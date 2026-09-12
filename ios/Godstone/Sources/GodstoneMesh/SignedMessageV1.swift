import Foundation
import CryptoKit
import GodstoneCore

/// T35: SignedMessageV1 exactly as section 15 -- the authorship binding inside the
/// sealed envelope. iOS twin of `wire/v2/SignedMessageV1.kt`. The outer frame, the
/// 29-byte sealed prefix, the MessageId formula, the PoW/priority policy and every
/// golden vector are read-only authorities: nothing here rewrites them. Unknown
/// versions fail closed; there is no legacy plaintext fallback.

/// Programmer-error rejection on the authoring side (the receiver path never throws).
public struct SignedMessageAuthorError: Error { public let reason: String; public init(reason: String) { self.reason = reason } }

/// Creation-time quality per section 15: 0 unknown, 1 user-confirmed, 2 authenticated source.
public enum TimeQuality: Int, Equatable, Sendable {
    case unknown = 0
    case userConfirmed = 1
    case authenticatedSource = 2
    public static func fromCode(_ code: Int) -> TimeQuality? { TimeQuality(rawValue: code) }
}

/// The authenticated application message. Only ever produced by a `.verified` result.
public struct VerifiedApplicationMessage {
    public let senderNodeId: Data          // 16 == Blake2s-128(senderIdentityPub)
    public let senderIdentityPub: Data     // 32 Ed25519 public key
    public let recipientNodeId: Data       // 16 == the intended local recipient (checked by the verifier)
    public let messageNonce: Data          // 16 sealed_inner prefix field, bound into the signature
    public let createdAtEpochSeconds: Int64
    public let timeQuality: TimeQuality
    public let priority: Priority          // canonical frozen code byte, bound into the signature
    public let bodyUtf8: Data              // <= 400 bytes, well-formed UTF-8 (verified)
    public let signedPlaintext: Data       // unsigned || signature64 -- msgID derives over these bytes

    /// msgID = the FROZEN MessageId.derive over the signed plaintext; no circular inclusion.
    public var msgId: Data {
        SignedMessageV1.messageId(senderNodeId: senderNodeId, createdAtEpochSeconds: createdAtEpochSeconds,
                                  messageNonce: messageNonce, signedPlaintext: signedPlaintext)
    }
}

/// Typed verification failure -- the receiver loop never sees an exception from this path.
public enum SenderVerificationResult {
    case verified(VerifiedApplicationMessage)
    case invalid(reason: String)
    public var isValid: Bool { if case .verified = self { return true }; return false }
}

///
/// SignedMessageV1 (section 15), the application payload inside the EXISTING 29-byte
/// sealed prefix and sealed-sender layer:
///
///     unsigned         = version1(0x01) || senderIdentityPub32 || recipientNodeId16
///                     || timeQuality1 || bodyLength_u16_be || bodyUtf8[bodyLength]
///     signature        = Ed25519.sign(senderIdentityPriv,
///                        ASCII("GMP2-SIGNED-MESSAGE-V1")
///                     || senderNodeId16 || recipientNodeId16
///                     || messageNonce16 || createdAt_u32_le || priorityCode1 || unsigned)
///     signedPlaintext  = unsigned || signature64
///     sealed_inner     = messageNonce16 || powNonce8 || createdAt_u32_le
///                     || priorityCode1 || signedPlaintext
///     msgID            = MessageId.derive(senderNodeId, createdAt, messageNonce, signedPlaintext)
///
/// The signature EXCLUDES the PoW nonce (no circular search dependence); the outer
/// MessageId formula is unchanged; cryptographic possession identifies a key, not a
/// person's name or emergency-service authority; no automatic human-verification claim.
public enum SignedMessageV1 {
    public static let version: UInt8 = 0x01
    public static let pubLen = 32
    public static let sigLen = 64
    public static let nodeLen = 16
    public static let nonceLen = 16
    public static let bodyMax = 400
    public static let domainText = "GMP2-SIGNED-MESSAGE-V1"
    public static var domainBytes: Data { Data(domainText.utf8) }

    // ---- authoring ----------------------------------------------------------------------

