"""Stand-in for the four providers' tools, and for the runner program.

Tests never run a real provider's tool. `bin/claude`, `bin/codex`, `bin/agy`
and `bin/grok` start this file under their own name; `stand_in_runner.sh`
starts it as `runner`. A test copies the whole StandIns folder to a
temporary folder of its own, points LEVERAGE_TOOL_DIR at the copy's `bin/`,
and talks to the stand-in only through files beside it, in `state/`:

  state/scenario.json        written by the test (below)
  state/calls.jsonl          one line per run: tool, argv, cwd, env
  state/app-server.jsonl     one line per message received by Codex
  state/counters.json        how many review prompts have been answered,
                             and each account's work prompts
  state/signed-in-<tool>     the sign-in of a tool with one sign-in for the
                             Mac (agy, grok) or with no account folder set
  <account folder>/.standin-signed-in
                             the sign-in of one account (CLAUDE_CONFIG_DIR,
                             CODEX_HOME)
  state/runner/<pid>.json    what the stand-in runner was started with

Nothing reaches the stand-in through the environment except what the real
tool reads there too (its account folder variable).

The answers have the shapes the real tools gave on this Mac (plan PV-2 and
PV-3), with made-up values. The status output carries a made-up email and
organisation (STATUS_EMAIL, STATUS_ORG), which the end-to-end secret scan
looks for everywhere.

Prompts. A prompt that contains "LEVERAGE-CRITERION" is a review: it answers
"LEVERAGE-CRITERION <n>: PASS" or "FAIL" for every "criterion <n>" the
prompt names, then "LEVERAGE-NOTES: ...". A prompt that contains
"LEVERAGE-EVIDENCE" is a build of the first "criterion <n>" it names: it
writes criterion-<n>.txt in its working folder and answers
"LEVERAGE-EVIDENCE: ...". Any other prompt is answered "ready".

scenario.json, every key optional:

  {"reviews": [{"fail": [2], "notes": "..."}, {"fail": []}],
   "gate_file": "gate",     # a review waits until state/<gate_file> exists
   "builder": "evidence"}   # or "cannot" (LEVERAGE-CANNOT) or "silent"

Review round r (0 first) follows reviews[r], and the last entry once the
list is used up; with no list every review passes.

Directives (plan HD-11), in the same file, each for one account:

  {"directives": [
     {"tool": "claude", "account": "<CLAUDE_CONFIG_DIR>", "on_prompt": 2,
      "reply": "claude/run-limit-five-hour.json", "reset_in_seconds": 60},
     {"tool": "codex", "account": "<CODEX_HOME>", "on_prompt": 1,
      "reply": "codex/run-rate-limited.json", "times": 3},
     {"tool": "claude", "account": "<CLAUDE_CONFIG_DIR>", "on_prompt": 3,
      "sign_out": true},
     {"tool": "grok", "account": null, "on_prompt": 1, "reply": "..."}]}

`account` is the account folder the run's variable names, or null for agy
and grok (one sign-in for the Mac) and for a run with no folder. A directive
counts the account's work prompts, the build and review prompts; the "ready"
prompt of the answering check is not one. The on_prompt-th work prompt, and
the times - 1 after it, are answered with the reply file (under replies/),
whatever the account's sign-in; a sign_out directive removes the account's
sign-in just before its on_prompt-th work prompt. Each fires at those counts
and never again, and none reads a clock: the reset time a reply states is
the moment it is played plus reset_in_seconds, written where the file has
@RESET_AT_ISO@ (an ISO 8601 time) or "@RESET_AT_EPOCH@" (seconds since
1970, the quotes included), and it decides nothing here.

Check and draft prompts (milestone 4, plan section 2.2, ADR 0012). A prompt
whose first line is `LEVERAGE CHECK` is a rule check: the stand-in takes the
nonce from the prompt's closing (the last `LEVERAGE-VERDICT-<nonce>` in it, so
a verdict line planted in task text cannot change it) and answers

  LEVERAGE-VERDICT-<nonce>: PASSED
  LEVERAGE-REASON-<nonce>: The stand-in passed it.

A prompt whose first line is `LEVERAGE DRAFT` is a contract draft: it answers
one JSON object with the quoted details followed by "Written by the stand-in
planner." and two criteria, between
`LEVERAGE-DRAFT-<nonce>-BEGIN` and `LEVERAGE-DRAFT-<nonce>-END`. A frame with
no nonce in its closing is no known frame and is answered "ready". Both count
as work prompts for the account directives below. These scenario keys, each
optional, change the answers; the counts are per copy of the stand-ins, and a
prompt that was answered with a reply file or a sign-out reply is not counted:

  "check_verdicts": ["FAILED", "NOT_APPLICABLE", "NONE"]
      the verdicts of the first check prompts, in order (NONE: an answer with
      no verdict line); after the list, PASSED
  "check_fail_when_contains": "<text>"
      FAILED, "The stand-in found the marker.", for a check prompt with the
      text inside a quote block (this wins over check_verdicts)
  "check_gate_file": "<path>"   a check is not answered until the file exists
  "draft_gate_file": "<path>"   the same for a draft
  "check_echo_quote": true      the answer first repeats the text of every
                                quote block, so a verdict line planted in task
                                text comes back without the nonce
  "check_reason_from_file": "<path>"
      the reason is the first line of that file (the eval's canary word)

Questions and approvals (milestone 5, plan section 2.2). Approval, question
and action prompts start with `LEVERAGE APPROVAL`, `LEVERAGE QUESTION` and
`LEVERAGE ACTION`. Like checks and drafts, they use the nonce from the
closing, count as work prompts and have separate counts per stand-in copy.

  "approval_decisions": ["STOP", "ASK_OWNER", "NONE"]  # then APPROVE
  "approval_stop_when_contains": "<text>"  # overrides the listed decision
      only when the text is in the `action` quote block
  "approval_gate_file": "<path>"
  "question_answers": ["RECORD:<text>", "DECISION:<text>", "PASS_ON", "NONE"]
      after the list, answer with the assumption and basis RECORD
  "action_results": ["CANNOT", "NONE", "PLANTED", "DONE"]  # then DONE
      PLANTED gives a wrong nonce and a correctly nonced line in a quote
  "action_gate_file": "<path>"
  "action_touch_file": "<path>"  # one line per answer, with the answer count
  "review_gate_file": "<path>"   # takes precedence over the older gate_file

Relative gate and touch paths are read in state/.

Signed out, every tool answers with its recorded or made reply file:
replies/<provider>/status-signed-out.json for a status command and
replies/<provider>/run-signed-out.json for a prompt.

Standard library only.
"""

