#!/usr/bin/env bash
# Self-test of the guards and suite selection of scripts/eval_rule.sh.
# Every case runs an isolated copy under `env -i`. The real-mode refusal
# cases use made-up files and intercept every tool the script can start.
#
# The refusal cases give the script something it must refuse before it
# starts a tool: CI set; no LEVERAGE_EVAL; LEVERAGE_EVAL set but
# neither LEVERAGE_TOOL_DIR nor LEVERAGE_EVAL_REAL; another suite, in the
# variable or as the argument; a LEVERAGE_TOOL_DIR that is not a copy of
# the stand-ins; a run against the stand-ins with no --out, or with --out
# in the repository's suite folder; an unknown provider. PATH holds shims
# named claude, codex, agy, grok, docker and swift that record being
# called. Refusals start none and create no output folder. Allowed runs
# use the same shims to record the suite, case set and ceilings.
#
#   bash scripts/test_eval_rule.sh
#
# Exit 0 when every case behaves as expected, 1 otherwise. It needs bash
# and the programs every Mac and Linux runner has; nothing is built.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/leverage-test-eval-rule.XXXXXX")
trap 'rm -rf "$work"' EXIT
work=$(cd "$work" && pwd -P)
system_path="$(dirname "$(command -v python3)"):/usr/bin:/bin"
# Use a disposable checkout, including for the real-mode refusal cases.
repo="$work/repo"
script="$repo/scripts/eval_rule.sh"
approval="$repo/evals/approves-actions"
mkdir -p "$repo/scripts" "$repo/mac" "$repo/evals/specific-details/cases" "$approval/cases" "$approval/held_out"
cp "$root/scripts/eval_rule.sh" "$script"
: >"$repo/.env"
printf '{}\n' >"$repo/evals/specific-details/bar.json"
printf '{}\n' >"$repo/evals/specific-details/cases/only.json"
printf '{}\n' >"$approval/bar.json"
printf '{"id":"main-example"}\n' >"$approval/cases/only.json"
printf '{"id":"held-example"}\n' >"$approval/held_out/only.json"
cp "$approval/cases/only.json" "$work/original-main"
cp "$approval/held_out/only.json" "$work/original-held"

shims="$work/shims"
called="$work/called"
mkdir -p "$shims" "$work/home" "$work/tmp"
: >"$called"
for program in claude codex agy grok; do
  cat >"$shims/$program" <<EOF
#!/bin/sh
echo "$program \$*" >>"$called"
exit 0
EOF
  chmod +x "$shims/$program"
done

# Keep all child commands inside the fixture. The scorer unit tests check
# the hash algorithm. Here the scorer's refusal checks the shell wiring.
cat >"$repo/scripts/eval_score.py" <<'PYTHON'
import json
import os
from pathlib import Path
import sys

# The legacy shell hashes cases by importing these functions.
if __name__ != "__main__":
    def read_json(path):
        return {}
    def read_cases(suite):
        return []
    def instruction_sha256(shipped):
        return "test-instruction"
    def cases_sha256(cases):
        return "test-cases"
command, *args = sys.argv[1:] if __name__ == "__main__" else ["legacy-import"]
root = Path(__file__).resolve().parent.parent
work = root.parent

def option(name):
    return args[args.index(name) + 1]

logged = list(args)
if "--canary" in logged:
    logged[logged.index("--canary") + 1] = "<canary>"
with (work / "scoring").open("a") as log:
    print(command, *logged, file=log)

if command == "config":
    suite, key, *_ = args
    approval = Path(suite).name == "approves-actions"
    held_out = "--held-out" in args
    if held_out and not approval:
        print("eval_score: refused: this suite has no held-out set", file=sys.stderr)
        sys.exit(2)
    config = {
        "kind": "decision" if approval else "verdict",
        "supported_providers": "gemini" if approval else "claude codex gemini",
        "maximum_tool_runs": 12 if held_out else 36 if approval else 30,
        "maximum_second_tries": 2 if held_out else 6,
    }
    print(config[key])
elif command == "verify-cases":
    suite = Path(args[0])
    for folder, original in (("cases", "original-main"), ("held_out", "original-held")):
        if (suite / folder / "only.json").read_bytes() != (work / original).read_bytes():
            print(f"eval_score: refused: frozen {folder} hash differs", file=sys.stderr)
            sys.exit(2)
elif command == "record":
    if os.environ.get("EVAL_TEST_RECORD_STATUS") == "2":
        print("eval_score: refused: a case has no line", file=sys.stderr)
        sys.exit(2)
    out = Path(option("--out"))
    result = {"tool_runs": 2}
    if "--mode" in args:
        result.update(mode=option("--mode"), role_file_sha256=None)
    out.write_text(json.dumps(result) + "\n")
