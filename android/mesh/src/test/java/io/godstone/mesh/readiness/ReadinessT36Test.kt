// T36 readiness court (android isle) -- the twin of ReadinessT36Tests.swift.
//
// SendDirectAuthority: an atomic authored DIRECT send command. One reviewed scenario per
// witness; every assertion is positive and expected (a present side effect is captured, an
// absent one is CAPTURED as absence); the observable counters on the injected fakes are the
// oracles that make the five named falsifications killable (retry regenerates the identity,
// retry re-resolves the recipient, an id handed out before the durable commit, the profile
// gate moved after signing, a changed content replaying pinned bytes).
package io.godstone.mesh.readiness

import io.godstone.core.crypto.Ed25519Keys
import io.godstone.core.crypto.X25519Keys
import io.godstone.mesh.delivery.AckFrame
import io.godstone.mesh.delivery.AckMode
import io.godstone.mesh.delivery.AckResult
import io.godstone.mesh.delivery.ClearResult
import io.godstone.mesh.delivery.DeliveryLookup
import io.godstone.mesh.delivery.DeliveryRecord
import io.godstone.mesh.delivery.DeliveryRepository
import io.godstone.mesh.delivery.DeliveryState
import io.godstone.mesh.delivery.DeliveryTracker
import io.godstone.mesh.delivery.DeliveryTransition
import io.godstone.mesh.delivery.Ed25519AckAuthenticator
import io.godstone.mesh.delivery.EnqueueResult
import io.godstone.mesh.delivery.TransitionResult
import io.godstone.mesh.delivery.IntentStateRank
import io.godstone.mesh.delivery.InMemoryOutboundIntentJournal
import io.godstone.mesh.delivery.LogicalIdentityFactory
import io.godstone.mesh.delivery.PeerIdentityLookupSource
import io.godstone.mesh.delivery.RecipientKeyResolver
import io.godstone.mesh.delivery.SendDirectAuthority
import io.godstone.mesh.delivery.SendDirectCommand
import io.godstone.mesh.delivery.SendDirectRejection
import io.godstone.mesh.delivery.SendDirectResult
import io.godstone.mesh.delivery.SenderClock
import io.godstone.mesh.delivery.SenderSigningKeys
import io.godstone.mesh.delivery.SenderTime
import io.godstone.mesh.delivery.SigningKeysAdapter
import io.godstone.mesh.identity.Identity
import io.godstone.mesh.identity.PeerIdentityLookup
import io.godstone.mesh.identity.PeerIdentityRecord
import io.godstone.mesh.identity.PeerTrustLevel
import io.godstone.mesh.identity.PeerTrustRepositoryCorruptionReason
import io.godstone.mesh.identity.PendingPeerIdentity
import io.godstone.mesh.identity.VerifiedPeerIdentity
import io.godstone.mesh.router.BloomDigest
import io.godstone.mesh.router.Router
import io.godstone.mesh.seal.SealedSender
import io.godstone.mesh.store.InMemoryMessageStore
import io.godstone.mesh.store.MessageStore
import io.godstone.mesh.store.OutboundEnqueueResult
import io.godstone.mesh.wire.v2.FrameV2
import io.godstone.mesh.wire.v2.LogicalMessageIdentity
import io.godstone.mesh.wire.v2.MessageId
import io.godstone.mesh.wire.v2.Priority
import io.godstone.mesh.wire.v2.SignedMessageV1
import io.godstone.mesh.wire.v2.TimeQuality
import io.godstone.mesh.wire.v2.TypeV2
import java.security.SecureRandom
import kotlinx.coroutines.test.runTest
import org.junit.Assert
import org.junit.Test

class ReadinessT36Test {

    private val rng = SecureRandom()

    // ------------------------------------------------------------------ fakes (deterministic; counters observable)

    private class FixedClock(private val created: Long, private val quality: TimeQuality) : SenderClock {
        var calls: Int = 0
            private set
        override fun now(): SenderTime {
            calls++
            return SenderTime(created, quality)
        }
    }

    private class RecordingIdentityFactory : LogicalIdentityFactory {
        var creates: Int = 0
            private set
        private var seq: Long = 0
        override fun create(nowEpochSeconds: Long): LogicalMessageIdentity {
            creates++
            seq++
            val nonce = ByteArray(MessageId.NONCE_BYTES)
            for (i in nonce.indices) nonce[i] = ((seq * 31 + i * 7 + 3) and 0xFFL).toByte()
            return LogicalMessageIdentity.of(nowEpochSeconds, nonce)
        }
    }

