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

final class SunSpanTests: XCTestCase {
    /// A day's elevations every 10 minutes from local midnight, as the sun curve samples them.
    func day(_ lat: Double, _ lon: Double, from start: String) -> [(t: Double, e: Double)] {
        let d = utc(start)
        return (0...144).map { i in (Double(i) / 144, solarElevation(latitude: lat, longitude: lon, at: d.addingTimeInterval(Double(i) * 600))) }
    }
    func clock(_ t: Double) -> String {
        let m = Int((t * 1440).rounded()); return String(format: "%02d:%02d", m / 60, m % 60)
    }
    func label(_ s: [(t: Double, e: Double)], _ e: Double, below: Bool = false) -> String {
        sunSpanLabel(sunSpans(s, line: e, below: below), clock: clock)
    }

    func testAnOrdinaryDayRisesAndSets() {
        let s = day(51.48, 0, from: "2026-03-20T00:00:00Z")   // Greenwich, equinox, UTC
        XCTAssertEqual(label(s, 0), "06:08 – 18:08")
        XCTAssertEqual(label(s, 0, below: true), "until 06:08 · from 18:08")
        XCTAssertEqual(label(s, 60), "not today")
        XCTAssertEqual(label(s, 60, below: true), "all day")
    }

    func testAMidnightSunDipIsLabelledInTheOrderItHappens() {
        // Tromsø at midsummer, local time UTC+2: the sun never sets, and its lowest point is about 00:45,
        // after local midnight. A line between the midnight height and that minimum is crossed going
        // down first and coming back up later, so "above" is everything but a short dip.
        let s = day(69.65, 18.96, from: "2026-06-20T22:00:00Z")
        let low = s.map(\.e).min()!, line = (s[0].e + low) / 2
        let above = sunSpans(s, line: line)
        XCTAssertEqual(above.count, 2)
        XCTAssertEqual(above.first?.from, 0); XCTAssertEqual(above.last?.to, 1)
        XCTAssertLessThan(above[0].to, above[1].from)
        let dip = sunSpans(s, line: line, below: true)
        XCTAssertEqual(dip.count, 1)
        XCTAssertEqual(label(s, line), "until \(clock(dip[0].from)) · from \(clock(dip[0].to))")
        XCTAssertEqual(label(s, line, below: true), "\(clock(dip[0].from)) – \(clock(dip[0].to))")
        XCTAssertLessThan(dip[0].from, dip[0].to)
        // Polar day: above the horizon all day.
        XCTAssertEqual(label(s, 0), "all day")
        XCTAssertEqual(label(s, 0, below: true), "not today")
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
        XCTAssertEqual(effectiveLevels(local: [70, 40, 20], fromHA: [90, -1, 10, -1, -1, 0]), [90, 40, 10])
        XCTAssertEqual(effectiveLevels(local: [70, 40, 20], fromHA: nil), [70, 40, 20])
    }
    func testSunFallbackKeepsHomeAssistantLevelsButNotTheSetHelper() {
        let row: [Double] = [94, 60, 30, -1, 55, 1_700_000_000]
        let kept = fallbackLevels(row)
        XCTAssertEqual(effectiveLevels(local: [70, 40, 20], fromHA: kept), [94, 60, 30])
        XCTAssertNotNil(RemoteSet(row: row))
        XCTAssertNil(RemoteSet(row: kept))
    }
}

final class UserLevelWinsTests: XCTestCase {
    func testALevelSetByHandDuringTheWaitBeatsTheOlderReading() {
        XCTAssertTrue(userLevelWins(atRead: 40, now: 52, held: false))   // a key press while Home Assistant answered
    }
    func testAnUnchangedLevelKeepsTheReading() {
        XCTAssertFalse(userLevelWins(atRead: 40, now: 40, held: false))
    }
    func testADraggedSliderIsNeverOverriddenByAReading() {
        XCTAssertTrue(userLevelWins(atRead: 40, now: 40, held: true))
        XCTAssertTrue(userLevelWins(atRead: 40, now: 63, held: true))
    }
    func testNothingToTrustWithoutALevel() {
        XCTAssertFalse(userLevelWins(atRead: nil, now: nil, held: true))
    }
    func testAHandChangeDuringTheWaitBecomesAnOffsetInsteadOfBeingOverwritten() {
        let st = HoldState(lastSet: 40, lastTarget: 40)
        let c = levelToDecideOn(read: 40, atRead: 40, model: 52, held: false)
        XCTAssertEqual(c, 52)
        let s = decide(current: c, want: 40, remote: nil, state: st, here: true, auto: true, dragging: false, sun: 1, touched: true)
        XCTAssertEqual(s.state.offset, 12)
        XCTAssertNil(s.write)
    }
    func testTheReadingStandsWhenNothingMovedTheLevel() {
        XCTAssertEqual(levelToDecideOn(read: 41, atRead: 40, model: 40, held: false), 41)   // the monitor's own buttons
    }
    func testADraggedSliderHoldsItsLevelAndMakesNoAutomaticWrite() {
        let st = HoldState(lastSet: 40, lastTarget: 40)
        let c = levelToDecideOn(read: 40, atRead: 40, model: 63, held: true)
        XCTAssertEqual(c, 63)
        let s = decide(current: c, want: 40, remote: nil, state: st, here: true, auto: true, dragging: true, sun: 1, touched: true)
        XCTAssertNil(s.write); XCTAssertNil(s.state.offset)
    }
    func testAWriteOverwritesTheSliderOnlyWhenItWasUntouchedMeanwhile() {
        XCTAssertEqual(levelAfterWrite(new: 70, ok: true, atStart: 40, now: 40, held: false), 70)
        XCTAssertNil(levelAfterWrite(new: 70, ok: true, atStart: 40, now: 55, held: false))   // moved by hand during the write
        XCTAssertNil(levelAfterWrite(new: 70, ok: true, atStart: 40, now: 40, held: true))    // slider held
        XCTAssertNil(levelAfterWrite(new: 70, ok: false, atStart: 40, now: 40, held: false))  // refused
    }
    func testACommittedWriteLeavesTheSliderAtWhatWasWrittenSoAWriteOnlyMonitorGetsNoOffset() {
        let before = HoldState(lastSet: 40, lastTarget: 40)
        let step = decide(current: 40, want: 70, remote: nil, state: before, here: true, auto: true, dragging: false, sun: 1, touched: false)
        XCTAssertEqual(step.write, 70)
        let c = writeCommit(step: step, before: before, ok: true, clearedMeanwhile: false, controlChanged: false,
                            levelAtStart: 40, levelNow: 40, held: false)!
        XCTAssertEqual(c.state.lastSet, 70)
        XCTAssertEqual(c.level, 70)   // slider == lastSet, so the next tick's slider-based reading is no hand change
        let next = decide(current: c.level!, want: 70, remote: nil, state: c.state, here: true, auto: true, dragging: false, sun: 1, touched: false)
        XCTAssertNil(next.state.offset); XCTAssertNil(next.write)
    }
    func testAFailedCommitForgetsLastSetAndMovesNoSlider() {
        let before = HoldState(lastSet: 40, lastTarget: 40)
        let step = decide(current: 40, want: 70, remote: nil, state: before, here: true, auto: true, dragging: false, sun: 1, touched: false)
        let c = writeCommit(step: step, before: before, ok: false, clearedMeanwhile: false, controlChanged: false,
                            levelAtStart: 40, levelNow: 40, held: false)!
        XCTAssertNil(c.state.lastSet); XCTAssertNil(c.level)
    }
    func testNothingIsCommittedWhenTheControlChangedInTheRebuild() {
        let before = HoldState(lastSet: 40, lastTarget: 40)
        let step = decide(current: 40, want: 70, remote: nil, state: before, here: true, auto: true, dragging: false, sun: 1, touched: false)
        XCTAssertNil(writeCommit(step: step, before: before, ok: true, clearedMeanwhile: false, controlChanged: true,
                                 levelAtStart: 40, levelNow: 40, held: false))
    }
    func testAnOffsetClearedByApplyDuringTheWriteStaysCleared() {
        let before = HoldState(lastSet: 40, lastTarget: 40, offset: 5, offsetSun: 1, offsetAt: 1)
        let step = decide(current: 45, want: 40, remote: nil, state: before, here: true, auto: true, dragging: false, sun: 1, touched: false, now: 2)
        let c = writeCommit(step: step, before: before, ok: true, clearedMeanwhile: true, controlChanged: false,
                            levelAtStart: 45, levelNow: 45, held: false)!
        XCTAssertNil(c.state.offset); XCTAssertNil(c.state.lastSet)
    }
}

