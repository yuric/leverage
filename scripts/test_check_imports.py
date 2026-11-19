#!/usr/bin/env python3
"""Self-test for check_imports.py.

Builds a small throwaway repository with the same layout as this one, then
runs check_imports.py against planted good and bad imports and compares the
exit code and the messages. Each case is something the check must accept,
must reject, or once got wrong.

Usage: python3 scripts/test_check_imports.py [-v]
Standard library and git only; exits 0 when every case behaves as expected.
"""

import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
VERBOSE = "-v" in sys.argv[1:]

# The same isolation as test_check_rules.py: no GIT_* variable from the caller
# can point the fixture's git commands at another repository.
ENV = {
    key: value for key, value in os.environ.items()
    if not key.startswith("GIT_")
    and key not in ("GITHUB_ACTIONS", "PYTHONPATH", "PYTHONDONTWRITEBYTECODE")
}
ENV.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_SYSTEM=os.devnull)

DIRECTIONS = """| Code unit | Folder | May import |
|---|---|---|
| `Kit` | `mac/Sources/Kit/` | nothing |
| `Helper` | `mac/Sources/Helper/` | `Kit` |
| `App` | `mac/Sources/App/` | `Kit` |
| `KitTests` | `mac/Tests/KitTests/` | `Kit` |
| `api` | `api/` | nothing |
"""

ARCHITECTURE = f"""# Architecture

## Rules

Nothing here.

## Components

The parts.

### Allowed dependency directions

Code imports only along these directions.

{DIRECTIONS}
## Data

_TBD_
"""

FILES = {
    "mac/Package.swift": "// swift-tools-version: 6.2\nimport PackageDescription\n",
    "mac/Sources/Kit/Client.swift": "import Foundation\n\npublic struct Client {}\n",
    "mac/Sources/Helper/main.swift": "import Foundation\nimport Kit\n\nprint(\"hi\")\n",
    "mac/Sources/App/App.swift": "import Kit\nimport SwiftUI\n\n@main struct App {}\n",
    "mac/Tests/KitTests/ClientTests.swift": "import Foundation\n@testable import Kit\nimport Testing\n",
    "api/config/application.rb": "require_relative \"boot\"\nrequire \"rails\"\n",
    "api/config/boot.rb": "require \"bundler/setup\"\n",
    "api/bin/rails": "#!/usr/bin/env ruby\nrequire_relative \"../config/boot\"\n",
    "api/Gemfile": "source \"https://rubygems.org\"\n",
    "scripts/tool.py": "import os\n",
    ".gitignore": ".build/\n",
}

WORK = Path(tempfile.mkdtemp(prefix="check_imports_test_"))
REPO = WORK / "repo"
results = []


def sh(*args, cwd=None):
    result = subprocess.run(args, cwd=cwd or REPO, capture_output=True, text=True, env=ENV, check=False)
    if result.returncode != 0:
        raise SystemExit(f"{args} failed:\n{result.stdout}\n{result.stderr}")
    return result


def targets_fixture():
    """True if git, run in the fixture, acts on the fixture and nothing else."""
    result = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"], cwd=REPO, capture_output=True, text=True,
        env=ENV, check=False,
    )
    home = Path(os.path.realpath(WORK))
    return result.returncode == 0 and home in Path(os.path.realpath(result.stdout.strip())).parents


def write(relative, text):
    path = REPO / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def edit(relative, old, new):
    text = (REPO / relative).read_text(encoding="utf-8")
    assert old in text, f"{old!r} is not in {relative}"
    write(relative, text.replace(old, new))


def setup():
    REPO.mkdir()
    sh("git", "init", "-q", "-b", "main")
    for name in ("check_imports.py", "check_rules.py", "check_prd_ids.py"):
        write(f"scripts/{name}", (HERE / name).read_text(encoding="utf-8"))
    write("docs/ARCHITECTURE.md", ARCHITECTURE)
    for name, text in FILES.items():
        write(name, text)
    sh("git", "add", "-A")
    sh("git", "-c", "user.name=t", "-c", "user.email=t@example.invalid", "commit", "-q", "-m", "base")


