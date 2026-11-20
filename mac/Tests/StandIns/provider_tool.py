"""Stand-in for the four providers' tools, and for the runner program.

Tests never run a real provider's tool. `bin/claude`, `bin/codex`, `bin/agy`
and `bin/grok` start this file under their own name; `stand_in_runner.sh`
starts it as `runner`. A test copies the whole StandIns folder to a
temporary folder of its own, points LEVERAGE_TOOL_DIR at the copy's `bin/`,
and talks to the stand-in only through files beside it, in `state/`:

  state/scenario.json        written by the test (below)
  state/calls.jsonl          one line per run: tool, argv, cwd, env
  state/counters.json        how many review prompts have been answered
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

Standard library only.
"""

import fcntl
import json
import os
import re
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


def record_call(tool, argv):
    line = json.dumps({"tool": tool, "argv": argv, "cwd": os.getcwd(), "env": dict(os.environ)})
    with Locked():
        with open(state_path("calls.jsonl"), "a") as out:
            out.write(line + "\n")


def scenario():
    try:
        with open(state_path("scenario.json")) as handle:
            return json.load(handle)
    except FileNotFoundError:
        return {}


def next_review_round():
    with Locked():
        path = state_path("counters.json")
        try:
            with open(path) as handle:
                counters = json.load(handle)
        except FileNotFoundError:
            counters = {}
        round_number = counters.get("reviews", 0)
        counters["reviews"] = round_number + 1
        with open(path, "w") as handle:
            json.dump(counters, handle)
    return round_number


# --- Sign-in ------------------------------------------------------------------


def mark_file(tool):
    variable = ACCOUNT_VARIABLES.get(tool)
    folder = os.environ.get(variable) if variable else None
    if folder:
        return os.path.join(folder, MARK)
    return state_path(f"signed-in-{tool}")


def signed_in(tool):
    return os.path.exists(mark_file(tool))


def sign_in(tool):
    """Plays the owner signing in in the provider's window: one second."""
    time.sleep(SIGN_IN_SECONDS)
    path = mark_file(tool)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as handle:
        handle.write("signed in\n")


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


def answer(prompt, folder):
    """The answer's text for a prompt run in `folder`."""
    plan = scenario()
    if "LEVERAGE-CRITERION" in prompt:
        gate = plan.get("gate_file")
        if gate:
            gate_path = gate if os.path.isabs(gate) else state_path(gate)
            wait_for_gate(gate_path)
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
                              "email": STATUS_EMAIL, "orgName": STATUS_ORG}, indent=2))
            return 0
        print(json.dumps({"loggedIn": False, "authMethod": "none", "apiProvider": "firstParty"}, indent=2))
        return 1
    if argv[:2] == ["auth", "login"]:
        sign_in("claude")
        print("Login successful.")
        return 0
    prompt = prompt_of(argv, "-p", "--print")
    if prompt is not None:
        if not signed_in("claude"):
            print(json.dumps({"type": "result", "subtype": "success", "is_error": True,
                              "result": "Not logged in · Please run /login",
                              "usage": {"input_tokens": 0, "output_tokens": 0}}))
            return 1
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
        print("Not logged in", file=sys.stderr)
        return 1
    if argv == ["login"]:
        sign_in("codex")
        print("Successfully logged in", file=sys.stderr)
        return 0
    if argv[:1] == ["exec"] and len(argv) > 1:
        prompt = argv[1]
        folder = option(argv, "-C", "--cd") or os.getcwd()
        last = option(argv, "-o", "--output-last-message")
        print(json.dumps({"type": "thread.started", "thread_id": "standin-thread"}))
        print(json.dumps({"type": "turn.started"}))
        if not signed_in("codex"):
            print(json.dumps({"type": "error", "message": "unexpected status 401 Unauthorized"}))
            return 101
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
        # What a signed-out agy does is not known (plan PV-4): this answer
        # is made up.
        if not signed_in("agy"):
            print(json.dumps({"status": "ERROR", "response": "",
                              "error": "You are not signed in to Antigravity."}))
            return 1
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
        if signed_in("grok"):
            print(f"Signed in as {STATUS_EMAIL} ({STATUS_ORG})")
        else:
            print("You are not authenticated.")
        print("Default model: grok-standin")
        return 0
    if argv[:1] == ["login"]:
        sign_in("grok")
        print("Signed in.")
        return 0
    prompt = prompt_of(argv, "-p", "--single")
    if prompt is not None:
        # What a signed-out `grok -p` does is not known: this is made up.
        if not signed_in("grok"):
            print("You are not authenticated.")
            return 1
        text = answer(prompt, option(argv, "--cwd") or os.getcwd())
        print(text)
        return 0
    print(f"grok stand-in: unknown arguments {argv}", file=sys.stderr)
    return 2


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
    return TOOLS[tool](argv)


if __name__ == "__main__":
    sys.exit(main())
