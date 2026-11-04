# Setting up Daylit

Daylit runs with no setup: it finds your external monitors and gives you a slider and keys for each.
This page covers everything else: automatic mode, Home Assistant, permissions and troubleshooting.

## Settings window

Gear menu → **Settings…** (on Windows also in the tray icon's menu) sets the common things without
editing a file: what brightness follows (nothing, the sun or Home Assistant), your location (typed,
or **Locate me** asks the system once), the day / blind closed / night levels and name of each
connected monitor, and Home Assistant's URL, token and room entities, with a connection test.
Moving its sliders does not change the screen; a line under each monitor shows its level right now.

It saves into the config file below and keeps everything else in it (other monitors, per-monitor Home
Assistant helpers, keys it does not show). Comments in the file are not kept.

## Config file

- macOS: `~/.config/daylit/config.json`
- Windows: `%APPDATA%\Daylit\config.json`

The panel's gear menu → **Open config file** creates one if it is missing. Every key is optional;
[`config.example.json`](../config.example.json) shows them all. After editing, use **Reload config**
in the same menu.

| Key | Meaning |
|---|---|
| `source` | `off`, `sun` or `homeAssistant`. Default: `homeAssistant` when a `homeAssistant.url` is set, else `sun` when a `location` is set, else `off`. |
| `location` | `latitude` and `longitude` (city level is enough). Needed for `sun`; with Home Assistant it is the fallback. |
| `monitors` | Per-monitor overrides, matched by `match` (any case-insensitive part of the monitor's name). `label`, the levels `day`, `blindDown`, `night` (0–100, defaults 70/40/20) and, on macOS, `control` (`native` or `ddc`). |
| `homeAssistant` | `url`, `tokenName` (default `daylit-home-assistant`) and the entities `autoSwitch`, `sun`, `cover`, `lights`, each optional. |
| `pauseOnBattery` | Starting value of *Pause on battery* in the gear menu (default `true`); the menu remembers your choice. |
| `ddcTool` | macOS only: path to `m1ddc` (Apple silicon only) if it is not in Homebrew's usual place. |
| `builtIn` | macOS only: `false` hides the built-in screen's slider (shown while the lid is open; manual only, automatic mode never changes it). |

Find the `match` text for your monitors with the built-in commands:

```sh
~/Applications/Daylit.app/Contents/MacOS/Daylit --list-monitors     # macOS
~/Applications/Daylit.app/Contents/MacOS/Daylit --check-config      # exit 0 = ok
```

```powershell
& "$env:LOCALAPPDATA\Programs\Daylit\Daylit.exe" --list-monitors | Out-String   # Windows
& "$env:LOCALAPPDATA\Programs\Daylit\Daylit.exe" --check-config | Out-String
```

`--check-config` lists problems to fix, notes (for example a configured monitor that is plugged
into another computer right now) and which config entry matched which monitor.

## Home Assistant

1. Create the helpers: one `input_boolean` for automatic mode and three `input_number`s per monitor
   (day, blind closed, night). [`homeassistant/daylit_helpers.yaml`](../homeassistant/daylit_helpers.yaml)
   is a ready package. The blind and the lights are optional.
2. Create a long-lived access token: your Home Assistant profile → Security.
3. Store the token (it never goes in the config file):
   - macOS: the app asks on first start and saves it in the keychain. Gear menu → *Home Assistant
     token…* changes it. From Terminal instead:
     `security add-generic-password -s daylit-home-assistant -a homeassistant -w` (it prompts).
   - Windows: the app asks on first start and saves it in Credential Manager. Right-click the tray
     icon → *Home Assistant token…* to change it.
4. In the config, set `homeAssistant.url` and, per monitor, a `homeAssistant` block:

```json
"homeAssistant": {
  "sensor": "sensor.daylit_left_monitor",
  "day": "input_number.daylit_left_day",
  "blindDown": "input_number.daylit_left_blind_down",
  "night": "input_number.daylit_left_night",
  "set": "input_number.daylit_left_set"
}
```

- The three levels can then be tuned from any Home Assistant dashboard.
- `sensor` is published by Daylit with what it applied (`target`, `manual`, `offset` (the hand-set distance), `daylight`, `blind`,
  `lights`, `source` attributes), so you can graph it.
- `set` is optional: changing that helper sets the monitor right away, even when the computer is
  idle (dim it from your phone). It then counts as a level set by hand.

With an `http://` URL the token travels unencrypted on your local network; use your `https://`
address if you have one. On macOS, plain `http://` works for local addresses only (an IP, `*.local`
or a single-word host name). `--check-config` warns when an `http://` URL points outside your local
network, where the token would cross the internet unencrypted.

Entity ids must be plain `domain.object_id` (lowercase letters, digits, `_`). Anything else is
reported as a config problem and Home Assistant is not contacted until it is fixed.

### Security notes

- **macOS keychain.** Daylit reads the token through `/usr/bin/security`. A token saved from
  Daylit's dialog trusts Daylit and that tool, so reading it never prompts; a token added from
  Terminal prompts once, naming `security`. Either way, any process running as you can read that
  one item with the same tool. Daylit doesn't read the keychain in-process because the downloadable build is
  not signed with a stable Developer ID: the keychain would ask again after every update. If that
  trade-off doesn't suit you, answer *Allow* instead (it asks again on each start).
- **The config file is trusted.** Whoever can edit `config.json` already runs code as you, so
  Daylit doesn't try to defend against a hostile config beyond rejecting malformed values (entity
  ids and the URL above).

## Keys and shortcuts

- macOS: the keyboard's brightness keys change the monitor holding the focused window (they need
  Accessibility permission; the built-in screen keeps working as usual). `⌃⌥⌘↑/↓` work without that
  permission. Add `⇧` for steps of 1.
