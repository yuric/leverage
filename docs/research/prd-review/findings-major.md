# PRD review: findings rated major

These are the findings from the [adversarial review of the PRD](README.md) that at least one verifier rated major and none rated blocker; the method and its limits are described there.

## Findings

### 9. A failed `task.before_done` gate changes state instead of refusing: no lifecycle row, a non-existent failed criterion, undefined events and verdict, and an override that can never take effect

- **Lines:** 74-75, 94, 98, 136, 263, 277, 288-289, 313, 320, 327, 557, 559, 592, 609, 699
- **Rated:** major by both verifiers
- **Fix:** the owner has to decide
- **Found by:** consistency inventory, state machine, event log, rule checks, interfaces

Every other gate failure is a refusal that leaves state untouched (step 6: refuse and route; the holder resends). A failed `task.before_done` gate instead 'counts as a failed review with the rule as the failed criterion': In review to Working with the round raised. A rule is not a row in `criteria`, so `criterion.reopened` has no subject and nothing reopens for the builder to fix; the hashed inputs are the reviewer's verdict and notes, so the builder has nothing to change. The lifecycle table has no row for the outcome. Unspecified: whether `review.failed` is written and with which actor, what `reviews.verdict` and the review criterion's state replay to, whether the reviewer's command outcome is completed or refused, and whether the failure counts toward escalation and the round limit (two such failures escalate, three hold the task). Override cannot work: the task has left In review, the reviewer's lease is gone, and the check key includes the round and the verdict/notes, so neither 'completes at once' nor 'the next request with the same inputs' can ever match.

**Effect.** The state table, golden traces and replay of round, verdict and criteria state cannot be written for this path. A wrong or flaky custom rule at 'when the review has passed' burns rounds, triggers escalation and the round limit for something only the reviewer's text controls, and the owner's Override button does nothing; the only remedy is to turn the rule off for everyone. Release criterion L699 fails at this hook.

**Verifier 1: partly.** Quotes are exact. Refuted: other gates also change state on failure (L260 hold, L264 stopped action, L298), so L263 specialises step 6 (L277). The builder can change evidence links (hashed, L320) and the work (L324); a new round is a new check key (L313). "Counts as a failed review" implies the L74 row, round limit (L98) and escalation. Stands: the override (L289, L609) can never match once the round rises; the failed-criterion subject, event actor and command outcome (L136) are undefined. Only custom rules reach this hook (L341-347, L362).

**Verifier 1's fix.** Options: (a) refuse, keep the task In review with the pass stored, a hold and a Needs you item; an override completes Done. (b) Keep L263 and specify it: a lifecycle row In review to Working, the reviewer's command outcome, `review.failed` caused by the `check.finished` event, no `criterion.reopened`, counting toward escalation and the round limit, and an override that carries to the next `task.before_done` request for that task and rule version in any round. Recommend (b): it matches L263 and L362 (reason goes to the builder) and keeps the owner out of routine failures.

**Verifier 2: confirmed.** Case: reviewer sends pass (L405); a custom gate at `task.before_done` fails. L263 says round up, back to builder; L277 says refuse. No lifecycle row (L74-76). I must guess the `review.failed` actor, the `criterion.reopened` subject (a rule is no `criteria` row, L557), replayed `reviews.verdict` (L592) and the command outcome (L136). Override is dead: the key includes round (L313, L583) and the task has left In review (L289). Overstated: escalation and round limit follow from L94-98; L260 and L264 failures also change things. No shipped rule uses this hook (L339-347), hence major.

**Verifier 2's fix.** Recommend (a) in its smallest form, mirroring `task.before_submit` (L262): refuse the verdict with `blocked_by_rule`; task stays In review, round unchanged; the reviewer keeps the review and may fail it naming real criteria (L74) or resend. L289 override and the L327 three-run limit then work as written. The reviewer's (a) invents hold reason `check_failed`, outside L113's fixed list. (b) needs a new verdict value, events and a rule-typed criterion; without override it contradicts L18, L328, L609. no. 123's hybrid collapses to (b), since custom rules route to the builder (L362).

### 10. Timers-first covers only commands on the task; other writers can put events after an unapplied due timer

- **Lines:** 86-87, 133, 135, 268, 272, 277, 286, 309, 629
- **Rated:** major by both verifiers
- **Fix:** the PRD already settles it elsewhere; the text needs aligning
- **Found by:** event log, steps and timing

The timer rule fires only before a command on that task. Several transactions write a task's events without being a command on it: an orchestrator's job result completing a pending transition (gating step 6 re-validates state but applies no timers), a project pause or budget pause opening holds on every task (in batches), a seat pause, a rule switch-off withdrawing checks and releasing waiting tasks, credential handoff. If a lease was due at 10:00 and the sweep has not run, a job result at 10:00:10-20 completes the submit of a seat whose lease already ended; or a `hold.opened` lands after the due time, pauses a dead lease, and the expiry is later written with effective time 10:00.

**Effect.** Outcomes depend on sweep timing: expired leases still complete transitions, `effective_at` goes backwards and steps get negative durations. Golden traces and Tests 2 and 7 cannot be made deterministic; the bug is rare and the random-sequence test may not hit it unless it randomises timer lag.

**Verifier 1: partly.** All six quotes are exact (L86, L87, L135, L277, L286, L309). The gap stands: L86, L135 and L629 scope timers-first to "a command on a task", and gating step 6 (L277) applies no timers, unlike step 1 (L272). Project, seat and rule commands (L436) are not commands on a task. What fails: outcomes are not open. L87, L135 and L628 ("no step has a negative duration") already forbid them, and L286 cancels the pending transition on expiry. A job result is arguably a command (L136, L384). Track A owns all timer logic (L687).

**Verifier 1's fix.** Widen the timer rule at L86, L135 and L629 from "a command on a task" to any write of an event for a task, which the invariants at L87, L135 and L628 already require. Make gating step 6 (L277) apply due timers as step 1 (L272) does. Not included as edits because they would add requirements: a late-sweep case in Test 7 (L648) and the golden traces, and a line on the gating interface at L666. Both are worth a maintainer's decision.

**Verifier 2: confirmed.** L86, L135 and L629 fire timers only before "a command on a task"; gating step 6 (L277) re-validates with no timer step. Case: lease due 10:00:00, submit pending, sweep not yet run, orchestrator's job result at 10:00:10. Read literally, the submit completes; L87 and L286 say it was cancelled at 10:00:00. Likewise a project-pause `hold.opened` at 10:00:10, then expiry at 10:00:00, breaks L135 and L628. I would have to guess whether a job result or hold fan-out counts as a command on the task. The invariants settle it, so not a blocker.

**Verifier 2's fix.** Widen the trigger from "a command on a task" to any transaction that writes an event for a task, at L86, L135 and L629, and add "applies due timers" to gating step 6 (L277). Extend Test 7 with the job-result and project-pause cases. The reviewer's "reads or writes anything" is too broad: reads run no changing transaction and must not write expiry events, so I scope it to event writes. The L666 restatement is unnecessary once step 6 says it. Not settled here: whether a withdrawn job's late result still records tokens and spend.

Text changes the verifiers proposed (not applied):

Verifier 1 would replace:

````text
Before the server validates any command on a task, it applies every timer already due on that task, in the same transaction, with the effective time set to the due time.
````

with:

````text
Before the server validates any command on a task, or writes any other event for a task, it applies every timer already due on that task, in the same transaction, with the effective time set to the due time. This holds for every writer, not only a command sent for that task: a job result that completes a pending transition, a hold opened or closed by a project, budget or seat pause, a rule switched off, and an override.
````

Verifier 1 would replace:

````text
Any timer already due on a task is applied before a command on that task is validated, with `effective_at` set to the due time.
````

with:

````text
Any timer already due on a task is applied before a command on that task is validated, and before any other event is written for that task, with `effective_at` set to the due time.
````

Verifier 1 would replace:

````text
When every check has a result, the server validates the state and the app checkers again.
````

with:

````text
When every check has a result, the server applies due timers, then validates the state and the app checkers again.
````

Verifier 1 would replace:

````text
Due timers are applied before any command on the same task.
````

with:

````text
Due timers are applied before any command on the same task, and before any other event is written for that task.
````

Verifier 2 would replace:

````text
Before the server validates any command on a task, it applies every timer already due on that task, in the same transaction, with the effective time set to the due time.
````

with:

````text
Before the server validates any command on a task, or writes any other event for a task, it applies every timer already due on that task, in the same transaction, with the effective time set to the due time. This holds for every writer, not only commands sent to that task: a job result that completes a pending transition, a hold opened or closed by a project, budget or seat pause, a check withdrawn by a rule change, an override, and a credential handoff.
````

Verifier 2 would replace:

````text
Any timer already due on a task is applied before a command on that task is validated, with `effective_at` set to the due time.
````

with:

````text
Any timer already due on a task is applied before a command on that task is validated, and before any other transaction writes an event for that task, with `effective_at` set to the due time.
````

Verifier 2 would replace:

````text
When every check has a result, the server validates the state and the app checkers again.
````

with:

````text
When every check has a result, the server applies due timers, then validates the state and the app checkers again.
````

Verifier 2 would replace:

````text
Due timers are applied before any command on the same task.
````

with:

````text
Due timers are applied before any command on the same task, and before any other event is written for it.
````

Verifier 2 would replace:

````text
A command that arrives after a lease's due time is refused before the sweep has run, and the expiry is recorded at the due time.
````

with:

````text
A command that arrives after a lease's due time is refused before the sweep has run, and the expiry is recorded at the due time. The same holds when the next writer is not a command on that task: a job result or a project pause that arrives after the due time and before the sweep records the expiry first, at the due time, and the pending transition is cancelled, not completed.
````

### 11. Agents the app runs share a machine and OS user with the database, keychain, settings folders and other seats' tokens; no isolation is specified

- **Lines:** 236, 354, 448, 528, 669, 716
- **Rated:** major by both verifiers
- **Fix:** the owner has to decide
- **Found by:** security and privacy

The PRD's premise is that no agent is trusted and every review is independent. Yet app-run provider tools and the reference runners execute headless on the machine that hosts the server, under the owner's logins, and nothing specifies an OS user, container, working directory, tool-permission mode or file boundary for them. A builder steered by task content has a shell beside the reviewer's and orchestrator's seat tokens, the PostgreSQL credentials, other accounts' settings folders and the keychain. It can pass its own review, approve its own outward action, or write rows directly. The only related line is advice about outward credentials.

**Effect.** Every guarantee the app enforces (independent review, action approval, the single writer) can be bypassed by one injected builder on the default single-machine install, and no release criterion would detect it.

**Verifier 1: partly.** All five quotes are exact (L236, L448, L528, L669, L716). The core gap stands: nothing specifies an OS user, container or permission mode for seats the app runs (L448, L453, L528), and L737 puts the server on the same machine. Overstated: L716 is not the only related line. L632 hashes seat tokens, L579/L584 limit direct writes, L455 keeps sign-in tokens out of the app, L28/L745 disclaim file management, and L708 is a release criterion that nominally covers it. L236 is about rule compliance, not host security.

**Verifier 1's fix.** Options: (a) seats the app runs get a separate OS user or container with no read access to server config, database credentials, keychain items, other settings folders or other seats' tokens, and L708 gains a local-machine test; (b) add a Risks row saying independence on a shared machine holds only for agents that stay inside the interface, as L716 does for outward actions. Recommend (b) now plus an Open decisions row for (a): provider logins may be tied to the OS user (not verified), so (a) needs testing first.

**Verifier 2: partly.** The gap is real: L448, L528 and L669 put app-run tools on the server's machine; L632 and L708 protect only the interface, and L579/L584 cannot stop a forged insert by whoever holds the app's database login. Case: the builder reads the reviewer runner's bearer token and calls claim-next and verdict (L403-405); L332 and L354 pass, as do all eight tests. But no Contract artifact changes, so I guess nothing unless isolation is chosen; then seats (L555) needs a run-identity field and a token-delivery rule.

**Verifier 2's fix.** Reviewer's (a) contradicts Credentials: logins reuse the owner's signed-in tool and settings folder (L440, L448, L466), Antigravity is machine-wide (L452), handoff needs several folders (L516); L28 and L745 leave file access to agents. Options: (1) add a Risks row: v1 guarantees hold at the interface only, not against an agent with a local shell; (2) also keep the database login, server config and seat tokens under an account agents cannot read, which splits the helper from the server (L528), with a release test. Recommend (1) now and (2) as an open decision.

### 12. Owner interface authentication is undefined: sign-in identity, first-owner bootstrap, cross-site protection, bind address and transport

- **Lines:** 436, 552, 606, 708, 737
- **Rated:** major by both verifiers
- **Fix:** the owner has to decide
- **Found by:** security and privacy

The owner interface can override checks, approve irreversible actions, mint seat tokens, save API tokens and make the machine helper run tools, yet its authentication is one phrase. 'Sign-in identity' is never defined (password, passkey, external identity). Also unspecified: how the first owner is created on a fresh open-source install, session lifetime, protection against cross-site requests from another page in the owner's browser, bind address, and transport encryption for bearer tokens when deployed on a server. The open decision on where it runs names sign-in as dependent and decides nothing. No test or release criterion covers the owner interface; line 708 covers seats only.

**Effect.** The `users` migration and the owner interface schema cannot be written in the contract milestone. Track C picks an ad hoc scheme, and a default install may expose every override and credential command to any local page or network peer.

**Verifier 1: partly.** All five quotes are exact and nothing in the PRD settles the core gap. Sign-in method and first-owner bootstrap appear nowhere; L632 Security covers seat tokens only; L737 names sign-in as a dependent and decides nothing; L669 schedules only "Seat sign-in". Overstated: owner commands are covered by test 3 (L644), L693 and L699, so only authentication is untested; only the `users` identity column (L552) and the sign-in calls are blocked, not the whole owner schema; session lifetime and cookie mechanics belong in the architecture document.

**Verifier 1's fix.** Add an Open decisions row "Owner sign-in". Options: (A) local password, created with a one-time setup code printed on the server console at first run; (B) external identity provider; (C) no sign-in on a loopback-only install, which contradicts L606. Recommend A. Extend L632 Security: every owner command needs a signed-in session, cross-origin owner calls are refused, the server binds to loopback by default, and encrypted transport is required when bound elsewhere (this also protects seat bearer tokens). Add a release criterion: unauthenticated and cross-origin owner calls are refused.

**Verifier 2: confirmed.** Exact case: empty database, owner opens Sign-in (L606). No owner command (L436), event (L175) or milestone (L669 names only seat sign-in) creates the `users` or `workspaces` row. For the contract I must guess the `users` columns behind "sign-in identity" (L552), whether session storage exists (no table at L549-575), and the sign-in, sign-out and anti-forgery parts of the owner schema (L665). L632 and L708 cover seats only; L737 decides nothing. Bind, transport and session lifetime are not contract artifacts, so major, not blocker.

**Verifier 2's fix.** Options: (a) local password, with first owner and workspace created through a one-time setup code printed on the server console; (b) external identity. Recommend (a); (b) fits a single-owner local install badly. Then add: password hash on `users`, session storage, setup/sign-in/sign-out calls, Origin check plus anti-forgery token on owner commands (same-site cookies do not separate localhost ports), owner sign-in in milestone 2, an L632 line and a release criterion. Correction: bind and transport rules also govern the agent interface, which shares the server (L436).

### 13. 'Each needs an answer before the contract' is not satisfied by assumed recommendations, and four recommendations are not answers

- **Lines:** 528, 547, 687, 726, 732, 736-739, 747, 754, 759-760
- **Rated:** major by both verifiers
- **Fix:** the owner has to decide
- **Found by:** build plan

The Open decisions table says every decision needs an answer before the contract, and also that the PRD assumes the recommendations; nothing turns one into the other. Of 29, eight really gate the contract: stack, where it runs, how the orchestrator runs, first provider, orchestrator approval default, token cost of checks, Campus, and cross-provider handoff. Four recommendations are not answers: first provider ends in an either/or; 'where it runs' allows a remote server although the helper must be on the owner's machine; paying and deleting stays open in Risks; counting check cost against the budget has no mechanism in the body. The other 21 are already encoded or are setting values.

**Effect.** The first contract item (migrations) cannot start without the stack, and the contract author must silently decide the four non-answers, which the owner then discovers in code.

**Verifier 1: partly.** All quotes are exact, and there are 29 rows. Refuted: L732 is itself the sign-off gate. Migrations need only PostgreSQL, assumed at L547/L736 (L133, L584); L687 defers folder names only. Paying/deleting has an answer at L747 ("On"); L726 points to that row, and L244 scope makes it a setting. Stands: L754 has no mechanism; job spend (L407, L567-568) never reaches `projects.spent` (L553, L595) or `cost.reported` (L268, L399). L737 allows a server while L528/L440 need the owner's machine. L739's either/or is unresolved but is a seed default (L719).

**Verifier 1's fix.** Keep the table; do not bulk-mark 21 rows "decided", since that decides for the owner. The owner answers three. (1) Check cost: A, job spend adds to `projects.spent` through a named event and runs the budget rule (recommended; matches L754, L595); B, recorded per rule only. (2) Where it runs: A, owner's machine only in version 1 (recommended; matches L528, L440); B, allow a server and specify a separate helper. (3) Provider rule: A, ship it off until a second provider connects (recommended); B, require two providers.

**Verifier 2: partly.** L732 gates the contract, but a blanket yes still leaves guesses. Trace: Complete contract, details check, job result with spend (L407) on a project at budget. L754 counts it, yet L399 is holder-only and L595 replays `projects.spent`: no event or budget-rule run is defined. L736 names PostgreSQL only; L666 needs a language (L687, L759). L739 leaves the provider rule's seeded `enabled` open (L693 vs L701). L737 vs L528 leaves a helper protocol open. Overstated: SQL migrations can start; L747 answers "On"; L738, L760, L747 are already encoded.

**Verifier 2's fix.** Do not relabel 21 rows as decided; only the owner can. Add an Answer column and an owner sign-off before milestone 1. Owner must answer five gaps: (1) language, and whether the codebase is Campus; (2) provider rule seeded off (recommended) or a second provider named; (3) server on the owner's machine with helper in-process (recommended), or remote plus a helper protocol in the contract; (4) job spend written as `cost.reported` running the budget rule (recommended), or recorded only; (5) pay/delete: add a row; approval rule covers all actions (L747) or publish/send only.

### 14. Hold reasons are never classified or given per-reason rules: lease pause, Blocked lane, step kind, stacking and closing are undefined, and seat-scoped holds outlive the seat's lease

- **Lines:** 46, 55, 78, 89, 113-116, 191, 213-215, 229, 260, 298, 327, 423-424, 432, 516, 521, 541, 559, 750
- **Rated:** major by both verifiers
- **Fix:** the owner has to decide
- **Found by:** consistency inventory, state machine, event log, steps and timing, credentials

Twelve hold reasons exist and three behaviours hang on 'a hold on the owner or the project': the lease clock pauses, the task shows in Blocked, and the step is `wait_owner`. No place classifies the reasons (`access`, `budget`, `check_error`, `contract_incomplete`, `rounds_exceeded`, `action_stopped`, `credential_limit`?), and the Terms row lists access, budget and an unrunnable check apart from 'the owner'. Nor is there any per-reason statement of what opens and closes it (`contract_incomplete` has no closer). Three waiting kinds (`wait_owner`, `wait_seat`, `wait_limit`) depend on the reason; `wait_seat` and `wait_limit` have subjects that contradict 'the waiting step's subject is the oldest open hold', and no rule picks the kind when holds of different kinds stack (`seat_paused` oldest, `owner_question` newer: which step, and does the lease pause?). Steps change only when 'the last hold lifts', so when the oldest hold closes while others stay open, time stays attributed to the closed reason or the row is silently mutated; '`wait_owner` steps by hold reason' is wrong either way. `seat_paused` and `credential_limit` describe one seat; a paused seat's lease keeps running and whether the clock pauses under `credential_limit` is unstated. If it does not, a 60-minute lease expires during a 5-hour or weekly limit, lease expiry writes only `task.lease_expired`, the task returns to Ready still held, eligibility requires 'no hold', and no other seat can claim it; the step stays `wait_seat`/`wait_limit` for a seat that no longer holds it, contradicting the acceptance criterion that it 'resumes'. `wait_limit` also opens when 'every credential that could run the task' is limited while the hold opens when no credential below is available. Two 'held' outcomes (three seats failing a claim gate, three re-runs) have no reason in the list.

**Effect.** Board, lease timers and step tracker (tracks A, E, F) will each guess a different classification; whether a builder waiting on access or a provider limit loses the task after 60 minutes differs by implementer. Tasks strand in Ready behind a hold about a seat that no longer has them, for up to a weekly provider reset, while healthy seats idle (what L89 says must not happen). Owner-wait and rule hold-up reports misattribute time whenever two holds overlap; step rows, replay and the Blocked lane disagree; the Credentials acceptance criterion fails or passes by accident; the fixed list the contract milestone must freeze is incomplete.

**Verifier 1: partly.** All quotes are exact. Refuted: the ten non-seat reasons classify by elimination (three hold step kinds L213-215; L226 puts failed and errored-check holds in `wait_owner`; L610; L750); heartbeats work under a hold (L116), so a live runner keeps its lease; the Contract milestone freezes step table and hold list before tracks start (L661-664). Standing: no closer for `seat_paused`/`credential_limit` on lease expiry (L78, L89, L423); cross-kind stacking and subject (L115 vs L214-215, L191); L215 vs L516/L521; no reason for L298, L327; no closer for `contract_incomplete`, `rounds_exceeded`.

**Verifier 1's fix.** Add a per-reason table to Holds (opened by, closed by, pauses lease, in Blocked, step kind) plus an Open decisions row. Recommended: the ten owner/project reasons pause the lease and show in Blocked; `seat_paused` and `credential_limit` do neither and close with `hold.closed` when the holder's lease ends, it releases, or the contract is edited; the waiting step re-opens when the governing hold changes, precedence owner/project, limit, seat; name reasons for L298 and L327; `contract_incomplete` closes on the next `task.contract_changed`; align L215 and L541 with L516/L521. Alternative: model seat conditions on the seat, not as task holds.

**Verifier 2: confirmed.** I would have to guess. Case 1: a blocking question opens `owner_question` (wait\_owner, lease paused, L89); the owner pauses the seat, then answers. L191 changes steps only when the last hold lifts, yet L115/L214 now imply wait\_seat with another subject. Case 2: `seat_paused`, lease expires; L78 writes only `task.lease_expired`, the hold stays, L423 refuses every claim, against L89. Unstated: lease under `credential_limit` (L521), `contract_incomplete` closer and lane (L260 vs L55), reasons for L298/L327 (L113). Nuance: heartbeats work under holds (L116), so expiry depends on the client (L432).

**Verifier 2's fix.** Add a per-reason table to Holds: opener, closer, pauses lease, in Blocked, step kind. Seat-scoped reasons (`seat_paused`, `credential_limit`): (a) lease runs, hold closes in the transaction where the seat loses the task; (b) `credential_limit` pauses the lease until reset. Recommend (a), rewording L215/L521/L541. Stacking: keep L115, kind follows the oldest open hold, open a new step when that hold changes; the reviewer's precedence rule contradicts L115. `contract_incomplete`: Backlog lane, `wait_contract`, closes on next `task.contract_changed`. Add reasons for L298 and L327.

### 15. The owner command list, declared part of the contract, lacks commands its own events, screens and Needs you choices require

- **Lines:** 98, 164, 174, 202, 305, 368, 374, 406-407, 422, 435-436, 555-556, 608, 613-614, 619, 669
- **Rated:** major by both verifiers
- **Fix:** the owner has to decide
- **Found by:** consistency inventory, interfaces, product and scope

Several registered events have no owner command that could produce them, and no agent call does either: `project.created` and `brief.changed` (only pause, resume and budget exist for projects, though the Projects screen shows briefs), `task.changed` (priority, project), `seat.resumed` and `seat.changed` including strength rank (only connect, pause, remove). Claim order is 'by priority and then age', yet priority is not on the Add task form and no command sets it. The check-error Needs you item offers 'run it again', which is not an owner command; the rounds-exceeded item has no resolution. Nothing queues a contract-draft job, so the planner role, the `draft` step and that job kind are unreachable. The Credentials commands (L527) are missing from the list. no. 124 adds that the briefing requires 'the seat's role file' from the core-loop milestone but no table, field, version or owner command holds role files and the Roles section is deferred.

