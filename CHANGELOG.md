# Changelog

All notable changes to leverage are recorded in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project will follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
once it makes its first release.

## [Unreleased]

### Added

- Added handoff: work continues on the next account when one reaches its
  limit or is signed out, Needs you with notifications, the Handoff tab,
  pausing and editing tasks and agents, and a daily backup. The PRD's
  Handoff milestone: the reference runner recognises a limit or a sign-out
  in a provider tool's failed run, the helper reports it, and the server
  continues the task or review on the next account in the Handoff order,
  or holds the task until an account is available or the owner signs in
  again; the record names the account of every claim, review and switch,
  and each interruption's recovery time is in the task's log. Needs you
  lists what waits for the owner, with Sign in again, and the Mac app
  announces each item once in a macOS notification. The Handoff tab shows
  the order and its eight fixed rules. The owner can save a task as an
  idea and move it to Backlog, change a task's contract, pause and continue
  a task, and pause, resume and change an agent. A `backup` container dumps
  the database once a day to a folder on the Mac and keeps 14 (none while
  the database holds no workspace), and `bin/restore` makes the database
  again beside the old one and replaces it only once the restored log
  passes the replay test. Every
  interruption is shown with stand-in tools only, and the limit replies
  they play are made, not observed. The PRD gains the changes R-1 to R-10;
  the choices are recorded in ADRs 0008 to 0010.
- Added the core loop: sign-in, logins, agents the app runs, tasks from a
  form to Done. The PRD's Core loop milestone: `Leverage.app` starts the
  server and its timer sweep in Docker containers on the owner's Mac,
  creates the owner's sign-in, adds and verifies logins through the helper
  (installing a provider's tool where leverage can), connects a builder and
  a reviewer, which the helper runs with the reference runner on those
  logins, and takes a task from the Add task form through review to Done,
  with every step in the event log and on the task page. A seat that
  connects on its own gets its token once and a landing prompt to paste
  into it. Every change goes through one transition function with
  idempotency keys, leases and timers. The PRD gains the changes Q-1 to
  Q-15; the choices are recorded in ADRs 0004 to 0007.
- The contract, the PRD's Contract milestone: `api/contract/` holds the
  fixed lists and event payload schemas, the state, step, hook, job, role,
  timer and Needs you tables, the shipped rules, the credential readers,
  the agent, owner and helper interfaces in OpenAPI 3.1, and eight golden
  traces; `api/db/` holds the migrations for every table of the Data model,
  with an append-only event log and a task state that changes only with an
  event; `Leverage::Gating` is the gating interface, with a stand-in and a
  conformance suite, including the re-entry of an outward action's gates.
  Two checks compare the PRD's tables with the contract in CI. The PRD gains the eleven changes the contract needed. The format
  is recorded in `docs/adr/0003-contract-format.md`.
- The skeleton of the build: a Rails API in `api/` that answers
  `GET /v1/health` and turns every unhandled error into one JSON shape; a Swift
  package in `mac/` with the library LeverageKit, the helper
  LeverageHelper and a one-window Mac app; `compose.yaml` to run the API and
  PostgreSQL in Docker containers on the owner's Mac; and a CI workflow that
  runs both test suites, RuboCop and the import check. The pinned
  versions and test tools are recorded in
  `docs/adr/0002-pinned-versions-test-tools-and-code-units.md`.
- Architecture rules AR-005, AR-006 and AR-007 are active: the components
  and their allowed dependency directions with an import check
  (`scripts/check_imports.py`), one mechanism per cross-cutting concern, and
  a check that a change to product source comes with a test.
- `docs/DEPLOY.md` describes how to configure, start, check and stop the
  skeleton on the owner's Mac.

- Repository scaffolding: README, MIT license, AUTHORS, contribution guide,
  code of conduct, security policy, and issue and pull request templates.
- Product requirements document structure in `docs/PRD.md` (requirements to
  follow).
- The PRD settles the gate before the contract: the owner's decisions on
  the stack, logins, handoff and notifications, 32 of the review's 89
  findings, the interrupted run as a release criterion, and a reordered
  build with handoff as its own milestone.
- Architecture and deployment document structure in `docs/`.
- `AGENTS.md` with instructions for AI coding agents.
- A progress file for the build (`docs/IMPLEMENTATION.md`), engineering
  practices in the architecture document with test-driven development first,
  and a rule in `CONTRIBUTING.md` for a run the maintainer delegates to an
  agent.
- The design reference: a working mockup of the app with a left pane, a
  project list, a Handoff tab and an app icon (`docs/design/`).
- `MAINTENANCE.md`: what to expect from the maintainer, and the project's
  scope limits.
- An AI-assisted contributions policy in `CONTRIBUTING.md`, a matching
  disclosure section in the pull request template, and a rule for AI-assisted
  vulnerability reports in `SECURITY.md`.
- Automated checks on every pull request: Markdown lint, internal links, PRD
  requirement IDs, and pull request title format. External links are checked
  weekly.
- Dependabot updates for the pinned GitHub Actions.
- A record of what four providers' published documents say about driving
  their subscription tools from another app, rotating accounts at a usage
  limit, and other software handling a login
  (`docs/research/provider-terms/`).
- A ruleset on `main`: changes land through pull requests with passing
  checks; force pushes and deletion are blocked.
- Research report on open source repository practices, with its notes and
  survey data, in `docs/research/open-source-practices/`.
- Architecture rules in `docs/ARCHITECTURE.md`: four active now and three
  that wait for code. A pull request answers the active rules in its
  description (Dependabot is exempt from that part), and a new required
  "Rules compliance" check verifies the answers.
- A `check-rules` skill for agents in `.agents/skills/`, linked from
  `.claude/skills/`.
- The version 1 product requirements in `docs/PRD.md` (a draft), with the
  record of its adversarial review in `docs/research/prd-review/`.
- The first architecture decision record: a Rails API with PostgreSQL,
  shipped in Docker containers that run on the owner's Mac for the first run
  and later on a server the owner controls; a native Swift and SwiftUI Mac
  app as a thin client; and a Swift helper on the owner's Mac that runs the
  providers' tools (`docs/adr/0001-rails-api-postgresql-and-a-mac-client.md`).

### Changed

- Pull requests are welcome at any time; opening an issue first is optional.
