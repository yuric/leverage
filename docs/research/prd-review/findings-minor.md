# PRD review: findings rated minor

These are the findings from the [adversarial review of the PRD](README.md) that were rated minor; the method and its limits are described there.

## Findings

### 68. Policy checks: `review.failed` is missing from the row rule and three hooks from the hashed-inputs table; replay of `rule_checks` has no events for policy rows

- **Lines:** 170, 228, 274, 278, 313-322, 345, 583, 594
- **Rated:** minor (one verifier)
- **Fix:** the owner has to decide
- **Found by:** consistency inventory

Row-writing is specified for policy rules at four hooks but not at `review.failed`, which has a shipped rule. The hashed-inputs table lists six hooks and omits `review.assign`, `review.failed` and `cost.reported`, although their rows fall under a uniqueness constraint that includes the input hash; a reviewer refused twice in one round collides. Only gate results are said to produce a `check.finished` event; policy `applied` rows and scope-decided `not_applicable` rows 'write a row', yet the replay must rebuild `rule_checks` results from the log alone.

**Effect.** The replay test fails on any log containing a policy check, the escalation rule's 'how often did it apply' cannot be answered, and tracks A and B disagree on which rows exist.

**Verifier: partly.** All four quotes are exact. Stands: L278 names four policy hooks and omits `review.failed` (shipped rule L345); L315-322 omits three hooks and L313 gives `review.failed` no subject; only gate results get `check.finished` (L278), yet L594 replays every `rule_checks` result and L170 is the only event carrying one. Overstated: gate `not_applicable` is already a gate result (L277, L280); a repeat refusal is a new attempt on the same keyed check (L313), not a collision. Nothing in Open decisions or Risks settles the rest.

**Verifier's fix.** Three choices. (1) Event: every `rule_checks` row writes `check.finished` (recommended; L139 and L594 imply it), or drop policy rows from the replay at L594. (2) `review.failed` row: always write `applied` with the effect (recommended, at most one per round), or only on escalation. (3) Hashed inputs: `review.assign` = seat plus providers that worked (L520); `review.failed` = the review, its round and failed criteria; `cost.reported` = the report id. Add the review to L313's subjects, and say a repeated identical policy check adds an attempt to the same row.

### 69. Data model omits fields and tables the prose relies on

- **Lines:** 134, 217, 313, 317, 319, 371, 398, 400, 519, 556, 559, 568, 608
- **Rated:** minor (one verifier)
- **Fix:** the owner has to decide
- **Found by:** consistency inventory

The contract's first item is migrations for every table under Data model, but several stored things have no home: the submit handoff note (hashed for before\_submit); the contract's 'details' and audience fields (hashed for before\_ready, on the form, target of a shipped rule); cost reports, said to keep 'their own rows' and to be a rule-check subject; the briefing hash each holder or reviewer last acknowledged; the credential that did the work on each claim and job; the `seq` counter row; and the text of an access request. Events cannot carry any of the text because payloads hold no content.

**Effect.** Migrations written from the table as listed force a schema change during milestones 2 to 5, and tracks B and C invent incompatible storage for the handoff note and acknowledged hash.

**Verifier: partly.** Quotes are exact. Stands: three text items have no listed home though L137 says content lives in its own tables: handoff note (L319, L400), details/audience (L317, L608), access text (L398; hold reasons are a fixed list, L113). Refuted: cost figures and credential ids are numbers/ids payloads may carry (L137; L595 replays `projects.spent`; L525 enumerates Credentials' tables); L549 says "Key fields"; L598 already puts everything else outside replay; one person writes migrations before tracks start (L653-658), so B and C cannot diverge.

**Verifier's fix.** The PRD does not determine where the text lives; the reviewer's own fix offers alternatives. Option 1: name homes in Data model: details/audience on `tasks`, handoff note on `reviews` (one row per round) or `tasks`, access text on `inbox_items`, acknowledged briefing hash on `tasks` and `reviews`. Option 2: state that the table lists key fields only and the milestone-1 migrations fix the rest. Recommend option 1 for those four only. Leave cost reports, credential ids and the `seq` counter to event payloads and the contract; no `cost_reports` table.

### 70. Add task has no rule for Imaginarium or Backlog, no draft save, and no way to start the planner

- **Lines:** 63, 65-66, 82, 121, 202, 407, 436, 608
- **Rated:** minor (one verifier)
- **Fix:** the owner has to decide
- **Found by:** state machine

Nothing decides whether Add task lands in Imaginarium or Backlog. The form always follows with Complete contract, which is valid only from Backlog. The two commands are separate transactions: if the second is refused, left pending or lost, the task exists, and a repeated save creates a duplicate unless both keys derive from the form. The table has no row for editing a contract in Backlog or Imaginarium, where edits are 'free'. No command queues the planner's draft job, so the `draft` step and the planner's Complete contract have no entry point.

**Effect.** The state table is incomplete for the first two states. The owner cannot save an idea or a draft through the only form, and the planner role ships with nothing that gives it work.

**Verifier: partly.** Quotes are exact. Refuted: the form's target is implied Backlog (L82, L65, L195, L608); a refused or pending second command is covered (L260, L276, L284, L608); a lost one by idempotency keys (L136, L581, L627). "Free" edits cover Backlog only, not Imaginarium (L121). Stands: nothing creates a task in Imaginarium, so Promote and `idea` are unreachable (L26, L63-64, L201); L121's Backlog edit has no table row, which Test 3 (L644) would refuse; no command, hook or milestone queues a contract-draft job (L47, L202, L406-407, L436, L669-672).

**Verifier's fix.** Two decisions. (1) Imaginarium entry: Add task takes a target (idea or Backlog) and the form gets Save as idea; or Imaginarium, Promote and `idea` are marked later. Recommend the target, since the board already has the lane. (2) Planner: add an owner Request draft command from Backlog writing `job.queued`; or defer the planner role, `draft` step and draft job. Recommend deferring, since no milestone builds it. Either way add the row L121 already determines: Edit contract, Backlog to Backlog, Owner, no hook, `task.contract_changed`. No idempotency change needed.

### 71. Hold may be opened from 'Any' state, including Done and Cancelled; project-level holds are unspecified

- **Lines:** 55, 79, 189, 191, 562
- **Rated:** minor (one verifier)
- **Fix:** the owner has to decide
- **Found by:** state machine

Hold and resume lists its From set as Any, which includes Done and Cancelled. A hold on a finished task has no current step to interrupt; opening a waiting step breaks step rule 1 and the lifetime sum, and the Blocked lane would show Done tasks. Project pause and budget pause open holds across a project without saying whether Done, Cancelled and Imaginarium tasks are included, or whether there is one project-level hold row or one per task, while each live task still needs its own `wait_owner` step and `hold.opened` event.

**Effect.** The step partition test on random command sequences fails on a hold after Done. Tracks A and F disagree on how a project pause appears in steps and in the replayed set of open holds.

**Verifier: partly.** All five quotes (L55, L79, L189, L191, L562) are exact and read correctly. Nothing refutes the defect: L80 writes "Any except Done" where an exception is meant, test 3 (L644) takes the table literally, and Open decisions and Risks (L714-764) are silent. What does not stand: the fix is only half mechanical. L189, L191 and L123 already rule out a hold on Done or Cancelled, but the project case (L89, L213, L423, L562, L594) is unsettled. Impact is overstated: tracks build from one contract (L649, L661).

**Verifier's fix.** Determined part, apply regardless: L79 From cell becomes "Any except Done and Cancelled". Decision to add to Open decisions: (A) one project-level hold row and event, plus a `wait_owner` step per live task; this breaks L185 (step and opening event in one transaction) once L133 batches it. (B) `project.paused` once, then per-task `hold.opened` (reason `project_paused`, `cause_id` the pause) for each task not Done or Cancelled, per batch. Recommend B. Also state whether Imaginarium tasks and tasks added during a pause are held, and that L55's Blocked lane excludes Done and Cancelled.

### 72. Review leases cannot pause under a hold: the reviews table has no paused-time field

- **Lines:** 88-89, 116, 214, 556, 559
- **Rated:** minor (one verifier)
- **Fix:** the owner has to decide
- **Found by:** steps and timing

A hold on the owner or project 'pauses the lease clock', and a reviewer has its own lease. `tasks` stores 'lease time left while paused', but `reviews` stores only 'lease due time'. A hold blocks the verdict, so a project paused during a review either expires the reviewer's lease (the review goes back to `wait_review` although the reviewer did nothing wrong) or needs a field that does not exist. `wait_seat` is likewise defined only for 'the seat holding the task': a paused reviewer seat has no step kind, and it is not said whether the task gets a `seat_paused` hold.

**Effect.** The migration is missing a column the lease rule requires. Reviews are lost during any long owner hold, which inflates `wait_review` and the review criterion's time.

**Verifier: partly.** Quotes at L89, L214, L556 and L559 are exact. Nothing settles whether a review lease pauses: L89 and L750 say "the lease clock" about a claimed task, L48 and L88 make a review a lease too, and only `tasks` (L556) has the paused field. That gap stands. The impact is overstated: hold time is `wait_owner`, not `wait_review` (L191, L213), and heartbeat still works under a hold (L116), so a live reviewer keeps its lease. The paused reviewer seat (L113, L214) is unspecified, not contradicted.

**Verifier's fix.** Not mechanical: L556/L559 fit a builder-only pause, L48/L88-89 fit both. Option A (recommended, same reasoning as L750 about keeping the seat's context): owner and project holds pause review leases too; add "lease time left while paused" to `reviews` and say so at L89. Option B: review leases never pause; say so at L89, and a reviewer must heartbeat through a hold. Separately decide whether a paused reviewer seat opens `wait_seat` with a `seat_paused` hold, or the step stays `review` until the lease expires.

