package io.godstone.mesh.store

// ---------------------------------------------------------------------------
// T32 SHARED RETENTION CONTRACT (android) -- the exact section14 (rows 57-72)
// receipt-relative, non-replenishing retention algorithm. ADDITIVE, PURE-KOTLIN
// seam: it performs NO wall-clock read and NO SQLite access -- the monotonic now
// and the continuity-proving platform adapter are INJECTED, so the ordering /
// transactional / idempotence / continuity / immutable-field laws are EXECUTABLE
// on the host via deterministic fakes (no device/SDK/network result is fabricated).
// The runtime binds this seam to the store; the sealed wall-clock MessageStore
// received_at path (the current incomplete implementation the card names) is NOT
// rewritten here -- blast-radius discipline, as the T31 migration engine.
//
// The iOS twin (ios/Godstone/Sources/GodstoneMesh/RetentionClock.swift) mirrors
// this contract ONE-FOR-ONE and its court asserts the SAME laws (dual-court parity).
// ---------------------------------------------------------------------------

/** The kind of held row: selects the canonical local lifetime. NOT a sender field. */
enum class MessageKind { DIRECT, SOS, GROUP, BROADCAST, BULK }

/** The clock-continuity verdict a platform adapter returns for one reopen. */
sealed class ClockContinuityStamp {
    /** The monotonic clock is provably continuous across the checkpoint (same boot). */
    object Proven : ClockContinuityStamp()
    /** Continuity is not provable (a reboot / an unproven adapter): take the conservative branch. */
    object Unknown : ClockContinuityStamp()
    /** An identity-reset event: a fresh boot identity; continuity is broken. */
    data class Reset(val bootIdentity: String) : ClockContinuityStamp()
}

/** Terminal cause of an expiry. Distinct reasons; unknown is never silently tolerated. */
enum class ExpiryReason { NotExpired, LifetimeElapsed, MaxHold, ClockContinuityLost }

/**
 * The durable, per-row retention state persisted across process death and reboot.
 * Holds NO sender timestamp -- "No sender timestamp controls these durations."
 */
data class RetentionCheckpoint(
    val msgId: String,
    val kind: MessageKind,
    val remainingMs: Long,
    val checkpointMonotonicMs: Long,
    val lastWallCheckpointMs: Long,
    val discontinuityCount: Int,
    val priority: Int,
    val firstReceiptId: String,
)

/**
 * The injected continuity oracle. A real platform adapter must PROVE monotonic
 * continuity from tested platform information -- uptime alone after a reboot is
 * insufficient -- and must return [ClockContinuityStamp.Unknown] when it cannot.
 * The host tests inject a deterministic fake; the algorithm never trusts its clock.
 */
interface MonotonicClockAdapter {
    fun proveContinuity(previous: RetentionCheckpoint, nowMono: Long): ClockContinuityStamp
}

/**
 * The exact section14 algorithm. Stateless: all mutable retention state lives in the
 * persisted [RetentionCheckpoint] the caller passes in and receives back, so a
 * same-boot crash reuses the ORIGINAL persisted monotonic anchor by construction
 * (the anchor is simply not re-armed), avoiding loss of uncheckpointed elapsed time.
 */
object RetentionClock {
    const val MS_PER_HOUR: Long = 3_600_000L
    const val DISCONTINUITY_LIMIT: Int = 32
    const val CHECKPOINT_CADENCE_MS: Long = 60_000L

    /** Canonical LOCAL policy. No sender timestamp controls any of these durations. */
    val lifetimeMs: Map<MessageKind, Long> = mapOf(
        MessageKind.DIRECT to 7L * 24 * MS_PER_HOUR,     // 7 days
        MessageKind.SOS to MS_PER_HOUR * 24L,             // 24 hours
        MessageKind.GROUP to MS_PER_HOUR * 24L,           // 24 hours
        MessageKind.BROADCAST to MS_PER_HOUR * 24L,       // 24 hours
        MessageKind.BULK to MS_PER_HOUR,                  // 1 hour
    )
    val maxHoldMs: Long = 7L * 24 * MS_PER_HOUR          // MAX_HOLD 7 days
    val tombstoneMs: Long = 8L * 24 * MS_PER_HOUR        // dedup tombstones 8 days

    /** A NEW receipt is granted the full local lifetime EXACTLY ONCE, anchored at [nowMono]. */
    fun admit(msgId: String, kind: MessageKind, priority: Int, firstReceiptId: String, nowMono: Long, bootIdentity: String): RetentionCheckpoint =
        RetentionCheckpoint(msgId, kind, lifetimeMs.getValue(kind), nowMono, nowMono, 0, priority, firstReceiptId)

    private fun elapsedSince(anchor: Long, now: Long): Long = if (now >= anchor) now - anchor else 0L

