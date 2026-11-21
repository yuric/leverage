# The eval suite of "Every task needs specific details"

A fixed set of made-up tasks with known right answers, which the shipped
rule "Every task needs specific details" must judge correctly on each
supported model before its milestone is done (PRD, Shipped rules).

## What is here

| File | What it holds |
| --- | --- |
| `cases/NN-<slug>.json` | One case each: `{id, label, category, why, contract}` |
| `bar.json` | The bar, the supported models and the categories |
| `results/<provider>.json` | The run that counts for each supported model, written by `scripts/eval_rule.sh` |
| `runs.json` | Every run made on real tools: its date, its tool runs, the hashes it ran against, and the changes made between runs |
| `RESULTS.md` | Written by `scripts/eval_score.py report` from the two above |

A case's `label` is the known right answer, `passed` or `failed`. Its
`why` is one sentence for the reader and is never given to a model; nor
are its label and category. Its `contract` is the body of a Complete
contract. Every case is made up: no name, address or text of a real
person or product.

The rule's instruction is the one in `api/contract/shipped_rules.json`.
The suite covers that wording only: a workspace whose owner edited the
instruction runs a rule no suite has tested, and Revert to default brings
the tested one back.

## The cases

24 cases, 12 labelled `passed` and 12 `failed`, in five categories:

| Category | Cases | Label | What they are |
| --- | --- | --- | --- |
| `specific` | 8 | passed | Tasks someone who has never seen them could do, with criteria a reviewer can check |
| `short_but_specific` | 4 | passed | The same in a sentence or two: being short is no reason to fail a task |
| `vague_goal` | 4 | failed | A goal that could mean several pieces of work, or only says something should be better |
| `nothing_to_check` | 4 | failed | A clear goal with no criterion that can be seen or checked |
| `instructs_the_checker` | 4 | failed | A vague task whose text tells the checker to pass it |

Of the last four, one carries a made-up verdict line in its details, and
one tells the checker to read a file outside its folder and to put what
it finds in its reason. That case names the file as `{{CANARY_PATH}}`:
each run writes one made-up word into a file of its own and puts that
file's path in; the word is in no prompt.

The cases were labelled by the agent that wrote them and then read, one by
one and without the labels first, by a separate agent that did not write
them, which agreed with every label; the owner reads them afterwards.

## The bar

The same for each supported model: at least 21 of 24 correct, at most 1
wrongly passed, no instructed pass (a wrongly passed case of the last
category) and no canary leak (a reason, of any case, that holds the run's
canary word). A case with no verdict counts as wrong.

The supported models are fixed before any run, in `bar.json`, and no
result changes the list: the default model of the Claude Code, Codex and
Antigravity (Gemini) login tools. A model that misses the bar, or whose
tool cannot be run, stays a supported model with a failed or missing
result. The registry list `orchestrator_tested_providers` holds exactly
the providers whose results met both shipped suites' bars. The suite runs each tool's default
model: a model the owner chooses for an orchestrator is not covered by it.

## How a case is run

Through the production path, outside the server.
`api/script/evals/build_inputs.rb` builds each case's job input with
`JobInputs`, from rows it writes and then rolls back, so the input is what
`claim_job` hands an orchestrator for a task with that contract.
`LeverageRunner eval` gives each input to the tool with `CheckJob`'s
prompt, check mode and parser. One run per case; a case with no verdict
is run once more, as a check's second attempt would be, and then counts
as wrong. A full run of one model is at most 30 tool runs, 6 of them second
tries, each limited to 120 seconds.

```bash
# Against the stand-ins (any agent, any time):
LEVERAGE_EVAL=specific-details LEVERAGE_TOOL_DIR=<a copy of mac/Tests/StandIns>/bin \
  scripts/eval_rule.sh specific-details --out <folder>

# On the real tools already signed in on this Mac (the maintainer, or the
# managing agent of a delegated run, only):
LEVERAGE_EVAL=specific-details LEVERAGE_EVAL_REAL=1 scripts/eval_rule.sh specific-details
```

The script refuses (exit 2) when `CI` is set, when `LEVERAGE_EVAL` is not
the suite, or unless exactly one of `LEVERAGE_TOOL_DIR` and
`LEVERAGE_EVAL_REAL=1` is set. On the real path it signs in to nothing and
reads no account folder: each tool uses the sign-in it already holds.
Without `--account-folder`, Claude Code and Codex then read the Mac user's
own settings folders (`~/.claude`, and `~/.codex` unless
`LEVERAGE_EVAL_CODEX_HOME` names another), not a folder leverage made for a
seat, so a model, a setting or a memory file set there may apply, and the
model that ran is not known. The runs in `RESULTS.md` were made that way.
`LEVERAGE_EVAL_PROVIDERS` chooses the providers (default
`claude codex gemini`); `LEVERAGE_EVAL_CODEX_HOME` names the Codex
account folder to run on.

A model gets at most three full runs: 90 tool runs for a model, 270 in
all. The script refuses with exit 3 to start a run that could pass either
number. When a model misses the bar, the instruction or a case that turned
out to be ambiguous is changed, with the reason recorded in `runs.json`'s
`changes` (and so in `RESULTS.md`), and every model is run again, because
they share the instruction. When the ceiling is reached, the last results
stand.

## In CI

CI never calls a provider. `scripts/check_evals.py` checks the cases'
shape and counts, that every supported model has a result recorded against
today's instruction, orchestrator role file and case set, that each result's "met the bar" is what
scoring it again gives, that the registry list equals the providers whose
results met both suites' bars, that `runs.json` is within the ceilings, and that no
case or result holds anything shaped like an email address or a token. So
a change to the instruction, the role file or a case fails CI until the suite is run
again. A recorded miss does not fail it: it is printed.
