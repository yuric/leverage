#!/usr/bin/env python3
"""Self-test for check_rules.py.

Builds a small throwaway repository, then runs check_rules.py against planted
good and bad pull requests and compares the exit code and the messages. Each
case is something the check must accept, must reject, or once got wrong.

Usage: python3 scripts/test_check_rules.py [-v]
Standard library and git only; exits 0 when every case behaves as expected.
"""

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
VERBOSE = "-v" in sys.argv[1:]
SHA = "a" * 40
DIGEST = "b" * 64


def fixture_env(parent):
    """Return the environment for every command run in the fixture.

    Git reads where its repository, working tree, and index are from GIT_*
    variables before it looks at the current folder. None of them is passed
    on, so a caller's GIT_DIR cannot point these commands at another
    repository.
    """
    env = {
        key: value for key, value in parent.items()
        if not key.startswith("GIT_")
        and key not in ("GITHUB_ACTIONS", "PYTHONPATH", "PYTHONDONTWRITEBYTECODE")
    }
    env.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_SYSTEM=os.devnull)
    return env


ENV = fixture_env(os.environ)

ARCHITECTURE = """# Architecture

## Rules

| ID | Rule | Status |
|----|------|--------|
| AR-001 | Scope | Active |
| AR-002 | Homes | Active |
| AR-003 | Decisions | Active |
| AR-004 | Dependencies | Active |
| AR-005 | Direction | Pending: activated later |

### AR-001 Scope

### AR-002 Homes

### AR-003 Decisions

### AR-004 Dependencies

### AR-005 Direction

## Components

_TBD_

## Data

_TBD_

## Technology choices

_TBD_
"""

PRD = """# PRD

## Functional requirements

| ID | Requirement |
|----|-------------|
| FR-001 | Something |

## Non-functional requirements

| ID | Requirement |
|----|-------------|
| NFR-001 | Something |
"""

TEMPLATE = """## What and why

## Architecture rules

<!-- Answer every line. -->

- AR-001:
- AR-002:
- AR-003:
- AR-004:

## Checklist

- [ ] Something.
"""

STEPS = "on: push\njobs:\n  a:\n    runs-on: ubuntu-24.04\n    steps:\n"
WORKFLOW = f"""on: push
jobs:
  check:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@{SHA} # v1
      - run: echo ok
"""

ADR = "# 0001. Use Python\n\nStatus: Accepted\n\n## Context\n\n## Decision\n"

# A stand-in for git that fails one subcommand and passes the rest on.
FAKE_GIT = """#!/bin/sh
if [ "$1" = "$FAIL_GIT" ]; then
  echo "fatal: simulated failure" >&2
  exit 128
fi
exec "$REAL_GIT" "$@"
"""

WORK = Path(tempfile.mkdtemp(prefix="check_rules_test_"))
REPO = WORK / "repo"
results = []


def targets_fixture(env=None):
    """True if git, run in the fixture, acts on the fixture and nothing else."""
    result = subprocess.run(
        ["git", "rev-parse", "--show-toplevel", "--absolute-git-dir"],
        cwd=REPO, capture_output=True, text=True, env=ENV if env is None else env, check=False,
    )
    found = result.stdout.splitlines()
    home = Path(os.path.realpath(WORK))
    return result.returncode == 0 and len(found) == 2 and all(
        home in Path(os.path.realpath(path)).parents for path in found
    )


def sh(*args, cwd=None, check=True):
    result = subprocess.run(
        args, cwd=cwd or REPO, capture_output=True, text=True, env=ENV, check=False
    )
    if check and result.returncode != 0:
        raise SystemExit(f"{args} failed:\n{result.stdout}\n{result.stderr}")
    return result


def write(relative, text):
    path = REPO / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    if isinstance(text, bytes):
        path.write_bytes(text)
    else:
        path.write_text(text, encoding="utf-8")


def edit(relative, old, new):
    text = (REPO / relative).read_text(encoding="utf-8")
    assert old in text, f"{old!r} is not in {relative}"
    write(relative, text.replace(old, new))


def link(target, relative):
    """Make a symbolic link at a path in the fixture."""
    path = REPO / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    os.symlink(target, path)


def move(old, new):
    (REPO / new).parent.mkdir(parents=True, exist_ok=True)
    os.rename(REPO / old, REPO / new)


def commit(tag):
    if not targets_fixture():
        raise SystemExit("refusing to commit: git is not pointed at the fixture")
    sh("git", "add", "-A")
    sh("git", "-c", "user.name=t", "-c", "user.email=t@example.invalid",
       "commit", "-q", "--allow-empty", "-m", tag)
    sh("git", "tag", "-f", tag)


def reset(tag="base"):
    # These commands destroy work. Run them only where that is the point.
    if not targets_fixture():
        raise SystemExit("refusing to reset: git is not pointed at the fixture")
    sh("git", "checkout", "-q", "--force", "--detach", tag)
    sh("git", "reset", "-q", "--hard", tag)
    sh("git", "clean", "-qfdx")


def setup():
    REPO.mkdir()
    sh("git", "init", "-q", "-b", "main")
    for name in ("check_rules.py", "check_prd_ids.py"):
        write(f"scripts/{name}", (HERE / name).read_text(encoding="utf-8"))
    write("docs/ARCHITECTURE.md", ARCHITECTURE)
    write("docs/PRD.md", PRD)
    write(".github/PULL_REQUEST_TEMPLATE.md", TEMPLATE)
    write(".github/workflows/ci.yml", WORKFLOW)
    write("README.md", "# Fixture\n")
    commit("base")
    (WORK / "bin").mkdir()
    (WORK / "bin" / "git").write_text(FAKE_GIT)
    (WORK / "bin" / "git").chmod(0o755)


def body(a1="Complies — implements #2", a2="Complies",
         a3="N/A — no technology or boundary is chosen",
         a4="N/A — no dependency is added", extra="", heading="## Architecture rules"):
    lines = [f"- AR-00{n}: {a}" for n, a in enumerate((a1, a2, a3, a4), 1) if a is not None]
    return f"## What and why\n\nSomething.\n\n{heading}\n\n" + "\n".join(lines) + f"\n\n## Other\n\n{extra}\n"


GOOD = body()
ANSWERS = GOOD.split("## Architecture rules\n\n")[1].split("\n\n## Other")[0]


