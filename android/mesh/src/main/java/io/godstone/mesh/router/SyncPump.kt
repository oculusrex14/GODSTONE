package io.godstone.mesh.router

import io.godstone.mesh.store.MessageStore
import io.godstone.mesh.wire.v2.FrameV2
import io.godstone.mesh.wire.v2.Priority
import io.godstone.mesh.wire.v2.TypeV2

// ---------------------------------------------------------------------------
// T41 -- "Wire Android durable anti-entropy and forwarding": the per-TrustedPeer
// bounded sync pump (section 14's forwarder and sync_run).
//
// T40 built the CONTROL half (the per-relation owner: DIGEST / inventory pages /
// WANT / RESET, the 64-page and 256-want budgets, the periodic 5-minute run).
// T84 built the ACK half. What was missing -- and what an Android node did not
// do at all -- is the SCHEDULING and FORWARDING half:
//
//   * a peer became present in the durable view and nothing registered a sync
//     relation for it, so no DIGEST was ever scheduled and no inventory run ever
//     opened;
//   * an inbound frame was received and persisted, and NOTHING forwarded it: a
//     three-node path A -> R -> B ended at R;
//   * a relation that went away left its run state and snapshot leases standing.
//
// The laws of this file, in the order they bind:
//
//   1. FORWARD ONLY AFTER DURABLE ACCEPTANCE. [enqueueForward] is called by the
//      composition AFTER the store has committed the frame; the pump itself
//      never sends anything it has not been handed a durably-held frame for. A
//      send that precedes its persist is therefore not expressible here, and the
//      court witnesses it on the real MeshNode path.
//   2. TTL AND HOP ARE APPLIED EXACTLY ONCE, to the copy. [ForwardCopy] holds
//      the forwarded frame, built once by [Router.forwardCopy]; a retry re-emits
//      those exact bytes, never a second decrement.
//   3. NEVER BACK TO receivedFrom. The immediate hop a frame arrived from is
//      never offered that frame again.
//   4. TTL 0/1 AND THE HOP CEILING REFUSE BY NAME. A local frame is never
//      forwarded; a copy that cannot increment the hop is refused.
//   5. STRICT PRIORITY WITHIN BOUNDED ADMITTED WORK. SOS first, then DIRECT,
//      GROUP, BROADCAST, BULK; the forward leg is bounded at 32 copies per turn
//      and the control leg by the owner's own 64-page / 256-want run budgets.
//   6. THE SOURCE TOKEN IS CAPTURED BEFORE THE TURN AND REVALIDATED AFTER IT.
//      The relation's generation is read first and re-read last: a relation lost
//      mid-turn emits NOTHING, so a stale turn can never write to a newer
//      relation.
//   7. CANCELLATION RELEASES THE RELATION, NEVER THE DURABLE TRUTH. [cancel]
//      ends the relation's run state and snapshot leases; held frames, delivery
//      rows and application retry state stay exactly as they were, so a
//      reconnect resumes from the durable estate.
//
// Nonshipping: this is the lab mesh path. The shipping LIGHT Archive-only graph
// carrieth no :mesh dependency, the readiness flags stay false, and no device
// claim is made here.
// ---------------------------------------------------------------------------

/** Bounded forward leg: at most this many copies are offered per turn. */
const val SYNC_MAX_FORWARD_PER_TURN: Int = 32

/** Bound on one peer's pending forward queue (drop-oldest, counted). */
const val SYNC_MAX_FORWARD_QUEUE: Int = 256

/**
 * One prepared forward copy. It is built ONCE -- TTL decremented and hop
 * incremented exactly once -- and every retry re-emiteth these exact bytes.
 */
class ForwardCopy internal constructor(
    val frame: FrameV2,
    /** The immediate hop it arrived from, which is never offered it back. */
    val fromPeer: ByteArray?,
) {
    val msgId: ByteArray get() = frame.msgId
    val ttl: Int get() = frame.ttl
    val hopCount: Int get() = frame.hopCount
    val priority: Priority get() = Priority.fromFlags(frame.flags)

    fun encoded(): ByteArray = frame.encode()
}

