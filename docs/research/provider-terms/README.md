# Provider terms check

This is the record of what four providers' published documents say about the
three things leverage does with a subscription login, read on 2026-11-18.

> **Snapshot, 2026-11-18.** The reading was done by AI agents (Claude): one
> reader per provider, then a second reader who opened every cited page again.
> It has not been checked line by line by a person. It reports what the
> documents say. It is not legal advice, and providers change their terms.

## What was asked

leverage starts each provider's own command-line tool on the owner's Mac,
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

Confidence is medium for Anthropic, medium to low for OpenAI, high for Google
and low for xAI. The reasons are under each provider.

This record holds findings only. Decisions made from them belong in
[the PRD](../../PRD.md).

## Anthropic (Claude)

- **Driven by another app: allowed with conditions.** Claude Code documents a
  non-interactive mode and a long-lived subscription token for scripts and
  CI, and a help article says such use draws on the plan's limits. The
  consumer terms, however, bar automated access unless it uses an API key or
  Anthropic permits it. The Claude Code compliance page says subscription
  sign-in is for ordinary use of Claude Code and Anthropic's own apps, that
  developers building products should use API keys, and that third parties
  may not offer Claude sign-in or route requests through plan logins for
  their users. The same page says nothing stops a person from signing in to
  the unmodified Claude Code program with their own subscription. No document
  addresses a local app that a person runs to drive the unmodified tool under
  their own login.
- **Rotating accounts: unclear.** Claude Code documents staying signed in to
  several accounts at once, for example work and personal. The usage policy
  bars creating several accounts to get around product limits, and bars
  bypassing restrictions built into the products. The compliance page says
  the advertised plan limits assume ordinary, individual use. No document
  says whether moving to a second account at a limit counts.
- **Other software handling the login: not allowed.** The consumer terms bar
  sharing a login. The compliance page says developers may not collect, store
  or pass on Claude logins or session tokens. A login that stays in Claude
  Code's own store, which leverage never reads, is consistent with these
  texts.
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
- **Not verified.** The documentation pages show no date. The Commercial
  Terms were not read.

## OpenAI (Codex)

- **Driven by another app: allowed with conditions.** The Codex
  documentation presents a non-interactive mode for scripts and CI that
  reuses the saved login. It recommends API keys for automation and calls a
  subscription login in CI an advanced option for trusted private runners.
  OpenAI also documents an official route for open-source, locally hosted
  apps to run Codex on a person's own plan, called Sign in with ChatGPT, in
  which the app registers its own client.
- **Rotating accounts: unclear.** The Sign in with ChatGPT documentation
  expects an app to hold several saved accounts and switch between them, and
  says plan usage is one total across apps. No official page that could be
  opened addresses switching accounts to continue past a limit. Copies of the
  consumer terms held by third parties bar getting around rate limits; that
  wording could not be confirmed on OpenAI's own site.
- **Other software handling the login: allowed with conditions.** The
  documentation says the saved login must be treated like a password and
  never committed, pasted or shared, and that one saved login should not be
  shared across machines. For other software it points to Sign in with
  ChatGPT.
- **Sources.** Codex documentation: Authentication,
  <https://learn.chatgpt.com/docs/auth>; Non-interactive mode,
  <https://learn.chatgpt.com/docs/non-interactive-mode>; Maintain Codex
  account auth in CI/CD, <https://learn.chatgpt.com/docs/auth/ci-cd-auth>.
  Sign in with ChatGPT for open-source apps,
  <https://developers.openai.com/siwc/token-sharing-open-source>.
- **Not verified.** OpenAI's Terms of Use, Usage Policies and Service Terms
  could not be opened (the site refused automated reading). The statements
  about the consumer terms above rest on a third-party copy of the
  2024-12-11 version and should be read on OpenAI's site by a person.

## Google (Gemini)

- **Driven by another app: not allowed.** Since 2026-06-18 the Gemini
  command-line tool no longer serves Google AI Pro and Ultra subscribers;
  their tool is now the Antigravity command-line tool. Its FAQ says headless
  mode is for direct scripting and CI, and that wrapping the tool inside
  another coding agent or application is not supported under consumer plans.
  It says using other software to reach the service breaks the terms and can
  lead to suspension, and it recommends an API key for that use.
- **Rotating accounts: not allowed.** The same FAQ says automating account
  rotation is not supported under consumer plans. No document read forbids
  simply holding more than one account. For more usage the documents point
  to paid credits or an API key.
- **Other software handling the login: not allowed.** Both the Antigravity
  and the Gemini tool terms say that using other software to reach the
  service with the tool's login breaks the terms.
- **Sources.** Google Antigravity documentation: FAQ,
  <https://antigravity.google/docs/faq>; Additional Terms of Service,
  <https://antigravity.google/terms>; Plans,
  <https://antigravity.google/docs/plans>. Gemini CLI terms and privacy
  notices (updated 2026-04-10),
  <https://geminicli.com/docs/resources/tos-privacy>. Google Developers
  Blog, "Transitioning Gemini CLI to Antigravity CLI" (2026-05-19),
  <https://developers.googleblog.com/an-important-update-transitioning-gemini-cli-to-antigravity-cli>.
  Google Terms of Service (effective 2026-07-30),
  <https://policies.google.com/terms>.
- **Not verified.** The Antigravity pages show no date. Where exactly a
  person's own script ends and "another application" begins is not spelled
  out. The FAQ was opened a third time, by a separate reader, and says what
  is reported here.

## xAI (Grok)

- **Driven by another app: unclear.** xAI's launch post and documentation for
  its command-line tool, Grok Build, promote headless use for scripts and
  automations, and offer the tool to SuperGrok and X Premium Plus
  subscribers. The only consumer terms that could be read were a third-party
  copy of the 2025-06-09 version, which bars using bots to reach the service
  and predates the tool.
- **Rotating accounts: unclear.** No page that could be opened addresses it.
  The FAQ says a subscription belongs to the account that bought it and that
  paid users share one weekly pool across Grok products.
- **Other software handling the login: allowed with conditions.** xAI's own
  pages show other tools signing in to a subscription through its sign-in
  flow, and the FAQ acknowledges apps that use a person's Grok login. The
  older terms bar sharing a login.
- **Sources.** Grok Build documentation: Headless and scripting,
  <https://docs.x.ai/build/cli/headless-scripting>. xAI news, "Introducing
  Grok Build" (2026-05-25), <https://x.ai/news/grok-build-cli>, and "Use Grok
  in OpenCode" (2026-05-21), <https://x.ai/news/grok-opencode>. Grok FAQ,
  <https://docs.x.ai/grok/faq>.
- **Not verified.** xAI's current consumer terms and acceptable use policy
  could not be opened. Every statement about its terms rests on a
  third-party copy of a superseded version and should be read on xAI's site
  by a person.

## What this means for leverage

- Moving work to a **different provider** is not account rotation, and no
  document read restricts it.
- Leaving each login inside the provider's own tool, and never reading it, is
  the one design that every provider's documents are consistent with.
- Driving a subscription tool from leverage, and moving between two logins of
  the same provider at a limit, are where the documents are restrictive or
  silent. Google's are the clearest: both are unsupported on consumer plans.
- Three of the four providers could not be read in full by an agent. A
  person should read the pages listed as not verified before relying on this
  record.
