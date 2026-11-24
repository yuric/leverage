# Architecture

| | |
|---|---|
| **Status** | Rules in force. The Core loop, Handoff, Rule checks, Questions and approvals, and Credentials are built. The owner's Mac runs the API, the timer sweep, daily backups, the Mac app and its agents. Agents can connect directly over HTTP or through the MCP server. |
| **Last updated** | 2026-11-23 |

This document describes how Leverage is built: its components, how they
communicate, where data lives, and why the design is the way it is. It
describes the system **as it exists**, not as it is hoped to be. Planned work
belongs in the PRD or in issues.

The technology choices are recorded under
[Technology choices](#technology-choices), the components under
[Components](#components), the contract and what crosses each boundary under
[Data](#data), [Interfaces](#interfaces), [Providers' tools](#providers-tools)
and [Trust boundaries](#trust-boundaries). The [rules](#rules) are in force
now.

## Rules

These rules apply to every change, whoever or whatever writes it. Each rule
has a stable ID that is never reused. A pull request answers every **Active**
rule. A **Pending** rule is agreed but does not apply yet; its status names
the pull request that activates it. A **Retired** rule keeps its row and its
heading, so that its ID stays taken, and is no longer answered.

Pending rules are the one exception to this document describing only what
exists. They are recorded before they apply so that the first code is written
knowing them.

| ID | Rule | Status |
|----|------|--------|
| AR-001 | [Requirement-scoped pull requests](#ar-001-requirement-scoped-pull-requests) | Active |
| AR-002 | [One authoritative home per fact](#ar-002-one-authoritative-home-per-fact) | Active |
| AR-003 | [Decision record for hard-to-reverse choices](#ar-003-decision-record-for-hard-to-reverse-choices) | Active |
| AR-004 | [Declared, pinned, justified dependencies](#ar-004-declared-pinned-justified-dependencies) | Active |
| AR-005 | [Declared dependency direction](#ar-005-declared-dependency-direction) | Active |
| AR-006 | [One mechanism per cross-cutting concern](#ar-006-one-mechanism-per-cross-cutting-concern) | Active |
| AR-007 | [Tests that fail before the change, never silently weakened](#ar-007-tests-that-fail-before-the-change-never-silently-weakened) | Active |

A product source file is a source file outside `docs/`, `scripts/`,
`.github/`, and `.agents/`.

### How the rules are applied

1. **Read them before changing anything.** [AGENTS.md](../AGENTS.md) sends
   every agent here first.
2. **Answer them in the pull request.** The description has an "Architecture
   rules" section with one line per active rule, as a bulleted or numbered
   list:

   ```text
   - AR-001: Complies — implements #12
   - AR-003: N/A — no technology or boundary is chosen or changed
   - AR-004: Deviates — docs/adr/0002-short-title.md
   ```

   - `Complies` means the rule covers something in the change and the change
     follows it. Say in a few words what you checked.
   - `N/A` means nothing in the change is covered by the rule. Give the
     reason, in at least two words. AR-001 covers every pull request, so it
     is never `N/A`.
   - `Deviates` means the change breaks the rule and the maintainer has
     agreed to that. For AR-001, give the reason on the line. For any other
     rule the deviation stays in the repository after the merge, so name an
     ADR with status `Accepted` that records why; it may be added by the same
     pull request.

   An answer and its reason go on one line, or continue on indented lines
   directly below it. The section must be visible to a reader: answers inside
   an HTML comment or a code block do not count.
3. **A required check verifies the answers.** `scripts/check_rules.py` runs as
   the "Rules compliance" check. It fails while any active rule lacks an
   answer in one of those forms, and it runs the mechanical part of each
   rule, listed under the rule as "Checked automatically". It takes the rule
   list from the base branch as well as from the pull request, so a pull
   request cannot drop a rule to avoid answering it. A pull request that was
   already passing when a rule became active answers the rule at its next
   push or edit; the check does not rerun on its own. The check does not
   follow symbolic links in the files that decide its result, and it fails
   when git cannot tell it what the pull request changed.
4. **Review judges what the check cannot.**
   - The check proves that each rule was answered in the right form, not
     that the answer is true.
   - The check runs the pull request's own copy of the script and the
     workflow, so a pull request can change the check. When one changes the
     scripts, a workflow, the template, or this section, the check says so in
     a warning.
   - Every `Deviates` answer also produces a warning.
   - Nothing forces anyone to read the answers or the warnings. The ruleset
     on `main` requires no approving review, because a sole maintainer cannot
     approve their own pull request. The maintainer reads them before
     merging.

Dependabot pull requests are exempt from the "Architecture rules" section,
because Dependabot cannot fill it in. The checks on what the change adds still
run on them, and with no answers there is no `N/A` to soften one. A bot's
description is upstream release notes, so the IDs in it are not resolved.

To add, change, activate, or retire a rule, change this section in a pull
request. Activating a rule adds its line to the
[pull request template](../.github/PULL_REQUEST_TEMPLATE.md) and retiring one
removes it; the check fails if the template and the active rules differ.
The pull request that retires a rule still answers it, because the rule is
active on the base branch. A pull request that deletes a rule's row or heading
fails the check: set the rule's status to `Retired` instead.

### AR-001 Requirement-scoped pull requests

Every pull request has one purpose and names what it implements: requirement
IDs from the [PRD](PRD.md), an issue or pull request, or, when there is
neither, the purpose itself in a few words. It changes only what that
requires, plus the bookkeeping the project asks for (the changelog, `AUTHORS`,
and the documents the change affects). Unrequested features, speculative
configuration, and unrelated edits are left out. So is a layer of indirection
(an interface, base class, wrapper, or plug-in point) that the requirement
does not ask for and that has only one implementation behind it; a test
stand-in counts as a second. An unrelated problem is reported as an issue, or
through [SECURITY.md](../SECURITY.md) if it is security-sensitive. This rule
does not replace the [scope policy](../MAINTENANCE.md#scope): a feature still
needs a requirement in the PRD first.

- **Checked automatically:** the answer is `Complies` followed by a
  requirement ID, an issue or pull request number, or a purpose of at least
  two words; or it is `Deviates` followed by a reason.
- **Left to review:** whether the requirement or number cited is real and is
  the reason for the change (a placeholder row in the PRD and a number that
  does not exist both pass the check), and whether the change contains only
  what was required.

### AR-002 One authoritative home per fact

Each of these facts has one home: a requirement in the [PRD](PRD.md), an
architecture decision in its [ADR](#architecture-decision-records), an
architecture rule (`AR-…`) in this section, and an interface definition in
this document. Other files and pull requests refer to them by ID or link and
do not restate them. Naming a rule's subject next to its ID is a reference;
repeating its conditions is a restatement. A generated file whose source is
in the repository is changed only by changing that source and regenerating
it.

- **Checked automatically:** every well-formed `FR-`, `NFR-`, and `AR-` ID
  (prefix, hyphen, three digits) used in a pull request description or in a
  Markdown file under `docs/` is defined in its home, and every `AR-` ID used
  in any Markdown file is defined here. A description may also name an ID
  that the pull request removes. Text inside HTML comments and fenced code
  blocks is not read. `docs/research/` is left out because it is an archive,
  and Markdown files outside `docs/` use requirement IDs only as format
  examples.
- **Left to review:** whether prose restates a fact that already has a home.
  A generated file is compared with a fresh run only where CI runs its
  generator with `--check`; today that is
  `mac/Sources/LeverageKit/Generated/Contract.swift`, from
  `scripts/generate_swift_contract.py`.

### AR-003 Decision record for hard-to-reverse choices

A pull request that makes or changes a hard-to-reverse choice adds an ADR in
`docs/adr/` with status `Accepted`; merging the pull request is the
maintainer's acceptance. Such choices include a language, runtime, framework,
datastore, external service, and component boundary. A change that
contradicts an accepted ADR supersedes that ADR in the same pull request; an
author who does not have the maintainer's agreement to do that stops and asks
first. The format is under
[Architecture decision records](#architecture-decision-records).

- **Checked automatically:**
  - Every file under `docs/adr/` is an ADR with a valid name, a unique
    number, and a valid status, and a superseded ADR names a successor that
    exists.
  - A pull request that adds the repository's first dependency manifest of a
    kind (`package.json`, `go.mod`, `pyproject.toml`, a `Dockerfile`, and the
    like) adds or changes an ADR.
  - A pull request that changes the [Components](#components) or
    [Technology choices](#technology-choices) section adds or changes an ADR.
    Answering `N/A` turns this one failure into a warning, for a change of
    wording only.
- **Left to review:** whether a choice is hard to reverse, whether the ADR
  says what was decided and has the right status, and whether a change
  contradicts an accepted ADR. A language introduced without a manifest is
  not detected.

### AR-004 Declared, pinned, justified dependencies

A pull request that adds a direct dependency (a library, tool, GitHub Action,
or external service) names each one in its description with its license, its
pinned version or commit SHA, and why existing code or the standard library
does not suffice. A library or tool must exist in its ecosystem's official
registry, and its license must be compatible with the MIT License.

- **Checked automatically:** every `uses:` in a workflow under
  `.github/workflows/` or in an action definition (`action.yml`) is written
  on one line and pinned to a full commit SHA, or to a digest for a container
  image. A third-party action or container image that the pull request adds
  is named in the description, and the answer is then not `N/A`.
- **Left to review:** the license, the justification, whether the package is
  the real one, and whether a changed SHA is the release it claims to be.
  The library manifests (`api/Gemfile`, `api/Gemfile.lock`,
  `mac/Package.swift`) and the image and package lines in `api/Dockerfile`
  and `compose.yaml` are not checked automatically: a reviewer compares them
  with the description.

### AR-005 Declared dependency direction

Code imports only along the dependency directions listed under
[Components](#components). A pull request that needs a new direction changes
that list, with an ADR, in the same pull request.

- **Checked automatically:** `scripts/check_imports.py`, the "Import
  directions" job in CI, reads the
  [allowed dependency directions](#allowed-dependency-directions) and fails
  when a Swift file imports a code unit its own unit may not import, when a
  Ruby file loads a file outside its unit's folder, or when a Swift or Ruby
  file outside `docs/`, `scripts/`, `.github/`, and `.agents/` is in no listed
  unit (`mac/Package.swift`, the package manifest, excepted). Because the
  list is in the Components section, changing it also needs an ADR under
  rule AR-003.
- **Left to review:** a dependency the check cannot see: a file loaded
  through a computed path, a target dependency in `mac/Package.swift` that
  no source file imports, and a call between components that is not an
  import (the Mac side reaches the API only over HTTP).

### AR-006 One mechanism per cross-cutting concern

Each cross-cutting concern (errors, logging, configuration, persistence,
shared helpers) has one designated mechanism, named in this document. A pull
request uses it and does not add a second mechanism or a duplicate of
something it already provides.

The mechanisms are listed under
[Cross-cutting mechanisms](#cross-cutting-mechanisms).

- **Checked automatically:** nothing.
- **Left to review:** whether a change uses the listed mechanism, and
  whether it adds a second one. A change that needs a new mechanism, or a
  first one where the list says "none yet", changes the list in the same
  pull request.

### AR-007 Tests that fail before the change, never silently weakened

A pull request that changes behavior adds or updates at least one test that
fails on the base branch and passes with the change. It does not delete,
skip, or loosen an existing assertion unless its description names the
assertion and the reason.

- **Checked automatically:** for the API and the Mac side only. Their
  product source is any file under `api/` or `mac/` that is not Markdown and
  not in a test folder. A test file is a `.rb` or `.swift` file under
  `api/test/` (for `api/`) or `mac/Tests/` (for `mac/`), and it counts only
  for its own component and only if the lines the pull request adds to it
  include an assertion.
  - A pull request that adds, changes, or deletes product source in a
    component, and adds no assertion to a test file of that component,
    fails. Answering `N/A` with a reason turns the failure into a warning,
    for a change with no behavior in it; a `Deviates` answer with its
    accepted ADR passes. A bot's pull request is held to this too; a
    maintainer answers for it by adding an AR-007 line to its description.
  - A pull request that removes or changes an assertion line or a test
    definition line (`test "..."`, `def test_`, `@Test`, `func test`) in an
    existing test file, deletes a test file that has assertions, or adds a
    skip to an existing test file gets a warning that names the file and the
    lines. The description must name each one and the reason.
- **Left to review:** product source outside `api/` and `mac/` (a Swift or
  Ruby file there also fails the AR-005 check until its unit is listed),
  whether the new test fails on the base branch, whether it tests the
  behavior that changed, whether a warned line really weakens the test,
  whether the description names it, and other ways to disable a test that
  the check does not recognize.

## Engineering practices

These are how the work is done. The [rules](#rules) say what a pull request
must satisfy; where a practice is also a rule, the rule is the authority.

- **Test-driven development.** Write the test first, see it fail, make it
  pass, then tidy with the tests green. Rule AR-007 is the requirement. To
  show it, commit the test before the code, or quote the test's failure on
  the base branch under "How it was verified".
- **The contract first.** What two parts share (tables, event types, the
  fixed lists, the interface schema) is written and reviewed before either
  part is built, and it lives in one place. Parts are built against it, with
  stand-ins where the other side does not exist yet.
- **Small steps that leave `main` working.** Every merge leaves the checks
  green and the product runnable; how work is split into pull requests is
  [AR-001](#ar-001-requirement-scoped-pull-requests).
- **Tests at the level of the behavior.** Unit tests for rules that are pure
  logic, tests against the interface schema for every call, and a run of the
  whole task loop for what crosses parts. A provider's tool is replaced by a
  stand-in in automated tests; nothing in CI calls a provider.
- **No secret in the repository, a log, an event, a fixture or a
  screenshot.** Tests use made-up values. Records name a credential by its
  id.
- **An adversarial review before merge in a delegated run.** In a run
  delegated under [CONTRIBUTING.md](../CONTRIBUTING.md#ai-assisted-contributions),
  a reviewer who did not write the change tries to break it, and its
  findings are fixed or answered in the pull request.
- **Documents in step.** A change that alters behavior, structure,
  configuration or deployment updates the matching document, and
  [IMPLEMENTATION.md](IMPLEMENTATION.md), in the same pull request.

## System overview

```mermaid
flowchart LR
  subgraph mac["Owner's Mac"]
    app["LeverageApp (with LeverageAppServices)"]
    helper["LeverageHelper"]
    runner["LeverageRunner, one per running seat"]
    tool["The provider's tool"]
    client["An agent that connects through MCP"]
    mcp["LeverageMCP"]
    backups[("backups folder")]
    subgraph docker["Docker containers (project leverage-app)"]
      api["api (Rails)"]
      sweep["sweep"]
      backup["backup"]
      db[("db (PostgreSQL)")]
    end
  end
  providerApi["Provider API"]
  app -- "starts with docker compose" --> docker
  app -- "credential messages on standard input" --> helper
  helper -- "HTTPS, token check and usage" --> providerApi
  helper -- "starts usage session" --> tool
  app -- "starts, token in its environment" --> helper
  helper -- "starts, seat token, account and work in its environment" --> runner
  runner -- "exit code 5 and one line: limit or signed out" --> helper
  runner -- "starts, no Leverage token" --> tool
  app -- "HTTP, 127.0.0.1" --> api
  helper -- "HTTP, 127.0.0.1" --> api
  runner -- "HTTP, 127.0.0.1" --> api
  client -- "MCP over standard input and output" --> mcp
  mcp -- "HTTP, 127.0.0.1" --> api
  api --> db
  sweep --> db
  backup --> db
  backup -- "one dump a day" --> backups
```

Leverage runs on the owner's Mac. The Mac app starts the server's four
containers through Docker Desktop ([ADR 0004](adr/0004-one-app-bundle-for-the-first-run.md)):
the API, the sweep that applies due timers, the daily backup
([ADR 0010](adr/0010-daily-backup-and-restore.md)) and PostgreSQL. Once
the owner signs in, the app starts the helper, which polls the server for
its requests: it adds and verifies credentials, reads usage, signs a
login in again,
installs a provider's tool, and starts and stops a `LeverageRunner` for
each seat the app runs, each on the account the server names. A runner
claims tasks or reviews over the agent interface and drives the provider's
tool for each criterion or review. An orchestrator checks rules, handles
questions and decides action approvals. A planner drafts contracts. The
runner drives the tool for each job. A General seat can take work in any
of those roles from the same loop. When a tool run fails because its
account reached a limit or is signed out, the runner tells the helper in
one line. The helper reports it, and the server continues the work on the
next account in the Handoff order or
holds it ([ADR 0008](adr/0008-how-a-run-moves-to-another-account.md)).
Every change goes through the API's transition function, which appends the
event log in the same transaction, and asks the owner's rules at a task's
gated moves ([ADR 0011](adr/0011-gating-reads-and-the-transition-function-writes.md)).
A seat that connects on its own gets a landing prompt with its token and
reads `GET /v1/join` for its instructions. It works through the same agent
interface, directly or through [LeverageMCP](#mcp-server-leveragemcp).

## Components

Seven product units exist: the API and six Swift units.
[ADR 0001](adr/0001-rails-api-postgresql-and-a-mac-client.md) and
[ADR 0005](adr/0005-code-units-of-the-core-loop.md) record the original
units. [ADR 0014](adr/0014-the-mcp-server-is-a-swift-program-over-standard-input-and-output.md)
adds the MCP server.

### API

- **Responsibility:** the server of a workspace. It serves the operations
  listed in `Leverage::Http::RouteTable` (see [Interfaces](#interfaces)):
  the owner's sign-in and commands, the agent calls of the five roles, and
  the helper's calls. Every change is a command through
  `Leverage::Transitions.apply`, the one writer: it takes the workspace's
  lock, finds a stored outcome by idempotency key, applies due timers,
  picks a refusal by the registry's precedence, asks the rules through
  `Transitions::Gate`, runs the command's entry, appends its events and
  moves the steps in the same transaction, and stores the outcome. Reads are
  `Leverage::Reads::*`, which write nothing; the owner's reads run in one
  repeatable-read snapshot and carry the log position they saw.
  `Leverage::Candidates` reads a seat's candidates in the Handoff order and
  which of them is available; `Leverage::Handoff` is what happens to a
  piece of work when its account stops or becomes available again (switch
  to the next candidate, hold the task, release the review, or close a
  credential hold), and the only caller of `Holds` for the two credential
  reasons; `SeatRuns.ensure_run_on` asks the helper for a run on the
  account the work is recorded on
  ([ADR 0008](adr/0008-how-a-run-moves-to-another-account.md)).
  `Leverage::Backup` makes and prunes the daily dumps and restores one
  ([ADR 0010](adr/0010-daily-backup-and-restore.md)).

  The owner's rules
  ([ADR 0011](adr/0011-gating-reads-and-the-transition-function-writes.md)):
  `Leverage::Rules::Engine`, the gating implementation, decides from the
  rule tables and the log and writes nothing; `Transitions::Gate` asks it
  at an entry's hook with the hashed inputs of `Leverage::HookInputs` and
  applies the answer: perform the entry, store the command as a pending
  transition and answer `pending`, or take the hook's failed-gate effect.
  An app checker (two are built: the acceptance-criteria count and the
  provider rule) answers inside the command; a model check is a
  `rule_check` job. The writers each own what they name: `RuleChecks` the
  check rows and every `check.*` event, `Jobs` the jobs and `job.*`,
  `PendingTransitions` a waiting command and its later outcome, which it
  completes as the requester, refuses or cancels, and `RuleRecords` the
  rules and their versions. A waiting command ended from outside goes
  through `PendingTransitions.cancel` alone. `RolePresence` reads polls
  in the last 90 seconds for enabled Orchestrator seats that have an
  available account or connect on their own. A check waits while its
  `rule_check` or `approval` job is queued or while it is held with
  `check_error`. While a check waits, a General seat must have polled in
  the last 90 seconds and either hold an orchestrator job or hold nothing
  and be a seat that could claim it (Jobs.next_for). A check held with
  `check_error` is considered as a new attempt. The same set of waiting
  checks drives `orchestrator_offline`. The timer queues an errored rule
  check again when a counting General seat passes the job claim tests
  for that attempt, independently of queue order. A counting Orchestrator
  can take it once free. Errored claim-check holds close on recovery so the
  next claim checks afresh.
  [PRD check errors and presence](PRD.md#when-a-check-cannot-run)

  `ReviewerEligibility` opens and resolves "No reviewer is eligible".
  In a workspace with a General seat, the board and task page share the
  independent reviewer reading for each unassigned review, including
  when the provider rule is off. Their account waits include General
  seats. Ready account waits use `Eligibility.claim_standing?`, the
  same standing test the engine uses to determine the Ready step's
  account wait cause.
  Four timers time out a check's or a draft's job in the queue and in its
  run, and two workspace timers, `orchestrator_offline` and
  `reviewer_eligibility`, run on every sweep. The 120 seconds within which
  a stopped orchestrator's item opens rest on two numbers: the sweep every
  15 seconds and a seat's last poll written at most every 10 (90 + 10 +
  15); a busy reference runner keeps polling every 30 seconds while its
  tool runs, and the join instructions tell an agent that connects on
  its own when to poll. `bin/rails leverage:install_shipped_rules`, which
  the image's entrypoint runs before the server starts, writes the seven
  shipped rules of a workspace that has none.
- **Owns:** the PostgreSQL database and the HTTP interface under `/v1`.
- **Depends on:** PostgreSQL, and the gems in `api/Gemfile`. It depends on
  no other component.
- **Code:** `api/`, a Rails application in API mode; tests in `api/test/`.
  `api/lib/leverage/` holds the transition function (`transitions.rb`,
  `transitions/`, one entry per command in `transitions/entries/`), its
  parts (`event_log.rb`, `workspace_lock.rb`, `idempotency.rb`,
  `steps.rb`, `holds.rb`, `leases.rb`, `timers.rb`, `eligibility.rb`,
  `briefing.rb`, `tokens.rb`, `seat_runs.rb`, `candidates.rb`,
  `handoff.rb`, `contract_diff.rb`, and for the rules `hook_inputs.rb`,
  `transitions/gate.rb`, `pending_transitions.rb`, `rule_checks.rb`,
  `jobs.rb`, `job_inputs.rb`, `rule_records.rb`, `role_presence.rb`,
  `reviewer_eligibility.rb`), the engine (`rules/`, which reads only), the
  sweep (`sweep.rb`, `api/bin/sweep`), the backup (`backup.rb`,
  `api/bin/backup`, `api/bin/restore`), the reads (among them
  `reads/inbox.rb`, `reads/recovery_times.rb`, `reads/rules.rb`,
  `reads/rule_timing.rb` and `reads/task_timeline.rb`), `Leverage::Replay`
  and `Leverage::LogAudit` (run by `bin/rails leverage:verify_log`;
  `bin/rails leverage:recovery_times` prints every recovery time and
  `bin/rails leverage:rule_timing` each rule's runs and times), and
  milestone 1's `Leverage::Contract` and `Leverage::Gating`.
  `api/script/evals/build_inputs.rb` builds the eval suite's job inputs.
  `api/config/role_files/` holds the role files for Builder, Reviewer,
  Planner and Orchestrator. A General briefing has no role file.
  `roles.json` supplies the General briefing's `work_rules` and each job
  material's `job_rules`. The join instructions use the same sentences
  for the relevant kind of work.
  The templates in `api/config/` are `landing_prompt.txt.erb`,
  `join_http.md.erb` and `join_mcp.md.erb`. The API image runs in the
  `api`, `sweep` and `backup` containers that `compose.yaml` describes.

### Shared Swift library (LeverageKit)

- **Responsibility:** what the Mac side's programs share: the clients of
  the three interfaces (`OwnerClient`, `AgentClient`, `HelperClient`
  behind the protocols `OwnerAPI`, `AgentAPI`, `HelperAPI`), sent through
  `HTTPTransport`; the contract's models; the contract's fixed lists and
  operations in `Generated/Contract.swift`, written by
  `scripts/generate_swift_contract.py`; `Subprocess`, `Log` and
  `Redaction`; `ProviderCatalog` (with the model each tool names as its
  default, where it names one); `EnvironmentKeys`; and the protocols the
  app's screens depend on (`AppRuntime`, with `Notifying` and
  `InboxCursorStoring`). `Detection/` holds one detector per provider,
  which reads a failed tool run and answers limit (with its window and
  stated reset time), short rate limit, signed out or failed
  ([ADR 0009](adr/0009-detectors-from-recorded-and-made-replies.md));
  `SignInStatus` asks a tool's status command whether an account is
  signed in and keeps nothing of its output; `RunEndReport` is the one line
  a runner prints when its account stops, naming the task, the review or
  the job it was on. The models of the rules, the rule checks, the jobs and
  a task's timing are in `Models/`. The registry's list of providers that
  met both eval bars is `ContractLists.orchestratorTestedProviders`.
  The generator also writes the agent tool schemas to
  `Generated/AgentTools.swift` from the interface contract.
- **Owns:** every HTTP call from the Mac side to the API, and the decoding
  of the answers.
- **Depends on:** Foundation (`FoundationNetworking` where it exists), the C
  library, and the API over HTTP.
- **Code:** `mac/Sources/LeverageKit/`; tests in `mac/Tests/LeverageKitTests/`.

### Reference runner (LeverageRunner)

- **Responsibility:** one seat's work, as a process the helper starts. It
  long-polls `GET /v1/next`, claims a task or a review, acknowledges the
  briefing, heartbeats the lease, runs the provider's tool once per open
  criterion (a builder) or once per review (a reviewer), reads the marker
  lines `LEVERAGE-EVIDENCE`, `LEVERAGE-CANNOT`, `LEVERAGE-CRITERION` and
  `LEVERAGE-NOTES` from the answer, and sends the calls. One driver per
  provider gives the tool's arguments (see
  [Providers' tools](#providers-tools)). `LeverageRunner probe` runs one
  test prompt, for the helper's `test_prompt` check. On a stop signal it
  ends the tool's process group, gives back what it holds and exits 0.
  After a failed tool run of a seat with a credential, `Interruption` asks
  the provider's detector and, when that settles nothing, `SignInStatus`;
  it retries a short rate limit after 5, 15 and 45 seconds. On a limit or
  a sign-out it stops heartbeating, gives back nothing, prints one
  `RunEndReport` line on standard output and exits 5. Started with work to
  continue (`LEVERAGE_CONTINUE_TASK_ID` or `LEVERAGE_CONTINUE_REVIEW_ID`),
  it goes on from that work's first criterion that has not passed. A
  builder's or reviewer's prompt carries the briefing's rules as quoted
  material. A command that answers `pending` is asked for again by its key
  until it is decided; a submit refused `blocked_by_rule` is worked again
  with the rule's name and reason as quoted material, up to the server's
  re-run limit. The builder runs approved actions in `FinishingFlow` and
  reports the work through the agent interface. `JobFlow` claims one job
  and calls `CheckJob`, `DraftJob`, `QuestionJob` or `ApprovalJob`. The
  runner sends the result once and asks `GET /v1/next` every 30 seconds
  while the tool runs.
  [ADR 0012](adr/0012-how-task-text-reaches-a-checker.md)
  The General runner uses `SeatRole.actsAs` to take
  jobs, reviews and tasks in one polling loop. While idle it is offered
  a job first, then a review, then a task. Its build and review prompts
  give the briefing's `work_rules` before quoted task text. Its fresh
  job prompts give `job_rules` from the material. General eval mode
  measures these job prompts on app-managed default models.
  It writes no role, skill or Markdown file into a work folder.
  `LeverageRunner eval` runs the two eval suites through the production
  `CheckJob` or `ApprovalJob` without serving the HTTP API.
  [ADR 0013](adr/0013-eval-suites-for-rules-a-model-judges.md)
- **Owns:** nothing stored. It makes `<work root>/<task id>/` when a task
  names no folder, and `<work root>/jobs/<random id>/` for each tool run
  of a job, removed after the run.
- **Depends on:** LeverageKit.
- **Code:** `mac/Sources/LeverageRunner/`; tests in
  `mac/Tests/LeverageRunnerTests/`.

### MCP server (LeverageMCP)

- **Responsibility** is to expose the agent interface as tools over MCP.
  The client's settings start the process. `ToolCatalog` lists the
  generated tools for the configured role, and `ToolCaller` forwards
  calls through the shared HTTP transport. The `get_join` tool reads
  the MCP form of the join instructions. The server keeps the current
  task or review in memory for heartbeats and work calls.
  [ADR 0014](adr/0014-the-mcp-server-is-a-swift-program-over-standard-input-and-output.md)
- **Owns** the MCP session, with the Rails API authoritative for seat
  authorization, idempotency and work state.
- **Depends on** LeverageKit, Foundation and CoreFoundation.
- **Code** lives in `mac/Sources/LeverageMCP/`, with tests in
  `mac/Tests/LeverageMCPTests/`.

### Mac helper (LeverageHelper)

- **Responsibility:** a command-line program the app starts with the
  helper's token. It long-polls `GET /v1/helper/next` and does one request
  at a time: the three login checks of Add credential and Verify (tool
  installed, signed in, test prompt), with progress per check; installing
  a provider's tool from its catalog source after the owner confirmed;
  starting a seat's run (seat-token pickup, then `LeverageRunner` with the
  token, the account and the work to continue in its environment) and
  stopping it; and Sign in again (`SignInAgain`: the provider's own
  sign-in, then the verify checks). A start for a seat whose run is alive
  is a hand-over: the new token first, then the old run is stopped, then
  the new one starts. A seat of any of the five roles is started the same
  way. When a runner exits 5 the helper reads its last line
  and sends `report_limit` or `report_signed_out`, with the job's id when
  the run was on a job (`InterruptionReporter`). It never adopts an existing
  account folder: Add always starts from a new, empty one. It stops its
  runs and exits when its token answers `401` (exit 3) or when the app that
  started it is gone (`ParentWatch`, in LeverageKit), also when it was
  gone before the helper looked (its parent is launchd). A runner watches
  the helper the same way and stops as on SIGTERM when the helper is gone,
  also when it was gone before the runner looked.
  How long each part of a stop is given is `StopTimings`, in LeverageKit:
  the app waits 16 seconds for the helper, the helper 10 for a runner, and
  a runner 4 to give back what its seat holds.
- `UsageRead` runs a version-gated login reader or asks `ProviderHTTP`
  for a token provider's reply. It reports the reading separately from
  the check outcome. `LocalChannel` decodes credential messages.
  `PendingTokens` holds a pasted value until Add checks it. The vault
  saves successful tokens by credential ID. `CredentialCleanup` cancels
  work for a forgotten credential and handles local deletion.
- **Owns:** the account folders, the tools Leverage installed, and the
  runs' logs, under the support folder (see [Data](#data)).
- **Depends on:** LeverageKit, Foundation and macOS Security when available.
- **Code:** `mac/Sources/LeverageHelper/`; tests in
  `mac/Tests/LeverageHelperTests/`.

### Mac app services (LeverageAppServices)

- **Responsibility:** what the app does outside its window, without
  SwiftUI: `DockerLocator` (the `docker` program in four known folders),
  `ServerFiles` (the server folder), `ServerSupervisor` (Docker Desktop,
  `docker compose up -d`, the wait for health), `HelperSupervisor` (the
  helper's token, process, standard input, restart and stop), `AppLock` (one app
  per support folder), `SessionStore` (`KeychainSessionStore` and
  `MemorySessionStore`), `ProcessRunner` for docker's commands,
  `UserNotifier` (macOS notifications through the platform's
  `UserNotifications`) and `InboxCursorStore` (the last Needs you item
  announced). `ServerFiles` also makes the backups folder.
- **Owns:** the server folder, the backups folder, the inbox cursor file
  and the owner's session in the Keychain.
- **Depends on:** LeverageKit and Foundation.
- **Code:** `mac/Sources/LeverageAppServices/`; tests in
  `mac/Tests/LeverageAppServicesTests/`.

### Mac app (LeverageApp)

- **Responsibility:** the owner's window. It starts the server and, after
  sign-in, the helper; creates the owner's sign-in on a new installation,
  signs in and out; and shows the board (with the Ideas lane), the task
  page with its log, its Timing section, its rule checklist with "Let it
  through once" and "Run it again", and "Draft the details", Change the
  task, Pause and Continue, the Add task form (with Save as an idea), Needs
  you, the Agent roster with Connect for the five roles, Pause, Resume and
  Change, and New prompt for a seat that connects on its own, the
  Credentials list with Add credential, Refresh, Verify all, usage and
  resets where available, and row actions, the Handoff tab with a
  reorderable list and its eight fixed rules, and
  Settings with Rules and Workspace, Projects, Activity and Decided for
  you. The task page includes questions, outward actions and task settings.
  `InboxWatcher` announces each Needs you item once, through
  `Notifying`, and keeps the count on the tab. Every owner-facing sentence
  is a case of a copy catalog, checked against the PRD's banned terms by
  `CopyTests`. `Live.swift` builds the real services (`LiveSettings`, the
  support folder's lock, the notifier and the inbox cursor); the image tag
  comes from the bundle's `LeverageAPIImageTag`.
- **Owns:** nothing stored itself; the services above keep the session and
  the inbox cursor.
- **Depends on:** LeverageKit, LeverageAppServices and SwiftUI.
- **Code:** `mac/Sources/LeverageApp/` (`Shell/`, `SignIn/`, `Board/`,
  `AddTask/`, `TaskPage/`, `NeedsYou/`, `Agents/`, `Credentials/`,
  `Handoff/`, `Settings/`, `Design/`); tests in
  `mac/Tests/LeverageAppTests/`. `scripts/build_app.sh` assembles
  `dist/Leverage.app` from it, the helper, the runner, the MCP server and
  `mac/Packaging/`.

### Test units

`LeverageTestSupport` holds what the Swift tests share: the stand-in tool
locator, temporary folders, `StubURLProtocol` and in-memory fakes of the
three API protocols and of the app's runtime, among them `FakeNotifier`
and `FakeInboxCursorStore`. `LeverageEndToEndTests` runs the built helper
and runner against the real API. `scripts/e2e_core_loop.sh` also runs a
prompt-connected agent. `scripts/e2e_handoff.sh` runs the six interrupted
cases, and `scripts/e2e_rule_checks.sh` runs the eight rule-check cases.
`scripts/e2e_questions_approvals.sh` adds seven runs and starts the built
MCP server against the real API with `ScriptedMCPClient`.
`LeverageMCPTests` checks protocol, process, tool and heartbeat behavior.
`mac/Tests/StandIns/` holds the stand-in tools (`claude`, `codex`, `agy`,
`grok`, an installer and an archive) in Python and shell, and under
`replies/` the provider replies the detectors are tested against and the
stand-ins play; it is not a code unit.

### Allowed dependency directions

Code imports only along these directions (rule AR-005). Each code unit is a
Swift target or the Rails application; "may import" lists the other code
units it may import, and nothing else of ours. Platform modules and
libraries are not code units: rule AR-004 covers them. Across components,
the Mac side reaches the API only over HTTP, through LeverageKit, and the
API calls nothing on the Mac side.

The runner and the helper never import each other: the helper starts the
runner as a process. The app imports neither: it reaches the helper only
through the server and by starting its process. The units and their
directions are recorded in [ADR 0005](adr/0005-code-units-of-the-core-loop.md)
and [ADR 0014](adr/0014-the-mcp-server-is-a-swift-program-over-standard-input-and-output.md).

| Code unit | Folder | May import |
|---|---|---|
| `LeverageKit` | `mac/Sources/LeverageKit/` | nothing |
| `LeverageRunner` | `mac/Sources/LeverageRunner/` | `LeverageKit` |
| `LeverageMCP` | `mac/Sources/LeverageMCP/` | `LeverageKit` |
| `LeverageHelper` | `mac/Sources/LeverageHelper/` | `LeverageKit` |
| `LeverageAppServices` | `mac/Sources/LeverageAppServices/` | `LeverageKit` |
| `LeverageApp` | `mac/Sources/LeverageApp/` | `LeverageKit`, `LeverageAppServices` |
| `LeverageTestSupport` | `mac/Tests/LeverageTestSupport/` | `LeverageKit` |
| `LeverageKitTests` | `mac/Tests/LeverageKitTests/` | `LeverageKit`, `LeverageTestSupport` |
| `LeverageRunnerTests` | `mac/Tests/LeverageRunnerTests/` | `LeverageKit`, `LeverageRunner`, `LeverageTestSupport` |
| `LeverageMCPTests` | `mac/Tests/LeverageMCPTests/` | `LeverageKit`, `LeverageMCP`, `LeverageTestSupport` |
| `LeverageHelperTests` | `mac/Tests/LeverageHelperTests/` | `LeverageKit`, `LeverageHelper`, `LeverageTestSupport` |
| `LeverageAppServicesTests` | `mac/Tests/LeverageAppServicesTests/` | `LeverageKit`, `LeverageAppServices`, `LeverageTestSupport` |
| `LeverageAppTests` | `mac/Tests/LeverageAppTests/` | `LeverageKit`, `LeverageApp`, `LeverageTestSupport` |
| `LeverageEndToEndTests` | `mac/Tests/LeverageEndToEndTests/` | `LeverageKit`, `LeverageTestSupport` |
| `api` | `api/` | nothing |

`python3 scripts/check_imports.py` checks the code against this table.

## Cross-cutting mechanisms

Each concern has one mechanism on each side (rule AR-006). "None yet" means
the first change that needs one chooses it and adds it here.

| Concern | API (`api/`) | Mac side (`mac/`) |
|---|---|---|
| Errors | `ApplicationController` answers every error with the contract's transport error body, `{"error":{"code","message"}}`, and one of five codes: `400 malformed`, `401 unauthenticated`, `404 not_found`, `422 invalid` or `key_reused`; errors raised before a controller runs go through `ApplicationController.exceptions_app`, and `JsonBodiesOnly` (`api/lib/middleware/`) answers a body not sent as JSON in the same shape. A 5xx answer hides the message, which is logged. A command that is refused is not an error: it answers `409` with the outcome body. | `LeverageClientError` in LeverageKit for what the clients raise (a transport error with its code, a refusal, an unexpected status or body); a network failure passes through as the `URLError` that `URLSession` threw. |
| Logging | `Rails.logger`; in production to standard output, tagged with the request ID. Each command adds one line, `leverage.command`, with the command, the caller, the key, the outcome, the refusal code, four timings (the lock wait, the event and step writes, the whole transition and the time in `Transitions::Gate`) and the rule a `blocked_by_rule` refusal names (`Leverage::CommandLog`); never a header, a body or a rule's reason. A logged parameter keeps its key, and its value only when the value is an id, a number or true or false: every other text, task text and a rule's words among it, is `[FILTERED]`, and so is anything shaped like a token. | `Log` in LeverageKit: one line per message to standard error, `<UTC time> <component> <level>: <message>`, after `Redaction` removes tokens (keeping their prefix), bearer values and email addresses. The app sends the helper's output to `<support folder>/logs/helper.log`, and the helper each run's to `logs/seat-<id>.log`; each is replaced once it passes 5 MB. |
| Configuration | Environment variables, set from `.env` through `compose.yaml` and read under `api/config/`; the backup's are `BACKUP_DIR`, `BACKUP_KEEP` and `BACKUP_EVERY_HOURS`, and the host folder is `LEVERAGE_BACKUP_DIR`. | The process environment, every name in `EnvironmentKeys` in LeverageKit (`LEVERAGE_API_URL` and the rest, among them the run's `LEVERAGE_CREDENTIAL_ID`, `LEVERAGE_CONTINUE_TASK_ID` and `LEVERAGE_CONTINUE_REVIEW_ID`, the app's `LEVERAGE_NOTIFICATIONS`, and `LEVERAGE_EVAL` and `LEVERAGE_EVAL_REAL`, read only by `LeverageRunner eval` and `scripts/eval_rule.sh`; [DEPLOY.md](DEPLOY.md) lists them). The helper also reads `LEVERAGE_TOKEN_STORE`, `LEVERAGE_PROVIDER_API_BASE` and `LEVERAGE_READ_TIMEOUT_SECONDS`. The bundle's image tag is the `Info.plist` key `LeverageAPIImageTag`. |
| Persistence | Active Record on PostgreSQL; the record of each backup is the `backup_runs` table. | `KeychainSessionStore` keeps the owner's session. The bundled helper uses `KeychainTokenVault` for one item per verified API token. Development and smoke helpers use the memory vault. External MCP client settings may contain a self-connected seat's token. [ADR 0017](adr/0017-api-tokens-the-keychain-and-the-local-channel.md) |
| Notifications | None. | `Notifying` in LeverageKit's `AppRuntime`; the real one is `UserNotifier` in LeverageAppServices, on the platform's `UserNotifications`, made only by `UserNotifier.make(bundleURL:environment:)` and only for a `.app` bundle with `LEVERAGE_NOTIFICATIONS` not `off`; everywhere else, tests included, the form that posts nothing. `InboxWatcher` in LeverageApp is its one caller. |
| Backups | `Leverage::Backup` (`api/lib/leverage/backup.rb`), run by `api/bin/backup` in the `backup` service and by `api/bin/restore` ([ADR 0010](adr/0010-daily-backup-and-restore.md)). | None: the app only makes the folder (`ServerFiles`). |
| How a run ends for a reason | `report_limit` and `report_signed_out` (`report_job_limit` and `report_job_signed_out` for a job's run) through the transition function; `Leverage::Handoff` decides what follows. | The provider's detector and `SignInStatus` in LeverageKit, asked by the runner's `Interruption`; exit code 5 with one `RunEndReport` line on standard output; the helper's `InterruptionReporter` sends the report ([ADR 0008](adr/0008-how-a-run-moves-to-another-account.md)). |
| Child processes | None. | `Subprocess` in LeverageKit uses an absolute program path, an allow-listed environment, its own process group, drained outputs and a time limit or stop that ends the group. Standard input defaults to `/dev/null`. The session form keeps input open for the helper channel and Codex app-server. `ProviderCatalog.toolEnvironment` builds the tool environment and `HelperSupervisor` builds the helper's environment. Docker gets only `HOME` and `PATH`. |
| Requests to a provider's API | None. | The helper's `ProviderHTTP` uses an ephemeral `URLSession` for a single bounded GET and returns only the catalog's allowed response headers. The Leverage API's `HTTPTransport` uses separate authentication and exposes no headers. |
| App to helper | Helper work is queued through the owner interface. | `HelperSupervisor` starts and stops the helper and sends the two messages in [Interfaces](#interfaces) on standard input. The support folder holds the pending cleanup queue described in [ADR 0017](adr/0017-api-tokens-the-keychain-and-the-local-channel.md). |
| Shared helpers | `Leverage::Contract` (`api/lib/leverage/contract.rb`) reads `api/contract/` and validates a payload against its schema with `json_schemer`. | LeverageKit. |

The helper's environment includes the API address, its own token, the
support folder and the allowed launch settings, including
`LEVERAGE_TOKEN_STORE`. A runner gets its seat token, the run's inputs,
`HOME`, `TMPDIR`, `LANG`, `USER` and `PATH=/usr/bin:/bin`. A provider's
tool gets `PATH`, `HOME`, `TMPDIR`, `LANG`, its account folder variable,
and `USER` for Claude.

## Data

- **Where.** PostgreSQL, in the `db` container, is the only store of the
  workspace. The PRD's [Data model](PRD.md#data-model) is the requirement;
  `api/db/structure.sql` is the schema, built by the migrations in
  `api/db/migrate/`. It has the 27 tables the Data model names plus
  `sessions`, `helper_requests` and `briefing_acknowledgements` (owner
  sign-in, the helper's requests and briefing acknowledgements), 30 in all,
  and each but `workspaces` and `backup_runs` has a `workspace_id` with a
  foreign key (a dump is of the whole database). The Core loop added
  `helper_requests.params` and `helper_requests.progress` (the non-secret
  inputs of a request, and per-check progress) and `seats.wanted_running`.
  The Handoff milestone added `backup_runs`, `credentials.limited_since`
  (a limit was reported; `limited_until` is set only with it),
  `seats.run_credential_id` (the account the seat's current run is on) and
  `seats.run_stop_reason`. The Rule checks milestone added
  `pending_transitions.params` and `jobs.attempt_number` and no table: the
  rules live in `rules` and `rule_versions`, a check in `rule_checks` with
  one `rule_check_attempts` row per attempt and one `jobs` row per model
  attempt, and a waiting command in `pending_transitions`.
  `pending_transitions.params` is the request the command will complete
  with; it is task text, a check refuses it unless the transition is
  `pending`, and the transition empties it when it completes, is refused
  or is cancelled. CI migrates from zero, with `structure.sql` moved
  away so the migrations run, and fails when the result differs from the
  committed file. From the Core loop on, migrations only go forward.
- **Who writes.** Every change goes through `Leverage::Transitions`; the
  sweep also writes its own `sweep_runs` rows. Only `Leverage::EventLog`
  inserts into `events`, no controller or read writes, and no file under
  `api/lib/leverage/rules/` calls a writing Active Record method; a static
  test holds all three. The schema itself refuses what the PRD forbids:
  - `events` and `rule_versions` are append-only: a trigger refuses
    `UPDATE`, `DELETE` and `TRUNCATE` for every role. The server and the
    sweep log in as `leverage_api`, a member of `leverage_app`, which has
    no right to change either even with a trigger switched off
    ([ADR 0007](adr/0007-sweep-service-and-database-login-role.md)).
  - A task's state changes only in a transaction that writes an event for
    that task in its workspace: two deferred constraint triggers on
    `tasks` check at commit for an `events` row whose `xact_id` (set by
    default to `pg_current_xact_id()`) is the transaction's own.
  - `rule_checks (rule_id, rule_version_id)` and `rules (id,
    current_version)` are composite foreign keys, so a check's version and
    a rule's current version belong to that rule.
  - A seat reviews at most one review at a time: the unique index on
    `reviews.reviewer_seat_id` counts only reviews with no verdict.
  - The `leverage_app` role (`NOLOGIN`, kept by the `db:grants` task after
    every task that builds or changes the schema) has `SELECT, INSERT` on
    `events` and `rule_versions`, `SELECT` only on `backup_runs`, `SELECT,
    INSERT, UPDATE, DELETE` on every other table, and no `TRUNCATE`.
    Migrations, tests, the backup, the restore and other commands use the
    database's owner role. Runs of `db:grants` go one at a time across the
    cluster, under an advisory lock taken in the `postgres` database, since
    two at once fail with "tuple concurrently updated".
- **What is never stored.** No column holds a token or a password in the
  clear: the only such names are `token_hash` (`sessions`, `helpers`,
  `seats`, a SHA-256 hex digest) and `users.password_digest` (bcrypt). A
  check constraint refuses any key named `token` or ending in `_token`, in
  any letter case and at any depth, in `commands.result`,
  `commands.refusal`, `helper_requests.result`, `helper_requests.params`
  and `helper_requests.progress`; the last two also refuse a key named
  `name`. A count named `tokens` is allowed. A credential is a row with a
  name, a kind and a state; no login, sign-in token, settings folder or
  keychain reference has a column.
- **How long.** The sweep deletes `commands` rows (the idempotency keys and
  stored outcomes) and `sweep_runs` rows older than 7 days. Delete content clears the applicable content columns while keeping
  the event log and timing records.
- **Credential readings.** The server keeps typed figures, resets,
  observation time, state and tool version in `credential_readings`.
  The Credentials snapshot shows the newest observed reading per added
  credential. Removing a credential deletes its readings. The sweep
  deletes finished and failed `read_usage` requests after seven days.
  Plan and account email are kept in their credential row.
- **Backups.** The `backup` service dumps the whole database once a day
  (`pg_dump` custom format) into a folder on the host, outside Docker's
  volumes: the app's `<support folder>/backups`, folder 0700, each file
  0600. It keeps the newest 14 dumps that its `backup_runs` rows name and
  never touches another file. A dump holds personal data (the owner's
  email and password digest, account names, every task's text) and no
  provider secret. `bin/restore` makes the database again from one dump
  and passes only if the replay test passes
  ([ADR 0010](adr/0010-daily-backup-and-restore.md);
  [DEPLOY.md](DEPLOY.md) says how).
- **Values.** Closed values are plain `text` columns, checked by the
  application against `api/contract/registry.json`; there is no PostgreSQL
  enum type. Durations that are settings are integer seconds.
- **On the Mac.** Under the support folder, `~/Library/Application
  Support/leverage` (or `LEVERAGE_SUPPORT_DIR`): `server/` (the compose
  file and the `.env` with the database passwords and `SECRET_KEY_BASE`,
  folder 0700, files 0600), `accounts/<credential id>/` (a Claude or Codex
  login's own settings folder, made new by Add and removed after a failed
  Add or confirmed Remove), `tools/<provider>/` (a tool Leverage unpacked),
  `work/<task id>/` (a task's folder when it names none), `logs/`
  (`helper.log` and one `seat-<id>.log` per run), `backups/` (the daily
  dumps, folder 0700), `inbox-cursor` (mode 0600: one number, the `seq` of
  the last Needs you item the app announced, so that each is announced
  once across restarts) and `app.lock`. A provider's own sign-in lives in
  that folder or, for a provider with one sign-in for the Mac, where the
  tool keeps it. The bundled helper keeps API tokens in the Keychain as
  described in [ADR 0017](adr/0017-api-tokens-the-keychain-and-the-local-channel.md).
- **Reply files.** `mac/Tests/StandIns/replies/` holds 61 test replies.
  Run and status fixtures follow
  [ADR 0009](adr/0009-detectors-from-recorded-and-made-replies.md).
  Usage fixtures contain made-up data and are checked by
  `scripts/check_reply_fixtures.py`. The product keeps the typed reading
  alone. Scrubbed developer captures stay outside the repository.
  [ADR 0018](adr/0018-usage-readers-and-their-tested-versions.md)
- **Eval suites.** [Specific details](../evals/specific-details/README.md)
  and [outward action approvals](../evals/approves-actions/README.md)
  hold made-up cases, numeric bars, run records and per-model results.
  Results record model verdicts or decisions, short reasons, tokens,
  elapsed time and provenance hashes. The scorer keeps no raw tool output.
  [ADR 0013](adr/0013-eval-suites-for-rules-a-model-judges.md)

## Interfaces

`api/contract/` is the definition of every interface between two parts of
Leverage; [its README](../api/contract/README.md) says how each file is
written and read. This section is the pointer AR-002 asks for, and states
the stability rules.

| Interface | Defined in |
| --- | --- |
| The agent, owner and helper HTTP interfaces | `api/contract/openapi.json` (OpenAPI 3.1, tags `agent`, `owner`, `helper`) |
| Which operations are served | `Leverage::Http::RouteTable` (`api/lib/leverage/http/route_table.rb`); `config/routes.rb` draws each from the registry's method and path |
| Events: types and payloads | `api/contract/registry.json` and `api/contract/payloads/<type>.v<n>.json` |
| The fixed lists every part uses | `api/contract/registry.json`; on the Mac side, `mac/Sources/LeverageKit/Generated/Contract.swift`, generated from it |
| States, commands, steps, hooks, jobs, roles, timers, Needs you | `api/contract/*.json`, one file each |
| The transition function and rule gating, in process | `Leverage::Gating` (`api/lib/leverage/gating.rb`) and the conformance suite `api/test/support/gating_conformance.rb` |
| Credential readers | `api/contract/readers.json` |
| Expected behavior, end to end | `api/contract/traces/` (24 golden traces, all run whole) |
| Agent MCP tools | `api/contract/openapi.json`, `api/contract/roles.json` and the session behavior in [ADR 0014](adr/0014-the-mcp-server-is-a-swift-program-over-standard-input-and-output.md) |
| The provider's tool | Its command line, driven by the runner (see [Providers' tools](#providers-tools)) |

`GET /v1/join` is an authenticated seat read that leaves poll-based
presence unchanged. It returns the instructions for the seat's role and
connection, including the polling loop. The short landing prompt is
issued once by the owner command `issue_landing_prompt`. The contract
README records the routes and how they connect.

On standard input, the helper accepts one UTF-8 JSON object per line.
Both `token` (version 2) and `forget` (version 1) of
`LocalHelperMessage` carry `credential_id`. The `token` message also
carries the selected provider and the pasted value. The message decoder
refuses malformed lines and uses a payload-free diagnostic.

- **Commands.** Every call that changes something is a `POST` that carries
  an `Idempotency-Key` header and answers one outcome body: 200 completed,
  202 pending, 409 refused with a code from the registry's `refusals`. A
  repeat of the key writes no events. A stored job claim exposes material
  only while the seat still holds the job in its current role and project.
  Delete content clears stored claim copies of the deleted material.
- **Events** are versioned. A released payload version is never edited: a
  change adds a new version, the server writes the newest, every reader
  handles every listed version, and old events are never rewritten.
- **Lists.** A value of a list the PRD tables changes the PRD first.
  `scripts/check_registry.py` and `scripts/check_contract_tables.py` fail
  in CI when the PRD and the contract differ, and
  `scripts/generate_swift_contract.py --check` when the Swift copy is
  stale.
- **Provisional parts** are marked: owner reads with `x-provisional: true`
  in `openapi.json`, and readers with `provisional: true` in
  `readers.json`. They may change without a new version until they are
  marked final.

## Providers' tools

The runner and the helper drive four login providers' tools from one table,
`ProviderCatalog` in LeverageKit and one driver per provider in
`LeverageRunner`. Each fact carries how far it is proven: `probe` ran on the
owner's Mac on 2026-11-19 under the allow-listed environment; `help` is in
the tool's own `--help`, never run; `documented` is in the vendor's
documentation, never run; `unverified` is none of these. Nothing below
`probe` is called proven.

| Provider (tool) | Account | Status and sign-in | Installer | Reviewer run | Builder run differs by |
| --- | --- | --- | --- | --- | --- |
| Claude (Claude Code, `claude`) | `CLAUDE_CONFIG_DIR` (`probe`); needs `USER` (`probe`) | `claude auth status`, field `loggedIn` (`probe`); `claude auth login` (`help`) | `https://claude.ai/install.sh` with `/bin/bash` (`documented`) | `claude -p <prompt> --output-format json --no-session-persistence --permission-mode dontAsk` (`probe`), with `--strict-mcp-config --setting-sources user` (`help`) | `--permission-mode acceptEdits`, `--model`, `--effort` (`help`) |
| Codex (Codex, `codex`) | `CODEX_HOME` (`probe`) | `codex login status`, signed out when it says "Not logged in" (`probe`); `codex login` (`help`) | `https://chatgpt.com/codex/install.sh` with `/bin/sh` (`documented`) | `codex exec <prompt> --json --sandbox read-only --skip-git-repo-check --ephemeral -C <dir> -o <file>` (`probe`) | `--sandbox workspace-write`, `-m` (`help`); no effort is passed, and Connect asks for none |
| Gemini (Antigravity, `agy`) | One sign-in for the Mac (`help`; the PRD states it) | No status or sign-in command (`help`): the test prompt is repeated | `https://antigravity.google/cli/install.sh` with `/bin/bash` (`documented`) | Not offered: `agy -p <prompt> --output-format json --print-timeout <n>s --mode plan` answered with a plan, not the word asked for (`probe`), so the runner refuses a Gemini reviewer and Connect does not list a Gemini login for one | Builder: the same without `--mode plan`, with `--mode accept-edits`, `--model`, `--effort` (`help`) |
| Grok (Grok Build, `grok`) | Treated as one sign-in for the Mac (`unverified`) | `grok models`, signed out when it says "You are not authenticated." (`probe`); `grok login --oauth` (`help`) | None: no documented source was reachable (`unverified`) | `grok -p <prompt> --cwd <dir> --permission-mode plan` (`help`) | `--permission-mode acceptEdits`, `-m` (`help`); no effort is passed, and Connect asks for none |

An orchestrator's rule check and a planner's draft run each tool in its
check mode, the answering check the helper's test prompt uses, in a new
empty folder ([ADR 0012](adr/0012-how-task-text-reaches-a-checker.md)).
The model and effort are passed only when the seat sets them. Claude's,
Codex's and Antigravity's check runs ran on the owner's Mac on 2026-11-20,
in the eval suite's run and the real checks through the server, at each
tool's default model (`probe`); Grok's has never run.

| Provider | Check run | Evidence |
| --- | --- | --- |
| Claude | `claude -p <prompt> --output-format json --no-session-persistence --permission-mode dontAsk --strict-mcp-config --setting-sources user --tools ""` | `probe` |
| Codex | `codex exec <prompt> --json --sandbox read-only --skip-git-repo-check --ephemeral -C <empty folder> -o <file>` | `probe` |
| Gemini | `agy -p <prompt> --output-format json --print-timeout <n>s`, never `--mode plan` | `probe` |
| Grok | `grok -p <prompt> --cwd <empty folder>` | `help` |

The managing agent ran Claude Code 2.1.325 as a builder over MCP with
`--mcp-config <file> --strict-mcp-config --allowedTools mcp__leverage`
(`probe`). The client asked for protocol revision 2025-11-25, and the
task reached Done with a stand-in reviewer.

A job's run also passes the seat's model and effort when the seat sets
them (`--model` and `--effort` for Claude and Antigravity, `-m` for Codex
and Grok), at the `help` level: every check that has run so far ran with
no model set, so these flags have never run in check mode. A prompt over
512 KiB is not started, because a tool gets its prompt as one argument and
the Mac starts no program whose arguments pass 1 MiB. The runner then
starts no tool, logs the reason and sends no result, so a check ends in
`error` after its two run timeouts, and a draft is dropped after its
second. The server's length limits on task text make that rare, not
impossible: they count characters, not bytes, and not the evidence rows a
task gathers, so a large enough task, with many evidence rows or text in
multibyte characters, still makes its checks end in `error`.

The test prompt of Claude, Codex and Antigravity answered "ready" under the
allow-listed environment (`probe`); Grok was signed out, so no prompt ran.
No installer and no sign-in command has been run by an agent. The runner
closes the tool's standard input, runs it in the task's folder (a job's
run in its empty folder) under a time limit, and passes no flag that
skips permissions or sandboxing.
An installer is downloaded only over HTTPS from a host its catalog entry
lists.

How a limit and a sign-out are recognised in each tool's failed run is
[ADR 0009](adr/0009-detectors-from-recorded-and-made-replies.md). Every
limit reply the detectors are written to is made, not observed; which
replies are recorded and which are made, per provider, is in
[IMPLEMENTATION.md](IMPLEMENTATION.md#what-the-handoff-milestone-proves-and-how-far). Sign in
again uses each tool's own sign-in, as Add credential does. Add credential
sets a login's model to the one its tool names as its default where it
names one (Claude `claude-opus-5-5` and Grok `grok-4.6`, each seen in a
run with the agent's whole environment, not the allow-list), and leaves it
empty for Codex and Antigravity, which name none; empty means the tool's
own default.

### Usage readers

The catalog distinguishes tool help, vendor documentation, generated
protocol schema, a recorded developer probe and facts stated in the PRD.
All nine contract entries remain provisional.

| Provider | Source and evidence | Shipped reader |
| --- | --- | --- |
| Claude login | Step 0 recorded the Claude Code 2.1.325 usage envelope without a model turn. Quota grammar was unavailable. The reset cache has made-up settings fixtures only. | Unavailable. Refresh cannot select the provisional reader. |
| Codex login | `codex app-server` over JSON lines. Generated protocol schema and one Step 0 session for CLI 0.169.0. | 0.169.0. Five-hour and weekly limits, usage summary when present, and eligible reset credits. |
| Gemini login | Antigravity usage screen in the PRD, and a terminal-free 1.5.13 probe without prompt tokens. | Unavailable. |
| Grok login | `grok usage --json` from tool help. | Unavailable. |
| OpenRouter token | Catalog GET, documentation and made replies. | Spending-use percentage, amount left and period usage when supplied. |
| Claude API token | Catalog GET, documentation and made replies. | Requests remaining when the named header is present. |
| OpenAI API token | Catalog GET, documentation and made replies. | Requests remaining when the named header is present. |
| Gemini API token | Catalog GET, documentation and made replies. | Reading state. |
| Grok API token | Catalog GET, documentation and made replies. | Reading state. |

The workspace sweep queues up to 50 due reads for active credentials
whose readings were stored more than nine minutes ago or are missing.
It requires a helper report in the last 90 seconds. A passed Add queues
the first read. Refresh queues an active
credential even if it has a recent reading. Refresh and the sweep end
abandoned pickups after 90 seconds, so a lost pickup can be retried.
The helper budgets 15 seconds for a read. The Codex usage session runs
in an empty temporary working directory. It stops and reaps the child
after collecting the required replies. Existing version and sign-in
preflights keep their usual working directory.
[ADR 0018](adr/0018-usage-readers-and-their-tested-versions.md)

## Trust boundaries

The Core loop is the first code that crosses the line between the Mac and
the server. Security review starts here; see [SECURITY.md](../SECURITY.md).

- **Network.** `compose.yaml` publishes the API on `127.0.0.1` only, and
  every Mac-side program calls it over plain HTTP. Nothing else on the
  network can reach it. In production the API answers only a request
  addressed to `127.0.0.1`, `localhost`, `[::1]` or `api`
  (`config.hosts`), so a web page in the owner's browser that rebinds its
  own name to the loopback address is refused `403`. Before the server leaves the Mac the transport
  must become HTTPS ([ADR 0006](adr/0006-owner-sign-in-and-tokens.md));
  `Configuration` already accepts an `https` address.
- **Callers and their tokens.** Three callers reach the server, each with
  its own bearer token (`lvo_` owner session, `lvh_` helper, `lvs_` seat):
  32 random bytes, shown once, stored only as a SHA-256 digest.
  `x-leverage-caller` on each operation and `roles.json` say which caller
  may run it, and a token of another kind answers `401`.
  - The owner's session is made by sign-in or setup, kept in the owner's
    login Keychain, and ended by sign-out. It has no expiry.
  - The helper's token is made by the app's `issue_helper_token` each time
    the app starts the helper, lives only in the helper's environment, and
    ends when the next one is issued.
  - A seat's token is made by the helper's seat-token pickup for a seat
    the app runs, and lives only in its runner's environment; it ends at
    the next pickup, when the run is reported stopped, and when the seat is
    removed. A seat that connects on its own receives its token only in
    the landing prompt, when Connect or New prompt issues one. Remove and
    New prompt end the old token. The prompt's agent stops at its next
    `401`. An MCP client starts `LeverageMCP` using the seat token from
    the client's settings as `LEVERAGE_SEAT_TOKEN` in the child
    environment. The MCP server uses
    the token for API authentication and never logs it. The settings
    that start the child may hold the token. The app and runner do not
    store it there. [ADR 0014](adr/0014-the-mcp-server-is-a-swift-program-over-standard-input-and-output.md)
- **The setup call.** `POST /v1/owner/setup` needs no token and creates the
  one owner. It answers `404` once an owner exists; until then any program
  on the Mac that can reach the loopback address could call it.
- **Untrusted input.** Everything a seat sends (contract text, notes,
  evidence), every helper report and everything a provider's tool prints
  is untrusted. Of a tool's output the runner reads only its marker lines,
  and quoted material in a prompt has its marker words neutralised. A link
  in evidence or a work reference is shown as plain text and never
  fetched. An event payload holds only ids, numbers, digests and values
  from closed lists, never free text; the one exception is `model`, a
  model name of at most 128 characters from a fixed character set with no
  `@`. An installer's address must be HTTPS on a host its catalog entry
  lists, also after a redirect.
- **Task text reaches a checker only as material**
  ([ADR 0012](adr/0012-how-task-text-reaches-a-checker.md)). In a rule
  check, draft, question or approval prompt every piece of task text, the contract
  included, is inside a block marked with a nonce made for that run, with
  every marker in the text broken (no run of `<` longer than two, and no
  `LEVERAGE` followed by a hyphen or a dash that looks like one), and the
  verdict is read only from lines that carry the nonce; anything
  else the tool prints is dropped unlogged. A rule's instruction is the owner's
  text and stands outside the blocks, as the checker's instruction. A
  checker's run starts in a new empty folder, which is not a wall. What a
  checker's run can reach if an instruction in task text got past the
  frame differs by provider. ADR 0012, decision 4, records the reach of
  each provider's check mode. The same table applies to the run that
  decides an outward action approval.

  A checker's reason is at most 500 characters, stays in its row, and
  reaches a builder's tool only as quoted material. A refused command's
  log line holds its code and the rule's id, never the reason.
- **A tool's output never leaves the runner.** A detector is given a
  failed run's exit status and outputs in memory only (`ToolRunRecord`,
  whose description shows sizes, never text) and gives back a kind; only
  the kind, the window and a stated reset time reach the helper, in the
  `RunEndReport` line, and the logs say only the kind. A status command
  prints the account's email, organisation and plan, so `SignInStatus`
  reads its one signed-in field and keeps, logs and returns nothing else;
  it answers signed out only on the tool's own signed-out reply. Grok's
  standard output is the agent's answer and is never read for a limit or a
  sign-out, nor is any run a signal killed.
- **Provider API tokens.** The secure field sends the pasted value to the
  helper over standard input. The Rails Add request carries the fixed
  mask. The helper checks the value at the locally selected catalog
  endpoint and saves the provider with the value after a pass. Verify and
  usage use that provider binding. Check and usage calls send
  authentication in a header. The sender refuses redirects, limits the
  body to 1 MiB, uses no cookies or cache, and gives the reader only
  named headers.
  The loopback test override is refused by a bundled helper and accepts
  only a marked made-up token. The app's helper environment omits the
  override. [ADR 0017](adr/0017-api-tokens-the-keychain-and-the-local-channel.md)
- **Usage and account facts.** Readers treat replies as bounded, untrusted
  input and keep no raw reply. The Codex session checks the account home
  during initialization. Its request methods are `initialize`,
  `account/read` with refresh disabled, `account/rateLimits/read` and
  `account/usage/read`. Claude and Codex account facts supply plan and
  email on Add and Verify. The API keeps each in the credential row and
  filters both from request logs. The provisional Claude cache reads one
  entry from a regular `.claude.json` under the account folder, keeps its
  fetch time and reset value in memory, and retains no file contents.
  The API checks reading identity, time, schema and field bounds.
- **The helper's reports are checked against what the seat holds.** A
  limit or sign-out report must name a credential that is an added login,
  a seat with a credential, and exactly one task, review or job; it is refused
  when the seat does not hold that work, or when the credential is not the
  one recorded for it. A refused report marks no credential and writes no
  event.
- **Reply files are scrubbed and checked.** A recorded reply keeps the
  tool's wording and loses its session ids, request ids, account folders
  and the like; `scripts/check_reply_fixtures.py` refuses an email, a token
  prefix, a real id or a named field with a real value, and the
  end-to-end secret scan fails if a reply's marker or long line is found
  outside the stand-ins' folder.
- **Secrets.** A provider login, sign-in token, link, code or API token
  stays out of the Leverage API, stored outcomes, events and logs.
  The reference runner's
  allow-listed tool environment excludes every Leverage token. A tool
  acting as an external MCP client needs access to the seat token via
  its settings, to pass it to the MCP process as described above. The helper's
  requests carry only non-secret inputs (`params`). The landing prompt
  contains the seat's token, so the API returns both only in the one-time
  response and keeps only the token's digest. A request body sent in any
  format other than JSON is answered `400` before Rails reads it, for any
  method and path (`JsonBodiesOnly`). A sign-in sent as a form, even to a
  mistyped path, never reaches the request log. The end-to-end runs scan the
  containers' logs, the helper's and runs' logs and a dump of the database
  for every secret they used and anything shaped like a token
  (`scripts/secret_scan.py`); the rule-check run also looks for any
  nonce-shaped marker in a log and for each test's marker words, written
  into its task text, rule, override reason and checker's reason, in the
  event payloads and the logs.
- **Privilege changes.** The owner's commands, the seats' calls and the
  helper's calls are separate operations with separate schemes. In the
  database, migrations run as the owner role, and the server and the sweep
  log in as `leverage_api`, which cannot change the event log; every table
  but `workspaces` and `backup_runs` is scoped by `workspace_id`. The
  `backup` service connects as the owner role, which every container of
  the image already holds, and gives the password to `pg_dump` and
  `pg_restore` in their environment, never in an argument. The server
  folder's `.env` holds the database passwords and `SECRET_KEY_BASE`,
  readable only by the owner's Mac account.
- **Backups hold personal data.** A dump holds the owner's email and
  password digest, account names and every task's text, and no provider
  secret. The folder is mode 0700 and each dump 0600 on the Mac; it is not
  copied off the Mac.
- **What is not protected.** Agents run as the owner's own Mac account
  (PRD, Risks): a provider's tool can read whatever that account can, and
  Leverage gates only what goes through it. A seat that connects on its
  own is whatever program holds its token. For Codex, Gemini and Grok the
  quote frame is the only wall between task text and a checker's reach
  (the table above).

## Technology choices

Each choice is recorded in the ADR named beside it.

| Part | Choice | Decided in |
| --- | --- | --- |
| Backend | Ruby on Rails, API mode, in `api/` | [ADR 0001](adr/0001-rails-api-postgresql-and-a-mac-client.md) |
| Datastore | PostgreSQL | [ADR 0001](adr/0001-rails-api-postgresql-and-a-mac-client.md) |
| Hosting | A server the owner controls, one installation per owner; for the first run, the owner's Mac | [ADR 0001](adr/0001-rails-api-postgresql-and-a-mac-client.md) |
| Docker containers | The backend ships as a container image; the backend and PostgreSQL run in Docker containers | [ADR 0001](adr/0001-rails-api-postgresql-and-a-mac-client.md) |
| Owner's interface | A native Mac app in Swift with SwiftUI, a thin client of the API, in `mac/` | [ADR 0001](adr/0001-rails-api-postgresql-and-a-mac-client.md) |
| Mac helper | Runs the providers' tools on the owner's Mac; written in Swift, in `mac/` | [ADR 0001](adr/0001-rails-api-postgresql-and-a-mac-client.md) |
| Ruby and Rails | Ruby 4.0.10 (image `ruby:4.0.10-slim`), Rails 8.1.4.1; gem versions fixed in `api/Gemfile.lock` | [ADR 0002](adr/0002-pinned-versions-test-tools-and-code-units.md) |
| PostgreSQL version | 17.12 (image `postgres:17.12-trixie`) | [ADR 0002](adr/0002-pinned-versions-test-tools-and-code-units.md) |
| API checks | Minitest, RuboCop (`rubocop-rails-omakase`); no security scanner (question 6 in [IMPLEMENTATION.md](IMPLEMENTATION.md#questions-for-the-owner)) | [ADR 0002](adr/0002-pinned-versions-test-tools-and-code-units.md) |
| Swift | Swift tools version 6.2, macOS 14 or later, no third-party packages | [ADR 0002](adr/0002-pinned-versions-test-tools-and-code-units.md) |
| Swift tests | Swift Testing | [ADR 0002](adr/0002-pinned-versions-test-tools-and-code-units.md) |
| Continuous integration | GitHub Actions: `ubuntu-24.04` for the API, the import check and the `e2e` job (the whole loop, with the helper and the runner built for Linux), `macos-26` for Swift and the app bundle | [ADR 0002](adr/0002-pinned-versions-test-tools-and-code-units.md), [ADR 0005](adr/0005-code-units-of-the-core-loop.md) |
| Code units | `api`, and the Swift units `LeverageKit`, `LeverageRunner`, `LeverageHelper`, `LeverageAppServices`, `LeverageApp`, with their test units, under [Components](#allowed-dependency-directions); build subsets by `LEVERAGE_ONLY` | [ADR 0005](adr/0005-code-units-of-the-core-loop.md) |
| The contract | JSON data files with JSON Schema 2020-12, OpenAPI 3.1, `structure.sql`, the `leverage_app` role, `json_schemer` 2.5.0 | [ADR 0003](adr/0003-contract-format.md) |
| Packaging | One app bundle built on the owner's Mac, ad-hoc signed, that starts the server through Docker Desktop and the helper as its child | [ADR 0004](adr/0004-one-app-bundle-for-the-first-run.md) |
| Owner sign-in and tokens | `bcrypt` 3.1.22 for the password; opaque prefixed tokens stored as SHA-256; plain HTTP on loopback | [ADR 0006](adr/0006-owner-sign-in-and-tokens.md) |
| Timers and the database login | A `sweep` service from the API's image, no job runner; long polls by looking again; the server and the sweep log in as `leverage_api` | [ADR 0007](adr/0007-sweep-service-and-database-login-role.md) |
| Handoff between accounts | A run on one account for its whole life; the server asks the helper for a run on the account the work is recorded on; the runner tells the helper by exit code 5 and one line | [ADR 0008](adr/0008-how-a-run-moves-to-another-account.md) |
| Limit and sign-out detection | One detector per provider in LeverageKit, written to recorded and made reply files kept under `mac/Tests/StandIns/replies/` | [ADR 0009](adr/0009-detectors-from-recorded-and-made-replies.md) |
| Backups | A `backup` service from the API's image: `pg_dump` once a day to a folder on the host, `bin/restore` with the replay test; no new dependency | [ADR 0010](adr/0010-daily-backup-and-restore.md) |
| Notifications | The platform's `UserNotifications`, a module of macOS, not a dependency to pin | No ADR: nothing is chosen beyond the platform the Mac app already targets |
| Rule gating | The engine reads and decides; `Transitions::Gate` and four writers write; a waiting command is stored whole and finished by its own entry as its requester; no new dependency | [ADR 0011](adr/0011-gating-reads-and-the-transition-function-writes.md) |
| Model checks | An orchestrator agent runs each check as a job with the provider's tool in its check mode, task text in nonce-marked quote blocks, in an empty folder | [ADR 0012](adr/0012-how-task-text-reaches-a-checker.md) |
| Eval suites | A folder per suite. CI scores the committed runs without using a provider | [ADR 0013](adr/0013-eval-suites-for-rules-a-model-judges.md) |
| MCP server | Swift executable over standard input and output, using the shared HTTP transport and generated agent tool schemas | [ADR 0014](adr/0014-the-mcp-server-is-a-swift-program-over-standard-input-and-output.md) |
| Provider API tokens | The platform's Security framework and the helper's local channel. The five provider services are catalog endpoints. | [ADR 0017](adr/0017-api-tokens-the-keychain-and-the-local-channel.md) |
| Usage readers | Bounded parsers in the helper. Login usage requires a recorded, exact tool version. | [ADR 0018](adr/0018-usage-readers-and-their-tested-versions.md) |
| Finishing | A shared settlement path for action decisions and one scan for delayed leases | [ADR 0015](adr/0015-one-method-decides-what-a-finishing-task-does-next.md) |
| Overturn after action completion | A durable event on the action | [ADR 0016](adr/0016-an-overturned-approval-that-changes-nothing-is-an-event.md) |

## Architecture decision records

Significant, hard-to-reverse decisions are recorded as short ADRs in
`docs/adr/`, one file each, numbered upward from `0001`
(`0001-short-title.md`). The folder holds nothing else. Rule AR-003 says when
an ADR is required, and "How the rules are applied" says when one records an
agreed deviation from a rule. Each ADR follows this outline and stays short:

```markdown
# 0001. Short title

Status: Accepted

## Context

## Decision

## Alternatives considered

## Consequences
```

The status is one of `Proposed`, `Accepted`, `Rejected`, `Deprecated`, or
`Superseded by 0002` (the number of the ADR that replaces it). Only an
accepted ADR is binding, and the maintainer accepts one by merging the pull
request that gives it that status. `Deprecated` marks a decision that no
longer applies and has no successor. Once an ADR is accepted its decision is
not rewritten: only its status line changes, apart from repairs such as a
broken link, and a later ADR supersedes it. If two open pull requests take
the same number, the second to merge takes the next one.

Recorded so far:

- [0001. Rails API with PostgreSQL, a Mac client and a Mac helper](adr/0001-rails-api-postgresql-and-a-mac-client.md)
- [0002. Pinned versions, test tools and code units of the skeleton](adr/0002-pinned-versions-test-tools-and-code-units.md)
- [0003. The contract's format](adr/0003-contract-format.md)
- [0004. One app bundle for the first run](adr/0004-one-app-bundle-for-the-first-run.md)
- [0005. Code units of the core loop](adr/0005-code-units-of-the-core-loop.md)
- [0006. Owner sign-in and tokens](adr/0006-owner-sign-in-and-tokens.md)
- [0007. The sweep service and the database login role](adr/0007-sweep-service-and-database-login-role.md)
- [0008. How a run moves to another account](adr/0008-how-a-run-moves-to-another-account.md)
- [0009. Detectors from recorded and made replies](adr/0009-detectors-from-recorded-and-made-replies.md)
- [0010. Daily backup and restore](adr/0010-daily-backup-and-restore.md)
- [0011. Gating reads and the transition function writes](adr/0011-gating-reads-and-the-transition-function-writes.md)
- [0012. How task text reaches a checker](adr/0012-how-task-text-reaches-a-checker.md)
- [0013. Eval suites for rules a model judges](adr/0013-eval-suites-for-rules-a-model-judges.md)
- [0014. The MCP server is a Swift program over standard input and output](adr/0014-the-mcp-server-is-a-swift-program-over-standard-input-and-output.md)
- [0015. One method decides what a Finishing task does next](adr/0015-one-method-decides-what-a-finishing-task-does-next.md)
- [0016. An overturned approval that changes nothing is an event](adr/0016-an-overturned-approval-that-changes-nothing-is-an-event.md)