def case(name, expect, text=None, base="base", author=None, want=(), absent=(),
         ci=False, args=None, limit=60, isolated=True, script="scripts/check_rules.py",
         event=None, fail_git=None, check=None):
    """Run the check once. expect is the exit code; want/absent are substrings.

    event is the raw text of an event file; fail_git names a git subcommand
    that is made to fail; check is a further test of the whole output.
    """
    env = dict(ENV)
    if ci:
        env["GITHUB_ACTIONS"] = "true"
    if fail_git:
        env.update(FAIL_GIT=fail_git, REAL_GIT=shutil.which("git", path=ENV.get("PATH")),
                   PATH=str(WORK / "bin") + os.pathsep + ENV.get("PATH", ""))
    # -I keeps the script's folder and the environment off the import path.
    command = [sys.executable] + (["-I"] if isolated else []) + [script]
    if args is not None:
        command += args
    elif base:
        command += ["--base", base]
        if author or event is not None:
            path = WORK / "event.json"
            if event is None:
                event = json.dumps({"pull_request": {"body": text, "user": {"login": author}}})
            path.write_bytes(event if isinstance(event, bytes) else event.encode("utf-8"))
            command += ["--event", str(path)]
        else:
            description = WORK / "body.md"
            description.write_bytes((text or "").encode("utf-8"))
            command += ["--body-file", str(description)]
    started = time.time()
    try:
        result = subprocess.run(command, cwd=REPO, capture_output=True, text=True,
                                env=env, timeout=limit, check=False)
        code, out = result.returncode, result.stdout + result.stderr
    except subprocess.TimeoutExpired:
        code, out = "timeout", ""
    want = [want] if isinstance(want, str) else list(want)
    absent = [absent] if isinstance(absent, str) else list(absent)
    ok = (
        code == expect
        and all(item in out for item in want)
        and not any(item in out for item in absent)
        and "Traceback" not in out
        and "internal error" not in out
        and (check is None or bool(check(out)))
    )
    results.append((ok, name))
    if not ok or VERBOSE:
        print(f"{'ok  ' if ok else 'FAIL'} {name} (exit {code}, {time.time() - started:.1f}s)")
    if not ok:
        print(f"     expected exit {expect}, with {want}, without {absent}")
        print("     | " + out.replace("\n", "\n     | "))


def workflow(step):
    write(".github/workflows/x.yml", f"{STEPS}{step}\n")


def one_failure(out):
    return out.count("FAIL: ") == 1


# What the GitHub Actions runner does with a line of output, after TryParseV2
# and TryParse in src/Runner.Common/ActionCommand.cs of actions/runner. A line
# is a command if, after leading spaces, it starts with "::name::", or if it
# has "##[name]" anywhere in it, and the name is one the runner knows.
RUNNER_COMMANDS = {
    "stop-commands", "set-env", "set-output", "save-state", "add-mask", "add-path",
    "add-matcher", "remove-matcher", "debug", "warning", "error", "notice", "group",
    "endgroup", "echo",
}


def runner_command(line):
    """Return (form, name) if the runner would read the line as a command."""
    text = line.lstrip()
    if text.startswith("::") and text.find("::", 2) >= 0:
        name = text[2:text.find("::", 2)].split(" ")[0].lower()
        if name in RUNNER_COMMANDS:
            return "::", name
    start = line.find("##[")
    if start >= 0 and line.find("]", start) >= 0:
        name = line[start + 3:line.find("]", start)].split(" ")[0].lower()
        if name in RUNNER_COMMANDS:
            return "##[", name
    return None


def only_own_commands(out):
    """True if the only commands in the output are the check's annotations.

    Each "FAIL: text" line is followed by "::error::text", each "WARNING:"
    line by "::warning::", and the runner reads no other line as a command.
    """
    lines = re.split(r"\r\n|\r|\n", out)  # where the runner ends a line
    expected = {}
    for number, line in enumerate(lines):
        for label, kind in (("FAIL: ", "error"), ("WARNING: ", "warning")):
            if line.startswith(label):
                expected[number + 1] = f"::{kind}::" + line[len(label):].replace("%", "%25")
    commands = {number: line for number, line in enumerate(lines) if runner_command(line)}
    return bool(expected) and commands == expected


setup()
NO_SECTION = "has no '## Architecture rules' section"

# --- The self-test only ever touches its own fixture --------------------------
decoy = Path(tempfile.mkdtemp(prefix="check_rules_decoy_"))
sh("git", "init", "-q", cwd=decoy)
hostile = dict(os.environ, GIT_DIR=str(decoy / ".git"), GIT_WORK_TREE=str(decoy),
               GIT_INDEX_FILE=str(decoy / ".git" / "index"))
results.append((not targets_fixture(env=hostile),
                "GIT_DIR and GIT_WORK_TREE, passed on, would point git at another repository"))
results.append((targets_fixture(env=fixture_env(hostile)),
                "git in the fixture ignores GIT_DIR and GIT_WORK_TREE set outside it"))
shutil.rmtree(decoy, ignore_errors=True)

# --- The repository on its own ---------------------------------------------
reset(); case("repository checks pass", 0, base=None, want="All rule checks passed")
reset(); case("--body-file without --base is refused", 2, args=["--body-file", "x.md"])
reset(); case("--base without a description is refused", 2, args=["--base", "base"])
reset(); case("unknown base", 1, GOOD, base="nope", want="base commit 'nope' was not found")
reset(); case("missing description file", 1, args=["--base", "base", "--body-file", "nope.md"],
              want="could not read the pull request description")

# --- Answers ----------------------------------------------------------------
reset(); case("good description", 0, GOOD, want="answers 4 active rule(s)")
reset(); case("empty description", 1, "", want=NO_SECTION)
reset(); case("untouched template", 1, TEMPLATE, want="AR-001: the answer must start with")
filled = TEMPLATE
for number, answer in enumerate(ANSWERS.split("\n"), 1):
    filled = filled.replace(f"- AR-00{number}:", answer)
reset(); case("filled-in template", 0, filled)
reset(); case("one rule unanswered", 1, body(a3=None),
              want="AR-003 is an active rule and the description does not answer it")
reset(); case("N/A without a reason", 1, body(a3="N/A"), want="AR-003: 'N/A' needs a reason")
reset(); case("N/A with a one-word reason", 1, body(a3="N/A — none"), want="AR-003: 'N/A' needs a reason")
reset(); case("N/A with a short honest reason", 0, body(a3="N/A — typo fix", a4="N/A: no deps"))
reset(); case("answer that is not one of the three", 1, body(a2="yes"), want="AR-002: the answer must start with")
reset(); case("keyword glued to other text", 1, body(a2="Compliesn't at all"), want="AR-002: the answer must start with")
reset(); case("N/A glued to other text", 1, body(a3="N/Aaaaaaaaaaaa is fine"), want="AR-003: the answer must start with")
reset(); case("duplicate answer", 1, GOOD.replace("- AR-002: Complies", "- AR-002: Complies\n- AR-002: Complies"),
              want="AR-002 is answered more than once")
reset(); case("reason wrapped onto the next line", 0, body(a3="N/A —\n  no technology or boundary is chosen"))
reset(); case("CRLF line endings", 0, GOOD.replace("\n", "\r\n"))
reset(); case("bold IDs, deeper heading, checkboxes", 0,
              body(heading="### Architecture rules").replace("- AR-001:", "- [x] **AR-001**:"))
