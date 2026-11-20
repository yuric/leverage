#!/usr/bin/env bash
# The eval suite's run (milestone 4 plan RV-3 to RV-6, §2.4, §5.3): every
# case of evals/<suite>/ through the production path outside the server,
# on each provider's tool, scored against the bar.
#
#   LEVERAGE_EVAL=specific-details LEVERAGE_TOOL_DIR=<stand-ins>/bin \
#     scripts/eval_rule.sh specific-details --out <folder>      # stand-ins
#   LEVERAGE_EVAL=specific-details LEVERAGE_EVAL_REAL=1 \
#     scripts/eval_rule.sh specific-details                     # real tools
#
# The run on real tools is the managing agent's alone (plan §5.3), never in
# CI. Any agent may run it against the stand-ins.
#
# It refuses (exit 2, before it starts anything) when CI is set; when
# LEVERAGE_EVAL is not the suite named as the argument, or that is not
# specific-details; when it is not true that exactly one of
# LEVERAGE_TOOL_DIR and LEVERAGE_EVAL_REAL=1 is set; when
# LEVERAGE_TOOL_DIR is not the bin/ of a copy of mac/Tests/StandIns (an
# absolute path, beside provider_tool.py); when a run against the
# stand-ins has no --out, or one inside the repository's suite folder;
# when a run on real tools is given --out; for an unknown provider or
# option. That guards against CI and accidents; it is nobody's consent.
#
# Then:
# 1. On the real path, `eval_score.py budget` over runs.json, before any
#    tool is looked for: exit 3 when one more full run of a provider would
#    pass 3 runs or 90 tool runs of a model, or 270 in all.
# 2. It builds LeverageRunner (the runner lane) and prints the tool each
#    provider resolves to (`LeverageRunner eval --resolve-only`), before
#    any case goes out. On the stand-in path each is under LEVERAGE_TOOL_DIR.
# 3. It writes one made-up word into a file of the run's own folder, the
#    canary, and builds the inputs: api/script/evals/build_inputs.rb, in a
#    container of a compose project of its own that mounts the checkout's
#    api/ and the suite, so that it runs the checkout's code and not that
#    of whatever image is tagged. {{CANARY_PATH}} becomes the canary's path;
#    the word is in no prompt.
# 4. For each provider of LEVERAGE_EVAL_PROVIDERS (default "claude codex
#    gemini"): `LeverageRunner eval`, one run per case, at most 6 second
#    tries and 30 tool runs, each limited to 120 seconds. On the stand-in
#    path each provider's run gets a new empty folder as --account-folder,
#    signed in the stand-ins' own way (a mark file); agy and grok, which
#    keep one sign-in for the Mac, are signed in in the copy's state/. On
#    the real path LEVERAGE_DEV_TOOL_LOGIN=1, so each tool uses the sign-in
#    it already holds for this Mac user; nothing is signed in and no account
#    folder is read. LEVERAGE_EVAL_CODEX_HOME, when set, goes to the Codex
#    run alone as --account-folder (its CODEX_HOME). The real path reserves
#    30 tool runs in runs.json before each provider's run and settles the
#    count after it.
# 5. It scores each provider's lines (eval_score.py record) into
#    results/<provider>.json and writes RESULTS.md: in the suite folder on
#    the real path, in --out on the stand-in path (runs.json is never
#    touched there).
#
# A provider whose tool is found signed out or at its limit before the run
# is left out of LEVERAGE_EVAL_PROVIDERS and recorded with
# `scripts/eval_score.py not-run` (plan §5.3, step 5).
#
# Exit 0 when every provider was run and scored (whether or not it met the
# bar, which the last lines say), 1 when a step failed, 2 for a refusal, 3
# when the budget is used up.
#
# Environment it reads besides the switches (all optional):
#   LEVERAGE_EVAL_PROVIDERS   the providers to run (claude codex gemini grok)
#   LEVERAGE_EVAL_CODEX_HOME  the Codex account folder to run on (real path)
#   LEVERAGE_EVAL_SCRATCH     Swift's build folder (default mac/.build/eval)
#   API_IMAGE_TAG             the API image to run build_inputs.rb in; by
#                             default the run builds its own and removes it
set -euo pipefail

say() { printf 'eval: %s\n' "$*"; }
refuse() {
  printf 'eval_rule: refused: %s\n' "$*" >&2
  exit 2
}
usage="usage: LEVERAGE_EVAL=specific-details (LEVERAGE_TOOL_DIR=<stand-ins>/bin | LEVERAGE_EVAL_REAL=1)"
usage="$usage scripts/eval_rule.sh specific-details [--out <folder>]"

# --- The guards: nothing has started yet ----------------------------------

if [ -n "${CI:-}" ]; then
  refuse "CI is set; the eval suite never runs in CI"
fi
if [ $# -lt 1 ]; then
  refuse "$usage"
fi
suite_name=$1
shift
if [ "$suite_name" != "specific-details" ]; then
  refuse "the suite is specific-details, not '$suite_name'; $usage"
fi
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
while [ $# -gt 0 ]; do
  case "$1" in
    --out)
      if [ $# -lt 2 ] || [ -z "$2" ]; then refuse "--out needs a folder; $usage"; fi
      out=$2
      shift 2
      ;;
    *) refuse "unknown argument '$1'; $usage" ;;
  esac
done

providers=${LEVERAGE_EVAL_PROVIDERS:-claude codex gemini}
for provider in $providers; do
  case "$provider" in
    claude | codex | gemini | grok) ;;
    *) refuse "unknown provider '$provider' in LEVERAGE_EVAL_PROVIDERS; each is claude, codex, gemini or grok" ;;
  esac
