import Foundation
import GodstoneCore

/// Non-shipping composition root for the mesh subsystem (Stage 4 Phase C8.4B).
///
/// Builds and owns the unified mesh runtime authority graph:
/// - One `MeshIdentity`
/// - One `SqliteMessageStore`
/// - One `SqlitePeerIdentityStore`
/// - One `PeerIdentityRepository` backing BOTH `BoundRecipientKeyResolver` and `SessionManager`
/// - `DeliveryTracker` with `Ed25519AckAuthenticator` over `BoundRecipientKeyResolver`
/// - Trusted `SessionManager`
/// - `MeshNode` consuming only the trusted `SessionManager` and `MeshIdentity`
/// - `RuntimeInvalidator` for deterministic panic wipe invalidation
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
    public let lifecycleGate: DefaultRuntimeLifecycleGate
    public let invalidator: MeshRuntimeInvalidator

    internal init(
        identity: MeshIdentity,
        messageStore: SqliteMessageStore,
        peerIdentityStore: SqlitePeerIdentityStore,
        lifecycleGate: DefaultRuntimeLifecycleGate = DefaultRuntimeLifecycleGate()
    ) {
        self.identity = identity
        self.messageStore = messageStore
        self.peerIdentityStore = peerIdentityStore
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

        self.invalidator = MeshRuntimeInvalidator(
            lifecycleGate: lifecycleGate,
            sessions: sessions,
            peerStore: peerIdentityStore,
            messageStore: messageStore
        )
    }

    /// Create a standard non-shipping `MeshRuntime` after resuming any pending panic wipe.
    public static func create(
        messageStoreUrl: URL,
        peerStoreUrl: URL,
        maxStoreBytes: Int64 = 64 * 1024 * 1024,
        journal: WipeJournal = UserDefaultsWipeJournal(),
        artifacts: WipeArtifacts = KeychainWipeArtifacts()
    ) throws -> MeshRuntime {
        // Startup/Resume barrier: finish any pending wipe BEFORE opening stores or identity
        try PanicWipe.resumeIfPending(journal: journal, artifacts: artifacts)

        let identity = try MeshIdentity.loadOrCreate()
        let messageStore = SqliteMessageStore(url: messageStoreUrl, maxBytes: maxStoreBytes)
        let peerStore = try SqlitePeerIdentityStore(url: peerStoreUrl)
        return MeshRuntime(identity: identity, messageStore: messageStore, peerIdentityStore: peerStore)
    }
}
