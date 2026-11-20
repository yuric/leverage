#!/usr/bin/env python3
"""Make the compose file the app bundle carries from compose.yaml.

The app starts the server from a copy of the repository's compose.yaml
(milestone 2 plan PK-1, PK-2). Two things differ in that copy:

* the `build:` line is removed, because the app never builds the API
  image: scripts/build_app.sh builds it in this Mac's Docker beforehand;
* `pull_policy: never` is set on the `api`, `sweep` and `backup` services
  (the three that run the API image; milestone 3 plan WP13), so a
  missing image is reported as missing (the app says "This copy of
  leverage was not built on this Mac.") instead of Docker asking a
  registry for an image that is not there.

Every other line is kept as it is, in order. The change is made on the
text, not by loading and writing YAML, so comments and anchors survive;
a compose file of any other shape (no build line, two of them, a missing
service, a pull_policy already set) is refused with a message rather than
changed in a way scripts/test_app_compose.py has not checked.

Usage: python3 scripts/app_compose.py [--input compose.yaml] [--output FILE]
Without --output the result goes to standard output. Standard library only.
"""

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SERVICES = ("api", "sweep", "backup")
BUILD = re.compile(r"^\s*build:")
SERVICE_KEY = re.compile(r"^  ([A-Za-z0-9][A-Za-z0-9_.-]*):\s*$")
PULL_POLICY = "pull_policy: never"


class ComposeShapeError(Exception):
    """The compose file is not of the shape this script knows how to change."""


def make(text):
    """Return the bundle's compose text made from `text`."""
    lines = text.splitlines(keepends=True)

    builds = [index for index, line in enumerate(lines) if BUILD.match(line)]
    if len(builds) != 1:
        raise ComposeShapeError(
            f"expected exactly one build line, found {len(builds)}"
            + (f" (lines {', '.join(str(i + 1) for i in builds)})" if builds else ""))
    del lines[builds[0]]

    try:
        start = next(i for i, line in enumerate(lines) if line.rstrip("\r\n") == "services:")
    except StopIteration:
        raise ComposeShapeError("no top-level services: section") from None
    end = next((i for i in range(start + 1, len(lines))
                if lines[i].strip() and not lines[i].startswith((" ", "#"))), len(lines))

    keys = {}
    for index in range(start + 1, end):
        found = SERVICE_KEY.match(lines[index].rstrip("\r\n"))
        if found:
            keys[found.group(1)] = index

    for name in SERVICES:
        if name not in keys:
            raise ComposeShapeError(f'no service "{name}" under services:')

    # Insert from the bottom up so the indexes found above stay right.
    for name in sorted(SERVICES, key=lambda n: keys[n], reverse=True):
        key = keys[name]
        following = sorted(index for index in keys.values() if index > key)
        stop = following[0] if following else end
        body = [line for line in lines[key + 1:stop] if line.strip() and not line.lstrip().startswith("#")]
        if not body:
            raise ComposeShapeError(f'service "{name}" has no settings')
        if any(line.strip().startswith("pull_policy:") for line in body):
            raise ComposeShapeError(f'service "{name}" already sets pull_policy')
        indent = body[0][: len(body[0]) - len(body[0].lstrip(" "))]
        newline = "\r\n" if lines[key].endswith("\r\n") else "\n"
        lines.insert(key + 1, f"{indent}{PULL_POLICY}{newline}")

    return "".join(lines)


def main(arguments=None):
    parser = argparse.ArgumentParser(description="Make the app bundle's compose file.")
    parser.add_argument("--input", type=Path, default=ROOT / "compose.yaml",
                        help="the repository's compose file (default: compose.yaml)")
    parser.add_argument("--output", type=Path, help="where to write it (default: standard output)")
    options = parser.parse_args(arguments)

    try:
        text = options.input.read_text(encoding="utf-8")
    except OSError as error:
        print(f"app_compose: cannot read {options.input}: {error.strerror}", file=sys.stderr)
        return 1
    try:
        made = make(text)
    except ComposeShapeError as error:
        print(f"app_compose: {options.input}: {error}", file=sys.stderr)
        return 1

    if options.output is None:
        sys.stdout.write(made)
    else:
        options.output.parent.mkdir(parents=True, exist_ok=True)
        options.output.write_text(made, encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
