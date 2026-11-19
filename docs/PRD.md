# leverage PRD: Event log, rule checks and the core task loop

Draft of 2026-11-18, exported from the owner's working document (author: Neo). An [adversarial review](research/prd-review/README.md) of this text found open problems; none of them is resolved here yet.

Version 1 is the core task loop (contract, claim, build, review, done) with two things built in from the first commit. The first is an append-only event log that times every step. The second is system rules that the app enforces as checks on task transitions. The Analytics page comes later as a view over this data, because the data cannot be backfilled. A second pass added Credentials: provider logins, API tokens and the order in which one takes over from another.

## Goals and non-goals

Version 1 proves one loop end to end with real agents, and records enough to find bottlenecks later without guessing.

Goals:

1. A task moves from Backlog to Done through one server-side transition function. No other code path changes task state.
2. Every state change writes an event in the same database transaction. If the event is not written, the change did not happen.
3. Every task's lifetime is split into timed steps that do not overlap and leave no gaps. Each step says who was working or what the task was waiting for.
4. System rules are checks the app runs at fixed moments. A transition cannot complete until every rule bound to that moment has a recorded result.
5. Each rule check records whether the rule applied, the result, who checked it, and how long it queued and ran.
6. The owner can turn any rule off, change its parameters, override a single failed check, and see the cost in time of each rule.
7. Agents from any provider connect through one HTTP interface. A reference runner and an MCP server ship with version 1 so one provider works on day one.
8. The owner adds provider logins and API tokens in one place, sees each account's limits and available resets, and sets which credential takes over when one hits a limit.

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
| Seat | One connected agent: a provider, a model, an effort setting and a role. It signs in with its own token. |
| Task contract | A task's goal, its acceptance criteria, its budget and any outward action it ends in. |
| Acceptance criterion | One thing that can be checked to prove the task is done. The last one is always the independent review. |
| Outward action | Publishing, paying, sending or deleting. It cannot be undone once it leaves the app. |
| Transition | A change of task state, requested by a command and carried out only by the server. |
| Hook | A named moment in the loop where rules run, such as "before a task enters Ready". |
| Rule | A system-wide instruction bound to one hook, with a scope and a checker. |
| Rule check | One run of one rule for one task at one hook. It is stored with its result and its times. |
| Event | An immutable record that something happened, written by the server. |
| Step | A timed segment of a task's life, opened and closed by events. |
| Hold | A reason a task cannot move: waiting on the owner, on access, on budget, on a paused project or on a rule check that could not run. Holds stack. |
| Job | A piece of model work the server queues for a seat: a rule check, a question to answer, an approval, a contract to draft. |
| Lease | A seat's time-limited claim on a task or a review. It is renewed by heartbeat and released on expiry. |
| Briefing | What an agent must read before it works: the applicable rules, the project brief, its role file and the contract. |
| Credential | How a seat reaches its provider: a subscription login used through the provider's own tool, or an API token. |
| Handoff order | The owner's ordered list of credentials. When one hits a limit, the next one takes over. |

## Task lifecycle

A task has eight states and moves between them only through commands the server carries out. Six are drawn below. The picture leaves out Finishing, which only a task with an outward action passes through between In review and Done, and Cancelled. The lanes on the board are Imaginarium, Backlog, Blocked, Ready, In Progress (working, in review or finishing) and Done. Cancelled tasks show only under a filter. Blocked is a lane, not a state: it shows every task with an open hold on the owner or the project, whatever its state, and the card says where it came from. The task returns to its own lane when the hold lifts.

_The lifecycle diagram (6 states, 5 gated moves, 2 loops) did not survive the export. The table below is the authority._

Each forward move names the hook where rules run. A failed review loops back to the builder, and a lost lease returns the task to Ready. A hold does not change the state.

| Command | From | To | Who may ask | Hook | Events written |
| --- | --- | --- | --- | --- | --- |
| Add task | None | Imaginarium or Backlog | Owner | None | `task.created` |
| Promote | Imaginarium | Backlog | Owner | None | `task.promoted` |
| Complete contract | Backlog | Ready | Owner or planner seat | `task.before_ready` | `task.contract_changed`, `task.ready` |
| Edit contract | Ready, Working, In review | Backlog | Owner | None | `task.contract_changed`, `task.returned` |
| Claim | Ready | Working | Builder seat | `task.before_claim` | `task.claimed` |
| Acknowledge briefing | Working | Working | Holder | None | `task.briefing_acknowledged` |
| Start criterion (optional) | Working | Working | Builder | None | `criterion.started` |
| Pass criterion | Working | Working | Builder | None | `criterion.passed`, `evidence.attached` |
| Submit | Working | In review | Builder | `task.before_submit` | `task.submitted` |
| Claim review | In review | In review | Reviewer seat | `review.assign` | `review.started` |
| Release review, or review lease expiry | In review | In review, unassigned | Reviewer or the app | None | `review.released` or `review.lease_expired` |
| Review fails | In review | Working | Reviewer | `review.failed` | `review.failed`, `criterion.reopened`, and `task.reassigned` if it escalates |
| Review passes, no outward action | In review | Done | Reviewer | `task.before_done` | `review.passed`, `task.done` |
| Review passes, with an outward action | In review | Finishing | Reviewer | `task.before_done`, then `action.requested` | `review.passed`, `action.requested` |
| Report action done | Finishing | Done, once every action is done or waived | Builder | None | `action.reported_done`, `task.done` |
| Release, or lease expiry | Working, Finishing | Ready, or Finishing without a holder | Holder or the app | None | `task.released` or `task.lease_expired` |
| Hold and resume | Any | Unchanged | Owner or the app | None | `hold.opened`, `hold.closed` |
| Cancel | Any except Done | Cancelled | Owner | None | `task.cancelled` |

Saving the Add task form is two commands in a row: Add task, then Complete contract.

### Timers and leases

- **Timers run first.** Before the server validates any command on a task, it applies every timer already due on that task, in the same transaction, with the effective time set to the due time. This covers lease expiry and check timeouts. The sweep only triggers the same logic for tasks nobody has touched.
- **A lease ends at its due time.** After that, every call from its holder is refused with `lease_expired`, a heartbeat included. Effective times never go backwards within a task.
- **Two kinds of lease.** The builder's lease covers Working and Finishing. A reviewer has its own lease during a review, with heartbeat and release. An expired review lease leaves the task In review and unassigned, so another reviewer can claim it.
- **Holds and the lease clock.** A hold on the owner or the project pauses the lease clock. A paused seat does not, so a dead seat cannot keep a task.
- **One thing at a time.** In version 1 a seat holds at most one task or review.

### Rework and escalation

