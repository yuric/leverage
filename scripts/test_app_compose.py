#!/usr/bin/env python3
"""Self-test for app_compose.py.

app_compose.py makes the compose file the app bundle carries from the
repository's compose.yaml (milestone 2 plan PK-1): the `build:` line is
removed and `pull_policy: never` is set on the `api` and `sweep` services,
so a missing image gives the app's "not built on this Mac" sentence and
not a registry error. These cases prove that on the real compose.yaml
exactly that changes and every other line is kept, in order, and that a
compose file of another shape fails and says why instead of being
changed in a way nobody checked.

Usage: python3 scripts/test_app_compose.py [-v]
Standard library only; exits 0 when every case behaves as expected.
"""

import difflib
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
SCRIPT = HERE / "app_compose.py"
COMPOSE = ROOT / "compose.yaml"
VERBOSE = "-v" in sys.argv[1:]
PULL = "pull_policy: never"


def run(text, *arguments, to_file=True):
    """Run the script on `text`; return (code, messages, output text)."""
    with tempfile.TemporaryDirectory() as folder:
        source = Path(folder) / "compose.yaml"
        target = Path(folder) / "out" / "compose.yaml"
        source.write_text(text, encoding="utf-8")
        command = [sys.executable, "-I", str(SCRIPT), "--input", str(source)]
        if to_file:
            command += ["--output", str(target)]
        result = subprocess.run(command + list(arguments), capture_output=True, text=True, check=False)
        if to_file:
            output = target.read_text(encoding="utf-8") if target.exists() else None
            messages = result.stdout + result.stderr
        else:
            output = result.stdout if result.returncode == 0 else None
            messages = result.stderr
    return result.returncode, messages, output


def service_block(text, name):
    """The lines of one service under `services:`, without its key line."""
    lines = text.splitlines()
    if "services:" not in lines:
        return []
    start = lines.index("services:")
    block, inside = [], False
    for line in lines[start + 1:]:
        if line and not line.startswith(" ") and not line.startswith("#"):
            break
        if line.startswith("  ") and not line.startswith("   ") and line.rstrip().endswith(":"):
            inside = line.strip() == f"{name}:"
            continue
        if inside:
            block.append(line)
    return block


def first_setting(block):
    for line in block:
        stripped = line.strip()
        if stripped and not stripped.startswith("#"):
            return line
    return None


class Cases:
    def __init__(self):
        self.failures = []
        self.count = 0

    def check(self, name, condition, detail=""):
        self.count += 1
        if condition:
            if VERBOSE:
                print(f"ok   {name}")
        else:
            self.failures.append(name)
            print(f"FAIL {name}")
            if detail:
                print("     " + str(detail).replace("\n", "\n     "))


def main():
    cases = Cases()
    original = COMPOSE.read_text(encoding="utf-8")

    code, messages, made = run(original)
    cases.check("the repository's compose.yaml is accepted", code == 0 and made is not None, messages)
    made = made or ""

    before = original.splitlines()
    after = made.splitlines()
    removed = [line for tag, i1, i2, _, _ in difflib.SequenceMatcher(None, before, after, autojunk=False).get_opcodes()
               if tag in ("delete", "replace") for line in before[i1:i2]]
    added = [line for tag, _, _, j1, j2 in difflib.SequenceMatcher(None, before, after, autojunk=False).get_opcodes()
             if tag in ("insert", "replace") for line in after[j1:j2]]
    build_lines = [line for line in before if line.strip().startswith("build:")]
    cases.check("the repository's compose.yaml has exactly one build line", len(build_lines) == 1, build_lines)
    cases.check("only the build line is removed", removed == build_lines, removed)
    cases.check("only two pull_policy lines are added",
                [line.strip() for line in added] == [PULL, PULL], added)
    cases.check("every other line is kept, in order",
                [line for line in after if line.strip() != PULL] == [line for line in before if line not in build_lines])
    cases.check("no build line is left", not any(line.strip().startswith("build:") for line in after))

    for name in ("api", "sweep"):
        block = service_block(made, name)
        first = first_setting(block)
        cases.check(f"{name} starts with pull_policy: never at the service's indentation",
                    first == "    " + PULL, first)
    db = service_block(made, "db")
    cases.check("db is left as it was (its image is pulled by build_app.sh)",
                db == service_block(original, "db") and not any(PULL in line for line in db))
    cases.check("the file still ends with a newline", made.endswith("\n"))

    code, messages, output = run(original, to_file=False)
    cases.check("without --output it writes the same text to standard output", code == 0 and output == made, messages)

    code, messages, output = run(original.replace(build_lines[0] + "\n", "") if build_lines else original)
    cases.check("a compose file with no build line fails and says so",
                code != 0 and output is None and "build" in messages, messages)

    doubled = original.replace("  image: postgres", "  build: ./db\n    image: postgres", 1)
    code, messages, output = run(doubled)
    cases.check("a compose file with two build lines fails and says so",
                code != 0 and output is None and "build" in messages, messages)

    commented = original.replace("services:\n", "services:\n  # build: ./elsewhere is only a comment\n", 1)
    code, messages, output = run(commented)
    cases.check("a build in a comment is neither counted nor removed",
                code == 0 and output is not None and "# build: ./elsewhere is only a comment" in output, messages)

    no_sweep = original.replace("\n  sweep:\n", "\n  timers:\n", 1)
    code, messages, output = run(no_sweep)
    cases.check("a compose file without a sweep service fails and names it",
                code != 0 and output is None and '"sweep"' in messages, messages)

    no_api = original.replace("\n  api:\n", "\n  web:\n", 1)
    code, messages, output = run(no_api)
    cases.check("a compose file without an api service fails and names it",
                code != 0 and output is None and '"api"' in messages, messages)

    preset = original.replace("\n  sweep:\n", "\n  sweep:\n    pull_policy: always\n", 1)
    code, messages, output = run(preset)
    cases.check("a service that already sets pull_policy fails and names it",
                code != 0 and output is None and '"sweep"' in messages and "pull_policy" in messages, messages)

    no_services = original.replace("\nservices:\n", "\nservice:\n", 1)
    code, messages, output = run(no_services)
    cases.check("a compose file without services fails",
                code != 0 and output is None and "services" in messages, messages)

    code, messages, _ = run(original, "--unknown")
    cases.check("an unknown argument fails", code != 0, messages)

    print(f"{cases.count - len(cases.failures)}/{cases.count} cases passed")
    return 1 if cases.failures else 0


if __name__ == "__main__":
    sys.exit(main())
