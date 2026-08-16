package io.godstone.mesh

import io.godstone.core.crypto.X25519Keys
import io.godstone.mesh.router.BloomDigest
import io.godstone.mesh.router.Router
import io.godstone.mesh.store.InMemoryMessageStore
import io.godstone.mesh.store.MessageStore
import io.godstone.mesh.store.PersistResult
import io.godstone.mesh.wire.v2.FrameV2
import io.godstone.mesh.wire.v2.MessageId
import io.godstone.mesh.wire.v2.Priority
import io.godstone.mesh.wire.v2.SosFrameValidator
import io.godstone.mesh.wire.v2.TypeV2
import kotlinx.coroutines.async
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import java.security.SecureRandom
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

/**
 * Router behaviour under the conditions that actually occur in a blackout:
 * loops, duplicates, dying batteries and messages nobody can deliver yet.
 *
 * These are unit tests over the routing logic only - no Bluetooth, no threads.
 * The radio layer is exercised by meshsim instead. Runs on the canonical GMP/2.1
 * FrameV2 path (ADR-001/008): 16-byte content-derived msg_id, priority from the
 * flags PRIORITY_MASK, no header-timestamp age gate, and no relay PoW gate (PoW
 * is recipient-side, verified after SealedSender.open -- see ProofOfWorkTest).
 */
class RouterTest {

    private val selfNodeId = ByteArray(16) { 0x0A }
    private val peerC = ByteArray(16) { 0x0C }

    /** Deterministic, distinct 16-byte msg_id for a given seed. */
    private fun msgId(seed: Int): ByteArray = ByteArray(16) { ((seed + it) and 0xFF).toByte() }

    private fun frame(
        msgId: ByteArray,
        ttl: Int = 8,
        priority: Priority = Priority.DIRECT,
        type: TypeV2 = TypeV2.MESSAGE,
        payload: ByteArray = ByteArray(32)
    ): FrameV2 = FrameV2(
        type = type,
        msgId = msgId,
        routingTag = ByteArray(4),
        ttl = ttl,
        hopCount = 0,
        flags = Priority.toFlags(priority),
        payload = payload
    )

    @Test
    fun `duplicate message is not relayed twice`() = runTest {
        val store = InMemoryMessageStore()
        val router = Router(store, selfNodeId)
        val id = msgId(1)
        val f = frame(id)

        // First sighting is novel: persist and offer for relay.
        assertTrue(router.onFrameReceived(f, fromPeer = peerC))
        // Same id arriving from a different neighbour is the flood coming back
        // around. Relaying it again is how a mesh melts down.
        assertFalse(router.onFrameReceived(f, fromPeer = peerC))
    }

    @Test
    fun `frame with exhausted ttl is dropped`() = runTest {
        val store = InMemoryMessageStore()
        val router = Router(store, selfNodeId)
        assertFalse(router.onFrameReceived(frame(msgId(2), ttl = 0), fromPeer = peerC))
    }

    @Test
    fun `ttl above one is relayed and decremented on the forward copy`() = runTest {
        val store = InMemoryMessageStore()
        val router = Router(store, selfNodeId)
        val f = frame(msgId(3), ttl = 5)

        assertTrue(router.onFrameReceived(f, fromPeer = peerC))
        val fwd = router.forwardCopy(f)
        assertEquals(4, fwd.ttl)
        assertEquals(1, fwd.hopCount)
    }

    @Test
    fun `group priority is accepted by the relay - PoW is recipient-side not a relay gate`() = runTest {
        val store = InMemoryMessageStore()
        val router = Router(store, selfNodeId)
        // GMP/2.1 (ADR-001 §3): the PoW nonce lives inside the sealed payload, so a
        // relay cannot verify it and does not gate on it. GROUP traffic is relayed;
        // the recipient verifies the stamp after SealedSender.open. The GMP/1
        // relay PoW gate is gone.
        val f = frame(msgId(5), priority = Priority.GROUP, payload = ByteArray(32))
        assertTrue(router.onFrameReceived(f, fromPeer = peerC))
    }

    @Test
    fun `direct priority is accepted`() = runTest {
        val store = InMemoryMessageStore()
        val router = Router(store, selfNodeId)
        assertTrue(router.onFrameReceived(frame(msgId(6), priority = Priority.DIRECT), fromPeer = peerC))
    }

