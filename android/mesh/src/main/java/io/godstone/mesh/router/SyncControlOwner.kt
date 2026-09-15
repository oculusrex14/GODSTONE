package io.godstone.mesh.router

import io.godstone.mesh.store.MessageStore
import io.godstone.mesh.wire.v2.FrameV2
import io.godstone.mesh.wire.v2.MessageId

/**
 * T40 (ADR-009 section 5) -- the per-relation sync/control owner.
 *
 * The node's ingress demultiplexes decoded PING/HELLO/DIGEST/WANT here,
 * BEFORE the generic Router runs policy, the seen-dedup window, the TTL
 * gate and persistence; ACK keeps its sealed dispatcher and only MESSAGE
 * and SOS enter durable message routing. Everything else (the bulk pair,
 * any unknown) is refused in this profile. The owner mutates relation
 * state only; control frames never enter held message storage.
 *
 * The §14 event algorithm, per arriving control:
 *   1. capture the source token before delivery   -- the relation identity
 *      and its generation are taken BEFORE any suspension point;
 *   2. validate token and input under the named owner -- the codec already
 *      refused an uncanonical payload; the owner revalidates that the
 *      relation still stands linked and the payload belongs to its run;
 *   3. perform exactly one explicit transition    -- each handler moves one
 *      field of the run state, never two;
 *   4. schedule a bounded effect                  -- replies, pages and
 *      answers are RETURNED to the caller, counted against the run budgets
 *      (64 pages, 256 requested frames);
 *   5. revalidate the token on completion         -- after the suspension
 *      the relation must still be the same instance of the same generation,
 *      else the effect is Refused and nothing stands mutated.
 *
 * The inventory run is a stream: pages arrive in lexicographic order after
 * an exclusive cursor; the run is OPENED by the first request, CONTINUES
 * through the pages, and is CLOSED by the first page whose done is set.
 * A page that names the run's snapshot after the close is an
 * internal contradiction: Refused "sequence_break". The end-of-run
 * certification [checkSequence] re-verifies the accumulated stream.
 */
