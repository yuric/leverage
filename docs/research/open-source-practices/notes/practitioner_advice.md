# Practitioner advice for starting and growing an open source repository (as of 2026-11-18)

"I" in this note is the AI research agent that did this pass. Quotations were re-checked against the live pages after an adversarial review on 2026-11-19; corrections are marked "(corrected after review)".

Scope/limits: this was a time-boxed pass (~24 tool calls). AI-policy and CLA material is well sourced (several primary pages read). Early-adoption/README, solo-maintainer sustainability, docs-first, and issue hygiene are thinner and lean on secondary results; these are flagged. Search snippets for several items (McQuaid, Willison, Eghbal) were not read in full and are marked "not read". Format per finding: advice — who/where (credibility, date) — stage — reasoning — dissent.

## 1. What matters in the first weeks / what drives early adoption vs ceremony

### Takeaway

Practitioner advice that surfaced is consistent but mostly anecdotal and vendor-flavored: a first screen that says who it is for and shows an outcome (screenshot/demo), a launch on a venue where the audience already is (Show HN), and fast maintainer replies. I found no rigorous data on what causes stars; sources say launch spikes do not prove a tactic caused growth. I did not find strong primary maintainer sources on GIFs/quick-start; treat as a gap.

### Cited Findings

- Advice (day one): first README screen = one sentence on who it is for + outcome-focused screenshot/demo + obvious next step; reuse the same category phrase in repo description, README headline and launch posts. Who: DEV Community star-growth guides (author "iris1031", 2026, promotional growth playbooks; low credibility, anecdotal). Dissent/caveat: the same results note vendors selling README generators, and that fake/bought stars get detected and removed — [DEV: cold start problem](https://dev.to/iris1031/the-cold-start-problem-for-github-projects-how-to-get-your-first-1000-stars), [DEV: 7 tactics 2026](https://dev.to/iris1031/github-star-growth-7-tactics-that-still-work-in-2026-39a0)
- Advice (launch): post on Hacker News (Show HN) where audience already is; "build something worth talking about, position so people get it instantly." One developer reports 500+ stars in 24h from this; single anecdote — [DEV: 500 stars in 24 hours](https://dev.to/bobsingor/how-i-got-500-stars-in-24-hours-on-my-first-public-github-repo-1afh)
- Advice (once users arrive): fast replies increase trust and keep launch threads alive; turn recurring questions into README updates (guide-level, unattributed to a named maintainer) — [DEV: first 1000 stars](https://dev.to/iris1031/how-to-get-your-first-1000-github-stars-the-complete-open-source-growth-guide-4367)
- Will McGugan (Rich/Textual author) wrote a widely cited post on getting first 1k stars (2022; older classic). I could not retrieve it (404 on the URL tried); the contents are not verified here — [search result listing](https://www.willmcgugan.com/blog/tech/post/promoting-your-open-source-project-or-how-to-get-your-first-1k-github-stars)
- Ask HN threads on first users: PostHog's founder reportedly got first handful from friends pre-launch then a few hundred from an HN launch; HashiCorp's founder reportedly relied on meetups and word of mouth (secondhand summary, not verified at the thread) — [Ask HN: first users with zero audience](https://hn.svelte.dev/item/47800507), [first-1000-members collection](https://github.com/octolens/first-1000-members)
- Mike McQuaid (Homebrew project leader since ~2009; ~30 maintainers, ~30M users): "contributor funnel" — users progress from bad issues to good issues to simple contributions to complex contributions to maintaining; most contributors start as users fixing their own problem; maintainers should remain users. Talk OSCON 2017/FOSDEM 2018 (older classic); blog version not fully read — [McQuaid talk page](https://mikemcquaid.com/talks/why-people-dont-contribute-to-your-open-source-project/), [Changelog summary](https://changelog.com/news/e47D)
- Simon Willison and others do not appear in my retrieved material giving star/README advice (not found).

### Inferences

- Nothing found says LICENSE/CoC/CHANGELOG/templates drive early adoption; adoption advice centers on README first screen, a working demo, launch venue, and responsiveness. (Absence in my limited sample, not proof.)

### Gaps

- No primary maintainer sources on GIF/demo/quick-start, non-goals sections, or public roadmaps; no data distinguishing adoption drivers from ceremony.
- McGugan post not read; Eghbal/Asparouhova, Geerling, Ronacher, Valsorda, Nesbitt, Evan You, antirez not reached.

## 2. What is premature for a new/solo project; who argues the opposite

### Takeaway

Weak, opinion-level consensus: solo is the norm, governance can stay minimal (single-maintainer model), but a CoC/CONTRIBUTING is advised once you invite outside contributions. The sharpest "premature" argument I found is not about docs but about the contribution model itself (tldraw/Ruiz: outside code has little value now).

### Cited Findings

- A secondary guide said most projects run on one to three active maintainers and called the single-maintainer model simple but a single point of failure (paraphrase; the page was gone when re-checked after review, so this is unverified) — [secondary guide, 2025](https://www.mintlify.com/opensource-together/opensource-together/learning/maintainer-guide). A "61% maintain alone" figure attributed to Tidelift is not on the DEV summary previously cited for it and has been dropped (corrected after review).
- Code of conduct timing, disagreement: Fred Hallstrom (GitHub interview, date not checked): have one if you want any outside contributions, skip if staying solo; other GitHub pieces say many maintainers think it can wait until conflict arises; another calls it "a must have"; Linux Foundation blog recommends early CoC while decentralizing power over time — [GitHub Blog: what to do when project becomes a community](https://github.blog/open-source/maintainers/what-to-do-when-your-open-source-project-becomes-a-community/), [LF: lessons from maintainers](https://www.linuxfoundation.org/blog/lessons-from-maintainers-of-the-worlds-most-critical-software)
- Blog commentary describes CONTRIBUTING.md as the first file that makes a maintainer state what they want from contributors (paraphrase; the earlier quotation was not found on the page when re-checked) — [Weight of the Green Merge Button, 2025](https://blog-5f3.pages.dev/posts/2025-09-22-best-practices-open-source-maintainers)
- Steve Ruiz (tldraw founder/CEO), 2026-01-17: his AI-driven issue generator produced plausible-but-wrong issues which contributors' AIs then "fixed"; PRs ignored templates, CLAs and codebase patterns; he argues that when bad work is virtually indistinguishable from good, "the value of external contribution is probably less than zero", and wants outside help limited to reporting and discussion (corrected after review) — [Stay away from my trash](https://tldraw.dev/blog/stay-away-from-my-trash)
- Premature templates/heavy CI: no direct practitioner source found. Curl's Stenberg says PRs are not a major problem because tests and CI catch low-quality contributions (i.e. CI is cited as valuable at scale) — [curl bounty post](https://daniel.haxx.se/blog/2026/01/26/the-end-of-the-curl-bug-bounty/)

### Inferences

- A docs-only repo with CoC/CONTRIBUTING/CODEOWNERS before users and code is, per the sources found, not harmful but not an adoption driver; the live tension is whether to invite PRs at all in the AI era.

### Gaps

- Nothing found on semver-before-1.0, changelogs, Discord/Slack, steering committees, or issue-template elaborateness from named practitioners.

## 3. CLA vs DCO vs nothing; relicensing lessons

### Takeaway

No recommendation found for CLA on a small MIT project. Credible commentators split: DeVault (DCO preferred, CLA = relicensing warning sign, 2021) vs Kyle Mitchell (lawyer; CLAs misunderstood; relicensing never revokes past releases; permissive projects can relicense future work anyway, 2023-09-06). My own reading, not Mitchell's: under MIT with inbound=outbound, a CLA adds little beyond relicensing flexibility, and Mitchell notes that even without a CLA a permissively licensed project can change terms for new work.

### Cited Findings

- Drew DeVault (SourceHut founder; 2021-04-12): adopt DCO not CLA; under DCO contributors keep copyright and project cannot relicense on new terms; CLA is "a promise that one day the stewards … will take your work"; he avoids CLA projects (names Go) — [DCO is a great alternative to a CLA](https://drewdevault.com/blog/DCO/). Note: stronger claim than Mitchell's; contested for permissive licenses (below).
- Kyle E. Mitchell (open source licensing lawyer; 2023-09-06, after HashiCorp BSL change): CLA is a license not an assignment; relicensing does not revoke earlier releases; projects without CLA can still change terms for new work, especially under permissive licenses; skipping a CLA is most sensible when copyleft, using DCO, and accepting unverified-rights risk; criticizes overbroad "further assurances" terms — [Real and Imagined CLA Overreach](https://writing.kemitchell.com/2023/09/06/Actual-CLA-Overreach)
- CHAOSS study (via The Register, 2025): for Elastic and HashiCorp most contributions were internal so relicensing barely moved contributors; Redis had many external contributors and the fork (Valkey) was foundation-backed — [The Register](https://www.theregister.com/2025/02/24/open_source_licensing/), [The New Stack](https://thenewstack.io/what-happens-to-relicensed-open-source-projects-and-their-forks/). OpenSearch chose DCO (DeVault link above).
- Lesson claimed by secondary guides: the decision must be made before outside contributions accumulate; cannot add a CLA retroactively without re-consenting contributors (inference; 2026 blog guides not verified) — [Beancount CLA vs DCO guide, 2026-10](https://beancount.io/blog/2026/10/13/cla-vs-dco-contributor-agreement-open-source-project-guide)
- Interaction with AI: QEMU declines AI-derived code because DCO clauses (b)/(c) cannot be honored for AI output (2025-06); Linux says AI agents must not add Signed-off-by, humans own DCO — see section 5.

### Inferences

- If you intend ever to dual-license/commercialize, the real decision is before first external merge; with only MIT, solo, and no external merges, no document is needed yet, and DCO is the lightweight reversible default.

### Gaps

- Did not find a lawyer-blog source specifically on MIT + CLA for a tiny project; Redis/Elastic CLA texts not read.

## 4. Maintainer sustainability

### Takeaway

Consensus: owe users nothing, set expectations, say no, protect scope. Data (Tidelift, secondhand): 60% call themselves unpaid hobbyists (2024 survey, via The Register); almost 60% quit or considered quitting (late-2022 survey, via DEV). My retrieval of McQuaid/Eghbal primary text was incomplete.

### Cited Findings

- Tidelift maintainer surveys (secondary summaries, corrected after review): the DEV post (2023-05-25) on the late-2022 survey reports 58% quit (22%) or considered quitting (36%) — [DEV/Tidelift summary](https://dev.to/tidelift/maintainer-burnout-is-real-almost-60-of-maintainers-have-quit-or-considered-quitting-maintaining-one-of-their-projects-51ma); The Register on the 2024 survey reports 60% calling themselves unpaid hobbyists — [The Register](https://www.theregister.com/2024/09/18/open_source_maintainers_underpaid/). No source read gives a share who maintain alone. Did not locate 2025/2026 Tidelift data.
- Mike McQuaid: "Open Source Maintainers Owe You Nothing" and FOSDEM 2024 "boundaries, burnout, business" (titles confirmed, text not read); OSI profile: don't open PRs you aren't willing to finish — [post](https://mikemcquaid.com/open-source-maintainers-owe-you-nothing/), [FOSDEM 2024 slides](https://archive.fosdem.org/2024/events/attachments/fosdem-2024-2029-open-source-in-2024-boundaries-burnout-business/slides/22591/Open_Source_-_boundaries_burnout_business_jSoCbxc.pdf), [OSI profile](https://opensource.org/maintainers/mikemcquaid)
- Brett Cannon (snarky.ca, CPython core dev) has a post "Setting expectations for open source participation" (title seen, not read) — [Cannon, "Setting expectations for open source participation"](https://snarky.ca/setting-expectations-for-open-source-participation/)
- Jazzband sunset its collaborative model 2026-03-14 citing AI spam — [announcement](https://jazzband.co/news/2026/03/14/sunsetting-jazzband)
- Ghostty/Mitchell Hashimoto moved toward a nonprofit model and left GitHub April 2026 over instability (secondary) — [Hashimoto](https://mitchellh.com/writing/ghostty-leaving-github)

### Gaps

- No funding (Sponsors/Open Collective) practitioner advice retrieved; no entitled-user handling beyond McQuaid titles.

## 5. AI-era: AI PRs/issues, policies, AGENTS.md, bots, building with agents

### Takeaway

Strongest-evidence section. Policies form a spectrum: bans (Gentoo, NetBSD, QEMU, Zig), disclosure+accountability (Ghostty, Linux, Fedora, LLVM, typescript-eslint), and structural closure of intake (tldraw, Ghostty vouching, llama.cpp limits, curl bounty). Maintainers say what works is explicit enforceable rules, human accountability, narrowing inbound channels, and iteration. Most policies target external contributors; maintainers using AI heavily (Ghostty, tldraw) are exempt.

### Cited Findings

All from the secondary roundup [codenote.net, 2026](https://codenote.net/en/posts/oss-ai-slop-contribution-policy-shift/) unless a primary is listed (primary URLs given in that page, not independently fetched except where noted):

- Gentoo ban (April 2024); NetBSD: LLM-generated code "presumed to be tainted code", not to be committed without prior written core approval (May 2024; the roundup groups it with bans); QEMU declines AI-derived contributions (June 2025, DCO rationale); Zig LLM ban (undated); Cloud Hypervisor restriction (Sept 2025).
- Linux kernel: AI allowed; AI agents must not add `Signed-off-by`; the human submitter reviews the code and takes responsibility ([coding assistants](https://docs.kernel.org/process/coding-assistants.html)); contributors should be transparent about tool use in cover letters and changelogs ([tool-generated content](https://docs.kernel.org/process/generated-content.html)). The roundup also describes an `Assisted-by:` trailer, but neither kernel page read on 2026-11-19 mentions one, so that claim is dropped (corrected after review); LLVM: bans autonomous PR agents and AI on Good First Issues ([llvm.org](https://llvm.org/docs/AIToolPolicy.html)); Fedora (Oct 2025) accountability/transparency; WordPress and Django policies; typescript-eslint (2026-01-20) cannot ban but requires author understanding and human-written prose; NewPipe (2025-12-16) "I did not generate this with AI" checkbox in templates; llama.cpp tightened roughly monthly Nov 2025 to Mar 2026, bans AI PR descriptions/issues, one open PR for new contributors, explicit account bans.
- Ghostty (primary fetched): AI_POLICY.md requires disclosing tool and extent, ability to explain the change without AI, human-edited AI text in issues, no AI media, public denouncement of slop; applies to outside contributors only, and maintainers are exempt; the strict rules hold "until either the people get better, the AI gets better, or both"; the policy says it is not due to an anti-AI stance (corrected after review: two earlier quotations were not on the page) — [AI_POLICY.md](https://github.com/ghostty-org/ghostty/blob/main/AI_POLICY.md). Per the roundup: PR #8289 disclosure (2025-08-19), drive-by AI PRs barred unless tied to accepted issue (2026-01-22), vouch system (2026-02-15) ([mitchellh/vouch](https://github.com/mitchellh/vouch)).
- curl (Stenberg, primary 2026-01-26): bounty ended 2026-01-31; confirmed-report rate >15% earlier years to <5% in 2025; 87 confirmed vulns, >$100k paid since 2019; reports via GitHub private vulnerability reporting or email; AI-slop submitters banned; PRs not a major problem because tests/CI catch them — [The end of the curl bug bounty](https://daniel.haxx.se/blog/2026/01/26/the-end-of-the-curl-bug-bounty/). Nuance (secondary): Stenberg accepts good AI-assisted findings (Joshua Rogers' work) — [The Register](https://www.theregister.com/2026/01/21/curl_ends_bug_bounty/). Note: aggregator figures differ ($86k/78 vulns Bugcrowd vs $100k/87 curl) — prefer curl's own post.
- tldraw (Ruiz, 2026-01-17): announced it would soon begin automatically closing external PRs; issues/discussions stay open; internally uses AI; "If you know the codebase and know what you're doing, writing great code has never been easier than with these tools" (quotation corrected after review) — [post](https://tldraw.dev/blog/stay-away-from-my-trash); later reiterated (secondary) — [Latent Space](https://latent.space/p/pr-not-welcome)
- Unverified (corrected after review): the following two items were read from Simon Willison's tag page, which changes as he posts, and neither could be found there when re-checked on 2026-11-19. SQLite reportedly declines agent-written code but accepts agent-generated bug reports with reproducible test cases and demonstration patches — [simonwillison.net coding-agents](https://www.simonwillison.net/tags/coding-agents/); Willison reportedly said the AI PR flood is not a problem for his LLM project. Separately verified: "vibe engineering" = accountable AI use ([2025-10-07](https://simonwillison.net/2025/Oct/7/vibe-engineering/)).
- GitHub added maintainer controls (disable PRs, collaborator-only PRs) — [GitHub blog "eternal September"](https://github.blog/open-source/maintainers/welcome-to-the-eternal-september-of-open-source-heres-what-we-plan-to-do-for-maintainers/)
- AGENTS.md/CLAUDE.md (mostly SEO/vendor blogs, low credibility): keep short (one cites <200 lines), cut generic advice, use AGENTS.md as shared file for multi-agent contributors, maintainers can encode norms (e.g. reserve "good first issue" for humans) into contributors' agents; conflicting claims on whether Claude Code reads AGENTS.md natively (unverified; check Anthropic docs); "60,000+ repos use AGENTS.md" is unverified marketing — [Non-Convex Labs](https://hn.jakechampion.name/reader/https://nonconvexlabs.com/blog/oss-maintainers-can-inject-their-standards-into-contributors-ai-tools), [mac.install.guide](https://mac.install.guide/ai/agent-instructions/best-practices)
- Disagreement: Ghostty/Zig/QEMU/Gentoo restrict AI vs typescript-eslint/Linux/Willison accept with accountability; Ruiz argues detection is moot because outside code lost value.

### Inferences

- For a solo AI-agent-built repo: an AI policy for inbound contributors (disclosure + must-understand + human-written issue text) is the cheapest widely copied pattern; also plan for the option to restrict PRs later.

### Gaps

- No practitioner write-up on "building in public with AI agents" found; AI bots in issue triage not covered; LLVM/Zig/Gentoo primary pages not fetched.

## 6. Security minimum for small projects

### Takeaway

Only supply-chain material found: tj-actions/changed-files compromise (March 2025, CVE-2025-30066) — tags were rewritten, SHAs were not; pin third-party Actions to full commit SHA and automate bumps.

### Cited Findings

- Pin to full-length SHA, verify the SHA belongs to the action's repo and not a fork; Renovate/pinact can maintain pins; Dependabot alerts do not cover SHA-pinned actions; SHA pin does not cover nested actions — secondary vendor blogs: [Lullabot ADR 2026-05](https://architecture.lullabot.com/adr/20260505-pin-github-actions-to-hash/), [Socket](https://socket.dev/blog/hardening-github-actions-against-outside-threats), [DEV: pin to SHA](https://dev.to/suzukishunsuke/pin-github-actions-to-a-full-length-commit-sha-for-security-2n7p), [platformengineering.org: beyond SHA pinning](https://platformengineering.org/blog/beyond-sha-pinning-why-immutability-isnt-provenance-in-github-actions)
- Private reporting: curl moved all security reports to GitHub Private Vulnerability Reporting (see section 5).

### Gaps

- Not retrieved: practitioner views on 2FA, secret scanning, what can wait, 2025-26 incidents beyond tj-actions (e.g. npm worm incidents); no solo-maintainer-specific minimum list.

## 7. Docs-first / requirements-first in public

### Takeaway

Mixed and thin. Pro: lightweight spec/decision records force clarity, especially with AI agents. Con: "Spec-Driven Development Considered Harmful" argues detailed specs before a cheap prototype are premature commitment. Middle: short problem/non-goals/acceptance docs for hard-to-reverse decisions.

### Cited Findings

- Counter: [Spec-Driven Development Considered Harmful](https://levelup.gitconnected.com/spec-driven-development-considered-harmful-76b2d2d90c8e) (author/date not verified)
- Pro/solo: lightweight solo RFC (one dated file in docs/decisions) — [tessl solo-rfc](https://tessl.io/registry/nickrowlandocom/solo-rfc); Dan Vega on spec-driven development for solo developers — [danvega.dev](https://www.danvega.dev/blog/spec-driven-development-solo-developers)
- No maintainer of a well-known project found recommending publishing a PRD before code.

### Gaps

- No evidence on whether public PRDs draw users/contributors; no pitfalls beyond blog opinion.

## 8. Issue tracker hygiene

### Takeaway

Stale-bot auto-closing is the contested part; consensus among critics is label/nudge but close manually. Little else retrieved.

### Cited Findings

- Gutenberg discussion: auto-close most controversial; consensus leaned to label/triage and close manually — [WP Tavern](https://wptavern.com/gutenberg-contributors-consider-implementing-a-bot-to-close-stale-issues)
- Drew DeVault, "GitHub stale bot considered harmful" (2021-10-26, older; full text not read, prefers mailing-list workflows) — [engineered.at mirror](https://engineered.at/articles/github-stale-bot-considered-harmful-51e139ce-4be6-4d63-9a86-33d1f2a0eff9)
- Critics (forum/issue threads, mixed ages): closing signals "we don't care," increases duplicates, discourages newcomers — [Dgraph](https://discuss.dgraph.io/t/constructive-criticism-on-issue-handling/19825), [Frappe](https://discuss.frappe.io/t/please-stop-automatically-closing-github-issues/90596), [actions/stale #1122](https://github.com/actions/stale/issues/1122). Defender: reduces issue count to focus (Meteor forum). Compromises: longer warning, friendly wording, never-stale label. Recent complaint on Anthropic's Claude Code tracker: stale-closed unreviewed issues — [claudeissues.com](https://claudeissues.com/issue/39980-meta-zero-maintainer-engagement-on-community-reported-bugs-stale-bot-closes-issu)
- LLVM bans AI on Good First Issues to protect newcomer path (section 5).

### Gaps

- Nothing retrieved on labels taxonomy, good-first-issue efficacy, Discussions vs Issues, project boards.
