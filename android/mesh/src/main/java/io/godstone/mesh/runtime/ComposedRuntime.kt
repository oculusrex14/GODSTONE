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
    /**
     * *** GS-FINAL-003 `same-estate`: THE ACK NAMESPACE, AS THE ESTATE'S OWN OWNER. ***
     *
     * *A resource model supplies its in-memory store; the launchable composition supplies the REAL on-disk ACK
     * namespace the wipe must erase. The type is the INTERFACE because a real store and a model have to be
     * interchangeable here -- and `ComposedRuntimeHarness.addNode` picks the production tracker whenever the store
     * is a real `SqliteMessageStore`, so the durable and modelled roads never mix.*
     */
    val ackStore: io.godstone.mesh.delivery.AckObligationStore,
    val keys: MutableKeyTable,
    val ackPump: io.godstone.mesh.delivery.DurableAckPump,
    /**
     * *** GS-FINAL-003 `selfsame-send` (review A6): THE ESTATE'S PRODUCT SEND ROAD, WHEN IT OWNS ONE. ***
     *
     * *A composition over a REAL estate runneth the PRODUCT command (`SendDirectAuthority`): it resolveth the
     * recipient's trust through the estate's directory (so a REVOKED peer is refused BY NAME), minteth one explicit
     * intent, and write-aheadeth it to the estate's durable ledger -- so a retry loadeth the SAME authored bytes.*
     * **A pure resource model carrieth `null` and useth the harness's own authoring road, which is REAL but narrower,
     * and that difference is NAMED here rather than hidden.***
     */
    val directSend: io.godstone.mesh.delivery.SendDirectAuthority? = null,
) {
    val nodeId: ByteArray get() = identity.nodeId

    /** Trust one peer's signing key (the operator's selection, never self-named). */
    fun trust(nodeId: ByteArray, signingKey: ByteArray) = keys.put(nodeId, signingKey)

    /** The signing seed, for the harness's own authoring road. */
    internal fun signingSeed(): ByteArray = identityPriv.copyOf()
}

/**
 * *** GS-FINAL-003 `same-estate`: THE ESTATE'S OWN OWNERS, SUPPLIED BY WHOEVER WROTE THEM. ***
 *
 * *THE OBLIGATION: **"Use production normal owner with actual on-disk stores/real identity and same runtime authority
 * Send/SOS operate. No fake in-memory under real app."*** **The harness asks the estate owner for these three, so a
 * real composition's nodes run over the REAL files and a wipe retires exactly what a send used.** *A resource model
 * leaves [ComposedRuntimeHarness.estate] null and never reaches this.*
 */
interface ComposedEstateFactories {
    /** The identity the estate stored under [label] (its own key material, loaded or created by the owner). */
    fun identityFor(label: String): Identity

    /** The durable message store the estate opened for [label]. */
    fun storeFor(label: String): MessageStore

    /** The durable ACK namespace the estate opened for [label]. */
    fun ackStoreFor(label: String): io.godstone.mesh.delivery.AckObligationStore

    /**
     * *** THE ESTATE'S OWN WRITE-AHEAD INTENT LEDGER (review A6). ***
     *
     * *THE OBLIGATION: **"Real Send durable transaction ... retry load identical persisted bytes."*** **The harness's own
     * authoring road never touched the product's intent ledger, so a retry across a relaunch could not load the SAME
     * pinned bytes.** *An estate that carrieth a durable ledger answers HERE -- a real `SQLiteOpenHelper` over the
     * label's own directory -- and the harness's send road then runs the PRODUCT command over it.*
     *
     * *The default is the in-memory reference implementation, which is honest for a pure resource model and is NAMED as
     * such rather than silently substituted for a real medium.*
     */
    fun intentLedgerFor(label: String): io.godstone.mesh.delivery.OutboundIntentJournal =
        io.godstone.mesh.delivery.InMemoryOutboundIntentJournal()

    /**
     * *** THE ESTATE'S OWN PEER DIRECTORY, SO TRUST IS RESOLVED RATHER THAN ASSUMED. ***
     *
     * *A revoked or quarantined recipient must be REFUSED BY NAME; a road that never asked the directory could not
     * refuse one.* **The labels and their pinned material come from the estate that composed them.**
     */
    fun peerDirectory(): Map<String, ComposedPeerMaterial> = emptyMap()

