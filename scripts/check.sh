#!/bin/bash
# Every check a change needs before it is pushed, in one command (macOS; the Windows app builds here too).
#   scripts/check.sh            parity guard, both test suites, both builds (0 warnings)
#   scripts/check.sh --quick    parity guard and both test suites, no builds
#   PARITY_BASE=<ref>           what the parity guard compares against (default origin/main)
# CI runs the same steps (.github/workflows/build.yml); this is the local copy for people and agents.
set -u
cd "$(dirname "$0")/.."
quick=false
[ "${1:-}" = "--quick" ] && quick=true

if command -v dotnet >/dev/null 2>&1; then DOTNET=dotnet
elif [ -x "$HOME/.dotnet/dotnet" ]; then DOTNET="$HOME/.dotnet/dotnet"
else DOTNET=""; fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/daylit-check.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
results=()
failed=0

# step <name> <command...>: runs it with its output in a log, prints the log's tail when it fails.
step() {
  local name=$1; shift
  local log="$tmp/$(echo "$name" | tr ' /' '__').log"
  printf '%-34s' "$name"
  if "$@" >"$log" 2>&1; then
    echo "ok"; results+=("ok    $name")
  else
    echo "FAILED"; results+=("FAIL  $name"); failed=1
    tail -n 40 "$log" | sed 's/^/    /'
  fi
}

no_warnings() {   # <log> : fails when the build log has a compiler warning
  ! grep -E "(warning:|warning [A-Z]+[0-9]+:)" "$1"
}

mac_build() {
  # A clean compile in a scratch folder: an incremental build does not repeat a warning from a file it
  # did not recompile. Then build.sh, which wraps and signs the app the way a user gets it.
  (cd mac && swift build -c release --product Daylit --scratch-path "$tmp/swift-build") >"$tmp/mac-build.out" 2>&1 ||
    { cat "$tmp/mac-build.out"; return 1; }
  no_warnings "$tmp/mac-build.out" || return 1
  mac/build.sh "$tmp/app"
}

win_build() {
  "$DOTNET" build windows/Daylit.csproj -c Release --nologo --no-incremental -o "$tmp/win" >"$tmp/win-build.out" 2>&1 || { cat "$tmp/win-build.out"; return 1; }
  no_warnings "$tmp/win-build.out"
}

base=${PARITY_BASE:-origin/main}
step "parity guard" python3 -I scripts/parity-guard.py --base "$base" --worktree
step "mac tests (swift test)" bash -c 'cd mac && swift test'
if [ -n "$DOTNET" ]; then
  step "windows tests (dotnet test)" "$DOTNET" test windows/tests/Daylit.Tests.csproj --nologo
else
  echo "windows tests: SKIPPED (no dotnet: install the .NET 10 SDK)"; results+=("SKIP  windows tests (no dotnet)"); failed=1
fi
if ! $quick; then
  step "mac build, 0 warnings" mac_build
  if [ -n "$DOTNET" ]; then step "windows build, 0 warnings" win_build; fi
fi

echo
printf '%s\n' "${results[@]}"
if [ $failed -eq 0 ]; then echo "ALL CHECKS PASSED"; else echo "CHECKS FAILED"; fi
exit $failed