    @Test
    fun `buildSos produces a max-ttl structurally-valid SOS frame with a 16-byte content-derived msg_id`() {
        val store = InMemoryMessageStore()
        val router = Router(store, selfNodeId)
        val sos = router.buildSos("help".toByteArray())

        assertEquals(TypeV2.SOS, sos.type)
        assertEquals(FrameV2.MAX_TTL, sos.ttl)
        assertEquals(16, sos.msgId.size)
        assertTrue(sos.flags and FrameV2.ACK_REQ != 0)
        assertTrue(sos.flags and FrameV2.RELAY_OK != 0)
        // SOS payload is structurally valid per SosFrameValidator (patch 15).
        assertEquals(SosFrameValidator.Verdict.OK, SosFrameValidator.validate(sos))
        // Round-trips through the GMP/2.1 codec byte-identically.
        val rt = FrameV2.decode(sos.encode())
        assertTrue(rt != null && rt.msgId.contentEquals(sos.msgId))
    }

    @Test
    fun `buildSos msg_id is content-derived - distinct payloads get distinct ids`() {
        val store = InMemoryMessageStore()
        val router = Router(store, selfNodeId)
        val a = router.buildSos("help".toByteArray())
        val b = router.buildSos("fire".toByteArray())
        assertNotEquals(a.msgId.toList(), b.msgId.toList())
    }

    @Test
    fun `framesPeerLack returns held frames absent from the peer digest`() = runTest {
        val store = InMemoryMessageStore()
        val router = Router(store, selfNodeId)
        val id = msgId(7)
        assertTrue(router.onFrameReceived(frame(id), fromPeer = peerC))

        // An empty bloom means the peer has nothing: offer everything we hold.
        val empty = BloomDigest()
        val lacks = router.framesPeerLacks(empty, 8)
        assertEquals(1, lacks.size)
        assertTrue(lacks[0].msgId.contentEquals(id))

        // A bloom that already contains the msg_id means the peer has it: offer nothing.
        val full = BloomDigest().apply { add(id) }
        assertTrue(router.framesPeerLacks(full, 8).isEmpty())
    }

    @Test
    fun `current digest advertises every held msg_id`() = runTest {
        val store = InMemoryMessageStore()
        val router = Router(store, selfNodeId)
        val id = msgId(8)
        assertTrue(router.onFrameReceived(frame(id), fromPeer = peerC))

        val digest = router.currentDigest()
        assertTrue(digest.mightContain(id))
        assertFalse(digest.mightContain(msgId(9999)))
    }

    // --- Stage 4B: persist result checked before forward (ADR-004) ---

    @Test
    fun `persist failure prevents relay and inbound emit`() = runTest {
        // A store whose persist always fails exercises the persist gate in
        // onFrameReceived without a real engine. The frame is novel and its TTL
        // is healthy, so the only thing that can return false here is the
        // persist-before-forward gate: a frame this node cannot durably hold is
        // NOT relayed (false) and NOT emitted to inbound -- forwarding what this
        // node cannot itself carry would let the only copy be dropped.
        val router = Router(FailingMessageStore(), selfNodeId)
        val f = frame(msgId(11), ttl = 5)

        assertFalse(router.onFrameReceived(f, fromPeer = peerC))
        // onFrameReceived returned before `_inbound.emit`, so nothing reached the
        // inbound flow (contrast the working-store tests above, which return true
        // and advertise the held id in the digest).
        assertFalse(router.currentDigest().mightContain(f.msgId))
    }

    // --- Stage 4B.1 / B1: a persist failure must NOT poison retry ---

