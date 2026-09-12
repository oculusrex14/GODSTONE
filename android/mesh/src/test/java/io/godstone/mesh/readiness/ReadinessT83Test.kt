// T83 readiness court (android isle) -- the twin of ReadinessT83Tests.swift.
//
// Add ack_obligations and ack_frames namespaces as section14 specifies. One reviewed
// scenario per witness; every assertion is positive and expected (a present side
// effect is captured, an absent one is CAPTURED as absence through a typed Absent /
// zero-count observation); the observable counters on the injected fakes and the
// paired-store census are the oracles that make the five named falsifications
// killable (an ACK stored into the message namespace, the obligation omitted from
// the inbox transaction, candidates deduped across distinct signatures, the pair
// quota removed, the retirement unbound from the frame transaction).
package io.godstone.mesh.readiness

import io.godstone.core.crypto.Ed25519Keys
import io.godstone.core.crypto.X25519Keys
import io.godstone.mesh.delivery.AckAdmissionResult
import io.godstone.mesh.delivery.AckCacheKey
import io.godstone.mesh.delivery.AckFrame
import io.godstone.mesh.delivery.AckFrameRecord
import io.godstone.mesh.delivery.AckObligation
import io.godstone.mesh.delivery.AckObligationDriver
import io.godstone.mesh.delivery.AckObligationState
import io.godstone.mesh.delivery.AckSignerSeam
import io.godstone.mesh.delivery.AckVerificationClass
import io.godstone.mesh.delivery.Ed25519AckAuthenticator
import io.godstone.mesh.delivery.FrameCommitResult
import io.godstone.mesh.delivery.FrameLookup
import io.godstone.mesh.delivery.InboundCommitResult
import io.godstone.mesh.delivery.InMemoryAckStore
import io.godstone.mesh.delivery.ObligationAdvanceResult
import io.godstone.mesh.delivery.ObligationInsertResult
import io.godstone.mesh.delivery.ObligationLookup
import io.godstone.mesh.delivery.PairList
import io.godstone.mesh.delivery.PendingList
import io.godstone.mesh.delivery.RecipientKeyResolver
import io.godstone.mesh.delivery.SqliteAckStore
import io.godstone.mesh.identity.Identity
import io.godstone.mesh.router.Router
import io.godstone.mesh.store.FrameCommitOutcome
import io.godstone.mesh.store.InMemoryMessageStore
import io.godstone.mesh.store.JdbcStoreDb
import io.godstone.mesh.wire.v2.FrameV2
import io.godstone.mesh.wire.v2.LogicalMessageIdentity
import io.godstone.mesh.wire.v2.Priority
import io.godstone.mesh.wire.v2.TypeV2
import java.io.File
import java.security.SecureRandom
import kotlinx.coroutines.test.runTest
import org.junit.Assert
import org.junit.Test

class ReadinessT83Test {
    private val rng = SecureRandom()

    // ------------------------------------------------------------------ fakes (deterministic; counters observable)

    private class BytesKey(bytes: ByteArray) {
        private val b = bytes.copyOf()
        override fun equals(other: Any?): Boolean = other is BytesKey && b.contentEquals(other.b)
        override fun hashCode(): Int = b.contentHashCode()
    }

    private class KeyTable : RecipientKeyResolver {
        private val table = LinkedHashMap<BytesKey, ByteArray>()
        var queries: Int = 0
            private set
        fun put(nodeId: ByteArray, key: ByteArray) {
            table[BytesKey(nodeId)] = key.copyOf()
        }
        fun dropAll() {
            table.clear()
        }
        override fun publicSigningKey(nodeId: ByteArray): ByteArray? {
            queries++
            return table[BytesKey(nodeId)]?.copyOf()
        }
    }

    private class Local(val id: ByteArray, val seed: ByteArray, val pub: ByteArray, val dhPub: ByteArray)

    private fun newLocal(): Local {
        val ed = Ed25519Keys.generate(rng)
        val dh = X25519Keys.generate(rng)
        val idn = Identity.fromKeyMaterial(ed.pub, ed.priv, dh.pub, dh.priv)
        return Local(idn.nodeId, ed.priv, ed.pub, dh.pub)
    }

    private class TestSigner(private val local: Local?) : AckSignerSeam {
        var asks: Int = 0
            private set
        var pinnedGeneration: Long = Long.MAX_VALUE
        override val nodeId: ByteArray?
            get() = local?.id?.copyOf()
        override fun generation(): Long = pinnedGeneration
        override fun signingSeed(msgId: ByteArray, recipientNodeId: ByteArray): ByteArray? {
            asks++
            return local?.seed?.copyOf()
        }
    }

    private class Rig(
        val me: Local,
        val originId: ByteArray,
        val store: InMemoryMessageStore,
        val router: Router,
        val keys: KeyTable,
        val authenticator: Ed25519AckAuthenticator,
    )

    private fun rig(tag: Int): Rig {
        val me = newLocal()
        val origin = nodeOf(tag, 0x11)
        val base = InMemoryMessageStore()
        val router = Router(base, origin)
        val keys = KeyTable()
        return Rig(me, origin, base, router, keys, Ed25519AckAuthenticator(keys))
    }

