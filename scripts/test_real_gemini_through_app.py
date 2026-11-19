#!/usr/bin/env python3
"""Self-test for real_gemini_through_app.sh's refusals.

real_gemini_through_app.sh is a developer check with the real Antigravity
(the managing agent's override 8). It must refuse to run, with exit code 2
and before it starts anything, when CI is set or when LEVERAGE_REAL_PROVIDER
is not "gemini". These cases run it with docker, swift, curl and python3
replaced by stand-ins that record any call, and prove that each refusal
says why and calls none of them. The run with the switch set is never made
here: only the managing agent runs it.

Usage: python3 scripts/test_real_gemini_through_app.py [-v]
Standard library only; exits 0 when every case behaves as expected.
"""

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "real_gemini_through_app.sh"
RECORDED = ("docker", "swift", "curl", "python3", "mktemp")


class Refusals(unittest.TestCase):
    def setUp(self):
        self._folder = tempfile.TemporaryDirectory()
        self.addCleanup(self._folder.cleanup)
        root = Path(self._folder.name)
        self.bin = root / "bin"
        self.bin.mkdir()
        self.calls = root / "calls.txt"
        for name in RECORDED:
            tool = self.bin / name
            tool.write_text(f'#!/bin/sh\necho "{name} $*" >> "{self.calls}"\nexit 1\n', encoding="utf-8")
            tool.chmod(0o755)

    def run_script(self, **variables):
        environment = {
            "PATH": f"{self.bin}:/usr/bin:/bin",
            "HOME": self._folder.name,
            "LANG": "C",
        }
        environment.update(variables)
        result = subprocess.run(
            [str(SCRIPT)], env=environment, capture_output=True, text=True, check=False, timeout=60)
        return result.returncode, result.stdout + result.stderr

    def assertNothingCalled(self):
        called = self.calls.read_text(encoding="utf-8") if self.calls.exists() else ""
        self.assertEqual(called, "", "the refusal started something")

    def test_ci_set_is_refused_even_with_the_switch(self):
        code, output = self.run_script(CI="true", LEVERAGE_REAL_PROVIDER="gemini")
        self.assertEqual(code, 2, output)
        self.assertIn("CI is set", output)
        self.assertNothingCalled()

    def test_ci_set_without_the_switch_is_refused(self):
        code, output = self.run_script(CI="1")
        self.assertEqual(code, 2, output)
        self.assertNothingCalled()

    def test_the_switch_not_set_is_refused(self):
        code, output = self.run_script()
        self.assertEqual(code, 2, output)
        self.assertIn("LEVERAGE_REAL_PROVIDER=gemini", output)
        self.assertNothingCalled()

    def test_the_switch_naming_another_provider_is_refused(self):
        for provider in ("claude", "codex", "grok", "GEMINI", "gemini ", ""):
            with self.subTest(provider=provider):
                code, output = self.run_script(LEVERAGE_REAL_PROVIDER=provider)
                self.assertEqual(code, 2, output)
                self.assertNothingCalled()

    def test_the_script_is_executable_and_documents_both_refusals(self):
        self.assertTrue(os.access(SCRIPT, os.X_OK))
        text = SCRIPT.read_text(encoding="utf-8")
        self.assertIn("CI is set", text)
        self.assertIn("LEVERAGE_REAL_PROVIDER", text)


if __name__ == "__main__":
    verbosity = 2 if "-v" in sys.argv[1:] else 1
    argv = [arg for arg in sys.argv if arg != "-v"]
    unittest.main(argv=argv, verbosity=verbosity)
