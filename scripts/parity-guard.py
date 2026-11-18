#!/usr/bin/env python3
"""Mac/Windows parity guard. Runs in CI on every pull request and in scripts/check.sh.

1. Every .swift file under mac/Sources and every .cs file directly in windows/ is listed in
   scripts/twins.json (in a group, or as Mac-only / Windows-only with a reason), and every listed file exists.
2. A change to one side of a group comes with a change to the other side, unless the pull request body
   (env PARITY_PR_BODY) or a commit message in the range has a line "Parity: <reason>".

  scripts/parity-guard.py --base <ref> [--head <ref>]   # files changed in base...head
  scripts/parity-guard.py --base <ref> --worktree       # ...plus uncommitted and untracked files
Standard library only.
"""
import argparse, json, os, re, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TWINS = ROOT / "scripts" / "twins.json"
PARITY_LINE = re.compile(r"^[ \t]*Parity:[ \t]*\S[^\n]{2,}$", re.MULTILINE)


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


def parity_reason(base, head):
    body = os.environ.get("PARITY_PR_BODY", "")
    m = PARITY_LINE.search(body)
    if m:
        return m.group(0).strip()
    m = PARITY_LINE.search(git("log", "--format=%B", f"{base}..{head}"))
    return m.group(0).strip() if m else None


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
            one_sided.append(f"{f} changed, but none of its twins did: {', '.join(sorted(others))}")
    if one_sided:
        reason = parity_reason(a.base, a.head)
        if reason:
            print(f"parity: one-sided change accepted ({reason})")
            for line in one_sided:
                print(f"  {line}")
        else:
            problems += one_sided
            problems.append("If the other app really needs no change, say why in the pull request or a commit "
                            "message with a line like 'Parity: Mac-only, Windows has no keychain'.")

    if problems:
        print("parity guard: FAILED")
        for p in problems:
            print(f"  - {p}")
        return 1
    print(f"parity guard: ok ({len(changed)} changed files checked)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