    /// unsigned = version1 || pub32 || recipient16 || timeQuality1 || bodyLength_u16_be || body
    public static func buildUnsigned(senderIdentityPub: Data, recipientNodeId: Data,
                                     timeQuality: TimeQuality, bodyUtf8: Data) throws -> Data {
        guard senderIdentityPub.count == pubLen else { throw SignedMessageAuthorError(reason: "senderIdentityPub must be 32 bytes") }
        guard recipientNodeId.count == nodeLen else { throw SignedMessageAuthorError(reason: "recipientNodeId must be 16 bytes") }
        guard bodyUtf8.count <= bodyMax else { throw SignedMessageAuthorError(reason: "body exceeds the 400-byte documented budget") }
        guard isWellFormedUtf8([UInt8](bodyUtf8)) else { throw SignedMessageAuthorError(reason: "body must be well-formed UTF-8") }
        var out = Data()
        out.append(version)
        out.append(senderIdentityPub)
        out.append(recipientNodeId)
        out.append(UInt8(timeQuality.rawValue))
        out.append(UInt8((bodyUtf8.count >> 8) & 0xFF))
        out.append(UInt8(bodyUtf8.count & 0xFF))
        out.append(bodyUtf8)
        return out
    }

    /// The signature preimage: DOMAIN || senderNodeId16 || recipientNodeId16 || messageNonce16
    /// || createdAt_u32_le || priorityCode1 || unsigned. The PoW nonce is deliberately absent.
    public static func signaturePreimage(senderNodeId: Data, recipientNodeId: Data, messageNonce: Data,
                                         createdAtEpochSeconds: Int64, priorityCode: Int, unsigned: Data) throws -> Data {
        guard senderNodeId.count == nodeLen else { throw SignedMessageAuthorError(reason: "senderNodeId must be 16 bytes") }
        guard recipientNodeId.count == nodeLen else { throw SignedMessageAuthorError(reason: "recipientNodeId must be 16 bytes") }
        guard messageNonce.count == nonceLen else { throw SignedMessageAuthorError(reason: "messageNonce must be 16 bytes") }
        guard (0...4).contains(priorityCode) else { throw SignedMessageAuthorError(reason: "priorityCode must be a canonical frozen Priority code") }
        var out = Data()
        out.append(domainBytes)
        out.append(senderNodeId)
        out.append(recipientNodeId)
        out.append(messageNonce)
        out.append(MessageId.uint32Le(createdAtEpochSeconds))
        out.append(UInt8(priorityCode & 0xFF))
        out.append(unsigned)
        return out
    }

