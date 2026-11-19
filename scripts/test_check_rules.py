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
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
VERBOSE = "-v" in sys.argv[1:]
SHA = "a" * 40
ENV = {
    key: value for key, value in os.environ.items()
    if key not in ("GITHUB_ACTIONS", "PYTHONPATH", "PYTHONDONTWRITEBYTECODE")
}
ENV.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_SYSTEM=os.devnull)

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

WORKFLOW = f"""on: push
jobs:
  check:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@{SHA} # v1
      - run: echo ok
"""

ADR = "# 0001. Use Python\n\nStatus: Accepted\n\n## Context\n\n## Decision\n"

WORK = Path(tempfile.mkdtemp(prefix="check_rules_test_"))
REPO = WORK / "repo"
results = []


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


def commit(tag):
    sh("git", "add", "-A")
    sh("git", "-c", "user.name=t", "-c", "user.email=t@example.invalid",
       "commit", "-q", "--allow-empty", "-m", tag)
    sh("git", "tag", "-f", tag)


def reset(tag="base"):
    sh("git", "checkout", "-q", "--detach", tag)
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


def body(a1="Complies — implements #2", a2="Complies",
         a3="N/A — no technology or boundary is chosen",
         a4="N/A — no dependency is added", extra="", heading="## Architecture rules"):
    lines = [f"- AR-00{n}: {a}" for n, a in enumerate((a1, a2, a3, a4), 1) if a is not None]
    return f"## What and why\n\nSomething.\n\n{heading}\n\n" + "\n".join(lines) + f"\n\n## Other\n\n{extra}\n"


GOOD = body()
ANSWERS = GOOD.split("## Architecture rules\n\n")[1].split("\n\n## Other")[0]


def case(name, expect, text=None, base="base", author=None, want=(), absent=(),
         ci=False, args=None, limit=60):
    """Run the check once. expect is the exit code; want/absent are substrings."""
    env = dict(ENV)
    if ci:
        env["GITHUB_ACTIONS"] = "true"
    command = [sys.executable, "scripts/check_rules.py"]
    if args is not None:
        command += args
    elif base:
        command += ["--base", base]
        if author:
            event = WORK / "event.json"
            event.write_text(json.dumps(
                {"pull_request": {"body": text, "user": {"login": author}}}))
            command += ["--event", str(event)]
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
    )
    results.append((ok, name))
    if not ok or VERBOSE:
        print(f"{'ok  ' if ok else 'FAIL'} {name} (exit {code}, {time.time() - started:.1f}s)")
    if not ok:
        print(f"     expected exit {expect}, with {want}, without {absent}")
        print("     " + out.replace("\n", "\n     "))


def workflow(step):
    write(".github/workflows/x.yml",
          f"on: push\njobs:\n  a:\n    runs-on: ubuntu-24.04\n    steps:\n{step}\n")


setup()
NO_SECTION = "has no '## Architecture rules' section"

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

# --- AR-001 -----------------------------------------------------------------
reset(); case("AR-001 bare Complies", 1, body(a1="Complies"), want="name what the change implements")
reset(); case("AR-001 cites a requirement", 0, body(a1="Complies — FR-001"))
reset(); case("AR-001 cites an issue URL", 0, body(a1="Complies — https://github.com/o/r/issues/7"))
reset(); case("AR-001 cites owner/repo#number", 0, body(a1="Complies: reverts o/r#12"))
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

# --- AR-004: actions --------------------------------------------------------
for form in ('- "uses": evil/action@main', "- {uses: evil/action@main}", "- uses : evil/action@main",
             "- uses:\n          evil/action@main", "- uses: [evil/action@main]"):
    reset(); workflow("      " + form)
    case(f"unreadable uses form: {form.splitlines()[0]}", 1, GOOD, want="in a form this check cannot read")
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
reset(); (REPO / "docs/adr").mkdir(parents=True); os.symlink("../../README.md", REPO / "docs/adr/0001-link.md")
case("ADR that is a symbolic link", 1, base=None, want="does not belong in docs/adr/")

