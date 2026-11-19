# Adversarial review of the PRD

This is the record of an adversarial review of [the PRD](../../PRD.md) as it was first committed, kept so that each finding can be accepted or rejected by the owner.

> **Review snapshot, 2026-11-18.** The review was run by AI agents (Claude) and has not been checked line by line by a person. Its findings are claims. Nothing in the PRD was changed because of them: the PRD in this repository is the owner's exported text with seven lines of formatting repaired. Line numbers below refer to `docs/PRD.md` as committed together with this record.

## How the review was done

1. **Ten reviewers**, each with one angle of attack, read the whole PRD: a consistency inventory across sections, the state machine, the event log, steps and timing, rule checks, credentials and handoff, security and privacy, the build plan, the agent and owner interfaces, and product scope. Each returned at most 14 findings.
2. **Merging.** The 140 findings were clustered into 76 distinct ones.
3. **Verification.** Every finding rated blocker or major went to two verifiers: one told to refute it from the rest of the PRD, one acting as the engineer who must write the contract milestone from it. Minor findings went to the first only. A finding was dropped if any verifier refuted it.
4. **A completeness pass** looked for what the ten had missed, and its findings were verified the same way. 13 survived.

What that produced: **89 findings**, of which 8 were rated blocker by at least one verifier, 59 major, and 22 minor. 74 of them need a decision from the owner; for the rest at least one verifier thought the PRD already contains the answer and only the text needs aligning.

## Limits of this review

- **No finding was refuted outright.** Verifiers marked 84 of the 89 findings as only partly right and corrected them, and their corrections are printed under each finding, but none was thrown out. That may mean the findings are sound, or that the verifiers were too lenient. Finders and verifiers were the same model.
- **Findings were capped.** The ten reviewers reported having 66 more findings than the cap let them return. Those were not examined.
- **Read each finding with its verifier notes.** Where a verifier says "partly", the claim paragraph above it overstates something, and the verifier note says what.
- **Hand checks.** The agent that assembled this record compared the eight blocker-rated findings (numbers 1 to 8) with the PRD text and confirmed that the lines they cite say what the findings report. The other 81 were not checked a second time.
- **Not reviewed:** the prototype, the mock-up, the lifecycle diagram, and the credentials document the PRD refers to. None of them was available.

## Findings rated blocker by at least one verifier

### 1. Finishing has owner-driven exits that exist only in prose: rework, waive-to-Done and revoke have no lifecycle row, command or event

- **Lines:** 61-80, 105-109, 121, 169, 436, 561, 611, 644
- **Rated:** blocker by both verifiers
- **Fix:** the owner has to decide
- **Found by:** consistency inventory, state machine, event log, interfaces

Exits from Finishing are named in prose but absent from the lifecycle table, the owner command list and the event registry. (1) A stopped action offers 'send the task back for rework', but no row goes Finishing to Working, the owner list has approve, stop and waive but no send-back, contract edits are barred in Finishing, and action states have no path from `stopped` back to `contracted` or `requested`. Unstated: target state, whether the round rises and counts toward the limit, which criteria reopen, whether the review and `task.before_done` run again, what becomes of the already written `review.passed` and the review criterion's passed state, whether other approved or done actions are revoked, and whether the previous builder gets a pushed lease or the task goes to Ready. (2) Waiving the last open action must reach Done, but waive is an owner command and the only row to Done is the builder's. (3) An owner overturn puts an action in `revoked`, which is neither done nor waived, so the task can never be Done. (4) Finding no. 0 also notes that a holderless Finishing task cannot be re-acquired (Claim is Ready to Working only; the fresh lease is granted only at approval). Cancel is the only exit.

**Effect.** The state and command table, Test 3, the event registry and the golden traces cannot be written for Finishing. Tracks A, C and E would each invent the rework path; replay of tasks.state, actions.state and criteria state has no event to follow; a revoked action strands its task; a task could re-enter review with an outward action already carried out; a builder that dies after approval strands a task with no recovery but cancel.

**Verifier 1: partly.** All quotes are exact. Nothing in Open decisions (L746, L751), Risks or Tests settles it. Stands: (1) L109 offers rework but no Finishing-to-Working row (L61-80), no owner command (L436), edits barred (L121); (4) L78 leaves Finishing holderless, Claim is Ready-only (L67), L106 grants a lease only at approval. Overstated: waive has a command (L436) and event (L169), and L107/L704 already make Done follow it; only the row is missing. (3) is inference: L611 never says overturn yields `revoked`; L123 uses revoke for Cancel only. Still undefined.

**Verifier 1's fix.** Decide: (a) add owner "Return for rework", Finishing to Working, round plus one, refused once any action is reported done, undone approvals revoked, review and `task.before_done` rerun; or (b) drop the choice, leaving waive and cancel. Recommend (a). Also decide holderless Finishing: recommend a Needs you item after expiry, with the previous builder re-offered `action` via /next. Define overturning an approval: recommend it behaves as stopped. Separately, add the "Waive action" row (Owner; Finishing, or Done when last; `action.waived`, `task.done`), which L107 already determines.

**Verifier 2: confirmed.** Confirmed; I cannot write Finishing rows without guessing. Stopped action, owner picks rework (L109): no row in L61-80, no command in L436, L121 bars edits; target state, round, reopened criteria, lease, events and action state are unstated. Waive-last: L107 says Done but only L77 (Builder) writes `task.done`. Overturn (L611): PRD never says whether an approved action becomes `stopped` or `revoked` (L561, L169); if revoked, L77 never fires. Approved-lease expiry (L78): no re-acquire path (L67, L106). Approve, stop and waive also lack rows.

**Verifier 2's fix.** Decide four rows. Rework: (a) owner Return for rework, Finishing to Working, naming criteria, round+1 (reviews are one row per round, L559), refused once any action is done; non-done actions are re-requested after the next pass; (b) drop the choice. Recommend (a), but not held by the round limit and not `action.revoked` with state `contracted` (replay cannot derive it). Waive row: Owner, to Done when last (L107). Overturn of an approval = Stop; `revoked` only on cancel. Expired approved lease: Needs you item, re-offer `action` to the previous builder.

### 2. Finishing without a holder is a dead end, and an approved irreversible action can be repeated or become unreportable after a lost lease

- **Lines:** 39, 67, 76-78, 87-88, 106-107, 109, 123, 390, 401
- **Rated:** blocker by both verifiers
- **Fix:** the owner has to decide
- **Found by:** state machine, security and privacy, interfaces

