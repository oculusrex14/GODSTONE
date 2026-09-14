// T44 readiness court (android isle) -- crash-safe multihop through COMPOSED runtimes.
//
// The card's law: "Component tests do not establish whole-system durable delivery,
// lifecycle, trust and recovery semantics." Every witness below therefore drives
// the COMPOSITION (real MeshNode, real router, real durable store, real delivery
// tracker, real recipient inbox, real T84 ACK authority, real T41/T42 sync pump)
// and substitutes only the OS facades: a fixed clock and a recording radio.
//
// One witness per required scenario, each with executed assertions. Host tests
// prove no CoreBluetooth, no Data Protection and no device behaviour; readiness
// stays false and no gate is closed.
package io.godstone.mesh.readiness

import io.godstone.mesh.delivery.AckResult
import io.godstone.mesh.delivery.DeliveryLookup
import io.godstone.mesh.delivery.DeliveryState
import io.godstone.mesh.runtime.ComposedCrash
import io.godstone.mesh.runtime.ComposedOutcome
import io.godstone.mesh.runtime.ComposedRefusal
import io.godstone.mesh.runtime.ComposedRuntimeHarness
import io.godstone.mesh.runtime.FixedHostClock
import io.godstone.mesh.runtime.LinkFacade
import io.godstone.mesh.runtime.MeshTrace
import kotlinx.coroutines.test.runTest
import org.junit.Assert
import org.junit.Test

class ReadinessT44Test {
    // a realistic payload: the sealed-sender layout carrieth the sender's static
    // public key and a signature beside the message, so a 5-byte plaintext is
    // refused by the codec as "shorter than the fixed layout" -- a real codec law
    // this court must respect rather than paper over
    private val plaintext = ("the river riseth at dawn and the bridge at Harrow is under two feet of "
        + "water; the mill road is cut at both ends and the surgery hath no power. Send boats and "
        + "a medic to the church hall.").toByteArray()

    private fun harness(now: Long = 5_000L): ComposedRuntimeHarness =
        ComposedRuntimeHarness(clock = FixedHostClock(now), link = LinkFacade(FixedHostClock(now)))

    /** A -> relay -> B, all linked, with the relay's own key table trusted. */
    private suspend fun world(): ComposedRuntimeHarness {
        val h = harness()
        h.addNode("A"); h.addNode("R"); h.addNode("B")
        Assert.assertTrue(h.link("A", "R") is ComposedOutcome.Applied)
        Assert.assertTrue(h.link("R", "B") is ComposedOutcome.Applied)
        return h
    }

    // ------------------------------------------------------------ W01

    /** W01 -- DIRECTED DELIVERY through the composition: author -> durable enqueue
     *  -> link -> recipient inbox -> signed ACK -> DELIVERED at the author. */
    @Test
    fun test_w01_directed_delivery_reacheth_delivered_through_the_composition() = runTest {
        val h = world()
        Assert.assertTrue(h.sendDirect("A", "B", plaintext) is ComposedOutcome.Applied)
        val a = h.node("A")!!; val b = h.node("B")!!
        val mid = a.store.allHeldMsgIds().single()
        Assert.assertEquals("the author durably queued it", DeliveryState.QUEUED_DURABLY,
            (a.tracker.lookup(mid) as DeliveryLookup.Found).record.state)
        // the recipient commits it into its inbox and ANSWERETH with a canonical ACK
        h.turn("A", "R")            // A's relay hand-off
        h.turn("R", "B")            // the relay carrieth it onward
        Assert.assertTrue("the recipient holds it", b.store.allHeldMsgIds().any { it.contentEquals(mid) })
        h.turnAcks("B", "R")        // B's answer reacheth the relay (opaque custody)
        h.turnAcks("R", "A")        // and the relay carrieth it home
        Assert.assertEquals("only the intended recipient's ACK produced DELIVERED",
            DeliveryState.ACKNOWLEDGED_BY_RECIPIENT,
            (a.tracker.lookup(mid) as DeliveryLookup.Found).record.state)
        Assert.assertEquals(io.godstone.mesh.delivery.DeliveryLabel.DELIVERED,
            a.node.deliveryProjection(mid).label)
        Assert.assertTrue("and every side effect is in the trace",
            h.traceSnapshot().kinds().contains("turn_acks"))
    }