    @Test
    fun `persist failure does not poison retry - same msg_id accepted exactly once after recovery`() =
        runTest(UnconfinedTestDispatcher()) {
        // B1: the durable store is the authority and the in-memory dedup window
        // is only an optimisation populated AFTER durable acceptance. So a frame
        // whose first persist FAILS must not be permanently marked seen -- after
        // the store recovers the same msg_id must be accepted, held, forwarded
        // and emitted exactly once, and a third (now-duplicate) arrival must be
        // suppressed.
        val store = FailThenSucceedStore()
        val router = Router(store, selfNodeId)
        val received = ArrayList<FrameV2>()
        // UnconfinedTestDispatcher: the collector runs eagerly, so each `emit`
        // inside onFrameReceived is delivered to `received` synchronously (no
        // manual runCurrent flush needed, and no virtual-time hang from the
        // infinite collect before it is cancelled).
        val collector = launch { router.inbound.collect { received.add(it) } }
        val id = msgId(21)
        val f = frame(id, ttl = 5)

        // 1st arrival: store fails -> FAILED_STORAGE -> NOT marked seen, NOT
        // emitted, NOT relayed. Critically the msg_id is NOT poisoned into seen.
        assertFalse(router.onFrameReceived(f, fromPeer = peerC))
        assertFalse(router.currentDigest().mightContain(id), "failed persist must not hold the frame")
        assertTrue(received.isEmpty(), "failed persist must not emit to inbound")

        // 2nd arrival, SAME msg_id: store now succeeds -> HELD_NEW -> held,
        // emitted, relayed. This is the retry that B1 guarantees is possible.
        assertTrue(router.onFrameReceived(f, fromPeer = peerC))
        assertEquals(1, received.size, "the recovered retry emitted to inbound exactly once")

        // 3rd arrival, SAME msg_id: now a duplicate (seen hit) -> suppressed.
        assertFalse(router.onFrameReceived(f, fromPeer = peerC))

        collector.cancel()
        assertEquals(1, received.size, "inbound emitted exactly once (the recovered retry)")
        assertTrue(received[0].msgId.contentEquals(id))
        assertTrue(store.persistCalls >= 2, "the failed first attempt did not satisfy the durable UNIQUE")
    }

    @Test
    fun `durable UNIQUE catches a duplicate the LRU aged out - authoritative dedup`() = runTest {
        // B1: with the durable store as authority, a duplicate whose id has aged
        // out of the small in-memory LRU (but is still durably held) MUST be
        // caught by the durable UNIQUE(msg_id) and reported HELD_DUPLICATE -- not
        // re-forwarded. Uses a tiny seen cache so the id evicts without 16384
        // frames.
        val store = InMemoryMessageStore()
        val router = Router(store, selfNodeId, seenCacheSize = 2)
        val id = msgId(31)
        val f = frame(id, ttl = 5)

        // Persist id -> HELD_NEW, seen=[id].
        assertTrue(router.onFrameReceived(f, fromPeer = peerC))
        // Two distinct ids evict `id` from the 2-entry LRU: seen=[other1,other2].
        assertTrue(router.onFrameReceived(frame(msgId(32), ttl = 5), fromPeer = peerC))
        assertTrue(router.onFrameReceived(frame(msgId(33), ttl = 5), fromPeer = peerC))
        // `id` is gone from the LRU but still durably held. Re-offering it is a
        // LRU MISS -> persist -> HELD_DUPLICATE -> suppressed (NOT re-forwarded).
        assertFalse(router.onFrameReceived(f, fromPeer = peerC))
        // Still held exactly once.
        val digest = router.currentDigest()
        assertTrue(digest.mightContain(id))
        assertFalse(digest.mightContain(msgId(999)))
    }

    @Test
    fun `two concurrent same-msg_id arrivals forward at most once`() =
        runTest(UnconfinedTestDispatcher()) {
        // B1: at-most-once forwarding under concurrency. Two "simultaneous"
        // arrivals of the same msg_id must result in exactly one forward and one
        // inbound emission. The Router mutex serialises the bodies; the first
        // persist returns HELD_NEW (forward) and marks seen, the second is then a
        // duplicate (caught by the LRU fast-path or the durable UNIQUE) and is
        // suppressed. UnconfinedTestDispatcher runs each `async` body eagerly up
        // to its first suspension, so the two arrivals execute deterministically
        // (r1 completes its non-suspending body before r2 starts) while still
        // exercising the mutex gate that would serialise truly concurrent arrivals.
        val store = InMemoryMessageStore()
        val router = Router(store, selfNodeId)
        val received = ArrayList<FrameV2>()
        val collector = launch { router.inbound.collect { received.add(it) } }
        val id = msgId(22)
        val f = frame(id, ttl = 5)

        val r1 = async { router.onFrameReceived(f, fromPeer = peerC) }
        val r2 = async { router.onFrameReceived(f, fromPeer = ByteArray(16) { 0x0D }) }
        val results = listOf(r1.await(), r2.await())

        collector.cancel()
        assertEquals(1, results.count { it }, "exactly one of the two arrivals forwarded")
        assertEquals(1, received.size, "inbound emitted exactly once")
    }

