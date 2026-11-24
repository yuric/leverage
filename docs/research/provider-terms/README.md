# Provider terms check

This is the record of what four providers' published documents say about the
three things Leverage does with a subscription login, read on 2026-11-18.

> **Snapshot, 2026-11-18.** The reading was done by AI agents (Claude): one
> reader per provider, then a second reader who opened every cited page again.
> The Antigravity FAQ and the Claude Code compliance page were opened a third
> time, on 2026-11-19, by a separate reviewer. It has not been checked line by
> line by a person. It reports what the documents say, in paraphrase. It is
> not legal advice, and providers change their terms.

## What was asked

Leverage starts each provider's own command-line tool on the owner's Mac,
signed in with the owner's own subscription, and gives it tasks. It lets the
owner connect more than one login of the same provider and moves work to the
next one when a limit is reached. It never copies a login out of the
provider's tool. So each provider's documents were read for three questions:

1. **Driven by another app.** May a subscription login be used through the
   provider's own tool when another program starts and scripts that tool?
2. **Several accounts.** May one person hold several accounts, and is
   switching between them to continue past a usage limit addressed?
3. **Credential handling.** What do the documents say about other software
   storing, reading or passing on a login?

## Summary

| Provider | Driven by another app | Rotating accounts past a limit | Other software handling the login |
| --- | --- | --- | --- |
| Anthropic (Claude) | Allowed with conditions | Unclear | Not allowed |
| OpenAI (Codex) | Allowed with conditions | Unclear | Allowed with conditions |
| Google (Gemini) | Not allowed | Not allowed | Not allowed |
| xAI (Grok) | Unclear | Unclear | Allowed with conditions |

Confidence is medium for Anthropic (high on credential handling), medium for
OpenAI (low on rotating accounts), high for Google and low for xAI. The
reasons are under each provider.

This record holds findings only. Decisions made from them belong in
[the PRD](../../PRD.md).

## Anthropic (Claude)

- **Driven by another app: allowed with conditions.** Claude Code documents a
  non-interactive mode and a long-lived subscription token for scripts and
  CI, and a help article says such use draws on the plan's limits. The
  consumer terms, however, bar automated access unless it uses an API key or
  Anthropic permits it. The Claude Code compliance page says subscription
  sign-in is meant for "ordinary use" of Claude Code and Anthropic's own
  apps, that developers building products should use API keys, and that
  third parties may not offer Claude sign-in or route requests through plan
  logins for their users. The usage policy also bars services that route
  requests through consumer subscriptions, and the Agent SDK overview says
  third parties may not offer Claude sign-in or rate limits in their products
  unless approved. The page on running Claude Code from scripts says a mode
  that never reads the subscription login is recommended for scripted use and
  will become the default for the non-interactive mode in a future release.
  The compliance page also says nothing stops a person from signing in to the
  unmodified Claude Code program with their own subscription. No document
  addresses a local app that a person runs to drive the unmodified tool under
  their own login.
- **Rotating accounts: unclear.** Claude Code documents staying signed in to
  several accounts at once, for example work and personal, each with its own
  configuration folder. The usage policy bars creating several accounts to
  get around product guardrails, and bars bypassing restrictions built into
  the products; no document says whether a usage limit is a guardrail or a
  restriction in that sense. The compliance page says the advertised plan
  limits assume ordinary, individual use. No document says whether moving to
  a second account at a limit counts. The first reader's verdict was allowed
  with conditions; the second reader's, reported here, is unclear.
- **Other software handling the login: not allowed.** The consumer terms bar
  sharing a login or making the account available to anyone else. The
  compliance page says developers may not collect, store or pass on Claude
  logins or session tokens, and that sign-in must go through Anthropic's own
  flow. Claude Code keeps the login in the macOS Keychain, one entry per
  configuration folder. A login that stays in Claude Code's own store and
  that no other program reads is consistent with these texts; the verdict
  applies to an app that handles the login, not to the person's own login
  staying there. The readers judged that an app which itself holds the
  long-lived token would be storing a login in the sense of that page.
- **Sources.** Consumer Terms of Service (effective 2025-10-08),
  <https://www.anthropic.com/legal/consumer-terms>. Usage Policy (effective
  2026-11-12), <https://www.anthropic.com/legal/aup>. Claude Code
  documentation: Legal and compliance,
  <https://code.claude.com/docs/en/legal-and-compliance>; Authentication,
  <https://code.claude.com/docs/en/authentication>; Run Claude Code
  programmatically, <https://code.claude.com/docs/en/headless>; Agent SDK
  overview, <https://code.claude.com/docs/en/agent-sdk/overview>. Help
  centre, "Use the Claude Agent SDK with your Claude plan",
  <https://support.claude.com/en/articles/15036540-use-the-claude-agent-sdk-with-your-claude-plan>.