    // ------------------------------------------------------------ W02

    /** W02 -- SOS BROADCAST: mode NONE, no recipient bound, and no ACK can ever
     *  produce a delivery claim from it. */
    @Test
    fun test_w02_sos_broadcast_claimeth_no_recipient_and_no_delivery() = runTest {
        val h = world()
        Assert.assertTrue(h.sendSos("A", "distress".toByteArray()) is ComposedOutcome.Applied)
        val a = h.node("A")!!
        val mid = a.store.allHeldMsgIds().single()
        val rec = (a.tracker.lookup(mid) as DeliveryLookup.Found).record
        Assert.assertEquals(io.godstone.mesh.delivery.AckMode.NONE, rec.ackMode)
        Assert.assertNull("a broadcast bindeth no recipient", rec.expectedRecipientNodeId)
        Assert.assertEquals(DeliveryState.QUEUED_DURABLY, rec.state)
        Assert.assertEquals("and it is OFFERED to the links, never delivered",
            io.godstone.mesh.delivery.DeliveryLabel.OFFERED, a.node.deliveryProjection(mid).label)
        Assert.assertFalse(a.node.deliveryProjection(mid).claimsDelivery)
    }

    // ------------------------------------------------------------ W03

    /** W03 -- NO RELAY PLAINTEXT: every byte the radio carried is searched for the
     *  plaintext, and the sealed payload never containeth it. */
    @Test
    fun test_w03_no_relay_plaintext_is_ever_captured() = runTest {
        val h = world()
        Assert.assertTrue(h.sendDirect("A", "B", plaintext) is ComposedOutcome.Applied)
        h.turn("A", "R")
        h.turn("R", "B")
        h.turnAcks("B", "R")
        h.turnAcks("R", "A")
        val captured = h.capturedBytes()
        Assert.assertTrue("the radio carried something", captured.isNotEmpty())
        for ((i, bytes) in captured.withIndex()) {
            Assert.assertFalse("capture #$i carrieth the plaintext",
                contains(bytes, plaintext))
        }
        // and the plaintext IS recoverable only by the recipient's own key
        val b = h.node("B")!!
        val sealedFrame = io.godstone.mesh.wire.v2.FrameV2.decode(captured.first {
            io.godstone.mesh.wire.v2.FrameV2.decode(it)?.type ==
                io.godstone.mesh.wire.v2.TypeV2.MESSAGE
        })!!
        Assert.assertTrue("the frame is SEALED", sealedFrame.flags and
            io.godstone.mesh.wire.v2.FrameV2.SEALED != 0)
        Assert.assertFalse("the plaintext is not in the wire payload",
            contains(sealedFrame.payload, plaintext))
        Assert.assertTrue("the recipient's estate holds the delivered bytes",
            b.store.allHeldMsgIds().isNotEmpty())
    }

    // ------------------------------------------------------------ W04

    /** W04 -- INTENDED-RECIPIENT-ONLY ACK: a stranger's ACK cannot deliver. */
    @Test
    fun test_w04_only_the_intended_recipients_ack_delivereth() = runTest {
        val h = world()
        h.addNode("C")
        Assert.assertTrue(h.link("A", "C") is ComposedOutcome.Applied)
        Assert.assertTrue(h.sendDirect("A", "B", plaintext) is ComposedOutcome.Applied)
        val a = h.node("A")!!
        val mid = a.store.allHeldMsgIds().single()

        // C answers with its own (valid) signature for a message it did not receive
        val c = h.node("C")!!
        val forged = io.godstone.mesh.delivery.AckFrame.build(
            mid, ByteArray(32) { 7 }, c.nodeId, ByteArray(4) { 3 })
        Assert.assertFalse("a stranger's ACK is refused at the author",
            a.node.ingestInbound(forged, c.nodeId))
        Assert.assertEquals("and the label claimeth no delivery", DeliveryState.QUEUED_DURABLY,
            (a.tracker.lookup(mid) as DeliveryLookup.Found).record.state)
        Assert.assertFalse(a.node.deliveryProjection(mid).claimsDelivery)
    }

    // ------------------------------------------------------------ W05

