import Foundation
@testable import GodstoneMesh

// C6.4.1-A -- TEST-ONLY mutation-control repository (iOS twin of the Android
// `MutatedDeliveryRepository`). Lives in TEST source; NOT compiled into any
// shipping build. Production `SqliteDeliveryRepository` builds its CAS WHERE
// clause UNCONDITIONALLY -- there is no production API to drop the state / mode
// / recipient predicate. This class rebuilds the WEAKENED SQL (a guard dropped)
// to PROVE each predicate is load-bearing: with the guard off the WRONG outcome
// results, so the production predicate (always on) is what makes the concurrency
// guarantees hold. `ci/no_delivery_guard_bypass.py` fails the build if a
// guard-bypass token re-enters a main-source directory, so this class can NEVER
// migrate into production by accident.
//
// Reads / enqueue / clear delegate to a production `SqliteDeliveryRepository`
// over the SAME store; only `transition` / `acknowledgeBound` are weakened. The
// 0-row CAS reclassification and the lifecycle truth-table are reused from the
// production repo (`internal` `transitionMapping` / `classifyZeroRowTransition`
// / `classifyZeroRowAck`), so the weakened repo and the production repo
// classify identical inputs identically -- no duplicated classification logic
// to drift. The weakened SQL builders below mirror the PRE-C6.4.1 guarded
// builders that were removed from production; a guard=false drops its
// predicate (the exact mutation each C6.4-M test exercises).
final class MutatedDeliveryRepository: DeliveryRepository {
    private let strong: SqliteDeliveryRepository
    private let store: DeliveryStore
    private let stateGuard: Bool
    private let modeGuard: Bool
    private let recipientGuard: Bool

    init(_ store: DeliveryStore,
         stateGuard: Bool = true, modeGuard: Bool = true, recipientGuard: Bool = true) {
        self.store = store
        self.strong = SqliteDeliveryRepository(store)
        self.stateGuard = stateGuard
        self.modeGuard = modeGuard
        self.recipientGuard = recipientGuard
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

    public func acknowledgeBoundAndRetire(_ msgId: Data, expectedRecipient: Data) -> AckResult {
        guard msgId.count == 16 else { return .invalidArgument }
        guard expectedRecipient.count == 16 else { return .invalidArgument }
        let sql = acknowledgeBoundSql()
        // Recipient bind slot is present ONLY when recipientGuard is on (mirrors the
        // pre-C6.4.1 guarded builder).
        let bindArgs: [Data?] = recipientGuard ? [msgId, expectedRecipient] : [msgId]
        do {
            let affected = try store.execDeliveryUpdate(sql, bytesArgs: bindArgs)
            switch affected {
            case 1: return .applied
            case 0: return strong.classifyZeroRowAck(msgId: msgId, expectedRecipient: expectedRecipient)
            default: return .storageFailure
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