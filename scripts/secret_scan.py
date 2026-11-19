#!/usr/bin/env python3
"""Look for secrets in logs and a database dump (milestone 2 plan §5.2, L721).

Step 5 of scripts/e2e_core_loop.sh. Scans every file under the paths given
for:

- each secret listed in a --secrets file (one per line; blank lines and
  lines starting with "#" are skipped) and each --literal value: the
  owner's password, the session and helper tokens a test used, the
  stand-ins' made-up email and organisation;
- anything shaped like a leverage token: lvs_, lvh_ or lvo_ followed by 16
  or more URL-safe base64 characters (IN-18). What the redaction leaves,
  `lvs_[removed]`, is not one;
- a bearer header's value of 16 characters or more.

A hit is printed as "<file>:<line>: <what>", where <what> says which listed
secret it was (by its number in its file) or which shape matched. The secret
itself is never printed. Exit 0 when nothing is found, 1 on any hit, 2 when
the scan could not be made: no path, a missing path, no file to scan, no
secret to look for, or a secret shorter than 6 characters.

Usage:
  python3 -I scripts/secret_scan.py [--secrets FILE]... [--literal VALUE]... PATH...

Standard library only.
"""

import argparse
import os
import re
import sys

SHAPES = [
    ("token shape", re.compile(rb"lv[sho]_[A-Za-z0-9_-]{16,}")),
    ("bearer value", re.compile(rb"Bearer\s+[A-Za-z0-9._~+/-]{16,}=*")),
]
SHORTEST = 6


class Refused(Exception):
    """The scan could not be made."""


def read_secrets(files, literals):
    """[(label, bytes)] for every secret to look for."""
    secrets = []
    for path in files:
        try:
            with open(path, encoding="utf-8") as handle:
                lines = handle.read().splitlines()
        except OSError as error:
            raise Refused(f"cannot read the secrets file {path}: {error.strerror}") from error
        number = 0
        for line in lines:
            value = line.strip()
            if not value or value.startswith("#"):
                continue
            number += 1
            secrets.append((f"secret {number} of {path}", value))
    for number, value in enumerate(literals, start=1):
        secrets.append((f"literal {number}", value))
    if not secrets:
        raise Refused("no secret to look for")
    for label, value in secrets:
        if len(value) < SHORTEST:
            raise Refused(f"{label} is too short to look for (under {SHORTEST} characters)")
    return [(label, value.encode("utf-8")) for label, value in secrets]


def files_under(paths):
    """Every regular file under the paths, in a stable order."""
    found = []
    for path in paths:
        if os.path.isfile(path):
            found.append(path)
        elif os.path.isdir(path):
            for folder, folders, names in os.walk(path):
                folders.sort()
                found.extend(os.path.join(folder, name) for name in sorted(names)
                             if os.path.isfile(os.path.join(folder, name)))
        else:
            raise Refused(f"no such file or folder: {path}")
    if not found:
        raise Refused("no file to scan")
    return found


def scan_file(path, secrets):
    """[(line number, what)] for every hit, one per secret or shape a line holds."""
    hits = []
    with open(path, "rb") as handle:
        for number, line in enumerate(handle, start=1):
            for label, value in secrets:
                if value in line:
                    hits.append((number, label))
            for label, shape in SHAPES:
                if shape.search(line):
                    hits.append((number, label))
    return hits


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--secrets", action="append", default=[], metavar="FILE")
    parser.add_argument("--literal", action="append", default=[], metavar="VALUE")
    parser.add_argument("paths", nargs="*", metavar="PATH")
    arguments = parser.parse_args(argv)
    try:
        if not arguments.paths:
            raise Refused("no path to scan")
        secrets = read_secrets(arguments.secrets, arguments.literal)
        files = files_under(arguments.paths)
    except Refused as refusal:
        print(f"secret_scan: {refusal}", file=sys.stderr)
        return 2

    total = 0
    for path in files:
        for number, label in scan_file(path, secrets):
            print(f"{path}:{number}: {label}")
            total += 1
    if total:
        print(f"secret_scan: {len(files)} files, {total} hits")
        return 1
    print(f"secret_scan: {len(files)} files, {len(secrets)} secrets and {len(SHAPES)} shapes, no secret found")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
