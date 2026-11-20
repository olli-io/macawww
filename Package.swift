// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "macawww",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "macawww",
            path: "Sources/macawww",
            swiftSettings: [.unsafeFlags(["-Osize"], .when(configuration: .release))],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-dead_strip"], .when(configuration: .release))]
        ),
        .testTarget(
            name: "macawwwTests",
            dependencies: ["macawww"],
            path: "Tests/macawwwTests"
        ),
    ]
)
