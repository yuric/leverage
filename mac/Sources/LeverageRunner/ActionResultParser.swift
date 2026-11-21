enum ActionResultParser {
    enum Result: Equatable, Sendable {
        case done(String)
        case cannot(String)
    }

    static func parse(_ text: String, nonce: String) -> Result? {
        let frame = FramedOutput(text, nonce: nonce)
        let done = frame.fields(Prompts.actionDoneMarker(nonce))
        let cannot = frame.fields(Prompts.actionCannotMarker(nonce))

        guard done.count + cannot.count == 1 else { return nil }
        if let proof = done.first?.value, !proof.isEmpty, proof != Prompts.actionProofPlaceholder {
            return .done(proof)
        }
        if let reason = cannot.first?.value, !reason.isEmpty, reason != Prompts.actionReasonPlaceholder {
            return .cannot(reason)
        }
        return nil
    }
}
