package io.godstone.mesh.store

// ---------------------------------------------------------------------------
// T31 SHARED MIGRATION CONTRACT (android). The iOS twin (Sources/GodstoneMesh/
// SchemaMigration.swift) mirrors these types and the SAME law, and both courts
// (ReadinessT31Test.kt / ReadinessT31Tests.swift) drive ONE contract through an
// injected executor, so the laws are EXECUTED not narrated.
//
// It REPLACES the destructive drop-and-recreate on the VERSIONED upgrade path
// (the sealed MessageStore.onUpgrade drop path stays for the never-shipped
// pre-ship case -- blast-radius discipline: this is an ADDITIVE sanctioned seam;
// the engine is what the runtime binds onUpgrade to once installs must survive).
//
// Laws (each witnessed by a court case, each struck by a roster mutant):
//   * every supported version -> current: ordered steps run low->high;
//   * transactional: a step is BEGIN..COMMIT; a crash at ANY statement rolls the
//     WHOLE step back and leaves the store at the prior version (recoverable);
//   * idempotent after crash: a durably-committed step is never re-applied;
//   * future version -> UnsupportedVersion, NOTHING deleted (fail closed);
//   * altered schema (drift from the frozen fingerprint) -> RepairRequired,
//     NOT a silent recreate;
//   * immutable fields (msg_id / recipient binding) are BYTE-IDENTICAL after a
//     successful migration -- the plan never mutates them.
//
// Pure stdlib only: no Context / no SQLiteDatabase, so the model is deterministic
// and the physical run of the section19/18 cases against the built artifact stays
// DEVICE evidence (deferred T73-T75); the host proves the migration LAW here.
// ---------------------------------------------------------------------------

/** An ordered, comparable schema revision carrying the minimum rollback-compatible app revision. */
data class SchemaVersion(val revision: Int, val minimumRollbackCompatibleApp: Int) : Comparable<SchemaVersion> {
    override fun compareTo(other: SchemaVersion): Int = revision.compareTo(other.revision)
    init { require(revision >= 0) { "revision must be non-negative" } }
}

/** The frozen accepted fingerprint of the current table set (names + columns + immutable-field definitions). */
data class TableFingerprint(val name: String, val columns: List<String>, val immutableColumns: Set<String>) {
    /** Canonical, order-sensitive form so two equal schemas compare equal regardless of map iteration. */
    fun canonical(): String =
        "$name(" + columns.sorted().joinToString(",") + "|@" + immutableColumns.sorted().joinToString(",") + ")"
}

data class SchemaFingerprint(val tables: List<TableFingerprint>) {
    fun canonical(): String = tables.map { it.canonical() }.sorted().joinToString(";")
    fun matches(observed: SchemaFingerprint): Boolean = canonical() == observed.canonical()
    /** The union of every immutable column name across all tables -- the byte-identity guarantee's domain. */
    fun immutableColumnNames(): Set<String> = tables.flatMap { it.immutableColumns }.toSet()
}

/** One ordered migration edge from -> to, expressed as the statements (and/or a code apply) that advance it. */
data class MigrationStep(val from: Int, val to: Int, val statements: List<String>, val apply: ((MigrationExecutor) -> Unit)? = null) {
    init { require(to == from + 1) { "a migration step must advance exactly one revision ($from -> $to)" } }
}

/** The typed, total outcome of a migration attempt -- never a silent partial state. */
sealed class MigrationResult {
    data class Upgraded(val from: Int, val to: Int) : MigrationResult()
    data class AlreadyCurrent(val at: Int) : MigrationResult()
    /** A FUTURE schema: refuse, delete nothing (fail closed). */
    data class UnsupportedVersion(val found: Int, val supportedMax: Int) : MigrationResult()
    /** The observed schema drifted from the frozen fingerprint: require repair, do NOT recreate. */
    data class RepairRequired(val reason: String) : MigrationResult()
    /** A step faulted; the whole step rolled back and the prior version is preserved (recoverable). */
    data class Failed(val stage: String, val rolledBack: Boolean, val versionPreserved: Boolean) : MigrationResult()

    val isOk: Boolean get() = this is Upgraded || this is AlreadyCurrent
}

/** The injected statement executor / durable-checkpoint / observation seam the engine drives. */
interface MigrationExecutor {
    /** The highest revision durably committed so far -- used to make re-running idempotent. */
    fun checkpointedThrough(): Int
    /** Commit `statements` for `step` in ONE transaction; a crash throws and must leave NO partial effect. */
    fun execute(step: MigrationStep, statements: List<String>)
    /** Read the live schema as a fingerprint, to compare against the frozen accepted one. */
    fun observeFingerprint(): SchemaFingerprint
    /** A digest of the immutable-field bytes across all tables (for the byte-identity law). */
    fun immutableDigest(): String
    /** Persist the durable checkpoint after a committed step (idempotence marker). */
    fun markCheckpointed(step: MigrationStep)
}

