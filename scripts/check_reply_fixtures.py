"""Checks the reply files of the stand-in tools (plan HD-8).

Run: python3 -I scripts/check_reply_fixtures.py [<replies folder>]
     (default: mac/Tests/StandIns/replies)

Run and status replies use the milestone 3 metadata, a marker in the outputs,
and a process exit status. Usage replies (RD-8) are made-up process outputs,
settings, by-method Codex messages or HTTP replies with an expected reading.
HTTP response headers are limited to the ones the reader takes (RD-6).

Scan the raw file, decoded strings (including keys) and embedded JSON for
account details, token prefixes and home paths. Identifiers and account
fields must hold placeholders. Diagnostics name the file, never a value.

Standard library only.
"""

from functools import lru_cache
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_ROOT = os.path.join(os.path.dirname(HERE), "mac", "Tests", "StandIns", "replies")

LOGIN_PROVIDERS = {"claude", "codex", "gemini", "grok"}
# RD-6. These are response headers, distinct from the authentication and
# version headers sent in a request.
RESPONSE_HEADERS = {
    "claude_api": {"anthropic-ratelimit-requests-remaining"},
    "openai_api": {"x-ratelimit-remaining-requests"},
    "openrouter": set(), "gemini_api": set(), "grok_api": set(),
}
PROVIDERS = LOGIN_PROVIDERS | RESPONSE_HEADERS.keys()
USAGE_BASES = {"made_from_recorded", "made_from_schema", "made_from_documentation", "made_from_prd"}
SESSION_METHODS = {"initialize", "account/read", "account/usage/read", "account/rateLimits/read"}
OUTPUT_KEYS = {"stdout", "stderr", "exit_status"}
BASES = {"recorded_no_login", "invented", "made_from_observed"}
KINDS = {"run", "status"}
EXPECTATIONS = {"limit", "rate_limited", "signed_out", "failed", "signed_in"}
WINDOWS = {"five_hour", "weekly", "per_model", "spend"}
RESETS = {"stated", "none"}
REQUIRED_META = ("provider", "tool", "tool_version", "basis", "date", "kind", "shows", "expect", "marker")

MARKER = re.compile(r"^LVRG-REPLY-[0-9a-f]{12}$")
SCRUBBED = "<scrubbed>"

# Fields that carry an account's details or a run's own id in a real reply
# (inventory-mac.md section 2), and a few more of the same kind.
NAMED_FIELDS = {
    "email", "orgId", "orgName", "organization", "subscriptionType", "planTier", "loginExpiresAt",
    "configDirectory", "projectsDirectory", "session_id", "sessionId", "uuid", "credential_expires_at",
    "modelUsage", "thread_id", "conversation_id", "request_id", "account_id", "accountId", "user_id",
    "userId",
}

EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}")
TOKENS = [
    ("a stand-in token", re.compile(r"LVRG-TOKEN-[0-9a-fA-F]{12}")),
    ("a Leverage token", re.compile(r"(?<![A-Za-z0-9])lv[sho]_[A-Za-z0-9_-]{8,}")),
    ("an Anthropic key", re.compile(r"(?<![A-Za-z0-9])sk-ant-[A-Za-z0-9_-]{6,}")),
    ("an OpenAI key", re.compile(r"(?<![A-Za-z0-9-])sk-(proj-)?[A-Za-z0-9_-]{16,}")),
    ("an xAI key", re.compile(r"(?<![A-Za-z0-9])xai-[A-Za-z0-9_-]{16,}")),
    ("a Google key", re.compile(r"(?<![A-Za-z0-9])AIza[A-Za-z0-9_-]{16,}")),
    ("a Google token", re.compile(r"(?<![A-Za-z0-9])ya29\.[A-Za-z0-9_-]{10,}")),
    ("a GitHub token", re.compile(r"(?<![A-Za-z0-9])(gh[pousr]_|github_pat_)[A-Za-z0-9_]{16,}")),
    ("a JSON web token", re.compile(r"(?<![A-Za-z0-9])eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}")),
    ("a bearer value", re.compile(r"(?i)\bbearer\s+(?!or\b|and\b|token\b)[A-Za-z0-9._~+/-]{16,}")),
]
HOME_PATH = re.compile(r"(/Users/|/home/)(?!Shared\b)[^/\s\"']+|(?<![\w/~])~[A-Za-z0-9._-]*/")
# The words of a field's name that mark it as an account's detail, whatever
# else the name holds (plan_type, rateLimitTier, organization_name, orgUuid).
NAMED_WORDS = {"email", "plan", "org", "organization", "organisation", "account", "tier", "subscription",
               "access", "display", "name", "refresh", "session"}
