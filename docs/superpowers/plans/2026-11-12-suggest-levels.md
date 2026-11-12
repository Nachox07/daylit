# Suggest New Levels From Repeated Hand Changes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When someone keeps correcting a monitor the same way, Daylit (macOS and Windows) offers to change that monitor's `day` / `blindDown` / `night` level in a one-line panel card with **Apply** and **Not now**; it never changes a level without the click.

**Architecture:** A pure core (`mac/Sources/DaylitCore/Suggest.swift`, `windows/Suggest.cs`, same rules and same tests) turns hand changes into samples, finds which levels the samples can tell apart, fits those levels by ridge least squares, rounds them to what can be stored, and decides whether to suggest by re-running the real `target(...)`. The apps add a recording hook next to `decide` in the tick, a per-machine `corrections.json`, the Home Assistant `input_number/set_value` write and `min`/`max`/`step` read, the Apply / Not now actions, and the panel card with a new UI snapshot `panel-one-suggestion`.

**Tech Stack:** Swift 5.9 package (XCTest, SwiftUI, AppKit), .NET 10 WPF (xUnit), Home Assistant REST API.

**Spec:** `docs/superpowers/specs/2026-11-12-suggest-levels-design.md` (read it once before Task 1).

---

## Read this first (every task)

- Work only in the worktree of branch `feature/suggest-levels` (`.worktrees/suggest-levels` inside the main checkout). All paths below are relative to its root; run commands from there.
- **macOS:** `cd mac && swift test` runs the core tests. `mac/build.sh /tmp/daylit-build` builds the app; it must finish with **0 errors and 0 warnings** (pass a folder so it does not replace `~/Applications/Daylit.app`).
- **Windows: there is no `dotnet` on this Mac.** Windows code is compiled and tested only by CI (`.github/workflows/build.yml`, job `windows`) after a push. Be extra careful with C# syntax. Known traps: a ternary that mixes a value and `null` needs a cast (`cond ? (double?)x : null`); a pattern variable declared in an `if` condition stays in scope for the rest of the block, so pick names not used elsewhere in the method; records compare arrays and lists by reference (the records here override `Equals` for that reason).
- To check a Windows task on CI after pushing: `gh run list --branch feature/suggest-levels --limit 1` gives the run id, then `gh run watch <id> --exit-status`. On a failure, `gh run view <id> --log-failed | head -80` shows the compiler or test error.
- **Public repo.** No real coordinates, IP addresses, Home Assistant entity names, home-folder paths or tokens in code, tests, docs or commits. Monitor names in tests are `"Monitor"` / `"m"`. If a place is needed, Greenwich (51.48, 0). **Never read, print or handle the Home Assistant token.**
- Test names describe behaviour. Never put issue numbers in test names or commit subjects.
- Commit subjects start with the area: `Mac:`, `Windows:`, `Docs:`. End every commit message with the line `Co-Authored-By: Claude <noreply@anthropic.com>` and no other trailer or link.
- UI snapshot baselines (`mac/Tests/Snapshots`, `windows/tests/Snapshots`) are **never recorded locally**: Task 26 records them on CI (CONTRIBUTING.md → *UI snapshots*). From Task 21 until Task 26, CI's macOS job fails at the *UI snapshots* step with `panel-one-suggestion-…: new scene, no baseline`; from Task 25 the Windows job does the same. That is expected; every other step must pass.

## Key existing code (where things hook in)

| Symbol | Where | What it is |
|---|---|---|
| `target(day:blindDown:night:elev:pos:lights:tuning:light:) -> Int` | `mac/Sources/DaylitCore/Rules.swift` | the automatic level; daylight `s = min(daylightFraction(elev), light)` |
| `effectiveLevels(local:fromHA:)` | `mac/Sources/DaylitCore/Rules.swift` | `[day, blindDown, night]` with Home Assistant's values where ≥ 0 |
| `HoldState` (`lastSet`, `offset`, `offsetSun`, `offsetAt`, …) | `mac/Sources/DaylitCore/Rules.swift` | per-monitor hold state between ticks |
| `decide(current:want:remote:state:here:auto:dragging:sun:touched:now:dayOf:) -> Step` | `mac/Sources/DaylitCore/Rules.swift` | one tick's decision; a hand change sets `offset = c − want`, `offsetSun`, `offsetAt = now` |
| `localDay(_:)` | `mac/Sources/DaylitCore/Rules.swift` | local calendar day of a Unix time |
| `daylightFraction(elevation:tuning:)` | `mac/Sources/DaylitCore/Sun.swift` | 0 at −3°, 1 from 12° (defaults) |
| `Tuning` (`lightsBoost`, `lightsBoostSunBelow`, …) | `mac/Sources/DaylitCore/Tuning.swift` | thresholds |
| `ConfigPatch`, `ConfigText`, `ConfigEditError` | `mac/Sources/DaylitCore/ConfigEdit.swift` | saving the config file, keeping unknown keys |
| `Daylit.tick()` loop around `decide(...)` | `mac/Sources/Daylit/Model.swift` ~lines 590–680 | per-monitor tick |
| `HAClient.call(_:_:_:timeout:)`, `HAClient.describe` | `mac/Sources/Daylit/Sources.swift` | Home Assistant REST (GET when the body is `nil`) |
| `Panel` | `mac/Sources/Daylit/UI.swift` | the menu-bar panel |
| `Snapshots.scenes()` | `mac/Sources/Daylit/Snapshots.swift` | the snapshot scenes |
| `CLI.suggestMatch(_:)` | `mac/Sources/Daylit/Cli.swift` | a short `match` for a display name |
| `Rules.Target(double[] v, double pos, bool lights, double sun, Tuning? t, bool? boost, double light)` | `windows/Rules.cs` | Windows target; `sun` is `Tuning.Fraction(elev)`, `boost` is `elev < LightsBoostSunBelow` |
| `Hold` record struct, `Rules.Decide(...)`, `Rules.LocalDay` | `windows/Rules.cs` | as on the Mac |
| `Tuning.Fraction(elev)`, `ConfigPatch` (`Read`, `HasComments`, `SuggestMatch`, `Apply`) | `windows/Config.cs` | |
| `Controller.TickOnce()` loop around `Rules.Decide(...)` | `windows/App.cs` ~lines 590–640 | Windows tick |
| `HAClient.Call`, `HAClient.History` | `windows/Sources.cs` | Windows Home Assistant REST |
| `Settings` (registry) | `windows/Win.cs` | app settings |
| `Flyout` | `windows/Ui.cs` | the tray panel |
| `Snapshots.Scenes()` / `Render` | `windows/Snapshots.cs` | snapshot scenes |

## Numbers the fixtures produce (computed while writing this plan)

Week fixture (levels 100 / 78 / 75, 13 samples on 5 UTC days): automatic levels `85 86 86 87 85 86 86 85 87 86 91 91 95`; candidates = blind down only (day dominates on 2 days, night on none); fit blind down = **61.42** → rounded **61** (78 → 61, a drop of 17); mean absolute error **11.54 → 3.31**; amount **14** ("lower by about 14"); log `suggest: Monitor blind down 78 → 61 (13 changes on 5 days)`.

Second-day fixture (levels 95 / 62 / 75): automatic levels 75, 75, 78 (the 78 at 58% needs daylight 0.5, sun 4.5°); two samples settle (63 and 72), the put-back 69 does not; no candidates (one day); a blind-down-only fit gives **55.88**.

Cloudy-morning replay (levels 95 / 62 / 75, the two held changes 63 at blind 40% and 72 at blind 58% on three days, daylight 0.5 / 0.6 / 0.7 from sun 4.5° / 6° / 7.5°): automatic levels `75 79 75 79 75 78`. The largest weights are blind down 0.42, day 0.41, night 0.50, all under 0.55, so there are **no candidates and no suggestion**.

References (sunny with the blind fully down, sunny with it open, evening with lights on; levels 100 / 78 / 75): before **78 / 100 / 80**. After the week's proposal (blind down 61): **61 / 100 / 80**. After the four-morning "clear pattern" proposal (blind down 63, fit 62.83): **63 / 100 / 80**. Only the covered, proposed situation moves; the other two move 0.

Other checks: one sample (chosen 60 at blind 30%, auto 85) fits blind down to **66.44**; exact synthetic data (levels 90/50/30, 300 samples) recovers each level within 1.

## File map

Create:
- `mac/Sources/DaylitCore/Suggest.swift`: the pure core (types `Level`, `Sample`, `NumberStep`, `LevelChange`, `Suggestion`, `SampleContext`, `Recorder`; `enum Suggest` with the rules).
- `mac/Tests/DaylitCoreTests/SuggestTests.swift`: all core tests and the two fixtures.
- `mac/Sources/Daylit/Suggestions.swift`: the app side (`extension Daylit`): corrections file, levels and steps, working out the suggestion, Apply, Not now.
- `windows/Suggest.cs`: the same core in C#.
- `windows/tests/SuggestTests.cs`: the same tests in xUnit.
- `windows/Suggestions.cs`: the Windows app side (`partial class Controller`).

Modify:
- `mac/Sources/DaylitCore/ConfigEdit.swift`: `ConfigPatch.setLevels` (write one monitor's local levels).
- `mac/Sources/Daylit/Sources.swift`: `HAClient.setNumber`, `HAClient.numberStep`.
- `mac/Sources/Daylit/Model.swift`: state, load at start, dirty on reload, the tick hook, `forgetHandSet` made internal.
- `mac/Sources/Daylit/UI.swift`: the suggestion card and the Apply error in the problem line.
- `mac/Sources/Daylit/Snapshots.swift`: scene `panel-one-suggestion`.
- `windows/Config.cs`: `ConfigPatch.SetLevels`.
- `windows/tests/Daylit.Tests.csproj`: compile `../Suggest.cs`.
- `windows/Sources.cs`: `HAClient.SetNumber`, `HAClient.GetNumberStep`.
- `windows/Win.cs`: `Settings.SuggestDismissed`.
- `windows/App.cs`: `partial`, load, dirty on reload, the tick hook, the call at the end of the tick.
- `windows/Ui.cs`: the card and the Apply error.
- `windows/Snapshots.cs`: scene `panel-one-suggestion`.
- `README.md`, `docs/setup.md`, `AGENTS.md`, `CONTRIBUTING.md`: short mentions.
- `mac/Tests/Snapshots/panel-one-suggestion-{light,dark}.png`, `windows/tests/Snapshots/panel-one-suggestion-{light,dark}.png`: new baselines, from CI.

## Decisions taken where the spec left room

1. "Main weight" uses the candidate rule: a sample counts for a level when that level's weight is ≥ 0.55. With several proposed levels, the **main** one is the one that moves most (the first on a tie); the sentence and the amount follow it; the others follow in day, blind down, night order.
2. The "3 points better" test is done once, for all levels that move ≥ 5 together. No search over subsets.
3. The log's "N changes on D days" counts every current sample of that monitor (the ones the fit used).
4. Pending (not yet settled) changes live in memory only: a restart drops them.
5. A hand change on a tick that may not be recorded (for example the lights boost decided it) still ends the pending change before it. Automatic off drops a pending change (`held` = Automatic on and offset still set).
6. The `min`/`max`/`step` of an `input_number` is read with `GET /api/states/<entity>` when the suggestion is worked out, not in the tick template (the template and its tests stay as they are).
7. The suggestion is worked out again at the end of a tick when it is marked dirty (start, config reload, a new sample, Apply, Not now) and also when a monitor's levels or Home Assistant's up/down state changed since last time.
8. A local Apply on a `config.json` that has comments is refused with a problem line ("set the level in Settings instead"), because saving would drop the comments silently. A monitor with no entry in the config gets one, with `match` from the existing suggest-match helper.
9. The Apply error stays in the problem line (`suggestError` / `SuggestError`) until the next suggestion action, since the tick resets the normal problem line every 30 s.
10. C# names the function `Suggest.SuggestionFor` (Swift: `Suggest.suggestion`) because a C# method named `Suggestion` next to the `Suggestion` type is confusing. Everything else mirrors.
11. Second-day fixture: "78 → 72 at 58%" only gives an automatic 78 with daylight 0.5 (sun 4.5°, late afternoon); in full daylight it would be 81. The fixture uses sun 4.5°.
12. Week fixture: "blind 100 raised slightly" cannot be at full daylight (the target would be 100, which is not recorded), so it uses sun 9° (daylight 0.8, auto 95, chosen 98), on a day that already has a midday sample, so day stays a non-candidate.
13. The amount is the mean `|chosen − auto|` over main-level samples that pull the same way as the proposal (spec section 5 says so now); no such sample, no suggestion.
13. "Exact synthetic data recovers the levels" is checked within 1 point: the pull toward the current value is part of the fit, so recovery is never exact; 300 samples make it small.

---

### Task 1: Swift core: levels, samples, weights and candidates

Creates `mac/Sources/DaylitCore/Suggest.swift` with the file header, `Level`, `Sample` and the first part of `enum Suggest`. Later tasks add to it with `extension Suggest { … }` blocks appended at the end of the file.

**Files:**
- Create: `mac/Sources/DaylitCore/Suggest.swift`
- Create: `mac/Tests/DaylitCoreTests/SuggestTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `mac/Tests/DaylitCoreTests/SuggestTests.swift` with exactly this content (the `Fixture` helper is used by every later test task):

```swift
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
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `cd mac && swift test --filter SuggestCandidateTests`
Expected: the build fails with `error: cannot find 'Suggest' in scope (and 'Sample', 'Level')`.

- [ ] **Step 3: Write the code**

Create `mac/Sources/DaylitCore/Suggest.swift` with exactly this content:

```swift
// Suggest new levels from repeated hand changes. Pure: no IO, so every rule here is unit-tested.
// The app records a Sample for each deliberate correction, keeps them in corrections.json and asks
// Suggest.suggestion for a change to offer in the panel. Same rules on Windows (windows/Suggest.cs).
import Foundation

/// The three levels of a monitor, in the order `target` and the config use them.
public enum Level: Int, CaseIterable, Codable {
    case day = 0, blindDown = 1, night = 2
    /// As the panel says it.
    public var name: String { ["day", "blind down", "night"][rawValue] }
    /// The config key: monitors[].day / blindDown / night.
    public var key: String { ["day", "blindDown", "night"][rawValue] }
    /// When this level is the one that counts most.
    public var situation: String { ["with the blind open", "with the blind partly or fully down", "in the evening"][rawValue] }
}

/// One deliberate correction by hand.
public struct Sample: Codable, Equatable {
    public var monitor: String     // the monitor's key (the same key the hold state uses)
    public var chosen: Int         // the level the user set
    public var auto: Int           // the automatic target at that moment
    public var s: Double           // the daylight fraction target used: min(daylightFraction(elev), light)
    public var p: Double           // blind position / 100
    public var elev: Double        // sun elevation, so scoring can rerun target
    public var lights: Bool        // the room lights were on
    public var levels: [Double]    // [day, blindDown, night] in effect then
    public var at: Double          // Unix seconds
    public init(monitor: String, chosen: Int, auto: Int, s: Double, p: Double, elev: Double, lights: Bool, levels: [Double], at: Double) {
        self.monitor = monitor; self.chosen = chosen; self.auto = auto; self.s = s; self.p = p
        self.elev = elev; self.lights = lights; self.levels = levels; self.at = at
    }
}

public enum Suggest {
    /// A level "carries most of the weight" in a sample from this weight (0.55, so a blind exactly 40% open still counts).
    public static let dominant = 0.55
    /// A level is a candidate only with dominant samples on this many local days.
    public static let minDays = 3

    /// How much each level counts in `target` for a sample: [day, blindDown, night], summing to 1.
    public static func weights(s: Double, p: Double) -> [Double] { [s * p, s * (1 - p), 1 - s] }

    /// Whether `level` carries most of the weight in this sample.
    public static func dominates(_ x: Sample, _ level: Level) -> Bool {
        weights(s: x.s, p: x.p)[level.rawValue] >= dominant - 1e-9
    }

    /// The levels the samples can tell apart: dominant samples on at least `minDays` different local days.
    public static func candidates(_ samples: [Sample], dayOf: (Double) -> Int = { localDay($0) }) -> [Level] {
        Level.allCases.filter { l in Set(samples.filter { dominates($0, l) }.map { dayOf($0.at) }).count >= minDays }
    }
}
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `cd mac && swift test --filter SuggestCandidateTests`
Expected: `Executed 5 tests, with 0 failures`. Then `cd mac && swift test` (everything) passes too.

- [ ] **Step 5: Commit**

```bash
git add mac/Sources/DaylitCore/Suggest.swift mac/Tests/DaylitCoreTests/SuggestTests.swift
git commit -m "$(cat <<'MSG'
Mac: suggestion core with samples, level weights and candidates

Co-Authored-By: Claude <noreply@anthropic.com>
MSG
)"
```

### Task 2: Swift core: the fit

**Files:**
- Modify: `mac/Sources/DaylitCore/Suggest.swift` (append at the end of the file)
- Modify: `mac/Tests/DaylitCoreTests/SuggestTests.swift` (append at the end of the file)

- [ ] **Step 1: Write the failing tests**

Append this to the end of `mac/Tests/DaylitCoreTests/SuggestTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `cd mac && swift test --filter SuggestFitTests`
Expected: the build fails with `error: type 'Suggest' has no member 'fit'`.

- [ ] **Step 3: Write the code**

Append this to the end of `mac/Sources/DaylitCore/Suggest.swift`:

```swift
extension Suggest {
    /// Least squares for the candidate levels, the others held at their current values, with a pull of
    /// weight 1 toward the current value (as one extra sample at the current level):
    ///     minimise Σ (chosen − x·L)² + Σ_candidates (L_k − current_k)²
    /// Returns all three levels, each fitted one clamped to 0–100 (not rounded: see roundToStep).
    public static func fit(_ samples: [Sample], levels: [Double], candidates: [Level]) -> [Double] {
        let c = candidates.map(\.rawValue), n = c.count
        guard n > 0, levels.count == 3 else { return levels }
        var a = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        var b = [Double](repeating: 0, count: n)
        for x in samples {
            let w = weights(s: x.s, p: x.p)
            var y = Double(x.chosen)
            for k in 0..<3 where !c.contains(k) { y -= w[k] * levels[k] }
            for i in 0..<n {
                b[i] += w[c[i]] * y
                for j in 0..<n { a[i][j] += w[c[i]] * w[c[j]] }
            }
        }
        for i in 0..<n { a[i][i] += 1; b[i] += levels[c[i]] }   // the pull toward the current value
        let solved = solve(a, b)
        var out = levels
        for i in 0..<n { out[c[i]] = min(max(solved[i], 0), 100) }
        return out
    }

    /// Gaussian elimination with partial pivoting. The pull adds 1 to the diagonal, so the matrix is
    /// positive definite and no pivot is 0.
    static func solve(_ a0: [[Double]], _ b0: [Double]) -> [Double] {
        var a = a0, b = b0
        let n = b.count
        for col in 0..<n {
            let piv = (col..<n).max { abs(a[$0][col]) < abs(a[$1][col]) }!
            a.swapAt(col, piv); b.swapAt(col, piv)
            for r in 0..<n where r != col {
                let f = a[r][col] / a[col][col]
                for k in col..<n { a[r][k] -= f * a[col][k] }
                b[r] -= f * b[col]
            }
        }
        return (0..<n).map { b[$0] / a[$0][$0] }
    }
}
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `cd mac && swift test --filter SuggestFitTests`
Expected: `Executed 4 tests, with 0 failures`. Then `cd mac && swift test` (everything) passes too.

- [ ] **Step 5: Commit**

```bash
git add mac/Sources/DaylitCore/Suggest.swift mac/Tests/DaylitCoreTests/SuggestTests.swift
git commit -m "$(cat <<'MSG'
Mac: fit candidate levels by least squares with a pull to the current value

Co-Authored-By: Claude <noreply@anthropic.com>
MSG
)"
```

### Task 3: Swift core: rounding to what can be stored

**Files:**
- Modify: `mac/Sources/DaylitCore/Suggest.swift` (append at the end of the file)
- Modify: `mac/Tests/DaylitCoreTests/SuggestTests.swift` (append at the end of the file)

- [ ] **Step 1: Write the failing tests**

Append this to the end of `mac/Tests/DaylitCoreTests/SuggestTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `cd mac && swift test --filter SuggestRoundingTests`
Expected: the build fails with `error: cannot find 'NumberStep' in scope`.

- [ ] **Step 3: Write the code**

Append this to the end of `mac/Sources/DaylitCore/Suggest.swift`:

```swift
/// The values a level can be stored as. A Home Assistant input_number has its own min, max and step;
/// a local level is a whole number 0–100.
public struct NumberStep: Equatable {
    public var min: Double
    public var max: Double
    public var step: Double
    public init(min: Double, max: Double, step: Double) { self.min = min; self.max = max; self.step = step }
    public static let whole = NumberStep(min: 0, max: 100, step: 1)

    /// From the answer to GET /api/states/<input_number>: its min, max and step attributes. nil when one is missing.
    public static func parse(_ d: Data) -> NumberStep? {
        guard let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let a = o["attributes"] as? [String: Any],
              let lo = (a["min"] as? NSNumber)?.doubleValue, let hi = (a["max"] as? NSNumber)?.doubleValue,
              let st = (a["step"] as? NSNumber)?.doubleValue, st > 0, hi >= lo else { return nil }
        return NumberStep(min: lo, max: hi, step: st)
    }
}

extension Suggest {
    /// The nearest value `st` accepts, inside both its range and 0–100. Halves round up.
    public static func roundToStep(_ v: Double, _ st: NumberStep) -> Double {
        let lo = max(st.min, 0), hi = min(st.max, 100)
        let first = ((lo - st.min) / st.step - 1e-9).rounded(.up), last = ((hi - st.min) / st.step + 1e-9).rounded(.down)
        guard last >= first else { return min(max(v, lo), hi) }   // a step coarser than the range: just clamp
        let n = min(max(((v - st.min) / st.step).rounded(), first), last)
        return ((st.min + n * st.step) * 1e6).rounded() / 1e6   // no 61.500000001 from the multiplication
    }
}
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `cd mac && swift test --filter SuggestRoundingTests`
Expected: `Executed 3 tests, with 0 failures`. Then `cd mac && swift test` (everything) passes too.

- [ ] **Step 5: Commit**

```bash
git add mac/Sources/DaylitCore/Suggest.swift mac/Tests/DaylitCoreTests/SuggestTests.swift
git commit -m "$(cat <<'MSG'
Mac: round a proposed level to the Home Assistant step or a whole number

