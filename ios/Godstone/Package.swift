// swift-tools-version:5.9
import PackageDescription

// The iOS app is assembled from three local packages so the module boundaries
// are enforced by the compiler, exactly as they are on Android:
//     App -> (GodstoneMesh, GodstoneLLM) -> GodstoneCore
// There is deliberately no dependency edge between Mesh and LLM.

let package = Package(
    name: "GodstonePackages",
    // iOS 16 is the shipping target. macOS is declared so the pure-logic
    // library closure (GodstoneCore + GodstoneMesh + tests) can be compiled
    // and verified on a Mac host / CI without an iOS simulator runtime; the
    // GodstoneLLM target (UIKit + llama.cpp) is iOS-only and is not built in
    // that closure. Declaring macOS here does not change the iOS app target,
    // which is assembled by XcodeGen from ios/project.yml.
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "GodstoneCore", targets: ["GodstoneCore"]),
        .library(name: "GodstoneMesh", targets: ["GodstoneMesh"]),
        .library(name: "GodstoneLLM",  targets: ["GodstoneLLM"])
    ],
    targets: [
        .target(name: "GodstoneCore"),
        .target(name: "GodstoneMesh", dependencies: ["GodstoneCore"]),
        // The Objective-C++ bridge over llama.cpp lives in its own C target so
        // that GodstoneLLM stays pure-Swift. SwiftPM does not support a single
        // target mixing .swift with .h/.mm, so the split is required for the
        // package to resolve at all (even when GodstoneLLM is not being built).
        // GodstoneLLMBridge itself only compiles when third_party/llama.cpp is
        // fetched; until then it is simply never built.
        .target(
            name: "GodstoneLLMBridge",
            dependencies: ["GodstoneCore"],
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("../../third_party/llama.cpp/include"),
                .headerSearchPath("../../third_party/llama.cpp/ggml/include"),
                .unsafeFlags(["-O3", "-ffast-math"])
            ]
        ),
        .target(
            name: "GodstoneLLM",
            dependencies: ["GodstoneCore", "GodstoneLLMBridge"]
        ),
        // GodstoneLLMTests is intentionally absent: GodstoneLLM cannot build
        // without the third_party/llama.cpp submodule, so its test target cannot
        // build either. The Mesh tests have no such dependency.
        .testTarget(name: "GodstoneMeshTests", dependencies: ["GodstoneMesh", "GodstoneCore"])
    ]
)
