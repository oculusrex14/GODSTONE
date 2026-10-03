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

/// *** *** IOS-R6: THE RETAINED RUNTIME OWNER -- AND IT CONSULTS RECOVERY BEFORE IT CONSTRUCTS ANYTHING. *** ***
///
/// *THE DEFECT THE REVIEW NAMED, VERBATIM: "`LabRuntimeHolder` unconditionally executes `try! LabRuntime.compose()`.
/// compose creates identities/nodes and opens/reseeds the trust database without checking the wipe journal ... There
/// is no recovery-only holder topology or operator-confirmed corruption recovery before ordinary SOS/Send/contact
/// resources become reachable."* **AND ITS REMEDY IS EXACTLY WHAT THIS TYPE NOW DOES:**
///
///   1. **READ THE ESTATE FIRST, COMPOSING NOTHING.** `MeshRuntime.recoveryEstateStatus` answereth the typed decision,
///      the durable generation and the rung -- it opens no store and mints no identity.
///   2. **RENDER RECOVERY-ONLY / OPERATOR STATES WITHOUT A RUNTIME.** An outstanding or corrupt estate yields NO
///      `LabRuntime` at all (`runtime == nil`), so no sensitive resource is reachable behind a mere flag.
///   3. **TRANSITION TO NORMAL ONLY WITH A CONSUMED, ESTATE-BOUND PERMIT.** On a settled estate the holder builds a
///      permit from the driving bootstrap and requires `.normal(permit)`, then consumes it with
///      `consumeForConstruction(estateId:liveGeneration:)` **before** `LabRuntime.compose` -- so a permit minted for
///      one estate, or before the record moved (ABA), is REFUSED at the actual construction boundary.
///
/// **`try!` IS GONE.** A composition error is carried as a rendered refusal, not a process termination; the lab that
/// cannot compose says so rather than dying silently.
public final class LabRuntimeHolder: ObservableObject {
    /// THE ONE RUNTIME -- present ONLY when the estate settled and its permit was consumed at construction.
    public var runtime: LabRuntime? { activeRuntime }
    /// *** THE OBSERVABLE DOOR: a surface repaints when the construction attempt changes the runtime. *** *Published so
    /// the gate in `LabRootView` re-evaluates after a retry or an operator resolution.*
    @Published private var activeRuntime: LabRuntime?

    /// The typed estate state this holder read at its last construction attempt. A surface renders THIS.
    @Published public private(set) var estateDecision: StartupRecoveryDecision
    @Published public private(set) var estateGeneration: UInt64
    @Published public private(set) var estateRung: String?
    /// The outcome of the construction attempt, spoken for a reader (empty when normal construction succeeded).
    @Published public private(set) var bootstrapWords: String
    /// *** THE OPERATOR'S OWN RESOLUTION, AS THE RUNTIME ANSWERED IT (G1). *** *A surface must bind the DURABLE
    /// effect of the operator's act rather than a phrase a view invented, so the typed outcome's own words are
    /// projected here where the drive happened.*
    @Published public private(set) var operatorWipeWords: String
    /// *** THE RETRY'S OWN ANSWER, AS THE RUNTIME ANSWERED IT (G1). *** *Distinct from `bootstrapWords`, which the
    /// re-attempt overwriteth: this is the typed outcome of the resume drive itself, so a rendered arm can bind the
    /// effect without racing the re-gate.*
    @Published public private(set) var retryWords: String
    /// The lab's canonical estate identifier -- the same value the permit is bound to.
    public let estateId: String

    // --------------------------------------------------------------------------------------------
    // *** G1: THE TYPED DECISION'S OWN LAWS, PROJECTED -- THE ONE HOLDER A SURFACE RENDERS FROM. ***
    //
    // *THE DEFECT THIS CLOSES, MEASURED: `LabRecoveryOnlyView` rendered BOTH the Retry and the Resolve buttons
    // whatever the decision said, so during a corrupt record the Retry invited a resume the shared law reserves to
    // the operator, and after a settled estate it drove a FRESH request the authority never earned. **THE LAWS
    // ALREADY EXIST ON THE DECISION (`permitsRecoveryConstruction`, `requiresOperator`); no surface consulted them.**
    // THE GATE IS THEREFORE THE DECISION'S OWN PROPERTIES, PROJECTED HERE -- never a UI-local boolean, which is a
    // second source of truth beside the durable one.*
    // --------------------------------------------------------------------------------------------

    /// TRUE only while the DURABLE decision permits a recovery (resume) drive: pending/retryable. The earned-Retry
    /// law -- corrupt/terminal/settled all answer `false`, so a Retry that would start destruction can never render.
    public var permitsRecoveryConstruction: Bool { estateDecision.permitsRecoveryConstruction }

    /// TRUE only for an unreadable record or a policy refusal: the road no automatic action may take.
    public var requiresOperator: Bool { estateDecision.requiresOperator }

    /// The durable REASON the decision carries (nil when settled) -- rendered, never inferred from an error string.
    public var refusalReason: String? { estateDecision.refusalReason }

    /// GS-LAB-001 step 4: THE OWNER HEARETH THE LIFECYCLE. It recordeth the last phase, so that a court (and a reader)
    /// can see that the notification reached THE RUNTIME'S OWNER and not a view -- and so that a later step may pause or
    /// resume owned work without a second, competing owner.
    private(set) var lastLifecyclePhase: ScenePhase?

    public func lifecycleChanged(to phase: ScenePhase) {
        lastLifecyclePhase = phase
    }

    public init() {
        let root = LabRuntime.labEstateRootURL()
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // *** THE ESTATE'S CANONICAL IDENTITY, FROM THE INVENTORY THE HOLDER IS ABOUT TO COMPOSE. ***
        self.estateId = LabRuntime.labEstateIdentifier(root: root)
        self.estateDecision = .cleanStart
        self.estateGeneration = 0
        self.estateRung = nil
        self.bootstrapWords = ""
        self.operatorWipeWords = ""
        self.retryWords = ""
        // *** G1: THE DEBUG, NONSHIPPING FIXTURE DOOR -- INJECTED BEFORE ANY HOLDER CONSTRUCTION. ***
        //
        // *It planteth the REAL durable journal bytes (phase + floor + marker) in the exact medium the ladder
        // writeth, so the typed decision below is read from a record that really stands -- never a fabricated
        // `WipeProgressState` or story graph. In a shipping build the door does not exist at all.*
        #if DEBUG
        LabRecoveryFixtureDoor.applyFixtureIfPresent(
            journalURL: LabRuntime.labWipeJournalURL(),
            estateRoot: root)
        #endif
        attemptConstruction()
    }

