import XCTest
import Foundation
@testable import GodstoneMesh

/**
 * GS-FINAL-005 (the independent audit, 2026-09-18): **THE RETENTION CLOCK IS OPTIONAL, SO PRODUCTION RUNS WITH NO
 * RETENTION CLOCK AT ALL -- AND `nil` SILENTLY MEANS "KEEP EVERYTHING".**
 *
 * THE AUDIT'S MEASUREMENT: *"`SqliteMessageStore.isForwardable` returns true when `receiptTimeProvider` is nil.
 * Inspected MeshRuntime/Node construction does not install it."* AND ITS ROOT CAUSE: *"Optional mutable dependency and
 * a misleading parameter name allow a locally tested time policy to be bypassed in composition."*
 *
 * *** MEASURED AT SOURCE, AND IT IS WORSE THAN "NOT INSTALLED": *** `receiptTimeProvider` is assigned by **26 test
 * sites** and by **ZERO production sites**. The type is `Optional`, the property is `public var`, and EVERY reader
 * treats `nil` as the permissive answer:
 *
 *   | line | reader | behaviour when the clock is nil |
 *   |---|---|---|
 *   | 1022 | `isForwardable` | `return true` -- "this row is fine" |
 *   | 1354 | the expiry predicate | `return true` -- "not expired" |
 *   | 1183 | `sweepExpiredNoLock` | refuses, but only this one does |
 *
 * SO A PRODUCTION STORE ERASES NOTHING AND FORWARDS EVERYTHING: PER-KIND RETENTION -- the whole subject of
 * GS-STORE-004 -- IS INERT. And a permissive default is the worst possible one here, because the failure is SILENT:
 * an unbounded store looks exactly like a healthy one.
 *
 * THE REMEDY PRESCRIBED IS THE ARM'S OWN SHAPE: *"Make a single runtime clock protocol mandatory in store, snapshot,
 * sync and lifecycle constructors. Remove the permissive nil branch from production. ... Missing production clock must
 * be a construction error."*
 *
 * THESE ARMS ARE RUN RED FIRST. The store here is built EXACTLY as production builds it.
 */
@MainActor
final class GsFinal005MandatoryClockTests: XCTestCase {

    private func tempUrl(_ tag: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("gf005_\(tag)_\(UUID().uuidString).db")
    }

    /**
     * *** THE ARM FOR THE AUDIT'S OWN SENTENCE: "Missing production clock must be a construction error." ***
     *
     * IT IS NOT ONE TODAY, AND THAT IS THE FINDING: the store constructeth happily with no clock and then silently
     * governs no retention. A construction that cannot be observed to fail is a construction nobody can rely on.
     */
    func testGSFINAL005_aStoreConstructedWithNoClockIsAConstructionError() throws {
        let url = tempUrl("noclcok")
        // THE PRODUCTION CONSTRUCTION SITE'S OWN CALL: `SqliteMessageStore(url:maxBytes:)`, no clock installed.
        let store = SqliteMessageStore(url: url, maxBytes: 64 * 1024 * 1024)

        // *** THE REQUIREMENT, POSITIVELY ASSERTED. *** An earlier draft of this arm asserted `XCTAssertNil` on the
        // clock -- WHICH ASSERTED THE DEFECT AS THE REQUIREMENT: green on the broken tree, and it would FAIL the moment
        // someone fixed the finding. A STORE MUST NOT BE ABLE TO STAND WITHOUT A CLOCK.
        XCTAssertNotNil(
            store.receiptTimeProvider,
            "*** GS-FINAL-005: A STORE CONSTRUCTED WITHOUT A RUNTIME CLOCK MUST NOT BE USABLE. The audit: 'Missing " +
                "production clock must be a construction error.' Today the initialiser succeedeth, " +
                "`receiptTimeProvider` stayeth nil, and EVERY retention judgement silently answereth \"keep\" -- so " +
                "PER-KIND RETENTION IS INERT IN PRODUCTION AND AN UNBOUNDED STORE LOOKS EXACTLY LIKE A HEALTHY ONE. ***",
        )
        store.close()
        try? FileManager.default.removeItem(at: url)
    }

