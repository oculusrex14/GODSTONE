package io.godstone.mesh.readiness

// T39 readiness court (android isle) -- the twin of ReadinessT39Tests.swift.
//
// One durable authority for the SOS broadcast lifecycle (section 14): the held
// frame and its NONE-mode delivery row commit together or not at all; the
// Active-SOS projection is read FROM the durable row, never from a UI memory;
// cancel moves the row terminal and retires the held work transactionally and
// tells the truth about copies already relayed; retry resumes the SAME
// authored bytes. The card's named behavioral cases are the witnesses:
// enqueue second-write failure (W1), restart with an active SOS (W2), cancel
// versus the queued writer (W3), relay already sent (W4), duplicate
// cancellation (W5), and NONE-mode ACK rejection (W6) -- plus the same-bytes
// law of retry (W7), the command-surface routing (W8), the one-authority
// census (W9), the no-torn-pair campaign (W10), and the flag-truth witness
// (W11). The named semantic negative -- "cancel only clears the UI flag" --
// dies on W2/W3/W4/W10/W11 together: they read the tables, not the flag.
//
// The court drives the durable route (the store-backed repository overriding
// enqueueSosOutbound) exactly as the composition root wires it in production
// (the shared SQL engine is that route's sibling); the compatible two-step
// route for plain journals is the sealed T24/T38 observables' road, proven by
// MeshNodeDeliveryIntegrationTest and ReadinessT38Test standing unchanged.

import io.godstone.core.crypto.Ed25519Keys
import io.godstone.core.crypto.X25519Keys
import io.godstone.mesh.ActiveSos
import io.godstone.mesh.MeshNode
import io.godstone.mesh.SosCancelResult
import io.godstone.mesh.SosCommand
import io.godstone.mesh.SosCommandResult
import io.godstone.mesh.SosDispatchResult
import io.godstone.mesh.delivery.AckAuthenticator
import io.godstone.mesh.delivery.AckFrame
import io.godstone.mesh.delivery.AckMode
import io.godstone.mesh.delivery.AckResult
import io.godstone.mesh.delivery.ClearResult
import io.godstone.mesh.delivery.DeliveryLookup
import io.godstone.mesh.delivery.DeliveryRepository
import io.godstone.mesh.delivery.DeliveryState
import io.godstone.mesh.delivery.DeliveryTracker
import io.godstone.mesh.delivery.DeliveryTransition
import io.godstone.mesh.delivery.EnqueueResult
import io.godstone.mesh.delivery.InMemoryStoreDeliveryRepository
import io.godstone.mesh.delivery.TransitionResult
import io.godstone.mesh.identity.Identity
import io.godstone.mesh.store.InMemoryMessageStore
import io.godstone.mesh.store.OutboundEnqueueResult
import io.godstone.mesh.store.PersistResult
import io.godstone.mesh.wire.v2.FrameV2
import io.godstone.mesh.wire.v2.TypeV2
import java.security.SecureRandom
import kotlinx.coroutines.test.runTest
import org.junit.Assert
import org.junit.Test

class ReadinessT39Test {

    // ------------------------------------------------------------------ fixtures

    private fun newIdentity(): Identity {
        val rng = SecureRandom()
        val ed = Ed25519Keys.generate(rng)
        val dh = X25519Keys.generate(rng)
        return Identity.fromKeyMaterial(ed.pub, ed.priv, dh.pub, dh.priv)
    }

    private fun peerOf(seedByte: Int): ByteArray =
        ByteArray(16) { ((seedByte * 31 + it) and 0xFF).toByte() }

    private fun sosFrame(
        msgId: ByteArray,
        flags: Int = FrameV2.ACK_REQ or FrameV2.RELAY_OK,
        type: TypeV2 = TypeV2.SOS,
        tag: ByteArray = ByteArray(4),
        payload: ByteArray = ByteArray(200) { (it % 251).toByte() },
    ): FrameV2 = FrameV2(type, msgId, tag, 4, 0, flags, payload)

