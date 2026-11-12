# A night level for when the room lights are on

Issue #40. Both apps (macOS and Windows) behave the same.

## Problem

`night` does two jobs today:

1. **After sunset, room lights on:** night + `lightsBoost` (a global 5 points) is the evening level.
2. **Weak daylight:** clouds, or a low sun, blend the target toward night.

One user's evening level with the lights on is about 80. So night was set to 75. On a cloudy morning
the room is dim, and they want 60–70, but the blend toward night cannot go below 75. Lowering night and
raising the global boost would work for that monitor, but it would raise every other monitor's lit
evenings (one goes from 20 to 35).

## Design

Each monitor gets an **optional** fourth level, `nightLights` (0–100): the level after sunset with the
room lights on. Without it, nothing changes: the current formula runs exactly as today. With it, night
becomes the dark-room level that weak daylight blends toward. The global boost no longer applies to
that monitor.

Definitions as today:

- `sun` = `daylightFraction(elev)`: 0 at −3°, 1 from 12°, with the defaults.
- `s = min(sun, light)`: `light` is the daylight-sensor cap, 1 without a sensor.
- `daytime = blindDown + (day − blindDown) · pos / 100`

**Monitor without `nightLights`** (unchanged):

    v = night + (daytime − night) · s
    if lights && elev < lightsBoostSunBelow: v = max(v, night + lightsBoost)

**Monitor with `nightLights`**, room lights off: the same as above without the boost line, so the
blend goes toward night.

**Monitor with `nightLights`**, room lights on:

    anchor = night · sun + nightLights · (1 − sun)
    v = anchor + (daytime − anchor) · s

With the sun high (`sun = 1`), anchor = night, so the lamps make no difference in daylight, cloudy or
not. As the sun goes down, the anchor slides from night to `nightLights`, with no jump at 1.5°. With
the sun down, `v = nightLights`.

Then, in every case, clamp to 0–100 and round, as now.

Example (day 95, blind down 62, night 60, nightLights 80):

- cloudy morning (`s` 0.5), blind 40% → 68
- blind 58% → 71
- blind open, `s` 0.55 → 79
- dark evening with the lights on → 80

## Where the lights state comes from

- As today: the configured lights entity, from Home Assistant.
- **No lights entity:** lights count as off. Settings shows the new field only when a lights entity is
  configured.
- **Home Assistant down (sun fallback):**
  - For a monitor **with** `nightLights`, use the last lights state seen. This works the same way the
    blind keeps its last known position, so a lit evening does not drop to night during an outage.
  - With none seen yet, lights count as off.
  - Monitors **without** `nightLights` keep today's fallback exactly (lights off).
- Sun-only source: lights off. The field is not shown, since there is no lights entity.

## Configuration

- **Local config:** `monitors[].nightLights` (optional number). Validation as for the other levels
  (0–100). `--check-config` accepts it.
- **Home Assistant:** an optional `monitors[].homeAssistant.nightLights` naming an `input_number`.
  - Same rules as the other three: Home Assistant's value wins when it is ≥ 0.
  - With neither a local nor a Home Assistant value, the monitor has no `nightLights`.
  - `homeassistant/daylit_helpers.yaml` gets an optional commented example.
- **Settings:** an optional row **Lights on** under Night, empty by default, with the help text
  "After sunset with the room lights on. Empty keeps Night plus the room-lights boost." It is saved like
  the other levels, keeping every other key.
- **Nobody's brightness changes** until they set the level.

## The brightness chart

Both apps' charts draw the curve through `target`, so they follow automatically. If the chart has a
lights-on variant, it uses the same function. No new chart elements.

## Suggestions (from #39)

The suggestion feature fits only day, blind down and night. For a monitor with `nightLights`:

- Samples are not recorded while the lights are on and `sun < 1`. In that case the four-level formula
  applies and the three-level fit would be wrong.
- The levels snapshot in a sample includes `nightLights` too, so changing it makes older samples stale.
- Fitting `nightLights` itself is a follow-up issue.

## Tests (same cases in Swift and C#)

- **No `nightLights`:** `target` is identical to today for a grid of elevations, blind positions,
  lights on/off and caps. This is the regression guard.
- **With `nightLights`:**
  - lights off equals the boost-free blend toward night
  - lights on at `sun = 1` equals the lights-off value
  - lights on at the sun down equals `nightLights`
  - the dusk transition is continuous: no step larger than 2 points between elevations 0.1° apart
  - the example values above
- **Effective levels:** the Home Assistant value wins when ≥ 0; with no value, there is no
  `nightLights`.
- **Fallback:** a monitor with `nightLights` keeps the last lights state while Home Assistant is down,
  and one without it stays as today.
- **Suggestions:** no sample while the lights are on and `sun < 1` for a monitor with `nightLights`;
  the snapshot includes it.
- **Config:** load, save and validation of `nightLights`, locally and in Home Assistant, and Settings
  keeps other keys.
- **UI snapshots:** only the Settings scenes that show the levels change; re-record them on CI.

## Out of scope

- Fitting `nightLights` in the suggestion feature (follow-up issue).
- Changing the global boost or any default.
- Setting any user's levels. The owner's own values (night 60, lights on 80) are applied separately,
  with their yes.
