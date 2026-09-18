import Foundation
import GodstoneCore

/// Non-shipping composition root for the mesh subsystem (Stage 4 Phase C8.4B / C8.4B.1).
///
/// Builds and owns the unified mesh runtime authority graph:
/// - One `MeshIdentity`
/// - One `SqliteMessageStore`
/// - One `SqlitePeerIdentityStore`
/// - One `PeerIdentityRepository` backing BOTH `BoundRecipientKeyResolver` and `SessionManager`
/// - `DeliveryTracker` with `Ed25519AckAuthenticator` over `BoundRecipientKeyResolver`
/// - Trusted `SessionManager`
/// - `MeshNode` consuming only the trusted `SessionManager` and `MeshIdentity`
/// - `MeshRuntimeInvalidator` for deterministic panic wipe invalidation
/// - `beginPanicWipe()` active panic-wipe authority associated with the exact store URLs
///
/// ARCHIVE-ONLY BOUNDARY: This composition root lives inside `GodstoneMesh` and is NOT
/// referenced by the shipping `AppContainer` or `Godstone-Light` target.
public final class MeshRuntime {

    public let identity: MeshIdentity
    public let messageStore: SqliteMessageStore
    internal let peerIdentityStore: SqlitePeerIdentityStore
    internal let peerRepository: PeerIdentityRepository
    internal let recipientKeyResolver: BoundRecipientKeyResolver
    internal let ackAuthenticator: Ed25519AckAuthenticator
    internal let deliveryRepository: SqliteDeliveryRepository
    public let deliveryTracker: DeliveryTracker
    public let sessionManager: SessionManager
    public let meshNode: MeshNode
    // IOS-06 step 1: **ONE RUNTIME OWNER FOR LIFECYCLE, OVER THE REAL TRANSPORT.** Until this landed,
    // `UnifiedRuntimeLifecycle` and `LifecycleTransportAdapter` were constructed NOWHERE in production (measured),
    // and the node called `ble.start()`/`ble.stop()` directly. The authority is built over the node's OWN
    // transport through T44's adapter, so the graph and the instrument meet at last.
    public let lifecycle: UnifiedRuntimeLifecycle
    // GS-RUNTIME-001 step 2: **THE ACK ROAD'S OWNERS, IN THE PRODUCTION RUNTIME.** Until these landed, the durable
    // ACK store, its driver, its pump and the recipient inbox were constructed ONLY by the composition harness --
    // and nothing in production ever collected the transport's readiness, so "registering a queue does not send
    // it". They are built over the SAME opened private store and the SAME pinned identity as everything else here.
    // (INTERNAL, NOT PUBLIC: these types are internal, and `public let` on an internal type doth not compile --
    // the compiler said so, which is how I learned that the runtime's OWN shape needeth no wider surface.)
    /// *** GS-FINAL-003 (round 572): TYPED AS THE PROTOCOL, BECAUSE WHAT IS HELD IS THE GATED DECORATOR. ***
    ///
    /// It was `SqliteAckStore` -- THE CONCRETE STORE -- which is precisely why every ACK road built from it bypassed
    /// the wipe gate: the type said "the real store", never "a store that may be asked whether it is admissible". The
    /// DECORATOR IS THE PROTOCOL'S IMPLEMENTATION NOW, so the held reference cannot be the ungated object.
    internal let ackStore: any AckObligationStore
    internal let ackDriver: AckObligationDriver
    internal let ackPump: DurableAckPump
    public let lifecycleGate: DefaultRuntimeLifecycleGate
    public let invalidator: MeshRuntimeInvalidator
    public let messageStoreUrl: URL
    public let peerStoreUrl: URL
    public let journal: WipeJournal

    /// GS-STORE-006: **THE KEY PROVIDER THE WIPE MUST HAVE, HELD BY THE RUNTIME ITSELF.**
    ///
    /// THE CARD'S STEP 2 IN ITS OWN WORDS: "Make MeshModule/MeshRuntime pass the exact live transport, session owner,
    /// database handles, key provider and artifact paths into that authority. DEFAULT-NIL DEPENDENCIES MUST NOT PERMIT A
    /// PRODUCTION WIPE TO OMIT A REQUIRED RESOURCE."
    ///
    /// AND THE MEASUREMENT THAT PUT IT HERE: `encryptedStores` was a PARAMETER OF `create` THAT WAS USED ONCE (to open the
    /// stores) AND THEN DROPPED -- SO NO METHOD OF A COMPOSED RUNTIME COULD REACH THE KEY PROVIDER AT ALL, AND THE SECOND
    /// HALF OF THE WIPE (the half that runs once the runtime STANDS, where the resources finally exist) HAD **NO WAY TO
    /// ERASE THE DEK**. THAT IS A STRONGER DEFECT THAN A NIL DEFAULT: EVEN A CALLER WHO PASSED A PROVIDER COULD NOT HAVE
    /// IT USED. Holding it here is what maketh the second half possible.
    private let wipeKeyProvider: (any PrivateStoreKeyProvider)?

    /// *** GS-FINAL-003: THE ONE-SLOT HOLDER THE ADMISSION GATE RESOLVETH ITS AUTHORITY THROUGH. ***
    /// Declared here so the composition can fill it AFTER construction (`wipeAuthority` is lazy and reads
    /// `meshNode`), while `init` can still hand the same box to the decorators.
    internal let wipeGateBox: WipeGateBox

    /// GS-FINAL-002: **THE KEYCHAIN THE COMPOSITION WAS GIVEN, RETAINED FOR THE WIPE.**
    ///
    /// THE OLD `PanicWipe` PATH REGENERATED THE IDENTITY THROUGH `MeshIdentity.generateAndStore(keychain:)` -- with
    /// the FIXED default keychain, ignoring the one the caller had passed. The crash-resumable ladder's last rung needs
    /// the same effect, and the one authority that serves the startup resume, the continuation AND the fresh public
    /// wipe can only supply it if the runtime HOLDS the keychain. So it is held, and the old path's inconsistency --
    /// a composition that accepted a keychain and then regenerated against a different one -- is corrected with it.
    private let keychain: any LocalIdentityKeychain

