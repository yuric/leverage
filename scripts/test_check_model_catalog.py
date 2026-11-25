#!/usr/bin/env python3
"""Self-test for check_model_catalog.py.

Runs check_model_catalog.py on the real catalog and on doctored copies
written to a temporary folder. The checker must accept documented efforts
regardless of native driver support and reject invalid entries with a
diagnostic (contract decision UX-5).

Usage: python3 scripts/test_check_model_catalog.py [-v]
Standard library only; exits 0 when every case behaves as expected.
"""

import copy
import json
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
SCRIPT = HERE / "check_model_catalog.py"
MODELS = ROOT / "api" / "contract" / "models.json"
REGISTRY = ROOT / "api" / "contract" / "registry.json"
VERBOSE = "-v" in sys.argv[1:]
FAILURES = []


def run(models, registry=None):
    with tempfile.TemporaryDirectory() as folder:
        models_path = Path(folder) / "models.json"
        models_path.write_text(json.dumps(models), encoding="utf-8")
        registry_path = Path(folder) / "registry.json"
        registry_path.write_text(json.dumps(registry if registry is not None else load(REGISTRY)), encoding="utf-8")
        result = subprocess.run(
            [sys.executable, "-I", str(SCRIPT), "--models", str(models_path),
             "--registry", str(registry_path), "--root", str(ROOT)],
            capture_output=True, text=True, check=False)
    return result.returncode, result.stdout + result.stderr


def load(path):
    return json.loads(path.read_text(encoding="utf-8"))


def expect(name, code, output, want_code, must_contain=()):
    problems = []
    if code != want_code:
        problems.append(f"exit code {code}, wanted {want_code}")
    for needle in must_contain:
        if needle not in output:
            problems.append(f"output lacks {needle!r}")
    if problems:
        FAILURES.append(name)
        print(f"FAIL {name}: {'; '.join(problems)}")
        print("  " + output.replace("\n", "\n  "))
    elif VERBOSE:
        print(f"ok   {name}")


def provider(models, name):
    return next(entry for entry in models["providers"] if entry["provider"] == name)


def first_model(models, name):
    return provider(models, name)["models"][0]


def cases(models):
    """(name, change, strings the failure must name)."""

    def unknown_level(m):
        first_model(m, "claude")["evidence"] = "unverified"

    def empty_source(m):
        first_model(m, "claude")["source"] = " "

    def no_date(m):
        del first_model(m, "claude")["checked_on"]

    def impossible_date(m):
        first_model(m, "claude")["checked_on"] = "2026-13-45"

    def documented_without_address(m):
        first_model(m, "claude")["source"] = "trust me"

    def documented_over_http(m):
        first_model(m, "claude")["source"] = "http://example.com/models"

    def help_without_path(m):
        entry = first_model(m, "codex")
        entry["evidence"] = "help"
        entry["source"] = "codex --help, read on this Mac"

    def help_with_missing_path(m):
        entry = first_model(m, "codex")
        entry["evidence"] = "help"
        entry["source"] = "docs/no-such-file.md"

    def efforts_from_help(m):
        first_model(m, "claude")["efforts"] = {"values": ["low"], "evidence": "help",
                                              "source": "mac/Sources/LeverageRunner/ClaudeDriver.swift",
                                              "checked_on": "2026-11-24"}

    def duplicate_model(m):
        entry = provider(m, "claude")
        entry["models"].append(copy.deepcopy(entry["models"][0]))

    def default_not_listed(m):
        provider(m, "grok")["default_model"]["value"] = "grok-made-up"

    def api_provider(m):
        entry = copy.deepcopy(provider(m, "codex"))
        entry["provider"] = "openai_api"
        m["providers"].append(entry)

    def provider_twice(m):
        m["providers"].append(copy.deepcopy(provider(m, "gemini")))

    def provider_missing(m):
        m["providers"] = [entry for entry in m["providers"] if entry["provider"] != "gemini"]

    def duplicate_effort(m):
        entry = first_model(m, "claude")
        entry["efforts"]["values"] = ["low", "low"]

    return [
        ("an evidence level outside the list", unknown_level, ["claude", "unverified"]),
        ("an empty source", empty_source, ["claude", "source"]),
        ("a missing date", no_date, ["claude", "checked_on"]),
        ("a date that is no calendar date", impossible_date, ["claude", "checked_on"]),
        ("a documented source that is no address", documented_without_address, ["claude", "documented", "address"]),
        ("a documented source that is not https", documented_over_http, ["claude", "documented", "address"]),
        ("a help entry citing no repository path", help_without_path, ["codex", "help", "repository"]),
        ("a help entry citing a path that does not exist", help_with_missing_path, ["codex", "docs/no-such-file.md"]),
        ("efforts with help evidence", efforts_from_help, ["claude", "efforts", "documented"]),
        ("a model listed twice", duplicate_model, ["claude", "twice"]),
        ("a default model not among the models", default_not_listed, ["grok", "grok-made-up", "default"]),
        ("a provider that is not a login provider", api_provider, ["openai_api", "login"]),
        ("a provider listed twice", provider_twice, ["gemini", "twice"]),
        ("a login provider missing", provider_missing, ["gemini", "missing"]),
        ("an effort listed twice", duplicate_effort, ["claude", "low", "twice"]),
    ]


def main():
    models = load(MODELS)
    code, output = run(models)
    expect("the real catalog passes", code, output, 0, ["OK"])

    prompt_efforts = copy.deepcopy(models)
    provider(prompt_efforts, "codex")["native_effort"]["value"] = False
    first_model(prompt_efforts, "codex")["efforts"] = {
        "values": ["low"], "evidence": "documented",
        "source": "https://example.com/made-up", "checked_on": "2026-11-24",
    }
    code, output = run(prompt_efforts)
    expect("documented efforts for a provider whose driver takes none", code, output, 0, ["OK"])

    for name, change, needles in cases(models):
        doctored = copy.deepcopy(models)
        change(doctored)
        code, output = run(doctored)
        expect(name, code, output, 1, needles)

    code, output = run({"providers": []})
    expect("a catalog without evidence levels", code, output, 1, ["evidence_levels"])

    if FAILURES:
        print(f"{len(FAILURES)} case(s) failed.")
        return 1
    print("All check_model_catalog.py self-test cases passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
