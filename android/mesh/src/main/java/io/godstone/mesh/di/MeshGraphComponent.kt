package io.godstone.mesh.di

import dagger.Binds
import dagger.BindsInstance
import dagger.Component
import io.godstone.mesh.MeshNode
import io.godstone.mesh.delivery.AckObligationDriver
import io.godstone.mesh.delivery.DeliveryTracker
import io.godstone.mesh.delivery.BoundRecipientKeyResolver
import io.godstone.mesh.delivery.Ed25519AckAuthenticator
import io.godstone.mesh.delivery.RecipientKeyResolver
import io.godstone.mesh.delivery.SqliteAckStore
import io.godstone.mesh.identity.PeerIdentityRepository
import io.godstone.mesh.crypto.SessionManager
import io.godstone.mesh.identity.DefaultRuntimeLifecycleGate
import io.godstone.mesh.identity.Identity
import io.godstone.mesh.identity.SqlcipherPeerIdentityStore
import io.godstone.mesh.identity.WipeSensitiveUseGate
import io.godstone.mesh.identity.WipeGatedAckObligationStore
import io.godstone.mesh.delivery.DurableAckPump
import io.godstone.mesh.store.MessageStore
import io.godstone.mesh.store.SqliteMessageStore
import android.content.Context
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.Module
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import dagger.Provides
import javax.inject.Singleton

/**
 * *** GS-FINAL-003 (ii) / GS-RUNTIME-001: THE REAL DAGGER COMPONENT, SO `MeshModule`'s BINDINGS ARE COMPILED. ***
 *
 * THE NAMED GAP, IN THE LEDGER'S OWN WORDS: *"THE HILT BINDING'S PORTABILITY TO A REAL COMPONENT IS UNTESTED because
 * no `:mesh` Dagger component exists on LIGHT."* **AND THAT IS NOT A DOCUMENTATION GAP -- IT IS A CODEGEN GAP:**
 * `@Provides` methods in a Hilt module are validated ONLY when a component actually consumes them. Until this
 * interface existed, NOTHING in this repository assembled `MeshModule`, so:
 *
 *   * a provider with a missing dependency, a type mismatch, or an unsatisfiable `@Singleton` scope WOULD NOT FAIL
 *     THE BUILD -- it would ship, and fail at runtime inside a DI graph that no test could construct;
 *   * and the courts could only HAN D-CALL `MeshModule.provideX(...)`, which measures a function, not a GRAPH.
 *     *A provider that returns a plausible object from a plausible input can look perfect and still be unwireable --
 *     THE INVERTED `provideWipeIsPending` GATE SHIPPED FOR EIGHTEEN ROUNDS behind exactly that kind of hand-call.*
 *
 * *** WHY THIS COMPONENT CAN EXIST ON A NON-SHIPPING MODULE. *** *`:mesh` is NOT on the LIGHT shipping edge: the
 * lab-isolation control requires `:app` to reach `:core` only, and `FORBIDDEN_ANDROID_MODULES` names `mesh` itself.
 * So this component lives where the mesh runtime lives and can never leak into the shipped profile -- the same reason
 * the module's tests may construct a real `Context`.*
 *
 * *** IT IS DECLARED HERE, IN MAIN, RATHER THAN IN THE TEST SOURCE SET, BECAUSE CODEGEN HAPPENS AT COMPILE TIME.** *A
 * component declared only in a test would be generated only for the test variant, so the MAIN variant's providers
 * would still never be validated -- and a debug-only graph proves nothing about what ships. Declaring it in main
 * means `:mesh:compileDebugKotlin` and `:mesh:compileReleaseKotlin` BOTH fail if the graph cannot be assembled.*
 *
 * SCOPED `@Singleton` LIKE THE HILT COMPONENT IT MIRRORS: the production bindings are all `@Singleton`, and a
 * component that did not carry that scope would fail to compile -- which is itself a check the repository lacked.
 */
@Singleton
@Component(modules = [MeshGraphMeshModule::class])
internal interface MeshGraphComponent {

    /** The one process-wide node, assembled from the module's real providers. */
    fun meshNode(): MeshNode

    /** Identity, which the module loads through the startup barrier. */
    fun identity(): Identity

    fun messageStore(): SqliteMessageStore

    /** Exposed as the INTERFACE too, so the `@Provides fun provideMessageStore` road is exercised. */
    fun messageStoreInterface(): MessageStore

    fun peerIdentityStore(): SqlcipherPeerIdentityStore

    fun runtimeLifecycleGate(): DefaultRuntimeLifecycleGate

