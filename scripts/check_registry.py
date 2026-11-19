#!/usr/bin/env python3
"""Check that the PRD's fixed lists equal the contract's registry (test 12).

The registry, api/contract/registry.json, is the authority for event types,
hold reasons, refusals and check results; the PRD keeps its tables and
sentences for them. This script fails when the two differ, value by value
and column by column:

  * event types: the table under "### Event types". Per row, the first cell
    is the group; the second cell up to its first sentence end outside a
    code span, with parenthesised text removed, gives the types (each code
    span). Compared with event_types[].type and event_types[].group.
  * hold reasons: the table under "### Holds" whose header starts
    "| Reason |". The reason (first-column code span), the Lease clock cell
    (Pauses, Runs, No lease exists), the In Blocked cell's first word (Yes,
    No) and the Step cell's code span, compared with lease_clock,
    in_blocked and step.
  * refusals: the paragraph starting "**Specific refusals.**". The set from
    its first sentence; the order from the sentence starting "When several
    causes apply"; the claims-only and owner-only codes from the sentences
    that say so. Compared with code, precedence, claims_only, owner_only.
  * check results: the sentence starting "A rule check result is one of"
    under "### How a transition is gated", parentheses removed.

Every list is found by its heading or its opening words, never by line
number. A missing section is reported as "section missing", and a cell or
sentence that yields no well-formed value, or a code span that is not one,
as "unparsable cell", so a rewording fails loudly. Release reasons are kept
in the registry only and are not compared (PRD, Event types).

Usage: python3 scripts/check_registry.py [--prd PATH] [--registry PATH]
Standard library only; exits 0 when the lists agree, 1 otherwise.
"""

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_PRD = ROOT / "docs" / "PRD.md"
DEFAULT_REGISTRY = ROOT / "api" / "contract" / "registry.json"

EVENT_TYPE = re.compile(r"^[a-z_]+\.[a-z_]+$")
NAME = re.compile(r"^[a-z_]+$")
HEADING = re.compile(r"^(#{1,6})\s+(.*?)\s*$")
FENCE = re.compile(r"^ {0,3}(`{3,}|~{3,})")

LEASE_CLOCK = {"Pauses": "pauses", "Runs": "runs", "No lease exists": "no_lease"}
IN_BLOCKED = {"Yes": True, "No": False}


class Found:
    """Values read from the PRD, and the problems met while reading them."""

    def __init__(self):
        self.values = []
        self.problems = []


# --- Reading Markdown -------------------------------------------------------


def prose_lines(text):
    """The document's lines, with fenced code blocks blanked out."""
    lines, fence = [], None
    for line in text.splitlines():
        match = FENCE.match(line)
        if fence:
            if match and match.group(1)[0] == fence[0] and len(match.group(1)) >= len(fence):
                fence = None
            lines.append("")
        elif match:
            fence = match.group(1)
            lines.append("")
        else:
            lines.append(line)
    return lines


def section(lines, title):
    """The lines under a heading with this exact title, up to the next heading
    of the same or a higher level; None when there is no such heading."""
    for index, line in enumerate(lines):
        match = HEADING.match(line)
        if match and match.group(2) == title:
            level = len(match.group(1))
            body = []
            for following in lines[index + 1:]:
                other = HEADING.match(following)
                if other and len(other.group(1)) <= level:
                    break
                body.append(following)
            return body
    return None


def tables(lines):
    """Each Markdown table in lines, as (header cells, [row cells])."""
    found, current = [], None
    for line in lines + [""]:
        if line.lstrip().startswith("|"):
            cells = split_row(line)
            if current is None:
                current = (cells, [])
            elif all(re.fullmatch(r":?-{3,}:?", cell) for cell in cells):
                continue
            else:
                current[1].append(cells)
        elif current is not None:
            found.append(current)
            current = None
    return found


def split_row(line):
    """The cells of one table row; a pipe inside a code span does not split."""
    text = line.strip()
    if text.startswith("|"):
        text = text[1:]
    if text.endswith("|"):
        text = text[:-1]
    cells, cell, in_code = [], "", False
    for char in text:
        if char == "`":
            in_code = not in_code
        if char == "|" and not in_code:
            cells.append(cell.strip())
            cell = ""
        else:
            cell += char
    cells.append(cell.strip())
    return cells