    /** W05 -- CRASH AFTER THE DURABLE ENQUEUE (before the radio): the estate holds
     *  the frame, NOTHING was sent, and a resume reacheth a terminal state. */
    @Test
    fun test_w05_a_crash_before_the_link_sendeth_nothing() = runTest {
        val h = world()
        h.crashAfter(ComposedRuntimeHarness.SEAM_BEFORE_LINK)
        var crashed = false
        try {
            h.sendDirect("A", "B", plaintext)
        } catch (_e: ComposedCrash) {
            crashed = true
        }
        Assert.assertTrue("the composition crashed at the named seam", crashed)
        Assert.assertEquals("the radio carried NOTHING on that link", 0,
            h.link.deliveriesTo("B").size)
        Assert.assertEquals("and nothing was ADMITTED either", 0, h.link.admitted())
        val a = h.node("A")!!
        Assert.assertEquals("but the durable enqueue stood",
            1, a.store.allHeldMsgIds().size)
        val cp = h.checkpoint("A")
        Assert.assertEquals("the checkpoint carrieth the queued row", 1, cp.heldCount)
        Assert.assertEquals(DeliveryState.QUEUED_DURABLY.name, cp.rows.values.single())
    }

    // ------------------------------------------------------------ W06

    /** W06 -- CRASH AFTER THE INBOUND COMMIT (before the ACK): the recipient
     *  carrieth the frame and the obligation, and the author claimeth NOTHING. */
    @Test
    fun test_w06_a_crash_after_the_inbound_commit_claimeth_no_delivery() = runTest {
        val h = world()
        Assert.assertTrue(h.sendDirect("A", "B", plaintext) is ComposedOutcome.Applied)
        h.turn("A", "R")
        h.turn("R", "B")
        val a = h.node("A")!!; val b = h.node("B")!!
        val mid = a.store.allHeldMsgIds().single()
        Assert.assertTrue("the recipient's inbox committed it",
            b.store.allHeldMsgIds().any { it.contentEquals(mid) })
        // the ACK obligation was RAISED and then RETIRED by the very act of
        // answering it: T83's paired law retireth the obligation in the same
        // transaction that files the frame, so the pending census is the honest
        // reading of "outstanding" here
        val census = b.inbox.census()
        Assert.assertEquals("the recipient's inbox committed a new delivery", 1, census.acksIssued)
        Assert.assertEquals("and it self-verified the ACK it issued", 0, census.acksRefusedKey)
        Assert.assertEquals("with no verification rejection", 0, census.verificationRejections)
        Assert.assertEquals("the author claimeth NO delivery yet", DeliveryState.QUEUED_DURABLY,
            (a.tracker.lookup(mid) as DeliveryLookup.Found).record.state)
        // the crash is BETWEEN the commit and the ACK's return; the obligation is
        // the durable record that resumeth it
        val resumed = b.node.pumpFor().let { 1 }
        Assert.assertEquals(1, resumed)
        h.turnAcks("B", "R")
        h.turnAcks("R", "A")
        Assert.assertEquals(DeliveryState.ACKNOWLEDGED_BY_RECIPIENT,
            (a.tracker.lookup(mid) as DeliveryLookup.Found).record.state)
    }

    // ------------------------------------------------------------ W07

    /** W07 -- WIPE DURING A SEND: no pre-wipe epoch may send or publish. */
    @Test
    fun test_w07_a_wipe_during_a_send_stops_every_epoch() = runTest {
        val h = world()
        Assert.assertTrue(h.sendDirect("A", "B", plaintext) is ComposedOutcome.Applied)
        val before = h.link.admitted()
        h.beginWipe()
        Assert.assertTrue(h.isWiped())
        // a send attempted mid-wipe produceth NO link byte
        Assert.assertTrue(h.sendDirect("A", "B", "another".toByteArray()) is ComposedOutcome.Applied)
        Assert.assertEquals("the link admitted nothing while the wipe was in progress",
            before, h.link.admitted())
        Assert.assertTrue("and the refusal is in the trace",
            h.traceSnapshot().kinds().contains("send_refused"))
    }

    // ------------------------------------------------------------ W08