final class DecideTests: XCTestCase {
    func step(_ c: Int, want: Int, remote: RemoteSet? = nil, state: HoldState = HoldState(),
              here: Bool = true, auto: Bool = true, dragging: Bool = false, sun: Double = 1, touched: Bool = true) -> Step {
        decide(current: c, want: want, remote: remote, state: state, here: here, auto: auto, dragging: dragging, sun: sun, touched: touched)
    }

    func testAMonitorReadingOneOffIsNotAHandSetLevel() {
        let st = HoldState(lastSet: 45, lastTarget: 45)
        let s = step(46, want: 45, state: st, touched: false)   // Daylit wrote 45, the monitor reports 46
        XCTAssertNil(s.write); XCTAssertNil(s.state.offset); XCTAssertFalse(s.manual)
        XCTAssertEqual(step(46, want: 45, state: st, touched: true).state.offset, 1)   // one step with the keys counts
        XCTAssertEqual(step(47, want: 45, state: st, touched: false).state.offset, 2)  // the monitor's own buttons count
    }

    func testARefusedWriteIsRetriedAndNotMistakenForAHandSetLevel() {
        let first = step(40, want: 70, touched: false)
        XCTAssertEqual(first.write, 70)
        // The monitor refused the write and still reads 40 on the next tick.
        let next = step(40, want: 70, state: first.state.afterWrite(ok: false, before: HoldState()), touched: false)
        XCTAssertEqual(next.write, 70)
        XCTAssertNil(next.state.offset); XCTAssertFalse(next.manual)
        // A write that went through is remembered as usual.
        XCTAssertEqual(first.state.afterWrite(ok: true, before: HoldState()), first.state)
    }

