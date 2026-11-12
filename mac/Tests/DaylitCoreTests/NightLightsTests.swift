import XCTest
@testable import DaylitCore

/// The target rule before the optional nightLights level, copied as it was: the regression guard.
private func targetBefore(day: Double, blindDown: Double, night: Double, elev: Double, pos: Double, lights: Bool,
                          tuning t: Tuning = Tuning(), light: Double = 1) -> Int {
    let sun = min(daylightFraction(elevation: elev, tuning: t), light)
    let daytime = blindDown + (day - blindDown) * pos / 100
    var v = night + (daytime - night) * sun
    if lights && elev < t.lightsBoostSunBelow { v = max(v, night + t.lightsBoost) }
    return Int(min(max(v, 0), 100).rounded())
}

final class NightLightsTargetTests: XCTestCase {
    // The spec's example monitor: day 95, blind down 62, night 60, lights on 80.
    func t(elev: Double, pos: Double, lights: Bool, light: Double = 1, nightLights: Double? = 80) -> Int {
        target(day: 95, blindDown: 62, night: 60, elev: elev, pos: pos, lights: lights, light: light, nightLights: nightLights)
    }

    func testWithoutNightLightsTheTargetIsExactlyAsBefore() {
        var t = Tuning(); t.brightness = .init(); t.brightness?.lightsBoost = 12; t.brightness?.lightsBoostSunBelow = 4
        var checked = 0
        for tuning in [Tuning(), t] {
            for levels in [(70.0, 40.0, 20.0), (95, 62, 75), (100, 78, 75), (30, 50, 90), (0, 0, 0), (100, 100, 100)] {
                for e in stride(from: -12.0, through: 40, by: 0.5) {
                    for pos in [0.0, 25, 40, 58, 100] {
                        for lights in [false, true] {
                            for light in [0.2, 0.5, 0.8, 1] {
                                XCTAssertEqual(
                                    target(day: levels.0, blindDown: levels.1, night: levels.2, elev: e, pos: pos, lights: lights, tuning: tuning, light: light),
                                    targetBefore(day: levels.0, blindDown: levels.1, night: levels.2, elev: e, pos: pos, lights: lights, tuning: tuning, light: light),
                                    "levels \(levels) elev \(e) pos \(pos) lights \(lights) light \(light)")
                                checked += 1
                            }
                        }
                    }
                }
            }
        }
        XCTAssertEqual(checked, 2 * 6 * 105 * 5 * 2 * 4)
    }

    func testLightsOffBlendsTowardNightWithNoBoost() {
        for e in stride(from: -10.0, through: 20, by: 0.5) {
            for pos in [0.0, 40, 100] {
                XCTAssertEqual(t(elev: e, pos: pos, lights: false),
                               targetBefore(day: 95, blindDown: 62, night: 60, elev: e, pos: pos, lights: false))
            }
        }
        XCTAssertEqual(t(elev: -10, pos: 100, lights: false), 60)   // dark, lights off: night, not night + 5
    }

    func testLightsOnWithTheSunHighChangeNothing() {
        for pos in [0.0, 40, 58, 100] {
            for light in [0.3, 0.5, 1] {
                XCTAssertEqual(t(elev: 30, pos: pos, lights: true, light: light), t(elev: 30, pos: pos, lights: false, light: light))
            }
        }
    }

    func testLightsOnWithTheSunDownGiveTheLightsOnLevel() {
        for e in [-3.0, -6, -20] {
            for pos in [0.0, 100] { XCTAssertEqual(t(elev: e, pos: pos, lights: true), 80) }
        }
    }

    func testTheDuskTransitionHasNoStep() {
        for pos in [0.0, 40, 100] {
            for light in [0.5, 1] {
                var prev = t(elev: -6, pos: pos, lights: true, light: light)
                for i in 1...260 {   // -6° to 20° in steps of 0.1°
                    let now = t(elev: -6 + Double(i) / 10, pos: pos, lights: true, light: light)
                    XCTAssertLessThanOrEqual(abs(now - prev), 2, "pos \(pos) light \(light) at \(-6 + Double(i) / 10)°")
                    prev = now
                }
            }
        }
    }

