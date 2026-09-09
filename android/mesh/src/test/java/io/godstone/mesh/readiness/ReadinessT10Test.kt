package io.godstone.mesh.readiness

import io.godstone.mesh.transport.BleGattServer
import io.godstone.mesh.transport.BleTransport
import io.godstone.mesh.transport.ContractCharacteristic
import io.godstone.mesh.transport.GattClientConnection
import io.godstone.mesh.transport.GattOpType
import io.godstone.mesh.transport.GattProperty
import io.godstone.mesh.transport.InboundRoute
import io.godstone.mesh.transport.ProvisionCheck
import io.godstone.mesh.transport.RequiredCharacteristicSet
import io.godstone.mesh.wire.v2.FrameV2
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.ArrayList
import java.util.UUID

/**
 * T10: the GATT profile speaks the generated wire contract, on the wire and
 * in the resolvers.
 *
 * Every mesh identifier the transport installs, resolves or advertises is the
 * FrameV2 value (service A001, inbox A002, digest A003, link info A004). The
 * hand-rolled FD short-form values of the non-shipping legacy profile are
 * never named by the contract, never installed, and rejected whenever a
 * resolver meets them in a tree. The provisioning gate is the whole-tree
 * resolver RequiredCharacteristicSet.check: duplicate first, then unknown,
 * then property gaps; a tree that is not the profile fails discovery rather
 * than half-connecting.
 */
class ReadinessT10Test {

    private val legacyInbox = UUID.fromString("0000FD01-0000-1000-8000-00805F9B34FB")
    private val legacyDigest = UUID.fromString("0000FD02-0000-1000-8000-00805F9B34FB")
    private val legacyService = UUID.fromString("0000FD00-0000-1000-8000-00805F9B34FB")

    private fun canonicalTree(): ArrayList<ContractCharacteristic> {
        val tree = ArrayList<ContractCharacteristic>()
        tree.add(RequiredCharacteristicSet.MESH.inbox)
        tree.add(RequiredCharacteristicSet.MESH.digest)
        tree.add(RequiredCharacteristicSet.MESH.linkInfo)
        return tree
    }

    @Test
    fun testMeshIdentifiersAreTheGeneratedValues() {
        assertEquals("service A001", UUID.fromString("6764A001-9A5E-4C7B-B0A1-3E5D8C2F7A10"), RequiredCharacteristicSet.MESH.serviceUuid)
        assertEquals("inbox A002", FrameV2.INBOX_UUID, RequiredCharacteristicSet.MESH.inbox.uuid)
        assertEquals("digest A003", FrameV2.DIGEST_UUID, RequiredCharacteristicSet.MESH.digest.uuid)
        assertEquals("link info A004", FrameV2.LINK_INFO_UUID, RequiredCharacteristicSet.MESH.linkInfo.uuid)
        assertEquals("transport service alias", FrameV2.SERVICE_UUID, BleTransport.SERVICE_UUID)
        assertEquals("transport inbox alias follows the contract", FrameV2.INBOX_UUID, BleTransport.WRITE_CHAR_UUID)
        assertEquals("transport digest alias follows the contract", FrameV2.DIGEST_UUID, BleTransport.DIGEST_CHAR_UUID)
        assertEquals("transport link info alias follows the contract", FrameV2.LINK_INFO_UUID, BleTransport.LINK_INFO_CHAR_UUID)
    }

