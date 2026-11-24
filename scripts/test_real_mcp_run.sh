#!/usr/bin/env bash
# Exercise the managing agent's MCP check with an isolated PATH and fake API.
set -euo pipefail
python3 -I - "${1:-$(dirname "$0")/real_mcp_run.sh}" <<'PY'
import http.server
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest

SCRIPT = Path(sys.argv.pop()).resolve()
BUILDER = "00000000-0000-4000-8000-000000000101"
REVIEWER = "00000000-0000-4000-8000-000000000102"
TASK = "00000000-0000-4000-8000-000000000103"
SIDE_EFFECTS = ("claude", "codex", "agy", "grok", "docker", "swift")
EVENTS = ("task.claimed", "criterion.started", "criterion.passed", "task.submitted", "task.done")
SEAT_TOKEN = "stand-in-builder-token"
REVIEWER_TOKEN = "stand-in-reviewer-token"
PRIVATE_TEXT = "stand-in raw response must stay private"
RULES = [f"00000000-0000-4000-8000-00000000020{i}" for i in range(7)]

SHIM = r'''
import json, os, pathlib, subprocess, sys, time
p = pathlib.Path(sys.argv[0]).resolve().parent.parent
mode = (p / "mode").read_text() if (p / "mode").exists() else ""
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with (p / "calls").open("a") as log:
    log.write(name + "\n")
if name == "docker":
    if "port" in args:
        print("127.0.0.1:" + os.environ["STAND_IN_PORT"])
    elif "leverage:verify_log" in args:
        print("verify_log: stand-in workspace verified")
    elif "logs" in args and mode == "leak":
        print("stand-in-builder-token")
    elif not any(cmd in args for cmd in ("up", "down", "logs", "rm")):
        sys.exit(92)
elif name == "swift":
    if "--show-bin-path" in args:
        print(p / "bin")
elif name == "LeverageRunner":
    assert os.environ["LEVERAGE_SEAT_TOKEN"] == "stand-in-reviewer-token"
    assert os.environ["LEVERAGE_SEAT_ROLE"] == "reviewer"
    assert "LEVERAGE_DEV_TOOL_LOGIN" not in os.environ
    assert pathlib.Path(os.environ["LEVERAGE_TOOL_PATH"]).parent == pathlib.Path(
        os.environ["LEVERAGE_TOOL_DIR"])
    parent = os.getppid()
    end = time.monotonic() + 20
    while time.monotonic() < end and os.getppid() == parent:
        time.sleep(0.05)
elif name == "LeverageMCP":
    assert os.environ["LEVERAGE_SEAT_TOKEN"] == "stand-in-builder-token"
    assert os.environ["LEVERAGE_SEAT_ROLE"] == "builder"
    print("2026-11-20T00:00:00Z mcp info: MCP initialize protocol revision 2025-06-18", file=sys.stderr)
elif name == "claude":
    config = pathlib.Path(args[args.index("--mcp-config") + 1])
    server = json.loads(config.read_text())["mcpServers"]["leverage"]
    facts = {"path": str(config), "mode": config.stat().st_mode & 0o777,
             "parent_mode": config.parent.stat().st_mode & 0o777,
             "has_builder_token": server["env"]["LEVERAGE_SEAT_TOKEN"] == "stand-in-builder-token",
             "args": args, "cwd": os.getcwd(),
             "empty": not list(pathlib.Path.cwd().iterdir())}
    (p / "client.tmp").write_text(json.dumps(facts))
    (p / "client.tmp").replace(p / "client.json")
    assert "LEVERAGE_SEAT_TOKEN" not in os.environ
    assert "LEVERAGE_REAL_MCP" not in os.environ
    cmd = server["command"]
    assert pathlib.Path(cmd).name in ("LeverageMCP", "sh")
    child_env = os.environ.copy()
    child_env.update(server["env"])
    subprocess.run([cmd, *server.get("args", [])], env=child_env, check=True)
    if mode == "denied":
        print(json.dumps({"permission_denials": [{"tool_name": "mcp__leverage__get_next"}]}), flush=True)
    if mode == "denied_text":
        print("Tool call mcp__leverage__get_next was not allowed", file=sys.stderr, flush=True)
    if mode in ("denied", "denied_text", "interrupt"):
        time.sleep(20)
    if mode == "failure":
        print("stand-in raw response must stay private", file=sys.stderr)
        sys.exit(1)
    if mode == "orphan":
        source = """import pathlib, signal, sys, time
root = pathlib.Path(sys.argv[1])
signal.signal(signal.SIGTERM, lambda *_: ((root / 'orphan-stopped').touch(), sys.exit(0)))
(root / 'orphan-started').touch()
end = time.monotonic() + 12
while root.exists() and time.monotonic() < end:
    time.sleep(0.02)
"""
        subprocess.Popen([sys.executable, "-I", "-c", source, str(p)],
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        end = time.monotonic() + 3
        while not (p / "orphan-started").exists() and time.monotonic() < end:
            time.sleep(0.02)
        assert (p / "orphan-started").exists()
    pathlib.Path("hello.txt").write_text("ready\n")
    (p / "submitted").touch()
    result = "stand-in raw response must stay private"
    if mode == "no_denials":
        result += "; no MCP tool calls were denied"
    print(json.dumps({"is_error": False, "result": result, "permission_denials": []}))
else:
    sys.exit(93)
'''


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_GET(self):
        self.reply()

    def do_POST(self):
        self.reply()

    def reply(self):
        server = self.server
        path = self.path.split("?")[0]
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        if body:
            assert self.headers["Content-Type"] == "application/json"
        if self.command == "POST":
            key = self.headers["Idempotency-Key"]
            assert key and key not in server.keys
            server.keys.add(key)
        if path == "/v1/join":
            assert self.headers["Authorization"] == f"Bearer {SEAT_TOKEN}"
        elif path not in ("/v1/health", "/v1/owner/setup"):
            assert self.headers["Authorization"] == "Bearer stand-in-session-token"
        message = json.loads(body) if body else {}
        completed = lambda result: {"outcome": "completed", "result": result}
        if path == "/v1/health":
            result = {}
        elif path == "/v1/owner/setup":
            result = completed({"session_token": "stand-in-session-token"})
        elif path == "/v1/owner/rules":
            result = {"rules": [{"rule": {"id": key, "enabled": True}} for key in RULES]}
        elif path.endswith("/disable"):
            server.disabled.add(path.split("/")[-2])
            result = completed(None)
        elif path == "/v1/owner/seats":
            seat = message["role"]
            assert seat in ("builder", "reviewer")
            assert message["provider"] == ("claude" if seat == "builder" else "codex")
            assert not message.get("credential_id")
            seat_id = BUILDER if seat == "builder" else REVIEWER
            server.connected.add(seat_id)
            result = completed({"seat_id": seat_id})
        elif path.endswith("/landing-prompt"):
            if self.command != "POST":
                self.send_error(405, PRIVATE_TEXT)
                return
            seat_id = path.split("/")[-2]
            assert seat_id in server.connected and seat_id not in server.issued
            connection, token = ("mcp", SEAT_TOKEN) if seat_id == BUILDER else ("http", REVIEWER_TOKEN)
            assert self.path == path and message == {"connection": connection}
            server.issued[seat_id] = connection
            address = f"http://127.0.0.1:{server.server_port}"
            join_url = f"{address}/v1/join" + ("?connection=mcp" if connection == "mcp" else "")
            result = completed({"seat_id": seat_id, "seat_token": token, "connection": connection,
                                "text": f"Join Leverage at {address} with token {token}. Fetch GET {join_url} "
                                        f"with header Authorization: Bearer {token} and follow its instructions exactly."})
        elif path == "/v1/join":
            assert self.command == "GET" and self.path == "/v1/join?connection=mcp" and not body
            assert server.issued.get(BUILDER) == "mcp"
            server.join_reads += 1
            result = {"role": "builder", "connection": "mcp", "text": "Stand-in MCP join instructions."}
        elif path == "/v1/owner/tasks":
            assert server.disabled == set(RULES)
            result = completed({"task_id": TASK})
        elif path == f"/v1/owner/tasks/{TASK}/complete-contract":
            assert message["actions"] == []
            assert message["criteria"] == [
                {"text": "Create a file named hello.txt that contains the word ready", "kind": "build"},
                {"text": "An independent reviewer agrees.", "kind": "review"}
            ]
            folder = Path(message["work_reference"])
            assert folder.is_dir() and not list(folder.iterdir())
            server.work_folder = folder
            result = completed(None)
        elif path == f"/v1/owner/tasks/{TASK}":
            result = {"task": {"state": "done" if (server.root / "submitted").exists() else "ready"}}
        elif path == "/v1/owner/events":
            actors = [BUILDER] * 4 + [REVIEWER]
            if server.mode == "wrong_actor":
                actors[2] = REVIEWER
            result = {"events": [
                {"seq": i, "type": kind, "task_id": TASK, "actor_kind": "seat", "actor_id": actor,
                 "payload": {"private": PRIVATE_TEXT}}
                for i, (kind, actor) in enumerate(zip(EVENTS, actors), 1)
            ], "next_after_seq": 5}
        else:
            self.send_error(404, PRIVATE_TEXT)
            return
        payload = json.dumps(result).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


