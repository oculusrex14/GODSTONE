package io.godstone.mesh.delivery

import io.godstone.mesh.identity.PeerIdentityLookup
import io.godstone.mesh.identity.PeerIdentityRepository
import io.godstone.mesh.identity.PeerTrustLevel

/**
 * Read-only lookup source abstraction for resolving peer identities (ADR-003, Phase C8.3).
 *
 * Provides a minimal, read-only interface to decouple [BoundRecipientKeyResolver]
 * from the full mutable [PeerIdentityRepository] surface.
 */
internal fun interface PeerIdentityLookupSource {
    fun lookup(nodeId: ByteArray): PeerIdentityLookup
}

/**
 * Adapter exposing [PeerIdentityRepository.lookup] through the read-only [PeerIdentityLookupSource] contract.
 */
internal class RepositoryPeerIdentityLookupSource(
    private val repository: PeerIdentityRepository
) : PeerIdentityLookupSource {
    override fun lookup(nodeId: ByteArray): PeerIdentityLookup =
        repository.lookup(nodeId)
}

/**
 * Read-only durable peer-identity -> ACK signing-key resolver (ADR-003, Phase C8.3).
 *
 * Maps a 16-byte `node_id` to its bound 32-byte Ed25519 `signing_public_key` if and only if
 * the peer is in an active verified state ([PeerTrustLevel.TOFU_PINNED] or [PeerTrustLevel.USER_VERIFIED])
 * with no pending rotation candidate and not revoked.
 *
 * Invariants:
 * - Read-only: never performs store mutations, approvals, rotations, or key generation.
 * - Fail-closed: returns `null` for unverified, quarantined, revoked, corrupt, missing, or invalid states.
 * - Stateless: never caches or memoizes keys; all invocations query [PeerIdentityLookupSource].
 * - Boundary: guards `nodeId.size == 16` before invoking lookup source.
 * - Defensive: returns a defensive clone of the 32-byte signing key.
 */
internal class BoundRecipientKeyResolver(
    private val source: PeerIdentityLookupSource
) : RecipientKeyResolver {

    constructor(repository: PeerIdentityRepository) : this(RepositoryPeerIdentityLookupSource(repository))

    override fun publicSigningKey(nodeId: ByteArray): ByteArray? {
        if (nodeId.size != 16) {
            return null
        }
        val lookup = try {
            source.lookup(nodeId)
        } catch (_: Exception) {
            return null
        }
        return when (lookup) {
            is PeerIdentityLookup.Verified -> {
                when (lookup.identity.trustLevel) {
                    PeerTrustLevel.TOFU_PINNED,
                    PeerTrustLevel.USER_VERIFIED -> lookup.identity.signingPublicKey.clone()
                    PeerTrustLevel.REVOKED -> null
                }
            }
            is PeerIdentityLookup.NotFound,
            is PeerIdentityLookup.Quarantined,
            is PeerIdentityLookup.Revoked,
            is PeerIdentityLookup.Corrupt,
            is PeerIdentityLookup.StorageFailure,
            is PeerIdentityLookup.InvalidArgument -> null
        }
    }
}
