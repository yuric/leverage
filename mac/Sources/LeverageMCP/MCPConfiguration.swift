import Foundation
import LeverageKit

struct MCPConfiguration: Sendable, HidesToken {
    enum Invalid: Error, CustomStringConvertible {
        case missingToken
        case seatRole

        var description: String {
            switch self {
            case .missingToken: "\(EnvironmentKeys.seatToken) is not set"
            case .seatRole: "\(EnvironmentKeys.seatRole) must name a seat role"
            }
        }
    }

    let apiBaseURL: URL
    let seatToken: String
    let role: SeatRole?

    init(environment: [String: String]) throws {
        guard let token = environment[EnvironmentKeys.seatToken],
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Invalid.missingToken
        }

        if let name = environment[EnvironmentKeys.seatRole] {
            guard let role = SeatRole(rawValue: name) else { throw Invalid.seatRole }
            self.role = role
        } else {
            role = nil
        }

        apiBaseURL = Configuration(environment: environment).apiBaseURL
        seatToken = token
    }

    var fieldsWithoutToken: [(String, String)] {
        [("role", role?.rawValue ?? "all")]
    }
}