    /// *** THE ONE CONSTRUCTION ATTEMPT: READ THE ESTATE, AND BUILD ONLY AGAINST A CONSUMED, BOUND PERMIT. ***
    ///
    /// *Called at launch and again after any recovery retry, so the gate is the SAME road every time: no code path
    /// reaches `compose` without passing `consumeForConstruction`.*
    private func attemptConstruction() {
        let root = LabRuntime.labEstateRootURL()
        // *** FAIL-CLOSED BASELINE: a brand-new estate must carry a durable generation before a permit is minted. ***
        LabRuntime.establishLabEstateBaselineIfNeeded()
        // (1) THE TYPED READ -- NO STORE, NO IDENTITY, NO NODE. *Read BEFORE any sensitive resource exists.*
        let status = MeshRuntime.recoveryEstateStatus(journal: LabRuntime.labWipeJournal())
        estateDecision = status.decision
        estateGeneration = status.generation
        estateRung = status.rung

        switch status.decision {
        case .cleanStart, .wipeCompleted:
            // (3) THE PERMIT: MINTED BY A DRIVE, BOUND TO THIS ESTATE, CONSUMED AT CONSTRUCTION.
            guard LabRuntime.consumeLabConstructionPermit(estateId: estateId,
                                                          liveGeneration: status.generation) else {
                activeRuntime = nil
                bootstrapWords = "private construction refused: no valid permit for this estate and generation"
                return
            }
            do {
                // *** THE PRIVATE CONSTRUCTION, OVER THE LAB'S RETAINED ESTATE ROOT. ***
                activeRuntime = try LabRuntime.compose(estateRoot: root)
                bootstrapWords = ""
            } catch {
                activeRuntime = nil
                bootstrapWords = "composition refused: \(error)"
            }
        case .recoveryPending, .retryableFailure:
            // (2) RECOVERY-ONLY: NO RUNTIME AT ALL -- and no sensitive resource behind a flag.
            activeRuntime = nil
            bootstrapWords = "recovery-only: " + status.decision.name
                + (status.decision.refusalReason.map { " -- " + $0 } ?? "")
        case .corruptJournal, .terminalFailure:
            // OPERATOR REQUIRED: no automatic action may resolve an unreadable record.
            activeRuntime = nil
            bootstrapWords = status.decision.name + " -- operator required"
        }
    }

    /// *** *** G1: THE RETRY ROAD -- GATED BY THE DURABLE DECISION, AND A RESUME RATHER THAN A FRESH REQUEST. *** ***
    ///
    /// *THE DEFECT THIS CLOSES, MEASURED: the recovery-only surface drove `runRecoveryForOperator(requestFresh: true)`
    /// whatever the decision said -- so a Retry from a SETTLED estate WROTE A FRESH `REQUESTED` AND BUMPED THE
    /// GENERATION (starting destruction rather than resuming the failed operation), and during a CORRUPT record it
    /// invited a resume the shared law reserves to the operator (`permitsRecoveryConstruction` is FALSE there). **THE
    /// LAW ALREADY EXISTED ON THE DECISION AND NO SURFACE CONSULTED IT.***
    ///
    /// **THE AUTHORITY IS RE-READ AT THE TAP, NOT TRUSTED FROM THE RENDER**: a screen that showed the button cannot
    /// vouch for the record now, so the typed decision is taken again here and the gate is applied to THAT. And the
    /// phase is the other half of the repair: a Retry RESUMES (`requestFresh: false`) -- the fresh request belongs to
    /// the operator's own complete wipe, which carrieth its own restriction.
    ///
    /// Returns the words now rendered: the authority's own summary when it permitted, or a TYPED REFUSAL naming the
    /// decision when it did not.
    @discardableResult
    public func recoveryRetry() -> String {
        let status = MeshRuntime.recoveryEstateStatus(journal: LabRuntime.labWipeJournal())
        estateDecision = status.decision
        estateGeneration = status.generation
        estateRung = status.rung
        guard status.decision.permitsRecoveryConstruction else {
            retryWords = "refused: " + status.decision.name + " does not permit a recovery resume"
                + (status.decision.refusalReason.map { " -- " + $0 } ?? "")
            bootstrapWords = retryWords
            return retryWords
        }
        let outcome = LabRuntime.runRecoveryForOperator(requestFresh: false)
        // *** THE RESUME'S OWN TYPED ANSWER (the durable `requestFresh: false` road), RENDERED BESIDE the re-gate. ***
        retryWords = "recovery retry: " + outcome.summaryWords
        bootstrapWords = retryWords
        attemptConstruction()
        return retryWords
    }

    /// *** G1: THE OPERATOR'S OWN RESOLUTION, GATED ON `requiresOperator` AND RESTRICTED TO AN UNREADABLE RECORD. ***
    ///
    /// *The shared law reserves this road to a genuinely corrupt/terminal estate; offering it beside a Retry (which
    /// the surface did) invites an operator wipe where a resume was owed. The authority also refuses a readable estate
    /// BY NAME inside the coordinator -- and this gate never reaches it with one.*
    @discardableResult
    public func resolveCorrupt() -> String {
        let status = MeshRuntime.recoveryEstateStatus(journal: LabRuntime.labWipeJournal())
        estateDecision = status.decision
        estateGeneration = status.generation
        estateRung = status.rung
        guard status.decision.requiresOperator else {
            bootstrapWords = "refused: " + status.decision.name + " does not require an operator resolution"
            return bootstrapWords
        }
        return resolveCorruptForOperator().summaryWords
    }

