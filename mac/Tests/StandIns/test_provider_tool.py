"""Self-test of the stand-in tools (plan PV-7).

Run: python3 -I mac/Tests/StandIns/test_provider_tool.py
     python3 -I mac/Tests/StandIns/test_provider_tool.py --write-archive
       (rebuilds standin-tool.tar.gz from archive/standin-tool)

Each test copies this folder to a temporary folder and runs the copy with an
environment of its own, never the caller's, so no real tool and no real
account folder can be reached. Standard library only.
"""

import gzip
import io
import json
import os
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ARCHIVE = os.path.join(HERE, "standin-tool.tar.gz")
ARCHIVE_SOURCE = os.path.join(HERE, "archive", "standin-tool")
TOOLS = ("claude", "codex", "agy", "grok")


def build_archive():
    """The stand-in release archive, byte for byte the same on every run."""
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w", format=tarfile.USTAR_FORMAT) as tar:
        with open(ARCHIVE_SOURCE, "rb") as handle:
            data = handle.read()
        info = tarfile.TarInfo("standin-tool")
        info.size, info.mode, info.mtime = len(data), 0o755, 0
        info.uid = info.gid = 0
        info.uname = info.gname = ""
        tar.addfile(info, io.BytesIO(data))
    out = io.BytesIO()
    with gzip.GzipFile(fileobj=out, mode="wb", mtime=0, filename="") as gz:
        gz.write(raw.getvalue())
    return out.getvalue()


class StandInTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="standins-test-")
        self.root = os.path.join(self.tmp, "StandIns")
        shutil.copytree(HERE, self.root, ignore=shutil.ignore_patterns("state", "__pycache__"))
        self.home = os.path.join(self.tmp, "home")
        self.work = os.path.join(self.tmp, "work")
        os.makedirs(self.home)
        os.makedirs(self.work)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def env(self, **extra):
        env = {"PATH": os.path.join(self.root, "bin") + ":/usr/bin:/bin", "HOME": self.home,
               "TMPDIR": self.tmp, "LANG": "en_US.UTF-8"}
        env.update(extra)
        return env

    def run_tool(self, tool, *argv, env=None, cwd=None, timeout=30):
        return subprocess.run([os.path.join(self.root, "bin", tool), *argv], env=env or self.env(),
                              cwd=cwd or self.work, stdin=subprocess.DEVNULL, capture_output=True,
                              text=True, timeout=timeout)

    def state(self, *parts):
        return os.path.join(self.root, "state", *parts)

    def write_scenario(self, scenario):
        os.makedirs(self.state(), exist_ok=True)
        with open(self.state("scenario.json"), "w") as handle:
            json.dump(scenario, handle)

    def account(self, name):
        folder = os.path.join(self.tmp, "accounts", name)
        os.makedirs(folder, exist_ok=True)
        return folder


