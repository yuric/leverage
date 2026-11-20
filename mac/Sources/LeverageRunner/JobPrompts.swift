import Foundation
import LeverageKit

/// The two frames a checker and a planner are given, the nonce, and the
/// labels (milestone 4 plan section 2.2, ADR 0012). A placeholder for WP14:
/// the final names and signatures, answering nothing. The frames are what
/// keeps task text from steering a checker (L937), so nothing calls these
/// until they are built.
enum JobPrompts {
    /// The first line of a check prompt.
    static let checkFirstLine = "LEVERAGE CHECK"
    /// The first line of a draft prompt.
    static let draftFirstLine = "LEVERAGE DRAFT"

    /// A nonce for one tool run: 12 lower-case hex characters from the
    /// system's random source. Never logged.
    static func makeNonce() -> String { "" }

    /// The check prompt for one rule check: the role file, the rule, the
    /// moment, every piece of task text in its own quote block, and the
    /// closing that asks for the two nonce lines.
    static func check(material: CheckMaterial, nonce: String) -> String { "" }

    /// The draft prompt for one contract draft: the task's text, the
    /// criteria it already has and the brief in quote blocks, and the
    /// closing that asks for one JSON object between the nonce's markers.
    static func draft(material: DraftMaterial, nonce: String) -> String { "" }
}