import fcntl
import json
import os
import re
import runpy
import signal
import subprocess
import sys
import time

STATUS_EMAIL = "standin.owner@example.invalid"
STATUS_ORG = "Stand-in Example Org"
VERSIONS = {
    "claude": "0.0.1 (Claude Code stand-in)",
    "codex": "codex-cli 0.0.1-standin",
    "agy": "0.0.1-standin",
    "grok": "grok 0.0.1 (standin) [stable]",
}
ACCOUNT_VARIABLES = {"claude": "CLAUDE_CONFIG_DIR", "codex": "CODEX_HOME"}
SIGN_IN_SECONDS = 1.0
MARK = ".standin-signed-in"

ROOT = os.path.dirname(os.path.abspath(__file__))
STATE = os.path.join(ROOT, "state")
REPLIES = os.path.join(ROOT, "replies")
# The folder of replies/ each tool's files are in: the provider's id.
PROVIDER_FOLDERS = {"claude": "claude", "codex": "codex", "agy": "gemini", "grok": "grok"}


# --- State beside the stand-in ------------------------------------------------


def state_path(*parts):
    os.makedirs(STATE, exist_ok=True)
    return os.path.join(STATE, *parts)


class Locked:
    """An exclusive lock on state/lock, for the files several runs share."""

    def __enter__(self):
        self.handle = open(state_path("lock"), "a")
        fcntl.flock(self.handle, fcntl.LOCK_EX)
        return self

    def __exit__(self, *exc):
        fcntl.flock(self.handle, fcntl.LOCK_UN)
        self.handle.close()


