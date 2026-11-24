#!/usr/bin/env python3
"""Write the contract's fixed lists and agent tools for the Mac side.

api/contract/registry.json is the authority for the fixed lists,
api/contract/hooks.json for the hooks' moment names,
api/contract/readers.json for the readers' tested versions and figure labels, and
api/contract/openapi.json for the few closed values that only the interface
schema has. The generated files live in mac/Sources/LeverageKit/Generated
and are changed by updating the contract and running this script again
(rule AR-002). CI runs it with --check and compares both files.

What is written:

  * every list under the registry's "lists", each under the Swift name
    LIST_NAMES gives it (a list without one fails, so a new list is named
    on purpose);
  * the registry's named lists in NAMED_LISTS (commands, event types, hold
    reasons, refusals, check results, release reasons, next kinds, step
    kinds, Needs you items, credential providers), with the extra facts the
    Mac side reads: a provider's kind and group, whether a seat may
    choose a release reason, and whether a hold reason puts its task in
    Blocked;
  * the tested tool versions and figure labels for each provider's reader;
  * the hooks, as RuleHook, with each one's moment name (hooks.json) and
    whether an owner's rule may use it (registry `custom_rule_hooks`);
  * the lists that name values of another list, as constants in
    ContractLists (a list of providers is a list of `Provider`, which may
    be empty, so it is no enum);
  * the operations, as ContractOperation with each one's method, path,
    caller and tag, so that no path is typed in Swift (IN-1);
  * the interface schema's own enums in OPENAPI_ENUMS (transport error
    codes, helper checks and their states and failures, and a few more);
  * the agent tools, as AgentTools, from the registry's agent operations,
    roles.json, and the OpenAPI summaries and input schemas, and each seat
    role's acts_as and role_file from roles.json, as SeatRole.actsAs and
    SeatRole.hasRoleFile.

The registry keys in SERVER_ONLY (guards, timers' due-time sources, policy
effects, job kinds) are the server's machinery and are not written; `hooks`
and `custom_rule_hooks` are read for RuleHook.
Any other registry key fails, so nothing is left out silently.

A value becomes a lower camel case case name (`in_review` -> `inReview`,
`task.claimed` -> `taskClaimed`), with the value as its raw value where the
two differ; a Swift keyword is escaped with backticks. A value that is not
lower snake case (dots allowed), or two values with one case name, fail.

Usage:
  python3 scripts/generate_swift_contract.py           # write the file
  python3 scripts/generate_swift_contract.py --check   # compare, write nothing
Options --registry, --openapi, --hooks, --readers, --roles and --output replace the
paths for the self-test. AgentTools.swift is written beside --output.
Standard library only; exits 0 on success, 1 otherwise.
"""

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_REGISTRY = ROOT / "api" / "contract" / "registry.json"
DEFAULT_OPENAPI = ROOT / "api" / "contract" / "openapi.json"
DEFAULT_HOOKS = ROOT / "api" / "contract" / "hooks.json"
DEFAULT_READERS = ROOT / "api" / "contract" / "readers.json"
DEFAULT_ROLES = ROOT / "api" / "contract" / "roles.json"
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

# Lists under the registry's "lists" whose values name values of another list
# and that may be empty: (key, Swift constant, Swift type, the registry list
# that holds the values, what each value must be there). They are written as
# constants in ContractLists, not as enums.
LIST_REFERENCES = [
    ("orchestrator_tested_providers", "orchestratorTestedProviders", "Provider", "credential_providers",
     "provider", "login",
     "The login providers whose tool's default model passed the eval suite (RV-5). "
     "It refuses nothing: the app says \"Not tested for checking tasks.\" beside every other choice."),
    ("general_tested_providers", "generalTestedProviders", "Provider", "credential_providers",
     "provider", "login",
     "The login providers whose tool's default model passed both eval suites run as a General seat (GA-11). "
     "It refuses nothing: the app says \"Not tested for checking tasks.\" beside a General seat of every other provider."),
    ("important_event_types", "importantEventTypes", "EventType", "event_types",
     "type", None, "The event types shown by the Important filter in Activity."),
]

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

