#!/usr/bin/env python3
"""Self-test for speed_report.py.

Feeds the report made-up `leverage.command` log lines, as the api container
prints them, and checks what it reads, what it leaves out, the percentiles,
the comparison with the target and the exit codes.

Usage: python3 -I scripts/test_speed_report.py [-v]
Standard library only; exits 0 when every case behaves as expected.
"""

import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "speed_report.py"
sys.path.insert(0, str(HERE))

import speed_report  # noqa: E402

FAILURES = []


def check(name, condition, detail=""):
    if not condition:
        FAILURES.append(f"{name}: {detail}")
    elif "-v" in sys.argv[1:]:
        print(f"ok  {name}")


def line(command="claim", caller="seat:5b0b9d30", outcome="completed",
         refusal="-", lock="0.412", step="1.087", total="4.250", prefix=True):
    body = (f"leverage.command command={command} caller={caller} key=k-1 "
            f"outcome={outcome} refusal={refusal} lock_wait_ms={lock} "
            f"event_step_ms={step} transition_ms={total}")
    if not prefix:
        return body
    return f"api-1  | I, [2026-11-19T10:00:00.000000 #1]  INFO -- : [req-1] {body}"


def run_cli(text, *args):
    with tempfile.TemporaryDirectory() as folder:
        path = Path(folder) / "api.log"
        path.write_text(text, encoding="utf-8")
        result = subprocess.run(
            [sys.executable, "-I", str(SCRIPT), "--log", str(path), *args],
            capture_output=True, text=True, check=False)
    return result.returncode, result.stdout + result.stderr


# --- parsing -------------------------------------------------------------

row = speed_report.parse_line(line())
check("a compose log line is read", row is not None)
check("the command is read", row and row["command"] == "claim", str(row))
check("the caller is read", row and row["caller"] == "seat:5b0b9d30", str(row))
check("the three timings are numbers",
      row and (row["lock_wait_ms"], row["event_step_ms"], row["transition_ms"])
      == (0.412, 1.087, 4.25), str(row))
check("a bare line is read too", speed_report.parse_line(line(prefix=False)))
check("an ordinary log line is not a command",
      speed_report.parse_line("Started GET \"/v1/next\" for 10.0.0.1") is None)
check("a line with a missing timing is not a command",
      speed_report.parse_line(
          "leverage.command command=claim caller=app key=- outcome=completed "
          "refusal=- lock_wait_ms=1.000") is None)
check("a line with a timing that is not a number is not a command",
      speed_report.parse_line(line(total="abc")) is None)

# --- percentiles ---------------------------------------------------------

hundred = [float(n) for n in range(1, 101)]
check("p50 of 1..100 is 50", speed_report.percentile(hundred, 50) == 50.0)
check("p95 of 1..100 is 95", speed_report.percentile(hundred, 95) == 95.0)
check("p99 of 1..100 is 99", speed_report.percentile(hundred, 99) == 99.0)
check("the order of the input does not matter",
      speed_report.percentile(list(reversed(hundred)), 95) == 95.0)
check("one value is every percentile", speed_report.percentile([7.5], 99) == 7.5)
check("p95 of 21 values is the 20th", speed_report.percentile(
    [float(n) for n in range(1, 22)], 95) == 20.0)
check("no values has no percentile", speed_report.percentile([], 95) is None)

# --- grouping and the table ---------------------------------------------

lines = []
for index in range(1, 101):
    lines.append(line(command="heartbeat", caller="seat:a", step="0.000",
                      lock=f"{index / 10:.3f}", total=f"{index / 5:.3f}"))
for index in range(1, 101):
    lines.append(line(command="claim", caller="seat:b", step=f"{index / 10:.3f}",
                      lock="0.100", total=f"{index:.3f}"))
lines.append(line(command="add_task", caller="user:owner", step="9.000"))
lines.append(line(command="sweep_timers", caller="app", step="9.000"))
lines.append("Completed 200 OK in 3ms")
text = "\n".join(lines) + "\n"

parsed = speed_report.read_lines(text.splitlines())
check("the report reads every command line", len(parsed.rows) == 202, str(len(parsed.rows)))

summary = speed_report.summarise(parsed.rows, caller="seat")
check("seat commands only are counted by default",
      summary.total == 200, str(summary.total))
check("commands are grouped by name",
      sorted(summary.by_command) == ["claim", "heartbeat"], str(sorted(summary.by_command)))
claim = summary.by_command["claim"]
check("a group counts its commands", claim.count == 100)
check("a group's event and step p95", claim.event_step[1] == 9.5, str(claim.event_step))
check("a group's lock wait p50", claim.lock_wait[0] == 0.1, str(claim.lock_wait))
check("a group's transition p99", claim.transition[2] == 99.0, str(claim.transition))
check("all callers can be asked for",
      speed_report.summarise(parsed.rows, caller="all").total == 202)

written = summary.writing
check("only commands that wrote events are in the writing row",
      written.count == 100, str(written.count))
check("the heartbeats are in the all-commands row",
      summary.overall.count == 200, str(summary.overall.count))
check("the all-commands event and step p95 counts the heartbeats' zeros",
      summary.overall.event_step[1] < summary.writing.event_step[1])

check("the target is compared with the writing p95",
      speed_report.verdict(summary, 20.0).startswith("within"),
      speed_report.verdict(summary, 20.0))
check("above the target says so and the measured figure",
      "above" in speed_report.verdict(summary, 5.0)
      and "9.500" in speed_report.verdict(summary, 5.0),
      speed_report.verdict(summary, 5.0))
empty = speed_report.summarise([], caller="seat")
check("no commands has no verdict", speed_report.verdict(empty, 20.0).startswith("no "))

# --- the program ---------------------------------------------------------

code, out = run_cli(text, "--threads", "64", "--pool", "32", "--seats", "50",
                    "--seconds", "120")
check("the program exits 0 on a good log", code == 0, out)
check("the table names the commands", "claim" in out and "heartbeat" in out, out)
check("the table has the writing and all-commands rows",
      "all commands" in out and "commands that wrote events" in out, out)
check("the table says the thread setting and the pool size",
      "RAILS_MAX_THREADS 64" in out and "pool 32" in out, out)
check("the table says the seats and the seconds",
      "50 seats" in out and "120 seconds" in out, out)
check("the table says it is within the target",
      "within 20" in out, out)
check("the add_task of the owner is not in the table", "add_task" not in out, out)

code, out = run_cli("nothing here\n")
check("a log with no command lines exits 2", code == 2, out)
check("and says why", "no leverage.command" in out, out)

code, out = run_cli(line(caller="user:owner") + "\n")
check("a log with only owner commands exits 2 by default", code == 2, out)
code, out = run_cli(line(caller="user:owner") + "\n", "--callers", "all")
check("and exits 0 with --callers all", code == 0, out)

code, out = run_cli(text, "--min-commands", "500")
check("a run with fewer commands than asked for exits 3", code == 3, out)

code, out = run_cli(line(step="30.000") + "\n", "--target-ms", "20")
check("above the target is still exit 0: nothing is tuned to pass", code == 0, out)
check("and the table says above", "above 20" in out, out)

if FAILURES:
    print("FAILED")
    for failure in FAILURES:
        print(f"  {failure}")
    sys.exit(1)
print("speed_report: every case behaves as expected")
