import Foundation
import LeverageKit

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// One JSON object per LF-terminated line on the helper's standard input.
struct LocalChannel: Sendable {
    let cleanup: CredentialCleanup
    let log: Log

    private static let lineLimit = 64 * 1024

    /// EOF closes this channel. The helper's other work is independent.
    func run(input: FileHandle) async {
        let fd = fcntl(input.fileDescriptor, F_DUPFD_CLOEXEC, 0)
        guard fd >= 0 else {
            log.warning("could not open the local channel")
            return
        }
        let (chunks, continuation) = AsyncStream<Data>.makeStream()
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())
        source.setCancelHandler { _ = close(fd) }
        source.setEventHandler {
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = read(fd, &bytes, bytes.count)
            if count > 0 {
                continuation.yield(Data(bytes.prefix(count)))
            } else if count == 0 || errno != EINTR {
                continuation.finish()
                source.cancel()
            }
        }
        source.resume()
        defer { source.cancel() }

        var line = Data()
        var oversized = false
        for await chunk in chunks {
            if Task.isCancelled { return }
            for byte in chunk {
                if byte == 0x0A {
                    if oversized {
                        log.warning("invalid local message")
                    } else {
                        await receive(line)
                    }
                    line.removeAll(keepingCapacity: true)
                    oversized = false
                } else if !oversized {
                    if line.count == Self.lineLimit {
                        line.removeAll(keepingCapacity: true)
                        oversized = true
                    } else {
                        line.append(byte)
                    }
                }
            }
        }
        if !Task.isCancelled && (oversized || !line.isEmpty) {
            log.warning("invalid local message")
        }
    }

    private func receive(_ line: Data) async {
        guard let message = try? LocalHelperMessage.decodeLine(line) else {
            log.warning("invalid local message")
            return
        }
        switch message {
        case .token(let id, let token):
            await cleanup.acceptToken(token, credentialID: id)
        case .forget(let id):
            await cleanup.forget(id)
        }
    }
}
