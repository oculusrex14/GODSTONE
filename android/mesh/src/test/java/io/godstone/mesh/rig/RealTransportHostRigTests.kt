package io.godstone.mesh.rig

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import io.godstone.mesh.DirectDispatchResult
import io.godstone.mesh.delivery.DeliveryState
import java.io.File
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * *** GS-INTEGRATION-001 `real-adapters`: THE ANDROID REAL-TRANSPORT HOST RIG'S OWN COURT. ***
 *
 * Every arm below driveth the PRODUCTION composition (`MeshModule.provideMeshNode`) over ON-DISK stores, with ONLY
 * the OS facade substituted, and observeth an OWNER (the durable store, the transport's own roster, the delivery
 * journal) rather than a court counter.
 *
 * THE REQUIRED ARMS, AND WHY EACH DEFENDETH SOMETHING A PLAUSIBLE BUG WOULD BREAK:
 *   * [testTwoNodesEstablishAndTheDirectFrameReachesTheRecipientsDurableRow] -- the exact `msgId` the author sealed
 *     is found in the RECIPIENT's own on-disk store, through the real ingress doors, AND the recipient's inbox
 *     really issued its canonical ACK. A framing/ingress regression (or a silent no-op send) maketh this fail;
 *   * [testTearDownReleasesEveryOwner] -- after `tearDown` the closed store REFUSETH a read, catching an
 *     unlinked-but-open handle (the SQLite diagnostic the full lane must not carry);
 *   * [testIsLinkReadyIsFalseForANotReadyLink] -- a link whose handshake never ran is NOT reported ready;
 *   * [testPreAuthFragmentsAreRefusedAndCommitNothing] -- a pre-auth fragment committeth nothing and is a bounded
 *     event in the transport's own ring.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33])
internal class RealTransportHostRigTests {

    private lateinit var root: File
    private var rig: RealTransportHostRig? = null

    @Before
    fun mintEstate() {
        root = File.createTempFile("gs_rig_court_", "").let { it.delete(); it.mkdirs(); it.deleteOnExit(); it }
    }

    @After
    fun razeEstate() {
        runCatching { rig?.tearDown() }
        root.deleteRecursively()
    }

    private fun ctx(): Context = ApplicationProvider.getApplicationContext()

    /** A rig over its OWN anonymous estate (deleted at `tearDown`). */
    private fun newRig(): RealTransportHostRig = RealTransportHostRig(ctx()).also { rig = it }

    /** *** A RIG OVER A CALLER-OWNED ROOT, SO [RealTransportHostRig.tearDown] LEAVETH THE ESTATE IN PLACE. *** */
    private fun ownedRig(): RealTransportHostRig = RealTransportHostRig(ctx(), root).also { rig = it }