Co-Authored-By: Claude <noreply@anthropic.com>
MSG
)"
```

### Task 4: Swift core: scoring, the trigger and the sentence

**Files:**
- Modify: `mac/Sources/DaylitCore/Suggest.swift` (append at the end of the file)
- Modify: `mac/Tests/DaylitCoreTests/SuggestTests.swift` (append at the end of the file)

- [ ] **Step 1: Write the failing tests**

Append this to the end of `mac/Tests/DaylitCoreTests/SuggestTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `cd mac && swift test --filter SuggestTriggerTests`
Expected: the build fails with `error: type 'Suggest' has no member 'meanAbsError' (and 'suggestion', 'Suggestion', 'LevelChange')`.

- [ ] **Step 3: Write the code**

Append this to the end of `mac/Sources/DaylitCore/Suggest.swift`:

```swift
/// One level to change: from its current value to the proposed one.
public struct LevelChange: Equatable {
    public var level: Level
    public var from: Double
    public var to: Double
    public init(level: Level, from: Double, to: Double) { self.level = level; self.from = from; self.to = to }
}

/// What the panel offers for one monitor.
public struct Suggestion: Equatable {
    public var monitor: String          // the monitor's key
    public var changes: [LevelChange]   // the main level (the one that moves most) first
    public var amount: Int              // how far the user moves it: mean of chosen − auto where the main level dominates, rounded, no sign
    public var lower: Bool              // the user lowers it (true) or raises it
    public var samples: Int             // the hand changes behind it
    public var days: Int                // on this many local days
    public init(monitor: String, changes: [LevelChange], amount: Int, lower: Bool, samples: Int, days: Int) {
        self.monitor = monitor; self.changes = changes; self.amount = amount; self.lower = lower; self.samples = samples; self.days = days
    }

    public var main: Level { changes[0].level }
    /// "blind down 78 → 62, day 100 → 95"
    public var changeText: String {
        changes.map { "\($0.level.name) \(Self.fmt($0.from)) → \(Self.fmt($0.to))" }.joined(separator: ", ")
    }
    /// The panel line: "You lower Monitor by about 12 with the blind partly or fully down. Set blind down 78 → 62?"
    public func sentence(label: String) -> String {
        "You \(lower ? "lower" : "raise") \(label) by about \(amount) \(main.situation). Set \(changeText)?"
    }
    /// "suggest: Monitor blind down 78 → 62 (12 changes on 4 days)"
    public func logLine(label: String) -> String { "suggest: \(label) \(changeText) (\(samples) changes on \(days) days)" }

    /// A whole number without decimals, otherwise one decimal (an input_number with step 0.5).
    public static func fmt(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), v)
    }
}

extension Suggest {
    /// A proposed level must move at least this much after rounding.
    public static let minMove = 5.0
    /// ...and the proposed levels must lower the mean absolute error by at least this much.
    public static let minGain = 3.0
    /// "Not now" hides a monitor's suggestions this long (seconds).
    public static let notNow: Double = 7 * 86400

    /// The two level lists are the same (an input_number may hold decimals).
    public static func sameLevels(_ a: [Double], _ b: [Double]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) < 1e-6 }
    }

    /// The real target (boost, clamp, rounding) for a sample's moment with other levels.
    /// `light: x.s` gives target the same daylight fraction: s is never above daylightFraction(elev).
    public static func rerun(_ x: Sample, levels l: [Double], tuning: Tuning) -> Int {
        target(day: l[0], blindDown: l[1], night: l[2], elev: x.elev, pos: x.p * 100, lights: x.lights, tuning: tuning, light: x.s)
    }

    /// Mean of |target − chosen| over the samples, with `levels`.
    public static func meanAbsError(_ samples: [Sample], levels: [Double], tuning: Tuning = Tuning()) -> Double {
        guard !samples.isEmpty else { return 0 }
        let total = samples.reduce(0) { $0 + abs(rerun($1, levels: levels, tuning: tuning) - $1.chosen) }
        return Double(total) / Double(samples.count)
    }

    /// The change to offer for one monitor, or nil.
    /// - samples: all recorded samples (other monitors' and stale ones are ignored here)
    /// - levels: the monitor's [day, blindDown, night] now
    /// - steps: per level, what it can be stored as; nil = it comes from Home Assistant and is unavailable now
    /// - dismissedUntil: "Not now" was clicked; nothing until this time
    public static func suggestion(monitor: String, samples all: [Sample], levels: [Double], steps: [NumberStep?], now: Double,
                                  dismissedUntil: Double?, tuning: Tuning = Tuning(),
                                  dayOf: (Double) -> Int = { localDay($0) }) -> Suggestion? {
        if let d = dismissedUntil, now < d { return nil }
        guard levels.count == 3, steps.count == 3 else { return nil }
        let mine = all.filter { $0.monitor == monitor && sameLevels($0.levels, levels) }
        let cand = candidates(mine, dayOf: dayOf).filter { steps[$0.rawValue] != nil }
        guard !cand.isEmpty else { return nil }
        let fitted = fit(mine, levels: levels, candidates: cand)
        var proposed = levels
        var changes: [LevelChange] = []
        for l in cand {
            let v = roundToStep(fitted[l.rawValue], steps[l.rawValue]!)
            if abs(v - levels[l.rawValue]) >= minMove - 1e-9 {
                proposed[l.rawValue] = v
                changes.append(LevelChange(level: l, from: levels[l.rawValue], to: v))
            }
        }
        guard !changes.isEmpty else { return nil }
        let gain = meanAbsError(mine, levels: levels, tuning: tuning) - meanAbsError(mine, levels: proposed, tuning: tuning)
        guard gain >= minGain - 1e-9 else { return nil }
        var main = changes[0]   // the one that moves most; the first of them on a tie
        for c in changes where abs(c.to - c.from) > abs(main.to - main.from) { main = c }
        let ordered = [main] + changes.filter { $0.level != main.level }
        let dom = mine.filter { dominates($0, main.level) }
        let mean = Double(dom.reduce(0) { $0 + $1.chosen - $1.auto }) / Double(max(dom.count, 1))
        return Suggestion(monitor: monitor, changes: ordered, amount: Int(abs(mean).rounded()), lower: mean < 0,
                          samples: mine.count, days: Set(mine.map { dayOf($0.at) }).count)
    }
}
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `cd mac && swift test --filter SuggestTriggerTests`
Expected: `Executed 7 tests, with 0 failures`. Then `cd mac && swift test` (everything) passes too.

- [ ] **Step 5: Commit**

```bash
git add mac/Sources/DaylitCore/Suggest.swift mac/Tests/DaylitCoreTests/SuggestTests.swift
git commit -m "$(cat <<'MSG'
Mac: decide when to suggest by rerunning the real target

Co-Authored-By: Claude <noreply@anthropic.com>
MSG
)"
```

### Task 5: Swift core: the recorder and what is not recorded

**Files:**
- Modify: `mac/Sources/DaylitCore/Suggest.swift` (append at the end of the file)
- Modify: `mac/Tests/DaylitCoreTests/SuggestTests.swift` (append at the end of the file)

- [ ] **Step 1: Write the failing tests**

Append this to the end of `mac/Tests/DaylitCoreTests/SuggestTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `cd mac && swift test --filter SuggestRecorderTests`
Expected: the build fails with `error: cannot find 'Recorder' in scope (and 'SampleContext', 'makeSample', 'isHandChange', 'afterApply')`.

- [ ] **Step 3: Write the code**

Append this to the end of `mac/Sources/DaylitCore/Suggest.swift`:

```swift
/// Why a tick's hand change is not a sample (each of these hides what the user really wanted).
public struct SampleContext: Equatable {
    public var follower: Bool      // a linked follower: its level comes from the leader
    public var writeFailed: Bool   // this tick's write to the monitor failed
    public var idle: Bool          // this machine is idle
    public var paused: Bool        // paused on battery
    public var sunFallback: Bool   // the source is Home Assistant but it is down: the sun is standing in
    public init(follower: Bool = false, writeFailed: Bool = false, idle: Bool = false, paused: Bool = false, sunFallback: Bool = false) {
        self.follower = follower; self.writeFailed = writeFailed; self.idle = idle; self.paused = paused; self.sunFallback = sunFallback
    }
}

/// Hand changes waiting to settle, one per monitor. A change becomes a sample after `settle` seconds with
/// no further hand change on that monitor, while its offset is still held.
public struct Recorder: Equatable {
    public static let settle: Double = 300
    public private(set) var pending: [String: Sample] = [:]
    public init() {}

    /// A hand change on `monitor` this tick. `sample` is nil when the tick may not be recorded (see
    /// Suggest.makeSample) or the user put it back to automatic: either way it ends the gesture before it.
    public mutating func handChanged(monitor: String, sample: Sample?) { pending[monitor] = sample }

    /// Every tick, per monitor. Returns the sample that became final now, if any.
    /// - held: the hand-set offset is still set and automatic mode is on (false drops the pending change)
    /// - levels: the monitor's levels now (a change drops it too)
    public mutating func settle(monitor: String, held: Bool, levels: [Double], now: Double) -> Sample? {
        guard let p = pending[monitor] else { return nil }
        if !held || !Suggest.sameLevels(p.levels, levels) { pending[monitor] = nil; return nil }
        guard now - p.at >= Self.settle else { return nil }
        pending[monitor] = nil
        return p
    }

    /// Forget a monitor's pending change (Apply, Automatic switched, back to automatic).
    public mutating func drop(_ monitor: String) { pending[monitor] = nil }
}

extension Suggest {
    /// The room lights' boost decided the target (it lifted the level above the blend).
    public static func boostDecides(levels l: [Double], elev: Double, pos: Double, lights: Bool, tuning t: Tuning, light: Double) -> Bool {
        guard lights, elev < t.lightsBoostSunBelow, l.count == 3 else { return false }
        let s = min(daylightFraction(elevation: elev, tuning: t), light)
        let daytime = l[1] + (l[0] - l[1]) * pos / 100
        return l[2] + t.lightsBoost > l[2] + (daytime - l[2]) * s
    }

    /// The sample for a tick where decide recorded a new hand-set level, or nil when it may not be recorded:
    /// see SampleContext, the lights boost deciding the target, or `chosen` / `auto` at 0 or 100 (the clamp
    /// hides the true wish). `pos` is the blind position 0–100 (100 without a blind), `light` the cloud cap (1 without a sensor).
    public static func makeSample(monitor: String, chosen: Int, auto: Int, elev: Double, pos: Double, lights: Bool, light: Double,
                                  levels: [Double], tuning: Tuning, now: Double, context: SampleContext) -> Sample? {
        if context.follower || context.writeFailed || context.idle || context.paused || context.sunFallback { return nil }
        guard levels.count == 3, (1...99).contains(chosen), (1...99).contains(auto) else { return nil }
        if boostDecides(levels: levels, elev: elev, pos: pos, lights: lights, tuning: tuning, light: light) { return nil }
        return Sample(monitor: monitor, chosen: chosen, auto: auto, s: min(daylightFraction(elevation: elev, tuning: tuning), light),
                      p: min(max(pos, 0), 100) / 100, elev: elev, lights: lights, levels: levels, at: now)
    }

    /// Whether this tick's decide took a new hand-set level (moved by hand): it stamps offsetAt with now.
    /// A level from the Home Assistant "set" helper (`remote`) stamps it too, but is not a hand change.
    public static func isHandChange(before: HoldState, after: HoldState, remote: Int?, now: Double) -> Bool {
        remote == nil && now > 0 && after.offsetAt == now && before.offsetAt != now
    }

    /// The hold state after Apply: the hand-set offset is cleared, or it would be applied again on top of
    /// the new level (target 85, set 70, new level gives 70: the monitor would go to 55).
    public static func afterApply(_ s: HoldState) -> HoldState {
        var r = s
        r.lastSet = nil; r.offset = nil; r.offsetSun = nil; r.offsetAt = nil
        return r
    }
}
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `cd mac && swift test --filter SuggestRecorderTests`
Expected: `Executed 8 tests, with 0 failures`. Then `cd mac && swift test` (everything) passes too.

- [ ] **Step 5: Commit**

```bash
git add mac/Sources/DaylitCore/Suggest.swift mac/Tests/DaylitCoreTests/SuggestTests.swift
git commit -m "$(cat <<'MSG'
Mac: record a hand change once it has held five minutes

Co-Authored-By: Claude <noreply@anthropic.com>
MSG
)"
```

### Task 6: Swift core: stale and old samples, corrections.json

**Files:**
- Modify: `mac/Sources/DaylitCore/Suggest.swift` (append at the end of the file)
- Modify: `mac/Tests/DaylitCoreTests/SuggestTests.swift` (append at the end of the file)

- [ ] **Step 1: Write the failing tests**

Append this to the end of `mac/Tests/DaylitCoreTests/SuggestTests.swift`:

```swift
final class SuggestStoreTests: XCTestCase {
    func testStaleSamplesAreDroppedWhenTheLevelsChange() {
        let old = Fixture.sample(0, 9, elev: 30, p: 0.35, chosen: 70, levels: [100, 78, 75])
        let fresh = Fixture.sample(1, 9, elev: 30, p: 0.35, chosen: 70, levels: [100, 62, 75])
        let unplugged = Fixture.sample(0, 9, elev: 30, p: 0.35, chosen: 70, levels: [90, 50, 30], monitor: "other")
        let kept = Suggest.dropStale([old, fresh, unplugged], current: ["m": [100, 62, 75]])
        XCTAssertEqual(kept, [fresh, unplugged])
        // A suggestion only counts samples taken with the levels in effect now.
        XCTAssertTrue(Suggest.sameLevels([100, 62.0000001, 75], [100, 62, 75]))
        XCTAssertFalse(Suggest.sameLevels([100, 62.5, 75], [100, 62, 75]))
    }

    func testSamplesOlderThanFourteenDaysAreDropped() {
        let now = Fixture.t0 + 20 * 86400
        let a = Fixture.sample(5, 9, elev: 30, p: 0.35, chosen: 70, levels: [100, 78, 75])    // 15 days old
        let b = Fixture.sample(7, 9, elev: 30, p: 0.35, chosen: 70, levels: [100, 78, 75])    // 13 days old
        XCTAssertEqual(Suggest.dropOld([a, b], now: now), [b])
    }

    func testSamplesSurviveTheFile() {
        let x = Fixture.sample(0, 9, elev: 30, p: 0.35, chosen: 70, levels: [100, 78, 75])
        XCTAssertEqual(Suggest.decode(Suggest.encode([x])), [x])
        let text = String(decoding: Suggest.encode([x]), as: UTF8.self)
        for key in ["\"monitor\"", "\"chosen\"", "\"auto\"", "\"s\"", "\"p\"", "\"elev\"", "\"lights\"", "\"levels\"", "\"at\""] {
            XCTAssertTrue(text.contains(key), key)
        }
        XCTAssertEqual(Suggest.decode(nil), [])
        XCTAssertEqual(Suggest.decode(Data("broken".utf8)), [])
        let short = #"{"samples": [{"monitor": "m", "chosen": 70, "auto": 86, "s": 1, "p": 0.35, "elev": 30, "lights": false, "levels": [100, 78], "at": 0}]}"#
        XCTAssertEqual(Suggest.decode(Data(short.utf8)), [])
    }
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `cd mac && swift test --filter SuggestStoreTests`
Expected: the build fails with `error: type 'Suggest' has no member 'dropStale' (and 'dropOld', 'decode', 'encode')`.

- [ ] **Step 3: Write the code**

Append this to the end of `mac/Sources/DaylitCore/Suggest.swift`:

```swift
/// corrections.json: {"samples": [...]}.
private struct CorrectionsFile: Codable { var samples: [Sample] }

extension Suggest {
    /// Samples older than this are dropped on load and on save (seconds).
    public static let maxAge: Double = 14 * 86400

    /// Without the samples older than `maxAge`.
    public static func dropOld(_ samples: [Sample], now: Double) -> [Sample] { samples.filter { now - $0.at <= maxAge } }

    /// Without the samples whose levels differ from their monitor's levels now (`current`, by monitor key):
    /// after Apply, a change in Settings or of a Home Assistant helper, a level starts from fresh evidence.
    /// Monitors not in `current` (unplugged) keep theirs.
    public static func dropStale(_ samples: [Sample], current: [String: [Double]]) -> [Sample] {
        samples.filter { x in current[x.monitor].map { sameLevels($0, x.levels) } ?? true }
    }

    /// The samples in corrections.json; none when it is missing or broken. Entries without three levels are skipped.
    public static func decode(_ d: Data?) -> [Sample] {
        guard let d, let f = try? JSONDecoder().decode(CorrectionsFile.self, from: d) else { return [] }
        return f.samples.filter { $0.levels.count == 3 }
    }

    /// corrections.json's content.
    public static func encode(_ samples: [Sample]) -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? e.encode(CorrectionsFile(samples: samples))) ?? Data("{\"samples\":[]}".utf8)
    }
}
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `cd mac && swift test --filter SuggestStoreTests`
Expected: `Executed 3 tests, with 0 failures`. Then `cd mac && swift test` (everything) passes too.

- [ ] **Step 5: Commit**

```bash
git add mac/Sources/DaylitCore/Suggest.swift mac/Tests/DaylitCoreTests/SuggestTests.swift
git commit -m "$(cat <<'MSG'
Mac: drop stale and old samples and keep them as JSON

Co-Authored-By: Claude <noreply@anthropic.com>
MSG
)"
```

### Task 7: Swift core: the two fixtures

Tests only: they check the motivating week, the day after, cloudy mornings and the reference situations (spec §4 *Protecting situations the user did not correct*, §7) against Tasks 1–6. No new code. The reference check is a test that guards against a later change to the fit, not a runtime filter.

**Files:**
- Modify: `mac/Tests/DaylitCoreTests/SuggestTests.swift` (append at the end of the file)

- [ ] **Step 1: Write the tests**

Append this to the end of `mac/Tests/DaylitCoreTests/SuggestTests.swift`:

```swift
/// Anonymised from one real week: every morning the user lowered the monitor 6–15 points with the blind
/// 30–40% open, with the levels day 100 / blind down 78 / night 75.
final class SuggestFixtureTests: XCTestCase {
    static let week: [Double] = [100, 78, 75]
    static func weekSamples() -> [Sample] {
        let l = week
        return [
            // Mornings, full daylight, the blind 30–40% open: about 15 lower than the automatic level.
            Fixture.sample(0, 8.5, elev: 20, p: 0.30, chosen: 70, levels: l), Fixture.sample(0, 9.5, elev: 24, p: 0.35, chosen: 72, levels: l),
            Fixture.sample(1, 8.5, elev: 20, p: 0.35, chosen: 70, levels: l), Fixture.sample(1, 9.0, elev: 22, p: 0.40, chosen: 74, levels: l),
            Fixture.sample(2, 8.5, elev: 20, p: 0.30, chosen: 71, levels: l), Fixture.sample(2, 9.5, elev: 24, p: 0.35, chosen: 70, levels: l),
            Fixture.sample(3, 8.5, elev: 20, p: 0.35, chosen: 72, levels: l), Fixture.sample(3, 9.0, elev: 22, p: 0.30, chosen: 73, levels: l),
            Fixture.sample(4, 8.5, elev: 20, p: 0.40, chosen: 75, levels: l), Fixture.sample(4, 9.5, elev: 24, p: 0.35, chosen: 70, levels: l),
            // Midday with the blind 60% open: a small lowering.
            Fixture.sample(1, 13, elev: 30, p: 0.60, chosen: 88, levels: l), Fixture.sample(3, 13, elev: 30, p: 0.60, chosen: 89, levels: l),
            // Late afternoon, blind open, sun low: raised a little.
            Fixture.sample(1, 16, elev: 9, p: 1, chosen: 98, levels: l),
        ]
    }

    func testTheWeekHasTheAutomaticLevelsTheUserSaw() {
        XCTAssertEqual(Self.weekSamples().map(\.auto), [85, 86, 86, 87, 85, 86, 86, 85, 87, 86, 91, 91, 95])
    }

