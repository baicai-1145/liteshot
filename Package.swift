// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "LiteShot",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "LiteShot", targets: ["LiteShot"]),
        .executable(name: "LiteShotOCRHelper", targets: ["LiteShotOCRHelper"]),
        .executable(name: "LiteShotAIHelper", targets: ["LiteShotAIHelper"])
    ],
    targets: [
        .executableTarget(
            name: "LiteShot"
        ),
        .executableTarget(
            name: "LiteShotOCRHelper"
        ),
        .executableTarget(
            name: "LiteShotAIHelper"
        ),
    ]
)