### 73. Reports start at promotion, but a hold opened in Imaginarium makes a step straddle that start

- **Lines:** 55, 79, 191, 195, 201, 223, 230
- **Rated:** minor (one verifier)
- **Fix:** the owner has to decide
- **Found by:** steps and timing

Holds are allowed in any state, and the Blocked lane shows held tasks 'whatever its state', so a project pause while a task is in Imaginarium closes `idea` and opens `wait_owner`. If the owner promotes the task while the hold is open, no step boundary is written at `task.promoted` (a new step opens only 'when the last hold lifts'). The `wait_owner` step then spans the report start in rule 7. Step durations summed by kind no longer equal `task.done` minus the rule-7 start, and 'time in Imaginarium shown apart' is not the sum of `idea` steps.

**Effect.** Track F's 'where does task time go' and 'how long in all' queries disagree for such tasks, and owner-wait totals include time before the task counted as started.

**Verifier: partly.** All four quotes are exact. The scenario is reachable: holds apply in any state (L79, L55), promote is an owner command that holds do not block (L116), and nothing writes a step boundary at `task.promoted` under an open hold (L191). No Open decision or Risk covers it. Overstated: the PRD never says step sums equal L230's total. The tested invariants (L194, L643, L695) still hold. What stands is that L195 and L229 leave a straddling `wait_owner` step undefined. L191 ("The work step closes") is ambiguous for `idea`.

**Verifier's fix.** Settle it in the step table (L661). Option A: a hold never interrupts `idea`; the hold is still recorded and shown in Blocked, and promoting under an open hold closes `idea` and opens `wait_owner` at `task.promoted`. Option B: `task.promoted` always closes the open step and reopens the same kind. Option C: leave steps alone and have report queries clip every step at the rule-7 start. Recommend A: Imaginarium time stays equal to the `idea` steps, and L191's wording already leans that way.

### 74. Who receives a gate failure is contradictory, and routing to the orchestrator has no mechanism

- **Lines:** 47, 248, 264, 297, 337-347, 362
- **Rated:** minor (one verifier)
- **Fix:** the owner has to decide
- **Found by:** rule checks

For a custom rule at `task.before_claim` the task is not yet claimed, so line 362 sends the reason to the owner while line 297 sends it to the seat. At `action.requested` the task is claimed, so line 362 sends it to the builder while the Hooks table opens a Needs you item for the owner. The `route` value 'the orchestrator' has no job kind to carry it (jobs are a check, a question, an approval, a draft). The shipped-rules table gives no `route` for either shipped gate, and a planner-drafted contract that fails `task.before_ready` has no stated recipient.

**Effect.** Tracks B, C and E deliver the same failure to different recipients, and the Rules settings would offer a route that does nothing.

**Verifier: partly.** All five quotes are exact. Refuted: the claim case is settled by L293-298 plus L426 (`blocked_by_rule` with the reason goes to the calling seat); a planner draft is the Complete contract command (L407), so the planner gets the command outcome and the hold carries the reason (L260); Settings, Rules (L615) does not list `route`. Standing: `route` (L248) has no value-to-mechanism mapping, no default and no shipped value (L341-342); "the orchestrator" has no carrier (L47, L406); L362 says builder where L264 and L109 open a Needs you item.

