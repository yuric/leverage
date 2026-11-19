#!/usr/bin/env python3
"""Write the contract's fixed lists as Swift enums for the Mac side.

api/contract/registry.json is the authority for the fixed lists, and
api/contract/openapi.json for the few closed values that only the interface
schema has. The Mac side reads them as Swift enums in one generated file,
mac/Sources/LeverageKit/Generated/Contract.swift, which is changed only by
changing the contract and running this script again (rule AR-002). CI runs
it with --check, which fails when the committed file differs from a fresh
run.

What is written:

  * every list under the registry's "lists", each under the Swift name
    LIST_NAMES gives it (a list without one fails, so a new list is named
    on purpose);
  * the registry's named lists in NAMED_LISTS (commands, event types, hold
    reasons, refusals, check results, release reasons, next kinds, step
    kinds, Needs you items, credential providers), with the extra facts the
    Mac side reads: a provider's kind and group, and whether a seat may
    choose a release reason;
  * the operations, as ContractOperation with each one's method, path,
    caller and tag, so that no path is typed in Swift (IN-1);
  * the interface schema's own enums in OPENAPI_ENUMS (transport error
    codes, helper checks and their states and failures, and a few more).

The registry keys in SERVER_ONLY (hooks, guards, timers' due-time sources,
policy effects, job kinds) are the server's machinery and are not written.
Any other registry key fails, so nothing is left out silently.

A value becomes a lower camel case case name (`in_review` -> `inReview`,
`task.claimed` -> `taskClaimed`), with the value as its raw value where the
two differ; a Swift keyword is escaped with backticks. A value that is not
lower snake case (dots allowed), or two values with one case name, fail.

Usage:
  python3 scripts/generate_swift_contract.py           # write the file
  python3 scripts/generate_swift_contract.py --check   # compare, write nothing
Options --registry, --openapi and --output replace the three paths (for the
self-test). Standard library only; exits 0 on success, 1 otherwise.
"""

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_REGISTRY = ROOT / "api" / "contract" / "registry.json"
DEFAULT_OPENAPI = ROOT / "api" / "contract" / "openapi.json"
DEFAULT_OUTPUT = ROOT / "mac" / "Sources" / "LeverageKit" / "Generated" / "Contract.swift"

VALUE = re.compile(r"^[a-z][a-z0-9]*(?:[._][a-z0-9]+)*$")

# The Swift name of each list under the registry's "lists".
LIST_NAMES = {
    "task_states": "TaskState",
    "criterion_states": "CriterionState",
    "criterion_kinds": "CriterionKind",
    "action_states": "ActionState",
    "action_kinds": "ActionKind",
    "review_verdicts": "ReviewVerdict",
    "question_outcomes": "QuestionOutcome",
    "question_bases": "QuestionBasis",
    "pending_transition_states": "PendingTransitionState",
    "job_states": "JobState",
    "seat_roles": "SeatRole",
    "seat_run_states": "SeatRunState",
    "actor_kinds": "ActorKind",
    "caller_kinds": "CallerKind",
    "operation_callers": "OperationCaller",
    "operation_tags": "OperationTag",
    "event_subject_kinds": "EventSubjectKind",
    "check_subject_kinds": "CheckSubjectKind",
    "step_subject_kinds": "StepSubjectKind",
    "step_classes": "StepClass",
    "step_cause_kinds": "StepCauseKind",
    "wait_causes": "WaitCause",
    "priorities": "Priority",
    "credential_kinds": "CredentialKind",
    "credential_states": "CredentialState",
    "provider_groups": "ProviderGroup",
    "reading_states": "ReadingState",
    "figure_kinds": "FigureKind",
    "limit_windows": "LimitWindow",
    "reset_kinds": "ResetKind",
    "brief_entry_kinds": "BriefEntryKind",
    "evidence_kinds": "EvidenceKind",
    "rule_kinds": "RuleKind",
    "checkers": "RuleChecker",
    "on_fail": "RuleOnFail",
    "routes": "RuleRoute",
    "scope_kinds": "RuleScopeKind",
    "rule_origins": "RuleOrigin",
    "inbox_states": "InboxState",
    "inbox_about_kinds": "InboxAboutKind",
    "inbox_choices": "InboxChoice",
    "helper_request_kinds": "HelperRequestKind",
    "helper_request_states": "HelperRequestState",
    "command_outcomes": "OutcomeKind",
}

# Registry keys that are lists of names, or of objects with a name field:
# (key, the field that holds the value or None, Swift name).
NAMED_LISTS = [
    ("commands", None, "CommandName"),
    ("event_types", "type", "EventType"),
    ("hold_reasons", "reason", "HoldReason"),
    ("refusals", "code", "RefusalCode"),
    ("check_results", None, "CheckResult"),
    ("release_reasons", "reason", "ReleaseReason"),
    ("next_kinds", None, "NextKind"),
    ("step_kinds", None, "StepKind"),
    ("needs_you_items", None, "NeedsYouItem"),
    ("credential_providers", "provider", "Provider"),
]

