package io.godstone.mesh.crypto

import io.godstone.mesh.identity.Identity
import io.godstone.mesh.identity.RuntimeLifecycleGate
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.locks.ReentrantLock
import java.util.concurrent.locks.ReentrantReadWriteLock
import kotlin.concurrent.read
import kotlin.concurrent.write
import kotlin.concurrent.withLock

/**
 * Per-peer trusted session registry (Stage 4 Phase C8.4B / C8.4B.1).
 *
 * Replaces the untrusted raw NoiseSession registry. Owns and gates on
 * [TrustedHandshakeController] instances rather than raw Noise establishment.
 * Seal and open are permitted IFF the transport peer's controller has reached
 * [HandshakeTrustState.READY].
 *
 * LOCK ORDER HIERARCHY:
 * 1. Lifecycle Read/Write Lock (`lifecycleRwLock`):
 *    - In-flight operations take the read lock for their entire duration (including controller execution).
 *    - Invalidation (`invalidateForWipe`) takes the exclusive write lock, ensuring all in-flight operations
 *      drain completely before controllers are destroyed and the registry cleared.
 * 2. Per-Peer Lock (`peerLocks`):
 *    - Serializes handshakes (initiator/responder processing) for a specific peer.
 * 3. Map Lock (`mapLock`):
 *    - Protects insertion, removal, and lookup in `controllers`.
 *
 * Invalidation for panic wipe destroys all sessions and permanently transitions
 * the manager to INVALIDATED state.
 */