reset(); case("heading with a trailing colon", 0, body(heading="## Architecture rules:"))
reset(); case("section ends at the next heading", 1,
              "## Architecture rules\n\n- AR-001: Complies #2\n\n## Other\n\n- AR-002: Complies\n",
              want="AR-002 is an active rule")
reset(); case("answers written as a table", 1,
              "## Architecture rules\n\n| AR-001 | Complies |\n", want="has no answer lines")

# --- Words, keywords, and what AR-001 accepts ---------------------------------
reset(); case("a one-letter word is a word", 0, body(a1="Complies — adds C"))
reset(); case("a token such as I/O is a word", 0, body(a3="N/A — no I/O"))
reset(); case("a hyphenated reason is still two words", 0, body(a3="N/A — docs-only"))
for reason in ("n/a", "-", "none.", "N/A"):
    reset(); case(f"N/A with the reason '{reason}'", 1, body(a3=f"N/A — {reason}"),
                  want="AR-003: 'N/A' needs a reason")
reset(); case("keywords in capitals", 0, body(a2="COMPLIES", a3="NOT APPLICABLE — no technology is chosen"))
for rule, answer in (("AR-001", "Compl\u0131es"), ("AR-002", "Complie\u017f"), ("AR-003", "Not appl\u0131cable"),
                     ("AR-004", "Dev\u0131ates"), ("AR-002", "\uff23omplies")):
    reset(); case(f"look-alike letter in a keyword: {answer!a}", 1,
                  body(**{f"a{rule[-1]}": answer}), want=f"{rule}: the answer must start with")
reset(); case("AR-001 citing only a rule ID", 1, body(a1="Complies — AR-002"),
              want="name what the change implements")
reset(); case("AR-001 citing a non-functional requirement", 0, body(a1="Complies — NFR-001"))

# --- Lists and headings as Markdown allows them -------------------------------
numbered = "\n".join(f"{n}. {line[2:]}" for n, line in enumerate(ANSWERS.split("\n"), 1))
reset(); case("answers in a numbered list", 0, GOOD.replace(ANSWERS, numbered), want="answers 4 active rule(s)")
reset(); case("answers in a list numbered with brackets", 0, GOOD.replace(ANSWERS, numbered.replace(". AR", ") AR")))
reset(); case("underlined heading with hyphens", 0, body(heading="Architecture rules\n------------------"))
reset(); case("underlined heading with equals signs", 0, body(heading="Architecture rules\n=================="))
reset(); case("section ends at an underlined heading", 1,
              "## Architecture rules\n\n- AR-001: Complies #2\n\nOther\n-----\n\n" + ANSWERS + "\n",
              want="AR-002 is an active rule")
reset(); case("a rule across the page under the answers is not a heading", 0,
              GOOD.replace("- AR-002: Complies", "- AR-002: Complies\n---"))
reset(); case("hyphens under a blank line are not a heading", 0,
              GOOD.replace("- AR-002: Complies", "- AR-002: Complies\n\nA note.\n\n---\n"))
reset(); edit("docs/ARCHITECTURE.md", "## Rules", "Rules\n-----")
case("underlined heading in the architecture document", 0, base=None, want="5 rule(s)")

# --- Answers a reader cannot see --------------------------------------------
reset(); case("answers inside an HTML comment", 1, f"## Architecture rules\n\n<!--\n{ANSWERS}\n-->\n",
              want="has no answer lines")
reset(); case("section after an unclosed comment", 1, f"Fix typo.\n\n<!--\n## Architecture rules\n\n{ANSWERS}\n",
              want=NO_SECTION)
reset(); case("answers inside a code fence", 1, f"## Architecture rules\n\n```\n{ANSWERS}\n```\n", want="has no answer lines")
reset(); case("answers inside a tilde fence", 1, f"## Architecture rules\n\n~~~\n{ANSWERS}\n~~~\n", want="has no answer lines")
reset(); case("answers inside a long fence with an inner fence line", 1,
              f"## Architecture rules\n\n````\n```\n{ANSWERS}\n```\n````\n", want="has no answer lines")
reset(); case("answers in an indented code block", 1,
              "## Architecture rules\n\n" + "\n".join("    " + line for line in ANSWERS.split("\n")) + "\n",
              want="has no answer lines")
reset(); case("inline triple backticks before the section", 0, "```npm test``` passes locally.\n\n" + GOOD)
reset(); case("comment marker inside inline code", 0,
              "Removed the stray `<!--` marker.\n\n" + GOOD.replace("## Architecture rules\n", "## Architecture rules\n\n<!-- Answer every line. -->\n"))
reset(); case("numbered answers inside an HTML comment", 1, f"## Architecture rules\n\n<!--\n{numbered}\n-->\n",
              want="has no answer lines")
reset(); case("numbered answers inside a code fence", 1, f"## Architecture rules\n\n```\n{numbered}\n```\n",
              want="has no answer lines")
reset(); case("numbered answers in an indented code block", 1,
              "## Architecture rules\n\n" + "\n".join("    " + line for line in numbered.split("\n")) + "\n",
              want="has no answer lines")
reset(); case("underlined heading inside an HTML comment", 1,
              f"<!--\nArchitecture rules\n------------------\n-->\n\n{ANSWERS}\n", want=NO_SECTION)
reset(); case("underlined heading inside a code fence", 1,
              f"```\nArchitecture rules\n------------------\n```\n\n{ANSWERS}\n", want=NO_SECTION)
reset(); case("underlined heading in an indented code block", 1,
              f"Text.\n\n    Architecture rules\n    ------------------\n\n{ANSWERS}\n", want=NO_SECTION)

# --- AR-001 -----------------------------------------------------------------
reset(); case("AR-001 bare Complies", 1, body(a1="Complies"), want="name what the change implements")
reset(); case("AR-001 cites a requirement", 0, body(a1="Complies — FR-001"))
reset(); case("AR-001 cites an issue URL", 0, body(a1="Complies — https://github.com/o/r/issues/7"))
reset(); case("AR-001 cites owner/repo#number", 0, body(a1="Complies: reverts o/r#12"))
reset(); case("AR-001 cites a bare issue number", 0, body(a1="Complies: #12"))
reset(); case("AR-001 with a number that is part of a path", 1, body(a1="Complies: x/#12"),
              want="name what the change implements")
reset(); case("AR-001 states a purpose", 0, body(a1="Complies — fixes typos in the README"))
reset(); case("AR-001 cannot be N/A", 1, body(a1="N/A — fixes a typo in the README"),
              want="applies to every pull request")
reset(); case("AR-001 deviation with a reason warns", 0, body(a1="Deviates — carries two changes the maintainer asked for"),
              want="WARNING: AR-001 is answered 'Deviates'")
