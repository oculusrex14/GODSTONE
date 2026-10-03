package io.godstone.mesh.lab.crash

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import io.godstone.mesh.DirectDispatchResult
import io.godstone.mesh.delivery.DeliveryState
import io.godstone.mesh.rig.RealTransportHostRig
import io.godstone.mesh.transport.BleDirection
import io.godstone.mesh.transport.PeerId
import io.godstone.mesh.transport.TransportResult
import io.godstone.mesh.wire.v2.FrameV2
import java.io.File
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * *** GS-CRASH-001 `late-lifecycle`: THE CRASH + DISCONNECT REPRODUCTION HARNESS. ***
 *
 * *These classes drive the REAL runtime through the [RealTransportHostRig] forked-worker road -- the production
 * composition root (`MeshModule.provideMeshNode`) over REAL on-disk SQLite estates, with ONLY the OS/hardware facade
 * substituted -- and reproduce the LATER LIFECYCLE after the initial handshake: what happens when a worker's radio
 * leg CRASHES, when the platform reports a real CHANNEL DISCONNECT, and when the runtime is TERMINATED late in life.*
 *
 * *** THE CRASH BOUNDARY IS AN INJECTED FAILURE AT A REAL PRODUCTION SEAM, NEVER A HARNESS NO-OP. *** *[WorkerCrash]
 * is thrown from INSIDE the production `MeshNode.dispatchDirect` send closure (the radio leg) or through the inbox's
 * own `"signing"` / `"frame_insert"` fault seam -- so the durable commit that PRECEDES that leg really committed, and
 * the crash really lands in the middle of the production road.* **A scenario then proveth the mesh's REAL answer to
 * that crash: the durable estate that survived, the refusal the crashed node now gives, or the recovery a FRESH
 * composition over the SAME on-disk estate reaches** -- never merely that no exception escaped a fixture.
 *
 * *** NOTHING HERE ASSERTS WHAT A FAKE RETURNETH. *** *Every observation is read from the OWNER PRODUCTION BUILT: the
 * `SqliteMessageStore`'s own durable rows, `SessionManager`'s own readiness/slot census, the transport's own published
 * relation ledger, `DefaultRuntimeLifecycleGate`'s own terminal state, `StoreQuota`'s own pure policy, and the
 * `DeliveryTracker`'s own record. The rig supplies no counter these assertions rest on.*
 *
 * *** THE STORE BACKEND IS SUBSTITUTED AND THAT IS NAMED, NOT HIDDEN. *** *`JdbcStoreDb` stands in for the native
 * SQLCipher link, exactly as every host harness on this isle substitutes it; NEITHER THIS COURT NOR ANY EVIDENCE IT
 * PRODUCES CLAIMETH ANDROIDKEYSTORE OR APPROVED-SQLCIPHER-DEVICE PROOF.*
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33])
internal abstract class CrashScenarioCourt {

    /** A fixture root OUTLIVING a `tearDown`, so a fresh composition reacheth the SAME durable estate. */
    protected lateinit var root: File

    protected var rig: RealTransportHostRig? = null

    /** The boundary at which the last injected worker failure landed, for the record. */
    protected var lastCrash: WorkerCrash? = null

    @Before
    fun mintEstate() {
        root = File.createTempFile("gs_crash_", "").let { it.delete(); it.mkdirs(); it.deleteOnExit(); it }
    }

    @After
    fun razeEstate() {
        runCatching { rig?.tearDown() }
        root.deleteRecursively()
    }

    protected fun ctx(): Context = ApplicationProvider.getApplicationContext()

    /** A rig over a CALLER-OWNED root, so `tearDown` leaveth the estate standing for a fresh composition. */
    protected fun newRig(): RealTransportHostRig =
        RealTransportHostRig(ctx(), root).also { rig = it }

    // ============================================================================================
    // MARK: - the crash boundary
    // ============================================================================================