    func testTheWeekProposesALowerBlindDownOnly() {
        let samples = Self.weekSamples()
        XCTAssertEqual(Suggest.candidates(samples, dayOf: Fixture.utcDay), [.blindDown])
        XCTAssertEqual(Suggest.fit(samples, levels: Self.week, candidates: [.blindDown])[1], 61.42, accuracy: 0.01)
        XCTAssertEqual(Suggest.meanAbsError(samples, levels: Self.week), 11.54, accuracy: 0.01)
        XCTAssertEqual(Suggest.meanAbsError(samples, levels: [100, 61, 75]), 3.31, accuracy: 0.01)
        let s = Suggest.suggestion(monitor: "m", samples: samples, levels: Self.week, steps: [.whole, .whole, .whole],
                                   now: Fixture.t0 + 5 * 86400, dismissedUntil: nil, dayOf: Fixture.utcDay)
        XCTAssertNotNil(s)
        XCTAssertEqual(s?.changes.map(\.level), [.blindDown])   // night not proposed, day not raised
        let to = s?.changes.first?.to ?? 0
        XCTAssertLessThanOrEqual(to, 78 - 5)
        XCTAssertTrue((45...65).contains(to), "\(to)")
        XCTAssertEqual(to, 61)
        XCTAssertEqual(s?.amount, 14)
        XCTAssertEqual(s?.sentence(label: "Monitor"),
                       "You lower Monitor by about 14 with the blind partly or fully down. Set blind down 78 → 61?")
        XCTAssertEqual(s?.logLine(label: "Monitor"), "suggest: Monitor blind down 78 → 61 (13 changes on 5 days)")
    }

    func testTheDayAfterRecordsTwoChangesAndFitsBlindDownLower() {
        // Levels day 95 / blind down 62 / night 75. Two changes held, a third was put back within 3 minutes.
        let l: [Double] = [95, 62, 75]
        let first = Fixture.sample(5, 8.5, elev: 20, p: 0.40, chosen: 63, levels: l)    // 75 → 63
        let putBack = Fixture.sample(5, 11, elev: 22, p: 0.40, chosen: 69, levels: l)   // 75 → 69, then back
        let second = Fixture.sample(5, 15, elev: 4.5, p: 0.58, chosen: 72, levels: l)   // 78 → 72, low afternoon sun
        XCTAssertEqual([first.auto, putBack.auto, second.auto], [75, 75, 78])
        var r = Recorder()
        var finals: [Sample] = []
        func ticks(_ from: Double, _ seconds: Double, held: Bool) {
            for t in stride(from: from + 30, through: from + seconds, by: 30) {
                if let f = r.settle(monitor: "m", held: held, levels: l, now: t) { finals.append(f) }
            }
        }
        r.handChanged(monitor: "m", sample: first); ticks(first.at, 600, held: true)
        r.handChanged(monitor: "m", sample: putBack); ticks(putBack.at, 150, held: true)
        r.handChanged(monitor: "m", sample: nil)      // put back to automatic at +3 min: decide clears the offset
        ticks(putBack.at + 180, 600, held: false)
        r.handChanged(monitor: "m", sample: second); ticks(second.at, 600, held: true)
        XCTAssertEqual(finals.map(\.chosen), [63, 72])
        // One day is not enough to suggest...
        XCTAssertEqual(Suggest.candidates(finals, dayOf: Fixture.utcDay), [])
        XCTAssertNil(Suggest.suggestion(monitor: "m", samples: finals, levels: l, steps: [.whole, .whole, .whole],
                                        now: second.at + 600, dismissedUntil: nil, dayOf: Fixture.utcDay))
        // ...but the fit points the right way: blind down lower.
        let bd = Suggest.fit(finals, levels: l, candidates: [.blindDown])[1]
        XCTAssertEqual(bd, 55.88, accuracy: 0.01)
        XCTAssertTrue((35...57).contains(bd), "\(bd)")
    }

    /// The three situations a proposal must leave alone unless the samples cover them: a sunny day with the
    /// blind fully down, a sunny day with it open, an evening with the lights on.
    static let references: [(level: Level, elev: Double, pos: Double, lights: Bool)] = [
        (.blindDown, 30, 0, false), (.day, 30, 100, false), (.night, -6, 100, true),
    ]
    static func referenceTarget(_ l: [Double], _ r: (level: Level, elev: Double, pos: Double, lights: Bool)) -> Int {
        target(day: l[0], blindDown: l[1], night: l[2], elev: r.elev, pos: r.pos, lights: r.lights)
    }

    func testCloudyMorningsMakeNoSuggestion() {
        // The day after's two held changes, replayed on three days with thin daylight (0.5–0.7) at levels 95 / 62 / 75.
        // At blind 40% day and blind down mix to 75.2, the same as night: no level explains the change.
        let l: [Double] = [95, 62, 75]
        let samples = [(4.5, 7.5), (6.0, 6.0), (7.5, 4.5)].enumerated().flatMap { d, e in
            [Fixture.sample(6 + d, 9, elev: e.0, p: 0.40, chosen: 63, levels: l),
             Fixture.sample(6 + d, 15, elev: e.1, p: 0.58, chosen: 72, levels: l)]
        }
        XCTAssertEqual(samples.map(\.auto), [75, 79, 75, 79, 75, 78])
        XCTAssertEqual(Suggest.candidates(samples, dayOf: Fixture.utcDay), [])   // no level reaches 0.55 of the weight
        XCTAssertNil(Suggest.suggestion(monitor: "m", samples: samples, levels: l, steps: [.whole, .whole, .whole],
                                        now: Fixture.t0 + 10 * 86400, dismissedUntil: nil, dayOf: Fixture.utcDay))
    }

    func testReferencesStayPut() {
        // Every fixture that suggests: the evening with the lights on, and the situation of each level not
        // proposed, keep their target within 3 points.
        let clear = (0..<4).map { Fixture.sample($0, 9, elev: 30, p: 0.35, chosen: 70, levels: Self.week) }
        for samples in [Self.weekSamples(), clear] {
            guard let s = Suggest.suggestion(monitor: "m", samples: samples, levels: Self.week, steps: [.whole, .whole, .whole],
                                             now: Fixture.t0 + 5 * 86400, dismissedUntil: nil, dayOf: Fixture.utcDay) else {
                return XCTFail("the fixture should suggest")
            }
            var after = Self.week
            for c in s.changes { after[c.level.rawValue] = c.to }
            let proposed = Set(s.changes.map(\.level))
            for r in Self.references where r.level == .night || !proposed.contains(r.level) {
                XCTAssertLessThanOrEqual(abs(Self.referenceTarget(after, r) - Self.referenceTarget(Self.week, r)), 3, "\(r.level)")
            }
            XCTAssertEqual(Self.referenceTarget(after, Self.references[2]), 80)   // evening: night 75 + the lights' 5
            XCTAssertEqual(Self.referenceTarget(after, Self.references[1]), 100)  // sunny, blind open: day 100
        }
    }
}
```

- [ ] **Step 2: Run them**

Run: `cd mac && swift test --filter SuggestFixtureTests`
Expected: `Executed 5 tests, with 0 failures` (the numbers are listed under *Numbers the fixtures produce* at the top of this plan). If one fails, **do not change an expected value**: the code from Tasks 1–6 differs from the plan; compare it with the plan and fix the code, or stop and report the failing line.

- [ ] **Step 3: Commit**

```bash
git add mac/Tests/DaylitCoreTests/SuggestTests.swift
git commit -m "$(cat <<'MSG'
Mac: test suggestions against the motivating week and the day after

