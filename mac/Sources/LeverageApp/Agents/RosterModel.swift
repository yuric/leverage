import Foundation
import LeverageKit
import Observation

/// One agent on the roster: its name, what it is, what it is doing, and what
/// can be done to it (MA-2, MA-30). No strength rank is shown (MA-11). Its
/// state is one of HM-45's words: Paused, Off, Not running, or Waiting for the
/// account it cannot run on.
struct RosterRow: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    /// "Builder. Building Fix rounding in invoice totals."
    let roleLine: String
    /// "Claude · Default model · Default effort · On"
    let detailLine: String
    /// "Runs on Personal.", for an agent the app runs.
    let loginLine: String?
    let lastPolledLine: String
    let runChip: CardChip?
    let canStart: Bool
    let canStop: Bool
    /// An agent that connects on its own has a landing prompt; one the app runs has none.
    let canCopyLandingPrompt: Bool
    let canPause: Bool
    let canResume: Bool
    let canChange: Bool
    /// What pausing does and does not do (HE-26), on a paused agent's row.
    let pausedNote: String?

    init(seat: Seat, loginName: String?, doing: String?, waitingFor: String? = nil, now: Date) {
        id = seat.id
        name = seat.name
        let runsOnApp = seat.credentialID != nil
        let working = seat.enabled && !seat.paused
        let state: String
        if seat.paused {
            state = AgentsCopy.statePaused.text
        } else if !seat.enabled {
            state = AgentsCopy.stateOff.text
        } else if runsOnApp {
            if seat.runState != .running {
                state = doing.map { AgentsCopy.stateBuilding.filled(["task": $0]) } ?? AgentsCopy.stateNotRunning.text
            } else if let account = waitingFor {
                state = AgentsCopy.stateWaitingFor.filled(["account": account])
            } else {
                state = doing.map { AgentsCopy.stateBuilding.filled(["task": $0]) } ?? AgentsCopy.stateRunning.text
            }
        } else {
            state = doing.map { AgentsCopy.stateBuilding.filled(["task": $0]) } ?? AgentsCopy.stateConnectsOnItsOwn.text
        }
        roleLine = AgentsCopy.roleLine.filled(["role": AgentsCopy.role(seat.role).text, "state": state])

        let model = seat.model.flatMap { $0.isEmpty ? nil : $0 } ?? AgentsCopy.defaultModel.text
        // A tool that is given no effort runs on its own default, whatever
        // effort the agent was given.
        let given = ProviderCatalog.takesEffort(seat.provider) ? seat.effort : nil
        let effort = given.flatMap { $0.isEmpty ? nil : AgentsCopy.effortNamed.filled(["effort": $0]) }
            ?? AgentsCopy.defaultEffort.text
        let onOff = (seat.paused ? AgentsCopy.pausedWord : seat.enabled ? .on : .off).text
        detailLine = [ProviderNames.name(seat.provider), model, effort, onOff].joined(separator: " · ")
        loginLine = runsOnApp ? loginName.map { AgentsCopy.runsOn.filled(["login": $0]) } : nil

        if let polled = seat.lastPolledAt {
            let when = RelativeDateTimeFormatter().localizedString(for: polled, relativeTo: now)
            lastPolledLine = AgentsCopy.lastAsked.filled(["when": when])
        } else {
            lastPolledLine = AgentsCopy.neverAsked.text
        }

        if runsOnApp {
            runChip = seat.runState == .running
                ? CardChip(text: AgentsCopy.chipRunning.text, tone: .done)
                : CardChip(text: AgentsCopy.chipNotRunning.text, tone: .plain)
        } else {
            runChip = nil
        }
        canStart = runsOnApp && working && seat.runState != .running
        canStop = runsOnApp && seat.runState == .running
        canCopyLandingPrompt = !runsOnApp
        canPause = working
        canResume = seat.paused
        canChange = true
        pausedNote = seat.paused ? AgentsCopy.pausedNote.text : nil
    }
}

/// What the confirmation before Remove says.
struct PendingRemoval: Equatable, Sendable {
    let id: UUID
    let title: String
    let message: String
}

/// The Agents screen: one row per agent from `list_seats`, with Start and
/// Stop for an agent the app runs, Copy landing prompt for one that connects
/// on its own, and Remove behind a confirmation (MA-2, MA-12, MA-20, MA-30).
///
/// It reads again when the events tail delivers a batch, and every 10 seconds,
/// because when an agent last asked for work and whether it runs are not
/// events (MA-20). A read that fails keeps the rows already shown.
@MainActor
@Observable
final class RosterModel {
    enum State: Equatable, Sendable {
        case loading
        case loaded
        case failed(ShellCopy)
        /// The sign-in ended. The shell returns the app to Sign in.
        case signedOut
    }

