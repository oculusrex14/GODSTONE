import Foundation

/// Read-only lookup source abstraction for resolving peer identities (ADR-003, Phase C8.3).
///
/// Provides a minimal, read-only protocol to decouple `BoundRecipientKeyResolver`
/// from the full mutable `PeerIdentityRepository` surface.
internal protocol PeerIdentityLookupSource: AnyObject, Sendable {
    func lookup(_ nodeId: Data) -> PeerIdentityLookup
}

extension PeerIdentityRepository: PeerIdentityLookupSource {}

/// Read-only durable peer-identity -> ACK signing-key resolver (ADR-003, Phase C8.3).
///
/// Maps a 16-byte `node_id` to its bound 32-byte Ed25519 `signing_public_key` if and only if
/// the peer is in an active verified state (`.tofuPinned` or `.userVerified`)
/// with no pending rotation candidate and not revoked.
///
/// Invariants:
/// - Read-only: never performs store mutations, approvals, rotations, or key generation.
/// - Fail-closed: returns `nil` for unverified, quarantined, revoked, corrupt, missing, or invalid states.
/// - Stateless: never caches or memoizes keys; all invocations query `PeerIdentityLookupSource`.
/// - Boundary: guards `nodeId.count == 16` before invoking lookup source.
/// - Signing key only: returns `signingPublicKey`, never transport or static DH keys.
internal final class BoundRecipientKeyResolver: RecipientKeyResolver, @unchecked Sendable {
    private let source: any PeerIdentityLookupSource

    internal init(source: any PeerIdentityLookupSource) {
        self.source = source
    }

    internal func publicSigningKey(forNodeId nodeId: Data) -> Data? {
        guard nodeId.count == 16 else {
            return nil
        }
        let lookup = source.lookup(nodeId)
        switch lookup {
        case .verified(let identity):
            switch identity.trustLevel {
            case .tofuPinned, .userVerified:
                return identity.signingPublicKey
            case .revoked:
                return nil
            }
        case .notFound, .quarantined, .revoked, .corrupt, .storageFailure, .invalidArgument:
            return nil
        }
    }
}
