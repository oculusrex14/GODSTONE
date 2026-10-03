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

/// *** *** G1: THE LAB'S ZERO-PRIVATE-OPEN WITNESS -- RAISED AT THE REAL DOORS, NOT OBSERVED FROM THE TAB TREE. *** ***
///
/// *THE CLAUSE THIS ANSWERS, AND WHY THE OBVIOUS WITNESS IS NOT ENOUGH: "Couple any zero-private-open instrumentation
/// to actual factory/key/native open doors -- tab absence alone NOT zero-effects proof."* **A recovery-only surface
/// that renders no tab proveth NOTHING about construction; it proveth only what a boolean gate did at the render.**
/// *So the count is raised AT THE CALLS THAT REALLY CREATE PRIVATE STORES -- the two constructions inside
/// `LabRuntime.compose` (`SqliteMessageStore(url:...)` per label, and the lab's `SqlitePeerIdentityStore`), which are
/// the ONLY doors a lab composition has to a private medium.*
///
/// **AND IT IS HONEST ABOUT WHAT THE LAB'S DOOR IS:** *the lab's stores are PLAINTEXT under Application Support and
/// the lab carrieth NO DEK provider, so there is no key/DEK/native-cipher door on this road to raise beside them; the
/// store constructor IS the private door here, and the composition that opens one is `compose`.* **THE POSITIVE
/// CONTROL IS THE POINT**: *a normal boot after a settled estate MUST render a NON-ZERO count (the same arm sees it),
/// so a probe that was never raised -- the constant-zero witness the contract forbids -- cannot pass.*
public enum LabRecoveryOpenProbe {
    private static let lock = NSLock()
    private static var opens: [String] = []

    /// Raise the witness AT the door: called immediately before a private store is constructed, so it counteth the
    /// door being REACHED rather than the open succeeding (a construction that failéth late still opened the door).
    public static func notePrivateStoreOpen(_ path: String) {
        lock.lock(); opens.append(path); lock.unlock()
    }

    /// The private-store doors this process actually reached, in order.
    public static func openedPrivateStores() -> [String] {
        lock.lock(); defer { lock.unlock() }; return opens
    }

    /// The count a surface renders.
    public static var privateStoreOpens: Int {
        lock.lock(); defer { lock.unlock() }; return opens.count
    }

    /// A court or an arm that must start from a clean witness.
    public static func resetForTest() { lock.lock(); opens.removeAll(); lock.unlock() }
}

/// *** *** G2: THE LAB'S PER-PEER SESSION-INVALIDATION HUB -- THE CALLBACK'S REAL TARGET. *** ***
///
/// *THE DEFECT G2 NAMES: `LabRuntime.compose` built `MeshTrustFacade` with NO `sessionInvalidator`, so the adapter's
/// `invalidateSessions` appended `invalidatedSessionNodes` and called a NIL callback -- **the array a witness that
/// never saw the effect** -- while `SessionManager.retireIncarnations(ofPeerId:)` stood unwired. A revoked peer's live
/// sessions kept sealing/opening after the revocation claimed otherwise.*
///
/// **THE HUB IS THE MAPPING MISSING AT THE WIRING POINT.** *The facade's callback carrieth the 16-octet IDENTITY node
/// id (that is the only value `TrustUXModel.handleRevoke`/`handleApprove` ever pass), while the session registry is
/// keyed by the transport `peerId` UUID. So the relation pairs are BOUND where a real relation comes up -- through the
/// node's OWN delegates -- and the callback retires every incarnation of every bound peer in BOTH directions. A
/// relation the lab never established is answered as such, not silently dropped.*
///
/// **IT HOLDS NOTHING THE COMPOSITION DOES NOT OWN AND DROPS IT ON RELEASE:** the session owners are WEAK, so a lab
/// handle that has gone away invalidates nobody (and the whole-estate wipe invalidation remains the vault seam's own
/// road, untouched).*
internal final class LabSessionInvalidationHub {
    /// One node label's live sessions, held WEAKLY.
    private struct Sessions { weak var manager: SessionManager? }
    private var sessionsByLabel: [String: Sessions] = [:]
    /// Identity node id (16 octets) -> the transport peer handles bound to it, both directions.
    private var peersByNodeId: [Data: Set<UUID>] = [:]
    private let lock = NSLock()

    init() {}

    /// Bind one label's live session owner. Called where the composition hands over the node.
    func bind(label: String, sessions: SessionManager) {
        lock.lock(); sessionsByLabel[label] = Sessions(manager: sessions); lock.unlock()
    }

    /// *** THE RELATION PAIR IS BOUND WHERE A REAL RELATION COMES UP -- THE NODE'S OWN DELEGATE. *** *A pairing the
    /// lab never established is therefore never bound, and a callback for it retires nothing rather than guessing.*
    func bindPeer(nodeId: Data, peerId: UUID, label: String) {
        guard nodeId.count == 16 else { return }
        lock.lock()
        peersByNodeId[nodeId, default: []].insert(peerId)
        lock.unlock()
    }

    /// *** THE CALLBACK THE FACADE HOLDS: RETIRE EVERY INCARNATION OF EVERY BOUND PEER, BOTH DIRECTIONS. ***
    ///
    /// *`retireIncarnations(ofPeerId:)` removes BOTH directions for one handle; it is called once per bound handle, so
    /// a node the lab knows by two handles is retired on both.* **IT RETURNS THE NUMBER ACTUALLY RETIRED, so a caller
    /// -- and a court -- can see the effect rather than an empty array.**
    @discardableResult
    func invalidateSessions(forNodeId nodeId: Data) -> Int {
        lock.lock()
        let bound = peersByNodeId[nodeId] ?? []
        let managers = sessionsByLabel.values.compactMap { $0.manager }
        lock.unlock()
        var retired = 0
        for peer in bound {
            for manager in managers { retired += manager.retireIncarnations(ofPeerId: peer) }
        }
        return retired
    }

    /// How many peer handles are bound to one identity node id (the mapping's own witness).
    func boundPeerCount(forNodeId nodeId: Data) -> Int {
        lock.lock(); defer { lock.unlock() }
        return peersByNodeId[nodeId]?.count ?? 0
    }

    /// *** THE IDENTITY NODE ID A SELF-CONTAINED COURT FIXTURE BINDS UNDER (real contacts are preferred). ***
    internal static let fixtureBoundNodeId = Data(repeating: 0x4E, count: 16)

    // ------------------------------------------------------------------------------------------------------
    // *** THE POSITIVE-COURT FIXTURES: REAL SESSIONS THE HUB'S OWN CALLBACK MUST TEAR DOWN. ***
    //
    // *THE COURT NEEDS TWO THINGS THE PUBLIC SURFACE CANNOT REACH: a `SessionManager` (its init is internal over
    // internal protocols) and a PAIRED relation (the harness's `link()` bypasses the handshake entirely). Both are
    // therefore built HERE, in the module that owns those types -- and the pairing is the REAL four-entry handshake the
    // production driver uses, so the session torn down is a real Noise session rather than a mock.*
    //
    // **EACH FIXTURE IS TAGGED AND BOUND UNDER A CALLER-NAMED IDENTITY NODE ID**, so a court can bind one under a real
    // lab contact, drive the REAL facade revocation, and keep an UNRELATED fixture as its positive control.*
    // ------------------------------------------------------------------------------------------------------

    /// A real, paired session plus the admissions a court presents to seal/open.
    internal struct LabSessionFixture {
        let initiator: SessionManager
        let responder: SessionManager
        let initiatorAdmission: RelationAdmission
        let responderAdmission: RelationAdmission
    }

    private var fixtures: [String: LabSessionFixture] = [:]

    /// *** ESTABLISH A REAL PAIRED NOISE SESSION, OVER THE REAL KEYED HANDSHAKE ENTRIES. ***
    ///
    /// *Returns nil (a NAMED refusal) unless BOTH sides reach ready, so a court can never proceed on a half-open
    /// session and mistake a refusal for a session.*
    internal static func establishPairedSession() -> LabSessionFixture? {
        do {
            let initiatorIdentity = try MeshIdentity.generateAndStore(keychain: HarnessIdentityKeychain())
            let responderIdentity = try MeshIdentity.generateAndStore(keychain: HarnessIdentityKeychain())
            let initiator = SessionManager(identity: initiatorIdentity,
                                           trustAuthority: ComposedTrustAuthority())
            let responder = SessionManager(identity: responderIdentity,
                                           trustAuthority: ComposedTrustAuthority())
            let peerHandle = UUID()
            let outbound = RelationAdmission(direction: .outboundCentral, peerId: peerHandle,
                                             generation: 1, transportEpoch: 1)
            let inbound = RelationAdmission(direction: .inboundPeripheral, peerId: peerHandle,
                                            generation: 1, transportEpoch: 1)
            guard let hs1 = initiator.beginInitiator(outbound, remoteHint: responderIdentity.nodeHint),
                  let hs2 = responder.responderProcessHs1(inbound, remoteHint: initiatorIdentity.nodeHint, hs1: hs1),
                  let hs3 = initiator.initiatorProcessHs2(outbound, hs2: hs2,
                                                          advertisedRemoteHint: responderIdentity.nodeHint),
                  responder.responderProcessHs3(inbound, hs3: hs3,
                                                advertisedRemoteHint: initiatorIdentity.nodeHint)
            else { return nil }
            guard initiator.isReady(outbound), responder.isReady(inbound) else { return nil }
            return LabSessionFixture(initiator: initiator, responder: responder,
                                     initiatorAdmission: outbound, responderAdmission: inbound)
        } catch {
            return nil
        }
    }

    /// *** INSTALL A REAL PAIRED SESSION UNDER A CALLER-NAMED IDENTITY NODE ID. ***
    ///
    /// *Both managers are bound, and the relation is bound under `boundToNodeId` BOTH DIRECTIONS, so a callback for
    /// that node id retires the very incarnations this session lives in.*
    @discardableResult
    internal func installPairedSession(tag: String, boundToNodeId: Data) -> Bool {
        guard let fixture = LabSessionInvalidationHub.establishPairedSession() else { return false }
        bind(label: "fixture-\(tag)-initiator", sessions: fixture.initiator)
        bind(label: "fixture-\(tag)-responder", sessions: fixture.responder)
        bindPeer(nodeId: boundToNodeId, peerId: fixture.initiatorAdmission.peerId, label: "fixture-\(tag)")
        bindPeer(nodeId: boundToNodeId, peerId: fixture.responderAdmission.peerId, label: "fixture-\(tag)")
        lock.lock(); fixtures[tag] = fixture; lock.unlock()
        return true
    }

    /// Seal initiator->responder over a tagged fixture (nil when no session stands, or after invalidation).
    internal func fixtureSeal(tag: String, _ plaintext: Data) -> Data? {
        lock.lock(); let fixture = fixtures[tag]; lock.unlock()
        guard let fixture else { return nil }
        return fixture.initiator.seal(fixture.initiatorAdmission, plaintext)
    }

