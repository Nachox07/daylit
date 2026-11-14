# Daylit: notes for AI agents

Daylit keeps external monitors at the right brightness through the day (sun, or Home Assistant with
a blind and room lights). This file tells an agent how to **set it up for a user** and how to
**work on the code**. Human docs: [README.md](README.md).

## Rules

- **Never handle the Home Assistant token.** Don't ask for it, type it, paste it, read it from the
  credential store or put it in any file. Both apps ask for it on first start (gear menu →
  *Home Assistant token…* to change it) and the user pastes it.
  Agents may only check that one *is stored* (`--check-config` reports `tokenStored`).
- **Don't change Home Assistant** unless the user asks. Creating the helpers is the user's call;
  offer [`homeassistant/daylit_helpers.yaml`](homeassistant/daylit_helpers.yaml).
- The config holds no secrets, but it has the user's HA address and entity names: keep it out of
  commits and public places.

## Set up Daylit for a user

The short version of these steps is also an Agent Skill:
[`.agents/skills/configure-daylit/SKILL.md`](.agents/skills/configure-daylit/SKILL.md)
(`.claude/skills/configure-daylit` points Claude Code to it). Agents without skill support can
follow this section directly.

### 1. Install

Two ways. **Prefer the download**: no toolchain, a minute of work. Offer **building from source**
when the user would rather not run an unsigned app, or wants to change the code.

**Download the latest release** (the app is not signed by Apple or Microsoft, so the OS asks once):

macOS 14+ (one app for Apple silicon and Intel):

```sh
gh release download -R Nachox07/daylit -p 'Daylit-mac-*.zip' -D /tmp/daylit --clobber
# without gh: https://github.com/Nachox07/daylit/releases/latest
ditto -x -k /tmp/daylit/Daylit-mac-*.zip ~/Applications/
open ~/Applications/Daylit.app
```