done
if [ -z "${providers// /}" ]; then refuse "LEVERAGE_EVAL_PROVIDERS names no provider"; fi

root=$(cd "$(dirname "$0")/.." && pwd -P)
suite="$root/evals/$suite_name"

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
  case "$out_abs/" in
    "$suite/"*) refuse "--out is inside the suite folder; a stand-in run never writes there" ;;
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
score() { python3 -I "$root/scripts/eval_score.py" "$@"; }

if [ "$path_kind" = "real tools" ]; then
  # 1. The budget, before any tool is looked for.
  budget=0
  score budget --runs "$suite/runs.json" --providers "$providers" || budget=$?
  if [ "$budget" -ne 0 ]; then
    say "the budget of RV-6 refuses this run"
    exit "$budget"
  fi
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/leverage-eval.XXXXXX")
work=$(cd "$work" && pwd -P)
export COMPOSE_PROJECT_NAME="leverage-eval-$$"
own_image=""
if [ -z "${API_IMAGE_TAG:-}" ]; then
  export API_IMAGE_TAG="$COMPOSE_PROJECT_NAME"
  own_image="leverage-api:$API_IMAGE_TAG"
fi
compose_started=""

finish() {
  status=$?
  trap - EXIT INT TERM
  if [ -n "$compose_started" ]; then
    docker compose down --volumes --remove-orphans >/dev/null 2>&1 || true
  fi
  if [ -n "$own_image" ] && [ -n "$compose_started" ]; then
    docker image rm "$own_image" >/dev/null 2>&1 || true
  fi
  rm -rf "$work"
  if [ "$status" -ne 0 ]; then say "FAILED (exit $status)"; fi
  exit "$status"
}
trap finish EXIT
trap 'exit 130' INT TERM

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
  if [ "$path_kind" = "real tools" ]; then
    env -u LEVERAGE_TOOL_DIR LEVERAGE_EVAL="$suite_name" LEVERAGE_EVAL_REAL=1 LEVERAGE_DEV_TOOL_LOGIN=1 \
      "$runner" eval "$@"
  else
    env -u LEVERAGE_EVAL_REAL -u LEVERAGE_DEV_TOOL_LOGIN LEVERAGE_EVAL="$suite_name" LEVERAGE_TOOL_DIR="$tool_dir" \
      "$runner" eval "$@"
  fi
}
for provider in $providers; do
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
    --canary-path "$0" --out /eval-inputs/inputs.json' "$work/canary/word.txt" >"$work/inputs.log" 2>&1; then
  tail -n 40 "$work/inputs.log" >&2
  say "the inputs were not built"
  exit 1
fi
docker compose down --volumes --remove-orphans >/dev/null 2>&1 || true
say "$(tail -n 1 "$work/inputs.log")"

hashes=$(python3 -I -c '
import sys
sys.path.insert(0, sys.argv[1])
import eval_score
print(eval_score.instruction_sha256(eval_score.read_json(sys.argv[2])),
      eval_score.cases_sha256(eval_score.read_cases(sys.argv[3])))' \
  "$root/scripts" "$root/api/contract/shipped_rules.json" "$suite")
instruction_sha=${hashes% *}
cases_sha=${hashes#* }

# 4 and 5. Each provider's run, scored.
mkdir -p "$out_abs/results"
failed=0
for provider in $providers; do
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
    score runs-add --runs "$suite/runs.json" --provider "$provider" --date "$today" \
      --instruction-sha256 "$instruction_sha" --cases-sha256 "$cases_sha"
  fi
  say "$provider: running the suite"
  status=0
  run_eval --inputs "$work/inputs/inputs.json" --provider "$provider" --out "$verdicts" \
    ${account[@]+"${account[@]}"} || status=$?
  made=0
  if [ -f "$verdicts" ]; then
    made=$(python3 -I -c '
import json, sys
print(sum(json.loads(line).get("tool_runs", 0) for line in open(sys.argv[1]) if line.strip()))' "$verdicts")
  fi
  if [ "$path_kind" = "real tools" ]; then
    score runs-settle --runs "$suite/runs.json" --provider "$provider" --tool-runs "$made"
  fi
  if [ "$status" -ne 0 ]; then
    say "$provider: the run failed (exit $status) after $made tool runs; no result recorded"
    failed=1
    continue
  fi
  score record --suite "$suite" --provider "$provider" --verdicts "$verdicts" --canary "$canary" \
    --date "$today" --out "$out_abs/results/$provider.json" | sed 's/^/eval: /'
done

if [ "$path_kind" = "stand-ins" ]; then
  cp "$suite/bar.json" "$out_abs/bar.json"
  mkdir -p "$out_abs/cases"
  cp "$suite"/cases/*.json "$out_abs/cases/"
fi
score report --suite "$out_abs"
say "wrote $out_abs/RESULTS.md"
exit "$failed"
