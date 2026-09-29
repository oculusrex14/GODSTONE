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
) {
    /** The durable state of one message, or null when the estate carrieth none. */
    fun durableStateOf(nodeLabel: String, msgId: ByteArray): DeliveryState? {
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
        harness.node(nodeLabel)?.store?.allHeldMsgIds()?.lastOrNull()

    /** Every msg_id the named node's durable estate carrieth. */
    suspend fun heldMsgIdsOf(nodeLabel: String): List<ByteArray> =
        harness.node(nodeLabel)?.store?.allHeldMsgIds()?.map { it.copyOf() } ?: emptyList()

    /** The honest label the durable row supporteth, or null when the estate carrieth no row. */
    fun deliveryLabelOf(nodeLabel: String, msgId: ByteArray): String? {
        val node = harness.node(nodeLabel) ?: return null
        val projection = node.node.deliveryProjection(msgId)
        return projection.label.name
    }

    /** How many messages the named node durably holdeth. */
    suspend fun heldCount(nodeLabel: String): Int =
        harness.node(nodeLabel)?.store?.allHeldMsgIds()?.size ?: 0

    /**
     * *** GS-UX-001 `rendered-controls`: THE DIRECTED SEND, WITH THE MESSAGE ID THE AUTHORITY MINTED. ***
     *
     * *The screen must render the ID THE RUNTIME OWNS rather than one it invented, so the send returneth the `msg_id` the
     * durable enqueue committed (or null when nothing was committed). The rendered id is then a READ, which is what
     * maketh a view-local string unable to satisfy the journey arm.*
     */
    suspend fun sendDirectResult(from: String, recipient: String, plaintext: ByteArray): DirectSendResult {
        val before = harness.node(from)?.store?.allHeldMsgIds()?.map { it.toList() }?.toSet() ?: emptySet()
        val outcome = harness.sendDirect(from, recipient, plaintext)
        val after = harness.node(from)?.store?.allHeldMsgIds() ?: emptyList()
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
        is ComposedOutcome.Refused -> "refused:" + outcome.reason.name
    }

    companion object {
        /** The honest readiness statement. It carrieth no parameter, so no caller
         *  can argue it into saying true. */
        fun readinessStatement(): LabReadiness = LabReadiness(
            androidLinkLayerReady = false,
            iosLinkLayerReady = false,
            profile = LabProfile.NAME,
            experimental = LabProfile.EXPERIMENTAL,
        )

        /**
         * Compose [labels].size real peers and link them in a chain, so a message
         * from the first to the last travelleth through a real relay.
         */
        fun compose(labels: List<String> = listOf("A", "R", "B"),
                    rng: SecureRandom = SecureRandom()): LabRuntime {
            require(labels.size >= 2) { "a lab runtime needs at least two peers" }
            require(labels.distinct().size == labels.size) { "lab labels must be distinct" }
            val clock = FixedHostClock()
            val harness = ComposedRuntimeHarness(clock = clock, link = LinkFacade(clock), rng = rng)
            for (label in labels) harness.addNode(label)
            for (i in 0 until labels.size - 1) harness.link(labels[i], labels[i + 1])
            return LabRuntime(harness, labels.toList())
        }
    }
}
