import Foundation
import LeverageKit

// Prints the helper's version and the API's health. Exits 0 when the API
// answers healthy, 1 otherwise.

let configuration = Configuration()
let sessionConfiguration = URLSessionConfiguration.ephemeral
sessionConfiguration.timeoutIntervalForRequest = 10
let client = LeverageClient(
    baseURL: configuration.apiBaseURL,
    session: URLSession(configuration: sessionConfiguration))

print("LeverageHelper \(leverageMacVersion)")

let result: Result<Health, any Error>
do {
    result = .success(try await client.health())
} catch {
    result = .failure(error)
}

let line = healthLine(for: result)
if case .success(let health) = result, health.status == "ok" {
    print(line)
    exit(0)
} else {
    FileHandle.standardError.write(Data((line + "\n").utf8))
    exit(1)
}
