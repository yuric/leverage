# AGENTS.md

Instructions for AI coding agents (and a useful orientation for humans) working
in this repository. Follows the [AGENTS.md](https://agents.md) convention.

## Current state

leverage has its contract and the Core loop milestone: an owner can sign
in, add logins, connect a builder and a reviewer, and take a task from a
form to Done, on the owner's Mac. The repository holds the documentation,
the research behind its practices, and the scripts and checks that keep
them consistent, plus:

- `api/`: a Rails application in API mode, with Minitest tests. It serves
  the owner's, the agents' and the helper's calls of the Core loop through
  one transition function (`api/lib/leverage/transitions.rb`), and runs a
  timer sweep (`api/bin/sweep`); `bin/rails leverage:verify_log` replays a
  workspace's log against its tables;
- `api/contract/`: the contract every part is built against (the fixed
  lists, event payloads, state and step tables, hooks, jobs, roles, timers,
  Needs you, the interface schema and the golden traces), described in its
  [README](api/contract/README.md); `api/db/`: the migrations and
  `structure.sql` for every table of the Data model;
- `mac/`: a Swift package with the library LeverageKit, the reference
  runner LeverageRunner, the helper LeverageHelper, the app's services
  LeverageAppServices and the Mac app LeverageApp, with Swift Testing tests
  and stand-in provider tools in `mac/Tests/StandIns/`;
- `compose.yaml` (the API, the sweep and PostgreSQL in Docker containers on
  the owner's Mac, the one environment in [docs/DEPLOY.md](docs/DEPLOY.md)),
  `compose.test.yaml` (lets Docker pick the API's port in automated runs)
  and `.env.example`;
- `scripts/`: besides the checks below, `build_app.sh` (builds
  `dist/Leverage.app`), `smoke_app.sh`, `e2e_core_loop.sh` (the whole loop
  with stand-in tools), `speed_run.sh`, `secret_scan.py`,
  `generate_swift_contract.py` and `app_compose.py`;
- `.github/workflows/ci.yml`: the API and Swift test suites, the
  migrations-from-zero check, the import check, the app bundle and the
  end-to-end run on Linux on every pull request;
  `.github/workflows/docs.yml`: the Markdown, link, PRD, rules and title
  checks, and the comparison of the PRD's tables with the contract.

Update this file in the same pull request that changes any of that.

## Start here

Read [docs/IMPLEMENTATION.md](docs/IMPLEMENTATION.md) before any work. It
says which milestone is in flight, how the build is being run, and what is
waiting for the owner. A pull request that starts, finishes or changes the
plan for a milestone updates it.

## Source of truth

1. [docs/PRD.md](docs/PRD.md) defines **what** is built. Product behavior
   that is not traceable to a requirement there does not belong in a pull
   request.
2. [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) defines **how** it is built.
3. [docs/DEPLOY.md](docs/DEPLOY.md) defines how it is shipped and operated.
4. [MAINTENANCE.md](MAINTENANCE.md) defines scope limits and what gets
   declined.
5. [docs/IMPLEMENTATION.md](docs/IMPLEMENTATION.md) records progress, and
   holds the terms of a delegated run while one is in progress. It defines
   nothing about the product.

Sections marked _TBD_ are undecided. Do not fill them in by guessing, and do
not treat a plausible assumption as a decision. If a task depends on something
undecided, stop and ask, or open an issue.

In a delegated run (see
[CONTRIBUTING.md](CONTRIBUTING.md#ai-assisted-contributions)), record the
question and what you chose under "Questions for the owner" in
[docs/IMPLEMENTATION.md](docs/IMPLEMENTATION.md), and continue. A delegated
run does not supersede an accepted ADR and does not answer Deviates to a
rule. It records the question and takes a path that needs neither. Every ADR
it adds is listed in IMPLEMENTATION.md as waiting for the owner until the
owner has read it.

## Architecture rules

- **Read the rules before you change anything.** They are in the
  [Rules](docs/ARCHITECTURE.md#rules) section of the architecture document,
  with IDs that start `AR-`. Every rule marked Active applies to your change.
- **Check your pull request against them before you open or update it.**
  Follow the [check-rules skill](.agents/skills/check-rules/SKILL.md): it
  answers every active rule from the evidence in your diff, not from memory.
  `.claude/skills` is a symbolic link to `.agents/skills`; if it is a plain
  file in your checkout, read `.agents/skills/` directly.

## Working rules

- **Follow the engineering practices.** They are in
  [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#engineering-practices):
  test-driven development first.
- **Do not invent requirements.** Propose them as a change to the PRD and let a
  maintainer accept them.
- **Use the PRD's terms.** The [Terms](docs/PRD.md#terms) table names the
  things leverage is made of. Use those words, with those meanings, in
  documents, issues, pull requests, and code. Do not coin a synonym or reuse a
  term for something else; a new or changed term is a change to the PRD.
- **Verify before you claim.** Statements about how the project works must come
  from reading the current files, not from comments, older docs, or
  expectation. If something is unverified, say so. Run the checks below before
  reporting work as done.
- **Keep docs in step with reality.** A change that alters behavior,
  architecture, configuration, or deployment updates the matching document in
  the same pull request.
- **Never commit secrets.** No credentials, tokens, keys, or personal data, in
  code, docs, tests, fixtures, or commit messages. Use placeholders.
- **Stay in scope.** One purpose per pull request; rule AR-001 defines it.
- **Do not add a dependency or service without declaring it.** Rule AR-004
  says what to declare.
- **Security-sensitive findings go through [SECURITY.md](SECURITY.md)**, not
  public issues or pull requests.

## Workflow

- `main` is protected by a repository ruleset: direct pushes, force pushes,
  and deletion are rejected. Every change, including the maintainer's, lands
  through a pull request whose checks have passed. Do not try to work around
  the ruleset; if it blocks something legitimate, say so and stop.
- Branch from `main`, open a pull request, and fill in the template, including
  the architecture rules and AI assistance sections. `gh pr create` with
  `--body` or `--body-file` skips the template, so start the description from
  the template file yourself.
- In the AI assistance section, name the tool and what it did, and leave both
  boxes unticked: the person you work for ticks one after reading the change.
- Do not open a pull request that the person you work for has not asked for
  or seen. See "No unattended agents" in
  [CONTRIBUTING.md](CONTRIBUTING.md#ai-assisted-contributions). The one
  exception is a delegated run the maintainer started, described there.
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
python3 scripts/check_rules.py                       # architecture rules
python3 scripts/test_check_rules.py                  # self-test of that check
python3 scripts/check_imports.py                     # dependency directions
python3 scripts/test_check_imports.py                # self-test of that check
python3 scripts/check_registry.py                    # PRD lists vs the registry
python3 scripts/test_check_registry.py               # self-test of that check
python3 scripts/check_contract_tables.py             # PRD tables vs the contract
python3 scripts/test_check_contract_tables.py        # self-test of that check
python3 -I scripts/generate_swift_contract.py --check  # Swift copy of the contract is current
python3 -I scripts/test_generate_swift_contract.py   # self-test of the generator
python3 -I scripts/test_app_compose.py               # self-test of the bundle's compose file
python3 -I scripts/test_secret_scan.py               # self-test of the secret scan
python3 -I scripts/test_speed_report.py              # self-test of the speed report
python3 -I scripts/test_real_gemini_through_app.py   # the real Gemini check's refusals
python3 -I mac/Tests/StandIns/test_provider_tool.py  # self-test of the stand-in tools
```

After changing anything under `api/contract/registry.json` or the
interface schema's enums, run `python3 scripts/generate_swift_contract.py`
and commit the regenerated `mac/Sources/LeverageKit/Generated/Contract.swift`.

CI also runs the API's tests and RuboCop, the Swift build and tests, the app bundle, and the end-to-end run, listed under "Build, test, and run" below.

With a base commit and a description file, `check_rules.py` also checks a
pull request:
`python3 scripts/check_rules.py --base origin/main --body-file <file>`.
The two options only work together.

If a tool is not installed, say which check you could not run instead of
claiming it passed.

## GitHub Actions

Workflows in `.github/workflows/` follow these rules. Keep to them when adding
or changing one:

- Set `permissions:` explicitly, and grant the least that works. The default
  is `contents: read`.
- Pin every third-party action to a full commit SHA, with the version in a
  trailing comment. Never pin to a tag or branch. Dependabot proposes the
  updates, and the "Rules compliance" check fails on an unpinned action.
- Never use the `pull_request_target` trigger.
- Pass untrusted values (titles, branch names, issue text) to scripts through
  `env:`, never by interpolating `${{ … }}` into a `run:` script.

## Build, test, and run

Run these before reporting work as done. Ruby is never run on the Mac
itself: every Ruby and Rails command runs in the `api` container. Run them
from the repository root unless a line says otherwise.

Once, to configure (then replace the made-up values in `.env`):

```bash
cp .env.example .env
```

The API (`api/`):

```bash
docker compose build                                 # build the API image
docker compose run --rm api bin/rails test           # tests, against PostgreSQL
docker compose run --rm api bin/rails zeitwerk:check # autoloading
docker compose run --rm -e SEED=1 -e WALKS=1000 api bin/rails test test/engine/step_partition_test.rb  # 1000 random walks
docker compose run --rm --no-deps api bin/rubocop    # style
docker compose up -d                                 # run the API, the sweep and the database
curl -s http://127.0.0.1:3000/v1/health              # check it answers
docker compose exec -T api bin/rails leverage:verify_log  # replay every workspace's log
docker compose down                                  # stop; the data is kept
```

`API_PORT` in `.env` moves the API off port 3000 when that port is taken;
use the same port in the `curl` line. An automated `up` adds
`-f compose.yaml -f compose.test.yaml`, so that Docker picks the port, and
reads it with `docker compose -f compose.yaml -f compose.test.yaml port api
3000`.

The contract tests need no database. While you change the code, run them
from your checkout through a bind mount, without rebuilding the image:

```bash
docker compose run --rm --no-deps --entrypoint "" -v "$PWD/api:/rails" api bin/contract_test
```

When several checkouts (git worktrees) of this repository, or several
agents in one checkout, run containers at once, export
`COMPOSE_PROJECT_NAME` and `API_IMAGE_TAG` with a value of their own in
each, so that each has its own containers, image tag and database volume.

The Mac side (`mac/`):

```bash
cd mac
swift build                                          # build every target
swift test                                           # tests
```

`LEVERAGE_ONLY=<lane>` builds and tests one lane of the package: `kit`,
`runner`, `helper`, `services`, `app` or `e2e` (the only lane on Linux).
When several agents work at once, each builds its own lane in its own
`--scratch-path`, so that a half-written file in one lane never stops
another from compiling.

The whole product, from the repository root (Docker and Swift, nothing
else):

```bash
scripts/e2e_core_loop.sh                             # the whole loop with stand-in tools
scripts/speed_run.sh                                 # 50 seats for 120 s; prints the speed table
scripts/build_app.sh && scripts/smoke_app.sh         # build dist/Leverage.app, open it, check its server
```

Each starts a compose project of its own and removes it, also on failure.
`smoke_app.sh` uses a support folder and a compose project of its own
(`leverage-smoke-<pid>`). No automated test calls a real provider: the
tests find the providers' tools only through `LEVERAGE_TOOL_DIR`, on the
stand-ins. `scripts/real_gemini_through_app.sh` runs only with
`LEVERAGE_REAL_PROVIDER=gemini` and never in CI. How to run and operate it
all is in [docs/DEPLOY.md](docs/DEPLOY.md).

## Documentation style

- Markdown, wrapped at about 80 columns, one sentence of purpose at the top of
  every document.
- Write what is true now. Plans go in the PRD or in issues.
- Prefer a short, correct document to a long, speculative one.
