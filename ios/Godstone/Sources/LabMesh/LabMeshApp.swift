import Foundation
import SwiftUI
// GS-UX-001 `accessibility`: `UIAccessibility.post` is the platform's own announcement mechanism, and this target is
// iOS-only (the lab is a launchable application), so the import carrieth no portability cost.
import UIKit
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

// ---------------------------------------------------------------------------
// *** GS-UX-001 `accessibility` (iOS isle): THE LIVE-REGION MECHANISM THE HOST
// HAS AND SWIFTUI LACKETH A DECLARATION FOR. ***
//
// *The Android twin declarith a live region with one modifier (`LiveRegionMode.Polite`/`.Assertive`) and a semantics
// court can READ it back off the rendered node. **SWIFTUI HAS NO SUCH DECLARATION**: a status `Text` whose value
// changeth is repainted and, without help, never announced.*
//
// *So the iOS road is the platform's OWN mechanism, and it taketh TWO parts:*
//
//   1. `.accessibilityAddTraits(.updatesFrequently)` -- the REAL platform trait that telleth assistive technology the
//      element's value changeth often and must be re-announced rather than merely re-read on request;
//   2. `UIAccessibility.post(notification: .announcement, argument:)` -- the platform's own announcement, posted AT
//      THE MOMENT the state changeth.
//
// *** AND THE HONEST LIMIT IS STATED HERE RATHER THAN DISCOVERED BY AN AUDITOR. *** *XCUITest carrieth NO API to read
// an element's traits and NO API to observe a posted announcement -- so the UI lane can assert the TRIGGER (the
// rendered value changeth) and the WORDS (the shared vocabulary), and CANNOT assert the announcement itself. That
// half belongeth to the human screen-reader acceptance (`gs-ux-001.human-accessibility-acceptance`), which the ledger
// keepeth EXTERNAL. **WHAT THIS FILE MUST NOT DO IS SKIP THE REAL MECHANISM BECAUSE IT IS HARD TO OBSERVE.***
// ---------------------------------------------------------------------------

/// The lab's announcement door: the ONE place either lab status surface speaketh through.
///
/// *A second call site in a second view would be a second convention, and the two would drift; so the views announce
/// through this and the mechanism is named once.*
enum LabAnnouncements {
    /// Post one announcement through the platform's own mechanism.
    ///
    /// *`argument` is the SHARED vocabulary's words (never a phrase invented here), so what a screen reader speaketh
    /// is what the durable projection sayeth.*
    static func announce(_ words: String) {
        guard !words.isEmpty else { return }
        UIAccessibility.post(notification: .announcement, argument: words)
    }
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
