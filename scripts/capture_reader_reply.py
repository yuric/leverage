"""Capture a provider usage reply outside git for the managing agent (RD-7).

The program is supplied explicitly. Read its output through a bounded pipe;
write only the scrubbed copy. No account file is opened by this script.
"""

import argparse
from itertools import islice
import json
import os
from pathlib import Path
import re
import runpy
import select
import signal
import subprocess
import tempfile
import time
import sys


COMMANDS = {
    "claude": [
        "-p", "/usage", "--output-format", "json", "--no-session-persistence",
        "--permission-mode", "dontAsk", "--strict-mcp-config", "--setting-sources", "user",
        "--tools", "",
    ],
    "codex": ["app-server"],
    "gemini": ["-p", "/usage", "--mode", "plan", "--output-format", "json", "--print-timeout", "15s"],
}
CODEX_CALLS = (
    {"id": 1, "method": "initialize"},
    {"method": "initialized"},
    {"id": 2, "method": "account/rateLimits/read"},
    {"id": 3, "method": "account/usage/read"},
)
MAX_OUTPUT = 1024 * 1024
FIXED_DATE = "2026-01-01T00:00:00Z"
FIXED_EPOCH = 1767225600
ID_OR_VALUE = "<scrubbed>"

# Only known structural names survive. Unknown names can be table keys and
# could themselves be account details. Known maps mask every key regardless.
STRUCTURAL_KEYS = set("""
    account accountId apiProvider availableCount authMethod balance cachedUsageUtilization
    clientInfo code codexHome configDirectory conversationId conversation_id cost
    createdAt credentialExpiresAt credential_expires_at credits currentStreakDays dailyUsageBuckets
    data description duration durationMs duration_api_ms duration_ms email error expiresAt expires_at
    fetchedAtMs five_hour grantedAt hasCredits id inputTokens input_tokens isError is_error jsonrpc
    lifetimeTokens limit limitId limitName loginExpiresAt longestRunningTurnSec longestStreakDays
    max message method model modelUsage models model_usage normalModelSlug numTurns num_turns orgId orgName
    organization organizationId organizations ordinaryUsageAllowed outputTokens output_tokens
    peakDailyTokens perModel per_model plan planTier planType platformFamily platformOs primary
    projectsDirectory rateLimitReachedType rateLimitResetCredits rateLimitUpsell rateLimits
    rateLimitsByLimitId remainingPercent remaining_percent requestId request_id requiresOpenaiAuth
    resetAt resetType resetsAt resets_at response result secondary sessionId session_id seven_day
    seven_day_opus seven_day_sonnet spendControlReached startDate status subtype subscriptionType
    summary threadId threadUsage thread_id title tokens totalCostUsd totalTokens total_cost_usd
    total_tokens turnCount turns type unlimited usage usageByModel usedPercent used_percent userAgent
    userId user_id utilization utilizationPercent uuid version weekly windowDurationMins
    window_duration_mins workspaceId workspaceName workspaces cedar_ember
    cache_creation_input_tokens cache_read_input_tokens
""".split()) | {call["method"] for call in CODEX_CALLS}
DATA_MAPS = {
    "modelUsage", "models", "model_usage", "organizations", "perModel", "per_model",
    "rateLimitsByLimitId", "usageByModel", "workspaces",
}
ENUMS = {
    "type": {"result", "error", "apiKey", "chatgpt", "amazonBedrock", "gcp"},
    "subtype": {"success", "error", "error_during_execution", "error_max_turns"},
    "status": {"available", "redeeming", "redeemed", "unknown", "SUCCESS", "ERROR"},
    "resetType": {"codexRateLimits", "unknown"},
    "platformFamily": {"unix", "windows"},
    "platformOs": {"macos", "linux", "windows"},
}
TOKEN_COUNTS = {
    "inputTokens", "input_tokens", "outputTokens", "output_tokens", "totalTokens", "total_tokens",
    "cache_creation_input_tokens", "cache_read_input_tokens", "tokens",
}
TURN_COUNTS = {"numTurns", "num_turns", "turnCount", "turns"}