def reset():
    # These commands destroy work. Run them only where that is the point.
    if not targets_fixture():
        raise SystemExit("refusing to reset: git is not pointed at the fixture")
    sh("git", "reset", "-q", "--hard", "HEAD")
    sh("git", "clean", "-qfdx")


def case(name, expect, want=(), absent=(), ci=False, cwd=None, isolated=True):
    """Run the check once. expect is the exit code; want/absent are substrings."""
    env = dict(ENV)
    if ci:
        env["GITHUB_ACTIONS"] = "true"
    command = [sys.executable] + (["-I"] if isolated else []) + [str(REPO / "scripts/check_imports.py")]
    started = time.time()
    try:
        result = subprocess.run(command, cwd=cwd or REPO, capture_output=True, text=True,
                                env=env, timeout=60, check=False)
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
    )
    results.append((ok, name))
    if not ok or VERBOSE:
        print(f"{'ok  ' if ok else 'FAIL'} {name} (exit {code}, {time.time() - started:.1f}s)")
    if not ok:
        print(f"     expected exit {expect}, with {want}, without {absent}")
        print("     | " + out.replace("\n", "\n     | "))


def swift(relative, line, before="import Kit\n"):
    """Add a line to a Swift file of the fixture."""
    write(relative, before + line + "\n")


setup()
FORBIDDEN = "which App may not import"
APP = "mac/Sources/App/App.swift"

# --- The layout as it is -----------------------------------------------------
reset(); case("the fixture follows its directions", 0,
              want=["5 code unit(s)", "every import follows the allowed directions"])
reset(); case("run from another folder, it still checks the repository", 0, cwd=WORK,
              want="every import follows the allowed directions")

# --- Swift imports between code units -------------------------------------------
reset(); swift(APP, "import Helper")
case("the app imports the helper", 1, want=[f"{APP} line 2 imports Helper, {FORBIDDEN}", "AR-005"])
reset(); swift("mac/Sources/Kit/Client.swift", "import App", before="")
case("the library imports the app", 1, want="imports App, which Kit may not import")
reset(); swift("mac/Tests/KitTests/ClientTests.swift", "import App")
case("a test target imports a unit it may not", 1, want="imports App, which KitTests may not import")
reset(); swift("mac/Sources/Kit/Client.swift", "import KitTests", before="")
case("the library imports its tests", 1, want="imports KitTests, which Kit may not import")
for form in ("@testable import Helper", "import struct Helper.Thing", "import func Helper.run",
             "internal import Helper", "public import Helper", "@preconcurrency import Helper",
             "@_exported public import Helper", "@_implementationOnly import Helper",
             "    import Helper", "import Kit; import Helper", "import\tHelper",
             "@available(macOS 14, *) import Helper", "import Helper // the helper"):
    reset(); swift(APP, form)
    case(f"forbidden import written as: {form.strip()}", 1, want=FORBIDDEN)
reset(); swift(APP, "#if canImport(Helper)\nimport Helper\n#endif")
case("an import inside #if is still an import", 1, want=FORBIDDEN)
reset(); swift(APP, "#if canImport(Helper)\n#endif")
case("canImport is not an import", 0)
reset(); swift(APP, "import Foundation\nimport SwiftUI\nimport Testing\nimport os")
case("modules that are not code units are not checked here", 0)
reset(); swift(APP, "import HelperExtras\nimport Kit2")
case("a module whose name only starts like a unit is not that unit", 0)

# --- Text that only looks like an import ---------------------------------------
for name, text in (
    ("a line comment", "// import Helper"),
    ("a comment after code", "let x = 1 // import Helper"),
    ("a block comment", "/*\nimport Helper\n*/"),
    ("a nested block comment", "/* outer /* inner */\nimport Helper\n*/"),
    ("a multi-line string", "let s = \"\"\"\nimport Helper\n\"\"\""),
    ("a raw multi-line string", "let s = #\"\"\"\n\"\"\"\nimport Helper\n\"\"\"#"),
    ("a string", "let s = \"import Helper\""),
    ("a documentation comment", "/// import Helper"),
):
    reset(); swift(APP, text)
    case(f"an import in {name} is not an import", 0)
