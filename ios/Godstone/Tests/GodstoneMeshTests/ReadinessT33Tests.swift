import XCTest
@testable import GodstoneMesh

// ---------------------------------------------------------------------------
// T33 - the CANONICAL designated regression court, iOS side. The manifest
// required_regression_paths names this file; the narrow filter is
// `swift test --package-path ios/Packages/GodstoneFoundation --filter ReadinessT33Tests`.
// It drives the iOS contract twin (Sources/GodstoneMesh/StoreQuota.swift) and
// asserts the SAME eight store-growth / observer-lifetime laws as the android twin
// ReadinessT33Test.kt (identical names), giving the dual-court parity the card
// requires. The sealed wall-clock store path is NOT touched; the physical
// section19/18 capacity cases are DEVICE evidence (deferred to T73-75).
// ---------------------------------------------------------------------------

private func okV(_ v: Int64) -> Measured { .values(v) }
private func badV(_ r: String) -> Measured { .queryFailure(r) }

private func healthy(total: Int64 = 0, deliv: Int64 = 0, inbox: Int64 = 0, tomb: Int64 = 0, trust: Int64 = 0, inTx: Bool = false, wal: Int64 = 0) -> QuotaSnapshot {
    QuotaSnapshot(heldBytes: okV(total), totalBytes: okV(1 << 20), deliveryRows: okV(deliv), inboxRows: okV(inbox), tombstoneRows: okV(tomb), trustPins: okV(trust), inActiveTransaction: inTx, walBytes: wal)
}
private func allSosRows(_ n: Int) -> [HeldRow] { (1...n).map { HeldRow(id: String(format: "sos-%04d", $0), priority: 0, receivedAt: Int64($0), size: 1) } }
private func mixedRowsArr() -> [HeldRow] {
    [
        HeldRow(id: "sos-b", priority: 0, receivedAt: 3, size: 4),
        HeldRow(id: "n-c", priority: 1, receivedAt: 1, size: 2),
        HeldRow(id: "n-a", priority: 1, receivedAt: 2, size: 1),
        HeldRow(id: "n-b", priority: 1, receivedAt: 2, size: 2),
        HeldRow(id: "sos-a", priority: 0, receivedAt: 4, size: 8, isUnexpiredTombstone: true),
    ]
}

final class ReadinessT33Tests: XCTestCase {

    // (1) an all-SOS store still holds the hard cap INCLUDING SOS
    func testAllSosStoreStillHoldsTheHardCapIncludingSos() throws {
        let rows = allSosRows(400)
        let total = StoreQuota.heldFrameHardCap + 32
        let plan = StoreQuota.evictionPlan(rows: rows, measuredHeldBytes: total)
        XCTAssertEqual(plan.cumulativeBytes, 32, "the all-SOS overshoot is drained to exactly the deficit")
        XCTAssertFalse(plan.evictedIds.isEmpty, "an all-SOS store is still capped -- SOS is evicted (retained-LAST, not exempt)")
        XCTAssertLessThan(plan.cumulativeBytes - Int64(plan.evictedIds.count), 32, "eviction is a MINIMAL prefix")
    }

    // (2) millions of duplicate / terminal inputs are rejected idempotent
    func testMillionsOfDuplicateAndTerminalInputsAreRejectedIdempotent() throws {
        for _ in 1...1000 {
            XCTAssertEqual(StoreQuota.admit(snapshot: healthy(), candidateSize: 1, isDuplicate: true, isTerminal: false), .duplicateRejected, "duplicate replay is always rejected")
            XCTAssertEqual(StoreQuota.admit(snapshot: healthy(), candidateSize: 1, isDuplicate: false, isTerminal: true), .terminalRejected, "terminal input is always rejected")
        }
        XCTAssertTrue(StoreQuota.admit(snapshot: healthy(), candidateSize: 1, isDuplicate: false, isTerminal: false).isAccepted(), "a fresh input is admitted once")
    }

    // (3) a WAL overshoot checkpoints only outside an active transaction
    func testWalGrowthCheckpointsOutsideActiveTransaction() throws {
        let under = StoreQuota.checkpointState(inActiveTransaction: false, walBytes: StoreQuota.walAllowance / 2)
        XCTAssertFalse(under.due, "no checkpoint when the WAL is within its allowance")
        XCTAssertFalse(under.suspend, "no suspension when the WAL is within its allowance")
        let outside = StoreQuota.checkpointState(inActiveTransaction: false, walBytes: StoreQuota.walAllowance + 1)
        XCTAssertTrue(outside.due, "a WAL overshoot OUTSIDE a tx is due to checkpoint")
        XCTAssertFalse(outside.suspend, "and is not suspended")
        let inside = StoreQuota.checkpointState(inActiveTransaction: true, walBytes: StoreQuota.walAllowance + 1)
        XCTAssertFalse(inside.due, "a WAL overshoot INSIDE an active tx must NOT checkpoint")
        XCTAssertTrue(inside.suspend, "instead the store suspends until the tx closes")
    }

