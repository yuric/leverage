# 0010. Daily backup and restore

Status: Accepted

## Context

The event log cannot be rebuilt from anything else, and the PRD requires a
daily backup and a restore that is tested before release. The database is
PostgreSQL in a Docker volume on the owner's Mac
([ADR 0007](0007-sweep-service-and-database-login-role.md)); resetting
Docker Desktop or removing the volume destroys it. A dump holds the
owner's email and password digest, account names and every task's text,
and no provider secret. Where the dumps go, which program writes them,
which database role it uses and how a restore is made are hard to change
once an owner relies on them (rule AR-003). The decisions are the
milestone's plan HB-1 to HB-8.

## Decision

1. **A fourth service, `backup`.** `compose.yaml` runs `api/bin/backup`
   from the API's image, with the API's environment, after `api` is
   healthy, restarting unless stopped. It is not part of the sweep: a dump
   must not delay timers, and only this service has the backup folder
   mounted (HB-1).
2. **The owner role.** The service connects as the database's owner role,
   which `DATABASE_URL` already names in every container of the image:
   `pg_dump` must read every table and sequence whatever a later migration
   adds, and a restore must drop and create the database. The connection
   is read from `ActiveRecord::Base.connection_db_config` and passed to the
   PostgreSQL tools as `--host`, `--port`, `--username` and `--dbname`, with
   the password in `PGPASSWORD`, never in an argument (HB-1).
3. **A folder on the host.** The dumps go to a folder outside Docker's
   volumes, bind-mounted at `/backups` from `LEVERAGE_BACKUP_DIR`: the
   app's `<support folder>/backups` (mode 0700), `./backups` for a
   developer's own run, and a new folder of its own for every script and
   test. On Linux the folder must be writable by uid 1000, the image's user
   (HB-2).
4. **One dump a day, the newest 14 kept.** `bin/backup` looks when it
   starts and then every 15 minutes; when no `backup_runs` row is newer
   than `BACKUP_EVERY_HOURS` (24) it runs `pg_dump --format=custom
   --no-owner --no-privileges` into a `.partial` file opened with mode 0600, renames
   it to `leverage-<UTC time>.dump`, writes one `backup_runs` row and
   prunes. Pruning deletes only files that this database's `backup_runs`
   rows name, beyond the newest `BACKUP_KEEP` (14); a file no row names is
   never touched. A failed dump leaves no file and no row and is tried at
   the next look. `bin/backup --once` makes one dump and exits non-zero if
   it fails (HB-3).
5. **`backup_runs` is the record.** One row per dump (ran at, file name,
   size), with no workspace, because a dump is of the whole database and
   the first one is made before an owner exists. The application's role
   may only read it. `get_system_health` reports the last dump's time and
   `backup_late`, true when the newest row is older than 26 hours or when
   there is none and the workspace is older than an hour (HB-4).
6. **`bin/restore` makes the database again.** Run in the `backup` service
   by the maintainer, with the API, the sweep and the backup stopped. It
   refuses to replace a database whose `events` table holds a row unless
   given `--replace`; drops and creates the database; runs `pg_restore
   --no-owner --no-privileges --exit-on-error` into the empty database;
   gives the roles their rights again (`db:grants`); and runs
   `leverage:verify_log`. It exits 0 only when every step passed, the
   replay test included; 1 on a refusal or a failed step; 2 on wrong use
   (HB-5).
7. **The restore is tested three times.** `backup_restore_test.rb` in the
   `api` job restores a committed log into a database that does not exist
   yet; `scripts/restore_drill.sh` restores a seeded log into a cluster
   whose volume was removed, which has no database and no `leverage_app`
   role; and `scripts/e2e_handoff.sh` runs the same drill on the log of its
   last test, which holds this milestone's events (HB-6).

## Alternatives considered

- **A second Docker volume.** The same reset of Docker Desktop that
  destroys the database's volume destroys it.
- **The backup in the sweep.** A dump of minutes would hold up the timers.
- **The backup as `leverage_api`** with a right to insert into
  `backup_runs`. That role has no right to read every sequence, and cannot
  drop or create a database.
- **A status file in place of `backup_runs`.** A second persistence
  mechanism beside Active Record (rule AR-006).
- **A copy off the Mac.** Not built; it belongs with the move to a server.

## Consequences

- A dump survives the loss of Docker's volumes, but not the loss of the
  Mac's disk: nothing copies it elsewhere.
- `pg_dump` keeps each object's owner in a custom-format archive even with
  `--no-owner`; the restore's `--no-owner` drops them, and the archive
  holds no `GRANT` or `REVOKE`.
- After a restore, tokens issued after the dump no longer match: the app
  issues the helper a new token at its next start, and the owner verifies
  each account and signs in again where needed (HB-7).
- A restore is a terminal command for the maintainer; the owner cannot
  restore from inside the app.
