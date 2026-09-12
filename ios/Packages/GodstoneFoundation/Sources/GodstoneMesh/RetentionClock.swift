import Foundation

// ---------------------------------------------------------------------------
// T32 SHARED RETENTION CONTRACT (iOS) -- the Swift twin of the Android
// store/RetentionClock.kt. Both courts (ReadinessT32Test.kt /
// ReadinessT32Tests.swift) drive ONE contract through an injected continuity
// oracle so the dual-court parity the card mandates holds: the bounded
// receipt-relative retention laws are EXECUTED identically on both isles.
// This is the ADDITIVE sanctioned seam the runtime binds the store to; the sealed
// wall-clock MessageStore received_at path (the current incomplete implementation
// the card names) is NOT rewritten here.
//
// Laws (mirrored exactly): a proven-continuous (same-boot) reopen debits the true
// monotonic delta from the ORIGINAL persisted anchor and re-arms nothing; an
// unprovable reopen takes the conservative branch debit = max(1h, clamped
// nonnegative wall estimate) and counts a discontinuity; the 32nd discontinuity
// expires with CLOCK_CONTINUITY_LOST; remaining = max(0, prev - debit) is NEVER
// replenished; a wall-clock rollback may only shrink retention; MAX_HOLD 7d caps
// every kind; no sender timestamp controls a duration.
//
// No wall-clock read, no SQLite: the monotonic now and the continuity oracle are
// INJECTED, so the laws are host-executable via deterministic fakes and no
// device/SDK/network result is fabricated. Pure Foundation only.
// ---------------------------------------------------------------------------

/// The kind of held row: selects the canonical local lifetime. NOT a sender field.
public enum MessageKind: Int, CaseIterable, Sendable {
    case direct, sos, group, broadcast, bulk
}

/// The clock-continuity verdict a platform adapter returns for one reopen.
public enum ClockContinuityStamp: Equatable, Sendable {
    case proven
    case unknown
    case reset(bootIdentity: String)
}

/// Terminal cause of an expiry. Distinct reasons; an unknown clock is never silently tolerated.
public enum ExpiryReason: String, CaseIterable, Sendable {
    case notExpired = "NOT_EXPIRED"
    case lifetimeElapsed = "LIFETIME_ELAPSED"
    case maxHold = "MAX_HOLD"
    case clockContinuityLost = "CLOCK_CONTINUITY_LOST"
}

/// The durable, per-row retention state persisted across process death and reboot.
/// Holds NO sender timestamp -- "No sender timestamp controls these durations."
public struct RetentionCheckpoint: Equatable, Sendable {
    public let msgId: String
    public let kind: MessageKind
    public var remainingMs: Int
    public var checkpointMonotonicMs: Int
    public var lastWallCheckpointMs: Int
    public var discontinuityCount: Int
    public let priority: Int
    public let firstReceiptId: String
    public init(msgId: String, kind: MessageKind, remainingMs: Int, checkpointMonotonicMs: Int,
                lastWallCheckpointMs: Int, discontinuityCount: Int, priority: Int, firstReceiptId: String) {
        self.msgId = msgId; self.kind = kind; self.remainingMs = remainingMs
        self.checkpointMonotonicMs = checkpointMonotonicMs; self.lastWallCheckpointMs = lastWallCheckpointMs
        self.discontinuityCount = discontinuityCount; self.priority = priority; self.firstReceiptId = firstReceiptId
    }
}

/// The injected continuity oracle. A real platform adapter must PROVE monotonic
/// continuity from tested platform information -- uptime alone after a reboot is
/// insufficient -- and must return `.unknown` when it cannot. The host tests inject
/// deterministic fakes; the algorithm never trusts its clock.
public protocol MonotonicClockAdapter: AnyObject {
    func proveContinuity(previous: RetentionCheckpoint, nowMono: Int) -> ClockContinuityStamp
}

/// The exact section14 algorithm. Stateless: all mutable retention state lives in the
/// persisted RetentionCheckpoint the caller passes in and receives back, so a
/// same-boot crash reuses the ORIGINAL persisted monotonic anchor by construction.
public struct RetentionPolicy {
    public static let msPerHour = 3_600_000
    public static let discontinuityLimit = 32
    public static let checkpointCadenceMs = 60_000

    /// Canonical LOCAL policy. No sender timestamp controls any of these durations.
    public static let lifetimeMs: [MessageKind: Int] = [
        .direct: 7 * 24 * msPerHour,       // 7 days
        .sos: 24 * msPerHour,               // 24 hours
        .group: 24 * msPerHour,             // 24 hours
        .broadcast: 24 * msPerHour,         // 24 hours
        .bulk: msPerHour,                   // 1 hour
    ]
    public static let maxHoldMs = 7 * 24 * msPerHour      // MAX_HOLD 7 days
    public static let tombstoneMs = 8 * 24 * msPerHour    // dedup tombstones 8 days

