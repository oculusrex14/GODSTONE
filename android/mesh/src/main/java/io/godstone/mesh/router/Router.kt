package io.godstone.mesh.router

import io.godstone.mesh.store.MessageStore
import io.godstone.mesh.store.PersistResult
import io.godstone.mesh.wire.v2.FrameV2
import io.godstone.mesh.wire.v2.LogicalMessageIdentity
import io.godstone.mesh.wire.v2.MessageId
import io.godstone.mesh.wire.v2.Priority
import io.godstone.mesh.wire.v2.TypeV2
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * Delay-tolerant epidemic router on the canonical GMP/2.1 frame path (ADR-001,
 * ADR-008, C6.7.1). Operates on FrameV2.
 *
 * There is deliberately no routing table. In a disaster the topology changes
 * faster than any table converges, and assuming otherwise is the classic failure
 * of mesh messengers. Messages persist, replicate to every peer encountered, and
 * physically travel with their carriers.
 *
 * Inbound gate (relay): PeerGovernor (rate limit / trust) -> dedup (LRU 16384 on
 * the 16-byte msg_id) -> TTL. PoW is NOT a relay gate under GMP/2.1: the nonce
 * lives inside the sealed payload a relay cannot open, so the stamp is verified
 * by the recipient after SealedSender.open, not by the relay (ADR-001 §3). The
 * GMP/1 age gate is gone: GMP/2.1 carries no header timestamp, so there is no
 * header field to age against; retention is receipt-relative and lives in the
 * store (ADR-004). Relay-side anti-flood remains PeerGovernor (threat A5).
 */
