#!/usr/bin/env python3
"""Self-test for check_registry.py.

Runs check_registry.py on the real PRD and registry, which must pass, and on
doctored copies written to a temporary folder, each of which must fail and
name the value and the list that differ. Each case is a drift the check must
catch, or a reading it once could have got wrong.

Usage: python3 scripts/test_check_registry.py [-v]
Standard library only; exits 0 when every case behaves as expected.
"""

import copy
import importlib.util
import json
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
SCRIPT = HERE / "check_registry.py"
PRD = ROOT / "docs" / "PRD.md"
REGISTRY = ROOT / "api" / "contract" / "registry.json"
VERBOSE = "-v" in sys.argv[1:]


def run(prd_text, registry):
    """Run the check on the given PRD text and registry object."""
    with tempfile.TemporaryDirectory() as folder:
        prd_path = Path(folder) / "PRD.md"
        registry_path = Path(folder) / "registry.json"
        prd_path.write_text(prd_text, encoding="utf-8")
        registry_path.write_text(json.dumps(registry), encoding="utf-8")
        result = subprocess.run(
            [sys.executable, "-I", str(SCRIPT),
             "--prd", str(prd_path), "--registry", str(registry_path)],
            capture_output=True, text=True, check=False)
    return result.returncode, result.stdout + result.stderr


def replace_once(text, old, new):
    """Replace exactly one occurrence, so a doctored copy changes what it says."""
    count = text.count(old)
    if count != 1:
        raise AssertionError(f"expected one occurrence of {old!r}, found {count}")
    return text.replace(old, new)


def line_containing(text, needle):
    """The one line of the PRD that contains needle, or that starts with it
    when needle is the start of a table row."""
    if needle.startswith("| "):
        lines = [line for line in text.splitlines() if line.startswith(needle)]
    else:
        lines = [line for line in text.splitlines() if needle in line]
    if len(lines) != 1:
        raise AssertionError(f"expected one line containing {needle!r}, found {len(lines)}")
    return lines[0]


