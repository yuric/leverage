# 0018. Usage readers and their tested versions

Status: Accepted

## Context

Provider tools and account APIs can change the shape of a usage reply
independently of leverage. A wrong number can show false capacity
or resume work waiting on a limit (CR-2, CR-3, CR-4, CR-8, CR-10,
CR-12, CR-37, RD-1 to RD-3, RD-7, RD-8).

## Decision

- Keep the bounded tool or HTTP call and the parser in the helper.
  A typed reading leaves the helper. Raw provider replies stay in
  memory on the product path.
- Gate a login reader on the exact normalized tool version in
  `api/contract/readers.json`. The Swift catalog is generated from it.
  The server queues the first read at Add, queues Refresh on request
  and schedules due reads in the sweep.
- Use the existing subprocess mechanism with open standard input for
  the Codex JSON line session. Check the account home before asking
  for data. Once the required replies arrive, stop and reap the child.
  The allowed methods are in
  [Architecture](../ARCHITECTURE.md#trust-boundaries).
- Keep recorded usage replies out of the repository. Scrub a
  maintainer's developer capture before writing it. Test parsers with
  made-up replies following the known structure and check the
  fixtures before accepting them.

## Alternatives considered

- Accept later tool versions if the JSON still decodes. Decoding
  cannot show that the numbers still mean the same thing.
- Drive a usage screen through a pseudo-terminal. The Codex
  protocol provides a narrower read path. Gemini still needs a
  source the maintainer can verify.
- Guess Claude's usage grammar or a reset grant from the reported
  envelope. The quota fields and real reset-cache shape are missing
  from the evidence.
- Have the helper schedule its own reads. The server already
  coordinates requests and deduplicates Refresh with scheduled work.

## Consequences

Only Codex CLI 0.169.0 has a registered login usage reader. Claude's
experimental figures parser and reset-cache reader are covered by
stand-ins and stay out of the live lookup. Gemini and Grok logins
show usage as unavailable. A later tool version needs a recording
and a rebuild. The five token readers are provisional and use
documentation-based fixtures. See the
[provider evidence table](../ARCHITECTURE.md#usage-readers).
