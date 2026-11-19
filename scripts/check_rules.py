#!/usr/bin/env python3
"""Check the repository, and optionally a pull request, against the
architecture rules in docs/ARCHITECTURE.md ("Rules").

That section is the authority on what each rule requires and on which parts
are checked here; this file only implements them. In outline:

  * repository checks, always run: the rules table, the pull request
    template, ID references, ADR files, and action pins;
  * pull request checks, run when --base is given: the answers in the
    description, and what the change adds relative to the base commit.

Usage:
  python3 scripts/check_rules.py
  python3 scripts/check_rules.py --base origin/main --body-file tmp/pr-body.md

CI passes --event "$GITHUB_EVENT_PATH" instead of --body-file, and the
description and author are read from that file. Standard library only; exits
0 when every check passes, 1 otherwise.
"""

import sys

# This script runs on pull requests, where files next to it are not trusted.
# Take the script's folder off the import path so that a new file here (an
# "argparse.py", say) cannot replace a standard library module, and do not
# leave bytecode behind in the working tree.
sys.dont_write_bytecode = True
import os  # noqa: E402  (already loaded by the interpreter; not a path lookup)

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path[:] = [p for p in sys.path if os.path.abspath(p or os.curdir) != _HERE]

import argparse  # noqa: E402
import importlib.util  # noqa: E402
import json  # noqa: E402
import re  # noqa: E402
import subprocess  # noqa: E402
from pathlib import Path, PurePosixPath  # noqa: E402


