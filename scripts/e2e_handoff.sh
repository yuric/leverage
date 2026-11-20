#!/usr/bin/env bash
# The Handoff milestone's acceptance run (milestone 3 plan §5.2): six tests,
# each from the first sign-in to the first Done with a run interrupted in
# one of the three forms (a limit after work is saved, a login found signed
# out, one account at its limit while the next is signed out). It is built
# like scripts/e2e_core_loop.sh: the real API, sweep and backup in
# containers, the real helper and runner built once with LEVERAGE_ONLY=e2e,
# every provider's tool a stand-in. It needs Docker and Swift and nothing
# else, and is the same on the Mac and in CI's e2e job.
#
#   scripts/e2e_handoff.sh
#
# One compose project per test (leverage-e2e-handoff-<pid>-<n>), because
# there is one owner per database and no test may meet a hold, a limited
# account or a login an earlier test left. For each test, in order:
#   1. a backup folder of its own (mode 0777), and db, api, sweep and backup
#      started with both compose files on a port Docker picks;
#   2. that one test, with swift test --filter and LEVERAGE_E2E=handoff;
#   3. leverage:verify_log (replay, step partition, every command's events);
#   4. leverage:recovery_times with CEILING_SECONDS=900 and OPEN=fail: each
#      interval beside the working bar (plan HE-1), failing on one longer or
#      still open;
#   5. the secret scan of the containers' logs, the helper's and the runs'
#      logs, the stand-ins' record of each call, a data-only dump of the
#      database and the backup folder's listing, for the secrets the test
#      used, the stand-ins' made-up email and organisation, every reply
#      file's marker and every long line of its outputs;
#   6. for the test of form C only, scripts/restore_drill.sh --from-project
#      on that project's log (plan §5.3);
#   7. the project, its volume and its folders removed, also on failure.
# Nothing waits a fixed time: the tests long-poll for each event.
#
# Environment it reads (all optional):
#   API_IMAGE_TAG          the API image's tag, used as it is (never rebuilt);
#                          by default the run builds leverage-api:<its own
#                          tag> once and removes it when it ends
#   LEVERAGE_E2E_SCRATCH   Swift's build folder (default: mac/.build)
#   LEVERAGE_E2E_KEEP=1    keep the run's folder (logs, dumps) even when it passes
#   LEVERAGE_E2E_RECOVERY_TIMES  a file the six recovery-time tables are
#                          appended to
#   LEVERAGE_E2E_ONLY      run only the tests whose name holds this text
#                          (while a fault is being found; the acceptance run
#                          sets nothing)
# A failed run always keeps its folder and prints where it is.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
for file in compose.yaml compose.test.yaml; do
  if [ ! -f "$file" ]; then
    echo "e2e_handoff: $file is missing" >&2
    exit 2
  fi
done

# The six tests of §5.2, as swift test --filter names them, and which one
# also runs the restore drill (form C: its log holds a hold, an item, a
# sign-in and a switch).
tests=(
  "LimitHandoffEndToEndTests/testSameProvider"
  "LimitHandoffEndToEndTests/testOtherProvider"
  "LimitWaitEndToEndTests/testWaitsForTheReset"
  "SignedOutEndToEndTests/testHandsOff"
  "SignedOutEndToEndTests/testHeldUntilSignIn"
  "LimitThenSignedOutEndToEndTests/testHeldUntilTheNextSignsIn"
)
drill_test="LimitThenSignedOutEndToEndTests/testHeldUntilTheNextSignsIn"
replies="$root/mac/Tests/StandIns/replies"

run_id="leverage-e2e-handoff-$$"
own_image=""
if [ -z "${API_IMAGE_TAG:-}" ]; then
  export API_IMAGE_TAG="$run_id"
  own_image="leverage-api:$API_IMAGE_TAG"
fi
image="leverage-api:$API_IMAGE_TAG"
scratch="${LEVERAGE_E2E_SCRATCH:-$root/mac/.build}"
out=$(mktemp -d "${TMPDIR:-/tmp}/leverage-e2e-handoff.XXXXXX")
out=$(cd "$out" && pwd -P)
project=""
backups=""

say() { printf 'e2e_handoff: %s\n' "$*"; }
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
  chmod 0777 "$backups"
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
  (cd mac && env -u LEVERAGE_REAL_PROVIDER LEVERAGE_ONLY=e2e LEVERAGE_E2E=handoff LEVERAGE_E2E_DIR="$folder" \
    swift test --skip-build --scratch-path "$scratch" --filter "$test")
  ran=$(find "$folder" -mindepth 2 -maxdepth 2 -name secrets.txt | wc -l | tr -d ' ')
  if [ "$ran" -ne 1 ]; then
    say "$n. $test: expected the one test to run; $ran wrote their secrets"
    exit 1
  fi

  # 3. The replay and the audit of every command.
  say "$n. $test: leverage:verify_log"
  U exec -T api bin/rails leverage:verify_log

  # 4. The recovery times against the working bar.
  say "$n. $test: leverage:recovery_times"
  {
    echo "== $test"
    U exec -T -e CEILING_SECONDS=900 -e OPEN=fail api bin/rails leverage:recovery_times
  } >"$folder/recovery-times.txt" 2>&1 || {
    cat "$folder/recovery-times.txt"
    exit 1
  }
  cat "$folder/recovery-times.txt"
  if [ -n "${LEVERAGE_E2E_RECOVERY_TIMES:-}" ]; then
    cat "$folder/recovery-times.txt" >>"$LEVERAGE_E2E_RECOVERY_TIMES"
  fi

  # 5. The secret scan.
  U logs --no-color >"$folder/containers.log" 2>&1
  # shellcheck disable=SC2016 # expanded by the db container's shell
  U exec -T db sh -c 'pg_dump --data-only --no-owner -U "$POSTGRES_USER" leverage_production' \
    >"$folder/dump.sql" 2>"$folder/dump.err"
  U exec -T backup ls -l /backups >"$folder/backups.txt"
  scan=(python3 -I scripts/secret_scan.py --replies "$replies")
  for secrets in "$folder"/*/secrets.txt; do scan+=(--secrets "$secrets"); done
  for logs in "$folder"/*/support/logs; do scan+=("$logs"); done
  for calls in "$folder"/*/StandIns/state/calls.jsonl; do
    if [ -f "$calls" ]; then scan+=("$calls"); fi
  done
  scan+=("$folder/containers.log" "$folder/dump.sql" "$folder/backups.txt")
  say "$n. $test: scanning the logs, the dump and the backup folder's listing"
  "${scan[@]}"

  # 6. The restore drill on this test's own log, which removes the project.
  if [ "$test" = "$drill_test" ]; then
    say "$n. $test: the restore drill on this project's log"
    scripts/restore_drill.sh --from-project "$project"
  fi

  # 7. The project, its volume and its backup folder.
  end_project
done

if [ "$ran_tests" -eq 0 ]; then
  say "no test is named like $LEVERAGE_E2E_ONLY"
  exit 1
fi
say "$ran_tests of ${#tests[@]} tests passed"
