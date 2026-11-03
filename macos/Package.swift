// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EpochControl",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "EpochControl", targets: ["EpochControl"]),
        .library(name: "EpochControlKit", targets: ["EpochControlKit"]),
    ],
    targets: [
        // Reads run folders and writes commands. No UI, so it is tested on its own.
        .target(name: "EpochControlKit"),
        .executableTarget(name: "EpochControl", dependencies: ["EpochControlKit"]),
        .testTarget(
            name: "EpochControlKitTests",
            dependencies: ["EpochControlKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
