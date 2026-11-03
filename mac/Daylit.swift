// Daylit for macOS — menu-bar app that keeps external monitors at the right brightness.
// Works with no setup (sliders, brightness keys, on-screen indicator); automatic brightness comes
// from the sun at your location, or from Home Assistant (sun, a window blind, room lights). See README.md.
//
//  - "native" monitors: macOS's own brightness API (DisplayServices). Works while HDR is on,
//    when most monitors ignore DDC brightness.
//  - "ddc" monitors: DDC/CI through m1ddc (brew install m1ddc).
//  - Settings live in ~/.config/daylit/config.json (DAYLIT_CONFIG overrides the path); the Home
//    Assistant token in the keychain. DAYLIT_DEBUG=1 logs to stdout.
import SwiftUI
import AppKit
import CoreGraphics
import IOKit.ps
import ServiceManagement
import ApplicationServices
import Carbon.HIToolbox

let DEBUG = ProcessInfo.processInfo.environment["DAYLIT_DEBUG"] == "1"
/// Debug detail: stdout only, with DAYLIT_DEBUG=1.
func log(_ s: @autoclosure () -> String) { if DEBUG { print("[daylit] " + s()); fflush(stdout) } }

/// What the app decided and did, in ~/Library/Logs/Daylit/daylit.log (also stdout with DAYLIT_DEBUG=1).
enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Daylit/daylit.log")
    static let q = DispatchQueue(label: "log")
    static let fmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f
    }()
    static func write(_ msg: String) {
        log(msg)
        let line = fmt.string(from: Date()) + " " + msg + "\n"
        q.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 512 * 1024 {
                let old = url.appendingPathExtension("old")
                try? fm.removeItem(at: old); try? fm.moveItem(at: url, to: old)
            }
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}

// MARK: config

struct HAConfig: Decodable {
    let url: String?
    let tokenName: String?       // keychain service holding the long-lived token
    let autoSwitch: String?      // input_boolean for automatic mode; without it the switch is local
    let sun: String?             // default sun.sun
    let cover: String?           // optional blind; its position scales the daytime level
    let lights: String?          // optional light; on at night = a little brighter
}

struct MonitorHA: Decodable {
    let sensor: String?          // sensor this app publishes, e.g. sensor.daylit_left_monitor
    let day: String?             // input_numbers that override the local levels
    let blindDown: String?
    let night: String?
    let set: String?             // input_number: changing it in HA sets this monitor now, even when the Mac is idle
}

struct MonitorConfig: Decodable {
    let match: String            // part of the display name (case-insensitive)
    let label: String?
    let control: String?         // "native", "ddc" or "auto" (default)
    let day: Double?             // daytime level, blind open (default 70)
    let blindDown: Double?       // daytime level, blind closed (default 40)
    let night: Double?           // night level (default 20)
    let homeAssistant: MonitorHA?
}

struct Location: Decodable { let latitude: Double; let longitude: Double }

struct Config: Decodable {
    var source: String?
    var location: Location?
    var manualHold: Int?
    var pauseOnBattery: Bool?    // default for the panel switch (true when missing)
    var ddcTool: String?
    var homeAssistant: HAConfig?
    var monitors: [MonitorConfig]?

    static let path: URL = {
        if let p = ProcessInfo.processInfo.environment["DAYLIT_CONFIG"], !p.isEmpty { return URL(fileURLWithPath: p) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/daylit/config.json")
    }()

    /// A missing file is fine (all defaults). A broken one is reported, and the app still runs with defaults.
    static func load() -> (Config, String?) {
        guard let d = try? Data(contentsOf: path) else { return (Config(), nil) }
        do { return (try JSONDecoder().decode(Config.self, from: d), nil) }
        catch { return (Config(), "config.json is not valid: \(Self.describe(error))") }
    }
    static func describe(_ e: Error) -> String {
        switch e as? DecodingError {
        case .typeMismatch(_, let c), .valueNotFound(_, let c), .keyNotFound(_, let c), .dataCorrupted(let c):
            let at = c.codingPath.map(\.stringValue).joined(separator: ".")
            return (at.isEmpty ? "" : at + ": ") + c.debugDescription
        default: return e.localizedDescription
        }
    }
}

enum Source { case off, sun, homeAssistant }

extension Config {
    /// The source to use, plus a problem to show when the config asks for something it cannot do.
    func resolvedSource() -> (Source, String?) {
        let hasHA = !(homeAssistant?.url ?? "").isEmpty
        let fallback: Source = location != nil ? .sun : .off
        switch source {
        case nil: return (hasHA ? .homeAssistant : fallback, nil)
        case "off": return (.off, nil)
        case "sun": return location != nil ? (.sun, nil) : (.off, "Sun mode needs a location (latitude, longitude)")
        case "homeAssistant": return hasHA ? (.homeAssistant, nil) : (fallback, "Home Assistant mode needs homeAssistant.url")
        case let s?: return (hasHA ? .homeAssistant : fallback, "Unknown source \"\(s)\" (use off, sun or homeAssistant)")
        }
    }
}

// MARK: sun

/// Solar elevation in degrees (same formula as the Windows app; within 0.01° of Home Assistant's sun.sun).
func solarElevation(latitude: Double, longitude: Double, at date: Date = Date()) -> Double {
    func rad(_ x: Double) -> Double { x * .pi / 180 }
    func deg(_ x: Double) -> Double { x * 180 / .pi }
    func mod(_ a: Double, _ n: Double) -> Double { let r = a.truncatingRemainder(dividingBy: n); return r < 0 ? r + n : r }
    let d = date.timeIntervalSince1970 / 86400 + 2440587.5 - 2451545.0
    let g = rad(mod(357.529 + 0.98560028 * d, 360))
    let q = mod(280.459 + 0.98564736 * d, 360)
    let L = rad(q + 1.915 * sin(g) + 0.020 * sin(2 * g))
    let e = rad(23.439 - 0.00000036 * d)
    let ra = deg(atan2(cos(e) * sin(L), cos(L)))
    let dec = asin(sin(e) * sin(L))
    let gmst = mod(18.697374558 + 24.06570982441908 * d, 24)
    let ha = rad(gmst * 15 + longitude - ra)
    return deg(asin(sin(rad(latitude)) * sin(dec) + cos(rad(latitude)) * cos(dec) * cos(ha)))
}

// MARK: displays

struct Screen { let id: CGDirectDisplayID; let uuid: String; let name: String }

/// External displays only: the built-in screen keeps its own brightness handling.
@MainActor func externalScreens() -> [Screen] {
    if ProcessInfo.processInfo.environment["DAYLIT_DEBUG_NO_DISPLAYS"] == "1" { return [] }   // tests: the empty state
    return NSScreen.screens.compactMap { s in
        guard let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              CGDisplayIsBuiltin(id) == 0 else { return nil }
        let uuid = CGDisplayCreateUUIDFromDisplayID(id).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String } ?? ""
        return Screen(id: id, uuid: uuid, name: s.localizedName)
    }
}

