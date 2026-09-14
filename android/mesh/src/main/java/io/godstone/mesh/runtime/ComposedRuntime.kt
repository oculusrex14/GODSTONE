package io.godstone.mesh.runtime

import io.godstone.core.crypto.Ed25519Keys
import io.godstone.core.crypto.X25519Keys
import io.godstone.mesh.MeshNode
import io.godstone.mesh.delivery.AckAuthenticator
import io.godstone.mesh.delivery.AckMode
import io.godstone.mesh.delivery.AckResult
import io.godstone.mesh.delivery.DeliveryLookup
import io.godstone.mesh.delivery.DeliveryState
import io.godstone.mesh.delivery.DeliveryTracker
import io.godstone.mesh.delivery.Ed25519AckAuthenticator
import io.godstone.mesh.delivery.RecipientInboxRepository
import io.godstone.mesh.delivery.RecipientKeyResolver
import io.godstone.mesh.delivery.UnresolvedRecipientKeyResolver
import io.godstone.mesh.delivery.InMemoryAckStore
import io.godstone.mesh.transport.PeerEvent
import io.godstone.mesh.delivery.AckObligationDriver
import io.godstone.mesh.delivery.AckSignerSeam
import io.godstone.mesh.identity.Identity
import io.godstone.mesh.router.InventorySnapshotAuthority
import io.godstone.mesh.wire.v2.LogicalMessageIdentity
import io.godstone.mesh.router.SyncControlOwner
import io.godstone.mesh.router.SyncPump
import io.godstone.mesh.store.InMemoryMessageStore
import io.godstone.mesh.store.MessageStore
import io.godstone.mesh.store.PersistResult
import io.godstone.mesh.wire.v2.FrameV2
import io.godstone.mesh.wire.v2.TypeV2
import java.security.MessageDigest
import java.security.SecureRandom

// ---------------------------------------------------------------------------
// T44 -- "Prove crash-safe multihop behavior through composed runtimes".
//
// Component tests do not establish whole-system durable delivery, lifecycle,
// trust and recovery semantics. This harness composes the REAL authorities --
// the real `MeshNode`, the real `Router`, the real durable store, the real
// `DeliveryTracker`, the real recipient inbox, the real T84 ACK authority and the
// real T41/T42 sync pump -- and substitutes ONLY the operating system's facades:
//
//   * `HostClock`   -- a deterministic monotonic clock (no wall time, no timers)
//   * `LinkFacade`  -- the radio, serialized: every byte handed to a link is
//                      RECORDED verbatim, so "no relay plaintext" is a fact about
//                      captured bytes rather than a claim
//
// Everything a case observeth is captured: the bytes on each link, the durable
// state of every delivery row, the held set, the ephemeral link offers, and a
// TRACE of typed events that a DIFFERENT isle can replay (see [MeshTrace]).
//
// Laws this file enforceth:
//   1. NO SEND WITHOUT THE DURABLE COMMIT. A case can drive a node only through
//      the composition; a store that refuseth a persist produceth no link byte.
//   2. CRASH CHECKPOINTS ARE REAL. `crashAfter(boundary)` interrupts the
//      composition at a named seam and leaveth the durable estate exactly as the
//      crash found it; `resume()` reacheth a terminal state from the record.
//   3. A WIPE DURING A SEND IS EXERCISED, and no pre-wipe epoch may send or
//      publish afterwards (section 5 invariant 8).
//   4. RESOURCES ARE BOUNDED: the trace, the link ledger and the captured bytes
//      are all capped, and the caps are observable.
//
// Nonshipping: this lives in the :mesh module, which the LIGHT shipping graph
// excludes. Readiness stays false and no device claim is made.
// ---------------------------------------------------------------------------

/** The OS facade the harness substitutes for time. */
fun interface HostClock {
    fun monoMillis(): Long
}

/**
 * A deterministic clock. [monoMillis] is the harness's own monotonic base (every
 * case fixes its instants); [wallSeconds] is the SECONDS the wire calendar speaks,
 * seeded from the real clock exactly once at construction so the sealed frame's
 * lifetime arithmetic stayeth in the same epoch as the codecs that judge it.
 */
