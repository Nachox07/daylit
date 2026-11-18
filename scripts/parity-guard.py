#!/usr/bin/env python3
"""Mac/Windows parity guard. Runs in CI on every pull request and in scripts/check.sh.

1. Every .swift file under mac/Sources and every .cs file directly in windows/ is listed in
   scripts/twins.json (in a group, or as Mac-only / Windows-only with a reason), and every listed file exists.
2. A change to one side of a group comes with a change to the other side, unless a waiver names that file:
   a line in a commit message of the range (the usual place) or the pull request body (env PARITY_PR_BODY)
       Parity: mac/Sources/Daylit/Token.swift — Mac-only, Windows has no keychain
   Targets are paths, directories ending in "/", or globs, separated by commas or spaces; then " — " (or
   " - ", " -- ") and the reason. HTML comments are ignored, so a template's example never counts.

The twin map is a navigation aid, not proof of parity: a file in several groups is matched by a change to
any of its twins (windows/App.cs with mac/Sources/Daylit/Keys.swift passes). The shared cases in
tests/parity/ are what show that the apps behave the same.

  scripts/parity-guard.py --base <ref> [--head <ref>]   # files changed in base...head
  scripts/parity-guard.py --base <ref> --worktree       # ...plus uncommitted and untracked files
Standard library only.
"""
import argparse, fnmatch, json, os, re, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TWINS = ROOT / "scripts" / "twins.json"
PARITY_LINE = re.compile(r"^[ \t]*Parity:[ \t]*(.*)$", re.MULTILINE)
SEPARATOR = re.compile(r"\s+(?:—|–|--|-)\s+")
PLACEHOLDERS = {"why", "reason", "todo", "tbd", "n/a", "na", "none", "-"}


def git(*args):
    return subprocess.run(["git", "-C", str(ROOT), *args], check=True, capture_output=True, text=True).stdout


def in_scope(path):
    p = Path(path)
    return (path.startswith("mac/Sources/") and p.suffix == ".swift") or (
        p.parent.as_posix() == "windows" and p.suffix == ".cs")


def counterparts_of(groups):
    counterparts = {}
    for g in groups:
        for side, other in (("mac", "windows"), ("windows", "mac")):
            for f in g.get(side, []):
                counterparts.setdefault(f, set()).update(g.get(other, []))
    return counterparts


def load_map():
    data = json.loads(TWINS.read_text(encoding="utf-8"))
    groups = data.get("groups", [])
    return groups, data.get("macOnly", {}), data.get("windowsOnly", {}), counterparts_of(groups)


def base_counterparts(base):
    """The map as it was at the base: a file deleted (and dropped from the map) still needs its twins."""
    try:
        data = json.loads(git("show", f"{base}:scripts/twins.json"))
    except (subprocess.CalledProcessError, json.JSONDecodeError):
        return {}
    return counterparts_of(data.get("groups", []))


def map_problems(groups, mac_only, win_only, counterparts):
    problems = []
    listed = set(counterparts) | set(mac_only) | set(win_only)
    for g in groups:
        if not g.get("mac") or not g.get("windows"):
            problems.append(f"twins.json: group '{g.get('name')}' needs files on both sides")
    for f, why in {**mac_only, **win_only}.items():
        if not str(why).strip():
            problems.append(f"twins.json: {f} is one-sided with no reason")
    for f in sorted(listed):
        if not in_scope(f):
            problems.append(f"twins.json: {f} is not a mac/Sources .swift or windows/*.cs file")
        elif not (ROOT / f).is_file():
            problems.append(f"twins.json: {f} does not exist (renamed or removed? update the map)")
    tracked = git("ls-files", "mac/Sources", "windows").splitlines()
    untracked = git("ls-files", "--others", "--exclude-standard", "mac/Sources", "windows").splitlines()
    for f in sorted(set(tracked) | set(untracked)):
        if in_scope(f) and f not in listed and (ROOT / f).is_file():
            problems.append(f"{f} is not in scripts/twins.json: add it to the group of its twin, "
                            "or to macOnly / windowsOnly with the reason")
    return problems


def changed_files(base, head, worktree):
    files = set(git("diff", "--name-only", "--no-renames", f"{base}...{head}").splitlines())
    if worktree:
        files |= set(git("diff", "--name-only", "--no-renames", "HEAD").splitlines())
        files |= set(git("ls-files", "--others", "--exclude-standard").splitlines())
    return {f for f in files if f}


def strip_comments(text):
    return re.sub(r"<!--.*?-->", "", text, flags=re.DOTALL)


def parse_waivers(text):
    """(waivers, problems): each waiver is (targets, reason, line); a malformed Parity line is a problem."""
    waivers, problems = [], []
    for m in PARITY_LINE.finditer(strip_comments(text)):
        line = m.group(0).strip()
        parts = SEPARATOR.split(m.group(1).strip(), maxsplit=1)
        if len(parts) != 2:
            problems.append(f"'{line}': write 'Parity: <files> — <why>' (the files it excuses, then the reason)")
            continue
        targets = [t for t in re.split(r"[,\s]+", parts[0]) if t]
        reason = parts[1].strip()
        bad_targets = [t for t in targets if "/" not in t and "*" not in t or "<" in t or ">" in t]
        letters = re.sub(r"[^A-Za-z]", "", reason)
        if not targets or bad_targets:
            problems.append(f"'{line}': name the files it excuses as paths, directories ('mac/Sources/Daylit/') or globs")
        elif "<" in reason or ">" in reason or reason.lower().strip(" .") in PLACEHOLDERS or len(letters) < 6:
            problems.append(f"'{line}': give the real reason the other app needs no change")
        else:
            waivers.append((targets, reason, line))
    return waivers, problems


def excused_by(path, waivers):
    for targets, reason, line in waivers:
        for t in targets:
            if path == t or (t.endswith("/") and path.startswith(t)) or fnmatch.fnmatchcase(path, t):
                return line
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--base", required=True)
    ap.add_argument("--head", default="HEAD")
    ap.add_argument("--worktree", action="store_true", help="also count uncommitted and untracked files")
    a = ap.parse_args()

    groups, mac_only, win_only, counterparts = load_map()
    problems = map_problems(groups, mac_only, win_only, counterparts)

    changed = changed_files(a.base, a.head, a.worktree)
    before = base_counterparts(a.base)
    one_sided = []
    for f in sorted(changed):
        others = counterparts.get(f, set()) | before.get(f, set())
        if others and not (others & changed):
            one_sided.append((f, f"{f} changed, but none of its twins did: {', '.join(sorted(others))}"))
    if one_sided:
        text = os.environ.get("PARITY_PR_BODY", "") + "\n" + git("log", "--format=%B", f"{a.base}..{a.head}")
        waivers, waiver_problems = parse_waivers(text)
        unexcused = []
        for f, line in one_sided:
            by = excused_by(f, waivers)
            if by:
                print(f"parity: one-sided change accepted: {f} ({by})")
            else:
                unexcused.append(line)
        if unexcused:
            problems += waiver_problems + unexcused
            problems.append("If the other app really needs no change, add a line to a commit message (or the pull "
                            "request) naming the file and why: 'Parity: mac/Sources/Daylit/Token.swift — Mac-only, "
                            "Windows has no keychain'.")

    if problems:
        print("parity guard: FAILED")
        for p in problems:
            print(f"  - {p}")
        return 1
    print(f"parity guard: ok ({len(changed)} changed files checked)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
