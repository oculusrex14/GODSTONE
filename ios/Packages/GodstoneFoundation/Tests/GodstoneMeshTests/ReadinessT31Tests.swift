import XCTest
@testable import GodstoneMesh

// ---------------------------------------------------------------------------
// T31 - the CANONICAL designated regression court, iOS side. The manifest
// required_regression_paths names this file; the narrow filter is
// `swift test --package-path ios/Packages/GodstoneFoundation --filter ReadinessT31Tests`.
// It drives the iOS engine twin (Sources/GodstoneMesh/SchemaMigration.swift)
// through the deterministic InMemoryMigrationExecutor and asserts the SAME six
// laws as the android twin ReadinessT31Test.kt (identical names) against the SAME
// frozen schema, giving the dual-court parity the card requires:
//   * every supported version reaches current;
//   * a crash at any statement rolls the WHOLE step back and the run is idempotent
//     after the crash;
//   * a duplicate launch is a no-op;
//   * a future schema -> UnsupportedVersion with NOTHING deleted (fail closed);
//   * an altered schema -> RepairRequired, NOT a silent recreate;
//   * the immutable fields are byte-identical while the message id and the
//     recipient binding survive.
// The concrete store DDL and the physical run of the section19/18 cases against the
// built artifact are DEVICE evidence (deferred to the device gate); the host proves
// the ordering law only. The android twin exercises the identical contract on JVM.
// ---------------------------------------------------------------------------

private func eqStrings(_ a: [String], _ b: [String]) -> Bool {
    guard a.count == b.count else { return false }
    for i in a.indices where a[i] != b[i] { return false }
    return true
}

final class ReadinessT31Tests: XCTestCase {

    private static let supportedMax = 6
    private static let frozen = SchemaFingerprint(tables: [
        TableFingerprint(name: "held_frames", columns: ["msg_id","type","ttl","hop_count","flags","priority","routing_tag","payload","received_from","received_at","retention_class","meta_v6"], immutableColumns: ["msg_id"]),
        TableFingerprint(name: "delivery", columns: ["d_msg_id","d_recipient","d_state"], immutableColumns: ["d_msg_id","d_recipient"]),
        TableFingerprint(name: "store_meta", columns: ["cipher","kdf","schema_fingerprint"], immutableColumns: Set<String>()),
    ])
    private static let steps: [MigrationStep] = [
        MigrationStep(from: 1, to: 2, statements: ["ALTER TABLE store_meta ADD COLUMN kdf"]),
        MigrationStep(from: 2, to: 3, statements: ["ALTER TABLE held_frames ADD COLUMN retention_class"]),
        MigrationStep(from: 3, to: 4, statements: ["ALTER TABLE store_meta ADD COLUMN schema_fingerprint"]),
        MigrationStep(from: 4, to: 5, statements: ["ALTER TABLE delivery ADD COLUMN d_state"]),
        MigrationStep(from: 5, to: 6, statements: ["ALTER TABLE held_frames ADD COLUMN meta_v6"]),
    ]
    private static let immutableDomains: [String: Set<String>] = [
        "held_frames": ["msg_id"], "delivery": ["d_msg_id","d_recipient"], "store_meta": Set<String>(),
    ]
    private static let immutableValues: [String: [String]] = [
        "held_frames": ["0123456789abcdef"], "delivery": ["0123456789abcdef","node-beta"], "store_meta": [],
    ]

    private func addedByStep(_ table: String, _ column: String) -> Int? {
        for st in Self.steps where st.statements.contains(where: { $0.lowercased().contains("table \(table) add column \(column)") }) { return st.to }
        return nil
    }
    private func columnsPresentAt(_ table: String, _ revision: Int) -> [String] {
        Self.frozen.tables.first(where: { $0.name == table })!.columns.filter { c in
            if let add = addedByStep(table, c) { return add <= revision }
            return true
        }
    }
    private func initialTablesAt(_ revision: Int) -> [TableFingerprint] {
        Self.frozen.tables.map { tf in
            let cols = columnsPresentAt(tf.name, revision)
            return TableFingerprint(name: tf.name, columns: cols, immutableColumns: tf.immutableColumns.filter { cols.contains($0) })
        }
    }
    private func newExec(_ revision: Int) -> InMemoryMigrationExecutor {
        InMemoryMigrationExecutor(startRevision: revision, initialTables: initialTablesAt(revision), initialImmutable: Self.immutableValues).withImmutableDomains(Self.immutableDomains)
    }
    private func hasColumn(_ ex: InMemoryMigrationExecutor, _ table: String, _ column: String) -> Bool {
        ex.observeFingerprint().tables.first(where: { $0.name == table })!.columns.contains(column)
    }

    // (1) every supported version reaches current (a start already at current is AlreadyCurrent)
    func testEverySupportedVersionReachesCurrent() throws {
        for s in 1...ReadinessT31Tests.supportedMax {
            let engine = SchemaMigrationEngine(steps: Self.steps, supportedMax: Self.supportedMax, fingerprint: Self.frozen)
            let ex = newExec(s)
            let r = engine.migrate(currentVersion: s, observed: ex.observeFingerprint(), executor: ex)
            XCTAssertTrue(r.isOk, "rev \(s) should land at current, got \(r)")
            if case .upgraded(_, let to) = r { XCTAssertEqual(to, Self.supportedMax) }
            XCTAssertTrue(Self.frozen.matches(ex.observeFingerprint()), "the migrated schema matches the frozen fingerprint at rev \(s)")
        }
    }

