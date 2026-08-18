import Foundation
@testable import GodstoneMesh

// C6.4.1-A / C7.4.1 -- TEST-ONLY mutation-control repository (iOS twin of the Android
// `MutatedDeliveryRepository`). Lives in TEST source; NOT compiled into any
// shipping build. Production `SqliteDeliveryRepository` builds its CAS WHERE
// clause UNCONDITIONALLY and atomically deletes the held frame within a transaction.
// This class rebuilds the WEAKENED SQL (a guard dropped) and optionally skips held
// retirement to PROVE each predicate and the held retirement are load-bearing:
// with a guard off or retirement skipped, the WRONG outcome results, so the
// production implementation (always on) is what makes the concurrency guarantees
// hold. `ci/no_delivery_guard_bypass.py` fails the build if a guard-bypass
// token re-enters a main-source directory, so this class can NEVER migrate
// into production by accident.
//
// Reads / enqueue / clear delegate to a production `SqliteDeliveryRepository`
// over the SAME store; only `transition` / `acknowledgeBoundAndRetire` are weakened.
// The 0-row CAS reclassification and the lifecycle truth-table are reused from the
// production repo (`internal` `transitionMapping` / `classifyZeroRowTransition`
// / `classifyZeroRowAck`), so the weakened repo and the production repo
// classify identical inputs identically -- no duplicated classification logic
// to drift.
final class MutatedDeliveryRepository: DeliveryRepository {
    private let strong: SqliteDeliveryRepository
    private let store: DeliveryStore
    private let stateGuard: Bool
    private let modeGuard: Bool
    private let recipientGuard: Bool
    private let skipHeldRetirement: Bool

    init(
        _ store: DeliveryStore,
        stateGuard: Bool = true,
        modeGuard: Bool = true,
        recipientGuard: Bool = true,
        skipHeldRetirement: Bool = false
    ) {
        self.store = store
        self.strong = SqliteDeliveryRepository(store)
        self.stateGuard = stateGuard
        self.modeGuard = modeGuard
        self.recipientGuard = recipientGuard
        self.skipHeldRetirement = skipHeldRetirement
    }

    public func get(_ msgId: Data) -> DeliveryLookup { strong.get(msgId) }

    public func enqueue(_ msgId: Data, ackMode: AckMode, expectedRecipient: Data?) -> EnqueueResult {
        strong.enqueue(msgId, ackMode: ackMode, expectedRecipient: expectedRecipient)
    }

    public func clear(_ msgId: Data) -> ClearResult { strong.clear(msgId) }

    public func transition(_ msgId: Data, _ transition: DeliveryTransition) -> TransitionResult {
        guard msgId.count == 16 else { return .invalidArgument }
        let (target, validFroms) = strong.transitionMapping(transition)
        let sql = transitionSql(target: target, validFroms: validFroms)
        if transition == .markHanded || skipHeldRetirement {
            do {
                let affected = try store.execDeliveryUpdate(sql, bytesArgs: [msgId])
                switch affected {
                case 1: return .applied
                case 0: return strong.classifyZeroRowTransition(msgId: msgId, target: target, validFroms: validFroms)
                default: return .storageFailure
                }
            } catch {
                return .storageFailure
            }
        }
        do {
            let res = try store.atomicTransitionAndRetire(
                guardedTransitionSql: sql,
                msgId: msgId
            )
            switch res {
            case .applied: return .applied
            case .noMatch: return strong.classifyZeroRowTransition(msgId: msgId, target: target, validFroms: validFroms)
            case .missingHeld: return .corrupt
            }
        } catch {
            return .storageFailure
        }
    }

    public func acknowledgeBoundAndRetire(_ msgId: Data, expectedRecipient: Data) -> AckResult {
        guard msgId.count == 16 else { return .invalidArgument }
        guard expectedRecipient.count == 16 else { return .invalidArgument }
        let sql = acknowledgeBoundSql()
        let bindArgs: [Data?] = recipientGuard ? [msgId, expectedRecipient] : [msgId]
        do {
            if skipHeldRetirement {
                let affected = try store.execDeliveryUpdate(sql, bytesArgs: bindArgs)
                switch affected {
                case 1: return .applied
                case 0: return strong.classifyZeroRowAck(msgId: msgId, expectedRecipient: expectedRecipient)
                default: return .storageFailure
                }
            } else {
                let res = try store.atomicAcknowledgeAndRetire(
                    guardedAckSql: sql,
                    msgId: msgId,
                    expectedRecipient: expectedRecipient
                )
                switch res {
                case .applied: return .applied
                case .noMatch: return strong.classifyZeroRowAck(msgId: msgId, expectedRecipient: expectedRecipient)
                case .missingHeld: return .corrupt
                }
            }
        } catch {
            return .storageFailure
        }
    }

    // MARK: - weakened CAS SQL builders (mirror the removed pre-C6.4.1 builders)

    private func transitionSql(target: DeliveryState, validFroms: [DeliveryState]) -> String {
        var sql = "UPDATE \(StoreSchema.deliveryTable) " +
            "SET \(StoreSchema.colDState) = \(target.code) " +
            "WHERE \(StoreSchema.colDMsgId) = ?"
        if stateGuard {
            let codes = validFroms.map { String($0.code) }.joined(separator: ",")
            sql += " AND \(StoreSchema.colDState) IN (\(codes))"
        }
        return sql
    }

    private func acknowledgeBoundSql() -> String {
        var sql = "UPDATE \(StoreSchema.deliveryTable) " +
            "SET \(StoreSchema.colDState) = \(DeliveryState.acknowledgedByRecipient.code) " +
            "WHERE \(StoreSchema.colDMsgId) = ?"
        if stateGuard {
            sql += " AND \(StoreSchema.colDState) IN (\(DeliveryState.queuedDurably.code), \(DeliveryState.handedToRelay.code))"
        }
        if modeGuard {
            sql += " AND \(StoreSchema.colDAckMode) = \(AckMode.singleRecipient.rawValue)"
        }
        if recipientGuard {
            sql += " AND \(StoreSchema.colDExpected) = ?"
        }
        return sql
    }
}