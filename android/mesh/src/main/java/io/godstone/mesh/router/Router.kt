package io.godstone.mesh.router

import io.godstone.mesh.store.MessageStore
import io.godstone.mesh.store.PersistResult
import io.godstone.mesh.wire.v2.FrameV2
import io.godstone.mesh.wire.v2.MessageId
import io.godstone.mesh.wire.v2.Priority
import io.godstone.mesh.wire.v2.TypeV2
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * Delay-tolerant epidemic router on the canonical GMP/2.1 frame path (ADR-001,
 * ADR-008). Operates on FrameV2.
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
    private val selfNodeId: ByteArray,
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
        if (!governor.allowInbound(fromPeer, Priority.fromFlags(frame.flags))) return false

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

    /** Prepare a frame for forwarding: decrement TTL, increment hop_count. */
    fun forwardCopy(frame: FrameV2): FrameV2 =
        frame.copy(ttl = frame.ttl - 1, hopCount = frame.hopCount + 1)

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
     * Seal an application message for [recipientStaticPub] (PROTOCOL.md s.6).
     *
     * A relay sees only an ephemeral key, ciphertext and a daily-rotating routing
     * tag (now carried in the FrameV2 header field, not the payload) -- never who
     * is talking to whom.
     *
     * The sealed inner content carries the message nonce, PoW nonce, and created_at alongside
     * the plaintext (ADR-001 §3.3.4, C6.7):
     *     sealedInner = messageNonce(16) || powNonce(8) || created_at_le(4) || plaintext.
     * created_at is the SAME uint32 epoch-second count used in msg_id derivation, serialised
     * LITTLE-ENDIAN so there is one canonical created_at encoding across msg_id + PoW preimage
     * + sealed payload and the recipient reconstructs preimages from the sealed bytes without
     * any byte-order conversion. SealedSender packs sender_node_id before that, so the AEAD
     * authenticates sender + message nonce + PoW nonce + created_at + plaintext together.
     *
     * msg_id = BLAKE2s-128(b"GMP2-MSGID" || selfNodeId || created_at || message_nonce || plaintext)
     * (MessageId.derive), sender-computed and carried in the header. GROUP/BROADCAST mine the
     * nonce (priority.requiresProofOfWork) and set HAS_POW; SOS/DIRECT do not.
     */
    suspend fun buildSealedMessage(
        plaintext: ByteArray,
        recipientNodeId: ByteArray,
        recipientStaticPub: ByteArray,
        priority: Priority = Priority.DIRECT,
        messageNonce: ByteArray = MessageId.generateNonce()
    ): FrameV2 {
        require(messageNonce.size == MessageId.NONCE_BYTES) { "messageNonce must be 16 bytes" }
        val createdAt = System.currentTimeMillis() / 1000
        val createdAtLe = MessageId.uint32Le(createdAt)
        val powNonce = if (priority.requiresProofOfWork) {
            ProofOfWork.mine(selfNodeId, createdAtLe, TypeV2.MESSAGE.code, plaintext)
        } else {
            ByteArray(ProofOfWork.NONCE_BYTES)
        }
        val sealedInner = messageNonce + powNonce + createdAtLe + plaintext
        val sealed = io.godstone.mesh.seal.SealedSender.seal(
            sealedInner, selfNodeId, recipientStaticPub)
        val msgId = MessageId.derive(selfNodeId, createdAt, messageNonce, plaintext)
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

    /**
     * Open a sealed MESSAGE addressed to us and split the authenticated inner
     * content into the message nonce, PoW nonce, created_at and plaintext. Null means it was
     * not ours -- a routing-tag collision, expected and costs one AEAD open.
     *
     * The caller verifies PoW when the frame carries HAS_POW (recipient-side
     * gate; relays cannot perform this check).
     */
    fun openSealedMessage(frame: FrameV2, ourStaticDhPriv: ByteArray): OpenedSealedMessage? {
        val opened = io.godstone.mesh.seal.SealedSender.open(frame.payload, ourStaticDhPriv)
            ?: return null
        // opened.plaintext is the sealedInner: messageNonce(16) + powNonce(8) + created_at_le(4) + plaintext
        val inner = opened.plaintext
        val prefixLen = MessageId.NONCE_BYTES + ProofOfWork.NONCE_BYTES + 4 // 28 bytes
        if (inner.size < prefixLen) return null
        val messageNonce = inner.copyOfRange(0, MessageId.NONCE_BYTES)
        val powNonce = inner.copyOfRange(MessageId.NONCE_BYTES, MessageId.NONCE_BYTES + ProofOfWork.NONCE_BYTES)
        val createdAtLe = inner.copyOfRange(MessageId.NONCE_BYTES + ProofOfWork.NONCE_BYTES, prefixLen)
        val plaintext = inner.copyOfRange(prefixLen, inner.size)
        return OpenedSealedMessage(
            senderNodeId = opened.senderNodeId,
            messageNonce = messageNonce,
            powNonce = powNonce,
            createdAtLe = createdAtLe,
            plaintext = plaintext,
            frame = frame
        )
    }

    /**
     * Build a SOS frame. Maximum TTL, broadcast (zero routing tag), ACK_REQ +
     * RELAY_OK flags, priority SOS. The payload is structurally valid per
     * SosFrameValidator: "SOS1" magic + a 64-byte signature slot + the user
     * payload.
     *
     * The 64-byte slot is a PLACEHOLDER (all zeros) for the Ed25519 signature
     * over (msg_id || "SOS1" || payload). Cryptographic SOS signing is wired
     * with the SOS lifecycle under ADR-003/005 (OPEN); SosFrameValidator (patch
     * 15) validates structure only, so a zero slot is accepted at this layer.
     * msg_id is content-and-nonce derived (MessageId.derive).
     */
    fun buildSos(
        payload: ByteArray,
        messageNonce: ByteArray = MessageId.generateNonce()
    ): FrameV2 {
        require(messageNonce.size == MessageId.NONCE_BYTES) { "messageNonce must be 16 bytes" }
        val createdAt = System.currentTimeMillis() / 1000
        val sigSlot = ByteArray(64)   // placeholder; Ed25519 signing deferred (ADR-003/005 OPEN)
        val sosPayload = io.godstone.mesh.wire.v2.SosFrameValidator.PAYLOAD_MAGIC + sigSlot + payload
        val msgId = MessageId.derive(selfNodeId, createdAt, messageNonce, payload)
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

/** Result of opening a sealed MESSAGE, with the authenticated inner content split out. */
data class OpenedSealedMessage(
    val senderNodeId: ByteArray,
    val messageNonce: ByteArray,
    val powNonce: ByteArray,
    val createdAtLe: ByteArray,
    val plaintext: ByteArray,
    val frame: FrameV2
) {
    /**
     * Recipient-side logical message identity verification (C6.7 / ADR-001 §3.3).
     * Re-derives msg_id from unsealed components and asserts it matches frame.msgId.
     */
    fun verifyMessageId(): Boolean {
        if (senderNodeId.size != MessageId.NODE_ID_BYTES ||
            messageNonce.size != MessageId.NONCE_BYTES ||
            createdAtLe.size != 4) return false
        val createdAt = java.nio.ByteBuffer.wrap(createdAtLe)
            .order(java.nio.ByteOrder.LITTLE_ENDIAN).int.toLong() and 0xFFFFFFFFL
        val derived = MessageId.derive(senderNodeId, createdAt, messageNonce, plaintext)
        return derived.contentEquals(frame.msgId)
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