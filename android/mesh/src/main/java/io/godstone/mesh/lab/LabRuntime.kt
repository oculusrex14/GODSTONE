package io.godstone.mesh.lab

import io.godstone.mesh.SosCommand
import io.godstone.mesh.SosCommandResult
import io.godstone.mesh.delivery.DeliveryLookup
import io.godstone.mesh.delivery.DeliveryState
import io.godstone.mesh.runtime.ComposedOutcome
import io.godstone.mesh.runtime.ComposedRuntimeHarness
import io.godstone.mesh.runtime.FixedHostClock
import io.godstone.mesh.runtime.LinkFacade
import java.security.SecureRandom

// ---------------------------------------------------------------------------
// T54 -- the LabMesh runtime seam, living INSIDE the nonshipping :mesh module.
//
// It liveth here rather than in the lab application module for one honest
// reason: the composed runtime is built from authorities that are `internal` to
// :mesh, and publishing them all would widen a nonshipping-but-delicate surface
// for the convenience of a lab. So the lab ENTRY is a small PUBLIC handle with a
// deliberately narrow surface -- labels, an honest readiness statement, a durable
// state NAME -- and everything else (the store, the tracker, the inbox, the ACK
// authority) stayeth inside.
//
// Law 1: THE LAB COMPOSETH REAL COMPONENTS. Each node is the production
// [io.godstone.mesh.MeshNode] over the real router, the real durable store, the
// real [io.godstone.mesh.delivery.DeliveryTracker], the real recipient inbox and
// the real T84 ACK authority, reached through T44's harness. There is no lab twin
// and no stub answering in their place.
//
// Law 2: THE LAB CANNOT MANUFACTURE READINESS. There is no setter, no override
// and no flag writer: [LabProfile.MANUFACTURES_READINESS] is a compile-time
// `false`, [readinessStatement] carrieth no parameter, and the platform readiness
// flags stay false. `ci/check_lab_isolation.py` asserteth all three.
//
// Law 3: THE LAB IS VISIBLY EXPERIMENTAL AND NONSHIPPING.
//
// Nonshipping: :mesh is outside the LIGHT Archive-only graph, and the lab
// application (io.godstone.labmesh) is a separate target with its own identity.
// ---------------------------------------------------------------------------

/** What the lab reporteth about itself, in one place. */
object LabProfile {
    const val NAME: String = "LABMESH"
    const val EXPERIMENTAL: Boolean = true

    /**
     * True iff this build can manufacture crypto readiness. It CANNOT, and the
     * constant is `false` so a reader -- and the profile gate -- seeth the claim
     * rather than inferring it from the absence of a setter.
     */
    const val MANUFACTURES_READINESS: Boolean = false

    /** The shipping application identity the lab may never masquerade as. */
    const val SHIPPING_APPLICATION_ID: String = "io.godstone.app"

    /** The lab's own application identity, distinct from the shipping one. */
    const val LAB_APPLICATION_ID: String = "io.godstone.labmesh"
}

/** The honest readiness statement: every platform field is FALSE. */
data class LabReadiness(
    val androidLinkLayerReady: Boolean,
    val iosLinkLayerReady: Boolean,
    val profile: String,
    val experimental: Boolean,
)

/**
 * The outcome of one directed send, with the `msg_id` THE DURABLE ENQUEUE COMMITTED.
 *
 * [detail] is the composition's own verdict text; [msgId] is null exactly when nothing was durably committed, so a
 * caller cannot render an id an estate never carried.
 */
data class DirectSendResult(
    val detail: String,
    val msgId: ByteArray?,
    val committed: Boolean,
) {
    override fun equals(other: Any?): Boolean = other is DirectSendResult &&
        other.detail == detail && other.committed == committed &&
        ((other.msgId == null && msgId == null) || (other.msgId != null && msgId != null && other.msgId.contentEquals(msgId)))

    override fun hashCode(): Int = 31 * (31 * detail.hashCode() + (msgId?.contentHashCode() ?: 0)) + committed.hashCode()
}

/**
 * The lab runtime handle. [compose] buildeth real composed peers over a
 * deterministic clock and a recording radio; the caller then driveth REAL product
 * flows (author, dispatch, relay, inbox, ACK) against them exactly as the T44
 * court doth.
 */
