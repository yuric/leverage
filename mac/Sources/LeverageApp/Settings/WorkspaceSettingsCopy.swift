import Foundation

enum WorkspaceSettingsCopy: OwnerFacingCopy {
    case title, loading, save, saving, retry
    case leaseLength, checkQueueTimeout, checkRunTimeout, maximumRounds, rerunLimit, recoveryTimeCeiling
    case secondsBounds, countBounds, optionalSecondsBounds

    var text: String {
        switch self {
        case .title: "Workspace settings"
        case .loading: "Loading workspace settings…"
        case .save: "Save"
        case .saving: "Saving…"
        case .retry: "Try again"
        case .leaseLength: "How long an agent may go quiet before its task goes back"
        case .checkQueueTimeout: "How long a check may wait for an agent"
        case .checkRunTimeout: "How long a check may run"
        case .maximumRounds: "How many failed reviews a task may have before it waits for you"
        case .rerunLimit: "How many times a check may run again"
        case .recoveryTimeCeiling: "Target time to resume work after a limit or sign-out"
        case .secondsBounds: "{minimum} to {maximum} seconds"
        case .countBounds: "{minimum} to {maximum}"
        case .optionalSecondsBounds: "{minimum} to {maximum} seconds. Leave empty to set no target. The recovery report measures this wait."
        }
    }

    static func label(for field: WorkspaceSettingsModel.Field) -> Self {
        switch field {
        case .leaseLength: .leaseLength
        case .checkQueueTimeout: .checkQueueTimeout
        case .checkRunTimeout: .checkRunTimeout
        case .maximumRounds: .maximumRounds
        case .rerunLimit: .rerunLimit
        case .recoveryTimeCeiling: .recoveryTimeCeiling
        }
    }

    static func hint(for field: WorkspaceSettingsModel.Field) -> String {
        let format: Self
        switch field {
        case .maximumRounds, .rerunLimit: format = .countBounds
        case .recoveryTimeCeiling: format = .optionalSecondsBounds
        default: format = .secondsBounds
        }
        return format.filled([
            "minimum": field.bounds.lowerBound.formatted(),
            "maximum": field.bounds.upperBound.formatted(),
        ])
    }
}
