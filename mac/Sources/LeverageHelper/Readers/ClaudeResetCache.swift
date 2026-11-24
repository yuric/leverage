import Foundation
import LeverageKit

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The provisional reset source (CR-4). A fresh, explicitly empty entry
/// means zero. The shape of an actual grant has not been recorded.
enum ClaudeResetCache {
    private static let fileLimit = 5 << 20
    private static let entryLimit = 64 << 10

    static func read(accountFolder: URL, now: Date) -> [Reset]? {
        // Pin the accounts directory and the account itself before opening
        // its settings. O_NONBLOCK also lets us reject a non-regular file
        // without stalling on a FIFO before fstat.
        let dirFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        let accounts = open(accountFolder.deletingLastPathComponent().path, dirFlags)
        guard accounts >= 0 else { return nil }
        defer { close(accounts) }
        let account = openat(accounts, accountFolder.lastPathComponent, dirFlags)
        guard account >= 0 else { return nil }
        defer { close(account) }
        let fd = openat(account, ".claude.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        let settings = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1, info.st_size > 0, info.st_size <= fileLimit else { return nil }
        let size = Int(info.st_size)
        guard let data = try? settings.read(upToCount: size), data.count == size,
              fstat(fd, &info) == 0, info.st_size == size else { return nil }
        return read(data: data, now: now)
    }

    static func read(data: Data, now: Date) -> [Reset]? {
        guard data.count <= fileLimit else { return nil }
        return data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var scanner = SettingsScanner(bytes: bytes)
            guard let range = try? scanner.member(named: "cachedUsageUtilization"), range.count <= entryLimit else {
                return nil
            }
            let entry = UnsafeBufferPointer(rebasing: bytes[range])
            var clock = SettingsScanner(bytes: entry)
            var usage = SettingsScanner(bytes: entry)
            guard let timestamp = try? clock.member(named: "fetchedAtMs"),
                  let millis = try? JSONDecoder().decode(Int64.self, from: Data(entry[timestamp])),
                  let utilization = try? usage.member(named: "utilization") else { return nil }
            let age = now.timeIntervalSince1970 - Double(millis) / 1000
            guard (0...600).contains(age) else { return nil }
            let payload = UnsafeBufferPointer(rebasing: entry[utilization])
            var resets = SettingsScanner(bytes: payload)
            guard let value = try? resets.member(named: "cedar_ember") else { return nil }
            let compact = payload[value].lazy.filter { !SettingsScanner.isSpace($0) }
            return compact.elementsEqual("[]".utf8) || compact.elementsEqual("{}".utf8) ? [] : nil
        }
    }
}

/// Scans JSON in place to locate one member of an object. Other members'
/// values never become Swift strings, dictionaries, arrays or error text.
private struct SettingsScanner {
    private struct Invalid: Error {}
    let bytes: UnsafeBufferPointer<UInt8>
    private var offset = 0

    init(bytes: UnsafeBufferPointer<UInt8>) { self.bytes = bytes }

    static func isSpace(_ byte: UInt8) -> Bool { byte == 32 || byte == 9 || byte == 10 || byte == 13 }

    mutating func member(named name: String) throws -> Range<Int>? {
        spaces()
        try require("{")
        spaces()
        var found: Range<Int>?
        if !take("}") {
            repeat {
                spaces()
                let start = offset
                try string()
                let key = bytes[(start + 1)..<(offset - 1)]
                let matches = key.elementsEqual(name.utf8) ||
                    (key.count <= name.utf8.count * 6 && key.contains(0x5c) &&
                     (try? JSONDecoder().decode(String.self, from: Data(bytes[start..<offset]))) == name)
                spaces()
                try require(":")
                spaces()
                let value = offset
                try skipValue(depth: 0)
                if matches {
                    guard found == nil else { throw Invalid() }
                    found = value..<offset
                }
                spaces()
            } while take(",")
            try require("}")
        }
        spaces()
        guard offset == bytes.count else { throw Invalid() }
        return found
    }

    private var next: UInt8? { offset < bytes.count ? bytes[offset] : nil }

    private mutating func spaces() {
        while let byte = next, Self.isSpace(byte) { offset += 1 }
    }

    private mutating func take(_ token: Unicode.Scalar) -> Bool {
        guard let byte = next, byte == token.value else { return false }
        offset += 1
        return true
    }

    private mutating func require(_ token: Unicode.Scalar) throws {
        guard take(token) else { throw Invalid() }
    }

    private mutating func skipValue(depth: Int) throws {
        guard depth < 128, let byte = next else { throw Invalid() }
        switch Unicode.Scalar(byte) {
        case "{", "[":
            let object = byte == UInt8(ascii: "{")
            let end: Unicode.Scalar = object ? "}" : "]"
            offset += 1
            spaces()
            if take(end) { return }
            repeat {
                spaces()
                if object {
                    try string()
                    spaces()
                    try require(":")
                    spaces()
                }
                try skipValue(depth: depth + 1)
                spaces()
            } while take(",")
            try require(end)
        case "\"": try string()
        case "n": try literal("null")
        case "t": try literal("true")
        case "f": try literal("false")
        default: try number()
        }
    }

    private mutating func literal(_ text: String) throws {
        for scalar in text.unicodeScalars { try require(scalar) }
    }

    private mutating func number() throws {
        _ = take("-")
        if !take("0") { try digits() }
        if take(".") { try digits() }
        if take("E") || take("e") {
            _ = take("+") || take("-")
            try digits()
        }
    }

    private mutating func digits() throws {
        let start = offset
        while let byte = next, (48...57).contains(byte) { offset += 1 }
        guard offset > start else { throw Invalid() }
    }

    private mutating func string() throws {
        try require("\"")
        while let byte = next {
            offset += 1
            switch byte {
            case 0x22: return
            case 0x5c:
                guard let escaped = next else { throw Invalid() }
                offset += 1
                if escaped == 0x75 {
                    for _ in 0..<4 {
                        guard let hex = next, (48...57).contains(hex) || (65...70).contains(hex) ||
                                (97...102).contains(hex) else { throw Invalid() }
                        offset += 1
                    }
                } else if !#""\/bfnrt"#.utf8.contains(escaped) { throw Invalid() }
            case 0..<0x20: throw Invalid()
            case 0x80...0xff:
                // Validate this scalar through the standard UTF-8 decoder
                // without retaining string contents.
                var input = bytes[(offset - 1)...].makeIterator()
                var decoder = UTF8()
                guard case .scalarValue(let scalar) = decoder.decode(&input) else { throw Invalid() }
                offset += scalar.utf8.count - 1
            default: break
            }
        }
        throw Invalid()
    }
}
