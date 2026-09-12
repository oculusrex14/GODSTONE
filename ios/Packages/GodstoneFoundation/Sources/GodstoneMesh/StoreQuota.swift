import Foundation

// ---------------------------------------------------------------------------
// T33 SHARED QUOTA / EVICTION / OBSERVER-LEASE CONTRACT (iOS) -- the Swift twin of
// the Android store/StoreQuota.kt. Both courts (ReadinessT33Test.kt /
// ReadinessT33Tests.swift) drive ONE contract through injected deterministic
// measurements so the dual-court parity the card mandates holds: the store-growth
// and observer-lifetime laws are EXECUTED identically on both isles.
//
// NO wall-clock read, NO SQLite: every measurement is INJECTED via QuotaSnapshot,
// so the capacity/authority/consistency/lease laws are host-executable via
// deterministic fakes and no device/SDK/network result is fabricated. The sealed
// wall-clock MessageStore held-cap/eviction/observer path (the current incomplete
// implementation the card names) is NOT rewritten here -- additive sanctioned seam.
//
// Laws (mirrored exactly, including the two the android court forced): NON-SOS
// FIRST / SOS retained-LAST eviction order; authority-preserving measurement (a
// query failure is never a fabricated 0); transaction-owned eviction that pairs
// each removed held row with its delivery EVICTED transition; and a commit-ordered,
// non-reentrant observer lease whose mid-dispatch registrations carry to the NEXT round.
// ---------------------------------------------------------------------------

/// The bounded categories the store accounts for, each with a hard ceiling.
public enum QuotaKind: Int, CaseIterable, Sendable { case heldFrame, totalPrivateStore, deliveryRows, inboxRows, tombstoneRows, trustIdentities }

/// A read of one measured quantity: a real value, OR a query failure. A failure is NEVER a fabricated 0.
public enum Measured: Sendable {
    case values(Int64)
    case queryFailure(String)
}

/// The resources the store must NEVER silently evict under pressure -- new admission is refused instead.
public enum Pressure: String, CaseIterable, Sendable {
    case unexpiredTombstones = "UNEXPIRED_TOMBSTONES"
    case verifiedTrustPins = "VERIFIED_TRUST_PINS"
    case revokedTrustPins = "REVOKED_TRUST_PINS"
    case deliveryRows = "DELIVERY_ROWS"
}

public enum StoreDeliveryState: String, CaseIterable, Sendable {
    case queued = "QUEUED", handed = "HANDED", delivered = "DELIVERED", cancelled = "CANCELLED", evicted = "EVICTED"
}

/// The injected, deterministic measurements of the store at a decision instant. A failed read is `.queryFailure`, never 0.
public struct QuotaSnapshot: Sendable {
    public let heldBytes: Measured
    public let totalBytes: Measured
    public let deliveryRows: Measured
    public let inboxRows: Measured
    public let tombstoneRows: Measured
    public let trustPins: Measured
    public let inActiveTransaction: Bool
    public let walBytes: Int64
    public init(heldBytes: Measured, totalBytes: Measured, deliveryRows: Measured, inboxRows: Measured,
                tombstoneRows: Measured, trustPins: Measured, inActiveTransaction: Bool, walBytes: Int64) {
        self.heldBytes = heldBytes; self.totalBytes = totalBytes; self.deliveryRows = deliveryRows
        self.inboxRows = inboxRows; self.tombstoneRows = tombstoneRows; self.trustPins = trustPins
        self.inActiveTransaction = inActiveTransaction; self.walBytes = walBytes
    }
}

/// A candidate held row carrying its delivery binding; identity is the immutable id.
public struct HeldRow: Sendable {
    public let id: String
    public let priority: Int
    public let receivedAt: Int64
    public let size: Int64
    public let deliveryState: StoreDeliveryState
    public let isUnexpiredTombstone: Bool
    public let isVerifiedTrustPin: Bool
    public let isRevokedTrustPin: Bool
    public init(id: String, priority: Int, receivedAt: Int64, size: Int64, deliveryState: StoreDeliveryState = .queued,
                isUnexpiredTombstone: Bool = false, isVerifiedTrustPin: Bool = false, isRevokedTrustPin: Bool = false) {
        self.id = id; self.priority = priority; self.receivedAt = receivedAt; self.size = size
        self.deliveryState = deliveryState; self.isUnexpiredTombstone = isUnexpiredTombstone
        self.isVerifiedTrustPin = isVerifiedTrustPin; self.isRevokedTrustPin = isRevokedTrustPin
    }
    public func with(deliveryState s: StoreDeliveryState) -> HeldRow {
        HeldRow(id: id, priority: priority, receivedAt: receivedAt, size: size, deliveryState: s,
                isUnexpiredTombstone: isUnexpiredTombstone, isVerifiedTrustPin: isVerifiedTrustPin, isRevokedTrustPin: isRevokedTrustPin)
    }
}

