package io.godstone.mesh.transport

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * ANDROID-05-A — a FAILED START may not suppress retry (`BleTransport.kt:200-209`).
 *
 * The R1 supplement, in its own words: `start()` set `isStarted = true` BEFORE `gattServer.start()`;
 * "the false return leaves that flag set. A second call returns at the initial guard. `isRunning` can
 * be false while retry is suppressed." AND ITS WARNING IS FOLLOWED HERE: "`isRunning == false` alone
 * misses the defect" -- so these arms COUNT THE OS START ATTEMPTS through the injectable GATT
 * boundary, which is the only observation that can tell a suppressed retry from a retried one.
 *
 * W01 THE POSITIVE CONTROL: a first attempt that succeedeth starteth the transport and advertiseth.
 * W02 THE SUPPLEMENT'S SCHEDULE: first attempt FAILS -> completely non-started -> the SECOND start()
 *     ATTEMPTETH the OS start again and succeedeth.
 *
 * No device, emulator or radio is involved: the boundary is injected and the advertising hooks are a
 * fake that recordeth its calls.
 */
class ReadinessAndroid05aTest {

    private class CountingAttempts(private val outcomes: List<Boolean>) {
        var attempts: Int = 0
        fun next(): Boolean {
            val outcome = outcomes.getOrElse(attempts) { false }
            attempts += 1
            return outcome
        }
    }

    private class RecordingAdvertiser : AdvertisingHooks {
        var starts: Int = 0
        override val isAvailable: Boolean get() = true
        override fun dispatchStart(
            settings: BleAdvertiseSettings,
            instructions: List<AdvertiseInstruction>,
            callback: (AdvertisingResult) -> Unit
        ): Boolean {
            starts += 1
            callback(AdvertisingResult.Success)
            return true
        }
        override fun dispatchStop(): Boolean = true
    }

    /** The in-memory identity storage the sibling courts use; no device, no prefs. */
    private class InMemoryIdentityStorage : io.godstone.mesh.identity.IdentityStorage {
        private var v1: ByteArray? = null
        private var legacy: io.godstone.mesh.identity.LegacyIdentityMaterial? = null
        override fun readV1State(): ByteArray? = v1?.copyOf()
        override fun readLegacyMaterial(): io.godstone.mesh.identity.LegacyIdentityMaterial? = legacy
        override fun hasPartialLegacy(): Boolean = false
        override fun writeV1State(state: ByteArray): Boolean { v1 = state.copyOf(); return true }
        override fun migrateLegacyToV1(state: ByteArray): Boolean {
            v1 = state.copyOf(); legacy = null; return true
        }
        override fun clear(): Boolean { v1 = null; legacy = null; return true }
    }

    private fun identity(): io.godstone.mesh.identity.Identity =
        io.godstone.mesh.identity.Identity.loadOrCreate(InMemoryIdentityStorage())

    @Test
    fun testW01ThePositiveControlASuccessfulFirstAttemptStarteth() {
        val attempts = CountingAttempts(listOf(true))
        val hooks = RecordingAdvertiser()
        val transport = BleTransport(
            identity = identity(), advertisingHooks = hooks,
            serverStartAttempt = { attempts.next() })
        transport.start()
        assertEquals("the OS start must have been attempted once", 1, attempts.attempts)
        assertTrue("a successful first attempt must start the transport", transport.isStartedForTest())
    }

    @Test
    fun testW02AFailedFirstAttemptMustNotSuppressTheSecond() {
        val attempts = CountingAttempts(listOf(false, true))
        val hooks = RecordingAdvertiser()
        val transport = BleTransport(
            identity = identity(), advertisingHooks = hooks,
            serverStartAttempt = { attempts.next() })
        transport.start()
        assertEquals("the first attempt must have been attempted", 1, attempts.attempts)
        assertFalse("a transport whose OS start FAILED is not running", transport.isRunning)
        transport.start()                       // THE RETRY
        assertEquals(
            "a failed start SUPPRESSED retry: the second start() returned at the guard without " +
                "attempting GATT startup at all",
            2, attempts.attempts)
        assertTrue("the retry's successful attempt must start the transport",
            transport.isStartedForTest())
    }
}
