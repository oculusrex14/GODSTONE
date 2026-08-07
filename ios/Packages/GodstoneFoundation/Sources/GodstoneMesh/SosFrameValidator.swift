import Foundation

/// Structural validation of a decoded GMP/2.1 SOS frame.
///
/// The wire codec (`FrameV2.decode`) validates only the 32-byte header — magic,
/// version, type, ttl/hop range, CRC, declared length — and returns a parsed
/// frame for ANY well-formed header, including a well-formed SOS whose payload
/// is not a valid distress call. A distress broadcast is a stricter shape than
/// a parseable frame: per `wire/wire_v2.yaml` `sos_requirements`, the payload
/// MUST begin with the `SOS1` magic and carry a 64-byte Ed25519 signature slot,
/// and the flags MUST set `ack_req | relay_ok`. This validator enforces those
/// STRUCTURAL requirements so a parse error or a non-distress frame can never be
/// promoted to a distress call — a parse failure must not be able to fabricate a
/// SOS (ADR-001 §6; `wire/golden_vectors.json` `reject_sos_*`).
///
/// SCOPE — patch 15 (frame-validation-and-vectors): this is the **structural**
/// SOS gate only. The CRYPTOGRAPHIC check — that the 64-byte signature slot
/// verifies against the sender's Ed25519 public key over
/// `msg_id ‖ "SOS1" ‖ payload` — is a runtime concern that needs the sender
/// identity and the sealed-sender open path; it lands with the GMP/2.1
/// router/MeshNode realization (patch 17/19). The golden SOS vector uses a
/// 64-zero-byte signature placeholder, which is structurally present but would
/// not verify against any real key, confirming the split: structure here,
/// cryptography there.
///
/// This validator does NOT touch the live iOS mesh runtime (`Router`/`MeshNode`
/// stay memory-only on `FrameV2`); it is additive frame-validation code
/// consumed by the golden-vector test and, later, by the GMP/2.1 router.
public enum SosFrameValidator {
    /// SOS payload magic (`wire_v2.yaml`: `sos_requirements.payload_magic`).
    public static let payloadMagic: [UInt8] = [0x53, 0x4F, 0x53, 0x31] // "SOS1"

    /// Ed25519 signature slot length (`sos_requirements`: 64-byte signature).
    public static let signatureBytes = 64

    /// Minimum SOS payload length: 4-byte magic + 64-byte signature slot.
    public static var minPayload: Int { payloadMagic.count + signatureBytes }

    /// Required SOS flags (`sos_requirements.required_flags`).
    public static let requiredFlags: UInt16 = FrameV2.Flags.ack_req | FrameV2.Flags.relay_ok

    /// Structural verdict for a decoded frame presented as a SOS.
    public enum Verdict: Equatable {
        case ok
        case wrongType
        case missingRequiredFlags
        case payloadTooShort
        case missingMagic
    }

    /// Returns the structural verdict for `frame`. A non-SOS frame is
    /// `wrongType` regardless of payload. Order: type → flags → length → magic,
    /// so the most fundamental structural defect is reported first and a
    /// too-short payload is never dereferenced past its end.
    public static func validate(_ frame: FrameV2) -> Verdict {
        guard frame.type == .sos else { return .wrongType }
        guard (frame.flags & requiredFlags) == requiredFlags else { return .missingRequiredFlags }
        guard frame.payload.count >= minPayload else { return .payloadTooShort }
        let prefix = [UInt8](frame.payload.prefix(payloadMagic.count))
        guard prefix == payloadMagic else { return .missingMagic }
        return .ok
    }
}