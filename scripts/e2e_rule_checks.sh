#!/usr/bin/env bash
# The Rule checks milestone's acceptance run (milestone 4 plan §5.2, RT-9):
# seven tests, each from the first sign-in, which now writes the seven
# shipped rules, to a task checked by the rules: the shipped rules from the
# form to Done and on a vague task, a custom rule at "before work is
# submitted" that refuses and passes and that waits for the owner on the
# fourth try, the orchestrator offline and back, the provider rule at
# review, and a contract a planner drafts. It is built like
# scripts/e2e_handoff.sh: the real API, sweep and backup in containers, the
# real helper and runner built once with LEVERAGE_ONLY=e2e, every provider's
# tool a stand-in. It needs Docker and Swift and nothing else, and is the
# same on the Mac and in CI's e2e job.
#
#   scripts/e2e_rule_checks.sh
#
# One compose project per test (leverage-e2e-rules-<pid>-<n>), because
# there is one owner per database and creating it writes the rules. For
# each test, in order:
#   1. a backup folder of its own (mode 1777), and db, api, sweep and backup
#      started with both compose files on a port Docker picks;
#   2. that one test, with swift test --filter and LEVERAGE_E2E=rule_checks;
#   3. leverage:verify_log (replay with rule_checks and rules, the step
#      partition, every command's events, the gate line of RT-4);
#   4. leverage:rule_timing: each rule's runs, queue and run time and
#      tokens, kept as rule-timing-<n>-<test>.txt;
#   5. the secret scan of the containers' logs, the helper's and the runs'
#      logs, the stand-ins' record of each call, a data-only dump of the
#      database and the backup folder's listing, for the secrets the test
#      used, the stand-ins' made-up email and organisation, every reply
#      file's marker and every long line of its outputs; and the two
#      task-text questions (RT-8): none of the test's marker words in any
#      event's payload or in any log line, and no frame's nonce in a log;
#   6. the project, its volume and its folders removed, also on failure.
# Nothing waits a fixed time: the tests long-poll for each event.
#
# Environment it reads (all optional):
#   API_IMAGE_TAG          the API image's tag, used as it is (never rebuilt);
#                          by default the run builds leverage-api:<its own
#                          tag> once and removes it when it ends
#   LEVERAGE_E2E_SCRATCH   Swift's build folder (default: mac/.build)
#   LEVERAGE_E2E_KEEP=1    keep the run's folder (logs, dumps) even when it passes
#   LEVERAGE_E2E_RULE_TIMING  a folder the rule-timing files are copied to
#   LEVERAGE_E2E_ONLY      run only the tests whose name holds this text
#                          (while a fault is being found; the acceptance run
#                          sets nothing)
# A failed run always keeps its folder and prints where it is.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
for file in compose.yaml compose.test.yaml; do
  if [ ! -f "$file" ]; then
    echo "e2e_rule_checks: $file is missing" >&2
    exit 2
  fi
done

# The seven tests of §5.2, as swift test --filter names them.
tests=(
  "ShippedRulesEndToEndTests/testFormToDone"
  "ShippedRulesEndToEndTests/testVagueTaskStaysInBacklog"
  "SubmitRuleEndToEndTests/testRuleBlocksSubmitThenPasses"
  "SubmitRuleEndToEndTests/testFourthTryWaitsForTheOwner"
  "OrchestratorOfflineEndToEndTests/testOfflineAndBack"
  "ProviderRuleEndToEndTests/testNoReviewerEligibleThenAnother"
  "DraftContractEndToEndTests/testDraftToReady"
)
replies="$root/mac/Tests/StandIns/replies"

run_id="leverage-e2e-rules-$$"
own_image=""
if [ -z "${API_IMAGE_TAG:-}" ]; then
  export API_IMAGE_TAG="$run_id"
  own_image="leverage-api:$API_IMAGE_TAG"
fi
image="leverage-api:$API_IMAGE_TAG"
scratch="${LEVERAGE_E2E_SCRATCH:-$root/mac/.build}"
out=$(mktemp -d "${TMPDIR:-/tmp}/leverage-e2e-rules.XXXXXX")
out=$(cd "$out" && pwd -P)
project=""
backups=""

say() { printf 'e2e_rule_checks: %s\n' "$*"; }
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
  if [ "$status" -ne 0 ] && [ -n "$project" ]; then
    U logs --no-color >"$out/failed-containers.log" 2>&1 || true
  fi
  end_project
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

  # 2. The one test. LEVERAGE_REAL_PROVIDER is dropped, so the developer
  # check with a real tool never runs here.
  say "$n. $test: running the test"
  (cd mac && env -u LEVERAGE_REAL_PROVIDER LEVERAGE_ONLY=e2e LEVERAGE_E2E=rule_checks LEVERAGE_E2E_DIR="$folder" \
    swift test --skip-build --scratch-path "$scratch" --filter "$test")
  ran=$(find "$folder" -mindepth 2 -maxdepth 2 -name secrets.txt | wc -l | tr -d ' ')
  if [ "$ran" -ne 1 ]; then
    say "$n. $test: expected the one test to run; $ran wrote their secrets"
    exit 1
  fi

  # 3. The replay and the audit of every command.
  say "$n. $test: leverage:verify_log"
  U exec -T api bin/rails leverage:verify_log

  # 4. Each rule's runs, queue and run time and tokens, kept for the
  # managing agent to read against the test.
  name=${test//\//-}
  say "$n. $test: leverage:rule_timing"
  U exec -T api bin/rails leverage:rule_timing >"$folder/rule-timing-$n-$name.txt"
  cat "$folder/rule-timing-$n-$name.txt"
  if [ -n "${LEVERAGE_E2E_RULE_TIMING:-}" ]; then
    mkdir -p "$LEVERAGE_E2E_RULE_TIMING"
    cp "$folder/rule-timing-$n-$name.txt" "$LEVERAGE_E2E_RULE_TIMING/"
  fi

  # 5. The secret scan, and the two task-text questions.
  U logs --no-color >"$folder/containers.log" 2>&1
  # shellcheck disable=SC2016 # expanded by the db container's shell
  U exec -T db sh -c 'pg_dump --data-only --no-owner -U "$POSTGRES_USER" leverage_production' \
    >"$folder/dump.sql" 2>"$folder/dump.err"
  U exec -T backup ls -l /backups >"$folder/backups.txt"
  scan=(python3 -I scripts/secret_scan.py --replies "$replies" --credentials-dump "$folder/dump.sql")
  # The offline and draft cases add only Codex and/or Gemini logins.
  case "$test" in
    OrchestratorOfflineEndToEndTests/*|DraftContractEndToEndTests/*) ;;
    *) scan+=(--account-email "standin.owner@example.invalid") ;;
  esac
  for secrets in "$folder"/*/secrets.txt; do scan+=(--secrets "$secrets"); done
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

  # 6. The project, its volume and its backup folder.
  end_project
done

if [ "$ran_tests" -eq 0 ]; then
  say "no test is named like $LEVERAGE_E2E_ONLY"
  exit 1
fi
say "$ran_tests of ${#tests[@]} tests passed"
