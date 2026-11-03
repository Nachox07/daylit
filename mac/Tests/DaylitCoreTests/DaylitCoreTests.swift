import XCTest
@testable import DaylitCore

private func utc(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

final class SunTests: XCTestCase {
    func testMatchesHomeAssistantAtNight() {
        // Home Assistant's sun.sun reported -10.0° at this time and place (Greenwich).
        let e = solarElevation(latitude: 51.4769, longitude: -0.0005, at: utc("2026-01-01T00:00:00Z"))
        XCTAssertEqual(e, -10.0, accuracy: 0.05)
    }

    func testEquatorAtEquinoxNoonIsOverhead() {
        // March equinox 2024 (03:06 UTC): declination ≈ 0, so at the equator the noon sun is near 90°.
        // Solar noon at longitude 0 is about 12:07 UTC that day (equation of time ≈ -7 min).
        let e = solarElevation(latitude: 0, longitude: 0, at: utc("2024-03-20T12:07:00Z"))
        XCTAssertEqual(e, 90, accuracy: 0.5)
    }

    func testSummerSolsticeNoon() {
        // Noon elevation = 90° − latitude + declination; on the June solstice declination = 23.44°.
        // At longitude �-0.0005° solar noon is about 12:20 UTC.
        let e = solarElevation(latitude: 51.4769, longitude: -0.0005, at: utc("2026-06-21T12:20:00Z"))
        XCTAssertEqual(e, 90 - 51.4769 + 23.44, accuracy: 0.3)
    }

    func testDaylightFraction() {
        XCTAssertEqual(daylightFraction(elevation: -10), 0)
        XCTAssertEqual(daylightFraction(elevation: -3), 0)
        XCTAssertEqual(daylightFraction(elevation: 4.5), 0.5, accuracy: 1e-9)
        XCTAssertEqual(daylightFraction(elevation: 12), 1)
        XCTAssertEqual(daylightFraction(elevation: 60), 1)
    }
}

final class TargetTests: XCTestCase {
    func testNightUsesNightLevel() {
        XCTAssertEqual(target(day: 80, blindDown: 40, night: 20, elev: -20, pos: 100, lights: false), 20)
    }
    func testFullDayBlindOpenUsesDayLevel() {
        XCTAssertEqual(target(day: 80, blindDown: 40, night: 20, elev: 30, pos: 100, lights: false), 80)
    }
    func testFullDayBlindClosedUsesBlindDownLevel() {
        XCTAssertEqual(target(day: 80, blindDown: 40, night: 20, elev: 30, pos: 0, lights: false), 40)
    }
    func testBlindHalfOpenIsHalfway() {
        XCTAssertEqual(target(day: 80, blindDown: 40, night: 20, elev: 30, pos: 50, lights: false), 60)
    }
    func testTwilightBlendsDayAndNight() {
        // elev 4.5° = half daylight: halfway between night 20 and day 80.
        XCTAssertEqual(target(day: 80, blindDown: 40, night: 20, elev: 4.5, pos: 100, lights: false), 50)
    }
    func testLightsAtNightAddFive() {
        XCTAssertEqual(target(day: 80, blindDown: 40, night: 20, elev: -20, pos: 100, lights: true), 25)
    }
    func testLightsInDaylightChangeNothing() {
        XCTAssertEqual(target(day: 80, blindDown: 40, night: 20, elev: 30, pos: 100, lights: true), 80)
    }
    func testClampsToRange() {
        XCTAssertEqual(target(day: 150, blindDown: 150, night: 120, elev: 30, pos: 100, lights: false), 100)
        XCTAssertEqual(target(day: -10, blindDown: -10, night: -10, elev: -20, pos: 0, lights: false), 0)
    }
    func testEffectiveLevelsPreferHomeAssistantValues() {
        XCTAssertEqual(effectiveLevels(local: [70, 40, 20], fromHA: [90, -1, 10, -1, 0]), [90, 40, 10])
        XCTAssertEqual(effectiveLevels(local: [70, 40, 20], fromHA: nil), [70, 40, 20])
    }
}

final class DecideTests: XCTestCase {
    func step(_ c: Int, want: Int, remote: RemoteSet? = nil, state: HoldState = HoldState(),
              here: Bool = true, auto: Bool = true, dragging: Bool = false, hold: Int = 5) -> Step {
        decide(current: c, want: want, remote: remote, state: state, here: here, auto: auto, dragging: dragging, hold: hold)
    }

    func testAppliesTargetAndRemembersIt() {
        let s = step(50, want: 70)
        XCTAssertEqual(s.write, 70)
        XCTAssertEqual(s.applied, 70)
        XCTAssertFalse(s.manual)
        XCTAssertEqual(s.state, HoldState(lastSet: 70, lastTarget: 70))
    }
    func testNoWriteWhenAlreadyAtTarget() {
        XCTAssertNil(step(70, want: 70).write)
    }
    func testHandSetLevelIsHeldWhileTargetMovesLessThanHold() {
        // Automatic set 70; the user then chose 50; the target moved only to 73.
        let s = step(50, want: 73, state: HoldState(lastSet: 70, lastTarget: 70))
        XCTAssertNil(s.write)
        XCTAssertTrue(s.manual)
        XCTAssertEqual(s.applied, 50)
    }
    func testHandSetLevelIsReplacedOnceTargetMovesByHold() {
        let s = step(50, want: 75, state: HoldState(lastSet: 70, lastTarget: 70))
        XCTAssertEqual(s.write, 75)
        XCTAssertFalse(s.manual)
    }
    func testIdleMachineLeavesTheMonitorAlone() {
        let s = step(50, want: 70, here: false)
        XCTAssertTrue(s.skip)
        XCTAssertNil(s.write)
    }
    func testAutomaticOffNeverWrites() {
        let s = step(50, want: 70, auto: false)
        XCTAssertNil(s.write)
        XCTAssertEqual(s.applied, 50)
    }
    func testDraggingSliderIsNotOverridden() {
        XCTAssertNil(step(50, want: 70, dragging: true).write)
    }
    func testFirstLookAtSetHelperIsNotACommand() {
        let s = step(70, want: 70, remote: RemoteSet(value: 30, changed: 1000))
        XCTAssertNil(s.remote)
        XCTAssertEqual(s.state.remoteSeen, 1000)
    }
    func testSetHelperChangeAppliesEvenWhenIdleAndIsHeld() {
        let s = step(70, want: 70, remote: RemoteSet(value: 30, changed: 2000), state: HoldState(lastSet: 70, lastTarget: 70, remoteSeen: 1000), here: false)
        XCTAssertEqual(s.remote, 30)
        XCTAssertEqual(s.write, 30)
        XCTAssertFalse(s.skip)
        XCTAssertTrue(s.manual)
        XCTAssertEqual(s.state.remoteSeen, 2000)
        // Held as hand-set: the next tick at the same target keeps 30.
        let next = step(30, want: 70, state: s.state)
        XCTAssertNil(next.write)
        XCTAssertTrue(next.manual)
    }
    func testSetHelperUnchangedDoesNothing() {
        let s = step(70, want: 70, remote: RemoteSet(value: 30, changed: 1000), state: HoldState(lastSet: 70, lastTarget: 70, remoteSeen: 1000))
        XCTAssertNil(s.remote)
        XCTAssertNil(s.write)
    }
    func testRemoteRowParsing() {
        XCTAssertEqual(RemoteSet(row: [70, 40, 20, 55, 1234]), RemoteSet(value: 55, changed: 1234))
        XCTAssertNil(RemoteSet(row: [70, 40, 20, -1, 0]))      // no set helper
        XCTAssertNil(RemoteSet(row: [70, 40, 20, 55, 0]))      // helper missing in HA
        XCTAssertNil(RemoteSet(row: [70, 40, 20]))
        XCTAssertNil(RemoteSet(row: nil))
    }
}

final class LookTests: XCTestCase {
    func testDaylightWithOpenBlindIsLight() {
        var r = LookRule()
        XCTAssertFalse(r.wantDark(elev: 20, pos: 100, hasBlind: true, lightsOn: false, bri: 0, sat: 0))
    }
    func testNightIsDark() {
        var r = LookRule()
        XCTAssertTrue(r.wantDark(elev: -10, pos: 100, hasBlind: true, lightsOn: false, bri: 0, sat: 0))
    }
    func testClosedBlindIsDark() {
        var r = LookRule()
        XCTAssertTrue(r.wantDark(elev: 20, pos: 20, hasBlind: true, lightsOn: false, bri: 0, sat: 0))
    }
    func testBrightWhiteLightsAtNightAreLight() {
        var r = LookRule()
        XCTAssertFalse(r.wantDark(elev: -10, pos: 0, hasBlind: true, lightsOn: true, bri: 230, sat: 10))
    }
    func testWarmLightsAtNightStayDark() {
        var r = LookRule()
        XCTAssertTrue(r.wantDark(elev: -10, pos: 0, hasBlind: true, lightsOn: true, bri: 230, sat: 70))
    }
    func testInTheGapThePreviousAnswerStays() {
        var r = LookRule()
        XCTAssertFalse(r.wantDark(elev: 10, pos: 100, hasBlind: true, lightsOn: false, bri: 0, sat: 0))   // light
        XCTAssertFalse(r.wantDark(elev: 2, pos: 100, hasBlind: true, lightsOn: false, bri: 0, sat: 0))    // gap: stays light
        XCTAssertTrue(r.wantDark(elev: 0.5, pos: 100, hasBlind: true, lightsOn: false, bri: 0, sat: 0))   // below 1°: dark
        XCTAssertTrue(r.wantDark(elev: 2, pos: 100, hasBlind: true, lightsOn: false, bri: 0, sat: 0))     // gap: stays dark
    }
    func testWithoutBlindOnlyTheSunCounts() {
        var r = LookRule()
        XCTAssertFalse(r.wantDark(elev: 10, pos: 0, hasBlind: false, lightsOn: false, bri: 0, sat: 0))
    }
    func testLightsNote() {
        XCTAssertEqual(lightsNote(lights: false, bri: 200, sat: 0), "")
        XCTAssertEqual(lightsNote(lights: true, bri: 0, sat: 0), " · lights on")
        XCTAssertEqual(lightsNote(lights: true, bri: 204, sat: 10), " · lights 80% white")
        XCTAssertEqual(lightsNote(lights: true, bri: 102, sat: 70), " · lights 40% warm")
        XCTAssertEqual(lightsNote(lights: true, bri: 255, sat: 40), " · lights 100%")
    }
}

final class ConfigTests: XCTestCase {
    func write(_ text: String) -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("daylit-test-\(UUID().uuidString).json")
        try! text.write(to: u, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: u) }
        return u
    }

    func testMissingFileGivesDefaultsAndNoError() {
        let (c, err) = Config.load(from: URL(fileURLWithPath: "/nonexistent/daylit/config.json"))
        XCTAssertNil(err)
        XCTAssertNil(c.monitors)
        XCTAssertEqual(c.resolvedSource().0, .off)
    }
    func testBrokenJSONIsReportedAndDefaultsUsed() {
        let (c, err) = Config.load(from: write("{ \"source\": "))
        XCTAssertNotNil(err)
        XCTAssertTrue(err!.hasPrefix("config.json is not valid"))
        XCTAssertNil(c.source)
    }
    func testWrongTypeNamesTheKey() {
        let (_, err) = Config.load(from: write(#"{ "manualHold": "five" }"#))
        XCTAssertTrue(err?.contains("manualHold") ?? false, err ?? "")
    }
    func testExampleConfigLoads() throws {
        let example = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../config.example.json").standardizedFileURL
        let (c, err) = Config.load(from: example)
        XCTAssertNil(err)
        XCTAssertEqual(c.resolvedSource().0, .homeAssistant)
        XCTAssertEqual(c.monitors?.count, 2)
        XCTAssertNotNil(c.location)
    }
    func testSourceDefaults() {
        XCTAssertEqual(Config().resolvedSource().0, .off)
        XCTAssertEqual(Config(location: Location(latitude: 1, longitude: 2)).resolvedSource().0, .sun)
        XCTAssertEqual(Config(homeAssistant: HAConfig(url: "http://ha.local:8123")).resolvedSource().0, .homeAssistant)
    }
    func testSourceProblems() {
        let sunNoLoc = Config(source: "sun").resolvedSource()
        XCTAssertEqual(sunNoLoc.0, .off); XCTAssertNotNil(sunNoLoc.1)
        let haNoURL = Config(source: "homeAssistant", location: Location(latitude: 1, longitude: 2)).resolvedSource()
        XCTAssertEqual(haNoURL.0, .sun); XCTAssertNotNil(haNoURL.1)
        let unknown = Config(source: "moon").resolvedSource()
        XCTAssertEqual(unknown.0, .off); XCTAssertNotNil(unknown.1)
    }
}

final class TemplateTests: XCTestCase {
    func testNoAutoSwitchRendersJSONNull() {
        let t = HATemplate.build(HAConfig(url: "http://x"), [])
        XCTAssertTrue(t.contains(#""auto": null,"#), t)
        XCTAssertTrue(t.contains("sun.sun"))
        XCTAssertTrue(t.contains(#""pos": {{ 100 }}"#))
        XCTAssertTrue(t.contains(#""lights": {{ false | tojson }}"#))
    }
    func testEntitiesAppear() {
        let ha = HAConfig(url: "http://x", autoSwitch: "input_boolean.auto", cover: "cover.blind", lights: "light.room")
        let mon = MonitorHA(day: "input_number.d", set: "input_number.s")
        let t = HATemplate.build(ha, [("UUID-1", mon), ("UUID-2", nil)])
        XCTAssertTrue(t.contains("is_state('input_boolean.auto','on') | tojson"))
        XCTAssertTrue(t.contains("state_attr('cover.blind','current_position')"))
        XCTAssertTrue(t.contains("state_attr('light.room','brightness')"))
        XCTAssertTrue(t.contains(#""UUID-1": [{{ states('input_number.d') | float(-1) }}, -1, -1, "#))
        XCTAssertTrue(t.contains("states.input_number.s.last_changed"))
        XCTAssertFalse(t.contains("UUID-2"))   // a monitor without HA entities is left out
    }
    func testParsesAnswerShape() {
        let ok = #"{"elev": 10.5, "pos": 56, "lights": true, "auto": null, "bri": 200, "sat": 20, "m": {"U": [80, 40, 20, -1, 0]}}"#
        let s = HAState.parse(Data(ok.utf8))
        XCTAssertNotNil(s)
        XCTAssertNil(s?.auto)
        XCTAssertEqual(s?.m["U"]?.count, 5)
        let short = #"{"elev": 1, "pos": 1, "lights": false, "auto": true, "bri": 0, "sat": 0, "m": {"U": [80, 40, 20]}}"#
        XCTAssertNil(HAState.parse(Data(short.utf8)))
        XCTAssertNil(HAState.parse(Data("not json".utf8)))
    }
}
