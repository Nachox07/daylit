// Daylit for macOS — menu-bar app that keeps external monitors at the right brightness,
// driven by Home Assistant (sun, a window blind, room lights). See README.md.
//
//  - "native" monitors: macOS's own brightness API (DisplayServices). Works while HDR is on,
//    when most monitors ignore DDC brightness.
//  - "ddc" monitors: DDC/CI through m1ddc (brew install m1ddc).
//  - Settings live in ~/.config/daylit/config.json; the Home Assistant token in the keychain.
import SwiftUI
import AppKit
import CoreGraphics
import ServiceManagement
import ApplicationServices

// MARK: config

struct MonitorConfig: Decodable {
    let match: String            // part of the display name (case-insensitive)
    let label: String            // shown in the menu and the on-screen indicator
    let control: String?         // "native" or "ddc" (default "ddc")
    let sensor: String           // HA sensor this app publishes, e.g. sensor.daylit_left_monitor
    let day: String              // input_number: daytime level, blind open
    let blindDown: String        // input_number: daytime level, blind closed
    let night: String            // input_number: night level
    var native: Bool { control == "native" }
}

struct Config: Decodable {
    // A missing required key fails decoding, so the app shows the error instead of running half-configured.
    let homeAssistantUrl: String
    let tokenName: String?       // keychain service holding the long-lived token
    let autoSwitch: String       // input_boolean that turns automatic mode on/off
    let sun: String?             // default sun.sun
    let cover: String?           // optional cover (blind); its position scales the daytime level
    let lights: String?          // optional light; on at night = a little brighter
    let manualHold: Int?         // a hand-set value stays until the target moves this much (default 5)
    let ddcTool: String?         // path to m1ddc; default: Homebrew's (Apple silicon or Intel)
    let monitors: [MonitorConfig]

    static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/daylit/config.json")
    static func load() -> (Config?, String?) {
        guard let d = try? Data(contentsOf: path) else { return (nil, "Missing \(path.path) (see config.example.json)") }
        do {
            let c = try JSONDecoder().decode(Config.self, from: d)
            return c.monitors.isEmpty ? (nil, "config.json: no monitors") : (c, nil)
        }
        catch { return (nil, "Invalid config.json: \(error.localizedDescription)") }
    }
}

let (CONFIG, CONFIG_ERROR) = Config.load()

// MARK: displays

enum Native {
    typealias GetF = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    typealias SetF = @convention(c) (UInt32, Float) -> Int32
    static let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
    static let getF = unsafeBitCast(dlsym(h, "DisplayServicesGetBrightness"), to: GetF.self)
    static let setF = unsafeBitCast(dlsym(h, "DisplayServicesSetBrightness"), to: SetF.self)

    static func id(named name: String) -> CGDirectDisplayID? {
        for s in NSScreen.screens where s.localizedName.localizedCaseInsensitiveContains(name) {
            return s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        }
        return nil
    }
    static func get(_ name: String) -> Int? {
        guard let id = id(named: name) else { return nil }
        var b: Float = -1
        return getF(id, &b) == 0 && b >= 0 ? Int((b * 100).rounded()) : nil
    }
    static func set(_ name: String, _ v: Int) {
        if let id = id(named: name) { _ = setF(id, Float(v) / 100) }
    }
}

enum DDC {
    static let tool: String = CONFIG?.ddcTool
        ?? ["/opt/homebrew/bin/m1ddc", "/usr/local/bin/m1ddc"].first { FileManager.default.isExecutableFile(atPath: $0) }
        ?? "/opt/homebrew/bin/m1ddc"
    static func run(_ args: [String]) -> String? {
        let p = Process(); p.executableURL = URL(fileURLWithPath: tool); p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        let s = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return p.terminationStatus == 0 ? s : nil
    }
    static func index(_ name: String) -> String? {
        run(["display", "list"])?.split(separator: "\n").first { $0.localizedCaseInsensitiveContains(name) }
            .map { String($0.split(separator: "]")[0].dropFirst()) }
    }
    static func get(_ name: String) -> Int? {
        guard let i = index(name), let s = run(["display", i, "get", "luminance"]) else { return nil }
        return Int(s)
    }
    static func set(_ name: String, _ v: Int) {
        if let i = index(name) { _ = run(["display", i, "set", "luminance", String(v)]) }
    }
}

