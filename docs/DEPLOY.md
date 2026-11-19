# Deployment

| | |
|---|---|
| **Status** | One environment: the skeleton, run on the owner's Mac |
| **Last updated** | 2026-11-19 |

This document says how to run and operate leverage: how to stand it up from
scratch, check that it works, stop it, and what is not decided yet. It is
written so that someone who has never run leverage can follow it without
help.

Today leverage is a skeleton: the API answers a health check and the Mac
app and helper show that answer. Every command below was run on an Apple
silicon Mac with the pinned versions in
[ADR 0002](adr/0002-pinned-versions-test-tools-and-code-units.md).

## Prerequisites

- A Mac with Docker Desktop installed and running. Ruby is not needed on
  the Mac: every Ruby command runs inside the API container.
- Xcode 26 or later, for Swift 6.2 or later, to build the Mac app and the
  helper. Check with `swift --version`.
- A clone of this repository.

## Configuration

The API and the database read their settings from a `.env` file at the
repository root, which [compose.yaml](../compose.yaml) loads. `.env` is
git-ignored. Make it from the example, then replace the made-up values:

```bash
cp .env.example .env
```

| Variable | Used by | Required | What it does |
| --- | --- | --- | --- |
| `POSTGRES_USER` | db, api | Yes | The PostgreSQL user. compose stops with a message when it is unset. |
| `POSTGRES_PASSWORD` | db, api | Yes | That user's password. Letters, digits and dashes only, because it is put into `DATABASE_URL`. |
| `SECRET_KEY_BASE` | api | Yes | The key Rails signs with. Make one with `openssl rand -hex 64`. |
| `RAILS_ASSUME_SSL` | api | No, default `true` | Set `false` while the API is served over plain HTTP on the Mac. |
| `RAILS_FORCE_SSL` | api | No, default `true` | Set `false` while the API is served over plain HTTP on the Mac. |
| `API_PORT` | compose | No, default `3000` | The port on `127.0.0.1` where the API answers. |

compose sets `DATABASE_URL` for the API from the user and password; each
Rails environment adds its own database name (`leverage_production` for the
server, `leverage_test` for the tests).

The Mac app and the helper read one variable from their environment:

| Variable | Required | What it does |
| --- | --- | --- |
| `LEVERAGE_API_URL` | No, default `http://127.0.0.1:3000` | The API's address. A value that is not an `http` or `https` URL with a host is ignored. |

Secrets are never committed to this repository. Only the names above are
documented here; the values live in `.env` on the Mac.

## Environments

One environment exists: the owner's Mac, as decided in
[ADR 0001](adr/0001-rails-api-postgresql-and-a-mac-client.md) (decisions 8
and 9). The API runs in production mode in a Docker container built from
`api/Dockerfile`, next to a PostgreSQL container, and answers only on
`127.0.0.1`, over plain HTTP. The database is kept in the Docker volume
`leverage_db-data`. The Mac app and the helper are built from `mac/` with
Swift and run on the same Mac.

CI runs the same containers with the example `.env`; see
`.github/workflows/ci.yml`.

The move to a server the owner controls is not decided in detail: _TBD_.

## Deploying

From the repository root, after making `.env`:

```bash
docker compose build
docker compose up -d
```

The first `up` creates the database. To build and run the helper and the
app:

```bash
cd mac
swift build
swift run LeverageHelper
swift run LeverageApp
```

If the API is not on port 3000, give the helper and the app its address,
for example `LEVERAGE_API_URL=http://127.0.0.1:3017 swift run LeverageHelper`.

No second version exists yet, so no upgrade has been tried. How to upgrade
is _TBD_.

## Verifying a deployment

```bash
docker compose ps
curl -s http://127.0.0.1:3000/v1/health
```

`docker compose ps` shows both containers up, the database `healthy`, and
the API's port bound to `127.0.0.1` only. The health check answers
`{"status":"ok","version":"0.1.0"}`; use the port in `API_PORT` if you
changed it. From `mac/`, `swift run LeverageHelper` prints
`API: ok (version 0.1.0)` and exits 0; it exits 1 when the API does not
answer.

The test suites and checks:

```bash
docker compose run --rm api bin/rails test
docker compose run --rm api bin/rubocop
cd mac && swift build && swift test
```

## Stopping and rolling back

```bash
docker compose down
```

stops and removes the containers and keeps the database volume.
`docker compose down --volumes` also deletes the volume, and with it every
row in the database; it cannot be undone.

Only one version exists, so there is nothing to roll back to yet. How to
return to a previous version, and what to do about a migration that cannot
be undone, is _TBD_ until the first migration lands.

## Operations

`docker compose logs api` shows the API's log, which Rails writes to
standard output. Metrics, alerts, backups and routine maintenance are
_TBD_.
