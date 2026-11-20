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
        /// The daily backup is more than 26 hours old (HB-4).
        case backupLate
        /// The server does not answer.
        case unreachable
    }

    enum Tone: Equatable, Sendable { case neutral, good, warning, bad }

    private(set) var status: Status = .checking

    @ObservationIgnored private let owner: any OwnerAPI
    @ObservationIgnored private let helper: any HelperSupervising
    @ObservationIgnored private let server: (any ServerSupervising)?
    @ObservationIgnored private let interval: Duration

    init(
        owner: any OwnerAPI, helper: any HelperSupervising, server: (any ServerSupervising)? = nil,
        interval: Duration = .seconds(15)
    ) {
        self.owner = owner
        self.helper = helper
        self.server = server
        self.interval = interval
    }

    var sentence: ShellCopy {
        switch status {
        case .checking: .healthChecking
        case .running: .healthRunning
        case .late: .healthLate
        case .agentsStopped: .healthAgentsStopped
        case .backupLate: .healthBackupLate
        case .unreachable: .healthUnreachable
        }
    }

    var tone: Tone {
        switch status {
        case .checking: .neutral
        case .running: .good
        case .late, .agentsStopped, .backupLate: .warning
        case .unreachable: .bad
        }
    }

    /// Try again is offered once the helper has given up, and when
    /// leverage does not answer and there is a server to start again.
    var offersTryAgain: Bool { status == .agentsStopped || (status == .unreachable && server != nil) }

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

    /// Starts the server again when leverage does not answer (it goes
    /// through Docker again when it must), or the helper again after it gave
    /// up, then reads the line again.
    func tryAgain() async {
        if status == .unreachable, let server {
            _ = await server.start()
        } else {
            _ = await helper.tryAgain()
        }
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