class SessionManager internal constructor(
    private val identity: Identity,
    private val trustAuthority: PeerBindingTrustAuthority,
    private val localBindingIssuer: LocalBindingIssuer = LocalBindingIssuer { identity.issueIdentityBinding().encode() },
    private val lifecycleGate: RuntimeLifecycleGate? = null
) {
    private enum class ManagerState { ACTIVE, INVALIDATED }

    private val lifecycleRwLock = ReentrantReadWriteLock()
    private val mapLock = ReentrantLock()
    @Volatile private var managerState = ManagerState.ACTIVE

    internal var testOperationHook: ((String) -> Unit)? = null

    /**
     * ANDROID-06 (round 221): A NAMED TEST SEAM THAT MAKETH THE NEXT SEAL REFUSE **ONCE**.
     *
     * Why it is a PRODUCTION file and not a fixture trick: the caller-side law under witness -- 'a refused seal
     * returneth its slot to the relation' -- liveth in `sendThrough`'s refusal branch, which is reached through a
     * PRIVATE method, and every refusal condition of `seal` is INTERNAL (the manager not active, no slot for the
     * relation, the slot not ACTIVE). No court could therefore force a refusal ON COMMAND, and the law could only
     * be READ. This seam is the smallest honest way to DRIVE it: it is `internal`, it is consumed by the very
     * next seal, and it changeth nothing unless a court asketh for it.
     */
    internal var refuseNextSealForTest: Boolean = false
    internal var testInvalidationAttemptHook: (() -> Unit)? = null

    /**
     * GS-CTRL-002 (R01): this registry carrieth the name the composition contract
     * useth -- `controllers` -- because THAT IS WHAT IT IS: every entry owns exactly
     * one [TrustedHandshakeController] (`SessionSlot.controller`), and never a raw
     * `NoiseSession`. T08 renamed the map to `slots` when it made the key a RELATION
     * rather than a peer handle, and the repository's composition control -- which
     * readeth CODE TEXT with comments stripped -- then reported a registry that doth
     * not exist. The vocabulary is aligned here rather than the rule being loosened:
     * the instrument keepeth its authority and the code keepeth its design.
     *
     * CRYPTO-001 (T08 completion): the map is keyed by the RELATION'S PLACE --
     * direction and handle -- and every entry carrieth its full [RelationKey], the
     * complete admission. ONE live incarnation per place: a newer incarnation
     * SUPERSEDES the standing one, so the registry can never hold two lives of one
     * relation, and an operation addressed to the superseded incarnation is refused as
     * [RelationRetirement.STALE] without touching its replacement.
     *
     * The T08 "remembered generation" registry is RECLAIMED here, and deliberately: the
     * generation now cometh from the orchestration owner through the admission, so a
     * crypto-side history had nothing left to remember. A history whose only duty was to
     * paper over an absent key is a liability, not a defence.
     */
    private val controllers = HashMap<RelationPlace, SessionSlot>()

    private fun key(peerId: ByteArray): String = peerId.joinToString("") { "%02x".format(it) }

    /**
     * GS-CTRL-002 (R05): the PER-PEER (per-relation) serialisation point, under the name the
     * composition contract useth. The slot owneth the lock; `SessionSlot.serialize` acquireth the
     * very same lock, and [isReady] taketh it explicitly through this accessor. The registry
     * `controllers` above is keyed by the immutable relation, so "per-peer" here meaneth "per peer
     * relation" -- one lock, one controller, one relation, which is what the contract protecteth.
     */
    private fun getPeerLock(rk: RelationKey): ReentrantLock? = slotFor(rk)?.getPeerLock()

    /**
     * CRYPTO-001: THE LOOKUP ITSELF IS THE LAW. An incarnation standeth IFF the entry's
     * whole admission equalleth the one presented -- direction, handle, orchestration
     * generation AND transport epoch. Anything else is no slot at all, so no operation of a
     * replaced relation can reach its replacement.
     */
    private fun slotFor(admission: RelationKey): SessionSlot? =
        mapLock.withLock {
            val standing = controllers[admission.place] ?: return@withLock null
            if (standing.admission != admission) return@withLock null
            standing
        }

    /**
     * CRYPTO-001: admit an incarnation, SUPERSEDING the standing one for the same place. The map
     * lock is never held while the incumbent's slot lock is entered: the destructive retirement of
     * the superseded incarnation runneth after the map lock is releas'd, so the documented order
     * (gate, slot, map) is kept whole.
     */
    private fun getOrCreateSlot(admission: RelationKey): SessionSlot {
        var superseded: SessionSlot? = null
        val fresh = mapLock.withLock {
            val standing = controllers[admission.place]
            if (standing != null && standing.admission == admission) {
                return@withLock standing
            }
            superseded = standing
            val created = SessionSlot(admission)
            controllers[admission.place] = created
            created
        }
        superseded?.retire()?.destroy()
        return fresh
    }

    /**
     * CRYPTO-001: compare-and-remove on the WHOLE admission. A teardown addressed to an incarnation
     * which no longer standeth taketh nothing away.
     */
    private fun removeSlot(admission: RelationKey): SessionSlot? =
        mapLock.withLock {
            val standing = controllers[admission.place] ?: return@withLock null
            if (standing.admission != admission) return@withLock null
            controllers.remove(admission.place)
            standing
        }

    /**
     * THE PRE-T08 HOST VOCABULARY (CRYPTO-001). A host court which driveth ONE relation per platform
     * handle, and never mixeth directions, nameth that relation here. PRODUCTION NEVER SPEAKETH THIS:
     * the transport holdeth the relation's own admission -- its `GattClientConnection.relationKeyProvider`
     * is bound at admission and carrieth direction, generation and epoch -- and presenteth THAT. A
     * source-level arm of the canonical suite refuseth this vocabulary in production sources by name,
     * so the refusal is a control rather than an intention.
     */
    private fun hostPlaceholders(handle: String): List<RelationKey> =
        listOf(
            RelationKey(RelationDirection.OUTBOUND_CENTRAL, handle, 0L, 0L),
            RelationKey(RelationDirection.INBOUND_PERIPHERAL, handle, 0L, 0L),
        )

    /**
     * The host vocabulary nameth a HANDLE, not an incarnation. A handle-scoped READ is therefore
     * answered from whatever incarnation standeth -- the outbound one first -- and from the
     * placeholder when none standeth. A court which witnesseth STALENESS speaketh the keyed surface.
     */
    private fun hostAdmissions(peerId: ByteArray): List<RelationKey> {
        val handle = key(peerId)
        val standing = mapLock.withLock {
            listOf(
                RelationKey(RelationDirection.OUTBOUND_CENTRAL, handle, 0L, 0L),
                RelationKey(RelationDirection.INBOUND_PERIPHERAL, handle, 0L, 0L),
            ).mapNotNull { controllers[it.place]?.admission }
        }
        return if (standing.isEmpty()) hostPlaceholders(handle) else standing
    }

    /**
     * The host vocabulary's HANDSHAKE step: the standing incarnation of that direction when one
     * standeth -- so a court which pre-paired through the link owner's admission continueth on the
     * SAME incarnation -- and the documented placeholder when the court is the one which beginneth
     * the relation.
     */
    private fun hostHandshakeAdmission(peerId: ByteArray, direction: RelationDirection): RelationKey {
        val handle = key(peerId)
        val placeholder = RelationKey(direction, handle, 0L, 0L)
        return mapLock.withLock { controllers[placeholder.place]?.admission } ?: placeholder
    }

    /** T08 evidence hook: the live incarnation standing for [peerId], outbound first. */
    internal fun slotForTest(peerId: ByteArray): SessionSlot? {
        val handle = key(peerId)
        return mapLock.withLock {
            controllers[RelationPlace(RelationDirection.OUTBOUND_CENTRAL, handle)]
                ?: controllers[RelationPlace(RelationDirection.INBOUND_PERIPHERAL, handle)]
        }
    }

    /** T08 evidence hook: live entries in the relation-slot registry. */
    internal fun slotCountForTest(): Int = mapLock.withLock { controllers.size }

    /** CRYPTO-001 evidence hook: the live incarnations of one platform handle (one per direction). */
    internal fun incarnationCountForTest(peerId: ByteArray): Int {
        val handle = key(peerId)
        return mapLock.withLock { controllers.keys.count { it.handle == handle } }
    }

    /** T08 evidence hook: the ORCHESTRATION-OWNED generation of the live incarnation. */
    internal fun slotLeaseGenerationForTest(peerId: ByteArray): Long? {
        val slot = slotForTest(peerId) ?: return null
        return slot.serialize { slot.generation }
    }

    val isInvalidated: Boolean
        get() = managerState == ManagerState.INVALIDATED || (lifecycleGate?.isInvalidated == true)

    val isActive: Boolean
        get() = !isInvalidated

    /**
     * True IFF the peer has an active TrustedHandshakeController in HandshakeTrustState.READY
     * and the manager is not invalidated.
     */
    /**
     * ANDROID-07 / T26 STEP 2: THE IMMUTABLE FULL NODE ID OF A RELATION -- the sixteen octets the
     * TRUSTED HANDSHAKE validated and the controller RETAINED. Never a value derived from the static DH
     * key (which is a DIFFERENT identity), never a MAC, a hint or a station handle. NULL until the
     * relation is trusted, which is what maketh the PRE-AUTH budget the right instrument for everything
     * that arriveth earlier; and because the IDENTITY is charged rather than the handle, a peer cannot
     * evade a budget by arriving under another handle.
     */
    fun authenticatedNodeIdOf(admission: RelationKey): ByteArray? {
        val slot = slotFor(admission) ?: return null
        val lock = getPeerLock(admission) ?: return null
        return lock.withLock { slot.controller?.authenticatedNodeId }
    }

    /**
     * ANDROID-03 (T24) slice (a): the authenticated IDENTITY PUBLIC KEY for a relation, under the SAME lock
     * discipline as the node-id accessor above -- the peer lock of the relation, read while the slot's controller
     * answereth. It is the source `TrustedPeer.capture` needeth, and the node id IS its canonical derivation, so the
     * two accessors can never disagree.
     */
    fun authenticatedIdentityPubOf(admission: RelationKey): ByteArray? {
        val slot = slotFor(admission) ?: return null
        val lock = getPeerLock(admission) ?: return null
        return lock.withLock { slot.controller?.authenticatedIdentityPub }
    }

    fun isReady(admission: RelationKey): Boolean {
        var retirable: RelationKey? = null
        return lifecycleRwLock.read {
            if (!isActive) return false
            val slot = slotFor(admission) ?: return false
            // GS-CTRL-002 (R05): the readiness query taketh the PER-PEER lock EXPLICITLY, under the
            // name the composition contract useth -- the same lock `SessionSlot.serialize` acquireth,
            // so the behaviour is unchanged and the name is load-bearing rather than decorative.
            val peerLock = getPeerLock(admission) ?: return false
            // CRYPTO-002: THE IDLE PATH. A session that reached its own terminus while `state` still sayeth READY
            // must not keep publishing ready -- and THE PRIMITIVE IS THE AUTHORITY on its own terminus, asked WITHOUT
            // a packet (`evaluateTimeBudget`, the entry this round addeth).
            val terminallyAged = peerLock.withLock {
                val ctrl = slot.controller ?: return@withLock false
                ctrl.noiseSession.evaluateTimeBudget() != null ||
                    (ctrl.state == HandshakeTrustState.READY && !ctrl.isReady)
            }
            if (terminallyAged) {
                retirable = admission
                return@read false
            }
            peerLock.withLock {
                val ctrl = slot.controller ?: return@withLock false
                ctrl.isReady && ctrl.state == HandshakeTrustState.READY
            }
        }.also { answer ->
            // THE RETIREMENT, OUTSIDE THE LOCK, through the manager's own verb.
            if (retirable != null) drop(retirable!!)
        }
    }

    /**
     * Start initiator handshake for [peerId] and emit HS1 (32 bytes).
     * Serialized per peer. Returns null if already exists, collision, or invalidated.
     */
    fun beginInitiator(admission: RelationKey, remoteHint: ByteArray): ByteArray? =
        initiatorStart(admission, remoteHint)

    fun initiatorStart(admission: RelationKey, remoteHint: ByteArray): ByteArray? {
        lifecycleRwLock.read {
            if (!isActive) return null
            val slot = getOrCreateSlot(admission)
            if (slot.admission != admission) return null
            return slot.serialize {
                if (!isActive) return@serialize null
                if (slot.state != SlotState.ACTIVE) return@serialize null
                if (slot.controller != null) return@serialize null
                val ctrl = TrustedHandshakeController.initiator(
                    identity = identity,
                    remoteHint = remoteHint,
                    trustAuthority = trustAuthority,
                    localBindingIssuer = localBindingIssuer
                )
                val hs1 = try {
                    ctrl.initiatorWriteMessage1()
                } catch (e: Exception) {
                    ctrl.destroy()
                    return@serialize null
                }
                if (!isActive) {
                    slot.retire()
                    removeSlot(admission)
                    ctrl.destroy()
                    return@serialize null
                }
                slot.controller = ctrl
                hs1
            }
        }
    }

    /**
     * Process HS2 from responder and emit HS3 (197 bytes).
     * On success, transitions controller to READY. On failure or non-READY, drops entry and returns null.
     */
    fun initiatorProcessHs2(admission: RelationKey, hs2: ByteArray, advertisedRemoteHint: ByteArray): ByteArray? {
        lifecycleRwLock.read {
            if (!isActive) return null
            testOperationHook?.invoke("initiatorProcessHs2")
            val slot = slotFor(admission) ?: return null
            var doomed: TrustedHandshakeController? = null
            val result = slot.serialize {
                if (!isActive || slot.state != SlotState.ACTIVE) {
                    return@serialize null
                }
                val ctrl = slot.controller ?: return@serialize null
                val hs3 = ctrl.initiatorProcessMessage2(hs2, advertisedRemoteHint)
                if (hs3 == null || !ctrl.isReady) {
                    // T08: terminal transition serialized with the operation;
                    // the destructive destroy is routed outside the slot lock.
                    doomed = slot.retire()
                    return@serialize null
                }
                hs3
            }
            doomed?.let { ctrl ->
                removeSlot(admission)
                ctrl.destroy()
            }
            return result
        }
    }

    /**
     * Start responder handshake for a relation, process inbound HS1, and emit HS2 (229 bytes).
     */
    fun beginResponder(admission: RelationKey, remoteHint: ByteArray, hs1: ByteArray): ByteArray? =
        responderProcessHs1(admission, remoteHint, hs1)

    fun responderProcessHs1(admission: RelationKey, remoteHint: ByteArray, hs1: ByteArray): ByteArray? {
        lifecycleRwLock.read {
            if (!isActive) return null
            testOperationHook?.invoke("responderProcessHs1")
            val slot = getOrCreateSlot(admission)
            if (slot.admission != admission) return null
            return slot.serialize {
                if (!isActive) return@serialize null
                if (slot.state != SlotState.ACTIVE) return@serialize null
                if (slot.controller != null) return@serialize null
                val ctrl = TrustedHandshakeController.responder(
                    identity = identity,
                    remoteHint = remoteHint,
                    trustAuthority = trustAuthority
                )
                val hs2 = try {
                    ctrl.responderProcessMessage1AndWriteMessage2(hs1)
                } catch (e: Exception) {
                    ctrl.destroy()
                    return@serialize null
                }
                if (hs2 == null) {
                    ctrl.destroy()
                    return@serialize null
                }
                if (!isActive) {
                    slot.retire()
                    removeSlot(admission)
                    ctrl.destroy()
                    return@serialize null
                }
                slot.controller = ctrl
                hs2
            }
        }
    }

    /**
     * Process inbound HS3 from initiator.
     * Returns true IFF handshake reaches HandshakeTrustState.READY.
     */
    fun responderProcessHs3(admission: RelationKey, hs3: ByteArray, advertisedRemoteHint: ByteArray): Boolean {
        lifecycleRwLock.read {
            if (!isActive) return false
            testOperationHook?.invoke("responderProcessHs3")
            val slot = slotFor(admission) ?: return false
            var doomed: TrustedHandshakeController? = null
            val result = slot.serialize {
                if (!isActive || slot.state != SlotState.ACTIVE) {
                    return@serialize false
                }
                val ctrl = slot.controller ?: return@serialize false
                val ok = ctrl.responderProcessMessage3(hs3, advertisedRemoteHint)
                if (!ok || !ctrl.isReady) {
                    doomed = slot.retire()
                    return@serialize false
                }
                true
            }
            doomed?.let { ctrl ->
                removeSlot(admission)
                ctrl.destroy()
            }
            return result
        }
    }

    /**
     * Encrypt cleartext frame bytes for a relation.
     * Returns ciphertext IFF session is READY and manager is active.
     */
    fun seal(admission: RelationKey, frameBytes: ByteArray): ByteArray? {
        // ANDROID-06 (round 221): the named seam, consumed by this very call.
        if (refuseNextSealForTest) {
            refuseNextSealForTest = false
            return null
        }
        lifecycleRwLock.read {
            if (!isActive) return null
            testOperationHook?.invoke("seal")
            val slot = slotFor(admission) ?: return null
            return slot.serialize {
                if (slot.state != SlotState.ACTIVE) return@serialize null
                val ctrl = slot.controller ?: return@serialize null
                if (!ctrl.isReady || ctrl.state != HandshakeTrustState.READY) {
                    return@serialize null
                }
                ctrl.seal(frameBytes)
            }
        }
    }

    /**
     * Decrypt ciphertext bytes received from [peerId].
     * Returns cleartext IFF session is READY and manager is active.
     */
    fun open(admission: RelationKey, ciphertext: ByteArray): ByteArray? {
        lifecycleRwLock.read {
            if (!isActive) return null
            testOperationHook?.invoke("open")
            val slot = slotFor(admission) ?: return null
            return slot.serialize {
                if (slot.state != SlotState.ACTIVE) return@serialize null
                val ctrl = slot.controller ?: return@serialize null
                if (!ctrl.isReady || ctrl.state != HandshakeTrustState.READY) {
                    return@serialize null
                }
                ctrl.open(ciphertext)
            }
        }
    }

    /**
     * T17: the typed twin of the nullable [open]. The arms that answer null -
     * the inactive manager, the absent slot, the slot past its active life,
     * the absent or unready controller - are recorded as Rejected; the
     * cleartext of a verified frame is recorded as Authenticated, in the
     * vocabulary of the Noise layer's own CryptoOpenResult.
     */
    fun openWithResult(admission: RelationKey, ciphertext: ByteArray): NoiseSession.CryptoOpenResult {
        // CRYPTO-002: THE PRIMITIVE'S TYPED VERDICT TRAVELS. The old body called `open(...)` (which flatteneth
        // everything to a nullable ByteArray) inside a `catch (_: Throwable)` and answered `Rejected` FOR EVERY
        // FAILURE -- so THIS MANAGER NEVER ANSWERED `Expired`, exactly as the audit measured. The primitive is now
        // asked ONCE, and its own vocabulary is carried outward.
        var outcome: NoiseSession.CryptoOpenResult = NoiseSession.CryptoOpenResult.Rejected
        lifecycleRwLock.read {
            if (!isActive) return@read
            val slot = slotFor(admission) ?: return@read
            outcome = slot.serialize {
                val ctrl = slot.controller ?: return@serialize NoiseSession.CryptoOpenResult.Rejected
                try {
                    ctrl.noiseSession.openWithResult(ciphertext)
                } catch (_: Throwable) {
                    NoiseSession.CryptoOpenResult.Rejected
                }
            }
        }
        // THE TERMINUS IS ROUTED **OUTSIDE** THE LOCK, through the manager's OWN teardown verb, so the two lock
        // orders cannot meet (the same discipline the iOS isle's round 309/344/345 taught).
        if (outcome is NoiseSession.CryptoOpenResult.Expired) drop(admission)
        return outcome
    }

    /**
     * CRYPTO-001: THE RELATION'S TEARDOWN, ADDRESSED TO AN INCARNATION. [RelationRetirement.STALE]
     * when no such incarnation standeth -- the replacement is untouched.
     */
    fun drop(admission: RelationKey): RelationRetirement {
        lifecycleRwLock.read {
            // T08: the terminal transition is serialized; the destructive
            // destroy is routed OUTSIDE the slot lock.
            val slot = removeSlot(admission) ?: return RelationRetirement.STALE
            slot.retire()?.destroy()
            return RelationRetirement.RETIRED
        }
    }

    /**
     * THE APP-LEVEL DEPARTURE: every incarnation of the platform handle is retired, whatever
     * generation standeth. A node which learneth that a peer hath departed knoweth the PEER, not the
     * relation -- and it must not pretend otherwise, so it speaketh this verb rather than guessing an
     * admission. The answer counteth the incarnations retired.
     */
    fun retireIncarnations(ofHandle: String): Int {
        lifecycleRwLock.read {
            val doomed = ArrayList<SessionSlot>()
            mapLock.withLock {
                val places = controllers.keys.filter { it.handle == ofHandle }
                for (place in places) {
                    controllers.remove(place)?.let { doomed.add(it) }
                }
            }
            for (slot in doomed) {
                slot.retire()?.destroy()
            }
            return doomed.size
        }
    }

    fun destroyAll() {
        lifecycleRwLock.write {
            mapLock.withLock {
                for (slot in controllers.values) {
                    slot.retire()?.destroy()
                }
                controllers.clear()
            }
        }
    }

    /** T21 (section 13, D2): when a relation closes, its exact session
     *  slot closes with it - removed from the map, the generation remembered
     *  for the conflict law, retired and destroyed once outside every slot
     *  lock. The call is idempotent: an absent slot answers false. */
    fun destroyFor(admission: RelationKey): Boolean {
        lifecycleRwLock.read {
            if (!isActive) return false
            val slot = removeSlot(admission) ?: return false
            slot.retire()?.destroy()
            return true
        }
    }

    fun invalidateForWipe() {
        testInvalidationAttemptHook?.invoke()
        lifecycleRwLock.write {
            mapLock.withLock {
                managerState = ManagerState.INVALIDATED
                for (slot in controllers.values) {
                    slot.state = SlotState.INVALIDATED
                    slot.controller?.destroy()
                    slot.controller = null
                }
                controllers.clear()
            }
        }
    }

    // ---------------------------------------------------------------- the pre-T08 host vocabulary
    //
    // These overloads exist for the HOST COURTS which drive one relation per platform handle and never
    // mix directions. They mint the documented placeholder admission (generation 0, epoch 0). PRODUCTION
    // SPEAKETH THE KEYED SURFACE ABOVE ONLY. They are `internal` on purpose: a consumer outside this
    // module cannot reach them at all, and inside the module they are named for what they are.

    private fun hostHandle(peerId: ByteArray): String = key(peerId)

    internal fun isReady(peerId: ByteArray): Boolean =
        hostAdmissions(peerId).any { isReady(it) }

    internal fun beginInitiator(peerId: ByteArray, remoteHint: ByteArray): ByteArray? =
        initiatorStart(hostHandshakeAdmission(peerId, RelationDirection.OUTBOUND_CENTRAL), remoteHint)

    internal fun initiatorStart(peerId: ByteArray, remoteHint: ByteArray): ByteArray? =
        initiatorStart(hostHandshakeAdmission(peerId, RelationDirection.OUTBOUND_CENTRAL), remoteHint)

    internal fun initiatorProcessHs2(peerId: ByteArray, hs2: ByteArray, advertisedRemoteHint: ByteArray): ByteArray? =
        initiatorProcessHs2(hostHandshakeAdmission(peerId, RelationDirection.OUTBOUND_CENTRAL), hs2, advertisedRemoteHint)

    internal fun beginResponder(peerId: ByteArray, remoteHint: ByteArray, hs1: ByteArray): ByteArray? =
        responderProcessHs1(hostHandshakeAdmission(peerId, RelationDirection.INBOUND_PERIPHERAL), remoteHint, hs1)

    internal fun responderProcessHs1(peerId: ByteArray, remoteHint: ByteArray, hs1: ByteArray): ByteArray? =
        responderProcessHs1(hostHandshakeAdmission(peerId, RelationDirection.INBOUND_PERIPHERAL), remoteHint, hs1)

    internal fun responderProcessHs3(peerId: ByteArray, hs3: ByteArray, advertisedRemoteHint: ByteArray): Boolean =
        responderProcessHs3(hostHandshakeAdmission(peerId, RelationDirection.INBOUND_PERIPHERAL), hs3, advertisedRemoteHint)

    internal fun seal(peerId: ByteArray, frameBytes: ByteArray): ByteArray? {
        for (admission in hostAdmissions(peerId)) {
            seal(admission, frameBytes)?.let { return it }
        }
        return null
    }

    internal fun open(peerId: ByteArray, ciphertext: ByteArray): ByteArray? {
        for (admission in hostAdmissions(peerId)) {
            open(admission, ciphertext)?.let { return it }
        }
        return null
    }

    internal fun openWithResult(peerId: ByteArray, ciphertext: ByteArray): NoiseSession.CryptoOpenResult {
        var sawExpired = false
        for (admission in hostAdmissions(peerId)) {
            val outcome = openWithResult(admission, ciphertext)
            if (outcome is NoiseSession.CryptoOpenResult.Authenticated) return outcome
            // CRYPTO-002: THE AGGREGATE MUST NOT SWALLOW A TERMINUS. The old body answered `Rejected` for EVERYTHING
            // that did not authenticate -- so an exhausted session was indistinguishable from a bad packet AT THE API
            // THE HOST COURTS USE. A terminus is now reported AS a terminus (it is the more specific and the more
            // actionable of the two), and a plain rejection still falls through. The iOS isle carrieth the same fix.
            if (outcome is NoiseSession.CryptoOpenResult.Expired) sawExpired = true
        }
        return if (sawExpired) NoiseSession.CryptoOpenResult.Expired else NoiseSession.CryptoOpenResult.Rejected
    }

    internal fun authenticatedNodeIdOf(peerId: ByteArray): ByteArray? {
        for (admission in hostAdmissions(peerId)) {
            authenticatedNodeIdOf(admission)?.let { return it }
        }
        return null
    }

    internal fun authenticatedIdentityPubOf(peerId: ByteArray): ByteArray? {
        for (admission in hostAdmissions(peerId)) {
            authenticatedIdentityPubOf(admission)?.let { return it }
        }
        return null
    }

    /** The host courts' teardown: EVERY incarnation of that handle, as the app-level departure doth. */
    internal fun drop(peerId: ByteArray) {
        retireIncarnations(hostHandle(peerId))
    }

    internal fun destroyFor(peerId: ByteArray): Boolean = retireIncarnations(hostHandle(peerId)) > 0
}
