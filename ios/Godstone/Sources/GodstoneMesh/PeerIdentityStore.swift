import Foundation
import SQLite3

private let peerStoreSqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Canonical peer-identity database schema and guarded SQL contracts (ADR-003, Phase C8.2B).
internal enum PeerIdentitySchema {
    static let dbName = "godstone_peer_identities.db"
    static let dbVersion: Int32 = 1
    static let table = "peer_identities"

    static let colNodeId = "node_id"
    static let colSigningPublicKey = "signing_public_key"
    static let colAcceptedStaticDhPublicKey = "accepted_static_dh_public_key"
    static let colAcceptedGeneration = "accepted_generation"
    static let colTrustLevel = "trust_level"
    static let colPendingStaticDhPublicKey = "pending_static_dh_public_key"
    static let colPendingGeneration = "pending_generation"

    static let createTableSql = """
        CREATE TABLE peer_identities (
            node_id BLOB PRIMARY KEY NOT NULL,
            signing_public_key BLOB NOT NULL,
            accepted_static_dh_public_key BLOB NOT NULL,
            accepted_generation INTEGER NOT NULL,
            trust_level INTEGER NOT NULL,
            pending_static_dh_public_key BLOB,
            pending_generation INTEGER,

            CHECK (length(node_id) = 16),
            CHECK (length(signing_public_key) = 32),
            CHECK (length(accepted_static_dh_public_key) = 32),

            CHECK (
                accepted_generation BETWEEN 0 AND 4294967295
            ),

            CHECK (
                trust_level IN (1,2,3)
            ),

            CHECK (
                (
                    pending_static_dh_public_key IS NULL
                    AND pending_generation IS NULL
                )
                OR
                (
                    pending_static_dh_public_key IS NOT NULL
                    AND pending_generation IS NOT NULL
                )
            ),

            CHECK (
                pending_static_dh_public_key IS NULL
                OR length(pending_static_dh_public_key) = 32
            ),

            CHECK (
                pending_generation IS NULL
                OR pending_generation BETWEEN 0 AND 4294967295
            ),

            CHECK (
                pending_generation IS NULL
                OR pending_generation > accepted_generation
            ),

            CHECK (
                pending_static_dh_public_key IS NULL
                OR pending_static_dh_public_key != accepted_static_dh_public_key
            ),

            CHECK (
                trust_level != 3
                OR (
                    pending_static_dh_public_key IS NULL
                    AND pending_generation IS NULL
                )
            )
        )
        """

    static let readRawSql = """
        SELECT node_id, signing_public_key, accepted_static_dh_public_key,
               accepted_generation, trust_level, pending_static_dh_public_key,
               pending_generation
        FROM peer_identities
        WHERE node_id = ?
        """

    static let insertFirstSeenSql = """
        INSERT INTO peer_identities (
            node_id, signing_public_key, accepted_static_dh_public_key,
            accepted_generation, trust_level, pending_static_dh_public_key,
            pending_generation
        ) VALUES (?, ?, ?, ?, ?, NULL, NULL)
        """

    static let setInitialPendingSql = """
        UPDATE peer_identities
        SET pending_static_dh_public_key = ?, pending_generation = ?
        WHERE node_id = ?
          AND signing_public_key = ?
          AND accepted_static_dh_public_key = ?
          AND accepted_generation = ?
          AND trust_level = ?
          AND pending_static_dh_public_key IS NULL
          AND pending_generation IS NULL
        """

    static let advancePendingSql = """
        UPDATE peer_identities
        SET pending_static_dh_public_key = ?, pending_generation = ?
        WHERE node_id = ?
          AND signing_public_key = ?
          AND accepted_static_dh_public_key = ?
          AND accepted_generation = ?
          AND trust_level = ?
          AND pending_static_dh_public_key = ?
          AND pending_generation = ?
        """

    static let approvePendingRotationSql = """
        UPDATE peer_identities
        SET
            accepted_static_dh_public_key = pending_static_dh_public_key,
            accepted_generation = pending_generation,
            pending_static_dh_public_key = NULL,
            pending_generation = NULL
        WHERE node_id = ?
          AND signing_public_key = ?
          AND accepted_static_dh_public_key = ?
          AND accepted_generation = ?
          AND trust_level = ?
          AND pending_static_dh_public_key = ?
          AND pending_generation = ?
          AND trust_level IN (1,2)
        """

