#!/usr/bin/env python3
"""Self-test for real_provider_run.sh, the developer check with a real tool.

real_provider_run.sh runs one build prompt through the runner's own driver
(ProcessToolDriver, by the Swift test RealProviderRunTests) against the
provider's tool found on PATH (plan PV-6, WP21). These cases never run a
real tool: every tool on PATH is a stand-in of mac/Tests/StandIns, or a
sleeping stand-in written here, and HOME and TMPDIR are folders of the
test's own. They prove:

- every refusal (exit 2, before anything starts): CI set, the switch unset
  or naming another provider, an unknown provider, no provider, a bad
  option;
- "skipped: not installed" (exit 3) when the tool is not on PATH;
- "skipped: not signed in" (exit 4) when the tool's status says so, with no
  prompt run;
- a pass (exit 0) for each of the four tools, through the driver's build
  arguments, with the result on standard output and in the --evidence file,
  no leverage variable and no account folder variable in the tool's
  environment, and the temporary folder removed;
- a failure (exit 1) when the tool reports an error;
- a timeout (exit 1) that ends the tool and the child it started.

The runs that reach the tool build the Swift runner lane once (several
minutes the first time) in mac/.build/real-provider.

Usage: python3 -I scripts/test_real_provider_run.py [-v]
Standard library only; exits 0 when every case behaves as expected.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
SCRIPT = HERE / "real_provider_run.sh"
STAND_INS = ROOT / "mac" / "Tests" / "StandIns"
RECORDED = ("swift", "docker", "curl")
# The provider, its stand-in program and its stand-in's version line.
TOOLS = {
    "claude": ("claude", "0.0.1 (Claude Code stand-in)"),
    "codex": ("codex", "codex-cli 0.0.1-standin"),
    "gemini": ("agy", "0.0.1-standin"),
    "grok": ("grok", "grok 0.0.1 (standin) [stable]"),
}
# Generous: the first case to reach the tool builds the runner lane.
RUN_LIMIT = 1800


def real_swift_folder():
    found = shutil.which("swift")
    return str(Path(found).resolve().parent) if found else None


class Folder:
    """A test's own HOME, TMPDIR, stand-ins and recording programs."""

    def __init__(self):
        self._folder = tempfile.TemporaryDirectory(prefix="leverage-rpr-test.")
        self.root = Path(self._folder.name).resolve()
        self.home = self.root / "home"
        self.tmp = self.root / "tmp"
        self.fakes = self.root / "fakes"
        for folder in (self.home, self.tmp, self.fakes):
            folder.mkdir()
        self.calls = self.root / "fake-calls.txt"
        for name in RECORDED:
            program = self.fakes / name
            program.write_text(f'#!/bin/sh\necho "{name} $*" >> "{self.calls}"\nexit 1\n', encoding="utf-8")
            program.chmod(0o755)
        self.stand_ins = self.root / "StandIns"
        shutil.copytree(STAND_INS, self.stand_ins, ignore=shutil.ignore_patterns("state", "__pycache__"))
        self.bin = self.stand_ins / "bin"
        self.state = self.stand_ins / "state"

    def cleanup(self):
        self._folder.cleanup()

    def sign_in(self, program):
        self.state.mkdir(exist_ok=True)
        (self.state / f"signed-in-{program}").write_text("signed in\n", encoding="utf-8")

    def tool_calls(self):
        log = self.state / "calls.jsonl"
        if not log.exists():
            return []
        return [json.loads(line) for line in log.read_text(encoding="utf-8").splitlines() if line]

    def fake_calls(self):
        return self.calls.read_text(encoding="utf-8") if self.calls.exists() else ""

    def left_behind(self):
        """Anything in the test's TMPDIR: the script's folder, or Swift's."""
        return sorted(p.name for p in self.tmp.iterdir())


