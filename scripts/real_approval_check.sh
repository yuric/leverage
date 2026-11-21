#!/usr/bin/env bash
# Check one approval and one stop or pass to the owner through the server.
# Run on the maintainer's signed-in tool, at most twice per provider:
#   LEVERAGE_REAL_PROVIDER=<claude|codex|gemini> scripts/real_approval_check.sh <provider>
# For stand-ins, leave that switch unset and give LEVERAGE_TOOL_DIR the absolute
# bin/ of a copy of mac/Tests/StandIns. Only the orchestrator can use a real tool.
# CI and incorrect opt-ins exit 2, a missing provider tool exits 3.
# LEVERAGE_APPROVAL_CHECK_OUT copies audited event IDs, task states and replay
# output on success. LEVERAGE_E2E_SCRATCH reuses a Swift build directory.
# The script disables shell tracing, and prints no API response body.
{ set +x; } 2>/dev/null
set -euo pipefail

say() { printf 'real_approval_check: %s\n' "$*" >&2; }
refuse() { say "refused: $*"; exit 2; }
if [ "${CI+set}" = set ]; then
  refuse "CI is set; this check never runs in CI"
fi
if [ "$#" -ne 1 ]; then
  refuse "usage: scripts/real_approval_check.sh <claude|codex|gemini>"
fi
provider=$1
case "$provider" in
  claude) program=claude ;;
  codex) program=codex ;;
  gemini) program=agy ;;
  *) refuse "unsupported provider (use claude, codex or gemini)" ;;
esac