    private class RecordingAuthenticator : AckAuthenticator {
        var calls = 0
        override fun verify(
            originalMsgId: ByteArray,
            expectedRecipientNodeId: ByteArray,
            ackFrame: FrameV2,
        ): Boolean {
            calls++
            return true // would accept -- the witnesses assert it is never consulted
        }
    }

    /** The durable route as the composition root walks it: the store-backed
     *  repository owns BOTH tables through the store's one monitor. The
     *  counters prove the two-step road was never taken; the named fault seam
     *  reproduces the second-write failure the card names. */
    private class AuthorityRepository(
        private val store: InMemoryMessageStore,
        private val failAt: String? = null,
    ) : DeliveryRepository {
        var pairCommitCalls = 0
        var persistClosuresInvoked = 0
        private val inner = InMemoryStoreDeliveryRepository(store)

        override fun get(msgId: ByteArray): DeliveryLookup = inner.get(msgId)
        override fun enqueue(
            msgId: ByteArray,
            ackMode: AckMode,
            expectedRecipient: ByteArray?,
        ): EnqueueResult = inner.enqueue(msgId, ackMode, expectedRecipient)
        override fun transition(msgId: ByteArray, transition: DeliveryTransition): TransitionResult =
            inner.transition(msgId, transition)
        override fun acknowledgeBoundAndRetire(msgId: ByteArray, expectedRecipient: ByteArray): AckResult =
            inner.acknowledgeBoundAndRetire(msgId, expectedRecipient)
        override fun clear(msgId: ByteArray): ClearResult = inner.clear(msgId)

        override suspend fun enqueueSosOutbound(
            frame: FrameV2,
            localOriginNodeId: ByteArray,
            persist: suspend () -> PersistResult,
        ): OutboundEnqueueResult {
            pairCommitCalls++
            val guarded: suspend () -> PersistResult = {
                persistClosuresInvoked++
                persist()
            }
            val fault: ((String) -> Unit)? = failAt?.let { point ->
                { name -> if (name == point) throw IllegalStateException("injected second-write failure at " + name) }
            }
            return if (fault == null) {
                inner.enqueueSosOutbound(frame, localOriginNodeId, guarded)
            } else {
                store.enqueueSosOutboundAtWithFault(
                    frame, localOriginNodeId, System.currentTimeMillis(), fault,
                )
            }
        }
    }

    private class Rig(
        val store: InMemoryMessageStore,
        val tracker: DeliveryTracker,
        val node: MeshNode,
        val auth: RecordingAuthenticator,
    )

    private fun newRig(failAt: String? = null): Rig {
        val store = InMemoryMessageStore()
        val auth = RecordingAuthenticator()
        val tracker = DeliveryTracker(AuthorityRepository(store, failAt), auth)
        val node = MeshNode(
            ctx = null,
            identity = newIdentity(),
            store = store,
            deliveryTracker = tracker,
        )
        return Rig(store, tracker, node, auth)
    }

    private fun heldIdsOf(store: InMemoryMessageStore): List<ByteArray> {
        var out: List<ByteArray> = emptyList()
        runTest { out = store.allHeldMsgIds() }
        return out
    }

    private fun firstHeldFrame(store: InMemoryMessageStore): FrameV2 {
        var out: FrameV2? = null
        runTest { out = store.allHeldOrderedByPriority().first() }
        val f = out
        Assert.assertNotNull("a held frame must stand", f)
        return f!!
    }

    private fun rowOf(tracker: DeliveryTracker, msgId: ByteArray): DeliveryLookup =
        tracker.lookup(msgId)

    /** Dispatch once on a fresh rig and return (msg_id, result) -- both read
     *  back FROM the durable tables, the authority as the oracle. */
    private fun authorOnce(r: Rig, payload: ByteArray, peers: Int): Pair<ByteArray, SosDispatchResult> {
        for (i in 0 until peers) r.node.injectPeerForTest(peerOf(i + 1))
        var result: SosDispatchResult = SosDispatchResult.Failed("the dispatch never ran")
        runTest { result = r.node.dispatchSos(payload) { _, _ -> true } }
        Assert.assertEquals("dispatch must commit exactly one held frame", 1, heldIdsOf(r.store).size)
        return Pair(firstHeldFrame(r.store).msgId.copyOf(), result)
    }

