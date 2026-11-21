#!/usr/bin/env bash
# The managing agent's one-task MCP check (milestone 5, §5.4).
# LEVERAGE_REAL_MCP=1 LEVERAGE_REAL_PROVIDER=claude scripts/real_mcp_run.sh claude
# Optional: API_IMAGE_TAG to reuse an API image, LEVERAGE_E2E_SCRATCH for
# the Swift build, LEVERAGE_MCP_CHECK_OUT for the two verified artifacts.
# Exit 2 for a refusal, 3 if Claude is absent, 1 for failure, 130 for an
# interrupt. CI presence, including an empty value, always refuses.
{ set +x; } 2>/dev/null
set -euo pipefail

refuse() { printf 'real_mcp_run: refused: %s\n' "$1" >&2; exit 2; }
if [ "${CI+set}" = set ]; then
  refuse "CI is set"
fi
if [ "$#" -ne 1 ] || [ "${1:-}" != claude ]; then
  refuse "usage: LEVERAGE_REAL_MCP=1 LEVERAGE_REAL_PROVIDER=claude scripts/real_mcp_run.sh claude"
fi
if [ "${LEVERAGE_REAL_MCP:-}" != 1 ]; then
  refuse "set LEVERAGE_REAL_MCP=1"
fi
if [ "${LEVERAGE_REAL_PROVIDER:-}" != claude ]; then
  refuse "set LEVERAGE_REAL_PROVIDER=claude"
fi

exec python3 -I - "$0" <<'PY'
import json
import os
from pathlib import Path
import re
import secrets
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from urllib.error import HTTPError, URLError
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener
import uuid

ROOT = Path(sys.argv[1]).resolve().parents[1]
TITLE = "MCP developer check"
CRITERION = "Create a file named hello.txt that contains the word ready"
BUILDER_EVENTS = ("task.claimed", "criterion.started", "criterion.passed", "task.submitted")
CLIENT_LIMIT = 600

interrupted = False


class Failed(Exception):
    """Carries only fixed, safe failure messages."""


class Interrupted(Exception):
    pass


def request_stop(*_args):
    global interrupted
    interrupted = True


def check_stop():
    if interrupted:
        raise Interrupted


def say(message):
    print(f"real_mcp_run: {message}", file=sys.stderr, flush=True)


