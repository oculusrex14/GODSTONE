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
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            LabRootView()
                .environmentObject(holder)
                // GS-LAB-001 step 4 (round 267): THE LIFECYCLE REACHETH THE **SAME RUNTIME OWNER**. The card asketh that
                // 'foreground/background/protected-data lifecycle' be connected to it -- so the phase is handed to the
                // holder, which carrieth the ONE runtime, rather than to the view that merely showeth it.
                // GS-LAB-001 step 4: THE ONE-PARAMETER FORM, because the two-parameter `onChange(of:initial:_:)` is
                // iOS 17+ AND THE LAB TARGETS A LOWER DEPLOYMENT TARGET -- the compiler named the line and the reason,
                // which is the instrument working as intended rather than a setback.
                .onChange(of: scenePhase) { phase in holder.lifecycleChanged(to: phase) }
        }
    }
}

/// THE RETAINED RUNTIME OWNER: exactly one canonical runtime for the life of this lab's process.
public final class LabRuntimeHolder: ObservableObject {
    /// The ONE runtime. `LabRuntime.compose()` returneth the canonical one; nothing here manufactureth readiness.
    public let runtime: LabRuntime

    /// GS-LAB-001 step 4: THE OWNER HEARETH THE LIFECYCLE. It recordeth the last phase, so that a court (and a reader)
    /// can see that the notification reached THE RUNTIME'S OWNER and not a view -- and so that a later step may pause or
    /// resume owned work without a second, competing owner.
    private(set) var lastLifecyclePhase: ScenePhase?

    public func lifecycleChanged(to phase: ScenePhase) {
        lastLifecyclePhase = phase
    }

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
        // GS-LAB-001 step 4's NAVIGATION HALF (round 268): MINIMAL VIEWS FOR THE FIVE JOURNEYS THE CARD NAMETH --
        // identity, contacts, conversation, SOS and diagnostics. They are MINIMAL ON PURPOSE: the card asketh for
        // navigation to them, not for finished screens, and `GS-UX-001` (which dependeth on this finding) carrieth the
        // deeper journeys. Each screen SAYETH what it is and carrieth NO readiness claim.
        TabView {
            LabIdentityView().tabItem { Text("Identity") }
            LabContactsView().tabItem { Text("Contacts") }
            LabConversationView().tabItem { Text("Conversation") }
            LabSosView().tabItem { Text("SOS") }
            LabDiagnosticsView().tabItem { Text("Diagnostics") }
        }
        .environmentObject(holder)
    }
}

/// THE LAB'S OWN MARKER, repeated on every screen: who this build is, and that it maketh no readiness claim.
private struct LabBanner: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Godstone LabMesh").font(.headline)
            Text("EXPERIMENTAL, NONSHIPPING -- one retained runtime: " + LabProfile.name)
                .font(.footnote)
        }
    }
}

struct LabIdentityView: View {
    var body: some View { VStack { LabBanner(); Text("Identity").font(.title) } }
}

struct LabContactsView: View {
    var body: some View { VStack { LabBanner(); Text("Contacts").font(.title) } }
}

struct LabConversationView: View {
    var body: some View { VStack { LabBanner(); Text("Conversation").font(.title) } }
}

struct LabSosView: View {
    var body: some View { VStack { LabBanner(); Text("SOS").font(.title) } }
}

struct LabDiagnosticsView: View {
    @EnvironmentObject private var holder: LabRuntimeHolder
    var body: some View {
        VStack {
            LabBanner()
            Text("Diagnostics").font(.title)
            // THE ONE PLACE THE LAB SHOWETH THE LIFECYCLE IT HEARETH -- so that 'the lifecycle reacheth the same owner'
            // is VISIBLE to a human and to a reader, not merely assertable in a control.
            Text("last lifecycle phase: " + String(describing: holder.lastLifecyclePhase))
                .font(.footnote)
        }
    }
}