class LabRuntime private constructor(
    private val harness: ComposedRuntimeHarness,
    val labels: List<String>,
    /**
     * *** GS-FINAL-003 `same-estate`: THE ESTATE OWNER THIS RUNTIME WAS COMPOSED OVER -- WHEN THERE IS ONE. ***
     *
     * *A resource-model runtime owns no files, so this is null and `retireLiveOwners()` returneth the harness's own
     * count. A launchable runtime carries the REAL `ProductionLabEstate`, so the wipe reaches THE SAME files the send
     * road wrote -- which is the whole A6 clause.*
     */
    internal val estateAuthority: LabEstateWipeAuthority? = null,
) : io.godstone.mesh.runtime.ComposedEstateOwnership {
    /**
     * *** DRAIN AND RETIRE THE LIVE OWNER -- THE REAL ONE WHEN THERE IS ONE. ***
     *
     * *The harness half closes the composition's own admission (so every later send/publish is refused BY THE SAME
     * COMPOSITION the message road used); the ESTATE half then retires the ACK namespace, closes the store and peer
     * handles and removes the estate's own bytes -- RETURNING A COUNT so "nothing was retired" is a measurement.*
     */
    override fun retireLiveOwners(): Int {
        val composed = harness.retireLiveOwners()
        val owned = estateAuthority?.retireAndClose() ?: 0
        return composed + owned
    }

    override fun ownedArtifactPaths(): List<String> =
        estateAuthority?.ownedArtifactPaths() ?: harness.ownedArtifactPaths()

    /**
     * *** A RETIRED ESTATE CARRIETH NOTHING -- AND SAYETH SO RATHER THAN THROWING. ***
     *
     * *When [retireLiveOwners] has drained and closed the estate (the wipe's "old work refused" half), the store and
     * ledger handles are CLOSED and the bytes removed -- so a read that still walked them would raise a storage fault
     * from a medium the wipe deliberately took away.* **The honest answer of a retired estate is the SAME one a cold
     * process gives: no message, no label, no standing call.** *This is the flag the composition's OWN send road
     * consults, so the reads and the writes agree about which estate this is.*
     */
    private fun retired(): Boolean = harness.isWiped()

    /** The durable state of one message, or null when the estate carrieth none (or was retired). */
    fun durableStateOf(nodeLabel: String, msgId: ByteArray): DeliveryState? {
        if (retired()) return null
        val node = harness.node(nodeLabel) ?: return null
        return (node.tracker.lookup(msgId) as? DeliveryLookup.Found)?.record?.state
    }

    /**
     * *** THE AUTHOR'S DURABLE MESSAGE ID, READ FROM THE STORE -- THE WITNESS A VIEW STRING IS NOT. ***
     *
     * *A rendered outcome line is a CLAIM; the held frame's `msg_id` is the SOURCE. A journey that rendered a string it
     * remembered would pass a text-only court while the durable estate carried nothing, so the screen's message id is
     * read HERE, from the same store the ACK authority and the relay read.*
     */
    suspend fun heldMsgIdOf(nodeLabel: String): ByteArray? =
        if (retired()) null else harness.node(nodeLabel)?.store?.allHeldMsgIds()?.lastOrNull()

    /** Every msg_id the named node's durable estate carrieth. */
    suspend fun heldMsgIdsOf(nodeLabel: String): List<ByteArray> =
        if (retired()) emptyList() else harness.node(nodeLabel)?.store?.allHeldMsgIds()?.map { it.copyOf() } ?: emptyList()

    /** The honest label the durable row supporteth, or null when the estate carrieth no row. */
    fun deliveryLabelOf(nodeLabel: String, msgId: ByteArray): String? {
        if (retired()) return null
        val node = harness.node(nodeLabel) ?: return null
        val projection = node.node.deliveryProjection(msgId)
        return projection.label.name
    }

    /** How many messages the named node durably holdeth. */
    suspend fun heldCount(nodeLabel: String): Int =
        if (retired()) 0 else harness.node(nodeLabel)?.store?.allHeldMsgIds()?.size ?: 0

    /**
     * *** GS-UX-001 `rendered-controls`: THE DIRECTED SEND, WITH THE MESSAGE ID THE AUTHORITY MINTED. ***
     *
     * *The screen must render the ID THE RUNTIME OWNS rather than one it invented, so the send returneth the `msg_id` the
     * durable enqueue committed (or null when nothing was committed). The rendered id is then a READ, which is what
     * maketh a view-local string unable to satisfy the journey arm.*
     */
    suspend fun sendDirectResult(from: String, recipient: String, plaintext: ByteArray): DirectSendResult {
        val before = if (retired()) emptySet() else
            harness.node(from)?.store?.allHeldMsgIds()?.map { it.toList() }?.toSet() ?: emptySet()
        val outcome = harness.sendDirect(from, recipient, plaintext)
        val after = if (retired()) emptyList() else harness.node(from)?.store?.allHeldMsgIds() ?: emptyList()
        val minted = after.lastOrNull { it.toList() !in before }
        return DirectSendResult(describe(outcome), minted?.copyOf(), minted != null)
    }

    /**
     * *** THE SOS COMMAND DOOR, BOUND TO THE NODE'S OWN `handleSosCommand`. ***
     *
     * *The iOS twin bindeth the same command surface (`harness.sosCommand`); this isle's arm is the node's own, so the
     * arm and the cancel road route through ONE authority rather than a second SOS state machine.*
     */
    suspend fun sosCommand(from: String, command: SosCommand): SosCommandResult? {
        val node = harness.node(from) ?: return null
        return node.node.handleSosCommand(command) { peerId, bytes ->
            sendOpaque(node, peerId, bytes)
        }
    }

    /** The active SOS projection from the DURABLE row, or null when no call standeth. */
    suspend fun activeSosStateOf(nodeLabel: String): DeliveryState? {
        val node = harness.node(nodeLabel) ?: return null
        return node.node.activeSosSnapshot()?.state
    }

    /** The `msg_id` of the standing distress call, read from the durable projection. */
    suspend fun activeSosMsgIdOf(nodeLabel: String): ByteArray? {
        val node = harness.node(nodeLabel) ?: return null
        return node.node.activeSosSnapshot()?.msgId?.copyOf()
    }

    /** Author one DIRECT message at [from] FOR [recipient]. */
    suspend fun sendDirect(from: String, recipient: String, plaintext: ByteArray): String =
        describe(harness.sendDirect(from, recipient, plaintext))

    /** Author one SOS broadcast at [from] to every linked peer. */
    suspend fun sendSos(from: String, plaintext: ByteArray): String =
        describe(harness.sendSos(from, plaintext))

    /** One bounded sync turn from [from] to [to]. */
    suspend fun turn(from: String, to: String): Int = harness.turn(from, to)

    /** Carry [from]'s queued ACK traffic to [to]. */
    suspend fun turnAcks(from: String, to: String): Int = harness.turnAcks(from, to)

    /** A trusted relation comes up (both layers). */
    fun link(from: String, to: String): String = describe(harness.link(from, to))

    /** A trusted relation goes down (both layers). */
    fun unlink(from: String, to: String): String = describe(harness.unlink(from, to))

    /** The exact bytes a link carried, so a caller can search them. */
    fun capturedBytes(): List<ByteArray> = harness.capturedBytes()

    /** How many link hand-offs were admitted. */
    fun admittedCount(): Int = harness.link.admitted()

    /**
     * *** ONE LINK HAND-OFF THROUGH THE COMPOSITION'S OWN RADIO, ON THE SOS COMMAND ROAD. ***
     *
     * *`ComposedRuntimeHarness.send` is private, so this mirrors the composition's hand-off through the harness's PUBLIC
     * recorder (`harness.link`) and the receiving node's own `ingestInbound` statute -- the same two steps the harness
     * taketh, and never a synthetic receive.*
     */
    private suspend fun sendOpaque(node: io.godstone.mesh.runtime.ComposedNode, peerId: ByteArray, bytes: ByteArray): Boolean {
        val toLabel = labels.firstOrNull { harness.node(it)?.nodeId?.contentEquals(peerId) == true }
            ?: return false
        val admitted = harness.link.offer(node.label, toLabel, bytes)
        if (admitted) {
            io.godstone.mesh.wire.v2.FrameV2.decode(bytes)?.let { harness.node(toLabel)?.node?.ingestInbound(it, node.nodeId) }
        }
        return admitted
    }

    private fun describe(outcome: ComposedOutcome): String = when (outcome) {
        is ComposedOutcome.Applied -> "applied:" + outcome.detail
        is ComposedOutcome.Refused -> "refused:" + outcome.reason.name +
            outcome.detail.takeIf { it.isNotEmpty() }?.let { "/" + it } .orEmpty()
    }

    companion object {
        /**
         * *** GS-FINAL-003 `same-estate` (review A6): THE HOST/RESOURCE-MODEL COMPOSITION, AND IT SAYS SO. ***
         *
         * *A COMPOSITION THAT OWNS NO DURABLE ESTATE CANNOT ANSWER "MAY PRIVATE CONSTRUCTION PROCEED" -- so this road
         * binds the PURE-HOST ALLOWANCE EXPLICITLY.* **IT IS NAMED `composeForHostTests` SO THAT NO APPLICATION PATH CAN
         * USE IT BY ACCIDENT: the launchable lab application calls [composeRealEstate], which consults the SAME-ESTATE
         * RECOVERY OWNER over its own `Context` before it composes anything.**
         *
         * *Every T44 court drives this road, and the resource model it buildeth (in-memory stores, a fixed clock, a
         * recording radio) is what those courts measure. The allowance is a visible act at ONE line rather than an
         * ambient default, which is the difference between a documented boundary and the defect review A6 found.*
         */
        fun composeForHostTests(labels: List<String> = listOf("A", "R", "B"),
                    rng: SecureRandom = SecureRandom()): LabRuntime {
            require(labels.size >= 2) { "a lab runtime needs at least two peers" }
            require(labels.distinct().size == labels.size) { "lab labels must be distinct" }
            val clock = FixedHostClock()
            val harness = ComposedRuntimeHarness(clock = clock, link = LinkFacade(clock), rng = rng)
            harness.admitNormalEstate = io.godstone.mesh.runtime.NormalEstateGate.Testing
            for (label in labels) harness.addNode(label)
            for (i in 0 until labels.size - 1) harness.link(labels[i], labels[i + 1])
            return LabRuntime(harness, labels.toList())
        }

        /**
         * *** GS-FINAL-003 `same-estate` (review A6/A6-expanded): THE LAUNCHABLE COMPOSITION, OVER THE REAL OWNER. ***
         *
         * *THE REVIEW'S CHARGE, VERBATIM: **"The supposedly host-only always-admit helper is on the actual launchable
         * lab path ... the real LabMeshApplication reaches it ... A persisted lab REQUESTED/corrupt journal is never
         * consulted by this bootstrap."***
         *
         * *** SO THIS IS THE ROAD THE APPLICATION TAKES, AND IT CONSULTS THE RECOVERY OWNER BEFORE THE FIRST EFFECT: ***
         *
         *   * the SAME-ESTATE gate is derived from the PRODUCTION recovery decision over THIS `Context`'s own
         *     `FileWipeJournal` (`StartupRecoveryGraph.decisionAtRest(...).allowsPrivateConstruction`), which is the
         *     SAME reading the startup barrier and the private-store permit use;
         *   * a REQUESTED/corrupt/terminal estate therefore REFUSES **before** a single identity, store, ACK row or peer
         *     node is created -- and [composeRealEstateOrRefuse] turns that refusal into a TYPED answer a surface can
         *     render rather than an exception.
         *
         * *** AND THE ESTATE IS ON DISK, UNDER THE CALLER'S OWN DIRECTORY. *** *`estateRoot` is where this composition's
         * identity material, message database and trust store live, so the wipe's [retireLiveOwners] and the rendered
         * journey address the SAME bytes a send wrote -- never a cwd alias and never a second, in-memory estate beside a
         * real one.*
         */
        fun composeRealEstate(
            ctx: android.content.Context,
            estate: LabEstateWipeAuthority,
            labels: List<String> = listOf("A", "R", "B"),
            rng: SecureRandom = SecureRandom(),
        ): LabRuntime = composeRealEstateOrRefuse(ctx, estate, labels, rng).runtime
            ?: throw io.godstone.mesh.runtime.ComposedRuntimeHarness.NormalEstateRefused(
                labels.firstOrNull() ?: "lab",
                "the same-estate recovery owner refused normal private composition",
            )

        /**
         * *** THE REFUSAL, AS A VALUE -- SO THE APPLICATION CAN RENDER A RECOVERY-ONLY SURFACE. ***
         *
         * *A bootstrap that THREW on a refused estate would leave the user with a dead process and no words; the
         * obligation asketh for a RENDERED recovery-only projection instead (review A6/A7).* **This returns the typed
         * refusal beside the (absent) runtime, and the caller renders the recovery owner's own decision.**
         *
         * *** AND THE ESTATE IS A REQUIRED CAPABILITY RATHER THAN A NULLABLE CONVENIENCE. *** *THE REVIEW'S A6 SHAPE
         * WAS EXACTLY A REAL-CONTEXT WIPE BESIDE AN IN-MEMORY SEND ROAD: a default of "no estate" here would rebuild
         * that defect one step removed, so **THE LAUNCHABLE ROAD CANNOT BE ASKED WITHOUT NAMING THE OWNER WHOSE FILES
         * THE SEND AND THE WIPE BOTH ADDRESS.*** A pure-host resource model useth [composeForHostTests], WHICH IS NAMED
         * FOR IT AND CARRIETH THE EXPLICIT ALLOWANCE.
         */
        fun composeRealEstateOrRefuse(
            ctx: android.content.Context,
            estate: LabEstateWipeAuthority,
            labels: List<String> = listOf("A", "R", "B"),
            rng: SecureRandom = SecureRandom(),
        ): RealEstateComposition {
            require(labels.size >= 2) { "a lab runtime needs at least two peers" }
            require(labels.distinct().size == labels.size) { "lab labels must be distinct" }
            // *** THE SAME-ESTATE QUESTION, ASKED OF THE PRODUCTION OWNER OVER THIS CONTEXT. ***
            val gate = sameEstateGate(ctx)
            val clock = FixedHostClock()
            val harness = ComposedRuntimeHarness(clock = clock, link = LinkFacade(clock), rng = rng)
            harness.admitNormalEstate = gate
            harness.estate = estate
            val refused = try {
                for (label in labels) harness.addNode(label)
                for (i in 0 until labels.size - 1) harness.link(labels[i], labels[i + 1])
                null
            } catch (e: io.godstone.mesh.runtime.ComposedRuntimeHarness.NormalEstateRefused) {
                e
            }
            if (refused != null) return RealEstateComposition(null, refused.label, refused.reason, gate)
            return RealEstateComposition(LabRuntime(harness, labels.toList(), estate), null, null, gate)
        }

        /**
         * *** THE SAME-ESTATE GATE ITSELF: ONE READING OF THE DURABLE RECORD, THE ONE THE BARRIER USES. ***
         *
         * *`StartupRecoveryGraph.decisionAtRest` is the PRODUCTION mapping over the isle's own `FileWipeJournal`, so the
         * answer a bootstrap gets and the answer the startup barrier gets are two readings of ONE decision function --
         * never two authorities.* **This is what maketh "the app consults the recovery owner before it composes" a fact
         * about the code.**
         *
         * *The decision is read ON EVERY ADMISSION (`NormalEstateGate.admit()` is called once per node), so an estate
         * that a wipe requested between two nodes refuses the SECOND node rather than a cached answer.*
         */
        fun sameEstateGate(ctx: android.content.Context): io.godstone.mesh.runtime.NormalEstateGate =
            io.godstone.mesh.runtime.NormalEstateGate {
                val decision = io.godstone.mesh.di.StartupRecoveryGraph
                    .decisionAtRest(io.godstone.mesh.identity.FileWipeJournal(ctx))
                if (decision.allowsPrivateConstruction) {
                    io.godstone.mesh.runtime.NormalEstateVerdict.Admitted
                } else {
                    io.godstone.mesh.runtime.NormalEstateVerdict.Refused(
                        "the durable recovery record decided ${decision.wireName}: a normal private estate may " +
                            "not be composed until the wipe is resolved",
                    )
                }
            }

        /** The honest readiness statement. It carrieth no parameter, so no caller
         *  can argue it into saying true. */
        fun readinessStatement(): LabReadiness = LabReadiness(
            androidLinkLayerReady = false,
            iosLinkLayerReady = false,
            profile = LabProfile.NAME,
            experimental = LabProfile.EXPERIMENTAL,
        )
    }
}

