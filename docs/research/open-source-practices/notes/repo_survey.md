# Measured repository practices of young (created >= 2024-11-18), 1,000+ star GitHub repositories

All figures below are primary measurements made on 2026-11-18 (search run 19:42 UTC; per-repo survey about 19:50-19:58 UTC; strict second pass about 20:00 UTC) with the authenticated `gh api` CLI, GET requests only. Source files:

- Per-repo data: [repo_survey_data.csv](../data/repo_survey_data.csv) (100 rows, one per repository).
- Scripts, in [`../data/`](../data/): `repo_survey_script.py` (stages: `candidates`, `survey`, `validate`), `repo_survey_merge.py` (merges stages and applies manual review flags), `repo_survey_analyze.py` (produces every percentage; run `python3 repo_survey_analyze.py repo_survey_data.csv`).
- Printed results: [analysis_output.txt](../data/analysis_output.txt), the full ranked table plus segment tables by owner type, star band, age and category.
- Raw API captures (search results, the examined pool, the selected sample, the exclusion list, and the first- and second-pass survey output, about 10 MB of JSON in total) are not published in this repository. Where the text below cites one of those files by name, it is naming the capture the figure came from.

In this document "n=100" is the denominator unless stated. Every percentage is reproducible from the CSV with the analyze script. No secondary datasets (Octoverse, academic studies, Scorecard aggregates) were consulted, so nothing here is compared to outside figures.

## Sample construction, queries, exclusions and method

### Takeaway

100 repositories were measured: 25 in each of four star bands, 52 created 2024-11-18 to 2025-11-17 and 48 created 2025-11-18 or later; all 100 re-verified from a fresh `repos/{o}/{r}` call as created >= 2024-11-18, stars > 1000, not a fork, not archived (0 dropped). Of 158 randomly drawn candidates examined, 22 (13.9%) were non-software (prompt/skill collections, awesome lists, courses, leak mirrors and the like) and were excluded.

### Cited Findings

- Universe size at query time (search `total_count`, `created:>=2024-11-18 fork:false archived:false`): stars 1001-2000 = 3,638; 2001-5000 = 2,348; 5001-20000 = 1,176; >20000 = 353; total 7,515 repos. — `search_candidates_raw.json` (raw capture, not published)
- Queries used (16 cells = 4 star bands x 4 created-date windows; `sort=stars&per_page=100`, one random page per cell, page number in brackets; `q` = `created:{window} stars:{band} fork:false archived:false`). Windows: W1 = 2024-11-18..2025-05-17, W2 = 2025-05-18..2025-11-17, W3 = 2025-11-18..2026-05-17, W4 = 2026-05-18..2026-11-18. Cell totals (page): 1001..2000: W1 729 (p4), W2 734 (p6), W3 1254 (p2), W4 921 (p1); 2001..5000: W1 515 (p1), W2 459 (p2), W3 837 (p7), W4 537 (p3); 5001..20000: W1 261 (p2), W2 208 (p3), W3 440 (p4), W4 267 (p3); >20000: W1 71 (p1), W2 76 (p1), W3 163 (p1), W4 43 (p1). Random seed 20261118. Search was preceded by a `per_page=1` call per cell to read `total_count`. — `search_candidates_raw.json` (raw capture, not published)
- 10 repos were randomly drawn per cell (seed 7) = 158 examined (two cells had fewer than 10 candidates: 5k-20k W2 has only 8 results). I read name, description and topics of all 158 by hand and excluded 22; then took 25 per star band round-robin across windows. — `examined_pool.json` (raw capture, not published), `sample_selected.json` (raw capture, not published)
- Exclusions: 22 of 158 examined (13.9%). By band: 20k+ 7 of 40 (17.5%); 5k-20k 6 of 38 (15.8%); 2k-5k 5 of 40 (12.5%); 1k-2k 4 of 40 (10%). Reasons: prompt/skill/template collections or "awesome" lists (about 10), books/courses/guides (6), leaked-source dumps or mirrors (3), 1 exploit-PoC dump, 1 hardware-files-only repo, 1 binary-releases-only repo. The individual repositories are not named here. — `exclusions.json` (raw capture, not published)
- Sample composition: owner type Organization 53 / User 47; category (my manual labels) AI/LLM tooling 53, application 21, developer tool 12, infrastructure 6, framework/library 4, other 4; primary language Python 26, TypeScript 24, JavaScript 12, Rust 9, C# 5, Swift 5, Go 4, C 4, Dart 3, Shell 3, HTML 2, Kotlin/Java/none 1 each. — [analysis_output.txt](../data/analysis_output.txt)
- Per-repo calls: `repos/{o}/{r}`, `git/trees/{branch}?recursive=1` (0 truncated), `{owner}/.github` repo + tree (cached per owner, 26 of the 100 repos belong to an owner that has a `.github` repo), README raw, CONTRIBUTING raw, issue `config.yml` raw, up to 8 workflow files raw, `releases?per_page=1` (count from Link header), `tags?per_page=30`, `contributors?per_page=1&anon=false`, `community/profile`, `private-vulnerability-reporting`. All 100 repos returned every endpoint without error. A second pass re-read README, CONTRIBUTING and workflows with stricter regexes. — [repo_survey_script.py](../data/repo_survey_script.py)

