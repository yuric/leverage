/// The owner-facing sentences of the sign-in screen (IN-2, MA-5).
enum SignInCopy: OwnerFacingCopy {
    case createTitle, createBody, signInTitle, signInBody
    case emailLabel, emailPlaceholder, passwordLabel, passwordHintCreate
    case createButton, signInButton, busy

    // Why it did not work.
    case wrongDetails, cannotReach, alreadyCreated, invalidDetails, somethingWentWrong

    var text: String {
        switch self {
        case .createTitle: "Create your sign-in"
        case .createBody:
            "leverage keeps its work on this Mac. This email address and password are how you sign in to it."
        case .signInTitle: "Sign in"
        case .signInBody: "Sign in to leverage on this Mac."
        case .emailLabel: "Email address"
        case .emailPlaceholder: "name@example.com"
        case .passwordLabel: "Password"
        case .passwordHintCreate: "At least 8 characters. There is no way to reset it, so keep it somewhere safe."
        case .createButton: "Create sign-in"
        case .signInButton: "Sign in"
        case .busy: "One moment…"

        case .wrongDetails: "That email address and password do not match."
        case .cannotReach: "Can't reach leverage on this Mac, so you can't sign in yet. Try again in a moment."
        case .alreadyCreated: "A sign-in already exists on this Mac. Sign in with it instead."
        case .invalidDetails: "Use an email address and a password of at least 8 characters."
        case .somethingWentWrong: "Something went wrong while signing in. Try again."
        }
    }
}