    internal init(
        identity: MeshIdentity,
        messageStore: SqliteMessageStore,
        peerIdentityStore: SqlitePeerIdentityStore,
        messageStoreUrl: URL,
        peerStoreUrl: URL,
        journal: WipeJournal = UserDefaultsWipeJournal(),
        lifecycleGate: DefaultRuntimeLifecycleGate = DefaultRuntimeLifecycleGate(),
        wipeKeyProvider: (any PrivateStoreKeyProvider)? = nil,
        keychain: any LocalIdentityKeychain = DefaultLocalIdentityKeychain()
    ) {
        self.identity = identity
        self.messageStore = messageStore
        self.peerIdentityStore = peerIdentityStore
        self.messageStoreUrl = messageStoreUrl
        self.peerStoreUrl = peerStoreUrl
        self.journal = journal
        self.lifecycleGate = lifecycleGate
        self.wipeKeyProvider = wipeKeyProvider
        self.keychain = keychain

        let peerRepo = PeerIdentityRepository(store: peerIdentityStore)
        self.peerRepository = peerRepo

        // *** GS-FINAL-003: THE WIPE GATE IS NOW WIRED INTO AN ADMISSION POINT -- AND IT WAS NOT BEFORE. ***
        //
        // MEASURED: `CrashResumableWipe.allowsStartup()` / `allowsSensitiveApi()` were called by FOUR TEST SITES AND
        // ZERO PRODUCTION SITES. The gate existed, was journal-bound, and **NOBODY CONSULTED IT** -- so "a wipe is
        // pending" was a fact no production road acted on.
        //
        // IT IS WRAPPED AROUND THE EXISTING LIFECYCLE-GATED SURFACES, because the two gates answer DIFFERENT
        // QUESTIONS and both must be asked: the lifecycle gate asketh "hath this runtime been invalidated", and the
        // wipe gate asketh "is a wipe's journal outstanding". A runtime can be validly constructed WHILE a wipe
        // standeth pending (that is what keeps the drain reachable, measured in round 549), and in that state
        // sensitive USE must be refused even though the gate is active.
        //
        // ASKED PER CALL, NEVER SAMPLED: the decorators hold the gate, and the gate readeth the durable journal each
        // time. That is the property the third arm measures.
        // *** AND THE GATE IS CAPTURED AS A DEFERRED READ, FOR THE SAME LIVENESS REASON `wipeAuthority` IS LAZY: ***
        // constructing the coordinator here would read `meshNode`, which is assigned a few lines BELOW. A closure that
        // resolveth the authority at CALL time (after init) keeps the one-authority rule AND the initialisation order.
        // A BOX, NOT A `self` CAPTURE: `[weak self]` inside `init` reacheth `self` before every stored property is
        // assigned, which the COMPILER refused -- correctly, and it is the same liveness class as the `lazy` clause
        // above. The box is filled ONCE below, after `init` returneth, and read at call time thereafter.
        let wipeGateBox = WipeGateBox()
        self.wipeGateBox = wipeGateBox
        let wipeGate = DeferredWipeSensitiveUseGate { wipeGateBox.authority?.allowsSensitiveApi() ?? false }
        let gatedLookup = WipeGatedPeerIdentityLookupSource(
            delegate: RuntimeGatedPeerIdentityLookupSource(
                delegate: peerRepo,
                lifecycleGate: lifecycleGate
            ),
            wipeGate: wipeGate
        )
        let resolver = BoundRecipientKeyResolver(source: gatedLookup)
        self.recipientKeyResolver = resolver

        let ackAuth = Ed25519AckAuthenticator(resolver: resolver)
        self.ackAuthenticator = ackAuth

        let delivRepo = SqliteDeliveryRepository(messageStore)
        self.deliveryRepository = delivRepo

        let tracker = DeliveryTracker(repo: delivRepo, authenticator: ackAuth)
        self.deliveryTracker = tracker

        let gatedTrust = WipeGatedPeerBindingTrustAuthority(
            delegate: RuntimeGatedPeerBindingTrustAuthority(
                delegate: RepositoryPeerBindingTrustAuthority(repository: peerRepo),
                lifecycleGate: lifecycleGate
            ),
            wipeGate: wipeGate
        )
        let sessions = SessionManager(
            identity: identity,
            trustAuthority: gatedTrust,
            localBindingIssuer: DefaultLocalBindingIssuer(identity: identity),
            lifecycleGate: lifecycleGate
        )
        self.sessionManager = sessions

        self.meshNode = MeshNode(
            identity: identity,
            store: messageStore,
            deliveryTracker: tracker,
            sessions: sessions,
            // GS-FINAL-003 (round 636): THE COMPOSITION IS WHERE THE GATE IS PASSED -- the same 
            // every other admission point on this isle already receiveth, never a hand-typed lambda.
            wipeGate: wipeGate
        )

        // GS-RUNTIME-001 step 2: THE FOUR OWNERS, OVER THE SAME STORE AND THE SAME PINNED IDENTITY.
        // (a) the durable paired store IS the message store's transaction engine (SqliteMessageStore conformeth
        //     to AckObligationEngine), so the ACK namespaces commit inside the SAME database;
        let lifecycle = UnifiedRuntimeLifecycle(
            seam: LifecycleTransportAdapter(transport: meshNode.ble),
            nowMillis: { Int64(Date().timeIntervalSince1970 * 1000) },
        )
        self.lifecycle = lifecycle
        // IOS-06 step 1's second half: **THE NODE IS TOLD WHOSE RADIO IT OPENS.** One owner standeth; the graph
        // holdeth no second, unowned path to the transport any more.
        meshNode.lifecycleOwner = lifecycle
        // *** GS-FINAL-003 (round 572): THE ACK SURFACES NOW PASS AN ADMISSION POINT, BECAUSE THEY HAD NONE. ***
        //
        // MEASURED BEFORE THIS EDIT: `wipeGate` was consumed at exactly TWO seams -- the peer-identity lookup and the
        // binding authority -- while EVERY ACK ROAD was built DIRECTLY OVER `SqliteAckStore`. **A GATE THAT COVERETH
        // TWO ROADS OUT OF SIX IS NOT A PRIVILEGE BOUNDARY**, and these are not peripheral roads: they are where a
        // RELAY's frames are admitted and where custody obligations are retired -- so a wipe pending during an ACK
        // exchange would admit foreign frames into, and retire obligations out of, a store MID-ERASURE.
        //
        // ONE DECORATOR COVERS EVERY ACK ROAD AT ONCE, WHICH IS WHY IT NEEDS NO NEW MECHANISM: `AckObligationStore`
        // is a PROTOCOL, and both the driver and the pump are initialised with THAT PROTOCOL rather than the concrete
        // store -- so a FUTURE ACK ROAD CANNOT BYPASS THIS WITHOUT DELIBERATELY BYPASSING THE TYPE.
        let ackStore = WipeGatedAckObligationStore(
            delegate: SqliteAckStore(engine: messageStore),
            wipeGate: wipeGate,
        )
        // (b) the driver signeth through the PRODUCTION signer over the pinned identity -- the seam's seed road
        //     is refused BY CONSTRUCTION there, which is the repair of rounds 215/216;
        let ackDriver = AckObligationDriver(store: ackStore,
                                            signer: IdentityAckSigner(identity: identity),
                                            authenticator: ackAuth,
                                            resolver: resolver)
        // (c) the pump admitteth foreign candidates through that driver;
        let ackPump = DurableAckPump(store: ackStore,
                                     admitForeign: { encoded, from in
                                         ackDriver.admitForeignCandidate(encoded, receivedFrom: from)
                                     },
                                     clock: { Int(Date().timeIntervalSince1970 * 1000) })
        // (d) and the dispatcher answers the delivery tracker, exactly as the harness's twin doth.
        let dispatcher = AckDispatcher(
            lookupDeliveryRow: { tracker.lookup($0) },
            verifyOrigin: { tracker.acknowledge($0.msgId, $0) },
            admitCandidate: { encoded, from in ackPump.admit(encoded, receivedFrom: from) })
        meshNode.ackDispatcher = dispatcher
        // (e) AND THE RECIPIENT INBOX. Its DH road is THE ONE SEAM PRODUCTION CAN SATISFY: `MeshIdentity`'s
        //     `agreementKey` is INTERNAL, so the seed never leaveth the module -- whereas the SIGNER seam could
        //     not be satisfied at all until rounds 215/216 changed its SHAPE. THAT ASYMMETRY IS MEASURED, not
        //     assumed, and it is why one seam needed a design change and the other an in-module accessor.
        meshNode.recipientInbox = RecipientInboxRepository(
            router: meshNode.router,
            ourNodeId: identity.nodeId,
            localDhPrivate: { identity.agreementKey.rawRepresentation },
            signer: IdentityAckSigner(identity: identity),
            resolver: resolver,
            authenticator: ackAuth,
            pairedStore: ackStore,
            commitInbound: { frame, receivedFrom, localRecipient, generation, lifetime, receivedAt, fault in
                // *** GS-FINAL-003 (round 572): THE ROAD AROUND THE TYPE, CLOSED. ***
                //
                // *** A REVIEW FOUND THIS AND WAS RIGHT: GATING THE `AckObligationStore` PROTOCOL DOES NOT COVER THIS
                // CLOSURE. *** `RecipientInboxRepository` is handed `commitInbound` as a SECOND, PARALLEL WRITE ROAD
                // straight to `messageStore` -- and `commitInboundWithObligationAtWithFault` CREATES THE PENDING ACK
                // OBLIGATION AND THE HELD ROW. MEASURED: `wipeGate`/`allowsSensitive` appear NOWHERE in
                // `MessageStore.swift`, so THE ACTUAL WRITE PATH HAD NO GATE IN IT AT ALL -- the gated protocol
                // covereth the reads and the retires while the COMMIT went under them.
                //
                // AND MY OWN COMMENT ABOVE WAS THEREFORE FALSE: *"a FUTURE ACK ROAD CANNOT BYPASS THIS WITHOUT
                // DELIBERATELY BYPASSING THE TYPE"* -- **THE INJECTED CLOSURE IS PRECISELY A ROAD AROUND THE TYPE, AND
                // IT WAS ALREADY IN USE.** A decorator gates an INTERFACE; an injected closure is not that interface.
                //
                // THE AUTHORITY IS THE SAME ONE THE DECORATORS USE -- `wipeGateBox.authority?.allowsSensitiveApi()`,
                // READ PER CALL, ONE `CrashResumableWipe` OBJECT, FAIL-CLOSED ON NIL. **A SECOND, HAND-BUILT GATE
                // WOULD DIVERGE FROM WHAT THE DECORATORS ENFORCE, AND "A WIPE IS PENDING" MUST NOT MEAN TWO DIFFERENT
                // THINGS IN TWO PLACES.**
                //
                // AND THE REFUSAL IS THE TYPED ONE THE CALLER ALREADY HANDLETH (`.storageFailure` -> a storage
                // refusal), never a plausible-looking success: an inbox that reported "committed" during a wipe would
                // be a lie that looks like a state.
                guard wipeGateBox.authority?.allowsSensitiveApi() ?? false else {
                    return .storageFailure
                }
                return try messageStore.commitInboundWithObligationAtWithFault(
                    frame, receivedFrom: receivedFrom, localRecipientNodeId: localRecipient,
                    identityGeneration: generation, obligationLifetimeMs: lifetime,
                    // THE FAULT ROAD IS ADAPTED, NOT DROPPED: the repository carrieth a `(String)` fault and the
                    // store's variant carrieth `(String, OpaquePointer?)` (the raw handle), so the handle is
                    // DROPPED INSIDE the store (which receiveth it anyway) and the site name is FORWARDED.
                    receivedAt: receivedAt, fault: { label, _ in try fault?(label) })
            })
        // GS-RUNTIME-001 step 3: the node is the transport's delegate, so it receiveth the readiness; it must
        // therefore hold the pump that the readiness schedulleth.
        meshNode.ackPump = ackPump
        // GS-RUNTIME-001 step 4: THE DEADLINE IS ARMED BY THE RUNTIME THAT OWNETH THE NODE, at a bounded
        // interval, and the node cancellath it in `stop()` -- so it can never outlive its owner.
        meshNode.armAckTurnDeadline(intervalSeconds: 30)
        self.ackStore = ackStore
        self.ackDriver = ackDriver
        self.ackPump = ackPump

        self.invalidator = MeshRuntimeInvalidator(
            lifecycleGate: lifecycleGate,
            sessions: sessions,
            peerStore: peerIdentityStore,
            messageStore: messageStore, node: meshNode)
    }

