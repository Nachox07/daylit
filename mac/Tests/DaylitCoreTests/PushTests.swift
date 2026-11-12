import XCTest
@testable import DaylitCore

final class PushConfigTests: XCTestCase {
    func load(_ text: String) -> (Config, String?) {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try! text.write(to: u, atomically: true, encoding: .utf8)
        return Config.load(from: u)
    }
    func testPushIsOffWhenTheKeyIsMissing() {
        let (c, err) = load(#"{ "homeAssistant": { "url": "http://example.local:8123" } }"#)
        XCTAssertNil(err)
        XCTAssertNil(c.homeAssistant?.push)
    }
    func testPushTrueIsRead() {
        let (c, err) = load(#"{ "homeAssistant": { "url": "http://example.local:8123", "push": true } }"#)
        XCTAssertNil(err)
        XCTAssertEqual(c.homeAssistant?.push, true)
    }
    func testPushThatIsNotTrueOrFalseIsAProblemNamingTheKey() {
        let (_, err) = load(#"{ "homeAssistant": { "url": "http://example.local:8123", "push": "yes" } }"#)
        XCTAssertTrue(err?.contains("push") ?? false, err ?? "no error")
    }
    func testSavingFromSettingsKeepsPush() throws {
        let original = #"{ "source": "homeAssistant", "homeAssistant": { "url": "http://example.local:8123", "push": true } }"#
        let e = SettingsEdit(source: "homeAssistant", haURL: "http://example.local:8123")
        let o = try JSONSerialization.jsonObject(with: ConfigPatch.apply(e, to: Data(original.utf8))) as! [String: Any]
        XCTAssertEqual((o["homeAssistant"] as! [String: Any])["push"] as? Bool, true)
    }
}
