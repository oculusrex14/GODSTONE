package io.godstone.mesh.lab.crash

import io.godstone.mesh.delivery.DeliveryLabel
import io.godstone.mesh.delivery.DeliveryState
import io.godstone.mesh.delivery.InboxCommitResult
import io.godstone.mesh.delivery.PairList
import io.godstone.mesh.delivery.PendingList
import io.godstone.mesh.store.SqliteMessageStore
import io.godstone.mesh.wire.v2.FrameV2
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * *** GS-CRASH-001 `worker-crash`: AN INJECTED WORKER FAILURE AT A REAL PRODUCTION SEAM, AND THE MESH'S REAL ANSWER. ***
 *
 * *Ten scenarios. Four boundaries, each an ACTUAL production fault seam rather than a harness no-op:*
 *
 *  1. **the RADIO LEG of `MeshNode.dispatchDirect`** -- the send closure is where a killed worker's write would die,
 *     and it stands AFTER the whole durable enqueue committed. A crash here leaveth a frame whose delivery row sayeth
 *     QUEUED_DURABLY and NO custody claim;
 *  2. **the recipient inbox's own `"signing"` seam** -- reached by entering the very `acceptVerifiedAndRequireAck`
 *     the node's inbound collector calls; the T83 held+obligation transaction has ALREADY returned Committed, so the
 *     frame and its obligation survive while the canonical ACK was never signed;
 *  3. **the inbox's own `"frame_insert"` seam** -- the ACK was signed and self-verified but its `ack_frames` row was
 *     never filed; the obligation stays PENDING;
 *  4. **the store's own `"obligation"` seam inside the inbound transaction** -- a throw here rolls the WHOLE commit
 *     back, so the both-or-neither law (no held frame without its row) is proven by the ABSENCE of both.
 *
 * *** EVERY RECOVERY REACHES THE SAME ESTATE THROUGH A FRESH COMPOSITION. *** *A killed worker's `tearDown` closes the
 * stores while the owners stand and LEAVETH the caller-owned files; the fresh composition re-reads the SAME
 * `identity.bin`, the SAME `messages.db` and the SAME `ack_frames` namespace -- and its own inbox RESUMES the
 * delivery by re-ingesting the same sealed frame.* **A recovery that minted a fresh identity or store could not do
 * that, which is why the identity-continuity assertion is present rather than assumed.**
 */
internal class RealWorkerCrashScenarioTest : CrashScenarioCourt() {

    // ============================================================================================
    // MARK: - the inbox's own fault seam, entered exactly as the node's collector enters it
    // ============================================================================================

    private class Ingest(val result: InboxCommitResult?, val crash: WorkerCrash?)

    /**
     * *Enter the recipient's REAL inbox on the REAL sealed frame, injecting [at] as a kill. The inbox's `fault`
     * parameter is the court-only seam the node's own collector passeth `null` -- production is byte-identical.*
     */
    private fun ingestCrashing(recipient: String, frame: FrameV2, author: String, at: String?): Ingest {
        val n = rig!!.nodeOf(recipient)
        val inbox = n.node.recipientInbox ?: error("the recipient's inbox owner was never bound")
        val from = rig!!.nodeOf(author).identity.nodeId
        var crash: WorkerCrash? = null
        val result = try {
            runBlocking {
                inbox.acceptVerifiedAndRequireAck(frame, from) { seam ->
                    if (seam == at) throw WorkerCrash("inbox:$seam")
                }
            }
        } catch (c: WorkerCrash) {
            crash = c; lastCrash = c; null
        }
        return Ingest(result, crash)
    }

    private fun ingestClean(recipient: String, frame: FrameV2, author: String): InboxCommitResult? {
        val n = rig!!.nodeOf(recipient)
        val inbox = n.node.recipientInbox ?: error("the recipient's inbox owner was never bound")
        val from = rig!!.nodeOf(author).identity.nodeId
        return runBlocking { inbox.acceptVerifiedAndRequireAck(frame, from) }
    }