enum Native {
    typealias GetF = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    typealias SetF = @convention(c) (UInt32, Float) -> Int32
    static let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
    static let getF: GetF? = dlsym(h, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: GetF.self) }
    static let setF: SetF? = dlsym(h, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: SetF.self) }

    static func get(_ id: CGDirectDisplayID) -> Int? {
        guard let getF else { return nil }
        var b: Float = -1
        return getF(id, &b) == 0 && b >= 0 ? Int((b * 100).rounded()) : nil
    }
    static func set(_ id: CGDirectDisplayID, _ v: Int) { _ = setF?(id, Float(v) / 100) }
}

/// DDC/CI through m1ddc, addressing the display by its system UUID (the same one CoreGraphics reports).
enum DDC {
    nonisolated(unsafe) static var tool = defaultTool
    static let defaultTool = ["/opt/homebrew/bin/m1ddc", "/usr/local/bin/m1ddc"]
        .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/opt/homebrew/bin/m1ddc"
    static var available: Bool { FileManager.default.isExecutableFile(atPath: tool) }

    static func run(_ args: [String]) -> String? {
        let p = Process(); p.executableURL = URL(fileURLWithPath: tool); p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return p.terminationStatus == 0 ? s : nil
    }
    static func get(_ uuid: String) -> Int? { run(["display", uuid, "get", "luminance"]).flatMap { Int($0) } }
    static func set(_ uuid: String, _ v: Int) { _ = run(["display", uuid, "set", "luminance", String(v)]) }
}

enum Power {
    static var onBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPMBatteryPowerKey
    }
    /// Macs without an internal battery (desktops) hide the pause-on-battery switch.
    static var hasBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return false }
        return list.contains { ps in
            let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any]
            return d?[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
    }
}

/// macOS light/dark mode through System Events (needs the Automation permission, asked once).
@MainActor enum Appearance {
    static var isDark: Bool { NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
    /// nil on success, else a short reason (e.g. the permission was refused).
    @discardableResult static func setDark(_ dark: Bool) -> String? {
        var err: NSDictionary?
        NSAppleScript(source: "tell application \"System Events\" to tell appearance preferences to set dark mode to \(dark)")?
            .executeAndReturnError(&err)
        guard let err else { return nil }
        let n = err[NSAppleScript.errorNumber] as? Int ?? 0
        return n == -1743 ? "Allow Daylit to control System Events (System Settings → Privacy & Security → Automation)"
                          : "Could not change light/dark mode (\(n))"
    }
}

func idleSeconds() -> Double {
    CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
}

// MARK: Home Assistant

struct HAState: Decodable {
    let elev, pos: Double
    let lights: Bool
    let auto: Bool?                  // nil when there is no autoSwitch
    let bri: Double                  // room light brightness 0-255 (0 = unknown)
    let sat: Double                  // its hs colour saturation (0 = white, ~60+ = warm)
    /// Per display UUID: [day, blindDown, night, set, setChanged]; -1 = use the local value / no set helper;
    /// setChanged is the set helper's last_changed (Unix seconds).
    let m: [String: [Double]]
}

enum HAClient {
    nonisolated(unsafe) static var tokenCache: [String: String] = [:]
    static func token(_ name: String) -> String? {
        if let t = tokenCache[name] { return t }
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", name, "-w"]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let s, !s.isEmpty else { return nil }
        tokenCache[name] = s
        return s
    }

    /// Whether a token is stored, without reading it (security exits 0 when the item exists).
    static func tokenStored(_ name: String) -> Bool {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", name]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// One template call returns everything a tick needs.
    static func template(_ ha: HAConfig, _ mons: [Mon]) -> String {
        let pos = ha.cover.map { "state_attr('\($0)','current_position') | float(100)" } ?? "100"
        let lights = ha.lights.map { "is_state('\($0)','on') | tojson" } ?? "false | tojson"   // bare false renders as Python False
        let auto = ha.autoSwitch.map { "{{ is_state('\($0)','on') | tojson }}" } ?? "null"   // null outside {{ }}: Jinja has no null
        let bri = ha.lights.map { "state_attr('\($0)','brightness') | float(0)" } ?? "0"
        let sat = ha.lights.map { "(state_attr('\($0)','hs_color') or [0, 100])[1] | float(100)" } ?? "100"
        func num(_ e: String?) -> String { e.map { "{{ states('\($0)') | float(-1) }}" } ?? "-1" }
        let m = mons.compactMap { mon -> String? in
            guard let h = mon.ha, h.day != nil || h.blindDown != nil || h.night != nil || h.set != nil else { return nil }
            // states.domain.name is None when the entity is missing, so a typo gives "no set helper", not an error.
            let set = h.set.map { "\(num($0)), {{ as_timestamp(states.\($0).last_changed) if states.\($0) else 0 }}" } ?? "-1, 0"
            return "\"\(mon.uuid)\": [\(num(h.day)), \(num(h.blindDown)), \(num(h.night)), \(set)]"
        }.joined(separator: ", ")
        return """
        {"elev": {{ state_attr('\(ha.sun ?? "sun.sun")','elevation') | float(-10) }},
         "pos": {{ \(pos) }},
         "lights": {{ \(lights) }},
         "auto": \(auto),
         "bri": {{ \(bri) }},
         "sat": {{ \(sat) }},
         "m": {\(m)}}
        """
    }

    enum Failure: Error { case noToken, rejected, unreachable, badAnswer }

    static func call(_ ha: HAConfig, _ path: String, _ body: [String: Any]) async -> Result<Data, Failure> {
        let name = ha.tokenName ?? "daylit-home-assistant"
        guard let token = token(name) else { return .failure(.noToken) }
        var base = ha.url ?? ""
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + path) else { return .failure(.unreachable) }
        var r = URLRequest(url: url, timeoutInterval: 6)
        r.httpMethod = "POST"
        r.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (d, resp) = try? await URLSession.shared.data(for: r) else { return .failure(.unreachable) }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { tokenCache[name] = nil; return .failure(.rejected) }
        return code < 300 ? .success(d) : .failure(.unreachable)
    }
    static func state(_ ha: HAConfig, _ mons: [Mon]) async -> Result<HAState, Failure> {
        switch await call(ha, "/api/template", ["template": template(ha, mons)]) {
        case .failure(let f): return .failure(f)
        case .success(let d):
            guard let s = try? JSONDecoder().decode(HAState.self, from: d), s.m.values.allSatisfy({ $0.count == 5 })
            else { return .failure(.badAnswer) }
            return .success(s)
        }
    }
    static func describe(_ f: Failure, _ ha: HAConfig) -> String {
        switch f {
        case .noToken: return "No Home Assistant token in the keychain (\"\(ha.tokenName ?? "daylit-home-assistant")\", see README)"
        case .rejected: return "Home Assistant rejected the token"
        case .unreachable: return "Cannot reach Home Assistant"
        case .badAnswer: return "Unexpected answer from Home Assistant (check the entity ids)"
        }
    }
}

// MARK: model

enum Control: String { case native, ddc, none }

struct Mon: Identifiable {
    let id: CGDirectDisplayID
    let uuid: String
    let name: String
    let label: String
    let control: Control
    let day, blindDown, night: Double
    let ha: MonitorHA?
    var level: Double = 0
    var available = true
    var manual = false
    var lastSet: Int? = nil, lastTarget: Int? = nil, published: Int? = nil
    var remoteSeen: Double? = nil    // last_changed of the HA "set" helper already acted on
}

/// Target level: the daytime value slides between "blind closed" and "blind open" with the blind
/// position; the sun then blends it with the night value (0 below -3°, full daytime from 12°).
/// Room lights on at night add a little.
func target(day: Double, blindDown: Double, night: Double, elev: Double, pos: Double, lights: Bool) -> Int {
    let sun = min(max((elev + 3) / 15, 0), 1)
    let daytime = blindDown + (day - blindDown) * pos / 100
    var v = night + (daytime - night) * sun
    if lights && sun < 0.3 { v = max(v, night + 5) }
    return Int(min(max(v, 0), 100).rounded())
}

@MainActor final class Daylit: ObservableObject {
    static let idleLimit: Double = 300

