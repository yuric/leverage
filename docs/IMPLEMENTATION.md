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
| **On `main`** | The rules, the PRD with the gate settled, the first two decision records, the design reference, the provider-terms record and the skeleton |
| **Next** | The Core loop milestone, once the contract is merged |

### In flight

| Work | Branch | Pull request | State |
| --- | --- | --- | --- |
| Milestone 1 contract | `feat/contract` | None yet | In progress |

## Milestones

The milestones and their content are defined in the PRD under "Build order
and tracks". This table tracks them; it does not define them. Its rows follow
the PRD's milestone list. How the build is run locally is in
[DEPLOY.md](DEPLOY.md).

| # | Milestone | Status | Pull request | Notes |
| --- | --- | --- | --- | --- |
| 0 | Skeleton | Merged | #10 | Not a PRD milestone; it gives the others a place to land. Adds the first product source file, so it activates AR-006 and AR-007: it names the mechanisms and adds the AR-007 check. It lists a second component, so it activates AR-005 too. Its versions and test tools are in [ADR 0002](adr/0002-pinned-versions-test-tools-and-code-units.md) |
| 1 | Contract | In progress | | Adds `api/contract/`, the migrations and the gating interface, and the eleven PRD changes P-1 to P-11. The format is [ADR 0003](adr/0003-contract-format.md); the choices made for the owner are question 7 |
| 2 | Core loop | Not started | | With account setup and the part that starts agents. The first milestone usable without a terminal |
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
