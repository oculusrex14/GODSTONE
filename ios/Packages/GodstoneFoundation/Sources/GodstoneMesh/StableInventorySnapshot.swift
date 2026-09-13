import Foundation

// T40 (ADR-009 section 14, the snapshot law) -- stable inventory snapshots,
// the twin of the Android router/StableInventorySnapshot.kt. The store's
// executor builds one consistent streaming read of the DURABLE store into a
// sorted, immutable vector; pages are pinned to that captured vector, never
// to a moving offset. The authority allocates snapshot ids strictly
// monotonically from a nonzero base (exhaustion retires the context), shares
// at most two snapshots (the current plus a referenced predecessor) under
// lease, honours one build per 30 seconds and a 300-second age, aborts a
// walk that overruns its two-second read budget, and refuses vectors beyond
// the bounds. An ordinary new hold does not restart an active immutable
// snapshot; leases release at the relation's terminal.

public struct StableInventorySnapshot: Sendable, Equatable {

    public static let maxRows: Int = 100_000
    public static let maxIdBytes: Int = 1_600_000
    public static let maxAgeMs: Int64 = 300_000
    public static let minBuildGapMs: Int64 = 30_000
    public static let readBudgetMs: Int64 = 2_000
    public static let maxLeased: Int = 2

    public let snapshotId: UInt64
    /// The captured vector: sorted, distinct, immutable.
    public let ids: [Data]
    public let capturedAtMono: Int64

    public init(snapshotId: UInt64, ids raw: [Data], capturedAtMono: Int64) throws {
        if snapshotId == 0 { throw ControlException(.zeroSnapshotId) }
        if raw.count > StableInventorySnapshot.maxRows { throw ControlException(.countOutOfRange) }
        var copy: [Data] = []
        copy.reserveCapacity(raw.count)
        for id in raw {
            if id.count != ControlPayloadV1.idBytes { throw ControlException(.wrongSize) }
            copy.append(id)
        }
        if !ControlPayloadV1.idsDistinct(copy) { throw ControlException(.duplicateIds) }
        copy.sort { ControlPayloadV1.lexicographicCompare($0, $1) < 0 }
        let bytes = copy.reduce(0) { $0 + $1.count }
        if bytes > StableInventorySnapshot.maxIdBytes { throw ControlException(.countOutOfRange) }
        self.snapshotId = snapshotId
        self.ids = copy
        self.capturedAtMono = capturedAtMono
    }

    /// Is the id in the captured vector (the walk's membership oracle).
    public func contains(_ id: Data) -> Bool {
        var lo = 0, hi = ids.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let c = ControlPayloadV1.lexicographicCompare(ids[mid], id)
            if c == 0 { return true }
            if c < 0 { lo = mid + 1 } else { hi = mid - 1 }
        }
        return false
    }

    /// The page of at most [maxPerPage] ids following the exclusive lexicographic
    /// cursor; nil cursor walks from the beginning. The final page carries
    /// done=1; a walk past the end yields the empty done page (the wrap).
    public func pageAfter(cursor: Data?, maxPerPage: Int) throws -> ControlInventoryPage {
        if maxPerPage < 1 || maxPerPage > ControlPayloadV1.maxIdsPerArm {
            throw ControlException(.countOutOfRange)
        }
        if let cursor = cursor, cursor.count != ControlPayloadV1.idBytes {
            throw ControlException(.badCursor)
        }
        var picked: [Data] = []
        if let cursor = cursor {
            // the vector is sorted: seek the first id strictly past the cursor
            var lo = 0, hi = ids.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if ControlPayloadV1.lexicographicCompare(ids[mid], cursor) <= 0 { lo = mid + 1 }
                else { hi = mid }
            }
            if lo < ids.count {
                picked = Array(ids[lo..<min(lo + maxPerPage, ids.count)])
            }
        } else {
            picked = Array(ids.prefix(maxPerPage))
        }
        let done: UInt8 = (picked.isEmpty || lastBeyond(picked, cursor)) ? 1 : 0
        return try ControlInventoryPage(snapshotId: snapshotId, done: done, ids: picked)
    }

    /// A page is the last of the walk when its tail is the vector's own tail.
    private func lastBeyond(_ picked: [Data], _ cursor: Data?) -> Bool {
        guard let last = picked.last, let vectorLast = ids.last else { return true }
        return ControlPayloadV1.lexicographicCompare(last, vectorLast) >= 0
    }
}

// MARK: - the authority

public final class InventorySnapshotAuthority: @unchecked Sendable {

    private let store: MessageStore
    private let monotonicNowMillis: () -> Int64
    private let lock = NSLock()
    private var counter: UInt64
    private var retired = false
    private var current: StableInventorySnapshot?
    private var predecessor: StableInventorySnapshot?
    private var leases: [UInt64: Int] = [:]
    private var lastBuildAttemptMono: Int64 = Int64.min

    private var deferredByRateCount = 0
    private var deferredByLeasesCount = 0
    private var abortedByBudgetCount = 0
    private var refusedByBoundsCount = 0
    private var refusedByExhaustionCount = 0

    public init(store: MessageStore, monotonicNowMillis: @escaping () -> Int64, firstId: UInt64 = 0) {
        self.store = store
        self.monotonicNowMillis = monotonicNowMillis
        self.counter = firstId
    }

