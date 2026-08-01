package io.godstone.mesh.crypto

import io.godstone.mesh.identity.Identity
import java.util.concurrent.ConcurrentHashMap

/**
 * Per-peer Noise session registry -- the layer that was MISSING from the runtime.
 *
 * THE DEFECT THIS CLOSES. NoiseSession.kt existed, was unit tested, and was
 * constructed by nothing outside its own test file. BleTransport wrote
 * `frame.encode()` straight to the GATT characteristic, so every byte the mesh
 * ever sent was PLAINTEXT while the documentation, the store listing and the
 * threat model all described an encrypted messenger.
 *
 * A crypto implementation that no production code path constructs provides
 * exactly zero confidentiality. It is worse than none, because it makes the
 * claim look substantiated.
 *
 * Invariant G now fails the build if BleTransport can reach `send` without
 * going through this class.
 */
class SessionManager(private val identity: Identity) {

    private val sessions = ConcurrentHashMap<String, NoiseSession>()

    private fun key(peerId: ByteArray) = peerId.joinToString("") { "%02x".format(it) }

    /**
     * Session for [peerId], starting an XX handshake as initiator if none exists.
     * Returns null while the handshake is still in flight -- callers MUST NOT
     * fall back to sending plaintext, which is the failure this class exists to
     * prevent. Queue the frame instead; the router is delay-tolerant by design.
     */
    fun established(peerId: ByteArray): NoiseSession? =
        sessions[key(peerId)]?.takeIf { it.isEstablished }

    fun beginInitiator(peerId: ByteArray, remoteHint: ByteArray): NoiseSession =
        sessions.computeIfAbsent(key(peerId)) {
            NoiseSession.initiator(identity, identity.nodeHint, remoteHint)
        }

    fun beginResponder(peerId: ByteArray, remoteHint: ByteArray): NoiseSession =
        sessions.computeIfAbsent(key(peerId)) {
            NoiseSession.responder(identity, remoteHint, identity.nodeHint)
        }

    /**
     * Encrypt an already-encoded GMP/2 frame for [peerId].
     *
     * Returns null when no established session exists. The caller must treat
     * null as "cannot send yet", never as "send it in the clear".
     */
    fun seal(peerId: ByteArray, frameBytes: ByteArray): ByteArray? =
        established(peerId)?.encrypt(frameBytes)

    /**
     * Decrypt bytes received from [peerId]. Throws on tamper or replay -- a
     * failed frame is corruption or an active attacker and is never returned.
     */
    fun open(peerId: ByteArray, ciphertext: ByteArray): ByteArray? =
        established(peerId)?.decrypt(ciphertext)

    fun drop(peerId: ByteArray) {
        sessions.remove(key(peerId))?.destroy()
    }

    fun destroyAll() {
        sessions.values.forEach { it.destroy() }
        sessions.clear()
    }
}
