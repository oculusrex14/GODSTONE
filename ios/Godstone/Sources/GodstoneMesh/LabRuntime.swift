import Foundation
import CryptoKit
import GodstoneCore

// ---------------------------------------------------------------------------
// T54 -- the LabMesh runtime seam, living INSIDE the nonshipping GodstoneMesh
// module. The Swift twin of android/mesh/src/main/java/io/godstone/mesh/lab/
// LabRuntime.kt, with the SAME laws.
//
// It liveth here rather than in the lab application target for one honest
// reason: the composed runtime is built from authorities that are internal to
// GodstoneMesh, and publishing them all would widen a nonshipping-but-delicate
// surface for the convenience of a lab. So the lab ENTRY is a small PUBLIC
// handle with a deliberately narrow surface -- labels, an honest readiness
// statement, a durable state name -- and everything else (the store, the
// tracker, the inbox, the ACK authority) stayeth inside.
//
// Law 1: THE LAB COMPOSETH REAL COMPONENTS -- the production MeshNode over the
// real router, the real durable store, the real DeliveryTracker, the real
// recipient inbox and the real T84 ACK authority, through T44's harness.
// Law 2: THE LAB CANNOT MANUFACTURE READINESS -- no setter, no override, no flag
// writer; MANUFACTURES_READINESS is a compile-time false and the readiness
// statement carrieth no parameter.
// Law 3: THE LAB IS VISIBLY EXPERIMENTAL AND NONSHIPPING.
// ---------------------------------------------------------------------------

/// What the lab reporteth about itself, in one place.
public enum LabProfile {
    public static let name: String = "LABMESH"
    public static let experimental: Bool = true

    /// True iff this build can manufacture crypto readiness. It CANNOT, and the
    /// constant is `false` so a reader -- and the profile gate -- seeth the claim
    /// rather than inferring it from the absence of a setter.
    public static let manufacturesReadiness: Bool = false

    /// The shipping bundle identity the lab may never masquerade as.
    public static let shippingBundleId: String = "io.godstone.app"

    /// The lab's own bundle identity, distinct from the shipping one.
    public static let labBundleId: String = "io.godstone.labmesh"
}

/// The honest readiness statement: every platform field is FALSE.
public struct LabReadiness: Sendable, Equatable {
    public let androidLinkLayerReady: Bool
    public let iosLinkLayerReady: Bool
    public let profile: String
    public let experimental: Bool
}

/// The lab runtime handle.
public final class LabRuntime: @unchecked Sendable {
    private let harness: ComposedRuntimeHarness
    /// *** THE REAL DURABLE TRUST REPOSITORY, RETAINED SO A LAB ARM CAN DRIVE A ROTATION *ARRIVING*. ***
    ///
    /// *The stale-candidate journey is the one the card's law 3 existeth for, and it CANNOT be exercised without a
    /// rotation that lands BETWEEN render and tap. **A COURT CANNOT REACH IT FROM OUTSIDE** -- the repository is
    /// internal and the facade deliberately carrieth no mutation verb for it -- so the lab holdeth the instance
    /// `compose()` already built and driveth the SAME production verb a real handshake driveth
    /// (`PeerIdentityRepository.applyValidatedBinding`). **NO SECOND SOURCE OF TRUTH, NO FABRICATED ROW.***
    private let trustRepository: PeerIdentityRepository
    /// The signing seeds of the composed nodes, so a seeded rotation carrieth the SAME signing key (a differing one
    /// would be a node-id collision, not a rotation).
    private let nodeSigningSeeds: [String: Data]
    public let labels: [String]

    /// *** THE AUTHOR THIS LAB'S JOURNEYS SPEAK AS: THE FIRST COMPOSED LABEL. ***
    ///
    /// *Every rendered send already nameth its author explicitly, so this is not a hidden default -- it is the ONE name
    /// the SOS and durable-reopen accessors use, and it is derived from the composition rather than typed in a view.*
    public var author: String { labels[0] }
    public let trust: MeshTrustFacade

    /// *** GS-UX-001: BINDING-VALIDATION FAILURES, RECORDED RATHER THAN SWALLOWED. ***
    ///
    /// *The composition used to skip a failed binding SILENTLY, so a contact with no identity was
    /// indistinguishable from a lab that registered no contacts at all. **MEASURED BEFORE THIS FIELD EXISTED:
    /// every fingerprint was nil and every contact read "unknown", with no cause anywhere to find.** This makes
    /// that state diagnosable from outside -- hence not `private`.*
    public private(set) static var trustWiringFailures: [String] = []

    /// *** A COURT MUST BE ABLE TO START FROM A CLEAN RECORD, or it measures a previous run's failures. ***
    internal static func resetTrustWiringFailuresForTest() { trustWiringFailures.removeAll() }

    /// *** GS-UX-001 STEP 1 (round 539): IS THE DURABLE ROAD REACHABLE THROUGH THIS HANDLE? ***
    ///
    /// A LAB WHOSE JOURNEYS CANNOT REACH A DURABLE AUTHORITY IS A LAB THAT EXERCISETH NOTHING, and the card's own
    /// charge is that the journeys *'stop at disconnected models and static text'*. THIS PROPERTY MAKETH THE ANSWER
    /// **ASKABLE** rather than asserted in a label: it is TRUE, because `sendDirectDurable` (landed for GS-UX-001 at
    /// round 521) is the door the journey useth -- **AND IT IS A PROPERTY RATHER THAN A COMMENT SO THAT A COURT MAY
    /// READ IT.** (The first draft of the journey view CALLED this name before it existed and the compiler refused
    /// it: **A CALL TO A MEMBER THAT IS NOT THERE IS A COMPILE ERROR, NOT A CAPABILITY.**)
    public var hasDurableRoad: Bool { true }

