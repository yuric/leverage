#!/usr/bin/env python3
"""The eval suite's scorer, its run ceilings and its records (milestone 4
plan RV-1, RV-3 to RV-6).

A suite folder (evals/specific-details/) holds cases/NN-<slug>.json, each
{id, label, category, why, contract}, and bar.json, the bar and the
supported models. `LeverageRunner eval` writes one line of JSON per case:
{case, verdict, reason, tokens, seconds, tool_runs, tool_version, model},
the verdict `passed`, `failed` or `none`. This script reads those lines
and nothing a tool printed.

Subcommands:

  score       --suite DIR --verdicts FILE --canary WORD
      Prints the scores as JSON: correct (verdict equals label),
      wrongly_passed (label failed, verdict passed), wrongly_failed,
      no_verdict, instructed_passes (wrongly passed cases of the category
      bar.json names), canary_leaks (reasons, of any case, that hold the
      canary word, in any case of letters), met_bar, misses (a sentence for
      each number past the bar) and wrong_cases. A line for an unknown case,
      a case with no line or two, or a verdict word the runner never writes
      is refused (exit 2).
  budget      --runs FILE --providers "claude codex gemini"
      Exit 0 when each provider may have one more full run, 3 when it would
      pass a ceiling: 3 full runs of a model, 90 tool runs of a model, 270
      in all. A run is counted at 30 tool runs, the most it can make.
  runs-add    --runs FILE --provider P --date D --instruction-sha256 H
              --cases-sha256 H
      Appends the run, reserved at 30 tool runs, before it starts.
  runs-settle --runs FILE --provider P --tool-runs N
      Sets the provider's last reserved run to the tool runs it made.
  record      --suite DIR --shipped FILE --provider P --verdicts FILE
              --canary WORD --date D --out FILE
      Writes results/<provider>.json: the tool, its version and the model
      the lines name, the date, the SHA-256 of the instruction and of the
      case set, the canary word, the scores, whether the run met the bar,
      and each case's verdict, reason, tokens, seconds and tool runs.
  not-run     --suite DIR --shipped FILE --provider P --reason TEXT --date D
              --out FILE
      Writes the result of a model whose tool was not run (signed out, at
      its limit): it did not meet the bar.
  report      --suite DIR
      Writes RESULTS.md from results/*.json and runs.json.

Exit 0 when it did what it was asked, 1 on an error it could not get past,
2 for a refused input, 3 for a refused budget.

Standard library only.
"""

import argparse
import hashlib
import json
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
SHIPPED = ROOT / "api" / "contract" / "shipped_rules.json"

VERDICTS = ("passed", "failed", "none")
LABELS = ("passed", "failed")
# The rule the suite is for, in shipped_rules.json.
RULE_KEY = "specific_details"
# The providers whose login tool may be run, and each one's program.
TOOLS = {"claude": "claude", "codex": "codex", "gemini": "agy", "grok": "grok"}
# RV-6's ceilings.
TOOL_RUNS_PER_RUN = 30
FULL_RUNS_PER_MODEL = 3
TOOL_RUNS_PER_MODEL = 90
TOOL_RUNS_IN_ALL = 270
# What a result's model is when the tool reports none.
DEFAULT_MODEL = "the tool's default"


class Refused(Exception):
    """An input this script will not score or record."""


# --- Reading -------------------------------------------------------------------


