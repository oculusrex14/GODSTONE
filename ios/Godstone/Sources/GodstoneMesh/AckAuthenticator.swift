import Foundation
import CryptoKit

// Stage 3 Phase H -- the authenticated-ACK binding model (ADR-005), Swift twin
// of android/.../mesh/delivery/AckAuthenticator.kt.
//
// Minimum stranger-to-stranger authenticity (ADR-005 "decisions still required"):
// the recipient signs the exact message id with their long-term Ed25519
// identity signing key, and the holder verifies the signature against the
// recipient's public key, which is bound to the recipient's node id by the
// Noise_XX handshake / contact registry. The signature binds BOTH the message
// id and the recipient node id, so:
//   * an unsigned ACK is rejected (no signature to verify);
//   * a tampered signature / payload is rejected (verify fails);
//   * an ACK for message X cannot be replayed to ack message Y -- the signed
//     preimage includes the message id, so the signature is wrong for Y;
//   * an ACK claiming a different recipient is rejected -- the preimage includes
//     the recipient node id, and the resolver returns the public key for that
//     node id, under which a signature made by another recipient does not
//     verify.
//
// ACK frame layout (byte-identical cross-platform):
//   type        = TypeV2.ack (0x21)
//   msgId       = the EXACT message id being acknowledged (16 bytes)
//   routingTag  = recipient node hint (4 bytes)
//   payload     = signature(64) || recipientNodeId(16)   = 80 bytes
// canonical preimage signed = ACK_MAGIC("GMP2-ACK", 7) || msgId(16) || recipientNodeId(16) = 39 bytes

/// ASCII domain-separation tag bound into the signed ACK preimage.
public let ackMagic = "GMP2-ACK"

/// Resolves the 32-byte Ed25519 public signing key bound to a recipient node id.
public protocol RecipientKeyResolver: AnyObject {
    func publicSigningKey(forNodeId nodeId: Data) -> Data?
}

/// Production fail-closed `RecipientKeyResolver` (Stage 4C / C3). The M2-link
/// identity binding that would map a peer node id to its long-term Ed25519
/// public signing key (via the Noise_XX handshake / contact registry) is NOT
/// wired yet (ADR-005 OPEN). Until it is, this resolver resolves NO key for ANY
/// node id, so `Ed25519AckAuthenticator` rejects every ACK: no delivery is
/// claimed without a bound recipient key. This is the UNRESOLVED production
/// state -- a real resolver replaces this class when M2-link contact identity
/// is wired, and the fail-closed behaviour flips to real verification at that
/// point (not before). Mirrors `UnresolvedRecipientKeyResolver` on Android.
public final class UnresolvedRecipientKeyResolver: RecipientKeyResolver {
    public init() {}
    public func publicSigningKey(forNodeId nodeId: Data) -> Data? { nil }
}

/// Builds and verifies authenticated ACK frames (see file header for the model).
public enum AckFrame {

    /// Build an authenticated ACK for `msgId`, signed by the recipient.
    public static func build(
        msgId: Data,
        recipientSigningPrivKey: Data,
        recipientNodeId: Data,
        routingTag: Data,
        ttl: UInt8 = 4
    ) throws -> FrameV2 {
        precondition(msgId.count == 16, "msgId must be 16 bytes")
        precondition(recipientNodeId.count == 16, "recipientNodeId must be 16 bytes")
        precondition(routingTag.count == 4, "routingTag must be 4 bytes")
        let priv = try Curve25519.Signing.PrivateKey(rawRepresentation: recipientSigningPrivKey)
        let signature = try priv.signature(for: preimage(msgId: msgId, recipientNodeId: recipientNodeId))
        let payload = signature + recipientNodeId
        return FrameV2(type: .ack,
                       msgId: msgId,
                       routingTag: routingTag,
                       ttl: ttl,
                       hopCount: 0,
                       flags: 0,
                       payload: payload)
    }

    /// The canonical signed preimage for an ACK of `msgId` by `recipientNodeId`.
    public static func preimage(msgId: Data, recipientNodeId: Data) -> Data {
        Data(ackMagic.utf8) + msgId + recipientNodeId
    }
}

/// Verifies an ACK frame using Ed25519 over the canonical preimage, resolving
/// the recipient's public key via `resolver`. Pure + injected -> host-testable.
///
/// Stage 4C / C2: when `expectedRecipientNodeId` is supplied (read from durable
/// outbound state at enqueue time, INDEPENDENT of the ACK), the ACK is accepted
/// only if it names THAT recipient in its payload and the signature verifies
/// under the key bound to that expected recipient. This binds the ACK to the
/// intended recipient recorded at send time, so an ACK from a valid-but-
/// unintended recipient cannot ack a message not addressed to them. A nil
/// `expectedRecipientNodeId` (storeless test tracker, or the legacy unbound
/// path) falls back to binding against the recipient the ACK names -- the
/// Phase H behaviour, preserved so the existing truth-table / negative matrix
/// stays green. Mirrors `Ed25519AckAuthenticator.verify` on Android.
public final class Ed25519AckAuthenticator: AckAuthenticator {
    private let resolver: RecipientKeyResolver

    public init(resolver: RecipientKeyResolver) {
        self.resolver = resolver
    }

    public func verify(originalMsgId: Data, expectedRecipientNodeId: Data?, ackFrame: FrameV2) -> Bool {
        // 1. type must be ack
        guard ackFrame.type == .ack else { return false }
        // 2. the ACK must name the EXACT message id being acknowledged
        guard ackFrame.msgId == originalMsgId else { return false }
        // 3. payload must be signature(64) + recipientNodeId(16)
        let payload = ackFrame.payload
        guard payload.count == 80 else { return false }
        let signature = payload.prefix(64)
        let ackRecipientNodeId = Data(payload.suffix(16))
        // 4. C2: when an expected recipient is bound (from durable outbound
        //    state, independent of the ACK), the ACK's claimed recipient MUST
        //    equal it; the key is resolved for the EXPECTED recipient, so a
        //    signature made by another recipient does not verify. Nil expected
        //    = unbound -> bind against the ACK-claimed recipient (legacy path).
        let boundNodeId = expectedRecipientNodeId ?? ackRecipientNodeId
        if let expected = expectedRecipientNodeId, ackRecipientNodeId != expected { return false }
        // 5. resolve the recipient's public key bound to the (expected | claimed) node id
        guard let pub = resolver.publicSigningKey(forNodeId: boundNodeId), pub.count == 32 else { return false }
        // 6. verify the signature over the canonical preimage for that recipient
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: pub) else { return false }
        return key.isValidSignature(signature, for: AckFrame.preimage(msgId: originalMsgId,
                                                                      recipientNodeId: boundNodeId))
    }
}