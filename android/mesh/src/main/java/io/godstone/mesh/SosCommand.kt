package io.godstone.mesh

import io.godstone.mesh.delivery.DeliveryState
import io.godstone.mesh.wire.v2.FrameV2

// T39 (section 14): the SOS command surface -- Author, Retry, Cancel -- and the
// durable projections the one authority exposes. The card's word: "Commit SOS held
// frame plus NONE-mode delivery row atomically. Expose active SOS from that row.
// Cancel marks terminal and removes scheduled/held work transactionally; it
// cannot retract already relayed copies and UI says so. Retry resumes the same
// authored SOS bytes."
//
// The commands are data, not side effects: executing them belongs to MeshNode
// (handleSosCommand / dispatchSos / retrySos / cancelSos), which routes every
// mutation of BOTH tables -- held frames and delivery rows -- through the single
// durable authority (the store-backed repository or the shared SQL engine, each
// committing the pair in one transaction). No command mutates authoritative state
// on a validation failure; each typed result distinguishes failure from the
// idempotent no-op.

/**
 * One command of the distress lifecycle. Identity is by msg_id (content-based
 * equality, so duplicate logical records are detected, not silently doubled);
 * the payload is the user's bytes, never interpreted here.
 */
sealed class SosCommand {

    /** Author a fresh distress call: the node composes the frame (the T38
     *  signed-SOS authority when wired, the documented legacy shape otherwise)
     *  and commits held frame + NONE-mode row as ONE durable pair. */
    class Author(val payload: ByteArray) : SosCommand() {
        override fun equals(other: Any?): Boolean = other is Author &&
            other.payload.contentEquals(payload)
        override fun hashCode(): Int = payload.contentHashCode()
        override fun toString(): String = "SosCommand.Author(${payload.size} bytes)"
    }

    /** Resume the SAME authored bytes of a still-live call (never re-derive:
     *  the msg_id is immutable content; a retry that re-authored would betray
     *  it). A terminal row refuses the resume. */
    class Retry(val msgId: ByteArray) : SosCommand() {
        override fun equals(other: Any?): Boolean = other is Retry &&
            other.msgId.contentEquals(msgId)
        override fun hashCode(): Int = msgId.contentHashCode()
        override fun toString(): String = "SosCommand.Retry(${msgId.size} bytes)"
    }

    /** Cancel one call durably: guarded terminal CAS on the row plus removal of
     *  the scheduled/held work, transactionally in the one authority. Already
     *  relayed copies cannot be recalled -- the result says so, the UI must tell
     *  it too. Duplicate cancellation is idempotent, never an error. */
    class Cancel(val msgId: ByteArray) : SosCommand() {
        override fun equals(other: Any?): Boolean = other is Cancel &&
            other.msgId.contentEquals(msgId)
        override fun hashCode(): Int = msgId.contentHashCode()
        override fun toString(): String = "SosCommand.Cancel(${msgId.size} bytes)"
    }
}

/**
 * The durable Active-SOS projection: read FROM the delivery row (state, mode)
 * joined with the held frame and its receipt stamp -- never from a UI memory.
 * Broadcast shows local queue and offers only; it never claims
 * recipient-delivered or guaranteed rescue. Content-based equality on the
 * msg_id keeps duplicate projections detected.
 */
class ActiveSos(
    val msgId: ByteArray,
    val state: DeliveryState,
    val frame: FrameV2,
    /** When this node committed the pair, when it remembers; null when the
     *  tables cannot name the instant (honest silence over a fabricated clock). */
    val committedAtMillis: Long?,
) {
    /** True when the row has been handed to at least one relay: the UI must
     *  then say that already relayed copies cannot be recalled. */
    val relayed: Boolean get() = state == DeliveryState.HANDED_TO_RELAY

    fun sameCallAs(other: ActiveSos): Boolean =
        other.msgId.contentEquals(msgId) && other.state == state &&
            other.frame == frame && other.committedAtMillis == committedAtMillis

    override fun equals(other: Any?): Boolean = other is ActiveSos && sameCallAs(other)
    override fun hashCode(): Int {
        var h = msgId.contentHashCode()
        h = 31 * h + state.hashCode()
        h = 31 * h + frame.hashCode()
        h = 31 * h + committedAtMillis.hashCode()
        return h
    }

    override fun toString(): String =
        "ActiveSos(msg_id=" + java.util.Base64.getUrlEncoder().encodeToString(msgId) +
        ", state=" + state + ", relayed=" + relayed +
        ", committedAtMillis=" + committedAtMillis + ")"
}

/**
 * Typed outcome of the Cancel arm (C6.4-A discipline: a failed destructive
 * operation is never indistinguishable from success, and an idempotent
 * no-op is named apart from a fresh cancellation).
 */
sealed class SosCancelResult {
    /** This call cancelled: the row moved to CANCELLED_LOCALLY and the held
     *  frame was removed in the one transaction. [wasRelayed] is the truth of
     *  whether bytes had already gone out at the moment of cancellation --
     *  the UI must tell it: "already relayed copies cannot be recalled". */
    data class Cancelled(val wasRelayed: Boolean) : SosCancelResult()

    /** The call was already cancelled (or its row had reached this terminal
     *  state by another path): idempotent, nothing moved. [wasRelayed] is
     *  null when the fact can no longer be derived from the row itself --
     *  an honest silence, not a guess. */
    data class AlreadyCancelled(val wasRelayed: Boolean?) : SosCancelResult()

    /** The row is terminal in a way cancellation may not overwrite (EXPIRED,
     *  ACKNOWLEDGED): refused, nothing moved. */
    data class RejectedTerminal(val state: DeliveryState) : SosCancelResult()

    /** A SINGLE_RECIPIENT obligation is not this broadcast authority's to
     *  cancel: refused, nothing moved (the directed path owns its own
     *  retire machinery). */
    object NotBroadcast : SosCancelResult() {
        override fun toString(): String = "SosCancelResult.NotBroadcast"
    }

    /** Nothing was found for this msg_id: failure, not an empty success. */
    object UnknownMessage : SosCancelResult() {
        override fun toString(): String = "SosCancelResult.UnknownMessage"
    }

    /** The row (or its pair) is corrupt on read: fail closed, nothing moved. */
    object Corrupt : SosCancelResult() {
        override fun toString(): String = "SosCancelResult.Corrupt"
    }

    /** A storage failure during the guarded transaction: rolled back whole. */
    object StorageFailure : SosCancelResult() {
        override fun toString(): String = "SosCancelResult.StorageFailure"
    }

    /** The command was not well-formed (widths): refused before any write. */
    object InvalidArgument : SosCancelResult() {
        override fun toString(): String = "SosCancelResult.InvalidArgument"
    }
}

/**
 * The unified outcome of [MeshNode.handleSosCommand]: which arm ran and what
 * its durable result was. No arm reports success it did not achieve; the
 * dispatch arm's taxonomy is the established [SosDispatchResult], the cancel
 * arm's is [SosCancelResult] -- one envelope, two honest payloads.
 */
sealed class SosCommandResult {
    data class Enqueued(val dispatch: SosDispatchResult) : SosCommandResult()
    data class Cancelled(val cancel: SosCancelResult) : SosCommandResult()
}
