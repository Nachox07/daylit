// The app's state and the tick: reads the monitors, asks the source, applies the decisions from DaylitCore.
import SwiftUI
import AppKit
import ServiceManagement
import DaylitCore

@MainActor final class Daylit: ObservableObject {

    @Published var mons: [Mon] = []
    @Published var builtIn: BuiltIn?     // lid open: manual slider only (config "builtIn": false hides it)
    var draggingBuiltIn = false
    @Published var source: Source = .off
    @Published var auto = UserDefaults.standard.object(forKey: "auto") as? Bool ?? true
    @Published var detail = ""          // one line under the Automatic switch
    @Published var lightStatus: String?  // the daylight sensor's state, for the Settings window
    @Published var problem: String?     // config / connection problem, shown as a caption
    @Published var login = SMAppService.mainApp.status == .enabled
    @Published var pauseOnBattery = true
    @Published var hasBattery = Power.hasBattery
    @Published var onBattery = Power.onBattery
    @Published var lookOn = UserDefaults.standard.bool(forKey: "autoLook")   // off by default on the Mac
    @Published var dark = false
    /// "Sync monitors": moving one external monitor moves the others, keeping their offsets.
    @Published var sync = UserDefaults.standard.bool(forKey: "syncMonitors")
    @Published var live: LiveInputs?     // the last tick's blind, lights, clouds and hand-set distances, for the Settings chart
    var syncOffsets: SyncOffsets = {
        guard let d = UserDefaults.standard.data(forKey: "syncOffsets"), let o = try? JSONDecoder().decode(SyncOffsets.self, from: d) else { return SyncOffsets() }
        return o
    }()
    /// Hand-set state kept across restarts (DaylitCore.SavedHolds), so a restart doesn't jump the monitors.
    var holds: SavedHolds = {
        guard let d = UserDefaults.standard.data(forKey: "holds"), let h = try? JSONDecoder().decode(SavedHolds.self, from: d) else { return SavedHolds() }
        return h
    }()
    /// A change of levels to offer in the panel (DaylitCore.Suggest), and why the last Apply failed.
    @Published var suggestion: Suggestion?
    @Published var suggestError: String?
    /// Hand changes waiting to settle, and the settled ones (corrections.json, this Mac only).
    var recorder = Recorder()
    var corrections: [Sample] = []
    /// Work the suggestion out again at the end of the next tick (start, reload, a new sample, Apply, Not now).
    var suggestDirty = true
    /// Bumped by Apply and Not now. updateSuggestion drops its result when it changed during its Home
    /// Assistant reads, so a card the user already handled does not come back.
    var suggestEpoch = 0
    /// Per monitor, bumped where Apply clears its hand-set offset. The tick copies a monitor's hold state, awaits
    /// the write, then stores the state back: if this changed meanwhile, the copy still has the offset Apply just
    /// cleared, so the tick clears it again in its own result (and carries on normally) instead of restoring it.
    var offsetCleared: [String: Int] = [:]
    /// input_number min/max/step per entity, kept until the config reloads (a failed read is not kept).
    var stepCache: [String: NumberStep] = [:]
    /// Entities Home Assistant answered for without min/max/step: not asked again until the config reloads.
    var notNumber: Set<String> = []
    /// What the last suggestion was worked out from: each monitor's levels, and whether Home Assistant answered.
    var suggestLevels: [String: [Double]] = [:]
    var suggestFromHA: Bool?
    /// "Not now": per monitor key, no suggestion until then (Unix seconds).
    var suggestDismissed: [String: Double] = UserDefaults.standard.dictionary(forKey: "suggestDismissed") as? [String: Double] ?? [:]
    var lookDark: Bool?
    var look = LookRule()          // light/dark decision with hysteresis (DaylitCore)
    /// On battery with the pause switch on: no automatic work at all (sliders and keys still work).
    var paused: Bool { pauseOnBattery && hasBattery && onBattery }
    var config = Config()
    var configProblem: String?
    /// "Keep settings in iCloud Drive" (UserDefaults: it cannot live in the file it moves).
    @Published var iCloudOn = UserDefaults.standard.bool(forKey: ConfigLocation.defaultsKey)
    @Published var iCloudNote: String?   // what turning it on or off did, or why it could not
    /// The last config that loaded, kept while the file is broken or still downloading from iCloud.
    var lastGood: Config?
    /// The file as last loaded: a change (here, or another Mac through iCloud) reloads on the next check.
    var configStamp: ConfigLocation.Stamp?
    var dragging: Set<CGDirectDisplayID> = []
    let ddcQ = DispatchQueue(label: "ddc")
    /// Slider and key values for DDC monitors: the newest one waiting, and the monitors with a write under way.
    /// One write at a time per monitor, always the newest value, so the screen follows a drag as fast as DDC allows.
    var ddcWant: [CGDirectDisplayID: Int] = [:]
    var ddcBusy: Set<CGDirectDisplayID> = []
    var busy = false, again = false, wasHere = true
    var generation = 0
    var lastTick = Date.distantPast
    var timer: Timer?
    var screenDebounce: DispatchWorkItem?

    /// A model with fixed state and no side effects (no displays, keys, timers or network): snapshots.
    init(preview: Void) {}

