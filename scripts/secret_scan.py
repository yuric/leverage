#!/usr/bin/env python3
"""Look for secrets in logs and a database dump (milestone 2 plan §5.2, L721).

Step 5 of scripts/e2e_core_loop.sh and of each test of
scripts/e2e_handoff.sh (milestone 3 plan §5.2, step 3). Scans every file under the paths given
for:

- each secret listed in a --secrets file (one per line; blank lines and
  lines starting with "#" are skipped) and each --literal value: the
  owner's password, the session and helper tokens a test used, the
  stand-ins' made-up email and organisation. Each is looked for as written
  and in the forms a log or a dump may hold it in: JSON-escaped,
  URL-encoded (a path or a query, and a form body), and base64 at any of
  its three alignments inside a longer encoded text; and also with the
  file's line breaks removed, so a copy wrapped across lines is found
  where it starts;
- anything shaped like a Leverage token: lvs_, lvh_ or lvo_ followed by 16
  or more URL-safe base64 characters (IN-18). What the redaction leaves,
  `lvs_[removed]`, is not one;
- a bearer header's value of 16 characters or more, whatever the case of
  "Bearer";
- with --replies FOLDER, a provider tool's reply (milestone 3 plan HD-8,
  §5.2): every reply file's marker (meta.marker), and every line of its
  outputs (stdout, stderr) that is at least 40 characters long. A line
  that holds a reset placeholder (@RESET_AT_ISO@, "@RESET_AT_EPOCH@") is
  looked for in its pieces around the placeholders that are that long,
  because the stand-ins replace the placeholder when they play the reply.
  A shorter line, such as "{" or "ready", is in every log and is not
  looked for. A reply must appear nowhere but in the stand-ins' own folder,
    so that folder is never one of the paths scanned. Usage replies add
    the lines of the response body, each app-server reply and the settings
    fixture, and the Claude settings account id when the fixture has one.

Credentials (milestone 6 plan TK-5, §5.2) add two checks:

- --credentials-dump FILE scans a plain data-only dump. Each supplied
  --account-email VALUE must be in credentials.account_email and nowhere
  else. Only exact matches in that column are removed from the scan. The
  plan column is also inspected for leaked values.
- --provider-api-record FILE with --token-markers FILE scans the stand-in
  API's JSONL file. Each expected marker (one per line) must appear in that
  record's credential header and nowhere else. A marker-shaped value in
  any ordinary scanned file is a hit even without those options.

Task text (milestone 4 plan RT-8, §5.2 step 3) is content: it belongs in
its own rows and never in an event's payload or a log line. Two more
questions, each with its own paths:

- --not-in-events WORD with --events-dump FILE: each word, in every form a
  secret is looked for in, must be in no `payload` of the `events` table of
  a data-only dump (pg_dump --data-only, plain text). The same word in the
  task's own rows of that dump is not a hit, and neither is it anywhere
  else in an event's row.
- --logs PATH, with --not-in-logs WORD or alone: each word must be in no
  file under the log paths (the containers', the helper's, the runs' and
  the MCP server's logs). Those files must also hold no nonce-shaped
  marker from a check, draft, question, approval or action frame. These
  markers carry 12 hexadecimal characters.
  The stand-ins' record of each call holds the prompts, so it is never one
  of the log paths.

A hit is printed as "<file>:<line>: <what>", where <what> says which listed
secret or word it was (by its number) or which shape matched. The secret
or word itself is never printed. Exit 0 when nothing is found, 1 on any
hit, 2 when the scan could not be made: no path, a missing path, no file
to scan, no secret to look for, a secret or word shorter than 8 characters
(a shorter one leaves a base64 piece too short to look for at one of the
offsets, or turns up by chance), a replies folder with no reply file or a
reply file with no marker, words with no dump or no logs to look in, a
dump with no events table or no payload column in it, or log paths with no
file.

Usage:
  python3 -I scripts/secret_scan.py [--secrets FILE]... [--literal VALUE]...
      [--replies FOLDER]... [--not-in-events WORD... --events-dump FILE...]
      [--credentials-dump FILE [--account-email VALUE]...]
      [--provider-api-record FILE --token-markers FILE]
      [--logs PATH... [--not-in-logs WORD...]] [PATH...]

Paths to scan for secrets may come before, between or after the options.

Standard library only.
"""

