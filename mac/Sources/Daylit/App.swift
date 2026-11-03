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
        let host = NSHostingController(rootView: Panel(m: model).panelSurface(cornerRadius: 16))
        host.sizingOptions = [.preferredContentSize]
        panel.contentViewController = host
        roundCorners(host.view, 16)
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
        DispatchQueue.main.async { self.panel.invalidateShadow() }   // shadow from the drawn, rounded content
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

/// Clips a window's content to its rounded shape, so the window shadow follows the corners instead
/// of drawing a faint dark square behind them (call invalidateShadow after the first draw).
@MainActor func roundCorners(_ v: NSView, _ radius: CGFloat) {
    v.wantsLayer = true
    v.layer?.cornerRadius = radius
    v.layer?.cornerCurve = .continuous
    v.layer?.masksToBounds = true
}

/// The panel and indicator surface. macOS 26 and later: the system's Liquid Glass, the same material
/// Control Center uses (it blurs and lenses what is behind, and follows Reduce Transparency by
/// itself). Earlier versions: the menu material under an opaque-enough tint.
extension View {
    @ViewBuilder func panelSurface(cornerRadius: CGFloat) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *), !PanelBackground.plain {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(PanelBackground(cornerRadius: cornerRadius))
        }
        #else
        self.background(PanelBackground(cornerRadius: cornerRadius))
        #endif
    }
}

/// The surface where Liquid Glass is not available (and in snapshots, which draw a plain window
/// colour so they are the same on every machine).
struct PanelBackground: View {
    nonisolated(unsafe) static var plain = false
    var cornerRadius: CGFloat
    var body: some View {
        if Self.plain {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(Color(nsColor: .windowBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        } else {
            VisualEffect()
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        }
    }
}

/// Menu material under the window colour: opaque enough that text behind never shows through.
struct VisualEffect: View {
    var body: some View {
        ZStack {
            Blur()
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
        if !DemoController.enabled { let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String; Log.write("start: Daylit \(v == nil || v == "0.0.0" ? "dev" : v!)") }
        if let a = ProcessInfo.processInfo.environment["DAYLIT_APPEARANCE"] {   // screenshots: force light or dark
            NSApp.appearance = NSAppearance(named: a == "dark" ? .darkAqua : .aqua)
        }
        if DemoController.enabled {                 // scripted demo for recordings: no real model at all
            let d = DemoController(); DemoController.shared = d; d.run(); return
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
        if ProcessInfo.processInfo.environment["DAYLIT_SHOW"] == "settings" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { SettingsWindow.show(m) }
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
        if !DemoController.enabled, let id = Bundle.main.bundleIdentifier,
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