A failed review adds one to the round, reopens the failed criteria and gives the previous builder a fresh lease. The builder learns of it through `GET /v1/next`. If that lease expires, the task returns to Ready.

Escalation is a restriction on who may claim, not a push to a seat. It sets a minimum strength rank on the task. If the previous builder is below it, the task goes to Ready and only a seat at or above that rank can claim it.

Rounds are limited by a workspace setting, 3 by default. A failure at the limit holds the task and opens a Needs you item.

### Outward actions

An outward action happens only after the independent review has passed.

1. The contract names each outward action the task ends in.
2. When the review passes, the task moves to Finishing and the server asks approval for each action at the `action.requested` hook.
3. Once approved, the previous builder gets a fresh lease, carries the action out and reports it done.
4. The task is Done when every contracted action is reported done or waived by the owner.

A stopped action holds the task and opens a Needs you item with three choices: waive the action, send the task back for rework, or cancel it. No action can be requested in any other state.

### Holds

Hold reasons are a fixed list, with one more added under Credentials: `owner_question`, `owner_approval`, `access`, `budget`, `project_paused`, `contract_incomplete`, `check_error`, `rounds_exceeded`, `action_stopped`, `owner_hold` and `seat_paused`.

- Holds stack. A task is held while any hold is open, and the waiting step's subject is the oldest open hold.
- A hold blocks the seat commands that move work forward: claim, pass, submit, verdict and report action done. Heartbeat, release, contract edits, cancel and timers still work.
- A pending rule check is not a hold. It does make the task ineligible for anyone else to claim.

### Contract edits and cancel

The owner can edit a contract freely in Backlog. Editing it in Ready, Working or In review returns the task to Backlog and releases its holder. Criteria that are unchanged and already passed stay passed. `task.before_ready` runs again on the way back to Ready. A contract cannot be edited in Finishing or Done.

Cancel closes the open step and every hold, resolves the task's Needs you items, withdraws its pending checks and jobs, and revokes any approval not yet reported done. The holder's next call is refused with `task_cancelled`.

## Event log

The log is one table that the server appends to. No row is ever updated or deleted.

### Principles

1. **One writer.** Only the server's transition function appends events. Agents and the web app send commands and never write events.
2. **Same transaction.** The event, the state change and the step change commit together or not at all.
3. **Lock first.** The first statement of every transaction that changes anything takes the workspace lock and holds it to commit. Isolation is read committed. Model calls and long polls never run inside a transaction, and a change that touches many tasks is done in bounded batches.
4. **Order and time under the lock.** `seq` comes from a counter row read under the lock, not from a database sequence. `at` is the wall clock read once after the lock is taken, and every event of one command shares it. So `seq` order is commit order, `at` never decreases as `seq` grows, and a reader that tails by `seq` misses nothing.
5. **Timers before commands.** Any timer already due on a task is applied before a command on that task is validated, with `effective_at` set to the due time. `effective_at` never decreases within a task.
6. **Idempotent commands.** Every mutating call carries an idempotency key. A repeat with the same key writes nothing and returns the command's current outcome: pending, completed with its result, or refused with its cause.
7. **References, not content.** Payloads hold ids, numbers and short fixed values. They hold no prompt text, file content, question text or secrets. Content lives in its own tables and can be deleted without touching the log.
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
| `subject_kind`, `subject_id` | enum, uuid | The criterion, question, rule check, review, job, rule, hold or action concerned. |
| `cause_id` | uuid, nullable | The event that led to this one. |
| `command_id` | text, nullable | The idempotency key of the command. All events of one command share it. Events written when a pending transition completes carry the original requester's key, with `cause_id` set to the `check.finished` event. Empty for app-originated events. Indexed, not unique. |
| `payload` | json | Type-specific facts, validated against the schema. |

### Event types

| Group | Types |
| --- | --- |
| Task | `task.created`, `task.promoted`, `task.contract_changed`, `task.changed` (priority, project), `task.ready`, `task.returned`, `task.claimed`, `task.briefing_acknowledged`, `task.released`, `task.lease_expired`, `task.submitted`, `task.reassigned`, `task.done`, `task.cancelled` |
| Criteria | `criterion.started`, `criterion.passed`, `criterion.reopened`, `evidence.attached` |
| Review | `review.started`, `review.released`, `review.lease_expired`, `review.passed`, `review.failed` |
| Holds | `hold.opened`, `hold.closed`, each with a reason and, where one applies, the rule that caused it |
| Questions | `question.asked`, `question.answered` (from the record, by the orchestrator or by the owner), `question.overturned` |
| Outward actions | `action.requested`, `action.approved`, `action.stopped`, `action.waived`, `action.revoked`, `action.reported_done` |
| Rule checks | `check.queued`, `check.started`, `check.finished` (with the result, `withdrawn` included), `check.overridden` |
| Rules | `rule.created`, `rule.changed`, `rule.enabled`, `rule.disabled`, `rule.reverted`, `rule.removed` |
| Jobs | `job.queued`, `job.claimed`, `job.finished`, `job.timed_out`, `job.requeued`, `job.withdrawn` |
| Money | `cost.reported`, `project.budget_changed` |
| Projects and seats | `project.created`, `project.paused`, `project.resumed`, `brief.changed`, `seat.connected`, `seat.paused`, `seat.resumed`, `seat.changed`, `seat.removed` |
| Workspace | `workspace.settings_changed`, `content.deleted` |
| Needs you | `inbox.opened`, `inbox.resolved` |
| Credentials | `credential.added`, `credential.verified`, `credential.signed_out`, `credential.renamed`, `credential.removed`, `credential.order_changed`, `credential.limit_reached`, `credential.switched` |

Heartbeats and reads are not events. A heartbeat only moves the lease's expiry time.

The Activity feed, the log on each task page, the steps table and the analytics queries all read from this one table. Events are kept for the life of the workspace in version 1.

## Steps and timing

A task's life is a row of steps that touch end to end, so every minute of it belongs to exactly one step. The steps table is written in the same transaction as the events that open and close each step.

### Rules for steps

1. Exactly one step is open on a task from its creation until it is done or cancelled.
2. Opening a step closes the one before it at the same effective time.
3. A hold interrupts the current step. The work step closes and a waiting step opens. When the last hold lifts, the step that opens is the one the task's current state calls for, which may differ from the one interrupted.
4. Each step records its kind, its class (working, waiting or rule check), its subject and the seat responsible.
5. A builder can announce the criterion it is starting, and the `build` step then carries that criterion. Without an announcement the step has no criterion. When a criterion passes, an open step without one, for the same seat and round, is given that criterion. Whatever is left is reported as unattributed build time. The reference runner and the MCP server always announce.
6. The sum of a task's steps equals its lifetime. This is a tested invariant.
7. Reports measure a task from its promotion to Backlog, or from its creation if it was added straight to Backlog. Time in Imaginarium is shown apart.