    /**
     * *** THE FILES THIS ESTATE WROTE, BY THEIR REAL PATHS. ***
     *
     * *A wipe that could not name the estate's own bytes would have to guess, and the isle has already paid for that
     * twice (review A5/A10: cwd-relative aliases and logical names addressed files nobody wrote).* **The owner that
     * created the files is the one that can name them, so it must.**
     */
    fun ownedArtifactPaths(): List<String>
}

/** *** THE ESTATE'S OWN VIEW OF ONE PEER: exactly what a durable trust row carrieth. *** */
class ComposedPeerMaterial(
    val nodeId: ByteArray,
    val signingPub: ByteArray,
    val staticDhPub: ByteArray,
    val acceptedGeneration: Long,
    val trust: ComposedPeerTrust = ComposedPeerTrust.ACCEPTED,
) {
    override fun equals(other: Any?): Boolean = other is ComposedPeerMaterial &&
        nodeId.contentEquals(other.nodeId) && signingPub.contentEquals(other.signingPub) &&
        staticDhPub.contentEquals(other.staticDhPub) && acceptedGeneration == other.acceptedGeneration &&
        trust == other.trust

    override fun hashCode(): Int =
        31 * (31 * (31 * nodeId.contentHashCode() + signingPub.contentHashCode()) +
            staticDhPub.contentHashCode()) + acceptedGeneration.hashCode() + trust.hashCode()
}

/**
 * *** WHETHER THIS PEER MAY BE SENT TO, AS THE ESTATE DECIDES -- THE THREE CASES THE OBLIGATION NAMETH. ***
 *
 * *`ACCEPTED` is the pinned/verified case; `QUARANTINED` is a pending rotation the estate holdeth but will not send to;
 * `REVOKED` is the withdrawn trust the authority must refuse BY NAME.*
 */
enum class ComposedPeerTrust { ACCEPTED, QUARANTINED, REVOKED }

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
 * *** GS-FINAL-003 `same-estate` (review A6/A6-expanded): THE TYPED ANSWER TO "MAY A NORMAL PRIVATE COMPOSITION
 * PROCEED ON THIS ESTATE?" ***
 *
 * *A BOOLEAN WAS REJECTED BY THE AUDIT ON THE DECISION ROAD FOR A REASON THAT APPLIETH HERE TOO: it carrieth no cause,
 * so a court that observed `false` could not tell a correct refusal from a wiring fault.* **A refusal therefore NAMES
 * itself, which is what maketh it falsifiable.**
 */
sealed class NormalEstateVerdict {
    /** The estate is a PROVEN clean one, or a wipe that ran to its end. Private composition may proceed. */
    data object Admitted : NormalEstateVerdict()

    /** The estate refuses: a wipe is outstanding, the record is unreadable, or no authority was bound at all. */
    data class Refused(val reason: String) : NormalEstateVerdict()
}

/**
 * *** THE SAME-ESTATE ADMISSION GATE: ASKED ONCE, BEFORE THE FIRST PRIVATE EFFECT. ***
 *
 * *THE REVIEW'S A6-EXPANDED CHARGE IS EXACTLY THAT NOTHING ASKED THIS QUESTION ON THE LAUNCHABLE LAB PATH: the
 * `MeshNode` convenience constructor hardcoded `WipeSensitiveUseGate { true }`, so the app composed real signing/DH
 * identities, message stores, ACK stores and peer nodes while a separate rendered wipe reported a pending or corrupt
 * record.* **A GATE THAT IS ASKED MAKETH THAT IMPOSSIBLE BY CONSTRUCTION: [ComposedRuntimeHarness.addNode] refuses
 * before the first allocation.**
 *
 * *** AND THE UNBOUND VALUE REFUSES RATHER THAN PERMITS. *** *A default of "allow" is the defect itself; a default of
 * "refuse" meaneth a caller that forgot to bind the real owner getteth a loud, typed refusal instead of a silently
 * private estate.* **Pure-host resource-model courts bind [Testing] EXPLICITLY, so the allowance is a visible act at
 * one call site rather than an ambient default.**
 */
