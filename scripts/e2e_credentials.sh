#!/usr/bin/env bash
# Credentials acceptance tests. Each runs on a fresh API, sweep and backup
# with the real helper and runner. All providers are local stand-ins.
# An existing API_IMAGE_TAG is reused. LEVERAGE_E2E_SCRATCH selects the
# Swift build folder. LEVERAGE_E2E_ONLY selects a case while debugging.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd -P)
cd "$root"

tests=(
  AddAndReadEndToEndTests/testAddAndRead
  TokenEndToEndTests/tokens
  ReorderAndCapacityEndToEndTests/testWaitsEnd
)
run_id="leverage-e2e-credentials-$$"
own_image=""
if [ -z "${API_IMAGE_TAG:-}" ]; then
  export API_IMAGE_TAG="$run_id"
  own_image="leverage-api:$API_IMAGE_TAG"
fi
image="leverage-api:$API_IMAGE_TAG"
scratch="${LEVERAGE_E2E_SCRATCH:-$root/mac/.build}"
out=$(mktemp -d "${TMPDIR:-/tmp}/leverage-e2e-credentials.XXXXXX")
out=$(cd "$out" && pwd -P)
project=""
backups=""

say() { printf 'e2e_credentials: %s\n' "$*"; }
U() { docker compose -f compose.yaml -f compose.test.yaml -p "$project" "$@"; }

end_project() {
  if [ -n "$project" ]; then
    U down --volumes --remove-orphans || return
    project=""
  fi
  if [ -n "$backups" ] && [ -d "$backups" ]; then
    # The backup service can have written files as a different uid on Linux.
    docker run --rm --entrypoint "" -v "$backups:/backups" "$image" \
      find /backups -mindepth 1 -delete || return
    backups=""
  fi
}

finish() {
  local status=$?
  trap - EXIT INT TERM
  end_project || status=1
  if [ -n "$own_image" ]; then docker image rm "$own_image" >/dev/null 2>&1 || true; fi
  rm -rf "$out"
  if [ "$status" -eq 0 ]; then say "passed"; else say "FAILED (exit $status)"; fi
  exit "$status"
}
trap finish EXIT
trap 'exit 130' INT TERM

if [ ! -f .env ]; then cp .env.example .env; fi
if [ -n "$own_image" ]; then
  project="$run_id-build"
  U build api
  project=""
fi

say "building the e2e lane in $scratch"
(cd mac && LEVERAGE_ONLY=e2e swift build --build-tests --scratch-path "$scratch")

n=0
ran=0
for test in "${tests[@]}"; do
  n=$((n + 1))
  if [ -n "${LEVERAGE_E2E_ONLY:-}" ] && [[ "$test" != *"$LEVERAGE_E2E_ONLY"* ]]; then
    continue
  fi
  project="$run_id-$n"
  folder="$out/test-$n"
  backups="$out/backups-$n"
  mkdir -p "$folder" "$backups"
  chmod 1777 "$backups"
  export LEVERAGE_BACKUP_DIR="$backups"

  say "$test: starting db, api, sweep and backup as project $project"
  U up -d --wait --wait-timeout 300 db api sweep backup
  port=$(U port api 3000 | sed 's/.*://')
  export LEVERAGE_API_URL="http://127.0.0.1:$port"
  curl -fsS "$LEVERAGE_API_URL/v1/health" >/dev/null

  say "$test: running the test"
  (cd mac && env -u LEVERAGE_REAL_PROVIDER -u LEVERAGE_REAL_MCP LEVERAGE_ONLY=e2e \
    LEVERAGE_E2E=credentials LEVERAGE_E2E_DIR="$folder" \
    swift test --no-parallel --skip-build --scratch-path "$scratch" --filter "$test")
  cases=("$folder"/*/secrets.txt)
  if [ "${#cases[@]}" -ne 1 ] || [ ! -f "${cases[0]}" ]; then
    say "$test: expected exactly one test to write its secret scan inputs"
    exit 1
  fi
  case_dir=$(dirname "${cases[0]}")

  say "$test: replay and audit"
  U exec -T api bin/rails leverage:verify_log
  if [ "$n" -eq 3 ]; then
    say "$test: recovery times"
    U exec -T -e CEILING_SECONDS=900 -e OPEN=fail api bin/rails leverage:recovery_times
  fi

  U logs --no-color >"$folder/containers.log" 2>&1
  # shellcheck disable=SC2016 # expanded by the db container's shell
  U exec -T db sh -c 'pg_dump --data-only --no-owner -U "$POSTGRES_USER" leverage_production' \
    >"$folder/dump.sql" 2>"$folder/dump.err"
  U exec -T backup ls -l /backups >"$folder/backups.txt"
  scan=(python3 -I scripts/secret_scan.py --replies "$root/mac/Tests/StandIns/replies"
        --credentials-dump "$folder/dump.sql" --account-email standin.owner@example.invalid
        --secrets "${cases[0]}")
  if [ "$n" -eq 2 ]; then
    scan+=(--provider-api-record "$case_dir/StandIns/state/provider-api/calls.jsonl"
           --token-markers "$case_dir/token-markers.txt")
  fi
  for record in "$case_dir"/StandIns/state/{calls,app-server}.jsonl; do
    if [ -f "$record" ]; then scan+=("$record"); fi
  done
  say "$test: scanning logs, the database and the backup listing"
  "${scan[@]}" "$case_dir/support/logs" "$folder/containers.log" "$folder/backups.txt"

  end_project
  ran=$((ran + 1))
done
if [ "$ran" -eq 0 ]; then
  say "no test matches LEVERAGE_E2E_ONLY"
  exit 1
fi
say "$ran of ${#tests[@]} tests passed"