/// The outcome of one admission decision. QueryError is DISTINCT from a real rejection and from acceptance.
public enum AdmissionResult: Equatable, Sendable {
    case accepted
    case rejectedHeldCap
    case rejectedTotalQuota
    case refusedUnderPressure(Pressure)
    case duplicateRejected
    case terminalRejected
    case queryError(String)
    public func isAccepted() -> Bool { if case .accepted = self { return true }; return false }
}

/// The plan of one transaction-owned eviction: which rows leave, their delivery transitions, in stable order.
public struct EvictionPlan: Sendable {
    public let evictedIds: [String]
    public let deliveryTransitions: [(id: String, state: StoreDeliveryState)]
    public let cumulativeBytes: Int64
    public init(evictedIds: [String], deliveryTransitions: [(id: String, state: StoreDeliveryState)], cumulativeBytes: Int64) {
        self.evictedIds = evictedIds; self.deliveryTransitions = deliveryTransitions; self.cumulativeBytes = cumulativeBytes
    }
}

/// The exact section14 policy. Stateless over the injected snapshot; canonical ceilings.
public struct StoreQuota {
    public static let mib: Int64 = 1024 * 1024
    public static let heldFrameHardCap: Int64 = 64 * mib
    public static let totalPrivateStoreQuota: Int64 = 128 * mib
    public static let deliveryRowCap: Int = 100000
    public static let inboxRowCap: Int = 100000
    public static let tombstoneRowCap: Int = 100000
    public static let trustIdentityCap: Int = 4096
    public static let walAllowance: Int64 = 16 * mib
    public static let migrationPreflightSpace: Int64 = 256 * mib

    /// Stable policy order: NON-SOS FIRST (priority > 0 ascending), then oldest-received, then id -- so SOS (priority 0) is retained-LAST.
    public static let policyComparator: (HeldRow, HeldRow) -> Bool = { a, b in
        if a.priority != b.priority { return a.priority > b.priority }
        if a.receivedAt != b.receivedAt { return a.receivedAt < b.receivedAt }
        return a.id < b.id
    }

    public static func valueOrFailed(_ m: Measured) -> Int64? { if case let .values(v) = m { return v }; return nil }

    /// Pure admission of one candidate. NEVER Accepted on a fabricated measurement; a read failure is QueryError.
    public static func admit(snapshot: QuotaSnapshot, candidateSize: Int64, isDuplicate: Bool, isTerminal: Bool) -> AdmissionResult {
        guard let held = valueOrFailed(snapshot.heldBytes) else { return .queryError("held bytes read failed") }
        guard let total = valueOrFailed(snapshot.totalBytes) else { return .queryError("total bytes read failed") }
        guard let del = valueOrFailed(snapshot.deliveryRows) else { return .queryError("delivery rows read failed") }
        guard let inbox = valueOrFailed(snapshot.inboxRows) else { return .queryError("inbox rows read failed") }
        guard let tomb = valueOrFailed(snapshot.tombstoneRows) else { return .queryError("tombstone rows read failed") }
        guard let trust = valueOrFailed(snapshot.trustPins) else { return .queryError("trust pins read failed") }
        if isDuplicate { return .duplicateRejected }
        if isTerminal { return .terminalRejected }
        if held + candidateSize > heldFrameHardCap { return .rejectedHeldCap }
        if total + candidateSize > totalPrivateStoreQuota { return .rejectedTotalQuota }
        if del >= Int64(deliveryRowCap) { return .refusedUnderPressure(.deliveryRows) }
        if inbox >= Int64(inboxRowCap) { return .refusedUnderPressure(.deliveryRows) }
        if tomb >= Int64(tombstoneRowCap) { return .refusedUnderPressure(.unexpiredTombstones) }
        if trust >= Int64(trustIdentityCap) { return .refusedUnderPressure(.verifiedTrustPins) }
        return .accepted
    }

