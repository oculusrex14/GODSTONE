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
/// 4B.1). Mirrors `io.godstone.mesh.store.PersistResult` (top-level on both
/// platforms).
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

/// Outcome of an atomic DIRECT outbound enqueue operation (C6.6 / C6.6.1).
///
/// Commits canonical FrameV2 durable hold in `held_frames` and initial
/// `delivery_state` record in ONE transaction on the underlying SQLite connection.
public enum OutboundEnqueueResult: Sendable, Equatable {
    /// A new DIRECT message was atomically persisted in held_frames and delivery_state (QUEUED_DURABLY).
    case created(FrameV2)
    /// An idempotent retry of the SAME logical message with matching SINGLE_RECIPIENT binding and exact canonical frame.
    case alreadyQueuedSameBinding(FrameV2)
    /// A held frame exists with matching msg_id but its fields/content differ from requested frame.
    case canonicalFrameMismatch
    /// The new frame was evicted during capacity enforcement; transaction rolled back, 0 rows added.
    case rejectedCapacity
    /// A delivery record exists with a DIFFERENT recipient or ack mode; transaction rolled back.
    case conflictRecipient
    /// The delivery record is already in a terminal state (ACKED, EXPIRED, CANCELLED); transaction rolled back.
    case rejectedTerminalState
    /// Pre-existing state was inconsistent (held without delivery, delivery without held, wrong provenance, or corrupt); transaction rolled back.
    case inconsistentState
    /// A real SQL / IO failure occurred during the transaction; rolled back.
    case storageFailure
    /// The frame, recipient, or localOriginNodeId violates DIRECT policy / length / flags before SQL.
    case invalidArgument
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

    /// Atomically enqueue a canonical DIRECT outbound `frame` for `expectedRecipient`
    /// originating from `localOriginNodeId` (C6.6 / C6.6.1).
    ///
    /// In ONE transaction:
    /// - Inserts `frame` into held_frames with received_from = `localOriginNodeId`;
    /// - Enforces bounded capacity;
    /// - Verifies exact canonical `frame` survived capacity enforcement;
    /// - Inserts delivery_state with state QUEUED_DURABLY, ackMode SINGLE_RECIPIENT, and `expectedRecipient`;
    /// - Commits only if all succeed.
    ///
    /// Validates DIRECT policy (type == .message, priority == .direct, SEALED present, HAS_POW absent,
    /// 16-byte msg_id, 16-byte expectedRecipient, 16-byte localOriginNodeId) before transaction.
    func enqueueDirectOutbound(_ frame: FrameV2, expectedRecipient: Data, localOriginNodeId: Data) -> OutboundEnqueueResult

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
/// Durable delivery primitives the `SqliteDeliveryRepository` depends on (C6.4-A
/// iOS mirror of Android `StoreDb`). The repository is constructed against this
/// protocol, not the concrete `SqliteMessageStore`, so the C6.4-A storage-failure
/// tests can supply a `FaultingDeliveryStore` (a controlled failing handle /
/// selective fault seam -- NOT a corrupt random temp file). Every method is
/// `throws`: a SQL / IO / missing-handle failure is thrown and mapped by the
/// repository to a typed `.storageFailure`, NEVER folded into nil / false / 0
/// (absence / conflict / no-match use those sentinels). `SqliteMessageStore`
/// conforms in production.
internal protocol DeliveryStore: AnyObject {
    /// Read the delivery row for `msgId`, or nil if no row exists. Throws on a
    /// storage failure (distinct from the nil absence result).
    func readDelivery(_ msgId: Data) throws -> DeliveryRow?
    /// Atomically create the delivery row. Returns true iff a NEW row was
    /// inserted (ON CONFLICT DO NOTHING -> false). Throws on storage failure.
    func insertDelivery(_ msgId: Data, stateOrdinal: Int32, ackModeOrdinal: Int32,
                        expectedRecipient: Data?) throws -> Bool
    /// Run a guarded delivery UPDATE (the C6.4-F/H CAS). Returns the affected
    /// row count (0/1; >1 is an invariant violation). `bytesArgs` are the BLOB
    /// binds in order, with nil for a SQL NULL. Throws on storage failure.
    func execDeliveryUpdate(_ sql: String, bytesArgs: [Data?]) throws -> Int
}

internal enum StoreSchema {
    static let dbName = "godstone_messages.db"
    /// Schema logical revision (C6.4-E / C6.4.1). Mirrors Android
    /// `StoreSchema.DB_VERSION`. Bumped 4 -> 5 by C6.4 (added
    /// `CHECK (length(msg_id) = 16)` on both tables and
    /// `CHECK (state IN (1,2,3,4,5))` on delivery_state). Bumped 5 -> 6 by C6.4.1-G
    /// (added explicit `NOT NULL` to `msg_id` on both tables -- `BLOB PRIMARY KEY`
    /// alone does NOT enforce NOT NULL for a non-INTEGER-PK column in a rowid
    /// table; the `CHECK(length=16)` already rejects NULL, but the explicit
    /// `NOT NULL` makes the invariant legible in the DDL fingerprint and forces a
    /// destructive recreate of any v5 file). The store stamps this into
    /// `PRAGMA user_version`; on open a file whose user_version is OLDER is
    /// transactionally recreated (C6.4.1-D), a CURRENT file is DDL-fingerprint
    /// validated (C6.4.1-E), and a FUTURE file is rejected fail-closed untouched
    /// (C6.4.1-C). No installed base to preserve (ADR-001 §5).
    static let dbVersion: Int32 = 6
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