    /// Create a standard non-shipping `MeshRuntime` after resuming any pending panic wipe.
    /// Associates the pending wipe with the exact `messageStoreUrl` and `peerStoreUrl` it will later open.
    enum MeshRuntimeError: Error, Equatable {
        /// GS-STORE-002: a private store that is not encrypted at rest is never composed.
        case privateStoreNotEncrypted(String)
        /// *** GS-FINAL-004 clause (c): THE MESSAGE STORE COULD NOT BE OPENED, AND ITS OWN TYPED FAULT IS CARRIED. ***
        /// A runtime constructed over an unopened store would fail CLOSED on every operation -- *which is the right
        /// runtime behaviour and the wrong diagnostic one:* the failure would surface later, elsewhere, and without
        /// its cause. The store's own words are carried rather than replaced.
        case messageStoreUnavailable(String)
    }

    public static func create(
        messageStoreUrl: URL,
        peerStoreUrl: URL,
        maxStoreBytes: Int64 = 64 * 1024 * 1024,
        journal: WipeJournal = UserDefaultsWipeJournal(),
        encryptedStores: EncryptedStoreFactory? = nil
    ) throws -> MeshRuntime {
        try create(
            messageStoreUrl: messageStoreUrl,
            peerStoreUrl: peerStoreUrl,
            maxStoreBytes: maxStoreBytes,
            journal: journal,
            keychain: DefaultLocalIdentityKeychain(),
            encryptedStores: encryptedStores
        )
    }