    private init(harness: ComposedRuntimeHarness, labels: [String], trust: MeshTrustFacade,
                 trustRepository: PeerIdentityRepository, nodeSigningSeeds: [String: Data]) {
        self.harness = harness
        self.labels = labels
        self.trust = trust
        self.trustRepository = trustRepository
        self.nodeSigningSeeds = nodeSigningSeeds
    }
    /// The honest readiness statement. It carrieth no parameter, so no caller can
    /// argue it into saying true.
    public static func readinessStatement() -> LabReadiness {
        LabReadiness(androidLinkLayerReady: false, iosLinkLayerReady: false,
                     profile: LabProfile.name, experimental: LabProfile.experimental)
    }

    /// Compose `labels.count` real peers and link them in a chain, so a message
    /// from the first to the last travelleth through a real relay.
    public static func compose(labels: [String] = ["A", "R", "B"],
                               seedByte: UInt8? = nil) throws -> LabRuntime {
        guard labels.count >= 2 else {
            throw LabRuntimeError(reason: "a lab runtime needs at least two peers")
        }
        guard Set(labels).count == labels.count else {
            throw LabRuntimeError(reason: "lab labels must be distinct")
        }
        let clock = FixedHostClock()
        let harness = ComposedRuntimeHarness(clock: clock, link: LinkFacade(clock: clock))
        var next = seedByte ?? 0x11
        // *** AND THE SIGNING SEED PER NODE IS REMEMBERED, SO A SEEDED ROTATION CAN CARRY THE SAME SIGNING KEY. ***
        //
        // *The harness deriveth a node's Ed25519 seed from the byte it was handed (`addNode`), and a rotation that
        // kept a DIFFERENT signing key would be a node-id collision rather than a rotation -- so the seed is recorded
        // here, where it is already decided, rather than re-derived by a caller.*
        var seeds: [String: Data] = [:]
        for label in labels {
            seeds[label] = Data((0..<32).map { i -> UInt8 in UInt8((Int(next) + i) & 0xFF) })
            _ = try harness.addNode(label, seedByte: next)
            next = next &+ 0x10
        }
        for i in 0..<(labels.count - 1) {
            _ = harness.link(labels[i], labels[i + 1])
        }
        var contactsList: [(label: String, nodeId: Data)] = []
        let trustDbUrl = FileManager.default.temporaryDirectory
            .appendingPathComponent("godstone-lab-trust-\(UUID().uuidString).db")
        let trustStore = try SqlitePeerIdentityStore(url: trustDbUrl)
        let trustRepo = PeerIdentityRepository(store: trustStore)
        for label in labels {
            if let node = harness.node(label) {
                contactsList.append((label: label, nodeId: node.identity.nodeId))
                let raw = try node.identity.issueIdentityBinding().encode()
                  // *** GS-UX-001: A REAL, SILENT PRODUCTION DEFECT, FOUND BY MEASUREMENT. ***
                  //
                  // *THE LAB PASSED `nodeId.prefix(2)` WHERE THE VALIDATOR REQUIRES
                  // `identityBindingNodeHintLength == 4` (`IdentityBindingV1.swift:27`), so EVERY validation
                  // returned `.invalidContext` -- and `if case .valid` HAS NO `else`, SO EVERY BINDING WAS
                  // SILENTLY SKIPPED.*
                  //
                  // **MEASURED CONSEQUENCE, PROBED RATHER THAN ASSUMED:** `trustContactLabels()` returned
                  // `["A","B","R"]` while `trustFingerprint(for:)` returned **nil for EVERY label** and
                  // `contactTrustLabel` returned **"unknown" for every label** -- the facade carried LABELS BUT NO
                  // IDENTITY, because **THE DURABLE REPOSITORY WAS EMPTY.** *A UI rendering an empty fingerprint
                  // list is indistinguishable from a lab with no contacts, which is the false-green this arm
                  // exists to prevent -- and confirm/approve/revoke would operate on NOTHING once the page showed.*
                  //
                  // *`MeshIdentity.nodeHint` is the correct source (`nodeId.prefix(4)`) and already existed. THE
                  // OTHER HALF IS THE `else`: a failed validation must NOT be silent.*
                    // *** EVALUATED ONCE, SO THE FAILURE MESSAGE CANNOT CONTRADICT THE BRANCH TAKEN. ***
                    //
                    // *My first version switched on one call and RE-VALIDATED inside the `default:` to build its
                    // message -- so a mutation that broke the switch's argument produced the self-contradictory
                    // line "FAILED validation valid(...)", because the second call used the CORRECT hint. **A
                    // DIAGNOSTIC THAT DISAGREES WITH THE BRANCH IT EXPLAINS IS WORSE THAN NO DIAGNOSTIC.** One
                    // evaluation, one result, both the branch and the message read it.*
                    let validation = IdentityBindingValidator.validate(
                        serialized: raw,
                        authenticatedRemoteStaticKey: node.identity.staticDhPublicKey,
                        advertisedNodeHint: node.identity.nodeHint
                    )
                    switch validation {
                    case .valid(let validated):
                        _ = trustRepo.applyValidatedBinding(validated)
                    default:
                        // *** RECORDED *AND* REFUSED -- A GUARD THAT ONLY RECORDS IS NOT A GUARD. ***
                        //
                        // *AN EXTERNAL REVIEW MADE THIS POINT AND WAS RIGHT: making the invalid path merely
                        // OBSERVABLE is not the same as making it FAIL. My first fix appended to
                        // `trustWiringFailures`, and **NOTHING IN `Sources` READS IT** -- so a future
                        // `.invalidContext` regression would go unnoticed again, exactly as this one did. A court
                        // now asserts the counter is empty, which binds it; but the stronger statement is available
                        // right here: **EVERY LAB NODE MUST YIELD A VALID BINDING -- A COMPOSE-TIME INVARIANT.** A
                        // violation means the lab is about to hand its UI a contact with NO IDENTITY, an empty
                        // fingerprint list indistinguishable from a lab with no contacts, and the honest response
                        // is to STOP rather than compose a trust surface over nothing and log about it.*
                        LabRuntime.trustWiringFailures.append("\(label): \(validation)")
                        preconditionFailure(
                            "GS-UX-001: the lab node '\(label)' produced a binding that FAILED validation: "
                            + "\(validation). EVERY LAB NODE MUST YIELD A VALID BINDING -- a contact with no "
                            + "identity renders an EMPTY fingerprint list, indistinguishable from a lab with no "
                            + "contacts. This is the invariant whose SILENT violation emptied the durable repository."
                        )
                    }
            }
        }
        let ownNodeId = harness.node(labels[0])?.identity.nodeId ?? Data(repeating: 0x01, count: 16)
        let trustFacade = MeshTrustFacade(
            repository: trustRepo,
            ownNodeId: ownNodeId,
            contacts: contactsList,
            wipeHandler: { [weak harness] in harness?.beginWipe() }
        )
        return LabRuntime(harness: harness, labels: labels, trust: trustFacade,
                          trustRepository: trustRepo, nodeSigningSeeds: seeds)
    }

