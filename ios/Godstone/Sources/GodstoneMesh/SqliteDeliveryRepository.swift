import Foundation

// Stage 4C.1 / C6.3 / **C6.4** -- production `DeliveryRepository` backed by the
// SAME SQLite DB as the held-frames store. Folds the C6.1 `DeliveryJournal` plus
// the enqueue / transition / retire classification into ONE atomic aggregate over
// the `delivery_state` row keyed by msg_id, so the ACK authenticity decision (C2)
// binds to the recipient recorded in durable outbound state INDEPENDENT of the
// ACK frame (ADR-005: do not claim an ACK is from the intended recipient unless
// the expected recipient comes from durable outbound state).
//
// C6.4 hardening (see `DeliveryRepository` / `DeliveryTracker` doc):
//  * StorageFailure is REAL (C6.4-A): the iOS store primitives THROW on a SQL /
//    IO / missing-handle failure (the "throwing strict primitives" directive);
//    this repository catches at the boundary and maps to the typed
//    `.storageFailure` variant. Absence / conflict / no-match use their own
//    sentinels (nil / false / 0 row count) and are NEVER folded into a thrown
//    failure. (Android catches `Exception` at the boundary; iOS throws from the
//    primitive and catches here -- same invariant, language-idiomatic split.)
//  * 16-byte msg_id (C6.4-D): every method rejects a non-16-byte msg_id with
//    `.invalidArgument` BEFORE any SQL (the GMP/2.1 msg_id is BLAKE2s-128 = 16
//    bytes; the schema `CHECK (length(msg_id) = 16)` is defense-in-depth).
//  * Real SQL CAS (C6.4-F): `transition` runs a guarded
//    `UPDATE ... SET state WHERE msg_id AND state IN (...)` and decides `.applied`
//    by the affected row count (1), NOT a stale pre-read; a 0-row CAS is re-read
//    ONCE to classify.
//  * Lifecycle truth-table owned here (C6.4-G): `transition` takes a
//    `DeliveryTransition` (the fixed validFroms/target mapping lives here, not in
//    the caller). The old public `compareAndSet(validFroms, target)` is GONE.
//  * ACK CAS (C6.4-H): `acknowledgeBound` runs
//    `UPDATE ... SET acknowledged WHERE msg_id AND state IN (queued,handed) AND
//    ack_mode = SINGLE_RECIPIENT AND expected_recipient = ?` -- state + mode + the
//    EXACT durable recipient in ONE WHERE clause; a 0-row CAS is re-read and
//    classified (`.duplicateAuthenticatedAck` / `.rejectedState` /
//    `.unknownMessage` / `.storageFailure`).
//  * `acknowledgeBound` performs delivery-state retirement ONLY; held-frame
//    retirement is C7.4 (NOT yet implemented -- C6.4-I; ADR-004 delete-on-ACK is
//    NOT closed by this method).
//  * `clear` is typed (C6.4-J): a failed destructive operation is never
//    indistinguishable from success.
//
// C6.4.1-A: production CAS is UNCONDITIONAL. The state / mode / recipient WHERE
// predicates are ALWAYS present -- there is no production API to drop a
// predicate. The C6.4-M mutation controls were REMOVED from this class; mutation
// testing moved to the TEST-ONLY `MutatedDeliveryRepository` (test source), which
// rebuilds the WEAKENED SQL to prove each predicate is load-bearing.
// `ci/no_delivery_guard_bypass.py` fails the build if a guard-bypass token
// re-enters production source.
//
// C6.4-N: row-atomicity here is the `delivery_state` row only. It does NOT yet
// make `persist held frame` + `enqueue delivery record` atomic -- that
// cross-table outbound transaction is C6.6. The int state / ack_mode codes are
// the cross-platform persistence contract (NOT enum ordinals). An unknown state
// or ack_mode code, or a row that violates the C6.1 binding invariant, or a
// persisted state code 0 (UNAVAILABLE -- not a legal durable row, C6.4-C),
// decodes to `DeliveryLookup.corrupt` -- fail closed (C6.5), never silently to
// unavailable. Mirrors `SqliteDeliveryRepository` on Android (byte-identical
// schema + SQL + codes).

