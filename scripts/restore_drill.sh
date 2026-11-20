#!/usr/bin/env bash
# The restore drill (milestone 3 plan §5.3, HB-6): proves that a backup
# made by bin/backup restores, with bin/restore, into a cluster whose
# volume was removed (no database, no leverage_app role), and that the
# restored log is the same log and passes the replay test.
#
#   scripts/restore_drill.sh
#       makes a backup folder of its own (mode 0777, under TMPDIR), starts
#       db and api in a compose project of its own and fills it with
#       bin/rails runner script/drill/seed.rb.
#   scripts/restore_drill.sh --from-project <name>
#       uses a compose project that is up and holds a log, and the backup
#       folder it was started with, which LEVERAGE_BACKUP_DIR must name.
#
# Then: stops api, sweep and backup and reads three figures of the events
# (count, highest seq, an MD5 over every id in seq order); makes one
# backup; removes the project's volumes; starts db alone and restores the
# newest dump; reads the figures again and compares; starts api and asks
# whether an owner exists. The project is removed at the end, also on
# failure, with the folder the drill made itself (the caller's folder is
# left in place).
#
# Every compose call names both files and the project, so api is never
# published on a fixed port. A dump's name and mode are read only from
# inside a container: on Linux the file belongs to uid 1000, not to the
# user running this script. API_IMAGE_TAG picks the image, as for compose.
set -euo pipefail

cd "$(dirname "$0")/.."
for file in compose.yaml compose.test.yaml; do
  if [ ! -f "$file" ]; then
    echo "restore_drill: $file is missing" >&2
    exit 2
  fi
done

usage() {
  echo "Usage: scripts/restore_drill.sh [--from-project <name>]" >&2
}

from_project=""
case "$#" in
  0) ;;
  2)
    if [ "$1" != "--from-project" ] || [ -z "$2" ]; then
      usage
      exit 2
    fi
    from_project=$2
    ;;
  *)
    usage
    exit 2
    ;;
esac

DATABASE=leverage_production
image="leverage-api:${API_IMAGE_TAG:-local}"
own_folder=false
folder=""

if [ -n "$from_project" ]; then
  project=$from_project
  folder=${LEVERAGE_BACKUP_DIR:?restore_drill: with --from-project, LEVERAGE_BACKUP_DIR must name the folder the project was started with}
else
  project="leverage-drill-$$"
  folder=$(mktemp -d "${TMPDIR:-/tmp}/leverage-drill.XXXXXX")
  own_folder=true
  chmod 0777 "$folder"
fi
export LEVERAGE_BACKUP_DIR="$folder"

C() { docker compose -f compose.yaml -f compose.test.yaml -p "$project" "$@"; }

step() { echo "restore_drill: $*"; }
fail() {
  echo "restore_drill: FAILED: $*" >&2
  exit 1
}

cleanup() {
  local status=$?
  C down --volumes --remove-orphans >/dev/null 2>&1 || true
  if $own_folder && [ -d "$folder" ]; then
    # The dumps may belong to uid 1000: remove them as that user first.
    docker run --rm --entrypoint "" -v "$folder:/backups" "$image" \
      find /backups -mindepth 1 -delete >/dev/null 2>&1 || true
    rm -rf "$folder"
  fi
  if [ "$status" -eq 0 ]; then
    step "passed"
  fi
  exit "$status"
}
trap cleanup EXIT

# One SQL query through the db container, as the cluster's owner role.
query() {
  # shellcheck disable=SC2016 # expanded by the container's shell
  C exec -T db sh -c 'psql -U "$POSTGRES_USER" -d "$1" -AtX -v ON_ERROR_STOP=1 -c "$2"' sh "$1" "$2"
}

figures() {
  query "$DATABASE" "SELECT count(*) || ' ' || coalesce(max(seq), 0) || ' ' || \
md5(coalesce(string_agg(id::text, ',' ORDER BY seq, id), '')) FROM events"
}

if [ -z "$from_project" ]; then
  step "starting db and api in project $project, backups in $folder"
  C up -d --wait db api
  step "filling the database"
  C run --rm --no-deps api bin/rails runner script/drill/seed.rb
fi

# 1. Nothing writes while the drill measures.
step "1. stopping api, sweep and backup"
C stop api sweep backup
before=$(figures)
read -r count _seq _md5 <<<"$before"
[ "$count" -gt 0 ] || fail "the database holds no event to restore"
runs_before=$(query "$DATABASE" "SELECT count(*) FROM backup_runs")
step "events before: $before; backup_runs rows: $runs_before"
if [ -n "$from_project" ] && [ "$runs_before" -lt 1 ]; then
  fail "the project's backup service made no dump when it started"
fi

# 2. One backup.
step "2. bin/backup --once"
C run --rm --no-deps backup bin/backup --once
runs_after=$(query "$DATABASE" "SELECT count(*) FROM backup_runs")
[ "$runs_after" -eq $((runs_before + 1)) ] || fail "backup_runs went from $runs_before to $runs_after rows"
dump=$(query "$DATABASE" "SELECT file_name FROM backup_runs ORDER BY ran_at DESC, id DESC LIMIT 1")
[[ "$dump" =~ ^leverage-[0-9]{8}T[0-9]{9}Z\.dump$ ]] || fail "the newest row names an unexpected file: $dump"
# shellcheck disable=SC2016 # expanded by the container's shell
mode=$(C run --rm --no-deps --entrypoint "" backup sh -c \
  'test -f "/backups/$1" && test ! -e "/backups/$1.partial" && stat -c %a "/backups/$1"' sh "$dump") ||
  fail "$dump is not in the folder, or a partial file is beside it"
mode=${mode//[$'\r\n']/}
[ "$mode" = "600" ] || fail "$dump has mode $mode, not 600"
step "the newest dump is $dump, mode $mode"

# 3. The database, the cluster and its roles are gone.
step "3. removing the project's volumes"
C down --volumes

# 4. A new cluster, and the restore.
step "4. starting db alone, and restoring"
C up -d --wait db
[ "$(query postgres "SELECT count(*) FROM pg_database WHERE datname = '$DATABASE'")" = "0" ] ||
  fail "the new cluster already has $DATABASE"
[ "$(query postgres "SELECT count(*) FROM pg_roles WHERE rolname = 'leverage_app'")" = "0" ] ||
  fail "the new cluster already has the role leverage_app"
C run --rm --no-deps backup bin/restore "/backups/$dump" || fail "bin/restore exited non-zero"

# 5. The same log, and an API that answers from it.
after=$(figures)
step "5. events after: $after"
[ "$after" = "$before" ] || fail "the restored events differ: before $before, after $after"
C up -d --wait api
port=$(C port api 3000 | sed 's/.*://')
[ -n "$port" ] || fail "the API has no port"
setup=$(curl -fsS "http://127.0.0.1:$port/v1/owner/setup") || fail "get_setup_state did not answer"
[[ "$setup" == *'"owner_exists":true'* ]] || fail "get_setup_state says no owner exists: $setup"
step "get_setup_state: $setup"
