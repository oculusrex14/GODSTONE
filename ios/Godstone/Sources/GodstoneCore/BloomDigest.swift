// SYNTHESIZED gap-closure file -- authored to make the project compile; see docs/AUDIT.md.
import Foundation

/// 4096-bit Bloom digest of held message ids.
///
/// Mirrors `io.godstone.mesh.router.BloomDigest` (Android): 4096 bits, 4 hashes
/// per id, ~0.9% false-positive rate at 2000 messages. Two peers exchange the
/// digest so each only forwards what the other is missing; a false positive
/// merely skips a message the peer actually lacks, corrected on the next
/// encounter. Acceptable in an epidemic protocol, far cheaper than full id lists.
///
/// The Android build uses `long` message ids; here the router keys on `Data`
/// (the wire `messageId`). Each of the four hashes is the first 8 bytes of
/// `BLAKE2s(id || roundByte)` read big-endian, mod 4096 -- identical to the
/// Android `index(msgId, round)` for ids that fit in 8 bytes.
public enum BloomDigest {

    public static let sizeBits = 4096
    public static let sizeBytes = sizeBits / 8
    public static let hashes = 4

    /// Build a 512-byte digest from a list of message ids.
    public static func build(from ids: [Data]) -> Data {
        var bits = Data(count: sizeBytes)

        for id in ids {
            for round in 0..<hashes {
                var input = id
                input.append(UInt8(round))
                let digest = Blake2s.hash(input, digestLength: 8)
                let value = digest.withUnsafeBytes { ptr -> UInt64 in
                    ptr.load(as: UInt64.self).bigEndian
                }
                // Match Android: (v >>> 1) & Integer.MAX_VALUE, then mod 4096.
                let idx = Int((value >> 1) & UInt64(Int32.max)) % sizeBits
                bits[idx >> 3] |= UInt8(1 << (idx & 7))
            }
        }
        return bits
    }
}