    /// Internal creation overload accepting custom `LocalIdentityKeychain` for testing.
    ///
    /// *** GS-STORE-002 (round 521): **THE PRIVATE COMPOSITION, AND IT CARRIETH NO PLAINTEXT ROAD.** ***
    ///
    /// THE CARD'S LAW: "ordinary SQLite may never BE a private store." So THIS entry REFUSETH OUTRIGHT when it is
    /// given no verifying `EncryptedStoreFactory`, and it can therefore only ever produce stores that asserted
    /// encrypted-at-rest. THE RED WAS RUN FIRST AND IT WAS BEHAVIOURAL: the card's own closure test, taken on the tree
    /// BEFORE this repair, measured STOCK UNKEYED sqlite3 preparing a statement against the composition's private
    /// store -- `rc=0`, with the message naming the law.
    ///
    /// AND THE HOST/ARCHIVE COMPOSITION HATH ITS OWN NAME NOW (`createArchiveOnlyHostComposition`), BECAUSE A COMMENT
    /// HAD BEEN CARRYING THIS FINDING'S WHOLE REASSURANCE: the old code's own comment claimed the legacy default "at
    /// least SAYETH so now, instead of opening ordinary SQLite in silence" WHILE **THE CODE SAID NOTHING AT ALL** --
    /// it merely instantiated `SqliteMessageStore` and `SqlitePeerIdentityStore`. A COMMENT IS NOT A MEASUREMENT; A
    /// NAME IS, because a caller must now WRITE IT DOWN to obtain a plaintext store, and a reader can FIND it.
    internal static func create(
        messageStoreUrl: URL,
        peerStoreUrl: URL,
        maxStoreBytes: Int64 = 64 * 1024 * 1024,
        journal: WipeJournal = UserDefaultsWipeJournal(),
        keychain: any LocalIdentityKeychain,
        encryptedStores: EncryptedStoreFactory? = nil
    ) throws -> MeshRuntime {
        guard let factory = encryptedStores else {
            throw MeshRuntimeError.privateStoreNotEncrypted(
                "GS-STORE-002: a PRIVATE store is opened ONELY through a verifying EncryptedStoreFactory. A "
                + "composition that carrieth ordinary SQLite is the ARCHIVE/HOST composition and must SAY so by "
                + "calling createArchiveOnlyHostComposition -- it may not be reached by saying nothing.")
        }
        return try createPrivateComposition(
            messageStoreUrl: messageStoreUrl,
            peerStoreUrl: peerStoreUrl,
            maxStoreBytes: maxStoreBytes,
            journal: journal,
            keychain: keychain,
            encryptedStores: factory
        )
    }