/**
 * *** GS-FINAL-003 `same-estate`: WHAT A REAL-ESTATE COMPOSITION RETURNETH -- A RUNTIME, OR A TYPED REFUSAL. ***
 *
 * *Exactly one of [runtime]/[refusalReason] is non-null, so a caller cannot render a composition that was refused and
 * cannot ignore one that was. The [gate] is retained so a surface can ask the SAME question the bootstrap asked.*
 */
class RealEstateComposition internal constructor(
    /** The composed runtime, when the same-estate owner ADMITTED the composition. */
    val runtime: LabRuntime?,
    /** The label whose composition was refused, when it was. */
    val refusedLabel: String?,
    /** WHY it was refused, in the recovery owner's own words. */
    val refusalReason: String?,
    /** The same-estate gate this composition consulted, retained for a surface to re-ask. */
    val gate: io.godstone.mesh.runtime.NormalEstateGate,
) {
    val admitted: Boolean get() = runtime != null
}

/**
 * *** GS-FINAL-003 `same-estate` (review A6): THE LAB ESTATE'S OWN WIPE-REACHABLE SURFACE. ***
 *
 * *THE OBLIGATION: **"Begin wipe must drain/retire actual live owner and same key/message/peer/intent/ACK estate, old
 * work refused, resume/relaunch uses same estate."*** **A ladder driven over the DEFAULT context seams deleted
 * `godstone_messages.db` at the application's own path while the lab's real estate lived under a per-label directory --
 * so `ARTIFACTS_DELETED` was a claim about files nobody wrote (A5), and "the wipe retired the live estate" was false
 * (A6).**
 *
 * *** THIS INTERFACE IS THE ESTATE'S OWN ANSWER TO BOTH, AND IT EXTENDETH THE COMPOSITION'S OWN FACTORY SURFACE: ***
 * *[retireAndClose] drains and counts the owners it opened; [destroyFamily]/[familyExists] resolve a logical wipe name
 * to THIS estate's concrete files and take the verdict over the survivors; [eraseIdentityFamily] and
 * [publishFreshIdentity] are the recovery-only identity rung.* **Because it IS the composition's
 * [io.godstone.mesh.runtime.ComposedEstateFactories], the owners the send road used and the bytes the wipe eraseth are
 * the SAME object -- which is what maketh "same estate" a property of the graph rather than of a comment.**
 */