reset(); swift(APP, "let s = \"/*\"\nimport Helper")
case("a comment marker inside a string does not hide the next line", 1, want=FORBIDDEN)
reset(); swift(APP, "let s = \"a \\\" b\"\nimport Helper")
case("an escaped quote does not hide the next line", 1, want=FORBIDDEN)
reset(); swift(APP, "/* a */ import Helper")
case("an import after a closed block comment is an import", 1, want=FORBIDDEN)

# --- Code that is in no listed unit ----------------------------------------------
reset(); write("mac/Sources/Extra/Extra.swift", "import Foundation\n")
case("a new Swift target that is not listed", 1,
     want="mac/Sources/Extra/Extra.swift is not in any code unit listed")
reset(); write("tools/run.rb", "puts 1\n")
case("Ruby code outside every unit", 1, want="tools/run.rb is not in any code unit listed")
reset(); write("docs/example.rb", "require_relative '../../x'\n"); write("scripts/x.swift", "import App\n")
write(".github/x.rb", "x\n"); write(".agents/x.swift", "import Helper\n")
case("docs/, scripts/, .github/ and .agents/ hold no product code", 0)
reset(); write("mac/.build/checkouts/x/Sources/x.swift", "import Helper\n")
case("files git ignores are not read", 0)
reset(); write("mac/Sources/App/Extra.swift", "import Helper\n")
sh("git", "add", "-A")
case("a file not yet committed is read", 1, want="mac/Sources/App/Extra.swift line 1 imports Helper")

# --- Ruby code stays inside its unit ---------------------------------------------
RB = "api/config/application.rb"
for name, line in (
    ("require_relative out of the unit", "require_relative \"../../mac/Sources/Kit/client\""),
    ("require_relative with single quotes", "require_relative '../../scripts/check_rules'"),
    ("require_relative in brackets", "require_relative(\"../../tools/x\")"),
    ("require with a path that climbs", "require \"../../tools/x\""),
    ("require with an absolute path", "require \"/opt/leverage/x\""),
    ("load out of the unit", "load \"../../tools/x.rb\""),
    ("autoload out of the unit", "autoload :X, \"../../tools/x\""),
    ("require_relative after other code", "x = 1; require_relative \"../../tools/x\""),
):
    reset(); edit(RB, "require \"rails\"\n", f"require \"rails\"\n{line}\n")
    case(f"Ruby: {name}", 1, want=[f"{RB} line 3", "outside its code unit api/"])
reset(); edit("api/bin/rails", "../config/boot", "../../mac/x")
case("Ruby: a script without an extension is read by its first line", 1, want="api/bin/rails line 2")
for name, line in (
    ("require_relative inside the unit", "require_relative \"../app/models/thing\""),
    ("require of a gem", "require \"rails/all\""),
    ("a commented-out require", "# require_relative \"../../mac/x\""),
    ("a require in a string", "x = \"require_relative '../../mac/x'\""),
):
    reset(); edit(RB, "require \"rails\"\n", f"require \"rails\"\n{line}\n")
    case(f"Ruby: {name} is fine", 0)
reset(); edit(RB, "require \"rails\"\n", "require \"rails\"\n=begin\nrequire_relative \"../../mac/x\"\n=end\n")
case("Ruby: a require in a =begin block is not read", 0)

# --- The list of directions ------------------------------------------------------
reset(); edit("docs/ARCHITECTURE.md", "| `App` | `mac/Sources/App/` | `Kit` |", "| `App` | `mac/Sources/App/` | `Kit`, `Helper` |")
swift(APP, "import Helper")
case("a direction added to the list is allowed", 0)
reset(); edit("docs/ARCHITECTURE.md", "### Allowed dependency directions", "### Directions")
case("no list of directions", 1, want="no '### Allowed dependency directions' table under '## Components'")
reset(); edit("docs/ARCHITECTURE.md", DIRECTIONS, f"<!--\n{DIRECTIONS}-->\n")
case("a list inside an HTML comment does not count", 1, want="no '### Allowed dependency directions' table")
reset(); edit("docs/ARCHITECTURE.md", DIRECTIONS, f"```text\n{DIRECTIONS}```\n")
case("a list inside a code fence does not count", 1, want="no '### Allowed dependency directions' table")
reset(); edit("docs/ARCHITECTURE.md", "## Components", "## Parts")
case("no Components section", 1, want="no '### Allowed dependency directions' table under '## Components'")
reset(); edit("docs/ARCHITECTURE.md", "| `Helper` | `mac/Sources/Helper/` | `Kit` |",
              "| `Helper` | `mac/Sources/Helper/` | `Kit` |\n| `Old` | `mac/Sources/Old/` | nothing |")