    /// *** IOS-R6: THE OPERATOR'S OWN RESOLUTION OF A CORRUPT RECORD. ***
    ///
    /// *A corrupt journal cannot be retried into parseability, so the honest remedy is an OPERATOR-CONFIRMED full wipe
    /// over the lab's OWN estate (`MeshRuntime.resolveCorruptRecoveryForOperator`) -- **never a silent
    /// clear-journal.** After it, the holder re-reads the estate and may build normally. **The rendered control
    /// reacheth this road only through `resolveCorrupt()`, which applies the `requiresOperator` gate; this method
    /// itself carries the DURABLE effect and is the door a court drives directly.***
    @discardableResult
    public func resolveCorruptForOperator() -> RecoveryLadderOutcome {
        // *THE ESTATE IS THE LAB'S OWN INVENTORY -- enumerated STATICALLY from the root, since no composition exists
        // while the record is unreadable (`LabEstateSeam(inventory:)`).*
        let outcome = LabRuntime.resolveCorruptRecoveryForOperator()
        // *** THE TYPED OUTCOME OF THE OPERATOR'S OWN ACT, RENDERED -- including WHICH ARTIFACT SURVIVED, if any. ***
        operatorWipeWords = outcome.summaryWords
        bootstrapWords = "operator resolution: " + outcome.summaryWords
        attemptConstruction()
        return outcome
    }

    /// *** THE RETRY ROAD FOR AN OUTSTANDING ESTATE: DRIVE THE LADDER AGAIN OVER THE SAME ESTATE, THEN RE-ATTEMPT. ***
    ///
    /// *Retained for a caller that already holds an outcome the authority produced (and used by the gated rendered
    /// road above); the RENDERED control reaches the drive through `recoveryRetry()`, which consults the decision
    /// first.*
    @discardableResult
    public func noteRecoveryRetry(_ outcome: RecoveryLadderOutcome) -> RecoveryLadderOutcome {
        bootstrapWords = "recovery retry: " + outcome.summaryWords
        attemptConstruction()
        return outcome
    }
}

/// *** GS-UX-001 `accessibility` law 4: THE PLATFORM'S 44pt TOUCH-TARGET MINIMUM, APPLIED AT THE CONTROL. ***
///
/// *A plain SwiftUI `Button("Send")` lays out to roughly its TEXT's height -- about 20-30pt -- so every lab control
/// was below the 44pt minimum the shared contract requireth.* **THE LIVE LANE MEASURETH EACH CONTROL'S LAID-OUT FRAME
/// AND WOULD REDDEN**, which is exactly why the measurement is taken rather than the model asserted: a court handed a
/// constant could never have seen this.*
///
/// *So each INTERACTIVE control carrieth the minimum explicitly. `contentShape` is what maketh the WHOLE enlarged
/// frame tappable rather than only the glyph inside it -- without it the frame groweth and the hit target doth not,
/// which is the difference between a measured minimum and a claimed one.*
extension View {
    func labTouchTarget() -> some View {
        frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
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
        // *** *** IOS-R6: THE RECOVERY-ONLY TOPOLOGY -- NO SENSITIVE RESOURCE REACHABLE WITHOUT A SETTLED ESTATE. *** ***
        //
        // *THE DEFECT THE REVIEW NAMED: the real lab composed its identities, nodes and trust store unconditionally,
        // so a pending or corrupt wipe still produced a fully sensitive surface. **THIS GATE IS THE FIX AT THE
        // SURFACE**: when the holder holds NO runtime (an outstanding wipe, a corrupt record, or a refused
        // composition), the lab renders ONLY the recovery/operator screen and the TabView's journeys are never
        // built -- so no Send, no SOS, no contact, and no store is reachable behind a mere flag.*
        if let runtime = holder.runtime {
            // *** THE OPERATOR'S LAST RESOLUTION SURVIVES THE RE-GATE. *** *A successful resolution composes the
            // normal graph in the SAME state update, so the recovery-only surface (and its summary) is replaced before
            // it can repaint. The holder's readout is written from the authority's OWN typed result and carries into
            // the normal graph, so the operator's act is VISIBLE rather than lost to the transition it caused.*
            if !holder.operatorWipeWords.isEmpty {
                VStack(alignment: .leading) {
                    Text("operator wipe: " + holder.operatorWipeWords)
                        .font(.footnote)
                        .accessibilityIdentifier("lab.recovery.operatorwipe")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal])
            }
            journeys(runtime)
        } else {
            LabRecoveryOnlyView()
        }
    }

    /// The five journeys, reachable ONLY when a runtime was built against a consumed, estate-bound permit.
    @ViewBuilder
    private func journeys(_ runtime: LabRuntime) -> some View {
        // GS-LAB-001 step 4's NAVIGATION HALF (round 268): MINIMAL VIEWS FOR THE FIVE JOURNEYS THE CARD NAMETH --
        // identity, contacts, conversation, SOS and diagnostics. They are MINIMAL ON PURPOSE: the card asketh for
        // navigation to them, not for finished screens, and `GS-UX-001` (which dependeth on this finding) carrieth the
        // deeper journeys. Each screen SAYETH what it is and carrieth NO readiness claim.
        TabView(selection: $selection) {
            LabIdentityView(runtime: runtime).tabItem {
                // GS-UX-001 step 7 (round 277): A VISIBLE WORD IS NOT A SEMANTIC -- the
                // screen reader announceth the LABEL, and a test addresseth the IDENTIFIER.
                Text("Identity").accessibilityLabel("Identity screen").accessibilityIdentifier("lab.tab.identity")
            }
            .tag(0)
            LabContactsView(runtime: runtime).tabItem {
                // GS-UX-001 step 7 (round 277): A VISIBLE WORD IS NOT A SEMANTIC -- the
                // screen reader announceth the LABEL, and a test addresseth the IDENTIFIER.
                Text("Contacts").accessibilityLabel("Contacts screen").accessibilityIdentifier("lab.tab.contacts")
            }
            .tag(1)
            LabConversationView(runtime: runtime).tabItem {
                // GS-UX-001 step 7 (round 277): A VISIBLE WORD IS NOT A SEMANTIC -- the
                // screen reader announceth the LABEL, and a test addresseth the IDENTIFIER.
                Text("Conversation").accessibilityLabel("Conversation screen").accessibilityIdentifier("lab.tab.conversation")
            }
            .tag(2)
            LabSosView(runtime: runtime).tabItem {
                // GS-UX-001 step 7 (round 277): the CLASS is LabSosView while the LABEL is "SOS" -- two spellings for
                // one journey, and the navigation invariant asketh for the class while this label is what is HEARD.
                Text("SOS").accessibilityLabel("SOS screen").accessibilityIdentifier("lab.tab.sos")
            }
            .tag(3)
            LabDiagnosticsView(runtime: runtime, lastLifecyclePhase: String(describing: holder.lastLifecyclePhase)).tabItem {
                // GS-UX-001 step 7 (round 277): A VISIBLE WORD IS NOT A SEMANTIC -- the
                // screen reader announceth the LABEL, and a test addresseth the IDENTIFIER.
                Text("Diagnostics").accessibilityLabel("Diagnostics screen").accessibilityIdentifier("lab.tab.diagnostics")
            }
            .tag(4)
        }
    }
}