    func testTheExampleValues() {
        // A cloudy morning: the sun is high but clouds cap daylight at half.
        XCTAssertEqual(t(elev: 30, pos: 40, lights: true, light: 0.5), 68)    // 67.6
        XCTAssertEqual(t(elev: 30, pos: 58, lights: true, light: 0.5), 71)    // 70.57 (the spec rounds this to 70)
        XCTAssertEqual(t(elev: 30, pos: 58, lights: true, light: 0.49), 70)   // 70.36
        XCTAssertEqual(t(elev: 30, pos: 100, lights: true, light: 0.55), 79)  // 79.25
        XCTAssertEqual(t(elev: -10, pos: 100, lights: true), 80)              // a dark evening with the lights on
        // The same cloudy morning before: night 75 kept it at 75 or more.
        XCTAssertEqual(target(day: 95, blindDown: 62, night: 75, elev: 30, pos: 40, lights: true, light: 0.5), 75)
    }
}

final class NightLightsLevelsTests: XCTestCase {
    func testHomeAssistantValueWinsWhenZeroOrMore() {
        XCTAssertEqual(effectiveLevels(local: [70, 40, 20, 50], fromHA: [-1, -1, -1, 65, -1, 0]), [70, 40, 20, 65])
        XCTAssertEqual(effectiveLevels(local: [70, 40, 20, 50], fromHA: [-1, -1, -1, 0, -1, 0]), [70, 40, 20, 0])
        XCTAssertEqual(effectiveLevels(local: [70, 40, 20, 50], fromHA: [-1, -1, -1, -1, -1, 0]), [70, 40, 20, 50])
        XCTAssertEqual(effectiveLevels(local: [70, 40, 20], fromHA: [-1, -1, -1, 65, -1, 0]), [70, 40, 20, 65])
    }
    func testWithNoValueThereIsNoNightLights() {
        XCTAssertEqual(effectiveLevels(local: [70, 40, 20], fromHA: [-1, -1, -1, -1, -1, 0]), [70, 40, 20])
        XCTAssertEqual(effectiveLevels(local: [70, 40, 20], fromHA: nil), [70, 40, 20])
        XCTAssertEqual(effectiveLevels(local: [70, 40, 20, -1], fromHA: nil), [70, 40, 20])
        XCTAssertNil(nightLightsLevel([70, 40, 20]))
        XCTAssertEqual(nightLightsLevel([70, 40, 20, 80]), 80)
    }
}

final class NightLightsFallbackTests: XCTestCase {
    func testHomeAssistantsAnswerIsUsedWhileItGivesOne() {
        for has in [false, true] {
            XCTAssertTrue(roomLights(reported: true, fromHA: true, last: false, hasNightLights: has))
            XCTAssertFalse(roomLights(reported: false, fromHA: true, last: true, hasNightLights: has))
        }
    }
    func testAMonitorWithNightLightsKeepsTheLastLightsStateWhileHomeAssistantIsDown() {
        XCTAssertTrue(roomLights(reported: false, fromHA: false, last: true, hasNightLights: true))
        XCTAssertFalse(roomLights(reported: false, fromHA: false, last: false, hasNightLights: true))
        XCTAssertFalse(roomLights(reported: false, fromHA: false, last: nil, hasNightLights: true))   // none seen yet: off
    }
    func testAMonitorWithoutNightLightsCountsTheLightsAsOffInTheFallbackAsBefore() {
        XCTAssertFalse(roomLights(reported: false, fromHA: false, last: true, hasNightLights: false))
    }
    func testALitEveningDoesNotDropToNightDuringAnOutage() {
        let lit = roomLights(reported: false, fromHA: false, last: true, hasNightLights: true)
        XCTAssertEqual(target(day: 95, blindDown: 62, night: 60, elev: -10, pos: 100, lights: lit, nightLights: 80), 80)
    }
}

