import Foundation

/// The owner-facing sentences of the Needs you screen and of its
/// notifications (HM-24, HM-28, HM-29, HM-30). A sentence with a `{name}` in
/// it is filled in by `filled(_:)`.
enum NeedsYouCopy: OwnerFacingCopy {
    case title, empty, loading

    // Account signed out.
    case signedOutHeading, signedOutBody, signInAgain, signInWaiting
    // Limit with no reset time.
    case limitHeading, limitBody
    // Past the round limit.
    case sentBackHeading, sentBackBody, letItTryOnceMore, changeTask, cancelTask
    case cancelQuestion, cancelConfirm, cancelKeep
    // An item this version cannot open.
    case unknownKind

    // Notifications.
    case notificationsOff, settledBeforeYouSaw
    case kindSignedOut, kindLimit, kindSentBack, kindOther
    // Names used when a read could not say.
    case aTask, anAccount

    var text: String { "" }
}
