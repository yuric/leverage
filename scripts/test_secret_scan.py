#!/usr/bin/env python3
"""Self-test for secret_scan.py.

secret_scan.py is step 5 of the end-to-end run (milestone 2 plan §5.2):
it looks through the containers' logs, the helper's and the runs' logs
and a data-only dump of the database for the secrets the run used (the
owner's password, the session and helper tokens, the stand-ins' made-up
email and organisation) and for anything shaped like a leverage token
(IN-18), and one hit fails the run (L721). These cases prove that it
finds each kind of hit, says where without ever printing the secret,
passes what the redaction leaves (`lvs_[removed]`) and a token's SHA-256
digest, and refuses a scan that could pass without looking: no file, an
empty list of secrets, a secret too short to mean anything. With
--replies (milestone 3 plan §5.2), it finds a reply file's marker and a
long line of its outputs, the pieces of a line around a reset placeholder,
and never a short common line such as "ready".

Usage: python3 scripts/test_secret_scan.py [-v]
Standard library only; exits 0 when every case behaves as expected.
"""

import base64
import json
import subprocess
import sys
import tempfile
import unittest
import urllib.parse
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "secret_scan.py"

# Made-up values in the shapes the run uses.
PASSWORD = "made-up-e2e-owner-password"
# A made-up password with the characters that JSON, a URL and a form
# encode differently from the raw text.
ODD_PASSWORD = 'made-up "pass/word" & more+'

SESSION = "lvo_" + "A" * 21 + "b-c_d" + "E" * 17
HELPER = "lvh_" + "x" * 43
SEAT = "lvs_" + "0123456789abcdef" * 2 + "ABCDEFGHIJK"
EMAIL = "standin.owner@example.invalid"
ORG = "Stand-in Example Org"


class Scan:
    """A scratch folder with files to scan and a list of secrets."""

    def __init__(self):
        self._folder = tempfile.TemporaryDirectory()
        self.root = Path(self._folder.name)
        self.logs = self.root / "logs"
        self.logs.mkdir()

    def close(self):
        self._folder.cleanup()

    def file(self, name, text):
        path = self.logs / name
        path.parent.mkdir(parents=True, exist_ok=True)
        if isinstance(text, bytes):
            path.write_bytes(text)
        else:
            path.write_text(text, encoding="utf-8")
        return path

    def secrets(self, *values, name="secrets.txt"):
        path = self.root / name
        path.write_text("".join(f"{value}\n" for value in values), encoding="utf-8")
        return path

    def run(self, *arguments):
        result = subprocess.run(
            [sys.executable, "-I", str(SCRIPT), *map(str, arguments)],
            capture_output=True, text=True, check=False)
        return result.returncode, result.stdout + result.stderr