When the builder's lease expires or it releases in Finishing, the task stays in Finishing with no holder. No command lets any seat take a Finishing task: Claim is from Ready only, claim-next serves Ready tasks only, and the lease is granted once, on approval, to the previous builder; no row re-grants it. No hold, Needs you item or timer follows. The same happens when that seat is paused, removed or never polls. Nothing marks an action as started or records whether the approved action was already carried out, so a takeover by any unspecified path can repeat it. If the builder already performed the action and its lease expired before the report, the report is refused with `lease_expired` and nobody else can report it; the owner's only exits are waive (a false record: the action did happen) or cancel, and cancel 'revokes' an approval for something that may already have happened.

**Effect.** A task with an approved payment or publish sits in Finishing forever with no signal to the owner, or a second attempt repeats a payment, send or delete that already happened while the log shows one (or shows a done action as waived). Track A cannot write the Finishing rows of the state table because who may resume a holderless Finishing task is unspecified.

**Verifier 1: partly.** Core stands; all seven quotes are exact. L78 leaves Finishing holderless; claim is Ready-only (L67, L390); the lease is granted once, on approval (L106); L87 refuses a late report. No hold reason (L113), Needs you kind (L610), risk or open decision covers it, and "stopped" (L109) means an approval stop. Owner exits are only waive (L107, L436) or cancel (L123). Two parts fall: repetition by takeover cannot occur as written, since no takeover path exists, and L716 already disclaims acts outside the app; the state table is determinate (all refused), so Track A can write it.

**Verifier 1's fix.** Decide what follows a lost or released lease in Finishing. Options: (a) open a hold with a new reason plus a Needs you item offering: offer again to the previous builder, mark the action done, waive, or cancel; (b) let another eligible builder claim Finishing tasks. Recommend (a): never reassign automatically, because whether the action went out is unknown. Add an owner command "mark action done". Decide separately whether to add a builder-sent `action.started` marker; it is self-reported (L716) but tells the owner the action may have happened.

**Verifier 2: confirmed.** Case: verdict passes, task enters Finishing (L76); approval gives the builder a lease (L106); builder pays; lease due time passes; `POST .../actions/{aid}/done` is refused `lease_expired` (L87, L401). The task is "Finishing without a holder" (L78). Claim is Ready-only (L67, L390), nothing re-grants, no hold reason fits (L113), and no step kind fits (L208, L211) though L189 requires one open. Owner exits are waive or cancel (L107, L123), both recording a performed action as not done. I must guess the step, the `GET /v1/next` behaviour and the resume path.

**Verifier 2's fix.** Options: (a) losing the post-approval lease opens an owner hold and Needs you item (re-offer to the same builder, mark done, waive, cancel), plus an `action.started` call, event and state so "possibly performed" is recorded; (b) let another builder claim a Finishing task; (c) accept a late report from the task's builder seat after expiry. Recommend (a), reject (b). Correction to the reviewer: do not reuse `action_stopped`; its "send back for rework" choice (L109) is wrong once something may have gone out. Use a new hold reason, which also makes the step `wait_owner`.

### 3. `action.requested` is a gated hook but not a transition: Finishing before approval (and holderless Finishing) has no step kind, no pending-transition model, no gate/approval order and no error behaviour

- **Lines:** 67, 76, 78, 105-109, 189, 204-205, 208-211, 213, 247-248, 264, 276, 284, 305, 347, 362, 388, 390, 563
- **Rated:** major by one verifier, blocker by the other
- **Fix:** the owner has to decide
- **Found by:** consistency inventory, state machine, event log, steps and timing, rule checks

The gating mechanism assumes a requested command that stays 'in its earlier state while pending'. At `action.requested` the task has already moved to Finishing in the command that wrote `review.passed`; the server, not a seat, initiates the check, once per action. The lifecycle table puts the hook on the reviewer's command while prose says the task is already in Finishing. There is no command key or requester for `pending_transitions`, 'at most one pending transition' conflicts with several actions, and a model gate (custom rule 'before anything goes out') has nothing to refuse. A model policy (the orchestrator's approval) and custom model gates share the hook with no stated order (gates before approval, or both queued together), and `on_fail`, `route` and `check_error` are defined for gates only, so an `error`, timeout or offline orchestrator on the approval job is undefined. No step kind covers the interval: `check` needs a pending transition (this one already committed), `finish` and `wait_builder` need an approved action, `wait_owner` needs a hold; so 'exactly one step open' fails. The same is true of 'Finishing without a holder' after lease expiry (`wait_ready` is only for Ready), which is also a dead end. With several approved actions, `finish` and `wait_builder` take 'the action' as subject but nothing says which. Whether actions are approved in sequence or together is unstated. no. 42 also notes the missing Finishing-to-Working rework row.

**Effect.** The step-partition invariant (Test 2) fails or is patched ad hoc for every task with an outward action; tracks A and B cannot agree on the gating interface for the one hook that guards irreversible actions, or on whether approval is a pending transition on the reviewer's verdict (which ties up the reviewer's lease). An irreversible action can be approved and carried out while a 'before anything goes out' rule is still running, or after it fails. An approved action whose builder dies is stuck with no open-step definition.

**Verifier 1: partly.** All quotes are exact. Core stands: L76/L105/L109 commit Finishing before approval, so L284 and L204 cannot apply; no step kind covers undecided approval or holderless Finishing (L78, L205, L390), and the lifecycle table lacks approve, stop, waive and rework rows (L109, L436). Overstated: timeouts and offline handling cover any model check (L249, L304-307); L357 plus L277 and L264 fail closed, so no approval while a gate runs; L157 and L313 already give empty `command_id` and action-subject checks. L661 and L666 defer step events to the contract.

**Verifier 1's fix.** Options: (a) keep the task In review as a pending transition until every action is decided (contradicts L105, L109, ties up the reviewer lease); (b) make approval an action-level move outside `pending_transitions`, with a waiting step (new kind, or `check` widened to subject the action). Recommend (b): gates and policy per action, approved only when every gate passes; a policy `error` opens an `owner_approval` hold. Add a holderless-Finishing step and pickup (previous builder via `GET /v1/next` `action`, then Needs you), and lifecycle rows for approve, stop, waive, rework.

