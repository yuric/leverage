#!/usr/bin/env python3
"""Self-test for generate_swift_contract.py.

Runs the generator on the real registry and interface schema, whose output
must equal the committed Swift file, and on doctored copies written to a
temporary folder, each of which must change the output or fail and say
why. Each case is a drift the generator or its --check must catch, or a
naming it could get wrong.

Usage: python3 scripts/test_generate_swift_contract.py [-v]
Standard library only; exits 0 when every case behaves as expected.
"""

import copy
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
SCRIPT = HERE / "generate_swift_contract.py"
REGISTRY = ROOT / "api" / "contract" / "registry.json"
OPENAPI = ROOT / "api" / "contract" / "openapi.json"
HOOKS = ROOT / "api" / "contract" / "hooks.json"
READERS = ROOT / "api" / "contract" / "readers.json"
OUTPUT = ROOT / "mac" / "Sources" / "LeverageKit" / "Generated" / "Contract.swift"
AGENT_TOOLS = OUTPUT.with_name("AgentTools.swift")
ROLES = ROOT / "api" / "contract" / "roles.json"
VERBOSE = "-v" in sys.argv[1:]


def load(path):
    return json.loads(path.read_text(encoding="utf-8"))


def run(registry, openapi, *arguments, output_text=None, hooks=None, readers=None):
    """Run the generator on the given objects; return (code, output, Swift)."""
    with tempfile.TemporaryDirectory() as folder:
        registry_path = Path(folder) / "registry.json"
        openapi_path = Path(folder) / "openapi.json"
        hooks_path = Path(folder) / "hooks.json"
        readers_path = Path(folder) / "readers.json"
        output_path = Path(folder) / "Contract.swift"
        registry_path.write_text(json.dumps(registry), encoding="utf-8")
        openapi_path.write_text(json.dumps(openapi), encoding="utf-8")
        hooks_path.write_text(json.dumps(hooks if hooks is not None else load(HOOKS)), encoding="utf-8")
        if readers is not None:
            readers_path.write_text(json.dumps(readers), encoding="utf-8")
            arguments = ("--readers", str(readers_path), *arguments)
        if output_text is not None:
            output_path.write_text(output_text, encoding="utf-8")
        result = subprocess.run(
            [sys.executable, "-I", str(SCRIPT),
             "--registry", str(registry_path), "--openapi", str(openapi_path),
             "--hooks", str(hooks_path), "--output", str(output_path), *arguments],
            capture_output=True, text=True, check=False)
        swift = output_path.read_text(encoding="utf-8") if output_path.exists() else None
    return result.returncode, result.stdout + result.stderr, swift


def check_agent_tools(cases, registry, openapi):
    tools_text = AGENT_TOOLS.read_text(encoding="utf-8") if AGENT_TOOLS.exists() else ""
    quoted = r'("(?:[^"\\]|\\.)*")'
    rows = re.findall(
        rf"^        \.init\(id: {quoted}, method: \.(get|post), path: {quoted}, "
        rf"summary: {quoted}, inputSchema: {quoted}, roles: \[([^\]]*)\]\),$",
        tools_text, re.MULTILINE)
    operations = [op for op in registry["operations"] if op["tag"] == "agent"]
    cases.check("AgentTools.swift has all 25 agent operations in registry order (get_join included, GA-12)",
                [json.loads(row[0]) for row in rows] == [op["operation_id"] for op in operations]
                and len(rows) == 25, f"found {len(rows)} tool declarations")
    roles = load(ROLES)["roles"]
    for raw_id, method, raw_path, raw_summary, raw_schema, role_list in rows:
        tool_id = json.loads(raw_id)
        path = json.loads(raw_path)
        summary = json.loads(raw_summary)
        schema = json.loads(json.loads(raw_schema))
        op = next((op for op in operations if op["operation_id"] == tool_id), None)
        cases.check(f"{tool_id} matches the registry method and path",
                    op and (method.upper(), path) == (op["method"], op["path"]))
        if not op:
            continue
        interface = openapi["paths"][op["path"]][op["method"].lower()]
        cases.check(f"{tool_id} matches the interface summary", summary == interface["summary"])
        cases.check(f"{tool_id} lists the roles allowed by roles.json",
                    role_list == ", ".join("." + role["role"] for role in roles
                                           if tool_id in role["operations"]))
        cases.check(f"{tool_id} has an object schema with every reference resolved",
                    schema["type"] == "object" and '"$ref"' not in json.dumps(schema))
        path_fields = set(re.findall(r"\{(\w+)\}", path))
        body = interface.get("requestBody", {}).get("content", {}).get("application/json", {}).get("schema", {})
        if "$ref" in body:
            body = openapi["components"]["schemas"][body["$ref"].split("/")[-1]]
        expected_fields = path_fields | set(body.get("required", []))
        cases.check(f"{tool_id} requires every path and required body field",
                    expected_fields <= set(schema.get("properties", {}))
                    and expected_fields <= set(schema.get("required", [])))
        if tool_id == "submit_job_result":
            result = schema.get("properties", {}).get("result", {})
            cases.check("submit_job_result retains its four resolved result alternatives and path id",
                        "id" in schema.get("required", []) and len(result.get("oneOf", [])) == 4
                        and {"outcome", "answer", "basis"} in [
                            set(alternative.get("required", [])) for alternative in result["oneOf"]])