class CaptureError(Exception):
    """A fixed diagnostic that is safe to print without tool output."""


class ToolOutput:
    def __init__(self, pipe):
        self.fd = pipe.fileno()
        self.pending = bytearray()
        self.total = 0
        self.framing = "none"

    def read(self, deadline):
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not select.select([self.fd], [], [], remaining)[0]:
            raise CaptureError("tool reply timed out")
        chunk = os.read(self.fd, 65536)
        self.total += len(chunk)
        if self.total > MAX_OUTPUT:
            raise CaptureError("tool reply exceeded the capture limit")
        return chunk

    def object_line(self, deadline):
        while True:
            if self.pending:
                first = bytes(self.pending[:32]).lstrip().lower()
                if first.startswith(b"content-length:"):
                    self.framing = "content-length"
                    raise CaptureError("tool uses different message framing")
                if self.framing == "none":
                    self.framing = "unknown"
            offset = self.pending.find(b"\n")
            if offset >= 0:
                line = bytes(self.pending[:offset])
                del self.pending[:offset + 1]
                value = parse_json(line)
                if not isinstance(value, dict):
                    self.framing = "unknown"
                    raise CaptureError("tool did not return one JSON object per line")
                self.framing = "jsonl"
                return value
            chunk = self.read(deadline)
            if not chunk:
                raise CaptureError("tool closed output before completing the session")
            self.pending.extend(chunk)


def parse_json(raw):
    try:
        return json.loads(raw)
    except (ValueError, RecursionError):
        return None


def mac_version():
    source = Path(__file__).resolve().parents[1] / "mac/Sources/LeverageKit/HealthLine.swift"
    match = re.search(r'^public let leverageMacVersion = "([0-9.]+)"$', source.read_text(encoding="utf-8"),
                      re.MULTILINE)
    if not match:
        raise CaptureError("could not find the Mac version for initialize")
    return match[1]


def app_server(process, output, version):
    replies = {}
    start = time.monotonic()
    try:
        for request in CODEX_CALLS:
            if request["method"] == "initialize":
                request = {**request, "params": {"clientInfo": {"name": "leverage", "version": version}}}
            process.stdin.write(json.dumps(request, ensure_ascii=True).encode() + b"\n")
            process.stdin.flush()
            if "id" not in request:
                continue
            deadline = start + (5 if request["method"] == "initialize" else 20)
            while True:
                reply = output.object_line(deadline)
                # A message from the server can use an overlapping id.
                if "method" in reply or reply.get("id") != request["id"]:
                    continue
                if "error" in reply or not isinstance(reply.get("result"), dict):
                    raise CaptureError("app-server refused a usage request")
                replies[request["method"]] = reply
                break
    finally:
        print(f"framing: {output.framing}")
    return replies, output.framing


def one_shot(output, provider):
    deadline = time.monotonic() + (30 if provider == "claude" else 20)
    raw = bytearray()
    while chunk := output.read(deadline):
        raw.extend(chunk)
    if not raw.strip():
        print("framing: none")
        raise CaptureError("tool returned no reply")
    reply = parse_json(raw)
    framing = "json" if reply is not None else "text"
    print(f"framing: {framing}")
    return (reply if reply is not None else raw.decode("utf-8", errors="replace")), framing


def tool_environment(tool, work):
    env = {key: os.environ[key] for key in ("HOME", "LANG", "USER") if key in os.environ}
    home = env.get("HOME")
    folders = [str(tool.parent)]
    if home:
        folders.append(str(Path(home) / ".local" / "bin"))
    folders.extend(("/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"))
    env["PATH"] = os.pathsep.join(dict.fromkeys(folders))
    env["TMPDIR"] = str(work)
    return env


