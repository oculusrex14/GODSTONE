import Foundation

// Stage 4C.1 / C6.3 -- production `DeliveryRepository` backed by the SAME SQLite
// DB as the held-frames store. Folds the C6.1 `DeliveryJournal` plus the
// enqueue / transition / retire classification into ONE atomic aggregate over
// the `delivery_state` row keyed by msg_id, so the ACK authenticity decision
// (C2) binds to the recipient recorded in durable outbound state INDEPENDENT of
// the ACK frame (ADR-005: do not claim an ACK is from the intended recipient
// unless the expected recipient comes from durable outbound state).
//
// Each mutation is a single atomic SQL statement (see StoreSchema): `enqueue`
// creates the row (INSERT ... ON CONFLICT DO NOTHING -- a conflict is classified
// by re-reading), `compareAndSet` / `acknowledgeAndRetire` advance only the
// state column (UPDATE SET state WHERE msg_id, preserving ack_mode +
// expected_recipient), `clear` drops the row. The expected recipient is IMMUTABLE
// post-creation -- there is no recipient-only write. A crash between the
// repository's read and write leaves the LAST persisted state on disk (the
// write did not commit), which is the crash-safe semantics ADR-005 requires.
// (CAS-hardened WHERE-clause transitions arrive in C6.4.)
//
// The int state / ack_mode codes are the cross-platform persistence contract
// (DeliveryState.code / AckMode.rawValue, NOT the Swift enum order), so Android
// and iOS agree even if their enum orders ever diverge. An unknown state or
// ack_mode code, or a row that violates the C6.1 binding invariant, decodes to
// `DeliveryLookup.corrupt` -- fail closed (C6.5), never silently to unavailable.
// Mirrors `SqliteDeliveryRepository` on Android (byte-identical schema + SQL +
// codes).

/// Production `DeliveryRepository` over the same SQLite DB as `SqliteMessageStore`'s
/// held-frames table. One row holds the delivery state, ack mode, and intended
/// recipient, so the row read at acknowledge time is the row written at enqueue
/// time. The separate `ExpectedRecipientStore` seam was removed in C6.1: the
/// repository IS the durable record.
public final class SqliteDeliveryRepository: DeliveryRepository {
    private let store: SqliteMessageStore

    public init(_ store: SqliteMessageStore) {
        self.store = store
    }

    public func get(_ msgId: Data) -> DeliveryLookup {
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

    public func enqueue(_ msgId: Data, ackMode: AckMode, expectedRecipient: Data?) -> EnqueueResult {
        // C6.1 invariant: none -> no recipient; singleRecipient -> 16-byte recipient.
        guard bindingConsistent(ackMode: ackMode, expectedRecipient: expectedRecipient) else {
            return .corrupt
        }
        switch get(msgId) {
        case .notFound:
            if store.insertDelivery(msgId,
                                    stateOrdinal: DeliveryState.queuedDurably.code,
                                    ackModeOrdinal: ackMode.rawValue,
                                    expectedRecipient: expectedRecipient) {
                return .created
            }
            // Row appeared mid-call -- re-read to classify the conflict.
            return classifyExisting(msgId: msgId, ackMode: ackMode, expectedRecipient: expectedRecipient)
        case .found(let rec):
            return classifyExisting(rec: rec, ackMode: ackMode, expectedRecipient: expectedRecipient)
        case .corrupt:
            return .corrupt
        case .storageFailure:
            return .storageFailure
        }
    }

    public func compareAndSet(_ msgId: Data, validFroms: Set<DeliveryState>,
                              target: DeliveryState) -> TransitionResult {
        switch get(msgId) {
        case .notFound: return .unknownMessage
        case .corrupt: return .corrupt
        case .storageFailure: return .storageFailure
        case .found(let rec):
            let s = rec.state
            if s == target { return .alreadyInTarget }
            if validFroms.contains(s) {
                return store.updateDeliveryState(msgId, stateOrdinal: target.code) == 1
                    ? .applied : .unknownMessage // row vanished mid-call
            }
            return .rejectedState
        }
    }

    public func acknowledgeAndRetire(_ msgId: Data, ackMode: AckMode,
                                     expectedRecipient: Data?) -> AckResult {
        switch get(msgId) {
        case .notFound: return .unknownMessage
        case .corrupt: return .corrupt
        case .storageFailure: return .storageFailure
        case .found(let rec):
            // The durable binding (ack mode + expected recipient) MUST still match
            // the values the tracker authenticated against -- the recipient identity
            // comes from durable outbound state, INDEPENDENT of the ACK frame. A
            // mismatch means the row is not the message the tracker verified.
            if rec.ackMode != ackMode || rec.expectedRecipientNodeId != expectedRecipient {
                return .unknownMessage
            }
            return store.updateDeliveryState(msgId,
                                             stateOrdinal: DeliveryState.acknowledgedByRecipient.code) == 1
                ? .applied : .unknownMessage // row vanished mid-call (raced expire/cancel/forget)
        }
    }

    public func clear(_ msgId: Data) {
        store.clearDelivery(msgId)
    }

    private func classifyExisting(msgId: Data, ackMode: AckMode,
                                  expectedRecipient: Data?) -> EnqueueResult {
        switch get(msgId) {
        case .found(let rec):
            return classifyExisting(rec: rec, ackMode: ackMode, expectedRecipient: expectedRecipient)
        case .notFound:
            return .storageFailure // row vanished -- storage anomaly
        case .corrupt:
            return .corrupt
        case .storageFailure:
            return .storageFailure
        }
    }

    private func classifyExisting(rec: DeliveryRecord, ackMode: AckMode,
                                  expectedRecipient: Data?) -> EnqueueResult {
        if rec.state.isTerminal { return .rejectedTerminalState }
        // Non-terminal (queued / handed): same binding -> idempotent; else conflict.
        if rec.ackMode == ackMode && rec.expectedRecipientNodeId == expectedRecipient {
            return .alreadyQueuedSameBinding
        }
        return .conflictRecipient
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