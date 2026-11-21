import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A synchronous test client for newline-delimited MCP over two pipes.
/// Drive it from one thread while the server runs independently.
public final class ScriptedMCPClient {
    public enum Failure: Error {
        case timeout
        case pipeRead
        case pipeWrite
        case invalidLine
        case unexpectedReply
    }

    private let input: FileHandle
    private let output: FileHandle
    private let timeout: Duration
    private var pending = Data()
    private var nextID = 1

    /// The client writes to `input` and reads from `output`.
    public init(input: FileHandle, output: FileHandle, timeout: Duration = .seconds(10)) {
        self.input = input
        self.output = output
        self.timeout = Patience.scaled(timeout)
    }

    public func send(_ object: Any) throws {
        try writeLine(JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed]))
    }

    /// Sends malformed JSON too, so tests can exercise the server's parser.
    public func sendLine(_ line: String) throws {
        try writeLine(Data(line.utf8))
    }

    public func receive() throws -> Any? {
        let deadline = ContinuousClock.now + timeout
        while true {
            if let newline = pending.firstIndex(of: 0x0A) {
                let line = pending.prefix(upTo: newline)
                pending.removeSubrange(...newline)
                guard let object = try? JSONSerialization.jsonObject(with: line, options: [.fragmentsAllowed]) else {
                    // A parser error can include bytes from the server's output.
                    throw Failure.invalidLine
                }
                return object
            }
            try wait(for: Int16(POLLIN), on: output.fileDescriptor, until: deadline)
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = read(output.fileDescriptor, &bytes, bytes.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw Failure.pipeRead }
            if count == 0 {
                guard pending.isEmpty else { throw Failure.invalidLine }
                return nil
            }
            pending.append(contentsOf: bytes.prefix(count))
        }
    }

    /// Returns the initialize envelope and sends the follow-up notification.
    public func initialize(protocolVersion: String = "2025-06-18") throws -> [String: Any] {
        let reply = try request(method: "initialize", params: [
            "protocolVersion": protocolVersion,
            "capabilities": [:],
            "clientInfo": ["name": "leverage-test", "version": "1"],
        ])
        guard reply["result"] is [String: Any] else { throw Failure.unexpectedReply }
        try send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        return reply
    }

    /// Returns the tool result, including `isError` on a tool-level failure.
    public func call(name: String, arguments: [String: Any] = [:]) throws -> [String: Any] {
        let reply = try request(method: "tools/call", params: ["name": name, "arguments": arguments])
        guard let result = reply["result"] as? [String: Any] else { throw Failure.unexpectedReply }
        return result
    }

    public func closeInput() throws {
        try input.close()
    }

    private func request(method: String, params: [String: Any]) throws -> [String: Any] {
        let id = nextID
        nextID += 1
        try send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        guard let reply = try receive() as? [String: Any],
              reply["jsonrpc"] as? String == "2.0", reply["id"] as? Int == id else {
            throw Failure.unexpectedReply
        }
        return reply
    }

    private func writeLine(_ line: Data) throws {
        let descriptor = input.fileDescriptor
        #if canImport(Darwin)
        // An early server exit must fail the test without killing the test runner.
        guard fcntl(descriptor, F_SETNOSIGPIPE, 1) == 0 else { throw Failure.pipeWrite }
        #else
        var sigpipe = sigset_t()
        sigemptyset(&sigpipe)
        sigaddset(&sigpipe, SIGPIPE)
        var originalMask = sigset_t()
        guard pthread_sigmask(SIG_BLOCK, &sigpipe, &originalMask) == 0 else { throw Failure.pipeWrite }
        var consumeSignal = false
        defer {
            if consumeSignal {
                var noWait = timespec()
                _ = sigtimedwait(&sigpipe, nil, &noWait)
            }
            pthread_sigmask(SIG_SETMASK, &originalMask, nil)
        }
        #endif

        var frame = line
        frame.append(0x0A)
        let deadline = ContinuousClock.now + timeout
        try frame.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { throw Failure.pipeWrite }
            var offset = 0
            while offset < bytes.count {
                try wait(for: Int16(POLLOUT), on: descriptor, until: deadline)
                // Stay within POSIX's minimum PIPE_BUF after a write-ready poll.
                let count = write(descriptor, base.advanced(by: offset), min(512, bytes.count - offset))
                if count < 0 && errno == EINTR { continue }
                #if canImport(Glibc)
                consumeSignal = count < 0 && errno == EPIPE && sigismember(&originalMask, SIGPIPE) == 0
                #endif
                guard count > 0 else { throw Failure.pipeWrite }
                offset += count
            }
        }
    }

    private func wait(for events: Int16, on descriptor: Int32, until deadline: ContinuousClock.Instant) throws {
        var fd = pollfd(fd: descriptor, events: events, revents: 0)
        while true {
            let remaining = (deadline - ContinuousClock.now).components
            let milliseconds = Double(remaining.seconds) * 1000 + Double(remaining.attoseconds) / 1e15
            guard milliseconds > 0 else { throw Failure.timeout }
            let result = poll(&fd, 1, Int32(min(milliseconds.rounded(.up), Double(Int32.max))))
            if result < 0 && errno == EINTR { continue }
            if result == 0 { continue }
            guard result > 0, fd.revents & Int16(POLLNVAL) == 0 else {
                throw events == Int16(POLLIN) ? Failure.pipeRead : Failure.pipeWrite
            }
            // Also return on POLLHUP and POLLERR so read or write sees EOF or EPIPE.
            return
        }
    }
}
