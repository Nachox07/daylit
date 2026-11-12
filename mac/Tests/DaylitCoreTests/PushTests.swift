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

final class PushParseTests: XCTestCase {
    func testAuthMessages() {
        XCTAssertEqual(PushRule.parse(#"{"type":"auth_required","ha_version":"2026.11.0"}"#), .authRequired)
        XCTAssertEqual(PushRule.parse(#"{"type":"auth_ok","ha_version":"2026.11.0"}"#), .authOk)
        XCTAssertEqual(PushRule.parse(#"{"type":"auth_invalid","message":"Invalid access token or password"}"#),
                       .authInvalid("Invalid access token or password"))
    }
    func testResultSuccessAndFailure() {
        XCTAssertEqual(PushRule.parse(#"{"id":1,"type":"result","success":true,"result":null}"#), .result(id: 1, ok: true))
        XCTAssertEqual(PushRule.parse(#"{"id":1,"type":"result","success":false,"error":{"code":"invalid_format","message":"x"}}"#),
                       .result(id: 1, ok: false))
    }
    func testPong() {
        XCTAssertEqual(PushRule.parse(#"{"id":7,"type":"pong"}"#), .pong)
    }
    func testTheFirstEventListsEveryEntityUnderA() {
        let m = #"{"id":1,"type":"event","event":{"a":{"cover.blind":{"s":"open","a":{"current_position":100},"c":"01J","lc":1763000000.1},"sun.sun":{"s":"above_horizon","a":{"elevation":20.5},"c":"01K","lc":1763000000.2,"lu":1763000100.3}}}}"#
        XCTAssertEqual(PushRule.parse(m), .event(["cover.blind", "sun.sun"]))
    }
    func testAChangeUnderC() {
        let m = #"{"id":1,"type":"event","event":{"c":{"light.room":{"+":{"s":"off","lc":1763000200.5,"c":"01L","a":{"brightness":null}},"-":{"a":["hs_color"]}}}}}"#
        XCTAssertEqual(PushRule.parse(m), .event(["light.room"]))
    }
    func testARemovalUnderR() {
        XCTAssertEqual(PushRule.parse(#"{"id":1,"type":"event","event":{"r":["input_number.night"]}}"#), .event(["input_number.night"]))
    }
    func testAllThreeInOneEvent() {
        let m = #"{"id":1,"type":"event","event":{"a":{"light.a":{"s":"on","a":{},"c":"x","lc":1}},"c":{"light.b":{"+":{"s":"on"}}},"r":["light.c"]}}"#
        XCTAssertEqual(PushRule.parse(m), .event(["light.a", "light.b", "light.c"]))
    }
    func testAnythingElseIsOther() {
        for m in ["", "not json", "[]", #"[{"type":"auth_ok"}]"#, #"{"type":"something_new"}"#, #"{"no":"type"}"#,
                  #"{"type":"result","success":true}"#, #"{"type":"event"}"#, #"{"type":"auth_ok""#] {
            XCTAssertEqual(PushRule.parse(m), .other, m)
        }
    }
}

final class PushMessageTests: XCTestCase {
    func obj(_ s: String) -> [String: Any] { try! JSONSerialization.jsonObject(with: Data(s.utf8)) as! [String: Any] }
    func testTheAuthMessageCarriesTheTokenAsAccessToken() {
        let o = obj(PushRule.authMessage(token: "abc\"def\\ghi"))
        XCTAssertEqual(o["type"] as? String, "auth")
        XCTAssertEqual(o["access_token"] as? String, "abc\"def\\ghi")
        XCTAssertEqual(o.count, 2)
    }
    func testSubscribeNamesTheEntities() {
        let o = obj(PushRule.subscribeMessage(id: 1, entities: ["light.room", "sun.sun"]))
        XCTAssertEqual(o["id"] as? Int, 1)
        XCTAssertEqual(o["type"] as? String, "subscribe_entities")
        XCTAssertEqual(o["entity_ids"] as? [String], ["light.room", "sun.sun"])
    }
    func testPing() {
        let o = obj(PushRule.pingMessage(id: 4))
        XCTAssertEqual(o["id"] as? Int, 4); XCTAssertEqual(o["type"] as? String, "ping")
    }
    func testLogLinesCarryNoToken() {
        let token = "a-token-that-must-not-appear"
        _ = PushRule.authMessage(token: token)
        for line in [PushRule.connectedLine(12), PushRule.lostLine("no pong", retryIn: 5), PushRule.rejectedLine("Invalid access token or password"),
                     PushRule.offLine, PushRule.rejectedProblem] {
            XCTAssertFalse(line.contains(token), line)
        }
        XCTAssertEqual(PushRule.connectedLine(12), "push: connected (12 entities)")
        XCTAssertEqual(PushRule.lostLine("no pong", retryIn: 5), "push: lost (no pong), retrying in 5s")
        XCTAssertEqual(PushRule.offLine, "push: off")
    }
}

final class PushDecisionTests: XCTestCase {
    let subscribed: Set<String> = ["cover.blind", "light.room", "input_number.day", "input_number.set", "sun.sun", "sensor.solar"]
    func d(_ changed: Set<String>, lastTick: Double? = 1000, now: Double = 1010) -> PushTick {
        PushRule.decide(changed: changed, subscribed: subscribed, daylight: "sensor.solar", lastTick: lastTick, now: now)
    }
    func testCoverLightsAndHelpersTickAtOnce() {
        XCTAssertEqual(d(["cover.blind"]), .now)
        XCTAssertEqual(d(["light.room"]), .now)
        XCTAssertEqual(d(["input_number.day"]), .now)
        XCTAssertEqual(d(["input_number.set"]), .now)
        XCTAssertEqual(d(["sun.sun"]), .now)
    }
    func testADaylightOnlyChangeWaitsUntilAMinuteAfterTheLastTick() {
        XCTAssertEqual(d(["sensor.solar"], lastTick: 1000, now: 1010), .after(50))
    }
    func testTheDaylightLimitIsTheNormalPollIntervalWhenLongerThanAMinute() {
        let mains = PushRule.daylightLimit(onBattery: false, tuning: Tuning())
        let battery = PushRule.daylightLimit(onBattery: true, tuning: Tuning())
        XCTAssertEqual(mains, 60)
        XCTAssertEqual(battery, 120)
        XCTAssertEqual(PushRule.decide(changed: ["sensor.solar"], subscribed: subscribed, daylight: "sensor.solar", lastTick: 1000, now: 1010, every: battery), .after(110))
        XCTAssertEqual(PushRule.decide(changed: ["sensor.solar"], subscribed: subscribed, daylight: "sensor.solar", lastTick: 1000, now: 1120, every: battery), .now)
    }
    func testPingIsEveryTwoMinutesOnBatteryAndEveryMinuteOnMains() {
        XCTAssertEqual(PushRule.pingInterval(onBattery: false), 60)
        XCTAssertEqual(PushRule.pingInterval(onBattery: true), 120)
    }
    func testADaylightOnlyChangeTicksWhenTheLastTickIsAMinuteOld() {
        XCTAssertEqual(d(["sensor.solar"], lastTick: 1000, now: 1060), .now)
        XCTAssertEqual(d(["sensor.solar"], lastTick: nil), .now)
    }
    func testAMixTicksAtOnce() {
        XCTAssertEqual(d(["sensor.solar", "cover.blind"]), .now)
    }
    func testAnUnknownEntityIsIgnored() {
        XCTAssertEqual(d(["light.kitchen"]), .ignore)
        XCTAssertEqual(d([]), .ignore)
    }
    func testAnUnknownEntityNextToTheDaylightSensorStillCountsAsDaylightOnly() {
        XCTAssertEqual(d(["sensor.solar", "light.kitchen"]), .after(50))
    }
    func testWithoutADaylightSensorEverythingTicksAtOnce() {
        XCTAssertEqual(PushRule.decide(changed: ["sensor.solar"], subscribed: subscribed, daylight: nil, lastTick: 1000, now: 1001), .now)
    }
}

final class PushTimerTests: XCTestCase {
    func testABurstRunsOneTickAndEachChangeExtendsTheWindow() {
        var t = PushTimer()
        XCTAssertTrue(t.add(.now, now: 100))
        XCTAssertEqual(t.due, 101)
        XCTAssertTrue(t.add(.now, now: 100.3))
        XCTAssertEqual(t.due, 101.3)
        XCTAssertTrue(t.add(.now, now: 100.9))
        XCTAssertEqual(t.due!, 101.9, accuracy: 1e-9)
    }
    func testASingleChangeTicksAfterOneSecond() {
        var t = PushTimer()
        _ = t.add(.now, now: 100)
        XCTAssertEqual(t.due, 101)
    }
    func testTheWindowIsCappedAtThreeSecondsAfterTheFirstChange() {
        var t = PushTimer()
        _ = t.add(.now, now: 100)
        _ = t.add(.now, now: 100.8); _ = t.add(.now, now: 101.6); _ = t.add(.now, now: 102.4)
        XCTAssertEqual(t.due!, 103, accuracy: 1e-9)
        XCTAssertFalse(t.add(.now, now: 102.9))   // already due at the cap
        XCTAssertEqual(t.due!, 103, accuracy: 1e-9)
    }
    func testAStreamOverFiveSecondsTicksAtMostEveryThreeSeconds() {
        var t = PushTimer(); var fired: [Double] = []
        var now = 100.0
        while now < 105 {
            _ = t.add(.now, now: now)
            if let d = t.due, d <= now + 0.5 { fired.append(d); t.clear() }
            now += 0.5
        }
        XCTAssertEqual(fired.first!, 103, accuracy: 1e-9)
        for (a, b) in zip(fired, fired.dropFirst()) { XCTAssertGreaterThanOrEqual(b - a, 1) }
        XCTAssertLessThanOrEqual(fired.count, 2)
    }
    func testADaylightWaitDoesNotPushBackATickAlreadyDue() {
        var t = PushTimer()
        _ = t.add(.now, now: 100)
        XCTAssertFalse(t.add(.after(50), now: 100.5))
        XCTAssertEqual(t.due, 101)
    }
    func testAChangeBringsAWaitingDaylightTickForward() {
        var t = PushTimer()
        XCTAssertTrue(t.add(.after(50), now: 100))
        XCTAssertEqual(t.due, 150)
        XCTAssertTrue(t.add(.now, now: 110))
        XCTAssertEqual(t.due, 111)
    }
    func testIgnoreChangesNothingAndClearEmpties() {
        var t = PushTimer()
        XCTAssertFalse(t.add(.ignore, now: 100))
        XCTAssertNil(t.due)
        _ = t.add(.now, now: 100); t.clear()
        XCTAssertNil(t.due)
    }
}

final class PushTimingTests: XCTestCase {
    func testBackoff() {
        XCTAssertEqual((0..<7).map { PushRule.retryDelay(attempt: $0) }, [2, 5, 15, 60, 60, 60, 60])
    }
    func testPollIsFiveMinutesWhileHealthyOnMainsAndBattery() {
        XCTAssertEqual(PushRule.pollInterval(healthy: true, onBattery: false, tuning: Tuning()), 300)
        XCTAssertEqual(PushRule.pollInterval(healthy: true, onBattery: true, tuning: Tuning()), 300)
    }
    func testPollIsTodaysWhenNotHealthy() {
        XCTAssertEqual(PushRule.pollInterval(healthy: false, onBattery: false, tuning: Tuning()), 30)
        XCTAssertEqual(PushRule.pollInterval(healthy: false, onBattery: true, tuning: Tuning()), 120)
    }
    func testALongerConfiguredPollIsKeptWhileHealthy() {
        var t = Tuning(); t.timing = .init(); t.timing?.batteryPollSeconds = 900
        XCTAssertEqual(PushRule.pollInterval(healthy: true, onBattery: true, tuning: t), 900)
    }
    func testTheSocketIsOpenOnlyWhenEverythingAllowsIt() {
        XCTAssertTrue(PushRule.wanted(push: true, source: .homeAssistant, paused: false, auto: true, hasMonitors: true))
        XCTAssertFalse(PushRule.wanted(push: nil, source: .homeAssistant, paused: false, auto: true, hasMonitors: true))
        XCTAssertFalse(PushRule.wanted(push: false, source: .homeAssistant, paused: false, auto: true, hasMonitors: true))
        XCTAssertFalse(PushRule.wanted(push: true, source: .sun, paused: false, auto: true, hasMonitors: true))
        XCTAssertFalse(PushRule.wanted(push: true, source: .homeAssistant, paused: true, auto: true, hasMonitors: true))
        XCTAssertFalse(PushRule.wanted(push: true, source: .homeAssistant, paused: false, auto: false, hasMonitors: true))
        XCTAssertFalse(PushRule.wanted(push: true, source: .homeAssistant, paused: false, auto: true, hasMonitors: false))
    }
}
