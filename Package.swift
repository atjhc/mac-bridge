// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SwiftBridge",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/vapor/vapor.git", from: "4.0.0"),
        .package(url: "https://github.com/apple/swift-testing.git", from: "0.12.0"),
    ],
    targets: [
        .target(
            name: "BridgeCore"
        ),
        .target(
            name: "BridgeHTTP",
            dependencies: [
                "BridgeCore",
                .product(name: "Hummingbird", package: "hummingbird"),
            ]
        ),
        .executableTarget(
            name: "CalendarBridge",
            dependencies: ["BridgeHTTP"]
        ),
        .executableTarget(
            name: "ContactsBridge",
            dependencies: ["BridgeHTTP"]
        ),
        .executableTarget(
            name: "MailBridge",
            dependencies: ["BridgeHTTP"]
        ),
        .executableTarget(
            name: "ThingsBridge",
            dependencies: ["BridgeHTTP"]
        ),
        .executableTarget(
            name: "NotesBridge",
            dependencies: ["BridgeHTTP"]
        ),
        .executableTarget(
            name: "NetNewsWireBridge",
            dependencies: ["BridgeHTTP"]
        ),
        .executableTarget(
            name: "MacBridge",
            dependencies: [
                "BridgeCore",
                .product(name: "Vapor", package: "vapor"),
            ],
            exclude: ["API/Mail.h"]
        ),
        .testTarget(
            name: "BridgeCoreTests",
            dependencies: [
                "BridgeCore",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
    ]
)