import argparse
import base64
import json
import os
import re
import sys
import urllib.parse

TOKEN_MARKER = re.compile(rb"LVRG-TOKEN-[0-9a-fA-F]{12}(?![0-9a-fA-F])")
SHAPES = [
    ("token shape", re.compile(rb"lv[sho]_[A-Za-z0-9_-]{16,}")),
    ("bearer value", re.compile(rb"Bearer\s+[A-Za-z0-9._~+/-]{16,}=*", re.IGNORECASE)),
    ("test token marker", TOKEN_MARKER),
]
# Frames mark their lines and quote blocks with a nonce (ADR 0012 and
# milestone 5 plan AT-7). Only a prompt or a tool's answer holds one.
NONCE_SHAPE = ("nonce-shaped marker", re.compile(
    rb"LEVERAGE-(?:VERDICT|REASON|QUOTE|END|DRAFT|DECISION|ANSWER|BASIS|PASS-ON|DONE|CANNOT)-[0-9a-f]{12}"
))
# pg_dump's header of a table's rows, and the line that ends them.
COPY_HEADER = re.compile(r"^COPY (?:public\.)?\"?events\"? \((.*)\) FROM stdin;$")
CREDENTIALS_HEADER = re.compile(rb'^COPY (?:public\.)?"?credentials"? \((.*)\) FROM stdin;$')
COPY_END = b"\\."
# A base64 piece shorter than SHORTEST_BASE64 could turn up by chance in
# a dump. A secret of SHORTEST characters gives a piece of at least that
# length at each of the three offsets (8, 10 and 9 characters), so every
# secret the scan takes is looked for in base64 at all three.
SHORTEST = 8
SHORTEST_BASE64 = 8
# The shortest line of a reply file's outputs that is looked for (§5.2).
LONGEST_COMMON_LINE = 39
# What the stand-ins replace when they play a reply (provider_tool.py).
PLACEHOLDERS = re.compile(r'"@RESET_AT_EPOCH@"|@RESET_AT_ISO@|@FRESH_SETTINGS_MS@|@CODEX_HOME@')


class Refused(Exception):
    """The scan could not be made."""


def usage_lines(reply):
    """The JSON lines emitted by the stand-in API, tool or settings writer."""
    if "body" in reply:
        yield "body", json.dumps(reply["body"])
        yield "body", json.dumps(reply["body"], separators=(",", ":"))
        yield from pretty_lines("body", reply["body"])
    if "settings" in reply:
        settings = reply["settings"]
        rendered = json.dumps(settings)
        # The stand-in replaces the fetch time when it writes the settings.
        yield "settings", re.sub(r'("fetchedAtMs": )\d+', r'\g<1>@FRESH_SETTINGS_MS@', rendered)
        yield from pretty_lines("settings", settings)
    for method, message in reply.get("session", {}).items():
        # The app-server appends the client's id to the fixture message.
        rendered = json.dumps(message, separators=(",", ":"))
        if method == "initialize":
            rendered = rendered.replace('"codexHome":"<scrubbed>"', '"codexHome":@CODEX_HOME@')
        yield f"app-server {method}", rendered[:-1] + ',"id":'
        yield from pretty_lines(f"app-server {method}", message)
    for message in reply.get("server_messages", []):
        yield "app-server notice", json.dumps(message, separators=(",", ":"))
        yield from pretty_lines("app-server notice", message)


