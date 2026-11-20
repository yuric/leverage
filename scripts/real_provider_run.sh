#!/usr/bin/env bash
# A developer check with a provider's real tool (plan PV-6, WP21): it proves
# the runner's driver flags against the tool already installed and signed in
# on this Mac, and nothing else. It never runs in CI, and only the managing
# agent or the maintainer runs it, at most twice per tool.
#
#   LEVERAGE_REAL_PROVIDER=<p> scripts/real_provider_run.sh <p> [options]
#
#   <p>                 claude, codex, gemini (the tool agy) or grok
#   --evidence <file>   also write the result to <file>
#   --timeout <s>       the tool run's limit, 1 to 600 seconds (default 300)
#   --model <m>         the model a seat would pass (default: the tool's own)
#   --effort <e>        the effort a seat would pass (Claude and Gemini only)
#
# It refuses (exit 2, before anything starts) when CI is set, when
# LEVERAGE_REAL_PROVIDER is not exactly <p>, for an unknown provider or a
# bad option. That guards against CI and accidents; it is not anyone's
# consent. When the tool is not on PATH it says "skipped: not installed"
# (exit 3).
#
# Otherwise it builds the Swift runner lane and runs the one test
# RealProviderRunTests, which goes through the runner's own path: the
# builder prompt and ProcessToolDriver with a build's arguments, so no flag
# is typed here. Before the prompt, the catalog's version command and, where
# the provider has one, its status command run under the same environment.
# The prompt runs once, in a new empty folder under a
# temporary folder, with the runner's allow-listed environment (no token,
# no leverage variable, no account folder variable) and the time limit
# above; the driver ends the tool's whole process group when the limit
# passes. LEVERAGE_DEV_TOOL_LOGIN=1, which nothing else sets, lets the
# runner start Claude or Codex with no account folder of leverage's own, so
# the tool uses the sign-in it already holds for this Mac user. Nobody
# signs in here: a status that says signed out is "skipped: not signed in"
# (exit 4). Gemini (agy) has no status command, so a signed-out agy shows
# as a failure.
#
# It reads no file under any account folder and prints none of the tool's
# output or environment: the result is the provider, the tool's version
# line, the outcome, the exit status, whether the expected file appeared,
# the marker line's kind, the tokens and the seconds. Exit 0 when it
# passed, 1 when it failed. On every exit the temporary folder is removed,
# and on a stop (SIGINT, SIGTERM) every process group under the test is
# ended, the tool's included.
#
# Environment it reads besides the switch (optional):
# LEVERAGE_REAL_PROVIDER_SCRATCH, Swift's build folder for the runner lane
# (default mac/.build/real-provider).
set -euo pipefail

# Progress goes to standard error; standard output is the result alone.
say() { printf 'real_provider_run: %s\n' "$*" >&2; }
refuse() {
  printf 'real_provider_run: refused: %s\n' "$*" >&2
  exit 2
}
usage="usage: LEVERAGE_REAL_PROVIDER=<p> scripts/real_provider_run.sh <p>"
usage="$usage [--evidence <file>] [--timeout <seconds>] [--model <m>] [--effort <e>],"
usage="$usage where <p> is claude, codex, gemini or grok"

if [ -n "${CI:-}" ]; then
  refuse "CI is set; this check never runs in CI"
fi
if [ $# -lt 1 ]; then
  refuse "$usage"
fi
provider=$1
shift
# The tool's program by provider, as ProviderCatalog names it; the Swift
# test refuses a path whose name is not the catalog's.
case "$provider" in
  claude) program=claude ;;
  codex) program=codex ;;
  gemini) program=agy ;;
  grok) program=grok ;;
  *) refuse "unknown provider '$provider'; $usage" ;;
esac
if [ "${LEVERAGE_REAL_PROVIDER:-}" != "$provider" ]; then
  refuse "set LEVERAGE_REAL_PROVIDER=$provider to run the check with the real $program"
fi

evidence=""
timeout=300
model=""
effort=""
while [ $# -gt 0 ]; do
  case "$1" in
    --evidence | --timeout | --model | --effort)
      if [ $# -lt 2 ] || [ -z "$2" ]; then refuse "$1 needs a value; $usage"; fi
      case "$1" in
        --evidence) evidence=$2 ;;
        --timeout) timeout=$2 ;;
        --model) model=$2 ;;
        --effort) effort=$2 ;;
      esac
      shift 2
      ;;
    *) refuse "unknown argument '$1'; $usage" ;;
  esac
done
case "$timeout" in
  '' | *[!0-9]* | 0*) refuse "--timeout takes a whole number of seconds from 1 to 600" ;;
esac
if [ "$timeout" -gt 600 ]; then
  refuse "--timeout takes a whole number of seconds from 1 to 600"
fi

# Writes the result to standard output and, when asked, to the evidence
# file.
report() {
  printf '%s' "$1"
  if [ -n "$evidence" ]; then printf '%s' "$1" >"$evidence"; fi
}

