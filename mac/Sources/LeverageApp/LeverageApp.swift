import LeverageKit
import SwiftUI

@main
struct LeverageApp: App {
    var body: some Scene {
        Window("leverage", id: "main") {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}

@MainActor
@Observable
final class HealthModel {
    private(set) var line = "API: not checked yet"
    private(set) var isRefreshing = false
    private let client = LeverageClient(baseURL: Configuration().apiBaseURL)

    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            line = healthLine(for: .success(try await client.health()))
        } catch {
            line = healthLine(for: .failure(error))
        }
    }
}

struct ContentView: View {
    @State private var model = HealthModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("leverage")
                .font(.largeTitle)
            Text(model.line)
                .textSelection(.enabled)
            Button("Refresh") {
                Task { await model.refresh() }
            }
            .disabled(model.isRefreshing)
        }
        .padding(24)
        .frame(minWidth: 320, alignment: .leading)
        .task { await model.refresh() }
    }
}