    /**
     * *** THE GATE, AND THE REASON THIS COMPONENT IS WORTH BUILDING. ***
     *
     * *This binding's POLARITY was INVERTED in production for EIGHTEEN ROUNDS -- it answered `true` (allowed) exactly
     * when a wipe WAS outstanding -- and every lane stayed green, because the courts that "covered" it invoked the
     * provider WITH A HAND-TYPED LAMBDA of their own. **A PROVIDER'S BODY CANNOT BE MEASURED BY A COURT THAT PASSES
     * ITS OWN LAMBDA**, and a component that RESOLVES the binding is the first thing here that forces the real one
     * into a graph.*
     */
    fun wipeSensitiveUseGate(): WipeSensitiveUseGate

    /** The DECORATED ACK store: `@Provides` returns the gated type, so an unwired consumer would not compile. */
    fun wipeGatedAckObligationStore(): WipeGatedAckObligationStore

    /** The scheduler the node's dispatcher must be bound to -- GS-RUNTIME-001's write half. */
    fun ackDriver(): AckObligationDriver

    /**
     * *** THE RESOLVER, EXPOSED SO THE INTERFACE BINDING CAN BE OBSERVED. ***
     *
     * *`RecipientKeyResolver` was the binding the graph was MISSING -- nothing said the concrete
     * `BoundRecipientKeyResolver` satisfied the interface three providers ask for. Exposing it lets a court assert
     * that the interface and the concrete resolve to the SAME scoped object, which is the difference between a
     * `@Binds` and a second `@Provides` that would mint a rival resolver.*
     */
    fun recipientKeyResolver(): RecipientKeyResolver

    /** GS-RUNTIME-001's write half: the pump the node's dispatcher must be bound to. */
    fun durableAckPump(): DurableAckPump

    /**
     * *** THE COMPONENT'S ONE EXTERNAL INPUT. ***
     *
     * *The application `Context` is the single thing the graph cannot build for itself, so it is BOUND as an instance
     * rather than looked up -- see the note above for why both module-shaped attempts were rejected by codegen.*
     */
    @Component.Builder
    interface Builder {
        @BindsInstance
        fun applicationContext(@ApplicationContext context: Context): Builder
        fun build(): MeshGraphComponent
    }
}

/**
 * *** THE `@ApplicationContext Context` IS A BOUND INSTANCE, NOT A MODULE -- AND THAT IS THE DESIGN THE CODEGEN
 * FORCED. ***
 *
 * *My first two attempts were a `@Provides` module, and Hilt rejected both, each time for a REASON WORTH KEEPING:
 * an instantiable module must have "a visible, empty constructor", and a module needing runtime construction cannot
 * be Hilt-instantiated at all. A `Context` is exactly a runtime value, so THE GRAPH MUST NOT TRY TO PROVIDE IT FROM A
 * MODULE -- it is an INPUT to the component, and Dagger has a first-class way to say so.*
 *
 * **`@BindsInstance` WITH THE QUALIFIER**, so `MeshModule`'s `@ApplicationContext Context` parameters resolve to the
 * caller's own application context. **NO STATIC HOLDER, NO AMBIENT STATE**: the value is fixed when the component is
 * built, for that component, and a second component cannot disagree with the first about which application it serves
 * -- which a `static var` would have allowed.
 */

/**
 * *** `MeshModule`'s BINDINGS, RE-EXPOSED FOR A NON-HILT COMPONENT -- AND THE ONE PLACE A `@Binds` CAN LIVE. ***
 *
 * *Hilt's processor complained twice, and both complaints were correct: `MeshModule` carries `@InstallIn`, which only
 * a Hilt component honours, and a `@Binds` method must be ABSTRACT -- which an `object` cannot be. **THE MODULE'S
 * PROVIDERS ARE THEREFORE RE-DECLARED HERE AS ABSTRACT DELEGATIONS to the same `object`, so the graph resolves
 * EXACTLY the production implementations** -- no second implementation of anything, and `MeshModule` itself stays
 * untouched and remains the authority for what each provider does.*
 *
 * WHY NOT JUST EDIT `MeshModule`: *it is a Hilt module on a non-shipping path, and its `@Provides` bodies are what the
 * existing courts hand-call. Duplicating them here would create a SECOND place for a wiring decision to live -- the
 * defect this module's own docstring names. Delegation keeps one authority.*
 */
@Module
@InstallIn(SingletonComponent::class)
internal abstract class MeshGraphMeshModule {
    /** THE INTERFACE BINDING THE GRAPH WAS MISSING: bound to the module's own `@Singleton` concrete resolver. */
    @Binds @Singleton
    abstract fun bindRecipientKeyResolver(impl: BoundRecipientKeyResolver): RecipientKeyResolver

