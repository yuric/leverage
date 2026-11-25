import AppKit
import Foundation
import LeverageKit
import LeverageTestSupport
import SwiftUI
import Testing
import Vision

@testable import LeverageApp

/// The Imaginarium tab and its Try it sheet draw in each state and say what
/// FR-031 to FR-033, FR-037 and FR-040 ask: the gallery inside the shell,
/// and the sheet editing, checking, failed and saved, with and without the
/// Imaginarium project. Both are mostly a native scroll view, which
/// ImageRenderer omits, so they are drawn in an offscreen hosting view and
/// read back with text recognition. Clicks need a person.
@MainActor
@Suite("Imaginarium render")
struct ImaginariumRenderTests {
    private let projectID = UUID()

    private func picture() throws -> ImaginariumCatalog.Entry {
        try #require(try ImaginariumCatalog.launch().entries.first { $0.needs.contains(.imageTool) })
    }

    private func app() -> ImaginariumCatalog.Entry {
        ImaginariumCatalog.Entry(
            id: "pocket-to-do", category: "apps", title: "Pocket to-do", description: "A calm to-do app.",
            minutes: 40, fills: [.init(key: "look", label: "Look", defaultValue: "paper")],
            prompt: "Build a to-do app styled like {look}.", doneWhen: ["It opens", "Tasks are kept"], needs: [])
    }

    /// A signed-in context whose pane lists the Imaginarium project, or none.
    private func context(withProject: Bool) async throws -> (ScreenContext, Task<Void, Never>) {
        let rig = ShellRig()
        rig.scriptSignIn(ownerExists: true)
        rig.runtime.fakeSessions.token.value = "stored-made-up-token"
        let projects = withProject
            ? [Project(id: projectID, name: "Imaginarium", imaginarium: true, goal: "", briefVersion: 0)]
            : [Project(id: UUID(), name: "Invoices", goal: "", briefVersion: 0)]
        rig.owner.script { $0.listProjects = { ProjectsList(projects: projects) } }
        let model = rig.makeModel()
        await model.start()
        let context = try #require(model.screens)
        let watch = Task { await context.watchProjects() }
        try #require(await ShellFixtures.eventually { context.paneProjects.map(\.id) == projects.map(\.id) })
        return (context, watch)
    }

    /// An owner API whose answers take the sheet to `state` once submitted.
    private func owner(completing state: TaskState, reason: String? = nil, pending: Bool = false) -> FakeOwnerAPI {
        let api = FakeOwnerAPI()
        let rule = UUID()
        api.script {
            $0.addTask = { _, key in .completed(TaskCreatedResult(taskID: UUID()), key: key.value, command: .addTask) }
            $0.completeContract = { _, _, key in
                pending
                    ? .pending(key: key.value, command: .completeContract)
                    : .completed(nil, key: key.value, command: .completeContract)
            }
            $0.task = { taskID in
                let at = Date()
                return TaskPage(
                    task: TaskSummary(id: taskID, title: "Pocket to-do", state: state),
                    holds: reason == nil ? [] : [
                        Hold(id: UUID(), taskID: taskID, reason: .contractIncomplete, ruleID: rule, openedAt: at),
                    ],
                    reviewerSeatExists: true, asOfSeq: 1,
                    ruleChecks: reason.map { [RuleCheckRow(
                        id: UUID(), ruleID: rule, ruleName: "Specific details", ruleVersionID: UUID(),
                        version: 1, versionSavedAt: at, hook: .taskBeforeReady, momentName: "Before Ready",
                        checker: .model, result: .failed, reason: $0)] } ?? [])
            }
        }
        return api
    }

