package io.godstone.mesh.wire.v2

/**
 * Structural validation of a decoded GMP/2.1 SOS frame.
 *
 * The wire codec (`FrameV2.decode`) validates only the 32-byte header — magic,
 * version, type, ttl/hop range, CRC, declared length — and returns a parsed
 * frame for ANY well-formed header, including a well-formed SOS whose payload
 * is not a valid distress call. A distress broadcast is a stricter shape than
 * a parseable frame: per `wire/wire_v2.yaml` `sos_requirements`, the payload
 * MUST begin with the `SOS1` magic and carry a 64-byte Ed25519 signature slot,
 * and the flags MUST set `ACK_REQ | RELAY_OK`. This validator enforces those
 * STRUCTURAL requirements so a parse error or a non-distress frame can never be
 * promoted to a distress call — a parse failure must not be able to fabricate a
 * SOS (ADR-001 §6; `wire/golden_vectors.json` `reject_sos_*`).
 *
 * SCOPE — patch 15 (frame-validation-and-vectors): this is the **structural**
 * SOS gate only. The CRYPTOGRAPHIC check — that the 64-byte signature slot
 * verifies against the sender's Ed25519 public key over
 * `msg_id ‖ "SOS1" ‖ payload` — is a runtime concern that needs the sender
 * identity and the sealed-sender open path; it lands with the GMP/2.1
 * router/MeshNode realization (patch 17/19). The golden SOS vector uses a
 * 64-zero-byte signature placeholder, which is structurally present but would
 * not verify against any real key, confirming the split: structure here,
 * cryptography there.
 *
 * This validator does NOT touch the live GMP/1 runtime (`Router`/`MeshNode`
 * stay on `Frame`); it is additive frame-validation code consumed by the
 * golden-vector test and, later, by the GMP/2.1 router.
 */
object SosFrameValidator {
    /** SOS payload magic (`wire_v2.yaml`: `sos_requirements.payload_magic`). */
    val PAYLOAD_MAGIC: ByteArray =
        byteArrayOf('S'.code.toByte(), 'O'.code.toByte(), 'S'.code.toByte(), '1'.code.toByte())

    /** Ed25519 signature slot length (`sos_requirements`: 64-byte signature). */
    const val SIGNATURE_BYTES = 64

    /** Minimum SOS payload length: 4-byte magic + 64-byte signature slot. */
    val MIN_PAYLOAD: Int = PAYLOAD_MAGIC.size + SIGNATURE_BYTES

    /** Required SOS flags (`sos_requirements.required_flags`). */
    const val REQUIRED_FLAGS: Int = FrameV2.ACK_REQ or FrameV2.RELAY_OK

    /** Structural verdict for a decoded frame presented as a SOS. */
    enum class Verdict {
        OK,
        WRONG_TYPE,
        MISSING_REQUIRED_FLAGS,
        PAYLOAD_TOO_SHORT,
        MISSING_MAGIC,
    }

    /**
     * Returns the structural verdict for [frame]. A non-SOS frame is [WRONG_TYPE]
     * regardless of payload. Order: type → flags → length → magic, so the most
     * fundamental structural defect is reported first and a too-short payload
     * is never dereferenced past its end.
     */
    fun validate(frame: FrameV2): Verdict {
        if (frame.type != TypeV2.SOS) return Verdict.WRONG_TYPE
        if ((frame.flags and REQUIRED_FLAGS) != REQUIRED_FLAGS) return Verdict.MISSING_REQUIRED_FLAGS
        if (frame.payload.size < MIN_PAYLOAD) return Verdict.PAYLOAD_TOO_SHORT
        for (i in PAYLOAD_MAGIC.indices) {
            if (frame.payload[i] != PAYLOAD_MAGIC[i]) return Verdict.MISSING_MAGIC
        }
        return Verdict.OK
    }
}