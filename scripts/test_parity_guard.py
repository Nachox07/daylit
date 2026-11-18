#!/usr/bin/env python3
"""Tests for scripts/parity-guard.py: python3 -I scripts/test_parity_guard.py (scripts/check.sh and CI run it).

Each scenario builds a tiny git repository in a temporary folder with a copy of the guard and its own
twins.json, so the tests do not depend on this repository's files. Standard library only.
"""
import importlib.util, json, os, shutil, subprocess, sys, tempfile, unittest
from pathlib import Path

GUARD = Path(__file__).resolve().parent / "parity-guard.py"
spec = importlib.util.spec_from_file_location("parity_guard", GUARD)
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)

TWINS = {
    "groups": [
        {"name": "rules", "mac": ["mac/Sources/Core/Rules.swift", "mac/Sources/Core/Sun.swift"], "windows": ["windows/Rules.cs"]},
        {"name": "log", "mac": ["mac/Sources/App/Log.swift"], "windows": ["windows/Win.cs"]},
        {"name": "displays", "mac": ["mac/Sources/App/Displays.swift"], "windows": ["windows/Win.cs", "windows/Displays.cs"]},
    ],
    "macOnly": {"mac/Sources/App/Keychain.swift": "Mac keychain only"},
    "windowsOnly": {},
}
FILES = [f for g in TWINS["groups"] for side in ("mac", "windows") for f in g[side]] + list(TWINS["macOnly"])


class Repo:
    def __init__(self):
        self.dir = Path(tempfile.mkdtemp(prefix="parity-guard-test."))
        (self.dir / "scripts").mkdir()
        shutil.copy(GUARD, self.dir / "scripts" / "parity-guard.py")
        (self.dir / "scripts" / "twins.json").write_text(json.dumps(TWINS))
        for f in set(FILES):
            self.write(f)
        self.git("init", "-q", "-b", "main")
        self.commit("base")
        self.base = self.git("rev-parse", "HEAD").strip()

    def git(self, *args):
        env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
               "GIT_COMMITTER_EMAIL": "t@t"}
        return subprocess.run(["git", "-C", str(self.dir), *args], check=True, capture_output=True, text=True, env=env).stdout

    def write(self, f, text="// x\n"):
        p = self.dir / f
        p.parent.mkdir(parents=True, exist_ok=True)
        with open(p, "a") as h:
            h.write(text)

    def commit(self, message="change", *files):
        for f in files:
            self.write(f)
        self.git("add", "-A")
        self.git("commit", "-q", "--allow-empty", "-m", message)

    def run(self, body="", worktree=False):
        args = [sys.executable, "-I", str(self.dir / "scripts" / "parity-guard.py"), "--base", self.base]
        if worktree:
            args.append("--worktree")
        r = subprocess.run(args, capture_output=True, text=True, env={**os.environ, "PARITY_PR_BODY": body})
        return r.returncode, r.stdout

    def close(self):
        shutil.rmtree(self.dir, ignore_errors=True)


