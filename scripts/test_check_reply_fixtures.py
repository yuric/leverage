"""Self-test of scripts/check_reply_fixtures.py (plan HD-8).

Run: python3 -I scripts/test_check_reply_fixtures.py

Every case writes reply files into a temporary folder of its own and runs the
check on that folder. All values are made up. Standard library only.
"""

import copy
import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
CHECK = os.path.join(HERE, "check_reply_fixtures.py")

CLEAN_META = {
    "provider": "claude", "tool": "claude", "tool_version": "0.0.1", "basis": "invented",
    "date": "2026-11-19", "kind": "run", "command": ["-p", "hello"], "shows": "a made-up limit",
    "expect": "limit", "expect_window": "five_hour", "expect_reset": "stated",
    "marker": "LVRG-REPLY-0123456789ab",
}


def clean_reply(marker="LVRG-REPLY-0123456789ab"):
    meta = dict(CLEAN_META, marker=marker)
    stdout = json.dumps({"type": "result", "is_error": True, "session_id": marker,
                         "uuid": "00000000-0000-0000-0000-000000000000",
                         "result": "You have reached your 5-hour limit. It resets at @RESET_AT_ISO@."})
    return {"meta": meta, "exit_status": 1, "stdout": stdout + "\n", "stderr": ""}