**Effect.** The owner interface schema (contract milestone) is incomplete and will not match its event registry: no project can exist, a paused seat cannot return, priority is always default, registered events have no writer, the state-table test cannot cover unlisted commands, and track E builds screens (Projects, roster) with no commands behind them. The briefing hash cannot be computed in milestone 2 because one of its three parts does not exist.

**Verifier 1: partly.** Quotes are exact. Stands: no owner command or agent call writes `project.created`, `brief.changed`, `task.changed`, `seat.resumed` or `seat.changed` (L164, L174 vs L436); nothing queues a contract draft (L202, L406-407; the form at L82 bypasses the planner); the role file has no table or version (L368-374, L549-575, L619); "run it again" (L305) is unlisted. Refuted: Credentials commands are added to the contract at L523-527; rounds-exceeded is resolvable by cancel, edit contract or resume (L66, L79-80); tasks may have no project (L556), so milestone 2 is not blocked.

**Verifier 1's fix.** Mechanical part: extend L436 to match L164, L174, L305 and L527: create a project, edit a brief, change a task's priority or project, resume and change a seat, re-run a check, plus the Credentials commands. Decisions: (1) contract-draft trigger: an owner "Draft contract" command on a Backlog task (recommended), or cut the planner, `draft` step and job kind; (2) role files: four fixed texts versioned with the app (recommended), or a table with an edit command; (3) name the rounds-exceeded choices: one more round, edit contract, cancel; (4) priority on the Add task form, or default only.

**Verifier 2: confirmed.** Confirmed against L436. Pause seat opens `wait_seat` (L214), but nothing emits `seat.resumed` (L174). No command writes `project.created`, `brief.changed`, `task.changed` (L164) or `seat.changed`. Priority (L422, L556) is absent from the form (L608). L305 "run it again", L109 "send the task back for rework" and the L98 item have no command or lifecycle row. Nothing queues the draft job (L202, L406-407). The role file (L368, L374) has no store or version. Only L527 is already determined. I would guess every other command, trigger and payload.

**Verifier 2's fix.** Mechanical part: add L527's commands and "resume a seat" to L436. Priority is a decision, not mechanical as the reviewer says. Decide: (1) create project, edit brief, change task priority/project, change seat: add commands (recommended), or drop those events and priority ordering. (2) Draft trigger: owner "Draft contract" on a Backlog task (recommended), or cut the planner. (3) Role files: four shipped texts versioned with the app (recommended), or a table. (4) Rounds-exceeded choices, "run it again" and "send back for rework": add commands with lifecycle rows (recommended).

### 16. Most Needs you items and several holds have no reason code, no defined choices and no command that ends them; one offered choice has no command behind it

- **Lines:** 61-80, 98, 109, 113, 121, 298, 305, 327, 349, 398, 436, 571, 610, 719
- **Rated:** major by both verifiers
- **Fix:** the owner has to decide
- **Found by:** consistency inventory, product and scope

`inbox_items` stores choices, but only two kinds list them: a check error and a stopped action. Holds are a fixed list, but three situations that hold a task name no reason: a claim gate failing for 3 different seats, a model gate exceeding 3 re-runs ('goes to the owner'), and a rule no seat can satisfy. For `rounds_exceeded`, the 3-seat claim failure, the re-run limit, `access`, a task budget cap and a project budget pause, nothing says what the owner can choose or which command closes the hold; the owner list has only a generic 'hold and resume', and which holds that 'resume' may close is not stated. The Needs you screen list omits the claim-gate and re-run kinds entirely. For a stopped action the owner may 'send the task back for rework', yet the lifecycle table has no command from Finishing to Working and the owner command list has none either.

**Effect.** Tasks reach these holds with no specified way out; inbox item kinds and their choices cannot be put in the interface schema; track E cannot build the Needs you screen and track A has no transitions for its buttons; resuming a rounds-exceeded task immediately re-trips the limit. Owners get items they can read but not act on.

**Verifier 1: partly.** All quotes are exact. Stands: L298 and L327 name no reason from the fixed list (L113); L98, L349 and L398 give no choices or closing command; L79 and L436 offer only a generic resume; L610 omits both kinds; rework from Finishing has no row (L76-80), L121 bars edits there, and test 3 (L644) would refuse it. Overstated: L719 opens an item, not a hold (see L209); a project pause has resume and change budget (L436); questions and approvals have commands; cancel and contract edit work under any hold (L116, L123).

**Verifier 1's fix.** Add one table: inbox kind, hold reason, choices, the owner command behind each choice, and which holds Resume may close. Reasons: (a) add `claim_gate_failed` and `rerun_limit`; (b) fold both into `check_error`, which blurs wait\_owner by reason (L229). Recommend (a). Stopped action: (a) add an owner command from Finishing to Working with its events, round effect and reopened criteria; (b) drop the rework choice at L109. Recommend (a), since L109 already promises it. Also add the missing kinds to L610 and allow a project as inbox subject (L571).

**Verifier 2: confirmed.** Cases I cannot write. (1) Three seats fail a `task.before_claim` gate (L298), or a fourth changed submit hits the re-run cap (L327): `hold.opened` needs a reason and L113's fixed list has none. (2) Owner picks "send the task back for rework" (L109): no Finishing-to-Working row in L61-80 and no owner command at L436, so test 3 (L644) is unwritable. (3) `rounds_exceeded` and `access` (L98, L398): no choices, no closing command. Overstated: L719 opens an item, not a hold; "immediately re-trips" is unsupported.

**Verifier 2's fix.** Add one table: inbox kind, subject, hold reason, choices, owner command per choice. Recommend distinct reasons `claim_gate_failed` and `rerun_limit`; do not fold into `check_error`, whose "run it again" (L305) defeats L327 and blurs L229. Add "Return for rework", Finishing to Working: round up, stopped action back to contracted, unreported approvals revoked, done actions stay done. `rounds_exceeded`: one more round, raise minimum rank, or cancel. `access`: granted or cancel. Project as inbox subject. L719: workspace item, no hold; add to L610. Alternative: drop the rework choice.

### 17. The role file is required in every briefing from milestone 2 but is never defined, stored, versioned or editable; briefing is owned by a milestone-3 track

- **Lines:** 25, 49, 68, 358, 368-374, 380, 392, 436, 554-555, 619, 666, 669, 680
- **Rated:** major by both verifiers
- **Fix:** the owner has to decide
- **Found by:** consistency inventory, build plan, product and scope

The briefing must contain 'the seat's role file', its version feeds the briefing hash, it sits third in precedence, and the core-loop milestone's briefing consists of only the brief, the role file and the contract. But the roles library is a non-goal, the Roles settings section is 'later', no table or field holds a role file or its version (`seats` has only a role name), and no owner command or event creates or edits one. `brief_entries` likewise has no version field for the hash 'computed over the versions of those parts'. no. 102 adds: briefing acknowledgement is required from milestone 2 but briefing belongs to track B (milestone 3), and the Contract lists no interface through which the transition function gets the current briefing hash; and the lifecycle table allows Acknowledge briefing only from Working by the Holder, while a reviewer must acknowledge In review, so Test 3 would refuse the reviewer's acknowledgement.

**Effect.** The first milestone that needs a briefing cannot produce one or hash it; tracks A, B and D will each invent a source for role text (or ship an empty one that precedence ranks above the contract), and `briefing_changed` cannot be triggered deterministically. Track A cannot enforce 'no work call before acknowledgement' in milestone 2 without B's code, and the state table contradicts the reviewer flow.

**Verifier 1: partly.** All seven quotes are exact. Not refuted: role file is required (L49, L368, L373-374, L380) but has no table, field, version, command or event (L436, L555); L25/L619 defer Roles; Terms, Risks and Open decisions are silent. `brief_entries` (L554) has no version for L369, and L436 has no brief command. L68/L392 allow acknowledgement only by the Holder in Working, contradicting L373. Overstated: tracks are parallel, not tied to milestones (L653, L687), and L669-670 put the briefing in milestone 2; only the missing briefing interface (L666) stands.

**Verifier 1's fix.** Options: (a) four fixed role files shipped with the app, read-only, versioned by release; (b) a versioned role text per seat with an owner command and `seat.changed`; (c) drop the role file from version 1. Recommend (a): it matches the non-goal at L25 and L619. Also add a brief version counter per project raised by `brief.changed`, add a briefing-hash interface to the Contract list (L666), and extend the Acknowledge briefing row (L68, L392) to the reviewer in In review and the builder in Finishing.

**Verifier 2: confirmed.** Role file is required (L49, L368, L373-374, L380) but no table, field, owner command or event holds it (L436, L554-555); roles are a non-goal (L25, L619). The hash needs "versions" (L369); brief\_entries has none (L554), and no column stores the acknowledged hash (L556, L559). L68 allows ack only from Working, yet the reviewer acks In review (L373) and action-done in Finishing is a work call (L371); no review ack path exists (L403-405). Contract list (L657-668) has no briefing interface. Overstated: tracks are not milestones (L687).

**Verifier 2's fix.** Options: (a) four fixed role files shipped as static text, read-only, versioned by release; (b) versioned editable role text, which reopens non-goal L25; (c) drop the role file from the version 1 briefing. Recommend (a). Also: add a per-project brief version bumped by `brief.changed`; store the acknowledged hash on tasks and reviews; allow Acknowledge briefing in Working, In review (reviewer) and Finishing, with a review ack call; keep briefing in track B and add its hash interface to the Contract list.

### 18. The Tracks table leaves milestone 4 work, shared machinery and several commands unowned; the milestone-2 briefing belongs to a milestone-3 track

- **Lines:** 306, 374, 436, 636, 653, 666, 669-671, 679-685, 719
- **Rated:** major by both verifiers
- **Fix:** the owner has to decide
- **Found by:** consistency inventory, build plan

Seven tracks are said to have separate ownership, but no track's 'Owns' column contains: worker questions and answer jobs; outward actions, approval jobs and Finishing; escalation; holds and the Blocked lane logic; Needs you and Decided for you records and logic; budget holds, budget and cost reports; the job queue in general and non-check jobs (B owns only 'check jobs'); orchestrator-offline detection and requeue (which crosses C last-polled, A timers, B requeue and the inbox, while the Contract lists one in-process interface only); seat and project management; content deletion; backup and restore; the 50-seat load harness. That is the whole of milestone 4 and more. Promote, edit contract, cancel, hold, pause project or seat, delete content, access requests and cost reports appear in no milestone. Track B (Rules engine) owns the briefing, yet briefing acknowledgement is mandatory in the core-loop milestone, which says 'No rules yet' and is otherwise tracks A, C and D. Required tests 1 to 8 include none for questions, actions or inbox behaviour.

**Effect.** Parallel agents given disjoint file sets will either all skip milestone 4 or collide in the transition function and job queue; two tracks build the same thing differently (inbox, job queue) or neither builds it; the core loop stalls waiting on a track B deliverable; release criteria for cancel, restore and the offline item have no owner to deliver them.

**Verifier 1: partly.** Quotes are exact. Overstated: Finishing, holds, cancel, escalation are lifecycle commands (L61-80) inside the one transition function (L13, L131, L436) that A owns, verified by test 3 (L644); C owns all calls (L681), E the screens (L683); test 4 covers policy hooks on/off (L645). Tracks run in parallel (L687), so the B briefing does not stall M2. Stands: non-check jobs (L47 vs L680), inbox, offline detection, backup (L636, L709) and load measurement are unowned; cancel (L706), promote, edit, pause, delete, planner drafts are in no milestone; M3 needs holds and Needs you (L260, L305-306) scheduled in M4 (L671).

**Verifier 1's fix.** Options: (1) extend existing rows: A owns holds, questions, actions, inbox records, cancel, offline detection; B owns the job queue for all four job kinds; C or D owns backup, restore and the 50-seat measurement. (2) Add an eighth track for questions, approvals and inbox. (3) State a default: whatever writes an event is A's unless listed elsewhere. Recommend 1 plus 3. Also assign every command in L61-80 and L436 to a milestone, move holds and Needs you records ahead of rule checks, and add an inbox and question-routing test.

**Verifier 2: partly.** Core holds. L679-685 name no owner for question, approval or draft jobs (L680: only 'check jobs'), inbox, question records, offline detection (L306), restore (L636) or the 50-seat run (L630). L666 lists one in-process interface, so I must guess which others L657 demands; e.g. blocking question, orchestrator job, pass-on, hold, inbox item, owner answer. Overstated: test 4 (L645) covers policy hooks and test 3 Finishing; L436 puts owner commands in A's transition function; no line bars B from milestone 2; L660 covers all commands regardless of milestone.

**Verifier 2's fix.** Options: (1) A owns all lifecycle state: holds, actions/Finishing, escalation, cancel, questions, inbox, briefing hash/ack; B owns the whole job queue (check, question, approval, draft) and supplies rules to the briefing; A times offline detection, B requeues. (2) Add an eighth track for milestone 4. Recommend 1. Either way extend L666 with job-queue, inbox, hold and briefing interfaces, give every command a milestone, and name owners for restore and the 50-seat run. Instead of a ninth test, require golden traces for a blocking question and a stopped action.

### 19. An approved action can go out while the app blocks or erases its report

- **Lines:** 39, 105-109, 116, 123
- **Rated:** major by both verifiers
- **Fix:** the owner has to decide
- **Found by:** state machine

With several actions, approval is asked for each, but nothing says whether the builder starts after the first approval or after all, or in what order. If action A is approved and B is stopped, the `action_stopped` hold blocks report action done, so A can be carried out and stay unreportable. If the owner then cancels, or any cancel lands after an approval, the approval is revoked and the builder's report is refused with `task_cancelled`. The log then shows an irreversible action as revoked and never done.

**Effect.** The audit trail is wrong for payments, publishing and deletion, the cases it exists for. The owner chooses waive, rework or cancel without knowing that A already went out.

**Verifier 1: confirmed.** All five quotes are exact (L39, L105, L109, L116, L123). Nothing settles sequencing: L106 says "Once approved" in the singular, and L208, L211 and L388 hint at per-action dispatch, which makes the mixed case reachable. L116 blocks report action done under any hold. L123 revokes unreported approvals and refuses the holder. Risks (L716, L726), Open decisions (L746-747) and Audit (L634) do not cover an action in flight. One nuance: waiving B lifts the hold, so A stays unreportable only under cancel, or under rework, whose effect on A is unspecified.

**Verifier 1's fix.** Option 1 (recommended): the builder's Finishing lease starts only when every action is approved or waived, and actions run in contract order. Option 2: per-action dispatch as approvals arrive, as L208, L211 and L388 hint, with each mixed outcome spelled out. Under either, exempt report action done from holds (L116), accept it after cancel for an action that had been approved (L123), and say what rework does to already-approved actions (L109). Add a golden trace for cancel during an action.

**Verifier 2: confirmed.** Holds with one action and no guessing: approval gives the builder a lease (L106), it pays, the owner cancels (L80). L123 writes `action.revoked` and the report is refused `task_cancelled`, so `actions.state` is revoked for a sent payment. Any hold does the same through L116 (`owner_hold`, `budget`, `project_paused`). With two actions, L105-106 do not say whether A's approval alone starts the lease, or which action `GET /v1/next` (L388) hands out; I would guess both for the state table and golden traces. Lease expiry in Finishing (L78, L87) is a third route.

**Verifier 2's fix.** Recommend: (1) the lease starts only when every action is approved or waived; `actions` needs a position, since L561 has none. (2) Report action done is accepted under any hold, and only `task.done` waits for holds. (3) Make start-action required, not optional: cancel, release or expiry with a started action does not write `revoked` and opens Needs you. The reviewer's accept-after-cancel contradicts L355/L415 (a builder changes only the task it holds) and L123, so it needs an explicit former-builder exception. Alternative: per-action leases, each mixed outcome specified.

### 20. claim-next cannot skip a task: a seat refused at `task.before_claim` (or one that released a task) is handed the same task forever; cached results and the three-seat hold misbehave

- **Lines:** 261, 293, 297-298, 300, 318, 326, 390, 402, 422-423
- **Rated:** major by both verifiers
- **Fix:** the owner has to decide
- **Found by:** state machine, rule checks, interfaces

With claim-next the server picks the task (highest priority, then oldest) and the seat cannot name or decline one. Eligibility does not exclude tasks this seat already failed the claim gate on, or tasks it released. A stored `failed` is reused for identical inputs (contract version and seat), so every later claim-next by that seat picks the same top task and is refused instantly, without end. An `error` result is never reused, so each retry reserves the task again and queues a new model job. The 3-different-seats hold only fires in a workspace with three builder seats that all fail; with fewer the owner is never told; with three, the hold stops stronger seats claiming, defeating an agent-dependent rule; the hold has no reason in the fixed list. Results cached on contract version and seat also mean a rule that 'must hold at the moment work begins' is not re-judged, contradicting 'every time a seat tries to claim'. A provisional claim holds nothing, so one seat can reserve several tasks.

**Effect.** One seat-dependent claim rule on the top task, or one task a seat cannot do, starves that seat of all other Ready work silently, with no hold and no Needs you item. With one or two builder seats (the core-loop milestone and first-provider setup have exactly one) the workspace stops. Track C cannot write claim-next's selection rule.

**Verifier 1: partly.** Partly. Stands: eligibility (L423) ignores a seat's stored `failed` claim check, reused per L318/L326, so claim-next (L390, L422) re-picks the same task; the 3-seat hold (L298) has no reason in L113 or Needs you kind in L610 and cannot fire with fewer builders; reuse contradicts L293/L300. Refuted: `error` opens a `check_error` hold (L305), making the task ineligible, so no retry loop; core loop has no rules (L669) and no shipped rule uses this hook (L339-347); L719 promises detection; L277 revalidation prevents double holding.

**Verifier 1's fix.** A (recommended): claim-next skips a task while this seat has an un-overridden stored `failed` `task.before_claim` check for the current contract version, rule version and round; state whether `passed` is reused at this hook; replace "3 different seats" with "every enabled builder seat that meets the rank", add a hold reason and a Needs you kind; count a provisional claim as holding. B: add claim-by-id or a skip list to the interface. C: keep head-of-line blocking, document it, and open a Needs you item after repeated refusals.

**Verifier 2: partly.** Core holds. S1 claim-next picks T1 (L422); a custom claim rule fails (L261, L297). On the retry every L423 condition is true, T1 is picked again and the stored `failed` is reused (L326). T2 is never offered; L298 needs 3 seats. The L298 and L327 holds have no reason in L113 and no kind in L610. Whether a pending claim counts as "holds" (L423) is unstated. Wrong: an `error` holds the task with `check_error` (L305), so no retry loop; core-loop has no rules (L669). Reuse (L318, L326) is explicit; only L293/L300 wording conflicts.

**Verifier 2's fix.** Decide claim eligibility. Recommend: claim-next skips a task whose `task.before_claim` check for this seat is `failed` and not overridden under the current check key (L313), and a pending claim counts as holding. Hold at 3 failed seats or every enabled builder seat meeting the rank, whichever comes first, keeping L327; add one hold reason and one Needs you kind. Keep L326 reuse and drop "must hold at the moment work begins" (L300). Reject excluding released or lost tasks: it strands rework (L94) with one builder. Reject claim-by-id.

### 21. Escalation sets a rank nobody defines, and can leave a task in Ready with no seat able to claim it

- **Lines:** 74, 96, 345, 423, 610, 719
- **Rated:** major by both verifiers
- **Fix:** the owner has to decide
- **Found by:** state machine

Escalation sets a minimum strength rank, but no value is given: the rule's only parameter is the failure threshold. If no enabled builder seat reaches that rank, which is the usual case when the strongest seat built the task, the task waits in Ready with no hold. The Risks table promises detection, but no hook, hold reason, inbox kind or trigger for it appears in the contract lists. The Review fails row names only Working as the target although escalation sends the task to Ready. Nothing says the rank is ever cleared.

**Effect.** The strongest builder's twice-failed task vanishes into Ready. Track A cannot implement escalation without inventing the rank formula, and the promised detection has no specification to build from.

**Verifier 1: confirmed.** All quotes are exact and I could not refute the core. No rank value exists: L96 and L345 give only the threshold, and L555/L556 merely name the columns. L96's "If the previous builder is below it" leaves the formula open. L719 promises detection, but hold reasons (L113), Needs you kinds (L610), hooks (L258-268) and events (L164-177) carry nothing for it; L739 covers the provider rule only. L74 omits Ready, contradicting L96. Nothing clears the rank (L121, L345, L756). Overstated: the task stays visible in Ready (wait\_ready, L205), not vanished.

**Verifier 1's fix.** Decide three things. (1) Rank formula: recommend the previous builder's rank plus one, matching the rule name "stronger model"; the alternative is a target-rank parameter. (2) No enabled builder seat meets it: recommend no escalation, rework stays with the builder, and a Needs you item opens under a new inbox kind shared with the provider rule's case (L719). (3) Whether turning the rule off or a contract edit clears the rank; recommend both do. One part is mechanical: the L74 To cell should read "Working, or Ready if it escalates", per L96.

**Verifier 2: confirmed.** Case: top-ranked builder B claims T and two reviews fail. The `review.failed` hook (L266, L345) must set the task's minimum strength rank (L556, replayed L591), but L96 gives no value and the only parameter is the threshold. I must guess the value, the `task.reassigned` payload, and whether B keeps a lease (L94) or T goes to Ready, which L74 omits. If the rank exceeds B's, L423 leaves T unclaimable with no hold (L113) and no inbox kind (L610) behind L719. Clearing is unstated. L278 also omits `review.failed` rows.

**Verifier 2's fix.** Recommended: escalate only if an enabled builder seat ranks strictly above the previous builder; the minimum becomes the lowest such rank. Avoid "plus one": L555 gives rank no type. Otherwise no escalation: same builder, no `task.reassigned`, and the round limit (L98) catches it. L74 To becomes "Working, or Ready if it escalates" (L96 already says so). Keep the rank until Done or Cancelled: clearing on rule-off needs a per-task event the registry lacks (L164, L591). Add an inbox kind for L719. Alternative: an explicit target-rank parameter.

### 22. Batched multi-task changes contradict same-transaction, one `at` per command and a single idempotent outcome

- **Lines:** 132-134, 136, 213, 268, 307, 625, 756
- **Rated:** major by both verifiers
- **Fix:** the owner has to decide
- **Found by:** event log

Principle 3 says a change touching many tasks runs in bounded batches, which means several transactions. Principles 2 and 4 and the Atomicity requirement say a command commits everything together and all its events share one `at`. Pausing a project, a budget pause from one cost report, switching a rule off, an orchestrator returning, or pausing a seat each change steps on many tasks. Nothing says what commits first, what effective time later batches carry, who continues after a crash between batches, what a same-key repeat returns part-way, or whether seats may still act on tasks not yet reached.

**Effect.** Tasks in later batches keep accruing working time and lease time after a pause, or get holds stamped later than the pause. Tracks A, B and C will each resolve it differently.

**Verifier 1: partly.** Quotes at L133, L134, L625 and L756 are exact; "batch" appears only at L133, and Open decisions and Risks do not settle it. The finding stands for project pause/resume, budget pause (L268, L346) and rule switch-off (L287): each changes steps or lease clocks on many tasks (L89, L213, L556). Refuted for seat pause: a seat holds one task (L90, L749). Weak for orchestrator return (L307): app-originated, no command key (L157), so L134 and L136 do not bind. L136 already defines a "pending" outcome; L423 and L562 partly cover unreached tasks.

**Verifier 1's fix.** Options: (a) every owner or seat command is one transaction; restrict "bounded batches" at L133 to app-originated work (the sweep, re-queue on orchestrator return), each batch its own transaction with its own `at` and empty `command_id`. L724's "tens of seats" supports this. (b) Commit the project or rule fact once and apply per-task effects lazily with effective time equal to the command's `at`; this needs L86 and L149 widened beyond timer events. Recommend (a), and add (b) to Open decisions as the path if the lock limit is measured.

**Verifier 2: confirmed.** Real. L133 allows batches, but L132, L185 and L625 put a command's events and steps in one transaction, L134 gives one `at`, and L149 lets `effective_at` differ only for timers. Case: owner pauses project P at 10:00:00; batch 1 reaches T1; seat S2 submits T2 at 10:00:01; batch 2 runs at 10:00:02. I must guess T2's submit outcome, its `wait_owner` and lease-pause time (L89, L213), the same-key outcome (L136) and crash recovery. Golden traces (L649) need these. Seat pause is no case (L90); orchestrator return (L307) has no command key.