    @Published var mons: [Mon] = []
    @Published var source: Source = .off
    @Published var auto = UserDefaults.standard.object(forKey: "auto") as? Bool ?? true
    @Published var detail = ""          // one line under the Automatic switch
    @Published var problem: String?     // config / connection problem, shown as a caption
    @Published var login = SMAppService.mainApp.status == .enabled
    @Published var pauseOnBattery = true
    @Published var hasBattery = Power.hasBattery
    @Published var onBattery = Power.onBattery
    @Published var lookOn = UserDefaults.standard.bool(forKey: "autoLook")   // off by default on the Mac
    @Published var dark = false
    var lookDark: Bool?, daylight: Bool?, whiteLights: Bool?
    /// On battery with the pause switch on: no automatic work at all (sliders and keys still work).
    var paused: Bool { pauseOnBattery && hasBattery && onBattery }
    var config = Config()
    var configProblem: String?
    var dragging: Set<CGDirectDisplayID> = []
    let ddcQ = DispatchQueue(label: "ddc")
    var pending: [CGDirectDisplayID: DispatchWorkItem] = [:]
    var busy = false, again = false, wasHere = true
    var generation = 0
    var lastTick = Date.distantPast
    var timer: Timer?
    var screenDebounce: DispatchWorkItem?

    init() {
        reload()
        if ProcessInfo.processInfo.environment["DAYLIT_NO_KEYS"] != "1" { Keys.shared.start(self) }   // tests: no Accessibility prompt
        HotKeys.shared.start { [weak self] up, fine in self?.hotkey(up: up, fine: fine) }
        // A cheap check every 5 s; the real work runs every 30 s (120 s on battery) or on an event.
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in Task { @MainActor in self.check() } }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in log("wake"); try? await Task.sleep(nanoseconds: 3_000_000_000); self.redetect() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in self.screensChanged() }
        }
    }

    // MARK: setup

    func reload() {
        let (c, err) = Config.load()
        config = c
        pauseOnBattery = UserDefaults.standard.object(forKey: "pauseOnBattery") as? Bool ?? c.pauseOnBattery ?? true
        lookDark = nil; daylight = nil; whiteLights = nil
        let (src, srcErr) = c.resolvedSource()
        source = src
        configProblem = err ?? srcErr
        problem = configProblem
        DDC.tool = c.ddcTool ?? DDC.defaultTool
        HAClient.tokenCache = [:]
        log("config \(Config.path.path): source=\(src) problem=\(configProblem ?? "none")")
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
            switch cfg?.control {
            case "native": control = .native
            case "ddc": control = .ddc
            default: control = Native.get(s.id) != nil ? .native : DDC.available ? .ddc : .none
            }
            var m = Mon(id: s.id, uuid: s.uuid, name: s.name, label: cfg?.label ?? s.name, control: control,
                        day: cfg?.day ?? 70, blindDown: cfg?.blindDown ?? 40, night: cfg?.night ?? 20, ha: cfg?.homeAssistant)
            if let o = old[s.uuid] {
                m.level = o.level; m.remoteSeen = o.remoteSeen
                if o.control == control { m.lastSet = o.lastSet; m.lastTarget = o.lastTarget; m.published = o.published }
                else {
                    // Another control reads on its own scale: the new reading is not a level set by hand.
                    Log.write("control: \(m.label) now uses \(control.rawValue) (was \(o.control.rawValue))")
                }
            }
            if control == .native, let v = Native.get(s.id) { m.level = Double(v) }
            if old[s.uuid] == nil { Log.write("display: \(m.label) (\(s.name)) via \(control.rawValue)") }
            log("display \"\(s.name)\" id=\(s.id) uuid=\(s.uuid) control=\(control.rawValue)\(cfg != nil ? " (config \"\(cfg!.match)\")" : "")")
            return m
        }
        if mons.isEmpty { log("no external displays") }
        refresh()
    }

    // MARK: actions

    /// Run a tick now (or right after the current one).
    func refresh() {
        if busy { again = true; return }
        Task { await tick() }
    }

    func check() {
        if Appearance.isDark != dark { dark = Appearance.isDark }
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
        let here = idleSeconds() < Self.idleLimit
        if here && !wasHere {
            // Back at this Mac: publish again even if nothing changed, in case another machine wrote meanwhile.
            Log.write("back: applying targets")
            for i in mons.indices { mons[i].published = nil }
            wasHere = here
            refresh(); return
        }
        if !here && wasHere && source != .off { Log.write("idle: paused") }
        wasHere = here
        guard source != .off else { return }
        let interval: Double = Power.onBattery ? 120 : 30
        if Date().timeIntervalSince(lastTick) >= interval { refresh() }
    }

    func setLevel(_ i: Int, _ v: Double) {
        guard mons.indices.contains(i) else { return }
        mons[i].level = v
        let m = mons[i]
        if m.control == .native { Native.set(m.id, Int(v)); return }
        guard m.control == .ddc else { return }
        pending[m.id]?.cancel()   // DDC is slow: only send the last value of a quick series
        let uuid = m.uuid, val = Int(v)
        let w = DispatchWorkItem { DDC.set(uuid, val) }
        pending[m.id] = w; ddcQ.asyncAfter(deadline: .now() + 0.15, execute: w)
    }

    func dragChanged(_ i: Int, _ editing: Bool) {
        guard mons.indices.contains(i) else { return }
        if editing { dragging.insert(mons[i].id) } else { dragging.remove(mons[i].id) }
    }

    /// Brightness keys: change the monitor that holds the focused window.
    func key(up: Bool, fine: Bool, on id: CGDirectDisplayID) {
        guard let i = mons.firstIndex(where: { $0.id == id }), mons[i].control != .none else { return }
        let step = Double(fine ? 1 : 6)
        setLevel(i, min(max(mons[i].level + (up ? step : -step), 0), 100))
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
        if on { for i in mons.indices { mons[i].lastSet = nil; mons[i].manual = false } }
        refresh()
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
        lookDark = nil; daylight = nil; whiteLights = nil
        refresh()
    }

    /// Manual switch; it stays until the automatic decision next changes.
    func toggleDark() {
        if let e = Appearance.setDark(!Appearance.isDark) { problem = e }
        Task { @MainActor in try? await Task.sleep(nanoseconds: 500_000_000); self.dark = Appearance.isDark }
    }

    // Light mode when daylight comes in (sun up, blind open) or the room lights are bright and white;
    // dark otherwise. Same rule as Windows, with a gap between on and off thresholds so it does not
    // flip back and forth. Only acts when the decision changes, so a manual switch stays until then.
    func updateLook(_ s: Inputs) {
        guard lookOn else { lookDark = nil; daylight = nil; whiteLights = nil; return }
        if s.hasBlind {
            daylight = s.elev > 4 && s.pos >= 55 ? true : s.elev < 1 || s.pos <= 35 ? false : daylight ?? (s.elev > 3 && s.pos >= 50)
        } else {
            daylight = s.elev > 4 ? true : s.elev < 1 ? false : daylight ?? (s.elev > 3)
        }
        let lit = s.fromHA && s.lights && s.bri > 0   // brightness 0-255; hs saturation 0 = white, ~60+ = warm
        whiteLights = lit && s.bri >= 200 && s.sat <= 35 ? true : !lit || s.bri < 170 || s.sat > 45 ? false : whiteLights ?? false
        let wantDark = !(daylight! || whiteLights!)
        if wantDark != lookDark {
            Log.write("theme: " + (wantDark ? "dark" : "light"))
            if wantDark != Appearance.isDark, let e = Appearance.setDark(wantDark) {
                problem = e; Log.write("theme: " + e)
            }
            lookDark = wantDark
            dark = Appearance.isDark
        }
    }

    func setLogin(_ on: Bool) {
        try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
        login = SMAppService.mainApp.status == .enabled
    }

    /// Opens the config file in the default text editor, creating a starting one if there is none.
    func openConfig() {
        let p = Config.path
        if !FileManager.default.fileExists(atPath: p.path) {
            try? FileManager.default.createDirectory(at: p.deletingLastPathComponent(), withIntermediateDirectories: true)
            let monitors = mons.map { m in
                "    { \"match\": \"\(m.name)\", \"label\": \"\(m.label)\", \"control\": \"\(m.control == .none ? "auto" : m.control.rawValue)\", \"day\": 70, \"blindDown\": 40, \"night\": 20 }"
            }.joined(separator: ",\n")
            let text = "{\n  \"manualHold\": 5,\n  \"monitors\": [\n\(monitors)\n  ]\n}\n"
            try? text.write(to: p, atomically: true, encoding: .utf8)
        }
        let o = Process(); o.executableURL = URL(fileURLWithPath: "/usr/bin/open"); o.arguments = ["-t", p.path]
        try? o.run()
    }

    // MARK: tick

    struct Inputs {
        let elev, pos: Double; let lights: Bool; let levels: [String: [Double]]; let line: String
        var fromHA = false, hasBlind = false, bri = 0.0, sat = 100.0
    }

    var lastHAError: String?

    /// "lights 80% white" / "lights 40% warm": the colour matters to how bright the room feels, so show it.
    static func lightsNote(_ s: HAState) -> String {
        guard s.lights else { return "" }
        guard s.bri > 0 else { return " · lights on" }
        let tone = s.sat <= 35 ? " white" : s.sat > 45 ? " warm" : ""
        return " · lights \(Int((s.bri / 2.55).rounded()))%\(tone)"
    }

    func tick() async {
        if busy { again = true; return }
        busy = true
        defer {
            busy = false
            if again { again = false; Task { await self.tick() } }
        }
        lastTick = Date()
        let gen = generation
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
            mons[i].available = cur[i] != nil
            if let v = cur[i], !dragging.contains(mons[i].id) { mons[i].level = Double(v) }
        }

        guard source != .off else { detail = ""; problem = configProblem; return }
        // Nothing to drive: no polling until a monitor appears (the display-change notification ticks again).
        guard !mons.isEmpty else { detail = ""; return }
        if paused { detail = "Paused on battery"; for i in mons.indices { mons[i].manual = false }; return }
        guard let inp = await inputs(), gen == generation else { return }

        let sun = min(max((inp.elev + 3) / 15, 0), 1)
        let here = idleSeconds() < Self.idleLimit
        let hold = config.manualHold ?? 5
        for i in mons.indices {
            guard let c0 = cur[i] else { continue }
            var c = c0
            let m = mons[i]
            var lv = [m.day, m.blindDown, m.night]
            if let ov = inp.levels[m.uuid] { for k in 0..<3 where ov[k] >= 0 { lv[k] = ov[k] } }
            let want = target(day: lv[0], blindDown: lv[1], night: lv[2], elev: inp.elev, pos: inp.pos, lights: inp.lights)

            // Set from Home Assistant: acts once per change of the helper, even when this Mac is idle
            // (e.g. dimming from the phone while away). Then it is a hand-set level like any other.
            var remote = false
            if let r = inp.levels[m.uuid], r.count == 5, r[3] >= 0, r[4] > 0 {
                if m.remoteSeen == nil { mons[i].remoteSeen = r[4] }   // first look: an old value is not a command
                else if r[4] > m.remoteSeen! {
                    mons[i].remoteSeen = r[4]
                    let v = Int(min(max(r[3], 0), 100).rounded())
                    Log.write("remote: \(m.label) \(c)% → \(v)% from Home Assistant")
                    if c != v { write(m, v) }
                    c = v; remote = true
                    mons[i].level = Double(v)
                    mons[i].lastTarget = want; mons[i].lastSet = v == want ? nil : want   // held as hand-set until the target moves
                }
            }
            // Idle: the other machine on these monitors may be in use, so don't fight it.
            if !here && !remote { continue }

            var applied = c, manual = remote
            if auto && !remote && !dragging.contains(m.id) {
                let handSet = mons[i].lastSet != nil && c != mons[i].lastSet!
                if handSet && abs(want - (mons[i].lastTarget ?? want)) < hold {
                    manual = true
                } else {
                    if c != want { Log.write("auto: \(m.label) \(c)% → \(want)%"); write(m, want) }
                    applied = want; mons[i].lastSet = want; mons[i].lastTarget = want; mons[i].level = Double(want)
                }
            }
            mons[i].manual = manual
            if source == .homeAssistant, inp.fromHA, let ha = config.homeAssistant, let sensor = m.ha?.sensor, mons[i].published != applied {
                let r = await HAClient.call(ha, "/api/states/" + sensor, ["state": applied, "attributes": [
                    "friendly_name": "\(m.label) brightness", "unit_of_measurement": "%", "icon": "mdi:monitor",
                    "target": want, "manual": manual, "daylight": (sun * 100).rounded() / 100,
                    "sun_elevation": inp.elev, "blind": inp.pos, "lights": inp.lights, "source": "macOS"]])
                guard gen == generation else { return }
                if case .success = r {   // retried next tick if the post failed
                    mons[i].published = applied
                    Log.write("publish: \(sensor) = \(applied)" + (manual ? " (manual)" : ""))
                }
            }
        }
        if here { updateLook(inp) }   // an idle Mac leaves the appearance alone too
        detail = here || !auto ? inp.line : "Paused — this Mac is idle"
        log("tick: \(detail) · auto=\(auto)")
    }

    func write(_ m: Mon, _ v: Int) {
        log("set \"\(m.label)\" → \(v)")
        if m.control == .native { Native.set(m.id, v) }
        else if m.control == .ddc { let u = m.uuid; ddcQ.async { DDC.set(u, v) } }
    }

    /// Sun, blind, lights and levels from the configured source; nil when there is nothing to act on.
    func inputs() async -> Inputs? {
        func fromSun(_ note: String?) -> Inputs? {
            guard let l = config.location else { return nil }
            let e = solarElevation(latitude: l.latitude, longitude: l.longitude)
            let where_ = e >= 0 ? String(format: "%.1f° above the horizon", e) : String(format: "%.1f° below the horizon", -e)
            return Inputs(elev: e, pos: 100, lights: false, levels: [:], line: note ?? "Sun · " + where_)
        }
        switch source {
        case .off: return nil
        case .sun:
            problem = configProblem
            return fromSun(nil)
        case .homeAssistant:
            guard let ha = config.homeAssistant else { return nil }
            switch await HAClient.state(ha, mons) {
            case .success(let s):
                problem = configProblem
                if lastHAError != nil { Log.write("home assistant: ok"); lastHAError = nil }
                if let a = s.auto { auto = a } else { auto = UserDefaults.standard.object(forKey: "auto") as? Bool ?? true }
                let sun = Int((min(max((s.elev + 3) / 15, 0), 1) * 100).rounded())
                var line = "Home Assistant · sun \(sun)%"
                if ha.cover != nil { line += " · blind \(Int(s.pos))%" }
                if ha.lights != nil { line += Self.lightsNote(s) }
                return Inputs(elev: s.elev, pos: s.pos, lights: s.lights, levels: s.m, line: line, fromHA: true,
                              hasBlind: ha.cover != nil, bri: s.bri, sat: s.sat)
            case .failure(let f):
                problem = HAClient.describe(f, ha)
                if lastHAError != problem { Log.write("home assistant: \(problem ?? "")"); lastHAError = problem }
                if f == .noToken || f == .rejected { detail = "Home Assistant · not connected" }
                if config.location != nil {
                    auto = UserDefaults.standard.object(forKey: "auto") as? Bool ?? true
                    return fromSun("Home Assistant unreachable — using the sun")
                }
                detail = "Home Assistant · not connected"
                return nil
            }
        }
    }
}

