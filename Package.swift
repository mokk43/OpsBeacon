// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpsBeacon",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "OpsBeaconApp", targets: ["OpsBeaconApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.84.0"),
    ],
    targets: [
        .target(
            name: "OpsBeacon",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
            ],
            path: "OpsBeacon",
            exclude: ["App", "Resources"]
        ),
        .executableTarget(
            name: "OpsBeaconApp",
            dependencies: ["OpsBeacon"],
            path: "OpsBeacon/App"
        ),
        .testTarget(
            name: "OpsBeaconTests",
            dependencies: ["OpsBeacon"],
            path: "OpsBeaconTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