### Step kinds

| Kind | Class | Open while | Subject |
| --- | --- | --- | --- |
| `idea` | Waiting | The task is in Imaginarium. | None |
| `draft` | Working | A planner job is writing the contract. | The job |
| `wait_contract` | Waiting | The task is in Backlog and nobody is writing its contract. | None |
| `check` | Rule check | A transition is pending on one or more model checks. | The pending transition |
| `wait_ready` | Waiting | The task is in Ready with no seat. | None |
| `briefing` | Working | A seat has claimed the task and not yet acknowledged the briefing. | None |
| `build` | Working | The builder is working toward a criterion. | The criterion, if announced |
| `finish` | Working | Every builder criterion has passed and the task is not yet submitted, or an approved outward action is being carried out. | The action, if any |
| `wait_review` | Waiting | The task is submitted and no reviewer has started. It names the provider rule as its cause when that rule refused a reviewer who was otherwise eligible. | The review |
| `review` | Working | A reviewer is checking the work. | The review criterion |
| `wait_builder` | Waiting | The task is back with its builder, after a failed review or an approved action, and the builder has not yet made a call. | The review or action |
| `rework` | Working | The builder is fixing the work after a failed review, until it submits again. | The review |
| `wait_owner` | Waiting | A hold on the owner or the project is open. | The oldest open hold |
| `wait_seat` | Waiting | The seat holding the task is paused. | The seat |
| `wait_limit` | Waiting | Every credential that could run the task is at its provider limit. | The credential |

Things that do not block the task open no step. A non-blocking question, a cost report and an instant app-run check each keep their own times on their own rows.

### What can be measured

| Question | Computed from |
| --- | --- |
| Where does task time go? | Step durations summed by kind and class. |
| How long did each acceptance criterion take? | `build` steps by criterion, with unattributed build time shown apart. For the review criterion, `wait_review` plus `review`. |
| How long does each rule take to check? | Rule check attempts: queue time is started minus queued, run time is finished minus started. Queue time is shared, because one orchestrator runs checks one after another. |
| How long did a rule hold tasks up? | For each check that blocked a transition, finished minus queued. Added to that: `wait_owner` steps whose hold a failed or errored check of that rule opened, and `wait_review` steps that name the rule as cause. A `check` step with several checks is credited to the one that finished last. |
| What does a rule cost in tokens? | The tokens and spend on its jobs' results. |
| How often did a rule apply, stop something, or get overridden? | Rule check rows counted by result. |
| How long do tasks wait on the owner, and for what? | `wait_owner` steps by hold reason. |
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
| `action.requested` | The server asks approval for an outward action. | App and model | The action is stopped and a Needs you item opens. |
| `review.assign` | A reviewer asks to claim a review. | App only, policy | The reviewer is refused. |
| `review.failed` | A review fails. | App only, policy | Not a gate. It decides who may take the rework. |
| `question.asked` | A worker asks a question. | App, policy | Not a gate. It decides where the question goes. |
| `cost.reported` | A seat reports spending. | App only, policy | Not a gate. It can pause the project. |

### How a transition is gated

1. The server applies due timers and validates the command against the state machine.
2. It loads every enabled rule bound to the transition's hook. That set of rules and versions is frozen for this request.
3. It decides fixed scopes itself, at no cost. A rule whose scope does not cover the task gets a `not_applicable` row and nothing else runs for it.
4. App checkers run inside the transaction.
5. If a blocking model checker applies, the server stores the pending transition, queues one job per check, opens a `check` step and answers "pending". A rule with the scope "let the checker decide" uses the same job: the checker may answer `not_applicable`, with its reason. There is no separate applicability job.
6. When every check has a result, the server validates the state and the app checkers again. It completes the transition if each gate passed, did not apply, was withdrawn or was overridden. Otherwise it refuses the transition and routes each failure.
7. Every gate result is a rule check row and a `check.finished` event. Policy rules at `question.asked` and `action.requested` always write a row. Policy rules at `review.assign` and `cost.reported` write a row only when they change the outcome.

A rule check result is one of `passed`, `failed`, `not_applicable`, `applied` (policy rules, with the effect), `error` or `withdrawn`.

### Pending transitions

- A task has at most one pending transition and stays in its earlier state while it is pending.
- The holder may heartbeat, release and read. Its other commands are refused with `pending`.
- The lease keeps running. If it expires, the pending transition is cancelled and its checks are withdrawn.
- A rule edited during a check does not affect it: the frozen version's result stands. A rule turned off or removed during a check withdraws that check, and the transition completes if nothing else blocks it. A rule turned on during a check does not apply to this request.
- A refused transition is kept with its reasons. The holder fixes the cause and sends the command again with a new key.
- An override on a refused transition completes it at once if the holder's lease is live and the inputs are unchanged. Otherwise it applies to the next request with the same inputs.

### A rule on the move from Ready to In Progress

The owner adds such a rule in Settings, Rules, with the moment "before an agent starts a task". It runs at the `task.before_claim` hook, every time a seat tries to claim.

- A claim that waits on a model check is provisional. The task is reserved for that seat and no other seat can claim it.
- The seat gets no lease and no briefing until the check passes. It learns the outcome from `GET /v1/commands/{key}`.
- If the check fails, errors or times out, the reservation lapses and the task returns to Ready. The reason goes to the seat.
- A task that fails this gate for 3 different seats is held and opens a Needs you item, because the rule is then about the task and not the seat.

A rule about the task alone belongs at "ready to start", where it runs once and keeps no agent waiting. "Before an agent starts" is for a rule that depends on which agent takes the task, or that must hold at the moment work begins. Settings, Rules shows every rule's moment on its row.

### When a check cannot run

- A model check that is not started within its queue timeout, or not finished within its run timeout, is queued once more as a new attempt. A second miss gives the result `error`. A job result that arrives after its timeout is discarded.
- An `error` on a blocking rule holds the task with the reason `check_error`. If the orchestrator is online, a Needs you item opens for that task with three choices: run it again, override it once, or turn the rule off.
- The orchestrator counts as offline when no enabled seat with the needed role has polled for 90 seconds. The server then opens one workspace-level Needs you item, "Orchestrator offline, N checks waiting", not one per task.
- When such a seat polls again, waiting and errored checks are queued again on their own and that item closes.
- An `error` on a `warn` rule lets the transition through and is recorded.
- The sweep records each run. The web app shows a system health line, and says so when the sweep is more than two minutes late.

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
- A model-checked gate runs at most 3 times per round on changed inputs. After that the task goes to the owner. This stops a builder from rewording a note until a model passes it.
- The owner can override one failed or errored check for one task. The override stores who, when and why. Overrides are counted per rule, because a rule that is often overridden is wrong or too strict.