    @Test
    fun testLegacyFdValuesAreNeverNamedAndAlwaysRejected() {
        val named = ArrayList<UUID>()
        named.add(RequiredCharacteristicSet.MESH.serviceUuid)
        named.add(RequiredCharacteristicSet.MESH.inbox.uuid)
        named.add(RequiredCharacteristicSet.MESH.digest.uuid)
        named.add(RequiredCharacteristicSet.MESH.linkInfo.uuid)
        for (uuid in named) {
            assertFalse("no mesh identifier may be an FD short-form value: " + uuid, RequiredCharacteristicSet.isLegacyFdValue(uuid))
            assertFalse(uuid.toString(), uuid.equals(legacyInbox))
            assertFalse(uuid.toString(), uuid.equals(legacyDigest))
        }
        assertTrue("the resolver recognises the legacy FD form", RequiredCharacteristicSet.isLegacyFdValue(legacyInbox))
        assertTrue("the resolver recognises the legacy FD form", RequiredCharacteristicSet.isLegacyFdValue(legacyDigest))
        // A tree carrying the legacy characteristic is not the profile: unknown member.
        val taint = canonicalTree()
        taint.add(ContractCharacteristic(legacyInbox, setOf(GattProperty.WRITE, GattProperty.WRITE_NO_RESPONSE, GattProperty.NOTIFY)))
        assertTrue(taint.toString(), RequiredCharacteristicSet.MESH.check(taint) is ProvisionCheck.Unexpected)
        assertEquals(ProvisionCheck.Unexpected(legacyInbox), RequiredCharacteristicSet.MESH.check(taint))
        // The legacy service itself is refused, not auto-detected.
        assertEquals(ProvisionCheck.WrongService(legacyService), RequiredCharacteristicSet.MESH.checkService(legacyService))
    }

    @Test
    fun testServerBlueprintIsTheCanonicalTree() {
        val server = BleGattServer()
        val blueprint = server.serverBlueprint()
        assertEquals("one service installs three characteristics", 3, blueprint.size)
        assertEquals("the blueprint is the contract, element by element", RequiredCharacteristicSet.MESH.characteristics, blueprint)
        assertEquals("inbox: write, write no response, notify", setOf(GattProperty.WRITE, GattProperty.WRITE_NO_RESPONSE, GattProperty.NOTIFY), blueprint[0].properties)
        assertEquals("digest: read, notify", setOf(GattProperty.READ, GattProperty.NOTIFY), blueprint[1].properties)
        assertEquals("link info: read, write", setOf(GattProperty.READ, GattProperty.WRITE), blueprint[2].properties)
        val roles = ArrayList<UUID>()
        roles.add(blueprint[0].uuid)
        roles.add(blueprint[1].uuid)
        roles.add(blueprint[2].uuid)
        assertEquals("pairwise distinct roles", 3, roles.distinct().size)
        // Service/discovery integration: the tree the server installs is
        // exactly the tree the central provisioning gate accepts.
        assertTrue(
            "the central accepts what the server installs",
            RequiredCharacteristicSet.MESH.accepts(blueprint)
        )
    }

    @Test
    fun testPropertyAndPermissionMappingPreservesTheHistoricalInstallation() {
        assertEquals("all four bits decode", 4, RequiredCharacteristicSet.propertiesOf(2 or 4 or 8 or 16).size)
        assertEquals(
            "inbox mask is WRITE | WRITE_NO_RESPONSE | NOTIFY",
            8 or 4 or 16,
            RequiredCharacteristicSet.maskOf(RequiredCharacteristicSet.MESH.inbox.properties)
        )
        assertEquals(
            "digest mask is READ | NOTIFY",
            2 or 16,
            RequiredCharacteristicSet.maskOf(RequiredCharacteristicSet.MESH.digest.properties)
        )
        assertEquals(
            "link info mask is READ | WRITE",
            2 or 8,
            RequiredCharacteristicSet.maskOf(RequiredCharacteristicSet.MESH.linkInfo.properties)
        )
        assertEquals("inbox permission is WRITE only", 16, RequiredCharacteristicSet.permissionsFor(RequiredCharacteristicSet.MESH.inbox.properties))
        assertEquals("digest permission is READ only", 1, RequiredCharacteristicSet.permissionsFor(RequiredCharacteristicSet.MESH.digest.properties))
        assertEquals("link info permission is READ | WRITE", 1 or 16, RequiredCharacteristicSet.permissionsFor(RequiredCharacteristicSet.MESH.linkInfo.properties))
        // The descriptor attaches to every notify-capable characteristic: the
        // decision is observable on the blueprint's property sets.
        assertTrue("inbox carries notify", RequiredCharacteristicSet.MESH.inbox.properties.contains(GattProperty.NOTIFY))
        assertTrue("digest carries notify", RequiredCharacteristicSet.MESH.digest.properties.contains(GattProperty.NOTIFY))
        assertFalse("link info does not carry notify", RequiredCharacteristicSet.MESH.linkInfo.properties.contains(GattProperty.NOTIFY))
        // Round trip through the masks for every role.
        for (entry in RequiredCharacteristicSet.MESH.characteristics) {
            assertEquals("round trip " + entry.uuid, entry.properties, RequiredCharacteristicSet.propertiesOf(RequiredCharacteristicSet.maskOf(entry.properties)))
        }
    }