reset(); case("AR-001 deviation without a reason", 1, body(a1="Deviates"), want="'Deviates' needs the reason")

# --- Deviations from other rules --------------------------------------------
reset(); case("deviation without an ADR", 1, body(a4="Deviates — because"), want="AR-004: 'Deviates' needs the ADR")
reset(); case("deviation citing a missing ADR", 1, body(a4="Deviates — docs/adr/0009-nope.md"),
              want="docs/adr/0009-nope.md does not exist")
reset(); write("docs/adr/0001-use-python.md", ADR.replace("Accepted", "Proposed"))
case("deviation citing a proposed ADR", 1, body(a4="Deviates — docs/adr/0001-use-python.md"),
     want="must have status Accepted")
reset(); write("docs/adr/0001-use-python.md", ADR)
case("deviation citing an accepted ADR warns", 0, body(a4="Deviates — docs/adr/0001-use-python.md"),
     want="WARNING: AR-004 is answered 'Deviates'")

# --- AR-002: IDs resolve ----------------------------------------------------
reset(); case("unknown requirement in the description", 1, body(extra="Implements FR-999."),
              want="the description refers to FR-999")
reset(); case("unknown rule in the description", 1, body(extra="See AR-099."), want="the description refers to AR-099")
reset(); case("unknown requirement in inline code", 1, body(extra="Implements `FR-999`."), want="refers to FR-999")
reset(); case("example ID inside a code fence", 0, body(extra="```\nFR-999\n```"))
reset(); case("pending rule named in the description", 0, body(extra="AR-005 will apply later."))
reset(); case("lookalikes are not IDs", 0, body(extra="Branch feature/AR-150, board FR-4, and XFR-999."))
reset(); edit("docs/PRD.md", "| NFR-001 | Something |\n", "")
case("description names a requirement the change removes", 0, body(extra="Removes the placeholder NFR-001 row."))
reset(); edit("docs/PRD.md", "| FR-001 | Something |", "| FR-001 | Something |\n\n<!--\n| FR-999 | commented out |\n-->")
case("requirement defined only inside a comment", 1, body(a1="Complies — FR-999"), want="refers to FR-999")
reset(); write("docs/DEPLOY.md", "# Deploy\n\nImplements FR-042 and NFR-001.\n")
case("undefined requirement in docs/", 1, base=None, want="docs/DEPLOY.md refers to FR-042")
reset(); edit("README.md", "# Fixture", "# Fixture\n\nSee AR-055.")
case("undefined rule in the README", 1, base=None, want="README.md refers to AR-055")
reset(); write("docs/research/x/notes.md", "# N\n\nAR-999 and FR-999 were seen elsewhere.\n")
case("the research archive is skipped", 0, base=None)
reset(); write("docs/café.md", "# C\n\nFR-999\n")
case("non-ASCII file name is still read", 1, base=None, want="refers to FR-999")
reset(); write("docs/NOTES.MD", "# N\n\nAR-999\n")
case("upper-case extension is still read", 1, base=None, want="refers to AR-999")
reset(); write("docs/y.md", "# Y\n\n```js``` is how we mark code.\n\nFR-999\n")
case("inline triple backticks do not hide the rest of a file", 1, base=None, want="docs/y.md refers to FR-999")

# --- The PRD check reads Markdown the same way --------------------------------
PRD_CHECK = "scripts/check_prd_ids.py"
reset(); edit("docs/PRD.md", "| FR-001 | Something |",
              "| FR-001 | Something |\n\n<!--\n| FR-001 | an example row |\n-->\n\n~~~markdown\nSee FR-999.\n~~~")
case("PRD check: a comment and a tilde fence are not read", 0, script=PRD_CHECK, args=[],
     want="OK: 2 requirement ID(s)")
case("PRD check: the rules check agrees", 0, base=None)
reset(); edit("docs/PRD.md", "## Non-functional", "<!-- one\ntwo -->\n\n~~~\nx\n~~~\n\nSee FR-777.\n\n## Non-functional")
case("PRD check: line numbers count hidden lines", 1, script=PRD_CHECK, args=[],
     want="line 16: FR-777 is referenced")
reset(); write("bad.md", b"| FR-001 | caf\xe9 |\n")
case("PRD check: a file that is not UTF-8", 1, script=PRD_CHECK, args=["bad.md"], want="is not UTF-8 text")
case("PRD check: a folder instead of a file", 1, script=PRD_CHECK, args=["docs"], want="could not be read")
case("PRD check: a missing file", 1, script=PRD_CHECK, args=["nope.md"], want="not found")
reset(); write("scripts/re.py", "import sys\nprint('OK: hijacked')\nsys.exit(0)\n")
edit("docs/PRD.md", "| FR-001 | Something |", "| FR-1 | Something |")
case("PRD check: with -I a file next to the script cannot replace re", 1, script=PRD_CHECK, args=[],
     want="'FR-1' is not a valid requirement ID", absent="hijacked")

# --- Dependabot -------------------------------------------------------------
reset(); case("Dependabot needs no answers", 0, "Bumps actions/checkout.", author="dependabot[bot]",
              want="section is not required")
reset(); case("another author is not exempt", 1, "Bumps actions/checkout.", author="someone", want=NO_SECTION)
reset(); case("description read from the event file", 0, GOOD, author="someone", want="answers 4 active rule(s)")
reset(); write("package.json", "{}\n")
case("Dependabot is not exempt from the ADR check", 1, "", author="dependabot[bot]", want="adds package.json")
reset(); workflow(f"      - uses: evil/action@{SHA}")
case("Dependabot is not exempt from the new-action check", 1, "", author="dependabot[bot]",
     want="does not name the new action evil/action")
reset(); case("IDs in a Dependabot description are release notes, not checked", 0,
              "Bumps x. Upstream notes: fixes FR-999 and AR-099.", author="dependabot[bot]",
              want="the IDs in the description are not checked")
reset(); case("the same description from another author", 1,
              GOOD + "\nUpstream notes: fixes FR-999 and AR-099.\n", author="someone",
              want=["refers to FR-999", "refers to AR-099"])

# --- The event file ---------------------------------------------------------
STOPPED = "could not read the pull request description"
for name, payload in (
    ("a list at the top", "[]"),
    ("a number for pull_request", '{"pull_request": 17}'),
    ("null for pull_request", '{"pull_request": null}'),
    ("a number for the description", '{"pull_request": {"body": 17}}'),
    ("a list for the description", '{"pull_request": {"body": ["x"]}}'),
    ("text for the user", '{"pull_request": {"body": "x", "user": "dependabot[bot]"}}'),
    ("a list for the login", '{"pull_request": {"body": "x", "user": {"login": ["dependabot[bot]"]}}}'),
    ("a number for the login", '{"pull_request": {"body": "x", "user": {"login": 7}}}'),
    ("not JSON", "{"),
    ("nesting too deep to read", "[" * 200000),
    ("bytes that are not text", b"\xff\xfe\xfd"),
):
    reset(); case(f"event file with {name}", 1, event=payload, want=f"FAIL: {STOPPED}", check=one_failure)
