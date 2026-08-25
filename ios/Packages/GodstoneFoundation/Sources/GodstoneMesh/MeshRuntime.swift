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

        self.invalidator = MeshRuntimeInvalidator(
            lifecycleGate: lifecycleGate,
            sessions: sessions,
            peerStore: peerIdentityStore,
            messageStore: messageStore
        )
    }

    /// Create a standard non-shipping `MeshRuntime` after resuming any pending panic wipe.
    /// Associates the pending wipe with the exact `messageStoreUrl` and `peerStoreUrl` it will later open.
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
        keychain: any LocalIdentityKeychain
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
