// SYNTHESIZED gap-closure file -- authored to make the project compile; see docs/AUDIT.md.
import Foundation

/// Noise HKDF over BLAKE2s.
///
/// Noise's `HKDF(chaining_key, input_material)` is two HMAC invocations:
///   temp    = HMAC(ck, material)
///   new_ck  = temp
///   k       = HMAC(temp, material || 0x01)
///
/// `HMAC` here is RFC 2104 HMAC built *on top of* BLAKE2s used as an ordinary
/// hash -- it is NOT BLAKE2s's native keyed mode. The block size is BLAKE2s's
/// 64-byte block. This is the same construction the Android side uses (via
/// BouncyCastle's `HMac`/`Blake2sDigest` pair), so both peers derive identical
/// chaining and encryption keys.
public enum Hkdf {

    private static let blockSize = 64

    /// Split `material` under `chainingKey` into (newChainingKey, k).
    public static func split(chainingKey: Data, material: Data) -> (Data, Data) {
        let temp = hmac(key: chainingKey, message: material)

        var one = material
        one.append(0x01)
        let k = hmac(key: temp, message: one)

        return (temp, k)
    }

    /// RFC 2104 HMAC over BLAKE2s. `HMAC(K, m) = H(K ^ opad || H(K ^ ipad || m))`,
    /// with K padded/truncated to the 64-byte block.
    public static func hmac(key: Data, message: Data) -> Data {
        let block = blockSize
        var k = key
        if k.count > block {
            // Keys longer than the block are first hashed, then padded.
            k = Blake2s.hash(k, digestLength: 32)
        }
        if k.count < block {
            k.append(Data(count: block - k.count))
        }

        var ipad = Data(count: block)
        var opad = Data(count: block)
        k.withUnsafeBytes { ptr in
            let bytes = ptr.bindMemory(to: UInt8.self)
            ipad.withUnsafeMutableBytes { ip in
                let ib = ip.bindMemory(to: UInt8.self)
                opad.withUnsafeMutableBytes { op in
                    let ob = op.bindMemory(to: UInt8.self)
                    for i in 0..<block {
                        ib[i] = bytes[i] ^ 0x36
                        ob[i] = bytes[i] ^ 0x5C
                    }
                }
            }
        }

        var inner = ipad
        inner.append(message)
        let innerHash = Blake2s.hash(inner, digestLength: 32)

        var outer = opad
        outer.append(innerHash)
        return Blake2s.hash(outer, digestLength: 32)
    }
}