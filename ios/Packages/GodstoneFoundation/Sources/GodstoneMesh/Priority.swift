import Foundation

// Hand-written runtime helper -- NOT a codegen artifact. The Swift twin of
// android/.../wire/v2/Priority.kt. The wire format carries priority as 3 flag
// bits (FrameV2.Flags.priority_mask); this enum is the typed runtime view the
// store and router use. ci/check_parity.py Invariant A does not regenerate this
// file; it is outside the codegen contract (like BloomDigest.swift).

/// Runtime message priority derived from a FrameV2 header's 3-bit
/// `priority_mask` field (ADR-001 §3.1).
///
/// Values match wire/wire_v2.yaml `priority`: SOS 0 / DIRECT 1 / GROUP 2 /
/// BROADCAST 3 / BULK 4, occupying bits 8..10 of the flags word
/// (`FrameV2.Flags.priority_mask == 0x0700`). Byte-identical to the Android
/// `Priority` twin so the durable store's `priority` column derives the same
/// value on both platforms and the ordering/eviction parity holds.
public enum Priority: Int, Sendable {
    case sos = 0
    case direct = 1
    case group = 2
    case broadcast = 3
    case bulk = 4

    /// GROUP and BROADCAST are wide-distribution traffic the sender must pay
    /// PoW for (ADR-001 §3). SOS and DIRECT are exempt because latency there is
    /// a safety property; BULK is governed by its own transport (ADR-006).
    public var requiresProofOfWork: Bool { self == .group || self == .broadcast }

    /// Derive the priority from a FrameV2 flags word. Fail-safe to DIRECT,
    /// matching Android `Priority.fromFlags`.
    public static func fromFlags(_ flags: UInt16) -> Priority {
        let idx = Int((flags & FrameV2.Flags.priority_mask) >> 8)
        return Priority(rawValue: idx) ?? .direct
    }

    /// Strictly decode priority from FrameV2 flags. Fails closed (nil) on unknown codes
    /// (codes 5..7 or unmapped). Used in security validation and abuse gating.
    public static func fromFlagsStrict(_ flags: UInt16) -> Priority? {
        let idx = Int((flags & FrameV2.Flags.priority_mask) >> 8)
        return Priority(rawValue: idx)
    }

    /// Place a priority into its flag-bit position (bits 8..10).
    public static func toFlags(_ priority: Priority) -> UInt16 {
        UInt16(priority.rawValue) << 8
    }

    public static func fromCode(_ code: Int) -> Priority? {
        Priority(rawValue: code)
    }
}