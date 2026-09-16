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
    // GS-RUNTIME-001 step 2: **THE ACK ROAD'S OWNERS, IN THE PRODUCTION RUNTIME.** Until these landed, the durable
    // ACK store, its driver, its pump and the recipient inbox were constructed ONLY by the composition harness --
    // and nothing in production ever collected the transport's readiness, so "registering a queue does not send
    // it". They are built over the SAME opened private store and the SAME pinned identity as everything else here.
    // (INTERNAL, NOT PUBLIC: these types are internal, and `public let` on an internal type doth not compile --
    // the compiler said so, which is how I learned that the runtime's OWN shape needeth no wider surface.)
    internal let ackStore: SqliteAckStore
    internal let ackDriver: AckObligationDriver
    internal let ackPump: DurableAckPump
    public let lifecycleGate: DefaultRuntimeLifecycleGate
    public let invalidator: MeshRuntimeInvalidator
    public let messageStoreUrl: URL
    public let peerStoreUrl: URL
    public let journal: WipeJournal

    internal init(
        identity: MeshIdentity,
        messageStore: SqliteMessageStore,
        peerIdentityStore: SqlitePeerIdentityStore,
        messageStoreUrl: URL,
        peerStoreUrl: URL,
        journal: WipeJournal = UserDefaultsWipeJournal(),
        lifecycleGate: DefaultRuntimeLifecycleGate = DefaultRuntimeLifecycleGate()
    ) {
        self.identity = identity
        self.messageStore = messageStore
        self.peerIdentityStore = peerIdentityStore
        self.messageStoreUrl = messageStoreUrl
        self.peerStoreUrl = peerStoreUrl
        self.journal = journal
        self.lifecycleGate = lifecycleGate

        let peerRepo = PeerIdentityRepository(store: peerIdentityStore)
        self.peerRepository = peerRepo

        let gatedLookup = RuntimeGatedPeerIdentityLookupSource(
            delegate: peerRepo,
            lifecycleGate: lifecycleGate
        )
        let resolver = BoundRecipientKeyResolver(source: gatedLookup)
        self.recipientKeyResolver = resolver

        let ackAuth = Ed25519AckAuthenticator(resolver: resolver)
        self.ackAuthenticator = ackAuth

        let delivRepo = SqliteDeliveryRepository(messageStore)
        self.deliveryRepository = delivRepo

        let tracker = DeliveryTracker(repo: delivRepo, authenticator: ackAuth)
        self.deliveryTracker = tracker

        let gatedTrust = RuntimeGatedPeerBindingTrustAuthority(
            delegate: RepositoryPeerBindingTrustAuthority(repository: peerRepo),
            lifecycleGate: lifecycleGate
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
            sessions: sessions
        )

        // GS-RUNTIME-001 step 2: THE FOUR OWNERS, OVER THE SAME STORE AND THE SAME PINNED IDENTITY.
        // (a) the durable paired store IS the message store's transaction engine (SqliteMessageStore conformeth
        //     to AckObligationEngine), so the ACK namespaces commit inside the SAME database;
        let ackStore = SqliteAckStore(engine: messageStore)
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
                try messageStore.commitInboundWithObligationAtWithFault(
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
    }

    public static func create(
        messageStoreUrl: URL,
        peerStoreUrl: URL,
        maxStoreBytes: Int64 = 64 * 1024 * 1024,
        journal: WipeJournal = UserDefaultsWipeJournal(),
        artifacts: WipeArtifacts? = nil
    ) throws -> MeshRuntime {
        try create(
            messageStoreUrl: messageStoreUrl,
            peerStoreUrl: peerStoreUrl,
            maxStoreBytes: maxStoreBytes,
            journal: journal,
            artifacts: artifacts,
            keychain: DefaultLocalIdentityKeychain()
        )
    }

    /// Internal creation overload accepting custom `LocalIdentityKeychain` for testing.
    internal static func create(
        messageStoreUrl: URL,
        peerStoreUrl: URL,
        maxStoreBytes: Int64 = 64 * 1024 * 1024,
        journal: WipeJournal = UserDefaultsWipeJournal(),
        artifacts: WipeArtifacts? = nil,
        keychain: any LocalIdentityKeychain,
        encryptedStores: EncryptedStoreFactory? = nil
    ) throws -> MeshRuntime {
        let effectiveArtifacts =
            artifacts ??
            KeychainWipeArtifacts(
                keychain: keychain,
                storeUrl: messageStoreUrl,
                peerStoreUrl: peerStoreUrl
            )

        // Startup/Resume barrier: finish any pending wipe BEFORE opening stores or identity
        try PanicWipe.resumeIfPending(journal: journal, artifacts: effectiveArtifacts)

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
        let peerStore = try SqlitePeerIdentityStore(url: peerStoreUrl)
        return MeshRuntime(
            identity: identity,
            messageStore: messageStore,
            peerIdentityStore: peerStore,
            messageStoreUrl: messageStoreUrl,
            peerStoreUrl: peerStoreUrl,
            journal: journal
        )
    }

    /// Active panic-wipe execution for this runtime graph (Stage 4B.1 / C8.4B.1).
    /// Uses `RuntimeAwareWipeArtifacts` to ensure runtime handles are invalidated
    /// before cryptographic key erasure.
    public func beginPanicWipe() throws {
        try beginPanicWipe(keychain: DefaultLocalIdentityKeychain())
    }

    /// Internal panic-wipe execution overload accepting custom `LocalIdentityKeychain` for testing.
    internal func beginPanicWipe(keychain: any LocalIdentityKeychain) throws {
        let artifacts = RuntimeAwareWipeArtifacts(
            invalidator: self.invalidator,
            delegate: KeychainWipeArtifacts(
                keychain: keychain,
                storeUrl: self.messageStoreUrl,
                peerStoreUrl: self.peerStoreUrl
            )
        )
        try PanicWipe(journal: self.journal, artifacts: artifacts).begin()
    }
}