// MARK: keys, focus, on-screen indicator

enum Focus {
    /// The managed external display holding the focused window, or nil (built-in screen or an
    /// unsupported one). nil leaves the brightness key to macOS, so the laptop screen works natively.
    @MainActor static func managedMonitor() -> CGDirectDisplayID? {
        guard let id = screenID(), let m = Keys.shared.model,
              m.mons.contains(where: { $0.id == id && $0.control != .none }) else { return nil }
        return id
    }
    /// Display holding the frontmost app's front window (falls back to the mouse).
    static func screenID() -> CGDirectDisplayID? {
        var point: CGPoint? = nil
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
           let w = list.first(where: { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }),
           let b = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b) {
            point = CGPoint(x: r.midX, y: r.midY)
        }
        if point == nil, let e = CGEvent(source: nil) { point = e.location }
        guard let p = point else { return nil }
        var id: CGDirectDisplayID = 0; var n: UInt32 = 0
        guard CGGetDisplaysWithPoint(p, 1, &id, &n) == .success, n > 0 else { return nil }
        return id
    }
}

final class Keys {
    static let shared = Keys()
    weak var model: Daylit?
    var tap: CFMachPort?

    @MainActor func start(_ m: Daylit) {
        model = m
        // Needs Accessibility permission; macOS shows the prompt the first time.
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.start(m) }   // retry until granted
            return
        }
        guard tap == nil else { return }
        let cb: CGEventTapCallBack = { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = Keys.shared.tap { CGEvent.tapEnable(tap: t, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            // Apple Magic Keyboard: brightness keys arrive as plain key events, keycode 144 (up) / 145 (down).
            if type == .keyDown || type == .keyUp {
                let kc = event.getIntegerValueField(.keyboardEventKeycode)
                guard kc == 144 || kc == 145, let id = MainActor.assumeIsolated({ Focus.managedMonitor() }) else {
                    return Unmanaged.passUnretained(event)
                }
                if type == .keyDown {
                    let f = event.flags
                    let fine = f.contains(.maskAlternate) && f.contains(.maskShift)
                    DispatchQueue.main.async { Keys.shared.model?.key(up: kc == 144, fine: fine, on: id) }
                }
                return nil
            }
            // Other keyboards: NX_SYSDEFINED media-key events, key codes 2 (up) / 3 (down).
            guard type.rawValue == 14, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else {
                return Unmanaged.passUnretained(event)
            }
            let code = (ns.data1 & 0xFFFF0000) >> 16
            let down = ((ns.data1 & 0xFF00) >> 8) == 0xA
            guard code == 2 || code == 3 else { return Unmanaged.passUnretained(event) }
            guard let id = MainActor.assumeIsolated({ Focus.managedMonitor() }) else { return Unmanaged.passUnretained(event) }
            if down {
                let fine = ns.modifierFlags.contains(.option) && ns.modifierFlags.contains(.shift)
                DispatchQueue.main.async { Keys.shared.model?.key(up: code == 2, fine: fine, on: id) }
            }
            return nil   // swallow, so macOS does not also act on it
        }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                eventsOfInterest: CGEventMask((1 << 14) | (1 << 10) | (1 << 11)), callback: cb, userInfo: nil)
        if let t = tap {
            CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, t, 0), .commonModes)
            CGEvent.tapEnable(tap: t, enable: true)
        }
    }
}