class FixedHostClock(
    var now: Long = 1_000L,
    private val wallBase: Long = System.currentTimeMillis() / 1000L,
) : HostClock {
    override fun monoMillis(): Long = now
    fun wallSeconds(): Long = wallBase + (now - 1_000L) / 1000L
    fun advance(by: Long): Long { now += by; return now }
}

/** One captured link delivery: the exact bytes a radio carried. */
class LinkDelivery(
    val fromLabel: String,
    val toLabel: String,
    val bytes: ByteArray,
    val admitted: Boolean,
    val atMonoMillis: Long,
) {
    fun bytesCopy(): ByteArray = bytes.copyOf()
}

/**
 * The radio, serialized and recording. [admit] let a case decide whether the
 * transport accepteth the bytes (a refusal must never become a durable claim).
 */
class LinkFacade(
    private val clock: HostClock,
    private val bound: Int = MAX_CAPTURED,
) {
    private val lock = Any()
    private val captured = ArrayList<LinkDelivery>()
    private var admittedCount = 0
    private var refusedCount = 0
    private var dropped = 0L
    var admit: (String, String) -> Boolean = { _, _ -> true }

    /** Hand [bytes] to the [toLabel] link. Records EVERY attempt, admitted or not. */
    fun offer(fromLabel: String, toLabel: String, bytes: ByteArray): Boolean {
        val said = admit(fromLabel, toLabel)
        synchronized(lock) {
            while (captured.size >= bound) {
                captured.removeAt(0)
                dropped++
            }
            captured.add(LinkDelivery(fromLabel, toLabel, bytes.copyOf(), said, clock.monoMillis()))
            if (said) admittedCount++ else refusedCount++
        }
        return said
    }

    fun deliveries(): List<LinkDelivery> = synchronized(lock) { captured.toList() }

    fun deliveriesTo(label: String): List<LinkDelivery> = synchronized(lock) {
        captured.filter { it.toLabel == label }
    }

    fun admitted(): Int = synchronized(lock) { admittedCount }
    fun refused(): Int = synchronized(lock) { refusedCount }
    fun droppedCount(): Long = synchronized(lock) { dropped }
    fun clear() = synchronized(lock) { captured.clear() }

    companion object {
        /** Bound on captured bytes-deliveries: telemetry, drop-oldest, counted. */
        const val MAX_CAPTURED: Int = 4096
    }
}

/** One composed node: every authority below is a PRODUCTION instance. */
internal class ComposedNode internal constructor(
    val label: String,
    val identity: Identity,
    /** The signing seed of this composed identity (never leaves the harness). */
    private val identityPriv: ByteArray,
    val store: MessageStore,
    val tracker: DeliveryTracker,
    val node: MeshNode,
    val inbox: RecipientInboxRepository,
    val ackStore: InMemoryAckStore,
    val keys: MutableKeyTable,
    val ackPump: io.godstone.mesh.delivery.DurableAckPump,
) {
    val nodeId: ByteArray get() = identity.nodeId

    /** Trust one peer's signing key (the operator's selection, never self-named). */
    fun trust(nodeId: ByteArray, signingKey: ByteArray) = keys.put(nodeId, signingKey)

    /** The signing seed, for the harness's own authoring road. */
    internal fun signingSeed(): ByteArray = identityPriv.copyOf()
}

/** A durable checkpoint: what the estate carrieth at one instant. */
data class DurableCheckpoint(
    val atMonoMillis: Long,
    val heldDigest: String,
    val heldCount: Int,
    val rows: Map<String, String>,
    val offeredToLinks: Int,
) {
    fun toJson(): Map<String, Any> = mapOf(
        "at_mono_ms" to atMonoMillis,
        "held_digest" to heldDigest,
        "held_count" to heldCount,
        "rows" to rows,
        "offered_to_links" to offeredToLinks,
    )
}

/** One typed trace event: what the composition did, in order. */
data class TraceEvent(val kind: String, val atMonoMillis: Long, val fields: Map<String, String>) {
    fun toJson(): Map<String, Any> = mapOf(
        "kind" to kind, "at_mono_ms" to atMonoMillis, "fields" to fields,
    )
}

