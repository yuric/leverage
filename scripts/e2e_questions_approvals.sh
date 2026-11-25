#!/usr/bin/env bash
# Run the seven Questions and approvals acceptance cases with stand-ins.
# Each gets a fresh Compose project and a port assigned by Docker. The
# e2e lane builds the helper, runner, MCP server and tests once.
#
# Optional: API_IMAGE_TAG for an already-built API image, LEVERAGE_E2E_SCRATCH
# for the Swift build, and LEVERAGE_E2E_ONLY to run a named case locally.
# Every project and its temporary files are removed when the script exits.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
for file in compose.yaml compose.test.yaml; do
  if [ ! -f "$file" ]; then
    echo "e2e_questions_approvals: $file is missing" >&2
    exit 2
  fi
done

# The seven tests of §5.2, as swift test --filter names them.
tests=(
  "OutwardActionEndToEndTests/testApprovedActionReachesDone"
  "OutwardActionEndToEndTests/testStoppedThenSentBack"
  "OutwardActionEndToEndTests/testBuilderLostAfterApproval"
  "QuestionEndToEndTests/testOrchestratorDecidesAndOwnerOverturns"
  "QuestionEndToEndTests/testPassedOnQuestionHoldsUntilAnswered"
  "BudgetEndToEndTests/testProjectPausesAtItsBudget"
  "MCPEndToEndTests/testBuilderThroughMCPReachesDone"
)
replies="$root/mac/Tests/StandIns/replies"

run_id="${COMPOSE_PROJECT_NAME:-leverage-e2e-questions}-$$"
own_image=""
if [ -z "${API_IMAGE_TAG:-}" ]; then
  export API_IMAGE_TAG="$run_id"
  own_image="leverage-api:$API_IMAGE_TAG"
fi
image="leverage-api:$API_IMAGE_TAG"
scratch="${LEVERAGE_E2E_SCRATCH:-$root/mac/.build}"
out=$(mktemp -d "${TMPDIR:-/tmp}/leverage-e2e-questions.XXXXXX")
out=$(cd "$out" && pwd -P)
project=""
backups=""

say() { printf 'e2e_questions_approvals: %s\n' "$*"; }
U() { docker compose -f compose.yaml -f compose.test.yaml -p "$project" "$@"; }

# Removes a backup folder: its dumps may belong to uid 1000 (Linux), so they
# are removed as that user first.
remove_backups() {
  local folder=$1
  if [ -n "$folder" ] && [ -d "$folder" ]; then
    docker run --rm --entrypoint "" -v "$folder:/backups" "$image" \
      find /backups -mindepth 1 -delete >/dev/null 2>&1 || true
    rm -rf "$folder"
  fi
}

# Ends the project of the test in progress, if any.
end_project() {
  if [ -n "$project" ]; then
    U down --volumes --remove-orphans >/dev/null 2>&1 || true
  fi
  remove_backups "$backups"
  project=""
  backups=""
}

finish() {
  status=$?
  trap - EXIT INT TERM
  end_project
  if [ -n "$own_image" ]; then docker image rm "$own_image" >/dev/null 2>&1 || true; fi
  rm -rf "$out"
  if [ "$status" -eq 0 ]; then say "passed"; else say "FAILED (exit $status)"; fi
  exit "$status"
}
trap finish EXIT
trap 'exit 130' INT TERM

# .env holds made-up values; scripts/make_env.py makes one when there is none.
if [ ! -f .env ]; then
  python3 -I scripts/make_env.py >/dev/null
  say "made .env from .env.example, with secrets of its own"
fi

# The image, once; a tag the run was given is used as it is.
if [ -n "$own_image" ]; then
  say "building $own_image"
  project="$run_id-build"
  U build api
  project=""
fi

# The helper, the runner and the end-to-end tests, once.
say "building the e2e lane in $scratch"
(cd mac && LEVERAGE_ONLY=e2e swift build --build-tests --scratch-path "$scratch")

