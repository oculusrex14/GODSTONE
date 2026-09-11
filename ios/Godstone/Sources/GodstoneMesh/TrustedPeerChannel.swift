import Foundation

// ---------------------------------------------------------------------------
// T24 - the peer-event contract (the iOS half, mirror of TrustedPeerChannel.kt).
//
// A peer is publish'd to the application onely as a relation-bound, authenticated
// view. Its identity is carri'd by the node id and the identity public key and
// the trust version - never by a transport address, MAC, CBPeripheral UUID, node
// hint or RSSI, which may not substitute for it (section 5, the frozen identity
// law: node_id = BLAKE2s-128(identityPub), 16 octets; identityPub, Ed25519, 32
// octets). The events travel a BOUNDED RELIABLE channel, never a silent-drop
// queue: an offer is accepted, meeteth bounded backpressure (the caller keepeth
// the duty to retry), or the channel is in terminal failure. Delivery followeth
// the section 13 event algorithm - capture the owner token, validate the token
// and the input under the named owner, make one transition, then revalidate the
// token upon completion.
// ---------------------------------------------------------------------------

/// The frozen widths of an authenticated peer identity.
enum TrustedPeerSpec {
    static let nodeIdBytes: Int = 16
    static let identityPubBytes: Int = 32
}

/// An immutable, authenticated view of one peer bound to exactly one relation.
/// Two peers are the selfsame peer when their relation, node id, identity public
/// key and trust version all agree by CONTENT - the transport handle is no part
/// of identity. As a value type it is copied by value, so no caller may mutate
/// a peer it hath been given.
struct TrustedPeer: Equatable, Hashable, Sendable {
    let relation: RelationKey
    let nodeId16: Data
    let identityPub32: Data
    let trustVersion: Int

    /// A failable init: a peer whose node id is not sixteen octets, whose
    /// identity public key is not thirty-two octets, or whose trust version is
    /// negative is REFUS'd (nil), never constructured.
    init?(relation: RelationKey, nodeId16: Data, identityPub32: Data, trustVersion: Int) {
        self.relation = relation
        self.nodeId16 = nodeId16
        self.identityPub32 = identityPub32
        self.trustVersion = trustVersion
        guard nodeId16.count == TrustedPeerSpec.nodeIdBytes else { return nil }
        guard identityPub32.count == TrustedPeerSpec.identityPubBytes else { return nil }
        guard trustVersion >= 0 else { return nil }
    }

    // Content equality & hash are synthesiz'd from the four stored properties:
    // Data compareth bytewise, RelationKey is Hashable, Int compareth by value -
    // therefore two independently-built peers with the selfsame bytes are equal,
    // while a differing byte, version or relation maketh a different peer.
}

/// The three authoritative peer events, each carrying its immutable trusted peer.
enum LinkEvent: Sendable {
    /// The relation became link-ready: trusted cryptographic ready and key-confirmed.
    case linkReady(TrustedPeer)
    /// The relation was lost or torn down.
    case linkLost(TrustedPeer)
    /// The peer's authenticated identity was assert'd at its trust version.
    case auth(TrustedPeer)

    var peer: TrustedPeer {
        switch self {
        case let .linkReady(peer), let .linkLost(peer), let .auth(peer):
            return peer
        }
    }
}

/// The verdict a caller readeth back from offering upon the reliable channel.
enum OfferVerdict: Equatable {
    /// The event was carri'd by the channel.
    case accepted
    /// Bounded: the queue is full. Nothing is silently dropped; the caller must retry.
    case backpressure
    /// The channel, or the owning relation, hath fail'd terminally; nothing more is carri'd.
    case terminalFailure
}

/// A bounded RELIABLE peer-event channel. It is never lossy by silent drop: an
/// offer is accepted, meeteth bounded backpressure (the caller keepeth the duty
/// to retry), or the channel is in terminal failure. The owner token (the
/// relation generation) is validated at entry and revalidated upon completion,
/// and exactly one transition is made per accepted offer.
final class ReliablePeerEventChannel: @unchecked Sendable {
    let capacity: Int
    private let lock = NSLock()
    private var queue: [LinkEvent] = []
    private var terminal: Bool = false

    init(capacity: Int) {
        precondition(capacity > 0, "the bound of a reliable channel must be positive")
        self.capacity = capacity
    }

    /// How many events await delivery.
    var size: Int {
        lock.lock(); defer { lock.unlock() }
        return queue.count
    }

    /// Whether the channel hath fail'd terminally.
    var isTerminal: Bool {
        lock.lock(); defer { lock.unlock() }
        return terminal
    }

    /// Offer [event] under the named [ownerGeneration]. A terminal channel, or a
    /// token that doth not match the event's own relation generation, is refus'd
    /// as a terminal failure; a full queue answereth backpressure without
    /// dropping a whit; otherwise the single event is accepted.
    func offer(_ event: LinkEvent, ownerGeneration: UInt64) -> OfferVerdict {
        lock.lock(); defer { lock.unlock() }
        if terminal { return .terminalFailure }
        if event.peer.relation.generation != ownerGeneration { return .terminalFailure }
        if queue.count >= capacity { return .backpressure }
        queue.append(event)
        // revalidate the owner token upon completion: a mid-offer terminal turn undoeth the slip
        if terminal {
            if let last = queue.last, last.peer == event.peer { queue.removeLast() }
            return .terminalFailure
        }
        return .accepted
    }

    /// Take the head event for delivery, or nil when empty or terminal.
    func poll() -> LinkEvent? {
        lock.lock(); defer { lock.unlock() }
        if terminal { return nil }
        return queue.isEmpty ? nil : queue.removeFirst()
    }

    /// Fail the channel terminally: nothing more is carri'd, and the queue is voided.
    func failTerminally() {
        lock.lock(); defer { lock.unlock() }
        terminal = true
        queue.removeAll()
    }
}