SERVER_ONLY = {"hooks", "custom_rule_hooks", "guards", "due_time_sources", "policy_effects", "job_kinds"}

# Closed values only the interface schema has: (Swift name, component, the
# property path inside it, a sentence for the comment).
OPENAPI_ENUMS = [
    ("TransportErrorCode", "TransportError", ["error", "code"], "A transport error's code (IF-3)."),
    ("HelperCheck", "HelperCheckProgress", ["check"], "A check the helper runs for a request."),
    ("HelperCheckState", "HelperCheckProgress", ["state"], "Where one check stands while a request runs."),
    ("HelperCheckFailure", "HelperCheckProgress", ["failure"], "Why a check failed."),
    ("HelperRequestOutcome", "HelperRequestResult", ["outcome"], "How a helper request ended."),
    ("RunStopReason", "RunStoppedReport", ["stop_reason"], "Why a seat's run stopped."),
    ("OrchestratorState", "SystemHealth", ["orchestrator"], "Whether the orchestrator is set up and online."),
    ("LogNameKind", "LogName", ["kind"], "What a name in a task's log belongs to."),
]

SWIFT_KEYWORDS = {
    "Any", "Protocol", "Self", "Type", "as", "associatedtype", "break", "case", "catch", "class",
    "continue", "default", "defer", "deinit", "do", "else", "enum", "extension", "fallthrough",
    "false", "fileprivate", "for", "func", "guard", "if", "import", "in", "init", "inout",
    "internal", "is", "let", "nil", "open", "operator", "private", "protocol", "public",
    "repeat", "rethrows", "return", "self", "static", "struct", "subscript", "super", "switch",
    "throw", "throws", "true", "try", "typealias", "var", "where", "while",
}

HEADER = """\
// Generated by scripts/generate_swift_contract.py from
// api/contract/registry.json and api/contract/openapi.json.
// Do not edit: change the contract and run
//   python3 -I scripts/generate_swift_contract.py
// CI fails when this file differs from a fresh run (rule AR-002).
"""


class Problem(Exception):
    pass


def camel(value):
    parts = re.split(r"[._]", value)
    return parts[0] + "".join(part[:1].upper() + part[1:] for part in parts[1:])


def case_name(value):
    name = camel(value)
    return f"`{name}`" if name in SWIFT_KEYWORDS else name


def check_values(swift_name, values, source):
    if not values:
        raise Problem(f"{source}: the list is empty")
    names = {}
    for value in values:
        if not isinstance(value, str) or not VALUE.match(value):
            raise Problem(f"{source}: {value!r} is not lower snake case")
        name = camel(value)
        if name in names:
            raise Problem(
                f"{source}: {names[name]!r} and {value!r} both become the Swift case {name}")
        names[name] = value
    if len(set(values)) != len(values):
        raise Problem(f"{source}: a value is listed twice")


def enum_block(swift_name, values, comment, conformances="String, Codable, CaseIterable, Sendable",
               extra="", raw_values=None):
    """One enum; `raw_values` replaces a value's raw value where given."""
    check_values(swift_name, values, comment)
    lines = [f"/// {comment}", f"public enum {swift_name}: {conformances} {{"]
    for value in values:
        name = case_name(value)
        raw = (raw_values or {}).get(value, value)
        lines.append(f"    case {name}" if camel(value) == raw else f'    case {name} = "{raw}"')
    if extra:
        lines.append("")
        lines.append(extra.rstrip("\n"))
    lines.append("}")
    return "\n".join(lines)


def switch_property(signature, doc, rows):
    """A computed property whose value is a switch over the enum's cases."""
    lines = [f"    /// {doc}", f"    public var {signature} {{", "        switch self {"]
    lines += [f"        case .{case_name(value)}: return {result}" for value, result in rows]
    lines += ["        }", "    }"]
    return "\n".join(lines)