/// *** *** IOS-R6: THE RECOVERY-ONLY SURFACE -- WHAT A LAB WITH NO SETTLED ESTATE RENDERS. *** ***
///
/// *It carrieth NO journey: no Send, no SOS, no trust operation. It NAMES the typed estate state a human must act on,
/// and -- for a genuinely corrupt record -- offers the ONE legitimate operator action: an explicit, complete, owned
/// wipe (`resolveCorruptForOperator`), never a silent clear-journal. **THE RETRY ROAD IS FOR AN OUTSTANDING ESTATE;
/// the OPERATOR ROAD is for an unreadable one.***
struct LabRecoveryOnlyView: View {
    @EnvironmentObject private var holder: LabRuntimeHolder

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 12) {
            LabBanner()
            Text("Recovery").font(.title)
                .accessibilityIdentifier("lab.recovery.title")

            // THE TYPED DECISION, RENDERED -- the words a person acts on.
            //
            // *** THE `Text`-CONTENT IDIOM IS DELIBERATE (the same one `lab.diagnostics.wipestate` useth): SwiftUI
            // treats a `Text`'s content as its accessibility label, so a UI arm reading `.label` sees the WHOLE
            // rendered string -- which is what maketh these readouts bindeable from outside the process. ***
            Text("estate: " + holder.estateDecision.name)
                .font(.footnote)
                .accessibilityIdentifier("lab.recovery.decision")

            Text("rung: " + (holder.estateRung ?? "none read"))
                .font(.footnote)
                .accessibilityIdentifier("lab.recovery.rung")

            Text(holder.bootstrapWords)
                .font(.footnote)
                .accessibilityIdentifier("lab.recovery.bootstrap")

            // *** G1: THE RETRY'S OWN TYPED ANSWER, so the arm can bind the resume's effect without racing the
            // re-gate that a successful drive triggers above. ***
            if !holder.retryWords.isEmpty {
                Text(holder.retryWords)
                    .font(.footnote)
                    .accessibilityIdentifier("lab.recovery.retrywords")
            }

            // *** G1: THE TYPED LAWS, RENDERED SO AN ARM CAN BIND THE GATE ITSELF (never a UI-local boolean). ***
            Text("gate: recovery=" + (holder.permitsRecoveryConstruction ? "permitted" : "denied")
                 + " operator=" + (holder.requiresOperator ? "required" : "not-required")
                 + (holder.refusalReason.map { " reason=" + $0 } ?? ""))
                .font(.footnote)
                .accessibilityIdentifier("lab.recovery.gate")

            // *** *** G1: ZERO-PRIVATE-OPEN, WITNESSED AT THE REAL STORE-CONSTRUCTION DOORS. *** ***
            //
            // *A recovery-only surface with no tab proveth only what the render gate did. This COUNT is raised inside
            // `LabRuntime.compose` at the two calls that really construct a private store -- so a normal boot after a
            // settled estate reads NON-ZERO here (the positive control), while a pending/corrupt estate reads zero.*
            Text("private stores opened: " + String(LabRecoveryOpenProbe.privateStoreOpens))
                .font(.footnote)
                .accessibilityIdentifier("lab.recovery.privateopens")

            // *** G1: THE RETRY IS OFFERED *ONLY* WHERE THE DURABLE DECISION EARNS IT (`permitsRecoveryConstruction`:
            // pending/retryable). It is a RESUME (`requestFresh: false`) through the gated holder door -- so a settled
            // estate cannot start destruction, and a corrupt record cannot reach the operator's road from here. ***
            if holder.permitsRecoveryConstruction {
                Button("Retry recovery") {
                    _ = holder.recoveryRetry()
                }
                .labTouchTarget()
                .accessibilityIdentifier("lab.recovery.retry")
                .accessibilityLabel("Retry recovery")
            }

            // *** G1: THE OPERATOR'S ROAD IS OFFERED *ONLY* WHERE THE DECISION `requiresOperator` (corrupt/terminal),
            // and it is an EXPLICIT, COMPLETE, OWNED wipe -- never a silent clear-journal. ***
            if holder.requiresOperator {
                Button("Resolve corruption (operator wipe)") {
                    _ = holder.resolveCorrupt()
                }
                .labTouchTarget()
                .accessibilityIdentifier("lab.recovery.resolve")
                .accessibilityLabel("Resolve corruption with an operator wipe")
            }

            // *** G1: THE OPERATOR'S OWN RESULT, RENDERED FROM THE TYPED OUTCOME -- including any artifact that
            // SURVIVED -- so the control's effect is the authority's answer rather than a phrase this view chose. ***
            if !holder.operatorWipeWords.isEmpty {
                Text("operator wipe: " + holder.operatorWipeWords)
                    .font(.footnote)
                    .accessibilityIdentifier("lab.recovery.operatorwipe")
            }
        }
        .padding()
        }
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
    /// *** IOS-R6: THE SETTLED RUNTIME, HANDED BY THE GATE. *** *This view is built ONLY when the
    /// holder holds a runtime (a settled estate with a consumed permit), so it never guards for nil.*
    let runtime: LabRuntime

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
            Text("labels: " + runtime.labels.joined(separator: ", "))
                .accessibilityIdentifier("lab.identity.labels")
            Text("durable road: " + (runtime.hasDurableRoad ? "reachable" : "absent"))
                .accessibilityIdentifier("lab.identity.durableness")
        }
        .padding()
        }
    }
}

