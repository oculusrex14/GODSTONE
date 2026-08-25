package io.godstone.mesh.crypto

import io.godstone.mesh.identity.Identity
import io.godstone.mesh.identity.IdentityBindingValidationResult
import io.godstone.mesh.identity.IdentityBindingValidator
import io.godstone.mesh.identity.PeerIdentityRepository
import io.godstone.mesh.identity.PeerTrustApplyResult
import io.godstone.mesh.identity.ValidatedPeerBinding

/**
 * Lifecycle state for trusted handshake execution (ADR-003, Phase C8.4A).
 * Distinguishes cryptographic establishment from higher-level application READY authority.
 */
enum class HandshakeTrustState {
    INITIAL,
    HANDSHAKE_IN_PROGRESS,
    NOISE_ESTABLISHED,
    READY,
    QUARANTINED,
    SECURITY_REJECT,
    CORRUPT,
    STORAGE_FAILURE
}

/**
 * Narrow trust authority interface for handshake ingestion (ADR-003, Phase C8.4A).
 * Decouples the handshake controller from store internals and mutation operations.
 */
internal interface PeerBindingTrustAuthority {
    fun applyValidatedBinding(binding: ValidatedPeerBinding): PeerTrustApplyResult
}

/**
 * Production implementation of [PeerBindingTrustAuthority] delegating to [PeerIdentityRepository].
 */
internal class RepositoryPeerBindingTrustAuthority(
    private val repository: PeerIdentityRepository
) : PeerBindingTrustAuthority {
    override fun applyValidatedBinding(binding: ValidatedPeerBinding): PeerTrustApplyResult =
        repository.applyValidatedBinding(binding)
}

/**
 * Trust-aware Noise handshake controller (ADR-003, Phase C8.4A).
 *
 * Enforces:
 * - Pure [IdentityBindingValidator] validation before any repository access.
 * - Application of validated remote bindings to [PeerBindingTrustAuthority].
 * - Withholding HS3 on initiator validation/trust failure.
 * - Withholding READY on responder validation/trust failure.
 * - Separation of Noise cryptographic establishment from application READY authority.
 * - Refusal of application seal/open before READY state.
 */