    private class TrustSource : PeerIdentityLookupSource {
        private val table = mutableMapOf<List<Byte>, PeerIdentityLookup>()
        var resolves: Int = 0
            private set
        var faulted: Boolean = false
        private fun k(b: ByteArray) = b.toList()
        override fun lookup(nodeId: ByteArray): PeerIdentityLookup {
            resolves++
            if (faulted) return PeerIdentityLookup.StorageFailure(null)
            return table[k(nodeId)] ?: PeerIdentityLookup.NotFound
        }
        fun approve(nodeId: ByteArray, signingPub: ByteArray, staticDhPub: ByteArray, generation: Long) {
            val rec = PeerIdentityRecord(nodeId, signingPub, staticDhPub, generation, PeerTrustLevel.TOFU_PINNED)
            val verified = VerifiedPeerIdentity.fromRecord(rec)
                ?: throw IllegalStateException("fixture record malformed")
            table[k(nodeId)] = PeerIdentityLookup.Verified(verified)
        }
        fun quarantine(nodeId: ByteArray, signingPub: ByteArray, acceptedStaticDhPub: ByteArray) {
            val rec = PeerIdentityRecord(
                nodeId, signingPub, acceptedStaticDhPub, 1L, PeerTrustLevel.TOFU_PINNED,
                ByteArray(32) { 0x5A.toByte() }, 2L)
            val pending = PendingPeerIdentity.fromRecord(rec)
                ?: throw IllegalStateException("fixture pending record malformed")
            table[k(nodeId)] = PeerIdentityLookup.Quarantined(pending)
        }
        fun revokeMarker(nodeId: ByteArray) { table[k(nodeId)] = PeerIdentityLookup.Revoked }
        fun corruptAt(nodeId: ByteArray) {
            table[k(nodeId)] = PeerIdentityLookup.Corrupt(PeerTrustRepositoryCorruptionReason.UnknownTrustLevelCode(99))
        }
        fun markInvalid(nodeId: ByteArray) { table[k(nodeId)] = PeerIdentityLookup.InvalidArgument("fixture: malformed record") }
    }

    /** A [MessageStore] delegating to the durable in-memory engine, with an injected one-shot fault at the enqueue boundary. */
    private class FaultStore(val base: InMemoryMessageStore) : MessageStore by base {
        var failNextEnqueue: Boolean = false
        override suspend fun enqueueDirectOutbound(
            frame: FrameV2,
            expectedRecipient: ByteArray,
            localOriginNodeId: ByteArray,
        ): OutboundEnqueueResult {
            if (failNextEnqueue) {
                failNextEnqueue = false
                return OutboundEnqueueResult.StorageFailure
            }
            return base.enqueueDirectOutbound(frame, expectedRecipient, localOriginNodeId)
        }
    }

    /** Delivery repository view mirroring the store's durable rows (integration-corpus idiom). */
    private class RepoView(private val store: InMemoryMessageStore?) : DeliveryRepository {
        private val records = mutableMapOf<List<Byte>, DeliveryRecord>()
        private fun k(m: ByteArray) = m.toList()
        override fun get(msgId: ByteArray): DeliveryLookup {
            if (msgId.size != 16) return DeliveryLookup.InvalidArgument
            records[k(msgId)]?.let { return DeliveryLookup.Found(it) }
            val d = store?.readDeliveryRow(msgId)
            if (d != null) {
                val s = DeliveryState.fromPersistedCode(d.state)
                val a = AckMode.fromCode(d.ackMode)
                if (s != null && a != null) {
                    val fresh = DeliveryRecord(msgId, s, a, d.expectedRecipient)
                    records[k(msgId)] = fresh
                    return DeliveryLookup.Found(fresh)
                }
            }
            return DeliveryLookup.NotFound
        }
        override fun enqueue(msgId: ByteArray, ackMode: AckMode, expectedRecipient: ByteArray?): EnqueueResult {
            if (msgId.size != 16) return EnqueueResult.InvalidArgument
            return when (val l = get(msgId)) {
                DeliveryLookup.NotFound -> {
                    records[k(msgId)] = DeliveryRecord(msgId, DeliveryState.QUEUED_DURABLY, ackMode, expectedRecipient)
                    EnqueueResult.Created
                }
                is DeliveryLookup.Found -> EnqueueResult.AlreadyQueuedSameBinding
                DeliveryLookup.Corrupt -> EnqueueResult.Corrupt
                DeliveryLookup.StorageFailure -> EnqueueResult.StorageFailure
                DeliveryLookup.InvalidArgument -> EnqueueResult.InvalidArgument
            }
        }
        override fun transition(msgId: ByteArray, transition: DeliveryTransition): TransitionResult =
            TransitionResult.RejectedState
        override fun acknowledgeBoundAndRetire(msgId: ByteArray, expectedRecipient: ByteArray): AckResult {
            if (msgId.size != 16 || expectedRecipient.size != 16) return AckResult.InvalidArgument
            return when (val l = get(msgId)) {
                is DeliveryLookup.Found -> {
                    val rec = l.record
                    val bound = rec.expectedRecipientNodeId
                    if (rec.ackMode != AckMode.SINGLE_RECIPIENT || bound == null || !bound.contentEquals(expectedRecipient)) {
                        return AckResult.UnknownMessage
                    }
                    if (rec.state == DeliveryState.ACKNOWLEDGED_BY_RECIPIENT) return AckResult.DuplicateAuthenticatedAck
                    records[k(msgId)] = rec.copy(state = DeliveryState.ACKNOWLEDGED_BY_RECIPIENT)
                    store?.updateDeliveryState(msgId, DeliveryState.ACKNOWLEDGED_BY_RECIPIENT.code)
                    AckResult.Applied
                }
                DeliveryLookup.NotFound -> AckResult.UnknownMessage
                DeliveryLookup.Corrupt -> AckResult.Corrupt
                DeliveryLookup.StorageFailure -> AckResult.StorageFailure
                DeliveryLookup.InvalidArgument -> AckResult.InvalidArgument
            }
        }
        override fun clear(msgId: ByteArray): ClearResult =
            if (records.remove(k(msgId)) != null) ClearResult.Cleared else ClearResult.AlreadyAbsent
    }

