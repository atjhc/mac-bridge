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
            name: "CalendarBridge",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                "BridgeCore",
            ]
        ),
        .executableTarget(
            name: "ContactsBridge",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                "BridgeCore",
            ]
        ),
        .executableTarget(
            name: "MailBridge",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                "BridgeCore",
            ]
        ),
        .executableTarget(
            name: "ThingsBridge",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                "BridgeCore",
            ]
        ),
        .executableTarget(
            name: "NotesBridge",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                "BridgeCore",
            ]
        ),
        .executableTarget(
            name: "NetNewsWireBridge",
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