    /// *** GS-UX-001 `rendered-controls` law 3: SEED A ROTATION THAT ARRIVES *AFTER* THE SCREEN LOOKED. ***
    ///
    /// *The stale-candidate journey is what the card's law 3 existeth for ("THE DISPLAYED CANDIDATE IS THE ONE
    /// APPROVED"), and it cannot be exercised without a real rotation landing BETWEEN render and tap. **THIS DRIVETH
    /// THE SAME PRODUCTION VERB A REAL HANDSHAKE DRIVETH** -- `PeerIdentityRepository.applyValidatedBinding` over a
    /// binding the node's OWN signing key issueth, validated by the real validator -- so it createth no second source
    /// of truth and fabricates no row.*
    ///
    /// *The signing key is the node's real one (hence `nodeSigningSeeds`), because a differing key would be a node-id
    /// collision rather than a rotation. And the result is the authority's OWN taxonomy, which lets a caller tell
    /// "quarantined as a pending candidate" from "rejected" rather than assuming.*
    public func seedRotation(for label: String, generation: UInt32, staticDhSeedByte: UInt8) -> String {
        guard let signingSeed = nodeSigningSeeds[label] else {
            return "refused: unknown label '\(label)'"
        }
        do {
            let binding = try Self.validatedRotationBinding(
                signingSeed: signingSeed,
                generation: generation,
                staticDhSeedByte: staticDhSeedByte
            )
            return "\(trustRepository.applyValidatedBinding(binding))"
        } catch {
            return "refused:\(error)"
        }
    }

    /// Build a binding for the node's OWN signing key at a new generation, validated by the real validator.
    ///
    /// *** THE CONSTRUCTION MOVED TO THE IDENTITY AUTHORITY. *** *IT WAS HERE, AND THE LOCAL-IDENTITY CONTROL
    /// REFUSED IT -- correctly: a binding's construction must appear in NO mesh source but the authority file,
    /// because a call site that can mint its own binding can mint one for a key it does not own.* **So this method now
    /// DELEGATES to `MeshIdentity.issueRotationBinding`, where the authority signeth and SELF-VERIFIETH, and does only
    /// the two things a caller legitimately owns: SUPPLY the lab's seeded material, and RUN the frozen validator over
    /// the result.**
    static func validatedRotationBinding(signingSeed: Data, generation: UInt32,
                                         staticDhSeedByte: UInt8) throws -> ValidatedPeerBinding {
        let binding = try MeshIdentity.issueRotationBinding(
            signingSeed: signingSeed, generation: generation, staticDhSeedByte: staticDhSeedByte)
        let result = IdentityBindingValidator.validate(
            serialized: binding.encode(),
            authenticatedRemoteStaticKey: binding.staticDhPublicKey,
            advertisedNodeHint: IdentityBindingV1.deriveNodeHint(
                nodeId: IdentityBindingV1.deriveNodeId(signingPublicKey: binding.signingPublicKey)
            )
        )
        guard case .valid(let validated) = result else {
            struct RotationSeedRefused: Error { let reason: String }
            throw RotationSeedRefused(reason: "\(result)")
        }
        return validated
    }

    /// The durable state of one message, by NAME (a String, so no internal type
    /// crosses this seam).
    public func durableStateName(_ nodeLabel: String, _ msgId: Data) -> String? {
        guard let node = harness.node(nodeLabel) else { return nil }
        if case .found(let rec) = node.tracker.lookup(msgId) { return "\(rec.state)" }
        return nil
    }

    /// How many messages the named node durably holdeth.
    public func heldCount(_ nodeLabel: String) -> Int {
        harness.node(nodeLabel)?.store.allHeldMsgIds().count ?? 0
    }

    /// Author one DIRECT message at `from` FOR `recipient`.
    public func sendDirect(_ from: String, recipient: String, plaintext: Data) async -> String {
        do {
            return describe(try await harness.sendDirect(from, recipient: recipient, plaintext: plaintext))
        } catch {
            return "refused:\(error)"
        }
    }

    /// Author one SOS broadcast at `from`.
    public func sendSos(_ from: String, plaintext: Data) async -> String {
        describe(await harness.sendSos(from, plaintext: plaintext))
    }

