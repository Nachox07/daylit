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

final class PushURLTests: XCTestCase {
    func testHttpBecomesWsAndKeepsThePort() {
        XCTAssertEqual(PushRule.socketURL("http://example.local:8123")?.absoluteString, "ws://example.local:8123/api/websocket")
    }
    func testHttpsBecomesWss() {
        XCTAssertEqual(PushRule.socketURL("https://ha.example.com")?.absoluteString, "wss://ha.example.com/api/websocket")
    }
    func testATrailingSlashDoesNotDoubleTheSlash() {
        XCTAssertEqual(PushRule.socketURL("http://example.local:8123/")?.absoluteString, "ws://example.local:8123/api/websocket")
    }
    func testAPathIsKeptInFrontOfTheSocketPath() {
        XCTAssertEqual(PushRule.socketURL("https://example.local/ha/")?.absoluteString, "wss://example.local/ha/api/websocket")
    }
    func testUpperCaseSchemeWorks() {
        XCTAssertEqual(PushRule.socketURL("HTTP://example.local:8123")?.absoluteString, "ws://example.local:8123/api/websocket")
    }
    func testNotAnHttpURLGivesNothing() {
        XCTAssertNil(PushRule.socketURL("ftp://example.local"))
        XCTAssertNil(PushRule.socketURL("example.local:8123"))
        XCTAssertNil(PushRule.socketURL(""))
    }
}

final class PushEntityTests: XCTestCase {
    func config(_ ha: HAConfig?, _ mons: [MonitorHA?]) -> Config {
        Config(homeAssistant: ha, monitors: mons.enumerated().map { i, h in MonitorConfig(match: "M\(i)", homeAssistant: h) })
    }
    func testEveryConfiguredEntityOnceAndSorted() {
        let ha = HAConfig(url: "http://example.local:8123", autoSwitch: "input_boolean.auto", sun: "sun.sun", cover: "cover.blind",
                          lights: "light.room", light: "sensor.solar")
        let left = MonitorHA(sensor: "sensor.left", day: "input_number.day", blindDown: "input_number.down", night: "input_number.night",
                             set: "input_number.left_set", nightLights: "input_number.lit")
        let right = MonitorHA(day: "input_number.day", set: "input_number.right_set")   // shares the day helper
        XCTAssertEqual(PushRule.entities(config(ha, [left, right])),
                       ["cover.blind", "input_boolean.auto", "input_number.day", "input_number.down", "input_number.left_set",
                        "input_number.lit", "input_number.night", "input_number.right_set", "light.room", "sensor.solar", "sun.sun"])
    }
    func testUnsetEntitiesAreLeftOutAndTheSunDefaultsToSunSun() {
        XCTAssertEqual(PushRule.entities(config(HAConfig(url: "http://example.local:8123"), [nil, MonitorHA(night: "input_number.night")])),
                       ["input_number.night", "sun.sun"])
    }
    func testAnEmptySunIsSunSunAsInTheTemplate() {
        XCTAssertEqual(PushRule.entities(config(HAConfig(url: "http://example.local:8123", sun: ""), [])), ["sun.sun"])
    }
    func testThePublishedSensorIsNeverFollowed() {
        let ids = PushRule.entities(config(HAConfig(url: "http://example.local:8123"), [MonitorHA(sensor: "sensor.left")]))
        XCTAssertFalse(ids.contains("sensor.left"))
    }
    func testNoHomeAssistantNoEntities() {
        XCTAssertEqual(PushRule.entities(Config()), [])
    }
}