struct LabContactsView: View {
    /// *** IOS-R6: THE SETTLED RUNTIME, HANDED BY THE GATE. *** *This view is built ONLY when the
    /// holder holds a runtime (a settled estate with a consumed permit), so it never guards for nil.*
    let runtime: LabRuntime
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
        displayedFingerprint = runtime.trustFingerprint(for: selectedContact) ?? ""
        displayedCandidate = runtime.displayedRotationCandidate(for: selectedContact)
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
            ForEach(runtime.labels, id: \.self) { label in
                Text(label + " holdeth " + String(runtime.heldCount(label)) + " message(s)")
                    .accessibilityIdentifier("lab.contacts." + label)
            }

            Divider()

            Text("Trust Operations").font(.headline)

            // Contact selection picker
            Picker("contact", selection: $selectedContact) {
                ForEach(runtime.trustContactLabels(), id: \.self) { label in
                    Text(label).tag(label)
                }
            }
            .labTouchTarget()
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
                Text("status: " + runtime.contactTrustLabel(selectedContact)).font(.footnote)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("lab.trust.status")
            .accessibilityLabel("Verification status for \(selectedContact)")
            .accessibilityValue(runtime.contactTrustLabel(selectedContact))

            HStack(spacing: 8) {
                Button("Compare/Confirm") {
                    // *** THE CAPTURED STRING, NOT A FRESH READ. *** *The user is confirming what they SAW; a read
                    // taken here could differ from the rendered value and would confirm a string nobody compared.*
                    trustOutcome = runtime.compareAndConfirmFingerprint(
                        for: selectedContact, displayedFingerprint: displayedFingerprint)
                }
                .labTouchTarget()
                .accessibilityIdentifier("lab.trust.confirm")
                .accessibilityLabel("Compare and confirm fingerprint")
                .accessibilityHint("Confirms the fingerprint shown for \(selectedContact)")

                Button("Approve Rotation") {
                    // *** THE DISPLAYED REF TRAVELS -- NO LABEL, NO RE-RESOLVE, NO REFRESH. ***
                    guard let candidate = displayedCandidate else {
                        trustOutcome = "refused: no rotation candidate was displayed for '\(selectedContact)'"
                        return
                    }
                    trustOutcome = runtime.approveDisplayedRotation(candidate)
                    // And the screen re-captures afterwards, so the next tap is about what is now shown.
                    captureDisplayed()
                }
                .labTouchTarget()
                .accessibilityIdentifier("lab.trust.approve")
                .accessibilityLabel("Approve rotation")
                .accessibilityHint("Approves the exact rotation candidate shown for \(selectedContact)")

                Button("Revoke") {
                    let contact = selectedContact
                    trustOutcome = runtime.revokeContact(for: contact)
                }
                .labTouchTarget()
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
                trustOutcome = runtime.seedRotation(for: selectedContact,
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
            .labTouchTarget()
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
            if let first = runtime.trustContactLabels().first {
                selectedContact = first
            }
            captureDisplayed()
        }
    }
}

struct LabConversationView: View {
    /// *** IOS-R6: THE SETTLED RUNTIME, HANDED BY THE GATE. *** *This view is built ONLY when the
    /// holder holds a runtime (a settled estate with a consumed permit), so it never guards for nil.*
    let runtime: LabRuntime
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

    /// *** GS-UX-001 `accessibility`: WHAT THIS SCREEN LAST POSTED THROUGH THE ANNOUNCEMENT DOOR. ***
    ///
    /// *The rendered outcome is a status that CHANGES, and on iOS a repainted `Text` is not announced. The mechanism
    /// is the platform's own: `.accessibilityAddTraits(.updatesFrequently)` DECLARES that the value changeth, and
    /// `UIAccessibility.post(notification:.announcement)` SPEAKS it. This record is what a court can bind: **it is
    /// written in the SAME method that posteth**, so a screen that rendered a status and announced nothing readeth
    /// `nothing yet` and reddens.*
    ///
    /// *** AND THE ANNOUNCEMENT IS POSTED AT THE TRANSITION ITSELF, NOT ONLY VIA `onChange`. ***
    ///
    /// *MEASURED, AND IT IS THE DEFECT THIS METHOD REPLACETH: `.onChange(of:)` fires ONLY on a change AFTER the view
    /// has appeared, so the FIRST non-initial state a surface reached could be rendered and never announced at all --
    /// measured on this very arm, where the door read `nothing yet` after a real status change.* **A DOOR THAT IS
    /// ONLY OPENED FOR *SUBSEQUENT* CHANGES IS A DOOR A USER OF ASSISTIVE TECHNOLOGY CAN NEVER HEAR THE IMPORTANT
    /// PART THROUGH.** *So the helper is called where the value is SET -- the transition, whichever direction it
    /// goeth -- and the initial placeholder is deliberately not announced (announcing `nothing sent yet` on launch
    /// would be noise rather than a status).*
    ///
    /// **AND THE LIMIT IS NAMED RATHER THAN GLOSSED:** *XCUITest carrieth no API to observe a posted announcement, so
    /// this binds the DOOR'S OWN RECORD and the trigger -- never the platform's read-back, which stayeth with the
    /// human screen-reader acceptance.*
    @State private var announced: String = ""

