// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "NavCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "NavCore", targets: ["NavCore"])
    ],
    targets: [
        .target(name: "NavCore"),
        .testTarget(
            name: "NavCoreTests",
            dependencies: ["NavCore"],
            resources: [.copy("Resources")]
        )
    ]
)
