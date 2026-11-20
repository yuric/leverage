#!/usr/bin/env python3
"""Reads the API's `leverage.command` log lines and prints the speed table.

One line is logged per command (api/lib/leverage/command_log.rb): the wait
for the workspace lock, the time spent writing events and steps, the whole
transition, and (milestone 4, RD-60) the time inside the gate, in
milliseconds. A line without gate_ms, as milestone 2 wrote it, is counted
and adds no gate time. This prints, per command and overall, the 50th,
95th and 99th percentile of each (milestone 2 plan EN-19, 5.3),
the number of commands, the thread setting and the pool size, and says
whether the 95th percentile of the event and step writes is within the
target (20 ms, PRD L821). Nothing is tuned to pass: above the target is
reported, and the exit code is still 0.

Usage: python3 -I scripts/speed_report.py --log FILE|- [--callers seat|all]
         [--target-ms 20] [--threads N] [--pool N] [--seats N] [--seconds N]
         [--min-commands N]

Exit codes: 0 a table was printed; 2 the log has no command line to count;
3 fewer commands than --min-commands. Standard library only.
"""

import argparse
import math
import re
import sys
from dataclasses import dataclass, field

PREFIX = "leverage.command "
FIELD = re.compile(r"(\w+)=(\S+)")
TIMINGS = ("lock_wait_ms", "event_step_ms", "transition_ms")
GATE = "gate_ms"
PERCENTILES = (50, 95, 99)


def parse_line(text):
    """One command line as a dict, or None for any other line."""
    at = text.find(PREFIX)
    if at < 0:
        return None
    fields = dict(FIELD.findall(text[at + len(PREFIX):]))
    if "command" not in fields or "caller" not in fields:
        return None
    row = {"command": fields["command"], "caller": fields["caller"],
           "outcome": fields.get("outcome", "-"), "refusal": fields.get("refusal", "-")}
    for name in TIMINGS:
        try:
            row[name] = float(fields[name])
        except (KeyError, ValueError):
            return None
        if math.isnan(row[name]) or row[name] < 0:
            return None
    row[GATE] = None
    if GATE in fields:
        try:
            row[GATE] = float(fields[GATE])
        except ValueError:
            return None
        if math.isnan(row[GATE]) or row[GATE] < 0:
            return None
    return row


@dataclass
class Parsed:
    rows: list = field(default_factory=list)
    other: int = 0


def read_lines(lines):
    parsed = Parsed()
    for text in lines:
        row = parse_line(text)
        if row is None:
            parsed.other += 1
        else:
            parsed.rows.append(row)
    return parsed


def percentile(values, p):
    """The nearest-rank percentile: the smallest value with at least p percent
    of the values at or below it. None when there are no values."""
    if not values:
        return None
    ordered = sorted(values)
    rank = max(1, math.ceil(p / 100.0 * len(ordered)))
    return ordered[rank - 1]


@dataclass
class Group:
    count: int
    lock_wait: tuple
    event_step: tuple
    transition: tuple
    gate: tuple


def group_of(rows):
    gated = [r[GATE] for r in rows if r[GATE] is not None]
    return Group(
        count=len(rows),
        lock_wait=tuple(percentile([r["lock_wait_ms"] for r in rows], p) for p in PERCENTILES),
        event_step=tuple(percentile([r["event_step_ms"] for r in rows], p) for p in PERCENTILES),
        transition=tuple(percentile([r["transition_ms"] for r in rows], p) for p in PERCENTILES),
        gate=tuple(percentile(gated, p) for p in PERCENTILES))


@dataclass
class Summary:
    total: int
    by_command: dict
    overall: Group
    writing: Group


def summarise(rows, caller="seat"):
    """caller 'seat' counts the commands seats sent; 'all' counts every one."""
    if caller == "seat":
        rows = [r for r in rows if r["caller"].startswith("seat:")]
    names = sorted({r["command"] for r in rows})
    return Summary(
        total=len(rows),
        by_command={name: group_of([r for r in rows if r["command"] == name]) for name in names},
        overall=group_of(rows),
        writing=group_of([r for r in rows if r["event_step_ms"] > 0]))


def verdict(summary, target_ms):
    if summary.writing.count == 0:
        return "no command wrote events, so the event and step writes were not measured"
    p95 = summary.writing.event_step[1]
    where = (f"the 95th percentile of the event and step writes is {p95:.3f} ms over "
             f"{summary.writing.count} commands that wrote events, ")
    if p95 <= target_ms:
        return f"within {target_ms:g} ms: {where}the target is {target_ms:g} ms"
    return f"above {target_ms:g} ms: {where}the target is {target_ms:g} ms"


def cell(value):
    return "      -" if value is None else f"{value:7.3f}"


def row_text(name, group):
    cells = []
    for part in (group.lock_wait, group.event_step, group.transition, group.gate):
        cells.append(" ".join(cell(v) for v in part))
    return f"{name:<28}{group.count:>7}  " + "   ".join(cells)


def render(summary, args):
    out = []
    setting = []
    if args.seats is not None:
        setting.append(f"{args.seats} seats")
    if args.seconds is not None:
        setting.append(f"{args.seconds} seconds")
    if args.threads is not None:
        setting.append(f"RAILS_MAX_THREADS {args.threads}")
    if args.pool is not None:
        setting.append(f"pool {args.pool}")
    if setting:
        out.append("Run: " + ", ".join(setting))
    counted = "commands sent by seats" if args.callers == "seat" else "commands of every caller"
    out.append(f"{summary.total} {counted}; milliseconds, nearest-rank percentiles")
    out.append("")
    head = (f"{'':<35}{'lock wait':^23}   {'event+step writes':^23}   {'whole transition':^23}"
            f"   {'time in the gate':^23}")
    sub = f"{'command':<28}{'n':>7}  " + "   ".join(["    p50     p95     p99"] * 4)
    out += [head, sub, "-" * len(sub)]
    for name, group in summary.by_command.items():
        out.append(row_text(name, group))
    out.append("-" * len(sub))
    out.append(row_text("all commands", summary.overall))
    out.append(row_text("commands that wrote events", summary.writing))
    out.append("")
    out.append("Event and step writes, " + verdict(summary, args.target_ms))
    return "\n".join(out)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--log", required=True, help="the log file, or - for standard input")
    parser.add_argument("--callers", choices=("seat", "all"), default="seat")
    parser.add_argument("--target-ms", type=float, default=20.0)
    parser.add_argument("--threads", type=int)
    parser.add_argument("--pool", type=int)
    parser.add_argument("--seats", type=int)
    parser.add_argument("--seconds", type=int)
    parser.add_argument("--min-commands", type=int, default=1)
    args = parser.parse_args(argv)

    if args.log == "-":
        parsed = read_lines(sys.stdin)
    else:
        with open(args.log, encoding="utf-8", errors="replace") as handle:
            parsed = read_lines(handle)
    summary = summarise(parsed.rows, caller=args.callers)
    if summary.total == 0:
        print(f"speed_report: no leverage.command lines to count ({len(parsed.rows)} "
              f"of every caller, {parsed.other} other lines)", file=sys.stderr)
        return 2
    print(render(summary, args))
    if summary.total < args.min_commands:
        print(f"speed_report: only {summary.total} commands, {args.min_commands} asked for",
              file=sys.stderr)
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main())