class VersionsAndStatus(StandInTestCase):
    def test_every_tool_answers_version(self):
        for tool in TOOLS:
            result = self.run_tool(tool, "--version")
            self.assertEqual(result.returncode, 0, tool)
            self.assertIn("0.0.1", result.stdout, tool)

    def test_claude_status_follows_its_account_folder(self):
        one, two = self.account("one"), self.account("two")
        signed_out = self.run_tool("claude", "auth", "status", env=self.env(CLAUDE_CONFIG_DIR=one))
        self.assertEqual(signed_out.returncode, 1)
        self.assertFalse(json.loads(signed_out.stdout)["loggedIn"])

        login = self.run_tool("claude", "auth", "login", env=self.env(CLAUDE_CONFIG_DIR=one))
        self.assertEqual(login.returncode, 0)

        status = self.run_tool("claude", "auth", "status", env=self.env(CLAUDE_CONFIG_DIR=one))
        self.assertEqual(status.returncode, 0)
        answer = json.loads(status.stdout)
        self.assertTrue(answer["loggedIn"])
        self.assertEqual(answer["email"], "standin.owner@example.invalid")
        self.assertEqual(answer["orgName"], "Stand-in Example Org")
        other = self.run_tool("claude", "auth", "status", env=self.env(CLAUDE_CONFIG_DIR=two))
        self.assertEqual(other.returncode, 1, "a sign-in is per account folder")

    def test_sign_in_takes_one_second(self):
        folder = self.account("codex")
        started = time.monotonic()
        login = self.run_tool("codex", "login", env=self.env(CODEX_HOME=folder))
        self.assertEqual(login.returncode, 0)
        self.assertGreaterEqual(time.monotonic() - started, 1.0)

    def test_codex_status_is_on_standard_error_with_its_exit_code(self):
        folder = self.account("codex")
        out = self.run_tool("codex", "login", "status", env=self.env(CODEX_HOME=folder))
        self.assertEqual((out.returncode, out.stderr.strip()), (1, "Not logged in"))
        self.run_tool("codex", "login", env=self.env(CODEX_HOME=folder))
        signed = self.run_tool("codex", "login", "status", env=self.env(CODEX_HOME=folder))
        self.assertEqual(signed.returncode, 0)
        self.assertTrue(signed.stderr.startswith("Logged in using ChatGPT"))

    def test_grok_status_is_read_from_its_text(self):
        out = self.run_tool("grok", "models")
        self.assertEqual(out.returncode, 0)
        self.assertIn("You are not authenticated.", out.stdout)
        self.assertEqual(self.run_tool("grok", "login", "--oauth").returncode, 0)
        signed = self.run_tool("grok", "models")
        self.assertNotIn("You are not authenticated.", signed.stdout)
        self.assertIn("standin.owner@example.invalid", signed.stdout)

    def test_agy_has_no_sign_in_command_and_signs_in_by_a_mark_file(self):
        self.assertNotEqual(self.run_tool("agy", "login").returncode, 0)
        prompt = ["-p", "Reply with the single word ready.", "--output-format", "json"]
        signed_out = self.run_tool("agy", *prompt)
        self.assertNotEqual(signed_out.returncode, 0)
        os.makedirs(self.state(), exist_ok=True)
        open(self.state("signed-in-agy"), "w").close()
        signed_in = self.run_tool("agy", *prompt)
        self.assertEqual(signed_in.returncode, 0)
        answer = json.loads(signed_in.stdout)
        self.assertEqual((answer["status"], answer["response"]), ("SUCCESS", "ready\n"))


