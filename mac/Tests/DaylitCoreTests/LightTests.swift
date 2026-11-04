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
    func testAZeroIsAFaultNotACloud() {
        XCTAssertNil(lightRatio(value: 0, elev: 31, morning: true, reference: ref()))
        XCTAssertNil(lightRatio(value: 0, elev: 11, morning: true, reference: ref()))   // a smaller step too
        XCTAssertNil(lightRatio(value: nil, elev: 31, morning: true, reference: ref()))
        XCTAssertNil(lightRatio(value: 300, elev: -1, morning: true, reference: ref()))
    }
    func testOvercastCapsDaylightAtTheFloor() {
        XCTAssertEqual(lightCap(ratio: 0, floor: 0.35), 0.35, accuracy: 1e-9)
        XCTAssertEqual(lightCap(ratio: 0.5, floor: 0.35), 0.675, accuracy: 1e-9)
        XCTAssertEqual(lightCap(ratio: 1, floor: 0.35), 1)
        XCTAssertEqual(lightCap(ratio: nil, floor: 0.35), 1)
    }
    func testAnOvercastDawnNeverDipsAsTheSunRises() {
        // day 70, night 20, fully overcast: the level climbs with the sun and stops at the cap.
        let levels = stride(from: -3.0, through: 20, by: 0.5).map {
            target(day: 70, blindDown: 40, night: 20, elev: $0, pos: 100, lights: false, light: 0.35)
        }
        XCTAssertEqual(levels, levels.sorted())
        XCTAssertEqual(levels.last, 38)
    }
    func testAnEastFacingArrayIsComparedWithinItsOwnHalfOfTheDay() {
        var s: [(elev: Double, morning: Bool, value: Double)] = []
        for _ in 0..<5 { s.append((11, true, 4000)); s.append((11, false, 150)) }
        let r = LightReference(samples: s)
        XCTAssertEqual(lightRatio(value: 30, elev: 11, morning: false, reference: r)!, 0.2, accuracy: 1e-9)
    }
    func testAStepThatOnlyReadZeroIsNotAReference() {
        let r = LightReference(samples: (0..<5).map { _ in (elev: 31.0, morning: true, value: 0.0) })
        XCTAssertTrue(r.isEmpty)
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
        XCTAssertTrue(t.contains("state_attr('sensor.pv_power','unit_of_measurement')"))
        XCTAssertTrue(HATemplate.build(HAConfig(url: "http://x"), []).contains("\"light\": -1"))
        XCTAssertTrue(HATemplate.build(HAConfig(url: "http://x"), []).contains("\"lightUnit\": null"))
    }
    func testTheAnswerCarriesTheSensorUnit() {
        let base = #"{"elev": 10, "pos": 100, "lights": false, "auto": null, "bri": 0, "sat": 100, "light": 3.2, "lightAge": 5, "m": {}"#
        XCTAssertEqual(HAState.parse(Data((base + #", "lightUnit": "kW"}"#).utf8))?.lightUnit, "kW")
        XCTAssertNil(HAState.parse(Data((base + "}").utf8))?.lightUnit)   // an answer without it still parses
    }

    func testAUnitChangeRestartsLearningFromThatMoment() {
        let day = 86400.0, now = 100 * day
        // First seen: its whole history is trusted.
        let first = LightUnit.update(nil, sensor: "sensor.pv_power", unit: "W", now: now)
        XCTAssertEqual(first, LightUnit(sensor: "sensor.pv_power", unit: "W", since: 0))
        XCTAssertEqual(first.historyDays(10, now: now), 10)
        // Same unit: nothing changes.
        XCTAssertEqual(LightUnit.update(first, sensor: "sensor.pv_power", unit: "W", now: now + day), first)
        // W to kW: the older readings are 1000 times off, so learning starts again from now.
        let kw = LightUnit.update(first, sensor: "sensor.pv_power", unit: "kW", now: now)
        XCTAssertEqual(kw, LightUnit(sensor: "sensor.pv_power", unit: "kW", since: now))
        XCTAssertEqual(kw.historyDays(10, now: now + 2 * day), 2, accuracy: 1e-9)
        XCTAssertEqual(kw.historyDays(10, now: now + 30 * day), 10)
    }
    func testAMissingUnitIsNotAUnitChange() {
        let w = LightUnit(sensor: "sensor.pv_power", unit: "W", since: 0)
        // The sensor is briefly unavailable and reports no unit: keep what was learned.
        XCTAssertEqual(LightUnit.update(w, sensor: "sensor.pv_power", unit: nil, now: 50), w)
        XCTAssertEqual(LightUnit.update(w, sensor: "sensor.pv_power", unit: "", now: 50), w)
        // No unit known yet (started while it was unavailable): the first real one is adopted, not a change.
        let unknown = LightUnit.update(nil, sensor: "sensor.pv_power", unit: nil, now: 50)
        XCTAssertEqual(LightUnit.update(unknown, sensor: "sensor.pv_power", unit: "W", now: 60), w)
        // Another sensor starts fresh with its own history.
        XCTAssertEqual(LightUnit.update(w, sensor: "sensor.solar_power", unit: "kW", now: 50),
                       LightUnit(sensor: "sensor.solar_power", unit: "kW", since: 0))
    }
}
