package io.godstone.mesh.transport

import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

// ---------------------------------------------------------------------------
// T24->T25 contract layer: the immutable value the store executor publishes
// after a SUCCESSFUL commit, and the single observation lease an authority
// owns. These are the two types the T25 card's Required design / Interfaces
// section mandates:
//     HeldSnapshot{ storeVersion, hint4, digest6, queueDepth }
//     SnapshotObservationLease
// This child is PURELY ADDITIVE: it addeth no behaviour to the running system
// and toucheth no frozen contract. The widths are REUSE'D from the frozen
// BleLinkInfoConstants (NODE_HINT_BYTES, SHORT_DIGEST_BYTES) -- they are
// referenced, NEVER re-derived -- so the on-wire canonical forms stay law.
// ---------------------------------------------------------------------------

/**
 * An immutable, atomically-publishable snapshot of the held set. GATT reads
 * receiv'e a copy of the last committed value; the compute that produceth it
 * runneth on the store executor after commit (the platform child wires that).
 *
 *  - storeVersion: the store generation token. A stale compute may NOT overwrite
 *    a snapshot carrying a newer version; equality/hash are by content.
 *  - hint4 / digest6: the canonical node hint and short digest, exact widths
 *    enforced against the frozen constants; defensively copied on the way in.
 *  - queueDepth: the already-saturated held-set depth, confined to the one
 *    on-wire byte (0..255). Saturation of a raw count is the compute's law; the
 *    value type enforcesth only the representable range.
 */
class HeldSnapshot(
    val storeVersion: Long,
    hint4: ByteArray,
    digest6: ByteArray,
    val queueDepth: Int,
) {
    val hint4: ByteArray = hint4.copyOf()
    val digest6: ByteArray = digest6.copyOf()

    init {
        require(storeVersion >= 0L) { "storeVersion must be a nonnegative generation token" }
        require(this.hint4.size == BleLinkInfoConstants.NODE_HINT_BYTES) {
            "hint4 must be exactly ${BleLinkInfoConstants.NODE_HINT_BYTES} octets"
        }
        require(this.digest6.size == BleLinkInfoConstants.SHORT_DIGEST_BYTES) {
            "digest6 must be exactly ${BleLinkInfoConstants.SHORT_DIGEST_BYTES} octets"
        }
        require(queueDepth in 0..255) { "queueDepth must lie within one on-wire byte (0..255)" }
    }

    /** A defensive copy for a GATT-read consumer; the stored arrays never leak. */
    fun copyHint4(): ByteArray = hint4.copyOf()
    fun copyDigest6(): ByteArray = digest6.copyOf()

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is HeldSnapshot) return false
        return storeVersion == other.storeVersion &&
            queueDepth == other.queueDepth &&
            hint4.contentEquals(other.hint4) &&
            digest6.contentEquals(other.digest6)
    }

    override fun hashCode(): Int {
        var result = storeVersion.hashCode()
        result = 31 * result + queueDepth
        result = 31 * result + hint4.contentHashCode()
        result = 31 * result + digest6.contentHashCode()
        return result
    }
}

/**
 * The ONE observation lease an authority holdeth over the store's held-set
 * registry for the life of a runtime. It make'th the card's "one observation
 * lease per runtime; close removeth it" and section-13's "release lease once"
 * observable and testable:
 *  - it is born active;
 *  - close() is idempotent: only the FIRST call transitioneth active->closed
 *    and releaseth exactly once (the release action is invoc'd by no successor);
 *  - after close the lease is INERT -- a stale or rolled-back notification that
 *    consulteth isActive findeth it false and so driveth no compute.
 * The release action is the platform child's to supply (it owns the store
 * registration); this type owneth the SINGLE-RELEASE + idempotent-close law.
 */
class SnapshotObservationLease(private val onRelease: (() -> Unit)? = null) {
    private val active = AtomicBoolean(true)
    private val closes = AtomicInteger(0)

    val isActive: Boolean get() = active.get()
    val closeCount: Int get() = closes.get()

    /** True iff THIS call perform'd the active->closed transition and the one release. */
    fun close(): Boolean {
        if (active.compareAndSet(true, false)) {
            closes.incrementAndGet()
            onRelease?.invoke()
            return true
        }
        return false
    }
}