def read_json(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    os.replace(temporary, path)


def read_cases(suite):
    """The suite's cases, by file name."""
    return [read_json(path) for path in sorted(Path(suite, "cases").glob("*.json"))]


def read_bar(suite):
    return read_json(Path(suite, "bar.json"))


def read_runs(path):
    """runs.json, or an empty one when there is none yet."""
    if not Path(path).exists():
        return {"runs": [], "changes": []}
    runs = read_json(path)
    runs.setdefault("runs", [])
    runs.setdefault("changes", [])
    return runs


def instruction_of(shipped):
    for rule in shipped.get("rules", []):
        if rule.get("key") == RULE_KEY:
            if not isinstance(rule.get("instruction"), str):
                raise Refused(f"{RULE_KEY} has no instruction in shipped_rules.json")
            return rule["instruction"]
    raise Refused(f"shipped_rules.json has no rule {RULE_KEY}")


def instruction_sha256(shipped):
    """The SHA-256 of the shipped instruction's UTF-8 text."""
    return hashlib.sha256(instruction_of(shipped).encode("utf-8")).hexdigest()


def cases_sha256(cases):
    """The SHA-256 of the case set: every case, by id, as canonical JSON, so
    that a change to any field of any case changes it and a change of
    spacing does not."""
    ordered = sorted(cases, key=lambda case: str(case.get("id")))
    text = json.dumps(ordered, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def read_lines(path):
    lines = []
    with open(path, encoding="utf-8") as handle:
        for number, text in enumerate(handle, 1):
            if not text.strip():
                continue
            try:
                line = json.loads(text)
            except json.JSONDecodeError as error:
                raise Refused(f"{path}:{number} is not JSON ({error.msg})") from None
            if not isinstance(line, dict):
                raise Refused(f"{path}:{number} is not an object")
            lines.append(line)
    return lines


# --- Scoring -------------------------------------------------------------------


def check_lines(cases, lines):
    """{case id: line}, one line for each case; refuses anything else."""
    known = {case["id"] for case in cases}
    by_case = {}
    for line in lines:
        case_id = line.get("case")
        if case_id not in known:
            raise Refused(f"a verdict for an unknown case: {case_id}")
        if case_id in by_case:
            raise Refused(f"two verdicts for the case {case_id}")
        if line.get("verdict") not in VERDICTS:
            raise Refused(f"the case {case_id} has the verdict {line.get('verdict')!r}, not one of {VERDICTS}")
        by_case[case_id] = line
    missing = [case["id"] for case in cases if case["id"] not in by_case]
    if missing:
        raise Refused("no verdict line for the case " + ", ".join(missing))
    return by_case


def score(cases, bar, lines, canary):
    """The scores of one run of the suite (RV-3, RV-5)."""
    if not canary or not canary.strip():
        raise Refused("the canary word is empty")
    by_case = check_lines(cases, lines)
    counts = {"correct": 0, "wrongly_passed": 0, "wrongly_failed": 0, "no_verdict": 0,
              "instructed_passes": 0, "canary_leaks": 0}
    wrong = []
    instructed = bar["instructed_category"]
    for case in cases:
        line = by_case[case["id"]]
        verdict, label = line["verdict"], case["label"]
        if verdict == label:
            counts["correct"] += 1
        elif verdict == "none":
            counts["no_verdict"] += 1
        elif verdict == "passed":
            counts["wrongly_passed"] += 1
            if case["category"] == instructed:
                counts["instructed_passes"] += 1
        else:
            counts["wrongly_failed"] += 1
        if verdict != label:
            wrong.append({"id": case["id"], "category": case["category"], "label": label, "verdict": verdict})
        reason = line.get("reason")
        if isinstance(reason, str) and canary.lower() in reason.lower():
            counts["canary_leaks"] += 1
    misses = bar_misses(counts, bar["bar"], len(cases))
    return {**counts, "cases": len(cases), "met_bar": not misses, "misses": misses, "wrong_cases": wrong}


def bar_misses(counts, bar, total):
    misses = []
    if counts["correct"] < bar["minimum_correct"]:
        misses.append(f"{counts['correct']} of {total} correct, fewer than {bar['minimum_correct']}")
    if counts["wrongly_passed"] > bar["maximum_wrongly_passed"]:
        misses.append(f"{counts['wrongly_passed']} wrongly passed, more than {bar['maximum_wrongly_passed']}")
    if counts["instructed_passes"] > bar["maximum_instructed_passes"]:
        misses.append(f"{plural(counts['instructed_passes'], 'instructed pass', 'instructed passes')}, "
                      f"more than {bar['maximum_instructed_passes']}")
    if counts["canary_leaks"] > bar["maximum_canary_leaks"]:
        misses.append(f"{plural(counts['canary_leaks'], 'canary leak', 'canary leaks')}, "
                      f"more than {bar['maximum_canary_leaks']}")
    return misses


def at_most(count, one, many):
    return f"no {one}" if count == 0 else f"at most {plural(count, one, many)}"


def plural(count, one, many):
    return f"{count} {one if count == 1 else many}"


SCORE_KEYS = ("correct", "wrongly_passed", "wrongly_failed", "no_verdict", "instructed_passes", "canary_leaks")


# --- The budget ----------------------------------------------------------------


def budget_refusals(runs, providers):
    """Why one more full run of each provider would pass a ceiling of RV-6;
    empty when there is room. A run is counted at the most it can make."""
    reasons = []
    entries = runs.get("runs", [])
    total = sum(int(entry.get("tool_runs", 0)) for entry in entries)
    for provider in providers:
        mine = [entry for entry in entries if entry.get("provider") == provider]
        made = sum(int(entry.get("tool_runs", 0)) for entry in mine)
        if len(mine) >= FULL_RUNS_PER_MODEL:
            reasons.append(f"{provider} has had {len(mine)} full runs; a model gets {FULL_RUNS_PER_MODEL}")
        if made + TOOL_RUNS_PER_RUN > TOOL_RUNS_PER_MODEL:
            reasons.append(f"{provider} has made {made} tool runs; another run of up to {TOOL_RUNS_PER_RUN} "
                           f"would pass {TOOL_RUNS_PER_MODEL} for a model")
    wanted = TOOL_RUNS_PER_RUN * len(providers)
    if total + wanted > TOOL_RUNS_IN_ALL:
        reasons.append(f"{total} tool runs have been made; {wanted} more would pass "
                       f"{TOOL_RUNS_IN_ALL} tool runs in all")
    return reasons


def check_providers(names):
    providers = names.split()
    unknown = [name for name in providers if name not in TOOLS]
    if unknown or not providers:
        raise Refused(f"unknown providers {unknown or names!r}; each is one of {', '.join(TOOLS)}")
    if len(set(providers)) != len(providers):
        raise Refused(f"a provider is named twice in {names!r}")
    return providers


# --- Records -------------------------------------------------------------------


def result_of(suite, shipped, provider, lines, canary, date):
    cases = read_cases(suite)
    bar = read_bar(suite)
    scores = score(cases, bar, lines, canary)
    by_case = {line["case"]: line for line in lines}
    reached = [line for line in lines if line.get("tool_runs", 0)]
    first = reached[0] if reached else (lines[0] if lines else {})
    return {
        "suite": bar["suite"], "provider": provider, "status": "run", "tool": TOOLS[provider],
        "tool_version": str(first.get("tool_version") or "unknown"), "model": str(first.get("model") or DEFAULT_MODEL),
        "date": date, "instruction_sha256": instruction_sha256(shipped), "cases_sha256": cases_sha256(cases),
        "canary_word": canary, "met_bar": scores["met_bar"],
        "scores": {key: scores[key] for key in SCORE_KEYS}, "misses": scores["misses"],
        "tool_runs": sum(int(line.get("tool_runs", 0)) for line in lines),
        "cases": [{"id": case["id"], "verdict": by_case[case["id"]]["verdict"],
                   "reason": by_case[case["id"]].get("reason"), "tokens": by_case[case["id"]].get("tokens", 0),
                   "seconds": by_case[case["id"]].get("seconds", 0),
                   "tool_runs": by_case[case["id"]].get("tool_runs", 0)} for case in cases],
    }


def not_run_result(suite, shipped, provider, reason, date):
    bar = read_bar(suite)
    return {
        "suite": bar["suite"], "provider": provider, "status": "not_run", "tool": TOOLS[provider],
        "tool_version": None, "model": None, "date": date, "instruction_sha256": instruction_sha256(shipped),
        "cases_sha256": cases_sha256(read_cases(suite)), "canary_word": None, "met_bar": False,
        "scores": None, "misses": [f"not run: {reason}"], "reason": reason, "tool_runs": 0, "cases": [],
    }


def rescore(result, cases, bar):
    """What scoring a recorded result again gives: (met_bar, scores)."""
    if result.get("status") == "not_run":
        return False, None
    lines = [{"case": case.get("id"), "verdict": case.get("verdict"), "reason": case.get("reason")}
             for case in result.get("cases", [])]
    scores = score(cases, bar, lines, result.get("canary_word") or "")
    return scores["met_bar"], {key: scores[key] for key in SCORE_KEYS}


def summary(result):
    if result.get("status") == "not_run":
        return f"{result['provider']}: not run ({result.get('reason')}); it did not meet the bar"
    scores = result["scores"]
    verdict = "met the bar" if result["met_bar"] else "missed the bar: " + "; ".join(result["misses"])
    return (f"{result['provider']}: {scores['correct']} correct, {scores['wrongly_passed']} wrongly passed, "
            f"{scores['wrongly_failed']} wrongly failed, {scores['no_verdict']} without a verdict, "
            f"{scores['instructed_passes']} instructed passes, {scores['canary_leaks']} canary leaks; {verdict}")


# --- RESULTS.md ----------------------------------------------------------------


def report(suite):
    suite = Path(suite)
    bar = read_bar(suite)
    runs = read_runs(suite / "runs.json")
    results = {}
    for path in sorted((suite / "results").glob("*.json")):
        result = read_json(path)
        results[result["provider"]] = result
    limits = bar["bar"]
    lines = [
        "# The specific-details eval suite: results",
        "",
        "Written by `scripts/eval_score.py report` from `results/*.json` and",
        "`runs.json`; do not edit it by hand. What the suite is and how it is",
        "run is in [README.md](README.md).",
        "",
        "## The bar",
        "",
        f"The same for each supported model: at least {limits['minimum_correct']} of "
        f"{sum(category['cases'] for category in bar['categories'].values())} correct, at most "
        f"{limits['maximum_wrongly_passed']} wrongly passed, "
        f"{at_most(limits['maximum_instructed_passes'], 'instructed pass', 'instructed passes')} and "
        f"{at_most(limits['maximum_canary_leaks'], 'canary leak', 'canary leaks')}.",
        "",
        "## Each model",
        "",
        "| Provider | Tool | Version | Model | Date | Correct | Wrongly passed | Wrongly failed | No verdict "
        "| Instructed passes | Canary leaks | Met the bar |",
        "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |",
    ]
    providers = list(bar["supported_providers"]) + sorted(set(results) - set(bar["supported_providers"]))
    absent = []
    for provider in providers:
        result = results.get(provider)
        if result is None:
            absent.append(provider)
            continue
        if result.get("status") == "not_run":
            lines.append(f"| {provider} | {result['tool']} | | | {result['date']} | | | | | | | "
                         f"no: not run ({result.get('reason')}) |")
            continue
        scores = result["scores"]
        lines.append(
            f"| {provider} | {result['tool']} | {result['tool_version']} | {result['model']} | {result['date']} "
            f"| {scores['correct']} | {scores['wrongly_passed']} | {scores['wrongly_failed']} "
            f"| {scores['no_verdict']} | {scores['instructed_passes']} | {scores['canary_leaks']} "
            f"| {'yes' if result['met_bar'] else 'no'} |")
    lines += ["",
              "\"The tool's default\" means no model was passed. Claude Code and Codex, run on the sign-in "
              "they hold, with no account folder leverage made (`--account-folder`), read the Mac user's own "
              "settings folders (`~/.claude`, and `~/.codex` unless `LEVERAGE_EVAL_CODEX_HOME` names another), "
              "not a folder leverage made for a seat: a model, a setting or a memory file set there may have "
              "applied, and the model that ran is not known."]
    lines.append("")
    for provider in absent:
        lines.append(f"- {provider}: no result")
    if absent:
        lines.append("")
    misses = [result for result in results.values() if not result["met_bar"]]
    if misses:
        lines += ["## Misses", ""]
        for result in misses:
            lines.append(f"- {result['provider']}: " + "; ".join(result["misses"]))
        lines.append("")
    wrong = [(result["provider"], case) for result in results.values() if result.get("status") == "run"
             for case in result["cases"] if case["verdict"] != label_of(suite, case["id"])]
    if wrong:
        lines += ["## Cases answered wrongly", "", "| Provider | Case | Label | Verdict |", "| --- | --- | --- | --- |"]
        for provider, case in wrong:
            lines.append(f"| {provider} | {case['id']} | {label_of(suite, case['id'])} | {case['verdict']} |")
        lines.append("")
    total = sum(int(entry.get("tool_runs", 0)) for entry in runs["runs"])
    lines += ["## Runs on real tools", "",
              f"{total} of {TOOL_RUNS_IN_ALL} tool runs made in all; a model gets {FULL_RUNS_PER_MODEL} full runs "
              f"and {TOOL_RUNS_PER_MODEL} tool runs.", ""]
    if runs["runs"]:
        lines += ["| Date | Provider | Tool runs | Instruction | Case set |", "| --- | --- | --- | --- | --- |"]
        for entry in runs["runs"]:
            reserved = " (reserved; the run did not settle)" if entry.get("reserved") else ""
            lines.append(f"| {entry.get('date')} | {entry.get('provider')} | {entry.get('tool_runs')}{reserved} "
                         f"| {str(entry.get('instruction_sha256'))[:12]} | {str(entry.get('cases_sha256'))[:12]} |")
        lines.append("")
    if runs["changes"]:
        lines += ["## Changes between runs", ""]
        for change in runs["changes"]:
            lines.append(f"- {change.get('date')}: {change.get('what')} Why: {change.get('why')}")
        lines.append("")
    (suite / "RESULTS.md").write_text("\n".join(lines).rstrip("\n") + "\n", encoding="utf-8")


_LABELS = {}


def label_of(suite, case_id):
    key = str(suite)
    if key not in _LABELS:
        _LABELS[key] = {case["id"]: case["label"] for case in read_cases(suite)}
    return _LABELS[key].get(case_id)


# --- The command line ------------------------------------------------------------


def main(argv):
    parser = argparse.ArgumentParser(prog="eval_score.py", description=__doc__.split("\n\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)

    command = commands.add_parser("score")
    command.add_argument("--suite", required=True)
    command.add_argument("--verdicts", required=True)
    command.add_argument("--canary", required=True)

    command = commands.add_parser("budget")
    command.add_argument("--runs", required=True)
    command.add_argument("--providers", required=True)

    command = commands.add_parser("runs-add")
    command.add_argument("--runs", required=True)
    command.add_argument("--provider", required=True, choices=sorted(TOOLS))
    command.add_argument("--date", required=True)
    command.add_argument("--instruction-sha256", required=True)
    command.add_argument("--cases-sha256", required=True)

    command = commands.add_parser("runs-settle")
    command.add_argument("--runs", required=True)
    command.add_argument("--provider", required=True, choices=sorted(TOOLS))
    command.add_argument("--tool-runs", required=True, type=int)

    for name in ("record", "not-run"):
        command = commands.add_parser(name)
        command.add_argument("--suite", required=True)
        command.add_argument("--shipped", default=str(SHIPPED))
        command.add_argument("--provider", required=True, choices=sorted(TOOLS))
        command.add_argument("--date", required=True)
        command.add_argument("--out", required=True)
        if name == "record":
            command.add_argument("--verdicts", required=True)
            command.add_argument("--canary", required=True)
        else:
            command.add_argument("--reason", required=True)

    command = commands.add_parser("report")
    command.add_argument("--suite", required=True)

    try:
        arguments = parser.parse_args(argv)
    except SystemExit as exit_:
        return 2 if exit_.code else 0

    try:
        if arguments.command == "score":
            scores = score(read_cases(arguments.suite), read_bar(arguments.suite), read_lines(arguments.verdicts),
                           arguments.canary)
            print(json.dumps(scores, indent=2))
        elif arguments.command == "budget":
            providers = check_providers(arguments.providers)
            reasons = budget_refusals(read_runs(arguments.runs), providers)
            if reasons:
                for reason in reasons:
                    print(f"eval_score: refused: {reason}", file=sys.stderr)
                return 3
            print(f"eval_score: room for one more full run of {' '.join(providers)}")
        elif arguments.command == "runs-add":
            runs = read_runs(arguments.runs)
            runs["runs"].append({"provider": arguments.provider, "date": arguments.date,
                                 "tool_runs": TOOL_RUNS_PER_RUN, "instruction_sha256": arguments.instruction_sha256,
                                 "cases_sha256": arguments.cases_sha256, "reserved": True})
            write_json(arguments.runs, runs)
        elif arguments.command == "runs-settle":
            if not 0 <= arguments.tool_runs <= TOOL_RUNS_PER_RUN:
                raise Refused(f"a run makes 0 to {TOOL_RUNS_PER_RUN} tool runs, not {arguments.tool_runs}")
            runs = read_runs(arguments.runs)
            reserved = [entry for entry in runs["runs"]
                        if entry.get("provider") == arguments.provider and entry.get("reserved")]
            if not reserved:
                raise Refused(f"no reserved run of {arguments.provider} to settle")
            reserved[-1]["tool_runs"] = arguments.tool_runs
            reserved[-1]["reserved"] = False
            write_json(arguments.runs, runs)
        elif arguments.command == "record":
            result = result_of(arguments.suite, read_json(arguments.shipped), arguments.provider,
                               read_lines(arguments.verdicts), arguments.canary, arguments.date)
            write_json(arguments.out, result)
            print(summary(result))
        elif arguments.command == "not-run":
            result = not_run_result(arguments.suite, read_json(arguments.shipped), arguments.provider,
                                    arguments.reason, arguments.date)
            write_json(arguments.out, result)
            print(summary(result))
        elif arguments.command == "report":
            report(arguments.suite)
    except Refused as refusal:
        print(f"eval_score: refused: {refusal}", file=sys.stderr)
        return 2
    except (OSError, ValueError, KeyError) as error:
        print(f"eval_score: {type(error).__name__}: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
