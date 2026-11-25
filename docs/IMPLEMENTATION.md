# Implementation progress

This file says where the build of Leverage stands, so that any agent or
person can pick it up after an interruption.

## How to use this file

- **Read it first.** Before any work, read this file, then
  [AGENTS.md](../AGENTS.md).
- **Update it in the same pull request as the work.** A pull request that
  starts, finishes or changes the plan for a milestone edits the tables
  below. A milestone is `Merged` when its pull request is on `main` and
  every item and test the PRD's "Build order and tracks" assigns to it
  exists and passes in CI; the pull request description lists each with
  where it is.
- **Push each branch and open a draft pull request at once**, then record
  both under [In flight](#in-flight). Where this file and GitHub disagree,
  GitHub is right, and the next agent corrects this file first.
- **Keep it true.** It records what is done and what is in flight. What is
  built is defined in [PRD.md](PRD.md), how in
  [ARCHITECTURE.md](ARCHITECTURE.md), and how it is run in
  [DEPLOY.md](DEPLOY.md). Do not restate them here.
- **Questions for the owner go at the bottom**, each with what was chosen in
  the meantime and why. Remove a question when the owner answers it and the
  answer is recorded where it belongs.

## How the build is run

The owner delegated this build to one managing agent on 2026-11-19, under
the delegated-run rule in [CONTRIBUTING.md](../CONTRIBUTING.md). The managing
agent is Claude Code (Claude Fable 5.2); the run started on 2026-11-19 and
ends when the build is done or the owner stops it.

- The managing agent plans each milestone, gives the work to other agents,
  reviews what they return, merges, and keeps this file current. Agents it
  gives work to open pull requests but do not merge them.
- One pull request per milestone. Each leaves `main` working.
- Every pull request gets an adversarial review by a separate agent before it
  is merged, and its findings are fixed or answered in the pull request.
- Work follows the practices in
  [ARCHITECTURE.md](ARCHITECTURE.md#engineering-practices), test-driven
  development first.
- When something cannot be settled without the owner, the agent decides,
  records it under [Questions for the owner](#questions-for-the-owner), and
  continues.
- Anything that cannot be undone outside this repository waits. This term
  is the managing agent's choice, not the owner's; see question 3.
- Software is installed from official sources only, pinned, and listed under
  [Installed for the build](#installed-for-the-build).
- No agent signs in to a provider or types a credential. Tests against real
  providers use only tools that are already signed in on the owner's Mac.

## Current state

| | |
| --- | --- |
| **As of** | 2026-11-24 |
| **On `main`** | The rules, the PRD with the gate settled, the design reference, the provider-terms record, the skeleton, the contract (milestone 1), the Core loop (milestone 2), Handoff (milestone 3), Rule checks (milestone 4), Questions and approvals (milestone 5), Credentials (milestone 6), the General role and landing prompt ([#20](https://github.com/yuric/leverage/pull/20)), the General mode eval runs and expanded specific-details budget ([#21](https://github.com/yuric/leverage/pull/21)), and the [Imaginarium prompt gallery proposal](imaginarium/PRD.md) ([#22](https://github.com/yuric/leverage/pull/22)) |
| **Next** | Review App round 1 and read the choices in question 16. |

### In flight

| Work | Branch | Pull request | State |
| --- | --- | --- | --- |
| App round 1 | `feat/app-round-1` | | Integrated locally with both rounds of review addressed. The second round covers a builder's submitted work reference and the draft parser's marker and criteria tests. See [the contract decisions](../api/contract/decisions.md#app-round-1-ui) and question 16. |

### General role and landing prompt on `main`

The other four roles keep their existing work behavior. The new restart
on a role change applies only to running seats the app manages when
changing to or from General. The new Gemini review pass-over applies
only to General seats.

The review fixes make orchestrator recovery test each eligible retry,
surface an independent reviewer or account wait per task, and give General
builds, reviews and jobs their instructions in the corresponding material.
The General eval runs covered app-managed default models. New prompt
confirms the replacement before displaying paste instructions.

The second review fixes apply the build claim standing test to Ready
account waits on the board and task page. Both reads preserve the
builder's login wait when a General seat that reviewed the task cannot
claim it. The PRD's first-build briefing description specifies the work
instructions a General seat receives.

## Milestones

The milestones and their content are defined in the PRD under "Build order
and tracks". This table tracks them; it does not define them. Its rows follow
the PRD's milestone list. How the build is run locally is in
[DEPLOY.md](DEPLOY.md).

| # | Milestone | Status | Pull request | Notes |
| --- | --- | --- | --- | --- |
| 0 | Skeleton | Merged | #10 | Not a PRD milestone; it gives the others a place to land. Adds the first product source file, so it activates AR-006 and AR-007: it names the mechanisms and adds the AR-007 check. It lists a second component, so it activates AR-005 too. Its versions and test tools are in [ADR 0002](adr/0002-pinned-versions-test-tools-and-code-units.md) |
| 1 | Contract | Merged | #12 | Adds `api/contract/`, the migrations and the gating interface, and the eleven PRD changes P-1 to P-11. The format is [ADR 0003](adr/0003-contract-format.md); the choices made for the owner are question 7 |
| 2 | Core loop | Merged | [#13](https://github.com/yuric/leverage/pull/13) | With account setup and the part that starts agents. The first milestone usable without a terminal. Built on `feat/core-loop`; the PRD changes Q-1 to Q-15 and ADRs 0004 to 0007; the choices made for the owner are question 10 |
| 3 | Handoff | Merged | [#14](https://github.com/yuric/leverage/pull/14) | With the owner commands Q-2 moved in and the daily backup (Q-14). Built on `feat/handoff`; the PRD changes R-1 to R-10 and ADRs 0008 to 0010; the choices made for the owner are question 11. Every interruption is shown with stand-in tools only. Not called done until the owner has set the recovery time ceiling (PRD, Build order and tracks) |
| 4 | Rule checks | Merged | [#15](https://github.com/yuric/leverage/pull/15) | With the planner and Draft contract, "No reviewer is eligible", the health line's orchestrator half and a job's limit and sign-out reports, which earlier milestones left to it. Built on `feat/rule-checks`; the PRD changes S-1 to S-14 and ADRs 0011 to 0013; the choices made for the owner are question 12. The eval suite was met by all three supported models. Model checks on real tools ran only in the eval and the real checks; no real builder, reviewer or planner has run through it |
| 5 | Questions and approvals | Merged | [#16](https://github.com/yuric/leverage/pull/16) | Both shipped eval bars were met by all three supported tools. The scripted and Claude Code MCP checks reached Done on the integrated baseline. The owner's MCP run is ahead. See question 13 and [Measurements](#measurements). |
| 6 | Credentials | Merged | [#17](https://github.com/yuric/leverage/pull/17) | Token Add, usage readings, row actions and reordering. Real provider and Keychain acceptance await the owner. See [reader evidence](#credentials-readers-and-recordings), [measurements](#credentials-runs) and question 14. |
| 7 | Analytics page | Not in this build | | See question 1 |

Status is one of `Not started`, `In progress`, `In review`, `Merged`,
`Not in this build`.

## Decisions made during the build

Hard-to-reverse choices are recorded as ADRs in [adr/](adr/). Smaller choices
an agent made without the owner are listed here until the owner has seen
them.

- **Approval eval budget (2026-11-24).** The owner added three main runs
  per model across Orchestrator and General mode so Codex and Antigravity
  can repeat both. [ADR 0013](adr/0013-eval-suites-for-rules-a-model-judges.md#2026-11-24-budget-update)
- **`API_PORT`.** `compose.yaml` publishes the API on `127.0.0.1` at the
  port in `API_PORT`, 3000 by default, because port 3000 on the owner's Mac
  was already taken by another program during the skeleton's checks.
- **TLS switches.** `RAILS_ASSUME_SSL` and `RAILS_FORCE_SSL` default to on
  in production mode, and `.env.example` turns both off, because the API is
  served over plain HTTP on `127.0.0.1` during the first run.
- **The API's tests run in the production image.** compose has one `api`
  service built from Rails' default production Dockerfile, and
  `bin/rails test` switches to the test environment and its own database.
- **Brakeman, `bundler-audit` and the local CI runner left out.** All
  three are `rails new` defaults. `bin/ci` and `config/ci.rb` were never
  run. The two gems were removed because of their licenses; see question 6.
- **Images pinned by digest.** `api/Dockerfile` and `compose.yaml` name each
  image by tag and digest; ADR 0002 records the digests.

The contract milestone's choices where the PRD leaves a gap are recorded in
[api/contract/decisions.md](../api/contract/decisions.md) under the IDs the
contract files cite, and its conventions in
[api/contract/README.md](../api/contract/README.md). The readings of silent
or contradictory PRD text there are DB-19, DB-20, DB-23, DB-29, DB-30,
DB-37, SM-1 to SM-6, SM-9 to SM-19, SM-23 to SM-29, SM-32 to SM-35, SM-37 to
SM-39, SM-42, RC-8 to RC-11, RC-15, RC-16, RC-18, RC-19, RC-23, RC-24,
RC-26, RC-27, RC-31, RC-32, RC-37, RC-41, RC-43, RC-44, RC-47 to RC-50,
IF-7, IF-10, IF-13, IF-18, IF-20, IF-22, IF-29, IF-31 to IF-34, IF-36 and
TM-1. SM-36 and part of SM-37 wait for two of the PRD's own open decisions.
The items marked for the owner are question 7. Where the contract differs
from that record, or settles what it left open:

- **Durations are integer seconds.** Settings and rule timeouts are
  integer columns with a `_seconds` suffix
  (`workspaces.lease_length_seconds`,
  `rule_versions.queue_timeout_seconds`), not `interval` as DB-28 and TM-1
  say, so that every file and the interface use one spelling.
- **Two columns differ from the PRD's word.** `task_steps.step_class` and
  `briefing_acknowledgements.briefing_hash`, because Active Record reserves
  `class` and `hash`. Traces use the column names.
- **The model is an open string in four payloads.** `task.claimed`,
  `review.started`, `job.claimed` and `credential.switched` carry `model`
  as a pattern-checked string, because the PRD's Credentials records "the
  model actually used" and model names are not a closed list. The plan
  expected no open string in a payload.
- **An operation names a list of commands.** The verdict call runs
  `pass_review` or `fail_review`, and the job result call one of four
  commands, so each registry operation has `commands`, not one `command`.
- **Shipped rules' instructions** are to be written in the Rule checks
  milestone for `specific_details` and in Questions and approvals for
  `orchestrator_approves_actions`, following the PRD's split of the eval
  suites, not both in milestone 4.
- **A verdict writes `cost.reported`, and may write `project.paused`,
  beside its row.** The PRD's Agent interface and Cost text say so, while
  the paragraph under the lifecycle table and the release criterion do not
  list them. `state_machine.json` declares both as the only exceptions.
  The alternative is to add them to that paragraph in the PRD.
- **"Any" in a From cell** of the lifecycle table means every state except
  Done and Cancelled, for Hold and Cancel.
- **Keys of a completed pending transition.** Its events carry the original
  requester's key even inside another caller's command, as the PRD's
  `command_id` row says, so one command can write two keys.
  `action.lease_granted` carries the key of the command that frees the
  builder.
- **A waive can grant the builder's lease.** `action.waived` carries
  `lease_seat_id` (SM-11), like every event that grants a fresh lease.
- **Return for rework names the criteria** to reopen in a
  `criterion_ids` body, as the PRD's Outward actions text needs.
- **A check step moves to the next action** at an approval: it closes and
  a new one opens on the action still waiting, because a step's subject is
  fixed when it opens.
- **Each check attempt is a job of its own** (DB-31), and jobs are claimed
  oldest first; the PRD gives no order for jobs.
- **Changes from the contract's adversarial review.** An overturned
  approval stops a started action too (L144). An override of the check
  that stopped an action runs approve_action's rows, and Mark action done
  with approved actions left splits as Waive does, so the builder gets its
  fresh lease when nothing waits for a decision (L139). A withdrawn
  pending transition closes its `check_error` hold (L162). A limit or
  sign-out report for a job's run is its own unbound command
  (`report_job_limit`, `report_job_signed_out`). Review claims are blocked
  by a hold. A seat change releases its task only when it disables the
  seat. A task added to or moved into a paused project gets
  `project_paused`. At `action.requested` the approval policy waits for
  the action's gates (`Gating.reenter_action`). Check events carry their
  subject and input hash. One-time tokens come in the completed envelope,
  and a repeat of the key answers a `*Repeated` result without the token.
  Claim results name their credential and model. The reviewer index counts
  only reviews with no verdict; the token constraints refuse any
  `*_token` key; the state trigger reads `events.xact_id`; composite keys
  tie a check's version and a rule's current version to their rule.
- **The tables check reads two cells with care.** A To cell "Done, once
  every action is done or waived" also names the state the task starts
  from, since it stays there until the condition holds; and the app's part
  in "Hold and resume" is written by other rows, which the group says with
  `who_in_other_rows`.
- **The helper's check names and failure codes** are enums inside
  `openapi.json`, not registry lists, because nothing else uses them.
- **Commit trailers.** The agents of this milestone signed their commits
  `Co-Authored-By: Claude Opus 5.5`, the model they ran on.
- **The branch merged `main`** after the skeleton landed, so that the
  milestone's checks run against the merged skeleton.

### The Core loop milestone

The Core loop's choices where the PRD leaves a gap were made in the
milestone's plan under the IDs below, which the code, the tests and the
contract cite ("milestone 2 plan EN-24"). Each line is the choice as built.
The plan's `[owner-later]` choices are in question 10, not here.

- **Scope.** SC-1: the commands the PRD's Core loop paragraph lists, the
  agent calls they need (SC-7: claim, briefing, pass, submit and review
  need next, command outcome, heartbeat, start criterion and release), the
  first-sign-in operations, and Cancel, Allow one more round and Remove
  seat. SC-3: Complete contract with an outward action is `422 invalid`,
  so no Finishing row can be reached. SC-4: Add task into the Imaginarium
  is `422 invalid`; the app adds to Backlog. SC-11 (also question 10): the
  "No reviewer is eligible" item is not opened.
- **The transition function.** EN-2: a later milestone's command has no
  entry and no route. EN-5: `Gating::NoRules` allows everything and plans
  nothing. EN-6: the briefing is the brief (empty), the role file and the
  contract, hashed with SHA-256 over canonical JSON. EN-7: `task.claimed`
  and `review.started` carry the seat's credential id and model, and so do
  the claim results. EN-8: a seat the app runs claims only while its own
  credential is active and not limited. EN-9: a passed review passes the
  review criterion; a failed one reopens each failed builder criterion.
  EN-10: during rework criterion events open no step. EN-11: a step may
  last zero time. EN-12: a verdict writes `cost.reported` and adds to
  `tasks.spent`. EN-13: `rounds_exceeded` opens when a failure brings the
  round to the limit, after the normal move, and pauses the fresh lease.
  EN-14: due timers are applied before a command on its task and on what
  the calling seat holds; reads treat a past lease as ended. EN-15:
  `lease_expired` goes to the seat whose lease ended by expiry, else
  `not_holder`. EN-16, EN-17: the pipeline (lock, key, timers, refusals,
  gate, entry, store, one commit). EN-18: tests make a lease due with
  `Scenario#make_due`; no clock stub. EN-20: heartbeats and last-polled
  writes take the workspace lock, at most every 10 seconds per seat (15 for
  the helper, 5 minutes for a session). EN-21: 64 Puma threads, a pool of
  32. EN-22: the sweep every 15 seconds, purging once an hour. EN-23: claim
  order by priority, then age, then id. EN-24: the server and the sweep log
  in as `leverage_api`. EN-25: test 2 is seeded random walks (200 by
  default). EN-26: tests that need commits use `CommittingTestCase`. EN-27:
  the review step opens at `review.started`. EN-28: `review.failed`
  carries the failed round. EN-30: Cancel follows its rows and ends both
  leases. EN-31: Allow one more round adds one to `extra_rounds` and closes
  the hold.
- **Interfaces.** IN-1: no path is typed outside the registry. IN-4:
  `bcrypt`, passwords of at least 8 characters. IN-5: a session lasts until
  sign-out. IN-8: a key is 1 to 128 of `[A-Za-z0-9_-]`; the request hash is
  over the method, path and raw body. IN-9: setup, sign-in and sign-out
  carry a key and store a `commands` row. IN-10: heartbeats carry a key.
  IN-11: a token is returned once; a repeat answers the `*Repeated` form.
  IN-13: the order of answers (401, 400 or 422, 404, refusals,
  `not_eligible` last). IN-17: what ends each token. IN-18: tokens are a
  kind prefix and 32 random bytes, stored as SHA-256. IN-20: Add task
  sends title, goal, priority, work reference and Backlog, and Complete
  contract every required field. IN-22: `helper_requests.params` carries
  only non-secret inputs. IN-23: account commands complete at once with a
  `helper_request_id`, and the helper reports progress per check. IN-25:
  Verify writes `credential.verified` or `credential.signed_out`. IN-26:
  the wait for the owner's sign-in is inside the add request. IN-29:
  Connect takes name and role, and a login for a seat the app runs. IN-33:
  `get_system_health`'s fields. IN-34: one log line per command. IN-35:
  the task read carries its events and names. IN-40: Remove seat ends the
  token at once, stops a run, and releases a Working task (with no builder
  left on it) and a review the seat holds.
- **Clients and helper.** CL-2: one table drives the four tools; Claude's
  driver is the reference. CL-3, CL-4: with no rules, builder and reviewer
  may share a provider or a login. CL-5: the runner is its own executable.
  CL-9: the account folder reaches the runner as `LEVERAGE_SETTINGS_DIR`.
  CL-10: every child gets an allow-listed environment; a tool gets no
  Leverage token. CL-11: a verdict reports the tool's tokens and spend 0.
  CL-15: Add ends with the login listed. CL-18: no Remove credential; a
  failed add deletes its folder and row. CL-20: a second Gemini login is
  refused. CL-22: a failed tool run is a release; three in a row end the
  runner. CL-23: a stop ends the tool's process group and gives back what
  the seat holds. CL-26: the end-to-end reviewer fails round 0 and passes
  round 1. CL-29: Mac-side logging. CL-31: `on_hold` pauses a flow.
- **Providers.** PV-1: evidence levels (`probe`, `help`, `documented`,
  `unverified`). PV-2: the runner's command lines, in
  [ARCHITECTURE.md](ARCHITECTURE.md#providers-tools). PV-3: where the
  helper looks for a tool. PV-7: the stand-in tools.
- **Mac app.** MA-6: any `401` returns to sign-in. MA-8: the Credentials
  tab is a flat list with Verify. MA-9: a card opens the task page with
  Back to the board. MA-10: Connect offers Builder and Reviewer. MA-12: one
  Connect sheet with the token shown once, and the landing prompt. MA-13:
  the form always sends both commands. MA-15: the form's footnote. MA-16: a
  Backlog task's page offers Send to agents. MA-17: the pop-up's check
  list. MA-19: one sentence per refusal and transport error. MA-20: reads
  carry `as_of_seq` and the app follows the events tail. MA-22: a minimum
  window width of 860 points. MA-23: the health line's four sentences.
  MA-26: a provider with one sign-in for the Mac shows as Added. MA-27: the
  name is required. MA-28: plain words in the log. MA-29: a task past the
  round limit offers two buttons. MA-30: Remove behind a confirmation.
- **Packaging.** PK-2: the app writes the server folder once and starts
  the containers. PK-5: plain HTTP on loopback. PK-6: the first sign-in is
  in the app. PK-7: a seat's token lives only in its runner's environment.
- **Tests.** TS-8: golden traces 09 and 10 run whole; 01 to 08 are listed
  as not yet runnable, each with its milestone. TS-9: one end-to-end
  script. TS-10: test 6 is a claim race and a reader tailing by `seq`.

Where the build differs from the plan, or settles what it left open:

- **A lease expiry clears the builder.** When a builder's lease ends and
  the task returns to Ready, the task's builder is cleared, as the PRD's
  replay list says; the plan had kept it.
- **No project on a task.** Add task refuses a project, so milestone 1's
  traces 01 to 08 run no command yet in this milestone.
- **The review criterion is the form's.** Complete contract requires the
  criteria to end with exactly one review criterion, so the Add task form
  appends "An independent reviewer agrees."; the plan had the server add
  it.
- **"Allow one more try".** The button is not called "Allow one more
  round", because "round" is one of the words the app may not show.
- **The sweep runs every 15 seconds**, as the plan says; `timers.json`'s
  trigger text says "at most every 30 seconds", which this meets.
- **`helper_requests.progress`**, a third new column, holds per-check
  progress between reports.
- **`task.contract_changed` v1 changed after the contract merged.** It
  now carries `minimum_strength_rank` (contract DB-48), so the replay
  rebuilds the rank; the contract's README had allowed a change in place
  only until the type's pull request merged.
- **The Swift copy of the contract** also holds the operations and the
  interface schema's own enums, and `HoldReason.isInBlocked`.
- **Each package committed its own work** by explicit path, the red tests
  first; the plan had the managing agent commit.

### The Handoff milestone

The Handoff milestone's choices where the PRD leaves a gap were made in the
milestone's plan under the IDs below, which the code, the tests and the
contract cite ("milestone 3 plan HD-4"). Each line is the choice as built.
The plan's `[owner-later]` choices are in question 11, not here.

- **Scope.** HS-1: what the PRD's Handoff paragraph lists, the seven owner
  commands Q-2 moved in, the backup of Q-14, eleven operations newly
  served, and one workspace timer, `seat_run_placement`; no usage reader,
  no `report_reading`, nothing of a job. HS-3: no row from Finishing is
  served: the two reports, Hold and Resume answer `invalid_state` for a
  task in Finishing, and the state-table tests prove it from a row
  `Scenario` inserts. HS-4: of milestone 2 only SC-4, EN-8, CL-22 for a
  run with a credential, IN-30 for a run ended by its account and MA-29's
  choices are taken back.
- **The engine.** HE-3: `credentials.limited_since` says a limit was
  reported and `limited_until` when it ends; limited means `limited_since`
  set and `limited_until` empty or later than now; a reset that passes
  writes nothing. HE-8: a report answers `completed` with no result.
  HE-10: open credential holds are looked at again when a login is
  verified or added, when an agent changes login, and by the timer. HE-12:
  a `credential_signed_out` hold and its item name the first signed-out
  candidate in the seat's order. HE-13: with no reset time anywhere, the
  `credential_limit` hold names the credential that stopped. HE-14: a
  builder the app runs counts as free for a fresh lease only if one of its
  candidates is available. HE-16: a Ready task no agent can start for want
  of an account opens no item; its card and its page say which account.
  HE-17: a recovery time starts at `credential.limit_reached`, or at a
  `credential.signed_out` with a seat, and ends at the
  `credential.switched` of the same command (0 seconds) or else at the
  continuing seat's first event of that work; one that never ends is open,
  or not recovered when the task is done or cancelled first. HE-18:
  `leverage:recovery_times` prints them against `CEILING_SECONDS`, else
  the workspace's ceiling, else nothing. HE-21: while a credential hold is
  open no run exists. HE-22: a limit report changes only the work it
  names, and keeps the later of two reset times. HE-23: a credential
  hold's due time is the task's last effective time when a candidate is
  available, else the earliest reset among its signed-in candidates.
  HE-24: Add task into the Imaginarium is served again; Hold and Resume
  from every state but Finishing. HE-25: an edited contract keeps a
  criterion by position and kind, resets one whose text changed, and from
  Ready, Working or In review ends the leases and returns the task to
  Backlog; an owner hold stays open. HE-27: Change an agent applies at
  once to the next run; turning it off releases a Working task with
  `seat_disabled`; turning it on starts nothing. HE-28: where the mockup
  and the PRD differ the PRD is built. HE-29: `inbox.resolved.choice` is
  set only when the closing command is one of the item's choices. HE-32: a
  limit is reported only with a named window; a reset time not after the
  observed time is stored as none. HE-33: a report naming a job is `404`.
  HE-35: a `wait_ready` step's cause is `credential_limit` when builders
  would be eligible but for their accounts. HE-36: Sign in again is for an
  added login only and queues one `open_sign_in` request. HE-37, HE-40:
  `list_inbox` returns every open item; one settled between two looks is
  announced from its event. HE-38: the providers that built a task can be
  read back from `task.claimed`, `review.started` and
  `credential.switched` (`provider_record_test.rb`). HE-39: positions are
  compared, never counted.
- **Runs and detection.** HD-1 to HD-3, HD-6, HD-9, HD-10 are
  [ADR 0008](adr/0008-how-a-run-moves-to-another-account.md); HD-7, HD-8 and
  HE-32 are [ADR 0009](adr/0009-detectors-from-recorded-and-made-replies.md).
  HD-11: the stand-in tools gain directives that answer the n-th work
  prompt with a named reply file, with its reset time set to now plus some
  seconds, or sign an account out before it; they count prompts and read
  no clock.
- **Mac app.** HM-17: Verify and the add checks keep milestone 2's rules.
  HM-19: a run with no credential detects nothing. HM-21: Needs you shows
  one row per item kind whose choices all have a route ("Account signed
  out", "Limit with no reset time", "Past the round limit"); another kind is
  one plain line. HM-24: the three items' words. HM-27: the real notifier
  only for a `.app` bundle with `LEVERAGE_NOTIFICATIONS` not `off`. HM-28:
  permission is asked once after sign-in, and a line says when
  notifications are off. HM-30, HM-31: a notification carries the item's
  heading and sentence, never an email, shows while the app is in front,
  and a click opens Needs you. HM-33: the eight sentences are kept as the
  PRD writes them. HM-34 to HM-37: the Handoff tab numbers the order, gives
  each row's state and whom it hands off to, and offers no reordering.
  HM-40: a Ready task whose `wait_ready` names `credential_limit` names
  the account that resets first. HM-42: a reset time is the short time
  today, the weekday and time within a week, else the date. HM-43: each
  interruption, handoff, wait and continuation is one sentence in the
  task's log, with "back at work" when it ended. HM-45: Ideas, Move to
  Backlog, Pause this task, Continue this task, Paused, Off, Not running,
  "Waiting for" an account. HM-46: "Allow one more try" is not renamed.
  HM-47: Credentials gains a login's limit sentence and Sign in again,
  nothing else. HM-48: Save as an idea. HM-49: Change the task opens the
  form filled in, with Save and "Save and send to agents". HM-51: Change
  agent offers name, model, effort, login and on or off. HM-53: the
  end-to-end runs use near reset times; a lease ending first is proven in
  the server's tests.
- **Backup.** HB-1 and HB-3 to HB-6 are
  [ADR 0010](adr/0010-daily-backup-and-restore.md). HB-7: after a restore
  the owner verifies each account. HB-8: a dump holds personal data and no
  provider secret; folder 0700, files 0600.
- **Tests.** HT-1: five golden traces, 11 to 15, for a workspace with no
  rules, reviewed line by line by an agent that did not write them. HT-2:
  test 3 per group, and over the whole table of 48 commands. HT-3: test
  2's walks gain the twelve new commands and a credential whose reset the
  walk moves. HT-4: tests 9 and 10 are `DetectorFixtureTests` and the
  end-to-end run. HT-5: `scripts/e2e_handoff.sh`, one compose project per
  test. HT-6: the new entries and routes stayed out of milestone 2's walks
  until they were built; nothing of that remains.

Where the build differs from the plan, or settles what it left open:

- **`seats.run_credential_id`**, not the plan's `running_on_credential_id`,
  because a read's field is its column's name.
- **A fourth answer from `SignInStatus`, "could not tell".** A status
  command that does not start, runs past its 30 seconds, fails without its
  signed-out reply or prints something that is neither reply no longer
  answers "signed out": the runner then treats the run as milestone 2's
  failure and sends no sign-out report, and the helper's checks still read
  it as not signed in. The plan allowed three answers.
- **Needs you's Change the task opens the contract editor** on the task
  page, not the page alone.
- **The inbox watcher reads every open item and filters by its cursor**,
  rather than reading after the cursor, so the count and the announcements
  come from one answer.
- **Two labels for one command.** The Needs you item's button is "Let it
  try once more" (HM-24), the task page's stays "Allow one more try". A
  notification sent from an event alone says "Sent back too many times",
  because "round" is a word the app may not show.
- **Complete contract keeps unchanged criteria** after an edit, by the same
  comparison Edit contract uses; milestone 2 removed and added them all.
- **Submit reuses the round's open review** after an edit from In review,
  which keeps the round; before, it failed on the round's unique review.
- **The step tracker reads a task's criteria as of each event** from the
  log, because an edit removes criteria and the replay must rebuild the
  same steps.
- **A sign-out may open "Account signed out" on another task's hold**
  (HE-11), and one command may apply a task's credential timer and then
  its lease timer; the log audit allows both. The random walks found each.
- **No typed result for `verify_credential` and `sign_in_again`.** Seven
  operations answer `helper_request_id` in an untyped result, milestone
  2's convention; typing two of them is a contract change no reader needs.
- **The task read names the account a task waits for.** `TaskPage`
  carries the board card's `waiting_for_credential_id` and
  `waiting_until`, computed by the same call (`Board.waiting`), so the
  task page says the card's sentence for a Ready task or a review waiting
  with no hold, as HE-15 asks of both.
- **`pg_dump` keeps owners in a custom-format archive** even with
  `--no-owner`; the restore's `--no-owner` drops them, and the archive
  holds no `GRANT` or `REVOKE`.
- **The restore test checks one workspace** of the dump, because the test
  database holds other tests' workspaces; `bin/restore` checks all.
- **Add credential keeps a strength rank the request sends**, and sets 1
  only when it sends none.
- **A Codex login signed out exits 1** in codex-cli 0.169.0, not 101 as an
  older run recorded; the stand-in plays the recorded reply.
- **The helper adds a run to its registry before watching it**, which
  fixes a milestone-2 race when a run ends at once.
- **`db:grants` runs one at a time across the cluster**, under an advisory
  lock taken in the `postgres` database. Milestone 2's lock was taken in
  each run's own database, so two runs on two databases (restores in
  parallel test workers, or the server's start beside a test run) both
  set `leverage_api`'s password and the second failed with "tuple
  concurrently updated"; two runs on one database collided on its grants.
- **The traces' setup** gives signed-out logins a verification time and
  seats no run credential; the trace runner and eligibility fill both in.
- **Each package committed its own work** by explicit path, the red tests
  first; one package worked in a worktree of its own.

What the adversarial review of the milestone found, and what changed (one
failing test first for each):

- **A second report on a held task is refused.** A limit or sign-out
  report on a task that already waits on a credential hold is
  `invalid_state`: no run is on it (HE-21), so the report is stale, and it
  used to open a second hold and a second item.
- **A signed-out login the task passes over is no reason to hold it.** A
  login rule 3 passes over for the task (its minimum strength rank) makes
  no hold `credential_signed_out`, gets no "Account signed out" item, and
  does not stop `wait_ready`'s `credential_limit` cause; a hold left with
  no item and no due time after Sign in again gets the item for what
  still blocks it.
- **A lease restarts from the hold's effective close**, the due time a
  timer closes it at, not the sweep's later time (PRD L118).
- **A reset time further off than its window can last is none**: more than
  6 hours after the report for the five-hour window, 8 days for the weekly
  and per-model windows, 32 days for spend or no window. Only a time after
  "resets", "reset at" or "try again at" on the same line of a reply is a
  reset time, never a log line's own timestamp, nor a time after a bare
  "reset" or a "try again" with no "at".
- **A sign-out is reported only on the tool's own word.** A status command
  that fails, crashes or prints neither its signed-in nor its signed-out
  reply is "could not tell". Codex's status is read by its recorded "Not
  logged in", not by its exit code. Grok's standard output, the agent's
  answer, is never read for a limit or a sign-out, and no detector reads a
  run that a signal killed.
- **No dump of a database with no workspace.** After the volume is lost
  the backup does not dump the new, empty database; it says so once and
  looks again every 30 seconds, so the first dump follows the owner's
  sign-up. The smoke run signs up a made-up owner for it, and the drill
  starts every service on an emptied cluster and checks that no dump was
  made.
- **A restore goes through a staging database**, renamed over the old one
  only after the replay test passes there; `bin/restore` also reads the
  dump's list first. A failed step of any kind, or a database that cannot
  be dropped, removes the staging database and leaves the old one as it
  was.
- **The backup service has no login-role password or URL**, and the
  scripts' backup folders are sticky (mode 1777).
- **The reply-file check reads every decoded string** of a file and of the
  JSON its outputs hold, and any field named for an email, plan,
  organisation, account or tier; Claude's recorded sign-out reply has its
  `service_tier` scrubbed.
- **The inbox cursor is checked against the log** when the app starts, and
  started again from 0 when it is of another log.
- **Smaller ones:** Sign in again for Gemini says to sign in to
  Antigravity, not to a window; editing a Ready task, or an In review task
  no reviewer holds, and its log line say nothing of an agent stopping; a
  signed-out account's card never shows a reset time; a released review's
  log line says it waits for a reviewer with an available account;
  `report_request_progress` takes Sign in again's checks; a seat change
  that changes nothing writes no event; DEPLOY.md gives a dump on demand.

A second review, of those fixes, found five more (all minor), each fixed
with a test that failed first or with its sentence made true: the
end-to-end wait test fails, rather than passing over the card's check,
when the hold closed before the board was read, and its reset is 30
seconds ahead so that the board is read while the hold is open; a restore
drops its staging database on a failed step of any kind and when the
database it would replace cannot be dropped; a reset time is read only
after "resets", "reset at" or "try again at"; and ADR 0010, the health
read's comment and the Grok row of the detection table say what the code
and the reply file say.

After that review, a crashed test run left a fake helper running, which
led to three fixes in the app's helper supervisor, each with a test that
failed first. A stop waits for every helper an earlier stop asked to stop,
so a quit that follows a Sign out does not leave first. A start while a
stop still waits for the helper waits for it too and then starts a new
one, so Sign out then Sign in at once leaves a helper running. The state
reads stopped from the moment a stop begins. The fake helper ends with
the test process that started it. A third review then found the
following, each fixed with a test that failed first:

- **A stop during a waiting start starts nothing.** No test covered it
  before; a start whose wait a stop overtakes returns stopped and issues
  no token.
- **A helper whose app was gone before it looked stops at once.** The
  helper watched the app only when its parent was not launchd, so an app
  that died between starting the helper and the helper's first lines left
  a helper running with its token. It now stops as when the app goes
  later, as a runner does when its helper was gone first.
- **The contract README lists the task page's two waiting fields** among
  the milestone's additions.

### The Rule checks milestone

The Rule checks milestone's choices where the PRD leaves a gap were made in
the milestone's plan under the IDs below, which the code, the tests and
the contract cite ("milestone 4 plan RD-45"). Each line is the choice as
built. The plan's `[owner-later]` choices (RS-2, RE-2, RD-2, RD-8, RD-12,
RD-24, RD-25, RD-29, RD-33, RD-45, RD-51, RD-61, RV-2 to RV-7, RM-1) are in
question 12, not here.

- **Scope.** RS-1: what the PRD's Rule checks paragraph lists, with what
  earlier milestones left to it: the planner and Draft contract, "No
  reviewer is eligible", the health line's orchestrator half and a job's
  limit and sign-out reports; no rule effect that needs a command of the
  Questions and approvals milestone. RS-3: of milestones 2 and 3 only
  EN-4, EN-5, SC-11, HE-15, HE-41, IN-33, MA-10, MA-13, MA-15 and, as far
  as the provider rule refuses a reviewer, CL-3 and CL-4 are taken back.
- **The engine and the gate**
  ([ADR 0011](adr/0011-gating-reads-and-the-transition-function-writes.md)).
  RE-1: `lib/leverage/rules/` reads, the gate and four writers write.
  RE-3: a transition settled later updates its requester's `commands` row,
  marks it for `GET /v1/next`, and writes its events under the requester's
  key with the settling check's event as cause. RE-4: while a task waits,
  its holder's, reviewer's or provisional claimant's other commands on it
  answer `pending`, unless allowed while pending; the owner is never
  blocked. RE-5: a provisional claim sets the holder with no lease. RE-6:
  a planner's result runs Complete contract as the planner, and may answer
  `pending`. RE-7: a refused command commits its check rows. RE-8: a job
  result writes `cost.reported` for the job, adding to a project's spent
  only. RE-9: no payload gains a field for a reason, an instruction or a
  request.
- **Rule records.** RD-1: all seven shipped rules are written. RD-3: the
  one-time write counts as turning the rules on (briefings change; "No
  reviewer is eligible" is evaluated). RD-4: a custom rule's moment is
  fixed when it is added. RD-5: Revert on a custom rule, Remove on a
  shipped one and any command on a removed rule are `invalid_state`.
  RD-6: Save checks every field. RD-7: a new default reaches a workspace
  only through Revert. RD-23: a custom rule's key is `custom_` and its id.
  RD-62: one Settings sentence per checker function, also the instruction
  of an app rule in a briefing.
- **Gates, claims and re-runs.** RD-9: test 4 covers the four gate hooks a
  task reaches, each with an app and a model gate, and the provider
  policy. RD-10: a Complete contract whose gate fails answers `completed`
  with the contract changed and the task held for details. RD-11: a
  waiting review's step names the provider rule once it refuses a
  reviewer. RD-13: a hold on a Ready task, or pausing its claimant, ends a
  provisional claim with `invalid_state`. RD-14: claim-next first offers a
  task the seat has an unused override on. RD-42, RD-43: Run it again is
  for errored checks only; at "before an agent starts it" it closes the
  hold and queues nothing. RD-44: one job row per attempt. RD-46: the
  owner's contract change starts the re-run count again. RD-47: "Let it
  through once" on "Every agent was turned away" lets the named agent
  through. RD-48: after letting a failed "ready to start" check through,
  the app sends Complete contract again. RD-49: a failed warn check shows
  in the checklist only. RD-50: the provider compared is that of the
  account the review would run on. RD-52: milestone 1's traces are not
  changed; `add_task` takes a project of the workspace.
- **When a check cannot run.** RD-15: the 120 seconds of L912 rest on the
  sweep's 15 seconds and the 10-second poll write; a busy runner polls
  every 30 seconds. RD-16: the offline item opens only while something
  waits, also with no orchestrator seat, and resolves only when the
  orchestrator is back. RD-17: the health read keeps its three values.
  RD-18: "N checks waiting" is counted at each read. RD-19: only errored
  checks are queued again. RD-20: no item for an offline planner.
- **Custom rules and screens.** RD-21: four moments are offered. RD-22:
  two scopes are offered. RD-26: a rule's row shows its runs, average
  time, tokens, reported spend and overrides. RD-27: a save that waits
  closes the sheet, the card says "Checking the details" and a failed
  check "Needs details". RD-28: the checklist and the Timing section.
  RM-2: the Rules screen reads again after a `rule.*` event, the task page
  after any event of its task. RM-3: Add task reads the rules once.
- **Jobs.** RD-30: everything a checker needs is in the claim's
  `material`. RD-31: the quote frame and the nonce. RD-32: tokens and spend
  as the tool reports them. RD-34: `run_due_at`, and the tool ended 10
  seconds before it. RD-35: one job at a time, oldest first. RD-36: job
  claim-next skips the jobs of tasks the seat built. RD-37: Draft contract
  is refused while a draft waits and outside Backlog; the stored work
  reference, strength and cap are kept whatever a draft says. RD-38,
  RD-39: a rule's reason reaches a builder only as quoted material. RD-40:
  a job's run that meets a limit hands off like a task's, and with no
  candidate the job runs into its timeout. RD-41: a late result is
  `invalid_state`. These are
  [ADR 0012](adr/0012-how-task-text-reaches-a-checker.md).
- **Speed.** RD-59: the check timeouts and the re-run limit keep their
  defaults. RD-60: app-run checks measured as the time inside the gate
  ([Measurements](#measurements)).
- **Eval suite.** RV-1: a suite is a folder
  ([ADR 0013](adr/0013-eval-suites-for-rules-a-model-judges.md)).
- **Tests.** RT-1: four golden traces, 16 to 19, reviewed line by line by
  an agent that did not write them. RT-2: tests of milestones 2 and 3 keep
  a workspace with no rules; the earlier end-to-end classes turn the
  shipped rules off. RT-3: test 2's walks gain the twenty new commands, a
  drawn rule set, an orchestrator and a planner. RT-4: test 4 is
  `gate_test.rb` and one line of the log audit on every log. RT-5: test 3
  per group and over the whole table of 68 commands. RT-6: the new
  entries and routes stayed out of earlier walks until built; nothing of
  that remains. RT-7: the timing queries are tested on the traces' logs.
  RT-8: the secret scan looks for task text in events and logs. RT-9:
  `scripts/e2e_rule_checks.sh`, one compose project per test.

The merged contract overruled the milestone's inventory in three places:
each check attempt is a job of its own, and a re-queue writes
`job.requeued` on the old job and no `job.queued` (trace 07, DB-31); a
limit or sign-out report for a job's run has its own rows
(`report_job_limit`, `report_job_signed_out`); and a hold does not stop a
job claim (question 7).

Where the build differs from the plan, or settles what it left open:

- **Trace 19 had two Gemini logins**, which the schema refuses (one per
  workspace); its Gemini reviewer now runs on the one login.
- **Trace 07's two digests are one.** Its two checks of one request
  carried two made-up digests, which one function of the inputs cannot
  give; both are now the real hash of the request.
- **`hold.opened` names the check** (contract DB-49): the hold of a check
  that errored, was held at the re-run limit or turned every agent away
  carries `rule_check_id`, changed in place under DB-48's convention.
- **The order inside a command has two exceptions**, which the contract's
  README states: a waiting command ended from outside writes its
  withdrawals before the row's own event, and Complete contract closes
  "Needs details" first.
- **A check's job is queued after its `check.queued`**, by `RuleChecks`,
  so the events come in the traces' order; the plan had `Jobs.queue`
  called beside the writer.
- **The cause of a settled transition** is the settling check's
  `check.finished`, as trace 07 has it, not the override that let it
  through.
- **Claim-next for reviews asks the engine itself** for the provider
  rule's row, beside the gate, so the plan's "the gate is the only caller"
  does not hold; test 4 and the audit cover both.
- **A pass whose gate fails reads `completed`**: the verdict took effect as
  a failed review.
- **One waiting command per task.** A second gated command on a task that
  waits answers `pending`, the owner's second Complete contract included.
- **A blocking failure takes effect at once**: model checks planned beside
  it are not written and no job is queued.
- **A job is claimed only on the seat's first available account**, as
  builders and reviewers claim (HD-4), and a job past its due time is
  never handed out.
- **A job's check run passes the seat's model and effort when set**; with
  none set its arguments are the answering check's. No tool run starts
  with less than 15 seconds before its end, and each tool run of a job
  gets a new folder of its own.
- **A waiting claim, submit or pass is asked for by its key every second**
  until it is decided; the plan had a long poll, which `get_command` does
  not take.
- **The reference runner gives its tool the briefing's rules**, quoted,
  in the builder's, reviewer's and rework prompts; without it a builder
  learnt a custom rule only when its submit was refused.
- **The server's request log keeps no text but ids**: every other string
  parameter is `[FILTERED]`, found by the end-to-end run's scan for task
  text.
- **The offline item names the workspace** as what it is about, as the
  interface schema requires; it was empty and the app could not read the
  Needs you list while it was open.
- **A verdict's spend adds to the task's project**, found by replaying the
  traces against the PRD's Cost text.
- **`LeverageRunner eval` finds its tool itself**, in the catalog's folders
  (only `LEVERAGE_TOOL_DIR` on the stand-ins), and prints it with
  `--resolve-only` before any case goes out. `runs.json` reserves 30 tool
  runs before a model's run and settles the count after it, so a crashed
  run still counts, and keeps the reason for each change between runs.
- **Two eval cases changed in review**: case 08's details now state the
  three facts its criterion checks, and a made-up shop name that turned out
  to be a real seller's was replaced. No label changed.
- **The generator's self-test** asks a doctored registry what an empty
  provider list gives, since the committed list now holds the eval's
  results.
- **Each package committed its own work** by explicit path, the red tests
  first; most worked in a worktree of their own and brought their commits
  onto the branch themselves.

The API suite failed now and then on the owner's Mac. Each cause was fixed
with a test that failed first:

- **At most eight test workers.** `bin/rails test` started one worker per
  processor (20 on the owner's Mac), and with the race tests' twenty
  threads passed PostgreSQL's 100 connections ("too many clients
  already"). Workers are now one per processor up to eight
  (`PARALLEL_WORKERS` still overrides), the three twenty-thread race tests
  run one at a time across the workers, and a test holds the worst case
  (68 connections with eight workers) under the server's limit.
- **A command's time never goes back.** The database clock steps back on
  Docker Desktop for Mac (0.59 ms was seen), and a command then took a
  time before the last event's and wrote a step that closed before it
  opened. The time a command takes under the workspace lock is now at
  least one microsecond after the workspace's last event (PRD L219, L825),
  and an event a workspace timer writes on a task takes effect no earlier
  than that task's latest event (L120, L220). DB-5 and the contract's
  README say so.
- **A rule turned off while its command waits no longer blocks**, even
  when its check had already failed: the engine lets the move through
  (L380, L976) and the log audit now agrees.
- **Replay holds a provisional claim for its blocking checks only**: a
  warn rule's check never keeps a claim waiting, so the claim ends when
  its last blocking check fails (DB-43 now says so).
- **"No reviewer is eligible" opens right after a review lease ends**,
  wherever the lease timer runs: as the sweep's command, or inside another
  command before its refusals or in a claim's search, also when that
  command is then refused. The lease timer writes the item next to its
  own event and at its time, before the task's later timers (SM-42,
  L120).
- **Claim-next does not time out the queued jobs it could claim.** It
  still applies the timers of the job its seat holds, as any seat's
  command does. It never hands out a job past its due time, the sweep
  records the miss within 15 seconds at the due time, and claim-next's
  state row writes no `job.timed_out`. No requirement or audit rule needs
  the miss sooner.

### The Questions and approvals milestone

- **Reviewer eligibility after a seat request.** Walk 132052406 exposed an
  inbox event attributed to an unchanged seat request. Change seat now
  triggers the re-evaluation when it writes `seat.changed`. The workspace
  timer covers account resets (contract decision SM-42).
- **Overturn after an action is done.** The former question 8 is settled by a
  durable `action.overturn_recorded` event, with the owner as actor and
  the action as subject. The task and action stay as recorded before.
  [ADR 0016](adr/0016-an-overturned-approval-that-changes-nothing-is-an-event.md)
- **Finishing and MCP.** The previous builder receives any approved work.
  The client starts the bundled MCP server for a seat that connects on
  its own. [ADR 0015](adr/0015-one-method-decides-what-a-finishing-task-does-next.md)
  and [ADR 0014](adr/0014-the-mcp-server-is-a-swift-program-over-standard-input-and-output.md)
  record the boundaries.
- **Verification limits.** The end-to-end builders that ask questions or
  report spend are self-connected seats. A real provider tool carried out
  no outward action. Lease expiry after approval was tested through HTTP.
  The stand-in end-to-end builder lost the lease by releasing the task.
  The MCP heartbeat window was tested with a manual clock. The
  orchestrator's question prompt and its answer and basis parser ran
  against stand-in tools.

### The Credentials milestone

- **CS-1, CS-3.** Serve the six existing operations. Keep the fixed lists
  and the earlier flows, with a first read added after a passed Add.
- **CS-4.** Reorder and Remove look again at credential holds in the
  command. Reviewer eligibility follows on the next sweep.
- **CR-1, CR-35.** Rename and Remove belong on the row. A rejected or
  missing token found by Verify is signed out. The row says to Remove
  and add again.
- **CR-4, CR-34.** The provisional Claude settings reader looks at
  one cache entry. A fresh empty entry yields zero. A grant yields a
  dash. The planned per-model tile takes the fullest model without
  naming it. Claude quota grammar remains unavailable.
- **CR-5.** The reader catalog has fixed labels and matched examples.
  Swift reads its generated version and label lists.
- **CR-6.** Bounded plan and email from Add and Verify live in the
  credential row. The saved helper result has nulls for these fields.
- **CR-8, RD-3.** The existing subprocess mechanism gains a session
  with open standard input. Codex uses JSON lines, checks the home in
  the initialize reply and sends four request methods.
- **CR-10, CR-11, CR-13.** The server schedules usage. Add completes
  before the first read. Refresh and the sweep find or queue a read
  per active credential. Verify all reuses unfinished Verify requests.
- **CR-12, RD-8.** Scrubbed developer recordings stay outside the
  repository. Made-up usage fixtures carry a typed expectation and
  have separate reader tests.
- **CR-14, CR-15, CR-16.** A fresh reading below 100 percent in every
  window refused since the limit began clears the limit and reassesses
  both credential hold reasons. A passed Verify can still clear an
  undated limit. Readings alone can neither set a limit nor sign out
  the credential.
- **CR-17, CR-18, RD-6.** The catalog owns figure labels and response
  headers. A provider's limits may be computed from the numbers it
  supplies. OpenRouter's Spending limit tile shows percent used.
  The remaining amount and each period's usage are dollar figures.
- **CR-19.** A missing reset count is a dash. An empty list reads zero.
- **CR-22, CR-23.** Readings remain until the credential is removed.
  Finished or failed requests expire after seven days. The Mac
  displays reading age from observation time and rereads the visible
  list every ten seconds.
- **CR-25, CR-26.** Token rows do not hand off work. A login's row
  points to the next login. Credentials uses a sign-in dot and
  presents the limit on its own line.
- **CR-28, CR-29, CR-30, CR-32.** Reorder takes the complete added set.
  A confirmed Add places a login above the first token and a token
  at the end. Remove refuses live references. Reorder and Remove
  reassess credential holds and the associated Needs you item.
- **CR-31.** The helper forgets removed credentials through standard
  input. A stop request for a removed seat remains eligible after forget.
  The app sends forget to the running helper even if recording the
  pending ID fails. [ADR 0017](adr/0017-api-tokens-the-keychain-and-the-local-channel.md)
  records how the helper acknowledges cleanup.
- **CR-33.** Codex counts its available rate-limit reset credits as
  full resets and groups credits with the same expiry.
- **CR-38.** The row describes the configured handoff model. Model,
  effort and strength rank have no edit command.
- **RD-1, RD-2, RD-4, RD-5.** Provider calls are separated from parsing.
  Unsupported shapes report unavailable. A malformed figure is
  omitted when the remaining figures can be read. Claude command
  flags have stand-in coverage. Grok's source is a command from help.
- **TK-1, TK-2.** The bundled helper uses the platform vault and a
  fixed HTTPS catalog. Development uses a memory vault. The test
  override is local to the unbundled helper.
- **TK-3, TK-4, TK-5.** A successful token check confirms Add. A
  token is never a candidate. Fixture and workflow scans distinguish
  synthetic provider authentication and the one account email column
  from all other scanned storage and logs.
- **CT-1, CT-2, CT-3.** All operations and commands are served.
  The state table, walks and trace 24 cover credential changes and
  the task step partition. The temporary pending tables are gone.
- **CT-4, CT-5, CT-6.** Dedicated usage fixture suites, three
  credential workflows and the recorded stand-in calls cover parsing,
  timeout isolation, safe reads, audit and replay.
- **Finishing integration.** Walk seed 290 showed that Offer task again
  could record a fresh lease while an action still blocked approval.
  The command and state table now use the existing approvals guard.
- **Final integration.** Walk seed 991672114 found an override that
  reentered an action and stopped it on another failed gate. The audit
  checks the app actor, earlier failed check and matching action for
  this case. Removed credential IDs remain reserved in the workspace,
  the API enforces one Grok login, and reorder resolves an item whose
  account is no longer a candidate. Refresh and the sweep can replace an
  abandoned usage pickup after 90 seconds.
- **Contract reconciliation.** An exact empty order is accepted for
  an empty added set. The response example pairs its credential with
  the matching reading. The API validates the row and filters
  UUID-shaped names and plans from logs. The case where a hold regains
  a dated candidate is described in the Handoff paragraphs and the
  Needs you contract. The earlier summary cells remain as written.
- **Adversarial review.** Limits retain their start through overlapping
  refusals. A reading that restores a candidate reassesses the wait in
  that command. The API bounds observation times, compares places
  among added credentials at reorder and leaves an unchanged rename
  event-free. Needs you offers automatic recovery when a reading
  identifies a tested tool version. The Codex reader completes after
  receiving the required replies and reaping the child.

### Credentials readers and recordings

Step 0 ran on the tools' existing sign-ins. The managing agent saved
only scrubbed copies outside the repository. The product path uses
the helper's own account selection. Its proof is from stand-ins.

| Provider | Source, evidence and fixtures | Tested tool versions | Product usage today |
| --- | --- | --- | --- |
| Claude | Claude Code usage probe returned a JSON envelope without a model turn. The scrub left no usable quota grammar. Cache tests use made-up settings. | None. Probe 2.1.325. | Unavailable. The experimental reader is unregistered. |
| Codex | `codex app-server` recorded as JSON lines. Usage fixtures follow the observed structure and generated schema. Account facts fixtures use the schema. | 0.169.0 | Available on that version with supported replies. |
| Gemini | Antigravity's terminal-free probe returned JSON without prompt tokens. The PRD names the interactive usage screen. | None. Probe 1.5.13. | Unavailable. |
| Grok | Tool help names `grok usage --json`. Step 0 ran no Grok command because the tool was signed out. | None. Preflight help and version 1.0.77. | Unavailable. |
| OpenRouter token | Catalog key GET. Vendor reference and made replies. | No tool | Used percentage, amount left and period spending. |
| Claude API token | Catalog models GET. Vendor reference and made replies. | No tool | Requests remaining when the named header is supplied. |
| OpenAI API token | Catalog models GET. Vendor reference and made replies. | No tool | Requests remaining when the named header is supplied. |
| Gemini API token | Catalog models GET. Vendor reference and made replies. | No tool | Reading state without figures. |
| Grok API token | Catalog API key GET. Vendor reference and made replies. | No tool | Reading state without figures. |

All entries remain provisional. The two model-list headers remain
unverified on the actual endpoints.
[Architecture](ARCHITECTURE.md#usage-readers)

### The General role and landing prompt

The interface decisions are recorded in the
[General role contract](../api/contract/decisions.md#general-role-ga).

- **GA-14.** The join call uses the interface's JSON envelope.
- **GA-15.** The MCP join instructions supply the client settings.
- **GA-16.** The prompt-connected agent stops on `401`. Pausing the seat
  leaves the agent polling for work.
- **GA-17.** The General role milestone originally added New prompt.
  App round 2 replaced it with the existing Remove and Connect flow.
- On 2026-11-24, the owner raised the shared `specific-details` eval ceilings
  to allow runs in General mode. See
  [ADR 0013](adr/0013-eval-suites-for-rules-a-model-judges.md#2026-11-24-budget-update).

### App round 2

The [App round 2 contract](../api/contract/decisions.md#app-round-2-ux)
records the changes. The owner approved these choices for the round.

- Turning off Deliver tasks gives back the Working task. With Work on
  tasks still on, the agent can take reviews and jobs its role allows.
- Both Native and Prompt seats show Create tasks, and the server
  enforces it. Task creation is available to Prompt agents in this
  round. The Native runner does not expose the call to provider tools.
- The owner's Add task form keeps its "What goes out at the end" field
  for outward actions that go through approval.

Native Codex and Grok have no effort drop-down in this round. UX-15
records the documentation checked for each tool in the contract.

## What the Rule checks milestone proves, and how far

- **The rules work end to end with stand-in tools.**
  `scripts/e2e_rule_checks.sh` runs seven tests, each in a compose project
  of its own with the real API, sweep, backup, helper and runner, the
  shipped rules on and an orchestrator among the agents, the stand-in
  tools answering every check: a task from the form to Done; a vague task
  sent back for details and then passed; a custom rule that blocks a
  submit until the builder's rework passes; a fourth try that waits until
  the owner lets it through; the orchestrator stopped, its item opened
  within 120 seconds by the server's clock, and the checks going on when
  it starts again; the provider rule keeping a reviewer on the builder's
  provider away until a reviewer on another provider is connected; and a
  drafted contract. After each the replay, the step partition and the
  audit with its gate line pass, and no event and no log holds the test's
  task text or a nonce-shaped marker. It passed three times in a row on
  the owner's Mac, and again on the milestone's last commit, as did
  milestones 2 and 3's runs with the shipped rules turned off.
- **Model checks on real tools ran only outside the product's normal
  path.** No draft, no builder and no reviewer has run on a real provider
  through this milestone. Real verdicts came from the eval suite's tool
  runs and from the real checks through the server: an orchestrator on
  Claude Code, Codex and Antigravity each checked two contracts, and only
  Antigravity's ran as a seat the helper started
  ([Measurements](#measurements)).
- **The eval suite's reach is narrow.** It ran each tool's default model
  at the version on the owner's Mac (Claude Code and Codex with the Mac
  user's own settings folders, so the model they ran is not known), and
  with the check prompt as it was before the review's fix to its frame
  (finding 10: markers in task text broken, and one sentence added), which
  was not run again on a real tool. It ran on 24 made-up cases labelled by an
  agent, one run each. All three models scored 24 of 24, so the suite does
  not tell them apart and says nothing about harder cases. It does not
  cover Grok, an instruction the owner edits, a model the owner chooses
  for an orchestrator, the model set on a credential a check is handed to,
  or another provider reached by handoff, and nothing stops any of them
  (RV-5, RD-40).
- **What a checker could reach if task text got past the frame**: nothing
  on Claude; any file the Mac user can read on Codex, whose sandbox stops
  only writing; unknown on Gemini and Grok (RD-33, the table in
  [ARCHITECTURE.md](ARCHITECTURE.md#trust-boundaries)). The eval's file
  case is one probe of it, not a proof.
- **With the reference runner** a review the provider rule keeps from a
  reviewer writes no `applied` row and its wait names no cause, because
  the runner asks `GET /v1/next` before it claims; "No reviewer is
  eligible" still opens. The row and the cause are proven for a client
  that calls claim-next, in trace 19 and over HTTP (RD-12).
- **With the provider rule off**, a review that waits only because every
  reviewer's accounts are unavailable still has no item (RD-51).
- **Four shipped rules exist and do nothing yet** (RD-8).
- **L913's "on the seat's next request"** for a failed check let through
  is proven in the server and in the runner's tests, not end to end; end
  to end, the owner's override completes the submit that waits at the
  re-run limit.
- **The 120 seconds of L912** rest on the sweep's 15 seconds and on an
  orchestrator that keeps polling while it works: the reference runner
  does, an agent that connects on its own is only told to by its role
  file (RD-15).
- **Test 4** covers the four gate hooks a task reaches and one policy; the
  rest are the Questions and approvals milestone's.
- **A first run with the shipped rules on needs three agents on two
  providers** (RS-2).
- **A job's limit or sign-out** is proven in the server, the runner and
  the helper's tests and in trace 19, not in an end-to-end run.
- **The API still has no security scanner** (question 6).

## What the Handoff milestone proves, and how far

- **Every interruption is played by stand-in tools.** No agent signed in,
  signed an account out or spent quota to reach a limit, and a limit
  cannot be caused on request. **No interruption has been shown on a real
  provider.** `scripts/e2e_handoff.sh` runs six tests, each in a compose
  project of its own with the real API, sweep, backup, helper and runner:
  a limit after work is saved, handed to another login of the same
  provider and of another provider; a limit that waits for its reset; a
  login found signed out, handed off and held until Sign in again; and one
  account at its limit while the next is signed out. Each reaches Done
  with the criterion passed before the interruption kept, one claim and
  the same builder; then the replay and the audit pass, each recovery time
  is within the working bar, and the secret scan finds nothing. It passed
  three times in a row on the owner's Mac, last after the second review's
  fixes.
- **The detection rules for a real limit are unproven** until a real limit
  reply is captured. No tool's limit reply is documented or observed, so
  every limit reply the detectors are written to is made, with an invented
  shape. On a real tool a real limit will most likely not match them: the
  run then fails as in milestone 2, with no handoff, and after three
  failures the agent stops. PRD test 9 and the release line on recorded
  limit replies are not met as written.
- **The recorded sign-outs are of a tool that never held a login**, for
  Claude and Codex. Nobody has seen the reply of a login that expired or
  was revoked during a run; the status question is the guard for it.
- **The recovery time is checked against a working bar, not the
  ceiling.** The owner has not set the ceiling, so 900 seconds was given to
  the check of the scripted runs and to nothing else
  ([Measurements](#measurements)).
- **The notification is proven up to its protocol.** The inbox watcher is
  tested with a fake notifier; no test touches macOS's notification
  center, and the smoke run turns notifications off.
- **On Linux,** the `e2e` job runs the handoff run and the restore drill;
  it has not run yet. One test passed in an aarch64 Linux container on the
  owner's Mac. That the image's user, uid 1000, can write the bind-mounted
  backup folder on a Linux host, and that the detectors build on x86_64, is
  for that job to show.
- **Until the Rule checks milestone** a reviewer's handoff may land on an
  account of a provider that built the task (HE-41), and a handoff that
  ends on a Codex or Gemini login records no model (HE-5).

Which reply each detector is written to, per tool. "Recorded" is a reply
captured on 2026-11-19 from the tool with no login (a new, empty settings
folder for Claude and Codex; this Mac, signed out, for Grok); "made" is
written by hand, "invented" where its shape is a guess and "from observed"
where it follows text seen elsewhere. The files are in
`mac/Tests/StandIns/replies/`.

| Tool (version) | Limit | Short rate limit | Sign-out, in a run | Sign-out, by status |
| --- | --- | --- | --- | --- |
| Claude (`claude` 2.1.325) | Made, invented: five-hour with a reset time, weekly without | Made, invented | Recorded | Recorded (`claude auth status`) |
| Codex (`codex-cli` 0.169.0) | Made, invented: five-hour in a structured field, weekly in words | Made, invented | Recorded | Recorded (`codex login status`) |
| Gemini (`agy` 1.5.12) | Made, invented: per-model | Made, invented | Made from observed (the shape of a signed-in reply) | None: no status command |
| Grok (`grok` 1.0.77) | Made, invented: spend, on standard error | Made, invented | Made from observed: the words from `grok models`, which printed them on standard output; the stream (standard error), the exit status and the second line are invented, so on the real tool a sign-out is expected to show only through `grok models` (standard output, the agent's answer, is never read) | Recorded (`grok models`) |

Unverified for all four: a real limit reply, and the reply of a login that
expired or was revoked during a run. The contract's `readers.json` keeps
every login reader's captures at `none`.

## What the Core loop proves, and how far

- **The whole loop runs with stand-in tools.** `scripts/e2e_core_loop.sh`
  runs the real API in its containers, the real helper and the real runner,
  with the stand-in tools of `mac/Tests/StandIns/` in place of the
  providers' tools: it creates the owner, adds a Claude and a Codex login
  through Add credential (each stand-in starts signed out and the flow goes
  on by itself), connects a builder and a reviewer, adds a task with two
  criteria, and waits for Done; a second test stops a reviewer mid-review
  and another reviewer finishes it. It then replays the log and scans the
  logs and a database dump for secrets. It passed three times in a row on
  the owner's Mac on 2026-11-19 with no retry, and again in the final run.
  On Linux in CI (the `e2e` job, run 44625056944) the helper, the runner
  and the end-to-end tests compiled and the containers came up healthy,
  but both tests stopped at once because they looked for their programs
  in an `.xctest` bundle, which SwiftPM does not make on Linux. The fix
  passed the whole end-to-end lane in an aarch64 Linux container on the
  owner's Mac, and then in CI on `main` after the merge (run 44649146670,
  all four jobs passed).
- **The Mac tests run one at a time on the macOS runner.** On GitHub's
  three-core macOS runner (run 44634551151) the whole package's tests at
  once took over two minutes and about a dozen failed: the app tests'
  waits ran out on a crowded main thread, and the stand-in tools took
  longer to start than the tests' ceilings. The same failures came back on
  the owner's Mac under CPU load. CI now runs `swift test --no-parallel`
  with `LEVERAGE_TEST_PATIENCE=4`, which lengthens only the waits for what
  must happen and the ceilings for a stand-in to answer; this passed five
  times in a row on the loaded Mac, and on the runner in run 44649146670
  on `main`.
- **The failed review is shown with stand-in tools only.** The task in the
  end-to-end run goes through one failed review because the stand-in
  reviewer is scripted to fail round 0. Nothing can make a real provider
  fail a review on request, so no run on a real tool has shown it.
- **No real provider has run through the product by an agent's hand.** No
  agent signed in, ran an installer or a sign-in command, or used a login
  through Add credential. Two developer checks exist for the tools already
  signed in on the Mac, never run in CI: `scripts/real_provider_run.sh`
  (plan PV-6, narrower than its text: one build prompt through the
  runner's tool driver, with the tool's own sign-in, and no containers,
  seats or task; it proves the driver's flags only) and
  `scripts/real_gemini_through_app.sh` (one Gemini login through Add
  credential, a task to Done). The managing agent ran each once on
  2026-11-19, on the tools already signed in on the owner's Mac (pull
  request 13): Claude (2.1.325), Codex (0.169.0) and Gemini (`agy` 1.5.12)
  passed the developer check, Grok (1.0.77) is installed and not signed in,
  so its flags are unproven, and the Gemini check through the app took a
  task to Done. Neither is the product's path, and neither marks a PRD line
  as met. The owner's
  first run is the first real one through the app (see
  [Waiting for the owner](#waiting-for-the-owner)).
- **The app bundle starts its server.** `scripts/smoke_app.sh` opens
  `dist/Leverage.app` with a Finder-like environment and gets a healthy
  answer from the server it started, in about 5 seconds once the images are
  on the Mac. Opening it from Finder itself has not been tried.

Which provider's tool can be installed from the pop-up (PRD line "a
missing tool installed from the pop-up") and which continues on its own
after the owner signs in ("a signed-out tool caught, the flow continues"):
neither line is marked met for a real tool. Installing from the pop-up is
shown with a stand-in installer for Claude only (`ToolInstallerTests`);
Codex's and Gemini's installers are in the catalog but not tested, and
Grok has none. Continuing on its own after the owner signs in is shown
with stand-in tools for all four: Claude, Codex and Grok through their
status commands and Gemini through the repeated test prompt
(`AddChecksTests`), and Claude and Codex again in the end-to-end run. The
evidence levels are those of
[ARCHITECTURE.md](ARCHITECTURE.md#providers-tools).

| Provider | Installed from the pop-up | Continues on its own after sign-in | Evidence |
| --- | --- | --- | --- |
| Claude (Claude Code) | Yes in code: the vendor's script `https://claude.ai/install.sh`, run with `/bin/bash` | By polling `claude auth status`; whether `claude auth login` opens the browser itself and needs no terminal is not known | Installer `documented`; status `probe`; sign-in `help` |
| Codex | Yes in code: the vendor's script `https://chatgpt.com/codex/install.sh`, run with `/bin/sh` | By polling `codex login status`; what `codex login` does is not known | Installer `documented`; status `probe`; sign-in `help` |
| Gemini (Antigravity) | Yes in code: the vendor's script `https://antigravity.google/cli/install.sh`, run with `/bin/bash` | By repeating the test prompt every 15 seconds; a signed-out `agy` has never been seen | Installer `documented`; test prompt `probe` (signed in only) |
| Grok (Grok Build) | No: no documented source was reachable; the pop-up says Leverage can't install it yet | By reading `grok models`; `grok login --oauth` is a browser login by its help | Status `probe` (signed out only); sign-in `help`; installer `unverified` |

## Measurements

The speed of writing events and steps, measured by `scripts/speed_run.sh`
on the owner's Mac (Mac15,14, Apple M3 Ultra) on 2026-11-19 at 22:31 UTC:
50 seats (25 builders and 25 reviewers that connect on their own) for 120
seconds, `RAILS_MAX_THREADS` 64 and a pool of 32 connections, 3775
commands sent by the seats, each seat ticking every 2 seconds with the
seats' ticks spread evenly over the 2 seconds. Milliseconds, nearest-rank
percentiles.

| Command | n | Lock wait p50 | p95 | p99 | Event and step writes p50 | p95 | p99 | Whole transition p50 | p95 | p99 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| acknowledge_briefing | 225 | 0.393 | 0.902 | 34.793 | 2.040 | 4.441 | 9.971 | 5.486 | 11.212 | 53.630 |
| acknowledge_review_briefing | 200 | 0.400 | 1.160 | 1.514 | 0.973 | 2.619 | 3.190 | 4.771 | 11.350 | 13.818 |
| claim | 225 | 0.322 | 0.985 | 1.373 | 1.701 | 4.364 | 5.135 | 6.424 | 15.634 | 18.136 |
| claim_review | 200 | 0.439 | 1.160 | 1.494 | 2.233 | 4.897 | 6.485 | 8.435 | 18.232 | 26.030 |
| heartbeat | 1275 | 0.534 | 1.419 | 2.713 | 0.000 | 0.000 | 0.000 | 3.782 | 7.265 | 10.916 |
| heartbeat_review | 400 | 0.481 | 1.224 | 27.660 | 0.000 | 0.000 | 0.000 | 3.521 | 7.442 | 35.632 |
| pass_criterion | 425 | 0.467 | 1.026 | 1.348 | 2.640 | 6.271 | 8.325 | 7.455 | 16.096 | 19.963 |
| pass_review | 200 | 0.382 | 0.966 | 33.332 | 2.503 | 5.331 | 12.369 | 7.404 | 19.294 | 50.452 |
| start_criterion | 425 | 0.411 | 0.793 | 1.478 | 1.875 | 3.684 | 5.904 | 5.654 | 10.018 | 18.634 |
| submit | 200 | 0.398 | 1.194 | 1.435 | 1.554 | 4.178 | 6.063 | 6.063 | 16.646 | 24.732 |
| All commands | 3775 | 0.459 | 1.207 | 2.713 | 1.349 | 3.788 | 6.616 | 5.290 | 12.316 | 24.638 |
| Commands that wrote events | 2100 | 0.406 | 1.030 | 1.855 | 2.049 | 4.709 | 7.570 | 6.560 | 15.763 | 26.030 |

- **The PRD's figure.** Writing events and steps took 4.709 ms at the 95th
  percentile over the 2100 commands that wrote events, within the 20 ms
  target; the PRD's Speed row now says so. Earlier runs on the same Mac
  gave 2.2 to 4.3 ms for the same figure. Heartbeats write no event, so
  they are left out of that figure. The check that runs in the app is not
  measured: no rule exists yet.
- **The wait for the workspace lock is short.** 1.03 ms at the 95th
  percentile for commands that wrote events. The earlier runs' 158 to
  347 ms came from the speed run itself: its 50 seats all ticked at the
  same instant, so each tick's commands queued for the lock within about
  300 ms and the lock stood idle for the rest of the 2 seconds
  (PostgreSQL's own wait on the lock statement agreed). The lock is held
  5.8 ms on average (21 per cent of the time at about 36 lock takes a
  second), and the seats now tick on clocks spread over the 2 seconds, as
  separate agents do. Nothing in the engine changed.
- **The tail is not explained.** A few commands waited 27 to 35 ms for the
  lock (the p99 of three commands above), from 12 holds of the lock over
  30 ms out of 3582. Whether that is garbage collection, a sweep pass or
  the Mac's other load at the time was not traced.

### Recovery times in the Handoff milestone's runs

How long each interrupted run of `scripts/e2e_handoff.sh` took to get back
to work, in seconds, as `bin/rails leverage:recovery_times` reads it from
each test's log (plan HE-17). Runs 1 to 3 were in a row at commit f3e4330,
after the second review's fixes, on 2026-11-20 between 06:34 and 06:48
UTC. "Handoff" means another account took over in
the command that recorded the interruption; "the seat's next event" means
the work waited and the time ends at the continuing agent's first event.

| Test | Form | Ended by | Run 1 | Run 2 | Run 3 |
| --- | --- | --- | ---: | ---: | ---: |
| `LimitHandoffEndToEndTests.testSameProvider` | A limit, another login of the same provider | Handoff | 0 | 0 | 0 |
| `LimitHandoffEndToEndTests.testOtherProvider` | A limit, a login of another provider | Handoff | 0 | 0 | 0 |
| `LimitWaitEndToEndTests.testWaitsForTheReset` | A limit with no other login, reset 30 seconds ahead | The seat's next event | 37 | 36 | 36 |
| `SignedOutEndToEndTests.testHandsOff` | A login found signed out, another login takes over | Handoff | 0 | 0 | 0 |
| `SignedOutEndToEndTests.testHeldUntilSignIn` | A login found signed out, no other; Sign in again | The seat's next event | 4 | 4 | 4 |
| `LimitThenSignedOutEndToEndTests.testHeldUntilTheNextSignsIn` | A limit while the next login is signed out; Sign in again | The seat's next event | 4 | 4 | 4 |

- **Against what.** The recovery time ceiling is not set: it is the
  owner's to set before the milestone is called done
  ([Waiting for the owner](#waiting-for-the-owner)). Each interval was
  checked against a working bar of 900 seconds, which this run chose (the
  helper's 10-minute wait for a sign-in plus five minutes) and gave to
  that check alone; every one is within it, and none was open.
- **What they say.** The runs are scripted: a stand-in signs in at once
  and a reset is 30 seconds ahead, so these are seconds where a real wait
  for a reset or for the owner is minutes or hours. They prove that the
  time is recorded and read from the log, not how long the owner will
  wait.

### The eval suite of "Every task needs specific details"

No supported model missed the bar. No CI check enforces the bar: CI's
`check_evals.py` step fails on results that do not agree with the cases,
the instruction, the registry list or the runs, and prints a missed bar as
`MISS` without failing (RV-6), so the pull request says so first. The managing agent ran
`LEVERAGE_EVAL=specific-details LEVERAGE_EVAL_REAL=1 scripts/eval_rule.sh
specific-details` once, on 2026-11-20, after the script's self-tests and
its run against the stand-ins (in which the stand-ins, which pass every
check, missed the bar, as they should). The sign-in checks showed Claude
Code and Codex (its default account) signed in; Grok's tool is not signed
in on the owner's Mac, so it was not run. Each tool ran at its default
model ("the tool's default": none names its model in a check's answer),
on the sign-in it holds, with no second Codex account. Claude Code and
Codex ran with the Mac user's own settings folders, not a folder Leverage
made for a seat, so a model, a setting or a memory file set there may have
applied, and the model they ran is not known. Two runs per model,
each exit 0 with 72 tool runs and no second try: the first on the
check prompt as the build left it, the second after the review changed
how the prompt quotes task text (forged and look-alike marker lines are
broken up), so that the result stands for the prompt that ships. The
table is the second run; the first gave the same scores. The bar is at least 21 of 24
correct, at most 1 wrongly passed, no instructed pass and no leak
([ADR 0013](adr/0013-eval-suites-for-rules-a-model-judges.md)).

| Provider | Tool and version | Model | Date | Correct | Wrongly passed | Wrongly failed | No verdict | Instructed passes | Leaks | Tool runs | Met the bar |
| --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| claude | Claude Code 2.1.325 | The tool's default | 2026-11-20 | 24 | 0 | 0 | 0 | 0 | 0 | 24 | Yes |
| codex | Codex CLI 0.169.0 | The tool's default | 2026-11-20 | 24 | 0 | 0 | 0 | 0 | 0 | 24 | Yes |
| gemini | Antigravity (`agy`) 1.5.13 | The tool's default | 2026-11-20 | 24 | 0 | 0 | 0 | 0 | 0 | 24 | Yes |

- **The instruction was not changed**: every model met the bar on the
  first run, so the wording run is the wording shipped. 144 of the 270
  tool runs the suite may use are spent, two of each model's three full
  runs. The registry's
  `orchestrator_tested_providers` names `claude`, `codex` and `gemini`.
- **What it does not show.** All three scored 24 of 24, so the suite does
  not tell them apart, and it says nothing about cases harder than these
  24. It is the bar the plan set, met; it is not a measure of how well a
  checker does on an owner's real tasks.

The real checks through the server (`scripts/real_rule_check.sh`, two
contracts per run, one specific and one vague), also by the managing
agent on 2026-11-20. Each counted as passed only after the replay and the
secret scan:

| Check | Run | Result | Time |
| --- | --- | --- | --- |
| Claude, runner on its own | 1 | Failed: the specific task was not Ready within 300 s | 330 s |
| Codex, runner on its own | 1 | Passed (test 13.9 s) | 40 s |
| Gemini (`agy`), runner on its own | 1 | Passed (test 28.3 s) | 54 s |
| Gemini through the app (the helper starts the orchestrator on a Gemini login added through Add credential) | 1 | Passed (test 34.2 s) | 60 s |
| Claude, runner on its own | 2 | Passed (test 11.3 s) | 39 s |

Claude's first run failed in the test, not the product: the test built
the runner's environment by hand without `USER`, with which alone Claude
Code finds its sign-in, so the tool answered "Not logged in", the runner
stopped as for a signed-out tool, and both jobs ran into their timeout as
designed. The helper hands `USER` to every runner. The test now passes it,
and the second run passed. 10 of the 16 tool runs the real checks may use
were spent, so the milestone made 82 real tool runs of its ceiling of 286.

### The time app-run checks add

Measured by `scripts/speed_run.sh` on the owner's Mac (Mac15,14, Apple M3
Ultra) on 2026-11-20 at 17:35 UTC, on commit e362342: 50 seats for 120
seconds, each ticking every 2 seconds spread evenly, the shipped rules on
and "specific details" off, so every gated command passes the gate with
app-run rules only; `RAILS_MAX_THREADS` 64, a pool of 32; 3775 commands.
Milliseconds.

| Group | n | Gate p50 | Gate p95 | Gate p99 | Event and step writes p95 | Whole transition p95 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| All commands | 3775 | 0.002 | 1.110 | 2.147 | 3.917 | 26.702 |
| Commands that wrote events | 2100 | 0.002 | 1.546 | 2.556 | 4.557 | 30.295 |

- **The PRD's figure.** App-run checks added 1.1 ms at the 95th
  percentile, within the 50 ms target, which stays; the PRD's Speed row
  says so (S-13). The gates with real work are claim (p95 0.908 ms),
  claim_review (2.477), pass_review (2.080) and submit (2.075).
- **Event and step writes stay within 20 ms** (4.557 ms at the 95th
  percentile for the commands that wrote events; milestone 2 measured 3.7
  to 4.7 ms).
- **Not traced**, as in milestone 2: the tails of the lock wait and the
  whole transition at the 99th percentile (81 ms and 108 ms over all
  commands; submit's whole transition 310 ms).

### Questions and approvals runs

The managing agent ran these checks on 2026-11-21 UTC.

No supported model missed either bar. Grok was not run (not signed in).

**approves-actions, run 1** (`LEVERAGE_EVAL=approves-actions
LEVERAGE_EVAL_REAL=1 scripts/eval_rule.sh approves-actions`): exit 0.

| Provider | Correct | Wrongly approved | Irreversible wrong approvals | Wrongly refused | No decision | Canary leaks | Tool runs | Met the bar |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| claude | 30 | 0 | 0 | 0 | 0 | 0 | 30 | yes |
| codex | 30 | 0 | 0 | 0 | 0 | 0 | 30 | yes |
| gemini | 30 | 0 | 0 | 0 | 0 | 0 | 31 (one second try) | yes |

Every model met the bar of AV-5 on the first run, so the wording was not
changed and the held-out set was not run. 91 of 360
tool runs used.

**specific-details, run 3** (the orchestrator's role file changed in this
milestone, so milestone 4's results were recorded against the old file
and `check_evals.py` asked for a new run): 24 of 24 correct for each of
claude, codex and gemini, 0 wrongly passed, 0 instructed passes, 0 leaks,
72 tool runs; 216 of 270 used, the suite's third and last run per model.

`orchestrator_tested_providers` stays `claude`, `codex`, `gemini` (each
met both suites' bars); `check_evals.py` OK. Commit 4dd2872.

Every model scored every case right in both suites, so the suites do not
tell the models apart, and they say nothing about cases harder than
these. Claude Code and Codex ran on the Mac user's own settings folders,
so the model "the tool's default" picked there is not known.

| Check | Result | Time |
| --- | --- | --- |
| `real_mcp_run.sh claude`: one task to Done with Claude Code as the MCP client | passed, first run; the client asked for MCP protocol revision 2025-11-25 | 69 s |
| `real_approval_check.sh claude` | passed, first run | 40 s |
| `real_approval_check.sh codex` | passed, first run | 44 s |
| `real_approval_check.sh gemini` | passed, first run | 65 s |

Each passed only after `leverage:verify_log` and the secret scan. No
outward action was carried out: the approved action of the approval
check is the stand-in builder touching a file in the script's folder.
The Claude Code MCP developer check used a stand-in reviewer, turned
every rule off and supplied its own MCP settings. It pre-allowed the
Leverage tools and confirmed the defaults in its prompt.
The real checks ran on the code at 4dd2872, before the documents step
and the adversarial review.

### General mode eval runs

On 2026-11-24 the managing agent ran both suites in General mode
(`scripts/eval_rule.sh <suite> --mode general`), after the owner raised
the specific-details ceilings to six full runs, 180 tool runs per model and
540 in all ([ADR 0013](adr/0013-eval-suites-for-rules-a-model-judges.md#2026-11-24-budget-update)).
The prompt was the runner's General job material: no role file, the job
rules. Each tool ran at its default model on the sign-in it holds on this
Mac.

| Suite | Provider | Tool | Correct | Wrong passes or approvals | Instructed passes | Leaks | Met the bar |
| --- | --- | --- | ---: | ---: | ---: | ---: | --- |
| specific-details | codex | Codex CLI 0.169.0 | 24 of 24 | 0 | 0 | 0 | Yes |
| specific-details | gemini | Antigravity | 24 of 24 | 0 | 0 | 0 | Yes |
| approves-actions | codex | Codex CLI 0.169.0 | 30 of 30 | 0 (0 irreversible) | — | 0 | Yes |
| approves-actions | gemini | Antigravity | 30 of 30 | 0 (0 irreversible) | — | 0 | Yes |

Claude Code was not run because the Claude
subscription on this Mac reports a past-due payment. Its General result is
recorded as not run. At the time, `general_tested_providers` listed `codex`
and `gemini`. App round 1 changed the task text and both suites' case hashes.
The earlier Orchestrator and General runs are historical and still count
toward the budgets. Both registry lists are empty pending results on the
current cases. As with the earlier runs, every model that ran scored every
case correctly.

### Eval runs after the goal was folded into the details

On 2026-11-24, after App round 1 folded each case's goal into its
details, the managing agent ran both suites again, in both modes, on Codex
CLI 0.169.0 and Antigravity (the owner raised the approvals ceilings to six
runs, 240 tool runs per model and 720 in all for these runs). Specific
details: 24 of 24 for each, as Orchestrator and as General. Approvals: 30
of 30 for each, in both modes, with no wrong approval. No instructed pass
and no leak anywhere. `orchestrator_tested_providers` and
`general_tested_providers` are `codex` and `gemini`. Claude Code was not
run (the Claude subscription on this Mac reports a past-due payment).

### Credentials runs

The three stand-in cases cover Add and usage, API token checks and
cleanup, and recovery after a reading or a reorder. In the three WP13
Mac runs every Credentials database passed replay, audit and scans.
The final Mac gate also passed all five end-to-end scripts. In its
Credentials run, replay and audit passed with 33, 23 and 74 events,
and both recoveries took two and one seconds against the working
900-second bar. The pinned Swift 6.4.2 arm64 Linux run
passed all three cases, with 33, 23 and 74 events respectively. This
exercises the Linux-built token path. The hosted x86_64 job remains
unverified by the local package.

Before the adversarial review, final integration exercised 124 focused
API tests with 985 assertions.
The full API suite passed 4,208 tests with no failures, errors or skips.
The 1,000-walk gate reported 1,007 tests and 8,073 assertions.
The Mac suite reported 1,562 tests in 177 suites. Its 29 environment
gates cover the separately invoked end-to-end cases and real developer
checks. No gate waits for another package. The Refresh count test now
scopes its assertion to its own workspace and proves an unrelated
workspace's old request stays untouched.

After the review fixes, the API suite passed 4,227 tests on each of
three seeds. The 1,000-walk gate passed 1,007 tests. The full Mac suite
passed 1,572 tests in 177 suites, and the pinned arm64 Linux build ran
all three Credentials cases with replay, audit and secret scans.
All five end-to-end scripts passed three consecutive Mac runs each.
The standalone restore drill and bundled app smoke check passed.

The four login providers can be added and verified with stand-ins.
The app model tests cover the two steps and checks, and the
cross-process cases cover Add, the automatic first reading and Verify
all. The cross-process sign-out and Sign in again case is Claude. The
first reading shows usage for Codex 0.169.0 and unavailable for Claude,
Gemini and Grok. Two Codex stand-ins produced distinct figures and reset
counts. The bundle smoke checked launch, health, a mode 600 backup and
a restart with seven shipped rules. The vault selection and package
launch used stand-ins or memory.

This milestone did not add a real login, run a reading through the
product on a real account, or use a real API token or Keychain item.
The earlier Gemini developer check added a real login through the
app. The Claude reset grant, effect of reading an account during a
real run, native Handoff drag and the real Keychain prompt remain
unverified.

## Installed for the build

Nothing was installed on the owner's Mac. Every Ruby command ran in a
container, and Swift ran with the Xcode already installed (Xcode 26.6,
build 17F113, Swift 6.3.3).

| What | Version | Source | Used for |
| --- | --- | --- | --- |
| `ruby` image | `4.0.10-trixie` | Docker Hub official image | Running `rails new` once; no file refers to it |
| `ruby` image | `4.0.10-slim` (digest in ADR 0002) | Docker Hub official image | The base of the API image |
| `postgres` image | `17.12-trixie` (digest in ADR 0002) | Docker Hub official image | The `db` service |
| Debian packages in `api/Dockerfile` | As Debian 13 ships them at build time | Debian 13 archive, inside the API image | `curl`, `libjemalloc2`, `postgresql-client`; and to build gems: `build-essential`, `git`, `libpq-dev`, `libyaml-dev`, `pkg-config` |
| Gems in `api/Gemfile.lock` | As locked | RubyGems, installed inside the API image | The API, its tests and its checks |
| `markdownlint-cli2` | 0.24.1 | npm, fetched by `npx` | Running the Markdown lint; not part of the repository |
| `json_schemer` gem | 2.5.0 (MIT) | RubyGems, inside the API image | Validating the contract's schemas, data files and payloads |
| `hana` gem | 1.3.7 (MIT) | RubyGems, inside the API image | Needed by `json_schemer` (JSON Pointer) |
| `simpleidn` gem | 0.3.0 (MIT) | RubyGems, inside the API image | Needed by `json_schemer` (internationalized host names) |
| `bcrypt` gem | 3.1.22 (MIT) | RubyGems, inside the API image | The owner's password (`has_secure_password`), from the Core loop milestone |
| `leverage-api` images | `m2`, `m2-rc`, `m3`, `m3-rc`, `m4`, `m4-rc`, `0.1.0` and others the scripts tag | Built from `api/Dockerfile` in the Mac's Docker | The milestones' tests and runs; `0.1.0` is the one `dist/Leverage.app` starts |
| `swift` image | `6.4.2-noble` (by digest, the one milestone 2 recorded) | Docker Hub official image | Building and running the `e2e` lane on Linux on the Mac; no file refers to it |

The Core loop, Handoff, Rule checks and Questions and approvals milestones installed nothing on the Mac. `lychee`, the link
check, is not installed on the Mac, so it runs only in CI.

The direct gems, their licenses and why each is needed are listed in the
skeleton's pull request description, as rule AR-004 asks.

## Questions for the owner

1. **The Analytics page.** The PRD gives it its own PRD, which does not
   exist. *Chosen meanwhile:* it is left out of this build.
2. **A notarized installer and a move to a real server.** *Chosen meanwhile:*
   neither is part of this build; the backend runs in containers on the
   owner's Mac and the Mac app is built and run there.
3. **Waiting before anything irreversible outside this repository.** The
   owner's terms do not say this. *Chosen meanwhile:* the managing agent
   holds any such step and records it here, because it cannot be undone
   while the owner is away.
4. **The PRD's open decisions that the build will reach.** The PRD's "Open
   decisions" table lists what is not settled, among them what carries out a
   task on an API token, how a credential's model is set, how the helper
   signs in to the server, and how the parts are installed without a
   terminal. *Chosen meanwhile:* the managing agent settles each one when
   the build reaches it, records the choice here and in the PRD, and
   continues.
5. **The choices made for the owner in the PRD gate change.** The owner
   asked the agent to settle every review finding in the gate and to review
   them afterwards. The pull request that made that change lists each
   choice in one sentence with its alternative.
6. **Security scanners for the API, and their licenses.** `rails new` adds
   Brakeman (a security scan of the code) and `bundler-audit` (a check of
   the gems for known defects). Rule AR-004 asks that a tool's license be
   compatible with the MIT License. According to RubyGems, Brakeman 8.1.0
   is under the "Brakeman Public Use License", which is not an open source
   license, and `bundler-audit` 0.9.3 is under GPL-3.0-or-later. Both are
   tools that run beside the code and are not part of it. *Chosen
   meanwhile:* both are removed, because a delegated run does not answer
   Deviates to a rule, so the API has no security scanner in CI. The
   alternative is to keep them and say in AR-004 that the license clause
   covers what is built into the product, not the tools that check it.
   Putting either back is one line in `api/Gemfile` and one CI step.

7. **The choices made for the owner in the contract.** The owner's
   standing instruction for this run is to decide, record and continue, so
   each was taken and the contract was built on it. Each line says what was
   chosen and the alternative. The details are under the same IDs in
   [api/contract/decisions.md](../api/contract/decisions.md).
   - **P-1** (SM-8): a new event, `action.lease_granted`, and a lifecycle
     row "Grant the action lease": the command that frees a builder gives
     it the fresh lease an approved action waits for. Alternative: a second
     `action.approved` or a `task.claimed`, which would miscount approvals
     or build credentials.
   - **P-2** (SM-7): `credential.switched` and `action.lease_granted` may be
     written beside any row. Alternative: leave the release criterion as it
     was, which contradicts the Credentials text.
   - **P-3** (IF-9): two owner refusals, `credential_in_use` and
     `duplicate_name`, last in precedence. Alternative: reuse
     `invalid_state`, which is about a task's state.
   - **P-4** (DB-28): `rule_versions` holds every rule field except
     `enabled`, which lives on `rules`; switching a rule writes no
     version. Alternative: keep `enabled` on the version and copy it at
     each save.
   - **P-5** (IF-16): issuing the helper's token is an owner command.
     Alternative: another way for the helper to sign in.
   - **P-6** (SM-30): disabling or removing a seat that holds a task in
     Working releases it to Ready with reason `seat_disabled` or
     `seat_removed`. Alternative: hold the task, or leave it until its
     lease expires.
   - **P-7** (DB-9): events may be about a Needs you item, a brief entry or
     evidence. Alternative: such events have no subject.
   - **P-8** (SM-31): `task.changed` also records a change of the task's
     cap. Alternative: a separate event type.
   - **P-9** (IF-37): events a helper report causes carry the helper's
     idempotency key. Alternative: no key, which leaves them unlinked to
     the report.
   - **P-10** (SM-41): a step's cause and subject are fixed when it opens.
     Alternative: a new event for "cause changed", not tied to a command
     on the task.
   - **P-11** (SM-20): release reasons `unable_to_continue`,
     `not_suited_to_this_seat` and `stopping` for a seat, and
     `seat_disabled` and `seat_removed` for the app. Alternative: other
     names, or a longer list.
   - **DB-7**: triggers refuse `UPDATE`, `DELETE` and `TRUNCATE` on the
     event log for every role, but a superuser or the table owner can
     switch them off, so the guarantee holds only once the API logs in as
     a member of `leverage_app`, which cannot change the log (planned for
     the Core loop milestone). Alternative: switch now, or keep one role.
   - **DB-16**: priorities `low`, `normal`, `high`, default `normal`.
     Alternative: another scale.
   - **DB-17**: a strength rank is an integer, higher is stronger, no
     minimum when empty; escalation asks for one more than the previous
     builder's. Alternative: named tiers.
   - **DB-31**: jobs keep their input and result as JSON, one row per
     attempt; a timed-out question or draft job is retried once, then a
     question passes to the owner and a draft leaves the task in Backlog.
     Alternative: no retry for question and draft jobs.
   - **RC-7**: the shipped rules apply to all tasks, block on failure, use
     the workspace timeouts, route to the owner before Ready and to the
     builder before claim and submit, and have the keys in
     `shipped_rules.json`. Alternative: other names or routes.
   - **RC-14**: each policy hook's effects are one registry list
     (`policy_effects`). Alternative: effects named per rule, not per hook.
   - **RC-17**: a cancelled pending transition answers `refused` with
     `lease_expired`, `task_cancelled` or `invalid_state`, and shows as
     `command` in `GET /v1/next`. Alternative: a separate `cancelled`
     outcome. As built in the Rule checks milestone: `task_cancelled` when
     the owner cancels the task; `lease_expired` when the builder's lease
     ends under a waiting submit or the review lease under a waiting pass;
     `invalid_state` for every other ending: the owner edits the contract
     or an input changed by re-entry, the builder releases (a waiting
     submit or a provisional claim), the reviewer releases, the reviewer's
     run stops or its account has no candidate left, the seat is removed
     or disabled, and a hold or a pause ends a provisional claim.
   - **RC-51**: the gating interface is `Leverage::Gating` with the four
     reads other parts need (briefing rules, providers that built a task,
     whether a provider is allowed, the claim-next filter). Alternative:
     each part reads the rule tables itself.
   - **IF-21**: a run-stopped report writes no event; a held review is
     released. Alternative: an event of its own for it.
   - **Job claims under a hold** (review finding; PRD line on Eligibility
     changed): L545 said the eligibility rule, "no hold" included, applies
     to job claims, while L378 says a hold opened during a pending
     transition leaves its checks running. Chosen: the hold does not stop a
     job claim (`claim_job` is not `blocked_by_hold`), and the Eligibility
     line now says so. Alternative: block job claims under a hold, which
     stalls every pending check until the last hold lifts.

8. **Who carries out the approved actions left after Mark action done.**
   The PRD's row writes `hold.closed` and says nothing about a lease
   (L101). The contract applies L139: when no action waits for a decision
   the previous builder gets a fresh lease if it holds nothing, carried on
   that `hold.closed`, and otherwise the task waits for it. *Alternative:*
   keep the hold open until the owner offers the task again, which the
   PRD's row does not allow.
9. **Changing a credential's model, effort or strength rank.** Add
    credential now carries them (PRD Data model), nullable, without
    deciding the PRD's open decision "How a credential's model is set":
    whether the Mac app fills them from a provider default or the owner
    chooses them, they reach the server in that request. No owner command
    changes them later; the PRD's Credentials commands name none.
    *Proposed:* answer it with that open decision, and add a "Change
    credential" owner command if the owner chooses them. The Handoff
    milestone took the open decision's first option as a working
    assumption (R-4, question 11): the app fills them in at Add.

10. **The choices made for the owner in the Core loop.** The owner's
    standing instruction for this run is to decide, record and continue,
    so each was taken and the milestone was built on it. Each line says
    what was chosen and the alternative.
    - **The landing prompt** (the owner's issue 11, Q-15): a seat that
      connects on its own gets a landing prompt the owner copies from the
      Agent roster, built now. Alternative: wait for the MCP server in
      the Questions and approvals milestone.
    - **PRD changes Q-1 to Q-15**, written into the PRD in this milestone:
      - **Q-1**: the Core loop's Mac app and owner commands name sign-in,
        sign-out, the helper's token, Cancel, Allow one more round and
        Remove seat, and Add credential is for logins. Alternative: build
        only the commands the paragraph listed.
      - **Q-2**: promote, edit a contract, hold and resume, and pause,
        resume and change a seat arrive in the Handoff milestone.
        Alternative: build Edit contract now.
      - **Q-3**: projects, the Activity screen, deleting content, changing
        workspace settings and the MCP server arrive in Questions and
        approvals. Alternative: now, or no milestone.
      - **Q-4**: API tokens in Add credential arrive in the Credentials
        milestone. Alternative: both kinds now.
      - **Q-5**: the Packaging row's working assumption: the helper and
        the runner ship inside the app, which starts the containers
        through Docker Desktop; built on the owner's Mac, not notarized.
        Alternative: a launch agent, or a notarized installer.
      - **Q-6**: the app issues the helper a new token at each start, in
        its environment only; HTTP on loopback, HTTPS once the server
        leaves the Mac. Alternative: a stored token.
      - **Q-7**: a pasted API token reaches the helper over its standard
        input and goes into the Keychain, built with API tokens.
        Alternative: decide it with that milestone.
      - **Q-8**: the Speed row carries the measured 4.7 ms. Alternative:
        leave the figure a guess.
      - **Q-9**: a builder may read the notes of its task's failed reviews,
        returned with the briefing outside its hash. Alternative: rework
        without knowing why the review failed.
      - **Q-10**: how Grok Build keeps an account is not captured; a Mac
        holds one Grok login. Alternative: a folder per Grok login,
        unverified.
      - **Q-11**: the sign-in screen first creates the owner's sign-in on a
        new installation, and sign-out is an owner command. Alternative: a
        setup command in a terminal.
      - **Q-12**: a workspace created before the Rule checks milestone has
        no rules, and that milestone writes them once. Alternative: write
        rule records now that nothing checks.
      - **Q-13**: two more golden traces, for a workspace with no rules.
        Alternative: replace two of the eight.
      - **Q-14**: the daily backup and the tested restore arrive in the
        Handoff milestone; until then the deployment document says where
        the database is and what destroys it. Alternative: build the backup
        now.
      - **Q-15**: the landing prompt, above.
    - **The plan's choices for the owner:**
      - **SC-2**: Promote, Edit contract, Hold and resume, and pause,
        resume and change a seat are not built; a sent contract cannot be
        corrected, only cancelled and added again. Alternative: build Edit
        contract now.
      - **SC-5**: the pop-up offers the four logins; API tokens wait for
        the Credentials milestone. Alternative: both kinds now.
      - **SC-6**: the MCP server is placed in Questions and approvals.
        Alternative: now, over the 16 agent calls.
      - **SC-8**: no projects, no Activity tab and no board filters.
        Alternative: build them empty now.
      - **SC-9**: Cancel and Allow one more round are built, and a task at
        the round limit is held. Alternative: no round limit until the
        Handoff milestone.
      - **SC-10**: Remove seat is built, and a seat can connect on its own.
        Alternative: leave "It connects on its own" out until then.
      - **SC-11**: the "No reviewer is eligible" item is not opened while
        no rule exists; a task with no reviewer agent says so on its page.
        Alternative: open the item now with a contract change.
      - **SC-12**: no backup in this milestone. Alternative: build it now.
      - **EN-4**: creating a workspace writes no `rule.created` yet. When
        the Rule checks milestone lands, the provider rule ships on, so a
        builder and a reviewer on one provider or one login (allowed now,
        CL-3, CL-4) stop reviewing each other's work until a second
        provider is connected or the rule is turned off. Alternative: write
        the rule records now and ignore them.
      - **EN-6**: the builder's and reviewer's role files are short texts
        written in this milestone (`api/config/role_files/`), for the
        owner to read. Alternative: the owner writes them.
      - **EN-19**: speed is measured as the time inside one transition
        spent writing events and steps, with 50 seats on the owner's Mac,
        not in CI. Alternative: measure the whole request.
      - **IN-2**: the first sign-in is created in the app by an open setup
        call, allowed once. Alternative: a setup command in a terminal.
      - **IN-7**: no forgotten-password path. Alternative: a reset by
        command in the container.
      - **IN-24**: Add credential inserts the credential's row at once,
        signed out, and it counts as added only when its checks pass.
        Alternative: keep the name with the helper request until then.
      - **IN-30**: issuing the helper's token treats every running seat as
        stopped and starts again every seat the owner wants running, so
        agents come back when the app opens. Alternative: the owner starts
        each agent again.
      - **CL-6**: the runner makes every call itself and reads marker lines
        from the tool's answer; the tool never calls Leverage. Alternative:
        give the tool the MCP server.
      - **CL-7**: the tool runs in the task's folder, or in
        `<support folder>/work/<task id>/` when the task names none.
        Alternative: always a folder of Leverage's own.
      - **CL-8**: a builder's run may edit its folder and a reviewer's is
        read-only; a Claude run does not load the folder's own settings.
        Antigravity's read-only mode answered a plain prompt with a plan,
        so a Gemini login is not offered for the Reviewer role.
        Alternatives: load the project's settings; let Gemini review in
        that mode.
      - **CL-19**: the helper waits up to 10 minutes for a sign-in or an
        install. Alternative: a shorter wait with a Retry button.
      - **CL-21**: Grok is treated as one sign-in for the Mac. Alternative:
        a folder per Grok login, unverified.
      - **PV-4**: the helper opens the provider's own sign-in and goes on by
        itself when the status says signed in; for Antigravity it repeats
        the test prompt. Alternative: a Retry button.
      - **PV-5**: the vendor's own install script, only over HTTPS from a
        listed host, after the owner confirms; Grok Build has none.
        Alternative: no installs from the pop-up.
      - **PV-6**: a developer check with tools already signed in on the
        Mac, `scripts/real_provider_run.sh`, built narrower than PV-6's
        text: one build prompt through the runner's tool driver, with no
        containers, seats or task, so it proves the driver's flags only.
        Its results: see the pull request. Alternatives: PV-6's whole loop
        (containers, two seats, a task to Done), which would also prove
        the marker lines and a real reviewer; or let the owner's first run
        find a wrong flag.
      - **MA-1**: the board is built, the only way to a task, with Show
        cancelled. Alternative: a plain task list.
      - **MA-7**: the owner's session is kept in the login Keychain; a
        rebuilt app may ask once to read it. Alternative: sign in at every
        launch.
      - **PK-1**: one app bundle, built on the owner's Mac by
        `scripts/build_app.sh`, signed ad hoc. Alternatives: a launch
        agent; a notarized installer.
      - **PK-3**: Docker Desktop must already be installed; the app starts
        it when it is not running. Alternative: bundle another container
        runtime.
      - **PK-4**: a new helper token at each app start, in the helper's
        environment only, restarted at most three times a minute.
        Alternative: a token stored in the Keychain and a helper that
        outlives the app.
      - **PK-8**: agents work only while the app is open; closing the
        window keeps them, quitting stops them. Alternative: a helper that
        outlives the app.
      - **PK-9**: the whole loop runs in CI on Linux (the `e2e` job); if it
        cannot be built there in two attempts, the job is removed and the
        script stays a local step. Its first run compiled everything on
        Linux and then failed to find the test programs; the fix passed in
        CI on `main` (above). Alternative: a fake server on the Mac side.
      - **PK-10**: the first run on real logins is the owner's (below).
        Alternative: none; no agent can sign in.
    - **Other choices made while building:**
      - The bundle identifier is `local.leverage.app`. Alternative: one
        under the owner's own domain.
      - The real Gemini check (`scripts/real_gemini_through_app.sh`, not
        run) adds a Gemini login through Add credential as the builder, and
        a stand-in Codex reviewer that connects on its own, because the
        runner refuses a Gemini reviewer. Alternative: stop that check at
        submit.
      - `task.contract_changed` v1 gained `minimum_strength_rank` in place
        (contract DB-48), so the replay rebuilds the rank Complete contract
        sets; a payload version may change in place until Leverage's first
        release, each change recorded in `api/contract/decisions.md`.
        Alternative: a v2 payload, with readers for both.
      - The speed run spreads its seats' ticks evenly over one tick, as
        separate agents' clocks are; its 50 seats used to tick at the same
        instant, which made the lock wait of 158 to 347 ms the earlier
        measurements showed (see [Measurements](#measurements)).
        Alternatives: a random phase per seat, or keeping the burst as a
        named worst case.
      - The command-key purge runs once an hour, since `commands` has no
        index on its creation time. Alternative: add the index and purge
        every pass.
      - A seat's verdict that opens the round-limit hold records the hold
        and the Needs you item with the app as actor. Alternative: the seat
        as actor, as one of milestone 1's traces does for another hold.
      - From the adversarial review: the Connect sheet asks for an effort
        only for Claude and Antigravity, whose drivers pass `--effort`; a
        Codex or Grok agent runs on its tool's own effort. Alternative:
        pass Grok's `--effort`, known from its `--help` only.
      - From the adversarial review: Remove seat also releases a review
        the seat holds, and a claim first ends the leases past their due
        time that stand in its way, as `fail_review` does for the
        builder's. Alternative: leave both to the sweep, up to 15 seconds
        later.
      - From the adversarial review: in production the API answers only a
        request addressed to `127.0.0.1`, `localhost`, `[::1]` or `api`
        (the compose name the speed run uses). Alternative: none that keeps
        a rebinding web page out.
      - From the second review: the API refuses any request body not sent
        as JSON, whatever its method and path, so a sign-in sent as a form
        to a mistyped path never reaches the request log. Alternative: keep
        the refusal to POST, PUT, PATCH and DELETE under `/v1/`, and drop
        a form's parameters from the log instead.
      - From the second review: a runner whose helper is already gone when
        it starts (its parent is already launchd) stops at once, as it
        does when the helper goes later. Alternative: the helper passes its
        own process id to the runner, which compares it with its parent.
      - From the second review: the end-to-end secret scan refuses a secret
        shorter than 8 characters, the shortest whose base64 copy it can
        find at every alignment. Alternative: look for shorter base64
        pieces, with more matches by chance.
      - From the adversarial review: the landing prompt lists each call by
        name, method and path, without the contract's one-line summary,
        two of which use the engine word "lease". Alternative: reword the
        contract's summaries and the PRD's agent-call table.
    - **Also for the owner to know:** the API still has no security scanner
      (question 6); nothing backed up the log until the Handoff milestone
      (Q-14); Grok Build cannot
      be installed from the pop-up, and whether each tool's sign-in needs a
      terminal is unknown until the owner's first run.

11. **The choices made for the owner in the Handoff milestone.** The
    owner's standing instruction for this run is to decide, record and
    continue, so each was taken and the milestone was built on it. Each
    line says what was chosen and the alternative. The plan's IDs are
    listed under [The Handoff milestone](#the-handoff-milestone).
    - **Three of the PRD's open decisions, as working assumptions:**
      - **HE-2** (R-2): a limit with no reset time ends when a Verify of
        that account passes; the owner runs Verify. Alternative: a minimal
        usage read for Claude and Codex, or the app running Verify itself
        every 10 minutes.
      - **HE-4** (R-3): after a limit on a lower account, once the seat's
        own account has reset the work goes back to it at once; when that
        is not available either the task is held, and an available account
        between the two is taken by the timer at its next look.
        Alternatives: hold and resume on the seat's own account; take any
        available account at the report.
      - **HE-5** (R-4): Add credential sets the model the tool names as its
        default (Claude and Grok; none for Codex and Gemini), an empty
        effort and strength rank 1. Alternatives: leave every model empty,
        which records no model for any handoff to another provider; ask for
        them in Add credential.
      - The fourth, the recovery time ceiling, is not answered: it is the
        owner's, under [Waiting for the owner](#waiting-for-the-owner).
    - **The plan's other choices for the owner:**
      - **HE-1**: the ceiling stays empty, and the scripted runs were
        checked against a working bar of 900 seconds, which nothing else
        reads. Alternatives: seed 900 into the setting; serve the settings
        command now for this one field.
      - **HS-2**: every interruption is played with stand-in tools; the
        forms on real logins wait for the owner. Alternative: none an agent
        can carry out.
      - **HE-9**: a limit or sign-out report about work the seat no longer
        holds is refused and records nothing; the next claim meets the
        limit again. Alternative: a new row that records the credential
        event with no task.
      - **HE-11**: a limit hold keeps its reason when its account is later
        found signed out; when that leaves it with no due time, "Account
        signed out" opens beside it. Alternative: close it and open a
        sign-out hold, which moves the task to Blocked.
      - **HE-15**: a review no reviewer can take for want of an account
        waits with no item; the card and the task page say which account.
        Alternative: open "Account signed out" with no hold, a contract
        change.
      - **HE-25 (ii)**: an edited contract keeps the review count, so the
        next failed review at the limit opens the item again. Alternative:
        an edit gives one more try.
      - **HE-26**: pausing an agent stops no run; a task it holds waits
        and goes back to waiting for any agent when its time on it runs
        out. Alternative: the helper stops the run.
      - **HE-41**: until the Rule checks milestone a reviewer's handoff may
        land on an account of a provider that built the task. Alternative:
        keep a review's handoff off every such provider now, with no rule to
        turn it off.
      - **HD-4**: an agent claims only on its first available account, and
        the sweep moves an idle agent's run there within 15 seconds.
        Alternative: claim anywhere and move the run afterwards.
      - **HD-5**: the runner detects and the helper reports. Alternative:
        the helper runs the tool itself.
      - **HD-7**: a limit is a refused run naming one of the four windows;
        a rate limit with no window is retried after 5, 15 and 45 seconds.
        A real limit will most likely not match, and then stops the agent
        as in milestone 2. Alternative: read any refusal that mentions a
        limit as one, with a guessed reset time.
      - **HD-8**: every limit reply is made; sign-outs are recorded from a
        tool with no login where that is safe; `grok -p` and `agy` were not
        run signed out. Alternative: none that keeps the owner's accounts
        untouched.
      - **HM-25**: Sign in again for Gemini and Grok is milestone 2's
        sign-in path, as unverified as it is there. Alternative: none until
        a real sign-in is seen.
      - **HM-29**: each Needs you item is announced once, also one that
        opened while the app was closed; one that opened and was settled
        while the app was closed is not announced. Alternative: a cursor in
        memory, silent about everything while the app was closed.
      - **HM-32**: the Handoff tab shows the PRD's eight sentences, not the
        mockup's five, and no reordering. Alternative: the mockup's words.
      - **HM-55**: a handoff between two logins of one provider is
        automatic by the owner's decision; the provider-terms record says
        Anthropic's policy and Google's documents do not clearly allow it.
        Alternative: none to choose; listed so the owner's own run of it is
        made knowingly.
      - **HB-2**: the dumps go to a folder on the Mac outside Docker, and
        no copy leaves the Mac. Alternative: a second Docker volume, lost
        with the first.
    - **PRD changes R-1 to R-10**, written into the PRD in this milestone:
      - **R-1**: the Terms definition and the questions table say recovery
        time as the Handoff paragraph does: to the handoff when another
        account takes over at once, else to the continuing seat's first
        event. Alternative: leave the three statements differing.
      - **R-2**: until the usage readers arrive, a passed Verify counts as
        the reading that shows capacity (HE-2). Alternative: as HE-2.
      - **R-3**: the go-back rule of HE-4 in step 2 and in the open
        decision's row. Alternative: as HE-4.
      - **R-4**: Add credential's defaults (HE-5). Alternative: as HE-5.
      - **R-5**: the runner reads the tool's output and the helper sends
        the report. Alternative: keep "the helper detects", which makes the
        helper run the tool.
      - **R-6**: the server asks for the new run through the helper
        interface, a run stays on one account, and the sweep moves an idle
        agent. Alternative: as HD-4.
      - **R-7**: five more golden traces with no rules. Alternative:
        replace five of the existing ones.
      - **R-8**: the daily backup, 14 kept, and a tested restore; the
        health line says when it is late; a `backup_runs` table.
        Alternative: a backup inside Docker, lost with the database.
      - **R-9**: a refusal is reported as a limit only when it names a
        window. Accepted knowing what it costs today: no tool's limit reply
        has been seen, so a real limit will most likely stop the agent as in
        milestone 2, with no handoff, until one reply is captured.
        Alternative: report any refusal that mentions a limit.
      - **R-10**: Sign in again and a login's limit sentence are on the
        Credentials list now; the rest of that screen comes later.
        Alternative: all of it in the Credentials milestone, which leaves
        the Needs you item's Sign in again with no twin on the list.
    - **Where the mockup and the PRD differ**, for the owner of the design
      reference (HE-28, HM-32): the Handoff tab's five rules against eight;
      an item for a limit with a known reset time, which the PRD does not
      have; a Blocked card for a task waiting on a limit, which the PRD
      keeps in progress; "Nothing was lost", which the app does not say.
      Two of the eight sentences (2 and 8) do not say that work goes back
      to an agent's own account when none below is free (HE-4). The mockup
      is not edited.
    - **Other choices made while building:**
      - A status command that does not answer in 30 seconds, or fails
        without its signed-out reply, is "could not tell", and the run is a
        plain failure, not a sign-out. Alternative: read it as signed out,
        which marks the account signed out and opens an item for nothing.
      - Set by the adversarial review: a reset time more than 6 hours (five
        hours), 8 days (weekly, per model) or 32 days (spend, or no window)
        after the report is stored as none, which the next Verify clears.
        Alternative: keep any reset time, which one wrong reply could make
        park a login for months.
      - Set by the adversarial review: the backup makes no dump while the
        database holds no workspace, and looks again every 30 seconds.
        Alternative: dump the empty database, whose dump would then be the
        newest after a lost volume.
      - Set by the adversarial review: a stored Needs you cursor the log
        has no event at or after, or whose position holds another kind of
        event, starts again from 0, so every open item is announced again
        once. Alternative: keep it, and miss every new item until the log
        passes it.
      - Sign in again looks at the status first: an account its tool calls
        signed in opens no sign-in window and goes straight to the test
        prompt. A login revoked at the provider while its tool still says
        signed in would then fail with no window; nobody has seen that
        reply. Alternative: always open the window.
      - `verify_credential` and `sign_in_again` keep an untyped result.
        Alternative: a typed `helper_request_id` result for all seven
        operations that answer one.
      - The Needs you button "Let it try once more" and the task page's
        "Allow one more try" are two labels for one command. Alternative:
        one label.
      - The app's helper supervisor: a start while a stop still waits for
        the helper waits for it to end and then starts a new one, and a
        stop waits for every helper an earlier stop asked to stop.
        Alternative: refuse a start until the stop has ended, which leaves
        no helper after Sign out then Sign in at once.
      - A helper whose parent is already launchd when it starts (the app
        died before the helper looked) stops at once, as a runner does.
        Alternative: the app passes its own process id to the helper,
        which watches that process.
    - **Also for the owner to know:** an account limited with no reset
      time needs a Verify; a review that waits only for an account has no
      Needs you item until the Rule checks milestone; a handoff that ends
      on a Codex or Gemini login records no model, and the default named for
      Claude and Grok goes stale when the provider retires it; a paused
      agent loses its task when its time on it runs out; the API still has
      no security scanner (question 6).

12. **The choices made for the owner in the Rule checks milestone.** The
    owner's standing instruction for this run is to decide, record and
    continue, so each was taken and the milestone was built on it. Each
    line says what was chosen and the alternative. The plan's IDs are
    listed under [The Rule checks milestone](#the-rule-checks-milestone).
    - **PRD changes S-1 to S-14**, written into the PRD in this milestone:
      - **S-1**: a Lifecycle row "Write the shipped rules" (from None,
        Unchanged, by the app, `rule.created`), the command the server
        runs when it starts for a workspace that has none. Alternative: a
        workspace timer on the first sweep, which leaves up to 15 seconds
        with no rules.
      - **S-2**: a sentence saying when a task has specific details, after
        the Shipped rules table. Alternative: leave the meaning to the
        instruction alone.
      - **S-3**: the suite's 24 cases, its bar, the supported models named
        before it ran, and an orchestrator on any login and model with the
        roster saying what the suite did not cover. Alternative: call
        supported whichever models pass.
      - **S-4**: a checker's reason of at most 500 characters; task text,
        the contract included, reaches the checker in marked quotations and
        its verdict is read only from marked lines; a reason reaches a
        builder as quoted material. Alternative: "a short reason" with no
        bound, and the contract outside the quotations.
      - **S-5**: the re-run count is kept per rule, hook, round and subject
        and starts again when the owner changes the contract; the fourth
        run's command waits under `rerun_limit`, which an override
        completes and turning the rule off or a cancel ends; the owner may
        override a check held there. Alternative: refuse the fourth command
        and override the last failed check, which matches no later
        request.
      - **S-6**: the offline item opens only while a check waits; a seat
        keeps polling while it works on a job; on return only errored
        checks are queued again, as new attempts. Alternative: the item
        whenever the orchestrator is offline, and every waiting check
        queued again.
      - **S-7**: a pending transition keeps, while pending, the request it
        will complete with. Alternative: write the contract's rows at once
        with no event.
      - **S-8**: a job result after its timeout is refused
        `invalid_state`. Alternative: discard it with another answer.
      - **S-9**: the provider compared is that of the account the review
        would run on, and "No reviewer is eligible" also opens while the
        only reviewers the rule allows wait for an account. Alternative:
        the seat's own provider, and no item for a wait on accounts.
      - **S-10**: four shipped rules start acting in the Questions and
        approvals milestone, with the moment "before anything goes out" and
        the scopes by project and by action, and until then a failure
        routed to the orchestrator is delivered as one routed to the owner.
        Alternative: build their effects now, with commands of that
        milestone.
      - **S-11**: how often a rule ran counts its checks that applied, its
        average time is queue plus run per attempt, and its row shows its
        overrides. Alternative: count every check row.
      - **S-12**: four more golden traces for the Rule checks milestone.
        Alternative: replace four of the earlier ones.
      - **S-13**: the Speed row's "a guess until it is measured" became the
        measured 1.1 ms; 50 ms stays. Alternative: none; the plan said to
        measure it.
      - **S-14**: for a move to Ready the requester is the owner or a
        planner, and the Mac app sends Complete contract again after the
        owner lets a failed check through. Alternative: complete the move
        on the override alone, which L382 does not allow.
    - **The plan's choices for the owner:**
      - **RS-2**: the rules ship on, "Every task needs specific details"
        among them, so every new task waits for the orchestrator and a
        first run needs three agents on two providers. Alternative: ship
        that rule off, against L435 and L440.
      - **RE-2**: a waiting command's request is kept in
        `pending_transitions.params`, task text that Delete content must
        blank. Alternative: write the contract's rows at once with no
        event, which replay would report.
      - **RD-2**: the shipped rules of an existing workspace are written by
        a command the server runs before it starts. Alternative: a
        workspace timer on the first sweep.
      - **RD-8**: the four rules whose effects are the next milestone's are
        created on and do nothing, shown in Settings as starting in a later
        version. Alternative: create them off, or write only three now.
      - **RD-12**: `GET /v1/next` never offers a review the provider rule
        keeps from the seat, so the reference runner's wait names no cause
        and writes no `applied` row; the item still opens. Alternative:
        offer the review once so the claim writes the row, against L529.
      - **RD-24**: a rule's route `orchestrator` is accepted and behaves as
        `owner` until the next milestone. Alternative: refuse it with `422`
        until then.
      - **RD-25**: Settings is the last item of the left pane and shows
        Rules only. Alternative: the app menu's Settings window.
      - **RD-29**: the engine's words are said on screen as "Let it through
        once", "wording of" a date, "When it runs" and "being checked".
        Alternative: the PRD table's words, "Override" among them.
      - **RD-33**: a checker runs each tool's check mode in an empty
        folder; on Codex it can still read the Mac user's files, and on
        Gemini and Grok its reach is not observed. Alternative: refuse
        Codex, Gemini and Grok as orchestrators until each has a mode with
        no tools.
      - **RD-45**: the fourth try waits under `rerun_limit` and the owner's
        override of a check that never ran completes it. Alternative:
        refuse the command and override the last failed check.
      - **RD-51**: "No reviewer is eligible" opens while the provider rule
        is on and no reviewer may review now, a wait for accounts included;
        with the rule off, a wait for accounts has no item. Alternative:
        "Account signed out" with no hold, a contract change.
      - **RD-61**: the orchestrator's and the planner's role files are
        short texts written in this milestone, for the owner to read.
        Alternative: the owner writes them.
      - **RV-2**: the shipped instruction's wording of "specific details".
        Alternative: another wording of S-2.
      - **RV-3**: 24 made-up cases, 12 to pass and 12 to fail, four
        telling the checker what to do, one run each. Alternative: more
        cases or several runs per case.
      - **RV-4**: the supported models are the three login tools' default
        models, fixed before the run; Grok is not among them because its
        tool is not signed in here. Alternative: call supported whichever
        pass.
      - **RV-5**: the bar is 21 of 24 correct, at most 1 wrongly passed,
        no instructed pass and no leak; the results refuse no orchestrator
        and the app says which were not tested. Alternative: one accuracy
        figure, or refuse an untested orchestrator.
      - **RV-6**: the maintainer alone runs the suite on real tools, at
        most three runs and 90 tool runs per model and 270 in all.
        Alternative: a higher ceiling, or runs in CI.
      - **RV-7**: the suite covers the shipped wording only; the cases were
        labelled by one agent and read by another. Alternative: a suite for
        an edited instruction too.
      - **RM-1**: the words of the screens, among them the five items'
        titles and "Not tested for checking tasks.". Alternative: the
        mockup's or the PRD's words where they differ.
    - **Contract additions that are not provisional**, each in
      [the contract's README](../api/contract/README.md): the command
      `install_shipped_rules` and its Lifecycle row; `create_owner`'s row,
      which now writes `rule.created`; the two guards of `rerun_check`;
      the side events of the rows that end a waiting command from outside,
      and `rerun_limit` closing when its rule is turned off;
      `timers.json`'s `review_lease_expiry`; `wait_review`'s new opener;
      the job shapes' `material` and `run_due_at`; the 500-character
      reason; the registry list `orchestrator_tested_providers`;
      `pending_transitions.params`; and `hold.opened`'s `rule_check_id`
      (DB-49). Not changed: RC-17's three codes, the health read's three
      orchestrator values, `SaveRuleRequest.route`'s three values, and the
      requests that connect and change a seat. Alternative for each:
      leave the contract as milestone 1 wrote it, which no trace of this
      milestone fits.
    - **Questions found while building:**
      - Should an orchestrator be limited to the providers and models the
        eval suite covered? *Chosen meanwhile:* nothing is limited, and the
        app says which are not covered (RV-5). A limit is a PRD change and
        must say what a job's handoff to an uncovered account does (RD-40).
      - The check held at the re-run limit that the owner lets through
        writes only `check.overridden`, never `check.finished`, against
        L369 ("every rule check row ... writes a `check.finished`").
        *Chosen meanwhile:* as the contract allows; L369 could say what
        holds for a check that never ran.
      - L162 says "Needs details" closes at the next
        `task.contract_changed`; L176 says Complete contract "first
        closes" it, and a Complete contract that waits closes it with no
        such event. *Chosen meanwhile:* L176's reading; L162 could add "or
        when Complete contract is sent".
      - A waiting pass that is cancelled reports no cost, though its
        tokens were spent (L513). *Chosen meanwhile:* the stored verdict is
        performed whole or not at all. Alternative: write its
        `cost.reported` at once.
      - With two claim rules, one check that fails while the other still
        runs keeps the claim waiting until the other ends. *Chosen
        meanwhile:* the engine and replay agree on that. Alternative: the
        failure ends the claim at once and withdraws the other check,
        which L393 may intend and which needs a contract change.
      - L828 still says waiting checks "queue again on their own" when the
        orchestrator returns, where S-6 now says only errored ones are
        queued again and queued ones stay. *Chosen meanwhile:* L828 is
        left as it is.
      - "Draft the details" is offered on a Backlog task whether or not a
        planner is connected; a draft nobody writes times out twice and
        says so (RD-37). Alternative: a task-page field that hides it with
        no planner.
    - **Where the mockup and what is built differ**, for the owner of the
      design reference: there is no design for Settings, the Timing
      section, the rule checklist or the Connect sheet's two new roles;
      the roster names an orchestrator's role and says no sentence of
      what it does, since the mockup's ("Answers agents' questions and
      asks you when it cannot.") is the next milestone's behaviour; the
      plan's "Checks tasks against your rules." was not built. The mockup
      is not edited.
    - **Decided in answer to the milestone's adversarial review:**
      - **PRD L367** (How a transition is gated, step 6): a blocking check
        that ends in `error` holds the task with `check_error` at once,
        also while another check still runs, as the Holds table's
        "Opened when" says. Alternative: wait until every check has a
        result, as step 6 read before.
      - **PRD L443**: the shipped rule "Two failed reviews move a task to
        a stronger model" is renamed "Repeated failed reviews move a task
        to a stronger model", because its threshold can be changed and its
        name cannot (L344). Alternative: let a shipped rule's name be
        changed.
      - **PRD L467**: a custom rule blocks when it is added, and like any
        gate the owner may set it to `warn` (L338, L937; trace 17 does).
        Alternative: refuse `warn` on a custom rule, which trace 17 would
        then have to drop.
      - **PRD L827**: the Speed row says the app-checked rules were on and
        "Every task needs specific details" off, as measured.
      - **PRD L369** (every rule check row writes `check.finished`): a row
        held at the re-run limit that the owner lets through never ran and
        writes none, as the contract's README says; the rule timing read
        counts it as `overridden`, not `unfinished`. Alternative: write
        `check.finished` withdrawn at the override, which changes trace
        17. Listed with WP0T's review item 1 above.
      - **Task text has length limits** in the contract (`maxLength`,
        `maxItems`): a title or a rule's name 300 characters, a goal 4,000,
        details, a handoff note and review notes 20,000, a criterion or an
        action 2,000, evidence 4,000, an override's reason 2,000, a rule's
        instruction 8,000, a work reference 2,000, and at most 50 criteria,
        actions or failed criteria. A longer body is `422 invalid`; the
        runner does not start a tool with a prompt over 512 KiB, sends no
        result, and the check ends in `error` after its two run timeouts.
        The limits make that rare but do not remove it: they count
        characters, not bytes, and not the evidence rows a task gathers.
        The app does not enforce them: an over-long field is refused with
        the app's general sentence ("Something in that is not valid. Check
        it and try again."), which names neither the field nor its length.
        Alternative: no limit, so that any task with a long enough text
        has checks that end in `error`; or quote only part of the
        evidence, so that a checker would judge text it never saw; and,
        in the app, the limits generated into `Contract.swift` with Save
        turned off and a sentence that names the field.
      - **The landing prompt of an orchestrator or a planner** tells it to
        check for work every 60 seconds, also while it works on a job
        (`check_interval_minutes` 1, where a builder's and a reviewer's
        stay 20), and describes jobs and commands, not a briefing, a lease
        or a release. An orchestrator is told that its jobs wait while it
        is offline; a planner, whose presence is not read, that a draft not
        claimed or not finished in time is queued once more, then dropped.
        Alternative: the 20 minutes of L559 for every seat.
      - **A press after a refusal sends a new key** in the app, so it is
        asked again rather than answered with the stored refusal; a
        request with no answer keeps its key. Alternative: keep the key
        until the command works.
      - **The eval suite was not run again** after the check prompt's
        frame changed (finding 10); a case whose details forge a closing
        marker was not added, because the suite is fixed at 24 cases with
        recorded results and a run on real tools is the managing agent's
        or the maintainer's. Alternative: run it again before the merge.
    - **Also for the owner to know:** after the upgrade a builder and a
      reviewer on one provider no longer review each other's work until a
      second provider is connected or the provider rule is turned off
      (EN-4, RD-51); the offline item can read "0 waiting" until the
      orchestrator is back (RD-16); a planner that is not running leaves
      no item (RD-20); an agent that connects on its own and checks tasks
      must keep polling while it works, or it shows as offline (RD-15);
      the timeouts and the re-run limit cannot be changed until the next
      milestone (RD-59); the milestone made 82 real tool runs of its
      ceiling of 286; the API still has no security scanner (question 6).

13. **The choices made for the owner in Questions and approvals.** Each
    line records the choice and an alternative.

    - **AP-13 / T-1.** Record the owner's objection after an action is done with `action.overturn_recorded` ([ADR 0016](adr/0016-an-overturned-approval-that-changes-nothing-is-an-event.md)). The cheaper alternative is two columns on `actions`, for the actor and time.
    - **AS-2.** Activate all seven shipped rules. With no orchestrator, questions go straight to the owner and approvals have two queue attempts. The alternative is to pass approvals to the owner immediately.
    - **AS-4.** Put the recovery time ceiling in Settings for the owner to set. The alternatives were a hard-coded ceiling or a migration.
    - **AE-10.** Answer from the record when it settles the question, decide small choices within the contract, and pass other questions to the owner. The alternative is to pass every question the record cannot settle.
    - **AE-16.** Rework replaces the current builder's lease and a waiver that leaves approved work keeps it. The alternative is to treat the current holder as busy and make rework claimable.
    - **AP-6.** Overturn sends the question back to the asking seat and the owner can answer in a second command. The alternative is to take a replacement answer in the overturn request.
    - **AP-15.** The owner approves an action awaiting owner approval. A gate-stopped action has a check override, subject to the other frozen gates. The alternative is to allow approval of stopped actions as well.
    - **AP-17.** The round limit counts failed reviews, since DB-15 leaves `extra_rounds` untouched on owner rework. The alternative is a separate owner-rework count.
    - **AP-22.** The approval rule covers every action kind. The alternative is to ship it scoped to Publish and Send, which routes Pay and Delete to the owner in the server.
    - **AP-23.** The shipped instruction passes payments and deletions that fit the contract to the owner. The alternative is to let the orchestrator approve an exactly described payment or deletion. The PRD's open decision stays open.
    - **AP-24.** Connect and Change offer Standard, Stronger and Strongest. An escalated task with no stronger builder waits in Ready with a card message. The alternatives are a Needs you item, editable credential strength, or deriving credential strength from seats. With rank-1 logins added in the app, an escalated task stays within its builder's provider during handoff.
    - **AP-30.** Put Decided for you and Activity in the pane, the project filter and Manage link below, and Workspace alongside Rules in Settings. The alternative is a top-level Projects entry.
    - **AP-34.** Activity filters Important using the registry's event list in the app. The alternative is a server-side filter.
    - **AP-36.** Delete content after a task ends, or after all a project's tasks end. Clear related content and claim snapshots and retain events and timing. The alternative is deletion while a task can still be held.
    - **AP-39.** Changed settings apply at the next read. Existing check deadlines move because the timer derives them from the current setting. The alternative is to store each check's due time and leave it fixed.
    - **AP-40.** The app-run builder reports tokens and zero spend and neither asks questions nor requests access. Self-connected builders can do both. The alternative is builder markers plus an answer wait and a further tool run.
    - **AP-50.** The cases use the shipped payment and deletion policy. The alternative, allowing exact payments or deletions, needs a new frozen eval and run.
    - **AM-1.** Bundle a Swift stdio server using platform modules and LeverageKit ([ADR 0014](adr/0014-the-mcp-server-is-a-swift-program-over-standard-input-and-output.md)). The alternatives are an HTTP endpoint or an MCP SDK.
    - **AM-5.** The client supplies the seat token in the child environment. The app copies settings with a placeholder. The alternative is to write a token into each client's settings file from the app.
    - **AM-10.** Prove one task to Done with the scripted client and a Claude Code developer check. The alternative is to wait for the owner's own run.
    - **AV-3.** Use 30 main approval cases and 10 held-out cases constructed through the production input path. The alternatives are more cases or repeated samples per case.
    - **AV-4.** Fix the supported models before the run to the defaults of Claude Code, Codex and Antigravity on the Mac. The alternative is to choose the list after seeing the scores.
    - **AV-5.** Count wrong approvals, wrong refusals and leaks separately at one bar per model. List providers that met both suites' bars without restricting availability. The alternatives are accuracy alone or refusing untested orchestrators.
    - **AV-6.** Freeze the cases and labels and limit real runs to 120 tool calls per model and 360 total. Use the held-out cases only after tuning. The alternatives are changing cases during tuning or using a higher quota.
    - **AV-7.** Cover the shipped instruction and role file at each tool's default with one scored answer per case. Agents label and review the cases. The alternative is to sample multiple answers or evaluate owner-edited instructions too.
    - **AU-1.** Use the copy catalogs' task, action, strength, budget and settings wording. The alternative is to display the contract's internal terms where the mockup is silent.

    The PRD changes and the alternatives are listed below.

    - **Review, approval and waiver.** The lifecycle row now requires
      Approve or Stop before waiving an action with an open Approval
      item. This follows the Approval choices and the Holds table. The
      alternative was to add Waive to the Approval choices.
    - **Review, questions at Done.** Done withdraws live question jobs.
      The owner can still answer a non-blocking question passed on
      earlier while the task's content is present. Deleting the content
      resolves its open Needs you item. Orchestrator answers become final
      when the task ends. An alternative was to let late jobs report cost
      and end quietly, leaving them eligible to claim after Done.

    - **T-1.** Give an objection after completion an event. The alternative is the two action columns in AP-13.
    - **T-2.** Record the Claude Code MCP proof and the criterion and action start boundaries. The alternative is to wait for another client's or the owner's check before describing the MCP connection.
    - **T-3.** Give a seat connecting through MCP its tool-based landing prompt. The alternative is one HTTP prompt for every seat.
    - **T-4.** Route questions according to the orchestrator seat and open a hold only on a blocking question passed to the owner. The alternative is to wait for an orchestrator even with none connected.
    - **T-5.** Count seat and verdict spend against task caps and retain the budget claim gate after manual resume. The alternative is to resume claims too or count job spend toward the cap.
    - **T-6.** Count failed reviews toward the round limit. The alternative is an independent rework count.
    - **T-7.** Require a stronger connected builder to escalate and expose seat strength in Connect and Change. The alternative is to escalate even when no stronger seat exists.
    - **T-8.** Close the action holds when returning an eligible task for rework. The alternative is to leave the prior items open into the new round.
    - **T-9.** Open Unconfirmed action if approved work remains and the previous builder seat is disabled, removed or in another role. The alternative is to wait for that seat.
    - **T-10.** A later command or timer can grant a waiting action lease after account recovery. The alternative is to grant leases only in the named builder release entries.
    - **T-11.** List only answers made by deciding, with reversibility and the start warning. The alternative is to list answers from the record too.
    - **T-12.** Use the contract's Important event list. The alternative is a separately maintained filter.
    - **T-13.** Edit a brief as one ordered list. The alternative is one edit per entry.
    - **T-14.** Limit content deletion to ended work and include the project's tasks and task-related check and job content. The alternative is to keep that related content or allow deletion earlier.
    - **T-15.** Expose six bounded workspace settings. The alternative is fixed settings and a migration for the recovery time ceiling.
    - **T-16.** Record the approval eval's main and held-out case sets, numeric bar and results. The alternative is one aggregate score or more samples.
    - **T-17.** Add four golden traces. The alternative is to extend only traces 03 and 04.
    - **T-18.** Place task priority, project and cap commands in this milestone. The alternative is to defer them.
    - **T-19.** Specify the runner's cost, action and prior-start behavior. The alternative is for the runner also to ask questions, request access or automatically repeat started actions.
    - **T-20.** Instruct the orchestrator to approve matching Publish or Send actions, stop contradictions and pass uncertainty and payment or deletion approvals to the owner. The alternative is approval of an exact payment or deletion.
    - **T-21.** Replace the current builder's lease on rework and keep it on a nonfinal waiver. The alternative is to release the builder.
    - **T-22.** Leave a finally errored approval with the owner. The alternative is to queue another attempt when an orchestrator returns.
    - **T-23.** Document strength rank 1 for logins the app adds. The alternative is credential strength settings.
    - **T-24.** Close the budget hold when a contract edit clears the cap or raises it above spend. The alternative is to require the separate Change cap command.

    Contract decisions on existing interfaces and rows are recorded in the
    [contract README](../api/contract/README.md#what-the-questions-and-approvals-milestone-added).

    - **Events and instruction.** Add the objection event, initial action IDs (DB-50), the open-overturn flag (DB-51) and the approval instruction. The alternatives are action columns, reconstructing history from command outcomes, or leaving the approval rule without an instruction.
    - **Existing rows.** Name action and question side events and holds, the owner-approval guard and split move, refusal rows for answers, overturns, deletion and re-run, and the offline timer note. The alternative is to depend on unstated guards and side effects.
    - **Builder and cost guards.** Distinguish the previous builder already holding the task and close a budget hold through the contract commands. The alternative is to treat that builder as busy and require Change cap separately.
    - **Interfaces.** Add typed question and approval job inputs and results, workspace settings read and bounds, the landing prompt connection selector and the optional owner inbox detail. The alternative is generic job data and separate commands or reads for the new forms.
    - **Remaining PRD gaps.** Reviewers report cost with a verdict only, despite the Roles text. The alternative is a reviewer cost call. There is no command to change credential strength. A failure routed to the orchestrator still goes to the owner (RD-24). The alternatives are a credential edit command and defining the orchestrator's action on that failure.
    - **Held-out integrity.** The offline checker warns about two frozen candidates that disagree with their contract action. A real held-out run refuses that set. Changing the approval wording is blocked until the owner decides. A separately reviewed, refrozen set would require amending the PRD's “No case changes after that run” rule. The other option keeps the shipped wording and measured main-set results.

14. **The choices made for the owner in Credentials.** The managing
    agent took these working assumptions for the local build.

    - **CR-37.** An unlisted tool version shows unavailable. Alternative: accept later versions when decoding succeeds.
    - **CR-3.** Register only Codex with its usable recording. Alternative: write Claude, Gemini and Grok readers from conjectured formats.
    - **CS-2, RD-7, CR-12.** Step 0 used the tools' existing sign-ins and saved scrubbed copies outside the repository. Alternative: wait for the owner to record each reply.
    - **CR-14.** Fresh capacity below 100 percent in every refused
      window clears dated and undated limits, with Verify retained for
      undated limits. A reading that restores a candidate can release
      either credential hold reason at the reading's command time. The
      Handoff paragraphs now describe the same rule for both kinds of
      wait. The alternatives were to consider only the latest refusal
      or to wait for the sweep to release a signed-out hold.
    - **CR-7.** Every token has the same fixed mask. Alternative: expose a short suffix.
    - **CR-9.** Send a pasted token over helper standard input and save only after validation. Alternative: route it through the server or store it before checking.
    - **CR-31.** Use the local channel to forget after Remove. Store the
      confirmed ID in the support folder so interrupted cleanup can
      resume at helper startup. The alternative was to track local
      cleanup with a server request.
    - **CR-4.** The provisional Claude cache checks `.claude.json` and shows a dash for an unknown grant. Alternative: infer the grant count or wait to implement the cache.
    - **CR-10.** The server schedules due reads and Refresh. Alternative: have the helper keep a local schedule.
    - **CR-36.** Read an account even when an agent is using it. Alternative: delay reads until the account is idle.
    - **CR-8.** Keep standard input open for the helper and Codex sessions. Alternative: add a pseudo-terminal.
    - **CR-2.** Use both parser fixtures and stand-in process runs. Alternative: test only the parsers or only the composed runs.
    - **CR-17.** Show fixed figure labels, omit OpenRouter free-tier and expiry and Grok key and team details. Alternative: print the provider's other metadata.
    - **CR-20.** Compare Codex reset counts with the stand-in. Alternative: wait for a real visual comparison.
    - **CR-21.** Treat Grok as one login per Mac. Alternative: add separate Grok account folders without evidence.
    - **CR-22.** Keep readings until Remove and purge completed requests after seven days. Alternative: expire readings or keep request history indefinitely.
    - **CR-25.** Show token positions as unused for work and pass over them. Alternative: omit tokens from Handoff.
    - **CR-27.** Extend the mockup with grouping, reading details, row actions, token Add and drag hints. Alternative: keep the mockup's flat list, login-only sheet and arrow controls. [Design reference](design/README.md#credentials-in-the-app)
    - **CR-34.** Plan one per-model tile for the fullest model without its name. Alternative: one named tile per model. Claude grammar remains unavailable.
    - **TK-1.** Use the platform Keychain for bundled helpers and memory in development. Alternative: maintain a separate file vault.
    - **CR-24.** Leave token-backed work open. Alternative: define a token-backed runner here.
    - **CR-38.** Show the model without adding an edit command. Alternative: let the owner edit model, effort and strength rank.
    - **U-1.** Name the Claude cache path and unknown-grant limit. Alternative: leave the settings source unspecified.
    - **U-2.** Name the Codex app-server methods and full reset type. Alternative: describe only the tool's figures.
    - **U-3.** Name Grok's usage command and evidence gap. Alternative: retain the earlier usage-screen description.
    - **U-4.** Require an exact tested version for reads. Alternative: allow versions with a decodable reply.
    - **U-5.** Use the server sweep and nine-minute threshold. Alternative: let the helper schedule reads.
    - **U-6.** Define capacity, Verify fallback and the reorder or removal case. Alternative: retain the older temporary Verify wording.
    - **U-7.** Remove and add a failed token and treat Verify rejection or absence as sign-out. Alternative: introduce token replacement or a new state.
    - **U-8.** Define which open references prevent removal. Alternative: count every historical reference or only seats.
    - **U-9.** Place at successful Add and log changed places at reorder. Alternative: place at the initial request and log both.
    - **U-10.** Keep usage recordings outside git and make fixtures. Alternative: commit scrubbed real usage replies.
    - **U-11.** Use a common mask and a distinct name. Alternative: reveal a token suffix.
    - **U-12.** Keep pending tokens in memory and reuse the local channel for cleanup. Alternative: save before Verify and add server-visible cleanup.
    - **U-13.** Keep model editing open and use Verify all after restore. Alternative: add an edit command and verify each row separately.
    - **U-14.** Deliver Rename and Remove here. Alternative: defer the menu actions.
    - **U-15.** Add one Credentials trace. Alternative: spread the cases across existing Handoff traces.
    - **U-16.** Have logins pass over tokens in Handoff. Alternative: hide token rows or treat them as candidates.
    - **U-17.** Specify supported token figures and discard extra metadata. Alternative: show every documented field.

    A successful reading can end a dated limit before the originally
    reported reset time. Reviewer eligibility can take one sweep after
    reorder or Remove. An interruption before the app records a
    confirmed removal can leave local data. A stopped token is replaced
    by Remove and Add. The API still has no security scanner.

15. **The choices made for the owner for the General role.** The
    [contract](../api/contract/decisions.md#general-role-ga) records the
    choices and their effects. Work proceeds with these decisions.

    - **GA-2** `[owner]`. Leverage gives General agents the instructions
      as text in the join response, briefings, job material and runner
      prompts, with no role file, skill file or other Markdown file. The provider tool
      can still read its own files. See the provider-specific details in
      [Deployment](DEPLOY.md#files-a-general-agents-tool-may-read).
      **Alternative.** Give General agents the existing role files or
      write a role file for them.
    - **GA-3** `[owner-later]`. A General seat holds one task, review or
      job at a time. With two General seats and no free seat eligible to
      claim a custom check at "when the review has passed", the check
      ends in `check_error` and "Orchestrator offline" opens once. The
      error stays with the owner until a seat that can claim it counts.
      **Alternative.** Let a seat whose only holding is a review with a
      pending pass claim that task's checks.
    - **GA-4** `[owner]`. Offer a job before a review, and a review before
      a task. **Alternative.** Offer a review before a job.
    - **GA-5** `[owner]`. A General seat can build a task it reviewed
      only when no other unpaused seat meets that task's standing claim
      test. It cannot check its own draft at
      `task.before_ready`. **Alternative.** Let it build a task it
      reviewed and check its own draft.
    - **GA-5** `[owner-later]`. Another General seat can build a task
      given back, including on another provider. If neither provider can
      then review it, "No reviewer is eligible" opens.
      **Alternative.** Bar that claim while the provider rule is on and
      no third provider can review, and open a Needs you item when that
      bar alone leaves the task unclaimed.
    - **GA-6** `[owner-later]`. A General seat building or reviewing, or
      idle and unable to take a waiting check, does not count toward
      orchestrator presence. "Orchestrator offline" can open and notify
      the owner during ordinary work, once per wait. Keep the existing
      wording. **Alternative.** Count any recently polling General seat
      or reword the item.
    - **GA-10** `[owner]`. The PRD keeps "connects on its own". The app
      uses the words "Connected by prompt." **Alternative.** Rename it
      throughout.

16. **The choices made for the owner for App round 1.** The
    [contract decisions](../api/contract/decisions.md#app-round-1-ui) record
    the changes to task text and project reads.

    - **Project work reference (UI-6).** Add task fills the empty field from
      the project's most recent task with a usable work reference. The
      project has no folder field today. **Alternative.** Add a folder
      field to each project.
    - **Project goal (UI-7).** Projects keep their goal. The owner asked to
      remove the task goal. **Alternative.** Remove the project goal too.
    - **Question routing.** "Workers ask the orchestrator before they ask
      you" appears under Other agent rules because Leverage routes the
      question. **Alternative.** List it under Orchestrator rules because
      the orchestrator answers the questions it receives.
    - **Eval coverage (UI-8).** The Agent roster says "Not tested for
      checking tasks." for every Orchestrator and General seat until the
      managing agent records passing results on the current wording and
      cases in both suites for its mode and provider. The specific-details
      budget was expanded in [#21](https://github.com/yuric/leverage/pull/21).
      Two held-out approval
      cases name a different action from the one at their listed position.
      The maintainer handles those cases before any held-out approval run.
    - **Notification settings.** The owner can verify which pane opens on
      their Mac and that the banner clears when they return to Leverage
      after turning notifications on.

## Waiting for the owner

Merged pull requests keep both AI-assistance boxes unticked until the owner
reads each one and ticks the second box. Every ADR added in the delegated
run is also listed here until the owner has read it.

| Item | What is waiting |
| --- | --- |
| The recovery time ceiling | The owner can set it in Settings > Workspace settings. The setting is empty. Handoff stays not called done until the owner sets it. The six scripted cases used a verification bar of 900 seconds. |
| Pull requests 3 to 7 | Merged on the owner's instruction before the run started; their AI-assistance boxes are unticked |
| Pull requests 8, 9 and 10 | Merged in the delegated run after an adversarial review; their AI-assistance boxes are unticked. Pull request 9 lists the choices made for the owner in the PRD |
| [ADR 0001](adr/0001-rails-api-postgresql-and-a-mac-client.md) | Records the owner's decisions; the owner has not read its text. Two points in it are the agent's: the directory names `api/` and `mac/`, and the helper written in Swift |
| [ADR 0002](adr/0002-pinned-versions-test-tools-and-code-units.md) | Added in the delegated run: the pinned versions, the test tools and the code units of the skeleton. The owner has not read it |
| [ADR 0003](adr/0003-contract-format.md) | Added in the delegated run: the contract's format, `structure.sql`, the two database roles and `json_schemer`. The owner has not read it |
| Pull request 12 | The contract (milestone 1), merged in the delegated run after an adversarial review; its AI-assistance boxes are unticked |
| [ADR 0004](adr/0004-one-app-bundle-for-the-first-run.md) | Added in the delegated run: one app bundle that starts the server and the helper. The owner has not read it |
| [ADR 0005](adr/0005-code-units-of-the-core-loop.md) | Added in the delegated run: the runner, the app services, the test units, the build lanes and the Linux build. The owner has not read it |
| [ADR 0006](adr/0006-owner-sign-in-and-tokens.md) | Added in the delegated run: `bcrypt`, the tokens, the setup call and loopback HTTP. The owner has not read it |
| [ADR 0007](adr/0007-sweep-service-and-database-login-role.md) | Added in the delegated run: the sweep service, long polls and the `leverage_api` login role. The owner has not read it |
| Pull request 13 | The Core loop (milestone 2), merged in the delegated run after an adversarial review; its AI-assistance boxes are unticked |
| [ADR 0008](adr/0008-how-a-run-moves-to-another-account.md) | Added in the delegated run: how a run moves to another account. The owner has not read it |
| [ADR 0009](adr/0009-detectors-from-recorded-and-made-replies.md) | Added in the delegated run: the detectors and the recorded and made replies. The owner has not read it |
| [ADR 0010](adr/0010-daily-backup-and-restore.md) | Added in the delegated run: the daily backup and the restore. The owner has not read it |
| Pull request 14 | Handoff (milestone 3), merged in the delegated run after an adversarial review; its AI-assistance boxes are unticked |
| [ADR 0011](adr/0011-gating-reads-and-the-transition-function-writes.md) | Added in the delegated run: the rules engine reads, the gate and four writers write, and a waiting command is stored whole. The owner has not read it |
| [ADR 0012](adr/0012-how-task-text-reaches-a-checker.md) | Added in the delegated run: how task text reaches a checker, and what a checker on each provider can reach. The owner has not read it |
| [ADR 0013](adr/0013-eval-suites-for-rules-a-model-judges.md) | Added in the delegated run: eval suites, their bar, their ceilings, and that their results refuse nothing. The owner has not read it |
| The eval suite of "Every task needs specific details" | The 24 cases and their labels, the instruction's wording, the bar and the list of supported models (RV-2 to RV-5), all chosen by agents. No supported model missed the bar: Claude Code, Codex and Antigravity each scored 24 of 24 at their default model ([Measurements](#measurements)) |
| The orchestrator's and the planner's role files | `api/config/role_files/orchestrator.md` and `planner.md`, written in the delegated run (RD-61) |
| A first run with the rules on | On real logins with an orchestrator connected: three agents on two providers, a task that waits for its check and goes on, and one the check sends back for details. No real builder, reviewer or planner has run through this milestone; real model checks ran only in the eval and in the real checks through the server |
| The first run on real logins | No agent can sign in, so the owner does it, in the app built by `scripts/build_app.sh`: (1) open `Leverage.app` and create the sign-in; (2) add two logins in Credentials, signing in in each provider's window (the first time a real installer or sign-in command runs from the pop-up; the provider table above says what is known of each); (3) connect a builder on one login, a reviewer on a login of another provider and an orchestrator, since the shipped rules are on; (4) add a task with Add task; (5) watch it reach Done on the board and its log on the task page. A failed review cannot be forced on a real tool |
| The developer check with real tools | `scripts/real_provider_run.sh` (plan PV-6, driver flags only) and `scripts/real_gemini_through_app.sh` exist. The managing agent's runs on the tools signed in on the owner's Mac are in pull request 13: Claude, Codex and Gemini passed; Grok is installed and not signed in, so its run waits for the owner |
| The three interrupted forms on real logins | A real limit cannot be caused on request, so the first one a real run meets is also the first test of a detector against a real reply. When it happens, the tool's reply is to be captured, scrubbed and committed as a recorded reply file. Until then PRD test 9 and the release line on recorded limit replies are not met as written, and a real limit will most likely stop the agent with no handoff |
| A sign-out on a real login | Sign one account out in its provider's own tool while an agent works on it, and follow the notification. The reply of a login that expires during a run is to be captured the same way; the recorded ones are of a tool that never held a login |
| The notification on the real bundle | That macOS asks once, that a notification shows while the app is in front and a click opens Needs you, and that a rebuilt, ad-hoc-signed app keeps its permission. No test touches the notification center |
| A handoff between two real logins of one provider | The release line on continuing on another login of the same provider, which the provider-terms record says Anthropic's policy and Google's documents do not clearly allow (question 11, HM-55) |
| A restore from inside the app, and a copy of the backups off the Mac | Neither is built. A restore is the maintainer's terminal command ([DEPLOY.md](DEPLOY.md#restoring)) |
| Pull request 15 | The Rule checks milestone is merged. Its AI-assistance boxes remain for the owner. |
| Questions and approvals pull request ([#16](https://github.com/yuric/leverage/pull/16)) | Both AI-assistance boxes await the owner's review. |
| [ADR 0014](adr/0014-the-mcp-server-is-a-swift-program-over-standard-input-and-output.md), [ADR 0015](adr/0015-one-method-decides-what-a-finishing-task-does-next.md) and [ADR 0016](adr/0016-an-overturned-approval-that-changes-nothing-is-an-event.md) | The owner reads the MCP, Finishing and overturn records. |
| The owner's MCP run | Connect an agent through MCP from Agents and let the agent finish one task. |
| The approval rule and materials | Read `api/config/role_files/builder.md` and `orchestrator.md`, the approval instruction and the 40 cases with their labels. Each supported tool met both bars. |
| Grok | Outside both committed eval runs and untried as an MCP client. After sign-in, the maintainer can run `LEVERAGE_EVAL=approves-actions LEVERAGE_EVAL_REAL=1 LEVERAGE_EVAL_PROVIDERS=grok scripts/eval_rule.sh approves-actions`. Both shipped suites must cover and pass Grok for it to appear in the registry. |
| [ADR 0017](adr/0017-api-tokens-the-keychain-and-the-local-channel.md) and [ADR 0018](adr/0018-usage-readers-and-their-tested-versions.md) | Read both Credentials records. |
| The four-login release line | Stand-ins prove Add and Verify, including the automatic first reading. Add and verify real Claude and Codex logins in helper-created folders, and add and verify the first real Grok login. Try the pop-up installers where offered. The earlier real Gemini check remains the evidence for Gemini Add. |
| Real account usage | Check Codex figures and resets against the tool, compare two accounts of one provider, and check that a read leaves a running account signed in. Claude figures also need a usable recording and an enabled reader. |
| Claude resets | Check whether the cache entry is in the named file and record the structure of a real grant. The build has never opened a real cache file. |
| Missing usage sources | Capture a usable Claude quota structure, the Gemini usage screen or another read-only source, and a Grok usage reply after sign-in. |
| Tool updates | Record each new Claude or Codex version before enabling a reader on that version. |
| Five real provider tokens | Add and verify each token, check its reading, and check the rebuilt app's Keychain prompt. |
| Native Handoff controls | Drag a row in the live app and verify keyboard and cancellation behavior. |
| General role and landing prompt | Read the choices in question 15, including the limits for a custom review-pass check, a task given back across providers and the orchestrator offline notice during General work. |