def _load_sibling(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(_HERE, name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


check_prd_text = _load_sibling("check_prd_ids").check_text

ROOT = Path(_HERE).parent
ARCHITECTURE = "docs/ARCHITECTURE.md"
PRD = "docs/PRD.md"
TEMPLATE = ".github/PULL_REQUEST_TEMPLATE.md"
ADR_DIR = "docs/adr"
WORKFLOW_DIR = ".github/workflows"
# Research notes are an archive of what was found, not a description of the
# project, so IDs quoted there are not checked.
ARCHIVE = "docs/research/"

RULES_HEADING = "Rules"
ANSWERS_HEADING = "Architecture rules"
# AR-003: a change under one of these headings needs an ADR.
DECISION_SECTIONS = ("Components", "Technology choices")
# AR-003: the first file of one of these kinds means a language, runtime, or
# packaging choice was made. Names are compared in lower case.
MANIFESTS = {
    "package.json", "pyproject.toml", "setup.py", "setup.cfg", "pipfile",
    "go.mod", "cargo.toml", "gemfile", "pom.xml", "build.gradle",
    "build.gradle.kts", "composer.json", "package.swift", "mix.exs",
    "deno.json",
}
MANIFEST_PATTERNS = (
    (re.compile(r"^requirements[\w.-]*\.txt$"), "requirements.txt"),
    (re.compile(r"^dockerfile(\..+)?$"), "dockerfile"),
    (re.compile(r"^(docker-)?compose[\w.-]*\.ya?ml$"), "compose file"),
    (re.compile(r"\.(cs|fs|vb)proj$"), ".NET project file"),
)
# Bots that cannot fill in a pull request description.
EXEMPT_AUTHORS = {"dependabot[bot]"}
STATUSES = ("active", "pending", "retired")
ADR_STATUSES = "'Proposed', 'Accepted', 'Rejected', 'Deprecated', or 'Superseded by NNNN'"

A = re.ASCII
HEADING = re.compile(r"^ {0,3}(#{1,6})[ \t]+(.*)$")
FENCE = re.compile(r"^ {0,3}(`{3,}|~{3,})(.*)$")
RULE_ID = re.compile(r"^AR-\d{3}$", A)
LOOKS_LIKE_RULE_ID = re.compile(r"^AR[\s_-]*\d+$", A | re.IGNORECASE)
RULE_HEADING = re.compile(r"^###[ \t]+(AR[ \t_-]*\d+)\b", A | re.IGNORECASE)
# A well-formed ID that is not part of a longer word, path, or branch name.
ID_REF = re.compile(r"(?<![\w/-])(?:FR|NFR|AR)-\d{3}(?![\w-])", A)
ISSUE_REF = re.compile(
    r"(?<![\w&/#-])(?:[\w.-]+/[\w.-]+)?#\d+\b"
    r"|github\.com/[\w.-]+/[\w.-]+/(?:issues|pull)/\d+",
    A,
)
ANSWER = re.compile(
    r"^ {0,3}[-*+][ \t]+(?:\[[ xX]\][ \t]+)?[*_`]*(AR-\d{3})[*_`]*[ \t]*:[ \t]*(.*)$", A
)
LIST_ITEM = re.compile(r"^\s*(?:[-*+]|\d+[.)])\s")
KEYWORD = re.compile(r"^(complies|n/a|not applicable|deviates)(?![\w'’/-])(.*)$", re.IGNORECASE)
WORD = re.compile(r"[^\W\d_]{2,}")
ADR_FILE = re.compile(r"^(\d{4})-[a-z0-9]+(?:-[a-z0-9]+)*\.md$", A)
ADR_PATH = re.compile(r"(?<![\w/.-])docs/adr/\d{4}-[a-z0-9]+(?:-[a-z0-9]+)*\.md(?![\w-])", A)
ADR_STATUS_LINE = re.compile(r"^\*{0,2}Status\*{0,2}:\*{0,2}[ \t]*(.+?)[ \t]*$")
ADR_STATUS = re.compile(
    r"^(Proposed|Accepted|Rejected|Deprecated|Superseded by (\d{4}))$", A | re.IGNORECASE
)
# Any line that sets a "uses" key, however it is written ...
USES_KEY = re.compile(r"""(?<![\w-])["']?uses["']?[ \t]*:""")
# ... and the one way of writing it that this script can check.
USES_LINE = re.compile(
    r"""^[ \t]*(?:-[ \t]+)?uses:[ \t]+"""
    r"""(?:"([^"\s]+)"|'([^'\s]+)'|([^\s"'#{}\[\],&*!|>%@`][^\s#]*))"""
    r"""[ \t]*(?:#.*)?$"""
)
PINNED = re.compile(r"@[0-9a-f]{40}$")
PINNED_IMAGE = re.compile(r"@sha256:[0-9a-f]{64}$")
MIN_WORDS = 2  # a reason or a purpose is at least this many words


class Report:
    """Collects results and prints them, as annotations when run in CI."""

    def __init__(self):
        self.errors = 0
        self.in_ci = os.environ.get("GITHUB_ACTIONS") == "true"

    def _emit(self, label, kind, message):
        # File names and other text from the pull request end up in messages.
        # Control characters are removed so that none of it can start a new
        # line and be read by the runner as a workflow command.
        message = "".join(ch if ch >= " " else "?" for ch in message)
        print(f"{label}: {message}")
        if kind and self.in_ci:
            print(f"::{kind}::{message.replace('%', '%25')}")

    def ok(self, message):
        self._emit("OK", None, message)

    def warn(self, message):
        self._emit("WARNING", "warning", message)

    def error(self, message):
        self.errors += 1
        self._emit("FAIL", "error", message)


# --- Reading Markdown -------------------------------------------------------


def _strip_comments(line, in_comment):
    """Remove HTML comments from one line; return (text, still in a comment).

    A "<!--" inside an inline code span is text, not a comment. A comment
    that is never closed hides everything after it, as it does on GitHub.
    """
    out = []
    i, n = 0, len(line)
    while i < n:
        if in_comment:
            end = line.find("-->", i)
            if end < 0:
                return "".join(out), True
            i, in_comment = end + 3, False
        elif line.startswith("<!-->", i):  # an empty comment, by the HTML rules
            i += 5
        elif line.startswith("<!--->", i):
            i += 6
        elif line.startswith("<!--", i):
            i, in_comment = i + 4, True
        elif line[i] == "`":
            j = i
            while j < n and line[j] == "`":
                j += 1
            ticks = j - i
            close = re.compile(r"(?<!`)`{%d}(?!`)" % ticks).search(line, j)
            end = close.end() if close else j
            out.append(line[i:end])
            i = end
        else:
            out.append(line[i])
            i += 1
    return "".join(out), in_comment


def lines_of(text, keep_code=False):
    """Yield (line, in_code) for the lines a reader of the rendered page sees.

    HTML comments are removed. Lines inside fenced code blocks are skipped
    unless keep_code is set, so that an example is never mistaken for a
    heading, an ID, or an answer. A fence closes only on a line of the same
    character, at least as long as the one that opened it.
    """
    fence = None  # (character, length) while inside a fenced block
    in_comment = False
    for raw in text.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
        if fence:
            marker = raw.strip()
            indent = len(raw) - len(raw.lstrip(" "))
            if marker and set(marker) == {fence[0]} and len(marker) >= fence[1] and indent <= 3:
                fence = None
            if keep_code:
                yield raw, True
            continue
        if not in_comment:
            opening = FENCE.match(raw)
            if opening and not (opening.group(1)[0] == "`" and "`" in opening.group(2)):
                fence = (opening.group(1)[0], len(opening.group(1)))
                if keep_code:
                    yield raw, True
                continue
        line, in_comment = _strip_comments(raw, in_comment)
        yield line, False


def heading_of(line):
    """Return (depth, title) if the line is a heading, else None."""
    match = HEADING.match(line)
    if not match:
        return None
    title = match.group(2).strip()
    bare = title.rstrip("#")
    if bare != title and (not bare or bare[-1] in " \t"):
        title = bare.strip()  # closing hashes: "## Title ##"
    return len(match.group(1)), title


def section(text, title, level=None, keep_code=False):
    """Return the text under a heading, or None if the heading is absent.

    With level=None the heading may be at any depth. The section ends at the
    next heading of the same depth or shallower.
    """
    found = None
    body = []
    wanted = title.casefold()
    for line, in_code in lines_of(text, keep_code):
        heading = None if in_code else heading_of(line)
        if heading:
            depth, name = heading
            if found is not None and depth <= found:
                break
            if (
                found is None
                and level in (None, depth)
                and name.rstrip(":").strip().casefold() == wanted
            ):
                found = depth
                continue
        if found is not None:
            body.append(line)
    # Keep each line's indentation: an indented line is code, not an answer.
    return "\n".join(body).strip("\n") if found is not None else None


def visible(text):
    return "\n".join(line for line, _ in lines_of(text or ""))


def read(relative):
    """Return a file's text, or None if it is not a regular file."""
    path = ROOT / relative
    if not path.is_file():
        return None
    return path.read_bytes().decode("utf-8", errors="replace")


# --- Git --------------------------------------------------------------------


def git(*args):
    """Return git's output, or None if the command failed."""
    try:
        result = subprocess.run(
            ["git", *args], cwd=ROOT, capture_output=True, check=False,
            encoding="utf-8", errors="replace",
        )
    except OSError:
        return None
    return result.stdout if result.returncode == 0 else None


def names(output):
    """Split the output of a git command run with -z."""
    return [name for name in (output or "").split("\0") if name]


def show(ref, relative):
    """Return a file's text as of a commit, or None if it is not there."""
    return git("show", f"{ref}:{relative}")


def tree_at(ref):
    """Return every file path in a commit."""
    return names(git("ls-tree", "-r", "-z", "--name-only", ref))


def working_files():
    """Return every file in the working tree that git does not ignore."""
    listed = git("ls-files", "-co", "--exclude-standard", "-z")
    if listed is not None:
        found = names(listed)
    else:  # not a git checkout
        found = [
            path.relative_to(ROOT).as_posix()
            for path in ROOT.rglob("*")
            if ".git" not in path.parts
        ]
    return sorted(name for name in found if (ROOT / name).is_file())


def changes_since(base):
    """Return (start, added, deleted, touched) for the working tree.

    start is the commit the change is measured from: where the working
    tree's history left the base.
    """
    start = (git("merge-base", base, "HEAD") or "").strip() or base
    added, deleted, touched = set(), set(), set()
    fields = names(git("diff", "--name-status", "--no-renames", "-z", start))
    for status, name in zip(fields[0::2], fields[1::2]):
        touched.add(name)
        if status.startswith("A"):
            added.add(name)
        elif status.startswith("D"):
            deleted.add(name)
    untracked = names(git("ls-files", "-o", "--exclude-standard", "-z"))
    added.update(untracked)
    touched.update(untracked)
    return start, added, deleted, touched


# --- Rules ------------------------------------------------------------------


def parse_rules(text, report=None):
    """Return {rule ID: 'active' | 'pending' | 'retired'} from the Rules section.

    Problems are reported only when a report is given; the base branch's copy
    is read without one.
    """
    rules = {}
    problems = []
    body = section(text or "", RULES_HEADING, level=2)
    if body is None:
        problems.append(f"there is no '## {RULES_HEADING}' section")
        body = ""

    headings = []
    for line in body.split("\n"):
        heading = RULE_HEADING.match(line)
        if heading:
            headings.append(heading.group(1))
            continue
        if not line.strip().startswith("|"):
            continue
        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
        rule = cells[0].strip("`*")
        if not LOOKS_LIKE_RULE_ID.match(rule):
            continue
        if not RULE_ID.match(rule):
            problems.append(f"'{rule}' is not a valid rule ID (expected AR-001)")
            continue
        if rule in rules:
            problems.append(f"{rule} is listed twice (IDs are never reused)")
            continue
        status = cells[-1].strip("`*").lower()
        for known in STATUSES:
            if status == known or status.startswith(known + ":"):
                rules[rule] = known
                break
        else:
            problems.append(f"{rule} has no status of Active, Pending, or Retired")

    for rule in sorted(set(rules) - set(headings)):
        problems.append(f"{rule} is in the rules table but has no '### {rule}' heading")
    for rule in sorted(set(headings) - set(rules)):
        problems.append(f"'### {rule}' has no row in the rules table")

    if report:
        for problem in problems:
            report.error(f"{ARCHITECTURE}: {problem}")
        if not problems:
            counts = ", ".join(
                f"{sum(1 for s in rules.values() if s == status)} {status}"
                for status in STATUSES
            )
            report.ok(f"{len(rules)} rule(s) in {ARCHITECTURE} ({counts})")
    return rules


def active(rules):
    return {rule for rule, status in rules.items() if status == "active"}


def requirement_ids(prd_text):
    """Return the requirement IDs a PRD defines (outside comments and code)."""
    return set(check_prd_text(visible(prd_text))[0]) if prd_text else set()


def parse_answers(text):
    """Return ({rule ID: answer text}, duplicated IDs) from a description.

    Returns (None, set()) when there is no "Architecture rules" section.
    """
    body = section(text or "", ANSWERS_HEADING)
    if body is None:
        return None, set()
    answers, duplicates = {}, set()
    current = None
    for line in body.split("\n"):
        match = ANSWER.match(line)
        if match:
            current = match.group(1)
            if current in answers:
                duplicates.add(current)
            answers[current] = match.group(2).strip()
        elif current and line.strip() and line[:1] in " \t" and not LIST_ITEM.match(line):
            answers[current] += " " + line.strip()  # wrapped answer
        else:
            current = None
    return answers, duplicates


def classify(answer):
    """Return (kind, rest) where kind is complies, n/a, deviates, or None."""
    text = answer.strip().strip("*_`").strip()
    match = KEYWORD.match(text)
    if not match:
        return None, text
    kind = match.group(1).lower()
    return ("n/a" if kind == "not applicable" else kind), match.group(2)


def has_words(text):
    return len(WORD.findall(ID_REF.sub(" ", text))) >= MIN_WORDS


# --- Repository checks ------------------------------------------------------


def check_template(rules, report):
    text = read(TEMPLATE)
    if text is None:
        report.error(f"{TEMPLATE} is missing")
        return
    answers, _ = parse_answers(text)
    listed, expected = set(answers or ()), active(rules)
    for rule in sorted(expected - listed):
        report.error(f"{TEMPLATE}: no '- {rule}:' line for an active rule")
    for rule in sorted(listed - expected):
        report.error(f"{TEMPLATE}: lists {rule}, which is not an active rule")
    if listed == expected:
        report.ok(f"{TEMPLATE} lists every active rule")


def check_references(rules, requirements, files, report):
    """AR-002: IDs used in the documentation are defined in their home."""
    failures = 0
    for name in files:
        if name.startswith(ARCHIVE) or PurePosixPath(name).suffix.lower() not in (".md", ".markdown"):
            continue
        refs = set(ID_REF.findall(visible(read(name))))
        unknown = {ref for ref in refs if ref.startswith("AR") and ref not in rules}
        if name.startswith("docs/"):
            unknown |= {
                ref for ref in refs if not ref.startswith("AR") and ref not in requirements
            }
        for ref in sorted(unknown):
            failures += 1
            home = ARCHITECTURE if ref.startswith("AR") else PRD
            report.error(f"AR-002: {name} refers to {ref}, which {home} does not define")
    if not failures:
        report.ok("AR-002: every requirement and rule ID used in the docs is defined")


def adr_status(relative):
    """Return the regex match for an ADR's status line, or None."""
    for line, _ in lines_of(read(relative) or ""):
        found = ADR_STATUS_LINE.match(line)
        if found:
            return ADR_STATUS.match(found.group(1))
    return None


def check_adrs(report):
    """AR-003: ADR file names, numbers, and statuses."""
    folder = ROOT / ADR_DIR
    entries = sorted(p for p in folder.rglob("*") if not p.is_dir()) if folder.is_dir() else []
    failures = 0
    numbers = {}
    superseded = []
    for path in entries:
        name = path.relative_to(ROOT).as_posix()
        match = ADR_FILE.match(path.name)
        if path.parent != folder or not match or path.is_symlink() or not path.is_file():
            failures += 1
            report.error(
                f"AR-003: {name} does not belong in {ADR_DIR}/, which holds only "
                "ADR files named like 0001-short-title.md"
            )
            continue
        number = match.group(1)
        if number in numbers:
            failures += 1
            report.error(f"AR-003: {name} reuses number {number} ({numbers[number]})")
        numbers.setdefault(number, name)
        status = adr_status(name)
        if not status:
            failures += 1
            report.error(
                f"AR-003: {name} needs a line 'Status: ' followed by {ADR_STATUSES}"
            )
        elif status.group(2):
            superseded.append((name, number, status.group(2)))

    for name, number, successor in superseded:
        if successor == number or successor not in numbers:
            failures += 1
            report.error(f"AR-003: {name} is superseded by {successor}, which does not exist")
    if not failures:
        report.ok(f"AR-003: {len(entries)} ADR(s) in {ADR_DIR}/ are well formed")


def is_action_file(name):
    """Workflows, and action definitions anywhere in the repository."""
    path = PurePosixPath(name)
    if path.suffix.lower() not in (".yml", ".yaml"):
        return False
    return name.startswith(WORKFLOW_DIR + "/") or path.stem.lower() == "action"


def actions_in(text):
    """Return (values, unreadable line numbers) for the 'uses' keys in a file."""
    values, unreadable = [], []
    for number, line in enumerate((text or "").splitlines(), 1):
        if line.lstrip().startswith("#") or not USES_KEY.search(line):
            continue
        match = USES_LINE.match(line)
        if match:
            values.append(next(group for group in match.groups() if group))
        else:
            unreadable.append(number)
    return values, unreadable


def action_name(value):
    """'Owner/Repo/path@ref' -> 'owner/repo'; None for a local action."""
    if value.startswith("./"):
        return None
    if value.startswith("docker://"):
        return re.split(r"[@:]", value[len("docker://"):])[0].lower()
    return "/".join(value.split("@")[0].split("/")[:2]).lower()


def check_action_pins(files, report):
    """AR-004: every action is pinned to a full commit SHA."""
    failures = 0
    count = 0
    for name in files:
        if not is_action_file(name):
            continue
        values, unreadable = actions_in(read(name))
        for number in unreadable:
            failures += 1
            report.error(
                f"AR-004: {name} line {number} sets 'uses' in a form this check "
                "cannot read. Write it on one line as 'uses: owner/repo@<commit SHA>'."
            )
        for value in values:
            if value.startswith("./"):
                continue
            count += 1
            pinned = PINNED_IMAGE if value.startswith("docker://") else PINNED
            if not pinned.search(value):
                failures += 1
                report.error(
                    f"AR-004: {name} uses '{value}', which is not pinned to a "
                    "full commit SHA"
                )
    if not failures:
        report.ok(f"AR-004: {count} action reference(s) are pinned to a commit SHA")


# --- Pull request checks ----------------------------------------------------


def check_answers(required, answers, duplicates, report):
    """Every active rule has one well-formed answer. Returns {rule: kind}."""
    kinds = {}
    if not required:
        return kinds
    wanted = ", ".join(sorted(required))
    where = f"See {ARCHITECTURE}, 'How the rules are applied'."
    if answers is None:
        report.error(
            f"The description has no '## {ANSWERS_HEADING}' section that a reader "
            f"can see, with a line for each active rule ({wanted}). {where}"
        )
        return kinds
    if not answers:
        report.error(
            f"The '{ANSWERS_HEADING}' section has no answer lines. Write one line "
            f"per active rule ({wanted}), like '- AR-001: Complies — ...'. {where}"
        )
        return kinds
    for rule in sorted(duplicates):
        report.error(f"{rule} is answered more than once in the description")

    problems = len(duplicates)
    for rule in sorted(required):
        if rule not in answers:
            problems += 1
            report.error(f"{rule} is an active rule and the description does not answer it")
            continue
        kind, rest = classify(answers[rule])
        kinds[rule] = kind
        problem = None
        if kind is None:
            problem = "the answer must start with 'Complies', 'N/A', or 'Deviates'"
        elif rule == "AR-001":
            if kind == "n/a":
                problem = (
                    "this rule applies to every pull request, so 'N/A' is not an "
                    "answer. Say what the change implements after 'Complies'."
                )
            elif kind == "complies" and not (
                ID_REF.search(rest) or ISSUE_REF.search(rest) or has_words(rest)
            ):
                problem = (
                    "after 'Complies', name what the change implements: a "
                    "requirement ID, an issue, or its single purpose in a few words"
                )
            elif kind == "deviates" and not has_words(rest):
                problem = "'Deviates' needs the reason on the same line"
        elif kind == "n/a" and not has_words(rest):
            problem = f"'N/A' needs a reason of at least {MIN_WORDS} words after it"
        elif kind == "deviates":
            adr = ADR_PATH.search(rest)
            status = adr_status(adr.group(0)) if adr else None
            if not adr:
                problem = (
                    "'Deviates' needs the ADR that records why, for example "
                    "docs/adr/0002-short-title.md"
                )
            elif read(adr.group(0)) is None:
                problem = f"{adr.group(0)} does not exist"
            elif not status or status.group(1).lower() != "accepted":
                problem = f"{adr.group(0)} must have status Accepted to justify a deviation"
        if problem:
            problems += 1
            report.error(f"{rule}: {problem}")
        elif kind == "deviates":
            report.warn(
                f"{rule} is answered 'Deviates': the maintainer must agree to "
                "the deviation before merging."
            )
    if not problems:
        report.ok(f"the description answers {len(required)} active rule(s)")
    return kinds


def check_description_refs(body, rules, requirements, report):
    """AR-002: every ID used in the description is defined."""
    for ref in sorted(set(ID_REF.findall(visible(body)))):
        if ref.startswith("AR") and ref not in rules:
            report.error(
                f"AR-002: the description refers to {ref}, which {ARCHITECTURE} does not define"
            )
        elif not ref.startswith("AR") and ref not in requirements:
            report.error(f"AR-002: the description refers to {ref}, which {PRD} does not define")


def manifest_kind(name):
    base = PurePosixPath(name).name.lower()
    if base in MANIFESTS:
        return base
    for pattern, kind in MANIFEST_PATTERNS:
        if pattern.search(base):
            return kind
    return None


def check_decision_record(start, added, deleted, touched, kinds, report):
    """AR-003: choices that need an ADR come with one."""
    known = {manifest_kind(name) for name in tree_at(start)}
    manifests = sorted(
        name for name in added if manifest_kind(name) and manifest_kind(name) not in known
    )
    before = show(start, ARCHITECTURE) or ""
    after = read(ARCHITECTURE) or ""
    sections = [
        title for title in DECISION_SECTIONS
        if section(before, title, 2, keep_code=True) != section(after, title, 2, keep_code=True)
    ]
    if not manifests and not sections:
        return
    reasons = [f"adds {name}" for name in manifests]
    reasons += [f"changes the '{title}' section of {ARCHITECTURE}" for title in sections]
    with_adr = sorted(
        name for name in touched - deleted
        if name.startswith(ADR_DIR + "/") and ADR_FILE.match(name[len(ADR_DIR) + 1:])
    )
    if with_adr:
        report.ok(f"AR-003: the change comes with an ADR ({with_adr[0]})")
        return
    message = (
        f"AR-003: this pull request {' and '.join(reasons)}, "
        f"but adds or changes no ADR in {ADR_DIR}/"
    )
    if not manifests and kinds.get("AR-003") == "n/a":
        report.warn(
            message + ". It answers 'N/A', which is accepted for a change of "
            "wording only: the maintainer must confirm that before merging."
        )
    else:
        report.error(message + ".")


def check_new_actions(base, body, kinds, files, report):
    """AR-004: an action the base does not use is named in the description."""
    known = set()
    for name in tree_at(base):
        if is_action_file(name):
            known.update(action_name(value) for value in actions_in(show(base, name))[0])
    current = set()
    for name in files:
        if is_action_file(name):
            current.update(action_name(value) for value in actions_in(read(name))[0])
    new = sorted(name for name in current - known if name)
    if not new:
        return
    text = visible(body).lower()
    missing = [
        name for name in new
        if not re.search(r"(?<![\w/.-])" + re.escape(name) + r"(?![\w-])", text)
    ]
    for name in missing:
        report.error(
            f"AR-004: the description does not name the new action {name}. "
            "Name it with its license, its pinned SHA, and why it is needed."
        )
    if kinds.get("AR-004") == "n/a":
        report.error(
            f"AR-004 is answered 'N/A', but this pull request adds {', '.join(new)}"
        )
    elif not missing:
        report.ok(f"AR-004: the description names {len(new)} new action(s)")


def warn_about_enforcement_changes(start, touched, report):
    """Point the reviewer at changes to the files that do the checking."""
    changed = sorted(
        name for name in touched
        if name.startswith("scripts/") or is_action_file(name) or name == TEMPLATE
    )
    before = section(show(start, ARCHITECTURE) or "", RULES_HEADING, 2, keep_code=True)
    after = section(read(ARCHITECTURE) or "", RULES_HEADING, 2, keep_code=True)
    if before != after:
        changed.append(f"the Rules section of {ARCHITECTURE}")
    if changed:
        shown = ", ".join(changed[:6]) + (", ..." if len(changed) > 6 else "")
        report.warn(
            "This pull request changes what enforces the rules "
            f"({shown}). This check ran the pull request's own copy, so "
            "read those changes by hand before merging."
        )


# --- Entry point ------------------------------------------------------------


def main(argv):
    parser = argparse.ArgumentParser(
        description="Check the repository, and optionally a pull request, "
        "against the architecture rules."
    )
    parser.add_argument(
        "--base", help="base commit of the pull request, for example origin/main"
    )
    source = parser.add_mutually_exclusive_group()
    source.add_argument("--body-file", help="file holding the pull request description")
    source.add_argument("--event", help="GitHub event payload to read the description from")
    args = parser.parse_args(argv[1:])
    if (args.body_file or args.event) and not args.base:
        parser.error("--body-file and --event need --base")
    if args.base and not (args.body_file or args.event):
        parser.error("--base needs --body-file (or --event in CI)")

    report = Report()
    files = working_files()
    rules = parse_rules(read(ARCHITECTURE), report)
    requirements = requirement_ids(read(PRD))

    check_template(rules, report)
    check_references(rules, requirements, files, report)
    check_adrs(report)
    check_action_pins(files, report)

    if args.base:
        check_pull_request(args, rules, requirements, files, report)

    if report.errors:
        print(f"\n{report.errors} problem(s). The rules are in {ARCHITECTURE}.")
        return 1
    print("\nAll rule checks passed.")
    return 0


def check_pull_request(args, rules, requirements, files, report):
    if git("rev-parse", "--verify", "--quiet", f"{args.base}^{{commit}}") is None:
        report.error(f"base commit '{args.base}' was not found")
        return
    author = None
    try:
        if args.event:
            pull = json.loads(Path(args.event).read_bytes()).get("pull_request") or {}
            body = pull.get("body") or ""
            author = (pull.get("user") or {}).get("login")
        else:
            body = Path(args.body_file).read_bytes().decode("utf-8", errors="replace")
    except (OSError, ValueError) as problem:
        report.error(f"could not read the pull request description: {problem}")
        return

    base_rules = parse_rules(show(args.base, ARCHITECTURE))
    start, added, deleted, touched = changes_since(args.base)
    kinds = {}
    if author in EXEMPT_AUTHORS:
        report.ok(
            f"pull request by {author}: the '{ANSWERS_HEADING}' section is not "
            "required; the other checks apply"
        )
    else:
        required = active(rules) | active(base_rules)
        answers, duplicates = parse_answers(body)
        kinds = check_answers(required, answers, duplicates, report)
        # A description may name a rule or requirement that this change removes.
        check_description_refs(
            body,
            {**base_rules, **rules},
            requirements | requirement_ids(show(args.base, PRD)),
            report,
        )
    check_decision_record(start, added, deleted, touched, kinds, report)
    check_new_actions(args.base, body, kinds, files, report)
    warn_about_enforcement_changes(start, touched, report)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