    /**
     * *** THE WORKER-CRASH BOUNDARY: AN INJECTED FAILURE NAMED BY THE SEAM IT LANDED AT. ***
     *
     * *It is a RuntimeException so it travels the production call stack exactly as a dead worker's radio leg would;
     * the scenario CATCHES it at the boundary and then reads the durable estate the crash left behind.*
     */
    protected class WorkerCrash(val boundary: String, val detail: String = "") :
        RuntimeException("worker crash at boundary '$boundary'" + if (detail.isEmpty()) "" else ": $detail")

    /** The typed outcome of a dispatch that may have crashed at a named radio boundary. */
    protected class CrashDispatch(val frame: FrameV2, val crash: WorkerCrash?)

    /**
     * *** DISPATCH A REAL DIRECT FRAME AND INJECT A WORKER CRASH IN THE RADIO LEG. ***
     *
     * *The frame is sealed by the PRODUCTION road ([RealTransportHostRig.authorDirectFrame]) and committed by the REAL
     * `MeshNode.dispatchDirect` BEFORE any radio byte -- so a crash at [offersToAllow] offers lands AFTER that durable
     * commit, exactly where a killed worker's write would.* **`offersToAllow = 0` crashes before the first radio byte
     * (the durable commit stands, nothing crossed); `1` crashes after the first hop really crossed.**
     */
    protected fun dispatchCrashing(
        from: String,
        to: String,
        plaintext: ByteArray,
        boundary: String,
        offersToAllow: Int,
    ): CrashDispatch {
        val r = rig!!
        val n = r.nodeOf(from)
        val target = r.handleTowards(from, to)
        val frame = r.authorDirectFrame(from, to, plaintext)
        var offers = 0
        var crash: WorkerCrash? = null
        try {
            runBlocking {
                n.node.dispatchDirect(frame, expectedRecipient = r.nodeOf(to).identity.nodeId) { peer, bytes ->
                    if (offers >= offersToAllow) {
                        throw WorkerCrash(boundary, "the radio leg died after $offers admitted offer(s)")
                    }
                    val address = PeerId.toAddress(peer) ?: peer.decodeToString()
                    if (address != target) return@dispatchDirect false
                    offers++
                    n.transport.send(peer, bytes) is TransportResult.Admitted
                }
            }
        } catch (c: WorkerCrash) {
            crash = c
            lastCrash = c
        }
        return CrashDispatch(frame, crash)
    }

    /**
     * *DISPATCH A FRAME THAT ALREADY CROSSED ITS FIRST HOP, THEN KILL THE WORKER ON THE RETRY'S RADIO LEG.*
     * **This is the honest "crash after the first hop crossed" shape: the first dispatch must really hand the frame
     * over (asserted by the caller), and the crash then lands on a re-offer of the SAME pinned frame -- so the
     * recipient's hold is real and the crash is still inside the production radio leg.**
     */
    protected fun dispatchCrashingOnRetry(
        from: String,
        to: String,
        frame: FrameV2,
        boundary: String,
    ): WorkerCrash? {
        val r = rig!!
        val n = r.nodeOf(from)
        val target = r.handleTowards(from, to)
        var crash: WorkerCrash? = null
        try {
            runBlocking {
                n.node.dispatchDirect(frame, expectedRecipient = r.nodeOf(to).identity.nodeId) { peer, _ ->
                    // the retry's radio leg dies at its first offer, before any second byte
                    val address = PeerId.toAddress(peer) ?: peer.decodeToString()
                    if (address != target) return@dispatchDirect false
                    throw WorkerCrash(boundary, "the radio leg died on a re-offer of an already-pinned frame")
                }
            }
        } catch (c: WorkerCrash) {
            crash = c
            lastCrash = c
        }
        return crash
    }

    // ============================================================================================
    // MARK: - a real established session
    // ============================================================================================