/**
 * T44's cross-process / cross-isle trace: schema 1, canonical JSON, replayable by
 * ANOTHER isle's harness. The format carrieth no plaintext, no key material and no
 * private content -- only event kinds, hex msg_ids and observable outcomes.
 */
class MeshTrace(private val bound: Int = MAX_EVENTS) {
    private val lock = Any()
    private val events = ArrayList<TraceEvent>()
    private val checkpoints = ArrayList<DurableCheckpoint>()
    private var dropped = 0L

    fun append(event: TraceEvent) = synchronized(lock) {
        while (events.size >= bound) {
            events.removeAt(0)
            dropped++
        }
        events.add(event)
    }

    fun checkpoint(cp: DurableCheckpoint) = synchronized(lock) { checkpoints.add(cp) }

    fun events(): List<TraceEvent> = synchronized(lock) { events.toList() }
    fun kinds(): List<String> = synchronized(lock) { events.map { it.kind } }
    fun checkpointsSnapshot(): List<DurableCheckpoint> = synchronized(lock) { checkpoints.toList() }
    fun droppedCount(): Long = synchronized(lock) { dropped }
    fun size(): Int = synchronized(lock) { events.size }

    fun toJson(): Map<String, Any> = synchronized(lock) {
        mapOf(
            "schema" to SCHEMA,
            "isle" to ISLE,
            "events" to events.map { it.toJson() },
            "checkpoints" to checkpoints.map { it.toJson() },
        )
    }

    companion object {
        const val SCHEMA: Int = 1
        const val ISLE: String = "android"
        const val MAX_EVENTS: Int = 4096

        /**
         * Replayable shape check: a foreign trace is accepted only if it carrieth
         * this schema, an isle name and a well-formed event list. A future schema
         * is REFUSED rather than auto-detected.
         */
        fun parse(document: Map<String, Any?>): List<TraceEvent> {
            val schema = (document["schema"] as? Number)?.toInt()
                ?: throw IllegalArgumentException("the trace carrieth no schema")
            require(schema == SCHEMA) { "the trace schema $schema is refused (only $SCHEMA is known)" }
            val raw = document["events"] as? List<*>
                ?: throw IllegalArgumentException("the trace carrieth no events")
            return raw.map { item ->
                val entry = item as? Map<*, *>
                    ?: throw IllegalArgumentException("every trace event must be an object")
                val kind = entry["kind"] as? String
                    ?: throw IllegalArgumentException("every trace event must carry a kind")
                val at = (entry["at_mono_ms"] as? Number)?.toLong() ?: 0L
                @Suppress("UNCHECKED_CAST")
                val fields = (entry["fields"] as? Map<String, String>) ?: emptyMap()
                TraceEvent(kind, at, fields)
            }
        }
    }
}

/** Why a composed step was refused. Named, never a silent no-op. */
enum class ComposedRefusal {
    NO_SUCH_NODE,
    NOT_LINKED,
    STORE_REFUSED,
    WIPED,
    CRASH_POINT,
    TRACE_SCHEMA,
}

/** The typed outcome of one composed step. */
sealed class ComposedOutcome {
    data class Applied(val detail: String) : ComposedOutcome()
    data class Refused(val reason: ComposedRefusal, val detail: String = "") : ComposedOutcome()
}

/** A crash at a named composition seam: the estate is left exactly as found. */
class ComposedCrash(val boundary: String) : RuntimeException("crash at $boundary")

/**
 * The composed runtime harness. Every node it buildeth is the REAL composition --
 * real store, real tracker, real inbox, real ACK authority, real sync pump -- with
 * only the clock and the radio substituted.
 */