    private class Fixture(
        val snd: Identity,
        val signing: SigningKeysAdapter,
        val store: FaultStore,
        val journal: InMemoryOutboundIntentJournal,
        val trust: TrustSource,
        val factory: RecordingIdentityFactory,
        val clock: FixedClock,
        val authority: SendDirectAuthority,
        val router: Router,
    )

    private fun fixture(created: Long = 1700000123L): Fixture {
        val ed = Ed25519Keys.generate(rng)
        val dh = X25519Keys.generate(rng)
        val snd = Identity.fromKeyMaterial(ed.pub, ed.priv, dh.pub, dh.priv)
        val signing = SigningKeysAdapter(ed.priv, ed.pub)
        val base = InMemoryMessageStore()
        val store = FaultStore(base)
        val router = Router(store, snd.nodeId)
        val journal = InMemoryOutboundIntentJournal()
        val trust = TrustSource()
        val factory = RecordingIdentityFactory()
        val clock = FixedClock(created, TimeQuality.USER_CONFIRMED)
        val authority = SendDirectAuthority(
            identity = snd,
            signingKeys = signing,
            router = router,
            store = store,
            trustResolver = io.godstone.mesh.delivery.TrustedPeerIdentityResolver(trust),
            journal = journal,
            identityFactory = factory,
            clock = clock,
        )
        return Fixture(snd, signing, store, journal, trust, factory, clock, authority, router)
    }

    private data class Peer(val identity: Identity, val signingPriv: ByteArray, val staticDhPriv: ByteArray)

    private fun approvePeer(f: Fixture): Peer {
        val ed = Ed25519Keys.generate(rng)
        val dh = X25519Keys.generate(rng)
        val id = Identity.fromKeyMaterial(ed.pub, ed.priv, dh.pub, dh.priv)
        f.trust.approve(id.nodeId, ed.pub, dh.pub, 1L)
        return Peer(id, ed.priv, dh.priv)
    }

    private fun cmd(intent: ByteArray, ref: ByteArray, body: ByteArray): SendDirectCommand =
        SendDirectCommand.of(intent, ref, body) ?: throw IllegalStateException("command shape malformed")

    private fun ascii(s: String): ByteArray = s.toByteArray(kotlin.text.Charsets.US_ASCII)

    private fun bytesOf(seed: Int, n: Int): ByteArray = ByteArray(n) { ((it * 31 + seed) and 0xFF).toByte() }

    private fun le32(b: ByteArray): Long =
        (b[0].toLong() and 0xFF) or ((b[1].toLong() and 0xFF) shl 8) or
            ((b[2].toLong() and 0xFF) shl 16) or ((b[3].toLong() and 0xFF) shl 24)

    // ------------------------------------------------------------------ witnesses

    /** W1: a double tap is TWO explicit intents; identical content still yields two DISTINCT
     *  logical ids (a fresh nonce per logical send), both durable, each with its own bound row. */
    @Test
    fun testDoubleTapYieldsTwoExplicitIntentsTwoLogicalSends() = runTest {
        val f = fixture()
        val bob = approvePeer(f)
        val r1 = f.authority.sendDirect(cmd(bytesOf(1, 16), bob.identity.nodeId, ascii("same body"))) as SendDirectResult.DurablyEnqueued
        val r2 = f.authority.sendDirect(cmd(bytesOf(2, 16), bob.identity.nodeId, ascii("same body"))) as SendDirectResult.DurablyEnqueued
        Assert.assertFalse("the two logical ids differ (fresh nonce per logical send)", r1.logicalMessageId.contentEquals(r2.logicalMessageId))
        Assert.assertFalse("neither accept reports a replay", r1.fromRetry || r2.fromRetry)
        Assert.assertEquals("the store holds both frames", 2, f.store.base.allHeldMsgIds().size)
        Assert.assertEquals("one identity creation per logical send", 2, f.factory.creates)
        Assert.assertEquals("one resolve per logical send", 2, f.trust.resolves)
        Assert.assertEquals("two journal rows", 2, f.journal.size())
        for (id in listOf(r1.logicalMessageId, r2.logicalMessageId)) {
            val d = f.store.base.readDeliveryRow(id)
            Assert.assertNotNull("each send carries its delivery row from the same transaction", d)
            Assert.assertEquals("SINGLE_RECIPIENT binding", AckMode.SINGLE_RECIPIENT.code, d!!.ackMode)
            Assert.assertEquals("QUEUED_DURABLY at commit", DeliveryState.QUEUED_DURABLY.code, d.state)
            Assert.assertTrue("the expected recipient is bound", d.expectedRecipient != null && d.expectedRecipient!!.contentEquals(bob.identity.nodeId))
        }
    }

