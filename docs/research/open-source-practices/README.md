# Popular young repos ship builds, skip paperwork

> **Research snapshot, 2026-11-18.** This report was produced with AI research
> agents (Claude) and has not been peer reviewed. It describes `leverage` as it
> was *before* its recommendations were acted on. The "Adopt now" items were
> implemented the same day (see the [changelog](../../../CHANGELOG.md)); the
> "Adopt later" items are tracked in
> [issue #2](https://github.com/yuric/leverage/issues/2), and the project
> description in [issue #1](https://github.com/yuric/leverage/issues/1). The
> per-repository survey data is in
> [data/repo_survey_data.csv](data/repo_survey_data.csv); the raw API captures
> behind it (about 10 MB) are not published here.

`leverage` already has more community paperwork than nearly every young popular repository surveyed. What it lacks is the machinery those repositories do have. Among a population-weighted sample of 1k–5k-star repositories created since 2024-11-18, **72% run CI, 80% have git tags and 78% publish GitHub Releases**. Only **48% have CONTRIBUTING, 33% have a security policy or private vulnerability reporting (PVR), 17% have a code of conduct and 4% have CODEOWNERS**. **Only about 6% of that 1k–5k range combines a recognised license, CONTRIBUTING, CODE_OF_CONDUCT and SECURITY** (none of the 25 sampled at 1k–2k, 36% at 20k+). Institutional advice (opensource.guide, GitHub, OpenSSF) puts the community files first and treats CI, dependency bots, branch protection and pinned workflows as security basics. The repositories mostly do the reverse: distribution first, community files later, supply-chain hardening rarely. Practitioners add one current theme that institutions barely touch: after the 2025–26 wave of AI-generated pull requests, maintainers want explicit AI-contribution rules and tight intake. Yet only about **10% of surveyed repos have such a policy**. For `leverage` that leads to a short adopt-now list:

- finish the README (issue #1);
- protect `main` with a ruleset;
- add one hardened, docs-only CI workflow;
- turn the single disclosure line into a real AI-contribution policy;
- publish maintainer expectations and scope;
- set the repository description and topics.

Code-dependent practices wait for the first code, the first release or a second maintainer. Governance, Scorecard, CLAs, roadmaps and chat servers are not worth worrying about now. None of this shows that any practice causes popularity: the survey only sees repositories that already succeeded.

## How the evidence was weighted and read

The quantitative evidence is a survey of **100 repositories created on or after 2024-11-18 with more than 1,000 stars**, measured through the GitHub API on 2026-11-18 ([Survey notes](notes/repo_survey.md); [Survey CSV](data/repo_survey_data.csv)). The sample is stratified at exactly 25 repositories per star band. The population is not: of the **7,515** qualifying repositories, **48% sit at 1k–2k stars, 31% at 2k–5k, 16% at 5k–20k and 4.7% at 20k+**. The unweighted "overall" figure in the survey notes therefore over-represents the 20k+ band about fivefold.

This report uses three kinds of figure and labels each one:

- **Per-band figures** (n=25 each, roughly ±20 points at 95%).
- **A "1k–5k pooled" figure**, weighted 3,638:2,348 across the two lower bands. This is the closest peer group for a new solo project, and it is the default figure in the text unless another is named.
- **A population-weighted overall figure**, computed from the CSV with all four band weights.

I recomputed every weighted figure with the survey's own detection rules. Fourteen close-read case studies add adoption timelines: how many days after creation each file first appeared ([Case studies](notes/repo_case_studies.md)). Advice comes from three notes: institutional sources ([Canonical guidance](notes/canonical_guidance.md)) and two practitioner passes ([Practitioner advice](notes/practitioner_advice.md), [Early-stage advice](notes/early_stage_advice.md)). The survey was then audited separately: 14 headline figures were recomputed from the CSV and matched, 8 randomly chosen repositories were re-checked live against the GitHub API with no mismatches in 64 cells, and three case-study claims were checked against the API. All held.

## Institutions prescribe a launch checklist; practitioners prescribe boundaries

### Institutional and canonical sources agree on four launch files and a security baseline

opensource.guide treats four files as pre-launch requirements:

- **LICENSE** ("You must include a license when you launch").
- **README**, answering what the project does, why it is useful, how to get started and where to get help. It should also say whether contributions are accepted and whether the project is production-ready, "even if the project feels unfinished".
- **CONTRIBUTING**, which "can be simple at first".
- **CODE_OF_CONDUCT**, with the Contributor Covenant as the ready-made option.

([Starting a project](https://opensource.guide/starting-a-project/)). The same guide calls issue and PR templates optional, says a full style guide is unnecessary early, and warns that heavy linting rules raise barriers for contributors ([Best practices](https://opensource.guide/best-practices/)). It treats contributor agreements as "usually unnecessary" because the license already covers inbound and outbound terms ([Legal](https://opensource.guide/legal/)). Governance documents come "as it grows", with the single-leader BDFL model normal for small projects ([Leadership and governance](https://opensource.guide/leadership-and-governance/)). Its maintainer advice is operational: publish how contributions are reviewed and how much time you have, keep communication public, and run automated tests on every contribution behind required status checks ([Best practices](https://opensource.guide/best-practices/)).

GitHub adds SECURITY.md, SUPPORT.md, FUNDING.yml, templates and CODEOWNERS as discoverable "community health" files, and scores repositories on a community-profile checklist ([GitHub: default community health files](https://docs.github.com/en/communities/setting-up-your-project-for-healthy-contributions/creating-a-default-community-health-file)). It also publishes a security list: SECURITY.md, Dependabot alerts and updates, code scanning, secret scanning and push protection ([GitHub: securing your repository](https://docs.github.com/en/code-security/getting-started/securing-your-repository)). It recommends PVR so researchers get a private, structured channel ([GitHub: PVR](https://docs.github.com/en/code-security/security-advisories/working-with-repository-security-advisories/configuring-private-vulnerability-reporting-for-a-repository)).

OpenSSF supplies the most useful mechanism for deciding what can wait. Its OSPS Baseline (version 2026.02.19) defines three levels ([OSPS Baseline](https://baseline.openssf.org/versions/2026-02-19)):

- **Level 1 applies to any project with any number of maintainers.** Its controls include MFA, blocking direct commits to the primary branch, preventing branch deletion, keeping secrets out of version control, a documented contribution process, a public discussion channel, an OSI/FSF license and a listed security contact.
- **Level 2 (two or more maintainers)** adds CI tests, status checks, per-commit DCO-style assertions, signed releases, release changelogs and a coordinated-disclosure policy.
- **Level 3 (a large user base)** adds an SBOM, at least one non-author approval per change, threat modelling and SAST/SCA gates.

OpenSSF's Scorecard checks a further set of items: least-privilege workflow tokens, hash-pinned dependencies and Actions, dangerous `pull_request_target` patterns and a dependency-update tool. Scorecard cannot assess "Maintained" for repositories under 90 days old, and its Contributors check needs contributors from three or more organisations ([Scorecard checks](https://github.com/ossf/scorecard/blob/main/docs/checks.md)).

Foundation requirements belong to joining a foundation, not to launching a repository, and are reference points only. CNCF sandbox expects Apache-2.0 and DCO; Apache requires CLAs from committers ([Apache](https://www.apache.org/foundation/how-it-works/)).

On AI, the institutions are permissive and focused on provenance:

- **AGENTS.md** is a no-required-fields "README for agents", now stewarded under the Linux Foundation ([agents.md](https://agents.md)).
- **Apache** (guidance updated August 2026) encourages a `Generated-by:` or `Co-authored-by:` commit trailer ([Apache generative tooling](https://www.apache.org/legal/generative-tooling.html)).
- **The Linux Foundation** allows AI output subject to license checks and states no disclosure requirement ([LF generative AI](https://www.linuxfoundation.org/legal/generative-ai)).
- **OpenSSF** says to keep human review, flag AI-generated code, pin CI action versions and keep instruction files short ([OpenSSF AI guide](https://best.openssf.org/Security-Focused-Guide-for-AI-Code-Assistant-Instructions)).

### Maintainers and practitioners stress boundaries, verification and controlled intake

The practitioner record is thinner but sharper. Mike McQuaid argues that maintainers "owe you nothing" ([McQuaid](https://mikemcquaid.com/open-source-maintainers-owe-you-nothing/)). Brett Cannon notes that accepting a patch means taking on its long-term upkeep ([Cannon](https://snarky.ca/setting-expectations-for-open-source-participation/)). Jeff Geerling's rule is "be liberal with your 'no'" ([Geerling](https://www.jeffgeerling.com/blog/2022/just-say-no/)). Filippo Valsorda turns the same stance into one short maintenance-policy file, linked from CODE_OF_CONDUCT, CONTRIBUTING and SECURITY. It states his work cycles and narrow scope, and that he prefers detailed issues over PRs ([Valsorda](https://words.filippo.io/maintenance-policy/)).

On building with agents, three named maintainers converge on verification loops:

- **Simon Willison** lists tests, CI with linting, documentation and code review as prerequisites, and warns that without tests an agent may claim code works when it does not ([Willison](https://simonwillison.net/2025/Oct/7/vibe-engineering/), [Willison](https://simonwillison.net/2025/Sep/30/designing-agentic-loops/)).
- **Armin Ronacher** wants fast, clear tooling and conservative dependency upgrades ([Ronacher](https://lucumr.pocoo.org/2025/6/12/agentic-coding/)).
- **Mitchell Hashimoto** grows AGENTS.md one line at a time from each observed agent mistake ([Hashimoto](https://mitchellh.com/writing/my-ai-adoption-journey)).

The strongest practitioner material is about AI-era intake, and it covers a range of positions:

- **Outright bans**: Gentoo, NetBSD, QEMU and Zig.
- **Disclosure plus accountability**: Linux (`Assisted-by:` trailer, no agent `Signed-off-by`), LLVM, Fedora, typescript-eslint and Ghostty.
- **Closing intake structurally**: tldraw auto-closes external PRs, Ghostty uses vouching, llama.cpp limits newcomers, and curl ended its bug bounty.

Sources: ([codenote.net roundup](https://codenote.net/en/posts/oss-ai-slop-contribution-policy-shift/), [kernel coding-assistants](https://docs.kernel.org/process/coding-assistants.html), [Ghostty AI_POLICY](https://github.com/ghostty-org/ghostty/blob/main/AI_POLICY.md), [tldraw](https://tldraw.dev/blog/stay-away-from-my-trash), [curl](https://daniel.haxx.se/blog/2026/01/26/the-end-of-the-curl-bug-bounty/)). Ghostty's policy calls its rules "temporary safeguards" and exempts the maintainers. Curl's Daniel Stenberg reports that the share of confirmed bounty reports fell from **over 15% to under 5% in 2025**, yet says PRs are not a major problem because tests and CI catch weak contributions.

One security finding is specific and well supported. The **tj-actions/changed-files compromise (CVE-2025-30066)** rewrote tags but could not rewrite commit SHAs. The fix is to pin Actions to full SHAs and let Renovate or pinact bump them ([Lullabot ADR](https://architecture.lullabot.com/adr/20260505-pin-github-actions-to-hash/)).

### Where sources disagree

| Topic | Positions |
|---|---|
| Code of conduct timing | opensource.guide lists it as a launch file. A GitHub interview says to skip it if you stay solo, and others say wait until conflict arises ([GitHub Blog](https://github.blog/open-source/maintainers/what-to-do-when-your-open-source-project-becomes-a-community/)). The Linux Foundation recommends adopting one early ([LF](https://www.linuxfoundation.org/blog/lessons-from-maintainers-of-the-worlds-most-critical-software)). |
| CLA vs DCO | Drew DeVault prefers DCO and reads a CLA as a relicensing warning sign ([DeVault](https://drewdevault.com/blog/DCO/)). Licensing lawyer Kyle Mitchell notes that relicensing never revokes past releases and that permissive projects can change terms for new work anyway ([Mitchell](https://writing.kemitchell.com/2023/09/06/Actual-CLA-Overreach)). QEMU declines AI-derived code because DCO clauses cannot be honoured for it. |
| AI attribution trailers | Apache encourages `Co-authored-by`/`Generated-by`. Linux requires `Assisted-by`. Two case-study repositories tell agents never to add `Co-Authored-By` (ruby_llm, donutbrowser) ([ruby_llm AGENTS](https://github.com/crmne/ruby_llm/blob/HEAD/AGENTS.md)). |
| Specs before code | Birgitta Böckeler endorses writing specs first but finds spec-driven tooling heavy on ceremony and review burden ([Böckeler](https://www.martinfowler.com/articles/exploring-gen-ai/sdd-3-tools.html)). No named maintainer was found recommending a public PRD before code. |
| Stale bots | Geerling credits one with preventing burnout. Gutenberg contributors leaned toward labelling issues and closing them manually ([WP Tavern](https://wptavern.com/gutenberg-contributors-consider-implementing-a-bot-to-close-stale-issues)). |
| Outside PRs at all | Steve Ruiz argues external code value "may be near zero". Willison says the AI PR flood is not a problem for his project ([tldraw](https://tldraw.dev/blog/stay-away-from-my-trash)). |

## The repos lead with distribution and add community files reactively

### Survey: what young popular repositories actually contain

The table below gives the measured adoption shares. The 1k–5k pooled column is the reference group for `leverage`. Weighted overall uses population weights, and unweighted is the survey's raw n=100 figure. All columns come from ([Survey CSV](data/repo_survey_data.csv)) using the survey's detection rules; weighting is my computation.

| Practice | 1k–2k | 2k–5k | 5k–20k | 20k+ | **1k–5k pooled** | Weighted overall | Unweighted |
|---|---|---|---|---|---|---|---|
| README | 96 | 100 | 100 | 100 | **98** | 98 | 99 |
| LICENSE file in tree | 84 | 92 | 92 | 92 | **87** | 88 | 90 |
| License recognised by GitHub | 76 | 80 | 88 | 80 | **78** | 79 | 81 |
| README demo image/GIF/video | 88 | 88 | 84 | 88 | **88** | 87 | 87 |
| README install/usage heading | 64 | 80 | 64 | 84 | **70** | 70 | 73 |
| Git tags | 80 | 80 | 80 | 96 | **80** | 81 | 84 |
| GitHub Releases ≥1 | 80 | 76 | 76 | 92 | **78** | 79 | 81 |
| SemVer-style tags | 64 | 72 | 68 | 80 | **67** | 68 | 71 |
| Any CI workflow | 72 | 72 | 80 | 96 | **72** | 74 | 80 |
| Release/publish automation (loose) | 52 | 64 | 76 | 80 | **57** | 61 | 68 |
| CI runs tests (strict) | 44 | 44 | 48 | 76 | **44** | 46 | 53 |
| CI runs lint/typecheck (loose) | 36 | 52 | 44 | 60 | **42** | 43 | 48 |
| Workflows declare `permissions:` | 56 | 68 | 76 | 92 | **61** | 65 | 73 |
| All Actions SHA-pinned (share of all repos) | 16 | 16 | 20 | 40 | **16** | 18 | 23 |
| Dependabot or Renovate | 8 | 12 | 12 | 44 | **10** | 12 | 19 |
| CodeQL workflow (floor) | 4 | 4 | 12 | 20 | **4** | 6 | 10 |
| OpenSSF Scorecard | 0 | 0 | 0 | 0 | **0** | 0 | 0 |
| Topics set | 56 | 56 | 60 | 56 | **56** | 57 | 57 |
| GitHub Discussions on | 52 | 44 | 64 | 56 | **49** | 52 | 54 |
| Chat link in README | 28 | 28 | 36 | 44 | **28** | 30 | 34 |
| CONTRIBUTING | 48 | 48 | 52 | 56 | **48** | 49 | 51 |
| Issue templates (any) | 48 | 40 | 64 | 64 | **45** | 49 | 54 |
| Issue templates as YAML forms | 24 | 36 | 52 | 56 | **29** | 34 | 42 |
| Blank issues disabled | 24 | 24 | 40 | 32 | **24** | 27 | 30 |
| PR template | 28 | 28 | 48 | 44 | **28** | 32 | 37 |
| SECURITY policy (any) | 24 | 32 | 44 | 56 | **27** | 31 | 39 |
| PVR enabled | 24 | 36 | 44 | 40 | **29** | 32 | 36 |
| SECURITY or PVR | 28 | 40 | 60 | 60 | **33** | 38 | 47 |
| CODE_OF_CONDUCT | 12 | 24 | 44 | 36 | **17** | 22 | 29 |
| CHANGELOG-type file | 36 | 40 | 24 | 44 | **38** | 36 | 36 |
| CODEOWNERS | 4 | 4 | 16 | 40 | **4** | 8 | 16 |
| Agent-instruction artifact (any) | 36 | 48 | 48 | 64 | **41** | 43 | 49 |
| AGENTS.md at root | 20 | 40 | 40 | 56 | **28** | 31 | 39 |
| CLAUDE.md at root | 16 | 24 | 24 | 28 | **19** | 20 | 23 |
| AI-contribution policy (manually verified) | 8 | 12 | 12 | 12 | **10** | 10 | 11 |
| AI-review bot/config | 4 | 0 | 8 | 32 | **2** | 5 | 11 |
| CLA or DCO (manually verified) | 8 | 8 | 12 | 8 | **8** | 9 | 9 |
| FUNDING.yml | 20 | 20 | 24 | 24 | **20** | 21 | 22 |
| docs/ directory | 28 | 64 | 60 | 76 | **42** | 47 | 57 |
| ARCHITECTURE doc | 8 | 20 | 16 | 24 | **13** | 14 | 17 |
| RFC/spec/PRD directory | 8 | 0 | 8 | 16 | **5** | 6 | 8 |
| ADR directory | 0 | 4 | 0 | 12 | **2** | 2 | 4 |
| GOVERNANCE | 0 | 4 | 4 | 12 | **2** | 2 | 5 |
| ROADMAP | 0 | 0 | 0 | 16 | **0** | 1 | 4 |
| SUPPORT | 0 | 8 | 4 | 4 | **3** | 3 | 4 |
| MAINTAINERS | 0 | 0 | 0 | 8 | **0** | 0 | 2 |
| Stale bot | 4 | 4 | 4 | 4 | **4** | 4 | 4 |
| .gitattributes | 28 | 32 | 36 | 68 | **30** | 32 | 41 |
| .editorconfig | 8 | 4 | 12 | 24 | **6** | 8 | 12 |
| AUTHORS | 0 | 4 | 0 | 0 | **2** | 1 | 1 |
| Five-file bundle (README, recognised license, CONTRIBUTING, CoC, SECURITY) | 0 | 16 | 28 | 36 | **6** | 11 | 20 |
| Community health = 100% | 0 | 8 | 24 | 12 | **3** | 7 | 11 |

Weighting changes the story for practices that cluster at 20k+:

| Practice | Unweighted | Weighted overall |
|---|---|---|
| CODEOWNERS | 16% | 8% |
| Dependabot/Renovate | 19% | 12% |
| AI-review bots | 11% | 5% |
| Five-file bundle | 20% | 11% |

Weighting changes almost nothing for practices that are flat across bands, such as CONTRIBUTING, CHANGELOG, FUNDING, CLA/DCO, AI policy and README demo media. A few band-level patterns stand out:

- **At 1k–2k stars, 60% of repositories have ten or fewer contributors and 68% are user-owned.** These are effectively one-person projects, and they show the lightest paperwork: CoC 12%, CODEOWNERS 4%, SECURITY-or-PVR 28%.
- **About 1 in 5 has no recognised open-source license** despite 1,000+ stars.
- **License, tags, releases and README demo media hardly vary by band.** These behave like table stakes.
- **CODEOWNERS, dependency bots, AI review, SHA pinning and ROADMAP jump only at 20k+.** These behave like the marks of large, often company-run projects.

The survey notes add that organisation-owned repos lead user-owned repos on CoC (42% vs 15%) and CI (89% vs 70%). Repos under a year old more often run tests in CI (65% vs 42%, unweighted) ([Survey notes](notes/repo_survey.md)).

### Case studies: hygiene arrives in two bursts, and almost nobody writes requirements first

Twelve of the 14 case studies started code-first. **OpenSpec is the only repository whose first commits were a spec structure and a change proposal before any code** ([OpenSpec commits](https://github.com/Fission-AI/OpenSpec/commits/main)). spec-kit landed its methodology document together with code on day one ([spec-kit](https://github.com/github/spec-kit/blob/HEAD/spec-driven.md)).

In the first week, these were common:

| Practice in first week | Count |
|---|---|
| LICENSE | 10 of 13 countable |
| README | 13 of 14, three of them empty or one line |
| CI | 8 of 14 |
| A tagged release within five days | 8 of 14 |

Fewer than a third had CONTRIBUTING, SECURITY or issue templates that early (4 of 14 each).

Most other files arrived between day 30 and day 420, often in a deliberate hygiene pass:

- **Mole added SECURITY.md, a PR template and CODEOWNERS on day 168** in a commit titled "docs: strengthen public security signals" ([Mole SECURITY](https://github.com/tw93/Mole/blob/HEAD/SECURITY.md)).
- spec-kit added issue templates, a PR template, Dependabot and a stale workflow within about ten days of each other, six months in.
- OpenSpec added SECURITY and Dependabot at day 351, CONTRIBUTING at day 400 and issue forms at day 420, by which point it had 75k stars.

Some files were mostly never adopted. **CODE_OF_CONDUCT is absent in 10 of 14, CODEOWNERS in 9, FUNDING in 12, and GOVERNANCE, ROADMAP and ADR directories in all 14.**

Agent-instruction files nearly always came after launch. The exceptions are kumo and docker-agent, whose files predate their visible history. Among the rest, the earliest was gnhf on day 17 and the latest ruby_llm on day 566. Four repositories converged on one canonical file: openusage's CLAUDE.md is literally `@AGENTS.md`, and cliamp symlinks the two ([openusage AGENTS](https://github.com/robinebers/openusage/blob/HEAD/AGENTS.md)).

The AI-contribution rules in the case studies are concrete and often enforced by bots:

- **donutbrowser** auto-closes PRs without an AI-disclosure tick ([donutbrowser CONTRIBUTING](https://github.com/donutbrowser/donutbrowser/blob/HEAD/CONTRIBUTING.md)).
- **OpenSpec** makes PRs invitation-only after an issue is labelled `approved`, and asks that agent-drafted issues be read through and made the author's own ([OpenSpec CONTRIBUTING](https://github.com/Fission-AI/OpenSpec/blob/HEAD/CONTRIBUTING.md)).
- **openusage** closes most external PRs by design ([openusage CONTRIBUTING](https://github.com/robinebers/openusage/blob/HEAD/CONTRIBUTING.md)).
- **convert** added its AI policy on day 306, long after its own commits were agent-authored ([convert README](https://github.com/p2r3/convert/blob/HEAD/README.md)).

Despite these strict-sounding policies, outside PRs are merged at most of the 14. Process is encoded in CI and bots more than in prose.

## Advice and practice converge on basics and diverge on safeguards

The comparison table sorts each practice into one of four verdicts:

- **A**: advised and widely implemented.
- **B**: widely advised but rarely implemented (under about 35% in 1k–5k).
- **C**: implemented more than it is advised.
- **D**: rarely advised for this stage and rarely implemented.

"Has it?" is the current state of `leverage`. Observed shares are the 1k–5k pooled figure, with 20k+ in brackets where it differs sharply.

| Practice | Institutional advice | Practitioner advice | Observed (1k–5k pooled; 20k+) | Case studies (14) | Verdict | `leverage` has it? |
|---|---|---|---|---|---|---|
| LICENSE (OSI) | Launch requirement (opensource.guide, Baseline L1) | Uncontested | 87% file, 78% recognised | All 14 eventually; 3 added late (day 10–60) | A | Yes (MIT) |
| README answering what/why/how/help + maturity | Launch requirement | Low-credibility growth posts: first screen states audience and outcome | 98% present; 70% install heading | 13 of 14 day one, often thin; chrome-devtools-mcp says "early experimental prototype" | A | Partial: "definition phase" status only; description tracked in #1 |
| README demo media | Not mentioned | DEV growth posts only | **88%**, flat across bands | Common (docker-agent GIF, openusage screenshots) | C | No (nothing to show yet) |
| Tags / releases / SemVer | Best Practices: unique version id, release notes (MUST); SemVer suggested | Not covered | 80% tags, 78% releases, 67% SemVer | 8 of 14 release within 5 days | A | No |
| Release automation | Mentioned only as example tools | Not covered | **57%** (80% at 20k+) | release-please, changesets, tag workflows nearly everywhere | C | No |
| CHANGELOG | Keep a Changelog; Baseline L2 release changelog | Not covered | 38% | 8 of 14 | B (mid) | Yes (Unreleased section) |
| CI with tests on PRs | opensource.guide; Baseline L2 | Strong: Willison, Ronacher, Hashimoto, Stenberg | 72% any CI; 44% tests | 8 of 14 in first week | A | No |
| Conventional Commits | Spec only; no stage advice | Not covered | Not measured | Dominant; CI-enforced at chrome-devtools-mcp and basic-memory | C | Yes (AGENTS.md rule, not enforced) |
| Least-privilege workflow tokens | Scorecard; Baseline L2 | Not covered | 61% (92% at 20k+) | Not measured | A (where CI exists) | n/a (no workflows) |
| SHA-pinned Actions | Scorecard; OpenSSF AI guide | Strong after tj-actions | **16%** of all repos (40% at 20k+) | Not measured | B | n/a (no workflows) |
| Dependency-update bot | GitHub; Scorecard; opensource.guide | Ronacher: upgrade conservatively | **10%** (44% at 20k+) | 9 of 14, mostly day 97–634 | B | No |
| SAST / CodeQL | opensource.guide; Baseline L3 gates | Not covered | 4% (a floor) | 5 of 14 | B | No |
| OpenSSF Scorecard | OpenSSF | Not covered | **0%** | 0 of 14 | B | No |
| Branch protection / ruleset | Baseline L1 (block direct commits and deletion) | Not covered | Not observable | Not observable | Unknown | No |
| Secret scanning / push protection | GitHub; Baseline L1 | Not covered | Not observable | gitleaks at 2 | Unknown | Yes |
| MFA | Baseline L1 | Not covered | Not observable | Not observable | Unknown | Not stated in brief |
| CONTRIBUTING | Launch requirement | McQuaid funnel; "say what you'll reject" pattern | 48% | 11 of 14 eventually, 4 in first week | B (mid) | Yes |
| CODE_OF_CONDUCT | Launch requirement | Disputed timing | **17%** | 4 of 14 | B | Yes (by reference) |
| SECURITY.md + PVR | GitHub; Baseline L1 contact; L2 PVR | curl moved reports to PVR | 27% file, 29% PVR, 33% either | 9 of 14; 6 of 8 add scope sections | B | Yes (both) |
| Issue templates (YAML forms) | Optional | Not covered | 45% any, 29% forms | 13 of 14 eventually | C (mid) | Yes (forms) |
| Blank issues disabled | Not advised | Not covered | 24% | All 7 configs read disable them | C | No (enabled) |
| PR template | Optional | NewPipe and donutbrowser add AI checkboxes | 28% | Short and specific where present | D (mid) | Yes |
| CODEOWNERS | Documented, not required | Not covered | **4%** (40% at 20k+) | 5 of 14 | D | Yes (`* @yuric`) |
| Agent-instruction file | agents.md; OpenSSF AI guide | Strong: Willison, Hashimoto; keep short | 41% any; 28% AGENTS.md | 13 of 14, mostly post-launch | A (AI-era) | Yes (AGENTS.md + one-line CLAUDE.md) |
| AI-contribution policy | Apache/LF on provenance; no disclosure mandate from LF | **Strong**: Ghostty, Linux, LLVM, Fedora, llama.cpp | **10%** | At least 6 of 14 have explicit rules | B | Partial (one disclosure line) |
| AI-review bot | Not advised | Hashimoto uses report-only triage agents | 2% (32% at 20k+) | 7 of 14 | D below 20k | No |
| CLA / DCO | Usually unnecessary; DCO at Baseline L2 | DeVault vs Mitchell | 8% | 3 of 14 have CLAs | D | Deliberately none |
| Discussions / chat | Baseline L1 wants public discussion (issues suffice) | Not covered | 49% Discussions; 28% chat link | 6 of 14 Discussions | C (low effort) | No |
| GOVERNANCE / MAINTAINERS | "As it grows"; Baseline L2 | Not covered | 2% / 0% | 1 MAINTAINERS (day 162) | D | No |
| ROADMAP | opensource.guide lists roadmap in CONTRIBUTING | Not covered | 0% | 0 (gnhf has BACKLOG/VISION) | D | No (PRD + issues) |
| SUPPORT.md | GitHub health file | Not covered | 3% | Rare | D | No |
| FUNDING.yml | GitHub health file | No timing advice; Tidelift: donations are 25% of maintainer income | 20% | 2 of 14 | D | No |
| ADRs / architecture docs | Not advised | Middle ground: short docs for hard-to-reverse decisions | 2% ADR; 13% ARCHITECTURE | 0 ADR dirs | D | Convention declared; skeletons only |
| Public PRD / spec before code | Not advised | Böckeler: spec-first yes, heavy SDD tooling no | 5% spec dir | Only OpenSpec | D | Yes (core of project) |
| Stale bot | Mentioned as a bot option | Contested | 4% | 4 of 14 have stale workflows | D | No |
| Maintainer expectations / scope limits | opensource.guide: publish rules, response time, availability | Strong: McQuaid, Cannon, Geerling, Valsorda | Not measured | ruby_llm's "Features we'll reject"; openusage "no feature creep" | Advised; implementation unmeasured | Partial (SECURITY targets only) |
| .editorconfig / .gitattributes / AUTHORS | Not advised | Not covered | 6% / 30% / 2% | Not measured | D | Yes (all three) |

Three conclusions follow from the table.

First, **the advice that is widely implemented is the advice that pays off directly for users and maintainers**: a license, a README, tags and releases, CI. Institutions, practitioners and repositories all agree on these.

Second, **the advice given widely but rarely followed falls into two groups**. One is the community-file layer (CoC 17%, SECURITY 27%, CONTRIBUTING 48%). The other is the supply-chain layer (SHA pinning 16%, dependency bots 10%, CodeQL 4%, Scorecard 0%). Practitioners' AI-contribution policies (10%) also fall short. Case-study timelines suggest the files tend to arrive reactively after traction or spam, not that they were judged useless.

Third, **some things are implemented far more than any credible source advises**: README demo media (88%), release automation (57%), YAML issue forms, disabled blank issues and agent files. These appear to spread by copying from successful projects and templates, not from guidance.

## What leverage should do now, later, and never worry about

### Already done

`leverage` already covers every opensource.guide launch file and the Baseline Level 1 items that do not depend on code or a release. These are LICENSE, CONTRIBUTING, CODE_OF_CONDUCT, a SECURITY.md with PVR enabled, secret scanning with push protection, YAML issue forms, a PR template, an AGENTS.md with a one-line CLAUDE.md pointer, a CHANGELOG and stable requirement IDs. In 1k–5k-star peers, only 6% have even the five-file community bundle. Work already finished is marked "Yes" in the comparison table; the lists below cover only new work, except where existing work needs tightening.

### Adopt now (each written as a GitHub issue)

| # | Issue title and scope (acceptance criteria) | Evidence-based reason | Has it? |
|---|---|---|---|
| N1 | **Complete #1: README states what, why, status and how to take part.** One-sentence statement of what `leverage` is and for whom. Why it exists. An explicit maturity line ("definition phase: no code, not usable; requirements in docs/PRD.md"). How to take part now (comment on PRD issues; issue-first per CONTRIBUTING). Links to PRD, CONTRIBUTING and SECURITY. | opensource.guide wants these four answers plus maturity "even if unfinished". chrome-devtools-mcp launched with an "early experimental prototype" line. | Partial (status only; #1 open) |
| N2 | **Add a ruleset on `main` and confirm MFA.** Block force-push and deletion. Require changes via PR with zero required approvals, so agents cannot push straight to `main` but solo merging still works. Do not enable "require code owner review". Confirm 2FA on the owner account. Document the rule in AGENTS.md. | Baseline Level 1 controls AC-03.01/03.02 and AC-01.01 apply to one-maintainer projects. Non-author approval (QA-07.01) is Level 3 and impossible solo. Case studies show process is enforced by machinery more than prose. Ruleset availability on free public repos was not confirmed in the notes; check in settings. | No |
| N3 | **Add one hardened docs-CI workflow.** Run on `pull_request` (never `pull_request_target`). Top-level `permissions: contents: read`. Every third-party action pinned to a full commit SHA, with Renovate (or pinact) set to bump pins. Jobs: Markdown lint and link check; a script checking that FR-/NFR- IDs in docs/PRD.md are unique and well-formed; a Conventional-Commit PR-title check. Mark these as required status checks in the N2 ruleset. | Willison and Hashimoto say agents need mechanical verification, and AGENTS.md's "verify before claiming" rule has none today. chrome-devtools-mcp and basic-memory enforce PR titles in CI. Scorecard Token-Permissions and Dangerous-Workflow checks, plus the tj-actions compromise, favour getting the first workflow right. Only 16% of 1k–5k peers pin every action. The ID check is my design suggestion, not an observed practice. The notes confirm Renovate and pinact maintain SHA pins but do not confirm Dependabot does. | No |
| N4 | **Expand the AI-assisted contributions policy.** In CONTRIBUTING, add a section stating that: (1) contributors disclose the tool and how it was used; (2) they must be able to explain the change without the tool; (3) issue and PR prose is human-written or human-edited, and agent-drafted issues are "made yours"; (4) the maintainer builds `leverage` largely with agents, with Co-Authored-By trailers; (5) contributions are judged on the same standard however they were written; (6) undisclosed AI use, or unverified model-written security reports, may be closed. Add a disclosure checkbox to the PR template and a short AI-reports clause to SECURITY.md. | Practitioner policies (Ghostty, Linux, LLVM, typescript-eslint) converge on disclosure plus accountability. Only 10% of peers have any policy. convert added its policy 306 days after agent use began. Wording precedents: spec-kit ("judged identically"), donutbrowser SECURITY ("an unverified model-written report is not a security report"), OpenSpec ("make it yours"). The trailer choice matches Apache's guidance; ruby_llm and donutbrowser chose the opposite. | Partial (one disclosure line) |
| N5 | **Publish maintainer expectations and scope.** One short section, Valsorda-style, linked from README, CONTRIBUTING and SECURITY. It says this is a solo project; gives realistic response targets for issues (SECURITY already has 7/30 days); states that issues and PRD comments are preferred over PRs during definition; lists what will be declined, tied to PRD non-goals (add a non-goals section to docs/PRD.md); and notes that no support is owed. | McQuaid, Cannon, Geerling and Valsorda converge on writing down "no" defaults before demand arrives. opensource.guide wants review rules and available time published, and goals stated "to resist scope creep". ruby_llm's "Features we'll reject" is the observed model. | Partial |
| N6 | **Set the repository description and topics.** A one-line description reusing the README's first sentence, plus 3–6 topics. Leave homepage empty until a site exists. | 56% of peers set topics; it is a low-effort toggle. Reusing one category phrase across description and README comes from low-credibility growth posts, so treat it as cheap, not proven. | No |

### Adopt later (with the trigger for each)

| # | Practice | Trigger | Evidence-based reason | Has it? |
|---|---|---|---|---|
| L1 | Build, test and lint CI as required checks | First code commit | Willison and Ronacher treat tests and fast tooling as preconditions for agent work. 44% of peers run tests in CI and 72% have some CI. Baseline QA-03.01/06.01. | No |
| L2 | AGENTS.md commands, code map and invariants, plus a "Maintaining this file" section, kept short | First code commit; then one line per observed agent error | Hashimoto's "harness engineering"; gnhf's 48-line structure; OpenSSF says keep instruction files concise. | Partial (rules only) |
| L3 | Dependency-update bot for language ecosystems | First dependency manifest | Advised by GitHub and Scorecard. Only 10% of 1k–5k peers use one; most case studies added it after day 97. Ronacher advises conservative upgrades, so group updates. | No |
| L4 | CodeQL default setup (or equivalent SAST) | First code in a supported language | opensource.guide security page. Baseline Level 3 sets SAST gates. Only 4% of peers have a CodeQL workflow (a floor, since default setup is invisible). | No |
| L5 | First tag at 0.1.0, SemVer 0.y.z, release automation; decide whether release-please or changesets owns the CHANGELOG or it stays hand-written | First runnable artifact anyone can install (optionally tag PRD milestones earlier) | 80% of peers tag and 78% release; 8 of 14 case studies released within five days of having code. Best Practices requires unique versions and human-readable notes. gnhf tells agents never to hand-edit a generated CHANGELOG. | No (CHANGELOG exists) |
| L6 | SECURITY.md supported-versions table and in-scope/out-of-scope section | First release | GitHub says SECURITY.md should list supported versions. 6 of 8 case-study SECURITY files add scope or a threat model (OpenSpec, chrome-devtools-mcp). | Partial |
| L7 | README quick start and demo screenshot or GIF | First thing that runs | 88% of peers show demo media and 70% have an install/usage heading, though only growth posts advise it. | No |
| L8 | First ADR in docs/adr/ | First hard-to-reverse decision (language, storage, dependency licences) | The convention is already declared. Practitioners favour short records for irreversible choices; Böckeler warns against spec volume. 2% of peers have ADR directories. | Convention only |
| L9 | Enable Discussions, disable blank issues, route questions via contact links | First question-type or off-topic issues | All 7 case-study configs read disable blank issues and route questions to Discussions. Only 24% of peers disable them, and Discussions is a toggle (49%). With no Discussions, blank issues remain the only open channel today. | No |
| L10 | Restrict PR intake (collaborator-only PRs, `approved`-issue gate, auto-close bot) | First wave of unsolicited or low-quality AI PRs | Used by tldraw, Ghostty, OpenSpec and openusage; GitHub added collaborator-only PR controls. Premature before any inbound PRs exist. | No |
| L11 | DCO sign-off, GOVERNANCE/MAINTAINERS, non-author review | Second maintainer with write access; decide on any CLA before the first external code merge if dual licensing is ever intended | Baseline LE-01.01 and GV-01 sit at Level 2 (two or more maintainers). Linux bars agents from `Signed-off-by`. A CLA cannot be added retroactively without re-consent (secondary claim). | Deliberately none |
| L12 | AI review bot on PRs | Agent-authored PRs regularly exceed what you can read line by line | 2% of 1k–5k peers vs 32% at 20k+. Willison counts a review culture as a prerequisite. | No |
| L13 | FUNDING.yml / Sponsors | People depend on it in production | 20% of peers have one. No practitioner timing advice was found. Tidelift (2024, self-selected) puts donations at 25% of maintainer income. | No |
| L14 | Signed releases, provenance, SBOM | Distributing binaries or packages others install | Baseline puts signing at Level 2 and SBOM at Level 3. Scorecard checks both. | No |

### Don't worry about

| Practice | One-line reason | Has it? |
|---|---|---|
| OpenSSF Scorecard workflow or badge | 0% of all 100 repos run it; it cannot assess repositories under 90 days old, and its Contributors check is unattainable solo. | No |
| ROADMAP.md | 0% in 1k–5k and absent from all 14 case studies; the PRD plus issues already serves. | No |
| SUPPORT.md | 3% of peers; N5's expectations section covers it. | No |
| GOVERNANCE before a second maintainer | 2% of peers; opensource.guide says add it as the project grows and BDFL is normal (see L11). | No |
| CLA | opensource.guide calls agreements usually unnecessary; under MIT inbound=outbound, a CLA mainly adds relicensing power (Mitchell). | Deliberately none |
| Expanding the code of conduct or enabling required code-owner review | CoC is adopted by reference and only 17% of peers have one. Required code-owner review cannot be satisfied solo, and GitHub's docs do not say how. | Yes / Yes (keep as is) |
| Stale bot | Contested among practitioners, used by 4% of peers, and pointless with few issues. | No |
| Discord or other chat server | 28% of peers link one, but no practitioner source on timing was found, and it adds a channel a solo maintainer must watch. | No |
| Spec-driven tooling layers (spec-kit/OpenSpec workflows) on top of the PRD | Böckeler found them verbose and tedious to review; a short hand-written PRD matches what she does herself. | No |
| REUSE/SPDX headers, reproducible builds, fuzzing | They cover source files and builds that do not exist yet; Baseline does not require them at Level 1. | No |
| Custom VULNERABILITY_REPORT.yml | PVR's default form already collects summary, details, proof of concept and impact. | No |
| AUTHORS, .editorconfig, .gitattributes upkeep | Rare among peers (2%, 6%, 30%) but harmless; AUTHORS also defines who "leverage contributors" are. | Yes |

## Limitations and gaps that bound these conclusions

**Survivorship bias is the central limit.** The survey sees only repositories that crossed 1,000 stars. Nothing in it shows that any practice caused that popularity, or that repositories with the same practices did not fail.

**Weighting has a cost.** The 1k–5k pooled and weighted-overall figures rest mostly on two bands of 25 repositories each, roughly ±20 points at 95%, so band differences under about 20 points are noise.

**The sample skews in several directions.** Over half of the unweighted sample is AI/LLM tooling (41% in the pooled 1k–5k group), which inflates agent-file and AI-policy figures. Star manipulation was not checked. Within-cell sampling came from the top 1,000 search results.

**Several practices could not be observed at all**: branch protection, rulesets, MFA, secret scanning and CodeQL default setup. Their implementation rates are unknown, not low.

**Detection relies on heuristics.** Release automation, lint-in-CI, README sections and demo media were detected by regex. Only the AI-policy and CLA/DCO figures were verified by hand.

**The case studies have their own limits.** There are 14, chosen by the researcher, half of them agent tooling. Three have distorted histories (kumo, openusage, docker-agent). Star-at-adoption data were unavailable, so "after traction" means "by age", not "by star count".

**Practitioner coverage has real holes.** No named-maintainer sources were found on:

- what a new project's README must contain;
- which ceremony is premature (governance, RFCs, Discord, changelogs, pre-1.0 versioning);
- publishing requirements before code;
- when to set up funding.

The README and demo advice that does exist comes from low-credibility growth posts. Several figures are secondhand and stay labelled that way: Tidelift's "61% maintain alone" and "almost 60% quit or considered quitting", the CNCF sandbox requirements, and parts of the AI-policy roundup.

**Some institutional reads are incomplete or paraphrased.** Institutional pages were summarised by a fetch model, not quoted verbatim. The OSPS Baseline read was truncated, and a newer 2026-08-28 version was not read. Ruleset availability on free public repositories was not confirmed. Whether Dependabot maintains SHA-pinned actions was not verified.

**My own suggestions are marked as such.** The PRD requirement-ID check in N3 and the non-goals section in N5 are design suggestions derived from the repository's conventions, not observed practices.

## Conclusion

The evidence reframes the question for `leverage`. Documentation is no longer the gap: by the measures that institutions emphasise, the repository already sits in roughly the top few percent of its peer group before writing a line of code. What separates it from typical successful young projects is machinery. Its own AGENTS.md rules ("verify before claiming", Conventional Commits, no direct changes outside review) are currently enforced by nothing. The highest-value early work is therefore to make those rules executable. Do it while the cost is a single docs workflow and a ruleset, rather than a retrofit after agents have filled the history.

The AI-contribution question is where `leverage` can be early on purpose rather than by accident. The surveyed repositories wrote their policies reactively, months after agent use or a spam wave, and their wording often contradicts the agents' default behaviour (Co-Authored-By trailers banned in one repo, required in another). A project that is agent-built and specified in public from day one can publish, before anyone arrives, both how it uses agents and what it expects of contributors who do. The case studies suggest this is the one area where launching with policy, not adding it after the first wave of low-quality PRs, is likely to matter.
