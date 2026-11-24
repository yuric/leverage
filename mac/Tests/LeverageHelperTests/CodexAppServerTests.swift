import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

@testable import LeverageHelper

@Suite("Codex app-server", .timeLimit(.minutes(Patience.minutes(1))))
struct CodexAppServerTests {
    @Test("usage sends only the handshake and the two parameterless reads")
    func usageCalls() async throws {
        let rig = try HelperRig()
        let account = try makeAccount(rig)
        let actual = try await CodexUsageReader().read(account)

        #expect(actual.state == .ok)
        #expect(try rig.tools.calls().map(\.argv) == [["app-server"]])
        let calls = try messages(rig)
        #expect(calls.compactMap { $0["method"]?.stringValue } == [
            "initialize", "initialized", "account/rateLimits/read", "account/usage/read",
        ])
        try #require(calls.count == 4)
        #expect(calls[0]["params"]?["clientInfo"]?["name"] == .string("leverage"))
        #expect(calls[0]["params"]?["clientInfo"]?["version"] == .string(leverageMacVersion))
        #expect(calls[1]["id"] == nil)
        #expect(calls.dropFirst().allSatisfy { $0["params"] == nil })

        let requestMethods = CodexAppServer.Method.allCases.map(\.rawValue)
        #expect(requestMethods == ["initialize", "account/read", "account/rateLimits/read", "account/usage/read"])
        #expect(!requestMethods.contains { method in
            ["consume", "logout", "login", "nudge"].contains { method.lowercased().contains($0) }
        })
    }

    @Test("account facts use account/read with token refresh disabled")
    func accountRead() async throws {
        let rig = try HelperRig()
        let account = try makeAccount(rig)
        let result = await CodexAppServer.account(account)
        #expect(result != nil)
        let calls = try messages(rig)
        #expect(calls.compactMap { $0["method"]?.stringValue } == ["initialize", "initialized", "account/read"])
        #expect(calls.last?["params"] == .object(["refreshToken": .bool(false)]))
    }

    @Test("a mismatched home stops the session at initialize")
    func homeMustMatch() async throws {
        let rig = try HelperRig()
        let account = try makeAccount(rig, codexHome: rig.home)
        let reading = try await CodexUsageReader().read(account)

        #expect(reading == UsageReading(state: .unavailable))
        #expect(try messages(rig).compactMap { $0["method"]?.stringValue } == ["initialize"])
    }

    @Test("a server request sharing the initialize id receives no response")
    func serverRequest() async throws {
        let rig = try HelperRig()
        let account = try makeAccount(rig, reply: "codex/usage-server-request.json")
        let fixture = rig.tools.replies.appendingPathComponent("codex/usage-server-request.json")
        let original = try Data(contentsOf: rig.tools.replies.appendingPathComponent("codex/usage-both-windows.json"))
        var reply = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        reply["server_messages"] = [["id": 1, "method": "item/tool/call"]]
        try JSONSerialization.data(withJSONObject: reply).write(to: fixture)
        let reading = try await CodexUsageReader().read(account)

        #expect(reading.state == .ok)
        #expect(try messages(rig).map { $0["method"]?.stringValue } == [
            "initialize", "initialized", "account/rateLimits/read", "account/usage/read",
        ])
    }

    @Test("an RPC error is unavailable and the session sends no further requests")
    func errorReply() async throws {
        let rig = try HelperRig()
        let account = try makeAccount(rig, reply: "codex/usage-rpc-error.json")
        let reading = try await CodexUsageReader().read(account)

        #expect(reading == UsageReading(state: .unavailable))
        #expect(try messages(rig).compactMap { $0["method"]?.stringValue } == [
            "initialize", "initialized", "account/rateLimits/read",
        ])
    }

    @Test("completed replies survive EOF, a shutdown error, or a server waiting after EOF",
          arguments: ["clean", "error", "wait", "truncated", "cancel"])
    func closesAndReaps(afterEOF: String) async throws {
        let rig = try HelperRig()
        let account = try makeAccount(rig)
        // This stand-in waits for EOF before exiting. Its child retains the
        // output pipes and waits for the test runner, so the server's death
        // alone cannot account for its exit while this assertion is running.
        let standIn = """
            #!/usr/bin/env python3
            import json, os, pathlib, subprocess, sys, time

            child_code = '''
            import os, sys, time
            parent = int(sys.argv[1])
            while True:
                try:
                    os.kill(parent, 0)
                except ProcessLookupError:
                    break
                time.sleep(0.05)
            '''
            child = subprocess.Popen([
                sys.executable, "-I", "-c", child_code,
                "\(ProcessInfo.processInfo.processIdentifier)"
            ], stdin=subprocess.DEVNULL)
            pathlib.Path("pids").write_text(f"{os.getpid()} {child.pid}")
            replies = {
                "initialize": {"codexHome": os.environ["CODEX_HOME"]},
                "account/rateLimits/read": {"rateLimits": {}},
                "account/usage/read": {"summary": {}}
            }
            if "\(afterEOF)" == "truncated":
                sys.stderr.buffer.write(b"x" * ((8 << 20) + 1))
                sys.stderr.buffer.flush()
            for line in sys.stdin:
                call = json.loads(line)
                if "\(afterEOF)" == "cancel" and call["method"] == "account/usage/read":
                    pathlib.Path("last-read").touch()
                    while os.getppid() != 1:
                        time.sleep(0.05)
                if "id" in call:
                    print(json.dumps({"id": call["id"], "result": replies[call["method"]]}), flush=True)
            pathlib.Path("stdin-closed").touch()
            if "\(afterEOF)" == "wait":
                deadline = time.monotonic() + 3
                while os.getppid() != 1 and time.monotonic() < deadline:
                    time.sleep(0.05)
                pathlib.Path("server-wait-ended").touch()
            sys.exit(7 if "\(afterEOF)" == "error" else 0)
            """
        let tool = rig.tools.tool("codex")
        try Data(standIn.utf8).write(to: tool, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)

        let work = account.workingDirectory
        let task = Task { try await CodexUsageReader().read(account) }
        defer { task.cancel() }
        if afterEOF == "cancel" {
            try #require(await eventually(within: 30) {
                FileManager.default.fileExists(atPath: work.appendingPathComponent("last-read").path)
            })
            task.cancel()
        }
        let reading = try await task.value
        #expect(reading.state == (["truncated", "cancel"].contains(afterEOF) ? .unavailable : .ok))
        if afterEOF != "cancel" {
            #expect(FileManager.default.fileExists(atPath: work.appendingPathComponent("stdin-closed").path))
        }
        #expect(!FileManager.default.fileExists(atPath: work.appendingPathComponent("server-wait-ended").path))
        let pids = try String(contentsOf: work.appendingPathComponent("pids"), encoding: .utf8)
            .split(separator: " ").compactMap { Int32($0) }
        try #require(pids.count == 2)
        try #require(pids.allSatisfy { $0 > 1 })
        #expect(!isAlive(pids[0]))
        #expect(await eventually { !isAlive(pids[1]) })
    }

    private func messages(_ rig: HelperRig) throws -> [JSONValue] {
        let file = rig.tools.state.appendingPathComponent("app-server.jsonl")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map {
            try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8))
        }
    }

    private func makeAccount(
        _ rig: HelperRig, reply: String? = nil, codexHome: URL? = nil
    ) throws -> ReaderAccount {
        let folder = try rig.folders.createFresh(for: UUID())
        try rig.tools.signIn("codex", accountFolder: folder)
        try rig.tools.write(scenario: .init(usage: [
            .init(tool: "codex", account: folder, reply: reply, codexHome: codexHome),
        ]))
        let entry = try #require(ProviderCatalog.entry(for: "codex"))
        let tool = LocatedTool(path: rig.tools.tool("codex").path, version: "codex-cli 0.169.0")
        let locator = ToolLocator(settings: rig.settings, timings: fastTimings)
        return ReaderAccount(
            entry: entry, tool: tool, accountFolder: folder,
            environment: locator.toolEnvironment(entry, toolPath: tool.path, accountFolder: folder),
            workingDirectory: try rig.folder.folder("reads"),
            deadline: ContinuousClock.now + fastTimings.commandLimit)
    }
}
