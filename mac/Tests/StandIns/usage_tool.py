"""Usage commands for the provider stand-ins (RD-8)."""

import json
import os
from pathlib import Path
import select
import signal
import sys
import tempfile
import time


CODEX_METHODS = {"initialize", "account/read", "account/rateLimits/read", "account/usage/read"}
WAIT_LIMIT_SECONDS = 600
MAX_LINE = 1024 * 1024


def reply_file(replies, provider, relative):
    root = (Path(replies) / provider).resolve()
    path = (Path(replies) / relative).resolve()
    if path.parent != root or not path.name.startswith("usage-") or path.suffix != ".json":
        raise ValueError("expected a usage reply in the tool's reply folder")
    return json.loads(path.read_text(encoding="utf-8"))


def claude_usage(replies, directive, account):
    if directive.get("never_answers"):
        wait_for_stop()
        return 0
    if directive.get("settings") and account:
        value = reply_file(replies, "claude", directive["settings"])["settings"]
        place_settings(account, value, directive.get("stale_settings", False))
    if not directive.get("reply"):
        return None
    reply = reply_file(replies, "claude", directive["reply"])
    sys.stdout.write(reply["stdout"])
    sys.stderr.write(reply["stderr"])
    return reply["exit_status"]


def place_settings(account, value, stale):
    cache = value.get("cachedUsageUtilization")
    if isinstance(cache, dict) and "fetchedAtMs" in cache:
        age_ms = 11 * 60 * 1000 if stale else 0
        cache["fetchedAtMs"] = int(time.time() * 1000) - age_ms
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=account,
                                     prefix=".standin-settings-", delete=False) as handle:
        temporary = Path(handle.name)
        try:
            json.dump(value, handle)
            handle.write("\n")
            handle.flush()
            temporary.replace(Path(account) / ".claude.json")
        finally:
            temporary.unlink(missing_ok=True)


def caller_alive(parent, deadline):
    return parent != 1 and os.getppid() == parent and time.monotonic() < deadline


def wait_for_stop():
    stopped = False

    def stop(_number, _frame):
        nonlocal stopped
        stopped = True

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    parent = os.getppid()
    deadline = time.monotonic() + WAIT_LIMIT_SECONDS
    while not stopped and caller_alive(parent, deadline):
        time.sleep(0.05)


def received_lines():
    """Bound the wait between parent checks, including on partial lines."""
    parent = os.getppid()
    deadline = time.monotonic() + WAIT_LIMIT_SECONDS
    pending = bytearray()
    while caller_alive(parent, deadline):
        if not select.select([sys.stdin], [], [], 0.1)[0]:
            continue
        chunk = os.read(sys.stdin.fileno(), 65536)
        if not chunk:
            return
        pending.extend(chunk)
        while (offset := pending.find(b"\n")) >= 0:
            if offset > MAX_LINE:
                raise ValueError("app-server request exceeded the line limit")
            yield bytes(pending[:offset])
            del pending[:offset + 1]
        if len(pending) > MAX_LINE:
            raise ValueError("app-server request exceeded the line limit")


def send(message):
    print(json.dumps(message, separators=(",", ":")), flush=True)


def app_server(replies, directive, account, signed_in, record):
    rel = directive.get("reply")
    if not rel:
        rel = "codex/usage-both-windows.json" if signed_in else "codex/usage-signed-out.json"
    fixture = reply_file(replies, "codex", rel) if not directive.get("never_answers") else None
    for line in received_lines():
        try:
            request = json.loads(line)
        except ValueError:
            request = None
        if not isinstance(request, dict):
            send({"id": None, "error": {"code": -32700, "message": "Invalid request"}})
            continue
        record(request)
        method = request.get("method")
        if method == "initialized" and "id" not in request:
            continue
        if not isinstance(method, str) or method not in CODEX_METHODS:
            send({"id": request.get("id"), "error": {"code": -32601, "message": "Unknown method"}})
            continue
        if fixture is None:
            wait_for_stop()
            return 0
        response = fixture["session"][method]
        if method == "initialize":
            for unsolicited in fixture.get("server_messages", []):
                send(unsolicited)
            contents = response.get("result", {})
            if contents.get("codexHome") == "<scrubbed>":
                contents["codexHome"] = directive.get("codex_home") or account or str(Path.home() / ".codex")
        send({**response, "id": request.get("id")})
    return 0


def dispatch(tool, argv, directives, replies, account, signed_in, record):
    directive = next((
        entry for entry in directives if entry.get("tool") == tool
        and (os.path.realpath(entry["account"]) if entry.get("account") else None) == account
    ), {})
    if argv == ["--version"]:
        if "version" in directive:
            print(directive["version"])
            return 0
        return None
    if tool == "codex":
        return app_server(replies, directive, account, signed_in, record)
    if directive:
        return claude_usage(replies, directive, account)
    return None