SERVER_ONLY = {"guards", "due_time_sources", "policy_effects", "job_kinds"}
HOOK_KEYS = {"hooks", "custom_rule_hooks"}

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
    ("CheckVerdict", "RuleCheckJobResult", ["result"], "What a checker may answer (RV-3)."),
    ("DraftState", "TaskPage", ["draft"], "Where a contract draft stands on the task page (RD-37)."),
    ("JobKind", "ClaimJobResult", ["kind"], "What a job asks of the seat that claims it."),
    ("QuotedLabel", "QuotedText", ["label"], "The label of a piece of task text a checker is given (RD-31)."),
    ("RuleEffect", "TaskRuleCheck", ["effect"], "What an applied rule did (RD-28)."),
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
// api/contract/registry.json, openapi.json, hooks.json and readers.json.
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
    known = {"lists", "operations"} | SERVER_ONLY | HOOK_KEYS | {key for key, _, _ in NAMED_LISTS}
    unknown = sorted(set(registry) - known)
    if unknown:
        raise Problem(
            "registry.json: no Swift reading of " + ", ".join(unknown)
            + "; add it to NAMED_LISTS or SERVER_ONLY in scripts/generate_swift_contract.py")
    references = {entry[0] for entry in LIST_REFERENCES}
    missing = sorted(set(lists) - set(LIST_NAMES) - references)
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
        elif key == "hold_reasons":
            extra = switch_property(
                "isInBlocked: Bool",
                "Whether an open hold of this reason puts its task in Blocked (`in_blocked`).",
                [(entry["reason"], "true" if entry["in_blocked"] else "false") for entry in entries])
        elif key == "credential_providers":
            extra = switch_property(
                "facts: (kind: CredentialKind, group: ProviderGroup)",
                "The provider's credential kind and provider group.",
                [(entry["provider"], f"(.{case_name(entry['kind'])}, .{case_name(entry['provider_group'])})")
                 for entry in entries])
            extra += "\n\n    public var kind: CredentialKind { facts.kind }"
            extra += "\n    public var group: ProviderGroup { facts.group }"
        blocks.append(enum_block(swift_name, values, f"registry.json `{key}`.", extra=extra))

    for key in sorted(set(lists) - references):
        blocks.append(enum_block(LIST_NAMES[key], lists[key], f"registry.json `lists.{key}`."))
    return blocks


def list_references(registry):
    """ContractLists: the lists that name values of another list."""
    lists = registry["lists"]
    lines = ["/// registry.json `lists` that name values of another list.", "public enum ContractLists {"]
    for key, constant, swift_type, source, field, kind, comment in LIST_REFERENCES:
        if key not in lists:
            raise Problem(f"registry.json lists: {key} is missing")
        values = lists[key]
        if not isinstance(values, list):
            raise Problem(f"registry.json lists: {key} is not a list")
        known = {entry[field]: entry for entry in registry.get(source, [])}
        for value in values:
            if value not in known:
                raise Problem(f"registry.json lists.{key}: {value!r} is not in {source}")
            if kind is not None and known[value].get("kind") != kind:
                raise Problem(f"registry.json lists.{key}: {value!r} is not a {kind}")
        if len(set(values)) != len(values):
            raise Problem(f"registry.json lists.{key}: a value is listed twice")
        cases = ", ".join(f".{case_name(value)}" for value in values)
        lines += [f"    /// registry.json `lists.{key}`. {comment}",
                  f"    public static let {constant}: [{swift_type}] = [{cases}]"]
    lines.append("}")
    return "\n".join(lines)


def hook_enum(registry, hooks):
    """RuleHook: the nine hooks, with their moment names and who may use them."""
    names = registry.get("hooks")
    if not isinstance(names, list):
        raise Problem("registry.json: hooks is missing")
    entries = {}
    for entry in hooks.get("hooks", []):
        entries[entry.get("hook")] = entry
    for name in names:
        if name not in entries:
            raise Problem(f"hooks.json: no entry for the hook {name}")
        moment = entries[name].get("moment_name")
        if not isinstance(moment, str) or not moment.strip() or '"' in moment or "\\" in moment:
            raise Problem(f"hooks.json: the hook {name} has no usable moment_name")
    for name in entries:
        if name not in names:
            raise Problem(f"hooks.json: the hook {name} is not in registry.json hooks")
    moments = [entries[name]["moment_name"] for name in names]
    if len(set(moments)) != len(moments):
        raise Problem("hooks.json: two hooks have one moment_name")
    custom = registry.get("custom_rule_hooks", [])
    for name in custom:
        if name not in names:
            raise Problem(f"registry.json custom_rule_hooks: {name} is not in hooks")
    extra = switch_property(
        "momentName: String", "When the hook runs, in the owner's words (hooks.json `moment_name`).",
        [(name, f'"{entries[name]["moment_name"]}"') for name in names])
    extra += "\n\n" + switch_property(
        "isCustomAllowed: Bool", "Whether an owner's own rule may use the hook (registry `custom_rule_hooks`).",
        [(name, "true" if name in custom else "false") for name in names])
    return enum_block("RuleHook", names, "registry.json `hooks`.", extra=extra)


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


