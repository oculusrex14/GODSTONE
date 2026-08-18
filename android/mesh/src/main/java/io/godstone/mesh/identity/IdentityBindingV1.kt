package io.godstone.mesh.identity

import io.godstone.core.crypto.Ed25519Keys
import org.bouncycastle.crypto.digests.Blake2sDigest

/** Canonical version identifier for IdentityBindingV1. */
const val IDENTITY_BINDING_VERSION: Byte = 0x01

/** Fixed serialized byte length of an IdentityBindingV1 payload (133 bytes). */
const val IDENTITY_BINDING_SERIALIZED_LENGTH: Int = 133

/** Fixed byte length of the signature preimage (80 bytes). */
const val IDENTITY_BINDING_PREIMAGE_LENGTH: Int = 80

/** Authoritative byte length of an Ed25519 signing public key (32 bytes). */
const val IDENTITY_BINDING_SIGNING_KEY_LENGTH: Int = 32

/** Authoritative byte length of an X25519 static DH public key (32 bytes). */
const val IDENTITY_BINDING_STATIC_DH_KEY_LENGTH: Int = 32

/** Authoritative byte length of an Ed25519 signature (64 bytes). */
const val IDENTITY_BINDING_SIGNATURE_LENGTH: Int = 64

/** Authoritative byte length of a node_id (16 bytes). */
const val IDENTITY_BINDING_NODE_ID_LENGTH: Int = 16

/** Authoritative byte length of a discovery node hint (4 bytes). */
const val IDENTITY_BINDING_NODE_HINT_LENGTH: Int = 4

/** Domain separator for IdentityBindingV1 signature preimages. */
val IDENTITY_BINDING_DOMAIN: ByteArray = "GMP2-IDBIND".toByteArray(Charsets.US_ASCII)

/**
 * Immutable canonical representation of an IdentityBindingV1 object (ADR-003, Phase C8.1A).
 *
 * Enforces defensive copies of all internal byte arrays on construction, parsing, and getters.
 */