**Verifier's fix.** Option A (recommended): remove `route` from the rule record (L248) and reword L362 to defer to the Hooks table (L258-264), which already states each hook's failure outcome; L277 "routes each failure" then means that table. No new mechanism is needed. Option B: keep `route`, state its default and the value for both shipped gates, define what delivery to the orchestrator is (a new job kind at L47 and L406), and say whether `route` overrides the per-hook outcomes. A is smaller and matches L662, where the contract owns the hook list.

### 75. Two statements about recorded results and applicability contradict the gating algorithm

- **Lines:** 16, 276, 278, 368, 615, 717
- **Rated:** minor (one verifier)
- **Fix:** the PRD already settles it elsewhere; the text needs aligning
- **Found by:** rule checks

Goal 4 says every rule bound to a moment has a recorded result before the transition completes, but policies at `review.assign` and `cost.reported` write a row only when they change the outcome, so 'how often the rule ran' in Settings cannot be computed from rows for them. The Risks table answers the model-check bottleneck with 'Judge applicability once per task', while the algorithm has no applicability job or stored per-task applicability: a checker-decided rule is re-judged inside every check, and the briefing can only ever mark it 'may apply'.

**Effect.** Track F cannot produce the per-rule run counts for two shipped rules, and track B may build an applicability cache that the gating section rules out.

**Verifier: partly.** All five quotes are exact. L717 vs L276 stands: no applicability job, L326 reuses only passed/failed, L368 only "may apply". Goal 4 (L16) is loose rather than wrong: L40 defines a transition as a state change, which excludes Claim review (L72) and cost reports, and test 4 (L645) already limits the invariant to gate rules. The L615 claim is weak: L43 defines a rule check as one run and L228 counts rows, so track F can compute it; the count just omits no-effect evaluations (L278).

**Verifier's fix.** Three wording edits, each making a summary line agree with the detailed section. Goal 4 takes test 4's "gate rule" scope and points to step 7 for policies. The Risks response swaps the stale applicability sentence for what L274 says about fixed scopes. Settings, Rules states the count as recorded rule checks, per L43 and L228. Do not adopt the reviewer's "count from events" definition: nothing in the PRD says it, so it would be a new requirement. Not edited: L278 never says whether the `review.failed` policy writes a row.

Text changes the verifiers proposed (not applied):

Verifier 1 would replace:

````text
A transition cannot complete until every rule bound to that moment has a recorded result.
````

with:

````text
A transition cannot complete until every gate rule bound to that moment has a recorded result. Policy rules record a result as set out under How a transition is gated.
````

Verifier 1 would replace:

````text
Judge applicability once per task.
````

with:

````text
Decide fixed scopes in the app, at no cost.
````

Verifier 1 would replace:

````text
Each row shows how often the rule ran, its average time and its tokens.
````

with:

````text
Each row shows how many rule checks the rule has recorded, its average time and its tokens.
````

### 76. 'Quoted material' is undefined as a mechanism and omits evidence, review notes and other seat-written text

- **Lines:** 320, 334, 398, 402, 411, 558, 721-722
- **Rated:** minor (one verifier)
- **Fix:** the PRD already settles it elsewhere; the text needs aligning
- **Found by:** security and privacy

Line 334 is the only defence against task text steering a model, and it lists four builder texts. It omits evidence notes and links (hashed inputs, so they reach the orchestrator), release reasons, access request text, the reviewer's notes that reach the orchestrator at `task.before_done`, and orchestrator answers sent to builders. It covers checkers only, so a reviewer receives builder text unmarked. Because checkers are external seats, 'quoted' can only mean a field distinction in job inputs, which is not stated. Evidence links are fetched by reviewer and orchestrator tools on the owner's network and shown to the owner as live links; the risk row covers truthfulness only.

**Effect.** Track B and track D each decide what counts as untrusted input. An evidence note or a page behind an evidence link becomes an unmarked instruction channel to the reviewer and the approver.

**Verifier: partly.** Quotes are exact, but most of the claim fails. L334 is not the only defence: L327, L332, L335, L632, L721. Its list matches the builder free text in checker inputs (L319-322, L396); evidence notes are not hashed inputs. Release reasons (L402) and access text (L398) reach no model. L334's second sentence already denies authority to reviewer notes. L411 says "plain links", not live. Tracks B and D do not decide: the contract fixes job shapes first (L653, L663). What stands: L663 does not carry L334's quoting into those shapes, and reviewers are unaddressed.

**Verifier's fix.** Make the contract item at L663 repeat L334, so the one contract author fixes how quoted material is carried in job inputs before tracks B and D start. Not included, because they would be new requirements needing the owner's decision: extending quoting to what reviewers read, treating reviewer notes as quoted at `task.before_done`, and any rule about pages behind evidence links (the PRD places the work outside the app at L324 and L716, and leaves evidence to the reviewer at L722). I recommend leaving those out of version 1.

Text changes the verifiers proposed (not applied):

Verifier 1 would replace:

````text
the job kinds with their input and result shapes;
````

with:

````text
the job kinds with their input and result shapes, with builder-written text carried as quoted material and the contract and the rule's instruction as the only authority;
````

### 77. The speed targets cannot be measured where the plan says, have no baseline or load driver, and their release criterion cannot fail

- **Lines:** 584, 630, 669, 710, 724
- **Rated:** minor (one verifier)
- **Fix:** the owner has to decide
- **Found by:** build plan

The 50 ms target for app-run checks is to be measured in the core-loop milestone, which has no rules, so there is no app checker to measure. Both targets are stated as time 'added' with no baseline; a transition without events cannot exist, because a trigger rejects it. '50 active seats' has no load driver in any track, and that milestone has two real runner seats sharing one login. The release criterion accepts either meeting the targets or replacing them with whatever was measured, so no result can fail it.

**Effect.** Nobody builds the load harness, the numbers in the PRD stay guesses, and a slow workspace lock is found only after release with real seats.

**Verifier: partly.** All four quotes are exact. Stands: L630 measures app-check speed in the core-loop milestone, but L669 has "No rules yet" and app checkers arrive at L670. No track (L679-685) or required test (L642-649) owns a 50-seat load; L669 has two seats, and test 6 (L647) uses twenty for correctness only. Weaker: "adds" is measurable by timing the check and write segments, so the L584 trigger is no obstacle. L710 is deliberately measure-or-revise (L630 calls them guesses) and fails if nothing is measured, though any number passes. L724 already records the lock risk.

