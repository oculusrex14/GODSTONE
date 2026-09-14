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
        .testTarget(name: "GodstoneMeshTests", dependencies: ["GodstoneMesh", "GodstoneCore"]),
        // T54: the nonshipping LabMesh target's test capability, mirrored from
        // ios/Godstone/Tests/LabMeshTests so the lab's real-composition cases
        // EXECUTE on the host rather than existing only as an Xcode target.
        .testTarget(name: "LabMeshTests", dependencies: ["GodstoneMesh", "GodstoneCore"])
    ]
)
