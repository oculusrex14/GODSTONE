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
import io.godstone.mesh.identity.MeshRuntimeInvalidator
import io.godstone.mesh.identity.PanicWipe
import io.godstone.mesh.identity.PeerIdentityRepository
import io.godstone.mesh.identity.RuntimeAwareWipeArtifacts
import io.godstone.mesh.identity.RuntimeGatedPeerBindingTrustAuthority
import io.godstone.mesh.identity.RuntimeGatedPeerIdentityLookupSource
import io.godstone.mesh.identity.SqlcipherPeerIdentityStore
import io.godstone.mesh.store.MessageStore
import io.godstone.mesh.store.SqliteMessageStore
import javax.inject.Singleton

/**
 * Startup barrier execution primitive ensuring [PanicWipe.resumeIfPending] executes before
 * sensitive cryptographic identity or database stores are opened (Stage 4 Phase C8.4B.2).
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
 * Startup barrier token ensuring [PanicWipe.resumeIfPending] executes before
 * any sensitive cryptographic identity or database store is opened (Stage 4B.1 / C8.4B.1 / C8.4B.2).
 */
@Singleton
class MeshStartupWipeBarrier internal constructor(
    @ApplicationContext ctx: Context
) {
    init {
        runStartupWipeBarrier {
            PanicWipe.resumeIfPending(ctx)
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
    private val invalidator: MeshRuntimeInvalidator
) {
    fun begin() {
        val artifacts = RuntimeAwareWipeArtifacts(
            invalidator = invalidator,
            delegate = AndroidWipeArtifacts(ctx)
        )
        PanicWipe(FileWipeJournal(ctx), artifacts).begin()
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
        messageStore: SqliteMessageStore
    ): MeshRuntimeInvalidator =
        MeshRuntimeInvalidator(
            lifecycleGate = gate,
            sessions = sessions,
            peerStore = peerStore,
            messageStore = messageStore
        )

    @Provides @Singleton
    fun provideMeshPanicWipe(
        @ApplicationContext ctx: Context,
        invalidator: MeshRuntimeInvalidator
    ): MeshPanicWipe =
        MeshPanicWipe(ctx, invalidator)

    @Provides @Singleton
    fun provideMeshNode(
        @ApplicationContext ctx: Context,
        identity: Identity,
        store: MessageStore,
        deliveryTracker: DeliveryTracker,
        sessions: SessionManager
    ): MeshNode = MeshNode(ctx, identity, store, deliveryTracker, sessions)
}