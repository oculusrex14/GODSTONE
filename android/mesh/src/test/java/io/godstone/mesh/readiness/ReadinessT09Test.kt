package io.godstone.mesh.readiness

import io.godstone.mesh.identity.Identity
import io.godstone.mesh.store.InMemoryMessageStore
import io.godstone.mesh.transport.AdvertiseInstruction
import io.godstone.mesh.transport.AdvertisingFailure
import io.godstone.mesh.transport.AdvertisingHooks
import io.godstone.mesh.transport.AdvertisingResult
import io.godstone.mesh.transport.BleAdvertiseSettings
import io.godstone.mesh.transport.BleAdvertiser
import io.godstone.mesh.transport.BleAdvertisingPayload
import io.godstone.mesh.transport.BleLinkInfoConstants
import io.godstone.mesh.transport.BleTransport
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.util.ArrayList

/**
 * T09: the mesh advertises only the canonical service UUID.
 *
 * The legacy advertisement must carry the Flags AD and the complete 128-bit
 * Service Class UUID list for the canonical service, and nothing else: no
 * LinkInfo service data, no manufacturer data, no local name and no identity
 * hint. The full 13-octet LinkInfo record is served by GATT. The tests
 * inspect the real instruction stream handed to the advertising hooks, so a
 * production regression that re-adds an on-air field is caught by the
 * adapter assertion before the radio ever sees it.
 */
class ReadinessT09Test {

    private class RecordingHooks : AdvertisingHooks {
        var available: Boolean = true
        var throwSecurity: Boolean = false
        var fireFailureCode: Int? = null
        var acceptSubmission: Boolean = true
        val starts = ArrayList<Pair<BleAdvertiseSettings, List<AdvertiseInstruction>>>()
        var stopCount: Int = 0

        override val isAvailable: Boolean
            get() = available

        override fun dispatchStart(
            settings: BleAdvertiseSettings,
            instructions: List<AdvertiseInstruction>,
            callback: (AdvertisingResult) -> Unit
        ): Boolean {
            starts.add(Pair(settings, instructions.toList()))
            if (throwSecurity) {
                throw SecurityException("BLUETOOTH_ADVERTISE permission denied")
            }
            val code = fireFailureCode
            if (code != null) {
                callback(AdvertisingResult.Failure(failureForCode(code), code))
            } else {
                callback(AdvertisingResult.Success)
            }
            return acceptSubmission
        }

        override fun dispatchStop(): Boolean {
            stopCount += 1
            return true
        }

        private fun failureForCode(code: Int): AdvertisingFailure = when (code) {
            1 -> AdvertisingFailure.DATA_TOO_LARGE
            2 -> AdvertisingFailure.TOO_MANY_ADVERTISERS
            3 -> AdvertisingFailure.ALREADY_STARTED
            4 -> AdvertisingFailure.INTERNAL_ERROR
            5 -> AdvertisingFailure.FEATURE_UNSUPPORTED
            else -> AdvertisingFailure.UNKNOWN
        }
    }

    private class InMemoryIdentityStorage : io.godstone.mesh.identity.IdentityStorage {
        var v1State: ByteArray? = null
        var legacyMaterial: io.godstone.mesh.identity.LegacyIdentityMaterial? = null
        var failWrites = false

        override fun readV1State(): ByteArray? = v1State?.copyOf()
        override fun readLegacyMaterial(): io.godstone.mesh.identity.LegacyIdentityMaterial? = legacyMaterial
        override fun hasPartialLegacy(): Boolean = false
        override fun writeV1State(state: ByteArray): Boolean {
            if (failWrites) return false
            v1State = state.copyOf()
            return true
        }
        override fun migrateLegacyToV1(v1State: ByteArray): Boolean {
            if (failWrites) return false
            this.v1State = v1State.copyOf()
            this.legacyMaterial = null
            return true
        }
        override fun clear(): Boolean {
            v1State = null
            legacyMaterial = null
            return true
        }
    }

    private class Fixture(val identity: Identity, val hooks: RecordingHooks, val transport: BleTransport)

    private fun newFixture(): Fixture {
        val identity = Identity.loadOrCreate(InMemoryIdentityStorage())
        val hooks = RecordingHooks()
        val transport = BleTransport(
            identity = identity,
            store = InMemoryMessageStore(),
            advertisingHooks = hooks
        )
        return Fixture(identity, hooks, transport)
    }