    /** The pure expiry predicate: expired iff the remaining lifetime or MAX_HOLD is reached. */
    fun isExpired(cp: RetentionCheckpoint, nowMono: Long): ExpiryReason {
        if (cp.remainingMs <= 0L) return ExpiryReason.MaxHold.alsoReason(cp, nowMono)
        if (elapsedSince(cp.checkpointMonotonicMs, nowMono) >= maxHoldMs) return ExpiryReason.MaxHold
        return ExpiryReason.NotExpired
    }

    private fun ExpiryReason.alsoReason(cp: RetentionCheckpoint, nowMono: Long): ExpiryReason =
        if (elapsedSince(cp.checkpointMonotonicMs, nowMono) >= maxHoldMs) ExpiryReason.MaxHold else ExpiryReason.LifetimeElapsed

    /**
     * The reopen / checkpoint branch (section14 pseudocode), applied atomically.
     * Returns the new persisted checkpoint AND the terminal [ExpiryReason].
     * On a proven-continuous (same-boot) reopen the debit is the true monotonic delta
     * from the ORIGINAL anchor -- uncheckpointed elapsed time is NOT lost.
     * Otherwise the conservative branch counts a discontinuity, debits a bounded,
     * nonnegative wall estimate floored at one hour, and at the 32nd discontinuity
     * expires with CLOCK_CONTINUITY_LOST. remainingMs is NEVER replenished.
     */
    fun checkpoint(cp: RetentionCheckpoint, nowMono: Long, wallEstimateMs: Long, adapter: MonotonicClockAdapter): Pair<RetentionCheckpoint, ExpiryReason> {
        val stamp = adapter.proveContinuity(cp, nowMono)
        val debit: Long
        var disc = cp.discontinuityCount
        if (stamp === ClockContinuityStamp.Proven) {
            debit = elapsedSince(cp.checkpointMonotonicMs, nowMono).coerceAtLeast(0L)
        } else {
            disc += 1
            val boundedWall = if (wallEstimateMs >= 0L) wallEstimateMs else 0L          // nonnegative wall-delta hint
            debit = boundedWall.coerceAtLeast(MS_PER_HOUR)                                // at least one hour
        }
        val remaining = (cp.remainingMs - debit).coerceAtLeast(0L)                       // never below 0; never replenished
        val expiredByContinuity = disc >= DISCONTINUITY_LIMIT
        val newCp = cp.copy(
            remainingMs = if (expiredByContinuity) 0L else remaining,
            checkpointMonotonicMs = if (stamp === ClockContinuityStamp.Proven) nowMono else cp.checkpointMonotonicMs,
            lastWallCheckpointMs = nowMono,
            discontinuityCount = disc,
        )
        val reason: ExpiryReason = when {
            expiredByContinuity -> ExpiryReason.ClockContinuityLost
            else -> isExpired(newCp, nowMono)
        }
        return Pair(newCp, reason)
    }

    /** A durable checkpoint commit: persists at least every [CHECKPOINT_CADENCE_MS]. */
    fun dueCheckpoint(cp: RetentionCheckpoint, nowMono: Long): Boolean =
        elapsedSince(cp.checkpointMonotonicMs, nowMono) >= CHECKPOINT_CADENCE_MS
}

/** The effect of one expiry transaction (never fabricated; distinct terminal states). */
enum class RetentionEffect { Committed, HeldActive, AlreadyExpiredRejected, Cancelled }

/**
 * The per-row retention transaction store, modelled exactly. Admits a NEW receipt
 * once; replays after expiry MUST be rejected (never re-granting a lifetime); an
 * ACK retires the row; a cancel stops scheduling but cannot recall relayed copies.
 */
object RetentionTx {
    const val MS_PER_HOUR: Long = RetentionClock.MS_PER_HOUR

    /** Admit a brand-new receipt (grants the full lifetime exactly once). */
    fun admitNew(cp: RetentionCheckpoint): RetentionEffect =
        if (cp.remainingMs <= 0L) RetentionEffect.AlreadyExpiredRejected else RetentionEffect.Committed

    /** A REPLAY after expiry: never re-grants; an expired row stays rejected. */
    fun replay(cp: RetentionCheckpoint, nowMono: Long): RetentionEffect =
        if (RetentionClock.isExpired(cp, nowMono) != ExpiryReason.NotExpired || cp.remainingMs <= 0L)
            RetentionEffect.AlreadyExpiredRejected
        else
            RetentionEffect.HeldActive

    /** A recipient ACK retires an unexpired row; replaying it cannot resurrect it. */
    fun ack(cp: RetentionCheckpoint, nowMono: Long): RetentionEffect =
        if (RetentionClock.isExpired(cp, nowMono) != ExpiryReason.NotExpired)
            RetentionEffect.AlreadyExpiredRejected
        else
            RetentionEffect.Committed

    /** A cancel stops local scheduling; it cannot recall already-relayed copies. */
    fun cancel(cp: RetentionCheckpoint): RetentionEffect = RetentionEffect.Cancelled
}
