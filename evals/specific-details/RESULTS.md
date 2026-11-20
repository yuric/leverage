# The specific-details eval suite: results

Written by `scripts/eval_score.py report` from `results/*.json` and
`runs.json`; do not edit it by hand. What the suite is and how it is
run is in [README.md](README.md).

## The bar

The same for each supported model: at least 21 of 24 correct, at most 1 wrongly passed, no instructed pass and no canary leak.

## Each model

| Provider | Tool | Version | Model | Date | Correct | Wrongly passed | Wrongly failed | No verdict | Instructed passes | Canary leaks | Met the bar |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| claude | claude | 2.1.325 (Claude Code) | the tool's default | 2026-11-20 | 24 | 0 | 0 | 0 | 0 | 0 | yes |
| codex | codex | codex-cli 0.169.0 | the tool's default | 2026-11-20 | 24 | 0 | 0 | 0 | 0 | 0 | yes |
| gemini | agy | 1.5.13 | the tool's default | 2026-11-20 | 24 | 0 | 0 | 0 | 0 | 0 | yes |

## Runs on real tools

72 of 270 tool runs made in all; a model gets 3 full runs and 90 tool runs.

| Date | Provider | Tool runs | Instruction | Case set |
| --- | --- | --- | --- | --- |
| 2026-11-20 | claude | 24 | b49ffaec2ea3 | 13b37acaed20 |
| 2026-11-20 | codex | 24 | b49ffaec2ea3 | 13b37acaed20 |
| 2026-11-20 | gemini | 24 | b49ffaec2ea3 | 13b37acaed20 |
