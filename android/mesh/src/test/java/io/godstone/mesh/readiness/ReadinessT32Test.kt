package io.godstone.mesh.readiness

import io.godstone.mesh.store.ClockContinuityStamp
import io.godstone.mesh.store.ExpiryReason
import io.godstone.mesh.store.MessageKind
import io.godstone.mesh.store.MonotonicClockAdapter
import io.godstone.mesh.store.RetentionCheckpoint
import io.godstone.mesh.store.RetentionClock
import io.godstone.mesh.store.RetentionEffect
import io.godstone.mesh.store.RetentionTx
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * T32 designated regression court (android) -- bounded receipt-relative retention
 * across restarts. Drives the pure [RetentionClock] contract through deterministic
 * injected [MonotonicClockAdapter] fakes and asserts the exact section14 laws:
 *   * a wall-clock ROLLBACK never extends retention (the debit hint is clamped nonnegative);
 *   * a wall-clock FORWARD jump may expire early (a bounded conservative debit, >= 1h);
 *   * a same-boot restart reuses the persisted monotonic anchor -- uncheckpointed elapsed
 *     time is not lost and no discontinuity is counted;
 *   * a reboot (unproven continuity) is bounded -- the 32nd discontinuity expires with
 *     CLOCK_CONTINUITY_LOST, never an indefinite retention by a restart loop;
 *   * an unknown clock takes the conservative branch with a NONNEGATIVE bounded estimate;
 *   * repeated malicious same-boot crash loops drain the shared lifetime without replenish;
 *   * the expiry transaction: a REPLAY after expiry is rejected (never re-grants), an ACK
 *     retires, a CANCEL stops scheduling -- and a duplicate is never re-admitted.
 * The iOS twin ReadinessT32Tests.swift asserts the SAME seven laws with identical names.
 */
class ReadinessT32Test {

    private companion object {
        const val HOUR: Long = 3_600_000L
        const val DAY: Long = 24L * HOUR

        fun proven(): MonotonicClockAdapter = object : MonotonicClockAdapter {
            override fun proveContinuity(previous: RetentionCheckpoint, nowMono: Long): ClockContinuityStamp = ClockContinuityStamp.Proven
        }
        fun unknown(): MonotonicClockAdapter = object : MonotonicClockAdapter {
            override fun proveContinuity(previous: RetentionCheckpoint, nowMono: Long): ClockContinuityStamp = ClockContinuityStamp.Unknown
        }
        fun newCp(msgId: String, kind: MessageKind, nowMono: Long): RetentionCheckpoint =
            RetentionClock.admit(msgId, kind, 1, "receipt-$msgId", nowMono, "boot-1")
    }

    // (1) a wall-clock rollback never extends retention
    @Test
    fun testClockRollbackNeverExtendsRetention() {
        var cp = newCp("m1", MessageKind.SOS, 100L)                 // remaining 24h
        cp = cp.copy(remainingMs = 10L * HOUR, discontinuityCount = 5)   // partially drained, 5 prior strikes
        val start = cp.remainingMs
        // a malicious / buggy adapter hands a large NEGATIVE wall-delta hint (a rolled-back wall clock);
        // the nonnegative clamp + the one-hour conservative floor must keep the debit nonnegative
        val (n, r) = RetentionClock.checkpoint(cp, 101L, -2L * DAY, unknown())
        assertTrue("a wall-clock rollback may only SHRINK retention, never extend it", n.remainingMs <= start)
        assertTrue("the debit is nonnegative -- the row advanced toward expiry, did not regress", n.remainingMs < start)
        assertEquals("the conservative branch counts exactly one discontinuity", 6, n.discontinuityCount)
        assertTrue("retention never exceeds the canonical local policy under any clock fiction", n.remainingMs <= RetentionClock.lifetimeMs.getValue(MessageKind.SOS))
    }

    // (2) a wall-clock forward jump may expire early (bounded conservative debit >= 1h)
    @Test
    fun testClockForwardMayExpireEarly() {
        val cp = newCp("m2", MessageKind.SOS, 0L)
        val (n, r) = RetentionClock.checkpoint(cp, 5L, 30L * DAY, unknown())    // a huge forward wall estimate
        assertTrue("a forward wall jump debits at least the one-hour floor", n.remainingMs <= cp.remainingMs - HOUR)
        assertEquals("one discontinuity is counted", 1, n.discontinuityCount)
        assertTrue("the far-future estimate fully drains the row early", n.remainingMs == 0L && r != ExpiryReason.NotExpired)
    }