class Prompts(StandInTestCase):
    def sign_in_claude(self):
        folder = self.account("claude")
        self.run_tool("claude", "auth", "login", env=self.env(CLAUDE_CONFIG_DIR=folder))
        return self.env(CLAUDE_CONFIG_DIR=folder)

    def claude_prompt(self, prompt, env):
        out = self.run_tool("claude", "-p", prompt, "--output-format", "json",
                            "--no-session-persistence", "--permission-mode", "dontAsk", env=env)
        return out, json.loads(out.stdout)

    def test_a_signed_out_prompt_is_a_failure(self):
        out, answer = self.claude_prompt("Reply with the single word ready.",
                                         self.env(CLAUDE_CONFIG_DIR=self.account("empty")))
        self.assertEqual(out.returncode, 1)
        self.assertTrue(answer["is_error"])

    def test_a_plain_prompt_answers_ready(self):
        out, answer = self.claude_prompt("Reply with the single word ready.", self.sign_in_claude())
        self.assertEqual(out.returncode, 0)
        self.assertEqual(answer["result"], "ready")
        self.assertFalse(answer["is_error"])
        self.assertIn("input_tokens", answer["usage"])

    def test_a_build_prompt_writes_the_criterion_file(self):
        env = self.sign_in_claude()
        prompt = "Work on criterion 2. End with LEVERAGE-EVIDENCE: <where> or LEVERAGE-CANNOT: <why>."
        out, answer = self.claude_prompt(prompt, env)
        self.assertEqual(out.returncode, 0)
        self.assertTrue(os.path.exists(os.path.join(self.work, "criterion-2.txt")))
        self.assertTrue(answer["result"].startswith("LEVERAGE-EVIDENCE: criterion-2.txt"))

    def test_a_builder_told_it_cannot_answers_cannot(self):
        self.write_scenario({"builder": "cannot"})
        _, answer = self.claude_prompt("criterion 1 LEVERAGE-EVIDENCE", self.sign_in_claude())
        self.assertTrue(answer["result"].startswith("LEVERAGE-CANNOT:"))

    def test_reviews_follow_the_scenario_round_by_round(self):
        self.write_scenario({"reviews": [{"fail": [2], "notes": "Criterion 2 is missing."},
                                         {"fail": []}]})
        env = self.sign_in_claude()
        prompt = "Review criterion 1 and criterion 2. Answer LEVERAGE-CRITERION <n>: PASS or FAIL."
        _, first = self.claude_prompt(prompt, env)
        self.assertEqual(first["result"].splitlines(), [
            "LEVERAGE-CRITERION 1: PASS", "LEVERAGE-CRITERION 2: FAIL",
            "LEVERAGE-NOTES: Criterion 2 is missing."])
        _, second = self.claude_prompt(prompt, env)
        self.assertEqual(second["result"].splitlines()[:2], [
            "LEVERAGE-CRITERION 1: PASS", "LEVERAGE-CRITERION 2: PASS"])
        _, third = self.claude_prompt(prompt, env)
        self.assertIn("LEVERAGE-CRITERION 2: PASS", third["result"], "the last entry repeats")

    def test_a_review_waits_for_its_gate_file(self):
        self.write_scenario({"gate_file": "gate"})
        env = self.sign_in_claude()
        review = subprocess.Popen(
            [os.path.join(self.root, "bin", "claude"), "-p", "criterion 1 LEVERAGE-CRITERION",
             "--output-format", "json"], env=env, cwd=self.work, stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, text=True)
        try:
            with self.assertRaises(subprocess.TimeoutExpired):
                review.wait(timeout=1.5)
            open(self.state("gate"), "w").close()
            out, _ = review.communicate(timeout=10)
        finally:
            review.kill()
        self.assertIn("LEVERAGE-CRITERION 1: PASS", json.loads(out)["result"])

    def test_codex_exec_shape_and_its_output_file(self):
        folder = self.account("codex")
        env = self.env(CODEX_HOME=folder)
        self.run_tool("codex", "login", env=env)
        target = os.path.join(self.tmp, "codex-work")
        os.makedirs(target)
        last = os.path.join(self.tmp, "last.txt")
        out = self.run_tool("codex", "exec", "criterion 3 LEVERAGE-EVIDENCE", "--json", "--sandbox",
                            "workspace-write", "--skip-git-repo-check", "--ephemeral", "-C", target,
                            "-o", last, env=env)
        self.assertEqual(out.returncode, 0)
        kinds = [json.loads(line)["type"] for line in out.stdout.splitlines()]
        self.assertEqual(kinds, ["thread.started", "turn.started", "item.completed", "turn.completed"])
        self.assertTrue(os.path.exists(os.path.join(target, "criterion-3.txt")), "-C is the folder")
        with open(last) as handle:
            self.assertTrue(handle.read().startswith("LEVERAGE-EVIDENCE:"))

    def test_codex_signed_out_exits_101_with_an_error_line(self):
        out = self.run_tool("codex", "exec", "hello", "--json", env=self.env(CODEX_HOME=self.account("x")))
        self.assertEqual(out.returncode, 101)
        self.assertEqual(json.loads(out.stdout.splitlines()[-1])["type"], "error")

    def test_grok_answers_plain_text_in_its_cwd(self):
        self.run_tool("grok", "login", "--oauth")
        target = os.path.join(self.tmp, "grok-work")
        os.makedirs(target)
        out = self.run_tool("grok", "-p", "criterion 4 LEVERAGE-EVIDENCE", "--cwd", target)
        self.assertEqual(out.returncode, 0)
        self.assertTrue(out.stdout.startswith("LEVERAGE-EVIDENCE: criterion-4.txt"))
        self.assertTrue(os.path.exists(os.path.join(target, "criterion-4.txt")))

    def test_every_run_is_recorded_with_its_environment(self):
        self.run_tool("claude", "--version", env=self.env(MARKER="made-up-value"))
        with open(self.state("calls.jsonl")) as handle:
            calls = [json.loads(line) for line in handle]
        self.assertEqual(calls[-1]["tool"], "claude")
        self.assertEqual(calls[-1]["argv"], ["--version"])
        self.assertEqual(calls[-1]["env"]["MARKER"], "made-up-value")


