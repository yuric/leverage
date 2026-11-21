import LeverageKit

enum AnswerJobParser {
    static func parse(_ text: String, nonce: String) -> QuestionJobResult? {
        let frame = FramedOutput(text, nonce: nonce)
        let passes = frame.positions(JobPrompts.passOnMarker(nonce))
        let begins = frame.positions(JobPrompts.answerBegin(nonce))
        let ends = frame.positions(JobPrompts.answerEnd(nonce))
        let bases = frame.fields(JobPrompts.basisMarker(nonce))

        if !passes.isEmpty {
            guard passes.count == 1, begins.isEmpty, ends.isEmpty, bases.isEmpty else { return nil }
            return QuestionJobResult(outcome: .passedOn)
        }

        guard begins.count == 1, ends.count == 1, bases.count == 1,
              let begin = begins.first, let end = ends.first, begin < end,
              let field = bases.first, end < field.line,
              let basis = QuestionJobBasis(rawValue: field.value.lowercased())
        else { return nil }

        let body = frame.lines[(begin + 1)..<end].joined(separator: "\n")
        let answer = FramedOutput.limited(body, to: QuestionJobResult.answerLimit)
        guard !answer.isEmpty else { return nil }
        return QuestionJobResult(outcome: .answered, answer: answer, basis: basis)
    }
}
