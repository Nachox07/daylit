import AppKit

/// macOS light/dark mode through System Events (needs the Automation permission, asked once).
@MainActor enum Appearance {
    static var isDark: Bool { NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
    /// nil on success, else a short reason (e.g. the permission was refused).
    @discardableResult static func setDark(_ dark: Bool) -> String? {
        var err: NSDictionary?
        NSAppleScript(source: "tell application \"System Events\" to tell appearance preferences to set dark mode to \(dark)")?
            .executeAndReturnError(&err)
        guard let err else { return nil }
        let n = err[NSAppleScript.errorNumber] as? Int ?? 0
        return n == -1743 ? "Allow Daylit to control System Events (System Settings → Privacy & Security → Automation)"
                          : "Could not change light/dark mode (\(n))"
    }
}