// MARK: Home Assistant

struct HAState: Decodable {
    let elev, pos: Double
    let lights, auto: Bool
    let m: [[Double]]   // per monitor: [day, blindDown, night]
}

enum HAClient {
    static let token: String? = {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", CONFIG?.tokenName ?? "daylit-home-assistant", "-w"]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        try? p.run(); p.waitUntilExit()
        let s = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return s?.isEmpty == false ? s : nil
    }()

    /// One template call returns everything a tick needs.
    static let template: String = {
        guard let c = CONFIG else { return "" }
        let pos = c.cover.map { "state_attr('\($0)','current_position') | float(100)" } ?? "100"
        let lights = c.lights.map { "is_state('\($0)','on') | tojson" } ?? "false | tojson"   // bare false renders as Python False
        let mons = c.monitors.map {
            "[{{ states('\($0.day)') | float(70) }}, {{ states('\($0.blindDown)') | float(40) }}, {{ states('\($0.night)') | float(20) }}]"
        }.joined(separator: ", ")
        return """
        {"elev": {{ state_attr('\(c.sun ?? "sun.sun")','elevation') | float(-10) }},
         "pos": {{ \(pos) }},
         "lights": {{ \(lights) }},
         "auto": {{ is_state('\(c.autoSwitch)','on') | tojson }},
         "m": [\(mons)]}
        """
    }()

    static func call(_ path: String, _ body: [String: Any]) async -> Data? {
        guard let token, let c = CONFIG else { return nil }
        let base = c.homeAssistantUrl.hasSuffix("/") ? String(c.homeAssistantUrl.dropLast()) : c.homeAssistantUrl
        guard let url = URL(string: base + path) else { return nil }
        var r = URLRequest(url: url, timeoutInterval: 6)
        r.httpMethod = "POST"
        r.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (d, resp) = try? await URLSession.shared.data(for: r),
              (resp as? HTTPURLResponse)?.statusCode ?? 0 < 300 else { return nil }
        return d
    }
    static func state() async -> HAState? {
        guard let d = await call("/api/template", ["template": template]) else { return nil }
        return try? JSONDecoder().decode(HAState.self, from: d)
    }
}

// MARK: model

struct Monitor {
    let cfg: MonitorConfig
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
    @Published var level: [Double]
    @Published var connected: [Bool]
    @Published var auto = true
    @Published var status = CONFIG_ERROR ?? "Connecting…"
    @Published var login = SMAppService.mainApp.status == .enabled
    var mons: [Monitor]
    let ddcQ = DispatchQueue(label: "ddc")
    var pending: [Int: DispatchWorkItem] = [:]
    var busy = false, wasHere = false

