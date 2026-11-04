---
name: configure-daylit
description: Set up Daylit (external-monitor brightness from the sun or Home Assistant, macOS and Windows) for the user's monitors - install, detect monitors, write and validate config.json. Use when the user asks to install, configure, add a monitor to, or troubleshoot Daylit.
license: MIT
---

# Configure Daylit

The full guide is [AGENTS.md](../../../AGENTS.md) → *Set up Daylit for a user*. In short:

1. **Install** if the app is missing. Prefer the **latest release download** (AGENTS.md → *Install*
   has the commands): `gh release download -R Nachox07/daylit -p 'Daylit-mac-*.zip'` (or
   `'Daylit-windows-*.zip'`), unzip to `~/Applications` or `%LOCALAPPDATA%\Programs\Daylit`, then
   walk the user through the one-time OS prompt: macOS System Settings → Privacy & Security →
   **Open Anyway**; Windows SmartScreen **More info → Run anyway**, plus the .NET 10 Desktop Runtime
   (`winget install Microsoft.DotNet.DesktopRuntime.10`) if missing. If the user prefers not to run
   unsigned downloads, build from source instead: Windows .NET 10 SDK + `windows\build.ps1`; macOS
   `mac/build.sh`. For DDC monitors on Apple-silicon Macs also `brew install m1ddc` (Intel Macs: not supported by m1ddc).
2. **Detect** the monitors:
   - Windows: `& "$env:LOCALAPPDATA\Programs\Daylit\Daylit.exe" --list-monitors | Out-String`
   - macOS: `~/Applications/Daylit.app/Contents/MacOS/Daylit --list-monitors`

   Show the user the monitors and confirm which ones Daylit should manage and what to call them.
   Use each monitor's `match` (the model number) in the config.
3. **Ask** only what you can't detect: source (`off` / `sun` / `homeAssistant`), location at city
   level, the Home Assistant URL, the room's blind and lights entities, an optional daylight sensor (solar panel power or an
   outdoor lux sensor, for cloudy days), and the three
   `input_number` entities per monitor. Don't guess entity IDs. If the helpers don't exist yet,
   offer `homeassistant/daylit_helpers.yaml`; don't create them in Home Assistant without the
   user's go-ahead.
4. **Write** the config: Windows `%APPDATA%\Daylit\config.json`, macOS
   `~/.config/daylit/config.json`. Keep existing keys; edit, don't overwrite blindly.
   `config.example.json` shows every key.
5. **Validate** until `ok` is true, and explain any `notes`:
   - Windows: `& "$env:LOCALAPPDATA\Programs\Daylit\Daylit.exe" --check-config | Out-String`
   - macOS: `~/Applications/Daylit.app/Contents/MacOS/Daylit --check-config`
6. **Reload**: tell the user to use the gear menu → *Reload config*, or start the app.

Never ask for, type, read or store the Home Assistant token. Both apps prompt the user for it on
first start (gear menu → *Home Assistant token…* to change it); on macOS the user may instead run
`security add-generic-password -s daylit-home-assistant -a homeassistant -w` (it prompts).
`--check-config` reports only whether one is stored.