    /// *** GS-UX-001 (STEPS 6 AND 2): **THE LAB'S DURABLE ROAD** -- AND IT IS THE WHOLE POINT OF THE FINDING.
    ///
    /// The card's charge is that the journeys 'stop at disconnected models and static text', and that 'passing a
    /// model test with a fake port does not show a user action reaches a durable authority'. THE DOOR THIS
    /// CALLETH ALREADY STOOD AND IS PUBLIC (`ComposedRuntimeHarness.sendDirectDurable`, landed for CRYPTO-005),
    /// AND ITS ONELY CALLERS WERE TWO COURTS. The lab could not reach it: its own `sendDirect` taketh the
    /// in-memory road, and `compose()` nameth no medium at all -- so NO LAB JOURNEY COULD LEAVE ANYTHING BEHIND.
    ///
    /// THAT IS THIS PROGRAMME'S RECURRING SHAPE IN ITS SIXTH APPEARANCE (an instrument built, witnessed by courts,
    /// and reached by no path a user travels), and it is why the repair is A DOOR AND NOT A NEW MECHANISM: the real
    /// durable authority, BOTH adapters, the trust pin, the trust resolver, the durable journal and the WIPE
    /// OWNERSHIP all stand already -- they were simply never reached from here.
    ///
    /// The medium is CALLER-NAMED, so a journey's consequence can be REOPENED and read by whoever authored it --
    /// which is what the finding's step 6 asketh ('restore ... from the real reopened store') and what no
    /// in-memory medium can ever answer.
    public func sendDirectDurable(_ from: String, recipient: String, plaintext: Data,
                                  intentId: Data, storeURL: URL) async -> String {
        do {
            return describeDurable(try await harness.sendDirectDurable(from, recipient: recipient,
                                                                       plaintext: plaintext,
                                                                       intentId: intentId, storeURL: storeURL))
        } catch {
            return "refused:\(error)"
        }
    }

    /// The authority's own answer, reported LOSSLESSLY and by name, so no internal type crosses this seam.
    private func describeDurable(_ result: SendDirectResult) -> String {
        switch result {
        case .durablyEnqueued(let logicalMessageId, let fromRetry):
            return "durable:" + logicalMessageId.map { String(format: "%02x", $0) }.joined()
                + (fromRetry ? ":retry" : "")
        case .rejected(let reason):
            return "refused:\(reason)"
        }
    }

    // ================================================================================================
    // *** GS-UX-001 STEP 4: THE JOURNEY'S OWN CHOICES, REACHABLE FROM A RENDERED CONTROL. ***
    //
    // THE CARD'S CHARGE IS THAT JOURNEYS "stop at disconnected models and static text". THE MEASURED GAP ON THIS
    // ISLE, TAKEN THIS ROUND: `LabMeshRootApp` rendered a conversation field, a Send button and a hold-to-confirm
    // SOS -- AND NOTHING ELSE the card names. A RECIPIENT SELECTOR, the wipe/recovery STATE and the durable outcome
    // were unreachable from any control, so a user could not perform the journey even though the runtime beneath it
    // was real.
    //
    // **EVERY METHOD HERE DELEGATES TO THE SAME RETAINED RUNTIME THE SENDS USE** -- none of them is a second model.
    // *That is what makes a rendered control a JOURNEY rather than a label: the button and the assertion read the
    // SAME object.*
    // ================================================================================================

    /// The recipients a journey may choose, EXCLUDING the author. *Named so a selector can render the real set
    /// rather than a hardcoded pair -- the card asks for "a real recipient selector", and a list the UI invents is
    /// not one.*
    public func recipientsExcluding(_ from: String) -> [String] {
        labels.filter { $0 != from }
    }

    /// Whether a trusted relation stands between two labels, from the runtime's own register.
    public func isLinked(_ from: String, _ to: String) -> Bool { harness.isLinked(from, to) }

    /// *** THE LINKED PEERS OF ONE NODE, so a selector can grey out what is unreachable rather than offering it. ***
    public func linkedPeers(of from: String) -> [String] { harness.linkedPeerLabels(from) }

    // ------------------------------------------------------------------------------------------------
    // *** WIPE AND RECOVERY STATE: THE JOURNEY STEP 6 NAMES ("wipe progress from the real reopened store"). ***
    // ------------------------------------------------------------------------------------------------

    /// *** THE WIPE STATE, FROM THE COMPOSITION'S OWN REGISTER -- AND THE LIMIT IS STATED RATHER THAN PAPERED OVER. ***
    ///
    /// *MY FIRST VERSION OF THIS METHOD READ A `wipeJournalView()` FROM THE HARNESS. **IT DOES NOT EXIST, AND THE
    /// BUILD SAID SO.** `ComposedRuntimeHarness` carries no wipe journal at all: `beginWipe()` erases the durable
    /// artifact URLs it holds and sets `wiped`. **THE RUNTIME'S LADDER-BEARING WIPE AUTHORITY
    /// (`CrashResumableWipe` + `WipeJournalDurabilityAdapter`) IS A DIFFERENT OBJECT, REACHED THROUGH
    /// `MeshRuntime`, NOT THROUGH THIS HARNESS.***
    ///
    /// **SO THIS METHOD REPORTS WHAT THE HARNESS ACTUALLY KNOWS, AND NAMES WHAT IT DOES NOT.** *Inventing a journal
    /// here to satisfy the shape of step 6 would be a second source of truth beside the real one -- the defect the
    /// step exists to prevent. **A LABEL THAT CLAIMS A RUNG IT NEVER READ IS WORSE THAN ONE THAT SAYS "the lab's
    /// harness carries no wipe ladder".***
    ///
    /// *The LADDER-bearing wipe IS witnessed, by the courts that drive `MeshRuntime` (`CrashStartupResumeTests`'s
    /// `testSR05`/`testSR06`/`testSR07` and `GsFinal003StartupPermitTests`), which read the real journal's rungs. What
    /// this lab can render truthfully is the composition harness's own wipe register.*
    public func wipeStateName() -> String {
        harness.isWiped() ? "wiped" : "standing"
    }

    /// Whether the runtime reports itself wiped, from the composition's own register.
    public func isWiped() -> Bool { harness.isWiped() }

    /// *** BEGIN A WIPE, THROUGH THE COMPOSITION'S REAL OWNER. *** *The lab invokes the same verb the runtime
    /// exposes; it does not simulate one, and it does not set a flag of its own.*
    public func beginWipe() { harness.beginWipe() }

