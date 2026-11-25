#!/usr/bin/env python3
"""Check that no tracked file names a real user's home folder.

A path such as /Users/<name>/... or /home/<name>/... carries the local
account name of whoever wrote it, which is personal data: AGENTS.md and
the engineering practices in docs/ARCHITECTURE.md keep it out of code,
tests, fixtures and docs. Tests and docs use made-up names, and this check
allows only those (ALLOWED). It reads every file git tracks, as text;
a file that is not UTF-8 text is skipped. A path inside a web address
(example.com/home/...) is not a home folder and is not reported.

check_reply_fixtures.py and check_evals.py check the reply files and the
eval results for more kinds of account detail; this check covers the
whole tree for this one kind.

Usage: python3 -I scripts/check_home_paths.py [--root DIR]
Standard library and git only; exits 0 when no file names a home folder
outside ALLOWED, 1 otherwise, printing each file and line (not the name).
"""

import argparse
import re
import subprocess
import sys
from pathlib import Path

ALLOWED = {"someone", "someone-made-up", "example", "standin", "made-up", "Shared"}
HOME_PATH = re.compile(r"(?<![\w.-])/(?:Users|home)/([A-Za-z0-9._-]+)")


def tracked(root):
    listing = subprocess.run(["git", "-C", str(root), "ls-files", "-z"],
                             capture_output=True, check=True).stdout
    return [name for name in listing.decode("utf-8").split("\0") if name]


def problems(root):
    found = []
    for name in tracked(root):
        path = root / name
        if not path.is_file() or path.is_symlink():
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        for number, line in enumerate(text.splitlines(), start=1):
            if any(match.group(1) not in ALLOWED for match in HOME_PATH.finditer(line)):
                found.append(f"{name}:{number}: names a path into a user's home folder; use a made-up "
                             f"name ({', '.join(sorted(ALLOWED))})")
    return found


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", default=str(Path(__file__).resolve().parent.parent))
    arguments = parser.parse_args(argv)
    found = problems(Path(arguments.root))
    for problem in found:
        print(problem)
    if found:
        print(f"{len(found)} line(s) name a home folder")
        return 1
    print("No tracked file names a home folder")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