    // the first four bytes carry the seed injectively (no mod-256 collapse);
    // the tail is layout-fixed per salt, so pairs and probes never collide
    private fun nodeOf(seed: Int, salt: Int): ByteArray =
        ByteArray(16) { i ->
            if (i < 4) ((seed shr (8 * (3 - i))) and 0xFF).toByte()
            else ((i * 17 + salt * 3 + 1) and 0xFF).toByte()
        }

    private fun nonceOf(seed: Int): ByteArray =
        ByteArray(16) { i -> ((i * 31 + seed * 5 + 3) and 0xFF).toByte() }

    private fun hintOf(nodeId: ByteArray): ByteArray = nodeId.copyOfRange(0, 4)

    private fun ascii(s: String): ByteArray = s.toByteArray(kotlin.text.Charsets.US_ASCII)

    private suspend fun inboxFrame(r: Rig, tag: Int): FrameV2 {
        val identity = LogicalMessageIdentity.of(1700000200L, nonceOf(tag))
        return r.router.buildSealedMessage(
            plaintext = ascii("t83-inbox-$tag"),
            recipientNodeId = r.me.id,
            recipientStaticPub = r.me.dhPub,
            identity = identity,
            priority = Priority.DIRECT,
        )
    }

    private suspend fun commitInbound(r: Rig, frame: FrameV2, generation: Long, lifetimeMs: Long): InboundCommitResult =
        r.store.commitInboundWithObligationAtWithFault(
            frame, r.originId, r.me.id, generation, lifetimeMs, 1700000201L, null,
        )

    private fun driverOf(r: Rig, signer: TestSigner): AckObligationDriver =
        AckObligationDriver(r.store.ackStore, signer, r.authenticator, r.keys)

    // ------------------------------------------------------------------ witnesses

    @Test
    fun testCrashAfterInboxCommitBeforeSigningResumesDeterministically() = runTest {
        val r = rig(101)
        r.keys.put(r.me.id, r.me.pub)
        val frame = inboxFrame(r, 11)
        val c = commitInbound(r, frame, 7L, 60000L)
        Assert.assertTrue(
            "the inbox commit reports itself committed with a fresh obligation",
            c is InboundCommitResult.Committed && c.heldNew && c.obligationStored && !c.duplicate,
        )
        // crash at the signing boundary: the worker dies before it holds the pen
        val dying = driverOf(r, TestSigner(r.me))
        var raised = false
        try {
            dying.runPendingOnce(8) { point ->
                if (point == "signing") throw IllegalStateException("process death before signing")
            }
        } catch (e: IllegalStateException) {
            raised = true
        }
        Assert.assertTrue("the seam death is observable", raised)
        Assert.assertEquals("no frame half-acknowledged survives the crash", 0, r.store.ackStore.countFrames())
        when (val pending = r.store.ackStore.lookupObligation(frame.msgId, r.me.id)) {
            is ObligationLookup.Found -> Assert.assertEquals(
                "the obligation endures as pending (retryable)",
                AckObligationState.PENDING, pending.obligation.state,
            )
            else -> Assert.fail("the durable obligation must survive the crash")
        }
        // restart with a fresh worker over the same durable state
        val revived = driverOf(r, TestSigner(r.me))
        val report = revived.runPendingOnce(8)
        Assert.assertEquals("the resumed scan finds the one pending obligation", 1, report.scanned)
        Assert.assertEquals("the resumed worker signs once", 1, report.signed)
        Assert.assertEquals("and retires once", 1, report.retired)
        Assert.assertEquals("claiming nothing else", 0, report.keyUnavailable + report.storageFailures + report.idempotent + report.refusedQuota)
        Assert.assertEquals("the obligation table drains empty", 0, r.store.ackStore.countObligations())
        // the resumed outcome is byte-identical to the canonical one built directly
        val reference = AckFrame.build(frame.msgId, r.me.seed, r.me.id, hintOf(r.me.id))
        val key = AckCacheKey.compute(frame.msgId, r.me.id, reference.payload.copyOfRange(0, 64))
        if (key == null) {
            Assert.fail("the local cache key must be computable")
            return@runTest
        }
        when (val got = r.store.ackStore.lookupByAckKey(key)) {
            is FrameLookup.Found -> Assert.assertArrayEquals(
                "canonical bytes survive the restart unchanged", reference.encode(), got.record.encodedFrame,
            )
            else -> Assert.fail("the frame must live under the honest digest key")
        }
    }