    /** The durable ACK rows production filed for this (msgId, recipient) pair. */
    private fun ackRows(recipient: String, msgId: ByteArray): Int {
        val n = rig!!.nodeOf(recipient)
        return when (val pl = n.ackStore.candidatesForPair(msgId, n.identity.nodeId, 8)) {
            is PairList.Records -> pl.records.size
            else -> -1
        }
    }

    /** The PENDING obligations the owner carrieth -- a real durable census, never a court counter. */
    private fun pendingObligations(recipient: String): Int {
        val n = rig!!.nodeOf(recipient)
        return when (val pl = n.ackStore.listPending(64)) {
            is PendingList.Rows -> pl.rows.size
            is PendingList.Corrupt -> -1
            is PendingList.StorageFailure -> -2
        }
    }

    private fun heldCount(label: String): Int = rig!!.heldMsgIds(label).size

    private fun assertCrash(inj: Ingest, boundary: String) {
        assertTrue("*** the injected worker failure must really have landed at '$boundary' ***", inj.crash != null)
        assertTrue(inj.crash!!.boundary.contains(boundary))
    }

    // ---------------------------------------------------------------- W01

    /**
     * W01 -- A CRASH IN THE RADIO LEG BEFORE THE FIRST OFFER: THE DURABLE COMMIT STANDS, NOTHING CROSSED.
     *
     * *`dispatchDirect` commits the held frame AND the `QUEUED_DURABLY` delivery row in ONE transaction and ONLY THEN
     * iterateth the peers; a worker killed at the first offer leaveth that commit INTACT and the radio silent.*
     */
    @Test
    fun test_w01_radioLegCrashBeforeTheFirstOfferLeavesTheDurableCommitStanding() {
        val s = establish()
        val body = plaintext("w01")
        val d = dispatchCrashing(s.opener, s.responder, body, "before_first_offer", offersToAllow = 0)
        assertCrashed(d)
        assertHeld(s.opener, d.frame.msgId)
        assertOnlyQueuedAt(s.opener, d.frame.msgId)
        assertNotHeld(s.responder, d.frame.msgId)
        assertEquals(
            "*** the label claimeth no custody -- OFFERED would be a claim the radio died before making ***",
            DeliveryLabel.QUEUED.name, rig!!.nodeOf(s.opener).node.deliveryProjection(d.frame.msgId).label.name,
        )
        assertTrue("the crashed row is still RETRYABLE", rig!!.nodeOf(s.opener).node.deliveryProjection(d.frame.msgId).retryable)
    }

    // ---------------------------------------------------------------- W02

    /** W02 -- A CRASH AFTER THE FIRST HOP REALLY CROSSED: THE RECIPIENT HOLDS IT; THE AUTHOR STILL CLAIMS NOTHING. */
    @Test
    fun test_w02_radioLegCrashAfterTheFirstHopLeavesTheRecipientHoldingAndNoClaim() {
        val s = establish()
        // the first dispatch really crosses the hop (HandedToRelays), then the SAME pinned frame is re-offered
        // and the worker's radio leg dies on THAT offer -- still inside production's dispatch road
        val body = plaintext("w02")
        val frame = rig!!.authorDirectFrame(s.opener, s.responder, body)
        val first = dispatchExisting(s.opener, s.responder, frame)
        assertEquals(
            "*** the first hop must really have been handed to the live relay (observed $first) ***",
            io.godstone.mesh.DirectDispatchResult.HandedToRelays(1), first,
        )
        assertTrue(
            "*** and the recipient really committed it before the worker died ***",
            rig!!.waitUntil { rig!!.holdsMsg(s.responder, frame.msgId) },
        )
        val crash = dispatchCrashingOnRetry(s.opener, s.responder, frame, "after_first_hop")
        assertTrue("*** the crash must really have landed on the retry's radio leg ***", crash != null)
        assertOnlyQueuedAt(s.opener, frame.msgId)
        assertEquals(
            "*** the author claims NO delivery from admitted offers alone ***",
            DeliveryLabel.OFFERED.name, rig!!.nodeOf(s.opener).node.deliveryProjection(frame.msgId).label.name,
        )
    }

