package io.godstone.mesh.di

import android.content.Context
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import io.godstone.mesh.MeshNode
import io.godstone.mesh.crypto.RepositoryPeerBindingTrustAuthority
import io.godstone.mesh.crypto.SessionManager
import io.godstone.mesh.delivery.BoundRecipientKeyResolver
import io.godstone.mesh.delivery.DeliveryTracker
import io.godstone.mesh.delivery.Ed25519AckAuthenticator
import io.godstone.mesh.delivery.RepositoryPeerIdentityLookupSource
import io.godstone.mesh.delivery.SqliteDeliveryRepository
import io.godstone.mesh.identity.AndroidWipeArtifacts
import io.godstone.mesh.identity.DefaultRuntimeLifecycleGate
import io.godstone.mesh.identity.FileWipeJournal
import io.godstone.mesh.identity.Identity
import io.godstone.mesh.identity.CrashResumableWipe
import io.godstone.mesh.identity.MeshRuntimeInvalidator
import io.godstone.mesh.identity.PanicWipe
import io.godstone.mesh.identity.WipeArtifactFileSystemSeam
import io.godstone.mesh.identity.WipeDeferredSeams
import io.godstone.mesh.identity.WipeIdentityAuthoritySeam
import io.godstone.mesh.identity.WipeJournalDurabilityAdapter
import io.godstone.mesh.identity.WipeKeyVaultSeam
import io.godstone.mesh.identity.WipeTransportDrainSeam
import io.godstone.mesh.identity.PeerIdentityRepository
import io.godstone.mesh.identity.RuntimeAwareWipeArtifacts
import io.godstone.mesh.identity.RuntimeGatedPeerBindingTrustAuthority
import io.godstone.mesh.identity.RuntimeGatedPeerIdentityLookupSource
import io.godstone.mesh.identity.SqlcipherPeerIdentityStore
import io.godstone.mesh.store.MessageStore
import io.godstone.mesh.store.SqliteMessageStore
import javax.inject.Singleton
import io.godstone.mesh.delivery.AckDispatcher
import io.godstone.mesh.delivery.AckObligationDriver
import io.godstone.mesh.delivery.DurableAckPump
import io.godstone.mesh.delivery.IdentityAckSigner
import io.godstone.mesh.delivery.SqliteAckStore
import io.godstone.mesh.delivery.RecipientKeyResolver
import io.godstone.mesh.delivery.RecipientInboxRepository

/**
 * Startup barrier execution primitive ensuring the RUNTIME-OWNED WIPE AUTHORITY executes before sensitive cryptographic
 * identity or database stores are opened (Stage 4 Phase C8.4B.2).
 *
 * GS-STORE-006: it USED to ensure `[PanicWipe.resumeIfPending]` did so; since round 412 it runs the CRASH-RESUMABLE
 * COORDINATOR over the DEFERRED seams instead. THIS DOCUMENTATION IS CORRECTED RATHER THAN LEFT DESCRIBING A CALL THE CODE
 * NO LONGER MAKES -- a comment that lieth about the code beside it is a defect, not a nicety.
 */
internal fun runStartupWipeBarrier(resumePendingWipe: () -> Unit) {
    resumePendingWipe()
}

internal class MeshStartupCoordinator(
    private val resumePendingWipe: () -> Unit
) {
    fun executeBarrier() {
        runStartupWipeBarrier(resumePendingWipe)
    }
}

/**
 * Startup barrier token ensuring the RUNTIME-OWNED WIPE AUTHORITY executes before any sensitive cryptographic identity or
 * database store is opened (Stage 4B.1 / C8.4B.1 / C8.4B.2).
 *
 * GS-STORE-006: the authority is the CRASH-RESUMABLE COORDINATOR with EVERY EFFECTFUL SEAM DEFERRED (this process owns no
 * transport, no keystore and no database handles yet), so a pending wipe STOPS where it can honestly stop and stays PENDING
 * for the runtime that stands.
 */
