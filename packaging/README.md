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

## After tagging a release

1. Wait for the release workflow to publish the release, then run `packaging/update.sh 1.2.0`
   and commit the changed files here.
2. Homebrew (the first time, create the public repository `Nachox07/homebrew-tap`): copy `homebrew/Casks/daylit.rb` to `Casks/daylit.rb` in `Nachox07/homebrew-tap`
   and push. Check with `brew update && brew upgrade --cask nachox07/tap/daylit`.
3. winget: run `packaging/update.sh 1.2.0 <your winget-pkgs fork>` to copy the manifests to
   `manifests/n/Nachox07/Daylit/1.2.0/`, then open a pull request to `microsoft/winget-pkgs`.
   Alternatively, on Windows: `wingetcreate submit packaging/winget`. After the first version is
   accepted, `wingetcreate update Nachox07.Daylit --version <v> --urls <zip url> --submit` works too.
