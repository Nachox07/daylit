# Packaging

Files for installing Daylit with a package manager. Release builds still come from
`.github/workflows/release.yml`; these only point at its zips.

- `homebrew/Casks/daylit.rb`: the cask for the tap repository `Nachox07/homebrew-tap`
  (`brew install --cask nachox07/tap/daylit`). It depends on `m1ddc` on Apple silicon and keeps
  macOS's quarantine, so the first open needs **Open Anyway** like a downloaded zip. Homebrew
  removed `--no-quarantine`, and the official cask repository only takes notarized apps.
- `winget/`: the manifests for `winget install Nachox07.Daylit`. The zip's `Daylit.exe` is
  installed as a portable app with the .NET 10 Desktop Runtime as a dependency. Only x64 for
  now: the release builds an x64 `Daylit.exe`, which on an Arm64 PC needs the x64 runtime, and
  winget may install the Arm64 one there.
- `update.sh <version> [winget-pkgs clone]`: after a release is published, downloads its two zips
  and writes the version, URLs, sha256 and date into all of the above. It pushes and submits nothing.

- `publish.sh <version>`: runs `update.sh`, pushes the cask to the tap, opens the winget pull
  request (only with `WINGET=1`) and a pull request here with the updated files. The release
  workflow runs it from the release tag; the pull request here is built on a fresh clone of `main`.
  git authenticates through `gh auth git-credential` with `GH_TOKEN`: the token is never in a URL.
  `DRY_RUN=1` does it all locally and pushes nothing.

## After tagging a release

The release workflow's `packages` job runs `publish.sh` once the release is up. It needs:

- the secret `PACKAGES_TOKEN`: a classic personal access token with only the `public_repo` scope
  (fine-grained tokens can't open pull requests on `microsoft/winget-pkgs`);
- the repository variable `WINGET_AUTO` set to `true` for the winget step. Leave it unset while a
  winget pull request is still under review.

Without the secret the job only warns. By hand, the same steps are:

1. `packaging/update.sh 1.2.0` (no need to commit the result: the files here are templates, and the
   version they name can be older than the latest release).
2. Homebrew: copy `homebrew/Casks/daylit.rb` to `Casks/daylit.rb` in `Nachox07/homebrew-tap`
   and push. Check with `brew update && brew upgrade --cask nachox07/tap/daylit`.
3. winget: `packaging/update.sh 1.2.0 <your winget-pkgs fork>` copies the manifests to
   `manifests/n/Nachox07/Daylit/1.2.0/`; then open a pull request to `microsoft/winget-pkgs`.