    /**
     * *** REQUIRED ARM: TWO NODES ESTABLISH OVER THE OS FACADES ONLY, AND A DIRECT FRAME REACHETH THE RECIPIENT'S
     * DURABLE ROW -- THE EXACT `msgId` -- AND THE RECIPIENT'S OWN INBOX ISSUES ITS CANONICAL ACK. ***
     *
     * *THE `msgId` IS THE DISCRIMINATOR: it is derived from the sealed container, so finding THE AUTHOR'S OWN
     * sixteen octets in the recipient's store proveth (a) the frame was really sealed and framed by the production
     * transport, (b) the bytes really crossed and re-entered the receiving side's REAL ingress door, and (c) the
     * recipient's durable store really committed them.* **AND `acksIssued`/the node's own ACK outbox distinguish the
     * RECIPIENT'S INBOX from a mere relay hold that `router.onFrameReceived` would also record.**
     */
    @Test
    fun testTwoNodesEstablishAndTheDirectFrameReachesTheRecipientsDurableRow() {
        val r = newRig()
        r.makeNode("A")
        r.makeNode("B")
        val link = r.link("A", "B")

        // *** THE LINK IS READY BY THE EXACT-HANDLE CONTRACT, or the send below would offer to nobody. ***
        assertTrue(
            "*** the established link must be READY on its opener's own two views: ${r.linkReadinessDetail(link)} ***",
            r.waitUntil { r.isLinkReady(link) },
        )

        val plaintext = "the river riseth at dawn and the bridge at Harrow is under two feet of water; send boats"
            .toByteArray(Charsets.US_ASCII)
        val (frame, result) = r.sendDirect("A", "B", plaintext)

        assertTrue(
            "*** the dispatch must hand the sealed frame to exactly one relay, observed $result; ring: ${r.ring("A")} ***",
            result is DirectDispatchResult.HandedToRelays && result.count == 1,
        )
        assertTrue(
            "*** AND THE REAL TRANSPORT MUST HAVE PRODUCED ATTRIBUTED EGRESS for this frame: " +
                "${r.recordedEgressBytes("A", frame.msgId)} octets ***",
            r.recordedEgressBytes("A", frame.msgId) > 0,
        )

        // *** THE AUTHOR'S DURABLE INTENT, IN ONE TRANSACTION, BEFORE THE OFFER. ***
        assertTrue(
            "*** the author must durably hold its own frame: ${r.heldMsgIds("A").size} held ***",
            r.holdsMsg("A", frame.msgId),
        )
        assertTrue(
            "*** and the author's delivery row must stand QUEUED_DURABLY (never DELIVERED on host evidence alone), " +
                "observed ${r.deliveryState("A", frame.msgId)} ***",
            r.deliveryState("A", frame.msgId) == DeliveryState.QUEUED_DURABLY,
        )

        // *** THE RECIPIENT'S DURABLE ROW, THROUGH THE REAL INGRESS DOORS. ***
        assertTrue(
            "*** THE RECIPIENT MUST REALLY HOLD THE EXACT msgId IN ITS OWN ON-DISK STORE. " +
                "Observed held=${r.heldMsgIds("B").size}, ring: ${r.ring("B")} ***",
            r.waitUntil { r.holdsMsg("B", frame.msgId) },
        )
        assertNull(
            "the recipient is not the author: no delivery row of its own",
            r.deliveryRow("B", frame.msgId),
        )

        // *** AND THE INBOX ROAD REALLY RAN -- WHICH A RELAY HOLD ALONE WOULD NOT PROVE. ***
        val census = r.inboxCensus("B")
        assertNotNull("*** the recipient's inbox owner must exist on the production composition ***", census)
        assertTrue(
            "*** THE RECIPIENT'S INBOX MUST HAVE ISSUED ITS CANONICAL ACK -- census=$census, " +
                "outboxDepth=${r.ackOutboxDepth("B")} ***",
            r.waitUntil { (r.inboxCensus("B")?.acksIssued ?: 0) >= 1 && r.ackOutboxDepth("B") >= 1 },
        )
        // *AND THE ACK PRODUCTION ISSUED IS RETRIEVABLE, NEVER MINTED BY THE RIG.*
        val ack = r.drainOneAck("B")
        assertNotNull("*** the canonical ACK must stand in the node's own outbox ***", ack)
        assertTrue(
            "*** and it must name the very message the author sealed ***",
            ack!!.msgId.contentEquals(frame.msgId),
        )
    }

