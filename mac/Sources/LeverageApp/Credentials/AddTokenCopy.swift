enum AddTokenCopy: OwnerFacingCopy {
    case helperNotRunning

    var text: String {
        switch self {
        case .helperNotRunning: "Agents are not running on this Mac, so leverage cannot check the token."
        }
    }
}
