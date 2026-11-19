# Canonical institutional guidance for setting up and running an open source repository (as of 2026-11-18)

"I" in this note is the AI research agent that did this pass. Method note: all items were read from the live pages on 2026-11-18 via fetch (page text summarized by a fetch model, so wording is paraphrased, not verbatim). After an adversarial review on 2026-11-19, the quotations attributed to opensource.guide, agents.md, Apache and the Linux kernel were re-checked against the live pages; those not found were turned into paraphrase, marked "(corrected after review)". Quotations from GitHub Docs, CNCF, Apache's how-it-works page and the specs in section 4 were not re-checked. Stage tag per practice: [DAY1] = source frames as required/before launch; [REC] = recommended, no stage stated; [LATER] = source ties it to maturity/more maintainers/users/releases; [OPT] = source says optional/suggested.

## 1. Files and repo settings (GitHub docs, opensource.guide)

### Takeaway

opensource.guide treats LICENSE, README, CONTRIBUTING and CODE_OF_CONDUCT as the four pre-launch files; templates are optional. GitHub's docs add SECURITY.md, SUPPORT.md, FUNDING.yml, templates, CODEOWNERS and repo security features as discoverable "community health" items.

### Cited Findings

- [DAY1] LICENSE: "You must include a license when you launch" an open source project. Reason: lets others use/copy/modify/contribute without legal risk; MIT, Apache 2.0, GPLv3 most popular. — [Starting a project](https://opensource.guide/starting-a-project/)
- [DAY1] Public is not open source: a public GitHub repo with no license grants no rights to use/modify/distribute; without license, contributions belong to authors and nobody (incl. owner) can legally use them. — [Legal](https://opensource.guide/legal/)
- [DAY1] README answers four questions: what the project does, why useful, how to get started, where to get more help; also state whether contributions are accepted and whether production-ready. Write it even if the project feels unfinished. Goals can also go in README or a VISION file to resist scope creep. — [Starting a project](https://opensource.guide/starting-a-project/), [Best practices](https://opensource.guide/best-practices/)
- [DAY1] CONTRIBUTING: how to file bugs, suggest features, set up environment, run tests; types of contributions wanted, roadmap, how to reach you; link from README. Reason: sets expectations, cuts repeated questions; GitHub links it from new issue/PR screens. Can be simple at first; add FAQs later. — [Starting a project](https://opensource.guide/starting-a-project/)
- [DAY1] CODE_OF_CONDUCT: who it applies to, when, consequences; Contributor Covenant is ready-to-use; place in root, link from README. — [Starting a project](https://opensource.guide/starting-a-project/)
- [OPT] Issue and PR templates: guide says "try using" them (also as a way to filter contributions: require issue template/checklist or issue-before-PR); not presented as required. — [Starting a project](https://opensource.guide/starting-a-project/), [Best practices](https://opensource.guide/best-practices/)
- [OPT] Full style guide not necessary early; keep linters/style rules minimal because excessive standards raise contributor barriers. — [Starting a project](https://opensource.guide/starting-a-project/), [Best practices](https://opensource.guide/best-practices/)
- GitHub supported community health files: CODE_OF_CONDUCT.md, CONTRIBUTING.md, SECURITY.md, SUPPORT.md, ACCESSIBILITY.md (root, .github, or docs/); FUNDING.yml in .github; issue/PR templates and config.yml in .github/ISSUE_TEMPLATE; discussion category forms in .github/DISCUSSION_TEMPLATE; VULNERABILITY_REPORT.yml in .github. Lookup order .github, root, docs. A repo's own file overrides org-wide `.github` repo defaults. LICENSE cannot be a default; every repo needs its own. GOVERNANCE not listed on that page. — [GitHub: default community health file](https://docs.github.com/en/communities/setting-up-your-project-for-healthy-contributions/creating-a-default-community-health-file)
- Community profile checklist ("community standards") checks README, code of conduct, license, contributing, security policy, issue templates (.github/ISSUE_TEMPLATE; md templates need `name:`/`about:` frontmatter, yml forms need `name:`/`description:`), PR template. — [GitHub: community profiles](https://docs.github.com/en/communities/setting-up-your-project-for-healthy-contributions/about-community-profiles-for-public-repositories)
- SECURITY.md: GitHub says to include supported versions and how to report a vulnerability. — [GitHub: adding a security policy](https://docs.github.com/en/code-security/getting-started/adding-a-security-policy-to-your-repository)
- Private vulnerability reporting (PVR): repo owners/admins of public repos enable under Settings > Advanced Security; adds "Report a vulnerability" button; default form summary/details/PoC/impact, customizable via .github/VULNERABILITY_REPORT.yml. Reason: gives researchers a private structured channel instead of public disclosure. — [GitHub: configure PVR](https://docs.github.com/en/code-security/security-advisories/working-with-repository-security-advisories/configuring-private-vulnerability-reporting-for-a-repository)
- GitHub "securing your repository" list: SECURITY.md, access control review, dependency graph, Dependabot alerts, Dependabot security updates, Dependabot version updates (dependabot.yml), dependency review, code scanning (CodeQL), secret scanning, push protection. — [GitHub: securing your repository](https://docs.github.com/en/code-security/getting-started/securing-your-repository)
- CODEOWNERS: lives in .github/, root, or docs/ (first found wins); last matching pattern wins; owners need write access; "Require review from Code Owners" is a branch-protection/ruleset option; protect the CODEOWNERS file itself by assigning an owner to it; code owners not auto-requested on draft PRs; file must be on the PR base branch. Page does not address how a solo owner satisfies required review (self-review). — [GitHub: about code owners](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-code-owners)
- Rulesets vs branch protection: multiple rulesets can stack on one branch; enforcement can be toggled without deleting; read-access users can view them; can control commit metadata; bypass lists by role/team/app; most restrictive rule wins when both apply. Availability on free plans/public repos not confirmed by fetched text. — [GitHub: about rulesets](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/about-rulesets)
- Maintainer practices: publish rules (how contributions reviewed, what accepted, response time, your available time); keep communication public; keep docs current; respond to and close unwanted contributions promptly (rejecting a contribution is not rejecting the person; corrected after review: paraphrase, not a quotation); label beginner issues; automated tests on all contributions runnable locally, with required status checks; consider bots (semantic-release, Danger, no-response, Dependabot); copy tooling popular in your ecosystem; set time boundaries to avoid burnout. — [Best practices for maintainers](https://opensource.guide/best-practices/)
- Governance docs: small projects can list leaders in README/CONTRIBUTORS; document how to earn roles (GOVERNANCE.md) as it grows; smaller projects are probably BDFL by default; some early documentation will shape governance anyway, so write down what you can, such as expectations for behavior and contribution (corrected after review: paraphrase, not a quotation); no legal entity needed unless money is involved (fiscal sponsors: Apache, Software Freedom Conservancy, Open Collective); consider an org account with backup admin. — [Leadership and governance](https://opensource.guide/leadership-and-governance/)
- Contributor agreements: "Probably not" needed, because for most projects the OSS license serves as both inbound and outbound license (corrected after review: the page's wording); CLA/DCO only for specific needs (patent grants, dual licensing); heavy agreements discourage contributors. — [Legal](https://opensource.guide/legal/)
- Security best-practices guide (no date visible): MFA for privileged contributors; SAST (CodeQL, Semgrep); secret scanning (block pushes, revoke leaks); SCA (Dependabot/Renovate); automated license checks + SBOM; branch protection (review + status checks); SECURITY.md with private reporting and response times; enable GitHub PVR; lightweight threat model; simple incident-response plan linked from SECURITY.md; least-privilege roles. Not organized by project stage. Does not mention Scorecard or signing. — [Security best practices](https://opensource.guide/security-best-practices-for-your-project/)
- Non-code content (images, fonts, data) has its own licenses; check dependency license compatibility (permissive vs copyleft vs source-available). — [Legal](https://opensource.guide/legal/)

### Inferences

- For a docs-only solo repo, the opensource.guide "day one" set (LICENSE, README, CONTRIBUTING, CODE_OF_CONDUCT) is fully covered; templates, CODEOWNERS, SUPPORT, FUNDING, GOVERNANCE are explicitly or implicitly optional.
- CODEOWNERS with a single owner who is also the only author gives no review effect unless review-requirement is off; GitHub docs do not address this (unverified how it behaves under rulesets).

### Gaps

- opensource.guide /best-practices/ and /building-community/ pages were only partly read (building-community not fetched). Published dates for opensource.guide pages not visible.
- GitHub docs for CODE_OF_CONDUCT/CONTRIBUTING/SUPPORT/FUNDING individual pages not fetched; SUPPORT/FUNDING reasoning only from the combined list.
- Ruleset availability on free-plan public repos not verified.

## 2. OpenSSF: Best Practices Badge, Scorecard, OSPS Baseline

### Takeaway

OSPS Baseline (version 2026.02.19 fetched; page links a "2026-08-28" newer version I did not read) defines three maturity levels; Level 1 applies to any project with any number of maintainers and is the right bar for a brand-new solo repo. Level 2 starts at 2+ maintainers; Level 3 at large user bases. Best Practices passing criteria and Scorecard overlap but are heavier and code-oriented.

### Cited Findings

Baseline levels: L1 any code/non-code project, any number of maintainers/users; L2 code projects with at least 2 maintainers and a small number of consistent users; L3 code projects with a large number of consistent users. — [OSPS Baseline 2026.02.19](https://baseline.openssf.org/versions/2026-02-19)

Baseline Level 1 controls (checkable) — same source:

- OSPS-AC-01.01 MFA required to read/modify sensitive resources in the authoritative repo.
- AC-02.01 new collaborators get lowest privileges by default. AC-03.01 block direct commits to primary branch. AC-03.02 primary-branch deletion needs explicit confirmation/prevented.
- BR-01.01 sanitize untrusted metadata (e.g. branch names, PR titles) in CI; BR-01.03 no privileged CI credentials exposed to untrusted code snapshots.
- BR-03.01/03.02 official project URIs only over encrypted channels; distribution channels protected from adversary-in-the-middle.
- BR-07.01 prevent unintentional storage of unencrypted sensitive data (secrets) in VCS.
- DO-01.01 user guides for basic functionality (after a release); DO-02.01 defect reporting guide (after a release).
- GV-02.01 public discussion mechanisms for proposed changes and usage issues (while active); GV-03.01 documented contribution process.
- LE-02.01/02.02 source and released-asset license meet OSI or FSF definition; LE-03.01/03.02 LICENSE/COPYING file in repo and with released assets.
- QA-01.01 repo publicly readable at static URL; QA-01.02 public record of changes/authors/timestamps; QA-02.01 dependency list for direct language dependencies where supported; QA-04.01 list codebases if multi-repo; QA-05.01/05.02 no generated executables or unreviewable binaries in VCS.
- VM-02.01 documentation lists security contacts.

Baseline Level 2 (2+ maintainers) — same source: AC-04.01 CI default-lowest permissions; BR-02.01 unique version id per release; BR-04.01 release change log (functional + security); BR-05.01 standardized dependency tooling; BR-06.01 signed releases or signed manifest with hashes; DO-06.01/07.01 document dependency selection and build instructions; GV-01.01/01.02 document members with sensitive access and roles; GV-03.02 contributor guide states acceptable-contribution requirements; **LE-01.01 contributors assert legal authority on every commit (DCO-style)**; QA-03.01 status checks on primary-branch commits; QA-06.01 CI runs automated tests; SA-01.01/02.01/03.01 design docs, external interface docs, security assessment (after release); VM-01.01 coordinated vulnerability disclosure policy with response timeframe; VM-03.01 private vulnerability reporting; VM-04.01 publish vulnerability data.

Baseline Level 3 (large user base) — same source: AC-04.02 least-privilege jobs; BR-01.04; BR-02.02; BR-07.02 secrets policy; DO-03.01/03.02 verify asset integrity/author identity docs; DO-04.01/05.01 support scope/duration and end-of-security-updates statement; GV-04.01 reviewed collaborator escalation; **QA-02.02 SBOM for compiled released assets**; QA-04.02; QA-06.02/06.03 test docs and test-with-major-change policy; **QA-07.01 at least one non-author human approval on primary-branch commits**; SA-03.02 threat modeling; VM-04.02 VEX; VM-05.01-.03 SCA thresholds/pre-release/automatic malicious-dependency checks; VM-06.01/06.02 SAST thresholds and automatic blocking.

Note: the fetch of the Baseline page was truncated at 100,000 of ~127,000 chars; the control list above came from the first portion and appears complete by level, but per-control "Applicability"/rationale text (e.g. which controls apply only after a release) was only partially seen. — [OSPS Baseline 2026.02.19](https://baseline.openssf.org/versions/2026-02-19)

Scorecard checks (risk level; what scored) — [Scorecard checks doc](https://github.com/ossf/scorecard/blob/main/docs/checks.md):

- Branch-Protection (High): tiered; T1 block force-push/deletion, T2 require reviewers/admin settings, T3 status checks, T4 two reviewers + code owner review, T5 dismiss stale approvals/include admins.
- Code-Review (High): last ~30 commits human-reviewed; bot reviews do not count.
- Dangerous-Workflow (Critical): untrusted checkout under pull_request_target/workflow_run; script injection from context variables.
- Token-Permissions (High): top-level read-only `permissions:` with job-level writes.
- Pinned-Dependencies (Medium): hash-pin in Dockerfiles, shell scripts, workflows.
- Dependency-Update-Tool (High): Dependabot or Renovate configured.
- SAST (Medium): CodeQL or SonarCloud in PRs/workflows. Fuzzing (Medium): OSS-Fuzz/ClusterFuzzLite/language-native fuzz or property tests.
- Security-Policy (Medium): SECURITY.md with contact (6 pts), policy text (3), vuln/disclosure language (1).
- Signed-Releases (High): signature files 8, SLSA provenance .intoto.jsonl 10.
- Vulnerabilities (High, OSV); Binary-Artifacts (High); License (Low: top-level file, recognized FSF/OSI license); Maintained (High: projects under 90 days old cannot be assessed; weekly commits over 90 days scores top); CI-Tests (Low); CII-Best-Practices (Low: passing 5, silver 7, gold 10, in progress 2); Packaging (Medium); SBOM (Medium: in-source 5, as release artifact +5); Contributors (Low); Webhooks (Critical).
- Scorecard does not state "day one vs later" tiers; it scores presence only.

Best Practices Badge, passing level (selected checkable criteria; MUST unless noted) — [bestpractices.dev criteria](https://www.bestpractices.dev/en/criteria/0):

- Basics: description_good, interact (how to obtain/feedback/contribute), contribution (process explained), contribution_requirements (SHOULD), floss_license, license_location, documentation_basics, documentation_interface, sites_https, discussion (searchable, no proprietary client), english (SHOULD), maintained.
- Change control: public repo, repo_track, repo_interim, unique version per release, version_semver (SUGGESTED), version_tags (SUGGESTED), release_notes (human-readable, not raw logs), release_notes_vulns (list fixed public vulns).
- Reporting: bug report process, issue tracker (SHOULD), respond to majority of bug reports in last 2-12 months, public archive, vulnerability report process published, private-report instructions (if supported), initial vuln response within 14 days.
- Quality: working build; automated FLOSS test suite; test_policy (tests for new major functionality) and evidence it is followed; CI (SUGGESTED); compiler warnings/linter enabled and addressed.
- Security: dev knows secure design and common errors; crypto criteria; delivery_mitm (HTTPS); no unpatched medium+ vulns >60 days; no_leaked_credentials.
- Analysis: static_analysis before major releases (MUST); fix medium+ findings; dynamic analysis SUGGESTED.
- Many build/test/crypto/analysis criteria are N/A or "if applicable" for documentation-only projects; criteria page does not give a "new project" subset.

### Inferences

- A no-code, pre-release repo can plausibly satisfy Baseline L1 items that are not "after a release" (LICENSE, public repo, contribution doc, security contact, no secrets/binaries, MFA, block direct commits to main, public discussion). Several L1 controls (DO-01.01, DO-02.01) are explicitly post-release.
- For a solo maintainer, L2 items GV-01.*, LE-01.01 (DCO), QA-03.01/06.01 are out of the stated maturity range (needs 2+ maintainers), though cheap to adopt early.
- QA-07.01 (non-author approval) is L3 and structurally impossible for a solo maintainer; Scorecard Branch-Protection T4/T5 and Code-Review likewise cannot be fully scored solo.
- Scorecard "Maintained" cannot be assessed for repos under 90 days.

### Gaps

- Did not read the 2026-08-28 Baseline version (a later version exists per the page link; control changes between versions unverified). Did not read Concise Guide for Developing More Secure Software or Scorecard's newer checks list beyond above.
- Did not fetch Best Practices silver/gold or the "baseline" badge series (bestpractices.dev may now offer baseline-level badges: unverified).

## 3. Foundations: Linux Foundation, CNCF, Apache, TODO Group, Google, Mozilla; CLA vs DCO, trademarks, releases

### Takeaway

Foundation requirements are tied to joining a foundation, not to launching a repo. CNCF sandbox (entry stage) expects Apache-2.0, DCO (or CLA), written governance, and CoC reference; Apache requires CLA'd committers and PMC-voted releases. For an independent MIT solo project these are reference points only.

### Cited Findings

- CNCF sandbox (via search summary of cncf/sandbox guidance; secondary mirror noted, not confirmed on primary page): Apache 2.0 license required, GPL-family/BSL not acceptable; DCO enabled on every repo (CLA allowed instead); written open governance per CNCF maintainer guidance; CNCF CoC or adopted version referenced in root README; start OpenSSF Best Practices badge; license scanner (FOSSA/Snyk); DevStats; annual sandbox review may end in archiving; sandbox is entry point for early-stage projects and does not require due diligence. — [CNCF project lifecycle](https://contribute.cncf.io/projects/lifecycle/) (found via search; page itself not read), [cncf/sandbox](https://github.com/cncf/sandbox)
- DCO v1.1 (Linux Foundation, 2004/2006): contributor certifies they wrote the contribution or have the right to submit it under the project's license; project keeps a record of sign-off. Fetched page does not describe the sign-off mechanism (git `Signed-off-by`). — [developercertificate.org](https://developercertificate.org/)
- Apache: committers need signed CLA on file; PMC must vote to approve formal releases; lazy-consensus decisions; Apache Way includes "security as a mandatory feature" and a "commercial-friendly standard license"; Incubator entry needs working codebase, IP assignment intent, sponsoring mentor. — [Apache how it works](https://www.apache.org/foundation/how-it-works/)
- Google: pre-release checklist for Google-originated projects: README, Apache-2 LICENSE with source license headers, CONTRIBUTING, third-party code in `third_party`, lint check, internal approval; outside contributions only from contributors who signed Google's CLA. Page says little on security/versioning. This is an employer process, not general advice. — [Google open source: releasing](https://opensource.google/documentation/reference/releasing)
- TODO Group guides list includes "Starting an open source project", "Shutting down an open source project", "Using open source code", "Marketing Open Source Projects", "Building leadership", outbound OSS guide; no dates shown; the fetched index did not show AI or maintainer-specific guides. Content of the guides themselves was not read. — [TODO guides](https://todogroup.org/guides/)
- Trademark: no authoritative trademark guidance fetched (opensource.guide /legal/ summary covers licenses/IP but trademark detail not seen beyond company checklist item).

### Inferences

- CLA vs DCO: opensource.guide says neither needed usually; Baseline L2 (LE-01.01) wants per-commit assertion of authority (DCO-style) once 2+ maintainers; CNCF permits either; Apache/Google use CLAs. Net: DCO is the lightweight convention; CLA only for dual-licensing/patent needs.
- Linux Foundation guidance is not directly a repo-setup checklist.

### Gaps

- Mozilla guidance (e.g. Mozilla Open Source Archetypes, MOSS, Mozilla "open source release" docs) not researched; no findings.
- CNCF incubation/graduation criteria not retrieved (raw GitHub lifecycle URLs returned 404).
- Linux Foundation project-formation/trademark policy not retrieved.
- Google open source "creating a new project" best-practice docs (opensource.google/documentation) beyond the releasing page not read.

## 4. Licensing, SPDX/REUSE, SemVer, Keep a Changelog, Conventional Commits, release automation, reproducible builds, SBOMs

### Takeaway

These are conventions with specs; none of the sources mandates them day-one for a docs-only repo, and the specs themselves are clear about what is checkable (SPDX headers, 0.y.z, CHANGELOG sections, commit prefixes).

### Cited Findings

- REUSE spec 3.3 (2024-11-14): each covered file carries `SPDX-FileCopyrightText` and `SPDX-License-Identifier` (comment headers RECOMMENDED), license texts in `LICENSES/<SPDX-ID>.txt` with no unused licenses, REUSE.toml (version = 1, [[annotations]]) as alternative for bulk paths, .reuse/dep5 deprecated; `.license` sidecar for uncommentable files. Compliance checked with the REUSE tool (not described on spec page). — [REUSE spec 3.3](https://reuse.software/spec-3.3/)
- SemVer 2.0.0: MAJOR.MINOR.PATCH; 0.y.z is initial development ("anything may change", API not stable), commonly start at 0.1.0; 1.0.0 defines the public API once users depend on it; PATCH=backward-compatible fixes, MINOR=backward-compatible features, MAJOR=breaking. — [semver.org](https://semver.org)
- Keep a Changelog 1.1.0 (page header; embedded log shows 1.1.2, 2024-09-27): changelog for humans; entry for every version; group by Added/Changed/Deprecated/Removed/Fixed/Security; latest first; release dates; linkable versions; say if SemVer followed; keep an `Unreleased` section at top. — [keepachangelog.com](https://keepachangelog.com/en/1.1.0/)
- Conventional Commits 1.0.0: `<type>[scope]: <description>`; `fix` = PATCH, `feat` = MINOR, `BREAKING CHANGE:` footer or `!` = MAJOR; other types (build, chore, ci, docs, style, refactor, perf, test). Stated benefits: auto changelog, auto version bump, trigger build/publish, structured history. — [conventionalcommits.org](https://www.conventionalcommits.org/en/v1.0.0/)
- Release automation: opensource.guide names semantic-release as example tool only. — [Best practices](https://opensource.guide/best-practices/)
- Reproducible build definition: same source, environment and instructions let any party produce bit-by-bit identical artifacts, verified via hashes. Reasons page not read. — [reproducible-builds.org](https://reproducible-builds.org/docs/definition/)
- SBOM: recommended by opensource.guide security page (generate with license checks) and OpenSSF AI-assistant guide (SPDX or CycloneDX); Baseline L3 QA-02.02 requires SBOM for compiled released assets; Scorecard SBOM check. — [Security best practices](https://opensource.guide/security-best-practices-for-your-project/), [OpenSSF AI guide](https://best.openssf.org/Security-Focused-Guide-for-AI-Code-Assistant-Instructions), [Baseline](https://baseline.openssf.org/versions/2026-02-19)
- Best Practices badge treats SemVer/CalVer and git tags as SUGGESTED, unique version ids and human release notes as MUST. — [bestpractices.dev](https://www.bestpractices.dev/en/criteria/0)
- Google requires license headers on source files (for Apache-2 Google projects); opensource.guide does not require SPDX headers for MIT projects (not mentioned). — [Google releasing](https://opensource.google/documentation/reference/releasing)

### Inferences

- A docs-only repo has no covered source files, so REUSE/SPDX headers and SBOM/reproducible builds are not applicable yet; they become relevant at first code/release (Baseline places SBOM at L3).
- A CHANGELOG with an `Unreleased` section and a stated versioning scheme satisfies Keep a Changelog without any release existing.

### Gaps

- Conventional Commits adoption stage guidance (none given by spec). Why-reproducible rationale not retrieved. SLSA, Sigstore, and npm/PyPI trusted publishing guidance not researched.

## 5. AI: AGENTS.md, AI-contribution policies, disclosure

### Takeaway

AGENTS.md is a plain-Markdown, no-required-fields convention now stewarded by the Agentic AI Foundation under the Linux Foundation. LF and Apache both accept AI-assisted contributions subject to license/IP checks, and Apache encourages (not requires) a Generated-by commit trailer; OpenSSF says to keep human review and flag AI-generated code.

### Cited Findings

- AGENTS.md: "README for agents"; root file; no required fields; suggested sections: project overview, build/test commands, code style, testing instructions, security considerations, PR/commit conventions, deployment, pitfalls; nested AGENTS.md per subproject in monorepos, nearest file wins; user chat prompts override it; site claims 60,000+ projects; stewarded by Agentic AI Foundation under Linux Foundation. — [agents.md](https://agents.md)
- Linux Foundation generative AI guidance (no date on page): AI-generated content may be contributed to LF projects; check the tool's terms do not conflict with the project license/OSD; if output contains third-party copyrighted material, confirm permission and license compatibility and include notices/attribution; projects may set own guidance; follow employer policy. No disclosure/labeling requirement stated. — [LF generative AI guidance](https://www.linuxfoundation.org/legal/generative-ai)
- Apache generative tooling guidance (states it reflects August 2026 — recently updated): encourage `Generated-by: <Tool> <Version>` or `Co-authored-by:` token in commit messages (to support future Tooling-Provenance); conditions: tool terms not conflicting with OSD, output either non-copyrightable, free of third-party material, or third-party material used with permission; contributors should have reasonable confidence; disclose third-party material and its license; prompts alone generally insufficient for human authorship; notify Apache's private legal list if representations later prove wrong; published AI-generated text must be human-reviewed or labeled as AI-generated. — [Apache generative tooling](https://www.apache.org/legal/generative-tooling.html)
- OpenSSF "Security-Focused Guide for AI Code Assistant Instructions" (Best Practices + AI/ML WGs, version dated 2025-08-01): keep instruction files concise and project-specific; cite OWASP Top 10/ASVS; avoid "act as a security expert" personas; don't skip review/testing/static analysis/version control because code is AI-generated; developer remains responsible; flag AI-generated code and document tools used; ask for security-critical unit tests incl. negative tests; verify suggested packages exist (slopsquatting risk), use official package managers, pin versions, generate SBOM (SPDX/CycloneDX); never put secrets in code; pin CI action versions and run scans on CI/IaC. — [OpenSSF AI guide](https://best.openssf.org/Security-Focused-Guide-for-AI-Code-Assistant-Instructions)
- Other projects' policies (secondary, via search, except the kernel): Linux kernel allows AI-assisted contributions; AI agents must not add `Signed-off-by`, and contributors should be transparent about tool use in cover letters and changelogs (verified after review against [coding assistants](https://docs.kernel.org/process/coding-assistants.html) and [tool-generated content](https://docs.kernel.org/process/generated-content.html); neither page names an `Assisted-by:` trailer); Gentoo forbids content created with natural-language AI tools (April 2024 council motion, per the codenote.net roundup; corrected after review: an earlier "requires disclosure (GLEP 76)" was wrong, and GLEP 76 as fetched does not mention AI); Cloud Hypervisor (an LF project) declines LLM-generated contributions; OpenTelemetry's genai policy extends the LF guidance; RedMonk (2026-02-26) says DCO is the emerging legal mechanism. — [RedMonk analysis](https://redmonk.com/kholterhoff/2026/02/26/generative-ai-policy-landscape-in-open-source/) (snippet only, not opened)
- opensource.guide /legal/ has an AI item in the company-project legal checklist (understand licensing agreements and legislation around AI models; corrected after review: paraphrase, not a quotation). — [Legal](https://opensource.guide/legal/)

### Inferences

- Concrete checkable AI practices from institutions: AGENTS.md at root with build/test/style/security sections; contribution policy stating whether AI-assisted PRs are accepted and requiring human review/accountability; optional Generated-by/Co-authored-by trailer; no secrets in prompts/instruction files; CI + review still apply to agent output.
- Chat-time summaries of third-party policy coverage (Gentoo) are unverified against primary docs; the kernel summary was checked after review.

### Gaps

- Did not read the LF/OpenSSF "AI PR survey" (secondary blog cited an Oct 2026 survey: unverified, excluded). Did not verify GitHub's own AI contribution/agent guidance, or Mozilla/OpenSSF OSPS AI items.

## 6. What sources say is optional or overkill for small/early projects

### Takeaway

Explicit "skip" statements are few. opensource.guide says an elaborate CONTRIBUTING, style guide, and heavy contributor agreements are not needed early and that templates are optional; OSPS Baseline's maturity levels and CNCF's sandbox tier are the formal mechanisms for deferring practices.

### Cited Findings

- Not needed early: full style guide, elaborate CONTRIBUTING (can be simple), templates (suggested only), company-specific items (marketing plan, budget, multiple admins). — [Starting a project](https://opensource.guide/starting-a-project/)
- Contributor agreements usually unnecessary; heavy agreements can discourage contributors; legal entity unnecessary unless money involved. — [Legal](https://opensource.guide/legal/), [Leadership](https://opensource.guide/leadership-and-governance/)
- Governance: no perfect time; behavior and contribution-process docs worthwhile from launch; formal roles/GOVERNANCE.md as the project grows; BDFL is a normal model for small projects. — [Leadership](https://opensource.guide/leadership-and-governance/)
- Keep tooling/standards lean; excessive rules raise barriers; early stage = decisions on own preference. (Implied, not an explicit skip list per the fetch.) — [Best practices](https://opensource.guide/best-practices/)
- Baseline defers to L2 (2+ maintainers): signed releases, CI tests, DCO-style assertion, CVD policy with timeframe, PVR, member/role docs; to L3 (large user base): SBOM, non-author approval, threat modeling, SAST/SCA gates, VEX, secrets policy. — [Baseline](https://baseline.openssf.org/versions/2026-02-19)
- Many Baseline L1 documentation controls are phrased "after a release" (user guide, defect-reporting guide). — [Baseline](https://baseline.openssf.org/versions/2026-02-19)
- CNCF sandbox is an entry tier "not required to undergo due diligence"; heavier criteria belong to incubation/graduation (criteria not retrieved). — via search summary of [CNCF lifecycle](https://contribute.cncf.io/projects/lifecycle/)
- Scorecard cannot assess "Maintained" for projects under 90 days; Contributors check needs 3+ orgs, so it is unattainable solo. — [Scorecard checks](https://github.com/ossf/scorecard/blob/main/docs/checks.md)

### Inferences

- Items most likely to be flagged overkill for a solo, pre-code repo: SBOM, signed releases/SLSA, fuzzing, reproducible builds, CLA, formal GOVERNANCE.md, two-reviewer branch protection, CODEOWNERS-required-review, REUSE headers on code that does not exist.
- Most defensible day-one checklist from these sources: LICENSE, README (4 questions), CONTRIBUTING, CODE_OF_CONDUCT, SECURITY.md with private channel (enable PVR), MFA, block direct pushes/force-push/deletion on default branch, secret scanning + push protection, Dependabot once dependencies exist, no committed secrets/binaries, public discussion channel, AGENTS.md.

### Gaps

- No institutional source found that explicitly lists "overkill for small projects" beyond the opensource.guide statements above.

## Recent changes (2025-2026) flagged

- OSPS Baseline versions 2026.02.19 and a later 2026-08-28 exist (OSPS Baseline is a recent, evolving spec; check current version before comparing). [Baseline](https://baseline.openssf.org/versions/2026-02-19)
- Apache generative-tooling guidance states it reflects August 2026. [Apache](https://www.apache.org/legal/generative-tooling.html)
- OpenSSF AI code-assistant instruction guide dated 2025-08-01. [OpenSSF](https://best.openssf.org/Security-Focused-Guide-for-AI-Code-Assistant-Instructions)
- AGENTS.md now under Agentic AI Foundation (Linux Foundation). [agents.md](https://agents.md)
- GitHub docs now place security settings under "Security and quality" / "Advanced Security" and list "AI Scan" for code scanning, and a VULNERABILITY_REPORT.yml file. [GitHub](https://docs.github.com/en/code-security/getting-started/securing-your-repository), [GitHub PVR](https://docs.github.com/en/code-security/security-advisories/working-with-repository-security-advisories/configuring-private-vulnerability-reporting-for-a-repository)
- REUSE 3.3 (2024-11) introduced REUSE.toml replacing deprecated dep5. [REUSE](https://reuse.software/spec-3.3/)
- opensource.guide security and legal pages now include SBOM, AI-related terms, threat model and incident response items (page dates not visible; recency inferred, unverified).