class Router(
    private val store: MessageStore,
    selfNodeId: ByteArray,
    /** PROTOCOL.md section 8. Rate limits and trust, enforced before parsing. */
    private val governor: io.godstone.mesh.abuse.PeerGovernor =
        io.godstone.mesh.abuse.PeerGovernor(),
    /**
     * In-memory dedup window size. Defaults to the production 16384; test-only
     * smaller values let a test age an id OUT of the window while it is still
     * durably held, exercising the durable-UNIQUE-authority duplicate path (B1)
     * -- a path unreachable at the production cache size without 16384+ frames.
     */
    private val seenCacheSize: Int = SEEN_CACHE_SIZE,
) {

    private val selfNodeId = selfNodeId.copyOf().also {
        require(it.size == MessageId.NODE_ID_BYTES) { "selfNodeId must be ${MessageId.NODE_ID_BYTES} bytes" }
    }
    private val seen = LruMsgIdCache(seenCacheSize)
    private val mutex = Mutex()

    private val _inbound = MutableSharedFlow<FrameV2>(extraBufferCapacity = 256)
    val inbound: SharedFlow<FrameV2> = _inbound

    /**
     * Handle a frame received from [fromPeer].
     * Returns true when the frame is novel and should be relayed onward.
     */
    suspend fun onFrameReceived(frame: FrameV2, fromPeer: ByteArray): Boolean = mutex.withLock {
        // 0. Anti-abuse FIRST, before any payload work (PROTOCOL.md section 8).
        //    An unbounded inbound rate on a mesh whose premise is "battery is
        //    life" is a remote power-off switch, not a spam problem.
        val priority = Priority.fromFlagsStrict(frame.flags) ?: return false
        if (!governor.allowInbound(fromPeer, priority)) return false

        // 1. Fast duplicate path (B1). The in-memory LRU is an OPTIMISATION only:
        //    a hit means this id was durably accepted at some point (or is a
        //    within-window duplicate), so we short-circuit without touching the
        //    store. A miss MUST fall through to the durable store, whose
        //    UNIQUE(msg_id) result is the authoritative dedup decision. The LRU
        //    is populated only AFTER durable acceptance below, so a persist
        //    failure never poisons retry (the same id can be re-offered after the
        //    store recovers -- B1).
        if (seen.contains(frame.msgId)) {
            governor.penalise(fromPeer, 0.02)   // duplicate floods cost trust
            return false
        }

        // 2. Drop exhausted TTL. (No age gate: GMP/2.1 has no header timestamp;
        //    retention is receipt-relative in the store, ADR-004.)
        if (frame.ttl <= 0) return false

        // 3. No relay PoW gate under GMP/2.1: the nonce is in the sealed payload,
        //    verified by the recipient (ADR-001 §3).

        // 4. Durable authority (B1/B2). persist runs the insert, hard-cap
        //    enforcement and final-presence check in one transaction (B3) and
        //    reports the result. The relay/deliver decision is taken ONLY from
        //    this result -- never from the in-memory dedup window -- so the
        //    durable store is the authority and the LRU is only a cache.
        //    Storage exceptions are converted to FAILED_STORAGE at the store
        //    boundary (not thrown here), so one bad DB operation cannot kill the
        //    inbound receive collector.
        when (store.persist(frame, receivedFrom = fromPeer)) {
            PersistResult.HELD_NEW -> {
                // Durably held: mark seen (cache hint for future arrivals), reward
                // the peer for useful traffic, emit to inbound, offer for relay.
                seen.add(frame.msgId)
                governor.reward(fromPeer)
                _inbound.emit(frame)
                return frame.ttl > 1
            }
            PersistResult.HELD_DUPLICATE -> {
                // Already durably held (LRU aged the id out but the durable PK
                // still carries it): suppress re-relay, penalise the duplicate
                // flood, cache the id so future arrivals fast-path. seen.add is
                // safe here -- the frame IS durably held, so suppressing a retry
                // is correct (it already had its delivery/relay chance).
                seen.add(frame.msgId)
                governor.penalise(fromPeer, 0.02)
                return false
            }
            PersistResult.REJECTED_CAPACITY, PersistResult.FAILED_STORAGE -> {
                // NOT durably held (the just-inserted row was evicted by the cap,
                // or a storage exception rolled the transaction back). Do NOT
                // mark seen -- the same msg_id may be re-offered after the store
                // has room or recovers (B1: retry not poisoned). Do NOT reward
                // (the failure is not useful traffic) and do NOT penalise (a
                // durable failure is not the peer's fault). No inbound emit, no
                // relay: forwarding what this node cannot itself carry would let
                // the only copy be dropped.
                return false
            }
        }
    }

    /** Returns the copy of [frame] ready to be relayed: TTL decremented, hop count incremented. */
    fun forwardCopy(frame: FrameV2): FrameV2 {
        val nextHop = if (frame.hopCount >= 0xFF.toByte()) 0xFF.toByte() else (frame.hopCount + 1).toByte()
        return FrameV2(
            type = frame.type,
            msgId = frame.msgId.copyOf(),
            routingTag = frame.routingTag.copyOf(),
            ttl = (frame.ttl - 1).toByte(),
            hopCount = nextHop,
            flags = frame.flags,
            payload = frame.payload.copyOf()
        )
    }

    /**
     * Compute what a peer appears to lack, in strict priority order:
     * SOS first, then DIRECT, GROUP, BROADCAST, and BULK last.
     */
    suspend fun framesPeerLacks(peerDigest: BloomDigest, limit: Int): List<FrameV2> {
        // A-13: bounded by construction. The store pages rows and we stop as soon
        // as [limit] is reached, so a 200 MB backlog never materialises in memory.
        val out = ArrayList<FrameV2>(limit)
        store.forEachHeldOrderedByPriority { f ->
            if (!peerDigest.mightContain(f.msgId)) out.add(f)
            out.size < limit   // false stops the scan
        }
        return out
    }

    suspend fun currentDigest(): BloomDigest {
        val d = BloomDigest()
        store.forEachHeldMsgId { d.add(it); true }
        return d
    }

    /**
     * Build an anti-entropy WANT response frame (criterion 6, ADR-004).
     * Carries requested message IDs concatenated in the payload.
     */
    fun buildWant(msgIds: List<ByteArray>, routingTag: ByteArray): FrameV2 {
        require(msgIds.isNotEmpty()) { "WANT frame must carry at least one msg_id" }
        require(routingTag.size == 4) { "routingTag must be 4 bytes" }
        val payload = ByteArray(msgIds.size * MessageId.MSG_ID_BYTES)
        for (i in msgIds.indices) {
            val id = msgIds[i]
            require(id.size == MessageId.MSG_ID_BYTES) { "Each msg_id must be ${MessageId.MSG_ID_BYTES} bytes" }
            System.arraycopy(id, 0, payload, i * MessageId.MSG_ID_BYTES, MessageId.MSG_ID_BYTES)
        }
        val ephemeralIdentity = LogicalMessageIdentity.createNew()
        val msgId = MessageId.derive(selfNodeId, ephemeralIdentity, payload)
        return FrameV2(
            type = TypeV2.WANT,
            msgId = msgId,
            routingTag = routingTag,
            ttl = 1,
            hopCount = 0,
            flags = 0,
            payload = payload
        )
    }

    /**
     * Build an anti-entropy IAVE (I-Have) bloom digest frame (criterion 6, ADR-004).
     * Contains the full 4096-bit (512-byte) bloom filter of all held message IDs.
     */
    fun buildIHave(bloomFilter: ByteArray, routingTag: ByteArray): FrameV2 {
        require(bloomFilter.size == BloomFilter.FILTER_BYTES) {
            "IAVE bloomFilter must be ${BloomFilter.FILTER_BYTES} bytes"
        }
        require(routingTag.size == 4) { "routingTag must be 4 bytes" }
        val ephemeralIdentity = LogicalMessageIdentity.createNew()
        val msgId = MessageId.derive(selfNodeId, ephemeralIdentity, bloomFilter)
        return FrameV2(
            type = TypeV2.IAVE,
            msgId = msgId,
            routingTag = routingTag,
            ttl = 1,
            hopCount = 0,
            flags = 0,
            payload = bloomFilter.copyOf()
        )
    }

    /**
     * Build an authenticated recipient ACK frame (ADR-004, C6.1/C6.4.1).
     * Signs (b"GMP2-ACK" || msgId[16] || recipientNodeId[16]) under recipient's Ed25519 key.
     */
    fun buildAck(
        ackedMsgId: ByteArray,
        ourIdentityPriv: ByteArray,
        routingTag: ByteArray
    ): FrameV2 {
        require(ackedMsgId.size == MessageId.MSG_ID_BYTES) { "ackedMsgId must be 16 bytes" }
        require(ourIdentityPriv.size == 32 || ourIdentityPriv.size == 64) { "ourIdentityPriv must be Ed25519 private key bytes" }
        require(routingTag.size == 4) { "routingTag must be 4 bytes" }

        val signature = io.godstone.mesh.delivery.DeliveryAck.sign(
            ackedMsgId = ackedMsgId,
            recipientNodeId = selfNodeId,
            recipientIdentityPriv = ourIdentityPriv
        )
        val payload = ackedMsgId + selfNodeId + signature // 16 + 16 + 64 = 96 bytes

        val ephemeralIdentity = LogicalMessageIdentity.createNew()
        val ackMsgId = MessageId.derive(selfNodeId, ephemeralIdentity, payload)

        return FrameV2(
            type = TypeV2.ACK,
            msgId = ackMsgId,
            routingTag = routingTag,
            ttl = FrameV2.DEFAULT_TTL,
            hopCount = 0,
            flags = FrameV2.ACK_REQ or FrameV2.RELAY_OK or Priority.toFlags(Priority.DIRECT),
            payload = payload
        )
    }

    /**
     * Build a sealed MESSAGE frame with an explicit [LogicalMessageIdentity].
     * Canonical 29-byte sealed inner payload prefix (ADR-001 §3.3):
     * message_nonce[16] || pow_nonce[8] || created_at_le[4] || priority_code[1] || plaintext
     */
    suspend fun buildSealedMessage(
        plaintext: ByteArray,
        recipientNodeId: ByteArray,
        recipientStaticPub: ByteArray,
        identity: LogicalMessageIdentity,
        priority: Priority = Priority.DIRECT
    ): FrameV2 {
        require(recipientNodeId.size == MessageId.NODE_ID_BYTES) { "recipientNodeId must be 16 bytes" }
        require(recipientStaticPub.size == 32) { "recipientStaticPub must be 32 bytes" }
        require(priority == Priority.DIRECT || priority == Priority.GROUP || priority == Priority.BROADCAST) {
            "Invalid priority $priority for sealed MESSAGE frame"
        }

        val createdAtLe = identity.createdAtLe()
        val powNonce = if (priority.requiresProofOfWork) {
            ProofOfWork.mine(
                senderNodeId = selfNodeId,
                createdAtLe = createdAtLe,
                messageNonce = identity.messageNonce,
                priorityCode = priority.code.toByte(),
                typeCode = TypeV2.MESSAGE.code,
                plaintext = plaintext
            )
        } else {
            ByteArray(ProofOfWork.NONCE_BYTES)
        }

        val sealedInner = identity.messageNonce + powNonce + createdAtLe + byteArrayOf(priority.code.toByte()) + plaintext
        val sealed = io.godstone.mesh.seal.SealedSender.seal(
            sealedInner, selfNodeId, recipientStaticPub)
        val msgId = MessageId.derive(selfNodeId, identity, plaintext)
        val routingTag = io.godstone.mesh.seal.SealedSender.routingTag(
            recipientNodeId,
            io.godstone.mesh.seal.SealedSender.currentEpochDay())
        val flags = FrameV2.SEALED or
            (if (priority.requiresProofOfWork) FrameV2.HAS_POW else 0) or
            Priority.toFlags(priority)

        return FrameV2(
            type = TypeV2.MESSAGE,
            msgId = msgId,
            routingTag = routingTag,
            ttl = FrameV2.DEFAULT_TTL,
            hopCount = 0,
            flags = flags,
            payload = sealed
        )
    }

    /** Author a NEW sealed message by creating an explicit [LogicalMessageIdentity] once. */
    suspend fun authorSealedMessage(
        plaintext: ByteArray,
        recipientNodeId: ByteArray,
        recipientStaticPub: ByteArray,
        priority: Priority = Priority.DIRECT
    ): FrameV2 {
        val identity = LogicalMessageIdentity.createNew()
        return buildSealedMessage(plaintext, recipientNodeId, recipientStaticPub, identity, priority)
    }

    /**
     * Open a sealed MESSAGE addressed to us and verify authenticated message policy
     * and identity against frame headers (ADR-001 §3.3, C6.7.2).
     */
    fun openSealedMessage(frame: FrameV2, ourStaticDhPriv: ByteArray): OpenMessageResult {
        if (frame.type != TypeV2.MESSAGE) {
            return OpenMessageResult.WrongFrameType
        }
        if (frame.flags and FrameV2.SEALED == 0) {
            return OpenMessageResult.MissingSealedFlag
        }

        val opened = io.godstone.mesh.seal.SealedSender.open(frame.payload, ourStaticDhPriv)
            ?: return OpenMessageResult.NotForUs

        val inner = opened.plaintext
        val prefixLen = MessageId.NONCE_BYTES + ProofOfWork.NONCE_BYTES + 4 + 1 // 29 bytes
        if (inner.size < prefixLen || opened.senderNodeId.size != MessageId.NODE_ID_BYTES) {
            return OpenMessageResult.Malformed
        }

        val messageNonce = inner.copyOfRange(0, MessageId.NONCE_BYTES)
        val powNonce = inner.copyOfRange(MessageId.NONCE_BYTES, MessageId.NONCE_BYTES + ProofOfWork.NONCE_BYTES)
        val createdAtLe = inner.copyOfRange(MessageId.NONCE_BYTES + ProofOfWork.NONCE_BYTES, MessageId.NONCE_BYTES + ProofOfWork.NONCE_BYTES + 4)
        val priorityCode = inner[MessageId.NONCE_BYTES + ProofOfWork.NONCE_BYTES + 4].toInt() and 0xFF
        val plaintext = inner.copyOfRange(prefixLen, inner.size)

        val sealedPriority = Priority.fromCode(priorityCode)
            ?: return OpenMessageResult.PolicyMismatch
        if (sealedPriority != Priority.DIRECT && sealedPriority != Priority.GROUP && sealedPriority != Priority.BROADCAST) {
            return OpenMessageResult.PolicyMismatch
        }

        val headerPriority = Priority.fromFlagsStrict(frame.flags)
            ?: return OpenMessageResult.PolicyMismatch

        if (headerPriority != sealedPriority) {
            return OpenMessageResult.PolicyMismatch
        }

        if (sealedPriority == Priority.DIRECT) {
            if (frame.flags and FrameV2.HAS_POW != 0) {
                return OpenMessageResult.PolicyMismatch
            }
            if (!powNonce.all { it == 0.toByte() }) {
                return OpenMessageResult.PolicyMismatch
            }
        } else {
            if (frame.flags and FrameV2.HAS_POW == 0) {
                return OpenMessageResult.PolicyMismatch
            }
        }

        val createdAt = java.nio.ByteBuffer.wrap(createdAtLe)
            .order(java.nio.ByteOrder.LITTLE_ENDIAN).int.toLong() and 0xFFFFFFFFL
        val identity = LogicalMessageIdentity.of(createdAt, messageNonce)

        val expectedMsgId = MessageId.derive(opened.senderNodeId, identity, plaintext)
        if (!expectedMsgId.contentEquals(frame.msgId)) {
            return OpenMessageResult.MessageIdMismatch
        }

        if (sealedPriority.requiresProofOfWork) {
            val powValid = ProofOfWork.verify(
                powNonce = powNonce,
                senderNodeId = opened.senderNodeId,
                createdAtLe = createdAtLe,
                messageNonce = messageNonce,
                priorityCode = sealedPriority.code.toByte(),
                typeCode = frame.type.code,
                plaintext = plaintext
            )
            if (!powValid) {
                return OpenMessageResult.InvalidProofOfWork
            }
        }

        return OpenMessageResult.Accepted(
            PolicyCheckedOpenedMessage(
                senderNodeId = opened.senderNodeId,
                identity = identity,
                powNonce = powNonce,
                priority = sealedPriority,
                plaintext = plaintext,
                frame = frame
            )
        )
    }

    /**
     * Build an SOS frame. Maximum TTL, broadcast (zero routing tag), ACK_REQ +
     * RELAY_OK flags, priority SOS. The payload is structurally valid per
     * SosFrameValidator: "SOS1" magic + a 64-byte signature slot + the user
     * payload.
     *
     * The 64-byte slot is a PLACEHOLDER (all zeros) for the Ed25519 signature
     * over (msg_id || "SOS1" || payload). Cryptographic SOS signing is wired
     * with the SOS lifecycle under ADR-003/005 (OPEN); SosFrameValidator (patch
     * 15) validates structure only, so a zero slot is accepted at this layer.
     * msg_id is content-and-identity derived (MessageId.derive).
     */
    fun buildSos(
        payload: ByteArray,
        identity: LogicalMessageIdentity = LogicalMessageIdentity.createNew()
    ): FrameV2 {
        val sigSlot = ByteArray(64)   // placeholder; Ed25519 signing deferred (ADR-003/005 OPEN)
        val sosPayload = io.godstone.mesh.wire.v2.SosFrameValidator.PAYLOAD_MAGIC + sigSlot + payload
        val msgId = MessageId.derive(selfNodeId, identity, payload)
        return FrameV2(
            type = TypeV2.SOS,
            msgId = msgId,
            routingTag = ByteArray(4),         // broadcast: no specific recipient
            ttl = FrameV2.MAX_TTL,
            hopCount = 0,
            flags = FrameV2.ACK_REQ or FrameV2.RELAY_OK,   // 0x0030; SOS priority bits are 0
            payload = sosPayload
        )
    }

    companion object {
        const val SEEN_CACHE_SIZE = 16384
    }
}

