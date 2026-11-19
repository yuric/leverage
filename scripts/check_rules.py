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
# leave bytecode behind in the working tree. CI also runs it with "python3
# -I", which keeps the folder off the path from the start.
sys.dont_write_bytecode = True
import os  # noqa: E402  (already loaded by the interpreter; not a path lookup)

_HERE = os.path.dirname(os.path.abspath(__file__))
# Compared as real paths: Python puts the script's folder on the path with
# symbolic links resolved, and __file__ may name it through one.
sys.path[:] = [
    p for p in sys.path if os.path.realpath(p or os.curdir) != os.path.realpath(_HERE)
]

import argparse  # noqa: E402
import importlib.util  # noqa: E402
import json  # noqa: E402
import re  # noqa: E402
import stat  # noqa: E402
import subprocess  # noqa: E402
from pathlib import Path, PurePosixPath  # noqa: E402


def _load_sibling(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(_HERE, name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# The Markdown reader lives in check_prd_ids.py so that both checks read a
# document the same way, and so that neither file imports the other in a loop.
_prd = _load_sibling("check_prd_ids")
check_prd_text = _prd.check_text
lines_of = _prd.lines_of

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
    # compose.yaml, docker-compose.yml, compose.override.yaml: the name, then
    # whole words set off by a dot or a hyphen. Not "composed-music.yaml".
    (re.compile(r"^(?:docker-)?compose(?:[.-]\w+)*\.ya?ml$"), "compose file"),
    (re.compile(r"\.(cs|fs|vb)proj$"), ".NET project file"),
)
# Bots that cannot fill in a pull request description.
EXEMPT_AUTHORS = {"dependabot[bot]"}
STATUSES = ("active", "pending", "retired")
ADR_STATUSES = "'Proposed', 'Accepted', 'Rejected', 'Deprecated', or 'Superseded by NNNN'"

A = re.ASCII
HEADING = re.compile(r"^ {0,3}(#{1,6})[ \t]+(.*)$")
# The line under a Setext heading: "Title", then "=====" or "-----".
UNDERLINE = re.compile(r"^ {0,3}(=+|-+)[ \t]*$")
THEMATIC_BREAK = re.compile(r"^ {0,3}([-*_])[ \t]*(?:\1[ \t]*){2,}$")
LIST_START = re.compile(r"^( {0,3})([-*+]|\d{1,9}[.)])([ \t]+|$)")
RULE_ID = re.compile(r"^AR-\d{3}$", A)
LOOKS_LIKE_RULE_ID = re.compile(r"^AR[\s_-]*\d+$", A | re.IGNORECASE)
RULE_HEADING = re.compile(r"^###[ \t]+(AR[ \t_-]*\d+)\b", A | re.IGNORECASE)
# A well-formed ID that is not part of a longer word, path, or branch name.
ID_REF = re.compile(r"(?<![\w/-])(?:FR|NFR|AR)-\d{3}(?![\w-])", A)
REQUIREMENT_REF = re.compile(r"(?<![\w/-])(?:FR|NFR)-\d{3}(?![\w-])", A)
# An issue or pull request: "#12", "owner/repo#12", or its address. The first
# two are found by has_issue_ref(), which looks at the text around each "#".
ISSUE_NUMBER = re.compile(r"#\d+\b", A)
ISSUE_URL = re.compile(r"github\.com/[\w.-]+/[\w.-]+/(?:issues|pull)/\d+", A)
ANSWER = re.compile(
    r"^ {0,3}(?:[-*+]|\d{1,9}[.)])[ \t]+(?:\[[ xX]\][ \t]+)?"
    r"[*_`]*(AR-\d{3})[*_`]*[ \t]*:[ \t]*(.*)$",
    A,
)
LIST_ITEM = re.compile(r"^\s*(?:[-*+]|\d+[.)])\s")
# The three answers, as (spelling in lower case, what it means). They are
# matched as ASCII only, so no look-alike letter makes a fourth kind.
KEYWORDS = (
    ("complies", "complies"),
    ("not applicable", "n/a"),
    ("n/a", "n/a"),
    ("deviates", "deviates"),
)
GLUED = re.compile(r"[\w'’/-]")  # a keyword runs on into other text
WORD = re.compile(r"[^\W\d_]{2,}")
ADR_FILE = re.compile(r"^(\d{4})-[a-z0-9]+(?:-[a-z0-9]+)*\.md$", A)
ADR_PATH = re.compile(r"(?<![\w/.-])docs/adr/\d{4}-[a-z0-9]+(?:-[a-z0-9]+)*\.md(?![\w-])", A)
ADR_STATUS_LABEL = re.compile(r"\*{0,2}Status\*{0,2}:")
ADR_STATUS = re.compile(
    r"^(Proposed|Accepted|Rejected|Deprecated|Superseded by (\d{4}))$", A | re.IGNORECASE
)
# Text that sets a "uses" key if it stands where a key can start ...
USES_KEY = re.compile(r"""(?<![\w-])["']?uses["']?[ \t]*:""")
# ... the forms of that key which do not have "uses" and ":" side by side ...
EXPLICIT_USES = re.compile(
    r"""^[ \t]*(?:-[ \t]+)*\?[ \t]+(?:[&!]\S*[ \t]+)*["']?uses["']?[ \t]*(?:#.*)?$"""
)
ALIAS_KEY = re.compile(r"""(?<![^\s{\[,])\*[^\s{}\[\],]+[ \t]+:""")
YAML_ESCAPE = re.compile(r"\\(?:x([0-9A-Fa-f]{2})|u([0-9A-Fa-f]{4})|U([0-9A-Fa-f]{8}))")
# ... and the one way of writing it that this script can check.
USES_LINE = re.compile(
    r"""^[ \t]*(?:-[ \t]+)?uses:[ \t]+"""
    r"""(?:"([^"\s]+)"|'([^'\s]+)'|([^\s"'#{}\[\],&*!|>%@`][^\s"'#{}\[\],]*))"""
    r"""[ \t]*(?:#.*)?$"""
)
# Three kinds of text in a YAML file that are not YAML structure. They are
# set aside only while actions_in() is certain where each starts and ends.
# A comment: "#" at the start of a line or after a space.
COMMENT = re.compile(r"(?:^|[ \t])#")
SIMPLE_KEY = r"""(?:[A-Za-z_][\w.-]*|"[\w.-]+"|'[\w.-]+')"""
# "key: |" or "key: >": the lines below it that are indented further than the
# key. Group 1 ends at the column of the key.
BLOCK_SCALAR = re.compile(
    r"^( *(?:- +)*)" + SIMPLE_KEY + r" *: +[|>](?:[+-]?[1-9]?|[1-9][+-]?)(?:[ \t]+#.*)?[ \t]*$", A
)
# "key: '...'" or 'key: "..."': what is between the quotes.
QUOTED_VALUE = re.compile(r"^[ \t]*(?:-[ \t]+)*" + SIMPLE_KEY + r"""[ \t]*:[ \t]+(["'])""", A)
# Characters that some YAML readers take as the end of a line and others
# do not.
ODD_LINE_BREAKS = "\x0b\x0c\x1c\x1d\x1e\x85  "
PINNED = re.compile(r"^[\w.-]+(?:/[\w.-]+)+@[0-9a-f]{40}$", A)
PINNED_IMAGE = re.compile(r"^docker://[\w.:/-]+@sha256:[0-9a-f]{64}$", A)
MIN_WORDS = 2  # a reason or a purpose is at least this many words
# AR-007: the code folders of the components, and the folders of their tests.
# A file under SOURCE_DIRS is product source unless it is Markdown or is in a
# test folder; a test file is test code (TEST_SUFFIXES) in a test folder.
SOURCE_DIRS = ("api/", "mac/")
TEST_DIRS = ("api/test/", "mac/Tests/")
TEST_SUFFIXES = (".rb", ".swift")
# AR-007: a line that asserts something in a test, and a line that skips one.
ASSERTION = re.compile(
    r"\b(?:assert\w*|refute\w*|flunk|must_\w+|wont_\w+|XCTAssert\w*|XCTFail|XCTUnwrap)\b"
    r"|#(?:expect|require)\b",
    A,
)
SKIP = re.compile(r"^\s*(?:skip|pending|omit)\b|\bXCTSkip\w*|\.disabled\b|\bwithKnownIssue\b", A)
HUNK = re.compile(r"^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@", A)
REGULAR_FILE_MODES = ("100644", "100755")  # as git records them


class Stop(Exception):
    """Something the verdict depends on could not be read: fail, do not guess."""


def clean(text):
    """Return text that is safe to print in a GitHub Actions log.

    File names and other text from the pull request end up in messages. The
    runner reads a line as a command if it starts with "::name::" or has
    "##[name]" anywhere in it. Every message is printed after a fixed label,
    so only two things are needed: control characters are replaced, so that
    no text can start a line of its own, and "##[" is broken up.
    """
    text = "".join(
        "?" if ch < " " or "\x7f" <= ch <= "\x9f" or ch in "  "
        or "\ud800" <= ch <= "\udfff" else ch
        for ch in text
    )
    return text.replace("##[", "## [")


class Report:
    """Collects results and prints them, as annotations when run in CI."""

    def __init__(self):
        self.errors = 0
        self.in_ci = os.environ.get("GITHUB_ACTIONS") == "true"

    def _emit(self, label, kind, message):
        message = clean(message)
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


def heading_of(line):
    """Return (depth, title) if the line is a '#' heading, else None."""
    match = HEADING.match(line)
    if not match:
        return None
    title = match.group(2).strip()
    bare = title.rstrip("#")
    if bare != title and (not bare or bare[-1] in " \t"):
        title = bare.strip()  # closing hashes: "## Title ##"
    return len(match.group(1)), title


def outline(text, keep_code=False):
    """Yield (line, heading, back) for the lines a reader of the page sees.

    heading is (depth, title) on a line that is, or completes, a heading. A
    Setext heading is its text and then a line of "=" (depth 1) or "-"
    (depth 2); it is reported on that second line, and back is the number of
    lines just yielded that hold its text. A line of hyphens is a heading
    only under a paragraph: under a list item, a quote, or a blank line it
    is a rule across the page, as it is on GitHub.
    """
    block = None  # "text" in a paragraph, "other" in a list item or quote
    paragraph = []
    item = None  # the column where the text of the open list item starts
    for line, in_code in lines_of(text, keep_code=True):
        heading, back = None, 0
        if in_code:
            block = None
            if keep_code:
                yield line, None, 0
            continue
        indent = len(line) - len(line.lstrip(" "))
        if not line.strip():
            block = None
        elif heading_of(line):
            heading, block, item = heading_of(line), None, None
        elif block == "text" and UNDERLINE.match(line):
            title = " ".join(part.strip() for part in paragraph)
            heading, back, block = (1 if "=" in line else 2, title), len(paragraph), None
        else:
            rule = THEMATIC_BREAK.match(line)
            start = None if rule else LIST_START.match(line)
            # A list item interrupts a paragraph only if it has text and,
            # when numbered, starts at 1.
            interrupts = start and start.group(3) and line[start.end():].strip() and (
                not start.group(2)[0].isdigit() or start.group(2)[:-1] == "1"
            )
            quote = indent <= 3 and line.lstrip(" ").startswith(">")
            if block == "text" and not (interrupts or quote or rule):
                paragraph.append(line)
            elif block == "other" and not start and not rule:
                pass  # more of the list item or quote
            elif block is None and item is not None and indent >= item:
                block = "other"  # a later paragraph of the list item
            elif start and (block != "text" or interrupts):
                spaces = len(start.group(3))
                item = len(start.group(1)) + len(start.group(2)) + (spaces if 1 <= spaces <= 4 else 1)
                block = "other"
            elif quote:
                block, item = "other", None
            elif rule or indent >= 4:
                block, item = None, None  # a rule, or an indented code block
            else:
                block, item, paragraph = "text", None, [line]
        yield line, heading, back


def section(text, title, level=None, keep_code=False):
    """Return the text under a heading, or None if the heading is absent.

    With level=None the heading may be at any depth. The section ends at the
    next heading of the same depth or shallower.
    """
    found = None
    body = []
    wanted = title.casefold()
    for line, heading, back in outline(text, keep_code):
        if heading:
            depth, name = heading
            if found is not None and depth <= found:
                if back:
                    del body[-back:]  # the text of the heading that ends it
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


# --- Reading files ----------------------------------------------------------


def kind_of(relative):
    """Return 'file', 'dir', 'link', 'missing', or 'other' for a path.

    Symbolic links are never followed. 'link' means the path, or a folder on
    the way to it, is a symbolic link, so that what would be read is not what
    the repository holds at that path.
    """
    path = str(ROOT)
    parts = PurePosixPath(relative).parts
    mode = None
    for part in parts:
        if mode is not None and not stat.S_ISDIR(mode):
            return "missing"
        path = os.path.join(path, part)
        try:
            mode = os.lstat(path).st_mode
        except (FileNotFoundError, NotADirectoryError):
            return "missing"
        except (OSError, ValueError):
            return "other"
        if stat.S_ISLNK(mode):
            return "link"
    if mode is None:
        return "missing"
    return "file" if stat.S_ISREG(mode) else "dir" if stat.S_ISDIR(mode) else "other"


def read(relative):
    """Return a file's text, or None if it is not a regular file.

    A symbolic link is not a regular file, wherever it points.
    """
    if kind_of(relative) != "file":
        return None
    try:
        return (ROOT / relative).read_bytes().decode("utf-8", errors="replace")
    except OSError as problem:
        raise Stop(f"{relative} could not be read ({problem.strerror or 'error'})")


def not_a_file(kind):
    """Say why a path that had to be a regular file or a folder is not one."""
    if kind == "link":
        return (
            "is a symbolic link, or is inside one. This check does not follow "
            "links: commit the file itself"
        )
    return "is not a regular file"


def read_input(relative, report):
    """Return the text of a file that decides the verdict, or None.

    A file that is missing is left to the caller. One that is there but is
    not a regular file is reported here.
    """
    kind = kind_of(relative)
    if kind not in ("file", "missing"):
        report.error(f"{relative} {not_a_file(kind)}.")
    return read(relative)


# --- Git --------------------------------------------------------------------


def git(*args, hint=""):
    """Return what a git command printed, as bytes. Raises Stop if it failed.

    A command that fails is never treated as one that printed nothing: an
    unreadable change must not look like an empty one.
    """
    try:
        result = subprocess.run(["git", *args], cwd=ROOT, capture_output=True, check=False)
    except OSError as problem:
        raise Stop(f"'git {args[0]}' could not be run ({problem.strerror or 'error'})")
    if result.returncode != 0:
        said = result.stderr.decode("utf-8", errors="replace").strip().splitlines()
        detail = f": {said[0][:200]}" if said else ""
        raise Stop(
            f"'git {' '.join(args)}' failed with exit code {result.returncode}{detail}.{hint}"
        )
    return result.stdout


def names(output):
    """Split the output of a git command run with -z into file names.

    The output is bytes, and each name is decoded the way the operating
    system does it, so that an unusual name still finds its file.
    """
    return [os.fsdecode(name) for name in output.split(b"\0") if name]


_TREES = {}


def tree_at(commit):
    """Return {path: (mode, object ID)} for every file in a commit."""
    if commit not in _TREES:
        tree = {}
        for entry in git("ls-tree", "-r", "-z", commit).split(b"\0"):
            if not entry:
                continue
            fields, tab, name = entry.partition(b"\t")
            parts = fields.split(b" ")
            if not tab or len(parts) != 3:
                raise Stop(f"'git ls-tree -r -z {commit}' printed something unexpected.")
            tree[os.fsdecode(name)] = (parts[0].decode("ascii", "replace"), parts[2].decode("ascii", "replace"))
        _TREES[commit] = tree
    return _TREES[commit]


def show(commit, relative):
    """Return a file's text as of a commit, or None if it is not there."""
    entry = tree_at(commit).get(relative)
    if entry is None:
        return None
    mode, oid = entry
    if mode not in REGULAR_FILE_MODES:
        raise Stop(f"{relative} is not a regular file in commit {commit[:12]}.")
    return git("cat-file", "blob", oid).decode("utf-8", errors="replace")


def working_files(need_git):
    """Return every path in the working tree that git does not ignore.

    Symbolic links are listed and never followed. Without git, and when no
    pull request is being checked, every path under the root is listed.
    """
    try:
        found = names(git("ls-files", "-co", "--exclude-standard", "-z"))
    except Stop:
        if need_git:
            raise
        found = []  # not a git checkout
        for folder, folders, files in os.walk(ROOT, onerror=_cannot_list):
            folders[:] = [name for name in folders if name != ".git"]
            linked = [name for name in folders if os.path.islink(os.path.join(folder, name))]
            for name in files + linked:
                found.append(Path(folder, name).relative_to(ROOT).as_posix())
    # A path git lists may be gone from the working tree, or be a submodule.
    return sorted(name for name in set(found) if kind_of(name) in ("file", "link", "other"))


def _cannot_list(problem):
    raise Stop(f"a folder could not be listed ({problem.strerror or 'error'})")


def changes_since(base):
    """Return (start, added, deleted, touched) for the working tree.

    start is the commit the change is measured from: where the working
    tree's history left the base.
    """
    start = git(
        "merge-base", base, "HEAD",
        hint=" The base and HEAD must share history that this clone holds;"
        " fetch more of it and run the check again.",
    ).decode("ascii", "replace").strip()
    if not start:
        raise Stop(f"'git merge-base {base} HEAD' printed no commit.")
    added, deleted, touched = set(), set(), set()
    fields = names(git("diff", "--name-status", "--no-renames", "-z", start, "--"))
    if len(fields) % 2:
        raise Stop(f"'git diff --name-status -z {start}' printed something unexpected.")
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

    A rule whose status cannot be read is in the result with None, because
    its ID is taken all the same. Problems are reported only when a report is
    given; the base branch's copy is read without one.
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
        rules[rule] = None
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
    return set(check_prd_text(prd_text)[0]) if prd_text else set()


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
    for spelling, kind in KEYWORDS:
        head, rest = text[:len(spelling)], text[len(spelling):]
        if head.isascii() and head.lower() == spelling and not GLUED.match(rest):
            return kind, rest
    return None, text


def has_words(text):
    """True if the text has at least two words, IDs not counted.

    A word is a run of letters, or anything between spaces that has a letter
    in it: "adds C" and "no I/O" are two words each, "n/a" is one.
    """
    text = ID_REF.sub(" ", text)
    spaced = [part for part in text.split() if any(ch.isalpha() for ch in part)]
    return len(spaced) >= MIN_WORDS or len(WORD.findall(text)) >= MIN_WORDS


# The characters of an owner or repository name, and the characters that
# join "#12" to the text before it.
_NAME = frozenset("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
_JOINS = (_NAME - {"."}) | set("&/#")


def has_issue_ref(text):
    """True if the text names an issue or pull request.

    That is "#12" or "owner/repo#12" standing on its own, or the address of
    one on GitHub. "#12" inside a longer word, a path, or "&#12;" is not one.
    """
    if ISSUE_URL.search(text):
        return True
    for match in ISSUE_NUMBER.finditer(text):
        end = match.start()
        if end == 0 or text[end - 1] not in _JOINS:
            return True  # "#12" on its own
        repo = end
        while repo > 0 and text[repo - 1] in _NAME:
            repo -= 1
        if repo == end or repo == 0 or text[repo - 1] != "/":
            continue
        owner = repo - 1
        while owner > 0 and text[owner - 1] in _NAME:
            owner -= 1
        if owner == repo - 1:
            continue
        # "owner/repo#12": the owner starts the text, follows a character
        # that is not part of a path, or follows a dot within the name.
        if owner == 0 or text[owner - 1] not in "&/#" or "." in text[owner:repo - 2]:
            return True
    return False


# --- Repository checks ------------------------------------------------------


def check_template(rules, report):
    text = read_input(TEMPLATE, report)
    if text is None:
        if kind_of(TEMPLATE) == "missing":
            report.error(f"{TEMPLATE} is missing")
        return
    answers, duplicates = parse_answers(text)
    listed, expected = set(answers or ()), active(rules)
    for rule in sorted(expected - listed):
        report.error(f"{TEMPLATE}: no '- {rule}:' line for an active rule")
    for rule in sorted(listed - expected):
        report.error(f"{TEMPLATE}: lists {rule}, which is not an active rule")
    for rule in sorted(duplicates):
        report.error(f"{TEMPLATE}: lists {rule} more than once")
    if listed == expected and not duplicates:
        report.ok(f"{TEMPLATE} lists every active rule")


def check_references(rules, requirements, files, report):
    """AR-002: IDs used in the documentation are defined in their home."""
    failures = 0
    for name in files:
        if name.startswith(ARCHIVE) or PurePosixPath(name).suffix.lower() not in (".md", ".markdown"):
            continue
        text = read(name)
        if text is None:
            continue  # a symbolic link: its target is read under its own name
        refs = set(ID_REF.findall(visible(text)))
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


def adr_status(text):
    """Return the regex match for the status line of an ADR's text, or None."""
    for line, _ in lines_of(text or ""):
        label = ADR_STATUS_LABEL.match(line)
        if label and label.end() < len(line):
            value = line[label.end():]
            if value.startswith("*"):  # the end of "**Status:**"
                value = value[2 if value.startswith("**") else 1:]
            return ADR_STATUS.match(value.strip(" \t"))
    return None


def check_adrs(report):
    """AR-003: ADR file names, numbers, and statuses."""
    kind = kind_of(ADR_DIR)
    if kind not in ("dir", "missing"):
        reason = not_a_file(kind) if kind == "link" else "is not a folder"
        report.error(f"AR-003: {ADR_DIR} {reason}.")
        return
    folder = os.path.join(str(ROOT), *ADR_DIR.split("/"))
    entries = []
    if kind == "dir":
        for parent, folders, files in os.walk(folder, onerror=_cannot_list):
            linked = [name for name in folders if os.path.islink(os.path.join(parent, name))]
            entries += [os.path.join(parent, name) for name in files + linked]
    failures = 0
    numbers = {}
    superseded = []
    for path in sorted(entries):
        name = Path(path).relative_to(ROOT).as_posix()
        match = ADR_FILE.match(os.path.basename(path))
        if os.path.dirname(path) != folder or not match or kind_of(name) != "file":
            failures += 1
            link = "is a symbolic link and " if os.path.islink(path) else ""
            report.error(
                f"AR-003: {name} {link}does not belong in {ADR_DIR}/, which holds only "
                "ADR files named like 0001-short-title.md"
            )
            continue
        number = match.group(1)
        if number in numbers:
            failures += 1
            report.error(f"AR-003: {name} reuses number {number} ({numbers[number]})")
        numbers.setdefault(number, name)
        status = adr_status(read(name))
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


def _may_leave_quote_open(line):
    """True unless every quoted text that could start on the line ends on it.

    A quote character opens quoted text only where a value can start; one
    in the middle of a word is just a character. Where this function cannot
    tell, it follows both readings, so it errs towards True.
    """
    if '"' not in line and "'" not in line:
        return False
    states = {"out"}
    last = ""  # the last character so far that is not a space or a tab
    first = ""  # the first character of the last run of such characters
    blank = True
    for ch in line:
        can_open = not last or last in ":-?{[," or (blank and first in ("&", "!"))
        after = set()
        for state in states:
            if state == "'?":  # a quote inside '...': a second one keeps it open
                if ch == "'":
                    after.add("'")
                    continue
                state = "out"
            if state == "out":
                after.add("out")
                if can_open and ch in "\"'":
                    after.add(ch)
            elif state == '"':
                after.add('"\\' if ch == "\\" else "out" if ch == '"' else '"')
            elif state == '"\\':
                after.add('"')
            else:
                after.add("'?" if ch == "'" else "'")
        states = after
        if ch in " \t":
            blank = True
        else:
            first, last, blank = (ch if blank else first), ch, False
    return bool(states & {'"', '"\\', "'"})


def _without_quoted_value(line):
    """Return the line without the inside of a quoted value after 'key: '.

    Only for a line on which every quote that opens also closes.
    """
    opening = QUOTED_VALUE.match(line)
    if not opening:
        return line
    quote, start = opening.group(1), opening.end()
    at = start
    while at < len(line):
        if quote == '"' and line[at] == "\\":
            at += 2
        elif line[at] != quote:
            at += 1
        elif quote == "'" and line[at + 1:at + 2] == "'":
            at += 2
        else:
            return line[:start] + line[at:]
    return line


def _starts_entry(line, index):
    """True if a key at line[index] would start an entry of a mapping.

    Before it there is nothing on the line, or one of "{", "[" and ",", with
    at most these in between: "-", "?", ":", anchors, and tags.
    """
    while True:
        end = index
        while end > 0 and line[end - 1] in " \t":
            end -= 1
        if end == 0 or line[end - 1] in "{[,":
            return True
        if end == index:
            return False  # joined to the text before it
        index = max(line.rfind(" ", 0, end), line.rfind("\t", 0, end)) + 1
        token = line[index:end]
        if token not in ("-", "?", ":") and token[0] not in "&!":
            # The same, straight after the start of a flow entry: "{? uses".
            return bool(re.search(r"[{\[,](?:[-?:]$|[&!])", token))


def _unescape(match):
    try:
        return chr(int(next(group for group in match.groups() if group), 16))
    except (ValueError, OverflowError):
        return match.group(0)


def _sets_uses(line):
    """True if the line sets a 'uses' key in any way YAML allows, or may."""
    probes = [line]
    if "\\" in line:
        probes.append(YAML_ESCAPE.sub(_unescape, line))  # "\x75ses": ...
    for probe in probes:
        if any(_starts_entry(probe, found.start()) for found in USES_KEY.finditer(probe)):
            return True
        if EXPLICIT_USES.match(probe):  # "? uses", with ": value" on the next line
            return True
    # "*name : value": the key is whatever the anchor holds.
    return any(_starts_entry(line, found.start()) for found in ALIAS_KEY.finditer(line))


def actions_in(text):
    """Return (values, unreadable line numbers) for the 'uses' keys in a file.

    This is not a YAML parser. It finds every place where a "uses" key can
    be set, reads the one-line form, and reports every other form as
    unreadable. Comments, the text under "key: |" or "key: >", and a quoted
    value after "key: " are not YAML structure and are set aside, but only
    while it is certain where they start and end: not after a line that may
    leave a quote open, and not in a file with unusual line break
    characters. From there on every line is examined whole.
    """
    values, unreadable = [], []
    text = text or ""
    certain = not any(ch in text for ch in ODD_LINE_BREAKS)
    inside = None  # the column of the key whose block of text we are in
    for number, line in enumerate(text.splitlines(), 1):
        if inside is not None:
            indent = len(line) - len(line.lstrip(" "))
            if not line.strip(" \t") or indent > inside:
                continue
            inside = None
        structure = line
        if certain:
            comment = COMMENT.search(line)
            # With no quote before it, "#" cannot be inside quoted text.
            if comment and not set("\"'") & set(line[:comment.start()]):
                structure = line[:comment.start()]
            if _may_leave_quote_open(structure):
                certain, structure = False, line
            else:
                block = BLOCK_SCALAR.match(structure)
                inside = len(block.group(1)) if block else None
                structure = _without_quoted_value(structure)
        if not _sets_uses(structure):
            continue
        match = USES_LINE.match(line)
        if match:
            values.append(next(group for group in match.groups() if group))
        else:
            unreadable.append(number)
    return values, unreadable


def dependency(value):
    """Return (identity, name to cite) for a 'uses' value; None if local.

    The identity tells one dependency from another: the whole path of an
    action or reusable workflow, or the registry, port, and repository of an
    image. A description cites an action by its owner and repository, and
    an image by its identity.
    """
    if value.startswith("./"):
        return None
    if value.startswith("docker://"):
        image = value[len("docker://"):].split("@")[0]
        if image.rfind(":") > image.rfind("/"):
            image = image[:image.rfind(":")]  # a tag, not a registry port
        return "docker://" + image.lower(), image.lower()
    parts = value.split("@")[0].split("/")
    repository = "/".join(parts[:2]).lower()
    return "/".join([repository] + parts[2:]), repository


def check_action_pins(files, report):
    """AR-004: every action is pinned to a full commit SHA."""
    failures = 0
    count = 0
    kind = kind_of(WORKFLOW_DIR)
    if kind not in ("dir", "missing"):
        failures += 1
        reason = not_a_file(kind) if kind == "link" else "is not a folder"
        report.error(f"AR-004: {WORKFLOW_DIR} {reason}.")
    for name in files:
        if not is_action_file(name):
            continue
        text = read(name)
        if text is None:
            failures += 1
            report.error(f"AR-004: {name} {not_a_file(kind_of(name))}.")
            continue
        values, unreadable = actions_in(text)
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
            if not pinned.match(value):
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
        if kind == "complies":
            if rule == "AR-001" and not (
                REQUIREMENT_REF.search(rest) or has_issue_ref(rest) or has_words(rest)
            ):
                problem = (
                    "after 'Complies', name what the change implements: a "
                    "requirement ID, an issue, or its single purpose in a few words"
                )
        elif kind == "n/a":
            if rule == "AR-001":
                problem = (
                    "this rule applies to every pull request, so 'N/A' is not an "
                    "answer. Say what the change implements after 'Complies'."
                )
            elif not has_words(rest):
                problem = f"'N/A' needs a reason of at least {MIN_WORDS} words after it"
        elif kind == "deviates":
            if rule == "AR-001":
                if not has_words(rest):
                    problem = "'Deviates' needs the reason on the same line"
            else:
                adr = ADR_PATH.search(rest)
                text = read(adr.group(0)) if adr else None
                status = adr_status(text)
                if not adr:
                    problem = (
                        "'Deviates' needs the ADR that records why, for example "
                        "docs/adr/0002-short-title.md"
                    )
                elif text is None:
                    problem = f"{adr.group(0)} does not exist"
                elif not status or status.group(1).lower() != "accepted":
                    problem = f"{adr.group(0)} must have status Accepted to justify a deviation"
        else:  # anything that is not one of the three is never a pass
            problem = "the answer must start with 'Complies', 'N/A', or 'Deviates'"
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


def check_rules_kept(before, rules, report):
    """A rule the change started from is still there, whatever its status."""
    for rule in sorted(set(before) - set(rules)):
        report.error(
            f"{ARCHITECTURE}: this pull request deletes {rule}, which is a rule on "
            "the base branch. A rule keeps its row and its heading so that its ID "
            "stays taken: set its status to Retired instead."
        )


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


def check_new_actions(start, body, kinds, files, report):
    """AR-004: an action the change did not start with is named in the description."""
    known = set()
    for name, (mode, _) in tree_at(start).items():
        if is_action_file(name) and mode in REGULAR_FILE_MODES:
            known.update(dependency(value) for value in actions_in(show(start, name))[0])
    current = set()
    for name in files:
        if is_action_file(name):
            current.update(dependency(value) for value in actions_in(read(name))[0])
    new = sorted(found for found in current - known if found)
    if not new:
        return
    text = visible(body).lower()
    missing = []
    for identity, cited in new:
        image = identity.startswith("docker://")
        pattern = (
            r"(?<![\w/.-])" + ("(?:docker://)?" if image else "")
            + re.escape(cited) + (r"(?![\w/-])" if image else r"(?![\w-])")
        )
        if not re.search(pattern, text):
            missing.append((identity, cited))
    for identity, cited in missing:
        report.error(
            f"AR-004: the description does not name the new action {identity}. "
            f"Name {cited} with its license, its pinned SHA, and why it is needed."
        )
    added = ", ".join(identity for identity, _ in new)
    if kinds.get("AR-004") == "n/a":
        report.error(f"AR-004 is answered 'N/A', but this pull request adds {added}")
    elif not missing:
        report.ok(f"AR-004: the description names {len(new)} new action(s)")


def is_test_file(name):
    return name.startswith(TEST_DIRS) and PurePosixPath(name).suffix in TEST_SUFFIXES


def is_product_source(name):
    path = PurePosixPath(name)
    return (
        name.startswith(SOURCE_DIRS)
        and not name.startswith(TEST_DIRS)
        and path.suffix.lower() not in (".md", ".markdown")
    )


def changed_lines(start, name):
    """Return (removed, added) for a file: lists of (line number, text).

    Removed lines are numbered as in the start commit, added lines as in the
    working tree. A deleted file has all its lines removed.
    """
    if kind_of(name) == "missing":
        text = show(start, name) or ""
        return list(enumerate(text.splitlines(), 1)), []
    patch = git(
        "diff", "--no-ext-diff", "--no-textconv", "--no-color", "-U0", start, "--", name
    ).decode("utf-8", errors="replace")
    removed, added = [], []
    old = new = None
    for line in patch.split("\n"):
        hunk = HUNK.match(line)
        if hunk:
            old, new = int(hunk.group(1)), int(hunk.group(2))
            continue
        if old is None:
            continue  # the header of the patch, before the first hunk
        if line.startswith("-"):
            removed.append((old, line[1:]))
            old += 1
        elif line.startswith("+"):
            added.append((new, line[1:]))
            new += 1
    return removed, added


def _quote(found):
    number, text = found
    text = text.strip()
    return f"line {number}: '{text[:80]}{'...' if len(text) > 80 else ''}'"


def check_tests(start, deleted, touched, kinds, report):
    """AR-007: product source comes with a test; weakened tests are pointed out."""
    source = sorted(name for name in touched if is_product_source(name))
    tests = sorted(name for name in touched - deleted if is_test_file(name))
    if source and tests:
        report.ok(f"AR-007: the change to product source comes with {len(tests)} test file(s)")
    elif source:
        shown = ", ".join(source[:3]) + (", ..." if len(source) > 3 else "")
        message = (
            f"AR-007: this pull request changes product source ({shown}) but "
            f"adds or changes no test file under {' or '.join(TEST_DIRS)}"
        )
        kind = kinds.get("AR-007")
        if kind == "n/a":
            report.warn(
                message + ". It answers 'N/A': the maintainer must confirm that "
                "no behavior changes before merging."
            )
        elif kind == "deviates":
            report.ok(message + ", as its accepted 'Deviates' answer allows")
        else:
            report.error(
                message + ". Add a test that fails without the change, or answer "
                "'N/A' with the reason no behavior changes."
            )

    existing = tree_at(start)
    for name in sorted(touched):
        if not is_test_file(name) or name not in existing:
            continue
        removed, added = changed_lines(start, name)
        weaker = [found for found in removed if ASSERTION.search(found[1])]
        skips = [found for found in added if SKIP.search(found[1])]
        if name in deleted and weaker:
            what = f"deletes a test file with {len(weaker)} assertion(s)"
        else:
            parts = []
            if weaker:
                parts.append(
                    f"removes or changes {len(weaker)} assertion(s) "
                    f"({'; '.join(_quote(found) for found in weaker[:3])})"
                )
            if skips:
                parts.append(f"skips a test ({'; '.join(_quote(found) for found in skips[:3])})")
            what = " and ".join(parts)
        if weaker or skips:
            report.warn(
                f"AR-007: {name} {what}. If this weakens a test, the description must "
                "name the assertion and the reason."
            )


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


def read_description(args):
    """Return (description, author login or None). Raises Stop if unusable."""
    source = args.event or args.body_file
    try:
        data = Path(source).read_bytes()
        if not args.event:
            return data.decode("utf-8", errors="replace"), None
        event = json.loads(data)
    except (OSError, ValueError, RecursionError) as problem:
        raise Stop(f"could not read the pull request description: {problem}")

    # The event file is input like any other: check its shape before use.
    def wrong(what):
        return Stop(f"could not read the pull request description: {what} in the event file")

    if not isinstance(event, dict):
        raise wrong("there is no JSON object")
    pull = event.get("pull_request", {})
    if not isinstance(pull, dict):
        raise wrong("'pull_request' is not an object")
    body = pull.get("body")
    if body is not None and not isinstance(body, str):
        raise wrong("'pull_request.body' is not text")
    user = pull.get("user")
    if user is not None and not isinstance(user, dict):
        raise wrong("'pull_request.user' is not an object")
    login = (user or {}).get("login")
    if login is not None and not isinstance(login, str):
        raise wrong("'pull_request.user.login' is not text")
    return body or "", login


def check_pull_request(args, rules, requirements, files, report):
    try:
        base = git("rev-parse", "--verify", "--quiet", f"{args.base}^{{commit}}")
    except Stop:
        report.error(f"base commit '{args.base}' was not found")
        return
    base = base.decode("ascii", "replace").strip()
    body, author = read_description(args)

    base_rules = parse_rules(show(base, ARCHITECTURE))
    start, added, deleted, touched = changes_since(base)
    check_rules_kept(parse_rules(show(start, ARCHITECTURE)), rules, report)
    required = active(rules) | active(base_rules)
    kinds = {}
    if author in EXEMPT_AUTHORS:
        report.ok(
            f"pull request by {author}: the '{ANSWERS_HEADING}' section is not "
            "required and the IDs in the description are not checked; the "
            "checks on the change apply"
        )
    else:
        answers, duplicates = parse_answers(body)
        kinds = check_answers(required, answers, duplicates, report)
        # A description may name a rule or requirement that this change removes.
        check_description_refs(
            body,
            {**base_rules, **rules},
            requirements | requirement_ids(show(base, PRD)),
            report,
        )
    check_decision_record(start, added, deleted, touched, kinds, report)
    check_new_actions(start, body, kinds, files, report)
    if "AR-007" in required:
        check_tests(start, deleted, touched, kinds, report)
    warn_about_enforcement_changes(start, touched, report)


# --- Entry point ------------------------------------------------------------


def run_checks(args, report):
    files = working_files(need_git=bool(args.base))
    rules = parse_rules(read_input(ARCHITECTURE, report), report)
    requirements = requirement_ids(read_input(PRD, report))

    check_template(rules, report)
    check_references(rules, requirements, files, report)
    check_adrs(report)
    check_action_pins(files, report)

    if args.base:
        check_pull_request(args, rules, requirements, files, report)


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

    for stream in (sys.stdout, sys.stderr):
        try:  # a message never fails to print, whatever the terminal accepts
            stream.reconfigure(errors="backslashreplace")
        except (AttributeError, ValueError):
            pass

    report = Report()
    try:
        run_checks(args, report)
    except Stop as stop:
        report.error(f"{str(stop).rstrip('.')}. The check stopped here.")
    except Exception as problem:  # noqa: BLE001  (fail with a message, never a traceback)
        report.error(
            f"internal error in the rules check ({type(problem).__name__}: "
            f"{str(problem)[:200]}). The check stopped here."
        )

    if report.errors:
        print(f"\n{report.errors} problem(s). The rules are in {ARCHITECTURE}.")
        return 1
    print("\nAll rule checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
