# AGENTS.md

Instructions for AI coding agents (and a useful orientation for humans) working
in this repository. Follows the [AGENTS.md](https://agents.md) convention.

## Current state

leverage is in its definition phase. The repository contains documentation
only: there is no source code, no build, no test suite, and no deployment.
Update this file in the same pull request that changes any of that.

## Source of truth

1. [docs/PRD.md](docs/PRD.md) defines **what** is built. Work that is not
   traceable to a requirement there does not belong in a pull request.
2. [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) defines **how** it is built.
3. [docs/DEPLOY.md](docs/DEPLOY.md) defines how it is shipped and operated.

Sections marked _TBD_ are undecided. Do not fill them in by guessing, and do
not treat a plausible assumption as a decision. If a task depends on something
undecided, stop and ask, or open an issue.

## Rules

- **Do not invent requirements.** Propose them as a change to the PRD and let a
  maintainer accept them.
- **Verify before you claim.** Statements about how the project works must come
  from reading the current files, not from comments, older docs, or
  expectation. If something is unverified, say so.
- **Keep docs in step with reality.** A change that alters behavior,
  architecture, configuration, or deployment updates the matching document in
  the same pull request.
- **Never commit secrets.** No credentials, tokens, keys, or personal data, in
  code, docs, tests, fixtures, or commit messages. Use placeholders.
- **Stay in scope.** Make the change that was asked for. Report unrelated
  problems as issues instead of fixing them in passing.
- **Do not add dependencies, licenses, or services without saying so.** Any new
  dependency must be compatible with the MIT License and called out in the
  pull request description.
- **Security-sensitive findings go through [SECURITY.md](SECURITY.md)**, not
  public issues or pull requests.

## Workflow

- Branch from `main`; never commit to `main` directly once the project has
  code. Open a pull request and fill in the template.
- Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/)
  (`docs:`, `feat:`, `fix:`, `chore:` …), written in the imperative, explaining
  why when it is not obvious.
- Reference requirement IDs from the PRD (`FR-001`, `NFR-001`) in commits and
  pull requests that implement them.
- Add user-visible changes to the `Unreleased` section of
  [CHANGELOG.md](CHANGELOG.md).
- Disclose AI assistance: commits authored with an agent carry a
  `Co-Authored-By` trailer naming it. A human remains responsible for every
  change that is merged.

## Build, test, and run

Not applicable yet. When the first code lands, this section must list the
exact commands to install, build, lint, test, and run the project, and an
agent must run them before reporting work as done.

## Documentation style

- Markdown, wrapped at about 80 columns, one sentence of purpose at the top of
  every document.
- Write what is true now. Plans go in the PRD or in issues.
- Prefer a short, correct document to a long, speculative one.
