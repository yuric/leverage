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


if __name__ == "__main__":
    verbosity = 2 if "-v" in sys.argv[1:] else 1
    argv = [arg for arg in sys.argv if arg != "-v"]
    unittest.main(argv=argv, verbosity=verbosity)
