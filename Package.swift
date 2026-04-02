// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ChatbaseSDK",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "ChatbaseSDK", targets: ["ChatbaseSDK"]),
    ],
    targets: [
        .target(name: "ChatbaseSDK", path: "Sources/ChatbaseSDK"),
        .testTarget(name: "ChatbaseSDKTests", dependencies: ["ChatbaseSDK"], path: "Tests/ChatbaseSDKTests"),
    ]
)
