# 0011. Gating reads and the transition function writes

Status: Accepted

## Context

The Rule checks milestone puts the owner's rules in front of four task
moves (ready to start, before an agent starts it, before work is
submitted, when the review has passed) and one policy (who may review).
An app checker answers inside the command; a model check is a job an
orchestrator agent runs later, so the command that asked for it must wait
and be finished, refused or ended by whatever command or timer brings the
last result. Milestone 1 fixed the in-process interface,
`Leverage::Gating`, with a conformance suite, and milestone 2 the one
writer, `Leverage::Transitions.apply`, which appends the event log in the
same transaction as every row. Where the rules are decided, who writes
their rows and how a waiting command is kept and finished are hard to
change once traces, replay and the audit depend on them (rule AR-003).
The decisions are the milestone's plan RE-1 to RE-7 and its rule 11.

## Decision

1. **Gating reads; the transition function writes.** The engine,
   `Leverage::Rules::Engine` in `api/lib/leverage/rules/`, answers the
   gating interface's calls from the rule tables and the log and writes
   nothing. `Transitions::Gate` asks it at the entry's hook with the
   hashed inputs of `Leverage::HookInputs`, and the writers each own what
   they name: `RuleChecks` the check rows, their attempts and every
   `check.*` event; `Jobs` the jobs and `job.*`; `PendingTransitions` a
   waiting command's row and its later outcome; `RuleRecords` the rules
   and their versions. A third static line holds it: no file under
   `lib/leverage/rules/` calls a writing Active Record method
   (`one_writer_test.rb`), beside milestone 2's two (only the event log
   inserts events; no controller or read writes). The engine replaced
   `Gating::NoRules`, which is deleted (RE-1).
2. **A waiting command is stored whole.** A command whose gate needs a
   model check answers `202 pending`. Its request is kept in
   `pending_transitions.params`, emptied when the transition leaves
   `pending`, because nothing else can carry it: a request body is
   content and may not be in an event, and the task's rows change only
   when the move completes (RE-2).
3. **It is finished by the same entry, as its requester.** When the last
   check settles, inside whichever command or timer brought it (a job
   result, a timeout, the owner's override or re-run, a rule turned off,
   the last hold lifting), the engine's re-entry decides, and the stored
   request is performed by its own entry, its events carrying the
   requester as actor, the requester's key and the check's event as
   cause. The requester's `commands` row takes the outcome and is marked
   for `GET /v1/next` (RE-3). One command can therefore write events
   under two keys; the log audit allows that only where a pending
   transition has the second key.
4. **One answer while a task waits.** The holder's, the reviewer's or a
   provisional claimant's other commands on that task answer `pending`
   unless the registry marks them allowed while pending; the owner's are
   never blocked (RE-4). A provisional claim reserves the task with no
   lease until its checks settle (RE-5). A planner's draft result runs
   Complete contract as the planner, and may itself answer `pending`
   (RE-6). A refused command still commits the check rows it made (RE-7).
5. **One way to end a waiting command from outside.** Whatever takes the
   task or the review away from the requester calls
   `PendingTransitions.cancel` first: the transition's checks and jobs are
   withdrawn, the holds they opened close, the stored request is emptied,
   and the requester's command reads refused with one of RC-17's three
   codes: `task_cancelled` for Cancel, `lease_expired` for a lease that
   ends, `invalid_state` for every other ending (plan section 2.1, rule
   11). A late result for a withdrawn job is refused, so a cancelled
   command never completes.

## Alternatives considered

- **Each entry asks the rules and writes its own check rows.** Every gated
  entry would repeat the same writes, and a check written two ways could
  not be replayed by one rule.
- **The engine writes its rows.** It would bypass the transition
  function's one transaction and its log, and the conformance suite's
  "evaluation writes nothing" would no longer hold.
- **Write a waiting contract's rows at once, with no event.** The replay
  test would report rows the log does not explain.
- **Re-send the request from the client when the check ends.** The PRD
  asks that the move completes on its own; a client that is gone would
  leave it waiting.
- **A fourth refusal code for a cancelled transition.** RC-17 is the
  owner's and names three; a delegated run does not add one.

## Consequences

- `pending_transitions.params` holds task text while a command waits. It
  is content: the PRD's Data model says so (S-7), and the Questions and
  approvals milestone's Delete content must blank it.
- A completion appears in the log inside another command's transaction,
  under its own requester's key; `leverage:verify_log` and the golden
  traces 07 and 16 to 19 read it that way.
- Every way a waiting command can end has a case in
  `state_table_pending_ends_test.rb`,
  `state_table_review_and_seat_ends_test.rb` or
  `state_table_handoff_test.rb`, and trace 18.
- The engine is the production gating; a workspace with no rule row
  answers as `NoRules` did, so the traces of milestones 2 and 3 still run
  whole on it.