    // (2) crash at any statement rolls the whole step back; the run is idempotent after the crash
    func testCrashAtEachStatementRollsBackAndReRunsIdempotently() throws {
        let plan = [MigrationStep(from: 5, to: 6, statements: ["ALTER TABLE held_frames ADD COLUMN meta_v6", "ALTER TABLE store_meta ADD COLUMN kdf"])]
        let engine = SchemaMigrationEngine(steps: plan, supportedMax: Self.supportedMax, fingerprint: Self.frozen)
        let ex0 = newExec(5); ex0.crashAfterStatement = 0
        guard case .failed(_, let rb0, let vp0) = engine.migrate(currentVersion: 5, observed: ex0.observeFingerprint(), executor: ex0) else { return XCTFail("crash before any statement must fail closed") }
        XCTAssertTrue(rb0); XCTAssertTrue(vp0)
        XCTAssertFalse(hasColumn(ex0, "held_frames", "meta_v6"), "the crashed step left NO column behind (transactional)")
        XCTAssertEqual(ex0.executed.count, 0)
        let ex1 = newExec(5); ex1.crashAfterStatement = 1
        guard case .failed(_, let rb1, let vp1) = engine.migrate(currentVersion: 5, observed: ex1.observeFingerprint(), executor: ex1) else { return XCTFail("crash mid-step must fail closed") }
        XCTAssertTrue(rb1); XCTAssertTrue(vp1)
        XCTAssertFalse(hasColumn(ex1, "held_frames", "meta_v6"), "a mid-step crash must roll back the already-executed statement too")
        XCTAssertEqual(ex1.executed.count, 0)
        let exOk = newExec(5)
        XCTAssertTrue(engine.migrate(currentVersion: 5, observed: exOk.observeFingerprint(), executor: exOk).isOk)
        XCTAssertTrue(hasColumn(exOk, "held_frames", "meta_v6"), "the committed step added the column")
        XCTAssertEqual(exOk.executed.filter { $0.contains("meta_v6") }.count, 1, "the column was added exactly once across the committed run")
        XCTAssertTrue(engine.migrate(currentVersion: exOk.checkpointedThrough(), observed: exOk.observeFingerprint(), executor: exOk).isOk, "re-running after a durable checkpoint is idempotent")
    }

    // (3) a duplicate launch is idempotent
    func testDuplicateLaunchIsIdempotent() throws {
        let engine = SchemaMigrationEngine(steps: Self.steps, supportedMax: Self.supportedMax, fingerprint: Self.frozen)
        let ex = newExec(5)
        XCTAssertTrue(engine.migrate(currentVersion: 5, observed: ex.observeFingerprint(), executor: ex).isOk)
        let afterFirst = ex.executed
        XCTAssertTrue(engine.migrate(currentVersion: ex.checkpointedThrough(), observed: ex.observeFingerprint(), executor: ex).isOk)
        XCTAssertTrue(eqStrings(afterFirst, ex.executed), "the duplicate launch added no new side effects")
    }

    // (4) a future schema is UnsupportedVersion and NOTHING is deleted (fail closed)
    func testFutureVersionIsUnsupportedAndNothingDeleted() throws {
        let engine = SchemaMigrationEngine(steps: Self.steps, supportedMax: Self.supportedMax, fingerprint: Self.frozen)
        let ex = newExec(Self.supportedMax)
        let before = ex.immutableDigest()
        let r = engine.migrate(currentVersion: Self.supportedMax + 3, observed: ex.observeFingerprint(), executor: ex)
        if case .unsupportedVersion(let found, let sup) = r { XCTAssertEqual(found, Self.supportedMax + 3); XCTAssertEqual(sup, Self.supportedMax) }
        else { return XCTFail("a future version must be refused as UnsupportedVersion, got \(r)") }
        XCTAssertEqual(ex.executed.count, 0, "nothing was executed")
        XCTAssertEqual(ex.immutableDigest(), before, "nothing was deleted -- the immutable bytes are intact")
    }

    // (5) an altered schema yields RepairRequired, NOT a silent recreate
    func testAlteredSchemaYieldsRepairNotRecreate() throws {
        let engine = SchemaMigrationEngine(steps: Self.steps, supportedMax: Self.supportedMax, fingerprint: Self.frozen)
        let ex = newExec(Self.supportedMax)
        let drifted = SchemaFingerprint(tables: Self.frozen.tables.map { tf in
            tf.name == "held_frames" ? TableFingerprint(name: tf.name, columns: tf.columns + ["rogue_column"], immutableColumns: tf.immutableColumns) : tf
        })
        guard case .repairRequired = engine.migrate(currentVersion: Self.supportedMax, observed: drifted, executor: ex) else { return XCTFail("drift from the frozen fingerprint must demand repair") }
        XCTAssertEqual(ex.executed.count, 0, "repair must NOT be a silent recreate (no DDL run)")
    }

    // (6) after migration the immutable fields are byte-identical and the message id / recipient binding survive
    func testImmutableFieldsByteIdenticalAndBindingsPreserved() throws {
        let engine = SchemaMigrationEngine(steps: Self.steps, supportedMax: Self.supportedMax, fingerprint: Self.frozen)
        let ex = newExec(1)
        let before = ex.immutableDigest()
        XCTAssertTrue(engine.migrate(currentVersion: 1, observed: ex.observeFingerprint(), executor: ex).isOk, "a legit migration upgrades")
        XCTAssertEqual(ex.immutableDigest(), before, "the immutable fields are byte-identical after migration")
        XCTAssertTrue(ex.immutableDigest().contains("held_frames.msg_id=0123456789abcdef"), "the message id is retained")
        XCTAssertTrue(ex.immutableDigest().contains("delivery.d_recipient=node-beta"), "the recipient binding is retained")
        XCTAssertEqual(ex.violations.count, 0, "no immutable column was ever mutated or dropped")
    }
}