@MainActor enum HUD {
    static var panel: NSPanel?
    static var hide: DispatchWorkItem?
    static func show(_ label: String, _ v: Double, on id: CGDirectDisplayID) {
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == id
        }) else { return }
        let size = NSSize(width: 240, height: 70)
        let p = panel ?? {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .statusBar; p.isOpaque = false; p.backgroundColor = .clear; p.ignoresMouseEvents = true; p.hasShadow = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel = p; return p
        }()
        p.contentView = NSHostingView(rootView:
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "display").foregroundStyle(.secondary).accessibilityHidden(true)
                    Text(label).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer()
                    Text("\(Int(v))%").font(.system(size: 13, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Image(systemName: "sun.min.fill").font(.system(size: 11)).foregroundStyle(.secondary).accessibilityHidden(true)
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.quaternary)
                            Capsule().fill(.primary).frame(width: max(6, g.size.width * v / 100))
                        }
                    }.frame(height: 6)
                    Image(systemName: "sun.max.fill").font(.system(size: 13)).foregroundStyle(.secondary).accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .frame(width: size.width, height: size.height)
            .background(VisualEffect().clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))))
        let f = screen.frame
        p.setFrame(NSRect(x: f.midX - size.width / 2, y: f.minY + f.height * 0.12, width: size.width, height: size.height), display: true)
        p.alphaValue = 1; p.orderFrontRegardless()
        hide?.cancel()
        let w = DispatchWorkItem { NSAnimationContext.runAnimationGroup { $0.duration = 0.3; p.animator().alphaValue = 0 } }
        hide = w; DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: w)
    }
}