    @Test
    fun testSigningKeyUnavailableLeavesRetryableObligationAndNoClaimedDelivery() = runTest {
        val r = rig(102)
        r.keys.put(r.me.id, r.me.pub)
        val frame = inboxFrame(r, 21)
        Assert.assertTrue(
            "commit ok", commitInbound(r, frame, 7L, 60000L) is InboundCommitResult.Committed,
        )
        val starvingSigner = TestSigner(null)           // no local identity stands ready
        val starving = driverOf(r, starvingSigner)
        val s1 = starving.runPendingOnce(8)
        Assert.assertEquals("one row scanned", 1, s1.scanned)
        Assert.assertEquals("the key could not be had once", 1, s1.keyUnavailable)
        Assert.assertEquals("nothing signed", 0, s1.signed + s1.retired + s1.storageFailures)
        Assert.assertEquals("no key was even asked for", 0, starvingSigner.asks)
        Assert.assertEquals("the frame namespace stays empty", 0, r.store.ackStore.countFrames())
        when (val ob = r.store.ackStore.lookupObligation(frame.msgId, r.me.id)) {
            is ObligationLookup.Found -> Assert.assertTrue(
                "the obligation survives pending and retryable, lifetime untouched",
                ob.obligation.state == AckObligationState.PENDING && ob.obligation.remainingLifetimeMs == 60000L,
            )
            else -> Assert.fail("the obligation must survive the outage")
        }
        val staleSigner = TestSigner(r.me)
        staleSigner.pinnedGeneration = 0L            // older than the accepted pin of seven
        val stale = driverOf(r, staleSigner)
        val s1b = stale.runPendingOnce(8)
        Assert.assertEquals("a stale key must not sign", 1, s1b.keyUnavailable)
        Assert.assertEquals("and must not claim", 0, s1b.signed)
        Assert.assertEquals("the obligation still waits", 1, r.store.ackStore.countObligations())
        val healthy = driverOf(r, TestSigner(r.me))
        val s2 = healthy.runPendingOnce(8)
        Assert.assertEquals("the retry completes after the outage", 1, s2.signed)
        Assert.assertEquals("and retires the survivor", 1, s2.retired)
        Assert.assertEquals("one row in the frame namespace", 1, r.store.ackStore.countFrames())
    }

    @Test
    fun testMessageAndAckCoexistUnderSameMsgIdDistinctNamespaces() = runTest {
        val r = rig(103)
        r.keys.put(r.me.id, r.me.pub)
        val frame = inboxFrame(r, 31)
        Assert.assertTrue(
            "commit ok", commitInbound(r, frame, 7L, 60000L) is InboundCommitResult.Committed,
        )
        val rep = driverOf(r, TestSigner(r.me)).runPendingOnce(8)
        Assert.assertEquals("one signed", 1, rep.signed)
        // the message original still lives, byte-for-byte untouched
        val held = r.store.allHeldOrderedByPriority()
        Assert.assertEquals("the held set still carries the one message", 1, held.size)
        Assert.assertArrayEquals("the reply never clobbered the original", frame.encode(), held[0].encode())
        // the acknowledgement dwells beside it: same msg id, other namespace
        when (val pair = r.store.ackStore.candidatesForPair(frame.msgId, r.me.id, 8)) {
            is PairList.Records -> {
                Assert.assertEquals("the pair holds exactly one candidate", 1, pair.records.size)
                val rec = pair.records[0]
                Assert.assertArrayEquals("the ACK names the very same msg id", frame.msgId, rec.msgId)
                Assert.assertTrue(
                    "yet the two namespaces are distinct: the stored bytes differ from the original",
                    !rec.encodedFrame.contentEquals(frame.encode()),
                )
            }
            else -> Assert.fail("the pair scan must succeed")
        }
        Assert.assertEquals("and the obligation is discharged", 0, r.store.ackStore.countObligations())
    }

    @Test
    fun testForgedCandidateThenValidSignatureAdmitsBothSlotsDistinguishable() = runTest {
        val r = rig(104)
        val frame = inboxFrame(r, 41)
        val genuine = AckFrame.build(frame.msgId, r.me.seed, r.me.id, hintOf(r.me.id))
        // one byte flipped inside the signature field: a forgery on the wire
        val tampered = genuine.payload.copyOf()
        tampered[3] = (tampered[3].toInt() xor 0xFF).toByte()
        val forged = FrameV2(
            type = genuine.type, msgId = genuine.msgId, routingTag = genuine.routingTag,
            ttl = genuine.ttl, hopCount = genuine.hopCount, flags = genuine.flags, payload = tampered,
        )
        // an available authenticated recipient key: the forgery is caught BEFORE any write
        r.keys.put(r.me.id, r.me.pub)
        val d = driverOf(r, TestSigner(r.me))
        Assert.assertTrue(
            "invalid signature under an available key is refused",
            d.admitForeignCandidate(forged.encode(), r.originId) is AckAdmissionResult.RefusedKnownInvalid,
        )
        Assert.assertEquals("the refusal stores nothing", 0, r.store.ackStore.countFrames())
        // and can never suppress the later valid signature
        val acceptance = d.admitForeignCandidate(genuine.encode(), r.originId)
        when (acceptance) {
            is AckAdmissionResult.Stored -> {}
            else -> Assert.fail("the valid one must be admitted")
        }
        Assert.assertEquals("one verified row", 1, r.store.ackStore.countFrames())
        // an unknown key relays a copy only as a bounded opaque candidate, never labelled verified
        r.keys.dropAll()
        val alienSeed = ByteArray(32) { b -> ((b * 23 + 9) and 0xFF).toByte() }
        val alien = AckFrame.build(frame.msgId, alienSeed, r.me.id, hintOf(r.me.id))
        when (val ad2 = d.admitForeignCandidate(alien.encode(), r.originId)) {
            is AckAdmissionResult.Stored -> {
                when (val lk = r.store.ackStore.lookupByAckKey(ad2.ackKey)) {
                    is FrameLookup.Found -> Assert.assertEquals(
                        "the unknown-key copy is opaque, not verified",
                        AckVerificationClass.OPAQUE_CANDIDATE, lk.record.verificationClass,
                    )
                    else -> Assert.fail("the opaque candidate must be readable back")
                }
            }
            else -> Assert.fail("the unknown-key copy must be admitted opaquely")
        }
        when (val both = r.store.ackStore.candidatesForPair(frame.msgId, r.me.id, 8)) {
            is PairList.Records -> {
                Assert.assertEquals("verified and opaque coexist as distinct rows", 2, both.records.size)
                var verified = 0
                var opaque = 0
                for (rec in both.records) {
                    when (rec.verificationClass) {
                        AckVerificationClass.VERIFIED_RECIPIENT -> verified++
                        AckVerificationClass.OPAQUE_CANDIDATE -> opaque++
                    }
                }
                Assert.assertEquals("exactly one row claims verification", 1, verified)
                Assert.assertEquals("exactly one row stays opaque", 1, opaque)
            }
            else -> Assert.fail("the pair scan must succeed")
        }
    }

