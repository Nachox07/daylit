import XCTest
@testable import DaylitCore

/// Samples for the suggestion tests: generic monitor, levels as given, `auto` from the real target.
enum Fixture {
    static let t0 = 1_793_577_600.0   // 2026-11-02 00:00 UTC
    /// Days counted in UTC, so the tests do not depend on the machine's time zone.
    static func utcDay(_ t: Double) -> Int { Int((t / 86400).rounded(.down)) }
    static func sample(_ day: Int, _ hour: Double, elev: Double, p: Double, chosen: Int, levels: [Double],
                       monitor: String = "m", lights: Bool = false) -> Sample {
        let s = daylightFraction(elevation: elev)
        let auto = target(day: levels[0], blindDown: levels[1], night: levels[2], elev: elev, pos: p * 100, lights: lights)
        return Sample(monitor: monitor, chosen: chosen, auto: auto, s: s, p: p, elev: elev, lights: lights, levels: levels,
                      at: t0 + Double(day) * 86400 + hour * 3600)
    }
}

final class SuggestCandidateTests: XCTestCase {
    let levels: [Double] = [100, 78, 75]

    func testWeightsSplitDaylightBetweenTheBlindLevelsAndTheRestToNight() {
        let w = Suggest.weights(s: 1, p: 0.35)
        XCTAssertEqual(w[0], 0.35, accuracy: 1e-9)
        XCTAssertEqual(w[1], 0.65, accuracy: 1e-9)
        XCTAssertEqual(w[2], 0, accuracy: 1e-9)
        let dusk = Suggest.weights(s: 0.4, p: 1)
        XCTAssertEqual(dusk[0], 0.4, accuracy: 1e-9)
        XCTAssertEqual(dusk[1], 0, accuracy: 1e-9)
        XCTAssertEqual(dusk[2], 0.6, accuracy: 1e-9)
    }

    func testABlindExactlyFortyPercentOpenStillCountsForBlindDown() {
        let at45 = Fixture.sample(0, 9, elev: 30, p: 0.45, chosen: 70, levels: levels)
        let at46 = Fixture.sample(0, 9, elev: 30, p: 0.46, chosen: 70, levels: levels)
        XCTAssertTrue(Suggest.dominates(at45, .blindDown))    // weight 0.55
        XCTAssertFalse(Suggest.dominates(at46, .blindDown))   // weight 0.54
        XCTAssertTrue(Suggest.dominates(Fixture.sample(0, 9, elev: 30, p: 0.40, chosen: 70, levels: levels), .blindDown))
    }

    func testALevelNeedsDominantSamplesOnThreeDifferentDays() {
        let twoDays = [0, 0, 1, 1].map { Fixture.sample($0, 9, elev: 30, p: 0.35, chosen: 70, levels: levels) }
        XCTAssertEqual(Suggest.candidates(twoDays, dayOf: Fixture.utcDay), [])
        let threeDays = twoDays + [Fixture.sample(2, 9, elev: 30, p: 0.35, chosen: 70, levels: levels)]
        XCTAssertEqual(Suggest.candidates(threeDays, dayOf: Fixture.utcDay), [.blindDown])
    }

    func testWithoutABlindBlindDownIsNeverACandidate() {
        // No blind: the position is always 100, so blind down carries no weight.
        let days = (0..<5).map { Fixture.sample($0, 12, elev: 30, p: 1, chosen: 70, levels: levels) }
        XCTAssertEqual(Suggest.candidates(days, dayOf: Fixture.utcDay), [.day])
    }

    func testNightNeedsEveningSamples() {
        let evenings = (0..<3).map { Fixture.sample($0, 19, elev: -6, p: 0, chosen: 60, levels: levels) }
        XCTAssertEqual(Suggest.candidates(evenings, dayOf: Fixture.utcDay), [.night])
    }
}

