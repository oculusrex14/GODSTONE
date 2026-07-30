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
    private val selfNodeId: ByteArray
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
        // 1. Drop anything already handled (replay and loop suppression).
        if (seen.contains(frame.msgId)) return false

        // 2. Drop expired frames.
        val ageSeconds = (System.currentTimeMillis() / 1000) - frame.timestamp
        if (ageSeconds > MAX_AGE_SECONDS) return false

        // 3. Drop exhausted TTL.
        if (frame.ttl <= 0) return false

        // 4. Verify proof of work where the protocol requires it.
        if (frame.priority.requiresProofOfWork && !ProofOfWork.verify(frame)) {
            return false
        }

        seen.add(frame.msgId)
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
        val held = store.allHeldOrderedByPriority()
        val out = ArrayList<Frame>(limit)
        for (f in held) {
            if (out.size >= limit) break
            if (!peerDigest.mightContain(f.msgId)) out.add(f)
        }
        return out
    }

    suspend fun currentDigest(): BloomDigest {
        val d = BloomDigest()
        store.allHeldMsgIds().forEach { d.add(it) }
        return d
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
