#!/usr/bin/env bash
# Run an eval suite's cases through the production runner and score them
# against evals/<suite>/bar.json.
#
#   LEVERAGE_EVAL=specific-details LEVERAGE_TOOL_DIR=<stand-ins>/bin \
#     scripts/eval_rule.sh specific-details --out <folder>
#   LEVERAGE_EVAL=approves-actions LEVERAGE_EVAL_REAL=1 \
#     scripts/eval_rule.sh approves-actions [--held-out]
#
# Only the managing agent runs on real tools (plan §5.3). The real path
# verifies the frozen case sets and checks the budget before resolving a
# tool. It reserves the worst case in runs.json before each provider runs,
# and settles that reservation only after a completed run. Stopped or
# failed runs keep their reservation.
#
# The script builds the runner and resolves the providers' tools before
# any case goes out. A container builds the job inputs with a canary file
# path, but no canary word in the prompts. Each provider gets the suite's
# tool-run and retry ceilings. The stand-ins get temporary account folders
# or their own sign-in marks. Real tools use the login they already hold.
#
# Results go to results/<provider>.json or results/held-out/<provider>.json,
# and the suite's report goes to RESULTS.md. Stand-in runs use --out for
# those files and never write the ledger. A tool found signed out or at
# its limit before the run is left out of LEVERAGE_EVAL_PROVIDERS and recorded
# with scripts/eval_score.py not-run.
#
# Exit 0 when every provider was run and scored, 1 when a step failed,
# 2 for a refusal, or 3 when the budget is used up.
#
# Optional environment:
#   LEVERAGE_EVAL_PROVIDERS   providers to run (default from the suite)
#   LEVERAGE_EVAL_CODEX_HOME  Codex account folder for the real path
#   LEVERAGE_EVAL_SCRATCH     Swift's build folder (default mac/.build/eval)
#   API_IMAGE_TAG             API image (by default build and remove our own)
set -euo pipefail

say() { printf 'eval: %s\n' "$*"; }
refuse() {
  printf 'eval_rule: refused: %s\n' "$*" >&2
  exit 2
}
usage="usage: LEVERAGE_EVAL=<suite> (LEVERAGE_TOOL_DIR=<stand-ins>/bin | LEVERAGE_EVAL_REAL=1)"
usage="$usage scripts/eval_rule.sh <suite> [--held-out] [--out <folder>]"

# --- The guards: nothing has started yet ----------------------------------

if [ -n "${CI:-}" ]; then
  refuse "CI is set; the eval suite never runs in CI"
fi
if [ $# -lt 1 ]; then
  refuse "$usage"
fi
suite_name=$1
shift
case "$suite_name" in
  "" | *[!a-z0-9-]*) refuse "invalid suite name '$suite_name'; $usage" ;;
esac
if [ "${LEVERAGE_EVAL:-}" != "$suite_name" ]; then
  refuse "set LEVERAGE_EVAL=$suite_name to run the suite"
fi
tool_dir=${LEVERAGE_TOOL_DIR:-}
real=${LEVERAGE_EVAL_REAL:-}
if [ -n "$real" ] && [ "$real" != "1" ]; then
  refuse "LEVERAGE_EVAL_REAL is 1 or unset"
fi
if [ -n "$tool_dir" ] && [ -n "$real" ]; then
  refuse "LEVERAGE_TOOL_DIR and LEVERAGE_EVAL_REAL are both set; set one"
fi
if [ -z "$tool_dir" ] && [ -z "$real" ]; then
  refuse "set LEVERAGE_TOOL_DIR (the stand-ins) or LEVERAGE_EVAL_REAL=1 (real tools)"
fi

out=""
set_flag=()
while [ $# -gt 0 ]; do
  case "$1" in
    --out)
      if [ $# -lt 2 ] || [ -z "$2" ]; then refuse "--out needs a folder; $usage"; fi
      out=$2
      shift 2
      ;;
    --held-out)
      set_flag=(--held-out)
      shift
      ;;
    *) refuse "unknown argument '$1'; $usage" ;;
  esac