    // ---------------------------------------------------------------- W03

    /**
     * W03 -- THE KILLED WORKER'S ESTATE SURVIVES THE KILL, AND A FRESH COMPOSITION REACHETH THE SAME FRAME.
     *
     * *The discriminator is the `msgId` the author sealed: finding THE SAME sixteen octets in a second composition
     * over the same root proveth the durable continuity -- and the identity is re-read from disk, so it is the SAME
     * node rather than a look-alike.*
     */
    @Test
    fun test_w03_aFreshCompositionReachesTheCrashedAuthorsSameFrameAndIdentity() {
        val s = establish()
        val crashedNodeId = rig!!.nodeOf(s.opener).identity.nodeId.copyOf()
        val d = dispatchCrashing(s.opener, s.responder, plaintext("w03"), "kill", offersToAllow = 0)
        assertCrashed(d)
        val reopened = reopenEstate()
        reopened.makeNode(s.opener); reopened.makeNode(s.responder)
        assertTrue(
            "*** the fresh composition must re-read the SAME identity from the same on-disk estate ***",
            reopened.nodeOf(s.opener).identity.nodeId.contentEquals(crashedNodeId),
        )
        assertTrue("*** and the SAME durable frame must still stand ***", reopened.holdsMsg(s.opener, d.frame.msgId))
        assertEquals(
            "*** with its delivery row still QUEUED_DURABLY -- the kill stole no durable state ***",
            DeliveryState.QUEUED_DURABLY.name,
            (reopened.deliveryRow(s.opener, d.frame.msgId)?.let { DeliveryState.fromCode(it.state) } ?: DeliveryState.UNAVAILABLE).name,
        )
    }

    // ---------------------------------------------------------------- W04

    /**
     * W04 -- THE RESUMED AUTHOR RE-DISPATCHES THE SAME FRAME: NO SECOND AUTHORING, THE SAME `msgId`.
     *
     * *`enqueueDirectOutbound` answereth `AlreadyQueuedSameBinding` for the byte-identical frame -- which `dispatchDirect`
     * readeth as the same pinned frame -- so a retry cannot mint a second intent.*
     */
    @Test
    fun test_w04_theResumedAuthorReDispatchesWithoutASecondAuthoring() {
        val s = establish()
        val d = dispatchCrashing(s.opener, s.responder, plaintext("w04"), "kill", offersToAllow = 0)
        assertCrashed(d)
        val reopened = reopenEstate()
        reopened.makeNode(s.opener); reopened.makeNode(s.responder)
        val n = reopened.nodeOf(s.opener)
        val result = runBlocking {
            n.node.dispatchDirect(d.frame, expectedRecipient = reopened.nodeOf(s.responder).identity.nodeId) { _, _ -> false }
        }
        assertEquals(
            "*** a re-dispatch of the SAME frame must resume the SAME intent, not mint a second ***",
            io.godstone.mesh.DirectDispatchResult.QueuedLocally, result,
        )
        assertEquals("and no second held row was authored", 1, reopened.heldMsgIds(s.opener).size)
    }

    // ---------------------------------------------------------------- W05

