#!/usr/bin/env python3
"""Look for secrets in logs and a database dump (milestone 2 plan §5.2, L721).

Step 5 of scripts/e2e_core_loop.sh. Scans every file under the paths given
for:

- each secret listed in a --secrets file (one per line; blank lines and
  lines starting with "#" are skipped) and each --literal value: the
  owner's password, the session and helper tokens a test used, the
  stand-ins' made-up email and organisation. Each is looked for as written
  and in the forms a log or a dump may hold it in: JSON-escaped,
  URL-encoded (a path or a query, and a form body), and base64 at any of
  its three alignments inside a longer encoded text; and also with the
  file's line breaks removed, so a copy wrapped across lines is found
  where it starts;
- anything shaped like a leverage token: lvs_, lvh_ or lvo_ followed by 16
  or more URL-safe base64 characters (IN-18). What the redaction leaves,
  `lvs_[removed]`, is not one;
- a bearer header's value of 16 characters or more, whatever the case of
  "Bearer";
- with --replies FOLDER, a provider tool's reply (milestone 3 plan HD-8,
  §5.2): every reply file's marker (meta.marker), and every line of its
  outputs (stdout, stderr) that is at least 40 characters long. A line
  that holds a reset placeholder (@RESET_AT_ISO@, "@RESET_AT_EPOCH@") is
  looked for in its pieces around the placeholders that are that long,
  because the stand-ins replace the placeholder when they play the reply.
  A shorter line, such as "{" or "ready", is in every log and is not
  looked for. A reply must appear nowhere but in the stand-ins' own folder,
  so that folder is never one of the paths scanned.

A hit is printed as "<file>:<line>: <what>", where <what> says which listed
secret it was (by its number in its file) or which shape matched. The secret
itself is never printed. Exit 0 when nothing is found, 1 on any hit, 2 when
the scan could not be made: no path, a missing path, no file to scan, no
secret to look for, a secret shorter than 8 characters (a shorter one
leaves a base64 piece too short to look for at one of the offsets), or a
replies folder with no reply file or a reply file with no marker.

Usage:
  python3 -I scripts/secret_scan.py [--secrets FILE]... [--literal VALUE]...
      [--replies FOLDER]... PATH...

Standard library only.
"""

import argparse
import base64
import json
import os
import re
import sys
import urllib.parse

SHAPES = [
    ("token shape", re.compile(rb"lv[sho]_[A-Za-z0-9_-]{16,}")),
    ("bearer value", re.compile(rb"Bearer\s+[A-Za-z0-9._~+/-]{16,}=*", re.IGNORECASE)),
]
# A base64 piece shorter than SHORTEST_BASE64 could turn up by chance in
# a dump. A secret of SHORTEST characters gives a piece of at least that
# length at each of the three offsets (8, 10 and 9 characters), so every
# secret the scan takes is looked for in base64 at all three.
SHORTEST = 8
SHORTEST_BASE64 = 8
# The shortest line of a reply file's outputs that is looked for (§5.2).
LONGEST_COMMON_LINE = 39
# What the stand-ins replace when they play a reply (provider_tool.py).
PLACEHOLDERS = re.compile(r'"@RESET_AT_EPOCH@"|@RESET_AT_ISO@')


class Refused(Exception):
    """The scan could not be made."""