def record_json(name, value):
    line = json.dumps(value)
    with Locked():
        with open(state_path(name), "a", encoding="utf-8") as out:
            out.write(line + "\n")


def record_call(tool, argv):
    record_json("calls.jsonl", {"tool": tool, "argv": argv, "cwd": os.getcwd(), "env": dict(os.environ)})


def scenario():
    try:
        with open(state_path("scenario.json")) as handle:
            return json.load(handle)
    except FileNotFoundError:
        return {}


def bump_counter(update):
    """Reads counters.json, lets `update` change it and return a value, and
    writes it back, under the lock."""
    with Locked():
        path = state_path("counters.json")
        try:
            with open(path) as handle:
                counters = json.load(handle)
        except FileNotFoundError:
            counters = {}
        value = update(counters)
        with open(path, "w") as handle:
            json.dump(counters, handle)
    return value


def next_review_round():
    def update(counters):
        round_number = counters.get("reviews", 0)
        counters["reviews"] = round_number + 1
        return round_number
    return bump_counter(update)


# --- Sign-in ------------------------------------------------------------------


def mark_file(tool):
    variable = ACCOUNT_VARIABLES.get(tool)
    folder = os.environ.get(variable) if variable else None
    if folder:
        return os.path.join(folder, MARK)
    return state_path(f"signed-in-{tool}")


def signed_in(tool):
    return os.path.exists(mark_file(tool))


def sign_out(tool):
    try:
        os.remove(mark_file(tool))
    except FileNotFoundError:
        pass


def sign_in(tool):
    """Plays the owner signing in in the provider's window: one second."""
    time.sleep(SIGN_IN_SECONDS)
    path = mark_file(tool)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as handle:
        handle.write("signed in\n")


# --- Reply files and directives --------------------------------------------


def play(tool, name, reset_in_seconds=None):
    """Answers with replies/<provider>/<name>: its standard output, its
    standard error and its exit status, with the reset time filled in."""
    return play_file(f"{PROVIDER_FOLDERS[tool]}/{name}", reset_in_seconds)


def play_file(relative, reset_in_seconds=None):
    with open(os.path.join(REPLIES, relative), encoding="utf-8") as handle:
        reply = json.load(handle)
    stdout, stderr = reply["stdout"], reply["stderr"]
    if "@RESET_AT_" in stdout + stderr:
        if reset_in_seconds is None:
            print(f"stand-in: {relative} states a reset time; its directive needs reset_in_seconds",
                  file=sys.stderr)
            return 2
        reset = int(time.time()) + int(reset_in_seconds)
        iso = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(reset))
        stdout, stderr = (text.replace("@RESET_AT_ISO@", iso).replace('"@RESET_AT_EPOCH@"', str(reset))
                          for text in (stdout, stderr))
    sys.stdout.write(stdout)
    sys.stdout.flush()
    sys.stderr.write(stderr)
    sys.stderr.flush()
    return reply["exit_status"]


def account_of(tool):
    """The account folder a run of `tool` is for, or None (one sign-in for
    the Mac, or no folder set)."""
    variable = ACCOUNT_VARIABLES.get(tool)
    folder = os.environ.get(variable) if variable else None
    return os.path.realpath(folder) if folder else None


def same_account(directive_account, account):
    if not directive_account:
        return account is None
    return account is not None and os.path.realpath(directive_account) == account


def is_work_prompt(prompt):
    return (frame_of(prompt) is not None or "LEVERAGE-EVIDENCE" in prompt
            or "LEVERAGE-CRITERION" in prompt)


