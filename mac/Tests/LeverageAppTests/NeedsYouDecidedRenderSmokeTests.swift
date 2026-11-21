import AppKit
import Foundation
import LeverageKit
import LeverageTestSupport
import SwiftUI
import Testing

@testable import LeverageApp

@MainActor
@Suite("Needs you and Decided for you render smoke")
struct NeedsYouDecidedRenderSmokeTests {
    @Test("the two screens draw on the signed-in shell")
    func screensDraw() async {
        let rig = ShellRig()
        rig.scriptSignIn(ownerExists: true)
        rig.runtime.fakeSessions.token.value = "stored-made-up-token"
        let app = rig.makeModel()
        await app.start()
        guard let context = app.screens else {
            Issue.record("The signed-in app did not build its screen context")
            return
        }
        #expect(drawsSomething(NeedsYouView().environment(context)))
        #expect(drawsSomething(DecidedView().environment(context)))
    }

    private func drawsSomething(_ view: some View) -> Bool {
        let renderer = ImageRenderer(content: view.frame(width: 900, height: 620).background(Color.white))
        renderer.scale = 1
        guard let tiff = renderer.nsImage?.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.bitmapData
        else { return false }
        let pixel = max(1, bitmap.bitsPerPixel / 8)
        for row in 0..<bitmap.pixelsHigh {
            for column in 0..<bitmap.pixelsWide {
                let at = row * bitmap.bytesPerRow + column * pixel
                if (0..<pixel).contains(where: { data[at + $0] != data[$0] }) { return true }
            }
        }
        return false
    }
}
