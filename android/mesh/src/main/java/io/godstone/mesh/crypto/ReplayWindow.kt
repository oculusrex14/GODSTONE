package io.godstone.mesh.crypto

/**
 * T05: replay-window state that can never be poisoned by an unauthenticated
 * frame, and an unsigned-nonce parser that rejects reserved and out-of-policy
 * values before any subtraction.
 *
 * Two defects this class removes from the previous inline implementation:
 *
 *  1. Commit-before-authenticate. The old path advanced the window before the
 *     AEAD verification, so a FORGED frame with a far-future nonce shifted the
 *     window and then caused every legitimate retransmission to be rejected as
 *     a replay (the "forged-high-then-valid" attack). Now [preview] computes
 *     the would-be state WITHOUT mutation, the caller authenticates, and
 *     [commit] applies the previewed plan only after authentication succeeds.
 *     A failed authenticate mutates nothing.
 *
 *  2. Unchecked narrowing to Int. The old path narrowed unchecked nonce
 *     differences (`nonce - highest`, `highest - nonce`) with `.toInt()`. A
 *     difference past the 32-bit range silently wrapped, e.g. a forward jump
 *     of 2^32 + 3 narrowed to 3 and corrupted the window. Now every jump is
 *     classified with Long comparisons FIRST; narrowing happens only after
 *     the difference is proven to be below [windowSize].
 *
 * Both halves of the class are invoked under the owning session's replay
 * lock, so preview -> authenticate -> commit is one atomic session operation.
 */
class ReplayWindow(val windowSize: Int = DEFAULT_WINDOW) {

    /** Would-be window transition returned by [preview]; applied by [commit]. */
    sealed class Plan {
        /** Apply: shift/clear the bitmap, advance highest, mark [index] seen. */
        data class Accept(
            val nonce: Long,
            /** Forward distance proven < windowSize, or null for a clear-all. */
            val forwardShift: Int?,
            /** Bit index to mark seen. */
            val index: Int,
        ) : Plan()

        /** Replay or outside the window: no plan, no mutation. */
        data object Reject : Plan()
    }

    private var highestReceived: Long = -1L
    private val bits = java.util.BitSet(windowSize)

    /**
     * Compute the transition [nonce] would cause. Pure: no field changes.
     * Large forward jumps are classified by comparison BEFORE any narrowing
     * (T05: clear the bounded bitmap using comparisons before narrowing).
     */
    fun preview(nonce: Long): Plan {
        if (nonce > highestReceived) {
            val forward = nonce - highestReceived // Long arithmetic, no narrowing
            if (forward >= windowSize.toLong()) {
                // Whole window is left behind: the commit clears the bitmap.
                return Plan.Accept(nonce = nonce, forwardShift = -1,
                                   index = windowSize - 1)
            }
            // forward < windowSize <= Int range: narrowing is proven safe here.
            return Plan.Accept(nonce = nonce, forwardShift = forward.toInt(),
                               index = -1)
        }
        val backward = highestReceived - nonce // Long arithmetic, no narrowing
        if (backward >= windowSize.toLong()) return Plan.Reject
        // backward < windowSize: narrowing is proven safe here.
        val offset = backward.toInt()
        val index = windowSize - 1 - offset
        if (bits[index]) return Plan.Reject
        return Plan.Accept(nonce = nonce, forwardShift = 0, index = index)
    }

    /** Apply a previously previewed [plan]; the caller owns serialization. */
    fun commit(plan: Plan.Accept) {
        if (plan.nonce > highestReceived) {
            val shift = plan.forwardShift
            if (shift == null || shift < 0) {
                // Clear-all plan (forwardShift = -1) or malformed plan.
                bits.clear()
            } else {
                for (i in 0 until windowSize - shift) {
                    bits[i] = bits[i + shift]
                }
                for (i in windowSize - shift until windowSize) {
                    bits[i] = false
                }
            }
            highestReceived = plan.nonce
            bits[windowSize - 1] = true
        } else {
            bits[plan.index] = true
        }
    }

    /** Highest transport nonce accepted so far; -1 before any commit. */
    fun highest(): Long = highestReceived

    companion object {
        const val DEFAULT_WINDOW = 2048
    }
}

/**
 * Unsigned 64-bit transport nonce parser with the T05 policy gate.
 *
 * The 8 big-endian bytes are read as an unsigned value. Reserved and
 * out-of-policy values are rejected BEFORE any subtraction can happen:
 *
 *  - any byte pattern whose unsigned value is >= 2^63 (reads negative as a
 *    signed Long) is reserved - the sender's AtomicLong counter can never
 *    produce it, so it is a forged or malformed frame;
 *  - any value above [POLICY_CEILING] is out of policy - legitimate senders
 *    rekey at 2^20 transport messages, so a peer presenting nonces beyond
 *    2^21 without rekeying is not a conformant peer.
 */
object UnsignedNonce {

    sealed class Result {
        data class Valid(val value: Long) : Result()
        data class Rejected(val reason: String) : Result()
    }

    /** 2 * rekey limit: a conformant sender never exceeds this. */
    const val POLICY_CEILING: Long = 2L * (1L shl 20)

    fun parse(buffer: java.nio.ByteBuffer, offset: Int = 0): Result {
        val raw = buffer.getLong(offset)
        if (raw < 0L) {
            return Result.Rejected(
                "reserved nonce region: unsigned value >= 2^63 (raw " +
                    "0x" + java.lang.Long.toHexString(raw) + ")")
        }
        if (raw > POLICY_CEILING) {
            return Result.Rejected(
                "out-of-policy nonce " + raw +
                    ": conformant senders rekey at 2^20 transport messages")
        }
        return Result.Valid(raw)
    }
}