def directive_for(tool, prompt):
    """Counts a work prompt of the run's account and applies the directives
    for that count: a sign-out is done here, and the reply directive that
    answers this prompt, if any, is returned. Any other prompt counts for
    nothing and has no directive."""
    if not is_work_prompt(prompt):
        return None
    account = account_of(tool)
    key = f"{tool}|{account or ''}"

    def update(counters):
        prompts = counters.setdefault("prompts", {})
        prompts[key] = prompts.get(key, 0) + 1
        return prompts[key]
    count = bump_counter(update)
    answer = None
    for directive in scenario().get("directives") or []:
        if directive.get("tool") != tool or not same_account(directive.get("account"), account):
            continue
        first = int(directive["on_prompt"])
        if directive.get("sign_out"):
            if count == first:
                sign_out(tool)
        elif first <= count < first + int(directive.get("times") or 1) and answer is None:
            answer = directive
    return answer


def play_directive(directive):
    return play_file(directive["reply"], directive.get("reset_in_seconds"))


# --- Prompts ------------------------------------------------------------------

CRITERION = re.compile(r"criterion\s+(\d+)", re.IGNORECASE)


GATE_LIMIT_SECONDS = 600


def wait_for_gate(gate_path):
    """Waits until the gate file exists. A review that nobody opens must not
    outlive its caller: the stand-in is in a process group of its own, so a
    caller that is killed (a test run stopped half way) cannot end it, and it
    ends itself when its parent is gone or after GATE_LIMIT_SECONDS."""
    parent = os.getppid()
    deadline = time.monotonic() + GATE_LIMIT_SECONDS
    while not os.path.exists(gate_path):
        if parent == 1 or os.getppid() != parent or time.monotonic() > deadline:
            sys.exit(1)
        time.sleep(0.1)


# --- The nonce-framed prompts (plan section 2.2) -----------------------------

FRAME_NONCES = {
    "LEVERAGE CHECK": re.compile(r"LEVERAGE-VERDICT-([0-9a-f]{12})"),
    "LEVERAGE DRAFT": re.compile(r"LEVERAGE-DRAFT-([0-9a-f]{12})-BEGIN"),
    "LEVERAGE APPROVAL": re.compile(r"LEVERAGE-DECISION-([0-9a-f]{12}):"),
    "LEVERAGE QUESTION": re.compile(r"LEVERAGE-ANSWER-([0-9a-f]{12})-BEGIN"),
    "LEVERAGE ACTION": re.compile(r"LEVERAGE-DONE-([0-9a-f]{12}):"),
}
VERDICTS = ("PASSED", "FAILED", "NOT_APPLICABLE", "NONE")
REASONS = {
    "PASSED": "The stand-in passed it.",
    "FAILED": "The stand-in failed it.",
    "NOT_APPLICABLE": "The stand-in found it not applicable.",
}
APPROVAL_REASONS = {
    "APPROVE": "The stand-in approved it.",
    "STOP": "The stand-in stopped it.",
    "ASK_OWNER": "The stand-in asked the owner.",
}
MARKER_REASON = "The stand-in found the marker."
DRAFT_DETAILS = "Written by the stand-in planner."
DRAFT_CRITERIA = ["The requested page exists.", "The page includes the requested information."]


def frame_of(prompt):
    """(kind, nonce) when the first line names a frame and the closing carries
    the run's nonce. Task text comes before the closing."""
    first = prompt.split("\n", 1)[0].strip()
    pattern = FRAME_NONCES.get(first)
    if pattern is None:
        return None
    found = pattern.findall(prompt)
    return (first.split()[1].lower(), found[-1]) if found else None


def quote_blocks(prompt, nonce):
    """[(label, text)] of the quote blocks that carry this run's nonce, in
    order. A block with another nonce is task text and is not one."""
    pattern = re.compile(
        r"<<<LEVERAGE-QUOTE-" + nonce + r" ([^>\n]*)>>>[ \t]*\n?(.*?)\n?<<<LEVERAGE-END-" + nonce + ">>>",
        re.DOTALL)
    return [(label.strip(), text) for label, text in pattern.findall(prompt)]