def read_replies(folders):
    """[(label, value)] for every reply file under the folders: its marker,
    and each piece of 40 characters or more of each line of its outputs."""
    found = []
    for folder in folders:
        if not os.path.isdir(folder):
            raise Refused(f"no such replies folder: {folder}")
        files = []
        for place, folders_below, names in os.walk(folder):
            folders_below.sort()
            files.extend(os.path.join(place, name) for name in sorted(names) if name.endswith(".json"))
        if not files:
            raise Refused(f"no reply file in {folder}")
        for path in files:
            name = os.path.relpath(path, folder)
            try:
                with open(path, encoding="utf-8") as handle:
                    reply = json.load(handle)
                marker = reply["meta"]["marker"]
            except (OSError, ValueError, KeyError, TypeError) as error:
                raise Refused(f"cannot read the reply file {name}: {error}") from error
            if not isinstance(marker, str) or not marker:
                raise Refused(f"the reply file {name} has no marker")
            found.append((f"marker of {name}", marker))
            for stream in ("stdout", "stderr"):
                for number, line in enumerate((reply.get(stream) or "").splitlines(), start=1):
                    for piece in PLACEHOLDERS.split(line):
                        if len(piece.strip()) > LONGEST_COMMON_LINE:
                            found.append((f"{stream} line {number} of {name}", piece))
    return found


def read_secrets(files, literals, replies=()):
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
    secrets.extend(replies)
    if not secrets:
        raise Refused("no secret to look for")
    for label, value in secrets:
        if len(value) < SHORTEST:
            raise Refused(f"{label} is too short to look for (under {SHORTEST} characters)")
    return [form for label, value in secrets for form in forms(label, value)]


def base64_pieces(raw):
    """The base64 text a secret's bytes always encode to, at each of the
    three offsets it can start at inside a longer encoded text: only the
    characters that depend on the secret's bytes alone."""
    pieces = []
    for offset in range(3):
        encoded = base64.b64encode(b"\0" * offset + raw)
        start = (offset * 4 + 2) // 3
        end = (offset + len(raw)) // 3 * 4
        piece = encoded[start:end]
        if len(piece) >= SHORTEST_BASE64:
            pieces.append(piece)
    return pieces


def forms(label, value):
    """[(label, bytes)]: the secret as written, then every other form of it
    that differs from that, each labelled with how it is written."""
    raw = value.encode("utf-8")
    found = [(label, raw)]
    others = [
        ("JSON-escaped", json.dumps(value)[1:-1].encode("utf-8")),
        ("URL-encoded", urllib.parse.quote(value, safe="").encode("ascii")),
        ("form-encoded", urllib.parse.quote_plus(value).encode("ascii")),
    ] + [("base64", piece) for piece in base64_pieces(raw)]
    seen = {raw}
    for how, encoded in others:
        if encoded not in seen:
            seen.add(encoded)
            found.append((f"{label} ({how})", encoded))
    return found


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
    """[(line number, what)] for every hit, one per secret or shape a line
    holds; then each secret found only once the line breaks are removed, at
    the line where it starts."""
    hits = []
    with open(path, "rb") as handle:
        lines = handle.read().splitlines()
    for number, line in enumerate(lines, start=1):
        for label, value in secrets:
            if value in line:
                hits.append((number, label))
        for label, shape in SHAPES:
            if shape.search(line):
                hits.append((number, label))
    found = {label for _number, label in hits}
    joined = b"".join(lines)
    starts = []
    position = 0
    for line in lines:
        starts.append(position)
        position += len(line)
    for label, value in secrets:
        if label in found:
            continue
        at = joined.find(value)
        if at >= 0:
            number = max(index for index, start in enumerate(starts) if start <= at) + 1
            hits.append((number, label))
    return hits


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--secrets", action="append", default=[], metavar="FILE")
    parser.add_argument("--literal", action="append", default=[], metavar="VALUE")
    parser.add_argument("--replies", action="append", default=[], metavar="FOLDER")
    parser.add_argument("paths", nargs="*", metavar="PATH")
    arguments = parser.parse_args(argv)
    try:
        if not arguments.paths:
            raise Refused("no path to scan")
        replies = read_replies(arguments.replies)
        secrets = read_secrets(arguments.secrets, arguments.literal, replies)
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
    listed = len({label.split(" (")[0] for label, _value in secrets})
    reply_files = len({label for label, _value in replies if label.startswith("marker of ")})
    also = f", {reply_files} reply files" if reply_files else ""
    print(f"secret_scan: {len(files)} files, {listed} secrets and {len(SHAPES)} shapes{also}, no secret found")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