def registry_enums(registry):
    blocks = []
    lists = registry.get("lists")
    if not isinstance(lists, dict):
        raise Problem("registry.json: lists is missing")
    known = {"lists", "operations"} | SERVER_ONLY | {key for key, _, _ in NAMED_LISTS}
    unknown = sorted(set(registry) - known)
    if unknown:
        raise Problem(
            "registry.json: no Swift reading of " + ", ".join(unknown)
            + "; add it to NAMED_LISTS or SERVER_ONLY in scripts/generate_swift_contract.py")
    missing = sorted(set(lists) - set(LIST_NAMES))
    if missing:
        raise Problem(
            "registry.json lists: no Swift name for " + ", ".join(missing)
            + "; add it to LIST_NAMES in scripts/generate_swift_contract.py")

    for key, field, swift_name in NAMED_LISTS:
        entries = registry.get(key)
        if not isinstance(entries, list):
            raise Problem(f"registry.json: {key} is missing")
        values = [entry[field] if field else entry for entry in entries]
        extra = ""
        if key == "release_reasons":
            extra = switch_property(
                "isChosenBySeat: Bool",
                "Whether a seat may send it with a release (`chosen_by: seat`).",
                [(entry["reason"], "true" if entry["chosen_by"] == "seat" else "false") for entry in entries])
        elif key == "credential_providers":
            extra = switch_property(
                "facts: (kind: CredentialKind, group: ProviderGroup)",
                "The provider's credential kind and provider group.",
                [(entry["provider"], f"(.{case_name(entry['kind'])}, .{case_name(entry['provider_group'])})")
                 for entry in entries])
            extra += "\n\n    public var kind: CredentialKind { facts.kind }"
            extra += "\n    public var group: ProviderGroup { facts.group }"
        blocks.append(enum_block(swift_name, values, f"registry.json `{key}`.", extra=extra))

    for key in sorted(lists):
        blocks.append(enum_block(LIST_NAMES[key], lists[key], f"registry.json `lists.{key}`."))
    return blocks


def operation_enum(registry):
    operations = registry.get("operations")
    if not isinstance(operations, list) or not operations:
        raise Problem("registry.json: operations is missing")
    methods = []
    rows = []
    for entry in operations:
        method = entry.get("method")
        if method not in ("GET", "POST"):
            raise Problem(f"registry.json operations: {entry.get('operation_id')} has method {method!r}; "
                          "the contract allows GET and POST")
        if method not in methods:
            methods.append(method)
        path = entry["path"]
        if not path.startswith("/") or '"' in path or "\\" in path:
            raise Problem(f"registry.json operations: {entry['operation_id']} has path {path!r}")
        rows.append((entry["operation_id"],
                     f'(.{method.lower()}, "{path}", .{case_name(entry["caller"])}, .{case_name(entry["tag"])})'))
    # The case is the method in lower case; its raw value is the method.
    method_block = enum_block(
        "HTTPMethod", sorted(m.lower() for m in methods), "The methods the contract allows.",
        conformances="String, CaseIterable, Sendable", raw_values={m.lower(): m for m in methods})
    info = switch_property(
        "info: (method: HTTPMethod, path: String, caller: OperationCaller, tag: OperationTag)",
        "The operation's method, path template, caller and tag.", rows)
    extra = info + """

    public var method: HTTPMethod { info.method }
    /// The path with its parameters in braces, as `{id}`.
    public var path: String { info.path }
    public var caller: OperationCaller { info.caller }
    public var tag: OperationTag { info.tag }"""
    block = enum_block(
        "ContractOperation", [entry["operation_id"] for entry in operations],
        "registry.json `operations`: every HTTP call of the contract.",
        conformances="String, CaseIterable, Sendable", extra=extra)
    return [method_block, block]


def openapi_enums(openapi):
    schemas = openapi.get("components", {}).get("schemas", {})
    blocks = []
    for swift_name, component, path, comment in OPENAPI_ENUMS:
        node = schemas.get(component)
        where = f"openapi.json {component}.{'.'.join(path)}"
        for key in path:
            node = (node or {}).get("properties", {}).get(key)
        if not node or "enum" not in node:
            raise Problem(f"{where}: no enum there")
        values = [value for value in node["enum"] if value is not None]
        blocks.append(enum_block(swift_name, values, f"{comment} ({where})"))
    return blocks


def generate(registry, openapi):
    blocks = registry_enums(registry) + operation_enum(registry) + openapi_enums(openapi)
    return HEADER + "\n" + "\n\n".join(blocks) + "\n"


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true", help="compare with the file and write nothing")
    parser.add_argument("--registry", type=Path, default=DEFAULT_REGISTRY)
    parser.add_argument("--openapi", type=Path, default=DEFAULT_OPENAPI)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    arguments = parser.parse_args(argv)
    try:
        registry = json.loads(arguments.registry.read_text(encoding="utf-8"))
        openapi = json.loads(arguments.openapi.read_text(encoding="utf-8"))
        text = generate(registry, openapi)
    except (OSError, ValueError, KeyError, TypeError, Problem) as error:
        print(f"generate_swift_contract: {error}", file=sys.stderr)
        return 1
    if arguments.check:
        if not arguments.output.exists():
            print(f"{arguments.output.name} is missing: run python3 -I scripts/generate_swift_contract.py",
                  file=sys.stderr)
            return 1
        if arguments.output.read_text(encoding="utf-8") != text:
            print(f"{arguments.output.name} differs from the contract: "
                  "run python3 -I scripts/generate_swift_contract.py and commit the result",
                  file=sys.stderr)
            return 1
        print(f"{arguments.output.name} matches the contract")
        return 0
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(text, encoding="utf-8")
    print(f"wrote {arguments.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
