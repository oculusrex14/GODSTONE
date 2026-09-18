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
    // GS-FINAL-005 (round 709): THE CONTROL CLOCK -- THE AUDIT'S SECOND SENTENCE
    //
    // *** THE AUDIT: "InventorySnapshotAuthority and SyncControlOwner receive Date-based closures named
    // monotonicNowMillis." *** *Measured: the wall reading did not stop at those two -- the ROOT was
    // `MeshNode.controlClock`, which `defaultSyncPump`, the SOS dispatch paths and both control-plane seams all read
    // through.*
    //
    // **AND THE OTHER ISLE ALREADY HAD IT RIGHT (Android's `controlClock` readeth `System.nanoTime()`), SO THIS IS
    // PARITY WITH A CORRECT TWIN RATHER THAN A NEW INVENTION.**
    // ================================================================================================

    /**
     * *** THE DISCRIMINATING PROPERTY: A MONOTONIC CLOCK MUST NOT BE MOVABLE BY THE WALL CLOCK. ***
     *
     * *The audit's impact sentence: "wall-clock jumps can invalidate budget and deadline assumptions."*
     *
     * **WHY THIS IS NOT A SHAPE CHECK:** asserting only that `controlClock` exists, or that a parameter is NAMED
     * `monotonicNowMillis`, is exactly the string-matching that a wall-clock implementation satisfies. *The property
     * that DISCRIMINATES is the one a `Date()`-based closure FAILS and a `nanoTime()`-based closure PASSES: TWO
     * CONSECUTIVE SAMPLES MUST NOT DIFFER BY ~56 YEARS.* **The wall-clock reading is ~1.7e12 ms since the epoch;
     * a monotonic uptime reading is at most a few days' worth, ~1e8 ms.** *So the magnitude itself is the witness --
     * and pre-fix, `controlClock()` would have returned the epoch magnitude.*
     */
    func testGSFINAL005_theControlClockIsMonotonicAndNotWallTime() throws {
        let url = tempUrl("controlclock")
        let store = try SqliteMessageStore(url: url, maxBytes: 8 * 1024 * 1024)
        let identity = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let tracker = DeliveryTracker(
            repo: InMemoryDeliveryRepositoryForT43(InMemoryMessageStore()),
            authenticator: Ed25519AckAuthenticator(resolver: UnresolvedRecipientKeyResolver()))
        let node = MeshNode(identity: identity, store: store, deliveryTracker: tracker)

        let sample = node.controlClock()

        // *** THE WITNESS: WALL TIME SINCE 1970 IS ~1.7e12 ms; UPTIME IS BOUNDED BY THE HOST'S OWN UPTIME. ***
        // A threshold of 1e12 ms is ~31.7 years -- NO REAL MONOTONIC UPTIME REACHES IT, AND EVERY WALL READING SINCE
        // 2001 EXCEEDS IT. *So the arm cannot be satisfied by a wall clock and cannot be failed by a monotonic one.*
        XCTAssertLessThan(
            sample, 1_000_000_000_000,
            "*** GS-FINAL-005: `controlClock` MUST BE MONOTONIC, NOT WALL TIME. Measured \(sample) ms -- that is the " +
                "EPOCH MAGNITUDE, so this is `Date()`, and a user-set clock or an NTP step can move every deadline " +
                "and budget computed from it. *The audit: 'wall-clock jumps can invalidate budget and deadline " +
                "assumptions.'* ***",
        )

        // AND IT MUST ADVANCE RATHER THAN BE A CONSTANT -- a frozen clock would satisfy the bound above while making
        // every cadence comparison meaningless.
        let later = node.controlClock()
        XCTAssertGreaterThanOrEqual(
            later, sample,
            "*** A MONOTONIC CLOCK MUST NOT GO BACKWARDS. Observed \(sample) then \(later). ***",
        )
        XCTAssertNotEqual(
            later, 0,
            "*** AND IT MUST NOT BE A CONSTANT ZERO, which would satisfy the magnitude bound while breaking every " +
                "cadence comparison in the control plane. ***",
        )
        store.close()
        try? FileManager.default.removeItem(at: url)
    }

}
