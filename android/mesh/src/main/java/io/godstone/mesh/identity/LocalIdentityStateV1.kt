package io.godstone.mesh.identity

import android.content.Context
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

/** Canonical version identifier for LocalIdentityStateV1 (0x01). */
const val LOCAL_IDENTITY_STATE_VERSION: Byte = 0x01

/** Authoritative byte length of LocalIdentityStateV1 (69 bytes). */
const val LOCAL_IDENTITY_STATE_LENGTH: Int = 69

/** Byte length of an Ed25519 private seed (32 bytes). */
const val LOCAL_IDENTITY_ED25519_PRIV_LENGTH: Int = 32

/** Byte length of an X25519 private key (32 bytes). */
const val LOCAL_IDENTITY_X25519_PRIV_LENGTH: Int = 32

/**
 * Failure taxonomy for local identity authority and storage operations (ADR-003, Phase C8.1B).
 */
sealed class LocalIdentityException(message: String, cause: Throwable? = null) : IllegalStateException(message, cause) {
    class IdentityStateCorrupt(message: String, cause: Throwable? = null) : LocalIdentityException(message, cause)
    class UnsupportedIdentityStateVersion(val version: Byte) : LocalIdentityException("Unsupported identity state version: $version")
    class IdentityPersistenceFailure(message: String, cause: Throwable? = null) : LocalIdentityException(message, cause)
}

/**
 * Immutable representation of canonical local identity storage state (ADR-003, Phase C8.1B).
 *
 * 69-byte binary layout:
 * - offset 0: version (0x01)
 * - offset 1..4: binding_generation uint32 big-endian
 * - offset 5..36: Ed25519 private seed (32 bytes)
 * - offset 37..68: X25519 static private key (32 bytes)
 */
class LocalIdentityStateV1 private constructor(
    val version: Byte,
    val generation: Long,
    ed25519Seed: ByteArray,
    x25519PrivateKey: ByteArray,
) {
    private val _ed25519Seed: ByteArray = ed25519Seed.copyOf()
    private val _x25519PrivateKey: ByteArray = x25519PrivateKey.copyOf()

    val ed25519Seed: ByteArray get() = _ed25519Seed.copyOf()
    val x25519PrivateKey: ByteArray get() = _x25519PrivateKey.copyOf()

    fun encode(): ByteArray {
        val out = ByteArray(LOCAL_IDENTITY_STATE_LENGTH)
        out[0] = version
        out[1] = ((generation ushr 24) and 0xFF).toByte()
        out[2] = ((generation ushr 16) and 0xFF).toByte()
        out[3] = ((generation ushr 8) and 0xFF).toByte()
        out[4] = (generation and 0xFF).toByte()
        System.arraycopy(_ed25519Seed, 0, out, 5, LOCAL_IDENTITY_ED25519_PRIV_LENGTH)
        System.arraycopy(_x25519PrivateKey, 0, out, 37, LOCAL_IDENTITY_X25519_PRIV_LENGTH)
        return out
    }

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is LocalIdentityStateV1) return false
        return version == other.version &&
               generation == other.generation &&
               _ed25519Seed.contentEquals(other._ed25519Seed) &&
               _x25519PrivateKey.contentEquals(other._x25519PrivateKey)
    }

    override fun hashCode(): Int {
        var result = version.toInt()
        result = 31 * result + generation.hashCode()
        result = 31 * result + _ed25519Seed.contentHashCode()
        result = 31 * result + _x25519PrivateKey.contentHashCode()
        return result
    }

    companion object {
        fun create(
            generation: Long,
            ed25519Seed: ByteArray,
            x25519PrivateKey: ByteArray,
            version: Byte = LOCAL_IDENTITY_STATE_VERSION,
        ): LocalIdentityStateV1 {
            if (version != LOCAL_IDENTITY_STATE_VERSION) {
                throw LocalIdentityException.UnsupportedIdentityStateVersion(version)
            }
            if (generation !in 0L..0xFFFFFFFFL) {
                throw LocalIdentityException.IdentityStateCorrupt("Generation out of range: $generation")
            }
            if (ed25519Seed.size != LOCAL_IDENTITY_ED25519_PRIV_LENGTH) {
                throw LocalIdentityException.IdentityStateCorrupt("Invalid Ed25519 seed size: ${ed25519Seed.size}")
            }
            if (x25519PrivateKey.size != LOCAL_IDENTITY_X25519_PRIV_LENGTH) {
                throw LocalIdentityException.IdentityStateCorrupt("Invalid X25519 private key size: ${x25519PrivateKey.size}")
            }
            return LocalIdentityStateV1(version, generation, ed25519Seed, x25519PrivateKey)
        }

        fun parse(bytes: ByteArray): LocalIdentityStateV1 {
            if (bytes.size != LOCAL_IDENTITY_STATE_LENGTH) {
                throw LocalIdentityException.IdentityStateCorrupt(
                    "Invalid local identity state length: expected $LOCAL_IDENTITY_STATE_LENGTH, got ${bytes.size}"
                )
            }
            val version = bytes[0]
            if (version != LOCAL_IDENTITY_STATE_VERSION) {
                throw LocalIdentityException.UnsupportedIdentityStateVersion(version)
            }
            val gen = ((bytes[1].toLong() and 0xFF) shl 24) or
                      ((bytes[2].toLong() and 0xFF) shl 16) or
                      ((bytes[3].toLong() and 0xFF) shl 8) or
                      (bytes[4].toLong() and 0xFF)
            val edSeed = bytes.copyOfRange(5, 37)
            val xPriv = bytes.copyOfRange(37, 69)
            return LocalIdentityStateV1(version, gen, edSeed, xPriv)
        }
    }
}