    /**
     * W05 -- A CRASH AT THE INBOX'S `"signing"` SEAM: THE HELD ROW AND THE OBLIGATION SURVIVE, NO ACK WAS ISSUED.
     */
    @Test
    fun test_w05_theSigningCrashLeavesTheHeldRowAndObligationWithoutAnAck() {
        val s = establish()
        val frame = rig!!.authorDirectFrame(s.opener, s.responder, plaintext("w05"))
        val before = heldCount(s.responder)
        val inj = ingestCrashing(s.responder, frame, s.opener, "signing")
        assertCrash(inj, "signing")
        assertTrue("*** the T83 commit that PRECEDED the signing really committed the frame ***", heldCount(s.responder) == before + 1)
        assertEquals("*** and its obligation row stands PENDING ***", 1, pendingObligations(s.responder))
        assertEquals("*** no canonical ACK was ever signed ***", 0, ackRows(s.responder, frame.msgId))
        assertEquals("*** the inbox census agreeth: nothing was issued ***", 0, rig!!.inboxCensus(s.responder)!!.acksIssued)
        assertEquals("and no ACK reached the outbox", 0, rig!!.ackOutboxDepth(s.responder))
    }

    // ---------------------------------------------------------------- W06

    /**
     * W06 -- THE RECOVERY: A FRESH COMPOSITION RESUMES THE DELIVERY AND PRODUCES THE ONE CANONICAL ACK.
     *
     * *The resumed composition re-ingests the SAME sealed frame through its own inbox; the held row is a duplicate,
     * the pending obligation is settled by the signing road, and exactly ONE `ack_frames` row is filed -- the
     * obligation the crash left PENDING is the durable record that resumeth it.*
     */
    @Test
    fun test_w06_aFreshCompositionResumesTheSigningCrashAndIssuesTheCanonicalAck() {
        val s = establish()
        val frame = rig!!.authorDirectFrame(s.opener, s.responder, plaintext("w06"))
        assertCrash(ingestCrashing(s.responder, frame, s.opener, "signing"), "signing")
        val reopened = reopenEstate()
        reopened.makeNode(s.opener); reopened.makeNode(s.responder)
        val resumed = ingestClean(s.responder, frame, s.opener)
        assertTrue(
            "*** the resumed ingest must settle the obligation's pair (observed $resumed) ***",
            resumed is InboxCommitResult.Duplicate,
        )
        assertEquals("*** and file exactly ONE canonical ACK row ***", 1, ackRows(s.responder, frame.msgId))
        // *** AND A SECOND RESUME IS IDEMPOTENT: the durable row's own bytes answer it, no second row appears. ***
        val again = ingestClean(s.responder, frame, s.opener)
        assertTrue("a repeated resume is a Duplicate (observed $again)", again is InboxCommitResult.Duplicate)
        assertEquals("*** and it files NO second ACK row ***", 1, ackRows(s.responder, frame.msgId))
        assertEquals(
            "and the held row was not duplicated",
            1, reopened.heldMsgIds(s.responder).count { it.contentEquals(frame.msgId) },
        )
    }

    // ---------------------------------------------------------------- W07

    /** W07 -- A CRASH AT THE INBOX'S `"frame_insert"` SEAM: SIGNED, BUT NEVER FILED. */
    @Test
    fun test_w07_theFrameInsertCrashLeavesTheObligationPendingAndNoAckRow() {
        val s = establish()
        val frame = rig!!.authorDirectFrame(s.opener, s.responder, plaintext("w07"))
        assertCrash(ingestCrashing(s.responder, frame, s.opener, "frame_insert"), "frame_insert")
        assertHeld(s.responder, frame.msgId)
        assertEquals("*** the obligation stays PENDING for the bounded worker ***", 1, pendingObligations(s.responder))
        assertEquals("*** and the ack_frames row was never filed ***", 0, ackRows(s.responder, frame.msgId))
        assertEquals("no ACK was censused as issued", 0, rig!!.inboxCensus(s.responder)!!.acksIssued)
    }

    // ---------------------------------------------------------------- W08