def reader_properties(registry, readers):
    entries = readers["readers"]
    providers = [entry["provider"] for entry in registry["credential_providers"]]
    if [reader["provider"] for reader in entries] != providers:
        raise Problem("readers.json: expected one reader per provider in registry order")

    versions = []
    labels = []
    for reader in entries:
        provider = reader["provider"]
        versions.append((provider, "[" + ", ".join(
            swift_string(version) for version in reader["tested_tool_versions"]) + "]"))
        labels.append((provider, "[" + ", ".join(
            swift_string(figure["label"]) for figure in reader["figures"]) + "]"))
    properties = "\n\n".join([
        switch_property("testedToolVersions: [String]", "Tool versions this reader was tested against.", versions),
        switch_property("figureLabels: [String]", "Figure labels this reader may report.", labels),
    ])
    return "/// Reader metadata from readers.json.\nextension Provider {\n" + properties + "\n}"


def generate(registry, openapi, hooks, readers):
    blocks = (registry_enums(registry) + [hook_enum(registry, hooks), list_references(registry)]
              + operation_enum(registry) + openapi_enums(openapi) + [reader_properties(registry, readers)])
    return HEADER + "\n" + "\n\n".join(blocks) + "\n"


def resolve_references(node, document, chain=()):
    """Expand local OpenAPI references, including nested schema alternatives."""
    if isinstance(node, list):
        return [resolve_references(item, document, chain) for item in node]
    if not isinstance(node, dict):
        return node
    fields = {key: resolve_references(value, document, chain)
              for key, value in node.items() if key != "$ref"}
    if "$ref" not in node:
        return fields
    reference = node["$ref"]
    if not reference.startswith("#/") or reference in chain:
        raise Problem(f"openapi.json: cannot resolve {reference!r} inline")
    target = document
    for part in reference[2:].split("/"):
        target = target[part.replace("~1", "/").replace("~0", "~")]
    resolved = resolve_references(target, document, (*chain, reference))
    if resolved.keys() & fields.keys():
        # JSON Schema applies both keywords when a reference has siblings.
        return {"allOf": [resolved, fields]}
    return resolved | fields


def tool_input_schema(openapi, path, operation):
    path_item = openapi["paths"][path]
    parameters = {}
    for entry in path_item.get("parameters", []) + operation.get("parameters", []):
        parameter = resolve_references(entry, openapi)
        if parameter["in"] == "path":
            parameters[parameter["name"]] = parameter["schema"]

    body = resolve_references(operation.get("requestBody", {}), openapi)
    schema = body["content"]["application/json"]["schema"] if body else {
        "type": "object", "additionalProperties": False}
    if schema.get("type") != "object":
        raise Problem(f"openapi.json: {operation['operationId']} has a non-object request body")
    body_properties = schema.pop("properties", {})
    if parameters.keys() & body_properties.keys():
        raise Problem(f"openapi.json: {operation['operationId']} shares a path and body field")
    # Body examples alone do not represent complete tool arguments.
    if parameters:
        schema.pop("examples", None)
    schema["properties"] = parameters | body_properties
    schema["required"] = [*parameters, *schema.get("required", [])]
    return schema


def swift_string(value):
    # JSON's short escapes for these control characters differ from Swift's.
    encoded = json.dumps(value, ensure_ascii=False)
    return re.sub(r'\\(?:\\|u([0-9a-f]{4})|([bf]))',
                  lambda match: (match[0] if match[0] == r"\\"
                                 else r"\u{" + (match[1] or {"b": "8", "f": "c"}[match[2]]) + "}"),
                  encoded)