**Verifier 2's fix.** Options: (a) every owner or seat command is one transaction; batching stays only for app-originated work with no key (the sweep, the re-queue at L307), one task per transaction. (b) commit the project or rule fact once and apply per-task effects as timers due at the command's `at`; this needs L86 and L149 widened, and reads that tolerate stale open steps. Recommend (a): the L724 scale allows it and L185 and L625 stay true. Also decide whether a project pause writes per-task `hold.opened` events or one project hold (L562).

### 23. A refused command's outcome is not final: overrides and automatic re-runs complete it later

- **Lines:** 136, 157, 288-289, 296-297, 307, 388, 425, 563
- **Rated:** major by both verifiers
- **Fix:** the owner has to decide
- **Found by:** event log

A refused transition tells the holder to resend with a new key. Yet an override 'completes it at once', writing events under the original key, so a key the seat already read as refused turns completed; a resend may already exist. Errored checks are also queued again on their own after the transition was refused and, for a claim, after the reservation lapsed; what a late `passed` does is unstated. The 'holder's lease is live' condition cannot be met at `task.before_ready` (owner or planner, no lease) or `task.before_claim` (no lease until the check passes). `GET /v1/next` has no kind announcing a command outcome, although line 425 promises one.

**Effect.** Clients cannot treat any outcome as final; a task can move to In review while its builder is still editing or resubmitting. The commands table, pending\_transitions states and the idempotency test have no single meaning.

**Verifier 1: partly.** Quotes exact, but L289 is cut: its 'inputs are unchanged' and 'Otherwise it applies to the next request' clauses give before\_ready and before\_claim (L65, L296) a defined fallback and block completion after a changed resend; L277 re-validation, L284 and L326 prevent double completion. L136/L389 say 'current outcome', so finality was never promised; test L646 holds. Still unrefuted: what a re-run `passed` does to a refused, held transition (L305, L307, L297; L289 covers overrides only), 'completes at once' where failure is not a refusal (L263-264), and L425 versus L388's kinds.

**Verifier 1's fix.** Decide before the contract is written. (a) Refused is terminal: an override or a re-run `passed` only stores a reusable result (L326) and closes the `check_error` hold; the requester resends with a new key, prompted by a new `GET /v1/next` kind. (b) Keep in-place completion, extend it to re-runs, define it per hook, add a `command` kind. Recommend (a). Either way, add one line each for `task.before_done` and `action.requested`, where failure is a failed review or a stopped action, and make L425 agree with L388.

**Verifier 2: confirmed.** Case: submit K1 fails (L277); builder resends K2 with the same inputs, the stored `failed` is reused (L326), K2 is refused. Owner overrides the one shared check row (L328, L583). L289 "completes it at once": K1 or K2? L157 implies K1, a key already read as refused (L136, L389). At `task.before_done` the failure already raised the round and returned the task (L263), so completion contradicts L75's From. L277 makes `error` a refusal, yet L305-307 re-run it; a late `passed` is undefined. L388 has no kind for L425.

**Verifier 2's fix.** Options: (a) refused is terminal for a key; an override or re-run only stores a result the next request reuses (L326), and L289 loses "completes it at once"; (b) in-place completion, defined per hook. Recommend (a), but it is not one rule for five hooks. Still to decide: override at `task.before_done` (round is in the check key, L313, so nothing reuses it) and at `action.requested` (the server is the requester, nobody resends); whether `error` refuses or stays pending; and whether L388 gains a kind or L425 drops `GET /v1/next`.

### 24. Holder, builder and 'ever held' are never defined; a reviewer is both 'never a holder' and a caller of Holder-only calls, and Acknowledge briefing is allowed only in Working

- **Lines:** 68, 88, 94, 106, 121, 246, 332, 344, 354, 371-373, 391-392, 396, 399, 403-406, 415-416, 556, 591, 644, 669
- **Rated:** major by both verifiers
- **Fix:** the owner has to decide
- **Found by:** event log, rule checks, interfaces

Replay must reproduce `tasks.holder` and `tasks.builder`, but no rule says when each is set or cleared: In review, Finishing before approval, after release or expiry, after a contract edit or an escalation; 'the previous builder' must survive some of these. Reviewers hold a separate review lease, yet must acknowledge a briefing before a verdict through a call open only to the 'Holder', in a lifecycle row limited to Working to Working; the briefing, ack, cost and question calls are all /v1/tasks/{id}/... restricted to Holder, the review calls are claim-next, heartbeat, release and verdict only, and the verdict carries no tokens or spend. Under Test 3 any pair not in the table is refused, so a reviewer In review and a builder in Finishing (who must re-acknowledge before reporting an action done when a rule or brief edit changes the hash) can never clear `briefing_not_acknowledged` or `briefing_changed`. 'No seat that has ever held a task may check or review it' is undefined: if a reviewer counts as a holder, the round-1 reviewer is barred from round 2 and milestone 2 (one reviewer, one failed review) is impossible; if not, it cannot acknowledge, ask or report cost. Under a builder-only reading the rule excludes nobody, because each seat has one role and builders cannot claim reviews or jobs, unless a role can change (`seat.changed` is unspecified). It does not stop a planner judging its own draft, and the roles a checker may name are not listed although only orchestrators and planners can claim jobs. Also unstated: whether an acknowledgement survives a fresh lease when the hash is unchanged, and whether an acknowledgement is refused with `pending`.

**Effect.** Track A, building from the state table, refuses the reviewer's acknowledgement; track B then refuses every verdict, so no review can complete once the briefing check is on (from the core-loop milestone). Tracks A, B, C, D and F derive different holder/builder values and past-holder sets, so replay cannot match and the result is either refused second-round reviews or an independence guarantee that does nothing. Reviewer spend never reaches the budget rule. A rule naming a builder or reviewer role as checker can never run.

**Verifier 1: partly.** All quotes are exact. Stands: "Holder" is undefined and inconsistent (L355 says a reviewer "holds" a task; L121 "releases its holder" In review; L391-399 vs L403-405), so the reviewer acknowledgement L373 requires has no call or lifecycle row (L68, L392), nor has a Finishing re-ack (L371-372). Refuted: the round-2 bar (L48, L416, L344, L669: reviewers hold reviews, not tasks); pending (L285); lease states (L78, L88, L94, L106); track divergence (L13, L679: one writer). Checker-role points are speculative (L362).

**Verifier 1's fix.** Decide how a reviewer reaches the briefing calls. Option A (recommended): define Holder in Terms as the seat with the live builder lease and "held" as having had that lease; add /v1/reviews/{id}/briefing and /ack-briefing; extend the Acknowledge briefing row to In review (reviewer) and Finishing (builder); reword L355. Option B: widen Holder on the briefing, ack, question and cost calls to include the current reviewer. Either way, state whether reviewers report cost and ask questions (recommend spend on the verdict, no questions in version 1).

**Verifier 2: confirmed.** Case: B claims, acks, submits. R claims the review (L403) and must ack (L373), but the only ack call is task-scoped and Holder-only (L392), and its row is Working only (L68). Test 3 (L644) refuses it, so the verdict fails `briefing_not_acknowledged`. L355 says a reviewer "holds" the task, L332/L354 bar past holders, yet L669 needs one reviewer twice. I must guess holder/builder (L591) In review, in Finishing and after release. Overstated: L285 already refuses ack while pending; L436 has no role-change command.

**Verifier 2's fix.** Options: (a) review-scoped briefing, ack and cost calls, plus Acknowledge rows for In review (reviewer) and Finishing (builder); (b) widen Holder to the current reviewer. Recommend (a). Define holder = seat with the live builder lease; builder = last claimant, kept through In review and Finishing, cleared on return to Ready or Backlog; "held" = had a builder lease; ack kept per seat and hash. Corrections: keep L285 (ack refused while pending); checker role orchestrator only (L417-418), not planner; reword "holder" in L285, L289, L355; say how holderless Finishing (L78) regains a builder.

### 25. Content deletion has no defined scope against replay, and content is copied into tables, backups and logs it does not reach

- **Lines:** 137, 139, 559, 563, 566, 568, 572, 592, 594, 627, 633, 635-636, 638, 757
- **Rated:** major by both verifiers
- **Fix:** the owner has to decide
- **Found by:** event log, security and privacy

The PRD promises that content can be deleted without touching the log, but never lists what content is. Content is copied into places deletion is not said to reach: stored command results in `commands` (a claim result carries the whole briefing, kept at least 7 days), `jobs.result`, `rule_checks.reason` and `pending_transitions.reasons` (model-written text quoting the task), `reviews.notes`, Needs you items, daily backups with no retention period, and a server log of every refused command. If deleting removes rows (criteria, a removed custom rule, a removed seat), replay recreates them from events and the live tables no longer match, so the replay test fails after any deletion; events still reference those ids as actor, subject and past holder. Separately, the replay must rebuild a rule check's override, which includes the owner's free-text 'why'; that text must then live in an event payload, which principle 7 forbids, and it could never be deleted.

**Effect.** 'Delete content' leaves the contract, questions and model reasons readable in the database, backups and logs, so the privacy promise cannot be relied on; or deletion breaks replay and the who-may-review check. The `check.overridden` payload schema cannot satisfy both the replay list and the no-content rule.

**Verifier 1: partly.** Quotes are exact. Stands: nothing lists what `content.deleted` blanks; text copies sit in L559, L563, L566, L568, L572 (claim result returns the briefing, L390; kept 7 days, L627); backups have no retention (L636); L757 only restates the promise. L594 with L566 puts free-text "why" in replay against L137, though L598 excludes text. Refuted: replay breaking, since every deletion writes an event (L635, L171, L174, L175) that replay also applies; who-may-review, which reads the log (L332); inbox text (L571 holds references only); log bodies (L638, speculative).

**Verifier 1's fix.** Decide before the contract. Option A (recommended): never delete rows; `content.deleted` blanks a per-table list of text columns in Data model, including stored command results, job results, check reasons and review notes; seat and rule removal become flags. Option B: delete rows and have replay apply the deletion events. Either way, state a backup retention period and keep request bodies out of server logs. One part is already determined by L137 and L598: L594 should read "result and override (who and when)".

**Verifier 2: partly.** Three real guesses. (1) Owner overrides check C with a free-text why: L594 and L566 put it in replay, L137 bars text from payloads, L598 puts text outside replay; events are immutable (L579). (2) Delete task T's content: L137/L635 name no columns, yet contract text also sits in `jobs.result` (L407), `commands` (L390, L572), reasons and notes (L559, L563, L566). (3) Seat or rule removal: row or flag unstated; L700 needs versions kept. Overstated: replay applies deletion events too; past holders come from the log (L332); `inbox_items` (L571) has no text; backups and logs are outside the Contract.

**Verifier 2's fix.** Option A (recommended): never delete rows. `content.deleted` blanks a listed set of text columns per table: title, goal, criterion text, evidence, questions, action descriptions, review notes, check and transition reasons, job results, stored command results, and brief entries for a project. Seat and rule removal set a flag. Option B, deleting rows, contradicts L596, L633 and L700. The override part is already determined: at L594 override means who and when; why is text, outside replay per L598. Backup retention and log contents belong in Open decisions; the reviewer's 30 days is invented.

### 26. Overrides cannot take effect at three of the five gated hooks

- **Lines:** 109, 263, 289, 296, 313, 328, 699
- **Rated:** major by both verifiers
- **Fix:** the owner has to decide
- **Found by:** rule checks

Override either 'completes at once' (needs a holder with a live lease) or applies to 'the next request with the same inputs'. At `task.before_done` the failure itself raised the round and moved the task to Working; round is in the check key and the next review has new notes, so neither mode applies. At `action.requested` there is no holder before approval, no command re-requests a stopped action, and the stopped-action choices exclude override. At `task.before_ready` and `task.before_claim` no lease exists, so only the second mode works. A rule edit in between (new version) orphans the override too.

**Effect.** Goal 6 and the release criterion at L699 hold only for `task.before_submit`. An owner who disagrees with a rule at review-passed or before-anything-goes-out can only turn it off for the whole workspace.

**Verifier 1: partly.** Quotes at L109, L289, L296, L313, L699 are exact. Stands for two hooks, not three: a failed `task.before_done` gate already raised the round and returned the task to Working (L263), and round plus review notes are in the key (L313, L320); a stopped action has no holder (L106), no re-request command (L436) and no override choice (L109). Nothing elsewhere settles either. Refuted parts: `before_ready` and `before_claim` work through L289's second mode; rule-version orphaning follows from L313/L566/L583; `warn` (L247) and scope (L244) are alternatives to switching off.

**Verifier 1's fix.** Decide override per gated hook. Option A (recommended): add an "Override does" column to the Hooks table. `before_ready`: server completes the stored transition and closes the hold. `before_claim` and `before_submit`: as L289. `action.requested`: a fourth Needs you choice returns a gate-stopped action to approval. `before_done`: follow the decision on that hook's failure handling. State that an override does not carry to a new rule version. Option B: limit override to `before_submit` and errored checks, hide the button elsewhere, and narrow Goal 6 and L699.

**Verifier 2: partly.** Real at two hooks, not three. before\_done: verdict pass, gate fails, L263 has already raised the round and given the builder a lease (L94). Override per L289 then either jumps Working to Done (illegal, L75) or waits for a key that cannot recur (round in key, L313). action.requested: action stopped, no holder (L106), no re-request command, choices exclude override (L109), yet L609 shows the button. before\_ready and before\_claim work through the deferred mode. Rule-version point is already settled by L273, L313, L583: no carry-over.

**Verifier 2's fix.** Decide per hook; reject the blanket 'server re-drives without a lease': it would push a claim onto a seat (L90, L296) and drop L289's lease condition for submit. before\_done options: (a) override exempts the task from that rule version at its next review pass, whatever the round; (b) override undoes the rework while the builder has made no call; (c) no override there, and narrow L609 and L699. Recommend (a). Stopped action: override returns it to requested, so L357's approval still happens; add it as a fourth choice at L109.

### 27. Default check timeouts and 90-second offline detection misfire with one serial orchestrator; 'polled' is undefined and jobs have no heartbeat

- **Lines:** 225, 304-307, 406-407, 555, 629, 631, 698, 742
- **Rated:** major by both verifiers
- **Fix:** the owner has to decide
- **Found by:** rule checks, interfaces

One orchestrator runs checks serially, so a job can wait behind another for the 5-minute run timeout, yet it errors after two 2-minute queue misses: two rules on one hook, or two tasks submitting together, give `error` and `check_error` holds on a healthy system. The orchestrator is offline when no seat of the role 'has polled for 90 seconds', but 'polled' is not defined and jobs have no heartbeat call; a single-threaded runner or an MCP agent inside a model call does not poll, so it is declared offline mid-job. That opens the workspace item, suppresses per-task `check_error` items, and on the next poll re-queues waiting and errored checks automatically, including ones already awaiting an owner choice. Detection needs 90 seconds of silence plus up to 30 seconds of sweep, so 'within 90 seconds' cannot be met. Whether a seat may hold more than one job is unstated.

**Effect.** Spurious holds and Needs you items under ordinary load; a false 'Orchestrator offline' item that flaps on every long check; errored checks re-run without the owner's choice, spending tokens; a release criterion that fails by up to 30 seconds (or passes while normal operation violates it).

**Verifier 1: confirmed.** All quotes are exact (L225, L304, L306-307, L629, L698, L742) and nothing settles it. L304 counts queue time behind a running job; L742 allows a 5-minute run against two 2-minute queue misses. "Polled" appears only as a seats column (L555); jobs have claim and result only (L406-407), and L48, L90, L749 cover tasks and reviews, not jobs. L307 re-queues errored checks unrestricted. L306 plus L629 gives up to 120 seconds against L631, L698, L718. Overstated: the 90-second criterion is flaky, not impossible; misfires need checks over 90 seconds or a deep queue.

**Verifier 1's fix.** Add to Open decisions. (1) Queue timeout: count only while a checker of that role is free (recommended), or raise the default above the run timeout. (2) Liveness: any authenticated call counts, and a seat holding a job inside its run timeout is online (recommended), or add a job heartbeat. (3) On return, re-queue only checks that waited or errored while offline, not ones awaiting an owner choice. (4) Change L631, L698, L718 to 120 seconds, or detect offline on a shorter tick. (5) State one job per seat.

**Verifier 2: confirmed.** Trace: orchestrator claims job A at T0, posts its result at T0+3m, no call between (L406-407 have no heartbeat). L306 never says which calls set `last polled` (L555) or whether a job holder counts as online, so I must guess whether `inbox.opened`/`inbox.resolved` belong in the trace, and whether L307 re-queues an errored check with an open owner item (L305) or a lapsed claim (L297). Job B behind a 4-5 minute A errors at T0+4m (L304, L742). 90s plus a 30s sweep (L629) breaks L631, L698, L718. L90 is silent on jobs per seat.

**Verifier 2's fix.** Recommend: (1) Liveness is any authenticated call, and a seat holding a job inside its run timeout is online; no heartbeat needed, since L304 already makes the run timeout the job deadline. (2) One job per seat; the queue-timeout clock runs only while a seat of the role is online and idle. (3) Auto re-queue only checks that errored while offline (no per-task item, L305), never claim checks; the reviewer's queue/run split misclassifies overload errors. (4) Lower L306 to 60s, keeping L631, L698 and L718 true; the reviewer missed L718. Alternative: 120s in all three.

### 28. The model re-run limit disagrees with its default, has no hold reason, and locks the owner out of a Backlog task's contract check

- **Lines:** 113, 121, 154, 317, 324, 326-327, 608, 610, 742
- **Rated:** major by both verifiers
- **Fix:** the owner has to decide
- **Found by:** rule checks, product and scope

L327 allows 3 runs per round; L742 says 3 re-runs, which is 4. 'Goes to the owner' has no hold reason from the fixed list, no Needs you kind and no choices. The round only rises on a failed review, so at `task.before_ready` the limit is for the task's whole life: each contract edit changes the hashed inputs and reruns the check, so after three failed 'specific details' checks the owner's fourth edit can be neither checked nor overridden (no check row exists for the new inputs); only turning the rule off frees the task. The stated purpose is to stop a builder rewording a note, but here the requester is the owner. Because the work is not hashed, a builder who fixes the real work after a `task.before_submit` failure gets the stored failure back unless the note is reworded, which is the behaviour the limit punishes.

**Effect.** The fixed lists in the contract milestone lack a value this rule needs and the engine has no defined hold to open. An owner iterating on a contract locks their own task and must override or switch the rule off; honest builders spend their three runs rewording notes.

**Verifier 1: partly.** Quotes are exact. Stands: "goes to the owner" (L327) has no hold reason in L113, no Needs you kind in L610 and no choices, yet L664 freezes those lists. The limit is unqualified, so it covers owner-requested `task.before_ready` (L65). Overstated: no lockout, since the owner can override the third failure (L289, L328, L609) or switch the rule off (L756); the fourth-edit outcome is unspecified. Weak: L327 "on changed inputs" can mean re-runs, matching L551 and L742. L324 is a stated choice (L745).

**Verifier 1's fix.** Options: (a) apply the limit only to seat-requested gates, exempt owner-requested Complete contract, and add a hold reason such as `check_limit` with a Needs you kind and choices: allow more runs, override once, turn the rule off; (b) keep the limit everywhere and add the same hold; (c) drop the limit at `task.before_ready`. Recommend (a). Also word L327 as "re-run at most 3 times" to match L551 and L742, and state that a resubmit after a work fix needs changed evidence or a changed note.

**Verifier 2: confirmed.** L327 says 3 runs; L742 and L551 say 3 re-runs (4). Case: round 0, 'specific details' on (L342); owner sends Complete contract with four different contracts (L65, L121, L317). Fourth: no run, 'goes to the owner'. I must guess the hold reason (none fits in L113), the Needs you kind and choices (L610, L571), whether a check row is written (L277, L645) and the refusal (L426). Read literally, passes count too. L324/L326 point holds. Overstated: overriding, then resending the third contract, works (L289, L328).

**Verifier 2's fix.** Decide: (1) one number; recommend 3 failed runs per rule, task and round, counting distinct input hashes only, so passes, timeout retries and 'run it again' do not count. (2) Exempt owner-requested commands, not the whole hook: a planner seat also sends Complete contract (L65). (3) Add hold reason `check_limit` and a Needs you kind with choices: allow more runs, override once, turn the rule off; refusal stays `on_hold`. (4) Hashing a builder-supplied work revision is a new requirement; the alternative is requiring new evidence links.

### 29. The provider-review rule cannot hold after handoff: it is checked only at review claim, no table stores providers that worked, and cross-provider handoff also breaks the privacy line

- **Lines:** 72, 265, 344, 449, 507, 516, 519-520, 555-559, 633, 701, 719, 739, 760
- **Rated:** major by both verifiers
- **Fix:** the owner has to decide
- **Found by:** rule checks, credentials, security and privacy

The rule 'compares the providers that actually worked on the task', but runs once, at `review.assign`, when a reviewer claims. Handoff applies to any run that hits a provider limit, a review included, and follows one global list 'whatever the provider'. A reviewer whose credential is limited mid-review continues on the next credential, which can be the builder's provider or the builder's own credential, and gives the verdict with no further check; L520 corrects the builder side only. No table stores the providers that worked. Because credentials above are never tried, in the recommended two-provider setup a builder on the upper login hands off to the reviewer's provider, leaving no eligible reviewer; the Risks response detects a rule 'no connected seat can satisfy', but seat provider no longer decides that. Which provider an OpenRouter credential counts as is unstated. Privacy: L633 relies on the roster showing each seat's provider, but a task in progress moves, with its content, to a provider the roster does not show for that seat; `seats` has one provider column, and OpenRouter forwards to other hosts.

**Effect.** 'A different provider reviews every task' can be false for a completed review while every recorded check shows the rule satisfied and criterion 701 passes anyway; or reviews wait forever after a routine handoff. Task content reaches providers the owner never chose for that work.

**Verifier 1: partly.** All six quotes are exact. The core stands: the rule runs only at `review.assign` (L72, L265, L403), nothing re-runs it at handoff or verdict, and L701 and test 4 (L645) cover claim time only. Builder handoff into the reviewer's provider (L516, L760) leaves a two-provider setup (L739) without a reviewer. Overstated: L519 already requires recording the credential, and L332 derives sets from the log; L719 and L209 as worded surface the stall; the owner sets the order (L509) and the log shows the switch (L540), so the privacy point is minor.

**Verifier 1's fix.** Option 1 (recommended): reverse L760 and keep handoff inside one provider in v1. This removes both cases and keeps the two-provider setup of L739 working. Option 2: keep cross-provider handoff, refuse a reviewer handoff into any provider that built the task (hold `credential_limit` instead), derive that set from `task.claimed` and `credential.switched` as L332 does for holders, and say the L719 detection is per task. Either way: state whether OpenRouter, and a login versus an API token of one vendor, count as the same provider, and add a release criterion for the handoff case.

**Verifier 2: partly.** Real guess. List: Claude login, Codex login, Claude API. A Codex reviewer passes `review.assign` (L72, L265), hits its limit, L516 moves it to Claude API, and the verdict runs only `task.before_done` (L75): Claude reviewed Claude, and L278 writes no row. Reversed: builder Claude to Codex, L520 then refuses the only reviewer; L719 detection is unspecified. `tasks`/`reviews` hold no credential (L556, L559); L519 never says where it is recorded. OpenRouter's provider is undefined (L449). Overstated: privacy (L633), since the owner ordered the list (L760), and "recorded checks show satisfied".

**Verifier 2's fix.** Options. (1) Flip L760: handoff stays inside one provider in v1; drop L520's second sentence; adjust L516, L540, L541. L633 and L701 then hold. No per-project setting: L507 says one list. (2) Keep cross-provider: put credential and provider in `task.claimed`, `review.started`, `credential.switched` payloads; reviewer handoff skips builder-set providers, else `credential_limit`; detection per task. Recommend (1). Either way decide OpenRouter's provider; "routed vendor" conflicts with one provider per credential (L574). Do not extend to orchestrator handoff: L344 covers reviewers only.

### 30. Three different conditions for the limit hold, and 'earliest reset time' has no defined set

- **Lines:** 215, 516-517, 521, 541
- **Rated:** major by both verifiers
- **Fix:** the owner has to decide
- **Found by:** credentials

