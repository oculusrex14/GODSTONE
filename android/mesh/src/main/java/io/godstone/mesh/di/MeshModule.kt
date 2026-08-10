package io.godstone.mesh.di

import android.content.Context
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import io.godstone.mesh.MeshNode
import io.godstone.mesh.store.MessageStore
import io.godstone.mesh.store.SqliteMessageStore
import javax.inject.Singleton

/**
 * The ONE composition root for the mesh subsystem (Stage 4B / audit P0-02).
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

    @Provides @Singleton
    fun provideMessageStore(@ApplicationContext ctx: Context): MessageStore =
        SqliteMessageStore(ctx, STORE_MAX_BYTES)

    @Provides @Singleton
    fun provideMeshNode(
        @ApplicationContext ctx: Context,
        store: MessageStore,
    ): MeshNode = MeshNode(ctx, store)
}