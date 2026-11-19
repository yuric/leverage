#!/usr/bin/env python3
"""Check the repository, and optionally a pull request, against the
architecture rules in docs/ARCHITECTURE.md ("Rules").

Repository checks (always run):

  * the rules table is well formed and matches the rule headings;
  * the pull request template lists exactly the active rules;
  * AR-002: every FR-/NFR-/AR- ID used in docs/ is defined, and every AR- ID
    used in any Markdown file is defined;
  * AR-003: every ADR in docs/adr/ has a valid name, number, and status;
  * AR-004: every action in .github/workflows/ is pinned to a commit SHA.

Pull request checks (run when --base is given):

  * the description answers every active rule with "Complies", "N/A" and a
    reason, or "Deviates" and an ADR;
  * AR-001: a "Complies" answer cites a defined requirement ID or an issue;
  * AR-002: every ID used in the description is defined;
  * AR-003: a new dependency manifest, or a change to the Components or
    Technology choices section, comes with an ADR;
  * AR-004: an action the base branch does not use is named in the
    description.

The active rules are those marked Active on the base branch or in the working
tree, so a pull request cannot drop a rule to avoid answering it. The checks
prove that each rule was answered, not that the answer is true.

Usage:
  python3 scripts/check_rules.py
  python3 scripts/check_rules.py --base origin/main --body-file body.md

Without --body-file the description is read from the PR_BODY environment
variable, and the author from PR_AUTHOR; that is how CI passes them.
Standard library only; exits 0 when every check passes, 1 otherwise.
"""

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from check_prd_ids import check as check_prd  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
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
# AR-003: adding one of these files means a language or runtime was chosen.
MANIFESTS = {
    "package.json", "pyproject.toml", "setup.py", "Pipfile", "go.mod",
    "Cargo.toml", "Gemfile", "pom.xml", "build.gradle", "build.gradle.kts",
    "composer.json", "Package.swift", "mix.exs", "deno.json", "Dockerfile",
}
MANIFEST_PATTERN = re.compile(r"^requirements[\w.-]*\.txt$|\.(csproj|fsproj)$")
# Bots that cannot fill in a pull request description.
EXEMPT_AUTHORS = {"dependabot[bot]"}

COMMENT = re.compile(r"<!--.*?-->", re.DOTALL)
HEADING = re.compile(r"^(#{1,6})\s+(.*?)\s*#*\s*$")
RULE_ID = re.compile(r"^AR-\d{3}$")
LOOKS_LIKE_RULE_ID = re.compile(r"^AR[\s_-]*\d+$", re.IGNORECASE)
RULE_HEADING = re.compile(r"^###\s+(AR[\s_-]*\d+)\b", re.IGNORECASE)
RULE_REF = re.compile(r"\bAR-\d+\b")
REQUIREMENT_REF = re.compile(r"\b(?:FR|NFR)-\d+\b")
ISSUE_REF = re.compile(
    r"(?<![\w&/])#\d+\b|github\.com/[\w.-]+/[\w.-]+/(?:issues|pull)/\d+"
)
ANSWER = re.compile(
    r"^\s*[-*+]\s+(?:\[[ xX]\]\s+)?[*_`]*(AR-\d+)[*_`]*\s*:\s*(.*)$"
)
ADR_PATH = re.compile(r"docs/adr/\d{4}-[a-z0-9]+(?:-[a-z0-9]+)*\.md")
ADR_NAME = re.compile(r"^(\d{4})-[a-z0-9]+(?:-[a-z0-9]+)*\.md$")
ADR_STATUS_LINE = re.compile(r"^[\s*_|>-]*status\b[\s*_:|]+(.+?)[\s*_|]*$", re.IGNORECASE)
ADR_STATUS = re.compile(
    r"^(Proposed|Accepted|Rejected|Superseded by (\d{4}))$", re.IGNORECASE
)
USES = re.compile(r"^\s*(?:-\s*)?uses:\s*['\"]?([^'\"\s#]+)")
PINNED = re.compile(r"@[0-9a-f]{40}$")
PINNED_IMAGE = re.compile(r"@sha256:[0-9a-f]{64}$")
MIN_REASON = 10  # characters; enough to rule out "-", "none", "n/a"