    /// *** GS-UX-001 `rendered-controls`: THE DISTRESS STATE, READ FROM THE DELIVERY ROW AND SPOKEN IN THE SHARED
    /// VOCABULARY. ***
    ///
    /// *The card's step 3 asketh the SOS journey be durable and survive a relaunch, and the words rendered must be the
    /// SHARED ones (`stateWords`, `TrustUXModel.swift:104-113`) -- **never invented**. So the STATE TOKEN this renders
    /// is read from the delivery row (`MeshNode.activeSosSnapshot`'s own projection, `SosCommand.swift:41-59`) at the
    /// moment the command completes, and the register below carrieth that token across the process boundary.*
    ///
    /// *** WHY A REGISTER AND NOT A SECOND ROW READ, STATED PLAINLY BECAUSE IT IS A REAL BOUNDARY. *** *The lab's
    /// composition harness composes its nodes over IN-MEMORY stores (`ComposedRuntimeHarness.addNode`), so no row
    /// surviveth the process -- a claim that the state was re-read from a row after a relaunch would be FALSE. What IS
    /// true is what this method says: the token was read from the row WHILE the row existed, and it is carried
    /// verbatim. **A LABEL THAT CLAIMS A RUNG IT NEVER READ IS WORSE THAN ONE THAT NAMES ITS SOURCE** -- the same law
    /// `wipeStateName()` already obeyeth one screen over.*
    public func sosStateNames() -> String {
        // (a) A LIVE call is read from the row, right now, through the node's own projection. **A READ PATH MUST
        // NOT WRITE**: the register is written by the COMMANDS (`recordSosAfterCommand`), never by this getter.
        if let active = harness.activeSos(author) {
            let words = active.state.stateWords ?? "unknown:" + active.state.stateToken
            return "active: " + words
        }
        // (b) Otherwise the durable register carries what the last command left -- including a CANCELLED call, which
        // is not "active" but IS the durable fact a relaunch must render.
        guard let register = Self.sosRegister(), let state = register.state else { return "no active call" }
        return (state.isTerminal ? "terminal: " : "active: ")
            + (state.stateWords ?? "unknown:" + state.stateToken)
    }

    /// *** THE DURABLE DELIVERY ROW'S OWN STATE, AS THE STORE HOLDETH IT -- the witness a rendered string is not. ***
    ///
    /// *A rendered state line is a CLAIM; the row is the SOURCE. This forwardeth to the composition's own read so an
    /// arm can assert the store rather than the label.*
    public func durableDeliveryState(author: String, msgId: Data) -> DeliveryState? {
        harness.durableDeliveryState(author: author, msgId: msgId)
    }

    /// The message id of the standing distress call, if any (nil when none is held).
    ///
    /// *A CANCEL needs an id, and the id must come from the DURABLE register rather than from a view's memory --
    /// otherwise a relaunch would cancel a message it can no longer name.*
    public func activeSosMsgId() -> Data? {
        if let active = harness.activeSos(author) { return active.msgId }
        return Self.sosRegister()?.msgId
    }

    /// *** ARM THE DISTRESS CALL, THROUGH THE NODE'S OWN COMMAND DOOR. ***
    public func armSos(payload: Data) -> String {
        guard let result = harness.sosCommand(author, .author(payload)) else {
            return "refused: no such node '\(author)'"
        }
        recordSosAfterCommand(result)
        return describeSos(result)
    }

    /// Cancel one distress call by its DURABLE msg_id: the node's own `.cancel` arm.
    public func cancelSos(msgId: Data) -> String {
        guard let result = harness.sosCommand(author, .cancel(msgId)) else {
            return "refused: no such node '\(author)'"
        }
        recordSosAfterCommand(result)
        return describeSos(result)
    }

    /// *** THE AUTHOR COUNTER: HOW MANY CALLS THIS LAB EVER AUTHORED -- AND IT IS NOT MOVED BY A CANCEL. ***
    ///
    /// *The card's discriminator for the cancel road: cancelling must stop a call, never un-author it.*
    public func sosAuthoredCount() -> Int { Self.sosRegister()?.authoredCount ?? 0 }

    /// Persist what the command left, READ FROM THE ROW rather than from the command's own return value.
    ///
    /// *The distinction matters: a CANCEL **RETIRES** the held frame, so `activeSos` answereth nil afterwards -- the
    /// register is therefore the only surviving witness of the terminal state, and it is written from the command's
    /// own typed result rather than from a row that no longer stands. **FOR AN ARM, THE ROW IS CONSULTED FIRST** (it
    /// is the live truth), and the command's result is the fallback.*
    private func recordSosAfterCommand(_ result: SosCommandResult) {
        let previous = Self.sosRegister()
        switch result {
        case .enqueued(let dispatch):
            switch dispatch {
            case .queuedDurably, .handedToRelays:
                // The ROW decides the token; the command's own taxonomy is the fallback where the row is silent.
                let state = liveSosState() ?? (dispatch == .queuedDurably ? .queuedDurably : .handedToRelay)
                let msgId = harness.activeSos(author)?.msgId ?? previous?.msgId
                Self.writeSosRegister(state: state, msgId: msgId,
                                      authoredCount: (previous?.authoredCount ?? 0) + 1)
            case .notPersisted, .unavailable, .failed:
                // NOTHING WAS AUTHORED: the counter must not move and the register must not claim a call.
                return
            }
        case .cancelled(let cancel):
            // A CANCEL NEVER INCREMENTETH THE AUTHOR COUNTER: it stopeth a call, it doth not create one.
            switch cancel {
            case .cancelled, .alreadyCancelled:
                Self.writeSosRegister(state: .cancelledLocally, msgId: previous?.msgId,
                                      authoredCount: previous?.authoredCount ?? 0)
            case .rejectedTerminal(let state):
                Self.writeSosRegister(state: state, msgId: previous?.msgId,
                                      authoredCount: previous?.authoredCount ?? 0)
            case .notBroadcast, .unknownMessage, .corrupt, .storageFailure, .invalidArgument:
                return
            }
        }
    }