### Who may check

- No seat that has ever held a task may check or review it. The set of past holders comes from the log.
- Only a seat with the role named in the rule's checker may return a verdict. A verdict has a fixed shape: a result, a short reason, and the tokens and spend it used.
- Text written by a builder reaches a checker as quoted material: handoff notes, action descriptions, questions and assumptions. The contract and the rule's instruction are the only authority.
- A job's context is limited to the task's own project.

### Shipped rules

| Rule | Hook | Kind | Checker | When it is off |
| --- | --- | --- | --- | --- |
| Every task needs acceptance criteria | `task.before_ready` | Gate | App. Parameter: minimum count, default 1, not counting the review. | A task can enter Ready with only the review criterion. |
| Every task needs specific details | `task.before_ready` | Gate | Model, the orchestrator | No detail check. |
| Workers ask the orchestrator before they ask you | `question.asked` | Policy | App routes the question. The orchestrator answers from the record, decides, or passes it on. The time and tokens of its answer count as this rule's. | Every question opens a Needs you item. |
| A different provider reviews every task | `review.assign` | Policy | App | Any reviewer seat that never held the task may review. |
| Two failed reviews move a task to a stronger model | `review.failed` | Policy | App. Parameter: threshold, default 2. | Rework returns to the same builder. |
| Projects pause when they reach their budget | `cost.reported` | Policy | App | Spending continues past the budget, and the budget stops being part of claim eligibility. |
| The orchestrator approves outward actions itself | `action.requested` | Policy | Model, the orchestrator. It approves, stops, or passes to the owner. Every approval is listed under Decided for you. | Every outward action waits for the owner. |

The budget rule also covers a task's own cap. A task that reaches it is held with the reason `budget` and opens a Needs you item.

Some behaviour is built in and is not a rule, so it cannot be turned off:

- The state machine itself.
- Every task is reviewed by a seat that never held it.
- A builder or reviewer can change only the task it holds.
- Every builder criterion needs evidence before submit.
- An outward action happens only after the review passes, and always needs an approval from the orchestrator or the owner.
- No work call is accepted before the briefing is acknowledged.

### Custom rules

The owner adds a rule with a name, an instruction, a moment and a scope. The moments offered are plain-language names for five hooks: when a task is ready to start, before an agent starts it (Ready to In Progress), before work is submitted, when the review has passed, and before anything goes out. A custom rule is a model-checked gate that blocks. Its reason goes to the builder, or to the owner for a task that is not yet claimed.

### The briefing

The briefing is what a seat must read before it works on a task.

- **Content.** The system rules whose fixed scope covers the task, every "let the checker decide" rule marked as "may apply", the project brief, the seat's role file and the contract.
- **Hash.** It is computed over the versions of those parts, so only a change to something in this task's briefing changes it.
- **Delivery.** The claim returns it. `GET /v1/tasks/{id}/briefing` returns it again at any time.
- **Acknowledgement.** The seat must acknowledge the hash before a work call is accepted. Work calls are start criterion, pass criterion, ask a question, report an action done, submit and give a verdict. Heartbeat, release, cost report and reading the briefing are always accepted.
- **Changes.** After a change the next work call answers `briefing_changed`. The seat reads the briefing and acknowledges again.
- **Reviewers.** A reviewer gets a briefing too, with the reviewer's role file, and acknowledges it before giving a verdict.
- **From the first build.** The acknowledgement is required from the core-loop milestone on, with a briefing that holds only the brief, the role file and the contract. Rules join it in the next milestone.

Acknowledgement proves delivery, not understanding. The checks are what enforce a rule.

### Precedence

System rules come first, then the project brief, then the role file, then the task contract. In version 1 only system rules are checks. Project brief rules are text in the briefing.

## Agent interface

Agents work through one HTTP interface. Every call carries the seat's token as `Authorization: Bearer`, and every call that changes something carries an idempotency key.

| Call | Seat | What it does |
| --- | --- | --- |
| `GET /v1/next?wait=30` | Any | Waits up to 30 seconds and answers with one item: its kind and its id. Kinds: `none`, `task`, `rework`, `action`, `review`, `job`, `answer`, `briefing_changed`. |
| `GET /v1/commands/{key}` | Any | The current outcome of a command this seat sent: pending, completed with its result, or refused with its cause. |
| `POST /v1/tasks/claim-next` | Builder | Claims the next eligible Ready task. Returns the task, a lease and the briefing with its hash. Runs `task.before_claim`. |
| `GET /v1/tasks/{id}/briefing` | Holder | Returns the current briefing and its hash. |
| `POST /v1/tasks/{id}/ack-briefing` | Holder | Acknowledges the briefing hash. |
| `POST /v1/tasks/{id}/heartbeat` | Holder | Renews the lease. |
| `POST /v1/tasks/{id}/criteria/{cid}/start` | Builder | Optional. Announces the criterion being worked on. |
| `POST /v1/tasks/{id}/criteria/{cid}/pass` | Builder | Marks a criterion passed, with evidence links. |
| `POST /v1/tasks/{id}/questions` | Holder | Asks a question, with the worker's own assumption and whether the question blocks the work. |
| `GET /v1/tasks/{id}/questions/{qid}` | Holder | Reads the answer. |
| `POST /v1/tasks/{id}/access` | Holder | Says what access the task needs. It holds the task and opens a Needs you item. |
| `POST /v1/tasks/{id}/cost` | Holder | Reports tokens and spend since the last report. Runs `cost.reported`. |
| `POST /v1/tasks/{id}/submit` | Builder | Submits for review with a handoff note. Runs `task.before_submit`. |
| `POST /v1/tasks/{id}/actions/{aid}/done` | Builder | Reports that an approved outward action was carried out. |
| `POST /v1/tasks/{id}/release` | Holder | Gives the task back, with a reason. |
| `POST /v1/reviews/claim-next` | Reviewer | Claims the next review this seat may take, with a lease and a briefing. Runs `review.assign`. |
| `POST /v1/reviews/{id}/heartbeat`, `/release` | Reviewer | Renews or gives up the review lease. |
| `POST /v1/reviews/{id}/verdict` | Reviewer | Passes the work, or fails it and names the criteria that failed. Runs `task.before_done` on a pass. |
| `POST /v1/jobs/claim-next` | Orchestrator, planner | Claims the next job: a rule check, a question, an approval or a contract draft. |
| `POST /v1/jobs/{id}/result` | Job holder | Returns the result in the fixed shape for that kind of job, with the tokens and spend it used. A contract draft's result is the Complete contract command. |

### Roles

