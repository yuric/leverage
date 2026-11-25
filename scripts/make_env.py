#!/usr/bin/env python3
"""Makes the repository's .env from .env.example when there is none.

Every value in the example that starts with `change-me` (the database
passwords and Rails's secret) is published in the repository, so a .env
that kept them would start the developer stack with secrets anyone can
read. This writes each of them as a fresh random value of its own instead,
in hexadecimal (only letters and digits, as the example asks), and keeps
every other line as it is. The Mac app does the same for its own server
folder (ServerFiles.swift).

An existing .env is never changed. The file is written next to .env and
linked into place, so two scripts started at once cannot overwrite each
other's file; the one that loses the race keeps the winner's.

Usage: python3 -I scripts/make_env.py [<repository root>]
Prints one line when it made the file; exits 0 when .env exists afterwards.
Standard library only.
"""

import os
import secrets
import sys
import tempfile
from pathlib import Path

PLACEHOLDER = "change-me"
# Rails asks for at least 64 hexadecimal characters; `openssl rand -hex 64`
# in the example gives 128.
LONG_VALUES = {"SECRET_KEY_BASE": 64}
DEFAULT_BYTES = 32


def fill(example_text):
    lines = []
    for line in example_text.splitlines(keepends=True):
        key, sep, value = line.partition("=")
        if sep and not key.lstrip().startswith("#") and value.strip().startswith(PLACEHOLDER):
            ending = "\n" if line.endswith("\n") else ""
            size = LONG_VALUES.get(key.strip(), DEFAULT_BYTES)
            line = f"{key}={secrets.token_hex(size)}{ending}"
        lines.append(line)
    return "".join(lines)


def make(root):
    target = root / ".env"
    if target.exists():
        return False
    text = fill((root / ".env.example").read_text(encoding="utf-8"))
    handle, temporary = tempfile.mkstemp(prefix=".env.making.", dir=root)
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as stream:
            stream.write(text)
        os.chmod(temporary, 0o600)
        try:
            os.link(temporary, target)
        except FileExistsError:
            return False
    finally:
        os.unlink(temporary)
    return True


def main(argv):
    if len(argv) > 1:
        print("usage: make_env.py [<repository root>]", file=sys.stderr)
        return 64
    root = Path(argv[0]) if argv else Path(__file__).resolve().parent.parent
    if make(root):
        print("made .env from .env.example, with generated passwords and secret")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
