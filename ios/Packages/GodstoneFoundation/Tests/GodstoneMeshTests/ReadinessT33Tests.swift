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
    // ================================================================================================
    // *** GS-STORE-005 (round 583): RELEASE UNDER THE CLOSE PATH, AND REGISTRATION UNDER CONCURRENCY. ***
    //
    // THE CARD'S REMAINING WORK, VERBATIM: *"Inspect all quota namespaces, reserve-before-admit limits, postcommit
    // notifications and **release under every close path**."* THE T33 ARMS ABOVE COVER THE QUOTA NAMESPACES,
    // RESERVE-BEFORE-ADMIT AND THE POST-COMMIT DEFERRAL. **RELEASE UNDER THE CLOSE PATH HAD NO ARM AT ALL** -- a grep
    // of this file for `close()` returned NOTHING.
    //
    // *** AND THE PROPERTY IS NOT DECORATIVE: A CLOSED STORE THAT STILL HOLDS CALLBACKS WOULD FIRE THEM AGAINST A
    // DATABASE HANDLE IT HAS ALREADY RELEASED (`sqlite3_close_v2` runneth in the same method). ***
    // ================================================================================================

    /**
     * *** CLOSING RELEASETH EVERY REGISTRATION -- AND THE CENSUS SAITH SO. ***
     *
     * `ObservationLease.registrationCount` IS the observable truth (registrations PLUS deferred), so this arm readeth
     * a NUMBER rather than trusting that `releaseAll()` was called. **AND IT EXERCISES BOTH KINDS OF REGISTRATION:
     * the IMMEDIATE one and the DEFERRED one taken during a transaction** -- because `releaseAll()` must clear both
     * arrays, and an implementation that cleared only `registrations` would leak every registration made inside a
     * transaction, which is precisely where the store's own notifications are taken.
     */
    func testGSSTORE005ClosingReleasesEveryRegistrationIncludingDeferredOnes() throws {
        let lease = ObservationLease()

        lease.register { }
        lease.register { }
        XCTAssertEqual(lease.registrationCount, 2, "two immediate registrations must be visible in the census")

        // AND THE DEFERRED KIND: taken DURING a transaction, so it sitteth in the OTHER array.
        lease.beginTransaction()
        lease.register { }
        lease.register { }
        XCTAssertEqual(
            lease.registrationCount, 4,
            "*** A REGISTRATION MADE DURING A TRANSACTION IS DEFERRED, AND THE CENSUS COUNTS BOTH ARRAYS -- " +
                "otherwise an implementation clearing only one would look correct here. Observed: " +
                "\(lease.registrationCount) ***",
        )

        lease.releaseAll()
        XCTAssertEqual(
            lease.registrationCount, 0,
            "*** CLOSING MUST RELEASE **EVERY** REGISTRATION, DEFERRED ONES INCLUDED: a closed store that still " +
                "holdeth callbacks would fire them against a database handle it has already released. " +
                "Observed: \(lease.registrationCount) ***",
        )
    }

    /**
     * *** AND A RELEASED TOKEN IS INERT -- THE OTHER HALF OF "RELEASE", MEASURED BY EFFECT RATHER THAN BY COUNT. ***
     *
     * The census falling to zero proveth the arrays were cleared; **THIS ARM PROVETH THE CALLBACK CANNOT FIRE
     * AFTERWARDS**, which is the property that actually protecteth against the use-after-close. The counter is the
     * witness: it must stay put across a dispatch that would otherwise fire the released observer.
     */
    func testGSSTORE005AReleasedObserverNeverFiresAgain() throws {
        let lease = ObservationLease()
        var fired = 0

        let doomed = lease.register { fired += 1 }
        let survivor = lease.register { fired += 1 }

        lease.unregisterBy(doomed)
        lease.afterCommit()                      // WOULD FIRE EVERY LIVE OBSERVER

        XCTAssertEqual(
            fired, 1,
            "*** ONLY THE SURVIVING OBSERVER MAY FIRE: the released one must be INERT, or a released observer would " +
                "keep firing against a store that no longer standeth. Observed firings: \(fired) ***",
        )

        lease.unregisterBy(survivor)
        lease.afterCommit()
        XCTAssertEqual(
            fired, 1,
            "*** AND WITH EVERY TOKEN RELEASED, A DISPATCH MUST FIRE NOTHING AT ALL. Observed: \(fired) ***",
        )
    }

    /**
     * *** REGISTRATION DURING A DISPATCH IS DEFERRED, NOT REENTRANT -- THE CARD'S "POSTCOMMIT NOTIFICATIONS". ***
     *
     * A callback that registereth ANOTHER observer while the dispatch loop is walking the list must NOT have it fire
     * in the SAME round: the loop walketh a SNAPSHOT, and a reentrant append would either fire it immediately
     * (surprising the caller) or mutate the list under the walk. **THE OBSERVABLE CLAIM: THE SECOND OBSERVER FIRES
     * ONLY ON THE NEXT DISPATCH.**
     */
    func testGSSTORE005ARegistrationDuringDispatchFiresOnTheNextRoundOnly() throws {
        let lease = ObservationLease()
        var innerFired = 0
        var outerFired = 0

        lease.register {
            outerFired += 1
            lease.register { innerFired += 1 }        // REGISTERED WHILE DISPATCHING
        }
        lease.afterCommit()

        XCTAssertEqual(outerFired, 1, "the outer observer fires on this round")
        XCTAssertEqual(
            innerFired, 0,
            "*** AN OBSERVER REGISTERED **DURING** A DISPATCH MUST NOT FIRE IN THE SAME ROUND: the loop walketh a " +
                "snapshot, and firing into it mid-walk is the reentrancy the lease existeth to prevent. Observed: " +
                "\(innerFired) ***",
        )

        lease.afterCommit()
        XCTAssertEqual(
            innerFired, 1,
            "*** AND IT MUST FIRE ON THE NEXT ROUND -- otherwise a registration made during a dispatch would never " +
                "fire at all, which would be a silent loss rather than a deferral. Observed: \(innerFired) ***",
        )
    }

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
        // bounded-cursor law (the cards required bounded cursor reads): fetchPage respects its limit and never over-reads the backing
        let backing = ["r0", "r1", "r2", "r3", "r4"]
        XCTAssertLessThanOrEqual(StoreQuota.fetchPage(backing, start: 0, limit: 2).count, 2, "a page never exceeds its limit")
        XCTAssertEqual(StoreQuota.fetchPage(backing, start: 0, limit: 3), ["r0", "r1", "r2"], "a bounded page reads exactly the limit many rows")
        XCTAssertEqual(StoreQuota.fetchPage(backing, start: 3, limit: 10), ["r3", "r4"], "a page reads the residual tail when the limit would overrun")
        XCTAssertLessThanOrEqual(StoreQuota.fetchPage(backing, start: 0, limit: 99).count, backing.count, "the cursor never reads past the backing")
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
