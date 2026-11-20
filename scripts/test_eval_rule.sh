#!/usr/bin/env bash
# Self-test of the guards of scripts/eval_rule.sh (milestone 4 plan RV-6,
# §2.4). It never sets LEVERAGE_EVAL_REAL: every case runs the script
# under `env -i`, with an environment written here, so nothing of the
# caller's reaches it either.
#
# Each case gives the script something it must refuse, with exit 2, before
# it starts anything: CI set; no LEVERAGE_EVAL; LEVERAGE_EVAL set but
# neither LEVERAGE_TOOL_DIR nor LEVERAGE_EVAL_REAL; another suite, in the
# variable or as the argument; a LEVERAGE_TOOL_DIR that is not a copy of
# the stand-ins; a run against the stand-ins with no --out, or with --out
# in the repository's suite folder; an unknown provider. PATH holds shims
# named claude, codex, agy, grok, docker and swift that record being
# called: after every case none was called, and no output folder exists.
#
#   bash scripts/test_eval_rule.sh
#
# Exit 0 when every case behaves as expected, 1 otherwise. It needs bash
# and the programs every Mac and Linux runner has; nothing is built.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
script="$root/scripts/eval_rule.sh"
work=$(mktemp -d "${TMPDIR:-/tmp}/leverage-test-eval-rule.XXXXXX")
trap 'rm -rf "$work"' EXIT

shims="$work/shims"
called="$work/called"
mkdir -p "$shims" "$work/home" "$work/tmp"
: >"$called"
for program in claude codex agy grok docker swift; do
  cat >"$shims/$program" <<EOF
#!/bin/sh
echo "$program \$*" >>"$called"
exit 0
EOF
  chmod +x "$shims/$program"
done

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
  output=$(env -i PATH="$shims:/usr/bin:/bin" HOME="$work/home" TMPDIR="$work/tmp" ${environment[@]+"${environment[@]}"} \
    bash "$script" "$@" 2>&1) || status=$?
  local problems=()
  if [ "$status" -ne "$expected" ]; then problems+=("exit $status, not $expected"); fi
  if [ -s "$called" ]; then problems+=("started: $(tr '\n' ';' <"$called")"); fi
  if [ -e "$work/out" ]; then problems+=("made the output folder"); fi
  case "$output" in
    *refused*) ;;
    *) problems+=("did not say it refused") ;;
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
  --out "$root/evals/specific-details/results"
check "an unknown provider" 2 "${stand_in[@]}" "LEVERAGE_EVAL_PROVIDERS=claude chatbot" -- \
  specific-details --out "$work/out"
check "an unknown option" 2 "${stand_in[@]}" -- specific-details --out "$work/out" --fast

echo "$cases cases, $failures failed"
[ "$failures" -eq 0 ]
