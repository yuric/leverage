import LeverageKit
import SwiftUI

struct TaskSettingsSheet: View {
    @Bindable var model: TaskSettingsModel
    let projects: [Project]
    let dismiss: () -> Void

    var body: some View { EmptyView() }
}