class Report:
    """Collects results and prints them, as annotations when run in CI."""

    def __init__(self):
        self.errors = 0
        self.in_ci = os.environ.get("GITHUB_ACTIONS") == "true"

    def _annotate(self, kind, message):
        if self.in_ci:
            data = message.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
            print(f"::{kind}::{data}")

    def ok(self, message):
        print(f"OK: {message}")

    def warn(self, message):
        print(f"WARNING: {message}")
        self._annotate("warning", message)

    def error(self, message):
        self.errors += 1
        print(f"FAIL: {message}")
        self._annotate("error", message)


# --- Reading Markdown -------------------------------------------------------


def lines_of(text, keep_code=False):
    """Yield (line, in_code) without HTML comments.

    Lines inside fenced code blocks are skipped unless keep_code is set, so
    that an example is never mistaken for a heading, an ID, or an answer.
    """
    text = COMMENT.sub("", text.replace("\r\n", "\n"))
    in_code = False
    for line in text.split("\n"):
        if line.lstrip().startswith(("```", "~~~")):
            in_code = not in_code
            if keep_code:
                yield line, True
            continue
        if keep_code or not in_code:
            yield line, in_code


def section(text, title, level=None, keep_code=False):
    """Return the text under a heading, or None if the heading is absent.

    With level=None the heading may be at any depth. The section ends at the
    next heading of the same depth or shallower.
    """
    found = None
    body = []
    for line, in_code in lines_of(text, keep_code):
        heading = None if in_code else HEADING.match(line)
        if heading:
            depth = len(heading.group(1))
            if found is not None and depth <= found:
                break
            if (
                found is None
                and level in (None, depth)
                and heading.group(2).strip().lower() == title.lower()
            ):
                found = depth
                continue
        if found is not None:
            body.append(line)
    return "\n".join(body).strip() if found is not None else None


def visible(text):
    return "\n".join(line for line, _ in lines_of(text))


def read(relative):
    path = ROOT / relative
    return path.read_text(encoding="utf-8") if path.is_file() else None


# --- Git --------------------------------------------------------------------


def git(*args):
    """Return git's output, or None if the command failed."""
    try:
        result = subprocess.run(
            ["git", *args], cwd=ROOT, capture_output=True, text=True, check=False
        )
    except OSError:
        return None
    return result.stdout if result.returncode == 0 else None


def show(ref, relative):
    """Return a file's text as of a commit, or None if it is not there."""
    return git("show", f"{ref}:{relative}")


def markdown_files():
    listed = git("ls-files", "-co", "--exclude-standard", "--", "*.md")
    if listed is not None:
        return sorted(name for name in listed.splitlines() if (ROOT / name).is_file())
    return sorted(
        path.relative_to(ROOT).as_posix()
        for path in ROOT.rglob("*.md")
        if ".git" not in path.parts
    )


def changes_since(base):
    """Return (added, touched) paths in the working tree relative to base."""
    start = (git("merge-base", base, "HEAD") or "").strip() or base
    added, touched = set(), set()
    for line in (git("diff", "--name-status", "--no-renames", start) or "").splitlines():
        status, _, name = line.partition("\t")
        touched.add(name)
        if status.startswith("A"):
            added.add(name)
    untracked = (git("ls-files", "-o", "--exclude-standard") or "").splitlines()
    added.update(untracked)
    touched.update(untracked)
    return start, added, touched


# --- Rules ------------------------------------------------------------------


def parse_rules(text, report=None):
    """Return {rule ID: 'active' | 'pending'} from the Rules section.

    Problems are reported only when a report is given; the base branch's copy
    is read without one.
    """
    rules = {}
    problems = []
    body = section(text or "", RULES_HEADING, level=2)
    if body is None:
        problems.append(f"{ARCHITECTURE} has no '## {RULES_HEADING}' section")
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
        if status == "active":
            rules[rule] = "active"
        elif status.startswith("pending"):
            rules[rule] = "pending"
        else:
            problems.append(f"{rule} has no status of Active or Pending")

    for rule in sorted(set(rules) - set(headings)):
        problems.append(f"{rule} is in the rules table but has no '### {rule}' heading")
    for rule in sorted(set(headings) - set(rules)):
        problems.append(f"'### {rule}' has no row in the rules table")

    if report:
        for problem in problems:
            report.error(f"{ARCHITECTURE}: {problem}")
        if not problems:
            active = sum(1 for status in rules.values() if status == "active")
            report.ok(
                f"{len(rules)} rule(s) in {ARCHITECTURE} "
                f"({active} active, {len(rules) - active} pending)"
            )
    return rules