    /**
     * *** ONE REAL TWO-NODE SESSION, ESTABLISHED BY THE PRODUCTION LADDERS. ***
     *
     * *The role is the production `BleRoleElection`'s answer, the sealed handshake runs through the nodes' own
     * consumers, and [ready] is the rig's own exact-handle observation of BOTH of the opener's views -- so "the
     * handshake was established" is a measured fact before any later-lifecycle scenario begins.*
     */
    protected inner class Session(val a: String, val b: String) {
        val link: RealTransportHostRig.Link = rig!!.link(a, b)

        /** The party that opened the exchange (the election's answer -- the only side production can deliver to). */
        val opener: String = if (link.aOpened) a else b

        /** The other party. */
        val responder: String = if (link.aOpened) b else a

        /** The ADDRESS the opener useth to name the responder. */
        val openerHandle: String = if (link.aOpened) link.aHandle else link.bHandle

        /** The ADDRESS the responder useth to name the opener (its inbound connection's key). */
        val responderHandle: String = if (link.aOpened) link.bHandle else link.aHandle

        /** Is the opener's OWN view of the relation ready (the sealed key-confirmation round's own record)? */
        fun openerReady(): Boolean {
            val conn = rig!!.nodeOf(opener).transport.centralDriver.getActiveConnection(openerHandle)
                ?: return false
            return rig!!.nodeOf(opener).sessions.isReady(conn.peerId)
        }

        /** Is the responder's inbound relation ready? */
        fun responderReady(): Boolean {
            val conn = rig!!.nodeOf(responder).transport.serverDriver.getInboundConnection(responderHandle)
                ?: return false
            return rig!!.nodeOf(responder).sessions.isReady(conn.peerId)
        }

        fun assertEstablished() {
            assertEquals("*** the handshake is ESTABLISHED on the opener's own view ***", true, openerReady())
            assertEquals("*** and on the responder's ***", true, responderReady())
        }

        /** A third-party check that the opener's route-eligible view really carrieth the responder's wire identity. */
        fun openerRouteEligiblePeers(): Set<String> = rig!!.nodeOf(opener).node.knownPeersForTest()
    }

    /** Build the default two-node world (`A`/`B`), link it, and wait for the real established session. */
    protected fun establish(a: String = "A", b: String = "B"): Session {
        val r = newRig()
        r.makeNode(a)
        r.makeNode(b)
        val s = Session(a, b)
        assertTrue(
            "*** the link must be READY by the rig's own exact-handle contract: ${r.linkReadinessDetail(s.link)} ***",
            r.waitUntil { r.isLinkReady(s.link) },
        )
        s.assertEstablished()
        return s
    }

    // ============================================================================================
    // MARK: - the real platform disconnect doors
    // ============================================================================================

    /** *** THE INITIATOR's own platform door: the central-side disconnect the OS really delivers. *** */
    protected fun platformDisconnectInitiator(s: Session) {
        val n = rig!!.nodeOf(s.opener)
        val client = n.transport.activeClientForTest(s.openerHandle) ?: error("no client registration")
        n.transport.handleCentralDisconnected(s.openerHandle, client.clientToken, client.gattGeneration)
    }

    /** *** THE RESPONDER's own platform door: the peripheral-side disconnect, by the exact generation. *** */
    protected fun platformDisconnectResponder(s: Session) {
        val n = rig!!.nodeOf(s.responder)
        val gen = n.transport.serverDriver.getClientGeneration(s.responderHandle)
        n.transport.handleServerDisconnected(s.responderHandle, gen)
    }

    // ============================================================================================
    // MARK: - the fresh-composition recovery road (a killed worker's estate, re-opened)
    // ============================================================================================