    companion object {
        /** Every provider below DELEGATES to `MeshModule`, so the graph's behaviour is the production behaviour. */
        @Provides @Singleton
        fun startupWipeBarrier(@ApplicationContext ctx: Context): MeshStartupWipeBarrier =
            MeshModule.provideStartupWipeBarrier(ctx)

        @Provides @Singleton
        fun runtimeLifecycleGate(): DefaultRuntimeLifecycleGate = MeshModule.provideRuntimeLifecycleGate()

        @Provides @Singleton
        fun identity(@ApplicationContext ctx: Context, barrier: MeshStartupWipeBarrier): Identity =
            MeshModule.provideIdentity(ctx, barrier)

        @Provides @Singleton
        fun messageStore(@ApplicationContext ctx: Context, barrier: MeshStartupWipeBarrier): SqliteMessageStore =
            MeshModule.provideSqliteMessageStore(ctx, barrier)

        @Provides @Singleton
        fun messageStoreInterface(store: SqliteMessageStore): MessageStore =
            MeshModule.provideMessageStore(store)

        @Provides @Singleton
        fun peerIdentityStore(@ApplicationContext ctx: Context, barrier: MeshStartupWipeBarrier): SqlcipherPeerIdentityStore =
            MeshModule.providePeerIdentityStore(ctx, barrier)

        @Provides @Singleton
        fun peerIdentityRepository(store: SqlcipherPeerIdentityStore): PeerIdentityRepository =
            MeshModule.providePeerIdentityRepository(store)

        @Provides @Singleton
        fun wipeIsPending(@ApplicationContext ctx: Context): WipeSensitiveUseGate =
            MeshModule.provideWipeIsPending(ctx)

        @Provides @Singleton
        fun boundRecipientKeyResolver(
            repo: PeerIdentityRepository,
            gate: DefaultRuntimeLifecycleGate,
            wipeGate: WipeSensitiveUseGate,
        ): BoundRecipientKeyResolver = MeshModule.provideBoundRecipientKeyResolver(repo, gate, wipeGate)

        @Provides @Singleton
        fun ed25519AckAuthenticator(resolver: RecipientKeyResolver): Ed25519AckAuthenticator =
            MeshModule.provideEd25519AckAuthenticator(resolver)

        @Provides @Singleton
        fun wipeGatedAckStore(
            ackStore: SqliteAckStore,
            wipeGate: WipeSensitiveUseGate,
        ): WipeGatedAckObligationStore = MeshModule.provideWipeGatedAckStore(ackStore, wipeGate)

        @Provides @Singleton
        fun ackDriver(
            ackStore: WipeGatedAckObligationStore,
            identity: Identity,
            authenticator: Ed25519AckAuthenticator,
            resolver: RecipientKeyResolver,
        ): AckObligationDriver = MeshModule.provideAckDriver(ackStore, identity, authenticator, resolver)

        @Provides @Singleton
        fun ackPump(
            ackStore: WipeGatedAckObligationStore,
            driver: AckObligationDriver,
        ): DurableAckPump = MeshModule.provideAckPump(ackStore, driver)

        /** The UNDECORATED ack store the decorator wraps -- `provideWipeGatedAckStore` needs it. */
        @Provides @Singleton
        fun ackStore(store: SqliteMessageStore): SqliteAckStore = MeshModule.provideAckStore(store)

        @Provides @Singleton
        fun deliveryTracker(
            store: SqliteMessageStore,
            resolver: BoundRecipientKeyResolver,
        ): DeliveryTracker = MeshModule.provideDeliveryTracker(store, resolver)

        @Provides @Singleton
        fun sessionManager(
            identity: Identity,
            repo: PeerIdentityRepository,
            gate: DefaultRuntimeLifecycleGate,
            wipeGate: WipeSensitiveUseGate,
        ): SessionManager = MeshModule.provideSessionManager(identity, repo, gate, wipeGate)

        /**
         * *** THE NODE -- THE BINDING THAT MAKES THIS COMPONENT WORTH BUILDING. ***
         *
         * *`provideMeshNode` is the ONLY provider whose BODY wires the node (`ackDispatcher`, `ackPump`). A missing
         * dependency anywhere in this chain -- exactly what codegen reported twice while this file was being written
         * (`MeshNode cannot be provided`, `SqliteAckStore cannot be provided`) -- would have shipped silently, because
         * NOTHING ASSEMBLED THIS MODULE. Resolving it here is what makes those two holes compiler errors.*
         */
        @Provides @Singleton
        fun meshNode(
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
            wipeGate: WipeSensitiveUseGate,
        ): MeshNode = MeshModule.provideMeshNode(
            ctx, identity, store, deliveryTracker, sessions, pump,
            sqliteStore, ackStore, authenticator, resolver, wipeGate,
        )
    }
}
