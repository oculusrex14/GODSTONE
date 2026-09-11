import Foundation

// ---------------------------------------------------------------------------
// T31 SHARED MIGRATION CONTRACT (iOS) -- the Swift twin of the Android
// store/SchemaMigration.kt. Both courts (ReadinessT31Test.kt / ReadinessT31Tests.swift)
// drive ONE contract through an injected executor so the dual-court parity the
// card mandates holds: the six versioned-migration laws are EXECUTED identically on
// both isles. This is the ADDITIVE sanctioned seam the runtime binds onUpgrade to
// once installs must survive; the sealed system-SQLite store DDL is NOT rewritten.
//
// Laws (mirrored exactly from the Kotlin engine -- including the snapshot/restore
// transactional executor and the token-based DDL matcher): every supported version
// reaches current; a step is one transaction and a crash at any statement rolls the
// WHOLE step back; a durably-checkpointed step is never re-applied (idempotent after
// crash); a future schema -> UnsupportedVersion with NOTHING deleted; an altered
// schema -> RepairRequired, NOT a recreate; immutable fields stay byte-identical.
// Pure Foundation only (no sqlite3, no Security): the physical run of the
// section19/18 cases against the built artifact stays DEVICE evidence (deferred).
// ---------------------------------------------------------------------------

/// An ordered, comparable schema revision carrying the minimum rollback-compatible app revision.
public struct SchemaVersion: Comparable, Sendable {
    public let revision: Int
    public let minimumRollbackCompatibleApp: Int
    public init(revision: Int, minimumRollbackCompatibleApp: Int) { self.revision = revision; self.minimumRollbackCompatibleApp = minimumRollbackCompatibleApp }
    public static func < (lhs: SchemaVersion, rhs: SchemaVersion) -> Bool { lhs.revision < rhs.revision }
}

/// The frozen accepted fingerprint of one table (name + columns + the immutable-field definitions).
public struct TableFingerprint: Sendable {
    public let name: String
    public let columns: [String]
    public let immutableColumns: Set<String>
    public init(name: String, columns: [String], immutableColumns: Set<String>) { self.name = name; self.columns = columns; self.immutableColumns = immutableColumns }
    /// Canonical, order-insensitive form so two equal schemas compare equal regardless of collection order.
    public func canonical() -> String { "\(name)(\(columns.sorted().joined(separator: ","))|@\(immutableColumns.sorted().joined(separator: ",")))" }
}

public struct SchemaFingerprint: Sendable {
    public let tables: [TableFingerprint]
    public init(tables: [TableFingerprint]) { self.tables = tables }
    public func canonical() -> String { tables.map { $0.canonical() }.sorted().joined(separator: ";") }
    public func matches(_ observed: SchemaFingerprint) -> Bool { canonical() == observed.canonical() }
}

public typealias MigrationApply = (MigrationExecutor) -> Void

/// One ordered migration edge from -> to, expressed as the statements (and/or a code apply) that advance it.
public struct MigrationStep: Sendable {
    public let from: Int
    public let to: Int
    public let statements: [String]
    public let apply: MigrationApply?
    public init(from: Int, to: Int, statements: [String], apply: MigrationApply? = nil) { self.from = from; self.to = to; self.statements = statements; self.apply = apply }
}

public enum MigrationResult: Sendable {
    case upgraded(from: Int, to: Int)
    case alreadyCurrent(at: Int)
    case unsupportedVersion(found: Int, supportedMax: Int)
    case repairRequired(reason: String)
    case failed(stage: String, rolledBack: Bool, versionPreserved: Bool)
    public var isOk: Bool { if case .upgraded = self { return true }; if case .alreadyCurrent = self { return true }; return false }
}

/// The injected statement executor / durable-checkpoint / observation seam the engine drives.
public protocol MigrationExecutor: AnyObject {
    func checkpointedThrough() -> Int
    func execute(step: MigrationStep, statements: [String]) throws
    func observeFingerprint() -> SchemaFingerprint
    func immutableDigest() -> String
    func markCheckpointed(step: MigrationStep)
}

/// The ordered, transactional, idempotent migration engine -- the sanctioned seam onUpgrade delegates to.
public final class SchemaMigrationEngine: @unchecked Sendable {
    private let steps: [MigrationStep]
    private let supportedMax: Int
    private let fingerprint: SchemaFingerprint
    public init(steps: [MigrationStep], supportedMax: Int, fingerprint: SchemaFingerprint) { self.steps = steps; self.supportedMax = supportedMax; self.fingerprint = fingerprint }

    /// Advance `currentVersion` to `supportedMax`, fail-closed and idempotent.
    public func migrate(currentVersion: Int, observed: SchemaFingerprint, executor: MigrationExecutor) -> MigrationResult {
        if currentVersion > supportedMax { return .unsupportedVersion(found: currentVersion, supportedMax: supportedMax) }
        let checkpoint = executor.checkpointedThrough()
        let start = max(checkpoint, currentVersion)
        if start >= supportedMax {
            return fingerprint.matches(observed) ? .alreadyCurrent(at: supportedMax)
                : .repairRequired(reason: "observed schema drifts from the frozen fingerprint at current revision \(supportedMax)")
        }
        let ordered = steps.filter { $0.to > start && $0.to <= supportedMax }.sorted { $0.from < $1.from }
        var expect = start
        for step in ordered {
            if step.from != expect { return .failed(stage: "gap in the migration plan at \(expect) (next step \(step.from))", rolledBack: false, versionPreserved: true) }
            if step.to <= executor.checkpointedThrough() { expect = step.to; continue }
            do {
                try executor.execute(step: step, statements: step.statements)
                step.apply?(executor)
            } catch {
                return .failed(stage: "step \(step.from)->\(step.to)", rolledBack: true, versionPreserved: expect == step.from)
            }
            executor.markCheckpointed(step: step)
            expect = step.to
        }
        if expect != supportedMax { return .failed(stage: "plan ended at \(expect), short of current \(supportedMax)", rolledBack: false, versionPreserved: true) }
        let after = executor.observeFingerprint()
        if !fingerprint.matches(after) { return .repairRequired(reason: "migrated schema drifts from the frozen fingerprint") }
        return .upgraded(from: start, to: supportedMax)
    }
}

