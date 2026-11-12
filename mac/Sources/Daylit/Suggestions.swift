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
        Suggest.dropOld(Suggest.decode(try? Data(contentsOf: correctionsURL)), now: Date().timeIntervalSince1970)
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
        effectiveLevels(local: [m.day, m.blindDown, m.night], fromHA: inp.levels[m.uuid])
    }

    /// The monitor's input_number for a level, when the source is Home Assistant and one is configured.
    func haEntity(_ l: Level, of m: Mon) -> String? {
        guard source == .homeAssistant, let h = m.ha else { return nil }
        return [h.day, h.blindDown, h.night][l.rawValue].flatMap { Config.isEntityId($0) ? $0 : nil }
    }

    /// Whether some of the monitor's levels should come from Home Assistant but are not available this tick:
    /// Home Assistant is down (the sun stands in), or a configured helper reads below 0. Samples recorded
    /// with Home Assistant's levels must not be judged stale against local ones then.
    func haLevelsUnavailable(of m: Mon, _ inp: Inputs) -> Bool {
        for l in Level.allCases where haEntity(l, of: m) != nil {
            guard inp.fromHA, let row = inp.levels[m.uuid], row.count > l.rawValue, row[l.rawValue] >= 0 else { return true }
        }
        return false
    }

    /// What a level can be stored as now: a whole number for a local level, the input_number's own step,
    /// or nil when it comes from Home Assistant and is unavailable (Home Assistant down, or the helper reads below 0).
    func step(for l: Level, of m: Mon, _ inp: Inputs) async -> NumberStep? {
        guard let e = haEntity(l, of: m) else { return .whole }
        guard inp.fromHA, let ha = config.homeAssistant, let row = inp.levels[m.uuid], row.count > l.rawValue, row[l.rawValue] >= 0 else { return nil }
        return await HAClient.numberStep(ha, e)
    }
}
