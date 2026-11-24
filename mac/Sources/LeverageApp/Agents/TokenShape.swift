/// A prompt may repeat its own key, but every token-shaped string in it
/// must be that key (GA-13).
enum TokenShape {
    static func containsOnly(_ token: String, in text: String) -> Bool {
        let matches = text.matches(of: #/lv[sho]_[A-Za-z0-9_-]{8,}/#)
        return !matches.isEmpty && matches.allSatisfy { $0.output == token }
    }
}
