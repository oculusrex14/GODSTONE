package io.godstone.mesh.di

import android.content.Context
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import io.godstone.mesh.MeshNode
import io.godstone.mesh.delivery.DeliveryTracker
import io.godstone.mesh.delivery.Ed25519AckAuthenticator
import io.godstone.mesh.delivery.SqliteDeliveryJournal
import io.godstone.mesh.delivery.UnresolvedRecipientKeyResolver
import io.godstone.mesh.store.MessageStore
import io.godstone.mesh.store.SqliteMessageStore
import javax.inject.Singleton

/**
 * The ONE composition root for the mesh subsystem (Stage 4B / audit P0-02;
 * Stage 4C / C5 wires the delivery tracker).
 *
 * `MeshService` is `@AndroidEntryPoint` with `@Inject lateinit var meshNode:
 * MeshNode`; before this module existed that injection was unsatisfied (no
 * `@Provides` for `MeshNode` or its `MessageStore`), so there was no production
 * wiring that constructed a durable-backed node -- the durable store ADR-004
 * requires could be reached only from tests. This module is the single place
 * the production `MeshNode` and its `SqliteMessageStore` are constructed, so
 * every `MeshService` injection gets the same process-wide node carrying the
 * same durable store. Mirrors iOS `AppContainer`-style composition (the iOS
 * archive-only root wires no mesh today; the mesh ships behind
 * `LINK_LAYER_READY=false` on both platforms).
 *
 * Stage 4C / C5: the same `SqliteMessageStore` singleton's `engine` (the ONE
 * process-wide `StoreDb`) also feeds a `SqliteDeliveryJournal`, which is BOTH
 * the `DeliveryJournal` and the `ExpectedRecipientStore` for the
 * `DeliveryTracker`. The authenticator is `Ed25519AckAuthenticator` over the
 * production `UnresolvedRecipientKeyResolver` -- UNRESOLVED (M2-link identity
 * binding not wired), so it resolves no recipient key and rejects every ACK.
 * This is the fail-closed production state: the tracker owns the durable
 * delivery state + expected-recipient binding, but no delivery is claimed
 * until real recipient keys are bound (A-03 / ADR-005 OPEN). The outbound (C6)
 * and inbound-ACK (C7) paths in `MeshNode` drive this tracker.
 *
 * `:mesh` is non-shipping (the LIGHT release links only `:core`), so this
 * module is compiled as part of `:mesh` and reaches an app graph only when the
 * mesh subsystem is actually included -- it never lands on the archive-only
 * `lightRelease` classpath (verified by the forbidden-edge classpath gate,
 * Stage 4A). The Hilt graph here is what satisfies `MeshService.@Inject` once
 * the link layer (ADR-002 / Stage 4H) flips `LINK_LAYER_READY`.
 *
 * The store cap is the production wiring decision and so lives here, not in
 * the store: 64 MiB of frames (each < FrameV2.MAX_PAYLOAD + a 64-byte row
 * allowance) is thousands of delay-tolerant messages on a survival device --
 * generous for an epidemic router, bounded so an attacker cannot grow the
 * store without limit (ADR-004 §4 / criterion 4).
 */
@Module
@InstallIn(SingletonComponent::class)
object MeshModule {
    /** Production durable message-store hard cap (ADR-004 §4). */
    private const val STORE_MAX_BYTES = 64L * 1024 * 1024

    /**
     * The ONE process-wide `SqliteMessageStore`. Provided as the concrete type so
     * [provideDeliveryTracker] can reuse its `engine` (the shared `StoreDb`
     * connection) for the delivery journal -- one connection feeds both the
     * held-frames store and the `delivery_state` table.
     */
    @Provides @Singleton
    fun provideSqliteMessageStore(@ApplicationContext ctx: Context): SqliteMessageStore =
        SqliteMessageStore(ctx, STORE_MAX_BYTES)

    /// Re-expose the store as its `MessageStore` interface for `MeshNode` injection.
    @Provides @Singleton
    fun provideMessageStore(store: SqliteMessageStore): MessageStore = store

    /**
     * The production `DeliveryTracker` (Stage 4C / C5). The `SqliteDeliveryJournal`
     * wraps `store.engine` (the SAME `StoreDb` as the message store) and is passed
     * as BOTH the journal and the expected-recipient store -- one row holds the
     * delivery state + the intended recipient. The authenticator uses the
     * production `UnresolvedRecipientKeyResolver`, which resolves no key, so every
     * ACK is rejected (fail-closed until M2-link binds real recipient keys).
     */
    @Provides @Singleton
    fun provideDeliveryTracker(store: SqliteMessageStore): DeliveryTracker {
        val journal = SqliteDeliveryJournal(store.engine)
        return DeliveryTracker(
            journal,
            Ed25519AckAuthenticator(UnresolvedRecipientKeyResolver),
            journal,
        )
    }

    @Provides @Singleton
    fun provideMeshNode(
        @ApplicationContext ctx: Context,
        store: MessageStore,
        deliveryTracker: DeliveryTracker,
    ): MeshNode = MeshNode(ctx, store, deliveryTracker)
}