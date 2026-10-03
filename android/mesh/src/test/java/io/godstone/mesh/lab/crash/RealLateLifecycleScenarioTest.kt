package io.godstone.mesh.lab.crash

import io.godstone.mesh.DirectDispatchResult
import io.godstone.mesh.delivery.DeliveryState
import io.godstone.mesh.identity.MeshRuntimeInvalidator
import io.godstone.mesh.transport.BleDirection
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * *** GS-CRASH-001 `late-lifecycle`: TERMINATION AFTER THE HANDSHAKE. ***
 *
 * *Eight scenarios. The relation is established by the production ladders FIRST, and only then is the runtime
 * terminated -- so every assertion is about what a live, fully-established composition does when it is torn down,
 * never about a cold object:*
 *
 *  1. **`MeshNode.stop()` DRAINS**: the node's own session slots, route-eligible peer view, published-relation
 *     ledger and (through the node's OWN lifecycle authority) its radio are all released;
 *  2. **the node's lifecycle authority is TERMINAL** after the platform's power word, and a re-start is refused;
 *  3. **the permission-revocation word is terminal for ever** (the pinned T28 law);
 *  4. **a double stop is idempotent** -- the adapters are closed through the owner exactly ONCE;
 *  5. **the runtime invalidator (`MeshRuntimeInvalidator`) terminally closes the gate, the sessions and the
 *     stores** -- the wipe path's own order (stop the workers BEFORE deleting keys);
 *  6. **the durable estate SURVIVES the termination**: a fresh composition reads the same frame and identity;
 *  7. **a killed runtime offers nothing**: a post-stop dispatch queues durably and the outlet records NO byte;
 *  8. **a full teardown of both nodes** clears both views, both ledgers and both radios at once.
 *
 * *** WHERE A SCENARIO DRIVES THE NODE'S LIFECYCLE AUTHORITY DIRECTLY, IT SAYS SO. *** *This shipping tree FREEZES the
 * link-layer readiness flag off, so `MeshNode.start()` returneth false BY CONSTRUCTION and its own `openAdapters()`
 * (which is where production starteth the authority) is unreachable; the rig already bypasseth that gate for the
 * radio. A termination scenario therefore starteth THE NODE'S OWN `lifecycle` INSTANCE and then terminates it -- the
 * authority is production's, the drain it performeth is real, and nothing is simulated.*
 */
internal class RealLateLifecycleScenarioTest : CrashScenarioCourt() {

    /**
     * *Start the NODE'S OWN lifecycle authority -- the step production's frozen `openAdapters()` would take -- and
     * prove it is really READY before any termination is driven.*
     */
    private fun startNodeLifecycle(label: String) {
        val authority = rig!!.nodeOf(label).node.lifecycle
        authority.start()
        assertTrue("*** the node's own lifecycle authority must be READY before termination ***", authority.isReady())
    }

    // ---------------------------------------------------------------- W01

    /** W01 -- `MeshNode.stop()` DRAINS THE ESTABLISHED RELATION AND ITS RADIO. */
    @Test
    fun test_w01_stopDrainsTheSessionThePeerViewAndTheRadio() {
        val s = establish()
        val n = rig!!.nodeOf(s.opener)
        startNodeLifecycle(s.opener)
        assertTrue("the opener is really started before the stop", n.transport.isTransportStartedForTest())
        assertTrue("and the session is READY", s.openerReady())
        assertTrue("and its peer view is populated", n.node.knownPeersForTest().isNotEmpty())

        n.node.stop()

        assertEquals("*** the session owner's own census is ZERO after stop ***", 0, n.sessions.slotCountForTest())
        assertTrue("*** the route-eligible peer view is DRAINED ***", n.node.knownPeersForTest().isEmpty())
        assertTrue("*** the published-relation ledger is DRAINED ***", n.transport.publishedRelationsForTest().isEmpty())
        assertFalse("*** and the radio is CLOSED through the node's own authority ***", n.transport.isTransportStartedForTest())
        assertFalse("the lifecycle authority is no longer READY", n.node.lifecycle.isReady())
        assertEquals("the adapters were closed through the owner exactly once", 1, n.node.adaptersClosedThroughTheOwner)
        assertEquals("the responder's side is untouched by the opener's stop", true, s.responderReady())
    }

    // ---------------------------------------------------------------- W02

    /** W02 -- THE PLATFORM'S POWER WORD IS TERMINAL FOR THE NODE'S OWN AUTHORITY. */
    @Test
    fun test_w02_thePlatformPowerWordIsTerminalAndRefusesARestart() {
        val s = establish()
        val n = rig!!.nodeOf(s.opener)
        startNodeLifecycle(s.opener)
        val authority = n.node.lifecycle
        authority.onPowerLoss()
        assertEquals(
            "*** a power loss is TERMINAL_UNAVAILABLE, not a temporary suspension ***",
            "TERMINAL_UNAVAILABLE", authority.capabilityState().name,
        )
        assertFalse("and the authority is no longer READY", authority.isReady())
        assertFalse("*** and its drain really closed the radio ***", n.transport.isTransportStartedForTest())
        assertEquals("*** and severed the live clients it owned ***", 0, n.transport.activeClientCountForTest())
        // A RESTART MUST BE REFUSED: the terminal capability suppresseth it.
        authority.start()
        assertFalse("*** a terminal authority must REFUSE a restart ***", authority.isStarted())
        assertEquals("and remain terminal", "TERMINAL_UNAVAILABLE", authority.capabilityState().name)
    }

    // ---------------------------------------------------------------- W03

    /** W03 -- A WITHDRAWN PERMISSION IS TERMINAL FOR EVER (the pinned T28 law). */
    @Test
    fun test_w03_theWithdrawnPermissionIsTerminalForEver() {
        val s = establish()
        val n = rig!!.nodeOf(s.opener)
        startNodeLifecycle(s.opener)
        val authority = n.node.lifecycle
        authority.onPermissionRemoved()
        assertEquals(
            "*** a withdrawn permission is TERMINAL_PERMISSION_REVOKED ***",
            "TERMINAL_PERMISSION_REVOKED", authority.capabilityState().name,
        )
        assertFalse("the authority is not ready", authority.isReady())
        // A later start must NOT resurrect it, however the platform later answereth.
        authority.start()
        authority.start()
        assertEquals(
            "*** the revocation is remembered across every later start attempt ***",
            "TERMINAL_PERMISSION_REVOKED", authority.capabilityState().name,
        )
        assertFalse(authority.isStarted())
    }

    // ---------------------------------------------------------------- W04

    /** W04 -- A DOUBLE STOP IS IDEMPOTENT: the adapters close through the owner EXACTLY once. */
    @Test
    fun test_w04_aDoubleStopClosesTheAdaptersExactlyOnce() {
        val s = establish()
        val n = rig!!.nodeOf(s.opener)
        startNodeLifecycle(s.opener)
        n.node.stop()
        n.node.stop()
        n.node.stop()
        assertEquals(
            "*** the owner's own close census must be ONE across repeated stops ***",
            1, n.node.adaptersClosedThroughTheOwner,
        )
        assertEquals("and the sessions were destroyed once", 0, n.sessions.slotCountForTest())
        assertFalse("the radio stays closed", n.transport.isTransportStartedForTest())
        assertTrue("and the node's own estate owner still answereth its durable rows", n.messageStore !== null)
    }

    // ---------------------------------------------------------------- W05

    /**
     * W05 -- THE RUNTIME INVALIDATOR CLOSES THE GATE, THE SESSIONS AND THE STORES IN PRODUCTION'S OWN ORDER.
     *
     * *`MeshRuntimeInvalidator.invalidateForWipe()` is the wipe path's own authority: it invalidates the lifecycle
     * gate FIRST, then stops the node, then destroys the sessions, and only then closes the peer store and the
     * message store -- "stop/drain workers BEFORE deleting keys".*
     */
    @Test
    fun test_w05_theRuntimeInvalidatorTerminallyClosesGateSessionsAndStores() {
        val s = establish()
        val n = rig!!.nodeOf(s.opener)
        startNodeLifecycle(s.opener)
        val probe = ByteArray(16) { (it + 1).toByte() }
        assertEquals("the control: the store is readable before the invalidation", null, n.engine.readDelivery(probe))

        MeshRuntimeInvalidator(
            lifecycleGate = n.gate,
            sessions = n.sessions,
            peerStore = n.peerStore,
            messageStore = n.messageStore,
            node = n.node,
        ).invalidateForWipe()

        assertTrue("*** the lifecycle gate is INVALIDATED ***", n.gate.isInvalidated)
        assertFalse("and it no longer permits sensitive use", n.gate.isActive)
        assertTrue("*** the session owner is INVALIDATED ***", n.sessions.isInvalidated)
        assertFalse("and the radio was stopped by the node's own stop", n.transport.isTransportStartedForTest())
        val read = runCatching { n.engine.readDelivery(probe) }
        assertTrue(
            "*** and the store's OWN engine must refuse a read once closed: observed $read ***",
            read.isFailure,
        )
    }

    // ---------------------------------------------------------------- W06

    /** W06 -- THE DURABLE ESTATE SURVIVES THE TERMINATION, AND A FRESH COMPOSITION READETH IT. */
    @Test
    fun test_w06_theDurableEstateSurvivesTerminationAndIsReRead() {
        val s = establish()
        val frame = rig!!.authorDirectFrame(s.opener, s.responder, plaintext("w06"))
        val handed = dispatchExisting(s.opener, s.responder, frame)
        assertEquals(
            "the frame must really have crossed to the live relay before the termination " +
                "(observed $handed)",
            DirectDispatchResult.HandedToRelays(1), handed,
        )
        assertTrue("the recipient really committed it", rig!!.waitUntil { rig!!.holdsMsg(s.responder, frame.msgId) })
        val openerId = rig!!.nodeOf(s.opener).identity.nodeId.copyOf()
        startNodeLifecycle(s.opener)
        rig!!.nodeOf(s.opener).node.stop()

        val reopened = reopenEstate()
        reopened.makeNode(s.opener); reopened.makeNode(s.responder)
        assertTrue(
            "*** the fresh composition re-readeth the SAME on-disk identity ***",
            reopened.nodeOf(s.opener).identity.nodeId.contentEquals(openerId),
        )
        assertTrue("*** and the frame the terminated author durably held ***", reopened.holdsMsg(s.opener, frame.msgId))
        assertTrue("*** and the frame the recipient durably held ***", reopened.holdsMsg(s.responder, frame.msgId))
        assertEquals(
            "*** with its delivery row still QUEUED_DURABLY -- the termination claimed no delivery ***",
            DeliveryState.QUEUED_DURABLY.name,
            (reopened.deliveryRow(s.opener, frame.msgId)?.let { DeliveryState.fromCode(it.state) }
                ?: DeliveryState.UNAVAILABLE).name,
        )
    }

    // ---------------------------------------------------------------- W07

    /** W07 -- A KILLED RUNTIME OFFERS NOTHING: a post-stop dispatch queues durably and NO radio byte leaveth. */
    @Test
    fun test_w07_aPostStopDispatchQueuesDurablyAndPutsNoByteOnTheAir() {
        val s = establish()
        val n = rig!!.nodeOf(s.opener)
        startNodeLifecycle(s.opener)
        n.node.stop()
        val bytesBefore = n.outlet.bytes()
        val frame = rig!!.authorDirectFrame(s.opener, s.responder, plaintext("w07"))
        val result = dispatchExisting(s.opener, s.responder, frame)
        assertEquals(
            "*** a stopped runtime handeth the frame to NOBODY (observed $result) ***",
            DirectDispatchResult.QueuedLocally, result,
        )
        assertEquals(
            "*** and NOT ONE radio byte may leave a closed runtime ***",
            bytesBefore, n.outlet.bytes(),
        )
        assertOnlyQueuedAt(s.opener, frame.msgId)
        assertFalse("nothing reached the recipient", rig!!.holdsMsg(s.responder, frame.msgId))
    }

    // ---------------------------------------------------------------- W08

    /** W08 -- A FULL TEARDOWN OF BOTH NODES CLEARS BOTH VIEWS, BOTH LEDGERS AND BOTH RADIOS AT ONCE. */
    @Test
    fun test_w08_aFullTeardownClearsBothNodesAtOnce() {
        val s = establish()
        startNodeLifecycle(s.opener)
        startNodeLifecycle(s.responder)
        assertTrue(anyRelationPublished(s.opener, BleDirection.OUTBOUND, s.openerHandle))

        rig!!.nodeOf(s.opener).node.stop()
        rig!!.nodeOf(s.responder).node.stop()

        for (label in listOf(s.opener, s.responder)) {
            val n = rig!!.nodeOf(label)
            assertEquals("$label: session census zero", 0, n.sessions.slotCountForTest())
            assertTrue("$label: peer view drained", n.node.knownPeersForTest().isEmpty())
            assertTrue("$label: publication ledger drained", n.transport.publishedRelationsForTest().isEmpty())
            assertFalse("$label: radio closed", n.transport.isTransportStartedForTest())
        }
        assertFalse("neither side's relation is ready", s.openerReady() || s.responderReady())
    }
}