    /**
     * *** KILL THE WORKER'S COMPOSITION AND RE-OPEN THE SAME ON-DISK ESTATE IN A FRESH ONE. ***
     *
     * *[RealTransportHostRig.tearDown] stoppeth the producers, drains, and CLOSES the stores while the owners stand
     * -- and, on a caller-owned root, deliberately LEAVETH THE FILES.* **A fresh composition over the same root
     * therefore reacheth the SAME identity material, the SAME `messages.db`, the SAME `peers.db`, and the SAME
     * `ack_frames` namespace -- which is the whole of the crash-recovery claim.** *A store left mid-transaction by
     * the kill rolls its transaction back at re-open, exactly as a real SQLite crash recovery doth.*
     */
    protected fun reopenEstate(): RealTransportHostRig {
        rig?.tearDown()
        return newRig()
    }

    // ============================================================================================
    // MARK: - assertions helpers kept honest
    // ============================================================================================

    protected fun assertCrashed(d: CrashDispatch) {
        assertNotNull(
            "*** the injected worker failure must really have landed in the radio leg -- a node with NO " +
                "route-eligible peer never calls the send closure at all ***",
            d.crash,
        )
        assertEquals("the crash names the radio boundary", true, d.crash!!.boundary.isNotEmpty())
    }

    protected fun hex(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it) }

    protected fun plaintext(tag: String): ByteArray =
        ("$tag -- the river riseth at dawn and the mill road is cut at both ends; " +
            "send boats and a medic to the church hall.").toByteArray(Charsets.US_ASCII)

    protected fun dispatchState(label: String, msgId: ByteArray): String =
        (rig!!.deliveryRow(label, msgId)?.let { DeliveryState.fromCode(it.state) } ?: DeliveryState.UNAVAILABLE).name

    protected fun assertOnlyQueuedAt(label: String, msgId: ByteArray) {
        assertEquals(
            "*** the durable commit that PRECEDED the crash must stand QUEUED_DURABLY at $label ***",
            DeliveryState.QUEUED_DURABLY.name, dispatchState(label, msgId),
        )
    }

    protected fun assertNotHeld(label: String, msgId: ByteArray) {
        assertFalse("*** nothing may be fabricated at $label for the crashed offer ***", rig!!.holdsMsg(label, msgId))
    }

    protected fun assertHeld(label: String, msgId: ByteArray) {
        assertTrue("*** the durable row must really stand at $label ***", rig!!.holdsMsg(label, msgId))
    }

    // ============================================================================================
    // MARK: - the transport's own relation ledger helpers
    // ============================================================================================

    protected fun anyRelationPublished(label: String, direction: BleDirection, handle: String): Boolean =
        rig!!.nodeOf(label).transport.isAnyRelationPublishedForAddress(direction, handle)

    protected fun publishedRelations(label: String): List<String> =
        rig!!.nodeOf(label).transport.publishedRelationsForTest().map { it.direction.name + ":" + it.peerAddress }

    protected fun transportSendRefused(label: String, handle: String, frame: FrameV2): TransportResult {
        val peerId = PeerId.fromAddress(handle) ?: handle.toByteArray()
        return runBlocking { rig!!.nodeOf(label).transport.send(peerId, frame.encode()) }
    }

    protected fun directDispatchResult(label: String, to: String, plaintext: ByteArray): DirectDispatchResult {
        val frame = rig!!.authorDirectFrame(label, to, plaintext)
        return dispatchExisting(label, to, frame)
    }

    /**
     * *DISPATCH AN ALREADY-AUTHORED FRAME over the production radio road.* **The caller keeps the frame, so the
     * `msgId` it asserts is the `msgId` that was really committed -- a separate authoring would silently test a
     * DIFFERENT frame.**
     */
    protected fun dispatchExisting(label: String, to: String, frame: FrameV2): DirectDispatchResult {
        val r = rig!!
        val n = r.nodeOf(label)
        val target = r.handleTowards(label, to)
        return runBlocking {
            n.node.dispatchDirect(frame, expectedRecipient = r.nodeOf(to).identity.nodeId) { peer, bytes ->
                val address = PeerId.toAddress(peer) ?: peer.decodeToString()
                if (address != target) return@dispatchDirect false
                n.transport.send(peer, bytes) is TransportResult.Admitted
            }
        }
    }
}