    @Test
    fun testFourCandidateVariantsBoundedPerPair() = runTest {
        val r = rig(105)
        val frame = inboxFrame(r, 51)
        val d = driverOf(r, TestSigner(r.me))
        r.keys.dropAll()   // unknown keys -> all variants enter opaquely and must not dedup each other
        val seen = ArrayList<ByteArray>()
        for (i in 0 until 4) {
            val seed = ByteArray(32) { b -> ((b * 13 + i * 101 + 5) and 0xFF).toByte() }
            val v = AckFrame.build(frame.msgId, seed, r.me.id, hintOf(r.me.id))
            when (val res = d.admitForeignCandidate(v.encode(), r.originId)) {
                is AckAdmissionResult.Stored -> seen.add(res.ackKey.copyOf())
                else -> Assert.fail("variant $i must be admitted")
            }
            Assert.assertEquals(
                "variant $i stands alone so far", i + 1,
                r.store.ackStore.countForPair(frame.msgId, r.me.id),
            )
        }
        // the same candidate again: an idempotent Duplicate, not a dedup interference
        val lastSeed = ByteArray(32) { b -> ((b * 13 + 3 * 101 + 5) and 0xFF).toByte() }
        val repeat = AckFrame.build(frame.msgId, lastSeed, r.me.id, hintOf(r.me.id))
        Assert.assertTrue(
            "an identical copy is a Duplicate",
            d.admitForeignCandidate(repeat.encode(), r.originId) is AckAdmissionResult.Duplicate,
        )
        Assert.assertEquals("the pair still holds the four distinct ones", 4, r.store.ackStore.countForPair(frame.msgId, r.me.id))
        // the fifth distinct variant is explicitly refused at the bound
        val fifthSeed = ByteArray(32) { b -> ((b * 13 + 4 * 101 + 5) and 0xFF).toByte() }
        val fifth = AckFrame.build(frame.msgId, fifthSeed, r.me.id, hintOf(r.me.id))
        Assert.assertTrue(
            "capacity refuses further custody explicitly",
            d.admitForeignCandidate(fifth.encode(), r.originId) is AckAdmissionResult.RefusedQuotaPair,
        )
        Assert.assertEquals("and the first four stand untouched", 4, r.store.ackStore.countForPair(frame.msgId, r.me.id))
        Assert.assertEquals("no other namespace moved", 4, r.store.ackStore.countFrames())
        // the four keys are pairwise distinct: they do not dedup each other
        for (a in seen.indices) {
            for (b in a + 1 until seen.size) {
                Assert.assertTrue("distinct signatures yield distinct keys", !seen[a].contentEquals(seen[b]))
            }
        }
    }

    @Test
    fun testGlobalQuotaSaturationRefusesExplicitlyAndWipePreservesOriginals() = runTest {
        val r = rig(106)
        val acks = r.store.ackStore
        var admitted = 0
        for (p in 0 until 1024) {
            val m = nodeOf(p, 0x21)
            val recip = nodeOf(p, 0x5E)
            for (k in 0 until 4) {
                val sig = ByteArray(64) { b -> ((b * 7 + p * 3 + k + 1) and 0xFF).toByte() }
                val key = AckCacheKey.compute(m, recip, sig) ?: throw IllegalStateException("fixture digest")
                val enc = ByteArray(20) { b -> ((b + p + k) and 0xFF).toByte() }
                val rec = AckFrameRecord.of(
                    key, m, recip, sig, enc, r.originId, 1000L + k, AckVerificationClass.OPAQUE_CANDIDATE,
                ) ?: throw IllegalStateException("fixture record")
                when (acks.storeCandidate(rec)) {
                    is AckAdmissionResult.Stored -> admitted++
                    else -> Assert.fail("the census fill must admit ($p,$k)")
                }
            }
        }
        Assert.assertEquals("the census reaches the global bound", 4096, admitted)
        Assert.assertEquals(4096, acks.countFrames())
        // one candidate beyond the bound is refused explicitly, never silently dropped
        val mOut = nodeOf(9999, 0x77)
        val rOut = nodeOf(9998, 0x78)
        val sigOut = ByteArray(64) { b -> ((b * 11 + 3) and 0xFF).toByte() }
        val keyOut = AckCacheKey.compute(mOut, rOut, sigOut) ?: throw IllegalStateException("fixture digest")
        val encOut = ByteArray(20) { b -> ((b + 1) and 0xFF).toByte() }
        val recOut = AckFrameRecord.of(
            keyOut, mOut, rOut, sigOut, encOut, r.originId, 1L, AckVerificationClass.OPAQUE_CANDIDATE,
        ) ?: throw IllegalStateException("fixture record")
        Assert.assertTrue(
            "the shared quota refuses the next pair explicitly",
            acks.storeCandidate(recOut) is AckAdmissionResult.RefusedQuotaGlobal,
        )
        Assert.assertEquals("the bound stands", 4096, acks.countFrames())
        // first put one message through the very inbox, then wipe the ACK namespace:
        // the quota-governed wipe must not touch the message originals
        r.keys.put(r.me.id, r.me.pub)
        val frame = inboxFrame(r, 61)
        Assert.assertTrue(
            "inbox commit ok", commitInbound(r, frame, 3L, 60000L) is InboundCommitResult.Committed,
        )
        Assert.assertEquals("the wipe reports the exact count it removed", 4096, acks.deleteAllFrames())
        Assert.assertEquals("the ACK namespace stands empty", 0, acks.countFrames())
        val held = r.store.allHeldMsgIds()
        Assert.assertEquals("the message originals survived the wipe", 1, held.size)
        Assert.assertTrue("and the one held message is the committed original", held[0].contentEquals(frame.msgId))
    }