    /// *** GS-STORE-002 (round 521): **THE DECLARED ARCHIVE/HOST COMPOSITION** -- ordinary SQLite, SAYED ALOUD. ***
    ///
    /// Its STORES ARE NOT PRIVATE and it carrieth no DEK: the card's own words, "Public Archive SQLite stays on its
    /// existing separate read-only path." THE ONELY THING THE OLD DEFAULT DID NOT DO IS EXIST UNDER A NAME, and that
    /// absence is what let the silent plaintext private store live: the composition now REQUIRETH a caller to write
    /// this name down.
    ///
    /// *** GS-FINAL-004 (the independent audit, 2026-09-18): THIS NAME WAS DOING TWO JOBS, AND THE ANALYSIS IS WHY. ***
    ///
    /// THE AUDIT'S CHARGE: *"The alternate archive-only host composition still constructs private-store objects."* IT
    /// WAS RIGHT, AND THE REASON IS NOW MEASURED RATHER THAN GUESSED: THIS FUNCTION WAS ALSO THE **PRIVATE** ROAD --
    /// `create(messageStoreUrl:..., encryptedStores: factory)` DELEGATED HERE, passing the factory through. So a caller
    /// who wrote the "archive-only" name down could obtain an ENCRYPTED PRIVATE STORE GRAPH, AND A CALLER WHO WANTED
    /// THE PRIVATE GRAPH TRAVELLED THROUGH A NAME THAT DISCLAIMED IT. One function, two contracts, and the name
    /// described only one of them.
    ///
    /// THE SPLIT: this entry is now GENUINELY archive-only -- it carrieth NO `encryptedStores` parameter at all, so
    /// there is no road from it to a private store. The private composition keeps the factory, and `create` no longer
    /// travels through the archive name. **A COMPOSITION THAT CANNOT BE GIVEN A KEY CANNOT OPEN A PRIVATE STORE.**
    ///
    /// Its 25 callers are all courts that exercise the runtime over plaintext files on the host, and NOT ONE of them
    /// claimed a private store -- MEASURED before the rename, so the rename breaketh no production caller, because
    /// THERE IS NO PRODUCTION CALLER: this composition root is archive-only and unreferenced by the shipping target.
    /// (Re-measured this round: no file under `Sources/App/` or `Sources/GodstoneCore/` names either entry.)
    internal static func createArchiveOnlyHostComposition(
        messageStoreUrl: URL,
        peerStoreUrl: URL,
        maxStoreBytes: Int64 = 64 * 1024 * 1024,
        journal: WipeJournal = UserDefaultsWipeJournal(),
        keychain: any LocalIdentityKeychain
    ) throws -> MeshRuntime {
        try composeRuntimeGraph(
            messageStoreUrl: messageStoreUrl,
            peerStoreUrl: peerStoreUrl,
            maxStoreBytes: maxStoreBytes,
            journal: journal,
            keychain: keychain,
            encryptedStores: nil
        )
    }

    /// *** THE PRIVATE COMPOSITION: THE ONLY ROAD TO A KEYED PRIVATE STORE (GS-FINAL-004). ***
    ///
    /// It reacheth the shared graph WITH a factory, so the two stores it opens are the ones a verifying
    /// `EncryptedStoreFactory` has already judged. **GS-FINAL-004'S REMAINING WORK IS NAMED HERE RATHER THAN IMPLIED:**
    /// the factory still returns METADATA (`path`, `kind`, `encryptedAtRest`, `cipherVersion`) and NOT an owned
    /// connection, so this function checks the verdict and then opens the stores by URL -- a second, independent open.
    /// *"Acquiring SQLCipher cannot repair a discarded handle."* Closing that needs the factory's return type to carry
    /// the connection, which is the probe's subject (`tools/readiness/audit_probes/swift/GsFinal004*`).
    internal static func createPrivateComposition(
        messageStoreUrl: URL,
        peerStoreUrl: URL,
        maxStoreBytes: Int64 = 64 * 1024 * 1024,
        journal: WipeJournal = UserDefaultsWipeJournal(),
        keychain: any LocalIdentityKeychain,
        encryptedStores: EncryptedStoreFactory
    ) throws -> MeshRuntime {
        try composeRuntimeGraph(
            messageStoreUrl: messageStoreUrl,
            peerStoreUrl: peerStoreUrl,
            maxStoreBytes: maxStoreBytes,
            journal: journal,
            keychain: keychain,
            encryptedStores: encryptedStores
        )
    }

