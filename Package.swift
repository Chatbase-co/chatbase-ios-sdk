// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ChatbaseSDK",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ChatbaseSDK", targets: ["ChatbaseSDK"]),
    ],
    targets: [
        .target(name: "ChatbaseSDK", path: "Sources/ChatbaseSDK"),
        .testTarget(name: "ChatbaseSDKTests", dependencies: ["ChatbaseSDK"], path: "Tests/ChatbaseSDKTests"),
    ]
)
