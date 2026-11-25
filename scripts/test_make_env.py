#!/usr/bin/env python3
"""Self-test for make_env.py, and for the example it reads.

.env.example must not carry a secret that works: a copy of it alone must
not start the server, or a stranger who skips the edit runs a database
whose passwords anyone can read in this repository. make_env.py makes the
.env a developer's or a script's run uses, with random values of its own.
These cases hold that the example's three secrets are empty, that
compose.yaml refuses to start without the two it cannot do without, that
the generated file has three distinct random values, keeps every other
line, is private, and is never written over, and that no script or
workflow uses a copy of the example in its place.

Usage: python3 -I scripts/test_make_env.py [-v]
Standard library only; exits 0 when every case behaves as expected.
"""

import re
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
SCRIPT = HERE / "make_env.py"
EXAMPLE = ROOT / ".env.example"
COMPOSE = ROOT / "compose.yaml"
VERBOSE = "-v" in sys.argv[1:]
# The secrets and the length of the hex value each is given, as the app
# gives its own server folder (ServerFiles.swift).
SECRETS = {"POSTGRES_PASSWORD": 32, "LEVERAGE_API_DB_PASSWORD": 32, "SECRET_KEY_BASE": 128}
COPY = re.compile(r"\bcp\b[^\n]*\.env\.example")


def values(text):
    """The KEY=value lines of an env file, in order."""
    found = {}
    for line in text.splitlines():
        if line and not line.startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            found[key] = value
    return found


def run(folder, *arguments, example=EXAMPLE):
    output = Path(folder) / ".env"
    result = subprocess.run(
        [sys.executable, "-I", str(SCRIPT), "--example", str(example), "--output", str(output), *arguments],
        capture_output=True, text=True, check=False)
    return result.returncode, result.stdout + result.stderr, output


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
    example = EXAMPLE.read_text(encoding="utf-8")
    shipped = values(example)

    for name in SECRETS:
        cases.check(f"the example leaves {name} empty", shipped.get(name) == "", shipped.get(name))
    cases.check("the example holds no made-up secret to forget to replace", "change-me" not in example)

    compose = COMPOSE.read_text(encoding="utf-8")
    for name in ("POSTGRES_PASSWORD", "SECRET_KEY_BASE"):
        cases.check(f"compose.yaml refuses to start while {name} is empty or unset",
                    f"{name}: ${{{name}:?" in compose)

    with tempfile.TemporaryDirectory() as folder:
        code, messages, output = run(folder)
        cases.check("it writes the file and exits 0", code == 0 and output.is_file(), messages)
        text = output.read_text(encoding="utf-8") if output.is_file() else ""
        made = values(text)
        for name, length in SECRETS.items():
            cases.check(f"{name} is {length} hex characters",
                        re.fullmatch(f"[0-9a-f]{{{length}}}", made.get(name, "")) is not None, made.get(name))
        cases.check("the three values differ", len({made.get(name) for name in SECRETS}) == len(SECRETS))
        cases.check("every other line is the example's, in order",
                    [line for line in text.splitlines() if line.split("=", 1)[0] not in SECRETS]
                    == [line for line in example.splitlines() if line.split("=", 1)[0] not in SECRETS])
        cases.check("every key is kept, in order", list(made) == list(shipped), list(made))
        cases.check("the file is readable and writable by its owner alone",
                    output.is_file() and stat.S_IMODE(output.stat().st_mode) == 0o600)
        cases.check("it prints no value it made", not any(made.get(name, "x") in messages for name in SECRETS), messages)

        code, messages, _ = run(folder)
        cases.check("a second run refuses to write over the file and says so",
                    code != 0 and "already" in messages and output.read_text(encoding="utf-8") == text, messages)

        with tempfile.TemporaryDirectory() as other:
            _, _, second = run(other)
            again = values(second.read_text(encoding="utf-8")) if second.is_file() else {}
            cases.check("two runs make different values",
                        all(again.get(name) and again.get(name) != made.get(name) for name in SECRETS))

    with tempfile.TemporaryDirectory() as folder:
        kept = Path(folder) / "example"
        kept.write_text("POSTGRES_USER=leverage\nPOSTGRES_PASSWORD=set-by-hand\nSECRET_KEY_BASE=\n", encoding="utf-8")
        code, messages, output = run(folder, example=kept)
        made = values(output.read_text(encoding="utf-8")) if output.is_file() else {}
        cases.check("a value the example already gives is kept, and a missing key is not invented",
                    code == 0 and made.get("POSTGRES_PASSWORD") == "set-by-hand"
                    and "LEVERAGE_API_DB_PASSWORD" not in made and len(made.get("SECRET_KEY_BASE", "")) == 128, messages)

    with tempfile.TemporaryDirectory() as folder:
        code, messages, output = run(folder, example=Path(folder) / "missing")
        cases.check("a missing example fails and writes nothing", code != 0 and not output.exists(), messages)
        code, messages, _ = run(folder, "--unknown")
        cases.check("an unknown argument fails", code != 0, messages)

    copies = []
    for path in sorted((ROOT / "scripts").glob("*.sh")):
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
            if COPY.search(line) and not line.lstrip().startswith("#"):
                copies.append(f"{path.relative_to(ROOT)}:{number}")
    cases.check("no script copies the example in place of making .env", not copies, copies)

    # A workflow copies the example only to prove that compose refuses it,
    # and removes the copy in the same step.
    for path in sorted((ROOT / ".github" / "workflows").glob("*.yml")):
        lines = [line.strip() for line in path.read_text(encoding="utf-8").splitlines()]
        kept = [number for number, line in enumerate(lines, start=1)
                if COPY.search(line) and not line.startswith("#")
                and not ("docker compose config" in " ".join(lines[number:number + 5])
                         and "rm .env" in lines[number:number + 6])]
        cases.check(f"{path.name} keeps no copy of the example as .env", not kept, kept)

    print(f"{cases.count - len(cases.failures)}/{cases.count} cases passed")
    return 1 if cases.failures else 0


if __name__ == "__main__":
    sys.exit(main())
