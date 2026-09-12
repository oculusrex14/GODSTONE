import XCTest
@testable import GodstoneMesh

// ---------------------------------------------------------------------------
// T32 - the CANONICAL designated regression court, iOS side. The manifest
// required_regression_paths names this file; the narrow filter is
// `swift test --package-path ios/Packages/GodstoneFoundation --filter ReadinessT32Tests`.
// It drives the iOS contract twin (Sources/GodstoneMesh/RetentionClock.swift) and
// asserts the SAME seven bounded receipt-relative retention laws as the android
// twin ReadinessT32Test.kt (identical names), giving the dual-court parity the card
// requires. The sealed wall-clock store path is NOT touched; the physical
// section19/18 retention cases are DEVICE evidence (deferred to T73-75).
// ---------------------------------------------------------------------------

private final class ProvenAdapter: MonotonicClockAdapter, @unchecked Sendable {
    func proveContinuity(previous: RetentionCheckpoint, nowMono: Int) -> ClockContinuityStamp { .proven }
}
private final class UnknownAdapter: MonotonicClockAdapter, @unchecked Sendable {
    func proveContinuity(previous: RetentionCheckpoint, nowMono: Int) -> ClockContinuityStamp { .unknown }
}

final class ReadinessT32Tests: XCTestCase {

    private static let hour = 3_600_000
    private static let day = 24 * hour

    private static func proven() -> MonotonicClockAdapter { ProvenAdapter() }
    private static func unknown() -> MonotonicClockAdapter { UnknownAdapter() }
    private static func newCp(_ msgId: String, _ kind: MessageKind, _ now: Int) -> RetentionCheckpoint {
        RetentionPolicy.admit(msgId: msgId, kind: kind, priority: 1, firstReceiptId: "receipt-\(msgId)", nowMono: now, bootIdentity: "boot-1")
    }
    private static func with(_ base: RetentionCheckpoint, remaining: Int? = nil, disc: Int? = nil) -> RetentionCheckpoint {
        var c = base; if let r = remaining { c.remainingMs = r }; if let d = disc { c.discontinuityCount = d }
        return RetentionCheckpoint(msgId: c.msgId, kind: c.kind, remainingMs: c.remainingMs, checkpointMonotonicMs: c.checkpointMonotonicMs,
                                  lastWallCheckpointMs: c.lastWallCheckpointMs, discontinuityCount: c.discontinuityCount, priority: c.priority, firstReceiptId: c.firstReceiptId)
    }

    // (1) a wall-clock rollback never extends retention
    func testClockRollbackNeverExtendsRetention() throws {
        let base = Self.newCp("m1", .sos, 100)
        let cp = Self.with(base, remaining: 10 * Self.hour, disc: 5)
        let start = cp.remainingMs
        // a large NEGATIVE wall-delta hint (a rolled-back wall clock); the nonnegative clamp + 1h floor must keep the debit nonnegative
        let (n, _) = RetentionPolicy.checkpoint(cp, nowMono: 101, wallEstimateMs: -2 * Self.day, adapter: Self.unknown())
        XCTAssertLessThanOrEqual(n.remainingMs, start, "a wall-clock rollback may only SHRINK retention, never extend it")
        XCTAssertLessThan(n.remainingMs, start, "the debit is nonnegative -- the row advanced toward expiry, did not regress")
        XCTAssertEqual(n.discontinuityCount, 6, "the conservative branch counts exactly one discontinuity")
        XCTAssertLessThanOrEqual(n.remainingMs, RetentionPolicy.lifetimeMs[.sos]!, "retention never exceeds the canonical local policy")
    }

    // (2) a wall-clock forward jump may expire early (bounded conservative debit >= 1h)
    func testClockForwardMayExpireEarly() throws {
        let cp = Self.newCp("m2", .sos, 0)
        let (n, r) = RetentionPolicy.checkpoint(cp, nowMono: 5, wallEstimateMs: 30 * Self.day, adapter: Self.unknown())
        XCTAssertLessThanOrEqual(n.remainingMs, cp.remainingMs - Self.hour, "a forward wall jump debits at least the one-hour floor")
        XCTAssertEqual(n.discontinuityCount, 1, "one discontinuity is counted")
        XCTAssertEqual(n.remainingMs, 0, "the far-future estimate fully drains the row early")
        XCTAssertNotEqual(r, .notExpired)
    }

