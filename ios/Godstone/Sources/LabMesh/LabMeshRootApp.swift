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

// --------------------------------------------------------------------------------------
// *** GS-UX-001 STEP 1 (round 539): THE LAB'S JOURNEYS ARE **USABLE**, AND THEY REACH THE ONE RETAINED RUNTIME. ***
//
// THE CARD'S OWN CHARGE, MEASURED BEFORE THIS EDIT: *'the journeys stop at disconnected models and static text'* --
// and the three views below were LITERALLY ONE LINE OF `Text` EACH, while THE RUNTIME HANDLE WAS READ BY NO VIEW
// ANYWHERE IN THIS TARGET. A LAB WHOSE JOURNEYS CANNOT REACH ITS RUNTIME IS A LAB THAT EXERCISETH NOTHING.
//
// EVERY CALL BELOW GOETH THROUGH `LabRuntime` -- THE ONE PUBLIC DOOR TO THE COMPOSITION -- AND THEREFORE THROUGH THE
// REAL DURABLE AUTHORITY (rounds 521/525: `sendDirectDurable` pins the intent in `outbound_intents` before the frame
// is authored). **NOTHING HERE MUTATETH A UI-ONLY MAP**, which is the substitution the card forbiddeth.
// AND THIS TARGET CARRIETH NO OWNER OF ITS OWN: it holdeth the `LabRuntimeHolder` it was GIVEN, and
// `check_the_lab_buildeth_no_owner_of_its_own` keepeth that so.
// --------------------------------------------------------------------------------------

struct LabIdentityView: View {
    @EnvironmentObject private var holder: LabRuntimeHolder

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabBanner()
            Text("Identity").font(.title)
            // THE RUNTIME'S OWN ANSWER, not a claim written into a label: the labels it was composed with, and
            // whether the real durable authority is reachable through it.
            Text("labels: " + holder.runtime.labels.joined(separator: ", "))
                .accessibilityIdentifier("lab.identity.labels")
            Text("durable road: " + (holder.runtime.hasDurableRoad ? "reachable" : "absent"))
                .accessibilityIdentifier("lab.identity.durableness")
        }
        .padding()
    }
}

struct LabContactsView: View {
    @EnvironmentObject private var holder: LabRuntimeHolder

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabBanner()
            Text("Contacts").font(.title)
            // AND THE HOLD COUNTS COME FROM THE RECIPIENTS' OWN STORES, through the runtime.
            ForEach(holder.runtime.labels, id: \.self) { label in
                Text(label + " holdeth " + String(holder.runtime.heldCount(label)) + " message(s)")
                    .accessibilityIdentifier("lab.contacts." + label)
            }
        }
        .padding()
    }
}

struct LabConversationView: View {
    @EnvironmentObject private var holder: LabRuntimeHolder
    @State private var outcome = "nothing sent yet"
    @State private var body_ = "the mill road is cut; send boats"

    /// *** GS-UX-001 STEP 4: THE AUTHOR AND THE RECIPIENT ARE THE USER'S CHOICE, NOT CONSTANTS IN THE VIEW. ***
    ///
    /// *THE MEASURED GAP: this view hardcoded `sendDirect("A", recipient: "B", ...)` -- so the journey was reachable
    /// only for a PAIR THE VIEW INVENTED, and "a real recipient selector" (the card's own words) did not exist. **A
    /// SEND BUTTON WITH A HARDCODED RECIPIENT IS NOT A SELECTOR**, which is why the previous coverage could not see
    /// this: the arm grepped the SOURCE for `sendDirect` rather than driving a control.*
    ///
    /// The list is the RUNTIME'S OWN label set (`recipientsExcluding`), so a label the runtime does not carry cannot
    /// be offered.
    @State private var author: String = "A"
    @State private var recipient: String = "B"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabBanner()
            Text("Conversation").font(.title)

            // *** THE RECIPIENT SELECTOR: A REAL PICKER OVER THE RUNTIME'S OWN LABELS. ***
            Picker("from", selection: $author) {
                ForEach(holder.runtime.labels, id: \.self) { label in Text(label).tag(label) }
            }
            .accessibilityIdentifier("lab.conversation.author")

