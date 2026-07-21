// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "macEqualizer",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "macEqualizer", targets: ["macEqualizer"])
    ],
    dependencies: [
        .package(url: "https://github.com/ejbills/mediaremote-adapter.git", branch: "master")
    ],
    targets: [
        .executableTarget(
            name: "macEqualizer",
            dependencies: [
                .product(name: "MediaRemoteAdapter", package: "mediaremote-adapter")
            ],
            path: "Sources"
        )
    ]
)
