---
name: change-daylit
description: Change Daylit's code (macOS Swift app and Windows C# app) without the two apps drifting apart - find the twin file, write the shared test case first, change both apps, run scripts/check.sh. Use for any bug fix, feature or refactor in the Daylit repository.
license: MIT
---

# Change Daylit

Daylit is two native apps that must behave the same. The full rules are in [AGENTS.md](../../../AGENTS.md)
→ *Work on the code*, *Done means* and *Pitfalls we have hit*. Read the pitfalls before you start.

1. **Find the twins.** Look the file up in [`scripts/twins.json`](../../../scripts/twins.json). Read the
   other app's twin before changing anything: it may already do it right, or differently.
2. **Decide what the right behaviour is.** README → *How it works* and docs/setup.md decide. When the
   two apps disagree, the one that matches the docs is right; when the docs say nothing, ask the user.
3. **Write the shared case first.** When the logic is pure (`mac/Sources/DaylitCore`, `windows/Rules.cs`,
   `Config.cs`, `Suggest.cs`, `Update.cs`, `Push.cs`, `Light.cs`, `Chart.cs`), add a case to the matching
   file in `tests/parity/` (format: CONTRIBUTING.md → *Shared test cases*) and see it fail on the side
   that is wrong. Logic stuck in `Model.swift` / `App.cs`: move the decision into the pure files on both
   sides first, then test it.
4. **Change both apps.** Same names where the languages allow (`Suggest.applyClearsOffset` /
   `Suggest.ApplyClearsOffset`), same rule, same edge cases.
5. **Run `scripts/check.sh`.** It runs the parity guard, `swift test`, `dotnet test` and both builds with 0
   warnings. `--quick` skips the builds while you iterate. All green before you push.
6. **One side only?** Only when the other app truly has nothing to change (a macOS permission, the
   keychain, iCloud). Say why in the pull request or a commit message: `Parity: <why>`.
7. **New file?** Add it to `scripts/twins.json`, next to its twin or as `macOnly` / `windowsOnly`
   with the reason.
8. **Update the words.** README → *How it works* for behaviour, docs/setup.md for settings, AGENTS.md
   when an agent needs to know, and a UI change needs re-recorded snapshots (CONTRIBUTING.md → *UI
   snapshots*).

Never handle the Home Assistant token, and never put a real address, entity name or location in a
commit: use made-up values in tests.