    @Test
    fun `buildSealedMessage with LogicalMessageIdentity and openSealedMessage returns Accepted with PolicyCheckedOpenedMessage`() = runTest {
        val store = InMemoryMessageStore()
        val router = Router(store, selfNodeId)

        val recipientKeys = X25519Keys.generate(SecureRandom())
        val recipientPriv = recipientKeys.priv
        val recipientPub = recipientKeys.pub
        val recipientNodeId = ByteArray(16) { 0x55 }

        val plaintext = "Hello secure mesh".toByteArray()
        val identity = io.godstone.mesh.wire.v2.LogicalMessageIdentity.of(1700000000L, ByteArray(16) { 0x01 })
        val frame = router.buildSealedMessage(
            plaintext = plaintext,
            recipientNodeId = recipientNodeId,
            recipientStaticPub = recipientPub,
            identity = identity,
            priority = Priority.DIRECT
        )

        assertEquals(TypeV2.MESSAGE, frame.type)
        assertEquals(16, frame.msgId.size)

        val res = router.openSealedMessage(frame, recipientPriv)
        assertTrue(res is io.godstone.mesh.router.OpenMessageResult.Accepted, "Expected OpenMessageResult.Accepted")
        val opened = res.message
        assertTrue(selfNodeId.contentEquals(opened.senderNodeId))
        assertEquals(identity, opened.identity)
        assertEquals(Priority.DIRECT, opened.priority)
        assertTrue(opened.powNonce.all { it == 0.toByte() })
        assertTrue(plaintext.contentEquals(opened.plaintext))

        // Tampering negative control 1: Mutated header msg_id -> MessageIdMismatch
        val tamperedMsgId = frame.copy(msgId = ByteArray(16) { 0x99.toByte() })
        val resTamperedId = router.openSealedMessage(tamperedMsgId, recipientPriv)
        assertTrue(resTamperedId is io.godstone.mesh.router.OpenMessageResult.MessageIdMismatch)

        // Tampering negative control 2: Wrong recipient private key -> NotForUs
        val wrongPriv = X25519Keys.generate(SecureRandom()).priv
        val resWrongKey = router.openSealedMessage(frame, wrongPriv)
        assertTrue(resWrongKey is io.godstone.mesh.router.OpenMessageResult.NotForUs)
    }

    @Test
    fun `group message with HAS_POW mines pow with message_nonce and verifies on open`() = runTest {
        val store = InMemoryMessageStore()
        val router = Router(store, selfNodeId)

        val recipientKeys = X25519Keys.generate(SecureRandom())
        val recipientPriv = recipientKeys.priv
        val recipientPub = recipientKeys.pub
        val recipientNodeId = ByteArray(16) { 0x77 }

        val plaintext = "Group message with PoW".toByteArray()
        val identity = io.godstone.mesh.wire.v2.LogicalMessageIdentity.createNew()

        // GROUP priority sets HAS_POW and mines 20-bit PoW
        val frame = router.buildSealedMessage(
            plaintext = plaintext,
            recipientNodeId = recipientNodeId,
            recipientStaticPub = recipientPub,
            identity = identity,
            priority = Priority.GROUP
        )

        assertTrue(frame.flags and FrameV2.HAS_POW != 0, "HAS_POW must be set for GROUP priority")

        val res = router.openSealedMessage(frame, recipientPriv)
        assertTrue(res is io.godstone.mesh.router.OpenMessageResult.Accepted, "Valid PoW message must be Accepted")
        val opened = res.message
        assertEquals(Priority.GROUP, opened.priority)
        assertTrue(opened.plaintext.contentEquals(plaintext))
    }

