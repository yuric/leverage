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
| **As of** | 2026-11-19 |
| **On `main`** | The rules, the PRD with the gate settled, the design reference, the provider-terms record, the skeleton and the contract (milestone 1) |
| **Next** | The Core loop milestone (milestone 2): built on `feat/core-loop` with every check passing on the owner's Mac; its pull request is not open yet |

### In flight

| Work | Branch | Pull request | State |
| --- | --- | --- | --- |
| Milestone 2 core loop | `feat/core-loop` | None yet | In progress |

## Milestones

The milestones and their content are defined in the PRD under "Build order
and tracks". This table tracks them; it does not define them. Its rows follow
the PRD's milestone list. How the build is run locally is in
[DEPLOY.md](DEPLOY.md).

| # | Milestone | Status | Pull request | Notes |
| --- | --- | --- | --- | --- |
| 0 | Skeleton | Merged | #10 | Not a PRD milestone; it gives the others a place to land. Adds the first product source file, so it activates AR-006 and AR-007: it names the mechanisms and adds the AR-007 check. It lists a second component, so it activates AR-005 too. Its versions and test tools are in [ADR 0002](adr/0002-pinned-versions-test-tools-and-code-units.md) |
| 1 | Contract | Merged | #12 | Adds `api/contract/`, the migrations and the gating interface, and the eleven PRD changes P-1 to P-11. The format is [ADR 0003](adr/0003-contract-format.md); the choices made for the owner are question 7 |
| 2 | Core loop | In progress | None yet | With account setup and the part that starts agents. The first milestone usable without a terminal. Built on `feat/core-loop`; the PRD changes Q-1 to Q-15 and ADRs 0004 to 0007; the choices made for the owner are question 11 |
| 3 | Handoff | Not started | | |
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
- **The Swift copy of the contract** also holds the operations and the
  interface schema's own enums, and `HoldReason.isInBlocked`.
- **Each package committed its own work** by explicit path, the red tests
  first; the plan had the managing agent commit.

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
  It has not yet run on Linux in CI.
- **The failed review is shown with stand-in tools only.** The task in the
  end-to-end run goes through one failed review because the stand-in
  reviewer is scripted to fail round 0. Nothing can make a real provider
  fail a review on request, so no run on a real tool has shown it.