// MARK: keyboard shortcuts (in addition to the brightness keys)

/// Global shortcuts through Carbon's RegisterEventHotKey: no Accessibility permission needed, and the
/// key press is consumed. Up, down, and each with Shift for steps of 1.
@MainActor final class HotKeys {
    static let shared = HotKeys()
    struct Combo: Codable, Equatable {
        var key: UInt32          // virtual key code (kVK_*)
        var mods: UInt32         // Carbon modifiers: cmdKey, optionKey, controlKey
        var char: String         // what the key shows, e.g. "↑"
        var text: String {
            (mods & UInt32(controlKey) != 0 ? "⌃" : "") + (mods & UInt32(optionKey) != 0 ? "⌥" : "")
                + (mods & UInt32(cmdKey) != 0 ? "⌘" : "") + char
        }
    }
    static let mods = UInt32(controlKey | optionKey | cmdKey)
    static let defaultUp = Combo(key: UInt32(kVK_UpArrow), mods: mods, char: "↑")
    static let defaultDown = Combo(key: UInt32(kVK_DownArrow), mods: mods, char: "↓")

    var up: Combo = load("hotkeyUp") ?? defaultUp
    var down: Combo = load("hotkeyDown") ?? defaultDown
    var ok = false
    var refs: [EventHotKeyRef] = []
    var handler: EventHandlerRef?
    var action: ((Bool, Bool) -> Void)?   // (up, fine)

    static func load(_ k: String) -> Combo? {
        UserDefaults.standard.data(forKey: k).flatMap { try? JSONDecoder().decode(Combo.self, from: $0) }
    }
    func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(up), forKey: "hotkeyUp")
        UserDefaults.standard.set(try? JSONEncoder().encode(down), forKey: "hotkeyDown")
    }
    /// "⌃⌥⌘↑ / ↓" when both share modifiers.
    var pairText: String { up.mods == down.mods ? "\(up.text) / \(down.char)" : "\(up.text) / \(down.text)" }

    func start(_ act: @escaping (Bool, Bool) -> Void) {
        action = act
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKeys.shared.action?(id == 1 || id == 3, id >= 3) } }
            return noErr
        }, 1, &spec, nil, &handler)
        ok = register(up, down)
        Log.write("hotkeys: \(pairText)" + (ok ? "" : " are taken by another app"))
    }

    /// Registers all four; false (and nothing registered) if any is taken or not allowed.
    @discardableResult func register(_ u: Combo, _ d: Combo) -> Bool {
        unregister()
        let shift = UInt32(shiftKey)
        for (i, (c, extra)) in [(u, 0), (d, 0), (u, shift), (d, shift)].enumerated() {
            var ref: EventHotKeyRef?
            let st = RegisterEventHotKey(c.key, c.mods | UInt32(extra), EventHotKeyID(signature: 0x444C_5954 /* DLYT */, id: UInt32(i + 1)),
                                         GetApplicationEventTarget(), 0, &ref)
            guard st == noErr, let ref else { unregister(); return false }
            refs.append(ref)
        }
        return true
    }
    func unregister() { refs.forEach { UnregisterEventHotKey($0) }; refs = [] }

    /// Tries a new pair live; on failure the saved pair comes back.
    func apply(_ u: Combo, _ d: Combo) -> Bool {
        if register(u, d) { up = u; down = d; ok = true; save(); Log.write("hotkeys: \(pairText)"); return true }
        ok = register(up, down)
        return false
    }
}

/// Keyboard shortcuts window: click a box, press the combination.
struct ShortcutsView: View {
    // Passed in by the caller (main actor): older compilers treat @State defaults as nonisolated.
    @State var up: HotKeys.Combo
    @State var down: HotKeys.Combo
    @State var recording: Int? = nil     // 0 up, 1 down
    @State var error: String? = nil
    @State var monitor: Any? = nil
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Click a box and press the new combination.")
            Text("They change the screen with the active window. Hold ⇧ as well for steps of 1. The brightness keys keep working.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow { Text("Brighter"); box(0, up) }
                GridRow { Text("Dimmer"); box(1, down) }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("Reset to Defaults") { up = HotKeys.defaultUp; down = HotKeys.defaultDown; error = nil }
                Spacer()
                Button("Cancel") { stop(); done() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    stop()
                    if HotKeys.shared.apply(up, down) { done() }
                    else { error = "\(up.text) or \(down.text) is taken by another app (or not allowed by macOS). Try another." }
                }.keyboardShortcut(.defaultAction)
            }.padding(.top, 6)
        }
        .padding(20).frame(width: 380)
        .onAppear { HotKeys.shared.unregister() }   // so pressing the current keys records them instead of firing
        .onDisappear { stop(); HotKeys.shared.ok = HotKeys.shared.register(HotKeys.shared.up, HotKeys.shared.down) }
    }

    func box(_ i: Int, _ c: HotKeys.Combo) -> some View {
        Button { start(i) } label: {
            Text(recording == i ? "Press keys…" : c.text).frame(minWidth: 160).monospaced()
        }
        .accessibilityLabel(i == 0 ? "Brighter shortcut" : "Dimmer shortcut")
    }

    func start(_ i: Int) {
        stop(); recording = i; error = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            let f = e.modifierFlags
            if f.contains(.shift) { error = "Leave ⇧ out: it is added automatically for steps of 1."; return nil }
            if !f.contains(.control) && !f.contains(.command) { error = "Use ⌃ or ⌘ with the key, so it does not clash with typing."; return nil }
            var mods: UInt32 = 0
            if f.contains(.control) { mods |= UInt32(controlKey) }
            if f.contains(.option) { mods |= UInt32(optionKey) }
            if f.contains(.command) { mods |= UInt32(cmdKey) }
            let names: [Int: String] = [kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_LeftArrow: "←", kVK_RightArrow: "→",
                                        kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_Home: "↖", kVK_End: "↘"]
            let ch = names[Int(e.keyCode)] ?? (e.charactersIgnoringModifiers ?? "?").uppercased()
            let c = HotKeys.Combo(key: UInt32(e.keyCode), mods: mods, char: ch)
            if recording == 0 { up = c } else { down = c }
            error = nil; stop()
            return nil
        }
    }
    func stop() { if let m = monitor { NSEvent.removeMonitor(m) }; monitor = nil; recording = nil }
}

@MainActor enum ShortcutsWindow {
    static var window: NSWindow?
    static func show() {
        StatusController.shared?.close()
        if let w = window { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Daylit — Keyboard Shortcuts"; w.isReleasedWhenClosed = false
        w.contentViewController = NSHostingController(rootView: ShortcutsView(up: HotKeys.shared.up, down: HotKeys.shared.down) { window?.close() })
        w.center(); window = w
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            Task { @MainActor in window = nil; StatusController.shared?.model.objectWillChange.send() }
        }
        NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil)
    }
}