    init() {
        mons = (CONFIG?.monitors ?? []).map { Monitor(cfg: $0) }
        level = Array(repeating: 0, count: mons.count)
        connected = Array(repeating: false, count: mons.count)
        guard CONFIG != nil else { return }
        if HAClient.token == nil { status = "No token in the keychain (see README)" }
        Keys.shared.start(self)
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in Task { @MainActor in await self.tick() } }
        Task { await tick() }
    }

    func read(_ i: Int) -> Int? { mons[i].cfg.native ? Native.get(mons[i].cfg.match) : DDC.get(mons[i].cfg.match) }
    func write(_ i: Int, _ v: Int) {
        let c = mons[i].cfg
        if c.native { Native.set(c.match, v); return }
        ddcQ.async { DDC.set(c.match, v) }
    }
    /// Slider moves: apply right away (DDC is debounced, it is slow).
    func userSet(_ i: Int, _ v: Double) {
        let c = mons[i].cfg
        if c.native { Native.set(c.match, Int(v)); return }
        pending[i]?.cancel()
        let w = DispatchWorkItem { DDC.set(c.match, Int(v)) }
        pending[i] = w; ddcQ.asyncAfter(deadline: .now() + 0.15, execute: w)
    }
    /// Brightness keys: change the monitor that holds the focused window.
    func key(up: Bool, fine: Bool, on i: Int) {
        let step = Double(fine ? 1 : 6)
        level[i] = min(max(level[i] + (up ? step : -step), 0), 100)
        userSet(i, level[i])
        HUD.show(mons[i].cfg.label, level[i], on: mons[i].cfg.match)
    }
    func setAuto(_ on: Bool) {
        auto = on
        guard let sw = CONFIG?.autoSwitch else { return }
        Task { _ = await HAClient.call("/api/services/input_boolean/" + (on ? "turn_on" : "turn_off"), ["entity_id": sw]) }
        if on { for i in mons.indices { mons[i].lastSet = nil }; Task { await tick() } }
    }
    func setLogin(_ on: Bool) {
        try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
        login = SMAppService.mainApp.status == .enabled
    }

    func tick() async {
        if busy { return }; busy = true; defer { busy = false }
        var cur: [Int?] = []
        for i in mons.indices {
            if mons[i].cfg.native { cur.append(read(i)) }   // NSScreen: main thread only
            else { cur.append(await withCheckedContinuation { c in ddcQ.async { c.resume(returning: self.readOffMain(i)) } }) }
        }
        for i in mons.indices { connected[i] = cur[i] != nil; if let v = cur[i] { level[i] = Double(v) } }
        guard let s = await HAClient.state(), s.m.count == mons.count, s.m.allSatisfy({ $0.count == 3 }) else {
            status = HAClient.token == nil ? "No token in the keychain (see README)" : "Cannot reach Home Assistant"; return
        }
        auto = s.auto
        let sun = min(max((s.elev + 3) / 15, 0), 1)
        // Only the machine in use publishes, so a Mac and a PC on the same monitors don't overwrite each
        // other; coming back to this one publishes again even if nothing changed.
        let here = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!) < 300
        if here && !wasHere { for i in mons.indices { mons[i].published = nil } }
        wasHere = here
        var notes: [String] = []
        for i in mons.indices {
            guard let c = cur[i] else { continue }
            let v = s.m[i]
            let want = target(day: v[0], blindDown: v[1], night: v[2], elev: s.elev, pos: s.pos, lights: s.lights)
            var applied = c, manual = false
            if s.auto {
                let handSet = mons[i].lastSet != nil && c != mons[i].lastSet!
                if handSet && abs(want - (mons[i].lastTarget ?? want)) < (CONFIG?.manualHold ?? 5) {
                    manual = true
                } else {
                    if c != want { write(i, want) }
                    applied = want; mons[i].lastSet = want; mons[i].lastTarget = want; level[i] = Double(want)
                }
                notes.append(manual ? "manual" : "auto \(want)%")
            }
            if here && mons[i].published != applied {
                let ok = await HAClient.call("/api/states/" + mons[i].cfg.sensor, ["state": applied, "attributes": [
                    "friendly_name": "\(mons[i].cfg.label) brightness", "unit_of_measurement": "%", "icon": "mdi:monitor",
                    "target": want, "manual": manual, "daylight": (sun * 100).rounded() / 100,
                    "sun_elevation": s.elev, "blind": s.pos, "lights": s.lights, "source": "macOS"]])
                if ok != nil { mons[i].published = applied }   // retried next tick if the post failed
            }
        }
        status = s.auto ? "Sun \(Int(sun * 100))% · blind \(Int(s.pos))% · " + notes.joined(separator: " · ") : "Automatic mode off"
    }
    nonisolated func readOffMain(_ i: Int) -> Int? {
        guard let c = CONFIG?.monitors[i] else { return nil }
        return DDC.get(c.match)
    }
}

