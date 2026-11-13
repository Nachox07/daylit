// Suggest new levels from repeated hand changes (DaylitCore.Suggest): the file of samples, working out the
// suggestion the panel shows, and its two buttons. Nothing changes a level without Apply.
import Foundation
import DaylitCore

extension Daylit {
    /// This Mac's samples, not in iCloud: ~/Library/Application Support/Daylit/corrections.json.
    static var correctionsURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Daylit/corrections.json")
    }

    /// The saved samples, without those older than 14 days.
    static func loadCorrections() -> [Sample] {
        let d = try? Data(contentsOf: correctionsURL)
        let decoded = Suggest.decode(d)
        if let d, !d.isEmpty {
            let list = (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["samples"] as? [Any]
            // Not a samples list, or a list that decodes to nothing (one bad sample rejects the whole file).
            if list == nil || (!list!.isEmpty && decoded.isEmpty) { Log.write("suggest: corrections.json unreadable, starting empty") }
        }
        return Suggest.dropOld(decoded, now: Date().timeIntervalSince1970)
    }

    func saveCorrections() {
        corrections = Suggest.dropOld(corrections, now: Date().timeIntervalSince1970)
        let u = Self.correctionsURL
        do {
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Suggest.encode(corrections).write(to: u, options: .atomic)
        } catch {
            Log.write("suggest: could not save corrections.json: \(error.localizedDescription)")
        }
    }

    /// A monitor's levels this tick: Home Assistant's where it gave one, else the local ones.
    func levels(of m: Mon, _ inp: Inputs) -> [Double] {
        effectiveLevels(local: [m.day, m.blindDown, m.night] + (m.nightLights.map { [$0] } ?? []), fromHA: inp.levels[m.uuid])
    }

    /// The monitor's input_number for a level, when the source is Home Assistant and one is configured.
    func haEntity(_ l: Level, of m: Mon) -> String? {
        guard source == .homeAssistant, let h = m.ha else { return nil }
        return [h.day, h.blindDown, h.night, h.nightLights][l.rawValue].flatMap { Config.isEntityId($0) ? $0 : nil }
    }

    /// Whether some of the monitor's levels should come from Home Assistant but are not available this tick:
    /// Home Assistant is down (the sun stands in), or a configured helper reads below 0. Samples recorded
    /// with Home Assistant's levels must not be judged stale against local ones then.
    func haLevelsUnavailable(of m: Mon, _ inp: Inputs) -> Bool {
        // The nightLights helper is part of the levels snapshot too (row index 3).
        for l in Level.allCases where haEntity(l, of: m) != nil {
            guard inp.fromHA, let row = inp.levels[m.uuid], row.count > l.rawValue, row[l.rawValue] >= 0 else { return true }
        }
        return false
    }

    /// What a level can be stored as now: a whole number for a local level, the input_number's own step,
    /// or nil when it comes from Home Assistant and is unavailable (Home Assistant down, or the helper reads below 0).
    /// `retry` is true when the level is available this tick but its step could not be read: try again next tick.
    func step(for l: Level, of m: Mon, _ inp: Inputs) async -> (step: NumberStep?, retry: Bool) {
        guard let e = haEntity(l, of: m) else { return (.whole, false) }
        guard inp.fromHA, let ha = config.homeAssistant, let row = inp.levels[m.uuid], row.count > l.rawValue, row[l.rawValue] >= 0 else { return (nil, false) }
        if let c = stepCache[e] { return (c, false) }
        if notNumber.contains(e) { return (nil, false) }
        switch await HAClient.numberStep(ha, e) {
        case .noAnswer: return (nil, true)
        case .noAttributes:
            notNumber.insert(e)
            Log.write("suggest: \(e) is not an input_number, its level is not offered")
            return (nil, false)
        case .step(let s):
            stepCache[e] = s
            return (s, false)
        }
    }
}

extension Daylit {
    /// At the end of a tick: works the suggestion out again when something changed. The first monitor with
    /// one is shown; the next shows after it is handled.
    func updateSuggestion(_ inp: Inputs) async {
        var current: [String: [Double]] = [:]
        for m in mons { current[m.uuid] = levels(of: m, inp) }
        if current != suggestLevels || inp.fromHA != suggestFromHA { suggestDirty = true }
        guard suggestDirty else { return }
        suggestDirty = false; suggestLevels = current; suggestFromHA = inp.fromHA
        let now = Date().timeIntervalSince1970
        // A monitor whose Home Assistant levels are unavailable this tick (Home Assistant down, or a helper
        // reads below 0) is left out of `current`: dropStale keeps the samples of monitors it does not know,
        // so they are not deleted for good just because the local levels stand in for a while.
        var known = current
        for m in mons where haLevelsUnavailable(of: m, inp) { known[m.uuid] = nil }
        let kept = Suggest.dropOld(Suggest.dropStale(corrections, current: known), now: now)
        if kept != corrections { corrections = kept; saveCorrections() }
        let gen = generation, epoch = suggestEpoch
        var found: Suggestion?
        for m in mons where kept.contains(where: { $0.monitor == m.uuid }) {
            guard let lv = current[m.uuid] else { continue }
            // Steps are only needed for the levels the samples can tell apart (the others are never proposed).
            let mine = Suggest.dropOld(kept, now: now).filter { $0.monitor == m.uuid && Suggest.sameLevels($0.levels, lv) }
            let cand = Suggest.candidates(mine, tuning: config.tuned)
            // A monitor without nightLights may be offered one beside a lower night, but only when the room lights
            // come from Home Assistant: without them the level would never be used.
            let canAddNightLights = nightLightsLevel(lv) == nil && source == .homeAssistant
                && (config.homeAssistant?.lights).map(Config.isEntityId) == true && cand.contains(.night)
            var steps: [NumberStep?] = []
            for l in Level.allCases {
                if l == .nightLights && nightLightsLevel(lv) == nil && !canAddNightLights { steps.append(nil); continue }
                if !cand.contains(l) && !(l == .nightLights && canAddNightLights) { steps.append(.whole); continue }
                let r = await step(for: l, of: m, inp)
                if r.retry { suggestDirty = true }   // Home Assistant did not answer: work it out again next tick
                steps.append(r.step)
            }
            // Displays changed, or Apply / Not now was clicked while waiting: this answer is stale.
            guard gen == generation, epoch == suggestEpoch else { suggestDirty = true; return }
            if let s = Suggest.suggestion(monitor: m.uuid, samples: kept, levels: lv, steps: steps, now: now,
                                          dismissedUntil: suggestDismissed[m.uuid], tuning: config.tuned) {
                found = s; break
            }
        }
        guard found != suggestion else { return }
        if let f = found, let m = mons.first(where: { $0.uuid == f.monitor }) { Log.write(f.logLine(label: m.label)) }
        suggestion = found
    }

