/// The lease can be renewed automatically for ten minutes after a tool call (AM-4).
struct ActivityWindow {
    private static let length: Duration = .seconds(600)
    private var lastCall: Duration?

    mutating func recordCall(at time: Duration) {
        lastCall = time
    }

    func isOpen(at time: Duration) -> Bool {
        guard let lastCall else { return false }
        return time >= lastCall && time - lastCall < Self.length
    }
}
