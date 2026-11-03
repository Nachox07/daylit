---
name: configure-daylit
description: Set up Daylit (external-monitor brightness from the sun or Home Assistant, macOS and Windows) for the user's monitors - install, detect monitors, write and validate config.json. Use when the user asks to install, configure, add a monitor to, or troubleshoot Daylit.
license: MIT
---

# Configure Daylit

The full guide is [AGENTS.md](../../../AGENTS.md) → *Set up Daylit for a user*. In short:

1. **Install** if the app is missing. Windows: .NET 10 SDK, then `windows\build.ps1`
   (→ `%LOCALAPPDATA%\Programs\Daylit\Daylit.exe`). macOS: `mac/build.sh`
   (→ `~/Applications/Daylit.app`); for DDC monitors also `brew install m1ddc`.
2. **Detect** the monitors:
   - Windows: `& "$env:LOCALAPPDATA\Programs\Daylit\Daylit.exe" --list-monitors | Out-String`
   - macOS: `~/Applications/Daylit.app/Contents/MacOS/Daylit --list-monitors`

   Show the user the monitors and confirm which ones Daylit should manage and what to call them.
   Use each monitor's `match` (the model number) in the config.
3. **Ask** only what you can't detect: source (`off` / `sun` / `homeAssistant`), location at city
   level, the Home Assistant URL, the room's blind and lights entities, and the three
   `input_number` entities per monitor. Don't guess entity IDs. If the helpers don't exist yet,
   offer `homeassistant/daylit_helpers.yaml`; don't create them in Home Assistant without the
   user's go-ahead.
4. **Write** the config: Windows `%APPDATA%\Daylit\config.json`, macOS
   `~/.config/daylit/config.json`. Keep existing keys; edit, don't overwrite blindly.
   `config.example.json` shows every key.
5. **Validate** with `--check-config` (same commands as step 2) until `ok` is true. Explain any
   `notes`.
6. **Reload**: tell the user to use the gear menu → *Reload config*, or start the app.

Never ask for, type, read or store the Home Assistant token. On Windows the app prompts the user
for it; on macOS the user stores it with
`security add-generic-password -s daylit-home-assistant -a homeassistant -w` (it prompts).
`--check-config` reports only whether one is stored.