    // ------------------------------------------------------------------ W1 second-write failure

    /** W1 -- the card's "enqueue second-write failure": when the delivery row
     *  cannot be written, the held frame written moments before is taken back.
     *  Neither table keeps a trace of the half-commit, and the failure is
     *  reported (NotPersisted), never fabled as an empty success. Every named
     *  fault seam is probed at the authority, and once through the node. */
    @Test
    fun testEnqueueSecondWriteFailureRollsTheWholePairBack() {
        val mid = ByteArray(16) { (it + 1).toByte() }
        for (seam in listOf(
            "before_held_insert", "after_held_insert",
            "before_delivery_insert", "after_delivery_insert",
        )) {
            val store = InMemoryMessageStore()
            var outcome: OutboundEnqueueResult? = null
            runTest {
                outcome = store.enqueueSosOutboundAtWithFault(sosFrame(mid), ByteArray(16) { 7 }, 0L) { name ->
                    if (name == seam) throw IllegalStateException("injected failure at " + name)
                }
            }
            Assert.assertTrue("seam " + seam + " must yield StorageFailure, got " + outcome,
                outcome is OutboundEnqueueResult.StorageFailure)
            Assert.assertEquals("seam " + seam + " left a held orphan -- the pair must not half-commit",
                0, heldIdsOf(store).size)
            val freshTracker = DeliveryTracker(InMemoryStoreDeliveryRepository(store), RecordingAuthenticator())
            Assert.assertTrue("seam " + seam + " left a delivery row without its frame",
                freshTracker.lookup(mid) is DeliveryLookup.NotFound)
        }
        // Through the node: the same injected second-write failure surfaces as
        // NotPersisted and no table moves -- and the control distinguishes it
        // from an idempotent no-op.
        val r = newRig(failAt = "before_delivery_insert")
        var failed: SosDispatchResult = SosDispatchResult.Failed("never ran")
        runTest { failed = r.node.dispatchSos("hold the line".toByteArray()) { _, _ -> true } }
        Assert.assertTrue("node route must report NotPersisted, got " + failed,
            failed is SosDispatchResult.NotPersisted)
        Assert.assertEquals("no held frame may survive the rolled-back pair", 0, heldIdsOf(r.store).size)
        val ok = newRig()
        var good: SosDispatchResult = SosDispatchResult.Failed("never ran")
        runTest { good = ok.node.dispatchSos("hold the line".toByteArray()) { _, _ -> true } }
        Assert.assertTrue("the control must commit: " + good, good is SosDispatchResult.QueuedLocally)
        Assert.assertEquals("the control holds exactly one frame", 1, heldIdsOf(ok.store).size)
    }

    // ------------------------------------------------------------------ W2 restart

    /** W2 -- "restart with active SOS": a second node over the same durable
     *  tables re-exposes the call FROM THE ROW and can cancel it truthfully,
     *  learning it had been relayed. A UI-memory flag could never do this. */
    @Test
    fun testRestartRevealsTheActiveSosFromTheDurableRow() {
        val r = newRig()
        val (mid, dispatched) = authorOnce(r, "medic".toByteArray(), peers = 2)
        Assert.assertTrue("two relays must have taken the frame: " + dispatched,
            dispatched is SosDispatchResult.HandedToRelays && dispatched.count == 2)
        val before = rowOf(r.tracker, mid)
        Assert.assertTrue("the row must stand handed",
            before is DeliveryLookup.Found && before.record.state == DeliveryState.HANDED_TO_RELAY)
        val node2 = MeshNode(
            ctx = null,
            identity = newIdentity(),
            store = r.store,
            deliveryTracker = DeliveryTracker(InMemoryStoreDeliveryRepository(r.store), RecordingAuthenticator()),
        )
        Assert.assertFalse("a cold node must not claim an active SOS from thin air", node2.hasActiveSos())
        var seen: ActiveSos? = null
        runTest { seen = node2.refreshSosStatusAfterScan() }
        val projection = seen
        Assert.assertNotNull("the durable row must re-expose the active call after restart", projection)
        Assert.assertTrue("the projection must name the same msg_id", projection!!.msgId.contentEquals(mid))
        Assert.assertEquals("the restarted projection must read the durable state",
            DeliveryState.HANDED_TO_RELAY, projection.state)
        val stillHeld = firstHeldFrame(r.store)
        Assert.assertTrue("the restarted projection carries the held frame verbatim",
            projection.frame.encode().contentEquals(stillHeld.encode()))
        Assert.assertTrue("the flag must follow the row after the scan", node2.hasActiveSos())
        var cancelled: SosCancelResult? = null
        runTest { cancelled = node2.cancelSos(mid) }
        val restartCancel = cancelled
        Assert.assertTrue("the restart's cancel must know it was relayed: " + restartCancel,
            restartCancel is SosCancelResult.Cancelled && restartCancel.wasRelayed)
    }