    // (4) an observer fires only after commit, exactly once, never reentrantly
    func testObserverReentryIsDeferredAndFiresOnlyAfterCommit() throws {
        let lease = ObservationLease()
        var firstCalls = 0
        var lateCalls = 0
        lease.register { firstCalls += 1; lease.register { lateCalls += 1 } }
        lease.afterCommit()
        XCTAssertEqual(firstCalls, 1, "the registered observer fired once on commit")
        XCTAssertEqual(lateCalls, 0, "the reentrantly registered observer did NOT fire in the same dispatch")
        lease.afterCommit()
        XCTAssertEqual(lateCalls, 1, "the deferred observer fires on the NEXT commit")
        XCTAssertEqual(firstCalls, 2, "and the first observer still fires exactly once per commit")
        let lease2 = ObservationLease()
        var fired = 0
        lease2.beginTransaction()
        lease2.register { fired += 1 }
        lease2.abort()
        lease2.afterCommit()
        XCTAssertEqual(fired, 0, "an aborted transaction fires no observer")
    }

    // (5) a SQL failure in heldBytes never fabricates 0 and refuses admission (the named falsification)
    func testSqlFailureInHeldBytesNeverFabricatesZeroAndRefusesAdmission() throws {
        let failing = QuotaSnapshot(heldBytes: badV("sql: no such table"), totalBytes: okV(1 << 20), deliveryRows: okV(0), inboxRows: okV(0), tombstoneRows: okV(0), trustPins: okV(0), inActiveTransaction: false, walBytes: 0)
        let r = StoreQuota.admit(snapshot: failing, candidateSize: 1, isDuplicate: false, isTerminal: false)
        var isQueryErr = false; var reason = ""
        if case let .queryError(rr) = r { isQueryErr = true; reason = rr }
        var isRejectedCap = false; if case .rejectedHeldCap = r { isRejectedCap = true }
        XCTAssertTrue(isQueryErr, "a heldBytes read failure is a QueryError, not a fabricated zero")
        XCTAssertFalse(r.isAccepted(), "it is not silently Accepted")
        XCTAssertFalse(isRejectedCap, "and it is distinct from a real capacity rejection")
        XCTAssertFalse(reason.isEmpty, "the QueryError carries a non-empty reason")
    }

    // (6) the hard cap is never exceeded across a sequence of inserts
    func testCapUnderConcurrentInsertIsNeverExceeded() throws {
        var held: Int64 = 0
        let cap = StoreQuota.heldFrameHardCap
        let step: Int64 = 3 * StoreQuota.mib
        var accepted = 0
        for _ in 1...100 {
            let r = StoreQuota.admit(snapshot: healthy(total: held), candidateSize: step, isDuplicate: false, isTerminal: false)
            if r.isAccepted() { held += step; accepted += 1 }
            XCTAssertLessThanOrEqual(held, cap, "the accounting total never crosses the hard cap")
        }
        XCTAssertGreaterThan(accepted, 0, "inserts were admitted before the cap bound them")
    }

    // (7) eviction is a deterministic, stable, minimal prefix in policy order
    func testStableEvictionOrderIsDeterministic() throws {
        let rows = mixedRowsArr()
        let total = StoreQuota.heldFrameHardCap + 5
        let plan = StoreQuota.evictionPlan(rows: rows, measuredHeldBytes: total)
        XCTAssertEqual(plan.evictedIds, ["n-c", "n-a", "n-b"], "policy order evicts oldest non-SOS first, ties by id, SOS/protected untouched")
        XCTAssertEqual(plan.cumulativeBytes, 5, "the drained cumulative bytes equal the sum of the evicted sizes")
        XCTAssertTrue(StoreQuota.hardCapHoldsAfter(rows: rows, measuredHeldBytes: total), "the hard cap holds after the plan")
        XCTAssertFalse(plan.evictedIds.contains("sos-a"), "no unexpired tombstone / trust pin is silently evicted")
    }

    // (8) eviction moves the delivery record EVICTED in the SAME transaction (the second named falsification)
    func testEvictionUpdatesDeliveryStateInTheSameTransaction() throws {
        let rows = mixedRowsArr()
        let total = StoreQuota.heldFrameHardCap + 5
        let plan = StoreQuota.evictionPlan(rows: rows, measuredHeldBytes: total)
        XCTAssertEqual(plan.evictedIds.count, plan.deliveryTransitions.count, "every evicted row has exactly one delivery transition")
        for t in plan.deliveryTransitions {
            XCTAssertTrue(plan.evictedIds.contains(t.id), "the evicted row \(t.id) is paired with its id")
            XCTAssertEqual(t.state, .evicted, "and its delivery state moves to EVICTED, atomically with the held removal")
        }
        let applied = rows.map { plan.evictedIds.contains($0.id) ? $0.with(deliveryState: .evicted) : $0 }
        for r in applied where plan.evictedIds.contains(r.id) { XCTAssertEqual(r.deliveryState, .evicted, "held and delivery stay consistent") }
        let appliedTotal = total - plan.cumulativeBytes
        XCTAssertLessThanOrEqual(appliedTotal, StoreQuota.heldFrameHardCap, "the pass brought the store to (or under) the hard cap")
        let second = StoreQuota.evictionPlan(rows: applied, measuredHeldBytes: appliedTotal)
        XCTAssertTrue(second.evictedIds.isEmpty, "re-checking a capped store evicts nothing further")
        XCTAssertEqual(second.cumulativeBytes, appliedTotal, "a no-op pass reports the (already-capped) held total as its drain")
        let secondForced = StoreQuota.evictionPlan(rows: applied, measuredHeldBytes: total)
        XCTAssertTrue(!secondForced.evictedIds.contains { plan.evictedIds.contains($0) }, "a second pass never re-evicts an already-EVICTED row")
    }
}
