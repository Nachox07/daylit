import XCTest
@testable import DaylitCore

final class LevelSafetyTests: XCTestCase {
    func testHugeLevelsGiveAValidTargetInsteadOfNaN() {
        // 1e308 and -1e308 overflow the blend to NaN when used as they are.
        for pos in [0.0, 50, 100] {
            let v = target(day: 1e308, blindDown: -1e308, night: 20, elev: 20, pos: pos, lights: false)
            XCTAssertTrue((0...100).contains(v))
        }
        XCTAssertEqual(target(day: 1e308, blindDown: -1e308, night: 20, elev: 20, pos: 100, lights: false), 100)
        XCTAssertEqual(target(day: 1e308, blindDown: -1e308, night: 20, elev: 20, pos: 0, lights: false), 0)
    }

    func testNonFiniteInputsNeverCrashTarget() {
        XCTAssertEqual(target(day: .nan, blindDown: .infinity, night: -.infinity, elev: 20, pos: .nan, lights: true, nightLights: .nan), 100)   // NaN counts as 0, infinity as the nearest end
        let v = target(day: 70, blindDown: 40, night: 20, elev: .nan, pos: 100, lights: false)
        XCTAssertEqual(v, 20)   // an elevation that is not a number: the night level
        XCTAssertEqual(target(day: 70, blindDown: 40, night: 20, elev: 20, pos: 100, lights: false, light: .nan), 70)   // a light scale that is not a number caps nothing
    }

    func testHomeAssistantLevelAbove100IsClamped() {
        // An input_number with max 255 set to 200 means 100 here, so the blind blend keeps its meaning.
        let lv = effectiveLevels(local: [70, 40, 20], fromHA: [200, 300, 400, 250, -1, 0])
        XCTAssertEqual(lv, [100, 100, 100, 100])
        XCTAssertEqual(target(day: lv[0], blindDown: lv[1], night: lv[2], elev: 30, pos: 50, lights: false), 100)
    }

    func testLocalLevelsAreClampedToo() {
        XCTAssertEqual(effectiveLevels(local: [1e308, -1e308, .nan, 150], fromHA: nil), [100, 0, 0, 100])
    }

    func testInRangeLevelsPassThrough() {
        XCTAssertEqual(effectiveLevels(local: [70, 40, 20], fromHA: [80, -1, 30, -1, -1, 0]), [80, 40, 30])
    }

