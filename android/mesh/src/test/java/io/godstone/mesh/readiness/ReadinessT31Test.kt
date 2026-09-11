package io.godstone.mesh.readiness

// ---------------------------------------------------------------------------
// T31 - the CANONICAL designated regression court (android). The manifest
// required_regression_paths names this file; the narrow filter is
// `--tests *ReadinessT31Test*`. The iOS twin ReadinessT31Tests.swift asserts the
// SAME six laws against the SAME shared contract (SchemaMigration.kt <->
// SchemaMigration.swift) so the dual-court parity the card mandates holds. The
// engine is driven through the deterministic InMemoryMigrationExecutor: the
// versioned-migration laws are EXECUTED, not narrated -- every supported version
// reaches current; a crash at any statement rolls the whole step back and the run
// is idempotent after the crash; a duplicate launch is a no-op; a future schema is
// UnsupportedVersion with nothing deleted; an altered schema yields RepairRequired,
// NOT a recreate; and the immutable fields (msg_id / the recipient binding / the
// delivery id) stay byte-identical while the message id and binding survive.
// The physical run of the section19/18 cases against the built artifact is DEVICE
// evidence (deferred to the device gate) -- the host proves the ordering law only.
// ---------------------------------------------------------------------------

import io.godstone.mesh.store.InMemoryMigrationExecutor
import io.godstone.mesh.store.MigrationResult
import io.godstone.mesh.store.MigrationStep
import io.godstone.mesh.store.SchemaFingerprint
import io.godstone.mesh.store.SchemaMigrationEngine
import io.godstone.mesh.store.TableFingerprint
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ReadinessT31Test {

    private companion object {
        val SUPPORTED_MAX = 6

        val FROZEN = SchemaFingerprint(
            listOf(
                TableFingerprint("held_frames", listOf("msg_id", "type", "ttl", "hop_count", "flags", "priority", "routing_tag", "payload", "received_from", "received_at", "retention_class", "meta_v6"), setOf("msg_id")),
                TableFingerprint("delivery", listOf("d_msg_id", "d_recipient", "d_state"), setOf("d_msg_id", "d_recipient")),
                TableFingerprint("store_meta", listOf("cipher", "kdf", "schema_fingerprint"), emptySet()),
            ),
        )

        val STEPS = listOf(
            MigrationStep(1, 2, listOf("ALTER TABLE store_meta ADD COLUMN kdf")),
            MigrationStep(2, 3, listOf("ALTER TABLE held_frames ADD COLUMN retention_class")),
            MigrationStep(3, 4, listOf("ALTER TABLE store_meta ADD COLUMN schema_fingerprint")),
            MigrationStep(4, 5, listOf("ALTER TABLE delivery ADD COLUMN d_state")),
            MigrationStep(5, 6, listOf("ALTER TABLE held_frames ADD COLUMN meta_v6")),
        )

        val IMMUTABLE_DOMAINS = mapOf(
            "held_frames" to setOf("msg_id"),
            "delivery" to setOf("d_msg_id", "d_recipient"),
            "store_meta" to emptySet<String>(),
        )

        val IMMUTABLE_VALUES = mapOf(
            "held_frames" to listOf("0123456789abcdef"),
            "delivery" to listOf("0123456789abcdef", "node-beta"),
            "store_meta" to emptyList<String>(),
        )
    }

    private fun addedByStep(table: String, column: String): Int? =
        STEPS.firstOrNull { it.statements.any { s -> s.lowercase().contains("table $table add column $column") } }?.to

    private fun columnsPresentAt(table: String, revision: Int): List<String> =
        FROZEN.tables.first { it.name == table }.columns.filter { c ->
            val add = addedByStep(table, c); add == null || add <= revision
        }

    private fun initialTablesAt(revision: Int): List<TableFingerprint> =
        FROZEN.tables.map { tf ->
            val cols = columnsPresentAt(tf.name, revision)
            TableFingerprint(tf.name, cols, tf.immutableColumns.filter { cols.contains(it) }.toSet())
        }

    private fun newExec(revision: Int): InMemoryMigrationExecutor =
        InMemoryMigrationExecutor(revision, initialTablesAt(revision), IMMUTABLE_VALUES).withImmutableDomains(IMMUTABLE_DOMAINS)

    private fun hasColumn(ex: InMemoryMigrationExecutor, table: String, column: String): Boolean =
        ex.observeFingerprint().tables.first { it.name == table }.columns.contains(column)

    // (1) every supported version reaches current (a start already at current is AlreadyCurrent)
    @Test
    fun testEverySupportedVersionReachesCurrent() {
        for (s in 1..SUPPORTED_MAX) {
            val engine = SchemaMigrationEngine(STEPS, SUPPORTED_MAX, FROZEN)
            val ex = newExec(s)
            val r = engine.migrate(s, ex.observeFingerprint(), ex)
            assertTrue("rev $s should land at current, got $r", r.isOk)
            assertTrue("rev $s ends Upgraded or AlreadyCurrent", r is MigrationResult.Upgraded || r is MigrationResult.AlreadyCurrent)
            if (r is MigrationResult.Upgraded) assertEquals("rev $s reaches current", SUPPORTED_MAX, r.to)
            assertTrue("the migrated schema matches the frozen fingerprint at rev $s", FROZEN.matches(ex.observeFingerprint()))
        }
    }

    // (2) crash at any statement rolls the WHOLE step back; the run is idempotent after the crash
    @Test
    fun testCrashAtEachStatementRollsBackAndReRunsIdempotently() {
        val plan = listOf(MigrationStep(5, 6, listOf("ALTER TABLE held_frames ADD COLUMN meta_v6", "ALTER TABLE store_meta ADD COLUMN kdf")))
        val engine = SchemaMigrationEngine(plan, SUPPORTED_MAX, FROZEN)
        // crash before the first statement: nothing is applied
        val ex0 = newExec(5); ex0.crashAfterStatement = 0
        val r0 = engine.migrate(5, ex0.observeFingerprint(), ex0)
        assertTrue("crash before any statement fails closed", r0 is MigrationResult.Failed)
        r0 as MigrationResult.Failed; assertTrue(r0.rolledBack); assertTrue(r0.versionPreserved)
        assertFalse("the crashed step left NO column behind (transactional)", hasColumn(ex0, "held_frames", "meta_v6"))
        assertEquals(0, ex0.executed.size)
        // crash after the first statement: the whole step still rolls back -- the already-run ADD is NOT committed
        val ex1 = newExec(5); ex1.crashAfterStatement = 1
        val r1 = engine.migrate(5, ex1.observeFingerprint(), ex1)
        r1 as MigrationResult.Failed; assertTrue(r1.rolledBack); assertTrue(r1.versionPreserved)
        assertFalse("a mid-step crash must roll back the already-executed statement too", hasColumn(ex1, "held_frames", "meta_v6"))
        assertEquals(0, ex1.executed.size)
        // no crash: the step commits exactly once and a re-run after the checkpoint is idempotent
        val exOk = newExec(5)
        val ok = engine.migrate(5, exOk.observeFingerprint(), exOk)
        assertTrue(ok is MigrationResult.Upgraded)
        assertTrue("the committed step added the column", hasColumn(exOk, "held_frames", "meta_v6"))
        assertEquals("the column was added exactly once across the committed run", 1, exOk.executed.count { it.contains("meta_v6") })
        val again = engine.migrate(exOk.checkpointedThrough(), exOk.observeFingerprint(), exOk)
        assertTrue("re-running after a durable checkpoint is idempotent (AlreadyCurrent)", again is MigrationResult.AlreadyCurrent)
    }

    // (3) a duplicate launch is idempotent
    @Test
    fun testDuplicateLaunchIsIdempotent() {
        val engine = SchemaMigrationEngine(STEPS, SUPPORTED_MAX, FROZEN)
        val ex = newExec(5)
        val first = engine.migrate(5, ex.observeFingerprint(), ex)
        assertTrue(first is MigrationResult.Upgraded)
        val stmtsAfterFirst = ex.executed.toList()
        val second = engine.migrate(ex.checkpointedThrough(), ex.observeFingerprint(), ex)
        assertTrue("a duplicate launch is AlreadyCurrent", second is MigrationResult.AlreadyCurrent)
        assertEquals("the duplicate launch added no new side effects", stmtsAfterFirst, ex.executed.toList())
    }

    // (4) a future schema is UnsupportedVersion and NOTHING is deleted (fail closed)
    @Test
    fun testFutureVersionIsUnsupportedAndNothingDeleted() {
        val engine = SchemaMigrationEngine(STEPS, SUPPORTED_MAX, FROZEN)
        val ex = newExec(SUPPORTED_MAX)
        val before = ex.immutableDigest()
        val r = engine.migrate(SUPPORTED_MAX + 3, ex.observeFingerprint(), ex)
        assertEquals("a future version is refused", MigrationResult.UnsupportedVersion(SUPPORTED_MAX + 3, SUPPORTED_MAX), r)
        assertEquals("nothing was executed", 0, ex.executed.size)
        assertEquals("nothing was deleted -- the immutable bytes are intact", before, ex.immutableDigest())
    }

    // (5) an altered schema yields RepairRequired, NOT a silent recreate
    @Test
    fun testAlteredSchemaYieldsRepairNotRecreate() {
        val engine = SchemaMigrationEngine(STEPS, SUPPORTED_MAX, FROZEN)
        val ex = newExec(SUPPORTED_MAX)
        val drifted = SchemaFingerprint(FROZEN.tables.map { if (it.name == "held_frames") TableFingerprint(it.name, it.columns + "rogue_column", it.immutableColumns) else it })
        val r = engine.migrate(SUPPORTED_MAX, drifted, ex)
        assertTrue("drift from the frozen fingerprint demands repair", r is MigrationResult.RepairRequired)
        assertEquals("repair must NOT be a silent recreate (no DDL run)", 0, ex.executed.size)
    }

    // (6) after migration the immutable fields are byte-identical and the message id / recipient binding survive
    @Test
    fun testImmutableFieldsByteIdenticalAndBindingsPreserved() {
        val engine = SchemaMigrationEngine(STEPS, SUPPORTED_MAX, FROZEN)
        val ex = newExec(1)
        val before = ex.immutableDigest()
        val r = engine.migrate(1, ex.observeFingerprint(), ex)
        assertTrue("legit migration upgrades", r.isOk)
        assertEquals("the immutable fields are byte-identical after migration", before, ex.immutableDigest())
        assertTrue("the message id is retained", ex.immutableDigest().contains("held_frames.msg_id=0123456789abcdef"))
        assertTrue("the recipient binding is retained", ex.immutableDigest().contains("delivery.d_recipient=node-beta"))
        assertEquals("no immutable column was ever mutated or dropped", emptyList<String>(), ex.violations.toList())
        assertNotNull(ex)
    }
}
