import XCTest
@testable import DaylitCore

final class LightTests: XCTestCase {
    func ref() -> LightReference {
        // Clear mornings read up to 500 at 10–12°, noon 1600 at 30–32°.
        var s: [(elev: Double, morning: Bool, value: Double)] = []
        for k in 0..<10 { s.append((11, true, Double(50 + k * 50))); s.append((31, true, 1600)) }
        return LightReference(samples: s)
    }

    func testTheReferenceIsTheNinetiethPercentileOfEachStep() {
        let r = ref()
        XCTAssertEqual(r.clearSky(elev: 10.5, morning: true), 450)   // 50…500: the 90th percentile
        XCTAssertNil(r.clearSky(elev: 10.5, morning: false))          // afternoons are learned apart
        XCTAssertNil(LightReference(samples: [(11, true, 400), (11, true, 400)]).clearSky(elev: 11, morning: true))   // too few
    }
    func testACloudyMorningReadsAsAFractionOfClearSky() {
        XCTAssertEqual(lightRatio(value: 45, elev: 11, morning: true, reference: ref())!, 0.1, accuracy: 1e-9)
        XCTAssertEqual(lightRatio(value: 900, elev: 11, morning: true, reference: ref()), 1)   // brighter than clear: 1
    }
    func testAZeroWithTheSunUpIsAFaultNotACloud() {
        XCTAssertNil(lightRatio(value: 0, elev: 31, morning: true, reference: ref()))
        XCTAssertNil(lightRatio(value: nil, elev: 31, morning: true, reference: ref()))
        XCTAssertNil(lightRatio(value: 300, elev: -1, morning: true, reference: ref()))
    }
    func testOvercastKeepsTheFloorAndDawnFadesIn() {
        XCTAssertEqual(lightScale(ratio: 0, elev: 20, floor: 0.35), 0.35, accuracy: 1e-9)
        XCTAssertEqual(lightScale(ratio: 1, elev: 20, floor: 0.35), 1)
        XCTAssertEqual(lightScale(ratio: 0, elev: 4.5, floor: 0.35), 0.675, accuracy: 1e-9)   // half faded in
        XCTAssertEqual(lightScale(ratio: 0, elev: 2, floor: 0.35), 1)
        XCTAssertEqual(lightScale(ratio: nil, elev: 20, floor: 0.35), 1)
    }
    func testDimmingIsQuickerThanBrightening() {
        let down = smoothLight(1, toward: 0.35, dt: 120), up = smoothLight(0.35, toward: 1, dt: 120)
        XCTAssertLessThan(down, 1 - 0.6 * 0.65)          // most of the way down in 2 minutes
        XCTAssertLessThan(up, 0.35 + 0.4 * 0.65)         // under half way up
        XCTAssertEqual(smoothLight(nil, toward: 0.5, dt: 0), 0.5)
    }
    func testTheLightScaleDimsOnlyTheDaylightPart() {
        // day 70, night 20, full sun: clear 70; overcast keeps 35% of the 50-point daylight part.
        XCTAssertEqual(target(day: 70, blindDown: 40, night: 20, elev: 30, pos: 100, lights: false), 70)
        XCTAssertEqual(target(day: 70, blindDown: 40, night: 20, elev: 30, pos: 100, lights: false, light: 0.35), 38)
        XCTAssertEqual(target(day: 70, blindDown: 40, night: 20, elev: -10, pos: 100, lights: false, light: 0.35), 20)
    }
    func testHistoryReadingsGetTheSunsPosition() {
        let json = #"[[{"entity_id":"sensor.pv","state":"300","last_changed":"2026-06-21T12:00:00+00:00"},"#
                 + #"{"state":"unavailable","last_changed":"2026-06-21T12:01:00+00:00"},"#
                 + #"{"state":"0","last_changed":"2026-06-21T23:00:00.123+00:00"}]]"#
        let s = lightSamples(history: Data(json.utf8), latitude: 51.48, longitude: 0)
        XCTAssertEqual(s.count, 1)                       // the night reading and the non-number are skipped
        XCTAssertEqual(s[0].value, 300)
        XCTAssertGreaterThan(s[0].elev, 60)              // midsummer noon at Greenwich
    }
    func testALightSensorNeedsALocation() {
        XCTAssertNotNil(Config(homeAssistant: HAConfig(url: "http://homeassistant.local:8123", light: "sensor.pv_power")).validate())
        XCTAssertNil(Config(location: .init(latitude: 51.48, longitude: 0),
                            homeAssistant: HAConfig(url: "http://homeassistant.local:8123", light: "sensor.pv_power")).validate())
    }
    func testTheTemplateAsksForTheLightSensor() {
        let t = HATemplate.build(HAConfig(url: "http://x", light: "sensor.pv_power"), [])
        XCTAssertTrue(t.contains("states('sensor.pv_power') | float(-1)"))
        XCTAssertTrue(t.contains("\"lightAge\""))
        XCTAssertTrue(HATemplate.build(HAConfig(url: "http://x"), []).contains("\"light\": -1"))
    }
}