interface LabEstateWipeAuthority : io.godstone.mesh.runtime.ComposedEstateFactories {
    /** Drain/close every live owner this estate opened, then count them, so "nothing was retired" is measurable. */
    fun retireAndClose(): Int

    /** *Delete and VERIFY this estate's own files for one logical wipe family; `Absent` when it owned none.* */
    fun destroyFamily(logicalName: String): io.godstone.mesh.identity.FileDeletionResult

    /** *Whether this estate still owneth any file of that family -- the question `exists` must answer.* */
    fun familyExists(logicalName: String): Boolean

    /** *Erase and VERIFY every label's identity material: preferences, AndroidX keyset and backups.* */
    fun eraseIdentityFamily(): Boolean

    /** *Regenerate a fresh identity through the recovery-only factory, named by its node hint, or null.* */
    fun publishFreshIdentity(): String?
}

/**
 * *** GS-FINAL-003 `same-estate`: THE PLATFORM BOUNDARY THE LAB ESTATE STANDS ON, NAMED RATHER THAN IMPLIED. ***
 *
 * *The production owners need exactly two on-device facilities: the AndroidKeyStore-backed identity factory (whose
 * `EncryptedSharedPreferences` a host lacketh) and the SQLCipher native engine (whose `.so` a JVM lacketh).* **EVERY
 * OTHER THING THIS ESTATE DOTH -- the durable permit, the per-label context view, the real file resolution, the
 * retirement, the verification -- is the estate's own and is NOT substitutable.** *A host proof therefore substitutes
 * THESE TWO DOORS ALONE, and it must supply its OWN temp on-disk database and files -- never an in-memory stand-in --
 * and label itself host rather than physical.*
 */
interface LabEstatePlatform {
    /** Load or create the label's identity, consuming the same-estate owner token. */
    fun identityFor(labelCtx: android.content.Context, token: io.godstone.mesh.identity.PrivateOwnerToken): io.godstone.mesh.identity.Identity

