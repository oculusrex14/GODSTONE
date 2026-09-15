package io.godstone.mesh.transport

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * ANDROID-04 — the hour-glasses may not be LENGTHENED by the wall clock.
 *
 * The audit's card recordeth two defects, and this court taketh the SECOND: the deadlines are
 * consumed from a clock that defaulteth to `System.currentTimeMillis()/1000L`
 * (`BleConnection.kt:31`), and "a wall-clock rollback can extend the deadline further".
 *
 * No scheduler is needed to expose it. The glass answereth by re-reading the clock on every
 * question (`now() >= armedMono`), so the arms below inject a clock that ROLLS BACK -- which is
 * what a user-set clock, an NTP step or a clock correction doeth on a real device -- and demand
 * that the bound still hold. A rollback is not a hypothetical: it is the ordinary consequence of
 * a wall clock, which is precisely why a deadline may not be built upon one.
 *
 * W01 THE POSITIVE CONTROL: an armed glass falls at its bound and not before.
 * W02 a wall-clock rollback may not LENGTHEN an armed glass.
 * W03 a SPENT glass may never UN-EXPIRE.
 * W04 the key-confirmation echo bound is proof against the same rollback.
 */
class ReadinessAndroid04Test {

    @Test
    fun testW01ThePositiveControlTheArmedGlassFallsAtItsBound() {
        var wall = 1_000_000L
        val glass = HandshakeDeadline({ wall })
        glass.arm()
        wall += HandshakeDeadline.HANDSECONDS - 1
        assertFalse("the armed glass fell before its bound", glass.expired())
        wall += 1
        assertTrue("the armed glass did not fall at its bound", glass.expired())
    }

    // -- W02 WAS WITHDRAWN, WITH ITS REASON, AND NOT SILENTLY ---------------------------------
    // W02 demanded that an armed glass still fall after a WALL-CLOCK ROLLBACK ate four seconds of
    // real time (arm; +5; -4; +5; the bound is ten seconds of REAL time). MEASURED: no class that
    // is handed a LYING clock can recover the elapsed time the lie destroyed -- the information is
    // not in the input. The high-water guard below proveth that a reached bound stayeth reached
    // (W03/W04), and it cannot invent the four seconds back. THE CARD'S STEP 1 IS THE ONLY ANSWER
    // to W02's demand, and it is a COMPOSITION change, not a class-local one: inject a MONOTONIC
    // source into the transport, keeping wall time for persisted metadata only. That remaineth
    // OWED and is recorded in the ledger; the arm was withdrawn rather than left as a red that
    // cannot be satisfied.

    @Test
    fun testW03ASpentGlassMayNeverUnExpire() {
        var wall = 1_000_000L
        val glass = HandshakeDeadline({ wall })
        glass.arm()
        wall += HandshakeDeadline.HANDSECONDS
        assertTrue("the control: the glass falls at its bound", glass.expired())
        wall -= 5
        assertTrue("a wall-clock rollback UN-EXPIRED a spent hour-glass", glass.expired())
    }

    @Test
    fun testW04ALapsedEchoBoundMayNotUnLapseOnARollback() {
        var wall = 1_000_000L
        val confirmation = KeyConfirmation({ wall })
        confirmation.issue(ByteArray(KeyConfirmation.CHALLENGE_BYTES))
        wall += KeyConfirmation.ECHOSECONDS
        assertTrue("the control: the echo bound lapses at its own term", confirmation.echoLapsed())
        wall -= 20
        assertTrue(
            "a wall-clock rollback UN-LAPSED a spent key-confirmation echo bound: an echo that " +
                "arrived too late would be admitted again",
            confirmation.echoLapsed()
        )
    }

    // -- the card's STEP 1: the COMPOSITION may not build a deadline on the wall clock ---------
    // The guard in the glass proveth that a REACHED bound stayeth reached. It cannot invent back
    // the real seconds a rollback destroyed, so the card's step 1 requireth the thing itself: a
    // MONOTONIC source injected into the transport, "keeping wall time for persisted metadata
    // only". The arm below therefore readeth the PRODUCTION DEFAULT at runtime and demandeth that
    // it is not the wall clock. It is a PROPERTY of the shipped object, not a spelling in a file:
    // it calles the very lambda the deadlines are built from.

    @Test
    fun testW05TheProductionDefaultDeadlineClockIsNotTheWallClock() {
        val connection = BleConnection(byteArrayOf(1, 2, 3, 4))
        val shipped = connection.defaultClockSecondsForTest()
        val wall = System.currentTimeMillis() / 1000L
        assertTrue(
            "the composition still feedeth the hour-glasses the WALL clock (shipped=$shipped, " +
                "wall=$wall): a rollback therefore still lengthens a bound by exactly the real " +
                "seconds the lie destroyed",
            shipped < wall - 86_400L
        )
    }
}
