// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "macpixel",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "macpixel",
            path: "Sources/macpixel",
            swiftSettings: [.unsafeFlags(["-Osize"], .when(configuration: .release))],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-dead_strip"], .when(configuration: .release))]
        ),
        .testTarget(
            name: "macpixelTests",
            dependencies: ["macpixel"],
            path: "Tests/macpixelTests"
        ),
    ]
)