// MARK: keys, focus, on-screen indicator

enum Focus {
    /// Index of the configured monitor holding the focused window, or nil (built-in screen or
    /// an unconfigured one). nil leaves the brightness key to macOS, so the laptop screen works natively.
    @MainActor static func managedMonitor() -> Int? {
        guard let name = screenName() else { return nil }
        return CONFIG?.monitors.firstIndex { name.localizedCaseInsensitiveContains($0.match) }
    }
    /// Name of the screen holding the frontmost app's front window (falls back to the mouse).
    static func screenName() -> String? {
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
        return NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == id }?.localizedName
    }
}

final class Keys {
    static let shared = Keys()
    weak var model: Daylit?
    var tap: CFMachPort?

    func start(_ m: Daylit) {
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
                guard kc == 144 || kc == 145, let i = MainActor.assumeIsolated({ Focus.managedMonitor() }) else {
                    return Unmanaged.passUnretained(event)
                }
                if type == .keyDown {
                    let f = event.flags
                    let fine = f.contains(.maskAlternate) && f.contains(.maskShift)
                    DispatchQueue.main.async { Keys.shared.model?.key(up: kc == 144, fine: fine, on: i) }
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
            guard let i = MainActor.assumeIsolated({ Focus.managedMonitor() }) else { return Unmanaged.passUnretained(event) }
            if down {
                let fine = ns.modifierFlags.contains(.option) && ns.modifierFlags.contains(.shift)
                DispatchQueue.main.async { Keys.shared.model?.key(up: code == 2, fine: fine, on: i) }
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
    static func show(_ label: String, _ v: Double, on match: String) {
        guard let screen = NSScreen.screens.first(where: { $0.localizedName.localizedCaseInsensitiveContains(match) }) else { return }
        let size = NSSize(width: 220, height: 64)
        let p = panel ?? {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .statusBar; p.isOpaque = false; p.backgroundColor = .clear; p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel = p; return p
        }()
        p.contentView = NSHostingView(rootView:
            VStack(spacing: 8) {
                HStack { Image(systemName: "sun.max.fill"); Text(label); Spacer(); Text("\(Int(v))%").monospacedDigit() }
                ProgressView(value: v, total: 100)
            }.padding(14).frame(width: size.width, height: size.height)
             .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14)))
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
            ForEach(m.mons.indices, id: \.self) { i in
                if m.connected[i] { row(i) }
            }
            Text(m.connected.contains(true)
                 ? "Brightness keys: the screen with the active window (built-in screen works as usual) · ⌥⇧ = fine steps"
                 : "No configured monitor connected: brightness keys control the built-in screen")
                .font(.caption2).foregroundStyle(.secondary)
            Toggle("Automatic (sun, blind, lights)", isOn: Binding(get: { m.auto }, set: { m.setAuto($0) }))
            Text(m.status).font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                Toggle("Open at login", isOn: Binding(get: { m.login }, set: { m.setLogin($0) })).font(.caption)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.font(.caption)
            }
        }.padding(14).frame(width: 300)
    }
    func row(_ i: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack { Label(m.mons[i].cfg.label, systemImage: "sun.max"); Spacer(); Text("\(Int(m.level[i]))%").monospacedDigit() }
            Slider(value: Binding(get: { m.level[i] }, set: { m.level[i] = $0.rounded(); m.userSet(i, $0.rounded()) }), in: 0...100)
        }
    }
}

@main struct DaylitApp: App {
    @StateObject var m = Daylit()
    var body: some Scene {
        MenuBarExtra("Daylit", systemImage: "sun.max") { Panel(m: m) }.menuBarExtraStyle(.window)
    }
}
