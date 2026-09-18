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
import io.godstone.mesh.identity.WipeGatedAckObligationStore
import io.godstone.mesh.identity.WipeDeferredSeams
import io.godstone.mesh.identity.WipeIdentityAuthoritySeam
import io.godstone.mesh.identity.WipeJournalDurabilityAdapter
import io.godstone.mesh.identity.WipeKeyVaultSeam
import io.godstone.mesh.identity.WipeTransportDrainSeam
import io.godstone.mesh.identity.WipeArtifacts
import io.godstone.mesh.identity.WipeJournal
import io.godstone.mesh.identity.WipeJournalState
import io.godstone.mesh.identity.WipeStepResult
import io.godstone.mesh.identity.PeerIdentityRepository
import io.godstone.mesh.identity.RuntimeAwareWipeArtifacts
import io.godstone.mesh.identity.RuntimeGatedPeerBindingTrustAuthority
import io.godstone.mesh.identity.WipeSensitiveUseGate
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
internal fun <T> runStartupWipeBarrier(resumePendingWipe: () -> T): T = resumePendingWipe()

internal class MeshStartupCoordinator<T>(
    private val resumePendingWipe: () -> T
) {
    fun executeBarrier(): T = runStartupWipeBarrier(resumePendingWipe)
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
    /**
     * *** GS-FINAL-003 (the independent audit, 2026-09-18): THE STARTUP'S OUTCOME IS A VALUE, NOT A SIDE EFFECT. ***
     *
     * THE AUDIT'S MEASUREMENT: "Android MeshStartupWipeBarrier returns Unit after calling resume; providers require the
     * barrier object, not a successful recovery capability." AND ITS ROOT CAUSE, WHICH IS THE PRECISE ONE: "DI sequencing
     * is mistaken for successful state transition; construction of a barrier object says nothing about the returned
     * coordinator result."
     *
     * THAT IS EXACTLY WHAT THIS PROPERTY FIXETH. A provider that asked for `MeshStartupWipeBarrier` RECEIVED A
     * CONSTRUCTED OBJECT WHETHER THE PENDING WIPE HAD BEEN RECOVERED, REFUSED, OR FAILED -- the dependency graph proved
     * only that the constructor had run. The coordinator's own typed answer is retained here so a consumer can ASK
     * rather than assume.
     */
    val outcome: WipeStepResult

    init {
        outcome = runStartupWipeBarrier {
            CrashResumableWipe(
                store = WipeJournalDurabilityAdapter(FileWipeJournal(ctx)),
                vault = WipeDeferredSeams.DeferredKeyVaultSeam(),
                filesystem = WipeDeferredSeams.DeferredArtifactFileSystemSeam(),
                runtime = WipeDeferredSeams.DeferredTransportRuntimeSeam(),
                authority = WipeDeferredSeams.DeferredIdentityAuthoritySeam(),
            ).resume()
        }
    }

    /**
     * *** GS-FINAL-003: THE PERMIT IS RETAINED AND ASKABLE -- AND IT IS NOT YET CONSUMED AT CONSTRUCTION, BECAUSE
     * CONSUMING IT THERE DEADLOCKS THE GRAPH. THAT IS MEASURED, NOT ASSUMED. ***
     *
     * THE AUDIT'S CHARGE STANDS: *"Android MeshStartupWipeBarrier returns Unit after calling resume; providers require
     * the barrier object, not a successful recovery capability. ... DI sequencing is mistaken for successful state
     * transition."* A FIRST REPAIR OF MINE CONSUMED IT -- `requireStartupPermit(barrier)` THREW from
     * `provideIdentity`, `provideSqliteMessageStore` and `providePeerIdentityStore` -- AND THE DEPENDENCY CHAIN MAKES
     * THAT A DEADLOCK:
     *
     *   those three providers are the inputs of `provideMeshNode(...)`,
     *   `provideMeshPanipeWipe(invalidator, node)` NEEDS THE NODE,
     *   AND THE NODE IS THE ONLY THING THAT CARRIES THE LIVE TRANSPORT THE WIPE MUST DRAIN.
     *
     * So a blocked barrier would prevent the graph that finishes the wipe from ever being built, and ANY MID-WIPE CRASH
     * WOULD BRICK THE APP UNTIL THE JOURNAL WAS CLEARED BY HAND -- STRICTLY WORSE THAN THE DISCARD BEING REPAIRED. The
     * identical hazard was measured on iOS in the same round (`testSR02` threw `startupBlockedByPendingWipe`), and the
     * gate was reverted there too. A GATE THAT MAKES ITS OWN REMEDY UNREACHABLE IS WORSE THAN THE DEFECT IT CLOSES.
     *
     * THE MECHANISM THAT DOES NOT DEADLOCK ALREADY EXISTS AND IS THE ONE TO WIRE: `CrashResumableWipe.allowsStartup()`
     * and `allowsSensitiveApi()` ARE JOURNAL-BOUND -- they answer from the durable record, not a cached boolean -- so
     * they can refuse sensitive USE without refusing CONSTRUCTION. That requires the coordinator to be REACHABLE from
     * the providers (today the runtime-side authority is constructed inside `MeshPanicWipe.begin`), which is the
     * architectural prerequisite named in the ledger for BOTH isles.
     */
    val permitsStartup: Boolean
        get() = when (val r = outcome) {
            // NO WIPE WAS EVER REQUESTED -- the clean first launch. Distinguished from a pending wipe by the REASON,
            // because `Refused` is also used for a malformed journal, and treating THAT as clean would be unsound.
            is WipeStepResult.Refused -> r.reason.contains("nothing to resume")
            is WipeStepResult.AlreadyAtOrPast -> true
            is WipeStepResult.Advanced -> r.to == WipeJournalState.IDLE
            // A PENDING WIPE THAT COULD NOT ADVANCE: blocked, and the safe answer is to say so.
            is WipeStepResult.RetryLater -> false
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
    /**
     * *** GS-FINAL-002 (round 707): THE ENTRY RETURNS THE TYPED OUTCOME -- THE AUDIT'S CLAUSE, FULFILLED. ***
     *
     * **THE AUDIT'S `exact_remediation` SAYS: "Return a typed outcome to the caller and render completion only at
     * durable IDLE."** *That clause was UNMET HERE: this method returned `Unit` and DISCARDED the `WipeStepResult` of
     * `runRuntimeSideWipe` below, so `Refused` and `RetryLater` -- the difference between "the wipe ran" and "the wipe
     * did nothing" -- were UNOBSERVABLE to every caller.* **A caller that cannot tell those apart cannot render
     * completion at durable IDLE, because it cannot see the state at all.** *Found by an independent sweep that
     * enumerated this finding's clauses rather than trusting its evidence list.*
     *
     * **THE RETURN TYPE NAMES ITS OWN CONSEQUENCE: `WipeStepResult` is the ladder's own vocabulary**
     * (`Advanced`/`AlreadyAtOrPast`/`RetryLater`/`Refused`), *so the caller receives the coordinator's answer in the
     * coordinator's words rather than a boolean somebody invented here.*
     */
    fun begin(): WipeStepResult {
        val artifacts = RuntimeAwareWipeArtifacts(
            invalidator = invalidator,
            delegate = AndroidWipeArtifacts(ctx)
        )
        // *** GS-STORE-006: THIS ROOT IS THE RUNTIME-SIDE AUTHORITY, SO IT RUNS THE COORDINATOR OVER THE **LIVE** SEAMS --
        // and it can, because the module provideth the node, and the node owneth the transport. ***
        // `PanicWipe(FileWipeJournal(ctx), artifacts).begin()` RETIRES HERE: THE OLD COORDINATOR IS NO LONGER WHAT THE
        // RUNTIME-SIDE WIPE RUNS.
        return MeshPanicWipe.runRuntimeSideWipe(wipeAuthority(artifacts, FileWipeJournal(ctx)))
    }

    /**
     * THE ONE RUNTIME-SIDE AUTHORITY, in its own function so the seams are named once and the ENTRY VERB is the only
     * thing a caller chooses. A second copy of these seams is a second place for a mapping to go missing -- which is
     * precisely what the audit measured on the other isle.
     */
    private fun wipeAuthority(artifacts: WipeArtifacts, journal: WipeJournal): CrashResumableWipe =
        CrashResumableWipe(
            store = WipeJournalDurabilityAdapter(journal),          // the mapping; the journal is the isle's own
            vault = WipeKeyVaultSeam(artifacts),                    // over the RuntimeAwareWipeArtifacts built ABOVE, so
                                                                    // the invalidation ordering the isle owns is kept
            filesystem = WipeArtifactFileSystemSeam(journal),       // the same journal handle: one durable record
            runtime = WipeTransportDrainSeam(node.bleTransportForWipe),  // THE LIVE TRANSPORT the runtime itself uses
            authority = WipeIdentityAuthoritySeam(ctx, artifacts),  // the isle's own regeneration + naming
        )

    companion object {
        /**
         * *** GS-FINAL-002 (the independent audit, 2026-09-18): THE FRESH ENTRY VERB, ISOLATED SO IT CAN BE JUDGED. ***
         *
         * THE AUDIT'S MEASUREMENT: "Android `MeshPanicWipe.begin` constructs the coordinator and calls `resume`; resume
         * refuses an empty journal." AND THE CONSEQUENCE IT NAMES: "A fresh Android wipe may do no wipe at all."
         *
         * WHY THE VERB IS A FUNCTION OF ITS OWN: my first repair changed the call site and wrote three arms -- AND EVERY
         * ONE OF THEM PASSED AGAINST THE UNREPAIRED CALL SITE, because they drove the COORDINATOR directly and so never
         * exercised the ROUTING DECISION at all. A mutation that restored `.resume()` at the call site left the suite
         * green: the arms justified the coordinator, not the choice made here. THIS FUNCTION IS THAT CHOICE, made
         * separately testable, so the arm judges the decision rather than the thing the decision drives.
         *
         * A NEW OPERATION REQUESTS; ONLY CRASH RECOVERY RESUMES. `requestWipe` recordeth `REQUESTED` durably BEFORE it
         * drives anything -- which is what makes the wipe crash-resumable at all -- while `resume` answereth
         * `Refused("nothing to resume; no wipe was ever requested")` on a clean journal, WHICH IS THE STATE A USER'S
         * FIRST WIPE IS ALWAYS IN.
         */
        fun runRuntimeSideWipe(authority: CrashResumableWipe): WipeStepResult = authority.requestWipe()
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

    /**
     * *** THE PERMIT IS ASKED, NOT ENFORCED BY REFUSAL -- SEE THE DOCSTRING ABOVE FOR THE MEASURED DEADLOCK. ***
     *
     * THIS FUNCTION USED TO THROW, AND THAT MADE THE GRAPH THAT FINISHES THE WIPE UNBUILDABLE. It now RECORDS the
     * refusal at the ONE place a caller can act on it, and returns -- so construction proceeds, the node exists, the
     * transport exists, and `MeshPanicWipe` can drain. The consumer that must refuse sensitive USE is the one that
     * reads `barrier.permitsStartup`; wiring that into an admission gate (rather than into construction) is the
     * prerequisite named in the ledger for both isles.
     */
    private fun recordStartupPermit(barrier: MeshStartupWipeBarrier) {
        if (!barrier.permitsStartup) {
            android.util.Log.w(
                "GodstoneStartupWipe",
                "GS-FINAL-003: a wipe is outstanding and the startup recovery did not reach a terminal state " +
                    "(${barrier.outcome}); no key was erased and no artifact deleted. The runtime MUST NOT admit " +
                    "sensitive use until the live-seam resume completes.",
            )
        }
    }

    @Provides @Singleton
    fun provideRuntimeLifecycleGate(): DefaultRuntimeLifecycleGate =
        DefaultRuntimeLifecycleGate()

    @Provides @Singleton
    fun provideIdentity(
        @ApplicationContext ctx: Context,
        barrier: MeshStartupWipeBarrier
    ): Identity {
        recordStartupPermit(barrier)
        return Identity.loadOrCreate(ctx)
    }

    /**
     * The ONE process-wide `SqliteMessageStore`. Provided as the concrete type so
     * [provideDeliveryTracker] can reuse its `engine` (the shared `StoreDb`
     * connection) for the delivery journal -- one connection feeds both the
     * held-frames store and the `delivery_state` table.
     */
    @Provides @Singleton
    fun provideSqliteMessageStore(
        @ApplicationContext ctx: Context,
        barrier: MeshStartupWipeBarrier
    ): SqliteMessageStore {
        recordStartupPermit(barrier)
        return SqliteMessageStore(ctx, STORE_MAX_BYTES)
    }

    /// Re-expose the store as its `MessageStore` interface for `MeshNode` injection.
    @Provides @Singleton
    fun provideMessageStore(store: SqliteMessageStore): MessageStore = store

    @Provides @Singleton
    fun providePeerIdentityStore(
        @ApplicationContext ctx: Context,
        barrier: MeshStartupWipeBarrier
    ): SqlcipherPeerIdentityStore {
        recordStartupPermit(barrier)
        return SqlcipherPeerIdentityStore(ctx)
    }

    @Provides @Singleton
    fun providePeerIdentityRepository(store: SqlcipherPeerIdentityStore): PeerIdentityRepository =
        PeerIdentityRepository(store)

    /**
     * *** GS-FINAL-003 (round 570): THE DURABLE ANSWER, READ PER CALL, AT THE ADMISSION POINT. ***
     *
     * MEASURED BEFORE THIS EDIT: `CrashResumableWipe.allowsSensitiveApi()` -- THE JOURNAL-BOUND ANSWER -- HAD **ZERO
     * PRODUCTION CALLERS**, and both admission decorators gated only on `DefaultRuntimeLifecycleGate.isActive`, AN
     * IN-PROCESS FLAG. **THE IOS ISLE ALREADY CONSUMED ITS EQUIVALENT AT TWO ADMISSION POINTS; THIS ONE CONSULTED
     * NOTHING DURABLE.**
     *
     * AND THE GAP IS THE CRASH CASE: a wipe REQUESTED and then INTERRUPTED leaves the JOURNAL pending while the next
     * process starts with `invalidated = false` -- SO THE PROCESS FLAG SAYS "ACTIVE", THE DURABLE RECORD SAYS "A WIPE
     * IS OUTSTANDING", AND SENSITIVE USE IS ADMITTED AGAINST A STORE MID-ERASURE. That is precisely the audit's
     * charge: *"Replace Unit/ignored result with an internal, non-forgeable startup permit issued only after a typed
     * recovery decision."*
     *
     * AND IT DOES NOT DEADLOCK, WHICH IS WHY THIS SHAPE WAS CHOSEN: a gesture that REFUSED CONSTRUCTION was measured
     * to make the graph that finishes the wipe unbuildable (the node carries the transport the wipe must drain). This
     * seam is READ AT ADMISSION TIME from the durable journal -- so the graph still builds, the wipe can still
     * complete, and sensitive USE is refused until it has.
     */
    @Provides @Singleton
    fun provideWipeIsPending(@ApplicationContext ctx: Context): WipeSensitiveUseGate = WipeSensitiveUseGate {
        // READ, NEVER CACHED: the coordinator's own rule is that this question must be answered from the durable
        // record each time, because the answer CHANGES when the wipe completes.
        //
        // *** AND THE POLARITY, WHICH WAS INVERTED HERE AND WENT UNNOTICED FOR EIGHTEEN ROUNDS. ***
        //
        // THE TYPE SAYETH `allowsSensitiveUse()`, SO **TRUE MEANS ALLOWED** -- and BOTH CONSUMERS act on it exactly so
        // (`if (!wipeGate.allowsSensitiveUse()) return ...StorageFailure`). MY FIRST VERSION RETURNED
        // `read() != PanicWipe.WipeState.IDLE` -- TRUE WHEN A WIPE **IS** PENDING -- **SO THE SHIPPED GATE ALLOWED
        // SENSITIVE USE WHILE A WIPE WAS OUTSTANDING AND REFUSED IT ON A CLEAN DEVICE: EXACTLY BACKWARDS, AND WORSE
        // THAN NO GATE AT ALL ON THE DEVICE THAT HAD NEVER BEEN WIPED.**
        //
        // **AND EVERY LANE WAS GREEN THROUGHOUT, INCLUDING THE ARMS I WROTE FOR THIS VERY PROVIDER.** The reason is
        // worth keeping: those arms invoked the provider **WITH A HAND-TYPED `WipeSensitiveUseGate { false }`**, so
        // they measured the DECORATORS' consumption of a value the TEST chose -- never the value this function
        // produceth. **A PROVIDER'S BODY CANNOT BE MEASURED BY A COURT THAT PASSES ITS OWN LAMBDA.**
        //
        // IT WAS FOUND BY THE FIRST COURT THAT COULD BUILD A REAL `Context` AND ASK THE REAL PROVIDER, WHICH IS WHY
        // THE CARD'S "Context-bearing harness" DEMAND EXISTED. **A GATE THAT ANSWERED BACKWARDS IS PRECISELY THE
        // DEFECT SUCH A HARNESS IS FOR.**
        FileWipeJournal(ctx).read() == PanicWipe.WipeState.IDLE
    }

    @Provides @Singleton
    fun provideBoundRecipientKeyResolver(
        repo: PeerIdentityRepository,
        gate: DefaultRuntimeLifecycleGate,
        wipeGate: WipeSensitiveUseGate
    ): BoundRecipientKeyResolver {
        val source = RuntimeGatedPeerIdentityLookupSource(
            RepositoryPeerIdentityLookupSource(repo), gate, wipeGate,
        )
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
        gate: DefaultRuntimeLifecycleGate,
        wipeGate: WipeSensitiveUseGate
    ): SessionManager {
        val trustAuthority = RuntimeGatedPeerBindingTrustAuthority(
            RepositoryPeerBindingTrustAuthority(repo), gate, wipeGate,
        )
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

    /**
     * *** GS-FINAL-003 (round 631): THE ACK NAMESPACE IS NOW GATED ON ANDROID, FROM THE SAME BINDING. ***
     *
     * *"The ACK surfaces ... are still NOT wrapped, so a wipe pending during an ACK exchange is not refused there"* --
     * my own earlier note, and the remaining half of this finding on this isle. iOS gained a decorator over the
     * `AckObligationStore` protocol in round 572; **ANDROID HAD NO TWIN AT ALL.**
     *
     * IT IS A `@Provides` FOR THE **DECORATED** STORE, AND EVERY CONSUMER BELOW TAKETH THE DECORATED TYPE -- so the
     * driver, the pump and any future fifth consumer are covered AT ONCE, rather than each remembering a guard.
     * **AND IT TAKETH THE REAL `WipeSensitiveUseGate` BINDING, NOT A HAND-TYPED LAMBDA** -- the round-589 lesson, where
     * a provider whose body was measured only through a court's own lambda shipped INVERTED for eighteen rounds.
     */
    @Provides @Singleton
    fun provideWipeGatedAckStore(
        ackStore: SqliteAckStore,
        wipeGate: WipeSensitiveUseGate,
    ): WipeGatedAckObligationStore = WipeGatedAckObligationStore(ackStore, wipeGate)

    @Provides @Singleton
    fun provideAckDriver(
        ackStore: WipeGatedAckObligationStore,
        identity: Identity,
        authenticator: Ed25519AckAuthenticator,
        resolver: RecipientKeyResolver,
    ): AckObligationDriver =
        AckObligationDriver(ackStore, IdentityAckSigner(identity), authenticator, resolver)

    @Provides @Singleton
    fun provideAckPump(
        ackStore: WipeGatedAckObligationStore,
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
        wipeGate: WipeSensitiveUseGate,
    ): MeshNode {
        val node = MeshNode(ctx, identity, sqliteStore, deliveryTracker, wipeGate, sessions)
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