import AppKit
import Foundation
import LeverageKit
import LeverageTestSupport
import SwiftUI

@testable import LeverageApp

/// Made-up values the Agents and Credentials screens' tests share.
enum AgentFixtures {
    static let builderID = UUID(uuidString: "aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa")!
    static let reviewerID = UUID(uuidString: "bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb")!
    static let ownID = UUID(uuidString: "cccccccc-3333-4333-8333-cccccccccccc")!
    static let loginID = UUID(uuidString: "dddddddd-4444-4444-8444-dddddddddddd")!
    static let secondLoginID = UUID(uuidString: "eeeeeeee-5555-4555-8555-eeeeeeeeeeee")!
    static let geminiLoginID = UUID(uuidString: "ffffffff-6666-4666-8666-ffffffffffff")!
    /// Obviously not a token; the made-up value the Connect tests show once.
    static let madeUpToken = "lvs_made-up-token-for-tests-only"
    static let landingText = "Join Leverage with \(madeUpToken). Send Authorization: Bearer \(madeUpToken)."

    static func issuedPrompt(
        _ seatID: UUID, connection: LandingPromptConnection, key: IdempotencyKey, text: String = landingText
    ) -> CommandOutcome<LandingPromptIssuedAnswer> {
        .completed(.shown(LandingPromptIssued(seatID: seatID, seatToken: madeUpToken, text: text, connection: connection)),
                   key: key.value, command: .issueLandingPrompt)
    }


    static func seat(
        _ id: UUID, name: String, role: SeatRole = .builder, provider: Provider = .claude, credential: UUID? = nil,
        run: SeatRunState? = nil, lastPolled: Date? = nil, removed: Date? = nil, enabled: Bool = true,
        paused: Bool = false, model: String? = nil, effort: String? = nil, strengthRank: Int? = 1
    ) -> Seat {
        Seat(
            id: id, name: name, provider: provider, model: model, effort: effort, role: role, strengthRank: strengthRank,
            credentialID: credential, enabled: enabled, paused: paused, lastPolledAt: lastPolled, runState: run,
            removedAt: removed)
    }

    /// One seat the app runs, one that is stopped, and one that connects on its own.
    static func seats(asOfSeq: Int = 12) -> SeatsList {
        SeatsList(
            seats: [
                seat(builderID, name: "Claude, Personal", credential: loginID, run: .running),
                seat(reviewerID, name: "Codex, Team", role: .reviewer, provider: .codex, credential: secondLoginID, run: .stopped),
                seat(ownID, name: "Helper agent", role: .builder, provider: .grok),
            ], asOfSeq: asOfSeq)
    }

    static func credential(
        _ id: UUID, name: String, provider: Provider = .claude, state: CredentialState = .active,
        limitedUntil: Date? = nil, lastVerifiedAt: Date? = nil, position: Int = 1
    ) -> CredentialWithReading {
        CredentialWithReading(
            credential: Credential(
                id: id, provider: provider, name: name, state: state, limitedUntil: limitedUntil, position: position,
                lastVerifiedAt: lastVerifiedAt))
    }

    static func credentials(asOfSeq: Int = 11) -> CredentialsList {
        CredentialsList(
            credentials: [
                credential(loginID, name: "Personal", provider: .claude, position: 1),
                credential(secondLoginID, name: "Team", provider: .codex, position: 2),
            ], asOfSeq: asOfSeq)
    }

    static func board(building title: String, by seat: UUID, asOfSeq: Int = 9) -> Board {
        let summary = TaskSummary(
            id: UUID(), title: title, goal: "g", details: nil, state: .working, round: 0, holderSeatID: seat,
            builderSeatID: seat, workReference: nil, priority: .normal)
        return Board(tasks: [BoardTask(task: summary, blocked: false, holdReasons: [])], asOfSeq: asOfSeq, reviewerSeatExists: true)
    }

    static func owner(
        seats: SeatsList = seats(), credentials: CredentialsList = credentials(), board: Board? = nil
    ) -> FakeOwnerAPI {
        let owner = FakeOwnerAPI()
        owner.script {
            $0.seats = { seats }
            $0.credentials = { credentials }
            $0.board = { board ?? Board(tasks: [], asOfSeq: 9, reviewerSeatExists: true) }
        }
        return owner
    }

    static func plain(_ command: CommandName, key: IdempotencyKey, helperRequest: UUID? = nil) -> PlainOutcome {
        let result: JSONValue = helperRequest.map { .object(["helper_request_id": .string($0.uuidString.lowercased())]) }
            ?? .object([:])
        return .completed(result, key: key.value, command: command)
    }

    static func request(
        _ id: UUID, kind: HelperRequestKind = .runAddChecks, state: HelperRequestState = .pickedUp,
        progress: [HelperCheckProgress] = [], result: HelperRequestResult? = nil, updated: Int = 0,
        credential: UUID? = nil, seat: UUID? = nil
    ) -> HelperRequestStatus {
        let at = Date(timeIntervalSince1970: 1_780_000_000)
        return HelperRequestStatus(
            request: HelperRequest(
                id: id, kind: kind, seatID: seat, credentialID: credential, state: state, requestedAt: at,
                result: result, progress: progress, updatedAt: at.addingTimeInterval(Double(updated))),
            asOfSeq: 20)
    }

    static func progress(
        _ check: HelperCheck, _ state: HelperCheckState, failure: HelperCheckFailure? = nil,
        install: InstallOffer? = nil
    ) -> HelperCheckProgress {
        HelperCheckProgress(check: check, state: state, failure: failure, install: install)
    }

    static func finished(_ outcome: HelperRequestOutcome = .finished, failing: [HelperCheckResult] = []) -> HelperRequestResult {
        HelperRequestResult(outcome: outcome, checks: failing, toolVersion: nil)
    }

    /// The pasteboard of a test: what was copied, in order.
    static func pasteboard() -> (copied: Locked<[String]>, copy: @MainActor (String) -> Void) {
        let copied = Locked<[String]>([])
        return (copied, { text in copied.update { $0.append(text) } })
    }

    static func calls(_ owner: FakeOwnerAPI, _ operation: ContractOperation) -> [FakeCall] {
        owner.calls.filter { $0.operation == operation }
    }

    /// True when the view draws something: not one flat colour.
    @MainActor
    static func draws(_ view: some View, width: CGFloat = 900, height: CGFloat = 620) -> Bool {
        let renderer = ImageRenderer(content: view.frame(width: width, height: height))
        renderer.scale = 1
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff), let data = bitmap.bitmapData
        else { return false }
        let pixel = max(1, bitmap.bitsPerPixel / 8)
        for row in 0..<bitmap.pixelsHigh {
            let line = data + row * bitmap.bytesPerRow
            for column in 0..<bitmap.pixelsWide {
                let at = line + column * pixel
                for byte in 0..<pixel where at[byte] != data[byte] { return true }
            }
        }
        return false
    }
}