class RunnerInstallerAndScripts(StandInTestCase):
    def test_stand_in_runner_records_and_stops_with_its_child(self):
        runner = subprocess.Popen([os.path.join(self.root, "stand_in_runner.sh"), "--flag"],
                                  env=self.env(LEVERAGE_SEAT_TOKEN="lvs_madeupmadeupmadeup"),
                                  cwd=self.work, stdin=subprocess.DEVNULL)
        try:
            path = self.state("runner", f"{runner.pid}.json")
            deadline = time.monotonic() + 10
            while not os.path.exists(path) and time.monotonic() < deadline:
                time.sleep(0.05)
            with open(path) as handle:
                record = json.load(handle)
            self.assertEqual(record["argv"], ["--flag"])
            self.assertEqual(record["env"]["LEVERAGE_SEAT_TOKEN"], "lvs_madeupmadeupmadeup")
            runner.send_signal(signal.SIGTERM)
            self.assertEqual(runner.wait(timeout=10), 0)
            self.assertFalse(process_alive(record["child_pid"]))
        finally:
            runner.kill()

    def test_installer_installs_a_launcher_into_home(self):
        out = subprocess.run([os.path.join(self.root, "installer.sh"), "codex"], env=self.env(),
                             stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=30)
        self.assertEqual(out.returncode, 0, out.stderr)
        installed = os.path.join(self.home, ".local", "bin", "codex")
        version = subprocess.run([installed, "--version"], env=self.env(), capture_output=True,
                                 text=True, timeout=30)
        self.assertEqual(version.stdout.strip(), "codex-cli 0.0.1-standin")

    def test_archive_holds_the_stand_in_tool(self):
        with open(ARCHIVE, "rb") as handle:
            self.assertEqual(handle.read(), build_archive(), "rebuild with --write-archive")
        with tarfile.open(ARCHIVE) as tar:
            self.assertEqual(tar.getnames(), ["standin-tool"])
            self.assertEqual(tar.getmember("standin-tool").mode, 0o755)

    def test_big_output_writes_one_mebibyte_to_each_output(self):
        out = subprocess.run([os.path.join(self.root, "big_output.sh")], env=self.env(),
                             stdin=subprocess.DEVNULL, capture_output=True, timeout=30)
        self.assertEqual(out.returncode, 0)
        self.assertEqual((len(out.stdout), len(out.stderr)), (1048576, 1048576))
        self.assertEqual(set(out.stdout), {ord("a")})

    def test_sleeping_grandchild_writes_its_child_pid(self):
        pid_file = os.path.join(self.tmp, "grandchild.pid")
        script = subprocess.Popen([os.path.join(self.root, "sleeping_grandchild.sh"), pid_file],
                                  env=self.env(), stdin=subprocess.DEVNULL, start_new_session=True)
        try:
            deadline = time.monotonic() + 10
            while not os.path.exists(pid_file) and time.monotonic() < deadline:
                time.sleep(0.05)
            with open(pid_file) as handle:
                grandchild = int(handle.read())
            os.kill(grandchild, 0)  # raises if it is not running
        finally:
            os.killpg(script.pid, signal.SIGKILL)
            script.wait()


def process_alive(pid):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return False
        time.sleep(0.05)
    return True


if __name__ == "__main__":
    if sys.argv[1:] == ["--write-archive"]:
        with open(ARCHIVE, "wb") as handle:
            handle.write(build_archive())
        sys.exit(0)
    unittest.main()