case("a listed unit whose folder does not exist", 1, want="mac/Sources/Old/, the folder of Old, does not exist")
reset(); edit("docs/ARCHITECTURE.md", "| `App` | `mac/Sources/App/` | `Kit` |", "| `App` | `mac/Sources/App/` | `Core` |")
case("a direction to something that is not a unit", 1, want="App may import Core, which is not a listed code unit")
reset(); edit("docs/ARCHITECTURE.md", "| `App` | `mac/Sources/App/` | `Kit` |", "| App | mac/Sources/App/ | `Kit` |")
case("a row without code spans", 1, want="cannot be read")
reset(); edit("docs/ARCHITECTURE.md", "| `api` | `api/` | nothing |", "| `api` | `api/` | nothing |\n| `api` | `api/` | nothing |")
case("a unit listed twice", 1, want="api is listed more than once")
reset(); edit("docs/ARCHITECTURE.md", "| `App` | `mac/Sources/App/` | `Kit` |", "| `App` | `mac/Sources/App/` | `Kit` |\n| `X` | `mac/Sources/App/` | nothing |")
case("two units with one folder", 1, want="mac/Sources/App/ is listed more than once")
reset(); edit("docs/ARCHITECTURE.md", "`mac/Sources/App/`", "`../outside/`")
case("a folder outside the repository", 1, want="'../outside/' is not a folder in the repository")
reset(); (REPO / "docs/ARCHITECTURE.md").unlink()
case("the architecture document is missing", 1, want="docs/ARCHITECTURE.md is missing")

# --- Symbolic links are not followed ----------------------------------------------
reset(); os.symlink("../Helper/main.swift", REPO / "mac/Sources/App/Linked.swift")
case("a source file that is a symbolic link", 1, want="mac/Sources/App/Linked.swift is a symbolic link")
reset(); os.rename(REPO / "docs/ARCHITECTURE.md", REPO / "arch.md"); os.symlink("../arch.md", REPO / "docs/ARCHITECTURE.md")
case("the architecture document is a symbolic link", 1, want="docs/ARCHITECTURE.md is a symbolic link")
reset(); shutil.move(str(REPO / "mac/Sources/Helper"), str(REPO / "elsewhere")); os.symlink("../../elsewhere", REPO / "mac/Sources/Helper")
case("a unit folder that is a symbolic link", 1, want="is a symbolic link")
(REPO / "mac/Sources/Helper").unlink(); shutil.move(str(REPO / "elsewhere"), str(REPO / "mac/Sources/Helper"))

# --- How it runs -------------------------------------------------------------------
reset(); swift(APP, "import Helper")
case("errors are annotated in CI", 1, ci=True, want=f"::error::AR-005: {APP} line 2")
reset(); write("mac/Sources/App/x\n::error::pwn.swift", "import Helper\n")
case("a newline in a file name cannot start a workflow command", 1, ci=True, want="x?::error::pwn.swift line 1",
     absent="\n::error::pwn")
reset(); write("scripts/argparse.py", "import sys\nprint('every import follows')\nsys.exit(0)\n"); swift(APP, "import Helper")
case("a file next to the script cannot replace argparse", 1, want=FORBIDDEN, isolated=False)
reset(); case("the check leaves no bytecode behind", 0)
results.append((not (REPO / "scripts/__pycache__").exists(), "no scripts/__pycache__ after a run"))
reset(); shutil.rmtree(REPO / ".git"); swift(APP, "import Helper")
case("outside a git checkout every file is read", 1, want=FORBIDDEN)

failed = [name for ok, name in results if not ok]
print(f"{len(results) - len(failed)}/{len(results)} cases behaved as expected")
for name in failed:
    print(f"  FAILED: {name}")
shutil.rmtree(WORK, ignore_errors=True)
sys.exit(1 if failed else 0)
