import Foundation
import SQLite3
import GodstoneCore

// SYNTHESIZED gap-closure file -- the iOS twin of android/.../mesh/store/
// MessageStore.kt, realised for GMP/2.1 per ADR-001 §5 + ADR-004 (Stage 3
// Phase G). The schema, INSERT OR IGNORE dedup, window-function eviction,
// SUM(LENGTH(payload)) byte accounting and priority ORDER BY are byte-identical
// to the Android StoreSchema so the two stores are query-compatible and build
// the same anti-entropy digest from the same held set (ADR-004 criterion 6).

private let storeSqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Persistent hold for relayed and locally-originated frames -- the iOS twin of
/// the Android `MessageStore` interface.
///
/// The router treats the store as the source of truth for what this node
/// carries, so an encounter with any peer can be answered from disk without an
/// in-memory index. Frames are retained until delivered or aged out, which is
/// the whole point of a delay-tolerant epidemic router.
///
/// GMP/2.1 schema v2 (ADR-001 §5 / ADR-004): the primary key is the 16-byte
/// content-derived msg_id BLOB; there is no header timestamp column (GMP/2.1
/// carries no header timestamp -- created_at lives inside the sealed payload)
/// and no priority-as-source column (priority is 3 flag bits in `flags`; the
/// `priority` column here is a denormalised query aid derived from
/// `Priority.fromFlags(flags)` so ORDER BY / eviction can avoid SQLite's lack
/// of a bitwise shift operator). Retention is receipt-relative
/// (`received_at`), not creation-relative. There is no installed base (ADR-001
/// §5), so no migration code is written: an upgrade drops and recreates the
/// table.
/// The outcome of a durable persist, shared semantically with Android (Stage
/// 4B.1). Mirrors `io.godstone.mesh.store.MessageStore.PersistResult`.
///
/// The router must distinguish these to keep the durable `UNIQUE(msg_id)` the
/// authoritative dedup decision (B1) and to refuse to forward what it does not
/// durably hold (B2): only `heldNew` is forwarded/delivered; `heldDuplicate`
/// is suppressed (already held, do not re-relay); `rejectedCapacity` and
/// `failedStorage` leave the in-memory dedup window untouched so the same
/// msg_id may be re-offered after the store recovers or has room.
public enum PersistResult: Sendable, Equatable {
    /// Newly inserted and still present after capacity enforcement.
    case heldNew
    /// Already held on a duplicate msg_id (INSERT OR IGNORE no-op) and still present.
    case heldDuplicate
    /// Inserted but then evicted by the hard cap (or a duplicate whose row was evicted): not durably held.
    case rejectedCapacity
    /// A storage exception occurred inside the transaction; it was rolled back.
    case failedStorage
}

public protocol MessageStore: AnyObject {
    /// Durably hold `frame`, recording the peer it was received from.
    ///
    /// Returns a [PersistResult]. The row is present in the durable store at or
    /// before the moment this returns for `.heldNew` / `.heldDuplicate`; for
    /// `.rejectedCapacity` / `.failedStorage` the row is NOT durably held and the
    /// caller MUST NOT forward, deliver or permanently mark the id seen (B1/B2,
    /// ADR-004 / Stage 4B.1). The insert, hard-cap enforcement and final
    /// membership check run in one transaction (B3); a storage exception is
    /// rolled back and reported as `.failedStorage` rather than thrown, so one
    /// bad operation cannot kill the inbound receive collector. Mirrors Android
    /// `MessageStore.persist`.
    func persist(_ frame: FrameV2, receivedFrom: Data) -> PersistResult
    /// All held frames, SOS-first then by priority and recency.
    func allHeldOrderedByPriority() -> [FrameV2]
    /// msg_ids of every held frame, for bloom-digest construction (order-agnostic).
    func allHeldMsgIds() -> [Data]
    /// Stream held frames in priority order, stopping as soon as `visit`
    /// returns false. Pages rows and abandons the cursor the moment visit stops.
    func forEachHeldOrderedByPriority(_ visit: (FrameV2) -> Bool)
    /// Stream held msg_ids, stopping as soon as `visit` returns false.
    func forEachHeldMsgId(_ visit: (Data) -> Bool)
    /// Total stored bytes (sum of payloads + per-row bookkeeping allowance).
    var heldBytes: Int64 { get }
}