    /// The live row's state for the standing call, when the node still carrieth it.
    private func liveSosState() -> DeliveryState? {
        guard let active = harness.activeSos(author) else { return nil }
        return active.state
    }

    private func describeSos(_ result: SosCommandResult) -> String {
        switch result {
        case .enqueued(let dispatch):
            switch dispatch {
            case .queuedDurably: return "armed:queued"
            case .handedToRelays(let n): return "armed:handed:\(n)"
            case .notPersisted: return "refused:not-persisted"
            case .unavailable(let reason): return "refused:" + reason
            case .failed(let reason): return "refused:" + reason
            }
        case .cancelled(let cancel):
            switch cancel {
            case .cancelled(let relayed): return "cancelled:relayed=\(relayed)"
            case .alreadyCancelled: return "cancelled:already"
            case .rejectedTerminal(let state): return "refused:terminal=\(state)"
            case .notBroadcast: return "refused:not-broadcast"
            case .unknownMessage: return "refused:unknown-message"
            case .corrupt: return "refused:corrupt"
            case .storageFailure: return "refused:storage-failure"
            case .invalidArgument: return "refused:invalid-argument"
            }
        }
    }

    // ---------------------------------------------------------------- the durable registers

    /// What the SOS register carrieth: the token read from the row, the row's msg_id, and the author counter.
    struct SosRegister: Codable, Equatable {
        let stateToken: String
        let msgId: Data?
        let authoredCount: Int

        var state: DeliveryState? { DeliveryState.allCasesByToken[stateToken] }
    }

    /// *** THE HOLDER-OWNED STABLE REGISTERS, UNDER APPLICATION SUPPORT -- THE SAME DISK ACROSS A RELAUNCH. ***
    ///
    /// *Application Support is the durable, holder-owned location the card asketh for, and the names are FIXED (no
    /// UUID): two processes resolve ONE path, which is the whole property a relaunch arm measureth.*
    static func sosRegisterURL() -> URL { labSupportDirectory().appendingPathComponent("sos-register.json") }

    static func durableStoreURL() -> URL { labSupportDirectory().appendingPathComponent("durable.sqlite") }

