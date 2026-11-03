# Contributing to Daylit

Daylit is two small native apps, one per OS, that must behave the same. README → *How it works* is
the shared behaviour; change it there first when you change what the apps do.

## Build and run

**macOS** (macOS 14+, Xcode command-line tools; `brew install m1ddc` for DDC monitors):

```sh
mac/build.sh                         # → ~/Applications/Daylit.app (or: mac/build.sh <folder>)
open ~/Applications/Daylit.app
```

A Swift package (`mac/Package.swift`, no Xcode project). `build.sh` runs `swift build` and wraps the
binary into the app bundle with its Info.plist and signature.

- `Sources/DaylitCore/`: the decisions, with no AppKit: `Config`, `Sun`, `Rules` (brightness
  target, hand-set hold, idle, the Home Assistant "set" helper, light/dark), `HATemplate`.
- `Sources/Daylit/`: the app. `Model.swift` runs the tick, `Displays.swift` monitor I/O,
  `Sources.swift` Home Assistant calls and the keychain, `Keys.swift` brightness keys and
  shortcuts, `UI.swift` the panel, on-screen indicator and shortcuts window, `Look.swift`,
  `Cli.swift`, `Log.swift`, `App.swift`.

**Windows** (Windows 10/11, .NET 10 SDK):

```powershell
windows\build.ps1                    # → %LOCALAPPDATA%\Programs\Daylit\Daylit.exe
dotnet build windows\Daylit.csproj -c Release
```

WPF with the Fluent theme. `Rules.cs` holds the decisions and the sun (no WPF or Win32), `App.cs`
runs the tick, `Ui.cs` the windows, `Displays.cs` monitor I/O, `Sources.cs` Home Assistant calls,
`Config.cs`, `Cli.cs`. It also builds on macOS or Linux (`EnableWindowsTargeting`), which is
enough to check that it compiles.

## Tests

The decisions are tested on both sides with the same cases: sun elevation against known values,
the brightness target, a hand-set level being kept, the idle machine staying quiet, the Home
Assistant "set" helper, the light/dark gap, config parsing (missing, broken, the example file) and
the template.

```sh
cd mac && swift test                                 # DaylitCore, XCTest
dotnet test windows/tests/Daylit.Tests.csproj        # Rules.cs + Config.cs, xUnit; runs on any OS
```

CI runs both before building. Put new logic where it can be tested (`DaylitCore` / `Rules.cs`) and
keep the app files for the parts that touch the OS: displays, keys, windows, network.

## Rules for every change

- **Tests pass and 0 errors before you push**, and on macOS 0 warnings too. CI tests and builds both apps on every push
  (`.github/workflows/build.yml`). The macOS job runs on `macos-14` with an older Swift than a
  current Mac, and it is stricter about the main actor: don't give a SwiftUI `@State` a default
  value that reads `@MainActor` state; pass it in from the caller instead.
- **Keep the two apps in step.** A behaviour change lands in both, or the README says why not
  (for example, `control` is macOS only).
- **Never handle a Home Assistant token** in code, logs, tests, screenshots or commits. The token
  lives in the keychain (macOS) or Credential Manager (Windows). `--check-config` reports only
  whether one is stored.
- **Commits:** a short subject that starts with the area (`Mac:`, `Windows:`, `Docs:`) and says what
  changed for the user, then a body with the why when it isn't obvious. One logical change per
  commit.

## Test without Home Assistant

- No config at all: Daylit manages the detected monitors by hand (sliders, keys, indicator).
- `"source": "sun"` with a `location` gives automatic mode from the sun, computed locally.
- On macOS, `DAYLIT_CONFIG=/path/to/test.json` points the app at a test config, so your own stays
  untouched. On Windows, rename `%APPDATA%\Daylit\config.json` while you test, then put it back
  and use *Reload config*.

## CLI and debug switches

Both apps: `--list-monitors` (JSON: monitors, the `match` to use, control method, brightness) and
`--check-config` (JSON: problems, notes, which config entry matched which monitor; exit 0 = ok).
On Windows pipe them (`Daylit.exe --list-monitors | Out-String`) so the shell waits for the GUI app.