    @Test
    fun `broadcast message with HAS_POW mines pow and verifies on open`() = runTest {
        val store = InMemoryMessageStore()
        val router = Router(store, selfNodeId)

        val recipientKeys = X25519Keys.generate(SecureRandom())
        val recipientPriv = recipientKeys.priv
        val recipientPub = recipientKeys.pub
        val recipientNodeId = ByteArray(16) { 0x88.toByte() }

        val plaintext = "Broadcast flood notice".toByteArray()
        val identity = io.godstone.mesh.wire.v2.LogicalMessageIdentity.createNew()

        val frame = router.buildSealedMessage(
            plaintext = plaintext,
            recipientNodeId = recipientNodeId,
            recipientStaticPub = recipientPub,
            identity = identity,
            priority = Priority.BROADCAST
        )

        assertTrue(frame.flags and FrameV2.HAS_POW != 0)
        val res = router.openSealedMessage(frame, recipientPriv)
        assertTrue(res is io.godstone.mesh.router.OpenMessageResult.Accepted)
        val opened = res.message
        assertEquals(Priority.BROADCAST, opened.priority)
    }

    /**
     * CRITICAL SECURITY TEST: Downgrade attack
     * Attacker changes header priority from GROUP to DIRECT and strips HAS_POW to bypass PoW verification.
     * Recipient MUST reject with PolicyMismatch because the authenticated sealed priority is GROUP.
     */
    @Test
    fun `downgrade attack on GROUP message to DIRECT header is rejected with PolicyMismatch`() = runTest {
        val store = InMemoryMessageStore()
        val router = Router(store, selfNodeId)

        val recipientKeys = X25519Keys.generate(SecureRandom())
        val recipientPriv = recipientKeys.priv
        val recipientPub = recipientKeys.pub
        val recipientNodeId = ByteArray(16) { 0x77 }

        val plaintext = "High-priority group alert".toByteArray()
        val frame = router.authorSealedMessage(plaintext, recipientNodeId, recipientPub, priority = Priority.GROUP)

        // Attacker mutates header: clears HAS_POW, sets DIRECT priority
        val downgradedFlags = (frame.flags and FrameV2.HAS_POW.inv() and FrameV2.PRIORITY_MASK.inv()) or
            Priority.toFlags(Priority.DIRECT)
        val downgradedFrame = frame.copy(flags = downgradedFlags)

        val res = router.openSealedMessage(downgradedFrame, recipientPriv)
        assertTrue(res is io.godstone.mesh.router.OpenMessageResult.PolicyMismatch,
            "Downgraded priority header must be rejected with PolicyMismatch, got $res")
    }

    @Test
    fun `header priority mismatch against sealed priority is rejected with PolicyMismatch`() = runTest {
        val store = InMemoryMessageStore()
        val router = Router(store, selfNodeId)

        val recipientKeys = X25519Keys.generate(SecureRandom())
        val recipientPriv = recipientKeys.priv
        val recipientPub = recipientKeys.pub
        val recipientNodeId = ByteArray(16) { 0x77 }

        val plaintext = "Policy check message".toByteArray()
        val frame = router.authorSealedMessage(plaintext, recipientNodeId, recipientPub, priority = Priority.GROUP)

        // Mutate header priority to BROADCAST while leaving HAS_POW
        val mutatedFlags = (frame.flags and FrameV2.PRIORITY_MASK.inv()) or Priority.toFlags(Priority.BROADCAST)
        val mutatedFrame = frame.copy(flags = mutatedFlags)

        val res = router.openSealedMessage(mutatedFrame, recipientPriv)
        assertTrue(res is io.godstone.mesh.router.OpenMessageResult.PolicyMismatch)
    }

    @Test
    fun `missing SEALED flag is rejected with MissingSealedFlag`() = runTest {
        val store = InMemoryMessageStore()
        val router = Router(store, selfNodeId)

        val recipientKeys = X25519Keys.generate(SecureRandom())
        val recipientPriv = recipientKeys.priv
        val recipientPub = recipientKeys.pub
        val recipientNodeId = ByteArray(16) { 0x55 }

        val frame = router.authorSealedMessage("test".toByteArray(), recipientNodeId, recipientPub)
        val unsealedFrame = frame.copy(flags = frame.flags and FrameV2.SEALED.inv())

        val res = router.openSealedMessage(unsealedFrame, recipientPriv)
        assertTrue(res is io.godstone.mesh.router.OpenMessageResult.MissingSealedFlag)
    }