// ---------------------------------------------------------------------------
// Reference in-memory MigrationExecutor -- the deterministic seam BOTH isles'
// courts drive. It records every statement, models ALTER ADD COLUMN / DROP TABLE,
// maintains the immutable-field byte digest, honours ONE durable checkpoint
// (idempotence) and can crash at any statement index (the whole step rolls back via
// a snapshot/restore, never a partial application). Deliberately not the production
// store -- the production binding reuses the sealed store DDL; this makes the
// ENGINE's laws EXECUTABLE on the host so no device/SDK result is fabricated.
// ---------------------------------------------------------------------------

/// Signals a simulated mid-step crash so the engine's transactional rollback is exercised on the host.
public struct MigrationCrashSimulation: Error, Equatable { public let message: String; public init(_ message: String) { self.message = message } }

public final class InMemoryMigrationExecutor: MigrationExecutor, @unchecked Sendable {
    private final class Row { let cells: [String: String]; init(_ cells: [String: String]) { self.cells = cells } }

    private var tables: [String: [String]] = [:]
    private var rows: [String: [Row]] = [:]
    private var checkpoint: Int
    public var executed: [String] = []
    public var violations: [String] = []
    private var immutableDomains: [String: Set<String>] = [:]
    public var crashAfterStatement: Int = -1

    public init(startRevision: Int, initialTables: [TableFingerprint], initialImmutable: [String: [String]] = [:]) {
        self.checkpoint = startRevision
        for tf in initialTables {
            self.tables[tf.name] = tf.columns
            var cells: [String: String] = [:]
            let present = tf.immutableColumns.sorted()
            let vals = initialImmutable[tf.name] ?? []
            for (i, c) in present.enumerated() { cells[c] = i < vals.count ? vals[i] : "" }
            self.rows[tf.name] = [Row(cells)]
        }
    }

    @discardableResult public func withImmutableDomains(_ domains: [String: Set<String>]) -> InMemoryMigrationExecutor { self.immutableDomains = domains; return self }

    private func isImmutableCol(_ table: String, _ column: String) -> Bool { immutableDomains[table]?.contains(column) ?? false }

    public func observeFingerprint() -> SchemaFingerprint {
        SchemaFingerprint(tables: tables.map { (t, cols) in TableFingerprint(name: t, columns: cols, immutableColumns: (immutableDomains[t] ?? Set<String>()).filter { cols.contains($0) }) })
    }

    public func immutableDigest() -> String {
        var out = ""
        for t in rows.keys.sorted() {
            guard let rs = rows[t] else { continue }
            for c in (immutableDomains[t] ?? Set<String>()).sorted() { for r in rs { out += "\(t).\(c)=\(r.cells[c] ?? "");" } }
        }
        return out
    }

    public func checkpointedThrough() -> Int { checkpoint }
    public func markCheckpointed(step: MigrationStep) { if step.to > checkpoint { checkpoint = step.to } }

    public func execute(step: MigrationStep, statements: [String]) throws {
        // Transactional: snapshot the live schema, mutate LIVE, and on ANY fault restore the snapshot --
        // a mid-step crash rolls the ENTIRE step back (no partial application); a re-run re-applies exactly once.
        let snapT = tables; let snapR = rows
        let snapViol = violations; let snapExec = executed
        var ran = 0
        do {
            for s in statements {
                if crashAfterStatement >= 0 && ran >= crashAfterStatement { throw MigrationCrashSimulation("crash at statement '\(s)' of step \(step.from)->\(step.to)") }
                try applyStatement(s)
                ran += 1
            }
        } catch {
            tables = snapT; rows = snapR; violations = snapViol; executed = snapExec
            throw error
        }
    }

    private func applyStatement(_ s: String) throws {
        executed.append(s)
        let tk = s.lowercased().split(separator: " ", omittingEmptySubsequences: true).map(String.init).filter { $0 != "if" && $0 != "exists" }
        if tk.count >= 3 && tk[0].hasPrefix("drop") && tk[1].hasPrefix("table") {
            let tn = tk[2]
            if !(immutableDomains[tn] ?? Set<String>()).isEmpty { violations.append("dropped protected table \(tn)") }
            rows.removeValue(forKey: tn); tables.removeValue(forKey: tn)
            return
        }
        if tk.count >= 6 && tk[0].hasPrefix("alter") && tk[1].hasPrefix("table") && tk[3].hasPrefix("add") && tk[4].hasPrefix("column") {
            let tn = tk[2]; let c = tk[5]
            if var cols = tables[tn], !cols.contains(c) { cols.append(c); tables[tn] = cols }
            return
        }
        if tk.count >= 4 && tk[0].hasPrefix("update") && tk[2].hasPrefix("set") {
            let tn = tk[1]; let c = String(tk[3].split(separator: "=", omittingEmptySubsequences: false).first ?? "")
            if isImmutableCol(tn, c) { violations.append("attempted to mutate immutable column \(tn).\(c)") }
        }
    }
}
