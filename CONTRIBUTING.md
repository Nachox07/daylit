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

### UI snapshots (visual regression)

Each app can draw its panel and on-screen indicator offscreen from fixed, made-up state (two
monitors, two and three linked, one set by hand, none; no hardware and no Home Assistant), in light and dark at
2x. The baselines are committed in `mac/Tests/Snapshots/` and `windows/tests/Snapshots/`, so a
pull request that changes the UI shows the before and after in GitHub's image diff (side by side,
swipe, onion skin).

CI renders them on every push and compares with the baselines: an image fails when more than 0.5%
of its pixels change (anti-aliasing noise stays well below). The `snapshots-mac` /
`snapshots-windows` artifacts of the run hold the new renders and, for a failure, `diff-*.png`
with the changed pixels in red.

When the change is intended, re-record the baselines on CI's machines (fonts and rendering differ
slightly between OS versions, so baselines made on your own computer would not match):

```sh
gh workflow run build.yml --ref <your-branch> -f record=true
gh run download <run-id> -n snapshots-mac -D mac/Tests/Snapshots
gh run download <run-id> -n snapshots-windows -D windows/tests/Snapshots
git add mac/Tests/Snapshots windows/tests/Snapshots && git commit -m "UI snapshots: <what changed>"
```

Locally: `Daylit --render-snapshots <dir>` and `Daylit --compare-snapshots <baseline> <dir>`
(Windows: pipe to `Out-String`). The Mac's Liquid Glass is not part of the snapshots: they draw a
plain background so they look the same on every macOS version.

## Rules for every change

- **Tests pass and 0 errors before you push**, and on macOS 0 warnings too. CI tests and builds both apps on every push
  (`.github/workflows/build.yml`). The macOS job runs on `macos-15`, which can have an older Swift than a
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
| `DAYLIT_DEMO=1` | scripted demo on made-up monitors for the GIF and videos; touches nothing real (`DAYLIT_DEMO_SCREEN` picks the screen) |
| `DAYLIT_APPEARANCE=light` / `dark` | force the app's appearance (screenshots) |

Run the binary directly to use them:
`DAYLIT_DEBUG=1 ~/Applications/Daylit.app/Contents/MacOS/Daylit`. Quit the running Daylit first;
a second copy hands over to the first one and exits.

Logs: `~/Library/Logs/Daylit/daylit.log` and `%LOCALAPPDATA%\Daylit\daylit.log` (automatic changes,
publishes, idle/back, battery pause, theme switches, Home Assistant errors).

## Screenshots

The README's panel pictures are the UI snapshot baselines (`mac/Tests/Snapshots/panel-two-linked-*.png`,
`windows/tests/Snapshots/panel-two-linked-*.png`): drawn from made-up monitors, so they are always
current and never show anyone's setup. Re-recording the snapshots (*Tests → UI snapshots* above)
updates them. To change what they show, edit the scenes in `mac/Sources/Daylit/Snapshots.swift` and
`windows/Snapshots.cs` (generic monitor names, round levels), then re-record.

### Brightness chart GIF

`docs/chart-{light,dark}.gif` (docs/setup.md) are drawn by the same code and made-up state as the
`curve-*` snapshots, so they need no screen recording and look the same on every Mac:

```sh
cd mac && swift build && B=$(swift build --show-bin-path)/Daylit
for m in light dark; do
  $B --render-chart-frames /tmp/chart-$m $([ $m = dark ] && echo dark)
  ffmpeg -framerate 12 -i /tmp/chart-$m/frame-%04d.png -vf "scale=760:-1:flags=lanczos,palettegen=max_colors=128:stats_mode=diff" /tmp/pal.png
  ffmpeg -framerate 12 -i /tmp/chart-$m/frame-%04d.png -i /tmp/pal.png \
    -lavfi "scale=760:-1:flags=lanczos[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" -loop 0 ../docs/chart-$m.gif
done
```

The storyboard is `Snapshots.chartFrames` in `mac/Sources/Daylit/Snapshots.swift`. Re-render after a
change to the chart, as with the snapshots.

### Demo GIF and video (macOS)

`docs/demo-{light,dark}.gif` (and the social videos) come from a scripted demo: `DAYLIT_DEMO=1`
opens a colourful backdrop with the panel on top and plays a 15 s storyboard on made-up monitors:
the second monitor slides down alone, the link turns on and both move together keeping their
offset, the link turns off and the second slides back up alone. It's pure UI: it never touches
real brightness, Home Assistant or saved settings, and it runs alongside your normal Daylit.
On macOS 26+ it shows the real Liquid Glass. Use a 2x (Retina) screen so the capture is crisp.

```sh
mac/build.sh /tmp/demo-build
for m in light dark; do
  DAYLIT_DEMO=1 DAYLIT_APPEARANCE=$m DAYLIT_DEMO_SCREEN="part of a 2x screen's name" \
    /tmp/demo-build/Daylit.app/Contents/MacOS/Daylit > /tmp/demo.txt &
  sleep 2; R=$(grep -o -- '-R[0-9,-]*' /tmp/demo.txt)    # it prints the area to capture
  rm -f /tmp/demo-$m.mov; screencapture -x -v -V 14 $R /tmp/demo-$m.mov   # an existing file can make it hang
  pkill -f demo-build/Daylit.app
  ffmpeg -i /tmp/demo-$m.mov -vf "crop=800:520:320:145,fps=12,palettegen=max_colors=128:stats_mode=diff" /tmp/pal.png
  ffmpeg -i /tmp/demo-$m.mov -i /tmp/pal.png \
    -lavfi "crop=800:520:320:145,fps=12[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=3:diff_mode=rectangle" \
    -loop 0 docs/demo-$m.gif
done
```

Keep each GIF under 1.5 MB and check a few frames. To change the story, edit `step()` in
`mac/Sources/Daylit/Demo.swift`.
