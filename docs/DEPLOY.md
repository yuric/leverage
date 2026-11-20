# Deployment

| | |
|---|---|
| **Status** | One environment: the owner's Mac, where the app starts the server's containers; the Handoff milestone, with the daily backup and the restore |
| **Last updated** | 2026-11-19 |

This document says how to run and operate leverage: how to stand it up from
scratch, check that it works, stop it, and what is not decided yet. It is
written so that someone who has never run leverage can follow it without
help.

leverage runs on the owner's Mac. The Mac app, `Leverage.app`, starts the
server (the API, its timer sweep, its daily backup and PostgreSQL) in
Docker containers, and after the owner signs in it starts the helper, which
runs the agents on the owner's logins. How the parts are packaged is
[ADR 0004](adr/0004-one-app-bundle-for-the-first-run.md). Every command
below was run on an Apple silicon Mac with the pinned versions in
[ADR 0002](adr/0002-pinned-versions-test-tools-and-code-units.md), unless it
says otherwise.

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
the helper and the runner in release mode, and writes `dist/Leverage.app`,
signed ad hoc and not notarized, so it runs on this Mac only.
`scripts/build_app.sh --no-image` builds the bundle without the image (CI
does this). It is meant to be moved anywhere and opened from Finder; so
far it has been opened only by `scripts/smoke_app.sh`, with a Finder-like
environment.

## The first run

1. Open `Leverage.app`. It starts Docker Desktop if needed, writes its
   server folder and starts the containers; the first start takes a few
   seconds once the images are on the Mac.
2. Create the sign-in: an email address and a password of at least 8
   characters. There is no way to recover a forgotten password.
3. In Credentials, choose Add credential, pick a provider, name the login,
   and sign in to the provider's tool when leverage asks. Whether the
   tool's own window opens by itself is not yet known for any provider;
   for Gemini, sign in to Antigravity yourself first, since it has no
   sign-in command. leverage checks that the tool is installed (offering to
   install it where it can), that the login is signed in, and that it
   answers a test prompt.
4. In Agents, choose Connect: a builder on one login and a reviewer on
   another. A seat the app runs starts at once.
5. Choose Add task, fill in the form and save it. The task goes to Ready,
   the builder claims it, the reviewer reviews it, and it reaches Done; the
   task page shows each step in its log.

Agents run only while the app is open. Closing the window keeps them
running; quitting the app stops them. The server's containers keep running
after the app quits.

## Where things live

| What | Where |
| --- | --- |
| The support folder | `~/Library/Application Support/leverage` |
| The server's compose file and its `.env` (database passwords, `SECRET_KEY_BASE`, port, image tag), made once | `<support folder>/server/`, folder mode 0700, files 0600 |
| The containers | Docker Compose project `leverage-app`: services `db`, `api`, `sweep`, `backup` |
| The daily backups | `<support folder>/backups/leverage-<UTC time>.dump`, folder mode 0700, each file 0600 |
| The last Needs you item the app announced | `<support folder>/inbox-cursor`, one number, mode 0600 |
| The API | `http://127.0.0.1:<port>`, the first free port from 47130 to 47139, kept in `API_PORT` in the server folder's `.env` |
| A Claude or Codex login's settings | `<support folder>/accounts/<credential id>/` |
| Tools leverage unpacked | `<support folder>/tools/<provider>/` |
| A task's folder when the task names none | `<support folder>/work/<task id>/` |
| Logs | `<support folder>/logs/helper.log` (the helper) and `logs/seat-<id>.log` (each run); `docker compose -p leverage-app logs api sweep` for the server |
| The owner's session | The login Keychain, service `leverage`, account `owner-session` |

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

The log is lost for good when the volume and the backups folder are both
lost: by deleting the support folder as well, or by losing the Mac's disk.
Nothing copies the dumps off the Mac.

Migrations only go forward from the Core loop milestone on: a release that
changes the schema adds a migration and never rewrites an earlier one.

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
  provider secret is in it: leverage stores none. Keep copies private.
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
token, and in Credentials runs Verify on each login, choosing Sign in again
on any that says it is signed out. Tokens issued after the dump no longer
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
| `LEVERAGE_ONLY` | `mac/Package.swift` | Builds one lane of the package: `kit`, `runner`, `helper`, `services`, `app` or `e2e`. |
| `LEVERAGE_TEST_PATIENCE` | Mac tests | A multiplier, at least 1 (default 1), for the tests' waits and the ceilings handed to the code under test; CI sets 4 on its slow macOS runner. |
| `LEVERAGE_NOTIFICATIONS` | app | `off` keeps the app from asking for or posting a notification; `scripts/smoke_app.sh` sets it. A notification is posted only by the app opened as `Leverage.app`. |
| `LEVERAGE_E2E`, `LEVERAGE_E2E_DIR` | end-to-end tests | Switch the end-to-end tests on (`1` for the core loop's, `handoff` for the six interrupted runs), and the folder each test keeps its files in; `scripts/e2e_core_loop.sh` and `scripts/e2e_handoff.sh` set both. |

The helper's and a seat's tokens, and the run's inputs (among them
`LEVERAGE_CREDENTIAL_ID`, the account the run is on, and
`LEVERAGE_CONTINUE_TASK_ID` or `LEVERAGE_CONTINUE_REVIEW_ID`, the work it
continues), are set by the app and the helper only. Secrets are never committed to this repository; the
values live in `.env` and in the server folder.

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
back to work. No recovery time ceiling is set yet, so it compares nothing
unless given one in `CEILING_SECONDS`.

The checks that cover the whole product, from the repository root:

```bash
scripts/e2e_core_loop.sh
scripts/e2e_handoff.sh
scripts/restore_drill.sh
scripts/build_app.sh && scripts/smoke_app.sh
```

`scripts/e2e_core_loop.sh` starts its own compose project, runs the real
helper and runner with stand-in tools through a task with one failed
review, checks the log and scans for secrets, and removes its project.
`scripts/e2e_handoff.sh` runs six tests, each in a compose project of its
own, in which a stand-in tool meets a limit or a sign-out mid-task: the
work continues on the next account or waits and continues, and the script
checks the log, each recovery time against a working bar of 900 seconds
(not the owner's ceiling, which is not set), scans for secrets and the
reply files' text, and runs the restore drill on the last test's log.
`scripts/restore_drill.sh` alone fills a project of its own with a seeded
log, dumps it, removes the volume and restores into the new cluster.
`scripts/smoke_app.sh` opens the built app with a support folder and a
compose project of its own (`leverage-smoke-<pid>`), notifications off,
waits for the server's health and the first dump, and removes both.

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
sweep's passes and each dump. The Mac side's logs are under
`<support folder>/logs/`. The daily backup is under
[Backups and restore](#backups-and-restore). Metrics, alerts and routine
maintenance are _TBD_.