/// Schema + SQL shared in spirit with the Android `StoreSchema`. Keeping the
/// SQL byte-identical means the bounded-capacity eviction, the INSERT OR IGNORE
/// dedup and the priority ORDER BY run against the SAME real on-disk SQLite in
/// CI as production -- on iOS the production engine IS sqlite3 (no
/// SQLCipher/sqlite-jdbc seam as on Android), so the invariants proven host-side
/// are the invariants production enforces. At-rest encryption is iOS Data
/// Protection (a device concern, not exercised host-side), the same split as
/// Android's SQLCipher page encryption.
internal enum StoreSchema {
    static let dbName = "godstone_messages.db"
    static let dbVersion = 2
    static let table = "held_frames"
    static let colMsgId = "msg_id"
    static let colType = "type"
    static let colTtl = "ttl"
    static let colHopCount = "hop_count"
    static let colFlags = "flags"
    static let colPriority = "priority"
    static let colRoutingTag = "routing_tag"
    static let colPayload = "payload"
    static let colReceivedFrom = "received_from"
    static let colReceivedAt = "received_at"

    /// Per-row bookkeeping beyond the payload blob (columns + page overhead).
    static let rowOverhead: Int64 = 64

    static let createSql = """
        CREATE TABLE \(table) (
            \(colMsgId) BLOB PRIMARY KEY,
            \(colType) INTEGER,
            \(colTtl) INTEGER,
            \(colHopCount) INTEGER,
            \(colFlags) INTEGER,
            \(colPriority) INTEGER,
            \(colRoutingTag) BLOB,
            \(colPayload) BLOB,
            \(colReceivedFrom) BLOB,
            \(colReceivedAt) INTEGER
        )
        """

    /// Idempotent create for engines that reopen an existing file.
    static let createSqlIfNotExists =
        createSql.replacingOccurrences(of: "CREATE TABLE ", with: "CREATE TABLE IF NOT EXISTS ")

    /// Total stored bytes: sum of every payload plus a fixed per-row bookkeeping
    /// allowance. The precise measure the bounded-capacity invariant is enforced
    /// against (ADR-004 §4).
    static let heldBytesSql =
        "SELECT COALESCE(SUM(LENGTH(\(colPayload))) + COUNT(*) * \(rowOverhead), 0) FROM \(table)"

    /// Precise bounded-capacity eviction (Stage 3 Phase E, replacing the
    /// approximate row-count form). Deletes the SMALLEST prefix of rows, ordered
    /// NON-SOS-FIRST then oldest-received, whose cumulative (payload +
    /// rowOverhead) byte cost meets or exceeds the overshoot. The window
    /// function walks candidates in eviction order, `cum` is the running total
    /// INCLUDING the current row, `cum - sz` is the running total BEFORE it; a
    /// row is selected while the total before it was still short of the
    /// overshoot, so the selected prefix is exactly what is needed to return
    /// under the cap.
    ///
    /// Ordering: `(priority = 0) ASC` puts non-SOS (0) before SOS (1), so SOS is
    /// evicted LAST -- only after every non-SOS row has been evicted. Because
    /// the candidate set is ALL rows, the prefix always reaches the overshoot,
    /// so the store ALWAYS returns to or under the cap: all-SOS flooding stays
    /// inside the configured hard cap (ADR-004 criterion 4). Bind: (1) overshoot.
    static let evictPrefixSql = """
        DELETE FROM \(table) WHERE \(colMsgId) IN (
            SELECT \(colMsgId) FROM (
                SELECT \(colMsgId), (LENGTH(\(colPayload)) + \(rowOverhead)) AS sz,
                       SUM(LENGTH(\(colPayload)) + \(rowOverhead)) OVER (
                           ORDER BY (\(colPriority) = 0) ASC, \(colReceivedAt) ASC) AS cum
                FROM \(table)
            ) WHERE cum - sz < ?
        )
        """

    /// Priority-order clause: SOS-first (priority 0), then priority asc, then
    /// newest-received first (recency tie-break). Byte-identical to Android.
    static let priorityOrder = "\(colPriority) ASC, \(colReceivedAt) DESC"

    /// Membership check: true iff a row with `msg_id` is present. The load-bearing
    /// final-presence query run AFTER capacity enforcement inside the persist
    /// transaction (B2/B3): `persist` is truthful only when this confirms the row
    /// survived eviction. Bind: (1) msg_id. Byte-identical to Android.
    static let containsSql = "SELECT 1 FROM \(table) WHERE \(colMsgId) = ? LIMIT 1"
}

