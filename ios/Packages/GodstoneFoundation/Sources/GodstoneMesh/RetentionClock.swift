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

    /// GS-STORE-004 (round 313): THE RETENTION KIND OF A STORED TYPE OCTET -- the mapping that was MISSING, and
    /// whose absence round 312 measured: `MessageKind(rawValue: typeCode)` looked up the wire octet in a DIFFERENT
    /// `rawValue` space, missed, and the caller's `guard ... else { return true }` then answered "this row is fine"
    /// FOR A ROW IT NEVER JUDGED. THE MAPPING IS DECIDED AND DOCUMENTED, with its two judgements STATED:
    ///  - `message` is DIRECT, `sos` is SOS, and the two bulk types are BULK -- the only three kinds this build's
    ///    wire vocabulary can express. `.group` and `.broadcast` have NO wire type here, so no held row can
    ///    carrieth them: NAMED rather than silently mapped onto something else.
    ///  - the CONTROL types (hello, digest, want, ack, ping, goodbye) are held briefly and are governed as DIRECT,
    ///    the longest-lived applicable kind -- the NON-DESTRUCTIVE choice, since a control row is not retired early
    ///    by a mapping decision.
    ///  - AN UNKNOWN OCTET answereth `nil` and the caller then JUDGETH NOT (the row stayeth forwardable):
    ///    DESTROYING A ROW WHOSE TYPE IS UNKNOWN WOULD BE A GUESS WITH A DELETION BEHIND IT.
    public static func ofStoredTypeCode(_ code: Int) -> MessageKind? {
        switch TypeV2(rawValue: UInt8(truncatingIfNeeded: code)) {
        case .message: return .direct
        case .sos: return .sos
        case .bulk_offer, .bulk_chunk: return .bulk
        case .hello, .digest, .want, .ack, .ping, .goodbye: return .direct
        case nil: return nil
        }
    }
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
    /// *** GS-STORE-004 (round 527): THE CONTINUITY IDENTIFIER, CARRIED BY THE MODEL AT LAST. ***
    ///
    /// THE `boot_identity` COLUMN HATH STOOD IN THE SCHEMA SINCE REVISION 8, AND **NO MODEL EVER CARRIED IT**: it was
    /// written ONCE at admission and **NEVER ADVANCED**, because there was nowhere for a new boot to be put. MEASURED
    /// AT ROUND 527 BY AN INSTRUMENTED ARM (35 alternating opens): the discontinuity counter stood at **18** -- ONE
    /// PER OPEN IN THE OTHER BOOT -- because the persisted identity remained the ADMISSION boot for ever, so every
    /// open in a different boot counted afresh. **THE COUNTER THEREFORE MEASURED OPENS, NOT DISCONTINUITIES**, and a
    /// store reopened 32 times across a boot change would retire a row that suffered ONE.
    public var bootIdentity: String
    public init(msgId: String, kind: MessageKind, remainingMs: Int, checkpointMonotonicMs: Int,
                lastWallCheckpointMs: Int, discontinuityCount: Int, priority: Int, firstReceiptId: String,
                bootIdentity: String = "") {
        self.msgId = msgId; self.kind = kind; self.remainingMs = remainingMs
        self.checkpointMonotonicMs = checkpointMonotonicMs; self.lastWallCheckpointMs = lastWallCheckpointMs
        self.discontinuityCount = discontinuityCount; self.priority = priority; self.firstReceiptId = firstReceiptId
        self.bootIdentity = bootIdentity
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
        // AND THE IDENTITY IT ALREADY RECEIVETH IS NOW KEPT: `bootIdentity` was a PARAMETER THIS FUNCTION
        // DISCARDED, which is why no row ever advanced it.
        RetentionCheckpoint(msgId: msgId, kind: kind, remainingMs: lifetimeMs[kind]!,
                            checkpointMonotonicMs: nowMono, lastWallCheckpointMs: nowMono,
                            discontinuityCount: 0, priority: priority, firstReceiptId: firstReceiptId,
                            bootIdentity: bootIdentity)
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
        // *** AND THE CONTINUITY IDENTIFIER ADVANCETH WITH THE BOOT, WHICH IS THE WHOLE REPAIR: ***
        // `ClockContinuityStamp.reset` CARRIETH THE NEW BOOT IDENTITY, and the policy DISCARDED it -- so the persisted
        // identity remained the admission boot for ever and every later open in another boot counted a FRESH
        // discontinuity. ADVANCING IT MEANETH THE NEXT OPEN IN THIS BOOT PROVES CONTINUITY, so ONE boot change
        // counteth ONE discontinuity HOWEVER MANY TIMES the store is opened. `.unknown` (no persisted identity at
        // all) is NOT a boot we may name, and it is left untouched: an absent identity is not a continuity.
        if case .reset(let newBoot) = stamp { newCp.bootIdentity = newBoot }
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

/// *** GS-FINAL-005 (the independent audit, 2026-09-18): THE PLATFORM CLOCK PRODUCTION ACTUALLY USES. ***
///
/// BEFORE THIS EXISTED THERE WAS **NOTHING TO INSTALL**: the store's clock was an optional property that 26 test
/// sites assigned and ZERO production sites did, so production ran clockless and every retention judgement silently
/// answered "keep". A REPAIR THAT MADE THE CLOCK MANDATORY WOULD HAVE HAD NOTHING TO DEFAULT TO.
///
/// **THE MONOTONIC INSTANT IS `ProcessInfo.systemUptime`, NOT A WALL CLOCK**, because the policy's whole subject is
/// elapsed time that a user's clock change cannot move. `systemUptime` is monotonic since boot on Darwin, which is
/// exactly the property `RetentionPolicy`'s continuity arithmetic assume.
///
/// **AND THE BOOT IDENTITY IS DERIVED FROM THAT SAME INSTANT'S BASE**, so "the same boot" and "a new boot" are
/// distinguishable WITHOUT a wall clock: `bootBase = now - uptime` is the instant the current boot began, and it is
/// stable within a boot and different across one. It is not a secret and carrieth nothing sensitive.
///
/// THE HONEST LIMITATION, STATED RATHER THAN HIDDEN: two boots that begin at the SAME wall instant would share an
/// identity. That is a base-N collision on a DIFFERENT clock than the one being read, and the policy already
/// tolerateth an unproven continuity by DEBITING at least an hour (`RetentionPolicy.checkpoint`) -- so a collision
/// DEBITES RATHER THAN REPLENISHES, which is the safe direction.
public enum DefaultRetentionClock {
    public static func sample() -> (monoMs: Int64, bootIdentity: String) {
        let uptime = ProcessInfo.processInfo.systemUptime          // monotonic seconds since boot
        let now = Date().timeIntervalSince1970 * 1000              // wall ms -- used ONLY to name the boot
        let monoMs = Int64(uptime * 1000)
        let bootBase = Int64(now) - monoMs
        return (monoMs: monoMs, bootIdentity: "boot-" + String(bootBase, radix: 16))
    }
}
