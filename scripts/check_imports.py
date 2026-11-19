#!/usr/bin/env python3
"""Check that code imports only along the allowed dependency directions.

Rule AR-005 in docs/ARCHITECTURE.md ("Rules") is the authority; the list of
code units and the directions each may import is the table under
"Components", "Allowed dependency directions". This file only enforces them:

  * every Swift or Ruby file outside docs/, scripts/, .github/ and .agents/
    belongs to a listed code unit (mac/Package.swift, the package manifest,
    is the one exception);
  * a Swift file imports another code unit only if its unit may import it;
  * a Ruby file loads no file outside its own unit's folder.

Usage:
  python3 scripts/check_imports.py

Standard library and git only; exits 0 when every check passes, 1 otherwise.
"""

import sys

# The same protection as check_rules.py: this script runs on pull requests,
# where files next to it are not trusted. CI also runs it with "python3 -I".
sys.dont_write_bytecode = True
import os  # noqa: E402  (already loaded by the interpreter; not a path lookup)

_HERE = os.path.dirname(os.path.abspath(__file__))
# Compared as real paths: Python puts the script's folder on the path with
# symbolic links resolved, and __file__ may name it through one.
sys.path[:] = [
    p for p in sys.path if os.path.realpath(p or os.curdir) != os.path.realpath(_HERE)
]

import importlib.util  # noqa: E402
import posixpath  # noqa: E402
import re  # noqa: E402
from pathlib import PurePosixPath  # noqa: E402