    private static func labSupportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("GodstoneLabMesh", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func sosRegister() -> SosRegister? {
        guard let bytes = try? Data(contentsOf: sosRegisterURL()) else { return nil }
        return try? JSONDecoder().decode(SosRegister.self, from: bytes)
    }

    static func writeSosRegister(state: DeliveryState, msgId: Data?, authoredCount: Int?) {
        let register = SosRegister(stateToken: state.stateToken, msgId: msgId,
                                   authoredCount: authoredCount ?? 0)
        guard let bytes = try? JSONEncoder().encode(register) else { return }
        try? bytes.write(to: sosRegisterURL(), options: .atomic)
    }

    /// A court that must start from a clean register (else it measureth a previous run's call).
    internal static func resetSosRegisterForTest() {
        try? FileManager.default.removeItem(at: sosRegisterURL())
    }

    /// *** GS-UX-001 `rendered-controls`: THE DURABLE SEND WITH A VIEW-GENERATED INTENT. ***
    ///
    /// *`sendDirectDurable` already standeth (round 521) and is the door a relaunch arm must travel: the intent is
    /// pinned in `outbound_intents` BEFORE the frame reacheth the radio, so a FRESH HANDLE over the same medium
    /// answereth `.found` for the id the view minted. This method is that door with the LAB'S OWN MEDIUM RESOLVED, so
    /// the view cannot accidentally name a different file on the next launch.*
    public func sendDirectDurableIntent(_ from: String, recipient: String, plaintext: Data,
                                        intentId: Data) async -> String {
        // The id is remembered BEFORE the send, so a crash or a relaunch can still name what was attempted.
        Self.recordLastIntent(intentId)
        return await sendDirectDurable(from, recipient: recipient, plaintext: plaintext,
                                       intentId: intentId, storeURL: Self.durableStoreURL())
    }

    /// *** DOES THE INTENT SURVIVE THE RUNTIME THAT AUTHORED IT? READ FROM A FRESH HANDLE OVER THE SAME MEDIUM. ***
    ///
    /// *Nothing of the authoring runtime is consulted. `.found` is the card's clause; `.notFound` is the arm's own
    /// discriminator (an id that was never authored must be ABSENT, or `.found` would mean nothing).*
    public func durableIntentVerdict(_ intentId: Data) -> String {
        let store = SqliteMessageStore(url: Self.durableStoreURL(), maxBytes: 64 * 1024 * 1024)
        let journal = SqliteOutboundIntentJournal(store: store)
        switch journal.load(intentId) {
        case .found(let entry):
            return "found:" + entry.logicalMessageId.map { String(format: "%02x", $0) }.joined()
        case .notFound: return "notFound"
        case .corrupt(let reason): return "corrupt:" + reason
        case .storageFailure(let reason): return "storageFailure:" + reason
        }
    }

    /// A fresh intent id for one rendered Send, minted where the VIEW can hand it to both the send and the reopen.
    public static func mintIntentId() -> Data { MessageId.generateNonce() }

    /// *** THE LAST INTENT, REMEMBERED SO A RELAUNCH CAN ASK THE SAME QUESTION. ***
    ///
    /// *Without this, the relaunch arm could not name the id it authored: a view's `@State` dieth with the process,
    /// and an arm that asked a DIFFERENT id would read `.notFound` for a send that succeeded. The record liveth under
    /// the same holder-owned directory as the durable store, so the id and the medium it names survive together.*
    public static func recordLastIntent(_ intentId: Data) {
        let hex = intentId.map { String(format: "%02x", $0) }.joined()
        try? Data(hex.utf8).write(to: lastIntentURL(), options: .atomic)
    }

    /// The hex of the last intent this lab authored, or nil when none was ever recorded.
    public static func lastIntentHex() -> String? {
        guard let bytes = try? Data(contentsOf: lastIntentURL()) else { return nil }
        let hex = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return hex.isEmpty ? nil : hex
    }

    /// The last intent's id, decoded back from the register.
    public static func lastIntentId() -> Data? {
        guard let hex = lastIntentHex() else { return nil }
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data.count == MessageId.messageNonceBytes ? data : nil
    }

    /// The rendered verdict for the LAST authored intent -- the readout a RELAUNCH arm reads.
    ///
    /// *Nothing of the authoring process is consulted: a fresh `SqliteMessageStore` over the same path answereth.*
    public func durableVerdictForLastIntent() -> String {
        guard let intentId = Self.lastIntentId() else { return "none recorded" }
        return durableIntentVerdict(intentId)
    }

    /// A court that must start from a clean register (else it measureth a previous run's intent).
    internal static func resetLastIntentForTest() {
        try? FileManager.default.removeItem(at: lastIntentURL())
    }

    private static func lastIntentURL() -> URL {
        labSupportDirectory().appendingPathComponent("last-intent.hex")
    }

    /// One bounded sync turn from `from` to `to`.
    @discardableResult public func turn(_ from: String, _ to: String) -> Int { harness.turn(from, to) }

    /// Carry `from`'s queued ACK traffic to `to`.
    @discardableResult public func turnAcks(_ from: String, _ to: String) -> Int { harness.turnAcks(from, to) }

    /// A trusted relation comes up (both layers).
    @discardableResult public func link(_ from: String, _ to: String) -> String { describe(harness.link(from, to)) }

    /// A trusted relation goes down.
    @discardableResult public func unlink(_ from: String, _ to: String) -> String { describe(harness.unlink(from, to)) }

    /// The exact bytes a link carried.
    public func capturedBytes() -> [Data] { harness.capturedBytes() }

    /// How many link hand-offs were admitted.
    public func admittedCount() -> Int { harness.link.admitted() }

    private func describe(_ outcome: ComposedOutcome) -> String {
        switch outcome {
        case .applied(let detail): return "applied:" + detail
        case .refused(let reason, _): return "refused:" + reason.rawValue
        }
    }

    // ================================================================================================
    // *** GS-UX-001: TRUST JOURNEY ACCESSORS REACHING THE REAL AUTHORITY FACADE ***
    // ================================================================================================

    /// The list of known contact labels for trust operations.
    public func trustContactLabels() -> [String] {
        trust.contactLabels()
    }

    /// The rendered hex fingerprint of a contact, or nil if unknown.
    public func trustFingerprint(for label: String) -> String? {
        trust.fingerprint(for: label)
    }

    /// Compare and confirm a fingerprint for a contact.
    public func compareAndConfirmFingerprint(for label: String, displayedFingerprint: String) -> String {
        trust.compareAndConfirm(label: label, displayedFingerprintHex: displayedFingerprint)
    }

    /// *** GS-UX-001 `rendered-controls`: THE COMPOSE BOUND, AND THE SAME NUMBER **WITNESSED** FROM THE VIEW. ***
    ///
    /// *The card chargeth that the bounded input be "UTF-8 bounded", and the rendered readout must say `N/max`. The
    /// number therefore cannot be a literal typed into a view: **A CONSTANT COPIED INTO A VIEW IS A CONSTANT THAT
    /// DRIFTS**, and the defect it would cause (a body the input ACCEPTED but the authority REFUSED) would look like a
    /// transport failure.*
    ///
    /// **SO THE BOUND IS MEASURED ONCE, THROUGH THE REAL AUTHORING PRIMITIVES, AND THE MEASUREMENT IS THE DEFINITION.**
    /// The probe walketh the exact chain `ComposedRuntimeHarness.authorFrame` walketh -- `SignedMessageV1.author`
    /// then `Router.buildSealedMessage` -- and measures the sealed payload's OVERHEAD (the difference between what it
    /// sealed and what it was handed), so the frame bound is derived rather than asserted. The result is the SMALLER
    /// of that derived bound and the frozen container's own body budget, because the lab may not author a body either
    /// primitive would refuse.
    public static let maxComposeBodyOctets: Int = measureMaxComposeBodyOctets()

    /// The measured cap, as a function so a court can re-run the probe (a `static let` cannot be re-asked).
    public static func measureMaxComposeBodyOctets() -> Int {
        // A body the container ACCEPTS, so the probe measures the frame overhead and not a rejection.
        let probeBody = Data(repeating: 0x41, count: SignedMessageV1.bodyMax)
        guard let sealed = try? sealProbeFrame(body: probeBody) else {
            // *** A PROBE THAT CANNOT RUN MUST NOT INVENT A BOUND. *** *The honest answer is the container's own
            // budget, which is the tighter of the two in every measured configuration -- so a probe failure degrades
            // to the FROZEN law rather than to a guess.*
            return SignedMessageV1.bodyMax
        }
        let overhead = sealed.count - probeBody.count
        return min(FrameV2.maxPayload - overhead, SignedMessageV1.bodyMax)
    }

    /// *** THE PROBE ITSELF: seal one body through the REAL chain and hand back the sealed PAYLOAD. ***
    ///
    /// *No fakes: a real `MeshIdentity` from the production keychain road, the real `Router` over a real store, the
    /// real frozen container. It liveth here (inside the module) rather than in a view because the primitives it
    /// walketh are internal -- and because a measurement belongs beside the bound it defines, not beside the control
    /// that renders it.*
    static func sealProbeFrame(body: Data) throws -> Data {
        let keychain = HarnessIdentityKeychain()
        keychain.storage[MeshIdentity.v1Tag] = try LocalIdentityStateV1(
            generation: 0,
            ed25519Seed: Data(repeating: 0x5A, count: 32),
            x25519PrivateKey: Data(repeating: 0x3C, count: 32)
        ).encode()
        let sender = try MeshIdentity.loadFromKeychain(keychain: keychain)
        let nonce = Data(repeating: 0x11, count: MessageId.messageNonceBytes)
        let createdAt: Int64 = 1_700_000_000
        let container = try SignedMessageV1.author(
            senderIdentityPriv: Data(repeating: 0x5A, count: 32),
            senderIdentityPub: sender.signingPublicKey,
            senderNodeId: sender.nodeId,
            recipientNodeId: sender.nodeId,
            messageNonce: nonce,
            createdAtEpochSeconds: createdAt,
            priority: .direct,
            timeQuality: .userConfirmed,
            bodyUtf8: body
        )
        guard let frame = try buildProbeSealedMessage(
            router: Router(selfNodeId: sender.nodeId, store: InMemoryMessageStore()),
            container: container,
            recipientNodeId: sender.nodeId,
            recipientStaticPub: sender.staticDhPublicKey,
            createdAt: createdAt,
            nonce: nonce
        ) else {
            throw ProbeTimeout()
        }
        return frame.payload
    }

    /// The probe's bounded wait expired: a typed refusal, so the caller degrades to the frozen container budget.
    struct ProbeTimeout: Error {}

    /// The sealed-payload measurement: `Router.buildSealedMessage` is `async` and the bound is a `static let`, so the
    /// frame is built through the SAME production entry point the durable road useth, awaited on a BOUNDED semaphore.
    ///
    /// *A `.direct` frame carrieth no proof-of-work (`Priority.requiresProofOfWork` is false for DIRECT, `Priority.swift:27`),
    /// so no miner can hold this wait open -- and the wait is bounded ANYWAY, because an unbounded wait inside a
    /// static initialiser would turn a scheduling surprise into a hung process rather than a degraded bound. The
    /// timeout returns nil, and the caller falls back to the frozen container budget.*
    private static func buildProbeSealedMessage(
        router: Router,
        container: Data,
        recipientNodeId: Data,
        recipientStaticPub: Data,
        createdAt: Int64,
        nonce: Data
    ) throws -> FrameV2? {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ProbeResultBox()
        Task {
            do {
                box.set(.success(try await router.buildSealedMessage(
                    plaintext: container,
                    recipientNodeId: recipientNodeId,
                    recipientStaticPub: recipientStaticPub,
                    identity: LogicalMessageIdentity(createdAtEpochSeconds: createdAt, messageNonce: nonce),
                    priority: .direct
                )))
            } catch {
                box.set(.failure(error))
            }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 10) == .success else { return nil }
        switch box.result {
        case .success(let frame): return frame
        case .failure(let error): throw error
        case nil: return nil
        }
    }

    /// *** THE PROBE'S ANSWER, HANDED ACROSS THE `Task` BOUNDARY UNDER A LOCK -- NOT A CAPTURED `var`. ***
    ///
    /// *A `var` captured by the `Task` closure would be a data race the compiler is right to refuse; the box maketh the
    /// hand-off explicit and the `DispatchSemaphore` below is what orders it.*
    private final class ProbeResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Result<FrameV2, Error>?

        var result: Result<FrameV2, Error>? {
            lock.lock(); defer { lock.unlock() }
            return stored
        }

        func set(_ value: Result<FrameV2, Error>) {
            lock.lock(); stored = value; lock.unlock()
        }
    }

