# Suggest new levels from repeated hand changes

Issue #39. Both apps (macOS and Windows) behave the same.

## Goal

When someone keeps correcting a monitor the same way, Daylit offers to change that monitor's
levels (`day`, `blindDown`, `night`) so they stop having to. It suggests; it never changes a level
without a click.

Motivating case (one user, one week): every morning the user lowered a monitor by 6–15 points with
the blind 30–40% open. The levels were day 100 / blind down 78 / night 75. Lowering blind down to 62
by hand helped but did not go far enough: the next morning they still lowered it 6–12 points at 40%.
That is the pattern this feature should catch on its own.

## How the automatic level works (unchanged)

`target(...)` in `Rules.swift` / `Rules.cs`, with `s = min(daylightFraction(elev), light)` and
`p = pos / 100`:

    v = night·(1 − s) + s·(blindDown·(1 − p) + day·p)
    then max(v, night + lightsBoost) when the lights are on and the sun is low
    then clamp 0–100 and round

Without the lights boost and inside 0–100, `v` is linear in the three levels with weights
`x = [s·p, s·(1 − p), 1 − s]` for `[day, blindDown, night]`. The weights sum to 1.

## 1. Recording hand changes

A **sample** is one deliberate correction:

| field | meaning |
|---|---|
| `monitor` | the monitor's key (the same key the hold state uses) |
| `chosen` | the level the user set |
| `auto` | the automatic target at that moment |
| `s` | the daylight fraction `target` used: `min(daylightFraction(elev), light)` |
| `p` | blind position / 100 |
| `elev`, `lights` | sun elevation and lights flag, so scoring can rerun `target` |
| `levels` | the `[day, blindDown, night]` in effect at that moment |
| `at` | Unix time |

Rules:

- A sample is taken from the tick where `decide` records a new hand-set offset (moved by hand,
  `touched` or more than 1 off). Values are those of that tick, not later ones: the offset can fade
  while it is held.
- It becomes final after **5 minutes with no further hand change** on that monitor, with the offset
  still set. A new hand change in those 5 minutes replaces the pending one. If the offset is
  cleared first (Automatic off, Apply, a level change), the pending one is dropped.
- **Not recorded:**
  - a level from the Home Assistant `set` helper
  - a linked follower (its level comes from the leader)
  - a tick whose write failed
  - this machine idle, or paused on battery
  - Home Assistant down while the source is `homeAssistant` (the sun fallback is running)
  - the lights boost decided the target
  - `chosen` or `auto` at 0 or 100 (the clamp hides the true wish)
- Stored per machine, not in iCloud: macOS `~/Library/Application Support/Daylit/corrections.json`,
  Windows `%LOCALAPPDATA%\Daylit\corrections.json`. Samples older than 14 days are dropped on load
  and on save. Nothing is published to Home Assistant.
- **Stale samples:** a sample whose `levels` differ from the monitor's current levels is ignored
  and removed. This covers Apply, a change in Settings and a change of the helper in Home Assistant,
  so a level that was just changed starts from fresh evidence.

## 2. Which levels the data can tell apart

A level is a **candidate** only when at least 3 different local days have a sample where that
level carries most of the weight (`x_k ≥ 0.55`; 0.55 rather than 0.6 so a blind exactly 40% open, weight 0.6, is not lost to rounding). With the blind 35% open in full daylight,
`x = [0.35, 0.65, 0]`: blind down is a candidate, day is not. Without a blind, `p` is always 1, so
blind down is never a candidate.

Non-candidate levels stay fixed at their current values.

## 3. The fit

Fit only the candidate levels, holding the others at their current values. Least squares with a
small pull toward the current value (ridge weight 1, the same as one extra sample at the current
level):

    minimise  Σ_i (chosen_i − x_i · L)²  +  Σ_{k candidate} (L_k − current_k)²

This is a 1×1 to 3×3 linear solve. Clamp each result to 0–100 and round.

**Rounding to what can be stored:** when a level comes from a Home Assistant `input_number`, read
its `min`, `max` and `step` from the entity's attributes and round to a value it accepts. A local
level rounds to a whole number.

## 4. When to suggest

Per monitor, propose every candidate level where all of these hold:

1. it moves by at least **5** after rounding
2. the proposed levels lower the **mean absolute error** over that monitor's samples by at least
   **3 points**. Both errors are computed by running the real `target(...)` (boost, clamp,
   rounding) with each set of levels against `chosen`.

At most one suggestion per monitor at a time. It is computed when a sample becomes final, at start
and after a config reload. **Not now** hides that monitor's suggestions for **7 days**, remembered
across restarts in app settings, not in the config. A new suggestion after that needs the same
tests to pass again.

A level that comes from Home Assistant but is unavailable right now (the helper reads below 0, or
HA is down) is not proposed.

**Protecting situations the user did not correct.** A proposal must not change the target by more
than 3 points in a reference situation unless the user's samples cover it. The references are:

- a sunny day with the blind fully down (`s = 1`, `p = 0`, lights off)
- a sunny day with the blind open (`s = 1`, `p = 1`, lights off)
- an evening with the lights on (`s = 0`, lights on, the sun below `lightsBoostSunBelow`)