    /// C6.4-D / C6.4.1-G: the 16-byte msg_id invariant is enforced at the DB
    /// level on BOTH tables (`msg_id BLOB PRIMARY KEY NOT NULL` +
    /// `CHECK (length(msg_id) = 16)`). The GMP/2.1 msg_id is BLAKE2s-128 = 16
    /// bytes; `FrameV2.init` already preconditions `msgId.count == 16`, so this
    /// is defense-in-depth (a row can only be created via the wire path, which
    /// guards first). Mirrors Android `StoreSchema.CREATE_SQL`.
    static let createSql = """
        CREATE TABLE \(table) (
            \(colMsgId) BLOB PRIMARY KEY NOT NULL,
            \(colType) INTEGER,
            \(colTtl) INTEGER,
            \(colHopCount) INTEGER,
            \(colFlags) INTEGER,
            \(colPriority) INTEGER,
            \(colRoutingTag) BLOB,
            \(colPayload) BLOB,
            \(colReceivedFrom) BLOB,
            \(colReceivedAt) INTEGER,
            CHECK (length(\(colMsgId)) = 16)
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
                WHERE NOT EXISTS (
                    SELECT 1 FROM \(deliveryTable)
                    WHERE \(deliveryTable).\(colDMsgId) = \(table).\(colMsgId)
                      AND \(deliveryTable).\(colDState) IN (1, 2)
                )
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

    // ------------------------------------------------------------------
    // Stage 4C.1 / C6.1 -- delivery_state table (byte-identical cross-platform).
    //
    // Holds the delivery lifecycle state, the ACK mode, AND the intended
    // recipient for a message id in ONE row keyed by msg_id, in the SAME DB file
    // as the held frames, so the ACK authenticity decision (C2) binds to the
    // recipient recorded in durable outbound state INDEPENDENT of the ACK frame.
    // The expected recipient is IMMUTABLE post-creation (C6.1/C6.3): there is no
    // recipient-only write, and a duplicate insert is ON CONFLICT DO NOTHING (it
    // does NOT overwrite the bound recipient). Each mutation is a single atomic
    // SQL statement -- no read-modify-write, no nested transaction -- so the
    // non-recursive connection lock is acquired once per call (iOS) and no
    // transaction seam is needed. A crash between DeliveryTracker's read and
    // write leaves the LAST persisted state on disk (the write did not commit) --
    // the crash-safe semantics ADR-005 requires. (CAS-hardened transitions arrive
    // in C6.4.)
    //
    // The schema CHECK enforces the C6.1 binding invariant at the DB level:
    //   (ack_mode = 0 AND expected_recipient IS NULL) OR
    //   (ack_mode = 1 AND expected_recipient IS NOT NULL AND length = 16)
    // The int state / ack_mode codes are the cross-platform persistence contract
    // (DeliveryState.code / AckMode.rawValue), NOT the enum order, so the two
    // platforms agree even if their enum orders ever diverge. Mirrors Android
    // StoreSchema.
    // ------------------------------------------------------------------
    static let deliveryTable = "delivery_state"
    static let colDMsgId = "msg_id"
    static let colDState = "state"
    static let colDAckMode = "ack_mode"
    static let colDExpected = "expected_recipient"

    /// C6.4-C/D: the delivery row enforces (a) the 16-byte msg_id invariant, (b)
    /// the legal durable-state set (state IN (1,2,3,4,5) -- UNAVAILABLE/code 0 is
    /// NOT a legal durable row, only an in-memory concept), and (c) the C6.1
    /// binding invariant (none -> null recipient; singleRecipient -> 16-byte
    /// recipient). Mirrors Android `StoreSchema.CREATE_DELIVERY_SQL`.
    static let createDeliverySql = """
        CREATE TABLE \(deliveryTable) (
            \(colDMsgId) BLOB PRIMARY KEY NOT NULL,
            \(colDState) INTEGER NOT NULL,
            \(colDAckMode) INTEGER NOT NULL DEFAULT 0,
            \(colDExpected) BLOB,
            CHECK (length(\(colDMsgId)) = 16),
            CHECK (\(colDState) IN (1, 2, 3, 4, 5)),
            CHECK ((\(colDAckMode) = 0 AND \(colDExpected) IS NULL) OR
                   (\(colDAckMode) = 1 AND \(colDExpected) IS NOT NULL AND length(\(colDExpected)) = 16))
        )
        """

    /// Idempotent create for engines that reopen an existing file.
    static let createDeliverySqlIfNotExists =
        createDeliverySql.replacingOccurrences(of: "CREATE TABLE ", with: "CREATE TABLE IF NOT EXISTS ")

    /// Read the delivery row: (state code, ack_mode code, expected recipient or
    /// NULL). Bind: (1) msg_id.
    static let readDeliverySql =
        "SELECT \(colDState), \(colDAckMode), \(colDExpected) FROM \(deliveryTable) WHERE \(colDMsgId) = ?"

    /// Create the delivery row in QUEUED_DURABLY with the ack mode and expected
    /// recipient. ON CONFLICT DO NOTHING: a duplicate insert returns 0 rows (the
    /// caller re-reads to classify the conflict) and does NOT mutate the bound
    /// recipient (C6.1: the historical send intent is never overwritten).
    /// Bind: (1) msg_id, (2) state, (3) ack_mode, (4) expected_recipient.
    static let insertDeliverySql =
        "INSERT INTO \(deliveryTable) (\(colDMsgId), \(colDState), \(colDAckMode), \(colDExpected)) " +
        "VALUES (?, ?, ?, ?) ON CONFLICT(\(colDMsgId)) DO NOTHING"

    /// Drop the delivery row for msg_id. Bind: (1) msg_id. (C6.4: the state column
    /// is advanced via a guarded CAS built in the repository
    /// `execDeliveryUpdate`, NOT via a stale `updateDeliveryStateSql` pre-read
    /// seam; that SQL was removed.)
    static let clearDeliverySql = "DELETE FROM \(deliveryTable) WHERE \(colDMsgId) = ?"
}

/// One `delivery_state` row before it is typed into a `DeliveryRecord` (the
/// state / ack_mode codes may be unknown / corrupt). Mirrors Android `DeliveryRow`.
internal struct DeliveryRow {
    let state: Int32
    let ackMode: Int32
    let expectedRecipient: Data?
}

/// A stored row before it is typed into a FrameV2 (the type code may be
/// unknown / corrupt).
/// Canonical representation: `held_frames.type` stores the unsigned GMP/2 type octet
/// as INTEGER 0...255 (iOS: UInt8 rawValue is persisted as Int32).
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
        guard typeCode >= 0, typeCode <= 255,
              let type = TypeV2(rawValue: UInt8(typeCode)),
              msgId.count == 16,
              routingTag.count == 4,
              ttl >= 0, ttl <= Int32(FrameV2.maxTtl),
              hopCount >= 0, hopCount <= Int32(FrameV2.maxTtl),
              flags >= 0, flags <= 0xFFFF,
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
        // `sqlite3_open_v2` returns SQLITE_OK with a non-nil handle on success;
        // unwrap once so the migration helpers receive a non-optional `OpaquePointer`.
        guard let db = db else { return }
        handle = db
        // C6.4-E / C6.4.1-B/C/D/E: PRAGMA user_version schema versioning -- the
        // iOS twin of Android's `SQLiteOpenHelper.onUpgrade`. The store reads
        // `PRAGMA user_version` (THROWS on a read failure, C6.4.1-B -- never
        // 0-on-failure); an OLDER file is transactionally drop+recreated and
        // stamped (C6.4.1-D); a CURRENT file is DDL-fingerprint validated
        // (C6.4.1-E); a FUTURE file is rejected fail-closed untouched
        // (C6.4.1-C). On ANY migration/validation failure the handle is closed
        // and `handle` is set nil so the store is unusable (every op fails
        // closed) rather than opened against a half-migrated / wrong schema. No
        // installed base (ADR-001 §5: GMP/1 was never shipped). The logical
        // revision number (dbVersion) matches Android DB_VERSION.
        do {
            try runMigrations(db)
        } catch {
            sqlite3_close_v2(db)
            handle = nil
            return
        }
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
    ///
    /// C6.4.1-H: the persist path now uses STRICT throwing helpers
    /// (`insertRowNoLockStrict` / `heldBytesNoLockStrict` /
    /// `evictOldestPrefixNoLockStrict` / `containsNoLockStrict`). Pre-H, the
    /// non-throwing helpers masked a SQL/IO failure as 0 / false / silent, so a
    /// real storage error in heldBytes (reported 0 -> skipped eviction -> over-
    /// cap store silently committed) or in contains (reported false ->
    /// `.rejectedCapacity` for a row that IS held) was CONFLATED with the normal
    /// absence / no-match result and committed. The strict helpers THROW on a
    /// SQL failure; the throw unwinds to `withTransaction` -> ROLLBACK ->
    /// `.failedStorage`, so a storage fault never leaves a half-applied store.
    ///
    /// The fault seam now receives the locked db handle so a test can inject a
    /// REAL SQL failure at a phase (e.g. `DROP TABLE` so the next strict helper's
    /// prepare fails), proving the strict throw -> ROLLBACK path (not just the
    /// phase-boundary throw the B3 tests already cover). Phases: `after_insert`,
    /// `after_heldbytes`, `after_evict`, `before_contains`.
    @discardableResult
    internal func persistAtWithFault(
        _ frame: FrameV2, receivedFrom: Data, receivedAt: Int64,
        fault: ((String, OpaquePointer?) throws -> Void)?
    ) -> PersistResult {
        do {
            return try withTransaction { db in
                // A duplicate (INSERT OR IGNORE no-op) is NOT an error: returns
                // isNew=false without throwing. A real SQL/IO failure throws.
                let isNew = try insertRowNoLockStrict(db, frame, receivedFrom: receivedFrom, receivedAt: receivedAt)
                try fault?("after_insert", db)
                if isNew {
                    let held = try heldBytesNoLockStrict(db)
                    try fault?("after_heldbytes", db)
                    if held > maxBytes {
                        try evictOldestPrefixNoLockStrict(db, overshoot: held - maxBytes)
                    }
                    try fault?("after_evict", db)
                }
                try fault?("before_contains", db)
                let present = try containsNoLockStrict(db, frame.msgId)
                switch (present, isNew) {
                case (true, true):   return .heldNew
                case (true, false):  return .heldDuplicate
                default:             return .rejectedCapacity
                }
            }
        } catch {
            return .failedStorage
        }
    }

    public func enqueueDirectOutbound(
        _ frame: FrameV2,
        expectedRecipient: Data,
        localOriginNodeId: Data
    ) -> OutboundEnqueueResult {
        enqueueDirectOutboundAtWithFault(
            frame,
            expectedRecipient: expectedRecipient,
            localOriginNodeId: localOriginNodeId,
            receivedAt: Int64(Date().timeIntervalSince1970 * 1000),
            fault: nil
        )
    }

    private enum DirectEnqueueError: Error {
        case capacityEvicted
    }

    /// [enqueueDirectOutbound] with an explicit per-call fault seam (C6.6 / C6.6.1).
    ///
    /// In ONE transaction:
    /// 1. Inspects existing delivery_state and held_frames presence.
    /// 2. Checks consistency:
    ///    - If delivery row exists: validates binding, terminal state, local provenance, and canonical frame equality.
    ///    - If held exists without delivery row: fails closed as InconsistentState.
    /// 3. Fresh insert:
    ///    - Inserts frame into held_frames with received_from = `localOriginNodeId`;
    ///    - Enforces hard capacity (evicts non-SOS prefix);
    ///    - Reads back the exact persisted frame and proves it survived capacity enforcement and matches authored frame;
    ///    - Inserts initial delivery_state (QUEUED_DURABLY, SINGLE_RECIPIENT, expectedRecipient).
    /// 4. Commits all operations together. Any exception rolls back all changes.
    internal func enqueueDirectOutboundAtWithFault(
        _ frame: FrameV2,
        expectedRecipient: Data,
        localOriginNodeId: Data,
        receivedAt: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        fault: ((String, OpaquePointer?) throws -> Void)? = nil
    ) -> OutboundEnqueueResult {
        guard frame.msgId.count == 16,
              frame.routingTag.count == 4,
              frame.ttl <= FrameV2.maxTtl,
              frame.hopCount <= FrameV2.maxTtl,
              frame.flags <= 0xFFFF,
              frame.payload.count <= FrameV2.maxPayload,
              expectedRecipient.count == 16,
              localOriginNodeId.count == 16,
              frame.type == .message,
              Priority.fromFlagsStrict(frame.flags) == .direct,
              (frame.flags & FrameV2.Flags.sealed) != 0,
              (frame.flags & FrameV2.Flags.has_pow) == 0
        else {
            return .invalidArgument
        }

        do {
            return try withTransaction { db in
                let existingDelivery = try readDeliveryNoLockStrict(db, frame.msgId)
                let heldRow = try readHeldNoLockStrict(db, frame.msgId)

                if let existing = existingDelivery {
                    guard let state = DeliveryState.fromPersistedCode(existing.state),
                          let ackMode = AckMode.fromCode(existing.ackMode),
                          existing.expectedRecipient?.count == 16
                    else {
                        return .inconsistentState
                    }
                    if state.isTerminal {
                        return .rejectedTerminalState
                    }
                    guard let held = heldRow, let heldFrame = held.frame else {
                        return .inconsistentState
                    }
                    guard held.receivedFrom == localOriginNodeId else {
                        return .inconsistentState
                    }
                    if ackMode != .singleRecipient || expectedRecipient != existing.expectedRecipient {
                        return .conflictRecipient
                    }
                    if heldFrame != frame {
                        return .canonicalFrameMismatch
                    }
                    return .alreadyQueuedSameBinding(heldFrame)
                }

                if heldRow != nil {
                    return .inconsistentState
                }

                let isNew = try insertRowNoLockStrict(db, frame, receivedFrom: localOriginNodeId, receivedAt: receivedAt)
                guard isNew else { return .inconsistentState }

                try fault?("after_held_insert", db)

                let held = try heldBytesNoLockStrict(db)
                if held > maxBytes {
                    try evictOldestPrefixNoLockStrict(db, overshoot: held - maxBytes)
                }

                try fault?("after_evict", db)

                guard let persisted = try readHeldNoLockStrict(db, frame.msgId) else {
                    throw DirectEnqueueError.capacityEvicted
                }
                guard let persistedFrame = persisted.frame,
                      persistedFrame == frame && persisted.receivedFrom == localOriginNodeId else {
                    throw StoreError.stepFailed
                }

                try fault?("before_delivery_insert", db)

                let inserted = try insertDeliveryNoLockStrict(
                    db,
                    msgId: frame.msgId,
                    stateOrdinal: DeliveryState.queuedDurably.code,
                    ackModeOrdinal: AckMode.singleRecipient.rawValue,
                    expectedRecipient: expectedRecipient
                )
                guard inserted else { throw StoreError.stepFailed }

                try fault?("after_delivery_insert", db)

                return .created(persistedFrame)
            }
        } catch DirectEnqueueError.capacityEvicted {
            return .rejectedCapacity
        } catch {
            return .storageFailure
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

    /// C6.4.1-H: strict INSERT OR IGNORE. THROWS `StoreError.prepareFailed` /
    /// `stepFailed` on a SQL/IO failure (no 0/false conflation). Returns `isNew`
    /// (sqlite3_changes == 1); a duplicate (IGNORE no-op) returns false WITHOUT
    /// throwing -- absence is not failure. `sqlite3_step == SQLITE_DONE` is true
    /// for BOTH a real insert and an IGNORE no-op, so `sqlite3_changes` is the
    /// only way to tell them apart (Stage 4B.1 / B2 -- mirrors Android's
    /// rowId != -1 distinction). Used inside `withTransaction` so a throw
    /// unwinds to ROLLBACK -> `.failedStorage`.
    @inline(__always)
    private func insertRowNoLockStrict(
        _ db: OpaquePointer, _ frame: FrameV2, receivedFrom: Data, receivedAt: Int64
    ) throws -> Bool {
        let sql = "INSERT OR IGNORE INTO \(StoreSchema.table) (" +
            "\(StoreSchema.colMsgId), \(StoreSchema.colType), \(StoreSchema.colTtl), " +
            "\(StoreSchema.colHopCount), \(StoreSchema.colFlags), \(StoreSchema.colPriority), " +
            "\(StoreSchema.colRoutingTag), \(StoreSchema.colPayload), " +
            "\(StoreSchema.colReceivedFrom), \(StoreSchema.colReceivedAt)) " +
            "VALUES (?,?,?,?,?,?,?,?,?,?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt); throw StoreError.prepareFailed
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
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw StoreError.stepFailed }
        return sqlite3_changes(db) == 1
    }

    /// C6.4.1-H / C6.6.3: strict final-presence check. THROWS on prepare failure or
    /// any step error (SQLITE_INTERRUPT, SQLITE_BUSY, SQLITE_IOERR).
    /// ONLY SQLITE_DONE indicates absence (returns false).
    /// SQLITE_ROW indicates presence (returns true).
    /// A step error throws StoreError.stepFailed to trigger transaction ROLLBACK and failedStorage.
    @inline(__always)
    private func containsNoLockStrict(_ db: OpaquePointer, _ msgId: Data) throws -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, StoreSchema.containsSql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt); throw StoreError.prepareFailed
        }
        defer { sqlite3_finalize(stmt) }
        bindBlob(stmt, 1, msgId)
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_ROW {
            return true
        }
        if rc == SQLITE_DONE {
            return false
        }
        throw StoreError.stepFailed
    }

    /// C6.6.1 / C6.6.2: strict held-row read. THROWS on a prepare/step error.
    /// Only SQLITE_DONE indicates absence; any non-ROW error throws to trigger ROLLBACK.
    @inline(__always)
    private func readHeldNoLockStrict(_ db: OpaquePointer, _ msgId: Data) throws -> (frame: FrameV2?, receivedFrom: Data, receivedAt: Int64)? {
        let sql = "SELECT \(StoreSchema.colType), \(StoreSchema.colMsgId), \(StoreSchema.colRoutingTag), " +
            "\(StoreSchema.colTtl), \(StoreSchema.colHopCount), \(StoreSchema.colFlags), " +
            "\(StoreSchema.colPayload), \(StoreSchema.colReceivedFrom), \(StoreSchema.colReceivedAt) " +
            "FROM \(StoreSchema.table) WHERE \(StoreSchema.colMsgId) = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt); throw StoreError.prepareFailed
        }
        defer { sqlite3_finalize(stmt) }
        bindBlob(stmt, 1, msgId)
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_DONE { return nil }
        guard rc == SQLITE_ROW else { throw StoreError.stepFailed }
        let typeCode = sqlite3_column_int(stmt, 0)
        let rowMsgId = readBlob(stmt, 1)
        let routingTag = readBlob(stmt, 2)
        let ttl = sqlite3_column_int(stmt, 3)
        let hopCount = sqlite3_column_int(stmt, 4)
        let flags = sqlite3_column_int(stmt, 5)
        let payload = readBlob(stmt, 6)
        let receivedFrom = readBlob(stmt, 7)
        let receivedAt = sqlite3_column_int64(stmt, 8)
        let storeRow = StoreRow(
            typeCode: typeCode,
            msgId: rowMsgId,
            routingTag: routingTag,
            ttl: ttl,
            hopCount: hopCount,
            flags: flags,
            payload: payload
        )
        return (frame: storeRow.toFrame(), receivedFrom: receivedFrom, receivedAt: receivedAt)
    }

    /// C6.4.1-H: strict total-bytes. THROWS on a prepare/step failure. Used
    /// inside `withTransaction`; a throw unwinds to ROLLBACK -> `.failedStorage`.
    /// The non-throwing `heldBytesNoLock` below is kept for the non-transaction
    /// getter `heldBytes` (which swallows via `withDb`); the persist path must
    /// NOT swallow -- a heldBytes failure masked as 0 would skip eviction and
    /// silently commit an over-cap store (the conflation C6.4.1-H closes).
    @inline(__always)
    private func heldBytesNoLockStrict(_ db: OpaquePointer) throws -> Int64 {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, StoreSchema.heldBytesSql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt); throw StoreError.prepareFailed
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw StoreError.stepFailed }
        return sqlite3_column_int64(stmt, 0)
    }

    /// C6.4.1-H: strict eviction. THROWS on a prepare/step failure. Used inside
    /// `withTransaction`; a throw unwinds to ROLLBACK -> `.failedStorage`. The
    /// non-throwing `evictOldestPrefixNoLock` below is kept for the
    /// non-transaction `evictOldestPrefix` (which swallows via `withDb`); the
    /// persist path must NOT swallow -- an eviction failure masked as a no-op
    /// would silently commit an over-cap store.
    @inline(__always)
    private func evictOldestPrefixNoLockStrict(_ db: OpaquePointer, overshoot: Int64) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, StoreSchema.evictPrefixSql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt); throw StoreError.prepareFailed
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, overshoot)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw StoreError.stepFailed }
    }

    /// Total stored bytes on the locked connection. Non-throwing (swallows a
    /// SQL failure as 0) -- used by the `heldBytes` getter outside a
    /// transaction. The persist path uses the strict
    /// `heldBytesNoLockStrict` variant (C6.4.1-H).
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
    /// locked connection. Non-throwing (swallows a SQL failure as a no-op) --
    /// used by `evictOldestPrefix` outside a transaction. The persist path uses
    /// the strict `evictOldestPrefixNoLockStrict` variant (C6.4.1-H).
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

    // MARK: - C6.4-E / C6.4.1-B/C/D/E: PRAGMA user_version schema versioning
    //
    // The iOS twin of Android's `SQLiteOpenHelper.onUpgrade` + onOpen validation.
    // On open, read `PRAGMA user_version` (C6.4.1-B: THROWS on a read failure --
    // never 0-on-failure, which would masquerade as a fresh file and trigger a
    // destructive recreate that destroys real data on an I/O error). Then:
    //   * v < dbVersion (older or fresh=0): transactional drop+recreate both
    //     tables (C6.4.1-D: execStrict on every statement, BEGIN/COMMIT, ROLLBACK
    //     on any failure, no half-migrated handle) and stamp user_version.
    //   * v == dbVersion (current): DDL-fingerprint validate (C6.4.1-E) and open;
    //     a mismatch is rejected fail-closed.
    //   * v > dbVersion (future): reject fail-closed UNTOUCHED (C6.4.1-C) -- a
    //     newer schema this build cannot read is never silently downgraded.
    // No installed base (ADR-001 §5) -> destructive recreate is correct. The
    // logical revision matches Android `StoreSchema.DB_VERSION`.

    private enum StoreError: Error { case handleMissing, prepareFailed, stepFailed, execFailed, schemaMismatch }

    /// C6.4.1-B: read `PRAGMA user_version`. THROWS on a prepare/step failure --
    /// never returns 0-on-failure (a read that silently returns 0 looks like a
    /// fresh file and triggers a destructive recreate, destroying data on a real
    /// I/O error). Absent a successful read the version is unknowable, so fail
    /// closed instead of guessing.
    @inline(__always)
    private func readUserVersion(_ db: OpaquePointer) throws -> Int32 {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt); throw StoreError.prepareFailed
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw StoreError.stepFailed }
        return sqlite3_column_int(stmt, 0)
    }

    /// C6.4.1-D: execute one SQL statement and THROW on any non-OK result so a
    /// migration DDL failure cannot be silently swallowed into a half-migrated
    /// handle. Every migration statement runs through this.
    @inline(__always)
    private func execStrict(_ db: OpaquePointer, _ sql: String) throws {
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK { throw StoreError.execFailed }
    }

    /// Stamp `PRAGMA user_version = version` (persists in the DB header). Strict:
    /// a failed stamp leaves the file with a stale version, so throw (C6.4.1-D).
    @inline(__always)
    private func setUserVersion(_ db: OpaquePointer, _ version: Int32) throws {
        try execStrict(db, "PRAGMA user_version = \(version)")
    }

    /// C6.4.1-E: fingerprint the current-version schema by EXACT DDL match, NOT
    /// substring. `sqlite_master.sql` stores the CREATE text verbatim (SQLite
    /// strips `IF NOT EXISTS`); we compare its whitespace-normalized form to the
    /// expected `StoreSchema` DDL. A file that claims the current user_version
    /// but was created with a different DDL (hand-edited, partially-migrated,
    /// or silently-downgraded) fails this check and is rejected fail-closed.
    /// Mirrors Android `StoreSchema.validateSchema`.
    private func validateSchema(_ db: OpaquePointer) throws {
        try checkTableDdl(db, name: StoreSchema.table, expected: StoreSchema.createSql)
        try checkTableDdl(db, name: StoreSchema.deliveryTable, expected: StoreSchema.createDeliverySql)
    }

    private func checkTableDdl(_ db: OpaquePointer, name: String, expected: String) throws {
        // name is an internal constant, not user input -> string interpolation is safe.
        let sql = "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = '\(name)'"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt); throw StoreError.prepareFailed
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let raw = sqlite3_column_text(stmt, 0) else {
            throw StoreError.schemaMismatch
        }
        let actual = String(cString: raw)
        guard normalizeSql(actual) == normalizeSql(expected) else { throw StoreError.schemaMismatch }
    }

    /// Collapse runs of whitespace to a single space and trim, so the DDL
    /// compare is a fingerprint of the SCHEMA, not of its formatting.
    @inline(__always)
    private func normalizeSql(_ sql: String) -> String {
        sql.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// C6.4.1-B/C/D: schema versioning + migration. See the MARK comment above.
    /// Throws on any failure; the init closes the handle on throw so the store
    /// is unusable rather than half-migrated.
    private func runMigrations(_ db: OpaquePointer) throws {
        let v = try readUserVersion(db)
        if v < StoreSchema.dbVersion {
            // Older (or fresh, v=0): destructive recreate. No installed base
            // (ADR-001 §5) -> dropping data is correct. Transactional so a
            // mid-migration crash leaves the file on the OLD schema, not a
            // half-migrated one; every statement runs through execStrict.
            try execStrict(db, "BEGIN")
            do {
                try execStrict(db, "DROP TABLE IF EXISTS \(StoreSchema.deliveryTable)")
                try execStrict(db, "DROP TABLE IF EXISTS \(StoreSchema.table)")
                try execStrict(db, StoreSchema.createSql)
                try execStrict(db, StoreSchema.createDeliverySql)
                try setUserVersion(db, StoreSchema.dbVersion)
                try execStrict(db, "COMMIT")
            } catch {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                throw error
            }
            return
        }
        if v == StoreSchema.dbVersion {
            // Current: validate the DDL fingerprint. A current-version file
            // with a non-matching schema is rejected fail-closed -- the belt-
            // and-suspenders IF NOT EXISTS creates are NOT run here, so a
            // mismatch is never papered over.
            try validateSchema(db)
            return
        }
        // v > current: a FUTURE schema. Fail closed, leave the file untouched.
        // No invented downgrade of a schema this build cannot read.
        throw StoreError.schemaMismatch
    }

    // MARK: - Stage 4C.1 / C6.1 / C6.4 delivery_state row (throwing primitives)
    //
    // C6.4-A: every delivery primitive is `throws` -- a SQL / IO / missing-handle
    // failure is THROWN and mapped by `SqliteDeliveryRepository` to a typed
    // `.storageFailure`, NEVER folded into nil / false / 0 (absence / conflict /
    // no-match use those sentinels). This is the "throwing strict primitives"
    // directive for iOS (Android catches `Exception` at the boundary; iOS throws
    // from the primitive and catches at the repository). Each operation is one SQL
    // statement under the connection lock; row counts come from
    // `sqlite3_changes(db)` (Android uses executeUpdateDelete(); JDBC uses
    // executeUpdate()). Mirrors the Android `StoreDb` delivery methods
    // byte-identically. The stale pre-read `updateDeliveryState` / `clearDelivery`
    // seams were REMOVED (C6.4-F/J): state advances via a guarded CAS built in the
    // repository and run through `execDeliveryUpdate`; clear is
    // `execDeliveryUpdate(clearDeliverySql)`.

    /// Throwing connection accessor (C6.4-A): throws `StoreError.handleMissing`
    /// when the DB handle is nil, otherwise runs `body` under the connection lock.
    /// Distinct from the non-throwing `withDb` (used by the held-frames surface that
    /// reports failure as nil / 0 / false -- NOT part of the C6.4-A delivery
    /// surface).
    private func withDbThrowing<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard let db = handle else { throw StoreError.handleMissing }
        return try body(db)
    }

    private func readDeliveryNoLockStrict(_ db: OpaquePointer, _ msgId: Data) throws -> DeliveryRow? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, StoreSchema.readDeliverySql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt); throw StoreError.prepareFailed
        }
        defer { sqlite3_finalize(stmt) }
        bindBlob(stmt, 1, msgId)
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_DONE { return nil } // no row -- absence, NOT failure
        guard rc == SQLITE_ROW else { throw StoreError.stepFailed }
        let state = sqlite3_column_int(stmt, 0)
        let ackMode = sqlite3_column_int(stmt, 1)
        // Distinguish SQL NULL (no recipient) from a zero-length blob.
        let expected: Data? =
            sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : readBlob(stmt, 2)
        return DeliveryRow(state: state, ackMode: ackMode, expectedRecipient: expected)
    }

    private func insertDeliveryNoLockStrict(
        _ db: OpaquePointer,
        msgId: Data,
        stateOrdinal: Int32,
        ackModeOrdinal: Int32,
        expectedRecipient: Data?
    ) throws -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, StoreSchema.insertDeliverySql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt); throw StoreError.prepareFailed
        }
        defer { sqlite3_finalize(stmt) }
        bindBlob(stmt, 1, msgId)
        sqlite3_bind_int(stmt, 2, stateOrdinal)
        sqlite3_bind_int(stmt, 3, ackModeOrdinal)
        if let r = expectedRecipient { bindBlob(stmt, 4, r) } else { sqlite3_bind_null(stmt, 4) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw StoreError.stepFailed }
        return sqlite3_changes(db) > 0   // 1 inserted, 0 on conflict (DO NOTHING)
    }

    /// Read the delivery row for `msgId`: (state code, ack_mode code, expected
    /// recipient), or nil if NO row exists (absence). Throws on a storage failure
    /// (prepare/step error or missing handle) -- distinct from the nil absence
    /// result (C6.4-A). The expected recipient is nil when the column is SQL NULL
    /// (no recipient bound), distinct from an empty blob.
    internal func readDelivery(_ msgId: Data) throws -> DeliveryRow? {
        try withDbThrowing { db in try readDeliveryNoLockStrict(db, msgId) }
    }

    /// Atomically create the delivery row in QUEUED_DURABLY with the ack mode and
    /// expected recipient. Returns true iff a NEW row was inserted; false if a row
    /// already exists (ON CONFLICT DO NOTHING) -- the caller re-reads to classify
    /// the conflict. The expected recipient is NEVER updated on an existing row.
    /// Throws on a storage failure (C6.4-A).
    internal func insertDelivery(_ msgId: Data, stateOrdinal: Int32, ackModeOrdinal: Int32,
                                 expectedRecipient: Data?) throws -> Bool {
        try withDbThrowing { db in
            try insertDeliveryNoLockStrict(
                db,
                msgId: msgId,
                stateOrdinal: stateOrdinal,
                ackModeOrdinal: ackModeOrdinal,
                expectedRecipient: expectedRecipient
            )
        }
    }

    /// Run a guarded delivery UPDATE (the C6.4-F/H CAS). Returns the affected row
    /// count (0/1; >1 is an invariant violation the repository maps to
    /// `.storageFailure`). `bytesArgs` are the BLOB binds in order, with nil for a
    /// SQL NULL. Throws on a storage failure (C6.4-A). This REPLACES the stale
    /// `updateDeliveryState` pre-read seam: the repository builds the guarded
    /// `UPDATE ... WHERE msg_id AND state IN (...) [AND ack_mode ...] [AND
    /// expected_recipient = ?]` and decides `.applied` by the affected count, not a
    /// pre-read. Mirrors Android `StoreDb.execDeliveryUpdate`.
    internal func execDeliveryUpdate(_ sql: String, bytesArgs: [Data?]) throws -> Int {
        try withDbThrowing { db in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                sqlite3_finalize(stmt); throw StoreError.prepareFailed
            }
            defer { sqlite3_finalize(stmt) }
            for (i, arg) in bytesArgs.enumerated() {
                if let d = arg { bindBlob(stmt, Int32(i + 1), d) } else { sqlite3_bind_null(stmt, Int32(i + 1)) }
            }
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw StoreError.stepFailed }
            return Int(sqlite3_changes(db))
        }
    }

    /// Test seam (C6.5/C6.4-C): run a raw statement with NO BLOB binds on the SAME
    /// locked connection -- used to flip `PRAGMA ignore_check_constraints` so the
    /// corrupt-state tests can plant a `state = 0` / `state = 999` / mismatched
    /// binding row past the new schema CHECKs (the CHECK would otherwise reject
    /// the write). Production never calls this. Mirrors Android `StoreDb.execRawSql`.
    internal func execRawSql(_ sql: String) throws {
        try withDbThrowing { db in
            if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK { throw StoreError.execFailed }
        }
    }

    /// Test seam (C6.5): run a raw UPDATE on the SAME locked connection the
    /// delivery table uses, so the corrupt-state tests can mutate `state` /
    /// `ack_mode` to an unknown code WITHOUT opening a second connection (SQLite
    /// cross-connection file contention). Mirrors `JdbcStoreDb.execRawUpdate` on
    /// Android. Binds one BLOB parameter per `bytesArgs` entry (`?`, in order) and
    /// returns `sqlite3_changes(db)` (0 if the CHECK rejected the write -- wrap the
    /// caller in `PRAGMA ignore_check_constraints` via `execRawSql` to plant past
    /// the CHECK). Production never calls this.
    @discardableResult
    internal func execRawUpdate(_ sql: String, _ bytesArgs: [Data]) -> Int {
        withDb { db in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                sqlite3_finalize(stmt); return 0
            }
            defer { sqlite3_finalize(stmt) }
            for (i, arg) in bytesArgs.enumerated() {
                bindBlob(stmt, Int32(i + 1), arg)
            }
            sqlite3_step(stmt)
            return Int(sqlite3_changes(db))
        } ?? 0
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

/// C6.4-A: `SqliteMessageStore` conforms to `DeliveryStore` so the production
/// repository is constructed against the throwing-primitive protocol (and tests
/// can supply a `FaultingDeliveryStore`). The witnesses are the `internal throws`
/// methods above; the conformance is internal.
extension SqliteMessageStore: DeliveryStore {}

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
    private struct Held { let frame: FrameV2; let receivedFrom: Data; let receivedAt: Int64 }
    private let lock = NSLock()
    private let maxBytes: Int64
    private var rows: [Data: Held] = [:]
    private var deliveryRows: [Data: DeliveryRow] = [:]

    internal init(maxBytes: Int64 = .max) { self.maxBytes = maxBytes }

    func persist(_ frame: FrameV2, receivedFrom: Data) -> PersistResult {
        lock.lock(); defer { lock.unlock() }
        let isNew = rows[frame.msgId] == nil
        if isNew {
            rows[frame.msgId] = Held(frame: frame, receivedFrom: receivedFrom, receivedAt: Int64(Date().timeIntervalSince1970 * 1000))
        }
        if totalBytesNoLock > maxBytes { evictUntilUnderCapNoLock() }
        if rows[frame.msgId] != nil && isNew { return .heldNew }
        if rows[frame.msgId] != nil { return .heldDuplicate }
        return .rejectedCapacity   // the just-inserted frame was evicted by the cap
    }

    func enqueueDirectOutbound(_ frame: FrameV2, expectedRecipient: Data, localOriginNodeId: Data) -> OutboundEnqueueResult {
        guard frame.msgId.count == 16,
              frame.routingTag.count == 4,
              frame.ttl <= FrameV2.maxTtl,
              frame.hopCount <= FrameV2.maxTtl,
              frame.flags <= 0xFFFF,
              frame.payload.count <= FrameV2.maxPayload,
              expectedRecipient.count == 16,
              localOriginNodeId.count == 16,
              frame.type == .message,
              Priority.fromFlagsStrict(frame.flags) == .direct,
              (frame.flags & FrameV2.Flags.sealed) != 0,
              (frame.flags & FrameV2.Flags.has_pow) == 0
        else {
            return .invalidArgument
        }

        lock.lock(); defer { lock.unlock() }

        let heldEntry = rows[frame.msgId]
        let existingDelivery = deliveryRows[frame.msgId]

        if let existing = existingDelivery {
            guard let state = DeliveryState.fromPersistedCode(existing.state),
                  let ackMode = AckMode.fromCode(existing.ackMode),
                  existing.expectedRecipient?.count == 16
            else {
                return .inconsistentState
            }
            if state.isTerminal {
                return .rejectedTerminalState
            }
            guard let held = heldEntry else {
                return .inconsistentState
            }
            guard held.receivedFrom == localOriginNodeId else {
                return .inconsistentState
            }
            if ackMode != .singleRecipient || expectedRecipient != existing.expectedRecipient {
                return .conflictRecipient
            }
            if held.frame != frame {
                return .canonicalFrameMismatch
            }
            return .alreadyQueuedSameBinding(held.frame)
        }

        if heldEntry != nil {
            return .inconsistentState
        }

        let backupRows = rows
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        rows[frame.msgId] = Held(frame: frame, receivedFrom: localOriginNodeId, receivedAt: now)
        if totalBytesNoLock > maxBytes {
            evictUntilUnderCapNoLock()
        }

        guard let persisted = rows[frame.msgId] else {
            rows = backupRows
            return .rejectedCapacity
        }

        guard persisted.frame == frame && persisted.receivedFrom == localOriginNodeId else {
            rows = backupRows
            return .inconsistentState
        }

        deliveryRows[frame.msgId] = DeliveryRow(
            state: DeliveryState.queuedDurably.code,
            ackMode: AckMode.singleRecipient.rawValue,
            expectedRecipient: expectedRecipient
        )
        return .created(persisted.frame)
    }

    internal func readDeliveryRow(_ msgId: Data) -> DeliveryRow? {
        lock.lock(); defer { lock.unlock() }
        return deliveryRows[msgId]
    }

    internal func updateDeliveryState(_ msgId: Data, state: Int32) {
        lock.lock(); defer { lock.unlock() }
        if let existing = deliveryRows[msgId] {
            deliveryRows[msgId] = DeliveryRow(
                state: state,
                ackMode: existing.ackMode,
                expectedRecipient: existing.expectedRecipient
            )
        }
    }

    private var totalBytesNoLock: Int64 {
        // Per-row bookkeeping allowance matches StoreSchema.rowOverhead (64).
        rows.values.reduce(Int64(0)) { $0 + Int64($1.frame.payload.count) + 64 }
    }

    /// Evict oldest non-SOS first (then SOS, oldest first) until <= maxBytes, protecting active delivery rows.
    private func evictUntilUnderCapNoLock() {
        // Eviction order: non-SOS (priority != .sos) first, oldest received; then
        // SOS, oldest. Candidate set excludes rows with nonterminal delivery_state (state 1 or 2).
        let candidates = rows.filter { (id, _) in
            guard let d = deliveryRows[id] else { return true }
            return d.state != DeliveryState.queuedDurably.code && d.state != DeliveryState.handedToRelay.code
        }
        let order = candidates.sorted { a, b in
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