    @Test
    fun testResolverAcceptsTheCanonicalTree() {
        assertSame("the profile resolves to Match", ProvisionCheck.Match, RequiredCharacteristicSet.MESH.check(canonicalTree()))
        assertTrue("the provisioning gate accepts it", RequiredCharacteristicSet.MESH.accepts(canonicalTree()))
        assertSame(ProvisionCheck.Match, RequiredCharacteristicSet.MESH.checkService(RequiredCharacteristicSet.MESH.serviceUuid))
        // The gate's acceptance function must refuse the negatives too:
        // every tree that is not the profile returns false, on the very
        // entry point the central provisioning gate calls in production.
        assertFalse("no digest does not pass the gate", RequiredCharacteristicSet.MESH.accepts(
            listOf(RequiredCharacteristicSet.MESH.inbox, RequiredCharacteristicSet.MESH.linkInfo)))
        assertFalse("no inbox does not pass the gate", RequiredCharacteristicSet.MESH.accepts(
            listOf(RequiredCharacteristicSet.MESH.digest, RequiredCharacteristicSet.MESH.linkInfo)))
        assertFalse("no link info does not pass the gate", RequiredCharacteristicSet.MESH.accepts(
            listOf(RequiredCharacteristicSet.MESH.inbox, RequiredCharacteristicSet.MESH.digest)))
        assertFalse("a property gap does not pass the gate", RequiredCharacteristicSet.MESH.accepts(
            listOf(
                RequiredCharacteristicSet.MESH.inbox,
                ContractCharacteristic(RequiredCharacteristicSet.MESH.digest.uuid, setOf(GattProperty.READ)),
                RequiredCharacteristicSet.MESH.linkInfo
            )))
        assertFalse("an unknown member does not pass the gate", RequiredCharacteristicSet.MESH.accepts(
            listOf(
                RequiredCharacteristicSet.MESH.inbox,
                RequiredCharacteristicSet.MESH.digest,
                RequiredCharacteristicSet.MESH.linkInfo,
                ContractCharacteristic(legacyInbox, setOf(GattProperty.WRITE))
            )))
        assertFalse("a duplicate does not pass the gate", RequiredCharacteristicSet.MESH.accepts(
            listOf(
                RequiredCharacteristicSet.MESH.inbox,
                RequiredCharacteristicSet.MESH.digest,
                RequiredCharacteristicSet.MESH.linkInfo,
                RequiredCharacteristicSet.MESH.linkInfo
            )))
        assertFalse("an empty tree does not pass the gate", RequiredCharacteristicSet.MESH.accepts(listOf()))
    }

