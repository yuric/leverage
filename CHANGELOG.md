# Changelog

All notable changes to leverage are recorded in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project will follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
once it makes its first release.

## [Unreleased]

### Added

- The skeleton of the build: a Rails API in `api/` that answers
  `GET /v1/health` and turns every unhandled error into one JSON shape; a Swift
  package in `mac/` with the library LeverageKit, the helper
  LeverageHelper and a one-window Mac app; `compose.yaml` to run the API and
  PostgreSQL in Docker containers on the owner's Mac; and a CI workflow that
  runs both test suites, RuboCop, Brakeman and the import check. The pinned
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