    /**
     * *** REQUIRED ARM: `tearDown` RELEASETH EVERY OWNER, AND A CLOSED STORE REFUSETH A READ. ***
     *
     * *A store whose FILE was deleted while its handle stood open is the `database is unlinked while open`
     * diagnostic the full simulator lane must not carry. Closing explicitly while the owner standeth is the iOS
     * order; this arm proveth the close really happened by READING through the closed engine -- an
     * unlinked-but-open handle would silently answer.*
     */
    @Test
    fun testTearDownReleasesEveryOwner() {
        val r = ownedRig()
        r.makeNode("A")
        r.makeNode("B")
        r.link("A", "B")
        val nodeA = r.nodeOf("A")

        // The owner is alive and readable BEFORE the release boundary.
        val probe = ByteArray(16) { (it + 1).toByte() }
        assertNull("the control: no row stands for the probe", nodeA.engine.readDelivery(probe))
        assertTrue("the control: the store is open and its held set is answerable", r.heldMsgIds("A").isEmpty())
        // *Drain any production-issued ACK first, so nothing the node authored confuses the post-close read.*
        r.drainOneAck("A")

        r.tearDown()
        rig = null

        val afterClose = runCatching { nodeA.engine.readDelivery(probe) }
        assertTrue(
            "*** AFTER `tearDown` THE STORE'S OWN ENGINE MUST REFUSE A READ -- observed $afterClose. " +
                "A silent answer would mean the handle was left open (or unlinked) rather than closed. ***",
            afterClose.isFailure,
        )
        // *`allHeldMsgIds` is SUSPEND, so the read is wrapped in `runBlocking` (which maketh the lambda suspend)
        // and `runCatching` still captureth the throw the closed store must raise.*
        val heldAfterClose = runBlocking { runCatching { nodeA.messageStore.allHeldMsgIds() } }
        assertTrue(
            "*** and the store's own read road must refuse too: $heldAfterClose ***",
            heldAfterClose.isFailure,
        )
    }

    /**
     * *** REQUIRED ARM: A LINK WHOSE HANDSHAKE NEVER RAN IS **NOT** REPORTED READY. ***
     *
     * *The readiness contract is EXACT-HANDLE membership in the opener's own two views, so a predicate that
     * answered "any ready handle" (the hosted defect's shape) would pass an unestablished relation. This arm buildeth
     * the pure link description -- both handles, and the PRODUCTION election's opener -- WITHOUT driving either
     * ladder, and requireth `false`.*
     */
    @Test
    fun testIsLinkReadyIsFalseForANotReadyLink() {
        val r = newRig()
        r.makeNode("A")
        r.makeNode("B")
        val link = r.electLink("A", "B")

        r.open("A")
        r.open("B")
        assertFalse(
            "*** A LINK THAT WAS NEVER DRIVEN MUST NOT BE READY: ${r.linkReadinessDetail(link)} ***",
            r.isLinkReady(link),
        )
        assertTrue(
            "*** and the opener's own APPLICATION roster must be empty -- publication happeth only upon the sealed " +
                "key-confirmation round ***",
            r.nodeOf(if (link.aOpened) "A" else "B").transport.linkReadyPeersForTest().isEmpty(),
        )
    }

    /**
     * *** COMPANION ARM: PRE-AUTH FRAGMENTS STAY REFUSED, AND A REFUSED RECORD LEAVETH THE ESTATE ALONE. ***
     *
     * *The card's clause: "pre-auth fragments must remain refused."* **A fragment fed to an address with NO
     * connection reacheth the pre-auth budget and the door's own guard, and NOTHING is committed and NOTHING is
     * emitted: the durable store stayeth empty and the fabric recordeth no egress.**
     */
    @Test
    fun testPreAuthFragmentsAreRefusedAndCommitNothing() {
        val r = newRig()
        r.makeNode("A")
        val a = r.nodeOf("A")
        r.open("A")

        val junk = ByteArray(24) { (it * 7 + 1).toByte() }
        runBlocking { a.transport.handleServerInboundWrite("11:22:33:44:55:66", junk) }
        runBlocking { a.transport.handleCentralInboundNotification("11:22:33:44:55:66", junk) }

        assertTrue("*** NOTHING may be committed from a pre-auth fragment ***", r.heldMsgIds("A").isEmpty())
        assertTrue("*** and nothing may ride the air ***", a.outlet.airIsEmpty())
        assertTrue(
            "*** and the refusal must be a BOUNDED EVENT in the transport's own ring, observed: ${r.ring("A")} ***",
            a.transport.rejectionRecordsForTest().isNotEmpty(),
        )
    }
}
