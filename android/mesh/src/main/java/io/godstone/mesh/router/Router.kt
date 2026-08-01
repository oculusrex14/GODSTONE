package io.godstone.mesh.router

import io.godstone.mesh.store.MessageStore
import io.godstone.mesh.wire.Frame
import io.godstone.mesh.wire.FrameType
import io.godstone.mesh.wire.Priority
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * Delay-tolerant epidemic router.
 *
 * There is deliberately no routing table. In a disaster the topology changes
 * faster than any table converges, and assuming otherwise is the classic failure
 * of mesh messengers. Messages persist, replicate to every peer encountered, and
 * physically travel with their carriers.
 */
class Router(
    private val store: MessageStore,
    private val selfNodeId: ByteArray,
    /** PROTOCOL.md section 8. Rate limits and trust, enforced before parsing. */
    private val governor: io.godstone.mesh.abuse.PeerGovernor =
        io.godstone.mesh.abuse.PeerGovernor()
) {

    private val seen = LruMsgIdCache(SEEN_CACHE_SIZE)
    private val mutex = Mutex()

    private val _inbound = MutableSharedFlow<Frame>(extraBufferCapacity = 256)
    val inbound: SharedFlow<Frame> = _inbound

    /**
     * Handle a frame received from [fromPeer].
     * Returns true when the frame is novel and should be relayed onward.
     */
    suspend fun onFrameReceived(frame: Frame, fromPeer: ByteArray): Boolean = mutex.withLock {
        // 0. Anti-abuse FIRST, before any payload work (PROTOCOL.md section 8).
        //    An unbounded inbound rate on a mesh whose premise is "battery is
        //    life" is a remote power-off switch, not a spam problem. This was
        //    documented and entirely absent.
        if (!governor.allowInbound(fromPeer, frame.priority)) return false

        // 1. Drop anything already handled (replay and loop suppression).
        if (seen.contains(frame.msgId)) {
            governor.penalise(fromPeer, 0.02)   // duplicate floods cost trust
            return false
        }

        // 2. Drop expired frames.
        val ageSeconds = (System.currentTimeMillis() / 1000) - frame.timestamp
        if (ageSeconds > MAX_AGE_SECONDS) return false

        // 3. Drop exhausted TTL.
        if (frame.ttl <= 0) return false

        // 4. Verify proof of work where the protocol requires it.
        if (frame.priority.requiresProofOfWork && !ProofOfWork.verify(frame)) {
            governor.penalise(fromPeer)   // unmined wide-distribution traffic
            return false
        }

        seen.add(frame.msgId)
        governor.reward(fromPeer)         // well-formed, useful traffic
        store.persist(frame, receivedFrom = fromPeer)
        _inbound.emit(frame)

        return frame.ttl > 1
    }

    /** Prepare a frame for forwarding. Never sent back to the peer it came from. */
    fun forwardCopy(frame: Frame): Frame = frame.copy(ttl = frame.ttl - 1)

    /**
     * Compute what a peer appears to lack, in strict priority order:
     * SOS first, then DIRECT, GROUP, BROADCAST, and BULK last.
     */
    suspend fun framesPeerLacks(peerDigest: BloomDigest, limit: Int): List<Frame> {
        // A-13: bounded by construction. The store pages rows and we stop as soon
        // as [limit] is reached, so a 200 MB backlog never materialises in memory.
        val out = ArrayList<Frame>(limit)
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
     * A relay sees only an ephemeral key, ciphertext and a daily-rotating
     * routing tag -- never who is talking to whom. Before this existed, every
     * relay in the path learned the full social graph, while the threat model
     * promised adversary A2 that it "cannot attribute" messages.
     */
    fun buildSealedMessage(
        plaintext: ByteArray,
        recipientNodeId: ByteArray,
        recipientStaticPub: ByteArray,
        msgId: Long
    ): Frame {
        val sealed = io.godstone.mesh.seal.SealedSender.seal(
            plaintext, selfNodeId, recipientStaticPub)
        return Frame(
            type = FrameType.MESSAGE,
            ttl = Frame.DEFAULT_TTL,
            priority = Priority.DIRECT,
            msgId = msgId,
            timestamp = System.currentTimeMillis() / 1000,
            payload = io.godstone.mesh.seal.SealedSender.routingTag(
                recipientNodeId,
                io.godstone.mesh.seal.SealedSender.currentEpochDay()) + sealed
        )
    }

    /**
     * Attempt to open a MESSAGE addressed to us. Null means it was not ours --
     * a routing-tag collision, which is expected and costs one AEAD open.
     */
    fun openSealed(frame: Frame, ourStaticDhPriv: ByteArray):
            io.godstone.mesh.seal.SealedSender.Opened? {
        val tagLen = io.godstone.mesh.seal.SealedSender.ROUTING_TAG_LEN
        if (frame.payload.size <= tagLen) return null
        return io.godstone.mesh.seal.SealedSender.open(
            frame.payload.copyOfRange(tagLen, frame.payload.size), ourStaticDhPriv)
    }

    /** SOS gets maximum TTL, extended retention, and is evicted last. */
    fun buildSos(payload: ByteArray, msgId: Long): Frame = Frame(
        type = FrameType.SOS,
        ttl = Frame.MAX_TTL,
        priority = Priority.SOS,
        msgId = msgId,
        timestamp = System.currentTimeMillis() / 1000,
        payload = payload
    )

    companion object {
        const val SEEN_CACHE_SIZE = 16384
        const val MAX_AGE_SECONDS = 14L * 24 * 3600
    }
}

/**
 * Fixed-capacity LRU of msg_ids. The bound is essential: an attacker must never
 * be able to grow a data structure on our device without limit.
 */
class LruMsgIdCache(private val capacity: Int) {
    private val set = HashSet<Long>()
    private val order = ArrayDeque<Long>()

    @Synchronized fun contains(id: Long): Boolean = set.contains(id)

    @Synchronized fun add(id: Long) {
        if (set.add(id)) {
            order.addLast(id)
            while (order.size > capacity) {
                set.remove(order.removeFirst())
            }
        }
    }
}