    static let revokeNoPendingSql = """
        UPDATE peer_identities
        SET trust_level = 3,
            pending_static_dh_public_key = NULL,
            pending_generation = NULL
        WHERE node_id = ?
          AND signing_public_key = ?
          AND accepted_static_dh_public_key = ?
          AND accepted_generation = ?
          AND trust_level = ?
          AND pending_static_dh_public_key IS NULL
          AND pending_generation IS NULL
        """

    static let revokeWithPendingSql = """
        UPDATE peer_identities
        SET trust_level = 3,
            pending_static_dh_public_key = NULL,
            pending_generation = NULL
        WHERE node_id = ?
          AND signing_public_key = ?
          AND accepted_static_dh_public_key = ?
          AND accepted_generation = ?
          AND trust_level = ?
          AND pending_static_dh_public_key = ?
          AND pending_generation = ?
        """

    static func normalizeSql(_ sql: String) -> String {
        sql.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

/// Raw durable row loaded from database before strict decoding (ADR-003, Phase C8.2B).
internal struct PeerIdentityRow: Sendable, Equatable {
    let nodeIdRaw: Data
    let signingPublicKeyRaw: Data
    let acceptedStaticDhPublicKeyRaw: Data
    let acceptedGenerationRaw: Int64
    let trustCodeRaw: Int32
    let pendingStaticDhPublicKeyRaw: Data?
    let pendingGenerationRaw: Int64?
}

/// Storage error taxonomy for throwing storage operations.
internal enum PeerStoreError: Error {
    case handleMissing
    case prepareFailed
    case stepFailed
    case schemaMismatch
    case fileProtectionFailed
}

/// Closure type for file protection attribute assignment (ADR-003, Phase C8.2B.1).
internal typealias FileProtectionSetter = (_ path: String, _ protection: FileProtectionType) throws -> Void

/// Storage protocol for peer identity repository backend (ADR-003, Phase C8.2B).
internal protocol PeerIdentityStore: AnyObject {
    func inImmediateTransaction<T>(_ block: (PeerIdentityStore) throws -> T) throws -> T

    func readRaw(_ nodeId: Data) throws -> PeerIdentityRow?

    func insertFirstSeen(
        nodeId: Data,
        signingPub: Data,
        acceptedStatic: Data,
        acceptedGeneration: Int64,
        trustCode: Int32
    ) throws -> Int

    func setInitialPendingGuarded(
        nodeId: Data,
        signingPub: Data,
        acceptedStatic: Data,
        acceptedGeneration: Int64,
        trustLevel: Int32,
        newPendingStatic: Data,
        newPendingGeneration: Int64
    ) throws -> Int

    func advancePendingGuarded(
        nodeId: Data,
        signingPub: Data,
        acceptedStatic: Data,
        acceptedGeneration: Int64,
        trustLevel: Int32,
        oldPendingStatic: Data,
        oldPendingGeneration: Int64,
        newPendingStatic: Data,
        newPendingGeneration: Int64
    ) throws -> Int

    func approvePendingRotationGuarded(
        nodeId: Data,
        signingPub: Data,
        acceptedStatic: Data,
        acceptedGeneration: Int64,
        trustLevel: Int32,
        expectedPendingStatic: Data,
        expectedPendingGeneration: Int64
    ) throws -> Int

    func revokePeerGuarded(
        nodeId: Data,
        signingPub: Data,
        acceptedStatic: Data,
        acceptedGeneration: Int64,
        currentTrustLevel: Int32,
        oldPendingStatic: Data?,
        oldPendingGeneration: Int64?
    ) throws -> Int
}

/// Production SQLite-backed peer identity store with fixed FileProtectionType.complete (ADR-003, Phase C8.2B).
internal final class SqlitePeerIdentityStore: PeerIdentityStore {
    private var handle: OpaquePointer?
    private let lock = NSLock()
    internal let fileProtection: FileProtectionType = .complete

    /// Open (or create) the peer store at `url` with fixed Complete file protection.
    convenience init(url: URL) throws {
        try self.init(url: url, protectionSetter: { path, protection in
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: protection], ofItemAtPath: path)
            #endif
        })
    }