/// Production `DeliveryRepository` over the same SQLite DB as `SqliteMessageStore`'s
/// held-frames table. One row holds the delivery state, ack mode, and intended
/// recipient, so the row read at acknowledge time is the row written at enqueue
/// time. The separate `ExpectedRecipientStore` seam was removed in C6.1: the
/// repository IS the durable record.
public final class SqliteDeliveryRepository: DeliveryRepository {
    private let store: DeliveryStore

    /// Internal designated init over the abstract store protocol (C6.4.1-A: NO
    /// guard parameters -- production CAS is unconditional). Reachable by
    /// `@testable` tests that need a `DeliveryStore` which is not a
    /// `SqliteMessageStore` (e.g. `FaultingDeliveryStore`).
    internal init(_ store: DeliveryStore) {
        self.store = store
    }

    /// Production constructor over the concrete store (all CAS predicates on).
    /// Delegates to the designated `DeliveryStore` init via an explicit upcast:
    /// without `as DeliveryStore`, overload resolution picks THIS convenience
    /// init (most-specific match on the `SqliteMessageStore` parameter) and
    /// recurses infinitely (stack overflow -> SIGSEGV).
    public convenience init(_ store: SqliteMessageStore) {
        self.init(store as DeliveryStore)
    }

    public func get(_ msgId: Data) -> DeliveryLookup {
        guard msgId.count == 16 else { return .invalidArgument } // C6.4-D
        do {
            guard let row = try store.readDelivery(msgId) else { return .notFound }
            // C6.4-C: fromPersistedCode rejects code 0 (UNAVAILABLE) -- a persisted
            // UNAVAILABLE is corrupt, NOT a legal durable row.
            guard let state = DeliveryState.fromPersistedCode(row.state) else { return .corrupt }
            guard let ackMode = AckMode.fromCode(row.ackMode) else { return .corrupt }
            // C6.1 binding invariant (mirrors the schema CHECK): none -> nil
            // recipient; singleRecipient -> 16-byte recipient. A row that violates
            // it (e.g. directly mutated) is corrupt -- fail closed.
            guard bindingConsistent(ackMode: ackMode, expectedRecipient: row.expectedRecipient) else {
                return .corrupt
            }
            return .found(DeliveryRecord(msgId: msgId, state: state, ackMode: ackMode,
                                         expectedRecipientNodeId: row.expectedRecipient))
        } catch {
            return .storageFailure // C6.4-A: absence (nil) != failure (throw)
        }
    }

    public func enqueue(_ msgId: Data, ackMode: AckMode, expectedRecipient: Data?) -> EnqueueResult {
        // C6.4-D: reject a non-16-byte msg_id before any SQL.
        guard msgId.count == 16 else { return .invalidArgument }
        // C6.1 invariant: none -> no recipient; singleRecipient -> 16-byte recipient.
        guard bindingConsistent(ackMode: ackMode, expectedRecipient: expectedRecipient) else {
            return .corrupt
        }
        do {
            switch get(msgId) {
            case .notFound:
                let inserted = try store.insertDelivery(
                    msgId,
                    stateOrdinal: DeliveryState.queuedDurably.code,
                    ackModeOrdinal: ackMode.rawValue,
                    expectedRecipient: expectedRecipient)
                if inserted { return .created }
                // ON CONFLICT DO NOTHING -> a row appeared mid-call; re-read to classify.
                return classifyExisting(msgId: msgId, ackMode: ackMode, expectedRecipient: expectedRecipient)
            case .found(let rec):
                return classifyExisting(rec: rec, ackMode: ackMode, expectedRecipient: expectedRecipient)
            case .corrupt: return .corrupt
            case .storageFailure: return .storageFailure
            case .invalidArgument: return .invalidArgument // unreachable (msgId validated)
            }
        } catch {
            return .storageFailure // C6.4-A
        }
    }

    public func transition(_ msgId: Data, _ transition: DeliveryTransition) -> TransitionResult {
        guard msgId.count == 16 else { return .invalidArgument } // C6.4-D
        let (target, validFroms) = transitionMapping(transition)
        let sql = transitionSql(target: target, validFroms: validFroms)
        do {
            let affected = try store.execDeliveryUpdate(sql, bytesArgs: [msgId])
            switch affected {
            case 1: return .applied
            case 0: return classifyZeroRowTransition(msgId: msgId, target: target, validFroms: validFroms)
            default: return .storageFailure // affected > 1: invariant violation (PK is msg_id)
            }
        } catch {
            return .storageFailure // C6.4-A
        }
    }

