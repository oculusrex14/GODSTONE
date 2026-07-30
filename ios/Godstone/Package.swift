// swift-tools-version:5.9
import PackageDescription

// The iOS app is assembled from three local packages so the module boundaries
// are enforced by the compiler, exactly as they are on Android:
//     App -> (GodstoneMesh, GodstoneLLM) -> GodstoneCore
// There is deliberately no dependency edge between Mesh and LLM.

let package = Package(
    name: "GodstonePackages",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "GodstoneCore", targets: ["GodstoneCore"]),
        .library(name: "GodstoneMesh", targets: ["GodstoneMesh"]),
        .library(name: "GodstoneLLM",  targets: ["GodstoneLLM"])
    ],
    targets: [
        .target(name: "GodstoneCore"),
        .target(name: "GodstoneMesh", dependencies: ["GodstoneCore"]),
        .target(
            name: "GodstoneLLM",
            dependencies: ["GodstoneCore"],
            cSettings: [.unsafeFlags(["-O3", "-ffast-math"])]
        ),
        .testTarget(name: "GodstoneMeshTests", dependencies: ["GodstoneMesh"]),
        .testTarget(name: "GodstoneLLMTests",  dependencies: ["GodstoneLLM"])
    ]
)