    @Test
    fun testDuplicateValidMessageRegeneratesSameDeterministicAckNoDuplicateInbox() = runTest {
        val r = rig(107)
        r.keys.put(r.me.id, r.me.pub)
        val frame = inboxFrame(r, 71)
        when (val c1 = commitInbound(r, frame, 7L, 60000L)) {
            is InboundCommitResult.Committed -> Assert.assertTrue(
                "the first commit is fresh", c1.heldNew && c1.obligationStored && !c1.duplicate,
            )
            else -> Assert.fail("the first commit must succeed")
        }
        var genBefore = -1L
        var remBefore = -1L
        when (val before = r.store.ackStore.lookupObligation(frame.msgId, r.me.id)) {
            is ObligationLookup.Found -> {
                genBefore = before.obligation.identityGeneration
                remBefore = before.obligation.remainingLifetimeMs
            }
            else -> Assert.fail("the obligation must stand before the re-delivery")
        }
        // the same msg id arrives again; a newer pin offered must NOT replenish the row
        when (val c2 = commitInbound(r, frame, 9L, 90000L)) {
            is InboundCommitResult.Committed -> Assert.assertTrue(
                "the duplicate reports itself a duplicate", !c2.heldNew && !c2.obligationStored && c2.duplicate,
            )
            else -> Assert.fail("the duplicate commit must succeed as a duplicate")
        }
        Assert.assertEquals("one inbox row only", 1, r.store.allHeldMsgIds().size)
        Assert.assertEquals("one obligation row only", 1, r.store.ackStore.countObligations())
        when (val after = r.store.ackStore.lookupObligation(frame.msgId, r.me.id)) {
            is ObligationLookup.Found -> {
                Assert.assertEquals(
                    "the generation pin is not replenished by the re-delivery", genBefore, after.obligation.identityGeneration,
                )
                Assert.assertEquals(
                    "the remaining lifetime is not replenished either", remBefore, after.obligation.remainingLifetimeMs,
                )
            }
            else -> Assert.fail("the obligation must stand after the re-delivery")
        }
        val rep = driverOf(r, TestSigner(r.me)).runPendingOnce(8)
        Assert.assertEquals("one signed", 1, rep.signed)
        val reference = AckFrame.build(frame.msgId, r.me.seed, r.me.id, hintOf(r.me.id))
        val expectedKey = AckCacheKey.compute(frame.msgId, r.me.id, reference.payload.copyOfRange(0, 64))
        if (expectedKey == null) {
            Assert.fail("the deterministic key must be computable")
            return@runTest
        }
        when (val lk = r.store.ackStore.lookupByAckKey(expectedKey)) {
            is FrameLookup.Found -> Assert.assertArrayEquals(
                "one ack, one row, byte-identical to the deterministic regeneration", reference.encode(), lk.record.encodedFrame,
            )
            else -> Assert.fail("the deterministic ACK must live under the computed cache key")
        }
        val again = driverOf(r, TestSigner(r.me)).runPendingOnce(8)
        Assert.assertEquals("the worker claims nothing twice", 0, again.scanned + again.signed + again.retired)
    }

