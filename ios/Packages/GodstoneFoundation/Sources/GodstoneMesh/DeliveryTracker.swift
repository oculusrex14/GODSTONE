import Foundation

// Stage 3 Phase H -- durable, recipient-authenticated delivery state machine
// (ADR-005; A-03). The lifecycle from ADR-005:
//
//   UNAVAILABLE | QUEUED_DURABLY -> HANDED_TO_RELAY -> ACKNOWLEDGED_BY_RECIPIENT
//                                       \-> EXPIRED | CANCELLED_LOCALLY
//
// A successful GATT write is only HANDED_TO_RELAY. SENT / ACKNOWLEDGED_BY_RECIPIENT
// is forbidden unless an AUTHENTICATED intended recipient ACKs the EXACT message
// id (see AckAuthenticator). Cancellation cannot recall already relayed copies
// and the state says so. The machine is pure (no Keychain / no disk) with the
// journal + authenticator injected, so it is host-testable without a device or
// radio. The radio/link layer remains disabled (M2-link), so this is repo-owned
// evidence for the state machine + authenticated-ACK verification, not an
// on-device delivery proof. The Swift twin of android/.../mesh/delivery/
// DeliveryTracker.kt -- same states, same truth-table, same idempotent terminal
// semantics, so the two platforms enforce the same delivery contract.

/// Delivery lifecycle (ADR-005). Terminal states are acknowledged, expired,
/// cancelled.
public enum DeliveryState: String, Sendable {
    case unavailable
    case queuedDurably
    case handedToRelay
    case acknowledgedByRecipient
    case expired
    case cancelledLocally

    public var isTerminal: Bool {
        self == .acknowledgedByRecipient || self == .expired || self == .cancelledLocally
    }
}

/// Crash-safe persisted delivery state per message id. Implementations must
/// persist across a reboot/jetsam so a fresh `DeliveryTracker` over the same
/// journal recovers the state (reboot recovery, ADR-005 exit criteria).
public protocol DeliveryJournal: AnyObject {
    func read(_ msgId: Data) -> DeliveryState
    func write(_ msgId: Data, _ state: DeliveryState)
    func clear(_ msgId: Data)
}

/// Verifies that an inbound ACK frame is an authentic acknowledgment of
/// `originalMsgId` by the intended recipient. See `Ed25519AckAuthenticator` for
/// the binding model. A return of false means the ACK is rejected and the
/// delivery state MUST NOT advance to acknowledged -- no UI phrase stronger
/// than the cryptographic evidence is permitted (ADR-005).
public protocol AckAuthenticator: AnyObject {
    func verify(originalMsgId: Data, ackFrame: FrameV2) -> Bool
}

/// Durable delivery state machine. Every successful transition is persisted to
/// `journal` AFTER it is applied, so a crash-then-resume re-reads the last
/// persisted state. Transitions that are illegal for the current state (or an
/// ACK that fails authentication) return false and do not mutate state -- the
/// truth-table is enforced, not advisory.
public final class DeliveryTracker {
    private let journal: DeliveryJournal
    private let authenticator: AckAuthenticator

    public init(journal: DeliveryJournal, authenticator: AckAuthenticator) {
        self.journal = journal
        self.authenticator = authenticator
    }

    /// Current persisted state for `msgId` (unavailable if never tracked).
    public func state(_ msgId: Data) -> DeliveryState { journal.read(msgId) }

    /// Begin tracking: unavailable -> queuedDurably. Idempotent: already-queued
    /// stays queued. Returns false from any non-queueable state.
    @discardableResult
    public func enqueue(_ msgId: Data) -> Bool {
        let s = journal.read(msgId)
        if s == .queuedDurably { return true }
        if s != .unavailable { return false }
        journal.write(msgId, .queuedDurably)
        return true
    }

    /// Record a successful GATT write: queuedDurably -> handedToRelay.
    /// Idempotent from handedToRelay. This is NOT "sent" -- only `acknowledge`
    /// can reach acknowledgedByRecipient.
    @discardableResult
    public func markHandedToRelay(_ msgId: Data) -> Bool {
        let s = journal.read(msgId)
        if s == .handedToRelay { return true }
        if s != .queuedDurably { return false }
        journal.write(msgId, .handedToRelay)
        return true
    }

    /// Apply an authenticated recipient ACK. Only advances to
    /// acknowledgedByRecipient when `authenticator` accepts the ACK AND the
    /// current state is queuedDurably or handedToRelay (or already
    /// acknowledged -- idempotent). A rejected ACK returns false and the state
    /// is unchanged: no delivery is claimed without cryptographic evidence.
    @discardableResult
    public func acknowledge(_ msgId: Data, _ ackFrame: FrameV2) -> Bool {
        let s = journal.read(msgId)
        if s == .acknowledgedByRecipient { return true }   // idempotent re-ack
        if s != .queuedDurably && s != .handedToRelay { return false }
        if !authenticator.verify(originalMsgId: msgId, ackFrame: ackFrame) { return false }
        journal.write(msgId, .acknowledgedByRecipient)
        return true
    }

    /// TTL expiry: queuedDurably or handedToRelay -> expired. Terminal/idempotent.
    @discardableResult
    public func expire(_ msgId: Data) -> Bool {
        let s = journal.read(msgId)
        if s == .expired { return true }
        if s != .queuedDurably && s != .handedToRelay { return false }
        journal.write(msgId, .expired)
        return true
    }

    /// Local cancellation: queuedDurably or handedToRelay -> cancelledLocally.
    /// Terminal/idempotent. Cancellation cannot recall already relayed copies --
    /// the caller gives the truthful UI; the state machine records the intent.
    @discardableResult
    public func cancel(_ msgId: Data) -> Bool {
        let s = journal.read(msgId)
        if s == .cancelledLocally { return true }
        if s != .queuedDurably && s != .handedToRelay { return false }
        journal.write(msgId, .cancelledLocally)
        return true
    }

    /// Drop tracking for `msgId` (e.g. after it ages out of the store).
    public func forget(_ msgId: Data) { journal.clear(msgId) }
}