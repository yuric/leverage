#!/usr/bin/env bash
# Test the approval developer check with an isolated PATH and a loopback fake API.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
python3 -I - "$root" "${1:-$root/scripts/real_approval_check.sh}" <<'PY'
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from time import monotonic, sleep
from uuid import UUID

root, script = map(Path, sys.argv[1:])
quiet_value = "response-and-tool-output-must-stay-private"
roles = {"builder": 1, "reviewer": 2, "orchestrator": 3}


def ident(number):
    return str(UUID(int=number))


def token(number):
    return f"lvs_mock_{number:024d}"


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def answer(self, data, status=200):
        self.send_response(status)
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())

    def do_GET(self):
        if self.path == "/v1/health":
            self.answer({})
        elif self.headers.get("Authorization") != f"Bearer {token(0)}":
            self.answer({"body": quiet_value}, 401)
        elif self.path == "/v1/owner/rules":
            self.answer({"rules": [{"rule": rule} for rule in self.server.rules.values()]})
        else:
            path = self.server.pages.get(self.path)
            self.answer(path if path is not None else {"body": quiet_value}, 200 if path is not None else 404)

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        assert self.headers.get("Content-Type") == "application/json"
        key = self.headers.get("Idempotency-Key")
        assert key and key not in self.server.keys
        self.server.keys.add(key)
        if self.path == "/v1/owner/setup":
            result = {"session_token": token(0)}
        elif self.headers.get("Authorization") != f"Bearer {token(0)}":
            self.answer({"body": quiet_value}, 401)
            return
        elif self.path == "/v1/owner/seats":
            number = roles[body["role"]]
            seat_id = ident(number)
            self.server.connected[seat_id] = number
            result = {"seat_id": seat_id}
        elif self.path.endswith("/landing-prompt"):
            seat_id = self.path.split("/")[-2]
            assert self.path == f"/v1/owner/seats/{seat_id}/landing-prompt"
            assert body == {"connection": "http"} and seat_id not in self.server.issued
            self.server.issued.add(seat_id)
            seat_token = token(self.server.connected[seat_id])
            address = f"http://127.0.0.1:{self.server.server_port}"
            result = {"seat_id": seat_id, "seat_token": seat_token, "connection": "http",
                      "text": f"Join Leverage at {address} with token {seat_token}. Fetch GET {address}/v1/join "
                              f"with header Authorization: Bearer {seat_token} and follow its instructions exactly."}
        elif self.path.endswith("/disable"):
            self.server.rules[self.path.split("/")[-2]]["enabled"] = False
            result = None
        elif self.path == "/v1/owner/tasks":
            assert sum(rule["enabled"] for rule in self.server.rules.values()) == 1
            assert self.server.issued == {ident(number) for number in roles.values()}
            index = len(self.server.tasks) + 1
            task_id = ident(index + 100)
            result = {"task_id": task_id}
            self.server.tasks[task_id] = index
            if self.server.fault == "http-body":
                self.answer({"body": quiet_value}, 422)
                return
        else:
            task_id = self.path.split("/")[-2]
            index = self.server.tasks[task_id]
            number = (1, 12)[index - 1]
            expected = json.loads(next((root / "evals/approves-actions/cases").glob(f"{number:02d}-*.json")).read_text())
            work_folder = Path(body.pop("work_reference"))
            assert body == {
                key: value for key, value in expected["contract"].items() if key != "work_reference"
            }
            assert work_folder.is_dir()
            scenario = json.loads((work_folder.parent / "reviewer-tools/state/scenario.json").read_text())
            assert expected["review"]["evidence"] in scenario["reviews"][0]["notes"]
            if index == 2:
                assert self.server.first_page_reads > 0, "the second task started before checking the first"
            if self.server.fault == "hangup":
                self.server.pages[f"/v1/owner/tasks/{task_id}"] = {
                    "task": {"state": "finishing"}, "actions": [{"state": "requested"}], "holds": [], "events": [],
                }
                self.answer({"outcome": "completed", "result": None})
                return
            self.server.pages[f"/v1/owner/tasks/{task_id}"] = self.page(task_id, index)
            # Post one expected work folder for the builder shim and wait for its answer.
            instruction = self.server.marker_file
            ready = instruction.with_suffix(".ready")
            ready.unlink(missing_ok=True)
            instruction.write_text(f"{index}\n{work_folder}\n")
            deadline = monotonic() + 3
            orchestrator_ready = instruction.with_name("orchestrator-ready")
            while not (ready.exists() and orchestrator_ready.exists()) and monotonic() < deadline:
                sleep(0.02)
            assert ready.exists(), "the builder shim did not receive the action"
            assert orchestrator_ready.exists(), "the orchestrator shim did not check the launch limit"
            instruction.unlink()
            result = None
        self.answer({"outcome": "completed", "result": result})

    def page(self, task_id, index):
        first = index == 1
        fault = self.server.fault
        action_id = ident(200 + index)

        def event(kind, actor, subject=action_id, payload=None):
            return {"id": ident(300 + len(events)), "type": kind, "actor_kind": "seat",
                    "actor_id": ident(actor), "task_id": task_id, "subject_id": subject, "payload": payload or {}}

        events = []
        stopped = not first and fault not in {"owner", "fallback"}
        effect = "approved" if first else ("stopped" if stopped else "passed_to_owner")
        events.append(event("job.finished", 3, ident(500 + index)))
        events.append(event("check.finished", 3, ident(600 + index), {
            "rule_id": ident(90), "result": "applied", "hook": "action.requested",
            "subject_id": action_id, "effect": effect
        }))
        approver = 2 if fault == "approval-actor" else 3
        builder = 2 if fault == "report-actor" else 1
        if first or fault == "second-approval":
            events.append(event("action.approved", approver))
        if first:
            events.append(event("action.started", 1))
            events.append(event("action.reported_done", builder))
        elif stopped:
            events.append(event("action.stopped", 3))
        return {
            "task": {"id": task_id, "state": "done" if first else "finishing"},
            "actions": [{"id": action_id, "state": "done" if first else ("stopped" if stopped else "requested"),
                         "approved_by_kind": "seat" if first else None,
                         "approved_by_id": ident(approver) if first else None}],
            "holds": [] if stopped or first else [{"reason": "owner_approval", "closed_at": None}],
            "inbox_items": [] if stopped or first else [{"kind": "approval", "facts": {"action_id": action_id}}],
            "events": events,
            "rule_checks": [{"rule_id": ident(90),
                             "reason": "The agent gave no decision." if fault == "fallback" else "Fixture decision."}],
        }

    def handle_one_request(self):
        super().handle_one_request()
        if getattr(self, "path", None) == f"/v1/owner/tasks/{ident(101)}":
            self.server.first_page_reads += 1


