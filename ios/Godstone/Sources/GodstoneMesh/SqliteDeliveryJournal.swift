import Foundation

// Stage 4C.1 / C6.1 -- production `DeliveryJournal` backed by the SAME SQLite DB
// as the held-frames store. The delivery lifecycle state, the ACK mode, and the
// intended recipient live in ONE row keyed by msg_id, so the ACK authenticity
// decision (C2) binds to the recipient recorded in durable outbound state
// INDEPENDENT of the ACK frame (ADR-005: do not claim an ACK is from the
// intended recipient unless the expected recipient comes from durable outbound
// state).
//
// Each mutation is a single atomic SQL statement (see StoreSchema): `insert`
// creates the row (INSERT ... ON CONFLICT DO NOTHING), `updateState` advances
// only the state column (UPDATE SET state WHERE msg_id, preserving ack_mode +
// expected_recipient), `clear` drops the row. The expected recipient is IMMUTABLE
// post-creation -- there is no recipient-only write. A crash between
// DeliveryTracker's read and write leaves the LAST persisted state on disk (the
// write did not commit), which is the crash-safe semantics ADR-005 requires.
// (CAS-hardened transitions arrive in C6.4.)
//
// The int state / ack_mode codes are the cross-platform persistence contract
// (DeliveryState.code / AckMode.rawValue, NOT the Swift enum order), so Android
// and iOS agree even if their enum orders ever diverge. An unknown state or
// ack_mode code, or a row that violates the C6.1 binding invariant, decodes to
// `DeliveryLookup.corrupt` -- fail closed (C6.5), never silently to unavailable.
// Mirrors `SqliteDeliveryJournal` on Android (byte-identical schema + SQL +
// codes).

/// Production `DeliveryJournal` over the same SQLite DB as `SqliteMessageStore`'s
/// held-frames table. One row holds the delivery state, ack mode, and intended
/// recipient, so the row read at acknowledge time is the row written at enqueue
/// time. The separate `ExpectedRecipientStore` seam was removed in C6.1: the
/// journal IS the durable record.
public final class SqliteDeliveryJournal: DeliveryJournal {
    private let store: SqliteMessageStore

    public init(_ store: SqliteMessageStore) {
        self.store = store
    }

    public func read(_ msgId: Data) -> DeliveryLookup {
        guard let row = store.readDelivery(msgId) else { return .notFound }
        guard let state = DeliveryState.fromCode(row.state) else { return .corrupt }
        guard let ackMode = AckMode.fromCode(row.ackMode) else { return .corrupt }
        // C6.1 binding invariant (mirrors the schema CHECK): none -> nil
        // recipient; singleRecipient -> 16-byte recipient. A row that violates it
        // (e.g. manually mutated) is corrupt -- fail closed.
        guard bindingConsistent(ackMode: ackMode, expectedRecipient: row.expectedRecipient) else {
            return .corrupt
        }
        return .found(DeliveryRecord(msgId: msgId, state: state, ackMode: ackMode,
                                     expectedRecipientNodeId: row.expectedRecipient))
    }

    public func insert(_ msgId: Data, ackMode: AckMode, expectedRecipient: Data?) -> Bool {
        store.insertDelivery(msgId,
                             stateOrdinal: DeliveryState.queuedDurably.code,
                             ackModeOrdinal: ackMode.rawValue,
                             expectedRecipient: expectedRecipient)
    }

    public func updateState(_ msgId: Data, _ state: DeliveryState) -> Int {
        store.updateDeliveryState(msgId, stateOrdinal: state.code)
    }

    public func clear(_ msgId: Data) {
        store.clearDelivery(msgId)
    }

    /// C6.1 invariant: none -> nil recipient; singleRecipient -> 16-byte recipient.
    private func bindingConsistent(ackMode: AckMode, expectedRecipient: Data?) -> Bool {
        switch ackMode {
        case .none: return expectedRecipient == nil
        case .singleRecipient:
            guard let r = expectedRecipient else { return false }
            return r.count == 16
        }
    }
}