def capture(tool, provider, work):
    version = mac_version() if provider == "codex" else None
    process = subprocess.Popen(
        [tool, *COMMANDS[provider]], cwd=work, env=tool_environment(tool, work),
        stdin=subprocess.PIPE if provider == "codex" else subprocess.DEVNULL,
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, start_new_session=True,
    )
    try:
        output = ToolOutput(process.stdout)
        if provider == "codex":
            return app_server(process, output, version)
        return one_shot(output, provider)
    finally:
        # Close the session's input before ending the process group. A
        # deadline or a stopped capture must leave no session running.
        if process.stdin is not None:
            try:
                process.stdin.close()
            except BrokenPipeError:
                pass
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        except PermissionError:
            # Darwin can report EPERM for a group whose leader has exited.
            if process.poll() is None:
                process.kill()
        process.wait()
        process.stdout.close()


def model_evidence(value):
    """Return whether a structured reply reports prompt tokens or a model turn."""
    tokens, turn = False, False
    if isinstance(value, dict):
        for key, child in value.items():
            positive = type(child) in (int, float) and child > 0
            tokens |= key in TOKEN_COUNTS and (positive or isinstance(child, str)
                                                and re.fullmatch(r"[0-9]+", child) is not None
                                                and bool(child.strip("0")))
            turn |= ((key in TURN_COUNTS and positive)
                     or (key == "model" and isinstance(child, str) and bool(child.strip()))
                     or (key in {"modelUsage", "model_usage"} and isinstance(child, dict) and bool(child)))
            child_tokens, child_turn = model_evidence(child)
            tokens |= child_tokens
            turn |= child_turn
    elif isinstance(value, list):
        for child in value:
            child_tokens, child_turn = model_evidence(child)
            tokens |= child_tokens
            turn |= child_turn
    elif isinstance(value, str) and value.lstrip().startswith(("{", "[")):
        embedded = parse_json(value)
        if embedded is not None:
            return model_evidence(embedded)
    return tokens, turn or tokens


def sample_value(value, key, sensitive):
    if isinstance(value, str):
        if sensitive:
            return ID_OR_VALUE
        if value in ENUMS.get(key, ()):
            return value
        if re.fullmatch(r"\d{4}-\d\d-\d\d[Tt ][\d:.]+(?:[Zz]|[+-][\d:]+)", value):
            return FIXED_DATE
        if re.fullmatch(r"\d{4}-\d\d-\d\d", value):
            return FIXED_DATE[:10]
        if re.fullmatch(r"[+-]?\d+", value):
            if len(value) in (10, 13):
                return str(FIXED_EPOCH * (1000 if len(value) == 13 else 1))
            return "7" if value.strip("+-0") else "0"
        if re.fullmatch(r"[+-]?\d+\.\d+", value):
            return "7.5"
        return ID_OR_VALUE
    if type(value) is int:
        if sensitive:
            return 0
        if key in {"windowDurationMins", "window_duration_mins"} and value in (300, 10080):
            return value
        if key.endswith(("At", "_at", "AtMs")):
            return FIXED_EPOCH * (1000 if key.endswith("Ms") else 1)
        return 7 if value else 0
    if isinstance(value, float):
        if not sensitive and key.endswith(("At", "_at", "AtMs")):
            return float(FIXED_EPOCH * (1000 if key.endswith("Ms") else 1))
        return 0.0 if sensitive or value == 0 else 7.5
    return value