elif command == "report":
    filename = "RESULTS-general.md" if "--mode" in args else "RESULTS.md"
    (Path(option("--suite")) / filename).write_text("# Test results\n")
elif command in {"runs-add", "runs-settle"}:
    reserved = command == "runs-add"
    Path(option("--runs")).write_text("reserved\n" if reserved else "settled\n")
elif command not in {"budget", "legacy-import"}:
    sys.exit(f"unexpected scorer command {command}")
PYTHON

cat >"$shims/swift" <<EOF
#!/bin/sh
echo "swift \$*" >>"$called"
case "\$*" in *--show-bin-path*) printf '%s\n' "$shims" ;; esac
EOF
cat >"$shims/docker" <<EOF
#!/bin/sh
case " \$* " in *" --held-out "*) selection=held-out ;; *) selection=main ;; esac
echo "docker \$1 \$2 \$selection" >>"$called"
case " \$* " in *" --mode general "*) echo 'inputs mode general' >>"$called" ;; esac
if [ "\$2" = run ]; then
  for argument do
    case "\$argument" in
      *:/eval-inputs) printf '{}\n' >"\${argument%:/eval-inputs}/inputs.json" ;;
    esac
  done
fi
EOF
cat >"$shims/LeverageRunner" <<EOF
#!/bin/sh
case " \$* " in *" --mode general "*) echo 'runner mode general' >>"$called" ;; esac
case " \$* " in
  *" --resolve-only "*)
    echo "runner resolve \$LEVERAGE_EVAL \$3" >>"$called"
    exit 0
    ;;
esac
echo "runner run \$LEVERAGE_EVAL \$LEVERAGE_EVAL_MAX_TOOL_RUNS \$LEVERAGE_EVAL_MAX_SECOND_TRIES" >>"$called"
while [ "\$#" -gt 0 ]; do
  if [ "\$1" = --out ]; then
    printf '{"tool_runs":1}\n' >"\$2"
    exit "\${EVAL_TEST_RUNNER_STATUS:-0}"
  fi
  shift
done
exit 1
EOF
chmod +x "$shims/swift" "$shims/docker" "$shims/LeverageRunner"

# A folder shaped like a copy of the stand-ins (bin/ beside
# provider_tool.py), whose programs are shims too: nothing in it may run.
standins="$work/StandIns"
mkdir -p "$standins/bin"
: >"$standins/provider_tool.py"
for program in claude codex agy grok; do cp "$shims/$program" "$standins/bin/$program"; done

failures=0
cases=0