def pretty_lines(label, value):
    """A leak in a reformatted body can still hold a long line from it."""
    for number, line in enumerate(json.dumps(value, indent=2).splitlines(), start=1):
        yield f"{label} line {number}", line.strip()


def claude_account_ids(reply):
    """The made-up account id, even when it leaks without the settings."""
    if reply["meta"].get("provider") != "claude" or "settings" not in reply:
        return
    settings = reply["settings"]
    for fields in (settings, settings.get("oauthAccount", {})):
        for key in ("accountId", "account_id", "accountUuid", "oauthAccountUuid"):
            value = fields.get(key)
            if isinstance(value, str) and value != "<scrubbed>":
                yield value


def read_replies(folders):
    """[(label, value)] for every reply file under the folders: its marker,
    and each piece of 40 characters or more of each line of its outputs."""
    found = []
    for folder in folders:
        if not os.path.isdir(folder):
            raise Refused(f"no such replies folder: {folder}")
        files = []
        for place, folders_below, names in os.walk(folder):
            folders_below.sort()
            files.extend(os.path.join(place, name) for name in sorted(names) if name.endswith(".json"))
        if not files:
            raise Refused(f"no reply file in {folder}")
        for path in files:
            name = os.path.relpath(path, folder)
            try:
                with open(path, encoding="utf-8") as handle:
                    reply = json.load(handle)
                marker = reply["meta"]["marker"]
            except (OSError, ValueError, KeyError, TypeError) as error:
                raise Refused(f"cannot read the reply file {name}") from error
            if not isinstance(marker, str) or not marker:
                raise Refused(f"the reply file {name} has no marker")
            found.append((f"marker of {name}", marker))
            lines = [(f"{stream} line {number}", line)
                     for stream in ("stdout", "stderr")
                     for number, line in enumerate((reply.get(stream) or "").splitlines(), start=1)]
            if reply["meta"].get("kind") == "usage":
                lines.extend(usage_lines(reply))
                found.extend((f"settings account id of {name}", value) for value in claude_account_ids(reply))
            for origin, line in lines:
                for piece in PLACEHOLDERS.split(line):
                    if len(piece.strip()) > LONGEST_COMMON_LINE:
                        found.append((f"{origin} of {name}", piece))
    return found


def read_secrets(files, literals, replies=()):
    """[(label, bytes)] for every secret to look for."""
    secrets = []
    for path in files:
        try:
            with open(path, encoding="utf-8") as handle:
                lines = handle.read().splitlines()
        except OSError as error:
            raise Refused(f"cannot read the secrets file {path}: {error.strerror}") from error
        number = 0
        for line in lines:
            value = line.strip()
            if not value or value.startswith("#"):
                continue
            number += 1
            secrets.append((f"secret {number} of {path}", value))
    for number, value in enumerate(literals, start=1):
        secrets.append((f"literal {number}", value))
    secrets.extend(replies)
    if not secrets:
        raise Refused("no secret to look for")
    for label, value in secrets:
        if len(value) < SHORTEST:
            raise Refused(f"{label} is too short to look for (under {SHORTEST} characters)")
    return [form for label, value in secrets for form in forms(label, value)]


def read_words(words, flag):
    """[(label, bytes)] for every form of each word a question looks for."""
    found = []
    for number, value in enumerate(words, start=1):
        label = f"word {number} of {flag}"
        if len(value) < SHORTEST:
            raise Refused(f"{label} is too short to look for (under {SHORTEST} characters)")
        found.extend(forms(label, value))
    return found