**Verifier's fix.** Already determined by L669-670: measure event and step writes at the core-loop milestone, app-run checks at the rule-checks milestone. Open: (a) who builds a scripted 50-seat load with stub seats and a named command mix. Recommend track A extending test 6, or track C if measured over HTTP, listed as a ninth required test. (b) Whether L710 stays measure-or-revise or a miss needs the owner's recorded approval. Recommend approval. Keep "added" as timed segments and also record end-to-end p95 including lock wait. Alternative: drop the targets and keep only the measurement.

### 78. Overturning an orchestrator's answer has no defined effect on the task or the seat that acted on it

- **Lines:** 168, 343, 388, 436, 560, 611
- **Rated:** minor (one verifier)
- **Fix:** the owner has to decide
- **Found by:** completeness pass

The owner 'can overturn a decision' and `question.overturned` exists, but no line says what overturning an answer does. The builder has already continued on the orchestrator's answer, and the task may be In review, Finishing or Done. Not stated: whether the owner must give a replacement answer, whether the current holder is told (`GET /v1/next` has `answer` only), whether a hold opens, whether passed criteria or a passed review are reopened, whether it is allowed after Done, and how the `questions` row keeps both outcomes.

**Effect.** The owner's only control over answers the orchestrator gave alone cannot be built; tracks B, C and E would each give it a different meaning.

**Verifier: partly.** Quotes at L168, L436, L560 and L611 are exact, and "overturn" appears nowhere else, so replacement answer, telling the holder and any hold are undefined. Two sub-claims fall. Overturn has no row in the lifecycle table (L61-80) and goal 1 (L13) allows no other state change, so it cannot reopen criteria, a review or a Done task. It is also not the owner's only control: Edit contract (L66, L121), hold (L79) and cancel (L80) exist. The `questions` row is outside replay (L598) and the log keeps both events.

**Verifier's fix.** Options: (a) record only: `question.overturned` feeds rule statistics and nothing reaches the task. (b) Overturn requires a replacement answer, written as `question.overturned` plus an owner `question.answered`; while the task is Working the holder gets it through the existing `answer` kind; it never changes task state. From In review onward it is record only, and the owner uses the existing Edit contract, hold or cancel. Recommend (b): it adds no transition or hold reason. Say the same for overturning an approval (`action.revoked`, only before it is reported done).

### 79. Criterion identity across a contract edit is undefined, so 'unchanged' criteria, replay of criterion state and per-criterion timing have no basis

- **Lines:** 121, 164-165, 224, 318-320, 556-557, 592
- **Rated:** minor (one verifier)
- **Fix:** the owner has to decide
- **Found by:** completeness pass

A contract edit keeps criteria that are 'unchanged and already passed', but nothing defines unchanged (same row, same text, same position) or says what happens to an edited or removed criterion's row, evidence, `build` steps and events. Only `task.contract_changed` is written: no event adds, removes or resets a criterion, though replay into empty tables must reproduce every criterion's state. The contract version is a bare number on the task, so a check stored against an earlier version cannot be shown against the criteria it judged.

**Effect.** Replay cannot rebuild criterion state after an edit, and timing or evidence recorded for one criterion is silently attached to different text.

**Verifier: partly.** All five quotes are exact. Stands: L121 never defines "unchanged", and nothing says what happens to an edited or removed criterion's state, evidence (L558) or `build` steps (L193, L224); Open decisions L748 and L755 do not cover it. Overstated: `task.contract_changed` (L65-66) can carry criterion ids under L137, and all payload schemas are deferred to the Contract milestone (L659), so replay of L592 is unspecified, not impossible; text is outside replay (L139). No requirement exists to show a check against the criteria it judged (L313, L566, L700 concern rule versions).

**Verifier's fix.** Add an Open decisions row, "Criterion identity across a contract edit". Options: (a) criteria rows are immutable: a text change retires the row and adds a new one, "unchanged" means the same row, a retired row keeps its evidence and steps, and the `task.contract_changed` payload lists kept, added and retired ids; (b) edit in place and reset state on any text change, listed in the payload. Recommend (a), with reordering alone not counting as a change. Drop the proposal to store criterion ids per contract version: nothing requires it.

### 80. Shipped rules have no creation or upgrade path that the log can replay

- **Lines:** 171, 250, 252, 339-347, 564-565, 589, 594, 637, 658, 670-671
- **Rated:** minor (one verifier)
- **Fix:** the owner has to decide
- **Found by:** completeness pass

Replay into empty tables must reproduce each rule's enabled flag and current version, so every shipped rule has to come from a logged `rule.created`. Nothing says what writes those events, with which actor, or when: there is no workspace-creation event or command, and seeding by migration (the natural reading of milestone 1) leaves rules that replay cannot rebuild. Nothing says what an upgrade does to an existing workspace when a shipped default changes or a new shipped rule arrives (four of the seven need milestone 4 hooks): enforce silently, or leave 'Revert to default' pointing at fields no version records.

**Effect.** Track B seeds rules one way and track A's replay test fails on them at integration. A later release can change what is enforced with no version, actor or event.

**Verifier: partly.** All five quotes are exact. Stands: nothing says what writes `rule.created` for shipped rules or when; L436 has no such command, and workspaces live across milestones (L669 "No rules yet", L673, L637), so existing workspaces must gain rules. Arrival state is open (L739 "ship that rule off"). Falls: migration seeding is already excluded by L131, L589 and L634, and the actor can only be the app (L152). Silent enforcement is excluded by L252, L273 and L565: checks run stored versions, and Revert records the shipped fields as a new version.

**Verifier's fix.** Add an Open decisions row and one sentence under Shipped rules. Options: (a) the server writes `rule.created` as the app, version 1 with the shipped fields, for every shipped rule a workspace lacks, at workspace creation and at start; existing versions are never touched and a changed default reaches a workspace only through Revert to default; (b) seed by migration and drop `rules` from the replay set. Recommend (a), and decide alongside it whether a rule arriving in an existing workspace starts on or off. Add a golden trace for it.

### 81. Check timeouts live in both the rule record and workspace settings, and changing a limit mid-flight is undefined

- **Lines:** 98, 249, 273, 327, 424, 436, 551, 615, 619, 742
- **Rated:** minor (one verifier)
- **Fix:** the owner has to decide
- **Found by:** completeness pass

