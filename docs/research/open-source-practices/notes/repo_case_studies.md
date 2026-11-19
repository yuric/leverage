# Qualitative case studies of 14 young GitHub repos: what they did on day one vs later

"I" in this note is the AI research agent that wrote the case studies (the report's "survey's author"). Corrections made after an adversarial review on 2026-11-19 are marked "(corrected after review)".

Method: GitHub REST API via `gh` (GET only), run 2026-11-18. Repos picked from `search/repositories` with `created:>=2024-11-18 stars:>1000 fork:false archived:false`, deliberately sampling both the top of the list and the 4,000-5,000 star band. Every repo's `created_at` and `stargazers_count` was read from `repos/{o}/{r}`. "Days" below = days between `created_at` and the first commit touching that path (`commits?path=...`, last page). "Never" = no commit touched any of the candidate paths I probed (list in Limitations); it does not prove the file never existed under another name. Files were read via `contents` raw. Source URLs use `https://github.com/{owner}/{repo}/blob/HEAD/{path}` (current HEAD content, not day-one content, unless I say "first commit").

Sample (all verified created >= 2024-11-18 and > 1,000 stars):

| Repo | created_at | Stars | Owner type | License | Lang | Contributors (API, incl. bots) | Commits |
|---|---|---|---|---|---|---|---|
| [ChromeDevTools/chrome-devtools-mcp](https://github.com/ChromeDevTools/chrome-devtools-mcp) | 2025-09-11 | 58,198 | Org (Google) | Apache-2.0 | TS | 172 | 1,635 |
| [Fission-AI/OpenSpec](https://github.com/Fission-AI/OpenSpec) | 2025-08-05 | 75,179 | Org (small team) | MIT | TS | 149 | 1,053 |
| [github/spec-kit](https://github.com/github/spec-kit) | 2025-08-21 | 150,473 | Org (GitHub) | MIT | Python | 342 | 2,469 |
| [docker/docker-agent](https://github.com/docker/docker-agent) | 2025-09-01 | 4,692 | Org (Docker) | Apache-2.0 | Go | 135 | 11,706 |
| [cloudflare/kumo](https://github.com/cloudflare/kumo) | 2025-10-30 | 4,245 | Org (Cloudflare) | MIT | TS | 72 | 678 |
| [basicmachines-co/basic-memory](https://github.com/basicmachines-co/basic-memory) | 2024-12-02 | 4,624 | Org (small company) | AGPL-3.0 | Python | 58 | 2,606 |
| [donutbrowser/donutbrowser](https://github.com/donutbrowser/donutbrowser) | 2025-05-29 | 4,335 | Org (near-solo, 14 contribs) | AGPL-3.0 | Rust | 14 | 2,035 |
| [tw93/Mole](https://github.com/tw93/Mole) | 2025-09-23 | 75,506 | User | GPL-3.0 | Shell | 179 | 4,290 |
| [crmne/ruby_llm](https://github.com/crmne/ruby_llm) | 2025-01-30 | 4,517 | User | MIT | Ruby | 155 | 2,496 |
| [bjarneo/cliamp](https://github.com/bjarneo/cliamp) | 2026-02-24 | 4,657 | User | MIT | Go | 131 | 1,818 |
| [robinebers/openusage](https://github.com/robinebers/openusage) | 2026-02-01 | 4,605 | User | MIT | Swift | 23 | 898 |
| [kunchenguid/gnhf](https://github.com/kunchenguid/gnhf) | 2026-03-31 | 4,282 | User | MIT | TS | 23 | 165 |
| [p2r3/convert](https://github.com/p2r3/convert) | 2025-12-07 | 4,228 | User | GPL-2.0 | TS | 71 | 924 |
| [Pimzino/spec-workflow-mcp](https://github.com/Pimzino/spec-workflow-mcp) | 2025-08-07 | 4,306 | User | GPL-3.0 | TS | 19 | 425 |

Owner type counts: 7 individual-user-owned (Mole, ruby_llm, cliamp, openusage, gnhf, convert, spec-workflow-mcp); 7 org-owned, of which 4 are big-company-backed (Chrome DevTools/Google, spec-kit/GitHub, docker-agent/Docker, kumo/Cloudflare) and 3 are small-team orgs (OpenSpec, basic-memory, donutbrowser). Licenses: MIT x7 (OpenSpec, spec-kit, kumo, ruby_llm, cliamp, openusage, gnhf), Apache-2.0 x2 (chrome-devtools-mcp, docker-agent), AGPL-3.0 x2 (basic-memory, donutbrowser), GPL-3.0 x2 (Mole, spec-workflow-mcp), GPL-2.0 x1 (convert). Categories: agent tooling/spec tooling (OpenSpec, spec-kit, spec-workflow-mcp, chrome-devtools-mcp, gnhf, docker-agent, basic-memory), library/framework (ruby_llm, kumo), end-user apps (cliamp, openusage, Mole, donutbrowser, convert). Grew-from-small examples: ruby_llm, cliamp, gnhf, convert, Mole, spec-workflow-mcp, donutbrowser (all started as one-person code dumps).

---

## 1. What did each repo contain on day one (code-first, docs-first, spec-first)?

### Takeaway

Twelve of 14 started code-first; the two exceptions are OpenSpec (spec-first, by design of the product) and spec-kit (README-only commit, then full toolkit + design doc next day). No repo started with a PRD-style requirements doc before code except OpenSpec, whose first commits are the `openspec/` structure and a change proposal. Several "first commits" are distorted by history imports/squashes (kumo, openusage, docker-agent), so day-one comparisons for those are weak.

### Cited Findings

- chrome-devtools-mcp: first commit "feat: initial version" (2025-09-11) already contained LICENSE, README, CONTRIBUTING.md, SECURITY.md, `.github/ISSUE_TEMPLATE`, `.github/workflows`, docs/tool-reference.md, src/ and tests/ (80 files). Three more commits the same morning set up CI, release-please and a "conventional commits" doc. Its README said "This is an early experimental prototype!" on day one. — [first-commit README via API](https://github.com/ChromeDevTools/chrome-devtools-mcp/blob/HEAD/README.md), [commit list](https://github.com/ChromeDevTools/chrome-devtools-mcp/commits/main)
- OpenSpec: first commit "chore: initialize openspec project structure" had only `.gitignore` and `openspec/README.md`; second "docs: add openspec project overview"; third "feat: add typescript initialization change proposal"; code ("initialize typescript project with esm support") only came in the fourth commit, same day. The project used its own spec-first workflow to bootstrap itself. — [commits](https://github.com/Fission-AI/OpenSpec/commits/main) (earliest four read from API)
- spec-kit: first commit (2025-08-21) = LICENSE + empty README + .gitignore (3 files); the next day's "Initial checkin" added `spec-driven.md` (the methodology doc), `memory/constitution.md`, templates (`spec-template.md`, `plan-template.md`, `tasks-template.md`), shell scripts, `src/specify_cli`, `pyproject.toml`, and a workflow. So spec doc and code landed together; there was no separate PRD phase. — [spec-driven.md](https://github.com/github/spec-kit/blob/HEAD/spec-driven.md)
- basic-memory: first commit "Initial commit" = .gitignore, LICENSE, a one-line README (`# basic-memory`); code started 13 minutes later ("Initial project structure"). — [README](https://github.com/basicmachines-co/basic-memory/blob/HEAD/README.md)
- donutbrowser: "init" (2025-05-29) = 181 files (Next.js + Tauri app, LICENSE, workflows, dependabot); day-one README was literally "# Donut Browser / TODO". — [repo](https://github.com/donutbrowser/donutbrowser)
- Mole: "Initial commit: Clean Mac v1.0.0" = `clean.sh`, `install.sh`, Homebrew `Formula`, LICENSE, README (7 files, one of them a stray `.DS_Store`). — [repo](https://github.com/tw93/Mole)
- ruby_llm: "Initial commit" (2025-01-30 08:57) -> a gem-push workflow 5 minutes later -> version bump to `0.1.0.pre` in the first 12 minutes. First tree: README.md, lib/, ruby_llm.gemspec. — [repo](https://github.com/crmne/ruby_llm)
- cliamp: first commit "Initial cliamp" had main.go, go.mod, player/, playlist/, ui/, README (17 files); "Add release flow" and v1.0.0 followed next day. No LICENSE until day 10 ("Add MIT"). — [repo](https://github.com/bjarneo/cliamp)
- gnhf: first commit "feat: initial commit" (2026-03-30 23:51) carried LICENSE, README, CI, release-please config and manifest, ESLint/Prettier, BACKLOG.md and src (58 files); first release-please PR merged the next evening. — [repo](https://github.com/kunchenguid/gnhf)
- convert (p2r3): "initial commit - minimum viable application" = 8 files (handlers/, index.html, main.js, package.json, style.css). No README until day 49, no LICENSE until day 60. — [repo](https://github.com/p2r3/convert)
- spec-workflow-mcp: first commit titled "## [0.0.1] - 2025-08-07" (a CHANGELOG-style message) with 79 files incl. LICENSE, README, CHANGELOG.md, issue templates, src. Within an hour, three commits reworked README video links. — [repo](https://github.com/Pimzino/spec-workflow-mcp)
- History distortion cases: (a) kumo `created_at` 2025-10-30 but earliest visible commit is 2026-01-30 "Initial commit" containing 562 files incl. AGENTS.md and `GITHUB_MIGRATION_PLAN.md`, i.e. the repo was apparently developed elsewhere first (the file name suggests a migration; the origin is unverified). (b) openusage `created_at` 2026-02-01 and releases from `v0.0.1` on 2026-02-01, but the earliest commit is 2026-06-15 "OpenUsage — native Swift edition" with 252 files, i.e. history was reset/rewritten for a rewrite; all its files show "+134 days". (c) docker-agent `created_at` 2025-09-01 but earliest commit is 2025-05-06 ("cagent", README titled `# cagent`) so the repo existed or was imported earlier; first release v0.5.0 is dated the creation day. — [kumo](https://github.com/cloudflare/kumo), [openusage](https://github.com/robinebers/openusage), [docker-agent](https://github.com/docker/docker-agent)

### Inferences

- "Docs-first" in the PRD sense is rare in successful young repos; the exception (OpenSpec) is a spec-tool dogfooding itself. For a requirements-first solo repo the closest precedent is OpenSpec's three-commit sequence (structure, overview, change proposal) before code.
- The ratio of "all the hygiene files in commit one" is highest for Google/Docker-style corporate launches (chrome-devtools-mcp) and for solo devs who use a template or agent (gnhf, donutbrowser); the quick-and-dirty solo launches (convert, cliamp, Mole) added hygiene weeks to months later.

### Gaps

- Stargazer timestamps: the `stargazers` endpoint returned HTTP 404 in this environment (tried with and without the star+json Accept header), so I could not reconstruct star counts at age N days. Adoption below is therefore expressed in days and current stars only, not "stars at adoption time".
- Whether kumo, openusage and docker-agent were private/older before their visible first commit was not verified beyond the commit/created_at mismatch.

---

## 2. Adoption timeline: days after `created_at` that each file first appeared

Legend: 0 = in first commit/same day; "n" = never found; * = history distorted (see Q1); (c) = counted from earliest visible commit because it postdates created_at.

| Practice | chrome-devtools-mcp | OpenSpec | spec-kit | docker-agent* | kumo*(c) | basic-memory | donutbrowser | Mole | ruby_llm | cliamp | openusage* | gnhf | convert | spec-workflow-mcp |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| LICENSE | 0 | 32 | 0 | -45 | 4 | 0 | 0 | 0 | 7 | 10 | * | 0 | 60 | 0 |
| README (first) | 0 | 8 (root; spec README at 0) | 0 (empty; real at 1) | -118 | 0 | 0 (one line) | 0 ("TODO") | 0 | 0 | 0 | * | 0 | 49 | 0 |
| CONTRIBUTING | 0 | 400 | 1 | 0 (docs/) | 20 | 64 | 1 | 19 | 51 | n | * | 22 | n (README section) | n |
| CODE_OF_CONDUCT | n (links Google's) | n | 1 | n | n | 64 | 1 | n | n | n | * | n | n | n |
| SECURITY | 0 | 351 | 1 | 3-7 | n | 100 | 5 | 168 | n | n | * | n | 340 | n |
| Issue templates | 0 | 420 (forms) | 183 | -4 | n | 89 | 1 | 73 | 126 | 70 | * | 6 | 72 | 0 |
| PR template | n | 420 | 182 | n | 60 | n | 1 | 168 | 126 | 70 | * | n | n | n |
| CODEOWNERS | n | 45 | 1 | 3 | n | n | n | 168 | n | n | * | n | n | n |
| CI workflow | 0 | 32 | 1 | -89 | 10 | 64 | 0 | 0 | 0 (gem-push) | 1 | * | 0 | 48 | 31 (Claude review bot) |
| First release/tag | 5 (v0.1.0) | 32 (v0.1.0) | 1 (v0.0.1) | 0 (v0.5.0) | 11 (1.3.0) | 67 (v0.1.0) | 0 (alpha tag) | 5 (V1.2.0) | 27 (0.1.0.pre42) | 1 (v1.0.0) | 0 (v0.0.1) | 0 (0.1.1) | 99 (rolling `latest`) | none via API |
| Release automation | release-please d0 | changesets d31 | workflows d1 | n/a | changesets d6(c) | release.yml d64 | release.yml | release workflow d0 | gem on GitHub release | release.yml d1 | release workflow | release-please d0 | none | npm-publish.yml |
| CHANGELOG | 4 | 32 | 25 | 143 | n | 64 | 299 | n | n (release-notes.md at root) | n | * | 0 | n | 0 |
| Dependabot/Renovate | 0 | 351 | 181 | 374 | n | 103 | 0 | 97 | 634 (Renovate) | n | * | n | n | n |
| Agent files | GEMINI.md d123, AGENTS.md d223 | .cursor/rules d22, AGENTS.md d31 | AGENTS.md d30 | CLAUDE.md before creation, AGENTS.md d46 | AGENTS.md at first visible commit | CLAUDE.md d88, .claude d183, AGENTS.md d427 | .cursor/rules d8, AGENTS.md d57, CLAUDE.md d221 | CLAUDE.md/GEMINI.md/copilot-instructions d80, AGENTS.md d104 | AGENTS.md+CLAUDE.md d566, copilot-instructions d581 | CLAUDE.md d54, AGENTS.md (symlink) d121 | * (present) | AGENTS.md+CLAUDE.md d17 | AGENTS.md d306 | n |
| MAINTAINERS/GOVERNANCE | n | MAINTAINERS 162 | n (SUPPORT.md at HEAD) | n | n | n | n | n | n | n | n | n | n | n |
| ARCHITECTURE/ADR | n | docs only | design/ dir (HEAD) | n | n | docs/ARCHITECTURE.md d398; specs/ d294 | n | n | n (Archspec.rb) | architecture map inside CLAUDE.md | n | VISION.md (date not fetched) | n | n |
| FUNDING | n | n | n | n | n | n | n | 10 | 61 | n | n | n | n | n (README "Support") |
| CLA/DCO | Google CLA (in CONTRIBUTING d0) | n | n | n | n | CLA.md 89 | CONTRIBUTOR_LICENSE_AGREEMENT.md at HEAD | n | n | n | n | n | n | n |
| ROADMAP | n | n | n | n | n | n | n | n | n | n | n | BACKLOG.md in first commit | n | n |

All values from `commits?path=` first-commit dates vs `created_at`; sources: [chrome-devtools-mcp](https://github.com/ChromeDevTools/chrome-devtools-mcp), [OpenSpec](https://github.com/Fission-AI/OpenSpec), [spec-kit](https://github.com/github/spec-kit), [docker-agent](https://github.com/docker/docker-agent), [kumo](https://github.com/cloudflare/kumo), [basic-memory](https://github.com/basicmachines-co/basic-memory), [donutbrowser](https://github.com/donutbrowser/donutbrowser), [Mole](https://github.com/tw93/Mole), [ruby_llm](https://github.com/crmne/ruby_llm), [cliamp](https://github.com/bjarneo/cliamp), [openusage](https://github.com/robinebers/openusage), [gnhf](https://github.com/kunchenguid/gnhf), [convert](https://github.com/p2r3/convert), [spec-workflow-mcp](https://github.com/Pimzino/spec-workflow-mcp).

### Takeaway

In the first week most repos had LICENSE (10 of 13 countable), a README, and some CI or release plumbing (8 of 14), but only 4 of 14 had CONTRIBUTING and few had SECURITY, issue templates or agent files that early. Templates, SECURITY, CODEOWNERS, Dependabot and AGENTS.md mostly arrived between day 30 and day 400, usually triggered by traction, security-conscious users, or the maintainer starting to use agents. CODE_OF_CONDUCT, CODEOWNERS, FUNDING, GOVERNANCE, ROADMAP and ADR files were mostly never adopted.

### Cited Findings

- Day-one (within 1 day) hygiene bundles: chrome-devtools-mcp (LICENSE, README, CONTRIBUTING, SECURITY, issue templates, CI, dependabot, release-please by day 0); spec-kit (CONTRIBUTING, CODE_OF_CONDUCT, SECURITY, CODEOWNERS, CI by day 1 in one "Update with required files" commit); donutbrowser (CONTRIBUTING, CODE_OF_CONDUCT, issue and PR templates day 1 in "chore: add readme and other paperwork"). — [spec-kit commits](https://github.com/github/spec-kit/commits/main), [donutbrowser commits](https://github.com/donutbrowser/donutbrowser/commits/main)
- Late-adopted: OpenSpec added CONTRIBUTING at day 400 ("docs: add CONTRIBUTING.md (#1781)"), SECURITY + dependabot at day 351 (one commit "chore(security): add security policy, dependa..."), issue forms and PR template at day 420. — [OpenSpec CONTRIBUTING](https://github.com/Fission-AI/OpenSpec/blob/HEAD/CONTRIBUTING.md)
- Mole added SECURITY.md, PR template and CODEOWNERS together on day 168 in a commit titled "docs: strengthen public security signals", a deliberate hygiene pass. — [Mole SECURITY](https://github.com/tw93/Mole/blob/HEAD/SECURITY.md)
- spec-kit's issue templates (day 183), PR template (182), dependabot (181) and stale workflow (174) all arrived within ~10 days of each other in Feb 2026, six months in, despite day-one CONTRIBUTING/SECURITY/CODEOWNERS. — [spec-kit templates](https://github.com/github/spec-kit/tree/HEAD/.github/ISSUE_TEMPLATE)
- Agent-instruction files nearly always came after launch, not at it: earliest are docker-agent CLAUDE.md (before the visible creation date), cloudflare/kumo AGENTS.md (first visible commit), donutbrowser `.cursor/rules` day 8 (corrected after review: earlier omitted), gnhf day 17, OpenSpec .cursor/rules day 22 / AGENTS.md day 31, basic-memory CLAUDE.md day 88; latest are ruby_llm day 566 and chrome-devtools-mcp day 223 (GEMINI.md day 123). Several migrated names: chrome-devtools-mcp "move agent rules to AGENTS.md" (2026-04-22), cliamp "docs: symlink AGENTS.md to CLAUDE.md", donut "chore: rename agents file".
- Releases: 8 of 14 had a tagged release within 5 days of creation (chrome, spec-kit, docker-agent, donut, Mole, cliamp, openusage, gnhf; kumo within 11 days of its visible start); slowest are basic-memory (67d), OpenSpec (32d), ruby_llm (27d) and convert (no semver release; one rolling `latest` release created day 99 plus a `prebuilts` release). spec-workflow-mcp returned no GitHub releases through the API (releases via npm may exist; unverified).
- CODE_OF_CONDUCT: present in only 4 of 14 (spec-kit, basic-memory, donut, openusage; chrome-devtools-mcp links Google's guidelines instead); CODEOWNERS present in 5 of 14 (OpenSpec, spec-kit, docker-agent, Mole, openusage); FUNDING.yml in 2 (Mole day 10, ruby_llm day 61); MAINTAINERS.md in 1 (OpenSpec, day 162). No repo had GOVERNANCE.md or a ROADMAP.md (gnhf has BACKLOG.md and VISION.md at root). — verified from root listings via `repos/{r}/contents/`.
- Community-profile "health" scores (API) range 42 (spec-workflow-mcp) to 100 (spec-kit, basic-memory, openusage); this is the GitHub checker's measure, not a quality judgement. — [community profile API](https://docs.github.com/en/rest/metrics/community)

### Inferences

- Hygiene files cluster in two moments: launch day (for teams that copy a template/checklist or have an OSS office) and a "we got popular and spammy / security-conscious" pass in months 2-6 (Mole d168, spec-kit d174-183, OpenSpec d351-420).
- AGENTS.md became a post-launch artifact because most were created after maintainers started using agents heavily; a repo that is agent-built from day one should have it on day one (none of these did, but gnhf got there at day 17 and kumo's appears in the first visible commit).

### Gaps

- No star-count-at-adoption data (see Q1 gaps). Only "current stars" are known, so statements like "after traction" are by age, not by star threshold.
- I did not check `.github/workflows` first-commit dates for every repo separately from the directory; for repos where the history was reset (openusage) all dates are meaningless.

---

## 3. Content quality and style: README, CONTRIBUTING, SECURITY, AGENTS.md, AI policy

### Takeaway

The best-liked files are specific, short and opinionated rather than boilerplate. Contribution policies have hardened sharply toward gating (issue-first, invitation-only PRs, mandatory AI disclosure, auto-closing bots). AGENTS.md files are build/test/guardrail manuals, with an "AGENTS.md is canonical, CLAUDE.md just points to it" pattern.

### Cited Findings

README openings (first sentences):

- docker-agent: "Build, run, and share AI agents with a declarative YAML config, rich tool ecosystem, and multi-agent orchestration." then a demo GIF and a YAML example in the first screen. — [README](https://github.com/docker/docker-agent/blob/HEAD/README.md)
- openusage: "Track your AI coding subscriptions from the macOS menu bar." followed by a light/dark screenshot table, install via Homebrew. — [README](https://github.com/robinebers/openusage/blob/HEAD/README.md)
- convert: "**Truly universal online file converter.**" then a contrarian pitch (other converters are "boring and insecure") and numbered usage steps. — [README](https://github.com/p2r3/convert/blob/HEAD/README.md)
- Mole: "Deep clean, uninstall, optimize, analyze disk and monitor your Mac." plus an honest scope note that the repo is the free CLI and a separate app exists. — [README](https://github.com/tw93/Mole/blob/HEAD/README.md)
- ruby_llm opens with a 5-line code sample and "Build AI features the Ruby way..."; a later README section titled "23 providers. One API." — [README](https://github.com/crmne/ruby_llm/blob/HEAD/README.md)
- OpenSpec opens with a philosophy list ("fluid not rigid / iterative not waterfall / easy not complex..."), spec-kit with a table "Choose your process" mapping needs to outcomes, chrome-devtools-mcp with what it lets an agent do plus a link bar to Tool reference, CLI, Skills, Contributing, Design Principles. — [OpenSpec README](https://github.com/Fission-AI/OpenSpec/blob/HEAD/README.md), [spec-kit README](https://github.com/github/spec-kit/blob/HEAD/README.md), [chrome README](https://github.com/ChromeDevTools/chrome-devtools-mcp/blob/HEAD/README.md)
- Day-one READMEs were mostly thin: chrome-devtools-mcp 176 lines with an "early experimental prototype" disclaimer; cliamp 58 lines with an ASCII mock of the UI; kumo 83 lines (Installation/Usage); ruby_llm 190 lines; basic-memory, spec-kit, donutbrowser effectively empty ("TODO").
- spec-workflow-mcp's HEAD README begins with a notice that the maintainer is on a break ("I HAVE TAKEN A SMALL BREAK FROM THIS REPO..."), i.e. a status banner instead of a governance doc. — [README](https://github.com/Pimzino/spec-workflow-mcp/blob/HEAD/README.md)

CONTRIBUTING (what's specific, what gates):

- OpenSpec (issue-first, PRs by invitation): "Every contribution starts with a GitHub issue." and "Opening pull requests is limited to maintainers, so wait for an invitation on the issue before you start one." Maintainers add an `approved` label; features need two PRs (proposal in `openspec/changes/<name>/`, then implementation). It also says "If an agent drafts the issue, read it through and make it yours." — [CONTRIBUTING](https://github.com/Fission-AI/OpenSpec/blob/HEAD/CONTRIBUTING.md)
- openusage: "By design, most external pull requests are closed" and PRs must link an issue "labeled `approved`" and assigned to the PR author, else automation closes them; also "No AI-generated commit messages." Added a >1,000-line warning bot. — [CONTRIBUTING](https://github.com/robinebers/openusage/blob/HEAD/CONTRIBUTING.md), [pr-policy workflow](https://github.com/robinebers/openusage/tree/HEAD/.github/workflows)
- ruby_llm states what it will NOT accept: "Features we'll reject" lists anything buildable "in a few lines of application code", workflow DSLs, vector DB integrations, testing frameworks; steers new providers to community gems. — [CONTRIBUTING](https://github.com/crmne/ruby_llm/blob/HEAD/CONTRIBUTING.md)
- gnhf: "Human-authored pull requests targeting `main` must be raised through `no-mistakes`", a local gate that runs an AI review/test/lint pipeline and forwards the push; a CI check "PR must be raised via no-mistakes" enforces it. — [CONTRIBUTING](https://github.com/kunchenguid/gnhf/blob/HEAD/CONTRIBUTING.md)
- chrome-devtools-mcp: Google CLA, conventional commits for PR titles (enforced by a `conventional-commit.yml` workflow), and a "Feature release checklist" (`chore:` for incomplete features, then a `feat:` PR enabling it once docs are updated). — [CONTRIBUTING](https://github.com/ChromeDevTools/chrome-devtools-mcp/blob/HEAD/CONTRIBUTING.md)
- Mole: no process prose, mostly code-style rules ("Always use safe wrappers, never `rm -rf` directly"). Basic-memory, kumo, spec-kit have 280-519 line how-to guides (spec-kit's has a branch naming section, a review rubric scored 0-2 on 7 dimensions, and an "evidence gate": "A contribution is evaluated on the evidence it carries"). — [Mole CONTRIBUTING](https://github.com/tw93/Mole/blob/HEAD/CONTRIBUTING.md), [spec-kit CONTRIBUTING](https://github.com/github/spec-kit/blob/HEAD/CONTRIBUTING.md)
- donutbrowser: "Don't open a PR just to get added to the contributors list." and a CLA file for relicensing/dual licensing. — [CONTRIBUTING](https://github.com/donutbrowser/donutbrowser/blob/HEAD/CONTRIBUTING.md)
- convert has no CONTRIBUTING.md; its README "Contributing" section teaches how to write a format handler with a code stub and gives rules ("Please do not use CDNs"). — [README](https://github.com/p2r3/convert/blob/HEAD/README.md)

SECURITY:

- OpenSpec: private reporting via GitHub Security Advisories; "We aim to acknowledge within 3 business days and to ship a fix or a decision within 30 days"; only the latest npm version is supported; includes an in-scope vs out-of-scope table and a threat model for a local CLI. — [SECURITY](https://github.com/Fission-AI/OpenSpec/blob/HEAD/SECURITY.md)
- openusage: GitHub Security Advisories preferred, email fallback, "Acknowledgment within 48 hours", "Assessment and plan within 7 days". — [SECURITY](https://github.com/robinebers/openusage/blob/HEAD/SECURITY.md)
- docker-agent: private email, 72-hour acknowledgement, a "Review Process" describing a draft GitHub advisory under embargo. basic-memory: email and "respond within 72 hours", supported versions "0.x.x", plus a threat model. Mole: "acknowledge ... within 7 calendar days", status update within 30 days, GitHub private reporting only "if ... enabled". — [docker-agent](https://github.com/docker/docker-agent/blob/HEAD/SECURITY.md), [basic-memory](https://github.com/basicmachines-co/basic-memory/blob/HEAD/SECURITY.md), [Mole](https://github.com/tw93/Mole/blob/HEAD/SECURITY.md)
- chrome-devtools-mcp: routes to Google's VRP and spends most of the file on scope ("the AI agent or client using this MCP server validates any input") and a "Trusted host environment" section listing what it does not treat as vulnerabilities. spec-kit: GitHub's standard org-wide email text. — [chrome SECURITY](https://github.com/ChromeDevTools/chrome-devtools-mcp/blob/HEAD/SECURITY.md)
- donutbrowser: an "AI-Assisted Reports" section: "An unverified model-written report is not a security report; it will be closed without analysis." and "Say in your email whether AI was involved." — [SECURITY](https://github.com/donutbrowser/donutbrowser/blob/HEAD/SECURITY.md)
- convert: 11 lines, "Due of the nature of this project (browser + client side only), it is unusual for any security issues to be of any importance." — shortest viable version. — [SECURITY](https://github.com/p2r3/convert/blob/HEAD/SECURITY.md)
- Pattern (corrected after review; counted from the nine files above as re-read at HEAD on 2026-11-19): 5 of 9 have a scope or threat-model section (basic-memory, chrome-devtools-mcp, Mole, OpenSpec, openusage); docker-agent, donutbrowser, spec-kit and convert do not. Only OpenSpec and openusage name GitHub private advisories as the primary channel.

AGENTS.md / CLAUDE.md:

- Single-source pattern: openusage "CLAUDE.md files may only point to the nearest AGENTS.md file with `@AGENTS.md`" (CLAUDE.md is 1 line); ruby_llm CLAUDE.md is `@AGENTS.md`; gnhf CLAUDE.md is 2 lines; cliamp "`AGENTS.md` is a symlink to this file. Edit `CLAUDE.md` only."; Mole states there is deliberately no CLAUDE.md. — [openusage AGENTS](https://github.com/robinebers/openusage/blob/HEAD/AGENTS.md), [cliamp CLAUDE](https://github.com/bjarneo/cliamp/blob/HEAD/CLAUDE.md), [Mole AGENTS](https://github.com/tw93/Mole/blob/HEAD/AGENTS.md)
- Contents seen: commands (chrome-devtools-mcp: "Use only scripts from `package.json` to run commands."), architecture maps (cliamp "Architecture map", kumo "WHERE TO LOOK", ruby_llm "Framework structure"/"Boundaries (enforced by Archspec.rb)"), invariants/guardrails (gnhf has an "Invariants" section and "never hand-edit `CHANGELOG.md` or `.release-please-manifest.json`"; ruby_llm "Never invent model ids" and "Never edit generated files"; kumo "ANTI-PATTERNS", "CRITICAL" styling rules; Mole "Critical Safety Rules"), product filters (Mole "What Mole Should Not Do", "Product Decision Filter"), maintainer preferences (cliamp "Things to know about the maintainer's preferences"), commit format (cliamp wants a body on every commit; ruby_llm: "No 'Generated with' footers, no Co-Authored-By tags"; donut: one-line `<type>: <summary>` under 30 characters). — [ruby_llm AGENTS](https://github.com/crmne/ruby_llm/blob/HEAD/AGENTS.md), [gnhf AGENTS](https://github.com/kunchenguid/gnhf/blob/HEAD/AGENTS.md), [kumo AGENTS](https://github.com/cloudflare/kumo/blob/HEAD/AGENTS.md)
- Length range: convert's AGENTS.md is one line, telling the agent to read the end of the README, where the AI usage policy is; gnhf 48 lines; spec-kit 76; kumo 171; docker-agent 172; chrome 213; cliamp 250; basic-memory 517; donut 606. gnhf has a section "Maintaining this file" (meta-guidance to keep it current). kumo's header says "Generated: 2026-03-18 | Commit: 38518e34", i.e. partly agent-generated. — [convert AGENTS](https://github.com/p2r3/convert/blob/HEAD/AGENTS.md)
- ruby_llm: "How RubyLLM is built. For coding agents first, humans welcome." and delegates repo-wide PR rules to an account-level automation repo, a pattern for solo maintainers with many repos. It lets agents "push straight to `main`" for small fixes and merge their own PRs once CI and reviewers (CodeRabbit, CodeQL) pass. — [AGENTS](https://github.com/crmne/ruby_llm/blob/HEAD/AGENTS.md)
- AGENTS.md as policy enforcement: donut's file opens with a git rule (the agent may commit, but other history- or remote-changing commands need explicit authorization) and an AI-contribution section addressed to agents that forbids an AI `Co-Authored-By` trailer, tells the agent not to write PR descriptions, and not to tick the AI-disclosure box for the human. spec-kit's AGENTS.md says agent-authored commits and comments each need their own disclosure. — [donut AGENTS](https://github.com/donutbrowser/donutbrowser/blob/HEAD/AGENTS.md), [spec-kit AGENTS](https://github.com/github/spec-kit/blob/HEAD/AGENTS.md)

AI-contribution policies (stance, wording, enforcement):

- Disclose and own it, enforced by bot: donut ("AI can write your code. It cannot speak for you, and it cannot be a co-author."; PR template requires exactly one AI box ticked or "a bot closes the PR"; `pr-ai-policy.yml` workflow). — [CONTRIBUTING](https://github.com/donutbrowser/donutbrowser/blob/HEAD/CONTRIBUTING.md)
- Disclose, prose by human: convert README "AI Usage Policy" ("Not disclosing it may get your PR insta-closed"; "Do not use it to write descriptions for issues/PRs (except for translation)"; "there should _never_ be a scenario where you _need_ an LLM"), with an explicit acceptance of AI code ("I believe that's simply not feasible" to ban it). — [README](https://github.com/p2r3/convert/blob/HEAD/README.md)
- Disclose with detail, judged equally: spec-kit ("human and AI-assisted contributions are judged identically"; name tool, model, settings, degree; PR template has an AI Disclosure checkbox section). — [CONTRIBUTING](https://github.com/github/spec-kit/blob/HEAD/CONTRIBUTING.md)
- Permissive: ruby_llm "Use whatever tools you like, AI included. We review the change, not how it was written. You're responsible for every line you submit." — [CONTRIBUTING](https://github.com/crmne/ruby_llm/blob/HEAD/CONTRIBUTING.md)
- Gate via tooling: gnhf's `no-mistakes` requirement (AI-driven review before the PR); kumo's PR template has a checkbox "clanky has reviewed the change" or "automated review not possible because" (an internal AI reviewer; `validate-pr-description.yml`). — [kumo PR template](https://github.com/cloudflare/kumo/blob/HEAD/.github/pull_request_template.md)
- Restrictive on authorship text: openusage "No AI-generated commit messages."; OpenSpec requires issues "make it yours" if agent-drafted.
- Timing at convert (corrected after review): the README's "AI Usage Policy" section was added on day 98 (commit "add AI usage policy to README", 2026-03-15) and clarified the same day; a commit titled "update ai policy" first touched AGENTS.md on day 306 (2026-10-09). A commit search of the default branch found 55 commits with a Claude `Co-Authored-By` trailer, the earliest on day 297 (2026-09-30), and 27 commits with author name "claude", the earliest on day 309. So the policy preceded the agent-assisted commits found. Trailers naming other agents were not searched.

Issue templates / config:

- All 7 repos whose `config.yml` I read set `blank_issues_enabled: false` (chrome, basic-memory, ruby_llm, openusage, donut, spec-kit, OpenSpec). Contact links typically send questions to Discussions and docs (basic-memory, ruby_llm, donut, spec-kit). OpenSpec's config comment: "Issues are the only way a change to OpenSpec starts, so the forms are the only way in". YAML issue forms: chrome (3 forms incl. a "task" form), OpenSpec (bug/feature/docs), openusage (bug/feature/new_provider), donut, ruby_llm, spec-kit (8 forms incl. extension/preset submission), gnhf (bug only), convert (bug/feature/file-format-request). Markdown templates: basic-memory, cliamp, Mole. — [OpenSpec config](https://github.com/Fission-AI/OpenSpec/blob/HEAD/.github/ISSUE_TEMPLATE/config.yml), [chrome templates](https://github.com/ChromeDevTools/chrome-devtools-mcp/tree/HEAD/.github/ISSUE_TEMPLATE)
- PR templates are short and specific: Mole has a "Safety Review" section (does this touch path validation, sudo, symlinks?); OpenSpec "Closes #" + "How you verified it"; donut AI-usage tick; cliamp "`make check` passes" and docs updated.

### Inferences

- Maintainers have converged on "tell the contributor what you will reject and what evidence you need" (ruby_llm, spec-kit, openusage) rather than welcoming everything; the stricter ones appear after a flood of low-quality PRs, but this is not documented in the files themselves (reasons stated only in openusage's "keeps a small, focused project sane" and gnhf's "reduce the maintainer's burden").
- For agent policy, the transferable idea is the mismatch between the agent's default behavior (adding Co-Authored-By/"Generated with") and project rules; donut and ruby_llm put an explicit override in AGENTS.md.

### Gaps

- Contents of docs like CODE_OF_CONDUCT were not read (only existence).
- I did not read every issue template body; only filenames, config.yml and the PR templates above.

---

## 4. Process signals: issues vs discussions, labels, release cadence, commit convention, outside PRs, bots

### Takeaway

Everyone uses issues as the work queue; only 6 of 14 enabled Discussions. Despite strict-sounding policies, recent commits by non-owners are visible at 7 of them (cliamp, kumo, gnhf, Mole, spec-kit, docker-agent, basic-memory). Whether those authors are outside contributors was not checked (at company-owned repos they may be staff), and merge share by author type was not computed (corrected after review: earlier "merged at most of them"). Release cadence is high (weekly) and almost everything is automated through release-please, changesets, or tag-triggered workflows. Conventional commits dominate.

### Cited Findings

- Discussions enabled (API `has_discussions`): chrome-devtools-mcp, OpenSpec, spec-kit, ruby_llm, donutbrowser, Mole (6 of 14). Flag false: basic-memory, kumo, docker-agent, cliamp, gnhf, openusage, convert, spec-workflow-mcp; note basic-memory's issue config still links a Discussions URL (conflict; unverified which is current).
- Labels: `good first issue` exists in 12 of 14 (absent from spec-kit, which has `help wanted` among 56 labels; openusage uses `approved`, `needs-approved-issue`, `help wanted`). Label counts: 6 (convert) to 58 (docker-agent); OpenSpec has an `approved` label that gates PRs. — [labels API](https://docs.github.com/en/rest/issues/labels)
- Milestones/Projects: not verified (not queried).
- Versioning and cadence (current latest tags from API): chrome-devtools-mcp v1.13.0 on 2026-11-11 (65 releases, release-please, tags prefixed `chrome-devtools-mcp-v`); OpenSpec v2.1.0 2026-11-17 (60 releases, changesets); spec-kit v1.4.2 on 2026-11-17 (245 releases; v0.0.1 on day 1); docker-agent v1.162.0 on 2026-11-18 (278 releases; ~5 days between minors); kumo `@cloudflare/kumo@2.19.0` 2026-11-16; basic-memory v1.0.0 2026-10-29 after ~14 months of 0.x; cliamp v2.4.1 (163 releases; v1.0.0 on day 1); ruby_llm v2.2.3 2026-11-18; openusage v0.8.1-beta.2 (beta channel); gnhf 0.1.53 (53 patch releases, still 0.1.x); Mole V1.73.0 (capital-V tags, plus `-windows` and `-linux` suffixed tags); donutbrowser tags `nightly-<date>-<sha>` (610 releases, rolling); convert only a rolling `latest`.
- Release tooling seen: release-please (chrome-devtools-mcp, gnhf), changesets (OpenSpec, kumo), tag-triggered npm/MCP-registry publish (chrome), a GitHub release triggers gem push (ruby_llm), AUR/Nix/Homebrew publishing workflows (cliamp, Mole). spec-kit documents the process in `.github/workflows/RELEASE-PROCESS.md`. — [spec-kit workflows](https://github.com/github/spec-kit/tree/HEAD/.github/workflows)
- Commit conventions: conventional commits visible in the latest commits for chrome, OpenSpec, basic-memory, cliamp (mixed), kumo, gnhf, donut ("fix:", "feat:"), Mole; ruby_llm uses plain imperative sentences ("Add workers: to cap how many tool calls run at once (#1707)"). The conventional-commit requirement is enforced by CI at chrome-devtools-mcp (`conventional-commit.yml`) and basic-memory (`pr-title.yml`).
- Outside PRs: merged-PR totals (search API, includes bot PRs) — docker-agent 3,550 of 3,937; chrome 1,623/2,183; spec-kit 2,053/2,955; basic-memory 1,052/1,218; openusage 782/1,052; ruby_llm 768/1,045; kumo 665/863; OpenSpec 833/1,210; Mole 549/736; cliamp 306/452; donut 296/385; convert 179/276; gnhf 147/205; spec-workflow-mcp 48/91. Non-owner authors appear in each repo's latest commits except OpenSpec (maintainer-authored, consistent with its invitation-only rule), openusage (mostly the owner), and ruby_llm (owner commits; but 155 contributors overall).
- Bots/automation seen in workflow listings or config: stale workflows (donut `stale.yml`, openusage `stale.yml`, spec-kit `stale.yml` on 180-day inactive issues, docker-agent `stale-prs.yml`); AI reviewers (CodeRabbit via `.coderabbit.yaml` in OpenSpec and ruby_llm; Claude Code review workflows in basic-memory and spec-workflow-mcp; docker-agent `pr-review.yml`; kumo "clanky" and `pullrequest-report.yml`; openusage `pullfrog.yml`); AI-policy enforcement bots (donut `pr-ai-policy.yml`, openusage `pr-policy.yml`, gnhf `no-mistakes-required.yml`); `labeler.yml` (openusage); spec-kit uses GitHub agentic workflows (`.md` + `.lock.yml` pairs such as `bug-assess`, `pr-assess`, `add-community-extension`) to triage; CLA files (Google CLA in chrome CONTRIBUTING; `CLA.md` in basic-memory; donut CLA file). CodeQL in docker-agent, donut, ruby_llm, Mole, spec-kit; secret scanning via gitleaks in ruby_llm and Mole; Dependabot in 8 of 14 (chrome, OpenSpec, spec-kit, docker-agent, basic-memory, donut, Mole, openusage), Renovate in ruby_llm (day 634).
- Deliberate non-adoptions stated in files: ruby_llm refuses features (list above) and uses community gems for providers; Mole deliberately has no CLAUDE.md; OpenSpec limits PRs to maintainers/invited; openusage "no feature creep... most external pull requests are closed"; convert says it won't ban AI because it is "simply not feasible"; chrome-devtools-mcp SECURITY excludes prompt-injection through web content from scope.

### Inferences

- "Process" at these repos is mostly encoded in CI and bots rather than prose; the strictest human-facing rules are enforced mechanically (auto-close on missing label/disclosure).
- Solo maintainers show higher release cadence with automated release PRs (gnhf 53 releases in 7.5 months; cliamp 163 in 9 months) but may never write SECURITY/CoC.

### Gaps

- Milestones, Projects boards, and issue-vs-discussion volume were not measured.
- Whether bots (stale, AI reviewers) are currently active, rather than present as files, was not verified.
- External-PR merge share was not computed per author type; only totals and recent-commit author logins were examined.

---

## 5. Synthesis across the case studies

### Takeaway

Day one is the right time for LICENSE, a README that says what the thing is, CI, a first tag, and (if you can) CONTRIBUTING/SECURITY. Templates, Dependabot, CODEOWNERS and agent files are typically added weeks to months later and by most accounts cost little at launch; the user's planned day-one doc set is ahead of nearly every sampled repo, which mostly adopted these after traction. Heavier governance (GOVERNANCE, ROADMAP, ADRs, CoC) was mostly skipped.

### Cited Findings (patterns, each derived from Q1-Q4 data above)

- In the first week (<= day 7): LICENSE in 10 of 13 countable (chrome, spec-kit, basic-memory, donut, Mole, ruby_llm at day 7, gnhf, spec-workflow-mcp, plus docker-agent and kumo, whose visible history starts with it; late: OpenSpec 32, cliamp 10, convert 60); a README file in 13 of 14 (convert is the outlier at day 49; three of those were empty or one-line); CI in 8 of 14 (chrome, spec-kit, docker-agent, donut, Mole, ruby_llm, cliamp, gnhf); CONTRIBUTING in 4 (chrome, spec-kit, donut, docker-agent in `docs/`); SECURITY in 4 (chrome, spec-kit, donut, docker-agent); issue templates in 5 (chrome, donut, spec-workflow-mcp, docker-agent, gnhf at day 6; corrected after review); agent files in 0-1 (kumo/docker-agent arguably due to pre-creation history).
- After traction (day 30-420; current stars 4k-150k): CONTRIBUTING (OpenSpec 400, basic-memory 64, ruby_llm 51), SECURITY (Mole 168, OpenSpec 351, convert 340, basic-memory 100), issue/PR templates (ruby_llm 126, spec-kit 182, OpenSpec 420), Dependabot (basic-memory 103, spec-kit 181, OpenSpec 351, docker-agent 374), AGENTS.md (OpenSpec 31, spec-kit 30, docker 46, cliamp 121, Mole 104, chrome 223, ruby_llm 566), MAINTAINERS (OpenSpec 162).
- Mostly never: CODE_OF_CONDUCT (10 of 14 have none), CODEOWNERS (9 of 14), FUNDING (12 of 14), GOVERNANCE/ROADMAP (14 of 14), ADR directories (14 of 14; docs/ARCHITECTURE.md at basic-memory and `design/` at spec-kit are the nearest).
- Solo vs company-backed: company-backed repos (chrome, spec-kit, docker-agent) front-load boilerplate that comes from an org template (identical GitHub-standard SECURITY text, Google CLA/VRP, CODEOWNERS pointing to a team) and have 135-342 contributors; solo repos (convert, cliamp, Mole, ruby_llm, gnhf, openusage) typically launch with only README + code + a release flow and add policy documents later; the files rarely say why (corrected after review). Solo maintainers with high traction (openusage, OpenSpec, gnhf, donut) write the most restrictive and opinionated CONTRIBUTING files. Solo maintainers also lean hardest on AGENTS.md as a policy surface.
- Patterns specific to AI-developed repos: (1) agent file added once the maintainer starts using agents (gnhf d17, basic-memory CLAUDE.md d88) and then grown into a 200-600 line manual (basic-memory 517, donut 606); (2) consolidation to one canonical file via `@AGENTS.md` pointer or symlink; (3) explicit overrides of default agent attribution ("No Co-Authored-By"); (4) AI disclosure fields in PR template and issue forms (spec-kit, donut) and auto-closing bots; (5) AI-driven review in CI (CodeRabbit, Claude Code review, kumo "clanky", docker-agent pr-review, gnhf no-mistakes); (6) agents given push/merge rights with CI as the gate (ruby_llm); (7) skills/plugin directories (`skills/`, `.claude-plugin/`, `.agents/`) appear in 8 of 14 root listings; (8) spec-driven structure inside the repo itself (OpenSpec's `openspec/`, basic-memory's `specs/` from day 294, spec-kit's `.specify/` and `memory/constitution.md`).

Quotable examples worth imitating (all short, with file links):

- README opening: docker-agent's one-sentence `>` blockquote + GIF + YAML example. [README](https://github.com/docker/docker-agent/blob/HEAD/README.md); openusage's "Track your AI coding subscriptions from the macOS menu bar." [README](https://github.com/robinebers/openusage/blob/HEAD/README.md)
- CONTRIBUTING: ruby_llm's "Features we'll reject" list; OpenSpec's numbered "1. Open an issue / 2. We discuss it / 3. Open the PR (invited contributors)" flow. [OpenSpec](https://github.com/Fission-AI/OpenSpec/blob/HEAD/CONTRIBUTING.md)
- SECURITY: OpenSpec's "We aim to acknowledge within 3 business days and to ship a fix or a decision within 30 days." plus in-scope/out-of-scope table. [SECURITY](https://github.com/Fission-AI/OpenSpec/blob/HEAD/SECURITY.md); openusage's GitHub Security Advisories link with "Acknowledgment within 48 hours". [SECURITY](https://github.com/robinebers/openusage/blob/HEAD/SECURITY.md)
- AGENTS.md: openusage's one-line CLAUDE.md pointer; gnhf's compact 48-line structure (Project / Commands / Code map / Invariants / Conventions / Maintaining this file) [AGENTS](https://github.com/kunchenguid/gnhf/blob/HEAD/AGENTS.md); ruby_llm "Ground rules" with "Never invent model ids." [AGENTS](https://github.com/crmne/ruby_llm/blob/HEAD/AGENTS.md)
- AI-contribution policy: donut ("Disclosing AI use is never held against you. Hiding it is what gets a PR closed.") [CONTRIBUTING](https://github.com/donutbrowser/donutbrowser/blob/HEAD/CONTRIBUTING.md); spec-kit's "human and AI-assisted contributions are judged identically." [CONTRIBUTING](https://github.com/github/spec-kit/blob/HEAD/CONTRIBUTING.md)
- Issue templates: OpenSpec `config.yml` comment explaining forms are the only way in; `blank_issues_enabled: false` plus Discussions contact link (basic-memory, ruby_llm, donut). [basic-memory config](https://github.com/basicmachines-co/basic-memory/blob/HEAD/.github/ISSUE_TEMPLATE/config.yml)
- Release process: release-please from commit one (gnhf: first release PR merged within ~23 hours; AGENTS tells the agent never to hand-edit CHANGELOG); chrome-devtools-mcp's conventional-commit CI check plus `chore:` vs `feat:` feature-flagging checklist. [gnhf AGENTS](https://github.com/kunchenguid/gnhf/blob/HEAD/AGENTS.md)

### Inferences

- For a docs-only, requirements-first, solo, MIT, agent-developed repo: the closest precedents are OpenSpec (spec-first bootstrapping, issue-first contributions, AGENTS.md at d31, changesets), gnhf (solo + release-please + AGENTS/CLAUDE + VISION.md), and donut/ruby_llm for AI policy wording. A day-one set that includes SECURITY with private reporting and CODEOWNERS is at the early end of the observed distribution (only chrome, spec-kit, donut got near).
- Things the sampled repos regretted or fixed later (inferred from "later" additions, not stated): no PR/issue templates at launch led to retrofits at d70-d420. When AI-attribution and disclosure rules arrived was dated only at convert, where the README policy (day 98) preceded the first Claude-co-authored commits found (day 297).
- Cadence suggests "first tagged release within a week, even as v0.0.x" was the norm for those that grew past 4k stars quickly (not a controlled finding).

### Gaps / limitations (state plainly)

- Small sample (14), selected by me from the top and 4-5k star bands; survivorship bias (only repos that reached >1k stars are visible; nothing about repos with identical practices that failed). Seven of 14 are agent/MCP tooling, which over-represents AI-friendly practices and AGENTS.md.
- Star-growth timing could not be reconstructed: the stargazers API returned 404; adoption is expressed by age and current stars only.
- Historic distortion: kumo, openusage and docker-agent have first-commit dates inconsistent with created_at (imported/rewritten history); OpenSpec/spec-kit/gnhf first commits may be squashed or rebased too (not verified). Timezone offsets can put a first commit one day before `created_at` (gnhf, cliamp's first release).
- "Never" means no commit found for the probed paths: LICENSE(.md/.txt)/COPYING, README, CONTRIBUTING (root, .github, docs), CODE_OF_CONDUCT, SECURITY (root, .github), issue templates dir, PR templates (3 spellings), CODEOWNERS, workflows, CHANGELOG.md, dependabot.yml, renovate.json, .changeset, release-please files, AGENTS/CLAUDE/GEMINI/.cursorrules/.cursor/rules/.claude/copilot-instructions, GOVERNANCE/MAINTAINERS/ROADMAP/ARCHITECTURE/docs/adr, FUNDING, CLA.md/DCO, AI_POLICY.md. Other names (e.g. SUPPORT.md, DEVELOPMENT.md, NOTE-FORMAT.md, TRADEMARK.md) were seen only in root listings.
- Contributor counts come from `contributors?anon=false` last-page counts and include bots; merged-PR counts include bot PRs.
- Quoted text is from current HEAD files, not day-one versions, except where I said "first commit".
- Milestones/Projects usage, label usage patterns, issue response times and star-to-adoption correlations were not examined. Blog/launch context for why choices were made was not consulted, so all "why" statements are either quoted from files or marked as inference.
