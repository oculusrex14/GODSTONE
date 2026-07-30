// SYNTHESIZED gap-closure file -- authored to make the project compile; see docs/AUDIT.md.
import Foundation

/// Pure-Swift BLAKE2s (RFC 7693).
///
/// Implemented from scratch because iOS does not ship BLAKE2s in CryptoKit and
/// the mesh handshake (`Noise_XX_25519_ChaChaPoly_BLAKE2s`) is bound to it: both
/// peers must hash the protocol name, prologue and transcript with byte-identical
/// output or the chaining key diverges and the handshake never completes.
///
/// This matches the Android side, which uses BouncyCastle's `Blake2sDigest`.
/// The output is deterministic across platforms for any `digestLength` 1...32.
public enum Blake2s {

    /// BLAKE2s IV constants (sqrt of first 8 primes, 2^32 fractional bits).
    private static let iv: [UInt32] = [
        0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A,
        0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19
    ]

    /// Rotation constants for the G function.
    private static let rotations: [Int] = [16, 12, 8, 7]

    /// Sigma permutation: message-word schedule for the 10 BLAKE2s rounds.
    private static let sigma: [[Int]] = [
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
        [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
        [11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4],
        [7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8],
        [9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13],
        [2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9],
        [12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11],
        [13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10],
        [6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5],
        [10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0]
    ]

    private static let blockSize = 64          // BLAKE2s block: 64 bytes
    private static let maxDigestLength = 32    // BLAKE2s: up to 32 bytes

    /// Hash `data` to a digest of `digestLength` bytes (1...32), with no key.
    public static func hash(_ data: Data, digestLength: Int) -> Data {
        precondition(digestLength >= 1 && digestLength <= maxDigestLength,
                     "BLAKE2s digest length must be in 1...32")
        return hash(data, digestLength: digestLength, key: Data())
    }

    /// Convenience: 32-byte digest.
    public static func hash(_ data: Data) -> Data {
        hash(data, digestLength: 32)
    }

    /// Full BLAKE2s with optional key. Key (if any) is padded to the block size
    /// and used as the first message block, per RFC 7693 §2.5.
    public static func hash(_ data: Data, digestLength: Int, key: Data) -> Data {
        precondition(digestLength >= 1 && digestLength <= maxDigestLength)
        precondition(key.count <= blockSize, "BLAKE2s key must be <= 64 bytes")

        // Parameter block, little-endian. Only the fields we use are set; the
        // rest are zero. digest_length | (key_length << 8) | (fanout << 16) |
        // (depth << 24). fanout=1, depth=1 for an unkeyed/standard digest.
        var h = iv
        let keyBytes = key.count
        h[0] ^= UInt32(digestLength)
            | (UInt32(keyBytes) << 8)
            | (UInt32(1) << 16)   // fanout
            | (UInt32(1) << 24)   // depth

        // Prepend the padded key as the first block when keyed.
        var message = Data()
        if keyBytes > 0 {
            message.append(key)
            message.append(Data(count: blockSize - keyBytes))
        }
        message.append(data)

        var offset = 0
        let total = message.count
        var counter: UInt64 = 0

        // Compress every full 64-byte block; the final block (possibly partial)
        // is marked with the last-block flag.
        while offset < total {
            let chunkLen = min(blockSize, total - offset)
            let isLast = offset + chunkLen == total
            counter &+= UInt64(chunkLen)
            let block = message.subdata(in: offset..<(offset + chunkLen))
            let padded = chunkLen < blockSize ? block + Data(count: blockSize - chunkLen) : block
            compress(&h, block: padded, counter: counter, isLast: isLast)
            offset += chunkLen
        }

        // Handle the empty-message edge: the loop above never runs when total == 0.
        if total == 0 {
            compress(&h, block: Data(count: blockSize), counter: 0, isLast: true)
        }

        // Serialise the state little-endian and truncate to the digest length.
        var out = Data(capacity: maxDigestLength)
        for word in h {
            withUnsafeBytes(of: word.littleEndian) { out.append(contentsOf: $0) }
        }
        return out.prefix(digestLength)
    }

    // MARK: - Compression

    private static func compress(_ h: inout [UInt32],
                                 block: Data,
                                 counter: UInt64,
                                 isLast: Bool) {
        var v = [UInt32](repeating: 0, count: 16)
        for i in 0..<8 {
            v[i] = h[i]
            v[i + 8] = iv[i]
        }
        v[12] ^= UInt32(counter & 0xFFFF_FFFF)
        v[13] ^= UInt32((counter >> 32) & 0xFFFF_FFFF)
        if isLast { v[14] = ~v[14] }

        // Message words, little-endian.
        var m = [UInt32](repeating: 0, count: 16)
        block.withUnsafeBytes { ptr in
            let bytes = ptr.bindMemory(to: UInt8.self)
            for i in 0..<16 {
                let base = i * 4
                m[i] = UInt32(bytes[base])
                    | (UInt32(bytes[base + 1]) << 8)
                    | (UInt32(bytes[base + 2]) << 16)
                    | (UInt32(bytes[base + 3]) << 24)
            }
        }

        for round in 0..<10 {
            let s = sigma[round]
            g(&v, 0, 4, 8, 12, m[s[0]], m[s[1]])
            g(&v, 1, 5, 9, 13, m[s[2]], m[s[3]])
            g(&v, 2, 6, 10, 14, m[s[4]], m[s[5]])
            g(&v, 3, 7, 11, 15, m[s[6]], m[s[7]])
            g(&v, 0, 5, 10, 15, m[s[8]], m[s[9]])
            g(&v, 1, 6, 11, 12, m[s[10]], m[s[11]])
            g(&v, 2, 7, 8, 13, m[s[12]], m[s[13]])
            g(&v, 3, 4, 9, 14, m[s[14]], m[s[15]])
        }

        for i in 0..<8 {
            h[i] ^= v[i] ^ v[i + 8]
        }
    }

    @inline(__always)
    private static func g(_ v: inout [UInt32],
                          _ a: Int, _ b: Int, _ c: Int, _ d: Int,
                          _ x: UInt32, _ y: UInt32) {
        v[a] = v[a] &+ v[b] &+ x
        v[d] = rotr(v[d] ^ v[a], rotations[0])
        v[c] = v[c] &+ v[d]
        v[b] = rotr(v[b] ^ v[c], rotations[1])
        v[a] = v[a] &+ v[b] &+ y
        v[d] = rotr(v[d] ^ v[a], rotations[2])
        v[c] = v[c] &+ v[d]
        v[b] = rotr(v[b] ^ v[c], rotations[3])
    }

    @inline(__always)
    private static func rotr(_ value: UInt32, _ count: Int) -> UInt32 {
        (value >> count) | (value << (32 - count))
    }
}