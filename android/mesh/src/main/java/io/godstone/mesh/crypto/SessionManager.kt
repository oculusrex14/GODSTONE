package io.godstone.mesh.crypto

import io.godstone.mesh.identity.Identity
import io.godstone.mesh.identity.RuntimeLifecycleGate
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/**
 * Per-peer trusted session registry (Stage 4 Phase C8.4B).
 *
 * Replaces the untrusted raw NoiseSession registry. Owns and gates on
 * [TrustedHandshakeController] instances rather than raw Noise establishment.
 * Seal and open are permitted IFF the transport peer's controller has reached
 * [HandshakeTrustState.READY].
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

    private val lock = ReentrantLock()
    @Volatile private var managerState = ManagerState.ACTIVE

    private val controllers = HashMap<String, TrustedHandshakeController>()
    private val peerLocks = ConcurrentHashMap<String, ReentrantLock>()

    private fun key(peerId: ByteArray): String = peerId.joinToString("") { "%02x".format(it) }

    private fun getPeerLock(key: String): ReentrantLock =
        peerLocks.computeIfAbsent(key) { ReentrantLock() }

    val isInvalidated: Boolean
        get() = managerState == ManagerState.INVALIDATED || (lifecycleGate?.isInvalidated == true)

    val isActive: Boolean
        get() = !isInvalidated

    /**
     * True IFF the peer has an active TrustedHandshakeController in HandshakeTrustState.READY
     * and the manager is not invalidated.
     */
    fun isReady(peerId: ByteArray): Boolean {
        if (!isActive) return false
        val k = key(peerId)
        val ctrl = lock.withLock { controllers[k] } ?: return false
        return ctrl.isReady && ctrl.state == HandshakeTrustState.READY
    }

    /**
     * Start initiator handshake for [peerId] and emit HS1 (32 bytes).
     * Serialized per peer. Returns null if already exists, collision, or invalidated.
     */
    fun beginInitiator(peerId: ByteArray, remoteHint: ByteArray): ByteArray? =
        initiatorStart(peerId, remoteHint)

    fun initiatorStart(peerId: ByteArray, remoteHint: ByteArray): ByteArray? {
        if (!isActive) return null
        val k = key(peerId)
        val pLock = getPeerLock(k)
        return pLock.withLock {
            if (!isActive) return@withLock null
            val exists = lock.withLock { controllers.containsKey(k) }
            if (exists) return@withLock null

            val ctrl = TrustedHandshakeController.initiator(
                identity = identity,
                remoteHint = remoteHint,
                trustAuthority = trustAuthority,
                localBindingIssuer = localBindingIssuer
            )
            val hs1 = try {
                ctrl.initiatorWriteMessage1()
            } catch (e: Exception) {
                return@withLock null
            }

            val saved = lock.withLock {
                if (!isActive) {
                    ctrl.destroy()
                    false
                } else {
                    controllers[k] = ctrl
                    true
                }
            }
            if (!saved) return@withLock null
            hs1
        }
    }

    /**
     * Process HS2 from responder and emit HS3 (197 bytes).
     * On success, transitions controller to READY. On failure or non-READY, drops entry and returns null.
     */
    fun initiatorProcessHs2(peerId: ByteArray, hs2: ByteArray, advertisedRemoteHint: ByteArray): ByteArray? {
        if (!isActive) return null
        val k = key(peerId)
        val pLock = getPeerLock(k)
        return pLock.withLock {
            if (!isActive) return@withLock null
            val ctrl = lock.withLock { controllers[k] } ?: return@withLock null
            val hs3 = ctrl.initiatorProcessMessage2(hs2, advertisedRemoteHint)
            if (hs3 == null || !ctrl.isReady) {
                lock.withLock { controllers.remove(k) }
                ctrl.destroy()
                return@withLock null
            }
            hs3
        }
    }

    /**
     * Start responder handshake for [peerId], process inbound HS1, and emit HS2 (229 bytes).
     */
    fun beginResponder(peerId: ByteArray, remoteHint: ByteArray, hs1: ByteArray): ByteArray? =
        responderProcessHs1(peerId, remoteHint, hs1)

    fun responderProcessHs1(peerId: ByteArray, remoteHint: ByteArray, hs1: ByteArray): ByteArray? {
        if (!isActive) return null
        val k = key(peerId)
        val pLock = getPeerLock(k)
        return pLock.withLock {
            if (!isActive) return@withLock null
            val exists = lock.withLock { controllers.containsKey(k) }
            if (exists) return@withLock null

            val ctrl = TrustedHandshakeController.responder(
                identity = identity,
                remoteHint = remoteHint,
                trustAuthority = trustAuthority
            )
            val hs2 = try {
                ctrl.responderProcessMessage1AndWriteMessage2(hs1)
            } catch (e: Exception) {
                return@withLock null
            }
            if (hs2 == null) {
                ctrl.destroy()
                return@withLock null
            }

            val saved = lock.withLock {
                if (!isActive) {
                    ctrl.destroy()
                    false
                } else {
                    controllers[k] = ctrl
                    true
                }
            }
            if (!saved) return@withLock null
            hs2
        }
    }

    /**
     * Process inbound HS3 from initiator.
     * Returns true IFF handshake reaches HandshakeTrustState.READY.
     */
    fun responderProcessHs3(peerId: ByteArray, hs3: ByteArray, advertisedRemoteHint: ByteArray): Boolean {
        if (!isActive) return false
        val k = key(peerId)
        val pLock = getPeerLock(k)
        return pLock.withLock {
            if (!isActive) return@withLock false
            val ctrl = lock.withLock { controllers[k] } ?: return@withLock false
            val ok = ctrl.responderProcessMessage3(hs3, advertisedRemoteHint)
            if (!ok || !ctrl.isReady) {
                lock.withLock { controllers.remove(k) }
                ctrl.destroy()
                return@withLock false
            }
            true
        }
    }

    /**
     * Encrypt cleartext frame bytes for [peerId].
     * Returns ciphertext IFF session is READY and manager is active.
     */
    fun seal(peerId: ByteArray, frameBytes: ByteArray): ByteArray? {
        if (!isActive) return null
        val k = key(peerId)
        val ctrl = lock.withLock { controllers[k] } ?: return null
        if (!ctrl.isReady || ctrl.state != HandshakeTrustState.READY) return null
        return ctrl.seal(frameBytes)
    }

    /**
     * Decrypt ciphertext bytes received from [peerId].
     * Returns cleartext IFF session is READY and manager is active.
     */
    fun open(peerId: ByteArray, ciphertext: ByteArray): ByteArray? {
        if (!isActive) return null
        val k = key(peerId)
        val ctrl = lock.withLock { controllers[k] } ?: return null
        if (!ctrl.isReady || ctrl.state != HandshakeTrustState.READY) return null
        return ctrl.open(ciphertext)
    }

    fun drop(peerId: ByteArray) {
        val k = key(peerId)
        val ctrl = lock.withLock { controllers.remove(k) }
        ctrl?.destroy()
    }

    fun destroyAll() {
        lock.withLock {
            for (ctrl in controllers.values) {
                ctrl.destroy()
            }
            controllers.clear()
        }
    }

    fun invalidateForWipe() {
        lock.withLock {
            managerState = ManagerState.INVALIDATED
            for (ctrl in controllers.values) {
                ctrl.destroy()
            }
            controllers.clear()
        }
    }
}