    @Test
    fun `wrong frame type is rejected with WrongFrameType`() = runTest {
        val store = InMemoryMessageStore()
        val router = Router(store, selfNodeId)

        val recipientKeys = X25519Keys.generate(SecureRandom())
        val recipientPriv = recipientKeys.priv
        val recipientPub = recipientKeys.pub
        val recipientNodeId = ByteArray(16) { 0x55 }

        val frame = router.authorSealedMessage("test".toByteArray(), recipientNodeId, recipientPub)
        val sosFrame = frame.copy(type = TypeV2.SOS)

        val res = router.openSealedMessage(sosFrame, recipientPriv)
        assertTrue(res is io.godstone.mesh.router.OpenMessageResult.WrongFrameType)
    }

    @Test
    fun `direct message with HAS_POW flag is rejected with PolicyMismatch`() = runTest {
        val store = InMemoryMessageStore()
        val router = Router(store, selfNodeId)

        val recipientKeys = X25519Keys.generate(SecureRandom())
        val recipientPriv = recipientKeys.priv
        val recipientPub = recipientKeys.pub
        val recipientNodeId = ByteArray(16) { 0x55 }

        val frame = router.authorSealedMessage("test".toByteArray(), recipientNodeId, recipientPub, priority = Priority.DIRECT)
        val invalidFrame = frame.copy(flags = frame.flags or FrameV2.HAS_POW)

        val res = router.openSealedMessage(invalidFrame, recipientPriv)
        assertTrue(res is io.godstone.mesh.router.OpenMessageResult.PolicyMismatch)
    }

    @Test
    fun `group message with stripped HAS_POW flag is rejected with PolicyMismatch`() = runTest {
        val store = InMemoryMessageStore()
        val router = Router(store, selfNodeId)

        val recipientKeys = X25519Keys.generate(SecureRandom())
        val recipientPriv = recipientKeys.priv
        val recipientPub = recipientKeys.pub
        val recipientNodeId = ByteArray(16) { 0x77 }

        val frame = router.authorSealedMessage("test".toByteArray(), recipientNodeId, recipientPub, priority = Priority.GROUP)
        val invalidFrame = frame.copy(flags = frame.flags and FrameV2.HAS_POW.inv())

        val res = router.openSealedMessage(invalidFrame, recipientPriv)
        assertTrue(res is io.godstone.mesh.router.OpenMessageResult.PolicyMismatch)
    }

    @Test
    fun `direct message with non-zero powNonce is rejected with PolicyMismatch`() = runTest {
        val store = InMemoryMessageStore()
        val router = Router(store, selfNodeId)

        val recipientKeys = X25519Keys.generate(SecureRandom())
        val recipientPriv = recipientKeys.priv
        val recipientPub = recipientKeys.pub
        val recipientNodeId = ByteArray(16) { 0x55 }

        // Manually seal a DIRECT message with non-zero powNonce
        val identity = io.godstone.mesh.wire.v2.LogicalMessageIdentity.createNew()
        val badPowNonce = ByteArray(8) { 0x01 }
        val plaintext = "test".toByteArray()
        val sealedInner = identity.messageNonce + badPowNonce + identity.createdAtLe() + byteArrayOf(Priority.DIRECT.code.toByte()) + plaintext
        val sealed = io.godstone.mesh.seal.SealedSender.seal(sealedInner, selfNodeId, recipientPub)
        val msgId = MessageId.derive(selfNodeId, identity, plaintext)
        val frame = FrameV2(
            type = TypeV2.MESSAGE,
            msgId = msgId,
            routingTag = ByteArray(4),
            ttl = 8,
            hopCount = 0,
            flags = FrameV2.SEALED or Priority.toFlags(Priority.DIRECT),
            payload = sealed
        )

        val res = router.openSealedMessage(frame, recipientPriv)
        assertTrue(res is io.godstone.mesh.router.OpenMessageResult.PolicyMismatch)
    }

    @Test
    fun `invalid sealed priority code is rejected with PolicyMismatch`() = runTest {
        val store = InMemoryMessageStore()
        val router = Router(store, selfNodeId)

        val recipientKeys = X25519Keys.generate(SecureRandom())
        val recipientPriv = recipientKeys.priv
        val recipientPub = recipientKeys.pub
        val recipientNodeId = ByteArray(16) { 0x55 }

        // Sealed inner with priority byte 0 (SOS, invalid for MESSAGE) or 99
        val identity = io.godstone.mesh.wire.v2.LogicalMessageIdentity.createNew()
        val powNonce = ByteArray(8)
        val plaintext = "test".toByteArray()
        val sealedInner = identity.messageNonce + powNonce + identity.createdAtLe() + byteArrayOf(0.toByte()) + plaintext
        val sealed = io.godstone.mesh.seal.SealedSender.seal(sealedInner, selfNodeId, recipientPub)
        val msgId = MessageId.derive(selfNodeId, identity, plaintext)
        val frame = FrameV2(
            type = TypeV2.MESSAGE,
            msgId = msgId,
            routingTag = ByteArray(4),
            ttl = 8,
            hopCount = 0,
            flags = FrameV2.SEALED or Priority.toFlags(Priority.DIRECT),
            payload = sealed
        )

        val res = router.openSealedMessage(frame, recipientPriv)
        assertTrue(res is io.godstone.mesh.router.OpenMessageResult.PolicyMismatch)
    }

