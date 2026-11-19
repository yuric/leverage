#!/usr/bin/env python3
"""Check the requirement IDs in the PRD.

Requirement IDs are how issues, pull requests, tests, and commits refer to a
requirement, so they have to be unambiguous. This script fails if:

  * an ID in a requirements table is malformed (the format is FR-001 /
    NFR-001: prefix, hyphen, three digits);
  * the same ID is defined twice;
  * an FR- ID is defined in the non-functional table, or the reverse;
  * the PRD refers to an ID that no table defines.

Text inside HTML comments and fenced code blocks is not read. check_rules.py
loads this file for lines_of() and check_text(), so that both checks read
Markdown the same way; this file imports nothing from it.

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
FENCE = re.compile(r"^ {0,3}(`{3,}|~{3,})(.*)$")


# --- Reading Markdown -------------------------------------------------------


def _strip_comments(line, in_comment):
    """Remove HTML comments from one line; return (text, still in a comment).

    A "<!--" inside an inline code span is text, not a comment. A comment
    that is never closed hides everything after it, as it does on GitHub.
    """
    out = []
    i, n = 0, len(line)
    while i < n:
        if in_comment:
            end = line.find("-->", i)
            if end < 0:
                return "".join(out), True
            i, in_comment = end + 3, False
        elif line.startswith("<!-->", i):  # an empty comment, by the HTML rules
            i += 5
        elif line.startswith("<!--->", i):
            i += 6
        elif line.startswith("<!--", i):
            i, in_comment = i + 4, True
        elif line[i] == "`":
            j = i
            while j < n and line[j] == "`":
                j += 1
            ticks = j - i
            close = re.compile(r"(?<!`)`{%d}(?!`)" % ticks).search(line, j)
            end = close.end() if close else j
            out.append(line[i:end])
            i = end
        else:
            out.append(line[i])
            i += 1
    return "".join(out), in_comment


def lines_of(text, keep_code=False):
    """Yield (line, in_code) for the lines a reader of the rendered page sees.

    HTML comments are removed. Lines inside fenced code blocks are skipped
    unless keep_code is set, so that an example is never mistaken for a
    heading, an ID, or an answer. A fence closes only on a line of the same
    character, at least as long as the one that opened it. With keep_code
    set, every line of the text is yielded, so the lines can be numbered.
    """
    fence = None  # (character, length) while inside a fenced block
    in_comment = False
    for raw in text.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
        if fence:
            marker = raw.strip()
            indent = len(raw) - len(raw.lstrip(" "))
            if marker and set(marker) == {fence[0]} and len(marker) >= fence[1] and indent <= 3:
                fence = None
            if keep_code:
                yield raw, True
            continue
        if not in_comment:
            opening = FENCE.match(raw)
            if opening and not (opening.group(1)[0] == "`" and "`" in opening.group(2)):
                fence = (opening.group(1)[0], len(opening.group(1)))
                if keep_code:
                    yield raw, True
                continue
        line, in_comment = _strip_comments(raw, in_comment)
        yield line, False


# --- Requirement IDs --------------------------------------------------------


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
    """Check a PRD file. Raises OSError or UnicodeError if it cannot be read."""
    return check_text(path.read_bytes().decode("utf-8"))


def check_text(text):
    """Return ({ID: line number}, [problems]) for the text of a PRD."""
    errors = []
    defined = {}  # id -> line number of first definition
    references = []  # (id, line number)
    section_prefix = None

    for number, (line, in_code) in enumerate(lines_of(text, keep_code=True), 1):
        if in_code:
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
    try:
        defined, errors = check(path)
    except FileNotFoundError:
        print(f"error: {path} not found", file=sys.stderr)
        return 1
    except UnicodeError:
        print(f"error: {path} is not UTF-8 text", file=sys.stderr)
        return 1
    except (OSError, ValueError) as problem:
        reason = getattr(problem, "strerror", None) or type(problem).__name__
        print(f"error: {path} could not be read ({reason})", file=sys.stderr)
        return 1

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