UUID = re.compile(r"(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b")
REQUEST_ID = re.compile(r"\breq_[0-9A-Za-z]{8,}")
HEX_RUN = re.compile(r"(?i)(?<![0-9a-z])[0-9a-f]{16,}(?![0-9a-z])")


def placeholder_id(text):
    """An id made of zeros only, such as 00000000-0000-... or req_000..."""
    digits = re.sub(r"^req_|[-]", "", text)
    return set(digits) <= {"0"}


def text_problems(text):
    problems = []
    if EMAIL.search(text):
        problems.append("holds an email address")
    for name, pattern in TOKENS:
        if pattern.search(text):
            problems.append(f"holds {name}")
    if HOME_PATH.search(text):
        problems.append("holds a path into a user's home folder")
    for pattern in (UUID, REQUEST_ID, HEX_RUN):
        for found in pattern.finditer(text):
            if not placeholder_id(found.group(0)):
                problems.append("holds an id that is not a placeholder (made of zeros)")
                break
    return problems


class DuplicateKey(ValueError):
    """Duplicate object members could hide an earlier field's contents."""


def unique_object(pairs):
    value = {}
    for key, inner in pairs:
        if key in value:
            raise DuplicateKey
        value[key] = inner
    return value


def json_values(output):
    """Yield embedded objects, arrays or quoted strings, including JSON lines."""
    text = output.strip()
    if text.startswith(("{", "[", '"')):
        try:
            yield json.loads(text, object_pairs_hook=unique_object)
            return
        except json.JSONDecodeError:
            pass
    for line in text.splitlines():
        if line.lstrip().startswith(("{", "[", '"')):
            try:
                yield json.loads(line, object_pairs_hook=unique_object)
            except json.JSONDecodeError:
                pass


def scrubbed(value, marker):
    """Empty, null, `<scrubbed>`, the file's marker, or a UUID of zeros."""
    if value in (None, "", {}, [], SCRUBBED) or (marker and value == marker):
        return True
    return isinstance(value, str) and bool(UUID.fullmatch(value)) and placeholder_id(value)


def key_words(key):
    """The lower-case words of a field's name: snake_case, kebab-case and camelCase."""
    spaced = re.sub(r"([A-Z]+)([A-Z][a-z])", r"\1 \2", key)
    spaced = re.sub(r"([a-z0-9])([A-Z])", r"\1 \2", spaced)
    return {word.lower() for word in re.split(r"[^A-Za-z0-9]+", spaced) if word}


def named_field(key):
    return key in NAMED_FIELDS or bool(key_words(key) & NAMED_WORDS)


# These fields hold maps whose keys are data in a reply. Some, such as
# Gemini's models, can also be arrays; an array has no data keys to scrub.
DATA_MAP_NAMES = {
    "accounts", "models", "modelusage", "organizations", "organisations", "permodel",
    "ratelimitsbylimitid", "usagebymodel", "users", "workspaces",
}
ID_KEY = re.compile(r"(?i)^(?:acct|account|org|organization|organisation|workspace|user|team|tenant|"
                    r"session|thread|conversation|credit|req|request)[_-]([a-z0-9][a-z0-9_-]*)$")
