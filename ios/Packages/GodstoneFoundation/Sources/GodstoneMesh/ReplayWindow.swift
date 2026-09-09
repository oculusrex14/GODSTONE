import Foundation
import CryptoKit

/// T06: bounded replay window for the Swift DATA transport, mirroring the
/// Android `io.godstone.mesh.crypto.ReplayWindow` (preview / authenticate /
/// commit). The window is previewed WITHOUT mutation, the AEAD verification
/// runs against the parsed nonce, and the previewed plan is committed only on
/// success - a forged frame can never poison the window.
public final class ReplayWindow {

    /// Would-be window transition returned by ``preview``; applied by ``commit``.
    public enum Plan: Equatable {
        /// Apply: shift/clear the bitmap, advance highest, mark ``index`` seen.
        case accept(nonce: UInt64, forwardShift: Int?, index: Int)
        /// Replay or outside the window: no plan, no mutation.
        case reject
    }

    public let windowSize: Int
    private var highestReceived: UInt64?
    private var bits: [Bool]

    public init(windowSize: Int = ReplayWindow.defaultWindow) {
        self.windowSize = windowSize
        self.bits = [Bool](repeating: false, count: windowSize)
    }

    public static let defaultWindow = 2048

    /// Highest transport nonce accepted so far; nil before any commit.
    public func highest() -> UInt64? { highestReceived }

    /// Pure: computes the transition `nonce` would cause; mutates nothing.
    /// Large forward jumps are classified by comparison BEFORE any narrowing
    /// (T05 parity).
    public func preview(_ nonce: UInt64) -> Plan {
        if highestReceived == nil || nonce > highestReceived! {
            let forward = highestReceived.map { nonce - $0 } ?? (nonce + 1)
            if forward >= UInt64(windowSize) {
                return .accept(nonce: nonce, forwardShift: nil,
                               index: windowSize - 1)
            }
            return .accept(nonce: nonce, forwardShift: Int(forward), index: -1)
        }
        let backward = highestReceived! - nonce
        if backward >= UInt64(windowSize) { return .reject }
        let index = windowSize - 1 - Int(backward)
        if bits[index] { return .reject }
        return .accept(nonce: nonce, forwardShift: 0, index: index)
    }

    /// Apply a previously previewed plan; the caller owns serialization.
    public func commit(_ plan: Plan) {
        guard case .accept(let nonce, let forwardShift, let index) = plan else {
            return
        }
        if highestReceived == nil || nonce > highestReceived! {
            if let shift = forwardShift, shift >= 0, shift < windowSize {
                for i in 0..<(windowSize - shift) {
                    bits[i] = bits[i + shift]
                }
                for i in (windowSize - shift)..<windowSize {
                    bits[i] = false
                }
            } else {
                bits = [Bool](repeating: false, count: windowSize)
            }
            highestReceived = nonce
            bits[windowSize - 1] = true
        } else {
            bits[index] = true
        }
    }
}

/// T06: unsigned 64-bit transport nonce parser with the policy gate, mirroring
/// the Android parser: the reserved region (unsigned >= 2^63) and out-of-policy
/// nonces (conformant senders rekey at 2^20; ceiling 2^21) are rejected BEFORE
/// any window arithmetic.
public enum UnsignedNonce {

    public enum Result: Equatable {
        case valid(UInt64)
        case rejected(String)
    }

    public static let policyCeiling: UInt64 = 2 * (1 << 20)
    /// The reserved region starts at 2^63.
    public static let reservedFloor: UInt64 = 1 << 63

    /// Parse the first 8 big-endian bytes of `data`.
    public static func parse(_ data: Data, offset: Int = 0) -> Result {
        guard data.count >= offset + 8 else {
            return .rejected("truncated nonce: 8 bytes required")
        }
        var raw: UInt64 = 0
        for byte in data.subdata(in: offset..<(offset + 8)) {
            raw = (raw << 8) | UInt64(byte)
        }
        if raw >= reservedFloor {
            return .rejected("reserved nonce region: unsigned value >= 2^63")
        }
        if raw > policyCeiling {
            return .rejected("out-of-policy nonce \(raw): conformant senders " +
                             "rekey at 2^20 transport messages")
        }
        return .valid(raw)
    }
}

/// T06: the unified DATA transport wire format, shared with Android:
/// `ciphertext = uint64_be(nonce) || ChaChaPoly ciphertext || tag`.
/// The internal ChaChaPoly nonce stays `zero32 || uint64_le(nonce)`.
/// Legacy implicit-counter frames are never auto-detected: the first 8 bytes
/// are always the nonce.
public enum TransportCiphertextV1 {

    public static func encode(nonce: UInt64, ciphertextAndTag: Data) -> Data {
        var be = nonce.bigEndian
        var prefix = Data(count: 8)
        withUnsafeMutableBytes(of: &be) { rawBytes in
            prefix.replaceSubrange(0..<8, with: rawBytes)
        }
        return prefix + ciphertextAndTag
    }

    public static func decode(_ data: Data) -> (nonce: UInt64,
                                                ciphertextAndTag: Data)? {
        guard data.count >= 8 else { return nil }
        let nonce = data.prefix(8).reduce(0 as UInt64) {
            ($0 << 8) | UInt64($1)
        }
        return (nonce, data.dropFirst(8))
    }
}