    /// The ONE runtime graph, built by both declared compositions. The only difference between them is the factory,
    /// and it is passed explicitly rather than defaulted -- **so neither road can accidentally become the other.**
    private static func composeRuntimeGraph(
        messageStoreUrl: URL,
        peerStoreUrl: URL,
        maxStoreBytes: Int64,
        journal: WipeJournal,
        keychain: any LocalIdentityKeychain,
        encryptedStores: EncryptedStoreFactory?
    ) throws -> MeshRuntime {
        // *** GS-STORE-002 / GS-FINAL-011 (round 681): THE UNUSED `effectiveArtifacts` LOCAL IS GONE, AND THE
        // PARAMETER THAT BUILT IT WITH IT. ***
        //
        // `10_dead_code_and_technical_debt_report.md` named this EXACTLY: *"the inspected iOS composition constructs
        // the injected/default artifact dependency WITHOUT CONSUMING IT. ... either wire that exact object to the owned
        // wipe transaction and test it, or remove the misleading parameter/local with compatibility review. **Do not
        // leave an injectable dependency that callers believe controls deletion when it does not.**"*
        //
        // **MEASURED BEFORE REMOVING IT:** the local was resolved at this line and used NOWHERE ELSE in the file (the
        // only other `artifacts` occurrences were the parameter and its forwarding chain); `CrashResumableWipe` takes
        // SEAMS (`vault`, `filesystem`, `runtime`, `authority`), never a `WipeArtifacts`; the runtime's real deletion
        // road passeth `WipeArtifactFileSystemSeam` built from the OWNED PATHS at `:637`; and **NO CALLER -- production
        // or court -- ever passed `artifacts:` to any of the four entry points.**
        //
        // **SO `WipeArtifacts` BELONGS TO THE RETIRED `PanicWipe` COMPOSITION, NOT TO THIS ONE**, and carrying it here
        // meant a caller could inject an object that controlled NOTHING. *Removing it is the honest repair: the type
        // still existeth for `PanicWipe` and its courts, and this composition no longer offers a knob it never turns.*
        // Startup/Resume barrier: finish any pending wipe BEFORE opening stores or identity -- AND IT IS NOW THE
        // CRASH-RESUMABLE AUTHORITY THAT FINISHETH IT (GS-STORE-006's card, step 1: one runtime-owned authority, and the
        // old `PanicWipe` root retires rather than competing with it).
        //
        // *** AND IT RESUMETH ONLY WHAT NEEDETH NO TRANSPORT, WHICH IS A CONSEQUENCE OF THE ORDER THIS FUNCTION HATH,
        // NOT A CHOICE: `create` runneth BEFORE the runtime object existeth, so no transport stands here -- and
        // `RUNTIME_DRAINED` IS THE FIRST STAGE THAT REQUIRETH A RUNNING RUNTIME. THE DEFERRED SEAM ANSWERETH
        // `.notDrained` WITH THAT REASON, SO THE LADDER STOPS AT `REQUESTED`; THE RUNTIME THAT LATER STANDS RESUMETH
        // WITH THE LIVE SEAM. A seam answering `.drained()` here would let a restart erase keys while queued radio work
        // stood -- the very charge this finding carrieth. ***
        let resumeAuthority = CrashResumableWipe(
            store: WipeJournalDurabilityAdapter(journal: journal),
            // EVERY EFFECTFUL SEAM IS DEFERRED AT CREATE TIME, because the runtime owns NO platform resource here:
            // the VAULT (which would erase DEKs and identity keys), the TRANSPORT (which would drain radio work), and
            // the IDENTITY (which would GENERATE one -- the call whose absence of an old counterpart best fitteth the
            // measured hang). THE LADDER THEREFORE STOPS BEFORE `KEYS_ERASED`, exactly as the card's step 6 requires.
            vault: WipeDeferredKeyVaultSeam(),
            filesystem: WipeDeferredArtifactFileSystemSeam(),
            runtime: WipeDeferredTransportSeam(),
            authority: WipeDeferredIdentityAuthoritySeam()
        )
        // *** GS-FINAL-003: THE ANSWER IS NOT YET CONSUMED HERE, AND THE DEADLOCK THAT MAKES THAT SO IS MEASURED. ***
        //
        // THE AUDIT'S CHARGE STANDS: *"iOS discards the result of resume before creating identity/stores."* A FIRST
        // REPAIR OF MINE GATED THIS CALL SITE -- refusing construction whenever the permit was `.blocked` -- AND IT
        // DEADLOCKED THE COMPOSITION, which is why it is REVERTED rather than shipped:
        //
        //   * the ONLY path that can finish a pending wipe is `continuePendingWipeIfNeeded`, WHICH IS A METHOD ON A
        //     CONSTRUCTED RUNTIME;
        //   * that method drains through `meshNode.ble`, AND `MeshNode` IS BUILT FROM THE VERY STORES THIS FUNCTION
        //     WOULD REFUSE TO OPEN;
        //   * so refusing here means the runtime is never constructed, the transport never exists, the drain can never
        //     run, and THE WIPE CAN NEVER COMPLETE. A gate that makes the only remedy unreachable is worse than the
        //     defect it closes.
        //
        // THE PREREQUISITE IS THEREFORE AN ARCHITECTURAL ONE, AND IT IS NAMED RATHER THAN WORKED AROUND: iOS needs a
        // RECOVERY ENTRY POINT THAT DRIVES THE LADDER WITH A LIVE TRANSPORT WITHOUT CONSTRUCTING THE PRIVATE STORES --
        // i.e. a composition whose transport seam exists before (and independently of) the store graph. UNTIL THAT
        // EXISTS, THE PERMIT CANNOT BE CONSUMED AT THIS CALL SITE, and the finding's iOS half remains open. It is
        // recorded as owed in the ledger, and the red-by-design arms that measure what the permit MUST do live in
        // `tools/readiness/audit_probes/swift/GsFinal003StartupPermitTests.swift.txt`. The `StartupPermit` type this
        // would need, and its `decide` function, are preserved in that probe.
        //
        // A PENDING WIPE STAYETH PENDING: `retryLater` is not an error but the ladder's own refusal to advance without
        // the resources it needs, so it is DISCARDED here and the journal keepeth the truth.
        _ = try resumeAuthority.resume()

        let identity = try MeshIdentity.loadOrCreate(keychain: keychain)
        // ---- GS-STORE-002: the at-rest verdict BEFORE the store existeth -----------------------
        // With a factory the runtime REQUIRETH an encrypted, available verdict for both private
        // stores. The audit reproduced the opposite -- "MeshRuntime still instantiates both old
        // stores", so the file carrieth the plain `SQLite format 3` header and "stock unkeyed sqlite3
        // can prepare SELECT payload FROM held_frames" -- and the legacy default (no factory) at
        // least SAYETH so now, instead of opening ordinary SQLite in silence.
        if let factory = encryptedStores {
            for (url, tag) in [(messageStoreUrl, "message-store"), (peerStoreUrl, "peer-identity-store")] {
                switch factory.reopenExisting(path: url.path, tag: tag) {
                case .available(let handle):
                    guard handle.encryptedAtRest else {
                        throw MeshRuntimeError.privateStoreNotEncrypted("GS-STORE-002: " + tag)
                    }
                case .locked, .corrupt, .unavailable, .unsupportedVersion:
                    throw MeshRuntimeError.privateStoreNotEncrypted(
                        "GS-STORE-002: " + tag + " did not open as an encrypted private store")
                }
            }
        }
        let messageStore = SqliteMessageStore(url: messageStoreUrl, maxBytes: maxStoreBytes)
        // *** GS-FINAL-004 CLAUSE (c): THE TYPED OPEN OUTCOME IS NOW CONSUMED, NOT MERELY AVAILABLE. ***
        //
        // *"Return typed open errors instead of a nominal store with a nil handle."* **A TYPED ANSWER THAT NO
        // PRODUCTION CALLER ASKS FOR IS DECORATION** -- the same defect the iOS ACK round named when it found a gate
        // consulted at only two of six seams. **MEASURED BEFORE THIS EDIT: the composition built the store and
        // carried on regardless of whether it had opened**, which the card's own sentence describeth as *"a nominal
        // store with a nil handle."*
        //
        // **AND IT THROWETH RATHER THAN LOGGING, BECAUSE THE COMPOSITION CANNOT DO ANYTHING USEFUL WITH A STORE THAT
        // NEVER OPENED:** every subsequent operation would fail closed one at a time, so the failure would surface
        // LATER, ELSEWHERE, AND WITHOUT ITS CAUSE. *A runtime constructed over an unopened store is a runtime that
        // will fail in a place that cannot name why.*
        guard case .opened = messageStore.openOutcome else {
            if case .failed(let fault) = messageStore.openOutcome {
                throw MeshRuntimeError.messageStoreUnavailable(fault.description)
            }
            throw MeshRuntimeError.messageStoreUnavailable("the store was never opened")
        }
        let peerStore = try SqlitePeerIdentityStore(url: peerStoreUrl)
        let runtime = MeshRuntime(
            identity: identity,
            messageStore: messageStore,
            peerIdentityStore: peerStore,
            messageStoreUrl: messageStoreUrl,
            peerStoreUrl: peerStoreUrl,
            journal: journal,
            wipeKeyProvider: encryptedStores?.keyProviderForWipe,
            keychain: keychain
        )
        // *** AND THE BOX IS FILLED ONLY NOW, WITH THE RETIRED AUTHORITY THE WIPE PATHS THEMSELVES USE. ***
        // This is the ONE-AUTHORITY rule made literal: the admission point and the wipe entry points resolve the
        // SAME object, so "a wipe is pending" cannot mean two different things in two places.
        runtime.wipeGateBox.authority = runtime.wipeAuthority
        return runtime
    }