# check <name> <expected exit> <environment...> -- <arguments...>
check() {
  local name=$1 expected=$2
  shift 2
  local environment=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do
    environment+=("$1")
    shift
  done
  shift
  cases=$((cases + 1))
  : >"$called"
  rm -rf "$work/out"
  local status=0 output
  output=$(env -i PATH="$shims:$system_path" HOME="$work/home" TMPDIR="$work/tmp" ${environment[@]+"${environment[@]}"} \
    bash "$script" "$@" 2>&1) || status=$?
  local problems=()
  if [ "$status" -ne "$expected" ]; then problems+=("exit $status, not $expected"); fi
  if [ -s "$called" ]; then problems+=("started: $(tr '\n' ';' <"$called")"); fi
  if [ -e "$work/out" ]; then problems+=("made the output folder"); fi
  case "$output" in
    *"${EXPECTED_REFUSAL:-refused}"*) ;;
    *) problems+=("did not say ${EXPECTED_REFUSAL:-it refused}") ;;
  esac
  if [ ${#problems[@]} -eq 0 ]; then
    printf 'ok    %s\n' "$name"
  else
    failures=$((failures + 1))
    printf 'FAIL  %s: %s\n' "$name" "${problems[*]}"
    printf '%s\n' "$output" | sed 's/^/      /'
  fi
}

stand_in=(LEVERAGE_EVAL=specific-details "LEVERAGE_TOOL_DIR=$standins/bin")

check "CI is set" 2 CI=true "${stand_in[@]}" -- specific-details --out "$work/out"
check "CI is set to anything" 2 CI=1 "${stand_in[@]}" -- specific-details --out "$work/out"
check "no LEVERAGE_EVAL" 2 "LEVERAGE_TOOL_DIR=$standins/bin" -- specific-details --out "$work/out"
check "LEVERAGE_EVAL but neither LEVERAGE_TOOL_DIR nor LEVERAGE_EVAL_REAL" 2 \
  LEVERAGE_EVAL=specific-details -- specific-details --out "$work/out"
check "LEVERAGE_EVAL, neither switch and no --out" 2 LEVERAGE_EVAL=specific-details -- specific-details
check "LEVERAGE_EVAL names another suite" 2 LEVERAGE_EVAL=approvals "LEVERAGE_TOOL_DIR=$standins/bin" -- \
  specific-details --out "$work/out"
check "the argument names another suite" 2 "${stand_in[@]}" -- approvals --out "$work/out"
check "no suite argument" 2 "${stand_in[@]}" --
check "LEVERAGE_TOOL_DIR is not a copy of the stand-ins" 2 LEVERAGE_EVAL=specific-details \
  "LEVERAGE_TOOL_DIR=$shims" -- specific-details --out "$work/out"
check "LEVERAGE_TOOL_DIR is not absolute" 2 LEVERAGE_EVAL=specific-details LEVERAGE_TOOL_DIR=StandIns/bin -- \
  specific-details --out "$work/out"
check "a run against the stand-ins with no --out" 2 "${stand_in[@]}" -- specific-details
check "--out in the repository's suite folder" 2 "${stand_in[@]}" -- specific-details \
  --out "$repo/evals/specific-details/results"
check "--out cannot write another suite" 2 "${stand_in[@]}" -- specific-details --out "$approval/results"
ln -s "$approval" "$work/out-alias"
check "--out cannot alias a suite" 2 "${stand_in[@]}" -- specific-details --out "$work/out-alias"
check "an unknown provider" 2 "${stand_in[@]}" "LEVERAGE_EVAL_PROVIDERS=claude chatbot" -- \
  specific-details --out "$work/out"
EXPECTED_REFUSAL="named twice" check "a provider cannot run twice" 2 "${stand_in[@]}" \
  LEVERAGE_EVAL_PROVIDERS="claude claude" -- specific-details --out "$work/out"
check "an unknown option" 2 "${stand_in[@]}" -- specific-details --out "$work/out" --fast
EXPECTED_REFUSAL="unknown mode" check "an unknown mode" 2 "${stand_in[@]}" -- \
  specific-details --out "$work/out" --mode reviewer
EXPECTED_REFUSAL="--mode needs" check "a missing mode" 2 "${stand_in[@]}" -- \
  specific-details --out "$work/out" --mode

mkdir -p "$repo/approves-actions"
cp "$approval/bar.json" "$repo/approves-actions/bar.json"
EXPECTED_REFUSAL="invalid suite name" check "a suite name cannot escape the evals folder" 2 LEVERAGE_EVAL=../approves-actions \
  "LEVERAGE_TOOL_DIR=$standins/bin" -- ../approves-actions --out "$work/out"
EXPECTED_REFUSAL="unknown suite" check "a suite must exist" 2 LEVERAGE_EVAL=absent \
  "LEVERAGE_TOOL_DIR=$standins/bin" -- absent --out "$work/out"
check "specific-details has no held-out set" 2 "${stand_in[@]}" -- specific-details --held-out --out "$work/out"

real_mode=(LEVERAGE_EVAL=approves-actions LEVERAGE_EVAL_REAL=1)
mkdir "$approval/.eval-run.lock"
EXPECTED_REFUSAL="cannot lock the real-run budget" check "two real-mode runs cannot use the same suite budget" \
  2 "${real_mode[@]}" -- approves-actions
if [ -d "$approval/.eval-run.lock" ]; then
  rmdir "$approval/.eval-run.lock"
else
  failures=$((failures + 1))
  printf 'FAIL  real-mode refusal removed the lock of the other run\n'
fi

# Both sets must match the frozen files, even when only one set will run.
check_frozen() {
  local folder=$1 selection=$2
  local flags=()
  if [ "$selection" = held-out ]; then flags=(--held-out); fi
  cases=$((cases + 1))
  : >"$called"
  : >"$work/scoring"
  printf '{"id":"changed-example"}\n' >"$approval/$folder/only.json"
  local status=0 output
  output=$(env -i PATH="$shims:$system_path" HOME="$work/home" TMPDIR="$work/tmp" \
    "${real_mode[@]}" bash "$script" approves-actions ${flags[@]+"${flags[@]}"} 2>&1) || status=$?
  if [ "$status" -eq 2 ] &&
      [ ! -s "$called" ] &&
      [ ! -e "$approval/results" ] &&
      [ ! -e "$approval/runs.json" ] &&
      [ ! -d "$approval/.eval-run.lock" ] &&
      [ "$(sed -n '/^verify-cases /p' "$work/scoring")" = "verify-cases $approval${flags[*]:+ ${flags[*]}}" ] &&
      [[ "$output" == *"frozen $folder hash differs"* ]]; then
    printf 'ok    changed frozen %s refuses a %s real-mode run before any tool starts\n' "$folder" "$selection"
  else
    failures=$((failures + 1))
    printf 'FAIL  changed frozen %s did not refuse a %s real-mode run before tools (exit %s)\n' "$folder" "$selection" "$status"
    printf '%s\n' "$output" | sed 's/^/      /'
  fi
  case "$folder" in
    cases) cp "$work/original-main" "$approval/$folder/only.json" ;;
    held_out) cp "$work/original-held" "$approval/$folder/only.json" ;;
  esac
}

