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
// canonical preimage signed = ACK_MAGIC("GMP2-ACK", 8) || msgId(16) || recipientNodeId(16) = 40 bytes

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
    /// GS-ACK-002: `ttl` defaults to the FROZEN builder profile (4) and that default is
    /// deliberately UNCHANGED -- the protocol authority owns it. PRODUCTION callers must
    /// pass the ACK profile's initial TTL explicitly (`ackInitialTtl`, the same constant the
    /// immediate road uses), so that WHENCE a reply is generated never changes what it
    /// carries. Relying on this default on a production road is the defect this note exists
    /// to prevent.
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

    /// GS-RUNTIME-001 step 2: **THE PRODUCTION ROAD -- THE SAME FRAME, FROM AN ALREADY-COMPUTED SIGNATURE.**
    /// The seed-taking form above can only be satisfied by a signer willing to RELEASE ITS PRIVATE SEED, which
    /// a production identity must never do (it keepeth its key private and offereth `sign(message:)`). This
    /// overload carrieth the identical frame -- the payload is `signature || recipientNodeId`, the same
    /// preimage is signed, the same metadata is frozen -- so a signer that SIGNETH INTERNALLY can produce it.
    public static func build(
        msgId: Data,
        signature: Data,
        recipientNodeId: Data,
        routingTag: Data,
        ttl: UInt8 = 4
    ) throws -> FrameV2 {
        precondition(msgId.count == 16, "msgId must be 16 bytes")
        precondition(signature.count == 64, "an Ed25519 signature is 64 bytes")
        precondition(recipientNodeId.count == 16, "recipientNodeId must be 16 bytes")
        precondition(routingTag.count == 4, "routingTag must be 4 bytes")
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
/// Stage 4C.1 / C6.1: `expectedRecipientNodeId` is NON-optional and always comes
/// from durable outbound state (the delivery record bound at enqueue time),
/// INDEPENDENT of the ACK. The ACK is accepted only if its payload names THAT
/// recipient and the signature verifies under the key bound to THAT recipient.
/// The unbound fallback (`expectedRecipientNodeId ?? ackRecipientNodeId`) is
/// REMOVED -- a recipient identity may never become trusted merely because the
/// ACK packet names it. This binds the ACK to the intended recipient recorded at
/// send time, so an ACK from a valid-but-unintended recipient cannot ack a
/// message not addressed to them. The authenticator is only ever invoked for an
/// AckMode.singleRecipient record; AckMode.none records never reach it
/// (`DeliveryTracker.acknowledge` returns `.notAckEligible` first). Mirrors
/// `Ed25519AckAuthenticator.verify` on Android.
public final class Ed25519AckAuthenticator: AckAuthenticator {
    private let resolver: RecipientKeyResolver

    public init(resolver: RecipientKeyResolver) {
        self.resolver = resolver
    }

    public func verify(originalMsgId: Data, expectedRecipientNodeId: Data, ackFrame: FrameV2) -> Bool {
        // THE STRUCTURAL GUARDS RUN FIRST, AND WITHOUT ANY KEY LOOKUP (a pinned law of this repository:
        // a wrong expected recipient or a wrong msg id must query the lookup source ZERO times).
        guard let signature = acceptableSignature(originalMsgId: originalMsgId,
                                                 expectedRecipientNodeId: expectedRecipientNodeId,
                                                 ackFrame: ackFrame) else { return false }
        // 5. resolve the public key bound to the EXPECTED recipient node id
        guard let pub = resolver.publicSigningKey(forNodeId: expectedRecipientNodeId),
              pub.count == 32 else { return false }
        return verifySignature(signature, originalMsgId: originalMsgId,
                               expectedRecipientNodeId: expectedRecipientNodeId, pub: pub)
    }

    /// GS-ACK-001 (the audit's ordered step 4): the CAPTURED key is the one that verifies.
    ///
    /// (a) The resolver must still name that key for this recipient -- a binding that DRIFTED between the
    /// caller's gate and this verification is refused outright, fail-closed and never silently upgraded.
    /// (b) The signature is then checked under the CAPTURED key, so the key the caller validated is the key
    /// this verifier used, whatever the resolver answers now. One law with the Android isle.
    public func verifyWithCapturedKey(originalMsgId: Data, expectedRecipientNodeId: Data,
                                      capturedKey: Data, ackFrame: FrameV2) -> Bool {
        guard let signature = acceptableSignature(originalMsgId: originalMsgId,
                                                 expectedRecipientNodeId: expectedRecipientNodeId,
                                                 ackFrame: ackFrame) else { return false }
        guard capturedKey.count == 32 else { return false }
        guard let current = resolver.publicSigningKey(forNodeId: expectedRecipientNodeId) else {
            return false
        }
        guard current == capturedKey else { return false }
        return verifySignature(signature, originalMsgId: originalMsgId,
                               expectedRecipientNodeId: expectedRecipientNodeId, pub: capturedKey)
    }

    /// The structural guards that must decide a frame WITHOUT any key lookup, in their original order.
    private func acceptableSignature(originalMsgId: Data, expectedRecipientNodeId: Data,
                                     ackFrame: FrameV2) -> Data? {
        // 1. type must be ack
        guard ackFrame.type == .ack else { return nil }
        // 2. the ACK must name the EXACT message id being acknowledged
        guard ackFrame.msgId == originalMsgId else { return nil }
        // 3. payload must be signature(64) + recipientNodeId(16)
        let payload = ackFrame.payload
        guard payload.count == 80 else { return nil }
        // 4. C6.1: the ACK's claimed recipient MUST equal the durable expected
        //    recipient (independent of the ACK). No unbound fallback: a stranger
        //    naming themselves in the ACK cannot become the trusted recipient.
        guard Data(payload.suffix(16)) == expectedRecipientNodeId else { return nil }
        return Data(payload.prefix(64))
    }

    /// The one signature check, under the key the CALLER decided upon. The key is NEVER re-resolved here:
    /// that divergence between the validated key and the used key is exactly the hole step 4 closes.
    private func verifySignature(_ signature: Data, originalMsgId: Data,
                                 expectedRecipientNodeId: Data, pub: Data) -> Bool {
        guard pub.count == 32 else { return false }
        // 6. verify the signature over the canonical preimage for the EXPECTED
        //    recipient (the one the recipient themselves signed, since for a
        //    legitimate ACK their own node id == the expected recipient).
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: pub) else { return false }
        return key.isValidSignature(signature, for: AckFrame.preimage(msgId: originalMsgId,
                                                                     recipientNodeId: expectedRecipientNodeId))
    }
}