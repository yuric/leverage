import Foundation
import LeverageKit

/// Opens the provider's own sign-in and goes on by itself once the account
/// is signed in, with no Retry (L604, L716, PV-4, CL-19). The helper runs the
/// tool's sign-in command with the account's folder variable and standard
/// input closed, and looks at the status until it says signed in or the
/// wait ends. leverage never sees a password, a link or a code: the
/// command's output is never read.
///
/// A provider with no sign-in command (Antigravity) gets no window: the
/// owner signs in on this Mac, and the look, a repeated test prompt, notices.
struct SignInWindow: Sendable {
    let locator: ToolLocator
    let timings: HelperTimings

    /// True once `look` says signed in; false when the wait ends first or
    /// the task is cancelled. Any sign-in command still running then is
    /// ended.
    func waitForSignIn(
        _ entry: ProviderEntry, tool: LocatedTool, accountFolder: URL?,
        look: @Sendable () async -> Bool
    ) async -> Bool {
        var window: RunningSubprocess?
        if let arguments = entry.signIn.value.arguments {
            window = try? Subprocess.start(SubprocessRequest(
                executable: tool.path, arguments: arguments,
                environment: locator.toolEnvironment(entry, toolPath: tool.path, accountFolder: accountFolder),
                timeLimit: timings.waitAtMost, gracePeriod: .seconds(2), maximumOutputBytes: 64 << 10))
        }
        defer { window?.stop() }

        let every: Duration
        if case .testPrompt = entry.status.value.reading {
            every = timings.promptEvery
        } else {
            every = timings.lookEvery
        }
        return await Waiting.until(every: every, atMost: timings.waitAtMost, look)
    }
}

/// Looking again and again until something holds (CL-19).
enum Waiting {
    /// Looks at once and then every `every`, until `look` is true (true),
    /// or `atMost` has passed or the task is cancelled (false).
    static func until(every: Duration, atMost: Duration, _ look: @Sendable () async -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + atMost
        while !Task.isCancelled {
            if await look() { return true }
            let next = clock.now + every
            guard next < deadline else { break }
            try? await Task.sleep(until: next, clock: clock)
        }
        return false
    }
}
