# 0013. Eval suites for rules a model judges

Status: Accepted

## Context

The PRD ships "Every task needs specific details" as a rule a model
judges, and asks that each shipped rule a model judges pass an eval suite
at a bar on each supported model before release (L450, L924). It names
neither the cases, the bar, the supported models nor how a suite is run.
A suite run spends real quota on the owner's logins and cannot run in CI,
which never calls a provider. What a suite is, what it is measured
against, how much it may spend and what its results are used for are hard
to change once results are recorded against them (rule AR-003). The
decisions are the milestone's plan RV-1 to RV-7.

## Decision

1. **A suite is a folder.** `evals/<suite>/` holds `README.md`, one
   made-up case per file under `cases/` (`{id, label, category, why,
   contract}`; `why` is never given to a model), `bar.json` (the bar and
   the supported models), `results/<provider>.json` (the run that counts,
   per supported model), `runs.json` (every run on real tools, with its
   date and its number of tool runs) and `RESULTS.md`, written by the
   scorer. The first is `evals/specific-details/` (RV-1).
2. **What the rule means is written down first.** S-2 in the PRD and the
   shipped instruction say when a task has specific details (RV-2).
3. **24 cases, the production path outside the server.** 12 that should
   pass and 12 that should fail, in five categories, four of which tell
   the checker what to do; one plants a verdict line and one asks the
   checker to read a file outside its folder whose made-up word is in no
   prompt. `api/script/evals/build_inputs.rb` builds each case's job input
   with the server's own `JobInputs`, and `LeverageRunner eval` runs it
   through `CheckJob`'s prompt, check mode and parser, one tool run per
   case and one more only for a case with no verdict (RV-3).
4. **The supported models are fixed before any run.** The default model
   of each login tool signed in on the owner's Mac (Claude Code, the
   Codex CLI and Antigravity), in `bar.json`. No result changes the list:
   a model that misses the bar stays supported with a failed result, and
   the release line fails for it (RV-4).
5. **One bar for every model.** At least 21 of 24 correct, at most 1
   wrongly passed, no instructed pass and no leak of the file's word
   (RV-5).
6. **Only the maintainer runs it, within ceilings.** `scripts/eval_rule.sh`
   refuses with `CI` set, without `LEVERAGE_EVAL` naming the suite, and
   unless exactly one of `LEVERAGE_TOOL_DIR` (the stand-ins) and
   `LEVERAGE_EVAL_REAL=1` is set. On real tools it uses the sign-in each
   tool already holds and signs in to nothing. A model gets at most three
   full runs, 90 tool runs, and the suite 270 in all; `runs.json` counts
   them and the script refuses a run that would pass either (RV-6).
7. **The results inform the owner and refuse nothing.** The registry list
   `orchestrator_tested_providers` holds the providers whose result met
   the bar, and the app says "Not tested for checking tasks." beside an
   orchestrator on another provider, with a model chosen, or that connects
   on its own. No orchestrator is refused for its provider or model. CI
   runs `scripts/check_evals.py`, which needs no provider: the cases'
   shape, a result per supported model recorded against today's
   instruction and case set, each result scored again, the registry list,
   the ceilings, and no email or token in a result (RV-5, RV-7).

## Alternatives considered

- **Call supported whichever models pass.** No run could then fail.
- **One accuracy figure over all models.** It hides a model that lets
  vague tasks through.
- **Refuse an orchestrator the suite has not covered.** The PRD has no
  such rule, and a handoff can move a job to another provider in any case.
- **Run the suite in CI.** CI never calls a provider.

## Consequences

- A change to the instruction or a case fails CI until the suite is run
  again, by the maintainer. So does a change to the role file for
  Orchestrator results, and to the General role's job rules for General
  results. A change to the prompt's frame, the parser or a tool's
  check-mode flags does not; the maintainer runs the suite again by hand.
- CI checks that each result agrees with its ledger's latest settled run,
  the cases and the wording, not that a real run made it. Only the
  maintainer's eval run changes the results, the ledgers and the registry
  lists, and every pull request is the owner's to read.
- The suite covers the shipped wording, each tool's default model at the
  version on the Mac, and one run per case. An edited instruction, a model
  the owner chooses, the model of a credential a job is handed to, another
  provider reached by handoff, and Grok are not covered, and nothing stops
  them.
- The script takes a suite's name, and today accepts only
  `specific-details`: the approval rule's suite is the Questions and
  approvals milestone's.

## 2026-11-24 budget update

The owner raised the ceilings in decision 6 for `specific-details` to
allow runs in General mode. The suite gets six full runs and 180 tool runs
per model, with 540 tool runs in all. The Orchestrator ledger `runs.json`
and General ledger `runs-general.json` count toward the same ceilings.
Each full run remains limited to 30 tool runs, including up to six second
tries.

On 2026-11-24 the owner also raised the `approves-actions` ceilings to
allow Codex and Antigravity to rerun the main cases in both modes. The
two ledgers share six full main runs and 240 tool runs per model, with
720 tool runs in all. Each main run has up to 36 tool runs, including
up to six second tries. The held-out limits stay at one run per model
with up to 12 tool runs, including up to two second tries.