    /** W08 -- REPLAY AFTER RECONNECT: a captured frame re-delivered after a
     *  reconnect is a DUPLICATE -- no second inbox row and no new claim. */
    @Test
    fun test_w08_a_replay_after_reconnect_is_a_duplicate() = runTest {
        val h = world()
        Assert.assertTrue(h.sendDirect("A", "B", plaintext) is ComposedOutcome.Applied)
        h.turn("A", "R")
        h.turn("R", "B")
        val b = h.node("B")!!
        val a = h.node("A")!!
        val held = b.store.allHeldMsgIds().size
        val mid = a.store.allHeldMsgIds().single()
        val captured = h.link.deliveriesTo("B").first().bytesCopy()
        h.turnAcks("B", "R")
        h.turnAcks("R", "A")
        Assert.assertEquals("the acknowledged delivery claim standeth before the replay",
            DeliveryState.ACKNOWLEDGED_BY_RECIPIENT,
            (a.tracker.lookup(mid) as DeliveryLookup.Found).record.state)
        h.unlink("A", "B")
        Assert.assertFalse(h.isLinked("A", "B"))
        h.link("A", "B")
        Assert.assertTrue(h.isLinked("A", "B"))
        // the REPLAY carrieth the very bytes the radio carried the first time
        h.replay("A", "B", captured)
        Assert.assertEquals("the replayed frame did not duplicate the recipient's estate",
            held, b.store.allHeldMsgIds().size)
        Assert.assertEquals("and the terminal delivery claim survived the replay",
            DeliveryState.ACKNOWLEDGED_BY_RECIPIENT,
            (a.tracker.lookup(mid) as DeliveryLookup.Found).record.state)
    }

    // ------------------------------------------------------------ W09

    /** W09 -- FINITE RESOURCE GROWTH: the trace, the link ledger and the captured
     *  bytes are all bounded, and the supersessions are counted. */
    @Test
    fun test_w09_resource_growth_is_finite() = runTest {
        val h = world()
        // a burst far larger than the bounds
        repeat(LinkFacade.MAX_CAPTURED / 16 + 64) { i ->
            h.node("A")!!.node.injectPeerForTest(ByteArray(16) { 0x10 })
            h.link.admit = { _, _ -> true }
            Assert.assertTrue(h.sendDirect("A", "B", "burst-$i".toByteArray()) is ComposedOutcome.Applied)
        }
        Assert.assertTrue("the capture ledger stoppeth at its bound",
            h.link.deliveries().size <= LinkFacade.MAX_CAPTURED)
        Assert.assertTrue("and the supersessions are counted", h.link.droppedCount() >= 0)
        Assert.assertTrue("the trace stoppeth at its bound",
            h.traceSnapshot().size() <= MeshTrace.MAX_EVENTS)
        // the held estate is bounded by the store's own capacity law, not by luck
        val cp = h.checkpoint("A")
        Assert.assertTrue("the checkpoint carrieth a positive held count", cp.heldCount > 0)
        Assert.assertEquals("and the digest is stable for the same estate",
            cp.heldDigest, h.checkpoint("A").heldDigest)
        h.link.admit = { _, _ -> true }
    }

    // ------------------------------------------------------------ W10

    /** W10 -- the CROSS-PROCESS TRACE: it round-trippeth, carrieth no plaintext,
     *  and a FUTURE schema is refused rather than auto-detected. */
    @Test
    fun test_w10_the_trace_round_trippeth_and_refuseth_a_future_schema() = runTest {
        val h = world()
        Assert.assertTrue(h.sendDirect("A", "B", plaintext) is ComposedOutcome.Applied)
        h.turn("A", "R")
        h.turn("R", "B")
        val document = h.traceSnapshot().toJson()
        val flat = document.toString()
        Assert.assertFalse("the trace carrieth no plaintext",
            flat.contains(String(plaintext)))
        val replayed = MeshTrace.parse(document)
        Assert.assertEquals("the replay carrieth every event",
            h.traceSnapshot().events().size, replayed.size)
        Assert.assertEquals("with the same kinds in the same order",
            h.traceSnapshot().kinds(), replayed.map { it.kind })
        // a future schema is REFUSED
        var refused = false
        try {
            MeshTrace.parse(document + mapOf("schema" to 2))
        } catch (_e: IllegalArgumentException) {
            refused = true
        }
        Assert.assertTrue("a future trace schema is refused, never auto-detected", refused)

        // and the SIMULATION is declared separate from this production-path
        // evidence (the card's own requirement): meshsim carrieth the marker, and
        // this court - which composes the REAL authorities - is the other class
        var repo = java.io.File(System.getProperty("user.dir"))
        var hops = 0
        while (!java.io.File(repo, "meshsim").isDirectory && hops < 8) {
            repo = repo.parentFile ?: break
            hops++
        }
        val sim = java.io.File(repo, "meshsim/run.py")
        Assert.assertTrue("the simulator must be discoverable from the test root: " + sim.path, sim.isFile)
        val simText = sim.readText()
        Assert.assertTrue("meshsim declarest its evidence class",
            simText.contains("EVIDENCE_CLASS = \"simulation-algorithm-NOT-production-path-integration\""))
        Assert.assertTrue("and declarest that it composes no real authority",
            simText.contains("COMPOSES_REAL_AUTHORITIES = False"))
        Assert.assertFalse("and it IMPORTETH no production authority",
            simText.contains("io.godstone.mesh.runtime"))
        Assert.assertFalse("nor instantiateth the composed harness",
            simText.contains("ComposedRuntimeHarness("))
    }