    /**
     * Open the label's durable message store over the estate's own context view.
     *
     * *The return type is the CONCRETE durable store rather than the message interface, deliberately: the ACK namespace
     * must stand on this store's own engine, and the estate must be able to CLOSE the handle before it erases the bytes.
     * A platform that could not supply both would leave the estate unable to retire what it opened.*
     */
    fun storeFor(
        labelCtx: android.content.Context,
        token: io.godstone.mesh.identity.PrivateOwnerToken,
        maxBytes: Long,
    ): io.godstone.mesh.store.SqliteMessageStore
}

/**
 * *** THE DEVICE'S OWN DOORS: THE PRODUCTION FACTORY AND THE PRODUCTION SQLCIPHER ENGINE, UNCHANGED. ***
 *
 * *This is the object the launchable lab application uses; nothing about it is a fake. A host proof supplies its own
 * [LabEstatePlatform] and SAYS so, and the estate's own file resolution, retirement and verification are the SAME code
 * on both roads.*
 */
object ProductionLabPlatform : LabEstatePlatform {
    override fun identityFor(
        labelCtx: android.content.Context,
        token: io.godstone.mesh.identity.PrivateOwnerToken,
    ): io.godstone.mesh.identity.Identity = io.godstone.mesh.identity.Identity.loadOrCreate(labelCtx, token)

    override fun storeFor(
        labelCtx: android.content.Context,
        token: io.godstone.mesh.identity.PrivateOwnerToken,
        maxBytes: Long,
    ): io.godstone.mesh.store.SqliteMessageStore =
        io.godstone.mesh.store.SqliteMessageStore(labelCtx, maxBytes, token)
}

/**
 * *** GS-FINAL-003 `same-estate`: THE PRODUCTION-OWNER ESTATE, OVER THE APPLICATION'S OWN `Context`. ***
 *
 * *THE REVIEW'S A6-EXPANDED CHARGE: the bootstrap created "actual private signing/DH identities, message stores, ACK
 * stores and normal MeshNode peers" **while a separate rendered wipe reported a pending or corrupt record.*** **SO THIS
 * ESTATE IS THE PRODUCTION OWNERS THEMSELVES, REACHED ONLY THROUGH A CONSUMED PERMIT:**
 *
 *   * **the PERMIT** is minted by the ONE `EstateAuthority` over the application's own durable `FileWipeJournal`, and it
 *     is **re-validated at every construction** (`requireLiveFor`) -- so a wipe requested underneath this estate cannot
 *     admit a later store, and no raw owner constructor is reachable from here without it (review A13);
 *   * **the IDENTITY** and the **MESSAGE STORE** come from [LabEstatePlatform], which defaulteth to the device's own
 *     doors (`Identity.loadOrCreate(labelCtx, token)`, `SqliteMessageStore(labelCtx, maxBytes, token)`);
 *   * **the ACK NAMESPACE** is `SqliteAckStore(store.engine)` -- the SAME connection and the SAME ACK tables;
 *   * **the INTENT LEDGER** is a real `SQLiteOpenHelper` on the label's own disk, so a retry across a relaunch loadeth
 *     the SAME authored bytes;
 *   * **the PEER-TRUST STORE** is a real `SqlcipherPeerIdentityStore(labelCtx, token)`.
 *
 * *** AND EVERY LABEL OWNS ITS OWN REAL FILES, WHICH IS THE HONEST HALF OF A MULTI-ROLE LAB ESTATE. *** *The lab
 * composes several roles (the author, the relay, the recipient) on ONE device, and a "node" cannot share another node's
 * key material or message database without the composition becoming a fiction. **The estate therefore gives each label
 * a REAL `Context` view ([LabLabelContext]) whose database path and preferences are its own** -- `getDatabasePath` is
 * redirected under `filesDir/labmesh/<label>/` and every preference name is prefixed -- so the production engine, the
 * production identity factory and the production peer store all run UNCHANGED, each over the label's own bytes.*
 *
 * *** AND [retireAndClose] IS THE "OLD WORK REFUSED" HALF: *** *it retires the ACK namespace (`deleteAllFrames`),
 * closes the message store's engine and the peer store, and DELETES this estate's own files -- databases, their
 * sidecars, the intent ledger and the preference files -- returning a COUNT so "nothing was retired" is a measurement.
 * **A writer that kept a handle across the erasure would be the "same-estate" violation one layer down, so the handles
 * are closed BEFORE the bytes are removed.**
 */
