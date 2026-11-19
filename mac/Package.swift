// swift-tools-version: 6.2
// 6.2 is the Swift in Xcode 26.0, the oldest Xcode on GitHub's macos-26
// runner image, so every Xcode that runner offers can build this package.

import PackageDescription

let package = Package(
    name: "Leverage",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "LeverageKit", targets: ["LeverageKit"]),
        .executable(name: "LeverageHelper", targets: ["LeverageHelper"]),
        .executable(name: "LeverageApp", targets: ["LeverageApp"]),
    ],
    targets: [
        .target(name: "LeverageKit"),
        .executableTarget(name: "LeverageHelper", dependencies: ["LeverageKit"]),
        .executableTarget(name: "LeverageApp", dependencies: ["LeverageKit"]),
        .testTarget(name: "LeverageKitTests", dependencies: ["LeverageKit"]),
    ]
)