    // ------------------------------------------------------------------ W3 cancel versus the queued writer

    /** W3 -- "cancel versus queued writer": a cancellation that lands while a
     *  relay hand is in flight must not be resurrected by the writer's
     *  mark-handed follow. The bytes that left cannot be recalled -- the
     *  result says so -- and the row stays terminal. */
    @Test
    fun testCancelVersusQueuedWriterNeverResurrects() {
        val r = newRig()
        val mid = ByteArray(16) { (it * 3 + 1).toByte() }
        // commit the pair through the durable authority first (deterministic mid)
        var commit: OutboundEnqueueResult? = null
        runTest {
            commit = r.store.enqueueSosOutboundAtWithFault(sosFrame(mid), ByteArray(16) { 7 }, 0L, null)
        }
        Assert.assertTrue("authority commit must succeed: " + commit, commit is OutboundEnqueueResult.Created)
        r.node.injectPeerForTest(peerOf(9))
        var cancelledDuring = false
        var result: SosDispatchResult = SosDispatchResult.Failed("never ran")
        runTest {
            result = r.node.retrySos(mid) { _, _ ->
                // the cancellation lands while this hand is carrying the bytes
                val c = r.node.cancelSos(mid)
                cancelledDuring = c is SosCancelResult.Cancelled && !c.wasRelayed
                true
            }
        }
        val outcome = result
        Assert.assertTrue("the bytes did go out before the cancel was known: " + outcome,
            outcome is SosDispatchResult.HandedToRelays && outcome.count == 1)
        Assert.assertTrue("the mid-flight cancel must have moved the row", cancelledDuring)
        val l = rowOf(r.tracker, mid)
        Assert.assertTrue("the writer's mark-handed follow must not resurrect the row",
            l is DeliveryLookup.Found && l.record.state == DeliveryState.CANCELLED_LOCALLY)
        Assert.assertEquals("the cancel retired the held work", 0, heldIdsOf(r.store).size)
        Assert.assertFalse("no active SOS may be claimed once the row is terminal", r.node.hasActiveSos())
    }

    // ------------------------------------------------------------------ W4 relay already sent

    /** W4 -- "relay already sent": cancellation of a call whose bytes left
     *  reports the truth (wasRelayed) so the UI can say already relayed
     *  copies cannot be recalled, and retires the local work in one move. */
    @Test
    fun testCancelOfARelayedCallTellsTheRelayedTruth() {
        val r = newRig()
        val (mid, dispatched) = authorOnce(r, "priority one".toByteArray(), peers = 2)
        Assert.assertTrue("must have handed to two relays: " + dispatched,
            dispatched is SosDispatchResult.HandedToRelays && dispatched.count == 2)
        var cancelled: SosCancelResult? = null
        runTest { cancelled = r.node.cancelSos(mid) }
        val moved = cancelled
        Assert.assertTrue("the result must tell the UI the copies are out: " + moved,
            moved is SosCancelResult.Cancelled && moved.wasRelayed)
        Assert.assertEquals("the held frame must be retired with the row", 0, heldIdsOf(r.store).size)
        Assert.assertFalse(r.node.hasActiveSos())
    }