check_run() {
  local suite=$1 selection=$2 provider=$3 max_runs=$4 max_retries=$5
  local result="results/$provider.json" flags=()
  if [ "$selection" = held-out ]; then
    flags=(--held-out)
    result="results/held-out/$provider.json"
  fi
  cases=$((cases + 1))
  : >"$called"
  : >"$work/scoring"
  if [ "$selection" = main ]; then rm -rf "$work/out"; fi
  local status=0 output
  local provider_env=()
  if [ "$suite" = specific-details ]; then provider_env=(LEVERAGE_EVAL_PROVIDERS="$provider"); fi
  output=$(env -i PATH="$shims:$system_path" HOME="$work/home" TMPDIR="$work/tmp" \
    LEVERAGE_EVAL="$suite" "LEVERAGE_TOOL_DIR=$standins/bin" ${provider_env[@]+"${provider_env[@]}"} \
    bash "$script" "$suite" ${flags[@]+"${flags[@]}"} --out "$work/out" 2>&1) || status=$?
  local recorded recorded_set
  recorded=$(sed -n '/^record /p' "$work/scoring")
  if [[ " $recorded " == *" --held-out "* ]]; then recorded_set=held-out; else recorded_set=main; fi
  if [ "$status" -eq 0 ] &&
      [ "$recorded_set" = "$selection" ] &&
      [ -f "$work/out/$result" ] && [ -f "$work/out/RESULTS.md" ] &&
      [ -f "$work/out/results/$provider.json" ] && [ ! -e "$work/out/held_out" ] &&
      [ ! -e "$repo/evals/$suite/results" ] && [ ! -e "$repo/evals/$suite/runs.json" ] &&
      [ "$(sed -n '/^runner resolve /p' "$called")" = "runner resolve $suite $provider" ] &&
      [ "$(sed -n '/^runner run /p' "$called")" = "runner run $suite $max_runs $max_retries" ] &&
      [ "$(sed -n '/^docker compose run /p' "$called")" = "docker compose run $selection" ] &&
      [[ "$recorded" == *"--out $work/out/$result"* ]]; then
    printf 'ok    %s %s uses its provider, case set, ceilings and result path\n' "$suite" "$selection"
  else
    failures=$((failures + 1))
    printf 'FAIL  %s %s did not use its provider, case set, ceilings and result path (exit %s)\n' "$suite" "$selection" "$status"
    printf '%s\n' "$output" | sed 's/^/      /'
    cat "$called" "$work/scoring" | sed 's/^/      /'
  fi
}

