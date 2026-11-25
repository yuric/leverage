# Changelog

All notable changes to Leverage are recorded in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project will follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
once it makes its first release.

## [Unreleased]

### Added

- An offline subscription preview, a page to open in a browser
  ([docs/subscription/README.md](docs/subscription/README.md#interactive-preview)),
  exercises plan selection, checkout, billing changes and payment recovery
  with sample data. The app has no Subscription page yet, and its
  Subscription menu entry stays disabled.
- The sidebar account row shows the owner's sign-in email and opens a
  menu with Settings and Sign out.

- Every workspace has an Imaginarium project for gallery tasks. A new
  installation gets it at setup, and an
  existing one gets it once when the updated app starts its server. The
  side pane lists it first among the projects, on a faint rainbow tint.
- The Imaginarium tab offers 32 prompts that can be personalized, edited,
  copied, sent to Ready or saved to Ideas with their acceptance criteria.
  Tasks made from the gallery carry an Imaginarium badge.
- A new installation opens the setup assistant: a welcome, two logins
  from two providers, a General agent for each login, and a first task
  from three built-in starter tasks or one the owner writes. Leaving it
  with "Set up later" opens the task board with the setup checklist:
  four steps that tick when they are true, setup progress in the side
  pane, and a spotlight that dims the window and leaves the next control
  lit. The requirements and pictures are in
  [docs/onboarding/PRD.md](docs/onboarding/PRD.md).
- Added the Age of Lever marketing page with a provider-neutral board, a
  handoff example, and an interactive preview of the Imaginarium.
- Connect defaults to General. A General agent can build, review, draft
  contracts, check tasks, answer questions and decide approvals, one job,
  task or review at a time. A running seat the app manages restarts when
  its role changes to or from General. A General seat can build and do
  jobs on a Gemini login. Its review work passes over Gemini logins.
  The board shows task-specific reviewer availability and includes eligible
  General seats in account waits. A Ready task still shows the builder's
  login wait when a General seat with a free login lacks standing to build it.
  General build and review briefings include the instructions for that work.
- Prompt connections use one landing prompt with the seat's token and
  instructions to fetch `GET /v1/join` for HTTP or MCP. Prompt agents
  report their model and effort to the roster. To issue another landing
  prompt, remove the seat and connect a new one. Remove ends the seat's
  token and gives back its work.
- Connect and Change let the owner set Work on tasks, Deliver tasks and
  Create tasks. Turning Deliver tasks off returns held Working tasks to
  Ready. A Prompt agent with Create tasks can add a task with criteria
  and put it through the same checks as an owner's task. The task log and
  Activity name the agent that added it.

- Added the Credentials screen with limits and resets where available, API
  tokens, Refresh and Verify all, renaming and removing a credential, and
  reordering the handoff order. A usage reading can resume a waiting task
  as soon as a candidate has capacity. Needs you explains when Verify is
  needed. Pending local credential cleanup resumes when the helper starts.

- Worker questions and access requests, with owner replies and grants
  in Needs you.
- Outward actions after review, with approval or stop decisions, a
  Finishing lease for the original builder and owner choices for
  unconfirmed actions.
- Decided for you records approvals and answers made by deciding.
  Activity shows the workspace's events.
- Projects have briefs, budgets and pause controls. Tasks have project,
  priority and spending limit controls. Repeated failed reviews can
  require a stronger builder.
- Workspace settings and content deletion for finished work.
- The bundled MCP server exposes the agent interface for seats that
  connect on their own. All seven shipped rules act, and outward action
  approvals have their own eval suite.
- Completing a task withdraws its unanswered question jobs. An
  outstanding Approval item is answered before the action can be waived.
  Content deletion clears stored check reasons and evidence and resolves
  open Needs you items for unanswered questions. The spending fields
  share the Mac’s decimal separator and reject out-of-range amounts.

- Added rule checks: rules with versions in Settings, checks by an
  orchestrator agent, tasks that wait on a check, letting a check through
  once, a Timing section and rule checklist on each task, drafting a
  task's details, and the item that says no agent may review. The PRD's
  Rule checks milestone: every workspace has the seven shipped rules, on,
  written at sign-up or, for an existing installation, when the server
  starts. Four first act in the Questions and approvals milestone. The owner's rules
  gate a task becoming ready, an agent starting it, its work being
  submitted and its review passing; a rule Leverage checks itself answers
  at once, and one a model judges is a job for an orchestrator agent,
  which the helper starts like any other agent, while the task waits and
  goes on by itself when the check ends. A check that cannot run, an agent
  turned away by every check, a fourth try and an offline orchestrator
  each come to Needs you, and the owner can run a check again or let it
  through once with a reason. The provider rule keeps a reviewer off any
  provider that built the task, also after a handoff, and "No agent may
  review this" says when nobody may. The Rules screen in Settings edits,
  adds, reverts, turns off and removes rules, each change a new wording
  that earlier checks keep. The task page shows where a task's time went
  and what each rule said; a planner agent can draft a task's details. An
  agent's briefing and the reference runner's prompts carry the rules, and
  a rule's reason reaches a builder only as quoted material. The rule
  "Every task needs specific details" has its wording and an eval suite of
  24 cases, which Claude Code, Codex and Antigravity each passed at their
  default model at the time. On the current cases Codex and Antigravity
  pass, and Claude Code has not been run. The server's request log now
  keeps no text but ids. The PRD gains the changes S-1 to S-14; the
  choices are recorded in ADRs 0011 to 0013. After an adversarial review of the milestone: a waiting submit
  or pass completes when its rule is turned off, removed or saved; the
  re-run limit holds across a release; a check that cannot run while the
  orchestrator is online always opens its item, at once, beside another
  running check; turning a rule on again holds a task every agent was
  turned away from; cancelling a task withdraws all its checks and jobs; a
  waiting claim lapses for an agent that may no longer claim; a "note it"
  rule's check judges what the request held; task text has length limits;
  a checker's prompt breaks markers planted in task text; a builder sent
  back by a rule's check reads the rule and its reason; an agent that
  claims jobs is told to check for work every minute; a press after a
  refusal sends a new request; and the Needs you and Timing wording is
  plainer.
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
  passes the replay test. The task page names the account a task waits
  for, as its card does. Signing out of the app and quickly back in starts
  the helper again, and a helper whose app is gone stops. Every
  interruption is shown with stand-in tools only, and the limit replies
  they play are made, not observed. The PRD gains the changes R-1 to R-10;
  the choices are recorded in ADRs 0008 to 0010.
- Added the core loop: sign-in, logins, agents the app runs, tasks from a
  form to Done. The PRD's Core loop milestone: `Leverage.app` starts the
  server and its timer sweep in Docker containers on the owner's Mac,
  creates the owner's sign-in, adds and verifies logins through the helper
  (installing a provider's tool where Leverage can), connects a builder and
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

- The README describes how Leverage coordinates AI agents on the Mac and
  keeps tasks moving through provider interruptions.
- The left pane's Rules tab holds rules and workspace settings. Leverage
  Settings (⌘ ,) offers Same as this Mac, Light and Dark. Provider login
  rows are labeled Login.

- Add task and Edit contract use details in place of a separate task goal.
  The upgrade folds existing task goals into their details and updates an
  untouched "Every task needs specific details" rule to use the new wording.
- Add task can fill in where the work is from the project's latest usable
  work reference. Paste link and Choose folder on this Mac are available
  when no project is selected or the work-reference field is empty.
- Needs you offers Open System Settings when notifications are off.
- Native Connect offers Add a login when there are no logins. Native
  Connect and Change offer model and supported effort choices from the
  shared catalog, with the tool's default first. Prompt can connect
  without a login or model choice.
- Settings groups the list into Orchestrator rules and Other agent rules.
- The Agent roster marks task checking as untested until the eval suites
  pass on the updated task contract.
- The Age of Lever page puts the Handoff demo before the Imaginarium and
  keeps its navigation visible while scrolling.
- The Board tab is named Task board.
- Pull requests are welcome at any time; opening an issue first is optional.
- The product is written "Leverage", with a capital L, in the documents and
  in the app's words.

### Fixed

- Log verification recognizes a credential switch when an action
  approved by a check override grants the builder a fresh lease.
- `bin/rails leverage:verify_log` passes again for a workspace created
  before the Imaginarium project. Its sign-up wrote only the shipped
  rules, and the check now reads it that way.
- A planner's empty draft keeps the task's saved details, including goal
  text folded on upgrade.
- Add task refreshes project work references after task changes, builder
  submissions and content deletion. Paste link explains when the
  clipboard has no supported link or folder path.
- Native Connect lets the owner retry a failed login read.
- The server waits for PostgreSQL to accept TCP connections before
  starting, including when it starts with a new database after a restore.
- Log verification recognizes rule checks the orchestrator retries before
  the workspace's offline item opens.
- Saving an unchanged seat leaves reviewer eligibility updates to the
  timer sweep.