Co-Authored-By: Claude <noreply@anthropic.com>
MSG
)"
```

### Task 8: Swift core: write one monitor's local levels to config.json

Apply needs to change one or two levels of one monitor and keep everything else in the file. `ConfigPatch.apply` (the Settings window's save, same file) rewrites everything the window owns, so this adds a narrower function next to it.

**Files:**
- Modify: `mac/Sources/DaylitCore/ConfigEdit.swift` (append at the end of the file)
- Modify: `mac/Tests/DaylitCoreTests/SuggestTests.swift` (append at the end of the file)

- [ ] **Step 1: Write the failing tests**

Append this to the end of `mac/Tests/DaylitCoreTests/SuggestTests.swift`:

```swift
final class SuggestConfigTests: XCTestCase {
    func json(_ d: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:] }

    func testApplyWritesOneLocalLevelAndKeepsEverythingElse() throws {
        let file = Data("""
        { "source": "sun", "location": { "latitude": 51.48, "longitude": 0.00 }, "custom": true,
          "monitors": [ { "match": "Monitor", "label": "Desk", "day": 100, "blindDown": 78, "night": 75, "contrast": 60 },
                        { "match": "Other", "day": 50 } ] }
        """.utf8)
        let out = try ConfigPatch.setLevels(["blindDown": 61], display: "Generic Monitor", suggestedMatch: "Monitor", in: file)
        let root = json(out)
        let mons = root["monitors"] as? [[String: Any]] ?? []
        XCTAssertEqual(mons.count, 2)
        XCTAssertEqual(mons[0]["blindDown"] as? Int, 61)
        XCTAssertEqual(mons[0]["day"] as? Int, 100)
        XCTAssertEqual(mons[0]["night"] as? Int, 75)
        XCTAssertEqual(mons[0]["label"] as? String, "Desk")
        XCTAssertEqual(mons[0]["contrast"] as? Int, 60)
        XCTAssertEqual(mons[1]["day"] as? Int, 50)
        XCTAssertEqual(root["custom"] as? Bool, true)
        XCTAssertTrue(String(decoding: out, as: UTF8.self).contains("51.48"))
        XCTAssertFalse(String(decoding: out, as: UTF8.self).contains("51.479"))
    }

    func testApplyAddsAnEntryForAMonitorWithoutOne() throws {
        let out = try ConfigPatch.setLevels(["blindDown": 30, "day": 65], display: "Generic Monitor", suggestedMatch: "Monitor",
                                            in: Data(#"{ "source": "sun", "location": { "latitude": 51.48, "longitude": 0 } }"#.utf8))
        let mons = json(out)["monitors"] as? [[String: Any]] ?? []
        XCTAssertEqual(mons.count, 1)
        XCTAssertEqual(mons[0]["match"] as? String, "Monitor")
        XCTAssertEqual(mons[0]["blindDown"] as? Int, 30)
        XCTAssertEqual(mons[0]["day"] as? Int, 65)
        XCTAssertNil(mons[0]["night"])
    }

    func testApplyRefusesAFileThatIsNotAnObject() {
        XCTAssertThrowsError(try ConfigPatch.setLevels(["day": 60], display: "Monitor", suggestedMatch: "Monitor", in: Data("[1]".utf8)))
        XCTAssertThrowsError(try ConfigPatch.setLevels(["day": 60], display: "Monitor", suggestedMatch: "Monitor",
                                                       in: Data(#"{ "monitors": 3 }"#.utf8)))
    }
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `cd mac && swift test --filter SuggestConfigTests`
Expected: the build fails with `error: type 'ConfigPatch' has no member 'setLevels'`.

- [ ] **Step 3: Write the code**

Append this to the end of `mac/Sources/DaylitCore/ConfigEdit.swift` (it uses `ConfigText.relaxed`, `ConfigEditError`, `ConfigPatch.clamp` and `ConfigPatch.round2`, which are already in that file, and `Level` from Task 1):

```swift
extension ConfigPatch {
    /// The file with some of one monitor's local levels changed (keys "day", "blindDown", "night"; whole
    /// numbers, clamped to 0–100) and everything else kept, as a suggestion's Apply needs. The entry is
    /// found as `apply` finds it (its match is part of `display`, the connected display's name); without one,
    /// an entry with `suggestedMatch` is added. Comments are not kept (check ConfigText.hasComments first).
    /// Throws when the file is not a JSON object or the result would not load.
    public static func setLevels(_ levels: [String: Int], display: String, suggestedMatch: String, in original: Data?) throws -> Data {
        var root: [String: Any] = [:]
        if let d = original, !d.isEmpty {
            guard let o = try JSONSerialization.jsonObject(with: ConfigText.relaxed(d)) as? [String: Any] else {
                throw ConfigEditError.notAnObject
            }
            root = o
        }
        if let raw = root["monitors"], !(raw is [[String: Any]]) {
            throw ConfigEditError.invalid("monitors must be a list of objects; fix it with Open Config File")
        }
        var list = root["monitors"] as? [[String: Any]] ?? []
        let i = list.indices.first { j in
            guard let match = list[j]["match"] as? String, !match.isEmpty else { return false }
            return display.localizedCaseInsensitiveContains(match.trimmingCharacters(in: .whitespaces))
        }
        var entry = i.map { list[$0] } ?? ["match": suggestedMatch]
        for (k, v) in levels where Level.allCases.contains(where: { $0.key == k }) { entry[k] = clamp(v) }
        if let i { list[i] = entry } else { list.append(entry) }
        root["monitors"] = list
        // Written as typed: a coordinate read back as a Double would come out as 51.479999999999997.
        if var loc = root["location"] as? [String: Any] {
            for k in ["latitude", "longitude"] { if let v = (loc[k] as? NSNumber)?.doubleValue { loc[k] = round2(v) } }
            root["location"] = loc
        }
        let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let c = try JSONDecoder().decode(Config.self, from: out)
        if let err = c.validate() { throw ConfigEditError.invalid(err) }
        return out
    }
}
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `cd mac && swift test --filter SuggestConfigTests`
Expected: `Executed 3 tests, with 0 failures`. Then `cd mac && swift test` passes (all tests).

- [ ] **Step 5: Commit**

```bash
git add mac/Sources/DaylitCore/ConfigEdit.swift mac/Tests/DaylitCoreTests/SuggestTests.swift
git commit -m "$(cat <<'MSG'
Mac: write one monitor's local levels to config.json, keeping the rest

Co-Authored-By: Claude <noreply@anthropic.com>
MSG
)"
```

### Task 9: Windows core: levels, samples, weights and candidates

The C# mirror of Task 1: same rules, same test names and cases. Creates `windows/Suggest.cs` (namespace `Daylit`, `static partial class Suggest`; later tasks append more `static partial class Suggest { … }` blocks and types at the end of the file) and `windows/tests/SuggestTests.cs`.

**Files:**
- Create: `windows/Suggest.cs`
- Create: `windows/tests/SuggestTests.cs`
- Modify: `windows/tests/Daylit.Tests.csproj`

- [ ] **Step 1: Write the tests**

Create `windows/tests/SuggestTests.cs` with exactly this content (the `SuggestData` helper is used by every later Windows test task):

```csharp
using System.Text.Json.Nodes;
using Xunit;

namespace Daylit.Tests;

/// Samples for the suggestion tests: generic monitor, levels as given, Auto from the real target.
static class SuggestData {
    public const double T0 = 1_793_577_600;   // 2026-11-02 00:00 UTC
    /// Days counted in UTC, so the tests do not depend on the machine's time zone.
    public static int UtcDay(double t) => (int)Math.Floor(t / 86400);
    public static Sample Make(int day, double hour, double elev, double p, int chosen, double[] levels, string monitor = "m", bool lights = false) {
        var t = new Tuning();
        double s = t.Fraction(elev);
        int auto = Rules.Target(levels, p * 100, lights, s, t, elev < t.LightsBoostSunBelow);
        return new Sample(monitor, chosen, auto, s, p, elev, lights, levels, T0 + day * 86400 + hour * 3600);
    }
}

public class SuggestCandidateTests {
    static readonly double[] Levels = [100, 78, 75];

    [Fact]
    public void WeightsSplitDaylightBetweenTheBlindLevelsAndTheRestToNight() {
        var w = Suggest.Weights(1, 0.35);
        Assert.Equal(0.35, w[0], 1e-9); Assert.Equal(0.65, w[1], 1e-9); Assert.Equal(0, w[2], 1e-9);
        var dusk = Suggest.Weights(0.4, 1);
        Assert.Equal(0.4, dusk[0], 1e-9); Assert.Equal(0, dusk[1], 1e-9); Assert.Equal(0.6, dusk[2], 1e-9);
    }

    [Fact]
    public void ABlindExactlyFortyPercentOpenStillCountsForBlindDown() {
        Assert.True(Suggest.Dominates(SuggestData.Make(0, 9, 30, 0.45, 70, Levels), Level.BlindDown));    // weight 0.55
        Assert.False(Suggest.Dominates(SuggestData.Make(0, 9, 30, 0.46, 70, Levels), Level.BlindDown));   // weight 0.54
        Assert.True(Suggest.Dominates(SuggestData.Make(0, 9, 30, 0.40, 70, Levels), Level.BlindDown));
    }

    [Fact]
    public void ALevelNeedsDominantSamplesOnThreeDifferentDays() {
        var twoDays = new[] { 0, 0, 1, 1 }.Select(d => SuggestData.Make(d, 9, 30, 0.35, 70, Levels)).ToList();
        Assert.Empty(Suggest.Candidates(twoDays, SuggestData.UtcDay));
        var threeDays = twoDays.Append(SuggestData.Make(2, 9, 30, 0.35, 70, Levels)).ToList();
        Assert.Equal(new[] { Level.BlindDown }, Suggest.Candidates(threeDays, SuggestData.UtcDay));
    }

    [Fact]
    public void WithoutABlindBlindDownIsNeverACandidate() {
        // No blind: the position is always 100, so blind down carries no weight.
        var days = Enumerable.Range(0, 5).Select(d => SuggestData.Make(d, 12, 30, 1, 70, Levels)).ToList();
        Assert.Equal(new[] { Level.Day }, Suggest.Candidates(days, SuggestData.UtcDay));
    }

    [Fact]
    public void NightNeedsEveningSamples() {
        var evenings = Enumerable.Range(0, 3).Select(d => SuggestData.Make(d, 19, -6, 0, 60, Levels)).ToList();
        Assert.Equal(new[] { Level.Night }, Suggest.Candidates(evenings, SuggestData.UtcDay));
    }
}
```

- [ ] **Step 2: Write the code**

Create `windows/Suggest.cs` with exactly this content:

```csharp
// Suggest new levels from repeated hand changes. Pure: no WPF or Win32, so windows/tests runs every rule here.
// The app records a Sample for each deliberate correction, keeps them in corrections.json and asks
// Suggest.SuggestionFor for a change to offer in the panel. Same rules on macOS (mac/Sources/DaylitCore/Suggest.swift).
using System.Globalization;
using System.Text.Json;

namespace Daylit;

/// The three levels of a monitor, in the order Rules.Target and the config use them.
enum Level { Day = 0, BlindDown = 1, Night = 2 }

static class LevelText {
    public static readonly Level[] All = [Level.Day, Level.BlindDown, Level.Night];
    /// As the panel says it.
    public static string Name(this Level l) => l switch { Level.Day => "day", Level.BlindDown => "blind down", _ => "night" };
    /// The config key: monitors[].day / blindDown / night.
    public static string Key(this Level l) => l switch { Level.Day => "day", Level.BlindDown => "blindDown", _ => "night" };
    /// When this level is the one that counts most.
    public static string Situation(this Level l) => l switch {
        Level.Day => "with the blind open", Level.BlindDown => "with the blind partly or fully down", _ => "in the evening" };
}

/// One deliberate correction by hand. Monitor: the monitor's key (the same key the hold state uses); Chosen: the
/// level the user set; Auto: the automatic target then; S: the daylight fraction the target used,
/// min(Fraction(elev), light); P: blind position / 100; Elev, Lights: so scoring can rerun the target;
/// Levels: [day, blindDown, night] in effect then; At: Unix seconds.
sealed record Sample(string Monitor, int Chosen, int Auto, double S, double P, double Elev, bool Lights, double[] Levels, double At) {
    // A record compares arrays by reference: compare the levels by value.
    public bool Equals(Sample? o) => o is not null && Monitor == o.Monitor && Chosen == o.Chosen && Auto == o.Auto && S == o.S && P == o.P &&
                                     Elev == o.Elev && Lights == o.Lights && At == o.At && Levels.SequenceEqual(o.Levels);
    public override int GetHashCode() => HashCode.Combine(Monitor, Chosen, Auto, At);
}

static partial class Suggest {
    /// A level "carries most of the weight" in a sample from this weight (0.55, so a blind exactly 40% open still counts).
    public const double Dominant = 0.55;
    /// A level is a candidate only with dominant samples on this many local days.
    public const int MinDays = 3;

    /// How much each level counts in the target for a sample: [day, blindDown, night], summing to 1.
    public static double[] Weights(double s, double p) => [s * p, s * (1 - p), 1 - s];

    /// Whether `level` carries most of the weight in this sample.
    public static bool Dominates(Sample x, Level level) => Weights(x.S, x.P)[(int)level] >= Dominant - 1e-9;

    /// The levels the samples can tell apart: dominant samples on at least MinDays different local days.
    public static List<Level> Candidates(IReadOnlyList<Sample> samples, Func<double, int>? dayOf = null) {
        Func<double, int> day = dayOf ?? Rules.LocalDay;
        return LevelText.All.Where(l => samples.Where(x => Dominates(x, l)).Select(x => day(x.At)).Distinct().Count() >= MinDays).ToList();
    }
}
```

- [ ] **Step 3: Let the test project compile the core**

The test project compiles only the app files without WPF (`windows/tests/Daylit.Tests.csproj`). In its first `<ItemGroup>`, after the line `<Compile Include="../Light.cs" Link="App/Light.cs" />`, add:

```xml
    <Compile Include="../Suggest.cs" Link="App/Suggest.cs" />
```

The app project (`windows/Daylit.csproj`) picks up `windows/Suggest.cs` by itself.

- [ ] **Step 4: Check the C# by eye**

There is no `dotnet` here, so read what you wrote once against the plan: every `{` has its `}`, every statement ends with `;`, and nothing outside this task's code changed. Run `cd mac && swift test` only if you touched the Mac (you should not have).

- [ ] **Step 5: Commit, push and let CI run the tests**

```bash
git add windows/Suggest.cs windows/tests/SuggestTests.cs windows/tests/Daylit.Tests.csproj
git commit -m "$(cat <<'MSG'
Windows: suggestion core with samples, level weights and candidates

Co-Authored-By: Claude <noreply@anthropic.com>
MSG
)"
```

```bash
git push
gh run list --branch feature/suggest-levels --limit 1
gh run watch <run-id> --exit-status
```

Expected: the `windows` job's *Test (Rules, Config)* step passes (it now also runs `Suggest*Tests`). If it fails: `gh run view <run-id> --log-failed | head -80`, fix, commit (`Windows: fix …`), push, watch again. The macOS job is unaffected.

### Task 10: Windows core: the fit

The C# mirror of Task 2: same rules, same test names and cases. 

**Files:**
- Modify: `windows/Suggest.cs` (append at the end of the file)
- Modify: `windows/tests/SuggestTests.cs` (append at the end of the file)

- [ ] **Step 1: Write the tests**

Append this to the end of `windows/tests/SuggestTests.cs`:

```csharp
public class SuggestFitTests {
    [Fact]
    public void ExactSyntheticDataRecoversTheLevels() {
        // Every mix of sun and blind, from levels 90 / 50 / 30, many times over so the pull hardly counts.
        double[] truth = [90, 50, 30];
        var t = new Tuning();
        var samples = new List<Sample>();
        for (int r = 0; r < 25; r++)
            foreach (var elev in new[] { -3.0, 4.5, 12, 30 })
                foreach (var p in new[] { 0.0, 0.5, 1 }) {
                    double s = t.Fraction(elev);
                    var w = Suggest.Weights(s, p);
                    double chosen = w[0] * truth[0] + w[1] * truth[1] + w[2] * truth[2];
                    samples.Add(new Sample("m", (int)Math.Round(chosen, MidpointRounding.AwayFromZero), 0, s, p, elev, false, [70, 40, 20], 0));
                }
        var f = Suggest.Fit(samples, [70, 40, 20], [Level.Day, Level.BlindDown, Level.Night]);
        Assert.Equal(90, f[0], 1.0); Assert.Equal(50, f[1], 1.0); Assert.Equal(30, f[2], 1.0);
    }

    [Fact]
    public void ALevelThatIsNotACandidateStaysPut() {
        double[] levels = [100, 78, 75];
        var samples = Enumerable.Range(0, 4).Select(d => SuggestData.Make(d, 9, 30, 0.35, 70, levels)).ToList();
        var f = Suggest.Fit(samples, levels, [Level.BlindDown]);
        Assert.Equal(100, f[0]); Assert.Equal(75, f[2]);
        Assert.True(f[1] < 78);
    }

    [Fact]
    public void ThePullKeepsASingleSampleNearTheCurrentValue() {
        // Alone, this sample asks for blind down ≈ 43 ((60 − 0.3 · 100) / 0.7). One sample against the
        // pull of the current 78 moves it less than halfway.
        double[] levels = [100, 78, 75];
        var f = Suggest.Fit([SuggestData.Make(0, 9, 20, 0.3, 60, levels)], levels, [Level.BlindDown]);
        Assert.Equal(66.443, f[1], 0.01);
        Assert.True(f[1] > (42.857 + 78) / 2);
    }

    [Fact]
    public void AFitIsClampedToTheRange() {
        double[] levels = [100, 78, 75];
        var high = Enumerable.Range(0, 12).Select(d => SuggestData.Make(d % 3, 12, 30, 1, 99, levels)).ToList();
        Assert.True(Suggest.Fit(high, levels, [Level.Day])[0] <= 100);
    }
}
```

- [ ] **Step 2: Write the code**

Append this to the end of `windows/Suggest.cs`:

```csharp
static partial class Suggest {
    /// Least squares for the candidate levels, the others held at their current values, with a pull of
    /// weight 1 toward the current value (as one extra sample at the current level):
    ///     minimise Σ (chosen − x·L)² + Σ_candidates (L_k − current_k)²
    /// Returns all three levels, each fitted one clamped to 0–100 (not rounded: see RoundToStep).
    public static double[] Fit(IReadOnlyList<Sample> samples, double[] levels, IReadOnlyList<Level> candidates) {
        int[] c = candidates.Select(l => (int)l).ToArray();
        int n = c.Length;
        if (n == 0 || levels.Length != 3) return (double[])levels.Clone();
        var a = new double[n, n];
        var b = new double[n];
        foreach (var x in samples) {
            var w = Weights(x.S, x.P);
            double y = x.Chosen;
            for (int k = 0; k < 3; k++) if (!c.Contains(k)) y -= w[k] * levels[k];
            for (int i = 0; i < n; i++) {
                b[i] += w[c[i]] * y;
                for (int j = 0; j < n; j++) a[i, j] += w[c[i]] * w[c[j]];
            }
        }
        for (int i = 0; i < n; i++) { a[i, i] += 1; b[i] += levels[c[i]]; }   // the pull toward the current value
        var solved = Solve(a, b);
        var o = (double[])levels.Clone();
        for (int i = 0; i < n; i++) o[c[i]] = Math.Clamp(solved[i], 0, 100);
        return o;
    }

    /// Gaussian elimination with partial pivoting. The pull adds 1 to the diagonal, so the matrix is
    /// positive definite and no pivot is 0. Changes `a` and `b`.
    static double[] Solve(double[,] a, double[] b) {
        int n = b.Length;
        for (int col = 0; col < n; col++) {
            int piv = col;
            for (int r = col + 1; r < n; r++) if (Math.Abs(a[r, col]) > Math.Abs(a[piv, col])) piv = r;
            if (piv != col) {
                for (int k = 0; k < n; k++) (a[col, k], a[piv, k]) = (a[piv, k], a[col, k]);
                (b[col], b[piv]) = (b[piv], b[col]);
            }
            for (int r = 0; r < n; r++) {
                if (r == col) continue;
                double f = a[r, col] / a[col, col];
                for (int k = col; k < n; k++) a[r, k] -= f * a[col, k];
                b[r] -= f * b[col];
            }
        }
        var x = new double[n];
        for (int i = 0; i < n; i++) x[i] = b[i] / a[i, i];
        return x;
    }
}
```

- [ ] **Step 3: Check the C# by eye**

There is no `dotnet` here, so read what you wrote once against the plan: every `{` has its `}`, every statement ends with `;`, and nothing outside this task's code changed. Run `cd mac && swift test` only if you touched the Mac (you should not have).

- [ ] **Step 4: Commit, push and let CI run the tests**

```bash
git add windows/Suggest.cs windows/tests/SuggestTests.cs
git commit -m "$(cat <<'MSG'
Windows: fit candidate levels by least squares with a pull to the current value

Co-Authored-By: Claude <noreply@anthropic.com>
MSG
)"
```

```bash
git push
gh run list --branch feature/suggest-levels --limit 1
gh run watch <run-id> --exit-status
```

Expected: the `windows` job's *Test (Rules, Config)* step passes (it now also runs `Suggest*Tests`). If it fails: `gh run view <run-id> --log-failed | head -80`, fix, commit (`Windows: fix …`), push, watch again. The macOS job is unaffected.

### Task 11: Windows core: rounding to what can be stored

The C# mirror of Task 3: same rules, same test names and cases. 

**Files:**
- Modify: `windows/Suggest.cs` (append at the end of the file)
- Modify: `windows/tests/SuggestTests.cs` (append at the end of the file)

- [ ] **Step 1: Write the tests**

Append this to the end of `windows/tests/SuggestTests.cs`:

```csharp
public class SuggestRoundingTests {
    [Fact]
    public void ALocalLevelRoundsToAWholeNumber() {
        Assert.Equal(61, Suggest.RoundToStep(61.42, NumberStep.Whole));
        Assert.Equal(62, Suggest.RoundToStep(61.5, NumberStep.Whole));
        Assert.Equal(0, Suggest.RoundToStep(-3, NumberStep.Whole));
        Assert.Equal(100, Suggest.RoundToStep(104, NumberStep.Whole));
    }

    [Fact]
    public void AHomeAssistantLevelRoundsToItsStepInsideItsRange() {
        var st = new NumberStep(10, 90, 5);
        Assert.Equal(60, Suggest.RoundToStep(62.4, st));
        Assert.Equal(65, Suggest.RoundToStep(63, st));
        Assert.Equal(10, Suggest.RoundToStep(3, st));
        Assert.Equal(90, Suggest.RoundToStep(97, st));
        Assert.Equal(61.5, Suggest.RoundToStep(61.3, new NumberStep(0, 100, 0.5)));
        Assert.Equal(100, Suggest.RoundToStep(120, new NumberStep(0, 255, 1)));   // never above 100
    }

    [Fact]
    public void TheStepIsReadFromTheEntityAttributes() {
        Assert.Equal((NumberStep?)new NumberStep(10, 90, 5),
            NumberStep.Parse("""{"entity_id": "input_number.x", "state": "62.0", "attributes": {"min": 10, "max": 90, "step": 5, "mode": "slider"}}"""));
        Assert.Null(NumberStep.Parse("""{"state": "62.0", "attributes": {"min": 0}}"""));
        Assert.Null(NumberStep.Parse("""{"state": "62.0", "attributes": {"min": 0, "max": 100, "step": 0}}"""));
        Assert.Null(NumberStep.Parse("not json"));
    }
}
```

- [ ] **Step 2: Write the code**

Append this to the end of `windows/Suggest.cs`:

```csharp
/// The values a level can be stored as. A Home Assistant input_number has its own min, max and step;
/// a local level is a whole number 0–100.
readonly record struct NumberStep(double Min, double Max, double Step) {
    public static readonly NumberStep Whole = new(0, 100, 1);

    /// From the answer to GET /api/states/<input_number>: its min, max and step attributes. null when one is missing.
    public static NumberStep? Parse(string? json) {
        try {
            using var d = JsonDocument.Parse(json ?? "");
            if (d.RootElement.ValueKind != JsonValueKind.Object || !d.RootElement.TryGetProperty("attributes", out var a)
                || a.ValueKind != JsonValueKind.Object) return null;
            if (!Num(a, "min", out double lo) || !Num(a, "max", out double hi) || !Num(a, "step", out double st) || st <= 0 || hi < lo) return null;
            return new NumberStep(lo, hi, st);
        } catch (JsonException) { return null; }
    }

    static bool Num(JsonElement o, string key, out double v) {
        v = 0;
        return o.TryGetProperty(key, out var e) && e.ValueKind == JsonValueKind.Number && e.TryGetDouble(out v);
    }
}

static partial class Suggest {
    /// The nearest value `st` accepts, inside both its range and 0–100. Halves round up.
    public static double RoundToStep(double v, NumberStep st) {
        double lo = Math.Max(st.Min, 0), hi = Math.Min(st.Max, 100);
        double first = Math.Ceiling((lo - st.Min) / st.Step - 1e-9), last = Math.Floor((hi - st.Min) / st.Step + 1e-9);
        if (last < first) return Math.Min(Math.Max(v, lo), hi);   // a step coarser than the range: just clamp
        double n = Math.Min(Math.Max(Math.Round((v - st.Min) / st.Step, MidpointRounding.AwayFromZero), first), last);
        return Math.Round((st.Min + n * st.Step) * 1e6, MidpointRounding.AwayFromZero) / 1e6;   // no 61.500000001 from the multiplication
    }
}
```

- [ ] **Step 3: Check the C# by eye**

There is no `dotnet` here, so read what you wrote once against the plan: every `{` has its `}`, every statement ends with `;`, and nothing outside this task's code changed. Run `cd mac && swift test` only if you touched the Mac (you should not have).

- [ ] **Step 4: Commit, push and let CI run the tests**

```bash
git add windows/Suggest.cs windows/tests/SuggestTests.cs
git commit -m "$(cat <<'MSG'
Windows: round a proposed level to the Home Assistant step or a whole number

Co-Authored-By: Claude <noreply@anthropic.com>
MSG
)"
```

```bash
git push
gh run list --branch feature/suggest-levels --limit 1
gh run watch <run-id> --exit-status
```

Expected: the `windows` job's *Test (Rules, Config)* step passes (it now also runs `Suggest*Tests`). If it fails: `gh run view <run-id> --log-failed | head -80`, fix, commit (`Windows: fix …`), push, watch again. The macOS job is unaffected.

### Task 12: Windows core: scoring, the trigger and the sentence

The C# mirror of Task 4: same rules, same test names and cases. 

**Files:**
- Modify: `windows/Suggest.cs` (append at the end of the file)
- Modify: `windows/tests/SuggestTests.cs` (append at the end of the file)

- [ ] **Step 1: Write the tests**

Append this to the end of `windows/tests/SuggestTests.cs`:

```csharp
public class SuggestTriggerTests {
    static readonly double[] Levels = [100, 78, 75];
    static readonly NumberStep?[] Local = [NumberStep.Whole, NumberStep.Whole, NumberStep.Whole];
    static readonly double Later = SuggestData.T0 + 5 * 86400;

    [Fact]
    public void ScoringRunsTheRealTargetIncludingTheLightsBoost() {
        // Sun 0° (daylight 0.2), lights on: the blend gives 30.4, the boost lifts it to 35.
        var x = new Sample("m", 35, 35, 0.2, 1, 0, true, [32, 32, 30], 0);
        Assert.Equal(0, Suggest.MeanAbsError([x], [32, 32, 30]));
        Assert.Equal(5, Suggest.MeanAbsError([x with { Lights = false }], [32, 32, 30]));
    }

    [Fact]
    public void AMoveUnderFivePointsIsNotProposed() {
        // Blind fully down, three days at 74 against 78: the fit gives 75, which would cut the error from 4 to 1.
        var samples = Enumerable.Range(0, 3).Select(d => SuggestData.Make(d, 9, 30, 0, 74, Levels)).ToList();
        Assert.Equal(75, Suggest.Fit(samples, Levels, [Level.BlindDown])[1], 1e-9);
        Assert.Equal(3, Suggest.MeanAbsError(samples, Levels) - Suggest.MeanAbsError(samples, [100, 75, 75]));
        Assert.Null(Suggest.SuggestionFor("m", samples, Levels, Local, Later, null, dayOf: SuggestData.UtcDay));
    }

    [Fact]
    public void AMoveThatDoesNotCutTheErrorByThreeIsNotProposed() {
        // Half the changes ask for 20 less, half for none: blind down moves 11, but the mean error stays 10.
        var samples = Enumerable.Range(0, 3).SelectMany(d => new[] { 66, 86 }.Select(c => SuggestData.Make(d, 9, 30, 0.35, c, Levels))).ToList();
        Assert.Equal(67, Math.Round(Suggest.Fit(samples, Levels, [Level.BlindDown])[1], MidpointRounding.AwayFromZero));
        Assert.Equal(10, Suggest.MeanAbsError(samples, [100, 67, 75]));
        Assert.Null(Suggest.SuggestionFor("m", samples, Levels, Local, Later, null, dayOf: SuggestData.UtcDay));
    }

    [Fact]
    public void AClearPatternIsProposedWithItsSentence() {
        var samples = Enumerable.Range(0, 4).Select(d => SuggestData.Make(d, 9, 30, 0.35, 70, Levels)).ToList();   // auto 86
        var s = Suggest.SuggestionFor("m", samples, Levels, Local, Later, null, dayOf: SuggestData.UtcDay);
        Assert.NotNull(s);
        Assert.Equal(new[] { Level.BlindDown }, s!.Changes.Select(c => c.Level));
        Assert.Equal(16, s.Amount);
        Assert.True(s.Lower);
        Assert.Equal(4, s.Days);
        Assert.Equal(4, s.Samples);
        string to = Suggestion.Fmt(s.Changes[0].To);
        Assert.Equal($"You lower Monitor by about 16 with the blind partly or fully down. Set blind down 78 → {to}?", s.Sentence("Monitor"));
        Assert.Equal($"suggest: Monitor blind down 78 → {to} (4 changes on 4 days)", s.LogLine("Monitor"));
    }

    [Fact]
    public void OtherMonitorsAndUnavailableLevelsAreLeftOut() {
        var samples = Enumerable.Range(0, 4).Select(d => SuggestData.Make(d, 9, 30, 0.35, 70, Levels)).ToList();
        Assert.Null(Suggest.SuggestionFor("other", samples, Levels, Local, Later, null, dayOf: SuggestData.UtcDay));
        // Blind down comes from Home Assistant and is unavailable right now.
        Assert.Null(Suggest.SuggestionFor("m", samples, Levels, [NumberStep.Whole, null, NumberStep.Whole], Later, null, dayOf: SuggestData.UtcDay));
    }

    [Fact]
    public void NotNowHidesTheSuggestionForSevenDays() {
        var samples = Enumerable.Range(0, 4).Select(d => SuggestData.Make(d, 9, 30, 0.35, 70, Levels)).ToList();
        double until = Later + Suggest.NotNow;
        Assert.Equal(7 * 86400, Suggest.NotNow);
        Assert.Null(Suggest.SuggestionFor("m", samples, Levels, Local, until - 60, until, dayOf: SuggestData.UtcDay));
        Assert.NotNull(Suggest.SuggestionFor("m", samples, Levels, Local, until, until, dayOf: SuggestData.UtcDay));
    }

    [Fact]
    public void TwoLevelsAreListedMainFirst() {
        var s = new Suggestion("m", [new LevelChange(Level.BlindDown, 78, 62), new LevelChange(Level.Day, 100, 95)], 12, true, 12, 4);
        Assert.Equal("You lower Monitor by about 12 with the blind partly or fully down. Set blind down 78 → 62, day 100 → 95?", s.Sentence("Monitor"));
        Assert.Equal("62.5", Suggestion.Fmt(62.5));
        var up = new Suggestion("m", [new LevelChange(Level.Night, 20, 30)], 8, false, 3, 3);
        Assert.Equal("You raise Monitor by about 8 in the evening. Set night 20 → 30?", up.Sentence("Monitor"));
    }
}
```

- [ ] **Step 2: Write the code**

Append this to the end of `windows/Suggest.cs`:

```csharp
/// One level to change: from its current value to the proposed one.
readonly record struct LevelChange(Level Level, double From, double To);

/// What the panel offers for one monitor. Monitor: its key; Changes: the main level (the one that moves most)
/// first; Amount: how far the user moves it, the mean of chosen − auto where the main level dominates, rounded,
/// no sign; Lower: the user lowers it (true) or raises it; Samples, Days: the hand changes behind it.
sealed record Suggestion(string Monitor, IReadOnlyList<LevelChange> Changes, int Amount, bool Lower, int Samples, int Days) {
    // A record compares lists by reference: compare the changes by value.
    public bool Equals(Suggestion? o) => o is not null && Monitor == o.Monitor && Amount == o.Amount && Lower == o.Lower &&
                                         Samples == o.Samples && Days == o.Days && Changes.SequenceEqual(o.Changes);
    public override int GetHashCode() => HashCode.Combine(Monitor, Amount, Lower, Samples, Days);

    public Level Main => Changes[0].Level;
    /// "blind down 78 → 62, day 100 → 95"
    public string ChangeText => string.Join(", ", Changes.Select(ch => $"{ch.Level.Name()} {Fmt(ch.From)} → {Fmt(ch.To)}"));
    /// The panel line: "You lower Monitor by about 12 with the blind partly or fully down. Set blind down 78 → 62?"
    public string Sentence(string label) => $"You {(Lower ? "lower" : "raise")} {label} by about {Amount} {Main.Situation()}. Set {ChangeText}?";
    /// "suggest: Monitor blind down 78 → 62 (12 changes on 4 days)"
    public string LogLine(string label) => $"suggest: {label} {ChangeText} ({Samples} changes on {Days} days)";

    /// A whole number without decimals, otherwise one decimal (an input_number with step 0.5).
    public static string Fmt(double v) => v == Math.Round(v) ? ((long)v).ToString(CultureInfo.InvariantCulture) : v.ToString("0.0", CultureInfo.InvariantCulture);
}

static partial class Suggest {
    /// A proposed level must move at least this much after rounding...
    public const double MinMove = 5;
    /// ...and the proposed levels must lower the mean absolute error by at least this much.
    public const double MinGain = 3;
    /// "Not now" hides a monitor's suggestions this long (seconds).
    public const double NotNow = 7 * 86400;

    /// The two level lists are the same (an input_number may hold decimals).
    public static bool SameLevels(double[]? a, double[]? b) =>
        a != null && b != null && a.Length == b.Length && a.Zip(b).All(p => Math.Abs(p.First - p.Second) < 1e-6);

    /// The real target (boost, clamp, rounding) for a sample's moment with other levels. S already holds the
    /// cloud cap, so light is 1; the boost rule is the tick's: the sun below lightsBoostSunBelow.
    public static int Rerun(Sample x, double[] levels, Tuning t) =>
        Rules.Target(levels, x.P * 100, x.Lights, x.S, t, x.Elev < t.LightsBoostSunBelow, 1);

    /// Mean of |target − chosen| over the samples, with `levels`.
    public static double MeanAbsError(IReadOnlyList<Sample> samples, double[] levels, Tuning? t = null) {
        if (samples.Count == 0) return 0;
        t ??= new Tuning();
        var tuning = t;
        return samples.Sum(x => (double)Math.Abs(Rerun(x, levels, tuning) - x.Chosen)) / samples.Count;
    }

    /// The change to offer for one monitor, or null.
    /// all: every recorded sample (other monitors' and stale ones are ignored here); levels: the monitor's
    /// [day, blindDown, night] now; steps: per level, what it can be stored as, null = it comes from Home
    /// Assistant and is unavailable now; dismissedUntil: "Not now" was clicked, nothing until this time.
    public static Suggestion? SuggestionFor(string monitor, IReadOnlyList<Sample> all, double[] levels, NumberStep?[] steps, double now,
                                            double? dismissedUntil, Tuning? t = null, Func<double, int>? dayOf = null) {
        if (dismissedUntil is double d && now < d) return null;
        if (levels.Length != 3 || steps.Length != 3) return null;
        t ??= new Tuning();
        Func<double, int> day = dayOf ?? Rules.LocalDay;
        var mine = all.Where(x => x.Monitor == monitor && SameLevels(x.Levels, levels)).ToList();
        var cand = Candidates(mine, day).Where(l => steps[(int)l] != null).ToList();
        if (cand.Count == 0) return null;
        var fitted = Fit(mine, levels, cand);
        var proposed = (double[])levels.Clone();
        var changes = new List<LevelChange>();
        foreach (var l in cand) {
            double v = RoundToStep(fitted[(int)l], steps[(int)l]!.Value);
            if (Math.Abs(v - levels[(int)l]) >= MinMove - 1e-9) {
                proposed[(int)l] = v;
                changes.Add(new LevelChange(l, levels[(int)l], v));
            }
        }
        if (changes.Count == 0) return null;
        double gain = MeanAbsError(mine, levels, t) - MeanAbsError(mine, proposed, t);
        if (gain < MinGain - 1e-9) return null;
        var main = changes[0];   // the one that moves most; the first of them on a tie
        foreach (var ch in changes) if (Math.Abs(ch.To - ch.From) > Math.Abs(main.To - main.From)) main = ch;
        var mainLevel = main.Level;
        var ordered = new List<LevelChange> { main };
        ordered.AddRange(changes.Where(ch => ch.Level != mainLevel));
        var dom = mine.Where(x => Dominates(x, mainLevel)).ToList();
        double mean = dom.Sum(x => (double)(x.Chosen - x.Auto)) / Math.Max(dom.Count, 1);
        return new Suggestion(monitor, ordered, (int)Math.Round(Math.Abs(mean), MidpointRounding.AwayFromZero), mean < 0,
                              mine.Count, mine.Select(x => day(x.At)).Distinct().Count());
    }
}
```

- [ ] **Step 3: Check the C# by eye**

There is no `dotnet` here, so read what you wrote once against the plan: every `{` has its `}`, every statement ends with `;`, and nothing outside this task's code changed. Run `cd mac && swift test` only if you touched the Mac (you should not have).

- [ ] **Step 4: Commit, push and let CI run the tests**

```bash
git add windows/Suggest.cs windows/tests/SuggestTests.cs
git commit -m "$(cat <<'MSG'
Windows: decide when to suggest by rerunning the real target

Co-Authored-By: Claude <noreply@anthropic.com>
MSG
)"
```

```bash
git push
gh run list --branch feature/suggest-levels --limit 1
gh run watch <run-id> --exit-status
```

Expected: the `windows` job's *Test (Rules, Config)* step passes (it now also runs `Suggest*Tests`). If it fails: `gh run view <run-id> --log-failed | head -80`, fix, commit (`Windows: fix …`), push, watch again. The macOS job is unaffected.

### Task 13: Windows core: the recorder and what is not recorded

The C# mirror of Task 5: same rules, same test names and cases. 

**Files:**
- Modify: `windows/Suggest.cs` (append at the end of the file)
- Modify: `windows/tests/SuggestTests.cs` (append at the end of the file)

- [ ] **Step 1: Write the tests**

Append this to the end of `windows/tests/SuggestTests.cs`:

```csharp
public class SuggestRecorderTests {
    static readonly double[] Levels = [100, 78, 75];