A seat has one of four roles. Evidence links must be `https`, are never fetched by the server, and are shown as plain links.

| Role | May change | May read |
| --- | --- | --- |
| Builder | The task it holds | That task's contract, criteria, evidence and questions, and its project's brief |
| Reviewer | The review it holds | The same, for the task under review |
| Planner | The contract of the task its job names | That task and its project's brief |
| Orchestrator | The result of the job it holds | The task its job names and that task's project. Nothing from other projects. |

### Behaviour every client can rely on

- **Claiming is atomic.** The server picks the task, by priority and then age, and two seats can never receive the same one.
- **Eligibility.** A seat can claim when it is enabled, its role may build, it holds nothing else, it meets the task's minimum strength rank, the project is running, and the task has no hold and no pending transition. While the budget rule is on, the project must also be under budget.
- **Leases.** The lease length is a workspace setting, 60 minutes by default. A heartbeat renews it.
- **Pending answers.** A call that meets a model-checked gate answers `202 pending`. The seat learns the outcome from `GET /v1/commands/{key}` or from `GET /v1/next`.
- **Specific refusals.** Refusals name their cause: `not_holder`, `not_eligible`, `briefing_not_acknowledged`, `briefing_changed`, `blocked_by_rule` (with the rule and the reason), `pending`, `on_hold`, `lease_expired`, `rounds_exceeded`, `task_cancelled`.

### Clients

Two clients ship with version 1. A reference runner signs in as a seat and loops through claim, work and submit with a model. It can hold any of the four roles.

An MCP server exposes the same calls as tools. It heartbeats for the agent only while the agent has made a tool call in the last 10 minutes, so a stuck agent still loses its lease. Whether an MCP agent can work with no custom code at all is not yet tested.

### Owner interface

The web app uses a separate interface on the same server, with a signed-in session. Its commands are part of the contract and run through the same transition function: add, promote, complete and edit a contract, cancel, hold and resume, answer, overturn, approve or stop an action, waive an action, override a check, save, switch, revert and remove a rule, pause and resume a project, change a budget, connect, pause and remove a seat, delete content, and change workspace settings.

## Credentials

A credential is how a seat reaches its provider: a subscription login used through the provider's own tool on the owner's machine, or an API token. The Credentials screen has its own tab in the left pane. It lists them, shows what each provider reports about limits, and sets the order in which one takes over from another. The approved mock-up in the prototype is the design reference.

A credential is not the seat's own token. The seat token signs a seat in to this app. The credential signs it in to its provider.

### Two kinds

| Kind | Providers | How the app uses it | What the app keeps |
| --- | --- | --- | --- |
| Login | Claude (Claude Code), Codex (OpenAI), Gemini (Antigravity), Grok (Grok Build) | It runs the provider's tool without a screen, pointed at that account's settings folder. | The name, the provider and the settings folder. Never the sign-in token. |
| API token | Claude API, OpenAI API, Gemini API, Grok API, OpenRouter | It calls the provider's API. | The token in the system keychain and a masked label. |

- Logins and API tokens are listed in separate sections, each grouped by provider. A provider with no credential is not shown.
- Two accounts of one provider are two credentials with separate limits. Claude, Codex and Grok keep each account in its own settings folder. Antigravity has one sign-in for the whole machine, so a machine holds one Gemini login.
- A seat the app runs has exactly one credential. A seat that connects on its own needs none.
- A credential that a seat uses cannot be removed.
- An API token is never returned by any interface after it is saved. The app never reads, copies or decrypts a provider's sign-in token.

### Adding a credential

One button, Add credential, opens a pop-up with two steps. The owner never has to find the next thing to click.

1. **Pick.** A login for one of four providers, or an API token for one of five.
2. **Name it.** A token is pasted here too. One button: Sign in for a login, Add for a token.

The app then runs the checks itself, ticks each one off, saves the credential and closes the pop-up.

- **Login checks.** The tool is installed. It is signed in; if not, the app opens the tool's own sign-in and waits. One short test prompt gets an answer.
- **Token checks.** One small request confirms the token works. The app then reads what the provider reports about it.
- **A failed check** stays in the pop-up with one line saying what failed and one Retry button. A missing tool shows its install command.
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
| Gemini | Antigravity's usage screen, captured from the terminal | What that screen shows | None found | Taken from the existing Campus credentials doc. Not re-tested. |
| Grok | Grok Build's usage screen, captured from the terminal | What that screen shows | None found | Taken from the existing Campus credentials doc. Not re-tested. |

| API token | Validity check | What it reports |
| --- | --- | --- |
| OpenRouter | `GET /api/v1/key` | Spending limit and what is left, use today, this week and this month, free tier, expiry |
| Claude API | `GET /v1/models` | Rate limits, from the headers of each reply |
| OpenAI API | `GET /v1/models` (not verified) | Rate limits, from the headers of each reply |
| Gemini API | `GET /v1beta/models` | Nothing beyond valid |
| Grok API | `GET /v1/api-key` | Key name, team, and whether it is blocked |

Account balance and spend need an admin or management token at every provider. They are not in version 1.

### Reading usage

- Usage is read on Refresh and every 10 minutes, with a 15-second limit per account.
- One account that fails shows "unavailable" on its own row. It never blanks the others.
- A read never signs in or out, never opens a browser and never spends a reset.
- Verify runs the add checks again, for one account or for all.
- Readings are stored with their observed time. They are not events.
- Resets are shown, not spent. Using a reset from the app is not in version 1.

### Handoff

Handoff is the order in which one credential takes over from another. It is one list, shown under the credentials on the Credentials tab. Each row names the credential it hands off to, and the last row hands off to nobody.

- The owner reorders the list by dragging a row up or down. A line shows where the row will land, and a hint above the list names the position.
- Up and down buttons on each row do the same for keyboard and touch.
- A new login is placed above the first API token. A new token goes last, because tokens are billed per use.

When a run hits a provider limit:

1. The credential is marked limited until the reset time the provider gave.
2. The work is handed off to the next credential below it in the list that is signed in and not limited. Credentials above it are not tried.
3. The seat goes back to its own credential for its next task once that limit has reset.

- Every claim, job and handoff records which credential did the work. A handoff is the `credential.switched` event.
- A handoff to another provider changes the model doing the work. The provider-review rule therefore compares the providers that actually worked on the task, not the seat's first one.
- If no credential below is available, the task is held with the new reason `credential_limit` until the earliest reset time. Its step is the new kind `wait_limit`, classed as waiting, so time lost to provider limits shows in the timing data.

### What this adds to the contract