    /** W2: retry of the SAME intent token loads identical persisted bytes -- the counters
     *  prove nothing was re-created and nothing was re-resolved. */
    @Test
    fun testRetryOfSameIntentTokenLoadsIdenticalPersistedBytes() = runTest {
        val f = fixture()
        val bob = approvePeer(f)
        val t = bytesOf(5, 16)
        val first = f.authority.sendDirect(cmd(t, bob.identity.nodeId, ascii("retry me"))) as SendDirectResult.DurablyEnqueued
        val bytes1 = f.store.base.allHeldOrderedByPriority().single().encode()
        val creates0 = f.factory.creates
        val resolves0 = f.trust.resolves
        val second = f.authority.sendDirect(cmd(t, bob.identity.nodeId, ascii("retry me"))) as SendDirectResult.DurablyEnqueued
        Assert.assertTrue("the retry reports itself as a replay", second.fromRetry)
        Assert.assertArrayEquals("the same immutable logical id", first.logicalMessageId, second.logicalMessageId)
        val bytes2 = f.store.base.allHeldOrderedByPriority().single().encode()
        Assert.assertArrayEquals("identical persisted bytes", bytes1, bytes2)
        Assert.assertEquals("the identity was created once, ever", creates0, f.factory.creates)
        Assert.assertEquals("the recipient was resolved once, ever", resolves0, f.trust.resolves)
        Assert.assertEquals("still a single journal row", 1, f.journal.size())
    }

    /** W3: the key rotation race -- the generation is pinned at first accept; a replay never
     *  consults the rotated table; a FRESH intent resolves CURRENT. */
    @Test
    fun testKeyRotationRacePinsTheAcceptedGeneration() = runTest {
        val f = fixture()
        val bob = approvePeer(f)
        val t = bytesOf(6, 16)
        val first = f.authority.sendDirect(cmd(t, bob.identity.nodeId, ascii("rot me"))) as SendDirectResult.DurablyEnqueued
        // ADR-003 rotation: the identity signing key persists; ONLY the static DH material rotates.
        // (R5 of the frozen record validator binds nodeId to the SIGNING key, so the signing half stays.)
        val dh2 = X25519Keys.generate(rng)
        f.trust.approve(bob.identity.nodeId, bob.identity.identityPub, dh2.pub, 2L)
        // rotate under the pinned token
        val resolvesBefore = f.trust.resolves
        val replay = f.authority.sendDirect(cmd(t, bob.identity.nodeId, ascii("rot me"))) as SendDirectResult.DurablyEnqueued
        Assert.assertArrayEquals("the rotation cannot move the pinned replay", first.logicalMessageId, replay.logicalMessageId)
        Assert.assertEquals("the replay did not consult the rotated table", resolvesBefore, f.trust.resolves)
        Assert.assertEquals("the row pins the FIRST generation", 1L, f.journal.load(t)!!.acceptedGeneration)
        val t2 = bytesOf(66, 16)
        val fresh = f.authority.sendDirect(cmd(t2, bob.identity.nodeId, ascii("rot me"))) as SendDirectResult.DurablyEnqueued
        Assert.assertEquals("the fresh accept consulted the rotated table once more", resolvesBefore + 1, f.trust.resolves)
        Assert.assertEquals("the fresh row pins generation 2", 2L, f.journal.load(t2)!!.acceptedGeneration)
        Assert.assertArrayEquals("the fresh row seals with the ROTATED static material", f.journal.load(t2)!!.recipientStaticDhPub, dh2.pub)
        Assert.assertFalse("a fresh logical id, distinct from the pinned one", fresh.logicalMessageId.contentEquals(first.logicalMessageId))
    }

