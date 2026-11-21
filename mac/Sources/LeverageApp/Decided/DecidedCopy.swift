import LeverageKit

enum DecidedCopy: OwnerFacingCopy {
    case title, loading, empty, deletedTask, undo, undoQuestion, undoApproval, goBack, newAnswerField
    case recordObjection, recordObjectionQuestion
    case canUndo, cannotUndo, mayHaveGoneOut, stopped, recorded, newAnswer, noNewAnswer
    case publishing, paying, sending, deleting, whatWasApproved

    var text: String {
        switch self {
        case .title: "Decided for you"
        case .loading: "Reading decisions…"
        case .empty: "Nothing has been decided for you yet."
        case .deletedTask: "A deleted task"
        case .undo: "Undo this"
        case .undoQuestion: "Undo this answer?"
        case .undoApproval: "Undo this approval?"
        case .goBack: "Go back"
        case .newAnswerField: "Your new answer (optional)"
        case .recordObjection: "Record an objection"
        case .recordObjectionQuestion: "Record an objection to this approval?"
        case .canUndo: "Can still be undone"
        case .cannotUndo: "Cannot be undone"
        case .mayHaveGoneOut: "May already have gone out"
        case .stopped: "Stopped. See Needs you."
        case .recorded: "Recorded. {what} had already happened, so nothing changed."
        case .newAnswer: "The agent was told. Your answer: {answer}"
        case .noNewAnswer: "No new answer yet."
        case .publishing: "Publishing"
        case .paying: "Paying"
        case .sending: "Sending"
        case .deleting: "Deleting"
        case .whatWasApproved: "What was approved"
        }
    }

    static func recordedEffect(summary: String) -> String {
        // DecisionsList includes the kind at the start of the action summary.
        let verb = summary.prefix(while: \.isLetter).lowercased()
        let what: DecidedCopy = switch ActionKind(rawValue: verb) {
        case .publish: .publishing
        case .pay: .paying
        case .send: .sending
        case .delete: .deleting
        case nil: .whatWasApproved
        }
        return recorded.filled(["what": what.text])
    }
}