The hold opens when 'no credential below is available' (handoff text), while `wait_limit` is open while 'every credential that could run the task' is limited (step table), and the acceptance line says 'With every credential limited'. Because credentials above are never tried, these differ whenever the limited credential is not first in the list. 'The earliest reset time' does not say of which credentials: all, those below, or including the seat's own. A seat working on a handoff credential that then limits is held even if its own credential, above, has already reset.

**Effect.** Tracks A, F and G implement different triggers; the acceptance test passes or fails depending on list position. Tasks sit held while a usable credential exists.

**Verifier 1: partly.** All four quotes are exact. The "three triggers" part is mostly a misread: L521 is the operative rule, L541 is its special case (every credential limited implies none below is available), and L215's "could run the task" fits L516's "above are not tried". What stands: "earliest reset time" (L521, L541) names no set. If a credential above resets first, L541 passes or fails by reading, and L516-517 leave nothing to resume on. L215's subject "The credential" is likewise unspecified. Open decisions (L760) and Risks do not settle it.

**Verifier 1's fix.** Define one candidate set and use it for opening, closing and resuming. Option A (recommended): the seat's own credential plus every credential below it; hold opens when none is signed in and unlimited, closes at the earliest reset in that set, and the task resumes on that credential, which is the `wait_limit` subject. Option B: strict chain, only the last-limited credential and those below. Option C: any signed-in credential in the list, dropping "above are not tried". Then reword L215 and L541 to match L521.

**Verifier 2: confirmed.** Case: order [C1,C2,C3], seat's own is C2. C2 limits until 14:00 and work moves to C3 (L516). C3 limits at 12:00 until 18:00. L521 holds "until the earliest reset", which is C2 at 14:00, but L516 forbids trying credentials above and L517 returns to C2 only "for its next task". I must guess the `hold.closed` time, the resuming credential, the `wait_limit` subject (L215), and whether unlimited C1 counts (L215). L541 is only the all-limited special case, not a third trigger.

**Verifier 2's fix.** A (recommended): candidates are the seat's own credential and every credential below it. The hold opens when none is signed in and unlimited, and closes at the earliest `limited until` in that set. Work resumes on that credential with `credential.switched`, and it is the `wait_limit` subject. The reviewer's fix is incomplete: it also needs L516 reworded to "above the seat's own" and L517 to allow a mid-task return. B: current credential and below only; simpler, but tasks wait while the own credential is usable. C: whole list; contradicts L516.

### 31. 'Provider limit' and 'the reset time the provider gave' are undefined where a provider gives none

- **Lines:** 475, 488, 491-492, 503, 515, 521, 610
- **Rated:** major by both verifiers
- **Fix:** the owner has to decide
- **Found by:** credentials

A credential is 'marked limited until the reset time the provider gave'. Several sources give no reset time: Gemini API reports 'Nothing beyond valid', OpenRouter a spending limit that does not reset, Grok 'whether it is blocked', and two logins are read from captured screens. The PRD also never says what counts as hitting a limit: a per-minute rate-limit reply, a 5-hour session, a weekly cap or exhausted spend. With no reset time the hold has no end, and Needs you has no item for it. Nothing reconciles `limited until` with a later reading, for example after the owner spends a reset outside the app.

**Effect.** A task is held forever and silently, or a seat flaps credentials on every short rate-limit reply. The hold-close timer cannot be specified for track A.

**Verifier 1: confirmed.** All five quotes are exact (L475, L491, L503, L515, L521). Nothing defines a "provider limit": Terms L51 and L513 only say "hits a limit". L515 and L521 assume a reset time, yet L483-484 and L488-492 show sources with none. Open decisions L761 covers display only; Risks L727 covers wrong numbers. Needs you (L610) has no credential item, and Blocked (L55) excludes this hold. Timers (L86) omit it. The 10-minute read (L498) never clears `limited until` (L574). Only "flaps" is overstated: L516-517 hand off downward only.

**Verifier 1's fix.** Add an Open decisions row. (1) What counts as a limit: A, any rate-limit reply; B, only windows of minutes or more or exhausted spend, with short rate limits retried in place. Recommend B. (2) No reset time given: A, re-probe on the 10-minute usage read; B, open a Needs you item; C, both. Recommend C. (3) Clear `limited until` when a later reading shows capacity. Then list the limit-reset timer under Timers and leases and add the item to Needs you.

**Verifier 2: confirmed.** Case 1: a seat on a Gemini API token (L491 reports nothing), last in the handoff list, gets a quota refusal. L515 needs a reset time for `limited until` (L574), and L521/L541 need it as the hold-close due time. None exists and L610 has no item, so the hold never closes. Case 2: Claude API 429 with a 20-second retry (L489): limit or not? I would guess the `credential.limit_reached` payload, a nullable `limited until`, what closes `wait_limit` (L215) and the golden trace. L475 forbids estimating.

**Verifier 2's fix.** Three decisions. (1) What is a limit: recommend only a refusal on a window the readings carry as kind `limit` (5-hour, weekly, per-model, spend); per-minute rate limits are retried in place. (2) No reset time: recommend empty `limited until`, normal handoff, and if nobody is below, the hold plus a new Needs you item; the alternative is a fixed re-probe. (3) Reconciliation: the reviewer's 10-minute reading cannot clear Gemini or Grok tokens (no figures), and readings are not events (L502), so clearing needs a server event through the transition function.

### 32. Model, effort and strength rank after a cross-provider handoff are undefined; content goes to a provider the roster does not show and escalation is bypassed

- **Lines:** 36, 96, 448-449, 507, 520, 555, 574, 633, 760
- **Rated:** major by both verifiers
- **Fix:** the owner has to decide
- **Found by:** credentials, product and scope

A seat is 'a provider, a model, an effort setting and a role' with a strength rank. Handoff to another provider 'changes the model doing the work', but neither `credentials` nor the handoff list carries a model, effort or rank, so nothing determines which model continues. Escalation depends on rank ('only a seat at or above that rank can claim it'), yet a handoff ignores the task's minimum rank and can move an escalated task to a weaker model unchecked. The privacy requirement relies on 'the roster shows each seat's provider', which is false once the seat's content goes to the handoff provider (or through OpenRouter to any) part-way through with no owner action; the list is workspace-wide, not per project or per seat. Login-to-token handoff also swaps the provider tool for raw API calls.

**Effect.** Track G must invent a model mapping. Escalation to a stronger model is silently undone by a limit, and an owner who kept a project on one provider for confidentiality has its content sent elsewhere without being shown.

**Verifier 1: partly.** All five quotes are exact. Stands: L574 and L507-517 carry no model, effort or rank; L96/L423 check rank only at claim, never at handoff; L633's roster claim breaks once L516 moves work mid-task; L448-449 leave the login-to-token swap unspecified. Overstated: "without being shown" (L519 records every switch as `credential.switched`, visible in the L612 feed) and "no owner action" (the owner owns the list, L51, though L511 sets a default order). L760 already lists cross-provider handoff as open, but none of these consequences.

**Verifier 1's fix.** Decide L760 before the contract (L732 requires it). (a) Recommended: keep handoff inside the seat's provider in v1; model, effort and rank carry over unchanged, so L96 and L633 stay true. Drop the first sentence of L520, exclude OpenRouter as a target, and say how a login-to-token handoff runs the work. (b) Keep cross-provider: add model, effort and rank per handoff row, refuse a handoff below the task's minimum rank, make it opt-in per project, and show the working provider on roster and task page.

**Verifier 2: confirmed.** Case: seat B1 (Claude, rank 3, credential C1) claims task T whose minimum rank is 3 after escalation (L96, L423). C1 hits its limit; L516 switches to C2, a Gemini login. seats.model (L555) is a Claude id; credentials (L574) holds no model, effort or rank. I must guess the credential.switched payload, whether credentials need a model column, whether rank is rechecked, and which provider review.assign uses for a reviewer (L520). Roster (L613, L633) still shows Claude. Overstated: the switch is logged (L519) and the owner ordered the list (L507).

**Verifier 2's fix.** Owner decision; L760 currently recommends the opposite. (a) Recommended: v1 handoff only within one provider family, so seat model, effort and rank carry over; define families (Claude login with Claude API, Codex with OpenAI API, Gemini, Grok; OpenRouter alone); reword L51, L516, L520, L540, L760. It does not settle login-to-token swapping the tool for API calls; state who runs that loop. (b) Cross-provider per project opt-in, model/effort/rank per credential, hold with credential\_limit when below minimum rank, working provider on roster, review.assign rechecked on handoff.

### 33. Claim eligibility ignores credential state; behaviour before the reset and on sign-out or removal in use is missing

- **Lines:** 423, 454, 473, 516-517, 521
- **Rated:** major by both verifiers
- **Fix:** the owner has to decide
- **Found by:** credentials

Eligibility lists seat, role, rank, project and task conditions, with nothing about the seat's credential. Step 3 covers only the next task 'once that limit has reset'; a seat that finishes before the reset either claims on the handoff credential (whole tasks billed to a per-use token) or on a limited one (claim, immediate hold, repeat). A credential can become signed out while a seat is working: that is not a limit, so no handoff and no hold reason applies, and the task stalls to lease expiry and is reclaimed. The removal guard covers the credential 'a seat uses', not one currently doing handed-off work.

**Effect.** Seats with a dead or limited credential keep taking the highest-priority task and holding it. Removing a credential mid-handoff leaves a running task with no credential.

**Verifier 1: partly.** All four quotes are exact. Stands: L423 eligibility has no credential condition; L513-521 trigger handoff only on a provider limit, so a sign-out mid-run (L473, L177) has no defined behaviour; L454/L542 "a seat uses" reads as the assigned credential (L453, L555), not one doing handed-off work. Nothing in Risks or Open decisions (L760) settles these. Overstated: L517 implies the handoff credential continues until reset, and per-use billing follows the owner's order (L511); L90 limits a seat to one task; L521 defines the hold; lease expiry (L89) is a backstop.

**Verifier 1's fix.** Option A (recommended): an app-run seat is eligible only if its own credential, or one below it in the handoff order, is signed in and not limited; a new task starts on the first such credential, recorded on the claim. A sign-out mid-run hands off like a limit; with none available, hold the task and open a Needs you item. Refuse removal while an open task, review or job records the credential. Say whether `credential_limit` pauses the lease clock (L89 is silent). Option B: keep eligibility and rely on hold plus lease expiry; this leaves the reclaim loop.

**Verifier 2: confirmed.** L423 has no credential condition, and L513-521 fire only "when a run hits a provider limit". I would have to guess four things. (1) S finishes on handoff C2 and claims at 13:05; C1 resets at 15:00. L517 leaves the credential recorded on the claim (L519) undefined. (2) All candidates limited: L423 still lets S claim the top task. (3) `credential.signed_out` (L177) mid-run has no handoff trigger and no hold reason (L113). (4) Removing C2 mid-handoff passes L454, since L555 holds one credential per seat. "Repeat" is overstated: L90 blocks a second claim.

**Verifier 2's fix.** Recommend: (a) L423: an app-run seat is eligible only if its own credential or one below it (L516) is signed in and not limited; same for review and job claims. (b) Before the reset, claim on the first such credential, recorded on the claim. Alternative: not eligible until its own resets. (c) Signed-out in use: hand off as L516. If none, not `credential_limit` (no reset time, distorts `wait_limit`) but an owner hold with a Needs you item, closed on sign-in. (d) Refuse removal while an open task, review or job records the credential.

### 34. Limits during a review or an orchestrator job have no specified behaviour

- **Lines:** 88, 304-306, 519, 521, 562
- **Rated:** major by both verifiers
- **Fix:** the owner has to decide
- **Found by:** credentials

Handoff is written for a task: 'the task is held'. But credentials also do reviews and jobs ('Every claim, job and handoff records which credential'). A hold attaches to a 'Task or project', not a review or a job. A reviewer at its limit: is the task In review held, or the review lease left to expire? An orchestrator at its limit keeps polling, so it is not 'offline'; its checks miss their run timeout twice, become `error`, and each task gets a `check_error` hold and its own Needs you item whose first choice, run it again, fails the same way.

**Effect.** One weekly limit on the orchestrator's account floods Needs you with per-task check errors and blocks every gated transition, with the cause shown nowhere.

**Verifier 1: partly.** Quotes at L519, L562, L306 and L305 are exact. What stands: L513-521 covers only tasks, says nothing for a limited job seat, and L89 does not say whether `credential_limit` pauses a lease. Overstated: a task In review is still a task, holds apply in any state (L79) and block the verdict (L116), so L521 covers it. Jobs have a defined fail-closed path (L304-305, L740). Handoff comes first (L516), so the flood needs every lower credential exhausted. The cause shows on the credential row (L473, L515) and as `credential.limit_reached` (L177).

**Verifier 1's fix.** Decide per work kind. A (recommended): a limited reviewer releases the review with reason `credential_limit` and the task stays In review, unassigned. A job seat with no available credential stops claiming and counts as offline under L306, the workspace item names the limit and reset time, and its jobs requeue without a timeout miss. Also state whether `credential_limit` pauses the builder lease (recommend yes, matching L541). B: keep the fail-closed path, say so, and name the limit on the `check_error` item. C: scope version 1 handoff to builder tasks only.

**Verifier 2: confirmed.** Case A: a check job for task T's submit; the orchestrator's only credential hits its limit. L521 holds "the task" (T, whose builder is fine?), while L304-305 still time the job out twice, giving `error` and `check_error`. L306 defines offline by polling only, and whether a limited seat polls is unstated; the reviewer's flood assumes it does. No job event covers it (L172). Case B: a limited reviewer. T is held (L521), but L89 pauses leases only for owner/project holds, so the review lease expires and L116 blocks other reviewers until reset.

**Verifier 2's fix.** Decide per work kind. Recommend: (1) Review: the app releases it (`review.released`, caused by `credential.limit_reached`) with no task hold, since L116 would block other reviewers. Also decide whether a mid-review handoff to the builder's provider is refused (L520, L265). (2) Jobs: no task hold; a role whose seats are all limited counts as offline in L306, and the workspace item names the limit and reset. Drop the reviewer's "pause job timeouts": L305 and L307 already suppress per-task items and requeue errored checks. (3) State whether `credential_limit` pauses the builder's lease (L89).

### 35. The definition of done skips Credentials (Goal 8), the MCP server (Goal 7) and most of milestone 4; two criteria fail by construction and several Credentials criteria cannot be shown

- **Lines:** 19-20, 98, 278, 306, 343, 345-346, 432, 481, 531-543, 629, 631, 685, 691-710
- **Rated:** major by both verifiers
- **Fix:** the owner has to decide
- **Found by:** credentials, build plan, product and scope

'Version 1 is done when every line below is shown to hold', and the release list has no line for Credentials (goal 8 and milestone 5, whose own list is not referenced), for the MCP server (goal 7, feasibility 'not yet tested'), or for questions, escalation, budget pauses, the round limit, access requests or contract edits. Criterion 694 requires each command to write 'exactly the events the lifecycle table names', but with any rule enabled a gated command also writes check, job, hold and inbox events the table does not name. Criterion 698 requires the offline item within 90 seconds of stopping the runner, while offline is reached only after 90 seconds without a poll and timers are swept every 30. Within the Credentials list: line 540 needs a real limit hit, with no fault injection or fake provider specified (recorded replies cover readers only); line 541 needs a reset to pass (hours or days) with no clock control; line 537 'needs an account that has one' while the entry 'has only been seen empty'; line 535 needs two paid accounts at each of three providers. No line covers cross-provider handoff with the review rule, sign-out in use, or return to the own credential.

**Effect.** The owner cannot tell whether version 1 is done: it can be declared done with Goals 7 and 8 and milestone 4 features missing, or can never be declared done because two lines cannot be shown as written and a criterion needs an account state nobody has; the handoff criteria can only be demonstrated by exhausting real subscriptions.

**Verifier 1: partly.** Stands: L691-710 never reference L531-543, though L20 and L617 put Credentials in v1; L537 cannot be shown (L481), and L763 leaves it open. L694 "exactly" contradicts L278 once any gate rule is on. L698/L631/L718 equal the L306 threshold and ignore the L629 sweep (worst case only, not always). No line requires an MCP run (L432, L693). Refuted: questions, escalation, budget and contract edits are covered by tests 3-4 (L644-645); L704-705 cover outward actions; track G (L685) already binds the Credentials list; "two paid accounts" is cost, not a defect.

**Verifier 1's fix.** Decide two things. (1) Does the Credentials list gate v1? Recommend yes: L691 cites it, with L537 marked conditional, or take L763's dash alternative and delete L537. (2) Must the MCP server complete a task? Recommend one MCP run as a release line. Then mechanical follow-ups: reword L694 to allow the check, job, hold and inbox events L278 implies, or cite the golden traces; set L698, L631 and L718 to 120 seconds (90 plus one 30-second sweep); say L540-541 run against stubbed provider replies. Skip extra milestone-4 lines; tests 3-4 cover them.

**Verifier 2: partly.** Confirmed: L691-710 never reference L531-543 or the MCP server (L19-20, L432), so I must guess whether a golden trace covers `credential.switched` and `wait_limit`. L694 vs L276-278: Complete contract under shipped rules (L341-342) also writes check and job events. L698/L631/L718 vs L306+L629: last poll t=0, offline t=90, sweep t=119; I must guess threshold or bound. Overstated: tests 3-4 (L644-645) already cover questions, escalation, budget, round limit and contract edits; 698 is unguaranteeable, not always failing.

**Verifier 2's fix.** Decide: (1) Credentials gates v1 through one release line referencing L533-543, L537 conditional (recommended), or moves out of v1. (2) MCP: one MCP-driven task run (recommended), or drop it from Goal 7. (3) Offline: keep the 90 s threshold and say 120 s in L631, L698 and L718 (recommended; reviewer missed L718), or cut L306 to 60 s. (4) L694: lifecycle events plus the check, job, hold and inbox events gating writes; golden traces cannot describe a live run. Reject the injectable clock (contradicts L628); use a recorded limit reply with a near reset time.

### 36. The planner role, contract-draft job and `draft` step have no trigger, milestone, track, test or goal, and a planner result becomes the contract with no owner sign-off

- **Lines:** 26, 47, 65, 82, 104, 202-203, 334, 362, 406-407, 417, 430, 436, 555, 632, 663, 669-672, 693
- **Rated:** major by both verifiers
- **Fix:** the owner has to decide
- **Found by:** steps and timing, security and privacy, build plan, interfaces, product and scope

A planner role, a contract-draft job kind, a `draft` step ('a planner job is writing the contract') and 'Owner or planner seat' on Complete contract are all in the contract surface. Nothing queues a draft job: no owner command, no automatic rule on Add task or Promote, and the Add task form runs Complete contract itself. No milestone, track, test, acceptance criterion or goal mentions the planner; the non-goals say tasks are added through a form. It is undefined whether `draft` opens at `job.queued` or `job.claimed` and what step follows `job.timed_out`. The draft's result 'is the Complete contract command', so a model-written contract (budget and outward actions included) becomes 'the only authority' for every checker and for the orchestrator approving outward actions (which it does by default) and enters Ready with no owner look, contradicting treating model results as data; a planner steered by brief or task text can add an outward action that is later approved because the contract names it. Behaviour is also undefined when `task.before_ready` answers `202 pending` or fails: the reason routes to the owner, the planner has no retry path, the job's final state and the `draft`-to-`check` hand-over are unstated.

**Effect.** The contract must define a job kind, a `draft` step and a role whose entry point does not exist; tracks B, C and D each spend effort on something nobody can start or test, or each guesses a different trigger; step-table authors must guess when `draft` opens. If someone does build it, seat-written text gains owner-level authority and an irreversible action can be contracted and approved with no human in the path.

**Verifier 1: partly.** All quotes are exact. Core stands: "planner" and "draft" appear only at L47, 65, 202-203, 406-407, 417, 430, 555; no command or rule writes `job.queued` for a draft, no milestone, track, test or criterion (L657-709) covers it, and Open decisions and Risks are silent. L407 lets a model send a task to Ready with no owner step. Overstated: L26 excludes orchestrator chat, not a planner; L190, L260, L276 and L425 settle the `draft`-to-`check` hand-over and gate failure; L341-342, L354 and L357 still gate a planner contract.

**Verifier 1's fix.** Add to Open decisions. (a) Recommended: drop the planner role, the contract-draft job kind and the `draft` step from version 1 (L47, 65, 202-203, 406-407, 411, 417, 430, 555), so only the owner completes contracts, matching L669 and L608. (b) Keep them: add an owner command "Request draft" in Backlog that writes `job.queued`, open `draft` at `job.claimed`, have the result store a draft only (`task.contract_changed`, task stays in Backlog) with the owner running Complete contract, and add a milestone, track owner, test and release criterion.

**Verifier 2: confirmed.** Verified. Case: Add task to Imaginarium, Promote (L63-64); task sits in `wait_contract` (L203). No row in L61-80 or L436 writes `job.queued` for a draft, so `draft` (L202) is unreachable. I must guess its opening event (queued or claimed), its timeout (L304 covers checks only) and the step after `job.timed_out`. L65+L407 put the result in Ready; on 202 or failure L288 assumes a holder who resends, and the planner is not one. L669-672, tracks and tests omit it. The security point holds, softened by L260 gates.

**Verifier 2's fix.** (a) Recommended: drop the planner role, `draft` step and draft job kind from version 1. Touches L47, 65, 202-203, 406-407, 411, 417, 430, 555; matches L25-26 and L669. (b) Keep: add owner command "Request draft" (Backlog) writing `job.queued`; `draft` runs from `job.claimed` to finish, timeout or withdrawal; the result only saves the contract and the owner alone completes it. Reviewer's (b) is incomplete: it also needs a Backlog contract-save row (L66 has none), job timeouts, a milestone, track owner and golden trace. (c) Capped planner completion adds a setting; not for v1.

### 37. Authority text in the briefing has no defined author or write path: project brief, role file and 'the record'

- **Lines:** 25, 174, 343, 368-369, 380, 436, 554, 753
- **Rated:** major by both verifiers
- **Fix:** the owner has to decide
- **Found by:** security and privacy

The project brief and the role file rank above the contract and reach every builder, reviewer and checker as authority. The owner command list has no command to create a project or change a brief, although `project.created` and `brief.changed` events exist, and `brief_entries` has an author column and 'decisions and lessons' kinds, which implies authors other than the owner. Role files have no table, no version (the briefing hash needs one) and no editor, and the roles library is a non-goal. 'The record' the orchestrator answers from is undefined. If seats can write any of these, builder text becomes standing authority for later tasks.

**Effect.** The briefing hash and the brief and role-file migrations cannot be written. If orchestrator decisions or lessons flow into the brief, one injected question becomes a rule for every later task in the project.

**Verifier 1: partly.** All five quotes are exact (L343, L369, L380, L436, L554). Stands: L436 has no create-project or edit-brief command though L174 has `project.created` and `brief.changed`; role files have no table, version or editor (L25, L555, L619) yet L374 requires them from the core loop and L369 hashes versions; `brief_entries` has no version (L554); "the record" is only scoped to one project (L753), never defined. Refuted: seats cannot write the brief (Roles table L413-418, L632, L708), and checkers take only contract and rule instruction as authority (L334).

**Verifier 1's fix.** Options: (A) owner-only authorship: add create project, edit brief and edit role file to owner commands; add a versioned role-file table and a version on brief entries; define "the record" as owner-written brief entries plus owner answers in the same project. (B) also let the server store orchestrator decisions and lessons as brief entries, which needs an owner-acceptance step and a quoting rule. (C) drop role files from the version 1 briefing and hash. Recommend A; it matches the Roles table, which already denies seats any brief write.

**Verifier 2: partly.** The gap is real; the injection impact is overstated. L174 registers `project.created` and `brief.changed`, but L436 and L669 list no command that writes them. L368-369 and L374 need brief and role-file versions for the hash from the core-loop milestone, yet L554 has no version and L549-575 has no role-file table; L25 and L619 exclude an editor. So I would guess the migrations, hash and `brief.changed` payload. L413-418, L355 and L632 already bar seats from writing briefs; only server-derived entries and "the record" (L343, L753) stay open.

**Verifier 2's fix.** Three decisions. (1) Brief: add owner commands to create a project and add, edit or remove a brief entry; the author is the owner only (matches L413-418); add a brief version per project. (2) Role file: the reviewer's "edit role file" contradicts L25 and L619. Recommend four shipped, read-only role files versioned with the release; the alternative is an owner-editable versioned table. (3) The record: recommend brief entries plus owner answers in the same project; the alternative adds orchestrator decisions not overturned. Drop "owner accepts": it invents a command, and `question.overturned` already exists.