    /// Allocate the next snapshot id: nonzero, strictly monotonic; the context
    /// retires at exhaustion and no id is ever reused.
    public func nextSnapshotId() -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        if retired { return nil }
        if counter == UInt64.max {
            retired = true
            refusedByExhaustionCount += 1
            return nil
        }
        counter += 1
        return counter
    }

    /// The freshest admissible snapshot: the held one while it stands within
    /// its age; else a gated build. Nil means "defer this turn" -- the caller
    /// must not serve stale truth.
    public func currentSnapshot() -> StableInventorySnapshot? {
        let now = monotonicNowMillis()
        lock.lock()
        if retired { lock.unlock(); return nil }
        if let cur = current, now - cur.capturedAtMono <= StableInventorySnapshot.maxAgeMs {
            lock.unlock()
            return cur
        }
        lock.unlock()
        return buildFresh()
    }

    /// Force a recapture regardless of freshness, honouring rate, leases and budget.
    public func forceSnapshot() -> StableInventorySnapshot? {
        buildFresh()
    }

    public func currentSnapshotOrNull() -> StableInventorySnapshot? {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    public func isRetired() -> Bool { lock.lock(); defer { lock.unlock() }; return retired }
    public func deferredByRate() -> Int { lock.lock(); defer { lock.unlock() }; return deferredByRateCount }
    public func deferredByLeases() -> Int { lock.lock(); defer { lock.unlock() }; return deferredByLeasesCount }
    public func abortedByBudget() -> Int { lock.lock(); defer { lock.unlock() }; return abortedByBudgetCount }
    public func refusedByBounds() -> Int { lock.lock(); defer { lock.unlock() }; return refusedByBoundsCount }
    public func refusedByExhaustion() -> Int { lock.lock(); defer { lock.unlock() }; return refusedByExhaustionCount }

    // -- leases: the share of at most two snapshots (current + referenced predecessor) --

    public func acquire(_ snapshotId: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let known = (current?.snapshotId == snapshotId) || (predecessor?.snapshotId == snapshotId)
        guard known else { return false }
        leases[snapshotId, default: 0] += 1
        return true
    }

    public func release(_ snapshotId: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let held = leases[snapshotId], held > 0 else { return false }
        leases[snapshotId] = held - 1
        return true
    }

    public func leasedOf(_ snapshotId: UInt64) -> Int {
        lock.lock(); defer { lock.unlock() }
        return leases[snapshotId] ?? 0
    }

    /// Relation terminal: the leases it held are released.
    public func forgetLeases(_ snapshotIds: [UInt64]) {
        lock.lock(); defer { lock.unlock() }
        for sid in snapshotIds { leases[sid] = nil }
    }

    // -- the build --

    private func buildFresh() -> StableInventorySnapshot? {
        let now = monotonicNowMillis()
        lock.lock()
        if retired { lock.unlock(); return nil }
        if lastBuildAttemptMono != Int64.min,
           now - lastBuildAttemptMono < StableInventorySnapshot.minBuildGapMs {
            deferredByRateCount += 1
            lock.unlock()
            return nil
        }
        if leasedCountLocked() >= StableInventorySnapshot.maxLeased {
            deferredByLeasesCount += 1
            lock.unlock()
            return nil
        }
        lastBuildAttemptMono = now
        lock.unlock()

        // one consistent streaming walk of the DURABLE store -- the seen cache
        // is not consulted anywhere on this path (the card's semantic negative)
        let started = monotonicNowMillis()
        var raw: [Data] = []
        var breachBudget = false
        var breachBounds = false
        store.forEachHeldMsgId { id in
            if monotonicNowMillis() - started > StableInventorySnapshot.readBudgetMs {
                breachBudget = true
                return false
            } else if raw.count >= StableInventorySnapshot.maxRows {
                breachBounds = true
                return false
            } else {
                raw.append(id)
                return true
            }
        }
        if breachBounds {
            lock.lock(); refusedByBoundsCount += 1; lock.unlock()
            return nil
        }
        let totalBytes = raw.reduce(0) { $0 + $1.count }
        if breachBudget || totalBytes > StableInventorySnapshot.maxIdBytes {
            lock.lock(); abortedByBudgetCount += 1; lock.unlock()
            return nil
        }
        guard let sid = nextSnapshotId() else { return nil }
        guard let snap = try? StableInventorySnapshot(
            snapshotId: sid, ids: raw, capturedAtMono: monotonicNowMillis()
        ) else {
            // the durable store promised distinctness; if the walk ever showed
            // otherwise the capture is refused, never falsified
            return nil
        }
        lock.lock()
        let old = current
        let keepElder = (old != nil && (leases[old!.snapshotId] ?? 0) > 0)
        predecessor = keepElder ? old : nil
        if !keepElder, let old = old { leases.removeValue(forKey: old.snapshotId) }
        current = snap
        leases[snap.snapshotId] = 0
        lock.unlock()
        return snap
    }

    private func leasedCountLocked() -> Int {
        var n = 0
        if let cur = current, (leases[cur.snapshotId] ?? 0) > 0 { n += 1 }
        if let pre = predecessor, (leases[pre.snapshotId] ?? 0) > 0 { n += 1 }
        return n
    }
}
