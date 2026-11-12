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
