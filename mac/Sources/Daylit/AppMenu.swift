// While one of Daylit's windows is open (Settings, Keyboard Shortcuts, Home Assistant Token), Daylit acts like any
// Mac app: it gets a Dock icon and the menu bar's Daylit menu (About Daylit, Settings…, Quit), with Edit and
// Window menus, so ⌘C / ⌘V / ⌘W and ⌘Q work as usual. With all of them closed it goes back to living only in the
// menu bar. macOS only: Windows apps have no menu bar of this kind.
import AppKit
import DaylitCore

@MainActor enum AppMenu {
    private static let target = Target()
    private static var installed = false
    /// Daylit's windows that are open (minimized counts): the app stays regular while any is.
    private static var open: [ObjectIdentifier: NSWindow] = [:]
    /// Bumped on every change, so a delayed re-activation for an older state does nothing.
    private static var generation = 0

    /// Call every time one of the windows is shown, new or reused: Daylit is a regular app while any is open.
    static func opened(_ w: NSWindow) {
        if !installed { NSApp.mainMenu = build(); installed = true }
        track(w)
        guard NSApp.activationPolicy() != .regular else { return }
        NSApp.setActivationPolicy(.regular)
        // An app that turns regular while it is already frontmost gets a menu bar that draws but ignores clicks
        // until it is activated again. Hand the focus to the Dock for a moment and take it back, unless the window
        // closed or something else changed meanwhile.
        generation += 1
        let gen = generation
        DispatchQueue.main.async {
            guard gen == generation, open[ObjectIdentifier(w)] != nil else { return }
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                guard gen == generation, open[ObjectIdentifier(w)] != nil, w.isVisible else { return }
                NSApp.activate(ignoringOtherApps: true)
                w.makeKeyAndOrderFront(nil)
            }
        }
    }

    private static func track(_ w: NSWindow) {
        let id = ObjectIdentifier(w)
        guard open[id] == nil else { return }
        open[id] = w
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated {
                open[id] = nil
                generation += 1
                if open.isEmpty { NSApp.setActivationPolicy(.accessory) }
            }
        }
    }

    /// The standard About panel, with the version as Settings → App → About shows it and a link to its release notes.
    static func about() {
        let v = Daylit.appVersion
        let page = UpdateCheck.releasePage(v) ?? "https://github.com/Nachox07/daylit"
        let credits = NSMutableAttributedString(string: UpdateCheck.releasePage(v) == nil ? "Source code" : "Release notes",
            attributes: [.link: URL(string: page) as Any, .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)])
        let para = NSMutableParagraphStyle(); para.alignment = .center
        credits.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: credits.length))
        let shownBefore = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Daylit",
            // The panel shows this text as is: "Version 1.9.0", or "Local build" for a build from source. The empty
            // build number drops the "(0.0.0)" it would add.
            .applicationVersion: UpdateCheck.isDevBuild(v) ? "Local build" : "Version " + String(UpdateCheck.versionLine(v).dropFirst("Daylit ".count)),
            .version: "",
            .credits: credits,
        ])
        NSApp.activate(ignoringOtherApps: true)
        // The panel (the window that just appeared) counts as one of Daylit's windows, so closing Settings under it
        // keeps the menu bar.
        for w in NSApp.windows where w.isVisible && !shownBefore.contains(ObjectIdentifier(w)) { track(w) }
    }

    private static func build() -> NSMenu {
        let main = NSMenu()
        func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command, to t: AnyObject? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods; i.target = t
            return i
        }
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let m = NSMenu(title: title); items.forEach(m.addItem)
            let top = NSMenuItem(title: title, action: nil, keyEquivalent: ""); top.submenu = m
            main.addItem(top)
        }
        submenu("Daylit", [
            item("About Daylit", #selector(Target.about), to: target),
            .separator(),
            item("Settings…", #selector(Target.settings), ",", to: target),
            .separator(),
            item("Hide Daylit", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit Daylit", #selector(NSApplication.terminate(_:)), "q"),
        ])
        submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
        ])
        NSApp.windowsMenu = main.items.last?.submenu
        return main
    }

    @MainActor private final class Target: NSObject {
        @objc func about() { AppMenu.about() }
        @objc func settings() { if let m = StatusController.shared?.model { SettingsWindow.show(m) } }
    }
}
