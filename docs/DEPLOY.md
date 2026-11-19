# Deployment

| | |
|---|---|
| **Status** | One environment: the owner's Mac, where the app starts the server's containers; the Core loop milestone |
| **Last updated** | 2026-11-19 |

This document says how to run and operate leverage: how to stand it up from
scratch, check that it works, stop it, and what is not decided yet. It is
written so that someone who has never run leverage can follow it without
help.

leverage runs on the owner's Mac. The Mac app, `Leverage.app`, starts the
server (the API, its timer sweep and PostgreSQL) in Docker containers, and
after the owner signs in it starts the helper, which runs the agents on the
owner's logins. How the parts are packaged is
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
does this). The app can then be moved anywhere and opened from Finder.

## The first run

1. Open `Leverage.app`. It starts Docker Desktop if needed, writes its
   server folder and starts the containers; the first start takes a few
   seconds once the images are on the Mac.
2. Create the sign-in: an email address and a password of at least 8
   characters. There is no way to recover a forgotten password.
3. In Credentials, choose Add credential, pick a provider, name the login,
   and sign in in the provider's own window when it opens. leverage checks
   that the tool is installed (offering to install it where it can), that
   the login is signed in, and that it answers a test prompt.
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
| The containers | Docker Compose project `leverage-app`: services `db`, `api`, `sweep` |
| The API | `http://127.0.0.1:<port>`, the first free port from 47130 to 47139, kept in `API_PORT` in the server folder's `.env` |
| A Claude or Codex login's settings | `<support folder>/accounts/<credential id>/` |
| Tools leverage unpacked | `<support folder>/tools/<provider>/` |
| A task's folder when the task names none | `<support folder>/work/<task id>/` |
| Logs | `<support folder>/logs/helper.log` (the helper) and `logs/seat-<id>.log` (each run); `docker compose -p leverage-app logs api sweep` for the server |
| The owner's session | The login Keychain, service `leverage`, account `owner-session` |

## Where the log is, and what destroys it

The event log and every other record of the workspace are in PostgreSQL, in
the Docker volume `leverage-app_db-data`. **Nothing backs it up yet**: the
daily backup and the tested restore arrive in the Handoff milestone. The log
cannot be rebuilt from anything else. It is lost for good by any of these:

- `docker compose -p leverage-app down --volumes`, or removing the
  `leverage-app` project with its volumes in Docker Desktop;
- `docker volume prune` (or `docker system prune --volumes`) while the
  containers are stopped;
- resetting Docker Desktop to its factory defaults, or uninstalling it.

To copy the database out by hand while the containers run:

```bash
docker exec leverage-app-db-1 pg_dump -U leverage leverage_production > leverage-copy.sql
```

The file holds the whole log; keep it somewhere private. This command has
not been run against an owner's installation.

Migrations only go forward from the Core loop milestone on: a release that
changes the schema adds a migration and never rewrites an earlier one.

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

`up` starts three services: `db`, `api` (it prepares the database first)
and `sweep`, which applies due timers every 15 seconds and purges command
keys older than 7 days once an hour
([ADR 0007](adr/0007-sweep-service-and-database-login-role.md)).

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
| `LEVERAGE_E2E`, `LEVERAGE_E2E_DIR` | end-to-end tests | Switch the end-to-end tests on, and the folder each test keeps its files in; `scripts/e2e_core_loop.sh` sets both. |

The helper's and a seat's tokens, and the run's inputs, are set by the app
and the helper only. Secrets are never committed to this repository; the
values live in `.env` and in the server folder.

## Environments

One environment exists: the owner's Mac, as decided in
[ADR 0001](adr/0001-rails-api-postgresql-and-a-mac-client.md) (decisions 8
and 9). The API runs in production mode in a Docker container built from
`api/Dockerfile`, next to the sweep and a PostgreSQL container, and answers
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

`docker compose ps` shows the three containers up, the database and the API
`healthy`, and the API's port bound to `127.0.0.1` only. The health check
answers `{"status":"ok","version":"0.1.0"}`; use the port in `API_PORT` if
you changed it. `docker compose exec -T api bin/rails leverage:verify_log`
replays the log of every workspace against the tables and prints one line
per workspace.

The checks that cover the whole product, from the repository root:

```bash
scripts/e2e_core_loop.sh
scripts/build_app.sh && scripts/smoke_app.sh
```

`scripts/e2e_core_loop.sh` starts its own compose project, runs the real
helper and runner with stand-in tools through a task with one failed
review, checks the log and scans for secrets, and removes its project.
`scripts/smoke_app.sh` opens the built app with a support folder and a
compose project of its own (`leverage-smoke-<pid>`), waits for the server's
health, and removes both.

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
needs a database copied out before it: _TBD_ until the first upgrade.

## Operations

The server's logs are `docker compose -p leverage-app logs api sweep`: one
`leverage.command` line per command with its timings, and the sweep's
passes. The Mac side's logs are under `<support folder>/logs/`. Metrics,
alerts, backups and routine maintenance are _TBD_; backups arrive in the
Handoff milestone.