def scenario_path(name):
    return name if os.path.isabs(name) else state_path(name)


def next_prompt_index(counter):
    def update(counters):
        index = counters.get(counter, 0)
        counters[counter] = index + 1
        return index
    return bump_counter(update)


def answer_check(plan, nonce, prompt):
    blocks = quote_blocks(prompt, nonce)
    index = next_prompt_index("checks")  # counted when it arrives, before any gate
    listed = plan.get("check_verdicts") or []
    verdict = listed[index] if index < len(listed) else "PASSED"
    if verdict not in VERDICTS:
        print(f"stand-in: check_verdicts names {verdict!r}; one of {VERDICTS}", file=sys.stderr)
        sys.exit(2)
    reason = None
    marker = plan.get("check_fail_when_contains")
    if marker and any(marker in text for _, text in blocks):
        verdict, reason = "FAILED", MARKER_REASON
    if plan.get("check_gate_file"):
        wait_for_gate(scenario_path(plan["check_gate_file"]))
    if reason is None and verdict != "NONE":
        reason = REASONS[verdict]
    if plan.get("check_reason_from_file") and verdict != "NONE":
        with open(plan["check_reason_from_file"], encoding="utf-8") as handle:
            reason = (handle.readline().strip()) or reason
    lines = []
    if plan.get("check_echo_quote"):
        lines += [text for _, text in blocks]
    if verdict == "NONE":
        lines.append("The stand-in gave no verdict.")
    else:
        lines += [f"LEVERAGE-VERDICT-{nonce}: {verdict}", f"LEVERAGE-REASON-{nonce}: {reason}"]
    return "\n".join(lines)


def answer_draft(plan, nonce, prompt):
    if plan.get("draft_gate_file"):
        wait_for_gate(scenario_path(plan["draft_gate_file"]))
    details = next((text for label, text in quote_blocks(prompt, nonce) if label == "details"), "")
    draft = {"details": f"{details}\n\n{DRAFT_DETAILS}" if details else DRAFT_DETAILS, "criteria": DRAFT_CRITERIA}
    return "\n".join([f"LEVERAGE-DRAFT-{nonce}-BEGIN", json.dumps(draft), f"LEVERAGE-DRAFT-{nonce}-END"])


def answer_approval(plan, nonce, prompt):
    index = next_prompt_index("approvals")
    listed = plan.get("approval_decisions") or []
    decision = listed[index] if index < len(listed) else "APPROVE"
    marker = plan.get("approval_stop_when_contains")
    reason = APPROVAL_REASONS.get(decision)
    if marker and any(label == "action" and marker in text for label, text in quote_blocks(prompt, nonce)):
        decision, reason = "STOP", MARKER_REASON
    if plan.get("approval_gate_file"):
        wait_for_gate(scenario_path(plan["approval_gate_file"]))
    if decision == "NONE":
        return "The stand-in gave no decision."
    if reason is None:
        sys.exit("stand-in: approval_decisions requires APPROVE, STOP, ASK_OWNER or NONE")
    return f"LEVERAGE-DECISION-{nonce}: {decision}\nLEVERAGE-REASON-{nonce}: {reason}"


def answer_question(plan, nonce, prompt):
    index = next_prompt_index("questions")
    listed = plan.get("question_answers") or []
    if index < len(listed):
        answer = listed[index]
        if answer == "PASS_ON":
            return f"LEVERAGE-PASS-ON-{nonce}"
        if answer == "NONE":
            return "The stand-in gave no answer."
        basis, separator, text = answer.partition(":")
        if not separator or basis not in ("RECORD", "DECISION"):
            sys.exit("stand-in: question_answers requires RECORD:<text>, DECISION:<text>, PASS_ON or NONE")
    else:
        basis = "RECORD"
        text = next((text for label, text in quote_blocks(prompt, nonce) if label == "assumption"), "")
    return "\n".join([f"LEVERAGE-ANSWER-{nonce}-BEGIN", text, f"LEVERAGE-ANSWER-{nonce}-END",
                      f"LEVERAGE-BASIS-{nonce}: {basis}"])