    /** W08 -- THE RECOVERY FROM `"frame_insert"`: THE OBLIGATION IS RETIRED AND THE ACK FILED. */
    @Test
    fun test_w08_aFreshCompositionRetiresTheFrameInsertObligationAndFilesTheAck() {
        val s = establish()
        val frame = rig!!.authorDirectFrame(s.opener, s.responder, plaintext("w08"))
        assertCrash(ingestCrashing(s.responder, frame, s.opener, "frame_insert"), "frame_insert")
        val reopened = reopenEstate()
        reopened.makeNode(s.opener); reopened.makeNode(s.responder)
        val resumed = ingestClean(s.responder, frame, s.opener)
        assertTrue("the resumed ingest settles the pair (observed $resumed)", resumed is InboxCommitResult.Duplicate)
        assertEquals("*** exactly one canonical ACK row now stands ***", 1, ackRows(s.responder, frame.msgId))
        assertEquals("and the resumed ingest censused the issue", 1, reopened.inboxCensus(s.responder)!!.acksIssued)
    }

    // ---------------------------------------------------------------- W09

    /**
     * W09 -- A CRASH INSIDE THE INBOUND TRANSACTION (the store's `"obligation"` seam): BOTH-OR-NEITHER.
     *
     * *A throw here rolls the WHOLE transaction back, so the held row and the obligation are BOTH absent -- the law
     * that no held frame may stand without its row is proven from the absence side.*
     */
    @Test
    fun test_w09_aCrashInsideTheInboundTransactionRollsBackBothRows() {
        val s = establish()
        val frame = rig!!.authorDirectFrame(s.opener, s.responder, plaintext("w09"))
        val n = rig!!.nodeOf(s.responder)
        val before = heldCount(s.responder)
        var crash: WorkerCrash? = null
        val outcome = runBlocking {
            (n.messageStore as SqliteMessageStore).commitInboundWithObligationAtWithFault(
                frame = frame,
                receivedFrom = rig!!.nodeOf(s.opener).identity.nodeId,
                localRecipientNodeId = n.identity.nodeId,
                identityGeneration = 1L,
                obligationLifetimeMs = 60_000L,
                receivedAt = System.currentTimeMillis(),
            ) { seam -> if (seam == "obligation") throw WorkerCrash("store:obligation").also { crash = it } }
        }
        assertEquals("*** a throw at the store seam is reported as the protocol's own StorageFailure ***",
            io.godstone.mesh.delivery.InboundCommitResult.StorageFailure, outcome)
        assertEquals("the injected failure really landed", true, crash != null)
        assertEquals("*** NO held row may survive the rolled-back commit ***", before, heldCount(s.responder))
        assertEquals("*** and NO obligation may survive it either ***", 0, pendingObligations(s.responder))
        assertEquals("nor any ACK row", 0, ackRows(s.responder, frame.msgId))
    }

    // ---------------------------------------------------------------- W10

    /**
     * W10 -- A RADIO-LEG CRASH IS NOT A DISCONNECT: THE ESTABLISHED RELATION AND THE PEER VIEW STAND.
     *
     * *This is the boundary the crash harness must not blur: an injected failure in ONE send's radio leg must not
     * tear down the trusted session, the publication ledger, or the route-eligible view -- only a real platform
     * disconnect (see [RealChannelCrashScenarioTest]) may do that.*
     */
    @Test
    fun test_w10_aRadioLegCrashLeavesTheEstablishedRelationStanding() {
        val s = establish()
        assertCrashed(dispatchCrashing(s.opener, s.responder, plaintext("w10"), "kill", offersToAllow = 0))
        assertTrue("*** the trusted session SURVIVES a single send's crash ***", s.openerReady())
        assertTrue("and the responder's side too", s.responderReady())
        assertTrue(
            "*** and the relation stayeth published on the opener ***",
            anyRelationPublished(s.opener, io.godstone.mesh.transport.BleDirection.OUTBOUND, s.openerHandle),
        )
        assertTrue("*** so a LATER send still hands to the live relay ***",
            rig!!.waitUntil {
                val r = directDispatchResult(s.opener, s.responder, plaintext("w10b"))
                r is io.godstone.mesh.DirectDispatchResult.HandedToRelays
            },
        )
    }
}