def events_payloads(path):
    """[(line number, seq, payload bytes)] for every row of the events table
    in a data-only dump."""
    try:
        with open(path, "rb") as handle:
            lines = handle.read().splitlines()
    except OSError as error:
        raise Refused(f"cannot read the dump {path}: {error.strerror}") from error
    rows = None
    for number, line in enumerate(lines, start=1):
        if rows is None:
            header = COPY_HEADER.match(line.decode("utf-8", "replace"))
            if header:
                columns = [name.strip().strip('"') for name in header.group(1).split(",")]
                if "payload" not in columns:
                    raise Refused(f"the events table in {path} has no payload column")
                payload_at = columns.index("payload")
                seq_at = columns.index("seq") if "seq" in columns else None
                rows = []
            continue
        if line == COPY_END:
            return rows
        fields = line.split(b"\t")
        if len(fields) <= payload_at:
            raise Refused(f"{path}:{number}: a row of the events table has no payload")
        seq = fields[seq_at].decode("utf-8", "replace") if seq_at is not None else "?"
        rows.append((number, seq, fields[payload_at]))
    if rows is None:
        raise Refused(f"no events table in {path}")
    raise Refused(f"the events table in {path} does not end")


def scan_payloads(dumps, words):
    """[(path, line number, what)] for each word found in an event's payload,
    and how many events were read."""
    hits = []
    count = 0
    for path in dumps:
        for number, seq, payload in events_payloads(path):
            count += 1
            seen = set()
            for label, value in words:
                base = label.split(" (")[0]
                if base not in seen and value in payload:
                    seen.add(base)
                    hits.append((path, number, f"{base} (events.payload, seq {seq})"))
    return hits, count


def scan_logs(path, words):
    """[(line number, what)] for each word and each nonce-shaped marker a
    log line holds, one hit per word or shape and line."""
    hits = []
    with open(path, "rb") as handle:
        lines = handle.read().splitlines()
    for number, line in enumerate(lines, start=1):
        seen = set()
        for label, value in words:
            base = label.split(" (")[0]
            if base not in seen and value in line:
                seen.add(base)
                hits.append((number, label))
        if NONCE_SHAPE[1].search(line):
            hits.append((number, NONCE_SHAPE[0]))
    return hits


def base64_pieces(raw):
    """The base64 text a secret's bytes always encode to, at each of the
    three offsets it can start at inside a longer encoded text: only the
    characters that depend on the secret's bytes alone."""
    pieces = []
    for offset in range(3):
        encoded = base64.b64encode(b"\0" * offset + raw)
        start = (offset * 4 + 2) // 3
        end = (offset + len(raw)) // 3 * 4
        piece = encoded[start:end]
        if len(piece) >= SHORTEST_BASE64:
            pieces.append(piece)
    return pieces


def forms(label, value):
    """[(label, bytes)]: the secret as written, then every other form of it
    that differs from that, each labelled with how it is written."""
    raw = value.encode("utf-8")
    found = [(label, raw)]
    others = [
        ("JSON-escaped", json.dumps(value)[1:-1].encode("utf-8")),
        ("URL-encoded", urllib.parse.quote(value, safe="").encode("ascii")),
        ("form-encoded", urllib.parse.quote_plus(value).encode("ascii")),
    ] + [("base64", piece) for piece in base64_pieces(raw)]
    seen = {raw}
    for how, encoded in others:
        if encoded not in seen:
            seen.add(encoded)
            found.append((f"{label} ({how})", encoded))
    return found


def files_under(paths):
    """Every regular file under the paths, in a stable order."""
    found = []
    for path in paths:
        if os.path.isfile(path):
            found.append(path)
        elif os.path.isdir(path):
            for folder, folders, names in os.walk(path):
                folders.sort()
                found.extend(os.path.join(folder, name) for name in sorted(names)
                             if os.path.isfile(os.path.join(folder, name)))
        else:
            raise Refused(f"no such file or folder: {path}")
    if not found:
        raise Refused("no file to scan")
    return found


def read_lines(path):
    try:
        with open(path, "rb") as handle:
            return handle.read().splitlines()
    except OSError as error:
        raise Refused(f"cannot read {path}: {error.strerror}") from error


