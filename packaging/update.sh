#!/bin/sh
# Points the Homebrew cask and the winget manifests at a published release.
#   packaging/update.sh 1.2.0                 # update the files in packaging/ in place
#   packaging/update.sh 1.2.0 ~/winget-pkgs   # also copy the manifests into a winget-pkgs clone
# Downloads both release zips, hashes them and rewrites version, URLs, sha256 and release date.
# It never pushes or submits anything: see packaging/README.md for the next steps.
set -eu

VERSION="${1:-}"
WINGET_PKGS="${2:-}"
case "$VERSION" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) echo "usage: $0 <version, e.g. 1.2.0> [winget-pkgs clone]" >&2; exit 2 ;;
esac
case "$VERSION" in *[!0-9.]*) echo "version must be digits and dots: $VERSION" >&2; exit 2 ;; esac

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="Nachox07/daylit"
BASE="https://github.com/$REPO/releases/download/v$VERSION"
MAC_ZIP="Daylit-mac-$VERSION.zip"
WIN_ZIP="Daylit-windows-$VERSION.zip"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
for f in "$MAC_ZIP" "$WIN_ZIP"; do
  curl -fsSL -o "$TMP/$f" "$BASE/$f" || { echo "could not download $BASE/$f (is v$VERSION published?)" >&2; exit 1; }
done
# Releases after v1.8.0 carry SHA256SUMS, written by the release workflow from the zips it built.
# The downloads must match it, so a zip replaced on the release page afterwards is caught here.
if curl -fsSL -o "$TMP/SHA256SUMS" "$BASE/SHA256SUMS" 2>/dev/null; then
  [ "$(grep -cE "  ($MAC_ZIP|$WIN_ZIP)\$" "$TMP/SHA256SUMS")" = 2 ] \
    || { echo "SHA256SUMS of v$VERSION does not list both zips" >&2; exit 1; }
  (cd "$TMP" && shasum -a 256 -c SHA256SUMS --ignore-missing >/dev/null) \
    || { echo "the downloaded zips do not match SHA256SUMS of v$VERSION: do not publish" >&2; exit 1; }
  echo "checked both zips against SHA256SUMS"
else
  echo "v$VERSION has no SHA256SUMS (a release before it existed): zips not cross-checked" >&2
fi
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
MAC_SHA="$(sha "$TMP/$MAC_ZIP")"
WIN_SHA="$(sha "$TMP/$WIN_ZIP" | tr '[:lower:]' '[:upper:]')"
# The release's publish date (UTC), from the GitHub API.
DATE="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/tags/v$VERSION" \
  | sed -n 's/.*"published_at": *"\([0-9-]*\)T.*/\1/p' | head -n 1)"
[ -n "$DATE" ] || { echo "could not read the release date of v$VERSION" >&2; exit 1; }

export VERSION MAC_SHA WIN_SHA DATE BASE WIN_ZIP
CASK="$HERE/homebrew/Casks/daylit.rb"
perl -pi -e 's/^  version ".*"/  version "$ENV{VERSION}"/; s/^  sha256 ".*"/  sha256 "$ENV{MAC_SHA}"/' "$CASK"

W="$HERE/winget"
perl -pi -e 's/^PackageVersion: .*/PackageVersion: $ENV{VERSION}/' \
  "$W/Nachox07.Daylit.yaml" "$W/Nachox07.Daylit.installer.yaml" "$W/Nachox07.Daylit.locale.en-US.yaml"
perl -pi -e 's/^ReleaseDate: .*/ReleaseDate: $ENV{DATE}/;
             s/^(\s*InstallerUrl:) .*/$1 $ENV{BASE}\/$ENV{WIN_ZIP}/;
             s/^(\s*InstallerSha256:) .*/$1 $ENV{WIN_SHA}/' "$W/Nachox07.Daylit.installer.yaml"
perl -pi -e 's/^ReleaseNotesUrl: .*/ReleaseNotesUrl: https:\/\/github.com\/Nachox07\/daylit\/releases\/tag\/v$ENV{VERSION}/' \
  "$W/Nachox07.Daylit.locale.en-US.yaml"

# Every file must now name the new version and hashes; fail loudly if a pattern missed.
grep -q "version \"$VERSION\"" "$CASK" && grep -q "sha256 \"$MAC_SHA\"" "$CASK" \
  && grep -q "InstallerSha256: $WIN_SHA" "$W/Nachox07.Daylit.installer.yaml" \
  && grep -q "/v$VERSION/$WIN_ZIP" "$W/Nachox07.Daylit.installer.yaml" \
  && grep -q "^ReleaseDate: $DATE\$" "$W/Nachox07.Daylit.installer.yaml" \
  && grep -q "/releases/tag/v$VERSION\$" "$W/Nachox07.Daylit.locale.en-US.yaml" \
  && [ "$(grep -l "^PackageVersion: $VERSION\$" "$W"/*.yaml | wc -l | tr -d ' ')" = 3 ] \
  || { echo "an update did not apply; check the files in $HERE" >&2; exit 1; }

echo "Daylit $VERSION (released $DATE)"
echo "  mac zip     sha256 $MAC_SHA"
echo "  windows zip sha256 $WIN_SHA"
echo "updated $CASK and $W/*.yaml"

if [ -n "$WINGET_PKGS" ]; then
  DEST="$WINGET_PKGS/manifests/n/Nachox07/Daylit/$VERSION"
  mkdir -p "$DEST"
  # Don't clobber manifests already edited there (e.g. after a review comment on winget-pkgs).
  for f in "$W"/Nachox07.Daylit*.yaml; do
    t="$DEST/$(basename "$f")"
    if [ -e "$t" ] && ! cmp -s "$f" "$t"; then
      echo "$t exists and differs; move it away first" >&2; exit 1
    fi
  done
  cp "$W"/Nachox07.Daylit*.yaml "$DEST/"
  echo "copied the manifests to $DEST"
fi
