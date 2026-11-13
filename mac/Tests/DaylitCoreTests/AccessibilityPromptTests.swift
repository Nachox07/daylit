import XCTest
@testable import DaylitCore

final class AccessibilityPromptTests: XCTestCase {
    func testTheFirstCheckOfALaunchPrompts() {
        XCTAssertTrue(AccessibilityPrompt.shouldPrompt(alreadyAsked: false))
    }
    func testLaterChecksDoNotPromptAgain() {
        XCTAssertFalse(AccessibilityPrompt.shouldPrompt(alreadyAsked: true))
    }
    func testSettingsLinkOpensTheAccessibilityPane() {
        XCTAssertTrue(AccessibilityPrompt.settingsURL.hasSuffix("Privacy_Accessibility"))
    }
}