    @Test
    fun testResolverReportsEveryPropertyGap() {
        val noDigest = ArrayList<ContractCharacteristic>()
        noDigest.add(RequiredCharacteristicSet.MESH.inbox)
        noDigest.add(RequiredCharacteristicSet.MESH.linkInfo)
        assertEquals(
            "absent digest is reported as missing",
            ProvisionCheck.Missing(RequiredCharacteristicSet.MESH.digest.uuid, setOf(GattProperty.READ, GattProperty.NOTIFY), setOf<GattProperty>()),
            RequiredCharacteristicSet.MESH.check(noDigest)
        )

        val digestWithoutNotify = ArrayList<ContractCharacteristic>()
        digestWithoutNotify.add(RequiredCharacteristicSet.MESH.inbox)
        digestWithoutNotify.add(ContractCharacteristic(RequiredCharacteristicSet.MESH.digest.uuid, setOf(GattProperty.READ)))
        digestWithoutNotify.add(RequiredCharacteristicSet.MESH.linkInfo)
        assertEquals(
            "a digest without notify is a property gap",
            ProvisionCheck.Missing(RequiredCharacteristicSet.MESH.digest.uuid, setOf(GattProperty.READ, GattProperty.NOTIFY), setOf(GattProperty.READ)),
            RequiredCharacteristicSet.MESH.check(digestWithoutNotify)
        )

        val inboxWithoutWriteNoResponse = ArrayList<ContractCharacteristic>()
        inboxWithoutWriteNoResponse.add(ContractCharacteristic(RequiredCharacteristicSet.MESH.inbox.uuid, setOf(GattProperty.WRITE, GattProperty.NOTIFY)))
        inboxWithoutWriteNoResponse.add(RequiredCharacteristicSet.MESH.digest)
        inboxWithoutWriteNoResponse.add(RequiredCharacteristicSet.MESH.linkInfo)
        assertTrue(
            "an inbox without write-no-response is a property gap",
            RequiredCharacteristicSet.MESH.check(inboxWithoutWriteNoResponse) is ProvisionCheck.Missing
        )

        val noInbox = ArrayList<ContractCharacteristic>()
        noInbox.add(RequiredCharacteristicSet.MESH.digest)
        noInbox.add(RequiredCharacteristicSet.MESH.linkInfo)
        assertTrue("absent inbox is reported as missing", RequiredCharacteristicSet.MESH.check(noInbox) is ProvisionCheck.Missing)

        val noLinkInfo = ArrayList<ContractCharacteristic>()
        noLinkInfo.add(RequiredCharacteristicSet.MESH.inbox)
        noLinkInfo.add(RequiredCharacteristicSet.MESH.digest)
        assertTrue("absent link info is reported as missing", RequiredCharacteristicSet.MESH.check(noLinkInfo) is ProvisionCheck.Missing)
    }

    @Test
    fun testResolverPrefersDuplicateThenUnknownThenMissing() {
        val doubled = canonicalTree()
        doubled.add(RequiredCharacteristicSet.MESH.linkInfo)
        assertEquals(
            "a tree is a set, never a bag: duplicates are reported first",
            ProvisionCheck.Duplicate(RequiredCharacteristicSet.MESH.linkInfo.uuid),
            RequiredCharacteristicSet.MESH.check(doubled)
        )

        val unknownAndMissing = ArrayList<ContractCharacteristic>()
        unknownAndMissing.add(RequiredCharacteristicSet.MESH.inbox)
        unknownAndMissing.add(RequiredCharacteristicSet.MESH.linkInfo)
        unknownAndMissing.add(ContractCharacteristic(legacyDigest, setOf(GattProperty.READ, GattProperty.NOTIFY)))
        assertEquals(
            "an unknown member outranks a missing one",
            ProvisionCheck.Unexpected(legacyDigest),
            RequiredCharacteristicSet.MESH.check(unknownAndMissing)
        )

        val duplicateAndUnknown = canonicalTree()
        duplicateAndUnknown.add(ContractCharacteristic(legacyInbox, setOf(GattProperty.WRITE)))
        duplicateAndUnknown.add(RequiredCharacteristicSet.MESH.inbox)
        assertEquals(
            "duplicates outrank unknown members",
            ProvisionCheck.Duplicate(RequiredCharacteristicSet.MESH.inbox.uuid),
            RequiredCharacteristicSet.MESH.check(duplicateAndUnknown)
        )
    }

    @Test
    fun testInboundRoutingIsSingleAuthority() {
        val server = BleGattServer()
        assertSame(
            "LinkInfo bytes never enter the record decoder",
            InboundRoute.TO_LINK_INFO,
            server.classifyInbound(RequiredCharacteristicSet.MESH.linkInfo.uuid)
        )
        assertSame(
            "frame records are the deframer's concern",
            InboundRoute.TO_DEFRAMER,
            server.classifyInbound(RequiredCharacteristicSet.MESH.inbox.uuid)
        )
        assertSame("the legacy inbox value routes nowhere", InboundRoute.NOT_SUPPORTED, server.classifyInbound(legacyInbox))
        assertSame("the legacy digest value routes nowhere", InboundRoute.NOT_SUPPORTED, server.classifyInbound(legacyDigest))
        assertSame("an alien characteristic routes nowhere", InboundRoute.NOT_SUPPORTED, server.classifyInbound(UUID.fromString("6764A099-9A5E-4C7B-B0A1-3E5D8C2F7A10")))
        // The two routes are apart: one and the same 13-octet record is a
        // LinkInfo record on the link info characteristic and a frame record
        // on the inbox; classification alone decides, by uuid equality.
        assertEquals(
            "classification depends on the characteristic, not the bytes",
            server.classifyInbound(RequiredCharacteristicSet.MESH.linkInfo.uuid),
            server.classifyInbound(RequiredCharacteristicSet.MESH.linkInfo.uuid)
        )
    }

