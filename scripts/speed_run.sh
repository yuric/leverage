#!/usr/bin/env bash
# Measures the speed of the API's transitions (milestone 2 plan EN-19, 5.3).
#
# Starts a compose project of its own (compose.yaml and compose.test.yaml,
# so Docker picks the API's port and nothing binds a fixed one), runs
# api/script/speed/run.rb in a container of that project (fifty seats that
# connect on their own, heartbeating every 2 seconds, their ticks spread
# evenly over the 2 seconds as separate agents' are, on tasks put in Ready
# beforehand), reads the `leverage.command` lines from the api container's
# log through scripts/speed_report.py, prints the table with the date and
# the machine, and removes the project and its volume, also on failure.
#
#   scripts/speed_run.sh            50 seats for 120 seconds
#   scripts/speed_run.sh --smoke    4 seats for 20 seconds (CI's check that
#                                   the run works, not a measurement)
#   scripts/speed_run.sh --seats N --seconds N
#   scripts/speed_run.sh --specific-details on|off
#
# The shipped rules stay on. "Specific details" is off unless --specific-details
# on is given (milestone 4 plan RD-60, 5.4): the driver turns it off through
# disable_rule before its seats connect, so every Complete contract, claim,
# submit, review claim and verdict passes the gate with the app-run rules only.
#
# Needs Docker and a .env (made by scripts/make_env.py when there is none).
# COMPOSE_PROJECT_NAME and API_IMAGE_TAG may be set; the defaults are a
# project of this run's own and the tag "speed". The exit code is not
# changed by a figure above the target: nothing is tuned to pass.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

seats=50
seconds=120
smoke=false
min_commands=500
specific_details=off
while [ $# -gt 0 ]; do
  case "$1" in
    --smoke) smoke=true; seats=4; seconds=20; min_commands=10 ;;
    --seats) seats="$2"; shift ;;
    --seconds) seconds="$2"; shift ;;
    --specific-details)
      case "${2:-}" in
        on|off) specific_details="$2" ;;
        *) echo "speed_run: --specific-details is on or off" >&2; exit 64 ;;
      esac
      shift ;;
    *) echo "speed_run: unknown argument $1" >&2; exit 64 ;;
  esac
  shift
done
case "$seats$seconds" in *[!0-9]*|"") echo "speed_run: --seats and --seconds are whole numbers" >&2; exit 64 ;; esac
if [ $((seats % 2)) -ne 0 ] || [ "$seats" -lt 2 ]; then
  echo "speed_run: --seats is an even number, half builders and half reviewers" >&2
  exit 64
fi

export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-leverage-speed-$$}"
export API_IMAGE_TAG="${API_IMAGE_TAG:-speed}"
U() { docker compose -f compose.yaml -f compose.test.yaml "$@"; }

python3 -I scripts/make_env.py

work="$(mktemp -d "${TMPDIR:-/tmp}/leverage-speed.XXXXXX")"
cleanup() {
  status=$?
  U down --volumes --remove-orphans >/dev/null 2>&1 || true
  rm -rf "$work"
  exit $status
}
trap cleanup EXIT

echo "speed_run: building the image and starting the API, the sweep and the database ($COMPOSE_PROJECT_NAME)"
U up -d --build --wait db api sweep >"$work/up.txt" 2>&1 || { cat "$work/up.txt" >&2; exit 1; }

# The thread setting and the pool size Rails itself reports (EN-21).
settings="$(U exec -T api bin/rails runner '
  pool = ActiveRecord::Base.connection_pool
  size = pool.respond_to?(:size) ? pool.size : pool.db_config.max_connections
  puts "#{ENV.fetch("RAILS_MAX_THREADS", "unset")} #{size}"' 2>/dev/null | tail -n 1)"
threads="${settings%% *}"
pool="${settings##* }"
case "$threads$pool" in *[!0-9]*|"") echo "speed_run: could not read the thread setting and the pool size ($settings)" >&2; exit 1 ;; esac

echo "speed_run: $seats seats for $seconds seconds"
set +e
U run --rm --no-deps -T api ruby script/speed/run.rb --url http://api:3000 --seats "$seats" --seconds "$seconds" \
  --specific-details "$specific_details" | tee "$work/driver.txt"
driver=${PIPESTATUS[0]}
set -e

U logs --no-color --no-log-prefix api >"$work/api.log" 2>&1

if [ "$(uname -s)" = "Darwin" ]; then
  machine="$(sysctl -n hw.model), $(sysctl -n machdep.cpu.brand_string)"
else
  machine="$(uname -s) $(uname -m)"
fi

echo
echo "Speed measurement"
echo "Date: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "Machine: $machine"
echo "Arrivals: each seat ticks every 2 seconds; the seats' ticks are spread evenly over the 2 seconds"
echo "Rules: the shipped rules on; \"specific details\" $specific_details"
$smoke && echo "Smoke run: it shows that the measurement works; its figures are not the measurement."
report=0
python3 -I scripts/speed_report.py --log "$work/api.log" --threads "$threads" --pool "$pool" \
  --seats "$seats" --seconds "$seconds" --min-commands "$min_commands" || report=$?

if [ "$driver" -ne 0 ]; then
  echo "speed_run: the driver exited with $driver" >&2
  exit "$driver"
fi
exit "$report"
