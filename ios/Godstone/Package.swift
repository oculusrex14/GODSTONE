// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GodstonePackages",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "GodstoneCore", targets: ["GodstoneCore"]),
        .library(name: "GodstoneMesh", targets: ["GodstoneMesh"]),
        .library(name: "GodstoneLLM", targets: ["GodstoneLLM"])
    ],
    targets: [
        .target(name: "GodstoneCore"),
        .target(name: "GodstoneMesh", dependencies: ["GodstoneCore"]),
        .target(
            name: "GodstoneLLMBridge",
            dependencies: ["GodstoneCore"],
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("../../third_party/llama.cpp/include"),
                .headerSearchPath("../../third_party/llama.cpp/ggml/include"),
                .unsafeFlags(["-O3"])
            ]
        ),
        .target(name: "GodstoneLLM", dependencies: ["GodstoneCore", "GodstoneLLMBridge"]),
        .testTarget(name: "GodstoneCoreTests", dependencies: ["GodstoneCore"]),
        .testTarget(name: "GodstoneMeshTests", dependencies: ["GodstoneMesh", "GodstoneCore"])
    ]
)