- **Tables.** `credentials`, `credential_readings`, and a credential on each seat. They are listed under Data model.
- **Events.** `credential.added`, `credential.verified`, `credential.signed_out`, `credential.renamed`, `credential.removed`, `credential.order_changed`, `credential.limit_reached` and `credential.switched`.
- **Owner commands.** Add, verify, sign in again, rename, remove, refresh usage and reorder.
- **A machine helper.** The part that finds the providers' tools, runs them and reads usage must run on the owner's machine. With the recommended installation it is part of the server.
- **Build.** One more track and its own milestone, after Questions and approvals.

### Acceptance criteria for Credentials

- [ ] Adding a login through the pop-up takes two steps and ends with the account listed and its usage shown, with no other click.
- [ ] A signed-out tool is caught in the pop-up, and the flow continues on its own once the owner has signed in.
- [ ] Two accounts of one provider show separate limits and both stay signed in, for Claude, Codex and Grok.
- [ ] A Codex account shows the same number of resets as the Codex tool reports for it.
- [ ] A Claude account with a reset grant shows its count and kind. This needs an account that has one.
- [ ] A saved token is not returned by any interface and appears only masked.
- [ ] One account whose usage read times out shows "unavailable" while the others still show their figures.
- [ ] When a run hits a limit, the next credential in order takes over and the log records the switch.
- [ ] With every credential limited, the task is held with `credential_limit` and resumes after the earliest reset time.
- [ ] Removing a credential that a seat uses is refused.
- [ ] Refreshing usage spends no reset and changes no sign-in.

## Data model

These tables are part of the shared contract, which is listed in full under Build order. A relational database is assumed (see Open decisions).

| Table | Holds | Key fields |
| --- | --- | --- |
| `workspaces` | One row per owner | Settings: lease length, check timeouts, maximum rounds, re-run limit |
| `users` | The owner's sign-in | Workspace, sign-in identity |
| `projects` | Projects | Name, goal, budget, spent, paused |
| `brief_entries` | Each project's rules, decisions and lessons | Project, kind, text, author |
| `seats` | Connected agents | Name, provider, model, effort, role (builder, reviewer, planner or orchestrator), strength rank, credential, enabled, token hash, last polled |
| `tasks` | Tasks | Project (empty for "no project"), title, goal, state (one of eight), round, holder seat, builder seat, lease due time, lease time left while paused, minimum strength rank, contract version, budget cap, spent, work reference, priority |
| `criteria` | Acceptance criteria | Task, position, text, kind (build or review), state, passed at, passed by |
| `evidence` | Proof for a criterion | Criterion, kind, `https` link, note |
| `reviews` | One row per review round | Task, round, reviewer seat, lease due time, verdict, failed criteria, notes |
| `questions` | Worker questions | Task, asking seat, text, assumption, blocking, outcome, answer, basis, answered by |
| `actions` | Outward actions named in a contract | Task, kind, description, state (contracted, requested, approved, stopped, waived, revoked, done), approved by |
| `holds` | Why something cannot move | Task or project, reason, causing rule, opened at, closed at |
| `pending_transitions` | A transition waiting on checks | Task, command key, command, requester, frozen rule versions, state (pending, completed, refused, cancelled), reasons |
| `rules` | One row per rule | Key, enabled, current version |
| `rule_versions` | Immutable rule versions | Rule, version, every field of the rule record, author, created at |
| `rule_checks` | One row per check | Task, project, rule, rule version, hook, round, subject, input hash, result, effect, reason, override (who, when, why) |
| `rule_check_attempts` | Each run of a check | Check, attempt number, job, checker seat, queued at, started at, finished at, tokens, spend |
| `jobs` | Model work queued for seats | Kind, target, seat role, claimed by, state, queued at, claimed at, finished at, result, tokens, spend |
| `events` | The event log | As specified under Event log |
| `task_steps` | Timed segments of each task | Task, round, kind, class, subject, seat, causing rule, opened at, closed at, opening event, closing event |
| `inbox_items` | Needs you | Kind, what it refers to (a task or the workspace), choices, state, resolved by, resolved at |
| `commands` | Idempotency and command outcomes | Caller kind, caller id, key, command, outcome, stored result |
| `sweep_runs` | Proof the timer sweep is alive | Ran at, tasks touched |
| `credentials` | Logins and API tokens | Kind, provider, name, settings folder or keychain reference, masked label, plan, account email, state, limited until, position in the handoff order, last verified |
| `credential_readings` | What a provider reported for an account | Credential, observed at, state, and one entry per figure: label, kind (limit, activity or allowance), percent used, reset time, value |

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

- `tasks`: state, round, holder, builder, minimum strength rank, contract version.
- `criteria`: state. `reviews`: verdict. `actions`: state.
- `holds`: the open set with reasons.
- `rule_checks`: result and override. `rules`: enabled and current version.
- `projects`: paused and spent.
- `task_steps`: every row.

Everything else is outside the replay: text, links, lease due times, last polled, job results and stored command outcomes.

## What the app shows in version 1

The clickable prototype is the design reference. Version 1 makes these screens real and leaves the rest for later.

| Screen | In version 1 |
| --- | --- |
| Sign-in | The owner signs in. One owner per installation. |
| Kanban | Six lanes driven by task state and holds, with Blocked just before Ready, with the project and agent filters, and a filter that shows cancelled tasks. |
| Add task | A form: title, goal, acceptance criteria, who it is for and what it must include or avoid, outward actions, project. Saving runs `task.before_ready`. A failed check keeps the task in Backlog and shows the reason. |
| Task page | Contract, criteria with evidence, questions, and the log read from events. A Timing section lists the steps in order with durations, and a rule checklist with each rule's result, reason and time. A failed check has an Override button. |
| Needs you | Questions passed on, approvals, stopped actions, access requests, budget pauses, tasks past the round limit, and rule checks that could not run. One item covers an offline orchestrator. |
| Decided for you | Every call the orchestrator made alone: questions it decided and outward actions it approved, marked when they cannot be undone. The owner can overturn a decision. |
| Activity | The event log as a feed, with the Important and Everything filter. No chat. |
| Agent roster | Seats with provider, model, effort, role, on or off, and last polled. Connecting a seat creates its token and picks its credential. |
| Projects | The list, each brief, budget and pause. |
| Settings, Rules | Each rule's switch, moment, scope, checker, and parameters or instruction. Save, revert to default, add a custom rule. Each row shows how often the rule ran, its average time and its tokens. |
| System health | One line on every screen: whether the timer sweep and the orchestrator are running. |
| Credentials | Its own tab in the left pane. Logins and API tokens grouped by provider, each account's limits and available resets, the handoff order, Refresh and Verify all, and the Add credential pop-up. Built in its own milestone. |

Settings has four sections: Rules, Skills, Roles and Analytics. Later: the Analytics section, the Skills and Roles sections, Routines, the Activity chat and the orchestrator conversation.