tool=$(command -v -- "$program" 2>/dev/null || true)
case "$tool" in
  /*) ;;
  *)
    report "provider: $provider
tool: $program
outcome: skipped: not installed
"
    say "skipped: not installed ($program is not on PATH)"
    exit 3
    ;;
esac

root=$(cd "$(dirname "$0")/.." && pwd)
if ! command -v swift >/dev/null 2>&1; then
  say "failed: swift is not on PATH"
  exit 1
fi
scratch="${LEVERAGE_REAL_PROVIDER_SCRATCH:-$root/mac/.build/real-provider}"

work=$(mktemp -d "${TMPDIR:-/tmp}/leverage-real-provider.XXXXXX")
work=$(cd "$work" && pwd -P)
test_pid=""
watchdog_pid=""
own_group=$(ps -o pgid= -p $$ | tr -d ' ')

# Ends the process group of $1 and every process group under it. The driver
# starts the tool in a group of its own, which outlives the test's group if
# only that is ended; the groups are listed before any is ended, since a
# child whose parent is gone can no longer be found under it.
end_tree() {
  local all=$1 next=$1 groups group
  while [ -n "$next" ]; do
    next=$(ps -axo pid=,ppid= \
      | awk -v parents=" $next " 'index(parents, " " $2 " ") { print $1 }' | tr '\n' ' ' || true)
    next=${next% }
    all="$all $next"
  done
  groups=$(for pid in $all; do ps -o pgid= -p "$pid" 2>/dev/null || true; done | tr -d ' ' | sort -u || true)
  for group in $groups; do
    if [ "$group" != "$own_group" ]; then kill -TERM -- "-$group" 2>/dev/null || true; fi
  done
  sleep 2
  for group in $groups; do
    if [ "$group" != "$own_group" ]; then kill -KILL -- "-$group" 2>/dev/null || true; fi
  done
}

finish() {
  status=$?
  trap - EXIT INT TERM
  if [ -n "$watchdog_pid" ]; then kill -- "-$watchdog_pid" 2>/dev/null || true; fi
  if [ -n "$test_pid" ] && kill -0 "$test_pid" 2>/dev/null; then end_tree "$test_pid"; fi
  rm -rf "$work"
  exit "$status"
}
trap finish EXIT
trap 'exit 130' INT TERM
mkdir "$work/folder" "$work/support"

say "building the runner lane in $scratch"
# Swift's own temporary files go into the check's folder, which is removed.
if ! (cd "$root/mac" && TMPDIR="$work" LEVERAGE_ONLY=runner swift build --build-tests --scratch-path "$scratch") \
  >"$work/build.log" 2>&1; then
  tail -n 40 "$work/build.log" >&2
  say "failed: the runner lane did not build"
  exit 1
fi

say "running one build prompt with $tool (limit ${timeout}s)"
started=$(date +%s)
# Job control puts the test in a process group of its own, which the
# watchdog and finish end with every group under it (end_tree). The
# driver's own limit ends the tool first; the watchdog is the backstop for
# the test itself, and finish for a stop.
set -m
(
  cd "$root/mac"
  export LEVERAGE_ONLY=runner
  export LEVERAGE_DEV_TOOL_LOGIN=1
  export LEVERAGE_REAL_PROVIDER_RESULT="$work/result.txt"
  export LEVERAGE_REAL_PROVIDER_TOOL="$tool"
  export LEVERAGE_REAL_PROVIDER_FOLDER="$work/folder"
  export LEVERAGE_REAL_PROVIDER_TIMEOUT="$timeout"
  export LEVERAGE_REAL_PROVIDER_SUPPORT="$work/support"
  export LEVERAGE_REAL_PROVIDER_MODEL="$model"
  export LEVERAGE_REAL_PROVIDER_EFFORT="$effort"
  export TMPDIR="$work"
  exec swift test --skip-build --scratch-path "$scratch" --filter RealProviderRunTests
) >"$work/test.log" 2>&1 &
test_pid=$!
# The watchdog has a group of its own too, so that ending it ends its sleep.
(
  sleep $((timeout + 120))
  end_tree "$test_pid"
) >/dev/null 2>&1 &
watchdog_pid=$!
set +m
test_status=0
wait "$test_pid" || test_status=$?
test_pid=""
kill -- "-$watchdog_pid" 2>/dev/null || true
wait "$watchdog_pid" 2>/dev/null || true
watchdog_pid=""
say "the check took $(($(date +%s) - started))s"

if [ ! -s "$work/result.txt" ]; then
  # The test's log holds Swift Testing's lines only, never the tool's output.
  tail -n 40 "$work/test.log" >&2
  report "provider: $provider
tool: $program
outcome: failed
reason: the check did not run to its end (swift test exited $test_status)
"
  exit 1
fi
result=$(cat "$work/result.txt")
report "$result
"
case "$result" in
  *"outcome: passed"*) exit 0 ;;
  *"outcome: skipped: not signed in"*) exit 4 ;;
  *) exit 1 ;;
esac
