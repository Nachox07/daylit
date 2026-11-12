# A Night Level For When The Room Lights Are On — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Each monitor gets an optional fourth level, `nightLights` (0–100): the level after sunset with the room lights on. Without it nothing changes; with it, `night` becomes the dark-room level that weak daylight blends toward, and the global lights boost no longer applies to that monitor. Both apps (macOS and Windows) behave the same.

**Architecture:** The pure cores (`mac/Sources/DaylitCore`, `windows/Rules.cs` / `Chart.cs` / `Config.cs` / `Suggest.cs`) get the new `target` rule, a fourth entry in the levels array (`[day, blindDown, night]` or `[day, blindDown, night, nightLights]`), the per-monitor lights rule for the sun fallback, config keys and validation, the four-level suggestion rules and the "How Daylit decides" step. The Home Assistant template row becomes `[day, blindDown, night, nightLights, set, setChanged]`. The apps wire the last lights state into the fallback (opt-in monitors only), pass `nightLights` to `target`, and add an optional **Lights on** row in Settings → Displays.

**Tech Stack:** Swift 5.9 package (XCTest, SwiftUI, AppKit), .NET 10 WPF (xUnit), Home Assistant REST template API.

**Spec:** `docs/superpowers/specs/2026-11-12-night-lights-design.md` (read it once before Task 1).

---

## Read this first (every task)

- Work only in the worktree of branch `feature/night-lights` (`.worktrees/night-lights` inside the main checkout). All paths below are relative to its root; run commands from there.
- **macOS:** `cd mac && swift test` runs the core tests. `mac/build.sh /tmp/daylit-build` builds the app; it must finish with **0 errors and 0 warnings** (pass a folder so it does not replace `~/Applications/Daylit.app`).
- **Windows: there is no `dotnet` on this Mac.** Windows code is compiled and tested only by CI (`.github/workflows/build.yml`, job `windows`) after a push. Be extra careful with C# syntax. Known traps:
  - A ternary that mixes a value and `null` needs a cast: `cond ? (double?)x : null`. Every such ternary in this plan already has the cast; keep it.
  - A pattern variable declared in an `if` condition or an `is` expression stays in scope for the rest of the enclosing block or expression-bodied member, so pick names not used elsewhere in the method (this plan uses `nlv`, `lit`, `litOk`, `usedLit`, `roomLit`, which are free in the methods they go into).
  - Records compare arrays by reference (`Sample` overrides `Equals` for that reason; `LiveInputs` and `ChartMonitor` do not need to).
  - Prefer `new[] { a, b, c }` over a collection expression inside a ternary: `[..]` has no natural type there.
- To check a Windows task on CI after pushing: `gh run list --branch feature/night-lights --limit 1` gives the run id, then `gh run watch <id> --exit-status`. On a failure, `gh run view <id> --log-failed | head -80` shows the compiler or test error.
- **Public repo.** No real coordinates, IP addresses, Home Assistant entity names, home-folder paths or tokens in code, tests, docs or commits. Monitor keys in tests are `"m"` / `"U"`; entity names are made up (`input_number.lit`). If a place is needed, Greenwich (51.48, 0). **Never read, print or handle the Home Assistant token.**
- Test names describe behaviour. Never put issue numbers in test names, test descriptions or commit subjects.
- Commit subjects start with the area: `Mac:`, `Windows:`, `Docs:`, `UI snapshots:`. End every commit message with the line `Co-Authored-By: Claude <noreply@anthropic.com>` and no other trailer or link.
- UI snapshot baselines (`mac/Tests/Snapshots`, `windows/tests/Snapshots`) are **never recorded locally**: Task 15 records them on CI (CONTRIBUTING.md → *UI snapshots*). From Task 12 until Task 15, CI's macOS job fails at the *UI snapshots* step with `settings-displays-…` changed; from Task 13 the Windows job does the same. That is expected; every other step must pass.

## Key existing code (where things hook in)

| Symbol | Where | What it is |
|---|---|---|
| `target(day:blindDown:night:elev:pos:lights:tuning:light:) -> Int` | `mac/Sources/DaylitCore/Rules.swift` | the automatic level; `s = min(daylightFraction(elev), light)` |
| `effectiveLevels(local:fromHA:)`, `fallbackLevels(_:)`, `RemoteSet(row:)` | `mac/Sources/DaylitCore/Rules.swift` | levels in effect; what the sun fallback keeps of a Home Assistant row; the "set" helper |
| `HATemplate.build`, `HAState.parse` | `mac/Sources/DaylitCore/HATemplate.swift` | the one template per tick and its answer (rows checked to have 5 numbers today) |
| `MonitorConfig`, `MonitorHA`, `Config.validate()` | `mac/Sources/DaylitCore/Config.swift` | config model and validation |
| `SettingsEdit.Monitor`, `ConfigPatch.apply` | `mac/Sources/DaylitCore/ConfigEdit.swift` | what the Settings window saves, keeping every other key |
| `explain(...) -> Decision` | `mac/Sources/DaylitCore/Chart.swift` | "How Daylit decides, right now" |
| `Suggest.makeSample`, `fit`, `rerun`, `suggestion`, `decode` | `mac/Sources/DaylitCore/Suggest.swift` | suggestion core; checks `levels.count == 3` today |
| `Daylit.tick()` / `ownTarget` / `inputs()` / `fromSun` / `lastHAPos` | `mac/Sources/Daylit/Model.swift` | the tick, its inputs, the sun fallback |
| `levels(of:_:)`, `haLevelsUnavailable` | `mac/Sources/Daylit/Suggestions.swift` | a monitor's levels this tick |
| `Mon` | `mac/Sources/Daylit/Displays.swift` | a detected monitor with its config levels |
| `LiveInputs`, `ChartMonitor`, `BrightnessChart.decision` | `mac/Sources/Daylit/BrightnessChart.swift` | the Settings chart |
| `MonitorDraft`, `SettingsView.displaysPane` / `load` / `edit` / `caption` / `brightnessChart` | `mac/Sources/Daylit/Settings.swift` | Settings → Displays |
| `CLI.checkConfig` | `mac/Sources/Daylit/Cli.swift` | `--check-config` |
| `Rules.Target(double[] v, double pos, bool lights, double sun, Tuning? t, bool? boost, double light)` | `windows/Rules.cs` | Windows target; `sun` is the elevation's fraction, `light` the cloud cap |
| `HaTemplate.Build` | `windows/Rules.cs` | Windows template (one row per monitor, in order) |
| `Chart.EffectiveLevels`, `Chart.Explain`, `LiveInputs` | `windows/Chart.cs` | as on the Mac |
| `MonitorConfig`, `MonitorHa`, `Config.Validate`, `SettingsEdit`, `ConfigPatch.Apply` | `windows/Config.cs` | config |
| `HAClient.State` | `windows/Sources.cs` | parses the template answer into `Inputs.Levels` / `Remote` / `FromHa` |
| `Mon.HaLevels`, `Mon.Day/BlindDown/Night` | `windows/Displays.cs` | per-monitor levels |
| `Controller.SunInputs`, `TickOnce` loop around `Rules.Target` | `windows/App.cs` ~lines 389–396, 540–690 | the tick and the fallback |
| `Suggest.MakeSample`, `Fit`, `Rerun`, `SuggestionFor`, `Decode`, `Storable` | `windows/Suggest.cs` | suggestion core |
| `HaLevelsUnavailable` | `windows/Suggestions.cs` | as on the Mac |
| `Settings` window rows, `Contrast(TextBox)`, `Refresh`, `Save`, `RebuildCurves` | `windows/Settings.cs` | Settings → Displays |
| `ChartMonitor`, `BrightnessChart.Levels` / `Decide` | `windows/BrightnessChart.cs` | the chart |
| `Cli.CheckConfig` | `windows/Cli.cs` | `--check-config` |

## Decisions this plan takes (the spec left them open)