def first_sentence_spans(text):
    """The code spans of text's first sentence that are outside parentheses.

    The sentence ends at the first full stop outside a code span and outside
    parentheses that is followed by a space or the end of the text. Returns
    (spans, problem); problem is None or says why the text cannot be read.
    """
    spans, depth, index = [], 0, 0
    while index < len(text):
        char = text[index]
        if char == "`":
            end = text.find("`", index + 1)
            if end < 0:
                return spans, "an unclosed code span"
            if depth == 0:
                spans.append(text[index + 1:end])
            index = end + 1
            continue
        if char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth < 0:
                return spans, "a closing parenthesis with no opening one"
        elif char == "." and depth == 0 and (index + 1 == len(text) or text[index + 1].isspace()):
            return spans, None
        index += 1
    if depth != 0:
        return spans, "an unclosed parenthesis"
    return spans, None


def code_spans(text):
    return re.findall(r"`([^`]*)`", text)


def sentence_from(text, opening):
    """text from the first place it says opening, or None."""
    start = text.find(opening)
    return None if start < 0 else text[start:]


def well_formed(spans, pattern, where, found):
    """Keep the spans that match pattern; report the cell when one does not,
    or when there are none."""
    bad = [span for span in spans if not pattern.match(span)]
    if bad:
        found.problems.append(
            f"unparsable cell: {where}: code span(s) {', '.join(f'`{span}`' for span in bad)}"
            " are not well-formed values")
    if not spans:
        found.problems.append(f"unparsable cell: {where}: no value found")
    return [span for span in spans if pattern.match(span)]


# --- The four PRD lists ------------------------------------------------------


def event_types_from_prd(text):
    """(group, type) pairs from the table under "### Event types"."""
    found = Found()
    body = section(prose_lines(text), "Event types")
    if body is None:
        found.problems.append('section missing: no "### Event types" heading')
        return found
    table = next((t for t in tables(body) if t[0][:2] == ["Group", "Types"]), None)
    if table is None:
        found.problems.append('section missing: no "| Group | Types |" table under "### Event types"')
        return found
    for cells in table[1]:
        if len(cells) != 2:
            found.problems.append(f"unparsable cell: event types row {cells!r}: expected 2 cells")
            continue
        group, cell = cells
        spans, problem = first_sentence_spans(cell)
        if problem:
            found.problems.append(f"unparsable cell: event types, group {group}: {problem}")
            continue
        for value in well_formed(spans, EVENT_TYPE, f"event types, group {group}", found):
            found.values.append((group, value))
    return found


def hold_reasons_from_prd(text):
    """(reason, lease_clock, in_blocked, step) from the Holds table."""
    found = Found()
    body = section(prose_lines(text), "Holds")
    if body is None:
        found.problems.append('section missing: no "### Holds" heading')
        return found
    table = next((t for t in tables(body) if t[0] and t[0][0] == "Reason"), None)
    if table is None:
        found.problems.append('section missing: no table starting "| Reason |" under "### Holds"')
        return found
    header = table[0]
    try:
        columns = {name: header.index(name) for name in ("Reason", "Lease clock", "In Blocked", "Step")}
    except ValueError as missing:
        found.problems.append(f"section missing: the Holds table has no column {missing}")
        return found
    for cells in table[1]:
        if len(cells) != len(header):
            found.problems.append(f"unparsable cell: hold reasons row {cells!r}: expected {len(header)} cells")
            continue
        reasons = code_spans(cells[columns["Reason"]])
        if len(reasons) != 1 or not NAME.match(reasons[0]):
            found.problems.append(f"unparsable cell: hold reasons, Reason cell {cells[columns['Reason']]!r}")
            continue
        reason = reasons[0]
        clock_cell = cells[columns["Lease clock"]]
        clock = LEASE_CLOCK.get(clock_cell)
        if clock is None:
            found.problems.append(f"unparsable cell: hold reasons, `{reason}`, Lease clock {clock_cell!r}")
        blocked_cell = cells[columns["In Blocked"]]
        first_word = re.match(r"[A-Za-z]+", blocked_cell)
        blocked = IN_BLOCKED.get(first_word.group(0)) if first_word else None
        if blocked is None:
            found.problems.append(f"unparsable cell: hold reasons, `{reason}`, In Blocked {blocked_cell!r}")
        steps = code_spans(cells[columns["Step"]])
        step = steps[0] if len(steps) == 1 and NAME.match(steps[0]) else None
        if step is None:
            found.problems.append(f"unparsable cell: hold reasons, `{reason}`, Step {cells[columns['Step']]!r}")
        found.values.append((reason, clock, blocked, step))
    return found


