#!/usr/bin/env python3
"""Check that the PRD's tables equal the contract files that copy them.

The Docker image holds api/ only, so the Ruby tests cannot read docs/PRD.md.
This script compares, by heading and table header, every PRD table that a
contract file in api/contract/ copies, and fails on any difference:

  * the lifecycle table (under "## Task lifecycle") with the `source: prd`
    groups of state_machine.json: one group per row with its six cells
    verbatim in prd_cells; the event types of the Events written cell equal
    the events and conditional events of the group's rows (side events are
    not counted); the Hook cell is every row's hook; the From cell names the
    rows' from-states.
  * "### Step kinds" with steps.json: kind; the class, normalised
    ("Rule check" is rule_check) and verbatim; the Open while and Subject
    cells verbatim; a Subject of None means no subject kind.
  * "### Hooks" with hooks.json: hook; the Moment, Checkers and If a gate
    fails cells verbatim; the checkers the Checkers cell names; a hook whose
    Checkers cell says policy has no failed-gate effect, any other has one.
    The table under "### Check identity, re-runs and overrides" gives each
    hook's hashed inputs, verbatim, or none.
  * "#### Needs you choices" with needs_you.json: item name, about, hold
    reason, and the choices cell verbatim.
  * "### Roles" with roles.json: role, May change and May read verbatim.
  * the agent calls table (under "## Agent interface") with the registry's
    operations tagged agent: method, path and the Seat cell's caller.

A missing section or table is reported as "section missing", and a cell that
cannot be read as what it should hold as "unparsable cell", so a rewording
fails loudly. The Markdown helpers are check_registry.py's.

Usage: python3 scripts/check_contract_tables.py [--prd PATH] [--contract DIR]
Standard library only; exits 0 when every table agrees, 1 otherwise.
"""

import argparse
import importlib.util
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
DEFAULT_PRD = ROOT / "docs" / "PRD.md"
DEFAULT_CONTRACT = ROOT / "api" / "contract"
FILES = ("state_machine.json", "steps.json", "hooks.json", "needs_you.json",
         "roles.json", "registry.json")