    private fun readyTransport(fixture: Fixture): BleTransport {
        fixture.transport.gattServer.markServiceReadyForTest(true)
        return fixture.transport
    }

    private fun onlyInstructions(hooks: RecordingHooks): List<AdvertiseInstruction> {
        assertEquals("exactly one submission expected", 1, hooks.starts.size)
        return hooks.starts[0].second
    }

    @Test
    fun testCanonicalPayloadIsServiceUuidOnly() {
        val payload = BleAdvertisingPayload.canonical(BleTransport.SERVICE_UUID)
        assertEquals("one service uuid", 1, payload.serviceUuids.size)
        assertEquals(BleTransport.SERVICE_UUID, payload.serviceUuids[0])
        assertTrue("no service data on air", payload.serviceData().isEmpty())
        assertTrue("no manufacturer data on air", payload.manufacturerData().isEmpty())
        assertFalse("no local name on air", payload.includesDeviceName)
        assertFalse("no tx power on air", payload.includesTxPower)
        assertTrue("canonical payload fits the legacy budget", payload.fitsLegacyBudget())
    }

    @Test
    fun testDispatchedInstructionStreamMatchesCanonical() {
        val fixture = newFixture()
        readyTransport(fixture)
        assertTrue("submission accepted", fixture.transport.startAdvertisingNow())

        val recorded = onlyInstructions(fixture.hooks)
        assertEquals(
            "the platform builder receives exactly the canonical instruction stream",
            listOf<AdvertiseInstruction>(
                AdvertiseInstruction.AddServiceUuid(BleTransport.SERVICE_UUID),
                AdvertiseInstruction.IncludeDeviceName(false),
                AdvertiseInstruction.IncludeTxPowerLevel(false)
            ),
            recorded
        )
        assertEquals(
            "the connectable low-latency settings are submitted unchanged",
            fixture.transport.canonicalAdvertiseSettings(),
            fixture.hooks.starts[0].first
        )
        assertEquals(AdvertisingResult.Success, fixture.transport.lastAdvertisingResult)
    }

    @Test
    fun testLinkInfoServedByGattNotOnAir() {
        val fixture = newFixture()
        readyTransport(fixture)
        val snapshot = fixture.transport.refreshLocalLinkInfoSnapshotSync()
        assertNotNull("the LinkInfo snapshot exists to be served", snapshot)
        val bytes = fixture.transport.getLocalLinkInfoBytes()
        assertNotNull(bytes)
        assertEquals(
            "the whole record is served by GATT",
            BleLinkInfoConstants.LINK_INFO_BYTES,
            bytes!!.size
        )
        assertArrayEquals(bytes, fixture.transport.gattServer.linkInfoProvider())

        fixture.transport.startAdvertisingNow()
        val recorded = onlyInstructions(fixture.hooks)
        assertFalse(
            "no LinkInfo bytes may ride the advertisement",
            recorded.any { it is AdvertiseInstruction.AddServiceData }
        )
        assertFalse(
            "no manufacturer data may ride the advertisement",
            recorded.any { it is AdvertiseInstruction.AddManufacturerData }
        )
    }

    @Test
    fun testLegacyPayloadBudgetAccounting() {
        val canonical = BleAdvertisingPayload.canonical(BleTransport.SERVICE_UUID)
        assertTrue("Flags AD plus one 128-bit Service UUID List AD fit", canonical.fitsLegacyBudget())
        val withServiceData = BleAdvertisingPayload.canonical(BleTransport.SERVICE_UUID)
            .addServiceData(BleTransport.SERVICE_UUID, ByteArray(BleLinkInfoConstants.LINK_INFO_BYTES))
        assertFalse(
            "the historical defect: LinkInfo service data exceeds the legacy budget",
            withServiceData.fitsLegacyBudget()
        )
        assertTrue(withServiceData.legacyOnAirOctets() > 31)
        val withManufacturer = BleAdvertisingPayload.canonical(BleTransport.SERVICE_UUID)
            .addManufacturerData(0x02E0, ByteArray(BleLinkInfoConstants.LINK_INFO_BYTES))
        assertFalse("manufacturer data exceeds the budget", withManufacturer.fitsLegacyBudget())
        val withName = BleAdvertisingPayload.canonical(BleTransport.SERVICE_UUID)
        withName.includesDeviceName = true
        assertFalse("a device name inclusion exceeds the budget", withName.fitsLegacyBudget())
    }