/// A stored row before it is typed into a FrameV2 (the type code may be
/// unknown / corrupt).
internal struct StoreRow {
    let typeCode: Int32
    let msgId: Data
    let routingTag: Data
    let ttl: Int32
    let hopCount: Int32
    let flags: Int32
    let payload: Data

    /// Reconstruct a FrameV2, or nil if the row has an unknown type code or
    /// fails the FrameV2 invariants (skipped, not crashed -- forward-compat).
    func toFrame() -> FrameV2? {
        guard let type = TypeV2(rawValue: UInt8(typeCode)),
              msgId.count == 16,
              routingTag.count == 4,
              ttl <= Int32(FrameV2.maxTtl),
              hopCount <= Int32(FrameV2.maxTtl),
              payload.count <= FrameV2.maxPayload else { return nil }
        return FrameV2(type: type,
                       msgId: msgId,
                       routingTag: routingTag,
                       ttl: UInt8(ttl),
                       hopCount: UInt8(hopCount),
                       flags: UInt16(flags),
                       payload: payload)
    }
}

/// Durable message store backed by the system `sqlite3` C API.
///
/// On iOS this is the SAME engine in production and in CI (sqlite3 is
/// auto-linked on Apple platforms; `GodstoneCore/ArchiveRepository` already
/// uses it), so the store tests run the real production SQL on a real on-disk
/// file. At-rest encryption is iOS Data Protection: the DB file is created with
/// `FileProtectionType.complete` (encrypted at rest with a device-passcode-derived
/// key). On the macOS host this attribute is accepted but not enforced, so the
/// SQL invariants run in CI while the encryption is device-verified -- the same
/// split as Android's SQLCipher.
public final class SqliteMessageStore: MessageStore {
    private var handle: OpaquePointer?
    private let lock = NSLock()
    private let maxBytes: Int64
    /// The data-protection class the DB file is created with. Pinned to
    /// `.complete` (production default) so a regression to a weaker class is a
    /// test failure, not a silent weakening of at-rest encryption.
    public let fileProtection: FileProtectionType