fun interface NormalEstateGate {
    fun admit(): NormalEstateVerdict

    companion object {
        /**
         * *** THE DEFAULT FOR EVERY HARNESS THAT WAS NOT GIVEN AN OWNER -- AND IT REFUSES. ***
         *
         * *This is the single most important line in the A6 repair: the old default was the always-admit convenience,
         * and it was reached by the LAUNCHABLE APPLICATION. A harness that owns no journal cannot honestly answer "may
         * private composition proceed", so it sayeth so and composes nothing.*
         */
        val Unbound: NormalEstateGate = NormalEstateGate {
            NormalEstateVerdict.Refused(
                "no same-estate recovery authority is bound to this composition; a normal private estate " +
                    "may not be created without one",
            )
        }

        /**
         * *** THE PURE-HOST ALLOWANCE, BOUND EXPLICITLY BY THE COURTS THAT OWN NO DURABLE ESTATE. ***
         *
         * *`ComposedRuntimeHarness` is a RESOURCE MODEL: its nodes live in memory, it writes no journal and it survives
         * no relaunch. A court driving it is testing the composition's resource semantics, not a device's estate, so
         * the honest gate is "this model owns no estate to protect".* **THE NAME SAYETH SO, and no application path
         * binds it -- `LabMeshApplication` binds the real decision instead.**
         */
        val Testing: NormalEstateGate = NormalEstateGate { NormalEstateVerdict.Admitted }
    }
}

/**
 * *** GS-FINAL-003 `same-estate`: WHAT A WIPE MUST DRAIN, RETIRE AND ERASE ON THIS COMPOSITION. ***
 *
 * *THE OBLIGATION: **"Begin wipe must drain/retire actual live owner and same key/message/peer/intent/ACK estate, old
 * work refused, resume/relaunch uses same estate."*** **A composition that owns real stores answers here, so the wipe's
 * first rung reaches THE SAME OWNER the send/SOS road used -- rather than a flag beside it.***
 *
 * *** AND IT IS ASKED ONCE, BY THE OWNER THAT BUILT THE ESTATE, RATHER THAN RE-DERIVED BY THE WIPE. *** *A second
 * resolution of "which files are mine" is a second place for it to go stale; the harness that composed the nodes is the
 * one thing that knows what it allocated.*
 */
interface ComposedEstateOwnership {
    /**
     * Drain in-flight work and RETIRE the live owner: after this returns, every node composed by this harness must
     * REFUSE to send, publish or persist (the wipe's own `wiped` flag is set alongside), and the caller may then erase
     * the estate's bytes knowing no writer is still running.
     *
     * Returns the number of owners retired, so "nothing was retired" is a MEASUREMENT rather than an assumption.
     */
    fun retireLiveOwners(): Int

    /** The names of the durable artifacts this composition wrote -- so a wipe can address them by their REAL paths. */
    fun ownedArtifactPaths(): List<String>
}