def _markdown_helpers():
    """check_registry.py, loaded by path: -I keeps this folder off sys.path."""
    spec = importlib.util.spec_from_file_location("check_registry", HERE / "check_registry.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


_md = _markdown_helpers()
prose_lines, section, tables, code_spans = _md.prose_lines, _md.section, _md.tables, _md.code_spans
Found = _md.Found

EVENT_TYPE = _md.EVENT_TYPE
NAME = _md.NAME
HOOK = EVENT_TYPE
CALL = re.compile(r"^(GET|POST) (/v1/[a-z0-9{}/-]+)(\?[a-z0-9=&]+)?$")
SIBLING = re.compile(r"^/[a-z0-9{}-]+$")

LIFECYCLE_HEADER = ["Command", "From", "To", "Who may ask", "Hook", "Events written"]
STEPS_HEADER = ["Kind", "Class", "Open while", "Subject"]
HOOKS_HEADER = ["Hook", "Moment", "Checkers in version 1", "If a gate fails"]
HASHED_HEADER = ["Hook", "Inputs that are hashed"]
NEEDS_YOU_HEADER = ["Item", "About", "Hold reason", "Choices, and what each does"]
ROLES_HEADER = ["Role", "May change", "May read"]
CALLS_HEADER = ["Call", "Seat", "What it does"]

# "Any" in a From cell means every state a task can still leave: Done and
# Cancelled are where a task ends (Cancel is "Any except Done"; nothing moves
# a Cancelled task).
TERMINAL_STATES = ("done", "cancelled")

# The agent calls table's Seat cell, as the registry's operation caller
# (api/contract/README.md, "An operation's caller").
SEAT_CALLERS = {
    "Any": "any",
    "Builder": "builder",
    "Holder": "holder",
    "Reviewer": "reviewer",
    "Orchestrator, planner": "job_claimer",
    "Job holder": "job_holder",
}


def q(value):
    """A value as the messages show it: a name in backticks, null as null."""
    return "null" if value is None else f"`{value}`"


def names(values):
    return ", ".join(q(value) for value in sorted(values, key=str)) or "nothing"


def table_under(text, title, header, label):
    """(rows, problems) of the table with this header under the heading."""
    body = section(prose_lines(text), title)
    if body is None:
        return None, [f"section missing: no \"{title}\" heading for the {label}"]
    found = [t for t in tables(body) if t[0] == header]
    if len(found) != 1:
        return None, [f"section missing: expected one table \"| {' | '.join(header)} |\""
                      f" under \"{title}\" for the {label}, found {len(found)}"]
    rows, problems = [], []
    for cells in found[0][1]:
        if len(cells) != len(header):
            problems.append(f"unparsable cell: {label} row {cells!r}: expected {len(header)} cells")
        else:
            rows.append(cells)
    return rows, problems


def read_table(text, title, header, label):
    found = Found()
    rows, problems = table_under(text, title, header, label)
    found.problems += problems
    found.values = rows or []
    return found


def one_code_span(cell, pattern):
    """The cell's value when it is exactly one well-formed code span."""
    spans = code_spans(cell)
    if len(spans) == 1 and cell.strip() == f"`{spans[0]}`" and pattern.match(spans[0]):
        return spans[0]
    return None


def verbatim(messages, where, column, prd_value, file, contract_value):
    if prd_value != contract_value:
        messages.append(f"{where}: {column} cell differs: PRD {json.dumps(prd_value)},"
                        f" {file} {json.dumps(contract_value)}")


def one_side(messages, label, prd_keys, contract_keys, file):
    for key in prd_keys:
        if key not in contract_keys:
            messages.append(f"{label} {key}: in the PRD only")
    for key in contract_keys:
        if key not in prd_keys:
            messages.append(f"{label} {key}: in {file} only")
    for key in sorted({k for k in prd_keys if prd_keys.count(k) > 1}):
        messages.append(f"{label} {key}: appears more than once in the PRD")


# --- Lifecycle table ----------------------------------------------------------


def lifecycle_from_prd(text):
    return read_table(text, "Task lifecycle", LIFECYCLE_HEADER, "lifecycle table")


def event_spans(cell):
    """(event types, problems) from an Events written cell: every code span."""
    spans = code_spans(cell)
    bad = [span for span in spans if not EVENT_TYPE.match(span)]
    problems = []
    if bad:
        problems.append(f"code span(s) {', '.join(f'`{span}`' for span in bad)} are not event types")
    if not spans:
        problems.append("no event type found")
    return [span for span in spans if EVENT_TYPE.match(span)], problems


def from_states(cell, states):
    """The states a From cell names: None for "None", every state a task can
    leave for "Any", less those after "except"; None as the set when the cell
    names no state."""
    if cell == "None":
        return {None}
    shown = {state: state.replace("_", " ").capitalize() for state in states}

    def named(part):
        return {state for state, label in shown.items() if re.search(rf"\b{re.escape(label)}\b", part)}

    if cell.startswith("Any"):
        _, _, excepted = cell.partition(" except ")
        return {s for s in states if s not in TERMINAL_STATES} - named(excepted)
    found = named(cell)
    return found or None


def lifecycle_label(cells):
    return f"row \"{cells[0]}\" (from \"{cells[1]}\")"


def pair_groups(prd_rows, groups):
    """[(cells, group or None)] and the groups no PRD row took. A row takes the
    one group whose Command cell it shares; when several share it, the one
    whose From cell it shares."""
    free = list(groups)
    pairs = []
    for cells in prd_rows:
        same = [g for g in free if (g.get("prd_cells") or [None])[0] == cells[0]]
        if len(same) > 1:
            same = [g for g in same if g["prd_cells"][1:2] == cells[1:2]]
        chosen = same[0] if len(same) == 1 else None
        if chosen is not None:
            free.remove(chosen)
        pairs.append((cells, chosen))
    return pairs, free


def compare_lifecycle(text, contract):
    found = lifecycle_from_prd(text)
    messages = [f"lifecycle table: {problem}" for problem in found.problems]
    if found.problems and not found.values:
        return messages
    states = contract["registry.json"].get("lists", {}).get("task_states", [])
    groups = [g for g in contract["state_machine.json"].get("groups", []) if g.get("source") == "prd"]
    pairs, unpaired = pair_groups(found.values, groups)

    for cells, group in pairs:
        where = f"lifecycle table, {lifecycle_label(cells)}"
        if group is None:
            messages.append(f"{where}: in the PRD only; no `source: prd` group in state_machine.json has these cells")
            continue
        where += f", group `{group.get('id')}`"
        copied = group.get("prd_cells") or []
        if len(copied) != len(LIFECYCLE_HEADER):
            messages.append(f"{where}: prd_cells has {len(copied)} cells, the table {len(LIFECYCLE_HEADER)}")
        for index, column in enumerate(LIFECYCLE_HEADER):
            verbatim(messages, where, column, cells[index], "state_machine.json",
                     copied[index] if index < len(copied) else None)
        rows = group.get("rows", [])

        events, problems = event_spans(cells[5])
        for problem in problems:
            messages.append(f"unparsable cell: {where}: Events written: {problem}")
        written = set()
        for r in rows:
            written |= set(r.get("events", []))
            written |= {c.get("event") for c in r.get("conditional_events", [])}
        if not problems:
            only_prd = set(events) - written
            only_contract = written - set(events)
            if only_prd:
                messages.append(f"{where}: Events written names {names(only_prd)}, which no row of the group"
                                " writes as an event or a conditional event")
            if only_contract:
                messages.append(f"{where}: the group's rows write {names(only_contract)} as events or conditional"
                                " events, which the Events written cell does not name")

        hook_cell = cells[4]
        hook = None if hook_cell == "None" else one_code_span(hook_cell, HOOK)
        if hook_cell != "None" and hook is None:
            messages.append(f"unparsable cell: {where}: Hook {hook_cell!r} is neither None nor one hook")
        else:
            wrong = {r.get("hook") for r in rows
                     if r.get("hook") != hook and not (r.get("refusal") and r.get("hook") is None)}
            if wrong:
                messages.append(f"{where}: the Hook cell is {hook_cell}, but rows of the group have hook {names(wrong)}")

        named = from_states(cells[1], states)
        if named is None:
            messages.append(f"unparsable cell: {where}: From {cells[1]!r} names no state")
        else:
            starts = {r.get("from") for r in rows}
            if starts != named:
                messages.append(f"{where}: the From cell names {names(named)}, but the group's rows start"
                                f" from {names(starts)}")

    for group in unpaired:
        cells = group.get("prd_cells") or ["?", "?"]
        messages.append(f"lifecycle table, {lifecycle_label(cells)}, group `{group.get('id')}`:"
                        " in state_machine.json only; no PRD row has this Command cell")
    return messages


# --- Step kinds -------------------------------------------------------------


def compare_steps(text, contract):
    found = read_table(text, "Step kinds", STEPS_HEADER, "step kinds table")
    messages = [f"step kinds: {problem}" for problem in found.problems]
    entries = {s.get("kind"): s for s in contract["steps.json"].get("steps", [])}
    kinds = []
    for kind_cell, class_cell, open_while, subject in found.values:
        kind = one_code_span(kind_cell, NAME)
        if kind is None:
            messages.append(f"unparsable cell: step kinds, Kind {kind_cell!r}")
            continue
        kinds.append(f"`{kind}`")
        entry = entries.get(kind)
        if entry is None:
            continue
        where = f"step kinds, `{kind}`"
        step_class = class_cell.lower().replace(" ", "_")
        if entry.get("class") != step_class:
            messages.append(f"{where}: class differs: PRD {json.dumps(class_cell)} ({q(step_class)}),"
                            f" steps.json {q(entry.get('class'))}")
        verbatim(messages, where, "Class", class_cell, "steps.json", entry.get("prd_class"))
        verbatim(messages, where, "Open while", open_while, "steps.json", entry.get("prd_open_while"))
        verbatim(messages, where, "Subject", subject, "steps.json", entry.get("prd_subject"))
        none_subject = entry.get("subject_kinds") == [None]
        if (subject == "None") != none_subject:
            messages.append(f"{where}: Subject cell is {json.dumps(subject)}, but steps.json subject_kinds is"
                            f" {json.dumps(entry.get('subject_kinds'))}: a Subject of None means [null] and only that")
    one_side(messages, "step kinds,", kinds, [f"`{k}`" for k in entries], "steps.json")
    return messages


# --- Hooks ------------------------------------------------------------------


def checkers_from_cell(cell):
    """(checkers, says policy) from a Checkers cell's first sentence, or
    (None, None) when it does not read as a list of checkers."""
    first = cell.split(". ", 1)[0].rstrip(".")
    parts = [part.strip() for part in first.split(",")]
    policy = "policy" in parts
    parts = [part for part in parts if part != "policy"]
    if len(parts) != 1:
        return None, None
    phrase = re.sub(r" only$", "", parts[0])
    checkers = [word.strip().lower() for word in phrase.split(" and ")]
    if not all(NAME.match(checker) for checker in checkers):
        return None, None
    return checkers, policy


def compare_hooks(text, contract):
    found = read_table(text, "Hooks", HOOKS_HEADER, "hooks table")
    hashed = read_table(text, "Check identity, re-runs and overrides", HASHED_HEADER, "hashed inputs table")
    messages = [f"hooks: {problem}" for problem in found.problems + hashed.problems]
    entries = {h.get("hook"): h for h in contract["hooks.json"].get("hooks", [])}
    known_checkers = contract["registry.json"].get("lists", {}).get("checkers", [])

    hashed_inputs = {}
    for hook_cell, inputs in hashed.values:
        hook = one_code_span(hook_cell, HOOK)
        if hook is None:
            messages.append(f"unparsable cell: hooks, hashed inputs table, Hook {hook_cell!r}")
        elif hook in hashed_inputs:
            messages.append(f"hooks, `{hook}`: appears more than once in the hashed inputs table")
        else:
            hashed_inputs[hook] = inputs
    for hook in hashed_inputs:
        if hook not in entries:
            messages.append(f"hooks, `{hook}`: in the PRD's hashed inputs table only")

    hooks = []
    for hook_cell, moment, checkers_cell, failed_cell in found.values:
        hook = one_code_span(hook_cell, HOOK)
        if hook is None:
            messages.append(f"unparsable cell: hooks, Hook {hook_cell!r}")
            continue
        hooks.append(f"`{hook}`")
        entry = entries.get(hook)
        if entry is None:
            continue
        where = f"hooks, `{hook}`"
        verbatim(messages, where, "Moment", moment, "hooks.json", entry.get("prd_moment"))
        verbatim(messages, where, "Checkers in version 1", checkers_cell, "hooks.json", entry.get("prd_checkers"))
        verbatim(messages, where, "If a gate fails", failed_cell, "hooks.json", entry.get("prd_failed_gate"))
        verbatim(messages, where, "Inputs that are hashed", hashed_inputs.get(hook), "hooks.json",
                 entry.get("prd_hashed_inputs"))

        checkers, policy = checkers_from_cell(checkers_cell)
        if checkers is None or not set(checkers) <= set(known_checkers):
            messages.append(f"unparsable cell: {where}: Checkers {checkers_cell!r} does not name checkers"
                            f" from {names(known_checkers)}")
            continue
        if sorted(checkers) != sorted(entry.get("checkers", [])):
            messages.append(f"{where}: the Checkers cell names {names(checkers)}, hooks.json checkers"
                            f" {names(entry.get('checkers', []))}")
        kinds, effect = entry.get("rule_kinds", []), entry.get("failed_gate")
        if policy:
            if kinds != ["policy"] or effect is not None:
                messages.append(f"{where}: the Checkers cell says policy, so the hook is not a gate, but hooks.json"
                                f" has rule_kinds {json.dumps(kinds)} and failed_gate {json.dumps(effect)}")
        elif "gate" not in kinds or effect is None:
            messages.append(f"{where}: the Checkers cell names no policy, so the hook is a gate, but hooks.json"
                            f" has rule_kinds {json.dumps(kinds)} and failed_gate {json.dumps(effect)}")
        if failed_cell.startswith("Not a gate") and effect is not None:
            messages.append(f"{where}: If a gate fails says \"Not a gate\", but hooks.json failed_gate is"
                            f" {json.dumps(effect)}")
    one_side(messages, "hooks,", hooks, [f"`{h}`" for h in entries], "hooks.json")
    return messages


# --- Needs you choices ------------------------------------------------------


def compare_needs_you(text, contract):
    found = read_table(text, "Needs you choices", NEEDS_YOU_HEADER, "Needs you choices table")
    messages = [f"Needs you choices: {problem}" for problem in found.problems]
    entries = {item.get("prd_item"): item for item in contract["needs_you.json"].get("items", [])}
    items = []
    for item, about_cell, reason_cell, choices in found.values:
        items.append(f"\"{item}\"")
        entry = entries.get(item)
        if entry is None:
            continue
        where = f"Needs you choices, \"{item}\""
        about = about_cell.lower()
        if not NAME.match(about):
            messages.append(f"unparsable cell: {where}: About {about_cell!r}")
        elif entry.get("about") != about:
            messages.append(f"{where}: About differs: PRD {q(about)}, needs_you.json {q(entry.get('about'))}")
        reason = None if reason_cell == "None" else one_code_span(reason_cell, NAME)
        if reason_cell != "None" and reason is None:
            messages.append(f"unparsable cell: {where}: Hold reason {reason_cell!r} is neither None nor one reason")
        elif entry.get("hold_reason") != reason:
            messages.append(f"{where}: hold reason differs: PRD {q(reason)},"
                            f" needs_you.json {q(entry.get('hold_reason'))}")
        verbatim(messages, where, "Choices", choices, "needs_you.json", entry.get("prd_choices"))
    one_side(messages, "Needs you choices,", items, [f"\"{k}\"" for k in entries], "needs_you.json")
    return messages


# --- Roles ------------------------------------------------------------------


def compare_roles(text, contract):
    found = read_table(text, "Roles", ROLES_HEADER, "roles table")
    messages = [f"roles: {problem}" for problem in found.problems]
    entries = {r.get("role"): r for r in contract["roles.json"].get("roles", [])}
    roles = []
    for role_cell, may_change, may_read in found.values:
        role = role_cell.lower()
        if not NAME.match(role):
            messages.append(f"unparsable cell: roles, Role {role_cell!r}")
            continue
        roles.append(role)
        entry = entries.get(role)
        if entry is None:
            continue
        verbatim(messages, f"roles, {role}", "May change", may_change, "roles.json", entry.get("prd_may_change"))
        verbatim(messages, f"roles, {role}", "May read", may_read, "roles.json", entry.get("prd_may_read"))
    one_side(messages, "roles,", roles, list(entries), "roles.json")
    return messages


# --- Agent calls ------------------------------------------------------------


def agent_calls_from_prd(text):
    """{values: [(method, path, caller)]} from the agent calls table. A later
    code span that is a bare path segment (`/release`) is a sibling of the
    first call: the same path with its last segment replaced."""
    found = read_table(text, "Agent interface", CALLS_HEADER, "agent calls table")
    rows, found.values = found.values, []
    for call_cell, seat, _ in rows:
        spans = code_spans(call_cell)
        first = CALL.match(spans[0]) if spans else None
        if first is None or not all(SIBLING.match(span) for span in spans[1:]):
            found.problems.append(f"unparsable cell: agent calls, Call {call_cell!r}")
            continue
        caller = SEAT_CALLERS.get(seat)
        if caller is None:
            found.problems.append(f"unparsable cell: agent calls, {spans[0]}: Seat {seat!r} is not one of"
                                  f" {', '.join(SEAT_CALLERS)}")
            continue
        method, path = first.group(1), first.group(2)
        found.values.append((method, path, caller))
        for sibling in spans[1:]:
            found.values.append((method, path.rsplit("/", 1)[0] + sibling, caller))
    return found


def compare_agent_calls(text, contract):
    found = agent_calls_from_prd(text)
    messages = [problem if problem.startswith("unparsable") else f"agent calls: {problem}"
                for problem in found.problems]
    operations = {f"{o.get('method')} {o.get('path')}": o
                  for o in contract["registry.json"].get("operations", []) if o.get("tag") == "agent"}
    calls = []
    for method, path, caller in found.values:
        key = f"{method} {path}"
        calls.append(key)
        operation = operations.get(key)
        if operation is not None and operation.get("caller") != caller:
            seat = next(cell for cell, value in SEAT_CALLERS.items() if value == caller)
            messages.append(f"agent calls, {key}: seat differs: PRD \"{seat}\" ({q(caller)}),"
                            f" registry {q(operation.get('caller'))} (operation `{operation.get('operation_id')}`)")
    for key in calls:
        if key not in operations:
            messages.append(f"agent calls, {key}: in the PRD only")
    for key in operations:
        if key not in calls:
            messages.append(f"agent calls, {key}: in the registry only (operation"
                            f" `{operations[key].get('operation_id')}`)")
    for key in sorted({k for k in calls if calls.count(k) > 1}):
        messages.append(f"agent calls, {key}: appears more than once in the PRD")
    return messages


# --- Main -------------------------------------------------------------------


def check(prd_text, contract):
    """Every difference between the PRD's tables and the contract files."""
    return (compare_lifecycle(prd_text, contract)
            + compare_steps(prd_text, contract)
            + compare_hooks(prd_text, contract)
            + compare_needs_you(prd_text, contract)
            + compare_roles(prd_text, contract)
            + compare_agent_calls(prd_text, contract))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--prd", type=Path, default=DEFAULT_PRD)
    parser.add_argument("--contract", type=Path, default=DEFAULT_CONTRACT)
    args = parser.parse_args(argv)
    try:
        prd_text = args.prd.read_text(encoding="utf-8")
        contract = {name: json.loads((args.contract / name).read_text(encoding="utf-8")) for name in FILES}
    except (OSError, json.JSONDecodeError) as error:
        print(f"ERROR: {error}")
        return 1
    for name, data in contract.items():
        if not isinstance(data, dict):
            print(f"ERROR: {args.contract / name} is not a JSON object")
            return 1

    messages = check(prd_text, contract)
    if messages:
        print(f"The PRD's tables and the contract differ ({args.prd}, {args.contract}):")
        for message in messages:
            print(f"  - {message}")
        return 1
    counts = (
        len(lifecycle_from_prd(prd_text).values),
        len(contract["steps.json"].get("steps", [])),
        len(contract["hooks.json"].get("hooks", [])),
        len(contract["needs_you.json"].get("items", [])),
        len(contract["roles.json"].get("roles", [])),
        len(agent_calls_from_prd(prd_text).values),
    )
    print("OK: the PRD's tables and the contract agree on %d lifecycle rows, %d step kinds, %d hooks,"
          " %d Needs you items, %d roles and %d agent calls." % counts)
    return 0


if __name__ == "__main__":
    sys.exit(main())