def scrub(reply, is_sensitive):
    replaced = []

    def redact(value, path, key=None, depth=0):
        if depth > 64:
            raise CaptureError("tool reply nested too deeply")
        sensitive = key is not None and is_sensitive(key)
        if isinstance(value, dict):
            result = {}
            for index, (name, child) in enumerate(value.items(), 1):
                safe_key = name if key not in DATA_MAPS and name in STRUCTURAL_KEYS else f"<key:{index}>"
                child_path = f"{path}.{safe_key}"
                if safe_key != name:
                    replaced.append(child_path + " (key)")
                result[safe_key] = redact(child, child_path, name, depth + 1)
            return result
        if isinstance(value, list):
            return [redact(child, f"{path}[{index}]", key, depth + 1)
                    for index, child in enumerate(value)]
        if isinstance(value, str) and not sensitive and value.lstrip().startswith(("{", "[")):
            embedded = parse_json(value)
            if isinstance(embedded, (dict, list)):
                return json.dumps(redact(embedded, path, key, depth + 1), ensure_ascii=True)
        sampled = sample_value(value, key or "", sensitive)
        if sampled != value or type(value) in (int, float):
            replaced.append(path)
        return sampled

    return redact(reply, "reply"), replaced


def shape(value, label="reply"):
    names = {dict: "object", list: "array", str: "string", int: "integer",
             float: "number", bool: "boolean", type(None): "null"}
    yield f"{label}: {names[type(value)]}"
    if isinstance(value, dict):
        for key, child in value.items():
            display = "<key>" if key.startswith("<key:") else key
            yield from shape(child, f"{label}.{display}")
    elif isinstance(value, list):
        for child in value:
            yield from shape(child, f"{label}[]")


def checks(args):
    if "CI" in os.environ:
        raise CaptureError("usage capture is disabled when CI is set")
    if os.environ.get("LEVERAGE_REAL_PROVIDER") != args.provider:
        raise CaptureError("LEVERAGE_REAL_PROVIDER must name the requested provider")
    if not args.tool.is_absolute():
        raise CaptureError("--tool must be an absolute path")
    absolute = args.out.absolute()
    out = absolute.resolve()
    for path in (absolute, out):
        if any(os.path.lexists(parent / ".git") for parent in (path, *path.parents)):
            raise CaptureError("--out must be outside every git work tree")
    if not args.tool.is_file() or not os.access(args.tool, os.X_OK):
        raise CaptureError("--tool must name an executable program file")
    return out


def save_copy(out, provider, reply, framing, spent):
    checker = Path(__file__).with_name("check_reply_fixtures.py")
    safe_reply, replaced = scrub(reply, runpy.run_path(str(checker))["usage_named_field"])
    copy = {
        "meta": {"provider": provider, "basis": "recorded_scrubbed", "framing": framing,
                 "cost": "model_turn" if spent else "none", "replaced": replaced},
        "reply": safe_reply,
    }
    # NamedTemporaryFile creates a private file exclusively, so an existing
    # output cannot redirect or be replaced by this capture.
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=out,
                                     prefix=f"{provider}-", suffix=".json", delete=False) as handle:
        try:
            json.dump(copy, handle, indent=2, ensure_ascii=True, allow_nan=False)
            handle.write("\n")
            handle.flush()
        except BaseException:
            Path(handle.name).unlink()
            raise
    for line in islice(shape(safe_reply), 200):
        print(line)


def stop_capture(_signal, _frame):
    raise KeyboardInterrupt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("provider", choices=COMMANDS)
    parser.add_argument("--tool", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()
    signal.signal(signal.SIGTERM, stop_capture)
    try:
        out = checks(args)
        out.mkdir(mode=0o700, parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="work-", dir=out) as work:
            reply, framing = capture(args.tool, args.provider, Path(work))
        tokens, turn = model_evidence(reply) if args.provider != "codex" else (False, False)
        if args.provider == "claude":
            print("model turn: " + ("yes" if turn else "no"))
        if args.provider == "gemini":
            print("prompt tokens: " + ("yes" if tokens else "no"))
        save_copy(out, args.provider, reply, framing, turn if args.provider == "claude" else tokens)
    except CaptureError as error:
        print(f"capture: {error}", file=sys.stderr)
        return 1
    except (OSError, ValueError, RuntimeError, KeyboardInterrupt):
        print("capture: could not complete the usage capture", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
