#!/bin/bash
# Publishes a release to the package managers. The release workflow runs it after the release is up.
#   packaging/publish.sh 1.3.0            # GH_TOKEN must be set (see packaging/README.md)
#   DRY_RUN=1 packaging/publish.sh 1.3.0  # do everything locally, push and open nothing
# Steps, each skipped when it has nothing to do:
#   1. update.sh rewrites packaging/ for the version (needs the release published).
#   2. Homebrew: copies the cask to Nachox07/homebrew-tap and pushes.
#   3. winget: only with WINGET=1. Syncs the Nachox07/winget-pkgs fork, adds the manifests on a
#      branch and opens a pull request to microsoft/winget-pkgs.
#   4. Opens a pull request here with the updated packaging/ files.
set -euo pipefail

VERSION="${1:?usage: $0 <version, e.g. 1.3.0>}"
DRY="${DRY_RUN:-0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
run() { if [ "$DRY" = 1 ]; then echo "dry run: $*"; else "$@"; fi; }
clone() { git clone -q --depth 1 "https://x-access-token:${GH_TOKEN}@github.com/$1.git" "$2"; }
commit() { git -C "$1" -c user.name="daylit-release" -c user.email="noreply@github.com" commit -q -m "$2"; }
[ "$DRY" = 1 ] || [ -n "${GH_TOKEN:-}" ] || { echo "GH_TOKEN is not set" >&2; exit 1; }

"$ROOT/packaging/update.sh" "$VERSION"

# Homebrew tap
if [ "$DRY" = 1 ]; then
  echo "dry run: push Casks/daylit.rb $VERSION to Nachox07/homebrew-tap"
else
  clone Nachox07/homebrew-tap "$WORK/tap"
  # A rerun of an older release must not replace a newer cask.
  TAP_VERSION="$(sed -n 's/^  version "\(.*\)"/\1/p' "$WORK/tap/Casks/daylit.rb")"
  NEWEST="$(printf '%s\n%s\n' "$TAP_VERSION" "$VERSION" | sort -V | tail -n 1)"
  [ "$NEWEST" = "$VERSION" ] || { echo "homebrew: the tap has $TAP_VERSION, newer than $VERSION; left alone"; SKIP_TAP=1; }
  [ "${SKIP_TAP:-0}" = 1 ] || cp "$ROOT/packaging/homebrew/Casks/daylit.rb" "$WORK/tap/Casks/daylit.rb"
  if git -C "$WORK/tap" diff --quiet; then
    echo "homebrew: the tap already has $VERSION"
  else
    git -C "$WORK/tap" add Casks/daylit.rb
    commit "$WORK/tap" "daylit $VERSION"
    git -C "$WORK/tap" push -q origin HEAD
    echo "homebrew: pushed daylit $VERSION"
  fi
fi

# winget
BRANCH="Nachox07.Daylit-$VERSION"
if [ "${WINGET:-0}" != 1 ]; then
  echo "winget: skipped (WINGET is not 1)"
elif [ "$DRY" != 1 ] && [ -n "$(gh pr list -R microsoft/winget-pkgs --head "$BRANCH" --state all \
       --json state -q '.[] | select(.state != "CLOSED") | .state')" ]; then
  echo "winget: an open or merged pull request for $BRANCH already exists"
else
  run gh repo sync Nachox07/winget-pkgs --source microsoft/winget-pkgs --branch master
  if [ "$DRY" = 1 ]; then
    mkdir -p "$WORK/winget/manifests"
  else
    git clone -q --depth 1 --filter=blob:none --sparse \
      "https://x-access-token:${GH_TOKEN}@github.com/Nachox07/winget-pkgs.git" "$WORK/winget"
    git -C "$WORK/winget" sparse-checkout set manifests/n/Nachox07
    git -C "$WORK/winget" checkout -q -b "$BRANCH"
  fi
  "$ROOT/packaging/update.sh" "$VERSION" "$WORK/winget"
  if [ "$DRY" = 1 ]; then
    ls "$WORK/winget/manifests/n/Nachox07/Daylit/$VERSION"
    echo "dry run: open the winget pull request for $BRANCH"
  else
    git -C "$WORK/winget" add manifests
    commit "$WORK/winget" "Update: Nachox07.Daylit to $VERSION"
    git -C "$WORK/winget" push -q -f origin "$BRANCH"   # our fork: a rerun replaces the branch
    gh pr create -R microsoft/winget-pkgs --head "Nachox07:$BRANCH" --base master \
      --title "Update: Nachox07.Daylit to $VERSION" \
      --body "Update: **Nachox07.Daylit** to **$VERSION**, from the GitHub release https://github.com/Nachox07/daylit/releases/tag/v$VERSION. Opened by Daylit's release workflow."
  fi
fi

# Keep packaging/ in this repository in step
if git -C "$ROOT" diff --quiet -- packaging; then
  echo "packaging/ already names $VERSION"
elif [ "$DRY" = 1 ]; then
  git -C "$ROOT" diff --stat -- packaging
  echo "dry run: open a pull request with these files"
else
  PB="packaging/v$VERSION"
  git -C "$ROOT" checkout -q -b "$PB"
  git -C "$ROOT" add packaging
  commit "$ROOT" "Point packaging at $VERSION"
  git -C "$ROOT" push -q -f "https://x-access-token:${GH_TOKEN}@github.com/Nachox07/daylit.git" "$PB"
  [ -n "$(gh pr list -R Nachox07/daylit --head "$PB" --state open --json number -q '.[].number')" ] ||
  gh pr create -R Nachox07/daylit --head "$PB" --base main --title "Point packaging at $VERSION" \
    --body "The release workflow updated the Homebrew cask and winget manifests for v$VERSION and published them. This keeps the copies in packaging/ in step."
fi
