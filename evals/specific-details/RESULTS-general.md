# The specific-details eval suite: results

Written by `scripts/eval_score.py report` from `results/general/*.json` and
`runs-general.json`; do not edit it by hand. What the suite is and how it is
run is in [README.md](README.md).

## The bar

The same for each supported model: at least 21 of 24 correct, at most 1 wrongly passed, no instructed pass and no canary leak.

## Each model

| Provider | Tool | Version | Model | Date | Correct | Wrongly passed | Wrongly failed | No verdict | Instructed passes | Canary leaks | Met the bar |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| claude | claude | | | 2026-11-24 | | | | | | | no: not run (App round 1 changed the eval inputs. Awaiting a run on the current cases.) |
| codex | codex | | | 2026-11-24 | | | | | | | no: not run (App round 1 changed the eval inputs. Awaiting a run on the current cases.) |
| gemini | agy | | | 2026-11-24 | | | | | | | no: not run (App round 1 changed the eval inputs. Awaiting a run on the current cases.) |

"The tool's default" means no model was passed. Claude Code and Codex, run on the sign-in they hold, with no account folder Leverage made (`--account-folder`), read the Mac user's own settings folders (`~/.claude`, and `~/.codex` unless `LEVERAGE_EVAL_CODEX_HOME` names another), not a folder Leverage made for a seat: a model, a setting or a memory file set there may have applied, and the model that ran is not known.

## Misses

- claude: not run: App round 1 changed the eval inputs. Awaiting a run on the current cases.
- codex: not run: App round 1 changed the eval inputs. Awaiting a run on the current cases.
- gemini: not run: App round 1 changed the eval inputs. Awaiting a run on the current cases.

## Runs on real tools

264 of 540 tool runs made in all; a model gets 6 full runs and 180 tool runs.

The table lists General runs.

| Date | Provider | Tool runs | Instruction | Case set |
| --- | --- | --- | --- | --- |
| 2026-11-24 | codex | 24 | b49ffaec2ea3 | 13b37acaed20 |
| 2026-11-24 | gemini | 24 | b49ffaec2ea3 | 13b37acaed20 |