- **No real provider has run through the product.** No agent signed in,
  ran an installer or a sign-in command, or used a login through Add
  credential. The developer check with real tools (`scripts/real_provider_run.sh`,
  plan PV-6) was not written or run in this build, and neither was
  `scripts/real_gemini_through_app.sh`, which exists. The owner's first run
  is the first real one (see [Waiting for the owner](#waiting-for-the-owner)).
- **The app bundle starts its server.** `scripts/smoke_app.sh` opens
  `dist/Leverage.app` with a Finder-like environment and gets a healthy
  answer from the server it started, in about 5 seconds once the images are
  on the Mac. Opening it from Finder itself has not been tried.

Which provider's tool can be installed from the pop-up (PRD line "a
missing tool installed from the pop-up") and which continues on its own
after the owner signs in ("a signed-out tool caught, the flow continues"):
neither line is marked met for a real tool. Both are proven with stand-in
tools for all four providers. The evidence levels are those of
[ARCHITECTURE.md](ARCHITECTURE.md#providers-tools).

| Provider | Installed from the pop-up | Continues on its own after sign-in | Evidence |
| --- | --- | --- | --- |
| Claude (Claude Code) | Yes in code: the vendor's script `https://claude.ai/install.sh`, run with `/bin/bash` | By polling `claude auth status`; whether `claude auth login` opens the browser itself and needs no terminal is not known | Installer `documented`; status `probe`; sign-in `help` |
| Codex | Yes in code: the vendor's script `https://chatgpt.com/codex/install.sh`, run with `/bin/sh` | By polling `codex login status`; what `codex login` does is not known | Installer `documented`; status `probe`; sign-in `help` |
| Gemini (Antigravity) | Yes in code: the vendor's script `https://antigravity.google/cli/install.sh`, run with `/bin/bash` | By repeating the test prompt every 15 seconds; a signed-out `agy` has never been seen | Installer `documented`; test prompt `probe` (signed in only) |
| Grok (Grok Build) | No: no documented source was reachable; the pop-up says leverage can't install it yet | By reading `grok models`; `grok login --oauth` is a browser login by its help | Status `probe` (signed out only); sign-in `help`; installer `unverified` |

## Measurements

The speed of writing events and steps, measured by `scripts/speed_run.sh`
on the owner's Mac (Mac15,14, Apple M3 Ultra) on 2026-11-19 at 20:48 UTC:
50 seats (25 builders and 25 reviewers that connect on their own) for 120
seconds, `RAILS_MAX_THREADS` 64 and a pool of 32 connections, 3775
commands sent by the seats. Milliseconds, nearest-rank percentiles.

| Command | n | Lock wait p50 | p95 | p99 | Event and step writes p50 | p95 | p99 | Whole transition p50 | p95 | p99 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| acknowledge_briefing | 225 | 120.370 | 410.533 | 486.325 | 1.513 | 5.424 | 6.388 | 148.893 | 512.060 | 615.491 |
| acknowledge_review_briefing | 200 | 118.892 | 445.442 | 513.068 | 0.682 | 2.539 | 3.118 | 150.966 | 518.823 | 671.196 |
| claim | 225 | 143.331 | 476.780 | 653.421 | 1.233 | 4.330 | 5.207 | 158.035 | 572.075 | 718.090 |
| claim_review | 200 | 135.247 | 460.991 | 588.393 | 1.419 | 5.044 | 14.730 | 149.231 | 496.654 | 630.321 |
| heartbeat | 1275 | 72.352 | 132.373 | 256.385 | 0.000 | 0.000 | 0.000 | 78.235 | 159.304 | 294.215 |
| heartbeat_review | 400 | 84.125 | 226.391 | 269.687 | 0.000 | 0.000 | 0.000 | 94.642 | 238.615 | 348.067 |
| pass_criterion | 425 | 96.546 | 200.986 | 328.009 | 1.690 | 3.955 | 5.741 | 104.522 | 217.071 | 347.262 |
| pass_review | 200 | 143.250 | 491.217 | 659.704 | 1.890 | 6.661 | 9.007 | 172.324 | 554.910 | 751.963 |
| start_criterion | 425 | 107.669 | 318.891 | 676.809 | 1.249 | 3.235 | 5.483 | 121.461 | 418.371 | 734.629 |
| submit | 200 | 93.801 | 141.536 | 163.619 | 1.164 | 1.619 | 2.047 | 97.764 | 159.098 | 171.382 |
| All commands | 3775 | 91.326 | 230.519 | 520.088 | 1.036 | 2.810 | 5.836 | 103.744 | 250.784 | 615.491 |
| Commands that wrote events | 2100 | 113.273 | 347.326 | 617.540 | 1.400 | 4.330 | 6.509 | 131.827 | 433.540 | 693.100 |

- **The PRD's figure.** Writing events and steps took 4.330 ms at the 95th
  percentile over the 2100 commands that wrote events, within the 20 ms
  target; the PRD's Speed row now says so. Heartbeats write no event, so
  they are left out of that figure. The check that runs in the app is not
  measured: no rule exists yet.
- **The wait for the workspace lock dominates.** It was 347 ms at the 95th
  percentile for commands that wrote events, about 31 commands a second.
  A second run at 21:05 UTC the same day, with the same settings, gave
  158 ms for that wait and 2.267 ms for the event and step writes, so the
  wait varies from run to run. Why it is this large is not known: the lock
  may be held through the commit, the key store and the log line, or a
  wait for a pooled connection (32 for up to 50 requests at once) may be
  counted in it. Nothing was tuned.

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
| `leverage-api` images | `m2`, `m2-rc`, `0.1.0` and others the scripts tag | Built from `api/Dockerfile` in the Mac's Docker | The milestone's tests and runs; `0.1.0` is the one `dist/Leverage.app` starts |

The Core loop milestone installed nothing on the Mac. `lychee`, the link
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
    credential" owner command if the owner chooses them.

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
      - **Q-8**: the Speed row carries the measured 4.3 ms. Alternative:
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
        Mac. It was not written or run in this build. Alternative: let the
        owner's first run find a wrong flag, which is where it stands.
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
        script stays a local step. Its first run has not happened yet.
        Alternative: a fake server on the Mac side.
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
      - `task.contract_changed` carries no minimum strength rank, so the
        replay cannot rebuild a rank set by Complete contract (the app
        sends none; one replay test is skipped for it). Alternative: a new
        payload version that carries it.
      - The command-key purge runs once an hour, since `commands` has no
        index on its creation time. Alternative: add the index and purge
        every pass.
      - A seat's verdict that opens the round-limit hold records the hold
        and the Needs you item with the app as actor. Alternative: the seat
        as actor, as one of milestone 1's traces does for another hold.
    - **Also for the owner to know:** the API still has no security scanner
      (question 6); nothing backs up the log yet (Q-14); Grok Build cannot
      be installed from the pop-up, and whether each tool's sign-in needs a
      terminal is unknown until the owner's first run.

## Waiting for the owner

Merged pull requests keep both AI-assistance boxes unticked until the owner
reads each one and ticks the second box. Every ADR added in the delegated
run is also listed here until the owner has read it.

| Item | What is waiting |
| --- | --- |
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
| The first run on real logins | No agent can sign in, so the owner does it, in the app built by `scripts/build_app.sh`: (1) open `Leverage.app` and create the sign-in; (2) add two logins in Credentials, signing in in each provider's window (the first time a real installer or sign-in command runs from the pop-up; the provider table above says what is known of each); (3) connect a builder on one login and a reviewer on another; (4) add a task with Add task; (5) watch it reach Done on the board and its log on the task page. A failed review cannot be forced on a real tool |
| The developer check with real tools | Not run: `scripts/real_provider_run.sh` (plan PV-6) was not written, and `scripts/real_gemini_through_app.sh` was not run. No result exists for any provider |