    @Test
    fun testObligationRetiredOnlyWithFrameTransaction() = runTest {
        val acks = InMemoryAckStore()
        val m = nodeOf(81, 0x01)
        val recip = nodeOf(82, 0x02)
        val sig = ByteArray(64) { b -> ((b * 3 + 11) and 0xFF).toByte() }
        val key = AckCacheKey.compute(m, recip, sig) ?: throw IllegalStateException("fixture key")
        val enc = ByteArray(24) { b -> ((b * 5 + 1) and 0xFF).toByte() }
        val record = AckFrameRecord.of(
            key, m, recip, sig, enc, null, 5000L, AckVerificationClass.VERIFIED_RECIPIENT,
        ) ?: throw IllegalStateException("fixture record")
        val ob = AckObligation.of(m, recip, 2L, 5000L, AckObligationState.PENDING)
            ?: throw IllegalStateException("fixture obligation")
        // (a) the pair step moves frame insert and retirement together
        when (val ins = acks.insertIfAbsent(ob)) {
            is ObligationInsertResult.Stored -> {}
            else -> Assert.fail("the fixture obligation must insert")
        }
        when (val cm = acks.commitFrameAndRetireObligation(record, m, recip)) {
            is FrameCommitResult.Committed -> {}
            else -> Assert.fail("the pair step must commit")
        }
        Assert.assertEquals("the frame arrived", 1, acks.countFrames())
        when (val lk = acks.lookupObligation(m, recip)) {
            is ObligationLookup.Absent -> {}
            else -> Assert.fail("and the obligation retired in the same step")
        }
        // (b) replaying the pair step is idempotent
        when (val cm2 = acks.commitFrameAndRetireObligation(record, m, recip)) {
            is FrameCommitResult.Idempotent -> {}
            else -> Assert.fail("the replay must be idempotent")
        }
        Assert.assertEquals("still exactly one frame row", 1, acks.countFrames())
        // (c) the guarded mark advances once; drift is named; absence is not a failure
        val m2 = nodeOf(83, 0x03)
        val ob2 = AckObligation.of(m2, recip, 3L, 4000L, AckObligationState.PENDING)
            ?: throw IllegalStateException("fixture obligation")
        when (acks.insertIfAbsent(ob2)) {
            is ObligationInsertResult.Stored -> {}
            else -> Assert.fail("the second fixture obligation must insert")
        }
        Assert.assertTrue("markSigned advances a pending row", acks.markSigned(m2, recip) is ObligationAdvanceResult.Advanced)
        when (val st = acks.markSigned(m2, recip)) {
            is ObligationAdvanceResult.StateDrift -> Assert.assertEquals(
                "the second mark reports the drift it saw", AckObligationState.SIGNED, st.foundState,
            )
            else -> Assert.fail("the second mark must report drift, not advance")
        }
        when (val ab = acks.markSigned(nodeOf(99, 0x99), recip)) {
            is ObligationAdvanceResult.Absent -> {}
            else -> Assert.fail("absence is Absent, never a failure")
        }
        // (d) the resume scan re-drives half-finished pairs: a SIGNED row stays visible
        when (val pl = acks.listPending(8)) {
            is PendingList.Rows -> {
                Assert.assertEquals("the SIGNED row is still awaiting retirement", 1, pl.rows.size)
                Assert.assertEquals(AckObligationState.SIGNED, pl.rows[0].state)
            }
            else -> Assert.fail("the resume scan must succeed")
        }
        val sig2 = ByteArray(64) { b -> ((b * 9 + 1) and 0xFF).toByte() }
        val key2 = AckCacheKey.compute(m2, recip, sig2) ?: throw IllegalStateException("fixture key")
        val enc2 = ByteArray(24) { b -> ((b * 7 + 3) and 0xFF).toByte() }
        val record2 = AckFrameRecord.of(
            key2, m2, recip, sig2, enc2, null, 4000L, AckVerificationClass.VERIFIED_RECIPIENT,
        ) ?: throw IllegalStateException("fixture record")
        when (val cm3 = acks.commitFrameAndRetireObligation(record2, m2, recip)) {
            is FrameCommitResult.Committed -> {}
            else -> Assert.fail("the half-finished pair must complete atomically")
        }
        when (val pl2 = acks.listPending(8)) {
            is PendingList.Rows -> Assert.assertEquals("the scan drains to zero", 0, pl2.rows.size)
            else -> Assert.fail("the final scan must succeed")
        }
    }

    @Test
    fun testStorageFailureYieldsNeitherAckNorClaimedAcceptance() = runTest {
        val r = rig(109)
        r.keys.put(r.me.id, r.me.pub)
        val frame = inboxFrame(r, 91)
        // the fault seam at the obligation boundary: the WHOLE inbox commit rolls back
        val c = r.store.commitInboundWithObligationAtWithFault(
            frame, r.originId, r.me.id, 7L, 60000L, 1700000201L,
        ) { point ->
            if (point == "obligation") throw IllegalStateException("disk full at the obligation boundary")
        }
        Assert.assertTrue("the commit names the storage failure", c is InboundCommitResult.StorageFailure)
        Assert.assertEquals("the held set stayed empty: no half-delivered inbox", 0, r.store.allHeldMsgIds().size)
        Assert.assertEquals("and no obligation was claimed", 0, r.store.ackStore.countObligations())
        // the failure did not poison the store: an unrelated commit still succeeds
        val frame2 = inboxFrame(r, 92)
        Assert.assertTrue(
            "a later commit succeeds", commitInbound(r, frame2, 7L, 60000L) is InboundCommitResult.Committed,
        )
        // the SQL engine: CHECK constraints refuse forgeries the constructors would never build
        val file = File.createTempFile("t83-obligations", ".db")
        file.deleteOnExit()
        val db = JdbcStoreDb(file)
        try {
            var raised = false
            try {
                db.insertObligation(nodeOf(93, 1), nodeOf(94, 2), 1L, 1L, 9)
            } catch (e: Exception) {
                raised = true
            }
            Assert.assertTrue("the state-domain CHECK refuses the code 9", raised)
            raised = false
            try {
                db.insertObligation(nodeOf(93, 1).copyOfRange(0, 15), nodeOf(94, 2), 1L, 1L, 0)
            } catch (e: Exception) {
                raised = true
            }
            Assert.assertTrue("the length CHECK refuses a 15-byte msg id", raised)
            Assert.assertTrue(
                "a well-formed row is accepted", db.insertObligation(nodeOf(93, 1), nodeOf(94, 2), 4L, 60000L, 0),
            )
            val twin = AckObligation.of(nodeOf(93, 1), nodeOf(94, 2), 4L, 60000L, AckObligationState.PENDING)
                ?: throw IllegalStateException("fixture obligation")
            when (val du = SqliteAckStore(db).insertIfAbsent(twin)) {
                is ObligationInsertResult.Duplicate -> {}
                else -> Assert.fail("the very same pair is a Duplicate, not a failure")
            }
            when (val lk = SqliteAckStore(db).lookupObligation(nodeOf(99, 9), nodeOf(98, 8))) {
                is ObligationLookup.Absent -> {}
                else -> Assert.fail("an absent pair must read Absent before any close")
            }
            // the pair step over the real engine: frame and retirement move together
            val pm = nodeOf(95, 3)
            val pr = nodeOf(96, 4)
            val ps = ByteArray(64) { b -> ((b * 9 + 7) and 0xFF).toByte() }
            val pk = AckCacheKey.compute(pm, pr, ps) ?: throw IllegalStateException("fixture key")
            val pe = ByteArray(18) { b -> ((b * 3 + 2) and 0xFF).toByte() }
            val prec = AckFrameRecord.of(
                pk, pm, pr, ps, pe, null, 4000L, AckVerificationClass.VERIFIED_RECIPIENT,
            ) ?: throw IllegalStateException("fixture record")
            db.insertObligation(pm, pr, 5L, 4000L, 0)
            Assert.assertEquals(
                "the pair step commits atomically", FrameCommitOutcome.COMMITTED, db.commitAckPair(prec.toView(), pm, pr),
            )
            Assert.assertNotNull("the frame row persists", db.readAckFrameRowByAckKey(pk))
            Assert.assertNull("the obligation row retired", db.readObligation(pm, pr))
            // failure distinguished from absence once the engine is no more
            db.close()
            when (val lk2 = SqliteAckStore(db).lookupObligation(pm, pr)) {
                is ObligationLookup.StorageFailure -> {}
                else -> Assert.fail("a closed engine must answer StorageFailure, never Absent")
            }
        } finally {
            try {
                db.close()
            } catch (e: Exception) {
                // already closed: the failure leg above proves the mapping
            }
        }
    }

