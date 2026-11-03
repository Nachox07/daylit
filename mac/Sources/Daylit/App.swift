// Daylit for macOS: menu-bar app that keeps external monitors at the right brightness.
// Works with no setup (sliders, brightness keys, on-screen indicator); automatic brightness comes
// from the sun at your location, or from Home Assistant (sun, a window blind, room lights). See README.md.
//
//  - "native" monitors: macOS's own brightness API (DisplayServices). Works while HDR is on,
//    when most monitors ignore DDC brightness.
//  - "ddc" monitors: DDC/CI through m1ddc (brew install m1ddc; Apple silicon only).
//  - Settings live in ~/.config/daylit/config.json (DAYLIT_CONFIG overrides the path); the Home
//    Assistant token in the keychain. DAYLIT_DEBUG=1 logs to stdout.
import SwiftUI
import AppKit

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

    /// DAYLIT_SHOW=panel (screenshots, recordings): the panel stays open when another app has focus.
    static let pinned = ProcessInfo.processInfo.environment["DAYLIT_SHOW"] == "panel"
    func windowDidResignKey(_ n: Notification) { if !Self.pinned { close() } }
    func windowDidResize(_ n: Notification) { if panel.isVisible { place() } }   // content grew: keep the top under the item
}

/// Control Center-style background: the menu material, tinted with the window colour so text behind
/// the panel does not show through.
struct VisualEffect: View {
    var body: some View {
        ZStack {
            Blur()
            // Opaque enough that text behind the panel never shows through, in light or dark.
            // With Reduce Transparency on, fully opaque.
            Color(nsColor: .windowBackgroundColor)
                .opacity(NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? 1 : 0.9)
        }
    }
    struct Blur: NSViewRepresentable {
        func makeNSView(context: Context) -> NSVisualEffectView {
            let v = NSVisualEffectView(); v.material = .menu; v.blendingMode = .behindWindow; v.state = .active
            v.isEmphasized = true
            return v
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { TokenWindow.askIfMissing(m) }
    }
    /// Opening the app again (Finder, Spotlight, `open -a Daylit`) shows the panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        PanelOpener.open()
        return false
    }
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
        // Plain AppKit run loop: the app has no windows of its own besides the panel, so no SwiftUI
        // scene (an empty Settings scene used to open on ⌘,).
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = AppDelegate()
            app.delegate = delegate
            app.setActivationPolicy(.accessory)
            withExtendedLifetime(delegate) { app.run() }
        }
    }
}