/** Typed outcome of [Router.openSealedMessage]. */
sealed class OpenMessageResult {
    data class Accepted(val message: PolicyCheckedOpenedMessage) : OpenMessageResult()
    data object NotForUs : OpenMessageResult()
    data object Malformed : OpenMessageResult()
    data object WrongFrameType : OpenMessageResult()
    data object MissingSealedFlag : OpenMessageResult()
    data object PolicyMismatch : OpenMessageResult()
    data object MessageIdMismatch : OpenMessageResult()
    data object InvalidProofOfWork : OpenMessageResult()
}

/** Result of opening a verified sealed MESSAGE. */
data class PolicyCheckedOpenedMessage(
    val senderNodeId: ByteArray,
    val identity: LogicalMessageIdentity,
    val powNonce: ByteArray,
    val priority: Priority,
    val plaintext: ByteArray,
    val frame: FrameV2
) {
    val createdAtEpochSeconds: Long get() = identity.createdAtEpochSeconds
    val messageNonce: ByteArray get() = identity.messageNonce

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is PolicyCheckedOpenedMessage) return false
        return senderNodeId.contentEquals(other.senderNodeId) &&
            identity == other.identity &&
            powNonce.contentEquals(other.powNonce) &&
            priority == other.priority &&
            plaintext.contentEquals(other.plaintext) &&
            frame == other.frame
    }

    override fun hashCode(): Int {
        var result = senderNodeId.contentHashCode()
        result = 31 * result + identity.hashCode()
        result = 31 * result + powNonce.contentHashCode()
        result = 31 * result + priority.hashCode()
        result = 31 * result + plaintext.contentHashCode()
        result = 31 * result + frame.hashCode()
        return result
    }
}

/**
 * Fixed-capacity LRU of 16-byte msg_ids. The bound is essential: an attacker must
 * never be able to grow a data structure on our device without limit. Keys are
 * compared by content (ByteArray is identity-equal by default), via a small
 * content-keyed wrapper.
 */
class LruMsgIdCache(private val capacity: Int) {
    private class BytesKey(val bytes: ByteArray) {
        override fun equals(other: Any?): Boolean = other is BytesKey && bytes.contentEquals(other.bytes)
        override fun hashCode(): Int = bytes.contentHashCode()
    }

    private val set = HashSet<BytesKey>()
    private val order = ArrayDeque<BytesKey>()

    @Synchronized fun contains(id: ByteArray): Boolean = set.contains(BytesKey(id))

    @Synchronized fun add(id: ByteArray) {
        val k = BytesKey(id)
        if (set.add(k)) {
            order.addLast(k)
            while (order.size > capacity) {
                set.remove(order.removeFirst())
            }
        }
    }
}