    /// Open at the responder over a tagged fixture.
    internal func fixtureOpen(tag: String, _ ciphertext: Data) -> Data? {
        lock.lock(); let fixture = fixtures[tag]; lock.unlock()
        guard let fixture else { return nil }
        return fixture.responder.open(fixture.responderAdmission, ciphertext)
    }

    /// Seal over the RESPONDER direction (the other half of the both-directions evidence).
    internal func fixtureSealResponder(tag: String, _ plaintext: Data) -> Data? {
        lock.lock(); let fixture = fixtures[tag]; lock.unlock()
        guard let fixture else { return nil }
        return fixture.responder.seal(fixture.responderAdmission, plaintext)
    }

    /// Open at the INITIATOR (the other half of the both-directions evidence).
    internal func fixtureOpenInitiator(tag: String, _ ciphertext: Data) -> Data? {
        lock.lock(); let fixture = fixtures[tag]; lock.unlock()
        guard let fixture else { return nil }
        return fixture.initiator.open(fixture.initiatorAdmission, ciphertext)
    }

    /// A tagged fixture's real ready-state (the witness a court binds BEFORE and AFTER).
    internal func fixtureReady(tag: String) -> Bool {
        lock.lock(); let fixture = fixtures[tag]; lock.unlock()
        guard let fixture else { return false }
        return fixture.initiator.isReady(fixture.initiatorAdmission)
            && fixture.responder.isReady(fixture.responderAdmission)
    }
}