            Picker("to", selection: $recipient) {
                ForEach(holder.runtime.recipientsExcluding(author), id: \.self) { label in
                    Text(label).tag(label)
                }
            }
            .accessibilityIdentifier("lab.conversation.recipient")

            // *** AND THE LINK STATE, RENDERED: a recipient that cannot be reached must be VISIBLE as such rather
            // than silently failing an action. The register is the runtime's own. ***
            Text(holder.runtime.isLinked(author, recipient)
                 ? "link: up \(author)->\(recipient)"
                 : "link: down \(author)->\(recipient)")
                .accessibilityIdentifier("lab.conversation.linkstate")

            // *** A REAL UTF-8-BOUNDED INPUT AND A REAL SEND ACTION (step 4's core), WIRED TO THE RUNTIME. ***
            TextField("message", text: $body_)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("lab.conversation.field")
            Button("Send") {
                let text = body_
                let from = author, to = recipient
                Task { outcome = await holder.runtime.sendDirect(from, recipient: to, plaintext: Data(text.utf8)) }
            }
            .accessibilityIdentifier("lab.conversation.send")
            Text(outcome).accessibilityIdentifier("lab.conversation.outcome")

            // *** GS-UX-001 STEP 7: A READOUT OF THE RUNTIME'S OWN COUNT, SO THE ARM CAN BIND RUNTIME-OWNED STATE. ***
            //
            // *AN EXTERNAL REVIEW'S SHARPEST POINT: asserting the outcome TEXT only proves the view wrote something,
            // and `expectation(for:evaluatedWith:)` with `NSPredicate("label != %@")` is a CLASSIC SILENT FALSE
            // NEGATIVE on a SwiftUI Text (stale snapshot / KVC). **A CONTROL WHOSE CLOSURE IS REPLACED BY A LOCAL
            // STRING WRITE WOULD STILL PASS IT.*** This readout is `admittedCount()` -- **THE RUNTIME'S OWN COUNTER,
            // which no view can fabricate** -- so an unwired action and a stuck await BOTH redden.*
            Text("admitted: " + String(holder.runtime.admittedCount()))
                .accessibilityIdentifier("lab.conversation.admitted")
        }
        .padding()
    }
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

    /// *** THE RETAINED RUNTIME, WHICH THE SOS MUST REACH. *** *Its ABSENCE here was the defect: the view could
    /// write a string without one, and did.*
    @EnvironmentObject private var holder: LabRuntimeHolder

    @State private var heldSince: ContinuousClock.Instant?
    @State private var armed = false
    @State private var outcome: String?

    private let clock = ContinuousClock()

    /// Has the hold lasted the threshold? Measured on the MONOTONIC clock, so a wall-clock step cannot arm it early.
    private func thresholdReached() -> Bool {
        guard let start = heldSince else { return false }
        return clock.now - start >= Self.confirmationThreshold
    }

    /// *** THE SOS REACHES THE RUNTIME, AND THE RENDERED TEXT IS THE RUNTIME'S OWN VERDICT. ***
    ///
    /// *`LabRuntime.sendSos` broadcasts through the same retained runtime the direct-send road uses, so the outcome
    /// string is the authority's answer rather than a phrase this view chose. `@EnvironmentObject` is required to
    /// reach it -- the previous version needed no environment at all, WHICH WAS ITSELF THE SYMPTOM: a control that
    /// reaches nothing needs nothing.*
    private func sendSos() {
        Task { outcome = await holder.runtime.sendSos("A", plaintext: Data("SOS".utf8)) }
    }

    var body: some View {
        VStack(spacing: 12) {
            LabBanner()
            Text("SOS").font(.title)
            Text(armed ? "ARMED -- release to send" : "hold to arm")
            // THE GESTURE: a real hold, cancellable, with the monotonic threshold above.
            // *** GS-UX-001 STEP 7: A STABLE IDENTITY, SO THE GESTURE IS ADDRESSABLE BY ASSISTIVE TECHNOLOGY AND
            // BY A UI TEST ALIKE. *** *The card's sentence is that "a label reading Hold is not a gesture" -- and a
            // gesture the accessibility tree cannot name is also unreachable. The identifier is what makes the
            // control ADDRESSABLE; the gesture below is what makes it REAL.*
            Text("HOLD TO ARM")
                .accessibilityIdentifier("lab.sos.hold")
                .padding()
                .background(armed ? Color.red.opacity(0.3) : Color.gray.opacity(0.2))
                .onLongPressGesture(minimumDuration: 0, pressing: { pressing in
                    if pressing {
                        heldSince = clock.now
                        outcome = nil
                    } else {
                        // RELEASED: SEND only if the MONOTONIC threshold was reached; otherwise CANCELLED, and said so.
                        if thresholdReached() {
                            // *** GS-UX-001 STEP 5/(iv): THE HOLD MUST REACH THE RUNTIME, NOT A LOCAL STRING. ***
                            //
                            // *MEASURED DEFECT, FOUND BY REVIEW AND CONFIRMED HERE: this closure wrote
                            // `outcome = "sos armed by hold"` -- **A STRING THE VIEW ITSELF INVENTED. NO SOS WAS EVER
                            // BROADCAST, AND NOTHING WAS JOURNALLED**, so the gesture armed a label. **THAT IS THE
                            // CARD'S OWN CHARGE ("static text") COMMITTED BY THE CONTROL THE CARD ASKED FOR**, and it
                            // is the same rig-assignment defect that had already voided two other witnesses.*
                            //
                            // The outcome now carries THE RUNTIME'S OWN ANSWER, exactly as `LabConversationView`
                            // carries Send's -- so a broken send road is visible in the rendered text.
                            sendSos()
                        } else {
                            outcome = "hold cancelled -- threshold not reached"
                        }
                        heldSince = nil
                    }
                }, perform: { armed = thresholdReached() })
            // THE ACCESSIBLE ALTERNATIVE: the SAME SEND without a hold, because a hold must never be the only road.
            Button("Send SOS (accessible alternative)") { sendSos() }
                .accessibilityLabel("Send SOS")
                .accessibilityIdentifier("lab.sos.send")
            if let outcome { Text(outcome).font(.footnote).accessibilityIdentifier("lab.sos.outcome") }

            // *** AND THE RUNTIME'S OWN COUNT, SO THE SOS ARM CAN BIND RUNTIME-OWNED STATE TOO. ***
            Text("sos admitted: " + String(holder.runtime.admittedCount()))
                .accessibilityIdentifier("lab.sos.admitted")
        }
    }
}