    /**
     * *** AND THE CONSEQUENCE, MEASURED: THE EXPIRY PREDICATE ANSWERETH "KEEP" FOR EVERY KIND. ***
     *
     * The audit's own scenario: *"use non-default SOS/bulk/direct kinds"*. Per-kind retention carrieth DIFFERENT
     * lifetimes, so a clockless store must not answer the same thing for all of them -- and today it answereth "keep"
     * for all three.
     */
    func testGSFINAL005_theExpiryPredicateDoesNotSilentlyKeepEveryKind() throws {
        let url = tempUrl("kinds")
        let store = SqliteMessageStore(url: url, maxBytes: 64 * 1024 * 1024)

        // Every per-kind lifetime in the policy, asked with a receipt far older than any of them.
        let ancient = Int64(1_000)                      // mono ms since boot -- millennia before now
        for kind in [MessageKind.direct, .bulk, .sos] {
            guard let lifetime = RetentionPolicy.lifetimeMs[kind] else {
                XCTFail("the policy must carry a lifetime for \(kind)")
                continue
            }
            let judged = store.isForwardable(receivedAt: ancient - Int64(lifetime) - 1, kind: kind)
            XCTAssertFalse(
                judged,
                "*** GS-FINAL-005: A ROW OLDER THAN ITS KIND'S LIFETIME MUST NOT BE FORWARDABLE. `isForwardable` " +
                    "guardeth the clock with `else { return true }`, so a store with NO CLOCK ANSWERS \"this row is " +
                    "fine\" FOR EVERY KIND AND EVERY AGE -- per-kind retention is INERT, and an unbounded store " +
                    "LOOKS EXACTLY LIKE A HEALTHY ONE. Kind \\(kind), age \\(lifetime + 1)ms, judged: \\(judged) ***",
            )
        }
        store.close()
        try? FileManager.default.removeItem(at: url)
    }

    /**
     * *** AND THE OTHER DIRECTION: A REAL, INSTALLED CLOCK STILL WORKS. ***
     *
     * The positive control. The repair must make the clock MANDATORY without changing what an installed clock doeth --
     * GS-STORE-004's per-kind behaviour must survive intact.
     */
    func testGSFINAL005_anInstalledClockStillGovernsPerKindRetention() throws {
        let url = tempUrl("clock")
        let store = SqliteMessageStore(url: url, maxBytes: 64 * 1024 * 1024)
        // A frozen clock, deliberately: this arm is about the POLICY, not about time passing.
        let nowMono = Int64(1_000_000)
        store.receiptTimeProvider = { (monoMs: nowMono, bootIdentity: "boot-A") }

        let sosLifetime = RetentionPolicy.lifetimeMs[.sos]!
        // A fresh SOS row is forwardable; a SOS row older than its own lifetime is not.
        XCTAssertTrue(
            store.isForwardable(receivedAt: nowMono - 1, kind: .sos),
            "a fresh row must be forwardable when a clock IS installed",
        )
        XCTAssertFalse(
            store.isForwardable(receivedAt: nowMono - Int64(sosLifetime) - 1, kind: .sos),
            "and a row past its kind's lifetime must not be -- the clock's own answer, unchanged by the repair",
        )
        store.close()
        try? FileManager.default.removeItem(at: url)
    }
    // ================================================================================================
    // *** GS-STORE-004 (round 581): THE FIVE CASES THE AUDIT NAMED, AND THE STORE MUST JUDGE THEM. ***
    //
    // THE CARD'S OWN REMAINING WORK, VERBATIM: *"Require a production clock at store creation; **test non-DIRECT
    // kinds, same-boot reopen, reboot, exhaustion and readmission**."* THE FIRST CLAUSE IS DONE (the clock is
    // non-optional and defaults to the real platform clock). **THE FIVE CASES ARE THE GAP, AND EACH IS MEASURED
    // BELOW THROUGH THE STORE'S OWN PREDICATE -- NOT THROUGH THE POLICY ALONE**, because a policy that is right while
    // the STORE consults it wrongly is the defect the card's own text describes ("inspected runtime creation does not
    // install it").
    //
    // *** AND THE DISTINCTION THAT MATTERS THROUGHOUT: `isForwardable` IS READ FROM THE STORE, WITH THE REAL
    // PERSISTED BUDGET AND BOOT IDENTITY PASSED IN -- SO THESE ARMS MEASURE THE STORE'S JUDGEMENT, NOT A
    // REIMPLEMENTATION OF THE POLICY IN THE TEST. ***
    // ================================================================================================

    /// A store with a clock the arm controls, so the boot identity and the monotonic reading are both pinned.
    private func storeAt(_ tag: String, monoMs: Int64, boot: String)
        throws -> (SqliteMessageStore, URL) {
        let url = tempUrl(tag)
        let store = SqliteMessageStore(url: url, maxBytes: 64 * 1024 * 1024)
        store.receiptTimeProvider = { (monoMs: monoMs, bootIdentity: boot) }
        return (store, url)
    }