1. **Levels array.** A monitor's levels in effect are `[day, blindDown, night]`, or `[day, blindDown, night, nightLights]` when it has one. A monitor without `nightLights` keeps a three-element array everywhere, so its `corrections.json` samples, its suggestion snapshot and its behaviour are untouched. A monitor with one has four, so changing `nightLights` (or adding it) makes older samples stale through the existing `sameLevels` length-and-value check.
2. **Home Assistant row order.** The template row becomes `[day, blindDown, night, nightLights, set, setChanged]` (6 numbers), levels first: `fallbackLevels` keeps `prefix(4)`, `effectiveLevels` reads index 3, `RemoteSet` moves to indices 4 and 5, and `HAState.parse` / Windows `State` require 6. An old 5-number answer cannot happen (the app builds the template it parses).
3. **`sun` in the anchor** is `daylightFraction(elev)` (the elevation's share, not capped by clouds); the blend uses `s = min(sun, light)`, as the spec writes it. So a cloudy morning with the sun high anchors at `night`.
4. **Validation.** The other three levels are not range-checked today (they are clamped). `nightLights` is a new key, so a local value outside 0–100 is rejected (`config.json: monitor "<match>" nightLights is 0 to 100`), as the spec asks; no existing config can break. The Home Assistant helper is checked like the others (entity id).
5. **Settings visibility.** The **Lights on** row shows when the source is Home Assistant and the window's *Lights* entity box is not empty (it follows the box live). When hidden, the file's `nightLights` is kept (like contrast without its box). Its value is parsed with the existing `ContrastRule.parseField` (0–100 or empty). The help text is the field's tooltip / automation help and is also appended to the card's caption.
6. **Fallback.** A pure `roomLights(reported:fromHA:last:hasNightLights:)` decides the lights per monitor. `last` is the last lights state Home Assistant gave, passed only when the source is Home Assistant (a sun-only config has no lights).
7. **The chart** lines are drawn lights-off, so they do not change. The "How Daylit decides" step uses `explain(..., nightLights:)` with the lights state the tick used for that monitor (`LiveInputs.lightsUsed`), so its level still equals the tick's. With `nightLights`, the *Lights* step reads `on → <level>` when the lights move the level, `on, no effect now`, `off` (sun not fully up) or `no effect by day`.
8. **Suggestions** skip a sample when the monitor has `nightLights`, the lights are on and `daylightFraction(elev) < 1`. A four-level sample keeps its `nightLights` through `fit` and `rerun` runs the four-level `target`. A configured `nightLights` helper that is unavailable counts as "Home Assistant levels unavailable" (samples are not judged stale then).
9. **`--check-config`** adds a note (not a problem) when a monitor sets `nightLights` but there is no Home Assistant lights entity: the lights then count as off and the level never applies.
10. **The spec's example numbers.** With day 95, blind down 62, night 60, lights on 80 and clouds capping daylight at 0.5: blind 40% → **68** (67.6), blind 58% → **71** (70.57; the spec says 70, which needs a cap of 0.49 → 70.36), blind open with a cap of 0.55 → **79** (79.25), dark evening with the lights on → **80**. These were run in a scratch copy of `mac/` while writing this plan (all 259 core tests green, `mac/build.sh` 0 warnings). The test asserts 71 at 0.5 and 70 at 0.49.

## File map

Create:
- `mac/Tests/DaylitCoreTests/NightLightsTests.swift`: every new core test on the Mac.
- `windows/tests/NightLightsTests.cs`: the same cases in C#.

Modify (Mac core): `mac/Sources/DaylitCore/Rules.swift`, `HATemplate.swift`, `Config.swift`, `ConfigEdit.swift`, `Suggest.swift`, `Chart.swift`; `mac/Tests/DaylitCoreTests/DaylitCoreTests.swift` (row layout and the example config).
Modify (Mac app): `mac/Sources/Daylit/Displays.swift`, `Model.swift`, `Suggestions.swift`, `BrightnessChart.swift`, `Settings.swift`, `Cli.swift`.
Modify (Windows): `windows/Rules.cs`, `Chart.cs`, `Config.cs`, `Suggest.cs` (core, compiled by the test project); `windows/Sources.cs`, `Displays.cs`, `App.cs`, `Suggestions.cs`, `Settings.cs`, `BrightnessChart.cs`, `Cli.cs` (app); `windows/tests/RulesTests.cs` (template row and the example config).
Modify (docs): `README.md`, `docs/setup.md`, `AGENTS.md`, `config.example.json`, `homeassistant/daylit_helpers.yaml`.
Snapshots: `mac/Tests/Snapshots/settings-displays-*.png`, `windows/tests/Snapshots/settings-displays-*.png` (re-recorded on CI, Task 15).

---

### Task 1: Mac core — `target` with an optional `nightLights`

**Files:**
- Modify: `mac/Sources/DaylitCore/Rules.swift` (the `target` function)
- Create: `mac/Tests/DaylitCoreTests/NightLightsTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `mac/Tests/DaylitCoreTests/NightLightsTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd mac && swift test --filter NightLightsTargetTests`
Expected: build FAILS with `extra argument 'nightLights' in call`.

- [ ] **Step 3: Implement**

In `mac/Sources/DaylitCore/Rules.swift`, replace the whole `target` function with:

```swift
public func target(day: Double, blindDown: Double, night: Double, elev: Double, pos: Double, lights: Bool,
                   tuning t: Tuning = Tuning(), light: Double = 1, nightLights: Double? = nil) -> Int {
    let sunUp = daylightFraction(elevation: elev, tuning: t)
    let sun = min(sunUp, light)
    let daytime = blindDown + (day - blindDown) * pos / 100
    var v: Double
    if let nl = nightLights {
        // A monitor with its own lit-evening level: weak daylight blends toward night with the lights off.
        // With them on it blends toward a point that slides from night (sun high) to nightLights (sun down),
        // so the lamps change nothing in daylight and there is no step at dusk. No boost.
        let anchor = lights ? night * sunUp + nl * (1 - sunUp) : night
        v = anchor + (daytime - anchor) * sun
    } else {
        v = night + (daytime - night) * sun
        if lights && elev < t.lightsBoostSunBelow { v = max(v, night + t.lightsBoost) }
    }
    return Int(min(max(v, 0), 100).rounded())
}
```

Also add one line to the doc comment above `blindPosition`/`target` (the block that starts "Target level:"): `/// With nightLights (optional), the room lights move the night end of the blend instead of adding the boost.`

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd mac && swift test --filter NightLightsTargetTests` → 6 tests, 0 failures.
Run: `cd mac && swift test` → all green (the old `TargetTests` and `TuningTests` still pass).

- [ ] **Step 5: Commit**

```bash
git add mac/Sources/DaylitCore/Rules.swift mac/Tests/DaylitCoreTests/NightLightsTests.swift
git commit -m "Mac: target takes an optional night level for when the room lights are on

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 2: Mac core — levels in effect and the lights in the sun fallback

**Files:**
- Modify: `mac/Sources/DaylitCore/Rules.swift` (`effectiveLevels`; new `nightLightsLevel`, `roomLights`)
- Modify: `mac/Tests/DaylitCoreTests/NightLightsTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `mac/Tests/DaylitCoreTests/NightLightsTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd mac && swift test --filter NightLights`
Expected: build FAILS with `cannot find 'nightLightsLevel' in scope` and `cannot find 'roomLights' in scope`.

- [ ] **Step 3: Implement**

In `mac/Sources/DaylitCore/Rules.swift`, replace `effectiveLevels` (and its doc comment) with the block below, and add the two new functions right after it (leave `fallbackLevels` as it is until Task 7):

```swift
/// The levels in effect: [day, blindDown, night], plus a fourth, nightLights, when the monitor has one.
/// `local`: [day, blindDown, night], with nightLights as a fourth when the config sets it (below 0: none).
/// `fromHA`: a template row [day, blindDown, night, nightLights, set, setChanged] or what fallbackLevels kept.
/// Home Assistant's value wins where it has one (>= 0), else the local number.
public func effectiveLevels(local: [Double], fromHA: [Double]?) -> [Double] {
    var lv = Array(local.prefix(3))
    if let ov = fromHA { for k in 0..<min(3, ov.count, lv.count) where ov[k] >= 0 { lv[k] = ov[k] } }
    let fromRow = fromHA.flatMap { $0.count > 3 && $0[3] >= 0 ? $0[3] : nil }
    let own = local.count > 3 && local[3] >= 0 ? local[3] : nil
    if let nl = fromRow ?? own { lv.append(nl) }
    return lv
}

/// The nightLights level in a monitor's levels in effect; nil when it has none.
public func nightLightsLevel(_ levels: [Double]) -> Double? { levels.count > 3 && levels[3] >= 0 ? levels[3] : nil }

/// The room lights for one monitor this tick. Home Assistant's answer while it gives one. In the sun fallback
/// a monitor with a nightLights level keeps the last state seen (`last`; off when none was seen), as the blind
/// keeps its last position, so a lit evening does not drop to night during an outage. Every other monitor
/// counts the lights as off there, as before.
public func roomLights(reported: Bool, fromHA: Bool, last: Bool?, hasNightLights: Bool) -> Bool {
    if fromHA { return reported }
    return hasNightLights ? last ?? false : false
}
```

Note: until Task 6 a real template row still has the "set" helper at index 3, so between Tasks 2 and 6 the Mac app would read a monitor's "set" value as its lights-on level. The tests stay green (`effectiveLevels(local: [70, 40, 20], fromHA: [90, -1, 10, -1, 0])` in `DaylitCoreTests` still gives `[90, 40, 10]` because index 3 is −1 there), but do not run the app on Home Assistant with a "set" helper between Task 2 and Task 6; the branch is not merged before Task 17.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd mac && swift test --filter NightLights` → green. Run: `cd mac && swift test` → all green.

- [ ] **Step 5: Commit**

```bash
git add mac/Sources/DaylitCore/Rules.swift mac/Tests/DaylitCoreTests/NightLightsTests.swift
git commit -m "Mac: levels in effect carry the optional lights-on level; lights rule for the sun fallback

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3: Windows core — the same target, levels and fallback rule

No `dotnet` locally: this task is checked by CI only (push, then watch the `windows` job).

**Files:**
- Modify: `windows/Rules.cs` (`Rules.Target`; new `Rules.NightLightsLevel`, `Rules.RoomLights`)
- Modify: `windows/Chart.cs` (`Chart.EffectiveLevels`)
- Create: `windows/tests/NightLightsTests.cs`

- [ ] **Step 1: Write the failing tests**

Create `windows/tests/NightLightsTests.cs`:

```csharp
using Xunit;

namespace Daylit.Tests;

public class NightLightsTargetTests {
    // The spec's example monitor: day 95, blind down 62, night 60, lights on 80.
    static readonly double[] Four = [95, 62, 60, 80];
    static int T(double elev, double pos, bool lights, double light = 1) {
        var t = new Tuning();
        return Rules.Target(Four, pos, lights, t.Fraction(elev), t, elev < t.LightsBoostSunBelow, light);
    }

    /// The target rule before the optional nightLights level, copied as it was: the regression guard.
    static int TargetBefore(double[] v, double pos, bool lights, double sun, Tuning? t = null, bool? boost = null, double light = 1) {
        double daytime = v[1] + (v[0] - v[1]) * pos / 100;
        double x = v[2] + (daytime - v[2]) * Math.Min(sun, light);
        if (lights && (boost ?? sun < 0.3)) x = Math.Max(x, v[2] + (t?.LightsBoost ?? 5));
        return (int)Math.Round(Math.Clamp(x, 0, 100), MidpointRounding.AwayFromZero);
    }

    [Fact]
    public void WithoutNightLightsTheTargetIsExactlyAsBefore() {
        var custom = new Tuning { Brightness = new() { LightsBoost = 12, LightsBoostSunBelow = 4 } };
        double[][] all = [[70, 40, 20], [95, 62, 75], [100, 78, 75], [30, 50, 90], [0, 0, 0], [100, 100, 100]];
        int checkedCount = 0;
        foreach (var t in new[] { new Tuning(), custom })
            foreach (var v in all)
                for (double e = -12; e <= 40; e += 0.5)
                    foreach (var pos in new[] { 0.0, 25, 40, 58, 100 })
                        foreach (var lights in new[] { false, true })
                            foreach (var light in new[] { 0.2, 0.5, 0.8, 1 }) {
                                double sun = t.Fraction(e);
                                bool boost = e < t.LightsBoostSunBelow;
                                Assert.Equal(TargetBefore(v, pos, lights, sun, t, boost, light), Rules.Target(v, pos, lights, sun, t, boost, light));
                                Assert.Equal(TargetBefore(v, pos, lights, sun, t, null, light), Rules.Target(v, pos, lights, sun, t, null, light));
                                checkedCount++;
                            }
        Assert.Equal(2 * 6 * 105 * 5 * 2 * 4, checkedCount);
    }

    [Fact]
    public void LightsOffBlendsTowardNightWithNoBoost() {
        var t = new Tuning();
        for (double e = -10; e <= 20; e += 0.5)
            foreach (var pos in new[] { 0.0, 40, 100 })
                Assert.Equal(TargetBefore([95, 62, 60], pos, false, t.Fraction(e), t, e < t.LightsBoostSunBelow), T(e, pos, false));
        Assert.Equal(60, T(-10, 100, false));   // dark, lights off: night, not night + 5
    }

    [Fact]
    public void LightsOnWithTheSunHighChangeNothing() {
        foreach (var pos in new[] { 0.0, 40, 58, 100 })
            foreach (var light in new[] { 0.3, 0.5, 1 })
                Assert.Equal(T(30, pos, false, light), T(30, pos, true, light));
    }

    [Fact]
    public void LightsOnWithTheSunDownGiveTheLightsOnLevel() {
        foreach (var e in new[] { -3.0, -6, -20 })
            foreach (var pos in new[] { 0.0, 100 })
                Assert.Equal(80, T(e, pos, true));
    }

    [Fact]
    public void TheDuskTransitionHasNoStep() {
        foreach (var pos in new[] { 0.0, 40, 100 })
            foreach (var light in new[] { 0.5, 1 }) {
                int prev = T(-6, pos, true, light);
                for (int i = 1; i <= 260; i++) {   // -6° to 20° in steps of 0.1°
                    int now = T(-6 + i / 10.0, pos, true, light);
                    Assert.True(Math.Abs(now - prev) <= 2, $"pos {pos} light {light} at {-6 + i / 10.0}°");
                    prev = now;
                }
            }
    }

    [Fact]
    public void TheExampleValues() {
        // A cloudy morning: the sun is high but clouds cap daylight at half.
        Assert.Equal(68, T(30, 40, true, 0.5));    // 67.6
        Assert.Equal(71, T(30, 58, true, 0.5));    // 70.57 (the spec rounds this to 70)
        Assert.Equal(70, T(30, 58, true, 0.49));   // 70.36
        Assert.Equal(79, T(30, 100, true, 0.55));  // 79.25
        Assert.Equal(80, T(-10, 100, true));       // a dark evening with the lights on
        // The same cloudy morning before: night 75 kept it at 75 or more.
        Assert.Equal(75, Rules.Target([95, 62, 75], 40, true, 1, new Tuning(), false, 0.5));
    }
}

public class NightLightsLevelsTests {
    [Fact]
    public void HomeAssistantValueWinsWhenZeroOrMore() {
        Assert.Equal(new double[] { 70, 40, 20, 65 }, Chart.EffectiveLevels([70, 40, 20, 50], [-1, -1, -1, 65, -1, 0]));
        Assert.Equal(new double[] { 70, 40, 20, 0 }, Chart.EffectiveLevels([70, 40, 20, 50], [-1, -1, -1, 0, -1, 0]));
        Assert.Equal(new double[] { 70, 40, 20, 50 }, Chart.EffectiveLevels([70, 40, 20, 50], [-1, -1, -1, -1, -1, 0]));
        Assert.Equal(new double[] { 70, 40, 20, 65 }, Chart.EffectiveLevels([70, 40, 20], [-1, -1, -1, 65, -1, 0]));
    }

    [Fact]
    public void WithNoValueThereIsNoNightLights() {
        Assert.Equal(new double[] { 70, 40, 20 }, Chart.EffectiveLevels([70, 40, 20], [-1, -1, -1, -1, -1, 0]));
        Assert.Equal(new double[] { 70, 40, 20 }, Chart.EffectiveLevels([70, 40, 20], null));
        Assert.Equal(new double[] { 70, 40, 20 }, Chart.EffectiveLevels([70, 40, 20, -1], null));
        Assert.Null(Rules.NightLightsLevel([70, 40, 20]));
        Assert.Equal(80, Rules.NightLightsLevel([70, 40, 20, 80]));
    }
}

public class NightLightsFallbackTests {
    [Fact]
    public void HomeAssistantsAnswerIsUsedWhileItGivesOne() {
        foreach (var has in new[] { false, true }) {
            Assert.True(Rules.RoomLights(true, true, false, has));
            Assert.False(Rules.RoomLights(false, true, true, has));
        }
    }

    [Fact]
    public void AMonitorWithNightLightsKeepsTheLastLightsStateWhileHomeAssistantIsDown() {
        Assert.True(Rules.RoomLights(false, false, true, true));
        Assert.False(Rules.RoomLights(false, false, false, true));
        Assert.False(Rules.RoomLights(false, false, null, true));   // none seen yet: off
    }

    [Fact]
    public void AMonitorWithoutNightLightsCountsTheLightsAsOffInTheFallbackAsBefore() =>
        Assert.False(Rules.RoomLights(false, false, true, false));

    [Fact]
    public void ALitEveningDoesNotDropToNightDuringAnOutage() {
        bool lit = Rules.RoomLights(false, false, true, true);
        var t = new Tuning();
        Assert.Equal(80, Rules.Target([95, 62, 60, 80], 100, lit, t.Fraction(-10), t, true));
    }
}
```

- [ ] **Step 2: Implement**

In `windows/Rules.cs`, replace `Rules.Target` with the code below and add the two helpers right after it. Also extend the doc comment above `BlindPosition` / `Target`: `v` is `[day, blindDown, night]`, or with a fourth, nightLights.

```csharp
    public static int Target(double[] v, double pos, bool lights, double sun, Tuning? t = null, bool? boost = null, double light = 1) {
        double daytime = v[1] + (v[0] - v[1]) * pos / 100;
        double share = Math.Min(sun, light);
        double x;
        if (NightLightsLevel(v) is double nl) {
            // A monitor with its own lit-evening level: weak daylight blends toward night with the lights off.
            // With them on it blends toward a point that slides from night (sun high) to nightLights (sun down),
            // so the lamps change nothing in daylight and there is no step at dusk. No boost.
            double anchor = lights ? v[2] * sun + nl * (1 - sun) : v[2];
            x = anchor + (daytime - anchor) * share;
        } else {
            x = v[2] + (daytime - v[2]) * share;
            if (lights && (boost ?? sun < 0.3)) x = Math.Max(x, v[2] + (t?.LightsBoost ?? 5));
        }
        return (int)Math.Round(Math.Clamp(x, 0, 100), MidpointRounding.AwayFromZero);
    }

    /// The nightLights level in a monitor's levels in effect (a fourth number, 0 or more); null when it has none.
    public static double? NightLightsLevel(double[] v) => v.Length > 3 && v[3] >= 0 ? (double?)v[3] : null;

    /// The room lights for one monitor this tick. Home Assistant's answer while it gives one. In the sun fallback
    /// a monitor with a nightLights level keeps the last state seen (`last`; off when none was seen), as the blind
    /// keeps its last position, so a lit evening does not drop to night during an outage. Every other monitor
    /// counts the lights as off there, as before.
    public static bool RoomLights(bool reported, bool fromHa, bool? last, bool hasNightLights) =>
        fromHa ? reported : hasNightLights && (last ?? false);
```

`sun` in `Target` is the elevation's fraction (`Tuning.Fraction`), so it is the spec's `sun`; `share` is the spec's `s`.

In `windows/Chart.cs`, replace `EffectiveLevels` with:

```csharp
    /// The levels in effect: [day, blindDown, night], plus a fourth, nightLights, when the monitor has one.
    /// `local`: [day, blindDown, night], with nightLights as a fourth when the config sets it (below 0: none).
    /// `fromHa`: a template row [day, blindDown, night, nightLights, set, setChanged] or its first four numbers.
    /// Home Assistant's value wins where it has one (>= 0), else the local number.
    public static double[] EffectiveLevels(double[] local, double[]? fromHa) {
        var lv = local.Take(3).ToArray();
        if (fromHa != null) for (int k = 0; k < Math.Min(3, Math.Min(fromHa.Length, lv.Length)); k++) if (fromHa[k] >= 0) lv[k] = fromHa[k];
        double? fromRow = fromHa != null && fromHa.Length > 3 && fromHa[3] >= 0 ? (double?)fromHa[3] : null;
        double? own = local.Length > 3 && local[3] >= 0 ? (double?)local[3] : null;
        return (fromRow ?? own) is double nl ? lv.Append(nl).ToArray() : lv;
    }
```

- [ ] **Step 3: Push and check CI**

```bash
git add windows/Rules.cs windows/Chart.cs windows/tests/NightLightsTests.cs
git commit -m "Windows: target takes an optional night level for when the room lights are on

Co-Authored-By: Claude <noreply@anthropic.com>"
git push
gh run list --branch feature/night-lights --limit 1
gh run watch <id> --exit-status
```

Expected: the `windows` job builds and its tests pass (the new `NightLights*` tests and the old `TargetTests`, `ChartTests`, `SuggestTests`). On a failure: `gh run view <id> --log-failed | head -80`, fix, commit `Windows: fix …`, push again.

---

### Task 4: Mac config — the key, the helper, validation and saving

**Files:**
- Modify: `mac/Sources/DaylitCore/Config.swift`, `mac/Sources/DaylitCore/ConfigEdit.swift`, `mac/Sources/Daylit/Cli.swift`
- Modify: `mac/Tests/DaylitCoreTests/NightLightsTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `mac/Tests/DaylitCoreTests/NightLightsTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd mac && swift test --filter NightLightsConfigTests`
Expected: build FAILS with `value of type 'MonitorConfig' has no member 'nightLights'`.

- [ ] **Step 3: Implement**

`mac/Sources/DaylitCore/Config.swift`, `MonitorHA`: add the property and the init parameter (last, with a default, so every existing call compiles):

```swift
    public var set: String?             // input_number: changing it in HA sets this monitor now, even when the Mac is idle
    public var nightLights: String?     // optional input_number: the level after sunset with the room lights on
    public init(sensor: String? = nil, day: String? = nil, blindDown: String? = nil, night: String? = nil, set: String? = nil,
                nightLights: String? = nil) {
        self.sensor = sensor; self.day = day; self.blindDown = blindDown; self.night = night; self.set = set
        self.nightLights = nightLights
    }
```

`MonitorConfig`: after `night`:

```swift
    public var nightLights: Double?     // optional: after sunset with the room lights on (none: night + the lights boost)
```

`Config.validate()`: replace the per-monitor id list and add the range check after it:

```swift
        for m in monitors ?? [] {
            guard let h = m.homeAssistant else { continue }
            let at = "monitor \"\(m.match)\" homeAssistant."
            ids += [(at + "sensor", h.sensor), (at + "day", h.day), (at + "blindDown", h.blindDown),
                    (at + "night", h.night), (at + "set", h.set), (at + "nightLights", h.nightLights)]
        }
        for m in monitors ?? [] {
            if let v = m.nightLights, !(v.isFinite && (0...100).contains(v)) {
                return "config.json: monitor \"\(m.match)\" nightLights is 0 to 100"
            }
        }
```

`mac/Sources/DaylitCore/ConfigEdit.swift`, `SettingsEdit.Monitor`, after `contrast`:

```swift
        /// The window shows the "Lights on" box for this monitor (a lights entity is set). When false, `nightLights` in the file is kept.
        public var nightLightsEditable = false
        public var nightLights: Int? = nil    // nil = not set: the key is removed
```

`ConfigPatch.apply`, after the contrast block inside the monitors loop:

```swift
            if m.nightLightsEditable {
                if let v = m.nightLights { entry["nightLights"] = clamp(v) } else { entry["nightLights"] = nil }
            }
```

and in its doc comment change "contrast where it has no box" to "contrast and nightLights where they have no box".

`mac/Sources/Daylit/Cli.swift`, `checkConfig()`, inside the `for m in cfg.monitors ?? []` loop, before the `if hit == nil` line:

```swift
            if (m.nightLights != nil || m.homeAssistant?.nightLights != nil) && (src != .homeAssistant || (cfg.homeAssistant?.lights ?? "").isEmpty) {
                notes.append("monitor \"\(m.match)\": nightLights needs homeAssistant.lights; without it the lights count as off")
            }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd mac && swift test --filter NightLightsConfigTests` → 8 tests green. Run: `cd mac && swift test` → all green. Run: `mac/build.sh /tmp/daylit-build` → `Build complete!`, 0 warnings.

- [ ] **Step 5: Commit**

```bash
git add mac/Sources/DaylitCore/Config.swift mac/Sources/DaylitCore/ConfigEdit.swift mac/Sources/Daylit/Cli.swift mac/Tests/DaylitCoreTests/NightLightsTests.swift
git commit -m "Mac: nightLights in the config, locally and as a Home Assistant helper

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 5: Windows config — the same

CI only.

**Files:**
- Modify: `windows/Config.cs`, `windows/Cli.cs`
- Modify: `windows/tests/NightLightsTests.cs`

- [ ] **Step 1: Write the failing tests**

Append to `windows/tests/NightLightsTests.cs`:

```csharp
public class NightLightsConfigTests {
    static string Write(string text) {
        var p = Path.Combine(Path.GetTempPath(), $"daylit-test-{Guid.NewGuid()}.json");
        File.WriteAllText(p, text);
        return p;
    }
    static System.Text.Json.Nodes.JsonObject Json(string s) => (System.Text.Json.Nodes.JsonObject)System.Text.Json.Nodes.JsonNode.Parse(s)!;
    static readonly SettingsEdit.Monitor Dell = new("DELL U2723QE", "U2723QE", "Left", 95, 62, 60);
    const string Original = """{ "monitors": [ { "match": "U2723QE", "night": 60, "nightLights": 80, "control": "ddc", "homeAssistant": { "nightLights": "input_number.lit" } } ] }""";

    [Fact]
    public void LoadsTheLocalLevelAndTheHelper() {
        var (c, err) = Config.Load(Write("""{ "monitors": [ { "match": "Dell", "night": 60, "nightLights": 80, "homeAssistant": { "nightLights": "input_number.lit" } } ] }"""));
        Assert.Null(err);
        Assert.Equal(80, c.Monitors![0].NightLights);
        Assert.Equal("input_number.lit", c.Monitors![0].HomeAssistant!.NightLights);
    }

    [Fact]
    public void WithoutTheKeyThereIsNoLevel() =>
        Assert.Null(Config.Load(Write("""{ "monitors": [ { "match": "Dell", "night": 60 } ] }""")).cfg.Monitors![0].NightLights);

    [Theory]
    [InlineData("-1")]
    [InlineData("101")]
    public void ALevelOutsideZeroToHundredIsAProblem(string v) =>
        Assert.Equal("config.json: monitor \"Dell\" nightLights is 0 to 100",
                     Config.Load(Write($$"""{ "monitors": [ { "match": "Dell", "nightLights": {{v}} } ] }""")).error);

    [Fact]
    public void ZeroAndHundredAreFine() {
        Assert.Null(Config.Load(Write("""{ "monitors": [ { "match": "Dell", "nightLights": 0 } ] }""")).error);
        Assert.Null(Config.Load(Write("""{ "monitors": [ { "match": "Dell", "nightLights": 100 } ] }""")).error);
    }

    [Fact]
    public void AHelperThatIsNotAnEntityIdIsAProblem() =>
        Assert.Equal("config.json: monitor \"Dell\" homeAssistant.nightLights is not an entity id like light.office",
                     Config.Load(Write("""{ "monitors": [ { "match": "Dell", "homeAssistant": { "nightLights": "lit" } } ] }""")).error);

    [Fact]
    public void SettingsSavesTheLevelAndKeepsEveryOtherKey() {
        var m = Json(ConfigPatch.Apply(new SettingsEdit("off", null, null, [Dell with { NightLights = 85, NightLightsEditable = true }]), Original))["monitors"]![0]!;
        Assert.Equal(85, (int)m["nightLights"]!);
        Assert.Equal("ddc", (string)m["control"]!);
        Assert.Equal("input_number.lit", (string)m["homeAssistant"]!["nightLights"]!);
    }

    [Fact]
    public void AnEmptyBoxRemovesTheKey() =>
        Assert.Null(Json(ConfigPatch.Apply(new SettingsEdit("off", null, null, [Dell with { NightLights = null, NightLightsEditable = true }]), Original))["monitors"]![0]!["nightLights"]);

    [Fact]
    public void WithoutTheBoxTheFileKeepsItsLevel() =>
        Assert.Equal(80, (int)Json(ConfigPatch.Apply(new SettingsEdit("off", null, null, [Dell]), Original))["monitors"]![0]!["nightLights"]!);

    [Fact]
    public void AValueOutOfRangeIsClamped() =>
        Assert.Equal(100, (int)Json(ConfigPatch.Apply(new SettingsEdit("off", null, null, [Dell with { NightLights = 140, NightLightsEditable = true }]), Original))["monitors"]![0]!["nightLights"]!);
}
```

- [ ] **Step 2: Implement**

`windows/Config.cs`:

`MonitorHa`, after `Set`:

```csharp
    public string? NightLights { get; set; }  // optional input_number: the level after sunset with the room lights on
```

`MonitorConfig`, after `Night`:

```csharp
    public double? NightLights { get; set; }  // optional: after sunset with the room lights on (none: night + the lights boost)
```

`Config.Validate`: in the per-monitor id list add `(at + "nightLights", mh.NightLights)` after `(at + "set", mh.Set)`, and right after the `foreach (var (key, id) in ids)` loop add:

```csharp
        foreach (var m in c.Monitors ?? [])
            if (m?.NightLights is double nlv && !(double.IsFinite(nlv) && nlv >= 0 && nlv <= 100))
                return $"config.json: monitor \"{m.Match}\" nightLights is 0 to 100";
```

`SettingsEdit.Monitor`: add two optional parameters at the end (so every existing `new(...)` still compiles) and extend its doc comment ("`NightLightsEditable`: the window shows the Lights on box; otherwise `nightLights` in the file is kept. `NightLights` null = not set: the key is removed."):

```csharp
    public sealed record Monitor(string Name, string SuggestedMatch, string Label, int Day, int BlindDown, int Night,
                                 int? Contrast = null, bool ContrastEditable = false,
                                 int? NightLights = null, bool NightLightsEditable = false);
```

`ConfigPatch.Apply`, after the `if (m.ContrastEditable) { ... }` block:

```csharp
            if (m.NightLightsEditable) {
                if (m.NightLights is int lit) entry["nightLights"] = Math.Clamp(lit, 0, 100); else entry.Remove("nightLights");
            }
```

and in its doc comment change "contrast where it has no box" to "contrast and nightLights where they have no box".

`windows/Cli.cs`, `CheckConfig()`: declare `var lightsNotes = new List<string>();` right before `var monitors = (cfg.Monitors ?? []).Select(m => {`, add inside that lambda after the `problems.Add(...)` line:

```csharp
            if ((m.NightLights != null || ha?.NightLights != null) && (cfg.Effective != Source.HomeAssistant || string.IsNullOrWhiteSpace(cfg.HomeAssistant?.Lights)))
                lightsNotes.Add($"monitor \"{m.Match}\": nightLights needs homeAssistant.lights; without it the lights count as off");
```

and after `var notes = new List<string>();` add `notes.AddRange(lightsNotes);`.

- [ ] **Step 3: Push and check CI**

```bash
git add windows/Config.cs windows/Cli.cs windows/tests/NightLightsTests.cs
git commit -m "Windows: nightLights in the config, locally and as a Home Assistant helper

Co-Authored-By: Claude <noreply@anthropic.com>"
git push
gh run list --branch feature/night-lights --limit 1
gh run watch <id> --exit-status
```

Expected: `windows` job green (build and tests).

---

### Task 6: Mac — the Home Assistant row carries `nightLights`

**Files:**
- Modify: `mac/Sources/DaylitCore/HATemplate.swift`, `mac/Sources/DaylitCore/Rules.swift` (`fallbackLevels`, `RemoteSet`)
- Modify: `mac/Tests/DaylitCoreTests/DaylitCoreTests.swift` (row layout), `mac/Tests/DaylitCoreTests/NightLightsTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `mac/Tests/DaylitCoreTests/NightLightsTests.swift`:

```swift
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
```

In `mac/Tests/DaylitCoreTests/DaylitCoreTests.swift`, move the old tests to the new row layout (the "set" helper now sits at indices 4 and 5):

```swift
        XCTAssertEqual(effectiveLevels(local: [70, 40, 20], fromHA: [90, -1, 10, -1, -1, 0]), [90, 40, 10])
```
```swift
        let row: [Double] = [94, 60, 30, -1, 55, 1_700_000_000]
```
```swift
        XCTAssertEqual(RemoteSet(row: [70, 40, 20, -1, 55, 1234]), RemoteSet(value: 55, changed: 1234))
        XCTAssertNil(RemoteSet(row: [70, 40, 20, -1, -1, 0]))      // no set helper
        XCTAssertNil(RemoteSet(row: [70, 40, 20, -1, 55, 0]))      // helper missing in HA
```
and in `testParsesAnswerShape` the answer `"m": {"U": [80, 40, 20, -1, -1, 0]}` and `XCTAssertEqual(s?.m["U"]?.count, 6)`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd mac && swift test 2>&1 | grep -E "error:|Executed"`
Expected: FAIL — the template has no fourth level, `HAState.parse` wants 5 numbers, `RemoteSet` reads index 3, `fallbackLevels` keeps 3.

- [ ] **Step 3: Implement**

`mac/Sources/DaylitCore/HATemplate.swift`:

```swift
    /// Per display UUID: [day, blindDown, night, nightLights, set, setChanged]; -1 = use the local value / no set helper;
    /// setChanged is the set helper's last_changed (Unix seconds).
```
```swift
        guard let s = try? JSONDecoder().decode(HAState.self, from: d), s.m.values.allSatisfy({ $0.count == 6 }) else { return nil }
```
In `build`, keep the helper when filtering ids, include it in the guard and put it fourth in the row:

```swift
        let mons = mons0.map { m in (uuid: m.uuid, ha: m.ha.map { MonitorHA(sensor: ok($0.sensor), day: ok($0.day), blindDown: ok($0.blindDown),
                                                                              night: ok($0.night), set: ok($0.set), nightLights: ok($0.nightLights)) }) }
```
```swift
            guard let h = mon.ha, h.day != nil || h.blindDown != nil || h.night != nil || h.set != nil || h.nightLights != nil else { return nil }
```
```swift
            return "\"\(mon.uuid)\": [\(num(h.day)), \(num(h.blindDown)), \(num(h.night)), \(num(h.nightLights)), \(set)]"
```

`mac/Sources/DaylitCore/Rules.swift`:

```swift
/// The part of a Home Assistant row the sun fallback keeps: [day, blindDown, night, nightLights]. The "set"
/// helper is dropped, so an old remote value is never replayed while Home Assistant is down.
public func fallbackLevels(_ row: [Double]) -> [Double] { Array(row.prefix(4)) }
```
```swift
    /// From the template's per-monitor row [day, blindDown, night, nightLights, set, setChanged]; nil without a helper.
    public init?(row: [Double]?) {
        guard let r = row, r.count == 6, r[4] >= 0, r[5] > 0 else { return nil }
        value = r[4]; changed = r[5]
    }
```

`mac/Sources/Daylit/Suggestions.swift` reads `row[l.rawValue]` for indices 0–2 only, so it needs no change here.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd mac && swift test` → all green. Run: `mac/build.sh /tmp/daylit-build` → 0 warnings.

- [ ] **Step 5: Commit**

```bash
git add mac/Sources/DaylitCore/HATemplate.swift mac/Sources/DaylitCore/Rules.swift mac/Tests/DaylitCoreTests/DaylitCoreTests.swift mac/Tests/DaylitCoreTests/NightLightsTests.swift
git commit -m "Mac: read the lights-on level from Home Assistant, kept through the sun fallback

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 7: Windows — the Home Assistant row carries `NightLights`

CI only. `Sources.cs` and `Displays.cs` are app files (built by the `windows` job, not by the test project).

**Files:**
- Modify: `windows/Rules.cs` (`HaTemplate.Build`), `windows/Sources.cs` (`Inputs` doc, `HAClient.State`), `windows/Displays.cs` (`Mon`), `windows/App.cs` (`SunInputs`)
- Modify: `windows/tests/RulesTests.cs` (row layout), `windows/tests/NightLightsTests.cs`

- [ ] **Step 1: Write the failing tests**

Append to `windows/tests/NightLightsTests.cs`:

```csharp
public class NightLightsHomeAssistantTests {
    [Fact]
    public void TheTemplateAsksForTheHelperAsTheFourthNumber() =>
        Assert.Contains("[-1, -1, -1, {{ states('input_number.lit') | float(-1) }}, -1, 0]",
                        HaTemplate.Build(new HaConfig { Url = "http://x" }, [new MonitorHa { NightLights = "input_number.lit" }]));

    [Fact]
    public void AMonitorWithoutTheHelperGetsMinusOneThere() =>
        Assert.Contains("[{{ states('input_number.d') | float(-1) }}, -1, -1, -1, -1, 0]",
                        HaTemplate.Build(new HaConfig { Url = "http://x" }, [new MonitorHa { Day = "input_number.d" }]));

    [Fact]
    public void ABadHelperIdIsDroppedFromTheTemplate() =>
        Assert.DoesNotContain("input_number.x", HaTemplate.Build(new HaConfig { Url = "http://x" }, [new MonitorHa { NightLights = "input_number.x'}}" }]));
}
```

In `windows/tests/RulesTests.cs`, `TemplateTests.EntitiesAppearOneRowPerMonitor`, the row of a monitor without entities is now six numbers:

```csharp
        Assert.Contains("[-1, -1, -1, -1, -1, 0]", t);   // a monitor without HA entities still gets its row
```

- [ ] **Step 2: Implement**

`windows/Rules.cs`, `HaTemplate.Build`:

```csharp
        var monitors = monitors0.Select(m => m == null ? null : new MonitorHa {
            Sensor = Ok(m.Sensor), Day = Ok(m.Day), BlindDown = Ok(m.BlindDown), Night = Ok(m.Night), Set = Ok(m.Set), NightLights = Ok(m.NightLights) });
```
```csharp
            return $"[{Num(e?.Day, -1)}, {Num(e?.BlindDown, -1)}, {Num(e?.Night, -1)}, {Num(e?.NightLights, -1)}, {set}]";
```
and its doc comment: "One row per monitor, in order: [day, blindDown, night, nightLights, set, setChanged]; -1 marks …".

`windows/Displays.cs`, class `Mon`:

```csharp
    public double[]? HaLevels;                 // last levels from Home Assistant (with nightLights when set), for the sun fallback
    public double Day => Spec?.Day ?? Config.DefaultDay;
    public double BlindDown => Spec?.BlindDown ?? Config.DefaultBlindDown;
    public double Night => Spec?.Night ?? Config.DefaultNight;
    public double? NightLights => Spec?.NightLights;
    /// The local levels: [day, blindDown, night], with nightLights as a fourth when the config sets it.
    public double[] LocalLevels => NightLights is double nl ? new[] { Day, BlindDown, Night, nl } : new[] { Day, BlindDown, Night };
```

`windows/Sources.cs`:

```csharp
/// Inputs of one automatic decision. Levels: per monitor [day, blindDown, night], plus nightLights when it has one.
```
```csharp
    /// Per monitor: Home Assistant's own [day, blindDown, night, nightLights] (-1 where it has no value), for the Settings
    /// chart; null when these inputs did not come from Home Assistant.
```
In `HAClient.State` replace the row check, the levels, the remote and `FromHa`:

```csharp
            if (a == null || a.m == null || a.m.Length != mons.Count || a.m.Any(v => v == null || v.Length != 6)) {
                LastError = "Unexpected answer from Home Assistant"; Transient = false; return null;
            }
            // Local numbers wherever HA has no value; nightLights as a fourth when either has one.
            var levels = mons.Select((m, i) => Chart.EffectiveLevels(m.LocalLevels, a.m[i])).ToArray();
            var remote = a.m.Select(v => v[4] >= 0 && v[5] > 0 ? ((double, double)?)(v[4], v[5]) : null).ToArray();
            return new Inputs(a.elev, a.pos, a.lights, a.bri, a.sat, levels, a.auto, !string.IsNullOrWhiteSpace(h.Cover)) { Remote = remote, Light = a.light, LightAge = a.lightAge, LightUnit = a.lightUnit, FromHa = a.m.Select(v => v[..4]).ToArray() };
```

`windows/App.cs`, `SunInputs`: the local levels include `nightLights`:

```csharp
                          mons.Select(m => (keep ? m.HaLevels : null) ?? m.LocalLevels).ToArray(), null,
```

(`Mon.HaLevels` already stores the resolved `s.Levels[i]`, which now has the fourth level when there is one.)

- [ ] **Step 3: Push and check CI**

```bash
git add windows/Rules.cs windows/Sources.cs windows/Displays.cs windows/App.cs windows/tests/RulesTests.cs windows/tests/NightLightsTests.cs
git commit -m "Windows: read the lights-on level from Home Assistant, kept through the sun fallback

Co-Authored-By: Claude <noreply@anthropic.com>"
git push
gh run list --branch feature/night-lights --limit 1
gh run watch <id> --exit-status
```

Expected: `windows` job green.

---

### Task 8: Mac app — use the level and the last lights state

No new unit test (the rules are tested in Tasks 1, 2 and 6); this task wires them. Verified by build and by the full test run.

**Files:**
- Modify: `mac/Sources/Daylit/Displays.swift`, `mac/Sources/Daylit/Model.swift`, `mac/Sources/Daylit/Suggestions.swift`, `mac/Sources/Daylit/BrightnessChart.swift` (`LiveInputs` only)

- [ ] **Step 1: `Mon` gets the level**

`mac/Sources/Daylit/Displays.swift`, struct `Mon`, after `contrast`:

```swift
    var nightLights: Double? = nil   // config: the level after sunset with the room lights on (nil: night + the lights boost)
```

`mac/Sources/Daylit/Model.swift`, `redetect()`, after `m.contrast = cfg?.contrast`:

```swift
            m.nightLights = cfg?.nightLights
```

- [ ] **Step 2: Levels of a monitor include it**

`mac/Sources/Daylit/Suggestions.swift`:

```swift
    func levels(of m: Mon, _ inp: Inputs) -> [Double] {
        effectiveLevels(local: [m.day, m.blindDown, m.night] + (m.nightLights.map { [$0] } ?? []), fromHA: inp.levels[m.uuid])
    }
```

- [ ] **Step 3: Remember the lights and hand them to the fallback**

`mac/Sources/Daylit/Model.swift`:

In `struct Inputs`, after `lightRatio`:

```swift
        var lastLights: Bool? = nil     // sun fallback: the room lights Home Assistant last gave (nil: none seen)
```

After `var lastHAPos: Double?`:

```swift
    /// The room lights Home Assistant last gave: a monitor with a nightLights level keeps them while it is down.
    var lastHALights: Bool?
```

In `inputs()` → `fromSun`, right after `var i = Inputs(...)`:

```swift
            i.lastLights = keep ? lastHALights : nil   // a sun-only config has no lights
```

In the `.success` branch, after `lastHAPos = ha.cover != nil ? pos : nil`:

```swift
                lastHALights = s.lights
```

- [ ] **Step 4: The tick uses the per-monitor lights and the level**

In `tick()`, replace `ownTarget` with:

```swift
        /// The room lights for this monitor: in the sun fallback only one with a nightLights level keeps the last state.
        func lightsFor(_ m: Mon) -> Bool {
            roomLights(reported: inp.lights, fromHA: inp.fromHA, last: inp.lastLights, hasNightLights: nightLightsLevel(levels(of: m, inp)) != nil)
        }
        func ownTarget(_ m: Mon) -> Int {
            let lv = levels(of: m, inp)
            return target(day: lv[0], blindDown: lv[1], night: lv[2], elev: inp.elev, pos: inp.pos, lights: lightsFor(m),
                          tuning: config.tuned, light: inp.light, nightLights: nightLightsLevel(lv))
        }
```

In the `Suggest.makeSample(...)` call, change `lights: inp.lights` to `lights: lightsFor(m)`.

`LiveInputs` (in `mac/Sources/Daylit/BrightnessChart.swift`): add the field and compare it:

```swift
    var lightsUsed: [String: Bool] = [:]   // the room lights each monitor's target used (the sun fallback keeps them for nightLights)
    static func == (a: LiveInputs, b: LiveInputs) -> Bool {
        a.lightsUsed == b.lightsUsed && a.elev == b.elev && a.linked == b.linked && a.leader == b.leader && a.applying == b.applying && a.pos == b.pos && a.lights == b.lights && a.light == b.light && a.levels == b.levels
            && a.offsets.mapValues { "\($0.value) \($0.weight)" } == b.offsets.mapValues { "\($0.value) \($0.weight)" }
    }
```

Back in `tick()`, the `LiveInputs` it builds:

```swift
        let next = LiveInputs(elev: inp.elev, pos: inp.hasBlind ? inp.pos : nil, lights: inp.lights, light: inp.light, levels: inp.levels,
                              offsets: offs, linked: linkedNow, leader: leaderLabel, applying: auto && here,
                              lightsUsed: Dictionary(mons.map { ($0.uuid, lightsFor($0)) }, uniquingKeysWith: { a, _ in a }))
```

The published sensor's `lights` attribute keeps `inp.lights` (what Home Assistant reports); the light/dark rule is not touched.

- [ ] **Step 5: Build and test**

Run: `mac/build.sh /tmp/daylit-build` → `Build complete!`, 0 warnings.
Run: `cd mac && swift test` → all green.

- [ ] **Step 6: Commit**

```bash
git add mac/Sources/Daylit/Displays.swift mac/Sources/Daylit/Model.swift mac/Sources/Daylit/Suggestions.swift mac/Sources/Daylit/BrightnessChart.swift
git commit -m "Mac: the tick uses the lights-on level and keeps the lights through an outage for it

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 9: Windows app — the same wiring

CI only.

**Files:**
- Modify: `windows/App.cs`, `windows/Chart.cs` (`LiveInputs`)

- [ ] **Step 1: `LiveInputs` carries the lights each monitor used**

`windows/Chart.cs`: add a last optional member and mention it in the doc comment above the record ("LightsUsed: the room lights each monitor's target used, per monitor key"):

```csharp
sealed record LiveInputs(double? Elev = null, double? Pos = null, bool Lights = false, double Light = 1,
                         IReadOnlyDictionary<string, double[]>? Levels = null,
                         IReadOnlyDictionary<string, (int Value, double Weight)>? Offsets = null,
                         IReadOnlyDictionary<string, int>? Linked = null, string Leader = "", bool Applying = true,
                         IReadOnlyDictionary<string, bool>? LightsUsed = null);
```

- [ ] **Step 2: Remember the lights**

`windows/App.cs`, after `double? lastHaPos;`:

```csharp
    bool? lastHaLights;   // the room lights Home Assistant last gave: a monitor with nightLights keeps them while it is down
```

In `TickOnce`, in the `if (!haDown && Source == Source.HomeAssistant && s != null) { … }` block, after `lastHaPos = s.HasBlind ? s.Pos : null;`:

```csharp
            lastHaLights = s.Lights;
```

- [ ] **Step 3: Per-monitor lights in the loop**

Before the `foreach (int i in order)` loop, next to `linkedNow`:

```csharp
        var lightsUsed = new Dictionary<string, bool>();   // the room lights each monitor's target used (for the Settings chart)
```

Inside the loop, replace the `int target = Rules.Target(...)` line with:

```csharp
            // In the sun fallback only a monitor with a nightLights level keeps the last lights state; the others count them as off.
            bool roomLit = Rules.RoomLights(s.Lights, !haDown && Source == Source.HomeAssistant,
                                            Source == Source.HomeAssistant ? lastHaLights : null, Rules.NightLightsLevel(s.Levels[i]) != null);
            lightsUsed[m.Key] = roomLit;
            int target = Rules.Target(s.Levels[i], s.Pos, roomLit, sun, Cfg.Tuned, boost, light);
```

In the `Suggest.MakeSample(...)` call, replace `s.Lights` with `roomLit`.

The `Live = new LiveInputs(...)` call gets the map as a trailing named argument:

```csharp
        Live = new LiveInputs(s.Elev, s.HasBlind ? s.Pos : null, s.Lights, light, haLevels, offs, linkedNow,
                              li >= 0 ? mons[li].Label : "", AutoOn && here, LightsUsed: lightsUsed);
```

Publish and `UpdateLook` keep `s.Lights`.

- [ ] **Step 4: Push and check CI**

```bash
git add windows/App.cs windows/Chart.cs
git commit -m "Windows: the tick uses the lights-on level and keeps the lights through an outage for it

Co-Authored-By: Claude <noreply@anthropic.com>"
git push
gh run list --branch feature/night-lights --limit 1
gh run watch <id> --exit-status
```

Expected: `windows` job green.

---

### Task 10: Mac suggestions — no sample while the four-level rule decides; snapshot includes the level

**Files:**
- Modify: `mac/Sources/DaylitCore/Suggest.swift`, `mac/Sources/Daylit/Suggestions.swift`
- Modify: `mac/Tests/DaylitCoreTests/NightLightsTests.swift`

- [ ] **Step 1: Write the failing tests**

Append:

```swift
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd mac && swift test --filter NightLightsSuggestTests`
Expected: FAIL — `makeSample` returns nil for four levels (`levels.count == 3`), `fit` returns the levels unchanged, `decode` drops four-level samples.

- [ ] **Step 3: Implement**

`mac/Sources/DaylitCore/Suggest.swift`:

- `Sample.levels` comment: `// [day, blindDown, night] in effect then, plus nightLights when the monitor has one`
- `fit`: `guard n > 0, levels.count >= 3 else { return levels }   // a fourth level (nightLights) is kept as it is`
- `rerun`:

```swift
        target(day: l[0], blindDown: l[1], night: l[2], elev: x.elev, pos: x.p * 100, lights: x.lights, tuning: tuning, light: x.s,
               nightLights: nightLightsLevel(l))
```

- `suggestion`: `guard (3...4).contains(levels.count), steps.count == 3 else { return nil }`
- `makeSample`:

```swift
        guard (3...4).contains(levels.count), levels.allSatisfy(\.isFinite), elev.isFinite, pos.isFinite, light.isFinite,
              (1...99).contains(chosen), (1...99).contains(auto) else { return nil }
        // With nightLights, lights on and the sun not fully up, the four-level rule decides: the three-level fit would be wrong.
        if nightLightsLevel(levels) != nil && lights && daylightFraction(elevation: elev, tuning: tuning) < 1 { return nil }
        if boostDecides(levels: levels, elev: elev, pos: pos, lights: lights, tuning: tuning, light: light) { return nil }
```

  (`boostDecides` already returns false for four levels: such a monitor has no boost.) Add "a monitor with nightLights while its lights are on and the sun is not fully up" to `makeSample`'s doc comment.
- `decode`: `return f.samples.filter { (3...4).contains($0.levels.count) }` and its comment: "Entries without three or four levels are skipped."

`mac/Sources/Daylit/Suggestions.swift`, `haLevelsUnavailable`, before `return false`:

```swift
        // The nightLights helper is part of the levels snapshot too (row index 3).
        if source == .homeAssistant, let e = m.ha?.nightLights, Config.isEntityId(e) {
            guard inp.fromHA, let row = inp.levels[m.uuid], row.count > 3, row[3] >= 0 else { return true }
        }
```

Applying a suggestion still writes only `day` / `blindDown` / `night` (`Level` has three cases); `nightLights` is never proposed (fitting it is a follow-up).

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd mac && swift test` → all green (the old `Suggest*` tests unchanged). Run: `mac/build.sh /tmp/daylit-build` → 0 warnings.

- [ ] **Step 5: Commit**

```bash
git add mac/Sources/DaylitCore/Suggest.swift mac/Sources/Daylit/Suggestions.swift mac/Tests/DaylitCoreTests/NightLightsTests.swift
git commit -m "Mac: suggestions skip lit ticks the lights-on level decides, and track that level

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 11: Windows suggestions — the same

CI only.

**Files:**
- Modify: `windows/Suggest.cs`, `windows/Suggestions.cs`
- Modify: `windows/tests/NightLightsTests.cs`

- [ ] **Step 1: Write the failing tests**

Append:

```csharp
public class NightLightsSuggestTests {
    static readonly double[] Four = [95, 62, 60, 80];
    static Sample? Make(double elev, bool lights, double[] levels) =>
        Suggest.MakeSample("m", 70, 75, elev, 40, lights, 1, levels, new Tuning(), 1000, new SampleContext());

    [Theory]
    [InlineData(-10.0)]
    [InlineData(0.0)]
    [InlineData(5.0)]
    [InlineData(11.9)]
    public void NoSampleWhileTheLightsAreOnAndTheSunIsNotFullyUp(double elev) => Assert.Null(Make(elev, true, Four));

    [Fact]
    public void SamplesWithTheLightsOffOrTheSunFullyUp() {
        Assert.Equal(Four, Make(5, false, Four)!.Levels);
        Assert.Equal(Four, Make(12, true, Four)!.Levels);
    }

    [Fact]
    public void AMonitorWithoutNightLightsStillRecordsThoseTicks() =>
        Assert.NotNull(Make(5, true, [95, 62, 60]));   // at 5° the boost no longer applies, so the three-level rule decides

    [Fact]
    public void ChangingNightLightsMakesOlderSamplesStale() {
        var x = Make(30, false, Four)!;
        Assert.Empty(Suggest.DropStale([x], new Dictionary<string, double[]> { ["m"] = [95, 62, 60, 85] }));
        Assert.Empty(Suggest.DropStale([x], new Dictionary<string, double[]> { ["m"] = [95, 62, 60] }));
        Assert.Single(Suggest.DropStale([x], new Dictionary<string, double[]> { ["m"] = Four }));
        var r = new Recorder();
        r.HandChanged("m", x);
        Assert.Null(r.Settle("m", true, [95, 62, 60, 85], x.At + 400));
    }

    [Fact]
    public void TheFitKeepsNightLightsAsItIs() {
        var samples = Enumerable.Range(0, 6).Select(i => new Sample("m", 55, 62, 1, 0, 30, false, Four, i * 86400.0)).ToList();
        var fitted = Suggest.Fit(samples, Four, [Level.BlindDown]);
        Assert.Equal(4, fitted.Length);
        Assert.Equal(80, fitted[3]);
        Assert.Equal(56, fitted[1], 2);   // (6 · 55 + 62) / 7
    }

    [Fact]
    public void FourLevelSamplesSurviveTheFile() {
        var x = Make(30, false, Four)!;
        Assert.Equal(new[] { x }, Suggest.Decode(Suggest.Encode([x])));
    }
}
```

- [ ] **Step 2: Implement**

`windows/Suggest.cs`:

- `Sample` doc: "Levels: [day, blindDown, night] in effect then, plus nightLights when the monitor has one; At: Unix seconds."
- `Fit`: `if (n == 0 || levels.Length < 3) return (double[])levels.Clone();   // a fourth level (nightLights) is kept as it is`
- `Rerun`: pass the elevation's fraction as `sun` and the sample's capped share as `light`, so the four-level rule sees the real `sun` (for three levels `Min(sun, light)` is `S` as before, since `S` is never above the fraction):

```csharp
    public static int Rerun(Sample x, double[] levels, Tuning t) =>
        Rules.Target(levels, x.P * 100, x.Lights, t.Fraction(x.Elev), t, x.Elev < t.LightsBoostSunBelow, x.S);
```

- `SuggestionFor`: `if (levels.Length is < 3 or > 4 || steps.Length != 3) return null;`
- `MakeSample`:

```csharp
        if (levels.Length is < 3 or > 4 || !levels.All(double.IsFinite) || !double.IsFinite(elev) || !double.IsFinite(pos) || !double.IsFinite(light) ||
            chosen < 1 || chosen > 99 || auto < 1 || auto > 99) return null;
        // With nightLights, lights on and the sun not fully up, the four-level rule decides: the three-level fit would be wrong.
        if (Rules.NightLightsLevel(levels) != null && lights && t.Fraction(elev) < 1) return null;
        if (BoostDecides(levels, elev, pos, lights, t, light)) return null;
```

- `Decode`: `x.Levels is { Length: 3 or 4 }` and its comment "Entries without three or four levels are skipped."
- `Storable`: `x.Levels is { Length: 3 or 4 } && x.Levels.All(double.IsFinite)`

`windows/Suggestions.cs`, `HaLevelsUnavailable`:

```csharp
    bool HaLevelsUnavailable(Mon m, int i, Inputs s, bool haDown) =>
        LevelText.All.Any(l => HaEntity(l, m) != null && !HaLevelAvailable(l, i, s, haDown))
        // The nightLights helper is part of the levels snapshot too (row index 3).
        || (Source == Source.HomeAssistant && m.Spec?.HomeAssistant?.NightLights is { } nlEntity && Config.IsEntityId(nlEntity)
            && !(!haDown && s.FromHa is { } nlRaw && i < nlRaw.Length && nlRaw[i].Length > 3 && nlRaw[i][3] >= 0));
```

- [ ] **Step 3: Push and check CI**

```bash
git add windows/Suggest.cs windows/Suggestions.cs windows/tests/NightLightsTests.cs
git commit -m "Windows: suggestions skip lit ticks the lights-on level decides, and track that level

Co-Authored-By: Claude <noreply@anthropic.com>"
git push
gh run list --branch feature/night-lights --limit 1
gh run watch <id> --exit-status
```

Expected: `windows` job green (the old `SuggestTests` fixtures are three-level and unchanged).

---

### Task 12: Mac Settings — the optional **Lights on** row

**Files:**
- Modify: `mac/Sources/Daylit/Settings.swift`

- [ ] **Step 1: The draft keeps the typed text**

`MonitorDraft`, after `contrast`:

```swift
    var nightLights = ""           // "Lights on": empty = not set (night + the room-lights boost)
```

`load()`: the `MonitorDraft(...)` call ends with

```swift
                                contrastApplies: mon.control == .ddc, contrast: cfg?.contrast.map { Self.fmt($0) } ?? "",
                                nightLights: cfg?.nightLights.map { Self.fmt($0) } ?? "")
```

- [ ] **Step 2: The row, shown only with a lights entity**

Above `func caption(_:)` add:

```swift
    /// The "Lights on" row shows only with a lights entity: without one the lights count as off.
    var showsNightLights: Bool { source == "homeAssistant" && !lights.trimmingCharacters(in: .whitespaces).isEmpty }
    static let nightLightsHelp = "After sunset with the room lights on. Empty keeps Night plus the room-lights boost."
```

In `displaysPane`, right after `level("Night", "moon", $d.night)`:

```swift
                    if showsNightLights {
                        LabeledContent {
                            HStack(spacing: 6) {
                                TextField("Lights on", text: $d.nightLights, prompt: Text("Not set"))
                                    .labelsHidden().multilineTextAlignment(.trailing).frame(width: 64)
                                    .help(Self.nightLightsHelp)
                                Text("%").foregroundStyle(.secondary).frame(width: 16, alignment: .leading)
                            }
                        } label: { Row("Lights on", "lightbulb") }
                    }
```

In `caption(_:)`, after the first line:

```swift
        if showsNightLights { s += " Lights on: after sunset with the room lights on; empty keeps Night plus the room-lights boost." }
```

- [ ] **Step 3: Save it like the other levels, keeping every other key**

In `edit()`, inside `for d in monitors`, after the contrast block:

```swift
            if showsNightLights {
                // The same rule as contrast: 0 to 100, or empty for none.
                let (ok, v) = ContrastRule.parseField(d.nightLights)
                if !ok { error = "Lights on for \(d.label) is 0 to 100, or empty to keep Night plus the room-lights boost."; return nil }
                me.nightLightsEditable = true; me.nightLights = v
            }
```

`ConfigPatch.apply` (Task 4) writes or removes the key and keeps everything else; when the row is hidden the file's value stays.

- [ ] **Step 4: Build, test, look**

Run: `mac/build.sh /tmp/daylit-build` → 0 warnings. Run: `cd mac && swift test` → green.
Run: `/tmp/daylit-build/Daylit.app/Contents/MacOS/Daylit --render-snapshots /tmp/daylit-snaps` and open `/tmp/daylit-snaps/settings-displays-light.png`: the Studio Display card shows **Lights on · Not set %** under Night and the caption ends with the Lights on sentence (the snapshot config has `"lights": "light.office"`). Local renders differ slightly from CI's, so do not commit them.

- [ ] **Step 5: Commit and push**

```bash
git add mac/Sources/Daylit/Settings.swift
git commit -m "Mac: optional Lights on level in Settings when a lights entity is set

Co-Authored-By: Claude <noreply@anthropic.com>"
git push
```

Expected on CI: the macOS job fails only at *UI snapshots* with `settings-displays-dark.png` / `settings-displays-light.png` changed (re-recorded in Task 15).

---

### Task 13: Windows Settings — the same row

CI only.

**Files:**
- Modify: `windows/Settings.cs`

- [ ] **Step 1: A reusable optional-number row**

Replace `static FrameworkElement Contrast(TextBox box) { … }` with a general version and a one-line `Contrast` (the contrast row renders exactly as before):

```csharp
    /// A box for an optional 0–100 number: empty shows "Not set" in grey and leaves the key out of config.json.
    static FrameworkElement OptionalNumber(string title, TextBox box, string help) {
        box.TextAlignment = TextAlignment.Right;
        var hint = new TextBlock { Text = "Not set", Opacity = 0.45, IsHitTestVisible = false, HorizontalAlignment = HorizontalAlignment.Right,
                                   VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 12, 0),
                                   Visibility = box.Text == "" ? Visibility.Visible : Visibility.Collapsed };
        box.TextChanged += (_, _) => hint.Visibility = box.Text == "" ? Visibility.Visible : Visibility.Collapsed;
        System.Windows.Automation.AutomationProperties.SetName(box, title);
        System.Windows.Automation.AutomationProperties.SetHelpText(box, help);
        box.ToolTip = help;
        var cell = new Grid { Width = 90, Children = { box, hint } };
        var g = new Grid { Margin = new Thickness(0, 4, 0, 4) };
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(150) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.ColumnDefinitions.Add(new ColumnDefinition());
        var l = new TextBlock { Text = title, VerticalAlignment = VerticalAlignment.Center };
        var unit = new TextBlock { Text = "%", VerticalAlignment = VerticalAlignment.Center, Opacity = 0.75, Margin = new Thickness(8, 0, 0, 0) };
        Grid.SetColumn(cell, 1); Grid.SetColumn(unit, 2);
        g.Children.Add(l); g.Children.Add(cell); g.Children.Add(unit);
        return g;
    }

    /// The contrast box: empty leaves it to the monitor.
    static FrameworkElement Contrast(TextBox box) => OptionalNumber("Contrast", box, "0 to 100; empty leaves it to the monitor");

    const string NightLightsHelp = "After sunset with the room lights on. Empty keeps Night plus the room-lights boost.";
    /// The "Lights on" row shows only with a lights entity: without one the lights count as off.
    bool ShowsNightLights => SourceTag == "homeAssistant" && lights.Text.Trim() != "";
```

(The contrast box gains a tooltip with its existing help text; that is not visible in the snapshots.)

- [ ] **Step 2: The row in each monitor card**

`rows` gets two more members:

```csharp
    readonly List<(Mon mon, TextBox label, Slider day, Slider blind, Slider night, TextBlock now, TextBlock caption, bool haLevels, TextBox? contrast,
                   TextBox nightLights, FrameworkElement nightLightsRow)> rows = new();
```

In `Load()`, inside `foreach (var m in external)`, after the `contrast` box:

```csharp
            var nightLights = new TextBox { Text = spec?.NightLights is double nlv ? Fmt(nlv) : "" };
            var nightLightsRow = OptionalNumber("Lights on", nightLights, NightLightsHelp);
            rows.Add((m, label, day, blind, night, now, caption, haLevels, contrast, nightLights, nightLightsRow));
            var card = new List<UIElement> { Field("Name", label), Level("Day", day), Level("Blind closed", blind), Level("Night", night), nightLightsRow };
```

(replacing the old `rows.Add(...)` and `var card = ...` lines).

In the constructor, next to `cover.TextChanged += …`:

```csharp
        lights.TextChanged += (_, _) => Refresh();   // the Lights on rows come and go with the lights entity
```

In `Refresh()`, inside `foreach (var r in rows)`, first line:

```csharp
            r.nightLightsRow.Visibility = ShowsNightLights ? Visibility.Visible : Visibility.Collapsed;
```

and before `r.caption.Text = text;`:

```csharp
            if (ShowsNightLights) text += " Lights on: after sunset with the room lights on; empty keeps Night plus the room-lights boost.";
```

- [ ] **Step 3: Save**

In `Save()`, inside `foreach (var r in rows)`, after the contrast block, and the `mons.Add` call:

```csharp
            int? lit = null;
            if (ShowsNightLights) {
                // The same rule as contrast: 0 to 100, or empty for none.
                var (litOk, litValue) = ContrastRule.ParseField(r.nightLights.Text);
                if (!litOk) { Say($"Lights on for {r.label.Text} is 0 to 100, or empty to keep Night plus the room-lights boost.", true); return; }
                lit = litValue;
            }
            mons.Add(new SettingsEdit.Monitor(r.mon.D.Friendly, ConfigPatch.SuggestMatch(r.mon.D.Friendly), r.label.Text,
                                              (int)r.day.Value, (int)r.blind.Value, (int)r.night.Value, contrast, r.contrast != null,
                                              lit, ShowsNightLights));
```

- [ ] **Step 4: Push and check CI**

```bash
git add windows/Settings.cs
git commit -m "Windows: optional Lights on level in Settings when a lights entity is set

Co-Authored-By: Claude <noreply@anthropic.com>"
git push
gh run list --branch feature/night-lights --limit 1
gh run watch <id> --exit-status
```

Expected: Windows build and tests green; the Windows job fails only at *UI snapshots* with `settings-displays-*` changed (the macOS job too, since Task 12).

---

### Task 14: The chart — "How Daylit decides" with the lights-on level

The chart's two lines are drawn with the lights off (`level(_:elev:pos:)` has no lights term), and a lights-off monitor with `nightLights` blends exactly as before (Task 1), so the lines and every `curve-*` snapshot stay as they are. Only the decision row needs the level and the per-monitor lights.

**Files:**
- Modify: `mac/Sources/DaylitCore/Chart.swift` (`explain`), `mac/Sources/Daylit/BrightnessChart.swift`, `mac/Sources/Daylit/Settings.swift`
- Modify: `windows/Chart.cs` (`Explain`), `windows/BrightnessChart.cs`, `windows/Settings.cs`
- Modify: `mac/Tests/DaylitCoreTests/NightLightsTests.swift`, `windows/tests/NightLightsTests.cs`

- [ ] **Step 1: Write the failing Mac tests**

Append:

```swift
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
```

Run: `cd mac && swift test --filter NightLightsExplainTests` → build FAILS (`extra argument 'nightLights' in call`).

- [ ] **Step 2: Mac `explain`**

`mac/Sources/DaylitCore/Chart.swift`: add `nightLights: Double? = nil` as the last parameter of `explain`, pass it to `target`, and branch the *Lights* step:

```swift
public func explain(day: Double, blindDown: Double, night: Double, elev: Double, pos: Double?, lights: Bool,
                    tuning t: Tuning = Tuning(), light: Double = 1, offset: Int? = nil, offsetWeight w: Double = 1,
                    linked: Int? = nil, leader: String = "", applying: Bool = true, nightLights: Double? = nil) -> Decision {
    let p = pos ?? 100
    let base = target(day: day, blindDown: blindDown, night: night, elev: elev, pos: p, lights: lights, tuning: t, light: light,
                      nightLights: nightLights)
```
```swift
    if nightLights != nil {
        // Its own lit-evening level: the lights count whenever the sun is not fully up, with no boost.
        let moved = lights && base != Int(min(max(blended, 0), 100).rounded())
        steps.append(DecisionStep("Lights", moved ? "on → \(base)" : lights ? "on, no effect now" : sunShare < 1 ? "off" : "no effect by day"))
    } else {
        let lifted = lights && elev < t.lightsBoostSunBelow && Double(base) > blended.rounded()
        steps.append(DecisionStep("Lights", lifted ? "on → \(base)" : lights ? "on, no effect now" : elev < t.lightsBoostSunBelow ? "off" : "no effect by day"))
    }
```

(the `else` branch is the two existing lines, unchanged).

- [ ] **Step 3: Mac chart wiring**

`mac/Sources/Daylit/BrightnessChart.swift`:

```swift
struct ChartMonitor: Identifiable, Equatable {
    let id: String              // display uuid
    let label: String
    let day, blindDown, night: Double
    var nightLights: Double? = nil   // the level after sunset with the room lights on, when set
}
```
```swift
    func levels(_ m: ChartMonitor) -> [Double] {
        effectiveLevels(local: [m.day, m.blindDown, m.night] + (m.nightLights.map { [$0] } ?? []), fromHA: live?.levels[m.id])
    }
```
In `decision(_:)`:

```swift
        return explain(day: l[0], blindDown: l[1], night: l[2], elev: elev, pos: hasBlind ? (live?.pos ?? 100) : nil,
                       lights: live?.lightsUsed[m.id] ?? live?.lights ?? false, tuning: tuning, light: live?.light ?? 1, offset: o?.value,
                       offsetWeight: o?.weight ?? 1, linked: live?.linked[m.id], leader: live?.leader ?? "", applying: live?.applying ?? true,
                       nightLights: nightLightsLevel(l))
```

`mac/Sources/Daylit/Settings.swift`, next to `showsNightLights`:

```swift
    /// The typed "Lights on" level, while its row shows; nil when empty or not a level.
    func nightLightsValue(_ d: MonitorDraft) -> Double? {
        showsNightLights ? ContrastRule.parseField(d.nightLights).value.map(Double.init) : nil
    }
```

and in `brightnessChart`, the `ChartMonitor(...)` gets `nightLights: nightLightsValue($0)`:

```swift
                               monitors: monitors.map { ChartMonitor(id: $0.id, label: $0.label.isEmpty ? $0.name : $0.label, day: $0.day, blindDown: $0.blindDown, night: $0.night,
                                                                    nightLights: nightLightsValue($0)) },
```

Run: `cd mac && swift test` → green; `mac/build.sh /tmp/daylit-build` → 0 warnings.

- [ ] **Step 4: Windows tests**

Append to `windows/tests/NightLightsTests.cs`:

```csharp
public class NightLightsExplainTests {
    [Fact]
    public void TheLightsStepShowsTheLightsOnLevel() {
        var d = Chart.Explain(95, 62, 60, -10, 100, true, nightLights: 80);
        Assert.Equal(80, d.Level);
        Assert.Equal("on → 80", d.Steps.First(s => s.Title == "Lights").Value);
    }

    [Fact]
    public void LightsOffShowOffUntilTheSunIsFullyUp() {
        Assert.Equal("off", Chart.Explain(95, 62, 60, 5, 100, false, nightLights: 80).Steps.First(s => s.Title == "Lights").Value);
        Assert.Equal("no effect by day", Chart.Explain(95, 62, 60, 30, 100, false, nightLights: 80).Steps.First(s => s.Title == "Lights").Value);
    }

    [Fact]
    public void TheLevelEqualsTheTarget() {
        var t = new Tuning();
        for (double e = -8; e <= 20; e += 0.5)
            foreach (var lights in new[] { false, true })
                Assert.Equal(Rules.Target([95, 62, 60, 80], 40, lights, t.Fraction(e), t, e < t.LightsBoostSunBelow, 0.7),
                             Chart.Explain(95, 62, 60, e, 40, lights, light: 0.7, nightLights: 80).Level);
    }
}
```

- [ ] **Step 5: Windows `Explain` and chart wiring**

`windows/Chart.cs`, `Explain`: add `double? nightLights = null` as the last parameter, then:

```csharp
        int @base = Rules.Target(nightLights is double nlv ? new[] { day, blindDown, night, nlv } : new[] { day, blindDown, night },
                                 p, lights, sunShare, t, dusk, light);
```
and replace the two `lifted` / *Lights* lines with:

```csharp
        if (nightLights != null) {
            // Its own lit-evening level: the lights count whenever the sun is not fully up, with no boost.
            bool moved = lights && @base != R(Math.Clamp(blended, 0, 100));
            steps.Add(new DecisionStep("Lights", moved ? string.Create(CultureInfo.InvariantCulture, $"on → {@base}")
                                               : lights ? "on, no effect now" : sunShare < 1 ? "off" : "no effect by day"));
        } else {
            bool lifted = lights && dusk && @base > R(blended);
            steps.Add(new DecisionStep("Lights", lifted ? string.Create(CultureInfo.InvariantCulture, $"on → {@base}")
                                               : lights ? "on, no effect now" : dusk ? "off" : "no effect by day"));
        }
```

`windows/BrightnessChart.cs`:

```csharp
sealed record ChartMonitor(string Id, string Label, double Day, double BlindDown, double Night, double? NightLights = null);
```
```csharp
    double[] Levels(ChartMonitor m) =>
        Chart.EffectiveLevels(m.NightLights is double nl ? new[] { m.Day, m.BlindDown, m.Night, nl } : new[] { m.Day, m.BlindDown, m.Night },
                              live()?.Levels is { } lv && lv.TryGetValue(m.Id, out var ha) ? ha : null);
```
In `Decide(ChartMonitor m)`:

```csharp
        bool lightsNow = li?.LightsUsed is { } used && used.TryGetValue(m.Id, out var usedLit) ? usedLit : li?.Lights ?? false;
        return Chart.Explain(l[0], l[1], l[2], li?.Elev ?? Sun.Elevation(now, lat, lon), hasBlind ? li?.Pos ?? 100 : (double?)null,
                             lightsNow, tuning(), li?.Light ?? 1, o?.Value, o?.Weight ?? 1,
                             linked, li?.Leader ?? "", li?.Applying ?? true, Rules.NightLightsLevel(l));
```

`windows/Settings.cs`, next to `ShowsNightLights`:

```csharp
    /// The typed "Lights on" level, while its row shows; null when empty or not a level.
    double? NightLightsValue(TextBox box) => ShowsNightLights && ContrastRule.ParseField(box.Text).value is int v ? (double?)v : null;
```

In `RebuildCurves`:

```csharp
        var mons = rows.Select(r => new ChartMonitor(r.mon.Key, string.IsNullOrWhiteSpace(r.label.Text) ? r.mon.D.Friendly : r.label.Text.Trim(),
                                                     r.day.Value, r.blind.Value, r.night.Value, NightLightsValue(r.nightLights))).ToList();
```

and in `Load()`, after creating the `nightLights` box: `nightLights.TextChanged += (_, _) => RebuildCurves();   // "How Daylit decides" uses it`.

- [ ] **Step 6: Commit, push, check CI**

```bash
git add mac/Sources/DaylitCore/Chart.swift mac/Sources/Daylit/BrightnessChart.swift mac/Sources/Daylit/Settings.swift mac/Tests/DaylitCoreTests/NightLightsTests.swift \
        windows/Chart.cs windows/BrightnessChart.cs windows/Settings.cs windows/tests/NightLightsTests.cs
git commit -m "Mac, Windows: How Daylit decides shows the lights-on level

Co-Authored-By: Claude <noreply@anthropic.com>"
git push
gh run list --branch feature/night-lights --limit 1
gh run watch <id> --exit-status
```

Expected: tests and builds green on both jobs; only `settings-displays-*` fail at *UI snapshots* (no `curve-*` scene changes: they set no `nightLights`).

---

### Task 15: Re-record the UI snapshots on CI

**Files:**
- Modify: `mac/Tests/Snapshots/settings-displays-{light,dark}.png`, `windows/tests/Snapshots/settings-displays-{light,dark}.png`

- [ ] **Step 1: Record**

```bash
gh workflow run build.yml --ref feature/night-lights -f record=true
gh run list --branch feature/night-lights --workflow build.yml --limit 1   # the record run's id
gh run watch <id> --exit-status
gh run download <id> -n snapshots-mac -D mac/Tests/Snapshots
gh run download <id> -n snapshots-windows -D windows/tests/Snapshots
git status --short mac/Tests/Snapshots windows/tests/Snapshots
```

Expected: only `settings-displays-light.png` and `settings-displays-dark.png` change in each folder. If any other image changed (a `curve-*`, `panel-*` or another `settings-*`), stop: something beyond the Lights on row moved; find why before committing.

- [ ] **Step 2: Look and commit**

Open the four images: under *Night* in the Studio Display card there is a **Lights on** row with "Not set" and `%`, and the caption ends with "Lights on: after sunset with the room lights on; empty keeps Night plus the room-lights boost."

```bash
git add mac/Tests/Snapshots windows/tests/Snapshots
git commit -m "UI snapshots: Lights on row in Settings → Displays

Co-Authored-By: Claude <noreply@anthropic.com>"
git push
gh run list --branch feature/night-lights --limit 1
gh run watch <id> --exit-status
```

Expected: both jobs fully green, *UI snapshots* included.

---

### Task 16: Docs, example config and Home Assistant helpers

**Files:**
- Modify: `config.example.json`, `homeassistant/daylit_helpers.yaml`, `README.md`, `docs/setup.md`, `AGENTS.md`
- Modify: `mac/Tests/DaylitCoreTests/DaylitCoreTests.swift`, `windows/tests/RulesTests.cs` (the example config tests)

- [ ] **Step 1: Example config (with its tests)**

`config.example.json`: in the left monitor's `homeAssistant` block, after `"set": "input_number.daylit_left_set"` add `,` and `"nightLights": "input_number.daylit_left_night_lights"`; change the right monitor's levels line to `"day": 90, "blindDown": 60, "night": 30, "nightLights": 40`.

`mac/Tests/DaylitCoreTests/DaylitCoreTests.swift`, `testExampleConfigLoads`, after `XCTAssertNil(c.monitors?.last?.contrast)`:

```swift
        XCTAssertEqual(c.monitors?.first?.homeAssistant?.nightLights, "input_number.daylit_left_night_lights")
        XCTAssertEqual(c.monitors?.last?.nightLights, 40)
```

`windows/tests/RulesTests.cs`, `ExampleConfigLoads`, after `Assert.Null(c.Monitors![1].Contrast);`:

```csharp
        Assert.Equal("input_number.daylit_left_night_lights", c.Monitors![0].HomeAssistant!.NightLights);
        Assert.Equal(40, c.Monitors![1].NightLights);
```

Run: `cd mac && swift test` → green.

- [ ] **Step 2: Home Assistant helpers**

`homeassistant/daylit_helpers.yaml`, after the `daylit_left_set` helper:

```yaml
  # Optional: the level after sunset with the room lights on, for a monitor whose lit evenings sit
  # well above its night level. Name it in the monitor's "nightLights" key. Without it the room
  # lights add the same small boost to every monitor's night level, as before.
  # daylit_left_night_lights:
  #   name: Left monitor, night with the lights on
  #   min: 0
  #   max: 100
  #   step: 1
  #   unit_of_measurement: "%"
```

- [ ] **Step 3: README**

`README.md`, "How it works", replace step 4 with:

```markdown
4. **Room lights** on around dusk keep it a little above *night*, so a lit room is not too dark. A monitor
   can have its own level for that instead, *lights on* (optional): then *night* is the dark-room level
   that clouds blend toward, and the lights slide it to *lights on* as the sun goes down
   ([details](docs/setup.md#lights-on-level)).
```

- [ ] **Step 4: docs/setup.md**

- *How Daylit decides, right now*, step 4: append " A monitor with a *Lights on* level uses that instead ([below](#lights-on-level))."
- Add a section right after that list (before `### Suggested levels`):

```markdown
### Lights on level

By default the room lights do two things for every monitor: after sunset they keep it 5 above *night*
(`tuning.brightness.lightsBoost`), and *night* is also where weak daylight (clouds, a low sun) blends to.
When your lit evening is far above the level you want on a dim morning, give that monitor a **Lights on**
level (Settings → Displays, shown when a lights entity is set; or `"nightLights"` in the config, or a
Home Assistant helper). Then:

- **Lights off:** the blend goes toward *night*, with no boost.
- **Lights on:** the blend goes toward a point that slides from *night* (sun high) to *Lights on* (sun
  down). In daylight the lamps change nothing; after sunset the monitor sits at *Lights on*; there is no
  jump at dusk.

Example, day 95, blind closed 62, night 60, lights on 80: a cloudy morning (daylight counted at half) with
the blind 40% open gives 68, 58% open 71, the blind open with daylight at 55% gives 79, and a dark evening
with the lights on gives 80. Without *Lights on* nothing changes. With Home Assistant down, a monitor with
*Lights on* keeps the last lights state Home Assistant gave (others count the lights as off, as before).
Suggestions do not learn from changes made while the lights are on and the sun is not fully up on such a
monitor, and changing *Lights on* starts their evidence afresh.
```

- `monitors` row of the config table: after "`night` (0–100, defaults 70/40/20)," insert "an optional `nightLights` (0–100, [Lights on level](#lights-on-level)),".
- The Home Assistant JSON block: add the line `"nightLights": "input_number.daylit_left_night_lights"` (with a comma after the `set` line), and after the bullet "The three levels can then be tuned…" add: "- `nightLights` is optional: a fourth `input_number` for the [Lights on level](#lights-on-level). Home Assistant's value wins when it is 0 or more."
- Tuning table, `brightness.lightsBoost` row: append "(monitors without a `nightLights` level)".

- [ ] **Step 5: AGENTS.md**

In "3. Pick a source and write the config", per-monitor sentence: after "local levels `day` / `blindDown` / `night` (0–100)," insert "an optional `nightLights` (0–100: the level after sunset with the room lights on; only with a Home Assistant lights entity),", and change "naming three `input_number` entities" to "naming three `input_number` entities (a fourth, `nightLights`, is optional)".

- [ ] **Step 6: Check, commit, push**

```bash
grep -rn "nightLights" README.md docs/setup.md AGENTS.md config.example.json homeassistant/daylit_helpers.yaml
git diff --stat
git add config.example.json homeassistant/daylit_helpers.yaml README.md docs/setup.md AGENTS.md mac/Tests/DaylitCoreTests/DaylitCoreTests.swift windows/tests/RulesTests.cs
git commit -m "Docs: the optional lights-on level

Co-Authored-By: Claude <noreply@anthropic.com>"
git push
gh run list --branch feature/night-lights --limit 1
gh run watch <id> --exit-status
```

Expected: both jobs green. No real entity names, addresses or coordinates were added (the example's names are the existing generic `daylit_left_*` ones).

---

### Task 17: Final full run

- [ ] **Step 1: Mac**

```bash
cd mac && swift test 2>&1 | tail -3      # Executed N tests, with 0 failures
cd .. && mac/build.sh /tmp/daylit-build 2>&1 | grep -E "warning|error|Build complete"   # only "Build complete!"
```

- [ ] **Step 2: CI on the last push**

```bash
gh run list --branch feature/night-lights --limit 1
gh run watch <id> --exit-status
```

Expected: macOS and Windows jobs green, *UI snapshots* included.

- [ ] **Step 3: Spec walk-through**

Check each spec line against the code, and note anything missing:

- No `nightLights` → `target` identical (Task 1 grid, both apps).
- Lights off → blend toward night, no boost; lights on → the anchor rule; clamp and round (Tasks 1, 3).
- Lights state: Home Assistant's; none configured → off; fallback keeps the last state only for opt-in monitors, none seen → off; sun-only → off (Tasks 2, 3, 8, 9).
- Config: local key, Home Assistant helper (≥ 0 wins), validation, `--check-config` (Tasks 4–7).
- Settings row only with a lights entity, help text, saved keeping other keys (Tasks 12, 13).
- Chart follows `target`; no new elements (Task 14).
- Suggestions: no sample while lights on and `sun < 1` for an opt-in monitor; snapshot includes the level (Tasks 10, 11).
- Only `settings-displays-*` snapshots changed (Task 15). Docs (Task 16).

- [ ] **Step 4: Working tree clean and pushed**

```bash
git status
git log --oneline origin/feature/night-lights -1
```

Expected: `nothing to commit, working tree clean` and the branch up to date with `origin/feature/night-lights`. Opening the pull request is a separate decision for the owner.