final class NightLightsConfigTests: XCTestCase {
    func testLoadsTheLocalLevelAndTheHelper() {
        let text = #"{"monitors": [{"match": "Dell", "night": 60, "nightLights": 80, "homeAssistant": {"nightLights": "input_number.lit"}}]}"#
        let (c, err) = Config.parse(Data(text.utf8))
        XCTAssertNil(err)
        XCTAssertEqual(c?.monitors?.first?.nightLights, 80)
        XCTAssertEqual(c?.monitors?.first?.homeAssistant?.nightLights, "input_number.lit")
    }
    func testWithoutTheKeyThereIsNoLevel() {
        let (c, _) = Config.parse(Data(#"{"monitors": [{"match": "Dell", "night": 60}]}"#.utf8))
        XCTAssertNil(c?.monitors?.first?.nightLights)
    }
    func testALevelOutsideZeroToHundredIsAProblem() {
        for v in ["-1", "101"] {
            let (_, err) = Config.parse(Data(#"{"monitors": [{"match": "Dell", "nightLights": \#(v)}]}"#.utf8))
            XCTAssertEqual(err, #"config.json: monitor "Dell" nightLights is 0 to 100"#)
        }
        XCTAssertNil(Config.parse(Data(#"{"monitors": [{"match": "Dell", "nightLights": 0}]}"#.utf8)).1)
        XCTAssertNil(Config.parse(Data(#"{"monitors": [{"match": "Dell", "nightLights": 100}]}"#.utf8)).1)
    }
    func testAHelperThatIsNotAnEntityIdIsAProblem() {
        let (_, err) = Config.parse(Data(#"{"monitors": [{"match": "Dell", "homeAssistant": {"nightLights": "lit"}}]}"#.utf8))
        XCTAssertEqual(err, #"config.json: monitor "Dell" homeAssistant.nightLights is not an entity id like light.office"#)
    }

    func json(_ d: Data) -> [String: Any] { try! JSONSerialization.jsonObject(with: d) as! [String: Any] }
    let original = #"{"monitors": [{"match": "Dell", "night": 60, "nightLights": 80, "control": "ddc", "homeAssistant": {"nightLights": "input_number.lit"}}]}"#
    func edit(editable: Bool, value: Int?) -> SettingsEdit {
        var m = SettingsEdit.Monitor(name: "Dell U2723QE", suggestedMatch: "U2723QE", label: "Dell U2723QE", day: 95, blindDown: 62, night: 60)
        m.nightLightsEditable = editable; m.nightLights = value
        return SettingsEdit(source: "off", monitors: [m])
    }
    func testSettingsSavesTheLevelAndKeepsEveryOtherKey() throws {
        let m = (json(try ConfigPatch.apply(edit(editable: true, value: 85), to: Data(original.utf8)))["monitors"] as! [[String: Any]])[0]
        XCTAssertEqual(m["nightLights"] as? Int, 85)
        XCTAssertEqual(m["control"] as? String, "ddc")
        XCTAssertEqual((m["homeAssistant"] as? [String: Any])?["nightLights"] as? String, "input_number.lit")
    }
    func testAnEmptyBoxRemovesTheKey() throws {
        let m = (json(try ConfigPatch.apply(edit(editable: true, value: nil), to: Data(original.utf8)))["monitors"] as! [[String: Any]])[0]
        XCTAssertNil(m["nightLights"])
    }
    func testWithoutTheBoxTheFileKeepsItsLevel() throws {
        let m = (json(try ConfigPatch.apply(edit(editable: false, value: nil), to: Data(original.utf8)))["monitors"] as! [[String: Any]])[0]
        XCTAssertEqual(m["nightLights"] as? Int, 80)
    }
    func testAValueOutOfRangeIsClamped() throws {
        let m = (json(try ConfigPatch.apply(edit(editable: true, value: 140), to: Data(original.utf8)))["monitors"] as! [[String: Any]])[0]
        XCTAssertEqual(m["nightLights"] as? Int, 100)
    }
}

final class NightLightsHomeAssistantTests: XCTestCase {
    func testTheTemplateAsksForTheHelperAsTheFourthNumber() {
        let t = HATemplate.build(HAConfig(url: "http://x"), [("U", MonitorHA(nightLights: "input_number.lit"))])
        XCTAssertTrue(t.contains(#""U": [-1, -1, -1, {{ states('input_number.lit') | float(-1) }}, -1, 0]"#), t)
    }
    func testAMonitorWithoutTheHelperGetsMinusOneThere() {
        let t = HATemplate.build(HAConfig(url: "http://x"), [("U", MonitorHA(day: "input_number.d"))])
        XCTAssertTrue(t.contains(#""U": [{{ states('input_number.d') | float(-1) }}, -1, -1, -1, -1, 0]"#), t)
    }
    func testABadHelperIdIsDroppedFromTheTemplate() {
        let t = HATemplate.build(HAConfig(url: "http://x"), [("U", MonitorHA(day: "input_number.d", nightLights: "input_number.x'}}"))])
        XCTAssertFalse(t.contains("input_number.x"))
    }
    func testTheAnswerHasSixNumbersPerMonitor() {
        let ok = #"{"elev": 1, "pos": 1, "lights": true, "auto": null, "bri": 0, "sat": 0, "m": {"U": [80, 40, 20, 72, -1, 0]}}"#
        XCTAssertEqual(HAState.parse(Data(ok.utf8))?.m["U"], [80, 40, 20, 72, -1, 0])
        let old = #"{"elev": 1, "pos": 1, "lights": true, "auto": null, "bri": 0, "sat": 0, "m": {"U": [80, 40, 20, -1, 0]}}"#
        XCTAssertNil(HAState.parse(Data(old.utf8)))
    }
    func testTheSunFallbackKeepsNightLightsButNotTheSetHelper() {
        let row: [Double] = [94, 60, 30, 72, 55, 1_700_000_000]
        let kept = fallbackLevels(row)
        XCTAssertEqual(kept, [94, 60, 30, 72])
        XCTAssertEqual(effectiveLevels(local: [70, 40, 20], fromHA: kept), [94, 60, 30, 72])
        XCTAssertEqual(RemoteSet(row: row), RemoteSet(value: 55, changed: 1_700_000_000))
        XCTAssertNil(RemoteSet(row: kept))
    }
}

final class NightLightsSuggestTests: XCTestCase {
    let four: [Double] = [95, 62, 60, 80]
    func sample(elev: Double, lights: Bool, levels: [Double]) -> Sample? {
        Suggest.makeSample(monitor: "m", chosen: 70, auto: 75, elev: elev, pos: 40, lights: lights, light: 1,
                           levels: levels, tuning: Tuning(), now: 1_000, context: SampleContext())
    }
    func testNoSampleWhileTheLightsAreOnAndTheSunIsNotFullyUp() {
        for e in [-10.0, 0, 5, 11.9] { XCTAssertNil(sample(elev: e, lights: true, levels: four), "elev \(e)") }
    }
    func testSamplesWithTheLightsOffOrTheSunFullyUp() {
        XCTAssertEqual(sample(elev: 5, lights: false, levels: four)?.levels, four)
        XCTAssertEqual(sample(elev: 12, lights: true, levels: four)?.levels, four)
    }
    func testAMonitorWithoutNightLightsStillRecordsThoseTicks() {
        // At 5° the boost no longer applies, so the three-level rule decides and the tick is a sample.
        XCTAssertNotNil(sample(elev: 5, lights: true, levels: [95, 62, 60]))
    }
    func testChangingNightLightsMakesOlderSamplesStale() {
        let x = sample(elev: 30, lights: false, levels: four)!
        XCTAssertEqual(Suggest.dropStale([x], current: ["m": [95, 62, 60, 85]]), [])
        XCTAssertEqual(Suggest.dropStale([x], current: ["m": [95, 62, 60]]), [])
        XCTAssertEqual(Suggest.dropStale([x], current: ["m": four]), [x])
        var r = Recorder()
        r.handChanged(monitor: "m", sample: x)
        XCTAssertNil(r.settle(monitor: "m", held: true, levels: [95, 62, 60, 85], now: x.at + 400))
    }
    func testTheFitKeepsNightLightsAsItIs() {
        let samples = (0..<6).map { i in
            Sample(monitor: "m", chosen: 55, auto: 62, s: 1, p: 0, elev: 30, lights: false, levels: four, at: Double(i) * 86400)
        }
        let fitted = Suggest.fit(samples, levels: four, candidates: [.blindDown])
        XCTAssertEqual(fitted.count, 4)
        XCTAssertEqual(fitted[3], 80)
        XCTAssertEqual(fitted[1], 56, accuracy: 0.01)   // (6 · 55 + 62) / 7
    }
    func testFourLevelSamplesSurviveTheFile() {
        let x = sample(elev: 30, lights: false, levels: four)!
        XCTAssertEqual(Suggest.decode(Suggest.encode([x])), [x])
    }
}

final class FieldUnchangedTests: XCTestCase {
    func testUntouchedTextKeepsTheFilesValue() {
        let r = ContrastRule.parseField("72.5", unchangedFrom: "72.5")
        XCTAssertTrue(r.ok); XCTAssertTrue(r.keep); XCTAssertNil(r.value)
        XCTAssertTrue(ContrastRule.parseField("", unchangedFrom: "").keep)
    }
    func testAnEditedBoxIsParsedAndRounded() {
        let r = ContrastRule.parseField("73.4", unchangedFrom: "72.5")
        XCTAssertTrue(r.ok); XCTAssertFalse(r.keep); XCTAssertEqual(r.value, 73)
        XCTAssertNil(ContrastRule.parseField("", unchangedFrom: "72.5").value)
        XCTAssertFalse(ContrastRule.parseField("", unchangedFrom: "72.5").keep)
        XCTAssertFalse(ContrastRule.parseField("x", unchangedFrom: "72.5").ok)
    }
}

final class NightLightsExplainTests: XCTestCase {
    func testTheLightsStepShowsTheLightsOnLevel() {
        let d = explain(day: 95, blindDown: 62, night: 60, elev: -10, pos: 100, lights: true, nightLights: 80)
        XCTAssertEqual(d.level, 80)
        XCTAssertEqual(d.steps.first { $0.title == "Lights" }?.value, "on → 80")
    }
    func testLightsOffShowOffUntilTheSunIsFullyUp() {
        XCTAssertEqual(explain(day: 95, blindDown: 62, night: 60, elev: 5, pos: 100, lights: false, nightLights: 80)
                        .steps.first { $0.title == "Lights" }?.value, "off")
        XCTAssertEqual(explain(day: 95, blindDown: 62, night: 60, elev: 30, pos: 100, lights: false, nightLights: 80)
                        .steps.first { $0.title == "Lights" }?.value, "no effect by day")
    }
    func testTheLevelEqualsTheTarget() {
        for e in stride(from: -8.0, through: 20, by: 0.5) {
            for lights in [false, true] {
                XCTAssertEqual(explain(day: 95, blindDown: 62, night: 60, elev: e, pos: 40, lights: lights, light: 0.7, nightLights: 80).level,
                               target(day: 95, blindDown: 62, night: 60, elev: e, pos: 40, lights: lights, light: 0.7, nightLights: 80))
            }
        }
    }
}
