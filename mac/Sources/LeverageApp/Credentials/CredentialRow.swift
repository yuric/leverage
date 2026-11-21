import Foundation
import LeverageKit
import SwiftUI

struct CredentialRow: Identifiable, Equatable, Sendable {
    enum Action: Hashable, CaseIterable, Sendable {
        case rename, verify, signInAgain, remove
    }

    let id: UUID
    let name: String
    let kind: CredentialKind
    let kindLine: String
    let providerName: String
    let provider: Provider
    let usage: String
    let isSignedOut: Bool
    let accountDetails: [String]
    let figures: [FigureTile.Content]
    let resetsLine: String?
    let ageLine: String?
    let readingState: ReadingState?
    let readingLine: String?
    let modelLine: String?
    let tokenLine: String?

    var canSignInAgain: Bool { kind == .login && isSignedOut }
    var actions: [Action] { Action.allCases.filter { kind == .login || $0 != .signInAgain } }

    init(
        _ entry: CredentialWithReading, now: Date, calendar: Calendar = .current, locale: Locale = .current,
        testedVersions: [String]? = nil
    ) {
        let credential = entry.credential
        let clock = ResetClock(now: { now }, calendar: calendar, locale: locale)
        id = credential.id
        name = credential.name
        kind = credential.kind
        provider = credential.provider
        providerName = ProviderNames.name(credential.provider)
        kindLine = (credential.kind == .login ? CredentialsCopy.kindLogin : .kindToken).text
        isSignedOut = credential.state == .signedOut
        accountDetails = [credential.plan, credential.accountEmail].compactMap { $0 }
        readingState = entry.reading?.state
        let versions = testedVersions ?? credential.provider.testedToolVersions
        readingLine = Self.readingLine(entry.reading, credential: credential, testedVersions: versions)
        if credential.state == .signedOut {
            usage = (credential.kind == .login ? CredentialsCopy.usageSignedOut : .tokenStopped).text
        } else if credential.isLimited(at: now) {
            if let until = credential.limitedUntil {
                usage = CredentialsCopy.usageLimitUntil.filled(["time": ResetTime.text(for: until, clock: clock)])
            } else {
                usage = CredentialsCopy.usageLimitNoTime.filled(["provider": providerName])
            }
        } else {
            usage = credential.kind == .login && readingLine == nil ? CredentialsCopy.usageReady.text : ""
        }

        figures = entry.reading?.figures.map { FigureTile.Content($0, clock: clock) } ?? []
        ageLine = entry.reading.flatMap { Self.ageLine(observedAt: $0.observedAt, now: now, locale: locale) }
        if credential.kind == .login {
            resetsLine = Self.resetsLine(entry.reading?.resets, clock: clock)
            modelLine = credential.model.map { CredentialsCopy.handoffModel.filled(["model": $0]) }
            tokenLine = nil
        } else {
            resetsLine = nil
            modelLine = nil
            tokenLine = CredentialsCopy.tokenUse.text
        }
    }

    private static func readingLine(
        _ reading: CredentialReading?, credential: Credential, testedVersions: [String]
    ) -> String? {
        guard let reading else { return nil }
        switch reading.state {
        case .ok:
            return nil
        case .signedOut:
            return (credential.kind == .login ? CredentialsCopy.lookedSignedOut : .tokenStopped).text
        case .unavailable:
            guard credential.kind == .login else { return CredentialsCopy.unavailable.text }
            guard !testedVersions.isEmpty else {
                return CredentialsCopy.noReader.filled(["provider": ProviderNames.name(credential.provider)])
            }
            if let version = reading.toolVersion.flatMap(versionNumber),
               !testedVersions.contains(where: { versionNumber($0) == version }) {
                return CredentialsCopy.untestedVersion.filled([
                    "tool": ProviderNames.tool(credential.provider), "version": version,
                ])
            }
            return CredentialsCopy.unavailable.text
        }
    }