n=0
ran_tests=0
for test in "${tests[@]}"; do
  n=$((n + 1))
  if [ -n "${LEVERAGE_E2E_ONLY:-}" ] && [[ "$test" != *"$LEVERAGE_E2E_ONLY"* ]]; then
    continue
  fi
  ran_tests=$((ran_tests + 1))
  project="$run_id-$n"
  backups="$out/backups-$n"
  folder="$out/test-$n"
  mkdir -p "$backups" "$folder"
  chmod 1777 "$backups"
  export LEVERAGE_BACKUP_DIR="$backups"

  # 1. Containers of its own.
  say "$n. $test: starting db, api, sweep and backup as project $project"
  U up -d --wait --wait-timeout 300 db api sweep backup
  port=$(U port api 3000 | sed 's/.*://')
  export LEVERAGE_API_URL="http://127.0.0.1:$port"
  curl -fsS "$LEVERAGE_API_URL/v1/health" >/dev/null

  # 2. Only the selected stand-in test is enabled.
  say "$n. $test: running the test"
  (cd mac && env -u LEVERAGE_REAL_PROVIDER -u LEVERAGE_REAL_MCP -u LEVERAGE_EVAL_REAL \
    LEVERAGE_ONLY=e2e LEVERAGE_E2E=questions_approvals LEVERAGE_E2E_DIR="$folder" \
    LEVERAGE_TOOL_DIR="$root/mac/Tests/StandIns/bin" \
    swift test --no-parallel --skip-build --scratch-path "$scratch" --filter "$test")
  ran=$(find "$folder" -mindepth 2 -maxdepth 2 -name markers.txt | wc -l | tr -d ' ')
  if [ "$ran" -ne 1 ]; then
    say "$n. $test: expected the one test to run; $ran reached the log checks"
    exit 1
  fi

  # 3. The replay and the audit of every command.
  say "$n. $test: leverage:verify_log"
  U exec -T api bin/rails leverage:verify_log

  # 4. The secret scan and the two task-text checks.
  U logs --no-color >"$folder/containers.log" 2>&1
  # shellcheck disable=SC2016 # expanded by the db container's shell
  U exec -T db sh -c 'pg_dump --data-only --no-owner -U "$POSTGRES_USER" leverage_production' \
    >"$folder/dump.sql" 2>"$folder/dump.err"
  U exec -T backup ls -l /backups >"$folder/backups.txt"
  # Real tokens stay in memory. The scan checks their common prefixes
  # and Bearer shapes, plus the literals of the made-up owner and tools.
  scan=(python3 -I scripts/secret_scan.py --replies "$replies" --credentials-dump "$folder/dump.sql"
    --literal "made-up-e2e-owner-password"
    --literal "standin.owner@example.invalid"
    --literal "Stand-in Example Org")
  # Only action cases connect a builder on a Claude login.
  case "$test" in
    OutwardActionEndToEndTests/*) scan+=(--account-email "standin.owner@example.invalid") ;;
  esac
  for logs in "$folder"/*/support/logs; do scan+=("$logs" --logs "$logs"); done
  for calls in "$folder"/*/StandIns/state/calls.jsonl; do
    if [ -f "$calls" ]; then scan+=("$calls"); fi
  done
  markers=0
  for words in "$folder"/*/markers.txt; do
    while IFS= read -r word; do
      if [ -n "$word" ]; then
        scan+=(--not-in-events "$word" --not-in-logs "$word")
        markers=$((markers + 1))
      fi
    done <"$words"
  done
  if [ "$markers" -eq 0 ]; then
    say "$n. $test: the test wrote no marker word"
    exit 1
  fi
  scan+=(--events-dump "$folder/dump.sql" --logs "$folder/containers.log")
  scan+=("$folder/containers.log" "$folder/backups.txt")
  say "$n. $test: scanning the logs, the dump and the backup folder's listing"
  "${scan[@]}"

  # 5. The project, its volume and its backup folder.
  end_project
done

if [ "$ran_tests" -eq 0 ]; then
  say "no test is named like $LEVERAGE_E2E_ONLY"
  exit 1
fi
say "$ran_tests of ${#tests[@]} tests passed"
