package io.godstone.mesh.transport

/**
 * T12: the explicit termination of Android transport attempts.
 *
 * The platform can report a terminal event itself (a real disconnection
 * through the GATT callback), but reject, provisional timeout and local
 * cancel must terminate the relation without waiting for a callback that
 * may never arrive: a local close invalidates the GATT callback lifetime,
 * so any slot that awaits the platform after such a termination rests
 * forever. The types below make the termination a single, exactly named
 * operation for the exact relation.
 */

/** Why an attempt ends. */
enum class TerminalReason {
    /** A protocol-level rejection: malformed input, failed handshake, lost election. */
    REJECTED,

    /** The provisional window closed before the handshake completed. */
    PROVISIONAL_TIMEOUT,

    /** The transport itself cancels the attempt (stop, replacement, eviction). */
    LOCAL_CANCEL,

    /** The platform reported the disconnection through the callback. */
    PLATFORM_DISCONNECT
}

/**
 * A terminal event naming the exact relation that ends and the reason.
 * The relation key is the (direction, address, generation) triple under
 * which the attempt was admitted; an event may only terminate the attempt
 * it names, never the successor's registration.
 */
class TerminalEvent(
    val relationKey: RelationKey,
    val reason: TerminalReason
) {
    override fun toString(): String =
        "TerminalEvent(" + relationKey + ", " + reason + ")"
}

/**
 * What one termination operation actually did, so that callers schedule
 * effects from the outcome instead of re-reading current state:
 *
 * - transitioned: this very event performed the one transition to terminal
 *   (released the lease once, took the publication down once, rested the
 *   slot at IDLE of that generation).
 * - refusedForeignGeneration: the event named another generation than the
 *   registered one; it was refused and changed nothing.
 * - alreadyTerminal: the exact relation had already been terminated; the
 *   repeat is idempotent and changed nothing.
 * - unpublishEffectPending: the relation was published when it ended, so
 *   the platform Lost publication effect remains to be scheduled.
 * - closeCapturedGattRequired: a connection object was live, so the
 *   captured GATT handle of this exact attempt stands to be closed.
 */
class TerminalOutcome(
    val transitioned: Boolean,
    val refusedForeignGeneration: Boolean,
    val alreadyTerminal: Boolean,
    val unpublishEffectPending: Boolean,
    val closeCapturedGattRequired: Boolean
) {
    override fun toString(): String =
        "TerminalOutcome(transitioned=" + transitioned +
            ", refusedForeign=" + refusedForeignGeneration +
            ", alreadyTerminal=" + alreadyTerminal +
            ", unpublishPending=" + unpublishEffectPending +
            ", closeGatt=" + closeCapturedGattRequired + ")"
}