    /** W4: disk full at the durable commit -- failure is DISTINGUISHED from empty success:
     *  no id is handed out, nothing half-committed, and the pinned identity survives so the
     *  retry yields the SAME logical id. */
    @Test
    fun testDiskFullRefusesSendDistinguishingFailureFromEmpty() = runTest {
        val f = fixture()
        val bob = approvePeer(f)
        val t = bytesOf(8, 16)
        f.store.failNextEnqueue = true
        val refused = f.authority.sendDirect(cmd(t, bob.identity.nodeId, ascii("burst")))
        Assert.assertTrue("the refusal is typed", refused is SendDirectResult.Rejected)
        Assert.assertEquals("named StorageFailure at the enqueue boundary",
            SendDirectRejection.EnqueueStorageFailure, (refused as SendDirectResult.Rejected).reason)
        Assert.assertEquals("no frame reached the store", 0, f.store.base.allHeldMsgIds().size)
        val rowLoaded = f.journal.load(t)
        Assert.assertNotNull("the row persisted through the fault", rowLoaded)
        val row = rowLoaded!!
        Assert.assertEquals("it stands at AUTHORED -- the identity is pinned, not lost", IntentStateRank.AUTHORED, row.stateRank)
        f.store.failNextEnqueue = false
        val again = f.authority.sendDirect(cmd(t, bob.identity.nodeId, ascii("burst"))) as SendDirectResult.DurablyEnqueued
        Assert.assertArrayEquals("the retry yields the SAME logical id -- identity survives the crash", row.logicalMessageId, again.logicalMessageId)
        Assert.assertTrue("reported as a replay", again.fromRetry)
        Assert.assertEquals("one identity creation for the whole saga", 1, f.factory.creates)
        Assert.assertEquals("one resolve for the whole saga", 1, f.trust.resolves)
        Assert.assertEquals("the store now holds the one frame", 1, f.store.base.allHeldMsgIds().size)
        Assert.assertEquals("the row climbed to COMMITTED", IntentStateRank.COMMITTED, f.journal.load(t)!!.stateRank)
    }

    /** W5: process interruption and restart -- a fresh authority over the same durable media
     *  loads identical bytes and creates NOTHING. */
    @Test
    fun testRestartRetryIdenticalBytes() = runTest {
        val f = fixture()
        val bob = approvePeer(f)
        val t = bytesOf(11, 16)
        val first = f.authority.sendDirect(cmd(t, bob.identity.nodeId, ascii("persisted"))) as SendDirectResult.DurablyEnqueued
        val bytes1 = f.store.base.allHeldOrderedByPriority().single().encode()
        val factory2 = RecordingIdentityFactory()
        val trust2 = TrustSource()                                          // a fresh view: the replay must not need it
        val authority2 = SendDirectAuthority(
            identity = f.snd, signingKeys = f.signing, router = f.router, store = f.store,
            trustResolver = io.godstone.mesh.delivery.TrustedPeerIdentityResolver(trust2),
            journal = f.journal, identityFactory = factory2,
            clock = FixedClock(1700000999L, TimeQuality.USER_CONFIRMED),
        )
        val replay = authority2.sendDirect(cmd(t, bob.identity.nodeId, ascii("persisted"))) as SendDirectResult.DurablyEnqueued
        Assert.assertTrue("the restarted accept recognises the pinned intent", replay.fromRetry)
        Assert.assertArrayEquals("same immutable logical id after restart", first.logicalMessageId, replay.logicalMessageId)
        val bytes2 = f.store.base.allHeldOrderedByPriority().single().encode()
        Assert.assertArrayEquals("identical persisted bytes after restart", bytes1, bytes2)
        Assert.assertEquals("the restarted instance created nothing", 0, factory2.creates)
        Assert.assertEquals("the restarted instance resolved nothing", 0, trust2.resolves)
    }

    /** W6: changed recipient, body, or priority under one token is a NEW logical send; the
     *  shipped profile refuses non-DIRECT and fabricates nothing. */
    @Test
    fun testChangedRecipientOrBodyOrPriorityCreatesNewLogicalSend() = runTest {
        val f = fixture()
        val bob = approvePeer(f)
        val carolEd = Ed25519Keys.generate(rng)
        val carolDh = X25519Keys.generate(rng)
        val carol = Identity.fromKeyMaterial(carolEd.pub, carolEd.priv, carolDh.pub, carolDh.priv)
        f.trust.approve(carol.nodeId, carolEd.pub, carolDh.pub, 1L)
        val t = bytesOf(12, 16)
        val id1 = (f.authority.sendDirect(cmd(t, bob.identity.nodeId, ascii("body A"))) as SendDirectResult.DurablyEnqueued).logicalMessageId
        val id2 = (f.authority.sendDirect(cmd(t, bob.identity.nodeId, ascii("body B"))) as SendDirectResult.DurablyEnqueued).logicalMessageId
        val id3 = (f.authority.sendDirect(cmd(t, carol.nodeId, ascii("body B"))) as SendDirectResult.DurablyEnqueued).logicalMessageId
        Assert.assertFalse("changed body => new logical send", id1.contentEquals(id2))
        Assert.assertFalse("changed recipient => new logical send", id2.contentEquals(id3))
        Assert.assertEquals("three creations, one per accepted change", 3, f.factory.creates)
        Assert.assertEquals("the store retains the whole history", 3, f.store.base.allHeldMsgIds().size)
        Assert.assertEquals("one current row per token", 1, f.journal.size())
        Assert.assertEquals("the current row reflects the latest accept", IntentStateRank.COMMITTED, f.journal.load(t)!!.stateRank)
        val dDirect = SendDirectAuthority.bindingDigest(bob.identity.nodeId, ascii("body B"), Priority.DIRECT.code)
        val dGroup = SendDirectAuthority.bindingDigest(bob.identity.nodeId, ascii("body B"), Priority.GROUP.code)
        Assert.assertFalse("priority is covered by the binding digest", dDirect.contentEquals(dGroup))
        val before = f.factory.creates
        val refused = f.authority.sendDirect(cmd(bytesOf(13, 16), bob.identity.nodeId, ascii("sneak")), Priority.SOS)
        Assert.assertTrue("the lab profile forbids non-DIRECT shipping", refused is SendDirectResult.Rejected)
        Assert.assertEquals("the refusal fabricated nothing", before, f.factory.creates)
        Assert.assertEquals("still three durable frames", 3, f.store.base.allHeldMsgIds().size)
    }