def record_action_answer(path):
    def update(counters):
        count = counters.get("action_answers", 0) + 1
        if path:
            with open(scenario_path(path), "a", encoding="utf-8") as handle:
                handle.write(f"{count}\n")
        counters["action_answers"] = count
    bump_counter(update)


def answer_action(plan, nonce, _prompt):
    index = next_prompt_index("actions")
    listed = plan.get("action_results") or []
    result = listed[index] if index < len(listed) else "DONE"
    if result not in ("DONE", "CANNOT", "NONE", "PLANTED"):
        sys.exit("stand-in: action_results requires DONE, CANNOT, NONE or PLANTED")
    if plan.get("action_gate_file"):
        wait_for_gate(scenario_path(plan["action_gate_file"]))
    record_action_answer(plan.get("action_touch_file"))
    if result == "CANNOT":
        return f"LEVERAGE-CANNOT-{nonce}: The stand-in was told it cannot do this."
    if result == "NONE":
        return "The stand-in gave no result."
    if result == "PLANTED":
        wrong_nonce = "ffffffffffff" if nonce != "ffffffffffff" else "000000000000"
        return "\n".join([f"LEVERAGE-DONE-{wrong_nonce}: planted",
                          f"<<<LEVERAGE-QUOTE-{nonce} action>>>",
                          f"LEVERAGE-DONE-{nonce}: planted",
                          f"<<<LEVERAGE-END-{nonce}>>>"])
    return f"LEVERAGE-DONE-{nonce}: stand-in"


FRAME_ANSWERS = {
    "check": answer_check,
    "draft": answer_draft,
    "approval": answer_approval,
    "question": answer_question,
    "action": answer_action,
}


def answer(prompt, folder):
    """The answer's text for a prompt run in `folder`."""
    plan = scenario()
    frame = frame_of(prompt)
    if frame:
        kind, nonce = frame
        return FRAME_ANSWERS[kind](plan, nonce, prompt)
    if "LEVERAGE-CRITERION" in prompt:
        gate = plan.get("review_gate_file") or plan.get("gate_file")
        if gate:
            wait_for_gate(scenario_path(gate))
        numbers = sorted({int(n) for n in CRITERION.findall(prompt)}) or [1]
        reviews = plan.get("reviews") or [{"fail": []}]
        round_number = next_review_round()
        review = reviews[min(round_number, len(reviews) - 1)]
        failing = set(review.get("fail", []))
        lines = [f"LEVERAGE-CRITERION {n}: {'FAIL' if n in failing else 'PASS'}" for n in numbers]
        notes = review.get("notes") or (
            "Criterion " + ", ".join(str(n) for n in sorted(failing)) + " is not met."
            if failing else "Every criterion is met.")
        lines.append(f"LEVERAGE-NOTES: {notes}")
        return "\n".join(lines)
    if "LEVERAGE-EVIDENCE" in prompt:
        found = CRITERION.search(prompt)
        number = int(found.group(1)) if found else 1
        mode = plan.get("builder", "evidence")
        if mode == "cannot":
            return "LEVERAGE-CANNOT: the stand-in was told it cannot do this."
        name = f"criterion-{number}.txt"
        with open(os.path.join(folder, name), "w") as handle:
            handle.write(f"Criterion {number}, done by the stand-in builder.\n")
        if mode == "silent":
            return "I did some work."
        return f"LEVERAGE-EVIDENCE: {name} in {folder}"
    return "ready"


def option(argv, *names):
    for index, value in enumerate(argv):
        if value in names and index + 1 < len(argv):
            return argv[index + 1]
    return None


