import Foundation
import CryptoKit
import GodstoneCore

/// Sealed sender (L4). PROTOCOL.md section 6.
///
/// Swift twin of android/.../seal/SealedSender.kt.
///
/// THE CONSTRUCTION:
///     K_seal = Blake2s-256(X25519(ephemeral_priv, recipient_static_pub) || "godstone-seal-v2")
///     inner  = sender_node_id[16] || plaintext
///     sealed = ephemeral_pub[32] || nonce[12] || AES-GCM(K_seal, nonce, inner)
public enum SealedSender {

    public static let ephemeralLen = 32
    public static let tagLen = 16
    public static let nodeIdLen = 16
    public static let routingTagLen = 4

    public struct Opened: Sendable, Equatable {
        public let senderNodeId: Data
        public let plaintext: Data

        public init(senderNodeId: Data, plaintext: Data) {
            self.senderNodeId = senderNodeId
            self.plaintext = plaintext
        }
    }

    /// Routing tag = BLAKE2s-32(recipient_node_id || uint64_be(epoch_day)).
    public static func routingTag(recipientNodeId: Data, epochDay: Int64) -> Data {
        precondition(recipientNodeId.count == nodeIdLen, "recipientNodeId must be 16 bytes")
        var input = Data(capacity: nodeIdLen + 8)
        input.append(recipientNodeId)
        var dayBe = UInt64(bitPattern: epochDay).bigEndian
        withUnsafeBytes(of: &dayBe) { input.append(contentsOf: $0) }
        return Blake2s.hash(input, digestLength: routingTagLen)
    }

    public static func currentEpochDay(
        nowMillis: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) -> Int64 {
        nowMillis / 86_400_000
    }

    /// Seal [plaintext] for [recipientStaticPub].
    public static func seal(
        plaintext: Data,
        senderNodeId: Data,
        recipientStaticPub: Data
    ) throws -> Data {
        precondition(senderNodeId.count == nodeIdLen, "node_id must be 16 bytes")
        precondition(recipientStaticPub.count == 32, "X25519 public key must be 32 bytes")

        let eph = Curve25519.KeyAgreement.PrivateKey()
        let recPub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipientStaticPub)
        let sharedSecret = try eph.sharedSecretFromKeyAgreement(with: recPub)
        let shared = sharedSecret.withUnsafeBytes { Data($0) }
        let kSeal = Blake2s.hash(shared + Data("godstone-seal-v2".utf8), digestLength: 32)

        let inner = senderNodeId + plaintext

        var nonceBytes = [UInt8](repeating: 0, count: 12)
        let status = SecRandomCopyBytes(kSecRandomDefault, 12, &nonceBytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        let nonceData = Data(nonceBytes)
        let nonce = try AES.GCM.Nonce(data: nonceData)

        let sealedBox = try AES.GCM.seal(inner, using: SymmetricKey(data: kSeal), nonce: nonce)
        return eph.publicKey.rawRepresentation + nonceData + sealedBox.ciphertext + sealedBox.tag
    }

    /// Attempt to open a sealed payload. Returns nil on any failure.
    public static func open(
        sealedPayload: Data,
        recipientStaticPriv: Data
    ) -> Opened? {
        let payload = Data(sealedPayload)
        let minLen = ephemeralLen + 12 + tagLen + nodeIdLen
        guard payload.count >= minLen else { return nil }

        let ephPub = Data(payload.prefix(ephemeralLen))
        let nonceData = Data(payload.subdata(in: ephemeralLen..<(ephemeralLen + 12)))
        let ctAndTag = Data(payload.suffix(from: ephemeralLen + 12))
        guard ctAndTag.count >= tagLen + nodeIdLen else { return nil }

        let ct = Data(ctAndTag.dropLast(tagLen))
        let tag = Data(ctAndTag.suffix(tagLen))

        guard let priv = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: recipientStaticPriv),
              let eph = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephPub),
              let sharedSecret = try? priv.sharedSecretFromKeyAgreement(with: eph) else {
            return nil
        }

        let shared = sharedSecret.withUnsafeBytes { Data($0) }
        let kSeal = Blake2s.hash(shared + Data("godstone-seal-v2".utf8), digestLength: 32)

        guard let nonce = try? AES.GCM.Nonce(data: nonceData),
              let sealedBox = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: ct, tag: tag),
              let inner = try? AES.GCM.open(sealedBox, using: SymmetricKey(data: kSeal)),
              inner.count >= nodeIdLen else {
            return nil
        }

        let innerData = Data(inner)
        return Opened(
            senderNodeId: Data(innerData.prefix(nodeIdLen)),
            plaintext: Data(innerData.dropFirst(nodeIdLen))
        )
    }
}