/** The ordered, transactional, idempotent migration engine -- the sanctioned seam onUpgrade delegates to. */
class SchemaMigrationEngine(
    private val steps: List<MigrationStep>,
    private val supportedMax: Int,
    private val fingerprint: SchemaFingerprint,
) {
    /** Advance `currentVersion` to `supportedMax`, fail-closed and idempotent. */
    fun migrate(currentVersion: Int, observed: SchemaFingerprint, executor: MigrationExecutor): MigrationResult {
        // (1) A FUTURE schema: refuse without touching anything (no deletion, no downgrade).
        if (currentVersion > supportedMax) return MigrationResult.UnsupportedVersion(currentVersion, supportedMax)

        val checkpoint = executor.checkpointedThrough()
        val start = if (checkpoint > currentVersion) checkpoint else currentVersion

        // (2) Already current: nothing to run, but still demand the frozen fingerprint hold.
        if (start >= supportedMax) {
            return if (fingerprint.matches(observed)) MigrationResult.AlreadyCurrent(supportedMax)
            else MigrationResult.RepairRequired("observed schema drifts from the frozen fingerprint at current revision $supportedMax")
        }

        // (3) Run the ordered, gap-free chain low -> high, one committed transaction per step.
        val ordered = steps.filter { it.to > start && it.to <= supportedMax }.sortedBy { it.from }
        var expect = start
        for (step in ordered) {
            if (step.from != expect) {
                return MigrationResult.Failed("gap in the migration plan at $expect (next step ${step.from})", rolledBack = false, versionPreserved = true)
            }
            if (step.to <= executor.checkpointedThrough()) { expect = step.to; continue }   // idempotence: skip a durably-applied step
            try {
                executor.execute(step, step.statements)
                step.apply?.invoke(executor)
            } catch (t: Throwable) {
                // The step's transaction rolled back; the store is left at `expect` (recoverable). Fail closed.
                return MigrationResult.Failed("step ${step.from}->${step.to} (${t::class.simpleName})", rolledBack = true, versionPreserved = expect == step.from)
            }
            executor.markCheckpointed(step)
            expect = step.to
        }
        if (expect != supportedMax) {
            return MigrationResult.Failed("plan ended at $expect, short of current $supportedMax", rolledBack = false, versionPreserved = true)
        }

        // (4) Verify the frozen fingerprint holds on the migrated schema -- drift demands repair, NOT recreate.
        val after = executor.observeFingerprint()
        if (!fingerprint.matches(after)) {
            return MigrationResult.RepairRequired("migrated schema drifts from the frozen fingerprint")
        }
        return MigrationResult.Upgraded(start, supportedMax)
    }
}

// ---------------------------------------------------------------------------
// Reference in-memory MigrationExecutor -- the deterministic seam BOTH isles'
// courts drive (the iOS twin mirrors its observable model). It records every
// statement, models an ALTER ADD COLUMN / DROP TABLE, maintains the immutable-
// field byte digest, honours a single durable checkpoint (idempotence) and can
// crash at any statement index (transactional rollback of the whole step).
// It is deliberately not the production store -- the production binding reuses
// the sealed MessageStore DDL; this executor makes the ENGINE's laws EXECUTABLE
// on the host so no device/SDK result is fabricated.
// ---------------------------------------------------------------------------