- Windows: `Ctrl+Alt+PgUp/PgDn`, plus `Shift` for steps of 1.
- Both: gear menu → *Keyboard shortcuts…* to change them.

## Sync monitors

With two or more external monitors connected, a link button sits at the top of the panel, next to the
gear. It links every monitor, however many there are (click it again to unlink; while linked it is
filled with the accent colour and the monitor cards get an accent border).
With three or more monitors, each linked card also shows a small link icon: click it to take that
monitor out of the group (say a TV next to two matching monitors), and again to bring it back at
its current offset. While some are out, the header button is only outlined; clicking it links them all.
When you turn it on, Daylit remembers how far apart they are (say the Dell at 40 % and the other at
60 %: an offset of −20). From then on:

- Moving one monitor's slider, or using the keys on it, moves the others by the same amount. A
  monitor that hits 0 or 100 % stops there and lines up again when you come back.
- In automatic mode the first monitor's own target drives the group, and the others follow with
  their offsets. Their own day / blind closed / night levels are not used while sync is on.
- A monitor plugged in later joins at its current offset. A Home Assistant `set` helper still
  applies to its own monitor only. The built-in Mac screen is never part of the group.

Turn the switch off and on again to capture new offsets.

## Light and dark mode

Optional, with the sun or Home Assistant source: on by default on Windows, off by default on macOS.
Light mode when daylight comes in (sun above 4°, and with Home Assistant the blind at least 55 %
open) or when the room lights are bright and white; dark otherwise, including night with dim or
orange lights. Each condition has a gap between its on and off thresholds so it does not flip back
and forth, and a manual switch stays until the automatic decision next changes.

- Windows: if the wallpaper is one of Windows 11's stock light/dark pair, it is swapped too; a
  custom wallpaper is never touched.
- macOS: it switches the system appearance through System Events, so the first switch asks for the
  Automation permission.

Both apps: turn it on in Settings → *Appearance* (or the gear menu → *Light or dark mode from
daylight*); the gear menu also has a manual *Switch to light/dark mode*. The Appearance pane sets
when it switches, and with Home Assistant *Count the blind and the room lights* can be turned off to
follow the sun only.

## Tuning

Every number behind the rules can be changed in the config file's optional `tuning` block. The
Settings window has the ones people change: when the screens brighten (*Automatic*, a sun curve with
draggable lines) and when light and dark mode switch (*Appearance*); the `timing` keys are file only. A missing key keeps the value below; values that make no
sense (night above day, a dark edge above its light edge) are refused with the key's name.

| Key | Default | What it does |
|---|---|---|
| `brightness.sunNight` | -3 | sun elevation (°) at or below which the night level applies |
| `brightness.sunDay` | 12 | elevation from which the full daytime level applies |
| `brightness.lightsBoost` | 5 | room lights on at dusk keep the monitor this many points above night |
| `brightness.lightsBoostSunBelow` | 1.5 | …while the sun is below this elevation |
| `theme.lightSunAbove` / `darkSunBelow` | 4 / 1 | light mode above, dark below (in between, no change) |
| `theme.lightBlindAbove` / `darkBlindBelow` | 55 / 35 | blind open (%) needed for light mode / dark at or below |
| `theme.whiteLightsAbove` / `whiteLightsBelow` | 78.4 / 66.6 | lights this bright (%) and white count as daylight / stop counting (HA brightness 200 / 170 of 255) |
| `theme.whiteSaturationMax` / `warmSaturationMin` | 35 / 45 | colour saturation for "white" / "warm" (0 white … 100 deep colour) |
| `theme.room` | true | false: light/dark follows the sun only |
| `timing.pollSeconds` / `batteryPollSeconds` | 30 / 120 | how often automatic mode checks |
| `timing.idleSeconds` | 300 | no input this long: another computer may be using the monitors |
| `timing.haFallbackSeconds` | 60 | Home Assistant down this long: the sun takes over |
| `timing.manualKeepHours` | 12 | hand-set levels survive a restart this long |

An idle computer, or one paused on battery, leaves the appearance alone.

## Permissions (macOS)

| Permission | Asked when | Needed for |
|---|---|---|
| Accessibility | first start | the keyboard's brightness keys |
| Local Network | first contact with Home Assistant | reaching Home Assistant on your network |
| Automation (System Events) | first light/dark switch | light/dark mode |

All three are in System Settings → Privacy & Security. Without Local Network access Daylit cannot
reach Home Assistant; it holds the current levels for a minute, then uses the sun if a location is
set.

## Troubleshooting

- **A monitor shows "no brightness control".** Turn on DDC/CI in the monitor's own menu, and try
  another cable or port: some docks and adapters block DDC. On Apple-silicon Macs, `brew install m1ddc` if it is
  missing. m1ddc does not support Intel Macs; there only monitors that accept macOS's own
  brightness control work.
- **A monitor says "doesn't report its brightness".** Some monitors accept DDC changes but never
  answer reads. Move its slider once: if the monitor reacts, Daylit keeps it as write-only (the
  slider shows the last level sent, and automatic mode drives it). If it refuses, check DDC/CI in
  its menu.
- **Nothing changes automatically.** Check the *Automatic* switch and the status line under it;
  `--check-config` explains config problems. A computer with no input for 5 minutes stops changing
  brightness on purpose (see *Two machines* in the README), and so does a laptop on battery with
  *Pause on battery* on.
- **Logs:** `~/Library/Logs/Daylit/daylit.log` (macOS) and `%LOCALAPPDATA%\Daylit\daylit.log`
  (Windows) record automatic changes, publishes, idle/back, battery pause, theme switches and Home
  Assistant errors.