    func testConfigRejectsOutOfRangeLocalLevels() {
        for key in ["day", "blindDown", "night"] {
            for v in ["101", "-1", "1e308", "-1e308"] {
                let (_, err) = Config.parse(Data(#"{"monitors": [{"match": "Dell", "\#(key)": \#(v)}]}"#.utf8))
                XCTAssertEqual(err, #"config.json: monitor "Dell" \#(key) is 0 to 100"#, "\(key)=\(v)")
            }
            XCTAssertNil(Config.parse(Data(#"{"monitors": [{"match": "Dell", "\#(key)": 0}]}"#.utf8)).1)
            XCTAssertNil(Config.parse(Data(#"{"monitors": [{"match": "Dell", "\#(key)": 100}]}"#.utf8)).1)
        }
    }

    func testBadLocalLevelStillLeavesAUsableTarget() {
        let (c, err) = Config.parse(Data(#"{"monitors": [{"match": "Dell", "day": 1e308, "blindDown": -1e308}]}"#.utf8))
        XCTAssertNotNil(err)
        let m = c!.monitors![0]
        let lv = effectiveLevels(local: [m.day ?? 70, m.blindDown ?? 40, m.night ?? 20], fromHA: nil)
        XCTAssertTrue((0...100).contains(target(day: lv[0], blindDown: lv[1], night: lv[2], elev: 20, pos: 50, lights: false)))
    }
}

final class HAMissingEntityTests: XCTestCase {
    func testTemplateRendersNullForAMissingAutoSwitchAndSun() {
        let t = HATemplate.build(HAConfig(url: "http://x", autoSwitch: "input_boolean.auto", sun: "sun.home"), [])
        XCTAssertTrue(t.contains("is_state('input_boolean.auto','on') | tojson if states['input_boolean.auto'] else 'null'"), t)
        XCTAssertTrue(t.contains("state_attr('sun.home','elevation') | float(-10) if states['sun.home'] else 'null'"), t)
        let d = HATemplate.build(HAConfig(url: "http://x"), [])
        XCTAssertTrue(d.contains("states['sun.sun']"), d)
    }

    func testAnAnswerWithNullSunAndAutoParses() {
        let a = #"{"elev": null, "pos": 100, "lights": false, "auto": null, "bri": 0, "sat": 100, "m": {}}"#
        let s = HAState.parse(Data(a.utf8))
        XCTAssertNotNil(s)
        XCTAssertNil(s?.elev)
        XCTAssertEqual(s?.missingEntities(HAConfig(url: "http://x", autoSwitch: "input_boolean.auto", sun: "sun.home")),
                       ["input_boolean.auto", "sun.home"])
        XCTAssertEqual(s?.missingEntities(HAConfig(url: "http://x")), ["sun.sun"])   // no autoSwitch configured: null is normal
    }

    func testPresentEntitiesAreNotReportedMissing() {
        let a = #"{"elev": 12.5, "pos": 100, "lights": false, "auto": false, "bri": 0, "sat": 100, "m": {}}"#
        let s = HAState.parse(Data(a.utf8))!
        XCTAssertEqual(s.missingEntities(HAConfig(url: "http://x", autoSwitch: "input_boolean.auto")), [])
        XCTAssertNil(HAState.missingNote([]))
    }

    func testProblemLineNamesTheEntity() {
        XCTAssertEqual(HAState.missingNote(["input_boolean.nope"]), "Home Assistant has no entity input_boolean.nope")
    }
}

final class AutomaticFallbackTests: XCTestCase {
    func testOutageKeepsWhatHomeAssistantLastSaid() {
        XCTAssertFalse(automaticFallback(hasSwitch: true, lastFromHA: false, local: true))   // off in HA stays off
        XCTAssertTrue(automaticFallback(hasSwitch: true, lastFromHA: true, local: false))
    }
    func testWithoutAStateSeenOrASwitchTheLocalSettingDecides() {
        XCTAssertTrue(automaticFallback(hasSwitch: true, lastFromHA: nil, local: true))
        XCTAssertFalse(automaticFallback(hasSwitch: false, lastFromHA: true, local: false))
    }
}

final class DDCToolRuleTests: XCTestCase {
    private func resolve(_ c: String?, path: [String] = ["/usr/bin", "/opt/tools"], present: Set<String> = []) -> (path: String?, note: String?) {
        DDCToolRule.resolve(configured: c, pathDirs: path, exists: { present.contains($0) })
    }
    func testUnsetUsesTheDefaultWithoutANote() {
        XCTAssertNil(resolve(nil).path); XCTAssertNil(resolve(nil).note)
        XCTAssertNil(resolve("  ").note)
    }
    func testHomebrewLocationsAreAccepted() {
        XCTAssertEqual(resolve("/opt/homebrew/bin/m1ddc").path, "/opt/homebrew/bin/m1ddc")
        XCTAssertEqual(resolve("/usr/local/bin/m1ddc").path, "/usr/local/bin/m1ddc")
    }
    func testAnM1ddcOnThePathIsAccepted() {
        XCTAssertEqual(resolve("m1ddc", present: ["/opt/tools/m1ddc"]).path, "/opt/tools/m1ddc")
        XCTAssertEqual(resolve("/opt/tools/m1ddc").path, "/opt/tools/m1ddc")
        XCTAssertNil(resolve("m1ddc").path)   // not on the PATH: default, nothing run from the file
    }
    func testAnyOtherProgramIsIgnoredWithANote() {
        for bad in ["/bin/sh", "/tmp/m1ddc", "/opt/tools/../tools/m1ddc", "/Users/x/evil", "sh", "m1ddc2", "/opt/tools/other", "../m1ddc"] {
            let r = resolve(bad, present: ["/opt/tools/m1ddc"])
            XCTAssertNil(r.path, bad)
            XCTAssertEqual(r.note, DDCToolRule.note, bad)
        }
    }
    func testConfigWithABadValueKeepsNoDdcTool() {
        let (c, err) = Config.parse(Data(#"{"ddcTool": "/bin/sh", "homeAssistant": {"url": "ftp://x"}}"#.utf8))
        XCTAssertNotNil(err)
        XCTAssertNil(c?.ddcTool)
        XCTAssertEqual(Config.parse(Data(#"{"ddcTool": "/bin/sh"}"#.utf8)).0?.ddcTool, "/bin/sh")   // a valid file still carries it; the rule decides
    }
}
