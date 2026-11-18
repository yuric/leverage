# AGENTS.md

Instructions for AI coding agents (and a useful orientation for humans) working
in this repository. Follows the [AGENTS.md](https://agents.md) convention.

## Current state

leverage is in its definition phase. The repository contains documentation
and the checks that keep it consistent: there is no product source code, no
build, no test suite, and no deployment. Update this file in the same pull
request that changes any of that.

## Source of truth

1. [docs/PRD.md](docs/PRD.md) defines **what** is built. Work that is not
   traceable to a requirement there does not belong in a pull request.
2. [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) defines **how** it is built.
3. [docs/DEPLOY.md](docs/DEPLOY.md) defines how it is shipped and operated.
4. [MAINTENANCE.md](MAINTENANCE.md) defines scope limits and what gets
   declined.

Sections marked _TBD_ are undecided. Do not fill them in by guessing, and do
not treat a plausible assumption as a decision. If a task depends on something
undecided, stop and ask, or open an issue.

## Rules

- **Do not invent requirements.** Propose them as a change to the PRD and let a
  maintainer accept them.
- **Verify before you claim.** Statements about how the project works must come
  from reading the current files, not from comments, older docs, or
  expectation. If something is unverified, say so. Run the checks below before
  reporting work as done.
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

- `main` is protected by a repository ruleset: direct pushes, force pushes,
  and deletion are rejected. Every change, including the maintainer's, lands
  through a pull request whose checks have passed. Do not try to work around
  the ruleset; if it blocks something legitimate, say so and stop.
- Branch from `main`, open a pull request, and fill in the template, including
  the AI assistance section.
- Pull request titles and commit messages follow
  [Conventional Commits](https://www.conventionalcommits.org/)
  (`docs:`, `feat:`, `fix:`, `chore:` …), written in the imperative, explaining
  why when it is not obvious. The pull request title is checked automatically.
- Reference requirement IDs from the PRD (`FR-001`, `NFR-001`) in commits and
  pull requests that implement them.
- Add user-visible changes to the `Unreleased` section of
  [CHANGELOG.md](CHANGELOG.md).
- Disclose AI assistance: commits authored with an agent carry a
  `Co-Authored-By` trailer naming it. A human remains responsible for every
  change that is merged. The full policy is in
  [CONTRIBUTING.md](CONTRIBUTING.md#ai-assisted-contributions).

## Checks

These run on every pull request and must pass. Run them locally before you
report work as done:

```bash
npx markdownlint-cli2 "**/*.md"                      # Markdown lint
lychee --offline --include-fragments './**/*.md'     # links between files
python3 scripts/check_prd_ids.py                     # PRD requirement IDs
```

If a tool is not installed, say which check you could not run instead of
claiming it passed.

## GitHub Actions

Workflows in `.github/workflows/` follow these rules. Keep to them when adding
or changing one:

- Set `permissions:` explicitly, and grant the least that works. The default
  is `contents: read`.
- Pin every third-party action to a full commit SHA, with the version in a
  trailing comment. Never pin to a tag or branch. Dependabot proposes the
  updates.
- Never use the `pull_request_target` trigger.
- Pass untrusted values (titles, branch names, issue text) to scripts through
  `env:`, never by interpolating `${{ … }}` into a `run:` script.

## Build, test, and run

Not applicable yet. When the first code lands, this section must list the
exact commands to install, build, lint, test, and run the project, and an
agent must run them before reporting work as done.

## Documentation style

- Markdown, wrapped at about 80 columns, one sentence of purpose at the top of
  every document.
- Write what is true now. Plans go in the PRD or in issues.
- Prefer a short, correct document to a long, speculative one.