// MARK: UI

struct Panel: View {
    @ObservedObject var m: Daylit

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Daylit").font(.system(size: 13, weight: .semibold))
                Spacer()
                Menu {
                    Button("Keyboard Shortcuts…") { ShortcutsWindow.show() }
                    Divider()
                    Button("Open Config File…") { m.openConfig() }
                    Button("Reload Config") { m.reload() }
                    Divider()
                    Button(m.dark ? "Switch to Light Mode" : "Switch to Dark Mode") { m.toggleDark() }
                } label: { Image(systemName: "gearshape") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Settings").accessibilityLabel("Settings")
            }

            if m.mons.isEmpty {
                Text("No external monitors. Plug one in and Daylit takes over; the built-in screen stays with macOS.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 8) { ForEach(m.mons.indices, id: \.self) { i in row(i) } }
            }

            if m.source != .off {
                VStack(alignment: .leading, spacing: 8) {
                    switchRow("Automatic brightness", Binding(get: { m.auto }, set: { m.setAuto($0) }), .small) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Automatic")
                            if !m.detail.isEmpty {
                                Text(m.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }
                    .accessibilityHint(m.detail)
                    switchRow("Light or dark mode from daylight", Binding(get: { m.lookOn }, set: { m.setLook($0) }), .mini) {
                        Text("Light or dark mode from daylight").font(.caption)
                    }
                    if m.hasBattery {
                        switchRow("Pause on battery", Binding(get: { m.pauseOnBattery }, set: { m.setPause($0) }), .mini) {
                            Text("Pause on battery").font(.caption)
                        }
                        .help("On battery: no automatic changes and no Home Assistant traffic. Sliders and keys still work.")
                    }
                }
            } else {
                Text("Set a location or Home Assistant in the config file for automatic brightness.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            if let p = m.problem {
                Label(p, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }

            if !m.mons.isEmpty {
                let k = HotKeys.shared
                Text(k.ok ? "Brightness keys or \(k.pairText) change the screen with the active window. Add ⇧ (⌥⇧ with brightness keys) for fine steps."
                          : "\(k.pairText) are taken by another app; change them in the gear menu. Brightness keys still work (⌥⇧ for fine steps).")
                    .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack {
                Toggle("Open at login", isOn: Binding(get: { m.login }, set: { m.setLogin($0) }))
                    .toggleStyle(.switch).controlSize(.mini).font(.caption)
                    .accessibilityLabel("Open at login")
                Spacer()
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .buttonStyle(.borderless).help("Quit Daylit").accessibilityLabel("Quit Daylit")
            }
        }
        .padding(14)
        .frame(width: 320)

    }

    /// A label on the left and its switch on the right edge, like System Settings.
    func switchRow<L: View>(_ name: String, _ isOn: Binding<Bool>, _ size: SwiftUI.ControlSize, @ViewBuilder label: () -> L) -> some View {
        HStack(alignment: .center, spacing: 8) {
            label()
            Spacer(minLength: 8)
            Toggle(name, isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(size).accessibilityLabel(name)
        }
    }

    func row(_ i: Int) -> some View {
        let mon = m.mons[i]
        let usable = mon.control != .none && mon.available
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "display").foregroundStyle(.secondary).accessibilityHidden(true)
                Text(mon.label).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if mon.manual {
                    Text("Manual").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule()).help("Set by hand: kept until the automatic level moves")
                }
                Spacer()
                Text(usable ? "\(Int(mon.level))%" : "–").font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Image(systemName: "sun.min.fill").font(.system(size: 11)).foregroundStyle(.secondary).accessibilityHidden(true)
                Slider(value: Binding(get: { m.mons.indices.contains(i) ? m.mons[i].level : 0 },
                                      set: { m.setLevel(i, $0.rounded()) }),
                       in: 0...100, onEditingChanged: { m.dragChanged(i, $0) })
                    .controlSize(.small)
                    .accessibilityLabel("\(mon.label) brightness")
                Image(systemName: "sun.max.fill").font(.system(size: 13)).foregroundStyle(.secondary).accessibilityHidden(true)
            }
            .disabled(!usable)
            if !usable {
                Text(mon.control == .none ? "No brightness control found (install m1ddc for DDC monitors)."
                                          : "This monitor did not answer. It may be showing another computer.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))
    }
}

// MARK: app, menu-bar item, second launch

/// The menu-bar item and its panel. Owned here rather than through SwiftUI's MenuBarExtra, which has
/// no way to open its panel from code (needed when the app is opened a second time).
@MainActor final class StatusController: NSObject, NSWindowDelegate {
    static var shared: StatusController?
    let model: Daylit
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let panel: KeyPanel
    var closedAt = Date.distantPast

    final class KeyPanel: NSPanel {
        var onHide: (() -> Void)?
        override var canBecomeKey: Bool { true }
        override func cancelOperation(_ sender: Any?) { orderOut(nil) }   // Esc closes it
        override func orderOut(_ sender: Any?) { super.orderOut(sender); onHide?() }
    }

    init(model: Daylit) {
        self.model = model
        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .statusBar; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.delegate = self
        panel.onHide = { [weak self] in
            self?.item.button?.highlight(false); PanelOpener.visible = false; self?.closedAt = Date()
        }
        panel.setAccessibilityLabel("Daylit")
        let host = NSHostingController(rootView: Panel(m: model)
            .background(VisualEffect().clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)))
        host.sizingOptions = [.preferredContentSize]
        panel.contentViewController = host
        if let b = item.button {
            b.image = NSImage(systemSymbolName: "sun.max", accessibilityDescription: "Daylit")
            b.setAccessibilityLabel("Daylit")
            b.target = self; b.action = #selector(toggle)
        }
    }

    @objc func toggle() {
        if panel.isVisible { close(); return }
        if Date().timeIntervalSince(closedAt) < 0.3 { return }   // this click just closed it
        show()
    }

    func show() {
        model.refresh()
        place()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        item.button?.highlight(true)
        PanelOpener.visible = true
    }

    func close() { panel.orderOut(nil) }

    /// Under the menu-bar item, kept inside the screen.
    func place() {
        guard let b = item.button, let bw = b.window else { return }
        let r = bw.convertToScreen(b.convert(b.bounds, to: nil))
        let size = panel.frame.size
        let vf = (bw.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let x = min(max(r.midX - size.width / 2, vf.minX + 8), vf.maxX - size.width - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: r.minY - size.height - 6))
    }

    func windowDidResignKey(_ n: Notification) { close() }
    func windowDidResize(_ n: Notification) { if panel.isVisible { place() } }   // content grew: keep the top under the item
}

/// Control Center-style background: the menu material, tinted with the window colour so text behind
/// the panel does not show through.
struct VisualEffect: View {
    var body: some View {
        ZStack {
            Blur()
            Color(nsColor: .windowBackgroundColor).opacity(0.72)
        }
    }
    struct Blur: NSViewRepresentable {
        func makeNSView(context: Context) -> NSVisualEffectView {
            let v = NSVisualEffectView(); v.material = .menu; v.blendingMode = .behindWindow; v.state = .active; return v
        }
        func updateNSView(_ v: NSVisualEffectView, context: Context) {}
    }
}

@MainActor enum PanelOpener {
    static var visible = false
    static func open() { StatusController.shared?.show() }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    static let showNote = Notification.Name("app.daylit.mac.show")
    var model: Daylit?

    func applicationDidFinishLaunching(_ n: Notification) {
        if let a = ProcessInfo.processInfo.environment["DAYLIT_APPEARANCE"] {   // screenshots: force light or dark
            NSApp.appearance = NSAppearance(named: a == "dark" ? .darkAqua : .aqua)
        }
        let m = Daylit()
        model = m
        StatusController.shared = StatusController(model: m)
        // A second copy started from the binary (not through Launch Services) asks this one to show itself.
        DistributedNotificationCenter.default().addObserver(forName: Self.showNote, object: nil, queue: .main) { _ in
            Task { @MainActor in PanelOpener.open() }
        }
        if ProcessInfo.processInfo.environment["DAYLIT_SHOW"] == "panel" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { PanelOpener.open() }
        }
    }
    /// Opening the app again (Finder, Spotlight, `open -a Daylit`) shows the panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        PanelOpener.open()
        return false
    }
}