    /// A NEW receipt is granted the full local lifetime EXACTLY ONCE, anchored at nowMono.
    public static func admit(msgId: String, kind: MessageKind, priority: Int, firstReceiptId: String, nowMono: Int, bootIdentity: String) -> RetentionCheckpoint {
        RetentionCheckpoint(msgId: msgId, kind: kind, remainingMs: lifetimeMs[kind]!,
                            checkpointMonotonicMs: nowMono, lastWallCheckpointMs: nowMono,
                            discontinuityCount: 0, priority: priority, firstReceiptId: firstReceiptId)
    }

    private static func elapsedSince(_ anchor: Int, _ now: Int) -> Int { now >= anchor ? now - anchor : 0 }

    /// The pure expiry predicate: expired iff the remaining lifetime or MAX_HOLD is reached.
    public static func isExpired(_ cp: RetentionCheckpoint, nowMono: Int) -> ExpiryReason {
        if cp.remainingMs <= 0 { return reasonWhenDrained(cp, nowMono) }
        if elapsedSince(cp.checkpointMonotonicMs, nowMono) >= maxHoldMs { return .maxHold }
        return .notExpired
    }
    private static func reasonWhenDrained(_ cp: RetentionCheckpoint, _ nowMono: Int) -> ExpiryReason {
        elapsedSince(cp.checkpointMonotonicMs, nowMono) >= maxHoldMs ? .maxHold : .lifetimeElapsed
    }

    /// The reopen / checkpoint branch (section14 pseudocode), applied atomically.
    public static func checkpoint(_ cp: RetentionCheckpoint, nowMono: Int, wallEstimateMs: Int, adapter: MonotonicClockAdapter) -> (RetentionCheckpoint, ExpiryReason) {
        let stamp = adapter.proveContinuity(previous: cp, nowMono: nowMono)
        var debit = 0
        var disc = cp.discontinuityCount
        if stamp == .proven {
            debit = max(0, elapsedSince(cp.checkpointMonotonicMs, nowMono))
        } else {
            disc += 1
            let boundedWall = wallEstimateMs >= 0 ? wallEstimateMs : 0       // nonnegative wall-delta hint
            debit = max(msPerHour, boundedWall)                                // at least one hour
        }
        let remaining = max(0, cp.remainingMs - debit)                        // never below 0; never replenished
        let expiredByContinuity = disc >= discontinuityLimit
        var newCp = cp
        newCp.remainingMs = expiredByContinuity ? 0 : remaining
        newCp.checkpointMonotonicMs = (stamp == .proven) ? nowMono : cp.checkpointMonotonicMs
        newCp.lastWallCheckpointMs = nowMono
        newCp.discontinuityCount = disc
        let reason: ExpiryReason = expiredByContinuity ? .clockContinuityLost : isExpired(newCp, nowMono: nowMono)
        return (newCp, reason)
    }

    /// A durable checkpoint is due at least every checkpointCadenceMs.
    public static func dueCheckpoint(_ cp: RetentionCheckpoint, nowMono: Int) -> Bool {
        elapsedSince(cp.checkpointMonotonicMs, nowMono) >= checkpointCadenceMs
    }
}

/// The effect of one expiry transaction (never fabricated; distinct terminal states).
public enum RetentionEffect: String, CaseIterable, Sendable {
    case committed = "COMMITTED"
    case heldActive = "HELD_ACTIVE"
    case alreadyExpiredRejected = "ALREADY_EXPIRED_REJECTED"
    case cancelled = "CANCELLED"
}

/// The per-row retention transaction store, modelled exactly. Admits a NEW receipt
/// once; a REPLAY after expiry MUST be rejected (never re-granting a lifetime); an
/// ACK retires the row; a cancel stops scheduling but cannot recall relayed copies.
public struct RetentionTx {
    public static func admitNew(_ cp: RetentionCheckpoint) -> RetentionEffect {
        cp.remainingMs <= 0 ? .alreadyExpiredRejected : .committed
    }
    public static func replay(_ cp: RetentionCheckpoint, nowMono: Int) -> RetentionEffect {
        (RetentionPolicy.isExpired(cp, nowMono: nowMono) != .notExpired || cp.remainingMs <= 0) ? .alreadyExpiredRejected : .heldActive
    }
    public static func ack(_ cp: RetentionCheckpoint, nowMono: Int) -> RetentionEffect {
        RetentionPolicy.isExpired(cp, nowMono: nowMono) != .notExpired ? .alreadyExpiredRejected : .committed
    }
    public static func cancel(_ cp: RetentionCheckpoint) -> RetentionEffect { .cancelled }
}