class Case(unittest.TestCase):
    def setUp(self):
        self.folder = Folder()
        self.addCleanup(self.folder.cleanup)

    def run_script(self, *arguments, path, **variables):
        environment = {
            "PATH": path,
            "HOME": str(self.folder.home),
            "TMPDIR": str(self.folder.tmp),
            "LANG": "C",
            "USER": "standin",
        }
        environment.update(variables)
        result = subprocess.run(
            [str(SCRIPT), *arguments], env=environment, capture_output=True, text=True, check=False,
            timeout=RUN_LIMIT, cwd=str(self.folder.root))
        return result.returncode, result.stdout, result.stderr

    def stand_in_path(self):
        """The stand-ins first, then the recording swift: nothing real runs."""
        return f"{self.folder.bin}:{self.folder.fakes}:/usr/bin:/bin"

    def real_swift_path(self, bin_folder=None):
        swift = real_swift_folder()
        if swift is None:
            self.fail("swift is not on PATH: the cases that reach the tool need it")
        return f"{bin_folder or self.folder.bin}:{swift}:/usr/bin:/bin"

    def assertNothingStarted(self):
        self.assertEqual(self.folder.fake_calls(), "", "the refusal started something")
        self.assertEqual(self.folder.tool_calls(), [], "the refusal ran the tool")
        self.assertEqual(self.folder.left_behind(), [], "the refusal made a temporary folder")


class Refusals(Case):
    def test_ci_set_is_refused_even_with_the_switch(self):
        for ci in ("true", "1", "yes"):
            with self.subTest(ci=ci):
                code, out, err = self.run_script(
                    "claude", path=self.stand_in_path(), CI=ci, LEVERAGE_REAL_PROVIDER="claude")
                self.assertEqual(code, 2, out + err)
                self.assertIn("CI is set", err)
                self.assertNothingStarted()

    def test_the_switch_not_set_is_refused(self):
        self.folder.sign_in("claude")
        code, out, err = self.run_script("claude", path=self.stand_in_path())
        self.assertEqual(code, 2, out + err)
        self.assertIn("LEVERAGE_REAL_PROVIDER=claude", err)
        self.assertNothingStarted()

    def test_the_switch_naming_another_provider_is_refused(self):
        for switch in ("codex", "gemini", "CLAUDE", "claude ", " claude", ""):
            with self.subTest(switch=switch):
                code, out, err = self.run_script(
                    "claude", path=self.stand_in_path(), LEVERAGE_REAL_PROVIDER=switch)
                self.assertEqual(code, 2, out + err)
                self.assertNothingStarted()

    def test_an_unknown_provider_is_refused_even_when_the_switch_names_it(self):
        for provider in ("openai", "agy", "Claude", "api_key", "../claude"):
            with self.subTest(provider=provider):
                code, out, err = self.run_script(
                    provider, path=self.stand_in_path(), LEVERAGE_REAL_PROVIDER=provider)
                self.assertEqual(code, 2, out + err)
                self.assertIn("unknown provider", err)
                self.assertNothingStarted()

    def test_no_provider_is_refused(self):
        code, out, err = self.run_script(path=self.stand_in_path(), LEVERAGE_REAL_PROVIDER="claude")
        self.assertEqual(code, 2, out + err)
        self.assertIn("usage", err)
        self.assertNothingStarted()

    def test_a_bad_option_is_refused(self):
        for options in (["--timeout", "0"], ["--timeout", "abc"], ["--timeout", "601"], ["--timeout"],
                        ["--evidence"], ["--evidence", ""], ["--model"], ["--effort"], ["--bogus"],
                        ["extra"]):
            with self.subTest(options=options):
                code, out, err = self.run_script(
                    "claude", *options, path=self.stand_in_path(), LEVERAGE_REAL_PROVIDER="claude")
                self.assertEqual(code, 2, out + err)
                self.assertNothingStarted()


class NotInstalled(Case):
    def test_a_tool_not_on_path_is_skipped(self):
        evidence = self.folder.root / "evidence.txt"
        for provider, (program, _) in TOOLS.items():
            with self.subTest(provider=provider):
                # Only the recording swift and the system folders: no tool.
                path = f"{self.folder.fakes}:/usr/bin:/bin"
                self.assertIsNone(shutil.which(program, path=path), f"{program} is in a system folder")
                code, out, err = self.run_script(
                    provider, "--evidence", str(evidence), path=path, LEVERAGE_REAL_PROVIDER=provider)
                self.assertEqual(code, 3, out + err)
                self.assertIn("skipped: not installed", out)
                self.assertIn(f"provider: {provider}", out)
                self.assertEqual(evidence.read_text(encoding="utf-8"), out)
                self.assertNothingStarted()


