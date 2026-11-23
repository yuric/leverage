"""Serve made token-provider replies on IPv4 loopback.

Run with --scenario <file> and --port-file <new file>. The scenario's
"tokens" maps LVRG-TOKEN markers to {"reply": "<provider>/usage-<case>.json"}
or {"never_answers": true}. Requests use the latest scenario. The server
records method, endpoint and allowlisted headers beside it in calls.jsonl.
Only the fake marker survives from the authorization value.
"""

import argparse
from functools import lru_cache
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import socketserver
import json
import os
from pathlib import Path
import re
import stat
import tempfile
import threading

REPLIES = Path(__file__).resolve().parent / "replies"
ENDPOINTS = {
    "openrouter": "/api/v1/key",
    "claude_api": "/v1/models",
    "openai_api": "/v1/models",
    "gemini_api": "/v1beta/models",
    "grok_api": "/v1/api-key",
}
AUTH_HEADERS = ("authorization", "x-goog-api-key")
ANTHROPIC_VERSION = "2026-10-21"
TOKEN = re.compile(r"LVRG-TOKEN-[0-9a-fA-F]{12}(?![0-9a-fA-F])")
FIXTURE = re.compile(r"([a-z_]+)/usage-[a-z0-9-]+\.json")
METHODS = {"GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS", "CONNECT", "TRACE"}


def regular_open(path, flags, mode):
    """Open a test file without following a symlink or blocking on a FIFO."""
    fd = os.open(path, flags | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    try:
        details = os.fstat(fd)
        if not stat.S_ISREG(details.st_mode):
            raise ValueError("expected a regular file")
        if flags & os.O_WRONLY and details.st_nlink != 1:
            raise ValueError("request record must not be a hard link")
        return os.fdopen(fd, mode, encoding="utf-8")
    except BaseException:
        os.close(fd)
        raise


@lru_cache(maxsize=None)
def fixture(name):
    match = FIXTURE.fullmatch(name)
    if not match or match[1] not in ENDPOINTS:
        raise ValueError("expected a provider usage fixture")
    path = REPLIES / name
    if path.resolve() != path:
        raise ValueError("fixture must be in its provider directory")
    with regular_open(path, os.O_RDONLY, "r") as handle:
        return match[1], json.load(handle)


def read_scenario(path):
    with regular_open(path, os.O_RDONLY, "r") as handle:
        scenario = json.load(handle)
    tokens = scenario.get("tokens") if isinstance(scenario, dict) else None
    if not isinstance(tokens, dict):
        raise ValueError("scenario must map tokens to directives")

    for marker, directive in tokens.items():
        if not TOKEN.fullmatch(marker) or not isinstance(directive, dict):
            raise ValueError("invalid token directive")
        if set(directive) == {"reply"} and isinstance(directive["reply"], str):
            fixture(directive["reply"])
        elif directive != {"never_answers": True} or directive["never_answers"] is not True:
            raise ValueError("expected a single reply or never_answers directive")
    return tokens


def publish_port(path, port):
    # A reader can open the finished port file as soon as it appears.
    with tempfile.NamedTemporaryFile(dir=path.parent) as temporary:
        temporary.write(f"{port}\n".encode("ascii"))
        temporary.flush()
        os.link(temporary.name, path)


class ProviderServer(ThreadingHTTPServer):
    def __init__(self, scenario_path):
        self.scenario_path = scenario_path
        self.calls_path = scenario_path.with_name("calls.jsonl")
        self.calls_lock = threading.Lock()
        super().__init__(("127.0.0.1", 0), ProviderRequest)
        self.timeout = 0.25

    def server_bind(self):
        # HTTPServer.server_bind asks socket.getfqdn for the host's name: a
        # reverse lookup that can take many seconds on a CI runner. The
        # stand-in serves 127.0.0.1 only, so it names itself so.
        socketserver.TCPServer.server_bind(self)
        self.server_name = "127.0.0.1"
        self.server_port = self.server_address[1]

    def record(self, method, path, headers):
        entry = {"method": method, "path": path, "headers": headers}
        with self.calls_lock:
            with regular_open(self.calls_path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, "a") as handle:
                handle.write(json.dumps(entry) + "\n")


class ProviderRequest(BaseHTTPRequestHandler):
    timeout = 5

    def log_message(self, *_args):
        # The standard handler would log the raw request line.
        pass

    def safe_headers(self):
        headers = {}
        for name in AUTH_HEADERS:
            values = self.headers.get_all(name, [])
            if len(values) != 1:
                continue
            parts = values[0].split()
            if name == "authorization":
                if len(parts) != 2 or parts[0].lower() != "bearer":
                    continue
                parts = parts[1:]
            if len(parts) != 1:
                continue
            markers = TOKEN.findall(parts[0])
            if len(markers) == 1:
                headers[name] = "Bearer " + markers[0] if name == "authorization" else markers[0]
        if self.headers.get_all("anthropic-version") == [ANTHROPIC_VERSION]:
            headers["anthropic-version"] = ANTHROPIC_VERSION
        return headers

    def parse_request(self):
        if not super().parse_request():
            return False
        path = self.path.partition("?")[0]
        endpoint = path if path in ENDPOINTS.values() else "<unknown>"
        method = self.command if self.command in METHODS else "<unknown>"
        self.recorded_headers = self.safe_headers()
        self.server.record(method, endpoint, self.recorded_headers)
        if self.command != "GET":
            self.respond(405)
            return False
        return True

    def respond(self, status, headers=None, body=None):
        data = json.dumps({} if body is None else body).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def do_GET(self):
        if self.path not in ENDPOINTS.values():
            self.respond(404)
            return
        auth = "x-goog-api-key" if self.path == ENDPOINTS["gemini_api"] else "authorization"
        if auth not in self.recorded_headers or sum(name in self.headers for name in AUTH_HEADERS) != 1:
            self.respond(401)
            return
        marker = self.recorded_headers[auth].removeprefix("Bearer ")
        try:
            directive = read_scenario(self.server.scenario_path).get(marker)
        except (OSError, ValueError):
            self.respond(500)
            return
        if directive is None:
            self.respond(401)
        elif "never_answers" in directive:
            self.wait_for_disconnect()
        else:
            provider, reply = fixture(directive["reply"])
            if self.path != ENDPOINTS[provider]:
                self.respond(404)
            elif provider == "claude_api" and "anthropic-version" not in self.recorded_headers:
                self.respond(400)
            else:
                self.respond(reply["status"], reply["headers"], reply["body"])

    def wait_for_disconnect(self):
        # Each blocked client has its own daemon thread. Cancellation closes
        # its connection, and stopping the server ends any remaining waits.
        self.connection.settimeout(None)
        try:
            while self.connection.recv(4096):
                pass
        except ConnectionError:
            pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scenario", required=True, type=Path)
    parser.add_argument("--port-file", required=True, type=Path)
    args = parser.parse_args()
    parent = os.getppid()
    scenario_path = args.scenario.absolute()
    try:
        if scenario_path.name == "calls.jsonl" or args.port_file.name == "calls.jsonl":
            raise ValueError("calls.jsonl is reserved for the request record")
        read_scenario(scenario_path)
        with ProviderServer(scenario_path) as server:
            publish_port(args.port_file, server.server_port)
            while parent != 1 and os.getppid() == parent:
                server.handle_request()
    except (OSError, ValueError):
        parser.exit(1, "provider_api: could not start the stand-in with the supplied files\n")


if __name__ == "__main__":
    main()
