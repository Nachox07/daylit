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
    func testLitTwilightOnAMonitorWithNightLightsIsASample() {
        // The four-level weights explain these ticks, so they are recorded like any other.
        for e in [-10.0, 0, 5, 11.9] { XCTAssertEqual(sample(elev: e, lights: true, levels: four)?.lights, true, "elev \(e)") }
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

/// A sample as the app records it: daylight capped by `light`, `auto` from the real target with these levels.
private func recorded(_ day: Int, _ hour: Double, elev: Double, p: Double, light: Double = 1, lights: Bool, chosen: Int,
                      levels l: [Double]) -> Sample {
    let s = min(daylightFraction(elevation: elev), light)
    let auto = target(day: l[0], blindDown: l[1], night: l[2], elev: elev, pos: p * 100, lights: lights, light: light,
                      nightLights: nightLightsLevel(l))
    return Sample(monitor: "m", chosen: chosen, auto: auto, s: s, p: p, elev: elev, lights: lights, levels: l,
                  at: Fixture.t0 + Double(day) * 86400 + hour * 3600)
}

final class NightLightsWeightTests: XCTestCase {
    let four: [Double] = [95, 62, 60, 80]

    func testWithTheLightsOnWhatDaylightLeavesIsSplitBetweenNightAndLightsOn() {
        // Sun at 3° (daylight 0.4), blind open, lights on: 0.6 left, 40% of it to night and 60% to lights on.
        let x = recorded(0, 18, elev: 3, p: 1, lights: true, chosen: 70, levels: four)
        let w = Suggest.weights(x, nightLights: true)
        for (got, want) in zip(w, [0.4, 0, 0.24, 0.36]) { XCTAssertEqual(got, want, accuracy: 1e-9) }
        XCTAssertEqual(w.reduce(0, +), 1, accuracy: 1e-9)
        var off = x; off.lights = false
        for (got, want) in zip(Suggest.weights(off, nightLights: true), [0.4, 0, 0.6, 0]) { XCTAssertEqual(got, want, accuracy: 1e-9) }
        for (got, want) in zip(Suggest.weights(x, nightLights: false), [0.4, 0, 0.6, 0]) { XCTAssertEqual(got, want, accuracy: 1e-9) }
    }

    func testTheWeightsGiveTheTarget() {
        // The fit is only right when the weights are the target's own blend: check them against it everywhere.
        for elev in [-8.0, -3, 0, 3, 6, 9, 12, 30] {
            for p in [0.0, 0.4, 1] {
                for light in [0.3, 1] {
                    for lights in [false, true] {
                        let x = recorded(0, 12, elev: elev, p: p, light: light, lights: lights, chosen: 50, levels: four)
                        let w = Suggest.weights(x, nightLights: true)
                        let blend = zip(w, four).map { $0 * $1 }.reduce(0, +)
                        XCTAssertEqual(blend, Double(x.auto), accuracy: 0.5, "elev \(elev) p \(p) light \(light) lights \(lights)")
                    }
                }
            }
        }
    }

    func testNightAndLightsOnCountFromPointFourFiveWhenTheirsIsTheLargestWeight() {
        let three: [Double] = [95, 62, 60]
        // A cloudy morning, daylight held to half, blind 40% open: night 0.5, day 0.2, blind down 0.3.
        let cloudy = recorded(0, 9, elev: 20, p: 0.4, light: 0.5, lights: false, chosen: 63, levels: three)
        XCTAssertTrue(Suggest.dominates(cloudy, .night))
        // Daylight 0.56: night 0.44, under the bar.
        XCTAssertFalse(Suggest.dominates(recorded(0, 9, elev: 20, p: 0.4, light: 0.56, lights: false, chosen: 63, levels: three), .night))
        // A dark evening with the lights on: all of it is the lights-on level, none night.
        let lit = recorded(0, 20, elev: -6, p: 1, lights: true, chosen: 72, levels: four)
        XCTAssertTrue(Suggest.dominates(lit, .nightLights))
        XCTAssertFalse(Suggest.dominates(lit, .night))
        // The same evening on a monitor without the level: night, as before.
        XCTAssertTrue(Suggest.dominates(recorded(0, 20, elev: -6, p: 1, lights: true, chosen: 72, levels: three), .night))
        // An even split (no daylight counted, sun at 4.5°: half to each) counts for neither.
        let even = recorded(0, 17, elev: 4.5, p: 1, light: 0, lights: true, chosen: 70, levels: four)
        XCTAssertFalse(Suggest.dominates(even, .night))
        XCTAssertFalse(Suggest.dominates(even, .nightLights))
        // Day and blind down keep their 0.55 bar: 0.5 of day is not enough even when it is the largest.
        XCTAssertFalse(Suggest.dominates(recorded(0, 12, elev: 4.5, p: 1, lights: false, chosen: 70, levels: three), .day))
    }

    func testTheFitRecoversAllFourLevels() {
        let truth: [Double] = [90, 50, 30, 70]
        var samples: [Sample] = []
        for _ in 0..<20 {
            for elev in [-6.0, 0, 4.5, 9, 30] {
                for p in [0.0, 0.5, 1] {
                    for lights in [false, true] {
                        var x = recorded(0, 12, elev: elev, p: p, lights: lights, chosen: 0, levels: [70, 40, 20, 60])
                        let w = Suggest.weights(x, nightLights: true)
                        x.chosen = Int(zip(w, truth).map { $0 * $1 }.reduce(0, +).rounded())
                        samples.append(x)
                    }
                }
            }
        }
        let f = Suggest.fit(samples, levels: [70, 40, 20, 60], candidates: [.day, .blindDown, .night, .nightLights])
        for k in 0..<4 { XCTAssertEqual(f[k], truth[k], accuracy: 1, "level \(k)") }
    }

    func testAMonitorWithoutNightLightsNeverFitsOne() {
        let three: [Double] = [95, 62, 60]
        let lit = (0..<6).map { recorded($0, 20, elev: -6, p: 1, lights: true, chosen: 50, levels: three) }
        XCTAssertFalse(Suggest.candidates(lit, dayOf: Fixture.utcDay).contains(.nightLights))
        XCTAssertEqual(Suggest.fit(lit, levels: three, candidates: [.nightLights]), three)
    }

    func testSamplesSavedBeforeKeepLoadingAndCountTheSame() {
        // A corrections.json written before the four-level fit: a lights-on sample in full daylight on a monitor
        // with nightLights (the only lit sample it recorded then) and a three-level one.
        let text = #"""
        {"samples": [
          {"monitor": "m", "chosen": 70, "auto": 75, "s": 1, "p": 0.4, "elev": 30, "lights": true, "levels": [95, 62, 60, 80], "at": 1793577600},
          {"monitor": "m", "chosen": 70, "auto": 86, "s": 1, "p": 0.35, "elev": 30, "lights": false, "levels": [100, 78, 75], "at": 1793577600}
        ]}
        """#
        let got = Suggest.decode(Data(text.utf8))
        XCTAssertEqual(got.count, 2)
        // Sun fully up: the lights add nothing, so the sample weighs what it did with three levels.
        for (a, b) in zip(Suggest.weights(got[0], nightLights: true), Suggest.weights(s: 1, p: 0.4) + [0]) { XCTAssertEqual(a, b, accuracy: 1e-9) }
        XCTAssertEqual(Suggest.decode(Suggest.encode(got)), got)
    }
}

/// Cloudy mornings and lit evenings: the user wants a dimmer room darker and a lit evening a little lower.
final class NightLightsSuggestionTests: XCTestCase {
    let four: [Double] = [95, 62, 60, 80]
    let whole: [NumberStep?] = [.whole, .whole, .whole, .whole]   // a local nightLights, or one that may be added
    /// Sunny, blind fully down; sunny, blind open; a dark evening with the lights on.
    static let references: [(elev: Double, pos: Double, light: Double, lights: Bool)] = [(30, 0, 1, false), (30, 100, 1, false), (-6, 100, 1, true)]
    func t(_ l: [Double], _ r: (elev: Double, pos: Double, light: Double, lights: Bool)) -> Int {
        target(day: l[0], blindDown: l[1], night: l[2], elev: r.elev, pos: r.pos, lights: r.lights, light: r.light,
               nightLights: nightLightsLevel(l))
    }
    func applied(_ l: [Double], _ s: Suggestion) -> [Double] {
        var out = l
        for c in s.changes { if c.level.rawValue < out.count { out[c.level.rawValue] = c.to } else { out.append(c.to) } }
        return out
    }
    func suggest(_ samples: [Sample], levels: [Double], steps: [NumberStep?]? = nil) -> Suggestion? {
        Suggest.suggestion(monitor: "m", samples: samples, levels: levels, steps: steps ?? whole, now: Fixture.t0 + 6 * 86400,
                           dismissedUntil: nil, dayOf: Fixture.utcDay)
    }
    /// Two cloudy mornings (daylight held to half, blind 40% open, lights off) at 63 and two lit evenings at 72, on four days.
    func week(_ l: [Double], morning: Int = 63, evening: Int = 72) -> [Sample] {
        (0..<4).flatMap { d in
            [recorded(d, 8.5, elev: 15, p: 0.4, light: 0.5, lights: false, chosen: morning, levels: l),
             recorded(d, 9.5, elev: 20, p: 0.4, light: 0.5, lights: false, chosen: morning, levels: l),
             recorded(d, 20, elev: -6, p: 1, lights: true, chosen: evening, levels: l),
             recorded(d, 21, elev: -12, p: 1, lights: true, chosen: evening, levels: l)]
        }
    }

    func testCloudyMorningsAndLitEveningsSuggestNightAndLightsOn() {
        let samples = week(four)
        XCTAssertEqual(samples.map(\.auto).prefix(4), [68, 68, 80, 80])
        XCTAssertEqual(Suggest.candidates(samples, dayOf: Fixture.utcDay), [.night, .nightLights])
        guard let s = suggest(samples, levels: four) else { return XCTFail("cloudy mornings and lit evenings should suggest") }
        let after = applied(four, s)
        // Within a few points of what the user chose (the pull toward today's levels keeps them a little short):
        XCTAssertEqual(after[2], 54)   // a 63 on the cloudy mornings asks for night 51
        XCTAssertEqual(after[3], 73)   // the lit evenings were set to 72
        XCTAssertEqual(s.sentence(label: "Monitor"), "You lower Monitor by about 8 with the lights on. Set lights on 80 → 73, night 60 → 54?")
        // Sunny days do not change.
        for r in Self.references.prefix(2) { XCTAssertEqual(t(after, r), t(four, r)) }
    }

    func testAMonitorWithoutNightLightsIsOfferedOneBesideALowerNight() {
        // The same cloudy mornings on a monitor without the level; lit evenings were fine at night + the boost (65).
        let three: [Double] = [95, 62, 60]
        let samples = week(three).filter { !$0.lights }
        guard let s = suggest(samples, levels: three) else { return XCTFail("cloudy mornings should suggest") }
        XCTAssertEqual(s.changes.map(\.level), [.night, .nightLights])
        XCTAssertEqual(s.changes[1], LevelChange(level: .nightLights, from: 65, to: 65, added: true))
        let after = applied(three, s)
        XCTAssertEqual(after.count, 4)
        // The lit evening keeps its level, and sunny days do not change.
        XCTAssertEqual(t(after, Self.references[2]), t(three, Self.references[2]))
        XCTAssertEqual(t(three, Self.references[2]), 65)
        for r in Self.references.prefix(2) { XCTAssertEqual(t(after, r), t(three, r)) }
        XCTAssertEqual(s.sentence(label: "Monitor"), "You lower Monitor by about 5 when the room is dim. Set night 60 → 54, lights on 65 (new)?")
    }

    func testWithoutALightsOnStepOnlyNightIsOffered() {
        // Three steps, or none for the fourth: the room lights do not come from Home Assistant, so no level is added.
        let three: [Double] = [95, 62, 60]
        let samples = week(three).filter { !$0.lights }
        for steps in [[NumberStep?](whole.prefix(3)), [.whole, .whole, .whole, nil]] {
            XCTAssertEqual(suggest(samples, levels: three, steps: steps)?.changes.map(\.level), [.night])
        }
    }

    func testARaisedNightIsOfferedAlone() {
        let three: [Double] = [95, 62, 60]
        let samples = week(three, morning: 76).filter { !$0.lights }
        let s = suggest(samples, levels: three)
        XCTAssertEqual(s?.changes.map(\.level), [.night])
        XCTAssertEqual(s?.lower, false)
    }

    func testTheLightsOnLevelReadsWithTheLightsOn() {
        let s = Suggestion(monitor: "m", changes: [LevelChange(level: .nightLights, from: 80, to: 72)], amount: 8, lower: true, samples: 8, days: 4)
        XCTAssertEqual(s.sentence(label: "Monitor"), "You lower Monitor by about 8 with the lights on. Set lights on 80 → 72?")
        let pair = Suggestion(monitor: "m", changes: [LevelChange(level: .night, from: 60, to: 51), LevelChange(level: .nightLights, from: 65, to: 65, added: true)],
                              amount: 5, lower: true, samples: 8, days: 4)
        XCTAssertEqual(pair.sentence(label: "Monitor"), "You lower Monitor by about 5 when the room is dim. Set night 60 → 51, lights on 65 (new)?")
        XCTAssertEqual(pair.logLine(label: "Monitor"), "suggest: Monitor night 60 → 51, lights on 65 (new) (8 changes on 4 days)")
    }

    func testApplyWritesTheLightsOnLevelBesideNight() throws {
        let file = Data(#"{ "source": "sun", "location": { "latitude": 51.48, "longitude": 0 }, "monitors": [ { "match": "Monitor", "night": 60 } ] }"#.utf8)
        let out = try ConfigPatch.setLevels(["night": 51, "nightLights": 65], display: "Generic Monitor", suggestedMatch: "Monitor", in: file)
        let mons = (try JSONSerialization.jsonObject(with: out) as? [String: Any])?["monitors"] as? [[String: Any]] ?? []
        XCTAssertEqual(mons.first?["night"] as? Int, 51)
        XCTAssertEqual(mons.first?["nightLights"] as? Int, 65)
    }
}
