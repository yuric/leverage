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


def usage_reply(provider="codex", basis="made_from_schema"):
    marker = CLEAN_META["marker"]
    meta = {key: value for key, value in CLEAN_META.items() if key not in ("expect_window", "expect_reset")}
    meta.update(provider=provider, tool=provider, basis=basis, kind="usage",
                expect={"state": "ok", "figures": [], "resets": None})
    if provider == "codex":
        return {"meta": meta, "session": {
            "initialize": {"result": {"codexHome": marker}, "id": marker},
            "account/read": {"result": {"account": {"type": "chatgpt", "email": None,
                                                   "planType": "<scrubbed>", "workspaceName": ""}}},
            "account/rateLimits/read": {"result": {"rateLimits": {"primary": {"usedPercent": 42}}}},
            "account/usage/read": {"result": {"summary": {"lifetimeTokens": 123}}},
        }}
    if provider == "claude":
        return {"meta": meta, "exit_status": 0, "stdout": json.dumps({"session_id": marker}), "stderr": ""}
    return {"meta": meta, "status": 200, "headers": {}, "body": {}, "marker": marker}


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

    # Review: what the raw text hides behind JSON escapes, and the fields
    # a real reply carries a plan or an organisation in.

    def test_an_escaped_email_or_home_path_fails(self):
        # The raw file holds the value only in its JSON escapes: \\/ for /
        # and \\u0040 for @, which a reader of the decoded reply sees whole.
        for escaped, why in (("config at \\/Users\\/someone\\/.claude", "an escaped home path"),
                             ("written by someone\\u0040example.com", "an escaped email")):
            with self.subTest(why=why):
                reply = clean_reply()
                reply["stderr"] = "PLACEHOLDER\n"
                raw = json.dumps(reply, indent=2).replace("PLACEHOLDER", escaped)
                self.assertNotIn("/Users/", raw)
                self.assertNotIn("@example.com", raw)
                self.put(reply, raw=raw)
                self.assert_fails(why)

    def test_a_plan_or_organisation_field_with_a_value_fails(self):
        for field, value in (("plan", "max"), ("plan_type", "pro"), ("planType", "team"),
                             ("rate_limit_tier", "default_claude_max_20x"), ("subscription", "pro"),
                             ("organization_name", "Some Company"), ("orgUuid", "org-made-up"),
                             ("accountUuid", "acct-made-up"), ("account_email", "someone"),
                             ("billingTier", "made-up")):
            with self.subTest(field=field):
                reply = clean_reply()
                body = json.loads(reply["stdout"])
                body[field] = value
                reply["stdout"] = json.dumps(body) + "\n"
                self.put(reply)
                self.assert_fails(f"the field {field} with a value")

    def test_a_home_folder_named_with_a_tilde_fails(self):
        reply = clean_reply()
        reply["stderr"] = "could not read ~someone/.config/tool\n"
        self.put(reply)
        self.assert_fails("a home folder named as ~user")

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

    def put_usage(self, reply):
        self.put(reply, "usage-example.json", reply["meta"]["provider"])

    def assert_usage_fails(self, reply, *, hidden=None):
        self.put_usage(reply)
        result = self.check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("usage-example.json", result.stdout)
        self.assertNotIn("Traceback", result.stderr)
        if hidden:
            self.assertNotIn(hidden, result.stdout + result.stderr)

    def test_only_made_usage_replies_are_accepted(self):
        for basis in ("made_from_schema", "made_from_recorded", "made_from_documentation", "made_from_prd"):
            with self.subTest(basis=basis):
                self.put_usage(usage_reply(basis=basis))
                self.assert_passes()
        for basis in ("recorded_scrubbed", "recorded_no_login", "invented", "made_from_observed"):
            with self.subTest(basis=basis):
                self.assert_usage_fails(usage_reply(basis=basis))

    def test_usage_name_and_kind_agree(self):
        for reply, name in ((usage_reply(), "run-example.json"), (clean_reply(), "usage-example.json")):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as folder:
                self.root = folder
                self.put(reply, name, reply["meta"]["provider"])
                result = self.check()
                self.assertEqual(result.returncode, 1)
                self.assertIn(name, result.stdout)

    def test_expected_reading_needs_a_known_state_figures_and_resets(self):
        for invalid in ("ok", {}, {"state": "ok", "figures": []},
                        {"state": "maybe", "figures": [], "resets": []},
                        {"state": "ok", "figures": "none", "resets": []},
                        {"state": "ok", "figures": [], "resets": 2}):
            with self.subTest(expect=invalid):
                reply = usage_reply()
                reply["meta"]["expect"] = invalid
                self.assert_usage_fails(reply)

    def test_each_payload_form_can_carry_a_marker_and_its_absence_is_rejected(self):
        settings = usage_reply("claude")
        settings = {"meta": settings["meta"], "settings": {"cachedUsageUtilization": {}},
                    "marker": settings["meta"]["marker"]}
        for reply in (usage_reply(), usage_reply("claude"), settings, usage_reply("grok_api")):
            with self.subTest(keys=sorted(reply)), tempfile.TemporaryDirectory() as folder:
                self.root = folder
                self.put_usage(reply)
                self.assert_passes()
                payload = {key: value for key, value in reply.items() if key != "meta"}
                clean = json.loads(json.dumps(payload).replace(reply["meta"]["marker"], "<scrubbed>"))
                self.assert_usage_fails(dict(clean, meta=reply["meta"]))

    def test_usage_refuses_incomplete_or_mixed_payloads(self):
        for provider, overrides in (("grok_api", {"headers": []}), ("openrouter", {"status": True}),
                                    ("claude_api", {"session": {}}), ("codex", {"session": []}),
                                    ("codex", {"session": {"unknown/read": {"result": {}}}}),
                                    ("claude", {"stderr": None}), ("claude", {"settings": []})):
            with self.subTest(provider=provider, keys=sorted(overrides)), tempfile.TemporaryDirectory() as folder:
                self.root = folder
                reply = usage_reply(provider)
                reply.update(overrides, marker=reply["meta"]["marker"])
                self.assert_usage_fails(reply)

    def test_only_the_providers_named_response_headers_are_allowed(self):
        anthropic = "Anthropic-RateLimit-Requests-Remaining"
        openai = "X-RateLimit-Remaining-Requests"
        for provider in ("claude_api", "openai_api", "gemini_api", "grok_api", "openrouter"):
            with self.subTest(provider=provider), tempfile.TemporaryDirectory() as folder:
                self.root = folder
                reply = usage_reply(provider, "made_from_documentation")
                allowed = {"claude_api": anthropic, "openai_api": openai}.get(provider)
                if allowed:
                    reply["headers"][allowed] = "15"
                self.put_usage(reply)
                self.assert_passes()
                for header in {anthropic, openai, "Authorization", "Set-Cookie"} - {allowed}:
                    with self.subTest(header=header):
                        reply["headers"] = {header: "made-up-sensitive-header-value"}
                        self.assert_usage_fails(reply, hidden="made-up-sensitive-header-value")

    def test_usage_scans_structure_and_named_fields_even_at_an_encoded_layer(self):
        bad = "made-up-private-value"
        for field in ("id", "itemID", "creditId", "sessionID", "requestIds", "thread_id", "apiKey",
                      "workspaceName", "orgName", "email", "account", "planType", "path", "configDir",
                      "codexHome", "loginExpiresAt"):
            with self.subTest(field=field):
                reply = usage_reply()
                message = reply["session"]["account/usage/read"]["result"]
                message["details"] = [{"payload": json.dumps({field: bad})}]
                self.assert_usage_fails(reply, hidden=bad)
                message["details"] = [{"payload": json.dumps({field: "<scrubbed>"})}]
                self.put_usage(reply)
                self.assert_passes()

    def test_account_container_exemption_is_limited_to_the_account_read_reply(self):
        reply = usage_reply()
        reply["session"]["account/read"]["result"]["account"]["workspaceName"] = "made-up-private-workspace"
        self.assert_usage_fails(reply, hidden="made-up-private-workspace")
        reply = usage_reply()
        reply["session"]["account/usage/read"]["result"]["account"] = {"name": "made-up-private-account"}
        self.assert_usage_fails(reply, hidden="made-up-private-account")

    def test_usage_token_prefixes_and_escaped_paths_are_rejected_in_all_outputs(self):
        for secret in ("sk-" + "z" * 16, "xai-" + "q" * 16, "AIza" + "w" * 16,
                       "LVRG-TOKEN-0123456789ab", "/Users/made-up/private", "person@example.invalid"):
            with self.subTest(prefix=secret[:4]):
                reply = usage_reply("claude")
                encoded = json.dumps({"message": secret}).replace("/", r"\/").replace("@", r"\u0040")
                reply["stdout"] = json.dumps({"session_id": reply["meta"]["marker"], "result": encoded})
                self.assert_usage_fails(reply, hidden=secret)

    def test_schema_allows_only_documented_flags_with_boolean_values(self):
        for provider, flag in (("openrouter", "is_free_tier"), ("grok_api", "api_key_blocked"),
                               ("grok_api", "api_key_disabled"), ("grok_api", "team_blocked")):
            with self.subTest(flag=flag), tempfile.TemporaryDirectory() as folder:
                self.root = folder
                reply = usage_reply(provider)
                fields = reply["body"].setdefault("data", {}) if provider == "openrouter" else reply["body"]
                fields[flag] = False
                self.put_usage(reply)
                self.assert_passes()
                fields[flag] = "made-up-private-value"
                self.assert_usage_fails(reply, hidden="made-up-private-value")

    def test_duplicate_encoded_keys_cannot_hide_an_earlier_account_detail(self):
        reply = usage_reply("claude")
        reply["stderr"] = '{"id":"made-up-private-id","id":"<scrubbed>"}'
        self.assert_usage_fails(reply, hidden="made-up-private-id")

    def test_metadata_errors_do_not_echo_values_or_unknown_field_names(self):
        for field in ("basis", "kind", "expect"):
            with self.subTest(field=field):
                reply = clean_reply()
                reply["meta"][field] = "made-up-private-value"
                self.put(reply)
                result = self.check()
                self.assertEqual(result.returncode, 1)
                self.assertNotIn("made-up-private-value", result.stdout + result.stderr)
        reply = usage_reply()
        reply["session"]["account/read"]["result"]["account"]["private@example.invalid"] = True
        self.assert_usage_fails(reply, hidden="private@example.invalid")

    def test_private_identifiers_as_json_keys_are_rejected_even_with_null_values(self):
        reply = usage_reply()
        fields = reply["session"]["account/usage/read"]["result"]
        fields.update(account_id="<scrubbed>", org_name=None, workspace_name=None, user_id="<scrubbed>")
        self.put_usage(reply)
        self.assert_passes()
        for key in ("org_made_up_enumerated", "acct_made_up", "workspace_made_up",
                    "user_made_up", "session-made-up", "req_made_up", "thread-made-up"):
            with self.subTest(prefix=key.split("_")[0]):
                fields["details"] = json.dumps([{key: None}])
                self.assert_usage_fails(reply, hidden=key)

    def test_objects_keyed_by_model_organisation_or_limit_accept_only_placeholder_keys(self):
        reply = usage_reply()
        result = reply["session"]["account/rateLimits/read"]["result"]
        for field in ("rateLimitsByLimitId", "usageByModel", "modelUsage", "per_model", "organizations",
                      "workspaces"):
            with self.subTest(field=field):
                result[field] = {"<scrubbed>": {"primary": {"usedPercent": 4}}}
                self.put_usage(reply)
                self.assert_passes()
                result[field]["private-label"] = {"primary": None}
                self.assert_usage_fails(reply, hidden="private-label")
                del result[field]
        # The reference gives "codex" as an example at exactly this position.
        result["rateLimitsByLimitId"] = {"codex": {"primary": None}}
        self.put_usage(reply)
        self.assert_passes()
        result["rateLimitsByLimitId"]["codex"]["userId"] = "made-up-private"
        self.assert_usage_fails(reply, hidden="made-up-private")

    def test_rpc_ids_and_server_messages_are_checked_like_other_payload_fields(self):
        reply = usage_reply()
        reply["server_messages"] = [{"id": "<scrubbed>", "method": "example/read", "params": {}}]
        self.put_usage(reply)
        self.assert_passes()
        for mutate in (
            lambda item: item["session"]["initialize"].update(id=23),
            lambda item: item["server_messages"][0]["params"].update(configPath="private-directory"),
            lambda item: item.update(server_messages="wrong type"),
            lambda item: item["session"].update(initialize={"id": "<scrubbed>"}),
            lambda item: item["session"]["initialize"].update(error={}),
            lambda item: item.update(marker="does not match meta"),
        ):
            broken = copy.deepcopy(reply)
            mutate(broken)
            self.assert_usage_fails(broken)

    def test_an_allowed_header_may_not_carry_an_extra_line_or_a_structured_value(self):
        for value in ("1\r\nSet-Cookie: made-up", {"id": "<scrubbed>"}, 1):
            with self.subTest(value=value):
                reply = usage_reply("openai_api")
                reply["headers"] = {"X-RateLimit-Remaining-Requests": value}
                self.assert_usage_fails(reply)

    def test_expectation_records_use_figure_and_reset_wire_fields(self):
        reply = usage_reply()
        expect = reply["meta"]["expect"]
        figure = {"label": "5-hour limit", "kind": "limit", "window": "five_hour",
                  "percent_used": 42, "reset_at": None, "value": None}
        reset = {"count": 1, "kind": "full", "expires_at": None}
        expect.update(figures=[figure], resets=[reset])
        self.put_usage(reply)
        self.assert_passes()
        for records, field, replacement in (("figures", "label", None), ("figures", "kind", "unknown"),
                                            ("resets", "count", True), ("resets", "kind", "unknown")):
            with self.subTest(records=records, field=field):
                broken = copy.deepcopy(reply)
                broken["meta"]["expect"][records][0][field] = replacement
                self.assert_usage_fails(broken)
        del reset["expires_at"]
        self.assert_usage_fails(reply)

    def test_a_symlink_is_not_a_reply_file_or_provider_folder(self):
        with tempfile.TemporaryDirectory() as other:
            reply_path = os.path.join(other, "run-reply.json")
            with open(reply_path, "w") as handle:
                json.dump(clean_reply(), handle)
            claude_path = os.path.join(self.root, "claude")
            os.mkdir(claude_path)
            linked_file = os.path.join(claude_path, "run-limit.json")
            os.symlink(reply_path, linked_file)
            self.assert_fails("a linked reply file")
            os.unlink(linked_file)
            os.rmdir(claude_path)
            os.symlink(other, claude_path)
            result = self.check()
            self.assertEqual(result.returncode, 1)
            self.assertIn("claude", result.stdout)

    def test_private_filenames_and_duplicate_header_spellings_fail_without_echoing_them(self):
        reply = usage_reply("openai_api")
        reply["headers"] = {"x-ratelimit-remaining-requests": "2", "X-RateLimit-Remaining-Requests": "1"}
        self.assert_usage_fails(reply)
        self.put(None, "usage-madeup@example.invalid.json", "claude", raw="[]")
        result = self.check()
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("madeup@example.invalid", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
