import XCTest
@testable import DaylitCore

private func utc(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

final class SunTests: XCTestCase {
    // Expected values: NOAA Solar Calculator algorithm (gml.noaa.gov/grad/solcalc), geometric elevation
    // without refraction, computed independently of Daylit's formula. Daylit agrees to about 0.005°.
    private let greenwich = (lat: 51.4769, lon: -0.0005)   // Royal Observatory Greenwich

    func testGreenwichJuneSolsticeNoon() {
        XCTAssertEqual(solarElevation(latitude: greenwich.lat, longitude: greenwich.lon, at: utc("2024-06-21T12:00:00Z")), 61.958, accuracy: 0.05)
    }

    func testGreenwichDecemberSolsticeNoonAndMidnight() {
        XCTAssertEqual(solarElevation(latitude: greenwich.lat, longitude: greenwich.lon, at: utc("2024-12-21T12:00:00Z")), 15.084, accuracy: 0.05)
        XCTAssertEqual(solarElevation(latitude: greenwich.lat, longitude: greenwich.lon, at: utc("2024-12-21T00:00:00Z")), -61.959, accuracy: 0.05)
    }

    func testGreenwichEquinoxSunrise() {
        XCTAssertEqual(solarElevation(latitude: greenwich.lat, longitude: greenwich.lon, at: utc("2024-03-20T06:00:00Z")), -1.109, accuracy: 0.05)
    }

    func testEquatorAtEquinoxNoonIsOverhead() {
        XCTAssertEqual(solarElevation(latitude: 0, longitude: 0, at: utc("2024-03-20T12:07:00Z")), 89.834, accuracy: 0.05)
    }

    func testSouthernHemisphereEastLongitude() {
        // Sydney Opera House, 01:00 local time.
        XCTAssertEqual(solarElevation(latitude: -33.8568, longitude: 151.2153, at: utc("2024-09-22T15:00:00Z")), -52.095, accuracy: 0.05)
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
    func testEntityIdShape() {
        XCTAssertTrue(Config.isEntityId("light.office_2"))
        for bad in ["light", "light.", ".x", "light.Office", "light.a.b", "light.x')}}{{ 7*7 }}", "light.x }}", "light.x\n", "light.x y", ""] {
            XCTAssertFalse(Config.isEntityId(bad), bad)
        }
    }
    func testInjectedEntityIdIsRejectedAndNotUsed() {
        let text = #"{ "homeAssistant": { "url": "http://ha.local:8123", "cover": "cover.x')}}{{ 7*7 }}{{('" },"#
            + #" "monitors": [ { "match": "DELL", "day": 60 } ] }"#
        let (c, err) = Config.load(from: write(text))
        XCTAssertTrue(err?.contains("homeAssistant.cover") ?? false, err ?? "")
        XCTAssertNil(c.homeAssistant)                       // source settings dropped
        XCTAssertEqual(c.resolvedSource().0, .off)
        XCTAssertEqual(c.monitors?.first?.day, 60)          // monitors kept
    }
    func testInjectedMonitorEntityIsRejected() {
        let text = #"{ "homeAssistant": { "url": "http://ha.local:8123" }, "monitors": [ { "match": "DELL", "homeAssistant": { "sensor": "sensor.a/../../api/services" } } ] }"#
        let (_, err) = Config.load(from: write(text))
        XCTAssertTrue(err?.contains("homeAssistant.sensor") ?? false, err ?? "")
    }
    func testURLMustBeHTTP() {
        let (c, err) = Config.load(from: write(#"{ "homeAssistant": { "url": "file:///etc/passwd" } }"#))
        XCTAssertNotNil(err); XCTAssertNil(c.homeAssistant)
    }
    func testCleartextNote() {
        for local in ["http://192.168.1.20:8123", "http://10.0.0.2", "http://172.20.1.1", "http://homeassistant.local:8123",
                      "http://homeassistant:8123", "http://localhost:8123", "http://[fd00::1]:8123", "https://ha.example.com"] {
            XCTAssertFalse(Config.isCleartextToNonLocal(local), local)
        }
        XCTAssertTrue(Config.isCleartextToNonLocal("http://ha.example.com"))
        XCTAssertTrue(Config.isCleartextToNonLocal("http://203.0.113.5:8123"))
        // A name that merely starts like a private IP or like fc00::/7 is still a public name.
        XCTAssertTrue(Config.isCleartextToNonLocal("http://10.1.2.3.example.com"))
        XCTAssertTrue(Config.isCleartextToNonLocal("http://fd.example.com"))
        XCTAssertTrue(Config.isCleartextToNonLocal("http://[2001:db8::1]:8123"))
        XCTAssertFalse(Config.isCleartextToNonLocal("http://[::1]:8123"))
        XCTAssertFalse(Config.isCleartextToNonLocal("http://[fe80::1]"))
    }
}

final class TemplateTests: XCTestCase {
    func testTemplateDropsAnyBadIdThatSlipsThrough() {
        let t = HATemplate.build(HAConfig(url: "http://x", cover: "cover.x')}}{{ 7*7 }}"), [("U", MonitorHA(day: "input_number.d'}}"))])
        XCTAssertFalse(t.contains("7*7"), t)
        XCTAssertFalse(t.contains("input_number.d'"), t)
        XCTAssertTrue(t.contains(#""pos": {{ 100 }}"#))
    }
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

final class WriteOnlyTests: XCTestCase {
    func testUnreadableMonitorStaysUntouchedUntilTheUserWrites() {
        // Never answered a read: automatic mode has nothing to work from (it may be showing another computer).
        XCTAssertNil(ReadState.unknown.afterRead(ok: false).current(reading: nil, slider: 50))
        XCTAssertTrue(ReadState.unknown.usable)   // the slider can still be tried
    }
    func testAcceptedUserWriteMakesItWriteOnly() {
        let s = ReadState.unknown.afterUserWrite(ok: true)
        XCTAssertEqual(s, .writeOnly)
        XCTAssertEqual(s.current(reading: nil, slider: 64), 64)   // the slider is the record of its level
        XCTAssertEqual(s.afterRead(ok: false), .writeOnly)
    }
    func testRefusedUserWriteMakesItSilent() {
        let s = ReadState.unknown.afterUserWrite(ok: false)
        XCTAssertEqual(s, .silent)
        XCTAssertFalse(s.usable)
        XCTAssertEqual(s.afterUserWrite(ok: true), .writeOnly)   // e.g. DDC/CI switched on in the monitor's menu
    }
    func testAReadingAlwaysWins() {
        XCTAssertEqual(ReadState.writeOnly.afterRead(ok: true), .readable)
        XCTAssertEqual(ReadState.readable.current(reading: 30, slider: 70), 30)
        // A readable monitor that stops answering is showing another computer: leave it alone.
        XCTAssertNil(ReadState.readable.afterRead(ok: false).current(reading: nil, slider: 70))
        XCTAssertEqual(ReadState.readable.afterUserWrite(ok: true), .readable)
    }
    func testWriteOnlyAutomaticFollowsTargetUntilTheUserMovesTheSlider() {
        // Untouched: the slider holds what automatic last sent, so the next target is applied.
        var st = HoldState(lastSet: 60, lastTarget: 60)
        let auto = decide(current: 60, want: 72, remote: nil, state: st, here: true, auto: true, dragging: false, hold: 5)
        XCTAssertEqual(auto.write, 72)
        XCTAssertFalse(auto.manual)
        // Moved by hand to 40: kept as manual while the target moves less than the hold.
        st = auto.state
        let held = decide(current: 40, want: 74, remote: nil, state: st, here: true, auto: true, dragging: false, hold: 5)
        XCTAssertNil(held.write)
        XCTAssertTrue(held.manual)
    }
}

final class SyncTests: XCTestCase {
    func testCaptureKeepsOffsetsFromTheFirstMonitor() {
        let s = SyncOffsets(levels: [(key: "a", level: 60), (key: "b", level: 40), (key: "c", level: 75)])
        XCTAssertEqual(s.offsets, ["a": 0, "b": -20, "c": 15])
    }

    func testMovingOneMovesTheOthersBySameAmount() {
        let s = SyncOffsets(levels: [(key: "a", level: 60), (key: "b", level: 40)])
        XCTAssertEqual(s.follow(key: "a", level: 70, keys: ["a", "b"]), ["b": 50])
        XCTAssertEqual(s.follow(key: "b", level: 10, keys: ["a", "b"]), ["a": 30])
    }

    func testClampingDoesNotLoseTheOffset() {
        let s = SyncOffsets(levels: [(key: "a", level: 60), (key: "b", level: 40)])
        XCTAssertEqual(s.follow(key: "a", level: 10, keys: ["a", "b"]), ["b": 0])     // clamped at 0
        XCTAssertEqual(s.follow(key: "a", level: 50, keys: ["a", "b"]), ["b": 30])    // back in line
        XCTAssertEqual(s.follow(key: "b", level: 100, keys: ["a", "b"]), ["a": 100])  // 120 clamped
    }

    func testAutomaticTargetFromTheLeader() {
        let s = SyncOffsets(levels: [(key: "a", level: 60), (key: "b", level: 45)])
        XCTAssertEqual(s.targets(leader: "a", leaderTarget: 80, keys: ["a", "b"]), ["a": 80, "b": 65])
        // The second monitor can lead too (the first one is unplugged): same group, same offsets.
        XCTAssertEqual(s.targets(leader: "b", leaderTarget: 20, keys: ["b"]), ["b": 20])
    }

    func testNewMonitorJoinsAtItsCurrentOffset() {
        var s = SyncOffsets(levels: [(key: "a", level: 60), (key: "b", level: 40)])
        s.adopt([(key: "a", level: 70), (key: "c", level: 50)])
        XCTAssertEqual(s.offsets["c"], -20)   // base is 70 now
        XCTAssertEqual(s.offsets["b"], -20)   // unplugged monitor keeps its offset
    }

    func testGroupStartsAgainWhenNoKnownMonitorIsConnected() {
        var s = SyncOffsets(levels: [(key: "a", level: 60), (key: "b", level: 40)])
        s.adopt([(key: "x", level: 30), (key: "y", level: 50)])
        XCTAssertEqual(s.offsets, ["x": 0, "y": 20])
    }

    func testUnknownMonitorIsIndependent() {
        let s = SyncOffsets(levels: [(key: "a", level: 60)])
        XCTAssertEqual(s.follow(key: "z", level: 30, keys: ["a", "z"]), [:])
        XCTAssertEqual(s.follow(key: "a", level: 30, keys: ["a", "z"]), [:])
    }
}
