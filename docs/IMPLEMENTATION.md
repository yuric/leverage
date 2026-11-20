# Implementation progress

This file says where the build of leverage stands, so that any agent or
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
| **As of** | 2026-11-20 |
| **On `main`** | The rules, the PRD with the gate settled, the design reference, the provider-terms record, the skeleton, the contract (milestone 1) and the Core loop (milestone 2) |
| **Next** | The Handoff milestone (milestone 3): built on `feat/handoff` with every check passing on the owner's Mac; its pull request is not opened yet. Once merged it is not called done until the owner has set the recovery time ceiling |

### In flight

| Work | Branch | Pull request | State |
| --- | --- | --- | --- |
| Milestone 3 handoff | `feat/handoff` | None yet | In review |

## Milestones

The milestones and their content are defined in the PRD under "Build order
and tracks". This table tracks them; it does not define them. Its rows follow
the PRD's milestone list. How the build is run locally is in
[DEPLOY.md](DEPLOY.md).

| # | Milestone | Status | Pull request | Notes |
| --- | --- | --- | --- | --- |
| 0 | Skeleton | Merged | #10 | Not a PRD milestone; it gives the others a place to land. Adds the first product source file, so it activates AR-006 and AR-007: it names the mechanisms and adds the AR-007 check. It lists a second component, so it activates AR-005 too. Its versions and test tools are in [ADR 0002](adr/0002-pinned-versions-test-tools-and-code-units.md) |
| 1 | Contract | Merged | #12 | Adds `api/contract/`, the migrations and the gating interface, and the eleven PRD changes P-1 to P-11. The format is [ADR 0003](adr/0003-contract-format.md); the choices made for the owner are question 7 |
| 2 | Core loop | Merged | [#13](https://github.com/yuric/leverage/pull/13) | With account setup and the part that starts agents. The first milestone usable without a terminal. Built on `feat/core-loop`; the PRD changes Q-1 to Q-15 and ADRs 0004 to 0007; the choices made for the owner are question 11 |
| 3 | Handoff | In review | None yet | With the owner commands Q-2 moved in and the daily backup (Q-14). Built on `feat/handoff`; the PRD changes R-1 to R-10 and ADRs 0008 to 0010; the choices made for the owner are question 12. Every interruption is shown with stand-in tools only. Once merged it is not called done until the owner has set the recovery time ceiling (PRD, Build order and tracks) |
| 4 | Rule checks | Not started | | |
| 5 | Questions and approvals | Not started | | |
| 6 | Credentials | Not started | | The last milestone of this build; the release acceptance run follows it |
| 7 | Analytics page | Not in this build | | See question 1 |

Status is one of `Not started`, `In progress`, `In review`, `Merged`,
`Not in this build`.

## Decisions made during the build

Hard-to-reverse choices are recorded as ADRs in [adr/](adr/). Smaller choices
an agent made without the owner are listed here until the owner has seen
them.

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
The plan's `[owner-later]` choices are in question 11, not here.

- **Scope.** SC-1: the commands the PRD's Core loop paragraph lists, the
  agent calls they need (SC-7: claim, briefing, pass, submit and review
  need next, command outcome, heartbeat, start criterion and release), the
  first-sign-in operations, and Cancel, Allow one more round and Remove
  seat. SC-3: Complete contract with an outward action is `422 invalid`,
  so no Finishing row can be reached. SC-4: Add task into the Imaginarium
  is `422 invalid`; the app adds to Backlog. SC-11 (also question 11): the
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
  leverage token. CL-11: a verdict reports the tool's tokens and spend 0.
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
The plan's `[owner-later]` choices are in question 12, not here.

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
  of an account opens no item; its card says which account. HE-17: a
  recovery time starts at `credential.limit_reached`, or at a
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
- **No waiting account on the task page.** The board card names the
  account a Ready task or a review waits for when no hold is open (HE-15,
  HE-16); the task read has no such field, so the task page names the
  account only from an open hold.
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
  three times in a row on the owner's Mac and again in the final run.
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
| Grok (Grok Build) | No: no documented source was reachable; the pop-up says leverage can't install it yet | By reading `grok models`; `grok login --oauth` is a browser login by its help | Status `probe` (signed out only); sign-in `help`; installer `unverified` |

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
each test's log (plan HE-17). Runs 1 to 3 were in a row at commit 7d6eaba
on 2026-11-20 between 04:22 and 04:35 UTC; the final run was at 04:45 UTC
on the pull request's code. "Handoff" means another account took over in
the command that recorded the interruption; "the seat's next event" means
the work waited and the time ends at the continuing agent's first event.

| Test | Form | Ended by | Run 1 | Run 2 | Run 3 | Final run |
| --- | --- | --- | ---: | ---: | ---: | ---: |
| `LimitHandoffEndToEndTests.testSameProvider` | A limit, another login of the same provider | Handoff | 0 | 0 | 0 | 0 |
| `LimitHandoffEndToEndTests.testOtherProvider` | A limit, a login of another provider | Handoff | 0 | 0 | 0 | 0 |
| `LimitWaitEndToEndTests.testWaitsForTheReset` | A limit with no other login, reset 12 seconds ahead | The seat's next event | 21 | 22 | 21 | 22 |
| `SignedOutEndToEndTests.testHandsOff` | A login found signed out, another login takes over | Handoff | 0 | 0 | 0 | 0 |
| `SignedOutEndToEndTests.testHeldUntilSignIn` | A login found signed out, no other; Sign in again | The seat's next event | 4 | 4 | 4 | 4 |
| `LimitThenSignedOutEndToEndTests.testHeldUntilTheNextSignsIn` | A limit while the next login is signed out; Sign in again | The seat's next event | 4 | 4 | 4 | 4 |

- **Against what.** The recovery time ceiling is not set: it is the
  owner's to set before the milestone is called done
  ([Waiting for the owner](#waiting-for-the-owner)). Each interval was
  checked against a working bar of 900 seconds, which this run chose (the
  helper's 10-minute wait for a sign-in plus five minutes) and gave to
  that check alone; every one is within it, and none was open.
- **What they say.** The runs are scripted: a stand-in signs in at once
  and a reset is 12 seconds ahead, so these are seconds where a real wait
  for a reset or for the owner is minutes or hours. They prove that the
  time is recorded and read from the log, not how long the owner will
  wait.

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
| `leverage-api` images | `m2`, `m2-rc`, `m3`, `m3-rc`, `0.1.0` and others the scripts tag | Built from `api/Dockerfile` in the Mac's Docker | The milestones' tests and runs; `0.1.0` is the one `dist/Leverage.app` starts |
| `swift` image | `6.4.2-noble` (by digest, the one milestone 2 recorded) | Docker Hub official image | Building and running the `e2e` lane on Linux on the Mac; no file refers to it |

The Core loop and Handoff milestones installed nothing on the Mac. `lychee`, the link
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
     outcome.
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

8. **Overturning an approval whose action is already reported done.** The
   PRD says it "is recorded and changes nothing" (L144, L801), but no event
   type or column records it, and the only command row, kept until command
   keys are purged after 7 days, is not a durable record. The contract's
   rows for it write nothing. *Proposed:* a PRD change adding a durable
   record, for example an `action.overturn_recorded` event, or an
   `overturned_by` column on `actions` that replay covers. *Chosen
   meanwhile:* nothing is written, and the gap stays open.
9. **Who carries out the approved actions left after Mark action done.**
   The PRD's row writes `hold.closed` and says nothing about a lease
   (L101). The contract applies L139: when no action waits for a decision
   the previous builder gets a fresh lease if it holds nothing, carried on
   that `hold.closed`, and otherwise the task waits for it. *Alternative:*
   keep the hold open until the owner offers the task again, which the
   PRD's row does not allow.
10. **Changing a credential's model, effort or strength rank.** Add
    credential now carries them (PRD Data model), nullable, without
    deciding the PRD's open decision "How a credential's model is set":
    whether the Mac app fills them from a provider default or the owner
    chooses them, they reach the server in that request. No owner command
    changes them later; the PRD's Credentials commands name none.
    *Proposed:* answer it with that open decision, and add a "Change
    credential" owner command if the owner chooses them. The Handoff
    milestone took the open decision's first option as a working
    assumption (R-4, question 12): the app fills them in at Add.

11. **The choices made for the owner in the Core loop.** The owner's
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
        from the tool's answer; the tool never calls leverage. Alternative:
        give the tool the MCP server.
      - **CL-7**: the tool runs in the task's folder, or in
        `<support folder>/work/<task id>/` when the task names none.
        Alternative: always a folder of leverage's own.
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
        sets; a payload version may change in place until leverage's first
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

12. **The choices made for the owner in the Handoff milestone.** The
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
        waits with no item; the card says which account. Alternative: open
        "Account signed out" with no hold, a contract change.
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
      - The task page names the account a task waits for only from an
        open hold; the board card names it in every case. Alternative: two
        waiting fields on the task read.
      - The Needs you button "Let it try once more" and the task page's
        "Allow one more try" are two labels for one command. Alternative:
        one label.
    - **Also for the owner to know:** an account limited with no reset
      time needs a Verify; a review that waits only for an account has no
      Needs you item until the Rule checks milestone; a handoff that ends
      on a Codex or Gemini login records no model, and the default named for
      Claude and Grok goes stale when the provider retires it; a paused
      agent loses its task when its time on it runs out; the API still has
      no security scanner (question 6).

## Waiting for the owner

Merged pull requests keep both AI-assistance boxes unticked until the owner
reads each one and ticks the second box. Every ADR added in the delegated
run is also listed here until the owner has read it.

| Item | What is waiting |
| --- | --- |
| The recovery time ceiling | The owner sets it before the Handoff milestone is called done (PRD, Handoff and Open decisions). The setting is empty. The six scripted runs were checked against a working bar of 900 seconds, which the run chose; their intervals are seconds, because the runs are scripted ([Measurements](#measurements)). Until the Questions and approvals milestone brings the command that changes workspace settings, the owner's number is written by a migration |
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
| The first run on real logins | No agent can sign in, so the owner does it, in the app built by `scripts/build_app.sh`: (1) open `Leverage.app` and create the sign-in; (2) add two logins in Credentials, signing in in each provider's window (the first time a real installer or sign-in command runs from the pop-up; the provider table above says what is known of each); (3) connect a builder on one login and a reviewer on another; (4) add a task with Add task; (5) watch it reach Done on the board and its log on the task page. A failed review cannot be forced on a real tool |
| The developer check with real tools | `scripts/real_provider_run.sh` (plan PV-6, driver flags only) and `scripts/real_gemini_through_app.sh` exist. The managing agent's runs on the tools signed in on the owner's Mac are in pull request 13: Claude, Codex and Gemini passed; Grok is installed and not signed in, so its run waits for the owner |
| The three interrupted forms on real logins | A real limit cannot be caused on request, so the first one a real run meets is also the first test of a detector against a real reply. When it happens, the tool's reply is to be captured, scrubbed and committed as a recorded reply file. Until then PRD test 9 and the release line on recorded limit replies are not met as written, and a real limit will most likely stop the agent with no handoff |
| A sign-out on a real login | Sign one account out in its provider's own tool while an agent works on it, and follow the notification. The reply of a login that expires during a run is to be captured the same way; the recorded ones are of a tool that never held a login |
| The notification on the real bundle | That macOS asks once, that a notification shows while the app is in front and a click opens Needs you, and that a rebuilt, ad-hoc-signed app keeps its permission. No test touches the notification center |
| A handoff between two real logins of one provider | The release line on continuing on another login of the same provider, which the provider-terms record says Anthropic's policy and Google's documents do not clearly allow (question 12, HM-55) |
| A restore from inside the app, and a copy of the backups off the Mac | Neither is built. A restore is the maintainer's terminal command ([DEPLOY.md](DEPLOY.md#restoring)) |