The first open is blocked because the app is not notarized. Tell the user: System Settings →
Privacy & Security → scroll to the message about Daylit → **Open Anyway**, then confirm. For DDC
monitors on Apple silicon also `brew install m1ddc` (not available for Intel Macs: there only
monitors that accept macOS's own brightness control work). Then walk them through the permissions macOS asks for
(Accessibility for the brightness keys, Local Network for Home Assistant).

Windows 10/11:

```powershell
gh release download -R Nachox07/daylit -p 'Daylit-windows-*.zip' -D $env:TEMP\daylit --clobber
Expand-Archive "$env:TEMP\daylit\Daylit-windows-*.zip" "$env:LOCALAPPDATA\Programs\Daylit" -Force
winget install Microsoft.DotNet.DesktopRuntime.10   # if `dotnet --list-runtimes` has no WindowsDesktop 10.x
& "$env:LOCALAPPDATA\Programs\Daylit\Daylit.exe"
```

If SmartScreen shows "Windows protected your PC", tell the user to click **More info → Run anyway**.

**Build from source** (needs the toolchain; the result is the same app):

| | |
|---|---|
| Windows | .NET 10 SDK (`winget install Microsoft.DotNet.SDK.10`), then `windows\build.ps1` → `%LOCALAPPDATA%\Programs\Daylit\Daylit.exe` |
| macOS | Xcode command-line tools, then `mac/build.sh` → `~/Applications/Daylit.app`; for DDC monitors on Apple silicon also `brew install m1ddc` |

### 2. Find the monitors

**Windows:** Daylit is a GUI app, so pipe its output to wait for it:

```powershell
& "$env:LOCALAPPDATA\Programs\Daylit\Daylit.exe" --list-monitors | Out-String
```

```json
{ "monitors": [ { "name": "Dell AW3821DW", "match": "AW3821DW", "hdr": true,
                  "control": "sdr-white-level", "brightness": 82, "controllable": true } ] }
```

Use `match` in the config (any case-insensitive part of `name`; the model number is the stable
choice). `controllable: false` means DDC/CI is off in the monitor's menu or the cable/dock blocks it.

**macOS:**

```sh
~/Applications/Daylit.app/Contents/MacOS/Daylit --list-monitors
```

Same JSON, with `control` `native` (macOS's own brightness, works with HDR on) or `ddc` (through
`m1ddc`), and `uuid` instead of `display`. Built-in screens are listed with `builtIn: true` and
their brightness: the panel shows them as a manual slider only, automatic mode leaves them to macOS.
`controllable: false` with `brightness: null` on a DDC monitor can also mean it accepts changes but
never reports its level; the panel handles that once the user moves its slider.

### 3. Pick a source and write the config

Windows `%APPDATA%\Daylit\config.json`, macOS `~/.config/daylit/config.json` (or in iCloud Drive
when the user turned on *Keep settings in iCloud Drive*: `--check-config` prints the `path` in use). Every key is
optional; [`config.example.json`](config.example.json) shows them all.

| `source` | needs | use when |
|---|---|---|
| `off` | nothing | sliders and hotkeys only |
| `sun` | `location` (lat/lon) | no Home Assistant |
| `homeAssistant` | `homeAssistant.url` (+ token, pasted by the user) | the user has HA; `location` adds a fallback when HA is down |

An optional `tuning` block holds every threshold (sun elevations, light/dark switch points, timing);
see [docs/setup.md → Tuning](docs/setup.md#tuning). Leave it out unless the user asks for a change.

Per monitor: `match`, optional `label`, local levels `day` / `blindDown` / `night` (0–100), an optional `nightLights` (0–100: the level after sunset with the room lights on; only with a Home Assistant lights entity), an
optional fixed `contrast` (0–100, DDC monitors only, set at start and after a display change), and with
Home Assistant a `homeAssistant` block naming three `input_number` entities (a fourth, `nightLights`, is optional), an optional `sensor`
to publish and an optional `set` helper (change it in HA to set the monitor now, even when idle or Automatic is off). HA-wide entities (`autoSwitch`, `sun`, `cover`, `lights`, and `light`: a daylight sensor such as solar panel power, which needs `location`) are all optional.
`homeAssistant.push` (experimental, default off) makes Home Assistant tell Daylit when one of those entities changes ([docs/setup.md → Experimental](docs/setup.md#experimental); also Settings → Home Assistant → *Instant updates*); leave it off unless the user asks.

`checkUpdates` (default on) is the daily check for a newer Daylit release (one request to GitHub's public
releases list, nothing about the user; [docs/setup.md → Updates](docs/setup.md#updates)); `false` turns it
off, as does Settings → App → *Automatically check for updates*.

Ask the user for: latitude/longitude (city level is enough), the HA URL, and which blind / lights
entities belong to the room. Don't guess entity IDs.

### 4. Validate

```powershell
& "$env:LOCALAPPDATA\Programs\Daylit\Daylit.exe" --check-config | Out-String   # exit 0 = ok
```

```sh
~/Applications/Daylit.app/Contents/MacOS/Daylit --check-config   # macOS; exit 0 = ok
```

It reports `problems` (must fix), `notes` (e.g. a configured monitor that is plugged into another
computer right now, or no token stored yet) and which config entry matched which monitor. Then use
**Reload config** in the panel's gear menu, or start the app.

### 5. Hand over to the user

- Home Assistant: the app asks for a long-lived token (HA profile → Security) and the user pastes it.
  Windows keeps it in Credential Manager, macOS in the keychain. On macOS the user can also store it
  from Terminal: `security add-generic-password -s daylit-home-assistant -a homeassistant -w` (it prompts);
  Daylit then moves it to a keychain item only Daylit can read. With *Keep settings in iCloud Drive*, a
  `homeAssistant.url` or `tokenName` changed on another Mac (or by hand in the file) waits for the user to
  choose **Use** in the panel before the token goes there; a URL changed in the Settings window does not.
- Hotkeys default to `Ctrl+Alt+PgUp/PgDn` on Windows and `⌃⌥⌘↑/↓` on macOS (+Shift for steps of 1);
  gear menu → *Keyboard shortcuts…*. `⌃⌥⌘D` / `Ctrl+Alt+D` switch light and dark mode (same switch as the
  gear menu item). On macOS the brightness keys also work once the user grants
  Accessibility permission; on Windows a keyboard's own brightness keys work with no setup.
- When a newer release is out the panel says so (*Download*, *What's new*, *Not now*); gear menu →
  *Check for updates…* checks right away. Daylit never installs anything itself.
- The gear menu's *Settings…* window lets the user change the source, location, levels, contrast (DDC
  monitors) and Home Assistant entities later without editing JSON; it keeps every other key in the file.
- "Open at sign-in" / "Open at login", *Pause on battery* and *Light or dark mode from daylight* are
  in the panel's gear menu; the panel itself only has the monitor sliders, the link (sync) button
  and *Automatic*. A level set by hand keeps its distance from the
  automatic one until sunset (one set at night: until the sun has come up, even if the computer slept through it; at most 36 hours; without a location in the config: 18 hours at night, the calendar day by day), and survives a restart (for up to 12 hours). Repeated hand changes in the
  same situation make the panel offer a new level (*Apply* / *Not now*, [docs/setup.md → Suggested
  levels](docs/setup.md#suggested-levels)); the samples stay on that machine in `corrections.json`.
- "Pause on battery" (laptops only, on by default; config `pauseOnBattery`): no automatic work on
  battery. "Light or dark mode from daylight" (on by default on Windows, off on macOS; on macOS the
  first switch asks for the Automation permission for System Events).
- With no external monitor plugged in, the panel shows an empty state and nothing is polled. The
  built-in screen is never automated (on macOS it gets a manual slider while the lid is open;
  `"builtIn": false` hides it).
- Log: `%LOCALAPPDATA%\Daylit\daylit.log` (Windows) or `~/Library/Logs/Daylit/daylit.log` (macOS)
  shows automatic changes (`auto:`), publishes, idle/back, theme switches, battery pause/resume, suggested levels (`suggest:`), update checks (`update:`) and Home Assistant errors.

## Work on the code

- `windows/`: WPF on .NET 10 with the Fluent theme. `Rules.cs` decisions and the sun (pure, tested),
  `App.cs` the tick, `Ui.cs` windows, `Displays.cs` monitor IO, `Sources.cs` Home Assistant,
  `Config.cs`, `Cli.cs`. Build: `dotnet build windows/Daylit.csproj -c Release`; tests:
  `dotnet test windows/tests/Daylit.Tests.csproj` (runs on any OS). Both green before pushing.
- `mac/`: a Swift package. `Sources/DaylitCore` decisions (pure, tested), `Sources/Daylit` the app.
  Tests: `cd mac && swift test`; build: `mac/build.sh` (0 errors and 0 warnings before pushing). `DAYLIT_CONFIG`
  overrides the config path, `DAYLIT_DEBUG=1` logs to stdout, `DAYLIT_NO_KEYS=1` skips the
  Accessibility prompt, `DAYLIT_SHOW=panel` (or `settings`) and `DAYLIT_APPEARANCE=light|dark` are for screenshots, `DAYLIT_DEMO=1` plays the scripted demo for recordings.
- UI changes: CI compares offscreen renders of the panel and indicator with the baselines in
  `mac/Tests/Snapshots` and `windows/tests/Snapshots`. An intended change needs re-recorded
  baselines from CI (CONTRIBUTING.md → *UI snapshots*), so the PR shows the image diff.
- Keep the two apps behaving the same (README → *How it works*). The HDR rule matters: with HDR on,
  Windows brightness goes through the SDR white level (undocumented `DisplayConfigSetDeviceInfo`
  type `0xFFFFFFEE`), not DDC.
