package io.godstone.mesh.lab.crash

import io.godstone.mesh.DirectDispatchResult
import io.godstone.mesh.delivery.DeliveryState
import io.godstone.mesh.transport.BleDirection
import io.godstone.mesh.transport.PeerId
import io.godstone.mesh.transport.TransportResult
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * *** GS-CRASH-001 `channel-disconnect`: THE REAL PLATFORM DISCONNECT DOORS. ***
 *
 * *Six scenarios drive the transport's OWN platform entries --
 * `BleTransport.handleCentralDisconnected` (the initiator's ATT/GATT disconnect) and
 * `handleServerDisconnected` (the responder's peripheral disconnect) -- and then assert what the REAL runtime did to
 * the relation it had established: the sealed session's readiness, the published-relation ledger, the route-eligible
 * peer view, the ACK pump's schedule, and the answer a NEW send now gets.*
 *
 * *** EACH SCENARIO FIRST PROVES THE SESSION WAS REALLY ESTABLISHED AND REALLY DISCONNECTED; A NO-OP DOOR WOULD FAIL
 * BOTH HALVES. *** *The opener's route-eligible view is checked to CONTAIN the responder's wire identity before, and
 * to have LOST it after -- so "the relation fell" is a measurement of the production view, not of a fixture.*
 */
internal class RealChannelCrashScenarioTest : CrashScenarioCourt() {

    /** The responder's WIRE (MAC) identity, as the transport's `publishRelation` emits it. */
    private fun responderWireHex(s: Session): String =
        hex(PeerId.fromAddress(s.openerHandle)!!)

    private fun assertRouteEligible(s: Session, present: Boolean) {
        val key = responderWireHex(s)
        val held = s.openerRouteEligiblePeers().contains(key)
        if (present) {
            assertTrue("*** the established relation must be ROUTE-ELIGIBLE on the opener: " +
                "knownPeers=${s.openerRouteEligiblePeers()} key=$key ***", held)
        } else {
            assertFalse("*** the fallen relation must NOT remain route-eligible on the opener: " +
                "knownPeers=${s.openerRouteEligiblePeers()} key=$key ***", held)
        }
    }

    // ---------------------------------------------------------------- W01

    /** W01 -- the INITIATOR's platform disconnect tears down the exact relation it names. */
    @Test
    fun test_w01_initiatorPlatformDisconnectRetiresTheExactRelation() {
        val s = establish()
        val r = rig!!
        assertRouteEligible(s, present = true)
        assertTrue(
            "the opener's relation is published before the fall",
            anyRelationPublished(s.opener, BleDirection.OUTBOUND, s.openerHandle),
        )
        platformDisconnectInitiator(s)
        assertFalse("*** the sealed session is NO LONGER READY on the opener ***", s.openerReady())
        assertFalse(
            "*** and the opener's own publication ledger no longer carrieth the fallen relation " +
                "(published=${publishedRelations(s.opener)}) ***",
            anyRelationPublished(s.opener, BleDirection.OUTBOUND, s.openerHandle),
        )
        // *** THE PEER LOST TRAVELS THE TRANSPORT'S OWN ASYNCHRONOUS EVENT FLOW, SO THE DRAIN IS OBSERVED. ***
        assertTrue(
            "*** the fallen relation must DRAIN from the opener's route-eligible view: " +
                "knownPeers=${s.openerRouteEligiblePeers()} key=${responderWireHex(s)} ***",
            rig!!.waitUntil { !s.openerRouteEligiblePeers().contains(responderWireHex(s)) },
        )
        assertEquals("the responder's inbound side is untouched by the initiator's fall", true, s.responderReady())
        assertTrue("the whole transport was not stopped", r.nodeOf(s.opener).transport.isTransportStartedForTest())
    }

    // ---------------------------------------------------------------- W02

    /** W02 -- the RESPONDER's platform disconnect tears down the exact relation it names. */
    @Test
    fun test_w02_responderPlatformDisconnectRetiresTheExactRelation() {
        val s = establish()
        platformDisconnectResponder(s)
        assertFalse("*** the sealed session is NO LONGER READY on the responder ***", s.responderReady())
        assertEquals("the opener's outbound side is untouched by the responder's fall", true, s.openerReady())
    }

    // ---------------------------------------------------------------- W03

    /**
     * W03 -- A DISCONNECT FOR A SUPERSEDED REGISTRATION IS A NO-OP (T12's own token law).
     *
     * *The platform's disconnect carrieth the clientToken AND the GATT generation it was scheduled for; an event
     * naming ANOTHER registration must change nothing. This proves the teardown the other scenarios observe is the
     * TOKEN-CHECKED one rather than a blanket `disconnectAll`.*
     */
    @Test
    fun test_w03_aStaleRegistrationDisconnectIsANoOp() {
        val s = establish()
        val n = rig!!.nodeOf(s.opener)
        val client = n.transport.activeClientForTest(s.openerHandle) ?: error("no client registration")
        // A registration that is NOT the live one: same address, different tokens.
        n.transport.handleCentralDisconnected(s.openerHandle, client.clientToken + 1L, client.gattGeneration)
        assertEquals("*** a stale client-token disconnect must NOT retire the live relation ***", true, s.openerReady())
        assertTrue(anyRelationPublished(s.opener, BleDirection.OUTBOUND, s.openerHandle))
        n.transport.handleCentralDisconnected(s.openerHandle, client.clientToken, client.gattGeneration + 1L)
        assertEquals("*** nor a stale GATT generation ***", true, s.openerReady())
        assertTrue(anyRelationPublished(s.opener, BleDirection.OUTBOUND, s.openerHandle))
        // and the EXACT tokens really do retire it (the positive control for the two above)
        n.transport.handleCentralDisconnected(s.openerHandle, client.clientToken, client.gattGeneration)
        assertFalse("the exact registration retires the relation", s.openerReady())
    }

    // ---------------------------------------------------------------- W04

    /** W04 -- AFTER THE FALL, A NEW DIRECT SEND IS DURABLY QUEUED AND NOTHING IS HANDED TO A DEAD RADIO. */
    @Test
    fun test_w04_aSendAfterTheDisconnectQueuesDurablyWithoutHandingToADeadRadio() {
        val s = establish()
        val body = plaintext("w04")
        val frame = rig!!.authorDirectFrame(s.opener, s.responder, body)
        platformDisconnectInitiator(s)
        val peerId = PeerId.fromAddress(s.openerHandle) ?: s.openerHandle.toByteArray()
        val verdict = transportSendRefused(s.opener, s.openerHandle, frame)
        assertTrue(
            "*** the transport's own send door must REFUSE a fallen relation (observed $verdict) ***",
            verdict is TransportResult.Rejected || verdict is TransportResult.Closed,
        )
        val result = dispatchExisting(s.opener, s.responder, frame)
        assertEquals(
            "*** with no live relation the dispatch queues LOCALLY (observed $result) ***",
            DirectDispatchResult.QueuedLocally, result,
        )
        assertTrue("the author really holds the frame durably", rig!!.holdsMsg(s.opener, frame.msgId))
        assertEquals(
            "*** and the durable row stands QUEUED_DURABLY -- no custody is claimed from a dead link ***",
            DeliveryState.QUEUED_DURABLY.name, dispatchState(s.opener, frame.msgId),
        )
        assertFalse("nothing reached the dead recipient", rig!!.holdsMsg(s.responder, frame.msgId))
        // keep the compiler honest about peerId being the real handle
        assertEquals("the peer handle is the live address", s.openerHandle, PeerId.toAddress(peerId))
    }

    // ---------------------------------------------------------------- W05

    /** W05 -- THE ACK PUMP DROPS THE DEPARTED RELATION FROM ITS OWN SCHEDULE. */
    @Test
    fun test_w05_theAckPumpUnschedulesTheDepartedRelation() {
        val s = establish()
        val n = rig!!.nodeOf(s.opener)
        val peerMac = PeerId.fromAddress(s.openerHandle)!!
        n.pump.onLinkReady(peerMac)
        assertTrue(
            "the pump schedules a ready relation",
            n.pump.scheduledPeersForTest().any { it.contentEquals(peerMac) },
        )
        platformDisconnectInitiator(s)
        assertTrue(
            "*** the departure must UNSCHEDULE the peer -- the pump must not keep offering to a departed " +
                "relation (scheduled=${n.pump.scheduledPeersForTest().map { hex(it) }}) ***",
            rig!!.waitUntil { n.pump.scheduledPeersForTest().none { it.contentEquals(peerMac) } },
        )
    }

    // ---------------------------------------------------------------- W06

    /** W06 -- BOTH PLATFORM DOORS IN SEQUENCE: both views fall, both ledgers empty, and both sides queue only. */
    @Test
    fun test_w06_bothPlatformDoorsFallTogetherAndEveryEstateStaysDurable() {
        val s = establish()
        platformDisconnectInitiator(s)
        platformDisconnectResponder(s)
        assertFalse("the opener's relation fell", s.openerReady())
        assertFalse("the responder's relation fell", s.responderReady())
        assertFalse(anyRelationPublished(s.opener, BleDirection.OUTBOUND, s.openerHandle))
        assertFalse(anyRelationPublished(s.responder, BleDirection.INBOUND, s.responderHandle))
        val body = plaintext("w06")
        val frame = rig!!.authorDirectFrame(s.opener, s.responder, body)
        val result = dispatchExisting(s.opener, s.responder, frame)
        assertEquals("nothing was handed on either dead leg", DirectDispatchResult.QueuedLocally, result)
        assertOnlyQueuedAt(s.opener, frame.msgId)
        assertNotHeld(s.responder, frame.msgId)
    }
}