    /// Match the helper's version gate (CR-37). The catalog holds the tested versions.
    private static func versionNumber(_ version: String) -> String? {
        version.range(of: #"[0-9][0-9.]*"#, options: .regularExpression).map { String(version[$0]) }
    }

    private static func ageLine(observedAt: Date, now: Date, locale: Locale) -> String? {
        guard now.timeIntervalSince(observedAt) > 600 else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        let age = formatter.localizedString(for: observedAt, relativeTo: now)
        return CredentialsCopy.readAge.filled(["age": age])
    }

    private static func resetsLine(_ resets: [Reset]?, clock: ResetClock) -> String {
        let values = resets?.map { reset -> String in
            let count = reset.count.formatted(.number.locale(clock.locale))
            guard reset.count > 0 else { return count }
            let kind: CredentialsCopy = switch reset.kind {
            case .fiveHour: .resetFiveHour
            case .weekly: .resetWeekly
            case .perModel: .resetPerModel
            case .full: .resetFull
            }
            let quantity = CredentialsCopy.resetCount.filled(["count": count, "kind": kind.text])
            guard let expiry = reset.expiresAt else { return quantity }
            return CredentialsCopy.resetExpiry.filled(["reset": quantity, "time": ResetTime.text(for: expiry, clock: clock)])
        }
        let shown = values.map { $0.isEmpty ? 0.formatted(.number.locale(clock.locale)) : $0.joined(separator: " · ") } ?? "—"
        return CredentialsCopy.resetsAvailable.filled(["resets": shown])
    }
}

struct CredentialRowView: View {
    let row: CredentialRow
    let model: CredentialsModel
    let rename: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                statusDot
                Text(verbatim: row.name)
                    .font(.system(size: Tokens.FontSize.body, weight: .semibold))
                    .accessibilityValue(row.kindLine)
                if row.kind == .apiToken {
                    detail(MaskedLabel.forToken(""))
                        .accessibilityHidden(true)
                }
                Spacer(minLength: 0)
                menu
            }
            if !row.accountDetails.isEmpty {
                detail(row.accountDetails.joined(separator: " · "))
                    .textSelection(.enabled)
            }
            if !row.usage.isEmpty {
                detail(row.usage)
            }
            if let line = row.readingLine, line != row.usage {
                detail(line)
            }
            if !row.figures.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 8)], spacing: 8) {
                    ForEach(row.figures.indices, id: \.self) { index in
                        FigureTile(content: row.figures[index])
                    }
                }
            }
            if let line = row.resetsLine { detail(line) }
            if let line = row.ageLine { detail(line) }
            if let line = row.modelLine { detail(line) }
            if let line = row.tokenLine { detail(line) }
            if let line = model.progress(for: row.id) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    detail(line)
                }
            }
            if let line = model.failure(for: row.id), line != row.readingLine, line != row.usage,
               !(line == CredentialsCopy.unavailable.text && row.readingState == .unavailable) {
                Text(verbatim: line)
                    .font(.system(size: Tokens.FontSize.small, weight: .medium))
                    .foregroundStyle(Tokens.Tone.stop.foreground)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.Palette.surface, in: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                .strokeBorder(Tokens.Palette.line, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    private var statusDot: some View {
        Circle()
            .fill(row.isSignedOut ? Tokens.Tone.stop.foreground : Tokens.Tone.done.foreground)
            .frame(width: 8, height: 8)
            .accessibilityLabel((row.isSignedOut ? CredentialsCopy.statusSignedOut : .active).text)
    }

    private var menu: some View {
        Menu {
            ForEach(row.actions, id: \.self) { action in
                switch action {
                case .rename:
                    Button(CredentialsCopy.rename.text, action: rename)
                case .verify:
                    Button(CredentialsCopy.verify.text) { Task { await model.verify(row.id) } }
                        .disabled(!model.canVerify(row.id))
                case .signInAgain:
                    Button(CredentialsCopy.signInAgain.text) { Task { await model.signInAgain(row.id) } }
                        .disabled(!row.canSignInAgain || !model.canVerify(row.id))
                case .remove:
                    Button(CredentialsCopy.remove.text, role: .destructive) { model.askToRemove(row.id) }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel(CredentialsCopy.rowActions.filled(["name": row.name]))
    }

    private func detail(_ line: String) -> some View {
        Text(verbatim: line)
            .font(.system(size: Tokens.FontSize.small))
            .foregroundStyle(Tokens.Palette.text2)
    }
}