def active(rules):
    return {rule for rule, status in rules.items() if status == "active"}


def parse_answers(text):
    """Return ({rule ID: answer text}, duplicated IDs) from a description."""
    answers, duplicates = {}, set()
    current = None
    for line in (section(text, ANSWERS_HEADING) or "").split("\n"):
        match = ANSWER.match(line)
        if match:
            current = match.group(1)
            if current in answers:
                duplicates.add(current)
            answers[current] = match.group(2).strip()
        elif current and line.strip() and line[:1] in " \t":
            answers[current] += " " + line.strip()  # wrapped answer
        else:
            current = None
    return answers, duplicates


def classify(answer):
    """Return (kind, rest) where kind is complies, n/a, deviates, or None."""
    text = answer.strip().strip("*_`").strip()
    for kind, keywords in (
        ("complies", ("complies",)),
        ("n/a", ("n/a", "not applicable")),
        ("deviates", ("deviates",)),
    ):
        for keyword in keywords:
            if text.lower().startswith(keyword):
                return kind, text[len(keyword):].strip(" \t*_`-–—:,.()")
    return None, text


# --- Repository checks ------------------------------------------------------


def check_template(rules, report):
    text = read(TEMPLATE)
    if text is None:
        report.error(f"{TEMPLATE} is missing")
        return
    answers, _ = parse_answers(text)
    listed, expected = set(answers), active(rules)
    for rule in sorted(expected - listed):
        report.error(f"{TEMPLATE}: no '- {rule}:' line for an active rule")
    for rule in sorted(listed - expected):
        report.error(f"{TEMPLATE}: lists {rule}, which is not an active rule")
    if listed == expected:
        report.ok(f"{TEMPLATE} lists every active rule")


def check_references(rules, requirements, report):
    """AR-002: IDs used in the documentation are defined in their home."""
    failures = 0
    for name in markdown_files():
        if name.startswith(ARCHIVE):
            continue
        text = visible(read(name) or "")
        unknown = {ref for ref in RULE_REF.findall(text) if ref not in rules}
        if name.startswith("docs/") and name != PRD:  # the PRD has its own check
            unknown |= {
                ref for ref in REQUIREMENT_REF.findall(text) if ref not in requirements
            }
        for ref in sorted(unknown):
            failures += 1
            home = PRD if ref.startswith(("FR", "NFR")) else ARCHITECTURE
            report.error(f"AR-002: {name} refers to {ref}, which {home} does not define")
    if not failures:
        report.ok("AR-002: every requirement and rule ID used in the docs is defined")


def check_adrs(report):
    """AR-003: ADR file names, numbers, and statuses."""
    folder = ROOT / ADR_DIR
    files = sorted(folder.glob("*.md")) if folder.is_dir() else []
    failures = 0
    numbers = {}
    superseded = []
    for path in files:
        name = f"{ADR_DIR}/{path.name}"
        match = ADR_NAME.match(path.name)
        if not match:
            failures += 1
            report.error(f"AR-003: {name} is not named like 0001-short-title.md")
            continue
        number = match.group(1)
        if number in numbers:
            failures += 1
            report.error(f"AR-003: {name} reuses number {number} ({numbers[number]})")
        numbers.setdefault(number, name)

        status = None
        for line, _ in lines_of(path.read_text(encoding="utf-8")):
            found = ADR_STATUS_LINE.match(line)
            if found:
                status = ADR_STATUS.match(found.group(1).strip())
                break
        if not status:
            failures += 1
            report.error(
                f"AR-003: {name} needs a line 'Status: Proposed', 'Accepted', "
                "'Rejected', or 'Superseded by NNNN'"
            )
        elif status.group(2):
            superseded.append((name, number, status.group(2)))

    for name, number, successor in superseded:
        if successor == number or successor not in numbers:
            failures += 1
            report.error(f"AR-003: {name} is superseded by {successor}, which does not exist")
    if not failures:
        report.ok(f"AR-003: {len(files)} ADR(s) in {ADR_DIR}/ are well formed")


