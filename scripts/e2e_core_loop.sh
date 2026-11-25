#!/usr/bin/env bash
# The core loop, reviewer handoff and short-prompt agent (TS-9, GA-12–GA-17):
# the real API, its sweep and PostgreSQL in containers of a project of its own,
# the real helper and runner built from mac/, every provider's tool a stand-in.
# It needs Docker and Swift and nothing else, and is the same on the Mac and
# in CI's e2e job.
#
#   scripts/e2e_core_loop.sh
#
# Steps: start db, api and sweep (Docker picks the port); build the helper,
# the runner and the end-to-end tests (LEVERAGE_ONLY=e2e); run
# LeverageEndToEndTests with LEVERAGE_E2E=1; run leverage:verify_log on the
# database; scan the containers' logs, the helper's and the runs' logs and a
# data-only dump of the database for every secret the tests used and for
# anything shaped like a token; remove the project and its volume, also on
# failure. Nothing waits a fixed time: the tests long-poll for each event.
#
# Environment it reads (all optional):
#   API_IMAGE_TAG          the API image's tag; by default the run's own,
#                          leverage-api:<project>, removed when the run ends
#   LEVERAGE_E2E_SCRATCH   Swift's build folder (default: mac/.build)
#   LEVERAGE_E2E_KEEP=1    keep the run's folder (logs, dump) even when it passes
#   LEVERAGE_E2E_ONLY      run a single matching test within LeverageEndToEnd
# A failed run always keeps its folder and prints where it is.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

export COMPOSE_PROJECT_NAME="leverage-e2e-$$"
# The run builds its own image tag, so it never replaces leverage-api:local
# (or another checkout's tag) under a run going on beside it.
own_image=""
if [ -z "${API_IMAGE_TAG:-}" ]; then
  export API_IMAGE_TAG="$COMPOSE_PROJECT_NAME"
  own_image="leverage-api:$API_IMAGE_TAG"
fi
scratch="${LEVERAGE_E2E_SCRATCH:-$root/mac/.build}"
out=$(mktemp -d "${TMPDIR:-/tmp}/leverage-e2e.XXXXXX")
out=$(cd "$out" && pwd -P)

say() { printf 'e2e: %s\n' "$*"; }
U() { docker compose -f compose.yaml -f compose.test.yaml "$@"; }

finish() {
  status=$?
  trap - EXIT INT TERM
  if [ "$status" -ne 0 ]; then
    U logs --no-color >"$out/containers.log" 2>&1 || true
  fi
  U down --volumes --remove-orphans >/dev/null 2>&1 || true
  if [ -n "$own_image" ]; then docker image rm "$own_image" >/dev/null 2>&1 || true; fi
  if [ "$status" -eq 0 ] && [ "${LEVERAGE_E2E_KEEP:-}" != "1" ]; then
    rm -rf "$out"
    say "passed"
  else
    say "kept the run's folder: $out"
    if [ "$status" -eq 0 ]; then say "passed"; else say "FAILED (exit $status)"; fi
  fi
  exit "$status"
}
trap finish EXIT
trap 'exit 130' INT TERM

# .env holds made-up values; the example is used when there is none.
if [ ! -f .env ]; then
  cp .env.example .env
  say "made .env from .env.example"
fi

# 1. The API, its sweep and the database. compose.test.yaml lets Docker pick
# the port, which is read back once it is bound.
say "starting db, api and sweep as project $COMPOSE_PROJECT_NAME"
U up -d --build --wait --wait-timeout 300 db api sweep
port=$(U port api 3000 | sed 's/.*://')
export LEVERAGE_API_URL="http://127.0.0.1:$port"
curl -fsS "$LEVERAGE_API_URL/v1/health" >/dev/null
say "the API answers on $LEVERAGE_API_URL"

# 2. The helper, the runner and the end-to-end tests.
say "building the e2e lane in $scratch"
(cd mac && LEVERAGE_ONLY=e2e swift build --build-tests --scratch-path "$scratch")

# 3. The tests: each writes its folder (support folder, logs, the secrets it
# used) under LEVERAGE_E2E_DIR.
filter=LeverageEndToEnd
expected=7
if [ -n "${LEVERAGE_E2E_ONLY:-}" ]; then
  filter="$filter.*$LEVERAGE_E2E_ONLY"
  expected=1
  say "running 1 end-to-end test matching $LEVERAGE_E2E_ONLY"
else
  say "running all $expected end-to-end tests"
fi
# LEVERAGE_REAL_PROVIDER is dropped, so the developer check with a real
# tool (RealGeminiThroughAppTests) never runs here.
(cd mac && env -u LEVERAGE_REAL_PROVIDER LEVERAGE_ONLY=e2e LEVERAGE_E2E=1 LEVERAGE_E2E_DIR="$out/tests" \
  swift test --skip-build --scratch-path "$scratch" --filter "$filter")
ran=$(find "$out/tests" -mindepth 2 -maxdepth 2 -name secrets.txt 2>/dev/null | wc -l | tr -d ' ')
if [ "$ran" -ne "$expected" ]; then
  if [ "$expected" -eq 1 ]; then
    say "expected 1 end-to-end test to run; $ran wrote their secrets"
  else
    say "expected all $expected end-to-end tests to run; $ran wrote their secrets"
  fi
  exit 1
fi

# 4. The replay and the audit of every command, over the whole database.
say "running leverage:verify_log"
U exec -T api bin/rails leverage:verify_log

# 5. The secret scan.
U logs --no-color >"$out/containers.log" 2>&1
# shellcheck disable=SC2016 # expanded by the db container's shell
U exec -T db sh -c 'pg_dump --data-only --no-owner -U "$POSTGRES_USER" leverage_production' \
  >"$out/dump.sql" 2>"$out/dump.err"
scan=(python3 -I scripts/secret_scan.py --credentials-dump "$out/dump.sql")
for secrets in "$out"/tests/*/secrets.txt; do scan+=(--secrets "$secrets"); done
# The stand-in tools' record of each call holds the environment each tool
# was started with.
account_email_option=--literal
if [ -z "${LEVERAGE_E2E_ONLY:-}" ]; then account_email_option=--account-email; fi
for calls in "$out"/tests/*/StandIns/state/calls.jsonl; do
  if [ -f "$calls" ]; then
    scan+=("$calls")
    account_email_option=--account-email
  fi
done
# A Prompt-only case adds no login. Still check that the stand-in email
# appears nowhere in that run.
scan+=("$account_email_option" "standin.owner@example.invalid")
helper_logs=("$out"/tests/*/support/logs)
if [ "$account_email_option" = --account-email ] || [ -d "${helper_logs[0]}" ]; then
  scan+=("${helper_logs[@]}")
fi
scan+=("$out/containers.log")
say "scanning the logs and the database dump"
"${scan[@]}"
