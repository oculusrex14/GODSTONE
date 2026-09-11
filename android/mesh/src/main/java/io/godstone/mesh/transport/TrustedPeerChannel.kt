package io.godstone.mesh.transport

// ---------------------------------------------------------------------------
// T24 - the peer-event contract.
//
// A peer is published to the application ONLY as a relation-bound,
// authenticated view. Its identity is carried by the node id and the identity
// public key and the trust version - never by a transport address, MAC,
// CBPeripheral UUID, node hint or RSSI, which may not substitute for it
// (section 5, the frozen identity law: node_id = BLAKE2s-128(identityPub),
// 16 bytes; identityPub, Ed25519, 32 bytes). The events travel a BOUNDED
// RELIABLE channel, never a silent-drop queue: an offer is Accepted, meets
// bounded Backpressure (the caller keeps the duty to retry), or the channel is
// in TerminalFailure. Delivery follows the section 13 event algorithm -
// capture the owner token, validate the token and the input under the named
// owner, make one transition, then revalidate the token upon completion.
// ---------------------------------------------------------------------------

/** The frozen widths of an authenticated peer identity. */
internal object TrustedPeerSpec {
    const val NODE_ID_BYTES: Int = 16
    const val IDENTITY_PUB_BYTES: Int = 32
}

/**
 * An immutable, authenticated view of one peer bound to exactly one relation.
 * Two peers are the same peer when their relation, node id, identity public
 * key and trust version all agree by content - the transport handle is not
 * part of identity.
 */
internal class TrustedPeer(
    val relation: RelationKey,
    suppliedNodeId: ByteArray,
    suppliedIdentityPub: ByteArray,
    val trustVersion: Long,
) {
    // The captured identity is IMMUTABLE: the value owneth private copies of the
    // authenticated bytes, so no later mutation of a caller's buffer may corrupt a
    // peer that hath already been trusted (the section-5 immutability law).
    val nodeId16: ByteArray = suppliedNodeId.copyOf()
    val identityPub32: ByteArray = suppliedIdentityPub.copyOf()

    init {
        require(nodeId16.size == TrustedPeerSpec.NODE_ID_BYTES) {
            "a trusted peer carrieth a ${TrustedPeerSpec.NODE_ID_BYTES}-byte node id"
        }
        require(identityPub32.size == TrustedPeerSpec.IDENTITY_PUB_BYTES) {
            "a trusted peer carrieth a ${TrustedPeerSpec.IDENTITY_PUB_BYTES}-byte identity public key"
        }
        require(trustVersion >= 0L) { "a trust version may not be negative" }
    }

    companion object {
        /**
         * Capture the authenticated relation as an immutable identity AT THE
         * AUTHENTICATED MOMENT, forcing the frozen identity law upon the capture:
         * the node id is DERIVED as `BLAKE2s-128(identityPub)` by the very routine
         * the identity layer employs (section 5), never trusted from a caller's
         * bytes. The raw constructor accepteth any node id the caller supplyeth;
         * this factory leaveth no such freedom, so a captured peer can never
         * disagree with its own identity public key.
         *
         * @param authenticatedIdentityPub32 the remote Ed25519 identity public key
         *        (32 bytes) as the transport learned it when the relation was sealed.
         * @param trustVersion a NON-NEGATIVE, monotonic trust epoch of that identity.
         */
        fun capture(
            relation: RelationKey,
            authenticatedIdentityPub32: ByteArray,
            trustVersion: Long,
        ): TrustedPeer {
            require(authenticatedIdentityPub32.size == TrustedPeerSpec.IDENTITY_PUB_BYTES) {
                "onely a ${TrustedPeerSpec.IDENTITY_PUB_BYTES}-byte authenticated identity public key may be captured"
            }
            require(trustVersion >= 0L) { "a trust version may not be negative" }
            // Defer wholly to the canonical derivation; duplicate no hash here.
            val nodeId16 = io.godstone.mesh.identity.Identity.nodeIdOf(authenticatedIdentityPub32)
            return TrustedPeer(relation, nodeId16, authenticatedIdentityPub32, trustVersion)
        }
    }

    /** A defensive read of the node id, that no caller may mutate our copy. */
    fun copyNodeId(): ByteArray = nodeId16.copyOf()

    /** A defensive read of the identity public key. */
    fun copyIdentityPub(): ByteArray = identityPub32.copyOf()

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is TrustedPeer) return false
        return other.relation == relation &&
            other.trustVersion == trustVersion &&
            other.nodeId16.contentEquals(nodeId16) &&
            other.identityPub32.contentEquals(identityPub32)
    }

    override fun hashCode(): Int {
        var h = relation.hashCode()
        h = 31 * h + nodeId16.contentHashCode()
        h = 31 * h + identityPub32.contentHashCode()
        h = 31 * h + trustVersion.hashCode()
        return h
    }
}