def prompt_of(argv, *names):
    """The value after -p (claude, agy, grok) or the first word after exec."""
    return option(argv, *names)


# --- The four tools -----------------------------------------------------------


def claude(argv):
    if argv == ["--version"]:
        print(VERSIONS["claude"])
        return 0
    if argv[:2] == ["auth", "status"]:
        if signed_in("claude"):
            print(json.dumps({"loggedIn": True, "authMethod": "claude.ai", "apiProvider": "firstParty",
                              "email": STATUS_EMAIL, "orgName": STATUS_ORG,
                              "subscriptionType": "standin-claude-plan"}, indent=2))
            return 0
        return play("claude", "status-signed-out.json")
    if argv[:2] == ["auth", "login"]:
        sign_in("claude")
        print("Login successful.")
        return 0
    prompt = prompt_of(argv, "-p", "--print")
    if prompt is not None:
        directive = directive_for("claude", prompt)
        if not signed_in("claude"):
            return play("claude", "run-signed-out.json")
        if directive:
            return play_directive(directive)
        text = answer(prompt, os.getcwd())
        print(json.dumps({"type": "result", "subtype": "success", "is_error": False, "result": text,
                          "usage": {"input_tokens": 120, "output_tokens": 30}}))
        return 0
    print(f"claude stand-in: unknown arguments {argv}", file=sys.stderr)
    return 2


def codex(argv):
    if argv == ["--version"]:
        print(VERSIONS["codex"])
        return 0
    if argv[:2] == ["login", "status"]:
        # The real tool writes its status to standard error.
        if signed_in("codex"):
            print(f"Logged in using ChatGPT ({STATUS_EMAIL}, {STATUS_ORG})", file=sys.stderr)
            return 0
        return play("codex", "status-signed-out.json")
    if argv == ["login"]:
        sign_in("codex")
        print("Successfully logged in", file=sys.stderr)
        return 0
    if argv[:1] == ["exec"] and len(argv) > 1:
        prompt = argv[1]
        folder = option(argv, "-C", "--cd") or os.getcwd()
        last = option(argv, "-o", "--output-last-message")
        directive = directive_for("codex", prompt)
        if not signed_in("codex"):
            return play("codex", "run-signed-out.json")
        if directive:
            return play_directive(directive)
        print(json.dumps({"type": "thread.started", "thread_id": "standin-thread"}))
        print(json.dumps({"type": "turn.started"}))
        text = answer(prompt, folder)
        print(json.dumps({"type": "item.completed", "item": {"type": "agent_message", "text": text}}))
        print(json.dumps({"type": "turn.completed", "usage": {"input_tokens": 200, "output_tokens": 40}}))
        if last:
            with open(last, "w") as handle:
                handle.write(text)
        return 0
    print(f"codex stand-in: unknown arguments {argv}", file=sys.stderr)
    return 2


def agy(argv):
    if argv == ["--version"]:
        print(VERSIONS["agy"])
        return 0
    prompt = prompt_of(argv, "-p", "--print", "--prompt")
    if prompt is not None:
        directive = directive_for("agy", prompt)
        # What a signed-out agy does is not known (plan PV-4): its reply
        # file is made up.
        if not signed_in("agy"):
            return play("agy", "run-signed-out.json")
        if directive:
            return play_directive(directive)
        text = answer(prompt, os.getcwd())
        print(json.dumps({"conversation_id": "standin-conversation", "status": "SUCCESS",
                          "response": text + "\n", "num_turns": 1,
                          "usage": {"input_tokens": 90, "output_tokens": 20, "total_tokens": 110}}))
        return 0
    print(f"agy stand-in: unknown arguments {argv}", file=sys.stderr)
    return 2