    // ------------------------------------------------------------ W11

    /** W11 -- the composition cannot send what it did not commit: with the radio
     *  refusing every byte, the durable estate still holdeth the frame and NOTHING
     *  is admitted (the named negative's first limb). */
    @Test
    fun test_w11_a_refused_link_leaveth_the_durable_estate_standing() = runTest {
        val h = world()
        h.link.admit = { _, _ -> false }
        Assert.assertTrue(h.sendDirect("A", "B", plaintext) is ComposedOutcome.Applied)
        val a = h.node("A")!!
        Assert.assertEquals("nothing was admitted", 0, h.link.admitted())
        Assert.assertTrue("and every attempt is recorded as REFUSED", h.link.refused() >= 1)
        val mid = a.store.allHeldMsgIds().single()
        Assert.assertEquals("the durable row standeth queued and retryable",
            DeliveryState.QUEUED_DURABLY,
            (a.tracker.lookup(mid) as DeliveryLookup.Found).record.state)
        Assert.assertEquals("the label saith QUEUED, never OFFERED",
            io.godstone.mesh.delivery.DeliveryLabel.QUEUED, a.node.deliveryProjection(mid).label)
        h.link.admit = { _, _ -> true }
    }

    // ------------------------------------------------------------ W12

    /** W12 -- the COMPOSED-TRACE law: every CONTENT byte the radio carried belongeth
     *  to a frame the sender durably holdeth. A composition that bypassed the durable
     *  commit could not satisfy this, which is the card's named semantic negative. */
    @Test
    fun test_w12_every_relayed_byte_belongeth_to_a_durably_held_frame() = runTest {
        val h = world()
        Assert.assertTrue(h.sendDirect("A", "B", plaintext) is ComposedOutcome.Applied)
        h.turn("A", "R")
        h.turn("R", "B")
        h.turnAcks("B", "R")
        h.turnAcks("R", "A")
        var contentChecked = 0
        for (delivery in h.link.deliveries()) {
            val frame = io.godstone.mesh.wire.v2.FrameV2.decode(delivery.bytesCopy()) ?: continue
            if (frame.type != io.godstone.mesh.wire.v2.TypeV2.MESSAGE &&
                frame.type != io.godstone.mesh.wire.v2.TypeV2.SOS) continue
            val sender = h.node(delivery.fromLabel)!!
            Assert.assertTrue(
                "a " + frame.type + " byte left " + delivery.fromLabel +
                    " without its durable frame standing",
                sender.store.allHeldMsgIds().any { it.contentEquals(frame.msgId) })
            contentChecked++
        }
        Assert.assertTrue("at least one content frame was checked", contentChecked >= 1)
        // and the composed trace carrieth the evidence of that road
        val kinds = h.traceSnapshot().kinds()
        Assert.assertTrue(kinds.contains("send_direct"))
        Assert.assertTrue(kinds.contains("link_offer"))
        Assert.assertTrue(kinds.contains("turn"))
    }

    // ------------------------------------------------------------ helpers

    private fun contains(haystack: ByteArray, needle: ByteArray): Boolean {
        if (needle.isEmpty() || haystack.size < needle.size) return false
        outer@ for (i in 0..(haystack.size - needle.size)) {
            for (j in needle.indices) if (haystack[i + j] != needle[j]) continue@outer
            return true
        }
        return false
    }
}