def check_role_facts(cases):
    """AgentTools.swift gives each seat role the roles it acts as and whether
    it gets a role file, from roles.json (contract decisions GA-1, GA-2)."""
    tools_text = AGENT_TOOLS.read_text(encoding="utf-8") if AGENT_TOOLS.exists() else ""
    roles = load(ROLES)["roles"]
    for property_name, value in (
        ("actsAs: [SeatRole]", lambda role: "[" + ", ".join("." + name for name in role["acts_as"]) + "]"),
        ("hasRoleFile: Bool", lambda role: "true" if role["role_file"] else "false"),
    ):
        match = re.search(rf"^    public var {re.escape(property_name)} \{{\n(.*?)^    \}}",
                          tools_text, re.MULTILINE | re.DOTALL)
        body = match[1] if match else ""
        entries = dict(re.findall(r"^        case \.(\w+): return (.*)$", body, re.MULTILINE))
        cases.check(f"SeatRole.{property_name} has one case per role of roles.json",
                    len(entries) == len(roles) and len(roles) > 0, body)
        for role in roles:
            cases.check(f"SeatRole.{property_name} matches roles.json for {role['role']}",
                        entries.get(role["role"]) == value(role) if "acts_as" in role and "role_file" in role
                        else False, entries.get(role["role"], "missing"))


def check_readers(cases, swift, readers):
    for property_name, values in (
        ("testedToolVersions", lambda reader: reader["tested_tool_versions"]),
        ("figureLabels", lambda reader: [figure["label"] for figure in reader["figures"]]),
    ):
        property_match = re.search(
            rf"^    public var {property_name}: \[String\] \{{\n(.*?)^    \}}",
            swift, re.MULTILINE | re.DOTALL)
        body = property_match[1] if property_match else ""
        entries = re.findall(r"^        case \.(\w+): return (\[.*\])$", body, re.MULTILINE)
        actual = {name: json.loads(array) for name, array in entries}
        cases.check(f"{property_name} has exactly one case for each of the nine readers",
                    len(entries) == len(actual) == len(readers) == 9)
        for reader in readers:
            provider = reader["provider"]
            name = re.sub(r"_(.)", lambda match: match[1].upper(), provider)
            cases.check(f"{property_name} matches readers.json for {provider}",
                        actual.get(name) == values(reader))


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
            print(f"FAIL {name}\n{detail}")