done

root=$(cd "$(dirname "$0")/.." && pwd -P)
suite="$root/evals/$suite_name"
if [ ! -f "$suite/bar.json" ]; then refuse "unknown suite '$suite_name'; $usage"; fi

score() { python3 -I "$root/scripts/eval_score.py" "$@"; }
config() { score config "$suite" "$@" ${set_flag[@]+"${set_flag[@]}"}; }
kind=$(config kind)
maximum_tool_runs=$(config maximum_tool_runs)
maximum_second_tries=$(config maximum_second_tries)
providers=${LEVERAGE_EVAL_PROVIDERS:-}
if [ -z "$providers" ]; then providers=$(config supported_providers); fi
if [ -z "${providers//[[:space:]]/}" ]; then refuse "LEVERAGE_EVAL_PROVIDERS names no provider"; fi
read -r -a provider_list <<< "${providers//$'\n'/ }"
providers="${provider_list[*]}"
seen=""
for provider in "${provider_list[@]}"; do
  case "$provider" in
    claude | codex | gemini | grok) ;;
    *) refuse "unknown provider '$provider' in LEVERAGE_EVAL_PROVIDERS; each is claude, codex, gemini or grok" ;;
  esac
  case "$seen" in *" $provider "*) refuse "provider '$provider' is named twice" ;; esac
  seen="$seen $provider "
done

