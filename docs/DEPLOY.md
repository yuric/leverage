# Deployment

| | |
|---|---|
| **Status** | One environment on the owner's Mac. The app starts the server's containers, with all seven shipped rules active. Credentials can add, check and manage API tokens. |
| **Last updated** | 2026-11-25 |

This document says how to run and operate Leverage: how to stand it up from
scratch, check that it works, stop it, and what is not decided yet. It is
written so that someone who has never run Leverage can follow it without
help.

Leverage runs on the owner's Mac. The Mac app, `Leverage.app`, starts the
server (the API, its timer sweep, its daily backup and PostgreSQL) in
Docker containers, and after the owner signs in it starts the helper, which
runs the agents on the owner's logins. How the parts are packaged is
[ADR 0004](adr/0004-one-app-bundle-for-the-first-run.md). Every command
below was run on an Apple silicon Mac with the pinned versions in
[ADR 0002](adr/0002-pinned-versions-test-tools-and-code-units.md), unless it
says otherwise.

## Marketing page

[Age of Lever](https://ageoflever.com/) serves the static files in
`marketing-page/`. The `Deploy Age of Lever` workflow checks that the `CI`
and `Docs checks` push runs passed for the same `main` commit before it
publishes. It publishes only when the site's Git tree differs from the last
successful deployment or an interrupted deployment needs repair.

The workflow assumes the `AgeOfLeverGitHubDeploy` IAM role through GitHub
OIDC. Its trust is limited to this repository's immutable `main` subject and
the `Deploy Age of Lever` workflow. The role can manage files in the
`ageoflever-web-sitebucket-wymjk9jfrnqo` bucket and create and check invalidations
on distribution `E2753A9QFGUJ6U`. Long-lived credentials are unnecessary.

GitHub Actions serializes deployments. The publisher uploads assets before
the index, removes retired files, waits for CloudFront invalidation, and
checks that both public HTTPS URLs serve the checked index. It then records
the published Git tree in `.well-known/deployed-marketing-revision`.

To retry an interrupted deployment, run **Deploy Age of Lever** from the
GitHub Actions tab on `main`. A retry still requires successful `CI` and
`Docs checks` push runs for the current `main` commit. Revert a site change
through a pull request to publish the previous contents.

## Prerequisites

- To use the app: a Mac with macOS 14 or later and Docker Desktop
  installed. The app starts Docker Desktop when it is not running, and says
  so when it is not installed. Ruby is never needed on the Mac.
- To build the app, also: Xcode 26 or later (Swift 6.2 or later; check with
  `swift --version`), Docker Desktop running, and a clone of this
  repository. Building needs the network once, for the images.

## Building the app

From the repository root, on the Mac the app will run on:

```bash
scripts/build_app.sh
```

It builds the API image as `leverage-api:<version>` in this Mac's Docker,
pulls the PostgreSQL image `compose.yaml` pins by its digest, builds the app,
the helper, the runner and the MCP server in release mode, and writes `dist/Leverage.app`,
signed ad hoc and not notarized, so it runs on this Mac only.
`scripts/build_app.sh --no-image` builds the bundle without the image (CI
does this). It is meant to be moved anywhere and opened from Finder; so
far it has been opened only by `scripts/smoke_app.sh`, with a Finder-like
environment.

## The first run

Before you add a login, read what the providers' terms say. A login runs
the provider's own tool under your account. A provider may not allow its
tool to be driven by another app, or work to move between two logins of
one provider, and may suspend an account. Google's documents say neither is
supported on consumer plans. The providers' documents were read by AI
agents on 2026-11-18, and not all of them in full, so read your provider's
terms yourself before relying on that reading
([provider terms check](research/provider-terms/README.md),
[PRD Risks](PRD.md#risks)). An API token is the alternative to a login.

1. Open `Leverage.app`. It starts Docker Desktop if needed, writes its
   server folder and starts the containers; the first start takes a few
   seconds once the images are on the Mac.
2. Create the sign-in: an email address and a password of at least 8
   characters. There is no way to recover a forgotten password.
3. In Credentials, choose Add credential, pick a provider, name the login,
   and sign in to the provider's tool when Leverage asks. Whether the
   tool's own window opens by itself for Claude, Codex and Grok remains to be verified;
   for Gemini, sign in to Antigravity yourself first, since it has no
   sign-in command. Leverage checks that the tool is installed (offering to
   install it where it can), that the login is signed in, and that it
   answers a test prompt.
4. In Agents, choose Connect. Choose "Native: run on my login" and pick
   a login. General is selected by default. For a first task with the
   seven shipped rules on, connect two General agents on different
   providers that support review. You can also connect a Builder and a
   Reviewer on different providers, and an Orchestrator that can share
   either login. A seat the app runs starts at once. Rules, at the foot
   of the left pane, lists the rules and turns each on or off.
   Rules > Workspace settings sets the lease length, check timeouts,
   maximum rounds, re-run limit and recovery time ceiling.
5. Choose Add task, fill in the form and save it. The task waits in
   Backlog, "Checking the details", until the orchestrator has checked it;
   then it goes to Ready, the builder claims it, the reviewer reviews it,
   and it reaches Done; the task page shows each step in its log and its
   Timing section. A task the check sends back says why on its card and
   its page.

When a check waits and no seat counts as present for the orchestrator,
the health line and Needs you show the offline state. A General seat
busy building or reviewing cannot take a check. A question goes to the
owner at once when no Orchestrator seat is enabled and no General seat
can take the question now. An outward action waiting for an approval job
goes to the owner after two queue timeouts if the job is never claimed.
The default is four minutes.

The app runs its managed seats while the app is open. Closing the window
keeps those seats running. Quitting the app stops those seats. The server
containers continue to run.

### Connect a seat by prompt

In Agents, choose Connect, select a role and choose
"Prompt: paste into any agent". Choose "By HTTP calls" or "Through MCP" under
How it connects, then connect the seat. Copy the one landing prompt and
paste it into an agent on the same Mac. The prompt contains the seat's
token and the loopback address. It tells the agent to fetch `GET /v1/join`
using that token, then follow the instructions and keep polling for
work. Keep the prompt private. The roster labels
the seat "Connected by prompt."

To give the agent another landing prompt, choose **Remove** in the roster
and connect a new seat. The removed seat's next call answers `401` and the
agent stops. A Working task goes back to Ready, a review is released, and
a held job runs to its timeout. A pending submit, pending pass or provisional
claim is cancelled. Any open approved or started actions on a Finishing task
come to Needs you as "Unconfirmed action".

### Connect a seat through MCP

Choose "Through MCP" when connecting by prompt. The agent first fetches
`GET /v1/join?connection=mcp` over HTTP. The response gives it the
settings to add to its MCP client or ask you to add. The client uses
these settings to start the bundled server and speaks MCP with it over
standard input and output. If the app bundle moves, update the path in
the client's settings.

| Setting | Value |
| --- | --- |
| `command` | The absolute path to `Leverage.app/Contents/MacOS/LeverageMCP` |
| `LEVERAGE_API_URL` | The loopback URL from the landing prompt |
| `LEVERAGE_SEAT_TOKEN` | The token from the landing prompt, passed in the child's environment |
| `LEVERAGE_SEAT_ROLE` | `general`, `builder`, `reviewer`, `planner` or `orchestrator`. If omitted, all agent tools are listed and the API still enforces the seat's role |

The app passes its bundled executable path to the API through Compose
as `LEVERAGE_MCP_COMMAND`. If you start the server from the repository,
set `LEVERAGE_MCP_COMMAND` to the absolute path to `LeverageMCP` before
starting Compose. When the API has no usable path, the join instructions
tell the agent to ask you for it.
Keep any client settings file containing the token readable only by
the owner's Mac account.
[ADR 0014](adr/0014-the-mcp-server-is-a-swift-program-over-standard-input-and-output.md)

### Files a General agent's tool may read

Leverage supplies a General seat with instructions as text in the join
response, build and review briefings and prompts, and job material and
prompts. Both join instructions tell a General agent to disregard earlier
builds and reviews when it takes a job, and to start a fresh context when
the client supports it. The General eval covers only the fresh job prompts
on app-managed default models. Leverage supplies no role file, skill file
or other Markdown file. Your provider's tool can still load its own
instructions. Claude Code may read `CLAUDE.md` in the work folder.
Whether the runner's `--setting-sources user` prevents that is unverified.
Codex reads `AGENTS.md` in the work folder and under `CODEX_HOME`.
Which files Antigravity and Grok Build read from their work or home
folders remains unverified.

## Where things live

| What | Where |
| --- | --- |
| The support folder | `~/Library/Application Support/leverage` |
| The server's compose file and its `.env` (database passwords, `SECRET_KEY_BASE`, port, image tag), made once | `<support folder>/server/`, folder mode 0700, files 0600 |
| The containers | Docker Compose project `leverage-app`: services `db`, `api`, `sweep`, `backup` |
| The daily backups | `<support folder>/backups/leverage-<UTC time>.dump`, folder mode 0700, each file 0600 |
| The last Needs you item the app announced | `<support folder>/inbox-cursor`, one number, mode 0600 |
| Where the owner stands with first-run setup | `<support folder>/setup-progress`, one word, mode 0600 |
| The API | `http://127.0.0.1:<port>`, the first free port from 47130 to 47139, kept in `API_PORT` in the server folder's `.env` |
| A Claude or Codex login's settings | `<support folder>/accounts/<credential id>/` |
| Pending local credential cleanup | `<support folder>/pending-removals/<credential id>`, empty files |
| Tools Leverage unpacked | `<support folder>/tools/<provider>/` |
| A task's folder when the task names none | `<support folder>/work/<task id>/` |
| Logs | `<support folder>/logs/helper.log` (the helper) and `logs/seat-<id>.log` (each run); `docker compose -p leverage-app logs api sweep` for the server |
| The owner's session | The login Keychain, service `leverage`, account `owner-session` |
| The appearance choice | The macOS preferences of the app bundle (`local.leverage.app`), key `appAppearance`; not under the support folder, so `LEVERAGE_SUPPORT_DIR` does not separate it |

After sign-in, the row under the system health line shows the sign-in
email. Open that row to reach Settings or Sign out. The Leverage menu
also offers both actions.

For an API token, choose Add credential, pick an API token provider,
name the credential and paste the token into the secure field. The
bundled helper saves a verified token and its provider in a generic
password item, service `leverage API token`, account the credential ID.
The default macOS setup uses the login Keychain. A custom default or
search list affects where the file-based Security API stores and finds
the item. A rebuilt app may prompt for Keychain access. Tokens stay on
this Mac. If an item has no saved provider, Remove and Add it again.

Remove first deletes the server row and its readings. The app tries to
record the confirmed credential ID in the support folder and sends the
cleanup request to the running helper even if recording fails. The
helper deletes the Keychain item and removes settings folders it can
verify, including private folders made by earlier versions. A folder
whose ownership Leverage cannot verify is kept, as are shared Mac
sign-ins. The app resends pending cleanup when the helper starts. The
helper clears the pending ID after deleting any saved token and either
removing the folder, finding it absent or keeping it because ownership
could not be verified.
Readings are kept with their credential. The sweep deletes finished
and failed read requests after seven days.

## Where the log is, and what destroys it

The event log and every other record of the workspace are in PostgreSQL, in
the Docker volume `leverage-app_db-data`. The log cannot be rebuilt from
anything else. The `backup` service dumps the whole database once a day
into `<support folder>/backups`, a folder outside Docker
([Backups and restore](#backups-and-restore)). So the volume is lost by any
of these, and the log can then be restored from the newest dump made
before the loss, losing what was written after it (at most a day). Check
the dump's time and size: the backup makes no dump of a database that
holds no workspace, so the volume's loss alone adds no dump, but once the
owner signs up again on the new database its dumps are small and newer:

- `docker compose -p leverage-app down --volumes`, or removing the
  `leverage-app` project with its volumes in Docker Desktop;
- `docker volume prune` (or `docker system prune --volumes`) while the
  containers are stopped;
- resetting Docker Desktop to its factory defaults, or uninstalling it.

Delete content clears the live database. Existing dumps follow their
normal retention and can hold older task content.

The log is lost for good when the volume and the backups folder are both
lost: by deleting the support folder as well, or by losing the Mac's disk.
Nothing copies the dumps off the Mac.

Migrations only go forward from the Core loop milestone on: a release that
changes the schema adds a migration and never rewrites an earlier one.

The App round 1 migration folds each task's old goal into its details
before dropping the goal column. For the handling of empty or duplicate
text, see [UI-1](../api/contract/decisions.md#app-round-1-ui).

Each time the server starts, after the database is prepared,
`bin/rails leverage:install_shipped_rules` writes the seven shipped rules
of any workspace that has none. On upgrade it also moves an unchanged
"Every task needs specific details" rule from its previous shipped default
to the new default. The upgrade preserves the rule's switch setting and
any owner edits. See [Shipped rules](PRD.md#shipped-rules). The command
prints one line per workspace it changed. The rules are part of every
briefing, so an agent whose briefing changed is told at its next call
and reads it again. Then `bin/rails leverage:install_imaginarium_project`
creates the Imaginarium project of any workspace that has none, once, and
prints one line per workspace it wrote.

## Backups and restore

How the backup and the restore are built is
[ADR 0010](adr/0010-daily-backup-and-restore.md).

- **What runs.** The `backup` service starts once the API is healthy and
  looks every 15 minutes. When no dump is newer than `BACKUP_EVERY_HOURS`
  (24) it writes `leverage-<UTC time>.dump` (`pg_dump`, custom format) into
  the folder mounted at `/backups`, mode 0600, and records it in the
  `backup_runs` table. While the database holds no workspace (a new one,
  before the owner signs up, or one whose volume was lost) it makes no dump,
  says so once in its log ("The database holds no workspace yet"), and
  looks again every 30 seconds, so the first dump follows the owner's
  sign-up within a minute.
- **A dump now.** `docker compose exec backup bin/backup --once` (for the
  app: `dc exec backup bin/backup --once`, with `dc` as under
  [Restoring](#restoring)) makes one dump at once, prints its file name and
  exits non-zero if it failed.
- **Where.** For the app, `<support folder>/backups`, which the app makes
  with mode 0700 and names in `LEVERAGE_BACKUP_DIR` in its server folder's
  `.env`. For a server started from the repository, the folder in
  `LEVERAGE_BACKUP_DIR` (`./backups` in `.env.example`, git-ignored).
- **How many.** The newest `BACKUP_KEEP` (14) dumps that `backup_runs`
  names are kept; older ones are deleted with their row. A file in the
  folder that no `backup_runs` row names is never deleted, so a dump
  copied in by hand stays.
- **What is in a dump.** The whole database: the owner's email and
  password digest, account names, every task's text and the event log. No
  provider secret is in it: Leverage stores none. Keep copies private.
- **Is it running.** The health line at the foot of the app's left pane
  says "The daily backup is late" when the newest dump is older than 26
  hours, or when there is none an hour after the workspace was made.
  `docker compose -p leverage-app logs backup` shows each dump.
- **On Linux.** The image runs as uid 1000, which must be able to write the
  folder; Docker on the Mac allows it whatever the folder's owner. On a
  Linux host make the folder that user's first:

  ```bash
  mkdir -p /srv/leverage/backups && sudo chown 1000:1000 /srv/leverage/backups && chmod 0700 /srv/leverage/backups
  ```

  The scripts in this repository make theirs with mode 1777 instead (any
  user may write, only a file's owner may rename or remove it) and
  read a dump only from inside a container. A Linux host has run this only
  in CI's `e2e` job.

### Restoring

A restore is the maintainer's command, in a terminal; there is no restore
in the app. `bin/restore` runs in the `backup` service, which has the
folder and the database's owner role. It refuses to replace a database
whose log holds an event unless given `--replace`; otherwise it checks
that `pg_restore` can read the dump, restores it into a new database
beside the one it replaces (`<name>_restoring_<hex>`), gives the database
roles their rights again (`db:grants`) and runs the replay test
(`leverage:verify_log`) there, and only then drops the database and gives
the new one its name. A dump that cannot be restored, or whose log fails
the replay test, or a database that cannot be dropped, leaves the database
as it was and removes the new one. If the database was dropped and the
new one could not take its name, the message names the new one, to rename
by hand. It exits 0 only when every
step passed, 1 when it refused or a step failed (its message says which),
and 2 when it was called wrongly.

For a server started from the repository, with the dump's file name from
the backups folder:

```bash
docker compose stop api sweep backup
docker compose run --rm --no-deps backup bin/restore /backups/<file> --replace
docker compose up -d
```

Leave out `--replace` when the database is new or empty, as after its
volume was lost; then start `db` alone first (`docker compose up -d db`).
`scripts/restore_drill.sh` runs exactly that case: a log, a dump, the
volume removed, the restore into the new, empty cluster, and the same
count, highest position and checksum of the events afterwards. It then
removes the volume again, starts every service on the empty cluster as
the app does, checks that the backup made no dump of it, and restores the
same dump again.

For the app, quit `Leverage.app` first so that it does not start the
services again, and run the same three lines with the app's own files:

```bash
server="$HOME/Library/Application Support/leverage/server"
dc() { docker compose --project-directory "$server" -f "$server/compose.yaml" -p leverage-app "$@"; }
dc stop api sweep backup
dc run --rm --no-deps backup bin/restore /backups/<file> --replace
dc up -d
```

These app-form lines have not been run against an owner's installation;
the drill runs the repository's form.

**Afterwards, the owner** opens the app, which issues the helper a new
token. In Credentials the owner runs Verify all and chooses Sign in again
for any login that needs it. A provider token missing from this Mac needs
to be removed and added again. Leverage tokens issued after the dump no longer
match, and the log holds nothing written after the dump. The app finds by
itself that the Needs you cursor it keeps (`<support folder>/inbox-cursor`)
is of the log before the restore, starts it again, and announces every
open item once more. The health line's last backup time, and which dumps
pruning may delete, come from the restored database's `backup_runs`: they
know only the dumps made before the dump that was restored, so dumps made
after it are kept until removed by hand.

## Running the server without the app

This is the developer's path, from the repository root. The API and the
database read their settings from a `.env` file at the root, which
[compose.yaml](../compose.yaml) loads. `.env` is git-ignored. Make it from
the example, then replace the made-up values:

```bash
cp .env.example .env
docker compose build
docker compose up -d
```

`up` starts four services: `db`, `api` (it prepares the database first),
`sweep`, which applies due timers every 15 seconds and purges command keys
older than 7 days once an hour
([ADR 0007](adr/0007-sweep-service-and-database-login-role.md)), and
`backup`, the daily dump ([Backups and restore](#backups-and-restore)).

| Variable | Used by | Required | What it does |
| --- | --- | --- | --- |
| `POSTGRES_USER` | db, api, sweep | Yes | The PostgreSQL user, the database's owner role. compose stops with a message when it is unset. |
| `POSTGRES_PASSWORD` | db, api, sweep | Yes | That user's password. Letters, digits and dashes only, because it is put into `DATABASE_URL`. |
| `LEVERAGE_API_DB_PASSWORD` | api, sweep | No | The password of `leverage_api`, the login role the server and the sweep connect as; it cannot change the event log. Letters, digits and dashes only. Empty: they connect as `POSTGRES_USER`. |
| `SECRET_KEY_BASE` | api, sweep | Yes | The key Rails signs with. Make one with `openssl rand -hex 64`. |
| `RAILS_ASSUME_SSL` | api, sweep | No, default `true` | Set `false` while the API is served over plain HTTP on the Mac. |
| `RAILS_FORCE_SSL` | api, sweep | No, default `true` | Set `false` while the API is served over plain HTTP on the Mac. |
| `API_PORT` | compose | No, default `3000` | The port on `127.0.0.1` where the API answers. |
| `API_IMAGE_TAG` | compose | No, default `local` | The tag of the image `leverage-api:<tag>`. |
| `RAILS_MAX_THREADS` | api | No, default `64` | Puma's threads. |
| `DB_POOL` | api | No, default `32` | The database connections those threads share. |
| `LEVERAGE_BACKUP_DIR` | compose | No, default `./backups` | The folder on the host the `backup` service writes its dumps into, mounted at `/backups`. |
| `BACKUP_KEEP` | backup | No, default `14` | How many dumps are kept. |
| `BACKUP_EVERY_HOURS` | backup | No, default `24` | How old the newest dump may be before the next is made. |

compose sets `DATABASE_URL` from the user and password (the owner role, for
migrations, tests and every other command) and `API_DATABASE_URL` from
`LEVERAGE_API_DB_PASSWORD`; `api/bin/docker-entrypoint` puts the second in
place of the first for the server and the sweep only. Each Rails environment
adds its own database name (`leverage_production` for the server,
`leverage_test` for the tests).

`compose.test.yaml` is for automated runs only. Used together with
`compose.yaml`, it lets Docker pick a free port for the API:

```bash
docker compose -f compose.yaml -f compose.test.yaml up -d db api
docker compose -f compose.yaml -f compose.test.yaml port api 3000
```

The Mac-side programs read their settings from their environment; each name
is in `mac/Sources/LeverageKit/EnvironmentKeys.swift`. The ones a person
sets:

| Variable | Read by | What it does |
| --- | --- | --- |
| `LEVERAGE_API_URL` | helper, runner, tests | The API's address, default `http://127.0.0.1:3000`. A value that is not an `http` or `https` URL with a host is ignored. |
| `LEVERAGE_SUPPORT_DIR` | app, helper | Replaces `~/Library/Application Support/leverage`. |
| `LEVERAGE_COMPOSE_PROJECT` | app | The compose project, default `leverage-app`. |
| `LEVERAGE_SESSION_STORE` | app | `memory` keeps the owner's session out of the Keychain. |
| `LEVERAGE_TOOL_DIR` | helper | When set, the only folder searched for providers' tools (the stand-ins in tests). |
| `LEVERAGE_ONLY` | `mac/Package.swift` | Builds one lane of the package: `kit`, `runner`, `helper`, `services`, `app`, `mcp` or `e2e`. |
| `LEVERAGE_TEST_PATIENCE` | Mac tests | A multiplier, at least 1 (default 1), for the tests' waits and the ceilings handed to the code under test; CI sets 4 on its slow macOS runner. |
| `LEVERAGE_NOTIFICATIONS` | app | `off` keeps the app from asking for or posting a notification; `scripts/smoke_app.sh` sets it. A notification is posted only by the app opened as `Leverage.app`. |
| `LEVERAGE_E2E`, `LEVERAGE_E2E_DIR` | end-to-end tests | Switch the end-to-end tests on (`1` for the core loop's, `handoff` for the six interrupted runs, `rule_checks` for the eight rule-check runs, `questions_approvals` for the seven questions-and-approvals runs, `credentials` for the three Credentials cases), and the folder each test keeps its files in; `scripts/e2e_core_loop.sh`, `scripts/e2e_handoff.sh`, `scripts/e2e_rule_checks.sh`, `scripts/e2e_questions_approvals.sh` and `scripts/e2e_credentials.sh` set both. |
| `LEVERAGE_EVAL`, `LEVERAGE_EVAL_REAL` | `LeverageRunner eval`, `scripts/eval_rule.sh` | The eval suite's name, without which neither runs, and `1` for a run on the real tools, which only the maintainer sets, by hand ([Eval suites and real checks](#eval-suites-and-real-checks)). |

The helper's and a seat's tokens, and the run's inputs (among them
`LEVERAGE_CREDENTIAL_ID`, the account the run is on, and
`LEVERAGE_CONTINUE_TASK_ID` or `LEVERAGE_CONTINUE_REVIEW_ID`, the work it
continues), are set by the app and the helper for seats the app runs.
For seats that connect through MCP, the client passes the seat token from
its settings. Secrets stay out of this repository.

## Environments

One environment exists: the owner's Mac, as decided in
[ADR 0001](adr/0001-rails-api-postgresql-and-a-mac-client.md) (decisions 8
and 9). The API runs in production mode in a Docker container built from
`api/Dockerfile`, next to the sweep, the backup and a PostgreSQL container, and answers
only on `127.0.0.1`, over plain HTTP. The app's database is the volume
`leverage-app_db-data`; a server started from the repository uses
`leverage_db-data`.

CI runs the same containers with the example `.env`, and the whole loop with
stand-in tools on Linux; see `.github/workflows/ci.yml`.

The move to a server the owner controls is not decided in detail: _TBD_.

## Verifying a deployment

For the app: the health line at the foot of the window's left pane says
"System is running". For a server started from the repository:

```bash
docker compose ps
curl -s http://127.0.0.1:3000/v1/health
```

`docker compose ps` shows the four containers up, the database and the API
`healthy`, and the API's port bound to `127.0.0.1` only. The health check
answers `{"status":"ok","version":"0.1.0"}`; use the port in `API_PORT` if
you changed it. `docker compose exec -T api bin/rails leverage:verify_log`
replays the log of every workspace against the tables and prints one line
per workspace, and `docker compose exec -T api bin/rails
leverage:recovery_times` prints how long each interrupted run took to get
back to work. It compares intervals with the workspace's recovery time
ceiling when set. `CEILING_SECONDS` overrides that value for the command.
`docker compose exec -T api
bin/rails leverage:rule_timing` prints each rule's checks: how often it
ran, its queue and run times, the time it held tasks up, its tokens and
reported spend, and how often a check was let through; ids only, no rule's
name or words.

The checks that cover the whole product, from the repository root:

```bash
scripts/e2e_core_loop.sh
scripts/e2e_handoff.sh
scripts/e2e_rule_checks.sh
scripts/e2e_questions_approvals.sh
scripts/e2e_credentials.sh
scripts/restore_drill.sh
scripts/build_app.sh && scripts/smoke_app.sh
```

`scripts/e2e_core_loop.sh` exercises a task with one failed review using
the real helper and runner with stand-in tools. It also tests a
prompt-connected agent that fetches its instructions, takes a task to
Done with a second seat, and gives a second task back when removed. Four
Prompt cases cover reporting a model and effort to the roster, adding a
Ready task as a seat, offering a Ready task only to the seat with Deliver
on, and giving back a Working task when Deliver turns off.
The script checks the log and scans for secrets in its own compose
project, then removes the project.
`scripts/e2e_handoff.sh` runs six tests, each in a compose project of its
own, in which a stand-in tool meets a limit or a sign-out mid-task: the
work continues on the next account or waits and continues, and the script
checks the log, each recovery time against a working bar of 900 seconds
(not the owner's ceiling, which is not set), scans for secrets and the
reply files' text, and runs the restore drill on the last test's log.
`scripts/e2e_rule_checks.sh` runs eight tests, each in a compose project of
its own with the shipped rules on and stand-in tools answering the checks.
It covers a task from the form to Done with dedicated roles, a vague task
sent back for details, a custom rule that blocks a submit, a fourth try
that waits for the owner to let it through, the orchestrator stopped and
started again, the provider rule, a drafted contract, and a task from the
form to Done with two General agents. Each test checks the log, prints
each rule's timing, and scans events and logs for secrets, markers and
the test's task text.
`scripts/e2e_questions_approvals.sh` exercises questions, outward actions,
project budgets and the built MCP server with stand-ins. Each of seven
cases runs in its own project and checks replay, audit and the secret scan.
`scripts/e2e_credentials.sh` runs Add and usage, API tokens, and reorder
and capacity in three separate projects with stand-ins. Each checks replay,
the audit and the secret scan. The reorder case also checks recovery times.
`scripts/restore_drill.sh` alone fills a project of its own with a seeded
log, dumps it, removes the volume and restores into the new cluster.
`scripts/smoke_app.sh` opens the built app with a support folder and a
compose project of its own (`leverage-smoke-<pid>`), notifications off and tokens in memory,
waits for the server's health and the first dump, checks that sign-up
wrote the seven shipped rules and that a second start of the server wrote
none again, and removes both.

A developer check with a provider's real tool, never in CI, proves the
runner's command-line flags against a tool already installed and signed in
on the Mac, and nothing else:

```bash
LEVERAGE_REAL_PROVIDER=claude scripts/real_provider_run.sh claude   # or codex, gemini, grok
```

It needs the tool on `PATH`, signed in, and Swift. It builds the runner's
Swift code and sends one short build prompt through the runner's tool
driver in a new empty folder, after the tool's version command and, where
the provider has one, its status command; that spends a little of the
login's quota. Nobody signs in during the check. It prints the outcome and
exits 0 when it passed, 1 when it failed, 2 when it refused to start (`CI`
set, or `LEVERAGE_REAL_PROVIDER` not the provider named), 3 when it was
skipped because the tool is not installed, and 4 when it was skipped
because the tool is not signed in. `--evidence <file>` also writes the
result to a file, and `--timeout` limits the tool run (300 seconds by
default).

### Credential reader settings

| Setting | Effect |
| --- | --- |
| `LEVERAGE_TOKEN_STORE=memory` | The helper uses a process-local vault. Smoke and stand-in runs set this. Unbundled developer helpers use memory by default. |
| `LEVERAGE_READ_TIMEOUT_SECONDS` | One usage read's ceiling, from 1 to 15 seconds. Invalid or absent values use 15. |
| `LEVERAGE_PROVIDER_API_BASE` | Test-only provider endpoint on IPv4 loopback. The unbundled helper accepts only marked stand-in tokens through this override. The bundled helper refuses it. |

A developer launch of the app bundle uses `LEVERAGE_TOKEN_STORE=memory`
to exercise the same local channel without storing tokens. The app passes
that setting to its helper. The read timeout and provider endpoint
override are settings for direct helper runs. The app uses the default
timeout and the catalog endpoints. The maintainer's separately guarded
`scripts/capture_reader_reply.py` developer check uses a signed-in tool to
record scrubbed structure outside the repository. Its self-test uses
stand-ins. The evidence for each login is in
[Implementation progress](IMPLEMENTATION.md#credentials-readers-and-recordings).

### Eval suites and real checks

The evals and developer checks below reach a real tool already signed in
on the Mac. Each
is the maintainer's, never runs in CI, refuses to start (exit 2) when `CI`
is set, and runs on a real tool only with its switch set by hand:

```bash
LEVERAGE_EVAL=specific-details LEVERAGE_EVAL_REAL=1 scripts/eval_rule.sh specific-details
LEVERAGE_EVAL=approves-actions LEVERAGE_EVAL_REAL=1 scripts/eval_rule.sh approves-actions
LEVERAGE_REAL_MCP=1 LEVERAGE_REAL_PROVIDER=claude scripts/real_mcp_run.sh claude
LEVERAGE_REAL_PROVIDER=claude scripts/real_approval_check.sh claude   # or codex, gemini
LEVERAGE_REAL_PROVIDER=claude scripts/real_rule_check.sh claude   # or codex, gemini
LEVERAGE_REAL_PROVIDER=gemini scripts/real_rule_check.sh gemini --through-app
```

`scripts/eval_rule.sh` runs the 24 cases of `evals/specific-details/` on
each supported tool's default model, scores them against the bar and
writes the results, `runs.json` and `RESULTS.md` into the suite's folder
([ADR 0013](adr/0013-eval-suites-for-rules-a-model-judges.md)). It spends
up to 30 tool runs per model, keeps the count in `runs.json`, and refuses
(exit 3) a run past three per model, 90 tool runs per model or 270 in all.
`LEVERAGE_EVAL_PROVIDERS` names fewer providers (default `claude codex
gemini`), and `LEVERAGE_EVAL_CODEX_HOME` chooses another folder Codex is
already signed in to. It signs in to nothing. With `LEVERAGE_TOOL_DIR` on
a copy of the stand-in tools in place of `LEVERAGE_EVAL_REAL`, and
`--out <folder>`, anyone may run it; nothing then reaches a provider.

`scripts/real_rule_check.sh` starts the containers under a project of
its own, connects one orchestrator on the named provider (for
`--through-app`, a Gemini login added through Add credential, which the
helper starts), completes two contracts from the suite, one specific and
one vague, and passes when the first is Ready and the second is held for
details within 5 minutes, the log replays and the secret scan finds
nothing: two tool runs. It exits 3 when the tool is not installed.

The approval suite uses 30 main cases and reserves 10 held-out cases for
a wording change under the suite's run rules. The results bind to the
instruction, case set and orchestrator role file. CI checks both suites
offline and compares the registry with the providers that met both bars.
[Approval suite](../evals/approves-actions/README.md)

`scripts/real_mcp_run.sh` checks one Claude Code task to Done over MCP with
a stand-in reviewer. `scripts/real_approval_check.sh` checks an approval
and a stop or owner handoff with a real orchestrator and a stand-in
builder and reviewer. The approved action writes a line to a temporary
test file. Both checks replay the log and scan for secrets. The scripts
accept `LEVERAGE_E2E_SCRATCH` to reuse a Swift build directory.
`LEVERAGE_MCP_CHECK_OUT` selects where the MCP check saves its verified
event list and replay result. `LEVERAGE_APPROVAL_CHECK_OUT` selects where
the approval check saves audited event IDs, task states and replay output.
The outcomes are in [Measurements](IMPLEMENTATION.md#measurements).

## Stopping and rolling back

Quit the app to stop the helper and the agents. To stop the server's
containers and keep the database:

```bash
docker compose -p leverage-app stop
```

For a server started from the repository, `docker compose down` stops and
removes the containers and keeps the volume. `down --volumes` also deletes
the volume, and with it every row in the database, the log included; it
cannot be undone.

Only one version exists, so there is nothing to roll back to yet. Migrations
only go forward, so returning to an earlier version after a schema change
needs a dump made before it ([A dump now](#backups-and-restore)), restored
as under [Restoring](#restoring); the steps of an upgrade are _TBD_ until
the first one.

## Operations

The server's logs are `docker compose -p leverage-app logs api sweep
backup`: one `leverage.command` line per command with its timings, the
sweep's passes and each dump. A request's logged parameters keep only
ids, numbers and true or false; every other text, task text among it, is
`[FILTERED]`. The Mac side's logs are under
`<support folder>/logs/`. The daily backup is under
[Backups and restore](#backups-and-restore). Metrics, alerts and routine
maintenance are _TBD_.
