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
}