    // ------------------------------------------------------------------ W5 duplicate cancellation

    /** W5 -- "duplicate cancellation" is idempotent, never an error: the first
     *  cancellation moves the pair; every later one names the same terminal
     *  truth and touches nothing. */
    @Test
    fun testDuplicateCancellationIsIdempotentNotAnError() {
        val r = newRig()
        val (mid, dispatched) = authorOnce(r, "again and again".toByteArray(), peers = 0)
        Assert.assertTrue("queued with no relays in sight: " + dispatched,
            dispatched is SosDispatchResult.QueuedLocally)
        var first: SosCancelResult? = null
        runTest { first = r.node.cancelSos(mid) }
        val firstMove = first
        Assert.assertTrue("the first cancel moves the pair: " + firstMove,
            firstMove is SosCancelResult.Cancelled && !firstMove.wasRelayed)
        var second: SosCancelResult? = null
        runTest { second = r.node.cancelSos(mid) }
        val dup = second
        Assert.assertTrue("the duplicate must be the idempotent no-op: " + dup,
            dup is SosCancelResult.AlreadyCancelled && dup.wasRelayed == null)
        var third: SosCancelResult? = null
        runTest { third = r.node.cancelSos(mid) }
        val triple = third
        Assert.assertTrue("and stay so: " + triple,
            triple is SosCancelResult.AlreadyCancelled && triple.wasRelayed == null)
        val l = rowOf(r.tracker, mid)
        Assert.assertTrue("the row stays terminal throughout",
            l is DeliveryLookup.Found && l.record.state == DeliveryState.CANCELLED_LOCALLY)
        Assert.assertEquals("and the held frame stays gone", 0, heldIdsOf(r.store).size)
    }

    // ------------------------------------------------------------------ W6 NONE-mode ACK rejection

    /** W6 -- "NONE-mode ACK rejection": a broadcast call is not addressed to
     *  anybody, so no authenticated ACK of it exists. A correctly signed ACK
     *  for the msg_id is refused at the mode gate BEFORE any cryptography --
     *  the authenticator must never be consulted -- and the row, the frame
     *  and the flag all stand as they were. */
    @Test
    fun testNoneModeAckIsRejectedBeforeCryptography() {
        val r = newRig()
        val (mid, dispatched) = authorOnce(r, "no recipient".toByteArray(), peers = 1)
        Assert.assertTrue("one relay took it: " + dispatched, dispatched is SosDispatchResult.HandedToRelays)
        val rng = SecureRandom()
        val recipient = Ed25519Keys.generate(rng)
        val ack = AckFrame.build(mid, recipient.priv, ByteArray(16) { (it + 0x40).toByte() }, ByteArray(4) { 3 })
        var accepted = true
        runTest { accepted = r.node.ingestInbound(ack, peerOf(1)) }
        Assert.assertFalse("a NONE-mode call has no recipient that could acknowledge it", accepted)
        Assert.assertEquals("the authenticator must never have been consulted", 0, r.auth.calls)
        Assert.assertTrue("the direct tracker path must return NotAckEligible",
            r.tracker.acknowledge(mid, ack) is AckResult.NotAckEligible)
        val l = rowOf(r.tracker, mid)
        Assert.assertTrue("the row must stand as it was",
            l is DeliveryLookup.Found && l.record.state == DeliveryState.HANDED_TO_RELAY &&
                l.record.ackMode == AckMode.NONE)
        Assert.assertEquals("the held frame must stand as it was", 1, heldIdsOf(r.store).size)
        Assert.assertTrue("and the projection must still say active", r.node.hasActiveSos())
    }

    // ------------------------------------------------------------------ W7 retry resumes the same bytes

