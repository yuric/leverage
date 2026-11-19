import AppKit
import Foundation
import LeverageKit
import LeverageTestSupport
import SwiftUI
import Testing

@testable import LeverageApp

/// One render per screen with no window: the view builds, lays out and draws
/// something. Clicks and focus are not covered here (they need a person).
@MainActor
@Suite("Render smoke")
struct RenderSmokeTests {
    private func render(_ view: some View, width: CGFloat = 900, height: CGFloat = 620) -> NSImage? {
        // An opaque white ground under the view: where the view draws nothing
        // the picture is one flat colour, whatever the renderer's buffer held
        // before (a clear picture was once read as drawn in a full run).
        let renderer = ImageRenderer(content: view.frame(width: width, height: height).background(Color.white))
        renderer.scale = 1
        return renderer.nsImage
    }

    /// True when the picture is not one flat colour: some pixel differs from the first.
    private func drawsSomething(_ image: NSImage?) -> Bool {
        guard let image, image.size.width > 0, image.size.height > 0,
              let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.bitmapData
        else { return false }
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

    private func readyModel() async -> (AppModel, ScreenContext) {
        let rig = ShellRig()
        rig.scriptSignIn(ownerExists: true)
        rig.runtime.fakeSessions.token.value = "stored-made-up-token"
        let model = rig.makeModel()
        await model.start()
        return (model, model.screens!)
    }

    @Test("the check that something was drawn can tell a blank picture from a drawn one")
    func checkerWorks() {
        #expect(!drawsSomething(render(Color.clear)))
        #expect(!drawsSomething(render(Color.blue)))
        #expect(drawsSomething(render(Text(ShellCopy.appName.text).font(.largeTitle))))
        #expect(!drawsSomething(nil))
    }

    @Test("the start-up screens draw, one for each state the server can be in")
    func startupScreens() async {
        for state in [ServerState.dockerMissing, .dockerStarting, .dockerNotStarting, .imageMissing, .failed(reason: "made up")] {
            let rig = ShellRig()
            rig.runtime.fakeServer.afterStart.value = state
            let model = rig.makeModel()
            await model.start()
            #expect(drawsSomething(render(StartupView(model: model))), "\(state)")
        }
        let rig = ShellRig()
        rig.owner.script { $0.setupState = { throw URLError(.timedOut) } }
        let model = rig.makeModel()
        await model.start()
        #expect(model.phase == .cannotReachServer)
        #expect(drawsSomething(render(StartupView(model: model))))
    }

    @Test("the sign-in screen draws for both modes, light and dark, and with an error showing")
    func signInScreens() async {
        for mode in [SignInModel.Mode.create, .signIn] {
            let model = SignInModel(mode: mode, api: FakeOwnerAPI(), onSignedIn: { _ in })
            #expect(drawsSomething(render(SignInView(model: model), height: 420)), "\(mode)")
            #expect(drawsSomething(render(SignInView(model: model).environment(\.colorScheme, .dark), height: 420)))
        }
        let failing = SignInModel(mode: .signIn, api: FakeOwnerAPI(), onSignedIn: { _ in })
        failing.email = ShellFixtures.madeUpEmail
        failing.password = ShellFixtures.madeUpPassword
        await failing.submit()
        #expect(failing.state != .idle)
        #expect(drawsSomething(render(SignInView(model: failing), height: 420)))
    }

    @Test("the window frame draws once signed in, in both appearances")
    func rootView() async {
        let (model, _) = await readyModel()
        #expect(model.phase == .ready)
        #expect(drawsSomething(render(RootView(model: model))))
        #expect(drawsSomething(render(RootView(model: model).environment(\.colorScheme, .dark))))
    }

    @Test("the side pane and the toolbar draw for each place the owner can be")
    func paneAndToolbar() async {
        let (_, context) = await readyModel()
        for place in [Navigator.Place.board, .agents, .credentials] {
            context.navigator.show(place)
            #expect(drawsSomething(render(SidePane(context: context))), "\(place)")
            #expect(drawsSomething(render(Toolbar(context: context), height: 80)), "\(place)")
        }
        context.navigator.open(task: UUID())
        #expect(drawsSomething(render(Toolbar(context: context), height: 80)))
    }

    @Test("each screen of the content area draws inside the shell's context, built with no arguments")
    func contentScreens() async {
        let (_, context) = await readyModel()
        #expect(drawsSomething(render(BoardView().environment(context))))
        #expect(drawsSomething(render(TaskPageView().environment(context))))
        #expect(drawsSomething(render(AddTaskSheet().environment(context))))
        #expect(drawsSomething(render(RosterView().environment(context))))
        #expect(drawsSomething(render(CredentialsView().environment(context))))
    }

    @Test("the design tokens carry the mockup's numbers")
    func tokens() {
        #expect(Tokens.Radius.window == 18)
        #expect(Tokens.Radius.nav == 14)
        #expect(Tokens.Radius.card == 12)
        #expect(Tokens.Radius.tab == 10)
        #expect(Tokens.Radius.control == 8)
        #expect(Tokens.Radius.chip == 6)
        #expect(Tokens.FontSize.head == 15)
        #expect(Tokens.FontSize.body == 13)
        #expect(Tokens.FontSize.small == 12)
        #expect(Tokens.FontSize.badge == 11)
        #expect(Tokens.sidePaneWidth == 188)
        #expect(Tokens.minimumWindowWidth == 860)
    }

    @Test("colours are written as hex in the tokens and read back exactly")
    func hexColours() {
        let blue = NSColor(hex: 0x0A63E0).usingColorSpace(.sRGB)
        #expect(blue != nil)
        #expect(abs((blue?.redComponent ?? 0) - 10.0 / 255.0) < 0.001)
        #expect(abs((blue?.greenComponent ?? 0) - 99.0 / 255.0) < 0.001)
        #expect(abs((blue?.blueComponent ?? 0) - 224.0 / 255.0) < 0.001)
    }
}