class IdentityBindingV1 private constructor(
    val version: Byte,
    val generation: Long,
    signingPublicKey: ByteArray,
    staticDhPublicKey: ByteArray,
    signature: ByteArray,
) {
    private val _signingPublicKey: ByteArray = signingPublicKey.copyOf()
    private val _staticDhPublicKey: ByteArray = staticDhPublicKey.copyOf()
    private val _signature: ByteArray = signature.copyOf()

    val signingPublicKey: ByteArray get() = _signingPublicKey.copyOf()
    val staticDhPublicKey: ByteArray get() = _staticDhPublicKey.copyOf()
    val signature: ByteArray get() = _signature.copyOf()

    fun encode(): ByteArray {
        val out = ByteArray(IDENTITY_BINDING_SERIALIZED_LENGTH)
        out[0] = version
        out[1] = ((generation ushr 24) and 0xFF).toByte()
        out[2] = ((generation ushr 16) and 0xFF).toByte()
        out[3] = ((generation ushr 8) and 0xFF).toByte()
        out[4] = (generation and 0xFF).toByte()
        System.arraycopy(_signingPublicKey, 0, out, 5, IDENTITY_BINDING_SIGNING_KEY_LENGTH)
        System.arraycopy(_staticDhPublicKey, 0, out, 37, IDENTITY_BINDING_STATIC_DH_KEY_LENGTH)
        System.arraycopy(_signature, 0, out, 69, IDENTITY_BINDING_SIGNATURE_LENGTH)
        return out
    }

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is IdentityBindingV1) return false
        return version == other.version &&
               generation == other.generation &&
               _signingPublicKey.contentEquals(other._signingPublicKey) &&
               _staticDhPublicKey.contentEquals(other._staticDhPublicKey) &&
               _signature.contentEquals(other._signature)
    }

    override fun hashCode(): Int {
        var result = version.toInt()
        result = 31 * result + generation.hashCode()
        result = 31 * result + _signingPublicKey.contentHashCode()
        result = 31 * result + _staticDhPublicKey.contentHashCode()
        result = 31 * result + _signature.contentHashCode()
        return result
    }

    companion object {
        fun parse(serialized: ByteArray): IdentityBindingV1 {
            if (serialized.size != IDENTITY_BINDING_SERIALIZED_LENGTH) {
                throw IllegalArgumentException(
                    "Invalid serialized length: expected $IDENTITY_BINDING_SERIALIZED_LENGTH, got ${serialized.size}"
                )
            }
            val version = serialized[0]
            if (version != IDENTITY_BINDING_VERSION) {
                throw IllegalArgumentException("Unsupported version: $version")
            }
            val gen = ((serialized[1].toLong() and 0xFF) shl 24) or
                      ((serialized[2].toLong() and 0xFF) shl 16) or
                      ((serialized[3].toLong() and 0xFF) shl 8) or
                      (serialized[4].toLong() and 0xFF)
            val signingPub = serialized.copyOfRange(5, 37)
            val staticPub = serialized.copyOfRange(37, 69)
            val sig = serialized.copyOfRange(69, 133)
            return IdentityBindingV1(version, gen, signingPub, staticPub, sig)
        }

        fun create(
            generation: Long,
            signingPublicKey: ByteArray,
            staticDhPublicKey: ByteArray,
            signature: ByteArray,
            version: Byte = IDENTITY_BINDING_VERSION,
        ): IdentityBindingV1 {
            require(version == IDENTITY_BINDING_VERSION) { "Unsupported version: $version" }
            require(generation in 0L..0xFFFFFFFFL) { "Generation out of range: $generation" }
            require(signingPublicKey.size == IDENTITY_BINDING_SIGNING_KEY_LENGTH) {
                "Invalid signing public key size: ${signingPublicKey.size}"
            }
            require(staticDhPublicKey.size == IDENTITY_BINDING_STATIC_DH_KEY_LENGTH) {
                "Invalid static DH public key size: ${staticDhPublicKey.size}"
            }
            require(signature.size == IDENTITY_BINDING_SIGNATURE_LENGTH) {
                "Invalid signature size: ${signature.size}"
            }
            return IdentityBindingV1(version, generation, signingPublicKey, staticDhPublicKey, signature)
        }

        fun signaturePreimage(
            generation: Long,
            signingPublicKey: ByteArray,
            staticDhPublicKey: ByteArray,
            version: Byte = IDENTITY_BINDING_VERSION,
        ): ByteArray {
            require(version == IDENTITY_BINDING_VERSION) { "Unsupported version: $version" }
            require(generation in 0L..0xFFFFFFFFL) { "Generation out of range: $generation" }
            require(signingPublicKey.size == IDENTITY_BINDING_SIGNING_KEY_LENGTH) {
                "Invalid signing public key size: ${signingPublicKey.size}"
            }
            require(staticDhPublicKey.size == IDENTITY_BINDING_STATIC_DH_KEY_LENGTH) {
                "Invalid static DH public key size: ${staticDhPublicKey.size}"
            }
            val out = ByteArray(IDENTITY_BINDING_PREIMAGE_LENGTH)
            System.arraycopy(IDENTITY_BINDING_DOMAIN, 0, out, 0, IDENTITY_BINDING_DOMAIN.size)
            out[IDENTITY_BINDING_DOMAIN.size] = version
            val genOffset = IDENTITY_BINDING_DOMAIN.size + 1
            out[genOffset] = ((generation ushr 24) and 0xFF).toByte()
            out[genOffset + 1] = ((generation ushr 16) and 0xFF).toByte()
            out[genOffset + 2] = ((generation ushr 8) and 0xFF).toByte()
            out[genOffset + 3] = (generation and 0xFF).toByte()
            System.arraycopy(signingPublicKey, 0, out, genOffset + 4, IDENTITY_BINDING_SIGNING_KEY_LENGTH)
            System.arraycopy(staticDhPublicKey, 0, out, genOffset + 36, IDENTITY_BINDING_STATIC_DH_KEY_LENGTH)
            return out
        }

        fun deriveNodeId(signingPublicKey: ByteArray): ByteArray {
            require(signingPublicKey.size == IDENTITY_BINDING_SIGNING_KEY_LENGTH) {
                "Invalid signing public key size: ${signingPublicKey.size}"
            }
            val d = Blake2sDigest(null, IDENTITY_BINDING_NODE_ID_LENGTH, null, null)
            d.update(signingPublicKey, 0, signingPublicKey.size)
            val out = ByteArray(IDENTITY_BINDING_NODE_ID_LENGTH)
            d.doFinal(out, 0)
            return out
        }

        fun deriveNodeHint(nodeId: ByteArray): ByteArray {
            require(nodeId.size == IDENTITY_BINDING_NODE_ID_LENGTH) {
                "Invalid node_id size: ${nodeId.size}"
            }
            return nodeId.copyOfRange(0, IDENTITY_BINDING_NODE_HINT_LENGTH)
        }
    }
}

/**
 * Immutable representation of a cryptographically validated peer identity binding (ADR-003, Phase C8.1A).
 *
 * Produced only after exact length, version, signature, node_id derivation, Noise static match,
 * and advertisement hint consistency have all succeeded.
 */
