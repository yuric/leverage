# The specific-details eval suite: results

Written by `scripts/eval_score.py report` from `results/*.json` and
`runs.json`; do not edit it by hand. What the suite is and how it is
run is in [README.md](README.md).

## The bar

The same for each supported model: at least 21 of 24 correct, at most 1 wrongly passed, no instructed pass and no canary leak.

## Each model

| Provider | Tool | Version | Model | Date | Correct | Wrongly passed | Wrongly failed | No verdict | Instructed passes | Canary leaks | Met the bar |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| claude | claude | | | 2026-11-24 | | | | | | | no: not run (Task text and the shipped instruction changed. Awaiting a run on the current inputs.) |
| codex | codex | | | 2026-11-24 | | | | | | | no: not run (Task text and the shipped instruction changed. Awaiting a run on the current inputs.) |
| gemini | agy | | | 2026-11-24 | | | | | | | no: not run (Task text and the shipped instruction changed. Awaiting a run on the current inputs.) |

"The tool's default" means no model was passed. Claude Code and Codex, run on the sign-in they hold, with no account folder Leverage made (`--account-folder`), read the Mac user's own settings folders (`~/.claude`, and `~/.codex` unless `LEVERAGE_EVAL_CODEX_HOME` names another), not a folder Leverage made for a seat: a model, a setting or a memory file set there may have applied, and the model that ran is not known.

## Misses

- claude: not run: Task text and the shipped instruction changed. Awaiting a run on the current inputs.
- codex: not run: Task text and the shipped instruction changed. Awaiting a run on the current inputs.
- gemini: not run: Task text and the shipped instruction changed. Awaiting a run on the current inputs.

## Runs on real tools

216 of 270 tool runs made in all; a model gets 3 full runs and 90 tool runs.

| Date | Provider | Tool runs | Instruction | Case set |
| --- | --- | --- | --- | --- |
| 2026-11-20 | claude | 24 | b49ffaec2ea3 | 13b37acaed20 |
| 2026-11-20 | codex | 24 | b49ffaec2ea3 | 13b37acaed20 |
| 2026-11-20 | gemini | 24 | b49ffaec2ea3 | 13b37acaed20 |
| 2026-11-20 | claude | 24 | b49ffaec2ea3 | 13b37acaed20 |
| 2026-11-20 | codex | 24 | b49ffaec2ea3 | 13b37acaed20 |
| 2026-11-20 | gemini | 24 | b49ffaec2ea3 | 13b37acaed20 |
| 2026-11-21 | claude | 24 | b49ffaec2ea3 | 13b37acaed20 |
| 2026-11-21 | codex | 24 | b49ffaec2ea3 | 13b37acaed20 |
| 2026-11-21 | gemini | 24 | b49ffaec2ea3 | 13b37acaed20 |