    init() {
        corrections = Self.loadCorrections()
        reload()
        if ProcessInfo.processInfo.environment["DAYLIT_NO_KEYS"] != "1" { Keys.shared.start(self) }   // tests: no Accessibility prompt
        HotKeys.shared.start({ [weak self] up, fine in self?.hotkey(up: up, fine: fine) }, theme: { [weak self] in self?.toggleDark() })
        // A cheap check every 5 s; the real work runs every 30 s (120 s on battery) or on an event.
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in Task { @MainActor in self.check() } }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                log("wake"); for i in self.mons.indices { self.mons[i].lastSet = nil }   // as after idle
                try? await Task.sleep(nanoseconds: 3_000_000_000); self.redetect() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in self.screensChanged() }
        }
    }

    // MARK: setup

    func reload() {
        let p = Config.path
        if ConfigLocation.state(of: p) == .evicted {
            // iCloud Drive removed the file from this Mac to save space: ask for it back.
            do { try FileManager.default.startDownloadingUbiquitousItem(at: p); Log.write("config: downloading from iCloud Drive") }
            catch { Log.write("config: iCloud Drive download did not start: \(error.localizedDescription)") }
        }
        configStamp = ConfigLocation.stamp(of: p)
        let (c, err, kept) = Config.reload(from: p, lastGood: lastGood)
        if !kept && ConfigLocation.state(of: p) == .present { lastGood = c }
        if kept { Log.write("config: keeping the last settings that loaded") }
        // A removed or changed lights entity must not keep its last state alive through an outage.
        if c.homeAssistant?.lights != config.homeAssistant?.lights { lastHALights = nil }
        config = c
        pauseOnBattery = UserDefaults.standard.object(forKey: "pauseOnBattery") as? Bool ?? c.pauseOnBattery ?? true
        lookDark = nil; look = LookRule()
        // A suggestion worked out under the old config must not be applied under the new one.
        suggestDirty = true; stepCache = [:]; notNumber = []; suggestEpoch += 1; suggestion = nil; suggestError = nil
        let (src, srcErr) = c.resolvedSource()
        source = src
        configProblem = err ?? srcErr
        problem = configProblem
        DDC.tool = c.ddcTool ?? DDC.defaultTool
        HAClient.tokenCache = [:]
        log("config \(p.path): source=\(src) problem=\(configProblem ?? "none")")
        if src == .sun, let l = c.location {
            log(String(format: "sun elevation now %.2f° at %.3f, %.3f", solarElevation(latitude: l.latitude, longitude: l.longitude), l.latitude, l.longitude))
        }
        redetect()
    }

    func screensChanged() {
        screenDebounce?.cancel()
        let w = DispatchWorkItem { Task { @MainActor in self.redetect() } }
        screenDebounce = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: w)
    }

    /// Rebuilds the monitor list from the connected displays, keeping per-monitor state where possible.
    func redetect() {
        generation += 1
        let old = Dictionary(mons.map { ($0.uuid, $0) }, uniquingKeysWith: { a, _ in a })
        mons = externalScreens().map { s in
            let cfg = config.monitors?.first { s.name.localizedCaseInsensitiveContains($0.match) }
            let control: Control
            let nativeOK = Native.usable(s.id)
            switch cfg?.control {
            case "native": control = .native
            case "ddc": control = .ddc
            default: control = nativeOK ? .native : DDC.available ? .ddc : .none
            }
            var m = Mon(id: s.id, uuid: s.uuid, name: s.name, label: cfg?.label ?? s.name, control: control,
                        day: cfg?.day ?? 70, blindDown: cfg?.blindDown ?? 40, night: cfg?.night ?? 20, ha: cfg?.homeAssistant)
            m.contrast = cfg?.contrast
            m.nightLights = cfg?.nightLights
            if control == .ddc { m.level = 50 }   // a starting guess until the monitor reports (or a write sets it)
            if control == .native && !nativeOK {
                m.noControl = "No brightness control right now. Turn on HDR for this display, or DDC/CI in its menu."
            } else if control == .none {
                m.noControl = "No brightness control. Turn on HDR for this display, or DDC/CI in its menu (\(DDC.hint))."
            }
            if let o = old[s.uuid] {
                m.level = o.level; m.remoteSeen = o.remoteSeen; m.remoteValue = o.remoteValue
                if o.control == control {
                    m.lastSet = o.lastSet; m.lastTarget = o.lastTarget; m.offset = o.offset; m.offsetSun = o.offsetSun; m.offsetAt = o.offsetAt
                    m.published = o.published; m.readState = o.readState
                }
                else {
                    // Another control reads on its own scale: the new reading is not a level set by hand.
                    Log.write("control: \(m.label) now uses \(control.rawValue) (was \(o.control.rawValue))")
                }
            }
            else if let h = holds.restore(key: s.uuid, now: Date().timeIntervalSince1970, maxAge: config.tuned.manualKeepHours * 3600) {
                m.lastSet = h.lastSet; m.lastTarget = h.lastTarget; m.offset = h.offset; m.offsetSun = h.offsetSun; m.offsetAt = h.offsetAt
            }
            if control == .native, let v = Native.get(s.id) { m.level = Double(v) }
            if old[s.uuid] == nil { Log.write("display: \(m.label) (\(s.name)) via \(control.rawValue)" + (m.noControl != nil ? ", no brightness control right now" : "")) }
            else if old[s.uuid]?.noControl != m.noControl {
                Log.write("control: \(m.label) " + (m.noControl == nil ? "brightness control is back (\(control.rawValue))" : "has no brightness control right now"))
            }
            log("display \"\(s.name)\" id=\(s.id) uuid=\(s.uuid) control=\(control.rawValue)\(cfg != nil ? " (config \"\(cfg!.match)\")" : "")")
            return m
        }
        if mons.isEmpty { log("no external displays") }
        builtIn = config.builtIn == false ? nil : builtInScreen()
        applyContrast()
        refresh()
    }

    /// The configured contrast, written once per redetect (start, reload, display change, wake), ahead
    /// of the tick's brightness read on the same serial DDC queue. Never on the regular tick. An idle Mac
    /// leaves it for when the user is back: the monitor may be showing another computer.
    func applyContrast() {
        guard idleSeconds() < config.tuned.idleSeconds else { return }
        for i in mons.indices {
            let m = mons[i]
            guard let v = ContrastRule.toWrite(configured: m.contrast, ddc: m.control == .ddc, written: m.contrastSet) else { continue }
            mons[i].contrastSet = v   // a refused write is logged, and tried again at the next redetect
            let uuid = m.uuid, label = m.label
            ddcQ.async {
                let ok = DDC.setContrast(uuid, v)
                Log.write(ok ? "contrast: \(label) set to \(v)"
                             : "display: \(label) did not take contrast \(v); trying again after the next display change, wake or reload")
            }
        }
    }

    // MARK: actions

    /// Run a tick now (or right after the current one).
    func refresh() {
        if busy { again = true; return }
        Task { await tick() }
    }

    func check() {
        if Appearance.isDark != dark { dark = Appearance.isDark }
        // One stat every 5 s: an edit, or iCloud bringing another Mac's change, reloads within seconds.
        if let was = configStamp, ConfigLocation.stamp(of: Config.path) != was {
            Log.write("config: changed on disk, reloading"); reload(); return
        }
        // Switching HDR on or off changes whether macOS can set an external display's brightness, and it
        // does not always post a screen-change notification: re-probe cheaply and re-detect on a change.
        let probe = externalScreens().map { "\($0.uuid)=\(Native.usable($0.id))" }.joined(separator: ",")
        if probe != lastProbe { let first = lastProbe == nil; lastProbe = probe; if !first { redetect(); return } }
        applyContrast()   // one left pending while idle, also with no source or paused on battery
        let battery = Power.onBattery
        if battery != onBattery {
            onBattery = battery
            if hasBattery && pauseOnBattery && source != .off {
                Log.write(battery ? "battery: paused" : "power: resumed")
                if !battery { refresh(); return }
                detail = "Paused on battery"
            }
        }
        if paused || mons.isEmpty { return }   // nothing to do until power or a monitor comes back
        let here = idleSeconds() < config.tuned.idleSeconds
        if here && !wasHere {
            // Back at this Mac: publish again even if nothing changed, in case another machine wrote meanwhile.
            Log.write("back: applying targets")
            // Another machine may have changed the monitors meanwhile: that reading is not a hand-set level.
            for i in mons.indices { mons[i].published = nil; mons[i].lastSet = nil }
            wasHere = here
            refresh(); return
        }
        if !here && wasHere && source != .off { Log.write("idle: paused") }
        wasHere = here
        guard source != .off else { return }
        let interval: Double = Power.onBattery ? config.tuned.batteryPollSeconds : config.tuned.pollSeconds
        if Date().timeIntervalSince(lastTick) >= interval { refresh() }
    }

    /// A level set by hand (slider or keys). With sync on, the other monitors follow with their offsets.
    func userSet(_ i: Int, _ v: Double) {
        guard mons.indices.contains(i) else { return }
        setLevel(i, v)
        guard sync, mons.count > 1 else { return }
        adoptSync()
        let follow = syncOffsets.follow(key: mons[i].uuid, level: Int(v), keys: mons.map(\.uuid))
        for (j, m) in mons.enumerated() where j != i && m.control != .none && m.readState.usable {
            if let lv = follow[m.uuid], Int(m.level) != lv { setLevel(j, Double(lv)) }
        }
    }

    /// Brings newly connected monitors into the sync group at their current offset.
    func adoptSync() {
        let before = syncOffsets
        syncOffsets.adopt(mons.filter { $0.control != .none }.map { (key: $0.uuid, level: Int($0.level)) })
        if syncOffsets != before { saveSync() }
    }

    func saveSync() {
        if let d = try? JSONEncoder().encode(syncOffsets) { UserDefaults.standard.set(d, forKey: "syncOffsets") }
    }

    func setSync(_ on: Bool) {
        sync = on
        UserDefaults.standard.set(on, forKey: "syncMonitors")
        if on {
            // Capture the offsets as they are now: each monitor keeps how much brighter or darker it is.
            syncOffsets = SyncOffsets(levels: mons.filter { $0.control != .none }.map { (key: $0.uuid, level: Int($0.level)) })
            saveSync()
            Log.write("sync: on " + mons.map { "\($0.label) \(syncOffsets.offsets[$0.uuid].map { $0 >= 0 ? "+\($0)" : "\($0)" } ?? "-")" }.joined(separator: ", "))
        } else {
            Log.write("sync: off")
        }
        refresh()
    }

    /// Linked, and every connected monitor is in the group (false while some were taken out).
    var syncAll: Bool { sync && syncOffsets.members(of: mons.map(\.uuid)) == mons.filter { $0.control != .none }.count }

    func isLinked(_ m: Mon) -> Bool { sync && mons.count > 1 && syncOffsets.isMember(m.uuid) }

    /// With three or more monitors: takes one out of the group or puts it back. A group of one is off.
    func toggleMember(_ i: Int) {
        guard sync, mons.indices.contains(i) else { return }
        let m = mons[i]
        if syncOffsets.isMember(m.uuid) {
            syncOffsets.leave(m.uuid)
            Log.write("sync: \(m.label) left the group")
            if syncOffsets.members(of: mons.map(\.uuid)) < 2 { setSync(false); return }
        } else {
            syncOffsets.join(m.uuid, levels: mons.filter { $0.control != .none }.map { (key: $0.uuid, level: Int($0.level)) })
            Log.write("sync: \(m.label) joined at \(syncOffsets.offsets[m.uuid] ?? 0)")
        }
        saveSync()
        objectWillChange.send()
    }

    func setLevel(_ i: Int, _ v: Double) {
        guard mons.indices.contains(i) else { return }
        mons[i].level = v; mons[i].touched = true
        let m = mons[i]
        if m.control == .native { Native.set(m.id, Int(v)); return }
        guard m.control == .ddc else { return }
        ddcWant[m.id] = Int(v)
        sendDDC(m.id, m.uuid)
    }

    /// Sends the newest waiting value unless a write to this monitor is still under way; that write sends it when done.
    func sendDDC(_ id: CGDirectDisplayID, _ uuid: String) {
        guard !ddcBusy.contains(id), let val = ddcWant.removeValue(forKey: id) else { return }
        ddcBusy.insert(id)
        ddcQ.async {
            let ok = DDC.set(uuid, val)
            Task { @MainActor in
                self.ddcBusy.remove(id)
                self.userWrote(id, ok: ok)
                self.sendDDC(id, uuid)
            }
        }
    }

    /// A slider or key write reached (or didn't reach) a DDC monitor that has never reported its level.
    func userWrote(_ id: CGDirectDisplayID, ok: Bool) {
        guard let i = mons.firstIndex(where: { $0.id == id }) else { return }
        let before = mons[i].readState
        let after = before.afterUserWrite(ok: ok)
        guard after != before else { return }
        mons[i].readState = after
        mons[i].available = after == .writeOnly
        Log.write(after == .writeOnly ? "display: \(mons[i].label) accepts brightness but doesn't report it (write-only)"
                                      : "display: \(mons[i].label) did not accept a brightness change")
    }

    /// The built-in screen's slider: macOS's own brightness, nothing automatic.
    func setBuiltIn(_ v: Double) {
        guard let b = builtIn else { return }
        builtIn?.level = v
        Native.set(b.id, Int(v))
    }

    func dragChanged(_ i: Int, _ editing: Bool) {
        guard mons.indices.contains(i) else { return }
        if editing { dragging.insert(mons[i].id) } else { dragging.remove(mons[i].id) }
    }

    /// Brightness keys: change the monitor that holds the focused window.
    func key(up: Bool, fine: Bool, on id: CGDirectDisplayID) {
        guard let i = mons.firstIndex(where: { $0.id == id }), mons[i].control != .none, mons[i].readState.usable else { return }
        let step = Double(fine ? 1 : 6)
        userSet(i, min(max(mons[i].level + (up ? step : -step), 0), 100))
        HUD.show(mons[i].label, mons[i].level, on: id)
    }

    /// Keyboard shortcut: the managed monitor with the active window, else the first one that works.
    func hotkey(up: Bool, fine: Bool) {
        let id = Focus.screenID().flatMap { s in mons.first { $0.id == s && $0.control != .none }?.id }
            ?? mons.first { $0.control != .none && $0.available }?.id
        if let id { key(up: up, fine: fine, on: id) }
    }

    func setAuto(_ on: Bool) {
        auto = on
        if source == .homeAssistant, let ha = config.homeAssistant, let sw = ha.autoSwitch {
            Task { _ = await HAClient.call(ha, "/api/services/input_boolean/" + (on ? "turn_on" : "turn_off"), ["entity_id": sw]) }
        } else {
            UserDefaults.standard.set(on, forKey: "auto")
        }
        if on { for i in mons.indices { forgetHandSet(i) } }
        refresh()
    }

    /// Back to the automatic level now (the Manual badge in the panel).
    func resume(_ i: Int) {
        guard mons.indices.contains(i) else { return }
        forgetHandSet(i)
        Log.write("resume: \(mons[i].label) back to automatic")
        refresh()
    }

    func forgetHandSet(_ i: Int) {
        mons[i].lastSet = nil; mons[i].offset = nil; mons[i].offsetSun = nil; mons[i].offsetAt = nil; mons[i].manual = false
        recorder.drop(mons[i].uuid)   // a change waiting to become a suggestion sample ends here too
    }

    func setPause(_ on: Bool) {
        pauseOnBattery = on
        UserDefaults.standard.set(on, forKey: "pauseOnBattery")
        Log.write("pause on battery: " + (on ? "on" : "off"))
        refresh()
    }

    func setLook(_ on: Bool) {
        lookOn = on
        UserDefaults.standard.set(on, forKey: "autoLook")
        lookDark = nil; look = LookRule()
        refresh()
    }

    /// Manual switch; it stays until the automatic decision next changes.
    func toggleDark() {
        if let e = Appearance.setDark(!Appearance.isDark) { problem = e; Log.write("theme: " + e) }
        Task { @MainActor in try? await Task.sleep(nanoseconds: 500_000_000); self.dark = Appearance.isDark }
    }

    // Light mode when daylight comes in (sun up, blind open) or the room lights are bright and white;
    // dark otherwise. Same rule as Windows, with a gap between on and off thresholds so it does not
    // flip back and forth. Only acts when the decision changes, so a manual switch stays until then.
    // With no earlier decision (start, reload, switched on) the current appearance settles a reading
    // inside a gap, so a restart does not undo a manual switch.
    func updateLook(_ s: Inputs) {
        guard lookOn else { lookDark = nil; look = LookRule(); return }
        let wantDark = look.wantDark(elev: s.elev, pos: s.pos, hasBlind: s.hasBlind, lightsOn: s.fromHA && s.lights, bri: s.bri, sat: s.sat,
                                     tuning: config.tuned, previous: lookDark == nil ? Appearance.isDark : nil)
        if wantDark != lookDark {
            if wantDark != Appearance.isDark {
                Log.write("theme: " + (wantDark ? "dark" : "light"))
                if let e = Appearance.setDark(wantDark) { problem = e; Log.write("theme: " + e) }
            }
            lookDark = wantDark
            dark = Appearance.isDark
        }
    }

    func setLogin(_ on: Bool) {
        try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
        login = SMAppService.mainApp.status == .enabled
    }

    /// Turns "Keep settings in iCloud Drive" on or off, moving the file (ConfigLocation), then loads it.
    func setICloud(_ on: Bool) {
        let loc = ConfigLocation.system
        do {
            if on {
                switch try loc.moveToICloud() {
                case .copiedLocal: iCloudNote = "Your settings are now in iCloud Drive."
                case .empty: iCloudNote = "Settings you save from now on go to iCloud Drive."
                case .adopted(let backedUp, let downloading):
                    iCloudNote = "Using the settings already in iCloud Drive"
                        + (downloading ? " (downloading)" : "")
                        + (backedUp ? ". This Mac's own are kept in ~/.config/daylit/config.local-backup.json." : ".")
                }
            } else {
                switch try loc.moveToLocal() {
                case .copiedBack: iCloudNote = "This Mac keeps a copy of the iCloud settings in ~/.config/daylit."
                case .nothingThere: iCloudNote = nil
                }
            }
        } catch ConfigLocation.MoveError.notDownloaded {
            try? FileManager.default.startDownloadingUbiquitousItem(at: loc.iCloud)
            iCloudNote = "The iCloud copy is still downloading. Try again in a moment."
            return
        } catch {
            iCloudNote = "Could not move the settings: \(error.localizedDescription)"
            return
        }
        UserDefaults.standard.set(on, forKey: ConfigLocation.defaultsKey)
        iCloudOn = on
        Log.write("config: iCloud Drive \(on ? "on" : "off")")
        reload()
    }

    /// Opens the config file in the default text editor, creating a starting one if there is none.
    func openConfig() {
        let p = Config.path
        if !FileManager.default.fileExists(atPath: p.path) {
            try? FileManager.default.createDirectory(at: p.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Serialized, not interpolated: a monitor name with a quote or backslash stays valid JSON.
            let monitors: [[String: Any]] = mons.map { m in
                ["match": m.name, "label": m.label, "control": m.control == .none ? "auto" : m.control.rawValue,
                 "day": 70, "blindDown": 40, "night": 20]
            }
            let root: [String: Any] = ["monitors": monitors]
            if let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: p, options: .atomic)
            }
        }
        let o = Process(); o.executableURL = URL(fileURLWithPath: "/usr/bin/open"); o.arguments = ["-t", p.path]
        try? o.run()
    }

    // MARK: tick

    struct Inputs {
        let elev, pos: Double; let lights: Bool; let levels: [String: [Double]]; var line: String
        var fromHA = false, hasBlind = false, bri = 0.0, sat = 100.0
        var light = 1.0                 // the daylight part's scale from the light sensor (1: clear or none)
        var lightRatio: Double? = nil   // how clear the sky is, 0…1, when the sensor says
        var lastLights: Bool? = nil     // sun fallback: the room lights Home Assistant last gave (nil: none seen)
    }

    // MARK: light sensor

    /// The light sensor's clear-sky reference, rebuilt from its Home Assistant history once a day.
    var lightRef = LightReference()
    var lightRefAt: Date?
    var lightRefBusy = false
    /// Which sensor, unit and place the reference belongs to: a new one starts learning again.
    var lightRefFor = ""
    /// The sensor's unit and since when its history is in it, kept across restarts.
    var lightUnit: LightUnit? = UserDefaults.standard.data(forKey: "lightUnit").flatMap { try? JSONDecoder().decode(LightUnit.self, from: $0) }
    /// The scale in use, smoothed, and when it last moved.
    var lightNow: Double?
    var lightAt: Date?

    func refreshLightReference(_ ha: HAConfig) async {
        guard let e = ha.light, Config.isEntityId(e), let loc = config.location, !lightRefBusy else { return }
        let unit = lightUnit?.sensor == e ? lightUnit! : LightUnit(sensor: e, unit: "", since: 0)
        let key = "\(e) \(unit.unit) \(loc.latitude) \(loc.longitude)"
        if key != lightRefFor { lightRef = LightReference(); lightRefAt = nil; lightRefFor = key }
        // Hourly while there is no reference, or only hours of it since a unit change; then daily.
        let young = unit.historyDays(10, now: Date().timeIntervalSince1970) < 1
        if let at = lightRefAt, Date().timeIntervalSince(at) < (lightRef.isEmpty || young ? 3600 : 86400) { return }
        lightRefBusy = true; defer { lightRefBusy = false }
        lightRefAt = Date()
        switch await HAClient.history(ha, e, days: unit.historyDays(10, now: Date().timeIntervalSince1970)) {
        case .success(let d):
            let samples = await Task.detached { lightSamples(history: d, latitude: loc.latitude, longitude: loc.longitude, since: unit.since) }.value
            guard key == lightRefFor else { return }   // the config changed meanwhile
            let fresh = LightReference(samples: samples)
            Log.write("light: clear-sky reference from \(samples.count) readings, \(fresh.bins.count) steps of the sky" +
                      (fresh.isEmpty ? " (not enough history, trying again in an hour)" : ""))
            if !fresh.isEmpty { lightRef = fresh }
            else if lightRef.isEmpty { lightStatus = "Not enough history in Home Assistant yet: trying again in an hour." }
            else { retryLightSoon() }   // an odd answer does not replace a good reference
        case .failure:
            Log.write("light: could not read its history (\(HAClient.lastCause ?? "no answer")), trying again in an hour")
            if lightRef.isEmpty { lightStatus = "Could not read the sensor's history from Home Assistant: trying again in an hour." }
            retryLightSoon()
        }
    }

    /// Keeps the sensor's unit; a change (W to kW) makes the reference learn again from now.
    func noteLightUnit(_ e: String, _ unit: String?) {
        let next = LightUnit.update(lightUnit, sensor: e, unit: unit, now: Date().timeIntervalSince1970)
        guard next != lightUnit else { return }
        if let was = lightUnit, was.sensor == e, !was.unit.isEmpty, next.unit != was.unit {
            Log.write("light: \(e) now reports in \(next.unit) (was \(was.unit)), learning its clear sky again from now")
        }
        lightUnit = next
        if let d = try? JSONEncoder().encode(next) { UserDefaults.standard.set(d, forKey: "lightUnit") }
    }

    /// Try the history again in an hour, keeping the reference in use until then.
    func retryLightSoon() { lightRefAt = Date().addingTimeInterval(3600 - 86400) }

    /// One step of the light scale toward `goal`, smoothed so a passing cloud does not jump the monitors.
    func stepLight(toward goal: Double) -> Double {
        let now = Date()
        lightNow = smoothLight(lightNow, toward: goal, dt: lightAt.map { now.timeIntervalSince($0) } ?? 0)
        lightAt = now
        return lightNow!
    }

    var lastHAError: String?
    /// When Home Assistant stopped answering. The sun takes over only after a minute, so a slow
    /// network at login or after wake does not jump the monitors to the fallback levels.
    var haDownSince: Date?
    /// When the current outage was last written to the log (see HAErrorRule.shouldLog).
    var haLoggedAt: Date?
    /// The last levels and blind position Home Assistant gave. With Home Assistant down, the sun drives
    /// the target but these stay, so a network blip does not swap them for the defaults and move the screens.
    var lastHALevels: [String: [Double]] = [:]
    var lastHAPos: Double?
    /// The room lights Home Assistant last gave: a monitor with a nightLights level keeps them while it is down.
    var lastHALights: Bool?
    var lastProbe: String?

    func tick() async {
        if busy { again = true; return }
        busy = true
        defer {
            busy = false
            if again { again = false; Task { await self.tick() } }
        }
        lastTick = Date()
        let gen = generation
        // The built-in screen's level can change under us (keys, auto-brightness): keep its slider current.
        if let b = builtIn, !draggingBuiltIn, let v = Native.get(b.id) { builtIn?.level = Double(v) }
        let snapshot = mons

        // Current brightness: detects values set by hand (keys, the monitor's own buttons).
        var cur: [Int?] = []
        for m in snapshot {
            switch m.control {
            case .native: cur.append(Native.get(m.id))   // NSScreen-backed API: main thread
            case .ddc: cur.append(await withCheckedContinuation { c in ddcQ.async { c.resume(returning: DDC.get(m.uuid)) } })
            case .none: cur.append(nil)
            }
        }
        guard gen == generation else { return }   // displays changed meanwhile; a new tick follows
        for i in mons.indices {
            if mons[i].control == .ddc {
                mons[i].readState = mons[i].readState.afterRead(ok: cur[i] != nil)
                // A write-only monitor: the slider is the record of its level.
                cur[i] = mons[i].readState.current(reading: cur[i], slider: Int(mons[i].level))
            }
            mons[i].available = cur[i] != nil
            if let v = cur[i], !dragging.contains(mons[i].id) { mons[i].level = Double(v) }
        }

        guard source != .off else { detail = ""; problem = configProblem; if live != nil { live = nil }; return }
        // Nothing to drive: no polling until a monitor appears (the display-change notification ticks again).
        guard !mons.isEmpty else { detail = ""; if live != nil { live = nil }; return }
        if paused { detail = "Paused on battery"; for i in mons.indices { mons[i].manual = false }; if live != nil { live = nil }; return }
        guard let inp = await inputs(), gen == generation else { return }

        let sun = daylightFraction(elevation: inp.elev, tuning: config.tuned)
        let here = idleSeconds() < config.tuned.idleSeconds
        /// The room lights for this monitor: in the sun fallback only one with a nightLights level keeps the last state.
        func lightsFor(_ m: Mon) -> Bool {
            roomLights(reported: inp.lights, fromHA: inp.fromHA, last: inp.lastLights, hasNightLights: nightLightsLevel(levels(of: m, inp)) != nil)
        }
        func ownTarget(_ m: Mon) -> Int {
            let lv = levels(of: m, inp)
            return target(day: lv[0], blindDown: lv[1], night: lv[2], elev: inp.elev, pos: inp.pos, lights: lightsFor(m),
                          tuning: config.tuned, light: inp.light, nightLights: nightLightsLevel(lv))
        }
        // Sync: the first group member that is reporting leads, with its own target and hand-set offset;
        // the others follow the level it lands on, each at its link offset (a hand-set level of theirs is
        // part of that offset, so they keep none of their own).
        if sync, mons.count > 1 { adoptSync() }
        let leader = sync && mons.count > 1 ? mons.indices.first(where: { cur[$0] != nil && syncOffsets.isMember(mons[$0].uuid) }) : nil
        var base: Int? = nil
        var linkedNow: [String: Int] = [:]   // linked followers: the level they land on (for the Settings chart)
        let now = Date().timeIntervalSince1970
        for i in leader.map({ l in [l] + mons.indices.filter { $0 != l } }) ?? Array(mons.indices) {
            guard let c0 = cur[i] else { continue }
            let m = mons[i]
            var state = HoldState(lastSet: m.lastSet, lastTarget: m.lastTarget, remoteSeen: m.remoteSeen, offset: m.offset, offsetSun: m.offsetSun, offsetAt: m.offsetAt, remoteValue: m.remoteValue)
            let clearedAt = offsetCleared[m.uuid]
            var want = ownTarget(m)
            let follower = base != nil && syncOffsets.isMember(m.uuid)
            if let b = base, follower {
                // Moved on its own (its buttons) since the last tick: that is its new place in the group.
                if here && auto, let last = m.lastSet, c0 != last, m.touched || abs(c0 - last) > 1, c0 != syncOffsets.level(key: m.uuid, base: b) {
                    syncOffsets.move(m.uuid, level: c0, base: b); saveSync()
                    Log.write("sync: \(m.label) moved by hand, now \(c0 - b >= 0 ? "+" : "")\(c0 - b) from the group")
                }
                want = syncOffsets.level(key: m.uuid, base: b) ?? want
                state.lastSet = nil; state.offset = nil; state.offsetSun = nil; state.offsetAt = nil
            }
            let step = decide(current: c0, want: want, remote: RemoteSet(row: inp.levels[m.uuid]), state: state,
                              here: here, auto: auto, dragging: dragging.contains(m.id), sun: sun, touched: m.touched, now: now)
            if let b = base, follower, let v = step.remote { syncOffsets.move(m.uuid, level: v, base: b); saveSync() }
            if !dragging.contains(m.id) { mons[i].touched = false }
            if let v = step.remote, !m.writeFailing { Log.write("remote: \(m.label) \(c0)% → \(v)% from Home Assistant") }
            var ok = true
            if let v = step.write {
                if step.remote == nil && !m.writeFailing { Log.write("auto: \(m.label) \(c0)% → \(v)%") }
                ok = await write(m, v)
                guard gen == generation else { return }
                // Logged once when it starts and once when it ends, not every tick while it lasts.
                if ok == mons[i].writeFailing {
                    Log.write(ok ? "display: \(m.label) takes brightness changes again"
                                 : "display: \(m.label) did not take brightness \(v)%; trying again each tick")
                }
                mons[i].writeFailing = !ok
            }
            var st = step.state.afterWrite(ok: ok, before: state)   // a refused write is retried next tick
            // Apply cleared this monitor's offset while the write was under way: merge that clear into our result.
            let appliedMeanwhile = offsetCleared[m.uuid] != clearedAt
            if appliedMeanwhile { st = Suggest.afterApply(st); recorder.drop(m.uuid) }
            if i == leader { base = syncOffsets.base(key: m.uuid, level: ok ? step.applied : c0) }   // followers go where the leader really is
            mons[i].lastSet = st.lastSet; mons[i].lastTarget = st.lastTarget; mons[i].remoteSeen = st.remoteSeen; mons[i].remoteValue = st.remoteValue
            if st.offset != m.offset, let o = st.offset {
                Log.write("manual: \(m.label) kept \(o > 0 ? "+" : "")\(o) from the automatic level")
            }
            mons[i].offset = st.offset; mons[i].offsetSun = st.offsetSun; mons[i].offsetAt = st.offsetAt
            // Suggestions (DaylitCore.Suggest): a new hand-set level becomes a sample once it has held 5 minutes.
            if step.remote != nil {
                // A Home Assistant "set" applied this tick overrides whatever was pending by hand: that change ends here.
                recorder.drop(m.uuid)
            } else if Suggest.isHandChange(before: state, after: step.state, remote: step.remote, now: now) {
                let ctx = SampleContext(follower: follower, writeFailed: !ok, idle: !here, paused: paused,
                                        sunFallback: source == .homeAssistant && !inp.fromHA)
                // An offset back at 0 (st.offset == nil) passes nil, which ends the pending change.
                recorder.handChanged(monitor: m.uuid, sample: st.offset.flatMap { o in
                    Suggest.makeSample(monitor: m.uuid, chosen: want + o, auto: want, elev: inp.elev, pos: inp.pos, lights: lightsFor(m),
                                       light: inp.light, levels: levels(of: m, inp), tuning: config.tuned, now: now, context: ctx)
                })
            }
            if let done = recorder.settle(monitor: m.uuid, held: auto && st.offset != nil, levels: levels(of: m, inp), now: now) {
                corrections.append(done); saveCorrections(); suggestDirty = true
            }
            if ok, let v = step.level { mons[i].level = Double(v) }
            if step.skip { continue }   // idle: the other machine on these monitors may be in use, so don't fight it
            let applied = ok ? step.applied : c0, manual = step.manual && !appliedMeanwhile
            if follower { linkedNow[m.uuid] = applied }
            mons[i].manual = manual
            if source == .homeAssistant, inp.fromHA, let ha = config.homeAssistant, let sensor = m.ha?.sensor, Config.isEntityId(sensor), mons[i].published != applied || mons[i].publishedManual != manual
                || mons[i].publishedLight != inp.lightRatio.map({ Int(($0 * 10).rounded()) }) {
                let r = await HAClient.call(ha, "/api/states/" + sensor, ["state": applied, "attributes": [
                    "friendly_name": "\(m.label) brightness", "unit_of_measurement": "%", "icon": "mdi:monitor",
                    "target": want, "manual": manual, "offset": st.offset ?? 0, "daylight": (sun * 100).rounded() / 100,
                    "light": inp.lightRatio.map { ($0 * 100).rounded() / 100 as Any } ?? NSNull(),   // how clear the sky is
                    "sun_elevation": inp.elev, "blind": inp.pos, "lights": inp.lights, "source": "macOS"]])
                guard gen == generation else { return }
                if case .success = r {   // retried next tick if the post failed
                    mons[i].published = applied; mons[i].publishedManual = manual
                    mons[i].publishedLight = inp.lightRatio.map { Int(($0 * 10).rounded()) }   // steps of 10%, not every tick
                    Log.write("publish: \(sensor) = \(applied)" + (manual ? " (manual)" : ""))
                }
            }
        }
        saveHolds()
        let nowSun = daylightFraction(elevation: inp.elev, tuning: config.tuned)
        var offs: [String: (value: Int, weight: Double)] = [:]
        for m in mons {
            if let o = m.offset, let w = offsetWeight(sun: nowSun, setAt: m.offsetSun ?? nowSun, age: m.offsetAt.map { now - $0 }) { offs[m.uuid] = (o, w) }
        }
        let leaderLabel = leader.map { mons[$0].label } ?? ""
        let next = LiveInputs(elev: inp.elev, pos: inp.hasBlind ? inp.pos : nil, lights: inp.lights, light: inp.light, levels: inp.levels,
                              offsets: offs, linked: linkedNow, leader: leaderLabel, applying: auto && here,
                              lightsUsed: Dictionary(mons.map { ($0.uuid, lightsFor($0)) }, uniquingKeysWith: { a, _ in a }))
        if live != next { live = next }
        if here { updateLook(inp) }   // an idle Mac leaves the appearance alone too
        detail = here || !auto ? inp.line : "Paused — this Mac is idle"
        log("tick: \(detail) · auto=\(auto)")
        await updateSuggestion(inp)
    }

    func saveHolds() {
        let before = holds, now = Date().timeIntervalSince1970
        for m in mons {
            let st = HoldState(lastSet: m.lastSet, lastTarget: m.lastTarget, offset: m.offset, offsetSun: m.offsetSun, offsetAt: m.offsetAt)
            // Re-save only when the state changed, so the timestamp means "last decided", not "last tick".
            if holds.entries[m.uuid].map({ $0.lastSet == st.lastSet && $0.lastTarget == st.lastTarget && $0.offset == st.offset }) != true {
                holds.record(key: m.uuid, state: st, now: now)
            }
        }
        if holds != before, let d = try? JSONEncoder().encode(holds) { UserDefaults.standard.set(d, forKey: "holds") }
    }

    /// Sends an automatic level; false when the monitor did not take it.
    func write(_ m: Mon, _ v: Int) async -> Bool {
        log("set \"\(m.label)\" → \(v)")
        switch m.control {
        case .native: return Native.set(m.id, v)
        case .ddc: let u = m.uuid; return await withCheckedContinuation { c in ddcQ.async { c.resume(returning: DDC.set(u, v)) } }
        case .none: return false
        }
    }

    /// Sun, blind, lights and levels from the configured source; nil when there is nothing to act on.
    func inputs() async -> Inputs? {
        func fromSun(_ note: String?) -> Inputs? {
            guard let l = config.location else { return nil }
            let e = solarElevation(latitude: l.latitude, longitude: l.longitude)
            let where_ = e >= 0 ? String(format: "%.1f° above the horizon", e) : String(format: "%.1f° below the horizon", -e)
            let keep = source == .homeAssistant   // a sun-only config uses its own levels
            var i = Inputs(elev: e, pos: keep ? lastHAPos ?? 100 : 100, lights: false, levels: keep ? lastHALevels : [:],
                           line: note ?? "Sun · " + where_, hasBlind: keep && lastHAPos != nil)
            i.lastLights = keep ? lastHALights : nil   // a sun-only config has no lights
            if lightNow != nil {   // no reading: back to the sun's rule, gently
                i.light = stepLight(toward: 1)
                if config.homeAssistant?.light != nil { lightStatus = "Home Assistant is not answering: going back to the sun's height alone." }
            }
            return i
        }
        switch source {
        case .off: return nil
        case .sun:
            problem = configProblem
            return fromSun(nil)
        case .homeAssistant:
            guard let ha = config.homeAssistant else { return nil }
            var result = await HAClient.state(ha, mons)
            for delay in HAErrorRule.retryDelays {   // a first failure after launch, wake or docking is usually brief
                guard case .failure(.unreachable) = result else { break }
                if haDownSince == nil { Log.write("home assistant: retrying in \(Int(delay)) s (\(HAClient.lastCause ?? "no answer"))") }   // once, not every tick of an outage
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                result = await HAClient.state(ha, mons)
            }
            switch result {
            case .success(let s):
                problem = configProblem
                if lastHAError != nil {
                    let mins = haDownSince.map { Int(Date().timeIntervalSince($0) / 60) } ?? 0
                    Log.write("home assistant: ok" + (mins > 0 ? " again after \(mins) min" : ""))
                    lastHAError = nil
                }
                haDownSince = nil; haLoggedAt = nil
                lastHALevels = s.m.mapValues(fallbackLevels)
                let pos = ha.cover != nil ? blindPosition(reported: s.pos, last: lastHAPos) : 100
                lastHAPos = ha.cover != nil ? pos : nil
                lastHALights = s.lights
                if let a = s.auto { auto = a } else { auto = UserDefaults.standard.object(forKey: "auto") as? Bool ?? true }
                let sun = Int((daylightFraction(elevation: s.elev, tuning: config.tuned) * 100).rounded())
                var line = "Home Assistant · sun \(sun)%"
                if ha.cover != nil { line += " · blind \(Int(pos))%" }
                if ha.lights != nil { line += lightsNote(lights: s.lights, bri: s.bri, sat: s.sat, tuning: config.tuned) }
                var i = Inputs(elev: s.elev, pos: pos, lights: s.lights, levels: s.m, line: line, fromHA: true,
                               hasBlind: ha.cover != nil, bri: s.bri, sat: s.sat)
                if let e = ha.light, Config.isEntityId(e), let loc = config.location {
                    noteLightUnit(e, s.lightUnit)
                    Task { await self.refreshLightReference(ha) }   // off the tick: the history call can take seconds
                    // A sensor that has not reported for 15 minutes is stuck, not dark.
                    let reading = (s.light ?? -1) >= 0 && (s.lightAge ?? 0) < 900 ? s.light : nil
                    // The sun here, as the reference was learned (Home Assistant's sun may be set elsewhere).
                    let here = solarElevation(latitude: loc.latitude, longitude: loc.longitude)
                    let ratio = lightRefFor.hasPrefix("\(e) \(lightUnit?.unit ?? "") ") ? lightRatio(value: reading, elev: here,
                                           morning: sunRising(latitude: loc.latitude, longitude: loc.longitude, at: Date()), reference: lightRef) : nil
                    i.lightRatio = ratio
                    i.light = stepLight(toward: lightCap(ratio: ratio, floor: config.tuned.cloudyDaylight / 100))
                    if let r = ratio {
                        i.line += " · light \(Int((r * 100).rounded()))%"
                        lightStatus = "Now \(Int((r * 100).rounded()))% of a clear sky, so daylight counts at most \(Int((i.light * 100).rounded()))%."
                    } else if !lightRef.isEmpty {
                        // A solar sensor sits at 0 and stops reporting after sunset: that is night, not a stuck sensor.
                        lightStatus = here <= 0 ? "The sun is down: the sensor counts again in the morning."
                            : reading == nil ? "No reading from the sensor right now: going back to the sun's height alone."
                            : "Too little sun to compare right now: the sun's height alone decides."
                    }
                } else {
                    lightStatus = nil
                    if lightNow != nil { i.light = stepLight(toward: 1) }
                }
                return i
            case .failure(let f):
                let message = HAClient.describe(f, ha)
                if HAErrorRule.shouldLog(message: message, lastMessage: lastHAError, lastLogged: haLoggedAt?.timeIntervalSince1970,
                                         now: Date().timeIntervalSince1970) {
                    let still = haLoggedAt != nil && message == lastHAError
                    Log.write("home assistant: \(message)" + (HAClient.lastCause.map { " (\($0))" } ?? "")
                              + (still ? ", still, for \(Int(Date().timeIntervalSince(haDownSince ?? Date()) / 60)) min" : ""))
                    haLoggedAt = Date()
                }
                lastHAError = message
                if haDownSince == nil { haDownSince = Date() }
                let transient = f == .unreachable
                let show = HAErrorRule.shouldShow(transient: transient, downSince: haDownSince!.timeIntervalSince1970,
                                                  now: Date().timeIntervalSince1970)
                problem = show ? message : configProblem
                if f == .noToken || f == .rejected { detail = "Home Assistant · not connected" }
                if config.location != nil, Date().timeIntervalSince(haDownSince!) >= config.tuned.haFallbackSeconds {
                    auto = UserDefaults.standard.object(forKey: "auto") as? Bool ?? true
                    return fromSun(nil)   // the error line under it says Home Assistant is unreachable
                }
                if show { detail = "Home Assistant · not connected" }
                return nil
            }
        }
    }
}