**Verifier 2: confirmed.** Case: verdict K1 passes on a task with actions A1, A2 and a custom "before anything goes out" gate. L76/L105 commit Finishing and `action.requested` inside K1, so L276/L284/L563 have no pending command, key, requester or earlier state. L204-213 offer no step until approval, nor for holderless Finishing (L78, L390). Gate-versus-approval order and a failed approval job (L247-248, L305, L347) must be guessed. Overstated: L264 does define a failed gate, and L306-307 plausibly cover an offline orchestrator.

**Verifier 2's fix.** Recommend (b): action checks are server-started, keyed per action, outside `pending_transitions`, with empty `command_id`; one waiting step until every action is decided, then the builder's lease; per action, gates before the approval job; add action-level rows and a holderless-Finishing step with previous-builder pickup. Correction to the reviewer: an offline orchestrator must keep L306-307 (one workspace item, automatic requeue), not a per-task `owner_approval` hold; only an `error` after the retry passes to the owner. Alternative (a): per-action pending transitions with requester app, which breaks L284.

### 4. `wait_builder` ends on 'a call' that is not an event, so its closing event cannot be named and `rework`/`finish` cannot be replayed

- **Lines:** 45, 94, 106, 179, 211-212, 570, 596, 661
- **Rated:** major by one verifier, blocker by the other
- **Fix:** the owner has to decide
- **Found by:** event log, steps and timing, build plan

Steps are opened and closed by events, each step row stores its opening and closing event, and replay must rebuild every `task_steps` row from the log. `wait_builder` is open until the builder 'makes a call'. The builder's natural first calls after a failed review or an approved action are `GET /v1/next` (how it learns of rework), a briefing read or a heartbeat, and none is an event. The lifecycle table has no command or event for a builder picking the task back up. Either a non-event closes a step (replay fails), or the step closes on the first event-writing call (an optional `criterion.started`, `criterion.passed`, `task.submitted` or `action.reported_done`), by which time the rework or the action is finished, so `rework` and the post-approval `finish` step have near-zero length and working time is recorded as waiting.

**Effect.** The contract's step table (L661, which event opens and closes which step) cannot be written for `wait_builder`, `rework` and `finish`. Tracks A and F will pick different boundaries, replay cannot reproduce them, and working time after a failed review or an approval is classed as waiting, corrupting 'where does task time go'.

**Verifier 1: confirmed.** Quotes at L45, L94, L179, L211, L570 and L596 are exact and read correctly in context. Nothing settles it: acknowledgement is tied to claim or a changed hash (L371-372), and a failed review changes no briefing part (L369); Open decisions (L734-764) and Risks are silent; L661 defers to the contract. "A call" includes heartbeats (L87). One overstatement: shipped clients always announce (L193), so `criterion.started` bounds `rework` for them. Zero length is certain only for post-approval `finish` (L77, L208) and non-announcing clients.

**Verifier 1's fix.** Add an Open decisions row. Options: (a) require Acknowledge briefing after every fresh lease (L94, L106); `task.briefing_acknowledged` closes `wait_builder`; extend the L68 row to Finishing and reword L211 to name that event. (b) Add a resume command and event. (c) Drop `wait_builder` and open `rework`/`finish` at `review.failed`/`action.approved`, counting idle time as working. Recommend (a): it reuses an existing event, needs no new call, keeps waiting separate from working, and gives post-approval `finish` a real length. Downgraded to major: replay is safe under an event-only reading; the damage is misclassified time.

**Verifier 2: confirmed.** Case: `review.failed` (L74) opens `wait_builder`; the builder then calls `GET /v1/next` (L94), heartbeat, start/pass, submit. L211 closes the step on "a call", but L179 makes reads and heartbeats non-events, while L45, L570, L596 and L661 need a closing event. No re-acknowledgement is required, since the hash is unchanged (L369, L372). I must guess the boundary. After approval the only work call is `action.reported_done` (L77), so `finish` is zero-length. Rework is understated, not zero, when clients announce (L193).

**Verifier 2's fix.** Options: (a) require Acknowledge briefing after every fresh lease; `task.briefing_acknowledged` closes `wait_builder`. Needs L68 extended to Finishing, L211 reworded, and L371-372 changed to per-lease acknowledgement. (b) A new resume command; an event written on `GET /v1/next` contradicts L179 and L384. (c) Drop `wait_builder`, losing the builder pickup delay. Recommend (a). One reviewer rationale is wrong: the briefing (L368) holds no review notes and its hash does not change, so the acknowledgement marks pickup only.

### 5. An `error` check result has incompatible outcomes (refuse, hold, auto re-queue), no pending-transition state, and at `task.before_claim` contradicts the lapsed reservation

- **Lines:** 89-90, 117, 277, 286, 289, 295-298, 305-307, 313, 563
- **Rated:** major by one verifier, blocker by the other
- **Fix:** the owner has to decide
- **Found by:** consistency inventory, state machine, rule checks

When a blocking check ends in `error`, step 6 refuses the transition, L305 holds the task with `check_error`, and L307 re-queues errored checks automatically. Re-queuing only makes sense if the transition is still pending, but `pending_transitions` has no state for that. At `task.before_claim` L297 says an error or timeout lapses the reservation and returns the task to Ready (claimable again), while L305 says the task is held; both cannot apply. If held, a task-level hold blocks every seat over a check whose subject is one seat, and 'run it again', the automatic re-queue and 'override it once' act on a claim whose reservation is gone and whose seat may hold other work, so a later pass has nothing to complete. If not held, with the orchestrator offline every polling builder reserves the task in turn for two timeouts each. Unstated: whether errors count toward the '3 different seats' hold, whether `check_error` pauses the lease clock, what closes the hold, whether a provisional reservation counts as holding under the one-task rule, and how a seat withdraws one (it has no lease to release).

**Effect.** Tracks A and B cannot agree what an errored check does to the transition, the lease or the hold; timeout tests have no single expected trace. An orchestrator outage either turns every claim attempt into a held Ready task that nothing clears, churns builders through reservations, or completes claims for seats that moved on; re-queued checks spend tokens on claims that cannot complete.

**Verifier 1: partly.** Quotes are exact, but most conflicts dissolve. Refuse plus hold already coexist (L260); L740 settles fail-closed. L59: a hold leaves state alone, so L297 and L305 both apply at before\_claim, and L423 stops other seats churning. L289 sends an override to the next request with the same inputs (L318: the seat); L326 reuses a re-run pass. L226+L213+L89 make check\_error pause the lease. L298 says "fails", not errors. Still unstated: what closes check\_error, whether a re-run pass completes the refused transition (L288 vs L307), provisional-claim holding and withdrawal (L90, L285).

