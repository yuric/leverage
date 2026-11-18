#!/usr/bin/env python3
"""Check the requirement IDs in the PRD.

Requirement IDs are how issues, pull requests, tests, and commits refer to a
requirement, so they have to be unambiguous. This script fails if:

  * an ID in a requirements table is malformed (the format is FR-001 /
    NFR-001: prefix, hyphen, three digits);
  * the same ID is defined twice;
  * an FR- ID is defined in the non-functional table, or the reverse;
  * the PRD refers to an ID that no table defines.

Usage: python3 scripts/check_prd_ids.py [path/to/PRD.md]
Standard library only; exits 0 when the PRD is consistent, 1 otherwise.
"""

import re
import sys
from pathlib import Path

DEFAULT_PRD = Path(__file__).resolve().parent.parent / "docs" / "PRD.md"

VALID_ID = re.compile(r"^(FR|NFR)-\d{3}$")
# Anything in an ID column that is clearly meant to be an ID: "FR-1",
# "fr-001", "NFR_002", "FR 003", "FR-0004".
LOOKS_LIKE_ID = re.compile(r"^N?FR[\s_-]*\d+$", re.IGNORECASE)
REFERENCE = re.compile(r"\b(?:FR|NFR)-\d+\b")
HEADING = re.compile(r"^#{1,6}\s+(.*)$")


def first_cell(line):
    """Return the first cell of a Markdown table row, or None."""
    stripped = line.strip()
    if not stripped.startswith("|"):
        return None
    cells = stripped.strip("|").split("|")
    return cells[0].strip().strip("`*").strip()


def expected_prefix(heading):
    """Which ID prefix belongs under this heading, if any."""
    text = heading.lower()
    if "non-functional" in text or "nonfunctional" in text:
        return "NFR"
    if "functional" in text:
        return "FR"
    return None


def check(path):
    errors = []
    defined = {}  # id -> line number of first definition
    references = []  # (id, line number)
    section_prefix = None
    in_code_block = False

    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if line.strip().startswith("```"):
            in_code_block = not in_code_block
            continue
        if in_code_block:
            continue

        heading = HEADING.match(line)
        if heading:
            section_prefix = expected_prefix(heading.group(1))
            continue

        cell = first_cell(line)
        is_definition = False
        if cell and LOOKS_LIKE_ID.match(cell):
            is_definition = True
            if not VALID_ID.match(cell):
                errors.append(
                    f"line {number}: '{cell}' is not a valid requirement ID "
                    "(expected FR-001 or NFR-001: prefix, hyphen, three digits)"
                )
            else:
                prefix = cell.split("-")[0]
                if cell in defined:
                    errors.append(
                        f"line {number}: {cell} is already defined on line "
                        f"{defined[cell]} (IDs are never reused)"
                    )
                else:
                    defined[cell] = number
                if section_prefix and prefix != section_prefix:
                    errors.append(
                        f"line {number}: {cell} is defined in a section that "
                        f"holds {section_prefix}- requirements"
                    )

        for match in REFERENCE.finditer(line):
            if is_definition and match.group(0) == cell:
                continue
            references.append((match.group(0), number))

    for ref, number in references:
        if ref not in defined:
            errors.append(
                f"line {number}: {ref} is referenced but no requirements "
                "table defines it"
            )

    return defined, errors


def main(argv):
    path = Path(argv[1]) if len(argv) > 1 else DEFAULT_PRD
    if not path.is_file():
        print(f"error: {path} not found", file=sys.stderr)
        return 1

    defined, errors = check(path)
    if errors:
        print(f"{path}: {len(errors)} problem(s) with requirement IDs")
        for error in errors:
            print(f"  {error}")
        return 1

    functional = sum(1 for key in defined if key.startswith("FR-"))
    print(
        f"OK: {len(defined)} requirement ID(s) in {path.name} "
        f"({functional} FR, {len(defined) - functional} NFR)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
