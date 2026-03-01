// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SwiftBridge",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.89.0")
    ],
    targets: [
        .target(
            name: "BridgeCore",
            dependencies: [
                .product(name: "Vapor", package: "vapor")
            ]
        ),
        .executableTarget(
            name: "MacBridge",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                "BridgeCore",
            ]
        ),
        .testTarget(
            name: "BridgeCoreTests",
            dependencies: ["BridgeCore"]
        ),
    ]
)
