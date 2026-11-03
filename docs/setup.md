# Setting up Daylit

Daylit runs with no setup: it finds your external monitors and gives you a slider and keys for each.
This page covers everything else: automatic mode, Home Assistant, permissions and troubleshooting.

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
| `manualHold` | A level you set by hand stays until the automatic target moves this many points (default 5). |
| `pauseOnBattery` | Starting value of the panel's *Pause on battery* switch (default `true`); the switch remembers your choice. |
| `ddcTool` | macOS only: path to `m1ddc` if it is not in Homebrew's usual place. |

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
   - macOS: `security add-generic-password -s daylit-home-assistant -a homeassistant -w`, which
     prompts for it and saves it in the keychain.
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
- `sensor` is published by Daylit with what it applied (`target`, `manual`, `daylight`, `blind`,
  `lights`, `source` attributes), so you can graph it.
- `set` is optional: changing that helper sets the monitor right away, even when the computer is
  idle (dim it from your phone). It then counts as a level set by hand.

With an `http://` URL the token travels unencrypted on your local network; use your `https://`
address if you have one. On macOS, plain `http://` works for local addresses only (an IP, `*.local`
or a single-word host name).

## Keys and shortcuts

- macOS: the keyboard's brightness keys change the monitor holding the focused window (they need
  Accessibility permission; the built-in screen keeps working as usual). `⌃⌥⌘↑/↓` work without that
  permission. Add `⇧` for steps of 1.
- Windows: `Ctrl+Alt+PgUp/PgDn`, plus `Shift` for steps of 1.
- Both: gear menu → *Keyboard shortcuts…* to change them.

## Light and dark mode

Optional, with the sun or Home Assistant source: on by default on Windows, off by default on macOS.
Light mode when daylight comes in (sun above 4°, and with Home Assistant the blind at least 55 %
open) or when the room lights are bright and white; dark otherwise, including night with dim or
orange lights. Each condition has a gap between its on and off thresholds so it does not flip back
and forth, and a manual switch stays until the automatic decision next changes.

- Windows: if the wallpaper is one of Windows 11's stock light/dark pair, it is swapped too; a
  custom wallpaper is never touched.
- macOS: it switches the system appearance through System Events, so the first switch asks for the
  Automation permission. The gear menu also has a manual *Switch to Light/Dark Mode*.

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
  another cable or port: some docks and adapters block DDC. On macOS, `brew install m1ddc` if it is
  missing.
- **Nothing changes automatically.** Check the *Automatic* switch and the status line under it;
  `--check-config` explains config problems. A computer with no input for 5 minutes stops changing
  brightness on purpose (see *Two machines* in the README), and so does a laptop on battery with
  *Pause on battery* on.
- **Logs:** `~/Library/Logs/Daylit/daylit.log` (macOS) and `%LOCALAPPDATA%\Daylit\daylit.log`
  (Windows) record automatic changes, publishes, idle/back, battery pause, theme switches and Home
  Assistant errors.