### Inferences

- The universe is large (7,515), so n=100 gives roughly +/-10 percentage points (95%) on a 50% proportion; differences under about 15 points between segments of 25-50 repos are within noise.
- About 1 in 7 young 1,000+ star repos is not a software project in the ordinary sense, and the share rises with stars (17.5% at 20k+ vs 10% at 1k-2k, though these are small counts).

### Gaps

- Within-cell sampling is a random page among the first (up to) 10 pages of star-sorted results, so each cell is sampled from its top 1,000 results only; for the >20000 W3 cell (163 repos) only page 1 (top 100) was available to the sampler. Cells with fewer than 1,000 results are sampled across their whole range; only 1k-2k W3 (1,254 results) exceeds the 1,000-result search cap, so its lowest-star repos were unreachable.
- Exclusion judgments are mine, from names/descriptions; borderline repos (e.g. affaan-m/ECC, vercel-labs/skills, geeklee/srt-whiteboard-animation, 1692775560/deepseek_project) were kept.

## 1. Adoption per practice, ranked, with tiers

### Takeaway

Basic hygiene (README, issues, .gitignore, a detectable license, tags/releases, some CI) is near-universal; community files (CONTRIBUTING, CODE_OF_CONDUCT, SECURITY, templates) sit around 30-55%; governance/process documents (ADR, RFC, ROADMAP, GOVERNANCE, MAINTAINERS), supply-chain tooling (Scorecard, pinning, Dependabot) and AI-contribution policies are rare. Community-profile health percentage median is 60 (mean 60.8, min 14, max 100); only 11 of 100 reach 100% and 25 reach 80%+.

### Cited Findings

Counts out of n=100 unless noted. "Any" = own repo or inherited from the owner's `.github` repo. Tiers: near-universal >80%, common 40-80%, minority 10-40%, rare <10%. Source for every row: [repo_survey_data.csv](../data/repo_survey_data.csv) via [analyze script](../data/repo_survey_analyze.py); full ranked list in [analysis_output.txt](../data/analysis_output.txt).

#### Near-universal (>80%)

| Practice | n | % |
|---|---|---|
| README present | 99 | 99 |
| Issues enabled | 99 | 99 |
| .gitignore | 94 | 94 |
| README has an image/GIF/video (strict, badges excluded; of 99 with README = 88%) | 87 | 87 |
| A LICENSE-type file in tree | 90 | 90 |
| Git tags | 84 | 84 |
| GitHub-recognised license (SPDX id) | 81 | 81 |
| GitHub Releases >= 1 | 81 | 81 |
| GitHub Actions workflows >= 1 (any CI = also 80) | 80 | 80 |

#### Common (40-80%)

| Practice | n | % |
|---|---|---|
| Test directory or test files in tree | 74 | 74 |
| README install/quick-start/usage heading | 73 | 73 |
| README badges | 72 | 72 |
| Semver-style tags (>=50% of latest 30 tags) | 71 | 71 |
| Release/publish automation in a workflow (loose regex: any "release/publish/goreleaser/docker build-push"; of the 80 CI repos 68 = 85%) | 68 | 68 |
| Workflows declare a `permissions:` block (of up to 8 workflows read) | 73 | 73 |
| Homepage URL set | 64 | 64 |
| docs/ directory | 57 | 57 |
| Topics set | 57 | 57 |
| Wiki enabled (default-on setting, not a deliberate practice) | 56 | 56 |
| Workflow runs tests (strict test-command regex; loose "tests or build" = 58) | 53 | 53 |
| Issue templates | 54 | 54 |
| GitHub Discussions enabled | 54 | 54 |
| CONTRIBUTING | 51 | 51 |
| Agent-instruction file/dir of any kind at root (AGENTS.md, CLAUDE.md, .claude/, .agents/, .cursor/, copilot-instructions/.github/instructions, GEMINI.md etc.) | 49 | 49 |
| Workflow runs lint/format/typecheck (loose regex) | 48 | 48 |
| SECURITY policy or private vulnerability reporting (either) | 47 | 47 |
| AGENTS.md or CLAUDE.md at repo root (any depth: 47) | 45 | 45 |
| Issue templates as YAML forms | 42 | 42 |
| .gitattributes | 41 | 41 |

