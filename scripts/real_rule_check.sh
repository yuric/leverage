#!/usr/bin/env bash
# One real verdict through the server (milestone 4 plan §5.5): the managing
# agent's check that an orchestrator on a provider's real tool checks two
# contracts the way the eval found. It never runs in CI, and only the
# managing agent runs it, once per supported provider, at most twice.
#
#   LEVERAGE_REAL_PROVIDER=<p> scripts/real_rule_check.sh <p>
#   LEVERAGE_REAL_PROVIDER=gemini scripts/real_rule_check.sh gemini --through-app
#
#   <p>             claude, codex or gemini (the tool agy)
#   --through-app   Gemini only: the orchestrator is a seat the helper starts
#                   on a Gemini login added through Add credential, as
#                   scripts/real_gemini_through_app.sh adds it (Antigravity
#                   keeps one sign-in for the whole Mac); without it the
#                   orchestrator connects on its own and the script starts
#                   one LeverageRunner for it
#
# It refuses (exit 2, before anything starts) when CI is set; when
# LEVERAGE_REAL_PROVIDER is not exactly <p>; for an unknown provider, a
# missing one, an unknown option, or --through-app with a provider other
# than gemini. That guards against CI and accidents; it is not anyone's
# consent. When the real tool is not on PATH it says "skipped: not
# installed" (exit 3).
#
# Against the stand-ins instead (any agent may run this; its plumbing is
# proven so): leave LEVERAGE_REAL_PROVIDER unset and set LEVERAGE_TOOL_DIR to
# the absolute bin/ of a copy of mac/Tests/StandIns (beside provider_tool.py).
# Setting both is refused. The stand-in checker fails the vague case by a
# word of its goal and passes the other.
#
# The run, on a compose project of its own (leverage-real-rule-check-<pid>):
# 1. db, api and sweep on a port Docker picks; the e2e lane built once;
# 2. the test RealRuleCheckTests: it creates the owner (which writes the
#    shipped rules), connects one orchestrator, and adds two tasks with
#    completed contracts, the first `specific` case and the first
#    `vague_goal` case of evals/specific-details/cases. It passes when the
#    first task is Ready and the second is held with contract_incomplete
#    within 5 minutes: two tool runs. Without --through-app the orchestrator
#    connects on its own, and the test starts LeverageRunner for it with
#    the tool found here and, on the real path, LEVERAGE_DEV_TOOL_LOGIN=1,
#    so the tool uses the sign-in it already holds; with --through-app the
#    real helper starts it on the Gemini login. Nobody signs in here;
#    nothing reads an account folder;
# 3. leverage:verify_log on the project's database;
# 4. the secret scan over this script's log, the containers', the helper's
#    and the runner's logs, a data-only dump and the output folder: what
#    milestones 2 and 3 scan for, every frame's nonce in a log, and the two
#    tasks' titles in any event's payload or log line (RT-8).
# The seat token issued with the landing prompt, the owner's session token and the
# helper's token go from the response into the test's memory and from there
# only into a child process's environment or a request header. The script
# never runs under set -x and prints no response body; the output folder
# holds the event list (types and ids), the two tasks' states and the
# verify_log result, and none of the tool's output.
#
# Exit 0 when it passed, 1 when it failed (the folder is kept and named), 2
# for a refusal, 3 when the tool is not installed. A failure does not block
# the merge; the managing agent records it for the owner.
#
# Environment it reads besides the switch (optional): API_IMAGE_TAG (used as
# it is; by default the run builds and removes an image of its own);
# LEVERAGE_E2E_SCRATCH (Swift's build folder, default mac/.build);
# LEVERAGE_RULE_CHECK_OUT (a folder the output folder is copied to);
# LEVERAGE_E2E_KEEP=1 keeps the run's folder when it passes.
set -euo pipefail

say() { printf 'real_rule_check: %s\n' "$*" >&2; }
refuse() {
  printf 'real_rule_check: refused: %s\n' "$*" >&2
  exit 2
}
usage="usage: LEVERAGE_REAL_PROVIDER=<p> scripts/real_rule_check.sh <p> [--through-app],"
usage="$usage where <p> is claude, codex or gemini (--through-app: gemini only)"