/** A crash at a composition seam. See [ComposedRuntimeHarness.SEAM_BEFORE_LINK]. */

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
) : ComposedEstateOwnership {
    private val nodes = LinkedHashMap<String, ComposedNode>()
    private val links = LinkedHashSet<String>()
    private var wiped = false
    private var crashAt: String? = null

    /**
     * *** GS-FINAL-003 `same-estate` (review A6): THE ADMISSION QUESTION A NORMAL COMPOSITION MUST ASK. ***
     *
     * *THE REVIEW'S CHARGE, VERBATIM: **"The supposedly host-only always-admit helper is on the actual launchable lab
     * path ... This is not test-source-only or an unreachable host helper: the real LabMeshApplication reaches it ... A
     * persisted lab REQUESTED/corrupt journal is never consulted by this bootstrap."***
     *
     * *** SO THE HARNESS NO LONGER ASSUMES: THE ADMISSION IS ASKED, ONCE PER NODE, BEFORE ANY EFFECT. *** *A caller
     * that owns an ON-DISK estate binds the SAME-ESTATE gate here; [NormalEstateGate.Unbound] is the ONLY value a
     * pure-host composition may carry, and it REFUSETH to compose rather than silently allowing.* **The launchable lab
     * application binds the real gate (see `LabRuntime.composeRealEstate`), so "the app consults the recovery owner
     * before it composes anything private" is a property of the code rather than of a comment.**
     */
    var admitNormalEstate: NormalEstateGate = NormalEstateGate.Unbound

    /**
     * *** THE REFUSAL, TYPED SO IT CANNOT BE MISTAKEN FOR A CONSTRUCTION. ***
     *
     * *A composition that refused leaveth NO identity, NO store, NO ACK row and NO peer node behind: this throweth
     * BEFORE the first effect, so the caller's own `catch` is the whole boundary and there is nothing to unwind.*
     */
    class NormalEstateRefused(val label: String, val reason: String) :
        IllegalStateException("normal private composition of '$label' was refused: $reason")

    /**
     * *** GS-FINAL-003 `same-estate`: THE ESTATE'S OWN OWNERS, WHEN THE COMPOSITION OWNS REAL ONES. ***
     *
     * *A resource model allocates in memory. **A LAUNCHABLE COMPOSITION OWNS FILES**: the identity material, the message
     * database and its sidecars, the wrapped-key preferences, the ACK namespace and the peer-trust store -- the very
     * bytes a wipe must delete and a relaunch must re-open.* **THE HARNESS THEREFORE TAKES THE OWNERS FROM WHOEVER
     * OWNETH THE ESTATE rather than minting its own**, so "the wipe retired the live estate" is a statement about the
     * objects the send road actually used.
     *
     * *** NULL IS THE RESOURCE MODEL, AND IT IS NAMED RATHER THAN IMPLIED. *** *A null estate meaneth the harness
     * allocates its own IN-MEMORY identity/store/ACK store per node -- exactly the behaviour every existing T44 court
     * measureth -- and it is reachable only where [admitNormalEstate] permitted, which [NormalEstateGate.Unbound] never
     * doth.*
     */
    var estate: ComposedEstateFactories? = null

    /** Compose one node, CONSULTING THE SAME-ESTATE GATE FIRST. The recipient key directory is per-node and explicit: a
     *  node resolveth only the keys it was actually trusted with. */
    fun addNode(label: String): ComposedNode {
        // *** THE GATE, ASKED BEFORE THE FIRST EFFECT. ***
        // *The estate's identity, the store handle and the ACK namespace below all allocate real material; a gate
        // consulted afterwards would be a report rather than an admission.*
        val verdict = admitNormalEstate.admit()
        if (verdict is NormalEstateVerdict.Refused) {
            trace.append(TraceEvent("normal_composition_refused", clock.monoMillis(),
                mapOf("node" to label, "reason" to verdict.reason)))
            throw NormalEstateRefused(label, verdict.reason)
        }
        val owner = estate
        val identity: Identity = owner?.identityFor(label) ?: run {
            val ed = Ed25519Keys.generate(rng)
            val dh = X25519Keys.generate(rng)
            Identity.fromKeyMaterial(ed.pub, ed.priv, dh.pub, dh.priv)
        }
        val store: MessageStore = owner?.storeFor(label) ?: InMemoryMessageStore()
        val ackStore: io.godstone.mesh.delivery.AckObligationStore =
            owner?.ackStoreFor(label) ?: InMemoryAckStore()
        val keys = MutableKeyTable()
        // a node pinnaleth its OWN authentic signing key first: the inbox
        // self-verifieth every ACK it produceth, so a directory without our own
        // key refuseth to issue one at all (the census saith acksRefusedKey)
        keys.put(identity.nodeId, identity.identityPub)
        val authenticator: AckAuthenticator = Ed25519AckAuthenticator(keys)
        // *** THE TRACKER IS THE PRODUCTION ONE WHENEVER THE STORE IS A REAL ONE. ***
        // *A `ComposedDeliveryRepository` over a real `SqliteMessageStore` would keep delivery STATE in a map beside a
        // durable store -- a second, non-durable source of truth, which is the "no fake in-memory under the real app"
        // defect at one level down.* **So the concrete store's own `engine` feeds `SqliteDeliveryRepository`, exactly as
        // `MeshModule.provideDeliveryTracker` builds it.**
        val tracker: DeliveryTracker = if (store is io.godstone.mesh.store.SqliteMessageStore) {
            DeliveryTracker(
                io.godstone.mesh.delivery.SqliteDeliveryRepository(store.engine, store::notifyHeldSetChanged),
                authenticator,
            )
        } else {
            DeliveryTracker(ComposedDeliveryRepository(store), authenticator)
        }
        // *** GS-FINAL-003 `same-estate` (review A6-expanded): THE NODE'S OWN ADMISSION IS BOUND TO THIS COMPOSITION. ***
        //
        // *THE REVIEW'S CHARGE: the `MeshNode` convenience constructor "hardcodes `WipeSensitiveUseGate { true }`" and
        // "is on the actual launchable lab path".* **SO THE COMPOSITION NO LONGER USES IT: the node is built with the
        // FULL constructor and a gate that answers from THIS harness's own estate state, so a retired/wipe-in-progress
        // composition REFUSES the node's durable writes through the same seam the production node carries.** *The gate
        // is read per call (never cached), so [retireLiveOwners] really closes the road a message would have taken.*
        val node = MeshNode(
            null, identity, store, tracker,
            io.godstone.mesh.identity.WipeSensitiveUseGate { !wiped },
            io.godstone.mesh.crypto.SessionManager(
                identity,
                // *The resource model's trust allowance: a binding validated by the handshake is applied. The peer-trust
                // road is NOT the subject of the same-estate repair (identity/messages/ACKs are), and it is stated
                // here rather than hidden.*
                object : io.godstone.mesh.crypto.PeerBindingTrustAuthority {
                    override fun applyValidatedBinding(
                        binding: io.godstone.mesh.identity.ValidatedPeerBinding,
                    ): io.godstone.mesh.identity.PeerTrustApplyResult =
                        io.godstone.mesh.identity.PeerTrustApplyResult.Accepted
                },
            ),
        )
        // *** THE SIGNING AUTHORITY IS WIRED OVER THE SAME IDENTITY THE ESTATE SUPPLIED. ***
        // *GS-SOS-001's reasoning is unchanged: the authority is built over the very key material this node's identity
        // carrieth (`identity.identityPriv`/`staticDhPub`, both `internal` to `:mesh` and never publicly exposed), and
        // the binding is ISSUED BY THAT IDENTITY -- so the composition completeth its own signing road rather than
        // forging one.*
        node.sosAuthority = SimulatedSosAuthority(
            identity.identityPriv, identity.staticDhPub, identity.issueIdentityBinding(), rng,
        )
        val inbox = RecipientInboxRepository(
            router = node.router,
            ourNodeId = identity.nodeId,
            localDhPrivate = { identity.staticDhPriv },
            signer = NodeSigner(identity.nodeId, identity.identityPriv),
            resolver = keys,
            authenticator = Ed25519AckAuthenticator(keys),
            pairedStore = ackStore,
            // *** AND THE INBOUND COMMIT IS THE REAL STORE'S OWN, NOT A MODEL'S. ***
            commitInbound = { frame, receivedFrom, localRecipient, generation, lifetime, receivedAt, fault ->
                commitInboundOn(store, frame, receivedFrom, localRecipient, generation, lifetime, receivedAt, fault)
            },
            clockSeconds = { clock.wallSeconds() },
        )
        node.recipientInbox = inbox
        // the T84 ACK authority, bound exactly as a composition would bind it
        val ackDriver = AckObligationDriver(
            ackStore, NodeSigner(identity.nodeId, identity.identityPriv), authenticator, keys,
        )
        val ackPump = io.godstone.mesh.delivery.DurableAckPump(ackStore,
            { encoded, from -> ackDriver.admitForeignCandidate(encoded, from) })
        node.ackDispatcher = io.godstone.mesh.delivery.AckDispatcher(
            lookupDeliveryRow = { tracker.lookup(it) },
            verifyOrigin = { tracker.acknowledge(it.msgId, it) },
            admitCandidate = { encoded, from -> ackPump.admit(encoded, from) },
        )
        // *** GS-FINAL-003 `selfsame-send` (review A6): THE PRODUCT SEND COMMAND, WHEN THE ESTATE OWNS ONE. ***
        //
        // *THE OBLIGATION: **"Use production normal owner ... and same runtime authority Send/SOS operate."*** A
        // composed node over a REAL estate therefore carries the SAME `SendDirectAuthority` the product command surface
        // uses -- resolving trust through the ESTATE's peer directory and write-ahead-ing to the ESTATE's durable ledger
        // -- so the recipient's revoked/absent state is a real refusal and a relaunch can resume the SAME bytes.*
        //
        // *The authority is built ONCE per node and reused by both the fresh and the retry road, so "one intent, one
        // pinned revision" is a property of the object graph.*
        val directSend = owner?.let {
            io.godstone.mesh.delivery.SendDirectAuthority(
                identity = identity,
                signingKeys = io.godstone.mesh.delivery.SigningKeysAdapter(
                    identity.identityPriv, identity.identityPub,
                ),
                router = node.router,
                store = store,
                trustResolver = EstateDirectoryTrustResolver(it.peerDirectory()),
                journal = it.intentLedgerFor(label),
            )
        }
        val composed = ComposedNode(label, identity, identity.identityPriv, store, tracker, node, inbox,
            ackStore, keys, ackPump, directSend)
        nodes[label] = composed
        trace.append(TraceEvent("node_composed", clock.monoMillis(),
            mapOf("node" to label, "node_id" to hex(identity.nodeId))))
        return composed
    }

    fun node(label: String): ComposedNode? = nodes[label]

    /**
     * *** THE INBOUND COMMIT ROAD, ROUTED BY THE STORE'S OWN TYPE. ***
     *
     * *A REAL store commits the frame AND its ACK obligation ATOMICALLY through its own verb -- the road
     * `MeshModule.provideMeshNode` binds. A resource model cannot, so it fallseth to the SAME verb on the model's own
     * store, and a store that carrieth no such road answereth the protocol's OWN typed `StorageFailure` rather than a
     * fabricated acceptance.* **The dispatch is by TYPE rather than by a caller flag, so the real store's road cannot
     * be forgotten at a call site.**
     */
    private suspend fun commitInboundOn(
        store: MessageStore,
        frame: FrameV2,
        receivedFrom: ByteArray,
        localRecipient: ByteArray,
        generation: Long,
        lifetime: Long,
        receivedAt: Long,
        fault: ((String) -> Unit)?,
    ): io.godstone.mesh.delivery.InboundCommitResult {
        // *** DURING A WIPE NOTHING IS ADMITTED INTO THE STORE. ***
        // *The store is mid-erasure; admitting a frame would be the "old work refused" clause violated one layer down.
        // The refusal speaketh IN THE PROTOCOL'S OWN VOCABULARY (`InboundCommitResult.StorageFailure`), which is what a
        // store under erasure genuinely is -- never an invented error and never a plausible-looking acceptance.*
        if (wiped) return io.godstone.mesh.delivery.InboundCommitResult.StorageFailure
        return when (store) {
            is io.godstone.mesh.store.SqliteMessageStore ->
                store.commitInboundWithObligationAtWithFault(
                    frame, receivedFrom, localRecipient, generation, lifetime, receivedAt, fault,
                )
            is InMemoryMessageStore ->
                store.commitInboundWithObligationAtWithFault(
                    frame, receivedFrom, localRecipient, generation, lifetime, receivedAt, fault,
                )
            // *** A STORE THAT CANNOT COMMIT AN OBLIGATION SAYETH SO, IN THE PROTOCOL'S OWN TYPE. ***
            else -> io.godstone.mesh.delivery.InboundCommitResult.StorageFailure
        }
    }

    /**
     * *** GS-FINAL-003 `selfsame-send` (review A6): ONE EXPLICIT INTENT TOKEN PER FRESH SEND. ***
     *
     * *A double tap is TWO explicit intents, never one mutated token.*
     */
    private fun mintIntentToken(): ByteArray = ByteArray(16).also { rng.nextBytes(it) }

    /**
     * *** OFFER THE FRAME THE PRODUCT AUTHORITY DURABLY PINNED. ***
     *
     * *THE RETRY LAW'S OWN SHAPE: the frame is LOADED BACK from the store's held set by the `msg_id` the durable enqueue
     * committed, so what leaves the radio is exactly the bytes that were pinned -- never a second authoring.* **The
     * dispatch then travelleth the node's own statute, which re-enqueueth idempotently (`AlreadyQueuedSameBinding`) and
     * hands the canonical frame to every linked peer.**
     */
    private suspend fun dispatchProductSend(
        from: String,
        a: ComposedNode,
        b: ComposedNode,
        result: io.godstone.mesh.delivery.SendDirectResult,
        recipientLabel: String,
    ): ComposedOutcome = when (result) {
        is io.godstone.mesh.delivery.SendDirectResult.Rejected ->
            ComposedOutcome.Refused(ComposedRefusal.STORE_REFUSED, result.reason.name)
        is io.godstone.mesh.delivery.SendDirectResult.DurablyEnqueued -> {
            val frame = a.store.allHeldOrderedByPriority()
                .firstOrNull { it.msgId.contentEquals(result.logicalMessageId) }
                ?: return ComposedOutcome.Refused(
                    ComposedRefusal.STORE_REFUSED,
                    "the product authority reported a durable enqueue whose frame the store does not carry",
                )
            val dispatched = a.node.dispatchDirect(frame, expectedRecipient = b.nodeId) { peerId, bytes ->
                val label = nodes.values.firstOrNull { it.nodeId.contentEquals(peerId) }?.label
                    ?: return@dispatchDirect false
                send(a, label, bytes)
            }
            trace.append(TraceEvent("send_direct", clock.monoMillis(),
                mapOf("from" to from, "recipient" to recipientLabel, "msg_id" to hex(frame.msgId),
                      "result" to dispatched.toString(), "road" to "product")))
            ComposedOutcome.Applied(dispatched.toString())
        }
    }

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

    /**
     * *** GS-FINAL-003 `same-estate`: DRAIN AND RETIRE THE LIVE OWNERS THIS COMPOSITION MADE. ***
     *
     * *THE OBLIGATION: **"Begin wipe must drain/retire actual live owner and same key/message/peer/intent/ACK estate,
     * old work refused."*** **This is the "retire" half for a resource model: it closes the send/publish admission (so
     * every subsequent [send] is refused BY THE SAME COMPOSITION the message road used) and returns the number of
     * owners retired -- a COUNT, so "nothing was retired" is observable rather than assumed.** *The byte-level erasure
     * of a real on-disk estate is performed by the caller's own owner over the paths it composed (see
     * [ComposedEstateOwnership]); a harness that wrote no bytes has nothing further to erase and sayeth so by returning
     * zero owned paths.*
     */
    override fun retireLiveOwners(): Int {
        beginWipe()
        return nodes.size
    }

    /** The durable artifacts this composition wrote, so a wipe can address them by their REAL paths. */
    override fun ownedArtifactPaths(): List<String> = estate?.ownedArtifactPaths() ?: emptyList()

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
        // *** THE AUTHOR MUST TRUST THE RECIPIENT'S SIGNING KEY TO VERIFY THE ACK; the operator's selection, never a
        // document's claim. (The product authority performs the SAME act from the estate's own directory.) ***
        a.trust(b.nodeId, b.identity.identityPub)
        // *** GS-FINAL-003 `selfsame-send` (review A6): THE PRODUCT SEND COMMAND WHEN THE ESTATE OWNS ONE. ***
        // *THE OBLIGATION: **"same runtime authority Send/SOS operate."*** When this node carrieth the estate's
        // `SendDirectAuthority`, the send travelleth the PRODUCT command -- the recipient's TRUST is resolved through
        // the estate's directory (so a revoked/absent peer is REFUSED BY NAME), the intent is written ahead to the
        // estate's durable ledger, and the atomic pair is committed through the SAME `enqueueDirectOutbound` the
        // product binds. **THE FRAME THAT IS THEN OFFERED IS LOADED BACK FROM THE LEDGER, which is the retry law's own
        // read, so what leaves the radio is exactly the bytes that were durably pinned.***
        val road = a.directSend
        if (road != null) {
            val result = road.sendDirect(
                io.godstone.mesh.delivery.SendDirectCommand.of(
                    intentId = mintIntentToken(),
                    recipientTrustRef = b.nodeId,
                    bodyUtf8 = plaintext,
                ) ?: return ComposedOutcome.Refused(ComposedRefusal.STORE_REFUSED, "malformed intent token"),
            )
            return dispatchProductSend(from, a, b, result, recipientLabel)
        }
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

/**
 * *** GS-FINAL-003 `selfsame-send` (review A6): THE ESTATE'S OWN PEER DIRECTORY, AS THE SEND ROAD SEES IT. ***
 *
 * *THE OBLIGATION: **"trust accepted DH/generation revoked recipient refused."*** **The harness's authoring road never
 * resolved the recipient at all, so a REVOKED peer was written to and the accepted DH generation was never checked.*
 * **This resolver answers from THE ESTATE'S OWN DIRECTORY** -- `Absent` for a stranger, `Revoked` for a withdrawn peer,
 * `NotApproved("quarantined")` for a pending rotation, and an `Approved` carrying the ACCEPTED generation and static DH
 * key for a pinned one -- so every negative case is a real, reachable refusal.*
 */
internal class EstateDirectoryTrustResolver(
    private val directory: Map<String, ComposedPeerMaterial>,
) : io.godstone.mesh.delivery.RecipientTrustResolver {
    override fun resolve(recipientTrustRef: ByteArray): io.godstone.mesh.delivery.ResolvedRecipient {
        if (recipientTrustRef.size != io.godstone.mesh.wire.v2.MessageId.NODE_ID_BYTES) {
            return io.godstone.mesh.delivery.ResolvedRecipient.InvalidArgument
        }
        val label = directory.entries
            .firstOrNull { it.value.nodeId.contentEquals(recipientTrustRef) }?.key
            ?: return io.godstone.mesh.delivery.ResolvedRecipient.Absent
        val material = directory[label] ?: return io.godstone.mesh.delivery.ResolvedRecipient.Corrupt("no material")
        if (material.signingPub.size != 32 || material.staticDhPub.size != 32) {
            return io.godstone.mesh.delivery.ResolvedRecipient.Corrupt("malformed peer material")
        }
        return when (material.trust) {
            ComposedPeerTrust.REVOKED -> io.godstone.mesh.delivery.ResolvedRecipient.Revoked
            ComposedPeerTrust.QUARANTINED -> io.godstone.mesh.delivery.ResolvedRecipient.NotApproved("quarantined")
            ComposedPeerTrust.ACCEPTED -> io.godstone.mesh.delivery.ResolvedRecipient.Approved(
                recipientNodeId = material.nodeId,
                recipientSigningPub = material.signingPub,
                recipientStaticDhPub = material.staticDhPub,
                acceptedGeneration = material.acceptedGeneration,
            )
        }
    }
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

/**
 * GS-SOS-001: the signing authority of ONE simulated node, backed by the very key material the harness
 * generated for it. It is TEST-SUPPORT code living in main so that tests may drive the real composition;
 * it forges nothing, and every key it hands out belongs to the node it was built for.
 */
private class SimulatedSosAuthority(
    private val seed: ByteArray,
    private val dhPublicKey: ByteArray,
    // GS-SOS-001, second defect (round 163): the binding is ISSUED BY THE HARNESS'S OWN IDENTITY
    // (`Identity.issueIdentityBinding()`, an authority file) and handed in -- this file is NOT an
    // authority file, so constructing one here would be the very issuance bypass the local-identity
    // control refuseth. The material above is the same ed/dh pair the identity was built from.
    private val binding: io.godstone.mesh.identity.IdentityBindingV1,
    private val rng: java.security.SecureRandom,
) : io.godstone.mesh.wire.v2.SosSigningAuthority {
    override fun currentNonce(): ByteArray = ByteArray(16).also { rng.nextBytes(it) }
    override fun currentSigningSeed(): ByteArray? = seed.copyOf()
    override fun currentStaticDhPublicKey(): ByteArray? = dhPublicKey.copyOf()
    override fun currentGeneration(): Long = binding.generation
    override fun currentIdentityBinding(): io.godstone.mesh.identity.IdentityBindingV1 = binding
    override fun currentTimeEpochSeconds(): Long = 1_700_000_000L
}