    /// Open (or create) the store at `url` with a `maxBytes` hard cap.
    public init(url: URL, maxBytes: Int64,
                fileProtection: FileProtectionType = .complete) {
        self.maxBytes = maxBytes
        self.fileProtection = fileProtection
        // Ensure the parent directory exists (application support / temp dir).
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let path = url.path
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            sqlite3_close_v2(db)
            return
        }
        handle = db
        sqlite3_exec(db, StoreSchema.createSqlIfNotExists, nil, nil, nil)
        // At-rest encryption: mark the file complete-protection. Best-effort --
        // on the macOS host this is accepted but not enforced (device concern).
        try? FileManager.default.setAttributes(
            [.protectionKey: fileProtection], ofItemAtPath: path)
    }

    deinit { if let db = handle { sqlite3_close_v2(db) } }

    // MARK: - MessageStore

    public func persist(_ frame: FrameV2, receivedFrom: Data) -> PersistResult {
        persistAt(frame, receivedFrom: receivedFrom,
                  receivedAt: Int64(Date().timeIntervalSince1970 * 1000))
    }

    public var heldBytes: Int64 {
        withDb { db in heldBytesNoLock(db) } ?? 0
    }

    public func allHeldOrderedByPriority() -> [FrameV2] {
        var out: [FrameV2] = []
        forEachHeldOrderedByPriority { out.append($0); return true }
        return out
    }

    public func allHeldMsgIds() -> [Data] {
        var out: [Data] = []
        forEachHeldMsgId { out.append($0); return true }
        return out
    }

    public func forEachHeldOrderedByPriority(_ visit: (FrameV2) -> Bool) {
        withDb { db in
            let sql = "SELECT \(StoreSchema.colType), \(StoreSchema.colMsgId), " +
                "\(StoreSchema.colRoutingTag), \(StoreSchema.colTtl), " +
                "\(StoreSchema.colHopCount), \(StoreSchema.colFlags), " +
                "\(StoreSchema.colPayload) FROM \(StoreSchema.table) " +
                "ORDER BY \(StoreSchema.priorityOrder)"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                sqlite3_finalize(stmt); return
            }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                let row = StoreRow(
                    typeCode: sqlite3_column_int(stmt, 0),
                    msgId: readBlob(stmt, 1),
                    routingTag: readBlob(stmt, 2),
                    ttl: sqlite3_column_int(stmt, 3),
                    hopCount: sqlite3_column_int(stmt, 4),
                    flags: sqlite3_column_int(stmt, 5),
                    payload: readBlob(stmt, 6))
                guard let frame = row.toFrame() else { continue }   // skip unknown-type
                if !visit(frame) { return }
            }
        }
    }

    public func forEachHeldMsgId(_ visit: (Data) -> Bool) {
        withDb { db in
            let sql = "SELECT \(StoreSchema.colMsgId) FROM \(StoreSchema.table)"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                sqlite3_finalize(stmt); return
            }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                if !visit(readBlob(stmt, 0)) { return }
            }
        }
    }

    // MARK: - Internals (test-exposed for deterministic eviction)

    /// Persist with an explicit received_at (millis), so eviction oldest-first
    /// and priority tie-breaks do not race the wall clock in tests. Inserts,
    /// enforces the hard cap and checks final membership in ONE transaction
    /// (B2/B3), returning a truthful [PersistResult]. A storage exception inside
    /// the transaction is rolled back and reported as `.failedStorage` -- never
    /// thrown -- so one bad operation cannot kill the inbound receive collector.
    @discardableResult
    internal func persistAt(_ frame: FrameV2, receivedFrom: Data, receivedAt: Int64) -> PersistResult {
        persistAtWithFault(frame, receivedFrom: receivedFrom, receivedAt: receivedAt, fault: nil)
    }

    /// [persistAt] with an explicit per-call fault seam (B3). Tests pass a
    /// one-shot injector that throws between the insert/evict/contains phases to
    /// prove the transaction rolls back and the store reopens valid + bounded;
    /// production always passes `nil` via [persistAt].
    @discardableResult
    internal func persistAtWithFault(
        _ frame: FrameV2, receivedFrom: Data, receivedAt: Int64,
        fault: ((String) throws -> Void)?
    ) -> PersistResult {
        do {
            return try withTransaction { db in
                let ins = insertRowNoLock(db, frame, receivedFrom: receivedFrom, receivedAt: receivedAt)
                guard ins.ok else { return PersistResult.failedStorage }
                if ins.isNew {
                    try fault?("after_insert")
                    let held = heldBytesNoLock(db)
                    if held > maxBytes {
                        evictOldestPrefixNoLock(db, overshoot: held - maxBytes)
                    }
                    try fault?("after_evict")
                }
                try fault?("before_contains")
                let present = containsNoLock(db, frame.msgId)
                switch (present, ins.isNew) {
                case (true, true):   return .heldNew
                case (true, false):  return .heldDuplicate
                default:             return .rejectedCapacity
                }
            }
        } catch {
            return .failedStorage
        }
    }

    /// Evict the smallest oldest (non-SOS-first) prefix that brings the store
    /// back to or under the cap. No-op while under budget. Used outside a
    /// transaction by tests that pre-seed the store; the persist path runs
    /// eviction inside [withTransaction] via [evictOldestPrefixNoLock].
    internal func evictIfOverBudget() {
        let bytes = heldBytes
        guard bytes > maxBytes else { return }
        evictOldestPrefix(overshoot: bytes - maxBytes)
    }

    internal func evictOldestPrefix(overshoot: Int64) {
        withDb { db in evictOldestPrefixNoLock(db, overshoot: overshoot) }
    }

    // MARK: - Transaction + non-locking SQL helpers (B3)
    //
    // The existing `withDb` is a non-recursive NSLock: it MUST NOT be nested
    // (deadlock). The persist transaction therefore holds the connection lock
    // ONCE via `withTransaction` and calls these non-locking helpers inside that
    // critical section, so insert + eviction + final-contains are atomic without
    // re-acquiring the lock.

    private enum StoreTxnError: Error { case openFailed, beginFailed, commitFailed }

    /// Run [body] in ONE transaction holding the connection lock once (B3):
    /// `BEGIN IMMEDIATE` -> body -> `COMMIT`, or `ROLLBACK` if body throws. The
    /// non-locking SQL helpers called inside [body] operate on the locked
    /// connection directly. Mirrors Android `StoreDb.inTransaction` (framework
    /// `beginTransaction`, an EXCLUSIVE write lock -- the "or equivalent sqlite
    /// transaction API" the directive allows).
    private func withTransaction<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard let db = handle else { throw StoreTxnError.openFailed }
        if sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) != SQLITE_OK {
            throw StoreTxnError.beginFailed
        }
        do {
            let result = try body(db)
            if sqlite3_exec(db, "COMMIT", nil, nil, nil) != SQLITE_OK {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                throw StoreTxnError.commitFailed
            }
            return result
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    /// INSERT OR IGNORE the row. Returns `(ok, isNew)`: `ok` is false on a
    /// prepare/step failure; `isNew` is true only when a row was actually
    /// inserted (sqlite3_changes == 1), false when the duplicate was IGNORE'd.
    /// `sqlite3_step == SQLITE_DONE` is true for BOTH a real insert and an
    /// IGNORE no-op, so `sqlite3_changes` is the only way to tell them apart
    /// (Stage 4B.1 / B2 -- mirrors Android's rowId != -1 distinction).
    @inline(__always)
    private func insertRowNoLock(
        _ db: OpaquePointer, _ frame: FrameV2, receivedFrom: Data, receivedAt: Int64
    ) -> (ok: Bool, isNew: Bool) {
        let sql = "INSERT OR IGNORE INTO \(StoreSchema.table) (" +
            "\(StoreSchema.colMsgId), \(StoreSchema.colType), \(StoreSchema.colTtl), " +
            "\(StoreSchema.colHopCount), \(StoreSchema.colFlags), \(StoreSchema.colPriority), " +
            "\(StoreSchema.colRoutingTag), \(StoreSchema.colPayload), " +
            "\(StoreSchema.colReceivedFrom), \(StoreSchema.colReceivedAt)) " +
            "VALUES (?,?,?,?,?,?,?,?,?,?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt); return (false, false)
        }
        defer { sqlite3_finalize(stmt) }
        bindBlob(stmt, 1, frame.msgId)
        sqlite3_bind_int(stmt, 2, Int32(frame.type.rawValue))
        sqlite3_bind_int(stmt, 3, Int32(frame.ttl))
        sqlite3_bind_int(stmt, 4, Int32(frame.hopCount))
        sqlite3_bind_int(stmt, 5, Int32(frame.flags))
        sqlite3_bind_int(stmt, 6, Int32(Priority.fromFlags(frame.flags).rawValue))
        bindBlob(stmt, 7, frame.routingTag)
        bindBlob(stmt, 8, frame.payload)
        bindBlob(stmt, 9, receivedFrom)
        sqlite3_bind_int64(stmt, 10, receivedAt)
        guard sqlite3_step(stmt) == SQLITE_DONE else { return (false, false) }
        return (true, sqlite3_changes(db) == 1)
    }

    /// Final-presence check (B2/B3): true iff a row with `msgId` is present.
    @inline(__always)
    private func containsNoLock(_ db: OpaquePointer, _ msgId: Data) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, StoreSchema.containsSql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt); return false
        }
        defer { sqlite3_finalize(stmt) }
        bindBlob(stmt, 1, msgId)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    /// Total stored bytes on the locked connection.
    @inline(__always)
    private func heldBytesNoLock(_ db: OpaquePointer) -> Int64 {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, StoreSchema.heldBytesSql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt); return 0
        }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int64(stmt, 0) : 0
    }

    /// Delete the oldest non-SOS-first prefix meeting [overshoot] bytes, on the
    /// locked connection.
    @inline(__always)
    private func evictOldestPrefixNoLock(_ db: OpaquePointer, overshoot: Int64) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, StoreSchema.evictPrefixSql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt); return
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, overshoot)
        sqlite3_step(stmt)
    }

    // MARK: - Panic wipe

    /// Delete the store DB file (+ WAL/SHM sidecars). Idempotent. Composed into
    /// the Phase F `PanicWipe` via `KeychainWipeArtifacts.deleteArtifacts()`.
    @discardableResult
    public static func panicWipe(at url: URL) -> Bool {
        let fm = FileManager.default
        var ok = true
        for suffix in ["", "-wal", "-shm"] {
            let p = URL(fileURLWithPath: url.path + suffix)
            do { try fm.removeItem(at: p) } catch { /* absent is fine */ }
            if fm.fileExists(atPath: p.path) { ok = false }
        }
        return ok
    }

    // MARK: - sqlite helpers

    private func withDb<T>(_ body: (OpaquePointer) -> T) -> T? {
        lock.lock(); defer { lock.unlock() }
        guard let db = handle else { return nil }
        return body(db)
    }

    private func bindBlob(_ stmt: OpaquePointer?, _ index: Int32, _ data: Data) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Void in
            sqlite3_bind_blob(stmt, index, raw.baseAddress, Int32(data.count), storeSqliteTransient)
        }
    }

    private func readBlob(_ stmt: OpaquePointer?, _ index: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(stmt, index))
        guard let ptr = sqlite3_column_blob(stmt, index), count > 0 else { return Data() }
        return Data(bytes: ptr, count: count)
    }
}

