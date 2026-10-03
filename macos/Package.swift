// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DaylightDrop",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "DaylightDropApp",
            targets: ["DaylightDropApp"]
        ),
        .library(
            name: "DaylightDropKit",
            targets: ["DaylightDropKit"]
        ),
        .library(
            name: "DaylightDropTransport",
            targets: ["DaylightDropTransport"]
        ),
    ],
    targets: [
        .target(
            name: "DaylightDropTransport",
            path: "Sources/DaylightDropApp/Transport"
        ),
        .target(
            name: "DaylightDropKit",
            dependencies: ["DaylightDropTransport"],
            path: "Sources/DaylightDropApp",
            exclude: ["Transport"]
        ),
        .executableTarget(
            name: "DaylightDropApp",
            dependencies: ["DaylightDropKit", "DaylightDropTransport"],
            path: "Sources/DaylightDropLauncher"
        ),
        .testTarget(
            name: "TransportTests",
            dependencies: ["DaylightDropTransport"],
            path: "Tests/TransportTests"
        ),
        .testTarget(
            name: "AppTests",
            dependencies: ["DaylightDropKit", "DaylightDropTransport"],
            path: "Tests/AppTests"
        ),
    ]
)
