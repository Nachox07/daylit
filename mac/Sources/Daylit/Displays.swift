// External displays and how their brightness is read and set: macOS's own API (DisplayServices,
// works with HDR on) or DDC/CI through m1ddc. Also power source and idle time.
import AppKit
import CoreGraphics
import IOKit.ps
import DaylitCore

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

/// The laptop's own screen while the lid is open. Shown in the panel for manual use only: automatic
/// mode never touches it (macOS's auto-brightness and light sensor do that job better).
struct BuiltIn: Equatable { let id: CGDirectDisplayID; let name: String; var level: Double }

@MainActor func builtInScreen() -> BuiltIn? {
    for s in NSScreen.screens {
        guard let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              CGDisplayIsBuiltin(id) != 0, let v = Native.get(id) else { continue }
        return BuiltIn(id: id, name: s.localizedName, level: Double(v))
    }
    return nil
}

enum Native {
    typealias GetF = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    typealias SetF = @convention(c) (UInt32, Float) -> Int32
    static let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
    static let getF: GetF? = dlsym(h, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: GetF.self) }
    static let setF: SetF? = dlsym(h, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: SetF.self) }
    typealias CanF = @convention(c) (UInt32) -> Bool
    static let canF: CanF? = dlsym(h, "DisplayServicesCanChangeBrightness").map { unsafeBitCast($0, to: CanF.self) }
    /// macOS can set this display's brightness right now. External monitors usually only qualify while
    /// HDR is on, so this changes when HDR is switched on or off.
    static func usable(_ id: CGDirectDisplayID) -> Bool { (canF?(id) ?? true) && get(id) != nil }

    static func get(_ id: CGDirectDisplayID) -> Int? {
        guard let getF else { return nil }
        var b: Float = -1
        return getF(id, &b) == 0 && b >= 0 ? Int((b * 100).rounded()) : nil
    }
    /// True when macOS accepted the change.
    @discardableResult static func set(_ id: CGDirectDisplayID, _ v: Int) -> Bool { setF?(id, Float(v) / 100) == 0 }
}

/// DDC/CI through m1ddc, addressing the display by its system UUID (the same one CoreGraphics reports).
enum DDC {
    nonisolated(unsafe) static var tool = defaultTool
    static let defaultTool = ["/opt/homebrew/bin/m1ddc", "/usr/local/bin/m1ddc"]
        .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/opt/homebrew/bin/m1ddc"
    static var available: Bool { FileManager.default.isExecutableFile(atPath: tool) }
    /// Why DDC isn't available here: m1ddc only exists for Apple silicon.
    static var hint: String {
        #if arch(arm64)
        return "install m1ddc for DDC monitors"
        #else
        return "DDC needs an Apple-silicon Mac"
        #endif
    }
    static var missingNote: String {
        #if arch(arm64)
        return "m1ddc not found: DDC monitors need it (brew install m1ddc)"
        #else
        return "DDC monitors are not supported on Intel Macs (m1ddc is Apple silicon only); monitors that accept macOS's own brightness control still work"
        #endif
    }

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
    /// True when m1ddc reports success (the monitor acknowledged the write).
    @discardableResult static func set(_ uuid: String, _ v: Int) -> Bool { run(["display", uuid, "set", "luminance", String(v)]) != nil }
    /// Contrast (VCP 0x12). True when the monitor acknowledged the write.
    static func setContrast(_ uuid: String, _ v: Int) -> Bool { run(["display", uuid, "set", "contrast", String(v)]) != nil }
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

func idleSeconds() -> Double {
    CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
}

enum Control: String { case native, ddc, none }

struct Mon: Identifiable {
    let id: CGDirectDisplayID
    let uuid: String
    let name: String
    let label: String
    let control: Control
    let day, blindDown, night: Double
    let ha: MonitorHA?
    var contrast: Double? = nil   // config: fixed DDC contrast, written by Daylit.applyContrast
    var contrastSet: Int? = nil   // written since this monitor was (re)detected (ContrastRule)
    var level: Double = 0
    var available = true
    var readState: ReadState = .unknown   // DDC only: does it report its level (DaylitCore)
    var manual = false
    var lastSet: Int? = nil, lastTarget: Int? = nil, published: Int? = nil
    var offset: Int? = nil, offsetSun: Double? = nil, offsetAt: Double? = nil   // a hand-set level as a distance from the target (DaylitCore.decide)
    var publishedManual = false   // the manual flag last sent to Home Assistant
    var publishedLight: Int?      // and the sky's clearness, in tenths
    var touched = false   // moved with the slider or keys since the last tick
    var remoteSeen: Double? = nil    // last_changed of the HA "set" helper already acted on
    var noControl: String? = nil     // why nothing can set this monitor right now, shown on its row
    var writeFailing = false         // the last automatic write was refused (logged once, retried each tick)
}