macOS environment variables:

| Variable | Effect |
|---|---|
| `DAYLIT_CONFIG=<path>` | use this config file |
| `DAYLIT_DEBUG=1` | detailed log on stdout |
| `DAYLIT_NO_KEYS=1` | skip the Accessibility prompt and the brightness-key tap |
| `DAYLIT_DEBUG_NO_DISPLAYS=1` | act as if no external monitor were connected (the empty state) |
| `DAYLIT_SHOW=panel` | open the panel right after start and keep it open (screenshots, recordings) |
| `DAYLIT_APPEARANCE=light` / `dark` | force the app's appearance (screenshots) |

Run the binary directly to use them:
`DAYLIT_DEBUG=1 ~/Applications/Daylit.app/Contents/MacOS/Daylit`. Quit the running Daylit first;
a second copy hands over to the first one and exits.

Logs: `~/Library/Logs/Daylit/daylit.log` and `%LOCALAPPDATA%\Daylit\daylit.log` (automatic changes,
publishes, idle/back, battery pause, theme switches, Home Assistant errors).

## Screenshots

Files: `docs/screenshots/{mac,windows}-panel-{light,dark}.png`, plus the optional on-screen
indicator stills `mac-hud-{light,dark}.png` (committed) and `windows-osd-{light,dark}.png` (not
committed: Windows' translucent indicator shows the desktop behind it, so only add them over a
plain background). Capture the window only, with no shadow, desktop, other
apps or personal names on screen. Use generic monitor labels (the system names are fine) and a
config without your own Home Assistant address showing in the panel.

**macOS:**

```sh
pkill -x Daylit
DAYLIT_APPEARANCE=light DAYLIT_SHOW=panel ~/Applications/Daylit.app/Contents/MacOS/Daylit &
sleep 3
# the panel's window number
swift -e 'import CoreGraphics
for w in CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
where (w["kCGWindowOwnerName"] as? String) == "Daylit" { print(w["kCGWindowNumber"]!, w["kCGWindowBounds"]!) }'
screencapture -o -l <number> docs/screenshots/mac-panel-light.png
```

Repeat with `DAYLIT_APPEARANCE=dark`. For the indicator, press `⌃⌥⌘↑` and capture its window
within a second (it fades out), or use `screencapture -o -w` and click it.

**Windows:** open the panel from the tray and use Snipping Tool (`Win+Shift+S`) in *Window* mode.
For the indicator, press `Ctrl+Alt+PgUp` first, then snip within a second; it is translucent, so put
a plain, empty window behind it first. Switch light/dark in Settings → Personalization → Colors (or
the gear menu's *Switch to dark mode*) and capture again.

Check each image before committing: nothing personal, nothing cut off, same size as the one it
replaces where possible. The README shows the two `panel` pairs; the indicator stills are optional.

### Demo GIF (macOS)

`docs/demo-{light,dark}.gif` is the panel while a slider is dragged. With `DAYLIT_SHOW=panel` the
panel stays open while you work in another app, so you can record it:

```sh
pkill -x Daylit
DAYLIT_APPEARANCE=light DAYLIT_SHOW=panel ~/Applications/Daylit.app/Contents/MacOS/Daylit &
sleep 3
# X,Y,W,H from the window bounds printed by the snippet above
screencapture -x -v -V 8 -R X,Y,W,H /tmp/demo.mov   # drag a slider during these 8 s
ffmpeg -ss 1 -t 6 -i /tmp/demo.mov -vf "fps=12,palettegen=max_colors=96:stats_mode=diff" /tmp/pal.png
ffmpeg -ss 1 -t 6 -i /tmp/demo.mov -i /tmp/pal.png \
  -lavfi "fps=12[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=3:diff_mode=rectangle" \
  -loop 0 docs/demo-light.gif
```

Repeat with `DAYLIT_APPEARANCE=dark`. Keep each GIF under 1 MB (lower `fps` or `max_colors` if not),
put the slider back where it was, and check a few frames: nothing outside the panel.