if [ -n "${CI:-}" ]; then
  refuse "CI is set; this check never runs in CI"
fi
if [ $# -lt 1 ]; then
  refuse "$usage"
fi
provider=$1
shift
case "$provider" in
  claude) program=claude ;;
  codex) program=codex ;;
  gemini) program=agy ;;
  *) refuse "unknown provider '$provider'; $usage" ;;
esac
through_app=0
while [ $# -gt 0 ]; do
  case "$1" in
    --through-app) through_app=1 ;;
    *) refuse "unknown argument '$1'; $usage" ;;
  esac
  shift
done
if [ "$through_app" = 1 ] && [ "$provider" != gemini ]; then
  refuse "--through-app is for gemini only: only Antigravity's login can be added with no sign-in"
fi

# The path: the real tool, or the stand-ins. Exactly one.
tool_dir="${LEVERAGE_TOOL_DIR:-}"
if [ -n "$tool_dir" ]; then
  if [ -n "${LEVERAGE_REAL_PROVIDER+set}" ]; then
    refuse "set LEVERAGE_REAL_PROVIDER or LEVERAGE_TOOL_DIR, not both"
  fi
  case "$tool_dir" in
    /*) ;;
    *) refuse "LEVERAGE_TOOL_DIR must be an absolute path" ;;
  esac
  if [ ! -x "$tool_dir/$program" ] || [ ! -f "$tool_dir/../provider_tool.py" ]; then
    refuse "LEVERAGE_TOOL_DIR is not the bin/ of a copy of mac/Tests/StandIns"
  fi
  mode=stand-ins
elif [ "${LEVERAGE_REAL_PROVIDER:-}" != "$provider" ]; then
  refuse "set LEVERAGE_REAL_PROVIDER=$provider to run the check with the real $program"
else
  mode=real
fi

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

if [ "$mode" = real ]; then
  tool=$(command -v -- "$program" 2>/dev/null || true)
else
  tool="$tool_dir/$program"
fi
case "$tool" in
  /*) ;;
  *)
    say "skipped: not installed ($program is not on PATH)"
    exit 3
    ;;
esac
say "tool: $tool ($mode)"

for file in compose.yaml compose.test.yaml; do
  if [ ! -f "$file" ]; then
    say "failed: $file is missing"
    exit 1
  fi
done

export COMPOSE_PROJECT_NAME="leverage-real-rule-check-$$"
own_image=""
if [ -z "${API_IMAGE_TAG:-}" ]; then
  export API_IMAGE_TAG="$COMPOSE_PROJECT_NAME"
  own_image="leverage-api:$API_IMAGE_TAG"
fi
scratch="${LEVERAGE_E2E_SCRATCH:-$root/mac/.build}"
out=$(mktemp -d "${TMPDIR:-/tmp}/leverage-real-rule-check.XXXXXX")
out=$(cd "$out" && pwd -P)
results="$out/results"
mkdir -p "$results"
log="$out/script.log"
: >"$log"
# Every progress line also goes to the script's own log, which is scanned.
say() { printf 'real_rule_check: %s\n' "$*" | tee -a "$log" >&2; }

U() { docker compose -f compose.yaml -f compose.test.yaml "$@"; }

finish() {
  status=$?
  trap - EXIT INT TERM
  if [ "$status" -ne 0 ]; then
    U logs --no-color >"$out/containers.log" 2>&1 || true
  fi
  U down --volumes --remove-orphans >/dev/null 2>&1 || true
  if [ -n "$own_image" ]; then docker image rm "$own_image" >/dev/null 2>&1 || true; fi
  if [ -n "${LEVERAGE_RULE_CHECK_OUT:-}" ]; then
    mkdir -p "$LEVERAGE_RULE_CHECK_OUT" && cp -R "$results/." "$LEVERAGE_RULE_CHECK_OUT/" || true
  fi
  if [ "$status" -eq 0 ] && [ "${LEVERAGE_E2E_KEEP:-}" != "1" ]; then
    rm -rf "$out"
    printf 'real_rule_check: passed\n' >&2
  else
    printf "real_rule_check: kept the run's folder: %s\n" "$out" >&2
    if [ "$status" -eq 0 ]; then
      printf 'real_rule_check: passed\n' >&2
    else
      printf 'real_rule_check: FAILED (exit %s)\n' "$status" >&2
    fi
  fi
  exit "$status"
}
trap finish EXIT
trap 'exit 130' INT TERM

if [ ! -f .env ]; then
  cp .env.example .env
  say "made .env from .env.example"
fi

# 1. The containers, and the e2e lane.
say "starting db, api and sweep as project $COMPOSE_PROJECT_NAME"
if [ -n "$own_image" ]; then
  U up -d --build --wait --wait-timeout 300 db api sweep >>"$log" 2>&1
else
  U up -d --wait --wait-timeout 300 db api sweep >>"$log" 2>&1
fi
port=$(U port api 3000 | sed 's/.*://')
export LEVERAGE_API_URL="http://127.0.0.1:$port"
curl -fsS "$LEVERAGE_API_URL/v1/health" >/dev/null
say "the API answers on $LEVERAGE_API_URL"
say "building the e2e lane in $scratch"
(cd mac && LEVERAGE_ONLY=e2e swift build --build-tests --scratch-path "$scratch") >>"$log" 2>&1

# 2. The test.
if [ "$through_app" = 1 ]; then name=testThroughTheApp; else name=testRunnerOnItsOwn; fi
say "running RealRuleCheckTests/$name (two contracts, 5 minutes at most)"
(
  cd mac
  export LEVERAGE_ONLY=e2e
  export LEVERAGE_E2E=real_rule_check
  export LEVERAGE_E2E_DIR="$out/tests"
  export LEVERAGE_RULE_CHECK_PROVIDER="$provider"
  export LEVERAGE_RULE_CHECK_TOOL="$tool"
  export LEVERAGE_RULE_CHECK_RESULTS="$results"
  swift test --skip-build --scratch-path "$scratch" --filter "RealRuleCheckTests/$name"
) >>"$log" 2>&1 || {
  grep -E '^(✘|✔)' "$log" | tail -n 20 >&2 || true
  say "failed: the test did not pass"
  exit 1
}
ran=$(find "$out/tests" -mindepth 2 -maxdepth 2 -name secrets.txt 2>/dev/null | wc -l | tr -d ' ')
if [ "$ran" -ne 1 ]; then
  say "failed: expected the one test to run; $ran wrote their secrets"
  exit 1
fi
grep -E '^(✘|✔) Test ' "$log" | tail -n 5 >&2 || true

# 3. Replay and audit.
say "running leverage:verify_log"
U exec -T api bin/rails leverage:verify_log >"$results/verify_log.txt" 2>&1 || {
  cat "$results/verify_log.txt" >&2
  say "failed: leverage:verify_log"
  exit 1
}
cat "$results/verify_log.txt" >&2

# 4. The secret scan.
U logs --no-color >"$out/containers.log" 2>&1
# shellcheck disable=SC2016 # expanded by the db container's shell
U exec -T db sh -c 'pg_dump --data-only --no-owner -U "$POSTGRES_USER" leverage_production' \
  >"$out/dump.sql" 2>"$out/dump.err"
scan=(python3 -I scripts/secret_scan.py)
for secrets in "$out"/tests/*/secrets.txt; do scan+=(--secrets "$secrets"); done
for logs in "$out"/tests/*/support/logs; do scan+=("$logs" --logs "$logs"); done
for words in "$out"/tests/*/markers.txt; do
  while IFS= read -r word; do
    if [ -n "$word" ]; then scan+=(--not-in-events "$word" --not-in-logs "$word"); fi
  done <"$words"
done
scan+=(--events-dump "$out/dump.sql" --logs "$out/containers.log" --logs "$log")
scan+=("$out/containers.log" "$out/dump.sql" "$results" "$log")
say "scanning the logs, the dump and the output folder"
"${scan[@]}" >&2