    ///
    /// Author a signed plaintext (the bytes placed after the 29-byte sealed prefix).
    /// The lab profile enables DIRECT authoring only; SOS keeps its separate signed
    /// format and GROUP/BROADCAST need a separately accepted design. Unknown time binds
    /// createdAt 0 with TimeQuality.unknown -- the two fields stand and fall together.
    public static func author(senderIdentityPriv: Data, senderIdentityPub: Data, senderNodeId: Data,
                              recipientNodeId: Data, messageNonce: Data, createdAtEpochSeconds: Int64,
                              priority: Priority, timeQuality: TimeQuality, bodyUtf8: Data) throws -> Data {
        guard priority == .direct else { throw SignedMessageAuthorError(reason: "the lab profile enables DIRECT authoring only") }
        guard (createdAtEpochSeconds == 0) == (timeQuality == .unknown) else {
            throw SignedMessageAuthorError(reason: "unknown time binds createdAt 0 with timeQuality UNKNOWN; the two fields stand and fall together")
        }
        let unsigned = try buildUnsigned(senderIdentityPub: senderIdentityPub, recipientNodeId: recipientNodeId,
                                         timeQuality: timeQuality, bodyUtf8: bodyUtf8)
        let preimage = try signaturePreimage(senderNodeId: senderNodeId, recipientNodeId: recipientNodeId,
                                             messageNonce: messageNonce, createdAtEpochSeconds: createdAtEpochSeconds,
                                             priorityCode: priority.rawValue, unsigned: unsigned)
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: senderIdentityPriv)
        let signature = try key.signature(for: preimage)
        guard signature.count == sigLen else { throw SignedMessageAuthorError(reason: "Ed25519 must produce a 64-byte signature") }
        var out = unsigned
        out.append(signature)
        return out
    }

    // ---- receiving ------------------------------------------------------------------------

    ///
    /// Verify a signed plaintext against the FROZEN binding laws. Returns a typed result;
    /// never throws out of the receiver loop. Rejects BEFORE any inbox/ACK admission:
    /// exact length, version, well-formed UTF-8, the time-quality binding, the canonical
    /// priority, the sender-id/key binding (senderNodeId == BLAKE2s128(pub)), the intended
    /// local recipient equality, and finally the Ed25519 signature over the domain preimage.
    public static func verify(signedPlaintext: Data, senderNodeId: Data, recipientLocalNodeId: Data,
                              messageNonce: Data, createdAtEpochSeconds: Int64,
                              priorityCode: Int) -> SenderVerificationResult {
        guard senderNodeId.count == nodeLen else { return .invalid(reason: "senderNodeId must be 16 bytes") }
        guard recipientLocalNodeId.count == nodeLen else { return .invalid(reason: "recipient local id must be 16 bytes") }
        guard messageNonce.count == nonceLen else { return .invalid(reason: "messageNonce must be 16 bytes") }
        guard (0...4).contains(priorityCode), let priority = Priority.fromCode(priorityCode) else {
            return .invalid(reason: "priorityCode is not a canonical frozen Priority code")
        }
        let b = [UInt8](signedPlaintext)
        let fixed = 1 + pubLen + nodeLen + 1 + 2 + sigLen
        if b.count < fixed { return .invalid(reason: "signed plaintext shorter than the fixed layout") }
        if b[0] != version { return .invalid(reason: "unknown version; there is no legacy plaintext fallback") }
        let senderIdentityPub = Data(b[1 ..< 1 + pubLen])
        let embeddedRecipient = Data(b[(1 + pubLen) ..< (1 + pubLen + nodeLen)])
        let tqCode = Int(b[1 + pubLen + nodeLen])
        guard let timeQuality = TimeQuality.fromCode(tqCode) else { return .invalid(reason: "timeQuality is not a closed enum code") }
        let bodyLenPos = 1 + pubLen + nodeLen + 1
        let bodyLength = (Int(b[bodyLenPos]) << 8) | Int(b[bodyLenPos + 1])
        if bodyLength > bodyMax { return .invalid(reason: "bodyLength exceeds the documented 400-byte budget") }
        let expectedTotal = 1 + pubLen + nodeLen + 1 + 2 + bodyLength + sigLen
        if b.count != expectedTotal { return .invalid(reason: "bodyLength does not match the actual tail; the frame is not exact") }
        let body = Data(b[(bodyLenPos + 2) ..< (bodyLenPos + 2 + bodyLength)])
        let signature = Data(b[(bodyLenPos + 2 + bodyLength) ..< (bodyLenPos + 2 + bodyLength + sigLen)])
        if !isWellFormedUtf8([UInt8](body)) { return .invalid(reason: "body is not well-formed UTF-8") }
        if (createdAtEpochSeconds == 0) != (timeQuality == .unknown) {
            return .invalid(reason: "createdAt and timeQuality are not bound (unknown time uses 0/UNKNOWN together)")
        }
        if nodeIdOf(senderIdentityPub) != senderNodeId { return .invalid(reason: "senderNodeId is not BLAKE2s128(senderIdentityPub)") }
        if embeddedRecipient != recipientLocalNodeId {
            return .invalid(reason: "embedded recipientNodeId differs from the intended local recipient")
        }
        let unsigned = Data(b[0 ..< (bodyLenPos + 2 + bodyLength)])
        guard let preimage = try? signaturePreimage(senderNodeId: senderNodeId, recipientNodeId: embeddedRecipient,
                                                    messageNonce: messageNonce, createdAtEpochSeconds: createdAtEpochSeconds,
                                                    priorityCode: priorityCode, unsigned: unsigned) else {
            return .invalid(reason: "preimage could not be formed")
        }
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: senderIdentityPub) else {
            return .invalid(reason: "public key is not acceptable")
        }
        if !key.isValidSignature(signature, for: preimage) { return .invalid(reason: "signature does not verify over the domain preimage") }
        let message = VerifiedApplicationMessage(
            senderNodeId: senderNodeId, senderIdentityPub: senderIdentityPub, recipientNodeId: embeddedRecipient,
            messageNonce: messageNonce, createdAtEpochSeconds: createdAtEpochSeconds, timeQuality: timeQuality,
            priority: priority, bodyUtf8: body, signedPlaintext: signedPlaintext)
        return .verified(message)
    }

    /// The frozen binding copied VERBATIM in formula: node_id = BLAKE2s-128(identityPub).
    public static func nodeIdOf(_ identityPub: Data) -> Data {
        precondition(identityPub.count == pubLen, "identityPub must be 32 bytes")
        return Blake2s.hash(identityPub, digestLength: 16)
    }

    /// msgID: the FROZEN MessageId.derive over the signed plaintext (no circular inclusion).
    public static func messageId(senderNodeId: Data, createdAtEpochSeconds: Int64, messageNonce: Data,
                                 signedPlaintext: Data) -> Data {
        MessageId.derive(senderNodeId: senderNodeId, createdAtEpochSeconds: createdAtEpochSeconds,
                         messageNonce: messageNonce, plaintext: signedPlaintext)
    }

    // ---- sealed DH input guard -------------------------------------------------------------

    ///
    /// Reject policy for X25519 public inputs before any agreement runs: the all-zero
    /// encoding is the identity (low-order) element; u >= p (2^255 - 19) is a
    /// non-canonical field encoding; the sign/masking bit must be clear in a canonical
    /// u encoding. None of these seals a real shared secret; accepting one is a hostile
    /// downgrade of the sealed layer, so they are refused fail-closed.
    public static func acceptableSealedDhPublicKey(_ pub: Data) -> Bool {
        guard pub.count == pubLen else { return false }
        let b = [UInt8](pub)
        if b.allSatisfy({ $0 == 0 }) { return false }                     // identity element: low order, refuse
        if b[31] & 0x80 != 0 { return false }                             // sign/masking bit must be clear
        if b[31] == 0x7F {
            for j in stride(from: 30, through: 1, by: -1) {               // compare down against p's octets
                if b[j] != 0xFF { return true }                            // a smaller byte at a higher position drops u below p
            }
            if b[0] >= 0xED { return false }                               // u >= p == ED FF.. FF 7F: non-canonical, refuse
        }
        return true
    }

    // ---- UTF-8 validation --------------------------------------------------------------------

    /// Strict well-formedness: no surrogates, no overlongs, no truncated sequences, cap at U+10FFFF.
    public static func isWellFormedUtf8(_ bytes: [UInt8]) -> Bool {
        var i = 0
        while i < bytes.count {
            let b0 = bytes[i]
            let len: Int
            switch b0 {
            case 0x00...0x7F: len = 1
            case 0xC2...0xDF: len = 2                                     // overlong 2-byte (C0/C1) excluded by range
            case 0xE0...0xEF: len = 3
            case 0xF0...0xF4: len = 4                                     // above U+10FFFF excluded (F5.. rejected)
            default: return false                                          // lone continuations, C0/C1, F5+, 0xF8+
            }
            if i + len > bytes.count { return false }
            for k in 1 ..< len {
                let bk = bytes[i + k]
                if !(bk >= 0x80 && bk <= 0xBF) { return false }
            }
            if len == 3 {
                let b1 = bytes[i + 1]
                if b0 == 0xE0 && b1 < 0xA0 { return false }                // overlong 3-byte
                if b0 == 0xED && b1 >= 0xA0 && b1 <= 0xBF { return false } // surrogates D800..DFFF excluded
            }
            if len == 4 {
                let b1 = bytes[i + 1]
                if b0 == 0xF0 && b1 < 0x90 { return false }                // overlong 4-byte
                if b0 == 0xF4 && b1 > 0x8F { return false }                 // above U+10FFFF
            }
            i += len
        }
        return true
    }
}