@Singleton
class MeshStartupWipeBarrier internal constructor(
    @ApplicationContext ctx: Context
) {
    init {
        runStartupWipeBarrier {
            // *** GS-STORE-006: THE OLD `PanicWipe.resumeIfPending(ctx)` IS REPLACED BY **ONE RUNTIME-OWNED AUTHORITY** --
            // THE CRASH-RESUMABLE COORDINATOR THE ISLE ALREADY HAD BUT WHICH NOTHING IN PRODUCTION EVER CALLED (round 400
            // counted ZERO production conformances for any of its five seams). ***
            //
            // AND AT THE STARTUP **EVERY EFFECTFUL SEAM IS DEFERRED**, BECAUSE THIS PROCESS OWNS NO PLATFORM RESOURCE YET:
            // no transport, no keystore, no database handles. THE LADDER THEREFORE STOPS WHERE IT CAN HONESTLY STOP --
            // nothing erased, nothing deleted, no store opened on an erased key -- AND THE WIPE STAYS PENDING FOR THE
            // RUNTIME THAT STANDS, exactly as the card's step 6 requires ("on restart, resume from the durable compatible
            // journal BEFORE opening keys, databases, discovery or a new identity").
            //
            // THE JOURNAL IS NOT DEFERRED: writing a checkpoint is DURABILITY, not destruction, and it is the whole point of
            // this half. `FileWipeJournal` commits synchronously, which is what makes the checkpoint survive the crash the
            // ladder's durability is built for.
            CrashResumableWipe(
                store = WipeJournalDurabilityAdapter(FileWipeJournal(ctx)),
                vault = WipeDeferredSeams.DeferredKeyVaultSeam(),
                filesystem = WipeDeferredSeams.DeferredArtifactFileSystemSeam(),
                runtime = WipeDeferredSeams.DeferredTransportRuntimeSeam(),
                authority = WipeDeferredSeams.DeferredIdentityAuthoritySeam(),
            ).resume()
        }
    }
}

/**
 * Active runtime panic-wipe authority (Stage 4 Phase C8.4B / C8.4B.1).
 *
 * Coordinates invalidation across the live runtime graph ([DefaultRuntimeLifecycleGate],
 * [SessionManager], [SqlcipherPeerIdentityStore], [SqliteMessageStore]) via [MeshRuntimeInvalidator]
 * and [RuntimeAwareWipeArtifacts] before triggering platform cryptographic key erasure.
 */
@Singleton
class MeshPanicWipe internal constructor(
    @ApplicationContext private val ctx: Context,
    private val invalidator: MeshRuntimeInvalidator,
    private val node: MeshNode
) {
    fun begin() {
        val artifacts = RuntimeAwareWipeArtifacts(
            invalidator = invalidator,
            delegate = AndroidWipeArtifacts(ctx)
        )
        // *** GS-STORE-006: THIS ROOT IS THE RUNTIME-SIDE AUTHORITY, SO IT RUNS THE COORDINATOR OVER THE **LIVE** SEAMS --
        // and it can, because the module provideth the node, and the node owneth the transport. ***
        // `PanicWipe(FileWipeJournal(ctx), artifacts).begin()` RETIRES HERE: THE OLD COORDINATOR IS NO LONGER WHAT THE
        // RUNTIME-SIDE WIPE RUNS.
        val journal = FileWipeJournal(ctx)
        CrashResumableWipe(
            store = WipeJournalDurabilityAdapter(journal),          // the mapping; the journal is the isle's own
            vault = WipeKeyVaultSeam(artifacts),                    // over the RuntimeAwareWipeArtifacts built ABOVE, so
                                                                    // the invalidation ordering the isle owns is kept
            filesystem = WipeArtifactFileSystemSeam(journal),       // the same journal handle: one durable record
            runtime = WipeTransportDrainSeam(node.bleTransportForWipe),  // THE LIVE TRANSPORT the runtime itself uses
            authority = WipeIdentityAuthoritySeam(ctx, artifacts),  // the isle's own regeneration + naming
        ).resume()
    }
}

/**
 * The ONE composition root for the mesh subsystem (Stage 4B / C8.4B / C8.4B.1).
 *
 * Provides the unified runtime authority graph:
 * - One [MeshStartupWipeBarrier] ensuring crash/startup pending wipe recovery executes before open;
 * - One [Identity] authority for the process (loaded after [MeshStartupWipeBarrier]);
 * - One [SqliteMessageStore] and [SqlcipherPeerIdentityStore];
 * - One [PeerIdentityRepository] backing BOTH [BoundRecipientKeyResolver] and [SessionManager];
 * - [BoundRecipientKeyResolver] installed into [Ed25519AckAuthenticator] and [DeliveryTracker];
 * - Trusted [SessionManager] backed by [TrustedHandshakeController] and [RuntimeGatedPeerBindingTrustAuthority];
 * - [MeshNode] consuming the single [Identity], [MessageStore], [DeliveryTracker], and [SessionManager];
 * - [DefaultRuntimeLifecycleGate] ensuring clean fail-closed runtime invalidation on wipe;
 * - [MeshRuntimeInvalidator] and [MeshPanicWipe] providing runtime-aware active wipe authority.
 */
@Module
@InstallIn(SingletonComponent::class)
internal object MeshModule {
    /** Production durable message-store hard cap (ADR-004 §4). */
    private const val STORE_MAX_BYTES = 64L * 1024 * 1024

    @Provides @Singleton
    fun provideStartupWipeBarrier(@ApplicationContext ctx: Context): MeshStartupWipeBarrier =
        MeshStartupWipeBarrier(ctx)

