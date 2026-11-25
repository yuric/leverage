#!/usr/bin/env python3
"""Check the model catalog, api/contract/models.json (contract decision UX-5).

The catalog lists each login provider's models and the efforts each model
accepts; the server refuses a model or an effort it does not list, and the
Mac reads the same list from the generated ModelCatalog.swift. An entry is
never invented: each says how it is known. This check fails on

  * an evidence level outside the catalog's evidence_levels, or a catalog
    without them;
  * an empty source, or a missing date (checked_on) or one that is not a
    calendar date in the form YYYY-MM-DD;
  * a documented fact whose source is not a page address (https://);
  * a help or probe fact whose source is not a path to a file in the
    repository (a recorded reply, a probe, or a saved --help output), or a
    model id or default model whose cited file does not name it;
  * efforts whose evidence is not documented (a tool's --help lists efforts
    for the whole tool and never says which model accepts which);
  * an effort, or a model id, listed twice;
  * a default model that is not among the provider's models;
  * a provider that is not a login provider of the registry, a provider
    listed twice, or a login provider missing.

No automated job reaches a provider: the catalog changes by a pull request
that edits models.json with the new entry's evidence and date (DEPLOY.md,
"Updating the model list").

Usage: python3 scripts/check_model_catalog.py [--models PATH] [--registry PATH] [--root PATH]
Standard library only; exits 0 when the catalog holds, 1 otherwise.
"""

import argparse
import datetime
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
RECORDED = ("help", "probe", "probe (full environment)")


def fact_problems(where, fact, levels, root, value=None):
    """Problems with one fact; value is the model id or default it evidences."""
    problems = []
    evidence = fact.get("evidence")
    if evidence not in levels:
        problems.append(f"{where}: evidence {evidence!r} is not one of {', '.join(levels)}")
    source = fact.get("source")
    if not isinstance(source, str) or not source.strip():
        problems.append(f"{where}: the source is empty")
    elif evidence == "documented" and not source.startswith("https://"):
        problems.append(f"{where}: a documented fact must cite a page address (https://), not {source!r}")
    elif evidence in RECORDED:
        path = source.split("#", 1)[0]
        if "://" in source or path.startswith("/") or ".." in Path(path).parts:
            problems.append(f"{where}: a {evidence} fact must cite a repository path, not {source!r}")
        elif not (root / path).is_file():
            problems.append(f"{where}: {path} is not a file in the repository ({evidence} evidence)")
        elif isinstance(value, str) and value not in (root / path).read_text(encoding="utf-8", errors="replace"):
            problems.append(f"{where}: {path} does not name {value!r} ({evidence} evidence)")
    if not is_date(fact.get("checked_on")):
        problems.append(f"{where}: checked_on is missing or not a date")
    return problems


def is_date(value):
    if not isinstance(value, str) or not DATE.match(value):
        return False
    try:
        datetime.date.fromisoformat(value)
    except ValueError:
        return False
    return True


def check(models, registry, root):
    problems = []
    levels = models.get("evidence_levels")
    if not isinstance(levels, list) or not levels:
        return ["models.json has no evidence_levels"]
    logins = [entry["provider"] for entry in registry.get("credential_providers", []) if entry.get("kind") == "login"]
    seen = []
    for entry in models.get("providers", []):
        name = entry.get("provider")
        if name in seen:
            problems.append(f"{name}: the provider is listed twice")
        seen.append(name)
        if name not in logins:
            problems.append(f"{name}: not a login provider of the registry ({', '.join(logins)})")
        native = entry.get("native_effort") or {}
        problems += fact_problems(f"{name} native_effort", native, levels, root)
        default = entry.get("default_model")
        if default is not None:
            problems += fact_problems(f"{name} default_model", default, levels, root, default.get("value"))
        ids = []
        for model in entry.get("models", []):
            model_id = model.get("id")
            where = f"{name} {model_id}"
            if model_id in ids:
                problems.append(f"{where}: the model is listed twice")
            ids.append(model_id)
            problems += fact_problems(where, model, levels, root, model_id)
            efforts = model.get("efforts")
            if efforts is None:
                continue
            if efforts.get("evidence") != "documented":
                problems.append(f"{where}: efforts must be documented, not {efforts.get('evidence')!r}")
            problems += fact_problems(f"{where} efforts", efforts, levels, root)
            values = efforts.get("values", [])
            for value in sorted({v for v in values if values.count(v) > 1}):
                problems.append(f"{where}: the effort {value!r} is listed twice")
        if default is not None and default.get("value") not in ids:
            problems.append(f"{name}: the default model {default.get('value')!r} is not among its models")
    for name in logins:
        if name not in seen:
            problems.append(f"{name}: the login provider is missing from models.json")
    return problems


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--models", type=Path, default=ROOT / "api" / "contract" / "models.json")
    parser.add_argument("--registry", type=Path, default=ROOT / "api" / "contract" / "registry.json")
    parser.add_argument("--root", type=Path, default=ROOT)
    arguments = parser.parse_args(argv)
    try:
        models = json.loads(arguments.models.read_text(encoding="utf-8"))
        registry = json.loads(arguments.registry.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        print(f"check_model_catalog: {error}", file=sys.stderr)
        return 1
    problems = check(models, registry, arguments.root.resolve())
    for problem in problems:
        print(problem)
    if problems:
        print(f"check_model_catalog: {len(problems)} problem(s) in models.json")
        return 1
    print("OK: the model catalog lists only evidenced entries.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