class GuardScenarios(unittest.TestCase):
    def setUp(self):
        self.repo = Repo()

    def tearDown(self):
        self.repo.close()

    def assertFails(self, body="", worktree=False):
        code, out = self.repo.run(body, worktree)
        self.assertEqual(code, 1, out)
        return out

    def assertPasses(self, body="", worktree=False):
        code, out = self.repo.run(body, worktree)
        self.assertEqual(code, 0, out)
        return out

    def test_both_sides_changed_passes(self):
        self.repo.commit("both", "mac/Sources/Core/Rules.swift", "windows/Rules.cs")
        self.assertPasses()

    def test_one_side_changed_fails(self):
        self.repo.commit("one", "mac/Sources/Core/Rules.swift")
        self.assertIn("none of its twins did: windows/Rules.cs", self.assertFails())

    def test_waiver_in_a_commit_message_naming_the_file_passes(self):
        self.repo.commit("one\n\nParity: mac/Sources/Core/Rules.swift — comment wording only", "mac/Sources/Core/Rules.swift")
        self.assertPasses()

    def test_waiver_in_the_pull_request_body_passes(self):
        self.repo.commit("one", "mac/Sources/Core/Rules.swift")
        self.assertPasses("Intro\n\nParity: mac/Sources/Core/Rules.swift - comment wording only\n")

    def test_waiver_by_directory_and_by_glob_passes(self):
        self.repo.commit("one", "mac/Sources/Core/Rules.swift", "mac/Sources/App/Log.swift")
        self.assertPasses("Parity: mac/Sources/Core/ mac/Sources/App/*.swift — Mac comments only")

    def test_waiver_for_another_file_does_not_excuse_this_one(self):
        self.repo.commit("one", "mac/Sources/Core/Rules.swift", "windows/Displays.cs")
        out = self.assertFails("Parity: mac/Sources/Core/Rules.swift — comment wording only")
        self.assertIn("windows/Displays.cs changed", out)
        self.assertNotIn("mac/Sources/Core/Rules.swift changed", out)

    def test_waiver_without_files_fails(self):
        self.repo.commit("one\n\nParity: Mac-only, Windows has no keychain", "mac/Sources/Core/Rules.swift")
        self.assertIn("Parity: <files> — <why>", self.assertFails())

    def test_placeholder_reason_fails(self):
        self.repo.commit("one", "mac/Sources/Core/Rules.swift")
        self.assertIn("real reason", self.assertFails("Parity: mac/Sources/Core/Rules.swift — <why>"))

    def test_reason_on_the_next_line_fails(self):
        self.repo.commit("one", "mac/Sources/Core/Rules.swift")
        self.assertFails("Parity: mac/Sources/Core/Rules.swift\ncomment wording only")

    def test_waiver_inside_an_html_comment_is_ignored(self):
        self.repo.commit("one", "mac/Sources/Core/Rules.swift")
        self.assertFails("<!--\nParity: mac/Sources/Core/Rules.swift — comment wording only\n-->")

    def test_file_in_several_groups_passes_with_any_twin(self):
        self.repo.commit("w", "windows/Win.cs", "mac/Sources/App/Log.swift")
        self.assertPasses()

    def test_file_in_several_groups_fails_alone(self):
        self.repo.commit("w", "windows/Win.cs")
        self.assertFails()

    def test_one_sided_file_listed_as_mac_only_passes(self):
        self.repo.commit("k", "mac/Sources/App/Keychain.swift")
        self.assertPasses()

    def test_unmapped_new_file_fails(self):
        self.repo.commit("new", "windows/NewThing.cs")
        self.assertIn("windows/NewThing.cs is not in scripts/twins.json", self.assertFails())

    def test_mapped_file_that_is_gone_fails(self):
        (self.repo.dir / "mac/Sources/App/Keychain.swift").unlink()
        self.repo.commit("rm")
        self.assertIn("does not exist", self.assertFails())

    def test_deleted_file_dropped_from_the_map_still_needs_its_twin(self):
        (self.repo.dir / "mac/Sources/Core/Rules.swift").unlink()
        twins = json.loads(json.dumps(TWINS))
        twins["groups"][0]["mac"].remove("mac/Sources/Core/Rules.swift")
        (self.repo.dir / "scripts/twins.json").write_text(json.dumps(twins))
        self.repo.commit("rm")
        self.assertIn("mac/Sources/Core/Rules.swift changed", self.assertFails())

    def test_uncommitted_change_counts_with_worktree(self):
        self.repo.write("windows/Rules.cs")
        self.assertFails(worktree=True)


class WaiverParsing(unittest.TestCase):
    def test_separators_and_targets(self):
        for line in ("Parity: a/b.swift — reason here", "Parity: a/b.swift – reason here",
                     "Parity: a/b.swift -- reason here", "Parity: a/b.swift, c/d.cs - reason here"):
            waivers, problems = guard.parse_waivers(line)
            self.assertEqual(problems, [], line)
            self.assertEqual(len(waivers), 1, line)

    def test_a_dash_inside_a_path_is_not_a_separator(self):
        waivers, _ = guard.parse_waivers("Parity: mac/Sources/x-y.swift — reason here")
        self.assertEqual(waivers[0][0], ["mac/Sources/x-y.swift"])


if __name__ == "__main__":
    unittest.main(verbosity=1)