def grok(argv):
    if argv == ["--version"]:
        print(VERSIONS["grok"])
        return 0
    if argv == ["models"]:
        if not signed_in("grok"):
            return play("grok", "status-signed-out.json")
        print(f"Signed in as {STATUS_EMAIL} ({STATUS_ORG})")
        print("Default model: grok-standin")
        return 0
    if argv[:1] == ["login"]:
        sign_in("grok")
        print("Signed in.")
        return 0
    prompt = prompt_of(argv, "-p", "--single")
    if prompt is not None:
        directive = directive_for("grok", prompt)
        # What a signed-out `grok -p` does is not known: its reply file is
        # made up.
        if not signed_in("grok"):
            return play("grok", "run-signed-out.json")
        if directive:
            return play_directive(directive)
        text = answer(prompt, option(argv, "--cwd") or os.getcwd())
        print(text)
        return 0
    print(f"grok stand-in: unknown arguments {argv}", file=sys.stderr)
    return 2


# --- Usage reads (RD-8) -------------------------------------------------------

# The separate usage list matches tool and account, like run directives but
# without prompt counts. Its fields are reply, settings, stale_settings,
# never_answers, version and codex_home. Available account commands and
# the shape of their usage files are in usage_tool.py.
def usage_command(tool, argv):
    app_server = tool == "codex" and argv == ["app-server"]
    if not (app_server or argv == ["--version"]
            or tool == "claude" and prompt_of(argv, "-p", "--print") == "/usage"):
        return None
    dispatch = runpy.run_path(os.path.join(ROOT, "usage_tool.py"))["dispatch"]
    return dispatch(tool, argv, scenario().get("usage") or [], REPLIES,
                    account_of(tool), app_server and signed_in(tool),
                    lambda message: record_json("app-server.jsonl", message))


# --- The runner ---------------------------------------------------------------


def runner(argv):
    """Stand-in for LeverageRunner: records how it was started, then runs
    until it is stopped, with a sleeping child of its own. The stop handler
    is in place before the child exists and before the record is written,
    so a stop at any moment ends the child too."""
    folder = state_path("runner")
    os.makedirs(folder, exist_ok=True)
    held = {"child": None, "stopped": False}

    # A stop ends the child; the wait below then returns and the stand-in
    # exits 0, as the real runner does after releasing what it holds.
    def stop(signum, frame):
        held["stopped"] = True
        if held["child"] is not None:
            held["child"].terminate()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    child = subprocess.Popen(["/bin/sleep", "600"], stdin=subprocess.DEVNULL)
    held["child"] = child
    try:
        if held["stopped"]:  # the stop came while the child was starting
            child.terminate()
        record = {"argv": argv, "env": dict(os.environ), "cwd": os.getcwd(),
                  "pid": os.getpid(), "child_pid": child.pid}
        path = os.path.join(folder, f"{os.getpid()}.json")
        with open(path + ".tmp", "w") as handle:
            json.dump(record, handle)
        os.replace(path + ".tmp", path)
        # Python runs a signal's handler between two steps of the program,
        # not inside a system call: a stop that lands just before a wait
        # with no limit begins would be seen only when that wait ends, which
        # is never. So the wait is short and repeated, and the stop is read
        # from the flag the handler sets.
        while not held["stopped"]:
            try:
                child.wait(timeout=0.05)
                break
            except subprocess.TimeoutExpired:
                pass
        if child.poll() is None:
            child.terminate()
        child.wait()
    finally:
        if child.poll() is None:  # any other way out
            child.kill()
            child.wait()
    return 0


TOOLS = {"claude": claude, "codex": codex, "agy": agy, "grok": grok, "runner": runner}


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in TOOLS:
        print("usage: provider_tool.py claude|codex|agy|grok|runner [arguments]", file=sys.stderr)
        return 2
    tool, argv = sys.argv[1], sys.argv[2:]
    if tool != "runner":
        record_call(tool, argv)
        result = usage_command(tool, argv)
        if result is not None:
            return result
    return TOOLS[tool](argv)


if __name__ == "__main__":
    sys.exit(main())
