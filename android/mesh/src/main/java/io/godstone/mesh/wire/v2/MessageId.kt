// Hand-written runtime helper -- NOT a codegen artifact.
// ci/check_parity.py Invariant A regenerates the wire codecs only; this file is
// the runtime realisation of ADR-001 §3's msg_id derivation and is outside the
// codegen contract. Patch 21 (cross-platform-conformance) pins the byte-for-byte
// iOS twin.
package io.godstone.mesh.wire.v2

import org.bouncycastle.crypto.digests.Blake2sDigest
import java.nio.ByteBuffer

/**
 * GMP/2.1 message-id derivation (ADR-001 §3).
 *
 *     msg_id = BLAKE2s-128(sender_node_id ‖ created_at_le ‖ payload)   (16 bytes)
 *
 * The sender computes msg_id when it builds a frame and places it in the 16-byte
 * header field. Relays and the recipient use the header msg_id directly for
 * dedup and bloom anti-entropy — they do NOT recompute it (a relay cannot see
 * the sealed sender, and re-derivation is a recipient integrity check, not a
 * relay gate). The recipient may re-derive after unsealing to authenticate the
 * binding between sender, creation time and payload.
 *
 * `created_at` is a uint32 epoch-second count. It is serialised here
 * big-endian to match the rest of the GMP/2.1 wire format (the header is
 * big-endian throughout); the ADR-001 §3 spelling `created_at_le` is read as
 * "the created_at logical element", not a little-endian byte order, and that
 * interpretation is pinned for cross-platform parity in patch 21.
 */
object MessageId {

    /** BLAKE2s-128 over (sender_node_id[16] ‖ created_at_be[4] ‖ payload). */
    fun derive(senderNodeId: ByteArray, createdAtEpochSeconds: Long, payload: ByteArray): ByteArray {
        require(senderNodeId.size == 16) { "sender_node_id must be 16 bytes" }
        val d = Blake2sDigest(null, 16, null, null)
        d.update(senderNodeId, 0, senderNodeId.size)
        d.update(uint32Be(createdAtEpochSeconds), 0, 4)
        d.update(payload, 0, payload.size)
        val out = ByteArray(16)
        d.doFinal(out, 0)
        return out
    }

    /** Big-endian uint32 encoding of an epoch-second count. */
    fun uint32Be(epochSeconds: Long): ByteArray =
        ByteBuffer.allocate(4).putInt(epochSeconds.toInt()).array()
}