import Foundation

@MainActor
protocol WorkReferencePasteboard {
    func readString() -> String?
}

@MainActor
protocol WorkReferenceFolderPicker {
    func chooseFolder() -> String?
}

/// The shortcuts for the editable field. Only Paste link validates its input.
@MainActor
struct WorkReferenceInput {
    private let pasteboard: any WorkReferencePasteboard
    private let folderPicker: any WorkReferenceFolderPicker
    private(set) var pasteProblem: AddTaskCopy?

    init(pasteboard: any WorkReferencePasteboard, folderPicker: any WorkReferenceFolderPicker) {
        self.pasteboard = pasteboard
        self.folderPicker = folderPicker
    }

    static func showsButtons(projectID: UUID?, reference: String) -> Bool {
        projectID == nil || reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    mutating func pasteLink() -> String? {
        let reference = pasteboard.readString()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !reference.isEmpty, reference.unicodeScalars.count <= 2_000,
              !reference.contains(where: \.isNewline), !reference.utf8.contains(0) else {
            pasteProblem = .noClipboardReference
            return nil
        }
        pasteProblem = Self.problem(in: reference)
        return pasteProblem == nil ? reference : nil
    }

    func chooseFolder() -> String? {
        guard let path = folderPicker.chooseFolder() else { return nil }
        return (path as NSString).abbreviatingWithTildeInPath
    }

    mutating func referenceChanged() { pasteProblem = nil }

    private static func problem(in reference: String) -> AddTaskCopy? {
        if reference.hasPrefix("/") || reference == "~" || reference.hasPrefix("~/") {
            return embeddedAddressCarriesSignInDetails(in: reference) ? .workLinkSignInDetails : nil
        }

        // An scp-like address has a user and a host before the path's colon.
        // Recognize the password form too so we can refuse it explicitly.
        if reference.range(of: #"\A[^\s/@:]+(?::[^\s/@]+)?@(?:[^\s/?:#@]+|\[[^\s\]]+\]):.+"#,
                           options: .regularExpression) != nil {
            if let queryStart = reference.firstIndex(of: "?") {
                let query = reference[reference.index(after: queryStart)...].prefix { $0 != "#" }
                if hasSecretParameter(in: String(query)) { return .workLinkSignInDetails }
            }
            return embeddedAddressCarriesSignInDetails(in: reference) ? .workLinkSignInDetails : nil
        }

        guard let address = parseAddress(reference),
              let scheme = address.scheme?.lowercased() else { return .noClipboardReference }
        switch scheme {
        case "http", "https", "ssh", "git":
            guard address.host?.isEmpty == false else { return .noClipboardReference }
        case "file":
            guard address.path.hasPrefix("/") else { return .noClipboardReference }
        default:
            return .noClipboardReference
        }
        return carriesSignInDetails(address) ? .workLinkSignInDetails : nil
    }

    private static func parseAddress(_ reference: String) -> URLComponents? {
        guard let url = URL(string: reference, encodingInvalidCharacters: false) else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)
    }

    /// The API's LinkRules also checks addresses embedded in free text.
    private static func embeddedAddressCarriesSignInDetails(in reference: String) -> Bool {
        if reference.range(of: #"(?:\A|[\s(])[^\s/@:]+:[^\s/@]+@[^\s/:]+"#, options: .regularExpression) != nil {
            return true
        }
        return reference.matches(of: #/[A-Za-z][A-Za-z0-9+.-]*://[^\s<>"']+/#).contains { match in
            guard let address = parseAddress(String(match.output)) else { return true }
            return carriesSignInDetails(address)
        }
    }

    private static func carriesSignInDetails(_ address: URLComponents) -> Bool {
        let scheme = address.scheme?.lowercased()
        let isWeb = scheme == "http" || scheme == "https"
        return address.password != nil || (isWeb && address.user?.isEmpty == false)
            || hasSecretParameter(in: address.percentEncodedQuery)
    }

    private static func hasSecretParameter(in query: String?) -> Bool {
        // Match the API's LinkRules on decoded names, including names without values.
        let secretName = #"token|secret|passw|pwd|api[-_]?key|\Akey\z|\Aauth|signature|\Asig\z|credential|session"#
        return query?.split(separator: "&").contains { item in
            let encodedName = String(item.prefix { $0 != "=" })
            let name = encodedName.removingPercentEncoding ?? encodedName
            return name.range(of: secretName, options: [.caseInsensitive, .regularExpression]) != nil
        } ?? false
    }
}