`queue_timeout` and `run_timeout` are fields of each rule version, yet 'check timeouts' is also a workspace setting with a single default. No precedence is given, and only the rule's copy is frozen with a pending request. For the other limits nothing says what a change does to work in flight: a shorter lease length against live leases, a lower round limit against a task already past it, a lower re-run limit against checks already run. Settings lists Rules plus three sections marked later, so the 'change workspace settings' command has no screen.

**Effect.** Track B reads timeouts from the rule and track A's timer logic from settings. The owner cannot change a limit the PRD calls a setting.

**Verifier: partly.** All five quotes are exact. Two parts stand. L249 (rule fields) and L551 (workspace "check timeouts") never state their relationship; L742 does not say what the defaults are defaults for. L436 lists "change workspace settings", yet L604-619 give it no screen, and L615 does not expose timeouts either. Weakened: L304 says "its queue timeout", and L252/L273/L287 freeze the rule version, so the rule's value governs a running check. In-flight effects are largely implied: lease due times are stored (L556) and moved only by heartbeat (L179); round and re-run limits are tested at the failure or re-run (L98, L327).

**Verifier's fix.** Timeouts: (a) workspace values are defaults copied into a rule version on save, and the rule version's value governs, which matches L304 and L287; (b) one workspace value, with the rule fields dropped from L249. Recommend (a). Add one sentence: a settings change applies from the next claim or heartbeat and to checks queued afterwards, and round and re-run limits are compared when the failure or re-run happens. Screen: (a) add a Limits section to Settings in version 1; (b) drop "change workspace settings" from L436 and fix the L742 defaults. Recommend (a).

### 82. Removing or editing a seat that holds work has no specified effect

- **Lines:** 89-90, 96, 174, 332, 344, 436, 454, 555, 613
- **Rated:** minor (one verifier)
- **Fix:** the owner has to decide
- **Found by:** completeness pass

A credential in use cannot be removed, but nothing equivalent exists for seats. `seat.removed` and `seat.changed` exist and the owner can remove a seat, yet no rule says what happens when that seat holds a task, a review, a claimed job or a provisional claim. Under an owner hold the lease clock is paused, so the task keeps a holder that no longer exists until the hold lifts. `seat.changed` has no stated fields: a role change turns a builder seat into a reviewer, and a provider, model or rank change after building alters what the provider rule and escalation compare.

**Effect.** The state table and replay have no row for a task whose holder was removed, and independence and escalation rules compare values that changed after the work was done.

**Verifier: partly.** All five quotes are exact. Stands: no line states what removal does to a held task, review, job or provisional claim; L174 gives `seat.changed` no fields and L436 lists no command that produces it. Overstated: nothing is orphaned, because lease expiry (L78, L88) and job timeout (L172) free the work, and under a hold (L89) nobody could claim anyway. Refuted: independence uses seat identity from the log, not role (L332, L354); the provider rule compares recorded providers that actually worked (L519-520); replay excludes seats (L591-598).

**Verifier's fix.** Removal options: (a) refuse while the seat holds anything, as L454 does for credentials; (b) release its task, review, jobs and provisional claim in the same command with the usual release events; (c) state that lease expiry and job timeout handle it. Recommend (b), matching Cancel (L123) and "a dead seat cannot keep a task" (L89). For `seat.changed`: either drop it from L174, or add a change-seat command to L436 with named fields, refused while the seat holds work, with role and provider fixed at connect. Recommend the second.

### 83. Monotonic time is asserted, not enforced: two clock sources are named, the type has no zone, and nothing clamps a clock that steps back

- **Lines:** 87, 134-135, 148-149, 424, 628
- **Rated:** minor (one verifier)
- **Fix:** the owner has to decide
- **Found by:** completeness pass

`at` is 'the wall clock read once after the lock is taken', while Quality says every duration comes 'from the database clock'. The PRD then concludes that `at` never decreases with `seq` and that effective times never go backwards. A wall clock on an owner's machine does step back (time-sync correction, manual change, virtual machine resume), and a `timestamp` without zone stored in local time repeats an hour each autumn. No rule clamps `at` to the previous value, and lease and check due times are derived from the same clock.

**Effect.** A backward step produces negative step durations, fails the step-partition test and shortens or extends every lease by the size of the step.

**Verifier: partly.** Quotes at L134, L148 and L628 are exact. Stands: nothing clamps `at` or `effective_at`; L87 and L134-135 assert monotonicity from a clock that can step back, and no Risk or Open decision covers it. Overstated: "wall clock" (L134) vs "database clock" (L628) is loose wording, not necessarily two sources (L736-737: one process, PostgreSQL, one machine). `timestamp` (L148) is a generic type and local time is never stated. Test 2 (L643) telescopes and still passes; only L628's no-negative-duration rule breaks.

**Verifier's fix.** Not mechanical: the PRD states the invariant but no mechanism. Options: (a) clamp: keep the last `at` in the counter row, write the larger of database now and that value, derive lease and timeout due times from it; (b) drop the claim on `at`, order by `seq` only, floor step durations at zero; (c) refuse writes while the clock is behind and show it on system health. Recommend (a), with UTC stored with zone in the migrations. Separately, L134 "wall clock" can become "database clock" to match L628.

### 84. No order or re-evaluation is defined when several timers are due on one task

- **Lines:** 86, 89, 135, 286, 304-305, 742
- **Rated:** minor by both verifiers
- **Fix:** the PRD already settles it elsewhere; the text needs aligning
- **Found by:** event log

'Every timer already due' gives no order and no re-evaluation. A pending submit can have a check queue timeout (default 2 minutes) and a lease expiry due together. Applying the timeout creates a second attempt whose own timeout may also be due, then an `error` and a `check_error` hold, which may pause the lease clock; applying the lease first cancels the transition and withdraws the checks. The two orders end in different states (held with the old builder, or Ready), and lease-first writes earlier effective times after later ones. Whether a hold opened by a timer pauses the lease from its effective time or from now is also unstated.

**Effect.** The same history gives different final states depending on implementation order, and can break 'effective\_at never decreases'. The timer golden trace cannot be written.

**Verifier 1: partly.** All four quotes are exact (L86, L286, L304, L305). But the claimed divergence is already excluded: L86 sets effective time to due time and L87/L135 forbid it decreasing, so only ascending due order with re-reading conforms; lease-first out of order breaks a stated invariant. L226 shows an errored check's hold opens `wait_owner`, so L89 pauses the lease; L149 says durations use effective time. What stands: order and re-read are implicit only, and an exact tie between lease and check timeout is settled nowhere (L742, Open decisions and Risks are silent).

