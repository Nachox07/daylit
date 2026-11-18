---
name: change-daylit
description: Change Daylit's code (macOS Swift app and Windows C# app) without the two apps drifting apart - find the twin file, write the shared test case first, change both apps, run scripts/check.sh. Use for any bug fix, feature or refactor in the Daylit repository.
---

This skill lives in [`.agents/skills/change-daylit/SKILL.md`](../../../.agents/skills/change-daylit/SKILL.md),
the shared location other agents read. Read that file and follow it.

(Kept as a short pointer rather than a symlink so it also works on Windows checkouts, where git
writes symlinks as plain files unless symlink support is turned on.)