def _load_sibling(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(_HERE, name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# check_rules.py reads Markdown, lists files, and reports; both checks do it
# the same way.
_rules = _load_sibling("check_rules")
ARCHITECTURE = _rules.ARCHITECTURE
Report = _rules.Report
Stop = _rules.Stop

COMPONENTS = "Components"
DIRECTIONS = "Allowed dependency directions"
# Folders that hold no product code (see "Rules" in docs/ARCHITECTURE.md).
NOT_PRODUCT = ("docs/", "scripts/", ".github/", ".agents/")
# The Swift package manifest describes the targets; it belongs to none.
MANIFEST = "Package.swift"
RUBY_SUFFIXES = (".rb", ".ru", ".rake", ".gemspec")
RUBY_NAMES = ("Gemfile", "Rakefile")

A = re.ASCII
CODE_SPAN = re.compile(r"`([^`]+)`")
UNIT_NAME = re.compile(r"^[A-Za-z_]\w*$", A)
# A Swift import: attributes, an access level, an import kind, then the module.
SWIFT_IMPORT = re.compile(
    r"^\s*(?:@\w+(?:\([^)]*\))?\s*)*"
    r"(?:(?:public|package|internal|fileprivate|private|open)\s+)?"
    r"import\s+(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?"
    r"([A-Za-z_]\w*)",
    A,
)
# The start of a Swift string literal: optional "#"s for a raw string, then
# one quote or three.
SWIFT_STRING = re.compile(r'(#*)("""|")')
# A Ruby statement that loads a file named by a literal.
RUBY_LOAD = re.compile(
    r"""(?:^|;)\s*(require_relative|require|load|autoload\s*\(?\s*:\w+\s*,)"""
    r"""\s*\(?\s*(["'])([^"']+)\2""",
    A,
)


# --- The list of directions --------------------------------------------------


def parse_directions(text, report):
    """Return {unit: (folder, allowed units)} from the Components section."""
    components = _rules.section(text or "", COMPONENTS, level=2)
    table = _rules.section(components or "", DIRECTIONS, level=3)
    rows = [line.strip() for line in (table or "").split("\n") if line.strip().startswith("|")]
    units, folders, problems = {}, {}, []
    for row in rows:
        cells = [cell.strip() for cell in row.strip("|").split("|")]
        if set("".join(cells)) <= set("-: ") or "`" not in "".join(cells):
            continue  # the header, or the line under it
        name = CODE_SPAN.fullmatch(cells[0]) if cells else None
        folder = CODE_SPAN.fullmatch(cells[1]) if len(cells) > 1 else None
        allowed = CODE_SPAN.findall(cells[2]) if len(cells) > 2 else []
        if (
            len(cells) != 3 or not name or not folder or not UNIT_NAME.match(name.group(1))
            or not folder.group(1).endswith("/")
            or not (allowed or cells[2].lower().startswith("nothing"))
        ):
            problems.append(
                f"the row '{row}' cannot be read: write it as "
                "| `Unit` | `folder/` | `Other`, `Another` | or 'nothing' in the last cell"
            )
            continue
        name, folder = name.group(1), folder.group(1)
        if name in units:
            problems.append(f"{name} is listed more than once")
            continue
        if folder in folders:
            problems.append(f"{folder} is listed more than once ({folders[folder]})")
            continue
        clean = posixpath.normpath(folder)
        if folder.startswith("/") or clean.startswith("..") or clean == ".":
            problems.append(f"'{folder}' is not a folder in the repository")
            continue
        units[name] = (folder, set(allowed))
        folders[folder] = name
    if not units and not problems:
        problems.append(
            f"there is no '### {DIRECTIONS}' table under '## {COMPONENTS}' that a "
            "reader can see"
        )
    for name, (folder, allowed) in sorted(units.items()):
        for other in sorted(allowed - set(units)):
            problems.append(f"{name} may import {other}, which is not a listed code unit")
        kind = _rules.kind_of(folder.rstrip("/"))
        if kind == "missing":
            problems.append(f"{folder}, the folder of {name}, does not exist")
        elif kind != "dir":
            problems.append(f"{folder}, the folder of {name}, {_rules.not_a_file(kind)}")
    for problem in problems:
        report.error(f"AR-005: {ARCHITECTURE}: {problem}")
    if not problems:
        report.ok(f"AR-005: {len(units)} code unit(s) listed under {COMPONENTS} in {ARCHITECTURE}")
    return units if not problems else None


def unit_of(name, units):
    """Return the unit whose folder holds a file (the deepest one), or None."""
    found = None
    for unit, (folder, _) in units.items():
        if name.startswith(folder) and (found is None or len(folder) > len(units[found][0])):
            found = unit
    return found


# --- Reading code ------------------------------------------------------------


def swift_code(text):
    """Return the lines of a Swift file with comments and strings blanked.

    Every character that is not code becomes a space, and line breaks stay,
    so line numbers are kept. Block comments nest, as they do in Swift. A
    one-line string ends at the end of its line at the latest.
    """
    out = []
    at, end = 0, len(text)
    depth = 0  # how many block comments are open
    string = None  # (closing delimiter, raw, multi-line) while in a string
    while at < end:
        ch = text[at]
        if depth:
            if text.startswith("/*", at) or text.startswith("*/", at):
                depth += 1 if ch == "/" else -1
                out.append("  ")
                at += 2
            else:
                out.append("\n" if ch == "\n" else " ")
                at += 1
        elif string:
            close, raw, multi = string
            if ch == "\n" and not multi:
                string = None
                out.append("\n")
                at += 1
            elif ch == "\\" and not raw and at + 1 < end:
                out.append(" " + ("\n" if text[at + 1] == "\n" else " "))
                at += 2
            elif text.startswith(close, at):
                string = None
                out.append(" " * len(close))
                at += len(close)
            else:
                out.append("\n" if ch == "\n" else " ")
                at += 1
        elif text.startswith("//", at):
            stop = text.find("\n", at)
            stop = end if stop < 0 else stop
            out.append(" " * (stop - at))
            at = stop
        elif text.startswith("/*", at):
            depth = 1
            out.append("  ")
            at += 2
        else:
            opening = SWIFT_STRING.match(text, at) if ch in '#"' else None
            if opening:
                hashes, quote = opening.groups()
                string = (quote + hashes, bool(hashes), quote == '"""')
                out.append(" " * (opening.end() - at))
                at = opening.end()
            else:
                out.append(ch)
                at += 1
    return "".join(out).split("\n")


def swift_imports(text):
    """Yield (line number, module) for each import in a Swift file."""
    for number, line in enumerate(swift_code(text), 1):
        for statement in line.split(";"):
            found = SWIFT_IMPORT.match(statement)
            if found:
                yield number, found.group(1)


def ruby_loads(text):
    """Yield (line number, method, path) for each file a Ruby file loads."""
    in_doc = False
    for number, line in enumerate(text.splitlines(), 1):
        if in_doc:
            in_doc = not line.startswith("=end")
            continue
        if line.startswith("=begin"):
            in_doc = True
            continue
        for found in RUBY_LOAD.finditer(line):
            yield number, found.group(1).split()[0].split("(")[0], found.group(3)


def is_ruby(name, text):
    path = PurePosixPath(name)
    if path.suffix in RUBY_SUFFIXES or path.name in RUBY_NAMES:
        return True
    first = text.split("\n", 1)[0] if not path.suffix else ""
    return first.startswith("#!") and "ruby" in first


def escapes(name, method, path, folder):
    """True if a Ruby load reaches outside the unit's folder."""
    if method == "require_relative":
        target = posixpath.normpath(posixpath.join(posixpath.dirname(name), path))
        return not (target + "/").startswith(folder)
    return path.startswith("/") or ".." in path.split("/")


# --- The check ----------------------------------------------------------------


def check_imports(units, files, report):
    failures = 0
    imports = 0
    read = 0
    for name in files:
        if name.startswith(NOT_PRODUCT):
            continue
        path = PurePosixPath(name)
        swift = path.suffix == ".swift"
        if not swift and path.suffix not in RUBY_SUFFIXES + ("",) and path.name not in RUBY_NAMES:
            continue
        kind = _rules.kind_of(name)
        if kind != "file":
            if swift or path.suffix in RUBY_SUFFIXES:
                failures += 1
                report.error(f"AR-005: {name} {_rules.not_a_file(kind)}.")
            continue
        text = _rules.read(name)
        ruby = not swift and is_ruby(name, text)
        if not swift and not ruby:
            continue
        unit = unit_of(name, units)
        if unit is None:
            if swift and path.name == MANIFEST:
                continue
            failures += 1
            report.error(
                f"AR-005: {name} is not in any code unit listed under {COMPONENTS} in "
                f"{ARCHITECTURE}. Add its unit and the directions it may import, with an ADR."
            )
            continue
        read += 1
        folder, allowed = units[unit]
        if swift:
            for number, module in swift_imports(text):
                if module not in units or module == unit:
                    continue
                imports += 1
                if module not in allowed:
                    failures += 1
                    report.error(
                        f"AR-005: {name} line {number} imports {module}, which {unit} may "
                        f"not import. The allowed directions are under {COMPONENTS} in "
                        f"{ARCHITECTURE}; a new one changes that list, with an ADR."
                    )
        else:
            for number, method, target in ruby_loads(text):
                if escapes(name, method, target, folder):
                    failures += 1
                    report.error(
                        f"AR-005: {name} line {number} loads '{target}' with {method}, "
                        f"which is outside its code unit {folder}"
                    )
    if not failures:
        report.ok(
            f"AR-005: every import follows the allowed directions ({read} file(s) read, "
            f"{imports} import(s) between code units)"
        )


def run_checks(report):
    text = _rules.read_input(ARCHITECTURE, report)
    if text is None:
        if _rules.kind_of(ARCHITECTURE) == "missing":
            report.error(f"AR-005: {ARCHITECTURE} is missing")
        return
    units = parse_directions(text, report)
    if units is None:
        return
    check_imports(units, _rules.working_files(need_git=False), report)


def main():
    for stream in (sys.stdout, sys.stderr):
        try:  # a message never fails to print, whatever the terminal accepts
            stream.reconfigure(errors="backslashreplace")
        except (AttributeError, ValueError):
            pass
    report = Report()
    try:
        run_checks(report)
    except Stop as stop:
        report.error(f"{str(stop).rstrip('.')}. The check stopped here.")
    except Exception as problem:  # noqa: BLE001  (fail with a message, never a traceback)
        report.error(
            f"internal error in the import check ({type(problem).__name__}: "
            f"{str(problem)[:200]}). The check stopped here."
        )
    if report.errors:
        print(f"\n{report.errors} problem(s). Rule AR-005 is in {ARCHITECTURE}.")
        return 1
    print("\nAll import checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