check_general_run() {
  local mode_setup=$1 selection=$2
  local environment=(LEVERAGE_EVAL=approves-actions)
  local flags=(--mode general)
  local destination="$work/out" status=0 output problems=()
  local result="results/general/gemini.json"
  cases=$((cases + 1))
  : >"$called"
  : >"$work/scoring"
  if [ "$mode_setup" = real-shims ]; then
    environment+=(LEVERAGE_EVAL_REAL=1)
    destination="$approval"
    printf 'existing orchestrator ledger\n' >"$approval/runs.json"
  else
    environment+=("LEVERAGE_TOOL_DIR=$standins/bin")
    flags+=(--out "$destination")
  fi
  if [ "$selection" = held-out ]; then
    flags+=(--held-out)
    result="results/general/held-out/gemini.json"
  fi
  mkdir -p "$destination/results"
  printf 'existing orchestrator result\n' >"$destination/results/gemini.json"
  printf 'existing orchestrator report\n' >"$destination/RESULTS.md"
  output=$(env -i PATH="$shims:$system_path" HOME="$work/home" TMPDIR="$work/tmp" \
    "${environment[@]}" bash "$script" approves-actions "${flags[@]}" 2>&1) || status=$?
  if [ "$status" -ne 0 ]; then problems+=("exit $status"); fi
  if [ "$(sed -n '/^inputs mode general$/p' "$called")" != 'inputs mode general' ] ||
      [ "$(sed -n '/^docker compose run /p' "$called")" != "docker compose run $selection" ]; then
    problems+=("did not build General inputs")
  fi
  if [ "$(sed -n '/^runner mode general$/p' "$called" | wc -l | tr -d ' ')" -ne 2 ]; then
    problems+=("did not select General mode for runner resolution and execution")
  fi
  if [ ! -f "$destination/$result" ] ||
      ! scorer_received_general_mode "record" || ! scorer_received_general_mode "report" ||
      [ ! -f "$destination/RESULTS-general.md" ]; then
    problems+=("did not record and report General results separately")
  fi
  if [ "$(cat "$destination/results/gemini.json")" != 'existing orchestrator result' ] ||
      [ "$(cat "$destination/RESULTS.md")" != 'existing orchestrator report' ]; then
    problems+=("overwrote orchestrator results")
  fi
  if [ "$mode_setup" = real-shims ]; then
    if ! scorer_received_general_mode "budget" || ! scorer_received_general_mode "runs-add" ||
        ! scorer_received_general_mode "runs-settle" ||
        [ ! -f "$approval/runs-general.json" ] || [ "$(cat "$approval/runs-general.json")" != settled ] ||
        [ "$(cat "$approval/runs.json")" != 'existing orchestrator ledger' ]; then
      problems+=("did not settle the General run in its own ledger")
    fi
  fi
  if [ ${#problems[@]} -eq 0 ]; then
    printf 'ok    General %s %s run uses its material, mode and result paths\n' "$mode_setup" "$selection"
  else
    failures=$((failures + 1))
    printf 'FAIL  General %s %s run: %s\n' "$mode_setup" "$selection" "${problems[*]}"
    printf '%s\n' "$output" | sed 's/^/      /'
    cat "$called" "$work/scoring" | sed 's/^/      /'
  fi
}

scorer_received_general_mode() {
  grep "^$1 " "$work/scoring" | grep -q -- '--mode general' &&
    ! grep "^$1 " "$work/scoring" | grep -q -- '--role-file'
}

# A partial JSONL file is only a lower bound on the number of tool runs.
check_real_run() {
  local name=$1 runner_status=$2 record_status=$3
  local expected=$((runner_status + record_status))
  rm -rf "$approval/results"
  rm -f "$approval/runs.json"
  cases=$((cases + 1))
  : >"$called"
  : >"$work/scoring"
  local status=0 output
  output=$(env -i PATH="$shims:$system_path" HOME="$work/home" TMPDIR="$work/tmp" \
    EVAL_TEST_RUNNER_STATUS="$runner_status" EVAL_TEST_RECORD_STATUS="$record_status" \
    "${real_mode[@]}" bash "$script" approves-actions 2>&1) || status=$?
  local result="$approval/results/gemini.json"
  local problems=()
  if [ "$status" -ne "$expected" ]; then problems+=("exited $status, expected $expected"); fi
  if [ -d "$approval/.eval-run.lock" ]; then problems+=("left the budget locked"); fi
  if [ "$(sed -n '/^runner run /p' "$called")" != "runner run approves-actions 36 6" ]; then
    problems+=("did not start the expected shimmed run")
  fi
  if [ "$expected" -eq 0 ]; then
    if [ ! -f "$result" ] || [ "$(cat "$approval/runs.json")" != settled ] ||
        [[ "$(sed -n '/^runs-settle /p' "$work/scoring")" != *"--tool-runs 2"* ]]; then
      problems+=("did not publish a result and settle its scored count")
    fi
  elif [ ! -f "$approval/runs.json" ] || [ "$(cat "$approval/runs.json")" != reserved ] ||
      [ -n "$(ls -A "$approval/results" 2>/dev/null)" ]; then
    problems+=("did not keep its full budget reservation and discard partial output")
  fi
  if [ ${#problems[@]} -eq 0 ]; then
    printf 'ok    %s\n' "$name"
  else
    failures=$((failures + 1))
    printf 'FAIL  %s: %s\n' "$name" "${problems[*]}"
    printf '%s\n' "$output" | sed 's/^/      /'
  fi
}

check_frozen cases held-out
check_frozen held_out main
check_run specific-details main codex 30 6
check_run approves-actions main gemini 36 6
check_run approves-actions held-out gemini 12 2
check_real_run "a failed real-mode run keeps its full budget reservation" 1 0
check_real_run "an incomplete real-mode run keeps its full budget reservation" 0 2
check_real_run "a complete real-mode run settles the scored tool count" 0 0
check_general_run stand-in main
check_general_run stand-in held-out
check_general_run real-shims main

echo "$cases cases, $failures failed"
[ "$failures" -eq 0 ]