/// In-memory `MessageStore` for unit tests that need a durable-shaped store
/// without touching sqlite3 -- the iOS twin of Android's `InMemoryMessageStore`.
///
/// Stage 4B.1: contract-parity with `SqliteMessageStore`. `persist` reports the
/// same `PersistResult` distinctions (`.heldNew` / `.heldDuplicate` /
/// `.rejectedCapacity`) so router-level at-most-once and capacity-rejection
/// tests can run without sqlite3. The hard cap defaults to unlimited so existing
/// router tests that never approach a cap compile unchanged; a tight cap
/// exercises the same eviction ordering (non-SOS first, then SOS, newest
/// retained) as the SQL store. A bespoke fake (e.g. `FailingStore`) exercises the
/// `.failedStorage` path.
internal final class InMemoryMessageStore: MessageStore {
    private struct Held { let frame: FrameV2; let receivedAt: Int64 }
    private let lock = NSLock()
    private let maxBytes: Int64
    private var rows: [Data: Held] = [:]

    internal init(maxBytes: Int64 = .max) { self.maxBytes = maxBytes }

    func persist(_ frame: FrameV2, receivedFrom: Data) -> PersistResult {
        lock.lock(); defer { lock.unlock() }
        let isNew = rows[frame.msgId] == nil
        if isNew {
            rows[frame.msgId] = Held(frame: frame, receivedAt: Int64(Date().timeIntervalSince1970 * 1000))
        }
        if totalBytesNoLock > maxBytes { evictUntilUnderCapNoLock() }
        if rows[frame.msgId] != nil && isNew { return .heldNew }
        if rows[frame.msgId] != nil { return .heldDuplicate }
        return .rejectedCapacity   // the just-inserted frame was evicted by the cap
    }