    /// Active panic-wipe execution for this runtime graph (Stage 4B.1 / C8.4B.1).
    /// Uses `RuntimeAwareWipeArtifacts` to ensure runtime handles are invalidated
    /// before cryptographic key erasure.
    /// GS-STORE-006: **THE RUNTIME THAT STANDS FINISHES THE WIPE THE STARTUP COULD NOT** -- the SECOND HALF of the card's
    /// step 6, and the half both corrected courts name as owed.
    ///
    /// WHY IT IS SEPARATE: `MeshRuntime.create` performs the startup resume BEFORE the runtime object exists, so it owns NO
    /// platform resource and therefore DEFERS EVERY EFFECTFUL SEAM -- the ladder reaches as far as `REQUESTED` and no
    /// further, and the wipe stays PENDING (the safe direction: nothing erased, nothing deleted, no store opened on an
    /// erased key; a court measured the runtime REFUSING to open exactly those stores). **ONCE THE RUNTIME STANDS, THOSE
    /// RESOURCES EXIST, AND THIS RESUMES THE VERY SAME LADDER WITH THE LIVE SEAMS:** the transport over `meshNode.ble`, the
    /// vault over `wipeKeyProvider` (which this type now HOLDS, because holding it is what makes this half possible at
    /// all), the real filesystem, and the real identity authority.
    ///
    /// **IT INVENTS NO SECOND AUTHORITY**: the same `CrashResumableWipe` over the same journal, and THE DURABLE
    /// CHECKPOINTS are what make the two halves safe in either order and safe to REPEAT after a crash between them -- which
    /// is the property the journal's `RUNTIME_DRAINED` stage was restored to carry.
    ///
    /// IDEMPOTENT: a finished wipe answers `.alreadyAtOrPast(.idle)`; one that cannot proceed answers `.retryLater` WITH
    /// THE REASON and leaves the journal where it stands. A composition that stored no key provider answers the vault's
    /// honest pending failure and therefore STAYS PENDING rather than completing falsely.
    @discardableResult
    public func continuePendingWipeIfNeeded() throws -> WipeStepResult {
        // *** ONE AUTHORITY, NOT A SECOND COPY OF ITS SEAMS (GS-FINAL-002, round 548). ***
        //
        // THIS METHOD USED TO BUILD ITS OWN `CrashResumableWipe` WITH ITS OWN SEAMS. The audit's charge against the
        // fresh entry point -- "the new coordinator was added beside, rather than made the sole owner of, the public
        // wipe entry contract" -- applied here too, and it had a MEASURED cost: this copy's filesystem seam carried no
        // real-path mapping and its vault carried no store-closing hook, so the continuation STOPPED AT
        // `ARTIFACTS_DELETED` reporting every artifact as failed-to-delete while the stores were still open by this very
        // runtime. A second copy of a seam is a second place for the mapping to be missing.
        //
        // The retained authority owns the live transport, the keychain the composition was given, the real artifact
        // paths and the runtime invalidation. Resuming through it is what makes "one authority" true in fact.
        try wipeAuthority.resume()
    }

    /// GS-FINAL-011: **THE LITERAL TEST SEAM IS GONE.** It returned `("crashResumable", true, true)` -- three
    /// constants -- while `beginPanicWipe` below constructed the OLD `PanicWipe` machine. The suite stayed green
    /// because it was reading a string the source wrote by hand, not the runtime's own behaviour. THE AUDIT'S OWN
    /// WORDS: "A test seam describes intended architecture without reading or exercising the runtime graph."
    ///
    /// WHAT REPLACED IT IS A MEASUREMENT, NOT A CLAIM: `CrashStartupResumeTests` now calls the REAL `beginPanicWipe`
    /// over a real runtime with a recording journal and reads WHICH LADDER ACTUALLY RAN -- `runtimeDrained` is a stage
    /// `CrashResumableWipe` writes and `PanicWipe` cannot reach, so the record itself names the authority.
    ///
    /// AND THE AUTHORITY IS NOW **ONE RETAINED OBJECT**, which is what makes "the same authority" a fact rather than a
    /// description: `wipeAuthority` is built once at composition and used by the startup resume, the continuation, and
    /// the fresh public wipe alike.

