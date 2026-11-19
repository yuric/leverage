# Changelog

All notable changes to leverage are recorded in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project will follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
once it makes its first release.

## [Unreleased]

### Added

- Repository scaffolding: README, MIT license, AUTHORS, contribution guide,
  code of conduct, security policy, and issue and pull request templates.
- Product requirements document structure in `docs/PRD.md` (requirements to
  follow).
- Architecture and deployment document structure in `docs/`.
- `AGENTS.md` with instructions for AI coding agents.
- `MAINTENANCE.md`: what to expect from the maintainer, and the project's
  scope limits.
- An AI-assisted contributions policy in `CONTRIBUTING.md`, a matching
  disclosure section in the pull request template, and a rule for AI-assisted
  vulnerability reports in `SECURITY.md`.
- Automated checks on every pull request: Markdown lint, internal links, PRD
  requirement IDs, and pull request title format. External links are checked
  weekly.
- Dependabot updates for the pinned GitHub Actions.
- A ruleset on `main`: changes land through pull requests with passing
  checks; force pushes and deletion are blocked.
- Research report on open source repository practices, with its notes and
  survey data, in `docs/research/open-source-practices/`.
- Architecture rules in `docs/ARCHITECTURE.md`: four active now and three
  that wait for code. Every pull request answers the active rules in its
  description, and a new "Rules compliance" check verifies the answers.
- A `check-rules` skill for agents in `.agents/skills/`, linked from
  `.claude/skills/`.

### Changed

- Pull requests are welcome at any time; opening an issue first is optional.
