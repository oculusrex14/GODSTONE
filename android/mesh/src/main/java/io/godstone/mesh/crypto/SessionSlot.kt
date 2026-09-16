package io.godstone.mesh.crypto

import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/**
 * CRYPTO-001 (T08 completion, the Android twin of the iOS `RelationAdmission`): the DIRECTION of a
 * relation. An inbound and an outbound relation of ONE platform address are TWO relations, not one.
 *
 * WHY THE CRYPTO PACKAGE OWNS ITS OWN ENUM rather than importing `transport.BleDirection`: the
 * transport dependeth on this package (`SessionHandshakeAuthority`, the seal and open ports), so
 * taking the transport's vocabulary here would invert that dependency. The transport mapeth its own
 * `BleDirection` onto this one at the composition boundary, explicitly, which is where a mapping
 * belongeth.
 */
enum class RelationDirection {
    OUTBOUND_CENTRAL,
    INBOUND_PERIPHERAL,
}

/**
 * CRYPTO-001: THE COMPLETE IMMUTABLE RELATION IDENTITY, and the only key the crypto registry accepteth.
 *
 * What the audit refuseth: a registry that resolveth a relation by the platform HANDLE alone. A handle
 * is reused -- a station is replaced while the address standeth -- so a delayed teardown, a queued
 * ciphertext, a handshake half spoken or a lapsed timer captured against incarnation A would resolve
 * incarnation B and slay it, or route A's work into B's lifetime.
 *
 * Each field is load-bearing:
 * - [direction]: an inbound and an outbound relation of one address are two relations;
 * - [handle]: the transport's lookup address -- the only name the platform giveth, and never a node id
 *   (it is the hex of the peer's transport handle, NOT its identity);
 * - [generation]: THE ORCHESTRATION-OWNED generation, minted by the link owner when the relation is
 *   admitted (`BleCentralOrchestrationDriver.connectionGenerations`). The crypto registry minteth NONE
 *   of its own: an independent counter could alias, and the T08 "remembered generation" history existed
 *   only to paper over that absence;
 * - [transportEpoch]: the radio epoch the admission belongeth to. A handle and a generation can recur
 *   across a radio restart; the epoch cannot.
 */
data class RelationKey(
    val direction: RelationDirection,
    val handle: String,
    val generation: Long,
    val transportEpoch: Long,
) {
    override fun toString(): String =
        "RelationKey($direction, " + handle.take(8) + ", gen=" + generation + ", epoch=" + transportEpoch + ")"
}

/** The relation's PLACE in the registry: one live incarnation per direction and handle. */
data class RelationPlace(val direction: RelationDirection, val handle: String)

/** CRYPTO-001: the placement of an admission, so a lookup nameth the place first and the incarnation second. */
val RelationKey.place: RelationPlace
    get() = RelationPlace(direction, handle)

/**
 * CRYPTO-001: the typed answer of a relation's teardown. A teardown addressed to an incarnation which
 * no longer standeth is [STALE] -- the authority REFUSETH it, and the standing replacement is untouched.
 * The distinction IS the finding: a drop which cannot be told from a drop of the replacement is not an
 * authority over relations.
 */
enum class RelationRetirement { RETIRED, STALE }

enum class SlotState { ACTIVE, RETIRED, INVALIDATED }

/**
 * T08: the single serialization authority for one relation. The handshake controller, cipher counters,
 * replay window, terminal state and timer lease all live in this slot, and every operation - handshake,
 * seal, open, drop, isReady - takes the SAME slot lock. Lock order: the lifecycle gate first, then the
 * slot; the destructive work of a drop happens OUTSIDE the slot lock (only the terminal transition is
 * serialized). Retired slots are removed from the registry and their lock entries reclaimed with them.
 */
class SessionSlot(
    /** CRYPTO-001: the incarnation this slot standeth for. Immutable for the slot's whole life. */
    val admission: RelationKey,
) {

    private val lock = ReentrantLock()

    /**
     * T08 witness: the serialisation authority proves itself. While the slot lock is held an entry is
     * exclusive, so the depth is zero when a fresh operation begins, and the same thread may re-enter
     * through retire. If two different threads are ever seen inside the slot at the same time the slot
     * has stopped being the serialisation point, and the peak records it for the concurrent case to
     * fail on.
     */
    private var lastEntered: Thread? = null
    private var depth = 0
    internal var maxThreadsInside = 0

    internal var controller: TrustedHandshakeController? = null
    internal var state: SlotState = SlotState.ACTIVE

    /** The relation's place -- the slot's own key in the registry. */
    val key: RelationKey get() = admission

    /** The relation's ORCHESTRATION-OWNED generation: READ from the admission, never minted here. */
    val generation: Long get() = admission.generation

    /**
     * GS-CTRL-002 (R05): the PER-PEER (per-relation) serialisation point, under the name the
     * composition contract useth. It is not a name added for a gate: [serialize], and therefore every
     * handshake operation on this relation, runneth through it.
     */
    internal fun getPeerLock(): ReentrantLock = lock

    fun <T> serialize(block: () -> T): T = getPeerLock().withLock {
        val me = Thread.currentThread()
        if (depth > 0 && lastEntered != null && lastEntered !== me) {
            // Two different threads were seen inside the slot at once.
            maxThreadsInside = 2
        }
        if (depth == 0) {
            lastEntered = me
        }
        depth += 1
        try {
            block()
        } finally {
            depth -= 1
            if (depth == 0) {
                lastEntered = null
            }
        }
    }

    /**
     * T08: transition the slot to RETIRED atomically with the operation that caused it, and hand back
     * the controller so the CALLER can route the destructive destroy outside the slot lock.
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
