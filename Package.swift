// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "LiteShot",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "LiteShot", targets: ["LiteShot"])
    ],
    targets: [
        .executableTarget(
            name: "LiteShot"
        ),
    ]
)