# A schema field such as workspace_name is checked by its value. A key
# such as workspace_<opaque value> is itself private, even with no value.
FIELD_SUFFIXES = {"id", "ids", "uuid", "uuids", "email", "name", "type", "plan", "tier",
                  "blocked", "disabled", "agent", "status", "expires_at", "limit", "count"}


def data_keyed_field(key):
    name = key.lower().replace("_", "").replace("-", "")
    return name in DATA_MAP_NAMES or bool(re.search(r"by(?:account|organi[sz]ation|org|workspace|"
                                                   r"model|user|team|tenant|limit)(?:id|name)?$", name))


def private_id_key(key):
    match = ID_KEY.fullmatch(key)
    return match is not None and match[1].lower().replace("-", "_") not in FIELD_SUFFIXES


def usage_named_field(key):
    """Match account details, identifiers, credentials and filesystem paths."""
    words = key_words(key)
    return (named_field(key) or bool(words & {"id", "ids", "uuid", "uuids", "workspace", "team",
                                              "path", "paths", "directory", "directories", "dir",
                                              "folder", "home", "token", "password", "secret"})
            or bool(re.search(r"(?:ID|Id)s?$", key))
            or {"api", "key"} <= words or key.lower() in {"apikey", "cwd", "modified_by", "owned_by"}
            or (bool(words & {"login", "credential", "auth"}) and any(w.startswith("expir") for w in words)))


def usage_private_value(provider, path, value, marker):
    """Handle the few structural names shared with fields carrying private data."""
    key = path[-1]
    if provider == "codex":
        if path == ("session",) or (path[:-1] == ("session",) and key in SESSION_METHODS):
            return False  # The session shape is checked separately.
        account_path = ("session", "account/read", "result", "account")
        if path == account_path and isinstance(value, dict):
            return False
        if path[:-1] == account_path:
            if key == "type" and value in ("apiKey", "chatgpt", "gcp", "amazonBedrock"):
                return False
            if key == "usesCodexManagedCredentials" and type(value) is bool:
                return False
            return not scrubbed(value, marker)
    if provider == "openrouter" and path == ("body", "data", "is_free_tier"):
        return type(value) is not bool
    if provider == "grok_api" and path[:-1] == ("body",):
        if key in {"api_key_blocked", "api_key_disabled", "team_blocked"}:
            return type(value) is not bool
        if key == "name":
            return not scrubbed(value, marker)
    if provider == "openrouter" and path == ("body", "data", "label"):
        return not scrubbed(value, marker)
    if isinstance(value, dict) and data_keyed_field(key):
        return False  # Its children are checked by their keys as well as their values.
    return usage_named_field(key) and not scrubbed(value, marker)


def scan_value(value, path, marker, provider, usage, found):
    """Scan keys, values and nested JSON, retaining only fixed diagnostic text."""
    if isinstance(value, dict):
        data_keys = usage and path and isinstance(path[-1], str) and data_keyed_field(path[-1])
        # This one example key is in the Codex protocol schema.
        codex_limits = provider == "codex" and path == ("session", "account/rateLimits/read", "result",
                                                       "rateLimitsByLimitId")
        for key, inner in value.items():
            found.update(text_problems(key))
            if usage and private_id_key(key):
                found.add("an object key holds a private identifier")
            if data_keys and not scrubbed(key, marker) and not (codex_limits and key == "codex"):
                found.add("an object keyed by account, model or limit data needs placeholder keys")
            child = (*path, key)
            private = (usage_private_value(provider, child, inner, marker) if usage else
                       path[:1] in (("stdout",), ("stderr",)) and usage_named_field(key) and not scrubbed(inner, marker))
            if private:
                found.add("an account, identifier, credential or path field holds a non-placeholder value")
            scan_value(inner, child, marker, provider, usage, found)
    elif isinstance(value, list):
        for index, inner in enumerate(value):
            scan_value(inner, (*path, index), marker, provider, usage, found)
    elif isinstance(value, str):
        found.update(text_problems(value))
        if usage or path[:1] in (("stdout",), ("stderr",)):
            for inner in json_values(value):
                scan_value(inner, path, marker, provider, usage, found)