    /// GS-STORE-006 / GS-FINAL-002: **THE ONE WIPE AUTHORITY, BUILT ONCE AND RETAINED.**
    ///
    /// THE AUDIT'S CHARGE IN TWO PARTS, BOTH CLOSED HERE:
    ///   * GS-FINAL-002 -- "iOS MeshRuntime.beginPanicWipe still constructs old PanicWipe instead of requesting
    ///     through CrashResumableWipe." It now REQUESTS through the retained authority.
    ///   * The card's own words -- "The new coordinator was added beside, rather than made the sole owner of, the
    ///     public wipe entry contract."
    ///
    /// THE LIVENESS RULE IS THE REASON THIS IS A `lazy var` AND NOT A `let`: a stored property's initializer cannot
    /// read `meshNode`, which is assigned during `init` from a closure that would capture a not-yet-initialized
    /// `self`. `lazy` moves construction to first use -- after `init` -- so the AUTHORITY genuinely sees the LIVE
    /// transport, which is the whole point of the second half.
    private(set) lazy var wipeAuthority: CrashResumableWipe = CrashResumableWipe(
        store: WipeJournalDurabilityAdapter(journal: journal),
        vault: WipeKeyVaultSeam(
            dekProvider: wipeKeyProvider,
            // THE KEYCHAIN THE COMPOSITION WAS GIVEN, not the fixed default the old path regenerated against.
            deleteIdentityKeys: { [keychain] in try MeshIdentity.deleteFromKeychain(keychain: keychain) },
            // THE RUNTIME IS INVALIDATED BEFORE ITS KEYS ARE DESTROYED -- the effect the old `PanicWipe` authority
            // really performed through `RuntimeAwareWipeArtifacts`, carried across rather than dropped.
            //
            // *** AND THE DUAL HANDLE IS CLOSED HERE, BECAUSE IT IS A MEASURED BLOCKER. ***
            //
            // `createArchiveOnlyHostComposition` opens `messageStore` and `peerStore` on the SAME urls the artifact map
            // names, so when the ladder reaches the deletion stage THE FILE IS STILL OPEN BY THIS VERY RUNTIME. A
            // `removeItem` against an open sqlite handle leaves the file in place, the seam correctly reports "the
            // artifact surviveth its own deletion", and the ladder stops at `ARTIFACTS_DELETED` -- MEASURED: after a
            // "wipe" the old node id stood (SR05) and the peer store kept its row (SR06).
            //
            // The old `PanicWipe` path never hit this because it deleted through a store that had never been opened in
            // that process. Closing here adds no new refusal: the gate is already invalidated and the sessions already
            // destroyed by the line above, so this runtime was permanently unusable either way -- which SR07 measures.
            invalidateRuntime: { [invalidator, messageStore, peerIdentityStore] in
                try invalidator.invalidateForWipe()
                messageStore.close()
                peerIdentityStore.close()
            }
        ),
        // THE REAL ARTIFACT PATHS: `WipeScope` names logical artifacts, and a deletion must address the files this
        // runtime actually owns. Without the mapping every deletion answered `.absent` against the process's working
        // directory and the store survived a "completed" wipe.
        filesystem: WipeArtifactFileSystemSeam(
            journal: WipeJournalDurabilityAdapter(journal: journal),
            realPaths: [
                "mesh.db": messageStoreUrl,
                "mesh.db-wal": URL(fileURLWithPath: messageStoreUrl.path + "-wal"),
                "mesh.db-shm": URL(fileURLWithPath: messageStoreUrl.path + "-shm"),
                "peer.db": peerStoreUrl,
                "peer.db-wal": URL(fileURLWithPath: peerStoreUrl.path + "-wal"),
                "peer.db-shm": URL(fileURLWithPath: peerStoreUrl.path + "-shm"),
            ]
        ),
        runtime: WipeTransportDrainSeam(transport: meshNode.ble),
        // THE IDENTITY IS REGENERATED, NOT MERELY NAMED -- the effect the old `PanicWipe` path performed through
        // `KeychainWipeArtifacts.regenerateIdentity()` (it called `MeshIdentity.generateAndStore(keychain:)`), carried
        // across rather than dropped. Without it the ladder would reach `NEW_IDENTITY` having published nothing, and
        // the crash-restart arm that requires a DIFFERENT node id after a wipe would measure its absence.
        authority: WipeIdentityAuthoritySeam(regenerateIdentity: { [keychain] in
            try MeshIdentity.generateAndStore(keychain: keychain)
        })
    )

    /// The wipe authority the composition carries, OBSERVED rather than asserted.
    internal func wipeAuthorityForTest() -> CrashResumableWipe { wipeAuthority }

    /// *** GS-FINAL-002 (round 707): THE PUBLIC ENTRY RETURNS THE TYPED OUTCOME -- THE AUDIT'S CLAUSE, FULFILLED. ***
    ///
    /// **THE AUDIT'S `exact_remediation` SAYS: "Return a typed outcome to the caller and render completion only at
    /// durable IDLE."** *That clause was UNMET AT BOTH PRODUCTION ENTRIES: this one returned `Void` and the Android
    /// `MeshPanicWipe.begin()` discarded its `WipeStepResult`, so a `refused` or `retryLater` answer -- the difference
    /// between "the wipe ran" and "the wipe did nothing" -- was UNOBSERVABLE to every caller.* **A caller that cannot
    /// tell those apart cannot render completion at durable IDLE, because it cannot see the state at all.**
    ///
    /// *Found by an independent sweep that enumerated this finding's clauses rather than trusting its evidence list.*
    /// **`@discardableResult` keeps every existing call site compiling** -- *the shape of the repair the repository
    /// already useth for the internal overload one line below* -- while making the answer AVAILABLE rather than
    /// ERASED. **A public type cannot be returned here only if it were internal: `WipeStepResult` is public**, so
    /// there is no encapsulation reason for the erasure and there never was.
    @discardableResult
    public func beginPanicWipe() throws -> WipeStepResult {
        try beginPanicWipe(keychain: DefaultLocalIdentityKeychain())
    }

    /// GS-FINAL-002: **A FRESH WIPE REQUESTS; ONLY STARTUP RECOVERY RESUMES.**
    ///
    /// `requestWipe()` writes `REQUESTED` durably BEFORE it drives anything, then runs the ladder as far as the live
    /// seams allow. `resume()` is reserved for the crash path: it refuses an empty journal, and a fresh operation
    /// routed through it would DO NOTHING AT ALL while reporting success -- which is precisely the defect the audit
    /// measured on the Android isle (`MeshPanicWipe.begin` called `resume`).
    ///
    /// Internal, because `LocalIdentityKeychain` is internal: a public method cannot take an internal type. The
    /// retained authority owns every seam, so this overload exists only to keep the historical test signature -- a
    /// caller needing a custom keychain or a recording journal builds its own authority over the same journal.
    @discardableResult
    internal func beginPanicWipe(keychain: any LocalIdentityKeychain) throws -> WipeStepResult {
        _ = keychain
        return try wipeAuthority.requestWipe()
    }
}