    /// Internal/test-only designated initializer with injected protection setter seam.
    internal init(url: URL, protectionSetter: FileProtectionSetter) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let path = url.path
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let validDb = db else {
            if let db = db { sqlite3_close_v2(db) }
            throw PeerStoreError.handleMissing
        }
        handle = validDb

        // Set busy timeout for cross-connection concurrency
        sqlite3_busy_timeout(validDb, 5000)

        do {
            try runMigrations(validDb)
        } catch {
            sqlite3_close_v2(validDb)
            handle = nil
            throw error
        }

        // Apply FileProtectionType.complete fail-closed via protectionSetter
        do {
            try protectionSetter(path, .complete)
        } catch {
            sqlite3_close_v2(validDb)
            handle = nil
            throw PeerStoreError.fileProtectionFailed
        }
    }

    deinit {
        if let db = handle {
            sqlite3_close_v2(db)
        }
    }

    func inImmediateTransaction<T>(_ block: (PeerIdentityStore) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard let db = handle else { throw PeerStoreError.handleMissing }

        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
            throw PeerStoreError.stepFailed
        }

        let txStore = TransactionStore(parent: self, db: db)
        do {
            let result = try block(txStore)
            guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                throw PeerStoreError.stepFailed
            }
            return result
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    private func readUserVersion(_ db: OpaquePointer) throws -> Int32 {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt); throw PeerStoreError.prepareFailed
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw PeerStoreError.stepFailed }
        return sqlite3_column_int(stmt, 0)
    }

    private func tableExists(_ db: OpaquePointer, _ name: String) throws -> Bool {
        var stmt: OpaquePointer?
        let sql = "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt); throw PeerStoreError.prepareFailed
        }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, name)
        let rc = sqlite3_step(stmt)
        return rc == SQLITE_ROW
    }

    private func runMigrations(_ db: OpaquePointer) throws {
        let v = try readUserVersion(db)
        let exists = try tableExists(db, PeerIdentitySchema.table)

        if v == 0 && !exists {
            // Case A: Fresh database -> Create inside transaction and stamp user_version = 1
            guard sqlite3_exec(db, "BEGIN", nil, nil, nil) == SQLITE_OK else { throw PeerStoreError.stepFailed }
            do {
                guard sqlite3_exec(db, PeerIdentitySchema.createTableSql, nil, nil, nil) == SQLITE_OK else {
                    throw PeerStoreError.stepFailed
                }
                guard sqlite3_exec(db, "PRAGMA user_version = \(PeerIdentitySchema.dbVersion)", nil, nil, nil) == SQLITE_OK else {
                    throw PeerStoreError.stepFailed
                }
                guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw PeerStoreError.stepFailed }
            } catch {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                throw error
            }
            try validateSchema(db)
            return
        }

        if v == 0 && exists {
            // Case B: user_version == 0 but table exists -> Fail closed
            throw PeerStoreError.schemaMismatch
        }

        if v == PeerIdentitySchema.dbVersion {
            // Case C: Current version -> Validate DDL fingerprint
            try validateSchema(db)
            return
        }

        // Case D: Future version (v > 1) -> Fail closed
        throw PeerStoreError.schemaMismatch
    }

    private func validateSchema(_ db: OpaquePointer) throws {
        var stmt: OpaquePointer?
        let sql = "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt); throw PeerStoreError.prepareFailed
        }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, PeerIdentitySchema.table)
        guard sqlite3_step(stmt) == SQLITE_ROW, let raw = sqlite3_column_text(stmt, 0) else {
            throw PeerStoreError.schemaMismatch
        }
        let actual = String(cString: raw)
        guard PeerIdentitySchema.normalizeSql(actual) == PeerIdentitySchema.normalizeSql(PeerIdentitySchema.createTableSql) else {
            throw PeerStoreError.schemaMismatch
        }
    }

    func readRaw(_ nodeId: Data) throws -> PeerIdentityRow? {
        lock.lock()
        defer { lock.unlock() }
        guard let db = handle else { throw PeerStoreError.handleMissing }
        return try readRawNoLock(db, nodeId)
    }

    func insertFirstSeen(
        nodeId: Data,
        signingPub: Data,
        acceptedStatic: Data,
        acceptedGeneration: Int64,
        trustCode: Int32
    ) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard let db = handle else { throw PeerStoreError.handleMissing }
        return try insertFirstSeenNoLock(
            db,
            nodeId: nodeId,
            signingPub: signingPub,
            acceptedStatic: acceptedStatic,
            acceptedGeneration: acceptedGeneration,
            trustCode: trustCode
        )
    }

    func setInitialPendingGuarded(
        nodeId: Data,
        signingPub: Data,
        acceptedStatic: Data,
        acceptedGeneration: Int64,
        trustLevel: Int32,
        newPendingStatic: Data,
        newPendingGeneration: Int64
    ) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard let db = handle else { throw PeerStoreError.handleMissing }
        return try setInitialPendingNoLock(
            db,
            nodeId: nodeId,
            signingPub: signingPub,
            acceptedStatic: acceptedStatic,
            acceptedGeneration: acceptedGeneration,
            trustLevel: trustLevel,
            newPendingStatic: newPendingStatic,
            newPendingGeneration: newPendingGeneration
        )
    }

    func advancePendingGuarded(
        nodeId: Data,
        signingPub: Data,
        acceptedStatic: Data,
        acceptedGeneration: Int64,
        trustLevel: Int32,
        oldPendingStatic: Data,
        oldPendingGeneration: Int64,
        newPendingStatic: Data,
        newPendingGeneration: Int64
    ) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard let db = handle else { throw PeerStoreError.handleMissing }
        return try advancePendingNoLock(
            db,
            nodeId: nodeId,
            signingPub: signingPub,
            acceptedStatic: acceptedStatic,
            acceptedGeneration: acceptedGeneration,
            trustLevel: trustLevel,
            oldPendingStatic: oldPendingStatic,
            oldPendingGeneration: oldPendingGeneration,
            newPendingStatic: newPendingStatic,
            newPendingGeneration: newPendingGeneration
        )
    }

    func approvePendingRotationGuarded(
        nodeId: Data,
        signingPub: Data,
        acceptedStatic: Data,
        acceptedGeneration: Int64,
        trustLevel: Int32,
        expectedPendingStatic: Data,
        expectedPendingGeneration: Int64
    ) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard let db = handle else { throw PeerStoreError.handleMissing }
        return try approvePendingRotationNoLock(
            db,
            nodeId: nodeId,
            signingPub: signingPub,
            acceptedStatic: acceptedStatic,
            acceptedGeneration: acceptedGeneration,
            trustLevel: trustLevel,
            expectedPendingStatic: expectedPendingStatic,
            expectedPendingGeneration: expectedPendingGeneration
        )
    }

    func revokePeerGuarded(
        nodeId: Data,
        signingPub: Data,
        acceptedStatic: Data,
        acceptedGeneration: Int64,
        currentTrustLevel: Int32,
        oldPendingStatic: Data?,
        oldPendingGeneration: Int64?
    ) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard let db = handle else { throw PeerStoreError.handleMissing }
        return try revokePeerNoLock(
            db,
            nodeId: nodeId,
            signingPub: signingPub,
            acceptedStatic: acceptedStatic,
            acceptedGeneration: acceptedGeneration,
            currentTrustLevel: currentTrustLevel,
            oldPendingStatic: oldPendingStatic,
            oldPendingGeneration: oldPendingGeneration
        )
    }

    /// Coordinated panic wipe helper for peer identity database artifacts (ADR-004, Phase C8.2C).
    @discardableResult
    public static func panicWipe(at url: URL) -> Bool {
        let fm = FileManager.default
        var ok = true
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let p = URL(fileURLWithPath: url.path + suffix)
            do { try fm.removeItem(at: p) } catch { /* absent is fine */ }
            if fm.fileExists(atPath: p.path) { ok = false }
        }
        return ok
    }

    // MARK: - No-Lock Internal Operations (Lock discipline §22)

    fileprivate func readRawNoLock(_ db: OpaquePointer, _ nodeId: Data) throws -> PeerIdentityRow? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, PeerIdentitySchema.readRawSql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt); throw PeerStoreError.prepareFailed
        }
        defer { sqlite3_finalize(stmt) }
        bindBlob(stmt, 1, nodeId)

        let rc = sqlite3_step(stmt)
        if rc == SQLITE_DONE { return nil }
        guard rc == SQLITE_ROW else { throw PeerStoreError.stepFailed }

        let nId = readBlob(stmt, 0)
        let signPub = readBlob(stmt, 1)
        let accStatic = readBlob(stmt, 2)
        let accGen = sqlite3_column_int64(stmt, 3)
        let trustCode = sqlite3_column_int(stmt, 4)
        let pendStatic: Data? = sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : readBlob(stmt, 5)
        let pendGen: Int64? = sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 6)

        return PeerIdentityRow(
            nodeIdRaw: nId,
            signingPublicKeyRaw: signPub,
            acceptedStaticDhPublicKeyRaw: accStatic,
            acceptedGenerationRaw: accGen,
            trustCodeRaw: trustCode,
            pendingStaticDhPublicKeyRaw: pendStatic,
            pendingGenerationRaw: pendGen
        )
    }

    fileprivate func insertFirstSeenNoLock(
        _ db: OpaquePointer,
        nodeId: Data,
        signingPub: Data,
        acceptedStatic: Data,
        acceptedGeneration: Int64,
        trustCode: Int32
    ) throws -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, PeerIdentitySchema.insertFirstSeenSql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt); throw PeerStoreError.prepareFailed
        }
        defer { sqlite3_finalize(stmt) }
        bindBlob(stmt, 1, nodeId)
        bindBlob(stmt, 2, signingPub)
        bindBlob(stmt, 3, acceptedStatic)
        sqlite3_bind_int64(stmt, 4, acceptedGeneration)
        sqlite3_bind_int(stmt, 5, trustCode)

        guard sqlite3_step(stmt) == SQLITE_DONE else { throw PeerStoreError.stepFailed }
        return Int(sqlite3_changes(db))
    }

    fileprivate func setInitialPendingNoLock(
        _ db: OpaquePointer,
        nodeId: Data,
        signingPub: Data,
        acceptedStatic: Data,
        acceptedGeneration: Int64,
        trustLevel: Int32,
        newPendingStatic: Data,
        newPendingGeneration: Int64
    ) throws -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, PeerIdentitySchema.setInitialPendingSql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt); throw PeerStoreError.prepareFailed
        }
        defer { sqlite3_finalize(stmt) }
        bindBlob(stmt, 1, newPendingStatic)
        sqlite3_bind_int64(stmt, 2, newPendingGeneration)
        bindBlob(stmt, 3, nodeId)
        bindBlob(stmt, 4, signingPub)
        bindBlob(stmt, 5, acceptedStatic)
        sqlite3_bind_int64(stmt, 6, acceptedGeneration)
        sqlite3_bind_int(stmt, 7, trustLevel)

        guard sqlite3_step(stmt) == SQLITE_DONE else { throw PeerStoreError.stepFailed }
        return Int(sqlite3_changes(db))
    }

    fileprivate func advancePendingNoLock(
        _ db: OpaquePointer,
        nodeId: Data,
        signingPub: Data,
        acceptedStatic: Data,
        acceptedGeneration: Int64,
        trustLevel: Int32,
        oldPendingStatic: Data,
        oldPendingGeneration: Int64,
        newPendingStatic: Data,
        newPendingGeneration: Int64
    ) throws -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, PeerIdentitySchema.advancePendingSql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt); throw PeerStoreError.prepareFailed
        }
        defer { sqlite3_finalize(stmt) }
        bindBlob(stmt, 1, newPendingStatic)
        sqlite3_bind_int64(stmt, 2, newPendingGeneration)
        bindBlob(stmt, 3, nodeId)
        bindBlob(stmt, 4, signingPub)
        bindBlob(stmt, 5, acceptedStatic)
        sqlite3_bind_int64(stmt, 6, acceptedGeneration)
        sqlite3_bind_int(stmt, 7, trustLevel)
        bindBlob(stmt, 8, oldPendingStatic)
        sqlite3_bind_int64(stmt, 9, oldPendingGeneration)

        guard sqlite3_step(stmt) == SQLITE_DONE else { throw PeerStoreError.stepFailed }
        return Int(sqlite3_changes(db))
    }

    fileprivate func approvePendingRotationNoLock(
        _ db: OpaquePointer,
        nodeId: Data,
        signingPub: Data,
        acceptedStatic: Data,
        acceptedGeneration: Int64,
        trustLevel: Int32,
        expectedPendingStatic: Data,
        expectedPendingGeneration: Int64
    ) throws -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, PeerIdentitySchema.approvePendingRotationSql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt); throw PeerStoreError.prepareFailed
        }
        defer { sqlite3_finalize(stmt) }
        bindBlob(stmt, 1, nodeId)
        bindBlob(stmt, 2, signingPub)
        bindBlob(stmt, 3, acceptedStatic)
        sqlite3_bind_int64(stmt, 4, acceptedGeneration)
        sqlite3_bind_int(stmt, 5, trustLevel)
        bindBlob(stmt, 6, expectedPendingStatic)
        sqlite3_bind_int64(stmt, 7, expectedPendingGeneration)

        guard sqlite3_step(stmt) == SQLITE_DONE else { throw PeerStoreError.stepFailed }
        return Int(sqlite3_changes(db))
    }

    fileprivate func revokePeerNoLock(
        _ db: OpaquePointer,
        nodeId: Data,
        signingPub: Data,
        acceptedStatic: Data,
        acceptedGeneration: Int64,
        currentTrustLevel: Int32,
        oldPendingStatic: Data?,
        oldPendingGeneration: Int64?
    ) throws -> Int {
        var stmt: OpaquePointer?
        if let oldStatic = oldPendingStatic, let oldGen = oldPendingGeneration {
            guard sqlite3_prepare_v2(db, PeerIdentitySchema.revokeWithPendingSql, -1, &stmt, nil) == SQLITE_OK else {
                sqlite3_finalize(stmt); throw PeerStoreError.prepareFailed
            }
            defer { sqlite3_finalize(stmt) }
            bindBlob(stmt, 1, nodeId)
            bindBlob(stmt, 2, signingPub)
            bindBlob(stmt, 3, acceptedStatic)
            sqlite3_bind_int64(stmt, 4, acceptedGeneration)
            sqlite3_bind_int(stmt, 5, currentTrustLevel)
            bindBlob(stmt, 6, oldStatic)
            sqlite3_bind_int64(stmt, 7, oldGen)

            guard sqlite3_step(stmt) == SQLITE_DONE else { throw PeerStoreError.stepFailed }
            return Int(sqlite3_changes(db))
        } else {
            guard sqlite3_prepare_v2(db, PeerIdentitySchema.revokeNoPendingSql, -1, &stmt, nil) == SQLITE_OK else {
                sqlite3_finalize(stmt); throw PeerStoreError.prepareFailed
            }
            defer { sqlite3_finalize(stmt) }
            bindBlob(stmt, 1, nodeId)
            bindBlob(stmt, 2, signingPub)
            bindBlob(stmt, 3, acceptedStatic)
            sqlite3_bind_int64(stmt, 4, acceptedGeneration)
            sqlite3_bind_int(stmt, 5, currentTrustLevel)

            guard sqlite3_step(stmt) == SQLITE_DONE else { throw PeerStoreError.stepFailed }
            return Int(sqlite3_changes(db))
        }
    }

    @inline(__always)
    private func bindBlob(_ stmt: OpaquePointer?, _ index: Int32, _ data: Data) {
        _ = data.withUnsafeBytes { raw in
            sqlite3_bind_blob(stmt, index, raw.baseAddress, Int32(data.count), peerStoreSqliteTransient)
        }
    }

    @inline(__always)
    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ text: String) {
        sqlite3_bind_text(stmt, index, text, -1, peerStoreSqliteTransient)
    }

    @inline(__always)
    private func readBlob(_ stmt: OpaquePointer?, _ index: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(stmt, index) else { return Data() }
        let count = Int(sqlite3_column_bytes(stmt, index))
        return Data(bytes: bytes, count: count)
    }

    /// Transaction-scoped store view avoiding recursive locking on NSLock (ADR-003, Phase C8.2B.1 §22).
    private final class TransactionStore: PeerIdentityStore {
        private unowned let parent: SqlitePeerIdentityStore
        private let db: OpaquePointer

        init(parent: SqlitePeerIdentityStore, db: OpaquePointer) {
            self.parent = parent
            self.db = db
        }

        func inImmediateTransaction<T>(_ block: (PeerIdentityStore) throws -> T) throws -> T {
            throw PeerStoreError.stepFailed
        }

        func readRaw(_ nodeId: Data) throws -> PeerIdentityRow? {
            try parent.readRawNoLock(db, nodeId)
        }

        func insertFirstSeen(
            nodeId: Data,
            signingPub: Data,
            acceptedStatic: Data,
            acceptedGeneration: Int64,
            trustCode: Int32
        ) throws -> Int {
            try parent.insertFirstSeenNoLock(
                db,
                nodeId: nodeId,
                signingPub: signingPub,
                acceptedStatic: acceptedStatic,
                acceptedGeneration: acceptedGeneration,
                trustCode: trustCode
            )
        }

        func setInitialPendingGuarded(
            nodeId: Data,
            signingPub: Data,
            acceptedStatic: Data,
            acceptedGeneration: Int64,
            trustLevel: Int32,
            newPendingStatic: Data,
            newPendingGeneration: Int64
        ) throws -> Int {
            try parent.setInitialPendingNoLock(
                db,
                nodeId: nodeId,
                signingPub: signingPub,
                acceptedStatic: acceptedStatic,
                acceptedGeneration: acceptedGeneration,
                trustLevel: trustLevel,
                newPendingStatic: newPendingStatic,
                newPendingGeneration: newPendingGeneration
            )
        }

        func advancePendingGuarded(
            nodeId: Data,
            signingPub: Data,
            acceptedStatic: Data,
            acceptedGeneration: Int64,
            trustLevel: Int32,
            oldPendingStatic: Data,
            oldPendingGeneration: Int64,
            newPendingStatic: Data,
            newPendingGeneration: Int64
        ) throws -> Int {
            try parent.advancePendingNoLock(
                db,
                nodeId: nodeId,
                signingPub: signingPub,
                acceptedStatic: acceptedStatic,
                acceptedGeneration: acceptedGeneration,
                trustLevel: trustLevel,
                oldPendingStatic: oldPendingStatic,
                oldPendingGeneration: oldPendingGeneration,
                newPendingStatic: newPendingStatic,
                newPendingGeneration: newPendingGeneration
            )
        }

        func approvePendingRotationGuarded(
            nodeId: Data,
            signingPub: Data,
            acceptedStatic: Data,
            acceptedGeneration: Int64,
            trustLevel: Int32,
            expectedPendingStatic: Data,
            expectedPendingGeneration: Int64
        ) throws -> Int {
            try parent.approvePendingRotationNoLock(
                db,
                nodeId: nodeId,
                signingPub: signingPub,
                acceptedStatic: acceptedStatic,
                acceptedGeneration: acceptedGeneration,
                trustLevel: trustLevel,
                expectedPendingStatic: expectedPendingStatic,
                expectedPendingGeneration: expectedPendingGeneration
            )
        }

        func revokePeerGuarded(
            nodeId: Data,
            signingPub: Data,
            acceptedStatic: Data,
            acceptedGeneration: Int64,
            currentTrustLevel: Int32,
            oldPendingStatic: Data?,
            oldPendingGeneration: Int64?
        ) throws -> Int {
            try parent.revokePeerNoLock(
                db,
                nodeId: nodeId,
                signingPub: signingPub,
                acceptedStatic: acceptedStatic,
                acceptedGeneration: acceptedGeneration,
                currentTrustLevel: currentTrustLevel,
                oldPendingStatic: oldPendingStatic,
                oldPendingGeneration: oldPendingGeneration
            )
        }
    }
}