shim_source = r"""
import json
import os
import subprocess
import sys
import time
from pathlib import Path

name = Path(sys.argv[0]).name
args = sys.argv[1:]
work = Path(os.environ.get("TEST_SHIM_ROOT", Path(sys.argv[0]).resolve().parent))
with (work / "calls").open("a") as calls:
    calls.write(name + "\n")
if name in {"claude", "codex", "agy", "grok"}:
    print("response-and-tool-output-must-stay-private")
elif name == "docker":
    assert os.environ["DOCKER_CONFIG"] == "fixture-config"
    assert os.environ["DOCKER_HOST"] == "fixture-docker-host"
    assert os.environ["COMPOSE_PROJECT_NAME"].startswith("leverage-real-approval-check-")
    assert args[:5] == ["compose", "-f", "compose.yaml", "-f", "compose.test.yaml"]
    operation = args[5]
    if operation == "port":
        print("127.0.0.1:" + os.environ["FIXTURE_PORT"])
    elif operation == "exec" and "leverage:verify_log" in args:
        assert args[6:9] == ["-T", "api", "bin/rails"]
        print("Replay passed.")
    elif operation == "exec" and "pg_dump" in args[-1]:
        print("COPY public.events (seq, payload) FROM stdin;\n1\t{}\n\\.")
    elif operation == "up":
        assert args[-3:] == ["db", "api", "sweep"]
    elif operation == "logs" and (work / "fault").read_text() == "leaked-token":
        print("lvs_mock_" + "0" * 24)
    elif operation == "down":
        assert "--volumes" in args
        (work / "compose-down").touch()
    elif operation != "logs":
        sys.exit(7)
elif name == "swift":
    scratch = Path(args[args.index("--scratch-path") + 1])
    products = scratch / "products"
    if "--show-bin-path" in args:
        print(products)
    else:
        assert args[:3] == ["build", "--product", "LeverageRunner"]
        products.mkdir(parents=True, exist_ok=True)
        (products / "LeverageRunner").symlink_to(Path(sys.argv[0]).with_name("runner-shim"))
elif name == "LeverageRunner":
    role = os.environ["LEVERAGE_SEAT_ROLE"]
    number = {"builder": 1, "reviewer": 2, "orchestrator": 3}[role]
    assert os.environ["LEVERAGE_SEAT_TOKEN"] == f"lvs_mock_{number:024d}"
    (work / f"{role}-pid").write_text(str(os.getpid()))
    tool = Path(os.environ["LEVERAGE_TOOL_PATH"])
    if role == "orchestrator":
        assert os.environ.get("LEVERAGE_DEV_TOOL_LOGIN") == "1"
        assert "LEVERAGE_SETTINGS_DIR" not in os.environ
        assert os.environ["USER"] == "shim-user"
        for _ in range(2):
            subprocess.run([str(tool)], check=True, capture_output=True, timeout=2)
        # The real path has an explicit launch ceiling.
        assert subprocess.run([str(tool)], capture_output=True, timeout=2).returncode != 0
        (work / "orchestrator-ready").touch()
    else:
        assert "LEVERAGE_DEV_TOOL_LOGIN" not in os.environ
        assert tool.parent == Path(os.environ["LEVERAGE_TOOL_DIR"])
        assert tool.name == {"builder": "claude", "reviewer": "codex"}[role]
        instruction = work / "task-folder"
        ready = instruction.with_suffix(".ready")
        if role == "builder":
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                if instruction.exists() and not ready.exists():
                    index, folder = instruction.read_text().splitlines()
                    scenario = json.loads((tool.parent.parent / "state/scenario.json").read_text())
                    marker = Path(scenario["action_touch_file"])
                    assert marker.parent == Path(folder)
                    fault = (work / "fault").read_text()
                    if (index == "1" and fault != "no-touch") or (index == "2" and fault == "second-touch"):
                        marker.write_text("1\n")
                    ready.touch()
                time.sleep(0.02)
    time.sleep(30)
else:
    sys.exit(8)
"""