### 38. The Roles table grants reads that no listed call serves: reviewers cannot get evidence or the handoff note, builders cannot get review notes or action details

- **Lines:** 368, 388-407, 413-418, 556, 559, 708
- **Rated:** major by both verifiers
- **Fix:** the owner has to decide
- **Found by:** security and privacy, interfaces

`GET /v1/next` returns only a kind and an id; the only read calls are the briefing and one question. A review claim returns only a lease and a briefing (rules, brief, role file, contract). No listed call returns criterion states, evidence links, the handoff note, the work reference or questions to a reviewer, the review's failed criteria and notes to a builder told `rework`, or which action was approved (action state) to a builder told `action`. The orchestrator may read 'that task's project' but has no read call at all, so it is unknown whether the server pushes project content into the job or the seat pulls it, and how much of the project that covers. A task may have no project, where 'that task's project' is undefined.

**Effect.** The milestone-2 run (builder, reviewer, one failed review) cannot be completed through the listed calls: the reference reviewer cannot see what it must review. Tracks B, C and D will each invent read endpoints with no stated scope, and release criterion 708 on role limits has nothing fixed to test against.

**Verifier 1: partly.** All quotes are exact. Stands: the briefing (L49, L368) excludes evidence, handoff note, work reference and review notes; reviews/claim-next (L403) returns only lease and briefing; `rework` arrives as kind and id (L94, L388). L285 says the holder may "read", but no such call is listed. Refuted: orchestrator input is pushed (L334-335; job input shapes L663; scope in Open decisions L753). The contract is written by one person first (L653, L665), so tracks will not each invent reads. L708 has the Roles table to test against. Actions are named in the contract (L104).

**Verifier 1's fix.** Options: (a) add pull reads, `GET /v1/tasks/{id}` for the holder and `GET /v1/reviews/{id}` for the reviewer, each returning exactly what the Roles table allows; (b) push the same fields in the claim-next and `GET /v1/next` responses, with no new calls; (c) widen the briefing, which would churn its hash. Recommend (a): L285 already assumes a holder read, and rework arrives as a bare id. Also state that orchestrator and planner inputs are push-only job inputs, and that a task with no project has an empty brief and scopes to itself.

**Verifier 2: confirmed.** Trace: builder claims (L390), passes C1 with evidence, submits with note (L400). Reviewer's claim returns only lease and briefing (L403), and the briefing is rules, brief, role file, contract (L368): no evidence, handoff note or work reference, though L416 grants evidence. After a fail, the builder gets `rework` plus an id (L94, L388); notes sit in `reviews` (L559) with no route and L415 omits them. `action` does not say which `aid` (L401). I must guess endpoints, shapes, and orchestrator scope (L418, L753); L663 implies pushed job inputs only.

**Verifier 2's fix.** Option A (recommended): two holder-scoped reads, `GET /v1/tasks/{id}` and `GET /v1/reviews/{id}`, accepted before acknowledgement; job inputs pushed in the jobs claim response, per kind (L663), rule-check inputs being the hashed inputs (L315-322). The reviewer's fix needs amending: it must also widen Roles L415-416 to name handoff note, work reference, review notes and action state, or it contradicts L708; define 'the record' for question jobs (L343); builder text stays quoted (L334). Option B: fold everything into the briefing, which breaks its hash (L369). No-project: task only.

### 39. The shipped rule set cannot complete a task with the recommended single provider; the minimum first-run setup is never stated and the promised unsatisfiable-rule detector is unspecified

- **Lines:** 19, 90, 209, 342, 344, 606, 610, 669, 693, 701, 719, 732, 738-739
- **Rated:** major by both verifiers
- **Fix:** the owner has to decide
- **Found by:** build plan, product and scope

The first provider is Claude alone and the runner is promised for one provider (milestone 2 runs both seats on one active login), but 'A different provider reviews every task' ships as a rule and refuses a reviewer from the builder's provider; the open decision that names the conflict leaves 'second provider or rule off' unanswered. From milestone 3 the end-to-end release run (builder and reviewer driven by the reference runner) stops in `wait_review` unless a second provider adapter is built, which no track owns. The shipped 'specific details' rule is model-checked, so an orchestrator runner must also be on before any task can enter Ready. With one role per seat and one item per seat, the true minimum is three seats and three running processes, plus a second provider or a rule switched off; no section says so. Shipped rules have no stated default on or off, and how the owner account is first created is not specified. The Risks table answers with a detector for unsatisfiable rules that has no trigger, event, Needs you kind, milestone or test.

**Effect.** The first release criterion fails on a default install, or passes only because someone turned a shipped rule off by hand; a new owner following the recommended setup adds a task and it never reaches Done, with no screen explaining why. Track D's scope (one adapter or two) is unknown and the rule seed data in the contract cannot be written until the default is chosen.

**Verifier 1: partly.** All seven quotes are exact. Stands: L739 names the conflict but picks neither branch, though L732 says the recommendation is assumed; the L719 detector appears nowhere else (not in L113, L176, L610, L640-649, L669-672, L693-710). Overstated: the PRD already lists this as a pre-contract decision (L732); track G runs four providers' tools before release (L448, L528, L672, L685); the always-on orchestrator is acknowledged (L738, L718) and a missing one is surfaced (L306, L610, L616); L209/L609 show the provider rule as cause; three seats is derivable (L669-670).

**Verifier 1's fix.** Answer L739's either/or. (a) Ship the provider rule off, offer it when a second provider connects; L701 still tests with two same-provider seats. (b) Ship it on and require two providers, which only works from milestone 5, so milestones 3-4 need it off anyway. Recommend (a). Add a default column to Shipped rules (only L747 states one). Either specify the L719 detector (trigger, Needs you kind in L610, test, owning track) or cut it and rely on L209. Add one line on minimum seats and first owner sign-in.

**Verifier 2: partly.** Real: L739 leaves 'second provider or rule off' unanswered though L732 requires an answer before the contract; L344/L701 assume on. I must guess the seeded `enabled` value, and for L719's detector the trigger, inbox kind (absent from L610), and closing condition; L328 overrides cover gates only. Trace: Claude builder submits, Claude reviewer claims, `review.assign` refuses, `wait_review` forever. Overstated: track G runs four providers' tools (L448, L685); orchestrator-offline is surfaced (L306); three seats derive from L90, L411. Owner creation (L606, L552) is separate.

**Verifier 2's fix.** Decide L739. (a) Seed the provider rule off; L701 still testable with two Claude seats and the rule switched on. (b) Require a second provider. Recommend (a). Do not delete L719: L520 plus cross-provider handoff (L760) can make the rule unsatisfiable even with two providers, so specify the detector either way: evaluated when `review.assign` refuses and no enabled reviewer seat qualifies, one workspace-level Needs you kind, closing condition, a test. State each shipped rule's default. Skip the 'prompt to turn on' (new requirement). Owner creation is a separate minor gap.

### 40. `GET /v1/next` kinds do not cover what the lifecycle makes seats wait for, and its delivery semantics are undefined

- **Lines:** 116, 288-289, 296, 388, 398, 425
- **Rated:** major by both verifiers
- **Fix:** the owner has to decide
- **Found by:** interfaces

The PRD says a seat learns a pending command's outcome from `GET /v1/next`, but none of the eight kinds is a command outcome; L296 names only `GET /v1/commands/{key}`. No kind tells a held seat that its hold closed (access granted, budget raised, project resumed), that an override completed its refused transition, or that an answer it used was overturned. It is unstated whether an item is consumed on delivery or repeated until acted on, what `task` means (work available, or your provisional claim completed), and what its id is for when claim-next picks independently.

**Effect.** The contract's `GET /v1/next` response cannot be written. Clients must busy-retry work calls to detect a lifted hold; a lost response may lose an answer; a builder whose submit was completed by override keeps working on a task it no longer holds.

**Verifier 1: partly.** Quotes at L296, L388, L425, L289 are exact. Core stands: L425 promises outcomes via next, but L388 has no outcome kind and L296 names only commands/{key}; no kind signals a lifted access/budget/project hold (L113-116) or question.overturned (L168); consumption and the meaning of task/review/job ids are unstated. Impacts are overstated: L389 always returns outcomes, L397 re-reads answers so none is lost, L426 not\_holder/on\_hold bound stale work, and L179/L384/L211 lean toward a non-consuming read. L665 defers the response to the contract, but no open decision covers it.

**Verifier 1's fix.** Option A (minimal): state next is a non-consuming read repeated until the seat acts; delete "or from GET /v1/next" at L425 so it matches L296/L389; say held seats retry on `on_hold`; ids are advisory. Option B: also add kinds `command` (carrying the key) and `resume` (hold closed), re-deliver `answer` on overturn, and define task/review/job as "claim-next will return something". Recommend B, added as a row in Open decisions, since L89 pauses the lease during owner holds and seats otherwise busy-retry for hours.

**Verifier 2: confirmed.** L665 makes the `GET /v1/next` response a contract deliverable, yet L388 gives eight kinds and no semantics. Case: a builder calls access (L398), the hold opens with the lease paused (L89, L750), the owner grants it; no kind fits, so the seat retries until `on_hold` (L116) stops. A reviewer's 202 verdict (L405, L425) has no outcome kind; L296 names only commands/{key}. `question.overturned` (L168) has none. Repeat-or-consume and the `task` id against L390/L422 are guesses. Overstated: answers are re-readable (L397).

**Verifier 2's fix.** Option A (recommended): next is a non-consuming read. Each kind gets a state predicate, a clearing call and a fixed priority. Add `command` (id is the key; clears when commands/{key} is read) and `resume` (clears on the holder's next accepted call). `task`/`review`/`job` mean claim-next has work, with no id. An overturn re-raises `answer`. The reviewer's "never consumed" needs these clearing rules, or `command`, `answer` and `resume` repeat forever. Option B: keep eight kinds, delete "or from `GET /v1/next`" at L425, add `wait` to commands/{key}; holds are detected by retry.

### 41. Blocking questions and non-check jobs have no specified waiting state, timeout or offline behaviour

- **Lines:** 113, 168, 217, 249, 306, 343, 396-397, 611
- **Rated:** major by both verifiers
- **Fix:** the owner has to decide
- **Found by:** interfaces

A question may block the work and is routed to the orchestrator first. While the orchestrator job is queued or running there is no hold reason (`owner_question` is the owner's), no step kind, and the lease clock keeps running. Queue and run timeouts are defined only for model checks on the rule record; question, approval and draft jobs have none. The offline item counts only checks, so questions and approvals wait silently. When the owner overturns an orchestrator answer, nothing tells the seat that acted on it.

**Effect.** A builder blocked on a question loses its lease while waiting, or waits forever with the orchestrator down. Step-partition timing misattributes the wait to build. An approval job that never finishes leaves a Finishing task with no Needs you item.

**Verifier 1: partly.** All five quotes are exact. Stands: nothing defines what a blocking question (L396, L560) does while the orchestrator answers. L113 has only `owner_question`, L199-215 has no matching step, so the wait is timed as `build` despite L217. Question and draft jobs have no timeout or owner fallback (L249, L304, L551, L742 cover checks only). Overturn (L168, L611) has no seat effect. Refuted: approvals are a model check (L347), so L304-307 and L610 apply. Lease loss is overstated (heartbeat renews, L371, L424; L89 intends it). The offline item and health line appear regardless (L306, L616).

**Verifier 1's fix.** Options: (A) a blocking question opens a waiting step and a new hold reason from ask to answer; (B) no hold, the builder stays in `build` and the PRD says so. Recommend A, with the lease still running under heartbeat, as L89 intends. Give question and draft jobs the workspace queue and run timeouts; a second miss passes the question to the owner as `owner_question`. Count all job kinds in the offline item. On `question.overturned`, deliver a new `answer` item, non-retroactive. State that L305 covers the approval policy check.

**Verifier 2: confirmed.** Case: a builder posts a question with blocking=true (L396) and L343 routes it to an orchestrator job. L217 implies a blocking question opens a step, but L199-215 has no such kind and L113 has only `owner_question`, so hold, step and lease are guesses. Timeouts cover checks only (L249, L304, L742); a claimed question job never times out despite `job.timed_out` (L172). The approval wait in Finishing has no step either (L208, L211). Overturn (L168, L611) has no seat delivery. Overstated: heartbeat keeps the lease (L116), and the offline item opens regardless (L306).

**Verifier 2's fix.** The reviewer's hold with a paused lease contradicts L117 and L286, where waiting on the orchestrator is not a hold and the lease keeps running. Option A (recommended): follow that precedent. A blocking question and an approval wait open a new waiting step, no hold; question and approval jobs use the workspace check timeouts; a second miss passes to the owner, opening `owner_question` or `owner_approval`. Option B: the reviewer's new hold reason, which also needs Blocked-lane and `wait_owner` changes. Either way: the offline item counts all jobs, and overturn delivers a new `answer` item, non-retroactive.

### 42. Three waiting states have no Needs you item and no owner command that ends them

- **Lines:** 67, 78, 96, 106, 209, 354, 388, 423, 436, 610, 613
- **Rated:** major by both verifiers
- **Fix:** the owner has to decide
- **Found by:** product and scope

(1) A task In review with no eligible reviewer waits silently: the owner cannot give a verdict and Needs you has no such kind. (2) Escalation sets a minimum strength rank. If no seat meets it the task sits in Ready forever. The roster does not show rank, nothing says how a seat gets one, and no command lowers it on a task. (3) A lapsed builder lease in Finishing leaves the task without a holder. Claim exists only from Ready, so no seat can take it. If the action already went out unreported, a fresh lease to the same builder repeats an irreversible action.

**Effect.** In week one the owner sees tasks that do not move and no item saying why. The only exits are cancel or a guess at which rule or seat is the cause.

**Verifier 1: partly.** Quotes at L78, L96, L354 and L613 are exact. Part 1 is mostly answered: L719 promises a detector and Needs you item for a rule no connected seat can satisfy, L739 covers the one-provider case, and the owner can switch that rule off (L436). Remaining gaps: L610 omits that kind, and L354 is built in, not a rule. Part 2 stands: rank appears only at L555-556, with no owner command to set or clear it (L436). Part 3 stands (L78, L106), though waive (L107, L436) is an exit; the repeat-action risk is speculative.

**Verifier 1's fix.** Options: (a) widen L719's detector to any task in Ready, In review or Finishing that no enabled seat can take, and list that kind at L610; (b) add a separate hold reason per case. Recommend (a), plus: show strength rank on the roster, with owner commands to set a seat's rank and clear a task's minimum; on a lapsed Finishing lease, open a Needs you item asking the owner whether the action went out, with choices to re-lease the builder, waive, or cancel.

**Verifier 2: partly.** Case 2: review fails twice, L96 sets a minimum rank. I cannot write `task.reassigned`'s payload (value unspecified, yet replayed at L591), nor any command that sets a seat's rank (L555; absent from L436, L613) or clears the minimum. Case 3: lease lapses in Finishing (L78). No row re-leases it (L67 is Ready only, L106 fires once), no step kind fits (L208-211), no item; only waive or cancel. Case 1 is overstated: L719 promises a detector and the rule can be switched off, but L610/L631 omit the item.

**Verifier 2's fix.** Extend L719's detector instead of adding a second: one Needs you kind in L610 for "no enabled seat can take this", judged on the roster ignoring busy seats. Rank: (a) owner sets rank at connect, roster shows it, an owner command clears a task's minimum (recommended); (b) drop rank and escalate by excluding the previous builder. Lapsed Finishing: (a) hold and ask the owner: done, retry by the same builder, waive or cancel (recommended); (b) auto re-lease, risking a repeat. Never a different builder: L106.

### 43. A builder is sent to four artefacts that are not in the export, and some definitions exist only there

- **Lines:** 37, 57, 317, 440, 483-484, 556, 602, 608, 612, 667, 759
- **Rated:** major by both verifiers
- **Fix:** the owner has to decide
- **Found by:** product and scope

The lifecycle picture is a placeholder. The screens defer to 'the clickable prototype' and 'the approved mock-up' with no link. The Gemini and Grok readers defer to 'the existing Campus credentials doc' and give their figures as 'What that screen shows', though the contract must fix what each reader returns. Things only the prototype can settle: which events count as Important in Activity, and the contract's fields. The form has audience and include-or-avoid fields, the check hashes 'details', the Terms entry lists a budget, and `tasks` has no column for details or audience.

**Effect.** Track E has no reference to test screens against, track G cannot write two of nine readers, and the contract author must guess the task contract's fields.

**Verifier 1: partly.** All four quotes are exact. Stands: task-contract fields disagree across L37 (budget, no details), L317 (hashes "details"), L608 (audience, include/avoid, no budget) and L556 (no details or audience column), with no Open decisions row; "Important" is defined nowhere (L612 only); prototype and Campus doc are unlinked (L440, L602, L483-484). Refuted: the L57 picture is redundant, since L55 and L61-80 specify every state and move; reader output is already assigned to the contract (L667), with shape at L575, L475, and reuse of Campus readers at L759.

**Verifier 1's fix.** Options: (A) make the PRD self-contained; (B) link the prototype and Campus credentials doc and leave the rest to the contract milestone. Recommend A, narrowed: settle one task-contract field list (does "details" mean audience plus include/avoid; is budget hashed; where it is stored) and align L37, L317, L556 and L608; define Important by event type or add an Open decisions row; give a path for the prototype and Campus doc. Replace the L57 placeholder with a pointer to the table. Gemini and Grok readers need only the link.

**Verifier 2: partly.** Real for the contract: L37 (goal, criteria, budget, actions), L317 (goal, criteria, details, actions), L608 (adds audience, include-or-avoid) and L556 (no details column) disagree. I must guess the details column(s), and whether a budget-cap edit in Working is Edit contract (L66) or `task.changed` (L164). L483-484 leave L667 unwritable for two readers; L612 Important is undefined. Not real: L57, since L61-80 fully define states; L602/L440 hit track E, not the contract. Cutting Gemini and Grok contradicts L448, L461, L535.

**Verifier 2's fix.** Decide the contract field list once. Recommend: goal, criteria, details (the form's audience and include-or-avoid text), outward actions; store details on `tasks`; budget cap outside the contract, changed via `task.changed`; align L37, L317, L556, L608. For Gemini and Grok, keep both logins: either paste the Campus figure lists into L483-484 or narrow L667 to the generic reading shape (L575) and take their figures from recorded replies (L685). Define Important as a flag in the event registry. Drop or re-export L57; link the prototype for track E.

### 44. Six Risk responses promise behaviour the body does not specify or contradicts

- **Lines:** 276, 305, 368, 609-610, 615, 716-720, 727, 763
- **Rated:** major by both verifiers
- **Fix:** the owner has to decide
- **Found by:** product and scope

The risk table says the server detects a rule no connected seat can satisfy; no section, hook or Needs you kind does. It says the briefing tells agents the gate covers only what goes through the app; the briefing content list has no such part. It says applicability is judged once per task; the body judges it inside every check job. It says the owner can set a rule to warn; the Rules screen lists no such control. It says every reader checks the tool's version; only Claude's reset read mentions one. It says spend is labelled as reported; no screen does.

**Effect.** The mitigations the owner is relying on will not be built, because builders work from the sections, not the risk table. The model-check bottleneck and the unsatisfiable rule stay unmitigated.

**Verifier 1: partly.** All four quotes are exact (L276, L717-719). Four gaps stand: no unsatisfiable-rule detector or Needs you kind (L610, L631; L739 only names the problem); briefing content lacks the gate-scope line (L368); a version check appears only for Claude resets (L763, not L481-503); no screen labels spend as reported (L614). Two are overstated: L276 already folds applicability into the check job, so only "once per task" is wrong (L326 reuses passed/failed only); warn is fully specified (L247, L308, L565), only the L615 list omits it.

**Verifier 1's fix.** Per response, either specify it in the body or reword the Risks row. Recommend: (1) specify the detector (trigger, Needs you kind, test), or drop it and settle L739 by shipping the provider rule off with one provider; (2) add a fixed gate-scope line to briefing content; (3) reword L717 to "applicability is judged in the check job, with no separate job"; (4) add on-fail to L615 and say whether custom rules (L362) may warn; (5) put the version check under Reading usage, or narrow L727 to Claude resets; (6) label spend "reported" on Projects and task page.

**Verifier 2: confirmed.** All six hold. Case 1: Claude-only workspace (L739), provider rule on. Submit succeeds, every Claim review is refused at `review.assign` (L265), the task sits in `wait_review` forever. L610 lists no such Needs you kind, L113 no hold; I must guess kind, trigger and resolution. Case 2: checker-decides rule at `task.before_claim`; seat A got `not_applicable`, lease expires, seat B claims. L276 and L318 queue a new job; L717 says none. L718's warn has no control at L615. L727's check appears only at L763. L716, L720: copy absent from L368, L615.

**Verifier 2's fix.** Decide per row. Detector: specify it for the provider rule only (no enabled reviewer seat can pass `review.assign` for a submitted task; one new Needs you kind), or delete L719's response and ship the rule off per L739. Recommend specifying. Drop 'once per task': the reviewer's cache contradicts L276, L300 and L313; say fixed scopes are free and identical inputs reuse results. Add `on_fail` to L615 and reconcile L362. Scope the version check to the three undocumented readers, per figure. Briefing line and 'reported' label are copy.

### 45. The work has no path to the reviewer: the work reference has no writer or reader, and evidence must be an https link

- **Lines:** 28, 102, 324, 356, 395, 411, 415-416, 556, 558, 608, 669, 722, 745
- **Rated:** major by both verifiers
- **Fix:** the owner has to decide
- **Found by:** completeness pass

The app 'stores a reference to where the work lives' in `tasks`, but no agent call, owner command, form field or event sets it, and the Roles table lets no seat read it. The reviewer's only pointer is evidence, which must be an `https` link and is mandatory for every builder criterion. With the recommended installation, agents work in local folders on the owner's machine, so a builder can produce such a link only by pushing or uploading unreviewed work, and a reviewer from another provider then needs credentials to open it. Milestone 2's two local runners have nothing to link to.

**Effect.** The independent review, which every later guarantee rests on, cannot reach local work. Builders either cannot pass a criterion or must publish unreviewed work to obtain a link.

**Verifier 1: partly.** Quotes are exact. Stands: `work reference` (L556) has no writer in the form (L608), agent calls (L388-407), owner commands (L436) or events (L164), and no reader in Roles (L415-418) or the briefing (L368). L28 and L745 only say it is stored. Evidence is mandatory (L356) and `https` (L411, L558). Overstated: evidence also has `kind` and `note` (L558), file access is left to agents' tools (L745), one machine shares folders (L737), and a private branch push is not a contracted outward action (L39, L104).

**Verifier 1's fix.** Options: (a) Name a writer for the work reference (Add task form or project, and the builder at submit), store it in `tasks` outside the replay, add it to the briefing and to the builder and reviewer rows of Roles, and list evidence kinds beyond an `https` link (commit, path, command output) using the existing `kind` and `note` fields. The event records only that it changed, per L137. (b) Require an owner-provisioned remote and say so in setup and Risks. Recommend (a).

**Verifier 2: partly.** Confirmed core: `work reference` (L556, L28, L745) has no command (L61-80), no form field (L608), no event (`task.changed` covers only priority, project, L164), and is in neither the briefing (L368) nor the Roles read lists (L415-416). I must guess its type, writer and readers. Evidence `kind` values (L558) and whether a note-only row satisfies L356 are also undefined, so Milestone 2's local runners (L669) have no specified link. Overstated: https-only is a consistent choice (L411, L722), and pushing to a private remote is not an outward action (L39).

**Verifier 2's fix.** Reviewer's (a) needs correcting: an event must not carry the value (L137, L598). Option A (recommended): work reference is unfetched free text (path, repo, branch, commit) in `tasks`; owner may set it on Add task, builder must set it on submit; `task.submitted` marks it; claim and review-claim return it; Roles lists include it. Evidence becomes a row with a defined kind: an `https` link, or a note locating proof inside the work reference. Option B: require an owner-provisioned remote, stated in setup and Risks; this conflicts with L716.

### 46. Budgets have no unit, the task cap cannot be set, and spend is undefined for subscription seats and lost on several paths

- **Lines:** 37, 87, 304, 317, 346, 349, 399, 405, 511, 553, 556, 608, 720, 754
- **Rated:** major by both verifiers
- **Fix:** the owner has to decide
- **Found by:** completeness pass

