import Foundation
import CryptoKit

/// Deterministic RFC 8032 Ed25519 signing engine.
///
/// Apple's CryptoKit `Curve25519.Signing.PrivateKey.signature(for:)` produces randomized (hedged)
/// signatures. While cryptographically valid, randomized nonces prevent exact test vector reproduction.
/// This pure-Swift engine performs canonical RFC 8032 deterministic signing (using SHA512 nonce derivation
/// from the private seed + message), ensuring 100% byte-for-byte cross-platform equivalence with Android
/// BouncyCastle and Python cryptography fixtures.
internal enum Ed25519Signer {

    internal struct BigInt: Equatable {
        internal var words: [UInt32]

        internal init(_ words: [UInt32] = [0]) {
            var w = words
            while w.count > 1 && w.last == 0 {
                w.removeLast()
            }
            self.words = w.isEmpty ? [0] : w
        }

        internal init(bytes: Data) {
            var words = [UInt32]()
            for i in stride(from: 0, to: bytes.count, by: 4) {
                var val: UInt32 = 0
                for b in 0..<4 {
                    if i + b < bytes.count {
                        val |= UInt32(bytes[i + b]) << (b * 8)
                    }
                }
                words.append(val)
            }
            self.init(words)
        }

        internal func toData(count: Int) -> Data {
            var res = Data(count: count)
            for i in 0..<count {
                let wordIdx = i / 4
                let byteIdx = i % 4
                if wordIdx < words.count {
                    res[i] = UInt8((words[wordIdx] >> (byteIdx * 8)) & 0xFF)
                } else {
                    res[i] = 0
                }
            }
            return res
        }

        internal static func < (lhs: BigInt, rhs: BigInt) -> Bool {
            if lhs.words.count != rhs.words.count {
                return lhs.words.count < rhs.words.count
            }
            for i in stride(from: lhs.words.count - 1, through: 0, by: -1) {
                if lhs.words[i] != rhs.words[i] {
                    return lhs.words[i] < rhs.words[i]
                }
            }
            return false
        }

        internal static func <= (lhs: BigInt, rhs: BigInt) -> Bool {
            return !(rhs < lhs)
        }

        internal static func + (lhs: BigInt, rhs: BigInt) -> BigInt {
            var res = [UInt32]()
            let count = max(lhs.words.count, rhs.words.count)
            var carry: UInt64 = 0
            for i in 0..<count {
                let a = i < lhs.words.count ? UInt64(lhs.words[i]) : 0
                let b = i < rhs.words.count ? UInt64(rhs.words[i]) : 0
                let sum = a + b + carry
                res.append(UInt32(sum & 0xFFFFFFFF))
                carry = sum >> 32
            }
            if carry > 0 {
                res.append(UInt32(carry))
            }
            return BigInt(res)
        }

        internal static func - (lhs: BigInt, rhs: BigInt) -> BigInt {
            var res = [UInt32]()
            var borrow: Int64 = 0
            for i in 0..<lhs.words.count {
                let a = Int64(lhs.words[i])
                let b = i < rhs.words.count ? Int64(rhs.words[i]) : 0
                let diff = a - b - borrow
                if diff < 0 {
                    res.append(UInt32(diff + 0x100000000))
                    borrow = 1
                } else {
                    res.append(UInt32(diff))
                    borrow = 0
                }
            }
            return BigInt(res)
        }

        internal static func * (lhs: BigInt, rhs: BigInt) -> BigInt {
            if lhs == BigInt([0]) || rhs == BigInt([0]) { return BigInt([0]) }
            var res = [UInt64](repeating: 0, count: lhs.words.count + rhs.words.count)
            for i in 0..<lhs.words.count {
                var carry: UInt64 = 0
                for j in 0..<rhs.words.count {
                    let cur = res[i + j] + UInt64(lhs.words[i]) * UInt64(rhs.words[j]) + carry
                    res[i + j] = cur & 0xFFFFFFFF
                    carry = cur >> 32
                }
                res[i + rhs.words.count] += carry
            }
            var out = [UInt32]()
            var carry: UInt64 = 0
            for val in res {
                let sum = val + carry
                out.append(UInt32(sum & 0xFFFFFFFF))
                carry = sum >> 32
            }
            while carry > 0 {
                out.append(UInt32(carry & 0xFFFFFFFF))
                carry >>= 32
            }
            return BigInt(out)
        }

        internal func divmod(_ rhs: BigInt) -> (quotient: BigInt, remainder: BigInt) {
            precondition(rhs != BigInt([0]), "Division by zero")
            if self < rhs { return (BigInt([0]), self) }

            var rem = BigInt([0])
            var quoWords = [UInt32](repeating: 0, count: self.words.count)

            for i in stride(from: self.words.count * 32 - 1, through: 0, by: -1) {
                rem = rem.shiftLeft1()
                let bit = (self.words[i / 32] >> (i % 32)) & 1
                if bit == 1 {
                    rem = rem + BigInt([1])
                }
                if rhs <= rem {
                    rem = rem - rhs
                    quoWords[i / 32] |= (1 << (i % 32))
                }
            }
            return (BigInt(quoWords), rem)
        }