class SecretScanTests(unittest.TestCase):
    def setUp(self):
        self.scan = Scan()
        self.addCleanup(self.scan.close)

    def assertNoSecretPrinted(self, output):
        for value in (PASSWORD, SESSION, HELPER, SEAT, EMAIL, ORG):
            self.assertNotIn(value, output)

    def test_clean_files_pass(self):
        self.scan.file("api.log", "Started GET /v1/health\nCompleted 200 OK\n")
        self.scan.file("dump.sql", "COPY public.sessions (id, token_hash) FROM stdin;\n")
        secrets = self.scan.secrets(PASSWORD, SESSION, EMAIL, ORG)
        code, output = self.scan.run("--secrets", secrets, self.scan.logs)
        self.assertEqual(code, 0, output)
        self.assertIn("2 files", output)
        self.assertIn("no secret found", output)

    def test_a_listed_secret_is_found_with_its_place_and_never_printed(self):
        self.scan.file("helper.log", "line one\nsigned in as " + PASSWORD + " here\n")
        secrets = self.scan.secrets(PASSWORD, EMAIL)
        code, output = self.scan.run("--secrets", secrets, self.scan.logs)
        self.assertEqual(code, 1, output)
        self.assertIn("helper.log:2", output)
        self.assertIn("secret 1 of " + str(secrets), output)
        self.assertNoSecretPrinted(output)

    def test_the_stand_ins_email_and_organisation_are_found(self):
        self.scan.file("dump.sql", f"1\t{EMAIL}\n2\tPlan of {ORG}\n")
        secrets = self.scan.secrets(EMAIL, ORG)
        code, output = self.scan.run("--secrets", secrets, self.scan.logs)
        self.assertEqual(code, 1, output)
        self.assertIn("dump.sql:1: secret 1", output)
        self.assertIn("dump.sql:2: secret 2", output)
        self.assertNoSecretPrinted(output)

    def test_every_kind_of_token_is_found_by_its_shape_alone(self):
        self.scan.file("seat-1.log", f"seat {SEAT}\n")
        self.scan.file("api.log", f"Authorization: {HELPER}\n")
        self.scan.file("sub/db.log", f"session={SESSION};\n")
        secrets = self.scan.secrets(PASSWORD)
        code, output = self.scan.run("--secrets", secrets, self.scan.logs)
        self.assertEqual(code, 1, output)
        for name in ("seat-1.log:1: token shape", "api.log:1: token shape", "db.log:1: token shape"):
            self.assertIn(name, output)
        self.assertIn("3 hits", output)
        self.assertNoSecretPrinted(output)

    def test_a_bearer_value_is_found(self):
        self.scan.file("api.log", "Authorization: Bearer abcdefghijklmnopqrstuvwxyz012345\n")
        code, output = self.scan.run("--secrets", self.scan.secrets(PASSWORD), self.scan.logs)
        self.assertEqual(code, 1, output)
        self.assertIn("api.log:1: bearer value", output)
        self.assertNotIn("abcdefghijklmnopqrstuvwxyz012345", output)

    def test_what_the_redaction_leaves_and_a_digest_pass(self):
        digest = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
        self.scan.file(
            "helper.log",
            "2026-11-19T10:00:00Z helper info: started with lvh_[removed]\n"
            "seat token lvs_[removed] and Bearer [removed]\n"
            f"token_hash {digest}\n"
            "the prefixes lvs_, lvh_ and lvo_ alone\n")
        code, output = self.scan.run("--secrets", self.scan.secrets(PASSWORD), self.scan.logs)
        self.assertEqual(code, 0, output)

    def test_a_secret_counts_once_per_line(self):
        self.scan.file("a.log", f"{PASSWORD} and {PASSWORD}\n{PASSWORD}\n")
        code, output = self.scan.run("--secrets", self.scan.secrets(PASSWORD), self.scan.logs)
        self.assertEqual(code, 1, output)
        self.assertIn("a.log:1: secret 1", output)
        self.assertIn("a.log:2: secret 1", output)
        self.assertIn("2 hits", output)

    def test_bytes_that_are_not_utf8_are_still_scanned(self):
        self.scan.file("dump.bin", b"\xff\xfe\x00" + PASSWORD.encode() + b"\x00\xff\n")
        code, output = self.scan.run("--secrets", self.scan.secrets(PASSWORD), self.scan.logs)
        self.assertEqual(code, 1, output)
        self.assertIn("dump.bin:1: secret 1", output)

    def test_several_secrets_files_and_literals_add_up(self):
        self.scan.file("a.log", f"{ORG}\n")
        first = self.scan.secrets(PASSWORD, name="one.txt")
        second = self.scan.secrets("# a comment line", "", SESSION, name="two.txt")
        code, output = self.scan.run(
            "--secrets", first, "--secrets", second, "--literal", ORG, self.scan.logs)
        self.assertEqual(code, 1, output)
        self.assertIn("a.log:1: literal 1", output)
        self.assertNoSecretPrinted(output)

    def test_a_file_given_by_itself_is_scanned(self):
        path = self.scan.file("one.log", f"{PASSWORD}\n")
        code, output = self.scan.run("--secrets", self.scan.secrets(PASSWORD), path)
        self.assertEqual(code, 1, output)
        self.assertIn("1 files", output)

    def test_a_missing_path_is_refused(self):
        code, output = self.scan.run(
            "--secrets", self.scan.secrets(PASSWORD), self.scan.root / "nothing-here")
        self.assertEqual(code, 2, output)
        self.assertIn("nothing-here", output)

    def test_no_file_to_scan_is_refused(self):
        empty = self.scan.root / "empty"
        empty.mkdir()
        code, output = self.scan.run("--secrets", self.scan.secrets(PASSWORD), empty)
        self.assertEqual(code, 2, output)
        self.assertIn("no file", output)

    def test_no_secret_to_look_for_is_refused(self):
        self.scan.file("a.log", "text\n")
        code, output = self.scan.run("--secrets", self.scan.secrets("# only a comment"), self.scan.logs)
        self.assertEqual(code, 2, output)
        self.assertIn("no secret", output)

    def test_a_missing_secrets_file_is_refused(self):
        self.scan.file("a.log", "text\n")
        code, output = self.scan.run("--secrets", self.scan.root / "absent.txt", self.scan.logs)
        self.assertEqual(code, 2, output)

    def test_a_secret_too_short_to_mean_anything_is_refused(self):
        self.scan.file("a.log", "text\n")
        code, output = self.scan.run("--secrets", self.scan.secrets("abc"), self.scan.logs)
        self.assertEqual(code, 2, output)
        self.assertIn("too short", output)
        self.assertNotIn("abc\n", output)

    def test_a_secret_written_json_escaped_is_found(self):
        self.scan.file("api.log", json.dumps({"password": ODD_PASSWORD}) + "\n")
        code, output = self.scan.run("--secrets", self.scan.secrets(ODD_PASSWORD), self.scan.logs)
        self.assertEqual(code, 1, output)
        self.assertIn("api.log:1: secret 1", output)
        self.assertIn("JSON-escaped", output)
        self.assertNotIn(ODD_PASSWORD, output)

    def test_a_secret_written_url_or_form_encoded_is_found(self):
        self.scan.file("url.log", "GET /x?p=" + urllib.parse.quote(ODD_PASSWORD, safe="") + "\n")
        self.scan.file("form.log", "password=" + urllib.parse.quote_plus(ODD_PASSWORD) + "\n")
        code, output = self.scan.run("--secrets", self.scan.secrets(ODD_PASSWORD), self.scan.logs)
        self.assertEqual(code, 1, output)
        self.assertIn("url.log:1: secret 1", output)
        self.assertIn("form.log:1: secret 1", output)
        self.assertNotIn(ODD_PASSWORD, output)

    def test_a_secret_written_in_base64_is_found_at_any_offset(self):
        alone = base64.b64encode(PASSWORD.encode()).decode()
        inside = base64.b64encode(b"x" + PASSWORD.encode() + b"yz").decode()
        self.scan.file("alone.log", f"blob {alone}\n")
        self.scan.file("inside.log", f"blob {inside}\n")
        code, output = self.scan.run("--secrets", self.scan.secrets(PASSWORD), self.scan.logs)
        self.assertEqual(code, 1, output)
        self.assertIn("alone.log:1: secret 1", output)
        self.assertIn("inside.log:1: secret 1", output)
        self.assertIn("base64", output)

    def test_the_shortest_secret_allowed_is_found_in_base64_at_all_three_offsets(self):
        # Eight characters is the shortest secret the scan takes, because a
        # shorter one leaves a base64 piece too short to look for at one of
        # the three offsets.
        secret = "abcdefgh"
        for offset in range(3):
            encoded = base64.b64encode(b"x" * offset + secret.encode() + b"yyyy").decode()
            self.scan.file(f"offset{offset}.log", f"blob {encoded}\n")
        code, output = self.scan.run("--literal", secret, self.scan.logs)
        self.assertEqual(code, 1, output)
        for offset in range(3):
            self.assertIn(f"offset{offset}.log:1: literal 1", output)
        self.assertNotIn(secret, output)

    def test_a_secret_under_eight_characters_is_refused(self):
        # Its base64 copy could not be found at every offset.
        self.scan.file("a.log", "text\n")
        for secret in ("abcdef", "abcdefg"):
            code, output = self.scan.run("--literal", secret, self.scan.logs)
            self.assertEqual(code, 2, output)
            self.assertIn("too short", output)

    def test_a_secret_wrapped_across_lines_is_found_where_it_starts(self):
        self.scan.file("wrapped.log", "first line\nvalue " + PASSWORD[:10] + "\n" + PASSWORD[10:] + " end\n")
        code, output = self.scan.run("--secrets", self.scan.secrets(PASSWORD), self.scan.logs)
        self.assertEqual(code, 1, output)
        self.assertIn("wrapped.log:2: secret 1", output)
        self.assertNotIn(PASSWORD, output)

    def test_a_bearer_value_is_found_whatever_its_case(self):
        self.scan.file("lower.log", "authorization: bearer abcdefghijklmnopqrstuvwxyz012345\n")
        self.scan.file("upper.log", "AUTHORIZATION: BEARER abcdefghijklmnopqrstuvwxyz012345\n")
        code, output = self.scan.run("--secrets", self.scan.secrets(PASSWORD), self.scan.logs)
        self.assertEqual(code, 1, output)
        self.assertIn("lower.log:1: bearer value", output)
        self.assertIn("upper.log:1: bearer value", output)

    def test_no_path_is_refused(self):
        code, output = self.scan.run("--secrets", self.scan.secrets(PASSWORD))
        self.assertEqual(code, 2, output)


