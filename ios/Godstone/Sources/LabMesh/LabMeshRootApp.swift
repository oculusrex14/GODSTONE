import SwiftUI
import GodstoneMesh

/// T54 / GS-LAB-001 step 2: THE iOS LAB'S LAUNCHABLE ENTRY POINT AND ITS RETAINED RUNTIME OWNER.
///
/// The card's own words: "Add an iOS @main App inside Sources/LabMesh, with a WindowGroup for the lab root and ONE
/// RETAINED RUNTIME OWNER. Keep the existing shipping App entry excluded from the lab target."
///
/// So this is the lab's OWN @main -- the shipping `GodstoneApp` stayeth where it is and is NEVER compiled into this
/// target -- and it carrieth ONE owner (`LabRuntimeHolder`), NOT a runtime composed in a view: a runtime composed by a
/// view would be composed again on every recomposition (many where the lab declareth ONE).
@main
struct LabMeshRootApp: App {
    @StateObject private var holder = LabRuntimeHolder()

    var body: some Scene {
        WindowGroup {
            LabRootView()
                .environmentObject(holder)
        }
    }
}

/// THE RETAINED RUNTIME OWNER: exactly one canonical runtime for the life of this lab's process.
public final class LabRuntimeHolder: ObservableObject {
    /// The ONE runtime. `LabRuntime.compose()` returneth the canonical one; nothing here manufactureth readiness.
    public let runtime: LabRuntime

    public init() {
        // GS-LAB-001 (round 266): THE REAL BUILD SAITH `compose()` THROWETH -- and round 262's `swiftc -parse` could not
        // say so, because PARSING IS NOT TYPE-CHECKING. The error is carried rather than swallowed; a lab that cannot
        // compose its runtime must NOT pretend it did.
        self.runtime = try! LabRuntime.compose()
    }
}

/// The lab root: it SAYETH what this build is, and it carrieth no readiness claim of its own.
struct LabRootView: View {
    @EnvironmentObject private var holder: LabRuntimeHolder

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Godstone LabMesh").font(.title)
            Text("EXPERIMENTAL, NONSHIPPING. This build exercises the real adapters on a real device; it is never a store candidate.")
            // GS-LAB-001 (round 266): THE iOS SPELLING, READ FROM `LabRuntime.swift` RATHER THAN ASSUMED FROM THE OTHER ISLE --
            // the android twin carrieth `LabMeshApp.PROFILE`, this isle carrieth `LabProfile.name`, and the compiler said so.
            Text("one retained runtime: " + LabProfile.name)
        }
        .padding()
    }
}