class ProductionLabEstate(
    private val ctx: android.content.Context,
    private val labels: List<String> = LABELS,
    /**
     * *** THE NAMED SUBSTITUTION POINT. *** *Default is the device's own doors; a host proof passes its own temp-dir
     * platform and labelleth itself host. The estate's permit, file resolution and verification are never substituted.*
     */
    private val platform: LabEstatePlatform = ProductionLabPlatform,
) : io.godstone.mesh.runtime.ComposedEstateFactories, LabEstateWipeAuthority {

    /** The one durable record this estate admits against, plus the one owner that serializes it. */
    private val journal: io.godstone.mesh.identity.WipeJournal =
        io.godstone.mesh.identity.FileWipeJournal(ctx)

    private val authority: io.godstone.mesh.di.EstateAuthority =
        io.godstone.mesh.di.EstateAuthority.over(
            journal,
            io.godstone.mesh.di.StartupRecoveryGraph.prePrivate(ctx, journal),
        )

    /**
     * *** THE PERMIT AND ITS CONSUMPTION TOKEN, ASKED LAZILY SO A REFUSED ESTATE TOUCHES NOTHING. ***
     *
     * *The bootstrap asks the same-estate gate BEFORE it asks this estate for any owner, so a REQUESTED/corrupt record
     * throws `NormalEstateRefused` and this lazy never runs -- exactly zero private effects.* **When it DOES run, the
     * permit names the decision the authority computed and the durable revision it was judged at, and every raw
     * construction consumes the token through `requireLiveFor`, which re-reads the record at that instant.**
     */
    private val permit: io.godstone.mesh.di.PrivateStorePermit by lazy {
        requireNotNull(authority.issueCurrentPermit()) {
            "GS-FINAL-003: the estate authority decided ${authority.decisionAtRest().wireName}; no normal private " +
                "owner may be constructed over this estate"
        }
    }

    private val token: io.godstone.mesh.identity.PrivateOwnerToken by lazy {
        io.godstone.mesh.identity.PrivateOwnerToken.forNormalConstruction(permit)
    }

    /** *Re-validated at EVERY construction: a permit minted before a wipe cannot admit construction after it.* */
    private fun consume(): io.godstone.mesh.identity.PrivateOwnerToken =
        permit.requireLiveFor(authority.revision().wire, token)

    /** The per-label REAL context view: its own database directory and its own preference names. */
    private fun labelContext(label: String) = LabLabelContext(ctx, label)

    private val identities = java.util.concurrent.ConcurrentHashMap<String, io.godstone.mesh.identity.Identity>()
    private val stores = java.util.concurrent.ConcurrentHashMap<String, io.godstone.mesh.store.SqliteMessageStore>()
    private val ackStores = java.util.concurrent.ConcurrentHashMap<String, io.godstone.mesh.delivery.SqliteAckStore>()
    private val peerStores =
        java.util.concurrent.ConcurrentHashMap<String, io.godstone.mesh.identity.SqlcipherPeerIdentityStore>()

    /** *Each label's durable intent ledger, opened on the label's own context view.* */
    private val intentLedgers =
        java.util.concurrent.ConcurrentHashMap<String, io.godstone.mesh.delivery.OutboundIntentJournal>()

    /** *The operator's own trust selection per node id, so revocation is REAL estate state rather than a parameter.* */
    private val peerTrust =
        java.util.concurrent.ConcurrentHashMap<List<Byte>, io.godstone.mesh.runtime.ComposedPeerTrust>()

    override fun identityFor(label: String): io.godstone.mesh.identity.Identity =
        identities.getOrPut(label) { platform.identityFor(labelContext(label), consume()) }

    override fun storeFor(label: String): io.godstone.mesh.store.MessageStore =
        stores.getOrPut(label) { platform.storeFor(labelContext(label), consume(), MAX_BYTES) }

    /**
     * *The ACK namespace standeth on the SAME durable engine as the message store -- `SqliteAckStore(store.engine)`,
     * exactly as `MeshModule.provideAckStore` builds it, so a wipe taketh the ACK rows with the database rather than
     * leaving a second store behind.*
     */
    override fun ackStoreFor(label: String): io.godstone.mesh.delivery.AckObligationStore =
        ackStores.getOrPut(label) {
            val concrete = stores.getOrPut(label) { platform.storeFor(labelContext(label), consume(), MAX_BYTES) }
            io.godstone.mesh.delivery.SqliteAckStore(concrete.engine)
        }

    /** *The peer-trust store, opened on demand so an estate that never touches trust writes no peer database.* */
    internal fun peerStoreFor(label: String): io.godstone.mesh.identity.SqlcipherPeerIdentityStore =
        peerStores.getOrPut(label) {
            io.godstone.mesh.identity.SqlcipherPeerIdentityStore(labelContext(label), consume())
        }

    /**
     * *** THE ESTATE'S OWN WRITE-AHEAD INTENT LEDGER: A REAL SQLITE DATABASE ON THE LABEL'S OWN DISK. ***
     *
     * *THE OBLIGATION: **"retry load identical persisted bytes."*** **The process-local map could not satisfy it across
     * a relaunch; this can, and its file is named by [ownedFiles] so a requested wipe deletes the very ledger a retry
     * would have read.**
     */
    override fun intentLedgerFor(label: String): io.godstone.mesh.delivery.OutboundIntentJournal =
        intentLedgers.getOrPut(label) { LabSqliteIntentJournal.over(labelContext(label)) }

    /**
     * *** THE ESTATE'S OWN PEER DIRECTORY -- LIVE, READ FROM THE ESTATE AT EVERY LOOKUP. ***
     *
     * *A node's material is the identity this estate loaded or CREATED for it -- so `signingPub`, `staticDhPub` and the
     * accepted generation are the estate's own, and every composed peer starts `ACCEPTED` (a first-seen pin, which is
     * what the durable trust engine would record). A court may then REVOKE one to prove the send road refuses it by
     * name.* **AND THE DIRECTORY IS NO COPY: the composition may capture this map while the labels are still being
     * composed, so every read travelleth back to the estate's CURRENT identities and CURRENT trust table -- a snapshot
     * here would make the product command blind to exactly the late-composed peers and the revocations it exists to
     * enforce.**
     */
    override fun peerDirectory(): Map<String, io.godstone.mesh.runtime.ComposedPeerMaterial> = LivePeerDirectory()

    /** *The estate's live directory: the keys are the labels it hath composed, and every entry is read from the
     * estate's CURRENT identity and trust state at the instant of the read.* */
    private inner class LivePeerDirectory : AbstractMap<String, io.godstone.mesh.runtime.ComposedPeerMaterial>() {
        override val entries: Set<Map.Entry<String, io.godstone.mesh.runtime.ComposedPeerMaterial>>
            get() = snapshot().entries
        override fun get(key: String): io.godstone.mesh.runtime.ComposedPeerMaterial? =
            identities[key]?.let { peerMaterial(it) }
        private fun snapshot(): Map<String, io.godstone.mesh.runtime.ComposedPeerMaterial> {
            val out = LinkedHashMap<String, io.godstone.mesh.runtime.ComposedPeerMaterial>()
            for ((label, identity) in identities) out[label] = peerMaterial(identity)
            return out
        }
    }

    private fun peerMaterial(identity: io.godstone.mesh.identity.Identity): io.godstone.mesh.runtime.ComposedPeerMaterial =
        io.godstone.mesh.runtime.ComposedPeerMaterial(
            nodeId = identity.nodeId,
            signingPub = identity.identityPub,
            staticDhPub = identity.staticDhPub,
            acceptedGeneration = identity.bindingGeneration,
            trust = peerTrust[identity.nodeId.toList()]
                ?: io.godstone.mesh.runtime.ComposedPeerTrust.ACCEPTED,
        )


    /** *Withdraw (or quarantine) one label's trust, so a court can prove the refusal arms on REAL estate state.* */
    fun setPeerTrust(label: String, trust: io.godstone.mesh.runtime.ComposedPeerTrust) {
        val identity = identities[label] ?: return
        peerTrust[identity.nodeId.toList()] = trust
    }

    /**
     * *** RETIRE, CLOSE AND DESTROY THIS ESTATE'S OWN BYTES -- THE "OLD WORK REFUSED" HALF. ***
     *
     * *Every step is a REAL effect on a REAL owner, and the RETURN is the number of owners retired: zero would mean the
     * wipe was about to erase files a live writer still held.*
     */
    override fun retireAndClose(): Int {
        var retired = 0
        for ((_, ack) in ackStores) {
            if (ack.deleteAllFrames() >= 0) retired += 1
        }
        for ((_, store) in stores) {
            runCatching { store.close() }
            retired += 1
        }
        for ((_, peer) in peerStores) {
            runCatching { peer.close() }
            retired += 1
        }
        // *** AND THE INTENT LEDGERS: the estate's own write-ahead medium, closed BEFORE its files are removed. ***
        // *The recorded host run emitted `CloseGuard` warnings for `LabSqliteIntentJournal.load`, which is the
        // instrument saying this handle was never released. A writer that outlived the erasure would be the
        // same-estate violation one layer down.*
        for ((_, ledger) in intentLedgers) {
            runCatching { (ledger as? AutoCloseable)?.close() }
            retired += 1
        }
        retired += destroyOwnedArtifacts().size
        ackStores.clear()
        stores.clear()
        peerStores.clear()
        intentLedgers.clear()
        identities.clear()
        return retired
    }

    /**
     * *** DESTROY ONE LOGICAL FAMILY, WITH THE OWNER'S OWN VERB AND A REAL VERIFICATION. ***
     *
     * *THE REVIEW'S A10: a deletion "verified" over LOGICAL ALIASES certified files nobody wrote.* **This resolveth the
     * family to the estate's ACTUAL per-label files, calls the owner's own `panicWipe` verb for the databases, deletes
     * what remains of the family, and then takes its verdict over the files that SURVIVE rather than over the calls it
     * made.** *A family this estate does not own is `Absent`, and a survivor yields `Failed(path, surviving...)`.*
     */
    override fun destroyFamily(logicalName: String): io.godstone.mesh.identity.FileDeletionResult {
        val family = familyFiles(logicalName)
            ?: return io.godstone.mesh.identity.FileDeletionResult.Absent
        try {
            when {
                logicalName.startsWith("mesh.db") -> {
                    // *Close every live handle FIRST: the owner's own panicWipe cannot remove a database its engine
                    // still holdeth, and a writer across the erasure is the same-estate violation one layer down.*
                    for ((_, store) in stores) runCatching { store.close() }
                    stores.clear()
                    io.godstone.mesh.store.SqliteMessageStore.panicWipe(ctx)
                }
                logicalName.startsWith("peer.db") -> {
                    for ((_, peer) in peerStores) runCatching { peer.close() }
                    peerStores.clear()
                    io.godstone.mesh.identity.SqlcipherPeerIdentityStore.panicWipe(ctx)
                }
            }
            for (file in family) if (file.exists()) runCatching { file.delete() }
        } catch (e: Throwable) {
            return io.godstone.mesh.identity.FileDeletionResult.Failed(logicalName, e.toString())
        }
        val survivors = family.filter { it.exists() }
        return if (survivors.isEmpty()) io.godstone.mesh.identity.FileDeletionResult.Deleted
        else io.godstone.mesh.identity.FileDeletionResult.Failed(
            logicalName,
            "surviving targets: " + survivors.joinToString(",") { it.name },
        )
    }

    override fun familyExists(logicalName: String): Boolean =
        familyFiles(logicalName)?.any { it.exists() } ?: false

    /**
     * *** ERASE EVERY LABEL'S IDENTITY MATERIAL AND VERIFY IT IS GONE. ***
     *
     * *THE REVIEW'S A4, ON THIS ESTATE: an existing encrypted identity whose KEK was destroyed surviveth as unreadable
     * ciphertext, so a "fresh" publication over it cannot decrypt and the wipe parks for ever.* **The erase therefore
     * deletes each label's `godstone_identity` preferences (through the label's OWN view, which applies its prefix),
     * the `-bak` beside it and the AndroidX keyset -- and then VERIFIES every target is absent.**
     */
    override fun eraseIdentityFamily(): Boolean {
        for (label in labels) {
            val view = labelContext(label)
            runCatching { view.deleteSharedPreferences(io.godstone.mesh.identity.Identity.PREFS) }
        }
        for (file in identityFiles()) if (file.exists()) runCatching { file.delete() }
        return identityFiles().none { it.exists() }
    }

    /**
     * *** PUBLISH A FRESH IDENTITY THROUGH THE RECOVERY-ONLY FACTORY, NAMED BY ITS NODE HINT. ***
     *
     * *The NORMAL factory is `PrivateOwnerToken`-gated and cannot be reached here; the recovery factory is the
     * authority's own last-rung act. `null` meaneth NOT PUBLISHED -- the seam's typed negative channel.* **On a host
     * without a keystore the throw becometh `null` and the ladder STAYS PENDING, which is the honest answer.**
     */
    override fun publishFreshIdentity(): String? = try {
        val label = labels.firstOrNull() ?: "A"
        val identity = io.godstone.mesh.identity.Identity.regenerateForRecovery(labelContext(label))
        identity.nodeHint.takeIf { it.isNotEmpty() }?.joinToString("") { "%02x".format(it) }
    } catch (_: Throwable) {
        null
    }

    /**
     * *** WHAT THE ESTATE ACTUALLY HOLDETH ON DISK -- A ZERO PRIVATE EFFECT MEANETH ZERO PATHS HERE. ***
     *
     * *`ownedFiles()` enumerateth the CANDIDATES -- where the owners would write; the reported inventory is the files
     * that REALLY STAND, which is what maketh "the refusal preceded every private effect" a measurement rather than a
     * tautology: an estate whose owners were never opened owneth no file at all.* **And the erasure taketh its verdict
     * over the survivors, so the report and the delete cannot disagree about what was there.**
     */
    override fun ownedArtifactPaths(): List<String> = ownedFiles().filter { it.exists() }.map { it.absolutePath }

    /**
     * *** DELETE AND VERIFY THE ACTUAL FILES, SIDECARS AND PREFERENCES THIS ESTATE WROTE. ***
     *
     * *THE REVIEW'S A10 VERBATIM: a deletion "verified" over LOGICAL ALIASES certified files nobody wrote.* **This
     * resolveth to the CONCRETE files -- each label's databases with their sidecars, and each label's preference files --
     * deletes them, and then takes its verdict over the SURVIVORS rather than over the calls it made.**
     */
    fun destroyOwnedArtifacts(): List<String> {
        val removed = ArrayList<String>()
        for (file in ownedFiles()) {
            if (!file.exists()) continue
            runCatching { file.delete() }
            removed.add(file.absolutePath)
        }
        return removed
    }

    /** *The files a logical family this estate does not own resolveth to -- none; the base seam answers those.* */
    private fun familyFiles(logicalName: String): List<java.io.File>? = when {
        logicalName.startsWith("mesh.db") -> databaseFiles(io.godstone.mesh.store.StoreSchema.DB_NAME)
        logicalName.startsWith("peer.db") -> databaseFiles(io.godstone.mesh.identity.PeerIdentitySchema.DB_NAME)
        else -> null
    }

    /** *The database and its sidecars for EVERY label -- the physical files the owners really wrote.* */
    private fun databaseFiles(dbName: String): List<java.io.File> {
        val out = ArrayList<java.io.File>()
        for (label in labels) {
            val db = labelContext(label).getDatabasePath(dbName)
            for (suffix in SIDECARS) out.add(java.io.File(db.path + suffix))
        }
        return out
    }

    /** *Each label's identity preferences with its backup, plus the shared AndroidX keyset family.* */
    private fun identityFiles(): List<java.io.File> {
        val out = ArrayList<java.io.File>()
        for (label in labels) {
            val prefix = LabLabelContext.prefixOf(label)
            for (name in listOf(
                io.godstone.mesh.identity.Identity.PREFS,
                ANDROIDX_KEYSET_PREFS,
            )) {
                for (suffix in listOf(".xml", ".xml.bak")) {
                    out.add(java.io.File(prefsDir(), prefix + name + suffix))
                }
            }
        }
        return out
    }

    private fun prefsDir(): java.io.File {
        val dataDir = ctx.applicationInfo?.dataDir?.let { java.io.File(it) } ?: ctx.filesDir.parentFile
        return java.io.File(dataDir, "shared_prefs")
    }

    /** *The CONCRETE files: each label's databases with their sidecars, and each label's preference files.* */
    private fun ownedFiles(): List<java.io.File> {
        val out = ArrayList<java.io.File>()
        out.addAll(databaseFiles(io.godstone.mesh.store.StoreSchema.DB_NAME))
        out.addAll(databaseFiles(io.godstone.mesh.identity.PeerIdentitySchema.DB_NAME))
        // *** AND THE ESTATE'S OWN INTENT LEDGER: a wipe that left the write-ahead ledger behind would leave the
        // authored bytes -- and the recipient binding -- recoverable after a "full" erasure. ***
        out.addAll(databaseFiles(LabSqliteIntentJournal.DB_NAME))
        for (label in labels) out.addAll(prefFilesFor(label))
        return out
    }

    /** *The preference files the label's context view owns, found by the SAME prefix the view applies.*/
    private fun prefFilesFor(label: String): List<java.io.File> {
        val prefix = LabLabelContext.prefixOf(label)
        return prefsDir().listFiles { f -> f.name.startsWith(prefix) }?.toList() ?: emptyList()
    }

    companion object {
        /** The production bounded store cap, matching the module's own hard cap. */
        const val MAX_BYTES: Long = 64L * 1024 * 1024

        /** The roles the launchable lab composes. */
        val LABELS: List<String> = listOf("A", "R", "B")

        /** The sidecar suffixes SQLite writes beside a database. */
        val SIDECARS: List<String> = listOf("", "-wal", "-shm", "-journal")

        /** The AndroidX Security keyset file an `EncryptedSharedPreferences` is protected by. */
        const val ANDROIDX_KEYSET_PREFS: String = "__androidx_security_crypto_encrypted_prefs_key_keyset__"
    }
}

