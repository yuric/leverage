import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

struct CredentialsHarnessTests {
    @Test("The helper launch keeps standard input open for local credential messages")
    func helperInput() async throws {
        let child = try RunningHelper.launch(.init(
            executable: "/bin/cat", arguments: [], environment: [:],
            timeLimit: Patience.scaled(.seconds(30))))
        try await withCleanup {
            let message = LocalHelperMessage.forget(credentialID: UUID())
            let line = try message.encodeLine()
            try await child.writeLine(line)
            child.closeInput()
            let result = await child.wait()
            #expect(result.succeeded)
            #expect(result.standardOutput == line + Data([0x0a]))
        } cleanup: {
            child.stop()
            _ = await child.wait()
        }
    }

    @Test("The stand-in provider API endpoint uses the port it published")
    func assignedPort() throws {
        let folder = try TemporaryFolder(prefix: "provider-api-port")
        let portFile = folder.url.appendingPathComponent("port")
        #expect(try RunningProviderAPI.endpoint(from: portFile) == nil)
        try Data("49155\n".utf8).write(to: portFile)
        #expect(try RunningProviderAPI.endpoint(from: portFile)?.absoluteString == "http://127.0.0.1:49155")
        try Data("0\n".utf8).write(to: portFile)
        #expect(throws: EndToEndFailure.self) { try RunningProviderAPI.endpoint(from: portFile) }
    }
}