reset(); case("event file with no pull request", 1, event="{}", want=NO_SECTION)
reset(); case("event file with a null description", 1, event='{"pull_request": {"body": null}}', want=NO_SECTION)
reset(); case("event file with no user", 0, event=json.dumps({"pull_request": {"body": GOOD}}))
reset(); case("event file with a null user", 0, event=json.dumps({"pull_request": {"body": GOOD, "user": None}}))
reset(); case("event file with a user without a login", 0,
              event=json.dumps({"pull_request": {"body": GOOD, "user": {"id": 1}}}))

# --- AR-004: actions --------------------------------------------------------
for form in ('- "uses": evil/action@main', "- {uses: evil/action@main}", "- uses : evil/action@main",
             "- uses:\n          evil/action@main", "- uses: [evil/action@main]",
             "- 'uses': evil/action@main", "- [uses: evil/action@main]", "- {name: x, uses: evil/action@main}",
             '- {"name":"x","uses":"evil/action@main"}', "- &step uses: evil/action@main",
             "- !!str uses: evil/action@main", "- ? uses\n        : evil/action@main",
             '- "\\x75ses": evil/action@main', '- "\\u0075ses": evil/action@main',
             "- *key : evil/action@main", "- uses: &ref evil/action@main", "- uses: |\n          evil/action@main",
             f"- {{name: x,\n          uses: evil/action@main,\"id\":x@{SHA}\n        }}",
             f"- {{name: x,\n          uses: ./local,\"uses\":evil/action@main\n        }}"):
    reset(); workflow("      " + form)
    case(f"unreadable uses form: {' '.join(form.split())[:60]}", 1, GOOD, want="in a form this check cannot read")
reset(); write(".github/workflows/x.yml", "on: push\njobs:\n  a:\n    runs-on: ubuntu-24.04\n    steps: [{uses: evil/action@main}]\n")
case("unreadable uses form: all the steps on one line", 1, base=None, want="in a form this check cannot read")
reset(); write(".github/workflows/x.yml", "on: push\njobs: {a: {uses: evil/flows/.github/workflows/x.yml@main}}\n")
case("unreadable uses form: a reusable workflow on one line", 1, base=None, want="in a form this check cannot read")
reset(); write(".github/workflows/x.yml", "on: push\njobs:\n  a:\n    uses: evil/flows/.github/workflows/x.yml@main\n")
case("unpinned reusable workflow", 1, base=None, want="x.yml@main', which is not pinned")
reset(); workflow("      - uses: evil/action@main")
case("unpinned action", 1, body(a4="Complies — adds evil/action"), want="uses 'evil/action@main', which is not pinned")
reset(); workflow("      - uses: ./.github/actions/local\n      - uses: docker://alpine:3.20")
case("local action is fine, image tag is not a pin", 1, body(a4="Complies — adds alpine"),
     want="uses 'docker://alpine:3.20', which is not pinned", absent="actions/local")
reset(); write(".github/actions/setup/action.yml", "runs:\n  using: composite\n  steps:\n    - uses: evil/action@main\n")
case("unpinned action inside a composite action", 1, body(a4="Complies — adds evil/action"), want="which is not pinned")
reset(); workflow(f"      - uses: Some-Org/New-Action/sub@{SHA} # v1")
case("new pinned action that the description does not name", 1, body(a4="Complies — adds an action"),
     want="does not name the new action some-org/new-action")
case("new action named only in a comment", 1, body(a4="Complies — adds an action", extra="<!-- some-org/new-action -->"),
     want="does not name the new action")
case("new action named only inside a longer name", 1,
     body(a4="Complies — adds an action", extra="See https://example.com/notsome-org/new-actionable"),
     want="does not name the new action")
case("new action named, but AR-004 answered N/A", 1, body(extra="Adds Some-Org/New-Action."),
     want="AR-004 is answered 'N/A', but this pull request adds some-org/new-action")
case("new action named and declared", 0, body(a4="Complies — adds Some-Org/New-Action (MIT), pinned, needed for X"),
     want="names 1 new action(s)")

# --- AR-004: text that only looks like a 'uses' key ---------------------------
reset(); workflow(
    f"      - uses: actions/checkout@{SHA}\n"
    "      - name: Explain\n"
    "        run: |\n"
    "          echo 'Example uses: checkout'\n"
    "          cat <<EOF\n"
    "          uses: an/example@v1\n"
    "          - uses: another/example@v1\n"
    "          steps: [{uses: third/example@v1}, {name: x, uses: fourth/example@v1}]\n"
    "          EOF\n"
    "      - name: Folded\n"
    "        run: >-\n"
    "          echo\n"
    "            uses: nothing\n"
    "      - run: echo done")
case("text in a run block is not a uses key", 0, base=None, want="2 action reference(s)")
reset(); write("tools/action.yml",
               "name: x\ndescription: 'uses: is an example'\ninputs:\n  mode:\n    description: \"uses: is an example\"\n"
               "runs:\n  using: composite\n  steps:\n    - run: echo ok\n      shell: bash\n")
case("a description that quotes 'uses:' is not a uses key", 0, base=None)
reset(); workflow("      # - uses: old/action@v1, uses: {uses: x}\n      - run: echo ok  # this step uses: nothing")
case("comments are not uses keys", 0, base=None)
# The lines under "key: |" are skipped only where they really are text.
for name, step in (
    ("a key at the column of the key above it", "      - run: |\n        uses: evil/action@main"),
    ("a key after the text has ended", "      - run: |\n          echo hi\n        uses: evil/action@main"),
    ("the next step after the text", "      - run: |\n          echo hi\n      - uses: evil/action@main"),
    ("a text marker inside a double-quoted value", "      - name: \"x\n   run: |\n     y\"\n        uses: evil/action@main"),
    ("a text marker inside a single-quoted value", "      - name: 'it''s\n   run: |\n     y'\n        uses: evil/action@main"),
    ("a text marker after an escaped quote", "      - name: \"x \\\"\n   run: |\n     y\"\n        uses: evil/action@main"),
    ("a text marker after an unusual line break", "      - name: x # c\u2028  run: |\n        uses: evil/action@main"),
    ("a text marker after a next-line character", "      - name: x # c\u0085  run: |\n        uses: evil/action@main"),
):
    reset(); workflow(step)
    case(f"a run block cannot hide {name}", 1, base=None, want="uses 'evil/action@main', which is not pinned")
reset(); workflow("      - {name: \"x\n      # y\", uses: evil/action@main}")
case("a comment line inside a quoted value cannot hide a key", 1, base=None, want="in a form this check cannot read")

