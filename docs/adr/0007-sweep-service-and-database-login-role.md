# 0007. The sweep service and the database login role

Status: Accepted

## Context

The Core loop milestone needs three things that run on their own clock: a
lease that ends at its due time, the purge of command keys after 7 days,
and long polls (`GET /v1/next`, the helper's next request, the events tail
and one helper request) that answer as soon as something changes. The PRD
also requires that the event log cannot be changed, and the contract
([ADR 0003](0003-contract-format.md)) left the API connecting as the
database's owner role, which can switch the log's triggers off. A job
runner, or a second database connection setup, is hard to take back once
the server depends on it (rule AR-003).

## Decision

1. **A sweep service, no job runner.** `api/bin/sweep` runs as a second
   service, `sweep`, from the same image as the API (`compose.yaml`). Every
   15 seconds it applies the due timers of every workspace through the
   transition function, in batches of 100, and writes one `sweep_runs` row
   per workspace. On its first pass and then once an hour it also purges
   command keys and `sweep_runs` rows older than 7 days.
   `bin/sweep --once` makes one pass and exits. A command on a task also
   applies that task's due timers first, so a late call is refused before
   the sweep comes round.
2. **Long polls by looking again.** A long poll waits outside any
   transaction, looks again every 250 ms, and gives its database connection
   back between looks (`Leverage::LongPoll`). Nothing is pushed:
   PostgreSQL's `LISTEN` is not used.
3. **Two database roles, chosen by the program.** `db:grants` creates
   `leverage_api`, a login role that is a member of `leverage_app` (which
   cannot change or delete an event or a rule version), with the password
   in `LEVERAGE_API_DB_PASSWORD`; without that variable the role cannot log
   in. `DATABASE_URL` keeps naming the owner role, which migrations,
   `db:prepare`, `db:grants`, every test run and every other command use.
   `api/bin/docker-entrypoint` makes the switch for two programs only: for
   the server and for `bin/sweep` it puts `API_DATABASE_URL` (the
   `leverage_api` role) in place of `DATABASE_URL` when it is set, and
   removes both database passwords from their environment.
4. **Threads and connections.** The `api` service runs 64 Puma threads
   (`RAILS_MAX_THREADS`) over a pool of 32 connections (`DB_POOL`, read by
   `database.yml`'s `max_connections`).

## Alternatives considered

- **Solid Queue or another job runner.** It would add tables, a worker and
  a dependency for three timers that one loop handles.
- **`LISTEN` and `NOTIFY`** for the long polls. Each waiting call would hold
  a connection for its whole wait.
- **The login role in `database.yml`'s production block.** `db:prepare`
  runs in the production environment before the server starts and needs
  the owner role, so the choice belongs to the program being started.

## Consequences

- A lease can outlive its due time by up to one sweep interval when no call
  touches its task; a call that comes first is refused at once.
- The server and the sweep cannot change the event log even if a trigger is
  switched off, once `LEVERAGE_API_DB_PASSWORD` is set (it is in the
  `.env` that `scripts/make_env.py` makes from `.env.example` and in the
  `.env` the app writes). Without it they connect as the owner role.
- Under 50 active seats the wait for the workspace lock is about 1 ms at
  the 95th percentile, and writing events and steps 4.7 ms (2026-11-19;
  [IMPLEMENTATION.md](../IMPLEMENTATION.md#measurements)). The lock is held
  about 6 ms per command, so one workspace takes about 160 commands a
  second before the lock is always busy. Earlier runs showed a wait of 158
  to 347 ms; it came from the speed run's seats all ticking at the same
  instant, not from the server.