class ValidatedPeerBinding(
    nodeId: ByteArray,
    signingPublicKey: ByteArray,
    staticDhPublicKey: ByteArray,
    val generation: Long,
) {
    private val _nodeId: ByteArray = nodeId.copyOf()
    private val _signingPublicKey: ByteArray = signingPublicKey.copyOf()
    private val _staticDhPublicKey: ByteArray = staticDhPublicKey.copyOf()

    val nodeId: ByteArray get() = _nodeId.copyOf()
    val signingPublicKey: ByteArray get() = _signingPublicKey.copyOf()
    val staticDhPublicKey: ByteArray get() = _staticDhPublicKey.copyOf()

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is ValidatedPeerBinding) return false
        return generation == other.generation &&
               _nodeId.contentEquals(other._nodeId) &&
               _signingPublicKey.contentEquals(other._signingPublicKey) &&
               _staticDhPublicKey.contentEquals(other._staticDhPublicKey)
    }

    override fun hashCode(): Int {
        var result = _nodeId.contentHashCode()
        result = 31 * result + _signingPublicKey.contentHashCode()
        result = 31 * result + _staticDhPublicKey.contentHashCode()
        result = 31 * result + generation.hashCode()
        return result
    }
}

/**
 * Result taxonomy for pure identity binding validation (ADR-003, Phase C8.1A).
 */
sealed interface IdentityBindingValidationResult {
    data class Valid(val binding: ValidatedPeerBinding) : IdentityBindingValidationResult
    data object MalformedLength : IdentityBindingValidationResult
    data object UnsupportedVersion : IdentityBindingValidationResult
    data object InvalidSignature : IdentityBindingValidationResult
    data object NoiseStaticMismatch : IdentityBindingValidationResult
    data object AdvertisementHintMismatch : IdentityBindingValidationResult
    data object InvalidContext : IdentityBindingValidationResult
}

/**
 * Pure validator executing the 10-step cryptographic validation pipeline (ADR-003, Phase C8.1A).
 */
object IdentityBindingValidator {
    fun validate(
        serialized: ByteArray,
        authenticatedRemoteStaticKey: ByteArray,
        advertisedNodeHint: ByteArray,
    ): IdentityBindingValidationResult {
        // Invariant check on context arguments
        if (authenticatedRemoteStaticKey.size != IDENTITY_BINDING_STATIC_DH_KEY_LENGTH ||
            advertisedNodeHint.size != IDENTITY_BINDING_NODE_HINT_LENGTH
        ) {
            return IdentityBindingValidationResult.InvalidContext
        }

        // 1. Length check
        if (serialized.size != IDENTITY_BINDING_SERIALIZED_LENGTH) {
            return IdentityBindingValidationResult.MalformedLength
        }

        // 2. Version check
        val version = serialized[0]
        if (version != IDENTITY_BINDING_VERSION) {
            return IdentityBindingValidationResult.UnsupportedVersion
        }

        // 3. Parse generation (uint32_be)
        val generation = ((serialized[1].toLong() and 0xFF) shl 24) or
                         ((serialized[2].toLong() and 0xFF) shl 16) or
                         ((serialized[3].toLong() and 0xFF) shl 8) or
                         (serialized[4].toLong() and 0xFF)

        // 4. Parse signing public key (32 bytes)
        val signingPublicKey = serialized.copyOfRange(5, 37)

        // 5. Parse static DH public key (32 bytes)
        val staticDhPublicKey = serialized.copyOfRange(37, 69)

        // 6. Parse signature (64 bytes)
        val signature = serialized.copyOfRange(69, 133)

        // 7. Verify Ed25519 signature over canonical GMP2-IDBIND preimage
        val preimage = IdentityBindingV1.signaturePreimage(generation, signingPublicKey, staticDhPublicKey, version)
        val sigValid = Ed25519Keys.verify(preimage, signature, signingPublicKey)
        if (!sigValid) {
            return IdentityBindingValidationResult.InvalidSignature
        }

        // 8. Derive node_id = BLAKE2s-128(signingPublicKey)
        val nodeId = IdentityBindingV1.deriveNodeId(signingPublicKey)

        // 9. Check binding.static_dh_public_key == authenticatedRemoteStaticKey
        if (!staticDhPublicKey.contentEquals(authenticatedRemoteStaticKey)) {
            return IdentityBindingValidationResult.NoiseStaticMismatch
        }

        // 10. Check first4(node_id) == advertisedNodeHint
        val expectedHint = IdentityBindingV1.deriveNodeHint(nodeId)
        if (!expectedHint.contentEquals(advertisedNodeHint)) {
            return IdentityBindingValidationResult.AdvertisementHintMismatch
        }

        val validated = ValidatedPeerBinding(
            nodeId = nodeId,
            signingPublicKey = signingPublicKey,
            staticDhPublicKey = staticDhPublicKey,
            generation = generation,
        )
        return IdentityBindingValidationResult.Valid(validated)
    }
}
