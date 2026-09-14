package io.godstone.mesh.lab

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

    /** How many messages the named node durably holdeth. */
    suspend fun heldCount(nodeLabel: String): Int =
        harness.node(nodeLabel)?.store?.allHeldMsgIds()?.size ?: 0

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
