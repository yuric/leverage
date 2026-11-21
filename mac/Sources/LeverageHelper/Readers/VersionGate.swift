enum VersionGate {
    static func accepts(_ version: String, testedVersions: [String]) -> Bool {
        guard let version = Self.number(in: version) else { return false }
        return testedVersions.contains { Self.number(in: $0) == version }
    }

    /// Compare the first run of ASCII digits and dots in the printed version.
    private static func number(in text: String) -> String? {
        func digit(_ byte: UInt8) -> Bool { (48...57).contains(byte) }
        let number = text.utf8.drop(while: { !digit($0) }).prefix(while: { digit($0) || $0 == 46 })
        return number.isEmpty ? nil : String(decoding: number, as: UTF8.self)
    }
}