## Quality requirements

| Area | Requirement |
| --- | --- |
| Atomicity | A command commits its state change, events, steps and rule check rows together, or changes nothing. |
| Ordering | Events are ordered per workspace in commit order. A reader that follows `seq` never misses a committed event. |
| Idempotency | Repeating a mutating call with the same key writes nothing new and returns the command's current outcome. Keys are kept for at least 7 days. |
| Clocks | Every duration comes from the database clock. Timer events carry their due time, and no step has a negative duration. |
| Timers | Due timers are applied before any command on the same task. A sweep triggers the rest at least every 30 seconds and records each run. |
| Speed | App-run checks add at most 50 ms to a transition at the 95th percentile. Writing events and steps adds at most 20 ms. Both are guesses until they are measured with 50 active seats in the core-loop milestone. |
| No silent waiting | If the orchestrator is offline, the owner sees one Needs you item within 90 seconds, and waiting checks queue again on their own when it returns. |
| Security | Seat tokens are stored hashed, shown once, revocable and sent as bearer tokens. Each role reaches only what the Roles table allows. Results returned by models are validated against fixed shapes and treated as data. |
| Privacy | Event payloads hold no content. The server sends content only to seats, and the roster shows each seat's provider. Deleting a task's or a project's content leaves its timing intact. |
| Audit | Every rule change, override, approval and hold has an actor and a time. |
| Deletion | The owner can delete the content of a task or a project, and remove a seat or a custom rule. Each writes an event. |
| Backups | The database is backed up daily and a restore is tested before release, because the log cannot be rebuilt. |
| Migrations | After the core-loop milestone, schema changes are forward-only and never rewrite events. |
| The app's own health | The server logs every refused command and every error, and exposes the sweep's last run and the queue lengths. |

Tests that must exist before release:

1. **Replay.** Rebuilding from the log reproduces the columns listed under Data model.
2. **Step partition.** For random command sequences, each task's steps touch end to end and sum to its lifetime.
3. **State table.** Every state and command pair either transitions as specified or is refused.
4. **Gate.** For each gated hook, a transition with an enabled gate rule and no result row cannot commit. For each policy hook, the rule's effect is tested on and off.
5. **Idempotency.** Every mutating call is repeated and writes once.
6. **Concurrency.** Twenty seats claim at once and no task is claimed twice. A reader tailing by `seq` at the same time never sees a number lower than one it has seen, and never a gap that fills later.
7. **Timers.** A command that arrives after a lease's due time is refused before the sweep has run, and the expiry is recorded at the due time.
8. **Golden traces.** Six to eight command sequences with their exact expected events and steps. Every track builds against them.

## Build order and tracks

The contract is written first by one person. After that, seven tracks with separate ownership can run in parallel.

### Milestones

1. **Contract.** Everything two tracks touch, written and reviewed before anything else starts:
   - the migrations for every table under Data model;
   - the event type registry with payload schemas;
   - the table of states and commands, for agents and for the owner;
   - the step table: which event opens and closes which step;
   - the hook list with what a failed gate does;
   - the job kinds with their input and result shapes;
   - the role table and the fixed lists: hold reasons, check results, refusals;
   - the interface schema for agents and for the owner, with the `GET /v1/next` response;
   - the in-process interface between the transition function and rule gating;
   - the shape of a credential reading, and what each provider's reader returns;
   - the golden traces.
2. **Core loop.** The transition function with timers, event append, steps and leases. Seat sign-in, idempotency and the agent calls for claim, briefing, pass, submit and review. Three owner commands: connect a seat, add a task, complete its contract. No rules yet. Two runner seats, a builder and a reviewer, finish a task end to end, including one failed review. The runners use whatever login is active on the machine. Speed is measured here.
3. **Rule checks.** Rule records and versions, hooks, app checkers, the orchestrator seat and model check jobs, pending transitions, timeouts, overrides, rules in the briefing, the Rules settings and the Timing section.
4. **Questions and approvals.** Worker questions, outward actions and the Finishing state, escalation, Needs you, Decided for you and budget holds.
5. **Credentials.** The Credentials screen, the add pop-up, usage and reset readers for each provider, a credential on each seat, and handoff when a limit is hit.
6. **Analytics page.** Its own PRD, over data collected since the core-loop milestone.

### Tracks

| Track | Owns | Needs first | Verified by |
| --- | --- | --- | --- |
| A. Core engine | Transition function, timers, event append, step tracker, replay | The contract | Tests 1, 2, 3, 6 and 7 |
| B. Rules engine | Rule records, scopes, checkers, check jobs, pending transitions, overrides, briefing | The contract, including the gating interface | Test 4, plus timeout and override tests |
| C. Interfaces | Agent and owner HTTP calls, sign-in, idempotency, the sweep trigger | The contract | Test 5, plus tests against the interface schema |
| D. Clients | MCP server, reference runner | The interface schema | A full task run against C |
| E. Web app | The screens listed above | The owner interface schema and F's queries | Browser tests of each screen |
| F. Read queries | Timing and rule queries, the task timeline | The tables and the golden traces | Query tests on logs produced from the golden traces |
| G. Credentials | The machine helper, the usage readers for each provider, the add flow, handoff and the Credentials screen | The contract, and C for the owner commands | The acceptance criteria for Credentials, with recorded provider replies for the readers |

Every track starts from the contract. B and C build against the gating and transition interfaces with stubs, then integrate on A. Track A owns all timer logic, and the sweep in track C only triggers it. Folder names are fixed when the stack is chosen.

## Release acceptance criteria

Version 1 is done when every line below is shown to hold.

- [ ] A task added through the form reaches Done through a builder seat and a reviewer seat run by the reference runner, with no manual database change.
- [ ] Every command in that run wrote exactly the events the lifecycle table names for it, and the replay test passes on its log.
- [ ] The task page shows steps that sum to the task's lifetime to within one second.
- [ ] With the acceptance-criteria rule on, no call can move a task without criteria into Ready. With it off, the same call succeeds.
- [ ] A model-checked rule blocks a submit. The reason reaches the builder and the check's attempts show queue time and run time.
- [ ] Stopping the orchestrator's runner opens one workspace-level Needs you item within 90 seconds. Starting it again queues the waiting checks without any click.
- [ ] An override on a failed check lets the task proceed and is recorded with who, when and why.
- [ ] Editing a rule creates a new version. Earlier checks still show the version they ran against.
- [ ] A reviewer from the builder's provider is refused while the provider rule is on.
- [ ] A command sent after a lease's due time is refused before the sweep runs. The steps show waiting in Ready from the due time.
- [ ] A reviewer whose runner is stopped loses the review, and another reviewer claims it.
- [ ] A task with an outward action cannot have it approved before its review passes, and is not Done until the action is reported done or waived.
- [ ] Every outward action the orchestrator approved appears under Decided for you.
- [ ] Cancelling a task with a pending check withdraws the check, and the holder's next call is refused with `task_cancelled`.
- [ ] Repeating each agent call with the same key writes no second event.
- [ ] No seat can read or change anything outside what the Roles table allows.
- [ ] A database restore from backup passes the replay test.
- [ ] The speed targets are met, or the measured numbers replace them in this PRD.