    @Test
    fun `unknown header priority fails closed on receive and open`() = runTest {
        val store = InMemoryMessageStore()
        val router = Router(store, selfNodeId)

        // Priority code 5 in flags (bits 8..10 = 0x0500)
        val unknownFlags = 5 shl 8
        val f = frame(msgId(30), priority = Priority.DIRECT).copy(flags = unknownFlags)

        // onFrameReceived must fail closed and drop frame
        assertFalse(router.onFrameReceived(f, fromPeer = peerC))

        val recipientKeys = X25519Keys.generate(SecureRandom())
        val res = router.openSealedMessage(f.copy(flags = unknownFlags or FrameV2.SEALED), recipientKeys.priv)
        assertTrue(res is io.godstone.mesh.router.OpenMessageResult.PolicyMismatch || res is io.godstone.mesh.router.OpenMessageResult.NotForUs)
    }

    @Test
    fun `truncated sealed inner payload is rejected with Malformed`() = runTest {
        val store = InMemoryMessageStore()
        val router = Router(store, selfNodeId)

        val recipientKeys = X25519Keys.generate(SecureRandom())
        val recipientPriv = recipientKeys.priv
        val recipientPub = recipientKeys.pub

        // Seal an inner payload of only 20 bytes (< 29 bytes prefix)
        val shortInner = ByteArray(20)
        val sealed = io.godstone.mesh.seal.SealedSender.seal(shortInner, selfNodeId, recipientPub)
        val frame = FrameV2(
            type = TypeV2.MESSAGE,
            msgId = ByteArray(16),
            routingTag = ByteArray(4),
            ttl = 8,
            hopCount = 0,
            flags = FrameV2.SEALED or Priority.toFlags(Priority.DIRECT),
            payload = sealed
        )

        val res = router.openSealedMessage(frame, recipientPriv)
        assertTrue(res is io.godstone.mesh.router.OpenMessageResult.Malformed)
    }

    @Test
    fun `router constructor defensively copies selfNodeId`() = runTest {
        val mutableNodeId = ByteArray(16) { 0x44 }
        val store = InMemoryMessageStore()
        val router = Router(store, mutableNodeId)

        // Mutate original array
        mutableNodeId.fill(0xFF.toByte())

        val recipientKeys = X25519Keys.generate(SecureRandom())
        val frame = router.authorSealedMessage("test".toByteArray(), ByteArray(16) { 0x55 }, recipientKeys.pub)

        val res = router.openSealedMessage(frame, recipientKeys.priv)
        assertTrue(res is io.godstone.mesh.router.OpenMessageResult.Accepted)
        val opened = res.message
        assertTrue(opened.senderNodeId.all { it == 0x44.toByte() }, "Router selfNodeId must not be mutated from external array")
    }

    @Test
    fun `concurrent authorSealedMessage to alice and bob produce distinct msg_ids and both are Accepted`() = runTest {
        val store = InMemoryMessageStore()
        val router = Router(store, selfNodeId)

        val aliceKeys = X25519Keys.generate(SecureRandom())
        val alicePriv = aliceKeys.priv
        val alicePub = aliceKeys.pub
        val aliceNodeId = ByteArray(16) { 0x11 }

        val bobKeys = X25519Keys.generate(SecureRandom())
        val bobPriv = bobKeys.priv
        val bobPub = bobKeys.pub
        val bobNodeId = ByteArray(16) { 0x22 }

        val content = "rendezvous at checkpoint 4".toByteArray()
        val frameAlice = router.authorSealedMessage(content, aliceNodeId, alicePub)
        val frameBob = router.authorSealedMessage(content, bobNodeId, bobPub)

        assertNotEquals(frameAlice.msgId.toList(), frameBob.msgId.toList())

        val resAlice = router.openSealedMessage(frameAlice, alicePriv)
        val resBob = router.openSealedMessage(frameBob, bobPriv)

        assertTrue(resAlice is io.godstone.mesh.router.OpenMessageResult.Accepted)
        assertTrue(resBob is io.godstone.mesh.router.OpenMessageResult.Accepted)
    }

