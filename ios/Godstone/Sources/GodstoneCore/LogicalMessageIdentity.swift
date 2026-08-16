import Foundation

/// Immutable logical message identity (ADR-001 §3.3, C6.7.1).
///
/// Encapsulates the immutable tuple:
///     (createdAtEpochSeconds, messageNonce)
///
/// Rules:
/// - A new logical message authors an identity ONCE via `createNew()`.
/// - Retries re-transmit the exact persisted FrameV2 rather than re-authoring.
/// - `messageNonce` is an immutable 16-byte random token.
/// - `createdAtEpochSeconds` is constrained to uint32 epoch-second range.
public struct LogicalMessageIdentity: Sendable, Equatable, Hashable {

    public let createdAtEpochSeconds: Int64
    public let messageNonce: Data

    public init(createdAtEpochSeconds: Int64, messageNonce: Data) {
        precondition(
            createdAtEpochSeconds >= 0 && createdAtEpochSeconds <= Int64(UInt32.max),
            "createdAtEpochSeconds out of uint32 range"
        )
        precondition(
            messageNonce.count == MessageId.messageNonceBytes,
            "messageNonce must be \(MessageId.messageNonceBytes) bytes, got \(messageNonce.count)"
        )
        self.createdAtEpochSeconds = createdAtEpochSeconds
        self.messageNonce = messageNonce
    }

    /// 4-byte little-endian uint32 serialization (ADR-001 §3.3 created_at_le).
    public func createdAtLe() -> Data {
        MessageId.uint32Le(createdAtEpochSeconds)
    }

    /// Author a new logical message identity with wall-clock time and CSPRNG nonce.
    public static func createNew(
        nowEpochSeconds: Int64 = Int64(Date().timeIntervalSince1970)
    ) -> LogicalMessageIdentity {
        let nonce = MessageId.generateNonce()
        return LogicalMessageIdentity(createdAtEpochSeconds: nowEpochSeconds, messageNonce: nonce)
    }

    /// Construct a deterministic logical identity (for tests, unsealing, and rederivation).
    public static func of(
        createdAtEpochSeconds: Int64,
        messageNonce: Data
    ) -> LogicalMessageIdentity {
        LogicalMessageIdentity(createdAtEpochSeconds: createdAtEpochSeconds, messageNonce: messageNonce)
    }
}