    /** W7: one body, several approved recipients -- each binding is a distinct logical send
     *  with its own durable row; no cross-contamination of ids or bindings. */
    @Test
    fun testMultiRecipientDistinctIds() = runTest {
        val f = fixture()
        val bob = approvePeer(f)
        val carolEd = Ed25519Keys.generate(rng)
        val carolDh = X25519Keys.generate(rng)
        val carol = Identity.fromKeyMaterial(carolEd.pub, carolEd.priv, carolDh.pub, carolDh.priv)
        f.trust.approve(carol.nodeId, carolEd.pub, carolDh.pub, 1L)
        val body = ascii("one body, distinct ids")
        val rb = f.authority.sendDirect(cmd(bytesOf(21, 16), bob.identity.nodeId, body)) as SendDirectResult.DurablyEnqueued
        val rc = f.authority.sendDirect(cmd(bytesOf(22, 16), carol.nodeId, body)) as SendDirectResult.DurablyEnqueued
        Assert.assertFalse("distinct recipients, distinct logical ids", rb.logicalMessageId.contentEquals(rc.logicalMessageId))
        Assert.assertEquals("two frames held", 2, f.store.base.allHeldMsgIds().size)
        val db = f.store.base.readDeliveryRow(rb.logicalMessageId)
        val dc = f.store.base.readDeliveryRow(rc.logicalMessageId)
        Assert.assertNotNull(db); Assert.assertNotNull(dc)
        Assert.assertTrue("the first row binds its own expected recipient", db!!.expectedRecipient != null && db.expectedRecipient!!.contentEquals(bob.identity.nodeId))
        Assert.assertTrue("the second row binds its own expected recipient", dc!!.expectedRecipient != null && dc.expectedRecipient!!.contentEquals(carol.nodeId))
        Assert.assertEquals("one creation per logical send", 2, f.factory.creates)
    }

    /** W8: the 400-byte UTF-8 profile gate stands BEFORE every authoring primitive -- a
     *  rejected body fabricates no signature, no seal, no row, no state. */
    @Test
    fun testBodyProfileGateBeforeAnyAuthoring() = runTest {
        val f = fixture()
        val bob = approvePeer(f)
        val oversize = ByteArray(SignedMessageV1.BODY_MAX + 1) { 0x41 }
        val loneContinuation = byteArrayOf(0x6E.toByte(), 0x6F.toByte(), 0x80.toByte())   // "no" + a naked continuation byte
        val cases = listOf(
            Triple("empty", ByteArray(0), SendDirectRejection.BodyEmpty),
            Triple("oversize", oversize, SendDirectRejection.BodyTooLarge),
            Triple("malformed", loneContinuation, SendDirectRejection.BodyNotUtf8),
        )
        var i = 0
        for ((name, body, expected) in cases) {
            i++
            val r = f.authority.sendDirect(cmd(bytesOf(30 + i, 16), bob.identity.nodeId, body))
            Assert.assertTrue("$name is Rejected", r is SendDirectResult.Rejected)
            Assert.assertEquals("$name names $expected", expected, (r as SendDirectResult.Rejected).reason)
        }
        Assert.assertEquals("no identity was ever created", 0, f.factory.creates)
        Assert.assertEquals("no signature was produced: the resolver was never consulted", 0, f.trust.resolves)
        Assert.assertEquals("nothing reached the store", 0, f.store.base.allHeldMsgIds().size)
        Assert.assertEquals("no rows in the journal", 0, f.journal.size())
        val exact = ByteArray(SignedMessageV1.BODY_MAX) { 0x41 }
        val ok = f.authority.sendDirect(cmd(bytesOf(44, 16), bob.identity.nodeId, exact))
        Assert.assertTrue("the maximal well-formed body is admitted (the boundary belongs to the profile)",
            ok is SendDirectResult.DurablyEnqueued)
    }