    @Test
    fun testOversizedPayloadRefusedBeforePlatform() {
        val hooks = RecordingHooks()
        val advertiser = BleAdvertiser(hooks)
        val oversized = BleAdvertisingPayload.canonical(BleTransport.SERVICE_UUID)
            .addServiceData(BleTransport.SERVICE_UUID, ByteArray(BleLinkInfoConstants.LINK_INFO_BYTES))
        val started = advertiser.start(fixtureSettings(), oversized)
        assertFalse("the adapter assertion rejects the oversized payload", started)
        assertEquals("nothing reaches the platform", 0, hooks.starts.size)
        val result = advertiser.lastResult
        assertTrue(result is AdvertisingResult.Failure)
        val failure = result as AdvertisingResult.Failure
        assertEquals(AdvertisingFailure.DATA_TOO_LARGE, failure.reason)
        assertEquals(1, failure.errorCode)
    }

    @Test
    fun testSemanticNegativeReAddingServiceDataFailsTheAdapterAssertion() {
        // The mutation under test: a production edit that re-adds the LinkInfo
        // record to the canonical advertisement. The canonical payload builder
        // and the dispatcher assertions below must jointly refuse it.
        val tainted = BleAdvertisingPayload.canonical(BleTransport.SERVICE_UUID)
            .addServiceData(
                BleTransport.SERVICE_UUID,
                ByteArray(BleLinkInfoConstants.LINK_INFO_BYTES) { index -> (index + 1).toByte() }
            )
        assertFalse("the budget audit refuses the tainted payload", tainted.fitsLegacyBudget())

        val hooks = RecordingHooks()
        val advertiser = BleAdvertiser(hooks)
        assertFalse("the adapter refuses to dispatch it", advertiser.start(fixtureSettings(), tainted))
        assertEquals(0, hooks.starts.size)
        assertTrue(advertiser.lastResult is AdvertisingResult.Failure)

        // The untainted canonical path still succeeds immediately after,
        // proving the refusal is the payload's, not the adapter being broken.
        val clean = BleAdvertisingPayload.canonical(BleTransport.SERVICE_UUID)
        assertTrue(advertiser.start(fixtureSettings(), clean))
        assertEquals(AdvertisingResult.Success, advertiser.lastResult)
        assertEquals(1, hooks.starts.size)
    }

    @Test
    fun testPlatformStartFailureSurfacesTypedError() {
        val fixture = newFixture()
        readyTransport(fixture)
        fixture.hooks.fireFailureCode = 3
        assertFalse(fixture.transport.startAdvertisingNow())
        val result = fixture.transport.lastAdvertisingResult
        assertTrue("the platform failure is typed, not swallowed", result is AdvertisingResult.Failure)
        val failure = result as AdvertisingResult.Failure
        assertEquals(AdvertisingFailure.ALREADY_STARTED, failure.reason)
        assertEquals(3, failure.errorCode)
    }

    @Test
    fun testPermissionDenialIsTypedAndLeavesStateClean() {
        val fixture = newFixture()
        readyTransport(fixture)
        fixture.hooks.throwSecurity = true
        assertFalse("no crash escapes the permission denial", fixture.transport.startAdvertisingNow())
        val result = fixture.transport.lastAdvertisingResult
        assertTrue(result is AdvertisingResult.Failure)
        assertEquals(
            AdvertisingFailure.PERMISSION_DENIED,
            (result as AdvertisingResult.Failure).reason
        )
        // Recovery: once the denial stops, a fresh submission succeeds and the
        // previous authoritative (not advertising) state was never half-opened.
        fixture.hooks.throwSecurity = false
        assertTrue(fixture.transport.startAdvertisingNow())
        assertEquals(AdvertisingResult.Success, fixture.transport.lastAdvertisingResult)
        fixture.transport.stopAdvertisingNow()
    }

    @Test
    fun testAdapterUnavailableIsTypedNotSilent() {
        val fixture = newFixture()
        readyTransport(fixture)
        fixture.hooks.available = false
        assertFalse(fixture.transport.startAdvertisingNow())
        val result = fixture.transport.lastAdvertisingResult
        assertTrue(result is AdvertisingResult.Failure)
        assertEquals(
            AdvertisingFailure.ADAPTER_UNAVAILABLE,
            (result as AdvertisingResult.Failure).reason
        )
        assertEquals("nothing was dispatched", 0, fixture.hooks.starts.size)
    }