    public func acknowledgeBound(_ msgId: Data, expectedRecipient: Data) -> AckResult {
        // C6.4-D + binding guard: the authenticated binding is a SINGLE_RECIPIENT
        // binding with a 16-byte recipient. The tracker only calls this for such a
        // record (it gates `none` / nil first); a malformed call fails closed
        // before any SQL. C6.4.1-I: `ackMode` + optionality are removed -- the SQL
        // hard-codes `ack_mode = SINGLE_RECIPIENT` and the recipient is always bound.
        guard msgId.count == 16 else { return .invalidArgument }
        guard expectedRecipient.count == 16 else { return .invalidArgument }
        let sql = acknowledgeBoundSql()
        do {
            let affected = try store.execDeliveryUpdate(sql, bytesArgs: [msgId, expectedRecipient])
            switch affected {
            case 1: return .applied
            case 0: return classifyZeroRowAck(msgId: msgId, expectedRecipient: expectedRecipient)
            default: return .storageFailure // affected > 1: invariant violation
            }
        } catch {
            return .storageFailure // C6.4-A
        }
    }

    public func clear(_ msgId: Data) -> ClearResult {
        guard msgId.count == 16 else { return .invalidArgument } // C6.4-D
        do {
            let affected = try store.execDeliveryUpdate(StoreSchema.clearDeliverySql, bytesArgs: [msgId])
            switch affected {
            case 1: return .cleared
            case 0: return .alreadyAbsent
            default: return .storageFailure
            }
        } catch {
            return .storageFailure // C6.4-A
        }
    }

    // --- C6.4-F/G: guarded SQL CAS builders ---------------------------------

    /// The fixed (target, validFroms) mapping the repository owns (C6.4-G).
    /// C6.4.1-A: `internal` so the TEST-ONLY `MutatedDeliveryRepository` can reuse
    /// the exact lifecycle truth-table without duplicating it.
    internal func transitionMapping(_ t: DeliveryTransition)
        -> (target: DeliveryState, validFroms: [DeliveryState]) {
        switch t {
        case .markHanded:
            return (.handedToRelay, [.queuedDurably])
        case .expire:
            return (.expired, [.queuedDurably, .handedToRelay])
        case .cancel:
            return (.cancelledLocally, [.queuedDurably, .handedToRelay])
        }
    }

    /// `UPDATE delivery_state SET state = target WHERE msg_id = ? AND state IN (...)`.
    /// C6.4-F: the state predicate is the load-bearing CAS guard. C6.4.1-A:
    /// production builds this UNCONDITIONALLY; the test-only
    /// `MutatedDeliveryRepository` rebuilds it without the state predicate to
    /// prove it is load-bearing.
    private func transitionSql(target: DeliveryState, validFroms: [DeliveryState]) -> String {
        let codes = validFroms.map { String($0.code) }.joined(separator: ",")
        return "UPDATE \(StoreSchema.deliveryTable) " +
            "SET \(StoreSchema.colDState) = \(target.code) " +
            "WHERE \(StoreSchema.colDMsgId) = ? AND \(StoreSchema.colDState) IN (\(codes))"
    }

    /// `UPDATE delivery_state SET state = ACKNOWLEDGED WHERE msg_id = ? AND state
    /// IN (QUEUED, HANDED) AND ack_mode = SINGLE_RECIPIENT AND expected_recipient = ?`.
    /// C6.4-H: state + mode + the EXACT durable recipient in ONE WHERE clause; the
    /// recipient is ALWAYS bound (bind slot 2). C6.4.1-A: production builds this
    /// UNCONDITIONALLY; the test-only `MutatedDeliveryRepository` rebuilds it minus
    /// a predicate to prove each is load-bearing.
    private func acknowledgeBoundSql() -> String {
        return "UPDATE \(StoreSchema.deliveryTable) " +
            "SET \(StoreSchema.colDState) = \(DeliveryState.acknowledgedByRecipient.code) " +
            "WHERE \(StoreSchema.colDMsgId) = ? " +
            "AND \(StoreSchema.colDState) IN (\(DeliveryState.queuedDurably.code), \(DeliveryState.handedToRelay.code)) " +
            "AND \(StoreSchema.colDAckMode) = \(AckMode.singleRecipient.rawValue) " +
            "AND \(StoreSchema.colDExpected) = ?"
    }

