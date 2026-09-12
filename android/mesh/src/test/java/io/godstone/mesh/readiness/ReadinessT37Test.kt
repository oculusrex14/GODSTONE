package io.godstone.mesh.readiness

// T37 readiness court (android isle) -- the twin of ReadinessT37Tests.swift.
//
// Persist received inbox messages before generating recipient ACKs, using the
// authenticated TrustedPeer only as immediate-hop identity (section 14). One
// reviewed scenario per witness; every assertion is positive and expected (a
// present side effect is CAPTURED, an absent one is CAPTURED as absence through
// a typed Absent/zero-count observation); the observable counters on the
// injected seams and the paired-store census are the oracles that make the
// five named falsifications killable (sign-before-commit, tag-as-identity,
// duplicate double-commit, ACK despite storage failure, hop-as-sender).
//
// The frozen authorities are COMPOSED, never rewritten: Router.openSealedMessage
// (unseal + canonical inner policy), SignedMessageV1.verify (the binding laws),
// AckFrame.build / Ed25519AckAuthenticator (the canonical formulas), and the
// T83 inbox transaction with its both-or-neither pair step. On this
// deterministic isle the court additionally proves byte-identity against a
// directly built canonical reference; the iOS twin asserts the verify/digest
// forms (its host Ed25519 layer signs randomized -- the T83 finding).
//
// Deterministic fixtures: SecureRandom only for key GENERATION; fixed clock
// providers at the injected seams; injective node/nonce builders (the T83
// four-verbatim-bytes + fixed-salt-tail idiom -- no mod-256 collapse).

import io.godstone.core.crypto.Ed25519Keys
import io.godstone.core.crypto.X25519Keys
import io.godstone.mesh.MeshNode
import io.godstone.mesh.delivery.AdmitAllSenders
import io.godstone.mesh.delivery.AckCacheKey
import io.godstone.mesh.delivery.AckFrame
import io.godstone.mesh.delivery.AckMode
import io.godstone.mesh.delivery.AckObligationState
import io.godstone.mesh.delivery.AckResult
import io.godstone.mesh.delivery.AckSignerSeam
import io.godstone.mesh.delivery.AckVerificationClass
import io.godstone.mesh.delivery.ClearResult
import io.godstone.mesh.delivery.DeliveryLookup
import io.godstone.mesh.delivery.DeliveryRepository
import io.godstone.mesh.delivery.DeliveryTracker
import io.godstone.mesh.delivery.DeliveryTransition
import io.godstone.mesh.delivery.Ed25519AckAuthenticator
import io.godstone.mesh.delivery.EnqueueResult
import io.godstone.mesh.delivery.InboxCommitResult
import io.godstone.mesh.delivery.ObligationLookup
import io.godstone.mesh.delivery.PairList
import io.godstone.mesh.delivery.RecipientInboxRepository
import io.godstone.mesh.delivery.RecipientKeyResolver
import io.godstone.mesh.delivery.RecipientSenderTrustPolicy
import io.godstone.mesh.delivery.RejectionReason
import io.godstone.mesh.delivery.TransitionResult
import io.godstone.mesh.delivery.UnresolvedRecipientKeyResolver
import io.godstone.mesh.identity.Identity
import io.godstone.mesh.router.Router
import io.godstone.mesh.seal.SealedSender
import io.godstone.mesh.store.InMemoryMessageStore
import io.godstone.mesh.wire.v2.FrameV2
import io.godstone.mesh.wire.v2.LogicalMessageIdentity
import io.godstone.mesh.wire.v2.Priority
import io.godstone.mesh.wire.v2.SignedMessageV1
import io.godstone.mesh.wire.v2.TimeQuality
import io.godstone.mesh.wire.v2.TypeV2
import java.security.SecureRandom
import kotlinx.coroutines.test.runTest
import org.junit.Assert
import org.junit.Test

class ReadinessT37Test {
    private val rng = SecureRandom()

    private val t37FixedDay: Long = 12345L
    private val t37Created: Long = 1700000200L
    private val t37Clock: Long = 1700000201L

