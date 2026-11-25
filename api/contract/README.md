# The contract

This folder is the one home of everything two parts of Leverage share: the
fixed lists, the event payload schemas, the state, step, hook, job, role,
timer and Needs you tables, the interface schema and the golden traces.

What it must contain is set by the PRD's Contract milestone
([Build order and tracks](../../docs/PRD.md#build-order-and-tracks)). The
PRD says what each list means; this folder says how it is written down.
Nothing here restates a PRD rule: a file names a PRD value by its spelling
and leaves its meaning to the PRD.

## Files

| File | What it holds |
| --- | --- |
| `registry.json` | The fixed lists and every name the other files use. |
| `payloads/<type>.v<n>.json` | One JSON Schema per event type and version. |
| `state_machine.json` | Each command: from-state, guard, to-state, caller, hook, events. |
| `steps.json` | The step kinds and the events that open and close each. |
| `hooks.json` | The hooks, what a failed gate does, hashed inputs, moment names. |
| `shipped_rules.json` | The seven shipped rules, their version-1 fields. |
| `jobs.json` | The job kinds: who claims them, timeouts, their input and result components. |
| `roles.json` | The five seat roles: may change, may read, the roles each acts as, whether it gets a role file, General work and job instructions, calls (every role may read `GET /v1/join`). |
| `timers.json` | Each timer: scope, due-time source, events. |
| `needs_you.json` | The Needs you items, their choices and the facts each stores. |
| `readers.json` | The credential readers per provider, and which are provisional. |
| `goal_fold.json` | How a task's goal was folded into its details, with examples (decisions.md, UI-1). |
| `models.json` | The model catalog: each login provider's models, the efforts each accepts and its default model, each with how it is known (decisions.md, UX-4). |
| `openapi.json` | The agent, owner and helper interfaces, in OpenAPI 3.1. |
| `traces/<nn>-<name>.json` | The golden traces. |
| `meta/<file>.schema.json` | The shape of each data file above, in JSON Schema 2020-12. |
| [`decisions.md`](decisions.md) | The choices made where the PRD leaves a gap, under the IDs the files cite (`plan SM-24`, `"decision": "DB-31"`). |

The tests under `api/test/contract/` validate each data file against its
meta-schema and check every name it uses against `registry.json`.

## Formats

- **JSON, everywhere.** Ruby (`json`), Python (`json`) and Swift
  (`JSONDecoder`) all read it with no extra parser. Two-space indentation, a
  newline at the end, UTF-8. An array of small objects may keep one object
  per line.
- **JSON Schema 2020-12** for every schema, with
  `"$schema": "https://json-schema.org/draft/2020-12/schema"`.
  `json_schemer` (in `api/Gemfile`) validates them.
- **OpenAPI 3.1** for `openapi.json`.
- No comments inside JSON. A schema explains itself in `description`; a
  table row cites the PRD in a field the file's meta-schema defines.

## Names

- Values of every list are lower snake case: `in_review`,
  `credential_limit`, `not_suited_to_this_seat`.
- Event types and hooks keep the PRD's dotted form: `task.claimed`,
  `task.before_ready`. Four hooks share their name with an event type
  (`action.requested`, `review.failed`, `question.asked`, `cost.reported`);
  they are still two lists, `hooks` and `event_types`.
- A `table.column` string names a database column: `tasks.lease_due_at`.
- Operation ids are snake case (`claim_next_task`); OpenAPI component names
  are upper camel case (`RuleCheckJobInput`); path segments are lower case
  with hyphens (`/v1/tasks/claim-next`) and path parameters are `{id}`,
  `{cid}`, `{aid}`, `{qid}`, `{key}`, `{provider}`.
- JSON fields are the Data model's column names in snake case. A reference
  to a row is `<name>_id`; a polymorphic reference is `<name>_kind` plus
  `<name>_id`. `test/contract/columns_test.rb` holds the interface
  components, the shipped rules and the traces to the columns of
  `api/test/db/expected_schema.rb`, with a short cited list of fields that
  are not a column.
- A duration that is a setting is integer seconds with a `_seconds` suffix:
  `workspaces.lease_length_seconds`, `rule_versions.queue_timeout_seconds`.
- Two columns do not carry the PRD's word, because Active Record reserves
  it: a step's class is `task_steps.step_class` and a briefing's hash is
  `briefing_acknowledgements.briefing_hash`. `steps.json` keeps `class` for
  the PRD's step table it copies.
- Use the PRD's [Terms](../../docs/PRD.md#terms). A word the PRD does not
  have is not coined here.

## `registry.json`

The registry is the authority for its lists. Every other contract file, test
and track uses its names and never types a list of its own. Its shape is
`meta/registry.schema.json`; its consistency is `registry_test.rb`.

Four lists are also tables or sentences in the PRD, and
`scripts/check_registry.py` (the "Registry matches the PRD" job) fails when
the two differ:

| Key | Entry | Compared with the PRD |
| --- | --- | --- |
| `event_types` | `type`, `group` (the PRD's group cell), `subject_kinds`, `schema_versions`, `written_as_side_event` | type and group |
| `hold_reasons` | `reason`, `lease_clock` (`pauses`, `runs`, `no_lease`), `in_blocked`, `step`, `needs_you_item` | reason, lease clock, In Blocked, step |
| `refusals` | `code`, `precedence` (1 is returned first; `null` for a claims-only code), `claims_only`, `owner_only` | code, order, claims only, owner only |
| `check_results` | a string | the value |

What the other fields mean:

- `subject_kinds` lists the `subject_kind` values an event of that type may
  carry, each from `lists.event_subject_kinds`; `null` in the list means
  the event may have no subject, because it is about the task, the project
  or the workspace itself.
- `written_as_side_event` is true for the types any command may write
  beside the events of its own row, as the paragraph under the PRD's
  lifecycle table lists them: every `check.*` and `job.*` type, `hold.*`,
  `inbox.*`, `credential.switched`, `action.lease_granted` and
  `action.revoked`.
- `needs_you_item` is the item the hold's row of the PRD's Needs you
  choices table opens, from `needs_you_items`, or `null` when none does.

The other keys are lists the PRD does not table, or names other files need:

| Key | What it is |
| --- | --- |
| `release_reasons` | The reasons `task.released` carries. `chosen_by: seat` reasons are the ones a seat may send with release; `chosen_by: app` reasons are written by the server. Kept in the registry only. |
| `next_kinds` | The kinds of `GET /v1/next`, in precedence order: the first true one is returned. |
| `step_kinds` | The step kinds. `steps.json` gives each its class and events. |
| `needs_you_items` | The Needs you items, one per row of the PRD's Needs you choices table. `needs_you.json` gives each its choices. |
| `hooks` | Every hook. `hooks.json` gives each its details. |
| `custom_rule_hooks` | The hooks a custom rule may use. |
| `commands` | Every command of the state table: the lifecycle rows, the commands with no lifecycle row, and the timers, which the server runs as commands with the app as caller. Each has one or more rows in `state_machine.json`. |
| `operations` | Every HTTP call: `operation_id`, `method` (`GET` reads, `POST` changes something), `path`, `caller`, `commands` (the `commands` it can run, or `["read"]`), `tag`. `openapi.json` has exactly these operations. |
| `job_kinds` | The job kinds, each naming the `openapi.json` components that hold its input and result shapes. |
| `guards` | The conditions a state-table row or a conditional event may name. |
| `due_time_sources` | The columns a timer's due time is read from. |
| `policy_effects` | For each policy hook, the effects an `applied` check may record. |
| `credential_providers` | The nine providers with their `kind` and `provider_group`. The provider rule alone compares by `provider_group`, so that a login and an API token of one vendor count as one provider. |
| `lists` | Every other closed vocabulary, as `{name: [value]}`. |

An operation's `caller`:

| Caller | Who |
| --- | --- |
| `any` | Any signed-in seat. |
| `builder`, `reviewer` | A seat with that role, or a General seat (`roles.json` `acts_as`). |
| `holder` | The task's holder (the builder with the lease, or the provisional claimant). |
| `job_claimer` | A seat whose role claims jobs: the orchestrator claims rule checks, questions and approvals, the planner claims contract drafts, and a General seat claims all four. |
| `job_holder` | The seat that claimed the job. |
| `creator` | An enabled seat whose permissions include Create tasks (UX-11, UX-13c). |
| `owner` | The owner's signed-in session (`sign_in_owner` itself takes the sign-in identity instead). |
| `helper` | The helper, with its own token. |
| `public` | No sign-in: the infrastructure health check, and setup on a new installation (whether an owner exists, and creating it, which is allowed once). |

### Adding a name

- **A value of one of the four PRD-compared lists** is a change to the PRD
  first. Edit the PRD table or sentence and the registry in the same pull
  request; the check fails until both agree.
- **A name another file needs** (a command, a guard, a due-time source, a
  list value) is added to its list here with one small edit, in the same
  pull request as the file that uses it. Do not reformat the file.
- **A new event type** needs a PRD change and a `payloads/<type>.v1.json`.

## Event payloads

`payloads/<type>.v<n>.json` holds version `n` of `<type>`'s payload schema,
one file for each number in the type's `schema_versions`. Every file follows
`meta/payload.schema.json`:

- `title` is `"<type> v<n>"`; the root is `"type": "object"` with
  `"additionalProperties": false`, `properties`, `required` and at least one
  entry in `examples`, each of which validates.
- A payload holds ids, numbers and short fixed values only (PRD, Event log,
  [principle 7](../../docs/PRD.md#principles)). Every string property, at
  any depth, is closed: an `enum` or `const` drawn from a registry list,
  `"format": "uuid"`, or `"format": "date-time"`. There is no free text, so
  a reason a model or a person wrote stays on its own row, never in the log.
- An id is `<name>_id` with `"format": "uuid"`. A credential is named by
  `credential_id` only.
- A time is an RFC 3339 string with `"format": "date-time"`. Tokens are
  integers. Spend is a JSON number in US dollars, as reported, with at most
  six decimal places (the database keeps `numeric(14,6)`).
- A field that may be absent in fact is required and `null`, so every
  version has one shape.

**Versioning.** A released version is never edited. A change adds
`payloads/<type>.v<n+1>.json` and appends `n+1` to the type's
`schema_versions`; the server writes the newest version, and every reader
handles every listed version. Old events are never rewritten. Until the
first release of Leverage no log holds an event a released build wrote, so
a version may still change in place; each such change is recorded in
[decisions.md](decisions.md) (DB-48 is the first, DB-49 the second).
`task.created` is the one type with two versions: version 2 is the shape
every task is written in, and version 1 is kept for the logs that hold it
(DB-56). `EventLog.append` takes no version, and the golden traces hold
only newest versions (`test/contract/traces_test.rb`).

## The event record

The PRD's [event record](../../docs/PRD.md#the-event-record) is the
authority. How its fields are filled:

- `actor_kind` is `owner`, `seat` or `app`; `actor_id` is the user, the
  seat, the helper for an event its report caused, or `null` for the
  server's own timers and requests.
- `round` is `null` exactly when `task_id` is `null`.
- `subject_kind` is `null` when the event is about the task, the project or
  the workspace itself; otherwise it is one of the type's `subject_kinds`.
- `command_id` is the caller's `Idempotency-Key`. A helper report is a
  command, so its events carry the helper's key. Events the server writes on
  its own carry none.
- `at` is the database clock, read once after the workspace lock, and every
  event of one command shares it. When the clock reads earlier than one
  microsecond after the workspace's last event's `at` (it can step back),
  `at` is that instead, so `at` strictly increases from one command to the
  next and two commands never share it.
- `effective_at` equals `at` except for a timer's events, which carry the
  due time, or the latest `effective_at` of the task's events when that is
  later. An event a workspace timer writes on a task takes effect no
  earlier than that task's latest event either. So `effective_at` never
  decreases within a task.

## The state table

`state_machine.json` has one group per row of the PRD's lifecycle table
(`source: prd`, with the row's six cells verbatim in `prd_cells`) and one
per set of commands the table does not list (`source: derived`, with the
PRD lines and the plan decision). Each group has rows, one per command,
from-state and guard:

- `from` and `to` are task states. `from: null` means the command does not
  read a task's state (Add task has no task yet).
- `guard` is a conjunction of guards from the registry's `guards`. Every
  reachable combination of the families a command and from-state name
  matches exactly one row. A row accepts any value of a family it does
  not name. The rows explain when the previous builder cannot hold this
  task (AE-16). A command and state with no row is refused with
  `invalid_state`.
- `events` are always written; `conditional_events` are written when their
  `when` guard holds. The PRD's Events cell is these two together.
- `side_events` are the events the paragraph under the PRD's lifecycle
  table lets any command write beside its row. Two that a verdict writes
  and that paragraph does not name, `cost.reported` and `project.paused`
  (PRD Cost), are declared once in `side_event_exceptions`.
- `builder_lease` is `claim`, `fresh`, `ends` or `null`. Every event that
  grants a fresh lease names the seat in `lease_seat_id`.
- `holds_opened` and `holds_closed` name hold reasons; `refusal` marks a
  refused row, which has no `to` and no events.
- `commands` gives each command's `work_call`, `blocked_by_hold` and
  `allowed_while_pending`, with a `note` where the PRD needs reading;
  `action_machine` is the outward action's own states. A guard about one
  action can name the `action_states` it holds in. Action events that move
  the action follow `action_machine`. `action.overturn_recorded` records
  an overturn after the action is done and leaves its state unchanged.
  A command without a move from the action's state is refused with
  `invalid_state`. The audit-only overturn follows its own rows.
- An operation that runs another command's rows names both (the verdict
  runs `pass_review` or `fail_review`; a job result may run
  `approve_action`), so the lease rule of the run command applies. An
  override of the failed check that stopped an action follows the
  approval's task and lease rows and uses the `override_check` action
  move (AP-15).
- `who_in_other_rows` on a group names a caller of the PRD's Who may ask
  cell whose part other rows write (the app's own holds).

`scripts/check_contract_tables.py` (in the "Registry matches the PRD" job)
compares every `prd_*` field and every `source: prd` group here (their
from-states, to-states, callers, hooks and events), in `steps.json`,
`hooks.json`, `needs_you.json` (with the operations of the choices),
`roles.json` and `shipped_rules.json`, the agent calls and `GET /v1/next`
kinds of the registry, and the commands a hold blocks, with the PRD's
tables. A From cell of "Any" means every state but Done and Cancelled; a
To cell "X, once ..." also names the state the task starts from.

## Golden traces

Traces 01 to 08 run in a workspace with the shipped rules; 09 to 15 run in
a workspace with no rule at all, as the core loop creates it, so their
`setup.rules` is empty. The Rule checks milestone's 16 to 19 run with the
shipped rules too: 16 with all seven on, 17 and 18 with "Every task needs
specific details" off and the custom rules their own commands add, and 19
with none, its first command writing them (`install_shipped_rules`).
Trace 18 sets a 300-second lease, so that a lease ends before a claimed
check's run timeout.

Each `traces/<nn>-<name>.json` follows `meta/trace.schema.json`: a `setup`
(settings, users, helpers, credentials, seats, projects and rules that
exist before the trace starts), then `commands` in order. Each command gives
`at`, `caller`, `command` (from `commands`), `operation_id` (or `null` for a
timer), `key`, `path_params`, `body` and `expect`: the `outcome`, the
`refusal`, every event it writes in `seq` order, the steps it opens and
closes, and optionally `result_fields`, fields of the result the trace
fixes (trace 05 shows the credential and model its claims run on).

Values in a trace are written as symbols, never as literal ids or times:

| Form | Means | Bound to |
| --- | --- | --- |
| `$kind:name` | The id of a row, or a key (`$task:1`, `$seat:builder`, `$key:claim`). | A UUIDv5 of the symbol under one fixed namespace. |
| `@event:n` | The trace's n-th expected event, counted from 1 across all commands. Each expected event names itself in `ref`. | That event's id. |
| `@t:s` | `s` seconds after the trace starts (may be negative). | An ISO 8601 instant. |
| `app` | As a `caller`: the server or a timer. | Itself. |

`Leverage::Contract::TraceBinder` does the binding and raises on any other
string that starts with `$` or `@`. An expected event lists every column
but `workspace_id` and `seq`, with its full payload: after binding, the
payload validates against its type's schema unchanged, and a field the
writer adds that the trace does not list is a failure. The events that
`setup` implies (the shipped rules' `rule.created`, for instance) are not
part of the trace. Setup rows and step rows use column names; a rules row
also carries `current_version_id`, the version its checks name.

How the traces write what the PRD leaves to the writer:

- **Timers** are commands of their own, with caller `app`, no operation and
  no key. Their events carry the due time as `effective_at`.
- **The server's own requests** inside a seat's command (the checks and
  jobs at `action.requested`) carry actor `app` and no key. Every other
  event of a seat's or the owner's command carries that command's key, or
  the key of the pending command it completes.
- **A check's identity** (`subject_kind`, `subject_id`, `input_hash`) is
  in `check.queued` and `check.finished`. In a trace one set of hashed
  inputs carries one digest, the same for every attempt of one check, and
  two sets two digests. The digests are made up, except trace 07's: its
  two checks hash one request and carry the engine's own hash of it.
  `action.lease_granted` carries actor `app` and the key of the command that
  frees the builder.
- **A pending transition's completion** carries the original requester's
  key, and its `cause_id` is the `check.finished` that completed it, even
  inside another caller's command. The check held at the re-run limit
  never ran and writes no `check.finished` until it is withdrawn, so a
  completion the owner's "Let it through once" on it gives names that
  `check.overridden` (milestone 4 plan RD-45, RE-3; trace 17).
- **Order** inside a command: the hook's check events, the row's events,
  `cost.reported`, then the other side events. Two exceptions (milestone 4
  plan section 2.1): a waiting command ended from outside (rule 11) writes
  its withdrawals first (`check.finished` withdrawn, `job.withdrawn`) and
  then the row's own event (`task.released`, `task.lease_expired`,
  `review.lease_expired`, `task.cancelled`; trace 18); and Complete
  contract closes an open `contract_incomplete` hold first (L175), before
  the hook's check events (trace 16). A job result writes `job.finished`,
  the check's `check.finished`, `cost.reported`, then the holds and items,
  then the requester's completion; a planner's draft that waits writes
  `job.finished` and `cost.reported`, then its Complete contract's check
  and job events (RE-6).
- **Round**: every event of a command carries the task's round before the
  command; `review.failed` and `task.returned_for_rework` raise it for what
  follows, and a step they open carries the new round.
- **`cause_id`** is set only for a chain the PRD names or that is plain (a
  completion, a helper report's later events, an item opened by a hold);
  otherwise it is `null`.
- **Jobs** are claimed oldest first. Each attempt is a job of its own:
  `job.requeued` is written on the job that timed out, and the next
  `check.queued` names the new one.

## How each side reads it

- **Ruby.** `Leverage::Contract` (`api/lib/leverage/contract.rb`) reads
  each file once, deep-frozen: `registry`, `list(name)`,
  `event_type(type)`, `payload_schema(type, version)`,
  `validate_payload(type, version, payload)` (returns the errors, empty
  when valid; raises `KeyError` for an unregistered type or version),
  `state_machine`, `steps`, `hooks`, `shipped_rules`, `jobs`, `roles`,
  `timers`, `needs_you`, `readers`, `models`, `openapi`, `trace(name)`,
  `meta_schema(name)` and `load(path)`. The folder is `Rails.root/contract`,
  or this folder found from the file when Rails is not loaded. The Docker
  build context is `api/`, so the image holds the contract.
- **Python.** `scripts/` reads the JSON files with the standard library and
  `docs/PRD.md` beside them. The PRD is not in the image, so every
  comparison with the PRD is a Python check.
- **Swift.** SwiftPM takes no resources from outside `mac/`.
  `mac/Tests/LeverageKitTests/RegistryDecodingTests.swift` finds
  `registry.json` from its own path and decodes it into plain `Codable`
  structs with explicit coding keys (`.convertFromSnakeCase` would also
  rewrite the keys of `lists`). No Swift code reads the contract at run
  time yet.

## Tests

Contract tests need no database. Each starts with
`require_relative "contract_helper"` and may `include ContractTestHelpers`
(`registry`, `meta_errors(name, data)`, `duplicates(values)`). Each file's
own test asserts against `registry.json`; `traces_test.rb` and
`columns_test.rb` then tie the files to each other and to the columns. No
test holds a copy of a PRD table or a hard-coded count. From the
repository root, with `.env` in place:

```bash
docker compose run --rm --no-deps --entrypoint "" -v "$PWD/api:/rails" api bin/contract_test
docker compose run --rm --no-deps --entrypoint "" -v "$PWD/api:/rails" api bin/contract_test test/contract/registry_test.rb
python3 scripts/check_registry.py
python3 scripts/test_check_registry.py
python3 scripts/check_contract_tables.py
python3 scripts/test_check_contract_tables.py
python3 scripts/check_model_catalog.py
python3 scripts/test_check_model_catalog.py
(cd mac && swift test --filter RegistryDecodingTests)
```

`bin/rails test` runs them too, in the same process as the database tests:
`contract_helper` then loads the application, so one Zeitwerk loader
manages `lib/`.

## Migrations

A migration's timestamp is the moment it was generated
(`bin/rails generate migration`), never a hand-typed one: a stamp set in
the future would sort after migrations generated later and run after them
on a fresh database. `api/db/structure.sql` is the schema.

## What the Core loop milestone added

The Core loop added to this contract and changed nothing in it that was
not provisional, except four things named below.

- Six operations, each a registry `operations` entry and an `openapi.json`
  operation, with a derived `state_machine.json` row with `events: []` for
  each command: `get_setup_state` and `create_owner` (the first sign-in,
  caller `public`), `sign_out_owner`, `get_helper_request` (provisional),
  `report_request_progress` and `get_landing_prompt`. The commands
  `create_owner`, `sign_out` and `report_request_progress` were added to
  `commands`.
- `HelperRequest.params` and `HelperRequest.progress`, the shapes of the
  provisional owner reads (each with `as_of_seq`), `Seat.wanted_running`,
  `LandingPrompt`, and `BriefingResponse.review_notes` (the notes of the
  task's failed reviews, outside the briefing's hash).
- Traces 09 and 10, with no rules.

The four changes to what was not provisional:

- The description of `AddCredentialRequest` now says the row is inserted
  at the Add command, so that the credential's name is kept only in its
  own row. No shape changed.
- The derived `issue_helper_token` row gained the conditional event
  `review.released` (when a seat still marked running holds a review),
  because a new helper token treats every such seat as stopped.
- The builder's `prd_may_read` in `roles.json` gained "the notes of its
  task's failed reviews", with the PRD's Roles table in the same change.
- The `task.contract_changed` v1 payload gained `minimum_strength_rank`
  (null for none), so that the log rebuilds the rank Complete contract
  sets (decisions.md, DB-48); every golden trace that writes the event
  carries it.

## What the Handoff milestone added

The Handoff milestone serves eleven operations that were already in the
contract (`report_limit`, `report_signed_out`, `sign_in_again`,
`list_inbox`, `promote_task`, `edit_contract`, `hold_task`, `resume_task`,
`pause_seat`, `resume_seat`, `change_seat`). It adds no event type, hold
reason, refusal, check result, release reason, Needs you item or choice.
What it added, each from the milestone 3 plan:

- **One workspace timer and its command**, `seat_run_placement` (HD-4):
  a `timers.json` entry fired on every sweep, a registry `commands`
  entry, and a row in the derived `timers` group that writes no event. It
  moves an idle seat's run to its first available candidate and starts
  again a run that a limit or a sign-out ended, through `start_seat`
  helper requests.
- **Meanings**, in `state_machine.json` and `timers.json`:
  `candidate_available` also holds when no candidate below the stopped
  credential is available and the seat's own credential is, and
  `no_candidate_available` is its opposite (HE-4); `owner_must_act` is
  false when a candidate between the seat's own credential and the
  stopped one is available, because the hold is then due at once (HE-4);
  `builder_free` and `builder_busy` count, for a seat the app runs,
  whether one of its candidates is available (HE-14); the due time of
  `credential_hold_release` is rule 8 of the plan's section 2.1 (HE-23).
- **Side events on four rows**: `report_request_result` may close a
  `credential_limit` hold (a passed Verify or sign-in of a credential
  limited with no reset time, HE-2, or `credential.added`, HE-10),
  resolve "Limit with no reset time", open "Account signed out" beside
  another task's `credential_limit` hold that a sign-out leaves with no
  due time, and resolve "Account signed out" while its hold stays open
  (HE-11); the six `report_signed_out` rows may open that same item
  (HE-11); `change_seat` may close the seat's credential hold when it
  gives the seat another credential, with `credential.switched` when
  `credential_differs` and `inbox.resolved` (HE-10, HE-27).
- **`needs_you.json`**: the `closes` text of `limit_with_no_reset_time`
  says that until the usage readers exist a passed Verify or Sign in
  again is the reading that shows capacity (HE-2). Its `prd_choices` is
  unchanged.
- **Descriptions**: `hold.opened`'s `credential_id` names the credential
  that stopped when no candidate has a reset time (HE-13), and the first
  signed-out candidate for `credential_signed_out` (HE-12); the two
  reports answer `completed` with a null result (HE-8) and `404` for a
  job until jobs arrive (HE-33); `sign_in_again` answers
  `helper_request_id` (HE-36).
- **Fields**: `HelperRequestParams.task_id` and `review_id`, the work a
  start request's run continues (HD-1); in the provisional reads,
  `Credential.limited_since` (HE-3), `Seat.run_credential_id` and
  `Seat.run_stop_reason` (HD-3, HD-10), `TaskPage.recovery_times`, a
  list of `RecoveryTime` (HE-17, HE-18),
  `TaskPage.waiting_for_credential_id` and `waiting_until`, the board
  card's two fields for the same task (HE-15, HE-16), and
  `SystemHealth.backup_last_ran_at` and `backup_late` (HB-4). The
  command `seat_run_placement` joins the `CommandName` enum.
- **Schema**: one migration adds `credentials.limited_since` with a check
  that `limited_until` is null unless it is set, and sets
  `strength_rank` to 1 where it was null (HE-3, HE-5);
  `seats.run_credential_id` (no foreign key, as DB-10) and
  `seats.run_stop_reason` (HD-3); and the table `backup_runs`, one row
  per dump, with no `workspace_id`, because a dump is of the whole
  database (HB-4). `db:grants` gives `leverage_app` SELECT alone on
  `backup_runs`; the owner role, which the backup runs as, writes it.

- **Traces 11 to 15**, with no rules (HT-1): `11-limit-handoff-no-rules`
  (trace 05's commands), `12-signed-out-hold-verify-no-rules` (trace
  06's), `13-limit-next-signed-out-no-rules`, `14-handoff-edges-no-rules`
  and `15-owner-controls-no-rules`.

`readers.json` is unchanged: every login reader stays provisional, with
`capture.limit` and `capture.sign_out` at `none`. `WorkspaceSettings` is
unchanged: the recovery time ceiling still has no value (HE-1).

One field is named after its column, not as the plan wrote it: the plan's
`Seat.running_on_credential_id` is `Seat.run_credential_id`, because a
JSON field is the Data model's column name (see Names) and
`columns_test.rb` holds every field of `Seat` to a column of `seats`.

## What the Rule checks milestone added

The Rule checks milestone serves twelve operations that were already in
the contract (`claim_next_job`, `submit_job_result`, `list_rules`,
`add_rule`, `save_rule`, `enable_rule`, `disable_rule`, `revert_rule`,
`remove_rule`, `rerun_check`, `override_check`, `draft_contract`), and
milestone 3's `report_limit` and `report_signed_out` now also take a
report that names a job. It adds no event type, hold reason, refusal or
check result. What it added and changed, each from the milestone 4 plan
(section 2.3), those that touch what was not provisional first:

- **The shipped instruction.** `shipped_rules.json` gives "Every task
  needs specific details" its instruction (RV-2). The placeholder
  `to_be_written_in` stays only for the rule that approves outward
  actions, and `meta/shipped_rules.schema.json` takes a string there.
  The server writes that rule's version with no instruction, so
  `list_rules` sends `null` there, as `RuleVersion` says; it never sends
  the placeholder.
- **One command and its Lifecycle row**, `install_shipped_rules` (RD-2):
  a registry `commands` entry, the `CommandName` enum, and a
  `state_machine.json` group with `source: prd` that copies the PRD's
  row "Write the shipped rules": actor `app`, no key, `rule.created` for
  each shipped rule, and the re-evaluation of "No reviewer is eligible"
  (SM-42). No operation runs it: `bin/rails
  leverage:install_shipped_rules` applies it before the server starts to
  each workspace with no `rules` row. SM-33, the shipped rules'
  `rule.created` as a workspace's first events, holds for workspaces
  created from this milestone on; an older workspace gets them from this
  command, after its earlier events.
- **One command and its Lifecycle row**, `install_imaginarium_project`
  (DB-53): a registry `commands` entry, the `CommandName` enum, and a
  `state_machine.json` group with `source: prd` that copies the PRD's row
  "Create the Imaginarium project": actor `app`, no key, one
  `project.created`. No operation runs it: `bin/rails
  leverage:install_imaginarium_project` applies it before the server
  starts to each workspace with no Imaginarium project. `create_owner`
  also writes that `project.created`, after the shipped rules' events.
- **`create_owner`'s row** writes `rule.created` for each shipped rule,
  with the owner as actor and the command's key (L434, RD-1). Its note no
  longer says the workspace starts with no rule.
- **Two guards**, `rerun_queues` and `rerun_of_claim_check`, one family
  (`rerun_target`) on `rerun_check`: an errored check at
  `task.before_claim` has already lapsed its provisional claim, so Run it
  again closes its `check_error` hold and queues nothing (RD-42).
- **Side events on rows that exist.** `claim_review` may write
  `check.finished`, the provider rule's `applied` row with effect
  `refused` for a review claim-next skips (RD-12). `disable_rule` and
  `remove_rule` close `rerun_limit` too, resolve the items of the holds
  they close, and say that a waiting command whose last check they
  withdraw completes in place under its requester's key (RD-45).
  `override_check`'s note says the same of the check held at the re-run
  limit; `submit_job_result` may open `rerun_limit` (a planner's
  contract, RE-6); `orchestrator_offline` says when its item opens and
  that only errored checks are queued again (RD-16, RD-19).
- **A waiting command ended from outside** (plan section 2.1, rule 11).
  `release_review`, `review_lease_expiry`, `report_run_stopped`,
  `issue_helper_token` (which treats a running seat's run as stopped) and
  the reviewer rows of `report_limit` and `report_signed_out` with no
  candidate left withdraw the checks and jobs of a pending pass and close
  the `check_error` and `rerun_limit` holds they opened; `pause_seat`
  withdraws a provisional claim's check and job; the builder's `release`
  from Working, `change_seat` and `remove_seat` close `rerun_limit` too.
  `timers.json`'s `review_lease_expiry` gains the same events.
  `get_command`'s description says which of RC-17's three codes each
  ending gives; RC-17 is unchanged.
- **`steps.json`**: `wait_review` closes and opens again at the provider
  rule's `check.finished`, so the new step names the rule as its cause
  (RD-11).
- **Job shapes**: `ClaimJobResult.run_due_at` (RD-34);
  `RuleCheckJobInput.material`, a `CheckMaterial` (the role file, the
  instruction, the moment, whether "not applicable" is allowed, the
  contract as a `CheckContract`, and the other task text as a list of
  `QuotedText`), and `ContractDraftJobInput.material`, a `DraftMaterial`
  (RD-30, RD-31, RD-37); `RuleCheckJobResult.reason` at most 500
  characters (RD-31). `claim_next_job` and `submit_job_result` say what a
  seat that already holds a job gets and what a late result answers
  (RD-40, RD-41).
- **Descriptions**: `BriefingRule.instruction` holds an app rule's
  sentence (RD-62); `BriefingResponse.review_notes` carries a rule's
  name and reason after a failed check at "when the review has passed"
  (RD-38).
- **A registry list**, `lists.orchestrator_tested_providers`: the login
  providers whose tool's default model passed the eval suite (RV-5).
  The managing agent's run of the suite set it to `claude`, `codex` and
  `gemini`; `scripts/check_evals.py` holds it equal to the results that
  met the bar. It refuses nothing, and `meta/registry.schema.json` lets
  it be empty.
- **`needs_you.json`**: the `orchestrator_offline` item opens only while
  a check waits (RD-16); `facts.waiting_checks` is the count now (RD-18);
  `facts.role` keeps `planner`, which is never written (RD-20).
- **Provisional reads**: `RuleWithVersion` gains `sentence`,
  `moment_name`, `acts` and `stats` (a `RuleStats`, RD-26); `TaskPage`
  gains `steps` (a list of `TaskStep`), `lifetime_seconds`, `as_of`,
  `rule_checks` (a list of `TaskRuleCheck`, each with its
  `RuleCheckAttempt` list), `pending` (a `PendingCommand` or null) and
  `draft`; `BoardTask` gains `checking` and `check_reason`;
  `SystemHealth` gains `waiting_checks`, and its `orchestrator` keeps its
  three values with a new description (RD-17, RD-18).
- **Schema**: one migration adds `pending_transitions.params`, the
  request a pending transition completes with, with checks that it is
  null unless the state is `pending` and that it holds no token key
  (RE-2), and `jobs.attempt_number`, integer, 1 by default (DB-31).
- **Gating**: `PlannedHold.rule_check_id` may be an index into
  `Evaluation#checks`, as `Failure.rule_check_ref` already may. No
  signature changed.
- **After the milestone's adversarial review**: every task-text field of
  the requests has a `maxLength` and every list of them a `maxItems`
  (`CompleteContractRequest`, `AddTaskRequest`, `CriterionInput`,
  `ActionInput`, `SubmitTaskRequest`, `GiveVerdictRequest`,
  `PassCriterionRequest`'s evidence, `OverrideCheckRequest`,
  `AddRuleRequest`, `SaveRuleRequest`, `ReturnForReworkRequest`), so a
  longer body is `422 invalid` before any check is queued: a checker's
  tool gets the task text as one argument, which the Mac refuses past
  1 MiB. The limits count characters, not bytes, and not the evidence
  rows a task gathers, so they make a prompt over the runner's 512 KiB
  rare, not impossible: such a check starts no tool and ends in `error`
  after its two run timeouts. `LandingPrompt.check_interval_minutes` is
  20, or 1 for an orchestrator, which counts as offline 90 seconds after
  its last poll (L401), and for a planner, whose presence is not read: a
  draft it does not claim or finish in time is queued once more, then
  dropped (L399). The `cancel` rows withdraw every check of the task with
  no result and no override, a warn rule's too, and every queued or
  claimed job of the task, a contract draft's among them (L207; review
  finding 6), not only a pending transition's. `enable_rule` may open
  `claim_gate_failed` again with its item, for a Ready task that three
  seats failed the rule on (L166, L393). The heartbeat's description says
  what a provisional claimant's heartbeat answers, and the report calls
  no longer say a report that names a job is 404. The shipped rule "Two
  failed reviews move a task to a stronger model" is "Repeated failed
  reviews move a task to a stronger model" (PRD L443).

Line numbers in the notes this milestone added are those of
`docs/PRD.md` at the merge of milestone 3, as the plan cites them.

## What the Questions and approvals milestone added

The milestone serves the questions, access, cost, outward action, project,
task settings and content deletion operations already in the contract.
Its new operation is `get_workspace_settings`, an owner read at
`GET /v1/owner/settings` returning `WorkspaceSettings` (AP-37).
`ChangeWorkspaceSettingsRequest` declares the six setting bounds and
allows the recovery time ceiling to be cleared (AP-39).

- `action.overturn_recorded` v1 has an action subject and an empty payload.
  An overturn after the action is done writes it once. A repeat is
  refused with `invalid_state` (AP-13).
- The approval rows require an open owner approval hold or the result of
  the action's own approval job. The failed check that stopped an action
  can be overridden through `override_check` (AP-15). An errored approval
  check stays with the owner. The offline timer leaves it alone and
  `rerun_check` refuses it (AE-15).
- Offer task again requires an enabled, unremoved seat in the builder
  role (AP-19). If the previous builder is unavailable in one of those
  ways and approved actions remain, the task holds with
  `action_unconfirmed`. Waive closes the `check_error` hold for any
  gate it withdraws on that action. Return for rework closes
  the approval and unconfirmed holds. When the previous builder still
  holds the task and is enabled and unpaused, rework replaces its lease
  and a waive keeps it (AE-16). A re-enabled seat can still hold the
  task's paused lease. Offer task again replaces that lease. Mark action
  done keeps it when approved actions remain and the seat is available
  (AP-19). An action with an open owner approval must be approved or
  stopped before it can be waived.
- `task.created` carries the initial `action_ids` so replay can recover
  actions added with the task. Replay accepts older events without that
  field (DB-50). `action.stopped.overturned` distinguishes an open
  approval overturned by the owner from an ordinary stop (DB-51).
- A question passed on without blocking has a Needs you item with a null
  hold. The answer, overturn and content deletion rows declare which
  cases are accepted and which return `invalid_state` (AP-3, AP-6,
  AP-36). Done withdraws queued or claimed question jobs. An orchestrator's
  answer can be overturned or replaced only while the task is active.
  A passed-on question on a Done task remains answerable while the task's
  content is present. Deleting that content resolves its open Needs you item.
  A project deletion also writes `content.deleted` for each
  task whose content it deletes. A changed brief advances its version
  once. Added and removed entries write `brief.changed` at that version.
  A reorder alone records the moved entries (AP-27, DB-41).
- Complete contract and Edit contract close a budget hold when the new
  cap is empty or above the task's reported spending (AE-12). A report
  opens no budget hold on a task the command just ended. Budget, cap and
  spend requests accept at most 99,999,999.999999 dollars. A report whose
  sum would overflow a task or project total returns `422 invalid`. The
  saved spend and its event use the same six-decimal precision. If a
  running gate's cost uses the capacity a waiting verdict needs, the
  gate result still commits and the verdict is refused.
- `QuestionJobInput` carries the task's question, contract with outward
  actions, project brief, role file and earlier answers. `ApprovalJobInput`
  carries the action, contract, role file, rule instruction and quoted
  notes and evidence (AP-4, AP-5, AE-5). The result schemas limit an
  answer to 4,000 characters and an approval reason to 500.
  `shipped_rules.json` gives the model policy its instruction (AP-23).
- `get_landing_prompt` accepts `connection=http` or `connection=mcp` and
  returns the chosen form in `connection` (AM-8). Connect and Change
  seat accept strength ranks 1 to 3 (AP-24). Activity uses the registry's
  `important_event_types` list (AP-34).
- The owner inbox includes optional `detail` for access requests and
  stopped approvals. The content stays in its row.
- Delete content also clears stored claim copies and check reasons from
  command refusals. A refusal by a rule check records the check's task
  on the receipt when the check row exists.
  A task page omits cleared evidence. A stale job claim
  exposes no material when the seat no longer holds that job in the
  current role or project, or the task content was deleted. A repeat
  preserves the key and never claims new work.
- Decided for you reads expose the decision, its task and seat, and the
  result of an overturn (AP-31, AP-32, AP-35). Projects expose their
  ordered briefs, pause source, open task count and content deletion
  time (AP-26). Task pages expose the action start flag and the action
  and question details. Board cards expose the wait for a builder or a
  stronger agent. Briefings carry the current action states and the
  answered questions outside the hash.
- The migration orders existing brief entries by creation time and id
  within each project before making their positions required and unique.
  It checks the question outcome and basis lists, lets job input be
  cleared, and indexes Finishing tasks with no holder by workspace.

## What the Credentials milestone added

The milestone serves the existing owner operations for rename, remove,
Refresh, Verify all and reorder, and the helper's `report_reading`.
Refresh and Verify all return their request ids as `helper_request_ids`
in the completed outcome's result.

- `usage_read_due` is a workspace timer on every sweep. It queues due
  usage reads and writes no event (CR-10).
- The sweep and Refresh expire usage pickups older than 90 seconds.
  They use the existing failed result with `reading_taken` and
  `timed_out`. Late results cannot replace the timed-out receipt.
- A reorder writes `credential.order_changed` for each added credential
  whose rank among added credentials changed, in the new order. Reorder
  and Remove can close credential holds, switch credentials, and resolve or open
  Needs you items. Remove keeps unfinished `stop_seat` requests. The
  helper can finish a seat stop after forgetting its credential. A limit
  item also resolves if its hold has a reset time to wait for again
  (CR-28, CR-30, CR-32).
- Reorder can resolve an item whose login is no longer a candidate.
  The hold keeps its original reason and subject.
- Add and Rename trim surrounding whitespace and require a nonblank name
  unique within its provider and kind. An unchanged name writes no event.
- A reading at most 60 seconds ahead of the command time is stored
  without a credential event. To clear a limit, an `ok` reading must
  have been observed after the latest refusal in the current limit.
  Every named window refused since the limit began needs at least one
  limit figure, with every such figure below 100 percent used. When any
  refusal named no window, or no refusal is recorded, the reading must
  also include a limit figure and every limit figure must be below 100.
  When this restores a candidate, either credential hold can close at
  the command time. A passed Verify still clears an undated limit (CR-14).
- Add accepts an API token with the fixed mask `••••••••` and a login
  with a null label. The database clears any older nonconforming labels
  before enforcing those two values. The helper's successful add result
  places the credential in the handoff order and queues its first read.
  The result of `read_usage` writes no event. Verify can record
  `credential.signed_out` v1 for a rejected or missing token using the
  existing payload (CR-7, CR-13, CR-29, TK-3).
- The helper reports `token_store_unavailable` when the Mac cannot read
  or save a token, and `provider_mismatch` when the token lacks a local
  binding to the requested provider. Neither signs the credential out.
  A connection failure is `unreachable`. A token check that receives an
  unexpected HTTP reply fails with `no_answer`.
- The reading schema limits figures to 32, resets to 16, tool version
  to 64 characters, and figure labels and string values to 80 characters
  each. The account reads keep their existing response fields.
- `readers.json` names the sources and the labels, including US dollars
  in OpenRouter's money labels and Requests remaining for Claude API and
  OpenAI API. A tested tool version requires a recorded usage reply.
  Every reader stays provisional (CR-5, CR-17, RD-3, RD-5, RD-6, RD-7).
- Trace `24-reading-ends-a-limit-wait` covers when a reading clears a
  limit, how reorders change a held task's candidates, and the events and
  steps the task records (CT-3).

## What the General role added

The owner asked for a role that does everything, picked first when an
agent is connected. Its decisions are GA-1 to GA-11 in
[`decisions.md`](decisions.md#general-role-ga).

- `seat_roles` gains `general`, last. `roles.json` gains two fields on
  every row: `acts_as`, the roles whose work a seat of the role does
  (each role itself; `general` the other four), and `role_file`, false
  for `general` only. The `general` row's callers and operations are the
  union of the other four's. The Swift generator writes both fields as
  `SeatRole.actsAs` and `SeatRole.hasRoleFile` in `AgentTools.swift`.
- `jobs.json`, the state table's `who` values and the operations'
  `caller` keep naming the role whose work is done: a General seat
  satisfies `builder`, `reviewer`, `planner`, `orchestrator`,
  `job_claimer` and the rule's `checker_role` through `acts_as`. A job's
  `seat_role` stays `orchestrator` or `planner`.
- `next_kinds` puts `job` before `review`. Only a General seat can have
  more than one of `job`, `review` and `task` true at once (GA-4).
- `Briefing.role_file`, `BriefingVersions.role_file_version` and the
  `role_file` of the four job materials may be null: null for a General
  seat, whose briefing hashes no role file part. A General briefing
  carries `work_rules` for building or reviewing, outside the hash.
  The runner and both join responses use those instructions (GA-7).
  A job's stored input keeps the role file text; a claim by a General
  seat returns it as null (GA-2).
- The role enums of `Seat`, `ConnectSeatRequest`, `ChangeSeatRequest` and
  `HelperRequestParams` gain `general`. `seats.role` is not constrained in
  the database, so there is no migration.
- The guards `builder_seat_enabled` and `builder_seat_unavailable` read a
  role that builds, `builder` or `general` (GA-8).

After the design was challenged three times, the contract holds these
(decisions GA-1 to GA-11 as revised):

- Escalation counts a seat by the standing part of the claim test,
  paused or not and busy or not, as on `main`: enabled, not removed, acts
  as builder, the rank, and no `review.started` by it on the task. Claims
  add "not paused" and the momentary part; the guard `escalates` says so,
  and the Eligibility module holds both parts (GA-1). The review bar is
  lifted for a task that no other seat could build, and escalation does
  not lift it (GA-5).
- Presence: two sentences, the same in `needs_you.json` (Orchestrator
  offline's `closes`) and in the `orchestrator_offline` row, say what
  waits (a queued rule_check or approval job, or a check held with
  `check_error`) and when a General seat counts for the orchestrator:
  while it polls and holds an orchestrator job, or holds nothing and
  could claim a waiting check (`Jobs.next_for`), or holds nothing while
  none waits. Question, approval and contract-draft jobs end as before;
  `orchestrator_offline` queues an errored rule check again only when a
  counting seat is eligible for that attempt, regardless of queue order,
  and leaves other errors with the owner. Errored claim-check holds close
  when the role is back (GA-6, RC-37). A question goes to a job only when a seat
  that acts as orchestrator could claim it now (GA-1).
- `change_seat`: a change of role of a running seat the app runs, to or
  from General, queues only `start_seat`, which the helper hands over
  (HD-2); other role changes queue nothing, as before. Unconfirmed action
  opens on a change to a role that does not build (GA-8). Only a General
  seat's review work passes over Gemini logins (GA-9).
- `roles.json` gains `job_rules` on every row: four sentences for
  `general`, empty for the roles with a role file. The four job materials
  gain `job_rules`, set when a General seat claims the job, where its
  `role_file` is null. The Swift generator writes them as
  `SeatRole.jobRules`, which the eval's General mode and the runner's
  tests read (GA-7).
- `lists.general_tested_providers`: the login providers whose default
  model met both suites' bars run as a General seat, empty until the
  maintainer runs them. The Swift generator writes it as
  `ContractLists.generalTestedProviders` (GA-11). The list applies to the
  app runner's fresh job prompt on default models. A seat that connects
  on its own or names a model remains outside the eval coverage.
- `BoardTask.reviewer_seat_exists` is an optional task-level reading for
  unassigned reviews in a workspace with a General seat. The task page
  shares that reading. Ready account waits use the build claim standing
  test for each task (GA-5, HE-16). In review account waits include
  eligible General reviewers (HE-15).

## What the join call added

The owner asked that an agent connected by prompt land from one short
prompt that carries its token, and read the rest of its instructions
from the server. Its decisions are GA-12 to GA-17 in
[`decisions.md`](decisions.md#general-role-ga).

- `get_join` (`GET /v1/join`, caller `any`, tag `agent`): every role
  lists it in `roles.json`, so the generated agent tools include it. It
  answers `JoinInstructions`, the whole text for the seat's role and the
  `connection` query (`http` or `mcp`), as JSON with a `text` field
  (GA-14). The MCP form's settings name the program the API was given in
  `LEVERAGE_MCP_COMMAND` (GA-15).
- `issue_landing_prompt` (`POST /v1/owner/seats/{id}/landing-prompt`,
  command `issue_landing_prompt`, a derived row that writes no seat
  event) replaces the read `get_landing_prompt` and its `LandingPrompt`.
  It issues the
  seat's token, ending the one before it, and answers
  `LandingPromptIssued` once: the short prompt with the token in it, and
  the token. A repeat of the key answers `LandingPromptIssuedRepeated`
  (GA-13). It releases the work the seat holds, as `remove_seat` does but
  with the seat kept: the registry gains the app's release reason
  `new_prompt` for a Working task, a review is released and a job misses
  its run time at once; the row lists the events, among them the run
  timer's (`job.requeued` and `check.queued` after a first miss) and the
  holds of a last miss (`check_error`, `owner_approval`,
  `owner_question`) (GA-17).
- `connect_seat` returns no token: `SeatConnected` is the seat's id, and
  `SeatConnectedRepeated` is gone. The four one-time responses are
  `SeatTokenPickup`, `LandingPromptIssued`, `HelperTokenIssued` and
  `OwnerSession`.

## What app round 1 changed

The owner went through the app tab by tab on 2026-11-24 and asked, among
other things, that a task have no goal. Its decisions are UI-1 to UI-8 in
[`decisions.md`](decisions.md#app-round-1-ui).

- A task's goal is folded into its details (`goal_fold.json`), and
  `tasks.goal` is dropped by the migration that folds it. `AddTaskRequest`,
  `CompleteContractRequest`, `TaskSummary`, `BriefingContract`,
  `CheckContract`, `ActionJobContract` and `DraftMaterial` lose `goal`;
  their examples and every golden trace body are folded the same way. The
  requests and reads change in place (DB-48's reasoning); no event payload
  carried a goal.
- The details' limit is 24,002 characters, so a folded task can be saved
  again unchanged. `BriefingContract` gains `title`.
- `task.before_ready` hashes the title, the details, the criteria and the
  actions. Trace 07's digest is the engine's hash of its new inputs.
- The specific-details instruction judges the title, the details and the
  criteria. `shipped_rules.json` keeps the replaced default in
  `superseded_instructions`, and `install_shipped_rules` gains the
  conditional event `rule.reverted` (guard `rule_on_superseded_default`,
  added to the registry's guards), which moves a rule still at that
  default to the new one.
- `Project` gains `latest_work_reference`, read from the project's tasks,
  which Add task uses to fill "Where the work is".
- A project keeps its goal.

## What app round 2 changed

The owner's three follow-ups of 2026-11-24, after round 1: New prompt
goes, the model and the effort are picked from lists the server checks,
and every seat has three permissions. Its decisions are UX-1 to UX-16 in
[`decisions.md`](decisions.md#app-round-2-ux).

- `models.json` (shape `meta/models.schema.json`) is the model catalog,
  read as `Leverage::Contract.models` and written for the Mac as
  `ModelCatalog.swift` by `scripts/generate_swift_contract.py`.
  `scripts/check_model_catalog.py` holds it to its evidence (UX-4, UX-5).
- `issue_landing_prompt` is issued only before the seat lands: its row
  splits on the guard family `seat_landing` and the landed row is refused
  `invalid_state`; it releases nothing. The release reason `new_prompt`
  stays readable with a note (UX-1 to UX-3).
- The registry gains the list `seat_permissions`, the operation caller
  `creator`, the operations `create_task` (`POST /v1/tasks`, running
  `add_task` and `complete_contract`) and `report_model`
  (`POST /v1/seat/model`, running `change_seat` as the seat), the refusal
  `add_task_limit` (precedence 14), the release reason
  `deliver_turned_off`, the Needs you items `agent_task_incomplete` and
  `agent_tasks_at_limit`, the choices `complete_contract` and
  `draft_contract`, and the guards `seat_has_landed`,
  `seat_has_not_landed`, `turns_deliver_off_holding_working_task` and
  `turns_deliver_off_with_pending_transition`.
  `task.released`, `inbox.opened` and `inbox.resolved` v1 gain the new
  values in place (DB-48's reasoning).
- `openapi.json` gains `SeatPermissions` (on `Seat`, `ConnectSeatRequest`,
  `ChangeSeatRequest` and `JoinInstructions`), `CreateTaskRequest`,
  `AgentTaskCreated`, `ReportModelRequest`, `ReportedModel` and
  `CatalogModel` (`JoinInstructions.models`).
- `state_machine.json`: `add_task` may be asked by the `creator`,
  `complete_contract` by the `creator` in the call that adds the task, and
  `change_seat` by `self`, the seat changing its own model and effort;
  `change_seat` turning Deliver tasks off releases the Working task. The
  `builder_availability` guards say which permissions a task lease reads
  and that an action lease reads none.
- `seats` gains `may_work`, `may_deliver` and `may_create` (migration
  `AddPermissionsToSeats`), read through `Leverage::Permissions`.
- Trace 25 has a seat add a task that waits on the model gate and reaches
  Ready, then one that fails the app gate and opens
  `agent_task_incomplete`.

## What the Imaginarium gallery added

The prompt gallery of the PRD's Imaginarium section (FR-030, FR-038,
FR-039, FR-041). Its decisions are DB-53, DB-55 and DB-56 and the two
entries under [Imaginarium gallery](decisions.md#imaginarium-gallery).

- The registry gains the list `imaginarium_entries`, the ids of the
  catalog's prompts. Add task refuses a source whose entry id is not in
  it.
- `openapi.json`: `AddTaskRequest` gains the optional `imaginarium`, an
  `ImaginariumSource` with the catalog `entry_id` and `catalog_version`,
  and `TaskSummary` gains `imaginarium_entry_id` and
  `imaginarium_catalog_version`. A task with a source goes to the
  workspace's Imaginarium project. An idea with a source carries its
  criteria, two to four build checks and a final review; any other Add
  task with criteria is `invalid`.
- `tasks` gains `imaginarium_entry_id` and `imaginarium_catalog_version`
  (migration `AddImaginariumSourceToTasks`), set together or not at all.
- `task.created` version 2 is the shape of every task's creation (DB-56):
  `imaginarium_entry` is the entry id or `null`, and
  `added_criterion_ids` lists an idea's criteria or is empty. Version 1,
  with neither field, stays for the logs that hold it. The replay
  rebuilds `tasks.imaginarium_entry_id` and the idea's criteria from it,
  and the step tracker reads the idea's criteria from it.
- `delete_content` is refused `invalid_state` for the workspace's
  Imaginarium project: the `content_deletability` guards name it (DB-55).

## What the account menu added

The sidebar account row of FR-001 shows the owner's sign-in email, which
the app does not keep after a relaunch. Its decision is the one entry
under [Account menu](decisions.md#account-menu).

- The registry and `openapi.json` gain the owner read
  `get_owner_identity` (`GET /v1/owner/session`, caller `owner`, command
  `read`, tag `owner`, security `ownerSession`). It returns
  `OwnerSessionIdentity`, the signed-in owner's `email_address` and the
  log position `as_of_seq`, with `Cache-Control: no-store`. It is final,
  like `get_workspace_settings`, not `x-provisional`.
- It adds no command, event, state table row or Needs you item.