class ThroughTheDriver(Case):
    """The runs that reach a stand-in tool through the Swift driver."""

    def prompt_calls(self):
        return [call for call in self.folder.tool_calls()
                if "-p" in call["argv"] or call["argv"][:1] == ["exec"]]

    def test_each_tool_passes_with_the_build_arguments(self):
        for provider, (program, version) in TOOLS.items():
            with self.subTest(provider=provider):
                self.folder.sign_in(program)
                evidence = self.folder.root / f"evidence-{provider}.txt"
                options = ["--timeout", "60", "--evidence", str(evidence)]
                if provider in ("claude", "gemini"):
                    options += ["--model", "model-x", "--effort", "high"]
                code, out, err = self.run_script(
                    provider, *options, path=self.real_swift_path(), LEVERAGE_REAL_PROVIDER=provider,
                    LEVERAGE_SEAT_TOKEN="lvs_made_up_never_for_a_tool", LEVERAGE_SETTINGS_DIR="/nonexistent")
                self.assertEqual(code, 0, out + err)
                self.assertIn(f"provider: {provider}", out)
                self.assertIn(f"tool: {program}", out)
                self.assertIn(f"tool_version: {version}", out)
                self.assertIn("outcome: passed", out)
                self.assertIn("exit_status: 0", out)
                self.assertIn("expected_file: yes", out)
                self.assertIn("answer_line: evidence", out)
                self.assertRegex(out, r"(?m)^seconds: \d+(\.\d+)?$")
                self.assertEqual(evidence.read_text(encoding="utf-8"), out)

                calls = [c for c in self.prompt_calls() if c["tool"] == program]
                self.assertEqual(len(calls), 1, "one attempt per invocation")
                call = calls[0]
                argv = call["argv"]
                if provider == "claude":
                    self.assertIn("acceptEdits", argv)
                    self.assertEqual(argv[argv.index("--model") + 1], "model-x")
                    self.assertEqual(argv[argv.index("--effort") + 1], "high")
                if provider == "codex":
                    self.assertIn("workspace-write", argv)
                if provider == "gemini":
                    self.assertIn("accept-edits", argv)
                    self.assertEqual(argv[argv.index("--print-timeout") + 1], "60s")
                if provider == "grok":
                    self.assertIn("acceptEdits", argv)
                # A new, empty folder under the temporary folder, gone now.
                self.assertTrue(call["cwd"].startswith(str(self.folder.tmp)), call["cwd"])
                self.assertFalse(os.path.exists(call["cwd"]))
                for name in call["env"]:
                    self.assertFalse(name.startswith("LEVERAGE_"), name)
                self.assertNotIn("CLAUDE_CONFIG_DIR", call["env"])
                self.assertNotIn("CODEX_HOME", call["env"])
                self.assertNotIn("lvs_made_up_never_for_a_tool", json.dumps(call))
                self.assertEqual(self.folder.left_behind(), [])

    def test_a_signed_out_tool_is_skipped_without_a_prompt(self):
        for provider in ("claude", "codex", "grok"):
            with self.subTest(provider=provider):
                evidence = self.folder.root / f"evidence-{provider}.txt"
                code, out, err = self.run_script(
                    provider, "--timeout", "60", "--evidence", str(evidence), path=self.real_swift_path(),
                    LEVERAGE_REAL_PROVIDER=provider)
                self.assertEqual(code, 4, out + err)
                self.assertIn("outcome: skipped: not signed in", out)
                self.assertEqual(evidence.read_text(encoding="utf-8"), out)
                self.assertEqual(self.prompt_calls(), [], "a prompt ran on a signed-out tool")
                # The stand-in's status output carries a made-up email; none
                # of the tool's output is passed on.
                self.assertNotIn("example.invalid", out + err)
                self.assertEqual(self.folder.left_behind(), [])

    def test_a_tool_that_reports_an_error_fails(self):
        # agy has no status command (its answer is the sign-in check): a
        # signed-out agy answers status ERROR, which is a failure.
        code, out, err = self.run_script(
            "gemini", "--timeout", "60", path=self.real_swift_path(), LEVERAGE_REAL_PROVIDER="gemini")
        self.assertEqual(code, 1, out + err)
        self.assertIn("outcome: failed", out)
        self.assertIn("expected_file: no", out)
        self.assertEqual(len(self.prompt_calls()), 1)
        self.assertEqual(self.folder.left_behind(), [])

    def write_sleeper(self):
        """An agy that answers its version, then sleeps with a child."""
        sleeper_bin = self.folder.root / "sleeper-bin"
        sleeper_bin.mkdir()
        pids = self.folder.root / "sleeper-pids"
        sleeper = sleeper_bin / "agy"
        sleeper.write_text(
            "#!/bin/sh\n"
            'if [ "$1" = "--version" ]; then echo "0.0.1-sleeper"; exit 0; fi\n'
            "sleep 600 &\n"
            f'echo "$$ $!" > "{pids}.tmp" && mv "{pids}.tmp" "{pids}"\n'
            "sleep 600\n",
            encoding="utf-8")
        sleeper.chmod(0o755)
        return sleeper_bin, pids

    def assertEnded(self, pids):
        self.assertTrue(pids.exists(), "the sleeper never started")
        for pid in (int(value) for value in pids.read_text(encoding="utf-8").split()):
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline and alive(pid):
                time.sleep(0.2)
            self.assertFalse(alive(pid), f"process {pid} was left behind")

    def test_a_timeout_ends_the_tool_and_its_child(self):
        sleeper_bin, pids = self.write_sleeper()
        started = time.monotonic()
        code, out, err = self.run_script(
            "gemini", "--timeout", "2", path=self.real_swift_path(sleeper_bin), LEVERAGE_REAL_PROVIDER="gemini")
        self.assertEqual(code, 1, out + err)
        self.assertIn("outcome: failed", out)
        self.assertIn("exit_status: timed out", out)
        self.assertIn("tool_version: 0.0.1-sleeper", out)
        self.assertEnded(pids)
        self.assertEqual(self.folder.left_behind(), [])
        self.assertLess(time.monotonic() - started, RUN_LIMIT)

    def test_a_stop_ends_the_tool_and_its_child_and_removes_the_folder(self):
        # SIGTERM to the script while the tool runs, long before its limit:
        # the driver never reaches its own limit, so the script must end the
        # tool's process group itself.
        sleeper_bin, pids = self.write_sleeper()
        environment = {
            "PATH": self.real_swift_path(sleeper_bin), "HOME": str(self.folder.home),
            "TMPDIR": str(self.folder.tmp), "LANG": "C", "USER": "standin", "LEVERAGE_REAL_PROVIDER": "gemini",
        }
        script = subprocess.Popen(
            [str(SCRIPT), "gemini", "--timeout", "300"], env=environment, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True, cwd=str(self.folder.root))
        try:
            deadline = time.monotonic() + RUN_LIMIT
            while not pids.exists() and script.poll() is None and time.monotonic() < deadline:
                time.sleep(0.2)
            self.assertTrue(pids.exists(), "the sleeper never started")
            script.terminate()
            out, err = script.communicate(timeout=60)
        finally:
            if script.poll() is None:
                script.kill()
                script.communicate()
        self.assertNotEqual(script.returncode, 0, out + err)
        self.assertEnded(pids)
        self.assertEqual(self.folder.left_behind(), [])


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    # A zombie still answers; ps says whether it is one.
    state = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True, check=False)
    return state.stdout.strip() != "" and not state.stdout.strip().startswith("Z")


class Text(unittest.TestCase):
    def test_the_script_is_executable_and_states_its_guards(self):
        self.assertTrue(os.access(SCRIPT, os.X_OK))
        text = SCRIPT.read_text(encoding="utf-8")
        for words in ("CI is set", "LEVERAGE_REAL_PROVIDER", "skipped: not installed",
                      "LEVERAGE_DEV_TOOL_LOGIN", "RealProviderRunTests"):
            self.assertIn(words, text)


if __name__ == "__main__":
    verbosity = 2 if "-v" in sys.argv[1:] else 1
    argv = [arg for arg in sys.argv if arg != "-v"]
    unittest.main(argv=argv, verbosity=verbosity)
