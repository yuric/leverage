#!/usr/bin/env python3
"""Self-test for check_contract_tables.py.

Runs check_contract_tables.py on the real PRD and contract, which must pass,
then on doctored copies written to a temporary folder: a PRD with one table
cell changed, and contract files with one copied value changed. Each copy
must fail and name the table, the row and what differs. Each case is a drift
the check must catch, or a reading it once could have got wrong.

Usage: python3 scripts/test_check_contract_tables.py [-v]
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
SCRIPT = HERE / "check_contract_tables.py"
PRD = ROOT / "docs" / "PRD.md"
CONTRACT = ROOT / "api" / "contract"
FILES = ("state_machine.json", "steps.json", "hooks.json", "needs_you.json",
         "roles.json", "registry.json", "shipped_rules.json")
VERBOSE = "-v" in sys.argv[1:]


def load_contract():
    return {name: json.loads((CONTRACT / name).read_text(encoding="utf-8")) for name in FILES}


def run(prd_text, contract):
    """Run the check on the given PRD text and contract files."""
    with tempfile.TemporaryDirectory() as folder:
        prd_path = Path(folder) / "PRD.md"
        prd_path.write_text(prd_text, encoding="utf-8")
        contract_path = Path(folder) / "contract"
        contract_path.mkdir()
        for name, data in contract.items():
            (contract_path / name).write_text(json.dumps(data), encoding="utf-8")
        result = subprocess.run(
            [sys.executable, "-I", str(SCRIPT),
             "--prd", str(prd_path), "--contract", str(contract_path)],
            capture_output=True, text=True, check=False)
    return result.returncode, result.stdout + result.stderr


def replace_once(text, old, new):
    """Replace exactly one occurrence, so a doctored copy changes what it says."""
    count = text.count(old)
    if count != 1:
        raise AssertionError(f"expected one occurrence of {old!r}, found {count}")
    return text.replace(old, new)


def row(text, start):
    """The one line of the PRD that starts with start."""
    lines = [line for line in text.splitlines() if line.startswith(start)]
    if len(lines) != 1:
        raise AssertionError(f"expected one line starting {start!r}, found {len(lines)}")
    return lines[0]


def change_row(text, start, old, new):
    """The PRD with old replaced by new inside the one row starting with start."""
    line = row(text, start)
    return replace_once(text, line, replace_once(line, old, new))


def drop_row(text, start):
    return replace_once(text, row(text, start) + "\n", "")


def load_module():
    spec = importlib.util.spec_from_file_location("check_contract_tables", SCRIPT)
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


def doctored_prd_cases(prd):
    """(name, doctored PRD text, strings the failure must name)."""
    return [
        # The five cases plan section 1.4a names.
        ("a lifecycle Events cell changed",
         change_row(prd, "| Promote |", "`task.promoted`", "`task.promoted`, `task.parked`"),
         ["lifecycle", "Promote", "Events written", "`task.parked`"]),
        ("a step class changed",
         change_row(prd, "| `idea` |", "| Waiting |", "| Working |"),
         ["step kinds", "`idea`", "class"]),
        ("a hook's failed-gate cell changed",
         change_row(prd, "| `review.assign` |", "The reviewer is refused.", "The reviewer is told to wait."),
         ["hooks", "`review.assign`", "If a gate fails"]),
        ("a Needs you hold reason changed",
         change_row(prd, "| Access request |", "`access`", "`owner_question`"),
         ["Needs you", "Access request", "hold reason", "`owner_question`"]),
        ("an agent path changed",
         change_row(prd, "| `POST /v1/tasks/{id}/heartbeat` |", "/heartbeat", "/pulse"),
         ["agent calls", "POST /v1/tasks/{id}/pulse", "POST /v1/tasks/{id}/heartbeat"]),

        # Lifecycle table.
        ("a lifecycle row removed",
         drop_row(prd, "| Promote |"),
         ["lifecycle", "Promote", "state_machine.json only"]),
        ("a lifecycle row added",
         replace_once(prd, row(prd, "| Promote |"),
                      row(prd, "| Promote |") + "\n| Park | Backlog | Ideas | Owner | None | `task.parked` |"),
         ["lifecycle", "Park", "PRD only"]),
        ("a lifecycle From cell changed",
         change_row(prd, "| Promote |", "| Ideas | Backlog |", "| Ready | Backlog |"),
         ["lifecycle", "Promote", "From", "`ready`", "`ideas`"]),
        ("a lifecycle Hook cell changed",
         change_row(prd, "| Claim | Ready |", "`task.before_claim`", "None"),
         ["lifecycle", "Claim", "Hook", "`task.before_claim`"]),
        ("a side event named in a lifecycle Events cell",
         change_row(prd, "| Submit |", "`task.submitted`", "`task.submitted`, `hold.opened`"),
         ["lifecycle", "Submit", "`hold.opened`"]),
        ("a stray code span in a lifecycle Events cell",
         change_row(prd, "| Promote |", "`task.promoted`", "`task.promoted`, `Promoted`"),
         ["unparsable cell", "Promote", "`Promoted`"]),
        ("a lifecycle Hook cell that names no hook",
         change_row(prd, "| Claim | Ready |", "`task.before_claim`", "The claim hook"),
         ["unparsable cell", "Claim", "Hook"]),
        ("a lifecycle From cell that names no state",
         change_row(prd, "| Promote |", "| Ideas | Backlog |", "| Somewhere | Backlog |"),
         ["unparsable cell", "Promote", "From"]),
        ("the lifecycle table's header changed",
         replace_once(prd, "| Command | From | To | Who may ask | Hook | Events written |",
                      "| Command | From | To | Who | Hook | Events written |"),
         ["section missing", "lifecycle"]),

        # Step kinds table.
        ("a step's subject changed",
         change_row(prd, "| `wait_seat` |", "The seat |", "The seat's owner |"),
         ["step kinds", "`wait_seat`", "Subject"]),
        ("a step's Open while cell changed",
         change_row(prd, "| `idea` |", "The task is in Ideas.", "The task is an idea."),
         ["step kinds", "`idea`", "Open while"]),
        ("a step kind row removed",
         drop_row(prd, "| `wait_limit` |"),
         ["step kinds", "`wait_limit`", "steps.json only"]),
        ("the Step kinds heading renamed",
         replace_once(prd, "### Step kinds\n", "### Kinds of step\n"),
         ["section missing", "Step kinds"]),

        # Hooks tables.
        ("a hook's checkers cell changed",
         change_row(prd, "| `task.before_submit` | The builder", "| App and model |", "| App only |"),
         ["hooks", "`task.before_submit`", "Checkers", "`model`"]),
        ("a hook's moment changed",
         change_row(prd, "| `review.failed` |", "A review fails.", "A review is failed."),
         ["hooks", "`review.failed`", "Moment"]),
        ("a hook's hashed inputs changed",
         change_row(prd, "| `question.asked` | The question |", "The question", "The question and its basis"),
         ["hooks", "`question.asked`", "Inputs that are hashed"]),
        ("a hook row removed",
         drop_row(prd, "| `cost.reported` | A seat"),
         ["hooks", "`cost.reported`", "hooks.json only"]),

        # Needs you choices table.
        ("a Needs you choices cell changed",
         change_row(prd, "| Task budget reached |", "Raise the cap, or cancel.", "Raise the cap."),
         ["Needs you", "Task budget reached", "Choices"]),
        ("a Needs you About cell changed",
         change_row(prd, "| Task budget reached |", "| Task |", "| Project |"),
         ["Needs you", "Task budget reached", "About", "`project`"]),
        ("a Needs you item renamed",
         change_row(prd, "| Access request |", "Access request", "Access wanted"),
         ["Needs you", "Access wanted", "PRD only", "Access request", "needs_you.json only"]),

        # Roles table.
        ("a role's May read cell changed",
         change_row(prd, "| Planner |", "That task and its project's brief", "That task"),
         ["roles", "planner", "May read"]),

        # Agent calls table.
        ("an agent call's seat changed",
         change_row(prd, "| `POST /v1/tasks/{id}/heartbeat` |", "| Holder |", "| Builder |"),
         ["agent calls", "POST /v1/tasks/{id}/heartbeat", "seat", "`builder`", "`holder`"]),
        ("an agent call removed",
         drop_row(prd, "| `POST /v1/tasks/{id}/heartbeat` |"),
         ["agent calls", "POST /v1/tasks/{id}/heartbeat", "registry only"]),
        ("an abbreviated sibling path changed",
         change_row(prd, "| `POST /v1/reviews/{id}/heartbeat`", "`/release`", "`/drop`"),
         ["agent calls", "POST /v1/reviews/{id}/drop", "POST /v1/reviews/{id}/release"]),
        ("an agent Seat cell that names no caller",
         change_row(prd, "| `POST /v1/tasks/{id}/heartbeat` |", "| Holder |", "| Somebody |"),
         ["unparsable cell", "agent calls", "Somebody"]),

        # The lifecycle To and Who may ask cells.
        ("a lifecycle To cell changed",
         change_row(prd, "| Promote |", "| Ideas | Backlog | Owner |", "| Ideas | Ready | Owner |"),
         ["lifecycle", "Promote", "To", "`ready`", "`backlog`"]),
        ("a lifecycle Who may ask cell changed",
         change_row(prd, "| Promote |", "| Backlog | Owner |", "| Backlog | Holder |"),
         ["lifecycle", "Promote", "Who may ask", "`holder`", "`owner`"]),
        ("a lifecycle Who may ask cell that names no caller",
         change_row(prd, "| Promote |", "| Backlog | Owner |", "| Backlog | Somebody |"),
         ["unparsable cell", "Promote", "Who may ask"]),

        # GET /v1/next precedence.
        ("two next kinds swapped",
         replace_once(prd, row(prd, "| `action` | An approved") + "\n" + row(prd, "| `rework` | A review failed") + "\n",
                      row(prd, "| `rework` | A review failed") + "\n" + row(prd, "| `action` | An approved") + "\n"),
         ["next kinds", "order", "`rework`", "`action`"]),
        ("a next kind removed",
         drop_row(prd, "| `resume` | A hold on"),
         ["next kinds", "`resume`", "registry.json only"]),
        ("the next kinds table's header changed",
         replace_once(prd, "| Kind | True when | Id | Cleared when |", "| Kind | When | Id | Cleared when |"),
         ["section missing", "next kinds"]),

        # Shipped rules.
        ("a shipped rule's hook changed",
         change_row(prd, "| Every task needs specific details |", "`task.before_ready`", "`task.before_claim`"),
         ["shipped rules", "Every task needs specific details", "Hook", "`task.before_claim`"]),
        ("a shipped rule's kind changed",
         change_row(prd, "| Projects pause when", "| Policy |", "| Gate |"),
         ["shipped rules", "Projects pause when they reach their budget", "Kind", "`gate`"]),
        ("a shipped rule's checker changed",
         change_row(prd, "| Every task needs specific details |", "Model, the orchestrator", "App"),
         ["shipped rules", "Every task needs specific details", "Checker"]),
        ("a shipped rule's When it is off cell changed",
         change_row(prd, "| Every task needs specific details |", "No detail check.", "No check."),
         ["shipped rules", "Every task needs specific details", "When it is off"]),
        ("a shipped rule removed",
         drop_row(prd, "| Repeated failed reviews move"),
         ["shipped rules", "Repeated failed reviews move a task to a stronger model", "shipped_rules.json only"]),
        ("two shipped rules swapped",
         replace_once(prd, row(prd, "| Every task needs acceptance criteria |") + "\n" + row(prd, "| Every task needs specific details |") + "\n",
                      row(prd, "| Every task needs specific details |") + "\n" + row(prd, "| Every task needs acceptance criteria |") + "\n"),
         ["shipped rules", "order"]),

        # App round 2: the agent's Add task and its Who cells.
        ("the creator call's seat changed",
         change_row(prd, "| `POST /v1/tasks` |", "| Creator |", "| Builder |"),
         ["agent calls", "POST /v1/tasks", "seat differs"]),
        ("the creator dropped from Add task",
         change_row(prd, "| Add task |", "Owner or creator seat", "Owner"),
         ["lifecycle", "Add task", "creator"]),

        # Commands a hold blocks.
        ("a command dropped from the list a hold blocks",
         replace_once(prd, "claim, pass, submit, verdict, start action and report action done.",
                      "claim, pass, submit, verdict and start action."),
         ["blocked by a hold", "`report_action_done`"]),
    ]


def group(contract, group_id):
    return next(g for g in contract["state_machine.json"]["groups"] if g["id"] == group_id)


def entry(items, key, value):
    return next(item for item in items if item[key] == value)


def doctored_contract_cases(contract):
    """(name, doctored contract, strings the failure must name)."""
    cases = []

    def case(name, change, needles):
        doctored = copy.deepcopy(contract)
        change(doctored)
        cases.append((name, doctored, needles))

    def drop_conditional(c):
        for r in group(c, "return_for_rework")["rows"]:
            r["conditional_events"] = [e for e in r["conditional_events"] if e["event"] != "hold.closed"]
    case("a conditional event dropped from a lifecycle group", drop_conditional,
         ["lifecycle", "Return for rework", "`hold.closed`"])

    def drop_event(c):
        for r in group(c, "fail_review")["rows"]:
            r["events"] = [e for e in r["events"] if e != "task.reassigned"]
    case("an event dropped from a lifecycle group", drop_event,
         ["lifecycle", "Review fails", "`task.reassigned`"])

    def to_side_event(c):
        for r in group(c, "fail_review")["rows"]:
            if "task.reassigned" in r["events"]:
                r["events"].remove("task.reassigned")
                r["side_events"].append({"event": "task.reassigned", "when": None, "note": "moved"})
    case("an Events cell event moved to side_events", to_side_event,
         ["lifecycle", "Review fails", "`task.reassigned`"])

    def extra_event(c):
        group(c, "promote")["rows"][0]["events"].append("task.returned")
    case("an event added to a lifecycle group", extra_event,
         ["lifecycle", "Promote", "`task.returned`"])

    def cell_copied_wrong(c):
        group(c, "claim")["prd_cells"][3] = "Builder"
    case("a prd_cells copy that differs", cell_copied_wrong,
         ["lifecycle", "Claim", "Who may ask", "Builder seat"])

    def group_removed(c):
        c["state_machine.json"]["groups"] = [g for g in c["state_machine.json"]["groups"] if g["id"] != "cancel"]
    case("a lifecycle group removed", group_removed, ["lifecycle", "Cancel", "PRD only"])

    def row_hook(c):
        group(c, "submit")["rows"][0]["hook"] = None
    case("a row's hook that differs from the Hook cell", row_hook,
         ["lifecycle", "Submit", "Hook", "`task.before_submit`"])

    def row_from(c):
        group(c, "edit_contract_active")["rows"][0]["from"] = "finishing"
    case("a row's from-state not in the From cell", row_from,
         ["lifecycle", "Edit contract", "From", "`finishing`"])

    def step_class(c):
        entry(c["steps.json"]["steps"], "kind", "check")["class"] = "working"
    case("a step's class changed in steps.json", step_class,
         ["step kinds", "`check`", "class", "`rule_check`", "`working`"])

    def step_subject(c):
        entry(c["steps.json"]["steps"], "kind", "idea")["subject_kinds"] = ["task"]
    case("a step with no subject given a subject kind", step_subject,
         ["step kinds", "`idea`", "Subject", "None"])

    def hook_checkers(c):
        entry(c["hooks.json"]["hooks"], "hook", "task.before_ready")["checkers"] = ["app"]
    case("a hook's checkers changed in hooks.json", hook_checkers,
         ["hooks", "`task.before_ready`", "Checkers", "`model`"])

    def policy_gate(c):
        entry(c["hooks.json"]["hooks"], "hook", "review.assign")["failed_gate"] = "refuse"
    case("a policy hook given a failed-gate effect", policy_gate,
         ["hooks", "`review.assign`", "policy", "failed_gate"])

    def gate_effect_lost(c):
        entry(c["hooks.json"]["hooks"], "hook", "task.before_submit")["failed_gate"] = None
    case("a gate hook with no failed-gate effect", gate_effect_lost,
         ["hooks", "`task.before_submit`", "failed_gate"])

    def needs_you_reason(c):
        entry(c["needs_you.json"]["items"], "prd_item", "Task budget reached")["hold_reason"] = "project_paused"
    case("a Needs you hold reason changed in needs_you.json", needs_you_reason,
         ["Needs you", "Task budget reached", "hold reason", "`budget`", "`project_paused`"])

    def operation_path(c):
        entry(c["registry.json"]["operations"], "operation_id", "submit_task")["path"] = "/v1/tasks/{id}/send"
    case("an agent operation's path changed in the registry", operation_path,
         ["agent calls", "POST /v1/tasks/{id}/submit", "POST /v1/tasks/{id}/send"])

    def operation_caller(c):
        entry(c["registry.json"]["operations"], "operation_id", "claim_next_job")["caller"] = "any"
    case("an agent operation's caller changed in the registry", operation_caller,
         ["agent calls", "POST /v1/jobs/claim-next", "`job_claimer`", "`any`"])

    def row_to(c):
        for r in group(c, "fail_review")["rows"]:
            r["to"] = "done"
    case("a row's to-state not in the To cell", row_to,
         ["lifecycle", "Review fails", "To", "`done`"])

    def claim_to(c):
        group(c, "claim")["rows"][0]["to"] = "in_review"
    case("a row's to-state where the To cell names another", claim_to,
         ["lifecycle", "Claim", "To", "`in_review`", "`working`"])

    def unchanged_moves(c):
        group(c, "acknowledge_briefing")["rows"][0]["to"] = "done"
    case("a row that moves where the To cell says Unchanged", unchanged_moves,
         ["lifecycle", "Acknowledge briefing", "Unchanged", "`working`", "`done`"])

    def row_who(c):
        for r in group(c, "fail_review")["rows"]:
            r["who"] = ["owner"]
    case("a row's caller not in the Who may ask cell", row_who,
         ["lifecycle", "Review fails", "Who may ask", "`owner`", "`reviewer`"])

    def who_dropped(c):
        group(c, "release_review")["rows"] = [r for r in group(c, "release_review")["rows"] if r["who"] != ["app"]]
    case("a caller of the Who may ask cell that no row has", who_dropped,
         ["lifecycle", "Release review", "Who may ask", "`app`"])

    def choice_dropped(c):
        item = entry(c["needs_you.json"]["items"], "prd_item", "Stopped action")
        item["choices"] = [ch for ch in item["choices"] if ch["choice"] != "cancel"]
    case("a Needs you choice dropped from the structured list", choice_dropped,
         ["Needs you", "Stopped action", "choices", "`cancel_task`"])

    def choice_operation(c):
        item = entry(c["needs_you.json"]["items"], "prd_item", "Task budget reached")
        entry(item["choices"], "choice", "raise_cap")["operation_id"] = "change_budget"
    case("a Needs you choice that runs another operation", choice_operation,
         ["Needs you", "Task budget reached", "choices", "`change_task_cap`", "`change_budget`"])

    def next_kinds(c):
        kinds = c["registry.json"]["next_kinds"]
        kinds[0], kinds[1] = kinds[1], kinds[0]
    case("two next kinds swapped in the registry", next_kinds, ["next kinds", "order", "`briefing_changed`"])

    def shipped_hook(c):
        entry(c["shipped_rules.json"]["rules"], "key", "different_provider_review")["hook"] = "review.failed"
    case("a shipped rule's hook changed in shipped_rules.json", shipped_hook,
         ["shipped rules", "A different provider reviews every task", "Hook", "`review.failed`"])

    def shipped_checker(c):
        entry(c["shipped_rules.json"]["rules"], "key", "different_provider_review")["checker"] = "model"
    case("a shipped rule's checker changed in shipped_rules.json", shipped_checker,
         ["shipped rules", "A different provider reviews every task", "Checker", "`model`"])

    def blocked_review(c):
        entry(c["state_machine.json"]["commands"], "command", "claim_review")["blocked_by_hold"] = False
    case("a review claim that a hold does not block", blocked_review, ["blocked by a hold", "`claim_review`"])

    def blocked_extra(c):
        entry(c["state_machine.json"]["commands"], "command", "heartbeat")["blocked_by_hold"] = True
    case("a heartbeat that a hold blocks", blocked_extra, ["blocked by a hold", "`heartbeat`"])

    def job_claim_unexplained(c):
        entry(c["state_machine.json"]["commands"], "command", "claim_job").pop("note", None)
    case("a job claim left unblocked with no note", job_claim_unexplained, ["blocked by a hold", "`claim_job`", "L378"])

    def role_cell(c):
        entry(c["roles.json"]["roles"], "role", "builder")["prd_may_change"] = "Any task"
    case("a role's May change copy that differs", role_cell, ["roles", "builder", "May change"])

    return cases


def parser_cases(module, prd):
    """Readings of the real PRD that the check once could have got wrong."""
    calls = module.agent_calls_from_prd(prd)
    seen = {(method, path) for method, path, _ in calls.values}
    for wanted in (("POST", "/v1/reviews/{id}/release"), ("GET", "/v1/next")):
        if wanted not in seen:
            FAILURES.append(f"agent call {wanted}")
            print(f"FAIL the agent calls table did not yield {wanted[0]} {wanted[1]}")
    if any("?" in path for _, path in seen):
        FAILURES.append("query string kept")
        print("FAIL a query string was kept in an agent call path")
    if calls.problems:
        FAILURES.append("agent calls problems")
        print("FAIL problems reading the real agent calls table:", calls.problems)

    lifecycle = module.lifecycle_from_prd(prd)
    if lifecycle.problems:
        FAILURES.append("lifecycle problems")
        print("FAIL problems reading the real lifecycle table:", lifecycle.problems)
    review_briefing = next((r for r in lifecycle.values if r[0] == "Acknowledge review briefing"), None)
    if review_briefing is None or module.event_spans(review_briefing[5])[0] != ["task.briefing_acknowledged"]:
        FAILURES.append("parenthesised note")
        print("FAIL the review briefing row's Events cell was not read as one event type")

    # App round 2 (UX-11, UX-13, UX-16): a seat whose permissions include
    # Create tasks, the creator, adds a task and completes its contract in
    # the same call, and the owner hears of a failed check.
    if module.SEAT_CALLERS.get("Creator") != "creator":
        FAILURES.append("Creator seat cell")
        print("FAIL the Seat cell \"Creator\" was not read as the creator caller")
    if module.who_roles("Owner or creator seat") != {"owner", "creator"}:
        FAILURES.append("creator in Who may ask")
        print("FAIL \"Owner or creator seat\" was not read as owner and creator")
    if module.who_roles("Owner, planner seat, or creator seat in the call that adds the task") != {
            "owner", "planner", "creator"}:
        FAILURES.append("creator qualifier")
        print("FAIL the qualifier \"in the call that adds the task\" was not dropped")
    offered = module.choice_operations("Complete the contract, ask a planner to draft it, or cancel.")
    if offered != ["cancel_task", "complete_contract", "draft_contract"]:
        FAILURES.append("contract choices")
        print(f"FAIL the agent task item's choices were read as {offered}")
    for call in (("POST", "/v1/tasks", "creator"), ("POST", "/v1/seat/model", "any")):
        if call not in calls.values:
            FAILURES.append(f"agent call {call}")
            print(f"FAIL the agent calls table did not yield {call}")

    if module.checkers_from_cell("App and model. A model check makes the claim provisional") != (["app", "model"], False):
        FAILURES.append("checkers with a trailing sentence")
        print("FAIL a Checkers cell's trailing sentence was read as checkers")
    if module.checkers_from_cell("App only, policy") != (["app"], True):
        FAILURES.append("policy checkers")
        print("FAIL 'App only, policy' was not read as app, policy")


def main():
    prd = PRD.read_text(encoding="utf-8")
    contract = load_contract()

    code, output = run(prd, contract)
    expect("the real PRD and contract pass", code, output, 0, ["OK"])

    for name, text, needles in doctored_prd_cases(prd):
        code, output = run(text, contract)
        expect(name, code, output, 1, needles)

    for name, doctored, needles in doctored_contract_cases(contract):
        code, output = run(prd, doctored)
        expect(name, code, output, 1, needles)

    side = copy.deepcopy(contract)
    group(side, "submit")["rows"][0]["side_events"].append(
        {"event": "hold.opened", "when": None, "note": "a side event"})
    code, output = run(prd, side)
    expect("a side event the Events cell does not name", code, output, 0, ["OK"])

    missing = copy.deepcopy(contract)
    del missing["steps.json"]
    code, output = run(prd, missing)
    expect("a contract file missing", code, output, 1, ["ERROR", "steps.json"])

    parser_cases(load_module(), prd)

    if FAILURES:
        print(f"{len(FAILURES)} case(s) failed.")
        return 1
    print("All check_contract_tables.py self-test cases passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
