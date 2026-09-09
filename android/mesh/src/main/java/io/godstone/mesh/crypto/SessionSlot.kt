package io.godstone.mesh.crypto

import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/**
 * T08: immutable key for one session slot. Wraps the existing transport
 * lookup handle (the peer-id hex string used for map lookup) WITHOUT turning
 * it into node identity.
 */
class RelationKey(val handle: String) {
    override fun equals(other: Any?): Boolean =
        other is RelationKey && other.handle == handle

    override fun hashCode(): Int = handle.hashCode()

    override fun toString(): String = "RelationKey(" + handle.take(8) + ")"
}

enum class SlotState { ACTIVE, RETIRED, INVALIDATED }

/**
 * T08: monotonic lease token. Reclaim compares generations: a retired slot
 * returns its lease to the registry and a replacement carries the next
 * generation.
 */
class SlotLease(val generation: Long) {
    fun next(): SlotLease = SlotLease(generation + 1)
}

/**
 * T08: the single serialization authority for one relation. The handshake
 * controller, cipher counters, replay window, terminal state and timer lease
 * all live in this slot, and every operation - handshake, seal, open, drop,
 * isReady - takes the SAME slot lock. Lock order: the lifecycle gate first,
 * then the slot; the destructive work of a drop happens OUTSIDE the slot
 * lock (only the terminal transition is serialized). Retired slots are
 * removed from the registry and their lock entries reclaimed with them.
 */
class SessionSlot(
    val key: RelationKey,
    lease: SlotLease = SlotLease(0)
) {

    private val lock = ReentrantLock()

    internal var controller: TrustedHandshakeController? = null
    internal var state: SlotState = SlotState.ACTIVE
    internal var lease: SlotLease = lease

    /** Every slot operation runs under this single serialization. */
    fun <T> serialize(block: () -> T): T = lock.withLock { block() }

    /**
     * T08: transition the slot to RETIRED atomically with the operation that
     * caused it, and hand back the controller so the CALLER can route the
     * destructive destroy outside the slot lock.
     */
    internal fun retire(): TrustedHandshakeController? = serialize {
        if (state == SlotState.RETIRED) {
            return@serialize null
        }
        state = SlotState.RETIRED
        val doomed = controller
        controller = null
        doomed
    }
}