    @Test
    fun testWrongSizedInputsRejectedBeforeAnyWrite() = runTest {
        val good = nodeOf(10, 0x0A)
        // obligations: every wrong width is refused by the constructor
        Assert.assertNull("a 15-byte msg id", AckObligation.of(good.copyOfRange(0, 15), good, 1L, 1L, AckObligationState.PENDING))
        Assert.assertNull("a 17-byte msg id", AckObligation.of(good + byteArrayOf(1, 2), good, 1L, 1L, AckObligationState.PENDING))
        Assert.assertNull("a 15-byte recipient", AckObligation.of(good, good.copyOfRange(0, 15), 1L, 1L, AckObligationState.PENDING))
        Assert.assertNull("a negative generation", AckObligation.of(good, good, -1L, 1L, AckObligationState.PENDING))
        Assert.assertNull("a negative lifetime", AckObligation.of(good, good, 1L, -1L, AckObligationState.PENDING))
        // frame records: the key, the signature and the widths are all policed
        val sig = ByteArray(64) { b -> b.toByte() }
        val enc = ByteArray(10) { b -> b.toByte() }
        val key = AckCacheKey.compute(good, good, sig) ?: throw IllegalStateException("fixture key")
        Assert.assertNull("a 31-byte key", AckFrameRecord.of(key.copyOfRange(0, 31), good, good, sig, enc, null, 1L, AckVerificationClass.VERIFIED_RECIPIENT))
        Assert.assertNull("a 33-byte key", AckFrameRecord.of(key + byteArrayOf(3), good, good, sig, enc, null, 1L, AckVerificationClass.VERIFIED_RECIPIENT))
        Assert.assertNull("a 63-byte signature", AckFrameRecord.of(key, good, good, sig.copyOfRange(0, 63), enc, null, 1L, AckVerificationClass.VERIFIED_RECIPIENT))
        Assert.assertNull("an empty encoding", AckFrameRecord.of(key, good, good, sig, ByteArray(0), null, 1L, AckVerificationClass.VERIFIED_RECIPIENT))
        Assert.assertNull("a 15-byte receivedFrom", AckFrameRecord.of(key, good, good, sig, enc, good.copyOfRange(0, 15), 1L, AckVerificationClass.VERIFIED_RECIPIENT))
        Assert.assertNull("a negative remaining", AckFrameRecord.of(key, good, good, sig, enc, null, -1L, AckVerificationClass.VERIFIED_RECIPIENT))
        // the classifier refuses malformed wire before the table ever sees it
        val r = rig(110)
        val d = driverOf(r, TestSigner(r.me))
        Assert.assertTrue(
            "truncated bytes", d.admitForeignCandidate(ByteArray(7) { b -> b.toByte() }, null) is AckAdmissionResult.RefusedBadFrame,
        )
        val message = inboxFrame(r, 1091)
        Assert.assertTrue(
            "a MESSAGE frame cannot be admitted as an ACK",
            d.admitForeignCandidate(message.encode(), null) is AckAdmissionResult.RefusedBadFrame,
        )
        val genuine = AckFrame.build(message.msgId, r.me.seed, r.me.id, hintOf(r.me.id))
        val shrunk = FrameV2(
            type = genuine.type, msgId = genuine.msgId, routingTag = genuine.routingTag,
            ttl = genuine.ttl, hopCount = genuine.hopCount, flags = genuine.flags,
            payload = genuine.payload.copyOfRange(0, 79),
        )
        Assert.assertTrue(
            "a 79-byte payload is out of shape",
            d.admitForeignCandidate(shrunk.encode(), null) is AckAdmissionResult.RefusedBadFrame,
        )
        Assert.assertTrue(
            "a 15-byte receivedFrom is out of shape",
            d.admitForeignCandidate(genuine.encode(), good.copyOfRange(0, 15)) is AckAdmissionResult.RefusedBadFrame,
        )
        Assert.assertEquals("nothing reached any table", 0, r.store.ackStore.countFrames())
        // the profile gates of the inbox commit refuse a non-DIRECT and an unsealed frame
        val groupFrame = r.router.buildSealedMessage(
            plaintext = ascii("t83-group"), recipientNodeId = r.me.id, recipientStaticPub = r.me.dhPub,
            identity = LogicalMessageIdentity.of(1700000202L, nonceOf(91)), priority = Priority.GROUP,
        )
        Assert.assertTrue(
            "a GROUP message is out of the DIRECT profile",
            r.store.commitInboundWithObligationAtWithFault(
                groupFrame, r.originId, r.me.id, 1L, 1000L, 1700000203L, null,
            ) is InboundCommitResult.InvalidArgument,
        )
        val unsealed = FrameV2(
            type = TypeV2.MESSAGE, msgId = message.msgId, routingTag = message.routingTag,
            ttl = message.ttl, hopCount = message.hopCount,
            flags = Priority.toFlags(Priority.DIRECT), payload = message.payload,
        )
        Assert.assertTrue(
            "an unsealed frame is out of profile",
            r.store.commitInboundWithObligationAtWithFault(
                unsealed, r.originId, r.me.id, 1L, 1000L, 1700000203L, null,
            ) is InboundCommitResult.InvalidArgument,
        )
        Assert.assertEquals("no obligation row was written by the refusals", 0, r.store.ackStore.countObligations())
        Assert.assertEquals("no frame was held by the refusals", 0, r.store.allHeldMsgIds().size)
    }