def start_shims(work):
    shims = work / "bin"
    shims.mkdir()
    for name in ("dirname", "mkdir"):
        (shims / name).symlink_to(shutil.which(name))
    (shims / "python3").symlink_to(sys.executable)
    fake = work / "shim"
    fake.write_text(f"#!{sys.executable}\n" + shim_source)
    fake.chmod(0o700)
    for name in ("docker", "swift", "claude", "codex", "agy", "grok", "runner-shim"):
        (shims / name).symlink_to(fake)
    return shims


with tempfile.TemporaryDirectory(prefix="test-real-approval-check-") as name:
    work = Path(name)
    shims = start_shims(work)
    for folder in ("home", "tmp"):
        (work / folder).mkdir()
    calls = work / "calls"
    marker = work / "task-folder"
    env = {"PATH": str(shims), "HOME": str(work / "home"), "USER": "shim-user", "LANG": "C",
           "TMPDIR": str(work / "tmp"), "TEST_SHIM_ROOT": str(work),
           "DOCKER_CONFIG": "fixture-config", "DOCKER_HOST": "fixture-docker-host",
           "API_IMAGE_TAG": "fixture-tag"}
    bash = shutil.which("bash")
    failures = []

    def run(arguments, variables, *, tracing=False):
        calls.unlink(missing_ok=True)
        options = ["-x"] if tracing else []
        return subprocess.run([bash, *options, str(script), *arguments], cwd=root, env=env | variables,
                              capture_output=True, text=True, timeout=15)

    def check(condition, message):
        if not condition:
            failures.append(message)
            print(f"FAIL: {message}", flush=True)

    for args, variables, reason in [
        (["claude"], {"CI": "", "LEVERAGE_REAL_PROVIDER": "claude"}, "CI is set"),
        (["codex"], {"CI": "1", "LEVERAGE_REAL_PROVIDER": "codex"}, "CI is set"),
        (["claude"], {}, "LEVERAGE_REAL_PROVIDER=claude"),
        (["gemini"], {"LEVERAGE_REAL_PROVIDER": "claude"}, "LEVERAGE_REAL_PROVIDER=gemini"),
        (["claude"], {"LEVERAGE_REAL_PROVIDER": "CLAUDE"}, "LEVERAGE_REAL_PROVIDER=claude"),
        ([], {"LEVERAGE_REAL_PROVIDER": "claude"}, "usage"),
        (["claude", "--unknown"], {"LEVERAGE_REAL_PROVIDER": "claude"}, "usage"),
        (["grok"], {"LEVERAGE_REAL_PROVIDER": "grok"}, "provider"),
        (["claude"], {"LEVERAGE_REAL_PROVIDER": "claude", "LEVERAGE_TOOL_DIR": str(shims)}, "not both"),
        (["claude"], {"LEVERAGE_TOOL_DIR": "bin"}, "absolute"),
        (["claude"], {"LEVERAGE_TOOL_DIR": str(shims)}, "copy of mac/Tests/StandIns"),
    ]:
        result = run(args, variables)
        check(result.returncode == 2 and reason in result.stderr,
              f"expected refusal {reason!r}, got exit {result.returncode}")
        check(not calls.exists(), f"refusal {reason!r} started a command")

    traced = run(["claude"], {"CI": "1"}, tracing=True)
    check(traced.returncode == 2 and traced.stderr.startswith("real_approval_check:"),
          "the script printed an inherited shell trace line")

    (work / "fault").write_text("hangup")
    hangup_tmp = work / "hangup-tmp"
    hangup_tmp.mkdir()
    with ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
        server.tasks, server.pages = {}, {}
        server.keys, server.connected, server.issued = set(), {}, set()
        server.rules = {ident(90): {"key": "orchestrator_approves_actions", "id": ident(90), "enabled": True}}
        server.fault, server.first_page_reads, server.marker_file = "hangup", 0, work / "hangup-task-folder"
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        variables = {"LEVERAGE_REAL_PROVIDER": "claude", "FIXTURE_PORT": str(server.server_port),
                     "LEVERAGE_E2E_SCRATCH": str(work / "scratch-hangup"), "TMPDIR": str(hangup_tmp)}
        child = subprocess.Popen([bash, str(script), "claude"], cwd=root, env=env | variables,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        pid_files = [work / f"{role}-pid" for role in roles]
        try:
            deadline = monotonic() + 10
            while child.poll() is None and not all(path.exists() for path in pid_files) and monotonic() < deadline:
                sleep(0.01)
            check(all(path.exists() for path in pid_files), "SIGHUP: three runners did not start")
            child.send_signal(signal.SIGHUP)
            child.wait(timeout=12)
            check(child.returncode == 130, f"SIGHUP: expected exit 130, got {child.returncode}")
            check((work / "compose-down").exists(), "SIGHUP: compose cleanup did not run")
            check(not any(hangup_tmp.iterdir()), "SIGHUP: temporary run folder survived")
            for path in pid_files:
                if path.exists():
                    try:
                        os.kill(int(path.read_text()), 0)
                    except ProcessLookupError:
                        pass
                    else:
                        check(False, f"SIGHUP: {path.stem} survived")
        finally:
            # The red run can leave shims holding the child's output pipes.
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            child.communicate(timeout=3)
            server.shutdown()
            thread.join()

    for index, (fault, expected_status, message) in enumerate([
        ("none", 0, "passed"),
        ("owner", 0, "passed"),
        ("fallback", 1, "the second check gave no decision"),
        ("approval-actor", 1, "orchestrator"),
        ("report-actor", 1, "builder"),
        ("second-approval", 1, "second action"),
        ("no-touch", 1, "first canary"),
        ("second-touch", 1, "second canary"),
        ("http-body", 1, "HTTP 422"),
        ("leaked-token", 1, "the secret scan found a leak"),
        ("fixed-port", 1, "dynamic loopback port"),
    ]):
        out = work / f"results-{index}"
        scratch = work / f"scratch-{index}"
        (work / "fault").write_text(fault)
        marker.unlink(missing_ok=True)
        (work / "orchestrator-ready").unlink(missing_ok=True)
        with ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
            server.tasks, server.pages = {}, {}
            server.keys, server.connected, server.issued = set(), {}, set()
            server.rules = {ident(i): {"key": key, "id": ident(i), "enabled": True}
                            for i, key in enumerate(("orchestrator_approves_actions", "other"), 90)}
            server.fault, server.first_page_reads, server.marker_file = fault, 0, marker
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                result = run(["claude"], {"LEVERAGE_REAL_PROVIDER": "claude",
                             "FIXTURE_PORT": "3000" if fault == "fixed-port" else str(server.server_port),
                             "LEVERAGE_E2E_SCRATCH": str(scratch),
                             "LEVERAGE_APPROVAL_CHECK_OUT": str(out)})
            finally:
                server.shutdown()
                thread.join()
        check(result.returncode == expected_status and message in result.stderr,
              f"{fault}: expected exit {expected_status} with {message!r}, got exit {result.returncode}")
        combined = result.stdout + result.stderr
        check(quiet_value not in combined and all(token(i) not in combined for i in range(4)),
              f"{fault}: a response body or token escaped")
        if expected_status == 0:
            invoked = calls.read_text().splitlines() if calls.exists() else []
            check(invoked.count("claude") == 2 and all(x not in invoked for x in ("codex", "agy", "grok")),
                  f"{fault}: expected exactly two selected provider launches")
            check(out.is_dir() and {path.name for path in out.iterdir()} == {"events.json", "tasks.json", "verify_log.txt"},
                  f"{fault}: expected only audited results")
            if out.is_dir():
                for path in out.iterdir():
                    contents = path.read_text()
                    check(quiet_value not in contents and all(token(i) not in contents for i in range(4)),
                          f"{fault}: private data escaped into results")
        else:
            check(not out.exists(), f"{fault}: failed run published results")
        check(not list((work / "tmp").glob("leverage-real-approval-check-*")),
              f"{fault}: private run folder remained")

    if failures:
        sys.exit(1)
print("test_real_approval_check: guard and workflow cases passed")
PY