struct DaylitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene { Settings { EmptyView() } }
}

@main enum Main {
    static func main() {
        if let code = CLI.run(Array(CommandLine.arguments.dropFirst())) { exit(code) }
        let me = ProcessInfo.processInfo.processIdentifier
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0.processIdentifier != me }) {
            DistributedNotificationCenter.default().postNotificationName(AppDelegate.showNote, object: nil, userInfo: nil, deliverImmediately: true)
            exit(0)
        }
        DaylitApp.main()
    }
}

// MARK: command line (see AGENTS.md)

/// `Daylit --list-monitors` / `--check-config`: JSON on stdout, exit 0 when fine, 1 when something needs fixing.
@MainActor enum CLI {
    static let help = """
        Daylit — monitor brightness from the sun or Home Assistant.
          Daylit                  start the menu-bar app
          Daylit --list-monitors  connected monitors as JSON (use "match" in config.json)
          Daylit --check-config   validate \(Config.path.path)
        Run it from the app bundle: ~/Applications/Daylit.app/Contents/MacOS/Daylit --list-monitors
        """

    static func run(_ args: [String]) -> Int32? {
        // Launch Services may pass -psn_… or -NSDocumentRevisionsDebugMode; only our flags count.
        guard let cmd = args.first?.lowercased(), ["--list-monitors", "--check-config", "--help", "-h"].contains(cmd) else { return nil }
        _ = NSApplication.shared   // NSScreen needs the app object
        switch cmd {
        case "--list-monitors": return emit(listMonitors(), 0)
        case "--check-config": let (j, ok) = checkConfig(); return emit(j, ok ? 0 : 1)
        default: print(help); return 0
        }
    }

    static func emit(_ obj: Any, _ code: Int32) -> Int32 {
        if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
           let s = String(data: d, encoding: .utf8) { print(s) }
        return code
    }

    /// A short, stable part of the name: the model ("AW3821DW") rather than the brand.
    static func suggestMatch(_ name: String) -> String {
        name.split(separator: " ").last { t in t.contains(where: \.isNumber) && t.contains(where: \.isLetter) }.map(String.init) ?? name
    }

    static func listMonitors() -> [String: Any] {
        let (cfg, _) = Config.load()
        DDC.tool = cfg.ddcTool ?? DDC.defaultTool
        var out: [[String: Any]] = []
        for s in NSScreen.screens {
            guard let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { continue }
            let builtIn = CGDisplayIsBuiltin(id) != 0
            let uuid = CGDisplayCreateUUIDFromDisplayID(id).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String } ?? ""
            let entry = cfg.monitors?.first { s.localizedName.localizedCaseInsensitiveContains($0.match) }
            var control = "none", level: Int? = nil
            if builtIn { control = "none (built-in screens are left to macOS)" }
            else {
                let forced = entry?.control
                if forced != "ddc", let v = Native.get(id) { control = "native"; level = v }
                else if forced != "native", DDC.available { control = "ddc"; level = DDC.get(uuid) }
                else if forced == "native" { control = "native" }
                else { control = "none (install m1ddc for DDC monitors)" }
            }
            var o: [String: Any] = ["name": s.localizedName, "match": suggestMatch(s.localizedName), "uuid": uuid,
                                    "builtIn": builtIn, "control": control, "controllable": !builtIn && level != nil]
            o["brightness"] = level ?? NSNull()
            o["configuredAs"] = entry.map { ($0.label ?? $0.match) as Any } ?? NSNull()
            out.append(o)
        }
        return ["monitors": out]
    }

    static func checkConfig() -> ([String: Any], Bool) {
        let exists = FileManager.default.fileExists(atPath: Config.path.path)
        let (cfg, err) = Config.load()
        let (src, srcErr) = cfg.resolvedSource()
        var problems: [String] = [], notes: [String] = []
        if let err { problems.append(err) }
        if let srcErr { problems.append(srcErr) }
        let names = externalScreens().map(\.name)
        var monitors: [[String: Any]] = []
        for m in cfg.monitors ?? [] {
            let hit = names.first { $0.localizedCaseInsensitiveContains(m.match) }
            if m.homeAssistant != nil && src != .homeAssistant {
                problems.append("monitor \"\(m.match)\" has homeAssistant entities but the source is \(src)")
            }
            if let c = m.control, !["native", "ddc", "auto"].contains(c) {
                problems.append("monitor \"\(m.match)\": control must be native, ddc or auto")
            }
            if hit == nil { notes.append("monitor \"\(m.match)\" is not connected right now (fine if it is used elsewhere)") }
            monitors.append(["match": m.match, "label": (m.label ?? NSNull()) as Any, "connected": (hit ?? NSNull()) as Any])
        }
        if !exists { notes.append("no config.json: Daylit runs with sliders and brightness keys only") }
        if (cfg.monitors ?? []).contains(where: { $0.control != "native" }) || cfg.monitors == nil, !DDC.available {
            notes.append("m1ddc not found: DDC monitors need it (brew install m1ddc)")
        }
        var result: [String: Any] = ["ok": problems.isEmpty, "path": Config.path.path, "exists": exists,
                                     "source": "\(src)", "problems": problems, "notes": notes, "monitors": monitors]
        if src == .homeAssistant, let ha = cfg.homeAssistant {
            let name = ha.tokenName ?? "daylit-home-assistant"
            let stored = HAClient.tokenStored(name)   // presence only, never read or printed
            if !stored { notes.append("no Home Assistant token in the keychain as \"\(name)\" (see README; the user adds it)") }
            result["notes"] = notes
            result["homeAssistant"] = ["url": (ha.url ?? NSNull()) as Any, "tokenName": name, "tokenStored": stored]
        } else {
            result["homeAssistant"] = NSNull()
        }
        return (result, problems.isEmpty)
    }
}
