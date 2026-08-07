// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GodstoneFoundation",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "GodstoneCore", targets: ["GodstoneCore"]),
        .library(name: "GodstoneMesh", targets: ["GodstoneMesh"])
    ],
    targets: [
        .target(name: "GodstoneCore"),
        .target(name: "GodstoneMesh", dependencies: ["GodstoneCore"]),
        .testTarget(name: "GodstoneCoreTests", dependencies: ["GodstoneCore"]),
        .testTarget(name: "GodstoneMeshTests", dependencies: ["GodstoneMesh", "GodstoneCore"])
    ]
)
