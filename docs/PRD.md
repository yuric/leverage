# leverage PRD: Event log, rule checks and the core task loop

Draft of 2026-11-19. An [adversarial review](research/prd-review/README.md) of the first draft recorded 89 findings. This draft settles 32 of them: the eight rated blocker (1 to 8), every finding from the review's credentials angle (7, 14, 29 to 35, 56 to 58 and 85), and findings 11, 15, 16, 23, 24, 40, 45, 47, 49, 50, 67 and 89. Each is settled in the section it touches, and the decisions behind them are recorded under Open decisions. Findings 13, 39 and 62 are answered in part there and under Risks. The other findings are open and wait for the milestone they touch.

Coordinating AI agents from several providers takes a technical patchwork today, and the work stops when a provider limit is hit or a login expires. leverage is meant to be the simple way to do that coordination: sign in, connect provider accounts, add a task in a form, and have the work reach Done even when a provider fails part-way.

The first user is the owner who is building it. The intended user is a person who has never opened a terminal. That is a claim, not an observation. What version 1 offers that person is continuity: the work survives a limit or a dead login, and the product explains what happened in plain language.

Version 1 is the core task loop (contract, claim, build, review, done) with two things built in from the first commit. The first is an append-only event log that times every step. The second is system rules that the app enforces as checks on task transitions. The Analytics page comes later as a view over this data, because the data cannot be backfilled. Version 1 also has Credentials: provider logins, API tokens and the order in which one takes over from another. All of it is built, in an order set by continuity: account setup joins the core loop, and handoff comes directly after it, so the first thing added to a working loop is that work survives a provider limit or a dead login.

Version 1 is three programs and two clients. The server is a Ruby on Rails application in API mode with PostgreSQL as its only datastore. It runs in Docker containers, one installation per owner, and holds the event log, the tasks and the rules. For the first run the containers run on the owner's Mac, and the same containers move to a server the owner controls later. The Mac app is the owner's interface: a native app written in Swift with SwiftUI, a thin client of the server's API. There is no browser version. The helper is a separate program on the owner's Mac, written in Swift. It starts each provider's own tool with the login that tool already holds, and reports to the server. A subscription login stays inside the provider's own tool: it never leaves the Mac and never reaches the server. The two clients are the reference runner, which the helper starts for a seat the app runs, and the MCP server (see Clients).

## Goals and non-goals

Version 1 proves one loop end to end with real agents, and records enough to find bottlenecks later without guessing.

Goals:

1. A task moves from Backlog to Done through one server-side transition function. No other code path changes task state.
2. Every state change writes an event in the same database transaction. If the event is not written, the change did not happen.
3. Every task's lifetime is split into timed steps that do not overlap and leave no gaps. Each step says who was working or what the task was waiting for.
4. System rules are checks the app runs at fixed moments. A transition cannot complete until every rule bound to that moment has a recorded result.
5. Each rule check records whether the rule applied, the result, who checked it, and how long it queued and ran.
6. The owner can turn any rule off, change its parameters, override a single failed check, and see the cost in time of each rule.
7. Agents from any provider connect through one HTTP interface. A reference runner and an MCP server ship with version 1. The reference runner is built for Claude first.
8. The owner adds provider logins and API tokens in one place, sees each account's limits and available resets, and sets which credential takes over when one hits a limit or is found signed out.
9. Work survives an interruption. When a provider limit is hit or a login is found signed out after work is saved, the task continues on another credential or resumes from the saved work, the recovery time is recorded, and the app tells the owner what happened in plain language.

Non-goals for version 1:

- The Analytics page. Version 1 ships the data, the queries behind it and a timeline on each task page.
- The roles and skills library, routines, and the shared Activity chat with @-mentions.
- The orchestrator as a chat super-user. In version 1 the orchestrator answers questions, runs model-checked rules and approves actions. Tasks are added through a form.
- Teams and sharing. One owner per workspace.
- Managing agents' files or branches. The app stores a reference to where the work lives and links to evidence.
- A view across workspaces for the operator. It needs a privacy decision first.

## Terms

| Term | Meaning |
| --- | --- |
| Workspace | One owner's whole installation: projects, agents, rules and data. |
| Seat | One connected agent: a provider, a model, an effort setting and a role. It signs in with its own token. A seat is either run by the app, which starts it on one credential, or connects on its own with no credential. |
| Task contract | A task's goal, its acceptance criteria, its budget and any outward action it ends in. |
| Acceptance criterion | One thing that can be checked to prove the task is done. The last one is always the independent review. |
| Outward action | Publishing, paying, sending or deleting. It cannot be undone once it leaves the app. |
| Transition | A change of task state, requested by a command and carried out only by the server. |
| Hook | A named moment in the loop where rules run, such as "before a task enters Ready". |
| Rule | A system-wide instruction bound to one hook, with a scope and a checker. |
| Rule check | One run of one rule for one task at one hook. It is stored with its result and its times. |
| Event | An immutable record that something happened, written by the server. |
| Step | A timed segment of a task's life, opened and closed by events. |
| Hold | A reason a task cannot move: waiting on the owner, on access, on budget, on a paused project, on a rule check that could not run, on a provider limit or on a signed-out login. Holds stack. |
| Job | A piece of model work the server queues for a seat: a rule check, a question to answer, an approval, a contract to draft. |
| Lease | A seat's time-limited claim on a task or a review. It is renewed by heartbeat and released on expiry. |
| Holder | The seat with the live builder lease or the provisional claim on a task. A task has at most one. |
| Builder | The seat that last claimed a task. It is kept through In review and Finishing and cleared when the task returns to Ready or Backlog or is cancelled. A seat has held a task if it ever had a builder lease on it; reviews and jobs do not count. |
| Briefing | What an agent must read before it works: the applicable rules, the project brief, its role file and the contract. |
| Credential | How a seat reaches its provider: a subscription login used through the provider's own tool, or an API token. |
| Handoff order | The owner's ordered list of all credentials, whatever their provider. When one hits a limit or is found signed out, the next one takes over. |
| Candidate | For a seat the app runs: its own credential and every credential below it in the handoff order. A candidate is available when it is signed in and not limited. An API token is not available until what carries out a task on a token is decided. |
| Helper | The program on the owner's Mac that starts each provider's own tool with the login that tool already holds, reads usage and reports to the server. It signs in to the server with its own token. Its launcher is the part that starts and stops the seats the app runs. |
| Work reference | Free text saying where a task's work lives: a folder, a repository, a branch or a commit. The server never opens it. |
| Saved work | What the app can observe of a task's progress: the criteria already passed with their evidence, and the work reference recorded on the task. |
| Recovery time | The time from the event that records an interruption (a limit reached, or a sign-out found during a run) to the handoff when another credential takes over at once, and otherwise to the first event written for the task by the seat that continues it. |

## Task lifecycle

A task has eight states and moves between them only through commands the server carries out. Six are drawn below. The picture leaves out Finishing, which only a task with an outward action passes through between In review and Done, and Cancelled. The lanes on the board are Imaginarium, Backlog, Blocked, Ready, In Progress (working, in review or finishing) and Done. Cancelled tasks show only under a filter. Blocked is a lane, not a state: it shows every task with an open hold that waits on the owner or the project, whatever its state, and the card says where it came from. The table under Holds says which hold reasons those are. The task returns to its own lane when the hold lifts.

_The lifecycle diagram (6 states, 5 gated moves, 2 loops) did not survive the export. The table below is the authority._

Each forward move names the hook where rules run. A failed review loops back to the builder if that seat is free, and a lost lease in Working returns the task to Ready. A hold does not change the state.

| Command | From | To | Who may ask | Hook | Events written |
| --- | --- | --- | --- | --- | --- |
| Add task | None | Imaginarium or Backlog | Owner | None | `task.created` |
| Promote | Imaginarium | Backlog | Owner | None | `task.promoted` |
| Draft contract | Backlog | Backlog | Owner | None | `job.queued` |
| Complete contract | Backlog | Ready | Owner or planner seat | `task.before_ready` | `task.contract_changed`, `task.ready` |
| Edit contract | Backlog | Backlog | Owner | None | `task.contract_changed` |
| Edit contract | Ready, Working, In review | Backlog | Owner | None | `task.contract_changed`, `task.returned` |
| Claim | Ready | Working | Builder seat | `task.before_claim` | `task.claimed` |
| Acknowledge briefing | Working, Finishing | Unchanged | Holder | None | `task.briefing_acknowledged` |
| Acknowledge review briefing | In review | In review | Reviewer holding the review | None | `task.briefing_acknowledged` (the payload names the review) |
| Start criterion (optional) | Working | Working | Builder | None | `criterion.started` |
| Pass criterion | Working | Working | Builder | None | `criterion.passed`, `evidence.attached` |
| Submit | Working | In review | Builder | `task.before_submit` | `task.submitted` |
| Claim review | In review | In review | Reviewer seat | `review.assign` | `review.started` |
| Release review, or review lease expiry | In review | In review, unassigned | Reviewer or the app | None | `review.released` or `review.lease_expired` |
| Review fails | In review | Working, or Ready when the previous builder is not free | Reviewer | `review.failed` | `review.failed`, `criterion.reopened`, and `task.reassigned` if it escalates |
| Review passes, no outward action | In review | Done | Reviewer | `task.before_done` | `review.passed`, `task.done` |
| Review passes, with an outward action | In review | Finishing | Reviewer | `task.before_done` | `review.passed`, `action.requested` (one per action) |
| Approve action | Finishing | Finishing | Owner, or the orchestrator through its approval job | None | `action.approved` |
| Grant the action lease | Finishing, an approved action waits for a builder that now holds nothing | Finishing | The app, in the command that frees the builder | None | `action.lease_granted` |
| Stop action | Finishing | Finishing, held with `action_stopped` | Owner or the orchestrator | None | `action.stopped`, `hold.opened` |
| Waive action | Finishing | Finishing, or Done when it was the last open action | Owner | None | `action.waived`, and `task.done` when last |
| Return for rework | Finishing, only while no action has been announced as started or reported done | Working, or Ready when the previous builder is not free | Owner | None | `task.returned_for_rework`, `criterion.reopened`, `action.withdrawn` for each action that goes back to contracted, `hold.closed` |
| Start action | Finishing | Finishing | Builder | None | `action.started` |
| Report action done | Finishing | Done, once every action is done or waived | Builder | None | `action.reported_done`, and `task.done` when last |
| Mark action done | Finishing, held with `action_unconfirmed` | Finishing, or Done when it was the last open action | Owner | None | `action.marked_done`, `hold.closed`, and `task.done` when last |
| Offer task again | Finishing, held with `action_unconfirmed` | Finishing | Owner | None | `hold.closed` |
| Release, or lease expiry | Working, Finishing | Ready from Working. From Finishing, the task stays in Finishing, held with `action_unconfirmed` | Holder or the app | None | `task.released` or `task.lease_expired`, and from Finishing `hold.opened` and `inbox.opened` |
| Hold and resume | Any | Unchanged | Owner or the app | None | `hold.opened`, `hold.closed` |
| Report a limit or a sign-out | Working, Finishing, or In review while a reviewer holds the review | Unchanged | The helper, acting as the app | None | `credential.limit_reached` or `credential.signed_out`, then `credential.switched` when the work is handed off. When no candidate is available: `hold.opened`, with `inbox.opened` when the owner must act, or `review.released` for a review |
| Cancel | Any except Done | Cancelled | Owner | None | `task.cancelled` |
| Write the shipped rules | None | Unchanged | The app | None | `rule.created` |

Saving the Add task form is two commands in a row: Add task, then Complete contract.

Draft contract queues a planner job. Its result is the Complete contract command (see `POST /v1/jobs/{id}/result`).

`action.requested` runs once per action. The server starts it, not a command.

The last column names the events of the move itself. A command also writes the registered events for whatever else it changes: `check.*` and `job.*` events for the rule checks at its hook, `hold.opened` and `inbox.opened` when it holds the task or opens a Needs you item, `credential.switched` when it gives a builder a fresh lease or closes a credential hold and the run starts on a credential other than the one last recorded for the task, `action.lease_granted` on the Finishing task whose approved action waits for a builder it frees, and, on Cancel, `hold.closed`, `inbox.resolved`, `check.finished` with the result `withdrawn`, `job.withdrawn` and `action.revoked` for what it closes, resolves, withdraws and revokes.

### Timers and leases

- **Timers run first.** Before the server validates any command on a task, it applies every timer already due on that task, in the same transaction, with the effective time set to the due time. This covers lease expiry, check timeouts and the release of a `credential_limit` or `credential_signed_out` hold, which is due at the earliest reset time among the seat's candidates and is recomputed when credentials change. The sweep only triggers the same logic for tasks nobody has touched. Timers that belong to the workspace and not to one task, such as the orchestrator-offline detector, are fired by the sweep through the same code path.
- **A lease ends at its due time.** After that, every call from its holder is refused with `lease_expired`, a heartbeat included. Effective times never go backwards within a task.
- **Two kinds of lease.** The builder's lease covers Working, and Finishing once an action is approved. Submitting ends it: while the task is In review, or in Finishing awaiting approval, no seat holds it, and the task keeps its builder seat. A reviewer has its own lease during a review, with heartbeat and release. An expired review lease leaves the task In review and unassigned, so another reviewer can claim it.
- **Holds and the lease clock.** A hold whose reason pauses the lease (see the table under Holds) pauses the lease clock. A paused seat does not, so a dead seat cannot keep a task. A `credential_limit` hold does not either: the helper has stopped the run, so no heartbeat is sent and the lease ends on time.
- **One thing at a time.** In version 1 a seat holds at most one task or review. A provisional claim counts as the task the seat holds, and release withdraws it.
- **What a lost lease keeps.** Release and lease expiry write only `task.released` or `task.lease_expired`. No criterion is reopened, so criteria that have passed stay passed, with their evidence, for the next builder, as they do after a contract edit. A release carries a reason from a fixed list in the contract's registry. It is carried in the `task.released` payload and shown in the task's log, and it is never free text.

### Rework and escalation

A failed review adds one to the round and reopens the failed criteria. If the previous builder holds nothing and is enabled and not paused, it gets a fresh lease, must acknowledge the briefing again before any work call, and learns of it through `GET /v1/next` (kind `rework`). If that lease expires, the task returns to Ready. Otherwise the task returns to Ready at once and any eligible builder may claim it. The `review.failed` event records which happened.

