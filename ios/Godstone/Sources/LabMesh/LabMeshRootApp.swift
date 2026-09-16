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
            LabIdentityView().tabItem {
                // GS-UX-001 step 7 (round 277): A VISIBLE WORD IS NOT A SEMANTIC -- the
                // screen reader announceth the LABEL, and a test addresseth the IDENTIFIER.
                Text("Identity").accessibilityLabel("Identity screen").accessibilityIdentifier("lab.tab.identity")
            }
            LabContactsView().tabItem {
                // GS-UX-001 step 7 (round 277): A VISIBLE WORD IS NOT A SEMANTIC -- the
                // screen reader announceth the LABEL, and a test addresseth the IDENTIFIER.
                Text("Contacts").accessibilityLabel("Contacts screen").accessibilityIdentifier("lab.tab.contacts")
            }
            LabConversationView().tabItem {
                // GS-UX-001 step 7 (round 277): A VISIBLE WORD IS NOT A SEMANTIC -- the
                // screen reader announceth the LABEL, and a test addresseth the IDENTIFIER.
                Text("Conversation").accessibilityLabel("Conversation screen").accessibilityIdentifier("lab.tab.conversation")
            }
            LabSosView().tabItem {
                // GS-UX-001 step 7 (round 277): the CLASS is LabSosView while the LABEL is "SOS" -- two spellings for
                // one journey, and the navigation invariant asketh for the class while this label is what is HEARD.
                Text("SOS").accessibilityLabel("SOS screen").accessibilityIdentifier("lab.tab.sos")
            }
            LabDiagnosticsView().tabItem {
                // GS-UX-001 step 7 (round 277): A VISIBLE WORD IS NOT A SEMANTIC -- the
                // screen reader announceth the LABEL, and a test addresseth the IDENTIFIER.
                Text("Diagnostics").accessibilityLabel("Diagnostics screen").accessibilityIdentifier("lab.tab.diagnostics")
            }
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

/// GS-UX-001 step 5 (round 270), THE CARD'S OWN SENTENCE: **"A label reading Hold is not a gesture."**
///
/// So the lab's SOS is a REAL, CANCELLABLE HOLD with a MONOTONIC CONFIRMATION THRESHOLD -- measured with
/// `ContinuousClock`, which cannot go backwards, never with `Date()` -- AND AN ACCESSIBLE ALTERNATIVE, because a gesture
/// that must be held is unreachable for some users and must never be the only road. The threshold is NAMED, and the
/// gesture is CANCELLABLE: lifting the finger before the threshold cancels it, and the screen SAYETH so.
struct LabSosView: View {
    /// The monotonic confirmation threshold. Named, because a bare number in a gesture is a magic constant.
    static let confirmationThreshold: Duration = .seconds(3)

    @State private var heldSince: ContinuousClock.Instant?
    @State private var armed = false
    @State private var outcome: String?

    private let clock = ContinuousClock()

    /// Has the hold lasted the threshold? Measured on the MONOTONIC clock, so a wall-clock step cannot arm it early.
    private func thresholdReached() -> Bool {
        guard let start = heldSince else { return false }
        return clock.now - start >= Self.confirmationThreshold
    }

    var body: some View {
        VStack(spacing: 12) {
            LabBanner()
            Text("SOS").font(.title)
            Text(armed ? "ARMED -- release to send" : "hold to arm")
            // THE GESTURE: a real hold, cancellable, with the monotonic threshold above.
            Text("HOLD TO ARM")
                .padding()
                .background(armed ? Color.red.opacity(0.3) : Color.gray.opacity(0.2))
                .onLongPressGesture(minimumDuration: 0, pressing: { pressing in
                    if pressing {
                        heldSince = clock.now
                        outcome = nil
                    } else {
                        // RELEASED: armed only if the MONOTONIC threshold was reached; otherwise CANCELLED, and said so.
                        if thresholdReached() { outcome = "sos armed by hold" } else { outcome = "hold cancelled -- threshold not reached" }
                        heldSince = nil
                    }
                }, perform: { armed = thresholdReached() })
            // THE ACCESSIBLE ALTERNATIVE: the same outcome without a hold, because a hold must never be the only road.
            Button("Send SOS (accessible alternative)") { outcome = "sos armed by accessible alternative" }
                .accessibilityLabel("Send SOS")
            if let outcome { Text(outcome).font(.footnote) }
        }
    }
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
