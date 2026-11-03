# Daylit: notes for AI agents

Daylit keeps external monitors at the right brightness through the day (sun, or Home Assistant with
a blind and room lights). This file tells an agent how to **set it up for a user** and how to
**work on the code**. Human docs: [README.md](README.md).

## Rules

- **Never handle the Home Assistant token.** Don't ask for it, type it, paste it, read it from the
  credential store or put it in any file. The app asks on first start and the user pastes it.
  Agents may only check that one *is stored* (`--check-config` reports `tokenStored`).
- **Don't change Home Assistant** unless the user asks. Creating the helpers is the user's call;
  offer [`homeassistant/daylit_helpers.yaml`](homeassistant/daylit_helpers.yaml).
- The config holds no secrets, but it has the user's HA address and entity names: keep it out of
  commits and public places.

## Set up Daylit for a user

### 1. Install

| | |
|---|---|
| Windows | .NET 10 SDK (`winget install Microsoft.DotNet.SDK.10`), then `windows\build.ps1` → `%LOCALAPPDATA%\Programs\Daylit\Daylit.exe` |
| macOS | `mac/build.sh`; for DDC monitors also `brew install m1ddc` |

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

**macOS:** no CLI yet. `system_profiler SPDisplaysDataType` lists the names; `m1ddc display list`
shows which answer DDC.

### 3. Pick a source and write the config

Windows `%APPDATA%\Daylit\config.json`, macOS `~/.config/daylit/config.json`. Every key is
optional; [`config.example.json`](config.example.json) shows them all.

| `source` | needs | use when |
|---|---|---|
| `off` | nothing | sliders and hotkeys only |
| `sun` | `location` (lat/lon) | no Home Assistant |
| `homeAssistant` | `homeAssistant.url` (+ token, pasted by the user) | the user has HA; `location` adds a fallback when HA is down |

Per monitor: `match`, optional `label`, local levels `day` / `blindDown` / `night` (0–100), and with
Home Assistant a `homeAssistant` block naming three `input_number` entities, an optional `sensor`
to publish and an optional `set` helper (change it in HA to set the monitor now, even when idle). HA-wide entities (`autoSwitch`, `sun`, `cover`, `lights`) are all optional.

Ask the user for: latitude/longitude (city level is enough), the HA URL, and which blind / lights
entities belong to the room. Don't guess entity IDs.

### 4. Validate

```powershell
& "$env:LOCALAPPDATA\Programs\Daylit\Daylit.exe" --check-config | Out-String   # exit 0 = ok
```

It reports `problems` (must fix), `notes` (e.g. a configured monitor that is plugged into another
computer right now, or no token stored yet) and which config entry matched which monitor. Then use
**Reload config** in the panel's gear menu, or start the app.

### 5. Hand over to the user

- Home Assistant: the app asks for a long-lived token (HA profile → Security); the user pastes it.
- Hotkeys default to `Ctrl+Alt+PgUp/PgDn` (+Shift for steps of 1); gear menu → *Keyboard shortcuts…*.
- "Open at sign-in" is a checkbox in the panel.
- Log: `%LOCALAPPDATA%\Daylit\daylit.log` shows automatic changes (`auto:`), publishes, idle/back,
  theme switches and Home Assistant errors.

## Work on the code

- `windows/`: WPF on .NET 10 with the Fluent theme. `App.cs` decisions, `Ui.cs` windows,
  `Displays.cs` monitor IO, `Sources.cs` Home Assistant and sun, `Config.cs`, `Cli.cs`.
  Build: `dotnet build windows/Daylit.csproj -c Release` (0 errors before pushing).
- `mac/`: one Swift file, `mac/build.sh`.
- Keep the two apps behaving the same (README → *How it works*). The HDR rule matters: with HDR on,
  Windows brightness goes through the SDR white level (undocumented `DisplayConfigSetDeviceInfo`
  type `0xFFFFFFEE`), not DDC.