**Verifier 1's fix.** State at L86 what L87/L135 already force: timers apply one at a time, earliest due first, including timers an applied timer creates that are already due. State at L89 that the pause starts at the hold's effective time (L86, L149). Not in the edits because the PRD does not determine them: a tie-break for identical due times (recommend lease expiry first, since it withdraws the checks anyway) and an extra golden trace with both timers due. Both need a maintainer decision.

**Verifier 2: partly.** Order is not open: L86 dates each timer at its due time and L87/L135 forbid effective\_at decreasing, so ascending due time is forced and "lease-first" is already illegal. Re-reading follows from "every timer already due" (L86). Pause-from-effective-time follows from L89 plus L149 ("Durations use this field"). Case: submit at T, second queue miss at T+4m00s (L304-305), lease due T+4m05s, sweep at T+4m10s gives held with builder, 5s left; no guess. Only real gap: both due at the identical instant (lease-first gives Ready, timeout-first gives held). One track owns timers (L687).

**Verifier 2's fix.** State what the PRD already implies: timers apply one at a time in ascending due time, re-reading after each until none is due; a hold pauses the lease from its effective time. The reviewer's tie-break (lease before check timeout) is not determined anywhere, so it is not in the edits. It needs a one-line owner decision; I recommend lease first, matching L87 ("A lease ends at its due time") and L89's aim that a dead seat cannot keep a task. The extra golden trace is a new requirement; leave it to the contract author within L648's six to eight.

Text changes the verifiers proposed (not applied):

Verifier 1 would replace:

````text
it applies every timer already due on that task, in the same transaction, with the effective time set to the due time.
````

with:

````text
it applies every timer already due on that task, in the same transaction, one at a time in order of due time, earliest first, each with the effective time set to its due time. A timer that an applied timer creates and that is itself already due is applied in the same pass.
````

Verifier 1 would replace:

````text
pauses the lease clock. A paused seat does not
````

with:

````text
pauses the lease clock from the hold's effective time. A paused seat does not
````

Verifier 2 would replace:

````text
This covers lease expiry and check timeouts.
````

with:

````text
This covers lease expiry and check timeouts. Timers are applied one at a time in ascending due time, and the due timers are read again after each one, because applying a timer can create or remove another. This repeats until none is due.
````

Verifier 2 would replace:

````text
A hold on the owner or the project pauses the lease clock.
````

with:

````text
A hold on the owner or the project pauses the lease clock from the hold's effective time, so a hold opened by a timer pauses it from that timer's due time.
````

### 85. Data model and event record cannot hold what handoff says is recorded

- **Lines:** 155, 177, 436, 519, 526-527, 556, 559, 568, 570, 574-575
- **Rated:** minor by both verifiers
- **Fix:** verifiers disagree on whether the PRD already settles it
- **Found by:** credentials

'Every claim, job and handoff records which credential did the work', but `tasks`, `reviews`, `jobs` and `task_steps` have no credential column. The event record's subject kinds do not include a credential or a seat, so `credential.*` events cannot name their subject. No event marks a limit clearing, so going back to the own credential and closing the hold have no cause event. `credentials.state` values are not listed and overlap with `limited until`. The owner-interface command list, declared 'part of the contract', omits the seven credential commands. Cost reports carry no credential, so subscription and per-use spend cannot be separated.

**Effect.** The milestone-1 migrations and event registry are written without these fields; adding them later breaks 'schema changes are forward-only' assumptions and the golden traces.

**Verifier 1: partly.** Quotes are exact, but most sub-claims fail. L525 limits table changes to `credentials`, `credential_readings` and a seat credential, so L519's "records" can be event payload, like past holders "from the log" (L332). State values are at L473 (active or signed out); L516 keeps "limited" separate. The limit ends by timestamp (L515, L521); `hold.closed` exists (L79) and `cause_id` is nullable (L156). L527 already adds the owner commands. No requirement separates subscription from per-use spend. Added columns are forward-only (L637). Standing: L155 omits `credential`; L519's place of record is unstated.

**Verifier 1's fix.** Option A (recommended): keep L525's table list; say the credential id is carried in the payloads of `task.claimed`, `review.started`, `job.claimed` and `credential.switched`, and add `credential` to L155's subject kinds. Option B: the reviewer's four columns, which contradicts L525 and widens the replay set (L591-596). Either way: enumerate `credentials.state` at L574 from L473, point L436 at L527, and name the credential reset time among the timers at L86. Add no `credential.limit_cleared` event and no cost-report field.

**Verifier 2: partly.** Real: L155's subject list cannot name a seat or credential, though L174/L177 events and L214-215 steps need both. L436 omits the commands L527 adds. L519 names no home for the credential. Case: C1 limits mid-build, C2 takes over; I must guess where L520's worked-providers set is read from. Not real: L473 and L516 already fix state values; `limited until` plus timers (L86, L521) closes the hold without a new event; no requirement separates subscription spend. Columns contradict L525, and a `task_steps` column widens replay (L596). Forward-only (L637) allows additions.

**Verifier 2's fix.** Reject the reviewer's columns, `credential.limit_cleared` and cost-report credential: none is required, and L525 limits schema additions to `credentials`, `credential_readings` and a credential on each seat. Instead: add seat and credential to the subject list (L155); state that L519's record is the credential id in the event payload, the only home L137 and L525 leave; list the L527 commands in the owner interface (L436); spell out `credentials.state` as active or signed out (L574, from L473).

Text changes the verifiers proposed (not applied):

Verifier 2 would replace:

````text
The criterion, question, rule check, review, job, rule, hold or action concerned.
````

with:

````text
The criterion, question, rule check, review, job, rule, hold, action, seat or credential concerned.
````

Verifier 2 would replace:

````text
Every claim, job and handoff records which credential did the work. A handoff is the `credential.switched` event.
````

with:

````text
Every claim, job and handoff records which credential did the work, as the credential's id in the payload of its own event. It is empty for a seat that connects on its own. No table other than `seats` gains a credential column. A handoff is the `credential.switched` event.
````

Verifier 2 would replace:

````text
connect, pause and remove a seat, delete content, and change workspace settings.
````

with:

````text
connect, pause and remove a seat, delete content, change workspace settings, and the credential commands listed under Credentials: add, verify, sign in again, rename, remove, refresh usage and reorder.
````

Verifier 2 would replace:

````text
plan, account email, state, limited until, position in the handoff order, last verified
````

with:

````text
plan, account email, state (active or signed out), limited until, position in the handoff order, last verified
````

