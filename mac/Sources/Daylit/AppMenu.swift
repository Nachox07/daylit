// While one of Daylit's windows is open (Settings, Keyboard Shortcuts, Home Assistant Token), Daylit acts like any
// Mac app: it gets a Dock icon and the menu bar's Daylit menu (About Daylit, Settings…, Quit), with Edit and
// Window menus, so ⌘C / ⌘V / ⌘W and ⌘Q work as usual. With all of them closed it goes back to living only in the
// menu bar. macOS only: Windows apps have no menu bar of this kind.
import AppKit
import DaylitCore

@MainActor enum AppMenu {
    private static let target = Target()

    /// Call once a window is created: switches to a regular app and back when the last of these windows closes.
    static func opened(_ w: NSWindow) {
        if !installed { NSApp.mainMenu = build(); installed = true }
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
            // An app that turns regular while it is already frontmost gets a menu bar that draws but ignores
            // clicks until it is activated again. Hand the focus to the Dock for a moment and take it back.
            DispatchQueue.main.async {
                NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.activate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    NSApp.activate(ignoringOtherApps: true)
                    w.makeKeyAndOrderFront(nil)
                }
            }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { n in
            let closing = n.object as? NSWindow
            Task { @MainActor in
                let others = [SettingsWindow.window, ShortcutsWindow.window, TokenWindow.window]
                    .contains { if let o = $0 { return o !== closing && o.isVisible } else { return false } }
                if !others { NSApp.setActivationPolicy(.accessory) }
            }
        }
    }
    private static var installed = false

    /// The standard About panel, with the version as Settings → App → About shows it and a link to its release notes.
    static func about() {
        let v = Daylit.appVersion
        let page = UpdateCheck.releasePage(v) ?? "https://github.com/Nachox07/daylit"
        let credits = NSMutableAttributedString(string: UpdateCheck.releasePage(v) == nil ? "Source code" : "Release notes",
            attributes: [.link: URL(string: page) as Any, .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)])
        let para = NSMutableParagraphStyle(); para.alignment = .center
        credits.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: credits.length))
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Daylit",
            // "Version 1.9.0", or "Version (local build)" for a build from source; the empty build number drops "(0.0.0)".
            .applicationVersion: UpdateCheck.isDevBuild(v) ? "(local build)" : String(UpdateCheck.versionLine(v).dropFirst("Daylit ".count)),
            .version: "",
            .credits: credits,
        ])
        NSApp.activate(ignoringOtherApps: true)
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