    /** W9: an immutable logical id is handed out ONLY after the durable commit proved itself
     *  -- read it back from the store and re-derived from the pinned row; a Rejected carries none. */
    @Test
    fun testIdentityOnlyAfterDurableEnqueue() = runTest {
        val f = fixture()
        val bob = approvePeer(f)
        val t = bytesOf(51, 16)
        val enq = f.authority.sendDirect(cmd(t, bob.identity.nodeId, ascii("prove me"))) as SendDirectResult.DurablyEnqueued
        val rowLoaded = f.journal.load(t)
        Assert.assertNotNull("the pinned row exists after the commit", rowLoaded)
        val row = rowLoaded!!
        val held = f.store.base.allHeldOrderedByPriority().single()
        Assert.assertArrayEquals("the held frame carries the handed id", enq.logicalMessageId, held.msgId)
        Assert.assertEquals("MESSAGE type", TypeV2.MESSAGE, held.type)
        Assert.assertTrue("SEALED is set", (held.flags and FrameV2.SEALED) != 0)
        Assert.assertTrue("the row is self-proving from the pinned bytes", row.verifyLogicalIdentity(f.snd.nodeId))
        Assert.assertArrayEquals("the row id equals the handed id", row.logicalMessageId, enq.logicalMessageId)
        val d = f.store.base.readDeliveryRow(enq.logicalMessageId)
        Assert.assertNotNull("the delivery row stands with the frame", d)
        Assert.assertEquals("SINGLE_RECIPIENT", AckMode.SINGLE_RECIPIENT.code, d!!.ackMode)
        Assert.assertEquals("QUEUED_DURABLY", DeliveryState.QUEUED_DURABLY.code, d.state)
        f.store.failNextEnqueue = true
        val refused = f.authority.sendDirect(cmd(bytesOf(52, 16), bob.identity.nodeId, ascii("prove me")))
        Assert.assertTrue("the refused command carries NO id", refused is SendDirectResult.Rejected)
        Assert.assertEquals("and names the fault", SendDirectRejection.EnqueueStorageFailure, (refused as SendDirectResult.Rejected).reason)
    }

    /** W10: unapproved and faulty recipients answer with SEVEN mutually distinct typed
     *  rejections -- failure distinguished from empty/no-op success, nothing mutated. */
    @Test
    fun testUnapprovedRecipientYieldsTypedDistinctRejections() = runTest {
        val f = fixture()
        val absent = bytesOf(61, 16)                                          // never entered in the table
        val qEd = Ed25519Keys.generate(rng); val qDh = X25519Keys.generate(rng)
        val qId = Identity.fromKeyMaterial(qEd.pub, qEd.priv, qDh.pub, qDh.priv)
        f.trust.quarantine(qId.nodeId, qEd.pub, qDh.pub)
        val revokedKey = bytesOf(63, 16); f.trust.revokeMarker(revokedKey)
        val corruptKey = bytesOf(64, 16); f.trust.corruptAt(corruptKey)
        val invalidKey = bytesOf(65, 16); f.trust.markInvalid(invalidKey)
        val cases = listOf(
            Quad("absent", absent, SendDirectRejection.RecipientAbsent),
            Quad("quarantined", qId.nodeId, SendDirectRejection.RecipientNotApproved),
            Quad("revoked", revokedKey, SendDirectRejection.RecipientRevoked),
            Quad("corrupt", corruptKey, SendDirectRejection.RecipientCorrupt),
            Quad("invalid", invalidKey, SendDirectRejection.TrustRefMalformed),
        )
        var i = 0
        val seen = mutableListOf<SendDirectRejection>()
        for ((name, ref, expected) in cases) {
            i++
            val r = f.authority.sendDirect(cmd(bytesOf(70 + i, 16), ref, ascii("body")))
            Assert.assertTrue("$name is Rejected", r is SendDirectResult.Rejected)
            Assert.assertEquals("$name names $expected", expected, (r as SendDirectResult.Rejected).reason)
            seen.add(r.reason)
        }
        f.trust.faulted = true
        val r6 = f.authority.sendDirect(cmd(bytesOf(78, 16), absent, ascii("body"))) as SendDirectResult.Rejected
        Assert.assertEquals("a storage fault is its own name", SendDirectRejection.RecipientStorageFailure, r6.reason)
        seen.add(r6.reason)
        f.trust.faulted = false
        val r7 = f.authority.sendDirect(cmd(bytesOf(79, 16), absent, ByteArray(0))) as SendDirectResult.Rejected
        Assert.assertEquals("an empty body is its own name (the profile gate precedes the trust gate)",
            SendDirectRejection.BodyEmpty, r7.reason)
        seen.add(r7.reason)
        Assert.assertEquals("seven mutually distinct typed rejections", 7, seen.toSet().size)
        Assert.assertEquals("nothing was authored", 0, f.factory.creates)
        Assert.assertEquals("nothing was stored", 0, f.store.base.allHeldMsgIds().size)
        Assert.assertEquals("no journal rows", 0, f.journal.size())
    }