### 86. Who writes an outward action's description is contradictory, so an approval is bound to nothing concrete

- **Lines:** 104, 321, 334, 401, 561, 726
- **Rated:** minor by both verifiers
- **Fix:** the PRD already settles it elsewhere; the text needs aligning
- **Found by:** security and privacy

Line 334 lists action descriptions as builder-written text, but the only description that exists is the contract's `actions` row, and no agent call lets a builder write one. Either builders write descriptions through an unspecified call, so the thing approved is builder text; or the description is contract text, so the orchestrator approves a generic line and never sees what will actually be sent, paid or deleted (recipient, amount, target). In both readings the approval hashes only 'kind and description', and the report-done call carries nothing to compare against what was approved.

**Effect.** The approval job's input shape cannot be written. The orchestrator or owner approves an irreversible action without its concrete parameters, and Decided for you cannot show what was actually approved.

**Verifier 1: partly.** Quotes are exact. The contradiction is real but one phrase wide: L37, L104, L317, L561 and L608 all make the action description contract text (owner or planner, L65), frozen in Finishing (L121); no builder call writes one (L400-401). Only L334 calls it builder text. The rest is overstated: L321 gives the approval input shape, Decided for you can show kind and description, and unverifiable payloads are an accepted limit (L324, L716, L722, L726) with an open decision at L747.

**Verifier 1's fix.** Drop "action descriptions" from the builder-text list at L334, so it agrees with the contract-owned description everywhere else and with its own next sentence ("The contract ... the only authority"). L726 can stay: the orchestrator may still read handoff notes and evidence (L418). A builder action proposal with concrete target and amount, echoed in report-done, would be a new requirement; if wanted, raise it under the open decision at L747 instead of editing it in.

**Verifier 2: partly.** Real: L334 calls action descriptions builder text, yet L37, L104, L317 and L561 put the description in the contract, written only by owner or planner (L65-66, L417), frozen in Finishing (L121), with no builder call (L388-407). Writing the approval job input (L663) I would guess whether description is authority or quoted. Overstated: five rows outvote one, so the shape is writable. Report-done (L401) needing no payload is no guess. L726 still holds through the handoff note the orchestrator may read (L418). Missing concrete parameters is a product gap already tracked at L716 and L747.

**Verifier 2's fix.** Delete "action descriptions" from L334, so the description is contract text everywhere, as L37, L104, L317, L321 and L561 already say. Reject the reviewer's option (a): a builder action proposal is a new call, a new table field and new hashed inputs at two hooks, none traceable to the PRD, and it would make builder text the thing approved, worsening the L726 risk. If the owner wants approvers to see recipient, amount or target, raise it as a separate PRD change alongside the open decision at L747.

Text changes the verifiers proposed (not applied):

Verifier 1 would replace:

````text
handoff notes, action descriptions, questions and assumptions
````

with:

````text
handoff notes, questions and assumptions
````

Verifier 2 would replace:

````text
handoff notes, action descriptions, questions and assumptions
````

with:

````text
handoff notes, questions and assumptions
````

### 87. Milestone 3 (Rule checks) cannot be demonstrated without Needs you, holds and triggers that arrive in milestone 4

- **Lines:** 260, 298, 305-306, 327, 343-347, 645, 670-671, 680
- **Rated:** minor by both verifiers
- **Fix:** the owner has to decide
- **Found by:** build plan

Rule-check behaviour depends on Needs you items (errored check, three-seat claim failure, re-run limit, offline orchestrator), on holds (`contract_incomplete`, `check_error`) and on routing failures to the owner. Needs you arrives in milestone 4, and holds appear in no milestone except 'budget holds'. Four of the seven shipped rules bind to hooks whose triggers (questions, outward actions, cost reports, escalation) are milestone 4 work, so Test 4's 'each policy hook, on and off', assigned to track B, cannot pass at milestone 3.

**Effect.** Track B either builds its own temporary inbox and holds or stalls until milestone 4. Milestone 3 has no demonstrable exit, and track B's 'Verified by' cannot be met when its milestone ends.

**Verifier 1: partly.** Quotes are exact. Refuted: Test 4 is a before-release test (L640), not a milestone exit; tracks run in parallel across milestones (L653) and B builds on stubs (L687); the contract already ships every table, hold reasons and failed-gate behaviour (L658-664). Only milestone 2 has a stated exit. Milestone 3 is demonstrable through L696-697, L699-701 and the task-page Override (L609). Stands: no milestone names the hold mechanism or the check-originated Needs you items (L298, L305-306, L327), though "timeouts" (L670) ends in both.

**Verifier 1's fix.** Options: (a) State that holds (open, close, `wait_owner` step, lease pause) land with the core loop, and that milestone 3 opens and resolves the Needs you items rule checks create (`check_error`, three-seat claim, re-run limit, offline orchestrator); milestone 4 adds question, action, budget and round-limit items plus Decided for you. Note that Test 4's policy half completes in milestone 4. (b) Swap milestones 3 and 4. Recommend (a): (b) fails because action approval and question routing are themselves rules needing the orchestrator and check jobs.

**Verifier 2: partly.** The dependency is real: L298, L305-306 and L327 open Needs you items and L260/L305 open holds, yet L670 names neither and L671 holds Needs you; four shipped rules (L343, L345-347) need milestone 4 triggers. Overstated: tracks run in parallel from the contract with stubs (L653, L687) and tests are due before release (L640), so Test 4 has no milestone 3 deadline. The Contract is unaffected: holds, inbox\_items, hold/inbox events and gate outcomes are fixed (L113, L167, L176, L260-268, L562, L571); a check\_error golden trace needs no guess.

**Verifier 2's fix.** Option 1 (recommended): name the hold mechanism (hold events, wait\_owner step, lease-clock pause) in milestone 2, because track A's tests 1-3 already cover it (L594, L643-644); add a minimal Needs you (open, resolve; check\_error, three-seat, re-run-limit and offline items) to milestone 3; say the four policy rules at L343 and L345-347 land in milestone 4. Option 2, the reviewer's (a): holds in milestone 3; workable. Reject (b): L374 puts rules in the milestone after the core loop, and approvals need milestone 3's orchestrator jobs (L347, L357).

### 88. 'Commits together or changes nothing' contradicts refusals that must persist timer events, failed check rows, holds and a saved contract

- **Lines:** 86, 132, 136, 260, 278, 288, 298, 608, 625, 648
- **Rated:** minor by both verifiers
- **Fix:** verifiers disagree on whether the PRD already settles it
- **Found by:** completeness pass

