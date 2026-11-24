"""Exercise RD-7 with temporary stand-ins and an empty test home."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
CAPTURE = ROOT / "scripts" / "capture_reader_reply.py"
CLAUDE_ARGS = [
    "-p", "/usage", "--output-format", "json", "--no-session-persistence",
    "--permission-mode", "dontAsk", "--strict-mcp-config", "--setting-sources", "user",
    "--tools", "",
]
GEMINI_ARGS = ["-p", "/usage", "--mode", "plan", "--output-format", "json", "--print-timeout", "15s"]

STAND_IN = r"""
import json
import os
from pathlib import Path
import sys

here = Path(__file__).parent
scenario = json.loads((here / "scenario.json").read_text())
with (here / "calls.jsonl").open("a") as log:
    print(json.dumps({"argv": sys.argv[1:], "env": dict(os.environ),
                      "cwd": os.getcwd(), "files": os.listdir()}), file=log)
if sys.argv[1:] != ["app-server"]:
    if sys.stdin.read():
        raise SystemExit(2)
    print(json.dumps(scenario))
elif scenario.get("content_length"):
    sys.stdin.readline()
    sys.stdout.write('Content-Length: 2\n\n{}')
    sys.stdout.flush()
else:
    for line in sys.stdin:
        request = json.loads(line)
        with (here / "methods.jsonl").open("a") as log:
            print(json.dumps(request), file=log)
        method = request["method"]
        if method == "initialize":
            print(json.dumps({"id": 1, "method": "account/requestFromServer"}), flush=True)
        if "id" in request:
            print(json.dumps({"id": request["id"], "result": scenario[method]}), flush=True)
