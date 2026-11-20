#!/usr/bin/env bash
# Self-test of scripts/real_rule_check.sh's refusals (milestone 4 plan §5.5,
# WP20). The real check is the managing agent's alone; this test never sets
# LEVERAGE_REAL_PROVIDER to a value the script accepts for the provider it
# names. It runs the script with docker, swift, curl, python3, mktemp and
# the three providers' programs (claude, codex, agy) replaced by shims first
# on PATH, each of which records that it was started and fails, and proves
# for every case that the script exits 2, says why, and started nothing:
#
# - CI set, with and without the switch;
# - no LEVERAGE_REAL_PROVIDER (and no copy of the stand-ins);
# - a LEVERAGE_REAL_PROVIDER that names another provider, or is not exactly
#   one (upper case, a trailing space, empty);
# - no provider, an unknown provider (grok, which this check does not take),
#   an unknown option, and --through-app with a provider other than gemini;
# - a LEVERAGE_TOOL_DIR that is not the bin/ of a copy of the stand-ins, or
#   that is relative, and one given together with LEVERAGE_REAL_PROVIDER.
#
#   bash scripts/test_real_rule_check.sh
#
# Needs bash and the standard tools only; exits 0 when every case behaves.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
script="$here/real_rule_check.sh"
work=$(mktemp -d "${TMPDIR:-/tmp}/leverage-test-real-rule-check.XXXXXX")
trap 'rm -rf "$work"' EXIT
shims="$work/shims"
calls="$work/calls.txt"
mkdir -p "$shims" "$work/home" "$work/standins/bin"
for name in docker swift curl python3 mktemp claude codex agy; do
  printf '#!/bin/sh\necho "%s $*" >>"%s"\nexit 1\n' "$name" "$calls" >"$shims/$name"
  chmod 755 "$shims/$name"
done
# A folder shaped like a copy of the stand-ins, whose tools are the shims.
cp "$shims/claude" "$shims/codex" "$shims/agy" "$work/standins/bin/"
: >"$work/standins/provider_tool.py"
mkdir -p "$work/not-standins"
cp "$shims/claude" "$work/not-standins/"

failures=0
passed=0

# run_case <name> <expected text> [VAR=value ...] -- [script arguments ...]
run_case() {
  local name=$1 expected=$2
  shift 2
  local -a variables=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do
    variables+=("$1")
    shift
  done
  shift
  rm -f "$calls"
  local output status
  output=$(env -i PATH="$shims:/usr/bin:/bin" HOME="$work/home" LANG=C TMPDIR="$work" \
    ${variables[@]+"${variables[@]}"} bash "$script" "$@" 2>&1)
  status=$?
  local problem=""
  if [ "$status" -ne 2 ]; then
    problem="exit $status, not 2"
  elif [[ "$output" != *"refused"* ]]; then
    problem="no refusal said"
  elif [ -n "$expected" ] && [[ "$output" != *"$expected"* ]]; then
    problem="the refusal does not say '$expected'"
  elif [ -s "$calls" ]; then
    problem="it started: $(tr '\n' ';' <"$calls")"
  fi
  if [ -n "$problem" ]; then
    printf 'FAIL: %s: %s\n  output: %s\n' "$name" "$problem" "$output"
    failures=$((failures + 1))
  else
    passed=$((passed + 1))
  fi
}

for provider in claude codex gemini; do
  run_case "CI set with the switch ($provider)" "CI is set" CI=true LEVERAGE_REAL_PROVIDER="$provider" -- "$provider"
  run_case "CI set without the switch ($provider)" "CI is set" CI=1 -- "$provider"
  run_case "no switch ($provider)" "LEVERAGE_REAL_PROVIDER=$provider" -- "$provider"
  for other in claude codex gemini grok GEMINI "$provider " ""; do
    if [ "$other" = "$provider" ]; then continue; fi
    run_case "the switch names '$other' ($provider)" "LEVERAGE_REAL_PROVIDER=$provider" \
      LEVERAGE_REAL_PROVIDER="$other" -- "$provider"
  done
  run_case "an unknown option ($provider)" "unknown argument" -- "$provider" --verbose
done
run_case "no provider" "usage" --
run_case "an unknown provider" "unknown provider 'grok'" LEVERAGE_REAL_PROVIDER=grok -- grok
run_case "--through-app with claude" "gemini only" LEVERAGE_REAL_PROVIDER=codex -- claude --through-app
run_case "--through-app with codex" "gemini only" -- codex --through-app
run_case "a tool folder that is no copy of the stand-ins" "not the bin/ of a copy" \
  LEVERAGE_TOOL_DIR="$work/not-standins" -- claude
run_case "a relative tool folder" "absolute" LEVERAGE_TOOL_DIR="standins/bin" -- claude
run_case "a copy of the stand-ins and a switch" "not both" \
  LEVERAGE_TOOL_DIR="$work/standins/bin" LEVERAGE_REAL_PROVIDER=codex -- claude
run_case "a copy of the stand-ins and an empty switch" "not both" \
  LEVERAGE_TOOL_DIR="$work/standins/bin" LEVERAGE_REAL_PROVIDER= -- gemini

# The script is executable, and its header documents both guards.
if [ ! -x "$script" ]; then
  echo "FAIL: real_rule_check.sh is not executable"
  failures=$((failures + 1))
fi
for text in "CI is set" "LEVERAGE_REAL_PROVIDER" "set -x"; do
  if ! grep -q -- "$text" "$script"; then
    echo "FAIL: real_rule_check.sh does not say '$text'"
    failures=$((failures + 1))
  fi
done
if grep -Eq '^[[:space:]]*set -[a-z]*x' "$script"; then
  echo "FAIL: real_rule_check.sh turns on set -x"
  failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
  echo "test_real_rule_check: $failures failed, $passed passed"
  exit 1
fi
echo "test_real_rule_check: $passed cases passed"