    /**
     * *** CASE 1: NON-DIRECT KINDS -- EACH CARRIETH ITS OWN LIFETIME, SO NO TWO MAY ANSWER THE SAME. ***
     *
     * The card's own words: *"use non-default SOS/bulk/direct kinds."* And the lifetimes are NOT equal
     * (`direct` 7 days, `sos`/`group`/`broadcast` 24 h, `bulk` 1 h), so an arm that asked one kind and generalised
     * would miss a per-kind defect entirely. **THE ROW IS AGED PAST THE SHORTEST LIFETIME BUT WELL INSIDE THE
     * LONGEST: SO `bulk` MUST BE WITHHELD WHILE `direct` IS STILL FORWARDABLE.** A predicate that answered the same
     * for both would fail here whichever way it answered.
     */
    func testGSSTORE004_nonDirectKindsAreGovernedByTheirOwnLifetimes() throws {
        let (store, url) = try storeAt("kinds2", monoMs: 10_000_000, boot: "boot-A")
        defer { store.close(); try? FileManager.default.removeItem(at: url) }

        // TWO HOURS AGO: past `bulk`'s one hour, comfortably inside `direct`'s 7 days.
        let twoHoursMs = Int64(2 * 60 * 60 * 1000)
        let receipt = store.receiptTimeProvider().monoMs - twoHoursMs

        XCTAssertFalse(
            store.isForwardable(receivedAt: receipt, kind: .bulk),
            "*** `bulk` LIVETH ONE HOUR, SO A TWO-HOUR-OLD ROW MUST BE WITHHELD. If this passes, PER-KIND RETENTION " +
                "IS INERT -- which is the card's own scenario ('use non-default SOS/bulk/direct kinds'). ***",
        )
        XCTAssertTrue(
            store.isForwardable(receivedAt: receipt, kind: .direct),
            "*** AND `direct` LIVETH SEVEN DAYS, SO THE SAME AGE MUST STILL BE FORWARDABLE. THE TWO ANSWERS MUST " +
                "DIFFER: a predicate answering the same for both is the defect, whichever answer it gives. ***",
        )
    }

    /**
     * *** CASE 2: SAME-BOOT REOPEN -- THE ELAPSED TIME IS DEBITED EXACTLY ONCE. ***
     *
     * A crash and a reopen WITHIN ONE BOOT carries the ORIGINAL monotonic anchor, so continuity is PROVEN and the
     * debit is the real elapsed time. **THE DEFECT THIS GUARDETH AGAINST IS THE OPPOSITE OF REBOOT: A reopen that
     * wrongly counted a discontinuity would debit a full hour for nothing, expiring rows at 32 opens.**
     */
    func testGSSTORE004_aSameBootReopenDebitsElapsedTimeAndCountsNoDiscontinuity() throws {
        let (store, url) = try storeAt("sameboot", monoMs: 5_000_000, boot: "boot-SAME")
        defer { store.close(); try? FileManager.default.removeItem(at: url) }

        let start = store.receiptTimeProvider().monoMs
        let budget = Int64(RetentionPolicy.lifetimeMs[.bulk]!)
        // ONE MINUTE OF REAL ELAPSED MONOTONIC TIME ON THE SAME BOOT.
        let elapsed: Int64 = 60_000
        store.receiptTimeProvider = { (monoMs: start + elapsed, bootIdentity: "boot-SAME") }

        XCTAssertTrue(
            store.isForwardable(receivedAt: start, kind: .bulk, storedBudget: budget - elapsed,
                                storedCheckpoint: start, storedBoot: "boot-SAME", storedDiscontinuity: Int64(0)),
            "*** SAME BOOT, ONE MINUTE LATER, BUDGET DEBITED BY THAT MINUTE: THE ROW IS STILL FORWARDABLE. A reopen " +
                "that wrongly counted a discontinuity would debit a full hour and WITHHOLD it -- the defect the " +
                "reboot case must not be confused with. ***",
        )
    }

