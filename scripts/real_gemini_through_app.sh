#!/usr/bin/env bash
# A developer check with the real Antigravity (agy), never run in CI and run
# only by the managing agent (milestone 2, the managing agent's override 8).
#
#   LEVERAGE_REAL_PROVIDER=gemini scripts/real_gemini_through_app.sh
#
# It refuses to run (exit 2, before anything starts) when CI is set or when
# LEVERAGE_REAL_PROVIDER is not gemini. That guards against CI and accidents;
# it is not anyone's consent.
#
# The path is the end-to-end run's (scripts/e2e_core_loop.sh): the real API,
# its sweep and PostgreSQL in containers of a project of their own, the real
# helper and the real runner, with the real `agy` found where the helper
# looks for it instead of the stand-ins. Antigravity keeps one sign-in for
# the whole Mac, and it must already be signed in: nobody signs in here. The
# test RealGeminiThroughAppTests adds one Gemini login through Add credential,
# connects a builder on it, adds one small task with one criterion in a new
# empty folder and waits for Done, at most 15 minutes. The reviewer is the
# real runner with the stand-in Codex, because the runner offers no Gemini
# reviewer (CL-8); the test file says why. Then leverage:verify_log and the
# secret scan run, and the project and its volume are removed.
#
# It spends a little of the Mac's Antigravity quota: the add's test prompt
# and one build. A failure does not block the merge; it is recorded for the
# owner.
#
# Environment it reads (all optional): API_IMAGE_TAG; LEVERAGE_E2E_SCRATCH
# (Swift's build folder, default mac/.build); LEVERAGE_E2E_KEEP=1 keeps the
# run's folder when it passes.
set -euo pipefail

if [ -n "${CI:-}" ]; then
  echo "real_gemini_through_app: refused: CI is set; this check never runs in CI" >&2
  exit 2
fi
if [ "${LEVERAGE_REAL_PROVIDER:-}" != "gemini" ]; then
  echo "real_gemini_through_app: refused: set LEVERAGE_REAL_PROVIDER=gemini to run the check with the real agy" >&2
  exit 2
fi

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

export COMPOSE_PROJECT_NAME="leverage-real-gemini-$$"
scratch="${LEVERAGE_E2E_SCRATCH:-$root/mac/.build}"
out=$(mktemp -d "${TMPDIR:-/tmp}/leverage-real-gemini.XXXXXX")
out=$(cd "$out" && pwd -P)

say() { printf 'real_gemini_through_app: %s\n' "$*"; }
U() { docker compose -f compose.yaml -f compose.test.yaml "$@"; }

finish() {
  status=$?
  trap - EXIT INT TERM
  if [ "$status" -ne 0 ]; then
    U logs --no-color >"$out/containers.log" 2>&1 || true
  fi
  U down --volumes --remove-orphans >/dev/null 2>&1 || true
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

python3 -I scripts/make_env.py

say "starting db, api and sweep as project $COMPOSE_PROJECT_NAME"
U up -d --build --wait --wait-timeout 300 db api sweep
port=$(U port api 3000 | sed 's/.*://')
export LEVERAGE_API_URL="http://127.0.0.1:$port"
curl -fsS "$LEVERAGE_API_URL/v1/health" >/dev/null
say "the API answers on $LEVERAGE_API_URL"

say "building the e2e lane in $scratch"
(cd mac && LEVERAGE_ONLY=e2e swift build --build-tests --scratch-path "$scratch")

say "running RealGeminiThroughAppTests (deadline 15 minutes for Done)"
(cd mac && LEVERAGE_ONLY=e2e LEVERAGE_E2E=1 LEVERAGE_REAL_PROVIDER=gemini LEVERAGE_E2E_DIR="$out/tests" \
  swift test --skip-build --scratch-path "$scratch" --filter RealGeminiThroughAppTests)
if ! find "$out/tests" -mindepth 2 -maxdepth 2 -name secrets.txt 2>/dev/null | grep -q .; then
  say "the test did not run"
  exit 1
fi

say "running leverage:verify_log"
U exec -T api bin/rails leverage:verify_log

U logs --no-color >"$out/containers.log" 2>&1
# shellcheck disable=SC2016 # expanded by the db container's shell
U exec -T db sh -c 'pg_dump --data-only --no-owner -U "$POSTGRES_USER" leverage_production' \
  >"$out/dump.sql" 2>"$out/dump.err"
scan=(python3 -I scripts/secret_scan.py)
for secrets in "$out"/tests/*/secrets.txt; do scan+=(--secrets "$secrets"); done
for logs in "$out"/tests/*/support/logs; do scan+=("$logs"); done
scan+=("$out/containers.log" "$out/dump.sql")
say "scanning the logs and the database dump"
"${scan[@]}"
