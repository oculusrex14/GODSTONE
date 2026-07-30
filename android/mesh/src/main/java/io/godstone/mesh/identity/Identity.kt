package io.godstone.mesh.identity

import android.content.Context
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import org.bouncycastle.crypto.digests.Blake2sDigest
import java.security.SecureRandom

/**
 * Long-term node identity. Private keys live in EncryptedSharedPreferences backed
 * by a Keystore master key, so device seizure does not immediately yield the
 * identity or the message history (threat A6).
 *
 * node_id = BLAKE2s-128(identity_pub), 16 bytes.
 */
class Identity private constructor(
    val identityPub: ByteArray,      // Ed25519, 32 bytes
    private val identityPriv: ByteArray,
    val staticDhPub: ByteArray,      // X25519, 32 bytes
    val staticDhPriv: ByteArray,
    val nodeId: ByteArray            // 16 bytes
) {

    /** First 4 bytes of node_id, broadcast in the BLE advertisement. */
    val nodeHint: ByteArray get() = nodeId.copyOf(4)

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
                acc = (acc shl 8) or (nodeId[idx % nodeId.size].toLong() and 0xFF)
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

    companion object {
        private const val PREFS = "godstone_identity"
        private const val K_ID_PUB = "id_pub"
        private const val K_ID_PRIV = "id_priv"
        private const val K_DH_PUB = "dh_pub"
        private const val K_DH_PRIV = "dh_priv"

        fun loadOrCreate(ctx: Context): Identity {
            val master = MasterKey.Builder(ctx)
                .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                .build()

            val prefs = EncryptedSharedPreferences.create(
                ctx,
                PREFS,
                master,
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
            )

            val existingPub = prefs.getString(K_ID_PUB, null)
            if (existingPub != null) {
                val idPub = decode(existingPub)
                return Identity(
                    identityPub = idPub,
                    identityPriv = decode(prefs.getString(K_ID_PRIV, null)!!),
                    staticDhPub = decode(prefs.getString(K_DH_PUB, null)!!),
                    staticDhPriv = decode(prefs.getString(K_DH_PRIV, null)!!),
                    nodeId = nodeIdOf(idPub)
                )
            }

            val rng = SecureRandom()
            val ed = Ed25519Keys.generate(rng)
            val dh = X25519Keys.generate(rng)

            prefs.edit()
                .putString(K_ID_PUB, encode(ed.pub))
                .putString(K_ID_PRIV, encode(ed.priv))
                .putString(K_DH_PUB, encode(dh.pub))
                .putString(K_DH_PRIV, encode(dh.priv))
                .apply()

            return Identity(ed.pub, ed.priv, dh.pub, dh.priv, nodeIdOf(ed.pub))
        }

        /**
         * Panic wipe. Destroys identity and all derived material so that prior
         * traffic cannot be linked to the regenerated node.
         */
        fun panicWipe(ctx: Context) {
            ctx.deleteSharedPreferences(PREFS)
        }

        fun nodeIdOf(identityPub: ByteArray): ByteArray {
            val d = Blake2sDigest(null, 16, null, null)
            d.update(identityPub, 0, identityPub.size)
            val out = ByteArray(16)
            d.doFinal(out, 0)
            return out
        }

        private fun encode(b: ByteArray) =
            android.util.Base64.encodeToString(b, android.util.Base64.NO_WRAP)

        private fun decode(s: String) =
            android.util.Base64.decode(s, android.util.Base64.NO_WRAP)
    }
}
