#!/bin/bash
# Starts the bundled app once and checks that it brings its server up
# (milestone 2 plan WP18, PK-1, PK-2) and that its daily backup runs
# (milestone 3 plan HB-2, HB-3):
#
#   scripts/build_app.sh && scripts/smoke_app.sh
#
# It runs dist/Leverage.app/Contents/MacOS/LeverageApp with the environment
# an app opened from Finder has (HOME, USER, LOGNAME, TMPDIR, LANG and a
# PATH of /usr/bin:/bin:/usr/sbin:/sbin), plus a support folder and a
# compose project of its own, the memory session store and
# LEVERAGE_NOTIFICATIONS=off (so no permission prompt is raised, HM-27), so
# the owner's folder, project, Keychain and notifications are never
# touched. Within 60 seconds the process must be alive and GET /v1/health
# must answer "ok" on the port the app wrote to <support>/server/.env.
# Within the same time again the first dump must be in <support>/backups
# (mode 0700), with mode 0600. Then it stops the app, removes the compose
# project with its volume, and deletes the support folder, whether the
# check passed or not.
#
# Options:
#   --app PATH       the bundle to start (default: dist/Leverage.app)
#   --timeout SECS   how long the server, and then the first dump, may take
#                    (default: 60 each)
#   --keep           keep the support folder (its logs) after the run
set -euo pipefail

root=$(cd -- "$(dirname -- "$0")/.." && pwd)
app="$root/dist/Leverage.app"
timeout=60
keep=0
while [ $# -gt 0 ]; do
  case "$1" in
    --app)
      [ $# -ge 2 ] || { echo "smoke_app: --app needs a path" >&2; exit 2; }
      app=$2; shift ;;
    --timeout)
      [ $# -ge 2 ] || { echo "smoke_app: --timeout needs seconds" >&2; exit 2; }
      case "$2" in ''|*[!0-9]*) echo "smoke_app: --timeout takes whole seconds" >&2; exit 2 ;; esac
      timeout=$2; shift ;;
    --keep) keep=1 ;;
    -h|--help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "smoke_app: unknown argument: $1 (see --help)" >&2; exit 2 ;;
  esac
  shift
done