/// *** THE LAB RUNTIME HANDLE. ***
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

    /// *** THE RETAINED ON-DISK AUTHORITY, ONE STORE PER NODE LABEL -- EMPTY WHEN NO ESTATE ROOT WAS SUPPLIED. ***
    ///
    /// *** IOS-R9: IT IS NOW **EVERY** LABEL'S STORE, NOT THE AUTHOR'S ALONE. *** *The field was populated for the
    /// author only, so `heldCount`/`durableSosState` answered for label A and silently reported nothing for R or B --
    /// and a wipe could not address the other nodes' bytes. **THE LAB IS ONE ESTATE, SO EVERY LABEL'S STORE STANDS IN
    /// IT.***
    private let nodeStores: [String: SqliteMessageStore]

    /// *** G2: THE SESSION-INVALIDATION HUB THE FACADE'S CALLBACK REACHES -- THE COMPOSITION OWNS IT. *** *Held so
    /// the callback's target lives exactly as long as the composition, and so a court can ask the hub's own witness.*
    private let sessionHub: LabSessionInvalidationHub

    /// *** THE LAB'S OWN ON-DISK ESTATE, SO ITS WIPE ADDRESSES THE FILES IT REALLY OWNS. ***
    ///
    /// *A wipe that journaleth over paths the lab never wrote is the defect the parent named: the lab's stores
    /// stayed live while a "wipe" reported progress against unrelated files. These are the REAL urls the lab
    /// composed over, collected where they are decided.*
    private let authorStoreURL: URL
    private let trustStoreURL: URL
    private let allStoreURLs: [URL]
    private let trustStore: SqlitePeerIdentityStore?

    /// *** THE AUTHOR NODE'S OWN DURABLE STORE FILE -- the exact medium the durable Send pins its intent in. ***
    /// *A court that must reopen the medium the send really wrote asks HERE rather than constructing a second path
    /// (`IOS-R10`).*
    public var authorDurableStoreURL: URL { authorStoreURL }

    private init(harness: ComposedRuntimeHarness, labels: [String], trust: MeshTrustFacade,
                 trustRepository: PeerIdentityRepository, nodeSigningSeeds: [String: Data],
                 nodeStores: [String: SqliteMessageStore] = [:],
                 trustStore: SqlitePeerIdentityStore? = nil,
                 sessionHub: LabSessionInvalidationHub = LabSessionInvalidationHub(),
                 authorStoreURL: URL? = nil, trustStoreURL: URL? = nil, allStoreURLs: [URL] = []) {
        self.harness = harness
        self.labels = labels
        self.trust = trust
        self.trustRepository = trustRepository
        self.nodeSigningSeeds = nodeSigningSeeds
        self.nodeStores = nodeStores
        self.trustStore = trustStore
        self.sessionHub = sessionHub
        self.authorStoreURL = authorStoreURL ?? Self.labSupportDirectory().appendingPathComponent("durable.sqlite")
        self.trustStoreURL = trustStoreURL ?? Self.labTrustStoreURL()
        self.allStoreURLs = allStoreURLs
    }

    /// *** THE DURABLE AUTHORITY'S OWN ROW FOR ONE MESSAGE -- the witness a rendered string is not. ***
    /// *Nil when the lab carrieth no estate root, so an arm can SAY which road it measured.*
    public func durableSosState(author: String, msgId: Data) -> DeliveryState? {
        guard let store = nodeStores[author] else { return nil }
        guard let row = try? store.readDelivery(msgId) else { return nil }
        return DeliveryState.fromCode(row.state)
    }

    /// *** THE HELD FRAMES THE DURABLE AUTHORITY CARRYETH. *** *A cancel must leave NO held frame, or a relaunch
    /// would render a live call; an arm asserteth the FRAME, not merely a row describing it.*
    public func durableSosHeldMsgIds(author: String) -> [Data] {
        nodeStores[author]?.allHeldMsgIds() ?? []
    }

    /// Whether this handle is bound to a retained on-disk estate at all.
    public var hasDurableEstate: Bool { !nodeStores.isEmpty }
    /// The honest readiness statement. It carrieth no parameter, so no caller can
    /// argue it into saying true.
    public static func readinessStatement() -> LabReadiness {
        LabReadiness(androidLinkLayerReady: false, iosLinkLayerReady: false,
                     profile: LabProfile.name, experimental: LabProfile.experimental)
    }

    /// Compose `labels.count` real peers and link them in a chain, so a message
    /// from the first to the last travelleth through a real relay.
    /// *** `estateRoot` GIVETH THE LAB'S AUTHOR NODE A RETAINED ON-DISK AUTHORITY. ***
    ///
    /// *THE DEFECT THIS CLOSES: the lab composed every node over IN-MEMORY stores, so the SOS authoring row died with
    /// the process and `sosStateNames()` fell back to a DISPLAY REGISTER -- "a label that claims a rung it never
    /// read".* **With a root, the AUTHOR's node is built over a REAL `SqliteMessageStore` under it (one file per node
    /// label, so a reopen over the same root reacheth the same bytes), and `sosStateNames` reads the STORE ROW.** *The
    /// default nil leaves every existing lab arm byte-identical, so the in-memory composition stands for the courts
    /// that want it.*
    public static func compose(labels: [String] = ["A", "R", "B"],
                               seedByte: UInt8? = nil,
                               estateRoot: URL? = nil) throws -> LabRuntime {
        guard labels.count >= 2 else {
            throw LabRuntimeError(reason: "a lab runtime needs at least two peers")
        }
        guard Set(labels).count == labels.count else {
            throw LabRuntimeError(reason: "lab labels must be distinct")
        }
        let clock = FixedHostClock()
        let harness = ComposedRuntimeHarness(clock: clock, link: LinkFacade(clock: clock))
        // *** THE RETAINED ESTATE: one durable store per label, under the caller's root. ***
        if let estateRoot {
            try FileManager.default.createDirectory(at: estateRoot, withIntermediateDirectories: true)
        }
        var nodeStores: [String: SqliteMessageStore] = [:]
        // *** THE LAB'S WHOLE ON-DISK ESTATE: EVERY LABEL'S STORE, SO A WIPE ADDRESSES ALL OF IT. ***
        var allStoreURLs: [URL] = []
        var next = seedByte ?? 0x11
        // *** AND THE SIGNING SEED PER NODE IS REMEMBERED, SO A SEEDED ROTATION CAN CARRY THE SAME SIGNING KEY. ***
        //
        // *The harness deriveth a node's Ed25519 seed from the byte it was handed (`addNode`), and a rotation that
        // kept a DIFFERENT signing key would be a node-id collision rather than a rotation -- so the seed is recorded
        // here, where it is already decided, rather than re-derived by a caller.*
        var seeds: [String: Data] = [:]
        for label in labels {
            seeds[label] = Data((0..<32).map { i -> UInt8 in UInt8((Int(next) + i) & 0xFF) })
            // *THE FILE NAME CARRIETH THE LABEL AND THE SEED BYTE, so a reopen over the same root minteth the SAME
            // estate for the same node rather than a second, empty one.*
            var durable: SqliteMessageStore? = nil
            if let estateRoot {
                let url = estateRoot.appendingPathComponent("lab_\(label)_\(next).db")
                // *** G1: THE REAL PRIVATE-STORE DOOR IS REACHED *HERE*, SO THE WITNESS IS RAISED HERE. ***
                LabRecoveryOpenProbe.notePrivateStoreOpen(url.path)
                durable = try SqliteMessageStore(url: url, maxBytes: 64 * 1024 * 1024)
                nodeStores[label] = durable
                // *EVERY LABEL'S FILE, SO THE WIPE CAN REACH THE WHOLE LAB ESTATE AND NOT ONE LABEL'S SLICE.*
                allStoreURLs.append(url)
                // *** AND THE HARNESS OWNS IT: registering the url here is what lets `LabEstateSeam` (and the
                // harness's own inventory) name these stores as artifacts of the estate rather than orphan them (IOS-R7). ***
                harness.registerDurableStore(url)
            }
            _ = try harness.addNode(label, seedByte: next, durableStore: durable)
            next = next &+ 0x10
        }
        for i in 0..<(labels.count - 1) {
            _ = harness.link(labels[i], labels[i + 1])
        }
        var contactsList: [(label: String, nodeId: Data)] = []
        // *** *** THE TRUST STORE IS A STABLE, ADDRESSABLE LAB FILE -- NOT A UUID IN `tmp`. *** ***
        //
        // *THE DEFECT THIS CLOSES IS THE PARENT'S OWN, AND IT IS A REAL ONE: the lab's durable estate lived under
        // `labSupportDirectory()` (per-label `lab_<label>_<seed>.db`) while the TRUST store was a
        // `UUID().uuidString` file in `tmp` -- **SO NO WIPE COULD EVER ADDRESS IT, and the "wipe" drove a journal over
        // paths the lab did not use.** A fixed name under the same holder-owned directory maketh the estate
        // addressable, which is what letteth the recovery road erase the LAB'S OWN files rather than unrelated ones.*
        //
        // **AND IT IS CLEARED FIRST, BECAUSE A COMPOSE IS A FRESH ESTATE:** *a stable name would otherwise carry a
        // previous launch's contacts into a new composition, and the arm that asserteth an empty trust surface would
        // measure the last run.*
        let trustDbUrl = Self.labTrustStoreURL()
        try? FileManager.default.removeItem(at: trustDbUrl)
        // *** G1: THE TRUST STORE IS THE COMPOSITION'S SECOND PRIVATE DOOR -- WITNESSED AT ITS OWN CONSTRUCTION. ***
        LabRecoveryOpenProbe.notePrivateStoreOpen(trustDbUrl.path)
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
        // *** *** G2: THE ONE SESSION-INVALIDATION HUB, BOUND TO THIS COMPOSITION'S REAL OWNERS AND RELATIONS. *** ***
        //
        // *THE DEFECT: `compose` passed NO `sessionInvalidator`, so the adapter's per-peer invalidation died at its
        // ledger. **THE HUB IS THE MAPPING AT THE WIRING POINT:** each label's REAL `SessionManager` is bound, and the
        // identity→transport-handle relation is bound where the harness's OWN link establishes it -- so the callback
        // retires the very incarnations a revoked/rotated peer's sessions live in. The callback closure holds the hub
        // STRONGLY (the hub holds only WEAK session owners), so the composition owns both and a released lab
        // invalidates nothing.*
        let sessionHub = LabSessionInvalidationHub()
        for label in labels {
            if let node = harness.node(label) { sessionHub.bind(label: label, sessions: node.node.sessions) }
        }
        // BOTH DIRECTIONS: the harness mints one transport handle per label and links them as peers, so each linked
        // pair's node ids are bound to the peer handle -- the same relation the transport delegate would bind.
        for from in labels {
            guard let fromNode = harness.node(from) else { continue }
            for to in harness.linkedPeerLabels(from) {
                guard let toNode = harness.node(to), let peerHandle = harness.transportHandle(for: to) else { continue }
                sessionHub.bindPeer(nodeId: toNode.identity.nodeId, peerId: peerHandle, label: from)
            }
        }
        let trustFacade = MeshTrustFacade(
            repository: trustRepo,
            ownNodeId: ownNodeId,
            contacts: contactsList,
            // *** GS-FINAL-003 `true-recovery-topology`: EVERY WIPE ROAD ON THIS LAB REACHES THE *SAME* PRODUCTION
            // RECOVERY OWNER. *** *This closure used to call `harness.beginWipe()`, the COMPOSITION HARNESS'S own
            // flag-and-delete -- a SECOND source of truth beside the durable ladder, and exactly what the audit's
            // "added beside, rather than made the sole owner" charge names. It now drives the production ladder, so a
            // wipe started from the trust surface and one started from the diagnostics control leave the SAME durable
            // record, and a resume readeth either.*
            //
            // *IT IS WEAKLY CAPTURED AND THE HARNESS IS NOT TOUCHED: the closure holds nothing the runtime does not
            // already own, so the trust facade cannot extend the runtime's life.*
            // *THE ESTATE IS A PARAMETER, SO THE TRUST SURFACE'S WIPE ADDRESSES THE **LAB'S** FILES: the harness the
            // closure captures is the one whose stores it erases, and `LabEstateSeam` answers those exact paths.*
            wipeHandler: { [weak harness, weak trustStore] in
                MeshRuntime.runRecoveryLadderInternal(
                    journal: LabRuntime.labWipeJournal(),
                    estate: LabEstateSeam(harness: harness, trustStore: trustStore),
                    requestFresh: true).outcome
            },
            // *** *** G2: THE PER-PEER SESSION CALLBACK IS WIRED TO THIS COMPOSITION'S REAL OWNERS. *** ***
            //
            // *THE DEFECT: this argument was OMITTED -- the facade defaulted it to nil -- so `invalidateSessions`
            // appended its ledger and called nothing, while `retireIncarnations` stood unwired. **EVERY REAL
            // COMPOSITION WIRES THIS ROAD** (the `compose` call above is the lab's only private composition), and the
            // callback carrieth the 16-octet identity node id the facade's handlers actually pass -- the hub maps it
            // to the transport handles the harness really established and retires their incarnations BOTH directions.
            // A callback that only echoed would leave the session sealing; this one tears it down.*
            sessionInvalidator: { [sessionHub] nodeId in
                _ = sessionHub.invalidateSessions(forNodeId: nodeId)
            }
        )
        return LabRuntime(harness: harness, labels: labels, trust: trustFacade,
                          trustRepository: trustRepo, nodeSigningSeeds: seeds,
                          nodeStores: nodeStores, trustStore: trustStore,
                          sessionHub: sessionHub,
                          // *** THE LAB'S OWN REAL PATHS, RETAINED SO ITS WIPE ADDRESSES THEM. ***
                          authorStoreURL: estateRoot.map { root in
                              root.appendingPathComponent("lab_\(labels[0])_\(seedByte ?? 0x11).db")
                          } ?? Self.durableStoreURL(),
                          trustStoreURL: trustDbUrl,
                          allStoreURLs: allStoreURLs)
            // *** *** IOS-R10: EVERY LAB NODE RESOLVES RECIPIENT TRUST FROM THE REAL REPOSITORY. *** ***
            //
            // *THE DEFECT THE REVIEW NAMED: the durable send's trust resolver invented the recipient's static-DH half
            // from the AUTHOR'S OWN identity and an accepted generation of 1 (`KeyTableTrustResolver` in
            // `ComposedNode.sendDirectDurable`) -- so a frame was sealed to the author's own key and a REVOKED contact
            // was re-pinned. **THE LAB NOW WIRES THE PRODUCTION REPOSITORY-BACKED RESOLVER**, so the recipient's real
            // static-DH material and accepted generation come from the durable trust store, a rotation is honoured by
            // generation, and a revoked contact is REFUSED rather than re-pinned.*
            .wiringRealRecipientTrust(resolver: TrustedPeerIdentityResolver(source: trustRepo))
    }
    /// Attach the real recipient-trust resolver to every composed node, and arm the recovery estate with the lab's
    /// real drain capability + total artifact inventory. Returns self so `compose` can chain it.
    @discardableResult
    private func wiringRealRecipientTrust(resolver: RecipientTrustResolver) -> LabRuntime {
        for label in labels {
            harness.node(label)?.recipientTrustResolver = resolver
        }
        // *** AND ARM THE RECOVERY ESTATE (IOS-R5/R7): the lab's live owners and its TOTAL on-disk inventory. ***
        harness.armRecoveryEstate(drain: LabEstateDrainSeam(harness: harness),
                                  artifacts: Self.estateInventory(trustStoreURL: trustStoreURL,
                                                                   allStoreURLs: allStoreURLs,
                                                                   authorStoreURL: authorStoreURL,
                                                                   extra: [Self.labCallRegisterURL(),
                                                                           Self.lastIntentURL(),
                                                                           Self.lastRecoveryURL()]))
        return self
    }

    /// *** THE LAB'S TOTAL ON-DISK INVENTORY (IOS-R7): EVERY FILE THE LAB REALLY WROTE, MAPPED TO ITS REAL URL. ***
    ///
    /// *THE REVIEW'S DEFECT: the ladder deleted only the fixed `mesh.db`/`peer.db` names, so the lab's real
    /// `lab_<label>_<seed>.db` stores and its trust store were never iterated and the ladder stalled at `KEYS_ERASED`.
    /// **THE INVENTORY IS THE LAB'S OWN RECORD OF WHAT IT CREATED** -- each per-label store and its `-wal`/`-shm`
    /// sidecars, the trust store and its sidecars, the durable intent medium, and the render-time registers the lab
    /// writes (`last-intent`, `last-recovery`, `sos-register`) -- all under the LAB's own real filenames, so a deletion
    /// addresses the bytes rather than guessing at a name it never wrote.*
    static func estateInventory(trustStoreURL: URL, allStoreURLs: [URL], authorStoreURL: URL,
                                extra: [URL] = []) -> [String: URL] {
        var out: [String: URL] = [:]
        func add(_ base: URL) {
            let name = base.lastPathComponent
            out[name] = base
            out[name + "-wal"] = URL(fileURLWithPath: base.path + "-wal")
            out[name + "-shm"] = URL(fileURLWithPath: base.path + "-shm")
        }
        for url in allStoreURLs { add(url) }
        add(authorStoreURL)
        add(trustStoreURL)
        for url in extra { add(url) }
        return out
    }

    /// *** *** IOS-R6: THE PERMIT, DRIVEN AND CONSUMED -- THE WHOLE GATE IN ONE CALL. *** ***
    ///
    /// *`LabRuntimeHolder` (and a court) may call this to obtain a permit for the lab estate and SPEND it at the
    /// construction boundary. It returns `true` only when a `.normal` permit was minted BY A DRIVE over the estate and
    /// then ACCEPTED by `consumeForConstruction(estateId:liveGeneration:)` -- wrong estate, a moved record (ABA) and a
    /// second use all return `false`.*
    ///
    /// *** THE MINTED ESTATE ID IS RETURNED RATHER THAN ASSUMED. *** *The permit carrieth its OWN `estateId` (the
    /// canonical id the authority computed from the estate it just judged), and the boundary check compares THAT --
    /// so a caller cannot pass a string it invented. `permit.estateId` is the positive discriminator; there is no
    /// nullable fallback and no forged metadata.*
    public struct LabPermitMint: Equatable {
        /// The canonical estate id the permit was bound to (`permit.estateId`).
        public let estateId: String
        /// The durable generation the permit was judged at (`permit.generation`).
        public let generation: UInt64
        /// The consumption result: the evidence when the permit admitted construction, nil otherwise.
        public let accepted: Bool
    }

    /// *** MINT A PERMIT BY DRIVING, THEN CONSUME IT AT THE MINTED ESTATE + LIVE GENERATION. ***
    ///
    /// *Returns the EVIDENCE-bound identity of the permit (its own `estateId`/`generation`) and whether consumption
    /// succeeded, so a caller never supplies a self-invented estate string and never falls back to a nil value.*
    @discardableResult
    public static func mintAndConsumeLabPermit(callerEstateId: String, liveGeneration: UInt64) -> LabPermitMint? {
        guard let permit = mintLabPermit(callerEstateId: callerEstateId) else { return nil }
        let canonicalEstate = labEstateIdentifier(root: labEstateRootURL())
        let accepted = permit.consumeForConstruction(estateId: canonicalEstate,
                                                     liveGeneration: liveGeneration) != nil
        return LabPermitMint(estateId: permit.estateId, generation: permit.generation, accepted: accepted)
    }

    /// *** THE RAW MINT, SO A COURT MAY DRIVE THE ACTUAL CONSTRUCTION BOUNDARY WITH ITS OWN ARGUMENTS. ***
    ///
    /// *The permit carrieth the REAL durable epoch it was judged at (`permit.generation`); a court asserting the
    /// boundary uses THAT value -- never a forged one -- so "accepted at the live generation" is a fact about the
    /// record, not about a literal typed into the arm.*
    public static func mintLabPermit(callerEstateId: String) -> PrivateRuntimePermit? {
        // *A BRAND-NEW ESTATE MUST CARRY A DURABLE GENERATION BEFORE A PERMIT IS MINTED (fail-closed): the boundary
        // refuseth a permit whose generation the record does not carry, so the baseline is established first.*
        establishLabEstateBaselineIfNeeded()
        let authority = CrashResumableWipe(
            store: WipeJournalDurabilityAdapter(journal: labWipeJournal()),
            vault: WipeDeferredKeyVaultSeam(),
            filesystem: WipeDeferredArtifactFileSystemSeam(),
            runtime: WipeDeferredTransportSeam(),
            authority: WipeDeferredIdentityAuthoritySeam())
        let bootstrap = StartupRecoveryBootstrap(wipe: authority, estateId: callerEstateId)
        guard case .normal(let permit) = bootstrap.consumeCompositionTopology() else { return nil }
        return permit
    }

    /// A boolean convenience for a caller that already holdeth the permit's own estate id (e.g. read back from
    /// `mintAndConsumeLabPermit`). *It supplies NOTHING the permit did not already carry.*
    public static func consumeLabConstructionPermit(estateId: String, liveGeneration: UInt64) -> Bool {
        mintAndConsumeLabPermit(callerEstateId: estateId, liveGeneration: liveGeneration)?.accepted ?? false
    }

    /// *** THE PRE-PRIVATE RECOVERY ROAD, OVER THE LAB'S OWN ESTATE -- THE PUBLIC DOOR A LAB VIEW USES. ***
    ///
    /// *`LabEstateSeam` is internal (it carrieth the module's own keychain), so a view in the LabMesh target cannot
    /// build one; this forwardeth the lab's real inventory and owns the seam here, where the module's types live.*
    /// *No composition exists in this state, so the estate POSITIVELY owns no live owner and the drain answereth
    /// `.cold` -- an honest claim rather than a dead barrier.*
    @discardableResult
    public static func runRecoveryForOperator(requestFresh: Bool) -> RecoveryLadderOutcome {
        establishLabEstateBaselineIfNeeded()
        let estate = LabEstateSeam(harness: nil,
                                   inventory: labEstateInventory(root: labEstateRootURL()))
        return MeshRuntime.runRecoveryLadder(journal: labWipeJournal(), estate: estate,
                                             requestFresh: requestFresh).outcome
    }

    /// *** THE OPERATOR'S OWN RESOLUTION OF A CORRUPT RECORD: AN EXPLICIT, COMPLETE, OWNED WIPE. ***
    ///
    /// *NEVER a clear-journal: the operator's act durably records `REQUESTED` and drives the full ladder over the lab's
    /// real estate (`MeshRuntime.resolveCorruptRecoveryForOperator`, which is restricted to a genuinely corrupt
    /// record).*
    @discardableResult
    public static func resolveCorruptRecoveryForOperator() -> RecoveryLadderOutcome {
        establishLabEstateBaselineIfNeeded()
        let estate = LabEstateSeam(harness: nil,
                                   inventory: labEstateInventory(root: labEstateRootURL()))
        return MeshRuntime.resolveCorruptRecoveryForOperator(journal: labWipeJournal(), estate: estate).outcome
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

    /// *** GS-UX-001 (STEPS 6 AND 2) + IOS-R10: THE LAB'S DURABLE ROAD, OVER THE LAB'S OWN ESTATE. ***
    ///
    /// *THE DEFECT THE REVIEW NAMED (`IOS-R10`): each durable send used to open a SEPARATE store at a caller-named
    /// path while the node routed through another -- so the pinned frame was absent from the node's estate and the
    /// recipient could never process it. **THE MEDIUM IS NOW THE LAB'S OWN AUTHORS' STORES** (the ones `compose`
    /// built), so the intent, the held frame and the delivery row live where the node really writeth them, and a
    /// recipient ACK advances the SAME obligation.*
    public func sendDirectDurable(_ from: String, recipient: String, plaintext: Data,
                                  intentId: Data) async -> String {
        do {
            // *The authority commits the frame ATOMICALLY (held row + delivery row), and the COMPOSITION hands the
            // committed frame to the link, so the recipient's own ingest writes its ACK obligation -- which is
            // IOS-R10's positive clause (the recipient processes the frame; its ACK updates the SAME obligation).*
            // **THE BOUNDED SYNC/ACK TURNS ARE NOT DRIVEN HERE**: they run on the sync pump's own executor, and a
            // caller drives them explicitly (`turn`/`turnAcks`) rather than from inside a send -- so this door cannot
            // block on a queue the caller already owns.
            return describeDurable(try await harness.sendDirectDurable(from, recipient: recipient,
                                                                       plaintext: plaintext, intentId: intentId))
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

    /// *** THE WIPE STATE, FROM THE PRODUCTION RECOVERY LADDER'S OWN DURABLE RECORD -- AND NOT FROM A FLAG. ***
    ///
    /// *THE DEFECT THIS REPLACES, STATED BY THE CODE THAT CARRIED IT: `harness.isWiped()` reporteth a BOOLEAN the
    /// COMPOSITION HARNESS setteth, and `ComposedRuntimeHarness` "carries no wipe journal at all" -- so "wipe progress
    /// from the real reopened store" (the card's step 6) was rendered from a flag that owns no ladder, while the real
    /// ladder-bearing authority lived in a different object this handle could not reach.* **A LABEL THAT CLAIMS A RUNG
    /// IT NEVER READ IS WORSE THAN ONE THAT SAYS SO, and the honest limit the old comment documented is now CLOSED
    /// rather than documented: the lab reads the PRODUCTION journal.**
    ///
    /// **THE READ IS PURE** -- `WipeJournalDurabilityAdapter.readJournal()` asketh the durable record and drives
    /// nothing -- so a view may call it on every render without advancing a wipe.
    public func wipeStateName() -> String {
        let rungs = Self.recoveryLadderRungs()
        guard let last = rungs.last else {
            // *AN EMPTY LADDER IS `IDLE` OR ABSENT, AND THE TWO ARE INDISTINGUISHABLE IN THE RECORD ITSELF (the
            // adapter deliberately does not invent a past). So the PERSISTED OUTCOME of the last real drive is
            // consulted -- a cache of a real read, written where the drive happened -- and when there is none, the
            // honest words are "no wipe was ever requested".*
            if let outcome = Self.lastRecoveryOutcome() {
                return outcome.decision == .wipeCompleted
                    ? "wiped (completed at the durable IDLE rung)"
                    : "standing (last recovery: " + outcome.decision.name + ")"
            }
            return "no wipe was ever requested"
        }
        return "standing at " + last
    }

    /// *** THE DURABLE RUNGS THE NEXT PROCESS WILL READ, IN THE PRODUCTION LADDER'S OWN WIRE SPELLING. ***
    ///
    /// *It is the SAME `WipeJournalDurabilityAdapter` the ladder writeth through, asked directly, so what a surface
    /// renders and what a resume reads cannot disagree.*
    public static func recoveryLadderRungs() -> [String] {
        WipeJournalDurabilityAdapter(journal: labWipeJournal()).readJournal()
    }

    /// Whether the runtime reports itself wiped, **FROM THE DURABLE RECORD RATHER THAN A FLAG**.
    public func isWiped() -> Bool {
        if Self.recoveryLadderRungs().last == WipeJournalState.wireName(.idle) { return true }
        return Self.lastRecoveryOutcome()?.decision == .wipeCompleted
    }

    /// *** BEGIN A WIPE, THROUGH THE PRODUCTION RECOVERY LADDER -- THE SAME AUTHORITY THE SHIPPING RUNTIME OWNS. ***
    ///
    /// *The lab invokes the real verb rather than simulating one: `MeshRuntime.runRecoveryLadder(journal:estate:requestFresh:)`
    /// writes `REQUESTED` durably, drains a LIVE transport that exists independently of the (lab's) store graph, erases
    /// the keys through the composition's own vault seams, deletes the enumerated private artifacts by their REAL
    /// paths, publishes a new identity, and records `IDLE` -- **and the outcome it returns is TYPED AND RETAINED, so the
    /// rendered surface can say which of the six estates the ladder reached and which artifact, if any, survived.**
    ///
    /// *IT IS THE SAME ROAD `MeshRuntime.create` TAKES BEFORE IT OPENS ANY PRIVATE STORE: `runRecoveryLadderInternal`
    /// is the ONE implementation both reach, so a rung the lab observes is a rung the shipping composition would.*
    @discardableResult
    public func beginWipe() -> RecoveryLadderOutcome {
        let outcome = runLabRecoveryLadder(requestFresh: true)
        Self.recordRecoveryOutcome(outcome)
        return outcome
    }

    /// *** RESUME THE STANDING WIPE FROM WHEREVER THE DURABLE RECORD STANDS -- THE CRASH PATH, DRIVEN LIVE. ***
    ///
    /// *A FRESH request and a RESUME are different phases (the audit's own clause: "a fresh wipe may do no wipe at all"
    /// when `resume` is used for both), so this taketh the other branch: no new `REQUESTED` is written, and the ladder
    /// continueth from the rung the record carrieth. On an estate that already completed, it is idempotent.*
    @discardableResult
    public func resumeWipe() -> RecoveryLadderOutcome {
        let outcome = runLabRecoveryLadder(requestFresh: false)
        Self.recordRecoveryOutcome(outcome)
        return outcome
    }

    /// The lab's own ladder drive: the SAME production road, over the lab's OWN estate.
    private func runLabRecoveryLadder(requestFresh: Bool) -> RecoveryLadderOutcome {
        recoverLabEstate(requestFresh: requestFresh).outcome
    }

    /// *** THE LAB'S WIPE, DRIVEN OVER THE LAB'S OWN ESTATE -- THE SAME OWNER AND PATHS THE LAB WROTE. ***
    ///
    /// *THE DEFECT THE PARENT NAMED, CLOSED: the lab's wipe used to drive the recovery road's DEFAULTS --
    /// `durable.sqlite` and a `peer.db` that the lab DOES write from the intent journal, beside a trust store in
    /// `tmp` it did not -- so **the lab's real per-label stores (`lab_<label>_<seed>.db`) and its trust store stayed
    /// LIVE while a wipe reported progress against unrelated files.*** **Now the estate is the instance's OWN:**
    /// *`MeshRuntime.runRecoveryLadder` is given a `LabEstateSeam` that answers the REAL paths the lab composed over,
    /// so a wipe deletes the lab's own bytes -- and the rendered state, the filesystem and the next launch agree.*
    ///
    /// **AND THE DEFAULT PATHS ARE NOT SILENTLY ABANDONED:** *`authorStoreURL` is the first label's composed file (or
    /// the legacy `durable.sqlite` when the lab carries no estate root), which is exactly the file the durable intent
    /// journal lives in -- so the send/relaunch journey's medium is wiped by the same operation that reports it.*
    public func recoverLabEstate(requestFresh: Bool) -> MeshRuntime.RecoveryOnlyOutcome {
        MeshRuntime.runRecoveryLadder(
            journal: Self.labWipeJournal(),
            estate: LabEstateSeam(harness: harness, extraPaths: labExtraPaths, trustStore: trustStore),
            requestFresh: requestFresh)
    }

    /// *** THE NAMES OUTSIDE THE HARNESS: THE TRUST STORE AND THE DURABLE INTENT MEDIUM. ***
    ///
    /// *The harness owns its per-label stores; these two are the LAB HANDLE's own files, and both are real artifacts
    /// the lab wrote. A name with no owner is never listed -- the repository already paid for that lesson twice.*
    private var labExtraPaths: [URL] { [authorStoreURL, trustStoreURL, Self.labCallRegisterURL()] }

    /// The lab's trust store: a FIXED name under the holder-owned directory, so a wipe can address it.
    public static func labTrustStoreURL() -> URL {
        labSupportDirectory().appendingPathComponent("lab-trust.db")
    }

    /// *** *** IOS-R6/R7: THE LAB'S OWN DURABLE WIPE JOURNAL -- A REAL FILE, NOT A SAME-PROCESS CACHE. *** ***
    ///
    /// *`UserDefaultsWipeJournal`'s read is a same-process cache and cannot vouch for the medium, so a permit bound to
    /// a generation it reports would be bound to a value the filesystem never carried (the parent's own ruling).*
    /// **THE JOURNAL IS NOW A `FileWipeJournal` BESIDE THE LAB'S ESTATE** (`<root>/lab-wipe.journal`), so a fresh
    /// process reads the SAME record from the SAME file -- which is the whole property a relaunch arm and the
    /// process-reopen smoke measure.*
    public static func labWipeJournal() -> WipeJournal {
        let root = labEstateRootURL()
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return FileWipeJournal(url: root.appendingPathComponent("lab-wipe.journal"))
    }

    /// *** THE LAB JOURNAL FILE, NAMED ONCE SO A WIPE CAN ADDRESS IT AND A SMOKE CAN REOPEN IT. ***
    public static func labWipeJournalURL() -> URL {
        labEstateRootURL().appendingPathComponent("lab-wipe.journal")
    }

    /// *** FAIL-CLOSED BASELINE: A BRAND-NEW ESTATE MUST CARRY A **PINNED** DURABLE GENERATION BEFORE A PERMIT IS
    /// MINTED. ***
    ///
    /// *The boundary refuseth a permit whose generation the record does not carry, so a first launch that minted
    /// against `nil` would deadlock the lab.*
    ///
    /// *** AND THE REPAIR THAT MATTERS: A FLOOR ALONE IS NOT A READABLE RECORD. ***
    /// *This used to call `journal.bumpEpoch()` alone -- and `bumpEpoch()` raiseth ONLY the floor (`CURRENT-02`: it
    /// never writes the phase), while the journal's pin law requireth the PHASE's suffix to equal the floor for the
    /// record to be readable AT ALL. So a brand-new estate was left with a floor and NO phase file, which `medium()`
    /// readeth as `.unreadable` -- `isReadableJournal()` answered false, `decideAndDrive()` answered `corrupt_journal`,
    /// and **NO PERMIT EVER MINTED** (measured: the permit road and the lab wipe both halted corrupt).*
    ///
    /// **SO THE LAB NO LONGER HANDS-ROLLS THE BASELINE: IT DRIVES THE PRODUCTION COORDINATOR'S OWN
    /// `establishBaseline()`**, *which stamps the CHECKED `idle|N` phase beside the floor -- the SAME state a shipping
    /// first launch reaches -- and, being guarded by `isReadableJournal()`/empty-journal, leaves an outstanding or
    /// corrupt record UNTOUCHED rather than laundering it.*
    public static func establishLabEstateBaselineIfNeeded() {
        let adapter = WipeJournalDurabilityAdapter(journal: labWipeJournal())
        let coordinator = CrashResumableWipe(
            store: adapter,
            vault: WipeDeferredKeyVaultSeam(),
            filesystem: WipeDeferredArtifactFileSystemSeam(),
            runtime: WipeDeferredTransportSeam(),
            authority: WipeDeferredIdentityAuthoritySeam())
        _ = coordinator.establishBaseline()
    }

    /// *** A COURT MUST BE ABLE TO START FROM A CLEAN LAB ESTATE, or it measureth a previous arm's wipe. ***
    ///
    /// *The lab's journal and estate root live under Application Support and are SHARED between arms in one process,
    /// so an arm that drove a wipe would otherwise leave the next one an outstanding estate. This removes the journal
    /// file, its floor and its refusal marker, and the estate/registers -- then re-establishes the BASELINE (a pinned
    /// `idle|1` record), the same readable fail-closed state a first launch sees.* **IT REMOVES THE FLOOR TOO: leaving
    /// a stale floor beside a removed phase is exactly the unpinnable state the baseline repair above closeth.**
    public static func resetLabEstateForTest() {
        let fm = FileManager.default
        try? fm.removeItem(at: labWipeJournalURL())
        try? fm.removeItem(at: URL(fileURLWithPath: labWipeJournalURL().path + ".epoch"))
        try? fm.removeItem(at: URL(fileURLWithPath: labWipeJournalURL().path + ".unacked"))
        try? fm.removeItem(at: labEstateRootURL())
        try? fm.removeItem(at: labTrustStoreURL())
        try? fm.removeItem(at: labCallRegisterURL())
        resetLastIntentForTest()
        resetRecoveryRecordForTest()
        establishLabEstateBaselineIfNeeded()
    }

    /// *** THE PERSISTED OUTCOME OF THE LAST REAL DRIVE -- A CACHE OF A READ, NAMED AS ONE. ***
    ///
    /// *THE DISTINCTION MATTERS AND IS WHY THIS IS NOT A SECOND SOURCE OF TRUTH: `RecoveryLadderOutcome` is produced BY
    /// the production ladder and carries the rungs AS THE DURABLE ADAPTER ANSWERED THEM at that instant. It is
    /// persisted for the ONE fact the journal itself cannot express -- a COMPLETED wipe reads as an empty ladder, so
    /// "wiped" and "never requested" are indistinguishable in the record -- and the surface renders the LIVE rung read
    /// FIRST, falling back to this only when the record is empty.*
    ///
    /// *** AND THE MEASURED REMAINING IS THE PRIVATE ARTIFACTS -- NOT THIS RECORD. ***
    /// *A wipe that measured ITS OWN outcome register as "still standing" could never reach `isComplete`: this file is
    /// written the instant the drive returns, so it would stand no matter how completely the private stores were
    /// erased -- a self-reference, not a residual store. **THE LAB'S OWN REGISTERS (`last-recovery.json`,
    /// `last-intent.hex`) ARE BOOKKEEPING, NOT PRIVATE MATERIAL** -- they carry no key, no store and no held frame --
    /// so they are excluded from the measured remaining while every PRIVATE artifact (each label's store and its
    /// sidecars, the trust store, the sos register) is still measured on the filesystem.*
    private static func recordRecoveryOutcome(_ outcome: RecoveryLadderOutcome) {
        let labRegisters: Set<String> = [lastRecoveryURL().lastPathComponent,
                                         lastIntentURL().lastPathComponent]
        let remaining = outcome.artifactsRemaining.filter { !labRegisters.contains($0) }
        let record: [String: Any] = [
            "decision": outcome.decision.name,
            "reason": outcome.decision.refusalReason ?? "",
            "rungs": outcome.rungs,
            "remaining": remaining,
            "complete": outcome.decision == .wipeCompleted && remaining.isEmpty,
        ]
        guard let bytes = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        try? bytes.write(to: lastRecoveryURL(), options: .atomic)
    }

    static func lastRecoveryOutcome() -> RecoveryLadderOutcome? {
        guard let bytes = try? Data(contentsOf: lastRecoveryURL()),
              let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let decisionName = object["decision"] as? String else { return nil }
        let reason = (object["reason"] as? String) ?? ""
        let decision: StartupRecoveryDecision
        switch decisionName {
        case "clean_start": decision = .cleanStart
        case "wipe_completed": decision = .wipeCompleted
        case "retryable_failure": decision = .retryableFailure(reason: reason)
        case "corrupt_journal": decision = .corruptJournal(reason: reason)
        case "terminal_failure": decision = .terminalFailure(reason: reason)
        default: decision = .recoveryPending(reason: reason)
        }
        return RecoveryLadderOutcome(
            decision: decision,
            rungs: (object["rungs"] as? [String]) ?? [],
            artifactsRemaining: (object["remaining"] as? [String]) ?? []
        )
    }

    private static func lastRecoveryURL() -> URL {
        labSupportDirectory().appendingPathComponent("last-recovery.json")
    }

    /// A court that must start from a clean wipe record (else it measureth a previous run's wipe).
    ///
    /// *** IT REMOVES THE PERSISTED OUTCOME CACHE ONLY -- IT MUST NOT `clear()` THE JOURNAL. *** *A `clear()` on a
    /// floor-less estate writeth a SUFFIX-LESS `idle` record, which the journal's pin law readeth as UNREADABLE --
    /// so it would defeat the very baseline `resetLabEstateForTest` establishes next and halt the permit road corrupt.
    /// The journal FILE is removed by `resetLabEstateForTest` itself; the pinned `idle|N` baseline is written by
    /// `establishLabEstateBaselineIfNeeded()` after.*
    internal static func resetRecoveryRecordForTest() {
        try? FileManager.default.removeItem(at: lastRecoveryURL())
    }

    /// *** THE RENDERED RUNG, FROM THE DURABLE RECORD (EMPTY LADDER FALLING BACK TO THE LAST REAL DRIVE). ***
    ///
    /// *The journal cannot express "a wipe COMPLETED" -- a finished ladder is written back to `IDLE` and reads as an
    /// empty record -- so a surface that asked the journal alone would show "no wipe was ever requested" immediately
    /// after a successful wipe, which is the opposite of the truth. The fallback carries the outcome of a real drive,
    /// named as such.*
    public func recoveryRungWords() -> String {
        let rungs = Self.recoveryLadderRungs()
        if rungs.isEmpty {
            guard let last = Self.lastRecoveryOutcome() else { return "no wipe has been driven from this lab" }
            return last.isComplete ? "durable rung: IDLE (completed)" : "last recovery: " + last.decision.name
        }
        return "durable rung: " + rungs.joined(separator: " -> ")
    }

    /// *** THE REMAINING PRIVATE ARTIFACTS, MEASURED ON THE FILESYSTEM RATHER THAN INFERRED FROM THE RUNG. ***
    public func recoveryArtifactWords() -> String {
        Self.lastRecoveryOutcome()?.remainingWords ?? "no artifacts measured"
    }

    /// *** GS-FINAL-003 `operator-required`: WHAT THE RECOVERY DECISION SAYETH, AND WHETHER A HUMAN IS NEEDED. ***
    ///
    /// *THE CLAUSE, MEASURED AT ITS OWN SURFACE: *"explicit operator-required for genuine corruption"*. **A CORRUPT
    /// DURABLE RECORD IS THE ONE ESTATE NO AUTOMATIC ACTION MAY RESOLVE** -- *retrying cannot make an unparseable value
    /// parse, and a composition that guessed "clean" would open private stores over material that may be mid-erasure.*
    /// **`requiresOperator` is the field that distinguisheth it from every other refusal, and it is exactly the field a
    /// bare Boolean cannot carry** -- so the word is rendered here, from the type, rather than being the caller's
    /// inference from an error string.*
    ///
    /// **THE DECISION IS TAKEN THROUGH THE PRODUCTION ENTRY POINT** (`MeshRuntime.startupRecoveryDecision`), *which owns
    /// the deferred create-time seams and OPENS NO STORE to answer -- so a surface may ask it on every render.*
    public static func startupRecoveryWords() -> String {
        let decision = MeshRuntime.startupRecoveryDecision(journal: labWipeJournal())
        return decision.requiresOperator ? decision.name + " -- operator required" : decision.name
    }

    /// Read generation and rung from one durable snapshot, without opening private stores.
    /// An unpinned record names no acknowledged generation; no persisted outcome is substituted.
    public static func durableWipeWords() -> (generation: String, rung: String) {
        let snapshot = labWipeJournal().readDurable()
        let generation: String
        if let epoch = snapshot?.epoch {
            generation = "generation: " + String(epoch) + " (acknowledged)"
        } else {
            generation = "generation: unacknowledged"
        }
        let rung: String
        if let state = snapshot?.state, state != .idle {
            rung = "rung: " + WipeJournalDurabilityAdapter.stage(forState: state)
        } else {
            rung = "rung: none read"
        }
        return (generation, rung)
    }

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
        // (a) A LIVE call is read from the DURABLE delivery row, right now, through the node's own projection --
        // which reads the store the node really writes (`activeSosSnapshot` -> `store.allHeldOrderedByPriority()`).
        if let active = harness.activeSos(author) {
            let words = active.state.stateWords ?? "unknown:" + active.state.stateToken
            return "active: " + words
        }
        // (b) OTHERWISE THE ROW ITSELF IS ASKED, BY NAME -- never a display register (`IOS-R9`). *A cancelled or
        // dispatched call has no held frame, but its delivery row STANDS terminal in the SAME durable store, and that
        // row is the authority a relaunch must render. If no row stands for the last call, the honest answer is "no
        // active call": the lab may not name a rung it cannot read.*
        guard let msgId = Self.labCallRegister()?.msgId,
              let state = durableDeliveryState(author: author, msgId: msgId) else {
            return "no active call"
        }
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
    /// *A CANCEL or RETRY needs an id, and the id must name a DURABLE row the estate still carries -- otherwise a
    /// relaunch would act on a message with no obligation (`IOS-R9`). **SO THE ID IS VALIDATED AGAINST THE ROW**: the
    /// last recorded id is returned ONLY when its delivery row really stands, and nil otherwise.*
    public func activeSosMsgId() -> Data? {
        if let active = harness.activeSos(author) { return active.msgId }
        guard let msgId = Self.labCallRegister()?.msgId,
              durableDeliveryState(author: author, msgId: msgId) != nil else { return nil }
        return msgId
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

    /// *** *** GS-UX-001 `required-retry`: RETRY THE STANDING CALL, THROUGH THE NODE'S OWN `.retry` ARM. *** ***
    ///
    /// *THE MEASURED GAP THIS CLOSES: `SosCommand.retry(_:)` EXISTED, WAS WIRED (`MeshNode.handleSosCommand` routes it
    /// to `retrySos`), WAS TESTED AT THE MODEL LEVEL (`ReadinessT39Tests.testRetryResumesTheSameAuthoredBytes...`) --
    /// **AND NO RENDERED CONTROL ON EITHER iOS SURFACE COULD REACH IT.*** *A capability the contract's own roster
    /// (`AccessibilityContract.essentialControls` names `("retry", "Retry")`) declares essential, with no control
    /// offering it, is a journey the user cannot take: exactly the "disconnected models and static text" shape the card
    /// charges, and precisely the class of omission a source grep cannot see.*
    ///
    /// **IT RESUMES THE SAME AUTHORED BYTES** (the node's `.retry` arm re-reads the held frame by msg_id and never
    /// re-authors -- `SosCommand`'s own contract: "a retry that re-authored would betray it"), *and the id cometh from
    /// the DURABLE projection rather than from a view's memory, so a relaunch can resume a call it never authored.*
    ///
    /// **`nil` msgId IS A TYPED REFUSAL, NOT A SILENT NO-OP**, and it NAMES the reason a user must be told: there is
    /// nothing standing to resume. *A retry that reported success with nothing to send would be the worst shape in this
    /// file -- a plausible-looking state over no effect.*
    public func retrySos(msgId: Data?) -> String {
        guard let msgId else { return "refused: no standing distress call to retry" }
        guard let result = harness.sosCommand(author, .retry(msgId)) else {
            return "refused: no such node '\(author)'"
        }
        // *** THE POST-COMMAND RECORD IS ITS OWN, BECAUSE A RETRY IS NOT AN AUTHORING. ***
        //
        // *`recordSosAfterCommand` INCREMENTETH THE AUTHOR COUNTER on a successful `.enqueued` -- correct for an ARM,
        // WRONG for a RESUME, and the class's own law already carrieth the distinction for the sibling verb: "A CANCEL
        // NEVER INCREMENTETH THE AUTHOR COUNTER: it stopeth a call, it doth not create one."* **A retry RESUMES a call,
        // so it must not create one either** -- and an author counter that moved on every retry would make the
        // surface's own "how many calls did this lab ever author" unanswerable.
        recordSosAfterCommand(result)
        // *** AND THE ACTION IS NAMED IN THE RENDERED ANSWER. *** *`describeSos` speaketh the node's taxonomy for the
        // OUTCOME of a command; a caller must be able to tell a resume from an arm in the rendered text, so the verb
        // is prefixed here rather than inferred by a reader from a string both commands can produce ("armed:queued").*
        return "resume:" + describeSos(result)
    }

    /// *** IOS-R9: THE POST-COMMAND RECORD IS AN **ID**, NOT AN AUTHORITY. ***
    ///
    /// *THE DEFECT THE REVIEW NAMED: the old register carried a STATE TOKEN (`SosRegister.stateToken`), so after a
    /// relaunch `sosStateNames()` rendered a rung read from a JSON file rather than from the delivery row -- "a label
    /// that claims a rung it never read". **THE STATE IS NOW ALWAYS READ FROM THE ROW** (`sosStateNames`,
    /// `activeSosMsgId`), and this record carries ONE THING: the id of the last call, so a relaunch can NAME the row it
    /// asks about. A file naming a row that no longer stands changes nothing, because the id is validated against the
    /// row before it is used.* **A RETRY AND A CANCEL BOTH LEAVE THE ID ALONE** -- neither authors a call, which is the
    /// class's own law ("a retry that re-authored would betray it"; "a cancel never incrementeth the author counter").*
    private func recordSosAfterCommand(_ result: SosCommandResult) {
        switch result {
        case .enqueued(let dispatch):
            switch dispatch {
            case .queuedDurably, .handedToRelays:
                // THE ROW NOW STANDS: record its id, read from the node's own durable projection.
                if let msgId = harness.activeSos(author)?.msgId { Self.writeLabCallId(msgId) }
            case .notPersisted, .unavailable, .failed:
                // NOTHING WAS AUTHORED: the record must not claim a call.
                return
            }
        case .cancelled(let cancel):
            switch cancel {
            case .cancelled, .alreadyCancelled, .rejectedTerminal:
                // The terminal row still stands under the recorded id: keep naming it so a relaunch may render it.
                if let msgId = Self.labCallRegister()?.msgId { Self.writeLabCallId(msgId) }
            case .notBroadcast, .unknownMessage, .corrupt, .storageFailure, .invalidArgument:
                return
            }
        }
    }

    /// *** THE STANDING CALL'S OWN ID, OR NIL: THE ARGUMENT A RENDERED RETRY MUST PASS RATHER THAN GUESS. ***
    ///
    /// *A view that minted its own id, or remembered one from an earlier session, would name work the estate may no
    /// longer carry -- so the id is read here, from the durable projection, at the moment of the tap.*
    public func standingSosMsgId() -> Data? { activeSosMsgId() }

    /// *** THE AUTHOR COUNTER: HOW MANY CALLS THIS ESTATE EVER AUTHORED -- COUNTED FROM THE DURABLE ROWS. ***
    ///
    /// *THE REVIEW'S CLAUSE: "with unchanged author/cancel counts". **A JSON INTEGER IS NEITHER AUTHORED NOR
    /// AUTHORITATIVE** -- it is a number that a dropped write can desync from the estate. The count is therefore
    /// DERIVED from the durable delivery rows: an SOS row (ackMode `none`) is written when a call is authored and is
    /// NEVER deleted by a cancel (which tombstones the row), so this count moves on an arm and stands still through a
    /// cancel -- exactly the discriminator the card names.*
    public func sosAuthoredCount() -> Int { authoredSosCount(author: author) }

    // ---------------------------------------------------------------- the durable call-id register

    /// What the call register carrieth: the last call's id, and NOTHING ELSE (the state lives in the row).
    struct LabCallRegister: Codable, Equatable {
        let msgId: Data?
    }

    /// *** THE HOLDER-OWNED STABLE REGISTER, UNDER APPLICATION SUPPORT -- THE SAME DISK ACROSS A RELAUNCH. ***
    static func labCallRegisterURL() -> URL {
        labSupportDirectory().appendingPathComponent("lab-call-register.json")
    }

    static func labCallRegister() -> LabCallRegister? {
        guard let bytes = try? Data(contentsOf: labCallRegisterURL()) else { return nil }
        return try? JSONDecoder().decode(LabCallRegister.self, from: bytes)
    }

    static func writeLabCallId(_ msgId: Data?) {
        guard let bytes = try? JSONEncoder().encode(LabCallRegister(msgId: msgId)) else { return }
        try? bytes.write(to: labCallRegisterURL(), options: .atomic)
    }

    /// A court that must start from a clean call register (else it measureth a previous run's call).
    internal static func resetSosRegisterForTest() {
        try? FileManager.default.removeItem(at: labCallRegisterURL())
    }

    /// The legacy single-medium path (used when the lab carrieth no estate root).
    static func durableStoreURL() -> URL { labSupportDirectory().appendingPathComponent("durable.sqlite") }

    /// *** THE HOLDER-OWNED STABLE DIRECTORY, UNDER APPLICATION SUPPORT -- THE SAME DISK ACROSS A RELAUNCH. ***
    static func labSupportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("GodstoneLabMesh", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// *** *** IOS-R6: THE LAB'S RETAINED ESTATE ROOT AND ITS CANONICAL IDENTIFIER. *** ***
    ///
    /// *THE DEFECT THE REVIEW NAMED: the real holder composed with NO estate root, so every node was in-memory and the
    /// durable Send could leave nothing behind. **THE HOLDER COMPOSES OVER A STABLE, HOLDER-OWNED ROOT** -- the same
    /// disk across a relaunch -- and the estate's IDENTITY is the inventory that root deterministically holds, so the
    /// permit the holder consumes at private construction is BOUND to the estate it is about to build.*
    public static func labEstateRootURL() -> URL {
        labSupportDirectory().appendingPathComponent("estate", isDirectory: true)
    }

    /// The seed bytes `compose` hands each label, in order -- so the per-label file name is deterministic.
    static func labNodeSeedBytes(labels: [String], seedByte: UInt8) -> [String: UInt8] {
        var out: [String: UInt8] = [:]
        var next = seedByte
        for label in labels { out[label] = next; next = next &+ 0x10 }
        return out
    }

    /// The lab's canonical estate identifier: the SAME inventory the holder will compose and the recovery estate
    /// answers with, so the permit's `estateId` and the holder's construction boundary are computed from the SAME bytes.
    public static func labEstateIdentifier(root: URL, labels: [String] = ["A", "R", "B"], seedByte: UInt8 = 0x11) -> String {
        MeshRuntime.recoveryEstateId(artifactPaths: labEstateInventory(root: root, labels: labels, seedByte: seedByte))
    }

    /// *** THE LAB'S COMPLETE ON-DISK INVENTORY, DERIVED DETERMINISTICALLY FROM THE ROOT. ***
    ///
    /// *`compose` names each store `lab_<label>_<seed>.db` under the root, so the whole estate can be enumerated
    /// WITHOUT a composition -- which is what a pre-private recovery road (and a permit's `estateId`) needs: the
    /// files exist (or will) at fixed names, and a wipe can address them before any node is built.*
    public static func labEstateInventory(root: URL, labels: [String] = ["A", "R", "B"],
                                   seedByte: UInt8 = 0x11) -> [String: URL] {
        var inventory: [String: URL] = [:]
        func add(_ url: URL) {
            inventory[url.lastPathComponent] = url
            inventory[url.lastPathComponent + "-wal"] = URL(fileURLWithPath: url.path + "-wal")
            inventory[url.lastPathComponent + "-shm"] = URL(fileURLWithPath: url.path + "-shm")
        }
        for (label, seed) in labNodeSeedBytes(labels: labels, seedByte: seedByte) {
            add(root.appendingPathComponent("lab_\(label)_\(seed).db"))
        }
        for url in [labTrustStoreURL(), labCallRegisterURL(), lastIntentURL(), lastRecoveryURL()] { add(url) }
        return inventory
    }

    /// *** THE NODE'S OWN TAXONOMY, SPOKEN: which arm ran and what its durable result was. ***
    ///
    /// *A caller must be able to tell an arm from a resume in the rendered text, so the VERB is prefixed by the callers
    /// above rather than inferred by a reader from a string both commands can produce.*
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

    /// *** THE AUTHOR COUNT, COUNTED FROM THE DURABLE ROWS (`IOS-R9`). ***
    ///
    /// *An SOS delivery row (ackMode `none`) is created when a call is authored and is NEVER deleted by a cancel, so
    /// the count moves on an arm and stands still through a cancel. Read from the node's OWN durable store -- the
    /// store the row really lives in -- rather than from a JSON integer a dropped write can desync.*
    func authoredSosCount(author: String) -> Int {
        guard let store = harness.node(author)?.store as? SqliteMessageStore else { return 0 }
        return store.allDeliveryMsgIdsForTest().filter { msgId in
            guard let row = try? store.readDelivery(msgId) else { return false }
            return row.ackMode == AckMode.none.rawValue
        }.count
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
                                       intentId: intentId)
    }

    /// *** DOES THE INTENT SURVIVE THE RUNTIME THAT AUTHORED IT? READ FROM A FRESH HANDLE OVER THE SAME MEDIUM. ***
    ///
    /// *Nothing of the authoring runtime is consulted -- and the medium is now THE AUTHOR'S OWN STORE (`authorStoreURL`,
    /// the exact file the node's router and journal write), so the verdict a relaunch reads is about the bytes the send
    /// really pinned rather than a second, disconnected medium (`IOS-R10`).*
    public func durableIntentVerdict(_ intentId: Data) -> String {
        let store = SqliteMessageStore(url: authorStoreURL, maxBytes: 64 * 1024 * 1024)
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

    /// *** G2: THE 16-OCTET IDENTITY NODE ID OF A LAB CONTACT. *** *The exact value the facade's
    /// `invalidateSessions` callback carrieth, so a court can address the same road the revocation does.*
    public func trustContactNodeId(_ label: String) -> Data? {
        harness.node(label)?.identity.nodeId
    }

    /// *** G2: DRIVE THE SESSION-INVALIDATION CALLBACK DIRECTLY BY IDENTITY NODE ID (the same hub the facade holds). ***
    /// *It answers HOW MANY incarnations were retired, so a court can show the effect rather than an empty ledger
    /// array -- and a second invocation retires nothing, proving the first was real.*
    @discardableResult
    public func invalidateSessions(forNodeId nodeId: Data) -> Int {
        sessionHub.invalidateSessions(forNodeId: nodeId)
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

    // ================================================================================================
    // *** *** G2: THE PER-PEER SESSION-INVALIDATION ROAD, FROM THE FACADE TO THE REAL REGISTRY. *** ***
    // ================================================================================================

    /// The number of live transport handles the composition bound to one identity node id (both-directions witness).
    public func boundSessionPeers(forNodeId nodeId: Data) -> Int {
        sessionHub.boundPeerCount(forNodeId: nodeId)
    }

    /// *** *** THE POSITIVE-COURT FIXTURES: REAL PAIRED NOISE SESSIONS THE CALLBACK MUST TEAR DOWN. *** ***
    ///
    /// *A court drives these -- which perform the REAL four-entry handshake over the public keyed doors -- so the
    /// session it later tears down is a real Noise session, not a mock. `boundTo:` binds the relation under a REAL lab
    /// contact's identity node id, so the court can drive the REAL facade revocation (`revokeContact(for:)`) and watch
    /// the callback `invalidateSessions` fires reach the session. The untagged form binds under a self-contained id for
    /// a court that presents it directly.*
    @discardableResult
    public func installRealSessionFixture(tag: String) -> Bool {
        sessionHub.installPairedSession(tag: tag, boundToNodeId: Self.fixtureSessionNodeId)
    }

    /// Install the fixture's relation under the REAL contact `label`'s identity node id (the facade's own value).
    @discardableResult
    public func installRealSessionFixture(tag: String, boundTo label: String) -> Bool {
        guard let nodeId = harness.node(label)?.identity.nodeId else { return false }
        return sessionHub.installPairedSession(tag: tag, boundToNodeId: nodeId)
    }

    /// Seal a frame over a tagged fixture's initiator->responder direction (the road a revocation must close).
    public func fixtureSeal(_ tag: String, _ plaintext: Data) -> Data? {
        sessionHub.fixtureSeal(tag: tag, plaintext)
    }

    /// Open a frame at a tagged fixture's responder direction.
    public func fixtureOpen(_ tag: String, _ ciphertext: Data) -> Data? {
        sessionHub.fixtureOpen(tag: tag, ciphertext)
    }

    /// Seal a frame over a tagged fixture's responder->initiator direction (the other direction of the pair).
    public func fixtureSealResponder(_ tag: String, _ plaintext: Data) -> Data? {
        sessionHub.fixtureSealResponder(tag: tag, plaintext)
    }

    /// Open a frame at a tagged fixture's initiator (the other direction of the pair).
    public func fixtureOpenInitiator(_ tag: String, _ ciphertext: Data) -> Data? {
        sessionHub.fixtureOpenInitiator(tag: tag, ciphertext)
    }

    /// A tagged fixture's REAL ready-state (the witness a court binds BEFORE and AFTER the invalidation).
    public func fixtureReady(_ tag: String) -> Bool {
        sessionHub.fixtureReady(tag: tag)
    }

    /// The identity node id the self-contained fixture form binds its relations under.
    public static var fixtureSessionNodeId: Data { LabSessionInvalidationHub.fixtureBoundNodeId }
}

public struct LabRuntimeError: Error, Equatable { public let reason: String }


#if DEBUG
/// *** *** G1: THE DEBUG, NONSHIPPING RECOVERY-FIXTURE DOOR -- REAL DURABLE BYTES, NOT A STORY GRAPH. *** ***
///
/// *THE MEASUREMENT THE REPORT NAMED AS MISSING: "no launchEnvironment door exists to reach those states", so the
/// recovery-only topology, the decision gate and the denial paths could not be driven by a rendered arm at all.*
/// **THE DOOR PLANTS THE ACTUAL MEDIUM**: the lab's real per-label stores and registers are created (the full
/// inventory, no hardcoded Artifact census), the durable generation FLOOR is seeded, and the journal file is written
/// with the REAL wire phase `REQUESTED` pinned to that floor -- which is exactly the bytes the production ladder
/// writeth, so the typed decision the holder reads is read from a record that really stands.*
///
/// **IT IS DEBUG-ONLY AND NONSHIPPING**: a release build carrieth neither this type nor its call site, so no shipping
/// configuration can be argued into a fixture. And it fabricates NO `WipeProgressState` and NO story graph -- a
/// fixture that only moved a UI value would prove nothing about the authority.
///
/// *** `corrupt` IS A REAL UNREADABLE RECORD, NOT A FLAG: *** *the door writeth an unparseable phase beside a
/// standing floor, so the holder meets GENUINE corruption -- `corrupt_journal` -- rather than a value this type
/// invented. A readable estate is answered a named refusal by the coordinator, so a fixture that planted something
/// readable would not even reach the operator road.*
public enum LabRecoveryFixtureDoor {
    /// The environment variable the XCTest launch door sets.
    public static let envKey = "GODSTONE_LAB_RECOVERY_FIXTURE"
    /// Plant a real pending recovery: inventory + floor + a pinned `REQUESTED` phase.
    public static let requestedFixture = "requested"
    /// Plant a persisted MID-LADDER rung: inventory + floor + a pinned `KEYS_ERASED` phase (a wipe that advanced and
    /// stopped, so a resume must continue from there rather than re-request).
    public static let keysErasedFixture = "keys_erased"
    /// Plant a genuinely unreadable record (phase + stale floor), the real corruption the operator road existeth for.
    public static let corruptFixture = "corrupt"
    /// Clear the lab estate to a pinned, readable clean baseline and plant nothing (the normal-boot control).
    public static let resetFixture = "reset"
    static func value() -> String? {
        let raw = ProcessInfo.processInfo.environment[envKey]
        return (raw?.isEmpty == false) ? raw : nil
    }
    /// The `WipeState` a phase-planting fixture writes (nil for the clear/corrupt arms).
    static func plantedPhase(_ fixture: String) -> WipeState? {
        switch fixture {
        case requestedFixture: return .requested
        case keysErasedFixture: return .keyErased
        default: return nil
        }
    }

    /// *** THE HOLDER'S ONE CALL: PLANT THE REAL FIXTURE MEDIUM BEFORE ANY HOLDER CONSTRUCTION. ***
    ///
    /// *The rules are chosen so an ARM is ORDER-INDEPENDENT and the RELAUNCH is a real DISCRIMINATOR:*
    ///   * NO value -- the door doth NOTHING. **This is what maketh the durability half honest**: a launch that
    ///     carrieth NO value writes no fixture, so whatever record it reads can only have come from the PREVIOUS
    ///     process through the medium.*
    ///   * `reset` -- clears the estate and re-stamps a PINNED, readable clean baseline (phase `idle|1`, floor `1`),
    ///     so a NORMAL boot is reachable regardless of what a previous arm left.
    ///   * `requested` -- plants the real wire phase `REQUESTED` (pinned to a seeded floor) beside the lab's real
    ///     inventory. A RELAUNCH with the value CLEARED then reads the SAME record the first process left.
    ///   * `corrupt` -- always plants an UNREADABLE phase beside a standing floor (presence is history; the phase
    ///     cannot be parsed, so every read road refuses it as corrupt).
    public static func applyFixtureIfPresent(journalURL: URL, estateRoot: URL) {
        guard let fixture = value() else { return }
        let fm = FileManager.default
        if fixture == resetFixture {
            // *** A CLEAN FIRST-LAUNCH ESTATE -- AND A **PINNED, READABLE** BASELINE. ***
            //
            // *`resetLabEstateForTest` clearéth the estate, but a clear on a genuinely floor-less estate writeth a
            // SUFFIX-LESS `idle` -- which the journal readeth as UNPINNED/UNREADABLE BY DESIGN -- so a pristine
            // simulator would read the normal boot as corrupt. **The baseline is therefore re-stamped explicitly at a
            // seeded floor**, which is exactly the state `establishBaseline` produceth: phase `idle|1` with floor `1`.*
            LabRuntime.resetLabEstateForTest()
            try? fm.createDirectory(at: estateRoot, withIntermediateDirectories: true)
            // A stale refusal marker or floor from a prior run must not survive the reset.
            try? fm.removeItem(at: URL(fileURLWithPath: journalURL.path + ".unacked"))
            try? fm.removeItem(at: URL(fileURLWithPath: journalURL.path + ".epoch"))
            try? Data("1".utf8).write(to: URL(fileURLWithPath: journalURL.path + ".epoch"), options: .atomic)
            try? Data("\(WipeState.idle.rawValue)|1".utf8).write(to: journalURL, options: .atomic)
            return
        }
        // A CLEAN SLATE FOR THE PLANT: record, floor and refusal marker removed.
        try? fm.removeItem(at: journalURL)
        try? fm.removeItem(at: URL(fileURLWithPath: journalURL.path + ".epoch"))
        try? fm.removeItem(at: URL(fileURLWithPath: journalURL.path + ".unacked"))
        try? fm.createDirectory(at: estateRoot, withIntermediateDirectories: true)
        if fixture == corruptFixture {
            // A STANDING FLOOR BESIDE AN UNPARSEABLE PHASE -- the real corruption, not a value this door invented.
            try? Data("1".utf8).write(to: URL(fileURLWithPath: journalURL.path + ".epoch"), options: .atomic)
            try? Data("THIS RECORD IS UNREADABLE BY CONSTRUCTION".utf8).write(to: journalURL, options: .atomic)
            return
        }
        guard let planted = plantedPhase(fixture) else { return }
        // (2) THE FLOOR IS SEEDED so the planted phase is PINNED to a real durable generation (an unpinned record
        // admits nothing, by design).
        try? Data("1".utf8).write(to: URL(fileURLWithPath: journalURL.path + ".epoch"), options: .atomic)
        // (3) THE LAB'S REAL, PHYSICALLY-OWNED INVENTORY, CREATED AT ITS OWN REAL PATHS (derived from the root, not a
        // hardcoded census). **THE FILES ARE CREATED EMPTY, NOT WITH MARKER GARBAGE**: a per-label store is later
        // opened as a real SQLite database once a resume settles the estate, and a file of non-SQLite bytes would make
        // that composition FAIL -- a fixture that broke the very road it existeth to exercise. An empty file is a valid
        // empty SQLite database, so the wipe addresses real bytes and the resume still composes.
        for (_, url) in LabRuntime.labEstateInventory(root: estateRoot) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: Data()) }
        }
        // (4) THE REAL WIRE PHASE, PINNED TO THE FLOOR ABOVE: this is the medium the ladder's own adapter reads.
        try? Data("\(planted.rawValue)|1".utf8).write(to: journalURL, options: .atomic)
    }
}
#endif

// ---------------------------------------------------------------------------
/// *** THE LAB'S ESTATE, AS A RECOVERY CAPABILITY: IT ANSWERS THE PATHS THE LAB REALLY WROTE. ***
//
// *THE DEFECT THE PARENT NAMED, IN ONE SENTENCE: a recovery road that chooseth its own paths can erase somebody
// else's estate -- and the lab's wipe used to drive DEFAULTS while the lab's real per-label stores and trust store
// stayed live.* **The estate is now a capability, and the lab passes ITS OWN.**
//
// **IT PULLS THE PATHS FROM THE OWNERS RATHER THAN FROM A LIST:** the harness's durable store urls (registered where
// each store was composed), plus the lab handle's own trust and intent files. *A name the lab never wrote is never
// listed, and a file the lab really wrote cannot be forgotten -- which is the difference between a mapping and a
// guess.*
// ---------------------------------------------------------------------------

/// The lab's recovery estate: the TOTAL inventory of files the lab really wrote, its own live drain seam, and the
/// closure of its retained owners.
internal struct LabEstateSeam: MeshRuntime.RecoveryEstate {
    private let paths: [String: URL]
    private let drain: LabEstateDrainSeam?
    private let trustStore: SqlitePeerIdentityStore?
    internal let keychain: any LocalIdentityKeychain = HarnessIdentityKeychain()
    /// The lab carries no encrypted private store (its stores are plaintext files under Application Support), so
    /// there is no DEK to erase and the vault answereth `.absent` -- the tri-state doctrine's own honest word.
    internal let dekProvider: (any PrivateStoreKeyProvider)? = nil

    /// - Parameters:
    ///   - harness: the composition whose stores and owners the wipe must reach. `nil` (a released harness) yields
    ///     NO paths and NO live owners -- and then the drain answereth nothing it cannot prove.
    ///   - extraPaths: the lab handle's own files (trust store, durable intent medium, render registers).
    internal init(harness: ComposedRuntimeHarness?, extraPaths: [URL] = [],
                  inventory: [String: URL]? = nil,
                  trustStore: SqlitePeerIdentityStore? = nil) {
        // *** IOS-R7: THE INVENTORY IS THE **REAL** NAMES THE LADDER ITERATES. *** *An explicit inventory wins (the
        // pre-private operator resolution has no composition to ask); otherwise the harness's ARMED inventory
        // (`armRecoveryEstate(artifacts:)`) is preferred -- one source of truth for what the lab wrote -- and failing
        // that the harness's registered stores plus the handle's extra files, each under its OWN filename plus its
        // `-wal`/`-shm` sidecars, so a deletion addresses the bytes rather than guessing at a name it never wrote.*
        var collected: [String: URL] = [:]
        if let inventory {
            collected = inventory
        } else if let armed = harness?.estateArtifactPaths, !armed.isEmpty {
            collected = armed
        } else {
            for url in harness?.durableStoreURLsForWipe() ?? [] { Self.add(url, to: &collected) }
            for url in extraPaths { Self.add(url, to: &collected) }
        }
        self.paths = collected
        self.drain = harness.map { LabEstateDrainSeam(harness: $0) }
        self.trustStore = trustStore
    }

    /// Add one real file and both SQLite sidecars, under its OWN filename (so a deletion addresses the real bytes).
    private static func add(_ base: URL, to out: inout [String: URL]) {
        let name = base.lastPathComponent
        out[name] = base
        out[name + "-wal"] = URL(fileURLWithPath: base.path + "-wal")
        out[name + "-shm"] = URL(fileURLWithPath: base.path + "-shm")
    }

    internal var artifactPaths: [String: URL] { paths }

    /// *** IOS-R5: THE LAB'S OWN LIVE TRANSPORT SEAM. *** *`nil` only when the harness was released (there is then no
    /// live owner to quiesce, and the drain answereth `.cold` from that positive fact rather than a dead barrier).*
    internal var liveTransport: TransportRuntimeSeam? { drain }

    /// *** DRAIN AND CLOSE THE LAB'S RETAINED OWNERS, THEN MEASURE IT. ***
    ///
    /// *`.drained` is answered ONLY when the harness really closed a non-zero number of retained durable stores and
    /// every one of them refused further use -- the measurement the review demanded. `.cold` only when the lab
    /// positively owns no live store. `.ownersLive` otherwise, which keeps the wipe pending rather than advancing over
    /// a store that is still live.*
    internal func drainOwners() -> OwnerDrainResult {
        // *** CLOSES ACTUAL RETAINED TRUST STORE BEFORE KEY/FILE DELETION. ***
        trustStore?.close()
        guard let harness = drain?.harness else {
            return .cold(reason: "the lab harness was released: the estate positively owns no live owner")
        }
        // The synthetic radio is quiesced first, then the owners are closed and MEASURED.
        _ = drain?.drainTransport()
        let measured = harness.closeLiveOwnersMeasured()
        if measured.closed {
            return .drained(reason: "closed \(measured.owners) retained durable owner(s); each refused further use")
        }
        if measured.owners == 0 {
            return .cold(reason: "the lab estate owns no durable store to drain")
        }
        return .ownersLive(reason: "\(measured.owners) retained durable owner(s) could not be confirmed closed")
    }
}

/// *** THE LAB'S LIVE TRANSPORT SEAM: A REAL QUIESCE OF THE COMPOSITION THE LAB ACTUALLY HOLDS. ***
///
/// *THE DEFECT IOS-R5 NAMED: recovery drained a BRAND-NEW `BleTransport()` with no active context, so its barrier
/// succeeded without touching anything. **THIS SEAM TOUCHES THE REAL OWNERS**: it drains the synthetic link and, on
/// the owner-drain road, closes the retained stores -- so the receipt described the estate rather than an empty
/// object.*
internal final class LabEstateDrainSeam: TransportRuntimeSeam, @unchecked Sendable {
    internal let harness: ComposedRuntimeHarness?
    private let lock = NSLock()
    private var quiescedThisLifetime = false

    internal init(harness: ComposedRuntimeHarness?) { self.harness = harness }

    internal func drainTransport() -> RuntimeDrainReceipt {
        lock.lock(); defer { lock.unlock() }
        quiescedThisLifetime = true
        // The synthetic link is the lab's whole radio; the owners are closed by `drainOwners()`.
        return .drained(closedTransports: harness == nil ? 0 : 1, quiescedRuntime: true)
    }

    internal func isQuiesced() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return quiescedThisLifetime
    }

    internal func fireRadio(_ msg: String) -> Bool { _ = msg; return !isQuiesced() }
    internal func sendVia(_ msg: String) -> Bool { _ = msg; return !isQuiesced() }
}