- **Not verified.**
  - The Claude Code documentation pages show no date. The help article shows
    only a relative update time and dated update notes (2026-06-15 and
    2026-10-07), not an exact last-updated date.
  - The Commercial Terms, the Trademark Guidelines and the help article on
    using Claude Code with Pro or Max plans were not read again in this
    check.
  - No document says whether a local app that a person runs may start the
    unmodified tool under that person's own login. The consumer terms'
    exception for uses Anthropic otherwise permits could not be tied to a
    specific permission for scripted use, beyond the long-lived token page
    naming scripts.
  - No document says whether a usage limit counts as a guardrail or
    restriction under the usage policy.

## OpenAI (Codex)

- **Driven by another app: allowed with conditions.** The Codex
  documentation presents a non-interactive mode for scripts and CI that
  reuses the saved login. It recommends API keys for automation and calls a
  subscription login in CI an advanced option for trusted private runners.
  OpenAI also documents an official route for open-source, locally hosted
  apps to run Codex on a person's own plan, called Sign in with ChatGPT, in
  which the app registers its own client and passes its own token to Codex.
  Sign in with ChatGPT appears to be in preview, and its pages send paid or
  remotely hosted apps to an interest form. No page that could be opened says
  whether an app may instead drive the Codex tool with the tool's own saved
  login. A third-party copy of the consumer terms bars automatically or
  programmatically extracting data or output; how that applies to driving
  the tool is not stated.
- **Rotating accounts: unclear.** The Sign in with ChatGPT documentation
  expects an app to hold several saved accounts and switch between them, and
  says plan usage is one total across apps. No official page that could be
  opened addresses switching accounts to continue past a limit. A
  third-party copy of the consumer terms bars getting around rate limits or
  restrictions and sharing account credentials; that wording could not be
  confirmed on OpenAI's own site, and it does not say how it applies to one
  person's own accounts.
- **Other software handling the login: allowed with conditions.** The
  documentation says the saved login, kept in a file or the system's
  credential store, must be treated like a password and never committed,
  pasted or shared, and the CI guide says one saved login file should not be
  shared across concurrent jobs or machines. That guide's ban on public or
  open-source repositories is about placing a saved login on CI runners for
  them. For other software, OpenAI points to Sign in with ChatGPT, in which
  the app keeps its own tokens in protected local storage. The pages opened
  do not address another app reading the Codex tool's saved login. A
  third-party copy of the consumer terms bars sharing account credentials.
- **Sources.** Codex documentation: Authentication,
  <https://learn.chatgpt.com/docs/auth>; Non-interactive mode,
  <https://learn.chatgpt.com/docs/non-interactive-mode>; Maintain Codex
  account auth in CI/CD, <https://learn.chatgpt.com/docs/auth/ci-cd-auth>.
  Sign in with ChatGPT for open-source apps,
  <https://developers.openai.com/siwc/token-sharing-open-source>; Codex
  app-server,
  <https://developers.openai.com/siwc/token-sharing-open-source/codex-app-server>;
  Accounts and sessions,
  <https://developers.openai.com/siwc/token-sharing-open-source/profiles-and-sessions>.
  Third-party copy of the Terms of Use (2024-12-11 version), not OpenAI's
  site,
  <https://open.windriver.com/info/uni-license-list/licenses/openai-tou-20241211.html>.
- **Not verified.**
  - OpenAI's Terms of Use, Usage Policies and Service Terms could not be
    opened (the site refused automated reading). The statements about the
    consumer terms above rest on a third-party copy of the 2024-12-11
    version, and on a third-party reading proxy of the live page that showed
    no date. A search result mentions a version dated 2026-01-01, which could
    not be opened, so the copy read may be superseded. They should be read on
    OpenAI's site by a person.
  - The help article on Codex with a ChatGPT plan and the announcement of the
    Codex app-server could not be opened either.
  - None of the Codex or Sign in with ChatGPT pages shows a date. Some Sign in
    with ChatGPT pages (token reference, self-hosted machines, errors,
    requesting a client ID) and the terms they link to were not opened.
  - Whether an app may drive the Codex tool with the tool's own saved login,
    rather than through Sign in with ChatGPT, is not stated on any page
    opened.
  - Whether the clause on getting around rate limits applies to one person
    switching between their own subscriptions is not stated on any page
    opened.

## Google (Gemini)

- **Driven by another app: not allowed.** Google's developer blog says that
  since 2026-06-18 the Gemini command-line tool no longer serves Google AI
  Pro and Ultra subscribers; their tool is now the Antigravity command-line
  tool. Its FAQ says headless mode is meant for direct scripting and CI, and
  that wrapping the tool inside "third-party coding agents or applications"
  is not supported under consumer plans. The FAQ and the Antigravity
  Additional Terms say that using third-party software to reach the service
  breaks the terms, and the Additional Terms say this can lead to suspension.
  Google recommends an API key for third-party agents. The documents read do
  not define whether an application that the account holder runs on their
  own machine counts as third-party in that sense.
- **Rotating accounts: not allowed.** The same FAQ says automating account
  rotation is not supported under consumer plans. No document read forbids
  simply holding more than one account. For more usage the documents point
  to paid credits or an API key. Google's general terms bar bypassing its
  systems or protective measures.
