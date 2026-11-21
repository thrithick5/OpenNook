// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OpenNook",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "OpenNook",
            path: "Sources/OpenNook"
        ),
        .testTarget(
            name: "OpenNookTests",
            dependencies: ["OpenNook"],
            path: "Tests/OpenNookTests"
        )
    ]
)