    // (3) a same-boot restart reuses the persisted monotonic anchor
    func testSameBootRestartReusesMonotonicAnchor() throws {
        let cp = Self.newCp("m3", .sos, 0)
        let (n, r) = RetentionPolicy.checkpoint(cp, nowMono: 3 * Self.hour, wallEstimateMs: 0, adapter: Self.proven())
        XCTAssertEqual(n.discontinuityCount, 0, "no discontinuity on a same-boot reopen")
        XCTAssertEqual(n.remainingMs, 21 * Self.hour, "the true monotonic delta drains the row")
        XCTAssertEqual(r, .notExpired, "not yet expired")
        XCTAssertLessThanOrEqual(n.remainingMs, RetentionPolicy.lifetimeMs[.sos]!, "re-checkpoint does NOT replenish toward the full lifetime")
    }

    // (4) a reboot with unproven continuity is bounded -- never an indefinite retention by restart loops
    func testRebootWithoutContinuityIsBoundedAndEventuallyExpires() throws {
        var cp = Self.newCp("m4", .direct, 0)
        var reason: ExpiryReason = .notExpired
        for i in 1...32 {
            let (n, r) = RetentionPolicy.checkpoint(cp, nowMono: i, wallEstimateMs: 0, adapter: Self.unknown())
            cp = n; reason = r
        }
        XCTAssertEqual(cp.discontinuityCount, 32, "every unproven reopen counts a discontinuity")
        XCTAssertEqual(reason, .clockContinuityLost, "the 32nd discontinuity forces expiry")
        XCTAssertEqual(cp.remainingMs, 0, "the row is fully drained")
    }

    // (5) an unknown clock takes the conservative branch with a NONNEGATIVE bounded estimate
    func testUnknownClockTakesConservativeBranch() throws {
        var cp = Self.newCp("m5", .sos, 0)
        for i in 1...5 { cp = RetentionPolicy.checkpoint(cp, nowMono: i, wallEstimateMs: -1, adapter: Self.unknown()).0 }   // all-negative hints
        XCTAssertEqual(cp.discontinuityCount, 5, "five conservative strikes")
        XCTAssertEqual(cp.remainingMs, 19 * Self.hour, "each strike debits exactly the one-hour floor (a negative hint is clamped to 0 then floored to 1h)")
        XCTAssertGreaterThanOrEqual(cp.remainingMs, 0, "never a negative remaining lifetime")
    }

    // (6) repeated malicious same-boot crash loops drain the shared lifetime without replenish
    func testRepeatedMaliciousCrashBoundAndTombstoneDiscipline() throws {
        var cp = Self.newCp("m6", .direct, 0)      // 7-day = 168h lifetime, anchored at 0
        for i in 1...40 { cp = RetentionPolicy.checkpoint(cp, nowMono: i * Self.hour, wallEstimateMs: 0, adapter: Self.proven()).0 }   // 40 crash-reopens, 1h apart
        XCTAssertEqual(cp.discontinuityCount, 0, "a same-boot crash loop counts NO discontinuity (continuity is proven)")
        XCTAssertEqual(cp.remainingMs, 128 * Self.hour, "each crash-reopen drains the shared lifetime from the persistent anchor -- never replenished")
        XCTAssertLessThanOrEqual(cp.remainingMs, RetentionPolicy.lifetimeMs[.direct]!, "still below the canonical full policy after 40 malicious reopens")
    }

    // (7) the expiry transaction vs ACK / cancel and a replayed frame after expiry
    func testExpiryTransactionVsAckCancelAndReplayAfterExpiry() throws {
        let fresh = Self.newCp("m7", .bulk, 0)
        let drained = Self.with(fresh, remaining: 0)
        XCTAssertEqual(RetentionTx.admitNew(fresh), .committed, "a fresh receipt commits once")
        XCTAssertEqual(RetentionTx.admitNew(drained), .alreadyExpiredRejected, "admitting an already-expired row is rejected")
        XCTAssertEqual(RetentionTx.replay(drained, nowMono: 999), .alreadyExpiredRejected, "replay after expiry is rejected")
        XCTAssertEqual(RetentionTx.replay(drained, nowMono: 1000), .alreadyExpiredRejected, "a replay of an expired row is still rejected")
        XCTAssertEqual(RetentionTx.ack(fresh, nowMono: 0), .committed, "an ACK retires a live row")
        XCTAssertEqual(RetentionTx.replay(fresh, nowMono: 0), .heldActive, "a live replay is held, not re-admitted")
        XCTAssertEqual(RetentionTx.cancel(drained), .cancelled, "a cancel is a distinct terminal effect")
        XCTAssertNotEqual(RetentionTx.replay(drained, nowMono: 5), .committed, "no path re-granted the expired row")
    }
}
