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
    var level: Double = 0
    var available = true
    var manual = false
    var lastSet: Int? = nil, lastTarget: Int? = nil, published: Int? = nil
    var remoteSeen: Double? = nil    // last_changed of the HA "set" helper already acted on
}