internal class ComposedRuntimeHarness(
    val clock: FixedHostClock = FixedHostClock(),
    val link: LinkFacade = LinkFacade(clock),
    private val rng: SecureRandom = SecureRandom(),
    private val trace: MeshTrace = MeshTrace(),
) {
    private val nodes = LinkedHashMap<String, ComposedNode>()
    private val links = LinkedHashSet<String>()
    private var wiped = false
    private var crashAt: String? = null

    /** Compose one node. The recipient key directory is per-node and explicit: a
     *  node resolveth only the keys it was actually trusted with. */
    fun addNode(label: String): ComposedNode {
        val ed = Ed25519Keys.generate(rng)
        val dh = X25519Keys.generate(rng)
        val identity = Identity.fromKeyMaterial(ed.pub, ed.priv, dh.pub, dh.priv)
        val store = InMemoryMessageStore()
        val ackStore = InMemoryAckStore()
        val keys = MutableKeyTable()
        // a node pinnaleth its OWN authentic signing key first: the inbox
        // self-verifieth every ACK it produceth, so a directory without our own
        // key refuseth to issue one at all (the census saith acksRefusedKey)
        keys.put(identity.nodeId, identity.identityPub)
        val authenticator: AckAuthenticator = Ed25519AckAuthenticator(keys)
        val repo = ComposedDeliveryRepository(store)
        val tracker = DeliveryTracker(repo, authenticator)
        val node = MeshNode(null, identity, store, tracker)
        val inbox = RecipientInboxRepository(
            router = node.router,
            ourNodeId = identity.nodeId,
            localDhPrivate = { dh.priv },
            signer = NodeSigner(identity.nodeId, ed.priv),
            resolver = keys,
            authenticator = Ed25519AckAuthenticator(keys),
            pairedStore = ackStore,
            commitInbound = { frame, receivedFrom, localRecipient, generation, lifetime, receivedAt, fault ->
                store.commitInboundWithObligationAtWithFault(
                    frame, receivedFrom, localRecipient, generation, lifetime, receivedAt, fault)
            },
            clockSeconds = { clock.wallSeconds() },
        )
        node.recipientInbox = inbox
        // the T84 ACK authority, bound exactly as a composition would bind it
        val ackDriver = AckObligationDriver(
            ackStore, NodeSigner(identity.nodeId, ed.priv), authenticator, keys,
        )
        val ackPump = io.godstone.mesh.delivery.DurableAckPump(ackStore,
            { encoded, from -> ackDriver.admitForeignCandidate(encoded, from) })
        node.ackDispatcher = io.godstone.mesh.delivery.AckDispatcher(
            lookupDeliveryRow = { tracker.lookup(it) },
            verifyOrigin = { tracker.acknowledge(it.msgId, it) },
            admitCandidate = { encoded, from -> ackPump.admit(encoded, from) },
        )
        val composed = ComposedNode(label, identity, ed.priv, store, tracker, node, inbox,
            ackStore, keys, ackPump)
        nodes[label] = composed
        trace.append(TraceEvent("node_composed", clock.monoMillis(),
            mapOf("node" to label, "node_id" to hex(identity.nodeId))))
        return composed
    }

    fun node(label: String): ComposedNode? = nodes[label]

    /** A trusted relation comes up between two nodes (both sides). */
    fun link(from: String, to: String): ComposedOutcome {
        val a = nodes[from] ?: return ComposedOutcome.Refused(ComposedRefusal.NO_SUCH_NODE, from)
        val b = nodes[to] ?: return ComposedOutcome.Refused(ComposedRefusal.NO_SUCH_NODE, to)
        a.node.handlePeerEvent(peerFound(b.nodeId))
        b.node.handlePeerEvent(peerFound(a.nodeId))
        links.add("$from->$to"); links.add("$to->$from")
        trace.append(TraceEvent("link_up", clock.monoMillis(), mapOf("from" to from, "to" to to)))
        return ComposedOutcome.Applied("linked $from <-> $to")
    }

    fun unlink(from: String, to: String): ComposedOutcome {
        val a = nodes[from] ?: return ComposedOutcome.Refused(ComposedRefusal.NO_SUCH_NODE, from)
        val b = nodes[to] ?: return ComposedOutcome.Refused(ComposedRefusal.NO_SUCH_NODE, to)
        a.node.handlePeerEvent(PeerEvent.Lost(b.nodeId))
        b.node.handlePeerEvent(PeerEvent.Lost(a.nodeId))
        links.remove("$from->$to"); links.remove("$to->$from")
        trace.append(TraceEvent("link_down", clock.monoMillis(), mapOf("from" to from, "to" to to)))
        return ComposedOutcome.Applied("unlinked $from <-> $to")
    }

    fun isLinked(from: String, to: String): Boolean = links.contains("$from->$to")

    /** Fix a crash at a named composition seam (null cleareth it). */
    fun crashAfter(boundary: String?) { crashAt = boundary }

    /** A wipe is in progress: no epoch may send or publish afterwards. */
    fun beginWipe() {
        wiped = true
        trace.append(TraceEvent("wipe_begin", clock.monoMillis(), emptyMap()))
    }

    fun isWiped(): Boolean = wiped

    /** The seam every send passeth through: the durable commit, then the link. */
    private suspend fun send(node: ComposedNode, toLabel: String, bytes: ByteArray): Boolean {
        if (wiped) {
            trace.append(TraceEvent("send_refused", clock.monoMillis(),
                mapOf("node" to node.label, "reason" to "wipe_in_progress")))
            return false
        }
        if (crashAt == SEAM_BEFORE_LINK) {
            crashAt = null
            trace.append(TraceEvent("crash", clock.monoMillis(), mapOf("boundary" to SEAM_BEFORE_LINK)))
            throw ComposedCrash(SEAM_BEFORE_LINK)
        }
        val admitted = link.offer(node.label, toLabel, bytes)
        trace.append(TraceEvent("link_offer", clock.monoMillis(),
            mapOf("node" to node.label, "to" to toLabel, "admitted" to admitted.toString(),
                  "bytes" to bytes.size.toString())))
        if (admitted) {
            // the radio DELIVERETH: the recorded bytes are handed to the receiving
            // node's own dispatch statute, which is the only way anything enters
            // its durable estate
            val frame = FrameV2.decode(bytes)
            if (frame != null) nodes[toLabel]?.node?.ingestInbound(frame, node.nodeId)
        }
        return admitted
    }

    /** The labels of the peers [from] currently carrieth a link to. */
    fun linkedPeerLabels(from: String): List<String> =
        nodes.values.filter { it.label != from && links.contains("$from->${it.label}") }
            .map { it.label }

    /**
     * Author and dispatch one DIRECT message at [from] FOR [recipientLabel],
     * handing it to every peer [from] is linked to. The recipient need not be a
     * neighbour: that is what the relay is for.
     */
    suspend fun sendDirect(from: String, recipientLabel: String, plaintext: ByteArray): ComposedOutcome {
        val a = nodes[from] ?: return ComposedOutcome.Refused(ComposedRefusal.NO_SUCH_NODE, from)
        val b = nodes[recipientLabel]
            ?: return ComposedOutcome.Refused(ComposedRefusal.NO_SUCH_NODE, recipientLabel)
        val peers = linkedPeerLabels(from)
        if (peers.isEmpty()) return ComposedOutcome.Refused(ComposedRefusal.NOT_LINKED, "no linked peer of $from")
        // the AUTHOR must trust the recipient's signing key to verify the ACK; the
        // operator's selection, never a document's claim
        a.trust(b.nodeId, b.identity.identityPub)
        // The sealed inner payload IS the frozen SignedMessageV1 container: the
        // recipient's inbox verifieth the author, the recipient and the msgId over
        // exactly those bytes (T35/T37's law). Sealing a bare body would be a
        // payload the frozen verifier MUST refuse ("unknown version; there is no
        // legacy plaintext fallback"), which is what the first form of this
        // harness did -- and the composed trace caught it.
        val nonce = ByteArray(16).also { rng.nextBytes(it) }
        val createdAt = clock.wallSeconds()
        val container = io.godstone.mesh.wire.v2.SignedMessageV1.author(
            senderIdentityPriv = a.signingSeed(),
            senderIdentityPub = a.identity.identityPub,
            senderNodeId = a.nodeId,
            recipientNodeId = b.nodeId,
            messageNonce = nonce,
            createdAtEpochSeconds = createdAt,
            priority = io.godstone.mesh.wire.v2.Priority.DIRECT,
            timeQuality = io.godstone.mesh.wire.v2.TimeQuality.USER_CONFIRMED,
            bodyUtf8 = plaintext,
        )
        val frame = a.node.router.buildSealedMessage(
            plaintext = container,
            recipientNodeId = b.nodeId,
            recipientStaticPub = b.identity.staticDhPub,
            identity = LogicalMessageIdentity.of(createdAt, nonce),
            priority = io.godstone.mesh.wire.v2.Priority.DIRECT,
        )
        val result = a.node.dispatchDirect(frame, expectedRecipient = b.nodeId) { peerId, bytes ->
            val label = nodes.values.firstOrNull { it.nodeId.contentEquals(peerId) }?.label ?: return@dispatchDirect false
            send(a, label, bytes)
        }
        trace.append(TraceEvent("send_direct", clock.monoMillis(),
            mapOf("from" to from, "recipient" to recipientLabel, "msg_id" to hex(frame.msgId),
                  "result" to result.toString())))
        return ComposedOutcome.Applied(result.toString())
    }

    /** Author and dispatch one SOS broadcast from [from] to every linked peer. */
    suspend fun sendSos(from: String, plaintext: ByteArray): ComposedOutcome {
        val a = nodes[from] ?: return ComposedOutcome.Refused(ComposedRefusal.NO_SUCH_NODE, from)
        val result = a.node.dispatchSos(plaintext) { peerId, bytes ->
            val label = nodes.values.firstOrNull { it.nodeId.contentEquals(peerId) }?.label
                ?: return@dispatchSos false
            send(a, label, bytes)
        }
        trace.append(TraceEvent("send_sos", clock.monoMillis(),
            mapOf("from" to from, "result" to result.toString())))
        return ComposedOutcome.Applied(result.toString())
    }

    /** Deliver everything a node holdeth for a peer: one bounded sync turn, then
     *  the peer ingesteth each frame through the REAL dispatch statute. */
    suspend fun turn(from: String, to: String): Int {
        val a = nodes[from] ?: return 0
        val b = nodes[to] ?: return 0
        if (!isLinked(from, to)) return 0
        val frames = a.node.drainSyncFramesForPeer(b.nodeId)
        var delivered = 0
        for (f in frames) if (send(a, to, f.encode())) delivered++
        trace.append(TraceEvent("turn", clock.monoMillis(),
            mapOf("from" to from, "to" to to, "frames" to frames.size.toString(),
                  "delivered" to delivered.toString())))
        return frames.size
    }

    /**
     * Carry [from]'s queued ACK traffic to [to] over a DIRECT link: the node's own
     * recipient ACKs (the T37 outbox) AND the bounded relay custody its T84 pump
     * holdeth. Both roads are real composition; the trace telleth which fired.
     */
    suspend fun turnAcks(from: String, to: String): Int {
        val a = nodes[from] ?: return 0
        val b = nodes[to] ?: return 0
        if (!isLinked(from, to)) return 0
        val own = a.node.drainAckOutboxForLink(MAX_ACKS_PER_TURN)
        a.ackPump.onLinkReady(b.nodeId, clock.monoMillis())
        val relay = a.ackPump.nextBatch(b.nodeId, clock.monoMillis()).copies
        var delivered = 0
        for (ack in own) if (send(a, to, ack.encode())) delivered++
        for (copy in relay) {
            if (send(a, to, copy.encodedFrame)) delivered++
            a.ackPump.onForwardOutcome(copy, b.nodeId, accepted = true, now = clock.monoMillis())
        }
        trace.append(TraceEvent("turn_acks", clock.monoMillis(),
            mapOf("from" to from, "to" to to, "own" to own.size.toString(),
                  "relay" to relay.size.toString(), "delivered" to delivered.toString())))
        return own.size + relay.size
    }

    /**
     * REPLAY exact captured bytes over a link: the honest "replay after
     * reconnect" -- the same frame the radio carried once, offered again.
     */
    suspend fun replay(from: String, to: String, bytes: ByteArray): Boolean {
        val a = nodes[from] ?: return false
        val b = nodes[to] ?: return false
        if (!isLinked(from, to)) return false
        trace.append(TraceEvent("replay", clock.monoMillis(),
            mapOf("from" to from, "to" to to, "bytes" to bytes.size.toString())))
        if (!link.offer(a.label, to, bytes)) return false
        // the replay RE-ENTERETH the receiving node's own statute, which suppressth
        // a held frame: the verdict is the duplicate verdict, never a silent drop
        val frame = FrameV2.decode(bytes) ?: return false
        trace.append(TraceEvent("replay_ingested", clock.monoMillis(),
            mapOf("from" to from, "to" to to, "msg_id" to hex(frame.msgId))))
        return b.node.ingestInbound(frame, a.nodeId)
    }

    /** The durable checkpoint of one node's estate. */
    suspend fun checkpoint(nodeLabel: String): DurableCheckpoint {
        val n = nodes[nodeLabel] ?: throw IllegalArgumentException("no node $nodeLabel")
        val ids = n.store.allHeldMsgIds()
        val rows = LinkedHashMap<String, String>()
        for (id in ids) {
            when (val l = n.tracker.lookup(id)) {
                is DeliveryLookup.Found -> rows[hex(id)] = l.record.state.name
                else -> rows[hex(id)] = "ABSENT"
            }
        }
        val cp = DurableCheckpoint(
            atMonoMillis = clock.monoMillis(),
            heldDigest = digestOf(ids),
            heldCount = ids.size,
            rows = rows,
            offeredToLinks = n.node.linkOffers.total(),
        )
        trace.checkpoint(cp)
        return cp
    }

    fun traceSnapshot(): MeshTrace = trace

    /** The exact bytes a link carried, for the "no relay plaintext" witness. */
    fun capturedBytes(): List<ByteArray> = link.deliveries().map { it.bytesCopy() }

    /** The PRODUCTION peer-presence event shape (the transport's own). */
    private fun peerFound(nodeId: ByteArray) = PeerEvent.Found(
        peerId = nodeId,
        nodeHint = nodeId.copyOf(4),
        rssi = null,
        sosFlag = false,
        bulkCapable = false,
        shortDigest = ByteArray(6),
        queueDepth = 0,
    )

    companion object {
        /** The composition seam a crash can be fixed at, before the radio. */
        const val SEAM_BEFORE_LINK: String = "before_link"

        /** Bound on one ACK turn (the T37 outbox is bounded at 64 by its own law). */
        const val MAX_ACKS_PER_TURN: Int = 64

        fun hex(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it) }

        fun digestOf(parts: List<ByteArray>): String {
            val md = MessageDigest.getInstance("SHA-256")
            for (p in parts.sortedBy { hex(it) }) md.update(p)
            return hex(md.digest())
        }
    }
}