    @Provides @Singleton
    fun provideRuntimeLifecycleGate(): DefaultRuntimeLifecycleGate =
        DefaultRuntimeLifecycleGate()

    @Provides @Singleton
    fun provideIdentity(
        @ApplicationContext ctx: Context,
        _barrier: MeshStartupWipeBarrier
    ): Identity =
        Identity.loadOrCreate(ctx)

    /**
     * The ONE process-wide `SqliteMessageStore`. Provided as the concrete type so
     * [provideDeliveryTracker] can reuse its `engine` (the shared `StoreDb`
     * connection) for the delivery journal -- one connection feeds both the
     * held-frames store and the `delivery_state` table.
     */
    @Provides @Singleton
    fun provideSqliteMessageStore(
        @ApplicationContext ctx: Context,
        _barrier: MeshStartupWipeBarrier
    ): SqliteMessageStore =
        SqliteMessageStore(ctx, STORE_MAX_BYTES)

    /// Re-expose the store as its `MessageStore` interface for `MeshNode` injection.
    @Provides @Singleton
    fun provideMessageStore(store: SqliteMessageStore): MessageStore = store

    @Provides @Singleton
    fun providePeerIdentityStore(
        @ApplicationContext ctx: Context,
        _barrier: MeshStartupWipeBarrier
    ): SqlcipherPeerIdentityStore =
        SqlcipherPeerIdentityStore(ctx)

    @Provides @Singleton
    fun providePeerIdentityRepository(store: SqlcipherPeerIdentityStore): PeerIdentityRepository =
        PeerIdentityRepository(store)

    @Provides @Singleton
    fun provideBoundRecipientKeyResolver(
        repo: PeerIdentityRepository,
        gate: DefaultRuntimeLifecycleGate
    ): BoundRecipientKeyResolver {
        val source = RuntimeGatedPeerIdentityLookupSource(RepositoryPeerIdentityLookupSource(repo), gate)
        return BoundRecipientKeyResolver(source)
    }

    /**
     * The production `DeliveryTracker` (Stage 4 Phase C8.4B).
     * The `SqliteDeliveryRepository` wraps `store.engine` (the SAME `StoreDb` as the
     * message store). The authenticator uses `BoundRecipientKeyResolver`.
     */
    @Provides @Singleton
    fun provideDeliveryTracker(
        store: SqliteMessageStore,
        resolver: BoundRecipientKeyResolver
    ): DeliveryTracker {
        val repo = SqliteDeliveryRepository(store.engine, store::notifyHeldSetChanged)
        return DeliveryTracker(repo, Ed25519AckAuthenticator(resolver))
    }

    @Provides @Singleton
    fun provideSessionManager(
        identity: Identity,
        repo: PeerIdentityRepository,
        gate: DefaultRuntimeLifecycleGate
    ): SessionManager {
        val trustAuthority = RuntimeGatedPeerBindingTrustAuthority(RepositoryPeerBindingTrustAuthority(repo), gate)
        return SessionManager(identity, trustAuthority, lifecycleGate = gate)
    }

    @Provides @Singleton
    fun provideMeshRuntimeInvalidator(
        gate: DefaultRuntimeLifecycleGate,
        sessions: SessionManager,
        peerStore: SqlcipherPeerIdentityStore,
        messageStore: SqliteMessageStore,
        node: MeshNode,
    ): MeshRuntimeInvalidator =
        MeshRuntimeInvalidator(
            lifecycleGate = gate,
            sessions = sessions,
            peerStore = peerStore,
            messageStore = messageStore,
            node = node,
        )

    @Provides @Singleton
    fun provideMeshPanicWipe(
        @ApplicationContext ctx: Context,
        invalidator: MeshRuntimeInvalidator,
        node: MeshNode                    // GS-STORE-006: THE LIVE TRANSPORT'S OWNER, so the wipe may drain what it owns
    ): MeshPanicWipe =
        MeshPanicWipe(ctx, invalidator, node)

    // ============================ GS-RUNTIME-001 step 2 on THIS isle: THE FOUR OWNERS ============================
    //
    // MEASURED BEFORE THIS (rounds 228-231): the Kotlin twins of all four owners STOOD in `delivery/`, the Kotlin
    // `MeshNode` already had `recipientInbox` and `ackDispatcher` attachment points and a `router`, and
    // **THE COMPOSITION PROVIDED NONE OF THEM** -- the live path could not send a scheduled, authenticated,
    // durable ACK at all. These providers bind them to THE SAME OPENED STORE AND THE SAME PINNED IDENTITY as
    // everything else in this module, and the signer is the PRODUCTION signer (round 230), whose seed road
    // refuseth by construction.