/** The typed outcome of offering one durably held frame for forwarding. */
sealed class ForwardOffer {
    /** Queued for this many OTHER registered peers (never the one it came from). */
    data class Queued(val peers: Int) : ForwardOffer()
    /** Refused by name; nothing was queued anywhere. */
    data class Refused(val reason: SyncRefusal) : ForwardOffer()
    /** A type that never travels the message road (control, or a T84 ACK). */
    object NotForwardable : ForwardOffer()
}

/** Why a leg produced nothing. Named, never a silent no-op. */
enum class SyncRefusal {
    /** No scheduler is registered for this peer: nothing may be emitted. */
    NOT_REGISTERED,
    /** The relation was cancelled during the turn (the source token broke). */
    RELATION_LOST,
    /** The frame's TTL is 0 or 1: it is local to a link and never forwarded. */
    TTL_EXHAUSTED,
    /** The hop count cannot be incremented: the copy is refused. */
    HOP_LIMIT,
    /** The frame arrived from the only peer registered, so nobody else may have it. */
    NO_OTHER_PEER,
    /** The peer's forward queue was full and the eldest copy was superseded. */
    QUEUE_OVERFLOW,
    /** The held set could not be read: no fabricated frame is served. */
    FETCH_STORAGE_FAILURE,
}

/** One peer's bounded turn. Every count is an executed observation. */
class SyncPumpBatch(
    val peer: ByteArray,
    /** The exact frames the link writer should send, in emission order. */
    val frames: List<FrameV2>,
    /** The forward copies among them, for the witnesses. */
    val copies: List<ForwardCopy>,
    val controlFrames: Int,
    val forwarded: Int,
    val refusals: Map<SyncRefusal, Int>,
) {
    val total: Int get() = frames.size
    val refusedTotal: Int get() = refusals.values.sum()

    companion object {
        fun empty(peer: ByteArray, reason: SyncRefusal) =
            SyncPumpBatch(peer, emptyList(), emptyList(), 0, 0, mapOf(reason to 1))
    }
}

/**
 * The per-TrustedPeer bounded sync pump. It owneth no durable state: the held
 * set IS the durable truth, the control owner IS the run state, and this class
 * holds only scheduling hints (registration, the pending forward queues, the
 * counters) that a restart rebuildeth from the store and the relation.
 */