def generate_tools(registry, openapi, roles):
    lines = ["""\
// Generated by scripts/generate_swift_contract.py from
// api/contract/registry.json, api/contract/openapi.json and api/contract/roles.json.
// Do not edit: change the contract and run
//   python3 -I scripts/generate_swift_contract.py
// CI fails when this file differs from a fresh run (rule AR-002).

public struct AgentTool: Sendable {
    public let id: String
    public let method: HTTPMethod
    public let path: String
    public let summary: String
    public let inputSchema: String
    public let roles: [SeatRole]
}

public enum AgentTools {
    public static let all: [AgentTool] = ["""]
    for entry in registry["operations"]:
        if entry["tag"] != "agent":
            continue
        tool_id, method, path = entry["operation_id"], entry["method"].lower(), entry["path"]
        operation = openapi["paths"][path][method]
        if operation["operationId"] != tool_id:
            raise Problem(f"openapi.json: {method.upper()} {path} does not name {tool_id}")
        tool_roles = ", ".join(f".{case_name(role['role'])}" for role in roles["roles"]
                               if tool_id in role["operations"])
        if not tool_roles:
            raise Problem(f"roles.json: no role lists {tool_id}")
        schema = json.dumps(tool_input_schema(openapi, path, operation), separators=(",", ":"),
                            ensure_ascii=False)
        lines.append(f"        .init(id: {swift_string(tool_id)}, method: .{method}, "
                     f"path: {swift_string(path)}, summary: {swift_string(operation['summary'])}, "
                     f"inputSchema: {swift_string(schema)}, roles: [{tool_roles}]),")
    lines += ["    ]", "}", ""]
    lines += role_facts(roles)
    return "\n".join(lines)


def role_facts(roles):
    """The roles each seat role acts as and whether it gets a role file,
    from roles.json (contract decisions GA-1, GA-2)."""
    seat_roles = [role["role"] for role in roles["roles"]]
    for role in roles["roles"]:
        unknown = [name for name in role["acts_as"] if name not in seat_roles]
        if unknown:
            raise Problem(f"roles.json: {role['role']} acts as {', '.join(unknown)}, not a role")
        if not isinstance(role["role_file"], bool):
            raise Problem(f"roles.json: {role['role']}'s role_file is not true or false")
    acts_as = [(role["role"], "[" + ", ".join(f".{case_name(name)}" for name in role["acts_as"]) + "]")
               for role in roles["roles"]]
    role_file = [(role["role"], "true" if role["role_file"] else "false") for role in roles["roles"]]
    return [
        "extension SeatRole {",
        switch_property("actsAs: [SeatRole]",
                        "The roles whose work a seat of this role does (roles.json `acts_as`).", acts_as),
        "",
        switch_property("hasRoleFile: Bool",
                        "Whether a seat of this role gets a role file (roles.json `role_file`).", role_file),
        "",
        "    /// Whether a seat of this role does the work of `role`.",
        "    public func actsAs(_ role: SeatRole) -> Bool { actsAs.contains(role) }",
        "}",
        "",
    ]


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true", help="compare with the file and write nothing")
    parser.add_argument("--registry", type=Path, default=DEFAULT_REGISTRY)
    parser.add_argument("--openapi", type=Path, default=DEFAULT_OPENAPI)
    parser.add_argument("--hooks", type=Path, default=DEFAULT_HOOKS)
    parser.add_argument("--readers", type=Path, default=DEFAULT_READERS)
    parser.add_argument("--roles", type=Path, default=DEFAULT_ROLES)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    arguments = parser.parse_args(argv)
    try:
        registry = json.loads(arguments.registry.read_text(encoding="utf-8"))
        openapi = json.loads(arguments.openapi.read_text(encoding="utf-8"))
        hooks = json.loads(arguments.hooks.read_text(encoding="utf-8"))
        readers = json.loads(arguments.readers.read_text(encoding="utf-8"))
        roles = json.loads(arguments.roles.read_text(encoding="utf-8"))
        outputs = {
            arguments.output: generate(registry, openapi, hooks, readers),
            arguments.output.with_name("AgentTools.swift"): generate_tools(registry, openapi, roles),
        }
        for output, text in outputs.items():
            if arguments.check:
                if not output.exists():
                    raise Problem(f"{output.name} is missing: run python3 -I scripts/generate_swift_contract.py")
                if output.read_text(encoding="utf-8") != text:
                    raise Problem(f"{output.name} differs from the contract: "
                                  "run python3 -I scripts/generate_swift_contract.py and commit the result")
                print(f"{output.name} matches the contract")
            else:
                output.parent.mkdir(parents=True, exist_ok=True)
                output.write_text(text, encoding="utf-8")
                print(f"wrote {output}")
    except (OSError, ValueError, KeyError, TypeError, Problem) as error:
        print(f"generate_swift_contract: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