#### Minority (10-40%)

| Practice | n | % |
|---|---|---|
| SECURITY policy file (any; own = 36) | 39 | 39 |
| AGENTS.md at root | 39 | 39 |
| Issue-template `config.yml` | 38 | 38 |
| PR template | 37 | 37 |
| Private vulnerability reporting enabled | 36 | 36 |
| CHANGELOG-type file | 36 | 36 |
| Discord/Slack/Telegram/WeChat link in README | 34 | 34 |
| Blank issues disabled (via config.yml) | 30 | 30 |
| CODE_OF_CONDUCT (any; own = 28) | 29 | 29 |
| README translations (README.xx.md) | 24 | 24 |
| CLAUDE.md at root | 23 | 23 |
| FUNDING.yml (any; own+inherited, 5 inherited) | 22 | 22 |
| Makefile/justfile/Taskfile | 19 | 19 |
| Dependabot or Renovate | 19 | 19 (Dependabot 15, Renovate 5) |
| Dockerfile/compose at root | 18 | 18 |
| ARCHITECTURE doc (file or docs/architecture*) | 17 | 17 |
| CODEOWNERS | 16 | 16 |
| pre-commit / husky / lefthook | 14 | 14 |
| README sponsor link | 13 | 13 |
| .editorconfig | 12 | 12 |
| Legacy `.md` issue templates (YAML forms 42, so forms outnumber legacy about 3:1) | 15 | 15 |
| AI-review bot (strict workflow regex or `.coderabbit.yaml`/greptile/gemini config) | 11 | 11 |
| AI-contribution policy (manually verified) | 11 | 11 |
| Deploy/self-host docs (filename heuristic) | 11 | 11 |
| Other security scanners in workflows (semgrep, trivy, dependency-review, zizmor etc.) | 11 | 11 |
| CodeQL workflow | 10 | 10 |

#### Rare (<10%)

| Practice | n | % |
|---|---|---|
| CLA or DCO (manually verified) | 9 | 9 |
| RFC/spec/PRD/design-doc directory | 8 | 8 |
| devcontainer | 7 | 7 |
| GOVERNANCE | 5 | 5 |
| Stale bot (actions/stale) | 4 | 4 |
| SUPPORT | 4 | 4 |
| ROADMAP | 4 | 4 |
| ADR directory | 4 | 4 |
| MAINTAINERS | 2 | 2 |
| CITATION.cff | 2 | 2 |
| AUTHORS | 1 | 1 |
| OpenSSF Scorecard workflow | 0 | 0 |

#### Details on specific practices

