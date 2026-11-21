enum ActionResultParser {
    enum Result: Equatable, Sendable {
        case done(String)
        case cannot(String)
    }

    static func parse(_ text: String, nonce: String) -> Result? {
        nil
    }
}