class CheckReplyFixtures(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory(prefix="reply-fixtures-test-")
        self.root = self.folder.name

    def tearDown(self):
        self.folder.cleanup()

    def put(self, reply, name="run-limit.json", provider="claude", raw=None):
        folder = os.path.join(self.root, provider)
        os.makedirs(folder, exist_ok=True)
        with open(os.path.join(folder, name), "w") as handle:
            handle.write(raw if raw is not None else json.dumps(reply, indent=2))

    def check(self):
        return subprocess.run([sys.executable, "-I", CHECK, self.root], capture_output=True, text=True,
                              timeout=60)

    def assert_passes(self):
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def assert_fails(self, why):
        result = self.check()
        self.assertNotEqual(result.returncode, 0, f"the check let through {why}")
        self.assertIn("run-limit.json", result.stdout + result.stderr, "the failure names the file")

    def test_a_clean_reply_passes(self):
        self.put(clean_reply())
        self.assert_passes()

    def test_two_clean_replies_with_their_own_markers_pass(self):
        self.put(clean_reply())
        self.put(clean_reply("LVRG-REPLY-ba9876543210"), name="run-other.json", provider="codex")
        other = os.path.join(self.root, "codex", "run-other.json")
        with open(other) as handle:
            reply = json.load(handle)
        reply["meta"]["provider"], reply["meta"]["tool"] = "codex", "codex"
        with open(other, "w") as handle:
            json.dump(reply, handle)
        self.assert_passes()

    def test_an_empty_folder_fails(self):
        result = self.check()
        self.assertNotEqual(result.returncode, 0, "no reply file at all must not pass")

    def test_an_email_address_fails(self):
        reply = clean_reply()
        reply["stderr"] = "Signed in as someone.real@example.com\n"
        self.put(reply)
        self.assert_fails("an email address")

    def test_an_email_address_in_meta_fails(self):
        reply = clean_reply()
        reply["meta"]["shows"] = "the reply of owner@example.org"
        self.put(reply)
        self.assert_fails("an email address in meta")

    def test_a_token_prefix_fails(self):
        for token in ("lvs_madeupmadeupmadeupmadeup", "lvh_madeupmadeupmadeupmadeup",
                      "lvo_madeupmadeupmadeupmadeup", "sk-ant-madeupmadeupmadeup",
                      "Bearer abcdefghijklmnopqrstuvwxyz012345"):
            with self.subTest(token=token):
                reply = clean_reply()
                reply["stdout"] = reply["stdout"].replace("5-hour limit", f"5-hour limit {token}")
                self.put(reply)
                self.assert_fails(f"the token {token[:6]}")

    def test_a_real_looking_id_fails(self):
        # Made-up values in the shapes the real replies carry.
        for value in ("1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d", "req_1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d",
                      "cf-ray: 1a2b3c4d5e6f7a8b-XXX"):
            with self.subTest(value=value):
                reply = clean_reply()
                reply["stderr"] = f"error {value}\n"
                self.put(reply)
                self.assert_fails(f"the id {value[:8]}")

    def test_a_placeholder_id_passes(self):
        reply = clean_reply()
        reply["stderr"] = ("request id: req_00000000000000000000000000000000, cf-ray: "
                           "0000000000000000-XXX, 00000000-0000-0000-0000-000000000000\n")
        self.put(reply)
        self.assert_passes()

    def test_a_named_field_with_a_real_value_fails(self):
        for field, value in (("session_id", "a-real-session"), ("orgName", "Some Company"),
                             ("subscriptionType", "max"), ("configDirectory", "/private/tmp/x"),
                             ("thread_id", "thread-1"), ("modelUsage", {"model-x": {"inputTokens": 3}})):
            with self.subTest(field=field):
                reply = clean_reply()
                body = json.loads(reply["stdout"])
                body[field] = value
                reply["stdout"] = json.dumps(body) + "\n"
                self.put(reply)
                self.assert_fails(f"the field {field} with a value")

    def test_a_named_field_in_a_json_line_is_found(self):
        reply = clean_reply()
        reply["stdout"] = (json.dumps({"type": "thread.started", "thread_id": "thread-real"}) + "\n"
                           + json.dumps({"type": "turn.started", "x": "LVRG-REPLY-0123456789ab"}) + "\n")
        self.put(reply)
        self.assert_fails("a thread_id in one line of JSON lines")

    def test_a_named_field_scrubbed_or_empty_passes(self):
        reply = clean_reply()
        body = json.loads(reply["stdout"])
        body.update({"configDirectory": "<scrubbed>", "loginExpiresAt": None, "modelUsage": {}})
        reply["stdout"] = json.dumps(body) + "\n"
        self.put(reply)
        self.assert_passes()

    def test_a_home_folder_path_fails(self):
        reply = clean_reply()
        reply["stderr"] = "could not read /Users/someone/.config/tool\n"
        self.put(reply)
        self.assert_fails("a path naming a user's home folder")

    def test_no_meta_fails(self):
        reply = clean_reply()
        del reply["meta"]
        self.put(reply)
        self.assert_fails("a file with no meta")

    def test_no_basis_fails(self):
        reply = clean_reply()
        del reply["meta"]["basis"]
        self.put(reply)
        self.assert_fails("a file with no basis")

    def test_an_unknown_basis_fails(self):
        reply = clean_reply()
        reply["meta"]["basis"] = "recorded"
        self.put(reply)
        self.assert_fails("a basis that is not one of the three")

    def test_made_from_observed_must_name_what_it_follows(self):
        reply = clean_reply()
        reply["meta"]["basis"] = "made_from_observed"
        self.put(reply)
        self.assert_fails("a made_from_observed file with no follows")
        reply["meta"]["follows"] = "the text the tool printed"
        self.put(reply)
        self.assert_passes()

    def test_a_missing_marker_fails(self):
        reply = clean_reply()
        del reply["meta"]["marker"]
        self.put(reply)
        self.assert_fails("a file with no marker")

    def test_a_badly_formed_marker_fails(self):
        reply = clean_reply("LVRG-REPLY-xyz")
        self.put(reply)
        self.assert_fails("a marker not of the form LVRG-REPLY-<12 hex digits>")

    def test_a_marker_missing_from_the_outputs_fails(self):
        reply = clean_reply()
        reply["stdout"] = reply["stdout"].replace("LVRG-REPLY-0123456789ab", "<scrubbed>")
        self.put(reply)
        self.assert_fails("a marker that is in meta only")

    def test_a_marker_used_twice_fails(self):
        self.put(clean_reply())
        self.put(clean_reply(), name="run-limit-again.json")
        result = self.check()
        self.assertNotEqual(result.returncode, 0, "the check let through one marker in two files")
        self.assertIn("LVRG-REPLY-0123456789ab", result.stdout + result.stderr)

    def test_a_folder_that_is_not_the_files_provider_fails(self):
        reply = clean_reply()
        self.put(reply, provider="codex")
        self.assert_fails("a Claude reply in the codex folder")

    def test_an_unknown_expectation_fails(self):
        reply = clean_reply()
        reply["meta"]["expect"] = "maybe"
        self.put(reply)
        self.assert_fails("an expectation that is not an outcome")

    def test_a_limit_must_name_its_window_and_reset(self):
        for key in ("expect_window", "expect_reset"):
            with self.subTest(key=key):
                reply = clean_reply()
                del reply["meta"][key]
                self.put(reply)
                self.assert_fails(f"a limit with no {key}")

    def test_outputs_must_be_text_and_the_exit_status_a_number(self):
        for key, value in (("stdout", None), ("stderr", 3), ("exit_status", "1")):
            with self.subTest(key=key):
                reply = copy.deepcopy(clean_reply())
                reply[key] = value
                self.put(reply)
                self.assert_fails(f"{key} of the wrong type")

    def test_a_file_that_is_not_json_fails(self):
        self.put(None, raw="{not json")
        self.assert_fails("a file that is not JSON")


if __name__ == "__main__":
    unittest.main()