/** The three authoritative peer events, each carrying its immutable trusted peer. */
internal sealed class LinkEvent {
    abstract val peer: TrustedPeer

    /** The relation became link-ready: trusted cryptographic ready and key-confirmed. */
    internal class LinkReady(override val peer: TrustedPeer) : LinkEvent()

    /** The relation was lost or torn down. */
    internal class LinkLost(override val peer: TrustedPeer) : LinkEvent()

    /** The peer's authenticated identity was asserted at its trust version. */
    internal class Auth(override val peer: TrustedPeer) : LinkEvent()
}

/** The verdict a caller readeth back from offering upon the reliable channel. */
internal sealed class OfferVerdict {
    /** The event was carried by the channel. */
    internal object Accepted : OfferVerdict()

    /** Bounded: the queue is full. Nothing is silently dropped; the caller must retry. */
    internal object Backpressure : OfferVerdict()

    /** The channel, or the owning relation, hath fail'd terminally; nothing more is carried. */
    internal object TerminalFailure : OfferVerdict()
}

/**
 * A bounded RELIABLE peer-event channel. It is never lossy by silent drop: an
 * offer is Accepted, meeteth bounded Backpressure (the caller keepeth the duty
 * to retry), or the channel is in TerminalFailure. The owner token (the
 * relation generation) is validated at entry and revalidated upon completion,
 * and exactly one transition is made per accepted offer.
 */
internal class ReliablePeerEventChannel(val capacity: Int) {
    init {
        require(capacity > 0) { "the bound of a reliable channel must be positive" }
    }

    private val queue = java.util.ArrayDeque<LinkEvent>()
    private var terminal = false

    /** How many events await delivery. */
    val size: Int get() = queue.size

    /** Whether the channel hath fail'd terminally. */
    val isTerminal: Boolean get() = terminal

    /**
     * Offer [event] under the named [ownerGeneration]. A terminal channel, or a
     * token that doth not match the event's own relation generation, is refused
     * as a [OfferVerdict.TerminalFailure]; a full queue answereth
     * [OfferVerdict.Backpressure] without dropping a whit; otherwise the single
     * event is [OfferVerdict.Accepted].
     */
    fun offer(event: LinkEvent, ownerGeneration: Long): OfferVerdict {
        if (terminal) return OfferVerdict.TerminalFailure
        if (event.peer.relation.generation != ownerGeneration) return OfferVerdict.TerminalFailure
        if (queue.size >= capacity) return OfferVerdict.Backpressure
        queue.addLast(event)
        // revalidate the owner token upon completion: a mid-offer terminal turn undoeth the slip
        if (terminal) {
            queue.remove(event)
            return OfferVerdict.TerminalFailure
        }
        return OfferVerdict.Accepted
    }

    /** Take the head event for delivery, or null when empty or terminal. */
    fun poll(): LinkEvent? {
        if (terminal) return null
        return queue.pollFirst()
    }

    /** Fail the channel terminally: nothing more is carried, and the queue is voided. */
    fun failTerminally() {
        terminal = true
        queue.clear()
    }
}