final class SuggestFitTests: XCTestCase {
    func testExactSyntheticDataRecoversTheLevels() {
        // Every mix of sun and blind, from levels 90 / 50 / 30, many times over so the pull hardly counts.
        let truth: [Double] = [90, 50, 30]
        var samples: [Sample] = []
        for _ in 0..<25 {
            for elev in [-3.0, 4.5, 12, 30] {
                for p in [0.0, 0.5, 1] {
                    let w = Suggest.weights(s: daylightFraction(elevation: elev), p: p)
                    let chosen = w[0] * truth[0] + w[1] * truth[1] + w[2] * truth[2]
                    samples.append(Sample(monitor: "m", chosen: Int(chosen.rounded()), auto: 0, s: daylightFraction(elevation: elev), p: p,
                                          elev: elev, lights: false, levels: [70, 40, 20], at: 0))
                }
            }
        }
        let f = Suggest.fit(samples, levels: [70, 40, 20], candidates: [.day, .blindDown, .night])
        XCTAssertEqual(f[0], 90, accuracy: 1)
        XCTAssertEqual(f[1], 50, accuracy: 1)
        XCTAssertEqual(f[2], 30, accuracy: 1)
    }

    func testALevelThatIsNotACandidateStaysPut() {
        let levels: [Double] = [100, 78, 75]
        let samples = (0..<4).map { Fixture.sample($0, 9, elev: 30, p: 0.35, chosen: 70, levels: levels) }
        let f = Suggest.fit(samples, levels: levels, candidates: [.blindDown])
        XCTAssertEqual(f[0], 100)
        XCTAssertEqual(f[2], 75)
        XCTAssertLessThan(f[1], 78)
    }

    func testThePullKeepsASingleSampleNearTheCurrentValue() {
        // Alone, this sample asks for blind down ≈ 43 ((60 − 0.3 · 100) / 0.7). One sample against the
        // pull of the current 78 moves it less than halfway.
        let levels: [Double] = [100, 78, 75]
        let one = Fixture.sample(0, 9, elev: 20, p: 0.3, chosen: 60, levels: levels)
        let f = Suggest.fit([one], levels: levels, candidates: [.blindDown])
        XCTAssertEqual(f[1], 66.443, accuracy: 0.01)
        XCTAssertGreaterThan(f[1], (42.857 + 78) / 2)
    }

    func testAFitIsClampedToTheRange() {
        let levels: [Double] = [100, 78, 75]
        let high = (0..<3).map { Fixture.sample($0, 12, elev: 30, p: 1, chosen: 99, levels: levels) }
        let f = Suggest.fit(high + high + high + high, levels: levels, candidates: [.day])
        XCTAssertLessThanOrEqual(f[0], 100)
    }
}

final class SuggestRoundingTests: XCTestCase {
    func testALocalLevelRoundsToAWholeNumber() {
        XCTAssertEqual(Suggest.roundToStep(61.42, .whole), 61)
        XCTAssertEqual(Suggest.roundToStep(61.5, .whole), 62)
        XCTAssertEqual(Suggest.roundToStep(-3, .whole), 0)
        XCTAssertEqual(Suggest.roundToStep(104, .whole), 100)
    }

    func testAHomeAssistantLevelRoundsToItsStepInsideItsRange() {
        let st = NumberStep(min: 10, max: 90, step: 5)
        XCTAssertEqual(Suggest.roundToStep(62.4, st), 60)
        XCTAssertEqual(Suggest.roundToStep(63, st), 65)
        XCTAssertEqual(Suggest.roundToStep(3, st), 10)
        XCTAssertEqual(Suggest.roundToStep(97, st), 90)
        XCTAssertEqual(Suggest.roundToStep(61.3, NumberStep(min: 0, max: 100, step: 0.5)), 61.5)
        XCTAssertEqual(Suggest.roundToStep(120, NumberStep(min: 0, max: 255, step: 1)), 100)   // never above 100
    }