    // (3) a same-boot restart reuses the persisted monotonic anchor
    @Test
    fun testSameBootRestartReusesMonotonicAnchor() {
        val cp = newCp("m3", MessageKind.SOS, 0L)
        // same-boot reopen 3h later, proven continuous: the ORIGINAL anchor 0 is reused, no strike, no re-arm
        val (n, r) = RetentionClock.checkpoint(cp, 3L * HOUR, 0L, proven())
        assertEquals("no discontinuity on a same-boot reopen", 0, n.discontinuityCount)
        assertEquals("the true monotonic delta drains the row", 21L * HOUR, n.remainingMs)
        assertTrue("not yet expired", r == ExpiryReason.NotExpired)
        assertTrue("re-checkpoint does NOT replenish toward the full lifetime", n.remainingMs <= RetentionClock.lifetimeMs.getValue(MessageKind.SOS))
    }

    // (4) a reboot with unproven continuity is bounded -- never an indefinite retention by restart loops
    @Test
    fun testRebootWithoutContinuityIsBoundedAndEventuallyExpires() {
        var cp = newCp("m4", MessageKind.DIRECT, 0L)     // 7-day lifetime
        var reason = ExpiryReason.NotExpired
        for (i in 1..32) {
            val (n, r) = RetentionClock.checkpoint(cp, i.toLong(), 0L, unknown())
            cp = n; reason = r
        }
        assertEquals("every unproven reopen counts a discontinuity", 32, cp.discontinuityCount)
        assertTrue("the 32nd discontinuity forces expiry", reason == ExpiryReason.ClockContinuityLost)
        assertEquals("the row is fully drained", 0L, cp.remainingMs)
    }

    // (5) an unknown clock takes the conservative branch with a NONNEGATIVE bounded estimate
    @Test
    fun testUnknownClockTakesConservativeBranch() {
        var cp = newCp("m5", MessageKind.SOS, 0L)
        for (i in 1..5) cp = RetentionClock.checkpoint(cp, i.toLong(), -1L, unknown()).first   // all-negative hints
        assertEquals("five conservative strikes", 5, cp.discontinuityCount)
        assertTrue("each strike debits exactly the one-hour floor (a negative hint is clamped to 0 then floored to 1h)",
            cp.remainingMs == 19L * HOUR)
        assertTrue("never a negative remaining lifetime", cp.remainingMs >= 0L)
    }

    // (6) repeated malicious same-boot crash loops drain the shared lifetime without replenish
    @Test
    fun testRepeatedMaliciousCrashBoundAndTombstoneDiscipline() {
        var cp = newCp("m6", MessageKind.DIRECT, 0L)      // 7-day = 168h lifetime, anchored at 0
        for (i in 1..40) cp = RetentionClock.checkpoint(cp, i.toLong() * HOUR, 0L, proven()).first   // 40 crash-reopens, 1h apart
        assertEquals("a same-boot crash loop counts NO discontinuity (continuity is proven)", 0, cp.discontinuityCount)
        assertEquals("each crash-reopen drains the shared lifetime from the persistent anchor -- never replenished",
            128L * HOUR, cp.remainingMs)
        assertTrue("still below the canonical full policy after 40 malicious reopens", cp.remainingMs <= RetentionClock.lifetimeMs.getValue(MessageKind.DIRECT))
    }

    // (7) the expiry transaction vs ACK / cancel and a replayed frame after expiry
    @Test
    fun testExpiryTransactionVsAckCancelAndReplayAfterExpiry() {
        val fresh = newCp("m7", MessageKind.BULK, 0L)
        val drained = fresh.copy(remainingMs = 0L)
        // a brand-new receipt is admitted once
        assertEquals("a fresh receipt commits", RetentionEffect.Committed, RetentionTx.admitNew(fresh))
        // an expired row can never be re-admitted / re-granted a lifetime
        assertEquals("admitting an already-expired row is rejected", RetentionEffect.AlreadyExpiredRejected, RetentionTx.admitNew(drained))
        // a REPLAY after expiry is rejected and must not resurrect
        assertEquals("replay after expiry is rejected", RetentionEffect.AlreadyExpiredRejected, RetentionTx.replay(drained, 999L))
        assertEquals("a replay of an expired row is still rejected", RetentionEffect.AlreadyExpiredRejected, RetentionTx.replay(drained, 1000L))
        // an ACK retires an unexpired row; a replay of a live row is merely held
        assertEquals("an ACK retires a live row", RetentionEffect.Committed, RetentionTx.ack(fresh, 0L))
        assertEquals("a live replay is held, not re-admitted", RetentionEffect.HeldActive, RetentionTx.replay(fresh, 0L))
        // a cancel stops scheduling (its own terminal state) and never re-grants
        assertEquals("a cancel is a distinct terminal effect", RetentionEffect.Cancelled, RetentionTx.cancel(drained))
        // the drained row's replay never became an admission (a duplicate is not re-admitted)
        assertTrue("no path re-granted the expired row", RetentionTx.replay(drained, 5L) != RetentionEffect.Committed)
    }
}