if [ -n "$tool_dir" ]; then
  case "$tool_dir" in
    /*) ;;
    *) refuse "LEVERAGE_TOOL_DIR is not an absolute path" ;;
  esac
  if [ ! -d "$tool_dir" ] || [ ! -f "$tool_dir/../provider_tool.py" ]; then
    refuse "LEVERAGE_TOOL_DIR is not the bin/ of a copy of the stand-ins (mac/Tests/StandIns)"
  fi
  tool_dir=$(cd "$tool_dir" && pwd -P)
  if [ -z "$out" ]; then refuse "a run against the stand-ins writes its results to --out <folder>"; fi
  out_parent=$(dirname "$out")
  if [ ! -d "$out_parent" ]; then refuse "--out's parent folder does not exist"; fi
  out_abs="$(cd "$out_parent" && pwd -P)/$(basename "$out")"
  if [ -d "$out_abs" ]; then out_abs=$(cd "$out_abs" && pwd -P); fi
  case "$out_abs/" in
    "$root/evals/"*) refuse "--out is inside the repository's evals folder" ;;
  esac
  path_kind="stand-ins"
else
  if [ -n "$out" ]; then refuse "a run on real tools writes into $suite; it takes no --out"; fi
  out_abs="$suite"
  path_kind="real tools"
fi

# --- From here things run ---------------------------------------------------

cd "$root"
today=$(date -u +%Y-%m-%d)
shipped="$root/api/contract/shipped_rules.json"
role_file="$root/api/config/role_files/orchestrator.md"
work=""
pending_results=""
suite_lock=""
compose_started=""
own_image=""

# Invoked by the EXIT trap.
# shellcheck disable=SC2329
finish() {
  status=$?
  trap - EXIT INT TERM
  if [ -n "$compose_started" ]; then
    docker compose down --volumes --remove-orphans >/dev/null 2>&1 || true
  fi
  if [ -n "$own_image" ] && [ -n "$compose_started" ]; then
    docker image rm "$own_image" >/dev/null 2>&1 || true
  fi
  if [ -n "$work" ]; then rm -rf "$work"; fi
  if [ -n "$pending_results" ]; then rm -rf "$pending_results"; fi
  if [ -n "$suite_lock" ]; then rmdir "$suite_lock"; fi
  if [ "$status" -ne 0 ]; then say "FAILED (exit $status)"; fi
  exit "$status"
}
trap finish EXIT
trap 'exit 130' INT TERM

if [ "$path_kind" = "real tools" ]; then
  # 1. Lock and check the ledger before any tool is looked for. Hold the
  # lock through settlement so that two invocations cannot spend the same room.
  if ! mkdir "$suite/.eval-run.lock" 2>/dev/null; then
    refuse "cannot lock the real-run budget for $suite_name"
  fi
  suite_lock="$suite/.eval-run.lock"
  score verify-cases "$suite" ${set_flag[@]+"${set_flag[@]}"}
  score budget --suite "$suite" --runs "$suite/runs.json" --providers "$providers" \
    --shipped "$shipped" --role-file "$role_file" ${set_flag[@]+"${set_flag[@]}"}
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/leverage-eval.XXXXXX")
work=$(cd "$work" && pwd -P)
export COMPOSE_PROJECT_NAME="leverage-eval-$$"
if [ -z "${API_IMAGE_TAG:-}" ]; then
  export API_IMAGE_TAG="$COMPOSE_PROJECT_NAME"
  own_image="leverage-api:$API_IMAGE_TAG"
fi

say "a run on $path_kind${tool_dir:+ from $tool_dir}; providers: $providers"

# 2. The runner, and the tool each provider resolves to.
scratch="${LEVERAGE_EVAL_SCRATCH:-$root/mac/.build/eval}"
if ! (cd "$root/mac" && TMPDIR="$work" LEVERAGE_ONLY=runner swift build --product LeverageRunner \
  --scratch-path "$scratch") >"$work/build.log" 2>&1; then
  tail -n 40 "$work/build.log" >&2
  say "the runner did not build"
  exit 1
fi
runner="$(cd "$root/mac" && LEVERAGE_ONLY=runner swift build --product LeverageRunner --scratch-path "$scratch" \
  --show-bin-path 2>/dev/null)/LeverageRunner"
if [ ! -x "$runner" ]; then
  say "the runner is not at $runner"
  exit 1
fi

# The runner's environment: the switch of this path and nothing else of
# leverage's. LEVERAGE_DEV_TOOL_LOGIN only on the real path (PV-6).
run_eval() {
  local ceilings=(
    "LEVERAGE_EVAL_MAX_TOOL_RUNS=$maximum_tool_runs"
    "LEVERAGE_EVAL_MAX_SECOND_TRIES=$maximum_second_tries"
  )
  if [ "$path_kind" = "real tools" ]; then
    env -u LEVERAGE_TOOL_DIR LEVERAGE_EVAL="$suite_name" LEVERAGE_EVAL_REAL=1 LEVERAGE_DEV_TOOL_LOGIN=1 \
      "${ceilings[@]}" "$runner" eval "$@"
  else
    env -u LEVERAGE_EVAL_REAL -u LEVERAGE_DEV_TOOL_LOGIN LEVERAGE_EVAL="$suite_name" LEVERAGE_TOOL_DIR="$tool_dir" \
      "${ceilings[@]}" "$runner" eval "$@"
  fi
}
for provider in "${provider_list[@]}"; do
  run_eval --provider "$provider" --resolve-only || exit 1
done

# 3. The canary, and the inputs. .env holds made-up values; the example
# is used when there is none, as scripts/e2e_core_loop.sh does.
if [ ! -f "$root/.env" ]; then
  cp "$root/.env.example" "$root/.env"
  say "made .env from .env.example"
fi
mkdir -p "$work/canary" "$work/inputs" "$work/verdicts" "$work/accounts"
canary=$(python3 -I -c '
import secrets
first = "bdfgklmnprstvz"
vowels = "aeiou"
print("".join(secrets.choice(first) + secrets.choice(vowels) for _ in range(4)) + secrets.choice(first) + "ex")')
printf '%s\n' "$canary" >"$work/canary/word.txt"

if [ -n "$own_image" ]; then
  say "building the API image $own_image"
  compose_started=1
  docker compose build api >"$work/image.log" 2>&1 || {
    tail -n 40 "$work/image.log" >&2
    exit 1
  }
fi
say "building the inputs in the container (project $COMPOSE_PROJECT_NAME)"
compose_started=1
if ! docker compose run --rm -T -e RAILS_ENV=development -v "$root/api:/rails" -v "$suite:/eval-suite:ro" -v "$work/inputs:/eval-inputs" \
  api bash -c 'bin/rails db:prepare >/dev/null && bin/rails runner script/evals/build_inputs.rb --suite /eval-suite \
    --canary-path "$0" --out /eval-inputs/inputs.json "$@"' "$work/canary/word.txt" \
  ${set_flag[@]+"${set_flag[@]}"} >"$work/inputs.log" 2>&1; then
  tail -n 40 "$work/inputs.log" >&2
  say "the inputs were not built"
  exit 1
fi
docker compose down --volumes --remove-orphans >/dev/null 2>&1 || true
say "$(tail -n 1 "$work/inputs.log")"

# 4 and 5. Each provider's run, scored.
results="$out_abs/results"
if [ "${#set_flag[@]}" -gt 0 ]; then results="$results/held-out"; fi
mkdir -p "$results"
record_results="$results"
if [ "$path_kind" = "real tools" ]; then
  # Score into a directory beside the final result so that publication is
  # a rename after the ledger has settled.
  pending_results=$(mktemp -d "$results/.pending.XXXXXX")
  record_results="$pending_results"
fi
failed=0
for provider in "${provider_list[@]}"; do
  account=()
  if [ "$path_kind" = "stand-ins" ]; then
    folder="$work/accounts/$provider"
    mkdir -p "$folder"
    case "$provider" in
      claude | codex) : >"$folder/.standin-signed-in" ;;
      gemini) mkdir -p "$tool_dir/../state" && : >"$tool_dir/../state/signed-in-agy" ;;
      grok) mkdir -p "$tool_dir/../state" && : >"$tool_dir/../state/signed-in-grok" ;;
    esac
    account=(--account-folder "$folder")
  elif [ "$provider" = "codex" ] && [ -n "${LEVERAGE_EVAL_CODEX_HOME:-}" ]; then
    account=(--account-folder "$LEVERAGE_EVAL_CODEX_HOME")
  fi
  verdicts="$work/verdicts/$provider.jsonl"
  if [ "$path_kind" = "real tools" ]; then
    score runs-add --suite "$suite" --runs "$suite/runs.json" --provider "$provider" --date "$today" \
      --shipped "$shipped" --role-file "$role_file" ${set_flag[@]+"${set_flag[@]}"}
  fi
  say "$provider: running the $kind suite"
  status=0
  run_eval --inputs "$work/inputs/inputs.json" --provider "$provider" --out "$verdicts" \
    ${account[@]+"${account[@]}"} || status=$?
  if [ "$status" -ne 0 ]; then
    say "$provider: the run failed (exit $status); no result recorded"
    failed=1
    continue
  fi
  scored="$record_results/$provider.json"
  score record --suite "$suite" --provider "$provider" --verdicts "$verdicts" --canary "$canary" \
    --shipped "$shipped" --role-file "$role_file" --date "$today" --out "$scored" \
    ${set_flag[@]+"${set_flag[@]}"} | sed 's/^/eval: /'
  if [ "$path_kind" = "real tools" ]; then
    made=$(python3 -I -c '
import json, sys
with open(sys.argv[1], encoding="utf-8") as file:
    print(json.load(file)["tool_runs"])' "$scored")
    score runs-settle --suite "$suite" --runs "$suite/runs.json" --provider "$provider" --tool-runs "$made" \
      ${set_flag[@]+"${set_flag[@]}"}
    mv "$scored" "$results/$provider.json"
  fi
done

if [ "$path_kind" = "stand-ins" ]; then
  cp "$suite/bar.json" "$out_abs/bar.json"
  mkdir -p "$out_abs/cases"
  cp "$suite"/cases/*.json "$out_abs/cases/"
fi
score report --suite "$out_abs"
say "wrote $out_abs/RESULTS.md"
exit "$failed"