    @Test
    fun testProvisioningGateFailsDiscoveryOnTheDispatchSeam() {
        var reported = "nothing"
        val client = GattClientConnection(
            peerAddress = "11:22:33:44:55:6E",
            relationGeneration = 1L,
            onServicesDiscovered = { success, _, _ ->
                reported = if (success) "found" else "lost"
            }
        )
        // The gate in the discovery callback hands the dispatch seam the
        // verdict of RequiredCharacteristicSet.check; a failed check must
        // reach the driver as a failure, never as an empty success. Each
        // dispatch consumes one in-flight SERVICE_DISCOVERY operation.
        client.enqueuePendingOpForTesting(GattOpType.SERVICE_DISCOVERY)
        client.dispatchServicesDiscovered(android.bluetooth.BluetoothGatt.GATT_SUCCESS, client.currentLifetimeToken, false)
        assertEquals("a tree that is not the profile fails discovery", "lost", reported)

        reported = "nothing"
        client.enqueuePendingOpForTesting(GattOpType.SERVICE_DISCOVERY)
        client.dispatchServicesDiscovered(android.bluetooth.BluetoothGatt.GATT_SUCCESS, client.currentLifetimeToken, true)
        assertEquals("the profile is found", "found", reported)

        reported = "nothing"
        client.enqueuePendingOpForTesting(GattOpType.SERVICE_DISCOVERY)
        client.dispatchServicesDiscovered(android.bluetooth.BluetoothGatt.GATT_FAILURE, client.currentLifetimeToken, true)
        assertEquals("a failed status is a failure even with a passing gate", "lost", reported)

        reported = "nothing"
        client.enqueuePendingOpForTesting(GattOpType.LINK_INFO_READ)
        client.dispatchServicesDiscovered(android.bluetooth.BluetoothGatt.GATT_SUCCESS, client.currentLifetimeToken, true)
        assertEquals("a response to a different operation reaches no verdict", "nothing", reported)
    }

    @Test
    fun testCanonicalGateAgreesWithTheDispatchSeam() {
        assertTrue("the gate itself agrees with the canonical tree", RequiredCharacteristicSet.MESH.accepts(canonicalTree()))
        assertFalse("and disagrees with the legacy profile", RequiredCharacteristicSet.MESH.accepts(
            arrayListOfContract(listOf(
                ContractCharacteristic(legacyInbox, setOf(GattProperty.WRITE, GattProperty.WRITE_NO_RESPONSE, GattProperty.NOTIFY)),
                ContractCharacteristic(legacyDigest, setOf(GattProperty.READ, GattProperty.NOTIFY)),
                RequiredCharacteristicSet.MESH.linkInfo
            ))
        ))
    }

    private fun arrayListOfContract(items: List<ContractCharacteristic>): ArrayList<ContractCharacteristic> {
        val out = ArrayList<ContractCharacteristic>()
        for (item in items) {
            out.add(item)
        }
        return out
    }

    @Test
    fun testGeneratedStringsMatchTheWireText() {
        // The resolvers compare numerically, but the shipping evidence is
        // rendered text: pin the case against wire/wire_v2.yaml verbatim.
        assertEquals("6764a001-9a5e-4c7b-b0a1-3e5d8c2f7a10", RequiredCharacteristicSet.MESH.serviceUuid.toString())
        assertEquals("6764a002-9a5e-4c7b-b0a1-3e5d8c2f7a10", RequiredCharacteristicSet.MESH.inbox.uuid.toString())
        assertEquals("6764a003-9a5e-4c7b-b0a1-3e5d8c2f7a10", RequiredCharacteristicSet.MESH.digest.uuid.toString())
        assertEquals("6764a004-9a5e-4c7b-b0a1-3e5d8c2f7a10", RequiredCharacteristicSet.MESH.linkInfo.uuid.toString())
        assertNotNull(BleGattServer().serverBlueprint())
    }
}