# Made-up reply files in the shape of mac/Tests/StandIns/replies (milestone 3
# plan HD-8): each names its marker, and its outputs hold the lines a tool's
# reply would. The scan looks for every marker and for every line of an
# output that is 40 characters or longer; a shorter line, such as "{" or
# "ready", is in every log and is not looked for.
MARKER = "LVRG-REPLY-0123456789ab"
LONG_LINE = '{"type":"result","is_error":true,"result":"Made-up limit reply for the scan"}'
PLACEHOLDER_LINE = ('{"error":"Made-up five-hour window reached, it comes back at @RESET_AT_ISO@ '
                    'and not one second before that time"}')
SHORT_LINE = "ready"


def reply_file(marker=MARKER, stdout=LONG_LINE + "\n", stderr=SHORT_LINE + "\n"):
    return json.dumps({
        "meta": {"provider": "claude", "kind": "run", "basis": "invented", "marker": marker},
        "exit_status": 1, "stdout": stdout, "stderr": stderr,
    })


class ReplyFileTests(unittest.TestCase):
    """--replies FOLDER: a tool's reply must appear nowhere but in the
    stand-ins' own folder (plan §5.2, step 3)."""

    def setUp(self):
        self.scan = Scan()
        self.addCleanup(self.scan.close)
        self.replies = self.scan.root / "replies" / "claude"
        self.replies.mkdir(parents=True)
        (self.replies / "run-limit.json").write_text(reply_file(), encoding="utf-8")

    def run_scan(self):
        return self.scan.run(
            "--secrets", self.scan.secrets(PASSWORD), "--replies", self.scan.root / "replies", self.scan.logs)

    def test_a_marker_found_is_a_hit_named_by_its_reply_file(self):
        self.scan.file("runner.log", f"run ended: {MARKER}\n")
        code, output = self.run_scan()
        self.assertEqual(code, 1, output)
        self.assertIn("runner.log:1: marker of claude/run-limit.json", output)
        self.assertNotIn(MARKER, output)

    def test_a_long_line_of_a_reply_found_is_a_hit(self):
        self.scan.file("helper.log", "first\nthe tool said " + LONG_LINE + "\n")
        code, output = self.run_scan()
        self.assertEqual(code, 1, output)
        self.assertIn("helper.log:2: stdout line 1 of claude/run-limit.json", output)
        self.assertNotIn(LONG_LINE, output)

    def test_a_long_line_is_found_json_escaped(self):
        self.scan.file("dump.sql", json.dumps({"note": LONG_LINE}) + "\n")
        code, output = self.run_scan()
        self.assertEqual(code, 1, output)
        self.assertIn("dump.sql:1: stdout line 1 of claude/run-limit.json (JSON-escaped)", output)

    def test_a_short_common_line_of_a_reply_is_not_a_hit(self):
        self.scan.file("runner.log", f"{SHORT_LINE}\n{{\n}}\n")
        code, output = self.run_scan()
        self.assertEqual(code, 0, output)
        self.assertIn("no secret found", output)

    def test_the_long_pieces_around_a_reset_placeholder_are_looked_for(self):
        (self.replies / "run-limit.json").write_text(
            reply_file(stdout=PLACEHOLDER_LINE + "\n"), encoding="utf-8")
        played = PLACEHOLDER_LINE.replace("@RESET_AT_ISO@", "2026-11-19T18:00:00Z")
        self.scan.file("runner.log", played + "\n")
        code, output = self.run_scan()
        self.assertEqual(code, 1, output)
        self.assertIn("runner.log:1: stdout line 1 of claude/run-limit.json", output)

    def test_every_reply_file_of_the_stand_ins_is_read(self):
        stand_ins = HERE.parent / "mac" / "Tests" / "StandIns" / "replies"
        self.scan.file("clean.log", "nothing here\n")
        code, output = self.scan.run("--secrets", self.scan.secrets(PASSWORD), "--replies", stand_ins, self.scan.logs)
        self.assertEqual(code, 0, output)
        markers = sum(1 for _ in stand_ins.rglob("*.json"))
        self.assertIn(f"{markers} reply files", output)

    def test_a_reply_file_with_no_marker_is_refused(self):
        (self.replies / "run-limit.json").write_text(reply_file(marker=""), encoding="utf-8")
        self.scan.file("clean.log", "nothing here\n")
        code, output = self.run_scan()
        self.assertEqual(code, 2, output)
        self.assertIn("no marker", output)

    def test_a_replies_folder_with_no_reply_file_is_refused(self):
        (self.replies / "run-limit.json").unlink()
        self.scan.file("clean.log", "nothing here\n")
        code, output = self.run_scan()
        self.assertEqual(code, 2, output)