    @Test
    fun testServiceNotReadyGateIsTyped() {
        val fixture = newFixture()
        // gattServer.isServiceReady is false until the service registration completes.
        assertFalse(fixture.transport.startAdvertisingNow())
        val result = fixture.transport.lastAdvertisingResult
        assertTrue(result is AdvertisingResult.Failure)
        assertEquals(
            AdvertisingFailure.SERVICE_NOT_READY,
            (result as AdvertisingResult.Failure).reason
        )
        assertEquals("refused before dispatch", 0, fixture.hooks.starts.size)
        readyTransport(fixture)
        assertTrue(fixture.transport.startAdvertisingNow())
        assertEquals(AdvertisingResult.Success, fixture.transport.lastAdvertisingResult)
    }

    @Test
    fun testStopWithoutOutstandingSubmissionIsNoOpNotFailure() {
        val fixture = newFixture()
        assertNull("no result recorded yet", fixture.transport.lastAdvertisingResult)
        assertTrue("stop without a start is a clean no-op", fixture.transport.stopAdvertisingNow())
        assertEquals("the platform saw nothing", 0, fixture.hooks.stopCount)
        assertFalse(
            "a no-op is never a failure",
            fixture.transport.lastAdvertisingResult is AdvertisingResult.Failure
        )
        readyTransport(fixture)
        assertTrue(fixture.transport.startAdvertisingNow())
        assertTrue(fixture.transport.stopAdvertisingNow())
        assertEquals(1, fixture.hooks.stopCount)
        assertTrue("a second stop is a no-op too", fixture.transport.stopAdvertisingNow())
        assertEquals(1, fixture.hooks.stopCount)
    }

    @Test
    fun testScannerSharesTheCanonicalAdvertisedUuid() {
        val fixture = newFixture()
        readyTransport(fixture)
        fixture.transport.startAdvertisingNow()
        val recorded = onlyInstructions(fixture.hooks)
        val advertisedUuids = ArrayList<java.util.UUID>()
        for (instruction in recorded) {
            if (instruction is AdvertiseInstruction.AddServiceUuid) {
                advertisedUuids.add(instruction.uuid)
            }
        }
        assertEquals("exactly one advertised uuid", 1, advertisedUuids.size)
        assertEquals(
            "the scanner filter and the advertisement share one canonical uuid",
            advertisedUuids[0],
            fixture.transport.canonicalScanFilterServiceUuid()
        )
    }

    @Test
    fun testNoIdentityHintOrRecordLeaksIntoTheAir() {
        val fixture = newFixture()
        readyTransport(fixture)
        val snapshot = fixture.transport.refreshLocalLinkInfoSnapshotSync()
        assertNotNull(snapshot)
        val linkInfo = fixture.transport.getLocalLinkInfoBytes()!!
        val hint = fixture.identity.nodeHint
        fixture.transport.startAdvertisingNow()
        val recorded = onlyInstructions(fixture.hooks)
        for (instruction in recorded) {
            when (instruction) {
                is AdvertiseInstruction.AddServiceData -> fail("service data must not ride the air")
                is AdvertiseInstruction.AddManufacturerData -> fail("manufacturer data must not ride the air")
                is AdvertiseInstruction.IncludeDeviceName ->
                    assertFalse("the local name must stay off air", instruction.include)
                is AdvertiseInstruction.IncludeTxPowerLevel ->
                    assertFalse("tx power must stay off air", instruction.include)
                else -> {}
            }
        }
        // The very bytes that were removed from the air are exactly those the
        // GATT server continues to serve: prove they exist and carry the hint.
        assertEquals(BleLinkInfoConstants.LINK_INFO_BYTES, linkInfo.size)
        var carried = false
        var position = 0
        while (position + hint.size <= linkInfo.size) {
            if (linkInfo.copyOfRange(position, position + hint.size).contentEquals(hint)) {
                carried = true
                break
            }
            position += 1
        }
        assertTrue("the snapshot genuinely embeds the identity hint (leak surface)", carried)
    }

    private fun fixtureSettings(): BleAdvertiseSettings = BleAdvertiseSettings(
        mode = 2,
        txPowerLevel = 3,
        connectable = true
    )
}
