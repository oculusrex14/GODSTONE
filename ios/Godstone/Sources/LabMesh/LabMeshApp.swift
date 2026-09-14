import Foundation
import SwiftUI
import GodstoneMesh
import GodstoneCore

// ---------------------------------------------------------------------------
// T54 -- the LabMesh iOS target's application seam.
//
// This target carrieth the lab's OWN bundle identity (io.godstone.labmesh,
// declared in ios/project.yml) and nothing else: the runtime it driveth is the
// canonical one, reached through `LabRuntime`, which liveth in the nonshipping
// GodstoneMesh module. There is no lab-only copy of any authority, and no way to
// manufacture readiness from here.
//
// It is VISIBLY EXPERIMENTAL: the entry point sayeth so, the bundle id sayeth so,
// and the profile gate asserteth that this target and its sources can never reach
// the LIGHT Archive-only application.
// ---------------------------------------------------------------------------

/// The lab application's own marker: identity and profile a reader -- and the
/// profile gate -- can inspect without starting a runtime.
public enum LabMeshApp {
    public static let applicationId: String = LabProfile.labBundleId
    public static let shippingApplicationId: String = LabProfile.shippingBundleId
    public static let profile: String = LabProfile.name
    public static let experimental: Bool = LabProfile.experimental
    public static let manufacturesReadiness: Bool = LabProfile.manufacturesReadiness

    /// Compose the real runtime the lab driveth.
    public static func compose() throws -> LabRuntime { try LabRuntime.compose() }

    /// The honest readiness statement (all platform fields false).
    public static func readiness() -> LabReadiness { LabRuntime.readinessStatement() }
}

/// The lab's own view. It existeth so the target buildeth as an application; the
/// interesting surface is `LabMeshApp`, which carrieth no readiness setter.
public struct LabMeshRootView: View {
    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Godstone LabMesh").font(.headline)
            Text("EXPERIMENTAL / NONSHIPPING").font(.caption)
            Text("profile: \(LabMeshApp.profile)")
            Text("bundle: \(LabMeshApp.applicationId)")
            Text("link layer ready: \(LabMeshApp.readiness().iosLinkLayerReady ? "true" : "false")")
        }
        .padding()
    }
}