- **Other software handling the login: not allowed.** Both the Antigravity
  and the Gemini tool terms say that using third-party software to reach the
  service with the tool's login breaks the terms. The Antigravity
  documentation says headless runs use the login cached by an earlier
  interactive sign-in, so the login stays in the tool. Leaving it there does
  not change what the FAQ says about wrapping the tool. Google's general
  terms make the person responsible for keeping their account secure and say
  nothing about storing or passing tokens.
- **Sources.** Google Antigravity documentation: FAQ,
  <https://antigravity.google/docs/faq>; Additional Terms of Service,
  <https://antigravity.google/terms>; Plans,
  <https://antigravity.google/docs/plans>; Antigravity CLI headless mode,
  <https://antigravity.google/docs/cli/headless/>. Gemini CLI terms and
  privacy notices (updated 2026-04-10),
  <https://geminicli.com/docs/resources/tos-privacy>. Google Developers
  Blog, "Transitioning Gemini CLI to Antigravity CLI" (2026-05-19),
  <https://developers.googleblog.com/an-important-update-transitioning-gemini-cli-to-antigravity-cli>.
  Google Terms of Service (effective 2026-07-30),
  <https://policies.google.com/terms>.
- **Not verified.**
  - The Antigravity pages show no date.
  - Where exactly a person's own script ends and a third-party application
    begins is not spelled out.
  - The Gemini tool's quota page (updated 2026-06-18) still lists Google AI
    Pro and Ultra quotas, which conflicts with the blog post; the conflict
    was not resolved.
  - Where the Antigravity tool keeps its login on macOS was not confirmed
    (its authentication page returned 404).
  - The Antigravity tool's own licence, and any terms specific to Google AI
    Pro or Ultra, were not found. The Google One terms do not name those
    plans. The Gemini API Additional Terms and the Gemini tool's repository
    licence were not opened.
  - Forum replies and press reports of account suspensions appeared in
    search results only; they were not verified or used.

## xAI (Grok)

- **Driven by another app: unclear.** xAI's launch post and documentation for
  its command-line tool, Grok Build, promote headless use for scripts, bots
  and automations, and offer the tool to SuperGrok and X Premium Plus
  subscribers. The headless example assumes either a local sign-in or an API
  key, so a subscription login is not excluded. The only consumer terms that
  could be read were a third-party copy of the 2025-06-09 version, which bars
  using bots to reach the service and predates the tool.
- **Rotating accounts: unclear.** No page that could be opened addresses it.
  The FAQ says a subscription belongs to the account that bought it, that
  paid users share one weekly pool across Grok products, and that at the
  limit a person can pay as they go or upgrade. The older terms reserve the
  right to impose rate limits.
- **Other software handling the login: allowed with conditions.** xAI's own
  pages show other tools signing in to a subscription through its sign-in
  flow, and the FAQ acknowledges third-party apps that use a person's Grok
  login. The older terms bar sharing a login. Grok Build's documentation does
  not say where the login is kept or whether other programs may read it.
- **Sources.** Grok Build documentation: Headless and scripting,
  <https://docs.x.ai/build/cli/headless-scripting>. xAI news, "Introducing
  Grok Build" (2026-05-25), <https://x.ai/news/grok-build-cli>, and "Use Grok
  in OpenCode" (2026-05-21), <https://x.ai/news/grok-opencode>. Grok FAQ,
  <https://docs.x.ai/grok/faq>. Third-party copy of the consumer terms
  (2025-06-09 version, superseded), not xAI's site,
  <https://loyalagents.github.io/loyal-agent-evals/docs/terms/xai-consumer-terms-prev-20250609.html>.
- **Not verified.**
  - xAI's current consumer terms, its acceptable use policy and its archived
    terms of 2026-06-26 could not be opened. Every statement about its terms
    rests on a third-party copy of a superseded version and should be read
    on xAI's site by a person. A third-party tracker reports an update to the
    terms dated 2026-10-12; that was not verified.
  - Where Grok Build stores its login was not found.
  - Whether headless runs signed in with a subscription draw on the weekly
    pool or on API credits is not stated; the FAQ only implies the pool.
  - A first reader's claims about an agent mode, a cached-token sign-in
    method, wording on bundled subscriptions and a report that the terms
    forbid using subscription logins in other tools could not be confirmed
    on an official page and are not used here.

## What this means for Leverage

- Moving work to a **different provider** was not one of the three
  questions. The readers did not look for it, and this record says nothing
  about it.
- Leaving each login inside the provider's own tool, and never reading it, is
  consistent with what Anthropic's and OpenAI's documents say about handling
  a login. For Google it does not change the answer to the first question:
  what the FAQ says about wrapping the tool applies wherever the login is
  kept. xAI's current terms were not read.
- Driving a subscription tool from another program, and moving between two
  logins of the same provider at a limit, are where the documents are
  restrictive or silent. Google's FAQ is the most explicit: it says wrapping
  its tool inside third-party coding agents or applications, and automating
  account rotation, are not supported under consumer plans. Whether an app
  that a person runs on their own machine is third-party in that sense is not
  spelled out, and this record does not decide it.
- OpenAI's and xAI's terms could not be opened on their own sites, and one
  Google documentation page returned an error. A person should read the pages
  listed as not verified before relying on this record.
