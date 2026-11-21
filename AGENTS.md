# AGENTS.md

Instructions for AI coding agents (and a useful orientation for humans) working
in this repository. Follows the [AGENTS.md](https://agents.md) convention.

## Current state

leverage has its contract, Core loop, Handoff, Rule checks and Questions
and approvals, and Credentials. On the owner's Mac, the owner can sign in, add logins,
connect agents, take a task from a form to Done, and see how it reached
Done. A run that meets a provider limit or sign-out continues on the
next eligible account or waits. The database is backed up daily, with a
tested restore. All seven shipped rules act. The app shows questions,
access requests, outward actions, projects and spending, Activity,
Decided for you, content deletion and workspace settings. A seat that
connects on its own can use HTTP or the bundled MCP server. Credentials
lists both kinds of credential, with token Add, Refresh, Verify all,
Rename and Remove. The Handoff tab supports reordering. Codex CLI 0.169.0
is the only registered login usage reader. The five API token readers
have stand-in coverage.

The full workflows use stand-in tools. Developer checks also ran a
Gemini task through the app, a Claude Code task through MCP, and checks
and approvals with real orchestrators on Claude Code, Codex and
Antigravity. Real checks used stand-ins for outward actions. Orchestrator
question jobs used stand-ins for the prompt and for parsing the answer
and basis. The owner's MCP run, real reviewer and planner runs, and a real
interruption remain unverified. The repository contains the documents,
research, and the following code and checks.

- `api/`: a Rails application in API mode, with Minitest tests. It serves
  the owner's, the agents' and the helper's calls through one transition
  function (`api/lib/leverage/transitions.rb`), which asks the rules engine
  (`api/lib/leverage/rules/`), runs a timer sweep (`api/bin/sweep`) and a
  daily backup (`api/bin/backup`, with `api/bin/restore`); `bin/rails
  leverage:verify_log` replays a workspace's log against its tables,
  `bin/rails leverage:recovery_times` prints each interrupted run's
  recovery time, `bin/rails leverage:rule_timing` each rule's runs and
  times, and `bin/rails leverage:install_shipped_rules` (run before the
  server starts) writes the shipped rules of a workspace that has none;
- `api/contract/`: the contract every part is built against (the fixed
  lists, event payloads, state and step tables, hooks, jobs, roles, timers,
  Needs you, the interface schema and the golden traces), described in its
  [README](api/contract/README.md); `api/db/`: the migrations and
  `structure.sql` for every table of the Data model;
- `mac/`: a Swift package with the library LeverageKit (with one limit
  and sign-out detector per provider), the reference runner
  LeverageRunner, the MCP server LeverageMCP, the helper LeverageHelper,
  the app's services
  LeverageAppServices and the Mac app LeverageApp, with Swift Testing tests,
  stand-in provider tools in `mac/Tests/StandIns/` and the provider replies
  they play in `mac/Tests/StandIns/replies/`;
- `evals/specific-details/`: the eval suite of the rule "Every task needs
  specific details" (24 made-up cases, the bar, and the results of the
  maintainer's run on Claude Code, Codex and Antigravity);
- `evals/approves-actions/`: the outward action approval eval suite, with
  30 main cases, a 10-case held-out set, and the recorded main results;
- `compose.yaml` (the API, the sweep, the daily backup and PostgreSQL in
  Docker containers on the owner's Mac, the one environment in
  [docs/DEPLOY.md](docs/DEPLOY.md)), `compose.test.yaml` (lets Docker pick
  the API's port in automated runs) and `.env.example`;
- `scripts/`: besides the checks below, `build_app.sh` (builds
  `dist/Leverage.app`), `smoke_app.sh`, `e2e_core_loop.sh` (the whole loop
  with stand-in tools), `e2e_handoff.sh` (six runs interrupted by a limit
  or a sign-out, with stand-in tools), `e2e_rule_checks.sh` (seven runs
  with the rules on and an orchestrator, with stand-in tools),
  `e2e_questions_approvals.sh` (seven stand-in cases, with MCP),
  `e2e_credentials.sh` (three stand-in cases with replay and secret scans),
  `capture_reader_reply.py` (a maintainer-only developer check),
  `restore_drill.sh` (a backup restored into an emptied cluster),
  `speed_run.sh`, `secret_scan.py`, `generate_swift_contract.py`,
  `app_compose.py`, and the maintainer's runs on real tools,
  `eval_rule.sh` (both suites, scored by `eval_score.py`),
  `real_rule_check.sh`, `real_mcp_run.sh` and `real_approval_check.sh`;
- `.github/workflows/ci.yml`: the API and Swift test suites, the
  migrations-from-zero check, the import check, the reply-file check, the
  capture self-test, app bundle, on Linux the end-to-end runs (`e2e_core_loop.sh`,
  `e2e_handoff.sh`, `e2e_rule_checks.sh`, `e2e_questions_approvals.sh`, `e2e_credentials.sh`)
  and the restore drill, and the
  eval suite's checks (`check_evals.py` and the self-tests of the eval
  scripts), on every pull request;
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
npx --yes markdownlint-cli2 "**/*.md"                      # Markdown lint
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
python3 -I scripts/check_reply_fixtures.py           # reply files hold no account detail
python3 -I scripts/test_capture_reader_reply.py      # capture guard and scrub self-test
python3 -I scripts/test_check_reply_fixtures.py      # self-test of that check
python3 -I scripts/test_e2e_core_loop.py             # the end-to-end script's plumbing, CI's steps
python3 -I scripts/test_speed_report.py              # self-test of the speed report
python3 -I scripts/test_real_gemini_through_app.py   # the real Gemini check's refusals
python3 -I scripts/test_real_provider_run.py         # the developer check, with stand-in tools
python3 -I mac/Tests/StandIns/test_provider_tool.py  # self-test of the stand-in tools
python3 -I scripts/check_evals.py                    # both suites' cases, results and registry list
python3 -I scripts/test_check_evals.py               # self-test of that check
python3 -I scripts/test_eval_score.py                # self-test of the eval scorer
bash scripts/test_eval_rule.sh                       # the eval script's refusals and plumbing, stand-in tools
bash scripts/test_real_rule_check.sh                 # the real rule check's refusals and plumbing
bash scripts/test_real_mcp_run.sh                    # the MCP check against stand-ins
bash scripts/test_real_approval_check.sh             # the approval check against stand-ins
```

After changing anything under `api/contract/registry.json` or the
interface schema's enums, run `python3 scripts/generate_swift_contract.py`
and commit the regenerated `mac/Sources/LeverageKit/Generated/Contract.swift`.

CI also runs the API's tests and RuboCop, the Swift build and tests, the app bundle, and the end-to-end runs, listed under "Build, test, and run" below.

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
docker compose build api                             # build the API image
docker compose run --rm api bin/rails test           # tests, against PostgreSQL
docker compose run --rm api bin/rails zeitwerk:check # autoloading
docker compose run --rm -e SEED=1 -e WALKS=1000 api bin/rails test test/engine/step_partition_test.rb  # 1000 random walks
docker compose run --rm --no-deps api bin/rubocop    # style
docker compose up -d                                 # run the API, the sweep, the database and the daily backup (into ./backups)
curl -s http://127.0.0.1:3000/v1/health              # check it answers
docker compose exec -T api bin/rails leverage:verify_log  # replay every workspace's log
docker compose exec -T api bin/rails leverage:recovery_times  # every recovery time
docker compose exec -T api bin/rails leverage:rule_timing  # each rule's runs and times
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
`runner`, `helper`, `services`, `app`, `mcp` or `e2e`. CI builds the
`e2e` lane on Linux, including the MCP server.
When several agents work at once, each builds its own lane in its own
`--scratch-path`, so that a half-written file in one lane never stops
another from compiling.

On a slow machine, such as GitHub's three-core macOS runner, run the tests
one at a time and with more patience, as CI does:

```bash
LEVERAGE_TEST_PATIENCE=4 swift test --no-parallel
```

`LEVERAGE_TEST_PATIENCE` multiplies only the waits for something that must
happen, the ceilings a stand-in or a fake has to answer within, and the
suites' time limits; a limit whose shortness a test checks is never
multiplied. Unset, it is 1.

The whole product, from the repository root (Docker and Swift, nothing
else):

```bash
scripts/e2e_core_loop.sh                             # the whole loop with stand-in tools
scripts/e2e_handoff.sh                               # six interrupted runs, one compose project each
scripts/e2e_rule_checks.sh                           # seven runs with the rules on, one compose project each
scripts/e2e_questions_approvals.sh                   # seven runs with stand-ins, including MCP
scripts/e2e_credentials.sh                          # three stand-in Credentials cases
scripts/restore_drill.sh                             # back up, empty the cluster, restore, replay
scripts/speed_run.sh                                 # 50 seats for 120 s; prints the speed table
scripts/build_app.sh && scripts/smoke_app.sh         # build dist/Leverage.app, open it, check its server
```

Each starts a compose project of its own and removes it, also on failure.
`e2e_handoff.sh` and `restore_drill.sh` also make a backup folder of their
own (mode 1777, sticky) under `TMPDIR`; they use the image `API_IMAGE_TAG` names
when it is set. Anything else that starts the `backup` service, or runs
`bin/backup` or `bin/restore`, exports `LEVERAGE_BACKUP_DIR` to a folder of
its own first, so that nothing writes into the checkout's `./backups`.
`smoke_app.sh` uses a support folder and a compose project of its own
(`leverage-smoke-<pid>`), sets `LEVERAGE_NOTIFICATIONS=off` and
`LEVERAGE_TOKEN_STORE=memory`, signs up a made-up owner (the
backup dumps no database without a workspace) and waits for the first
dump. No automated test calls a real provider: the
tests find the providers' tools only through `LEVERAGE_TOOL_DIR`, on the
stand-ins. `scripts/real_gemini_through_app.sh` runs only with
`LEVERAGE_REAL_PROVIDER=gemini` and never in CI.

A developer check with a real tool already signed in on the Mac, never in
CI, run only by the maintainer or the managing agent of a delegated run:

```bash
LEVERAGE_REAL_PROVIDER=claude scripts/real_provider_run.sh claude   # or codex, gemini, grok
```

It sends one build prompt through the runner's tool driver and proves the
driver's flags only. Its self-test runs in the `e2e` job with stand-in
tools.

The eval suites and the real developer checks reach real tools too, and
are run only by the maintainer or the managing agent of a delegated run,
never in CI, each with its switch set by hand (`LEVERAGE_EVAL_REAL=1`,
`LEVERAGE_REAL_PROVIDER`, with `LEVERAGE_REAL_MCP=1` for the MCP check):

```bash
LEVERAGE_EVAL=specific-details LEVERAGE_EVAL_REAL=1 scripts/eval_rule.sh specific-details
LEVERAGE_EVAL=approves-actions LEVERAGE_EVAL_REAL=1 scripts/eval_rule.sh approves-actions
LEVERAGE_REAL_MCP=1 LEVERAGE_REAL_PROVIDER=claude scripts/real_mcp_run.sh claude
LEVERAGE_REAL_PROVIDER=claude scripts/real_approval_check.sh claude   # or codex, gemini
LEVERAGE_REAL_PROVIDER=claude scripts/real_rule_check.sh claude   # or codex, gemini; gemini --through-app
```

No other agent sets these switches. Against the stand-ins, with
`LEVERAGE_TOOL_DIR` on a copy of `mac/Tests/StandIns/bin` and the switch
unset, anyone may run the offline self-tests above. The eval script with a
stand-in tool directory also takes `--out <folder>`.
How to run and operate it all is in [docs/DEPLOY.md](docs/DEPLOY.md).

## Documentation style

- Markdown, wrapped at about 80 columns, one sentence of purpose at the top of
  every document.
- Write what is true now. Plans go in the PRD or in issues.
- Prefer a short, correct document to a long, speculative one.