def actions_in(text):
    """Return the value of every 'uses:' line in a workflow."""
    found = []
    for line in (text or "").splitlines():
        match = USES.match(line)
        if match:
            found.append(match.group(1))
    return found


def action_name(value):
    """'Owner/Repo/path@ref' -> 'owner/repo'; None for a local action."""
    if value.startswith("./"):
        return None
    if value.startswith("docker://"):
        return re.split(r"[@:]", value[len("docker://"):])[0].lower()
    return "/".join(value.split("@")[0].split("/")[:2]).lower()


def workflow_files():
    folder = ROOT / WORKFLOW_DIR
    if not folder.is_dir():
        return []
    return sorted(p for p in folder.iterdir() if p.suffix in (".yml", ".yaml"))


def check_action_pins(report):
    """AR-004: every action is pinned to a full commit SHA."""
    failures = 0
    count = 0
    for path in workflow_files():
        for value in actions_in(path.read_text(encoding="utf-8")):
            count += 1
            if value.startswith("./"):
                continue
            pinned = PINNED_IMAGE if value.startswith("docker://") else PINNED
            if not pinned.search(value):
                failures += 1
                report.error(
                    f"AR-004: {WORKFLOW_DIR}/{path.name} uses '{value}', which is "
                    "not pinned to a full commit SHA"
                )
    if not failures:
        report.ok(f"AR-004: {count} action reference(s) are pinned to a commit SHA")


# --- Pull request checks ----------------------------------------------------


def check_answers(required, answers, duplicates, report):
    """Every active rule has one well-formed answer. Returns {rule: kind}."""
    kinds = {}
    if not answers and required:
        report.error(
            f"The description has no '## {ANSWERS_HEADING}' section with a line "
            f"for each active rule ({', '.join(sorted(required))}). "
            f"See {ARCHITECTURE}, 'How the rules are applied'."
        )
        return kinds
    for rule in sorted(duplicates):
        report.error(f"{rule} is answered more than once in the description")
    for rule in sorted(required):
        if rule not in answers:
            report.error(f"{rule} is an active rule and the description does not answer it")
            continue
        kind, rest = classify(answers[rule])
        kinds[rule] = kind
        if kind is None:
            report.error(
                f"{rule}: the answer must start with 'Complies', 'N/A', or 'Deviates'"
            )
        elif kind == "n/a" and len(rest) < MIN_REASON:
            report.error(f"{rule}: 'N/A' needs a reason on the same line")
        elif kind == "deviates":
            adr = ADR_PATH.search(answers[rule])
            if not adr:
                report.error(
                    f"{rule}: 'Deviates' needs the ADR that records why, "
                    "for example docs/adr/0002-short-title.md"
                )
            elif not (ROOT / adr.group(0)).is_file():
                report.error(f"{rule}: {adr.group(0)} does not exist")
    if required and all(kinds.get(rule) for rule in required):
        report.ok(f"the description answers {len(required)} active rule(s)")
    return kinds


def check_citations(body, kinds, rules, requirements, report):
    """AR-001 and AR-002 for the description."""
    text = visible(body)
    cited = set(REQUIREMENT_REF.findall(text))
    for ref in sorted(cited - set(requirements)):
        report.error(f"AR-002: the description refers to {ref}, which {PRD} does not define")
    for ref in sorted(set(RULE_REF.findall(text)) - set(rules)):
        report.error(
            f"AR-002: the description refers to {ref}, which {ARCHITECTURE} does not define"
        )
    if kinds.get("AR-001") == "complies":
        if cited & set(requirements) or ISSUE_REF.search(text):
            report.ok("AR-001: the description cites a requirement or an issue")
        else:
            report.error(
                "AR-001 is answered 'Complies', but the description names no "
                f"requirement ID from {PRD} and no issue. Cite one, or answer "
                "'N/A' with the single purpose of the change as the reason."
            )