**Verifier 1's fix.** Decide before the contract. (1) Recommended: keep L277 and L305 as written; add that check\_error closes when the check is re-run to a non-error result, overridden, or its rule is turned off, and that a re-run pass completes the refused transition under L289's conditions, otherwise it is reused on the next request. (2) The holder always resends per L288. Also state that L305 applies at task.before\_claim alongside L297 (or exempt it), that a provisional reservation counts as holding, and that release withdraws it.

**Verifier 2: confirmed.** Case: Submit meets a model gate, orchestrator offline, two queue timeouts give `error` (L304). L277 refuses; L305 holds; L307 re-queues; L289 completes a refused transition only on override. If the re-run passes I must guess whether the refused transition completes or the builder resends (blocked by the hold, L116); L563 has no state for it. At claim, L297 (lapse, Ready) and L305 (held) disagree, and a re-queued check has no reservation to complete. Lease pause for `check_error` is only implied (L213, L226). L698 tests this path.

**Verifier 2's fix.** General: (1, recommended) `error` leaves the transition pending under a `check_error` owner hold that pauses the lease; step 6 waits; re-run, override or rule-off resolves it and closes the hold. (2) Refuse, no hold, no re-queue: contradicts L305, L307, L698. Claim exception, recommend no. 12: reservation lapses, task-level `check_error` hold opens, no re-queue, errors excluded from the 3-seat count, hold closes when the orchestrator returns; override applies to that seat's next claim (L289). The no-hold variant churns reservations. Also: a reservation counts as holding; map each hold reason to lease pause and Blocked.

### 6. Holds and contract edits have no defined effect on a pending transition; step 6 does not re-check model-check inputs, so an edited contract can enter Ready unchecked

- **Lines:** 66, 116-117, 121, 123, 191, 204, 226, 277, 284-289, 317, 326
- **Rated:** major by one verifier, blocker by the other
- **Fix:** the owner has to decide
- **Found by:** state machine, steps and timing, rule checks