internal class TrustedHandshakeController(
    val noiseSession: NoiseSession,
    val trustAuthority: PeerBindingTrustAuthority,
    val localIdentity: Identity
) {
    var state: HandshakeTrustState = HandshakeTrustState.INITIAL
        private set

    val isReady: Boolean get() = state == HandshakeTrustState.READY

    val authenticatedRemoteStaticKey: ByteArray?
        get() = noiseSession.remoteStaticKey

    /**
     * Initiator step 1: write HS1 (32 bytes with empty payload).
     */
    fun initiatorWriteMessage1(): ByteArray {
        check(state == HandshakeTrustState.INITIAL) { "Invalid state for initiator HS1: $state" }
        val hs1 = noiseSession.writeHandshakeMessage(ByteArray(0))
        check(hs1.size == 32) { "HS1 size must be exactly 32 bytes, was ${hs1.size}" }
        state = HandshakeTrustState.HANDSHAKE_IN_PROGRESS
        return hs1
    }

    /**
     * Initiator step 2: read HS2 (229 bytes), validate responder binding, apply to trust authority,
     * and only on Accepted / FirstSeenPinned write HS3 (197 bytes) and advance to READY.
     * Returns HS3 bytes on success, or null on rejection / quarantine / error.
     */
    fun initiatorProcessMessage2(hs2: ByteArray, advertisedRemoteHint: ByteArray): ByteArray? {
        check(state == HandshakeTrustState.HANDSHAKE_IN_PROGRESS) { "Invalid state for initiator HS2: $state" }
        val readResult = try {
            noiseSession.readHandshakeMessageWithResult(hs2)
        } catch (e: Exception) {
            state = HandshakeTrustState.SECURITY_REJECT
            return null
        }

        val remoteStatic = readResult.authenticatedRemoteStaticKey
        if (remoteStatic == null || remoteStatic.size != 32) {
            state = HandshakeTrustState.SECURITY_REJECT
            return null
        }

        val validation = IdentityBindingValidator.validate(
            serialized = readResult.payload,
            authenticatedRemoteStaticKey = remoteStatic,
            advertisedNodeHint = advertisedRemoteHint
        )

        if (validation !is IdentityBindingValidationResult.Valid) {
            state = HandshakeTrustState.SECURITY_REJECT
            return null
        }

        val applyResult = trustAuthority.applyValidatedBinding(validation.binding)
        return when (applyResult) {
            is PeerTrustApplyResult.Accepted,
            is PeerTrustApplyResult.FirstSeenPinned -> {
                val localBinding = localIdentity.issueIdentityBinding()
                val localBytes = localBinding.encode()
                check(localBytes.size == 133) { "Local binding size must be 133, was ${localBytes.size}" }
                val hs3 = noiseSession.writeHandshakeMessage(localBytes)
                check(hs3.size == 197) { "HS3 size must be exactly 197 bytes, was ${hs3.size}" }
                state = HandshakeTrustState.READY
                hs3
            }
            is PeerTrustApplyResult.KeyChangedQuarantined -> {
                state = HandshakeTrustState.QUARANTINED
                null
            }
            is PeerTrustApplyResult.Rejected -> {
                state = HandshakeTrustState.SECURITY_REJECT
                null
            }
            is PeerTrustApplyResult.Corrupt -> {
                state = HandshakeTrustState.CORRUPT
                null
            }
            is PeerTrustApplyResult.StorageFailure -> {
                state = HandshakeTrustState.STORAGE_FAILURE
                null
            }
        }
    }

    /**
     * Responder step 1: read HS1 (32 bytes with empty payload), issue local binding, write HS2 (229 bytes).
     * Returns HS2 bytes on success, or null on rejection.
     */
    fun responderProcessMessage1AndWriteMessage2(hs1: ByteArray): ByteArray? {
        check(state == HandshakeTrustState.INITIAL) { "Invalid state for responder HS1: $state" }
        val readResult = try {
            noiseSession.readHandshakeMessageWithResult(hs1)
        } catch (e: Exception) {
            state = HandshakeTrustState.SECURITY_REJECT
            return null
        }

        if (readResult.payload.isNotEmpty()) {
            state = HandshakeTrustState.SECURITY_REJECT
            return null
        }

        val localBinding = localIdentity.issueIdentityBinding()
        val localBytes = localBinding.encode()
        check(localBytes.size == 133) { "Local binding size must be 133, was ${localBytes.size}" }
        val hs2 = noiseSession.writeHandshakeMessage(localBytes)
        check(hs2.size == 229) { "HS2 size must be exactly 229 bytes, was ${hs2.size}" }
        state = HandshakeTrustState.HANDSHAKE_IN_PROGRESS
        return hs2
    }

    /**
     * Responder step 2: read HS3 (197 bytes), validate initiator binding, apply to trust authority,
     * and only on Accepted / FirstSeenPinned advance to READY.
     * Returns true on success (READY), false on rejection / quarantine / error.
     */
    fun responderProcessMessage3(hs3: ByteArray, advertisedRemoteHint: ByteArray): Boolean {
        check(state == HandshakeTrustState.HANDSHAKE_IN_PROGRESS) { "Invalid state for responder HS3: $state" }
        val readResult = try {
            noiseSession.readHandshakeMessageWithResult(hs3)
        } catch (e: Exception) {
            state = HandshakeTrustState.SECURITY_REJECT
            return false
        }

        val remoteStatic = readResult.authenticatedRemoteStaticKey
        if (remoteStatic == null || remoteStatic.size != 32) {
            state = HandshakeTrustState.SECURITY_REJECT
            return false
        }

        val validation = IdentityBindingValidator.validate(
            serialized = readResult.payload,
            authenticatedRemoteStaticKey = remoteStatic,
            advertisedNodeHint = advertisedRemoteHint
        )

        if (validation !is IdentityBindingValidationResult.Valid) {
            state = HandshakeTrustState.SECURITY_REJECT
            return false
        }

        val applyResult = trustAuthority.applyValidatedBinding(validation.binding)
        return when (applyResult) {
            is PeerTrustApplyResult.Accepted,
            is PeerTrustApplyResult.FirstSeenPinned -> {
                state = HandshakeTrustState.READY
                true
            }
            is PeerTrustApplyResult.KeyChangedQuarantined -> {
                state = HandshakeTrustState.QUARANTINED
                false
            }
            is PeerTrustApplyResult.Rejected -> {
                state = HandshakeTrustState.SECURITY_REJECT
                false
            }
            is PeerTrustApplyResult.Corrupt -> {
                state = HandshakeTrustState.CORRUPT
                false
            }
            is PeerTrustApplyResult.StorageFailure -> {
                state = HandshakeTrustState.STORAGE_FAILURE
                false
            }
        }
    }

    /**
     * Application seal: encrypts plaintext only if state == READY.
     */
    fun seal(plaintext: ByteArray): ByteArray? {
        if (state != HandshakeTrustState.READY) return null
        return noiseSession.encrypt(plaintext)
    }

    /**
     * Application open: decrypts ciphertext only if state == READY.
     */
    fun open(ciphertext: ByteArray): ByteArray? {
        if (state != HandshakeTrustState.READY) return null
        return noiseSession.decrypt(ciphertext)
    }

    companion object {
        fun initiator(
            identity: Identity,
            remoteHint: ByteArray,
            trustAuthority: PeerBindingTrustAuthority
        ): TrustedHandshakeController {
            val session = NoiseSession.initiator(identity, identity.nodeHint, remoteHint)
            return TrustedHandshakeController(session, trustAuthority, identity)
        }

        fun responder(
            identity: Identity,
            remoteHint: ByteArray,
            trustAuthority: PeerBindingTrustAuthority
        ): TrustedHandshakeController {
            val session = NoiseSession.responder(identity, remoteHint, identity.nodeHint)
            return TrustedHandshakeController(session, trustAuthority, identity)
        }
    }
}