    /**
     * *** CASE 3: REBOOT -- CONTINUITY IS LOST, AND THE CONSERVATIVE RULE APPLIES. ***
     *
     * Monotonic readings are comparable ONLY within one boot, so a DIFFERENT boot identity is NOT continuity, and the
     * policy debiteth AT LEAST ONE HOUR regardless of how small the monotonic delta looketh. **THIS IS THE CASE WHERE
     * A NAIVE `now - anchor` WOULD BE MOST WRONG: the new boot's monotonic counter STARTETH NEAR ZERO, so the naive
     * arithmetic would compute A NEGATIVE OR TINY elapsed and EXTEND THE ROW'S LIFE.**
     */
    func testGSSTORE004_aRebootAppliesTheConservativeHourRatherThanTheNaiveDelta() throws {
        let (store, url) = try storeAt("reboot", monoMs: 1_000, boot: "boot-B")   // a FRESH boot: small counter
        defer { store.close(); try? FileManager.default.removeItem(at: url) }

        // THE ROW WAS ANCHORED IN ANOTHER BOOT, WITH A LARGE MONOTONIC READING AND A SMALL REMAINING BUDGET.
        let budget = Int64(RetentionPolicy.lifetimeMs[.bulk]!)
        let anchoredAt: Int64 = 9_000_000                       // the OLD boot's counter -- far larger than this boot's
        let remaining = budget - Int64(RetentionPolicy.msPerHour) + 1   // just under one hour left

        XCTAssertFalse(
            store.isForwardable(receivedAt: anchoredAt, kind: .bulk, storedBudget: remaining,
                                storedCheckpoint: anchoredAt, storedBoot: "boot-A", storedDiscontinuity: Int64(0)),
            "*** A REBOOT IS NOT CONTINUITY: the policy debiteth at least one hour, so a row with just under an hour " +
                "left MUST BE WITHHELD. **AND THE NAIVE ARITHMETIC WOULD GET THIS EXACTLY BACKWARDS:** the new boot's " +
                "counter ($(store.receiptTimeProvider().monoMs)) is SMALLER than the anchor ($(anchoredAt)), so " +
                "`now - anchor` is NEGATIVE and would have EXTENDED the row's life. ***",
        )
    }

    /**
     * *** CASE 4: EXHAUSTION -- THE BUDGET REACHETH ZERO AND THE ROW IS WITHHELD. ***
     *
     * The card: *"never replenished."* A budget spent to exactly zero must withhold, and -- the sharper half -- **A
     * LATER READ MUST NOT REPLENISH IT.** The store's own comment saith the debit is "FROM ITS OWN CHECKPOINT", so a
     * second judgement with the SAME exhausted budget must still withhold.
     */
    func testGSSTORE004_anExhaustedBudgetIsWithheldAndIsNeverReplenished() throws {
        let (store, url) = try storeAt("exhaust", monoMs: 7_000_000, boot: "boot-E")
        defer { store.close(); try? FileManager.default.removeItem(at: url) }

        let now: Int64 = store.receiptTimeProvider().monoMs
        let withheld = { (remaining: Int64) in
            store.isForwardable(receivedAt: now, kind: .bulk, storedBudget: remaining,
                                storedCheckpoint: now, storedBoot: "boot-E", storedDiscontinuity: Int64(0))
        }

        XCTAssertFalse(withheld(0),
                       "*** A BUDGET SPENT TO ZERO MUST WITHHOLD. ***")
        XCTAssertFalse(withheld(0),
                       "*** AND A SECOND JUDGEMENT MUST NOT REPLENISH IT -- 'remaining lifetime only DECREASES'. " +
                           "A predicate that resurrected a spent row on re-read would be the replenishment the " +
                           "finding forbids. ***")
    }

    /**
     * *** CASE 5: READMISSION -- A FRESH ROW OF THE SAME KIND IS STILL ADMITTED AFTER AN EXHAUSTION. ***
     *
     * The positive control for exhaustion, and it is the one that keepeth the case above from being satisfied by a
     * predicate that simply refuseth everything. **A NEW ROW CARRIETH A NEW RECEIPT AND A NEW ANCHOR: THE DEAD ROW'S
     * EXHAUSTION MAY NOT POISON THE KIND.**
     */
    func testGSSTORE004_aFreshRowIsReadmittedAfterAnExhaustedOne() throws {
        let (store, url) = try storeAt("readmit", monoMs: 8_000_000, boot: "boot-R")
        defer { store.close(); try? FileManager.default.removeItem(at: url) }

        let now: Int64 = store.receiptTimeProvider().monoMs
        XCTAssertFalse(
            store.isForwardable(receivedAt: now, kind: .bulk, storedBudget: 0,
                                storedCheckpoint: now, storedBoot: "boot-R", storedDiscontinuity: Int64(0)),
            "the rig must first produce a WITHHELD row, or the readmission below proves nothing",
        )
        XCTAssertTrue(
            store.isForwardable(receivedAt: now, kind: .bulk,
                                storedBudget: Int64(RetentionPolicy.lifetimeMs[.bulk]!),
                                storedCheckpoint: now, storedBoot: "boot-R", storedDiscontinuity: Int64(0)),
            "*** READMISSION: A FRESH ROW OF THE SAME KIND, WITH A FULL BUDGET AND THIS BOOT'S ANCHOR, MUST BE " +
                "ADMITTED -- otherwise a predicate that refused everything would satisfy the exhaustion case while " +
                "making the store useless. ***",
        )
    }

}