def credential_lines(path, emails):
    """Extract the allowed data from a credentials COPY section in place."""
    lines = read_lines(path)
    expected = {email.encode("utf-8") for email in emails}
    found = set()
    for index, line in enumerate(lines):
        header = CREDENTIALS_HEADER.fullmatch(line)
        if header:
            columns = [name.strip().strip(b'"') for name in header[1].split(b",")]
            if b"account_email" not in columns or b"plan" not in columns:
                raise Refused(f"the credentials table in {path} has no account_email or plan column")
            email_at = columns.index(b"account_email")
            for row in range(index + 1, len(lines)):
                if lines[row] == COPY_END:
                    return lines, len(expected - found)
                fields = lines[row].split(b"\t")
                if len(fields) != len(columns):
                    raise Refused(f"{path}:{row + 1}: a row of the credentials table does not match its columns")
                if fields[email_at] in expected:
                    found.add(fields[email_at])
                    fields[email_at] = b"[allowed account email]"
                    lines[row] = b"\t".join(fields)
            raise Refused(f"the credentials table in {path} does not end")
    raise Refused(f"no credentials table in {path}")


def read_token_markers(path):
    lines = read_lines(path)
    if not lines or any(not TOKEN_MARKER.fullmatch(line) for line in lines):
        raise Refused(f"invalid or empty token marker list in {path}")
    if len(set(lines)) != len(lines):
        raise Refused(f"duplicate token marker in {path}")
    return [line.decode("ascii") for line in lines]


def provider_record_lines(path, markers):
    """Extract only exact expected credential headers from the stand-in record."""
    lines = read_lines(path)
    expected = set(markers)
    found = set()
    for index, line in enumerate(lines):
        try:
            call = json.loads(line)
            headers = call["headers"]
            if not isinstance(headers, dict) or json.dumps(call).encode("utf-8") != line:
                raise ValueError
        except (ValueError, KeyError, TypeError) as error:
            raise Refused(f"{path}:{index + 1}: invalid stand-in API record") from error
        if call.get("method") != "GET":
            continue
        for name, prefix in (("authorization", "Bearer "), ("x-goog-api-key", "")):
            value = headers.get(name)
            if isinstance(value, str) and value.startswith(prefix) and value[len(prefix):] in expected:
                found.add(value[len(prefix):])
                headers[name] = "[allowed test token marker]"
        lines[index] = json.dumps(call).encode("utf-8")
    return lines, len(expected - found)


def scan_file(path, secrets):
    return scan_lines(read_lines(path), secrets)