A sample covers a reference when the level that reference depends on most carries at least 0.55 of
the sample's weight: blind down for the first, day for the second, night for the third. That level
is then a candidate, so in this design the check only fails when a fit moves a level with no
support. It never should, because only candidate levels move. It is kept as a test that guards the
evenings and sunny days against a later change to the fit, not as an extra filter.

Cloudy mornings with the blind partly open are a known gap. At blind 40%, day 95 and blind down 62
mix to 75.2, the same as night 75. The target is then about 75 whatever the light, so no level can
explain a change to 63 without hurting sunny days or evenings. This design makes no suggestion for
them. A separate control for dim daylight is tracked in its own issue.

## 5. The panel line

A one-line card at the bottom of the panel, only while a suggestion is pending:

> You lower *Monitor* by about 12 with the blind down. Set blind down 78 → 62?   **Apply** · **Not now**

- The direction ("lower" / "raise") and amount are the mean of `chosen − auto` over the samples
  where the proposed level is the main weight, rounded.
- The situation phrase follows the main level: day "with the blind open", blind down "with the blind partly or fully
  down", night "in the evening".
- Two or three levels: "Set blind down 78 → 62, day 100 → 95?"
- Several monitors with suggestions: show the first; the next one shows after it is handled.

**Apply**, per level:

- Home Assistant level (an `input_number` is configured and gave a value this tick): call
  `input_number/set_value` with the rounded value.
- Otherwise: write the local level to the config file (`ConfigEdit` on macOS, the matching code on
  Windows), keeping every other key.
- Then clear that monitor's hand-set offset (`offset`, `offsetSun`, `offsetAt`, `lastSet`).
  Otherwise the held correction would be applied again on top of the new level: target 85, user set
  70 (offset −15), new level gives 70, and the monitor would go to 55.
- If one write fails, keep the ones that worked, show the error in the panel's problem line and log
  it. The stale-sample rule takes care of the rest.

**Log lines:**

- `suggest: <label> blind down 78 → 62 (12 changes on 4 days)`
- `suggest: <label> applied`
- `suggest: <label> not now`
- `suggest: <label> <entity> failed: <reason>`

## 6. Code layout

- **Pure core** (no IO, fully tested), `mac/Sources/DaylitCore/Suggest.swift` and
  `windows/Suggest.cs`:
  - `Sample` and its JSON form
  - `Recorder`: a pending gesture, settle after 5 minutes, drop
  - `weights(s:p:)`
  - `candidates`
  - `fit`
  - `roundToStep`
  - `suggestion(samples:levels:steps:now:dismissedUntil:)`, which returns the levels to propose and
    the sentence parts
- **App side:** the recording hook next to `decide` in `Model.swift` / `App.cs`, the file load and
  save, the Apply and Not now actions, the HA write (a `setNumber` on `HAClient` and its Windows
  counterpart) and the attribute read for `min`/`max`/`step`.
- **UI:** the card in `UI.swift` and `Ui.cs`. A new snapshot state `panel-one-suggestion` on both
  platforms, with baselines re-recorded on CI (CONTRIBUTING → *UI snapshots*).

## 7. Tests (same cases in Swift and C#)

- **Fit:** exact synthetic data recovers the levels. A level without dominant samples stays put.
  The ridge keeps a single-sample result near the current value.
- **Candidates:** the 0.55 rule and the 3-day rule, and no blind meaning no blind-down candidate.
- **Recorder:**
  - a change settles after 5 minutes
  - a second change within 5 minutes replaces the first
  - a cleared offset drops the pending one
  - each exclusion in section 1 is not recorded
- **Stale samples** are dropped when the levels change.
- **Trigger:** the 5-point and 3-point thresholds, scored through `target`, including a sample
  where the boost applies; *Not now* hides for 7 days.
- **Rounding** to an HA step (for example step 5, min 10, max 90).
- **Cloudy mornings make no suggestion:** the second day's two changes replayed on three
  different days, at levels day 95, blind down 62 and night 75, with `s` 0.5–0.7 and the blind
  40–58% open, produce no suggestion.
- **References stay put:** for every fixture that does produce a suggestion, the evening-with-lights
  target and the target of any level that was not proposed move by no more than 3 points.
- **Apply clears the offset:** no doubled correction on the next `decide`.
- **The motivating week as a fixture**, anonymised, with the levels day 100 / blind down 78 /
  night 75. Blind down is proposed lower by at least 5, in the 45–65 range. Night is not proposed.
  Day is not raised.
- **The day after as a second fixture**, with the levels day 95 / blind down 62 / night 75: two
  changes that held, both lower: 75 → 63 with the blind 40% open and 78 → 72 at 58%. A third
  (75 → 69) was put back within 3 minutes and must not be recorded. One day is not enough to
  suggest, so this fixture checks the recorder and the fit's direction: blind down comes out lower,
  in the 35–57 range.

## Out of scope

- Learning anything other than the three levels (timings, the lights boost, tuning thresholds).
- Changing levels without a click.
- Syncing samples between machines.
- The dark/light keyboard shortcut (a separate PR).