say() { printf 'smoke_app: %s\n' "$*"; }
fail() { printf 'smoke_app: FAILED: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || fail "the app runs only on macOS"
program="$app/Contents/MacOS/LeverageApp"
[ -x "$program" ] || fail "no app at $app (run scripts/build_app.sh first)"
command -v docker >/dev/null || fail "docker is not on PATH (needed to remove the compose project)"
command -v curl >/dev/null || fail "curl is not on PATH"

support=$(mktemp -d "${TMPDIR:-/tmp}/leverage-smoke.XXXXXX")
support=$(cd "$support" && pwd -P)
# A project name of its own: lower-case letters, digits and dashes.
project="leverage-smoke-$$"
server="$support/server"
backups="$support/backups"
output="$support/app-output.log"
pid=""

stop_app() {
  [ -n "$pid" ] || return 0
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    for _ in $(seq 1 20); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.5
    done
    if kill -0 "$pid" 2>/dev/null; then
      say "the app did not stop on TERM; killing it"
      kill -KILL "$pid" 2>/dev/null || true
    fi
  fi
  wait "$pid" 2>/dev/null || true
  pid=""
}

cleanup() {
  status=$?
  trap - EXIT INT TERM
  stop_app
  # Any helper the app started is its child and stops with it (PK-8); a
  # stray one with this support folder in its environment would be a fault.
  if [ -f "$server/compose.yaml" ]; then
    docker compose --project-directory "$server" -f "$server/compose.yaml" -p "$project" \
      down --volumes --remove-orphans --timeout 10 >/dev/null 2>&1 || true
  fi
  # Whatever the file did not name (or a run that never wrote it).
  leftover=$(docker ps -aq --filter "label=com.docker.compose.project=$project")
  if [ -n "$leftover" ]; then
    # shellcheck disable=SC2086
    docker rm -f $leftover >/dev/null 2>&1 || true
  fi
  docker volume ls -q --filter "label=com.docker.compose.project=$project" \
    | while read -r volume; do docker volume rm "$volume" >/dev/null 2>&1 || true; done
  docker network ls -q --filter "label=com.docker.compose.project=$project" \
    | while read -r network; do docker network rm "$network" >/dev/null 2>&1 || true; done
  if [ -n "$(docker ps -aq --filter "label=com.docker.compose.project=$project")" ]; then
    printf 'smoke_app: FAILED: containers of %s are still there\n' "$project" >&2
    status=1
  fi
  if [ "$status" != 0 ]; then
    say "the app's output and logs:"
    [ -f "$output" ] && tail -n 40 "$output" | sed 's/^/  | /'
    for log in "$support"/logs/*.log; do
      [ -f "$log" ] || continue
      say "${log#"$support"/}:"
      tail -n 40 "$log" | sed 's/^/  | /'
    done
  fi
  if [ "$keep" = 1 ]; then
    say "kept $support"
  else
    rm -rf "$support"
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

say "starting $program"
say "support folder $support, compose project $project"
env -i \
  HOME="$HOME" USER="${USER:-$(id -un)}" LOGNAME="${LOGNAME:-$(id -un)}" \
  TMPDIR="${TMPDIR:-/tmp/}" LANG="${LANG:-en_US.UTF-8}" \
  PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  LEVERAGE_SUPPORT_DIR="$support" \
  LEVERAGE_COMPOSE_PROJECT="$project" \
  LEVERAGE_SESSION_STORE=memory \
  LEVERAGE_NOTIFICATIONS=off \
  "$program" >"$output" 2>&1 &
pid=$!

started=$(date +%s)
deadline=$((started + timeout))
port=""
answer=""
while :; do
  kill -0 "$pid" 2>/dev/null || { pid_status=0; wait "$pid" || pid_status=$?; pid=""; fail "the app exited (status $pid_status) before its server answered"; }
  if [ -z "$port" ] && [ -f "$server/.env" ]; then
    port=$(sed -n 's/^API_PORT=\([0-9][0-9]*\)$/\1/p' "$server/.env" | head -n 1)
    if [ -n "$port" ]; then
      { [ "$port" -ge 47130 ] && [ "$port" -le 47139 ]; } || fail "API_PORT $port is outside 47130 to 47139"
      say "the app wrote API_PORT=$port"
    fi
  fi
  if [ -n "$port" ]; then
    answer=$(curl -fsS --max-time 2 "http://127.0.0.1:$port/v1/health" 2>/dev/null || true)
    case "$answer" in
      *'"status":"ok"'*|*'"status": "ok"'*) break ;;
    esac
  fi
  [ "$(date +%s)" -lt "$deadline" ] || fail "GET /v1/health did not answer ok within ${timeout} s (port ${port:-not written})"
  sleep 1
done
elapsed=$(( $(date +%s) - started ))
kill -0 "$pid" 2>/dev/null || fail "the app is not running after its server answered"
say "after ${elapsed} s the app (pid $pid) is running and GET /v1/health on 127.0.0.1:$port answers $answer"

# The backup service starts with the others (the app runs `compose up` with
# no service named) and makes its first dump when it first looks (HB-3).
grep -qx "LEVERAGE_BACKUP_DIR=$backups" "$server/.env" \
  || fail "the app did not write LEVERAGE_BACKUP_DIR=$backups to $server/.env"
dump_started=$(date +%s)
deadline=$((dump_started + timeout))
dump=""
while :; do
  kill -0 "$pid" 2>/dev/null || fail "the app exited before the first backup"
  for file in "$backups"/leverage-*.dump; do
    [ -f "$file" ] && { dump=$file; break; }
  done
  [ -n "$dump" ] && break
  [ "$(date +%s)" -lt "$deadline" ] || fail "no dump in $backups within ${timeout} s"
  sleep 1
done
mode() { stat -f '%Lp' "$1"; }
[ "$(mode "$backups")" = 700 ] || fail "$backups has mode $(mode "$backups"), not 700"
[ "$(mode "$dump")" = 600 ] || fail "${dump#"$support"/} has mode $(mode "$dump"), not 600"
[ -s "$dump" ] || fail "${dump#"$support"/} is empty"
say "after $(( $(date +%s) - dump_started )) s more the first backup is ${dump#"$support"/} ($(wc -c <"$dump" | tr -d ' ') bytes, mode 600)"

say "stopping the app and removing $project"
stop_app
say "ok"