def refusals_from_prd(text):
    """{codes, precedence, claims_only, owner_only} from the refusals paragraph."""
    found = Found()
    lines = [line for line in prose_lines(text) if "**Specific refusals.**" in line]
    if len(lines) != 1:
        found.problems.append(
            'section missing: expected one paragraph starting "**Specific refusals.**",'
            f" found {len(lines)}")
        return found
    paragraph = lines[0].split("**Specific refusals.**", 1)[1].strip()

    spans, problem = first_sentence_spans(paragraph)
    if problem:
        found.problems.append(f"unparsable cell: refusals, first sentence: {problem}")
    codes = well_formed(spans, NAME, "refusals, first sentence", found)

    order = []
    sentence = sentence_from(paragraph, "When several causes apply")
    if sentence is None:
        found.problems.append('section missing: no sentence starting "When several causes apply"')
    else:
        spans, problem = first_sentence_spans(sentence)
        if problem:
            found.problems.append(f"unparsable cell: refusals, precedence sentence: {problem}")
        order = well_formed(spans, NAME, "refusals, precedence sentence", found)

    claims_only = marked(paragraph, "applies to claims only", "apply to claims only")
    owner_only = marked(paragraph, "are owner refusals", "is an owner refusal")
    found.values = {"codes": codes, "precedence": order, "claims_only": claims_only, "owner_only": owner_only}
    return found


def marked(paragraph, *phrases):
    """The codes named in each sentence of paragraph that says one of phrases."""
    codes = []
    for sentence in re.split(r"(?<=\.)\s+(?=[`A-Z])", paragraph):
        if any(phrase in sentence for phrase in phrases):
            spans, _ = first_sentence_spans(sentence)
            codes.extend(span for span in spans if NAME.match(span))
    return codes


def check_results_from_prd(text):
    """The check results from the sentence that lists them."""
    found = Found()
    body = section(prose_lines(text), "How a transition is gated")
    if body is None:
        found.problems.append('section missing: no "### How a transition is gated" heading')
        return found
    sentence = sentence_from("\n".join(body), "A rule check result is one of")
    if sentence is None:
        found.problems.append('section missing: no sentence starting "A rule check result is one of"')
        return found
    spans, problem = first_sentence_spans(sentence.split("\n", 1)[0])
    if problem:
        found.problems.append(f"unparsable cell: check results: {problem}")
    found.values = well_formed(spans, NAME, "check results", found)
    return found


# --- Comparison --------------------------------------------------------------


def one_side(label, prd_values, registry_values):
    """Messages for the values present on one side only."""
    messages = []
    prd_only = [value for value in prd_values if value not in registry_values]
    registry_only = [value for value in registry_values if value not in prd_values]
    if prd_only:
        messages.append(f"{label}: in the PRD only: {', '.join(f'`{v}`' for v in prd_only)}")
    if registry_only:
        messages.append(f"{label}: in the registry only: {', '.join(f'`{v}`' for v in registry_only)}")
    for value in sorted({v for v in prd_values if prd_values.count(v) > 1}):
        messages.append(f"{label}: `{value}` appears more than once in the PRD")
    return messages


def compare_event_types(found, registry):
    messages = [f"event types: {problem}" for problem in found.problems]
    entries = registry.get("event_types", [])
    prd_groups = {value: group for group, value in found.values}
    registry_groups = {entry.get("type"): entry.get("group") for entry in entries}
    messages += one_side("event types", [value for _, value in found.values],
                         [entry.get("type") for entry in entries])
    for value, group in prd_groups.items():
        if value in registry_groups and registry_groups[value] != group:
            messages.append(f"event types: `{value}`: group differs: PRD {group!r}, registry {registry_groups[value]!r}")
    return messages