# --- AR-004: which dependency is new ------------------------------------------
reset(); workflow(f"      - uses: docker://registry.example:5000/docs/lint@sha256:{DIGEST}"); commit("with-image")
workflow(f"      - uses: docker://registry.example:5000/docs/lint@sha256:{DIGEST}\n"
         f"      - uses: docker://registry.example:5000/tools/render:1.2@sha256:{DIGEST}")
case("a second image from the same registry is new", 1, body(a4="Complies — adds a renderer"), base="with-image",
     want="does not name the new action docker://registry.example:5000/tools/render.")
case("naming another image from that registry is not enough", 1, base="with-image",
     text=body(a4="Complies — like registry.example:5000/docs/lint, and registry.example:5000/tools/render-old"),
     want="does not name the new action docker://registry.example:5000/tools/render.")
case("a new image named by its full repository", 0, base="with-image", want="names 1 new action(s)",
     text=body(a4="Complies — adds docker://registry.example:5000/tools/render (MIT), pinned by digest"))
reset("with-image"); workflow(f"      - uses: docker://registry.example:5000/docs/lint:2.0@sha256:{'c' * 64}")
case("a new tag and digest of the same image is not new", 0, GOOD, base="with-image")
reset(); workflow(f"      - uses: docs-tools/ci/lint@{SHA}"); commit("with-lint")
workflow(f"      - uses: docs-tools/ci/lint@{SHA}\n      - uses: docs-tools/ci/render@{SHA}")
case("a second action from the same repository is new", 1, body(a4="Complies — adds a renderer"), base="with-lint",
     want="does not name the new action docs-tools/ci/render. Name docs-tools/ci with")
case("a new action named by its owner and repository", 0, base="with-lint", want="names 1 new action(s)",
     text=body(a4="Complies — adds docs-tools/ci (MIT), pinned, renders the docs"))
reset(); write("docs/NEW.md", "# New\n"); commit("left-early")
reset(); edit(".github/workflows/ci.yml", f"      - uses: actions/checkout@{SHA} # v1\n", ""); commit("base-dropped-action")
reset("left-early")
case("an action the base dropped after the branch left it is not new", 0, GOOD, base="base-dropped-action",
     absent="new action")

# --- AR-003: decision records -----------------------------------------------
reset(); write("package.json", "{}\n")
case("first manifest without an ADR", 1, body(a3="Complies"), want="adds package.json, but adds or changes no ADR")
case("first manifest cannot be waved through with N/A", 1, GOOD, want="adds package.json")
write("docs/adr/0001-use-node.md", ADR)
case("first manifest with an ADR", 0, body(a3="Complies — docs/adr/0001-use-node.md"), want="the change comes with an ADR")
reset(); write("café/package.json", "{}\n")
case("manifest under a non-ASCII folder", 1, body(a3="Complies"), want="package.json, but adds or changes no ADR")
reset(); write("services/api/requirements-dev.txt", "x\n")
case("nested requirements file", 1, body(a3="Complies"), want="requirements-dev.txt")
for name in ("compose.yaml", "docker-compose.yml", "deploy/docker-compose.prod.yml", "compose.override.yaml"):
    reset(); write(name, "services: {}\n")
    case(f"compose file: {name}", 1, body(a3="Complies"), want=f"adds {name}, but adds or changes no ADR")
for name in ("examples/composed-music.yaml", "docs/composer.yml", "compose.yaml.txt"):
    reset(); write(name, "title: x\n")
    case(f"not a compose file: {name}", 0, body(a3="Complies"))
reset(); write("go.mod", "module x\n"); write("docs/adr/drafts/anything.md", "lol\n")
case("a stray file under docs/adr/ is not an ADR", 1, body(a3="Complies"),
     want=["adds go.mod, but adds or changes no ADR", "does not belong in docs/adr/"])
reset(); write("package.json", "{}\n"); write("docs/adr/0001-use-node.md", ADR); commit("with-node")
write("tools/package.json", "{}\n")
case("second manifest of a kind already present", 0, body(a3="Complies"), base="with-node")
reset("with-node"); (REPO / "docs/adr/0001-use-node.md").unlink(); write("go.mod", "module x\n")
case("deleting an ADR does not count as adding one", 1, body(a3="Complies"), base="with-node",
     want="adds go.mod, but adds or changes no ADR")
reset(); edit("docs/ARCHITECTURE.md", "## Technology choices\n\n_TBD_", "## Technology choices\n\nPython.")
case("Technology choices changed without an ADR", 1, body(a3="Complies"), want="changes the 'Technology choices' section")
case("the same with N/A is a warning", 0, GOOD, want="WARNING: AR-003: this pull request changes the 'Technology choices'")
case("warnings are annotated in CI", 0, GOOD, want="::warning::AR-003", ci=True)
reset(); edit("docs/ARCHITECTURE.md", "## Data\n\n_TBD_", "## Data\n\nNone yet.")
case("another section may change freely", 0, body(a3="Complies"))

# --- AR-003: ADR files ------------------------------------------------------
reset(); write("docs/adr/first-decision.md", ADR)
case("ADR with a bad name", 1, base=None, want="does not belong in docs/adr/")
reset(); write("docs/adr/0001-a.md", ADR.replace("Status: Accepted", "Status: Done"))
case("ADR with an unknown status", 1, base=None, want="needs a line 'Status: '")
reset(); write("docs/adr/0001-a.md", ADR.replace("Status: Accepted\n", ""))
case("ADR without a status", 1, base=None, want="needs a line 'Status: '")
reset(); write("docs/adr/0001-a.md", ADR.replace("Status: Accepted", "Status: Superseded by 0002"))
case("ADR superseded by one that does not exist", 1, base=None, want="superseded by 0002, which does not exist")
write("docs/adr/0002-b.md", ADR)
case("ADR superseded by one that exists", 0, base=None, want="2 ADR(s)")
reset(); write("docs/adr/0001-a.md", ADR); write("docs/adr/0001-b.md", ADR)
case("two ADRs with one number", 1, base=None, want="reuses number 0001")
reset(); write("docs/adr/0001-a.md", ADR.replace("Status: Accepted", "Status quo was fine.\n\n**Status:** Deprecated"))
case("bold status after a prose line starting with Status", 0, base=None)
reset(); write("docs/adr/0001-a.md", ADR.replace("Status: Accepted", "Status:\t Accepted \t"))
case("status with tabs and spaces around it", 0, base=None)
reset(); (REPO / "docs/adr").mkdir(parents=True); os.symlink("../../README.md", REPO / "docs/adr/0001-link.md")
case("ADR that is a symbolic link", 1, base=None, want="does not belong in docs/adr/")

