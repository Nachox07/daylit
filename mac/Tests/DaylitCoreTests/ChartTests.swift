import XCTest
@testable import DaylitCore

final class ChartTests: XCTestCase {
    let gmt = TimeZone(identifier: "GMT")!
    func day(_ iso: String, lat: Double, tz: TimeZone? = nil) -> [(t: Double, e: Double)] {
        let d = ISO8601DateFormatter().date(from: iso)!
        let b = dayBounds(d, timeZone: tz ?? gmt)
        return daySamples(latitude: lat, longitude: 0, start: b.start, length: b.length)
    }

    func testAHandleSitsOnTheMorningCrossingWithTheEveningOneAsItsPartner() {
        let s = day("2026-06-19T12:00:00Z", lat: 51.48)
        let p = handlePlace(s, line: 12)
        XCTAssertFalse(p.parked)
        XCTAssertLessThan(p.at, 0.5); XCTAssertGreaterThan(p.partner!, 0.5)
        XCTAssertEqual(elevation(s, at: p.at), 12, accuracy: 0.05)
        XCTAssertEqual(elevation(s, at: p.partner!), 12, accuracy: 0.05)
        // Dragging the evening end puts the handle there and the morning one becomes the partner.
        let e = handlePlace(s, line: 12, morning: false)
        XCTAssertEqual(e.at, p.partner!, accuracy: 1e-9); XCTAssertEqual(e.partner!, p.at, accuracy: 1e-9)
    }
    func testMorningAndEveningAreNotAMirrorAroundNoonOnTheClock() {
        // At 10°E the sun peaks well before 12:00 GMT, so the crossings centre on solar noon instead.
        let d = ISO8601DateFormatter().date(from: "2026-06-19T12:00:00Z")!
        let b = dayBounds(d, timeZone: gmt)
        let s = daySamples(latitude: 51.48, longitude: 10, start: b.start, length: b.length)
        let p = handlePlace(s, line: 12)
        XCTAssertLessThan((p.at + p.partner!) / 2, 0.48)
    }
    func testWhenTheSunNeverReachesTheLineTheHandleParksOnThePeak() {
        let s = day("2026-12-21T12:00:00Z", lat: 70)   // noon about -3.4°: under the 12° line all day
        let p = handlePlace(s, line: 12)
        XCTAssertTrue(p.parked); XCTAssertNil(p.partner); XCTAssertFalse(p.sunAbove)
        XCTAssertEqual(p.at, 0.5, accuracy: 0.02)
        // A click on it saves nothing; dragging it away saves the sun's height where it lands.
        XCTAssertNil(draggedElevation(s, to: p.at, day: true, other: -3, parkedAt: p.at))
        XCTAssertNotNil(draggedElevation(s, to: 0.45, day: true, other: -6, parkedAt: p.at))
    }
    func testInPolarDayTheNightHandleParksOnTheTrough() {
        let s = day("2026-06-21T12:00:00Z", lat: 80)   // the sun stays about 13° up at midnight
        let p = handlePlace(s, line: -3)
        XCTAssertTrue(p.parked); XCTAssertTrue(p.sunAbove)
        XCTAssertTrue(p.at < 0.02 || p.at > 0.98)
    }
    func testTheHandlesNeverCrossAndStayInTheAcceptedRange() {
        let s = day("2026-06-19T12:00:00Z", lat: 51.48)
        XCTAssertEqual(draggedElevation(s, to: 0.1, day: true, other: 2), 2.5)    // the full-day line stops above night
        XCTAssertEqual(draggedElevation(s, to: 0.5, day: false, other: 12), 11.5)  // and night stops below it
        XCTAssertEqual(draggedElevation(s, to: 0.5, day: true, other: -3)!, 60, accuracy: 3)   // noon here is about 62°: clamped to 60
        let v = draggedElevation(s, to: 0.3, day: true, other: -3)!
        XCTAssertEqual(v * 2, (v * 2).rounded())                                    // half-degree steps
    }
    func testClockChangeDaysAre23And25HoursLong() {
        let london = TimeZone(identifier: "Europe/London")!
        let spring = dayBounds(ISO8601DateFormatter().date(from: "2026-03-29T12:00:00Z")!, timeZone: london)
        let autumn = dayBounds(ISO8601DateFormatter().date(from: "2026-10-25T12:00:00Z")!, timeZone: london)
        XCTAssertEqual(spring.length, 23 * 3600); XCTAssertEqual(autumn.length, 25 * 3600)
    }

    func testTheExplanationEndsOnTheLevelTheTickSets() {
        let t = Tuning()
        for elev in stride(from: -10.0, through: 40, by: 2.5) {
            for pos in [0.0, 40, 100] {
                for light in [1.0, 0.8, 0.35] {
                    for lights in [false, true] {
                        let base = target(day: 90, blindDown: 70, night: 45, elev: elev, pos: pos, lights: lights, tuning: t, light: light)
                        let d = explain(day: 90, blindDown: 70, night: 45, elev: elev, pos: pos, lights: lights, tuning: t, light: light, offset: 6)
                        XCTAssertEqual(d.level, min(base + 6, 100))
                        XCTAssertEqual(d.steps.last!.final, true)
                    }
                }
            }
        }
    }
    func testTheExplanationReadsInTheOrderTheRulesApply() {
        let d = explain(day: 90, blindDown: 70, night: 45, elev: 30, pos: 40, lights: false, light: 0.8, offset: 6)
        XCTAssertEqual(d.steps.map(\.title), ["Blind 40% open", "Sun high", "Cloudy", "Lights", "You"])
        XCTAssertEqual(d.steps.map(\.value), ["daytime 78", "100% → 78", "daylight 80% → 71", "no effect by day", "+6 → 77"])
        XCTAssertEqual(d.level, 77)
    }
    func testRoomLightsAtDuskLiftTheNightLevel() {
        let d = explain(day: 90, blindDown: 70, night: 45, elev: -5, pos: 0, lights: true)
        XCTAssertEqual(d.level, 50)
        XCTAssertEqual(d.steps.first { $0.title == "Lights" }?.value, "on → 50")
    }
    func testWithoutABlindTheFirstStepIsTheDayLevel() {
        let d = explain(day: 90, blindDown: 70, night: 45, elev: 30, pos: nil, lights: false)
        XCTAssertEqual(d.steps.first, DecisionStep("Day level", "90"))
        XCTAssertEqual(d.steps.last, DecisionStep("Now", "90", final: true))
    }
}
