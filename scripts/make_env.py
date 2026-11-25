#!/usr/bin/env python3
"""Make .env from .env.example, with random secrets of its own.

.env.example leaves the database owner's password, the login role's
password and SECRET_KEY_BASE empty, so that a copy of it alone starts
nothing: a server run on values published in this repository would give
its database to anyone who can reach it. This script writes the .env a
developer's run, CI and the end-to-end scripts use: every line of the
example, with each of those three, where the example leaves it empty,
given a random hex value (32, 32 and 128 characters, as the app gives its
own server folder). The file is made with mode 0600 and is never written
over: an existing .env may hold the passwords a database volume was
initialized with.

Usage: python3 -I scripts/make_env.py [--example FILE] [--output FILE]
Standard library only. Exits 0 when the file was written, 1 when it was
not (the message says why). It prints no value.
"""

import argparse
import os
import secrets
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
# Hex characters for each secret. Hex keeps the passwords to letters and
# digits, which is what DATABASE_URL can carry unescaped.
SECRETS = {"POSTGRES_PASSWORD": 32, "LEVERAGE_API_DB_PASSWORD": 32, "SECRET_KEY_BASE": 128}


def make(text):
    """Return the example's text with each empty secret given a value."""
    lines = []
    for line in text.splitlines(keepends=True):
        key, separator, value = line.rstrip("\r\n").partition("=")
        if separator and key in SECRETS and value == "":
            ending = line[len(line.rstrip("\r\n")):]
            line = f"{key}={secrets.token_hex(SECRETS[key] // 2)}{ending}"
        lines.append(line)
    return "".join(lines)


def main(arguments=None):
    parser = argparse.ArgumentParser(description="Make .env from .env.example with random secrets.")
    parser.add_argument("--example", type=Path, default=ROOT / ".env.example",
                        help="the example to read (default: .env.example at the repository root)")
    parser.add_argument("--output", type=Path, default=ROOT / ".env",
                        help="the file to make (default: .env at the repository root)")
    options = parser.parse_args(arguments)

    try:
        text = options.example.read_text(encoding="utf-8")
    except OSError as error:
        print(f"make_env: cannot read {options.example}: {error.strerror}", file=sys.stderr)
        return 1
    try:
        descriptor = os.open(options.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        print(f"make_env: {options.output} is already there and was left as it is. "
              "Remove it yourself to have a new one made.", file=sys.stderr)
        return 1
    except OSError as error:
        print(f"make_env: cannot write {options.output}: {error.strerror}", file=sys.stderr)
        return 1
    with os.fdopen(descriptor, "w", encoding="utf-8") as output:
        output.write(make(text))
    print(f"make_env: wrote {options.output} with secrets of its own")
    return 0


if __name__ == "__main__":
    sys.exit(main())
