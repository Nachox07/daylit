---
name: configure-daylit
description: Set up Daylit (monitor brightness from the sun or Home Assistant) for the user's monitors - install, detect monitors, write and validate config.json. Use when the user asks to install, configure, add a monitor to, or troubleshoot Daylit.
---

# Configure Daylit

Follow [AGENTS.md](../../../AGENTS.md) → *Set up Daylit for a user*. In short:

1. **Install** if `%LOCALAPPDATA%\Programs\Daylit\Daylit.exe` (Windows) or the Mac app is missing.
2. **Detect**: `Daylit.exe --list-monitors | Out-String`. Show the user the monitors and confirm
   which ones Daylit should manage and what to call them.
3. **Ask** only what you can't detect: source (sun / Home Assistant / off), location at city
   level, HA URL, the room's blind and lights entities, and the three `input_number` entities per
   monitor. If the helpers don't exist yet, offer `homeassistant/daylit_helpers.yaml`; don't create
   them in Home Assistant without the user's go-ahead.
4. **Write** the config (keep existing keys; edit, don't overwrite blindly).
5. **Validate**: `Daylit.exe --check-config | Out-String` until `ok` is true. Explain any `notes`.
6. **Reload**: tell the user to use gear menu → *Reload config*, or start the app.

Never ask for, type, read or store the Home Assistant token: the app prompts the user for it.
