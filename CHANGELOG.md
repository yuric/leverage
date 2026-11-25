# Changelog

All notable changes to Leverage are recorded in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project will follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
once it makes its first release.

## [Unreleased]

### Added

- `scripts/check_home_paths.py` fails CI when a tracked file names a real
  user's home folder. The eval results check also looks for home paths
  and for more provider key shapes.
- CI runs the subscription preview's tests on every pull request.
- Dependabot proposes weekly updates for the API's gems, the Ruby image
  (patch versions only) and the PostgreSQL image (no new major version).
- [docs/DEPLOY.md](docs/DEPLOY.md#updating-the-model-list) describes how
  to update the model list.

- An offline subscription preview, a page to open in a browser
  ([docs/subscription/README.md](docs/subscription/README.md#interactive-preview)),
  exercises plan selection, checkout, billing changes and payment recovery
  with sample data. The app has no Subscription page yet, and its
  Subscription menu entry stays disabled.
- The sidebar account row shows the owner's sign-in email and opens a
  menu with Settings and Sign out.
- The Age of Lever page and the README say that Codex, Grok, Claude and
  Gemini belong to their respective owners and that Leverage is not
  affiliated with or endorsed by them.
- [docs/DEPLOY.md](docs/DEPLOY.md#the-first-run) and the README tell a
  person to read the providers' terms before adding a login, since a
  provider may not allow its tool to be driven by another app or work to
  move between two logins, and link the
  [provider terms record](docs/research/provider-terms/README.md).

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
  choices are recorded in ADRs 0011 to 0013. After an adversarial review
  of the milestone: a waiting submit
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

- An agent that adds a task no longer takes that task's checks at "before
  a task is ready", whatever its role, also after the owner completes the
  task's contract. With one agent able to check, a task that agent adds
  ends its check in error, and with a General agent "Orchestrator
  offline" opens, where the agent used to pass its own task.
- An agent the owner has turned off can no longer send the result of a
  job it holds or add tasks: both are refused `forbidden`, and its join
  instructions say it is off. Its job goes to another agent, or to the
  owner, when the job's time runs out. A paused agent still finishes its
  job and can still add tasks.
- A planner's contract draft can no longer add, replace or remove a
  task's outward actions. The server keeps the saved actions, as it keeps
  the work reference, minimum strength and budget cap.
- The content of the Imaginarium project can no longer be deleted, in the
  server or the app, because nothing makes another one and the gallery
  needs it. The content of its Done and Cancelled tasks can still be
  deleted.
- Every `task.created` event is written in one shape, payload version 2,
  with `imaginarium_entry` and `added_criterion_ids`. Version 1 is kept for
  logs that already hold it.
- One cost report, review verdict or job result carries at most 100,000
  US dollars of spend, and a larger one is `422 invalid`, so one mistaken
  report can no longer fill a project's total and block every later
  report with a cost in that project.
- A question, its assumption, an access request, the owner's answer, a
  project's name and goal and a brief entry have length limits, and a
  brief has at most 100 entries; a longer one is `422 invalid`. A request
  body over 4 MiB is refused `400 malformed` before it is read.
- A build, a review or an outward action whose prompt is over 512 KiB
  starts no tool, logs the sizes and counts as a failed tool run.
- Copy in Connect keeps the landing prompt on this Mac's clipboard (no
  Universal Clipboard) and marks it so that clipboard-history tools that
  honour the mark skip it.
- Each container's log is capped at three files of 10 MB.
- `.env.example` and DEPLOY.md say that `SECRET_KEY_BASE` is needed for
  Rails to start and signs none of Leverage's tokens. The contract says
  that the server stores the model Add credential sends and fills in no
  default.
- `scripts/check_model_catalog.py` rejects a `checked_on` that is not a
  calendar date, a documented source that is not an `https` address, and
  a help or probe file that does not name the model id or default it
  evidences as a whole id.
- `scripts/restore_drill.sh --from-project` takes only an end-to-end run's
  `leverage-e2e-` project, and `scripts/speed_run.sh` always runs in a
  compose project of its own, so neither can remove the database of the
  owner's, the app's or another exported stack.
- The local Markdown lint command is pinned to markdownlint-cli2 0.24.2,
  the version CI runs. CONTRIBUTING.md names the code checks every pull
  request runs and points to their commands in AGENTS.md.
- The subscription preview keeps Change plan and Cancel subscription
  while a payment is due.

- The Age of Lever page and the README say that Leverage is built to keep
  work moving at a limit or a sign-out and that this has been shown so far
  only with stand-in tools, with a link to
  [how far it is proven](docs/IMPLEMENTATION.md#what-the-handoff-milestone-proves-and-how-far).
  The page's Handoff example is labelled Illustration.
- The API depends on the seven parts of Rails it uses (`railties`,
  `activesupport`, `activemodel`, `activerecord`, `activejob`, `actionpack`
  and `actionview`) instead of the `rails` gem. Its image no longer
  installs Action Mailer, Action Mailbox, Action Text, Active Storage,
  Action Cable or the gems only they need.
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

- When the owner completes the contract of a task an agent added, or a
  planner drafts it at the owner's request, the task log records that
  choice instead of "That no longer needs you."
- An agent with Work on tasks off is still offered the job it already
  holds, and can pick it up again after its run moves to another account.
  Its join instructions list `submit_task` when Deliver tasks is on.
- A task saved to Ideas from the Imaginarium, promoted and sent records
  its build steps per criterion and its review step against the review
  criterion. The steps already stored for such a task are rebuilt from the
  log once, when the updated server first starts, and `bin/restore` makes
  the same repair in a dump made before it, so `leverage:verify_log` and a
  restore pass again.
- A General agent whose lease on one task had lapsed, while another task
  it built waited in Finishing, no longer makes every other command in the
  workspace fail with a server error.
- `leverage:verify_log` and `bin/restore` no longer report a New prompt
  logged before App round 2 that ended a waiting command whose check was
  held at the re-run limit.
- The log audit reads a New prompt logged before App round 2 only for that
  seat's own work: the task it built, the reviews it held, its own waiting
  commands and the Finishing tasks it built. A release, withdrawn check or
  hold of another seat's work under that command is now reported, as is a
  sweep that writes anything other than closing the "Agents have added 50
  open tasks" item.
- `bin/restore` brings a dump made by an earlier version to the current
  schema before the replay test, so dumps kept from before an upgrade
  restore with the documented command. A dump made by a later version is
  refused with a message that says so. Every restored event gets the
  transaction id 0, so that in a new cluster no restored event can stand
  in for one a later transaction never wrote.
- A NUL character in a request is refused `422 invalid`, or `404` in a
  command key, instead of causing a server error.
- An app-run agent no longer claims and gives back the same task or review
  without end. After giving work back it waits a second before asking
  again, and three give-backs in a row (a work reference that names no
  folder on this Mac, a tool that says it cannot do the work, a failed
  run) stop the agent with an error.
- A Codex run that reconnected and then succeeded is no longer thrown away
  as a failed run, and its tokens are reported.
- A number out of range in a provider tool's output (a usage figure, or
  Codex's reset time) no longer crashes the runner. A limit with an
  unreadable reset time is reported with no reset time.
- When the server does not take the result of an Add credential, the
  helper removes the token or sign-in that Add saved, so nothing stays on
  the Mac for a credential that is never listed.
- The Imaginarium gallery's search also finds prompts by their category
  name, as each tile's chip shows it.
- Each Make it yours field in Try it shows its label above it, also while
  it holds its default.
- Connect's Done waits until the landing prompt has arrived, so closing
  the sheet can no longer lose the only prompt with the seat's token.
- The chosen appearance, Light or Dark, also applies to panels such as
  Choose folder, and Same as this Mac follows the Mac again.
- An app started with another `LEVERAGE_SUPPORT_DIR` gets its own compose
  project and Keychain session, instead of taking over the owner's server
  or signing the owner out. A folder used that way before keeps its data
  under the project `leverage-app`, which `LEVERAGE_COMPOSE_PROJECT`
  reaches.
- Why the server did not start is kept in `logs/app.log` in the support
  folder, and the start-up screen says where it is. A problem with the
  app's own folder no longer tells the owner to check Docker Desktop.
- When the support folder's `server/.env` is lost but the database is
  still in Docker, the app writes no new passwords and explains how to get
  the database back.
- The eval results no longer record why a provider's account refused a
  run, and the eval check refuses a not-run reason that names account or
  billing state.
- The eval check holds specific-details results to their ledger's latest
  settled run and tool-run counts, as it already did for the approvals
  suite.
- General-mode eval results and ledger entries record the General job
  rules they ran with (`job_rules_sha256`), so changing those rules
  without running the suites again fails CI.

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

### Security

- The API answers only requests addressed to `127.0.0.1`, `localhost` or
  `[::1]`. The compose service name `api` is no longer an allowed host, so
  a network that controls name resolution cannot point a page at the
  server.
- Owner sign-in counts wrong passwords: after ten inside a minute, sign-in
  is refused for a minute, with the right password too. A session that is
  already open keeps working.
- A seat and the helper each hold one waiting long poll. A newer one ends
  the older, so one agent cannot occupy every thread of the server.
- The landing prompt and the HTTP join instructions tell a
  prompt-connected agent to keep its token in a file only it can read and
  send the header from that file, never on a command line, where other
  accounts on the Mac could read it.
- `.env.example` no longer carries working secrets: its database passwords
  and `SECRET_KEY_BASE` are empty. `python3 -I scripts/make_env.py`
  replaces `cp .env.example .env`: it writes a `.env` with random values of
  its own and never touches an existing one. compose refuses to start
  while `POSTGRES_PASSWORD` or `SECRET_KEY_BASE` is empty. A `.env` copied
  from an earlier example still holds its published `change-me` values
  and runs on them until they are replaced; PostgreSQL keeps the password
  its volume was first made with.
- The application's database role can only read Rails' `schema_migrations`
  and `ar_internal_metadata`; only the owner role's migrations write them.
- `api/Dockerfile` no longer pulls a build frontend image by a floating
  tag. Every image the build pulls is named with a digest, the Ruby
  image's tag is written out instead of taken from `ARG RUBY_VERSION`,
  and a self-test holds both.
- Database dumps and exported keychains are git-ignored by name wherever
  they are written in the checkout.
- The app, the helper, the runner and the MCP server no longer keep a URL
  cache. Earlier builds wrote the API's answers and their bearer tokens,
  the owner's session among them, to plain files under `~/Library/Caches`.
  Each program now removes its own cache files when it starts. If you ran
  an earlier build, sign out and in once, and remove and connect again
  any agent that connected on its own.
- A task's "Where the work is" can no longer point a tool at the Mac's
  root, the home folder itself, Leverage's own support folder, or
  `~/Library` outside cloud drive folders. A link to one of these is
  refused too, and such a task is given back like one whose folder does
  not exist.
- The work folder's path is no longer part of a builder's or reviewer's
  prompt, so a folder's name cannot add instructions to it.
