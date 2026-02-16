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
        .executableTarget(
            name: "CalendarBridge",
            dependencies: [
                .product(name: "Vapor", package: "vapor")
            ]
        ),
        .executableTarget(
            name: "ContactsBridge",
            dependencies: [
                .product(name: "Vapor", package: "vapor")
            ]
        ),
        .executableTarget(
            name: "MailBridge",
            dependencies: [
                .product(name: "Vapor", package: "vapor")
            ]
        ),
        .executableTarget(
            name: "ThingsBridge",
            dependencies: [
                .product(name: "Vapor", package: "vapor")
            ]
        ),
        .executableTarget(
            name: "NotesBridge",
            dependencies: [
                .product(name: "Vapor", package: "vapor")
            ]
        ),
        .executableTarget(
            name: "NetNewsWireBridge",
            dependencies: [
                .product(name: "Vapor", package: "vapor")
            ]
        )
    ]
)