@lru_cache(maxsize=1)
def reading_shapes():
    """Use the public contract for the fixture's expected Figure and Reset."""
    path = os.path.join(os.path.dirname(HERE), "api", "contract", "openapi.json")
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)["components"]["schemas"]


def reading_record(value, shape):
    """Check required wire keys and their declared scalar types and enums."""
    if not isinstance(value, dict) or set(value) != set(shape["required"]):
        return False
    scalar_types = {"integer": (int,), "number": (int, float), "string": (str,), "null": (type(None),)}
    for key, scalar in value.items():
        field = shape["properties"][key]
        types = field["type"] if isinstance(field["type"], list) else [field["type"]]
        if not any(type(scalar) in scalar_types[t] for t in types):
            return False
        if "enum" in field and scalar not in field["enum"]:
            return False
    return True


def expected_reading(expect):
    if not isinstance(expect, dict) or set(expect) != {"state", "figures", "resets"}:
        return False
    shapes = reading_shapes()
    reading = shapes["CredentialReading"]["properties"]
    figures, resets = expect["figures"], expect["resets"]
    return (expect["state"] in reading["state"]["enum"]
            and isinstance(figures, list) and all(reading_record(f, shapes["Figure"]) for f in figures)
            and (resets is None or isinstance(resets, list) and all(reading_record(r, shapes["Reset"]) for r in resets)))


def output_problems(reply):
    problems = []
    if not all(isinstance(reply.get(key), str) for key in ("stdout", "stderr")):
        problems.append("stdout and stderr must both be text")
    if type(reply.get("exit_status")) is not int:
        problems.append("exit_status must be a number")
    return problems


def usage_payload_problems(reply, provider):
    keys = set(reply).difference({"meta", "marker"})
    if provider in RESPONSE_HEADERS and keys == {"status", "headers", "body"}:
        found = []
        if type(reply["status"]) is not int or not 100 <= reply["status"] <= 599:
            found.append("status must be an HTTP status code")
        headers = reply["headers"]
        if (not isinstance(headers, dict)
                or any(key.lower() not in RESPONSE_HEADERS[provider] or not isinstance(value, str)
                       or "\r" in value or "\n" in value for key, value in headers.items())
                or len({key.lower() for key in headers}) != len(headers)):
            found.append("headers must contain only this provider's named response headers with text values")
        return found
    if provider == "codex" and keys in ({"session"}, {"session", "server_messages"}):
        session = reply["session"]
        if (isinstance(session, dict) and session and set(session) <= SESSION_METHODS
                and all(isinstance(msg, dict) and (("result" in msg) != ("error" in msg)) for msg in session.values())
                and isinstance(reply.get("server_messages", []), list)
                and all(isinstance(msg, dict) for msg in reply.get("server_messages", []))):
            return []
    if provider == "claude":
        if keys == OUTPUT_KEYS:
            return output_problems(reply)
        if keys == {"settings"} and isinstance(reply["settings"], dict):
            return []
    return ["usage payload has the wrong shape for its provider"]


