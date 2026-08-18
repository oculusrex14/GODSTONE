package io.godstone.mesh.identity

import android.content.Context
import io.godstone.core.crypto.Ed25519Keys
import io.godstone.core.crypto.X25519Keys
import org.bouncycastle.crypto.digests.Blake2sDigest
import java.security.SecureRandom

/**
 * Long-term node identity and local binding authority (ADR-003, Phase C8.1B).
 *
 * Owns durable [bindingGeneration], derived public keys, and private keys.
 * All internal byte arrays are stored privately and copied on read to ensure immutability.
 *
 * node_id = BLAKE2s-128(identityPub), 16 bytes.
 */
class Identity private constructor(
    val bindingGeneration: Long,
    identityPub: ByteArray,      // Ed25519, 32 bytes
    identityPriv: ByteArray,     // Ed25519 private seed, 32 bytes
    staticDhPub: ByteArray,      // X25519, 32 bytes
    staticDhPriv: ByteArray,     // X25519 static private key, 32 bytes
    nodeId: ByteArray,           // 16 bytes
) {
    private val _identityPub: ByteArray = identityPub.copyOf()
    private val _identityPriv: ByteArray = identityPriv.copyOf()
    private val _staticDhPub: ByteArray = staticDhPub.copyOf()
    private val _staticDhPriv: ByteArray = staticDhPriv.copyOf()
    private val _nodeId: ByteArray = nodeId.copyOf()

    /** Derived Ed25519 public key (32 bytes). Defensive copy. */
    val identityPub: ByteArray get() = _identityPub.copyOf()

    /** Derived X25519 static DH public key (32 bytes). Defensive copy. */
    val staticDhPub: ByteArray get() = _staticDhPub.copyOf()

    /**
     * X25519 static private key (32 bytes). Defensive copy for existing NoiseSession constructor.
     * Private key material is never exposed via public mutable reference.
     */
    val staticDhPriv: ByteArray get() = _staticDhPriv.copyOf()

    /** Authoritative node ID derived as BLAKE2s-128(identityPub) (16 bytes). Defensive copy. */
    val nodeId: ByteArray get() = _nodeId.copyOf()

    /** First 4 bytes of node_id, broadcast in BLE advertisement hint. Defensive copy. */
    val nodeHint: ByteArray get() = _nodeId.copyOf(4)

    /**
     * Six-word call sign so two people can verify each other verbally, derived
     * deterministically from node_id against the BIP-39 wordlist.
     */
    fun callSign(wordlist: List<String>): String {
        val words = ArrayList<String>(6)
        var acc = 0L
        var bits = 0
        var idx = 0
        while (words.size < 6) {
            if (bits < 11) {
                acc = (acc shl 8) or (_nodeId[idx % _nodeId.size].toLong() and 0xFF)
                bits += 8
                idx++
                continue
            }
            val w = ((acc shr (bits - 11)) and 0x7FF).toInt()
            words.add(wordlist[w % wordlist.size])
            bits -= 11
        }
        return words.joinToString(" ")
    }

    /**
     * Canonical local issuer producing an IdentityBindingV1 for the local node (ADR-003, Phase C8.1B).
     *
     * The binding generation, signing public key, and static DH public key are sourced directly
     * from the owned identity authority without caller-supplied parameters. Signs the canonical
     * 80-byte GMP2-IDBIND preimage and self-verifies before returning.
     */
    internal fun issueIdentityBinding(): IdentityBindingV1 {
        val gen = this.bindingGeneration
        val signingPublic = _identityPub.copyOf()
        val staticPublic = _staticDhPub.copyOf()
        val preimage = IdentityBindingV1.signaturePreimage(gen, signingPublic, staticPublic)
        val signature = Ed25519Keys.sign(preimage, _identityPriv)

        if (!Ed25519Keys.verify(preimage, signature, signingPublic)) {
            throw LocalIdentityException.IdentityStateCorrupt("Local issuer self-verification failed")
        }

        return IdentityBindingV1.create(gen, signingPublic, staticPublic, signature)
    }

    companion object {
        private const val PREFS = "godstone_identity"

        fun loadOrCreate(ctx: Context): Identity =
            loadOrCreate(EncryptedSharedPreferencesStorage(ctx), SecureRandom())

        internal fun loadOrCreate(
            storage: IdentityStorage,
            rng: SecureRandom = SecureRandom(),
        ): Identity {
            val v1Raw = storage.readV1State()
            val legacy = storage.readLegacyMaterial()

            if (storage.hasPartialLegacy()) {
                throw LocalIdentityException.IdentityStateCorrupt("Partial legacy identity state detected")
            }

            return when {
                // CASE A -- EMPTY
                v1Raw == null && legacy == null -> {
                    val ed = Ed25519Keys.generate(rng)
                    val dh = X25519Keys.generate(rng)
                    val state = LocalIdentityStateV1.create(
                        generation = 0L,
                        ed25519Seed = ed.priv,
                        x25519PrivateKey = dh.priv,
                    )
                    val ok = storage.writeV1State(state.encode())
                    if (!ok) {
                        throw LocalIdentityException.IdentityPersistenceFailure(
                            "Failed to persist fresh identity state synchronously"
                        )
                    }
                    fromState(state)
                }

                // CASE B -- V1 ONLY
                v1Raw != null && legacy == null -> {
                    val state = LocalIdentityStateV1.parse(v1Raw)
                    fromState(state)
                }

                // CASE C -- CANONICAL LEGACY MIGRATION
                v1Raw == null && legacy != null -> {
                    if (legacy.idPub.size != 32 || legacy.idPriv.size != 32 ||
                        legacy.dhPub.size != 32 || legacy.dhPriv.size != 32
                    ) {
                        throw LocalIdentityException.IdentityStateCorrupt("Invalid legacy key length")
                    }

                    val derivedEdPub = Ed25519Keys.publicKeyFromPrivate(legacy.idPriv)
                    if (!derivedEdPub.contentEquals(legacy.idPub)) {
                        throw LocalIdentityException.IdentityStateCorrupt(
                            "Legacy Ed25519 public key does not match private seed"
                        )
                    }

                    val derivedDhPub = X25519Keys.publicKeyFromPrivate(legacy.dhPriv)
                    if (!derivedDhPub.contentEquals(legacy.dhPub)) {
                        throw LocalIdentityException.IdentityStateCorrupt(
                            "Legacy X25519 public key does not match private key"
                        )
                    }

                    val state = LocalIdentityStateV1.create(
                        generation = 0L,
                        ed25519Seed = legacy.idPriv,
                        x25519PrivateKey = legacy.dhPriv,
                    )
                    val ok = storage.migrateLegacyToV1(state.encode())
                    if (!ok) {
                        throw LocalIdentityException.IdentityPersistenceFailure(
                            "Failed to migrate legacy identity to V1 synchronously"
                        )
                    }
                    fromState(state)
                }

                // CASE D -- ANY PARTIAL OR MIXED STATE
                else -> {
                    throw LocalIdentityException.IdentityStateCorrupt(
                        "Mixed V1 and legacy identity state detected in storage"
                    )
                }
            }
        }

        private fun fromState(state: LocalIdentityStateV1): Identity {
            val edPub = Ed25519Keys.publicKeyFromPrivate(state.ed25519Seed)
            val dhPub = X25519Keys.publicKeyFromPrivate(state.x25519PrivateKey)
            val nid = nodeIdOf(edPub)
            return Identity(
                bindingGeneration = state.generation,
                identityPub = edPub,
                identityPriv = state.ed25519Seed,
                staticDhPub = dhPub,
                staticDhPriv = state.x25519PrivateKey,
                nodeId = nid,
            )
        }

        /**
         * Panic wipe. Destroys identity and all derived material so that prior
         * traffic cannot be linked to the regenerated node.
         */
        fun panicWipe(ctx: Context) {
            ctx.deleteSharedPreferences(PREFS)
        }

        /**
         * Build an Identity directly from already-generated key material. Used by
         * tests with fixed generation 0. Validates that supplied public keys match derived keys.
         */
        internal fun fromKeyMaterial(
            edPub: ByteArray,
            edPriv: ByteArray,
            dhPub: ByteArray,
            dhPriv: ByteArray,
        ): Identity {
            require(edPub.size == 32 && edPriv.size == 32 && dhPub.size == 32 && dhPriv.size == 32) {
                "Key material must be 32 bytes each"
            }
            val derivedEdPub = Ed25519Keys.publicKeyFromPrivate(edPriv)
            require(derivedEdPub.contentEquals(edPub)) { "Supplied edPub does not match derived public key" }
            val derivedDhPub = X25519Keys.publicKeyFromPrivate(dhPriv)
            require(derivedDhPub.contentEquals(dhPub)) { "Supplied dhPub does not match derived public key" }
            return Identity(
                bindingGeneration = 0L,
                identityPub = edPub,
                identityPriv = edPriv,
                staticDhPub = dhPub,
                staticDhPriv = dhPriv,
                nodeId = nodeIdOf(edPub),
            )
        }

        fun nodeIdOf(identityPub: ByteArray): ByteArray {
            require(identityPub.size == 32) { "identityPub must be 32 bytes" }
            val d = Blake2sDigest(null, 16, null, null)
            d.update(identityPub, 0, identityPub.size)
            val out = ByteArray(16)
            d.doFinal(out, 0)
            return out
        }
    }
}
