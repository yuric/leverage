import Foundation
import LeverageKit

struct ToolResult: Sendable {
    let response: ToolResponse?
    let isError: Bool
    let key: IdempotencyKey?
    var problem: String?

    var payload: JSONValue {
        .object([
            "status": response.map { .number(Double($0.status)) } ?? .null,
            "key": key.map { .string($0.value) } ?? .null,
            "body": response?.body ?? .object(["message": .string(problem ?? "The tool call failed.")])
        ])
    }

    static func failure(_ message: String, key: IdempotencyKey? = nil) -> Self {
        Self(response: nil, isError: true, key: key, problem: message)
    }
}

/// Serializes the seat's HTTP calls, including the heartbeat and any
/// criterion start sent on behalf of a pass. Actor isolation alone would
/// let a heartbeat interleave while a tool call awaits the API.
actor ToolCaller {
    private let transport: @Sendable (ToolRequest) async throws -> ToolResponse
    private let now: @Sendable () -> Duration
    private var window = ActivityWindow()
    private var held = HeldWork()
    private var sending = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    // Retrying an accepted report must still work after the last action
    // closes the task and clears the current lease.
    private var authorizedActionReports: [IdempotencyKey: [String: String]] = [:]
    // A lost reply can mean the start was stored. Use the same start key
    // when the client retries the pass with its separate key.
    private var unconfirmedStarts: [IdempotencyKey: ToolRequest] = [:]

    init(
        transport: @escaping @Sendable (ToolRequest) async throws -> ToolResponse,
        now: (@Sendable () -> Duration)? = nil
    ) {
        self.transport = transport
        let start = ContinuousClock.now
        self.now = now ?? { start.duration(to: .now) }
    }

    func recordActivity() {
        window.recordCall(at: now())
    }

    func call(_ tool: ToolDefinition, arguments: [String: JSONValue]) async -> ToolResult {
        recordActivity()
        let request: ToolRequest
        do {
            request = try Self.request(for: tool, arguments: arguments)
        } catch let error as InvalidArgument {
            return .failure(error.message)
        } catch {
            return .failure("Invalid tool arguments.")
        }
        await waitForTurn()
        defer { finishTurn() }

        return await perform(request, suppliedKey: arguments["idempotency_key"] != nil)
    }

    func heartbeat() async {
        await waitForTurn()
        defer { finishTurn() }
        guard !Task.isCancelled, window.isOpen(at: now()), let item = held.item else { return }
        _ = await send(item.heartbeat)
    }

    private func perform(_ request: ToolRequest, suppliedKey: Bool) async -> ToolResult {
        guard let key = request.key else { return await send(request) }

        if request.operation == .reportActionDone {
            if authorizedActionReports[key] == request.path { return await send(request) }
            guard let task = request.path["id"], let action = request.path["aid"],
                  held.hasStartedAction(task: task, action: action) else {
                return .failure("Call start_action before carrying out the action, then report it done.")
            }
        }
        if held.knows(key) { return await send(request) }

        if let attempt = unconfirmedStarts[key],
           request.operation != .passCriterion || attempt.path != request.path {
            return .failure("This key was already used for a different criterion pass.", key: key)
        }
        if suppliedKey, HeldWork.tracksCommand(request), unconfirmedStarts[key] == nil {
            // The client may have used this key before this process began.
            // A stored result must not reopen a criterion or move the lease.
            let lookup = await send(ToolRequest(operation: .getCommand, path: ["key": key.value]))
            switch lookup.response?.status {
            case 200:
                // A command observed while it was pending can still establish
                // this session's lease, even if it settles before this retry.
                if lookup.response?.body["outcome"]?.stringValue != OutcomeKind.pending.rawValue {
                    held.ignoreStoredOutcome(for: key)
                }
                return await send(request)
            case 404:
                break
            default:
                return ToolResult(response: lookup.response, isError: true, key: key,
                                  problem: "Could not check the command key. Retry with the same key.")
            }
        }

        if request.operation == .passCriterion, let task = request.path["id"], let criterion = request.path["cid"],
           !held.hasStartedCriterion(task: task, criterion: criterion),
           let failure = await announceCriterion(for: request, passKey: key) {
            return failure
        }
        unconfirmedStarts.removeValue(forKey: key)
        if request.operation == .reportActionDone { authorizedActionReports[key] = request.path }
        return await send(request)
    }

    /// A failure to announce the criterion stops the pass. The client's
    /// key remains the key of the pass, never the synthesized start's key.
    private func announceCriterion(for request: ToolRequest, passKey: IdempotencyKey) async -> ToolResult? {
        let start = unconfirmedStarts[passKey] ??
            ToolRequest(operation: .startCriterion, path: request.path, key: IdempotencyKey())
        let result = await send(start)
        if result.response?.status == 200, !result.isError { return nil }

        if result.response == nil || result.response?.status == 202 {
            unconfirmedStarts[passKey] = start
        } else {
            unconfirmedStarts.removeValue(forKey: passKey)
        }
        let response = result.response.map { answer in
            // Preserve the refusal or transport status without presenting
            // the internal command's key as an alternative pass key.
            var body = answer.body
            if var fields = body.objectValue {
                fields.removeValue(forKey: "key")
                body = .object(fields)
            }
            return ToolResponse(status: answer.status, body: body)
        }
        return ToolResult(response: response, isError: true, key: passKey,
                          problem: "Could not confirm start_criterion. Retry the pass with the same key.")
    }

    private func send(_ request: ToolRequest) async -> ToolResult {
        do {
            let response = try await transport(request)
            held.observe(request, response: response)
            let refused = request.operation == .getCommand &&
                response.body["outcome"]?.stringValue == OutcomeKind.refused.rawValue
            let isError = !(200..<300).contains(response.status) || refused
            return ToolResult(response: response, isError: isError, key: request.key)
        } catch {
            // Network errors can contain headers, URLs or response content.
            let message = "Could not get an answer from the API."
            return .failure(request.key == nil ? message : message + " Retry with the same key.", key: request.key)
        }
    }

    private func waitForTurn() async {
        if sending {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            sending = true
        }
    }

    private func finishTurn() {
        if waiters.isEmpty {
            sending = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    private struct InvalidArgument: Error {
        let message: String
    }

    private static func request(for tool: ToolDefinition, arguments: [String: JSONValue]) throws -> ToolRequest {
        let operation = tool.operation
        var request = ToolRequest(operation: operation)
        var body = arguments

        for segment in operation.path.split(separator: "/") where segment.hasPrefix("{") && segment.hasSuffix("}") {
            let name = String(segment.dropFirst().dropLast())
            guard let argument = body.removeValue(forKey: name)?.stringValue else {
                throw InvalidArgument(message: "The tool needs the \(name) argument.")
            }
            if operation == .getCommand {
                guard IdempotencyKey(argument) != nil else {
                    throw InvalidArgument(message: "The key argument must be an idempotency key.")
                }
                request.path[name] = argument
            } else {
                guard let id = UUID(uuidString: argument) else {
                    throw InvalidArgument(message: "The \(name) argument must be a UUID.")
                }
                request.path[name] = id.contractString
            }
        }

        if operation.method == .post {
            if let value = body.removeValue(forKey: "idempotency_key") {
                guard let key = value.stringValue.flatMap(IdempotencyKey.init) else {
                    throw InvalidArgument(message: "The idempotency_key argument is invalid.")
                }
                request.key = key
            } else {
                request.key = IdempotencyKey()
            }
            request.body = body
        } else if operation == .getNext {
            if let value = body.removeValue(forKey: "wait") {
                guard let wait = value.intValue, (0...NextWait.maximum).contains(wait) else {
                    throw InvalidArgument(message: "The wait argument must be an integer from 0 to \(NextWait.maximum).")
                }
                request.wait = wait
            } else {
                request.wait = NextWait.defaultSeconds
            }
        }
        if operation.method == .get, !body.isEmpty {
            throw InvalidArgument(message: "The tool received an unexpected argument.")
        }
        return request
    }
}
