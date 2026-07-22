// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "macEqualizer",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "macEqualizer", targets: ["macEqualizer"])
    ],
    targets: [
        .executableTarget(
            name: "macEqualizer",
            path: "Sources"
        )
    ]
)