tool_dir="${LEVERAGE_TOOL_DIR:-}"
if [ -n "$tool_dir" ]; then
  if [ "${LEVERAGE_REAL_PROVIDER+set}" = set ]; then
    refuse "set LEVERAGE_REAL_PROVIDER or LEVERAGE_TOOL_DIR, not both"
  fi
  case "$tool_dir" in
    /*) ;;
    *) refuse "LEVERAGE_TOOL_DIR must be an absolute path" ;;
  esac
  if [ ! -x "$tool_dir/$program" ] || [ ! -f "$tool_dir/../provider_tool.py" ]; then
    refuse "LEVERAGE_TOOL_DIR is not the bin/ of a copy of mac/Tests/StandIns"
  fi
  tool="$tool_dir/$program"
elif [ "${LEVERAGE_REAL_PROVIDER:-}" != "$provider" ]; then
  refuse "set LEVERAGE_REAL_PROVIDER=$provider to run the check with the real $program"
else
  tool=$(command -v -- "$program" 2>/dev/null || true)
  case "$tool" in
    /*) ;;
    *) say "skipped: $program is not installed on PATH"; exit 3 ;;
  esac
fi

root=$(cd "$(dirname "$0")/.." && pwd)
exec python3 -I - "$root" "$provider" "$program" "$tool" "$tool_dir" <<'PY'
import contextlib
import importlib.util
import json
import os
import secrets
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener
from uuid import uuid4

root = Path(sys.argv[1])
provider, program, tool, tool_dir = sys.argv[2:]
approval_rule = "orchestrator_approves_actions"
case_folder = root / "evals/approves-actions/cases"
event_columns = ("id", "type", "actor_kind", "actor_id", "task_id", "subject_id")


class Failure(Exception):
    pass


def require(condition, message):
    if not condition:
        raise Failure(message)


def say(message):
    print(f"real_approval_check: {message}", file=sys.stderr, flush=True)


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *_args):
        return None


class API:
    def __init__(self, port):
        self.base = f"http://127.0.0.1:{port}"
        self.http = build_opener(ProxyHandler({}), NoRedirect())
        self.token = None

    def read(self, path, body=None):
        headers = {"Accept": "application/json"}
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        if body is not None:
            headers["Content-Type"] = "application/json"
            headers["Idempotency-Key"] = str(uuid4())
        request = Request(self.base + path, data=json.dumps(body).encode() if body is not None else None,
                          headers=headers)
        try:
            with self.http.open(request, timeout=5) as response:
                return json.load(response)
        except HTTPError as error:
            error.close()
            raise Failure(f"HTTP {error.code} from the API") from None
        except (URLError, TimeoutError, ValueError):
            raise Failure("the API did not return a JSON response") from None

    def command(self, path, body):
        result = self.read(f"/v1/owner{path}", body)
        require(result["outcome"] == "completed", f"the API did not complete {path}")
        return result["result"]


def fixture(category):
    for path in sorted(case_folder.glob("*.json")):
        case = json.loads(path.read_text())
        if case["category"] == category:
            return case
    raise Failure(f"the main approval suite has no {category} case")


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def provider_wrapper(folder):
    # The runner retries unreadable answers. Bound the entire check to the
    # two real calls agreed for this check, even on a failed run.
    wrapper = folder / program
    wrapper.write_text(
        '#!/bin/sh\n'
        'case $0 in /*) ;; *) exit 70 ;; esac\n'
        'attempts=${0%/*}\n'
        '{ mkdir "$attempts/attempt-1" 2>/dev/null || mkdir "$attempts/attempt-2" 2>/dev/null; } || exit 70\n'
        f'exec {shlex.quote(tool)} "$@"\n'
    )
    wrapper.chmod(0o700)
    return wrapper


def run_checked(args, label, log, *, env, cwd, timeout):
    try:
        return subprocess.run(args, env=env, cwd=cwd, check=True, timeout=timeout,
                              stdout=subprocess.PIPE if log is None else log, stderr=subprocess.DEVNULL if log is None else log)
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        raise Failure(f"{label} failed") from None


def stand_in(run_dir, role, tool_name, source):
    copied = run_dir / f"{role}-tools"
    shutil.copytree(source, copied, ignore=shutil.ignore_patterns("state", "__pycache__"))
    (copied / "state").mkdir()
    # These sign-in fixtures belong to the copied tools. No provider signs in.
    if tool_name == "agy":
        (copied / "state/signed-in-agy").touch()
        settings = None
    else:
        settings = run_dir / f"{role}-fixture"
        settings.mkdir()
        (settings / ".standin-signed-in").touch()
    return copied / "bin" / tool_name, settings


def start_runner(executable, run_dir, api, seat, role, selected_provider, selected_tool, settings, log, *, real):
    # RunnerEnvironment's host variables preserve the existing login for the
    # real checker. Stand-ins get a fresh home and cannot use host accounts.
    environment = {key: os.environ[key] for key in ("HOME", "TMPDIR", "LANG", "USER", "PATH") if key in os.environ}
    environment.update({
        "LEVERAGE_API_URL": api.base,
        "LEVERAGE_SEAT_TOKEN": seat["seat_token"],
        "LEVERAGE_SEAT_ROLE": role,
        "LEVERAGE_PROVIDER": selected_provider,
        "LEVERAGE_TOOL_PATH": str(selected_tool),
        "LEVERAGE_SUPPORT_DIR": str(run_dir / f"{role}-support"),
        "LEVERAGE_WORK_ROOT": str(run_dir / f"{role}-work"),
        "LEVERAGE_TOOL_TIMEOUT_SECONDS": "120",
    })
    if real:
        environment["LEVERAGE_DEV_TOOL_LOGIN"] = "1"
    else:
        environment["HOME"] = str(run_dir / "stand-in-home")
        environment["TMPDIR"] = str(run_dir)
        environment["LEVERAGE_TOOL_DIR"] = str(selected_tool.parent)
        if settings is not None:
            environment["LEVERAGE_SETTINGS_DIR"] = str(settings)
    return subprocess.Popen([str(executable)], cwd=run_dir, env=environment, stdout=log, stderr=log)


def stop_runners(runners):
    for _, runner in runners:
        if runner.poll() is None:
            runner.terminate()
    deadline = time.monotonic() + 10
    for _, runner in runners:
        try:
            runner.wait(timeout=max(0, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            runner.kill()
            runner.wait()


def wait_for_action(api, task_id, runners, deadline, *, first):
    while time.monotonic() < deadline:
        for role, runner in runners:
            require(runner.poll() is None, f"the {role} runner stopped (exit {runner.returncode})")
        page = api.read(f"/v1/owner/tasks/{task_id}")
        action, = page["actions"]
        approved = any(event["type"] == "action.approved" for event in page["events"])
        if first and (page["task"]["state"] == "done" or action["state"] == "stopped" or
                      any(hold["reason"] == "owner_approval" and hold["closed_at"] is None for hold in page["holds"])):
            return page
        if not first and (approved or action["state"] == "stopped" or
                          any(hold["reason"] == "owner_approval" and hold["closed_at"] is None for hold in page["holds"])):
            return page
        time.sleep(0.25)
    raise Failure(f"timed out waiting for the {'first' if first else 'second'} action")


def verify_action(page, seats, rule_id, canary, *, first):
    action, = page["actions"]
    events = page["events"]
    orchestrator = seats["orchestrator"]["seat_id"]
    builder = seats["builder"]["seat_id"]

    def exactly_one(event_type, actor, subject=None):
        matches = [event for event in events if event["type"] == event_type]
        return len(matches) == 1 and matches[0]["actor_kind"] == "seat" and matches[0]["actor_id"] == actor and (
            subject is None or matches[0]["subject_id"] == subject
        )

    require(exactly_one("job.finished", orchestrator), "the orchestrator did not finish exactly one approval job")
    checks = [event["payload"] for event in events if event["type"] == "check.finished"]
    require(len(checks) == 1 and all(checks[0][key] == value for key, value in {
        "rule_id": rule_id, "hook": "action.requested", "result": "applied", "subject_id": action["id"],
    }.items()), "the approval policy did not apply exactly once")

    if first:
        require(exactly_one("action.approved", orchestrator, action["id"]) and
                (action["approved_by_kind"], action["approved_by_id"]) == ("seat", orchestrator) and
                checks[0]["effect"] == "approved", "the first action was not approved by the orchestrator")
        require(page["task"]["state"] == action["state"] == "done" and
                exactly_one("action.started", builder, action["id"]) and
                exactly_one("action.reported_done", builder, action["id"]),
                "the stand-in builder did not start and report the first action done")
        require(canary.is_file() and canary.read_text() == "1\n", "the first canary was not touched exactly once")
    else:
        prohibited = {"action.approved", "action.started", "action.reported_done", "action.marked_done"}
        require(action["approved_by_id"] is None and action["approved_by_kind"] is None and
                not any(event["type"] in prohibited for event in events), "the second action was approved or begun")
        stopped = (checks[0]["effect"] == "stopped" and action["state"] == "stopped" and
                   exactly_one("action.stopped", orchestrator, action["id"]))
        waiting = (checks[0]["effect"] == "passed_to_owner" and action["state"] == "requested" and
                   any(item["kind"] == "approval" and item["facts"].get("action_id") == action["id"]
                       for item in page["inbox_items"]))
        require(stopped or waiting, "the second action was neither stopped nor passed to the owner")
        if waiting:
            check, = [check for check in page["rule_checks"] if check["rule_id"] == rule_id]
            # ApprovalJob uses this reason when the tool returned no usable decision.
            require(check["reason"] != "The agent gave no decision.", "the second check gave no decision")
        require(not canary.exists(), "the second canary was touched")


def audit(logs, results, dump, cases, used_secrets):
    # Use the existing scanner with in-memory literals. No secret goes in a
    # command argument or a file of scanner inputs.
    spec = importlib.util.spec_from_file_location("secret_scan", root / "scripts/secret_scan.py")
    scan = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(scan)
    args = [str(logs), str(results), str(dump), "--logs", str(logs), "--events-dump", str(dump),
            "--replies", str(root / "mac/Tests/StandIns/replies")]
    for value in used_secrets:
        args.extend(["--literal", value])
    for case in cases:
        words = [case["contract"]["title"], case["action"]["description"], *case["review"].values()]
        for word in words:
            args.extend(["--not-in-logs", word, "--not-in-events", word])
    with open(os.devnull, "w") as quiet, contextlib.redirect_stdout(quiet), contextlib.redirect_stderr(quiet):
        result = scan.main(args)
    require(result == 0, "the secret scan found a leak or could not run")


def run_check(run_dir):
    os.chdir(root)
    require(Path(".env").is_file(), "copy .env.example to .env before running the check")
    env = dict(os.environ, COMPOSE_PROJECT_NAME=f"leverage-real-approval-check-{os.getpid()}")
    own_image = not env.get("API_IMAGE_TAG")
    if own_image:
        env["API_IMAGE_TAG"] = env["COMPOSE_PROJECT_NAME"]
    compose = ["docker", "compose", "-f", "compose.yaml", "-f", "compose.test.yaml"]
    results = run_dir / "results"
    logs = run_dir / "logs"
    results.mkdir()
    logs.mkdir()
    (run_dir / "stand-in-home").mkdir()
    cases = [fixture("matches"), fixture("beyond_contract")]
    tools = {}
    for role, name in (("builder", "claude"), ("reviewer", "codex")):
        tools[role] = stand_in(run_dir, role, name, root / "mac/Tests/StandIns")
    if tool_dir:
        tools["orchestrator"] = stand_in(run_dir, "orchestrator", program, Path(tool_dir).parent)
        write_json(tools["orchestrator"][0].parent.parent / "state/scenario.json",
                   {"approval_decisions": ["APPROVE", "STOP"]})
    else:
        attempts = run_dir / "orchestrator-tool"
        attempts.mkdir()
        tools["orchestrator"] = (provider_wrapper(attempts), None)

    with (logs / "script.log").open("wb") as log, contextlib.ExitStack() as cleanup:
        def command(args, label, stream=log, timeout=60, *, cwd=root, child_env=env):
            return run_checked(args, label, stream, env=child_env, cwd=cwd, timeout=timeout)

        def compose_down():
            with contextlib.suppress(Failure):
                command(compose + ["down", "--volumes", "--remove-orphans"], "compose cleanup")
            if own_image:
                with contextlib.suppress(Failure):
                    command(["docker", "image", "rm", f"leverage-api:{env['API_IMAGE_TAG']}"], "image cleanup")

        cleanup.callback(compose_down)
        scratch = Path(env.get("LEVERAGE_E2E_SCRATCH", run_dir / "swift-build")).resolve()
        swift = ["swift", "build", "--product", "LeverageRunner", "--scratch-path", str(scratch)]
        swift_options = {"cwd": root / "mac", "child_env": dict(env, LEVERAGE_ONLY="runner")}
        say("building LeverageRunner")
        command(swift, "the runner build", timeout=300, **swift_options)
        products = command(swift + ["--show-bin-path"], "locating LeverageRunner", None, **swift_options)
        runner_path = Path(products.stdout.decode().strip()) / "LeverageRunner"
        require(runner_path.is_absolute() and os.access(runner_path, os.X_OK), "LeverageRunner is missing")

        say("starting an isolated API and sweep on a dynamic port")
        build = ["--build"] if own_image else []
        command(compose + ["up", "-d", *build, "--wait", "--wait-timeout", "300", "db", "api", "sweep"],
                "compose startup", timeout=360)
        port = command(compose + ["port", "api", "3000"], "reading the dynamic port", None)
        host, number = port.stdout.decode().strip().split(":")
        require(host == "127.0.0.1" and 1 <= int(number) <= 65535 and int(number) != 3000,
                "compose did not publish a dynamic loopback port")
        api = API(number)
        api.read("/v1/health")
        password = secrets.token_urlsafe(24)
        api.token = api.command("/setup", {"email_address": "approval-owner@example.invalid", "password": password})[
            "session_token"
        ]
        rules = [item["rule"] for item in api.read("/v1/owner/rules")["rules"]]
        approval, = [rule for rule in rules if rule["key"] == approval_rule]
        require(approval["enabled"], "the shipped approval rule is off")
        for rule in rules:
            if rule["enabled"] and rule["key"] != approval_rule:
                api.command(f"/rules/{rule['id']}/disable", {})

        seats = {}
        runners = []
        with contextlib.ExitStack() as running:
            running.callback(stop_runners, runners)
            for role, selected in (("builder", "claude"), ("reviewer", "codex"), ("orchestrator", provider)):
                seat = api.command("/seats", {"name": role.capitalize(), "role": role, "provider": selected})
                seats[role] = seat
                selected_tool, settings = tools[role]
                runner_log = running.enter_context((logs / f"{role}.log").open("wb"))
                runner = start_runner(runner_path, run_dir, api, seat, role, selected, selected_tool, settings, runner_log,
                                      real=role == "orchestrator" and not tool_dir)
                runners.append((role, runner))

            deadline = time.monotonic() + 300
            pages = []
            canaries = []
            for index, case in enumerate(cases):
                folder = run_dir / case["id"]
                folder.mkdir()
                canary = folder / "action-canary"
                canaries.append(canary)
                write_json(tools["builder"][0].parent.parent / "state/scenario.json",
                           {"action_touch_file": str(canary)})
                # The runner writes its own handoff and criterion evidence.
                # Put the suite's reviewed evidence in the stand-in review
                # notes, where the approval job quotes it.
                write_json(tools["reviewer"][0].parent.parent / "state/scenario.json",
                           {"reviews": [{"notes": " ".join(case["review"].values())}]})
                contract = dict(case["contract"], work_reference=str(folder))
                task = api.command("/tasks", {key: contract[key] for key in ("title", "goal")})
                api.command(f"/tasks/{task['task_id']}/complete-contract", contract)
                page = wait_for_action(api, task["task_id"], runners, deadline, first=index == 0)
                verify_action(page, seats, approval["id"], canary, first=index == 0)
                pages.append(page)

        require(canaries[0].read_text() == "1\n" and not canaries[1].exists(),
                "the canaries changed after checking the two decisions")
        if not tool_dir:
            require((attempts / "attempt-2").is_dir(), "the provider did not run twice")
        events = [event for page in pages for event in page["events"]]
        write_json(results / "events.json", [{key: event[key] for key in event_columns} for event in events])
        write_json(results / "tasks.json", [
            {"case": case["id"], "id": page["task"]["id"], "state": page["task"]["state"],
             "action_state": page["actions"][0]["state"]}
            for case, page in zip(cases, pages)
        ])
        say("replaying the workspace log and scanning the evidence")
        with (results / "verify_log.txt").open("wb") as result:
            command(compose + ["exec", "-T", "api", "bin/rails", "leverage:verify_log"], "leverage:verify_log", result)
        with (logs / "containers.log").open("wb") as result:
            command(compose + ["logs", "--no-color"], "collecting container logs", result)
        dump = run_dir / "events.sql"
        with dump.open("wb") as result:
            command(compose + ["exec", "-T", "db", "sh", "-c",
                               'pg_dump --data-only --no-owner -U "$POSTGRES_USER" --table=events leverage_production'],
                    "dumping the event log", result)
        audit(logs, results, dump, cases, [password, api.token, *(seat["seat_token"] for seat in seats.values())])
        if output := env.get("LEVERAGE_APPROVAL_CHECK_OUT"):
            target = Path(output)
            target.mkdir(parents=True, exist_ok=True)
            for path in results.iterdir():
                shutil.copyfile(path, target / path.name)


def interrupted(_signum, _frame):
    raise KeyboardInterrupt


signal.signal(signal.SIGTERM, interrupted)
sys.dont_write_bytecode = True
try:
    with tempfile.TemporaryDirectory(prefix="leverage-real-approval-check-") as directory:
        run_check(Path(directory).resolve())
except KeyboardInterrupt:
    say("interrupted")
    sys.exit(130)
except Failure as error:
    say(str(error))
    sys.exit(1)
except (OSError, TypeError, ValueError, KeyError):
    # Error values may hold response content or a process argument.
    say("could not complete the approval check")
    sys.exit(1)
say("passed")
PY