    private enum Action: Hashable {
        case start(UUID), stop(UUID), remove(UUID), pause(UUID), resume(UUID)
    }

    private(set) var state: State = .loading
    private(set) var rows: [RosterRow] = []
    private(set) var pendingRemoval: PendingRemoval?
    /// The agent whose landing prompt was copied last.
    private(set) var copiedPrompt: UUID?
    private(set) var busy: Set<UUID> = []
    private(set) var working: [UUID: AgentsCopy] = [:]
    /// The Change sheet, while the owner has one open.
    private(set) var changing: ChangeAgentModel?
    private var failures: [UUID: String] = [:]

    @ObservationIgnored private let api: any OwnerAPI
    @ObservationIgnored private let noteRead: @MainActor (Int) -> Void
    @ObservationIgnored private let copy: @MainActor (String) -> Void
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let timing: FollowTiming
    @ObservationIgnored private var seats: [UUID: Seat] = [:]
    @ObservationIgnored private var logins: [ConnectAgentModel.LoginChoice] = []
    @ObservationIgnored private var keys: [Action: IdempotencyKey] = [:]
    @ObservationIgnored private var subscription: EventFeed.Subscription?
    @ObservationIgnored private var generation = 0

    init(
        api: any OwnerAPI, noteRead: @escaping @MainActor (Int) -> Void,
        copy: @escaping @MainActor (String) -> Void, now: @escaping () -> Date = Date.init,
        timing: FollowTiming = .normal
    ) {
        self.api = api
        self.noteRead = noteRead
        self.copy = copy
        self.now = now
        self.timing = timing
    }

    func isBusy(_ id: UUID) -> Bool { busy.contains(id) }

    /// The line a command left on that row.
    func failure(for id: UUID) -> String? { failures[id] }

    // MARK: reading