def compare_hold_reasons(found, registry):
    messages = [f"hold reasons: {problem}" for problem in found.problems]
    entries = {entry.get("reason"): entry for entry in registry.get("hold_reasons", [])}
    messages += one_side("hold reasons", [row[0] for row in found.values], list(entries))
    for reason, clock, blocked, step in found.values:
        entry = entries.get(reason)
        if entry is None:
            continue
        for column, prd_value in (("lease_clock", clock), ("in_blocked", blocked), ("step", step)):
            if prd_value is not None and entry.get(column) != prd_value:
                messages.append(f"hold reasons: `{reason}`: {column} differs:"
                                f" PRD {json.dumps(prd_value)}, registry {json.dumps(entry.get(column))}")
    return messages


def compare_refusals(found, registry):
    messages = [f"refusals: {problem}" for problem in found.problems]
    if not isinstance(found.values, dict):
        return messages
    entries = registry.get("refusals", [])
    messages += one_side("refusals", found.values["codes"], [entry.get("code") for entry in entries])

    ranked = sorted((entry for entry in entries if entry.get("precedence") is not None),
                    key=lambda entry: entry["precedence"])
    registry_order = [entry.get("code") for entry in ranked]
    prd_order = found.values["precedence"]
    if prd_order != registry_order:
        differences = [f"position {index + 1}: PRD `{a}`, registry `{b}`"
                       for index, (a, b) in enumerate(zip(prd_order, registry_order)) if a != b]
        if len(prd_order) != len(registry_order):
            differences.append(f"PRD ranks {len(prd_order)}, registry ranks {len(registry_order)}")
        messages.append("refusals: precedence differs: " + "; ".join(differences))
        messages += one_side("refusals with a precedence", prd_order, registry_order)

    for flag, phrase in (("claims_only", "claims only"), ("owner_only", "owner refusals")):
        prd_set = set(found.values[flag])
        registry_set = {entry.get("code") for entry in entries if entry.get(flag)}
        for code in sorted(prd_set - registry_set):
            messages.append(f"refusals: `{code}`: the PRD says {phrase}, the registry's {flag} is not true")
        for code in sorted(registry_set - prd_set):
            messages.append(f"refusals: `{code}`: the registry's {flag} is true, the PRD does not say {phrase}")
    return messages


def compare_check_results(found, registry):
    messages = [f"check results: {problem}" for problem in found.problems]
    if isinstance(found.values, list):
        messages += one_side("check results", found.values, list(registry.get("check_results", [])))
    return messages


def check(prd_text, registry):
    """Every difference between the PRD's lists and the registry."""
    return (compare_event_types(event_types_from_prd(prd_text), registry)
            + compare_hold_reasons(hold_reasons_from_prd(prd_text), registry)
            + compare_refusals(refusals_from_prd(prd_text), registry)
            + compare_check_results(check_results_from_prd(prd_text), registry))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--prd", type=Path, default=DEFAULT_PRD)
    parser.add_argument("--registry", type=Path, default=DEFAULT_REGISTRY)
    args = parser.parse_args(argv)
    try:
        prd_text = args.prd.read_text(encoding="utf-8")
        registry = json.loads(args.registry.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        print(f"ERROR: {error}")
        return 1
    if not isinstance(registry, dict):
        print("ERROR: the registry is not a JSON object")
        return 1

    messages = check(prd_text, registry)
    if messages:
        print(f"The PRD and the registry differ ({args.prd}, {args.registry}):")
        for message in messages:
            print(f"  - {message}")
        return 1
    counts = (len(registry.get("event_types", [])), len(registry.get("hold_reasons", [])),
              len(registry.get("refusals", [])), len(registry.get("check_results", [])))
    print("OK: the PRD and the registry agree on %d event types, %d hold reasons,"
          " %d refusals and %d check results." % counts)
    return 0


if __name__ == "__main__":
    sys.exit(main())
