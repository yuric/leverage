enum VersionGate {
    static func accepts(_ version: String, testedVersions: [String]) -> Bool { false }
}