    /// The view drawn in an offscreen hosting view, as the window would.
    private func picture(_ view: some View, width: CGFloat, height: CGFloat) throws -> NSBitmapImageRep {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: view.frame(width: width, height: height))
        host.frame.size = NSSize(width: width, height: height)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(width * 2), pixelsHigh: Int(height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = host.bounds.size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    /// The text a reader sees in the light appearance, after checking that
    /// the dark appearance draws too.
    private func text(of view: some View, width: CGFloat = 720, height: CGFloat = 570) throws -> String {
        let dark = try picture(view.environment(\.colorScheme, .dark), width: width, height: height)
        #expect(drawsSomething(dark))
        let light = try picture(view.environment(\.colorScheme, .light).background(.white), width: width, height: height)
        let request = VNRecognizeTextRequest()
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: try #require(light.cgImage)).perform([request])
        return try #require(request.results).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    private func drawsSomething(_ bitmap: NSBitmapImageRep) -> Bool {
        guard let data = bitmap.bitmapData else { return false }
        let pixel = max(1, bitmap.bitsPerPixel / 8)
        for row in 0..<bitmap.pixelsHigh {
            let line = data + row * bitmap.bytesPerRow
            for column in 0..<bitmap.pixelsWide {
                let at = line + column * pixel
                for byte in 0..<pixel where at[byte] != data[byte] { return true }
            }
        }
        return false
    }

    @Test("the gallery shows Surprise me and tiles, a picture tile saying it needs an image tool (FR-031, FR-032)")
    func gallery() async throws {
        let (context, watch) = try await context(withProject: true)
        defer { watch.cancel() }
        _ = try picture()
        let shown = try text(of: ImaginariumView().environment(context), width: 1100, height: 900)
        #expect(shown.contains(ImaginariumCopy.headline.text), "\(shown)")
        #expect(shown.contains(ImaginariumCopy.surpriseMe.text), "\(shown)")
        #expect(shown.contains(ImaginariumCopy.needsImageTool.text), "\(shown)")
        #expect(shown.contains(ImaginariumCopy.tryIt.text), "\(shown)")
        #expect(!shown.contains(ImaginariumCopy.noMatchingPrompts.text), "\(shown)")
    }

    @Test("the sheet names the Imaginarium project and offers Ready and Ideas, with no project choice (FR-033)")
    func sheetEditing() async throws {
        let (context, watch) = try await context(withProject: true)
        defer { watch.cancel() }
        let model = ImaginariumTryModel(entry: app(), catalogVersion: 1, api: FakeOwnerAPI())
        let shown = try text(of: ImaginariumTrySheet(model: model).environment(context))
        #expect(shown.contains("Pocket to-do"), "\(shown)")
        #expect(shown.contains(ImaginariumCopy.goesToProject.filled(["project": "Imaginarium"])), "\(shown)")
        #expect(shown.contains(ImaginariumCopy.sendToReady.text), "\(shown)")
        #expect(shown.contains(ImaginariumCopy.saveToIdeas.text), "\(shown)")
        #expect(shown.contains(ImaginariumCopy.copyPrompt.text), "\(shown)")
        #expect(!shown.contains(ImaginariumCopy.projectUnavailable.text), "\(shown)")

        model.copyPrompt(to: { _ in })
        let copied = try text(of: ImaginariumTrySheet(model: model).environment(context))
        #expect(copied.contains(ImaginariumCopy.copied.text), "\(copied)")
        #expect(!copied.contains(ImaginariumCopy.copyPrompt.text), "\(copied)")
    }

    @Test("without the Imaginarium project the sheet says so and offers only Copy prompt")
    func sheetWithoutProject() async throws {
        let (context, watch) = try await context(withProject: false)
        defer { watch.cancel() }
        let model = ImaginariumTryModel(entry: app(), catalogVersion: 1, api: FakeOwnerAPI())
        let shown = try text(of: ImaginariumTrySheet(model: model).environment(context))
        #expect(shown.contains(ImaginariumCopy.projectUnavailable.text), "\(shown)")
        #expect(shown.contains(ImaginariumCopy.copyPrompt.text), "\(shown)")
        #expect(!shown.contains(ImaginariumCopy.sendToReady.text), "\(shown)")
        #expect(!shown.contains(ImaginariumCopy.saveToIdeas.text), "\(shown)")
    }

    @Test("a picture entry's sheet says it needs an image tool (FR-032)")
    func sheetForPicture() async throws {
        let (context, watch) = try await context(withProject: true)
        defer { watch.cancel() }
        let model = ImaginariumTryModel(entry: try picture(), catalogVersion: 1, api: FakeOwnerAPI())
        let shown = try text(of: ImaginariumTrySheet(model: model).environment(context))
        #expect(shown.contains(ImaginariumCopy.needsImageTool.text), "\(shown)")
    }

    @Test("the sheet shows a rule check in progress, and a failed save with Try again")
    func sheetWaitingAndFailed() async throws {
        let (context, watch) = try await context(withProject: true)
        defer { watch.cancel() }

        let checking = ImaginariumTryModel(entry: app(), catalogVersion: 1, api: owner(completing: .ready, pending: true))
        await checking.submit(.ready, projectID: projectID)
        #expect(checking.state == .checking)
        let waiting = try text(of: ImaginariumTrySheet(model: checking).environment(context))
        #expect(waiting.contains("Waiting for a rule check"), "\(waiting)")
        #expect(!waiting.contains(ImaginariumCopy.sendToReady.text), "\(waiting)")

        let failing = FakeOwnerAPI()
        failing.script { $0.addTask = { _, _ in throw URLError(.timedOut) } }
        let failed = ImaginariumTryModel(entry: app(), catalogVersion: 1, api: failing)
        await failed.submit(.ready, projectID: projectID)
        guard case .failed = failed.state else {
            Issue.record("expected a failed save, got \(failed.state)")
            return
        }
        let shown = try text(of: ImaginariumTrySheet(model: failed).environment(context))
        #expect(shown.contains(ImaginariumCopy.tryAgain.text), "\(shown)")
    }

    @Test("a saved task says where it went, with the rule's reason in Backlog, and offers See it on the board (FR-040)",
          arguments: [TaskState.ready, .backlog, .ideas])
    func sheetSaved(_ state: TaskState) async throws {
        let (context, watch) = try await context(withProject: true)
        defer { watch.cancel() }
        let reason = state == .backlog ? "Name the intended audience." : nil
        let model = ImaginariumTryModel(entry: app(), catalogVersion: 1, api: owner(completing: state, reason: reason))
        await model.submit(state == .ideas ? .ideas : .ready, projectID: projectID)
        #expect(model.state == .saved(state, reason: reason))
        #expect(model.savedProjectID == projectID)
        let shown = try text(of: ImaginariumTrySheet(model: model).environment(context))
        #expect(shown.contains(ImaginariumCopy.savedTitle(state).text), "\(shown)")
        #expect(shown.contains(ImaginariumCopy.seeOnBoard.text), "\(shown)")
        #expect(shown.contains(ImaginariumCopy.keepBrowsing.text), "\(shown)")
        if let reason { #expect(shown.contains(reason), "\(shown)") }
    }
}