# --- The rules table and the template ---------------------------------------
reset(); edit("docs/ARCHITECTURE.md", "| AR-004 | Dependencies", "| AR-4 | Dependencies")
case("malformed rule ID", 1, base=None, want="'AR-4' is not a valid rule ID")
reset(); edit("docs/ARCHITECTURE.md", "### AR-005 Direction", "### Direction")
case("rule without its heading", 1, base=None, want="AR-005 is in the rules table but has no")
reset(); edit("docs/ARCHITECTURE.md", "| Pending: activated later |", "| Maybe |")
case("unknown rule status", 1, base=None, want="AR-005 has no status of Active, Pending, or Retired")
reset(); edit("docs/ARCHITECTURE.md", "| Pending: activated later |", "| Active |")
case("activated rule missing from the template", 1, base=None, want="no '- AR-005:' line for an active rule")
reset(); edit(".github/PULL_REQUEST_TEMPLATE.md", "- AR-004:\n", "- AR-004:\n- AR-005:\n")
case("template lists a pending rule", 1, base=None, want="lists AR-005, which is not an active rule")
reset(); edit("docs/ARCHITECTURE.md", "## Rules", "## Regulations")
case("no Rules section", 1, base=None, want="there is no '## Rules' section")

# --- A pull request cannot drop a rule ---------------------------------------
reset()
edit("docs/ARCHITECTURE.md", "| AR-004 | Dependencies | Active |\n", "")
edit("docs/ARCHITECTURE.md", "### AR-004 Dependencies\n\n", "")
edit(".github/PULL_REQUEST_TEMPLATE.md", "- AR-004:\n", "")
case("dropped rule: the repository is consistent", 0, base=None)
case("dropped rule: the base still requires an answer", 1, body(a4=None),
     want="AR-004 is an active rule and the description does not answer it")
case("dropped rule: answering it passes", 0, GOOD)
reset()
edit("docs/ARCHITECTURE.md", "| AR-004 | Dependencies | Active |", "| AR-004 | Dependencies | Retired |")
edit(".github/PULL_REQUEST_TEMPLATE.md", "- AR-004:\n", "")
case("retired rule: the repository is consistent", 0, base=None, want="1 retired")
case("retiring pull request still answers the rule", 1, body(a4=None), want="AR-004 is an active rule")
commit("retired")
case("after retirement the rule is not answered", 0, body(a4=None), base="retired", want="answers 3 active rule(s)")

# --- The check protects itself -----------------------------------------------
reset(); write("scripts/argparse.py", "import sys\nprint('All rule checks passed.')\nsys.exit(0)\n")
case("a file next to the script cannot replace argparse", 1, "", want=NO_SECTION)
case("the check leaves no bytecode behind", 0, base=None)
results.append((not (REPO / "scripts/__pycache__").exists(), "no scripts/__pycache__ after a run"))
reset(); edit("scripts/check_prd_ids.py", "#!/usr/bin/env python3", "#!/usr/bin/env python3\n# changed")
case("changing a script is pointed out", 0, GOOD, want="WARNING: This pull request changes what enforces the rules")
reset(); write("docs/adr/x\n::error::pwn.md", ADR)
case("a newline in a file name cannot start a workflow command", 1, base=None, ci=True, absent="\n::error::pwn")
reset(); write("docs/latin1.md", "# caf\xe9 FR-999\n".encode("latin-1"))
case("a file that is not UTF-8 is still read", 1, base=None, want="docs/latin1.md refers to FR-999")
reset(); case("a pathological heading line does not hang", 1, "# x" + " " * 60000 + "y\n" + "<!--" * 15000,
              want=NO_SECTION, limit=20)

# --- As CI runs it: a shallow clone of a merge commit ------------------------
reset(); write("docs/NEW.md", "# New\n"); commit("change")
sh("git", "checkout", "-q", "--detach", "base")
write("OTHER.md", "# Other\n"); commit("base-moved")
sh("git", "-c", "user.name=t", "-c", "user.email=t@example.invalid", "merge", "-q", "--no-ff", "-m", "merge", "change")
sh("git", "tag", "-f", "merged")
shallow = WORK / "shallow"
sh("git", "clone", "-q", "--depth", "2", "--branch", "merged", REPO.as_uri(), str(shallow), cwd=WORK)
REPO = shallow
case("depth-2 clone of a merge commit, base HEAD^1", 0, GOOD, base="HEAD^1", want="answers 4 active rule(s)")
case("the same with an empty description", 1, "", base="HEAD^1", want=NO_SECTION)

failed = [name for ok, name in results if not ok]
print(f"{len(results) - len(failed)}/{len(results)} cases behaved as expected")
for name in failed:
    print(f"  FAILED: {name}")
shutil.rmtree(WORK, ignore_errors=True)
sys.exit(1 if failed else 0)