    [Fact]
    public void AChangeSettlesAfterFiveMinutes() {
        var r = new Recorder();
        var x = SuggestData.Make(0, 9, 30, 0.35, 70, Levels);
        r.HandChanged("m", x);
        Assert.Null(r.Settle("m", true, Levels, x.At + 299));
        Assert.Equal(x, r.Settle("m", true, Levels, x.At + 300));
        Assert.Null(r.Settle("m", true, Levels, x.At + 330));   // once
    }

    [Fact]
    public void ASecondChangeWithinFiveMinutesReplacesTheFirst() {
        var r = new Recorder();
        var first = SuggestData.Make(0, 9, 30, 0.35, 70, Levels);
        var second = first with { Chosen = 66, At = first.At + 120 };
        r.HandChanged("m", first);
        Assert.Null(r.Settle("m", true, Levels, first.At + 60));
        r.HandChanged("m", second);
        Assert.Null(r.Settle("m", true, Levels, first.At + 300));   // 3 minutes after the second
        Assert.Equal(66, r.Settle("m", true, Levels, second.At + 300)?.Chosen);
    }

    [Fact]
    public void AClearedOffsetDropsThePendingChange() {
        var r = new Recorder();
        var x = SuggestData.Make(0, 9, 30, 0.35, 70, Levels);
        r.HandChanged("m", x);
        Assert.Null(r.Settle("m", false, Levels, x.At + 60));
        Assert.Null(r.Settle("m", true, Levels, x.At + 400));
        // A level change drops it too.
        r.HandChanged("m", x);
        Assert.Null(r.Settle("m", true, [100, 62, 75], x.At + 400));
        Assert.Empty(r.Pending);
        // And so does an excluded change (or one put back) right after it.
        r.HandChanged("m", x);
        r.HandChanged("m", null);
        Assert.Null(r.Settle("m", true, Levels, x.At + 400));
    }

    static Sample? Make(int chosen = 70, int auto = 86, double elev = 30, bool lights = false, double[]? levels = null, SampleContext context = default) =>
        Suggest.MakeSample("m", chosen, auto, elev, 35, lights, 1, levels ?? Levels, new Tuning(), 1000, context);

    [Fact]
    public void AnOrdinaryHandChangeIsASample() {
        var x = Suggest.MakeSample("m", 70, 86, 30, 35, false, 0.8, Levels, new Tuning(), 1000, new SampleContext());
        Assert.Equal(new Sample("m", 70, 86, 0.8, 0.35, 30, false, Levels, 1000), x);
    }

    [Fact]
    public void EachExclusionIsNotRecorded() {
        Assert.NotNull(Make());
        Assert.Null(Make(context: new SampleContext(Follower: true)));
        Assert.Null(Make(context: new SampleContext(WriteFailed: true)));
        Assert.Null(Make(context: new SampleContext(Idle: true)));
        Assert.Null(Make(context: new SampleContext(Paused: true)));
        Assert.Null(Make(context: new SampleContext(SunFallback: true)));
        Assert.Null(Make(0)); Assert.Null(Make(100));
        Assert.Null(Make(auto: 0)); Assert.Null(Make(auto: 100));
        // The lights boost decided the target: sun 0°, lights on, night 30 + 5 above the blend.
        Assert.Null(Make(40, auto: 35, elev: 0, lights: true, levels: [32, 32, 30]));
        Assert.NotNull(Make(40, auto: 35, elev: 0, lights: false, levels: [32, 32, 30]));
    }

    [Fact]
    public void AHomeAssistantSetIsNotAHandChange() {
        var before = new Hold(null, 80, 80);
        var after = new Hold(null, 50, 80, -30, 1, 1000);
        Assert.True(Suggest.IsHandChange(before, after, null, 1000));
        Assert.False(Suggest.IsHandChange(before, after, 50, 1000));
        Assert.False(Suggest.IsHandChange(after, after, null, 1030));   // held from an earlier tick
    }

    [Fact]
    public void DecideMarksAHandChangeWithItsTime() {
        var before = new Hold(null, 86, 86);
        var step = Rules.Decide(70, 86, null, before, true, true, 1, touched: true, now: 1000, dayOf: _ => 0);
        Assert.Equal(-16, step.State.Offset);
        Assert.True(Suggest.IsHandChange(before, step.State, step.Remote, 1000));
    }

    [Fact]
    public void ApplyClearsTheOffsetSoTheCorrectionIsNotDoubled() {
        // Target 85, the user set 70 (offset −15). The new levels give 70.
        var held = new Hold(null, 70, 85, -15, 1, 1000);
        var kept = Rules.Decide(70, 70, null, held, true, true, 1, touched: false, now: 1060, dayOf: _ => 0);
        Assert.Equal(55, kept.Applied);   // what would happen without clearing
        var cleared = Rules.Decide(70, 70, null, Suggest.AfterApply(held), true, true, 1, touched: false, now: 1060, dayOf: _ => 0);
        Assert.Equal(70, cleared.Applied);
        Assert.Null(cleared.Write);
        Assert.Null(cleared.State.Offset);
    }
}
```

- [ ] **Step 2: Write the code**

Append this to the end of `windows/Suggest.cs`:

```csharp
/// Why a tick's hand change is not a sample (each of these hides what the user really wanted).
/// Follower: a linked follower, its level comes from the leader; WriteFailed: this tick's write to the monitor
/// failed; Idle: this PC is idle; Paused: paused on battery; SunFallback: the source is Home Assistant but it is
/// down, the sun is standing in.
readonly record struct SampleContext(bool Follower = false, bool WriteFailed = false, bool Idle = false, bool Paused = false, bool SunFallback = false);

/// Hand changes waiting to settle, one per monitor. A change becomes a sample after Suggest.SettleSeconds with
/// no further hand change on that monitor, while its offset is still held.
sealed class Recorder {
    readonly Dictionary<string, Sample> pending = new();
    public IReadOnlyDictionary<string, Sample> Pending => pending;

    /// A hand change on `monitor` this tick. `sample` is null when the tick may not be recorded (see
    /// Suggest.MakeSample) or the user put it back to automatic: either way it ends the gesture before it.
    public void HandChanged(string monitor, Sample? sample) {
        if (sample == null) pending.Remove(monitor); else pending[monitor] = sample;
    }

    /// Every tick, per monitor. Returns the sample that became final now, if any.
    /// held: the hand-set offset is still set and automatic mode is on (false drops the pending change);
    /// levels: the monitor's levels now (a change drops it too).
    public Sample? Settle(string monitor, bool held, double[] levels, double now) {
        if (!pending.TryGetValue(monitor, out var p)) return null;
        if (!held || !Suggest.SameLevels(p.Levels, levels)) { pending.Remove(monitor); return null; }
        if (now - p.At < Suggest.SettleSeconds) return null;
        pending.Remove(monitor);
        return p;
    }

    /// Forget a monitor's pending change.
    public void Drop(string monitor) => pending.Remove(monitor);
}

static partial class Suggest {
    /// A hand change becomes a sample after this long with no further one (seconds).
    public const double SettleSeconds = 300;

    /// The room lights' boost decided the target (it lifted the level above the blend).
    public static bool BoostDecides(double[] l, double elev, double pos, bool lights, Tuning t, double light) {
        if (!lights || elev >= t.LightsBoostSunBelow || l.Length != 3) return false;
        double s = Math.Min(t.Fraction(elev), light);
        double daytime = l[1] + (l[0] - l[1]) * pos / 100;
        return l[2] + t.LightsBoost > l[2] + (daytime - l[2]) * s;
    }

    /// The sample for a tick where Decide recorded a new hand-set level, or null when it may not be recorded:
    /// see SampleContext, the lights boost deciding the target, or chosen / auto at 0 or 100 (the clamp hides
    /// the true wish). pos is the blind position 0–100 (100 without a blind), light the cloud cap (1 without a sensor).
    public static Sample? MakeSample(string monitor, int chosen, int auto, double elev, double pos, bool lights, double light,
                                     double[] levels, Tuning t, double now, SampleContext context) {
        if (context.Follower || context.WriteFailed || context.Idle || context.Paused || context.SunFallback) return null;
        if (levels.Length != 3 || chosen < 1 || chosen > 99 || auto < 1 || auto > 99) return null;
        if (BoostDecides(levels, elev, pos, lights, t, light)) return null;
        return new Sample(monitor, chosen, auto, Math.Min(t.Fraction(elev), light), Math.Clamp(pos, 0, 100) / 100, elev, lights, levels, now);
    }

    /// Whether this tick's Decide took a new hand-set level (moved by hand): it stamps OffsetAt with now.
    /// A level from the Home Assistant "set" helper (`remote`) stamps it too, but is not a hand change.
    public static bool IsHandChange(Hold before, Hold after, int? remote, double now) =>
        remote == null && now > 0 && after.OffsetAt == now && before.OffsetAt != now;

    /// The hold state after Apply: the hand-set offset is cleared, or it would be applied again on top of the
    /// new level (target 85, set 70, new level gives 70: the monitor would go to 55).
    public static Hold AfterApply(Hold h) => h with { LastSet = null, Offset = null, OffsetSun = null, OffsetAt = null };
}
```

- [ ] **Step 3: Check the C# by eye**

There is no `dotnet` here, so read what you wrote once against the plan: every `{` has its `}`, every statement ends with `;`, and nothing outside this task's code changed. Run `cd mac && swift test` only if you touched the Mac (you should not have).

- [ ] **Step 4: Commit, push and let CI run the tests**

```bash
git add windows/Suggest.cs windows/tests/SuggestTests.cs
git commit -m "$(cat <<'MSG'
Windows: record a hand change once it has held five minutes

Co-Authored-By: Claude <noreply@anthropic.com>
MSG
)"
```

```bash
git push
gh run list --branch feature/suggest-levels --limit 1
gh run watch <run-id> --exit-status
```

Expected: the `windows` job's *Test (Rules, Config)* step passes (it now also runs `Suggest*Tests`). If it fails: `gh run view <run-id> --log-failed | head -80`, fix, commit (`Windows: fix …`), push, watch again. The macOS job is unaffected.

### Task 14: Windows core: stale and old samples, corrections.json

The C# mirror of Task 6: same rules, same test names and cases. 

**Files:**
- Modify: `windows/Suggest.cs` (append at the end of the file)
- Modify: `windows/tests/SuggestTests.cs` (append at the end of the file)

- [ ] **Step 1: Write the tests**

Append this to the end of `windows/tests/SuggestTests.cs`:

```csharp
public class SuggestStoreTests {
    [Fact]
    public void StaleSamplesAreDroppedWhenTheLevelsChange() {
        var old = SuggestData.Make(0, 9, 30, 0.35, 70, [100, 78, 75]);
        var fresh = SuggestData.Make(1, 9, 30, 0.35, 70, [100, 62, 75]);
        var unplugged = SuggestData.Make(0, 9, 30, 0.35, 70, [90, 50, 30], monitor: "other");
        var kept = Suggest.DropStale([old, fresh, unplugged], new Dictionary<string, double[]> { ["m"] = [100, 62, 75] });
        Assert.Equal(new[] { fresh, unplugged }, kept);
        // A suggestion only counts samples taken with the levels in effect now.
        Assert.True(Suggest.SameLevels([100, 62.0000001, 75], [100, 62, 75]));
        Assert.False(Suggest.SameLevels([100, 62.5, 75], [100, 62, 75]));
    }

    [Fact]
    public void SamplesOlderThanFourteenDaysAreDropped() {
        double now = SuggestData.T0 + 20 * 86400;
        var a = SuggestData.Make(5, 9, 30, 0.35, 70, [100, 78, 75]);   // 15 days old
        var b = SuggestData.Make(7, 9, 30, 0.35, 70, [100, 78, 75]);   // 13 days old
        Assert.Equal(new[] { b }, Suggest.DropOld([a, b], now));
    }

    [Fact]
    public void SamplesSurviveTheFile() {
        var x = SuggestData.Make(0, 9, 30, 0.35, 70, [100, 78, 75]);
        Assert.Equal(new[] { x }, Suggest.Decode(Suggest.Encode([x])));
        string text = Suggest.Encode([x]);
        foreach (var key in new[] { "\"monitor\"", "\"chosen\"", "\"auto\"", "\"s\"", "\"p\"", "\"elev\"", "\"lights\"", "\"levels\"", "\"at\"" })
            Assert.Contains(key, text);
        Assert.Empty(Suggest.Decode(null));
        Assert.Empty(Suggest.Decode("broken"));
        Assert.Empty(Suggest.Decode("""{"samples": [{"monitor": "m", "chosen": 70, "auto": 86, "s": 1, "p": 0.35, "elev": 30, "lights": false, "levels": [100, 78], "at": 0}]}"""));
    }
}
```

- [ ] **Step 2: Write the code**

Append this to the end of `windows/Suggest.cs`:

```csharp
/// corrections.json: {"samples": [...]}.
sealed record CorrectionsFile(List<Sample>? Samples);

static partial class Suggest {
    /// Samples older than this are dropped on load and on save (seconds).
    public const double MaxAge = 14 * 86400;

    /// Without the samples older than MaxAge.
    public static List<Sample> DropOld(IEnumerable<Sample> samples, double now) => samples.Where(x => now - x.At <= MaxAge).ToList();

    /// Without the samples whose levels differ from their monitor's levels now (`current`, by monitor key):
    /// after Apply, a change in Settings or of a Home Assistant helper, a level starts from fresh evidence.
    /// Monitors not in `current` (unplugged) keep theirs.
    public static List<Sample> DropStale(IEnumerable<Sample> samples, IReadOnlyDictionary<string, double[]> current) =>
        samples.Where(x => !current.TryGetValue(x.Monitor, out var lv) || SameLevels(lv, x.Levels)).ToList();

    static readonly JsonSerializerOptions Json = new() {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase, PropertyNameCaseInsensitive = true, WriteIndented = true };

    /// The samples in corrections.json; none when it is missing or broken. Entries without three levels are skipped.
    public static List<Sample> Decode(string? text) {
        if (string.IsNullOrWhiteSpace(text)) return new List<Sample>();
        try {
            var f = JsonSerializer.Deserialize<CorrectionsFile>(text, Json);
            return f?.Samples?.Where(x => x is not null && x.Monitor is not null && x.Levels is { Length: 3 }).ToList() ?? new List<Sample>();
        } catch (JsonException) { return new List<Sample>(); }
    }

    /// corrections.json's content.
    public static string Encode(IEnumerable<Sample> samples) => JsonSerializer.Serialize(new CorrectionsFile(samples.ToList()), Json);
}
```

- [ ] **Step 3: Check the C# by eye**

There is no `dotnet` here, so read what you wrote once against the plan: every `{` has its `}`, every statement ends with `;`, and nothing outside this task's code changed. Run `cd mac && swift test` only if you touched the Mac (you should not have).

- [ ] **Step 4: Commit, push and let CI run the tests**

```bash
git add windows/Suggest.cs windows/tests/SuggestTests.cs
git commit -m "$(cat <<'MSG'
Windows: drop stale and old samples and keep them as JSON

Co-Authored-By: Claude <noreply@anthropic.com>
MSG
)"
```

```bash
git push
gh run list --branch feature/suggest-levels --limit 1
gh run watch <run-id> --exit-status
```

Expected: the `windows` job's *Test (Rules, Config)* step passes (it now also runs `Suggest*Tests`). If it fails: `gh run view <run-id> --log-failed | head -80`, fix, commit (`Windows: fix …`), push, watch again. The macOS job is unaffected.

### Task 15: Windows core: the two fixtures

The C# mirror of Task 7. Tests only.

**Files:**
- Modify: `windows/tests/SuggestTests.cs` (append at the end of the file)

- [ ] **Step 1: Write the tests**

Append this to the end of `windows/tests/SuggestTests.cs`:

```csharp
/// Anonymised from one real week: every morning the user lowered the monitor 6–15 points with the blind
/// 30–40% open, with the levels day 100 / blind down 78 / night 75.
public class SuggestFixtureTests {
    static readonly double[] Week = [100, 78, 75];
    static List<Sample> WeekSamples() {
        var l = Week;
        return [
            // Mornings, full daylight, the blind 30–40% open: about 15 lower than the automatic level.
            SuggestData.Make(0, 8.5, 20, 0.30, 70, l), SuggestData.Make(0, 9.5, 24, 0.35, 72, l),
            SuggestData.Make(1, 8.5, 20, 0.35, 70, l), SuggestData.Make(1, 9.0, 22, 0.40, 74, l),
            SuggestData.Make(2, 8.5, 20, 0.30, 71, l), SuggestData.Make(2, 9.5, 24, 0.35, 70, l),
            SuggestData.Make(3, 8.5, 20, 0.35, 72, l), SuggestData.Make(3, 9.0, 22, 0.30, 73, l),
            SuggestData.Make(4, 8.5, 20, 0.40, 75, l), SuggestData.Make(4, 9.5, 24, 0.35, 70, l),
            // Midday with the blind 60% open: a small lowering.
            SuggestData.Make(1, 13, 30, 0.60, 88, l), SuggestData.Make(3, 13, 30, 0.60, 89, l),
            // Late afternoon, blind open, sun low: raised a little.
            SuggestData.Make(1, 16, 9, 1, 98, l),
        ];
    }

    [Fact]
    public void TheWeekHasTheAutomaticLevelsTheUserSaw() =>
        Assert.Equal(new[] { 85, 86, 86, 87, 85, 86, 86, 85, 87, 86, 91, 91, 95 }, WeekSamples().Select(x => x.Auto));

    [Fact]
    public void TheWeekProposesALowerBlindDownOnly() {
        var samples = WeekSamples();
        Assert.Equal(new[] { Level.BlindDown }, Suggest.Candidates(samples, SuggestData.UtcDay));
        Assert.Equal(61.42, Suggest.Fit(samples, Week, [Level.BlindDown])[1], 0.01);
        Assert.Equal(11.54, Suggest.MeanAbsError(samples, Week), 0.01);
        Assert.Equal(3.31, Suggest.MeanAbsError(samples, [100, 61, 75]), 0.01);
        var s = Suggest.SuggestionFor("m", samples, Week, [NumberStep.Whole, NumberStep.Whole, NumberStep.Whole],
                                      SuggestData.T0 + 5 * 86400, null, dayOf: SuggestData.UtcDay);
        Assert.NotNull(s);
        Assert.Equal(new[] { Level.BlindDown }, s!.Changes.Select(c => c.Level));   // night not proposed, day not raised
        double to = s.Changes[0].To;
        Assert.True(to <= 78 - 5);
        Assert.InRange(to, 45, 65);
        Assert.Equal(61, to);
        Assert.Equal(14, s.Amount);
        Assert.Equal("You lower Monitor by about 14 with the blind partly or fully down. Set blind down 78 → 61?", s.Sentence("Monitor"));
        Assert.Equal("suggest: Monitor blind down 78 → 61 (13 changes on 5 days)", s.LogLine("Monitor"));
    }

