// DAYLIT_DEMO=1: a scripted demo of the panel for recordings (README GIFs, social videos).
// Pure UI on a preview model: it never reads or writes monitor brightness, never talks to Home
// Assistant and never saves anything. It opens a colourful backdrop window with the panel on top
// and plays a ~15 s storyboard in a loop:
//   unlinked, the second monitor slides 100 → 60 (only it moves) → link on → it slides 60 → 30 and
//   the first follows with its offset → link off → it slides back up alone.
// DAYLIT_DEMO_SCREEN: part of the screen's name to show it on (default: the main screen).
// DAYLIT_APPEARANCE=light|dark picks the look. See CONTRIBUTING.md → "Re-record the demo".
import SwiftUI
import AppKit
import DaylitCore

@MainActor final class DemoController {
    static var shared: DemoController?
    static var enabled: Bool { ProcessInfo.processInfo.environment["DAYLIT_DEMO"] == "1" }

    /// The recorded area, in points (1440×810 px on a 2x screen).
    static let area = NSSize(width: 720, height: 405)

    let model = Daylit(preview: ())
    var backdrop: NSWindow!
    var panel: NSPanel!
    var timer: Timer?
    var start = Date()

    final class FrontPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    func run() {
        func mon(_ id: CGDirectDisplayID, _ label: String, _ level: Double) -> Mon {
            var m = Mon(id: id, uuid: "00000000-0000-0000-0000-00000000000\(id)", name: label, label: label, control: .native,
                        day: 70, blindDown: 40, night: 20, ha: nil)
            m.level = level; m.available = true; m.readState = .readable
            return m
        }
        model.mons = [mon(1, "LG 27UP850", 80), mon(2, "Dell U2723QE", 100)]
        model.source = .homeAssistant; model.auto = true
        model.detail = "Home Assistant · sun 64% · blind 80%"
        model.problem = nil; model.builtIn = nil; model.sync = false

        let want = ProcessInfo.processInfo.environment["DAYLIT_DEMO_SCREEN"]
        let screen = NSScreen.screens.first { s in want.map { s.localizedName.localizedCaseInsensitiveContains($0) } ?? false }
            ?? NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame
        let frame = NSRect(x: (vf.midX - Self.area.width / 2).rounded(), y: (vf.midY - Self.area.height / 2).rounded(),
                           width: Self.area.width, height: Self.area.height)

        backdrop = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        backdrop.isReleasedWhenClosed = false
        backdrop.level = .floating
        backdrop.contentView = NSHostingView(rootView: Backdrop())
        backdrop.orderFrontRegardless()

        panel = FrontPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.isReleasedWhenClosed = false
        let host = NSHostingController(rootView: Panel(m: model).panelSurface(cornerRadius: 16))
        host.sizingOptions = [.preferredContentSize]
        panel.contentViewController = host
        roundCorners(host.view, 16)
        panel.layoutIfNeeded()
        let size = host.view.fittingSize
        panel.setContentSize(size)
        panel.setFrameOrigin(NSPoint(x: (frame.midX - size.width / 2).rounded(), y: (frame.midY - size.height / 2).rounded()))

        NSApp.setActivationPolicy(.regular)        // frontmost, so controls draw in their active colours
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { self.panel.invalidateShadow() }
        let top = NSScreen.screens[0].frame.maxY - frame.maxY   // screencapture -R uses top-left global points
        print("demo: screencapture -R\(Int(frame.minX)),\(Int(top)),\(Int(frame.width)),\(Int(frame.height)) on \(screen.localizedName)")
        fflush(stdout)

        start = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { _ in
            MainActor.assumeIsolated { self.step() }
        }
    }

    /// One frame of the storyboard. Times in seconds; the loop is `length` long.
    static let length = 15.0
    var wasSync = false

    func step() {
        let t = Date().timeIntervalSince(start).truncatingRemainder(dividingBy: Self.length)
        func ease(_ a: Double, _ b: Double, from t0: Double, to t1: Double) -> Double {
            let p = min(max((t - t0) / (t1 - t0), 0), 1)
            let e = p < 0.5 ? 4 * p * p * p : 1 - pow(-2 * p + 2, 3) / 2   // ease-in-out cubic
            return a + (b - a) * e
        }
        // The second monitor's level over time, and when the link is on.
        let dell: Double
        if t < 4 { dell = ease(100, 60, from: 1.5, to: 3.5) }
        else if t < 9 { dell = ease(60, 30, from: 6, to: 8) }
        else { dell = ease(30, 70, from: 11, to: 13) }
        let linked = t >= 5 && t < 10
        // Linked, the first follows with the offset it had when the link went on (80 vs 60 → +20).
        let lg = t < 6 ? 80 : (t < 10 ? 80 + (dell - 60) : 50)

        if linked != wasSync {
            withAnimation(.snappy(duration: 0.25)) { model.sync = linked }
            wasSync = linked
        }
        if model.mons.count == 2 {
            model.mons[0].level = lg.rounded()
            model.mons[1].level = dell.rounded()
        }
    }
}

/// A soft, colourful, impersonal background for the glass to blur.
struct Backdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.98, green: 0.62, blue: 0.42), Color(red: 0.86, green: 0.40, blue: 0.70),
                                    Color(red: 0.38, green: 0.42, blue: 0.92)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(Color(red: 1.0, green: 0.85, blue: 0.45).opacity(0.85)).frame(width: 260).offset(x: -170, y: -90).blur(radius: 6)
            Circle().fill(Color(red: 0.35, green: 0.85, blue: 0.80).opacity(0.75)).frame(width: 220).offset(x: 190, y: 110).blur(radius: 6)
            Circle().fill(Color.white.opacity(0.35)).frame(width: 140).offset(x: 120, y: -120).blur(radius: 4)
        }
        .ignoresSafeArea()
    }
}