    private var totalBytesNoLock: Int64 {
        // Per-row bookkeeping allowance matches StoreSchema.rowOverhead (64).
        rows.values.reduce(Int64(0)) { $0 + Int64($1.frame.payload.count) + 64 }
    }

    /// Evict oldest non-SOS first (then SOS, oldest first) until <= maxBytes.
    private func evictUntilUnderCapNoLock() {
        // Eviction order: non-SOS (priority != .sos) first, oldest received; then
        // SOS, oldest. `isSos` is 0 for non-SOS and 1 for SOS so ascending puts
        // non-SOS first (evicted before SOS), matching StoreSchema.evictPrefixSql.
        let order = rows.sorted { a, b in
            let aSos = Priority.fromFlags(a.value.frame.flags) == .sos ? 1 : 0
            let bSos = Priority.fromFlags(b.value.frame.flags) == .sos ? 1 : 0
            if aSos != bSos { return aSos < bSos }
            return a.value.receivedAt < b.value.receivedAt
        }
        var total = totalBytesNoLock
        for (id, held) in order {
            if total <= maxBytes { break }
            rows.removeValue(forKey: id)
            total -= Int64(held.frame.payload.count) + 64
        }
    }

    private var sorted: [(frame: FrameV2, receivedAt: Int64)] {
        rows.values.sorted { a, b in
            let pa = Priority.fromFlags(a.frame.flags).rawValue
            let pb = Priority.fromFlags(b.frame.flags).rawValue
            if pa != pb { return pa < pb }            // SOS (0) first
            return a.receivedAt > b.receivedAt        // newest-received first
        }.map { ($0.frame, $0.receivedAt) }
    }

    func allHeldOrderedByPriority() -> [FrameV2] {
        lock.lock(); defer { lock.unlock() }
        return sorted.map { $0.frame }
    }

    func allHeldMsgIds() -> [Data] {
        lock.lock(); defer { lock.unlock() }
        return Array(rows.keys)
    }

    func forEachHeldOrderedByPriority(_ visit: (FrameV2) -> Bool) {
        let ordered: [FrameV2]
        lock.lock(); ordered = sorted.map { $0.frame }; lock.unlock()
        for frame in ordered where !visit(frame) { return }
    }

    func forEachHeldMsgId(_ visit: (Data) -> Bool) {
        let ids: [Data]
        lock.lock(); ids = Array(rows.keys); lock.unlock()
        for id in ids where !visit(id) { return }
    }

    var heldBytes: Int64 {
        lock.lock(); defer { lock.unlock() }
        return totalBytesNoLock
    }
}