    // --- C6.4-F/H: zero-row CAS reclassification ----------------------------

    /// Classify a 0-row transition CAS (C6.4-F): re-read ONCE.
    ///  * notFound -> `.unknownMessage`;
    ///  * corrupt -> `.corrupt`; storageFailure -> `.storageFailure`;
    ///  * state == target -> `.alreadyInTarget`;
    ///  * state in validFroms -> `.storageFailure` (invariant violation -- the
    ///    guarded SQL should have matched; only reachable under a weakened-state
    ///    mutation (test-only) or a raced same-microsecond write);
    ///  * any other legal durable state -> `.rejectedState`.
    /// C6.4.1-A: `internal` so the test-only `MutatedDeliveryRepository` reuses
    /// the exact reclassification (no duplication / no drift).
    internal func classifyZeroRowTransition(msgId: Data, target: DeliveryState,
                                            validFroms: [DeliveryState]) -> TransitionResult {
        switch get(msgId) {
        case .notFound: return .unknownMessage
        case .corrupt: return .corrupt
        case .storageFailure: return .storageFailure
        case .invalidArgument: return .invalidArgument // unreachable
        case .found(let rec):
            let s = rec.state
            if s == target { return .alreadyInTarget }
            if validFroms.contains(s) { return .storageFailure } // SQL should have matched
            return .rejectedState
        }
    }

    /// Classify a 0-row ACK CAS (C6.4-H): re-read ONCE. The tracker ALREADY
    /// authenticated this ACK before calling `acknowledgeBound`, so a same-binding
    /// ACKNOWLEDGED row is a legitimate `.duplicateAuthenticatedAck` (the ACK lost
    /// the CAS to another authenticated ACK), NOT a re-verification.
    ///  * notFound -> `.unknownMessage`;
    ///  * corrupt -> `.corrupt`; storageFailure -> `.storageFailure`;
    ///  * binding changed (ack_mode or recipient differ) -> `.unknownMessage`
    ///    (an old ACK must NEVER bind to a re-bound row);
    ///  * state == acknowledged + same binding -> `.duplicateAuthenticatedAck`;
    ///  * state == expired / cancelled -> `.rejectedState`;
    ///  * same binding + queued/handed still present -> `.storageFailure`
    ///    (invariant violation -- the guarded SQL should have matched; only
    ///    reachable under a weakened-predicate mutation (test-only));
    ///  * any other state -> `.rejectedState`.
    /// C6.4.1-A: `internal` so the test-only `MutatedDeliveryRepository` reuses
    /// the exact reclassification (no duplication / no drift).
    internal func classifyZeroRowAck(msgId: Data, expectedRecipient: Data) -> AckResult {
        switch get(msgId) {
        case .notFound: return .unknownMessage
        case .corrupt: return .corrupt
        case .storageFailure: return .storageFailure
        case .invalidArgument: return .invalidArgument // unreachable
        case .found(let rec):
            let sameBinding = rec.ackMode == .singleRecipient &&
                rec.expectedRecipientNodeId == expectedRecipient
            if !sameBinding {
                return .unknownMessage // old ACK must never bind to a re-bound row
            }
            switch rec.state {
            case .acknowledgedByRecipient: return .duplicateAuthenticatedAck
            case .expired, .cancelledLocally: return .rejectedState
            case .queuedDurably, .handedToRelay: return .storageFailure // SQL should have matched
            default: return .rejectedState
            }
        }
    }

    // --- enqueue classification --------------------------------------------

    private func classifyExisting(msgId: Data, ackMode: AckMode,
                                  expectedRecipient: Data?) -> EnqueueResult {
        switch get(msgId) {
        case .found(let rec):
            return classifyExisting(rec: rec, ackMode: ackMode, expectedRecipient: expectedRecipient)
        case .notFound: return .storageFailure // row vanished -- storage anomaly
        case .corrupt: return .corrupt
        case .storageFailure: return .storageFailure
        case .invalidArgument: return .invalidArgument // unreachable
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