    func testTheStepIsReadFromTheEntityAttributes() {
        let d = Data(#"{"entity_id": "input_number.x", "state": "62.0", "attributes": {"min": 10, "max": 90, "step": 5, "mode": "slider"}}"#.utf8)
        XCTAssertEqual(NumberStep.parse(d), NumberStep(min: 10, max: 90, step: 5))
        XCTAssertNil(NumberStep.parse(Data(#"{"state": "62.0", "attributes": {"min": 0}}"#.utf8)))
        XCTAssertNil(NumberStep.parse(Data(#"{"state": "62.0", "attributes": {"min": 0, "max": 100, "step": 0}}"#.utf8)))
        XCTAssertNil(NumberStep.parse(Data("not json".utf8)))
    }
}

final class SuggestTriggerTests: XCTestCase {
    let levels: [Double] = [100, 78, 75]
    let local: [NumberStep?] = [.whole, .whole, .whole]

    func testScoringRunsTheRealTargetIncludingTheLightsBoost() {
        // Sun 0° (daylight 0.2), lights on: the blend gives 30.4, the boost lifts it to 35.
        let x = Sample(monitor: "m", chosen: 35, auto: 35, s: 0.2, p: 1, elev: 0, lights: true, levels: [32, 32, 30], at: 0)
        XCTAssertEqual(Suggest.meanAbsError([x], levels: [32, 32, 30]), 0)
        var off = x; off.lights = false
        XCTAssertEqual(Suggest.meanAbsError([off], levels: [32, 32, 30]), 5)
    }

    func testAMoveUnderFivePointsIsNotProposed() {
        // Blind fully down, three days at 74 against 78: the fit gives 75, which would cut the error from 4 to 1.
        let samples = (0..<3).map { Fixture.sample($0, 9, elev: 30, p: 0, chosen: 74, levels: levels) }
        XCTAssertEqual(Suggest.fit(samples, levels: levels, candidates: [.blindDown])[1], 75, accuracy: 1e-9)
        XCTAssertEqual(Suggest.meanAbsError(samples, levels: levels) - Suggest.meanAbsError(samples, levels: [100, 75, 75]), 3)
        XCTAssertNil(Suggest.suggestion(monitor: "m", samples: samples, levels: levels, steps: local, now: Fixture.t0 + 5 * 86400,
                                        dismissedUntil: nil, dayOf: Fixture.utcDay))
    }

    func testAMoveThatDoesNotCutTheErrorByThreeIsNotProposed() {
        // Half the changes ask for 20 less, half for none: blind down moves 11, but the mean error stays 10.
        let samples = (0..<3).flatMap { d in [66, 86].map { Fixture.sample(d, 9, elev: 30, p: 0.35, chosen: $0, levels: levels) } }
        XCTAssertEqual(Suggest.fit(samples, levels: levels, candidates: [.blindDown])[1].rounded(), 67)
        XCTAssertEqual(Suggest.meanAbsError(samples, levels: [100, 67, 75]), 10)
        XCTAssertNil(Suggest.suggestion(monitor: "m", samples: samples, levels: levels, steps: local, now: Fixture.t0 + 5 * 86400,
                                        dismissedUntil: nil, dayOf: Fixture.utcDay))
    }

    func testAClearPatternIsProposedWithItsSentence() {
        let samples = (0..<4).map { Fixture.sample($0, 9, elev: 30, p: 0.35, chosen: 70, levels: levels) }   // auto 86
        let s = Suggest.suggestion(monitor: "m", samples: samples, levels: levels, steps: local, now: Fixture.t0 + 5 * 86400,
                                   dismissedUntil: nil, dayOf: Fixture.utcDay)
        XCTAssertEqual(s?.changes.map(\.level), [.blindDown])
        XCTAssertEqual(s?.amount, 16)
        XCTAssertEqual(s?.lower, true)
        XCTAssertEqual(s?.days, 4)
        XCTAssertEqual(s?.samples, 4)
        let to = s.map { Suggestion.fmt($0.changes[0].to) } ?? ""
        XCTAssertEqual(s?.sentence(label: "Monitor"),
                       "You lower Monitor by about 16 with the blind partly or fully down. Set blind down 78 → \(to)?")
        XCTAssertEqual(s?.logLine(label: "Monitor"), "suggest: Monitor blind down 78 → \(to) (4 changes on 4 days)")
    }

    func testOtherMonitorsAndUnavailableLevelsAreLeftOut() {
        let samples = (0..<4).map { Fixture.sample($0, 9, elev: 30, p: 0.35, chosen: 70, levels: levels) }
        XCTAssertNil(Suggest.suggestion(monitor: "other", samples: samples, levels: levels, steps: local, now: Fixture.t0 + 5 * 86400,
                                        dismissedUntil: nil, dayOf: Fixture.utcDay))
        // Blind down comes from Home Assistant and is unavailable right now.
        XCTAssertNil(Suggest.suggestion(monitor: "m", samples: samples, levels: levels, steps: [.whole, nil, .whole], now: Fixture.t0 + 5 * 86400,
                                        dismissedUntil: nil, dayOf: Fixture.utcDay))
    }

    func testNotNowHidesTheSuggestionForSevenDays() {
        let samples = (0..<4).map { Fixture.sample($0, 9, elev: 30, p: 0.35, chosen: 70, levels: levels) }
        let clicked = Fixture.t0 + 5 * 86400
        let until = clicked + Suggest.notNow
        XCTAssertEqual(Suggest.notNow, 7 * 86400)
        XCTAssertNil(Suggest.suggestion(monitor: "m", samples: samples, levels: levels, steps: local, now: until - 60,
                                        dismissedUntil: until, dayOf: Fixture.utcDay))
        XCTAssertNotNil(Suggest.suggestion(monitor: "m", samples: samples, levels: levels, steps: local, now: until,
                                           dismissedUntil: until, dayOf: Fixture.utcDay))
    }

    func testTwoLevelsAreListedMainFirst() {
        let s = Suggestion(monitor: "m", changes: [LevelChange(level: .blindDown, from: 78, to: 62), LevelChange(level: .day, from: 100, to: 95)],
                           amount: 12, lower: true, samples: 12, days: 4)
        XCTAssertEqual(s.sentence(label: "Monitor"),
                       "You lower Monitor by about 12 with the blind partly or fully down. Set blind down 78 → 62, day 100 → 95?")
        XCTAssertEqual(Suggestion.fmt(62.5), "62.5")
        let up = Suggestion(monitor: "m", changes: [LevelChange(level: .night, from: 20, to: 30)], amount: 8, lower: false, samples: 3, days: 3)
        XCTAssertEqual(up.sentence(label: "Monitor"), "You raise Monitor by about 8 in the evening. Set night 20 → 30?")
    }
}

final class SuggestRecorderTests: XCTestCase {
    let levels: [Double] = [100, 78, 75]

    func testAChangeSettlesAfterFiveMinutes() {
        var r = Recorder()
        let x = Fixture.sample(0, 9, elev: 30, p: 0.35, chosen: 70, levels: levels)
        r.handChanged(monitor: "m", sample: x)
        XCTAssertNil(r.settle(monitor: "m", held: true, levels: levels, now: x.at + 299))
        XCTAssertEqual(r.settle(monitor: "m", held: true, levels: levels, now: x.at + 300), x)
        XCTAssertNil(r.settle(monitor: "m", held: true, levels: levels, now: x.at + 330))   // once
    }

    func testASecondChangeWithinFiveMinutesReplacesTheFirst() {
        var r = Recorder()
        let first = Fixture.sample(0, 9, elev: 30, p: 0.35, chosen: 70, levels: levels)
        var second = first; second.chosen = 66; second.at = first.at + 120
        r.handChanged(monitor: "m", sample: first)
        XCTAssertNil(r.settle(monitor: "m", held: true, levels: levels, now: first.at + 60))
        r.handChanged(monitor: "m", sample: second)
        XCTAssertNil(r.settle(monitor: "m", held: true, levels: levels, now: first.at + 300))   // 3 minutes after the second
        XCTAssertEqual(r.settle(monitor: "m", held: true, levels: levels, now: second.at + 300)?.chosen, 66)
    }

    func testAClearedOffsetDropsThePendingChange() {
        var r = Recorder()
        let x = Fixture.sample(0, 9, elev: 30, p: 0.35, chosen: 70, levels: levels)
        r.handChanged(monitor: "m", sample: x)
        XCTAssertNil(r.settle(monitor: "m", held: false, levels: levels, now: x.at + 60))
        XCTAssertNil(r.settle(monitor: "m", held: true, levels: levels, now: x.at + 400))
        // A level change drops it too.
        r.handChanged(monitor: "m", sample: x)
        XCTAssertNil(r.settle(monitor: "m", held: true, levels: [100, 62, 75], now: x.at + 400))
        XCTAssertTrue(r.pending.isEmpty)
        // And so does an excluded change (or one put back) right after it.
        r.handChanged(monitor: "m", sample: x)
        r.handChanged(monitor: "m", sample: nil)
        XCTAssertNil(r.settle(monitor: "m", held: true, levels: levels, now: x.at + 400))
    }

    func sample(_ chosen: Int = 70, auto: Int = 86, elev: Double = 30, lights: Bool = false, levels l: [Double]? = nil,
                context: SampleContext = SampleContext()) -> Sample? {
        Suggest.makeSample(monitor: "m", chosen: chosen, auto: auto, elev: elev, pos: 35, lights: lights, light: 1,
                           levels: l ?? levels, tuning: Tuning(), now: 1000, context: context)
    }

    func testAnOrdinaryHandChangeIsASample() {
        let x = Suggest.makeSample(monitor: "m", chosen: 70, auto: 86, elev: 30, pos: 35, lights: false, light: 0.8,
                                   levels: levels, tuning: Tuning(), now: 1000, context: SampleContext())
        XCTAssertEqual(x, Sample(monitor: "m", chosen: 70, auto: 86, s: 0.8, p: 0.35, elev: 30, lights: false, levels: levels, at: 1000))
    }

    func testEachExclusionIsNotRecorded() {
        XCTAssertNotNil(sample())
        XCTAssertNil(sample(context: SampleContext(follower: true)))
        XCTAssertNil(sample(context: SampleContext(writeFailed: true)))
        XCTAssertNil(sample(context: SampleContext(idle: true)))
        XCTAssertNil(sample(context: SampleContext(paused: true)))
        XCTAssertNil(sample(context: SampleContext(sunFallback: true)))
        XCTAssertNil(sample(0)); XCTAssertNil(sample(100))
        XCTAssertNil(sample(auto: 0)); XCTAssertNil(sample(auto: 100))
        // The lights boost decided the target: sun 0°, lights on, night 30 + 5 above the blend.
        XCTAssertNil(sample(40, auto: 35, elev: 0, lights: true, levels: [32, 32, 30]))
        XCTAssertNotNil(sample(40, auto: 35, elev: 0, lights: false, levels: [32, 32, 30]))
    }

    func testAHomeAssistantSetIsNotAHandChange() {
        let before = HoldState(lastSet: 80, lastTarget: 80)
        let after = HoldState(lastSet: 50, lastTarget: 80, offset: -30, offsetSun: 1, offsetAt: 1000)
        XCTAssertTrue(Suggest.isHandChange(before: before, after: after, remote: nil, now: 1000))
        XCTAssertFalse(Suggest.isHandChange(before: before, after: after, remote: 50, now: 1000))
        XCTAssertFalse(Suggest.isHandChange(before: after, after: after, remote: nil, now: 1030))   // held from an earlier tick
    }

    func testDecideMarksAHandChangeWithItsTime() {
        let before = HoldState(lastSet: 86, lastTarget: 86)
        let step = decide(current: 70, want: 86, remote: nil, state: before, here: true, auto: true, dragging: false, sun: 1,
                          touched: true, now: 1000, dayOf: { _ in 0 })
        XCTAssertEqual(step.state.offset, -16)
        XCTAssertTrue(Suggest.isHandChange(before: before, after: step.state, remote: step.remote, now: 1000))
    }

    func testApplyClearsTheOffsetSoTheCorrectionIsNotDoubled() {
        // Target 85, the user set 70 (offset −15). The new levels give 70.
        let held = HoldState(lastSet: 70, lastTarget: 85, offset: -15, offsetSun: 1, offsetAt: 1000)
        let kept = decide(current: 70, want: 70, remote: nil, state: held, here: true, auto: true, dragging: false, sun: 1,
                          touched: false, now: 1060, dayOf: { _ in 0 })
        XCTAssertEqual(kept.applied, 55)   // what would happen without clearing
        let cleared = decide(current: 70, want: 70, remote: nil, state: Suggest.afterApply(held), here: true, auto: true, dragging: false,
                             sun: 1, touched: false, now: 1060, dayOf: { _ in 0 })
        XCTAssertEqual(cleared.applied, 70)
        XCTAssertNil(cleared.write)
        XCTAssertNil(cleared.state.offset)
    }
}
