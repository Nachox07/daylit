#!/bin/sh
# Renders the UI snapshots with a built Daylit.app and compares them with the baselines in
# mac/Tests/Snapshots. CI runs it on every build and on every release, so the two cannot drift.
#   mac/snapshots.sh <Daylit.app> <output folder> [record]
# With "record" as the third argument it only renders (new baselines; see CONTRIBUTING.md).
set -eu
APP="$1"; OUT="$2"; RECORD="${3:-}"
BIN="$APP/Contents/MacOS/Daylit"
"$BIN" --render-snapshots "$OUT"
if [ "$RECORD" != "record" ]; then
  "$BIN" --compare-snapshots "$(cd "$(dirname "$0")" && pwd)/Tests/Snapshots" "$OUT"
fi