# --- Symbolic links are not followed ------------------------------------------
LINKED = "is a symbolic link, or is inside one"
reset(); move("docs/ARCHITECTURE.md", "rules.md"); link("../rules.md", "docs/ARCHITECTURE.md")
case("the architecture document is a symbolic link", 1, base=None, want=f"docs/ARCHITECTURE.md {LINKED}")
reset(); move("docs/PRD.md", "prd.md"); link("../prd.md", "docs/PRD.md")
case("the PRD is a symbolic link", 1, base=None, want=f"docs/PRD.md {LINKED}")
reset(); move(".github/PULL_REQUEST_TEMPLATE.md", "template.md"); link("../template.md", ".github/PULL_REQUEST_TEMPLATE.md")
case("the template is a symbolic link", 1, base=None, want=f".github/PULL_REQUEST_TEMPLATE.md {LINKED}")
reset(); move(".github/workflows/ci.yml", "ci.txt"); link("../../ci.txt", ".github/workflows/ci.yml")
case("a workflow is a symbolic link", 1, base=None, want=f"AR-004: .github/workflows/ci.yml {LINKED}")
reset(); (WORK / "outside.yml").write_text(WORKFLOW); link(str(WORK / "outside.yml"), ".github/workflows/out.yml")
case("a workflow links to a file outside the repository", 1, base=None, want=f".github/workflows/out.yml {LINKED}")
reset(); link("nowhere.yml", ".github/workflows/gone.yml")
case("a workflow is a link to nothing", 1, base=None, want=f".github/workflows/gone.yml {LINKED}")
reset(); link("../../README.md", "tools/setup/action.yml")
case("an action definition is a symbolic link", 1, base=None, want=f"tools/setup/action.yml {LINKED}")
reset(); move(".github/workflows", "ci"); link("../ci", ".github/workflows")
case("the workflow folder is a symbolic link", 1, base=None, want=f"AR-004: .github/workflows {LINKED}")
reset(); write("decisions/0001-use-python.md", ADR); link("../decisions", "docs/adr")
case("the ADR folder is a symbolic link", 1, base=None, want=f"AR-003: docs/adr {LINKED}", absent="1 ADR(s)")
reset(); link("nowhere", "docs/adr")
case("the ADR folder is a link to nothing", 1, base=None, want=f"AR-003: docs/adr {LINKED}")
reset(); (REPO / "docs/adr").mkdir(parents=True); write("decisions/0001-a.md", ADR); link("../../decisions", "docs/adr/more")
case("a linked folder inside the ADR folder", 1, base=None, want="docs/adr/more is a symbolic link and does not belong")
reset(); move("docs", "documents"); link("documents", "docs")
case("a folder on the way to a document is a symbolic link", 1, base=None, want=f"docs/ARCHITECTURE.md {LINKED}")
reset(); write("docs/adr/0001-real.md", ADR); link("0001-real.md", "docs/adr/0002-link.md")
case("a deviation cannot cite a linked ADR", 1, body(a4="Deviates — docs/adr/0002-link.md"),
     want="AR-004: docs/adr/0002-link.md does not exist")
reset(); write("notes.txt", "FR-999 and AR-999\n"); link("../notes.txt", "docs/alias.md")
case("a Markdown file that is a symbolic link is skipped", 0, base=None)
reset(); write(".agents/skills/x/SKILL.md", "# Skill\n\nSee AR-001.\n"); link("../.agents/skills", ".claude/skills")
case("a linked folder of Markdown files is fine", 0, base=None)
edit(".agents/skills/x/SKILL.md", "AR-001", "AR-999")
case("a file under a linked folder is read once, by its own name", 1, base=None,
     want=".agents/skills/x/SKILL.md refers to AR-999", absent=".claude/skills/x")

# --- File names as git reports them -------------------------------------------
reset(); write(".github/workflows/a\rb.yml", f"{STEPS}      - uses: evil/action@main\n")
case("a workflow with a carriage return in its name is read", 1, base=None, want="which is not pinned")
reset()
try:
    with open(os.fsencode(REPO) + b"/docs/caf\xe9.md", "wb") as handle:
        handle.write(b"# C\n\nFR-999\n")
except OSError:
    print("note: this file system refuses names that are not UTF-8; one case skipped")
else:
    case("a file whose name is not UTF-8 is read", 1, base=None, want="refers to FR-999")

# --- The rules table and the template ---------------------------------------
reset(); edit("docs/ARCHITECTURE.md", "| AR-004 | Dependencies", "| AR-4 | Dependencies")
case("malformed rule ID", 1, base=None, want="'AR-4' is not a valid rule ID")
reset(); edit("docs/ARCHITECTURE.md", "### AR-005 Direction", "### Direction")
case("rule without its heading", 1, base=None, want="AR-005 is in the rules table but has no")
reset(); edit("docs/ARCHITECTURE.md", "| Pending: activated later |", "| Maybe |")
case("unknown rule status", 1, base=None, want="AR-005 has no status of Active, Pending, or Retired")
case("a rule with an unknown status is not reported as deleted", 1, GOOD,
     want="AR-005 has no status", absent="deletes AR-005")
reset(); edit("docs/ARCHITECTURE.md", "| Pending: activated later |", "| Active |")
case("activated rule missing from the template", 1, base=None, want="no '- AR-005:' line for an active rule")
reset(); edit(".github/PULL_REQUEST_TEMPLATE.md", "- AR-004:\n", "- AR-004:\n- AR-005:\n")
case("template lists a pending rule", 1, base=None, want="lists AR-005, which is not an active rule")
reset(); edit(".github/PULL_REQUEST_TEMPLATE.md", "- AR-002:\n", "- AR-002:\n- AR-002:\n")
case("template lists a rule twice", 1, base=None, want="lists AR-002 more than once",
     absent="lists every active rule")
reset(); edit("docs/ARCHITECTURE.md", "## Rules", "## Regulations")
case("no Rules section", 1, base=None, want="there is no '## Rules' section")

# --- A pull request cannot drop a rule ---------------------------------------
DELETES = "this pull request deletes AR-004"
RETIRE = "set its status to Retired instead"
reset()
edit("docs/ARCHITECTURE.md", "| AR-004 | Dependencies | Active |\n", "")
edit("docs/ARCHITECTURE.md", "### AR-004 Dependencies\n\n", "")
edit(".github/PULL_REQUEST_TEMPLATE.md", "- AR-004:\n", "")
case("dropped rule: the repository is consistent", 0, base=None)
case("dropped rule: the pull request fails, and the base still requires an answer", 1, body(a4=None),
     want=[DELETES, RETIRE, "AR-004 is an active rule and the description does not answer it"])
case("dropped rule: answering it does not make up for deleting it", 1, GOOD, want=[DELETES, RETIRE],
     check=one_failure)
reset()
edit("docs/ARCHITECTURE.md", "| AR-005 | Direction | Pending: activated later |\n", "")
edit("docs/ARCHITECTURE.md", "### AR-005 Direction\n\n", "")
case("dropped rule: a pending rule cannot be deleted either", 1, GOOD,
     want=["this pull request deletes AR-005", RETIRE])