class Check(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory(prefix="leverage-test-real-mcp-")
        self.addCleanup(folder.cleanup)
        self.root = Path(folder.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        shim = self.bin / "record"
        shim.write_text(f"#!{sys.executable}\n" + SHIM)
        shim.chmod(0o700)
        for name in (*SIDE_EFFECTS, "LeverageRunner", "LeverageMCP"):
            (self.bin / name).symlink_to(shim)
        # Fixed tool lookup. No provider can be found outside the shims.
        (self.bin / "python3").symlink_to(sys.executable)
        self.env = {"PATH": str(self.bin), "HOME": folder.name, "TMPDIR": folder.name, "LANG": "C",
                    "COMPOSE_PROJECT_NAME": "leverage-m5-wp21", "API_IMAGE_TAG": "leverage-m5-wp21",
                    "LEVERAGE_MCP_CHECK_OUT": str(self.root / "results")}

    def start(self, args, env):
        return subprocess.Popen(
            ["/bin/bash", "-x", str(SCRIPT), *args], env={**self.env, **env}, start_new_session=True,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        )

    def read(self, process, timeout=12):
        try:
            return process.communicate(timeout=timeout)[0]
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.communicate()
            self.fail("check exceeded the self-test deadline")

    def test_refusals_start_no_program(self):
        opt_in = {"LEVERAGE_REAL_PROVIDER": "claude", "LEVERAGE_REAL_MCP": "1"}
        checks = (
            ({"CI": "1", **opt_in}, ["claude"], "CI is set"),
            ({"CI": "", **opt_in}, ["claude"], "CI is set"),
            ({}, ["claude"], "LEVERAGE_REAL_MCP=1"),
            ({"LEVERAGE_REAL_PROVIDER": "claude"}, ["claude"], "LEVERAGE_REAL_MCP=1"),
            ({"LEVERAGE_REAL_MCP": "1"}, ["claude"], "LEVERAGE_REAL_PROVIDER=claude"),
            ({**opt_in, "LEVERAGE_REAL_PROVIDER": "codex"}, ["claude"], "LEVERAGE_REAL_PROVIDER=claude"),
            (opt_in, ["codex"], "usage"),
            (opt_in, ["claude", "--extra"], "usage"),
        )
        for env, args, reason in checks:
            with self.subTest(args=args, reason=reason, variables=tuple(env)):
                (self.root / "calls").unlink(missing_ok=True)
                process = self.start(args, env)
                output = self.read(process)
                self.assertEqual(process.returncode, 2)
                self.assertFalse((self.root / "calls").exists())
                self.assertIn(reason, output)

    def exercise(self, mode, expected, reason):
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        (self.root / "mode").write_text(mode)
        server.root = self.root
        server.disabled = set()
        server.keys, server.connected, server.issued = set(), set(), {}
        server.join_reads = 0
        server.mode = mode
        thread = threading.Thread(target=server.serve_forever)
        thread.start()
        try:
            process = self.start(["claude"], {
                "LEVERAGE_REAL_PROVIDER": "claude", "LEVERAGE_REAL_MCP": "1",
                "STAND_IN_PORT": str(server.server_port),
            })
            facts_file = self.root / "client.json"
            if mode == "interrupt":
                until = time.monotonic() + 8
                while not facts_file.exists() and process.poll() is None and time.monotonic() < until:
                    time.sleep(0.02)
                if process.poll() is None:
                    process.send_signal(signal.SIGINT)
            output = self.read(process)
            self.assertEqual(process.returncode, expected, output)
            self.assertIn(reason, output)
            self.assertNotIn(SEAT_TOKEN, output)
            self.assertNotIn(REVIEWER_TOKEN, output)
            self.assertNotIn("stand-in-session-token", output)
            self.assertNotIn(PRIVATE_TEXT, output)
            self.assertNotRegex(output, r"(?m)^\+")
            self.assertNotIn("timeout", output.lower())
            self.assertTrue(facts_file.is_file(), "Claude shim did not see settings")
            facts = json.loads(facts_file.read_bytes())
            path = Path(facts["path"])
            self.assertFalse(path.exists())
            self.assertFalse(path.parent.exists())
            self.assertNotIn(SCRIPT.parents[1], path.parents)
            self.assertEqual(facts["mode"], 0o600)
            self.assertEqual(facts["parent_mode"], 0o700)
            self.assertTrue(facts["has_builder_token"])
            self.assertEqual(Path(facts["cwd"]), server.work_folder)
            self.assertTrue(facts["empty"])
            self.assertEqual(server.issued, {BUILDER: "mcp", REVIEWER: "http"})
            self.assertEqual(server.join_reads, 1)
            args = facts["args"]
            self.assertTrue(args[args.index("-p") + 1].startswith("Stand-in MCP join instructions."))
            self.assertTrue(args[args.index("-p") + 1].endswith(
                "Your user confirms these defaults. Take the one task that is waiting, finish it, submit it, and stop."
            ))
            self.assertEqual(args[args.index("--allowedTools") + 1], "mcp__leverage")
            self.assertEqual(args[args.index("--permission-mode") + 1], "acceptEdits")
            self.assertIn("--strict-mcp-config", args)
            self.assertIn("--no-session-persistence", args)
            self.assertNotIn("skip-permissions", " ".join(args))
            self.assertNotIn(SEAT_TOKEN, " ".join(args))
            self.assertNotIn(REVIEWER_TOKEN, " ".join(args))
            calls = (self.root / "calls").read_text().splitlines()
            self.assertEqual(calls.count("claude"), 1)
            self.assertFalse(any(name in calls for name in ("codex", "agy", "grok")))
            output_folder = Path(self.env["LEVERAGE_MCP_CHECK_OUT"])
            if expected == 0:
                self.assertEqual({p.name for p in output_folder.iterdir()}, {"events.json", "verify_log.txt"})
                for artifact in output_folder.iterdir():
                    contents = artifact.read_text()
                    self.assertNotIn(PRIVATE_TEXT, contents)
                    self.assertNotIn(SEAT_TOKEN, contents)
                    self.assertNotIn(REVIEWER_TOKEN, contents)
                self.assertIn("2025-06-18", output)
            else:
                self.assertFalse(output_folder.exists())
        finally:
            server.shutdown()
            server.server_close()
            thread.join()

    def test_success(self):
        self.exercise("success", 0, "passed")

    def test_success_with_no_denials(self):
        self.exercise("no_denials", 0, "passed")

    def test_stops_descendants_after_client_exit(self):
        self.exercise("orphan", 0, "passed")
        self.assertTrue((self.root / "orphan-stopped").exists())

    def test_failed_client(self):
        self.exercise("failure", 1, "client failed")

    def test_denied_structured(self):
        self.exercise("denied", 1, "MCP tool calls denied")

    def test_denied_text(self):
        self.exercise("denied_text", 1, "MCP tool calls denied")

    def test_interrupt(self):
        self.exercise("interrupt", 130, "interrupted")

    def test_actor_mismatch(self):
        self.exercise("wrong_actor", 1, "builder seat")

    def test_leak_prevents_publishing(self):
        self.exercise("leak", 1, "secret scan failed")


if __name__ == "__main__":
    unittest.main(verbosity=2)
PY
