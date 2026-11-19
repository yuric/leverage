import Foundation
import LeverageKit
import Observation

/// The one line at the foot of the pane (MA-23, L806): whether the timer
/// sweep is running on time, whether the agents are running on this Mac, and
/// whether leverage answers at all.
@MainActor
@Observable
final class HealthLineModel {
    enum Status: Equatable, Sendable {
        /// Nothing answered yet.
        case checking
        case running
        /// The sweep is more than two minutes late.
        case late
        /// The helper failed to start three times in a minute (PK-4).
        case agentsStopped
        /// The server does not answer.
        case unreachable
    }

    enum Tone: Equatable, Sendable { case neutral, good, warning, bad }

    private(set) var status: Status = .checking

    @ObservationIgnored private let owner: any OwnerAPI
    @ObservationIgnored private let helper: any HelperSupervising
    @ObservationIgnored private let interval: Duration

    init(owner: any OwnerAPI, helper: any HelperSupervising, interval: Duration = .seconds(15)) {
        self.owner = owner
        self.helper = helper
        self.interval = interval
    }

    var sentence: ShellCopy {
        switch status {
        case .checking: .healthChecking
        case .running: .healthRunning
        case .late: .healthLate
        case .agentsStopped: .healthAgentsStopped
        case .unreachable: .healthUnreachable
        }
    }

    var tone: Tone {
        switch status {
        case .checking: .neutral
        case .running: .good
        case .late, .agentsStopped: .warning
        case .unreachable: .bad
        }
    }

    /// Try again is offered once the helper has given up.
    var offersTryAgain: Bool { status == .agentsStopped }

    /// Reads the server's health and the helper's state once.
    func refresh() async {
        do {
            let health = try await owner.systemHealth()
            let helperState = await helper.state()
            if helperState == .stoppedTrying {
                status = .agentsStopped
            } else if health.sweepLate {
                status = .late
            } else {
                status = .running
            }
        } catch let error as TransportError where error.code == .unauthenticated {
            // The session ended; the app is returning to Sign in. Say nothing.
        } catch {
            if !Task.isCancelled { status = .unreachable }
        }
    }

    /// Starts the helper again after it gave up, then reads the line again.
    func tryAgain() async {
        _ = await helper.tryAgain()
        await refresh()
    }

    /// Reads on an interval until the task is cancelled.
    func run() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: interval)
        }
    }
}
