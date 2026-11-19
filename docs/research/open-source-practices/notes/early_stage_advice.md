# Early-stage open source advice from named maintainers (partial pass)

"I" in this note is the AI research agent that did this pass. Quotations in it were re-checked against the live pages after an adversarial review on 2026-11-19.

Scope note: tool budget was exhausted before several sub-questions were reached. Everything below was read via page fetch (summarised by the fetch tool, not read verbatim) unless labelled "search snippet" or "secondhand". Coverage is thin; see Gaps in each section.

## README and first impressions

### Takeaway

Not covered. No primary-source README advice from a named maintainer was reached in this pass.

### Cited Findings

- (none)

### Inferences

- (none)

### Gaps

- No fetches made on README content, quick start, demo, non-goals, or honest maturity labelling. Not researched: Stenberg, Willison, Hashimoto, or others on this.

## Setting expectations and sustainability

### Takeaway

McQuaid, Cannon and Geerling converge on one stance: maintainers owe users nothing, so write down and enforce what you will and will not do. Filippo Valsorda's maintenance-policy file is the most concrete example of doing so. Opinion throughout, not data. Eghbal was not reached.

### Cited Findings

- Mike McQuaid (Homebrew), "Open Source Maintainers Owe You Nothing", 19 Mar 2018. Licences disclaim warranty, so maintainers owe nothing to users, contributors or other maintainers. Burnout often comes from treating OSS as a business-customer relationship. Advice: stop work you no longer enjoy, block rude users, do not feel guilty about bugs. Opinion based on his experience. — [McQuaid](https://mikemcquaid.com/open-source-maintainers-owe-you-nothing/)
- Brett Cannon (CPython core dev), "Setting expectations for open source participation", 6 Sep 2018 (expands his Python US 2018 keynote). Once a project accepts outside contributions it exists for collaborative maintenance and enjoyment. Accepting a patch means taking on long-term upkeep. Nobody is owed a fix, merge or reply. Maintainers can step away from heated threads and wait hours or days. He gives no checklist; the support/scope/response-time items are the fetch summariser's inference. Opinion. — [Cannon](https://snarky.ca/setting-expectations-for-open-source-participation/)
- Cannon's follow-up "The social contract of open source" (search snippet only, not read): maintainers owe users nothing about code, and mistreating them is unethical. Paul Boddie's blog (snippet only) says Cannon's framing falls short of free-software ideals; this is the only disagreement found. — [snarky.ca](https://snarky.ca/the-social-contract-of-open-source/)
- Filippo Valsorda (Go crypto maintainer), 6 Apr 2024: wrote a short maintenance policy linked from CODE_OF_CONDUCT, CONTRIBUTING and SECURITY, purely "setting expectations". It covers his batched work cycles, narrow project scope, a preference for detailed issues over PRs (PRs are often reimplemented), funding, conduct and security reporting. Opinion plus practice. — [Valsorda](https://words.filippo.io/maintenance-policy/)
- Jeff Geerling (Ansible roles maintainer), "Just Say No", 29 Nov 2022. Rule: "Be liberal with your 'no', be judicious with your 'yes'." Each yes is paid back later, often as burnout. Decline PRs or issues that are too large, pull the project in an unwanted direction, or exceed capacity. Use a stale bot and close without locking. Unpaid users are owed no support, and people can fork. Opinion based on experience. — [Geerling](https://www.jeffgeerling.com/blog/2022/just-say-no/)
- Geerling, via search snippet only (not read in full): sees 50-100 issue/PR emails a day, merges 5-10 PRs a month, reads each PR before closing, and credits the stale bot plus a relaxed attitude as his best burnout prevention. Also reports he moved to full-time OSS work after saying no more. — [Geerling tags](https://jeffgeerling.com/tags/maintainer)

### Inferences

- For a solo maintainer, the shared message is to decide "no" defaults before demand arrives. Valsorda's single linked policy file is a lighter alternative to separate CONTRIBUTING/SECURITY/CoC prose.
- Geerling and Valsorda both push toward issues-over-PRs, which fits a GitHub-issues-managed repo.

### Gaps

- Not reached: Eghbal / Asparouhova "Working in Public" (two searches returned only stadium-architecture results; nadia.xyz URL I guessed was 404; workinpublic.xyz did not resolve), so the stadium/club/federation/toy taxonomy and attention-scarcity claims are unverified here. McQuaid's FOSDEM talks not read. Cannon's 2023 URL guess failed. Geerling's "burden of an open source maintainer" (2022) and "Why I close PRs" (2016) not read directly.

## Premature ceremony (governance, RFCs, Discord, templates, CoC, changelogs, versioning)

### Takeaway

Almost nothing reached. Only a versioning satire source was read, and it is not practitioner advice.

### Cited Findings

- ZeroVer (0ver.org) is satire (dated 1 Apr 2018, repo github.com/mahmoud/zerover). It is not a serious versioning standard, so should not be cited as a criticism with weight. — [0ver.org](https://0ver.org/)
- Valsorda's policy file (above) is a case for consolidating CoC/CONTRIBUTING/SECURITY into one short statement rather than elaborate separate documents. This is my reading of his stated purpose, not his claim. — [Valsorda](https://words.filippo.io/maintenance-policy/)

### Inferences

- No evidence collected either for or against adding governance/RFC/Discord/changelog early.

### Gaps

- No practitioner sources on governance docs, steering committees, RFC processes, roadmaps, chat servers, issue templates, CoC timing, changelog timing, SemVer vs 0.x vs CalVer. Entire sub-question open.

## Scope control and saying no

### Takeaway

Only Geerling and Valsorda reached (see above). Others (Ronacher, antirez, Evan You, Hashimoto, Willison, Nesbitt, Stenberg) not read.

### Cited Findings

- Geerling's liberal-no rule and Cannon's point that accepting a contribution means years of upkeep (he likens it to being handed a puppy; paraphrase, corrected after review) are the relevant claims; see Setting expectations section for sources. — [Geerling](https://www.jeffgeerling.com/blog/2022/just-say-no/); [Cannon](https://snarky.ca/setting-expectations-for-open-source-participation/)
- Valsorda: narrow scope for most projects; prefers detailed issues over PRs. — [Valsorda](https://words.filippo.io/maintenance-policy/)
- Valsorda on paid maintenance (search snippets, secondhand from Geomys/Valsorda pages): left Google in 2022, full-time independent maintainer by 2023, runs Geomys, funded by company retainers; reportedly does not solicit individual donations because he does not depend on crowdfunding. — [Valsorda dispatch](https://words.filippo.io/dispatches/geomys/); [Geomys](https://geomys.org/)

### Inferences

- Paid-maintenance model is relevant to later phases, not day one.

### Gaps

- "No is temporary, yes is forever" attribution, Ronacher, antirez, Evan You, Hashimoto, Nesbitt, Stenberg: not searched.

## Requirements-first / design-doc-first in public, and spec-driven development with agents

### Takeaway

One strong critical first-hand account: Birgitta Böckeler (Thoughtworks, hosted on martinfowler.com, 15 Oct 2025) finds current spec-driven tooling heavy in ceremony and review burden, though she endorses spec-first as an idea. No first-hand account of a maintainer publishing a PRD/RFC before any code was found.

### Cited Findings

- Böckeler, 15 Oct 2025. Tried Kiro, spec-kit and Tessl by hand. Spec-first is valuable and she writes specs before prompting agents. But SDD is poorly defined ("spec" often means "detailed prompt"). Kiro turned a small bug fix into 4 user stories and 16 acceptance criteria ("sledgehammer to crack a nut"). Spec-kit produced verbose repetitive markdown that was tedious to review; the agent ignored research notes about existing classes and created duplicates. Tessl showed non-determinism from the same spec. She would rather review code than these documents, and warns spec-as-source may combine model-driven-development inflexibility with LLM non-determinism. First-hand tool testing, opinion, not data; small samples. — [Böckeler](https://www.martinfowler.com/articles/exploring-gen-ai/sdd-3-tools.html)

### Inferences

- Böckeler's critique targets tool-generated spec volume; a short hand-written PRD is closer to what she says she does herself. A reasonable but unconfirmed reading.

### Gaps

- No public-PRD-before-code case study found. No positive first-hand SDD accounts retrieved. Only search snippets (secondhand) from other critics.

## Building with AI coding agents in the open

### Takeaway

Willison, Ronacher and Hashimoto agree that agent productivity depends on verification loops (tests, CI, runnable tools) and that instruction files should grow from observed failures. All first-hand opinion; no quantitative data.

### Cited Findings

- Simon Willison, "Vibe engineering", 7 Oct 2025: lists automated tests, comprehensive documentation, CI with formatting and linting, preview environments, a culture of code review, version control and manual QA as prerequisites. Without a solid suite an agent may claim code works without testing it. — [Willison](https://simonwillison.net/2025/Oct/7/vibe-engineering/)
- Willison, "Designing agentic loops", 30 Sep 2025: works best with clear success criteria; a solid automated test suite greatly increases agent value; keep an AGENTS.md showing how to use tools (one example often suffices); run YOLO mode only in sandboxes/containers; give agents only test/staging credentials with tight budget limits. — [Willison](https://simonwillison.net/2025/Sep/30/designing-agentic-loops/)
- Armin Ronacher (Flask), "Agentic Coding Recommendations", 12 Jun 2025: choose languages where tests are easy to run and cache (Go example); put key commands in a Makefile; make tools fast with clear errors; log to files the agent can read; prefer plain functions, plain SQL; be conservative with dependency upgrades and prefer generating code over adding dependencies; avoid shared state to allow parallel agents; refactor before complexity outgrows the agent. CLAUDE.md is mentioned only in passing. — [Ronacher](https://lucumr.pocoo.org/2025/6/12/agentic-coding/)
- Mitchell Hashimoto (Ghostty), "My AI Adoption Journey", 5 Feb 2026 (date per fetch result): give agents a way to verify their work; split planning from execution; "harness engineering" = whenever an agent errs, fix it permanently by adding a line to AGENTS.md or a scripted tool (paired with an AGENTS.md note); uses end-of-day agents for triage that produce reports only and never reply; runs a background agent ~10-20% of the day. — [Hashimoto](https://mitchellh.com/writing/my-ai-adoption-journey)

### Inferences

- A docs-only repo can seed AGENTS.md with build/test commands and grow it from incident notes, per Hashimoto; this needs code to exist before the test/CI advice applies.

### Gaps

- Not reached: Huntley, Yegge, Steinberger, small-PR and disclosure practices, AGENTS.md vs CLAUDE.md conventions, review-burden accounts.

## Funding basics

### Takeaway

Only survey data and Valsorda's stance found; no practitioner advice on day-one vs later setup of Sponsors/FUNDING.yml.

### Cited Findings

- Tidelift 2024 State of the Open Source Maintainer (about 400+ respondents, Sept 2024; Tidelift notes its t-shirt incentive may skew geography): maintainers "largely receive income from" donations (e.g. GitHub Sponsors, 25 percent), company salaries covering maintenance (24%) and Tidelift (19%); direct company payments 5%, foundations 3%, government 1%. The Register does not say whether these are shares of income or of maintainers (corrected after review). 60% call themselves unpaid hobbyists; 47% unpaid. Data (vendor survey, self-selected). — [The Register](https://www.theregister.com/2024/09/18/open_source_maintainers_underpaid/); [Business Wire release](https://www.businesswire.com/news/home/20240917030299/en)
- Same report: security work is 11% of maintainer time (4% in 2021); 66% trust non-maintainer PRs less since the xz backdoor; 64% would be less inclined to accept PRs from contributors known to use AI tools (Register). Almost 60% quit or considered quitting a project (secondhand via Sonar summary in search results, not verified against the original). — [The Register](https://www.theregister.com/2024/09/18/open_source_maintainers_underpaid/); [Sonar summary](https://www.sonarsource.com/resources/library/open-source-maintainers/)

### Inferences

- Even the largest listed source, donations, is reported at only 25% (of income or of maintainers; the summary is ambiguous), which gives no support for expecting early revenue from Sponsors.

### Gaps

- No timing advice on FUNDING.yml; no per-project Sponsors outcome reports.

## Data on adoption and contributor retention

### Takeaway

Nothing retrieved on README quality, response time, CONTRIBUTING files or good-first-issue effects, Octoverse, or academic studies.

### Cited Findings

- (none beyond Tidelift above)

### Gaps

- Octoverse 2025/2026, arXiv/academic studies, Linux Foundation research: not searched.