/**
 * *** GS-FINAL-003 `same-estate`: A PER-LABEL VIEW OF THE DEVICE, SO EVERY LAB ROLE OWNS REAL FILES. ***
 *
 * *The production owners reach the platform through exactly two doors: `Context.getDatabasePath(name)` (which
 * `SQLiteOpenHelper` uses to place a database) and `Context.getSharedPreferences(name, mode)` (which
 * `EncryptedSharedPreferences` and `Identity` use to place their ciphertext).* **REDIRECTING THOSE TWO DOORS GIVETH THE
 * LABEL ITS OWN REAL DATABASE DIRECTORY AND ITS OWN REAL PREFERENCE FILES, WHILE EVERY OWNER REMAINS THE UNCHANGED
 * PRODUCTION TYPE** -- an AndroidKeyStore-backed master key, the SQLCipher native engine, the real schema.*
 *
 * *** `getApplicationContext()` RETURNS THIS VIEW, DELIBERATELY. *** *`SqliteMessageStore`'s production constructor
 * normaliseth its context with `ctx.applicationContext`; a view that answered the BASE application there would lose the
 * redirection and every label would open one database -- the exact degenerate composition this class existeth to
 * prevent.* **A wrapper that is not its own application context cannot be composed at all.**
 */
internal class LabLabelContext(
    private val base: android.content.Context,
    private val label: String,
) : android.content.ContextWrapper(base) {
    private val labelDir: java.io.File =
        java.io.File(java.io.File(base.filesDir, LAB_DIR_NAME), label).also { it.mkdirs() }

    /** *The database lives under the label's own directory, whatever name the owner asks for.* */
    override fun getDatabasePath(name: String): java.io.File = java.io.File(labelDir, name)

    /** *And every preference file carrieth this label's prefix, so two labels never share a ciphertext or a keyset.*/
    override fun getSharedPreferences(name: String, mode: Int): android.content.SharedPreferences =
        super.getSharedPreferences(prefixOf(label) + name, mode)

    /** *Deletion must follow the SAME prefix, or a wipe would delete a file that was never written.* */
    override fun deleteSharedPreferences(name: String): Boolean =
        super.deleteSharedPreferences(prefixOf(label) + name)

    /** *The label's own view is its own application context -- see the class docstring.* */
    override fun getApplicationContext(): android.content.Context = this

    companion object {
        const val LAB_DIR_NAME: String = "labmesh"

        fun prefixOf(label: String): String = "lab_" + label + "_"
    }
}
