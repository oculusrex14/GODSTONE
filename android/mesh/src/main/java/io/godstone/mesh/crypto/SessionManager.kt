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
    internal var testInvalidationAttemptHook: (() -> Unit)? = null

    /**
     * T08: one SessionSlot per relation keyed by the immutable RelationKey
     * (the transport lookup handle). The slot owns its lock, so removing a
     * retired slot reclaims its lock entry with it.
     */
    private val slots = HashMap<String, SessionSlot>()

    /**
     * T08: bounded last-generation registry. When a slot is reclaimed the
     * generation its lease carried is remembered here, so a replacement for
     * the SAME transport handle starts at the NEXT generation and a stale
     * event captured against the previous incarnation can never be mistaken
     * for one captured against the replacement. Bounded: the eldest
     * remembered handle is evicted first, and a lost generation only weakens
     * the stale-event guard - the terminal slot state and the replay window
     * remain the authoritative defences.
     */
    private val rememberedGenerations = LinkedHashMap<String, Long>()
    private val rememberedOrder = ArrayList<String>()
    private val reclaimMaxRemembered = 256

    private fun key(peerId: ByteArray): String = peerId.joinToString("") { "%02x".format(it) }

    private fun relationKey(peerId: ByteArray): RelationKey = RelationKey(key(peerId))

    private fun slotFor(rk: RelationKey): SessionSlot? =
        mapLock.withLock { slots[rk.handle] }

    private fun getOrCreateSlot(rk: RelationKey): SessionSlot =
        mapLock.withLock {
            val existing = slots[rk.handle]
            if (existing != null) {
                return@withLock existing
            }
            val generation = (rememberedGenerations[rk.handle] ?: -1L) + 1L
            val fresh = SessionSlot(rk, SlotLease(generation))
            slots[rk.handle] = fresh
            return@withLock fresh
        }

    private fun removeSlot(slot: SessionSlot) {
        mapLock.withLock {
            // Only the CURRENT incarnation is reclaimed: a stale caller that
            // still holds an already-replaced slot must not evict the
            // replacement, and the reclaimed lock entry leaves with its slot.
            if (slots[slot.key.handle] === slot) {
                slots.remove(slot.key.handle)
                rememberGeneration(slot)
            }
        }
    }

    private fun rememberGeneration(slot: SessionSlot) {
        val handle = slot.key.handle
        if (rememberedGenerations.containsKey(handle)) {
            rememberedOrder.remove(handle)
        } else if (rememberedGenerations.size >= reclaimMaxRemembered) {
            val eldest = rememberedOrder.iterator()
            if (eldest.hasNext()) {
                val victim = eldest.next()
                eldest.remove()
                rememberedGenerations.remove(victim)
            }
        }
        rememberedGenerations[handle] = slot.lease.generation
        rememberedOrder.add(handle)
    }

    /** T08 evidence hook: the slot handle for [peerId], live or held over. */
    internal fun slotForTest(peerId: ByteArray): SessionSlot? =
        slotFor(relationKey(peerId))

    /** T08 evidence hook: live entries in the relation-slot registry. */
    internal fun slotCountForTest(): Int = mapLock.withLock { slots.size }

    /** T08 evidence hook: remembered generations currently retained. */
    internal fun rememberedCountForTest(): Int =
        mapLock.withLock { rememberedGenerations.size }

    /** T08 evidence hook: lease generation of the live slot, if any. */
    internal fun slotLeaseGenerationForTest(peerId: ByteArray): Long? {
        val slot = slotFor(relationKey(peerId)) ?: return null
        return slot.serialize { slot.lease.generation }
    }

    val isInvalidated: Boolean
        get() = managerState == ManagerState.INVALIDATED || (lifecycleGate?.isInvalidated == true)

    val isActive: Boolean
        get() = !isInvalidated

    /**
     * True IFF the peer has an active TrustedHandshakeController in HandshakeTrustState.READY
     * and the manager is not invalidated.
     */
    fun isReady(peerId: ByteArray): Boolean {
        lifecycleRwLock.read {
            if (!isActive) return false
            val slot = slotFor(relationKey(peerId)) ?: return false
            return slot.serialize {
                val ctrl = slot.controller ?: return@serialize false
                ctrl.isReady && ctrl.state == HandshakeTrustState.READY
            }
        }
    }

    /**
     * Start initiator handshake for [peerId] and emit HS1 (32 bytes).
     * Serialized per peer. Returns null if already exists, collision, or invalidated.
     */
    fun beginInitiator(peerId: ByteArray, remoteHint: ByteArray): ByteArray? =
        initiatorStart(peerId, remoteHint)

    fun initiatorStart(peerId: ByteArray, remoteHint: ByteArray): ByteArray? {
        lifecycleRwLock.read {
            if (!isActive) return null
            val slot = getOrCreateSlot(relationKey(peerId))
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
                    removeSlot(slot)
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
    fun initiatorProcessHs2(peerId: ByteArray, hs2: ByteArray, advertisedRemoteHint: ByteArray): ByteArray? {
        lifecycleRwLock.read {
            if (!isActive) return null
            testOperationHook?.invoke("initiatorProcessHs2")
            val slot = slotFor(relationKey(peerId)) ?: return null
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
                removeSlot(slot)
                ctrl.destroy()
            }
            return result
        }
    }

    /**
     * Start responder handshake for [peerId], process inbound HS1, and emit HS2 (229 bytes).
     */
    fun beginResponder(peerId: ByteArray, remoteHint: ByteArray, hs1: ByteArray): ByteArray? =
        responderProcessHs1(peerId, remoteHint, hs1)

    fun responderProcessHs1(peerId: ByteArray, remoteHint: ByteArray, hs1: ByteArray): ByteArray? {
        lifecycleRwLock.read {
            if (!isActive) return null
            testOperationHook?.invoke("responderProcessHs1")
            val slot = getOrCreateSlot(relationKey(peerId))
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
                    removeSlot(slot)
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
    fun responderProcessHs3(peerId: ByteArray, hs3: ByteArray, advertisedRemoteHint: ByteArray): Boolean {
        lifecycleRwLock.read {
            if (!isActive) return false
            testOperationHook?.invoke("responderProcessHs3")
            val slot = slotFor(relationKey(peerId)) ?: return false
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
                removeSlot(slot)
                ctrl.destroy()
            }
            return result
        }
    }

    /**
     * Encrypt cleartext frame bytes for [peerId].
     * Returns ciphertext IFF session is READY and manager is active.
     */
    fun seal(peerId: ByteArray, frameBytes: ByteArray): ByteArray? {
        lifecycleRwLock.read {
            if (!isActive) return null
            testOperationHook?.invoke("seal")
            val slot = slotFor(relationKey(peerId)) ?: return null
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
    fun open(peerId: ByteArray, ciphertext: ByteArray): ByteArray? {
        lifecycleRwLock.read {
            if (!isActive) return null
            testOperationHook?.invoke("open")
            val slot = slotFor(relationKey(peerId)) ?: return null
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
    fun openWithResult(peerId: ByteArray, ciphertext: ByteArray): NoiseSession.CryptoOpenResult {
        val clear = open(peerId, ciphertext) ?: return NoiseSession.CryptoOpenResult.Rejected
        return NoiseSession.CryptoOpenResult.Authenticated(clear)
    }

    fun drop(peerId: ByteArray) {
        lifecycleRwLock.read {
            val slot = removeSlotFor(relationKey(peerId)) ?: return
            // T08: the terminal transition is serialized; the destructive
            // destroy is routed OUTSIDE the slot lock.
            slot.retire()?.destroy()
        }
    }

    private fun removeSlotFor(rk: RelationKey): SessionSlot? =
        mapLock.withLock {
            val slot = slots[rk.handle] ?: return@withLock null
            slots.remove(rk.handle)
            rememberGeneration(slot)
            return@withLock slot
        }

    fun destroyAll() {
        lifecycleRwLock.write {
            mapLock.withLock {
                for (slot in slots.values) {
                    slot.retire()?.destroy()
                }
                slots.clear()
            }
        }
    }

    fun invalidateForWipe() {
        testInvalidationAttemptHook?.invoke()
        lifecycleRwLock.write {
            mapLock.withLock {
                managerState = ManagerState.INVALIDATED
                for (slot in slots.values) {
                    slot.state = SlotState.INVALIDATED
                    slot.controller?.destroy()
                    slot.controller = null
                }
                slots.clear()
            }
        }
    }
}