Step 6 re-validates only the state and app checkers. (1) While Complete contract waits on a `task.before_ready` model check, the owner may still edit the Backlog contract (only a holder's commands are refused with `pending`, and there is no holder); the state is still Backlog, so a pass on the old text moves edited, unchecked text into Ready. (2) An edit in Ready, Working or In review returns the task to Backlog and releases the holder but does not cancel the pending transition (unlike Cancel and lease expiry); its `check` step is closed by `wait_contract`, but the pending row and queued jobs live on, 'at most one pending transition' then blocks the owner's next Complete contract until stale checks end, and the orchestrator spends tokens on a discarded result. (3) A hold opened while a submit, verdict or claim is pending: holds block those commands, but step 6 does not mention holds, so the move (or a provisional claim's lease) completes on a held task; rule 3 says only 'the work step' closes on a hold, so whether `check` (or `wait_ready`, `wait_review`, `idea`) is interrupted is unclear. The reverse is also open: Complete contract is allowed under a hold, so would `check` open under an open hold? The check's finished-minus-queued also overlaps the `wait_owner` step, charging the same minutes to the rule and the owner.

**Effect.** A gate is bypassed by editing during the check (which the Add task form makes easy), breaking Goal 4. After a mid-check edit Complete contract can be refused or blocked until old checks time out (up to both timeouts, about 14 minutes at defaults) and rule time and tokens are charged for withdrawn work. Tracks A and B will differ on whether a pending transition completes, waits or is cancelled under a hold; golden traces cannot be written and hold-up time is double counted between the rule and the owner.

**Verifier 1: partly.** Quotes are exact. Stands: nothing says what an owner edit does to a pending transition (L121; L285 covers only the holder; Cancel L123 and expiry L286 do), nor whether step 6 (L277) completes under a hold or re-checks input hashes (L289, L326 cover only overrides and reuse). Weakened: L191's first sentence with L189 and L213 already makes a hold close `check`; step 6 state re-validation and contract-version hashes (L318-321) refuse stale submits and verdicts; only the owner can edit and can override anyway (L328); steps still partition (L194).

**Verifier 1's fix.** Add an Open decisions row. Recommended: (a) any contract edit, in any state, cancels the pending transition and withdraws its checks and jobs, as Cancel and lease expiry do; step 6 also compares input hashes and refuses on a mismatch. (b) A hold opened during a check leaves the transition pending; the result is applied when the last hold lifts; `wait_owner` owns the step and rule hold-up is taken from `check` steps. Alternatives for (b): cancel the transition like lease expiry, or complete under the hold.

**Verifier 2: confirmed.** Three cases I cannot write without guessing. (a) Complete contract pending, owner edits in Backlog (L121; L66 has no Backlog row; L285 binds only a holder): L277 rechecks state and app checkers, not the L317 hash, so the old pass admits new text. (b) Submit pending, owner edits: L66/L121 name no cancel, unlike L123/L286, and L284 then collides with the next Complete contract. (c) Hold during `check`: L116, L191, L204, L213 give no precedence, and `contract_incomplete`/`check_error` re-runs (L260, L305) always start under a hold. The L226 overlap is minor.

**Verifier 2's fix.** Two decisions. Edit during pending: (1) any contract edit, release or state change cancels the pending transition and withdraws its checks and jobs, as L123/L286 do, plus a Backlog edit row; recommended. (2) Refuse edits with `pending`. (3) Re-queue on new inputs. Hold during pending: (a) park the result until no hold is open, `wait_owner` beating `check`; recommended, but a provisional claim should lapse, and `contract_incomplete`/`check_error` must close on re-request or parking deadlocks. (b) Cancel. (c) Complete under the hold. The reviewer's new refusal cause is unnecessary under (1).

### 7. Credentials and handoff assume 'a seat the app runs', which nothing defines: no launcher, no limit signal, no credential delivery, and it contradicts 'the server holds no provider code'

- **Lines:** 36, 386-407, 426, 430, 448-455, 466, 513-521, 528, 555, 574, 613, 632, 665, 667, 669, 685, 687, 737-738
- **Rated:** major by one verifier, blocker by the other
- **Fix:** the owner has to decide
- **Found by:** consistency inventory, credentials, security and privacy, build plan, product and scope

Credentials distinguishes 'a seat the app runs' from one that 'connects on its own', and says the app runs the provider's tool, calls the provider's API, and switches credentials mid-task. Everywhere else seats are external clients that sign in and pull work, and an open decision assumes 'The server holds no provider code'. Nothing specifies: which component launches or supervises a seat's run (no command, screen, agent call or track; 'connect a seat' only creates a token; milestone 2 runners 'use whatever login is active'); which component detects that 'a run hits a provider limit', extracts the reset time, writes `credential.limit_reached` or restarts the work (the agent interface has no call to report a limit, no `GET /v1/next` kind announcing a switch, no response field naming the credential, no refusal for it; claim returns only 'the task, a lease and the briefing'); how a separate runner obtains an API token 'never returned by any interface'; where the app keeps a seat token it must present ('stored hashed, shown once'); how the provider-review rule learns which providers worked for self-connected seats; which model runs after a cross-provider handoff (a credential has no model, and provider, model and rank are the seat's defining fields). `seats` has no field for the distinction; the roster says every connect 'picks its credential' while self-connected seats need none; the day-one MCP path has no credential, so limits, handoff and `wait_limit` never apply to it. If the server is remote, the helper 'must run on the owner's machine' with no protocol or authentication defined. No track owns executing work on the eight non-first integrations. Track G names only C as a dependency though handoff needs A, B and D. The interface schema is a milestone-1 contract item, so it cannot be written complete.

**Effect.** The contract cannot fix the agent interface schema, the handoff events or track boundaries. Tracks C and D freeze an interface with no limit or switch signal; track D builds a pull-only runner in milestone 2 that milestone 5 must replace; tracks C, D and G build incompatible things (who launches a runner, where its token lives, whether the server makes model calls); track G cannot build handoff and stalls on A, B and D. Acceptance line 540 has no mechanism. Minimum-rank and provider-review checks become unreliable. A remote helper would be an unauthenticated component executing tools with the owner's logins.

**Verifier 1: partly.** Quotes are exact. Core stands: L448/453/528 say the app runs seats, yet no command (L436, L527), agent call (L386-407), track or open decision names who launches a run, detects a limit, or triggers `credential.limit_reached` under one-writer (L131); L528 contradicts L738. Refuted parts: nullable `credential` (L555) marks the distinction; self-connected seats never hand off, so the seat's provider holds; `on_hold` (L426) and L113 cover the hold; milestone order (L529, L669) covers G's dependencies and staged runners; MCP exclusion is by design (L453).

**Verifier 1's fix.** Owner decides; add a row to Open decisions. (a) Recommended, matches L448/453/528: the machine helper supervises app-run seats, spawns the runner with the credential injected, detects limits and reports them through one server command; add launch/stop commands, a per-run credential and model record, fix L613, narrow L738, limit remote installs to API tokens. (b) Runners stay external: add a limit-report call and a `/v1/next` kind; same-provider handoff only. (c) Smallest: version 1 ships inventory, readers and order; defer automatic handoff, dropping L540-541.

**Verifier 2: confirmed.** Case: seat S with credential C1 claims T (L390); a Claude limit hits mid-build. I must name the command that emits `credential.limit_reached`/`credential.switched` (L131, L660) and the events opening/closing `wait_limit` (L215, L661). None exists in L61-80, L388-407, L426, L436 or L527. Nothing launches "a seat the app runs" (L453, L669); L455 blocks token delivery; post-handoff model and rank are undefined (L423, L520, L555-556); L738 conflicts with L448, L466, L528. Overstated: nullable `credential` (L555) already marks managed seats; G's dependency is stub-able (L687).

**Verifier 2's fix.** Owner decides. (a) Helper launches and supervises managed seats and detects limits; server writes the events as app actor. Add launch/stop commands, a per-claim credential/provider/model record, a lease-clock rule for `credential_limit`; narrow L738. (b) External runners report limits: contradicts L453 and L455, and L760 if restricted to one provider. (c) Cut automatic handoff (L513-521, L540-541, `wait_limit`, `credential_limit`) from version 1; keep inventory, readers, order. Recommend (a), the only option L448, L453, L455 and L528 already describe; choose (c) if scope must shrink. Do not adopt (b) as written.

### 8. 'The previous builder gets a fresh lease' collides with one task per seat; who holds a task In review, and whether a provisional claim counts as holding, is undefined

- **Lines:** 88, 90, 94, 106, 121, 211, 295-296, 423, 556
- **Rated:** major by one verifier, blocker by the other
- **Fix:** the owner has to decide
- **Found by:** consistency inventory, state machine, steps and timing, interfaces

The builder's lease covers only Working and Finishing, so during In review (and Finishing before approval) the builder holds nothing and is eligible to claim another task; the reference runner loops straight back to claim. A failed review or an approval then 'gives the previous builder a fresh lease' on the first task: either the seat holds two (breaking the one-task rule and claim eligibility), or the lease cannot be granted and no fallback is given; if granted to a busy seat, `wait_builder` runs for the full lease (60 minutes by default) before the task returns to Ready, on every failed review. The other reading, that the builder remains holder through review, is hinted at by 'releases its holder' on a contract edit In review (ambiguous between builder and reviewer), contradicts the lease scope and idles every builder through `wait_review` and `review`. `tasks` carries both a holder seat and a builder seat with no rule for either. Likewise a seat with a provisional claim has no lease, so nothing stops it sending claim-next again and reserving several tasks.

**Effect.** Tracks A and D build different holder semantics; claim eligibility in the state table cannot be written and Test 3 cannot say what a builder's claim returns while its task is In review or what happens when a review fails while the builder holds another task. Either the one-task invariant breaks, or rework leases silently expire on busy builders and every failed review bounces to Ready after an hour of dead `wait_builder` time, or builder throughput halves. A seat can reserve the whole Ready queue through provisional claims.

**Verifier 1: partly.** All eight quotes are exact. The core stands: L90 and L423 (one holding, "holds nothing else") collide with L94 and L106 (fresh lease to the "previous builder"); nothing stops that builder claiming meanwhile, and L749/L751 do not reconcile them. L295-296 leave reservation-versus-holding open. Overstated: holder In review is inferable as empty (L78 "Finishing without a holder", "previous" at L94/L106, separate columns at L556); rework has a fallback (L94 expiry to Ready); one person writes the contract (L653), so tracks would not diverge.

**Verifier 1's fix.** Add an Open decisions row. Options: (a) builder stays reserved, not claim-eligible, until its task leaves In review and Finishing; (b) builder is freed at submit and holder is empty In review; on fail or approval the lease is granted only if that seat holds nothing, otherwise rework goes to Ready and an approved action waits in Finishing without a holder, offered through GET /v1/next once the seat is idle; (c) allow two holdings. Recommend (b). Also state that a provisional claim counts as holding, and that "releases its holder" In review means the review lease.

**Verifier 2: confirmed.** Case: S1 submits T1 (L71); its lease covers only Working and Finishing (L88). S1 sends claim-next: does "holds nothing else" (L423) refuse it? Unstated. If T2 is granted and T1's review fails, L94 gives S1 a second lease, breaking L90. I must guess `tasks.holder` In review (L556), a replayed column (L591), and the event and step when the builder is busy (L74, L205, L211). Provisional claims (L295-296) have the same gap. The reviewer's "Finishing without a holder" fallback dead-ends: Claim is Ready-only (L67, L355).

**Verifier 2's fix.** Options: (a) builder stays holder, not claim-eligible, until Done, Ready or Cancelled; simple, idles builders through review. (b) Builder freed at submit; holder empty In review and in Finishing before approval; builder seat kept. On fail or approval, grant the lease only if that seat is idle; otherwise rework goes to Ready (`wait_ready`, a named event), and an action waits for that seat's next idle `GET /v1/next` or opens Needs you. (c) Two holdings; contradicts L90 and L749. Recommend (b). Also count a provisional claim as holding, and state whom L121 releases In review.

## Every finding, by rating

The 8 findings above are printed in full. The others are in two further files.

### Rated blocker by at least one verifier

- **1.** Finishing has owner-driven exits that exist only in prose: rework, waive-to-Done and revoke have no lifecycle row, command or event (lines 61-80, 105-109, 121, 169, 436, 561, 611, 644)
- **2.** Finishing without a holder is a dead end, and an approved irreversible action can be repeated or become unreportable after a lost lease (lines 39, 67, 76-78, 87-88, 106-107, 109, 123, 390, 401)
- **3.** `action.requested` is a gated hook but not a transition: Finishing before approval (and holderless Finishing) has no step kind, no pending-transition model, no gate/approval order and no error behaviour (lines 67, 76, 78, 105-109, 189, 204-205, 208-211, 213, 247-248, 264, 276, 284, 305, 347, 362, 388, 390, 563)
- **4.** `wait_builder` ends on 'a call' that is not an event, so its closing event cannot be named and `rework`/`finish` cannot be replayed (lines 45, 94, 106, 179, 211-212, 570, 596, 661)
- **5.** An `error` check result has incompatible outcomes (refuse, hold, auto re-queue), no pending-transition state, and at `task.before_claim` contradicts the lapsed reservation (lines 89-90, 117, 277, 286, 289, 295-298, 305-307, 313, 563)
- **6.** Holds and contract edits have no defined effect on a pending transition; step 6 does not re-check model-check inputs, so an edited contract can enter Ready unchecked (lines 66, 116-117, 121, 123, 191, 204, 226, 277, 284-289, 317, 326)
- **7.** Credentials and handoff assume 'a seat the app runs', which nothing defines: no launcher, no limit signal, no credential delivery, and it contradicts 'the server holds no provider code' (lines 36, 386-407, 426, 430, 448-455, 466, 513-521, 528, 555, 574, 613, 632, 665, 667, 669, 685, 687, 737-738)
- **8.** 'The previous builder gets a fresh lease' collides with one task per seat; who holds a task In review, and whether a provisional claim counts as holding, is undefined (lines 88, 90, 94, 106, 121, 211, 295-296, 423, 556)

### Rated major by at least one verifier, blocker by none

Printed in full in [findings-major.md](findings-major.md).

- **9.** A failed `task.before_done` gate changes state instead of refusing: no lifecycle row, a non-existent failed criterion, undefined events and verdict, and an override that can never take effect (lines 74-75, 94, 98, 136, 263, 277, 288-289, 313, 320, 327, 557, 559, 592, 609, 699)
- **10.** Timers-first covers only commands on the task; other writers can put events after an unapplied due timer (lines 86-87, 133, 135, 268, 272, 277, 286, 309, 629)
- **11.** Agents the app runs share a machine and OS user with the database, keychain, settings folders and other seats' tokens; no isolation is specified (lines 236, 354, 448, 528, 669, 716)
- **12.** Owner interface authentication is undefined: sign-in identity, first-owner bootstrap, cross-site protection, bind address and transport (lines 436, 552, 606, 708, 737)
- **13.** 'Each needs an answer before the contract' is not satisfied by assumed recommendations, and four recommendations are not answers (lines 528, 547, 687, 726, 732, 736-739, 747, 754, 759-760)
- **14.** Hold reasons are never classified or given per-reason rules: lease pause, Blocked lane, step kind, stacking and closing are undefined, and seat-scoped holds outlive the seat's lease (lines 46, 55, 78, 89, 113-116, 191, 213-215, 229, 260, 298, 327, 423-424, 432, 516, 521, 541, 559, 750)
- **15.** The owner command list, declared part of the contract, lacks commands its own events, screens and Needs you choices require (lines 98, 164, 174, 202, 305, 368, 374, 406-407, 422, 435-436, 555-556, 608, 613-614, 619, 669)
- **16.** Most Needs you items and several holds have no reason code, no defined choices and no command that ends them; one offered choice has no command behind it (lines 61-80, 98, 109, 113, 121, 298, 305, 327, 349, 398, 436, 571, 610, 719)
- **17.** The role file is required in every briefing from milestone 2 but is never defined, stored, versioned or editable; briefing is owned by a milestone-3 track (lines 25, 49, 68, 358, 368-374, 380, 392, 436, 554-555, 619, 666, 669, 680)
- **18.** The Tracks table leaves milestone 4 work, shared machinery and several commands unowned; the milestone-2 briefing belongs to a milestone-3 track (lines 306, 374, 436, 636, 653, 666, 669-671, 679-685, 719)
- **19.** An approved action can go out while the app blocks or erases its report (lines 39, 105-109, 116, 123)
- **20.** claim-next cannot skip a task: a seat refused at `task.before_claim` (or one that released a task) is handed the same task forever; cached results and the three-seat hold misbehave (lines 261, 293, 297-298, 300, 318, 326, 390, 402, 422-423)
- **21.** Escalation sets a rank nobody defines, and can leave a task in Ready with no seat able to claim it (lines 74, 96, 345, 423, 610, 719)
- **22.** Batched multi-task changes contradict same-transaction, one `at` per command and a single idempotent outcome (lines 132-134, 136, 213, 268, 307, 625, 756)
- **23.** A refused command's outcome is not final: overrides and automatic re-runs complete it later (lines 136, 157, 288-289, 296-297, 307, 388, 425, 563)
- **24.** Holder, builder and 'ever held' are never defined; a reviewer is both 'never a holder' and a caller of Holder-only calls, and Acknowledge briefing is allowed only in Working (lines 68, 88, 94, 106, 121, 246, 332, 344, 354, 371-373, 391-392, 396, 399, 403-406, 415-416, 556, 591, 644, 669)
- **25.** Content deletion has no defined scope against replay, and content is copied into tables, backups and logs it does not reach (lines 137, 139, 559, 563, 566, 568, 572, 592, 594, 627, 633, 635-636, 638, 757)
- **26.** Overrides cannot take effect at three of the five gated hooks (lines 109, 263, 289, 296, 313, 328, 699)
- **27.** Default check timeouts and 90-second offline detection misfire with one serial orchestrator; 'polled' is undefined and jobs have no heartbeat (lines 225, 304-307, 406-407, 555, 629, 631, 698, 742)
- **28.** The model re-run limit disagrees with its default, has no hold reason, and locks the owner out of a Backlog task's contract check (lines 113, 121, 154, 317, 324, 326-327, 608, 610, 742)
- **29.** The provider-review rule cannot hold after handoff: it is checked only at review claim, no table stores providers that worked, and cross-provider handoff also breaks the privacy line (lines 72, 265, 344, 449, 507, 516, 519-520, 555-559, 633, 701, 719, 739, 760)
- **30.** Three different conditions for the limit hold, and 'earliest reset time' has no defined set (lines 215, 516-517, 521, 541)
- **31.** 'Provider limit' and 'the reset time the provider gave' are undefined where a provider gives none (lines 475, 488, 491-492, 503, 515, 521, 610)
- **32.** Model, effort and strength rank after a cross-provider handoff are undefined; content goes to a provider the roster does not show and escalation is bypassed (lines 36, 96, 448-449, 507, 520, 555, 574, 633, 760)
- **33.** Claim eligibility ignores credential state; behaviour before the reset and on sign-out or removal in use is missing (lines 423, 454, 473, 516-517, 521)
- **34.** Limits during a review or an orchestrator job have no specified behaviour (lines 88, 304-306, 519, 521, 562)
- **35.** The definition of done skips Credentials (Goal 8), the MCP server (Goal 7) and most of milestone 4; two criteria fail by construction and several Credentials criteria cannot be shown (lines 19-20, 98, 278, 306, 343, 345-346, 432, 481, 531-543, 629, 631, 685, 691-710)
- **36.** The planner role, contract-draft job and `draft` step have no trigger, milestone, track, test or goal, and a planner result becomes the contract with no owner sign-off (lines 26, 47, 65, 82, 104, 202-203, 334, 362, 406-407, 417, 430, 436, 555, 632, 663, 669-672, 693)
- **37.** Authority text in the briefing has no defined author or write path: project brief, role file and 'the record' (lines 25, 174, 343, 368-369, 380, 436, 554, 753)
- **38.** The Roles table grants reads that no listed call serves: reviewers cannot get evidence or the handoff note, builders cannot get review notes or action details (lines 368, 388-407, 413-418, 556, 559, 708)
- **39.** The shipped rule set cannot complete a task with the recommended single provider; the minimum first-run setup is never stated and the promised unsatisfiable-rule detector is unspecified (lines 19, 90, 209, 342, 344, 606, 610, 669, 693, 701, 719, 732, 738-739)
- **40.** `GET /v1/next` kinds do not cover what the lifecycle makes seats wait for, and its delivery semantics are undefined (lines 116, 288-289, 296, 388, 398, 425)
- **41.** Blocking questions and non-check jobs have no specified waiting state, timeout or offline behaviour (lines 113, 168, 217, 249, 306, 343, 396-397, 611)
- **42.** Three waiting states have no Needs you item and no owner command that ends them (lines 67, 78, 96, 106, 209, 354, 388, 423, 436, 610, 613)
- **43.** A builder is sent to four artefacts that are not in the export, and some definitions exist only there (lines 37, 57, 317, 440, 483-484, 556, 602, 608, 612, 667, 759)
- **44.** Six Risk responses promise behaviour the body does not specify or contradicts (lines 276, 305, 368, 609-610, 615, 716-720, 727, 763)
- **45.** The work has no path to the reviewer: the work reference has no writer or reader, and evidence must be an https link (lines 28, 102, 324, 356, 395, 411, 415-416, 556, 558, 608, 669, 722, 745)
- **46.** Budgets have no unit, the task cap cannot be set, and spend is undefined for subscription seats and lost on several paths (lines 37, 87, 304, 317, 346, 349, 399, 405, 511, 553, 556, 608, 720, 754)
- **47.** Fixed interface lists are incomplete: missing refusal codes and hold reasons, `rounds_exceeded` unreachable, `/v1/next` has no kind for a command outcome, and 'always accepted' contradicts the pending rule (lines 87, 98, 113, 116, 285, 298, 327, 356, 371, 388, 425-426, 644-645)
- **48.** The round limit says only 'holds the task' (lines 98, 154, 263, 426, 610, 742, 751)
- **49.** Lifecycle 'Events written' is incomplete, yet release requires 'exactly' those events (lines 61-80, 98, 121, 123, 278, 593, 649, 694)
- **50.** Four replay columns have no event that carries them (lines 137, 164, 171, 173, 278, 339-347, 399, 407, 556, 566, 589, 594-595, 598, 754)
- **51.** Events written when a pending transition completes have no defined actor, and break 'one `at` per command' (lines 65, 134, 148, 152, 157, 276, 317, 332, 608)
- **52.** build, finish and rework overlap, so 'the step the state calls for' is not determined (lines 191, 193, 207-208, 212, 262-263)
- **53.** 'How long did a rule hold tasks up' gives two formulas for the same minutes and double counts (lines 209, 225-226, 305, 307, 566-567)
- **54.** Per-criterion attribution: nothing says what `criterion.passed` does to the open build step (lines 70, 190, 193, 207, 224)
- **55.** A model-checked `warn` rule (and two policy hooks) contradict Goal 4 / Test 4 'no transition without a recorded result' (lines 16-17, 228, 247, 276-278, 308, 362, 615, 645, 718)
- **56.** Machine helper and system keychain conflict with 'a server the owner controls' (lines 449, 466, 528, 636, 657-668, 737)
- **57.** Track G's stated dependencies and placement contradict what handoff changes (lines 13, 344, 529, 653, 669, 672, 685, 687)
- **58.** The reader part of the contract and several Credentials criteria depend on reader outputs, accounts and limits that do not exist or are unverified (lines 481-484, 490, 535, 537, 540-541, 667, 685, 725, 727, 732, 759)
- **59.** The idempotency store would hold seat tokens and API tokens in plaintext (lines 136, 455, 538, 572, 613, 627, 632)
- **60.** One seat can stall the whole workspace or a project's budget: no limits on questions, access requests or cost reports (lines 89, 225, 304-305, 343, 371, 396-399, 742, 754)
- **61.** The owner has no specified way to cut off a seat: no revoke command, and a paused seat keeps reading and heartbeating (lines 89, 113, 116, 371, 436, 632)
- **62.** The provider-terms check for driving subscription tools is scheduled 'before release' although milestone 2, the first provider and track G depend on it; the PRD also records the doubt and internal details in a public repository (lines 3, 29, 448, 481, 483-484, 511, 669, 672, 728, 732-739, 759, 764)
- **63.** Golden traces need exact ids and times with no test seam, are too few for what they must cover, and vary with rule configuration (lines 134, 145-149, 278, 424, 628, 643, 648-649, 668-669, 684, 702)
- **64.** `review.assign` under claim-next: filter or refusal is undefined, so the provider-rule criterion and the wait\_review cause cannot be built (lines 72, 209, 265, 278, 313, 403, 422, 701)
- **65.** Restoring the daily backup rewinds the log: reported outward actions reappear as approved, `seq` and keys are reused, and credentials live outside the backup (lines 39, 106-107, 134, 448-449, 598, 627, 636, 709)
- **66.** Server downtime is charged to every lease and check timer: after a restart, sleep or crash all due timers fire retroactively (lines 86-87, 89, 135, 149, 286, 304-305, 424, 573, 629, 737-738)
- **67.** The sweep and timers-first are defined per task; timers that belong to no task have no trigger, effective time or owner (lines 86, 135, 306, 498, 515, 517, 521, 541, 573, 629, 687)

### Rated minor

Printed in full in [findings-minor.md](findings-minor.md).

- **68.** Policy checks: `review.failed` is missing from the row rule and three hooks from the hashed-inputs table; replay of `rule_checks` has no events for policy rows (lines 170, 228, 274, 278, 313-322, 345, 583, 594)
- **69.** Data model omits fields and tables the prose relies on (lines 134, 217, 313, 317, 319, 371, 398, 400, 519, 556, 559, 568, 608)
- **70.** Add task has no rule for Imaginarium or Backlog, no draft save, and no way to start the planner (lines 63, 65-66, 82, 121, 202, 407, 436, 608)
- **71.** Hold may be opened from 'Any' state, including Done and Cancelled; project-level holds are unspecified (lines 55, 79, 189, 191, 562)
- **72.** Review leases cannot pause under a hold: the reviews table has no paused-time field (lines 88-89, 116, 214, 556, 559)
- **73.** Reports start at promotion, but a hold opened in Imaginarium makes a step straddle that start (lines 55, 79, 191, 195, 201, 223, 230)
- **74.** Who receives a gate failure is contradictory, and routing to the orchestrator has no mechanism (lines 47, 248, 264, 297, 337-347, 362)
- **75.** Two statements about recorded results and applicability contradict the gating algorithm (lines 16, 276, 278, 368, 615, 717)
- **76.** 'Quoted material' is undefined as a mechanism and omits evidence, review notes and other seat-written text (lines 320, 334, 398, 402, 411, 558, 721-722)
- **77.** The speed targets cannot be measured where the plan says, have no baseline or load driver, and their release criterion cannot fail (lines 584, 630, 669, 710, 724)
- **78.** Overturning an orchestrator's answer has no defined effect on the task or the seat that acted on it (lines 168, 343, 388, 436, 560, 611)
- **79.** Criterion identity across a contract edit is undefined, so 'unchanged' criteria, replay of criterion state and per-criterion timing have no basis (lines 121, 164-165, 224, 318-320, 556-557, 592)
- **80.** Shipped rules have no creation or upgrade path that the log can replay (lines 171, 250, 252, 339-347, 564-565, 589, 594, 637, 658, 670-671)
- **81.** Check timeouts live in both the rule record and workspace settings, and changing a limit mid-flight is undefined (lines 98, 249, 273, 327, 424, 436, 551, 615, 619, 742)
- **82.** Removing or editing a seat that holds work has no specified effect (lines 89-90, 96, 174, 332, 344, 436, 454, 555, 613)
- **83.** Monotonic time is asserted, not enforced: two clock sources are named, the type has no zone, and nothing clamps a clock that steps back (lines 87, 134-135, 148-149, 424, 628)
- **84.** No order or re-evaluation is defined when several timers are due on one task (lines 86, 89, 135, 286, 304-305, 742)
- **85.** Data model and event record cannot hold what handoff says is recorded (lines 155, 177, 436, 519, 526-527, 556, 559, 568, 570, 574-575)
- **86.** Who writes an outward action's description is contradictory, so an approval is bound to nothing concrete (lines 104, 321, 334, 401, 561, 726)
- **87.** Milestone 3 (Rule checks) cannot be demonstrated without Needs you, holds and triggers that arrive in milestone 4 (lines 260, 298, 305-306, 327, 343-347, 645, 670-671, 680)
- **88.** 'Commits together or changes nothing' contradicts refusals that must persist timer events, failed check rows, holds and a saved contract (lines 86, 132, 136, 260, 278, 288, 298, 608, 625, 648)
- **89.** Nothing says what happens to passed criteria, evidence and the release reason when a different builder takes the task (lines 59, 78, 94, 96, 121, 208, 402, 557, 592)