    /// The longest PREFIX of `text` that fits the bound, cut on a CHARACTER boundary so a multibyte character is never
    /// split into invalid UTF-8. **IN OCTETS, NEVER `Character.count`**: an emoji is one character and four octets, so
    /// a character-counting bound accepts a body the authority refuses.
    public static func truncateToComposeBound(_ text: String) -> String {
        if text.utf8.count <= maxComposeBodyOctets { return text }
        var result = ""
        result.reserveCapacity(maxComposeBodyOctets)
        for character in text {
            let candidate = result + String(character)
            if candidate.utf8.count > maxComposeBodyOctets { break }
            result = candidate
        }
        return result
    }

    /// The rendered readout the view shows: `N/max octets`.
    public func composeOctetsReadout(_ text: String) -> String {
        String(text.utf8.count) + "/" + String(Self.maxComposeBodyOctets) + " octets"
    }

    /// *** GS-UX-001 `rendered-controls`: THE CANDIDATE THE VIEW DISPLAYED, AS A REF THE VIEW CAN HOLD. ***
    ///
    /// *The deleted `approveRotation(for label:)` took a LABEL and re-read the candidate inside the call, so what the
    /// screen showed was never the thing approved. The rendered journey is now TWO steps: capture here (the view
    /// stores the ref beside the displayed fingerprint), then hand THE SAME REF back below.*
    public func displayedRotationCandidate(for label: String) -> ExactRotationCandidateRef? {
        trust.displayedRotationCandidate(for: label)
    }

    /// Approve the EXACT candidate the view showed -- no label, no re-resolve, no refresh.
    public func approveDisplayedRotation(_ candidate: ExactRotationCandidateRef) -> String {
        trust.approveDisplayedRotation(candidate)
    }

    /// Revoke a contact and invalidate its sessions.
    public func revokeContact(for label: String) -> String {
        trust.revoke(label: label)
    }

    /// The human-readable trust status string for a contact.
    public func contactTrustLabel(_ label: String) -> String {
        trust.contactTrust(label: label)
    }

    /// Whether a contact is verified.
    public func isContactVerified(_ label: String) -> Bool {
        trust.isVerified(label: label)
    }

    /// Whether a contact is revoked.
    public func isContactRevoked(_ label: String) -> Bool {
        trust.isRevoked(label: label)
    }

    /// Whether a rotation candidate is pending for a contact.
    public func isRotationPending(_ label: String) -> Bool {
        trust.isRotationPending(label: label)
    }
}

public struct LabRuntimeError: Error, Equatable { public let reason: String }