    /// Apply: writes each proposed level (its input_number in Home Assistant, or the local level in
    /// config.json), then clears the monitor's hand-set offset, which would otherwise be applied again on
    /// top of the new level. A failed write keeps the ones that worked and shows in the problem line.
    func applySuggestion() async {
        guard let sg = suggestion, let m = mons.first(where: { $0.uuid == sg.monitor }) else { return }
        suggestion = nil; suggestError = nil; suggestEpoch += 1
        var local: [String: Int] = [:]
        var failed: [String] = []
        for c in sg.changes {
            if let e = haEntity(c.level, of: m), let ha = config.homeAssistant {
                if case .failure(let f) = await HAClient.setNumber(ha, e, c.to) { failed.append("\(e) failed: \(HAClient.describe(f, ha))") }
            } else {
                local[c.level.key] = Int(c.to.rounded())
            }
        }
        var wroteFile = false
        if !local.isEmpty {
            let p = Config.path
            do {
                let original: Data?
                do { original = try ConfigLocation.dataForPatch(at: p) } catch ConfigLocation.ReadError.downloading {
                    throw ConfigEditError.invalid("config.json is still downloading from iCloud Drive")
                } catch ConfigLocation.ReadError.unreadable(let why) {
                    throw ConfigEditError.invalid("could not read it (\(why))")
                }
                if let d = original, ConfigText.hasComments(d) {
                    throw ConfigEditError.invalid("it has comments, which saving would remove; set the level in Settings instead")
                }
                let out = try ConfigPatch.setLevels(local, display: m.name, suggestedMatch: CLI.suggestMatch(m.name), in: original)
                try FileManager.default.createDirectory(at: p.deletingLastPathComponent(), withIntermediateDirectories: true)
                try out.write(to: p, options: .atomic)
                wroteFile = true
            } catch ConfigEditError.invalid(let why) {
                failed.append("config.json failed: " + why.replacingOccurrences(of: "config.json: ", with: ""))
            } catch ConfigEditError.notAnObject {
                failed.append("config.json failed: it is not a JSON object")
            } catch {
                failed.append("config.json failed: \(error.localizedDescription)")
            }
        }
        offsetCleared[sg.monitor, default: 0] += 1   // a tick in flight merges this clear into its own result
        if let i = mons.firstIndex(where: { $0.uuid == sg.monitor }) {
            let cleared = Suggest.afterApply(HoldState(lastSet: mons[i].lastSet, lastTarget: mons[i].lastTarget, offset: mons[i].offset,
                                                       offsetSun: mons[i].offsetSun, offsetAt: mons[i].offsetAt))
            mons[i].lastSet = cleared.lastSet; mons[i].offset = cleared.offset; mons[i].offsetSun = cleared.offsetSun
            mons[i].offsetAt = cleared.offsetAt; mons[i].manual = false
        }
        recorder.drop(sg.monitor)
        for f in failed { Log.write("suggest: \(m.label) \(f)") }
        if failed.isEmpty { Log.write("suggest: \(m.label) applied") }
        let applyError = failed.isEmpty ? nil : "Could not apply the suggestion: " + failed.joined(separator: "; ")
        suggestError = applyError
        suggestDirty = true
        if wroteFile { reload(); suggestError = applyError } else { refresh() }   // reload: the new local level is in the file now (it clears the error, so put it back)
    }

    /// Not now: no suggestion for this monitor for 7 days, remembered across restarts.
    func dismissSuggestion() {
        guard let sg = suggestion else { return }
        let now = Date().timeIntervalSince1970
        suggestDismissed[sg.monitor] = now + Suggest.notNow
        suggestDismissed = suggestDismissed.filter { $0.value > now }   // expired entries go
        suggestEpoch += 1
        UserDefaults.standard.set(suggestDismissed, forKey: "suggestDismissed")
        Log.write("suggest: \(mons.first { $0.uuid == sg.monitor }?.label ?? "a monitor") not now")
        suggestion = nil; suggestError = nil; suggestDirty = true
        refresh()
    }
}