    // ------------------------------------------------------------------ fakes

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
        override fun publicSigningKey(nodeId: ByteArray): ByteArray? {
            queries++
            return table[BytesKey(nodeId)]?.copyOf()
        }
    }

    private class Local(
        val id: ByteArray,
        val seed: ByteArray,
        val pub: ByteArray,
        val dhPub: ByteArray,
        val dhPriv: ByteArray,
    )

    private fun newLocal(): Local {
        val ed = Ed25519Keys.generate(rng)
        val dh = X25519Keys.generate(rng)
        val idn = Identity.fromKeyMaterial(ed.pub, ed.priv, dh.pub, dh.priv)
        return Local(idn.nodeId, ed.priv, ed.pub, dh.pub, dh.priv)
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

    /** The never-exercised delivery repository of the T24 integration recipe. */
    private fun deadRepo(): DeliveryRepository = object : DeliveryRepository {
        override fun get(msgId: ByteArray): DeliveryLookup = throw NotImplementedError("unused by these witnesses")
        override fun enqueue(msgId: ByteArray, ackMode: AckMode, expectedRecipient: ByteArray?): EnqueueResult =
            throw NotImplementedError("unused by these witnesses")
        override fun transition(msgId: ByteArray, transition: DeliveryTransition): TransitionResult =
            throw NotImplementedError("unused by these witnesses")
        override fun acknowledgeBoundAndRetire(msgId: ByteArray, expectedRecipient: ByteArray): AckResult =
            throw NotImplementedError("unused by these witnesses")
        override fun clear(msgId: ByteArray): ClearResult = throw NotImplementedError("unused by these witnesses")
    }

    private class Rig(
        val me: Local,
        val base: InMemoryMessageStore,
        val keys: KeyTable,
        val signer: TestSigner,
        val auth: Ed25519AckAuthenticator,
        val repo: RecipientInboxRepository,
    )

    private fun rig(tag: Int, policy: RecipientSenderTrustPolicy? = null): Rig {
        val me = newLocal()
        val base = InMemoryMessageStore()
        val keys = KeyTable()
        keys.put(me.id, me.pub) // own key resolvable: the self-check walks this pin
        val signer = TestSigner(me)
        val repo = RecipientInboxRepository(
            router = Router(base, me.id),
            ourNodeId = me.id,
            localDhPrivate = { me.dhPriv.copyOf() },
            signer = signer,
            resolver = keys,
            authenticator = Ed25519AckAuthenticator(keys),
            pairedStore = base.ackStore,
            commitInbound = { f, rf, lr, g, l, t, fl ->
                base.commitInboundWithObligationAtWithFault(f, rf, lr, g, l, t, fl)
            },
            trustPolicy = policy ?: AdmitAllSenders,
            clockSeconds = { t37Clock },
            epochDay = { t37FixedDay },
            identityGeneration = { 7L },
        )
        return Rig(me, base, keys, signer, Ed25519AckAuthenticator(keys), repo)
    }

    // injective builders: four verbatim seed bytes + fixed salt tail (T83 law)
    private fun nodeOf(seed: Int, salt: Int): ByteArray =
        ByteArray(16) { i ->
            if (i < 4) ((seed shr (8 * (3 - i))) and 0xFF).toByte()
            else ((i * 17 + salt * 3 + 1) and 0xFF).toByte()
        }

    private fun nonceOf(seed: Int): ByteArray =
        ByteArray(16) { i -> ((i * 31 + seed * 5 + 3) and 0xFF).toByte() }

    private fun hintOf(nodeId: ByteArray): ByteArray = nodeId.copyOfRange(0, 4)

    private fun ascii(s: String): ByteArray = s.toByteArray(kotlin.text.Charsets.US_ASCII)

    private fun signedContainer(
        sender: Local,
        recipientId: ByteArray,
        nonceSeed: Int,
        createdAt: Long,
        body: String,
    ): ByteArray = SignedMessageV1.author(
        senderIdentityPriv = sender.seed,
        senderIdentityPub = sender.pub,
        senderNodeId = sender.id,
        recipientNodeId = recipientId,
        messageNonce = nonceOf(nonceSeed),
        createdAtEpochSeconds = createdAt,
        priority = Priority.DIRECT,
        timeQuality = TimeQuality.USER_CONFIRMED,
        bodyUtf8 = ascii(body),
    )

    /** Author the sealed inbound frame; the court normalizes the public rotating
     *  tag onto the rig's pinned day so the hint census is deterministic (the tag
     *  is transport metadata: msgId and the signature bind to the container,
     *  never to the tag). */
    private suspend fun inboundFrame(r: Rig, sender: Local, nonceSeed: Int): FrameV2 {
        val container = signedContainer(sender, r.me.id, nonceSeed, t37Created, "t37-body-$nonceSeed")
        val author = Router(r.base, sender.id)
        val built = author.buildSealedMessage(
            plaintext = container,
            recipientNodeId = r.me.id,
            recipientStaticPub = r.me.dhPub,
            identity = LogicalMessageIdentity.of(t37Created, nonceOf(nonceSeed)),
            priority = Priority.DIRECT,
        )
        return built.copy(routingTag = SealedSender.routingTag(r.me.id, t37FixedDay))
    }

    private suspend fun accept(
        r: Rig,
        frame: FrameV2,
        hop: ByteArray,
        fault: ((String) -> Unit)? = null,
    ): InboxCommitResult = r.repo.acceptVerifiedAndRequireAck(frame, hop, fault)

    private fun ackOf(result: InboxCommitResult): FrameV2? = when (result) {
        is InboxCommitResult.New -> result.ack
        is InboxCommitResult.Duplicate -> result.ack
        is InboxCommitResult.Rejected -> null
    }

    private fun isAccepted(result: InboxCommitResult): Boolean =
        result is InboxCommitResult.New || result is InboxCommitResult.Duplicate

    // ------------------------------------------------------------------ witnesses

    /** W1 -- the card's integration scenario through the composition root:
     *  author/seal -> trusted link (handleInboundFrame) -> recipient inbox ->
     *  signed ACK on the bounded outbox. The router's relay decision stands
     *  untouched beside the local destination attempt. */
    @Test
    fun testActualDirectedSendThroughBothAdaptersToDurableInboxAndSignedAck() = runTest {
        val r = rig(201)
        val sender = newLocal()
        r.keys.put(sender.id, sender.pub)
        val ident = Identity.fromKeyMaterial(r.me.pub, r.me.seed, r.me.dhPub, r.me.dhPriv)
        Assert.assertTrue(
            "the same key material yields the same node id on both build paths",
            ident.nodeId.contentEquals(r.me.id),
        )
        val node = MeshNode(
            ctx = null,
            identity = ident,
            store = r.base,
            deliveryTracker = DeliveryTracker(deadRepo(), Ed25519AckAuthenticator(UnresolvedRecipientKeyResolver)),
        )
        node.recipientInbox = r.repo
        val frame = inboundFrame(r, sender, 21)
        val hop = nodeOf(0x5E17, 0x77) // the immediate-hop trusted peer: not the sender
        val relayed = node.handleInboundFrame(hop, frame.encode())
        Assert.assertTrue("the relay decision stands: the frame was novel", relayed)
        val queued = node.drainAckOutboxForLink(4)
        Assert.assertEquals("exactly one canonical ACK queued for the link", 1, queued.size)
        val ack = queued[0]
        Assert.assertTrue("the answer names the original msg", ack.msgId.contentEquals(frame.msgId))
        Assert.assertEquals("the payload is signature64||recipient16", 80, ack.payload.size)
        Assert.assertEquals("the TTL is the production constant", 12, ack.ttl)
        Assert.assertEquals("one inbox row", 1, r.base.allHeldMsgIds().size)
        Assert.assertEquals("one ack row", 1, r.base.ackStore.countFrames())
        Assert.assertEquals("the obligation drained", 0, r.base.ackStore.countObligations())
        val reference = AckFrame.build(frame.msgId, r.me.seed, r.me.id, hintOf(r.me.id), 12)
        Assert.assertTrue(
            "the queued answer is byte-identical to the canonical regeneration",
            reference.encode().contentEquals(ack.encode()),
        )
        val census = r.repo.census()
        Assert.assertEquals("one admission counted", 1, census.committedNew + census.committedDuplicate)
        Assert.assertEquals("one ACK issued", 1, census.acksIssued)
        Assert.assertEquals(
            "no refusal counted",
            0,
            census.acksRefusedQuota + census.acksRefusedKey + census.acksRefusedSelfVerify,
        )
        val second = node.drainAckOutboxForLink(4)
        Assert.assertEquals("the outbox drained dry", 0, second.size)
    }

    /** W2 -- duplicate valid delivery: no duplicate inbox content; the SAME ACK
     *  returned. The signer is asked EXACTLY once across both accepts: the
     *  second answer is read from the stored row, never re-signed. */
    @Test
    fun testDuplicateValidDeliveryRegeneratesSameAckWithoutDuplicateInbox() = runTest {
        val r = rig(202)
        val sender = newLocal()
        r.keys.put(sender.id, sender.pub)
        val frame = inboundFrame(r, sender, 22)
        val hop = nodeOf(0x60, 0x11)
        val first = accept(r, frame, hop)
        Assert.assertTrue("the first delivery is accepted", isAccepted(first))
        val firstAck = ackOf(first)
        Assert.assertNotNull("the first delivery carries the canonical ACK", firstAck)
        Assert.assertEquals("the signer was asked once", 1, r.signer.asks)
        val second = accept(r, frame, hop)
        Assert.assertTrue("the duplicate is admitted as already held", second is InboxCommitResult.Duplicate)
        val secondAck = ackOf(second)
        Assert.assertNotNull("the duplicate still carries an ACK", secondAck)
        Assert.assertTrue(
            "the very bytes first filed are handed out again",
            firstAck!!.encode().contentEquals(secondAck!!.encode()),
        )
        Assert.assertEquals("the signer was NOT asked again: stored row, not re-signature", 1, r.signer.asks)
        Assert.assertEquals("one inbox row only", 1, r.base.allHeldMsgIds().size)
        Assert.assertEquals("one ack row only", 1, r.base.ackStore.countFrames())
        Assert.assertEquals("obligations stay drained", 0, r.base.ackStore.countObligations())
    }

    /** W3 -- bad signature: refused at the frozen verifier BEFORE admission;
     *  every table stands at zero. */
    @Test
    fun testBadSignatureRefusedBeforeAnyAdmission() = runTest {
        val r = rig(203)
        val sender = newLocal()
        r.keys.put(sender.id, sender.pub)
        val container = signedContainer(sender, r.me.id, 23, t37Created, "t37-tampered")
        container[container.size - 1] = (container[container.size - 1].toInt() xor 0x01).toByte()
        val author = Router(r.base, sender.id)
        val frame = author.buildSealedMessage(
            plaintext = container,
            recipientNodeId = r.me.id,
            recipientStaticPub = r.me.dhPub,
            identity = LogicalMessageIdentity.of(t37Created, nonceOf(23)),
            priority = Priority.DIRECT,
        ).copy(routingTag = SealedSender.routingTag(r.me.id, t37FixedDay))
        val before = r.repo.census()
        val result = accept(r, frame, nodeOf(0x61, 0x02))
        Assert.assertTrue("the forged signature is refused", result is InboxCommitResult.Rejected)
        Assert.assertEquals(
            "refused at the verifier, not at the envelope",
            RejectionReason.VERIFICATION_FAILED,
            (result as InboxCommitResult.Rejected).reason,
        )
        val after = r.repo.census()
        Assert.assertEquals("the verifier rejected exactly one", 1, after.verificationRejections - before.verificationRejections)
        Assert.assertEquals("no admission counted", 0, after.committedNew + after.committedDuplicate)
        Assert.assertEquals("no ACK issued", before.acksIssued, after.acksIssued)
        Assert.assertEquals("nothing was filed", 0, r.base.ackStore.countFrames())
        Assert.assertEquals("no obligation stands", 0, r.base.ackStore.countObligations())
        Assert.assertEquals("no inbox row", 0, r.base.allHeldMsgIds().size)
    }

    /** W4 -- bad msgID: the framed id no longer matches the frozen derivation;
     *  the closed ladder of the core names it. The hint still counted a hit: a
     *  matching tag admits nothing. */
    @Test
    fun testBadMsgIdRefusedByTheClosedLadder() = runTest {
        val r = rig(204)
        val sender = newLocal()
        r.keys.put(sender.id, sender.pub)
        val honest = inboundFrame(r, sender, 24)
        val flipped = honest.msgId.copyOf()
        flipped[0] = (flipped[0].toInt() xor 0x01).toByte()
        val frame = honest.copy(msgId = flipped)
        val before = r.repo.census()
        val result = accept(r, frame, nodeOf(0x62, 0x03))
        Assert.assertTrue("the mismatched id is refused", result is InboxCommitResult.Rejected)
        Assert.assertEquals(
            "the envelope's id disagrees with the frozen derivation",
            RejectionReason.MESSAGE_ID_MISMATCH,
            (result as InboxCommitResult.Rejected).reason,
        )
        val after = r.repo.census()
        Assert.assertEquals("the tag still counted as a hint", 1, after.hintHits - before.hintHits)
        Assert.assertEquals("yet nothing was admitted", 0, after.committedNew + after.committedDuplicate)
        Assert.assertEquals("nothing filed", 0, r.base.ackStore.countFrames())
        Assert.assertEquals("no inbox row", 0, r.base.allHeldMsgIds().size)
    }

    /** W5 -- wrong recipient: a validly signed container naming ANOTHER node is
     *  the wrong recipient; the frozen binding law refuses before any write. */
    @Test
    fun testWrongEmbeddedRecipientRefusedByBindingLaw() = runTest {
        val r = rig(205)
        val sender = newLocal()
        r.keys.put(sender.id, sender.pub)
        val other = newLocal() // the container names this other node instead
        val container = signedContainer(sender, other.id, 25, t37Created, "t37-other")
        val author = Router(r.base, sender.id)
        val frame = author.buildSealedMessage(
            plaintext = container,
            recipientNodeId = r.me.id, // the envelope still rotates under our tag
            recipientStaticPub = r.me.dhPub, // sealed under our DH: the unseal succeeds
            identity = LogicalMessageIdentity.of(t37Created, nonceOf(25)),
            priority = Priority.DIRECT,
        ).copy(routingTag = SealedSender.routingTag(r.me.id, t37FixedDay))
        val result = accept(r, frame, nodeOf(0x63, 0x04))
        Assert.assertTrue("the foreign recipient is refused", result is InboxCommitResult.Rejected)
        val rejected = result as InboxCommitResult.Rejected
        Assert.assertEquals("refused by the binding law itself", RejectionReason.VERIFICATION_FAILED, rejected.reason)
        Assert.assertEquals(
            "the refusal names the recipient binding",
            "embedded recipientNodeId differs from the intended local recipient",
            rejected.detail,
        )
        Assert.assertEquals("nothing filed", 0, r.base.ackStore.countFrames())
        Assert.assertEquals("no inbox row", 0, r.base.allHeldMsgIds().size)
    }

    /** W6 -- revoked sender policy: proof stands, yet policy refuses; the
     *  verifier is not even reached for a refusal (policy is not proof). */
    @Test
    fun testRevokedSenderPolicyRefusesWithoutTouchingTables() = runTest {
        val sender = newLocal()
        val r = rig(206, policy = object : RecipientSenderTrustPolicy {
            override fun admits(senderNodeId: ByteArray): Boolean = !senderNodeId.contentEquals(sender.id)
        })
        r.keys.put(sender.id, sender.pub)
        val frame = inboundFrame(r, sender, 26)
        val before = r.repo.census()
        val result = accept(r, frame, nodeOf(0x64, 0x05))
        Assert.assertTrue("the revoked sender is refused", result is InboxCommitResult.Rejected)
        Assert.assertEquals(
            "refused by policy",
            RejectionReason.SENDER_REVOKED,
            (result as InboxCommitResult.Rejected).reason,
        )
        val after = r.repo.census()
        Assert.assertEquals("policy refused exactly one", 1, after.policyRejections - before.policyRejections)
        Assert.assertEquals(
            "the cryptographic verifier was not consulted for a refusal",
            0,
            after.verificationRejections - before.verificationRejections,
        )
        Assert.assertEquals("nothing filed", 0, r.base.ackStore.countFrames())
        Assert.assertEquals("no obligation stands", 0, r.base.ackStore.countObligations())
        Assert.assertEquals("no inbox row", 0, r.base.allHeldMsgIds().size)
    }

    /** W7 -- disk failure: the whole inbox transaction rolls back; no ACK and no
     *  claimed local acceptance (the card's named negative). */
    @Test
    fun testDiskFailureYieldsNeitherAckNorClaimedAcceptance() = runTest {
        val r = rig(207)
        val sender = newLocal()
        r.keys.put(sender.id, sender.pub)
        val frame = inboundFrame(r, sender, 27)
        var raised = false
        val fault: (String) -> Unit = { point ->
            if (point == "obligation") {
                raised = true
                throw IllegalStateException("court-fault: obligation")
            }
        }
        val result = accept(r, frame, nodeOf(0x65, 0x06), fault)
        Assert.assertTrue("the fault seam was reached", raised)
        Assert.assertTrue("the commit failed", result is InboxCommitResult.Rejected)
        Assert.assertEquals(
            "storage failure, not a rejection of the sender",
            RejectionReason.STORAGE_FAILURE,
            (result as InboxCommitResult.Rejected).reason,
        )
        val census = r.repo.census()
        Assert.assertEquals("no ACK was issued", 0, census.acksIssued)
        Assert.assertEquals("the signer never stirred", 0, r.signer.asks)
        Assert.assertEquals("the whole transaction rolled back: no inbox row", 0, r.base.allHeldMsgIds().size)
        Assert.assertEquals("no obligation survived", 0, r.base.ackStore.countObligations())
        Assert.assertEquals("no frame filed", 0, r.base.ackStore.countFrames())
        // and the authority recovers: a later honest delivery still completes
        val next = inboundFrame(r, sender, 127)
        val again = accept(r, next, nodeOf(0x65, 0x06))
        Assert.assertTrue("a later delivery still completes", isAccepted(again))
    }

    /** W8 -- process kill after commit before ACK: the dying run throws at the
     *  signing seam; the durable row and the pending obligation survive; a
     *  fresh run over the SAME authorities regenerates the one true ACK. */
    @Test
    fun testProcessKillAfterCommitBeforeAckRegeneratesExactlyOnce() = runTest {
        val r = rig(208)
        val sender = newLocal()
        r.keys.put(sender.id, sender.pub)
        val frame = inboundFrame(r, sender, 28)
        val hop = nodeOf(0x66, 0x07)
        var hitSigning = false
        var died = false
        val crash: (String) -> Unit = { point ->
            if (point == "signing") {
                hitSigning = true
                throw IllegalStateException("court-fault: signing")
            }
        }
        try {
            accept(r, frame, hop, crash)
        } catch (t: IllegalStateException) {
            died = true
        }
        Assert.assertTrue("the dying run reached the signing seam", hitSigning)
        Assert.assertTrue("the death propagated out of the receiver", died)
        Assert.assertEquals("the committed inbox row survived the kill", 1, r.base.allHeldMsgIds().size)
        when (val ol = r.base.ackStore.lookupObligation(frame.msgId, r.me.id)) {
            is ObligationLookup.Found -> {
                Assert.assertEquals(
                    "the obligation stands pending, retryable",
                    AckObligationState.PENDING,
                    ol.obligation.state,
                )
            }
            else -> Assert.fail("the obligation must have survived the commit")
        }
        Assert.assertEquals("no ACK row was filed by the dying run", 0, r.base.ackStore.countFrames())
        // revival: the same frame over the same authorities, clean this time
        val revived = accept(r, frame, hop)
        Assert.assertTrue("the revived run completes", isAccepted(revived))
        val ack = ackOf(revived)
        Assert.assertNotNull("the revived run issues the ACK", ack)
        Assert.assertEquals("the signer was asked exactly once in total", 1, r.signer.asks)
        Assert.assertEquals("one frame filed", 1, r.base.ackStore.countFrames())
        Assert.assertEquals("the obligation retired with it", 0, r.base.ackStore.countObligations())
        val reference = AckFrame.build(frame.msgId, r.me.seed, r.me.id, hintOf(r.me.id), 12)
        Assert.assertTrue(
            "the regenerated answer is the one true canonical row",
            reference.encode().contentEquals(ack!!.encode()),
        )
    }

    /** W9 -- the rotating tag is a hint, not identity: a stale tag outside the
     *  window still delivers (clock skew is not authentication failure); a
     *  matching tag over a forged signature is still refused BY THE VERIFIER. */
    @Test
    fun testStaleTagStillDeliversAndMatchedTagAdmitsNothingAlone() = runTest {
        // leg one: the stale (out-of-window) tag is charged and delivered
        val r1 = rig(209)
        val s1 = newLocal()
        r1.keys.put(s1.id, s1.pub)
        val stale = inboundFrame(r1, s1, 29)
            .copy(routingTag = SealedSender.routingTag(r1.me.id, t37FixedDay - 3L))
        val beforeOne = r1.repo.census()
        val resOne = accept(r1, stale, nodeOf(0x67, 0x08))
        Assert.assertTrue("the stale-tagged frame still stands accepted", isAccepted(resOne))
        val afterOne = r1.repo.census()
        Assert.assertEquals("the miss was charged to the hint census", 1, afterOne.hintMissesUnsealed - beforeOne.hintMissesUnsealed)
        Assert.assertEquals("and the frame was unsealed notwithstanding", 1, afterOne.unsealedAccepted - beforeOne.unsealedAccepted)
        // leg two: a matched tag over a forged signature -- the verifier refuses
        val r2 = rig(1209)
        val s2 = newLocal()
        r2.keys.put(s2.id, s2.pub)
        val container = signedContainer(s2, r2.me.id, 129, t37Created, "t37-forged-under-honest-tag")
        container[container.size - 10] = (container[container.size - 10].toInt() xor 0x40).toByte()
        val forged = Router(r2.base, s2.id).buildSealedMessage(
            plaintext = container,
            recipientNodeId = r2.me.id,
            recipientStaticPub = r2.me.dhPub,
            identity = LogicalMessageIdentity.of(t37Created, nonceOf(129)),
            priority = Priority.DIRECT,
        ).copy(routingTag = SealedSender.routingTag(r2.me.id, t37FixedDay)) // the honest, MATCHING tag
        val beforeTwo = r2.repo.census()
        val resTwo = accept(r2, forged, nodeOf(0x68, 0x09))
        Assert.assertTrue("the forgery is refused", resTwo is InboxCommitResult.Rejected)
        val afterTwo = r2.repo.census()
        Assert.assertEquals("the tag matched, yet the match admitted nothing", 1, afterTwo.hintHits - beforeTwo.hintHits)
        Assert.assertEquals(
            "the refusal is the verifier's, not the tag's",
            RejectionReason.VERIFICATION_FAILED,
            (resTwo as InboxCommitResult.Rejected).reason,
        )
        Assert.assertEquals("nothing filed", 0, r2.base.ackStore.countFrames())
    }

    /** W10 -- the immediate hop is not the sender: one message delivered via
     *  two distinct hop tokens is admitted once, duplicated honestly, and the
     *  stored row keeps the FIRST filing's receipt (non-replenishing). */
    @Test
    fun testImmediateHopIsNotTheSenderAndReceiptStands() = runTest {
        val r = rig(210)
        val sender = newLocal()
        r.keys.put(sender.id, sender.pub)
        val frame = inboundFrame(r, sender, 30)
        val hopA = nodeOf(0x70A, 0x21)
        val hopB = nodeOf(0x70B, 0x22)
        Assert.assertTrue("the hops are distinct tokens", !hopA.contentEquals(hopB))
        Assert.assertTrue("neither hop is the sender", !hopA.contentEquals(sender.id) && !hopB.contentEquals(sender.id))
        val first = accept(r, frame, hopA)
        Assert.assertTrue("the first delivery is accepted", isAccepted(first))
        val second = accept(r, frame, hopB)
        Assert.assertTrue(
            "the second delivery via a different hop duplicates honestly",
            second is InboxCommitResult.Duplicate,
        )
        Assert.assertEquals("no re-signature across hops", 1, r.signer.asks)
        when (val pl = r.base.ackStore.candidatesForPair(frame.msgId, r.me.id, 4)) {
            is PairList.Records -> {
                Assert.assertEquals("exactly one filed row", 1, pl.records.size)
                val row = pl.records[0]
                val rf = row.receivedFrom
                Assert.assertTrue(
                    "the row keeps the first filing's receipt: later hops do not replenish the durable row",
                    rf != null && rf.contentEquals(hopA),
                )
                Assert.assertEquals(
                    "the row is recipient-verified",
                    AckVerificationClass.VERIFIED_RECIPIENT,
                    row.verificationClass,
                )
                Assert.assertTrue(
                    "the row names us as its recipient",
                    row.recipientNodeId.contentEquals(r.me.id),
                )
            }
            else -> Assert.fail("the pair census must answer with records")
        }
        val census = r.repo.census()
        Assert.assertEquals("the hop token never entered any identity decision", 0, census.acksRefusedKey)
    }

    /** W11 -- canonical ACK bytes end to end through the production entry:
     *  type ACK, 80-byte payload = signature64||recipient16, tag the recipient
     *  hint, ttl 12 (the section-14 production constant), hop 0, flags 0; the
     *  frozen authenticator accepts it under the pinned key; the message and
     *  its ACK coexist in the two namespaces under one msg id. */
    @Test
    fun testCanonicalAckBytesEndToEndThroughTheProductionEntry() = runTest {
        val r = rig(211)
        val sender = newLocal()
        r.keys.put(sender.id, sender.pub)
        val frame = inboundFrame(r, sender, 31)
        val result = accept(r, frame, nodeOf(0x69, 0x0A))
        val ack = ackOf(result)
        Assert.assertNotNull("the production entry issued the ACK", ack)
        Assert.assertEquals("type ACK", TypeV2.ACK, ack!!.type)
        Assert.assertEquals("payload is signature64||recipient16", 80, ack.payload.size)
        Assert.assertTrue(
            "the tail names the recipient",
            ack.payload.copyOfRange(64, 80).contentEquals(r.me.id),
        )
        Assert.assertTrue("the id is the original message's", ack.msgId.contentEquals(frame.msgId))
        Assert.assertTrue(
            "the tag is the canonical recipient hint",
            ack.routingTag.contentEquals(hintOf(r.me.id)),
        )
        Assert.assertEquals("ttl is the production constant", 12, ack.ttl)
        Assert.assertEquals("hop stands at zero", 0, ack.hopCount)
        Assert.assertEquals("flags stay canonical", 0, ack.flags)
        when (val pl = r.base.ackStore.candidatesForPair(frame.msgId, r.me.id, 4)) {
            is PairList.Records -> {
                Assert.assertEquals("one row filed", 1, pl.records.size)
                val row = pl.records[0]
                val stored = FrameV2.decode(row.encodedFrame)
                Assert.assertNotNull("the stored encoding decodes", stored)
                Assert.assertTrue(
                    "the frozen authenticator accepts it",
                    r.auth.verify(frame.msgId, r.me.id, stored!!),
                )
                val digest = AckCacheKey.compute(row.msgId, row.recipientNodeId, row.signature)
                Assert.assertNotNull("the cache key is computable", digest)
                Assert.assertTrue(
                    "the key is the honest digest of the row's own parts",
                    row.ackKey.contentEquals(digest!!),
                )
            }
            else -> Assert.fail("a row must stand filed")
        }
        Assert.assertEquals("the message stands held", 1, r.base.allHeldMsgIds().size)
        Assert.assertEquals("the answer lives beside it", 1, r.base.ackStore.countFrames())
        val held = r.base.allHeldOrderedByPriority()
        Assert.assertEquals("one held frame", 1, held.size)
        Assert.assertTrue(
            "the held row is the original bytes",
            held[0].encode().contentEquals(frame.encode()),
        )
    }
}
