// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DaylightDrop",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "DaylightDropTransport",
            targets: ["DaylightDropTransport"]
        ),
        .library(
            name: "DaylightDropApp",
            targets: ["DaylightDropApp"]
        ),
    ],
    targets: [
        .target(
            name: "DaylightDropTransport",
            path: "Sources/DaylightDropApp/Transport"
        ),
        .target(
            name: "DaylightDropApp",
            dependencies: ["DaylightDropTransport"],
            path: "Sources/DaylightDropApp",
            exclude: ["Transport"]
        ),
        .testTarget(
            name: "TransportTests",
            dependencies: ["DaylightDropTransport"],
            path: "Tests/TransportTests"
        ),
        .testTarget(
            name: "AppTests",
            dependencies: ["DaylightDropApp", "DaylightDropTransport"],
            path: "Tests/AppTests"
        ),
    ]
)
