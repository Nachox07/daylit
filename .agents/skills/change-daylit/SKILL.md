---
name: change-daylit
description: Change Daylit's code (macOS Swift app and Windows C# app) without the two apps drifting apart - find the twin file, write the shared test case first, change both apps, run scripts/check.sh. Use for any bug fix, feature or refactor in the Daylit repository.
license: MIT
---

# Change Daylit

Daylit is two native apps that must behave the same. This is the order to work in. What "done" means and
the pitfalls: [AGENTS.md](../../../AGENTS.md) → *Work on the code*. Commands: CONTRIBUTING.md → *Checks:
local and CI*.

1. **Find the twins.** Look the file up in [`scripts/twins.json`](../../../scripts/twins.json) and read
   the other app's twin first: it may already do it right, or differently. The map is a guide; a file in
   several groups can have more than one twin.
2. **Decide what is right.** README → *How it works* and docs/setup.md decide. When the apps disagree,
   the one that matches the docs is right; when the docs say nothing, ask the user.
3. **Write a failing shared case.** Add it to the matching file in `tests/parity/` (format:
   CONTRIBUTING.md → *Shared test cases*) and watch it fail on the wrong side. No file fits? Create a new
   area file and register it in both runners (`ParityTests.swift`, `ParityTests.cs`); an unregistered
   file fails the tests. Logic stuck in `Model.swift` / `App.cs`: pin today's behaviour with a case on the
   pure side if you can, then extract the decision into the pure files on both sides and make the case
   pass there.
4. **Change both apps** with the same rule and twin names (AGENTS.md → *Code layout and naming*).
5. **Run `scripts/check.sh`** (`--quick` while you iterate). Then push and wait for the pull request's CI.
6. **One side only?** Only when the other app truly has nothing to change (a macOS permission, the
   keychain, iCloud). Put `Parity: <file> — <why>` in the commit message.
7. **New source file?** Add it to `scripts/twins.json`, next to its twin or as `macOnly` / `windowsOnly`
   with the reason.
8. **Update the words:** README → *How it works*, docs/setup.md, AGENTS.md; a UI change needs re-recorded
   snapshots (CONTRIBUTING.md → *UI snapshots*). Check AGENTS.md → *Pitfalls we have hit* before pushing.

Never handle the Home Assistant token, and never put a real address, entity name or location in a
commit: use made-up values in tests.