The contract includes 'its budget' and tasks carry a budget cap, but the Add task form, the only way to add a task, has no budget field, and the hashed contract inputs omit it. No line gives the unit of budget or spend: tokens or money, and in which currency. Login credentials are flat-rate subscriptions, so their spend is undefined, yet the budget rule depends on it. Spend is lost when a lease expires before the last report and when a late job result is discarded, and reviewer calls carry no cost. Raising a task's cap is a contract edit, which releases the holder.

**Effect.** The contract cannot type the budget columns or the cost payload. The budget rule never fires for subscription seats, or compares unlike numbers, and a `budget` hold can only be cleared by discarding the claim.

**Verifier 1: partly.** Stands: budget is in the contract (L37) and on tasks (L556), yet the form (L608) and hashed inputs (L317) omit it; no unit or currency is stated anywhere; subscription spend is undefined (L50, L475, L511); raising a cap has no path except a contract edit (L121), which is barred in Finishing. Weaker: L173 "Money" and L754 imply spend is money; L720 already accepts self-reported loss; L399 is open to any "Holder", which L373 and L392 suggest includes reviewers; L79 and L436 ("change a budget") give partial outs.

**Verifier 1's fix.** Decide the unit. (a) Money in one workspace currency, with a price per provider and model so subscription seats report a notional cost. (b) Tokens are the budget unit in version 1, money shown only where reported. Recommend (b): L475 says nothing is estimated and L494 puts provider spend outside version 1. Then decide whether the task cap is a form field or project-only, add a raise-cap owner command that is not a contract edit, state whether reviewers may call L399, and keep the tokens of late job results.

**Verifier 2: confirmed.** I would have to guess. L553, L556, L567 and L568 (budget, spent, tokens, spend) have no unit, and the L399/L407 payloads are untyped. L494 says provider spend is unavailable, and L669 runs seats on logins. Case: a Working task is held `budget` (L349). The cap is contract (L37), so raising it is Edit contract, which releases the holder (L121), against L750. How the hold closes is unspecified. L87 refuses a cost report after expiry, L304 drops late job tokens, and L405/L559 give reviews no cost. Overstated: reviewer cost is ambiguous ("Holder", L399), not absent.

**Verifier 2's fix.** The reviewer's fix contradicts itself: a cap inside the hashed contract cannot be raised without a contract edit. Options: (a) money with a price table, which cuts against L475 and L738; (b) budgets and caps in total tokens, with spend optional and display-only. Recommend (b). Also take budget out of the contract (L37): make the cap a task field changed by `task.changed`, like priority, optional on the form and unhashed. Raising a cap or budget closes the `budget` hold. Accept cost reports after lease expiry, record late-job tokens, and add tokens to the review verdict.

### 47. Fixed interface lists are incomplete: missing refusal codes and hold reasons, `rounds_exceeded` unreachable, `/v1/next` has no kind for a command outcome, and 'always accepted' contradicts the pending rule

- **Lines:** 87, 98, 113, 116, 285, 298, 327, 356, 371, 388, 425-426, 644-645
- **Rated:** minor by one verifier, major by the other
- **Fix:** the owner has to decide
- **Found by:** consistency inventory, interfaces

The refusal list is a contract artefact but has no code for a command invalid in the current state (which Test 3 exercises for every state and command pair), for submit without evidence (a built-in, so not `blocked_by_rule`), for a wrong role, for an idempotency key reused with a different body, for the re-run limit, for a late job result, or for not found. `rounds_exceeded` is listed as a refusal, yet a failure at the limit is accepted and holds the task, so the next refusal is `on_hold` (it duplicates a hold reason). Two holds have no reason in the fixed list: a task that failed the claim gate for 3 seats, and a task past the model re-run limit. Pending outcomes are said to arrive via `GET /v1/next`, whose eight kinds include none for a command outcome; kind `task` is also undefined. Cost reports are 'always accepted', yet the pending rule refuses every holder command except heartbeat, release and read.

**Effect.** Tracks C and D code against different refusal sets; clients cannot map refusals to actions or distinguish a retryable refusal from a programming error; a seat waiting on /next never learns its pending claim resolved; a cost report during a multi-minute check is accepted or refused depending on who reads which line.

**Verifier 1: partly.** All quotes are exact. Stands: holds at L298 and L327 have no reason in the fixed list (L113) and no Needs you kind (L610); `rounds_exceeded` is a hold reason (L113) and a refusal (L426) with nothing choosing it over `on_hold` (L98, L116); L425 offers `/v1/next` but L388 has no kind for it and L296 names only `/commands`; a holder's state-invalid command (L644) has no code. Refuted: wrong role (L423, L355), key reuse (L136, L627), late result (L304), track divergence (L664, L687). L371 is scoped to acknowledgement, so that contradiction is weak.

**Verifier 1's fix.** Add rows to Open decisions. Recommended: (1) two new hold reasons for the claim-gate limit and the re-run limit, each with a Needs you kind, instead of overloading `check_error`; (2) drop `rounds_exceeded` from refusals so a held task always answers `on_hold` with the hold reason; (3) strike `/v1/next` from L425 to match L296, or else add a `command` kind; (4) add one `invalid_state` refusal; (5) state whether cost report, question and access calls work during pending and holds (recommend cost accepted). Leave role, key-reuse and not-found codes to the interface schema.