# Task text is content: it belongs in its own rows (tasks, criteria, rule
# versions, rule checks) and never in an event's payload or a log line
# (milestone 4 plan RT-8). Each end-to-end test of the rule checks puts
# marker words of its own in its details, its handoff note, its rule's
# instruction, its override reason and the stand-in checker's reason; the
# scan is given those words.
MARKER_WORD = "zebrafjord7k"
OTHER_WORD = "quokkaplume3"
EVENTS_HEADER = ("COPY public.events (id, workspace_id, seq, at, effective_at, type, schema_version, "
                 "actor_kind, actor_id, project_id, task_id, round, subject_kind, subject_id, cause_id, "
                 "command_id, payload, created_at, xact_id) FROM stdin;")
NONCE = "0123456789ab"


def event_row(seq, event_type, payload):
    """One row of the events table as pg_dump --data-only writes it: tab
    separated, \\N for a null, the payload as jsonb's text."""
    fields = ["00000000-0000-4000-8000-%012d" % seq, "00000000-0000-4000-8000-000000000001", str(seq),
              "2026-11-20 10:00:00+00", "2026-11-20 10:00:00+00", event_type, "1", "seat", "\\N", "\\N",
              "\\N", "\\N", "\\N", "\\N", "\\N", "key-%d" % seq, json.dumps(payload),
              "2026-11-20 10:00:00+00", "1000"]
    return "\t".join(fields)


def dump(event_rows, tasks_details="Plain details."):
    """A data-only dump with a tasks table and an events table."""
    return "\n".join([
        "--",
        "-- Data for Name: tasks; Type: TABLE DATA; Schema: public; Owner: -",
        "--",
        "COPY public.tasks (id, title, details) FROM stdin;",
        "00000000-0000-4000-8000-0000000000aa\tA task\t" + tasks_details,
        "\\.",
        "",
        EVENTS_HEADER,
        *event_rows,
        "\\.",
        "",
    ])