reset()
edit("docs/ARCHITECTURE.md", "| AR-004 | Dependencies | Active |", "| AR-004 | Dependencies | Retired |")
edit(".github/PULL_REQUEST_TEMPLATE.md", "- AR-004:\n", "")
case("retired rule: the repository is consistent", 0, base=None, want="1 retired")
case("retiring pull request still answers the rule", 1, body(a4=None), want="AR-004 is an active rule", absent="deletes")
case("retiring pull request that answers the rule passes", 0, GOOD, absent="deletes")
commit("retired")
case("after retirement the rule is not answered", 0, body(a4=None), base="retired", want="answers 3 active rule(s)")
reset(); write("docs/NEW.md", "# New\n"); commit("left-before-rule")
reset(); edit("docs/ARCHITECTURE.md", "| AR-005 |", "| AR-006 | Mechanisms | Pending: later |\n| AR-005 |")
edit("docs/ARCHITECTURE.md", "### AR-005 Direction", "### AR-006 Mechanisms\n\n### AR-005 Direction"); commit("base-added-rule")
reset("left-before-rule")
case("a rule the base added after the branch left it is not deleted", 0, GOOD, base="base-added-rule", absent="deletes")

# --- A git command that fails is not an empty change --------------------------
for command in ("merge-base", "diff", "ls-files", "ls-tree", "cat-file"):
    reset(); case(f"git {command} fails", 1, GOOD, fail_git=command, check=one_failure,
                  want=[f"FAIL: 'git {command}", "failed with exit code 128: fatal: simulated failure"])
reset(); case("git ls-files fails with no pull request to check", 0, base=None, fail_git="ls-files")
reset(); sh("git", "checkout", "-q", "--orphan", "unrelated"); sh("git", "rm", "-rqf", ".")
write("x.md", "# X\n"); commit("unrelated-base")
reset(); case("a base that shares no history", 1, GOOD, base="unrelated-base", check=one_failure,
              want=["FAIL: 'git merge-base", "must share history"])

# --- The check protects itself -----------------------------------------------
reset(); write("scripts/argparse.py", "import sys\nprint('All rule checks passed.')\nsys.exit(0)\n")
case("a file next to the script cannot replace argparse", 1, "", want=NO_SECTION, isolated=False)
case("nor can it when the script is run with -I", 1, "", want=NO_SECTION)
case("the check leaves no bytecode behind", 0, base=None)
results.append((not (REPO / "scripts/__pycache__").exists(), "no scripts/__pycache__ after a run"))
reset(); edit("scripts/check_prd_ids.py", "#!/usr/bin/env python3", "#!/usr/bin/env python3\n# changed")
case("changing a script is pointed out", 0, GOOD, want="WARNING: This pull request changes what enforces the rules")
reset(); write("docs/adr/x\n::error::pwn.md", ADR)
case("a newline in a file name cannot start a workflow command", 1, base=None, ci=True, absent="\n::error::pwn")
reset()
for name in ("x\n::error::one.md", "x\r::warning::two.md", "##[error]three.md", "##[add-mask]four.md",
             "x ##[stop-commands]five.md", "###[[set-output name=a;]six.md", "%0A::error::seven.md", "::notice::eight.md"):
    write(f"docs/adr/{name}", ADR)
write("docs/##[warning]nine.md", "# N\n\nFR-999 and AR-999\n")
case("no text from a pull request is read by the runner as a command", 1, GOOD, ci=True, check=only_own_commands,
     want=["## [error]three.md", "## [warning]nine.md"], absent="##[")
workflows = HERE.parent / ".github" / "workflows"
if workflows.is_dir():
    runs = [line for path in sorted(workflows.glob("*.yml"))
            for line in path.read_text(encoding="utf-8").splitlines() if re.search(r"\bscripts/\w+\.py\b", line)
            and "python" in line]
    results.append((len(runs) >= 4 and all(re.search(r"\bpython3 -I scripts/", line) for line in runs),
                    "every workflow step runs the scripts with python3 -I"))
reset(); write("docs/latin1.md", "# caf\xe9 FR-999\n".encode("latin-1"))
case("a file that is not UTF-8 is still read", 1, base=None, want="docs/latin1.md refers to FR-999")
reset(); case("a pathological heading line does not hang", 1, "# x" + " " * 60000 + "y\n" + "<!--" * 15000,
              want=NO_SECTION, limit=20)
reset(); case("a long run of dots before an issue number does not hang", 0,
              body(a1="Complies — " + "." * 200000 + " see #12"), limit=20)
reset(); case("a long run of name characters with no issue number does not hang", 1,
              body(a1="Complies " + "a-." * 70000 + "/"), want="name what the change implements", limit=20)
reset(); write("docs/adr/0001-a.md", ADR.replace("Status: Accepted", "Status: Accepted" + " \t" * 100000 + "x"))
case("a long run of spaces in an ADR status does not hang", 1, base=None, want="needs a line 'Status: '", limit=20)
reset(); workflow("      - run: echo " + "{uses, &a ,\"x\\\"" * 20000 + "\n      - name: " + "'" * 100000)
case("a pathological workflow line does not hang", 0, base=None, limit=20)

# --- As CI runs it: a shallow clone of a merge commit ------------------------
reset(); write("docs/NEW.md", "# New\n"); write("package.json", "{}\n"); commit("change")
sh("git", "checkout", "-q", "--detach", "base")
write("OTHER.md", "# Other\n"); write("go.mod", "module x\n"); commit("base-moved")
sh("git", "-c", "user.name=t", "-c", "user.email=t@example.invalid", "merge", "-q", "--no-ff", "-m", "merge", "change")
sh("git", "tag", "-f", "merged")
shallow = WORK / "shallow"
sh("git", "clone", "-q", "--depth", "2", "--branch", "merged", REPO.as_uri(), str(shallow), cwd=WORK)
REPO = shallow
# The pull request added package.json; go.mod came from the base branch. Only
# a diff measured from the base tells them apart.
case("depth-2 clone of a merge commit, base HEAD^1", 1, body(a3="Complies"), base="HEAD^1",
     want=["answers 4 active rule(s)", "adds package.json, but adds or changes no ADR"], absent="go.mod",
     check=one_failure)
case("the same with an empty description", 1, "", base="HEAD^1", want=[NO_SECTION, "adds package.json"])
write("docs/adr/0001-use-node.md", ADR)
case("the same with an ADR in the working tree", 0, body(a3="Complies"), base="HEAD^1",
     want="the change comes with an ADR (docs/adr/0001-use-node.md)")

failed = [name for ok, name in results if not ok]
print(f"{len(results) - len(failed)}/{len(results)} cases behaved as expected")
for name in failed:
    print(f"  FAILED: {name}")
shutil.rmtree(WORK, ignore_errors=True)
sys.exit(1 if failed else 0)