    /** W7 -- "Retry resumes the same authored SOS bytes": the resume re-sends
     *  the held frame verbatim (byte-identical to the first hand-offs), the
     *  row stays handed, and the unknown or terminal cases FAIL typed -- they
     *  never masquerade as empty successes. */
    @Test
    fun testRetryResumesTheSameAuthoredBytesAndFailsTyped() {
        val r = newRig()
        r.node.injectPeerForTest(peerOf(1))
        r.node.injectPeerForTest(peerOf(2))
        val firstHand = ArrayList<ByteArray>()
        runTest { r.node.dispatchSos("same bytes please".toByteArray()) { _, bytes -> firstHand.add(bytes.copyOf()); true } }
        Assert.assertEquals("two hands, two captures", 2, firstHand.size)
        val mid = firstHeldFrame(r.store).msgId.copyOf()
        val again = ArrayList<ByteArray>()
        var retried: SosDispatchResult = SosDispatchResult.Failed("never ran")
        runTest { retried = r.node.retrySos(mid) { _, bytes -> again.add(bytes.copyOf()); true } }
        val resume = retried
        Assert.assertTrue("the resume must hand the same count: " + resume,
            resume is SosDispatchResult.HandedToRelays && resume.count == 2)
        Assert.assertTrue("the bytes must be verbatim, not re-authored",
            again[0].contentEquals(firstHand[0]) && again[1].contentEquals(firstHand[1]))
        val l = rowOf(r.tracker, mid)
        Assert.assertTrue("the row stays handed (idempotent target)",
            l is DeliveryLookup.Found && l.record.state == DeliveryState.HANDED_TO_RELAY)
        // unknown msg_id: failure, not an empty success
        val stranger = ByteArray(16) { (it + 0x77).toByte() }
        var sends = 0
        var unknown: SosDispatchResult = SosDispatchResult.Failed("never ran")
        runTest { unknown = r.node.retrySos(stranger) { _, _ -> sends++; true } }
        Assert.assertTrue("an unknown msg_id must fail typed: " + unknown, unknown is SosDispatchResult.Failed)
        val unknownReason = (unknown as SosDispatchResult.Failed).reason
        Assert.assertTrue("and its reason must name itself: " + unknownReason,
            unknownReason.contains("no durable row"))
        Assert.assertEquals("no bytes may go out for a stranger", 0, sends)
        // terminal row: the resume is refused, no resurrection
        runTest { r.node.cancelSos(mid) }
        var afterCancel: SosDispatchResult = SosDispatchResult.Failed("never ran")
        runTest { afterCancel = r.node.retrySos(mid) { _, _ -> sends++; true } }
        Assert.assertTrue("a cancelled call must not be resumed: " + afterCancel,
            afterCancel is SosDispatchResult.Failed)
        Assert.assertEquals("and no bytes may go out for it either", 0, sends)
    }

    // ------------------------------------------------------------------ W8 the command surface

    /** W8 -- SosCommand.Author/Retry/Cancel route through one door and each
     *  returns the honest result of its arm: authoring enqueues durably,
     *  cancelling retires durably, retrying resumes; no arm reports a success
     *  the tables do not show. */
    @Test
    fun testCommandSurfaceRoutesEveryArmToTheDurableTruth() {
        val r = newRig()
        r.node.injectPeerForTest(peerOf(1))
        var authored: SosCommandResult? = null
        runTest { authored = r.node.handleSosCommand(SosCommand.Author("command one".toByteArray())) { _, _ -> true } }
        val authoring = authored
        Assert.assertTrue("author must enqueue durably: " + authoring,
            authoring is SosCommandResult.Enqueued && authoring.dispatch is SosDispatchResult.HandedToRelays)
        val mid = firstHeldFrame(r.store).msgId.copyOf()
        var cancelled: SosCommandResult? = null
        runTest { cancelled = r.node.handleSosCommand(SosCommand.Cancel(mid)) { _, _ -> true } }
        val cancelling = cancelled
        Assert.assertTrue("cancel must report its durable result: " + cancelling,
            cancelling is SosCommandResult.Cancelled && cancelling.cancel is SosCancelResult.Cancelled)
        // a fresh author, then the retry arm resumes the same bytes
        val r2 = newRig()
        var authored2: SosCommandResult? = null
        runTest { authored2 = r2.node.handleSosCommand(SosCommand.Author("command two".toByteArray())) { _, _ -> true } }
        Assert.assertTrue("author again: " + authored2, authored2 is SosCommandResult.Enqueued)
        val mid2 = firstHeldFrame(r2.store).msgId.copyOf()
        r2.node.injectPeerForTest(peerOf(1))
        var retried: SosCommandResult? = null
        runTest { retried = r2.node.handleSosCommand(SosCommand.Retry(mid2)) { _, _ -> true } }
        val resuming = retried
        Assert.assertTrue("retry must reach the resume arm: " + resuming,
            resuming is SosCommandResult.Enqueued && resuming.dispatch is SosDispatchResult.HandedToRelays)
        // content-based identity of the commands: duplicate logical records are
        // the same command (and a distinct one is distinct)
        Assert.assertTrue("same bytes, same command",
            SosCommand.Retry(mid2) == SosCommand.Retry(mid2.copyOf()) &&
                SosCommand.Retry(mid2) != SosCommand.Retry(mid))
    }