class InMemoryMigrationExecutor(
    private val startRevision: Int,
    initialTables: List<TableFingerprint>,
    initialImmutable: Map<String, List<String>> = emptyMap(),
) : MigrationExecutor {
    private data class Row(val cells: Map<String, String>)

    private val tables: MutableMap<String, MutableList<String>> = mutableMapOf()
    private val rows: MutableMap<String, MutableList<Row>> = mutableMapOf()
    private var checkpoint: Int = startRevision
    val executed: MutableList<String> = mutableListOf()
    val violations: MutableList<String> = mutableListOf()
    private var immutableDomains: Map<String, Set<String>> = emptyMap()
    /** When >= 0, the executor throws once that many statements have run INSIDE the current step, simulating a mid-step crash (the whole step must roll back). */
    var crashAfterStatement: Int = -1

    init {
        for (tf in initialTables) {
            tables[tf.name] = tf.columns.toMutableList()
            val imm = initialImmutable[tf.name] ?: emptyList()
            val cells = mutableMapOf<String, String>()
            tf.immutableColumns.sorted().forEachIndexed { i, c -> cells[c] = imm.getOrNull(i) ?: "" }
            rows[tf.name] = mutableListOf(Row(cells))
        }
    }

    /** Supply the per-table immutable-column domains (the byte-identity guarantee's subject). */
    fun withImmutableDomains(domains: Map<String, Set<String>>): InMemoryMigrationExecutor { this.immutableDomains = domains; return this }

    private fun isImmutableCol(table: String, column: String): Boolean = immutableDomains[table]?.contains(column) == true

    override fun observeFingerprint(): SchemaFingerprint =
        SchemaFingerprint(tables.map { (t, cols) -> TableFingerprint(t, cols.toList(), (immutableDomains[t] ?: emptySet()).filter { cols.contains(it) }.toSet()) })

    override fun immutableDigest(): String {
        val sb = StringBuilder()
        for (t in rows.keys.sorted()) {                       // sorted key order => deterministic digest regardless of map backing
            val rs = rows[t] ?: continue
            val cols = (immutableDomains[t] ?: emptySet()).sorted()
            for (r in rs) for (c in cols) sb.append(t).append('.').append(c).append('=').append(r.cells[c] ?: "").append(';')
        }
        return sb.toString()
    }

    override fun checkpointedThrough(): Int = checkpoint
    override fun markCheckpointed(step: MigrationStep) { if (step.to > checkpoint) checkpoint = step.to }

    override fun execute(step: MigrationStep, statements: List<String>) {
        // Transactional: snapshot the live schema (deep, via toList() copies), mutate LIVE, and on ANY fault
        // restore the snapshot -- so a mid-step crash rolls the ENTIRE step back (no partial application) and a
        // re-run after the crash re-applies it exactly once (idempotence). toMutableList() on the read-only
        // snapshot yields a fresh mutable copy, avoiding the MutableList self-aliasing that a naive stage had.
        val snapT = copyTables(tables)
        val snapR = copyRows(rows)
        val snapViol = newStrList(violations)
        val snapExec = newStrList(executed)
        var ran = 0
        try {
            for (s in statements) {
                if (crashAfterStatement in 0..ran) throw MigrationCrashSimulation("crash at statement '$s' of step ${step.from}->${step.to}")
                applyStatement(s)
                ran += 1
            }
        } catch (t: Throwable) {
            tables.clear(); for ((k, v) in snapT) tables[k] = v
            rows.clear(); for ((k, v) in snapR) rows[k] = v
            violations.clear(); violations.addAll(snapViol)
            executed.clear(); executed.addAll(snapExec)
            throw t
        }
    }

    private fun copyTables(src: Map<String, MutableList<String>>): MutableMap<String, MutableList<String>> {
        val out = mutableMapOf<String, MutableList<String>>()
        for ((k, v) in src) { val c = mutableListOf<String>(); c.addAll(v); out[k] = c }
        return out
    }

    private fun copyRows(src: Map<String, MutableList<Row>>): MutableMap<String, MutableList<Row>> {
        val out = mutableMapOf<String, MutableList<Row>>()
        for ((k, v) in src) { val c = mutableListOf<Row>(); c.addAll(v); out[k] = c }
        return out
    }

    private fun newStrList(src: List<String>): MutableList<String> {
        val c = mutableListOf<String>(); c.addAll(src); return c
    }

    private fun applyStatement(s: String) {
        executed.add(s)
        // Token-parse the DDL on a lowercased view (no regex -- the identifier class would otherwise be fragile).
        val tk = s.lowercase().trim().split(' ', '\t').filter { it.isNotEmpty() && it != "if" && it != "exists" }
        if (tk.size >= 3 && tk[0] == "drop" && tk[1] == "table") {
            val tn = tk[2]
            if ((immutableDomains[tn] ?: emptySet()).isNotEmpty()) violations += "dropped protected table $tn"
            rows.remove(tn); tables.remove(tn)
            return
        }
        if (tk.size >= 6 && tk[0] == "alter" && tk[1] == "table" && tk[3] == "add" && tk[4] == "column") {
            val tn = tk[2]; val c = tk[5]                                                   // ALTER TABLE <tn> ADD COLUMN <c>
            val cols = tables[tn]; if (cols != null && !cols.contains(c)) cols.add(c)
            return
        }
        if (tk.size >= 4 && tk[0] == "update" && tk[2] == "set") {
            val tn = tk[1]; val c = tk[3].substringBefore('=')                             // UPDATE <tn> SET <c>=...
            if (isImmutableCol(tn, c)) violations += "attempted to mutate immutable column $tn.$c"
        }
    }
}

/** Signals a simulated mid-step crash so the engine's transactional rollback is exercised on the host. */
class MigrationCrashSimulation(message: String) : RuntimeException(message)
