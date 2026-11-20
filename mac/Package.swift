// swift-tools-version: 6.2
// 6.2 is the Swift in Xcode 26.0, the oldest Xcode on GitHub's macos-26
// runner image, so every Xcode that runner offers can build this package.

import PackageDescription

// Build subsets. LEVERAGE_ONLY names one lane, and only that lane's targets
// are declared, so a half-written file in one lane never stops another lane
// compiling. Unset, macOS declares everything and Linux declares the `e2e`
// lane, the only one that builds there (no SwiftUI, no Keychain).
//
//   kit       LeverageKit and its tests
//   runner    the reference runner and its tests
//   helper    the helper and its tests
//   services  the app services and their tests
//   app       the app without LeverageAppServices (Live.swift then returns
//             UnavailableRuntime) and its tests
//   e2e       the runner, the helper and the end-to-end tests
#if os(Linux)
let defaultLane = "e2e"
#else
let defaultLane = "all"
#endif
let lane = Context.environment["LEVERAGE_ONLY"].flatMap { $0.isEmpty ? nil : $0 } ?? defaultLane
let lanes = ["kit", "runner", "helper", "services", "app", "e2e", "all"]
precondition(lanes.contains(lane), "LEVERAGE_ONLY must be one of \(lanes.dropLast().joined(separator: ", ")), or unset")

func when(_ names: String...) -> Bool { lane == "all" || names.contains(lane) }

let kit = Target.Dependency(stringLiteral: "LeverageKit")
let support = Target.Dependency(stringLiteral: "LeverageTestSupport")

var products: [Product] = [.library(name: "LeverageKit", targets: ["LeverageKit"])]
var targets: [Target] = [
    .target(name: "LeverageKit"),
    .target(name: "LeverageTestSupport", dependencies: [kit], path: "Tests/LeverageTestSupport"),
]

if when("kit") {
    targets.append(.testTarget(name: "LeverageKitTests", dependencies: [kit, support]))
}
if when("runner", "e2e") {
    products.append(.executable(name: "LeverageRunner", targets: ["LeverageRunner"]))
    targets.append(.executableTarget(name: "LeverageRunner", dependencies: [kit]))
}
if when("runner") {
    targets.append(.testTarget(
        name: "LeverageRunnerTests", dependencies: [kit, "LeverageRunner", support]))
}
if when("helper", "e2e") {
    products.append(.executable(name: "LeverageHelper", targets: ["LeverageHelper"]))
    targets.append(.executableTarget(name: "LeverageHelper", dependencies: [kit]))
}
if when("helper") {
    targets.append(.testTarget(
        name: "LeverageHelperTests", dependencies: [kit, "LeverageHelper", support]))
}
if when("services") {
    products.append(.library(name: "LeverageAppServices", targets: ["LeverageAppServices"]))
    targets.append(.target(name: "LeverageAppServices", dependencies: [kit]))
    targets.append(.testTarget(
        name: "LeverageAppServicesTests", dependencies: [kit, "LeverageAppServices", support]))
}
if when("app") {
    // In the `app` lane the services are not built: Live.swift checks
    // canImport(LeverageAppServices).
    let appDependencies: [Target.Dependency] = lane == "all" ? [kit, "LeverageAppServices"] : [kit]
    products.append(.executable(name: "LeverageApp", targets: ["LeverageApp"]))
    targets.append(.executableTarget(name: "LeverageApp", dependencies: appDependencies))
    targets.append(.testTarget(
        name: "LeverageAppTests", dependencies: [kit, "LeverageApp", support]))
}
if when("e2e") {
    targets.append(.testTarget(name: "LeverageEndToEndTests", dependencies: [kit, support]))
}

let package = Package(
    name: "Leverage",
    platforms: [
        .macOS(.v14)
    ],
    products: products,
    targets: targets
)