    @Test
    fun `retry semantics retransmit the exact persisted FrameV2 without altering msg_id`() = runTest {
        val store = InMemoryMessageStore()
        val router = Router(store, selfNodeId)

        val recipientKeys = X25519Keys.generate(SecureRandom())
        val recipientPub = recipientKeys.pub
        val recipientNodeId = ByteArray(16) { 0x33 }

        val content = "durable broadcast packet".toByteArray()
        val frame = router.authorSealedMessage(content, recipientNodeId, recipientPub)

        // Persist frame
        store.persist(frame, selfNodeId)

        // Retry re-reads the held frame and preserves exact msg_id
        val held = store.allHeldOrderedByPriority()
        assertEquals(1, held.size)
        assertTrue(held[0].msgId.contentEquals(frame.msgId))
        assertTrue(held[0].payload.contentEquals(frame.payload))
    }
}

/**
 * A [MessageStore] whose `persist` always fails -- exercises the persist gate in
 * `Router.onFrameReceived` (ADR-004 / Stage 4B) without a real engine. The other
 * methods report an empty store, which is consistent with "nothing was held".
 */
private class FailingMessageStore : MessageStore {
    override suspend fun persist(frame: FrameV2, receivedFrom: ByteArray): PersistResult =
        PersistResult.FAILED_STORAGE
    override suspend fun allHeldOrderedByPriority(): List<FrameV2> = emptyList()
    override suspend fun allHeldMsgIds(): List<ByteArray> = emptyList()
    override suspend fun forEachHeldOrderedByPriority(visit: (FrameV2) -> Boolean) {}
    override suspend fun forEachHeldMsgId(visit: (ByteArray) -> Boolean) {}
}

/**
 * B1 test fake: the first persist of a given msg_id FAILS (FAILED_STORAGE), the
 * second SUCCEEDS (HELD_NEW), subsequent ones are HELD_DUPLICATE. Mirrors a
 * store that recovers after a transient failure: the same msg_id must be
 * re-acceptable, proving the failed first attempt did not poison the dedup
 * window. Backed by an [InMemoryMessageStore] so the recovered row is actually
 * held and reported in the digest.
 */
private class FailThenSucceedStore : MessageStore {
    private val backing = InMemoryMessageStore()
    // ConcurrentHashMap needs content-equal ByteArray keys -> wrap them (ByteArray
    // is identity-equal by default, which would let the same msg_id be retried as a
    // "first attempt" forever and defeat the test).
    private val attempted = java.util.concurrent.ConcurrentHashMap<BytesKey, Int>()
    var persistCalls = 0
        private set

    override suspend fun persist(frame: FrameV2, receivedFrom: ByteArray): PersistResult {
        persistCalls++
        val key = frame.msgId
        val count = attempted.merge(BytesKey(key), 1) { a, b -> a + b } ?: 1
        return if (count == 1) {
            PersistResult.FAILED_STORAGE   // first attempt: storage unavailable
        } else {
            backing.persist(frame, receivedFrom)   // retry: durably held (NEW then DUPLICATE)
        }
    }

    private class BytesKey(val bytes: ByteArray) {
        override fun equals(other: Any?): Boolean = other is BytesKey && bytes.contentEquals(other.bytes)
        override fun hashCode(): Int = bytes.contentHashCode()
    }

    override suspend fun allHeldOrderedByPriority(): List<FrameV2> = backing.allHeldOrderedByPriority()
    override suspend fun allHeldMsgIds(): List<ByteArray> = backing.allHeldMsgIds()
    override suspend fun forEachHeldOrderedByPriority(visit: (FrameV2) -> Boolean) =
        backing.forEachHeldOrderedByPriority(visit)
    override suspend fun forEachHeldMsgId(visit: (ByteArray) -> Boolean) =
        backing.forEachHeldMsgId(visit)
}