/**
 * Raw legacy key material container for migration inspection.
 */
internal data class LegacyIdentityMaterial(
    val idPub: ByteArray,
    val idPriv: ByteArray,
    val dhPub: ByteArray,
    val dhPriv: ByteArray,
)

/**
 * Internal persistence seam around local identity preferences to enable deterministic testing without Robolectric.
 */
internal interface IdentityStorage {
    fun readV1State(): ByteArray?
    fun readLegacyMaterial(): LegacyIdentityMaterial?
    fun hasPartialLegacy(): Boolean
    fun writeV1State(state: ByteArray): Boolean
    fun migrateLegacyToV1(state: ByteArray): Boolean
    fun clear(): Boolean
}

/**
 * Production EncryptedSharedPreferences implementation of IdentityStorage.
 */
internal class EncryptedSharedPreferencesStorage(private val ctx: Context) : IdentityStorage {
    private val master = MasterKey.Builder(ctx)
        .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
        .build()

    private val prefs = EncryptedSharedPreferences.create(
        ctx,
        PREFS,
        master,
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
    )

    override fun readV1State(): ByteArray? {
        val raw = prefs.getString(K_STATE_V1, null) ?: return null
        return try {
            android.util.Base64.decode(raw, android.util.Base64.NO_WRAP)
        } catch (e: Throwable) {
            throw LocalIdentityException.IdentityStateCorrupt("Malformed Base64 in identity_state_v1", e)
        }
    }

    override fun readLegacyMaterial(): LegacyIdentityMaterial? {
        val sIdPub = prefs.getString(K_ID_PUB, null)
        val sIdPriv = prefs.getString(K_ID_PRIV, null)
        val sDhPub = prefs.getString(K_DH_PUB, null)
        val sDhPriv = prefs.getString(K_DH_PRIV, null)

        val presentCount = listOf(sIdPub, sIdPriv, sDhPub, sDhPriv).count { it != null }
        if (presentCount == 0) return null
        if (presentCount != 4) {
            throw LocalIdentityException.IdentityStateCorrupt("Partial legacy identity state: $presentCount of 4 keys present")
        }

        return try {
            LegacyIdentityMaterial(
                idPub = android.util.Base64.decode(sIdPub!!, android.util.Base64.NO_WRAP),
                idPriv = android.util.Base64.decode(sIdPriv!!, android.util.Base64.NO_WRAP),
                dhPub = android.util.Base64.decode(sDhPub!!, android.util.Base64.NO_WRAP),
                dhPriv = android.util.Base64.decode(sDhPriv!!, android.util.Base64.NO_WRAP),
            )
        } catch (e: Throwable) {
            throw LocalIdentityException.IdentityStateCorrupt("Malformed Base64 in legacy keys", e)
        }
    }

    override fun hasPartialLegacy(): Boolean {
        val sIdPub = prefs.getString(K_ID_PUB, null)
        val sIdPriv = prefs.getString(K_ID_PRIV, null)
        val sDhPub = prefs.getString(K_DH_PUB, null)
        val sDhPriv = prefs.getString(K_DH_PRIV, null)
        val count = listOf(sIdPub, sIdPriv, sDhPub, sDhPriv).count { it != null }
        return count in 1..3
    }

    override fun writeV1State(state: ByteArray): Boolean {
        val encoded = android.util.Base64.encodeToString(state, android.util.Base64.NO_WRAP)
        return prefs.edit()
            .putString(K_STATE_V1, encoded)
            .commit()
    }

    override fun migrateLegacyToV1(state: ByteArray): Boolean {
        val encoded = android.util.Base64.encodeToString(state, android.util.Base64.NO_WRAP)
        return prefs.edit()
            .putString(K_STATE_V1, encoded)
            .remove(K_ID_PUB)
            .remove(K_ID_PRIV)
            .remove(K_DH_PUB)
            .remove(K_DH_PRIV)
            .commit()
    }

    override fun clear(): Boolean {
        return prefs.edit().clear().commit()
    }

    companion object {
        const val PREFS = Identity.PREFS
        const val K_STATE_V1 = "identity_state_v1"
        const val K_ID_PUB = "id_pub"
        const val K_ID_PRIV = "id_priv"
        const val K_DH_PUB = "dh_pub"
        const val K_DH_PRIV = "dh_priv"
    }
}
