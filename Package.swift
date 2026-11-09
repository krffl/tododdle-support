// swift-tools-version:6.0
// The Swift package lives in swift/. This root manifest lets Swift Package Manager install
// straight from this repository's version tags.
import PackageDescription

let package = Package(
    name: "TododdleSupport",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "TododdleSupport", targets: ["TododdleSupport"]),
    ],
    targets: [
        .target(name: "TododdleSupport", path: "swift/Sources/TododdleSupport"),
        .testTarget(
            name: "TododdleSupportTests",
            dependencies: ["TododdleSupport"],
            path: "swift/Tests/TododdleSupportTests",
            resources: [.copy("Resources")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