def file_problems(path, provider_folder):
    """The problems of one file, and its marker (None when it has none)."""
    try:
        with open(path, encoding="utf-8") as handle:
            raw = handle.read()
        reply = json.loads(raw, object_pairs_hook=unique_object)
    except (OSError, ValueError, RecursionError):
        return ["is not readable JSON with unique keys"], None
    if not isinstance(reply, dict):
        return ["is not a JSON object"], None

    found = set(text_problems(raw))
    meta = reply.get("meta")
    if not isinstance(meta, dict):
        return sorted(found | {"has no meta"}), None
    for key in REQUIRED_META:
        if key not in meta:
            found.add(f"meta has no {key}")
    if meta.get("provider") != provider_folder:
        found.add("meta.provider must match the provider folder")
    kind = meta.get("kind")
    usage = kind == "usage"
    if usage != bool(re.fullmatch(r"usage-.+\.json", os.path.basename(path))):
        found.add("usage replies must use kind usage and a usage-<description>.json filename")
    basis = meta.get("basis")
    bases = USAGE_BASES if usage else BASES
    if not isinstance(basis, str) or basis not in bases:
        found.add("meta.basis is not permitted for this kind of reply")

    marker = meta.get("marker")
    if not isinstance(marker, str) or not MARKER.fullmatch(marker):
        marker = None
        found.add("meta.marker is not of the form LVRG-REPLY-<12 hex digits>")

    expect = meta.get("expect")
    if usage:
        if not expected_reading(expect):
            found.add("meta.expect must hold a reading with state, figures and resets")
        found.update(usage_payload_problems(reply, provider_folder))
        payload = {key: value for key, value in reply.items() if key != "meta"}
        if marker and (payload.get("marker", marker) != marker or marker not in json.dumps(payload)):
            found.add("a usage reply must carry its marker outside meta")
    else:
        if provider_folder not in LOGIN_PROVIDERS:
            found.add("run and status replies must belong to a login provider")
        if not isinstance(kind, str) or kind not in KINDS:
            found.add("meta.kind is not a supported reply kind")
        if basis == "made_from_observed" and not meta.get("follows"):
            found.add("a made_from_observed file names no observed text it follows (meta.follows)")
        if not isinstance(expect, str) or expect not in EXPECTATIONS:
            found.add("meta.expect must name an outcome")
        if expect == "limit":
            for key, choices in (("expect_window", WINDOWS), ("expect_reset", RESETS)):
                if not isinstance(meta.get(key), str) or meta[key] not in choices:
                    found.add(f"a limit's meta.{key} must be one of {sorted(choices)}")
        found.update(output_problems(reply))
        if marker and not any(isinstance(reply.get(k), str) and marker in reply[k] for k in ("stdout", "stderr")):
            found.add("its marker is in meta only, not in stdout or stderr")
    try:
        scan_value(reply, (), marker, provider_folder, usage, found)
    except (ValueError, RecursionError):
        found.add("nested reply JSON must have unique keys and a readable nesting depth")
    return sorted(found), marker


def problems(root):
    """Every problem of the reply files under `root`, each naming its file."""
    found = []
    markers = {}
    files = []
    if os.path.islink(root) or not os.path.isdir(root):
        return ["reply root must be a folder, not a link"]
    for provider in sorted(os.listdir(root)):
        folder = os.path.join(root, provider)
        if provider not in PROVIDERS:
            found.append("the reply root contains an unrecognized provider entry")
            continue
        if os.path.islink(folder) or not os.path.isdir(folder):
            found.append(f"{provider}: only folders, one per provider, belong here")
            continue
        for name in sorted(os.listdir(folder)):
            path = os.path.join(folder, name)
            relative = os.path.relpath(path, root)
            if text_problems(name) or not name.isprintable():
                found.append(f"{provider}/: a reply filename contains private detail or control characters")
                continue
            if os.path.islink(path) or not name.endswith(".json") or not os.path.isfile(path):
                found.append(f"{relative}: only .json reply files belong here")
                continue
            files.append(relative)
            file_found, marker = file_problems(path, provider)
            found.extend(f"{relative}: {problem}" for problem in file_found)
            if marker:
                markers.setdefault(marker, []).append(relative)
    if not files:
        found.append("no reply file in the reply root")
    for marker, users in sorted(markers.items()):
        if len(users) > 1:
            found.append(f"the marker {marker} is used by {len(users)} files: {', '.join(users)}")
    return found


def main(argv):
    root = argv[0] if argv else DEFAULT_ROOT
    found = problems(root)
    if found:
        for problem in found:
            print(problem)
        print(f"{len(found)} problem(s) in the reply files")
        return 1
    count = sum(len(files) for _, _, files in os.walk(root))
    print(f"All {count} reply files pass")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