    // ------------------------------------------------------------------ W9 the one authority

    /** W9 -- the broadcast pair-commit is ONE call on the authority that owns
     *  both tables: the compatible persist closure must never be invoked on
     *  this route, and what the row names (mode NONE, no recipient, queued)
     *  is what the tables hold. */
    @Test
    fun testTheBroadcastPairIsCommittedByOneAuthorityCall() {
        val store = InMemoryMessageStore()
        val repo = AuthorityRepository(store, null)
        val auth = RecordingAuthenticator()
        val tracker = DeliveryTracker(repo, auth)
        val node = MeshNode(ctx = null, identity = newIdentity(), store = store, deliveryTracker = tracker)
        runTest { node.dispatchSos("one door".toByteArray()) { _, _ -> true } }
        Assert.assertEquals("exactly one authority call must commit the broadcast pair", 1, repo.pairCommitCalls)
        Assert.assertEquals("the two-step route must never be walked here", 0, repo.persistClosuresInvoked)
        val frame = firstHeldFrame(store)
        val l = tracker.lookup(frame.msgId)
        Assert.assertTrue("the row must be found", l is DeliveryLookup.Found)
        val rec = (l as DeliveryLookup.Found).record
        Assert.assertEquals("the mode must be NONE", AckMode.NONE, rec.ackMode)
        Assert.assertNull("and name no recipient", rec.expectedRecipientNodeId)
        Assert.assertEquals("and stand queued durably", DeliveryState.QUEUED_DURABLY, rec.state)
        // frames that are not well-formed distress calls are refused BEFORE any
        // write: the type octet, the required flag bits, and the fixed widths
        // are policy, not hope
        val strays = listOf(
            sosFrame(ByteArray(16) { 1 }, type = TypeV2.MESSAGE),
            sosFrame(ByteArray(16) { 2 }, flags = FrameV2.ACK_REQ),
            sosFrame(ByteArray(15) { 3 }),
            sosFrame(ByteArray(16) { 4 }, tag = ByteArray(3)),
        )
        for (stray in strays) {
            var rejected: OutboundEnqueueResult? = null
            runTest {
                rejected = store.enqueueSosOutboundAtWithFault(stray, ByteArray(16) { 7 }, 0L, null)
            }
            Assert.assertTrue("policy must refuse a stray (" + stray.type + ", " + stray.flags +
                ", " + stray.msgId.size + "/" + stray.routingTag.size + ") with InvalidArgument, got " + rejected,
                rejected is OutboundEnqueueResult.InvalidArgument)
        }
        Assert.assertEquals("and none of the strays may leave a trace", 1, heldIdsOf(store).size)
    }

    // ------------------------------------------------------------------ W10 no torn pair