**Verifier 2: partly.** Must guess: (1) builder submits in Finishing: L644 says refused, L426 has no code. (2) L298 holds the task and L327 sends it to the owner; L113 has no reason (`check_error` is L305's errored check). (3) L98 accepts the failure and holds, so later calls get `on_hold` (L116); refusal `rounds_exceeded` is unreachable. (4) Submit answers 202; L425 names /next, L388 has no kind. Overreach: L136 already settles key reuse, L423 makes wrong-role claim `not_eligible`, and L371 means 'without acknowledgement' (L87, L123 also refuse).

**Verifier 2's fix.** Decide: (a) add refusals `invalid_state`, `criteria_incomplete`, `forbidden`; drop refusal `rounds_exceeded`. (b) One new hold reason with causing rule for L298 and L327, or reuse `check_error`; recommend new, since Needs-you choices differ. (c) Add /next kind `command` carrying the key, or strike /next from L425; recommend add, and define `task` as 'claimable work exists'. (d) Keep L285; reword L371 to 'need no acknowledgement' rather than amend L285. Skip `key_conflict` and `nothing_available`: empty claim-next is not a refusal. State refusal precedence.

### 48. The round limit says only 'holds the task'

- **Lines:** 98, 154, 263, 426, 610, 742, 751
- **Rated:** minor by one verifier, major by the other
- **Fix:** the owner has to decide
- **Found by:** state machine

Unstated: whether the third or the fourth failure trips the limit (the round starts at 0, the limit is 3); which state the task is held in; whether the builder gets a lease and the criteria are reopened; the Needs you choices; what closes `rounds_exceeded` and what the round is afterwards (a plain resume makes the next failure trip again); which call receives the `rounds_exceeded` refusal; and whether `task.before_done` gate failures count toward the limit.

**Effect.** The golden traces and Test 3 cannot cover the path every looping task ends on. The owner gets a Needs you item with undefined choices and no defined way out except cancel.

**Verifier 1: partly.** Quotes are exact. Refuted: gate failures count (L263 "counts as a failed review... the round goes up"); state (L59, L79 holds leave state unchanged, L74 gives Working); lease and criteria (L94 is unconditional, L89 pauses the clock); "no way out except cancel" (L66/L116/L121 contract edit, L79/L436 resume, L551 raise the setting). Stands: third or fourth failure (L98 against L154; L742 and L751 only lean third); Needs you choices absent, unlike L109 and L305; what closes the hold; the `rounds_exceeded` refusal (L426) has no call, since L116 already gives `on_hold`.

**Verifier 1's fix.** Option A (recommended, no new field): the failure that brings the round to the limit trips it. It is recorded in full per L94, plus a `rounds_exceeded` owner hold. Choices: allow one more round (closes the hold; the next failure trips again), edit the contract, or cancel. Drop `rounds_exceeded` from the L426 refusals, because `on_hold` covers it. Option B: the reviewer's per-task limit with "allow N more rounds", which adds a task column and a replayed value. Either way, say whether a contract edit resets the round.

**Verifier 2: partly.** Case: limit 3, the same task fails review three times. L98, L154 and L751 do not say whether failure 3 (round becomes 3) or failure 4 trips. L571/L610 need inbox choices and none are given (compare L109, L305). L426 lists `rounds_exceeded`, but L116 holds already refuse with `on_hold`, so no call is named. The exit and the later round are unstated (L79). Refuted part: L263 already makes `task.before_done` failures count. State and lease are mostly derivable from L59, L74, L89, L94, L750.

**Verifier 2's fix.** Decide four things. (1) Trip when the incremented round reaches the limit: the third failure, matching L751. (2) The Review fails row applies unchanged, plus the hold: Working with the builder keeping its claim and the lease clock paused (L89, L750), or Ready if escalated (L96). The reviewer's "Working with no lease" contradicts those, and its per-task limit adds an unlisted column. (3) Choices: allow one more round (closes the hold; the next failure trips again), edit the contract, cancel. (4) Drop `rounds_exceeded` from the refusals; `on_hold` covers it.

### 49. Lifecycle 'Events written' is incomplete, yet release requires 'exactly' those events

- **Lines:** 61-80, 98, 121, 123, 278, 593, 649, 694
- **Rated:** minor by one verifier, major by the other
- **Fix:** the PRD already settles it elsewhere; the text needs aligning
- **Found by:** event log

The release criterion requires every command to write exactly the events the lifecycle table names. The table omits events the PRD mandates elsewhere: `check.finished` for every gate result (so even the form save with the shipped criteria rule on), and for Cancel the closing of holds, resolving of Needs you items, withdrawal of checks and jobs and revoking of approvals, although Cancel is listed as `task.cancelled` only. Edit contract releases the holder with no release event listed; a failed review at the round limit opens a hold and a Needs you item. Whether these write `hold.closed`, `inbox.resolved`, `job.withdrawn` and `action.revoked`, or replay infers them, is unstated.

**Effect.** The acceptance line is false on the release run itself. Golden traces need exact events, and the replay of open holds, check results and action states depends on a choice nobody has made.

**Verifier 1: partly.** All four quotes are exact. Stands: L694 "exactly" contradicts L278, because the L693 form save runs `task.before_ready` (L608) with shipped rules L341-342, so Complete contract (L65) also writes `check.finished`. Does not stand: "that run" (L693) has no Cancel, contract edit or round-limit failure. Withdrawn checks are settled by L170 plus L278. `hold.closed`, `action.revoked`, `job.withdrawn`, `inbox.resolved` are registered (L167-176), and event-to-step mapping and exact traces are contract deliverables (L659-668). Edit contract names `task.returned` (L66); nothing requires `task.released`.

**Verifier 1's fix.** Make L694 and the lifecycle table agree with L278. Add one sentence under the table saying the column lists each command's own events and that gate results add `check.finished`. Drop "exactly" from L694; exactness stays with the golden traces (L649). Do not adopt the reviewer's rule that every replayed column change writes its own event, nor `task.released` on Edit contract: the PRD states neither. Whether Cancel writes `hold.closed`, `inbox.resolved`, `job.withdrawn` and `action.revoked` belongs to the contract's event registry and golden traces (L659, L668).

**Verifier 2: confirmed.** Form save with shipped rules on (L341-342, L608): L65 names only `task.contract_changed`, `task.ready`, but L276-278 also mandate `check.finished` and `check.queued`/`job.*` for the model gate. L694's "exactly" is therefore false on the release run; cost reports have no table row at all. Cancelling a held task with a pending check and an approved action: L80 says `task.cancelled` only, while L123 lists five side effects whose registered types (L167-176) are never tied to Cancel. L98 has the same gap. The Edit contract sub-claim fails: `task.returned` (L66) already clears the holder.

**Verifier 2's fix.** Keep the column as the move's own events. Add one note under the table that side effects write their already registered events (L167-176, L278), and reword L694 to allow them. Reject two parts of the reviewer's fix. `task.released` on Edit contract contradicts L66/L78, where it means a return to Ready. "Matching golden trace" cannot bind a live runner run, whose cost reports and check attempts vary against six to eight fixed sequences (L649). Event order within a command stays with the golden traces.

Text changes the verifiers proposed (not applied):

Verifier 1 would replace:

````text
Saving the Add task form is two commands in a row: Add task, then Complete contract.
````

with:

````text
Saving the Add task form is two commands in a row: Add task, then Complete contract.

The Events written column lists each command's own events. A rule that runs at the command's hook adds its own: every gate result is also a `check.finished` event, as described under How a transition is gated.
````

Verifier 1 would replace:

````text
Every command in that run wrote exactly the events the lifecycle table names for it, and the replay test passes on its log.
````

with:

````text
Every command in that run wrote the events the lifecycle table names for it, every gate result in that run wrote a `check.finished` event, and the replay test passes on its log.
````

Verifier 2 would replace:

````text
Saving the Add task form is two commands in a row: Add task, then Complete contract.
````

with:

````text
Saving the Add task form is two commands in a row: Add task, then Complete contract.

The last column names the events of the move itself. A command also writes the registered events for whatever else it changes: `check.*` and `job.*` events for the rule checks at its hook, `hold.opened` and `inbox.opened` when it holds the task or opens a Needs you item, and, on Cancel, `hold.closed`, `inbox.resolved`, `check.finished` with the result `withdrawn`, `job.withdrawn` and `action.revoked` for what it closes, resolves, withdraws and revokes.
````

Verifier 2 would replace:

````text
Every command in that run wrote exactly the events the lifecycle table names for it, and the replay test passes on its log.
````

with:

````text
Every command in that run that has a row in the lifecycle table wrote the events the table names for it, plus only the rule check, job, hold and Needs you events this PRD requires alongside them, and the replay test passes on its log.
````

### 50. Four replay columns have no event that carries them

- **Lines:** 137, 164, 171, 173, 278, 339-347, 399, 407, 556, 566, 589, 594-595, 598, 754
- **Rated:** minor by one verifier, major by the other
- **Fix:** verifiers disagree on whether the PRD already settles it
- **Found by:** event log

(1) `projects.spent`: model-check cost is counted against the project's budget, but it arrives in job results, which are outside the replay; `cost.reported` is only a holder's task call, and whether job spend runs the budget rule is unstated. Tasks with no project, and a task moved between projects by `task.changed`, are also undefined. (2) The `rule_checks` override includes 'why', but payloads hold no text and text is outside the replay. (3) Only gate results are promised a `check.finished` event; policy rows are not, and the `review.failed` hook is missing from that sentence. (4) Shipped rules exist before any event, so replay into empty tables yields no `rules` rows for them.

**Effect.** The replay test (Test 1 and the restore criterion) fails or is quietly narrowed by track A. Budget pauses differ depending on whether check cost is counted.

**Verifier 1: partly.** All five quotes are exact. Refuted: "decide whether job spend counts" is already settled (L754 with L732: counted, and assumed). "No event carries it" overstates: payloads may hold numbers (L137), `job.finished` exists (L172), schemas are a contract deliverable (L659), and events carry `project_id` (L153). Stands: nothing says job spend fires the `cost.reported` hook (L268, L399, L407); override "why" (L566, L594) conflicts with L137/L598; L278 promises no `check.finished` for policy rows and omits `review.failed`; shipped rules (L339-347) have no stated `rule.created`.

**Verifier 1's fix.** Two edits the PRD already determines: the replayed override is who and when only (L137, L598 keep text out); every policy row gets a `check.finished` event (L170, L280, L594). Three small decisions remain, not edited: (a) does job spend run the budget rule; recommend yes, one `cost.reported` event per job result. (b) Does the `review.failed` policy write a row always or only on escalation; recommend only on escalation, like `review.assign`. (c) Shipped rules: `rule.created` at install, or seeded before replay; recommend `rule.created`.

**Verifier 2: partly.** Case: project spent 9.90 of 10.00; a submit queues a model check whose job result reports 0.20 (L407). L754 with L732 already says it counts, but no event carries it (L173, L399, L598): replay gives 9.90, and whether `project.paused` fires or the task cap (L349) applies is a guess. L278 omits `review.failed` (L266) and promises no event for policy rows L594 replays. Override "why" (L566) is text, excluded by L137/L598. Shipped rules (L339-347) have no creating event. No-project and moved-task sub-claims are weak: events carry `project_id` (L153).

**Verifier 2's fix.** L754 already decides job spend counts; decide how. A (recommended): each accepted job result writes `cost.reported` with the job as subject, adds to `projects.spent` only, runs the project budget rule, never the task cap. B: carry spend in `job.finished`, no pause. Also decide whether a `review.failed` policy row is written always or only on escalation (recommend only on escalation). The rest the PRD settles: override replays who and when, not why; every rule check row writes `check.finished`; workspace setup writes `rule.created` per shipped rule.

Text changes the verifiers proposed (not applied):

Verifier 1 would replace:

````text
`rule_checks`: result and override. `rules`: enabled and current version.
````

with:

````text
`rule_checks`: result and override (who and when; the reason is text and stays outside the replay). `rules`: enabled and current version.
````

Verifier 1 would replace:

````text
Every gate result is a rule check row and a `check.finished` event.
````

with:

````text
Every gate result is a rule check row and a `check.finished` event. A policy rule that writes a row writes a `check.finished` event with it.
````

### 51. Events written when a pending transition completes have no defined actor, and break 'one `at` per command'

- **Lines:** 65, 134, 148, 152, 157, 276, 317, 332, 608
- **Rated:** minor by one verifier, major by the other
- **Fix:** the PRD already settles it elsewhere; the text needs aligning
- **Found by:** event log

When a pending transition completes, its events are written inside someone else's transaction: the orchestrator's job result, the owner's override or rule switch-off, or a timer. `command_id` is specified for them; the actor is not. If `task.claimed` takes the transaction's caller as actor, replay sets the holder to the orchestrator and the past-holder set taken from the log is wrong. These events also get a later `at` than the command's first events, against the rule that one command's events share it. Which events are written at request time is unstated: `task.contract_changed` must precede the check that reads the contract. `at` itself is a wall clock, which can step back.

**Effect.** Tracks A and B write different actors and split events differently; holder replay and the who-may-review rule read the wrong seat. A clock step breaks 'at never decreases' and step durations.

**Verifier 1: partly.** All four quotes are exact. Stands: L152 never names the actor of deferred events, and L134 "one command shares `at`" contradicts L157, which puts one key in two transactions. Request/completion split for L65 is unstated. Weakened: timers never complete a pending transition (L286, L304-305); only track A appends events (L131, L679) from a one-author contract with golden traces (L657-668), so tracks cannot diverge; replay test (L591, L642) catches a wrong holder; L628 fixes one database clock, though step-back is unaddressed.

**Verifier 1's fix.** Two edits the PRD already determines. Actor is the original requester: L157 gives these events the requester's key, keys are unique only per caller (L581), and L563 stores the requester. `at` is shared per transaction: L134 reads it once per lock. Not determined, left for the maintainer: which Complete contract events are written at request versus completion (belongs in the golden traces), `command_id` and `cause_id` for an override completing a refused transition (L289), and whether to clamp `at` against clock step-back.

**Verifier 2: confirmed.** Case: builder B claims T under a model rule at `task.before_claim` (L261, L276); orchestrator O posts the job result and `task.claimed` is written in O's transaction. L157 fixes `command_id`; L152 leaves the actor open between B, O and the app, and the golden traces need it. L134 "every event of one command shares it" contradicts L157. L65: the shipped model rule (L342) makes every `task.ready` deferred, and the timing of `task.contract_changed` is unstated. L289 overrides have no `check.finished` cause. L148 is asserted, not enforced. Impact is overstated: one contract author prevents track divergence.

**Verifier 2's fix.** The reviewer's conclusion is right but its basis is wrong: L332 and L591 do not force the actor, because a payload could carry the seat. L581 does: a key identifies a command only together with its caller, so an event carrying the requester's key must carry the requester as actor. State that, make `at` per transaction with a clamp, add `check.overridden` as cause, and say `task.contract_changed` is written at request time (L260, L608, L591). A per-command list is unnecessary; only Complete contract writes an event before its checks. Actor and key for refusal-path events remain unspecified.

Text changes the verifiers proposed (not applied):

Verifier 1 would replace:

````text
and every event of one command shares it
````

with:

````text
and every event written in that transaction shares it
````

Verifier 1 would replace:

````text
Who caused it: the owner, a seat or the app.
````

with:

````text
Who caused it: the owner, a seat or the app. For events written when a pending transition completes, it is the original requester, whose key they carry.
````

Verifier 2 would replace:

````text
`at` is the wall clock read once after the lock is taken, and every event of one command shares it.
````

with:

````text
`at` is the wall clock read once after the lock is taken, raised to the last `at` written if the clock has stepped back, and every event of one transaction shares it. A command that waits on checks writes its later events in a later transaction, with that transaction's `at`.
````

Verifier 2 would replace:

````text
Who caused it: the owner, a seat or the app.
````

with:

````text
Who caused it: the owner, a seat or the app. An event with a `command_id` has that command's caller as actor, whichever transaction writes it.
````

Verifier 2 would replace:

````text
Events written when a pending transition completes carry the original requester's key, with `cause_id` set to the `check.finished` event.
````

with:

````text
Events written when a pending transition completes carry the original requester's key and the original requester as actor, with `cause_id` set to the last `check.finished` event, or to the `check.overridden` event when an override completes it.
````

Verifier 2 would replace:

````text
queues one job per check, opens a `check` step and answers "pending".
````

with:

````text
queues one job per check, opens a `check` step and answers "pending". The contract a Complete contract command carries is saved and `task.contract_changed` is written in this first transaction, so the check reads it and a failed gate leaves it in Backlog. Every other event the lifecycle table names for a gated command is written at step 6.
````

### 52. build, finish and rework overlap, so 'the step the state calls for' is not determined

- **Lines:** 191, 193, 207-208, 212, 262-263
- **Rated:** minor by one verifier, major by the other
- **Fix:** verifiers disagree on whether the PRD already settles it
- **Found by:** steps and timing

In a rework round, three kinds can be true at once: `rework` ('until it submits again'), `build` (rule 5: announcing a criterion makes the `build` step carry it, and the shipped clients always announce), and `finish` (every builder criterion passed, not yet submitted). When `task.before_done` fails, no builder criterion reopens, so `finish` and `rework` both hold from the start. Other cases are not defined either: the step after a refused submit, after a hold lifts in Working (does the new `build` keep the interrupted criterion?), and after a new builder claims an escalated or expired rework (`briefing`, then `build` or `rework`?).

**Effect.** The contract item 'which event opens and closes which step' has several valid answers for Working. Rework time on a reopened criterion may or may not count toward that criterion, so tracks A and F disagree.

**Verifier 1: partly.** All five quotes are exact. The overlap in the "Open while" column (L207, L208, L212) is real, but L212's "until it submits again" plus rules 1-2 (L189-190) already make `rework` exclusive after a failed review, and L224 counts criterion time from `build` steps only. The A/F disagreement is overstated: L661 and L668 put the step table and golden traces in the contract, and L596 replays `task_steps`. L206 settles `briefing` first. A refused submit follows the same predicates. Only the post-hold criterion is unsettled, and L193's backfill mostly covers it.

**Verifier 1's fix.** Scope `build` and `finish` to tasks with no failed review, so the step table agrees with L212: after a failed review the working step is `rework` until the next submit. A precedence table is not needed. The reviewer's criterion column on `rework` is a new requirement that changes L224; leave it out unless the owner wants rework time counted per criterion. Whether a `build` step reopened after a hold keeps its announced criterion can be fixed in the contract's step table.

**Verifier 2: confirmed.** Milestone 2's golden trace needs one failed review (L669): `review.failed`, the builder's first call, start on the reopened criterion (clients always announce, L193), pass, submit. L212 keeps `rework` open until submit, subject the review. L193 and L207 put the announced criterion on a `build` step. L208 opens `finish` after the pass. I must guess which wins and whether L224 counts that time. A new claimer in round 1 (L96) and the criterion after a hold (L191) are also undefined. A refused submit in round 0 is derivable: `finish`.

**Verifier 2's fix.** Options: (A) `rework` is the only work kind in round 1+, and announcements change no step. (B) As A, but rule 5 applies to `rework`, which records the criterion. (C) `build` and `finish` in every round; drop `rework`, since the round column (L570) marks it. Recommend B: timing cannot be backfilled (L5). A new claimer in round 1+ gets `briefing`, then `rework`. Reject "reopen the kind before `check`": L260 and L263 open a hold or `wait_builder` instead. State that a closed `check` or hold opens the step the state calls for.

Text changes the verifiers proposed (not applied):

Verifier 1 would replace:

````text
The builder is working toward a criterion. |
````

with:

````text
The builder is working toward a criterion and no review of the task has failed. After a failed review the working step is `rework`. |
````

Verifier 1 would replace:

````text
Every builder criterion has passed and the task is not yet submitted, or an approved
````

with:

````text
No review of the task has failed, every builder criterion has passed and the task is not yet submitted, or an approved
````

### 53. 'How long did a rule hold tasks up' gives two formulas for the same minutes and double counts

- **Lines:** 209, 225-226, 305, 307, 566-567
- **Rated:** minor by one verifier, major by the other
- **Fix:** the owner has to decide
- **Found by:** steps and timing

The row adds per-check 'finished minus queued' and also credits a multi-check `check` step 'to the one that finished last'. With rule A finishing at 2 minutes and rule B at 5, queued behind A, the first formula gives 7 minutes for a 5-minute step and the second gives A nothing. After an `error`, the `check_error` `wait_owner` step is credited to the rule, and so is the re-run attempt that runs inside that step. Times live on attempts, not checks, so 'finished minus queued' for a check with three attempts is undefined. A `wait_review` step is credited whole to the provider rule after one refusal, including time before the refusal.

**Effect.** Track F cannot write the query or its tests. Per-rule hold-up sums exceed elapsed time, so the owner's 'cost in time of each rule' (Goal 6) is inflated and differs between implementations.

**Verifier 1: partly.** Quotes at L225, L226 and L307 are exact. Refuted: the multi-check double count. L226's last sentence reads as the tie-break for exactly that overlap, which L225 acknowledges, so A gets 0 and B gets 5. Nothing requires per-rule sums to equal elapsed time. Stands: times live on attempts (L313, L567) and `rule_checks` has none (L566), so check-level "finished minus queued" is undefined after a requeue (L304). An error re-run (L305, L307) can overlap the `wait_owner` step. `wait_review` is credited whole (L209, L570). Open decisions and Risks are silent.

**Verifier 1's fix.** Option 1 (recommended): compute hold-up from `task_steps` only, since steps partition time (L185, L194). Credit a `check` step to its single rule or to the last finisher, `wait_owner` by the hold's causing rule, and `wait_review` from the first refusal's rule-check time (L278). Drop "finished minus queued" from L226 and keep attempt times for L225 only. Option 2: keep the per-check span, defined as first attempt queued to last attempt finished, clipped to the `check` step. No stored data changes either way, so this can be settled when the contract is written.

**Verifier 2: confirmed.** L226 sums per-check "finished minus queued" and also credits a multi-check `check` step to the last finisher. Case: two model gates at `task.before_ready`, one serial orchestrator (L225); A finishes at 2 min, B at 5. Total is 7 or 5; A gets 2 or 0. Times exist only on attempts (L313, L566-567), so a retried check (L304) has no single interval. L305-307 do not say whether the `check_error` hold stays open during a re-run. L209/L570 credit the whole `wait_review`. Step table and golden traces need guesses.

**Verifier 2's fix.** Recommend steps only: hold-up is the duration of `task_steps` credited to the rule. `check` steps go to the last-finishing check (already stated), `wait_owner` by the hold's causing rule, `wait_review` where it names the rule. Delete "finished minus queued" from L226. Decide separately: split `wait_review` at first refusal (new step row, golden trace) or keep whole-step as an upper bound; and whether a `check_error` re-run runs inside the hold. Drop the reviewer's "or split by attempt run time": pick one. Alternative: keep attempt sums and define overlap subtraction.

### 54. Per-criterion attribution: nothing says what `criterion.passed` does to the open build step

- **Lines:** 70, 190, 193, 207, 224
- **Rated:** minor by one verifier, major by the other
- **Fix:** the owner has to decide
- **Found by:** steps and timing

Rule 5 gives a criterion to 'an open step without one' when it passes, but does not say the pass closes that step. Without an announcement: `build` is open from 10:00; C1 passes at 10:30 and the step gets C1; C2 passes at 11:00 and the open step already carries C1, so C2 gets zero and its half hour goes to C1. With an announcement: start C1, pass C1, 20 minutes on something else, start C2, and those 20 minutes go to C1. Segments closed earlier by a hold or a `check` step are never backfilled; they are 'unattributed' even when the builder passes that same criterion right after.

**Effect.** Per-criterion durations, a headline measure, depend on an unstated choice. The golden traces and track F's queries need the exact rows, and an agent that does not announce yields numbers that are wrong, not merely unattributed.

**Verifier 1: partly.** Quotes at L190, L193, L224 are exact. The core gap stands: no line says what a non-final `criterion.passed` does to the open `build` step, so both worked examples are possible readings. Three parts fail. L208 settles the final pass (`finish` opens). L193 and L224 already state that only the open step is backfilled and the rest is unattributed, so the hold case is documented design. L661 assigns the event-to-step table to the contract, and L755 already flags per-criterion precision. Events keep start and pass times, so nothing is lost.

**Verifier 1's fix.** Decide in rule 5 (L193) what a non-final pass does. A: it closes the open `build` step and opens a new criterion-less `build` step at the same effective time; backfill stays limited to the open step, so interrupted segments stay unattributed as L193 and L224 say. B: A plus backfill of every criterion-less `build` step since the previous pass. C: the pass leaves the step open, and only announcing agents get per-criterion numbers, as L755 implies. Recommend A: it fits L207 and L208 and adds least. Also reconcile L755 with L193's backfill.

**Verifier 2: confirmed.** L661 makes me write which event closes each step, but L193 only says a pass labels "an open step without one". Case: ack 10:05, pass C1 10:30, pass C2 11:00. If the pass leaves `build` open, C1=55 min and C2=0; if it closes it, 25/30. L207-208 settle only the last pass (`finish` opens). Announced variant: the gap after pass C1 goes to C1 or to nobody. Golden traces (L648) need exact rows. The third sub-claim is no defect: L193 and L755 already leave closed segments unattributed.

**Verifier 2's fix.** Option A (recommended): `criterion.passed` labels the open `build` step if it has no criterion, closes it, and opens a criterion-less `build`, or `finish` after the last builder criterion (L208). Also decide whether `criterion.started` relabels an open criterion-less step or closes it and opens a new one; I would close it, so idle gaps stay unattributed. Keep backfill to the open step, as L193 and L755 say: the reviewer's closed-step backfill would hand idle time after a pass to the next criterion. Option B: a pass never closes the step, and unannounced multi-criterion numbers are documented as unreliable.

### 55. A model-checked `warn` rule (and two policy hooks) contradict Goal 4 / Test 4 'no transition without a recorded result'

- **Lines:** 16-17, 228, 247, 276-278, 308, 362, 615, 645, 718
- **Rated:** minor by one verifier, major by the other
- **Fix:** the PRD already settles it elsewhere; the text needs aligning
- **Found by:** rule checks, build plan, product and scope

Goal 4 says a transition cannot complete until every rule bound to the moment has a recorded result, Goal 5 says each check records whether the rule applied, and Test 4 says a transition with an enabled gate rule and no result row cannot commit. A gate rule with `on_fail` `warn` and a model checker is an enabled gate rule, yet L247 says it never makes the caller wait and only a blocking model checker creates a pending transition, so its result cannot exist when the transition commits; L308 reads as if the transition waited for the outcome. Unspecified: when the warn job is queued, what its check row holds meanwhile, and what happens when the result arrives after the task has moved on, been cancelled or changed round. L362 says a custom rule blocks, while the Risks response relies on setting a rule to warn. Policy rules at `review.assign` and `cost.reported` write a row only when they change the outcome, so 'how often did a rule apply' and the per-rule run count on the Rules screen cannot be computed for them.

**Effect.** Track B cannot satisfy Test 4 and L247 together: it either blocks on warn rules or fails Test 4 as written. The only relief promised for an orchestrator outage (set the rule to warn) has no defined behaviour for custom rules. The provider and budget rules show misleading run counts on the Rules screen.

**Verifier 1: partly.** All seven quotes are exact. Stands: L16 and L645 are literally unsatisfiable for a model-checked warn rule, since L247 and L276 make only blocking model checks pending; L16 also conflicts with L278. Refuted: Option B is closed by L247; L308 mirrors L247; cancel is answered at L123, round by the check key at L313, late results at L304. "Only relief" is wrong: L305 and L756 allow turning the rule off. L228 is computable, because `applied` rows (L280) are exactly the outcome-changing runs. Residue: L615 "ran" count, L362 wording.

**Verifier 1's fix.** Scope Goal 4 and Test 4 to blocking rules, the term L305 already uses, so they agree with L247, L276 and L278. No new behaviour is added. Left out because the PRD does not determine them, for the maintainer to settle when writing the contract: whether a warn model check's row and `check.queued` are written in the transition's transaction; whether a custom rule's `on_fail` is editable (L362 against L718, and L615 does not list it); and the "ran" label on the Rules screen for the two sparse policy rules.

**Verifier 2: partly.** Real: owner sets "specific details" (L342) to warn, saves Add task. L247/L276 commit `task.ready` at once; L16 and L645 forbid it. L277 "every check" would make a warn check delay a blocking one at the same hook. Overstated: L247 excludes Option B, so no decision; L123 covers cancel, L217 no step, L625 puts the row in the command's transaction, L313 keys by round. L308 and Goal 5 (L17) are not contradicted. L362 is weak, but L615 shows no `on_fail` control. L228 holds; only L615 "ran" is inexact.

**Verifier 2's fix.** Narrow Goal 4 and Test 4 to gate rules set to block. Make step 6 wait only on blocking checks. State in step 5 that a warn model check is queued with the transition and its later result changes nothing. Qualify the run count on the Rules screen for the two policy hooks. Left out of the edits because the PRD does not settle them: whether Settings, Rules exposes `on_fail` (L615 omits it, L718 needs it), whether a custom rule can be switched to warn, and whether a contract edit withdraws an unfinished warn check.

Text changes the verifiers proposed (not applied):

Verifier 1 would replace:

````text
A transition cannot complete until every rule bound to that moment has a recorded result.
````

with:

````text
A transition cannot complete until every blocking rule bound to that moment has a recorded result.
````

Verifier 1 would replace:

````text
a transition with an enabled gate rule and no result row cannot commit
````

with:

````text
a transition with an enabled blocking gate rule and no result row cannot commit
````

Verifier 2 would replace:

````text
A transition cannot complete until every rule bound to that moment has a recorded result.
````

with:

````text
A transition cannot complete until every gate rule set to block at that moment has a recorded result. A gate rule set to `warn` is recorded and never holds the transition.
````

Verifier 2 would replace:

````text
a transition with an enabled gate rule and no result row cannot commit
````

with:

````text
a transition with an enabled gate rule whose `on_fail` is `block` and no recorded result cannot commit, and a transition whose only model-checked gate rules are set to `warn` commits without waiting
````

Verifier 2 would replace:

````text
When every check has a result, the server validates
````

with:

````text
When every blocking check has a result, the server validates
````

Verifier 2 would replace:

````text
There is no separate applicability job.
````

with:

````text
There is no separate applicability job. A model check on a `warn` rule does not make the transition pending: its rule check row and job are written with the transition, and its result is recorded when the check finishes, without changing the transition.
````

Verifier 2 would replace:

````text
Each row shows how often the rule ran, its average time and its tokens.
````

with:

````text
Each row shows how often the rule ran, its average time and its tokens. For rules at `review.assign` and `cost.reported` the count is how often the rule changed an outcome, because only those runs are recorded.
````

### 56. Machine helper and system keychain conflict with 'a server the owner controls'

- **Lines:** 449, 466, 528, 636, 657-668, 737
- **Rated:** minor by one verifier, major by the other
- **Fix:** the owner has to decide
- **Found by:** credentials

The helper 'must run on the owner's machine' and is part of the server only 'with the recommended installation'. The open decision on where it runs allows 'a server the owner controls'. There the server has no desktop keychain for API tokens, cannot 'open the tool's own sign-in and wait', and holds no settings folders, so the helper is a separate process with a protocol to the server. That protocol is not in the contract list, which names only the reading shape. The daily database backup does not cover the keychain or settings folders, so a restore yields credential rows pointing at nothing.

**Effect.** Track G builds an in-process helper that cannot work on the second supported installation; token storage and sign-in fail there with no fallback defined.

**Verifier 1: partly.** Quotes are exact, but the main inference fails. L528 says the helper is part of the server in the recommended installation, and L737's recommendation covers both hosts, so no separate process or protocol is implied. L448 runs tools "without a screen" and L669 uses the login "on the machine", so settings folders sit on the host. L501 Verify and L473 "sign in again" cover a restore; L448/L455 keep secrets out of the database by design. What stands: "system keychain" (L449) and sign-in (L466) are undefined on a headless host, and L737 omits Credentials as a dependant.

**Verifier 1's fix.** Options: (a) define "the owner's machine" at L528 as the host running the installation, keep the helper in-process, add Credentials to the L737 "depends on" cell, and name the token store and sign-in path for a host with no desktop keychain or browser; (b) limit v1 Credentials to the owner's-own-machine installation; (c) a separate helper with an authenticated protocol. Recommend (a), falling back to (b) if no headless token store is chosen. Either way, add a line that a restore onto another host leaves credentials signed out until Verify passes.

**Verifier 2: partly.** Real: L528 says the helper is in the server "with the recommended installation", but L737 recommends two. Case: server on a VPS, owner adds an OpenRouter token. L449/L574 need a "system keychain"; L466 needs an interactive sign-in. I must guess whether the contract (L657-668) gets a helper identity table, helper auth and calls, or none; L549-575, L177 and L527 have none. Overstated: a server can hold settings folders; headless sign-in is unverified; same-machine restore keeps the keychain (L636). Proposed "unverified" state invents a requirement.

**Verifier 2's fix.** Options: (a) helper is always in-process in v1; Credentials works only when the server runs on the owner's own machine; elsewhere seats connect on their own (L453 already allows) and the tab is unavailable. No new tables or protocol. (b) separate helper: add helper identity, token, calls and events to the contract. Recommend (a): reword L528, note it at L737. For backups, do not add a state: say at L636 that keychain and settings folders are outside the backup and the owner runs Verify all (L501) after a restore.

### 57. Track G's stated dependencies and placement contradict what handoff changes

- **Lines:** 13, 344, 529, 653, 669, 672, 685, 687
- **Rated:** minor by one verifier, major by the other
- **Fix:** verifiers disagree on whether the PRD already settles it
- **Found by:** credentials

Track G 'needs first' only the contract and C, and tracks 'can run in parallel', yet Credentials is also 'its own milestone, after Questions and approvals'. Handoff changes things other tracks own: a hold reason, a step kind and a reset timer (A owns 'all timer logic'), the provider-review policy (B), and credential switching inside the runner and MCP server (D). Goal 1 allows no state change outside the transition function. None of A, B or D lists Credentials work or tests, and the core-loop runners 'use whatever login is active', so the switch to assigned credentials in D has no owner.

**Effect.** G either edits A's, B's and D's code late, or handoff ships as a screen with no engine behind it. Tests 2, 3 and the replay never exercise `wait_limit`.

**Verifier 1: partly.** All four quotes are exact. Refuted parts: parallel tracks vs a later milestone is no contradiction (B is milestone 3 yet parallel; L687 stubs, then integrate). The contract already carries the hold reason, step kind and events (L113, L215, L177, L661, L664). L59: a hold changes no state, so Goal 1 is untouched. L540-541 require a working switch and hold, so no "screen without engine". Stands: G's row (L685) claims "handoff" whole, while A owns timers and steps (L679, L687) and B checkers (L680); L86 omits the reset timer; runner credential use is unassigned (L669, L528).

**Verifier 1's fix.** State at L687 what the existing ownership rules already imply: the `credential_limit` hold, `wait_limit` step and reset timer are track A's, the provider-rule comparison is track B's, and G's handoff goes through the transition function. Not mechanical, so left out: a new golden trace, "G starts after milestone 4" (contradicts L687 "Every track starts from the contract"), and whether the reference runner (D) or the machine helper (G) applies a seat's credential and detects a limit. That last point needs an Open decisions row; L448 and L528 point to the helper.

**Verifier 2: partly.** Real gap, wrong framing. Parallel tracks (L653) against milestone 5 (L529, L672) is no contradiction: A-F also deliver across milestones 2-4. But G "owns handoff" (L685), while the hold, `wait_limit` step and reset timer can only be A's (L13, L131, L687) and the provider rule is B's (L680). Case: a seat on K1 in `build` hits a limit, with K2 and K3 limited. I must guess who sends that command (no agent call L388-407, no helper interface L657-668) and how the switch reaches the runner (L388 kinds).

**Verifier 2's fix.** Already determined: A owns `credential_limit`, `wait_limit` and the reset timer; B owns the provider-rule change; G keeps helper, readers, add flow, order and screen, and still starts from the contract (L687), not after milestone 4. Undetermined: who detects the limit and switches. Option 1: the helper launches seats with their credential and reports limits in-process as the app, with no agent-interface change. Option 2: the runner (D) reports through a new agent call, which strains L455. Recommend 1, plus a helper-to-transition interface in the contract list and one handoff golden trace.

Text changes the verifiers proposed (not applied):

Verifier 1 would replace:

````text
Track A owns all timer logic, and the sweep in track C only triggers it.
````

with:

````text
Track A owns all timer logic, and the sweep in track C only triggers it. The same split holds for Credentials: the `credential_limit` hold, the `wait_limit` step and the timer that lifts the hold at the earliest reset time are track A's, the provider-review rule's comparison is track B's, and track G's handoff reaches them only through the transition function.
````

### 58. The reader part of the contract and several Credentials criteria depend on reader outputs, accounts and limits that do not exist or are unverified

- **Lines:** 481-484, 490, 535, 537, 540-541, 667, 685, 725, 727, 732, 759
- **Rated:** minor by one verifier, major by the other
- **Fix:** the owner has to decide
- **Found by:** credentials, build plan

Milestone 1 must fix 'what each provider's reader returns' before any track starts. For Gemini and Grok the figures are 'What that screen shows', taken from another document and 'Not re-tested'; OpenAI's check is '(not verified)'; Claude's reset entry 'has only been seen empty'. Track G is verified 'with recorded provider replies', which do not exist for these. The version check has no stated known-good versions, and for untested readers none can exist; with an allow-list every tool update turns readings 'unavailable'. Reuse of the Campus readers is itself an open decision. Handoff and `credential_limit` criteria need a run that really hits a provider limit and then a wait until a reset hours or days away; no fake provider or injection point is specified. The Claude reset criterion needs an account with a grant whose non-empty form has never been seen; the two-account criterion needs six paid subscriptions.

**Effect.** The contract author must guess four reader outputs, or the contract milestone (and so the core loop) waits on milestone 5 provider research nobody is assigned, contradicting the Scope risk response. Track G cannot show at least four of its eleven criteria, so milestone 5 has no reachable end.

**Verifier 1: partly.** All nine quotes are exact. Much is already answered: L575 fixes a generic reading shape; L732 with L759/L763 forces the Campus-reuse and Claude-cache decisions before the contract; L727 states an unknown version shows "unavailable"; L669 keeps the core loop off Credentials; L685 recorded replies can carry short reset times, so no fake provider is needed. What stands: L667 puts per-provider reader output in the contract while L483-484 and L490 are untested, and L535 and L537 need accounts the PRD does not secure.

**Verifier 1's fix.** Options: (1) narrow L667 to the generic reading shape already at L575 and leave per-provider parsing to Track G; (2) keep L667 and add a pre-contract spike that records replies from every source. Recommend (1): only the generic shape crosses tracks (L473, L657). Separately, mark L535 and L537 as conditional on named accounts, or defer the Grok two-account and Claude-reset checks, and record the tested tool version per reader in L481-484. No fake provider belongs in the PRD.

**Verifier 2: partly.** L667 puts per-provider reader output in the contract, but I would guess: Gemini/Grok figures ('What that screen shows', L483-484); Claude's non-empty reset entry (L481, never seen); where Codex per-reset expiry dates and Claude reset kinds (L481-482) fit L575's single-value entry; reading `state` values and unknown-version behaviour (L727). Case: run hits limit on C1 — no command in L386-407/L527 writes `credential.limit_reached`, so no golden trace for L540-541. Overstated: replies can be recorded in-track (L685); L535/L541 are costly, not impossible; L732 already gates the contract on L759.

**Verifier 2's fix.** Reject (a): it contradicts L448-449/L461/L535 and fixes neither Claude resets nor handoff. Recommend: keep in milestone 1 only what two tracks touch (L657): generic reading shape with a reset-entry form, reading states, the limit-reported command, `credential_limit` timer, `wait_limit`. Move per-provider parsers to a Track G spike that records replies first. Alternative: full spike before the contract (delays core loop). Also decide: fake provider tool for L540-541; L537 conditional, else dash (L763 alternative); name L535 accounts; unknown-version policy.

### 59. The idempotency store would hold seat tokens and API tokens in plaintext

- **Lines:** 136, 455, 538, 572, 613, 627, 632
- **Rated:** minor by one verifier, major by the other
- **Fix:** the PRD already settles it elsewhere; the text needs aligning
- **Found by:** security and privacy

Every mutating call, owner calls included, is recorded in `commands` with the command and a stored result, and a repeat must return the completed result. Connecting a seat returns its token; adding a credential carries a pasted API token in the command. Read literally, the plaintext seat token sits in the stored result and the API token in the stored command for at least 7 days, readable by anyone with database or backup access. That contradicts 'stored hashed, shown once' and 'never returned by any interface'. The alternative, a repeat that cannot return its result, contradicts principle 6 and Test 5.

**Effect.** A database or backup reader gets live seat and provider tokens, or tracks A and C implement idempotent replay differently for the two commands that return or carry secrets.

**Verifier 1: partly.** Quotes are exact, but the plaintext reading is overstated. L449 says the app keeps an API token only in the keychain plus a masked label; L455/L538 bar returning it by any interface, repeats included; L632 says seat tokens are stored hashed and shown once. L572's "command" is not stated to be the full body. Track claim is wrong: C owns both idempotency and sign-in (L681), G owns add credential (L685). What stands: L136/L572 carve out no exception, so a generic idempotency layer could store both, and no test catches it.

**Verifier 1's fix.** L449, L455 and L632 already decide it: secrets are never stored in `commands` and a repeat never returns a token. Say so in principle 6 (L136) and on the `commands` row (L572). No new requirement is added. Extending Test 5 or criterion 538 to cover the two cases, as the reviewer proposes, would be a new test requirement, so I left it out of the edits; it is a reasonable optional follow-up for the maintainer.

**Verifier 2: confirmed.** Real gap. L436 and L527 route connect-seat and add-credential through the same idempotent path; L136 and L572 say `commands` keeps the command and a stored result and a repeat returns that result. L613's reply carries the seat token; L462's command carries a pasted API token. A verbatim-replay store breaks L632 (hashed, shown once) and L449 (app keeps only keychain entry and masked label). Only L137 excludes secrets, and only for event payloads. Overstated: Test 5 (L646) only says "writes once", and L455 concerns returning, not storing.

**Verifier 2's fix.** L632 and L449 already decide it: a hashed token cannot be replayed, and an API token lives only in the keychain. State under principle 6 and on the `commands` row that neither stored field holds a secret, and that a repeated connect-seat returns its result without the token; extend Test 5. Do not touch criterion 538: it covers credentials, and L442 says a seat token is not one. Do not specify "returns the id"; the result shape belongs to the interface schema.

Text changes the verifiers proposed (not applied):

Verifier 1 would replace:

````text
Every mutating call carries an idempotency key. A repeat with the same key writes nothing and returns
````

with:

````text
Every mutating call carries an idempotency key. The stored command and its stored result never hold a seat token or an API token, so a repeat of a call that showed a token returns its result without the token. A repeat with the same key writes nothing and returns
````

Verifier 1 would replace:

````text
Caller kind, caller id, key, command, outcome, stored result
````

with:

````text
Caller kind, caller id, key, command, outcome, stored result. Neither the command nor the result holds a seat token or an API token
````

Verifier 2 would replace:

````text
A repeat with the same key writes nothing and returns the command's current outcome: pending, completed with its result, or refused with its cause.
````

with:

````text
A repeat with the same key writes nothing and returns the command's current outcome: pending, completed with its result, or refused with its cause. The stored command and the stored result hold no secrets. A seat token is returned only in the first reply to connecting a seat, and a repeat returns the result without it. A pasted API token goes to the system keychain and is not kept in the stored command.
````

Verifier 2 would replace:

````text
Caller kind, caller id, key, command, outcome, stored result
````

with:

````text
Caller kind, caller id, key, command, outcome, stored result. Neither the command nor the result holds a seat token or an API token
````

Verifier 2 would replace:

````text
Every mutating call is repeated and writes once.
````

with:

````text
Every mutating call is repeated and writes once. A repeated connect-seat returns its result without the token, and after connect-seat and add-credential no row of `commands` holds a seat token or an API token.
````

### 60. One seat can stall the whole workspace or a project's budget: no limits on questions, access requests or cost reports

- **Lines:** 89, 225, 304-305, 343, 371, 396-399, 742, 754
- **Rated:** major by one verifier, minor by the other
- **Fix:** the owner has to decide
- **Found by:** security and privacy

No limit exists per seat on questions, access requests, cost reports or idempotency keys. Each question becomes an orchestrator job; one orchestrator runs jobs one after another for the whole workspace, and model-check tokens count against the project budget. A builder in one project can fill the queue so other projects' checks miss the queue timeout twice and fail closed with `check_error`. A cost report is always accepted and unvalidated: an inflated figure pauses the whole project, a negative one lowers `spent`. An access request holds the task and pauses the lease clock, so a seat can then die and keep the task.

**Effect.** A single looping or injected builder floods Needs you, pauses its project, and puts unrelated tasks on `check_error` holds. The refusal list has no cause for it, so clients cannot back off.

**Verifier 1: partly.** Stands: nothing caps questions or access requests (L396-398; settings L551 list none), job order is unspecified (L406), so one seat's question jobs can push other projects' checks past the queue timeout twice into `check_error` (L304-305); L426 has no back-off cause; cost sign is unspecified. Falls: L371 "always accepted" means without briefing acknowledgement, not unvalidated; inflated cost is a recorded risk (L720); lease pause on owner holds is a recorded decision (L750) that ends when the owner acts; question tokens hit only the asker's project (L335, L754).

**Verifier 1's fix.** Options: (A) cap open questions per task and round and allow one open access request per task, refuse the excess with a new cause in the fixed refusal list, and require non-negative cost in the interface schema; (B) have `jobs/claim-next` hand out rule checks and approvals before questions; (C) accept it as a Risks row, relying on cancel (L123) and queue lengths (L638). Recommend A plus B. Leave out the per-seat call rate and per-report cost ceiling (L720 already accepts self-reported cost), and leave L750 as decided.

**Verifier 2: partly.** True: no caps exist (settings L551, refusals L426), and job claim order is unspecified (L406; tasks have one, L422). Under FIFO, 200 non-blocking questions on T1 (L396; not hold-blocked, L116) make T2's submit check miss the 2-minute queue timeout twice (L304, L742) and hold on `check_error` (L305). Negative spend is undefined (L399). Overstated: L371 concerns briefing acknowledgement only; inflated cost is an accepted risk (L720); answer tokens hit only the asker's project (L335, L754); the access lease pause is chosen design (L750). Nothing blocks the Contract.

**Verifier 2's fix.** Decide in the Default limits row (L742). Options: (a) job claim order puts checks and approvals before questions, then oldest first; tokens and spend must be non-negative; cap open questions per task (5) and open access requests (1), each with a named refusal added to L426. (b) (a) plus a per-seat rate with `rate_limited`, exempting heartbeat, release (L371) and same-key repeats (L136). (c) Accept and list under Risks. Recommend (a). Drop the per-report ceiling: it changes the shipped budget rule (L268, L346), and L720 already accepts self-reported spend.

### 61. The owner has no specified way to cut off a seat: no revoke command, and a paused seat keeps reading and heartbeating

- **Lines:** 89, 113, 116, 371, 436, 632
- **Rated:** minor by one verifier, major by the other
- **Fix:** the owner has to decide
- **Found by:** security and privacy

Tokens are called revocable, but the owner command list has no revoke or rotate command and no event for one. Pausing a seat opens a `seat_paused` hold, and a hold blocks only claim, pass, submit, verdict and report-done. The paused seat can still heartbeat, which keeps its lease despite line 89, read the briefing and answers, ask questions, request access and report cost. Removing the seat is the only cut-off, and what happens to its held task, review, job, reserved claim or approved action is not stated. Token expiry is absent.

**Effect.** A stolen or misbehaving seat keeps its task and its read access after the owner pauses it. Removing it leaves a task, review or approved action with no defined holder, which tracks A and C resolve differently.

**Verifier 1: partly.** Quotes are exact, but the headline fails: remove a seat (L436, L635, `seat.removed` L174) is the cut-off and satisfies "revocable" (L632). Rotate and expiry are required nowhere; install is single-owner, self-hosted (L737). L89 is misread: pause is a soft stop, the lease clock runs, and `wait_seat` (L214) exists because a live paused seat keeps its task. L116 allows its other calls deliberately. What stands: nothing says what removal does to a held task, review, job, reservation or approved action; only lease and job timeouts (L78, L73, L304) apply implicitly.

**Verifier 1's fix.** Decide what Remove seat does to work in flight. Options: (A) it releases everything in the same command using existing events: task to Ready, review unassigned, job requeued, reservation lapsed; (B) refuse removal while the seat holds anything, mirroring credentials (L454); (C) state that lease and job timeouts handle it. Recommend A, plus one sentence that pause is a soft stop and removal revokes the token. Skip rotate, expiry and `seat_disabled` for version 1. Separately, L436 lacks "resume a seat" although `seat.resumed` exists (L174).

**Verifier 2: partly.** Confirmed for remove: L436 and L635 allow "remove a seat" and L174 has `seat.removed`, but no row covers a removed builder holding a Working task or an approved action (L106 needs "the previous builder"). I must guess between immediate `task.released` and lease expiry, and `tasks.holder` must replay (L591). L632 "revocable" has no command unless remove is it. Refuted for pause: L116 allows heartbeat and release under any hold, L89 only keeps the clock running, and L214 `wait_seat` presumes the seat keeps its task. Token expiry is a new requirement.

**Verifier 2's fix.** Reject `seat_disabled` for paused seats: it contradicts L116 and L214. Options for remove: (1) hard cut-off. The token dies at once and the same command writes `task.released` or `review.released`, requeues its jobs, lapses a reservation, and sends a Finishing task to Needs you with L109's choices. (2) Refuse removal while the seat holds anything, as L454 does for credentials. (3) Invalidate the token only and let leases expire. Recommend 1, with a lifecycle row. Say whether remove is L632's revocation or add rotate writing `seat.changed`.

### 62. The provider-terms check for driving subscription tools is scheduled 'before release' although milestone 2, the first provider and track G depend on it; the PRD also records the doubt and internal details in a public repository

- **Lines:** 3, 29, 448, 481, 483-484, 511, 669, 672, 728, 732-739, 759, 764
- **Rated:** major by one verifier, minor by the other
- **Fix:** the owner has to decide
- **Found by:** build plan, product and scope

Whether a provider allows its subscription tool to be driven by another program is left as a check 'before release', after milestone 5 is built, and it is not among the Open decisions, so it does not gate the contract. Milestone 2 already depends on it (runners use the machine's active login), the first-provider recommendation is Claude through that route, the Login half of Credentials is built on it, and logins are placed ahead of API tokens by default, so the doubtful path is the default. If the answer is no for the first provider, runners need API tokens from milestone 2, which needs token storage the plan puts in milestone 5, and login readers, two-account handling and reset display are wasted work. As written for a public repository the file also contains an undocumented internal cache key, terminal capture of usage screens, a reset redemption flow, an unexplained internal product name (Campus), an unresolved author handle (Neo), and an operator view across owners' workspaces.

**Effect.** A late 'no' reorders the milestones after four of them are built and discards most of track G; the owner carries an unexamined terms risk through the whole build. Publishing the text invites a provider to block the tool and tells readers the project knowingly planned around unchecked terms.

**Verifier 1: partly.** All quotes are exact. What stands: the terms check (L728) is "before release" and absent from Open decisions (L736-764), yet L448, L669 and track G (L685) rely on driving the tool. Overstated: API tokens are already first-class (L449, L574), so a "no" changes the runner's model call and drops login readers, not milestone order; the MCP route (L453, L739) is unaffected; L511 orders handoff, not seat choice. Publication half mostly falls: operator view is a non-goal (L29), Campus is an open decision (L759), the cache key is no secret (L481, L727). Repo visibility unverified.

**Verifier 1's fix.** Add an Open decisions row "Driving subscription tools", answered per provider before the contract, Claude and Codex first. Options: (a) logins only where terms are confirmed, API tokens otherwise; (b) API tokens only in version 1; (c) keep "before release". Recommend (a); if Claude is unclear, milestone 2 runners take an API key from the environment, with no need to bring token storage forward. Separately, minor: define or neutralise Campus and "operator", and replace Neo before pushing. I did not check any provider's terms.

**Verifier 2: partly.** The Contract is not blocked and I guess nothing: either answer leaves the same tables, events, hold and step (L113, L177, L215, L574); a "no" only drops login reader shapes (L667). The reordering claim is overstated: milestone 2 runners connect on their own and need no credential (L453, L669), so no early token storage. Real residue: the check sits in Risks at "before release" (L728), outside the list L732 gates the contract on, yet decides whether track G's login half is built (L672, L685). Publication items are editorial; none is a secret.

**Verifier 2's fix.** Options: (a) leave as is and accept late rework of track G; (b) add an Open decisions row for driving subscription tools, answered per provider before track G starts, Claude and Codex first; (c) API tokens only in version 1. Recommend (b). Do not move keychain storage into milestone 2: that contradicts L453 and L669. If Claude's answer is no, the milestone 2 runner uses an API key from its own environment. The owner decides separately whether to trim the cache key (L481), Campus (L483-484, L759, L764) and Neo (L3) before publishing.

### 63. Golden traces need exact ids and times with no test seam, are too few for what they must cover, and vary with rule configuration

- **Lines:** 134, 145-149, 278, 424, 628, 643, 648-649, 668-669, 684, 702
- **Rated:** minor by one verifier, major by the other
- **Fix:** the owner has to decide
- **Found by:** build plan

Golden traces are 'exact expected events and steps', written by hand before any code, and every track builds against them. Exact events hold uuids, `seq`, `at`, `effective_at` and step durations, but ids and the database clock are server-generated and the Contract lists no test clock or id seam; Tests 2 and 7 and criterion 702 also need time to pass a 60-minute lease. The six to eight sequences are not named and cannot cover 15 step kinds, 9 hooks and 12 hold reasons, yet they are track F's only verification. Expected events also differ with the rules enabled, which changes between milestones 2 and 3.

**Effect.** Each track invents its own clock fake and comparison rules, so traces pass in one track and fail in another. Rule-timing queries ship with paths no trace exercises.

**Verifier 1: partly.** Quotes are exact (L278, L628, L649, L669, L684). Overstated: lease length is a workspace setting (L424, L551, L742), so tests need no 60-minute wait; track A owns all timer logic (L687), B and C stub; traces have no length limit, so "cannot cover" is unproven; naming them is the Contract's job (L668). Stands: the Contract list (L657-668) gives no clock/id seam or comparison rule for "exact" (L134, L145-149), no rule configuration per trace (L669 vs L273, L278), and no coverage rule though traces are F's only check (L684).

**Verifier 1's fix.** Options: (a) add a settable clock and id source to the Contract list; (b) state that traces use symbolic ids and time offsets, compared on type, order, actor, subject, payload and relative `effective_at`. Recommend (b): it needs no production seam. Also state on the golden-traces item that each trace declares its enabled rules and lease length, and that together they cover every step kind, gated hook and hold reason F's queries read. Keep six to eight as a floor; a coverage rule beats a higher count.

**Verifier 2: partly.** Case 1: Add task, Complete contract. Under L669 the exact events are `task.created`, `task.contract_changed`, `task.ready`; with shipped rules on (L276-278, L341-342) add `check.*`, `job.*` and a `check` step, shifting every `seq`. I must guess which. Case 2: Claim, then Submit 61 minutes later. Expected `effective_at` and step times need controlled time, yet L134 and L628 fix the wall/database clock and L657-668 lists no seam. Overstated: lease length is a setting (L424), and trace count is not the defect; the missing coverage rule is (L649, L684).

**Verifier 2's fix.** Option A (recommended): traces use labelled ids, `seq` from a fresh workspace, and times as offsets. Add to the Contract list one clock source the server reads, settable in tests. Each trace states its settings and enabled rules, with rules-off traces as milestone 2's target. Replace the reviewer's arbitrary 12 to 14 with a coverage rule: each step kind, hook, hold reason and measurement row appears in a trace. Option B: no seam, short lease settings, and compare only order, types, payloads and relative times.

### 64. `review.assign` under claim-next: filter or refusal is undefined, so the provider-rule criterion and the wait\_review cause cannot be built

- **Lines:** 72, 209, 265, 278, 313, 403, 422, 701
- **Rated:** minor by one verifier, major by the other
- **Fix:** the owner has to decide
- **Found by:** interfaces

reviews/claim-next takes no review id and 'claims the next review this seat may take', which reads as a filter. But the hook table, the wait\_review step and a release criterion all describe the provider rule refusing a specific reviewer for a specific task. With server-side picking there is no named review to refuse, no refusal code for it, no defined order among waiting reviews, and no defined moment at which a wait\_review step acquires the rule as its cause. Whether `GET /v1/next` offers `review` to a seat the rule would exclude is also unstated.

**Effect.** Tracks A, B and C will implement different semantics; the release criterion on L701 has no observable outcome to test; rule-delay analytics (wait\_review naming the rule) have no defined trigger.

**Verifier 1: partly.** Quotes are exact, but most of the claim is answered. L403 ("may take"), L344 and L719 ("no eligible reviewer") already read as an eligibility filter. L426 has `blocked_by_rule` and `not_eligible`. L278 and L313 fix when the row is written and its subject (the seat), which is also the L209 trigger. Tracks cannot diverge: L657-668 put the interface schema, refusals and golden traces in the one-person contract. Still open: the exact answer to an excluded seat, whether `GET /v1/next` (L388) offers it `review`, review ordering (L422 says "task"), and no `review.assign` row in the hash table (L315-322).

**Verifier 1's fix.** Option 1 (recommended): keep the filter. claim-next skips reviews the rule excludes; when the rule alone leaves the seat nothing, answer `blocked_by_rule`, write one `applied` row per seat, task and round, and set the wait\_review cause then. `GET /v1/next` stops offering that review to that seat once the row exists. Order reviews by priority then age as on L422, and add a `review.assign` row to the hash table. Option 2: claim a review by id with an explicit refusal; this changes the interface and is not recommended.

**Verifier 2: confirmed.** Case: T1 (built on Claude, older) and T2 (built on Codex) await review; Claude reviewer R calls claim-next. L403 implies R gets T2 (filter); L265/L701 imply R is refused. I must guess the response, which tasks get the L278 row and the L209 cause, and whether L388 offers `review` to R. L265 is the only policy hook with a gate-style outcome. Overstated: a refusal code exists (`blocked_by_rule`, L426) and L422 gives an order. The L315-322 hash table also omits `review.assign`.

**Verifier 2's fix.** Reviewer's option 1 has a hole: if excluded seats are never offered, no compliant client calls claim-next, so no L278 row or L209 cause is ever written. Options: (A) claim-time: `/v1/next` offers on built-in eligibility; claim-next walks reviews in L422 order, writes one row per excluded seat and review, stamps the cause, returns the first allowed, else refuses `blocked_by_rule`; `/next` then stops offering it. (B) pure filter with a server-derived cause, rewording L209/L265/L278/L701. Recommend A. Reuse L422's order; "submit time" is new.

### 65. Restoring the daily backup rewinds the log: reported outward actions reappear as approved, `seq` and keys are reused, and credentials live outside the backup

- **Lines:** 39, 106-107, 134, 448-449, 598, 627, 636, 709
- **Rated:** major by one verifier, minor by the other
- **Fix:** the owner has to decide
- **Found by:** completeness pass

The only durability measure is a daily backup, although 'the log cannot be rebuilt'. A restore silently drops up to a day of events. An outward action reported done in that window is `approved` again, and its builder is told to carry it out a second time. `seq` values already read by feeds are reissued for different events, idempotency keys and seat tokens issued since disappear, and restored lease due times are a day stale. API tokens in the system keychain and login settings folders are outside the database backup. The release criterion checks only that a restored database replays, which any backup does.

**Effect.** After a restore the app can direct a second payment, send or deletion; readers keyed by `seq` hold events that no longer exist; credential rows point at nothing.

**Verifier 1: partly.** Quotes at L39, L134, L449, L636 and L709 are exact. No section, risk or open decision covers restore; "backup" appears only at L636 and L709. The core stands: on rewound state, L105-106 with L347 re-approve and re-direct an action already carried out. Overstated: stale leases already expire through timers-first (L86-87); lost idempotency keys match lost effects (L136); v1 names no external `seq` consumer (L181); Verify all and sign in again exist (L473, L501); L709 does test backup consistency, though not loss handling.

**Verifier 1's fix.** Options: (a) Continuous archiving: shrinks the loss window, but waits on the stack and hosting decisions (L736-737) and never reaches zero. (b) A restore procedure: record a restore event, hold every task with an outward action not Done until the owner confirms each one, and run Verify all. Leases need nothing extra. (c) Accept the loss: state the window at L636 and add a Risks row. Recommend (b) plus stating the window, with (a) optional once the stack is chosen, and L709 reworded to test the procedure.

**Verifier 2: partly.** The hazard is real. Backup at 02:00 with an action approved; the builder pays and reports done (L77); restore. The action is `approved` again (L561), the stale lease expires (L86, L78) and the builder is offered it again (L106). The PRD is silent (L636, L709). The Contract is not blocked: nothing forces a guess, and later additions are additive (L138, L637). Overstated: no `seq` reader exists outside the database (L181); lost keys re-execute correctly (L581); logins are unbacked by design (L455); Verify catches dead references (L501).

**Verifier 2's fix.** Options: (A) accept a 24-hour loss window and add a Risks row. (B) A restore runbook from existing commands: keep seats paused, owner waives approved actions already carried out (L107), Verify all (L501), resume; L709 tests it. (C) Point-in-time recovery once PostgreSQL is confirmed (L736). Recommend B, plus C later. Reject the reviewer's workspace hold and restore event: holds are per task or project (L562) and events need a command (L131), so both are new requirements. "Expire all leases" already happens (L86).

### 66. Server downtime is charged to every lease and check timer: after a restart, sleep or crash all due timers fire retroactively

- **Lines:** 86-87, 89, 135, 149, 286, 304-305, 424, 573, 629, 737-738
- **Rated:** major by one verifier, minor by the other
- **Fix:** the owner has to decide
- **Found by:** completeness pass

Timers are absolute due times, applied retroactively at the due time, and the lease clock pauses only for owner and project holds. The recommended installation is the owner's own machine, which sleeps, restarts and is upgraded. While the server is down no seat can heartbeat and no orchestrator can return a result. On start, every lease whose due time passed expires, pending transitions are cancelled, each waiting check misses twice and becomes `error`, and steps charge the outage to seats and rules. Nothing defines startup behaviour, or what a runner does when the server is unreachable.

**Effect.** One sleep or restart longer than the remaining lease returns every claimed task to Ready, discards in-flight work and fills Needs you with check errors; timing data blames seats and rules for the outage.

**Verifier 1: partly.** All five quotes are exact (L86, L89, L286, L304, L737). Nothing defines server start or outage: Risks covers only an orchestrator outage (L718), and L309/L573/L638 only report a late sweep. So leases (L424) do expire retroactively. Two impacts are overstated. Check errors with the orchestrator offline give one workspace item and requeue on their own (L305-307), though that races the first sweep. Work is not discarded, since it lives outside the app (L28, L745). Outage time lands mostly in `wait_ready`, with at most one lease length in `build`.

**Verifier 1's fix.** Add an Open decisions row "Server outage or sleep". Options: (a) accept retroactive expiry and state it under Timers and Risks; (b) on start, measure the gap since the last `sweep_runs` row, write a restart event and shift every lease and check due time by it; (c) record the gap as a workspace-level hold, reusing the paused-lease field (L556), with its own waiting step. Recommend (c), because (b) alone still books the outage to `build` and check queue time. Also state that clients retry with the same key (L136) while the server is unreachable.

**Verifier 2: partly.** Mechanism confirmed: absolute timers (L86, L135, L629), only owner or project holds pause leases (L89), no server-outage text, and L737 recommends the owner's machine. But behaviour is determined (L86, L702), so I would not guess the state table. Impact overstated: L305-307 give one workspace item and re-queue errored checks; work lives outside the app (L28); a dead seat already costs the same (L59). Real gaps: outage time lands unmarked in `build` and rule-attributed `wait_owner` (L226), and after restart the order of first orchestrator poll (L307) versus first sweep is undefined.

**Verifier 2's fix.** Add an open decision. (a) Accept: say so under Timers and Risks, and keep `sweep_runs` for the workspace's life so reports can subtract gaps. (b) Shift lease and check due times by the gap; trigger on any sweep gap, not process start (sleep does not restart), and note steps still span the outage. (c) contradicts L562 (holds are task or project) and can push `effective_at` backwards. Recommend (a) for version 1, plus one sentence that due timers apply before checks are re-queued on the orchestrator's first poll.

### 67. The sweep and timers-first are defined per task; timers that belong to no task have no trigger, effective time or owner

- **Lines:** 86, 135, 306, 498, 515, 517, 521, 541, 573, 629, 687
- **Rated:** minor by one verifier, major by the other
- **Fix:** the owner has to decide
- **Found by:** completeness pass

The sweep and the timers-first rule are defined per task: the sweep 'triggers the same logic for tasks nobody has touched' and records 'tasks touched'. Several timers belong to no task: the 90-second orchestrator-offline detector, a credential's reset time that must close `credential_limit` holds, the 10-minute usage read, timeouts of jobs that are not checks, and idempotency key expiry. Nothing says what fires them, with what effective time, or in which transaction. Track A 'owns all timer logic', yet the credential and usage timers sit in track G and the offline detector in no track.

**Effect.** Tracks A, C and G each assume another fires these timers. Limit holds never lift and the offline item never opens unless someone adds a second scheduler outside the transition function.

**Verifier 1: partly.** Quotes are exact, but most examples are misread. Every job names a task (L47, L123, L418), so job timeouts are task timers. Key expiry (L627) is retention with no state effect. Usage reads are not events (L502) and sit with G's readers (L685). Credential limits are compared lazily (L515-517), and the `credential_limit` hold is on a task (L521). L687 gives A all timer logic. What stands: the workspace-level offline detector (L306, L631) fits neither the per-task wording (L86, L135) nor L573, and L86's list omits the hold release.

**Verifier 1's fix.** (a) Add a timer list to the Contract milestone: each timer, its scope (task or workspace), due-time source and event. Say the sweep also applies workspace-scoped timers (the offline detector) and the `credential_limit` hold release through the transition function, owned by track A, and reword `sweep_runs` "tasks touched" to match. (b) Keep the sweep per task; give the offline detector to track B and the hold release to track G as separate schedulers. Recommend (a), without a new timer table. Leave usage reads and key expiry as background housekeeping.

**Verifier 2: partly.** Real for two timers. L86 and L135 define timers-first per task and name only lease expiry and check timeouts; L573 counts "tasks touched". The workspace-level offline item (L306) and the `credential_limit` lift (L521, L541; `holds` at L562 has no due time) get no trigger or effective time. Case: the orchestrator stops; sweep-only firing (L629) lands 60-120 s later, breaking L698. Overstated: usage reads are not events (L502; track G, L685), key expiry is retention (L627), limited-until needs no firing (L515-517), and L687 already gives A ownership.

**Verifier 2's fix.** Options: (a) the contract lists every timer with scope, due-time source and event, all fired by the sweep through the transition function with effective\_at = due time; (b) a second scheduler with a named owner. Recommend (a), narrowed: add the credential\_limit lift (task-scoped; due = earliest limited-until, recomputed when credentials change) and orchestrator-offline (workspace-scoped); exclude usage reads and key expiry. Also decide non-check job timeout values, and whether the 90-second promise survives a 30-second sweep (shorten the threshold or the sweep, or say 120).