        internal func shiftLeft1() -> BigInt {
            var res = [UInt32]()
            var carry: UInt32 = 0
            for w in words {
                let nextCarry = w >> 31
                res.append((w << 1) | carry)
                carry = nextCarry
            }
            if carry > 0 {
                res.append(carry)
            }
            return BigInt(res)
        }

        internal func shiftLeft(_ n: Int) -> BigInt {
            var res = self
            for _ in 0..<n {
                res = res.shiftLeft1()
            }
            return res
        }

        internal static func % (lhs: BigInt, rhs: BigInt) -> BigInt {
            return lhs.divmod(rhs).remainder
        }

        internal func powerMod(_ exp: BigInt, _ m: BigInt) -> BigInt {
            var res = BigInt([1])
            var base = self % m
            var e = exp
            while e != BigInt([0]) {
                if (e.words[0] & 1) == 1 {
                    res = (res * base) % m
                }
                base = (base * base) % m
                let (q, _) = e.divmod(BigInt([2]))
                e = q
            }
            return res
        }
    }

    private static let p = (BigInt([1]).shiftLeft(255)) - BigInt([19]) // 2^255 - 19
    private static let q = BigInt(bytes: Data([
        0xed, 0xd3, 0xf5, 0x5c, 0x1a, 0x63, 0x12, 0x58,
        0xd6, 0x9c, 0xf7, 0xa2, 0xde, 0xf9, 0xde, 0x14,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10
    ]))

    private static let d: BigInt = {
        let num = p - BigInt([121665])
        let den = BigInt([121666]).powerMod(p - BigInt([2]), p)
        return (num * den) % p
    }()

    private static let B: (BigInt, BigInt, BigInt, BigInt) = {
        let By = (BigInt([4]) * BigInt([5]).powerMod(p - BigInt([2]), p)) % p
        let Bx = BigInt(bytes: Data([
            0x1a, 0xd5, 0x25, 0x8f, 0x60, 0x2d, 0x56, 0xc9,
            0xb2, 0xa7, 0x25, 0x95, 0x60, 0xc7, 0x2c, 0x69,
            0x5c, 0xdc, 0xd6, 0xfd, 0x31, 0xe2, 0xa4, 0xc0,
            0xfe, 0x53, 0x6e, 0xcd, 0xd3, 0x36, 0x69, 0x21
        ]))
        return (Bx, By, BigInt([1]), (Bx * By) % p)
    }()

    private static func pointAdd(_ P1: (BigInt, BigInt, BigInt, BigInt), _ P2: (BigInt, BigInt, BigInt, BigInt)) -> (BigInt, BigInt, BigInt, BigInt) {
        let (X1, Y1, Z1, T1) = P1
        let (X2, Y2, Z2, T2) = P2
        let A = (((Y1 + p - X1) % p) * ((Y2 + p - X2) % p)) % p
        let B = (((Y1 + X1) % p) * ((Y2 + X2) % p)) % p
        let C = ((BigInt([2]) * d) % p * ((T1 * T2) % p)) % p
        let D = ((BigInt([2]) * Z1) % p * Z2) % p
        let E = (B + p - A) % p
        let F = (D + p - C) % p
        let G = (D + C) % p
        let H = (B + A) % p
        return ((E * F) % p, (G * H) % p, (F * G) % p, (E * H) % p)
    }

    private static func pointMul(_ scalar: BigInt, _ P: (BigInt, BigInt, BigInt, BigInt)) -> (BigInt, BigInt, BigInt, BigInt) {
        var R = (BigInt([0]), BigInt([1]), BigInt([1]), BigInt([0]))
        var Q = P
        var s = scalar
        while s != BigInt([0]) {
            if (s.words[0] & 1) == 1 {
                R = pointAdd(R, Q)
            }
            Q = pointAdd(Q, Q)
            let (nextS, _) = s.divmod(BigInt([2]))
            s = nextS
        }
        return R
    }

    private static func pointEncode(_ P: (BigInt, BigInt, BigInt, BigInt)) -> Data {
        let (X, Y, Z, _) = P
        let zi = Z.powerMod(p - BigInt([2]), p)
        let x = (X * zi) % p
        let y = (Y * zi) % p
        var b = y.toData(count: 32)
        if (x.words[0] & 1) == 1 {
            b[31] |= 0x80
        }
        return b
    }

    internal static func sign(message: Data, seed: Data) -> Data {
        precondition(seed.count == 32, "Ed25519 seed must be 32 bytes")
        let h = Data(SHA512.hash(data: seed))
        var sBytes = Data(h.prefix(32))
        sBytes[0] &= 248
        sBytes[31] &= 127
        sBytes[31] |= 64
        let s = BigInt(bytes: sBytes)
        let prefix = Data(h.suffix(32))

        let APoint = pointMul(s, B)
        let pub = pointEncode(APoint)

        var rInput = prefix
        rInput.append(message)
        let rHash = Data(SHA512.hash(data: rInput))
        let r = BigInt(bytes: rHash) % q
        let RPoint = pointMul(r, B)
        let RBytes = pointEncode(RPoint)

        var kInput = RBytes
        kInput.append(pub)
        kInput.append(message)
        let kHash = Data(SHA512.hash(data: kInput))
        let k = BigInt(bytes: kHash) % q

        let S = (r + k * s) % q
        var sig = RBytes
        sig.append(S.toData(count: 32))
        return sig
    }
}