    @Provides @Singleton
    fun provideEd25519AckAuthenticator(resolver: RecipientKeyResolver): Ed25519AckAuthenticator =
        Ed25519AckAuthenticator(resolver)

    @Provides @Singleton
    fun provideAckStore(store: SqliteMessageStore): SqliteAckStore = SqliteAckStore(store.engine)

    @Provides @Singleton
    fun provideAckDriver(
        ackStore: SqliteAckStore,
        identity: Identity,
        authenticator: Ed25519AckAuthenticator,
        resolver: RecipientKeyResolver,
    ): AckObligationDriver =
        AckObligationDriver(ackStore, IdentityAckSigner(identity), authenticator, resolver)

    @Provides @Singleton
    fun provideAckPump(
        ackStore: SqliteAckStore,
        driver: AckObligationDriver,
    ): DurableAckPump =
        DurableAckPump(
            ackStore,
            { encoded, from -> driver.admitForeignCandidate(encoded, from) },
        )

    @Provides @Singleton
    fun provideMeshNode(
        @ApplicationContext ctx: Context,
        identity: Identity,
        store: MessageStore,
        deliveryTracker: DeliveryTracker,
        sessions: SessionManager,
        pump: DurableAckPump,
        sqliteStore: SqliteMessageStore,
        ackStore: SqliteAckStore,
        authenticator: Ed25519AckAuthenticator,
        resolver: RecipientKeyResolver,
    ): MeshNode {
        val node = MeshNode(ctx, identity, sqliteStore, deliveryTracker, sessions)
        // GS-RUNTIME-001 step 2: **THE DISPATCHER IS BOUND TO THE NODE**, answering the delivery tracker exactly
        // as the harness's twin doth. (The recipient inbox's own wiring followeth the T83 commit road and is the
        // NEXT slice; it is NOT claimed here.)
        node.ackDispatcher = AckDispatcher(
            lookupDeliveryRow = { deliveryTracker.lookup(it) },
            verifyOrigin = { deliveryTracker.acknowledge(it.msgId, it) },
            admitCandidate = { encoded, from -> pump.admit(encoded, from) },
        )
        // --------------------------------------------------------------------------------------
        // *** GS-RUNTIME-001 (round 545): THE PUMP ITSELF REACHETH THE NODE -- THE ASSIGNMENT THAT WAS MISSING. ***
        //
        // MEASURED BEFORE THIS LINE: `provisionAckPump` WAS INJECTED INTO THIS FUNCTION AND **NEVER ASSIGNED**, so
        // `MeshNode.ackPump` -- *'internal var ackPump: DurableAckPump? = null'* -- STAYED NULL IN PRODUCTION, WHILE
        // THE PUMP WAS MANUFACTURED, INJECTED, AND HANDED TO NOBODY. **A DEPENDENCY INJECTION FRAMEWORK MAKES AN
        // UNUSED PARAMETER INVISIBLE: it compiles, it wires, and it reacheth nothing.** Every consumer of the pump
        // on this isle therefore took the null road: `nextScheduledAck` returned null, `onLinkReady`/`onLinkGone`
        // were never told, and `isScheduled(fromPeer)` was ALWAYS FALSE -- **SO AN INBOUND ACK WAS NEVER RECOGNISED AS
        // OURS.** THE DISPATCHER BESIDE IT WAS ASSIGNED; THE PUMP WAS NOT; AND THE DIFFERENCE BETWEEN THE TWO LINES
        // WAS THE WHOLE OF THE FINDING.
        node.ackPump = pump
        // GS-RUNTIME-001 step 2: **THE RECIPIENT INBOX -- THE LAST OF THE FOUR OWNERS -- OVER THE T83 COMMIT ROAD.**
        // Its DH road is the one production CAN satisfy on this isle: `Identity.staticDhPriv` is exposed INTERNALLY
        // on the very precedent `staticDhPub`/`staticDhPriv` already stood upon, so the seed never leaveth the module.
        // The commit closure IS the composing store's own method, so an accepted delivery and its ACK obligation
        // commit in ONE transaction; and the identityGeneration closure is passed EXPLICITLY, because the inbox's
        // default is `0L` and a production obligation must pin the identity's REAL generation.
        node.recipientInbox = RecipientInboxRepository(
            router = node.router,
            ourNodeId = identity.nodeId,
            localDhPrivate = { identity.staticDhPriv },
            signer = IdentityAckSigner(identity),
            resolver = resolver,
            authenticator = authenticator,
            pairedStore = ackStore,
            commitInbound = { frame, receivedFrom, localRecipient, generation, lifetime, receivedAt, fault ->
                sqliteStore.commitInboundWithObligationAtWithFault(
                    frame, receivedFrom, localRecipient, generation, lifetime, receivedAt, fault,
                )
            },
            identityGeneration = { identity.bindingGeneration },
        )
        return node
    }
}