    [Fact]
    public void TheDayAfterRecordsTwoChangesAndFitsBlindDownLower() {
        // Levels day 95 / blind down 62 / night 75. Two changes held, a third was put back within 3 minutes.
        double[] l = [95, 62, 75];
        var first = SuggestData.Make(5, 8.5, 20, 0.40, 63, l);     // 75 → 63
        var putBack = SuggestData.Make(5, 11, 22, 0.40, 69, l);    // 75 → 69, then back
        var second = SuggestData.Make(5, 15, 4.5, 0.58, 72, l);    // 78 → 72, low afternoon sun
        Assert.Equal(new[] { 75, 75, 78 }, new[] { first.Auto, putBack.Auto, second.Auto });
        var r = new Recorder();
        var finals = new List<Sample>();
        void Ticks(double from, double seconds, bool held) {
            for (double t = from + 30; t <= from + seconds; t += 30)
                if (r.Settle("m", held, l, t) is Sample f) finals.Add(f);
        }
        r.HandChanged("m", first); Ticks(first.At, 600, true);
        r.HandChanged("m", putBack); Ticks(putBack.At, 150, true);
        r.HandChanged("m", null);      // put back to automatic at +3 min: Decide clears the offset
        Ticks(putBack.At + 180, 600, false);
        r.HandChanged("m", second); Ticks(second.At, 600, true);
        Assert.Equal(new[] { 63, 72 }, finals.Select(x => x.Chosen));
        // One day is not enough to suggest...
        Assert.Empty(Suggest.Candidates(finals, SuggestData.UtcDay));
        Assert.Null(Suggest.SuggestionFor("m", finals, l, [NumberStep.Whole, NumberStep.Whole, NumberStep.Whole],
                                          second.At + 600, null, dayOf: SuggestData.UtcDay));
        // ...but the fit points the right way: blind down lower.
        double bd = Suggest.Fit(finals, l, [Level.BlindDown])[1];
        Assert.Equal(55.88, bd, 0.01);
        Assert.InRange(bd, 35, 57);
    }

    /// The three situations a proposal must leave alone unless the samples cover them: a sunny day with the
    /// blind fully down, a sunny day with it open, an evening with the lights on.
    static readonly (Level Level, double Elev, double Pos, bool Lights)[] References = [
        (Level.BlindDown, 30, 0, false), (Level.Day, 30, 100, false), (Level.Night, -6, 100, true),
    ];
    static int ReferenceTarget(double[] l, (Level Level, double Elev, double Pos, bool Lights) r) {
        var t = new Tuning();
        return Rules.Target(l, r.Pos, r.Lights, t.Fraction(r.Elev), t, r.Elev < t.LightsBoostSunBelow);
    }

    [Fact]
    public void CloudyMorningsMakeNoSuggestion() {
        // The day after's two held changes, replayed on three days with thin daylight (0.5–0.7) at levels 95 / 62 / 75.
        // At blind 40% day and blind down mix to 75.2, the same as night: no level explains the change.
        double[] l = [95, 62, 75];
        var elevs = new[] { (Morning: 4.5, Afternoon: 7.5), (Morning: 6.0, Afternoon: 6.0), (Morning: 7.5, Afternoon: 4.5) };
        var samples = elevs.SelectMany((e, d) => new[] {
            SuggestData.Make(6 + d, 9, e.Morning, 0.40, 63, l), SuggestData.Make(6 + d, 15, e.Afternoon, 0.58, 72, l) }).ToList();
        Assert.Equal(new[] { 75, 79, 75, 79, 75, 78 }, samples.Select(x => x.Auto));
        Assert.Empty(Suggest.Candidates(samples, SuggestData.UtcDay));   // no level reaches 0.55 of the weight
        Assert.Null(Suggest.SuggestionFor("m", samples, l, [NumberStep.Whole, NumberStep.Whole, NumberStep.Whole],
                                          SuggestData.T0 + 10 * 86400, null, dayOf: SuggestData.UtcDay));
    }

    [Fact]
    public void ReferencesStayPut() {
        // Every fixture that suggests: the evening with the lights on, and the situation of each level not
        // proposed, keep their target within 3 points.
        var clear = Enumerable.Range(0, 4).Select(d => SuggestData.Make(d, 9, 30, 0.35, 70, Week)).ToList();
        foreach (var samples in new[] { WeekSamples(), clear }) {
            var s = Suggest.SuggestionFor("m", samples, Week, [NumberStep.Whole, NumberStep.Whole, NumberStep.Whole],
                                          SuggestData.T0 + 5 * 86400, null, dayOf: SuggestData.UtcDay);
            Assert.NotNull(s);   // the fixture should suggest
            var after = (double[])Week.Clone();
            foreach (var ch in s!.Changes) after[(int)ch.Level] = ch.To;
            var proposed = s.Changes.Select(ch => ch.Level).ToHashSet();
            foreach (var r in References.Where(x => x.Level == Level.Night || !proposed.Contains(x.Level)))
                Assert.InRange(Math.Abs(ReferenceTarget(after, r) - ReferenceTarget(Week, r)), 0, 3);
            Assert.Equal(80, ReferenceTarget(after, References[2]));    // evening: night 75 + the lights' 5
            Assert.Equal(100, ReferenceTarget(after, References[1]));   // sunny, blind open: day 100
        }
    }
}
```

- [ ] **Step 2: Commit, push and let CI run them**

```bash
git add windows/tests/SuggestTests.cs
git commit -m "$(cat <<'MSG'
Windows: test suggestions against the motivating week and the day after

Co-Authored-By: Claude <noreply@anthropic.com>
MSG
)"
```

```bash
git push
gh run list --branch feature/suggest-levels --limit 1
gh run watch <run-id> --exit-status
```

Expected: the `windows` job's tests pass with the same numbers as the Mac (see *Numbers the fixtures produce*). If one fails, **do not change an expected value**: find where `windows/Suggest.cs` differs from the plan.

### Task 16: Windows core: write one monitor's local levels to config.json

The C# mirror of Task 8.

**Files:**
- Modify: `windows/Config.cs` (inside `static class ConfigPatch`)
- Modify: `windows/tests/SuggestTests.cs` (append at the end of the file)

- [ ] **Step 1: Write the tests**

Append this to the end of `windows/tests/SuggestTests.cs` (the `using System.Text.Json.Nodes;` it needs is already at the top of the file from Task 9):

```csharp
public class SuggestConfigTests {
    [Fact]
    public void ApplyWritesOneLocalLevelAndKeepsEverythingElse() {
        const string file = """
            { "source": "sun", "location": { "latitude": 51.48, "longitude": 0.00 }, "custom": true,
              "monitors": [ { "match": "Monitor", "label": "Desk", "day": 100, "blindDown": 78, "night": 75, "contrast": 60 },
                            { "match": "Other", "day": 50 } ] }
            """;
        string text = ConfigPatch.SetLevels(new Dictionary<string, int> { ["blindDown"] = 61 }, "Generic Monitor", "Monitor", file);
        var root = JsonNode.Parse(text)!.AsObject();
        var mons = root["monitors"]!.AsArray();
        Assert.Equal(2, mons.Count);
        Assert.Equal(61, mons[0]!["blindDown"]!.GetValue<int>());
        Assert.Equal(100, mons[0]!["day"]!.GetValue<int>());
        Assert.Equal(75, mons[0]!["night"]!.GetValue<int>());
        Assert.Equal("Desk", mons[0]!["label"]!.GetValue<string>());
        Assert.Equal(60, mons[0]!["contrast"]!.GetValue<int>());
        Assert.Equal(50, mons[1]!["day"]!.GetValue<int>());
        Assert.True(root["custom"]!.GetValue<bool>());
        Assert.Contains("51.48", text);
        Assert.DoesNotContain("51.479", text);
    }

    [Fact]
    public void ApplyAddsAnEntryForAMonitorWithoutOne() {
        string text = ConfigPatch.SetLevels(new Dictionary<string, int> { ["blindDown"] = 30, ["day"] = 65 }, "Generic Monitor", "Monitor",
                                            """{ "source": "sun", "location": { "latitude": 51.48, "longitude": 0 } }""");
        var mons = JsonNode.Parse(text)!["monitors"]!.AsArray();
        Assert.Single(mons);
        Assert.Equal("Monitor", mons[0]!["match"]!.GetValue<string>());
        Assert.Equal(30, mons[0]!["blindDown"]!.GetValue<int>());
        Assert.Equal(65, mons[0]!["day"]!.GetValue<int>());
        Assert.Null(mons[0]!["night"]);
    }

    [Fact]
    public void ApplyRefusesAFileThatIsNotAnObject() {
        Assert.Throws<InvalidDataException>(() => ConfigPatch.SetLevels(new Dictionary<string, int> { ["day"] = 60 }, "Monitor", "Monitor", "[1]"));
        Assert.Throws<InvalidDataException>(() => ConfigPatch.SetLevels(new Dictionary<string, int> { ["day"] = 60 }, "Monitor", "Monitor", """{ "monitors": 3 }"""));
    }
}
```

- [ ] **Step 2: Write the code**

In `windows/Config.cs`, inside `static class ConfigPatch`, insert this method right before the line `    /// Two decimals, written exactly as shown in the window.` (it uses `Read`, already in `ConfigPatch`, and `Config.Load`):

```csharp
    /// The file with some of one monitor's local levels changed (keys "day", "blindDown", "night"; whole numbers,
    /// clamped to 0–100) and everything else kept, as a suggestion's Apply needs. The entry is found as Apply finds
    /// it (its match is part of `display`, the monitor's name); without one, an entry with `suggestedMatch` is added.
    /// Comments are not kept (check HasComments first). Throws when the file is not a JSON object or the result would not load.
    public static string SetLevels(IReadOnlyDictionary<string, int> levels, string display, string suggestedMatch, string? original) {
        var root = string.IsNullOrWhiteSpace(original) ? new JsonObject()
                 : JsonNode.Parse(original, documentOptions: Read) as JsonObject ?? throw new InvalidDataException("config.json is not a JSON object");
        if (root["monitors"] is { } raw && (raw is not JsonArray arr || arr.Any(x => x is not JsonObject)))
            throw new InvalidDataException("monitors must be a list of objects; fix it with Open config file");
        var list = root["monitors"] as JsonArray ?? new JsonArray();
        root.Remove("monitors");
        var entry = list.OfType<JsonObject>().FirstOrDefault(o =>
            o["match"]?.GetValueKind() == JsonValueKind.String && o["match"]!.GetValue<string>().Trim() is { Length: > 0 } match &&
            display.Contains(match, StringComparison.OrdinalIgnoreCase));
        if (entry == null) { entry = new JsonObject { ["match"] = suggestedMatch }; list.Add(entry); }
        foreach (var (k, v) in levels)
            if (k is "day" or "blindDown" or "night") entry[k] = Math.Clamp(v, 0, 100);
        root["monitors"] = list;
        var text = root.ToJsonString(new JsonSerializerOptions { WriteIndented = true, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping });
        string tmp = Path.Combine(Path.GetTempPath(), $"daylit-check-{Guid.NewGuid():N}.json");
        try {
            File.WriteAllText(tmp, text);
            var (_, err) = Config.Load(tmp);
            if (err != null) throw new InvalidDataException(err.Replace("config.json: ", ""));
        } finally { File.Delete(tmp); }
        return text;
    }
```

- [ ] **Step 3: Commit, push and let CI run the tests**

```bash
git add windows/Config.cs windows/tests/SuggestTests.cs
git commit -m "$(cat <<'MSG'
Windows: write one monitor's local levels to config.json, keeping the rest

Co-Authored-By: Claude <noreply@anthropic.com>
MSG
)"
```

```bash
git push
gh run list --branch feature/suggest-levels --limit 1
gh run watch <run-id> --exit-status
```

Expected: the `windows` job's tests pass.

### Task 17: Mac: Home Assistant write and step read

**Files:**
- Modify: `mac/Sources/Daylit/Sources.swift` (inside `enum HAClient`)

No unit test: the app target has no tests; `NumberStep.parse` is tested in Task 3. The check is a clean build.

- [ ] **Step 1: Add the two calls**

In `mac/Sources/Daylit/Sources.swift`, inside `enum HAClient`, insert right before the line `    static func describe(_ f: Failure, _ ha: HAConfig) -> String {`:

```swift
    /// input_number/set_value: a level from an accepted suggestion (DaylitCore.Suggest).
    static func setNumber(_ ha: HAConfig, _ entity: String, _ value: Double) async -> Result<Data, Failure> {
        guard Config.isEntityId(entity) else { return .failure(.badAnswer) }
        return await call(ha, "/api/services/input_number/set_value", ["entity_id": entity, "value": value])
    }
    /// An input_number's min, max and step, so a suggestion rounds to a value it accepts; nil when
    /// Home Assistant does not answer or the entity has none.
    static func numberStep(_ ha: HAConfig, _ entity: String) async -> NumberStep? {
        guard Config.isEntityId(entity), case .success(let d) = await call(ha, "/api/states/" + entity, nil) else { return nil }
        return NumberStep.parse(d)
    }
```

(`call` with a `nil` body is a GET; it adds the token itself. Never log or print it.)

- [ ] **Step 2: Build**

Run: `mac/build.sh /tmp/daylit-build 2>&1 | grep -E "warning|error|Build complete"`
Expected: only `Build complete!`.

- [ ] **Step 3: Commit**

```bash
git add mac/Sources/Daylit/Sources.swift
git commit -m "$(cat <<'MSG'
Mac: set an input_number and read its step from Home Assistant

Co-Authored-By: Claude <noreply@anthropic.com>
MSG
)"
```

### Task 18: Mac: suggestion state and corrections.json

**Files:**
- Create: `mac/Sources/Daylit/Suggestions.swift`
- Modify: `mac/Sources/Daylit/Model.swift`

- [ ] **Step 1: Add the state to the model**

In `mac/Sources/Daylit/Model.swift`, class `Daylit`, replace

```swift
    var lookDark: Bool?
    var look = LookRule()          // light/dark decision with hysteresis (DaylitCore)
```

with

```swift
    /// A change of levels to offer in the panel (DaylitCore.Suggest), and why the last Apply failed.
    @Published var suggestion: Suggestion?
    @Published var suggestError: String?
    /// Hand changes waiting to settle, and the settled ones (corrections.json, this Mac only).
    var recorder = Recorder()
    var corrections: [Sample] = []
    /// Work the suggestion out again at the end of the next tick (start, reload, a new sample, Apply, Not now).
    var suggestDirty = true
    /// What the last suggestion was worked out from: each monitor's levels, and whether Home Assistant answered.
    var suggestLevels: [String: [Double]] = [:]
    var suggestFromHA: Bool?
    /// "Not now": per monitor key, no suggestion until then (Unix seconds).
    var suggestDismissed: [String: Double] = UserDefaults.standard.dictionary(forKey: "suggestDismissed") as? [String: Double] ?? [:]
    var lookDark: Bool?
    var look = LookRule()          // light/dark decision with hysteresis (DaylitCore)
```

- [ ] **Step 2: Load the samples at start and mark the suggestion dirty on reload**

In `init()` (not `init(preview:)`, which snapshots use and must stay empty), replace

```swift
    init() {
        reload()
```

with

```swift
    init() {
        corrections = Self.loadCorrections()
        reload()
```

In `func reload()`, replace

```swift
        lookDark = nil; look = LookRule()
        let (src, srcErr) = c.resolvedSource()
```

with

```swift
        lookDark = nil; look = LookRule()
        suggestDirty = true
        let (src, srcErr) = c.resolvedSource()
```

- [ ] **Step 3: Let other files clear a hand-set level, and drop its pending change with it**

Replace

```swift
    private func forgetHandSet(_ i: Int) {
        mons[i].lastSet = nil; mons[i].offset = nil; mons[i].offsetSun = nil; mons[i].offsetAt = nil; mons[i].manual = false
    }
```

with

```swift
    func forgetHandSet(_ i: Int) {
        mons[i].lastSet = nil; mons[i].offset = nil; mons[i].offsetSun = nil; mons[i].offsetAt = nil; mons[i].manual = false
        recorder.drop(mons[i].uuid)   // a change waiting to become a suggestion sample ends here too
    }
```

- [ ] **Step 4: Create the app-side file**

Create `mac/Sources/Daylit/Suggestions.swift` with exactly this content (Task 20 appends a second `extension Daylit` to it):

```swift
// Suggest new levels from repeated hand changes (DaylitCore.Suggest): the file of samples, working out the
// suggestion the panel shows, and its two buttons. Nothing changes a level without Apply.
import Foundation
import DaylitCore

extension Daylit {
    /// This Mac's samples, not in iCloud: ~/Library/Application Support/Daylit/corrections.json.
    static var correctionsURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Daylit/corrections.json")
    }

    /// The saved samples, without those older than 14 days.
    static func loadCorrections() -> [Sample] {
        Suggest.dropOld(Suggest.decode(try? Data(contentsOf: correctionsURL)), now: Date().timeIntervalSince1970)
    }

    func saveCorrections() {
        corrections = Suggest.dropOld(corrections, now: Date().timeIntervalSince1970)
        let u = Self.correctionsURL
        do {
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Suggest.encode(corrections).write(to: u, options: .atomic)
        } catch {
            Log.write("suggest: could not save corrections.json: \(error.localizedDescription)")
        }
    }

    /// A monitor's levels this tick: Home Assistant's where it gave one, else the local ones.
    func levels(of m: Mon, _ inp: Inputs) -> [Double] {
        effectiveLevels(local: [m.day, m.blindDown, m.night], fromHA: inp.levels[m.uuid])
    }

    /// The monitor's input_number for a level, when the source is Home Assistant and one is configured.
    func haEntity(_ l: Level, of m: Mon) -> String? {
        guard source == .homeAssistant, let h = m.ha else { return nil }
        return [h.day, h.blindDown, h.night][l.rawValue].flatMap { Config.isEntityId($0) ? $0 : nil }
    }

    /// What a level can be stored as now: a whole number for a local level, the input_number's own step,
    /// or nil when it comes from Home Assistant and is unavailable (Home Assistant down, or the helper reads below 0).
    func step(for l: Level, of m: Mon, _ inp: Inputs) async -> NumberStep? {
        guard let e = haEntity(l, of: m) else { return .whole }
        guard inp.fromHA, let ha = config.homeAssistant, let row = inp.levels[m.uuid], row.count > l.rawValue, row[l.rawValue] >= 0 else { return nil }
        return await HAClient.numberStep(ha, e)
    }
}
```

- [ ] **Step 5: Build**

Run: `mac/build.sh /tmp/daylit-build 2>&1 | grep -E "warning|error|Build complete"` and `cd mac && swift test`
Expected: only `Build complete!`; tests pass.

- [ ] **Step 6: Commit**

```bash
git add mac/Sources/Daylit/Suggestions.swift mac/Sources/Daylit/Model.swift
git commit -m "$(cat <<'MSG'
Mac: keep suggestion samples in corrections.json on this Mac

Co-Authored-By: Claude <noreply@anthropic.com>
MSG
)"
```

### Task 19: Mac: record hand changes in the tick