def load_module():
    spec = importlib.util.spec_from_file_location("check_registry", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


FAILURES = []


def expect(name, code, output, want_code, must_contain=(), must_not_contain=()):
    problems = []
    if code != want_code:
        problems.append(f"exit code {code}, wanted {want_code}")
    for needle in must_contain:
        if needle not in output:
            problems.append(f"output lacks {needle!r}")
    for needle in must_not_contain:
        if needle in output:
            problems.append(f"output contains {needle!r}")
    if problems:
        FAILURES.append(name)
        print(f"FAIL {name}: {'; '.join(problems)}")
        print("  " + output.replace("\n", "\n  "))
    elif VERBOSE:
        print(f"ok   {name}")


def doctored_prd_cases(prd, registry):
    """(name, doctored PRD text, strings the failure must name)."""
    hold_access = line_containing(prd, "| `access` |")
    owner_question = line_containing(prd, "| `owner_question` |")
    access_row = hold_access
    task_row = line_containing(prd, "| Task | `task.created`")
    review_row = line_containing(prd, "| Review | `review.started`")
    holds_row = line_containing(prd, "| Holds | `hold.opened`")
    refusals = line_containing(prd, "**Specific refusals.**")
    precedence_old = "`pending`, `on_hold`, `briefing_not_acknowledged`"
    precedence_new = "`on_hold`, `pending`, `briefing_not_acknowledged`"
    return [
        ("a hold reason row removed",
         replace_once(prd, access_row + "\n", ""),
         ["hold reasons", "`access`"]),
        ("an event type added to a row",
         replace_once(prd, task_row, task_row.replace(
             "`task.promoted`,", "`task.promoted`, `task.parked`,")),
         ["event types", "`task.parked`"]),
        ("an event type moved to another group",
         replace_once(
             replace_once(prd, task_row, task_row.replace(" `task.promoted`,", "")),
             review_row, review_row.replace("`review.started`,", "`review.started`, `task.promoted`,")),
         ["event types", "`task.promoted`", "group"]),
        ("a refusal renamed",
         prd.replace("`not_holder`", "`not_the_holder`"),
         ["refusals", "`not_the_holder`", "`not_holder`"]),
        ("two refusals swapped in the precedence sentence",
         replace_once(prd, refusals, replace_once(refusals, precedence_old, precedence_new)),
         ["refusals", "precedence", "`pending`", "`on_hold`"]),
        ("the claims-only sentence lost",
         replace_once(prd, " `not_eligible` applies to claims only.", ""),
         ["refusals", "`not_eligible`", "claims only"]),
        ("the owner-refusal sentence lost",
         replace_once(prd, " `credential_in_use` and `duplicate_name` are owner refusals"
                      " and apply to owner commands only.", ""),
         ["refusals", "`credential_in_use`", "owner"]),
        ("a check result removed",
         replace_once(prd, "`applied` (policy rules, with the effect), `error` or",
                      "`applied` (policy rules, with the effect) or"),
         ["check results", "`error`"]),
        ("a Lease clock cell changed",
         replace_once(prd, owner_question, owner_question.replace("| Pauses |", "| Runs |")),
         ["hold reasons", "`owner_question`", "lease_clock"]),
        ("an In Blocked cell changed",
         replace_once(prd, owner_question, owner_question.replace("| Yes |", "| No |")),
         ["hold reasons", "`owner_question`", "in_blocked"]),
        ("a Step cell changed",
         replace_once(prd, hold_access, hold_access.replace("`wait_owner`", "`wait_seat`")),
         ["hold reasons", "`access`", "step"]),
        ("a Lease clock cell that reads as nothing",
         replace_once(prd, owner_question, owner_question.replace("| Pauses |", "| Sometimes |")),
         ["unparsable cell", "owner_question"]),
        ("the Event types heading renamed",
         replace_once(prd, "### Event types\n", "### Kinds of event\n"),
         ["section missing", "Event types"]),
        ("a stray code span in an event type cell",
         replace_once(prd, holds_row, holds_row.replace(
             "each with a reason", "each with `A Reason`")),
         ["unparsable cell", "Holds", "`A Reason`"]),
        ("the refusals paragraph missing",
         replace_once(prd, "**Specific refusals.**", "**Refusals.**"),
         ["section missing", "Specific refusals"]),
    ]


def main():
    prd = PRD.read_text(encoding="utf-8")
    registry = json.loads(REGISTRY.read_text(encoding="utf-8"))

    code, output = run(prd, registry)
    expect("the real PRD and registry pass", code, output, 0, ["OK"])

    for name, text, needles in doctored_prd_cases(prd, registry):
        code, output = run(text, registry)
        expect(name, code, output, 1, needles)

    extra = copy.deepcopy(registry)
    extra["hold_reasons"].append({
        "reason": "waiting_for_weather", "lease_clock": "pauses",
        "in_blocked": True, "step": "wait_owner", "needs_you_item": None})
    code, output = run(prd, extra)
    expect("a registry with an extra hold reason", code, output, 1,
           ["hold reasons", "`waiting_for_weather`", "registry only"])

    moved = copy.deepcopy(registry)
    for entry in moved["event_types"]:
        if entry["type"] == "task.claimed":
            entry["group"] = "Review"
    code, output = run(prd, moved)
    expect("a registry with an event type in the wrong group", code, output, 1,
           ["event types", "`task.claimed`", "group", "Task", "Review"])

    clock = copy.deepcopy(registry)
    for entry in clock["hold_reasons"]:
        if entry["reason"] == "seat_paused":
            entry["lease_clock"] = "pauses"
    code, output = run(prd, clock)
    expect("a registry with a hold reason's lease clock changed", code, output, 1,
           ["`seat_paused`", "lease_clock"])

    release = copy.deepcopy(registry)
    release["release_reasons"].append({"reason": "gone_fishing", "chosen_by": "seat"})
    code, output = run(prd, release)
    expect("a registry whose release reasons alone change", code, output, 0, ["OK"])

    # The parser itself: parenthesised notes and the Credentials row's
    # trailing sentence are not types.
    module = load_module()
    found = module.event_types_from_prd(prd)
    groups = {value: group for group, value in found.values}
    if found.problems:
        FAILURES.append("parser problems on the real PRD")
        print("FAIL parser problems on the real PRD:", found.problems)
    for value, group in (("task.claimed", "Task"), ("review.started", "Review"),
                         ("job.claimed", "Jobs"), ("action.lease_granted", "Outward actions")):
        if groups.get(value) != group:
            FAILURES.append(f"group of {value}")
            print(f"FAIL {value} read in group {groups.get(value)!r}, wanted {group!r}")
    if "withdrawn" in groups:
        FAILURES.append("withdrawn read as an event type")
        print("FAIL `withdrawn` from a parenthesis was read as an event type")
    if len([value for _, value in found.values]) != len(groups):
        FAILURES.append("an event type read twice")
        print("FAIL an event type was read more than once from the real PRD")

    if FAILURES:
        print(f"{len(FAILURES)} case(s) failed.")
        return 1
    print("All check_registry.py self-test cases passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