class SyncControlOwner(
    private val store: MessageStore,
    private val authority: InventorySnapshotAuthority,
    private val monotonicNowMillis: () -> Long,
    localNodeId: ByteArray,
    private val frameStamper: (ControlPayloadV1.ControlArm, ByteArray) -> FrameV2 =
        defaultStamper(localNodeId, monotonicNowMillis),
) {
    /** The one frame the consumer's plan names as the run's snapshot. */
    sealed class OwnerDecision {
        object Accepted : OwnerDecision() { override fun toString(): String = "Accepted" }
        data class Ignored(val reason: String) : OwnerDecision()
        data class Refused(val reason: String) : OwnerDecision()
        data class Answered(val frame: FrameV2) : OwnerDecision()
        data class Delivered(val frames: List<FrameV2>) : OwnerDecision()
    }

    /** The per-relation run state (the §14 sync_run's peer member). */
    inner class Relation internal constructor(val peerNodeId: ByteArray) {
        init {
            require(peerNodeId.size == ControlPayloadV1.ID_BYTES) { "relation peers must name 16-octet ids" }
        }

        var generation: Long = 0L   // the captured source token
        internal var lastHeardMono: Long = 0L

        // consumer view: the digest tracked for this peer
        var trackedSid: Long = 0L
            internal set
        var trackedBloom: ByteArray? = null
            internal set
        var pendingSid: Long = 0L   // named by a RESET; the next DIGEST must prove it

        // the active inventory run
        var runSid: Long = 0L
            internal set
        var runCursor: ByteArray? = null
            internal set
        var runDone: Boolean = true
            internal set
        var pagesRequested: Int = 0
            internal set
        var pagesReceived: Int = 0
            internal set
        var requestsSent: Int = 0
            internal set
        var lastInventoryRunMono: Long = 0L
            internal set

        /** The owner stores all received page descriptors for reinspection. */
        internal val delivered = ArrayList<ControlPayloadV1.InventoryPage>()
        /** Received ids that are absent locally wait for the next want. */
        internal val wantQueue = ArrayList<ByteArray>()

        // producer view: answers to this peer's requests
        var servedSid: Long = 0L
            internal set
        var producerPagesSent: Int = 0
            internal set
        var producerRunMono: Long = 0L
            internal set
        internal val leasedSids = ArrayList<Long>()

        // ping / RTT (ADR-009 section 3: PING is its own answer)
        var lastPingSentNonce: Long = 0L
            internal set
        var lastPingSentMono: Long = 0L
            internal set
        var lastAnsweredNonce: Long = 0L
            internal set
        var answeredOnce: Boolean = false
            internal set
        var rttMillis: Long = -1L
            internal set

        override fun toString(): String =
            "relation(sid=$trackedSid,run=$runSid,done=$runDone,pagesReq=$pagesRequested," +
                "pagesRecv=$pagesReceived,wants=${wantQueue.size},recv=${delivered.size})"
    }

    private val lock = Any()
    private val relations = HashMap<BytesKey, Relation>()

    private class BytesKey(val bytes: ByteArray) {
        override fun equals(other: Any?): Boolean =
            other is BytesKey && other.bytes.contentEquals(bytes)
        override fun hashCode(): Int = bytes.contentHashCode()
    }

    /** get or create the relation for [peer] (mesh_node_get_peer_or_create). */
    fun relationFor(peer: ByteArray): Relation = synchronized(lock) {
        val key = BytesKey(peer.copyOf())
        val known = relations[key]
        if (known != null) return@synchronized known
        val fresh = Relation(peer.copyOf())
        relations[key] = fresh
        fresh
    }

    /** The number of linked relations -- the observation face. */
    fun linkedRelationCount(): Int = synchronized(lock) { relations.size }

    /** Relation terminal: control state and producer leases release here. */
    fun forgetPeer(peer: ByteArray): Boolean = synchronized(lock) {
        val removed = relations.remove(BytesKey(peer.copyOf()))
        if (removed != null) {
            authority.forgetLeases(removed.leasedSids.toList())
            removed.generation++    // any in-flight revalidation now breaks
            true
        } else false
    }

    // ------------------------------------------------------------------
    // the demultiplex: decode by the frozen outer code, dispatch by arm
    // ------------------------------------------------------------------
    suspend fun handleControlFrame(frame: FrameV2, from: ByteArray): OwnerDecision {
        val result = ControlPayloadV1.decodeFor(frame.type, frame.payload)
        if (result is ControlPayloadV1.ControlDecodeResult.Err) {
            return OwnerDecision.Refused("decode:" + result.failure.name)
        }
        val payload = (result as ControlPayloadV1.ControlDecodeResult.Ok).payload
        val rel = relationFor(from)
        val token = rel.generation
        val decision = when (payload) {
            is ControlPayloadV1.Ping -> onPing(rel, payload)
            is ControlPayloadV1.Digest -> onDigest(rel, payload)
            is ControlPayloadV1.Want -> onWant(rel, payload)
            is ControlPayloadV1.InventoryRequest -> onInventoryRequest(rel, payload)
            is ControlPayloadV1.InventoryPage -> onInventoryPage(rel, payload)
            is ControlPayloadV1.Reset -> onReset(rel, payload)
        }
        // revalidate the captured token after the (possibly suspended) work
        val still = synchronized(lock) {
            relations[BytesKey(from.copyOf())] === rel && rel.generation == token
        }
        return if (still) decision else OwnerDecision.Refused("relation gone")
    }

    // ------------------------------------------------------------------
    // one explicit transition per arm
    // ------------------------------------------------------------------
    private fun onPing(rel: Relation, p: ControlPayloadV1.Ping): OwnerDecision {
        val now = monotonicNowMillis()
        rel.lastHeardMono = now
        if (p.reply == 0) {
            // a request is answered; a replay of the same request is RE-answered
            // idempotently -- the reply carries the very same nonce
            rel.lastAnsweredNonce = p.nonce
            rel.answeredOnce = true
            val reply = ControlPayloadV1.Ping(1, p.nonce)
            return OwnerDecision.Answered(frameStamper(ControlPayloadV1.ControlArm.PING, reply.encode()))
        }
        if (p.nonce != rel.lastPingSentNonce || rel.lastPingSentMono == 0L) {
            return OwnerDecision.Ignored("unsolicited reply")   // a reply is never answered; an unknown nonce is not ours
        }
        rel.rttMillis = now - rel.lastPingSentMono
        rel.lastPingSentMono = 0L
        return OwnerDecision.Accepted
    }

    /** The node asks a peer whether it is alive; the RTT pair rides back. */
    fun queuePing(rel: Relation): ControlPayloadV1.Ping {
        val nonce = (monotonicNowMillis() shl 8) xor (rel.peerNodeId[0].toLong() and 0xFF) xor 0x9E37L
        rel.lastPingSentNonce = nonce
        rel.lastPingSentMono = monotonicNowMillis()
        return ControlPayloadV1.Ping(0, nonce)
    }

    private fun onDigest(rel: Relation, d: ControlPayloadV1.Digest): OwnerDecision {
        rel.lastHeardMono = monotonicNowMillis()
        if (rel.pendingSid != 0L && d.snapshotId != rel.pendingSid) {
            return OwnerDecision.Ignored("digest names a foreign snapshot") // the run restarts deterministically
        }
        if (rel.trackedSid != 0L && d.snapshotId < rel.trackedSid) {
            return OwnerDecision.Ignored("stale digest")                     // the elder stands; mutate nothing
        }
        if (d.snapshotId == rel.trackedSid) {
            rel.trackedBloom = d.bloom.copyOf()                              // reaffirmed under the very same sid
            rel.pendingSid = 0L
            return OwnerDecision.Accepted
        }
        // a newer snapshot: adopt it; a run over the elder is discarded
        rel.trackedSid = d.snapshotId
        rel.trackedBloom = d.bloom.copyOf()
        rel.pendingSid = 0L
        if (rel.runSid != 0L && rel.runSid != d.snapshotId) discardRun(rel)
        return OwnerDecision.Accepted
    }

    /** The peer asks for ids: the answer is the held frame, read back verbatim. */
    private suspend fun onWant(rel: Relation, w: ControlPayloadV1.Want): OwnerDecision {
        rel.lastHeardMono = monotonicNowMillis()
        val serving = authority.currentSnapshotOrNull()
        if (serving == null || serving.snapshotId != w.snapshotId) {
            return OwnerDecision.Delivered(emptyList())   // bounded absent response: answer nothing
        }
        val wanted = HashSet<String>(w.ids.size)
        for (id in w.ids) wanted.add(hexOf(id))
        val answers = ArrayList<FrameV2>()
        store.forEachHeldOrderedByPriority { frame ->
            if (wanted.contains(hexOf(frame.msgId))) answers.add(frame)
            true                                            // keep the walk: at most 32 hit anyway
        }
        return OwnerDecision.Delivered(answers)            // exact ids, bytes as stored
    }

    /** The peer requests a page of our captured inventory (producer side). */
    private suspend fun onInventoryRequest(rel: Relation, r: ControlPayloadV1.InventoryRequest): OwnerDecision {
        rel.lastHeardMono = monotonicNowMillis()
        val snap = authority.currentSnapshot()             // honouring the rate limit and the leases
            ?: return OwnerDecision.Refused("snapshot build deferred")
        if (snap.snapshotId != r.snapshotId) {
            // the peer walks a stale or foreign course: answer with a reset
            // naming the new snapshot plus the current digest; the consumer
            // restarts with cursorPresent 0 (section 14, verbatim)
            rel.servedSid = snap.snapshotId
            rel.producerPagesSent = 0
            rel.producerRunMono = monotonicNowMillis()
            val reset = ControlPayloadV1.Reset(snap.snapshotId)
            val digest = digestPayloadFor(snap)
            return OwnerDecision.Delivered(
                listOf(
                    frameStamper(ControlPayloadV1.ControlArm.RESET, reset.encode()),
                    frameStamper(ControlPayloadV1.ControlArm.DIGEST, digest.encode()),
                ),
            )
        }
        if (rel.servedSid != snap.snapshotId) {
            rel.servedSid = snap.snapshotId                // a new snapshot starts a new producer run
            rel.producerPagesSent = 0
            rel.producerRunMono = monotonicNowMillis()
        }
        if (rel.producerPagesSent >= MAX_PAGES_PER_RUN) {
            return OwnerDecision.Refused("producer run budget spent")       // resume next turn
        }
        val cursor = if (r.cursorPresent == 0) null else r.cursor
        val page = snap.pageAfter(cursor, ControlPayloadV1.MAX_IDS_PER_ARM)
        rel.producerPagesSent++
        return OwnerDecision.Delivered(
            listOf(frameStamper(ControlPayloadV1.ControlArm.INVENTORY_PAGE, page.encode())),
        )
    }

    /** The response to OUR inventory request: verify, store, advance -- once. */
    private suspend fun onInventoryPage(rel: Relation, p: ControlPayloadV1.InventoryPage): OwnerDecision {
        rel.lastHeardMono = monotonicNowMillis()
        if (rel.runSid == 0L) return OwnerDecision.Ignored("unsolicited page")
        if (p.snapshotId != rel.runSid) return OwnerDecision.Refused("sequence_break")
        if (rel.runDone) return OwnerDecision.Refused("sequence_break")     // the stream continues after the close
        // GS-SYNC-001: the RECEIVER'S OWN page budget, imposed at THIS boundary BEFORE any mutation
        // (no `delivered.add`, no cursor advance, no `pagesReceived++`). MAX_PAGES_PER_RUN boundeth
        // the PRODUCER (`producerPagesSent`) and the PUMP (`pagesRequested`) only; without this check
        // the receiver retaineth every verified page and its counter passeth the budget, so a peer
        // could grow one open run's retained page descriptors without limit.
        if (rel.pagesReceived >= MAX_PAGES_PER_RUN) {
            return OwnerDecision.Refused("page_budget_exhausted")
        }
        if (p.ids.isNotEmpty()) {
            if (!ControlPayloadV1.idsDistinct(p.ids)) return OwnerDecision.Refused("duplicate_ids")
            for (k in 1 until p.ids.size) {
                if (ControlPayloadV1.lexicographicCompare(p.ids[k - 1], p.ids[k]) >= 0) {
                    return OwnerDecision.Refused("sequence_break")
                }
            }
            val cursor = rel.runCursor
            if (cursor != null && ControlPayloadV1.lexicographicCompare(p.ids[0], cursor) <= 0) {
                return OwnerDecision.Refused("sequence_break")
            }
        }
        if (p.done != 0 && p.done != 1) return OwnerDecision.Refused("bad_done")
        // one explicit transition: the verified page joins the run
        rel.delivered.add(ControlPayloadV1.InventoryPage(p.snapshotId, p.done, p.ids.map { it.copyOf() }))
        if (p.ids.isNotEmpty()) rel.runCursor = p.ids[p.ids.size - 1].copyOf()
        rel.pagesReceived++
        // request each id absent from the durable store (the probe reads the
        // truth, not the cache); duplicates already queued are passed over
        if (p.ids.isNotEmpty()) {
            val held = HashSet<String>(p.ids.size * 4)
            store.forEachHeldMsgId { id -> held.add(hexOf(id)); true }
            for (id in p.ids) {
                val hx = hexOf(id)
                if (held.contains(hx)) continue
                var queued = false
                for (q in rel.wantQueue) if (q.contentEquals(id)) { queued = true; break }
                if (!queued && rel.wantQueue.size < MAX_WANTS_QUEUED) rel.wantQueue.add(id.copyOf())
            }
        }
        if (p.done == 1) rel.runDone = true
        return OwnerDecision.Accepted
    }

    /** HELLO subtype 3: the producer names a new snapshot; the consumer restarts. */
    private fun onReset(rel: Relation, rs: ControlPayloadV1.Reset): OwnerDecision {
        rel.lastHeardMono = monotonicNowMillis()
        discardRun(rel)
        rel.trackedSid = 0L                                // await the digest that proves the new sid
        rel.pendingSid = rs.newSnapshotId
        return OwnerDecision.Accepted
    }

    /** Re-inspect the accumulated stream of one closed run; null when coherent. */
    fun checkSequence(rel: Relation): String? {
        if (rel.delivered.isEmpty()) return "sequence_break"
        if (!rel.runDone) return "sequence_break"
        var previous: ByteArray? = null
        for (k in rel.delivered.indices) {
            val page = rel.delivered[k]
            if (page.snapshotId != rel.runSid) return "sequence_break"
            if (page.ids.size > ControlPayloadV1.MAX_IDS_PER_ARM) return "count_out_of_range"
            if (page.ids.isEmpty() && page.done != 1) return "bad_done"
            if (page.ids.isNotEmpty()) {
                if (previous != null &&
                    ControlPayloadV1.lexicographicCompare(page.ids[0], previous) <= 0) return "sequence_break"
                previous = page.ids[page.ids.size - 1]
            }
            if (page.done == 1 && k != rel.delivered.size - 1) return "sequence_break"
        }
        return null
    }

    // ------------------------------------------------------------------
    // the consumer's pump: bounded inventory runs (plan / pump / complete)
    // ------------------------------------------------------------------
    /** Open a run over the peer's tracked snapshot (initial encounter or the 5-minute period). */
    fun startInventoryRun(peer: ByteArray): Boolean {
        val rel = relationFor(peer)
        if (rel.trackedSid == 0L) return false
        if (!rel.runDone) return false                      // a run is already open
        rel.runSid = rel.trackedSid
        rel.runCursor = null
        rel.runDone = false
        rel.pagesRequested = 0
        rel.pagesReceived = 0
        rel.requestsSent = 0
        rel.delivered.clear()
        rel.wantQueue.clear()
        rel.lastInventoryRunMono = monotonicNowMillis()
        return true
    }

    /** Whether the period has arrived for a fresh exact-inventory run. */
    fun shouldScheduleInventory(peer: ByteArray, now: Long): Boolean {
        val rel = relationFor(peer)
        return rel.runDone && rel.trackedSid != 0L &&
            (rel.lastInventoryRunMono == 0L || now - rel.lastInventoryRunMono >= PERIODIC_INVENTORY_MS)
    }

    /** The next frames of the consumer's run; empty when the turn has yielded.
     * The page leg runs only while the walk is open; the want leg drains even
     * after the close -- the received-but-unheld ids must not be stranded. */
    fun pumpNextInventoryFrames(peer: ByteArray): List<FrameV2> {
        val rel = relationFor(peer)
        if (rel.runSid == 0L) return emptyList()
        val out = ArrayList<FrameV2>()
        if (!rel.runDone && rel.pagesRequested < MAX_PAGES_PER_RUN) {
            val cp = if (rel.runCursor == null) 0 else 1
            val cursor = rel.runCursor ?: ByteArray(ControlPayloadV1.ID_BYTES)
            val req = ControlPayloadV1.InventoryRequest(rel.runSid, cp, cursor)
            out.add(frameStamper(ControlPayloadV1.ControlArm.INVENTORY_REQUEST, req.encode()))
            rel.pagesRequested++
        }
        while (rel.requestsSent < MAX_WANTS_PER_RUN && rel.wantQueue.isNotEmpty()) {
            val take = minOf(rel.wantQueue.size, ControlPayloadV1.MAX_IDS_PER_ARM)
            val batch = ArrayList(rel.wantQueue.subList(0, take))
            rel.wantQueue.subList(0, take).clear()
            val w = ControlPayloadV1.Want(rel.runSid, batch)
            out.add(frameStamper(ControlPayloadV1.ControlArm.WANT, w.encode()))
            rel.requestsSent++                               // one requested frame per want payload
        }
        if (rel.pagesRequested >= MAX_PAGES_PER_RUN && rel.wantQueue.isEmpty() && out.isNotEmpty()) {
            rel.runDone = true                               // the budget spent: yield the turn
        }
        return out
    }

    /** The consumer's answered wants: requeue received ids still absent locally. */
    suspend fun pendingWants(peer: ByteArray): List<ByteArray> {
        val rel = relationFor(peer)
        return rel.wantQueue.toList()                        // the pump drains it in batches
    }

    // ------------------------------------------------------------------
    // the producer's pump: serve the current snapshot as a DIGEST frame
    // ------------------------------------------------------------------
    /** Build (do not send) the digest frame for our current snapshot. */
    suspend fun buildDigestFrame(): Pair<FrameV2, ControlPayloadV1.Digest>? {
        val snap = authority.currentSnapshot() ?: return null
        val payload = digestPayloadFor(snap)
        return Pair(frameStamper(ControlPayloadV1.ControlArm.DIGEST, payload.encode()), payload)
    }

    /** The canonical four rounds over the CAPTURED vector -- never the seen cache. */
    internal fun digestPayloadFor(snap: StableInventorySnapshot): ControlPayloadV1.Digest {
        val bloom = BloomDigest()
        for (id in snap.ids) bloom.add(id)
        return ControlPayloadV1.Digest(snap.snapshotId, bloom.toBytes())
    }

    /** Lease a snapshot for a consumer relation (the run pins its pages to it). */
    fun acquireLease(rel: Relation, snapshotId: Long): Boolean {
        val ok = authority.acquire(snapshotId)
        if (ok && !rel.leasedSids.contains(snapshotId)) rel.leasedSids.add(snapshotId)
        return ok
    }

    fun releaseLease(rel: Relation, snapshotId: Long): Boolean {
        val ok = authority.release(snapshotId)
        rel.leasedSids.remove(snapshotId)
        return ok
    }

    /** Discard an open or closed run: the next start begins from the top. */
    private fun discardRun(rel: Relation) {
        rel.runSid = 0L
        rel.runCursor = null
        rel.runDone = true
        rel.pagesRequested = 0
        rel.pagesReceived = 0
        rel.requestsSent = 0
        rel.delivered.clear()
        rel.wantQueue.clear()
    }

    companion object {
        const val MAX_PAGES_PER_RUN: Int = 64
        const val MAX_WANTS_PER_RUN: Int = 256
        const val MAX_WANTS_QUEUED: Int = 8192               // 256 frames x 32 ids: the queue may not outgrow the run
        const val PERIODIC_INVENTORY_MS: Long = 300_000L

        /** The honest stamper: ids derived by the frozen formula, tag from the id. */
        fun defaultStamper(
            localNodeId: ByteArray,
            monotonicNowMillis: () -> Long,
        ): (ControlPayloadV1.ControlArm, ByteArray) -> FrameV2 {
            var seq = 0L
            return { arm, payload ->
                seq++
                val nonce = ByteArray(16)
                ControlPayloadV1.putU64Be(nonce, 0, monotonicNowMillis() ushr 10)
                ControlPayloadV1.putU64Be(nonce, 8, seq)
                val msgId = MessageId.derive(localNodeId, monotonicNowMillis() / 1000L, nonce, payload)
                FrameV2(
                    type = arm.outerCode,
                    msgId = msgId,
                    routingTag = msgId.copyOfRange(0, 4),
                    ttl = 0,
                    hopCount = 0,
                    flags = 0,
                    payload = payload.copyOf(),
                )
            }
        }

        internal fun hexOf(id: ByteArray): String {
            val sb = StringBuilder(id.size * 2)
            for (b in id) {
                val v = b.toInt() and 0xFF
                sb.append(HEX[v ushr 4]).append(HEX[v and 0x0F])
            }
            return sb.toString()
        }

        private val HEX = "0123456789ABCDEF".toCharArray()
    }
}