    /** W10 -- the campaign: authoring, cancelling (some twice), and retrying
     *  in interleave; after EVERY step the cross-table invariant holds --
     *  a held frame iff its live row, a terminal row iff its frame gone. The
     *  torn pair this task was named for becomes unnameable. */
    @Test
    fun testNoTornPairEverAcrossTheInterleavedCampaign() {
        val r = newRig()
        val mids = ArrayList<ByteArray>()
        fun invariant(step: String) {
            val held = HashSet(heldIdsOf(r.store).map { it.toList() })
            for (mid in mids) {
                val l = rowOf(r.tracker, mid)
                val isHeld = held.contains(mid.toList())
                when (l) {
                    is DeliveryLookup.Found -> {
                        val live = l.record.state == DeliveryState.QUEUED_DURABLY ||
                            l.record.state == DeliveryState.HANDED_TO_RELAY
                        Assert.assertTrue("torn pair at " + step + ": live row " + l.record.state +
                            " without its frame (or a frame without its row)", live == isHeld)
                    }
                    DeliveryLookup.NotFound ->
                        Assert.assertFalse("torn pair at " + step + ": frame without its row", isHeld)
                    DeliveryLookup.Corrupt, DeliveryLookup.StorageFailure, DeliveryLookup.InvalidArgument ->
                        Assert.fail("the durable rows must read sound at " + step + ", got " + l)
                }
            }
        }
        // step: author four calls, two of them relayed
        for (i in 0 until 4) {
            if (i < 2) r.node.injectPeerForTest(peerOf(i + 1))
            val before = HashSet(heldIdsOf(r.store).map { it.toList() })
            runTest { r.node.dispatchSos(("campaign " + i).toByteArray()) { _, _ -> true } }
            val fresh = heldIdsOf(r.store).first { !before.contains(it.toList()) }
            mids.add(fresh.copyOf())
            invariant("author " + i)
        }
        // step: cancel the first two -- and the first twice more (idempotence)
        for (k in listOf(0, 1, 0)) {
            runTest { r.node.cancelSos(mids[k]) }
            invariant("cancel " + k)
        }
        // step: retry the last one (live) and a cancelled one (refused, still no tear)
        runTest { r.node.retrySos(mids[3]) { _, _ -> true } }
        invariant("retry live")
        runTest { r.node.retrySos(mids[0]) { _, _ -> true } }
        invariant("retry cancelled")
        val liveCount = mids.count { k ->
            val l = rowOf(r.tracker, k)
            l is DeliveryLookup.Found &&
                (l.record.state == DeliveryState.QUEUED_DURABLY || l.record.state == DeliveryState.HANDED_TO_RELAY)
        }
        Assert.assertEquals("exactly the two uncanceled calls must remain live", 2, liveCount)
        Assert.assertEquals("and exactly those two must still be held", 2, heldIdsOf(r.store).size)
    }

    // ------------------------------------------------------------------ W11 the flag only ever follows

    /** W11 -- the observable flag is a faithful mirror, no more: it lights
     *  when the durable row stands and goes when the row is terminal, and a
     *  rogue call that once spent the flag freely (the pre-T39
     *  onSosAcknowledgedByRecipient) can no longer make it lie -- the row is
     *  live, so the flag stays true. */
    @Test
    fun testTheFlagOnlyEverSaysWhatTheDurableRowSays() {
        val r = newRig()
        Assert.assertFalse("before any authoring the mirror is dark", r.node.hasActiveSos())
        val (mid, _) = authorOnce(r, "mirror".toByteArray(), peers = 1)
        Assert.assertTrue("with a live row the mirror shines", r.node.hasActiveSos())
        // the rogue hand: a NONE-mode call has no recipient; an un-tethered
        // "recipient acknowledged" notification must not spend the flag
        r.node.onSosAcknowledgedByRecipient()
        Assert.assertTrue("while the row lives, the flag may not be cleared by a mere call",
            r.node.hasActiveSos())
        var cancelled: SosCancelResult? = null
        runTest { cancelled = r.node.cancelSos(mid) }
        Assert.assertTrue("the durable cancel moved the pair: " + cancelled,
            cancelled is SosCancelResult.Cancelled)
        Assert.assertFalse("and the mirror went dark with the row", r.node.hasActiveSos())
        // and it cannot be lit again by a remembered projection: a fresh scan of
        // the terminal tables says the same as the flag
        var seen: ActiveSos? = null
        runTest { seen = r.node.activeSosSnapshot() }
        Assert.assertNull("the scan must agree with the darkness", seen)
    }
}
