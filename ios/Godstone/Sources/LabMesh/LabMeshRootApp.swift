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
    /// *** GS-UX-001 STEP 7: AN EXPLICIT SELECTION, MEASURED NECESSARY. ***
    ///
    /// *The TabView had NO selection binding. MEASURED: after a tap on `lab.tab.contacts`, the accessibility
    /// tree STILL showed the Conversation page -- the tab button existed with a valid frame and the tap was
    /// issued, but the selection did not change. An unbound TabView leaves its selection to SwiftUI's internal
    /// state, which the `@StateObject` re-render under an accessibility text size was resetting.*
    @State private var selection: Int = 2

    var body: some View {
        // GS-LAB-001 step 4's NAVIGATION HALF (round 268): MINIMAL VIEWS FOR THE FIVE JOURNEYS THE CARD NAMETH --
        // identity, contacts, conversation, SOS and diagnostics. They are MINIMAL ON PURPOSE: the card asketh for
        // navigation to them, not for finished screens, and `GS-UX-001` (which dependeth on this finding) carrieth the
        // deeper journeys. Each screen SAYETH what it is and carrieth NO readiness claim.
        TabView(selection: $selection) {
            LabIdentityView().tabItem {
                // GS-UX-001 step 7 (round 277): A VISIBLE WORD IS NOT A SEMANTIC -- the
                // screen reader announceth the LABEL, and a test addresseth the IDENTIFIER.
                Text("Identity").accessibilityLabel("Identity screen").accessibilityIdentifier("lab.tab.identity")
            }
            .tag(0)
            LabContactsView().tabItem {
                // GS-UX-001 step 7 (round 277): A VISIBLE WORD IS NOT A SEMANTIC -- the
                // screen reader announceth the LABEL, and a test addresseth the IDENTIFIER.
                Text("Contacts").accessibilityLabel("Contacts screen").accessibilityIdentifier("lab.tab.contacts")
            }
            .tag(1)
            LabConversationView().tabItem {
                // GS-UX-001 step 7 (round 277): A VISIBLE WORD IS NOT A SEMANTIC -- the
                // screen reader announceth the LABEL, and a test addresseth the IDENTIFIER.
                Text("Conversation").accessibilityLabel("Conversation screen").accessibilityIdentifier("lab.tab.conversation")
            }
            .tag(2)
            LabSosView().tabItem {
                // GS-UX-001 step 7 (round 277): the CLASS is LabSosView while the LABEL is "SOS" -- two spellings for
                // one journey, and the navigation invariant asketh for the class while this label is what is HEARD.
                Text("SOS").accessibilityLabel("SOS screen").accessibilityIdentifier("lab.tab.sos")
            }
            .tag(3)
            LabDiagnosticsView().tabItem {
                // GS-UX-001 step 7 (round 277): A VISIBLE WORD IS NOT A SEMANTIC -- the
                // screen reader announceth the LABEL, and a test addresseth the IDENTIFIER.
                Text("Diagnostics").accessibilityLabel("Diagnostics screen").accessibilityIdentifier("lab.tab.diagnostics")
            }
            .tag(4)
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
        // *** GS-UX-001 STEP 7: SCROLLED, SO ENLARGED TYPE CANNOT COVER THE TAB BAR. ***
        // *MEASURED AT `UICTContentSizeCategoryAccessibilityXXXL`: this content reached y=763.8 while the TabBar
        // begins at y=676 -- SO THE CONTENT COVERED THE TAB BAR, a tab tap landed on CONTENT, and the page never
        // switched. The accessibility arm caught a REAL navigation defect, not a missing control: nothing could
        // scroll, so the overflow had nowhere to go.*
        ScrollView {
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
}

struct LabContactsView: View {
    @EnvironmentObject private var holder: LabRuntimeHolder
    @State private var selectedContact: String = "B"
    @State private var trustOutcome: String = "idle"
    /// *** GS-UX-001 `rendered-controls`: THE DISPLAYED CANDIDATE, HELD WHERE THE SCREEN CAN HAND IT BACK. ***
    ///
    /// *The deleted road took a LABEL and re-read "the current" candidate inside the call, so a rotation that moved
    /// between render and tap was approved anyway. **THE SCREEN NOW CARRIETH THE EXACT REF IT SHOWED.*** And the
    /// displayed FINGERPRINT is captured the same way, because `Compare/Confirm` must confirm the string the user
    /// actually saw rather than a fresh read taken at tap time.
    @State private var displayedCandidate: ExactRotationCandidateRef?
    @State private var displayedFingerprint: String = ""
    /// How many rotations this screen has driven in, so each arrival carrieth a distinct generation and key.
    @State private var rotationSeedStep: Int = 7

    /// Re-capture what this screen is standing on: one read of the real facade, stored for the taps.
    private func captureDisplayed() {
        displayedFingerprint = holder.runtime.trustFingerprint(for: selectedContact) ?? ""
        displayedCandidate = holder.runtime.displayedRotationCandidate(for: selectedContact)
    }

    var body: some View {
        // *** GS-UX-001: SCROLLED, SO ENLARGED TYPE CANNOT COVER THE TAB BAR -- the same repair the sibling journeys
        // already carry. *** *MEASURED AT `UICTContentSizeCategoryAccessibilityXXXL` on those views: content reached
        // y=763.8 while the TabBar begins at y=676, so a tab tap landed on CONTENT. **THE TRUST PAGE CARRIETH MORE
        // CONTROLS THAN ANY SIBLING, so it is the LAST surface that may grow without a scroll.***
        ScrollView {
        VStack(alignment: .leading, spacing: 8) {
            LabBanner()
            Text("Contacts").font(.title)
            // AND THE HOLD COUNTS COME FROM THE RECIPIENTS' OWN STORES, through the runtime.
            ForEach(holder.runtime.labels, id: \.self) { label in
                Text(label + " holdeth " + String(holder.runtime.heldCount(label)) + " message(s)")
                    .accessibilityIdentifier("lab.contacts." + label)
            }

            Divider()

            Text("Trust Operations").font(.headline)

            // Contact selection picker
            Picker("contact", selection: $selectedContact) {
                ForEach(holder.runtime.trustContactLabels(), id: \.self) { label in
                    Text(label).tag(label)
                }
            }
            .accessibilityIdentifier("lab.trust.recipient")
            // AND A CHANGE OF SELECTION RE-CAPTURES, so the ref always belongeth to the contact on screen.
            .onChange(of: selectedContact) { _ in captureDisplayed() }
            .onAppear { captureDisplayed() }

            let fp = displayedFingerprint.isEmpty ? "no-fingerprint" : displayedFingerprint
            // *** MEASURED: `accessibilityLabel` ON A `Text` DOES NOT OVERRIDE ITS CONTENT. ***
            //
            // *The arm read `fingerprint: c31cbb8f...` -- THE `Text`'s OWN STRING -- even though the label was
            // set. **SWIFTUI TREATS A `Text`'s CONTENT AS ITS ACCESSIBILITY LABEL AND A MODIFIER CANNOT REPLACE
            // IT**, so the fix is a DIFFERENT CONSTRUCT rather than another modifier: the visible string stays in
            // the content, and the semantic label is attached to a CONTAINER that ignores its children.*
            //
            // *The distinction the card asks for survives: `accessibilityLabel` states WHAT IT IS and
            // `accessibilityValue` carries the hex, so a screen reader can announce "Fingerprint for Alice,
            // c31cbb8f..." instead of reading a hex dump one character at a time.*
            HStack(spacing: 0) { Text("fingerprint: " + fp).font(.footnote) }
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("lab.trust.fingerprint")
                .accessibilityLabel("Fingerprint for \(selectedContact)")
                .accessibilityValue(fp)

            // Trust status readout
            // Same construct as the fingerprint, for the same MEASURED reason: a `Text`'s content IS its
            // accessibility label and a modifier cannot replace it, so the semantic label goes on a container.
            HStack(spacing: 0) {
                Text("status: " + holder.runtime.contactTrustLabel(selectedContact)).font(.footnote)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("lab.trust.status")
            .accessibilityLabel("Verification status for \(selectedContact)")
            .accessibilityValue(holder.runtime.contactTrustLabel(selectedContact))

            HStack(spacing: 8) {
                Button("Compare/Confirm") {
                    // *** THE CAPTURED STRING, NOT A FRESH READ. *** *The user is confirming what they SAW; a read
                    // taken here could differ from the rendered value and would confirm a string nobody compared.*
                    trustOutcome = holder.runtime.compareAndConfirmFingerprint(
                        for: selectedContact, displayedFingerprint: displayedFingerprint)
                }
                .accessibilityIdentifier("lab.trust.confirm")
                .accessibilityLabel("Compare and confirm fingerprint")
                .accessibilityHint("Confirms the fingerprint shown for \(selectedContact)")

                Button("Approve Rotation") {
                    // *** THE DISPLAYED REF TRAVELS -- NO LABEL, NO RE-RESOLVE, NO REFRESH. ***
                    guard let candidate = displayedCandidate else {
                        trustOutcome = "refused: no rotation candidate was displayed for '\(selectedContact)'"
                        return
                    }
                    trustOutcome = holder.runtime.approveDisplayedRotation(candidate)
                    // And the screen re-captures afterwards, so the next tap is about what is now shown.
                    captureDisplayed()
                }
                .accessibilityIdentifier("lab.trust.approve")
                .accessibilityLabel("Approve rotation")
                .accessibilityHint("Approves the exact rotation candidate shown for \(selectedContact)")

                Button("Revoke") {
                    let contact = selectedContact
                    trustOutcome = holder.runtime.revokeContact(for: contact)
                }
                .accessibilityIdentifier("lab.trust.revoke")
                .accessibilityLabel("Revoke contact")
                .accessibilityHint("Revokes \(selectedContact); this cannot be undone from here")
            }

            // *** GS-UX-001 `rendered-controls` law 3: A ROTATION THAT *ARRIVES*, DRIVEN FROM A CONTROL. ***
            //
            // *"An approval carrieth an `ExactRotationCandidateRef`; a rotation that moved between render and tap is
            // refused by the CAS." **THAT JOURNEY CANNOT BE PERFORMED WITHOUT A ROTATION ARRIVING**, and a court cannot
            // reach the repository from outside -- so the lab carrieth the control. **IT DRIVETH THE SAME PRODUCTION
            // VERB A REAL HANDSHAKE DRIVETH** (`PeerIdentityRepository.applyValidatedBinding`, over a binding the
            // node's own signing key issueth and the real validator checks): no second source of truth, no fabricated
            // row.*
            //
            // *** AND IT SNAPSHOTS WHAT THE SCREEN WAS SHOWING *BEFORE* THE ARRIVAL, WHICH IS WHAT MAKETH LAW 3
            // EXERCISABLE AT ALL. *** *An inbound rotation is exactly the event after which a screen must NOT re-read
            // "the current" candidate -- it must keep the ref it showed. So this control records the displayed ref
            // first and drives the arrival second; tapping it twice therefore leaves the SCREEN one generation behind
            // the AUTHORITY, which is the race under test. **A CONTROL THAT RE-READ AFTERWARD WOULD MAKE THE RACE
            // UNREACHABLE FROM ANY RENDERED ARM.***
            Button("A new key arrives") {
                rotationSeedStep += 1
                let generation = UInt32(rotationSeedStep)
                let keyByte = UInt8(0xA0 &+ rotationSeedStep)
                trustOutcome = holder.runtime.seedRotation(for: selectedContact,
                                                           generation: generation,
                                                           staticDhSeedByte: keyByte)
                // *** RE-READ ONLY WHEN NOTHING IS UNDER REVIEW YET. ***
                //
                // *A screen that ALREADY shows a pending candidate the user is reviewing must NOT silently swap it
                // for a newer arrival -- that swap is precisely the race law 3 existeth to catch. So the caption is
                // taken on the FIRST arrival (nothing was displayed) and deliberately NOT on a later one, leaving the
                // screen one generation behind the authority: the state a tap must refuse from.*
                if displayedCandidate == nil { captureDisplayed() }
            }
            .accessibilityIdentifier("lab.trust.seedrotation")
            .accessibilityLabel("A new key arrives")
            .accessibilityHint("Drives a real rotation for \(selectedContact); the displayed candidate is not re-read")

            Text(trustOutcome)
                .font(.footnote)
                .accessibilityIdentifier("lab.trust.outcome")
        }
        .padding()
        }
        .onAppear {
            if let first = holder.runtime.trustContactLabels().first {
                selectedContact = first
            }
            captureDisplayed()
        }
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

    /// *** GS-UX-001 STEP 3: THE VIEW-GENERATED INTENT, AND THE VERDICT IT LEFT BEHIND. ***
    ///
    /// *Send taketh the DURABLE road now: the intent is pinned in `outbound_intents` under a HOLDER-OWNED STABLE URL
    /// before the frame is authored, so a relaunch can ask the same medium what became of it -- which no in-memory
    /// medium can ever answer. The id is minted HERE, in the view, because the view is the thing that must be able to
    /// ask for it again.*
    @State private var intentHex: String = ""
    @State private var durableVerdict: String = "not asked"

    /// *** THE BOUNDED INPUT, IN OCTETS. ***
    ///
    /// *`onChange` truncates in UTF-8 OCTETS through the runtime's own measured bound -- **NEVER `Character.count`**,
    /// because one emoji is one character and four octets, so a character-counting bound accepts a body the authority
    /// refuses. The bound itself is PROBED at runtime (`LabRuntime.maxComposeBodyOctets`), so this view cannot drift
    /// from the frame the authority builds.*
    private func boundTheInput() {
        let bounded = LabRuntime.truncateToComposeBound(body_)
        if bounded != body_ { body_ = bounded }
    }

    var body: some View {
        // *** GS-UX-001 STEP 7: SCROLLED, SO ENLARGED TYPE CANNOT COVER THE TAB BAR. ***
        // *MEASURED AT `UICTContentSizeCategoryAccessibilityXXXL`: this content reached y=763.8 while the TabBar
        // begins at y=676 -- SO THE CONTENT COVERED THE TAB BAR, a tab tap landed on CONTENT, and the page never
        // switched. The accessibility arm caught a REAL navigation defect, not a missing control: nothing could
        // scroll, so the overflow had nowhere to go.*
        ScrollView {
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
                .onChange(of: body_) { _ in boundTheInput() }

            // *** THE OCTET READOUT, BECAUSE A BOUND A USER CANNOT SEE IS A BOUND THEY CANNOT RESPECT. ***
            //
            // *It reads `LabRuntime.composeOctetsReadout`, which measures the string in UTF-8 octets against the
            // PROBED cap -- so the number rendered and the number enforced are the same number.*
            HStack(spacing: 0) { Text(holder.runtime.composeOctetsReadout(body_)).font(.footnote) }
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("lab.conversation.octets")
                .accessibilityLabel("Conversation size")
                .accessibilityValue(holder.runtime.composeOctetsReadout(body_))

            Button("Send") {
                let text = body_
                let from = author, to = recipient
                // THE INTENT IS MINTED HERE, so the rendered verdict can name the id the send pinned.
                let intent = LabRuntime.mintIntentId()
                intentHex = intent.map { String(format: "%02x", $0) }.joined()
                Task {
                    outcome = await holder.runtime.sendDirectDurableIntent(
                        from, recipient: to, plaintext: Data(text.utf8), intentId: intent)
                    durableVerdict = holder.runtime.durableIntentVerdict(intent)
                }
            }
            .accessibilityIdentifier("lab.conversation.send")
            Text(outcome).accessibilityIdentifier("lab.conversation.outcome")

            // *** AND THE REOPEN'S OWN ANSWER, RENDERED -- THE CLAUSE THAT SEPARATES A DURABLE ROAD FROM A MEMORY ONE. ***
            //
            // *On a FRESH LAUNCH this reads the LAST RECORDED intent from the holder-owned register, so the rendered
            // line is the RELAUNCH discriminator itself: `.found` survives the process, `.notFound` for a never-authored
            // id is what maketh `.found` mean something.*
            HStack(spacing: 0) {
                Text("durable: " + (durableVerdict == "not asked"
                                    ? holder.runtime.durableVerdictForLastIntent()
                                    : durableVerdict)).font(.footnote)
            }
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("lab.conversation.durable")
                .accessibilityLabel("Durable intent verdict")
                .accessibilityValue(durableVerdict == "not asked"
                                    ? holder.runtime.durableVerdictForLastIntent()
                                    : durableVerdict)

            // *** GS-UX-001 STEP 7: A READOUT OF THE RUNTIME'S OWN COUNT, SO THE ARM CAN BIND RUNTIME-OWNED STATE. ***
            //
            // *AN EXTERNAL REVIEW'S SHARPEST POINT: asserting the outcome TEXT only proves the view wrote something,
            // and `expectation(for:evaluatedWith:)` with `NSPredicate("label != %@")` is a CLASSIC SILENT FALSE
            // NEGATIVE on a SwiftUI Text (stale snapshot / KVC). **A CONTROL WHOSE CLOSURE IS REPLACED BY A LOCAL
            // STRING WRITE WOULD STILL PASS IT.*** This readout is `admittedCount()` -- **THE RUNTIME'S OWN COUNTER,
            // which no view can fabricate** -- so an unwired action and a stuck await BOTH redden.*
            Text("admitted: " + String(holder.runtime.admittedCount()))
                .accessibilityIdentifier("lab.conversation.admitted")

            // *** AND THE INTENT THE VIEW MINTED, RENDERED SO A RELAUNCH ARM CAN NAME IT. ***
            HStack(spacing: 0) { Text("intent: " + (intentHex.isEmpty ? "none" : intentHex)).font(.footnote) }
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("lab.conversation.intent")
                .accessibilityLabel("Last intent id")
                .accessibilityValue(intentHex.isEmpty ? "none" : intentHex)
        }
        .padding()
        }
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
    /// The rendered distress state, read from the delivery row (or the durable register) in the shared vocabulary.
    @State private var sosState: String = "no active call"

    private let clock = ContinuousClock()

    /// Has the hold lasted the threshold? Measured on the MONOTONIC clock, so a wall-clock step cannot arm it early.
    private func thresholdReached() -> Bool {
        guard let start = heldSince else { return false }
        return clock.now - start >= Self.confirmationThreshold
    }

    /// *** THE SOS REACHES THE RUNTIME THROUGH THE NODE'S OWN COMMAND DOOR, AND THE RENDERED TEXT IS THE RUNTIME'S
    /// OWN VERDICT. ***
    ///
    /// *`LabRuntime.armSos` forwards to `MeshNode.handleSosCommand(.author(payload))` -- **THE EXISTING COMMAND
    /// SURFACE**, per the plan's instruction, not a new mechanism. The outcome string is the authority's answer rather
    /// than a phrase this view chose, and the state line below is read back FROM THE DELIVERY ROW through the shared
    /// vocabulary.*
    private func sendSos() {
        outcome = holder.runtime.armSos(payload: Data("SOS".utf8))
        sosState = holder.runtime.sosStateNames()
    }

    /// Cancel the standing call by the DURABLE msg_id -- the node's own `.cancel(msgId)` arm.
    private func cancelSos() {
        guard let msgId = holder.runtime.activeSosMsgId() else {
            outcome = "refused: nothing to cancel"
            return
        }
        outcome = holder.runtime.cancelSos(msgId: msgId)
        sosState = holder.runtime.sosStateNames()
    }

    var body: some View {
        // *** GS-UX-001 STEP 7: SCROLLED, SO ENLARGED TYPE CANNOT COVER THE TAB BAR. ***
        // *MEASURED AT `UICTContentSizeCategoryAccessibilityXXXL`: this content reached y=763.8 while the TabBar
        // begins at y=676 -- SO THE CONTENT COVERED THE TAB BAR, a tab tap landed on CONTENT, and the page never
        // switched. The accessibility arm caught a REAL navigation defect, not a missing control: nothing could
        // scroll, so the overflow had nowhere to go.*
        ScrollView {
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
                            // carries Send's -- so a broken send road is visible in the rendered text. **AND IT IS THE
                            // DURABLE ROAD**: the node's own `.author` arm commits the held frame and its row as one
                            // pair, which is what a relaunch can read.
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

            // *** THE CANCELLABLE ROAD THE CARD NAMES ("SOS hold/cancel"), BY ITS OWN DURABLE ID. ***
            Button("Cancel the call") { cancelSos() }
                .accessibilityLabel("Cancel the distress call")
                .accessibilityIdentifier("lab.sos.cancel")

            if let outcome { Text(outcome).font(.footnote).accessibilityIdentifier("lab.sos.outcome") }

            // *** AND THE DISTRESS STATE, RENDERED FROM THE DELIVERY ROW IN THE SHARED VOCABULARY. ***
            //
            // *The card asketh the SOS state be visible and durable. The LINE is prefixed (`active:`/`terminal:`/none)
            // so a reader can tell a live call from a retired one, and the WORDS after it come from
            // `AccessibilityContract.stateWords` -- **never invented**.*
            HStack(spacing: 0) { Text("call: " + sosState).font(.footnote) }
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("lab.sos.state")
                .accessibilityLabel("Distress call state")
                .accessibilityValue(sosState)
                .onAppear { sosState = holder.runtime.sosStateNames() }

            // *** AND THE RUNTIME'S OWN COUNT, SO THE SOS ARM CAN BIND RUNTIME-OWNED STATE TOO. ***
            Text("sos admitted: " + String(holder.runtime.admittedCount()))
                .accessibilityIdentifier("lab.sos.admitted")
        }
        }
    }
}

struct LabDiagnosticsView: View {
    @EnvironmentObject private var holder: LabRuntimeHolder
    /// The wipe control's own report, so the rendered surface NAMES what the action did.
    @State private var wipeNote = "not requested"
    var body: some View {
        // *** GS-UX-001 STEP 7: SCROLLED, SO ENLARGED TYPE CANNOT COVER THE TAB BAR. ***
        // *MEASURED AT `UICTContentSizeCategoryAccessibilityXXXL`: this content reached y=763.8 while the TabBar
        // begins at y=676 -- SO THE CONTENT COVERED THE TAB BAR, a tab tap landed on CONTENT, and the page never
        // switched. The accessibility arm caught a REAL navigation defect, not a missing control: nothing could
        // scroll, so the overflow had nowhere to go.*
        ScrollView {
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
}