Escalation is a restriction on who may claim, not a push to a seat. It sets a minimum strength rank on the task. If the previous builder is below it, the task goes to Ready and only a seat at or above that rank can claim it.

Rounds are limited by a workspace setting, 3 by default. A failure at the limit holds the task with the reason `rounds_exceeded` and opens a Needs you item. A rework the owner chose does not count toward this limit.

### Outward actions

An outward action happens only after the independent review has passed.

1. The contract names each outward action the task ends in.
2. When the review passes, the task moves to Finishing and the server requests each action at the `action.requested` hook. Each action is checked on its own. Gate rules at `action.requested` run first, and the approval policy runs only when every gate has passed, did not apply, was withdrawn or was overridden. If the approval rule is off, or its scope does not cover the action, or the orchestrator passes it on, the action holds the task with `owner_approval`.
3. When no action is waiting for a decision and none is stopped, the previous builder gets a fresh lease covering every approved action, if it holds nothing. It acknowledges the briefing again, announces each action as it starts it, carries the actions out in contract order and reports each done. If it holds something else, the task waits in Finishing with no holder. That seat is offered the action through `GET /v1/next` (kind `action`) as soon as it holds nothing, and may not claim new work while an approved action waits for it. The command that frees it gives it the fresh lease and writes `action.lease_granted` on the waiting task.
4. The task is Done when every contracted action is reported done by the builder, marked done by the owner or waived by the owner.

A stopped action holds the task with the reason `action_stopped` and opens a Needs you item with three choices: waive the action, return the task for rework, or cancel it. When a failed rule check stopped the action, the item also offers to override that check once, which is the owner approving the action. Rework is offered only while none of the task's actions has been announced as started or reported done. It adds one to the round, reopens the criteria the owner names and the review criterion, and gives the previous builder a fresh lease as after a failed review. Actions not yet carried out go back to contracted, and the review and `task.before_done` run again before any action is requested again. An owner rework does not trigger the round limit. No action can be requested in any other state.

Overturning an approval the orchestrator gave, before the action is reported done, stops the action in the same way. Overturning an approval whose action is already reported done is recorded and changes nothing.

If the builder releases the task or its lease expires after an approval and before every approved action is reported done, or the builder seat is disabled or removed before it has carried out an approved action, the task is held with the reason `action_unconfirmed` and a Needs you item opens with four choices: offer the task again to the same builder (a fresh lease, delivered through `GET /v1/next` as kind `action`), mark the action done (recorded as reported by the owner), waive it, or cancel. The task is never given to another seat automatically. The item names what was approved and by whom, and says whether the builder announced that it had started the action.

Disabling or removing a seat that holds a task in Working releases the task to Ready with `task.released`, whose reason is `seat_disabled` or `seat_removed`.

### Holds

Hold reasons are a fixed list of sixteen. The table gives each one's rules. In it, "Pauses" means the lease clock stops while the hold is open, if a seat holds the task.

| Reason | Opened when | Closed when | Lease clock | In Blocked | Step |
| --- | --- | --- | --- | --- | --- |
| `owner_question` | A blocking question is passed on to the owner. | The owner answers. | Pauses | Yes | `wait_owner` |
| `owner_approval` | An outward action waits for the owner's decision. | The owner approves or stops the action. | Pauses | Yes | `wait_owner` |
| `access` | A seat says what access the task needs. | The owner marks the access granted. | Pauses | Yes | `wait_owner` |
| `budget` | The task reaches its own cap. | The owner raises the cap. | Pauses | Yes | `wait_owner` |
| `project_paused` | The task's project is paused, by the owner or by the budget rule. | The project resumes. | Pauses | Yes | `wait_owner` |
| `contract_incomplete` | A gate at `task.before_ready` fails. | The next `task.contract_changed`. | No lease exists | No, the task is in the Backlog lane | `wait_contract` |
| `check_error` | A blocking rule check ends in `error`. | The check is re-run to a result other than `error`, is overridden, or is withdrawn. | Pauses | Yes | `wait_owner` |
| `rounds_exceeded` | A review fails at the round limit. | The owner allows one more round or edits the contract. | Pauses | Yes | `wait_owner` |
| `action_stopped` | An outward action is stopped. | The owner waives the action, returns the task for rework, or overrides the check that stopped it. | Pauses | Yes | `wait_owner` |
| `action_unconfirmed` | The builder loses the task after an approval and before every approved action is reported done. | The owner offers the task again, marks the action done or waives it. | Pauses | Yes | `wait_owner` |
| `claim_gate_failed` | The task fails a gate at `task.before_claim` for 3 different seats. The hold records the rule. | The owner edits the contract, overrides the check once or turns the rule off. | No lease exists | Yes | `wait_owner` |
| `rerun_limit` | A model-checked gate has run 3 times in one round on changed inputs. The hold records the rule. | The owner overrides the check once, edits the contract or turns the rule off, or the waiting command is cancelled. | Pauses | Yes | `wait_owner` |
| `owner_hold` | The owner holds the task. | The owner resumes it. | Pauses | Yes | `wait_owner` |
| `seat_paused` | The seat holding the task is paused. | The seat resumes or loses the task. | Runs | No | `wait_seat` |
| `credential_limit` | None of the seat's candidates is available and none is signed out. | A candidate resets, a reading shows capacity, or the seat loses the task. | Runs | No | `wait_limit` |
| `credential_signed_out` | None of the seat's candidates is available and at least one is signed out. | A candidate is verified after the owner signs in again, or a limited candidate resets. | Pauses | Yes | `wait_owner` |

- Holds stack. A task is held while any hold is open. The waiting step follows the oldest open hold: its kind is that reason's step, and its subject is the one the Step kinds table gives for that kind. A new step opens whenever the oldest open hold changes.
- A hold blocks the seat commands that move work forward: claim, pass, submit, verdict, start action and report action done. Heartbeat, release, cost report, contract edits, cancel and timers still work.
- Complete contract is allowed under a hold and first closes an open `contract_incomplete` hold. A re-run or an override closes `check_error`. So neither hold blocks its own resolution.
- Resume closes only an `owner_hold`. Every other hold closes through the choice that answers it, or on its own as the table says. Cancel closes every hold.
- A hold caused by a credential carries the credential's id only, in the hold and in the step.
- A task held with `credential_limit` opens no Needs you item when a reset time is known, because there is nothing for the owner to do. The task card and the task page name the account waited for and its reset time.
- A pending rule check is not a hold. It does make the task ineligible for anyone else to claim.

#### Needs you choices

Every Needs you item has choices that work, or has none and says what closes it. This table is the one home for them.

| Item | About | Hold reason | Choices, and what each does |
| --- | --- | --- | --- |
| Question passed on | Task | `owner_question` | Answer. |
| Approval | Task | `owner_approval` | Approve the action, or stop it. |
| Stopped action | Task | `action_stopped` | Waive the action, return the task for rework (only while no action has been announced as started or reported done), or cancel. When a rule check stopped the action: override that check once, which approves the action. |
| Unconfirmed action | Task | `action_unconfirmed` | Offer the task again to the same builder, mark the action done, waive it, or cancel. |
| Past the round limit | Task | `rounds_exceeded` | Allow one more round, edit the contract, or cancel. One more round closes the hold, and the next failure opens it again. |
| Refused for every agent | Task | `claim_gate_failed` | Edit the contract, override the check once, turn the rule off, or cancel. |
| Check past the re-run limit | Task | `rerun_limit` | Override the check once, edit the contract, or cancel. |
| Check could not run | Task | `check_error` | Run it again, override it once, or turn the rule off. |
| Access request | Task | `access` | Mark the access granted, or cancel. |
| Task budget reached | Task | `budget` | Raise the cap, or cancel. |
| Project budget reached | Project | `project_paused` | Change the budget, or resume the project. |
| Account signed out | Task | `credential_signed_out` | Sign in again. It opens the provider's own sign-in window. |
| Limit with no reset time | Task | `credential_limit` | None. It closes when a reading shows capacity. |
| No reviewer is eligible | Task | None | Connect an agent from another provider, or turn the provider rule off. It closes on its own when a connected seat may review the task. |
| Orchestrator offline | Workspace | None | None. It closes on its own when a seat with the role polls again. |

### Contract edits and cancel

The owner can edit a contract freely in Backlog. Editing it in Ready, Working or In review returns the task to Backlog and ends any builder lease and any review lease on it. Criteria that are unchanged and already passed stay passed. `task.before_ready` runs again on the way back to Ready. A contract cannot be edited in Finishing or Done. Return for rework is the only way to change the work of a task in Finishing. Editing a contract, in any state including Backlog, cancels the task's pending transition and withdraws its checks and jobs, as Cancel and lease expiry do.

Cancel closes the open step and every hold, resolves the task's Needs you items, withdraws its pending checks and jobs, and revokes any approval not yet reported done. The holder's next call is refused with `task_cancelled`. If an approved action was announced as started, the Needs you item and the cancel confirmation say that it may already have gone out. Cancel records the action as revoked and does not claim that it did not happen.

## Event log

The log is one table that the server appends to. No row is ever updated or deleted.

### Principles

1. **One writer.** Only the server's transition function appends events. Agents, the Mac app and the helper send commands and never write events.
2. **Same transaction.** The event, the state change and the step change commit together or not at all.
3. **Lock first.** The first statement of every transaction that changes anything takes the workspace lock and holds it to commit. Isolation is read committed. Long polls never run inside a transaction, and the server makes no model call: model work is a job that a seat pulls. A change that touches many tasks is done in bounded batches.
4. **Order and time under the lock.** `seq` comes from a counter row read under the lock, not from a database sequence. `at` is the wall clock read once after the lock is taken, and every event of one command shares it. So `seq` order is commit order, `at` never decreases as `seq` grows, and a reader that tails by `seq` misses nothing.
5. **Timers before commands.** Any timer already due on a task is applied before a command on that task is validated, with `effective_at` set to the due time. `effective_at` never decreases within a task.
6. **Idempotent commands.** Every mutating call carries an idempotency key. A repeat with the same key writes nothing and returns the command's current outcome: pending, completed with its result, or refused with its cause.
7. **References, not content.** Payloads hold ids, numbers and short fixed values. They hold no prompt text, file content, question text or secrets. A credential appears in a payload by its id only, never by its name, email, plan or settings folder. Content lives in its own tables and can be deleted without touching the log.
8. **Versioned payloads.** Each event type has a payload schema with a version. A change adds a version. Old events are never rewritten.
9. **A defined replay.** The log must rebuild a named set of columns, listed under Data model. Content such as titles, criterion text and instructions is outside that set.

### The event record

| Field | Type | Meaning |
| --- | --- | --- |
| `id` | uuid | Identity of the event. |
| `workspace_id` | uuid | Owner of the row. Every query filters on it. |
| `seq` | bigint | Order within the workspace, in commit order. |
| `at` | timestamp | When the server recorded it. Never decreases as `seq` grows. |
| `effective_at` | timestamp | When it happened. Equal to `at` except for timer events, which carry their due time. Durations use this field. |
| `type` | text | One of the registered event types. |
| `schema_version` | int | Version of this type's payload schema. |
| `actor_kind`, `actor_id` | enum, uuid | Who caused it: the owner, a seat or the app. |
| `project_id`, `task_id` | uuid, nullable | What it is about. |
| `round` | int | The task's review round, starting at 0. |
| `subject_kind`, `subject_id` | enum, uuid | The criterion, question, rule check, review, job, rule, hold, action, seat, credential, Needs you item, brief entry or evidence concerned. |
| `cause_id` | uuid, nullable | The event that led to this one. |
| `command_id` | text, nullable | The idempotency key of the command. All events of one command share it. Events written when a pending transition completes carry the original requester's key, with `cause_id` set to the `check.finished` event. A refused transition never completes later, so no later event carries its key. Events written by a helper report carry the helper's idempotency key. Empty for app-originated events, which are the events the server's own timers and requests write, the checks at `action.requested` included. Indexed, not unique. |
| `payload` | json | Type-specific facts, validated against the schema. |

### Event types