The hook sits next to `decide(...)` in `Daylit.tick()` (`mac/Sources/Daylit/Model.swift`). A hand change is the tick where `decide` stamps `offsetAt` with `now` (Task 5's `Suggest.isHandChange`); the sample's values are that tick's. The recorder settles it 5 minutes later.

**Files:**
- Modify: `mac/Sources/Daylit/Model.swift` (`func tick()`)

- [ ] **Step 1: Use the shared levels helper in the tick**

In `func tick()`, replace

```swift
        func ownTarget(_ m: Mon) -> Int {
            let lv = effectiveLevels(local: [m.day, m.blindDown, m.night], fromHA: inp.levels[m.uuid])
            return
```

with

```swift
        func ownTarget(_ m: Mon) -> Int {
            let lv = levels(of: m, inp)
            return
```

(`levels(of:_:)` is in `Suggestions.swift` from Task 18; the rest of `ownTarget` stays.)

- [ ] **Step 2: Record and settle**

Still in `func tick()`, inside the per-monitor loop, replace

```swift
            mons[i].offset = st.offset; mons[i].offsetSun = st.offsetSun; mons[i].offsetAt = st.offsetAt
            if ok, let v = step.level { mons[i].level = Double(v) }
```

with

```swift
            mons[i].offset = st.offset; mons[i].offsetSun = st.offsetSun; mons[i].offsetAt = st.offsetAt
            // Suggestions (DaylitCore.Suggest): a new hand-set level becomes a sample once it has held 5 minutes.
            if Suggest.isHandChange(before: state, after: step.state, remote: step.remote, now: now) {
                let ctx = SampleContext(follower: follower, writeFailed: !ok, idle: !here, paused: paused,
                                        sunFallback: source == .homeAssistant && !inp.fromHA)
                recorder.handChanged(monitor: m.uuid, sample: st.offset.flatMap { o in
                    Suggest.makeSample(monitor: m.uuid, chosen: want + o, auto: want, elev: inp.elev, pos: inp.pos, lights: inp.lights,
                                       light: inp.light, levels: levels(of: m, inp), tuning: config.tuned, now: now, context: ctx)
                })
            }
            if let done = recorder.settle(monitor: m.uuid, held: auto && st.offset != nil, levels: levels(of: m, inp), now: now) {
                corrections.append(done); saveCorrections(); suggestDirty = true
            }
            if ok, let v = step.level { mons[i].level = Double(v) }
```

What the names are, all already in that loop: `state` is the `HoldState` passed to `decide` (for a linked follower its offset was stripped, so it never shows a hand change), `step` is `decide`'s result, `st` is `step.state.afterWrite(ok:before:)`, `want` the target, `follower` / `ok` / `here` / `now` / `inp` as computed above. `chosen = want + offset` is the level the user set. An offset back at 0 (`st.offset == nil`, the user put it back) passes `nil`, which ends the pending change.

- [ ] **Step 3: Build and test**

Run: `mac/build.sh /tmp/daylit-build 2>&1 | grep -E "warning|error|Build complete"` and `cd mac && swift test`
Expected: only `Build complete!`; tests pass.

- [ ] **Step 4: Commit**

```bash
git add mac/Sources/Daylit/Model.swift
git commit -m "$(cat <<'MSG'
Mac: record deliberate hand changes as suggestion samples

Co-Authored-By: Claude <noreply@anthropic.com>
MSG
)"
```

### Task 20: Mac: work out the suggestion, Apply and Not now

**Files:**
- Modify: `mac/Sources/Daylit/Suggestions.swift` (append at the end of the file)
- Modify: `mac/Sources/Daylit/Model.swift` (end of `func tick()`)

- [ ] **Step 1: Add the three actions**

Append this to the end of `mac/Sources/Daylit/Suggestions.swift`:

```swift
extension Daylit {
    /// At the end of a tick: works the suggestion out again when something changed. The first monitor with
    /// one is shown; the next shows after it is handled.
    func updateSuggestion(_ inp: Inputs) async {
        var current: [String: [Double]] = [:]
        for m in mons { current[m.uuid] = levels(of: m, inp) }
        if current != suggestLevels || inp.fromHA != suggestFromHA { suggestDirty = true }
        guard suggestDirty else { return }
        suggestDirty = false; suggestLevels = current; suggestFromHA = inp.fromHA
        let now = Date().timeIntervalSince1970
        let kept = Suggest.dropOld(Suggest.dropStale(corrections, current: current), now: now)
        if kept != corrections { corrections = kept; saveCorrections() }
        let gen = generation
        var found: Suggestion?
        for m in mons where kept.contains(where: { $0.monitor == m.uuid }) {
            guard let lv = current[m.uuid] else { continue }
            var steps: [NumberStep?] = []
            for l in Level.allCases { steps.append(await step(for: l, of: m, inp)) }
            guard gen == generation else { suggestDirty = true; return }   // displays changed meanwhile
            if let s = Suggest.suggestion(monitor: m.uuid, samples: kept, levels: lv, steps: steps, now: now,
                                          dismissedUntil: suggestDismissed[m.uuid], tuning: config.tuned) {
                found = s; break
            }
        }
        guard found != suggestion else { return }
        if let f = found, let m = mons.first(where: { $0.uuid == f.monitor }) { Log.write(f.logLine(label: m.label)) }
        suggestion = found
    }

    /// Apply: writes each proposed level (its input_number in Home Assistant, or the local level in
    /// config.json), then clears the monitor's hand-set offset, which would otherwise be applied again on
    /// top of the new level. A failed write keeps the ones that worked and shows in the problem line.
    func applySuggestion() async {
        guard let sg = suggestion, let m = mons.first(where: { $0.uuid == sg.monitor }) else { return }
        suggestion = nil; suggestError = nil
        var local: [String: Int] = [:]
        var failed: [String] = []
        for c in sg.changes {
            if let e = haEntity(c.level, of: m), let ha = config.homeAssistant {
                if case .failure(let f) = await HAClient.setNumber(ha, e, c.to) { failed.append("\(e) failed: \(HAClient.describe(f, ha))") }
            } else {
                local[c.level.key] = Int(c.to.rounded())
            }
        }
        var wroteFile = false
        if !local.isEmpty {
            let p = Config.path
            do {
                let original = try? Data(contentsOf: p)
                if let d = original, ConfigText.hasComments(d) {
                    throw ConfigEditError.invalid("it has comments, which saving would remove; set the level in Settings instead")
                }
                let out = try ConfigPatch.setLevels(local, display: m.name, suggestedMatch: CLI.suggestMatch(m.name), in: original)
                try FileManager.default.createDirectory(at: p.deletingLastPathComponent(), withIntermediateDirectories: true)
                try out.write(to: p, options: .atomic)
                wroteFile = true
            } catch ConfigEditError.invalid(let why) {
                failed.append("config.json failed: " + why.replacingOccurrences(of: "config.json: ", with: ""))
            } catch ConfigEditError.notAnObject {
                failed.append("config.json failed: it is not a JSON object")
            } catch {
                failed.append("config.json failed: \(error.localizedDescription)")
            }
        }
        if let i = mons.firstIndex(where: { $0.uuid == sg.monitor }) {
            let cleared = Suggest.afterApply(HoldState(lastSet: mons[i].lastSet, lastTarget: mons[i].lastTarget, offset: mons[i].offset,
                                                       offsetSun: mons[i].offsetSun, offsetAt: mons[i].offsetAt))
            mons[i].lastSet = cleared.lastSet; mons[i].offset = cleared.offset; mons[i].offsetSun = cleared.offsetSun
            mons[i].offsetAt = cleared.offsetAt; mons[i].manual = false
        }
        recorder.drop(sg.monitor)
        for f in failed { Log.write("suggest: \(m.label) \(f)") }
        if failed.isEmpty { Log.write("suggest: \(m.label) applied") }
        else { suggestError = "Could not apply the suggestion: " + failed.joined(separator: "; ") }
        suggestDirty = true
        if wroteFile { reload() } else { refresh() }   // reload: the new local level is in the file now
    }

    /// Not now: no suggestion for this monitor for 7 days, remembered across restarts.
    func dismissSuggestion() {
        guard let sg = suggestion else { return }
        suggestDismissed[sg.monitor] = Date().timeIntervalSince1970 + Suggest.notNow
        UserDefaults.standard.set(suggestDismissed, forKey: "suggestDismissed")
        Log.write("suggest: \(mons.first { $0.uuid == sg.monitor }?.label ?? "a monitor") not now")
        suggestion = nil; suggestError = nil; suggestDirty = true
        refresh()
    }
}
```

What it uses: `HAClient.setNumber` / `HAClient.numberStep` (Task 17), `ConfigPatch.setLevels` (Task 8), `ConfigText.hasComments`, `ConfigEditError`, `Config.path`, `CLI.suggestMatch` (existing), `Suggest.afterApply` (Task 5), `reload()` and `refresh()` (existing, `Model.swift`), `generation` (existing: bumped when the displays change).

- [ ] **Step 2: Call it at the end of every tick**

At the end of `func tick()` in `mac/Sources/Daylit/Model.swift`, replace

```swift
        detail = here || !auto ? inp.line : "Paused — this Mac is idle"
        log("tick: \(detail) · auto=\(auto)")
    }
```

with

```swift
        detail = here || !auto ? inp.line : "Paused — this Mac is idle"
        log("tick: \(detail) · auto=\(auto)")
        await updateSuggestion(inp)
    }
```

- [ ] **Step 3: Build and test**

Run: `mac/build.sh /tmp/daylit-build 2>&1 | grep -E "warning|error|Build complete"` and `cd mac && swift test`
Expected: only `Build complete!`; tests pass.

- [ ] **Step 4: Commit**

```bash
git add mac/Sources/Daylit/Suggestions.swift mac/Sources/Daylit/Model.swift
git commit -m "$(cat <<'MSG'
Mac: offer, apply or put off suggested levels

Apply writes the input_number in Home Assistant or the local level in config.json, then clears the
hand-set offset so the correction is not applied twice on top of the new level.

Co-Authored-By: Claude <noreply@anthropic.com>
MSG
)"
```

### Task 21: Mac: the panel card and its snapshot scene

**Files:**
- Modify: `mac/Sources/Daylit/UI.swift` (`struct Panel`)
- Modify: `mac/Sources/Daylit/Snapshots.swift` (`Snapshots.scenes()`)

- [ ] **Step 1: Show the card and the Apply error**

In `mac/Sources/Daylit/UI.swift`, `Panel.body`, replace

```swift
            if let p = m.problem {
                Label(p, systemImage: "exclamationmark.triangle.fill")
```

with

```swift
            if let s = m.suggestion, let mon = m.mons.first(where: { $0.uuid == s.monitor }) {
                suggestionCard(s, label: mon.label)
            }

            if let p = m.problem ?? m.suggestError {
                Label(p, systemImage: "exclamationmark.triangle.fill")
```

Then, in the same struct, insert right before the line `    /// Shown on hover over a slider instead of a paragraph in the panel.`:

```swift
    /// New levels Daylit noticed from repeated hand changes (DaylitCore.Suggest). Nothing changes without Apply.
    func suggestionCard(_ s: Suggestion, label: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(s.sentence(label: label))
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Apply") { Task { await m.applySuggestion() } }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .help("Set the new level. A level from Home Assistant changes there; otherwise in config.json.")
                Button("Not now") { m.dismissSuggestion() }
                    .buttonStyle(.borderless).controlSize(.small)
                    .help("No suggestion for this monitor for 7 days")
                Spacer()
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .accessibilityElement(children: .contain)
    }

```

- [ ] **Step 2: Add the snapshot scene**

In `mac/Sources/Daylit/Snapshots.swift`, `scenes()`, replace

```swift
            ("panel-empty", AnyView(Panel(m: model([], source: .off)))),
```

with

```swift
            ("panel-one-suggestion", AnyView(Panel(m: {
                let one = mon(1, "Monitor", 64)
                let d = model([one], source: .homeAssistant, detail: "Home Assistant · sun 100% · blind 35%")
                d.suggestion = Suggestion(monitor: one.uuid, changes: [LevelChange(level: .blindDown, from: 78, to: 61)],
                                          amount: 14, lower: true, samples: 13, days: 5)
                return d
            }()))),
            ("panel-empty", AnyView(Panel(m: model([], source: .off)))),
```

- [ ] **Step 3: Build and look at the render (not a baseline)**

```bash
mac/build.sh /tmp/daylit-build 2>&1 | grep -E "warning|error|Build complete"
/tmp/daylit-build/Daylit.app/Contents/MacOS/Daylit --render-snapshots /tmp/daylit-snaps
open /tmp/daylit-snaps/panel-one-suggestion-light.png
```

Expected: only `Build complete!`. The image shows the "Monitor" card, *Automatic*, then a bordered card: "You lower Monitor by about 14 with the blind partly or fully down. Set blind down 78 → 61?" with **Apply** and **Not now**. Do **not** copy these PNGs into `mac/Tests/Snapshots`: Task 26 records the baselines on CI. Also run `/tmp/daylit-build/Daylit.app/Contents/MacOS/Daylit --compare-snapshots mac/Tests/Snapshots /tmp/daylit-snaps`: every existing scene must match; only `panel-one-suggestion-*` is reported as a new scene without a baseline.

- [ ] **Step 4: Commit and push**

```bash
git add mac/Sources/Daylit/UI.swift mac/Sources/Daylit/Snapshots.swift
git commit -m "$(cat <<'MSG'
Mac: show a suggested level in the panel with Apply and Not now

Co-Authored-By: Claude <noreply@anthropic.com>
MSG
)"
```

```bash
git push
```

CI's macOS job will now fail only at *UI snapshots* (`panel-one-suggestion-…: new scene, no baseline`) until Task 26.

### Task 22: Windows: Home Assistant write and step read, and the "Not now" setting

**Files:**
- Modify: `windows/Sources.cs` (inside `static class HAClient`)
- Modify: `windows/Win.cs` (inside `static class Settings`)

- [ ] **Step 1: Add the two calls**

In `windows/Sources.cs`, inside `static class HAClient`, insert right before the line `    public static Task<string?> SetSwitch(Config c, bool on) =>` (they use the existing `Call`, `http`, `Token` and `Config.IsEntityId`; `NumberStep` is from Task 11):

```csharp
    /// input_number/set_value: a level from an accepted suggestion (Suggest.cs). null when it failed (see LastError).
    public static Task<string?> SetNumber(Config c, string entity, double value) =>
        !Config.IsEntityId(entity) ? Task.FromResult<string?>(null) :
        Call(c, "/api/services/input_number/set_value", new { entity_id = entity, value });

    /// An input_number's min, max and step, so a suggestion rounds to a value it accepts; null when Home Assistant
    /// does not answer or the entity has none. Leaves LastError and Transient alone, like History.
    public static async Task<NumberStep?> GetNumberStep(Config c, string entity) {
        if (c.HomeAssistant?.Url is not { } url || Token == null || !Config.IsEntityId(entity)) return null;
        try {
            using var req = new HttpRequestMessage(HttpMethod.Get, url.TrimEnd('/') + "/api/states/" + entity);
            req.Headers.Authorization = new("Bearer", Token);
            using var r = await http.SendAsync(req);
            return r.IsSuccessStatusCode ? NumberStep.Parse(await r.Content.ReadAsStringAsync()) : null;
        } catch { return null; }
    }
```

- [ ] **Step 2: Remember "Not now" across restarts**

In `windows/Win.cs`, inside `static class Settings`, insert right before the line `    static int GetInt(string name, int dflt) => Registry.CurrentUser.OpenSubKey(Key)?.GetValue(name) is int i ? i : dflt;`:

```csharp
    /// "Not now" on a suggestion: per monitor key, no suggestion until then (Unix seconds; JSON).
    public static Dictionary<string, double> SuggestDismissed {
        get {
            try {
                return Registry.CurrentUser.OpenSubKey(Key)?.GetValue("SuggestDismissed") is string j
                    ? System.Text.Json.JsonSerializer.Deserialize<Dictionary<string, double>>(j) ?? new Dictionary<string, double>()
                    : new Dictionary<string, double>();
            } catch { return new Dictionary<string, double>(); }
        }
        set { using var k = Registry.CurrentUser.CreateSubKey(Key); k.SetValue("SuggestDismissed", System.Text.Json.JsonSerializer.Serialize(value)); }
    }
```

- [ ] **Step 3: Commit, push and let CI build it**

```bash
git add windows/Sources.cs windows/Win.cs
git commit -m "$(cat <<'MSG'
Windows: set an input_number and read its step from Home Assistant

Co-Authored-By: Claude <noreply@anthropic.com>
MSG
)"
```

```bash
git push
gh run list --branch feature/suggest-levels --limit 1
gh run watch <run-id> --exit-status
```

Expected: the `windows` job's *Build Daylit.exe* step passes (the macOS job fails only at its *UI snapshots* step, see *Read this first*).

### Task 23: Windows: suggestion state and corrections.json

**Files:**
- Create: `windows/Suggestions.cs`
- Modify: `windows/App.cs`

- [ ] **Step 1: Make the controller partial**

In `windows/App.cs`, replace the line

```csharp
sealed class Controller {
```

with

```csharp
sealed partial class Controller {
```

- [ ] **Step 2: Create the app-side file**

Create `windows/Suggestions.cs` with exactly this content (Task 25 adds methods to it; `Now` is `Controller`'s existing `static double Now`):

```csharp
// Suggest new levels from repeated hand changes (Suggest.cs): the file of samples, working out the suggestion
// the panel shows, and its two buttons. Nothing changes a level without Apply.
using System.IO;

namespace Daylit;

partial class Controller {
    /// A change of levels to offer in the panel, and why the last Apply failed.
    public Suggestion? Suggestion;
    public string? SuggestError;
    /// Hand changes waiting to settle, and the settled ones (corrections.json, this PC only).
    readonly Recorder recorder = new();
    List<Sample> corrections = new();
    /// Work the suggestion out again at the end of the next tick (start, reload, a new sample, Apply, Not now).
    bool suggestDirty = true;
    /// What the last suggestion was worked out from: each monitor's levels, and whether Home Assistant answered.
    Dictionary<string, double[]> suggestLevels = new();
    bool? suggestFromHa;
    /// "Not now": per monitor key, no suggestion until then (Unix seconds).
    Dictionary<string, double> suggestDismissed = new();

    /// This PC's samples: %LOCALAPPDATA%\Daylit\corrections.json.
    static readonly string CorrectionsPath =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Daylit", "corrections.json");

    /// The saved samples (without those older than 14 days) and the "Not now" times. Not for snapshots.
    void LoadCorrections() {
        try { corrections = Suggest.DropOld(Suggest.Decode(File.Exists(CorrectionsPath) ? File.ReadAllText(CorrectionsPath) : null), Now); }
        catch (Exception e) { Log.Write("suggest: could not read corrections.json: " + e.Message); corrections = new List<Sample>(); }
        suggestDismissed = Settings.SuggestDismissed;
    }

    void SaveCorrections() {
        corrections = Suggest.DropOld(corrections, Now);
        try {
            Directory.CreateDirectory(Path.GetDirectoryName(CorrectionsPath)!);
            File.WriteAllText(CorrectionsPath, Suggest.Encode(corrections));
        } catch (Exception e) { Log.Write("suggest: could not save corrections.json: " + e.Message); }
    }
}
```

- [ ] **Step 3: Load at start, mark dirty on every config load**

In `windows/App.cs`, in the constructor `public Controller(Application app)`, replace

```csharp
        ui = app.Dispatcher;
        Load();
        panel = new Flyout(this);
```

with

```csharp
        ui = app.Dispatcher;
        Load();
        LoadCorrections();
        panel = new Flyout(this);
```

(The snapshot constructor `Controller(Config cfg, List<Mon> mons, string subtitle)` must not call it.)

In `void Load()`, replace

```csharp
        lookDark = null; look.Reset();
        foreach (var m in Mons) { m.Spec = Mon.Match(m.D, Cfg.Monitors); m.LastSet = m.LastTarget = m.Published = null; m.ContrastSet = null; }
```

with

```csharp
        lookDark = null; look.Reset();
        suggestDirty = true;
        foreach (var m in Mons) { m.Spec = Mon.Match(m.D, Cfg.Monitors); m.LastSet = m.LastTarget = m.Published = null; m.ContrastSet = null; }
```

- [ ] **Step 4: Commit, push and let CI build it**

```bash
git add windows/Suggestions.cs windows/App.cs
git commit -m "$(cat <<'MSG'
Windows: keep suggestion samples in corrections.json on this PC

Co-Authored-By: Claude <noreply@anthropic.com>
MSG
)"
```

```bash
git push
gh run list --branch feature/suggest-levels --limit 1
gh run watch <run-id> --exit-status
```

Expected: the `windows` job builds and its tests pass. A warning that `Suggestion`, `SuggestError`, `suggestLevels` or `suggestFromHa` is never used is fine for now (Task 25 uses them).

### Task 24: Windows: record hand changes in the tick

The C# mirror of Task 19, in `Controller.TickOnce()` (`windows/App.cs`). The hand-change check compares `OffsetAt` with the `now` that was passed to `Rules.Decide`, so the tick must keep that value: the existing call passes the property `Now`, which reads the clock again on every use.

**Files:**
- Modify: `windows/App.cs` (`async Task TickOnce()`)

- [ ] **Step 1: Keep the tick's time**

Replace

```csharp
            bool dragging = m.Dragging;   // the slider is in the user's hand
            var step = Rules.Decide(c, target, s.Remote.ElementAtOrDefault(i), hold, AutoOn, here, sun, m.Touched, dragging, Now);
```

with

```csharp
            bool dragging = m.Dragging;   // the slider is in the user's hand
            double tickNow = Now;         // the same time for Decide and for the suggestion samples below
            var step = Rules.Decide(c, target, s.Remote.ElementAtOrDefault(i), hold, AutoOn, here, sun, m.Touched, dragging, tickNow);
```

- [ ] **Step 2: Record and settle**

Replace

```csharp
            (m.RemoteSeen, m.RemoteValue, m.LastSet, m.LastTarget, m.Offset, m.OffsetSun, m.OffsetAt) = (st.RemoteSeen, st.RemoteValue, st.LastSet, st.LastTarget, st.Offset, st.OffsetSun, st.OffsetAt);
```

with

```csharp
            (m.RemoteSeen, m.RemoteValue, m.LastSet, m.LastTarget, m.Offset, m.OffsetSun, m.OffsetAt) = (st.RemoteSeen, st.RemoteValue, st.LastSet, st.LastTarget, st.Offset, st.OffsetSun, st.OffsetAt);
            // Suggestions (Suggest.cs): a new hand-set level becomes a sample once it has held 5 minutes.
            if (Suggest.IsHandChange(hold, step.State, step.Remote, tickNow)) {
                var sampleContext = new SampleContext(Follower: follower, WriteFailed: !ok, Idle: !here, Paused: Paused, SunFallback: haDown);
                recorder.HandChanged(m.Key, st.Offset is int handOffset
                    ? Suggest.MakeSample(m.Key, target + handOffset, target, s.Elev, s.Pos, s.Lights, light, s.Levels[i], Cfg.Tuned, tickNow, sampleContext)
                    : null);
            }
            if (recorder.Settle(m.Key, AutoOn && st.Offset != null, s.Levels[i], tickNow) is Sample settled) {
                corrections.Add(settled); SaveCorrections(); suggestDirty = true;
            }
```

The names, all already in that loop: `hold` is the `Hold` passed to `Decide` (a linked follower's has its offset stripped), `step` its result, `st` = `Rules.AfterWrite(...)`, `target` the target, `follower`, `ok`, `here`, `haDown`, `light`, `s` (the `Inputs`) and `i` as computed above; `Paused` is the controller's property. `target + handOffset` is the level the user set. New names (`tickNow`, `sampleContext`, `handOffset`, `settled`) are chosen so they do not clash with pattern variables declared earlier in `TickOnce` (`o`, `c`, `v`, `b`, `gb`, `rv`, `w`, `last`).

- [ ] **Step 3: Commit, push and let CI build it**

```bash
git add windows/App.cs
git commit -m "$(cat <<'MSG'
Windows: record deliberate hand changes as suggestion samples

Co-Authored-By: Claude <noreply@anthropic.com>
MSG
)"
```

```bash
git push
gh run list --branch feature/suggest-levels --limit 1
gh run watch <run-id> --exit-status
```

Expected: the `windows` job builds and its tests pass.

### Task 25: Windows: work out the suggestion, Apply and Not now

**Files:**
- Modify: `windows/Suggestions.cs` (inside `partial class Controller`)
- Modify: `windows/App.cs` (end of `TickOnce()`)

- [ ] **Step 1: Add the actions**

In `windows/Suggestions.cs`, insert this inside `partial class Controller`, right before its closing `}` (after `SaveCorrections()`):

```csharp
    /// The monitor's input_number for a level, when the source is Home Assistant and one is configured.
    string? HaEntity(Level l, Mon m) {
        if (Source != Source.HomeAssistant || m.Spec?.HomeAssistant is not { } h) return null;
        string? e = l switch { Level.Day => h.Day, Level.BlindDown => h.BlindDown, _ => h.Night };
        return e != null && Config.IsEntityId(e) ? e : null;
    }

    /// What a level can be stored as now: a whole number for a local level, the input_number's own step, or
    /// null when it comes from Home Assistant and is unavailable (Home Assistant down, or the helper reads below 0).
    async Task<NumberStep?> StepFor(Level l, Mon m, int i, Inputs s, bool haDown) {
        if (HaEntity(l, m) is not { } e) return NumberStep.Whole;
        if (haDown || s.FromHa is not { } raw || i >= raw.Length || raw[i].Length <= (int)l || raw[i][(int)l] < 0) return null;
        return await HAClient.GetNumberStep(Cfg, e);
    }

    /// At the end of a tick: works the suggestion out again when something changed. The first monitor with one
    /// is shown; the next shows after it is handled.
    async Task UpdateSuggestion(Inputs s, Mon[] mons, bool haDown) {
        var current = new Dictionary<string, double[]>();
        for (int i = 0; i < mons.Length && i < s.Levels.Length; i++) current[mons[i].Key] = s.Levels[i];
        bool fromHa = !haDown && Source == Source.HomeAssistant;
        bool same = current.Count == suggestLevels.Count
                    && current.All(kv => suggestLevels.TryGetValue(kv.Key, out var lv) && Suggest.SameLevels(lv, kv.Value));
        if (!same || fromHa != suggestFromHa) suggestDirty = true;
        if (!suggestDirty) return;
        suggestDirty = false; suggestLevels = current; suggestFromHa = fromHa;
        double now = Now;
        var kept = Suggest.DropOld(Suggest.DropStale(corrections, current), now);
        if (kept.Count != corrections.Count) { corrections = kept; SaveCorrections(); }
        Suggestion? found = null;
        for (int i = 0; i < mons.Length && i < s.Levels.Length; i++) {
            var m = mons[i];
            if (!kept.Any(x => x.Monitor == m.Key)) continue;
            var steps = new NumberStep?[3];
            foreach (var l in LevelText.All) steps[(int)l] = await StepFor(l, m, i, s, haDown);
            double? until = suggestDismissed.TryGetValue(m.Key, out var u) ? (double?)u : null;
            var sg = Suggest.SuggestionFor(m.Key, kept, s.Levels[i], steps, now, until, Cfg.Tuned);
            if (sg != null) { found = sg; break; }
        }
        if (found == Suggestion) return;   // records compare by value (Suggestion.Equals)
        if (found is { } f && mons.FirstOrDefault(x => x.Key == f.Monitor) is { } fm) Log.Write(f.LogLine(fm.Label));
        Suggestion = found;
    }

    /// Apply: writes each proposed level (its input_number in Home Assistant, or the local level in config.json),
    /// then clears the monitor's hand-set offset, which would otherwise be applied again on top of the new level.
    /// A failed write keeps the ones that worked and shows in the panel's problem line.
    public async void ApplySuggestion() {
        try {
            if (Suggestion is not { } sg || Mons.FirstOrDefault(x => x.Key == sg.Monitor) is not { } m) return;
            Suggestion = null; SuggestError = null;
            var local = new Dictionary<string, int>();
            var failed = new List<string>();
            foreach (var ch in sg.Changes) {
                if (HaEntity(ch.Level, m) is { } e) {
                    if (await HAClient.SetNumber(Cfg, e, ch.To) == null) failed.Add($"{e} failed: {HAClient.LastError ?? "no answer"}");
                } else local[ch.Level.Key()] = (int)Math.Round(ch.To, MidpointRounding.AwayFromZero);
            }
            bool wroteFile = false;
            if (local.Count > 0) {
                try {
                    string? original = File.Exists(Config.PathName) ? File.ReadAllText(Config.PathName) : null;
                    if (original != null && ConfigPatch.HasComments(original))
                        throw new InvalidDataException("it has comments, which saving would remove; set the level in Settings instead");
                    string text = ConfigPatch.SetLevels(local, m.D.Friendly, ConfigPatch.SuggestMatch(m.D.Friendly), original);
                    Directory.CreateDirectory(Config.Dir);
                    File.WriteAllText(Config.PathName, text);
                    wroteFile = true;
                } catch (Exception ex) { failed.Add("config.json failed: " + ex.Message); }
            }
            var cleared = Suggest.AfterApply(new Hold(m.RemoteSeen, m.LastSet, m.LastTarget, m.Offset, m.OffsetSun, m.OffsetAt, m.RemoteValue));
            (m.LastSet, m.Offset, m.OffsetSun, m.OffsetAt) = (cleared.LastSet, cleared.Offset, cleared.OffsetSun, cleared.OffsetAt);
            m.Manual = false;
            recorder.Drop(m.Key);
            foreach (var f in failed) Log.Write($"suggest: {m.Label} {f}");
            if (failed.Count == 0) Log.Write($"suggest: {m.Label} applied");
            else SuggestError = "Could not apply the suggestion: " + string.Join("; ", failed);
            suggestDirty = true;
            if (wroteFile) Reload(); else await Tick("suggestion applied");   // Reload: the new local level is in the file now
        } catch (Exception err) { Log.Write("suggest: " + err); }
    }

    /// Not now: no suggestion for this monitor for 7 days, remembered across restarts.
    public void DismissSuggestion() {
        if (Suggestion is not { } sg) return;
        suggestDismissed[sg.Monitor] = Now + Suggest.NotNow;
        Settings.SuggestDismissed = suggestDismissed;
        Log.Write($"suggest: {Mons.FirstOrDefault(x => x.Key == sg.Monitor)?.Label ?? "a monitor"} not now");
        Suggestion = null; SuggestError = null; suggestDirty = true;
        _ = Tick("not now");
    }
```

What it uses: `HAClient.SetNumber` / `HAClient.GetNumberStep` (Task 22), `ConfigPatch.SetLevels` (Task 16), `ConfigPatch.HasComments`, `ConfigPatch.SuggestMatch`, `Config.PathName`, `Config.Dir`, `Reload()`, `Tick(string)`, `Mons`, `Cfg`, `Source` (existing), `Settings.SuggestDismissed` (Task 22), `Suggest.*` (Tasks 9–14). `Suggestion? found` is the type; `Suggestion` alone in an expression is the field.

- [ ] **Step 2: Call it at the end of every tick**

At the end of `TickOnce()` in `windows/App.cs`, replace

```csharp
                   + (s.LightRatio is double lr ? $" · light {Pct(lr)}%" : "");
    }
```

with

```csharp
                   + (s.LightRatio is double lr ? $" · light {Pct(lr)}%" : "");
        await UpdateSuggestion(s, mons, haDown);
    }
```

- [ ] **Step 3: Commit, push and let CI build it**

```bash
git add windows/Suggestions.cs windows/App.cs
git commit -m "$(cat <<'MSG'
Windows: offer, apply or put off suggested levels

Apply writes the input_number in Home Assistant or the local level in config.json, then clears the
hand-set offset so the correction is not applied twice on top of the new level.

Co-Authored-By: Claude <noreply@anthropic.com>
MSG
)"
```

```bash
git push
gh run list --branch feature/suggest-levels --limit 1
gh run watch <run-id> --exit-status
```

Expected: the `windows` job builds and its tests pass.

### Task 26: Windows: the panel card and its snapshot scene, then record both platforms' baselines on CI

**Files:**
- Modify: `windows/Ui.cs` (`sealed class Flyout`)
- Modify: `windows/Snapshots.cs`
- Create (from CI): `mac/Tests/Snapshots/panel-one-suggestion-light.png`, `mac/Tests/Snapshots/panel-one-suggestion-dark.png`, `windows/tests/Snapshots/panel-one-suggestion-light.png`, `windows/tests/Snapshots/panel-one-suggestion-dark.png`

- [ ] **Step 1: Two new fields**

In `windows/Ui.cs`, class `Flyout`, replace

```csharp
    readonly Grid autoRow;
```

with

```csharp
    readonly Grid autoRow;
    readonly Border suggestCard;      // a change of levels Daylit noticed (Suggest.cs), shown only while one is pending
    readonly TextBlock suggestText;
```

- [ ] **Step 2: Build the card in the constructor**

In the `Flyout(Controller app)` constructor, replace

```csharp
        error = Small(""); error.Margin = new Thickness(2, 10, 2, 0);
        root.Children.Add(error);
```

with

```csharp
        // A change of levels Daylit noticed from repeated hand changes (Suggest.cs). Nothing changes without Apply.
        suggestText = new TextBlock { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 8) };
        var apply = new Button { Content = "Apply", Padding = new Thickness(12, 4, 12, 4), Margin = new Thickness(0, 0, 8, 0),
                                 ToolTip = "Set the new level. A level from Home Assistant changes there; otherwise in config.json." };
        apply.Click += (_, _) => app.ApplySuggestion();
        var notNow = new Button { Content = "Not now", Padding = new Thickness(12, 4, 12, 4), ToolTip = "No suggestion for this monitor for 7 days" };
        notNow.Click += (_, _) => app.DismissSuggestion();
        suggestCard = Card(new StackPanel { Children = { suggestText, new StackPanel { Orientation = Orientation.Horizontal, Children = { apply, notNow } } } });
        suggestCard.Margin = new Thickness(0, 12, 0, 0);
        suggestCard.Visibility = Visibility.Collapsed;
        root.Children.Add(suggestCard);

        error = Small(""); error.Margin = new Thickness(2, 10, 2, 0);
        root.Children.Add(error);
```

(`Card(...)` is the existing helper: rounded border, themed by `ApplyTheme` through the `cards` list.)

- [ ] **Step 3: Fill it in `Sync()`**

In `public void Sync()`, replace

```csharp
            error.Text = app.Error ?? "";
            error.Visibility = app.Error == null ? Visibility.Collapsed : Visibility.Visible;
```

with

```csharp
            var sg = app.Suggestion;
            var sgMon = sg is { } pending ? app.Mons.FirstOrDefault(x => x.Key == pending.Monitor) : null;
            suggestCard.Visibility = sg != null && sgMon != null ? Visibility.Visible : Visibility.Collapsed;
            suggestText.Text = sg != null && sgMon != null ? sg.Sentence(sgMon.Label) : "";
            string? problem = app.Error ?? app.SuggestError;   // an Apply that failed stays until the next suggestion action
            error.Text = problem ?? "";
            error.Visibility = problem == null ? Visibility.Collapsed : Visibility.Visible;
```

- [ ] **Step 4: Add the snapshot scene**

In `windows/Snapshots.cs`, `Scenes()`, replace

```csharp
        yield return ("panel-empty", "{}", () => new(), false, "");
```

with

```csharp
        yield return ("panel-one-suggestion", ha, () => new() { Fake("Monitor", 64) }, false, "Home Assistant · sun 100% · blind 35%");
        yield return ("panel-empty", "{}", () => new(), false, "");
```

and in `Render`, replace

```csharp
                if (name.EndsWith("-partial")) controller.SnapshotLeave(list[^1]);   // the last monitor out of the group
```

with

```csharp
                if (name.EndsWith("-partial")) controller.SnapshotLeave(list[^1]);   // the last monitor out of the group
                if (name == "panel-one-suggestion")   // made-up evidence, the same scene as the Mac's
                    controller.Suggestion = new Suggestion(list[0].Key, [new LevelChange(Level.BlindDown, 78, 61)], 14, true, 13, 5);
```

- [ ] **Step 5: Commit and push, check the Windows job up to the snapshots**

```bash
git add windows/Ui.cs windows/Snapshots.cs
git commit -m "$(cat <<'MSG'
Windows: show a suggested level in the panel with Apply and Not now

Co-Authored-By: Claude <noreply@anthropic.com>
MSG
)"
```

```bash
git push
gh run list --branch feature/suggest-levels --limit 1
gh run watch <run-id> --exit-status
```

Expected: both jobs pass tests and build; both fail only at *UI snapshots* with `panel-one-suggestion-light.png: new scene, no baseline` (and `-dark`). Any other snapshot reported as changed is a regression: stop and fix it before recording.

- [ ] **Step 6: Record the baselines on CI and commit them** (CONTRIBUTING.md → *UI snapshots*)

```bash
git status --short mac/Tests/Snapshots windows/tests/Snapshots   # must print nothing before downloading into them
gh workflow run build.yml --ref feature/suggest-levels -f record=true
gh run list --branch feature/suggest-levels --workflow build.yml --limit 1    # the workflow_dispatch run
gh run watch <record-run-id> --exit-status
gh run download <record-run-id> -n snapshots-mac -D mac/Tests/Snapshots
gh run download <record-run-id> -n snapshots-windows -D windows/tests/Snapshots
git status --short mac/Tests/Snapshots windows/tests/Snapshots
```

Expected from the last command: only the four new `panel-one-suggestion-*.png` files. If an existing PNG shows as modified, CI's fonts or rendering differ from the committed baseline; restore it (`git checkout -- <file>`), since this task changes no other scene. Open the four new images and check the card reads "You lower Monitor by about 14 with the blind partly or fully down. Set blind down 78 → 61?" with **Apply** and **Not now**, in light and dark.

```bash
git add mac/Tests/Snapshots/panel-one-suggestion-light.png mac/Tests/Snapshots/panel-one-suggestion-dark.png windows/tests/Snapshots/panel-one-suggestion-light.png windows/tests/Snapshots/panel-one-suggestion-dark.png
git commit -m "$(cat <<'MSG'
UI snapshots: the panel with a suggested level

Co-Authored-By: Claude <noreply@anthropic.com>
MSG
)"
```

```bash
git push
gh run list --branch feature/suggest-levels --limit 1
gh run watch <run-id> --exit-status
```

Expected: both jobs green, including *UI snapshots*.

### Task 27: Docs: short mentions

README → *How it works* is the shared behaviour (CONTRIBUTING.md), so it gets the main sentence; `docs/setup.md` gets the details; `AGENTS.md` and `CONTRIBUTING.md` one line each. Plain sentences, no real names or paths of anyone's setup.

**Files:**
- Modify: `README.md`, `docs/setup.md`, `AGENTS.md`, `CONTRIBUTING.md`

- [ ] **Step 1: README.md**

In *How it works*, replace

```markdown
   sun climbs. The distance fades out at sunset, so the next day starts clean; *Manual ✕* on the
   monitor's row goes back to automatic at once.
```

with

```markdown
   sun climbs. The distance fades out at sunset, so the next day starts clean; *Manual ✕* on the
   monitor's row goes back to automatic at once. When you keep correcting a monitor the same way
   on several days, the panel offers to change its level, with *Apply* and *Not now*; nothing changes
   without the click ([details](docs/setup.md#suggested-levels)).
```

- [ ] **Step 2: docs/setup.md**

Replace

```markdown
The levels themselves are per monitor (Settings → *Displays*, or Home Assistant's helpers).
```

with

```markdown
The levels themselves are per monitor (Settings → *Displays*, or Home Assistant's helpers).

### Suggested levels

When you keep correcting a monitor the same way, the panel offers new levels:

> You lower *Monitor* by about 12 with the blind partly or fully down. Set blind down 78 → 62?

- A change counts once it has held 5 minutes. Not counted: the Home Assistant `set` helper, a linked
  monitor following another, an idle or paused computer, the sun standing in while Home Assistant is
  down, the room-lights boost, and levels at 0 or 100.
- A level is offered only with changes on at least 3 days in the situation where it counts most (blind
  down: daylight with the blind mostly closed; day: mostly open; night: the evening), when it moves by at
  least 5, and when the new level would have been at least 3 points closer to what you chose, on average.
- **Apply** sets the level where it lives: its `input_number` in Home Assistant (rounded to the helper's
  step), otherwise `config.json`. Your hand-set distance is cleared at the same time, so it is not added
  twice. **Not now** hides that monitor's suggestions for 7 days.
- The changes stay on this computer for 14 days (macOS `~/Library/Application Support/Daylit/corrections.json`,
  Windows `%LOCALAPPDATA%\Daylit\corrections.json`); nothing goes to Home Assistant or iCloud. When a
  level changes (Apply, Settings, a Home Assistant helper), it starts again from new changes.
- The log shows `suggest:` lines.
```

- [ ] **Step 3: AGENTS.md**

In *5. Hand over to the user*, replace

```markdown
  and *Automatic*. A level set by hand keeps its distance from the
  automatic one until sunset, and survives a restart (for up to 12 hours).
```

with

```markdown
  and *Automatic*. A level set by hand keeps its distance from the
  automatic one until sunset, and survives a restart (for up to 12 hours). Repeated hand changes in the
  same situation make the panel offer a new level (*Apply* / *Not now*, [docs/setup.md → Suggested
  levels](docs/setup.md#suggested-levels)); the samples stay on that machine in `corrections.json`.
```

and replace

```markdown
  shows automatic changes (`auto:`), publishes, idle/back, theme switches, battery pause/resume and Home Assistant errors.
```

with

```markdown
  shows automatic changes (`auto:`), publishes, idle/back, theme switches, battery pause/resume, suggested levels (`suggest:`) and Home Assistant errors.
```

- [ ] **Step 4: CONTRIBUTING.md**

Replace

```markdown
  target, hand-set hold, idle, the Home Assistant "set" helper, light/dark), `HATemplate`.
```

with

```markdown
  target, hand-set hold, idle, the Home Assistant "set" helper, light/dark), `HATemplate`, `Suggest`
  (suggested levels from repeated hand changes; `windows/Suggest.cs` is its twin).
```

- [ ] **Step 5: Check the anchor and commit**

Run: `grep -n "### Suggested levels" docs/setup.md` (one line) and `grep -rn "suggested-levels" README.md AGENTS.md` (two lines).

```bash
git add README.md docs/setup.md AGENTS.md CONTRIBUTING.md
git commit -m "$(cat <<'MSG'
Docs: suggested levels from repeated hand changes

Co-Authored-By: Claude <noreply@anthropic.com>
MSG
)"
```

```bash
git push
```

### Task 28: Final check

- [ ] **Step 1: Mac tests and a clean build**

```bash
cd mac && swift test 2>&1 | tail -3
mac/build.sh /tmp/daylit-build 2>&1 | grep -E "warning|error|Build complete"
```

Expected: `Executed N tests, with 0 failures` (N = the tests before this branch + 38 new ones); only `Build complete!`.

- [ ] **Step 2: A quick run on a test config (no Home Assistant, nothing of yours touched)**

```bash
mkdir -p /tmp/daylit-test
printf '{ "source": "sun", "location": { "latitude": 51.48, "longitude": 0 } }\n' > /tmp/daylit-test/config.json
DAYLIT_CONFIG=/tmp/daylit-test/config.json DAYLIT_NO_KEYS=1 DAYLIT_DEBUG=1 /tmp/daylit-build/Daylit.app/Contents/MacOS/Daylit &
sleep 15; kill %1
```

Expected: it starts, ticks (`tick:` lines) and shows no `suggest:` line yet (no samples). Quit any running Daylit first: a second copy hands over to the first and exits. (A full Apply check needs 3 days of real use; the core tests cover the rules.)

- [ ] **Step 3: CI green on the pushed head**

```bash
git status                      # clean, "up to date with 'origin/feature/suggest-levels'"
gh run list --branch feature/suggest-levels --limit 1
gh run watch <run-id> --exit-status
```

Expected: the macOS and Windows jobs both pass, tests, build and UI snapshots.

- [ ] **Step 4: Spec walk-through**

Read `docs/superpowers/specs/2026-11-12-suggest-levels-design.md` once more and tick each point against the code: recording rules and every exclusion (Tasks 5, 19, 24), candidates (1, 9), fit and pull (2, 10), rounding to an input_number step (3, 11, 17, 22), the 5-point and 3-point tests and Not now for 7 days (4, 12, 20, 25), the sentence and log lines (4, 12, 20, 25), Apply clearing the offset (5, 13, 20, 25), stale and old samples and corrections.json (6, 14, 18, 23), both fixtures, cloudy mornings and the references (7, 15), the card and `panel-one-suggestion` (21, 26). Report anything missing instead of adding scope.
