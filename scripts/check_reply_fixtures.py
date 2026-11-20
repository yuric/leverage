"""Checks the reply files of the stand-in tools (plan HD-8).

Run: python3 -I scripts/check_reply_fixtures.py [<replies folder>]
     (default: mac/Tests/StandIns/replies)

A reply file is one reply of a provider's tool, recorded with no login or
made, under replies/<provider>/. It holds `meta`, `exit_status`, `stdout`
and `stderr`. The check fails, naming the file, on:

- a file that is not JSON, or has no `meta`, no `basis`, or a `basis` that
  is not recorded_no_login, invented or made_from_observed; a
  made_from_observed file that does not name what it `follows`;
- a `meta` without its provider (the file's own folder), tool version,
  kind, expectation, or, for a limit, its window and whether it states a
  reset time; outputs that are not text, an exit status that is no number;
- an email address, a token prefix (leverage's lvs_, lvh_, lvo_, IN-18, and
  the providers' common ones), a bearer value, a path into a user's home
  folder (/Users/<name>, /home/<name> or ~<name>), or an id that is not a
  placeholder (a UUID, a request id, a run of 16 or more hex digits, unless
  every digit is 0), anywhere in the file: in its raw text, in every string
  of the decoded file, and in every string of the JSON the outputs hold, so
  that a JSON escape (\\/ for /, \\u0040 for @) hides nothing;
- one of the fields a real reply carries account details in
  (`inventory-mac.md` section 2), or any field whose name has one of the
  words email, plan, org, organization, organisation, account, tier or
  subscription in it, with a value that is not empty, null, `<scrubbed>`
  or the file's marker;
- a marker not of the form LVRG-REPLY-<12 hex digits>, one missing from
  both outputs, or one used by two files.

Standard library only.
"""

import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_ROOT = os.path.join(os.path.dirname(HERE), "mac", "Tests", "StandIns", "replies")

PROVIDERS = {"claude", "codex", "gemini", "grok"}
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
    ("a leverage token", re.compile(r"(?<![A-Za-z0-9])lv[sho]_[A-Za-z0-9_-]{8,}")),
    ("an Anthropic key", re.compile(r"(?<![A-Za-z0-9])sk-ant-[A-Za-z0-9_-]{6,}")),
    ("an OpenAI key", re.compile(r"(?<![A-Za-z0-9-])sk-(proj-)?[A-Za-z0-9_-]{16,}")),
    ("an xAI key", re.compile(r"(?<![A-Za-z0-9])xai-[A-Za-z0-9_-]{16,}")),
    ("a Google key", re.compile(r"(?<![A-Za-z0-9])AIza[A-Za-z0-9_-]{20,}")),
    ("a Google token", re.compile(r"(?<![A-Za-z0-9])ya29\.[A-Za-z0-9_-]{10,}")),
    ("a GitHub token", re.compile(r"(?<![A-Za-z0-9])(gh[pousr]_|github_pat_)[A-Za-z0-9_]{16,}")),
    ("a JSON web token", re.compile(r"(?<![A-Za-z0-9])eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}")),
    ("a bearer value", re.compile(r"(?i)\bbearer\s+(?!or\b|and\b|token\b)[A-Za-z0-9._~+/-]{16,}")),
]
HOME_PATH = re.compile(r"(/Users/|/home/)(?!Shared\b)[^/\s\"']+|(?<![\w/~])~[A-Za-z0-9._-]+/")
# The words of a field's name that mark it as an account's detail, whatever
# else the name holds (plan_type, rateLimitTier, organization_name, orgUuid).
NAMED_WORDS = {"email", "plan", "org", "organization", "organisation", "account", "tier", "subscription"}
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


def json_values(output):
    """Every JSON value in an output: the whole of it, or each of its lines."""
    values = []
    try:
        values.append(json.loads(output))
        return values
    except ValueError:
        pass
    for line in output.splitlines():
        line = line.strip()
        if line.startswith(("{", "[")):
            try:
                values.append(json.loads(line))
            except ValueError:
                pass
    return values


def scrubbed(value, marker):
    """Empty, null, `<scrubbed>`, the file's marker, or a UUID of zeros."""
    if value in (None, "", {}, [], SCRUBBED) or (marker and value == marker):
        return True
    return isinstance(value, str) and bool(UUID.fullmatch(value)) and placeholder_id(value)


def key_words(key):
    """The lower-case words of a field's name: snake_case, kebab-case and camelCase."""
    spaced = re.sub(r"([a-z0-9])([A-Z])", r"\1 \2", key)
    return {word.lower() for word in re.split(r"[^A-Za-z0-9]+", spaced) if word}


def named_field(key):
    return key in NAMED_FIELDS or bool(key_words(key) & NAMED_WORDS)


