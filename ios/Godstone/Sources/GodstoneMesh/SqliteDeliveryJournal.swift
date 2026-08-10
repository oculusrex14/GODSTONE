import Foundation

// Stage 4C / C4 -- production `DeliveryJournal` + `ExpectedRecipientStore` backed
// by the SAME SQLite DB as the held-frames store (not a separate file). The
// delivery lifecycle state AND the intended recipient live in ONE row keyed by
// msg_id, so the ACK authenticity decision (C2) binds to the recipient recorded
// in durable outbound state INDEPENDENT of the ACK frame (ADR-005: do not claim
// an ACK is from the intended recipient unless the expected recipient comes
// from durable outbound state).
//
// Each operation is a single atomic SQL statement (see StoreSchema): a
// state-only write preserves any bound expected recipient via a subquery, and a
// recipient-only write preserves the current state via COALESCE -- so the
// non-recursive NSLock is acquired once per call (via `withDb`) and no
// transaction seam is needed. A crash between DeliveryTracker's read and write
// leaves the LAST persisted state on disk (the write did not commit), which is
// the crash-safe semantics ADR-005 requires.
//
// The int state code is the cross-platform persistence contract (NOT the Swift
// enum's hash/position), so Android and iOS agree even if their enum orders ever
// differ. Mirrors `SqliteDeliveryJournal` on Android (byte-identical schema +
// SQL + codes).

/// Production `DeliveryJournal` + `ExpectedRecipientStore` over the same SQLite
/// DB as `SqliteMessageStore`'s held-frames table. The same journal instance
/// serves as BOTH the journal and the expected-recipient store, so the row read
/// at acknowledge time is the row written at enqueue time.
public final class SqliteDeliveryJournal: DeliveryJournal, ExpectedRecipientStore {
    private let store: SqliteMessageStore

    public init(_ store: SqliteMessageStore) {
        self.store = store
    }

    public func read(_ msgId: Data) -> DeliveryState {
        guard let row = store.readDelivery(msgId) else { return .unavailable }
        return fromCode(row.state)
    }

    public func write(_ msgId: Data, _ state: DeliveryState) {
        store.upsertDeliveryState(msgId, stateOrdinal: code(state))
    }

    public func clear(_ msgId: Data) {
        store.clearDelivery(msgId)
    }

    public func expectedRecipient(_ msgId: Data) -> Data? {
        store.readDelivery(msgId)?.expectedRecipient
    }

    public func recordExpectedRecipient(_ msgId: Data, _ recipient: Data?) {
        store.upsertDeliveryRecipient(msgId, expectedRecipient: recipient)
    }

    /// Stable int persistence code -- the cross-platform contract (mirrors
    /// Android). unavailable=0, queuedDurably=1, handedToRelay=2,
    /// acknowledgedByRecipient=3, expired=4, cancelledLocally=5.
    private func code(_ s: DeliveryState) -> Int32 {
        switch s {
        case .unavailable: return 0
        case .queuedDurably: return 1
        case .handedToRelay: return 2
        case .acknowledgedByRecipient: return 3
        case .expired: return 4
        case .cancelledLocally: return 5
        }
    }

    private func fromCode(_ c: Int32) -> DeliveryState {
        switch c {
        case 0: return .unavailable
        case 1: return .queuedDurably
        case 2: return .handedToRelay
        case 3: return .acknowledgedByRecipient
        case 4: return .expired
        case 5: return .cancelledLocally
        default: return .unavailable   // forward-compat: unknown code -> unavailable
        }
    }
}