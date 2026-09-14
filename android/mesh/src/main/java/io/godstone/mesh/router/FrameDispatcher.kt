package io.godstone.mesh.router

import io.godstone.mesh.delivery.AckDispatch
import io.godstone.mesh.delivery.AckDispatcher
import io.godstone.mesh.delivery.AckResult
import io.godstone.mesh.wire.v2.FrameV2
import io.godstone.mesh.wire.v2.TypeV2

// ---------------------------------------------------------------------------
// T41 -- the typed frame dispatcher (section 14's dispatch statute).
//
// "Control dispatch order is explicit: decoded PING/HELLO/DIGEST/WANT go to the
// per-relation sync/control owner before generic Router TTL/dedup/storage; ACK
// goes to the ACK dispatcher described below; only supported MESSAGE/SOS enter
// durable message routing. Unknown/BULK control types are rejected in this
// profile."
//
// Before T41 that order lived inline in MeshNode.ingestInbound, tangled with the
// message-side side effects, so nothing could witness the ORDER itself -- only
// its consequences. The order is now a TYPE: [DispatchVerdict.dispatchClass]
// sayeth which authority owneth the frame, the ACK road is the T84 dispatcher
// (or, when no ack_frames namespace is bound, the historical point-to-point
// face, expressed as the very same verdict type), and a frame of an unsupported
// type is refused BY NAME rather than falling through to persistence.
//
// The dispatcher ROUTES; it persisteth nothing. A MESSAGE/SOS verdict meaneth
// "the generic durable road is this frame's duty", and the composition runneth
// it. That separation is what maketh the order testable without a store.
// ---------------------------------------------------------------------------

/** Which authority owneth one inbound frame. */
enum class DispatchClass { CONTROL, ACK, MESSAGE, SOS, REFUSED }

/** Why a frame was refused at the door. Named, never a silent drop. */
enum class DispatchRefusal {
    /** The bulk pair, GOODBYE, an unknown type: not a frame of this profile. */
    UNSUPPORTED_TYPE,
}

/** The typed verdict of one dispatch. */
sealed class DispatchVerdict {
    abstract val dispatchClass: DispatchClass

    /** A link control: the per-relation owner decided; any answer rideth back out. */
    class Control(
        val decision: SyncControlOwner.OwnerDecision,
        val accepted: Boolean,
    ) : DispatchVerdict() {
        override val dispatchClass: DispatchClass get() = DispatchClass.CONTROL
    }

    /** An ACK: the delivery authority, never the message road. */
    class Ack(val dispatch: AckDispatch) : DispatchVerdict() {
        override val dispatchClass: DispatchClass get() = DispatchClass.ACK
        val accepted: Boolean get() = dispatch.accepted
    }

    /** A supported MESSAGE: the generic durable road is its duty. */
    object Message : DispatchVerdict() {
        override val dispatchClass: DispatchClass get() = DispatchClass.MESSAGE
    }

    /** A supported SOS: the generic durable road is its duty. */
    object Sos : DispatchVerdict() {
        override val dispatchClass: DispatchClass get() = DispatchClass.SOS
    }

    /** Refused by name: nothing is stored, nothing relayed, no trust moves. */
    class Refused(val reason: DispatchRefusal, val detail: String = "") : DispatchVerdict() {
        override val dispatchClass: DispatchClass get() = DispatchClass.REFUSED
    }
}

/**
 * The dispatch statute, in one place and in one order.
 *
 * [ackAuthority] is the T84 ACK dispatcher seam: when the composition owneth an
 * ack_frames namespace it is bound, and an ACK with no local delivery row becomes
 * relay custody rather than an UnknownMessage discard. When it is absent the
 * historical point-to-point face standeth, expressed as the SAME verdict type so
 * that no caller can tell the two roads apart by shape -- only by the verdict.
 */
class FrameDispatcher(
    private val owner: SyncControlOwner,
    private val ackAuthority: () -> AckDispatcher?,
    private val acknowledgeHistorically: (FrameV2) -> AckResult,
) {
    /** One inbound frame: control, then ACK, then the generic road. */
    suspend fun dispatch(frame: FrameV2, fromPeer: ByteArray): DispatchVerdict {
        when (frame.type) {
            TypeV2.PING, TypeV2.HELLO, TypeV2.DIGEST, TypeV2.WANT -> {
                // the per-relation owner, BEFORE policy, the seen window, the TTL
                // gate and persistence: a control frame is never content
                val decision = owner.handleControlFrame(frame, fromPeer)
                return DispatchVerdict.Control(decision, accepted(decision))
            }
            TypeV2.ACK -> {
                val authority = ackAuthority()
                return DispatchVerdict.Ack(
                    authority?.dispatch(frame, fromPeer)
                        ?: AckDispatch.OriginVerification(acknowledgeHistorically(frame)),
                )
            }
            TypeV2.MESSAGE -> return DispatchVerdict.Message
            TypeV2.SOS -> return DispatchVerdict.Sos
            else -> return DispatchVerdict.Refused(
                DispatchRefusal.UNSUPPORTED_TYPE,
                "the bulk pair, GOODBYE and anything unknown are refused in this profile " +
                    "(section 14 dispatch statute); nothing is stored, nothing is relayed, " +
                    "no trust is moved: ${frame.type}",
            )
        }
    }

    /** The frames an owner decision answereth with (empty when it answereth not). */
    fun replies(decision: SyncControlOwner.OwnerDecision): List<FrameV2> = when (decision) {
        is SyncControlOwner.OwnerDecision.Answered -> listOf(decision.frame)
        is SyncControlOwner.OwnerDecision.Delivered -> decision.frames
        else -> emptyList()
    }

    private fun accepted(decision: SyncControlOwner.OwnerDecision): Boolean = when (decision) {
        is SyncControlOwner.OwnerDecision.Accepted,
        is SyncControlOwner.OwnerDecision.Answered,
        is SyncControlOwner.OwnerDecision.Delivered -> true
        else -> false
    }
}
