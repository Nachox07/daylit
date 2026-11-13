// The brightness keys need macOS's Accessibility permission. macOS shows its dialog each time an app
// asks, so Daylit asks once per launch and then only checks quietly. The AX calls live in the app.
import Foundation

public enum AccessibilityPrompt {
    /// Whether to show macOS's permission dialog now: only if this launch has not asked yet.
    public static func shouldPrompt(alreadyAsked: Bool) -> Bool { !alreadyAsked }

    /// The panel hint while the permission is missing.
    public static let message = "Brightness keys need Accessibility permission"
    /// Where the Open Settings button goes.
    public static let settingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
}