    @Test
    fun testCanonicalAckBytesEndToEnd() = runTest {
        val r = rig(111)
        r.keys.put(r.me.id, r.me.pub)
        val frame = inboxFrame(r, 1111)
        when (val c = commitInbound(r, frame, 7L, 60000L)) {
            is InboundCommitResult.Committed -> Assert.assertTrue(
                "held new, obligation stored, not a duplicate",
                c.heldNew && c.obligationStored && !c.duplicate,
            )
            else -> Assert.fail("the inbox commit must succeed")
        }
        val rep = driverOf(r, TestSigner(r.me)).runPendingOnce(8)
        Assert.assertEquals("one signed, one retired", 2, rep.signed + rep.retired)
        when (val pl = r.store.ackStore.candidatesForPair(frame.msgId, r.me.id, 8)) {
            is PairList.Records -> {
                Assert.assertEquals("exactly one reply row", 1, pl.records.size)
                val rec = pl.records[0]
                Assert.assertNull("locally authored: no peer was seen", rec.receivedFrom)
                Assert.assertEquals("class VERIFIED under the own key", AckVerificationClass.VERIFIED_RECIPIENT, rec.verificationClass)
                Assert.assertEquals("the lifetime is carried from the obligation, not replenished", 60000L, rec.remainingLifetimeMs)
                val dec = FrameV2.decode(rec.encodedFrame)
                if (dec == null) {
                    Assert.fail("the stored encoding must decode")
                    return@runTest
                }
                Assert.assertEquals("the reply names an ACK", TypeV2.ACK, dec.type)
                Assert.assertArrayEquals("over the very msg id", frame.msgId, dec.msgId)
                Assert.assertEquals("the canonical payload is signature(64) || recipient(16)", 80, dec.payload.size)
                Assert.assertArrayEquals("the signature field", rec.signature, dec.payload.copyOfRange(0, 64))
                Assert.assertArrayEquals("the recipient field", r.me.id, dec.payload.copyOfRange(64, 80))
                Assert.assertArrayEquals("the routing tag is the canonical recipient hint", hintOf(r.me.id), dec.routingTag)
                Assert.assertTrue(
                    "the frozen authenticator, the wire's own gate, accepts the stored reply",
                    r.authenticator.verify(frame.msgId, r.me.id, dec),
                )
                val ky = AckCacheKey.compute(frame.msgId, r.me.id, rec.signature)
                if (ky == null) {
                    Assert.fail("the digest must be computable")
                    return@runTest
                }
                Assert.assertArrayEquals("key == SHA256(domain || msg || recipient || signature)", ky, rec.ackKey)
            }
            else -> Assert.fail("the pair scan must succeed")
        }
        val held = r.store.allHeldOrderedByPriority()
        Assert.assertEquals("the original still stands", 1, held.size)
        Assert.assertArrayEquals("byte for byte", frame.encode(), held[0].encode())
        Assert.assertEquals("the obligation is discharged", 0, r.store.ackStore.countObligations())
        val idle = driverOf(r, TestSigner(r.me)).runPendingOnce(8)
        Assert.assertEquals(
            "a restart finds nothing pending and claims nothing afresh",
            0, idle.scanned + idle.signed + idle.retired + idle.keyUnavailable + idle.storageFailures,
        )
    }
}