- Inheritance from an org-level `.github` repo is small: 26 of 100 repos have an owner `.github` repo; inherited files filled gaps for only 8 repos (FUNDING 5, SECURITY 3, CODE_OF_CONDUCT 1, CONTRIBUTING 0, PR template 0, SUPPORT 0, GOVERNANCE 0). Issue templates inherited: 0. — [CSV columns `*_inherited`]
- Issue templates: 54 have any; 42 YAML forms, 15 legacy markdown (some have both); 38 have `config.yml`; 30 disable blank issues; 27 have both YAML forms and blank issues disabled.
- SECURITY: 39 have a policy file; 28 of those 39 also have PVR on; 8 repos have PVR on with no SECURITY file; 36 PVR total; 47 have either.
- Releases: 81 have at least one; median release count 24 (mean 91; max 1,747); 63 of the 81 published their latest release within 90 days of 2026-11-18. 73 of 100 repos were pushed within the last 30 days. CHANGELOG-type files exist in 34 of those 81 release-publishing repos (42%).
- Release hygiene: of 80 repos with workflows, 23 pin every external action to a commit SHA, 13 are mixed, 43 use tags/branches only, 1 uses no external actions. So 29% of repos with external actions are fully SHA-pinned (23 of 79). 73 of the 80 workflow repos (91%) declare a `permissions:` block in at least one of the workflows read (up to 8 per repo). 19 repos have a `pull_request_target` trigger in the workflows read.
- Workflows: median 3 across all 100 (mean 7.4, max 41); among the 80 with at least one, median 5. 20 repos had zero workflows and none of the six named external CI configs (CircleCI, Travis, GitLab, Azure, Jenkins, Buildkite); no sampled repo used only an external CI config.
- CodeQL appears in 10 repos (Numbersf/Action-Build, YouPI-PG, mcporter, telemt, file-transfer-go, headroom, kilocode, ruflo, career-ops, open-code-review); 0 Scorecard.
- Contributors (from Link header, `anon=false`): median 16, mean 64.6, max 478; 20 repos have 3 or fewer contributors, 40 have 10 or fewer, 31 have 50 or more.
- README: median 237 lines (mean 333; 26 under 150 lines, 18 at 500+). Of 99 READMEs, 73 have an install/quick-start/usage-type heading (regex on headings). 12 repos' READMEs have no screenshot/GIF/video by the strict regex.
- Open issues + PRs count (GitHub's `open_issues_count` includes PRs): median 39, mean 661, max 27,817.
- Combined bundles: README + detectable license + CONTRIBUTING + CODE_OF_CONDUCT + SECURITY (any) = 20 of 100; the same plus issue templates and PR template (without the license condition) = 19. AGENTS/CLAUDE.md + CONTRIBUTING + CoC + SECURITY + CHANGELOG all together = 7 of 100. Health percentage bands: under 40: 19; 40-59: 31; 60-79: 25; 80-99: 14; exactly 100: 11.

### Inferences

- The tiers show that the first thing young popular repos get right is distribution (license, tags, releases, CI to build/publish), not governance. Community files are present in roughly half, and CODE_OF_CONDUCT/SECURITY/PR template are each in a minority.
- Wiki, Discussions and topics are largely settings defaults or low-effort toggles; their prevalence should not be read as deliberate "practice".
- Supply-chain hardening (SHA pinning 29%, Scorecard 0%, CodeQL 10%, Dependabot/Renovate 19%) lags what the security-advice literature recommends.

### Gaps

- Release automation, CI lint and "AI review" are regex heuristics on up to 8 workflow files per repo (31 repos have more than 8 workflows, so their flags may be under-counted); a workflow matching "release" does not prove it publishes. The strict test regex (53%) and loose (58%) bracket test-in-CI.
- "Deploy/self-host docs" is a file/folder-name heuristic and likely undercounts docs buried in README or a docs site.
- Behaviour behind GitHub settings (branch protection, required reviews, rulesets, secret scanning) is not visible through unauthenticated-as-collaborator GETs and was not measured.

## 2. Differences by owner type, star band, age and category

### Takeaway

Organization-owned repos beat user-owned on almost every governance/process practice (CoC 40% vs 15%, CODEOWNERS 23% vs 9%, CI 89% vs 70%, PVR 43% vs 28%); the top star band (20k+) is clearly more mature (CI 96%, CODEOWNERS 40%, Dependabot 40%, AI review 32%), while repos under one year old differ from older ones mainly in newer agent files and tests-in-CI, not in community files. Category differences are driven by the AI/LLM tooling majority (53 of 100); other categories have n of 4-21 and are indicative only.

### Cited Findings

Selected rows (full tables in [analysis_output.txt](../data/analysis_output.txt)). Org n=53, User n=47; bands n=25 each; age: 1-2 yr (created 2024-11-18..2025-11-17) n=52, under 1 yr (created >= 2025-11-18) n=48.

| Practice | Org | User | 1k-2k | 2k-5k | 5k-20k | 20k+ | 1-2yr | <1yr |
|---|---|---|---|---|---|---|---|---|
| License recognised | 81 | 81 | 76 | 80 | 88 | 80 | 81 | 81 |
| GitHub Releases | 85 | 77 | 80 | 76 | 76 | 92 | 85 | 77 |
| Actions workflows | 89 | 70 | 72 | 72 | 80 | 96 | 79 | 81 |
| Workflow runs tests (strict) | 60 | 45 | 44 | 44 | 48 | 76 | 42 | 65 |
| Release automation (loose) | 77 | 57 | 52 | 64 | 76 | 80 | 69 | 67 |
| Dependabot/Renovate | 26 | 11 | 8 | 12 | 12 | 44 | 21 | 17 |
| CONTRIBUTING | 58 | 43 | 48 | 48 | 52 | 56 | 42 | 60 |
| CODE_OF_CONDUCT | 42 | 15 | 12 | 24 | 44 | 36 | 21 | 38 |
| SECURITY policy (any) | 49 | 28 | 24 | 32 | 44 | 56 | 35 | 44 |
| PVR enabled | 43 | 28 | 24 | 36 | 44 | 40 | 35 | 38 |
| SECURITY or PVR | 58 | 34 | 28 | 40 | 60 | 60 | 46 | 48 |
| Issue templates | 62 | 45 | 48 | 40 | 64 | 64 | 56 | 52 |
| Issue YAML forms | 51 | 32 | 24 | 36 | 52 | 56 | 40 | 44 |
| PR template | 47 | 26 | 28 | 28 | 48 | 44 | 31 | 44 |
| CODEOWNERS | 23 | 9 | 4 | 4 | 16 | 40 | 13 | 19 |
| CHANGELOG file | 42 | 30 | 36 | 40 | 24 | 44 | 38 | 33 |
| Agent file (any kind) | 53 | 45 | 36 | 48 | 48 | 64 | 44 | 54 |
| AGENTS.md or CLAUDE.md at root | 51 | 38 | 28 | 44 | 48 | 60 | 38 | 52 |
| AI-contribution policy | 17 | 4 | 8 | 12 | 12 | 12 | 12 | 10 |
| AI-review bot/config | 15 | 6 | 4 | 0 | 8 | 32 | 13 | 8 |
| CLA/DCO | 15 | 2 | 8 | 8 | 12 | 8 | 8 | 10 |
| Discussions | 62 | 45 | 52 | 44 | 64 | 56 | 60 | 48 |
| Homepage set | 72 | 55 | 40 | 52 | 92 | 72 | 69 | 58 |
| docs/ directory | 68 | 45 | 28 | 64 | 60 | 76 | 56 | 58 |
| Discord/Slack/chat link in README | 38 | 30 | 28 | 28 | 36 | 44 | 44 | 23 |
| README demo media (strict) | 89 | 85 | 88 | 88 | 84 | 88 | 94 | 79 |
| FUNDING.yml | 19 | 26 | 20 | 20 | 24 | 24 | 23 | 21 |
| .gitattributes | 47 | 34 | 28 | 32 | 36 | 68 | 35 | 48 |
| Wiki enabled | 45 | 68 | 56 | 64 | 60 | 44 | 52 | 60 |

Category (selected; n: AI/LLM 53, application 21, developer tool 12, framework/library 4, infrastructure 6, other 4):

| Practice | AI/LLM | app | dev tool | framework | infra | other |
|---|---|---|---|---|---|---|
| Workflows >= 1 | 79 | 81 | 92 | 75 | 100 | 25 |
| CONTRIBUTING | 49 | 57 | 50 | 75 | 67 | 0 |
| SECURITY or PVR | 49 | 38 | 42 | 75 | 83 | 0 |
| Agent file (any) | 60 | 33 | 50 | 25 | 33 | 25 |
| AGENTS.md or CLAUDE.md root | 55 | 29 | 50 | 25 | 33 | 25 |
| AI-contribution policy | 8 | 10 | 17 | 25 | 33 | 0 |
| AI-review bot/config | 19 | 0 | 8 | 0 | 0 | 0 |
| Dependabot/Renovate | 26 | 5 | 25 | 0 | 17 | 0 |
| CODEOWNERS | 26 | 5 | 0 | 0 | 17 | 0 |
| Dockerfile at root | 17 | 14 | 8 | 0 | 83 | 0 |

Source for all: [repo_survey_data.csv](../data/repo_survey_data.csv) via [analysis](../data/repo_survey_analyze.py). Further derived counts: 32 of 53 AI/LLM-tooling repos (60%) have an agent file versus 17 of 47 non-AI repos (36%).

### Inferences

- Owner type matters most for CoC, CODEOWNERS, CLA/DCO, security files and CI; solo/user repos still ship releases (77%) and detectable licenses (81%, identical to orgs) but skip governance files.
- Star band: the 20k+ band is where CI (96%), CODEOWNERS (40%), dependency bots (44%) and AI review bots (32%) jump; below 5k, only 8-12% use Dependabot/Renovate. Lower bands (1k-2k) lag on docs/ (28%) and homepage (40%).
- Age: repos created within the last year more often run tests in CI (65% vs 42%), have CONTRIBUTING (60% vs 42%), CODE_OF_CONDUCT (38% vs 21%), a PR template (44% vs 31%) and agent files (54% vs 44%); the older cohort more often has a README demo (94% vs 79%), chat link (44% vs 23%) and releases (85% vs 77%). Each of these differences is 10-20 points on n of about 50, so only the largest (tests-in-CI, CoC, chat link) are likely real.
- Many of the small categories have n of 4-6 and should not be quoted as rates.

### Gaps

- Category labels are my own single-pass judgments from description and topics; they are in the CSV `category` column but not independently validated.
- Interactions (e.g. org + 20k+ + AI tooling) are confounded; no regression was run.

## 3. Agent-instruction files and AI-contribution policies

### Takeaway

Roughly half (49%) of young popular repos ship an agent-instruction artifact at the root, and 45% ship AGENTS.md and/or CLAUDE.md at the root; but only 11% have an AI-contribution policy or disclosure rule, so agent files are about 4 times as common as policies for human contributors.

### Cited Findings

- Any agent-instruction artifact at root: 49/100. AGENTS.md at root: 39; CLAUDE.md: 23; both: 17; AGENTS only: 22; CLAUDE only: 6; either: 45. AGENTS.md or CLAUDE.md at any depth: 47. 4 repos have agent artifacts but neither file (e.g. only `.claude/`, `.agents/`, `.cursor/`). — [CSV](../data/repo_survey_data.csv)
- Artifact kinds at root (counts; a repo can have several): AGENTS.md 39; CLAUDE.md 23; `.claude/` 20; `.agents/` 20; `.github/copilot-instructions.md` or `.github/instructions|prompts|chatmodes` 7; `.cursor/` rules/commands 5; `.gemini/` 4; `.codex/` 3; `.opencode/` 3; `.cursorrules` 2; `.windsurfrules` 1; `.clinerules` 1; `.kiro/` 1; `GEMINI.md` 1; `openspec/` 1. — [analysis_output.txt](../data/analysis_output.txt)
- Adoption by segment: AI/LLM tooling 60% vs 36% for non-AI repos; org 53% vs user 45%; 20k+ band 64% vs 36% at 1k-2k; under 1 yr old 54% vs 44% older. — [analysis_output.txt](../data/analysis_output.txt)
- Repos with an agent file also more often have CONTRIBUTING (33 of 49 = 67%) than repos without one (18 of 51 = 35%); CI: 45 of 49 (92%) vs 35 of 51 (69%). — [analysis_output.txt](../data/analysis_output.txt)
- AI-contribution policy, manually verified from CONTRIBUTING text, or a dedicated AI policy file/workflow: 11/100. These are: ZhFahim/anchor ("AI tools" section), daeuniverse/honk ("LLM Contribution Policy"), supabitapp/supacode, stickerdaniel/linkedin-mcp-server (disclosure format for agent-authored work), Dispatcharr/Dispatcharr ("On AI-Assisted Code"), pyrefly-org/pyrefly (AI_POLICY.md plus a "human" checkbox in the PR template), zumerlab/snapdom ("Using AI"), telemt/telemt ("AI Usage Policy"), Kilo-Org/kilocode (ownership of AI-assisted work), career-ops-hq/career-ops (rules for unattended coding agents), astral-sh/ty (`ai-policy.yml` workflow). Regex first-pass flagged 17 CONTRIBUTING files with AI-related terms; I read the contexts and discarded 7 (tool mentions or project structure, not policy). — [CSV columns `ai_policy_manual`, `v_contrib_ai_context`](../data/repo_survey_data.csv)
- AI-review bots: 11 repos (strict): workflow-based `claude-code-action`/`@claude` (anthropics/claude-code, ruflo), `openai/codex-action` (openai/codex) plus config files for CodeRabbit (hk, testsprite-cli, MaiBot, ECC, career-ops), Greptile (hk, ECC, paperclip), Gemini Code Assist (airi, A2A). — [CSV `ai_review_strict`, `ai_review_config_file`]
- CLA/DCO: 9/100 manually verified (CLA text in CONTRIBUTING for agent-flow, Lynxe, muse-gadget-sdk, Dispatcharr, pyrefly via a CLA bot, open-code-review; CLA/DCO workflow or config for vAPI-Network, openai/codex, vercel/eve DCO). One regex hit (TestSprite) was a false positive ("No separate CLA is required") and was removed. Two of the 9 (vAPI-Network, openai/codex) were counted from workflow regex hits that I did not read in full. — [CSV `cla_dco_manual`]

### Inferences

- Agent-instruction files have become a mainstream convention in this cohort, led by AGENTS.md (39%) over CLAUDE.md (23%); 17% have both.
- Policies about AI-authored contributions are still rare (11%), and where they exist they cluster in company or well-known maintainer projects with a CONTRIBUTING file.
- Having both AGENTS.md and CLAUDE.md at the root (17%) is a minority but established pattern; 22% have AGENTS.md only and 6% CLAUDE.md only.

### Gaps

- Agent-file detection looks at root and the named dot-directories; nested AGENTS.md/CLAUDE.md in subdirectories counted separately (47 any-depth vs 45 root). The content, quality and whether the files are symlinks was not examined.
- AI-policy detection only reads CONTRIBUTING (own or inherited), dedicated policy files, workflows named `ai-policy`, not README, PR templates or discussion posts, so it may undercount.

## 4. Licenses

### Takeaway

MIT (38) and Apache-2.0 (23) dominate; 19 of 100 have no OSI-style license recognised by GitHub (11 with none, 8 custom/unrecognised); copyleft (GPL/AGPL) is 19.

### Cited Findings

- License SPDX (GitHub): MIT 38; Apache-2.0 23; GPL-3.0 10; AGPL-3.0 8; GPL-2.0 1; BSD-3-Clause 1; NOASSERTION (a license file GitHub does not recognise, mostly custom or source-available) 8; no license 11. — [analysis_output.txt](../data/analysis_output.txt)
- Of the 11 with no license detected, 10 have no LICENSE-type file at all and 1 (anthropics/claude-code) has a LICENSE.md with proprietary text. The 8 NOASSERTION repos: Action-Build, Hephaestus, supacode, mango, visa-vulnerability-agentic-harness, telemt, dsh-our-free-model, paseo. — [CSV `license_spdx`, `license_file_path`]
- No-license repos include high-star ones: anthropics/claude-code (156k stars), dsh-our-free-model (80k), virattt/dexter (28k), gpu-unlock (20k), getpaseo/paseo (24k, NOASSERTION). — [CSV]
- Permissive (MIT, Apache, BSD) = 62; copyleft (GPL, AGPL) = 19. Org-owned and user-owned repos both have 81% recognised licenses. — [CSV]

### Inferences

- Roughly 1 in 5 young popular repos has no clear open-source license despite 1,000+ stars; "MIT + Apache" covers about 3 of 5 repos.

### Gaps

- License classification relies on GitHub's detector; custom licenses are not further categorised.

## 5. Surprising absences among popular repos

### Takeaway

Missing basics are not confined to small repos: 11 of 25 repos at 20k+ stars lack CONTRIBUTING, 10 of 25 lack both a SECURITY policy and PVR, 5 of 25 have no recognised license, while 20 of 100 repos run no CI at all (1 of those at 20k+).

### Cited Findings

- No CONTRIBUTING (own or inherited): 49 of 100, including 11 of the 25 repos at 20k+ stars (e.g. anthropics/claude-code 156k, openai/codex-plugin-cc 35k, openai/gpt-oss 20k, huggingface/open-r1 26k, steipete/CodexBar 23k, virattt/dexter 28k, vercel-labs/skills 40k, ATH-MaaS/Pixelle-Video 30k, firecrawl/anydoc 24k). — [CSV]
- No SECURITY policy and no PVR: 53 of 100 (so 47 have at least one); at 20k+ stars, 10 of 25 have neither (including openai/codex-plugin-cc, openai/gpt-oss, huggingface/open-r1, baidu/Unlimited-OCR, vercel-labs/skills). In the 20k+ band, 5 of 25 have no OSI-style license detected. — [CSV]
- No CI at all (no Actions workflow, no other CI config): 20 of 100; only 1 of the 25 repos at 20k+ stars (baidu/Unlimited-OCR, 31k), but 5 of 25 at 5k-20k including iflow-ai/iflow-cli and bytedance/LatentSync (see CSV for the full list). — [CSV `n_workflows`, `other_ci`]
- No GitHub Release: 19 of 100 (2 of 25 at 20k+: huggingface/open-r1 26k, baidu/Unlimited-OCR 31k), also bytedance/LatentSync (6k), iflow-cli (5k). — [CSV]
- 10 tests directories exist without CI; 16 repos run CI but have no recognisable test directory or test files. — [analysis_output.txt]
- 16 of the 80 workflow repos show neither a test/build nor a lint/typecheck pattern in the workflows read; 19 of 100 have community health under 40% (minimum 14%). — [analysis_output.txt]
- The Scorecard workflow appeared in 0 repos, ADR in 4, RFC/spec/PRD directory in 8, ROADMAP in 4, MAINTAINERS in 2, even among 20k+ repos (ROADMAP 4, ADR 3, MAINTAINERS 2 of 25). — [analysis_output.txt]

### Inferences

- High star counts do not imply governance hygiene; many viral repos (leaked-tools, model drops, one-person tools) are published as code drops with little scaffolding.
- Only 7 of 100 repos have the combination of agent file + CONTRIBUTING + CODE_OF_CONDUCT + SECURITY + CHANGELOG.

### Gaps

- Not checked: whether absent files exist in a linked docs site or wiki. "No CI" counts only Actions and 6 named external CI configs (CircleCI, Travis, GitLab, Azure, Jenkins, Buildkite); others (e.g. external Jenkins not configured in repo) are invisible.

## 6. Relevance to a brand-new, documentation-only solo repo, and limitations

### Takeaway

Relative to this cohort, a repo that starts with README, LICENSE, CONTRIBUTING, CODE_OF_CONDUCT, SECURITY with PVR, CHANGELOG, YAML issue forms, PR template, CODEOWNERS, AGENTS.md + CLAUDE.md, .editorconfig and .gitattributes already exceeds almost all the sampled repos on community files (only 11 of 100 reach 100% community health and 7 of 100 have the five-file bundle above); what it lacks, CI, dependency updates and releases, are the practices the cohort does have (CI 80%, releases 81%, tags 84%), though the cohort's own supply-chain practices are weak.

### Cited Findings

- Practices in the comparison repo versus this cohort: README 99%, license 81% (detected), CONTRIBUTING 51%, CODE_OF_CONDUCT 29%, SECURITY 39% + PVR 36%, CHANGELOG 36%, YAML issue forms 42%, PR template 37%, CODEOWNERS 16%, AGENTS.md 39% / CLAUDE.md 23% / both 17%, .editorconfig 12%, .gitattributes 41%, AUTHORS 1%. — [CSV]
- Practices the comparison repo lacks: GitHub Actions workflows 80%, tests in CI 53%, Dependabot/Renovate 19%, GitHub Releases 81%, semver tags 71%. — [CSV]
- Practices neither has that the cohort mostly skips: SHA-pinning (29% of repos with external actions), Scorecard (0%), CodeQL (10%), AI-contribution policy (11%), ADR (4%), RFC/spec/PRD directory (8%), GOVERNANCE (5%), ROADMAP (4%), MAINTAINERS (2%), SUPPORT (4%), CLA/DCO (9%).
- A PRD/spec docs directory is present in only 8 of 100 repos (RFC/spec/PRD/design-doc heuristic: `docs/`-`rfcs/specs/prd/design` or `openspec/` and `.specify/`).

### Inferences

- A solo maintainer repo with these community files is already above the typical young popular repo on documentation; adding CI, tags/releases and a dependency bot would close the gap on the practices that the cohort actually leads with.
- The cohort offers little evidence that ADR/RFC/ROADMAP/GOVERNANCE/MAINTAINERS are needed to get to 1,000+ stars; they are minority or rare even at 20k+ stars (ROADMAP 16%, ADR 12%, GOVERNANCE 12%, MAINTAINERS 8% in that band).

### Gaps (limitations, stated plainly)

- Survivorship: these are repos that already crossed 1,000 stars in under two years. Practices of repos that never got popular are not measured, so nothing here shows that a practice caused popularity.
- Skew: 53% are AI/LLM tooling; the cohort leans toward company-backed or viral projects, includes many Chinese-language repos, and star counts may be inflated for some (no check made for star manipulation). The sampling frame is search results sorted by stars within bands and creation windows; random pages within a cell are not a uniformly random draw from all matching repos (see Section 1 gaps).
- n=100: margins of roughly +/-10 points; segments of 25 have wider margins and small categories (n=4-6) are anecdotal.
- Unobservable settings: branch protection, rulesets, required reviews, secret scanning, Dependabot alerts (security updates without a yml), code scanning default setup (CodeQL can be enabled without a workflow file, so the 10% CodeQL figure is a floor), repo-level CLA apps and GitHub Apps (e.g. CodeRabbit installed without a config file), org-level required workflows, discussions categories.
- Heuristics: release automation (loose regex), lint-in-CI (loose regex), tests-in-CI (strict test-command regex, only first 8 workflows read), README install section (heading regex), README demo media (strict regex after excluding badge-like images; may count logos), chat-link (domain regex), deploy docs (filename heuristic), SHA-pinning (up to 8 workflows), agent files (path patterns), architecture/ADR/RFC (path patterns). Manual review applied only to the AI-policy hits and CLA/DCO hits. Regex hits for AI review in workflows were reduced to a strict list; two CLA/DCO workflow hits (vAPI-Network, openai/codex) were not read manually.
- `open_issues_count` includes PRs. Contributors endpoint excludes anonymous contributors and is a lower-bound for commit authors; contributor count for repos with squash-merged bot commits may be off.
- Singular snapshot: figures are a single day; many young repos change quickly (e.g. agent files added within weeks).
- The README of the repo, the community-profile endpoint's own file detection (health %) and my own tree-based detection can disagree (e.g. astral-sh/ty has issue forms in tree but community profile reports no issue template); I report tree-based detection for presence and the API's health percentage as-is.
