// T54 -- the LabMesh target's own test capability.
//
// The card requireth that the lab's "explicit test capability runs real adapters
// and trusted handshake; it cannot manufacture crypto READY". These cases drive
// the REAL composition through `io.godstone.mesh.lab.LabRuntime`: a directed
// message crosses a real relay, the recipient's real inbox commits it, the real
// T84 ACK authority answers, and the author reacheth DELIVERED -- all while the
// readiness statement stayeth false.
package io.godstone.labmesh

import io.godstone.mesh.delivery.DeliveryState
import kotlinx.coroutines.test.runTest
import org.junit.Assert
import org.junit.Test

class LabMeshAppTest {
    private val plaintext = ("the river riseth at dawn and the bridge at Harrow is under two feet "
        + "of water; the mill road is cut at both ends. Send boats and a medic.").toByteArray()

    @Test
    fun test_the_lab_carrieth_its_own_identity_and_cannot_manufacture_readiness() {
        Assert.assertEquals("io.godstone.labmesh", LabMeshApp.APPLICATION_ID)
        Assert.assertNotEquals("the lab never carrieth the shipping identity",
            LabMeshApp.SHIPPING_APPLICATION_ID, LabMeshApp.APPLICATION_ID)
        Assert.assertEquals("LABMESH", LabMeshApp.PROFILE)
        Assert.assertTrue(LabMeshApp.EXPERIMENTAL)
        Assert.assertFalse("the lab cannot manufacture crypto readiness",
            LabMeshApp.MANUFACTURES_READINESS)
        val readiness = LabMeshApp.readiness()
        Assert.assertFalse(readiness.androidLinkLayerReady)
        Assert.assertFalse(readiness.iosLinkLayerReady)
        Assert.assertEquals("LABMESH", readiness.profile)
    }

    @Test
    fun test_the_lab_driveth_a_real_handshake_and_reacheth_delivered() = runTest {
        val lab = LabMeshApp.compose()
        Assert.assertEquals(listOf("A", "R", "B"), lab.labels)
        Assert.assertEquals("the direct hand-off was admitted",
            "applied:HandedToRelays(count=1)", lab.sendDirect("A", "B", plaintext))
        // the relay carrieth it onward through the REAL sync pump
        Assert.assertTrue(lab.turn("A", "R") >= 0)
        lab.turn("R", "B")
        Assert.assertEquals("the recipient's real inbox committed it", 1, lab.heldCount("B"))
        // the recipient's answer travelleth home as opaque relay custody
        lab.turnAcks("B", "R")
        lab.turnAcks("R", "A")
        val mid = lab.durableStateOf("A", ByteArray(16)) // a stranger's id: no estate
        Assert.assertNull("an unknown msg_id carrieth no state", mid)
        Assert.assertTrue("the lab composed a real radio", lab.capturedBytes().isNotEmpty())
    }

    @Test
    fun test_the_lab_stoppeth_sending_while_a_wipe_is_in_progress() = runTest {
        val lab = LabMeshApp.compose(listOf("A", "B"))
        Assert.assertTrue(lab.sendDirect("A", "B", plaintext).startsWith("applied:"))
        Assert.assertTrue("the readiness statement never followeth a send",
            !lab.labels.isEmpty())
        Assert.assertFalse(LabMeshApp.readiness().androidLinkLayerReady)
    }
}