class TaskTextTests(unittest.TestCase):
    """--not-in-events WORD with --events-dump FILE, and --not-in-logs WORD
    with --logs PATH (plan RT-8, §5.2 step 3): a marker word of a test's
    task text in an event's payload or in a log line is a hit; the same
    word in the task's own row is not. A log holds no nonce-shaped marker
    of a check or draft frame either."""

    def setUp(self):
        self.scan = Scan()
        self.addCleanup(self.scan.close)
        self.logs = self.scan.root / "service-logs"
        self.logs.mkdir()

    def log(self, name, text):
        path = self.logs / name
        path.write_text(text, encoding="utf-8")
        return path

    def write_dump(self, text):
        path = self.scan.root / "dump.sql"
        path.write_text(text, encoding="utf-8")
        return path

    def run_words(self, dump_path, *extra):
        return self.scan.run(
            "--not-in-events", MARKER_WORD, "--not-in-events", OTHER_WORD, "--events-dump", dump_path,
            "--not-in-logs", MARKER_WORD, "--not-in-logs", OTHER_WORD, "--logs", self.logs, *extra)

    def test_neither_in_a_payload_nor_in_a_log_passes(self):
        path = self.write_dump(dump(
            [event_row(1, "task.created", {"title_length": 6}), event_row(2, "check.finished", {"result": "failed"})],
            tasks_details=f"Mention {MARKER_WORD} in the details."))
        self.log("api.log", "Completed 200 OK\nrefused submit_task blocked_by_rule rule=made-up\n")
        code, output = self.run_words(path)
        self.assertEqual(code, 0, output)
        self.assertIn("2 events", output)
        self.assertIn("1 log file", output)
        self.assertIn("no task text found", output)

    def test_a_marker_word_in_an_events_payload_is_a_hit(self):
        path = self.write_dump(dump([
            event_row(1, "task.created", {"title_length": 6}),
            event_row(2, "check.finished", {"result": "failed", "reason": f"It lacks {OTHER_WORD}."}),
        ]))
        self.log("api.log", "Completed 200 OK\n")
        code, output = self.run_words(path)
        self.assertEqual(code, 1, output)
        self.assertIn("dump.sql:10: word 2 of --not-in-events (events.payload, seq 2)", output)
        self.assertNotIn(OTHER_WORD, output)

    def test_a_marker_word_elsewhere_in_an_events_row_is_not_a_hit(self):
        # Only the payload is task text's way out; the type and keys are
        # the server's own words.
        row = event_row(1, "task.created", {"n": 1}).replace("key-1", f"key-{MARKER_WORD}")
        path = self.write_dump(dump([row]))
        self.log("api.log", "Completed 200 OK\n")
        code, output = self.run_words(path)
        self.assertEqual(code, 0, output)

    def test_a_marker_word_in_a_log_line_is_a_hit(self):
        path = self.write_dump(dump([event_row(1, "task.created", {"n": 1})]))
        self.log("api.log", "Completed 200 OK\n")
        self.log("runner.log", f"line one\nwarning: the check said {MARKER_WORD} is missing\n")
        code, output = self.run_words(path)
        self.assertEqual(code, 1, output)
        self.assertIn("runner.log:2: word 1 of --not-in-logs", output)
        self.assertNotIn(MARKER_WORD, output)

    def test_a_marker_word_json_escaped_in_a_log_is_a_hit(self):
        # A word JSON writes differently from its text (ensure_ascii).
        accented = "z\u00e9brafjord7k"
        path = self.write_dump(dump([event_row(1, "task.created", {"n": 1})]))
        self.log("api.log", json.dumps({"params": {"details": f"Find {accented}"}}) + "\n")
        self.assertNotIn(accented, (self.logs / "api.log").read_text(encoding="utf-8"))
        code, output = self.scan.run(
            "--not-in-events", MARKER_WORD, "--events-dump", path, "--not-in-logs", accented, "--logs", self.logs)
        self.assertEqual(code, 1, output)
        self.assertIn("api.log:1: word 1 of --not-in-logs (JSON-escaped)", output)

    def test_a_nonce_shaped_marker_in_a_log_is_a_hit(self):
        path = self.write_dump(dump([event_row(1, "task.created", {"n": 1})]))
        for number, line in enumerate([f"LEVERAGE-VERDICT-{NONCE}: PASSED", f"<<<LEVERAGE-QUOTE-{NONCE} details>>>"]):
            with self.subTest(line=line):
                self.log("runner.log", f"the tool answered\n{line}\n")
                code, output = self.run_words(path)
                self.assertEqual(code, 1, output)
                self.assertIn("runner.log:2: nonce-shaped marker", output)

    def test_a_questions_and_approvals_frame_marker_in_a_log_is_a_hit(self):
        for marker in ("DECISION", "REASON", "ANSWER", "BASIS", "PASS-ON", "DONE", "CANNOT"):
            with self.subTest(marker=marker):
                self.log("runner.log", f"the tool answered\nLEVERAGE-{marker}-{NONCE}: made-up text\n")
                code, output = self.scan.run("--logs", self.logs)
                self.assertEqual(code, 1, output)
                self.assertIn("runner.log:2: nonce-shaped marker", output)
                self.assertNotIn(NONCE, output)

    def test_a_marker_without_twelve_hex_characters_is_not_a_hit(self):
        path = self.write_dump(dump([event_row(1, "task.created", {"n": 1})]))
        self.log("runner.log", "LEVERAGE-VERDICT- is the frame's word\nLEVERAGE-QUOTE-0123 short\n")
        code, output = self.run_words(path)
        self.assertEqual(code, 0, output)

    def test_a_nonce_outside_the_logs_is_not_looked_for(self):
        # The stand-ins' record of each call holds the prompts, nonce and
        # all: it is scanned for secrets, not for task text.
        path = self.write_dump(dump([event_row(1, "task.created", {"n": 1})]))
        self.log("api.log", "Completed 200 OK\n")
        calls = self.scan.file("calls.jsonl", json.dumps({"argv": [f"LEVERAGE-VERDICT-{NONCE} {MARKER_WORD}"]}) + "\n")
        code, output = self.run_words(path, "--secrets", self.scan.secrets(PASSWORD), calls)
        self.assertEqual(code, 0, output)

    def test_the_words_with_the_secrets_add_up(self):
        path = self.write_dump(dump([event_row(1, "task.created", {"reason": MARKER_WORD})]))
        self.log("helper.log", f"{MARKER_WORD}\n")
        self.scan.file("api.log", "signed in with " + PASSWORD + "\n")
        code, output = self.run_words(path, "--secrets", self.scan.secrets(PASSWORD), self.scan.logs)
        self.assertEqual(code, 1, output)
        self.assertIn("api.log:1: secret 1", output)
        self.assertIn("helper.log:1: word 1 of --not-in-logs", output)
        self.assertIn("dump.sql:9: word 1 of --not-in-events", output)
        self.assertIn("3 hits", output)

    def test_words_without_a_dump_or_logs_are_refused(self):
        self.log("api.log", "Completed 200 OK\n")
        path = self.write_dump(dump([event_row(1, "task.created", {"n": 1})]))
        for arguments, missing in ((["--not-in-events", MARKER_WORD, "--logs", self.logs], "--events-dump"),
                                   (["--not-in-logs", MARKER_WORD, "--events-dump", path], "--logs")):
            with self.subTest(arguments=arguments):
                code, output = self.scan.run(*arguments)
                self.assertEqual(code, 2, output)
                self.assertIn(f"needs {missing}", output)

    def test_a_dump_with_no_events_table_is_refused(self):
        path = self.write_dump("COPY public.tasks (id) FROM stdin;\n\\.\n")
        self.log("api.log", "Completed 200 OK\n")
        code, output = self.run_words(path)
        self.assertEqual(code, 2, output)
        self.assertIn("no events table", output)

    def test_an_events_table_with_no_payload_column_is_refused(self):
        path = self.write_dump("COPY public.events (id, seq) FROM stdin;\n1\t1\n\\.\n")
        self.log("api.log", "Completed 200 OK\n")
        code, output = self.run_words(path)
        self.assertEqual(code, 2, output)
        self.assertIn("no payload column", output)

    def test_a_word_too_short_to_mean_anything_is_refused(self):
        path = self.write_dump(dump([event_row(1, "task.created", {"n": 1})]))
        self.log("api.log", "Completed 200 OK\n")
        code, output = self.scan.run(
            "--not-in-events", "short", "--events-dump", path, "--not-in-logs", MARKER_WORD, "--logs", self.logs)
        self.assertEqual(code, 2, output)
        self.assertIn("word 1 of --not-in-events is too short", output)

    def test_paths_to_scan_may_come_between_the_options(self):
        # The end-to-end scripts add each test's folders as they find them.
        path = self.write_dump(dump([event_row(1, "task.created", {"n": 1})]))
        self.log("api.log", "Completed 200 OK\n")
        api = self.scan.file("api.log", "signed in with " + PASSWORD + "\n")
        code, output = self.scan.run(
            "--secrets", self.scan.secrets(PASSWORD), self.logs, "--logs", self.logs, api,
            "--not-in-logs", MARKER_WORD, "--not-in-events", MARKER_WORD, "--events-dump", path)
        self.assertEqual(code, 1, output)
        self.assertIn("api.log:1: secret 1", output)

    def test_logs_alone_are_looked_at_for_a_nonce(self):
        # The real checks of §5.5 have no marker word of their own.
        self.log("runner.log", f"LEVERAGE-REASON-{NONCE}: fine\n")
        code, output = self.scan.run("--logs", self.logs)
        self.assertEqual(code, 1, output)
        self.assertIn("runner.log:1: nonce-shaped marker", output)

    def test_logs_with_no_file_are_refused(self):
        path = self.write_dump(dump([event_row(1, "task.created", {"n": 1})]))
        code, output = self.run_words(path)
        self.assertEqual(code, 2, output)
        self.assertIn("no log file", output)