| Group | Types |
| --- | --- |
| Task | `task.created`, `task.promoted`, `task.contract_changed`, `task.changed` (priority, project, cap), `task.ready`, `task.returned`, `task.returned_for_rework`, `task.claimed`, `task.briefing_acknowledged`, `task.released` (with a reason from the fixed list), `task.lease_expired`, `task.submitted`, `task.reassigned`, `task.done`, `task.cancelled` |
| Criteria | `criterion.started`, `criterion.passed`, `criterion.reopened`, `evidence.attached` |
| Review | `review.started`, `review.released`, `review.lease_expired`, `review.passed`, `review.failed` |
| Holds | `hold.opened`, `hold.closed`, each with a reason and, where one applies, the rule or the credential that caused it |
| Questions | `question.asked`, `question.answered` (from the record, by the orchestrator or by the owner), `question.overturned` |
| Outward actions | `action.requested`, `action.approved`, `action.lease_granted` (the builder an approved action waited for gets its fresh lease), `action.stopped`, `action.started`, `action.reported_done`, `action.marked_done` (by the owner), `action.waived`, `action.withdrawn` (an action put back to contracted by a return for rework), `action.revoked` (by Cancel only) |
| Rule checks | `check.queued`, `check.started`, `check.finished` (with the result, `withdrawn` included), `check.overridden` |
| Rules | `rule.created`, `rule.changed`, `rule.enabled`, `rule.disabled`, `rule.reverted`, `rule.removed` |
| Jobs | `job.queued`, `job.claimed`, `job.finished`, `job.timed_out`, `job.requeued`, `job.withdrawn` |
| Money | `cost.reported` (from a seat's report, a review verdict or a job result), `project.budget_changed` |
| Projects and seats | `project.created`, `project.paused`, `project.resumed`, `brief.changed`, `seat.connected`, `seat.paused`, `seat.resumed`, `seat.changed`, `seat.removed` |
| Workspace | `workspace.settings_changed`, `content.deleted` |
| Needs you | `inbox.opened`, `inbox.resolved` |
| Credentials | `credential.added`, `credential.verified`, `credential.signed_out` (also written when a sign-out is found during a run), `credential.renamed`, `credential.removed`, `credential.order_changed`, `credential.limit_reached`, `credential.switched`. The id of the credential that did the work is also carried in `task.claimed`, `review.started` and `job.claimed`. |

Heartbeats and reads are not events. A heartbeat only moves the lease's expiry time. A report from the helper is a command: it writes an event only through the transition function. A usage reading is not an event.

The contract's registry file is the authority for this list, and for hold reasons, refusals and check results. The tables in this PRD stay, and a check in continuous integration fails when one of them and the registry differ. Release reasons are a fifth fixed list, kept in the registry only, so this PRD has no table of it and the check does not compare it.

The Activity feed, the log on each task page, the steps table and the analytics queries all read from this one table. Events are kept for the life of the workspace in version 1.

## Steps and timing

A task's life is a row of steps that touch end to end, so every minute of it belongs to exactly one step. The steps table is written in the same transaction as the events that open and close each step.

### Rules for steps

1. Exactly one step is open on a task from its creation until it is done or cancelled.
2. Opening a step closes the one before it at the same effective time.
3. A hold interrupts the current step. The work step closes and a waiting step opens. If the oldest open hold changes while the task is held, that waiting step closes and a new one opens for the new oldest hold. When the last hold lifts, the step that opens is the one the task's current state calls for, which may differ from the one interrupted.
4. Each step records its kind, its class (working, waiting or rule check), its subject and the seat responsible.
5. A builder can announce the criterion it is starting, and the `build` step then carries that criterion. Without an announcement the step has no criterion. When a criterion passes, an open step without one, for the same seat and round, is given that criterion. Whatever is left is reported as unattributed build time. The reference runner and the MCP server always announce.
6. The sum of a task's steps equals its lifetime. This is a tested invariant.
7. Reports measure a task from its promotion to Backlog, or from its creation if it was added straight to Backlog. Time in Imaginarium is shown apart.
8. A step's cause and subject are fixed when it opens. A change of credential state with no task event does not open a new step.

### Step kinds

| Kind | Class | Open while | Subject |
| --- | --- | --- | --- |
| `idea` | Waiting | The task is in Imaginarium. | None |
| `draft` | Working | A planner job is writing the contract. | The job |
| `wait_contract` | Waiting | The task is in Backlog and nobody is writing its contract. | None |
| `check` | Rule check | A transition is pending on one or more model checks, or an outward action is waiting on its checks or its approval job. | The pending transition, or the action |
| `wait_ready` | Waiting | The task is in Ready with no seat. It names `credential_limit` as its cause when no seat is eligible only because none of its candidates is available, and none of them is signed out. | None |
| `briefing` | Working | A seat has claimed the task and not yet acknowledged the briefing. | None |
| `build` | Working | The builder is working toward a criterion. | The criterion, if announced |
| `finish` | Working | Every builder criterion has passed and the task is not yet submitted, or an approved outward action is being carried out. In the action case it opens when the builder acknowledges the briefing after the approval. | The first approved action not yet reported done, if any |
| `wait_review` | Waiting | The task is submitted and no reviewer has started. It names the provider rule as its cause when that rule refused a reviewer who was otherwise eligible. | The review |
| `review` | Working | A reviewer is checking the work. | The review criterion |
| `wait_builder` | Waiting | The task is waiting for its builder after a failed review or an approved action: the builder has a fresh lease and has not yet acknowledged the briefing under it, or an approved action waits for a builder that holds something else. | The review, or the first approved action not yet reported done |
| `rework` | Working | The builder is fixing the work after a failed review, from its acknowledgement of the briefing under the fresh lease until it submits again. | The review |
| `wait_owner` | Waiting | A hold that waits on the owner or the project is open. The table under Holds says which reasons those are. | The oldest open hold |
| `wait_seat` | Waiting | The seat holding the task is paused. | The seat |
| `wait_limit` | Waiting | The task is held with `credential_limit`: none of the seat's candidates is available and none is signed out. | The candidate that resets first |

Things that do not block the task open no step. A non-blocking question, a cost report and an instant app-run check each keep their own times on their own rows.

The contract's step table records these openings and closings: `review.failed` and an action's approval open `wait_builder` when they give the builder a fresh lease; `action.lease_granted` keeps `wait_builder` open, because its kind and subject do not change; `task.briefing_acknowledged` closes it and opens `rework` or `finish`; `task.submitted` closes `rework`; `action.reported_done` or `task.done` closes `finish`.

### What can be measured

| Question | Computed from |
| --- | --- |
| Where does task time go? | Step durations summed by kind and class. |
| How long did each acceptance criterion take? | `build` steps by criterion, with unattributed build time shown apart. For the review criterion, `wait_review` plus `review`. |
| How long does each rule take to check? | Rule check attempts: queue time is started minus queued, run time is finished minus started. Queue time is shared, because one orchestrator runs checks one after another. |
| How long did a rule hold tasks up? | For each check that blocked a transition, finished minus queued, less any part of that interval spent in a `wait_owner` step. Added to that: `wait_owner` steps whose hold a failed or errored check of that rule opened, and `wait_review` steps that name the rule as cause. A `check` step with several checks is credited to the one that finished last. |
| What does a rule cost in tokens? | The tokens and spend on its jobs' results. |
| How often did a rule apply, stop something, or get overridden? | Rule check rows counted by result. |
| How long do tasks wait on the owner, and for what? | `wait_owner` steps by hold reason. |
| How long did an interrupted run take to recover? | Recovery time: from the `credential.limit_reached` or `credential.signed_out` event to `credential.switched` when another credential takes over at once, and otherwise to the first event written for the task by the seat that continues it. Reads and heartbeats write no event and do not end it. |
| How long did a task take in all? | Its `task.done` time minus the start defined in rule 7. |

An open step is measured up to the present. Version 1 serves these as read-only queries and shows the per-task timeline on the task page.

## Rule checks

A rule is data: a hook, a scope, a checker and what happens on failure. The app runs it. No agent is trusted to have followed it.

### The rule record

| Field | Meaning |
| --- | --- |
| `key`, `name` | A stable key and the one-line name shown in Settings. |
| `hook` | The moment the rule runs. One hook per rule. |
| `scope` | Which tasks it covers: all tasks, named projects, or tasks that end in given outward actions. A model-checked rule can also use "let the checker decide". |
| `kind` | `gate` passes or fails, and a failure blocks the transition. `policy` chooses what happens at the hook and is recorded as applied. |
| `checker` | `app`: a built-in function with typed parameters. `model`: an instruction text judged by a seat role, by default the orchestrator. |
| `on_fail` | Gate rules only. `block` (default) or `warn`, which records the failure and lets the transition through. A `warn` rule never makes the caller wait. |
| `route` | Gate rules only. Who receives a failure: the builder, the orchestrator or the owner. |
| `queue_timeout`, `run_timeout` | Limits for a model check. |
| `enabled`, `origin`, `version` | On or off, shipped or custom, and the current version number. |

Every save creates a new immutable version, and every rule check stores the version it ran against. Revert to default writes the shipped fields as a new version.

Text and behaviour cannot drift apart. For a model-checked rule the text is the instruction, so editing it changes what is enforced. For an app-checked rule the sentence in Settings is generated from its parameters, and the owner edits the parameters.

### Hooks

| Hook | Moment | Checkers in version 1 | If a gate fails |
| --- | --- | --- | --- |
| `task.before_ready` | A task is about to enter Ready. | App and model | The task stays in Backlog with a `contract_incomplete` hold and the reason. |
| `task.before_claim` | A seat asks to claim a task. | App and model. A model check makes the claim provisional | The claim is refused and the task stays in Ready. |
| `task.before_submit` | The builder submits for review. | App and model | The submit is refused. The builder keeps the task and receives the reason. |
| `task.before_done` | The review has passed. | App and model | It counts as a failed review with the rule as the failed criterion: the round goes up and the task returns to its builder. `review.passed` is written only when the move commits. |
| `action.requested` | The server asks approval for an outward action. It runs once per action. | App and model | The action is stopped and a Needs you item opens. An error in the approval policy after its retry passes the action to the owner with `owner_approval`. An offline orchestrator is handled as in When a check cannot run. |
| `review.assign` | A reviewer asks to claim a review. | App only, policy | The reviewer is refused. |
| `review.failed` | A review fails. | App only, policy | Not a gate. It decides who may take the rework. |
| `question.asked` | A worker asks a question. | App, policy | Not a gate. It decides where the question goes. |
| `cost.reported` | A seat reports spending, or a job result or a review verdict reports what it used. | App only, policy | Not a gate. It can pause the project. |

### How a transition is gated

1. The server applies due timers and validates the command against the state machine.
2. It loads every enabled rule bound to the transition's hook. That set of rules and versions is frozen for this request.
3. It decides fixed scopes itself, at no cost. A rule whose scope does not cover the task gets a `not_applicable` row and nothing else runs for it.
4. App checkers run inside the transaction.
5. If a blocking model checker applies, the server stores the pending transition, queues one job per check, opens a `check` step and answers "pending". A rule with the scope "let the checker decide" uses the same job: the checker may answer `not_applicable`, with its reason. There is no separate applicability job.
6. When every check has a result and no hold is open on the task, the server validates the state and the app checkers again, and confirms that each model check's input hash still matches the current inputs. A mismatch cancels the transition and withdraws its checks, as a lost lease does. If a blocking check ended in `error`, the transition stays pending under a `check_error` hold (see When a check cannot run). Otherwise the server completes the transition if each gate passed, did not apply, was withdrawn or was overridden, and if a gate failed it refuses the transition and routes each failure.
7. Every rule check row, gate or policy, writes a `check.finished` event. Policy rules at `question.asked` and `action.requested` always write a row. Policy rules at `review.assign`, `review.failed` and `cost.reported` write a row only when they change the outcome.

A rule check result is one of `passed`, `failed`, `not_applicable`, `applied` (policy rules, with the effect), `error` or `withdrawn`.

### Pending transitions

- A task has at most one pending transition and stays in its earlier state while it is pending.
- The holder, or the reviewer holding the review, may heartbeat, release, read and report cost. Its other commands are refused with `pending`.
- The lease keeps running. If it expires, the pending transition is cancelled and its checks are withdrawn.
- A contract edit, in any state, cancels the pending transition and withdraws its checks and jobs in the same way.
- A hold opened while a transition is pending does not cancel it. Its checks keep running, and the result is applied when the last hold lifts. A provisional claim's reservation lapses when a hold opens. While the hold is open, the open step is the hold's waiting step, not `check`.
- A rule edited during a check does not affect it: the frozen version's result stands. A rule turned off or removed during a check withdraws that check, and the transition completes if nothing else blocks it. A rule turned on during a check does not apply to this request.
- A transition refused because a gate failed is final for its key. The holder fixes the cause and sends the command again with a new key.
- An override of a failed check completes nothing by itself. It stores the result, and the requester's next request with the same inputs reuses it and completes. The server raises the `command` kind of `GET /v1/next` for the refused command's key, so the seat knows to send it again. For a move to Ready the requester is the owner or a planner, and the Mac app sends Complete contract again after the override.
- A check that ended in `error` is not a refusal. Its transition stays pending and completes in place when the check is re-run, overridden or withdrawn.
- At `task.before_done` a failure has already become a failed review, so an override there is recorded against the rule and the rework goes on. At `action.requested` the server is the requester, so an override is the owner approving the stopped action.
- Checks at `action.requested` are not pending transitions. They are keyed per action with an empty `command_id`, and the task's state does not change while they run.

### A rule on the move from Ready to In Progress

The owner adds such a rule in Settings, Rules, with the moment "before an agent starts a task". It runs at the `task.before_claim` hook, every time a seat tries to claim.

- A claim that waits on a model check is provisional. The task is reserved for that seat and no other seat can claim it.
- The seat gets no lease and no briefing until the check passes. It learns the outcome from `GET /v1/commands/{key}`.
- If the check fails, the reservation lapses and the task returns to Ready, and the reason goes to the seat. If it ends in `error`, the reservation also lapses, the task gets a `check_error` hold, and the errored check is not queued again, because no claim is left for it to complete. Run it again, or the orchestrator coming back online, closes the hold, so the next claim runs the check afresh. An override applies to that seat's next claim.
- A task that fails this gate for 3 different seats is held with the reason `claim_gate_failed` and opens a Needs you item, because the rule is then about the task and not the seat. A check that ends in `error` does not count toward the 3 seats.

A rule about the task alone belongs at "ready to start", where it runs once and keeps no agent waiting. "Before an agent starts" is for a rule that depends on which agent takes the task, or that must hold at the moment work begins. Settings, Rules shows every rule's moment on its row.

### When a check cannot run

- A model check that is not started within its queue timeout, or not finished within its run timeout, is queued once more as a new attempt. A second miss gives the result `error`. A job result that arrives after its timeout is discarded. The call is refused with `invalid_state`.
- An `error` on a blocking rule leaves the transition pending and holds the task with the reason `check_error`. Like an owner hold, this hold pauses the lease clock. If the orchestrator is online, a Needs you item opens for that task with three choices: run it again, override it once, or turn the rule off. The hold closes when the check is re-run to a result other than `error`, is overridden, or is withdrawn because its rule was turned off. Step 6 of How a transition is gated then runs on the new results and completes or refuses the transition. The holder does not send the command again.
- The orchestrator counts as offline when no enabled seat with the needed role has polled for 90 seconds. A seat the app runs that has no available candidate stops claiming jobs, and when every enabled seat of a role is in that state the role counts as offline too. The orchestrator runs on the owner's Mac through the helper, so it is also offline while the Mac is off or the helper is not running. The server then opens one workspace-level Needs you item, "Orchestrator offline, N checks waiting", not one per task. When an account is the cause, the item names the account and its reset time, or says that it is signed out. The item opens only while at least one check waits. A seat keeps polling while it works on a job.
- When such a seat polls again, errored checks are queued again on their own, as new attempts, checks still in the queue stay there, and that item closes. A re-run that ends in a result other than `error` closes its `check_error` hold.
- An `error` on a `warn` rule lets the transition through and is recorded.
- The sweep records each run. The Mac app shows a system health line, and says so when the sweep is more than two minutes late.

### Check identity, re-runs and overrides

A rule check is keyed by task, rule version, hook, round, subject and a hash of its inputs. The subject is what the hook is about: the seat for a claim or a review claim, the question, the action or the cost report. Each run of a check is an attempt with its own queued, started and finished times.

| Hook | Inputs that are hashed |
| --- | --- |
| `task.before_ready` | The contract: goal, criteria, details, outward actions |
| `task.before_claim` | The contract version and the seat |
| `task.before_submit` | The contract version, each criterion's state and evidence links, the handoff note |
| `task.before_done` | The contract version, the review verdict and notes, the evidence links |
| `action.requested` | The contract version, the action's kind and description |
| `question.asked` | The question |

The work itself lives outside the app and is not hashed.

- A stored `passed` or `failed` is reused only for identical inputs. An `error` is never reused.
- A model-checked gate runs at most 3 times per round on changed inputs. After that the task is held with the reason `rerun_limit` and opens a Needs you item. This stops a builder from rewording a note until a model passes it. The count is kept for each rule, hook, round and subject, and starts again when the owner changes the contract. The command that would start a fourth run waits under the hold: an override of that check completes it, and turning the rule off withdraws it.
- The owner can override one failed or errored check, or one held at the re-run limit, for one task. The override stores who, when and why. Overrides are counted per rule, because a rule that is often overridden is wrong or too strict.

### Who may check

- No seat that has held a task may check or review it. A seat has held a task if it ever had a builder lease on it; reviews and jobs do not count, so the same reviewer may review again after a failed round. The set of past holders comes from the `task.claimed` events in the log.
- Only a seat with the role named in the rule's checker may return a verdict. In version 1 the checker role is always orchestrator. A verdict has a fixed shape: a result, a reason of at most 500 characters, and the tokens and spend it used.
- Text written by a builder reaches a checker as quoted material: handoff notes, action descriptions, questions and assumptions. The contract and the rule's instruction are the only authority. Every piece of a task's text, the contract included, reaches the checker inside marked quotations, and its verdict is read only from lines that carry a mark made for that run. A checker's reason reaches a builder as quoted material too.
- A job's context is limited to the task's own project.

### Shipped rules

Creating a workspace writes `rule.created` for each shipped rule. A workspace created before the Rule checks milestone has no rules; that milestone writes the same events for it once, through the transition function, with the app as actor, with the command Write the shipped rules, which the server runs when it starts for a workspace that has none.

| Rule | Hook | Kind | Checker | When it is off |
| --- | --- | --- | --- | --- |
| Every task needs acceptance criteria | `task.before_ready` | Gate | App. Parameter: minimum count, default 1, not counting the review. | A task can enter Ready with only the review criterion. |
| Every task needs specific details | `task.before_ready` | Gate | Model, the orchestrator | No detail check. |
| Workers ask the orchestrator before they ask you | `question.asked` | Policy | App routes the question. The orchestrator answers from the record, decides, or passes it on. The time and tokens of its answer count as this rule's. | Every question opens a Needs you item. |
| A different provider reviews every task | `review.assign` | Policy | App. It refuses a reviewer whose provider has built the task. It ships on. | Any reviewer seat that never held the task may review. |
| Two failed reviews move a task to a stronger model | `review.failed` | Policy | App. Parameter: threshold, default 2. | Rework returns to the same builder. |
| Projects pause when they reach their budget | `cost.reported` | Policy | App | Spending continues past the budget, and the budget stops being part of claim eligibility. |
| The orchestrator approves outward actions itself | `action.requested` | Policy | Model, the orchestrator. It approves, stops, or passes to the owner. Every approval is listed under Decided for you. | Every outward action waits for the owner. |

A task has specific details when someone who has never seen it could do it, and a reviewer could tell done from not done, from its goal, its details and its acceptance criteria alone.

The budget rule also covers a task's own cap. A task that reaches it is held with the reason `budget` and opens a Needs you item. The cost of a model check counts against the project's budget and never against a task's own cap.

The providers that have built a task are the provider of every credential recorded as doing its build work, in `task.claimed` and in each `credential.switched` written while a builder held the task, and the provider of every seat that held it with no credential. A handoff can add a provider part-way through, so the provider rule compares the reviewer against all of them, not against the first seat's provider. The provider compared is that of the account the review would run on. A login and an API token of one vendor count as the same provider. OpenRouter counts as its own provider. Because the rule ships on, the first run needs two providers connected. When no connected seat may review a task, a Needs you item says that no reviewer is eligible. A seat the app runs whose accounts are all unavailable has no account to review on, so the item also opens while the only reviewers the rule allows are waiting for an account.

Each shipped rule that a model judges has an eval suite: a fixed set of cases with known right answers. The rule must pass its suite before its milestone is done, at a numeric pass bar set for each supported model when the suite is built. The suite for "Every task needs specific details" belongs to the Rule checks milestone. The suite for "The orchestrator approves outward actions itself" belongs to the Questions and approvals milestone. The suite for "Every task needs specific details" has 24 cases. A supported model answers at least 21 correctly, passes at most one that should fail, passes none of the four whose text tells the checker what to do, and repeats nothing from a file such text told it to read. The supported models are the default models of the Claude, Codex and Gemini login tools. An orchestrator may run on any login and model; the Agent roster says which the suite did not cover. The results are in `evals/specific-details/RESULTS.md`.

Some behaviour is built in and is not a rule, so it cannot be turned off:

- The state machine itself.
- Every task is reviewed by a seat that never held it, which means a seat that never had a builder lease on it.
- A builder can change only the task it holds, and a reviewer only the review it holds.
- The handoff rules listed under Credentials. Code runs them, and no model judges them.
- Every builder criterion needs evidence before submit.
- An outward action happens only after the review passes, and always needs an approval from the orchestrator or the owner.
- No work call is accepted before the briefing is acknowledged.

### Custom rules

The owner adds a rule with a name, an instruction, a moment and a scope. The moments offered are plain-language names for five hooks: when a task is ready to start, before an agent starts it (Ready to In Progress), before work is submitted, when the review has passed, and before anything goes out. A custom rule is a model-checked gate that blocks. Its reason goes to the builder, or to the owner for a task that is not yet claimed.

### The briefing

The briefing is what a seat must read before it works on a task.

- **Content.** The system rules whose fixed scope covers the task, every "let the checker decide" rule marked as "may apply", the project brief, the seat's role file and the contract. Role files are four fixed texts shipped with the app, one per role. Their version is the app release, and it is part of the hash.
- **Hash.** It is computed over the versions of those parts, so only a change to something in this task's briefing changes it.
- **Delivery.** The claim returns it, together with the task's work reference, which is not part of the hash. `GET /v1/tasks/{id}/briefing` returns both again at any time.
- **Acknowledgement.** The seat must acknowledge the hash once per lease, and again after any change, before a work call is accepted. An acknowledgement is kept per seat, per lease and per hash. Work calls are start criterion, pass criterion, ask a question, start an action, report an action done, submit and give a verdict. Heartbeat, release, cost report and reading the briefing need no acknowledgement.
- **Changes.** After a change the next work call answers `briefing_changed`. The seat reads the briefing and acknowledges again.
- **Reviewers.** A reviewer gets a briefing too, with the reviewer's role file, and acknowledges it through the review's own call before giving a verdict. Reviewers ask no questions in version 1: a reviewer that needs something fails the review with notes.
- **From the first build.** The acknowledgement is required from the core-loop milestone on, with a briefing that holds only the brief, the role file and the contract. Rules join it in the Rule checks milestone.

Acknowledgement proves delivery, not understanding. The checks are what enforce a rule.

### Precedence

System rules come first, then the project brief, then the role file, then the task contract. In version 1 only system rules are checks. Project brief rules are text in the briefing.

## Agent interface

Agents work through one HTTP interface. Every call carries the seat's token as `Authorization: Bearer`, and every call that changes something carries an idempotency key.

| Call | Seat | What it does |
| --- | --- | --- |
| `GET /v1/next?wait=30` | Any | Waits up to 30 seconds and answers with one item: its kind and its id. Kinds: `none`, `task`, `rework`, `action`, `review`, `job`, `answer`, `briefing_changed`, `command`, `resume`. The table below the calls says what each means. |
| `GET /v1/commands/{key}` | Any | The current outcome of a command this seat sent: pending, completed with its result, or refused with its cause. |
| `POST /v1/tasks/claim-next` | Builder | Claims the next eligible Ready task. Returns the task, a lease, the briefing with its hash and the work reference. Runs `task.before_claim`. |
| `GET /v1/tasks/{id}/briefing` | Holder | Returns the current briefing with its hash, the work reference and, after a failed review, the reviewer's notes. The notes are outside the hash, like the work reference. |
| `POST /v1/tasks/{id}/ack-briefing` | Holder | Acknowledges the briefing hash. |
| `POST /v1/tasks/{id}/heartbeat` | Holder | Renews the lease. |
| `POST /v1/tasks/{id}/criteria/{cid}/start` | Builder | Optional. Announces the criterion being worked on. |
| `POST /v1/tasks/{id}/criteria/{cid}/pass` | Builder | Marks a criterion passed, with evidence. |
| `POST /v1/tasks/{id}/questions` | Holder | Asks a question, with the worker's own assumption and whether the question blocks the work. |
| `GET /v1/tasks/{id}/questions/{qid}` | Holder | Reads the answer. |
| `POST /v1/tasks/{id}/access` | Holder | Says what access the task needs. It holds the task and opens a Needs you item. |
| `POST /v1/tasks/{id}/cost` | Holder | Reports tokens and spend since the last report. Runs `cost.reported`. |
| `POST /v1/tasks/{id}/submit` | Builder | Submits for review with a handoff note and the work reference. Runs `task.before_submit`. The `task.submitted` event records only that the reference changed, never its value. |
| `POST /v1/tasks/{id}/actions/{aid}/start` | Builder | Announces that the builder is about to carry out an approved outward action. Writes `action.started`. |
| `POST /v1/tasks/{id}/actions/{aid}/done` | Builder | Reports that an approved outward action was carried out. |
| `POST /v1/tasks/{id}/release` | Holder | Gives the task back, with a reason from the fixed list in the contract's registry. No free text. |
| `POST /v1/reviews/claim-next` | Reviewer | Claims the next review this seat may take, with a lease, a briefing and the work reference. Runs `review.assign`. |
| `POST /v1/reviews/{id}/heartbeat`, `/release` | Reviewer | Renews or gives up the review lease. |
| `GET /v1/reviews/{id}/briefing` | Reviewer | Returns the reviewer's briefing and its hash. |
| `POST /v1/reviews/{id}/ack-briefing` | Reviewer | Acknowledges the reviewer's briefing hash. |
| `POST /v1/reviews/{id}/verdict` | Reviewer | Passes the work, or fails it and names the criteria that failed. Runs `task.before_done` on a pass. It carries the tokens and spend the review used, which run `cost.reported` for the task's project. |
| `POST /v1/jobs/claim-next` | Orchestrator, planner | Claims the next job: a rule check, a question, an approval or a contract draft. |
| `POST /v1/jobs/{id}/result` | Job holder | Returns the result in the fixed shape for that kind of job, with the tokens and spend it used. A contract draft's result is the Complete contract command. |

Each accepted job result also writes `cost.reported` with the job as subject. It adds to the project's spent and runs the project budget rule, never a task's own cap.

`GET /v1/next` does not consume what it returns. It repeats the first true item in this table, read from the top, until the seat acts.

| Kind | True when | Id | Cleared when |
| --- | --- | --- | --- |
| `command` | A command this seat sent is no longer pending, or a check that refused it has been overridden. | The command's key | `GET /v1/commands/{key}` is read. |
| `briefing_changed` | The briefing of the task or review the seat holds has changed since the seat acknowledged it. | The task | The seat acknowledges the new hash. |
| `resume` | A hold on the seat's task has closed. | The task | The holder's next accepted call. |
| `answer` | An answer to a question the seat asked is ready, or was overturned. | The question | The question is read. |
| `action` | An approved outward action waits for this seat under a fresh lease. | The task | The seat acknowledges the briefing under that lease. |
| `rework` | A review failed and the seat has a fresh lease on the task. | The task | The seat acknowledges the briefing under that lease. |
| `review` | `POST /v1/reviews/claim-next` has a review for this seat. | None | The seat claims it, or none is left. |
| `job` | `POST /v1/jobs/claim-next` has a job for this seat. | None | The seat claims it, or none is left. |
| `task` | `POST /v1/tasks/claim-next` has a task for this seat. | None | The seat claims it, or none is left. |
| `none` | Nothing above is true. | None | Any row above becomes true. |

### Roles

A seat has one of four roles. Evidence is an `https` link or a note that locates proof inside the work reference, and either one satisfies the built-in rule that every builder criterion needs evidence. Links are never fetched by the server and are shown as plain links. A work reference or an evidence link that carries sign-in details (a user and password in the address, or a token in the query) is refused.

| Role | May change | May read |
| --- | --- | --- |
| Builder | The task it holds | That task's contract, criteria, evidence, questions and work reference, its project's brief, and the notes of its task's failed reviews |
| Reviewer | The review it holds | The same, for the task under review |
| Planner | The contract of the task its job names | That task and its project's brief |
| Orchestrator | The result of the job it holds | The task its job names and that task's project. Nothing from other projects. |

### Behaviour every client can rely on

- **Claiming is atomic.** The server picks the task, by priority and then age, and two seats can never receive the same one.
- **Eligibility.** A seat can claim when it is enabled, its role may build, it holds no task, review or provisional claim, no approved action is waiting for it, it meets the task's minimum strength rank, the project is running, and the task has no hold and no pending transition. While the budget rule is on, the project must also be under budget. A seat the app runs is eligible only if one of its candidates is available (see Handoff). The same applies to review claims and job claims, except that the task's hold does not stop a job claim: a hold opened while a transition is pending leaves its checks running (see Pending transitions).
- **Leases.** The lease length is a workspace setting, 60 minutes by default. A heartbeat renews it.
- **Pending answers.** A call that meets a model-checked gate answers `202 pending`. The seat learns the outcome from `GET /v1/commands/{key}` or from `GET /v1/next`.
- **Specific refusals.** Refusals name their cause: `not_holder`, `not_eligible`, `forbidden` (wrong role for a call other than a claim), `invalid_state` (the command is not allowed in the task's current state), `briefing_not_acknowledged`, `briefing_changed`, `criteria_incomplete` (submit before every builder criterion has passed with evidence), `blocked_by_rule` (with the rule and the reason), `pending`, `on_hold`, `lease_expired`, `task_cancelled`, `credential_in_use` (removing a credential that a seat uses or that open work records), `duplicate_name` (a credential name already used within its provider and kind). When several causes apply, the first in this order is returned: `lease_expired`, `task_cancelled`, `not_holder`, `forbidden`, `invalid_state`, `pending`, `on_hold`, `briefing_not_acknowledged`, `briefing_changed`, `criteria_incomplete`, `blocked_by_rule`, `credential_in_use`, `duplicate_name`. `not_eligible` applies to claims only. `credential_in_use` and `duplicate_name` are owner refusals and apply to owner commands only. A held task answers `on_hold`, whatever the hold's reason. Transport codes (not found, a key reused with a different body) are defined in the interface schema.

### Clients

Two clients ship with version 1. A reference runner signs in as a seat and loops through claim, work and submit with a model. It can hold any of the four roles. It is what the helper starts for a seat the app runs: it drives the provider's own tool without a screen. It is built for Claude first.

An MCP server exposes the same calls as tools. It heartbeats for the agent only while the agent has made a tool call in the last 10 minutes, so a stuck agent still loses its lease. Whether an MCP agent can work with no custom code at all is not yet tested. An agent connected through the MCP server is a seat that connects on its own: it has no credential and never hands off.

A seat that connects on its own starts from a landing prompt, which the owner copies from the Agent roster when connecting it. The prompt tells the agent where the server is and how it signs in, to read its briefing, with its role file and its rules, before any work, to tell its user its defaults and confirm them (it checks for work every 20 minutes when it has none, takes one task at a time, and releases a task it cannot finish), and to ask its user what it needs before it starts. The prompt never contains the seat's token.

### Owner interface

The Mac app uses a separate interface on the same server, with a signed-in session. Its commands are part of the contract and run through the same transition function: create the owner's sign-in, sign out, add, promote, complete and edit a contract, ask a planner to draft a contract, change a task's priority or project, cancel, hold and resume, return a task for rework, allow one more round, run a check again, answer, overturn, approve or stop an action, waive an action, mark an action done, offer a task again, grant access, override a check, save, switch, revert and remove a rule, create a project, edit a brief, pause and resume a project, change a budget or a task's cap, connect, pause, resume, change and remove a seat, start and stop a seat the app runs, issue the helper's token, delete content, change workspace settings, and the Credentials commands listed under What this adds to the contract.

### Helper interface

The helper is a separate program on the owner's Mac. It stays separate while the server's containers run on the same Mac, as they do for the first run, so that moving the server later changes nothing in it. It signs in to the server with its own token, and its calls are part of the contract. Through them it learns what the server wants done on the Mac: start or stop a seat the app runs, run the checks of Add credential, install a provider's tool, open a provider's sign-in window, or read usage. Through them it reports what happened: a run started or stopped, a limit was reached, a login was found signed out, the result of each check, and each usage reading.

The helper acts as the app. Its reports go through the transition function, and it never writes an event or changes a task itself. When it starts a seat the app runs, it receives that seat's fresh token from the server and hands it to the run. No subscription login, sign-in token, sign-in link, code or API token is ever sent in these calls.

## Credentials

A credential is how a seat reaches its provider: a subscription login used through the provider's own tool on the owner's Mac, or an API token. The Credentials screen has its own tab in the left pane. It lists them and shows what each provider reports about limits. The order in which one takes over from another is on the Handoff tab. The approved mock-up in the prototype is the design reference.

A credential is not the seat's own token. The seat token signs a seat in to this app. The credential signs it in to its provider.

Credentials live on the owner's Mac. A login stays inside the provider's own tool, and an API token stays in the macOS Keychain. Neither ever reaches the server or its database, wherever the server runs. The server keeps only the fields listed for `credentials` and `credential_readings` under Data model. It never keeps the secret, the settings folder or the keychain reference, and every other record names a credential by its id only. The helper does everything that uses a credential: it starts the provider's tool, runs the checks, reads usage and reports to the server. No secret appears in the repository, a log, an event, a test fixture or a screenshot.

leverage shares nothing with any other program on the Mac: no code, no usage readers, no storage and no credentials. The one sign-in it cannot keep apart is Antigravity's, which that tool holds once for the whole Mac (see Two kinds). Every reader is written and tested in this repository.

### Two kinds

| Kind | Providers | How the app uses it | What the app keeps |
| --- | --- | --- | --- |
| Login | Claude (Claude Code), Codex (OpenAI), Gemini (Antigravity), Grok (Grok Build) | The helper runs the provider's tool without a screen, pointed at that account's settings folder. | On the server: the fields listed for `credentials` under Data model. On the Mac: a settings folder the helper creates for that account, except for Gemini, whose tool has one sign-in for the whole Mac. Never the sign-in token. |
| API token | Claude API, OpenAI API, Gemini API, Grok API, OpenRouter | The helper calls the provider's API to check the token and to read what the provider reports. What carries out a task on a token is an open decision. | On the server: the same fields, with a masked label made on the Mac. On the Mac: the token, in the macOS Keychain. |

- Logins and API tokens are listed in separate sections, each grouped by provider. A provider with no credential is not shown.
- Two accounts of one provider are two credentials with separate limits. Claude and Codex keep each account in its own settings folder. How Grok Build keeps an account is not yet captured; until it is, a Mac holds one Grok login. The helper creates that folder and never adopts one that another program created.
- Antigravity has one sign-in for the whole Mac, so a Mac holds one Gemini login. Every program on that Mac that uses the tool uses that sign-in, and leverage does not manage or copy it.
- A login and an API token of one vendor count as the same provider. OpenRouter counts as its own provider.
- Each credential carries a model, an effort setting and a strength rank. They are used when work reaches the credential by handoff from another provider. Add credential sets the strength rank to 1, leaves the effort setting empty, and sets the model to the one the provider's tool names as its default; where the tool names none, the model stays empty, which means the tool's own default.
- A seat the app runs has exactly one credential. The helper starts and stops it. A started seat is the reference runner, which polls and claims as that seat. For each claim it drives the provider's tool without a screen, pointed at the settings folder of the credential that claim runs on. A seat that connects on its own, any MCP agent included, needs no credential, never hands off, and is never held for `credential_limit` or `credential_signed_out`.
- Each time the helper starts a seat the app runs, the server issues that seat a new token, stores only its hash and ends the previous one. The token reaches the run through the process environment. It is never put on a command line, written to a file, logged or stored in an event. Each run gets only its own token.
- A credential that a seat uses, or that an open task, review or job records, cannot be removed.
- An API token is never returned by any interface after it is saved, and it never reaches the server. The app never reads, copies or decrypts a provider's sign-in token.

### Adding a credential

One button, Add credential, opens a pop-up with two steps. The owner never has to find the next thing to click, and never opens a terminal.

1. **Pick.** A login for one of four providers, or an API token for one of five.
2. **Name it.** A token is pasted here too. One button: Sign in for a login, Add for a token.

The app then runs the checks itself through the helper, ticks each one off, saves the credential and closes the pop-up.

- **Login checks.** The tool is installed. It is signed in, to the folder the helper created for this account or, for Gemini, to Antigravity's one sign-in for the Mac; if not, the app opens the provider's own sign-in window and waits. One short test prompt gets an answer.
- **A missing tool.** The helper checks whether the provider's tool is installed. If it is not, the pop-up shows what will be installed and from where, and the helper installs it after the owner confirms.
- **Sign-in.** It happens in the provider's own sign-in window. leverage never sees a password, a sign-in link or a code.
- **Token checks.** One small request from the helper confirms the token works. The helper then reads what the provider reports about it. The pasted token stays on the owner's Mac. It goes into the macOS Keychain and is never sent to the server, in the Add command or in any other call.
- **A failed check** stays in the pop-up with one line saying what failed and one Retry button.
- Names are unique within a provider and kind.

### What each account shows

Each account is one row: a status dot (active or signed out), the name, the plan and account email where the provider gives them, and one small tile per figure. A limit tile shows percent used and the reset time. Actions sit behind one menu: rename, verify, sign in again, remove.

- Only figures the provider supplied are shown. Nothing is estimated, and a real zero shows as 0.
- Every login account shows its available resets. A provider with no resets shows a dash.
- Each reading keeps the time it was observed. A reading older than 10 minutes shows its age.

| Login | Read from | Figures | Resets available | How sure |
| --- | --- | --- | --- | --- |
| Claude | The tool's own usage report: `claude -p /usage --output-format json` | Week for all models, week per model, and the 5-hour session | The count and kind, from the usage reply the tool caches in the account's settings folder (`cachedUsageUtilization.utilization.cedar_ember`). Kinds: 5-hour, weekly, per-model, full. | The usage report was run on 18 Nov 2026. The reset entry is undocumented and has only been seen empty. |
| Codex | Its app-server: `account/rateLimits/read` and `account/usage/read` | 5-hour and weekly windows, lifetime tokens, peak daily tokens | `rateLimitResetCredits.availableCount`, with each reset's expiry date | Rate limits and resets were read live on 18 Nov 2026 and are documented. |
| Gemini | Antigravity's usage screen, captured from the terminal | What that screen shows | None found | Not yet captured. Every Gemini fact in this PRD is unverified: Google's subscriber tool changed on 2026-06-18 from the Gemini command-line tool to the Antigravity command-line tool. Track G records a reply before writing the reader. |
| Grok | Grok Build's usage screen, captured from the terminal | What that screen shows | None found | Not yet captured. Track G records a reply before writing the reader. |

A reader's output shape is provisional in the contract until a real capture of that provider's limit output and sign-out output exists. Each capture records the version of the tool it was taken from, and each reader names the versions it was tested against.

| API token | Validity check | What it reports |
| --- | --- | --- |
| OpenRouter | `GET /api/v1/key` | Spending limit and what is left, use today, this week and this month, free tier, expiry |
| Claude API | `GET /v1/models` | Rate limits, from the headers of each reply |
| OpenAI API | `GET /v1/models` (not verified) | Rate limits, from the headers of each reply |
| Gemini API | `GET /v1beta/models` | Nothing beyond valid |
| Grok API | `GET /v1/api-key` | Key name, team, and whether it is blocked |

Account balance and spend need an admin or management token at every provider. They are not in version 1.

### Reading usage

- The helper reads usage on Refresh and every 10 minutes, with a 15-second limit per account, and reports each reading to the server.
- One account that fails shows "unavailable" on its own row. It never blanks the others.
- A read never signs in or out, never opens a browser and never spends a reset.
- Verify runs the add checks again, for one account or for all.
- Readings are stored with their observed time. They are not events.
- Readings and limit events store figures and times only, never the raw provider reply or its headers.
- Resets are shown, not spent. Using a reset from the app is not in version 1.

### Handoff

Handoff is what keeps work going when a credential stops. A credential stops when a run on it hits a provider limit, or when it is found signed out during a run. The work then moves to the next credential in the handoff order. Handoff has its own tab in the left pane, called Handoff. The tab shows the handoff rules as fixed sentences, and the handoff order.

The handoff order is one list of every credential, whatever its provider. Each row names the credential it hands off to, and the last row hands off to nobody.

- The owner reorders the list by dragging a row up or down. A line shows where the row will land, and a hint above the list names the position.
- Up and down buttons on each row do the same from the keyboard.
- A new login is placed above the first API token. A new token goes last, because tokens are billed per use. Until the owner reorders, that is the order: logins above API tokens, in the order they were added.
- The tab shows account names only, never an email or a token.

The handoff rules are fixed in version 1, and only the order can be changed. They are built-in behaviour that code in the server runs, as a deterministic checker. No model judges them. They are not rule records: they have no model checker, no versions and no switch, like the built-in behaviour listed under Shipped rules. The tab shows them in these words:

1. When an account reaches its limit, it rests until the reset time the provider gave.
2. Work moves to the next account below it in the order that is signed in and under its limit. Accounts above it are not tried.
3. An account found signed out is passed over, and work moves on in the same way.
4. Work may move to an account of any provider.
5. Moving on is always automatic, between two accounts of the same provider too. There is no switch for it.
6. An agent goes back to its own account for its next task once that account has reset.
7. Every piece of work records which account did it.
8. If no account below is free, the task waits. Its card says which account it is waiting for and when that account resets. If one of the accounts is signed out, the app asks you to sign in again.

The rest of this section says exactly what those sentences mean.

**Candidates.** The candidates for a seat are its own credential and every credential below it in the handoff order. A candidate is available when it is signed in and not limited. An API token keeps its place in the order but is not available, and cannot be the credential of a seat the app runs, until what carries out a task on a token is decided (see Open decisions). Two more conditions apply to one piece of work. A credential of another provider whose strength rank is below the task's minimum strength rank is passed over. While the provider rule is on, a review passes over every credential of a provider that has built the task.

**What counts as a limit.** A limit is a refusal on a window that the readings carry as kind limit: 5-hour, weekly, per-model or spend. A shorter rate-limit refusal is retried in place and is not a limit. A refusal is reported as a limit only when the provider's reply names one of those windows.

**Detection.** The helper detects a limit or a sign-out from the provider tool's output, by fixed rules in code, and reports it to the server through the helper interface. The reference runner the helper started is what reads the tool's output. It applies those rules, which are one piece of code the helper shares, and passes the helper only the kind of stop, the window and the reset time. The helper sends the report. The transition function does the rest. The helper never changes a task.

When a run hits a provider limit:

1. The server writes `credential.limit_reached`, which starts the recovery time, and marks the credential limited until the reset time the provider gave. If the provider gave none, limited until stays empty and the credential is checked again at each usage read.
2. In the same command, if a candidate below that credential is available, the server writes `credential.switched` with the app as actor, and the work is handed off to the first of them. Credentials above it are not tried. The seat keeps its claim, and the helper starts a new run on the new credential. The server asks for that run through the helper interface, naming the credential and the task or review to continue. When no candidate below it is available and the seat's own credential is, the work goes back to the seat's own credential at once.
3. The seat goes back to its own credential for its next task once its limit has reset, or during the task if the task is held and its own credential resets first.

When a login is found signed out during a run, the same happens with a different first event. The server writes `credential.signed_out`, which starts the recovery time, marks the credential signed out, and hands the work to the first available candidate below it with `credential.switched`.

**What the next credential is given.** On a handoff the seat starts a new run on the next credential with its briefing, the passed criteria with their evidence, and the work reference. That is the saved work. Nothing from the previous account's provider session, sign-in or settings folder is carried over, so the criterion that was in progress may be partly redone. Whether the files behind the work reference survived is checked by the owner by hand in version 1, because agents' files stay outside the app.

**Which model continues.** A handoff to a credential of the same provider keeps the seat's model, effort and strength rank. A handoff to another provider changes the model doing the work: the run uses the model, effort and strength rank set on that credential.

**What is recorded.** Every claim, job and handoff records which credential did the work, as the credential's id in the event payload, with the model actually used. The id is carried in the payloads of `task.claimed`, `review.started`, `job.claimed` and `credential.switched`. Payloads never carry a credential's name, email, plan or settings folder. A handoff is the `credential.switched` event. A new task starts on the seat's first available candidate, recorded in the claim's payload. When a builder gets a task back under a fresh lease, the run starts the same way, and the server writes `credential.switched` if that is not the credential last recorded for the task. A run is on one credential for its whole life. The server moves an idle seat's run to its first available candidate, within one sweep, and a claim is not eligible until the run is there.

**Who may review afterwards.** A handoff to another provider adds that provider to the providers that have built the task (see Shipped rules). The provider rule refuses a reviewer from any of them.

When no candidate is available:

- **A builder's task is held.** The reason is `credential_signed_out` when at least one candidate is signed out, because the owner can end the wait by signing in again. Otherwise it is `credential_limit`. The hold closes as soon as one candidate is available, and the task resumes on that credential with `credential.switched`.
- **Waiting on a limit.** Under `credential_limit` the lease keeps running, the task is not in Blocked and its step is `wait_limit`, so time lost to provider limits shows in the timing data. The task card and the task page name the account waited for and its reset time. No Needs you item opens, because there is nothing for the owner to do. The helper has stopped the run, so no heartbeat is sent. The task resumes after the earliest reset among the candidates, or returns to Ready when the seat's lease ends first, where any eligible seat may claim it with its passed criteria kept.
- **A limit with no reset time.** If no candidate has a reset time, the hold is still `credential_limit`, and a Needs you item opens naming the account. When a later reading shows capacity, the server clears limited until and closes the hold through the transition function, with `hold.closed`. No event type is added for it. Until the usage readers arrive, a Verify of the account that passes counts as that reading.
- **Waiting on a sign-in.** Under `credential_signed_out` the lease clock pauses, the task shows in Blocked and its step is `wait_owner`. A Needs you item opens that names the account and asks the owner to sign in again, and the Mac app sends a macOS notification. Sign in again opens the provider's own sign-in window. The hold closes when `credential.verified` is written for a candidate, or when a limited candidate resets, whichever comes first. The app never reads, stores or logs the sign-in token, the sign-in link or the code.
- **Reviews and jobs hand off like tasks.** When no candidate is left for a review, the review is released with `review.released`, caused by `credential.limit_reached` or `credential.signed_out`. The task stays In review and unassigned, and no task hold opens. A seat with no available candidate stops claiming jobs. When every enabled seat of a role has none, the role counts as offline (see When a check cannot run).
- **A seat that connects on its own** never hands off and is never held for a credential.

**Recovery time.** Recovery time is the interval between two events in the log. It starts at the event that records the interruption: `credential.limit_reached` for a limit, and `credential.signed_out` for a sign-out found during a run. It ends at `credential.switched` when another credential takes over at once, and otherwise at the first event written for that task by the seat that continues it. Reads and heartbeats write no event and do not end it. The recovery time ceiling is a workspace setting: the longest recovery time the interrupted-run scenarios may show. It has no value yet. The owner sets it before the Handoff milestone is called done.

### What this adds to the contract

- **Tables.** `credentials`, `credential_readings`, `helpers`, and a credential on each seat the app runs. They are listed under Data model.
- **Events.** `credential.added`, `credential.verified`, `credential.signed_out`, `credential.renamed`, `credential.removed`, `credential.order_changed`, `credential.limit_reached` and `credential.switched`. A sign-out found during a run is `credential.signed_out`. A limit that clears writes `hold.closed` and no credential event.
- **Hold reasons and a step.** `credential_limit` and `credential_signed_out`, and the step kind `wait_limit`.
- **Owner commands.** Add, verify, sign in again, rename, remove, refresh usage, reorder, install a provider's tool, start and stop a seat the app runs, and issue the helper's token.
- **The helper.** A separate program on the owner's Mac. It finds and installs the providers' tools, starts and stops the seats the app runs, detects a limit or a sign-out, runs the checks of Add credential and reads usage. It signs in to the server with its own token, and the contract defines its calls (see Helper interface). The server holds no provider login and no provider code.
- **Build.** One more track, across three milestones. The helper with its launcher for seats the app runs, and Add credential for logins, arrive in the Core loop milestone. Limit and sign-out detection, the two holds and the Handoff tab arrive in the Handoff milestone, directly after it. Adding an API token, the usage readers, reordering and the full Credentials screen arrive in the Credentials milestone.

### Acceptance criteria for Credentials

- [ ] Adding a login through the pop-up takes two steps and ends with the account listed and its usage shown, with no other click when the provider's tool is already installed.
- [ ] A provider's tool that is missing is installed from the pop-up after the owner confirms, with no terminal.
- [ ] A signed-out tool is caught in the pop-up, and the flow continues on its own once the owner has signed in.
- [ ] Two accounts of one provider show separate limits and both stay signed in, for Claude and Codex, and for Grok when two accounts are available.
- [ ] A Codex account shows the same number of resets as the Codex tool reports for it.
- [ ] A Claude account with a reset grant shows its count and kind. This needs an account that has one.
- [ ] A saved token is not returned by any interface, appears only masked, and is never sent to the server.
- [ ] No subscription login, sign-in token, sign-in link, code or API token appears in any request to the server, any log, any event, any test fixture or any screenshot in the repository.
- [ ] One account whose usage read times out shows "unavailable" while the others still show their figures.
- [ ] When a run hits a limit, the next available credential in the order takes over, whatever its provider, and the log records the switch.
- [ ] With every candidate limited, the task is held with `credential_limit` and resumes after the earliest candidate reset, or returns to Ready when the seat's lease ends first.
- [ ] A login found signed out during a run hands off like a limit. With no candidate available, the task is held with `credential_signed_out` until a login is verified.
- [ ] Removing a credential that a seat uses or that open work records is refused.
- [ ] Refreshing usage spends no reset and changes no sign-in.
- [ ] The Handoff tab shows the fixed rules and the one order, and has no switch for any rule.

The limit and sign-out lines are shown by replaying recorded provider replies with a near reset time. Recorded replies are scrubbed of account emails, account ids, tokens and plan identifiers before they are committed.

## Data model

These tables are part of the shared contract, which is listed in full under Build order. The database is PostgreSQL, in the server's containers. It holds no provider login and no API token: provider logins stay inside the providers' own tools and API tokens in the macOS Keychain.

| Table | Holds | Key fields |
| --- | --- | --- |
| `workspaces` | One row per owner | Settings: lease length, check timeouts, maximum rounds, re-run limit, recovery time ceiling |
| `users` | The owner's sign-in | Workspace, sign-in identity |
| `projects` | Projects | Name, goal, budget, spent, paused |
| `brief_entries` | Each project's rules, decisions and lessons | Project, kind, text, author |
| `seats` | Connected agents | Name, provider, model, effort, role (builder, reviewer, planner or orchestrator), strength rank, credential (set for a seat the app runs, empty for a seat that connects on its own), enabled, paused, token hash, last polled |
| `tasks` | Tasks | Project (empty for "no project"), title, goal, state (one of eight), round, holder seat (the seat with the live builder lease or the provisional claim), builder seat (the seat that last claimed the task, kept through In review and Finishing), lease due time, lease time left while paused, minimum strength rank, contract version, budget cap, spent, work reference (free text naming a folder, a repository, a branch or a commit; never fetched by the server), priority |
| `criteria` | Acceptance criteria | Task, position, text, kind (build or review), state, passed at, passed by |
| `evidence` | Proof for a criterion | Criterion, kind (link or note), `https` link or a note locating proof inside the work reference |
| `reviews` | One row per review round | Task, round, reviewer seat, lease due time, verdict, failed criteria, notes |
| `questions` | Worker questions | Task, asking seat, text, assumption, blocking, outcome, answer, basis, answered by |
| `actions` | Outward actions named in a contract | Task, kind, description, state (contracted, requested, approved, started, stopped, waived, revoked, done), approved by. Revoked is written only by Cancel. A return for rework puts an action back to contracted. |
| `holds` | Why something cannot move | Task or project, reason, causing rule or credential, opened at, closed at |
| `pending_transitions` | A transition waiting on checks | Task, command key, command, requester, frozen rule versions, state (pending, completed, refused, cancelled; a transition under a `check_error` hold stays pending), reasons, and while it is pending the request it will complete with |
| `rules` | One row per rule | Key, enabled, current version |
| `rule_versions` | Immutable rule versions | Rule, version, every field of the rule record except `enabled` (it lives on `rules`), author, created at |
| `rule_checks` | One row per check | Task, project, rule, rule version, hook, round, subject, input hash, result, effect, reason, override (who, when, why) |
| `rule_check_attempts` | Each run of a check | Check, attempt number, job, checker seat, queued at, started at, finished at, tokens, spend |
| `jobs` | Model work queued for seats | Kind, target, seat role, claimed by, state, queued at, claimed at, finished at, result, tokens, spend |
| `events` | The event log | As specified under Event log |
| `task_steps` | Timed segments of each task | Task, round, kind, class, subject, seat, cause (a rule, or `credential_limit` on a `wait_ready` step), opened at, closed at, opening event, closing event |
| `inbox_items` | Needs you | Kind, what it refers to (a task, a project or the workspace), choices, state, resolved by, resolved at |
| `commands` | Idempotency and command outcomes | Caller kind, caller id, key, command, outcome, stored result |
| `sweep_runs` | Proof the timer sweep is alive | Ran at, tasks touched, workspace timers fired |
| `backup_runs` | Proof the daily backup ran | Ran at, file name, size |
| `credentials` | Logins and API tokens. Never the secret, the settings folder or the keychain reference: those stay on the owner's Mac, where the helper keeps them by credential id. | Kind, provider, name, masked label, plan, account email, state (active or signed out), limited until, position in the handoff order, the model, effort and strength rank used when work reaches it from another provider, last verified |
| `credential_readings` | What a provider reported for an account | Credential, observed at, state, and one entry per figure: label, kind (limit, activity or allowance), percent used, reset time, value |
| `helpers` | The helper on the owner's Mac | Name, token hash, last reported |

Constraints the database enforces, not the application code alone:

- `events` accepts inserts only. The application's database role has no right to update or delete its rows.
- `events` is unique on workspace and `seq`. `command_id` is indexed and not unique, because one command can write several events.
- `commands` is unique on caller kind, caller id and key. This table alone enforces idempotency.
- `task_steps` allows at most one open row per task.
- `rule_checks` is unique on task, rule version, hook, round, subject and input hash.
- A change to `tasks.state` without an event for that task in the same transaction is rejected by a trigger.
- Every table carries `workspace_id` and every query filters on it. Row-level security is added if one installation ever serves several owners.

### What the replay test rebuilds

Replaying the log into empty tables must reproduce exactly these columns:

- `tasks`: state, round, holder, builder, minimum strength rank, contract version. The holder is set by `task.claimed` and by the event that gives a builder a fresh lease (after a failed review, an approved action, or the owner offering the task again), and by `action.lease_granted` when an approved action waited for a builder that held something else. It is cleared by `task.submitted`, `task.released`, `task.lease_expired`, `task.returned` and `task.cancelled`. The builder is set by `task.claimed` and cleared when the task returns to Ready or Backlog or is cancelled.
- `criteria`: state. `reviews`: verdict. `actions`: state.
- `holds`: the open set with reasons.
- `rule_checks`: result, and override (who and when; the reason is text and outside the replay). `rules`: enabled and current version.
- `projects`: paused and spent.
- `task_steps`: every row.

Everything else is outside the replay: text, links, the work reference, lease due times, last polled, job results, stored command outcomes, and the `credentials`, `credential_readings` and `helpers` tables, limited until included.

## What the app shows in version 1

The clickable prototype is the design reference. Version 1 makes these screens real and leaves the rest for later.

One rule covers every word the owner reads: a word on an owner-facing screen that a person trying the app asks about, or stops at, is a defect. As a starting list, these engine terms do not appear on an owner-facing screen without a plain-language replacement: hook, lease, rule version, pending transition, seat, hold, round, strength rank, override and Imaginarium. The table below, and the Needs you choices table under Holds, use the engine's own names to say what each screen holds, not what it says.

| Screen | In version 1 |
| --- | --- |
| Sign-in | The owner signs in. One owner per installation. On a new installation the screen first creates the owner's sign-in. |
| Kanban | Six lanes driven by task state and holds, with Blocked just before Ready, with the project and agent filters, and a filter that shows cancelled tasks. A task waiting on a provider limit says on its card which account it is waiting for and when that account resets. |
| Add task | A form: title, goal, acceptance criteria, who it is for and what it must include or avoid, outward actions, project, priority (optional, normal by default) and an optional "Where the work is" field. Saving runs `task.before_ready`. A failed check keeps the task in Backlog and shows the reason. |
| Task page | Contract, criteria with evidence, where the work is, questions, and the log read from events, which shows every handoff as it happens. A Timing section lists the steps in order with durations, and a rule checklist with each rule's result, reason and time. A failed check has an Override button. A task waiting on a provider limit names the account and its reset time. A task in Backlog has a Draft contract button, which asks a planner to write its contract. |
| Needs you | Questions passed on, approvals, stopped actions, unconfirmed outward actions, access requests, budget pauses, tasks past the round limit, tasks every agent was refused, checks past the re-run limit, rule checks that could not run, accounts signed out during a run, provider limits with no reset time, and tasks no connected agent may review. One item covers an offline orchestrator. Every item has the choices listed under Needs you choices. The Mac app sends a macOS notification when an item opens. |
| Decided for you | Every call the orchestrator made alone: questions it decided and outward actions it approved, marked when they cannot be undone. The owner can overturn a decision. Overturning an approval that has not been reported done stops the action, as in Outward actions. Overturning one already reported done is recorded and changes nothing, and the screen says so. |
| Activity | The event log as a feed, with the Important and Everything filter. No chat. |
| Agent roster | Seats with provider, model, effort, role, on or off, and last polled. Connecting a seat the app runs picks its credential and starts it, and no token is shown. Connecting a seat that runs on its own creates its token and shows it once, and shows a landing prompt to paste into that agent. |
| Projects | The list, each brief, budget and pause. |
| Settings, Rules | Each rule's switch, moment, scope, checker, and parameters or instruction. Save, revert to default, add a custom rule. Each row shows how often the rule ran, its average time and its tokens. How often a rule ran counts its checks that applied, and its average time is queue plus run for each attempt. The row also shows how often its checks were overridden. |
| System health | One line on every screen: whether the timer sweep and the orchestrator are running, and whether the daily backup is late. |
| Credentials | Its own tab in the left pane. Logins and API tokens grouped by provider, each account's limits and available resets, Refresh and Verify all, and the Add credential pop-up. Add credential for logins arrives in the Core loop milestone; a row's limit sentence and Sign in again in the Handoff milestone; API tokens and the rest in the Credentials milestone. |
| Handoff | Its own tab in the left pane. The handoff rules as plain sentences, with no switch, and the one order of accounts, which the owner can reorder. The tab and the default order arrive in the Handoff milestone, reordering in the Credentials milestone. |

Settings has four sections: Rules, Skills, Roles and Analytics. Later: the Analytics section, the Skills and Roles sections, Routines, the Activity chat and the orchestrator conversation.

## Quality requirements

| Area | Requirement |
| --- | --- |
| Atomicity | A command commits its state change, events, steps and rule check rows together, or changes nothing. |
| Ordering | Events are ordered per workspace in commit order. A reader that follows `seq` never misses a committed event. |
| Idempotency | Repeating a mutating call with the same key writes nothing new and returns the command's current outcome. Keys are kept for at least 7 days. |
| Clocks | Every duration comes from the database clock. Timer events carry their due time, and no step has a negative duration. |
| Timers | Due timers are applied before any command on the same task. A sweep triggers the rest, including workspace-scoped timers such as the orchestrator-offline detector, at least every 30 seconds and records each run. |
| Speed | App-run checks add at most 50 ms to a transition at the 95th percentile; measured at 1.1 ms with 50 active seats and the shipped rules on in the Rule checks milestone, on 2026-11-20. Writing events and steps adds at most 20 ms at the 95th percentile; measured at 4.7 ms with 50 active seats on 2026-11-19. |
| No silent waiting | If the orchestrator is offline, the owner sees one Needs you item within 120 seconds, and waiting checks queue again on their own when it returns. The Mac app sends a macOS notification when work stops and needs the owner, which is each time a Needs you item opens. |
| Security | Seat tokens are stored hashed, are revocable and are sent as bearer tokens. The token of a seat that connects on its own is shown once. A seat the app runs receives only its own token, issued fresh each time the helper starts it and never shown. Each role reaches only what the Roles table allows. Results returned by models are validated against fixed shapes and treated as data. Provider logins stay inside the providers' own tools and API tokens in the macOS Keychain, and neither reaches the server or its database. No secret appears in the repository, a log, an event, a test fixture or a screenshot, and records name a credential by its id only. |
| Privacy | Event payloads hold no content and name a credential by its id only. The server sends content only to seats. The roster shows each seat's provider, and a handoff to another provider shows in the task's log as it happens. Deleting a task's or a project's content leaves its timing intact. |
| Audit | Every rule change, override, approval and hold has an actor and a time. |
| Deletion | The owner can delete the content of a task or a project, and remove a seat or a custom rule. Each writes an event. |
| Backups | The database is backed up daily, by a container that writes a `pg_dump` file to a folder on the owner's Mac and keeps the newest 14, and a restore is tested before release, because the log cannot be rebuilt. Provider logins and API tokens are on the owner's Mac, outside the database and its backup, and are never copied into it. After a restore the owner verifies each account, with Verify all once the Credentials milestone brings it, and signs in again where needed. |
| Migrations | After the core-loop milestone, schema changes are forward-only and never rewrite events. |
| The app's own health | The server logs every refused command and every error, and exposes the sweep's last run and the queue lengths. |
| Fixed lists | The contract's registry file is the authority for hold reasons, event types, refusals and check results. The tables in this PRD stay, and a check in continuous integration fails when one of them and the registry differ. |

Tests that must exist before release:

1. **Replay.** Rebuilding from the log reproduces the columns listed under Data model.
2. **Step partition.** For random command sequences, each task's steps touch end to end and sum to its lifetime.
3. **State table.** Every state and command pair either transitions as specified or is refused. The pairs include Approve action, Stop action, Waive action and Return for rework.
4. **Gate.** For each gated hook, a transition with an enabled gate rule and no result row cannot commit. An outward action cannot be approved while a gate on it has no result. For each policy hook, the rule's effect is tested on and off.
5. **Idempotency.** Every mutating call is repeated and writes once.
6. **Concurrency.** Twenty seats claim at once and no task is claimed twice. A reader tailing by `seq` at the same time never sees a number lower than one it has seen, and never a gap that fills later.
7. **Timers.** A command that arrives after a lease's due time is refused before the sweep has run, and the expiry is recorded at the due time.
8. **Golden traces.** Six to eight command sequences with their exact expected events and steps. Two more are written for a workspace with no rules, for the Core loop milestone, which is built before any rule exists. Five more are written for the Handoff milestone, also for a workspace with no rules. Four more are written for the Rule checks milestone. Every track builds against them. One covers stop, return for rework, pass, approve and done. One has two outward actions and one custom rule at "before anything goes out".
9. **Interrupted run on a limit.** A task whose credential hits a limit after work is saved continues on another credential with its passed criteria and evidence intact. Recorded provider replies stand in for a real limit.
10. **Login found signed out.** A sign-out found during a run hands off, or holds the task with a Needs you item. A recorded reply stands in for a real sign-out.
11. **Recovery time.** Recovery time is the interval between the two named events, and no read or heartbeat ends it.
12. **Registry.** The fixed lists in this PRD equal the contract's registry file. The check fails when a hold reason, an event type, a refusal or a check result is in one and not in the other.

## Build order and tracks

The contract is written first by one person. After that, seven tracks with separate ownership can run in parallel.

### Milestones

1. **Contract.** Everything two tracks touch, written and reviewed before anything else starts:
   - the migrations for every table under Data model;
   - the registry file, which is the authority for the fixed lists: event types with their payload schemas, hold reasons, refusals, check results and release reasons;
   - the check that fails in continuous integration when a table in this PRD and the registry differ;
   - the table of states and commands, for agents, for the owner and for the helper's reports;
   - the step table: which event opens and closes which step;
   - the hook list with what a failed gate does;
   - the job kinds with their input and result shapes;
   - the role table;
   - the interface schema for agents and for the owner, with the `GET /v1/next` response;
   - the helper interface: how the helper signs in, how it learns what to start, stop, check, install or read, and what it reports (started, stopped, limit reached, signed out, check results and readings);
   - the in-process interface between the transition function and rule gating;
   - the generic shape of a credential reading, with the reset-entry form (count, kind, expiry), the reading states, and the report of a limit or a sign-out. A provider's reader shape is provisional until a real capture of that provider's limit and sign-out output exists;
   - the timer list: each timer, its scope (task or workspace), its due-time source and the event it writes;
   - the golden traces.
2. **Core loop.** The transition function with timers, event append, steps and leases. Seat sign-in, idempotency and the agent calls for claim, briefing, pass, submit and review. Account setup: the helper, installing a provider's tool, Add credential for logins, in two steps with its checks, a credential on each seat the app runs, and the helper's launcher, which starts such a seat. The Mac app has sign-in, the board, the Credentials list with Add credential for logins, the Agent roster, Add task and the task page. Owner commands: create the owner's sign-in, sign in and out, issue the helper's token, add and verify a credential, install a provider's tool, connect a seat, start and stop a seat the app runs, add a task, complete its contract, cancel a task, allow one more round, remove a seat. For this first run the server and PostgreSQL run in Docker containers on the owner's Mac. No rules yet. The helper starts the builder and reviewer runners on the logins the owner connected in this milestone, so the owner never starts an agent by hand, and the two seats finish a task end to end, including one failed review. This is the first milestone the owner can use end to end without a terminal. Speed is measured here.
3. **Handoff.** Limit and sign-out detection in the helper. The `credential_limit` and `credential_signed_out` holds, the `wait_limit` step, the handoff transitions, and the record of which credential did each claim and each review. The same record covers each job once jobs arrive in the Rule checks milestone. The Needs you screen, with the item for each hold that waits on the owner, and the macOS notification. The other owner commands the Needs you choices rest on arrive here: promote, edit a contract, hold and resume, and pause, resume and change a seat. The daily database backup and the tested restore. The Handoff tab with its fixed rules and the default order: logins above API tokens, in the order they were added. The launcher already exists. Its acceptance test is the first-sign-in-to-first-Done scenario including an interrupted run: a limit after work is saved, a login found signed out, and one account at its limit while the next is signed out. The recovery time is recorded in each, and the owner sets the recovery time ceiling before this milestone is called done.
4. **Rule checks.** Rule records and versions, hooks, app checkers, the orchestrator seat started by the helper, model check jobs, pending transitions, timeouts, overrides, rules in the briefing, the Rules settings and the Timing section. The eval suite for the specific-details rule, which the rule must pass before this milestone is done. Four of the seven shipped rules are created here and start to act in the Questions and approvals milestone, with the commands their effects need; so do the custom-rule moment "before anything goes out" and the scopes by project and by outward action. Until then a failure routed to the orchestrator is delivered as one routed to the owner is.
5. **Questions and approvals.** Worker questions, outward actions and the Finishing state, escalation, the remaining Needs you items, Decided for you and budget holds. Projects, with their screen and commands, the Activity screen, deleting content, changing workspace settings, and the MCP server over the whole agent interface. The eval suite for the rule that approves outward actions, which the rule must pass before this milestone is done.
6. **Credentials.** The rest of the Credentials screen: adding an API token, the usage and reset readers for each provider, each account's limits and available resets, Refresh and Verify all, and reordering the handoff order.
7. **Analytics page.** Its own PRD, over data collected since the core-loop milestone.

### Tracks

| Track | Owns | Needs first | Verified by |
| --- | --- | --- | --- |
| A. Core engine | Transition function, timers, event append, step tracker, replay. For handoff: the `credential_limit` and `credential_signed_out` hold reasons, the `wait_limit` step, the timer that lifts a credential hold, the handoff transitions and the per-claim credential record | The contract | Tests 1, 2, 3, 6, 7 and 11, and tests 9 and 10 together with G |
| B. Rules engine | Rule records, scopes, checkers, check jobs, pending transitions, overrides, briefing, and the comparison the provider rule makes | The contract, including the gating interface | Test 4, plus timeout and override tests, and the eval suite of each shipped rule a model judges |
| C. Interfaces | Agent, owner and helper HTTP calls, sign-in, idempotency, the sweep trigger, and the owner commands for credentials and handoff | The contract | Test 5, plus tests against the interface schema |
| D. Clients | MCP server, reference runner. The reference runner is what the helper starts for a seat the app runs. | The interface schema | A full task run against C |
| E. Mac app | The screens listed above except the Credentials and Handoff screens and the Add credential pop-up, which are track G's. The Needs you items and the macOS notification. Sign-in, the Agent roster, Add task and the task page in the Core loop milestone. | The owner interface schema and F's queries | UI tests of each screen |
| F. Read queries | Timing and rule queries, the task timeline, recovery time | The tables and the golden traces | Query tests on logs produced from the golden traces |
| G. Credentials | The helper with its launcher for seats the app runs, installing the providers' tools, limit and sign-out detection, the usage readers for each provider, the add flow, and the Credentials and Handoff screens. The launcher and the add flow are delivered in the Core loop milestone, detection in the Handoff milestone. | The contract, A's handoff transitions, C for the owner and helper calls, and D's reference runner, which the launcher starts | The acceptance criteria for Credentials, and tests 9 and 10 together with A. Track G first records a real reply from each of the Claude, Codex, Gemini and Grok login tools, and writes each reader from it. Recorded replies are committed only after account emails, account ids, tokens and plan identifiers are removed. |

Every track starts from the contract. B and C build against the gating and transition interfaces with stubs, then integrate on A. Track A owns all timer logic, and the sweep in track C only triggers it. The same split holds for handoff. Track A owns the two credential hold reasons, the `wait_limit` step, the timer that lifts a credential hold at the earliest reset, the handoff transitions and the per-claim credential record. Track B owns the comparison the provider rule makes. Track C builds the owner commands and track E the Needs you items. Track G's helper detects a limit or a sign-out and reports it to the transition function only through the helper interface in the contract. The server lives in `api/`. The Mac app and the helper live in `mac/`. Test 12 belongs to the contract and runs in continuous integration.

## Release acceptance criteria

Version 1 is done when every line below is shown to hold.

- [ ] A task added through the form reaches Done through a builder seat and a reviewer seat that the app started from the owner's connected logins, with no manual database change and no terminal.
- [ ] Every command in that run that has a row in the lifecycle table wrote the events the table names for it, plus only the rule check, job, hold, Needs you, `credential.switched` and `action.lease_granted` events this PRD requires alongside them, and the replay test passes on its log.
- [ ] The task page shows steps that sum to the task's lifetime to within one second.
- [ ] Every line of Acceptance criteria for Credentials holds. The line on a Claude reset grant is shown only if a test account with a reset grant exists.
- [ ] Each of the Claude, Codex, Gemini and Grok logins can be added and verified through the pop-up.
- [ ] One task reaches Done with its builder connected through the MCP server.
- [ ] A run whose login hits a limit after work is saved continues on another login of the same provider, with its passed criteria and evidence intact.
- [ ] The same run continues on a credential of another provider when that is the next one in the handoff order.
- [ ] A login found signed out during a run hands off to the next available credential. With none available, the task is held with `credential_signed_out`, a Needs you item asks the owner to sign in again, and the work continues once a login is verified.
- [ ] One account reaches its limit while the next one in the order is signed out: the task is held, the Mac app notifies the owner, and after the owner signs in again the work continues with its passed criteria and evidence intact.
- [ ] In each of the four interrupted runs above, the recovery time is recorded and is no longer than the recovery time ceiling, and the app tells the owner what happened in plain language.
- [ ] With the acceptance-criteria rule on, no call can move a task without criteria into Ready. With it off, the same call succeeds.
- [ ] A model-checked rule blocks a submit. The reason reaches the builder and the check's attempts show queue time and run time.
- [ ] Stopping the orchestrator seat the app runs opens one workspace-level Needs you item within 120 seconds. Starting it again queues the waiting checks without any click.
- [ ] An override on a failed check is recorded with who, when and why, and lets the task proceed: for a refused submit, claim or move to Ready, on the seat's next request.
- [ ] Editing a rule creates a new version. Earlier checks still show the version they ran against.
- [ ] A reviewer from any provider that has built the task is refused while the provider rule is on, including a provider the work reached by handoff.
- [ ] A reviewer whose credential hits a limit never continues on a credential of a provider that has built the task.
- [ ] A command sent after a lease's due time is refused before the sweep runs. The steps show waiting in Ready from the due time.
- [ ] A reviewer whose runner is stopped loses the review, and another reviewer claims it.
- [ ] A task with an outward action cannot have it approved before its review passes, and is not Done until the action is reported done or waived.
- [ ] A builder whose lease expires after an approval leaves the task held with a Needs you item, and no other seat can claim it.
- [ ] Every outward action the orchestrator approved appears under Decided for you.
- [ ] Cancelling a task with a pending check withdraws the check, and the holder's next call is refused with `task_cancelled`.
- [ ] Repeating each agent call with the same key writes no second event.
- [ ] No seat can read or change anything outside what the Roles table allows.
- [ ] A database restore from backup passes the replay test.
- [ ] The speed targets are met, or the measured numbers replace them in this PRD.
- [ ] Each shipped rule that a model judges passes its eval suite at the pass bar set for each supported model.
- [ ] The check that compares this PRD's fixed lists with the contract's registry passes.

## Risks

| Risk | Effect | Response |
| --- | --- | --- |
| Agents act outside the app | An agent with its own credentials can publish or send without asking, and the gate is bypassed. | Version 1 gates only what goes through it, and the briefing says so. Keep outward credentials away from agents where possible. Later the app carries out outward actions itself. |
| Agents the app runs share the owner's Mac and user account | An agent with a shell could read another seat's token or reach a provider's sign-in on the Mac, and so get around review or approval. While the server's containers run on the same Mac, it could also reach the database login. | Independent review and approvals are guaranteed for agents that stay within the app's interface, and the briefing says so. Each run is given only its own seat token. The app's records are in the server's database, which is out of an agent's reach once the server has moved off the owner's Mac. Stronger isolation is an open decision. |
| Model checks become the bottleneck | Each model check adds queue time and run time to a transition. | Use app checkers wherever a rule allows. Judge applicability once per task. Show every rule's time. Enforce timeouts. |
| The orchestrator is down | Blocking checks fail closed and tasks stall. The orchestrator runs on the owner's Mac, so this also happens whenever the Mac is off. | One Needs you item appears within 120 seconds, and waiting checks queue again when it returns. The owner can override a check or set a rule to warn. |
| A rule that cannot be satisfied | With one provider connected, the provider rule leaves no eligible reviewer and reviews wait forever. The same happens once every connected provider has built a task, which a handoff to another provider can cause. | The first run needs two providers connected. The server detects, task by task, a review that no connected seat may take, and opens a Needs you item that says no reviewer is eligible. |
| Cost is self-reported | The budget rule depends on what agents report. | Label spend as reported. Reconcile with provider billing later. |
| Task content steers a checker | Text in a task could talk a model checker into passing it. | Fixed verdict shape, the builder never checks its own work, and overrides and verdicts are audited. |
| Evidence is a link or a note | The app cannot verify that evidence shows what it claims. | That is the reviewer's job. The app records the evidence and who attached it. |
| Payload schemas change | Old events become unreadable. | Versioned schemas, readers that handle every version, and the replay test in continuous integration. |
| The per-workspace lock limits throughput | Appends in one workspace run one at a time. | Acceptable for tens of seats. Revisit if a workspace passes about 100 commands a second. |
| Scope | This PRD covers the whole loop, not only logging. | Milestones are separable. The core loop without rules is already useful and already logs everything. |
| A model approves actions that cannot be undone | The orchestrator decides on publishing, paying, sending and deleting, partly from text a builder wrote. | Approval comes only after an independent review. Builder text reaches the orchestrator as quoted material. Every approval is listed under Decided for you. Whether paying and deleting should always wait for the owner is an open decision. |
| Undocumented usage sources | Claude's reset entry and the captured usage screens of Antigravity and Grok Build can change with any tool update. No Gemini or Grok output has been captured yet, and Google changed its subscriber tool on 2026-06-18. | Each reader checks the tool's version and shows "unavailable" instead of a wrong number. A reader's shape is provisional in the contract until a real capture of that provider's limit and sign-out output exists. |
| Running a provider's tool from another app, and moving between two logins of one provider | A provider may not allow either, and may suspend an account. The providers' published documents were read on 2026-11-18. Anthropic's and OpenAI's allow their tool to be driven by another program, with conditions. No Anthropic document read addresses an app that a person runs to drive the unmodified tool under their own login. Neither provider's documents say whether moving to a second account at a limit is allowed, and Anthropic's usage policy bars creating several accounts to get around product limits. xAI's are unclear on both. Google's say that neither is supported on consumer plans, and that using other software to reach the service can lead to suspension. | Each login stays inside the provider's own tool and leverage never reads it, which is the one design that every provider's documents are consistent with. Moving work to a different provider is not account rotation, and no document read restricts it. The reading was done by AI agents, and three of the four providers' terms could not be read in full, so a person should read them before relying on it. API tokens are the alternative. |

## Open decisions

One gate stands before the contract. The contract is not started until these are settled, and nothing else is required first: the eight review findings rated blocker; every review finding from the credentials angle; findings 11, 15, 16, 23, 24, 40, 47, 49, 50 and 67, because each changes something the contract contains; what happens when a login is found signed out during a run; what the next credential or seat is given on handoff (finding 89); who writes the work reference and who reads it (finding 45); five decisions (where it runs together with logins or API tokens, how the orchestrator runs, the first provider, whether this product is Campus, and handoff to another provider); and a check of each provider's terms. This draft settles all of them in the sections they touch, and the owner reviews the whole set before it is merged. A row below that starts with "Decided" records the owner's answer. A row that starts with "Not settled" or "No value yet" is open: it has no working assumption, and it says what waits for it. Every other row keeps its recommendation as a working assumption, which is what this PRD assumes.

| Decision | Recommendation | What depends on it |
| --- | --- | --- |
| Stack and hosting | Decided: the server is a Ruby on Rails application in API mode, with PostgreSQL as its only datastore. The Mac app is native, written in Swift with SwiftUI, and is a thin client of the API. The helper is written in Swift. The server lives in `api/`, and the Mac app and the helper live in `mac/`. | The workspace lock and the state trigger are written for PostgreSQL. |
| Where it runs | Decided: the server and PostgreSQL run in Docker containers, one installation per owner. For the first run the containers run on the owner's Mac. The same containers move to a server the owner controls later. The Mac app and the helper run on the owner's Mac. | Sign-in, the helper interface, and where data is kept: the event log, tasks and rules in the server's database, provider logins and API tokens in the providers' own tools and the macOS Keychain. The helper is a separate program that signs in to the server, so the move changes where the containers run and nothing else. Agents run only while the Mac is awake. A hosted service for many owners is a different build. |
| Logins or API tokens for the first run | Decided: subscription logins. Claude, Codex, Gemini and Grok logins are accepted. API tokens stay in version 1 as a second kind of credential and are not the first-run path. | The helper, getting the providers' tools onto the Mac without a terminal, and the providers' terms (see Risks). |
| How the orchestrator runs | Decided: as a seat the app runs. The helper starts it on a login the owner picks, it pulls jobs like any other seat, and handoff applies to it. | The server holds no provider login and no provider code, so it cannot call a model itself. Every model call is timed the same way. Checks that need the orchestrator wait while the Mac is off or the helper is not running, and the orchestrator-offline Needs you item covers that. |
| First provider | Decided: all four logins are accepted. The reference runner is built for Claude first. | The provider rule ships on, so the first run needs two providers connected. With one, a Needs you item says no reviewer is eligible. |
| A blocking check that cannot run | Fail closed, with an owner override. | Safer, but work stalls until the owner acts. |
| Is a review always required | Yes in version 1. | It keeps the state machine simple. The alternative is a per-project switch. |
| Default limits | 60-minute lease, 2-minute check queue timeout, 5-minute check run timeout, 3 review rounds, 3 re-runs of a model check per round. | How fast a stuck seat or check is noticed. |
| Who may override a check | The owner only. | Whether the orchestrator may override on the owner's instruction comes with the orchestrator conversation. |
| Event retention | The life of the workspace. | Storage, and what a deleted task leaves behind. |
| Where agents' work lives | The app stores a reference only. | Branches, folders and file access stay with each agent's own tools. |
| When an outward action may happen | Only after the review passes. | The Finishing state. Allowing it earlier would put the action outside the review. |
| Orchestrator approves outward actions by default | On, as chosen for the prototype, with every approval under Decided for you. | The reviewer advises that paying and deleting always wait for the owner. |
| Contract edits after Ready | Allowed. The task returns to Backlog, and any builder lease and review lease on it ends. | Whether a wrong criterion can be fixed without cancelling. |
| Tasks per seat | One task or review at a time. A seat is free while its task is in review. | Claim eligibility and how many seats a busy workspace needs. |
| A claimed task that waits on the owner | The seat keeps its claim and the lease clock pauses. | The alternative frees the task and loses the seat's context. |
| Rework | The same builder first if it is free; otherwise the task returns to Ready. After 3 rounds the task comes to the owner. | How long a bad task can loop. |
| How the owner is told about Needs you | Decided: the Mac app sends a macOS notification when work stops and needs the owner, which is each time a Needs you item opens. | Email is a later addition. |
| What the orchestrator may read | Only the project of the task its job names. | Whether answers "from the record" can draw on other projects. |
| Token cost of model checks | Recorded per rule and counted against the project's budget, through `cost.reported` on each job result. Never against a task's own cap. | Whether rule cost shows in money as well as time. A project can reach its budget pause slightly sooner. |
| Per-criterion timing | Agents announce the criterion they start. Time that is not announced is reported as unattributed. | How exact the per-criterion numbers are. |
| Turning a rule off while tasks wait on it | Those checks are withdrawn and the tasks proceed at once. | What the switch does to work in flight. |
| Deleting | The content of a task or project can be deleted. Its timing stays. | Privacy, and what the log keeps. |
| Cancelled tasks | Hidden from the board, shown under a filter. | The board's lanes. |
| Is this product Campus | Decided: no. leverage is a separate open-source product. It shares nothing with Campus, the owner's earlier tool: no code, no usage readers, no storage and no credentials. | Credentials is new work, written and tested in this repository. |
| Handoff to another provider | Decided: allowed. Handoff follows the one order, whatever the provider. | The model doing a task can change part-way through. The server records every provider that has built a task, and the provider rule refuses a reviewer from any of them. |
| Handoff rules | Decided: fixed in version 1. Only the order can be changed. Handoff between two logins of the same provider is always automatic, with no switch. | The alternative gives each rule its own switch. Google's documentation does not support automated account rotation, and the other providers' terms are unclear (see Risks). |
| Gemini login | Decided: Gemini keeps its subscription login, at the owner's own risk. No warning is shown when a Gemini login is added. | Google's documentation says that driving its consumer tool from another application is not supported and can lead to suspension. leverage runs the provider's own tool on the owner's own Mac. The alternative is a Gemini API token only. |
| First usable milestone | Decided: the Core loop milestone. The launcher that starts agents arrives there, with account setup. | The owner can use the product end to end without a terminal from that milestone on. |
| Figures a provider does not report | Hidden, except resets, which show a dash. | How uniform the account rows look. |
| Percent used or percent left | Used only. | The wording on every limit tile. |
| Reading Claude's resets from its cache | Yes, behind a version check, showing 0 only when the entry is present and empty. | The entry is undocumented. The alternative is to show a dash for Claude until a supported source exists. |
| Spending a reset from the app | Not in version 1. The count is shown only. | Spending a reset is a later addition. |
| Isolation of agent runs | Not in version 1. It is stated as a risk. | Keeping seat tokens, provider sign-ins and, while the server runs on the same Mac, the database login out of the reach of agent runs needs a separate macOS user or a sandbox, and must first be shown not to break provider sign-ins. |
| Recovery time ceiling | No value yet. The owner sets it before the Handoff milestone is called done. | Whether the interrupted-run scenarios pass. |
| A limit with no reset time before the usage readers exist | Working assumption, chosen in the Handoff build: the account stays limited until a Verify of it passes, which counts as a reading that shows capacity. No reader is built before the Credentials milestone. | Whether the Handoff milestone brings a minimal read for a limited account, or such an account stays limited until the owner runs Verify. |
| A limit on a later credential after the seat's own has reset | Working assumption, chosen in the Handoff build: the task goes back to the seat's own credential at once, with `credential.switched`. When the seat's own credential is not available either, the task is held, and the hold closes as soon as one candidate is available. | Whether the task goes back to the seat's own credential at once, or is held and resumes on it. |
| What carries out a task on an API token | Not settled. The first run uses logins. Until it is answered, an API token is not an available candidate and cannot be the credential of a seat the app runs, so no handoff ends on one. | What runs the work on a token, and where its files live. |
| How a credential's model is set | Working assumption, chosen in the Handoff build: the app fills them in at Add from a default for each provider, as above. The Credentials milestone puts them on its screen. | Whether the app fills them in from a default for each provider or the owner chooses them, and on which screen. |
| What a token's masked label shows | Not settled. The label is made on the Mac, and the token never reaches the server. It has to be answered before a token's label is kept on the server. | Whether the label the server keeps may show any characters of the token. |
| How the helper signs in to the server | With its own token, which the server stores as a hash. The Mac app issues a new token each time it starts the helper and passes it in the helper's process environment; it is never stored or shown. While the containers run on the Mac the transport is HTTP on its loopback address; HTTPS is required once they do not. Ending the token stops the helper's calls; runs keep their own seat tokens. | How the token reaches the Mac, the transport between the Mac and the server, and what stops when the token is ended. |
| How a pasted token reaches the helper | Working assumption: the Mac app hands it to the helper over the helper's standard input, and the helper writes it to the macOS Keychain. It never passes through the server. It is built with API tokens in the Credentials milestone. | Whether the Mac app writes the token into the macOS Keychain for the helper to read, or hands it to the helper on the Mac. |
| Packaging | Working assumption, chosen in the Core loop build: the helper and the reference runner ship inside the Mac app, which starts the helper while it is open. The app starts the server's containers through Docker Desktop, which must already be installed, and says so when it is not. The app is built on the owner's Mac and is not notarized. | Agents run only while the app is open. A notarized installer and a helper that outlives the app are later. |