class SyncPump(
    private val owner: SyncControlOwner,
    private val store: MessageStore,
    private val router: Router,
    private val monotonicNowMillis: () -> Long = { System.nanoTime() / 1_000_000L },
) {
    private val lock = Any()

    /** The registered peers: the scheduler's registration truth. */
    private val registered = LinkedHashMap<String, SyncRelation>()

    /** Per-peer pending forward copies, highest priority first. */
    private val forwardQueues = HashMap<String, ArrayDeque<ForwardCopy>>()

    /** Copies superseded by the bounded queue, per peer (observation only). */
    private val overflowed = HashMap<String, Long>()

    /** One peer's scheduling state (never the durable truth). */
    class SyncRelation internal constructor(val peerNodeId: ByteArray) {
        var registered: Boolean = true
        var lastTurnMono: Long = 0L
        var turns: Long = 0L
        var forwardedFrames: Long = 0L
        var controlFrames: Long = 0L
        var digestsSent: Long = 0L
        var lastDigestMono: Long = 0L
    }

    // ---------------------------------------------------------------- scheduling

    /**
     * Register a TrustedPeer's sync relation: the peer becometh schedulable, so
     * its turn may emit a DIGEST and open an inventory run. Idempotent; true iff
     * this call created the registration.
     */
    fun register(peer: ByteArray, now: Long = monotonicNowMillis()): Boolean {
        if (peer.size != ControlPayloadV1.ID_BYTES) return false
        synchronized(lock) {
            val key = peer.hexKey()
            if (registered.containsKey(key)) return false
            val rel = SyncRelation(peer.copyOf())
            rel.lastTurnMono = now
            registered[key] = rel
            forwardQueues[key] = ArrayDeque()
            // the owner's relation is created here too, so the control half and
            // the scheduling half can never disagree about who is linked
            owner.relationFor(peer)
            return true
        }
    }

    /**
     * Cancel a relation (relation loss / disconnect). The run state and the
     * snapshot leases release; the DURABLE estate -- held frames, delivery rows
     * and the application's retry state -- is untouched, so a reconnect resumes.
     */
    fun cancel(peer: ByteArray): Boolean {
        synchronized(lock) {
            val key = peer.hexKey()
            val gone = registered.remove(key) != null
            forwardQueues.remove(key)
            overflowed.remove(key)
            val ownerHad = owner.forgetPeer(peer)
            return gone || ownerHad
        }
    }

    fun isRegistered(peer: ByteArray): Boolean = synchronized(lock) { registered.containsKey(peer.hexKey()) }

    fun registeredCount(): Int = synchronized(lock) { registered.size }

    fun relationFor(peer: ByteArray): SyncRelation? = synchronized(lock) { registered[peer.hexKey()] }

    fun pendingForwardCount(peer: ByteArray): Int =
        synchronized(lock) { forwardQueues[peer.hexKey()]?.size ?: 0 }

    /** How many copies were superseded by the bounded queue (observation only). */
    fun overflowCount(peer: ByteArray): Long = synchronized(lock) { overflowed[peer.hexKey()] ?: 0L }

    fun registeredPeers(): List<ByteArray> =
        synchronized(lock) { registered.values.map { it.peerNodeId.copyOf() } }

    // ---------------------------------------------------------------- forwarding

    /**
     * Offer one DURABLY HELD frame for epidemic forwarding. The composition
     * calls this only after the store committed the frame (law 1), so a send
     * before its persist is not expressible on this road.
     *
     * Returns the number of peers the copy was queued for. TTL 0/1 and the hop
     * ceiling are refused BY NAME, and nothing is queued for them.
     */
    fun enqueueForward(frame: FrameV2, fromPeer: ByteArray?, now: Long = monotonicNowMillis()): ForwardOffer {
        if (frame.type != TypeV2.MESSAGE && frame.type != TypeV2.SOS) {
            // control frames are link-local (section 14: "a TTL0 control frame is
            // local to the authenticated link and never forwarded"), and ACKs
            // travel on their own bounded pump (T84), never on the message road
            return ForwardOffer.NotForwardable
        }
        if (frame.ttl <= 1) return ForwardOffer.Refused(SyncRefusal.TTL_EXHAUSTED)
        if (frame.hopCount + 1 > FrameV2.MAX_TTL) return ForwardOffer.Refused(SyncRefusal.HOP_LIMIT)
        // THE copy: TTL decremented and hop incremented EXACTLY ONCE, here.
        val copy = ForwardCopy(router.forwardCopy(frame), fromPeer?.copyOf())
        var queued = 0
        synchronized(lock) {
            for ((key, rel) in registered) {
                if (!rel.registered) continue
                if (fromPeer != null && rel.peerNodeId.contentEquals(fromPeer)) continue   // never echo
                val queue = forwardQueues.getOrPut(key) { ArrayDeque() }
                while (queue.size >= SYNC_MAX_FORWARD_QUEUE) {
                    queue.removeFirst()
                    overflowed[key] = (overflowed[key] ?: 0L) + 1
                }
                insertByPriority(queue, copy)
                queued += 1
            }
        }
        return if (queued == 0) ForwardOffer.Refused(SyncRefusal.NO_OTHER_PEER)
        else ForwardOffer.Queued(queued)
    }

    /** Strict priority insertion: SOS first .. BULK last; FIFO within a rank. */
    private fun insertByPriority(queue: ArrayDeque<ForwardCopy>, copy: ForwardCopy) {
        val rank = copy.priority.code
        var index = queue.size
        var i = 0
        val it = queue.iterator()
        while (it.hasNext()) {
            if (it.next().priority.code > rank) {
                index = i
                break
            }
            i += 1
        }
        if (index == queue.size) queue.addLast(copy) else queue.add(index, copy)
    }

    // ---------------------------------------------------------------- the turn

    /**
     * One bounded turn for [peer]: the control leg (a due inventory run opens,
     * then the owner's own bounded page/WANT requests are taken) and then the
     * epidemic forward copies.
     *
     * The WANT ANSWER is deliberately NOT here: reading the exact requested
     * frames out of the durable held set is the control owner's `onWant`, which
     * answereth with a `Delivered` decision the composition queues on the control
     * outbox. One owner for that relation -- a second serve leg in this class
     * would race it and could double-serve a frame.
     *
     * Suspend: the control leg may read the store. NO lock is held across it --
     * the pump's monitor protecteth scheduling hints only, never I/O.
     */
    suspend fun pump(peer: ByteArray, now: Long = monotonicNowMillis()): SyncPumpBatch {
        val key = peer.hexKey()
        val rel = synchronized(lock) { registered[key] }
            ?: return SyncPumpBatch.empty(peer, SyncRefusal.NOT_REGISTERED)
        if (!synchronized(lock) { rel.registered }) {
            return SyncPumpBatch.empty(peer, SyncRefusal.NOT_REGISTERED)
        }

        // the source token, captured BEFORE anything is built
        val relation = owner.relationFor(peer)
        val token = relation.generation

        // 1. the control leg.
        val frames = ArrayList<FrameV2>()
        // 1a. the DIGEST leg: section 14 -- "schedule exact inventory at initial
        //     encounter and periodically every 5 minutes while linked". Our digest
        //     is what letteth the PEER open a run against OUR held set; without it
        //     no reconciliation is ever scheduled in that direction.
        val digestDue = synchronized(lock) {
            rel.digestsSent == 0L ||
                now - rel.lastDigestMono >= SyncControlOwner.PERIODIC_INVENTORY_MS
        }
        if (digestDue) {
            val built = owner.buildDigestFrame()
            if (built != null) {
                frames.add(built.first)
                synchronized(lock) {
                    rel.digestsSent += 1
                    rel.lastDigestMono = now
                }
            }
        }
        // 1b. our own run: a due run opens, then the owner's bounded requests
        //     (<= 64 pages and <= 256 wants per run) are taken.
        if (owner.shouldScheduleInventory(peer, now)) owner.startInventoryRun(peer)
        val control = owner.pumpNextInventoryFrames(peer)
        frames.addAll(control)

        // 2. the forward leg: bounded, strict priority, one copy per frame per
        //    peer per turn. The lock is held only to POP the copies.
        val popped = synchronized(lock) {
            val queue = forwardQueues.getOrPut(key) { ArrayDeque() }
            val out = ArrayList<ForwardCopy>()
            while (queue.isNotEmpty() && out.size < SYNC_MAX_FORWARD_PER_TURN) {
                out.add(queue.removeFirst())
            }
            out
        }
        val emittedIds = HashSet<List<Byte>>()
        for (f in frames) emittedIds.add(f.msgId.toList())
        val copies = ArrayList<ForwardCopy>(popped.size)
        for (copy in popped) {
            // one copy per frame per peer per turn: a frame this turn already
            // carrieth (e.g. as the answer to the peer's own request) is not also
            // offered as an epidemic copy
            if (emittedIds.contains(copy.msgId.toList())) continue
            frames.add(copy.frame)
            copies.add(copy)
            emittedIds.add(copy.msgId.toList())
        }

        synchronized(lock) {
            rel.controlFrames += control.size + (if (digestDue) 1 else 0)
            rel.forwardedFrames += copies.size
            rel.turns += 1
            rel.lastTurnMono = now
        }

        // 3. revalidate the token: a relation cancelled mid-turn emits NOTHING,
        //    so a stale turn can never write to a newer relation.
        if (relation.generation != token) {
            return SyncPumpBatch(peer, emptyList(), emptyList(), 0, 0,
                mapOf(SyncRefusal.RELATION_LOST to 1))
        }
        return SyncPumpBatch(peer, frames, copies, control.size, copies.size, emptyMap())
    }

    private fun ByteArray.hexKey(): String = joinToString("") { "%02x".format(it) }
}
