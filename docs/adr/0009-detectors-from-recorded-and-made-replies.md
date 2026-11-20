# 0009. Detectors from recorded and made replies

Status: Accepted

## Context

A handoff starts when the runner recognises, in a failed tool run, that
the account reached a limit or is signed out
([ADR 0008](0008-how-a-run-moves-to-another-account.md)). The PRD reports
a limit only when the provider's reply names one of four windows
(five-hour, weekly, per-model, spend), and takes a reset time only from
what the reply states. No provider documents what its tool prints at a
limit, and no agent of this build may sign in, sign an account out or
spend the owner's quota to see one, so no real limit reply exists. What
can be seen safely is a tool with no login at all: a new, empty settings
folder for Claude and Codex, and Grok's status command on a Mac where it is
signed out. A status command prints the account's email, organisation and
plan. Which replies the rules are written to, and how a reply is kept in
the repository, decide what the product can claim and are hard to change
once tests and stand-ins depend on them (rule AR-003). The decisions are
the milestone's plan HD-7, HD-8 and HE-32.

## Decision

1. **One detector per provider, in LeverageKit.** `ClaudeDetector`,
   `CodexDetector`, `AntigravityDetector` and `GrokDetector` share
   `ReplyReading` and `LimitWindowWords`, and give back only a
   `RunOutcome`: a limit with its window and stated reset time, a short
   rate limit, signed out, or failed. They read a run only when it failed,
   in one order: sign-out, then limit, then short rate limit, then
   failure. A run leverage itself ended is always a failure.
2. **What a limit is.** A refused run whose reply names one of the four
   windows, in a structured field where the tool gives one, else by the
   fixed words of `LimitWindowWords` next to the word "limit" or "quota". A
   reset time is taken only from a time the reply states; nothing is
   estimated, and a time not after the moment observed is stored by the
   server as none. A rate limit that names no window is retried in place
   after 5, 15 and 45 seconds with the heartbeat running, and then counts
   as one failed run (HD-7, HE-32).
3. **A status question guards the wording no rule knows.** When a failed
   run's output settles nothing and the provider has a status command
   (Claude, Codex and Grok), the runner asks `SignInStatus`, under a
   30-second limit. Its output is read for the one signed-in field and
   dropped: it answers signed in, signed out, no status command, or could
   not tell (a status command that would not start or ran past its
   limit), and nothing of the output is logged, returned or kept. Could
   not tell leaves the run a failure, not a sign-out.
4. **Every rule names the reply file it was written to.** The replies are
   files under `mac/Tests/StandIns/replies/<provider>/`, each with `meta`
   (provider, tool, tool version, `basis`, date, what it shows, the
   outcome its detector must give, and one made-up marker
   `LVRG-REPLY-<12 hex digits>`), the exit status and both outputs. `basis`
   is `recorded_no_login` for a reply captured from a tool with no login,
   `made_from_observed` for a reply made to follow observed text, and
   `invented` for a reply whose shape is a guess. The marker is also in
   the outputs, in place of one scrubbed value in a recorded reply, so the
   recorded wording is not changed (HD-8).
5. **The files are checked and played.** `scripts/check_reply_fixtures.py`
   refuses a file with no `meta` or `basis`, an email address, a token
   prefix, an id that is not a placeholder, a named field with a real
   value, or a marker missing from the outputs or used twice. It runs in
   CI. `DetectorFixtureTests` gives every file to its detector, and the
   stand-in tools play the same files, so the end-to-end run carries them
   through the runner, the helper and the server.
   `scripts/secret_scan.py --replies` fails when a marker or a long line
   of a reply is found anywhere outside the stand-ins' folder.
6. **The contract's readers stay provisional.** `api/contract/readers.json`
   keeps every login reader's `capture.limit` and `capture.sign_out` at
   `none`.

## Alternatives considered

- **Treat any refusal that mentions a limit as a limit.** A context or
  output limit would then hand work to another account, and a reset time
  would have to be guessed.
- **Run each tool signed in until it hits a limit.** No agent may spend the
  owner's quota, and a limit cannot be caused on request.
- **Keep the raw captures.** They hold session ids, request ids and
  account folders; the scrubbed files keep the wording and drop those.
- **Detect in the helper.** The helper never sees the tool's output
  ([ADR 0008](0008-how-a-run-moves-to-another-account.md)).

## Consequences

- Every limit reply in the repository is made, so the rules for a limit
  are a guess at the shape. On a real tool a real limit will most likely
  not match them, and is then milestone 2's failing run: no handoff, and
  after three failures the run ends. This stays so until a real limit
  reply is captured, scrubbed and committed as a recorded file.
- The recorded sign-out replies are of a tool that never held a login,
  for Claude and Codex; nobody has seen the reply of a login that expired
  or was revoked during a run. Grok's run reply and Gemini's sign-out are
  made from observed text.
- A detector names the tool versions its recorded files came from: Claude
  2.1.325 and Codex 0.169.0; none for Antigravity and Grok, whose run
  replies are all made.
