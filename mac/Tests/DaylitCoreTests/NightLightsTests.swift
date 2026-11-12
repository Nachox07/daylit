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