    /// The ONE place this surface speaketh: set-and-announce, so no state change can be rendered silently.
    private func announceOutcome(_ words: String) {
        outcome = words
        announced = words
        LabAnnouncements.announce(words)
    }

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
                ForEach(runtime.labels, id: \.self) { label in Text(label).tag(label) }
            }
            .labTouchTarget()
            .accessibilityIdentifier("lab.conversation.author")
            // *** A SELECTION CONTROL MUST CARRY ITS CURRENT SELECTION (measured: the roster's selected-state check
            // found the value EMPTY). SwiftUI's `Picker` does not always publish its selection as the accessibility
            // value, so it is stated explicitly -- the same law the trust status/octet readouts already obey. ***
            .accessibilityLabel("Author")
            .accessibilityValue(author)

            Picker("to", selection: $recipient) {
                ForEach(runtime.recipientsExcluding(author), id: \.self) { label in
                    Text(label).tag(label)
                }
            }
            .labTouchTarget()
            .accessibilityIdentifier("lab.conversation.recipient")
            .accessibilityLabel("Recipient")
            .accessibilityValue(recipient)

            // *** AND THE LINK STATE, RENDERED: a recipient that cannot be reached must be VISIBLE as such rather
            // than silently failing an action. The register is the runtime's own. ***
            Text(runtime.isLinked(author, recipient)
                 ? "link: up \(author)->\(recipient)"
                 : "link: down \(author)->\(recipient)")
                .accessibilityIdentifier("lab.conversation.linkstate")

            // *** A REAL UTF-8-BOUNDED INPUT AND A REAL SEND ACTION (step 4's core), WIRED TO THE RUNTIME. ***
            TextField("message", text: $body_)
                .textFieldStyle(.roundedBorder)
                .labTouchTarget()
                // *** GS-UX-001 law 2: THE FIELD MUST CARRY ITS OWN ACCESSIBLE NAME. ***
                // *MEASURED: without this the field read an EMPTY label -- a placeholder is not an accessible name,
                // so a screen reader announceth NOTHING for the control a user must type into, which is law 2's own
                // defect.*
                .accessibilityLabel("Message text")
                .accessibilityIdentifier("lab.conversation.field")
                .onChange(of: body_) { _ in boundTheInput() }

            // *** THE OCTET READOUT, BECAUSE A BOUND A USER CANNOT SEE IS A BOUND THEY CANNOT RESPECT. ***
            //
            // *It reads `LabRuntime.composeOctetsReadout`, which measures the string in UTF-8 octets against the
            // PROBED cap -- so the number rendered and the number enforced are the same number.*
            HStack(spacing: 0) { Text(runtime.composeOctetsReadout(body_)).font(.footnote) }
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("lab.conversation.octets")
                .accessibilityLabel("Conversation size")
                .accessibilityValue(runtime.composeOctetsReadout(body_))

            Button("Send") {
                let text = body_
                let from = author, to = recipient
                // THE INTENT IS MINTED HERE, so the rendered verdict can name the id the send pinned.
                let intent = LabRuntime.mintIntentId()
                intentHex = intent.map { String(format: "%02x", $0) }.joined()
                Task {
                    // *** THE TRANSITION ITSELF ANNOUNCETH: the Send's own answer is what a screen-reader user must
                    // hear, and it is posted here rather than left to a change observer.*
                    announceOutcome(await runtime.sendDirectDurableIntent(
                        from, recipient: to, plaintext: Data(text.utf8), intentId: intent))
                    durableVerdict = runtime.durableIntentVerdict(intent)
                }
            }
            .labTouchTarget()
            .accessibilityIdentifier("lab.conversation.send")
            // *** GS-UX-001 `accessibility`: THE OUTCOME IS ANNOUNCED, NOT MERELY REPAINTED. ***
            //
            // *`updatesFrequently` is the platform's own declaration that this element's value changeth and must be
            // re-announced; the `onChange` posteth the platform's own announcement with the SHARED words -- the same
            // vocabulary Android's `stateDescription` speaketh.* **A DELIVERED MESSAGE THAT LANDETH SILENTLY IS A
            // MESSAGE A SCREEN-READER USER NEVER HEARS ABOUT.**
            Text(outcome)
                .accessibilityIdentifier("lab.conversation.outcome")
                .accessibilityAddTraits(.updatesFrequently)
                // *AND THE ONE DECLARATION IS PAIRED WITH A FALLBACK OBSERVER, so a status set by ANY other road
                // (a future caller, a restored value) is still announced rather than silently repainted.*
                .onChange(of: outcome) { words in
                    announced = words
                    LabAnnouncements.announce(words)
                }
            HStack(spacing: 0) {
                Text("announced: " + (announced.isEmpty ? "nothing yet" : announced)).font(.footnote)
            }
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("lab.a11y.announced")
                .accessibilityLabel("Last announced status")
                .accessibilityValue(announced.isEmpty ? "nothing yet" : announced)

            // *** AND THE REOPEN'S OWN ANSWER, RENDERED -- THE CLAUSE THAT SEPARATES A DURABLE ROAD FROM A MEMORY ONE. ***
            //
            // *On a FRESH LAUNCH this reads the LAST RECORDED intent from the holder-owned register, so the rendered
            // line is the RELAUNCH discriminator itself: `.found` survives the process, `.notFound` for a never-authored
            // id is what maketh `.found` mean something.*
            HStack(spacing: 0) {
                Text("durable: " + (durableVerdict == "not asked"
                                    ? runtime.durableVerdictForLastIntent()
                                    : durableVerdict)).font(.footnote)
            }
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("lab.conversation.durable")
                .accessibilityLabel("Durable intent verdict")
                .accessibilityValue(durableVerdict == "not asked"
                                    ? runtime.durableVerdictForLastIntent()
                                    : durableVerdict)

            // *** GS-UX-001 STEP 7: A READOUT OF THE RUNTIME'S OWN COUNT, SO THE ARM CAN BIND RUNTIME-OWNED STATE. ***
            //
            // *AN EXTERNAL REVIEW'S SHARPEST POINT: asserting the outcome TEXT only proves the view wrote something,
            // and `expectation(for:evaluatedWith:)` with `NSPredicate("label != %@")` is a CLASSIC SILENT FALSE
            // NEGATIVE on a SwiftUI Text (stale snapshot / KVC). **A CONTROL WHOSE CLOSURE IS REPLACED BY A LOCAL
            // STRING WRITE WOULD STILL PASS IT.*** This readout is `admittedCount()` -- **THE RUNTIME'S OWN COUNTER,
            // which no view can fabricate** -- so an unwired action and a stuck await BOTH redden.*
            Text("admitted: " + String(runtime.admittedCount()))
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
    /// *** IOS-R6: THE SETTLED RUNTIME, HANDED BY THE GATE. *** *This view is built ONLY when the
    /// holder holds a runtime (a settled estate with a consumed permit), so it never guards for nil.*
    let runtime: LabRuntime

    @State private var heldSince: ContinuousClock.Instant?
    @State private var armed = false
    @State private var outcome: String?
    /// The rendered distress state, read from the delivery row (or the durable register) in the shared vocabulary.
    @State private var sosState: String = "no active call"

    /// *** GS-UX-001 `accessibility`: THE SOS ANNOUNCEMENT DOOR'S OWN RECORD, written where it posteth. ***
    @State private var sosAnnounced: String = ""

    /// The ONE place the distress state speaketh: set-and-announce, at the transition itself.
    ///
    /// *The same measured defect as the conversation surface's: a change observer misseth the FIRST non-initial
    /// state, and an armed or cancelled call is the most consequential state change on this screen.*
    private func announceSosState(_ words: String) {
        sosState = words
        sosAnnounced = words
        LabAnnouncements.announce(words)
    }

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
        outcome = runtime.armSos(payload: Data("SOS".utf8))
        // *** THE TRANSITION ANNOUNCETH: an armed call must be SPOKEN, not merely repainted. ***
        announceSosState(runtime.sosStateNames())
    }

    /// Cancel the standing call by the DURABLE msg_id -- the node's own `.cancel(msgId)` arm.
    private func cancelSos() {
        guard let msgId = runtime.activeSosMsgId() else {
            outcome = "refused: nothing to cancel"
            return
        }
        outcome = runtime.cancelSos(msgId: msgId)
        // *** AND A CANCELLED CALL TOO -- it is the change a bystander most needeth to hear. ***
        announceSosState(runtime.sosStateNames())
    }

    /// *** GS-UX-001 `required-retry`: RESUME THE STANDING CALL -- THE NODE'S OWN `.retry(msgId)` ARM. ***
    ///
    /// *The id is read from the DURABLE projection at tap time, and the runtime answers a `nil` with the typed refusal a
    /// user must be told. **THE OUTCOME IS ANNOUNCED LIKE THE OTHER TWO TRANSITIONS**, because a resumed call is a state
    /// change of the same consequence as an armed or a cancelled one.*
    ///
    /// *** AND IT IS PREFIXED `resume:` -- WHICH IT WAS NOT, AND THAT WAS A REAL DEFECT, NOT A COSMETIC ONE. ***
    /// *The rendered outcome must name WHICH ARM RAN (`LabRuntime` prefixes the other arms with `armed:`/`cancelled:`
    /// for exactly this reason), and a resume that read as a bare `armed:` would be indistinguishable from a fresh
    /// arm. **THE `retry` COURT ASSERTS THIS VOCABULARY (`resume:`/`refused:`), and the prefix is what maketh the
    /// rendered string evidence of the ROAD rather than of a phrase the view chose.***
    private func retrySos() {
        let answer = runtime.retrySos(msgId: runtime.activeSosMsgId())
        outcome = answer.hasPrefix("refused") ? answer : "resume:" + answer
        announceSosState(runtime.sosStateNames())
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
                .labTouchTarget()
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
                .labTouchTarget()
                .accessibilityIdentifier("lab.sos.send")

            // *** THE CANCELLABLE ROAD THE CARD NAMES ("SOS hold/cancel"), BY ITS OWN DURABLE ID. ***
            Button("Cancel the call") { cancelSos() }
                .accessibilityLabel("Cancel the distress call")
                .labTouchTarget()
                .accessibilityIdentifier("lab.sos.cancel")

            // *** *** GS-UX-001 `required-retry`: THE ESSENTIAL `Retry` CONTROL, WHICH WAS OMITTED ENTIRELY. *** ***
            //
            // *THE CONTRACT'S OWN ROSTER NAMES IT ESSENTIAL -- `AccessibilityContract.essentialControls` carrieth
            // `("retry", "Retry")`, and the SHARED Android lab already renders it (`LabMeshJourneyScreen`'s
            // `LabControl.RETRY`, bound to `LabJourneyBindings.retry()` -> `SosCommand.Retry`).* **ON THIS ISLE THE
            // CAPABILITY STOOD (`MeshNode.handleSosCommand(.retry)`) AND NO RENDERED CONTROL COULD REACH IT** -- *so a
            // user whose call was queued and never left could do nothing to resume it, while a source grep for
            // "retry" found plenty. That is precisely the omission a control-level check exists to catch and a
            // text-level check cannot.*
            //
            // **AND THE ID COMES FROM THE DURABLE PROJECTION, NOT FROM THIS VIEW'S MEMORY:** *a view that remembered an
            // id could name work the estate no longer carrieth; the runtime readeth it at the moment of the tap, and a
            // `nil` is answered with the refusal a user must be told ("no standing distress call to retry").*
            Button("Retry") { retrySos() }
                .accessibilityLabel("Retry")
                .labTouchTarget()
                .accessibilityIdentifier("lab.sos.retry")

            // *** THE OUTCOME IS ALWAYS RENDERED, EVEN BEFORE ANY ACTION -- a conditional `if let` made the element
            // ABSENT until an arm drove an action, so a combination that never acted (the roster's default-scale arm)
            // measured it missing. The placeholder is a non-empty truthful line, and every action still replaces it
            // with the runtime's own answer. ***
            Text(outcome ?? "no distress action yet")
                .font(.footnote)
                .accessibilityIdentifier("lab.sos.outcome")

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
                // *** GS-UX-001 `accessibility`: AN ARMED OR CANCELLED CALL IS THE MOST CONSEQUENTIAL STATE CHANGE ON
                // THIS SCREEN, SO IT IS ANNOUNCED RATHER THAN LEFT TO A REPAINT. ***
                //
                // *The Android twin carrieth `LiveRegionMode.Assertive` here for that reason; iOS's road is the
                // `.updatesFrequently` trait plus the platform's own announcement, posted with the shared words when
                // the state actually changeth.*
                .accessibilityAddTraits(.updatesFrequently)
                .onChange(of: sosState) { words in
                    sosAnnounced = words
                    LabAnnouncements.announce(words)
                }
                // *** THE FIRST LOOK IS ANNOUNCED TOO, GUARDED: a STANDING call restored from the durable estate is
                // the state a user must hear on arrival, while the EMPTY initial placeholder is deliberately silent
                // (announcing "no active call" on launch would be noise rather than a status).*
                .onAppear {
                    let words = runtime.sosStateNames()
                    sosState = words
                    if words.hasPrefix("active: ") || words.hasPrefix("terminal: ") {
                        sosAnnounced = words
                        LabAnnouncements.announce(words)
                    }
                }

            // *** AND THE SOS'S OWN ANNOUNCEMENT RECORD, SO A COURT CAN BIND THE DOOR RATHER THAN TRUST IT. ***
            HStack(spacing: 0) {
                Text("announced: " + (sosAnnounced.isEmpty ? "nothing yet" : sosAnnounced)).font(.footnote)
            }
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("lab.sos.announced")
                .accessibilityLabel("Last announced distress state")
                .accessibilityValue(sosAnnounced.isEmpty ? "nothing yet" : sosAnnounced)

            // *** AND THE RUNTIME'S OWN COUNT, SO THE SOS ARM CAN BIND RUNTIME-OWNED STATE TOO. ***
            Text("sos admitted: " + String(runtime.admittedCount()))
                .accessibilityIdentifier("lab.sos.admitted")
        }
        }
    }
}