    /// Transaction-owned eviction keeping the 64 MiB held hard cap, in STABLE policy order, protecting tombstones/trust pins,
    /// pairing every removed held row with its delivery EVICTED transition (held + delivery move together).
    public static func evictionPlan(rows: [HeldRow], measuredHeldBytes: Int64) -> EvictionPlan {
        if measuredHeldBytes <= heldFrameHardCap { return EvictionPlan(evictedIds: [], deliveryTransitions: [], cumulativeBytes: measuredHeldBytes) }
        var overshoot = measuredHeldBytes - heldFrameHardCap
        let eligible = rows.sorted(by: policyComparator).filter { !$0.isUnexpiredTombstone && !$0.isVerifiedTrustPin && !$0.isRevokedTrustPin && $0.deliveryState != .evicted }
        var evicted: [String] = []; var trans: [(id: String, state: StoreDeliveryState)] = []; var cum: Int64 = 0
        for r in eligible {
            if overshoot <= 0 { break }
            evicted.append(r.id); trans.append((r.id, .evicted)); cum += r.size; overshoot -= r.size
        }
        return EvictionPlan(evictedIds: evicted, deliveryTransitions: trans, cumulativeBytes: cum)
    }

    public static func hardCapHoldsAfter(rows: [HeldRow], measuredHeldBytes: Int64) -> Bool {
        if measuredHeldBytes <= heldFrameHardCap { return true }
        return evictionPlan(rows: rows, measuredHeldBytes: measuredHeldBytes).cumulativeBytes >= (measuredHeldBytes - heldFrameHardCap)
    }

    /// A checkpoint is DUE only from the measured WAL overshoot AND only OUTSIDE an active transaction; inside a tx it suspends.
    public static func checkpointState(inActiveTransaction: Bool, walBytes: Int64) -> (due: Bool, suspend: Bool) {
        let over = walBytes > walAllowance
        return (over && !inActiveTransaction, over && inActiveTransaction)
    }

    /// Bounded cursor read: a page never exceeds its limit; an out-of-range/zero-limit read yields none, never a fabricated full page.
    public static func fetchPage<T>(_ source: [T], start: Int, limit: Int) -> [T] {
        if limit <= 0 || start < 0 || start >= source.count { return [] }
        return Array(source[start..<min(start + limit, source.count)])
    }
}

/// The observer lease. Handles register and fire ONLY after a commit, once each, in order,
/// NOT reentrantly: a registration made during dispatch is carried to the NEXT commit round.
/// An aborted transaction discards the notifications registered within it.
public final class ObservationLease: @unchecked Sendable {
    public final class LeaseToken: @unchecked Sendable { public let id: Int; init(_ id: Int) { self.id = id } }
    private var registrations: [(LeaseToken, () -> Void)] = []
    private var deferred: [(LeaseToken, () -> Void)] = []     // registered within an open tx (abandoned on abort)
    private var promote: [(LeaseToken, () -> Void)] = []      // registered during dispatch -> fired NEXT round
    private var nextId = 0
    private var inTx = false
    private var dispatching = false
    public init() {}
    public var active: Bool { inTx }
    public func beginTransaction() { inTx = true }
    public func commit() { inTx = false }
    public func abort() { inTx = false; deferred.removeAll() }
    @discardableResult public func register(_ observer: @escaping () -> Void) -> LeaseToken {
        let t = LeaseToken(nextId); nextId += 1
        if dispatching { promote.append((t, observer)) } else if inTx { deferred.append((t, observer)) } else { registrations.append((t, observer)) }
        return t
    }
    public func unregisterBy(_ token: LeaseToken) {
        registrations.removeAll { $0.0 === token }; deferred.removeAll { $0.0 === token }; promote.removeAll { $0.0 === token }
    }
    public func afterCommit() {
        if inTx { return }
        dispatching = true
        var pending = promote; promote.removeAll()
        pending.append(contentsOf: registrations)
        var fired = Set<Int>()
        var i = 0
        while i < pending.count { if fired.insert(pending[i].0.id).inserted { pending[i].1() }; i += 1 }
        dispatching = false
    }
}
