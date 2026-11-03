// Brightness keys (event tap, needs Accessibility) and the global keyboard shortcuts (Carbon hot keys).
import AppKit
import ApplicationServices
import Carbon.HIToolbox

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
