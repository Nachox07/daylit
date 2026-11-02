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

let DEBUG = ProcessInfo.processInfo.environment["DAYLIT_DEBUG"] == "1"
func log(_ s: @autoclosure () -> String) { if DEBUG { print("[daylit] " + s()); fflush(stdout) } }

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
    NSScreen.screens.compactMap { s in
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
}

func idleSeconds() -> Double {
    CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
}

// MARK: Home Assistant

struct HAState: Decodable {
    let elev, pos: Double
    let lights: Bool
    let auto: Bool?                  // nil when there is no autoSwitch
    let m: [String: [Double]]        // per display UUID: [day, blindDown, night]; -1 = use the local value
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

    /// One template call returns everything a tick needs.
    static func template(_ ha: HAConfig, _ mons: [Mon]) -> String {
        let pos = ha.cover.map { "state_attr('\($0)','current_position') | float(100)" } ?? "100"
        let lights = ha.lights.map { "is_state('\($0)','on') | tojson" } ?? "false | tojson"   // bare false renders as Python False
        let auto = ha.autoSwitch.map { "{{ is_state('\($0)','on') | tojson }}" } ?? "null"   // null outside {{ }}: Jinja has no null
        func num(_ e: String?) -> String { e.map { "{{ states('\($0)') | float(-1) }}" } ?? "-1" }
        let m = mons.compactMap { mon -> String? in
            guard let h = mon.ha, h.day != nil || h.blindDown != nil || h.night != nil else { return nil }
            return "\"\(mon.uuid)\": [\(num(h.day)), \(num(h.blindDown)), \(num(h.night))]"
        }.joined(separator: ", ")
        return """
        {"elev": {{ state_attr('\(ha.sun ?? "sun.sun")','elevation') | float(-10) }},
         "pos": {{ \(pos) }},
         "lights": {{ \(lights) }},
         "auto": \(auto),
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
            guard let s = try? JSONDecoder().decode(HAState.self, from: d), s.m.values.allSatisfy({ $0.count == 3 })
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
            if let o = old[s.uuid] { m.level = o.level; m.lastSet = o.lastSet; m.lastTarget = o.lastTarget }
            if control == .native, let v = Native.get(s.id) { m.level = Double(v) }
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
        let here = idleSeconds() < Self.idleLimit
        if here && !wasHere {
            // Back at this Mac: publish again even if nothing changed, in case another machine wrote meanwhile.
            log("user is back")
            for i in mons.indices { mons[i].published = nil }
            wasHere = here
            refresh(); return
        }
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

    struct Inputs { let elev, pos: Double; let lights: Bool; let levels: [String: [Double]]; let line: String }

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
        guard let inp = await inputs(), gen == generation else { return }

        let sun = min(max((inp.elev + 3) / 15, 0), 1)
        let here = idleSeconds() < Self.idleLimit
        if !here {
            detail = auto ? "Paused — this Mac is idle" : inp.line
            log("tick (idle): \(detail)")
            return   // the other machine on these monitors may be in use: don't fight it
        }
        let hold = config.manualHold ?? 5
        for i in mons.indices {
            guard let c = cur[i] else { continue }
            let m = mons[i]
            var lv = [m.day, m.blindDown, m.night]
            if let ov = inp.levels[m.uuid] { for k in 0..<3 where ov[k] >= 0 { lv[k] = ov[k] } }
            let want = target(day: lv[0], blindDown: lv[1], night: lv[2], elev: inp.elev, pos: inp.pos, lights: inp.lights)
            var applied = c, manual = false
            if auto && !dragging.contains(m.id) {
                let handSet = m.lastSet != nil && c != m.lastSet!
                if handSet && abs(want - (m.lastTarget ?? want)) < hold {
                    manual = true
                } else {
                    if c != want { write(m, want) }
                    applied = want; mons[i].lastSet = want; mons[i].lastTarget = want; mons[i].level = Double(want)
                }
            }
            mons[i].manual = manual
            if source == .homeAssistant, let ha = config.homeAssistant, let sensor = m.ha?.sensor, m.published != applied {
                let r = await HAClient.call(ha, "/api/states/" + sensor, ["state": applied, "attributes": [
                    "friendly_name": "\(m.label) brightness", "unit_of_measurement": "%", "icon": "mdi:monitor",
                    "target": want, "manual": manual, "daylight": (sun * 100).rounded() / 100,
                    "sun_elevation": inp.elev, "blind": inp.pos, "lights": inp.lights, "source": "macOS"]])
                guard gen == generation else { return }
                if case .success = r { mons[i].published = applied }   // retried next tick if the post failed
            }
        }
        detail = inp.line
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
                if let a = s.auto { auto = a } else { auto = UserDefaults.standard.object(forKey: "auto") as? Bool ?? true }
                let sun = Int((min(max((s.elev + 3) / 15, 0), 1) * 100).rounded())
                var line = "Home Assistant · sun \(sun)%"
                if ha.cover != nil { line += " · blind \(Int(s.pos))%" }
                if ha.lights != nil && s.lights { line += " · lights on" }
                return Inputs(elev: s.elev, pos: s.pos, lights: s.lights, levels: s.m, line: line)
            case .failure(let f):
                problem = HAClient.describe(f, ha)
                log("Home Assistant: \(problem ?? "")")
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
                    Image(systemName: "display").foregroundStyle(.secondary)
                    Text(label).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer()
                    Text("\(Int(v))%").font(.system(size: 13, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Image(systemName: "sun.min.fill").font(.system(size: 11)).foregroundStyle(.secondary)
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.quaternary)
                            Capsule().fill(.primary).frame(width: max(6, g.size.width * v / 100))
                        }
                    }.frame(height: 6)
                    Image(systemName: "sun.max.fill").font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .frame(width: size.width, height: size.height)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous)))
        let f = screen.frame
        p.setFrame(NSRect(x: f.midX - size.width / 2, y: f.minY + f.height * 0.12, width: size.width, height: size.height), display: true)
        p.alphaValue = 1; p.orderFrontRegardless()
        hide?.cancel()
        let w = DispatchWorkItem { NSAnimationContext.runAnimationGroup { $0.duration = 0.3; p.animator().alphaValue = 0 } }
        hide = w; DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: w)
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
                    Button("Open Config File…") { m.openConfig() }
                    Button("Reload Config") { m.reload() }
                } label: { Image(systemName: "gearshape") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Settings")
            }

            if m.mons.isEmpty {
                Text("No external monitor connected. The brightness keys control the built-in screen.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 8) { ForEach(m.mons.indices, id: \.self) { i in row(i) } }
            }

            if m.source != .off {
                Toggle(isOn: Binding(get: { m.auto }, set: { m.setAuto($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Automatic")
                        if !m.detail.isEmpty {
                            Text(m.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
                .toggleStyle(.switch).controlSize(.small)
            } else {
                Text("Set a location or Home Assistant in the config file for automatic brightness.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            if let p = m.problem {
                Label(p, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }

            if !m.mons.isEmpty {
                Text("Brightness keys change the screen with the active window. ⌥⇧ for fine steps.")
                    .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack {
                Toggle("Open at login", isOn: Binding(get: { m.login }, set: { m.setLogin($0) }))
                    .toggleStyle(.switch).controlSize(.mini).font(.caption)
                Spacer()
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .buttonStyle(.borderless).help("Quit Daylit")
            }
        }
        .padding(14)
        .frame(width: 320)
        .onAppear { m.refresh() }
    }

    func row(_ i: Int) -> some View {
        let mon = m.mons[i]
        let usable = mon.control != .none && mon.available
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "display").foregroundStyle(.secondary)
                Text(mon.label).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if mon.manual {
                    Text("Manual").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule()).help("Set by hand: kept until the automatic level moves")
                }
                Spacer()
                Text(usable ? "\(Int(mon.level))%" : "–").font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Image(systemName: "sun.min.fill").font(.system(size: 11)).foregroundStyle(.secondary)
                Slider(value: Binding(get: { m.mons.indices.contains(i) ? m.mons[i].level : 0 },
                                      set: { m.setLevel(i, $0.rounded()) }),
                       in: 0...100, onEditingChanged: { m.dragChanged(i, $0) })
                    .controlSize(.small)
                Image(systemName: "sun.max.fill").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .disabled(!usable)
            if !usable {
                Text(mon.control == .none ? "No brightness control found (install m1ddc for DDC monitors)."
                                          : "This monitor did not answer. It may be showing another computer.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.6)))
    }
}

@main struct DaylitApp: App {
    @StateObject var m = Daylit()
    var body: some Scene {
        MenuBarExtra("Daylit", systemImage: "sun.max") { Panel(m: m) }.menuBarExtraStyle(.window)
    }
}