def main():
    cases = Cases()
    registry = load(REGISTRY)
    openapi = load(OPENAPI)

    # The committed file is a fresh run of the generator on the real files.
    result = subprocess.run(
        [sys.executable, "-I", str(SCRIPT), "--check"],
        capture_output=True, text=True, check=False)
    cases.check("the committed Contract.swift equals a fresh run",
                result.returncode == 0, result.stdout + result.stderr)

    code, out, swift = run(registry, openapi)
    cases.check("generates from the real files", code == 0 and swift is not None, out)
    swift = swift or ""
    committed = OUTPUT.read_text(encoding="utf-8") if OUTPUT.exists() else ""
    cases.check("a run into another folder writes the committed text",
                swift == committed, "the outputs differ")

    check_agent_tools(cases, registry, openapi)
    check_role_facts(cases)
    readers = load(READERS)
    check_readers(cases, swift, readers["readers"])

    doctored_readers = copy.deepcopy(readers)
    codex = next(reader for reader in doctored_readers["readers"] if reader["provider"] == "codex")
    codex["capture"]["usage"] = "recorded"
    codex["tested_tool_versions"] = ["9.8.7", "9.8.8"]
    codex["figures"][0]["label"] = '5-hour "window"'
    code, out, new_swift = run(registry, openapi, readers=doctored_readers)
    cases.check("generates from changed reader metadata", code == 0 and new_swift is not None, out)
    check_readers(cases, new_swift or "", doctored_readers["readers"])
    code, out, _ = run(registry, openapi, "--check", output_text=committed, readers=doctored_readers)
    cases.check("--check fails when reader metadata changed", code == 1 and "Contract.swift differs" in out, out)

    doctored_readers["readers"].pop()
    code, out, _ = run(registry, openapi, readers=doctored_readers)
    cases.check("a missing provider reader fails", code == 1 and "one reader per provider" in out, out)

    cases.check("important event types are exposed as a typed list in registry order",
                "importantEventTypes: [EventType] = [" + ", ".join(
                    "." + re.sub(r"[._](.)", lambda match: match[1].upper(), event)
                    for event in registry["lists"]["important_event_types"]) + "]" in swift)

    code2, _, swift2 = run(registry, openapi)
    cases.check("two runs write the same text", code2 == 0 and swift == swift2)

    cases.check("says it is generated and from what",
                "Generated by scripts/generate_swift_contract.py" in swift
                and "Do not edit" in swift, swift[:400])

    # Naming: snake case and dotted values become lower camel case, with the
    # value kept as the raw value where the two differ.
    for line in [
        "public enum TaskState: String, Codable, CaseIterable, Sendable {",
        "    case imaginarium\n",
        '    case inReview = "in_review"',
        '    case taskClaimed = "task.claimed"',
        '    case claimNextTask = "claim_next_task"',
        '    case notEligible = "not_eligible"',
        '    case claudeApi = "claude_api"',
        "public enum CommandName: String, Codable, CaseIterable, Sendable {",
        "public enum ContractOperation: String, CaseIterable, Sendable {",
        'case .claimNextTask: return (.post, "/v1/tasks/claim-next", .builder, .agent)',
        'case .issueLandingPrompt: return (.post, "/v1/owner/seats/{id}/landing-prompt", .owner, .owner)',
        'case .getJoin: return (.get, "/v1/join", .any, .agent)',
        '    case issueLandingPrompt = "issue_landing_prompt"',
        "public enum TransportErrorCode: String, Codable, CaseIterable, Sendable {",
        '    case keyReused = "key_reused"',
        "public enum HelperCheck: String, Codable, CaseIterable, Sendable {",
        '    case waitingForSignIn = "waiting_for_sign_in"',
    ]:
        cases.check(f"writes {line.strip()!r}", line in swift)

    cases.check("a provider knows its kind and group",
                "case .claudeApi: return (.apiToken, .anthropic)" in swift)
    cases.check("a release reason says whether a seat may choose it",
                "case .seatRemoved: return false" in swift
                and "case .stopping: return true" in swift)
    cases.check("a hold reason says whether it puts a task in Blocked",
                "public var isInBlocked: Bool" in swift
                and "case .roundsExceeded: return true" in swift
                and "case .seatPaused: return false" in swift)
    cases.check("the null of a nullable enum is not a case",
                "case null" not in swift and "case `null`" not in swift)

    # A value added to the registry changes the output, and --check fails.
    doctored = copy.deepcopy(registry)
    doctored["lists"]["task_states"].append("parked_for_later")
    code, out, new_swift = run(doctored, openapi)
    cases.check("a new list value is generated",
                code == 0 and '    case parkedForLater = "parked_for_later"' in (new_swift or ""), out)
    code, out, _ = run(doctored, openapi, "--check", output_text=committed)
    cases.check("--check fails when the registry gained a value",
                code == 1 and "Contract.swift" in out and "generate_swift_contract.py" in out, out)

    code, out, _ = run(registry, openapi, "--check")
    cases.check("--check fails when the file is missing", code == 1 and "missing" in out, out)

    code, out, _ = run(registry, openapi, "--check", output_text=committed + "// edited\n")
    cases.check("--check fails on a hand edit", code == 1, out)

    # A Swift keyword is escaped.
    doctored = copy.deepcopy(registry)
    doctored["lists"]["priorities"].append("default")
    code, out, new_swift = run(doctored, openapi)
    cases.check("a Swift keyword is escaped",
                code == 0 and "    case `default`\n" in (new_swift or ""), out)

    # Failures that must be loud.
    doctored = copy.deepcopy(registry)
    doctored["lists"]["parking_spots"] = ["a", "b"]
    code, out, _ = run(doctored, openapi)
    cases.check("a list with no Swift name fails and names it",
                code == 1 and "parking_spots" in out, out)

    doctored = copy.deepcopy(registry)
    doctored["mystery_table"] = []
    code, out, _ = run(doctored, openapi)
    cases.check("an unknown registry key fails and names it",
                code == 1 and "mystery_table" in out, out)

    doctored = copy.deepcopy(registry)
    doctored["lists"]["priorities"] += ["very_high", "very.high"]
    code, out, _ = run(doctored, openapi)
    cases.check("two values with one Swift name fail",
                code == 1 and "veryHigh" in out, out)

    doctored = copy.deepcopy(registry)
    doctored["operations"][0] = dict(doctored["operations"][0], method="DELETE")
    code, out, _ = run(doctored, openapi)
    cases.check("a method other than GET or POST fails",
                code == 1 and "DELETE" in out, out)

    doctored = copy.deepcopy(openapi)
    del doctored["components"]["schemas"]["HelperCheckProgress"]["properties"]["state"]
    code, out, _ = run(registry, doctored)
    cases.check("a missing interface enum fails and names it",
                code == 1 and "HelperCheckProgress" in out, out)

    doctored = copy.deepcopy(registry)
    doctored["lists"]["task_states"].append("Not Snake")
    code, out, _ = run(doctored, openapi)
    cases.check("a value that is not snake case fails", code == 1 and "Not Snake" in out, out)

    # The Rule checks milestone's additions (milestone 4 plan section 2.2):
    # the hooks and their moment names, a list that names providers, and the
    # closed values of the new shapes.
    for line in [
        "public enum RuleHook: String, Codable, CaseIterable, Sendable {",
        '    case taskBeforeReady = "task.before_ready"',
        '    case costReported = "cost.reported"',
        '        case .taskBeforeReady: return "when a task is ready to start"',
        '        case .taskBeforeDone: return "when the review has passed"',
        '        case .costReported: return "when spending is reported"',
        "    public var isCustomAllowed: Bool {",
        "        case .taskBeforeClaim: return true",
        "        case .reviewAssign: return false",
        "public enum ContractLists {",
        "    public static let orchestratorTestedProviders: [Provider] = [",
        "public enum CheckVerdict: String, Codable, CaseIterable, Sendable {",
        '    case notApplicable = "not_applicable"',
        "public enum DraftState: String, Codable, CaseIterable, Sendable {",
        '    case notWritten = "not_written"',
        "public enum JobKind: String, Codable, CaseIterable, Sendable {",
        '    case contractDraft = "contract_draft"',
        "public enum QuotedLabel: String, Codable, CaseIterable, Sendable {",
        '    case handoffNote = "handoff_note"',
        "public enum RuleEffect: String, Codable, CaseIterable, Sendable {",
        '    case passedToOwner = "passed_to_owner"',
        '    case installShippedRules = "install_shipped_rules"',
    ]:
        cases.check(f"writes {line.strip()!r}", line in swift, line)
    cases.check("a list of providers is no enum", "enum OrchestratorTestedProvider" not in swift)
    cases.check("the providers tested as a General seat are written, as a list (GA-11)",
                "generalTestedProviders: [Provider] = []" in swift and "enum GeneralTestedProvider" not in swift)
    cases.check("the landing prompt is no longer a read", "getLandingPrompt" not in swift)

    doctored = copy.deepcopy(registry)
    doctored["lists"]["general_tested_providers"] = ["claude_api"]
    code, out, _ = run(doctored, openapi)
    cases.check("a General-tested provider that is not a login fails and names it",
                code == 1 and "claude_api" in out and "login" in out, out)

    # The list's committed values are the managing agent's eval results, so
    # what an empty list gives is asked of a doctored registry, not of the
    # committed one.
    doctored = copy.deepcopy(registry)
    doctored["lists"]["orchestrator_tested_providers"] = []
    code, out, new_swift = run(doctored, openapi)
    cases.check("a list that names no provider is written as an empty list",
                code == 0 and "orchestratorTestedProviders: [Provider] = []" in (new_swift or "")
                and "enum OrchestratorTestedProvider" not in (new_swift or ""), out)

    doctored = copy.deepcopy(registry)
    doctored["lists"]["orchestrator_tested_providers"] = ["claude", "gemini"]
    code, out, new_swift = run(doctored, openapi)
    cases.check("a list of providers is written as providers, in its order",
                code == 0 and "orchestratorTestedProviders: [Provider] = [.claude, .gemini]" in (new_swift or ""), out)

    doctored = copy.deepcopy(registry)
    doctored["lists"]["orchestrator_tested_providers"] = ["claude", "no_such_provider"]
    code, out, _ = run(doctored, openapi)
    cases.check("a provider the registry does not know fails and names it",
                code == 1 and "no_such_provider" in out, out)

    doctored = copy.deepcopy(registry)
    doctored["lists"]["orchestrator_tested_providers"] = ["claude_api"]
    code, out, _ = run(doctored, openapi)
    cases.check("a provider that is not a login fails and names it",
                code == 1 and "claude_api" in out and "login" in out, out)

    doctored = copy.deepcopy(registry)
    doctored["lists"]["orchestrator_tested_providers"] = ["claude", "claude"]
    code, out, _ = run(doctored, openapi)
    cases.check("a provider listed twice fails", code == 1 and "twice" in out, out)

    hooks = load(HOOKS)
    doctored_hooks = copy.deepcopy(hooks)
    doctored_hooks["hooks"][0]["moment_name"] = "when a task is about to start"
    code, out, new_swift = run(registry, openapi, hooks=doctored_hooks)
    cases.check("a changed moment name is written",
                code == 0 and 'case .taskBeforeReady: return "when a task is about to start"' in (new_swift or ""), out)
    code, out, _ = run(registry, openapi, "--check", output_text=committed, hooks=doctored_hooks)
    cases.check("--check fails when a moment name changed", code == 1, out)

    doctored_hooks = copy.deepcopy(hooks)
    del doctored_hooks["hooks"][1]["moment_name"]
    code, out, _ = run(registry, openapi, hooks=doctored_hooks)
    cases.check("a hook with no moment name fails and names it",
                code == 1 and "task.before_claim" in out and "moment_name" in out, out)

    doctored_hooks = copy.deepcopy(hooks)
    doctored_hooks["hooks"] = doctored_hooks["hooks"][1:]
    code, out, _ = run(registry, openapi, hooks=doctored_hooks)
    cases.check("a registry hook that hooks.json lacks fails and names it",
                code == 1 and "task.before_ready" in out, out)

    doctored_hooks = copy.deepcopy(hooks)
    doctored_hooks["hooks"].append(dict(doctored_hooks["hooks"][0], hook="task.after_done"))
    code, out, _ = run(registry, openapi, hooks=doctored_hooks)
    cases.check("a hook that only hooks.json names fails and names it",
                code == 1 and "task.after_done" in out, out)

    doctored_hooks = copy.deepcopy(hooks)
    doctored_hooks["hooks"][1]["moment_name"] = doctored_hooks["hooks"][0]["moment_name"]
    code, out, _ = run(registry, openapi, hooks=doctored_hooks)
    cases.check("two hooks with one moment name fail", code == 1 and "moment" in out, out)

    doctored = copy.deepcopy(registry)
    doctored["custom_rule_hooks"].append("review.assign")
    code, out, new_swift = run(doctored, openapi)
    cases.check("a hook the registry lets an owner's rule use is custom",
                code == 0 and "        case .reviewAssign: return true" in (new_swift or ""), out)

    doctored = copy.deepcopy(registry)
    doctored["custom_rule_hooks"].append("task.after_done")
    code, out, _ = run(doctored, openapi)
    cases.check("a custom hook that is no hook fails and names it",
                code == 1 and "task.after_done" in out, out)

    print(f"{cases.count - len(cases.failures)}/{cases.count} cases passed")
    return 1 if cases.failures else 0


if __name__ == "__main__":
    sys.exit(main())