    /// Reads the agents, and the logins and the board for what each row says
    /// about them. The last two are a nicety: the roster shows without them.
    func load() async {
        generation += 1
        let mine = generation
        do {
            let seats = try await api.seats()
            var position = seats.asOfSeq
            var loginNames: [UUID: String] = [:]
            var accounts: [Credential] = []
            var doing: [UUID: String] = [:]
            do {
                let list = try await api.credentials()
                loginNames = Dictionary(
                    list.credentials.map { ($0.credential.id, $0.credential.name) }, uniquingKeysWith: { first, _ in first })
                accounts = list.credentials.map(\.credential)
                position = min(position, list.asOfSeq)
            } catch let error as TransportError where error.code == .unauthenticated {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {}
            do {
                let board = try await api.board()
                for entry in board.tasks where entry.task.state == .working || entry.task.state == .finishing {
                    if let holder = entry.task.holderSeatID, doing[holder] == nil { doing[holder] = entry.task.title }
                }
                position = min(position, board.asOfSeq)
            } catch let error as TransportError where error.code == .unauthenticated {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {}
            guard mine == generation else { return }
            let at = now()
            let present = seats.seats.filter { $0.removedAt == nil }
            self.seats = Dictionary(present.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            logins = accounts.filter { $0.kind == .login }.sorted { $0.position < $1.position }
                .map(ConnectAgentModel.LoginChoice.init)
            rows = present.map { seat in
                // The row says it only for an agent that is on and running.
                let waiting = AgentWait.account(for: seat, in: accounts, at: at).map(ProviderNames.account)
                return RosterRow(
                    seat: seat, loginName: seat.credentialID.flatMap { loginNames[$0] }, doing: doing[seat.id],
                    waitingFor: waiting, now: at)
            }
            state = .loaded
            noteRead(position)
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch let error as TransportError where error.code == .unauthenticated {
            if mine == generation { state = .signedOut }
        } catch {
            if mine == generation { state = .failed(ShellCopy.sentence(for: error)) }
        }
    }

    /// Reads again each time the events tail delivers a batch.
    func attach(to feed: EventFeed) {
        subscription?.cancel()
        subscription = feed.subscribe { [weak self] _ in
            Task { await self?.load() }
        }
    }

    func detach() {
        subscription?.cancel()
        subscription = nil
    }

    /// Reads now and then every `interval` until cancelled.
    func keepCurrent(every interval: Duration = .seconds(10)) async {
        while !Task.isCancelled {
            await load()
            do { try await Task.sleep(for: interval) } catch { return }
        }
    }

    // MARK: Pause, Resume and Change

    /// Pause: the agent takes no new work. It stops no run (HE-26), so the row
    /// says what that means.
    func pause(_ id: UUID) async {
        guard rows.first(where: { $0.id == id })?.canPause == true else { return }
        await run(.pause(id), working: .pausing)
    }

    func resume(_ id: UUID) async {
        guard rows.first(where: { $0.id == id })?.canResume == true else { return }
        await run(.resume(id), working: .resuming)
    }

    /// Change: opens the sheet with this agent's values and the logins it can
    /// move to. A saved change closes it and reads the roster again.
    func beginChange(_ id: UUID) {
        guard let seat = seats[id], rows.contains(where: { $0.id == id }) else { return }
        changing = ChangeAgentModel(
            api: api, seat: seat, logins: logins,
            onChanged: { [weak self] in
                self?.changing = nil
                await self?.load()
            })
    }

    func cancelChange() { changing = nil }

    // MARK: commands

    func start(_ id: UUID) async {
        guard rows.first(where: { $0.id == id })?.canStart == true else { return }
        await run(.start(id), working: .starting)
    }

    func stop(_ id: UUID) async {
        guard rows.first(where: { $0.id == id })?.canStop == true else { return }
        await run(.stop(id), working: .stopping)
    }

    /// Remove asks first.
    func askToRemove(_ id: UUID) {
        guard let row = rows.first(where: { $0.id == id }) else { return }
        pendingRemoval = PendingRemoval(
            id: id, title: AgentsCopy.removeTitle.filled(["name": row.name]), message: AgentsCopy.removeMessage.text)
    }

    func cancelRemoval() { pendingRemoval = nil }

    func confirmRemoval() async {
        guard let pending = pendingRemoval else { return }
        pendingRemoval = nil
        await run(.remove(pending.id), working: nil)
    }

    private func run(_ action: Action, working label: AgentsCopy?) async {
        let id: UUID
        switch action {
        case .start(let seat), .stop(let seat), .remove(let seat), .pause(let seat), .resume(let seat): id = seat
        }
        guard !busy.contains(id) else { return }
        busy.insert(id)
        working[id] = label
        failures[id] = nil
        defer {
            busy.remove(id)
            working[id] = nil
        }
        let key = keys[action] ?? IdempotencyKey()
        keys[action] = key
        do {
            let outcome: PlainOutcome
            switch action {
            case .start: outcome = try await api.startSeat(seatID: id, key: key)
            case .stop: outcome = try await api.stopSeat(seatID: id, key: key)
            case .remove: outcome = try await api.removeSeat(seatID: id, key: key)
            case .pause: outcome = try await api.pauseSeat(seatID: id, key: key)
            case .resume: outcome = try await api.resumeSeat(seatID: id, key: key)
            }
            _ = try outcome.completedResult()
            keys[action] = nil
            if let requestID = outcome.helperRequestID, label != nil {
                let follower = HelperRequestFollower(api: api, timing: timing)
                if let request = try await follower.follow(requestID, giveUpAfter: timing.quickGiveUpAfter),
                   !request.succeeded {
                    let name = rows.first(where: { $0.id == id })?.name ?? ""
                    let line = action == .stop(id) ? AgentsCopy.stopFailed : .startFailed
                    failures[id] = line.filled(["name": name])
                }
            }
            await load()
        } catch is CancellationError {
            return
        } catch {
            if CommandKey.wasAnswered(error) { keys[action] = nil }
            failures[id] = ShellCopy.sentence(for: error).text
        }
    }

    /// Copy landing prompt: fetches the prompt again each time and copies it.
    /// An agent the app runs has none.
    func copyLandingPrompt(_ id: UUID) async {
        guard rows.first(where: { $0.id == id })?.canCopyLandingPrompt == true, !busy.contains(id) else { return }
        busy.insert(id)
        defer { busy.remove(id) }
        failures[id] = nil
        copiedPrompt = nil
        do {
            let prompt = try await api.landingPrompt(seatID: id)
            guard !TokenShape.isIn(prompt.text) else { throw LeverageClientError.invalidBody }
            copy(prompt.text)
            copiedPrompt = id
        } catch is CancellationError {
            return
        } catch {
            failures[id] = ShellCopy.sentence(for: error).text
        }
    }
}