def strings_in(value):
    """Every string in a decoded JSON value, its keys among them."""
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for key, inner in value.items():
            yield key
            yield from strings_in(inner)
    elif isinstance(value, list):
        for inner in value:
            yield from strings_in(inner)


def decoded_problems(reply):
    """text_problems over every string of the decoded reply and of the JSON
    its outputs hold, which no JSON escape hides."""
    found = []
    texts = list(strings_in(reply))
    for name in ("stdout", "stderr"):
        output = reply.get(name)
        if isinstance(output, str):
            for value in json_values(output):
                texts.extend(strings_in(value))
    for text in texts:
        for problem in text_problems(text):
            if problem not in found:
                found.append(problem)
    return found


def named_field_problems(value, marker):
    problems = []
    if isinstance(value, dict):
        for key, inner in value.items():
            if named_field(key) and not scrubbed(inner, marker):
                problems.append(f"the field {key} holds a value; scrub it to {SCRUBBED!r}")
            problems.extend(named_field_problems(inner, marker))
    elif isinstance(value, list):
        for inner in value:
            problems.extend(named_field_problems(inner, marker))
    return problems


def file_problems(path, provider_folder):
    """The problems of one file, and its marker (None when it has none)."""
    try:
        with open(path, encoding="utf-8") as handle:
            raw = handle.read()
        reply = json.loads(raw)
    except (OSError, ValueError) as error:
        return [f"is not readable JSON: {error}"], None
    if not isinstance(reply, dict):
        return ["is not a JSON object"], None
    problems = text_problems(raw)
    problems.extend(problem for problem in decoded_problems(reply) if problem not in problems)
    meta = reply.get("meta")
    if not isinstance(meta, dict):
        return problems + ["has no meta"], None
    marker = meta.get("marker")

    for key in REQUIRED_META:
        if key not in meta:
            problems.append(f"meta has no {key}")
    basis = meta.get("basis")
    if "basis" in meta and basis not in BASES:
        problems.append(f"meta.basis is {basis!r}, not one of {sorted(BASES)}")
    if basis == "made_from_observed" and not meta.get("follows"):
        problems.append("a made_from_observed file names no observed text it follows (meta.follows)")
    if meta.get("provider") != provider_folder:
        problems.append(f"meta.provider is {meta.get('provider')!r}, but the file is in {provider_folder}/")
    if "kind" in meta and meta["kind"] not in KINDS:
        problems.append(f"meta.kind is {meta['kind']!r}, not one of {sorted(KINDS)}")
    if "expect" in meta and meta["expect"] not in EXPECTATIONS:
        problems.append(f"meta.expect is {meta['expect']!r}, not one of {sorted(EXPECTATIONS)}")
    if meta.get("expect") == "limit":
        if meta.get("expect_window") not in WINDOWS:
            problems.append(f"a limit's meta.expect_window must be one of {sorted(WINDOWS)}")
        if meta.get("expect_reset") not in RESETS:
            problems.append(f"a limit's meta.expect_reset must be one of {sorted(RESETS)}")

    stdout, stderr = reply.get("stdout"), reply.get("stderr")
    outputs_are_text = isinstance(stdout, str) and isinstance(stderr, str)
    if not outputs_are_text:
        problems.append("stdout and stderr must both be text")
    status = reply.get("exit_status")
    if not isinstance(status, int) or isinstance(status, bool):
        problems.append("exit_status must be a number")

    if not isinstance(marker, str) or not MARKER.match(marker):
        if "marker" in meta:
            problems.append("meta.marker is not of the form LVRG-REPLY-<12 hex digits>")
        marker = None
    elif outputs_are_text and marker not in stdout and marker not in stderr:
        problems.append("its marker is in meta only, not in stdout or stderr")

    if outputs_are_text:
        for output in (stdout, stderr):
            for value in json_values(output):
                problems.extend(named_field_problems(value, marker))
    return problems, marker


def problems(root):
    """Every problem of the reply files under `root`, each naming its file."""
    found = []
    markers = {}
    files = []
    if not os.path.isdir(root):
        return [f"{root}: no such folder"]
    for provider in sorted(os.listdir(root)):
        folder = os.path.join(root, provider)
        if not os.path.isdir(folder):
            found.append(f"{os.path.relpath(folder, root)}: only folders, one per provider, belong here")
            continue
        if provider not in PROVIDERS:
            found.append(f"{provider}/: not a login provider ({sorted(PROVIDERS)})")
        for name in sorted(os.listdir(folder)):
            path = os.path.join(folder, name)
            relative = os.path.relpath(path, root)
            if not name.endswith(".json") or not os.path.isfile(path):
                found.append(f"{relative}: only .json reply files belong here")
                continue
            files.append(relative)
            file_found, marker = file_problems(path, provider)
            found.extend(f"{relative}: {problem}" for problem in file_found)
            if marker:
                markers.setdefault(marker, []).append(relative)
    if not files:
        found.append(f"{root}: no reply file")
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