Lines 132 and 625 make every command all-or-nothing. But a refused command must still commit several writes: timer events applied before validation (86, test 7), the failed gate's rule check row and `check.finished` event (278), the `contract_incomplete` hold (260), the per-seat failure count (298), the kept refusal (288), and for Complete contract apparently the edited contract itself (608). Nothing lists which writes survive a refusal or what `command_id` they carry. A same-key repeat that arrives after a newly due timer must both 'write nothing' (136) and apply the timer first (86).

**Effect.** Track A rolls back on refusal and loses lease expiries, failed-check rows and holds; tracks B and C assume they persist. Test 7 and the 3-seat hold cannot pass under the stated atomicity rule.

**Verifier 1: partly.** Quotes are exact, but L132 and L625 state transaction atomicity, not "refusal = rollback". Refusal is a stored outcome (L136, L288, L563, L572). Failed gates have committed effects (L260, L263-264, L278). Test 7 (L648), track A's own test (L679), requires the expiry to persist. The 3-seat count derives from rule\_checks keyed by seat (L313, L583). Timer events' command\_id is settled: empty for app-originated events (L157). What stands: no sentence says a refusal commits; repeat versus due timer (L136 vs L629) and the contract surviving a failed Complete contract (L608) are only implied.

**Verifier 1's fix.** Add one sentence to the Atomicity row saying a refusal commits (edit given); every item in it is already stated elsewhere. Two residuals are not edited and belong in the contract milestone's golden traces (L668). First, whether a same-key repeat applies a newly due timer: recommend no, it writes nothing and the sweep applies it; the effective time is the due time either way. Second, an explicit line that a gate-failed Complete contract keeps the saved contract and writes `task.contract_changed` (implied by L260, L317, L591).

**Verifier 2: partly.** Core contradiction refuted: L86, L648, L260, L278, L136 and L572 already make refusal a committed outcome; L625 is atomicity. L298's count derives from `rule_checks`. Real gap: refused Complete contract with zero criteria. L65 names `task.contract_changed`, `task.ready`; L260/L278 add `check.finished`, `hold.opened`. I must guess whether the contract and `task.contract_changed` persist (replayed contract version, L591), and which `command_id` refuse-path events carry after a model check (L157 covers completion only). Reviewer's same-key rule contradicts L136, L627, L707.

**Verifier 2's fix.** Option A (recommended): Complete contract always saves the contract and writes `task.contract_changed`; only `task.ready` depends on the gate. A model check must read the contract while pending (L276, L284), and L608 shows the kept task. Option B: nothing is saved on failure. Then state once: refusal is a committed outcome carrying due timer events (empty `command_id`), check rows, holds and the `commands` row; refuse-path events after a model check carry the requester's key; a same-key repeat is answered before timers and writes nothing.

Text changes the verifiers proposed (not applied):

Verifier 1 would replace:

````text
A command commits its state change, events, steps and rule check rows together, or changes nothing.
````

with:

````text
A command commits its state change, events, steps and rule check rows together, or changes nothing. A refusal is a committed outcome, not a rollback: the due timers applied before it, the rule check rows and `check.finished` events of a failed gate, any hold that gate opens and the stored refusal commit together.
````

### 89. Nothing says what happens to passed criteria, evidence and the release reason when a different builder takes the task

- **Lines:** 59, 78, 94, 96, 121, 208, 402, 557, 592
- **Rated:** minor by both verifiers
- **Fix:** verifiers disagree on whether the PRD already settles it
- **Found by:** completeness pass

Three paths hand a task to a different builder: release or lease expiry in Working, escalation after a failed review, and a contract edit. Only the edit says passed criteria 'stay passed'. For release and expiry nothing says whether criterion state, 'passed by' and evidence are kept or reset, though criterion state is a replay column. If kept, a new builder claiming a task whose builder criteria all passed lands in `finish` and can submit work it never saw. If reset, no event is named for it. The release reason is collected but delivered to nobody.

**Effect.** The state table, replay and golden traces cannot be written for the lost-lease path. A second builder either redoes finished work or submits the first builder's work blind.

**Verifier 1: partly.** Quotes are exact. Escalation is settled: L74 and L94 reopen only the failed criteria, via `criterion.reopened`. For release and expiry, L78 names only `task.released`/`task.lease_expired` and L694 demands exactly those events, so with L592 "criteria stay passed" is inferable (as at L121) but never stated. "Blind submit" is softened by L415 (builder reads criteria and evidence), L556 (work reference), L356 and L332. What stands: no explicit sentence for release/expiry, and the L402 release reason has no column (L556), no recipient, and L137 bars text in payloads.

**Verifier 1's fix.** Two small decisions. Criteria: (a) say under Timers and leases that release and expiry write no criterion event, so passed criteria, passed-by and evidence persist and the next builder reads them under the Roles table; (b) reopen all builder criteria, adding `criterion.reopened` to the Release row. Recommend (a): it matches L78, L94 and L121. Release reason: (a) a fixed-value reason in the `task.released` payload, shown in the task log; (b) free text in its own column, shown to owner and next builder. Recommend (a).

**Verifier 2: partly.** Case: B1 passes every builder criterion, lease expires, B2 claims and acknowledges. L78 names only `task.released`/`task.lease_expired`; `criterion.reopened` appears only on L74; L694 demands exactly the named events; L94 reopens only failed criteria; L121 keeps passes across a released holder. So criteria stay passed and B2's step is `finish` (L208). B2 can read criteria and evidence (L415), and a never-holder still reviews (L354). No guess for replay or traces. Only real gap: the release reason (L402) has no column, event field or reader.

**Verifier 2's fix.** State the implied rule once under Timers and leases: release and expiry reopen nothing, so passed criteria and their evidence carry to the next builder. Reviewer's option (b) contradicts L78/L694 (no event named). Option (a)'s "claim returns the release reason" is a new requirement, not in the PRD. Leftover small decision, not edited: is the release reason a fixed value in the `task.released` payload (L137 bars free text) or text in a table, and who reads it. Recommend a fixed list, shown in the task log.

Text changes the verifiers proposed (not applied):

Verifier 2 would replace:

````text
- **One thing at a time.** In version 1 a seat holds at most one task or review.
````

with:

````text
- **One thing at a time.** In version 1 a seat holds at most one task or review.
- **What a lost lease keeps.** Release and lease expiry write only `task.released` or `task.lease_expired`. No criterion is reopened, so criteria that have passed stay passed, with their evidence, for the next builder, as they do after a contract edit.
````
