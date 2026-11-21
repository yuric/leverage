import Foundation

/// Newline-delimited UTF-8 JSON. The input queue owns the read buffer and
/// keeps the blocking pipe read off the executor that runs the heartbeats.
final class StdioTransport: @unchecked Sendable {
    private let input: FileHandle
    private let output: FileHandle
    private let inputQueue = DispatchQueue(label: "leverage.mcp.input")
    private let outputLock = NSLock()
    private var buffer = Data()

    init(input: FileHandle, output: FileHandle) {
        self.input = input
        self.output = output
    }

    func nextLine() async -> Data? {
        await withCheckedContinuation { continuation in
            inputQueue.async {
                continuation.resume(returning: self.readLine())
            }
        }
    }

    private func readLine() -> Data? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.prefix(upTo: newline)
                buffer.removeSubrange(...newline)
                return line
            }

            let chunk = input.availableData
            if chunk.isEmpty {
                if buffer.isEmpty { return nil }
                let line = buffer
                buffer.removeAll()
                return line
            }
            buffer.append(chunk)
        }
    }

    func write(_ response: Any) throws {
        var line = try JSONSerialization.data(withJSONObject: response, options: [.withoutEscapingSlashes])
        line.append(0x0A)
        try outputLock.withLock { try output.write(contentsOf: line) }
    }
}