    func testARefusedHomeAssistantSetStaysPending() {
        // Automatic mode off: only the "set" helper writes. It changed to 70; the monitor refused it.
        let st = HoldState(remoteSeen: 100)
        let first = step(40, want: 50, remote: RemoteSet(value: 70, changed: 200), state: st, auto: false)
        XCTAssertEqual(first.write, 70)
        let next = step(40, want: 50, remote: RemoteSet(value: 70, changed: 200), state: first.state.afterWrite(ok: false, before: st), auto: false)
        XCTAssertEqual(next.write, 70)   // tried again
        // Once it went through, the same "set" is not applied twice.
        XCTAssertNil(step(70, want: 50, remote: RemoteSet(value: 70, changed: 200), state: next.state.afterWrite(ok: true, before: st), auto: false).write)
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
    func testHandSetLevelIsKeptAsADistanceFromTheTarget() {
        // Automatic set 70; the user chose 50 (20 below). The tick that notices keeps 50.
        let s = step(50, want: 70, state: HoldState(lastSet: 70, lastTarget: 70))
        XCTAssertNil(s.write)
        XCTAssertTrue(s.manual)
        XCTAssertEqual(s.state.offset, -20)
        // The target rises: the screen follows it, still 20 below.
        let next = step(50, want: 81, state: s.state)
        XCTAssertEqual(next.write, 61)
        XCTAssertTrue(next.manual)
    }
    func testACloudyMorningKeepsTheDimmerLevel() {
        // Replays a real morning: the user turned the screen down twice while the blind opened and the sun rose.
        var st = HoldState(lastSet: 76, lastTarget: 76)
        var s = step(52, want: 76, state: st, sun: 0.82); st = s.state            // set by hand: 24 below
        XCTAssertNil(s.write)
        s = step(52, want: 81, state: st, sun: 0.84); st = s.state               // blind 40 → 54 %
        XCTAssertEqual(s.write, 57)
        s = step(57, want: 87, state: st, sun: 0.84); st = s.state               // blind 80 %
        XCTAssertEqual(s.write, 63)
        s = step(63, want: 92, state: st, sun: 0.96)                             // the sun rises
        XCTAssertEqual(s.write, 68)
        XCTAssertTrue(s.manual)
    }
    func testAHandSetLevelEqualToTheTargetIsNotManual() {
        let s = step(72, want: 72, state: HoldState(lastSet: 70, lastTarget: 70))
        XCTAssertFalse(s.manual)
        XCTAssertNil(s.state.offset)
    }
    func testADaytimeDistanceFadesAtDuskAndRestsAtNight() {
        let st = HoldState(lastSet: 60, lastTarget: 80, offset: -20, offsetSun: 1)
        XCTAssertEqual(step(60, want: 80, state: st, sun: 1).write, nil)
        XCTAssertEqual(step(60, want: 70, state: st, sun: 0.15).applied, 60)     // half faded: 70 − 10
        let night = step(60, want: 50, state: st, sun: 0)
        XCTAssertEqual(night.write, 50)                                          // the night level, clean
        XCTAssertFalse(night.manual)
    }

    // Unix days in UTC keep these tests independent of the machine's time zone.
    func at(_ day: Int, _ hour: Double) -> Double { Double(day) * 86400 + hour * 3600 }
    func utcDay(_ t: Double) -> Int { Int((t / 86400).rounded(.down)) }

    func testOneMissingSunReadingDoesNotLoseADaytimeDistance() {
        // Home Assistant gave no elevation for one poll, so the sun read as night.
        var st = HoldState(lastSet: 60, lastTarget: 80, offset: -20, offsetSun: 0.9, offsetAt: at(100, 10))
        var s = decide(current: 60, want: 30, remote: nil, state: st, here: true, auto: true, dragging: false, sun: 0,
                       now: at(100, 11), dayOf: utcDay); st = s.state
        XCTAssertEqual(s.write, 30)
        s = decide(current: 30, want: 80, remote: nil, state: st, here: true, auto: true, dragging: false, sun: 0.9,
                   now: at(100, 11.1), dayOf: utcDay)
        XCTAssertEqual(s.write, 60)                                              // the sun is back, so is the distance
        XCTAssertTrue(s.manual)
    }
    func testADaytimeDistanceEndsWithTheDayEvenWithoutANightTick() {
        // Set at 16:00, the computer slept, the next tick is the next morning.
        let st = HoldState(lastSet: 50, lastTarget: 70, offset: -20, offsetSun: 0.8, offsetAt: at(100, 16))
        let s = decide(current: 50, want: 70, remote: nil, state: st, here: true, auto: true, dragging: false, sun: 0.5,
                       now: at(101, 8), dayOf: utcDay)
        XCTAssertEqual(s.write, 70)
        XCTAssertNil(s.state.offset)
        XCTAssertFalse(s.manual)
    }
    func testALinkedMonitorMovedOnItsOwnKeepsItsNewPlace() {
        var g = SyncOffsets(levels: [(key: "a", level: 70), (key: "b", level: 60)])
        g.move("b", level: 45, base: 70)
        XCTAssertEqual(g.level(key: "b", base: 80), 55)   // 25 below the group now
        g.move("c", level: 10, base: 70)                  // not a member: nothing
        XCTAssertNil(g.level(key: "c", base: 70))
    }
    func testAnOffsetSavedWithoutATimeCountsFromWhenItWasSaved() {
        let h = SavedHolds(entries: ["m": .init(lastSet: 50, lastTarget: 70, offset: -20, offsetSun: 0.8, saved: 1000)])
        XCTAssertEqual(h.restore(key: "m", now: 2000)?.offsetAt, 1000)
    }
    // A date in 2026 in UTC, as Unix seconds (real dates, so the sun samples are the season's).
    func utc(_ month: Int, _ day: Int, _ hour: Double) -> Double {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!
        let d = c.date(from: DateComponents(year: 2026, month: month, day: day))!.timeIntervalSince1970
        return d + hour * 3600
    }
    let polar = (latitude: 78.0, longitude: 15.0)
    let temperate = (latitude: 36.7, longitude: 0.0)

    func testANightDistanceLastsAsLongAsItStaysDark() {
        // A real polar night: the sun does not reach the fade edge for days, so a night distance stays.
        let st = HoldState(lastSet: 30, lastTarget: 50, offset: -20, offsetSun: 0, offsetAt: utc(12, 15, 23))
        XCTAssertFalse(offsetExpired(st, now: utc(12, 16, 20), sun: 0, dayOf: utcDay, place: polar))
        let s = decide(current: 30, want: 50, remote: nil, state: st, here: true, auto: true, dragging: false, sun: 0,
                       now: utc(12, 16, 20), dayOf: utcDay, place: polar)
        XCTAssertNotNil(s.state.offset)
    }
    func testANightDistanceSetInTheEveningEndsAfterASleepThroughTheDay() {
        // Set at 19:00 in December, nobody ticked while the sun was up, next evening it is dark again.
        let st = HoldState(lastSet: 30, lastTarget: 50, offset: -20, offsetSun: 0, offsetAt: utc(12, 15, 19))
        XCTAssertTrue(offsetExpired(st, now: utc(12, 16, 19), sun: 0, dayOf: utcDay, place: temperate))
        XCTAssertFalse(offsetExpired(st, now: utc(12, 16, 4), sun: 0, dayOf: utcDay, place: temperate))   // still the same night
        let s = decide(current: 30, want: 50, remote: nil, state: st, here: true, auto: true, dragging: false, sun: 0,
                       now: utc(12, 16, 19), dayOf: utcDay, place: temperate)
        XCTAssertNil(s.state.offset)
        XCTAssertEqual(s.write, 50)
    }
    func testANightDistanceEndsWhenDaylightPassesTheFadeEdgeEvenAfterASleep() {
        let st = HoldState(lastSet: 30, lastTarget: 50, offset: -20, offsetSun: 0, offsetAt: utc(4, 10, 23))
        XCTAssertFalse(offsetExpired(st, now: utc(4, 11, 4), sun: 0.29, dayOf: utcDay, place: temperate))
        XCTAssertTrue(offsetExpired(st, now: utc(4, 11, 4), sun: 0.3, dayOf: utcDay, place: temperate))
    }
    func testADaytimeDistanceSetInTheEveningDoesNotComeBackInTheMorning() {
        // Set at 20:00 in June with the sun up; the next tick is 07:30 and the sun is up again.
        let st = HoldState(lastSet: 50, lastTarget: 70, offset: -20, offsetSun: 1, offsetAt: utc(6, 20, 20))
        let s = decide(current: 50, want: 70, remote: nil, state: st, here: true, auto: true, dragging: false, sun: 0.5,
                       now: utc(6, 21, 7.5), dayOf: utcDay, place: temperate)
        XCTAssertNil(s.state.offset)
        XCTAssertEqual(s.write, 70)
        XCTAssertFalse(s.manual)
    }
    func testWithoutALocationANightDistanceEndsAfterEighteenHoursAndADayOneWithTheDay() {
        let night = HoldState(lastSet: 30, lastTarget: 50, offset: -20, offsetSun: 0, offsetAt: utc(12, 15, 19))
        XCTAssertFalse(offsetExpired(night, now: utc(12, 15, 19) + 17.9 * 3600, sun: 1, dayOf: utcDay))
        XCTAssertTrue(offsetExpired(night, now: utc(12, 15, 19) + 18.1 * 3600, sun: 0, dayOf: utcDay))
        let day = HoldState(lastSet: 50, lastTarget: 70, offset: -20, offsetSun: 0.8, offsetAt: utc(6, 20, 10))
        XCTAssertFalse(offsetExpired(day, now: utc(6, 20, 23.5), sun: 0, dayOf: utcDay))
        XCTAssertTrue(offsetExpired(day, now: utc(6, 21, 0.5), sun: 0.5, dayOf: utcDay))
    }
    func testEveryDistanceEndsAfterThirtySixHours() {
        let night = HoldState(lastSet: 30, lastTarget: 50, offset: -20, offsetSun: 0, offsetAt: utc(12, 15, 0))
        XCTAssertFalse(offsetExpired(night, now: utc(12, 15, 0) + offsetMaxAge, sun: 0, dayOf: utcDay, place: polar))
        XCTAssertTrue(offsetExpired(night, now: utc(12, 15, 0) + offsetMaxAge + 1, sun: 0, dayOf: utcDay, place: polar))
        let day = HoldState(lastSet: 30, lastTarget: 50, offset: -20, offsetSun: 1, offsetAt: utc(6, 20, 12))
        XCTAssertTrue(offsetExpired(day, now: utc(6, 20, 12) + offsetMaxAge + 1, sun: 1, dayOf: { _ in 7 }, place: polar))
    }
    func testADaytimeDistanceCarriesPastMidnightOnlyInAPolarDay() {
        let st = HoldState(lastSet: 50, lastTarget: 70, offset: -20, offsetSun: 0.8, offsetAt: utc(6, 20, 20))
        XCTAssertFalse(offsetExpired(st, now: utc(6, 21, 1), sun: 0.1, dayOf: utcDay, place: polar))        // polar day, new calendar day
        XCTAssertTrue(offsetExpired(st, now: utc(6, 21, 9), sun: 1, dayOf: utcDay, place: polar))           // but not for more than 12 hours
        XCTAssertTrue(offsetExpired(st, now: utc(6, 21, 1), sun: 0, dayOf: utcDay, place: temperate))       // a normal midnight
        XCTAssertFalse(offsetExpired(st, now: utc(6, 20, 23), sun: 0, dayOf: utcDay, place: temperate))     // same day: the fade handles it
    }
    func testASavedHoldIsRewrittenWhenOnlyTheOffsetTimeChanges() {
        var saved = SavedHolds()
        let a = HoldState(lastSet: 40, lastTarget: 70, offset: -30, offsetSun: 1, offsetAt: 900)
        XCTAssertTrue(saved.record(key: "A", state: a, now: 1000))
        XCTAssertFalse(saved.record(key: "A", state: a, now: 1100))                   // nothing changed
        var again = a; again.offsetAt = 1050; again.offsetSun = 0.5                    // same offset, held again
        XCTAssertTrue(saved.record(key: "A", state: again, now: 1100))
        XCTAssertEqual(saved.restore(key: "A", now: 1200), again)
    }

    func testALevelSetInTheLastLightFadesOverHalfAnHour() {
        // Replays an evening: the user turned the screen 30 up with little light left.
        var st = HoldState(lastSet: 55, lastTarget: 55)
        var s = decide(current: 85, want: 55, remote: nil, state: st, here: true, auto: true, dragging: false, sun: 0.04,
                       now: at(100, 18.4), dayOf: utcDay); st = s.state
        XCTAssertNil(s.write)
        s = decide(current: 85, want: 55, remote: nil, state: st, here: true, auto: true, dragging: false, sun: 0.01,
                   now: at(100, 18.4 + 4.0 / 60), dayOf: utcDay); st = s.state
        XCTAssertEqual(s.write, 81)                                              // 4 minutes on: most of it, not a quarter
        s = decide(current: 81, want: 55, remote: nil, state: st, here: true, auto: true, dragging: false, sun: 0,
                   now: at(100, 18.4 + 15.0 / 60), dayOf: utcDay); st = s.state
        XCTAssertEqual(s.write, 70)                                              // half way
        s = decide(current: 70, want: 55, remote: nil, state: st, here: true, auto: true, dragging: false, sun: 0,
                   now: at(100, 19), dayOf: utcDay)
        XCTAssertEqual(s.write, 55)                                              // gone at night, as a daytime one
        XCTAssertFalse(s.manual)
    }
    func testANightDistanceEndsAfterSunrise() {
        let st = HoldState(lastSet: 30, lastTarget: 50, offset: -20, offsetSun: 0)
        XCTAssertNil(step(30, want: 50, state: st, sun: 0).write)                // kept through the night
        XCTAssertEqual(step(30, want: 60, state: st, sun: 0.15).write, 50)       // half gone
        let day = step(30, want: 70, state: st, sun: 0.3)
        XCTAssertEqual(day.write, 70)
        XCTAssertNil(day.state.offset)
    }
    func testTheDistanceIsClampedButKept() {
        let s = step(10, want: 30, state: HoldState(lastSet: 10, lastTarget: 40, offset: -30, offsetSun: 1))
        XCTAssertEqual(s.write, 0)
        XCTAssertEqual(s.state.offset, -30)
        XCTAssertEqual(step(0, want: 60, state: s.state).write, 30)
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
    func testHomeAssistantRestartWithTheSameSetValueIsNotACommand() {
        let first = step(75, want: 75, remote: RemoteSet(value: 20, changed: 1000))
        let restart = step(75, want: 75, remote: RemoteSet(value: 20, changed: 5000), state: first.state, here: false)
        XCTAssertNil(restart.remote)
        XCTAssertNil(restart.write)
        XCTAssertNil(restart.state.offset)
        XCTAssertEqual(restart.state.remoteSeen, 5000)
        let real = step(75, want: 75, remote: RemoteSet(value: 40, changed: 6000), state: restart.state, here: false)
        XCTAssertEqual(real.remote, 40)
        XCTAssertEqual(real.state.remoteValue, 40)
    }
    func testSetHelperChangeAppliesEvenWhenIdleAndIsHeld() {
        let s = step(70, want: 70, remote: RemoteSet(value: 30, changed: 2000), state: HoldState(lastSet: 70, lastTarget: 70, remoteSeen: 1000), here: false)
        XCTAssertEqual(s.remote, 30)
        XCTAssertEqual(s.write, 30)
        XCTAssertFalse(s.skip)
        XCTAssertTrue(s.manual)
        XCTAssertEqual(s.state.remoteSeen, 2000)
        // Followed like a hand-set level: the next tick at the same target keeps 30, a higher one moves with it.
        let next = step(30, want: 70, state: s.state)
        XCTAssertNil(next.write)
        XCTAssertTrue(next.manual)
        XCTAssertEqual(step(30, want: 80, state: next.state).write, 40)
    }
    func testSetHelperUnchangedDoesNothing() {
        let s = step(70, want: 70, remote: RemoteSet(value: 30, changed: 1000), state: HoldState(lastSet: 70, lastTarget: 70, remoteSeen: 1000))
        XCTAssertNil(s.remote)
        XCTAssertNil(s.write)
    }
    func testRemoteRowParsing() {
        XCTAssertEqual(RemoteSet(row: [70, 40, 20, -1, 55, 1234]), RemoteSet(value: 55, changed: 1234))
        XCTAssertNil(RemoteSet(row: [70, 40, 20, -1, -1, 0]))      // no set helper
        XCTAssertNil(RemoteSet(row: [70, 40, 20, -1, 55, 0]))      // helper missing in HA
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
    func testWhiteLightsSwitchAtTheSameBrightnessAsBefore() {
        var r = LookRule()
        XCTAssertTrue(r.wantDark(elev: -10, pos: 0, hasBlind: true, lightsOn: true, bri: 199, sat: 10))    // not bright enough yet
        XCTAssertFalse(r.wantDark(elev: -10, pos: 0, hasBlind: true, lightsOn: true, bri: 200, sat: 10))   // 200 of 255: light
        XCTAssertFalse(r.wantDark(elev: -10, pos: 0, hasBlind: true, lightsOn: true, bri: 170, sat: 10))   // still counts
        XCTAssertTrue(r.wantDark(elev: -10, pos: 0, hasBlind: true, lightsOn: true, bri: 169, sat: 10))    // below 170: dark
    }
    func testANarrowCustomGapStartsInsideIt() {
        var t = Tuning(); t.theme = .init(); t.theme?.lightSunAbove = 2; t.theme?.darkSunBelow = 1.8
        var r = LookRule()
        XCTAssertFalse(r.wantDark(elev: 1.97, pos: 100, hasBlind: false, lightsOn: false, bri: 0, sat: 0, tuning: t))   // upper part of the gap: light
    }
    func testCloseLinesGetLabelsThatDoNotOverlap() {
        XCTAssertEqual(spreadLabels([80, 90], gap: 24, height: 170), [80, 104])
        XCTAssertEqual(spreadLabels([90, 80], gap: 24, height: 170), [104, 80])
        XCTAssertEqual(spreadLabels([20, 120], gap: 24, height: 170), [20, 120])   // far apart: on their lines
        XCTAssertEqual(spreadLabels([165, 168], gap: 24, height: 170), [134, 158])   // at the bottom: pushed up
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
    // Sun 16°, blind 40% (inside the default 35–55 gap), lights off: only the daylight condition is undecided.
    func testAFreshRuleInTheGapKeepsALightScreen() {
        var r = LookRule()
        XCTAssertFalse(r.wantDark(elev: 16, pos: 40, hasBlind: true, lightsOn: false, bri: 0, sat: 0, previous: false))
        XCTAssertFalse(r.wantDark(elev: 16, pos: 40, hasBlind: true, lightsOn: false, bri: 0, sat: 0), "stays light")
    }
    func testAFreshRuleInTheGapKeepsADarkScreen() {
        var r = LookRule()
        XCTAssertTrue(r.wantDark(elev: 16, pos: 40, hasBlind: true, lightsOn: false, bri: 0, sat: 0, previous: true))
        XCTAssertTrue(r.wantDark(elev: 16, pos: 40, hasBlind: true, lightsOn: false, bri: 0, sat: 0), "stays dark")
    }
    func testAFreshRuleInTheGapWithoutTheScreenStateUsesTheMidpoint() {
        var r = LookRule()
        XCTAssertTrue(r.wantDark(elev: 16, pos: 40, hasBlind: true, lightsOn: false, bri: 0, sat: 0, previous: nil), "40% is under the 50% midpoint")
        var open = LookRule()
        XCTAssertFalse(open.wantDark(elev: 16, pos: 52, hasBlind: true, lightsOn: false, bri: 0, sat: 0, previous: nil), "52% is over it")
    }
    func testOutsideTheGapTheScreenStateIsIgnored() {
        var a = LookRule(), b = LookRule(), c = LookRule()
        XCTAssertFalse(a.wantDark(elev: 16, pos: 80, hasBlind: true, lightsOn: false, bri: 0, sat: 0, previous: true), "blind open: light")
        XCTAssertTrue(b.wantDark(elev: 16, pos: 20, hasBlind: true, lightsOn: false, bri: 0, sat: 0, previous: false), "blind closed: dark")
        XCTAssertTrue(c.wantDark(elev: -10, pos: 40, hasBlind: true, lightsOn: false, bri: 0, sat: 0, previous: false), "night: dark")
    }
    func testBothConditionsInTheGapFollowTheScreenState() {
        // Lights at 185 of 255 (about 73%, between 66.6 and 78.4) and white: also inside their gap.
        var light = LookRule(), dark = LookRule(), unknown = LookRule()
        XCTAssertFalse(light.wantDark(elev: 16, pos: 40, hasBlind: true, lightsOn: true, bri: 185, sat: 10, previous: false))
        XCTAssertFalse(light.wantDark(elev: 16, pos: 40, hasBlind: true, lightsOn: true, bri: 185, sat: 10), "stays light")
        XCTAssertTrue(dark.wantDark(elev: 16, pos: 40, hasBlind: true, lightsOn: true, bri: 185, sat: 10, previous: true))
        XCTAssertTrue(dark.wantDark(elev: 16, pos: 40, hasBlind: true, lightsOn: true, bri: 185, sat: 10), "stays dark")
        XCTAssertTrue(unknown.wantDark(elev: 16, pos: 40, hasBlind: true, lightsOn: true, bri: 185, sat: 10, previous: nil))
    }
    func testAfterKeepingALightScreenSunsetStillTurnsItDark() {
        var r = LookRule()
        XCTAssertFalse(r.wantDark(elev: 16, pos: 40, hasBlind: true, lightsOn: false, bri: 0, sat: 0, previous: false))
        XCTAssertTrue(r.wantDark(elev: 0.5, pos: 40, hasBlind: true, lightsOn: false, bri: 0, sat: 0), "sun below 1°: dark")
    }
    func testADarkScreenUnderBrightWhiteLightsLeavesDaylightToTheMidpoint() {
        // Bright white lights decide light on their own, so the dark screen says nothing about daylight.
        var r = LookRule()
        XCTAssertFalse(r.wantDark(elev: 16, pos: 52, hasBlind: true, lightsOn: true, bri: 230, sat: 10, previous: true))
        XCTAssertFalse(r.wantDark(elev: 16, pos: 52, hasBlind: true, lightsOn: false, bri: 0, sat: 0), "52% blind is over the midpoint: light")
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
        let (_, err) = Config.load(from: write(#"{ "pauseOnBattery": "five" }"#))
        XCTAssertTrue(err?.contains("pauseOnBattery") ?? false, err ?? "")
    }
    func testAnOldConfigWithManualHoldStillLoads() {
        let (c, err) = Config.load(from: write(#"{ "source": "sun", "manualHold": 5, "location": { "latitude": 51.48, "longitude": 0.0 } }"#))
        XCTAssertNil(err)
        XCTAssertEqual(c.source, "sun")
    }
    func testExampleConfigLoads() throws {
        let example = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../config.example.json").standardizedFileURL
        let (c, err) = Config.load(from: example)
        XCTAssertNil(err)
        XCTAssertEqual(c.resolvedSource().0, .homeAssistant)
        XCTAssertEqual(c.monitors?.count, 2)
        XCTAssertNotNil(c.location)
        XCTAssertEqual(c.monitors?.first?.contrast, 60)
        XCTAssertNil(c.monitors?.last?.contrast)
        XCTAssertEqual(c.monitors?.first?.homeAssistant?.nightLights, "input_number.daylit_left_night_lights")
        XCTAssertEqual(c.monitors?.last?.nightLights, 40)
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
    func testUnavailableBlindKeepsItsLastPosition() {
        XCTAssertEqual(blindPosition(reported: 40, last: 70), 40)
        XCTAssertEqual(blindPosition(reported: -1, last: 40), 40)    // dropped off Home Assistant for a moment
        XCTAssertEqual(blindPosition(reported: -1, last: nil), 100)  // never seen: counts as open
        XCTAssertEqual(blindPosition(reported: 0, last: 40), 0)      // closed is a real position
    }

    func testEntitiesAppear() {
        let ha = HAConfig(url: "http://x", autoSwitch: "input_boolean.auto", cover: "cover.blind", lights: "light.room")
        let mon = MonitorHA(day: "input_number.d", set: "input_number.s")
        let t = HATemplate.build(ha, [("UUID-1", mon), ("UUID-2", nil)])
        XCTAssertTrue(t.contains("is_state('input_boolean.auto','on') | tojson"))
        XCTAssertTrue(t.contains("state_attr('cover.blind','current_position') | float(-1)"))   // unavailable is not "open"
        XCTAssertTrue(t.contains("state_attr('light.room','brightness')"))
        XCTAssertTrue(t.contains(#""UUID-1": [{{ states('input_number.d') | float(-1) }}, -1, -1, "#))
        XCTAssertTrue(t.contains("states['input_number.s'].last_changed"))
        XCTAssertFalse(t.contains("UUID-2"))   // a monitor without HA entities is left out
    }
    func testSetHelperWithDigitFirstNameAvoidsTheDottedForm() {
        // Home Assistant can't parse states.input_number.1st…, and one syntax error fails the whole template.
        let mon = MonitorHA(set: "input_number.1st_monitor")
        let t = HATemplate.build(HAConfig(url: "http://x"), [("U", mon)])
        XCTAssertTrue(t.contains("states['input_number.1st_monitor'].last_changed) if states['input_number.1st_monitor']"))
        XCTAssertFalse(t.contains("states.input_number"))
    }
    func testParsesAnswerShape() {
        let ok = #"{"elev": 10.5, "pos": 56, "lights": true, "auto": null, "bri": 200, "sat": 20, "m": {"U": [80, 40, 20, -1, -1, 0]}}"#
        let s = HAState.parse(Data(ok.utf8))
        XCTAssertNotNil(s)
        XCTAssertNil(s?.auto)
        XCTAssertEqual(s?.m["U"]?.count, 6)
        let short = #"{"elev": 1, "pos": 1, "lights": false, "auto": true, "bri": 0, "sat": 0, "m": {"U": [80, 40, 20]}}"#
        XCTAssertNil(HAState.parse(Data(short.utf8)))
        XCTAssertNil(HAState.parse(Data("not json".utf8)))
    }
}

final class ContrastTests: XCTestCase {
    func testConfiguredContrastIsWrittenOverDDC() {
        XCTAssertEqual(ContrastRule.toWrite(configured: 60, ddc: true, written: nil), 60)
    }
    func testNothingIsWrittenWithoutAConfiguredValue() {
        XCTAssertNil(ContrastRule.toWrite(configured: nil, ddc: true, written: nil))
    }
    func testHDROrNativeMonitorsAreLeftAlone() {
        XCTAssertNil(ContrastRule.toWrite(configured: 60, ddc: false, written: nil))
    }
    func testTheSameValueIsNotWrittenTwiceUntilForgotten() {
        XCTAssertNil(ContrastRule.toWrite(configured: 60, ddc: true, written: 60))
        XCTAssertEqual(ContrastRule.toWrite(configured: 70, ddc: true, written: 60), 70, "a reloaded config with a new value")
    }
    func testOutOfRangeValuesAreClampedAndRounded() {
        XCTAssertEqual(ContrastRule.toWrite(configured: 150, ddc: true, written: nil), 100)
        XCTAssertEqual(ContrastRule.toWrite(configured: -5, ddc: true, written: nil), 0)
        XCTAssertEqual(ContrastRule.toWrite(configured: 62.5, ddc: true, written: nil), 63)
    }
    func testContrastIsReadFromAMonitorEntry() throws {
        let c = try JSONDecoder().decode(Config.self, from: Data(#"{"monitors":[{"match":"U2723QE","contrast":55}]}"#.utf8))
        XCTAssertEqual(c.monitors?.first?.contrast, 55)
        XCTAssertNil(c.validate())
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
        let auto = decide(current: 60, want: 72, remote: nil, state: st, here: true, auto: true, dragging: false, sun: 1)
        XCTAssertEqual(auto.write, 72)
        XCTAssertFalse(auto.manual)
        // Moved by hand to 40: kept, 32 below the target.
        st = auto.state
        let held = decide(current: 40, want: 72, remote: nil, state: st, here: true, auto: true, dragging: false, sun: 1)
        XCTAssertNil(held.write)
        XCTAssertTrue(held.manual)
    }
}

final class SyncTests: XCTestCase {
    func testALeavingMonitorStaysOutAndTheOthersKeepTheirOffsets() {
        var s = SyncOffsets(levels: [(key: "a", level: 60), (key: "b", level: 40), (key: "tv", level: 75)])
        s.leave("a")
        XCTAssertEqual(s.offsets, ["b": -20, "tv": 15])
        XCTAssertEqual(s.follow(key: "b", level: 30, keys: ["a", "b", "tv"]), ["tv": 65])
        XCTAssertEqual(s.follow(key: "a", level: 10, keys: ["a", "b", "tv"]), [:], "a monitor outside the group moves alone")
        s.adopt([(key: "a", level: 10), (key: "b", level: 30), (key: "tv", level: 65)])
        XCTAssertFalse(s.isMember("a"), "not adopted back by itself")
        XCTAssertEqual(s.members(of: ["a", "b", "tv"]), 2)
    }
    func testRejoiningUsesTheCurrentOffset() {
        var s = SyncOffsets(levels: [(key: "a", level: 60), (key: "b", level: 40)])
        s.leave("b")
        s.join("b", levels: [(key: "a", level: 50), (key: "b", level: 20)])
        XCTAssertEqual(s.offsets["b"], -30)
        XCTAssertTrue(s.excluded.isEmpty)
    }
    func testOffsetsSavedBeforeGroupsStillLoad() throws {
        let s = try JSONDecoder().decode(SyncOffsets.self, from: Data(#"{"offsets":{"a":0,"b":-5}}"#.utf8))
        XCTAssertEqual(s.offsets["b"], -5); XCTAssertTrue(s.excluded.isEmpty)
    }

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

    // MARK: saved hand-set state

    func testSavedHoldRestoresWithinMaxAgeAndKeepsTheHandSetLevel() {
        var saved = SavedHolds()
        saved.record(key: "A", state: HoldState(lastSet: 40, lastTarget: 70, offset: -30, offsetSun: 1, offsetAt: 900), now: 1000)
        let back = try! JSONDecoder().decode(SavedHolds.self, from: try! JSONEncoder().encode(saved))
        let st = back.restore(key: "A", now: 1000 + 3600)
        XCTAssertEqual(st, HoldState(lastSet: 40, lastTarget: 70, offset: -30, offsetSun: 1, offsetAt: 900))
        // The monitor is at 40 (set by hand before the restart): it keeps following the target 30 below.
        let s = decide(current: 40, want: 72, remote: nil, state: st!, here: true, auto: true, dragging: false, sun: 1)
        XCTAssertEqual(s.write, 42)
        XCTAssertTrue(s.manual)
    }

    func testWithoutSavedHoldARestartAppliesTheTarget() {
        let s = decide(current: 40, want: 72, remote: nil, state: HoldState(), here: true, auto: true, dragging: false, sun: 1)
        XCTAssertEqual(s.write, 72)
    }

    func testHoldsSavedBeforeOffsetsStillLoad() {
        let old = Data(#"{"entries":{"A":{"lastSet":40,"lastTarget":70,"saved":10}}}"#.utf8)
        let back = try! JSONDecoder().decode(SavedHolds.self, from: old)
        XCTAssertEqual(back.restore(key: "A", now: 20), HoldState(lastSet: 40, lastTarget: 70))
    }

    func testSavedHoldExpiresAndEmptyStateIsDropped() {
        var saved = SavedHolds()
        saved.record(key: "A", state: HoldState(lastSet: 70, lastTarget: 70), now: 0)
        XCTAssertNil(saved.restore(key: "A", now: SavedHolds.maxAge + 1))
        XCTAssertNil(saved.restore(key: "B", now: 10))
        saved.record(key: "A", state: HoldState(), now: 5)
        XCTAssertTrue(saved.entries.isEmpty)
    }

    func testHAErrorTransientStaysQuietForAMinute() {
        XCTAssertFalse(HAErrorRule.shouldShow(transient: true, downSince: nil, now: 100))
        XCTAssertFalse(HAErrorRule.shouldShow(transient: true, downSince: 100, now: 100))
        XCTAssertFalse(HAErrorRule.shouldShow(transient: true, downSince: 100, now: 159))
        XCTAssertTrue(HAErrorRule.shouldShow(transient: true, downSince: 100, now: 160))
    }
    func testOnlyGatewayStatusesAreTransient() {
        for code in [502, 503, 504] { XCTAssertTrue(HAErrorRule.transient(status: code), "\(code)") }
        for code in [400, 401, 403, 404, 500, 501, 505, 0] { XCTAssertFalse(HAErrorRule.transient(status: code), "\(code)") }
    }
    func testHAErrorTokenProblemsShowAtOnce() {
        XCTAssertTrue(HAErrorRule.shouldShow(transient: false, downSince: nil, now: 0))
        XCTAssertEqual(HAErrorRule.retryDelays, [2, 5])
    }
    func testHAOutageIsLoggedOnceThenEveryTenMinutes() {
        let m = "Cannot reach Home Assistant"
        XCTAssertTrue(HAErrorRule.shouldLog(message: m, lastMessage: nil, lastLogged: nil, now: 0))
        XCTAssertFalse(HAErrorRule.shouldLog(message: m, lastMessage: m, lastLogged: 0, now: 30))
        XCTAssertFalse(HAErrorRule.shouldLog(message: m, lastMessage: m, lastLogged: 0, now: 599))
        XCTAssertTrue(HAErrorRule.shouldLog(message: m, lastMessage: m, lastLogged: 0, now: 600))
    }
    func testADifferentHAErrorIsLoggedAtOnce() {
        XCTAssertTrue(HAErrorRule.shouldLog(message: "Token rejected", lastMessage: "Cannot reach Home Assistant", lastLogged: 0, now: 30))
    }
    func testAnEmptyDisplayNameGetsANumber() {
        XCTAssertEqual(DisplayName.label("", index: 1), "Display 2")
        XCTAssertEqual(DisplayName.label("  ", index: 0), "Display 1")
        XCTAssertEqual(DisplayName.label("DELL S2725QC", index: 0), "DELL S2725QC")
    }
}

final class ConfigEditTests: XCTestCase {
    func json(_ d: Data) -> [String: Any] { try! JSONSerialization.jsonObject(with: d) as! [String: Any] }
    let dell = SettingsEdit.Monitor(name: "DELL U2723QE", suggestedMatch: "U2723QE", label: "Left", day: 80, blindDown: 45, night: 15)

    func testContrastBoxWritesAndRemovesTheKeyAndKeepsTheRest() throws {
        let original = #"{ "monitors": [ { "match": "U2723QE", "control": "ddc", "contrast": 40, "future": 1 } ] }"#
        var e = SettingsEdit(source: "off", monitors: [dell])
        e.monitors[0].contrastEditable = true; e.monitors[0].contrast = 70
        var m = (json(try ConfigPatch.apply(e, to: Data(original.utf8)))["monitors"] as! [[String: Any]])[0]
        XCTAssertEqual(m["contrast"] as? Int, 70)
        XCTAssertEqual(m["control"] as? String, "ddc"); XCTAssertEqual(m["future"] as? Int, 1)
        e.monitors[0].contrast = nil
        m = (json(try ConfigPatch.apply(e, to: Data(original.utf8)))["monitors"] as! [[String: Any]])[0]
        XCTAssertNil(m["contrast"], "an empty box removes the key")
        XCTAssertEqual(m["future"] as? Int, 1)
        let saved = try ConfigPatch.apply(e, to: Data(original.utf8))
        XCTAssertNil(try JSONDecoder().decode(Config.self, from: saved).monitors?[0].contrast)
    }
    func testContrastWithoutABoxIsKept() throws {
        let original = #"{ "monitors": [ { "match": "U2723QE", "contrast": 40 } ] }"#
        let m = (json(try ConfigPatch.apply(SettingsEdit(source: "off", monitors: [dell]), to: Data(original.utf8)))["monitors"] as! [[String: Any]])[0]
        XCTAssertEqual(m["contrast"] as? Int, 40, "an HDR or native monitor has no box: its contrast stays")
    }
    func testContrastBoxText() {
        XCTAssertTrue(ContrastRule.parseField("").ok); XCTAssertNil(ContrastRule.parseField("  ").value)
        XCTAssertEqual(ContrastRule.parseField("60").value, 60)
        XCTAssertEqual(ContrastRule.parseField("62,5").value, 63)
        XCTAssertEqual(ContrastRule.parseField("0").value, 0)
        XCTAssertFalse(ContrastRule.parseField("101").ok)
        XCTAssertFalse(ContrastRule.parseField("-1").ok)
        XCTAssertFalse(ContrastRule.parseField("high").ok)
    }

    func testCommentsAndTrailingCommasAreIgnored() throws {
        let text = """
        { // where
          "source": "sun", /* city level */ "location": { "latitude": 51.48, "longitude": -0.01, },
          "monitors": [ { "match": "a//b", "label": "x /* y */" }, ],
        }
        """
        let o = json(ConfigText.relaxed(Data(text.utf8)))
        XCTAssertEqual(o["source"] as? String, "sun")
        let m = (o["monitors"] as! [[String: Any]])[0]
        XCTAssertEqual(m["match"] as? String, "a//b")
        XCTAssertEqual(m["label"] as? String, "x /* y */")
    }

    func testKeepsWhatTheWindowDoesNotOwn() throws {
        let original = """
        { "manualHold": 7, "futureKey": [1, 2],
          "homeAssistant": { "url": "http://homeassistant.local:8123", "tokenName": "kc", "cover": "cover.blind" },
          "monitors": [
            { "match": "U2723QE", "control": "ddc", "day": 70, "contrast": 60, "homeAssistant": { "day": "input_number.left_day" } },
            { "match": "Unplugged", "day": 33 } ] }
        """
        var e = SettingsEdit(source: "homeAssistant", latitude: 51.4769, longitude: -0.0005, monitors: [dell],
                             haURL: "http://homeassistant.local:8123", cover: "")
        e.lights = "light.desk"
        let o = json(try ConfigPatch.apply(e, to: Data(original.utf8)))
        XCTAssertEqual(o["manualHold"] as? Int, 7)
        XCTAssertNotNil(o["futureKey"])
        let ha = o["homeAssistant"] as! [String: Any]
        XCTAssertEqual(ha["tokenName"] as? String, "kc")
        XCTAssertNil(ha["cover"], "an emptied field removes the key")
        XCTAssertEqual(ha["lights"] as? String, "light.desk")
        let loc = o["location"] as! [String: Double]
        XCTAssertEqual(loc["latitude"], 51.48); XCTAssertEqual(loc["longitude"], 0)
        let text = String(data: try ConfigPatch.apply(e, to: Data(original.utf8)), encoding: .utf8)!
        XCTAssertTrue(text.contains("51.48"), text); XCTAssertFalse(text.contains("51.479"), text)
        let mons = o["monitors"] as! [[String: Any]]
        XCTAssertEqual(mons.count, 2)
        XCTAssertEqual(mons[0]["control"] as? String, "ddc")
        XCTAssertEqual(mons[0]["contrast"] as? Int, 60)
        XCTAssertEqual(mons[0]["label"] as? String, "Left")
        XCTAssertEqual(mons[0]["day"] as? Int, 80)
        XCTAssertNotNil(mons[0]["homeAssistant"])
        XCTAssertEqual(mons[1]["day"] as? Int, 33)
    }

    func testANewMonitorIsAddedWithItsSuggestedMatch() throws {
        let o = json(try ConfigPatch.apply(SettingsEdit(source: "off", monitors: [dell]), to: nil))
        let m = (o["monitors"] as! [[String: Any]])[0]
        XCTAssertEqual(m["match"] as? String, "U2723QE")
        XCTAssertNil(o["location"])
        XCTAssertNil(o["homeAssistant"])
    }

    func testTwoMonitorsMatchingOneEntryDoNotOverwriteEachOther() throws {
        let a = SettingsEdit.Monitor(name: "DELL U2723QE (1)", suggestedMatch: "U2723QE", label: "", day: 80, blindDown: 40, night: 20)
        let b = SettingsEdit.Monitor(name: "DELL U2723QE (2)", suggestedMatch: "U2723QE", label: "", day: 10, blindDown: 10, night: 10)
        let o = json(try ConfigPatch.apply(SettingsEdit(source: "off", monitors: [a, b]), to: Data(#"{"monitors":[{"match":"U2723QE"}]}"#.utf8)))
        let mons = o["monitors"] as! [[String: Any]]
        XCTAssertEqual(mons.count, 1); XCTAssertEqual(mons[0]["day"] as? Int, 80)
    }
    func testLocationKeepsOtherKeysAndCommentsAreDetected() throws {
        let o = json(try ConfigPatch.apply(SettingsEdit(source: "sun", latitude: 1, longitude: 2),
                                           to: Data(#"{"location":{"latitude":0,"longitude":0,"note":"x"}}"#.utf8)))
        XCTAssertEqual((o["location"] as! [String: Any])["note"] as? String, "x")
        XCTAssertTrue(ConfigText.hasComments(Data("{ // hi\n}".utf8)))
        XCTAssertFalse(ConfigText.hasComments(Data(#"{ "a": "//not", }"#.utf8)))
    }
    func testTuningIsWrittenOnlyWhereItDiffersFromTheDefault() throws {
        var e = SettingsEdit(source: "off")
        e.tuning = ["brightness.sunDay": 15, "theme.lightSunAbove": 4, "timing.pollSeconds": 20]   // 4 is the default
        e.themeRoom = false
        let o = json(try ConfigPatch.apply(e, to: Data(#"{"tuning":{"theme":{"darkSunBelow":0},"future":1}}"#.utf8)))
        let t = o["tuning"] as! [String: Any]
        XCTAssertEqual((t["brightness"] as! [String: Any])["sunDay"] as? Int, 15)
        XCTAssertEqual((t["timing"] as! [String: Any])["pollSeconds"] as? Int, 20)
        let theme = t["theme"] as! [String: Any]
        XCTAssertNil(theme["lightSunAbove"]); XCTAssertNil(theme["darkSunBelow"], "cleared in the window")
        XCTAssertEqual(theme["room"] as? Bool, false)
        XCTAssertEqual(t["future"] as? Int, 1)
        XCTAssertNil(json(try ConfigPatch.apply(SettingsEdit(source: "off"), to: Data(#"{"tuning":{"theme":{"darkSunBelow":0}}}"#.utf8)))["tuning"])
        var bad = SettingsEdit(source: "off"); bad.tuning = ["brightness.sunNight": 20, "brightness.sunDay": 10]
        XCTAssertThrowsError(try ConfigPatch.apply(bad, to: nil))
    }
    func testAnInvalidResultIsRefused() {
        XCTAssertThrowsError(try ConfigPatch.apply(SettingsEdit(source: "homeAssistant", haURL: "homeassistant.local"), to: nil))
        XCTAssertThrowsError(try ConfigPatch.apply(SettingsEdit(source: "sun", lights: "Desk lamp"), to: nil))
        XCTAssertThrowsError(try ConfigPatch.apply(SettingsEdit(source: "sun"), to: Data("[1]".utf8)))
        XCTAssertThrowsError(try ConfigPatch.apply(SettingsEdit(source: "off"), to: Data(#"{"monitors":[null,{"match":"A"}]}"#.utf8)))
    }
}

final class TuningTests: XCTestCase {
    func testDefaultsGiveTheSameResultsAsBefore() {
        let t = Tuning()
        for elev in stride(from: -10.0, through: 30, by: 0.5) {
            XCTAssertEqual(daylightFraction(elevation: elev, tuning: t), min(max((elev + 3) / 15, 0), 1), accuracy: 1e-12)
            for lights in [false, true] {
                XCTAssertEqual(target(day: 70, blindDown: 40, night: 20, elev: elev, pos: 60, lights: lights, tuning: t),
                               target(day: 70, blindDown: 40, night: 20, elev: elev, pos: 60, lights: lights))
            }
        }
        XCTAssertEqual(target(day: 70, blindDown: 40, night: 20, elev: 1.4, pos: 100, lights: true), max(25, Int((20 + 50 * 4.4 / 15).rounded())))
    }
    func testCustomValuesMoveTheCurveAndTheBoost() throws {
        let t = try JSONDecoder().decode(Tuning.self, from: Data(#"{"brightness":{"sunNight":0,"sunDay":20,"lightsBoost":10,"lightsBoostSunBelow":0}}"#.utf8))
        XCTAssertEqual(daylightFraction(elevation: 10, tuning: t), 0.5)
        XCTAssertEqual(target(day: 70, blindDown: 40, night: 20, elev: -5, pos: 100, lights: true, tuning: t), 30)
        XCTAssertEqual(target(day: 70, blindDown: 40, night: 20, elev: 1, pos: 100, lights: true, tuning: t), 23, "no boost above lightsBoostSunBelow")
    }
    func testThemeThresholdsAndRoomSwitch() {
        var t = Tuning(); t.theme = .init(); t.theme?.lightSunAbove = 10; t.theme?.darkSunBelow = 6
        var look = LookRule()
        XCTAssertTrue(look.wantDark(elev: 8, pos: 100, hasBlind: false, lightsOn: false, bri: 0, sat: 0, tuning: t), "8° is under the 8.5° midpoint")
        XCTAssertFalse(look.wantDark(elev: 11, pos: 100, hasBlind: false, lightsOn: false, bri: 0, sat: 0, tuning: t))
        XCTAssertFalse(look.wantDark(elev: 8, pos: 100, hasBlind: false, lightsOn: false, bri: 0, sat: 0, tuning: t), "stays light inside the gap")
        t.theme?.room = false
        var sunOnly = LookRule()
        XCTAssertFalse(sunOnly.wantDark(elev: 20, pos: 0, hasBlind: true, lightsOn: false, bri: 0, sat: 0, tuning: t), "blind ignored")
    }
    func testImpossibleValuesAreRefused() throws {
        func check(_ json: String) throws -> String? { try JSONDecoder().decode(Config.self, from: Data(json.utf8)).validate() }
        XCTAssertNil(try check(#"{"tuning":{}}"#))
        XCTAssertNotNil(try check(#"{"tuning":{"brightness":{"sunNight":10,"sunDay":5}}}"#))
        XCTAssertNotNil(try check(#"{"tuning":{"theme":{"lightSunAbove":0,"darkSunBelow":2}}}"#))
        XCTAssertNotNil(try check(#"{"tuning":{"timing":{"pollSeconds":1}}}"#))
        XCTAssertEqual(try check(#"{"tuning":{"timing":{"pollSeconds":1}}}"#), "config.json: tuning.timing.pollSeconds must be 5–3600")
    }
}

final class AuditLogicTests: XCTestCase {
    func testTheLongestMatchingEntryWinsAndTheOrderDoesNotMatter() {
        let name = "Dell AW3821DW"
        XCTAssertEqual(MonitorMatch.best(name: name, matches: ["Dell", "AW3821DW"]), 1)
        XCTAssertEqual(MonitorMatch.best(name: name, matches: ["AW3821DW", "Dell"]), 0)
        XCTAssertEqual(MonitorMatch.best(name: name, matches: ["Dell", "Dell"]), 0)    // equal: the first
    }
    func testAMatchIsTrimmedCaseInsensitiveAndNeverEmpty() {
        XCTAssertEqual(MonitorMatch.best(name: "Dell AW3821DW", matches: ["  aw3821dw "]), 0)
        XCTAssertNil(MonitorMatch.best(name: "Dell AW3821DW", matches: ["", "   "]))
        XCTAssertNil(MonitorMatch.best(name: "Dell AW3821DW", matches: ["LG"]))
        XCTAssertEqual(MonitorMatch.best(name: "Dell AW3821DW", matches: ["   ", "Dell "]), 1)
    }
    func testTheConfigFindsTheEntryByTheLongestMatch() throws {
        let c = try JSONDecoder().decode(Config.self, from: Data(#"{"monitors":[{"match":"Dell","day":10},{"match":"AW3821DW","day":90}]}"#.utf8))
        XCTAssertEqual(c.monitor(for: "Dell AW3821DW")?.day, 90)
        XCTAssertEqual(c.monitor(for: "Dell U2723QE")?.day, 10)
        XCTAssertNil(c.monitor(for: "LG"))
    }
    func testSavingChoosesTheLongestMatchingEntry() throws {
        let original = #"{ "monitors": [ { "match": "Dell", "day": 10 }, { "match": "AW3821DW", "day": 20 } ] }"#
        let e = SettingsEdit(source: "off", monitors: [.init(name: "Dell AW3821DW", suggestedMatch: "AW3821DW", label: "", day: 77, blindDown: 40, night: 20)])
        let out = try JSONSerialization.jsonObject(with: ConfigPatch.apply(e, to: Data(original.utf8))) as! [String: Any]
        let list = out["monitors"] as! [[String: Any]]
        XCTAssertEqual(list[0]["day"] as? Int, 10)
        XCTAssertEqual(list[1]["day"] as? Int, 77)
        let applied = try JSONSerialization.jsonObject(with: ConfigPatch.setLevels(["day": 55], display: "Dell AW3821DW", suggestedMatch: "AW3821DW", in: Data(original.utf8))) as! [String: Any]
        XCTAssertEqual((applied["monitors"] as! [[String: Any]])[1]["day"] as? Int, 55)
    }
    func testANullMonitorsListIsAsAbsentForSaveAndApply() throws {
        let original = #"{ "source": "off", "monitors": null }"#
        let e = SettingsEdit(source: "off", monitors: [.init(name: "DELL U2723QE", suggestedMatch: "U2723QE", label: "", day: 80, blindDown: 45, night: 15)])
        let saved = try JSONSerialization.jsonObject(with: ConfigPatch.apply(e, to: Data(original.utf8))) as! [String: Any]
        XCTAssertEqual((saved["monitors"] as! [[String: Any]]).count, 1)
        let applied = try JSONSerialization.jsonObject(with: ConfigPatch.setLevels(["day": 55], display: "DELL U2723QE", suggestedMatch: "U2723QE", in: Data(original.utf8))) as! [String: Any]
        XCTAssertEqual((applied["monitors"] as! [[String: Any]])[0]["day"] as? Int, 55)
        XCTAssertThrowsError(try ConfigPatch.apply(e, to: Data(#"{"monitors": 5}"#.utf8)))   // a wrong type still stops
    }
    func testAClockSetBackDoesNotHoldTicksOff() {
        XCTAssertFalse(tickDue(elapsed: 10, interval: 30))
        XCTAssertTrue(tickDue(elapsed: 30, interval: 30))
        XCTAssertTrue(tickDue(elapsed: -3600, interval: 30))   // lastTick is in the future
    }
    func testTheLightHistoryWaitsAnHourWithoutAReferenceAndADayWithOne() {
        XCTAssertFalse(lightHistoryDue(elapsed: 3599, hasReference: false, young: false))
        XCTAssertTrue(lightHistoryDue(elapsed: 3600, hasReference: false, young: false))
        XCTAssertFalse(lightHistoryDue(elapsed: 3599, hasReference: true, young: true))
        XCTAssertFalse(lightHistoryDue(elapsed: 3600, hasReference: true, young: false))
        XCTAssertTrue(lightHistoryDue(elapsed: 86400, hasReference: true, young: false))
        XCTAssertTrue(lightHistoryDue(elapsed: -3600, hasReference: true, young: false))    // the clock was set back
        XCTAssertTrue(lightHistoryDue(elapsed: -1, hasReference: false, young: false))
    }
    func testARetryStampMakesTheHistoryDueInAnHourNotOnTheNextTick() {
        let now = 1_000_000.0
        for (has, young) in [(false, false), (true, true), (true, false), (false, true)] {
            let stamp = lightRetryStamp(now: now, hasReference: has, young: young)
            XCTAssertFalse(lightHistoryDue(elapsed: now + 30 - stamp, hasReference: has, young: young), "30 s later, \(has) \(young)")
            XCTAssertTrue(lightHistoryDue(elapsed: now + 3600 - stamp, hasReference: has, young: young), "an hour later, \(has) \(young)")
        }
    }
}