def check_decision_record(start, added, touched, kinds, report):
    """AR-003: choices that need an ADR come with one."""
    reasons = [
        f"adds {name}"
        for name in sorted(added)
        if Path(name).name in MANIFESTS or MANIFEST_PATTERN.search(Path(name).name)
    ]
    before = show(start, ARCHITECTURE) or ""
    after = read(ARCHITECTURE) or ""
    for title in DECISION_SECTIONS:
        if section(before, title, 2, keep_code=True) != section(after, title, 2, keep_code=True):
            reasons.append(f"changes the '{title}' section of {ARCHITECTURE}")
    if not reasons:
        return
    if any(name.startswith(ADR_DIR + "/") and name.endswith(".md") for name in touched):
        report.ok("AR-003: the change comes with an ADR")
        return
    message = (
        f"AR-003: this pull request {' and '.join(reasons)}, "
        f"but adds or changes no ADR in {ADR_DIR}/"
    )
    if kinds.get("AR-003") == "n/a":
        report.warn(message + ". It answers 'N/A': the maintainer must confirm the reason.")
    else:
        report.error(
            message + ". Add the ADR, or answer 'N/A' with the reason none is needed."
        )


def check_new_actions(base, body, report):
    """AR-004: an action the base branch does not use is named in the description."""
    known = set()
    listed = git("ls-tree", "-r", "--name-only", base, "--", WORKFLOW_DIR) or ""
    for name in listed.splitlines():
        known.update(action_name(value) for value in actions_in(show(base, name)))
    current = set()
    for path in workflow_files():
        current.update(action_name(value) for value in actions_in(path.read_text(encoding="utf-8")))
    new = sorted(name for name in current - known if name)
    for name in new:
        if name not in body.lower():
            report.error(
                f"AR-004: the description does not name the new action {name}. "
                "Name it with its license, its pinned SHA, and why it is needed."
            )
    if new and all(name in body.lower() for name in new):
        report.ok(f"AR-004: the description names {len(new)} new action(s)")


# --- Entry point ------------------------------------------------------------


def main(argv):
    parser = argparse.ArgumentParser(
        description="Check the repository, and optionally a pull request, "
        "against the architecture rules."
    )
    parser.add_argument(
        "--base", help="base commit of the pull request, for example origin/main"
    )
    parser.add_argument(
        "--body-file", help="file holding the pull request description"
    )
    args = parser.parse_args(argv[1:])

    report = Report()
    rules = parse_rules(read(ARCHITECTURE), report)
    prd = ROOT / PRD
    requirements = check_prd(prd)[0] if prd.is_file() else {}

    check_template(rules, report)
    check_references(rules, requirements, report)
    check_adrs(report)
    check_action_pins(report)

    if args.base:
        if git("rev-parse", "--verify", "--quiet", f"{args.base}^{{commit}}") is None:
            report.error(f"base commit '{args.base}' was not found")
        elif os.environ.get("PR_AUTHOR") in EXEMPT_AUTHORS:
            report.ok(
                f"pull request by {os.environ['PR_AUTHOR']}: the "
                f"'{ANSWERS_HEADING}' section is not required"
            )
        else:
            if args.body_file:
                body = Path(args.body_file).read_text(encoding="utf-8")
            else:
                body = os.environ.get("PR_BODY", "")
            base_rules = parse_rules(show(args.base, ARCHITECTURE))
            required = active(rules) | active(base_rules)
            answers, duplicates = parse_answers(body)
            kinds = check_answers(required, answers, duplicates, report)
            check_citations(body, kinds, {**base_rules, **rules}, requirements, report)
            start, added, touched = changes_since(args.base)
            check_decision_record(start, added, touched, kinds, report)
            check_new_actions(args.base, body, report)

    if report.errors:
        print(f"\n{report.errors} problem(s). The rules are in {ARCHITECTURE}.")
        return 1
    print("\nAll rule checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