struct LabDiagnosticsView: View {
    /// *** IOS-R6: THE SETTLED RUNTIME, HANDED BY THE GATE. *** *This view is built ONLY when the
    /// holder holds a runtime (a settled estate with a consumed permit), so it never guards for nil.*
    let runtime: LabRuntime
    /// The lifecycle phase the owner last heard, rendered here (the owner is the ONE place the notification lands).
    let lastLifecyclePhase: String
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
            Text("last lifecycle phase: " + lastLifecyclePhase)
                .font(.footnote)

            // *** GS-UX-001 STEP 6 / GS-FINAL-003 `true-recovery-topology`: THE WIPE JOURNEY, FROM THE PRODUCTION
            // LADDER'S OWN DURABLE RECORD -- AND THE CONTRADICTION THE OLD COMMENT CONFESSED IS NOW GONE. ***
            //
            // *The comment that stood here said this surface read "THE COMPOSITION HARNESS'S OWN WIPE REGISTER ...
            // because that is the register this runtime has -- AND IT SAYS SO", while the card's step 6 asks for "wipe
            // progress from the real reopened store" and the ledger's own sentence forbids "a LABEL THAT CLAIMS A RUNG
            // IT NEVER READ".* **THE LIMIT IS CLOSED RATHER THAN DOCUMENTED:** *`wipeStateName()` now readeth
            // `WipeJournalDurabilityAdapter` over the SAME durable journal the shipping ladder writeth, so the string
            // rendered here and the rung a fresh process resumes from are the same record -- and it surviveth a relaunch,
            // which the flag never did.*
            //
            // **AND THE BUTTON IS THE REAL LADDER, NOT A FLAG:** `beginWipe()` drives
            // `MeshRuntime.runRecoveryLadder(requestFresh: true)` -- *the SAME road `MeshRuntime.create` takes before it
            // opens any private store* -- so this journey exercises drain, key erasure, artifact deletion and identity
            // publication rather than setting a boolean beside them.
            Text("wipe: " + runtime.wipeStateName())
                .accessibilityIdentifier("lab.diagnostics.wipestate")