    /** W11: the production call path in one sweep -- UI command, author/encrypt, durable
     *  enqueue, router, trusted link, recipient inbox, signed ACK -- the downstream side
     *  effect CAPTURED; the refused variant of the same path captured as ABSENCE end to end. */
    @Test
    fun testFullCallPathCommandToSignedAck() = runTest {
        val f = fixture()
        val bobEd = Ed25519Keys.generate(rng); val bobDh = X25519Keys.generate(rng)
        val bob = Identity.fromKeyMaterial(bobEd.pub, bobEd.priv, bobDh.pub, bobDh.priv)
        f.trust.approve(bob.nodeId, bobEd.pub, bobDh.pub, 1L)
        // 1..3: UI command -> author/encrypt -> durable enqueue
        val t = bytesOf(81, 16)
        val body = ascii("across the trusted link")
        val enq = f.authority.sendDirect(cmd(t, bob.nodeId, body)) as SendDirectResult.DurablyEnqueued
        // 4: router -- the peer pulls what its (empty) digest lacks from the held store
        val missing = f.router.framesPeerLacks(BloomDigest(), 32)
        Assert.assertEquals("one frame offered for the lacking peer", 1, missing.size)
        val frame = missing.single()
        Assert.assertArrayEquals("the offered frame is the handed logical send", enq.logicalMessageId, frame.msgId)
        // the trusted link hands it to the recipient's router, which persists it in the inbox
        val bobStore = InMemoryMessageStore()
        val bobRouter = Router(bobStore, bob.nodeId)
        Assert.assertTrue("the inbox admitted the frame", bobRouter.onFrameReceived(frame, f.snd.nodeId))
        Assert.assertEquals("the inbox holds exactly the one frame", 1, bobStore.allHeldMsgIds().size)
        // the recipient opens the sealed envelope with its OWN static private key (section 15 prefix)
        val op = SealedSender.open(frame.payload, bobDh.priv)
        Assert.assertNotNull("the envelope opens for the intended recipient alone", op)
        Assert.assertTrue("the claimed sender is the origin", op!!.senderNodeId.contentEquals(f.snd.nodeId))
        val inner = op.plaintext
        val nonce = inner.copyOfRange(0, 16)
        val powNonce = inner.copyOfRange(16, 24)
        val created = le32(inner.copyOfRange(24, 28))
        val prio = inner[28].toInt() and 0xFF
        val sp = inner.copyOfRange(29, inner.size)
        Assert.assertTrue("the DIRECT policy crossed the link intact (zero PoW nonce)", powNonce.all { it == 0.toByte() })
        Assert.assertEquals("the priority byte is DIRECT", Priority.DIRECT.code, prio)
        val verdict = SignedMessageV1.verify(sp, op.senderNodeId, bob.nodeId, nonce, created, prio)
        Assert.assertTrue("the authorship binding verifies at the recipient", verdict is io.godstone.mesh.wire.v2.SenderVerificationResult.Verified)
        val m = (verdict as io.godstone.mesh.wire.v2.SenderVerificationResult.Verified).message
        Assert.assertArrayEquals("the body survived the journey", body, m.bodyUtf8)
        Assert.assertArrayEquals("the msgID binding is circular-consistent end to end", frame.msgId, m.msgId)
        // 7: the recipient signs the ACK; the sender's tracker advances the durable row on proof
        val repoView = RepoView(f.store.base)
        val tracker = DeliveryTracker(repoView, Ed25519AckAuthenticator(object : RecipientKeyResolver {
            override fun publicSigningKey(nodeId: ByteArray): ByteArray? =
                if (nodeId.contentEquals(bob.nodeId)) bobEd.pub else null
        }))
        val ackFrame = AckFrame.build(frame.msgId, bobEd.priv, bob.nodeId, frame.routingTag)
        Assert.assertEquals("the authenticated ACK applies", AckResult.Applied, tracker.acknowledge(frame.msgId, ackFrame))
        val d = f.store.base.readDeliveryRow(frame.msgId)
        Assert.assertNotNull(d)
        Assert.assertEquals("the row advanced to ACKNOWLEDGED_BY_RECIPIENT",
            DeliveryState.ACKNOWLEDGED_BY_RECIPIENT.code, d!!.state)
        // the refused variant of the same path: an unapproved recipient captures pure absence
        val f2 = fixture()
        val stranger = bytesOf(99, 16)                                        // never approved anywhere
        val r2 = f2.authority.sendDirect(cmd(bytesOf(98, 16), stranger, ascii("nowhere")))
        Assert.assertTrue("refused at the trust gate", r2 is SendDirectResult.Rejected)
        Assert.assertEquals("named absent", SendDirectRejection.RecipientAbsent, (r2 as SendDirectResult.Rejected).reason)
        Assert.assertEquals("no frame was ever authored", 0, f2.store.base.allHeldMsgIds().size)
        Assert.assertEquals("no journal row exists", 0, f2.journal.size())
        Assert.assertEquals("no identity was created", 0, f2.factory.creates)
        Assert.assertEquals("nothing crossed the link", 0, f2.router.framesPeerLacks(BloomDigest(), 32).size)
    }
}

/** A 3-field record for the W10 cases (the Quad name marks the shape, three fields only). */
private data class Quad<A, B, C>(val first: A, val second: B, val third: C)