## Risks

| Risk | Effect | Response |
| --- | --- | --- |
| Agents act outside the app | An agent with its own credentials can publish or send without asking, and the gate is bypassed. | Version 1 gates only what goes through it, and the briefing says so. Keep outward credentials away from agents where possible. Later the app carries out outward actions itself. |
| Model checks become the bottleneck | Each model check adds queue time and run time to a transition. | Use app checkers wherever a rule allows. Judge applicability once per task. Show every rule's time. Enforce timeouts. |
| The orchestrator is down | Blocking checks fail closed and tasks stall. | One Needs you item appears within 90 seconds, and waiting checks queue again when it returns. The owner can override a check or set a rule to warn. |
| A rule that cannot be satisfied | With one provider connected, the provider rule leaves no eligible reviewer and reviews wait forever. | The server detects a rule that no connected seat can satisfy and opens a Needs you item. |
| Cost is self-reported | The budget rule depends on what agents report. | Label spend as reported. Reconcile with provider billing later. |
| Task content steers a checker | Text in a task could talk a model checker into passing it. | Fixed verdict shape, the builder never checks its own work, and overrides and verdicts are audited. |
| Evidence is a link | The app cannot verify that evidence shows what it claims. | That is the reviewer's job. The app records the link and who attached it. |
| Payload schemas change | Old events become unreadable. | Versioned schemas, readers that handle every version, and the replay test in continuous integration. |
| The per-workspace lock limits throughput | Appends in one workspace run one at a time. | Acceptable for tens of seats. Revisit if a workspace passes about 100 commands a second. |
| Scope | This PRD covers the whole loop, not only logging. | Milestones are separable. The core loop without rules is already useful and already logs everything. |
| A model approves actions that cannot be undone | The orchestrator decides on publishing, paying, sending and deleting, partly from text a builder wrote. | Approval comes only after an independent review. Builder text reaches the orchestrator as quoted material. Every approval is listed under Decided for you. Whether paying and deleting should always wait for the owner is an open decision. |
| Undocumented usage sources | Claude's reset entry and the captured usage screens of Antigravity and Grok Build can change with any tool update. | Each reader checks the tool's version and shows "unavailable" instead of a wrong number. |
| Running a provider's tool from another app | A provider may not allow its subscription tool to be driven by another app. | Check each provider's terms before release. API tokens are the alternative. |

## Open decisions

Each needs an answer before the contract is written. The recommendation is what this PRD assumes. Fourteen came out of the adversarial review, and the last six came with Credentials.

| Decision | Recommendation | What depends on it |
| --- | --- | --- |
| Stack and hosting | One server process with PostgreSQL. | The workspace lock and the state trigger are written for PostgreSQL. |
| Where it runs | One installation per owner, on the owner's own machine or a server the owner controls. | Sign-in, row-level security and the operator view. A hosted service for many owners is a different build. |
| How the orchestrator runs | As a seat that pulls jobs, like any other agent. | The server holds no provider code and every model call is timed the same way. The cost is that a runner must always be on. The alternative is the server calling a provider directly. |
| First provider | Claude, through the MCP server and the reference runner. | With one provider the provider rule cannot be satisfied. Either connect a second provider for reviews or ship that rule off. |
| A blocking check that cannot run | Fail closed, with an owner override. | Safer, but work stalls until the owner acts. |
| Is a review always required | Yes in version 1. | It keeps the state machine simple. The alternative is a per-project switch. |
| Default limits | 60-minute lease, 2-minute check queue timeout, 5-minute check run timeout, 3 review rounds, 3 re-runs of a model check per round. | How fast a stuck seat or check is noticed. |
| Who may override a check | The owner only. | Whether the orchestrator may override on the owner's instruction comes with the orchestrator conversation. |
| Event retention | The life of the workspace. | Storage, and what a deleted task leaves behind. |
| Where agents' work lives | The app stores a reference only. | Branches, folders and file access stay with each agent's own tools. |
| When an outward action may happen | Only after the review passes. | The Finishing state. Allowing it earlier would put the action outside the review. |
| Orchestrator approves outward actions by default | On, as chosen for the prototype, with every approval under Decided for you. | The reviewer advises that paying and deleting always wait for the owner. |
| Contract edits after Ready | Allowed. The task returns to Backlog and its holder is released. | Whether a wrong criterion can be fixed without cancelling. |
| Tasks per seat | One task or review at a time. | Claim eligibility and how many seats a busy workspace needs. |
| A claimed task that waits on the owner | The seat keeps its claim and the lease clock pauses. | The alternative frees the task and loses the seat's context. |
| Rework | The same builder first. After 3 rounds the task comes to the owner. | How long a bad task can loop. |
| How the owner is told about Needs you | In the app only in version 1. | Email or push is a later addition. |
| What the orchestrator may read | Only the project of the task its job names. | Whether answers "from the record" can draw on other projects. |
| Token cost of model checks | Recorded per rule and counted against the project's budget. | Whether rule cost shows in money as well as time. |
| Per-criterion timing | Agents announce the criterion they start. Time that is not announced is reported as unattributed. | How exact the per-criterion numbers are. |
| Turning a rule off while tasks wait on it | Those checks are withdrawn and the tasks proceed at once. | What the switch does to work in flight. |
| Deleting | The content of a task or project can be deleted. Its timing stays. | Privacy, and what the log keeps. |
| Cancelled tasks | Hidden from the board, shown under a filter. | The board's lanes. |
| Is this product Campus | Treat the existing Campus credentials work as the base and reuse its usage readers. | Whether Credentials is new work or a description of what already exists. |
| Handoff to another provider | Allowed. Handoff follows the list, whatever the provider. | The model doing a task can change part-way through. The alternative keeps handoff inside one provider. |
| Figures a provider does not report | Hidden, except resets, which show a dash. | How uniform the account rows look. |
| Percent used or percent left | Used only. | The wording on every limit tile. |
| Reading Claude's resets from its cache | Yes, behind a version check, showing 0 only when the entry is present and empty. | The entry is undocumented. The alternative is to show a dash for Claude until a supported source exists. |
| Spending a reset from the app | Not in version 1. The count is shown only. | Campus already has a redemption flow for Codex that could be brought in later. |