            // *** THE TYPED OUTCOME, RENDERED: WHICH OF THE SIX ESTATES THE LADDER REACHED, WHICH RUNG IT STANDS AT,
            // AND WHICH PRIVATE ARTIFACT (IF ANY) SURVIVED. ***
            //
            // *A single word ("wiped") cannot carry those three facts, and the finding's own remediation clause is
            // explicit: "render completion only at durable IDLE". The words below come from `RecoveryLadderOutcome`
            // itself -- the rung from the JOURNAL's wire spelling, the artifacts from the FILESYSTEM -- so a surface
            // cannot say "complete" over a store that still stands.*
            Text("rung: " + runtime.recoveryRungWords())
                .font(.footnote)
                .accessibilityIdentifier("lab.diagnostics.wiperung")
            Text("artifacts: " + runtime.recoveryArtifactWords())
                .font(.footnote)
                .accessibilityIdentifier("lab.diagnostics.wipeartifacts")

            // *** GS-FINAL-003 `operator-required`: THE STARTUP DECISION AND WHETHER A HUMAN MUST DECIDE. ***
            //
            // *The card asks for "explicit operator-required for genuine corruption", and `requiresOperator` is the
            // field that CARRIES that requirement -- a bare Boolean cannot express "refused, and a person must
            // intervene". It is rendered here so the distinction is visible rather than inferable from an error string.*
            // **THE READ OPENS NO STORE:** `MeshRuntime.startupRecoveryDecision` owns the deferred create-time seams and
            // answers from the durable record alone.
            Text("startup recovery: " + LabRuntime.startupRecoveryWords())
                .font(.footnote)
                .accessibilityIdentifier("lab.diagnostics.startuprecovery")

            // *** *** G1: ZERO-PRIVATE-OPEN'S POSITIVE CONTROL, RENDERED ON A NORMAL BOOT. *** ***
            //
            // *The recovery surface renders the same count while the estate is blocked; THIS render is the control the
            // arm compares it against -- a normal boot after a settled estate MUST read NON-ZERO, so a count that was
            // never raised (the constant-zero witness the contract forbids) reddens HERE.*
            Text("private stores opened: " + String(LabRecoveryOpenProbe.privateStoreOpens))
                .font(.footnote)
                .accessibilityIdentifier("lab.diagnostics.privateopens")

            Button("Begin wipe") {
                wipeNote = runtime.beginWipe().summaryWords
            }
            .labTouchTarget()
            .accessibilityIdentifier("lab.diagnostics.beginwipe")

            Button("Resume wipe") {
                wipeNote = runtime.resumeWipe().summaryWords
            }
            .labTouchTarget()
            .accessibilityIdentifier("lab.diagnostics.resumewipe")
            .accessibilityLabel("Resume the wipe from its durable record")

            Text("wipe result: " + wipeNote)
                .font(.footnote)
                .accessibilityIdentifier("lab.diagnostics.wiperesult")
        }
        }
    }
}
