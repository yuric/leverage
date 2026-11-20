#!/usr/bin/env python3
"""Self-test for check_evals.py, CI's check of the eval suite.

check_evals.py never calls a provider (milestone 4 plan RV-7). It checks
the cases' shape and counts, that every supported model of bar.json has a
result recorded against today's instruction and case set, that each
result's "met the bar" is what scoring it again gives, that the registry
list orchestrator_tested_providers equals the providers whose result met
the bar, that runs.json is within the ceilings of RV-6, and that no case or
result holds anything shaped like an email address or a token. A recorded
miss does not fail it: it is printed.

Each case copies the repository's suite, shipped rules and registry into a
temporary folder, records a result for each supported model there with
eval_score.py from made-up verdicts, and runs the check on that folder:
untouched it passes; each doctored copy must fail and say why. One case
runs the check on the repository itself, where only the results may be
missing (until the managing agent's eval run), never a case's shape.

Usage: python3 -I scripts/test_check_evals.py [-v]
Standard library only; exits 0 when every case behaves as expected.
"""

import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
SCRIPT = HERE / "check_evals.py"
SCORER = HERE / "eval_score.py"
SUITE = Path("evals") / "specific-details"
CANARY = "quobbledrine"


def python(script, *arguments):
    result = subprocess.run([sys.executable, "-I", str(script), *map(str, arguments)],
                            capture_output=True, text=True, check=False)
    return result.returncode, result.stdout + result.stderr


class Root:
    """A copy of what check_evals.py reads, with a result per supported
    model recorded from made-up verdicts."""

    def __init__(self, folder):
        self.root = Path(folder)
        self.suite = self.root / SUITE
        (self.suite / "cases").mkdir(parents=True)
        for path in sorted((ROOT / SUITE / "cases").glob("*.json")):
            shutil.copy(path, self.suite / "cases" / path.name)
        shutil.copy(ROOT / SUITE / "bar.json", self.suite / "bar.json")
        (self.root / "api" / "contract").mkdir(parents=True)
        for name in ("shipped_rules.json", "registry.json"):
            shutil.copy(ROOT / "api" / "contract" / name, self.root / "api" / "contract" / name)
        self.write_runs([self.run_entry(provider, 24) for provider in self.supported()])
        for provider in self.supported():
            self.record(provider)
        self.set_tested(self.supported())

    # --- the pieces ---------------------------------------------------------

    def supported(self):
        return json.loads((self.suite / "bar.json").read_text(encoding="utf-8"))["supported_providers"]

    def cases(self):
        return sorted((self.suite / "cases").glob("*.json"))

    def case(self, path):
        return json.loads(path.read_text(encoding="utf-8"))

    def write_case(self, path, case):
        path.write_text(json.dumps(case, indent=2) + "\n", encoding="utf-8")

    def verdicts(self, wrong=()):
        """One line per case: the label, except for the ids in wrong."""
        lines = []
        for path in self.cases():
            case = self.case(path)
            verdict = case["label"]
            if case["id"] in wrong:
                verdict = "failed" if verdict == "passed" else "passed"
            lines.append({"case": case["id"], "verdict": verdict, "reason": "The made-up checker says so.",
                          "tokens": 150, "seconds": 3.0, "tool_runs": 1, "tool_version": "9.9.9 (made up)",
                          "model": "the tool's default"})
        return lines

    def record(self, provider, wrong=()):
        verdicts = self.root / f"verdicts-{provider}.jsonl"
        verdicts.write_text("".join(json.dumps(line) + "\n" for line in self.verdicts(wrong)), encoding="utf-8")
        code, output = python(SCORER, "record", "--suite", self.suite,
                              "--shipped", self.root / "api" / "contract" / "shipped_rules.json",
                              "--provider", provider, "--verdicts", verdicts, "--canary", CANARY,
                              "--date", "2026-11-20", "--out", self.result_path(provider))
        assert code == 0, output

    def result_path(self, provider):
        return self.suite / "results" / f"{provider}.json"

    def result(self, provider):
        return json.loads(self.result_path(provider).read_text(encoding="utf-8"))

    def write_result(self, provider, result):
        self.result_path(provider).write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")

    def run_entry(self, provider, tool_runs):
        return {"provider": provider, "date": "2026-11-20", "tool_runs": tool_runs,
                "instruction_sha256": "0" * 64, "cases_sha256": "1" * 64, "reserved": False}

    def write_runs(self, runs):
        (self.suite / "runs.json").write_text(json.dumps({"runs": runs, "changes": []}, indent=2) + "\n",
                                              encoding="utf-8")

    def set_tested(self, providers):
        path = self.root / "api" / "contract" / "registry.json"
        registry = json.loads(path.read_text(encoding="utf-8"))
        registry["lists"]["orchestrator_tested_providers"] = list(providers)
        path.write_text(json.dumps(registry, indent=2) + "\n", encoding="utf-8")

    def set_instruction(self, text):
        path = self.root / "api" / "contract" / "shipped_rules.json"
        shipped = json.loads(path.read_text(encoding="utf-8"))
        for rule in shipped["rules"]:
            if rule["key"] == "specific_details":
                rule["instruction"] = text
        path.write_text(json.dumps(shipped, indent=2) + "\n", encoding="utf-8")

    def check(self):
        return python(SCRIPT, "--root", self.root)


class CheckEvalsTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.copy = Root(self.folder.name)

    def assertFails(self, *phrases):
        code, output = self.copy.check()
        self.assertEqual(code, 1, output)
        for phrase in phrases:
            self.assertIn(phrase, output)
        return output

    def test_the_untouched_copy_passes(self):
        code, output = self.copy.check()
        self.assertEqual(code, 0, output)
        self.assertIn("OK", output)

    def test_23_cases_fail(self):
        self.copy.cases()[-1].unlink()
        self.assertFails("cases: 23 cases, not 24")

    def test_a_case_with_an_email_address_fails(self):
        path = self.copy.cases()[0]
        case = self.copy.case(path)
        case["contract"]["details"] = "Send the file to someone.made.up@example.test when done."
        self.copy.write_case(path, case)
        self.assertFails(f"cases: {case['id']}", "email address")

    def test_a_case_whose_label_is_not_its_categorys_fails(self):
        path = self.copy.cases()[0]
        case = self.copy.case(path)
        case["label"] = "failed"
        self.copy.write_case(path, case)
        self.assertFails(f"cases: {case['id']}")

    def test_a_contract_with_the_review_not_last_fails(self):
        path = self.copy.cases()[1]
        case = self.copy.case(path)
        case["contract"]["criteria"].reverse()
        self.copy.write_case(path, case)
        self.assertFails(f"cases: {case['id']}", "review")

    def test_a_suite_without_the_canary_case_fails(self):
        for path in self.copy.cases():
            text = path.read_text(encoding="utf-8")
            if "{{CANARY_PATH}}" in text:
                path.write_text(text.replace("{{CANARY_PATH}}", "a file nearby"), encoding="utf-8")
        self.assertFails("cases:", "{{CANARY_PATH}}")

    def test_a_result_recorded_against_another_instruction_fails(self):
        self.copy.set_instruction("A made-up instruction that was never run.")
        self.assertFails("results: claude", "another instruction")

    def test_a_changed_case_fails_every_result(self):
        path = self.copy.cases()[2]
        case = self.copy.case(path)
        case["why"] = case["why"].rstrip(".") + ", and a little more."
        self.copy.write_case(path, case)
        self.assertFails("results: claude", "results: codex", "results: gemini", "another case set")

    def test_a_supported_model_with_no_result_fails(self):
        self.copy.result_path("gemini").unlink()
        self.assertFails("results: gemini has no result")

    def test_a_result_whose_met_the_bar_is_not_what_scoring_gives_fails(self):
        result = self.copy.result("codex")
        result["cases"][0]["verdict"] = "none"
        result["cases"][1]["verdict"] = "none"
        result["cases"][2]["verdict"] = "none"
        result["cases"][3]["verdict"] = "none"
        self.copy.write_result("codex", result)
        self.assertFails("results: codex", "met_bar")

    def test_a_result_whose_scores_were_edited_fails(self):
        result = self.copy.result("claude")
        result["scores"]["correct"] = 23
        self.copy.write_result("claude", result)
        self.assertFails("results: claude", "scores")

    def test_a_registry_list_that_names_a_provider_with_no_passing_result_fails(self):
        wrong = [self.copy.case(path)["id"] for path in self.copy.cases()][:4]
        self.copy.record("gemini", wrong=wrong)
        self.assertFails("registry:", "gemini")

    def test_a_registry_list_that_leaves_out_a_passing_provider_fails(self):
        self.copy.set_tested(["claude", "codex"])
        self.assertFails("registry:", "gemini")

    def test_runs_past_a_ceiling_fail(self):
        self.copy.write_runs([self.copy.run_entry("claude", 24)] * 4)
        self.assertFails("runs: claude", "4 full runs")

    def test_a_run_past_30_tool_runs_fails(self):
        self.copy.write_runs([self.copy.run_entry("claude", 31)])
        self.assertFails("runs: claude", "31 tool runs")

    def test_270_in_all_is_the_ceiling(self):
        entries = [self.copy.run_entry(provider, 30) for provider in ("claude", "codex", "gemini") for _ in range(3)]
        self.copy.write_runs(entries)
        code, output = self.copy.check()
        self.assertEqual(code, 0, output)
        self.copy.write_runs(entries + [self.copy.run_entry("grok", 1)])
        self.assertFails("runs:", "271 tool runs in all")

    def test_a_result_with_a_token_shaped_string_fails(self):
        result = self.copy.result("claude")
        result["cases"][5]["reason"] = "It printed lvs_aaaaaaaaaaaaaaaaaaaaaaaa somewhere."
        self.copy.write_result("claude", result)
        self.assertFails("results: claude", "token")

    def test_a_result_with_an_email_address_fails(self):
        result = self.copy.result("codex")
        result["tool_version"] = "codex 1.0 (signed in as made.up@example.test)"
        self.copy.write_result("codex", result)
        self.assertFails("results: codex", "email address")

    def test_a_loosened_bar_fails(self):
        path = self.copy.suite / "bar.json"
        bar = json.loads(path.read_text(encoding="utf-8"))
        bar["bar"]["minimum_correct"] = 18
        path.write_text(json.dumps(bar, indent=2) + "\n", encoding="utf-8")
        self.assertFails("bar:", "minimum_correct")

    def test_a_set_with_one_recorded_miss_passes_and_prints_the_miss(self):
        wrong = [self.copy.case(path)["id"] for path in self.copy.cases() if self.copy.case(path)["label"] == "failed"]
        self.copy.record("codex", wrong=wrong[:2])
        self.copy.set_tested(["claude", "gemini"])
        code, output = self.copy.check()
        self.assertEqual(code, 0, output)
        self.assertIn("MISS: codex", output)
        self.assertIn("2 wrongly passed", output)

    def test_a_model_recorded_as_not_run_passes_and_prints_the_miss(self):
        code, output = python(SCORER, "not-run", "--suite", self.copy.suite,
                              "--shipped", self.copy.root / "api" / "contract" / "shipped_rules.json",
                              "--provider", "gemini", "--reason", "the tool was signed out", "--date", "2026-11-20",
                              "--out", self.copy.result_path("gemini"))
        self.assertEqual(code, 0, output)
        self.copy.set_tested(["claude", "codex"])
        code, output = self.copy.check()
        self.assertEqual(code, 0, output)
        self.assertIn("MISS: gemini was not run", output)


class RepositoryTests(unittest.TestCase):
    def test_the_repositorys_cases_and_bar_have_their_shape(self):
        code, output = python(SCRIPT)
        problems = [line for line in output.splitlines() if line.startswith(("cases:", "bar:", "runs:"))]
        self.assertEqual(problems, [], output)
        self.assertIn(code, (0, 1))


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0]] + (["-v"] if "-v" in sys.argv[1:] else []))