def stop(child):
    # Signal the process group so the MCP server opened by Claude ends too.
    # Each process is started in a new session below.
    if child.poll() is not None:
        return
    try:
        os.killpg(child.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    except PermissionError:
        # On macOS the child may have just exited but still need reaping.
        child.wait(timeout=5)
        return
    try:
        child.wait(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(child.pid, signal.SIGKILL)
        child.wait()


class LocalOnly(HTTPRedirectHandler):
    def redirect_request(self, *_args, **_kwargs):
        return None


class Owner:
    def __init__(self, address):
        self.address = address
        self.http = build_opener(ProxyHandler({}), LocalOnly())
        self.token = None

    def request(self, path, *, post=False, body=None):
        check_stop()
        headers = {}
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        if post:
            headers["Idempotency-Key"] = str(uuid.uuid4())
        encoded = None
        if body is not None:
            headers["Content-Type"] = "application/json"
            encoded = json.dumps(body).encode()
        request = Request(self.address + path, data=encoded, headers=headers, method="POST" if post else "GET")
        try:
            with self.http.open(request, timeout=5) as response:
                if response.status != 200:
                    raise Failed("the API returned an unexpected status")
                return json.load(response)
        except HTTPError as error:
            raise Failed(f"the API returned HTTP {error.code}") from None
        except (URLError, TimeoutError, ValueError):
            raise Failed("the API request did not return JSON") from None

    def command(self, path, body=None):
        response = self.request(f"/v1/owner/{path}", post=True, body=body)
        if response["outcome"] != "completed":
            raise Failed("an owner command did not complete")
        return response["result"]

    def read(self, path):
        return self.request(f"/v1/owner/{path}")


def denied(output):
    # Claude's JSON result reports denied tool names. Also handle a denial
    # emitted as a diagnostic while the client is still waiting.
    try:
        result = json.loads(output)
    except ValueError:
        result = None
    if isinstance(result, dict):
        for item in result.get("permission_denials") or []:
            if isinstance(item, dict) and re.fullmatch(
                r"mcp__leverage(?:__[A-Za-z0-9_]+)?", str(item.get("tool_name"))
            ):
                return True
    text = output.decode("utf-8", errors="replace")
    tool = r"(?:mcp__leverage(?:__\w+)?|MCP tool(?: call)?s?)"
    refusal = r"(?:denied|not allowed|not permitted)"
    return bool(re.search(rf"{tool}[^\r\n]{{0,160}}{refusal}|{refusal}[^\r\n]{{0,160}}{tool}", text, re.I))


def check_client(child, deadline):
    stdout, stderr = bytearray(), bytearray()
    streams = {child.stdout: stdout, child.stderr: stderr}
    while streams:
        check_stop()
        if time.monotonic() >= deadline:
            raise Failed("the client exceeded the 600-second limit")
        for stream in select.select(list(streams), [], [], 0.15)[0]:
            data = os.read(stream.fileno(), 65536)
            if not data:
                del streams[stream]
                continue
            streams[stream].extend(data)
            if len(stdout) + len(stderr) > 4 * 1024 * 1024:
                raise Failed("the client exceeded the output limit")
            if denied(streams[stream]):
                raise Failed("MCP tool calls denied")
    while child.poll() is None:
        check_stop()
        if time.monotonic() >= deadline:
            raise Failed("the client exceeded the 600-second limit")
        time.sleep(0.05)
    try:
        result = json.loads(stdout)
    except ValueError:
        result = {}
    if child.returncode != 0 or not isinstance(result, dict) or result.get("is_error") is not False:
        raise Failed("the client failed")


def task_events(owner, task, builder):
    wanted = list(BUILDER_EVENTS)
    evidence = []
    cursor = 0
    while True:
        page = owner.read(f"events?after_seq={cursor}&limit=500&wait=0")
        for event in page["events"]:
            if event["task_id"] == task and event["type"] in BUILDER_EVENTS:
                if (not wanted or event["type"] != wanted[0]
                        or event["actor_kind"] != "seat" or event["actor_id"] != builder):
                    raise Failed("unexpected event order or builder seat")
                wanted.pop(0)
            evidence.append({key: event[key] for key in ("seq", "type", "task_id", "actor_kind", "actor_id")})
        if len(page["events"]) < 500:
            break
        if page["next_after_seq"] <= cursor:
            raise Failed("the event cursor did not advance")
        cursor = page["next_after_seq"]
    if wanted:
        raise Failed("the builder seat's task events are incomplete")
    return evidence


class Check:
    def __init__(self, folder, claude):
        self.folder = folder
        self.claude = claude
        self.environment = os.environ.copy()
        self.environment["COMPOSE_PROJECT_NAME"] = f"leverage-real-mcp-{os.getpid()}"
        self.own_image = not self.environment.get("API_IMAGE_TAG")
        if self.own_image:
            self.environment["API_IMAGE_TAG"] = self.environment["COMPOSE_PROJECT_NAME"]
        self.compose = ["docker", "compose"]
        env_file = ROOT / ".env"
        self.compose += ["--env-file", str(env_file if env_file.is_file() else ROOT / ".env.example")]
        self.compose += ["-f", str(ROOT / "compose.yaml"), "-f", str(ROOT / "compose.test.yaml")]
        self.scratch = Path(os.environ.get("LEVERAGE_E2E_SCRATCH") or folder / "build").resolve()
        self.compose_started = False
        self.reviewer = None

    def progress(self, message):
        with (self.folder / "script.log").open("a") as log:
            print(f"real_mcp_run: {message}", file=log)
        say(message)

    def command(self, args, description, *, cwd=ROOT, env=None, timeout=120, body=None,
                cleanup=False, stderr=subprocess.STDOUT):
        if not cleanup:
            check_stop()
        with subprocess.Popen(
            args, cwd=cwd, env=self.environment if env is None else env, start_new_session=True,
            stdin=subprocess.DEVNULL if body is None else subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=stderr,
        ) as child:
            deadline = time.monotonic() + timeout
            try:
                while time.monotonic() < deadline:
                    if not cleanup:
                        check_stop()
                    try:
                        output = child.communicate(input=body, timeout=0.2)[0]
                    except subprocess.TimeoutExpired:
                        # communicate retains the pending input between calls.
                        body = None
                        continue
                    if child.returncode:
                        raise Failed(f"{description} failed")
                    return output
                raise Failed(f"{description} exceeded its time limit")
            finally:
                if child.returncode is None:
                    stop(child)

    def clean(self):
        if self.reviewer:
            stop(self.reviewer)
            self.reviewer = None
        if self.compose_started:
            self.command(self.compose + ["down", "--volumes", "--remove-orphans"],
                         "Compose cleanup", cleanup=True)
            if self.own_image:
                try:
                    self.command(["docker", "image", "rm", "leverage-api:" + self.environment["API_IMAGE_TAG"]],
                                 "image cleanup", cleanup=True)
                except Failed:
                    pass

    def products(self):
        swift = ["swift", "build", "--scratch-path", str(self.scratch), "--manifest-cache", "local"]
        env = {**self.environment, "LEVERAGE_ONLY": "e2e"}
        for name in ("LeverageMCP", "LeverageRunner"):
            self.command(swift + ["--product", name], "Swift build", cwd=ROOT / "mac", env=env, timeout=600)
        output = self.command(swift + ["--show-bin-path"], "Swift build path",
                              cwd=ROOT / "mac", env=env, stderr=subprocess.DEVNULL)
        binary_dir = Path(output.decode().strip())
        if not binary_dir.is_absolute():
            raise Failed("Swift did not return an absolute build path")
        return binary_dir

    def start_reviewer(self, binary, address, token):
        standins = self.folder / "stand-ins"
        shutil.copytree(ROOT / "mac/Tests/StandIns", standins)
        settings = self.folder / "reviewer-settings"
        settings.mkdir()
        (settings / ".standin-signed-in").touch()
        env = {name: os.environ[name] for name in ("PATH", "LANG", "USER")
               if name in os.environ}
        env.update(HOME=str(self.folder), TMPDIR=str(self.folder), LEVERAGE_API_URL=address,
                   LEVERAGE_SEAT_TOKEN=token, LEVERAGE_SEAT_ROLE="reviewer", LEVERAGE_PROVIDER="codex",
                   LEVERAGE_TOOL_DIR=str(standins / "bin"), LEVERAGE_TOOL_PATH=str(standins / "bin/codex"),
                   LEVERAGE_SETTINGS_DIR=str(settings), LEVERAGE_SUPPORT_DIR=str(self.folder / "support"),
                   LEVERAGE_WORK_ROOT=str(self.folder / "review-work"), LEVERAGE_TOOL_TIMEOUT_SECONDS="60")
        with (self.folder / "reviewer.log").open("wb") as log:
            self.reviewer = subprocess.Popen([binary], env=env, stdin=subprocess.DEVNULL,
                                             stdout=log, stderr=log, start_new_session=True)

    def run_client(self, mcp, address, token, prompt, work, deadline):
        config = self.folder / "mcp.json"
        # The shell redirects only the server's stderr, because a client
        # may consume it internally. The built server still owns stdout.
        settings = {"mcpServers": {"leverage": {
            "command": "/bin/sh", "args": ["-c", 'exec "$1" 2>>"$2"', "LeverageMCP",
                                           str(mcp), str(self.folder / "mcp.log")],
            "env": {"LEVERAGE_API_URL": address, "LEVERAGE_SEAT_ROLE": "builder", "LEVERAGE_SEAT_TOKEN": token},
        }}}
        with os.fdopen(os.open(config, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as file:
            json.dump(settings, file)
        try:
            check_stop()
            prompt = prompt.rstrip() + (
                "\n\nYour user confirms these defaults. Take the one task that is waiting, finish it, submit it, and stop."
            )
            args = [self.claude, "-p", prompt, "--output-format", "json", "--no-session-persistence",
                    "--permission-mode", "acceptEdits", "--strict-mcp-config", "--setting-sources", "user",
                    "--mcp-config", str(config), "--allowedTools", "mcp__leverage"]
            # Match the tool driver's basic login environment. Pass no seat
            # token or opt-in switches to Claude. The MCP settings own the
            # builder token and only the reviewer process gets its own.
            env = {name: os.environ[name] for name in
                   ("HOME", "TMPDIR", "LANG", "USER", "PATH")
                   if name in os.environ}
            with subprocess.Popen(args, cwd=work, env=env, start_new_session=True,
                                  stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE) as child:
                try:
                    check_client(child, deadline)
                finally:
                    if child.returncode is None:
                        stop(child)
        finally:
            config.unlink(missing_ok=True)

    def run(self):
        self.progress("building the MCP server and reference runner")
        binary = self.products()
        self.progress("starting the temporary Compose project")
        self.compose_started = True
        up = ["up", "-d", "--wait", "--wait-timeout", "300"]
        if self.own_image:
            up.append("--build")
        self.command(self.compose + up + ["db", "api", "sweep"], "Compose startup", timeout=600)
        port = self.command(self.compose + ["port", "api", "3000"], "Compose port lookup").decode().strip()
        if not re.fullmatch(r"127\.0\.0\.1:[0-9]{1,5}", port) or port.endswith(":3000"):
            raise Failed("Compose did not publish a dynamic loopback port")
        address = "http://" + port
        owner = Owner(address)
        owner.request("/v1/health")
        password = secrets.token_urlsafe(24)
        owner.token = owner.command("setup", {"email_address": "owner@example.invalid",
                                               "password": password})["session_token"]
        for row in owner.read("rules")["rules"]:
            rule = row["rule"]
            if rule["enabled"]:
                owner.command(f"rules/{rule['id']}/disable")
        builder = owner.command("seats", {"name": "MCP builder", "role": "builder", "provider": "claude"})
        reviewer = owner.command("seats", {"name": "Stand-in reviewer", "role": "reviewer", "provider": "codex"})
        landing = owner.read(f"seats/{builder['seat_id']}/landing-prompt?connection=mcp")
        if landing["connection"] != "mcp":
            raise Failed("the API did not return an MCP landing prompt")
        work = self.folder / "work"
        work.mkdir()
        task = owner.command("tasks", {"title": TITLE, "goal": CRITERION, "state": "backlog"})["task_id"]
        owner.command(f"tasks/{task}/complete-contract", {
            "title": TITLE, "goal": CRITERION, "details": None, "work_reference": str(work),
            "criteria": [{"text": CRITERION, "kind": "build"}], "actions": [],
            "minimum_strength_rank": None, "budget_cap": None,
        })
        self.start_reviewer(binary / "LeverageRunner", address, reviewer["seat_token"])
        self.progress("running one Claude MCP client")
        deadline = time.monotonic() + CLIENT_LIMIT
        self.run_client(binary / "LeverageMCP", address, builder["seat_token"], landing["text"], work, deadline)
        while time.monotonic() < deadline:
            if owner.read(f"tasks/{task}")["task"]["state"] == "done":
                break
            if self.reviewer.poll() is not None:
                raise Failed("the stand-in reviewer exited before the task reached Done")
            time.sleep(0.25)
        else:
            raise Failed("the task did not reach Done within 600 seconds")
        hello = work / "hello.txt"
        if hello.is_symlink() or not hello.is_file() or hello.stat().st_size > 4096:
            raise Failed("the work folder did not contain the expected hello.txt")
        if not re.search(rb"\bready\b", hello.read_bytes()):
            raise Failed("hello.txt did not contain the expected word")
        evidence = task_events(owner, task, builder["seat_id"])
        stop(self.reviewer)
        self.reviewer = None
        self.progress("replaying the workspace log")
        results = self.folder / "results"
        results.mkdir()
        (results / "events.json").write_text(json.dumps(evidence, indent=2) + "\n")
        (results / "verify_log.txt").write_bytes(self.command(
            self.compose + ["exec", "-T", "api", "bin/rails", "leverage:verify_log"], "leverage:verify_log"))
        (self.folder / "containers.log").write_bytes(self.command(
            self.compose + ["logs", "--no-color"], "Compose logs"))
        mcp_log = self.folder / "mcp.log"
        logs = [mcp_log, self.folder / "reviewer.log", self.folder / "containers.log", self.folder / "script.log"]
        scan = [sys.executable, "-I", str(ROOT / "scripts/secret_scan.py"), "--secrets", "/dev/stdin"]
        for path in logs:
            scan += ["--logs", str(path), str(path)]
        scan += [str(results)]
        known = [password, owner.token, builder["seat_token"], reviewer["seat_token"]]
        self.progress("scanning the logs and artifacts")
        self.command(scan, "secret scan", body=("\n".join(known) + "\n").encode())
        match = re.search(r"^\S+ mcp info: MCP initialize protocol revision (\d{4}-\d{2}-\d{2})$",
                          mcp_log.read_text(), re.MULTILINE)
        if not match:
            raise Failed("the MCP protocol revision was not recorded")
        return results, match[1]


def main():
    os.umask(0o077)
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, request_stop)
    claude = shutil.which("claude")
    if not claude or not Path(claude).is_absolute():
        say("skipped: Claude is not installed on PATH")
        return 3
    try:
        with tempfile.TemporaryDirectory(prefix="leverage-real-mcp-", dir="/tmp") as temporary:
            folder = Path(temporary).resolve()
            if ROOT == folder or ROOT in folder.parents:
                raise Failed("the temporary directory is inside the repository")
            out = os.environ.get("LEVERAGE_MCP_CHECK_OUT")
            destination = Path(out).resolve() if out else None
            if destination and destination.exists():
                raise Failed("the output directory already exists")
            check = Check(folder, claude)
            try:
                results, revision = check.run()
            finally:
                check.clean()
            check_stop()
            if destination is None:
                destination = Path(tempfile.mkdtemp(prefix="leverage-real-mcp-results-", dir="/tmp"))
                for artifact in results.iterdir():
                    shutil.copyfile(artifact, destination / artifact.name)
            else:
                shutil.copytree(results, destination)
            say(f"passed (MCP protocol revision {revision}); artifacts: {destination}")
            return 0
    except Interrupted:
        say("interrupted")
        return 130
    except Failed as error:
        say(str(error))
    except (OSError, KeyError, ValueError, TypeError, AttributeError, subprocess.SubprocessError):
        say("the check could not read or write an expected value")
    return 1


sys.exit(main())
PY