class CredentialScanTests(unittest.TestCase):
    def setUp(self):
        self.scan = Scan()
        self.addCleanup(self.scan.close)
        self.log = self.scan.file("helper.log", "nothing here\n")

    def run_scan(self, *arguments):
        return self.scan.run("--secrets", self.scan.secrets(PASSWORD), self.log, *arguments)

    def run_dump(self, email=EMAIL, plan="stand-in plan", name="One", outside="no secret"):
        # The five scripts use pg_dump --data-only --no-owner and COPY's
        # actual column order. PostgreSQL quotes the position column.
        dump_path = self.scan.root / "dump.sql"
        dump_path.write_text(
            "-- PostgreSQL database dump\n"
            "COPY public.credentials (id, workspace_id, kind, provider, name, masked_label, plan, "
            'account_email, state, limited_until, "position", model, effort, strength_rank, last_verified_at, '
            "created_at, updated_at, limited_since) FROM stdin;\n"
            f"1\t2\tlogin\tclaude\t{name}\t\\N\t{plan}\t{email}\tactive\t\\N\t0\t\\N\t\\N\t1\t\\N\t"
            "2026-11-21 12:00:00+00\t2026-11-21 12:00:00+00\t\\N\n\\.\n"
            "COPY public.helper_requests (id, result) FROM stdin;\n"
            f"1\t{json.dumps({'account_email': outside})}\n\\.\n", encoding="utf-8")
        return self.run_scan("--credentials-dump", dump_path, "--account-email", EMAIL)

    def test_the_expected_email_in_the_account_email_column_passes(self):
        code, output = self.run_dump()
        self.assertEqual(code, 0, output)
        self.assertIn("1 expected account email found", output)
        self.assertNotIn(EMAIL, output)

    def test_a_missing_or_partial_account_email_fails(self):
        for email in (r"\N", "prefix-" + EMAIL):
            with self.subTest(case="partial" if email.endswith(EMAIL) else "null"):
                code, output = self.run_dump(email=email)
                self.assertEqual(code, 1, output)
                self.assertIn("expected account email missing", output)
                if email.endswith(EMAIL):
                    self.assertIn("dump.sql:3:", output)
                self.assertNotIn(EMAIL, output)

    def test_the_expected_email_is_found_in_other_columns_and_logs(self):
        for column in ("name", "plan", "outside"):
            with self.subTest(column=column):
                code, output = self.run_dump(**{column: EMAIL})
                self.assertEqual(code, 1, output)
                self.assertIn("dump.sql:", output)
                self.assertNotIn(EMAIL, output)
        self.log.write_text(EMAIL, encoding="utf-8")
        code, output = self.run_dump()
        self.assertEqual(code, 1, output)
        self.assertIn("helper.log:1:", output)
        self.assertNotIn(EMAIL, output)

    def test_other_secrets_in_account_fact_columns_still_fail(self):
        code, output = self.run_dump(email=PASSWORD, plan=PASSWORD)
        self.assertEqual(code, 1, output)
        self.assertIn("dump.sql:3: secret 1", output)
        self.assertNotIn(PASSWORD, output)

    def test_a_dump_without_account_columns_is_refused(self):
        path = self.scan.file("dump.sql", "COPY public.credentials (id, name) FROM stdin;\n1\tOne\n\\.\n")
        code, output = self.run_scan("--credentials-dump", path, "--account-email", EMAIL)
        self.assertEqual(code, 2, output)
        self.assertIn("no account_email or plan column", output)

    def test_malformed_credentials_copy_cannot_pass(self):
        header = "COPY public.credentials (id, plan, account_email) FROM stdin;\n"
        for dump_text, message in (("", "no credentials table"),
                                   (header + "1\tOne\t\\N\n", "does not end"),
                                   (header + "1\tOne\n\\.\n", "does not match its columns")):
            with self.subTest(message=message):
                path = self.scan.file("dump.sql", dump_text)
                code, output = self.run_scan("--credentials-dump", path, "--account-email", EMAIL)
                self.assertEqual(code, 2, output)
                self.assertIn(message, output)

    def test_an_expected_account_email_without_a_dump_is_refused(self):
        code, output = self.run_scan("--account-email", EMAIL)
        self.assertEqual(code, 2, output)
        self.assertIn("needs --credentials-dump", output)

    def token_record(self, *markers, extra=""):
        path = self.scan.root / "provider-calls.jsonl"
        entries = [json.dumps({"method": "GET", "path": "/api/v1/key",
                               "headers": {"authorization": "Bearer " + marker}}) for marker in markers]
        path.write_text("\n".join(entries) + "\n" + extra, encoding="utf-8")
        return path

    def test_each_expected_token_marker_must_be_in_the_stand_in_record(self):
        markers = ["LVRG-TOKEN-" + f"{index:012x}" for index in (1, 2)]
        expected = self.scan.secrets(*markers, name="markers.txt")
        path = self.token_record(*markers)
        code, output = self.run_scan("--provider-api-record", path, "--token-markers", expected)
        self.assertEqual(code, 0, output)
        self.assertIn("2 expected token markers found", output)
        for marker in markers:
            self.assertNotIn(marker, output)

        path = self.token_record(markers[0])
        code, output = self.run_scan("--provider-api-record", path, "--token-markers", expected)
        self.assertEqual(code, 1, output)
        self.assertIn("expected token marker missing", output)
        self.assertNotIn(markers[1], output)

    def test_token_markers_are_found_outside_their_stand_in_header(self):
        marker = "LVRG-TOKEN-" + "a" * 12
        expected = self.scan.secrets(marker, name="markers.txt")
        path = self.token_record(marker, extra=json.dumps(
            {"method": "GET", "path": "/" + marker, "headers": {}}) + "\n")
        self.log.write_bytes(base64.b64encode(b"!" + marker.encode()) + b"\n")
        code, output = self.run_scan("--provider-api-record", path, "--token-markers", expected)
        self.assertEqual(code, 1, output)
        self.assertIn("helper.log:1:", output)
        self.assertIn("provider-calls.jsonl:2:", output)
        self.assertNotIn(marker, output)

    def test_only_get_in_the_stand_in_record_can_prove_the_positive_control(self):
        marker = "LVRG-TOKEN-" + "a" * 12
        expected = self.scan.secrets(marker, name="markers.txt")
        path = self.scan.file("provider-calls.jsonl", json.dumps(
            {"method": "POST", "path": "/api/v1/key", "headers": {"authorization": "Bearer " + marker}}
        ) + "\n")
        code, output = self.run_scan("--provider-api-record", path, "--token-markers", expected)
        self.assertEqual(code, 1, output)
        self.assertIn("expected token marker missing", output)
        self.assertNotIn(marker, output)

    def test_the_marker_and_record_inputs_are_required_together(self):
        marker = "LVRG-TOKEN-" + "a" * 12
        expected = self.scan.secrets(marker, name="markers.txt")
        for flag, path in (("--provider-api-record", self.token_record(marker)), ("--token-markers", expected)):
            with self.subTest(flag=flag):
                code, output = self.run_scan(flag, path)
                self.assertEqual(code, 2, output)
                self.assertIn("must be used together", output)

    def test_an_invalid_marker_list_or_record_cannot_pass(self):
        marker = "LVRG-TOKEN-" + "a" * 12
        path = self.token_record(marker)
        cases = (([], "invalid or empty token marker list"),
                 (["no-marker-here"], "invalid or empty token marker list"),
                 ([marker, marker], "duplicate token marker"))
        for values, message in cases:
            with self.subTest(message=message):
                expected = self.scan.secrets(*values, name="markers.txt")
                code, output = self.run_scan("--provider-api-record", path, "--token-markers", expected)
                self.assertEqual(code, 2, output)
                self.assertIn(message, output)
                self.assertNotIn(marker, output)
        expected = self.scan.secrets(marker, name="markers.txt")
        # A duplicate JSON key must not hide an occurrence outside an
        # allowed header when the scanner parses the line.
        path.write_text('{"path": "' + marker + '", "path": "/api/v1/key", "headers": {}}\n', encoding="utf-8")
        code, output = self.run_scan("--provider-api-record", path, "--token-markers", expected)
        self.assertEqual(code, 2, output)
        self.assertIn("invalid stand-in API record", output)
        self.assertNotIn(marker, output)

    def test_token_marker_shape_is_found_without_a_stand_in_record(self):
        marker = "LVRG-TOKEN-" + "b" * 12
        self.log.write_text(marker, encoding="utf-8")
        code, output = self.run_scan()
        self.assertEqual(code, 1, output)
        self.assertIn("test token marker", output)
        self.assertNotIn(marker, output)

    def test_usage_bodies_are_found_in_the_form_the_stand_ins_play(self):
        replies = self.scan.root / "replies"
        replies.mkdir()
        body = {"data": {"label": "made-up usage for secret scanner verification"}}
        message = {"result": {"account": {"planType": "made-up subscription type"}}}
        account_id = "made-up-settings-account-id"
        settings = {"oauthAccount": {"accountUuid": account_id}, "cachedUsageUtilization": None}
        cases = [({"status": 200, "headers": {}, "body": body}, json.dumps(body)),
                 ({"status": 200, "headers": {}, "body": body}, json.dumps(body, indent=2).splitlines()[2]),
                 ({"session": {"account/read": message}}, json.dumps({**message, "id": 2}, separators=(",", ":"))),
                 ({"settings": settings}, account_id)]
        for index, (fixture, leak) in enumerate(cases):
            with self.subTest(case=index):
                fixture["meta"] = {"kind": "usage", "provider": "claude" if "settings" in fixture else "stand-in",
                                   "marker": "LVRG-REPLY-" + f"{index:012x}"}
                (replies / "usage-test.json").write_text(json.dumps(fixture), encoding="utf-8")
                self.log.write_text(leak, encoding="utf-8")
                code, output = self.run_scan("--replies", replies)
                self.assertEqual(code, 1, output)
                self.assertIn("usage-test.json", output)
                self.assertNotIn(leak, output)


if __name__ == "__main__":
    verbosity = 2 if "-v" in sys.argv[1:] else 1
    argv = [arg for arg in sys.argv if arg != "-v"]
    unittest.main(argv=argv, verbosity=verbosity)