"""


class CaptureReaderReply(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="capture-reader-test-")
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.tools = self.root / "selected"
        self.tools.mkdir()
        self.decoy = self.root / "on-path"
        self.decoy.mkdir()
        self.out = self.root / "captures"
        self.env = {
            "PATH": str(self.decoy), "HOME": str(self.home), "TMPDIR": str(self.root),
            "USER": "made-up-user", "LANG": "C", "LEVERAGE_REAL_PROVIDER": "claude",
            "LEVERAGE_TOOL_DIR": str(self.decoy), "LEVERAGE_TEST_PRIVATE": "not-for-child",
            "CODEX_HOME": str(self.home / "untouched"),
            "CLAUDE_CONFIG_DIR": str(self.home / "untouched"),
        }
        self.scenario = {
            "type": "result", "result": {
                "accountId": "made-up-account-67", "email": "sample.owner@example.invalid",
                "planType": "made-up-plan-35", "orgName": "Made-up group",
                "workspaceName": "Made-up workspace", "loginExpiresAt": "2029-02-03T00:00:00Z",
                "cachePath": "/home/example/.made-up-tool", "usedPercent": 87,
                "resetsAt": 1888012345,
                "perModel": {
                    "org_made_up_organization": {"usedPercent": 72},
                    "sample.owner@example.invalid": {"usedPercent": 42},
                    "550e8400-e29b-41d4-a716-446655440000": {"usedPercent": 61},
                },
            },
        }
        for folder in (self.tools, self.decoy):
            self.make_tool(folder, "claude", self.scenario)

    def make_tool(self, folder, name, scenario):
        tool = folder / name
        tool.write_text(f"#!{sys.executable}\n{STAND_IN}", encoding="utf-8")
        tool.chmod(0o700)
        (folder / "scenario.json").write_text(json.dumps(scenario), encoding="utf-8")
        return tool

    def run_capture(self, provider="claude", *, tool=None, out=None, **env):
        tool = tool if tool is not None else self.tools / provider
        return subprocess.run(
            [sys.executable, "-I", CAPTURE, provider, "--tool", str(tool),
             "--out", str(out if out is not None else self.out)],
            cwd=self.root, env=self.env | env, stdin=subprocess.DEVNULL,
            capture_output=True, text=True, timeout=30,
        )

    def read_capture(self):
        copies = list(self.out.iterdir())
        self.assertEqual(len(copies), 1)
        self.assertEqual(copies[0].stat().st_mode & 0o777, 0o600)
        return json.loads(copies[0].read_text())

    def calls(self):
        return [json.loads(line) for line in (self.tools / "calls.jsonl").read_text().splitlines()]

    def assert_refuses(self, out, diagnostic):
        self.assertNotEqual(out.returncode, 0)
        self.assertIn(diagnostic, out.stderr)
        self.assertFalse((self.tools / "calls.jsonl").exists())
        self.assertFalse((self.decoy / "calls.jsonl").exists())
        self.assertFalse(self.out.exists())

    def test_ci_is_refused_even_when_empty(self):
        self.assert_refuses(self.run_capture(CI=""), "CI")

    def test_the_provider_switch_has_to_match(self):
        self.assert_refuses(self.run_capture(LEVERAGE_REAL_PROVIDER="codex"), "LEVERAGE_REAL_PROVIDER")

    def test_an_unsupported_provider_is_refused(self):
        self.assert_refuses(
            self.run_capture("grok", LEVERAGE_REAL_PROVIDER="grok"), "invalid choice")

    def test_a_tool_path_must_be_absolute(self):
        self.assert_refuses(self.run_capture(tool="selected/claude"), "absolute")

    def test_an_output_inside_the_repository_is_refused(self):
        self.assert_refuses(self.run_capture(out=ROOT / "captures-test"), "git work tree")
        fake_worktree = self.root / "a-worktree"
        fake_worktree.mkdir()
        (fake_worktree / ".git").write_text("gitdir: /nowhere")
        indirect = self.root / "through-a-link"
        indirect.symlink_to(fake_worktree, target_is_directory=True)
        self.assert_refuses(self.run_capture(out=indirect / "captures"), "git work tree")

    def test_it_runs_only_the_named_tool_in_an_empty_folder_and_scrubs_before_writing(self):
        run = self.run_capture()
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn("framing: json", run.stdout)
        self.assertIn("model turn: no", run.stdout)
        self.assertIn("usedPercent: integer", run.stdout)
        self.assertGreaterEqual(run.stdout.count("<key>"), 3)
        self.assertFalse((self.decoy / "calls.jsonl").exists())
        [call] = self.calls()
        self.assertEqual(call["argv"], CLAUDE_ARGS)
        self.assertEqual(call["files"], [])
        self.assertEqual(Path(call["cwd"]).resolve().parent, self.out.resolve())
        self.assertEqual(call["env"]["HOME"], str(self.home))
        self.assertEqual(call["env"]["USER"], "made-up-user")
        self.assertEqual(call["env"]["PATH"].split(os.pathsep)[0], str(self.tools))
        for name in ("CLAUDE_CONFIG_DIR", "CODEX_HOME", "LEVERAGE_TOOL_DIR", "LEVERAGE_TEST_PRIVATE"):
            self.assertNotIn(name, call["env"])
        self.assertEqual(list(self.home.iterdir()), [])
        saved = self.read_capture()
        self.assertEqual(saved["meta"]["basis"], "recorded_scrubbed")
        self.assertIn("reply.result.accountId", saved["meta"]["replaced"])
        self.assertIn("reply.result.usedPercent", saved["meta"]["replaced"])
        self.assertIs(type(saved["reply"]["result"]["usedPercent"]), int)
        for raw in ("made-up-account-67", "sample.owner@example.invalid", "made-up-plan-35",
                    "Made-up group", "Made-up workspace", "2029-02-03", "/home/example/",
                    "1888012345", "org_made_up_organization", "550e8400-e29b-41d4-a716-446655440000"):
            self.assertNotIn(raw, json.dumps(saved))
            self.assertNotIn(raw, run.stdout + run.stderr)

    def test_claude_turns_model_names_or_tokens_mark_a_model_turn(self):
        for evidence in ({"num_turns": 1}, {"model": "made-up-model"}, {"usage": {"input_tokens": 3}}):
            with self.subTest(evidence=evidence):
                self.make_tool(self.tools, "claude", evidence)
                run = self.run_capture()
                self.assertEqual(run.returncode, 0, run.stderr)
                self.assertIn("model turn: yes", run.stdout)
                self.assertEqual(self.read_capture()["meta"]["cost"], "model_turn")
                for copy in self.out.iterdir():
                    copy.unlink()

    def test_gemini_uses_the_fixed_prompt_and_reports_token_evidence(self):
        tool = self.make_tool(self.tools, "agy", {"usage": {"total_tokens": 9}})
        run = self.run_capture("gemini", tool=tool, LEVERAGE_REAL_PROVIDER="gemini")
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(self.calls()[0]["argv"], GEMINI_ARGS)
        self.assertIn("prompt tokens: yes", run.stdout)
        self.assertEqual(self.read_capture()["meta"]["cost"], "model_turn")

    def test_codex_sends_only_the_fixed_usage_session(self):
        tool = self.make_tool(self.tools, "codex", {
            "initialize": {"codexHome": "/home/example/.codex", "userAgent": "made-up-client"},
            "account/rateLimits/read": {"rateLimits": {"primary": {"usedPercent": 61}}},
            "account/usage/read": {"summary": {"lifetimeTokens": 1272}},
        })
        run = self.run_capture("codex", tool=tool, LEVERAGE_REAL_PROVIDER="codex")
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn("framing: jsonl", run.stdout)
        receive = self.tools / "methods.jsonl"
        messages = [json.loads(line) for line in receive.read_text().splitlines()]
        self.assertEqual([message["method"] for message in messages],
                         ["initialize", "initialized", "account/rateLimits/read", "account/usage/read"])
        self.assertEqual(messages[0]["params"]["clientInfo"]["name"], "leverage")
        self.assertNotIn("id", messages[1])
        self.assertTrue(all("params" not in message for message in messages[1:]))
        saved = self.read_capture()
        self.assertEqual(set(saved["reply"]), {messages[i]["method"] for i in (0, 2, 3)})
        self.assertNotIn("/home/example/", json.dumps(saved))

    def test_non_jsonl_codex_framing_is_reported_without_raw_bytes(self):
        tool = self.make_tool(self.tools, "codex", {"content_length": True})
        run = self.run_capture("codex", tool=tool, LEVERAGE_REAL_PROVIDER="codex")
        self.assertNotEqual(run.returncode, 0)
        self.assertIn("framing: content-length", run.stdout)
        self.assertNotIn("Content-Length: 2", run.stdout + run.stderr)
        self.assertEqual(list(self.out.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