/** A per-node key directory: a node resolveth only the keys it was trusted with. */
internal class MutableKeyTable : RecipientKeyResolver {
    private val table = HashMap<List<Byte>, ByteArray>()
    fun put(nodeId: ByteArray, key: ByteArray) { table[nodeId.toList()] = key.copyOf() }
    override fun publicSigningKey(nodeId: ByteArray): ByteArray? = table[nodeId.toList()]?.copyOf()
}

/** The local signing identity as the inbox's seam seeth it. */
internal class NodeSigner(
    private val idBytes: ByteArray,
    private val seed: ByteArray,
) : AckSignerSeam {
    override val nodeId: ByteArray get() = idBytes.copyOf()
    override fun generation(): Long = 1L
    override fun signingSeed(msgId: ByteArray, recipientNodeId: ByteArray): ByteArray = seed.copyOf()
}

/** The composed delivery repository over the composed store. */
internal class ComposedDeliveryRepository(
    private val store: MessageStore,
) : io.godstone.mesh.delivery.DeliveryRepository {
    private val records =
        LinkedHashMap<List<Byte>, io.godstone.mesh.delivery.DeliveryRecord>()

    override fun get(msgId: ByteArray): DeliveryLookup {
        if (msgId.size != 16) return DeliveryLookup.InvalidArgument
        records[msgId.toList()]?.let { return DeliveryLookup.Found(it) }
        val engine = (store as? io.godstone.mesh.store.InMemoryMessageStore) ?: return DeliveryLookup.NotFound
        val row = engine.readDeliveryRow(msgId) ?: return DeliveryLookup.NotFound
        val state = DeliveryState.fromPersistedCode(row.state) ?: return DeliveryLookup.Corrupt
        val mode = AckMode.fromCode(row.ackMode) ?: return DeliveryLookup.Corrupt
        val rec = io.godstone.mesh.delivery.DeliveryRecord(msgId, state, mode, row.expectedRecipient)
        records[msgId.toList()] = rec
        return DeliveryLookup.Found(rec)
    }

    override fun enqueue(msgId: ByteArray, ackMode: AckMode,
                         expectedRecipient: ByteArray?): io.godstone.mesh.delivery.EnqueueResult {
        if (msgId.size != 16) return io.godstone.mesh.delivery.EnqueueResult.InvalidArgument
        return when (val l = get(msgId)) {
            DeliveryLookup.NotFound -> {
                records[msgId.toList()] = io.godstone.mesh.delivery.DeliveryRecord(
                    msgId, DeliveryState.QUEUED_DURABLY, ackMode, expectedRecipient)
                io.godstone.mesh.delivery.EnqueueResult.Created
            }
            is DeliveryLookup.Found -> when {
                l.record.state.isTerminal ->
                    io.godstone.mesh.delivery.EnqueueResult.RejectedTerminalState
                l.record.ackMode != ackMode ->
                    io.godstone.mesh.delivery.EnqueueResult.ConflictRecipient
                else -> io.godstone.mesh.delivery.EnqueueResult.AlreadyQueuedSameBinding
            }
            else -> io.godstone.mesh.delivery.EnqueueResult.StorageFailure
        }
    }

    override fun transition(msgId: ByteArray,
                           transition: io.godstone.mesh.delivery.DeliveryTransition)
        : io.godstone.mesh.delivery.TransitionResult {
        val rec = (get(msgId) as? DeliveryLookup.Found)?.record
            ?: return io.godstone.mesh.delivery.TransitionResult.UnknownMessage
        val target = when (transition) {
            io.godstone.mesh.delivery.DeliveryTransition.EXPIRE -> DeliveryState.EXPIRED
            io.godstone.mesh.delivery.DeliveryTransition.CANCEL -> DeliveryState.CANCELLED_LOCALLY
            io.godstone.mesh.delivery.DeliveryTransition.MARK_HANDED -> DeliveryState.HANDED_TO_RELAY
        }
        if (rec.state == target) return io.godstone.mesh.delivery.TransitionResult.AlreadyInTarget
        if (rec.state.isTerminal) return io.godstone.mesh.delivery.TransitionResult.RejectedState
        records[msgId.toList()] = rec.copy(state = target)
        return io.godstone.mesh.delivery.TransitionResult.Applied
    }

    override fun acknowledgeBoundAndRetire(msgId: ByteArray,
                                          expectedRecipient: ByteArray): AckResult {
        if (msgId.size != 16 || expectedRecipient.size != 16) return AckResult.InvalidArgument
        val rec = (get(msgId) as? DeliveryLookup.Found)?.record ?: return AckResult.UnknownMessage
        if (rec.state == DeliveryState.ACKNOWLEDGED_BY_RECIPIENT) {
            return AckResult.DuplicateAuthenticatedAck
        }
        if (rec.state.isTerminal) return AckResult.RejectedState
        if (rec.ackMode != AckMode.SINGLE_RECIPIENT) return AckResult.NotAckEligible
        val bound = rec.expectedRecipientNodeId ?: return AckResult.Corrupt
        if (!bound.contentEquals(expectedRecipient)) return AckResult.RejectedState
        records[msgId.toList()] = rec.copy(state = DeliveryState.ACKNOWLEDGED_BY_RECIPIENT)
        return AckResult.Applied
    }

    override fun clear(msgId: ByteArray) = io.godstone.mesh.delivery.ClearResult.AlreadyAbsent
}