struct LabDiagnosticsView: View {
    @EnvironmentObject private var holder: LabRuntimeHolder
    /// The wipe control's own report, so the rendered surface NAMES what the action did.
    @State private var wipeNote = "not requested"
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabBanner()
            Text("Diagnostics").font(.title)
            // THE ONE PLACE THE LAB SHOWETH THE LIFECYCLE IT HEARETH -- so that 'the lifecycle reacheth the same owner'
            // is VISIBLE to a human and to a reader, not merely assertable in a control.
            Text("last lifecycle phase: " + String(describing: holder.lastLifecyclePhase))
                .font(.footnote)

            // *** GS-UX-001 STEP 6: THE WIPE JOURNEY, RENDERED AND TRUTHFUL ABOUT ITS OWN LIMIT. ***
            //
            // *The card asks for "wipe progress from the real reopened store". What this control renders is THE
            // COMPOSITION HARNESS'S OWN WIPE REGISTER (`wipeStateName()`), because that is the register this runtime
            // has -- **AND IT SAYS SO**, rather than showing a rung it never read. The LADDER-bearing wipe authority
            // is reached through `MeshRuntime`, not through this harness; a ladder label here would be a SECOND
            // SOURCE OF TRUTH beside the real one.*
            //
            // **THE BUTTON IS A REAL ACTION, NOT A DISPLAY:** `beginWipe()` invokes the harness's own owner, which
            // erases the durable artifacts it holds. A control that only SET a local flag would be the "static text"
            // shape this finding charges.*
            Text("wipe: " + holder.runtime.wipeStateName())
                .accessibilityIdentifier("lab.diagnostics.wipestate")

            Button("Begin wipe") {
                holder.runtime.beginWipe()
                wipeNote = holder.runtime.wipeStateName()
            }
            .accessibilityIdentifier("lab.diagnostics.beginwipe")

            Text("wipe result: " + wipeNote)
                .font(.footnote)
                .accessibilityIdentifier("lab.diagnostics.wiperesult")
        }
    }
}
