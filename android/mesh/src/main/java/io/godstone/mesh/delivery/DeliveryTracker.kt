package io.godstone.mesh.delivery

import io.godstone.mesh.wire.v2.FrameV2

// Stage 3 Phase H -- durable, recipient-authenticated delivery state machine
// (ADR-005; A-03). The lifecycle from ADR-005:
//
//   UNAVAILABLE | QUEUED_DURABLY -> HANDED_TO_RELAY -> ACKNOWLEDGED_BY_RECIPIENT
//                                       \-> EXPIRED | CANCELLED_LOCALLY
//
// A successful GATT write is only HANDED_TO_RELAY. SENT / ACKNOWLEDGED_BY_RECIPIENT
// is forbidden unless an AUTHENTICATED intended recipient ACKs the EXACT message
// id (see AckAuthenticator). Cancellation cannot recall already relayed copies
// and the state says so. The machine is pure (no Context / no disk) with the
// journal + authenticator injected, so it is host-testable without a device or
// radio. The radio/link layer remains disabled (M2-link), so this is repo-owned
// evidence for the state machine + authenticated-ACK verification, not an
// on-device delivery proof.

/**
 * Delivery lifecycle (ADR-005). Terminal states are ACKNOWLEDGED_BY_RECIPIENT,
 * EXPIRED and CANCELLED_LOCALLY.
 */
enum class DeliveryState {
    UNAVAILABLE,
    QUEUED_DURABLY,
    HANDED_TO_RELAY,
    ACKNOWLEDGED_BY_RECIPIENT,
    EXPIRED,
    CANCELLED_LOCALLY;

    val isTerminal: Boolean get() =
        this == ACKNOWLEDGED_BY_RECIPIENT || this == EXPIRED || this == CANCELLED_LOCALLY
}

/**
 * Crash-safe persisted delivery state per message id. Implementations must
 * persist across a reboot/jetsam so a fresh [DeliveryTracker] over the same
 * journal recovers the state (reboot recovery, ADR-005 exit criteria).
 */
interface DeliveryJournal {
    fun read(msgId: ByteArray): DeliveryState
    fun write(msgId: ByteArray, state: DeliveryState)
    fun clear(msgId: ByteArray)
}

/**
 * Verifies that an inbound ACK frame is an authentic acknowledgment of
 * [originalMsgId] by the intended recipient. See [Ed25519AckAuthenticator] for
 * the binding model. A return of false means the ACK is rejected and the
 * delivery state MUST NOT advance to ACKNOWLEDGED -- no UI phrase stronger than
 * the cryptographic evidence is permitted (ADR-005).
 */
interface AckAuthenticator {
    fun verify(originalMsgId: ByteArray, ackFrame: FrameV2): Boolean
}

/**
 * Durable delivery state machine. Every successful transition is persisted to
 * [journal] AFTER it is applied, so a crash-then-resume re-reads the last
 * persisted state. Transitions that are illegal for the current state (or an
 * ACK that fails authentication) return false and do not mutate state -- the
 * truth-table is enforced, not advisory.
 */
class DeliveryTracker(
    private val journal: DeliveryJournal,
    private val authenticator: AckAuthenticator,
) {
    /** Current persisted state for `msgId` (UNAVAILABLE if never tracked). */
    fun state(msgId: ByteArray): DeliveryState = journal.read(msgId)

    /**
     * Begin tracking a message: UNAVAILABLE -> QUEUED_DURABLY. Idempotent: a
     * message already QUEUED_DURABLY stays queued (re-enqueuing a queued msg is
     * benign). Returns false from any non-queueable state (already handed/acked/
     * expired/cancelled).
     */
    fun enqueue(msgId: ByteArray): Boolean {
        val s = journal.read(msgId)
        if (s == DeliveryState.QUEUED_DURABLY) return true
        if (s != DeliveryState.UNAVAILABLE) return false
        journal.write(msgId, DeliveryState.QUEUED_DURABLY)
        return true
    }

    /**
     * Record that the frame was handed to a relay (a successful GATT write).
     * QUEUED_DURABLY -> HANDED_TO_RELAY. Idempotent from HANDED_TO_RELAY.
     * Returns false from any other state (this is NOT "sent" -- only
     * [acknowledge] can reach ACKNOWLEDGED_BY_RECIPIENT).
     */
    fun markHandedToRelay(msgId: ByteArray): Boolean {
        val s = journal.read(msgId)
        if (s == DeliveryState.HANDED_TO_RELAY) return true
        if (s != DeliveryState.QUEUED_DURABLY) return false
        journal.write(msgId, DeliveryState.HANDED_TO_RELAY)
        return true
    }

    /**
     * Apply an authenticated recipient ACK. Only advances to
     * ACKNOWLEDGED_BY_RECIPIENT when [authenticator] accepts the ACK AND the
     * current state is QUEUED_DURABLY or HANDED_TO_RELAY (or already
     * acknowledged -- idempotent). A rejected ACK (unsigned / tampered / wrong
     * recipient / wrong msg id) returns false and the state is unchanged: no
     * delivery is claimed without cryptographic evidence.
     */
    fun acknowledge(msgId: ByteArray, ackFrame: FrameV2): Boolean {
        val s = journal.read(msgId)
        if (s == DeliveryState.ACKNOWLEDGED_BY_RECIPIENT) return true   // idempotent re-ack
        if (s != DeliveryState.QUEUED_DURABLY && s != DeliveryState.HANDED_TO_RELAY) return false
        if (!authenticator.verify(msgId, ackFrame)) return false
        journal.write(msgId, DeliveryState.ACKNOWLEDGED_BY_RECIPIENT)
        return true
    }

    /**
     * TTL expiry: QUEUED_DURABLY or HANDED_TO_RELAY -> EXPIRED. Terminal.
     */
    fun expire(msgId: ByteArray): Boolean {
        val s = journal.read(msgId)
        if (s == DeliveryState.EXPIRED) return true
        if (s != DeliveryState.QUEUED_DURABLY && s != DeliveryState.HANDED_TO_RELAY) return false
        journal.write(msgId, DeliveryState.EXPIRED)
        return true
    }

    /**
     * Local cancellation: QUEUED_DURABLY or HANDED_TO_RELAY -> CANCELLED_LOCALLY.
     * Terminal. Cancellation cannot recall already relayed copies -- the caller
     * is responsible for the truthful UI ("canceled; relayed copies may
     * remain"); the state machine only records the local intent.
     */
    fun cancel(msgId: ByteArray): Boolean {
        val s = journal.read(msgId)
        if (s == DeliveryState.CANCELLED_LOCALLY) return true
        if (s != DeliveryState.QUEUED_DURABLY && s != DeliveryState.HANDED_TO_RELAY) return false
        journal.write(msgId, DeliveryState.CANCELLED_LOCALLY)
        return true
    }

    /** Drop tracking for `msgId` (e.g. after the message ages out of the store). */
    fun forget(msgId: ByteArray) = journal.clear(msgId)
}