def scan_lines(lines, secrets):
    """[(line number, what)] for every hit, one per secret or shape a line
    holds; then each secret found only once the line breaks are removed, at
    the line where it starts."""
    hits = []
    for number, line in enumerate(lines, start=1):
        for label, value in secrets:
            if value in line:
                hits.append((number, label))
        for label, shape in SHAPES:
            if shape.search(line):
                hits.append((number, label))
    found = {label for _number, label in hits}
    joined = b"".join(lines)
    starts = []
    position = 0
    for line in lines:
        starts.append(position)
        position += len(line)
    for label, value in secrets:
        if label in found:
            continue
        at = joined.find(value)
        if at >= 0:
            number = max(index for index, start in enumerate(starts) if start <= at) + 1
            hits.append((number, label))
    return hits


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--secrets", action="append", default=[], metavar="FILE")
    parser.add_argument("--literal", action="append", default=[], metavar="VALUE")
    parser.add_argument("--replies", action="append", default=[], metavar="FOLDER")
    parser.add_argument("--not-in-events", action="append", default=[], metavar="WORD")
    parser.add_argument("--events-dump", action="append", default=[], metavar="FILE")
    parser.add_argument("--not-in-logs", action="append", default=[], metavar="WORD")
    parser.add_argument("--logs", action="append", default=[], metavar="PATH")
    parser.add_argument("--credentials-dump", metavar="FILE")
    parser.add_argument("--account-email", action="append", default=[], metavar="VALUE")
    parser.add_argument("--provider-api-record", metavar="FILE")
    parser.add_argument("--token-markers", metavar="FILE")
    parser.add_argument("paths", nargs="*", metavar="PATH")
    # The end-to-end scripts add each test's folders between the options.
    arguments = parser.parse_intermixed_args(argv)
    try:
        if not (arguments.paths or arguments.events_dump or arguments.logs
                or arguments.credentials_dump or arguments.provider_api_record):
            raise Refused("no path to scan")
        if arguments.not_in_events and not arguments.events_dump:
            raise Refused("--not-in-events needs --events-dump")
        if arguments.not_in_logs and not arguments.logs:
            raise Refused("--not-in-logs needs --logs")
        if arguments.events_dump and not arguments.not_in_events:
            raise Refused("--events-dump needs --not-in-events")
        if arguments.account_email and not arguments.credentials_dump:
            raise Refused("--account-email needs --credentials-dump")
        if bool(arguments.provider_api_record) != bool(arguments.token_markers):
            raise Refused("--provider-api-record and --token-markers must be used together")
        secrets = replies = files = []
        special_files = []
        if arguments.credentials_dump:
            dump_lines, missing_email = credential_lines(arguments.credentials_dump, arguments.account_email)
            special_files.append((arguments.credentials_dump, dump_lines, missing_email, "account email"))
        markers = []
        if arguments.provider_api_record:
            markers = read_token_markers(arguments.token_markers)
            record_lines, missing_marks = provider_record_lines(arguments.provider_api_record, markers)
            special_files.append((arguments.provider_api_record, record_lines, missing_marks, "token marker"))
        if arguments.paths or special_files:
            replies = read_replies(arguments.replies)
            secrets = read_secrets(arguments.secrets, arguments.literal + arguments.account_email + markers, replies)
            files = files_under(arguments.paths) if arguments.paths else []
        event_words = read_words(arguments.not_in_events, "--not-in-events")
        log_words = read_words(arguments.not_in_logs, "--not-in-logs")
        try:
            logs = files_under(arguments.logs) if arguments.logs else []
        except Refused as refusal:
            raise Refused(f"no log file to scan ({refusal})") from refusal
        payload_hits, events = scan_payloads(arguments.events_dump, event_words) if event_words else ([], 0)
    except Refused as refusal:
        print(f"secret_scan: {refusal}", file=sys.stderr)
        return 2

    total = 0
    for path in files:
        for number, label in scan_file(path, secrets):
            print(f"{path}:{number}: {label}")
            total += 1
    for path, lines, missing, label in special_files:
        for number, hit in scan_lines(lines, secrets):
            print(f"{path}:{number}: {hit}")
            total += 1
        if missing:
            print(f"{path}: expected {label} missing ({missing})")
            total += missing
    for path, number, label in payload_hits:
        print(f"{path}:{number}: {label}")
        total += 1
    for path in logs:
        for number, label in scan_logs(path, log_words):
            print(f"{path}:{number}: {label}")
            total += 1
    scanned = len(files) + len(special_files)
    if total:
        print(f"secret_scan: {scanned + len(logs)} files, {total} hits")
        return 1
    if scanned:
        listed = len({label.split(" (")[0] for label, _value in secrets})
        reply_files = len({label for label, _value in replies if label.startswith("marker of ")})
        also = f", {reply_files} reply files" if reply_files else ""
        print(f"secret_scan: {scanned} files, {listed} secrets and {len(SHAPES)} shapes{also}, no secret found")
    if arguments.account_email:
        print(f"secret_scan: {len(set(arguments.account_email))} expected account email found")
    if markers:
        print(f"secret_scan: {len(markers)} expected token markers found")
    if event_words or log_words:
        words = len(arguments.not_in_events) + len(arguments.not_in_logs)
        log_files = f"{len(logs)} log file" + ("" if len(logs) == 1 else "s")
        print(f"secret_scan: {events} events and {log_files}, {words} words, no task text found")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
