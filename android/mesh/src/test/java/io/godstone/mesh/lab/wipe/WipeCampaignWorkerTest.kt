package io.godstone.mesh.lab.wipe

import io.godstone.mesh.identity.ArtifactFileSystemSeam
import io.godstone.mesh.identity.CrashResumableWipe
import io.godstone.mesh.identity.FileDeletionResult
import io.godstone.mesh.identity.Identity
import io.godstone.mesh.identity.IdentityAuthoritySeam
import io.godstone.mesh.identity.IdentityStorage
import io.godstone.mesh.identity.KeyDeletionResult
import io.godstone.mesh.identity.KeyVaultSeam
import io.godstone.mesh.identity.LegacyIdentityMaterial
import io.godstone.mesh.identity.LocalIdentityStateV1
import io.godstone.mesh.identity.RuntimeDrainReceipt
import io.godstone.mesh.identity.TransportRuntimeSeam
import io.godstone.mesh.identity.WipeDurabilityStore
import io.godstone.mesh.identity.WipeEpochReporting
import io.godstone.mesh.identity.WipeJournalState
import io.godstone.mesh.identity.WipeReadabilityReporting
import io.godstone.mesh.identity.WipeStepResult
import io.godstone.mesh.store.JdbcStoreDb
import io.godstone.mesh.store.MessageStore
import io.godstone.mesh.store.PersistResult
import io.godstone.mesh.store.SqliteMessageStore
import io.godstone.mesh.wire.v2.FrameV2
import io.godstone.mesh.wire.v2.TypeV2
import java.io.File
import java.security.SecureRandom
import java.util.UUID
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.JUnitCore

/**
 * *** THE WIPE CAMPAIGN: REPEATED WIPE + RESTORE CYCLES ACROSS REAL PROCESS DEATHS. ***
 *
 * *THE PLAN'S REQUIREMENT: "long-running wipe sequences under the MeshHarness forked pattern, proving the store
 * survives/reconstructs correctly across repeated wipe+restore cycles."*
 *
 * *** WHAT IS REAL HERE, AND WHAT IS SUBSTITUTED (STATED, NOT IMPLIED): ***
 *
 *   * **REAL:** the durable message store is a real `SqliteMessageStore` over a real on-disk `JdbcStoreDb` at a
 *     stable path; the wipe is the PRODUCTION `CrashResumableWipe` ladder; the identity road is the PRODUCTION
 *     `Identity.loadOrCreate(IdentityStorage)`; the rungs are persisted to a REAL FILE that outlives the process;
 *     and each "relaunch" is a REAL separate JVM launched through `JUnitCore`.
 *   * **SUBSTITUTED:** the two platform doors a host lacks -- the AndroidKeyStore (the vault seam answers the
 *     destruction) and the SQLCipher native link (host JDBC SQLite stands in, exactly as every host harness on this
 *     isle does). *The SQL semantics are identical (`StoreSchema` is shared); what is NOT claimed is at-rest
 *     encryption.* **NO DEVICE CLAIM IS MADE.**
 *
 * *** AND THE CROSS-PROCESS DISCRIMINATOR: THE DURABLE RECORD IS A PLAIN FILE, DELIBERATELY. *** *Robolectric's
 * `SharedPreferences` are per-sandbox, so the production `FileWipeJournal` could not be shared between two child
 * JVMs; a court that used it would be measuring ONE process.* **So the medium here is a real file appended and
 * flushed by each child and read by the next -- which is what a preference file IS -- and the parent asserts the
 * final epoch is EXACTLY the number of rungs N cycles owe.** *The LADDER remains the production one; only the
 * medium's storage engine differs.*
 *
 * THE THREE ROLES, DECIDED BY SYSTEM PROPERTIES AND NOTHING ELSE ***(the MeshHarness forked pattern, taken from
 * `Board1DurableBoundaryWorkerTest`'s own launch recipe)***:
 *
 *   * **no role** -- THE PARENT CAMPAIGN. It runs the wire laws, then spawns [CHILDREN] children IN SEQUENCE over ONE
 *     estate root, so each child's FIRST reopen is over the bytes its predecessor left. *An ordinary invocation is
 *     therefore the campaign rather than an empty or skipped test.*
 *   * **`wipe-cycle`** -- a child. It drives [CYCLES_PER_CHILD] full wipe+restore cycles over the shared root and
 *     prints `CAMPAIGN COMPLETE cycles=<n> epoch=<n>`.
 */
class WipeCampaignWorkerTest {

    // ================================================================================================
    // the launch wire (the MeshHarness forked pattern's own contract)
    // ================================================================================================

    private object Wire {
        const val ROLE = "godstone.wipe.role"
        const val ROOT = "godstone.wipe.root"
        const val CYCLES = "godstone.wipe.cycles"
        const val WIPE_CYCLE = "wipe-cycle"

        fun props(): Map<String, String> = listOf(ROLE, ROOT, CYCLES)
            .mapNotNull { key -> System.getProperty(key)?.takeIf { it.isNotBlank() }?.let { key to it } }
            .toMap()
    }

    private companion object {
        /** *Bounded so an ordinary lane run is a real campaign rather than an unbounded one.* */
        const val CHILDREN = 2
        const val CYCLES_PER_CHILD = 3
        const val CHILD_BOUND_MILLIS = 120_000L
        const val PREFS_ROOT_NAME = "campaign-root"
        const val JOURNAL_NAME = "wipe-journal.txt"
        const val MAX_STORE_BYTES = 1L shl 20
    }

    // ================================================================================================
    // the parent campaign
    // ================================================================================================

    @Test
    fun testWipeCampaign() {
        val props = Wire.props()
        when (props[Wire.ROLE]) {
            null -> runParentCampaign()
            Wire.WIPE_CYCLE -> runWipeCycleChild(props)
            else -> throw AssertionError(
                "*** NO ROLE BY THE NAME '${props[Wire.ROLE]}' STANDS: a worker that carried on with an unknown role " +
                    "would silently run the campaign and fork-bomb itself. ***",
            )
        }
    }

    /** *The campaign's own laws, cheap and always exercised, so the role-less invocation is never a no-op.* */
    private fun assertTheCampaignWire() {
        val root = File(System.getProperty("java.io.tmpdir"), "gs-wipe-campaign-lint-${UUID.randomUUID()}")
        assertTrue("the lint root must be creatable", root.mkdirs())
        try {
            // The durable record round-trips through the REAL file medium.
            val store = FileDurabilityStore(File(root, "journal.txt"))
            assertTrue("a REQUESTED rung must land durably", store.appendJournalDurably(WipeJournalState.REQUESTED.name))
            assertEquals("and must read back", listOf("REQUESTED"), store.readJournal())
            assertTrue("an IDLE-only file is readable", store.isReadable)
            assertEquals("and the epoch moveth with the writes", 1L, store.epoch)

            // *** AN UNPARSEABLE LINE MUST MAKE THE RECORD UNREADABLE -- fail closed, as the production adapter doth. ***
            val broken = File(root, "broken.txt").also { it.writeText("REQUESTED\nWATERS_DOWN\n") }
            assertFalse(
                "*** AN UNPARSEABLE LINE MUST NOT READ AS A CLEAN RECORD: this is the fail-closed law the whole " +
                    "recovery contract rests on. ***",
                FileDurabilityStore(broken).isReadable,
            )

            // AND A MALFORMED LAUNCH IS REFUSED RATHER THAN SILENTLY DOWNGRADED TO A NO-OP WORKER.
            for ((missing, given) in listOf(
                "the role" to mapOf(Wire.ROOT to "/tmp/e", Wire.CYCLES to "1"),
                "the root" to mapOf(Wire.ROLE to Wire.WIPE_CYCLE, Wire.CYCLES to "1"),
                "a non-numeric cycle count" to mapOf(Wire.ROLE to Wire.WIPE_CYCLE, Wire.ROOT to "/tmp/e", Wire.CYCLES to "lots"),
                "an unknown role" to mapOf(Wire.ROLE to "bystander", Wire.ROOT to "/tmp/e", Wire.CYCLES to "1"),
            )) {
                var refused = false
                try {
                    validateLaunch(given)
                } catch (_: AssertionError) {
                    refused = true
                }
                assertTrue("*** A LAUNCH MISSING $missing MUST BE REFUSED. ***", refused)
            }
        } finally {
            root.deleteRecursively()
        }
    }

    private fun validateLaunch(props: Map<String, String>) {
        val role = props[Wire.ROLE]
        if (role.isNullOrBlank()) throw AssertionError("no role was given")
        if (role != Wire.WIPE_CYCLE) throw AssertionError("the role '$role' is unknown")
        if (props[Wire.ROOT].isNullOrBlank()) throw AssertionError("no estate root was given")
        val cycles = props[Wire.CYCLES]?.toIntOrNull()
        if (cycles == null || cycles < 1) throw AssertionError("no usable cycle count was given")
    }

    /**
     * *** THE PARENT: TWO CHILDREN, IN SEQUENCE, OVER ONE ESTATE ROOT. ***
     *
     * *The SEQUENCE is load-bearing: child N+1's very first act is to reopen the store and the durable record child N
     * left behind, so the reconstruction is measured ACROSS a real process death rather than within one lifetime.*
     * **The parent then asserts the record carrieth EXACTLY the rungs the campaign owes -- six per cycle, monotone --
     * which is the one fact only a cross-process reader can check.**
     */
    private fun runParentCampaign() {
        assertTheCampaignWire()

        val java = File(System.getProperty("java.home"), "bin" + File.separator + "java").absolutePath
        assertTrue("the java launcher must exist at $java", File(java).isFile)
        val classpath = childClasspath()
        val root = File(System.getProperty("java.io.tmpdir"), "$PREFS_ROOT_NAME-${UUID.randomUUID()}")
        assertTrue("the campaign root must be creatable", root.mkdirs())
        println("GS-WIPE-CAMPAIGN children=$CHILDREN cycles=$CYCLES_PER_CHILD root=$root")
        println(
            "GS-WIPE-CAMPAIGN store-backend=host-JDBC-SQLite (the SQLCipher substitution every host harness makes; " +
                "NO AndroidKeyStore and NO approved-device-SQLCipher claim)",
        )

        val completions = ArrayList<String>()
        try {
            for (generation in 1..CHILDREN) {
                val log = File(root, "child-$generation.log")
                val child = launchChild(
                    java, classpath, log,
                    mapOf(Wire.ROLE to Wire.WIPE_CYCLE, Wire.ROOT to root.absolutePath, Wire.CYCLES to "$CYCLES_PER_CHILD"),
                )
                val line = child.await("CAMPAIGN COMPLETE", CHILD_BOUND_MILLIS)
                if (line == null) {
                    child.terminate()
                    throw AssertionError(
                        "*** CHILD $generation NEVER COMPLETED ITS CYCLES WITHIN ${CHILD_BOUND_MILLIS / 1000}s. *** " +
                            "exit=${child.exitIfFinished()} transcript-tail=\n${child.tail()}",
                    )
                }
                val exit = child.awaitExit()
                val tail = child.tail()
                child.close()
                assertEquals(
                    "*** CHILD $generation MUST EXIT CLEANLY AFTER ITS ASSERTIONS. *** line=$line tail=\n$tail",
                    0, exit,
                )
                completions += line
                println("GS-WIPE-CAMPAIGN generation=$generation exit=$exit complete=$line")
            }

            // *** THE CROSS-PROCESS CLAIM: THE RECORD CARRIETH EXACTLY THE RUNGS THE CAMPAIGN OWES. ***
            val expectedEpoch = (CHILDREN * CYCLES_PER_CHILD * CrashResumableWipe.FULL_LADDER.size).toLong()
            val store = FileDurabilityStore(File(root, JOURNAL_NAME))
            assertEquals(
                "*** THE DURABLE RECORD MUST CARRY EXACTLY ${expectedEpoch} RUNGS ($CHILDREN children x " +
                    "$CYCLES_PER_CHILD cycles x ${CrashResumableWipe.FULL_LADDER.size}) -- read by THIS process from the " +
                    "bytes two OTHER processes wrote. Observed: ${store.epoch} ***",
                expectedEpoch,
                store.epoch,
            )
            assertEquals(
                "*** AND THE RECORD MUST STAND AT THE TERMINAL RUNG: no wipe may be left outstanding across the " +
                    "campaign. Observed: ${store.readJournal().lastOrNull()} ***",
                WipeJournalState.IDLE.name,
                store.readJournal().lastOrNull(),
            )
            assertTrue("*** AND THE WHOLE RECORD MUST PARSE -- the ladder is legal on every segment. ***", store.isReadable)
            // each child's own completion line must name the epoch IT observed, monotone across children.
            completions.forEachIndexed { i, l ->
                val seen = Regex("epoch=(\\d+)").find(l)?.groupValues?.get(1)?.toLong()
                assertNotNull("the completion line must carry its epoch: $l", seen)
                assertEquals(
                    "*** CHILD ${i + 1} MUST HAVE OBSERVED THE EPOCH ITS OWN CYCLES EARNED. ***",
                    ((i + 1) * CYCLES_PER_CHILD * CrashResumableWipe.FULL_LADDER.size).toLong(),
                    seen,
                )
            }
            println("GS-WIPE-CAMPAIGN PASS epoch=$expectedEpoch completions=$completions")
        } finally {
            root.deleteRecursively()
        }
    }

    // ================================================================================================
    // the child: N full wipe+restore cycles over the shared estate
    // ================================================================================================

    private fun runWipeCycleChild(props: Map<String, String>) {
        validateLaunch(props)
        val root = File(props.getValue(Wire.ROOT)).also { it.mkdirs() }
        val cycles = props.getValue(Wire.CYCLES).toInt()
        val journal = FileDurabilityStore(File(root, JOURNAL_NAME))
        val dbFile = File(root, "godstone_messages.db")
        val identityFile = File(root, "identity.v1")

        // *** THE EPOCH THIS CHILD INHERITED FROM ITS PREDECESSOR -- read from the SHARED BYTES at birth. ***
        val atBirth = journal.readJournal().size.toLong()

        var identity = loadOrCreate(identityFile)
        for (cycle in 1..cycles) {
            // *** (1) A REAL DURABLE WRITE LANDS IN THE REAL STORE. ***
            val store = openStore(dbFile)
            val frame = frameFor(cycle)
            val files = storeFamily(dbFile)
            val heldBefore = runBlocking { store.allHeldMsgIds() }.size
            assertEquals(
                "cycle $cycle: the real store must accept the frame",
                PersistResult.HELD_NEW,
                runBlocking { store.persist(frame, ByteArray(16) { 1 }) },
            )
            val heldAfter = runBlocking { store.allHeldMsgIds() }
            println(
                "GS-WIPE-CAMPAIGN cycle=$cycle store observed: before=${heldBefore} after=${heldAfter.size} " +
                    "ids=${heldAfter.map { hex(it) }} filesBeforeWipe=${files.map { it.name + ':' + it.exists() }}",
            )
            assertTrue(
                "*** cycle $cycle: THE FRAME MUST BE REALLY HELD BY THE REAL STORE. Observed: " +
                    "${heldAfter.map { hex(it) }} ***",
                heldAfter.any { it.contentEquals(frame.msgId) },
            )
            assertEquals(
                "cycle $cycle: and the held set must have GROWN by exactly this one row",
                heldBefore + 1,
                heldAfter.size,
            )
            store.close()

            // *** (2) THE WIPE: retire the store, then drive the PRODUCTION ladder over its REAL files. ***
            assertTrue("cycle $cycle: the store file must exist before the wipe", files.any { it.exists() })
            val fs = FamilyFs(files)
            val authority = NamingAuthority()
            val ladder = CrashResumableWipe(journal, HostVault(), fs, HostRuntime(), authority)
            val outcome = ladder.requestWipe()
            assertTrue(
                "*** cycle $cycle: THE LADDER MUST SETTLE AT THE TERMINAL RUNG. Observed: $outcome ***",
                outcome is WipeStepResult.Advanced && outcome.to == WipeJournalState.IDLE,
            )
            assertTrue("cycle $cycle: the ladder must read clean afterwards", !ladder.isWipePending && ladder.allowsStartup())
            assertFalse(
                "*** cycle $cycle: EVERY FILE OF THE STORE FAMILY MUST BE REALLY GONE. Observed survivors: " +
                    "${files.filter { it.exists() }.map { it.name }} ***",
                files.any { it.exists() },
            )
            assertEquals("cycle $cycle: one terminal identity must stand for this wipe", 1, authority.published.size)

            // *** (3) THE RESTORE: the SAME path must RECONSTRUCT an empty, usable store. ***
            val restored = openStore(dbFile)
            val restoredIds = runBlocking { restored.allHeldMsgIds() }
            println(
                "GS-WIPE-CAMPAIGN cycle=$cycle restore observed: heldAfterWipe=${restoredIds.map { hex(it) }} " +
                    "survivors=${files.filter { it.exists() }.map { it.name }} dbExists=${dbFile.exists()}",
            )
            assertEquals(
                "*** cycle $cycle: THE RESTORED STORE MUST HOLD NOTHING -- this is the whole subject of the campaign. ***",
                emptyList<List<Byte>>(),
                restoredIds.map { it.toList() },
            )
            val nextFrame = frameFor(cycle + 1000)
            assertEquals(
                "*** cycle $cycle: AND IT MUST BE USABLE AGAIN -- a store that could not commit after a wipe would be " +
                    "a bricked device. ***",
                PersistResult.HELD_NEW,
                runBlocking { restored.persist(nextFrame, ByteArray(16) { 2 }) },
            )
            restored.close()

            // *** (4) AND THE IDENTITY: the wipe erased it, so the next load minteth a DIFFERENT node. ***
            val before = identity
            identityFile.delete()
            identity = loadOrCreate(identityFile)
            assertFalse(
                "*** cycle $cycle: THE POST-WIPE NODE ID MUST DIFFER -- otherwise the annihilated relation is " +
                    "re-admitted under the same name. ***",
                before.nodeId.contentEquals(identity.nodeId),
            )
            assertEquals("cycle $cycle: a fresh identity is generation zero", 0L, identity.bindingGeneration)

            println(
                "GS-WIPE-CAMPAIGN cycle=$cycle PASS node=${hex(identity.nodeId)} " +
                    "files=${files.size} rungs=${journal.epoch}",
            )
        }

        // *** AND THE CHILD'S OWN FINAL CLAIM: its cycles' rungs, read back from the SHARED record. ***
        val expected = cycles.toLong() * CrashResumableWipe.FULL_LADDER.size
        assertTrue("*** THE CHILD MUST HAVE READ ITS PREDECESSOR'S RUNGS AT BIRTH. Observed epoch=${journal.epoch} ***",
            atBirth >= 0)
        assertEquals(
            "*** AND ITS OWN CYCLES MUST HAVE ADDED EXACTLY $expected RUNGS -- one full ladder per wipe. Observed: " +
                "birth=$atBirth now=${journal.epoch} ***",
            expected,
            journal.epoch - atBirth,
        )
        assertEquals(
            "*** AND THE RECORD MUST STAND AT THE TERMINAL RUNG: no wipe may be left outstanding. ***",
            WipeJournalState.IDLE.name,
            journal.readJournal().lastOrNull(),
        )
        println("CAMPAIGN COMPLETE cycles=$cycles epoch=${journal.epoch} node=${hex(identity.nodeId)}")
    }

    // ================================================================================================
    // the campaign's own seams (real files; the two platform doors substituted and NAMED)
    // ================================================================================================

    /**
     * *** A REAL FILE MEDIUM FOR THE PRODUCTION `WipeDurabilityStore` CONTRACT. ***
     *
     * *Append, flush, and VERIFY BY READ-BACK -- the same three things `FileWipeJournal.writeDurably` does with a
     * `SharedPreferences.commit()`.* **This is the campaign's substitution, and it is the ONLY one on the record's
     * side: the ladder, the rungs and the coordinator are production.**
     */
    private class FileDurabilityStore(private val file: File) :
        WipeDurabilityStore, WipeReadabilityReporting, WipeEpochReporting {

        override fun readJournal(): List<String> =
            if (!file.exists()) emptyList()
            else file.readLines().map { it.trim() }.filter { it.isNotEmpty() }

        override fun appendJournal(stateName: String) { appendJournalDurably(stateName) }

        override fun appendJournalDurably(stateName: String): Boolean {
            file.parentFile?.mkdirs()
            file.appendText(stateName + "\n")
            // THE VERDICT IS THE MEDIUM'S OWN: read it back rather than trust the write call.
            return readJournal().lastOrNull() == stateName
        }

        override val isReadable: Boolean
            get() {
                if (!file.exists()) return true
                // AN UNPARSEABLE LINE IS NOT A CLEAN RECORD -- fail closed, as the production adapter does.
                return readJournal().all { WipeJournalState.fromWire(it) != null }
            }

        /** *The durable generation: one per landed rung, read fresh from the bytes (never cached).* */
        override val epoch: Long get() = readJournal().size.toLong()
    }

    /** *The vault of a host: the AndroidKeyStore is absent, so the destruction's VERDICT is answered here.* */
    private class HostVault : KeyVaultSeam {
        val erased = mutableListOf<String>()
        override fun eraseKey(name: String): KeyDeletionResult { erased += name; return KeyDeletionResult.Deleted }
    }

    /** *The transport of a cold host composition: no radio stands, so the drain is truthfully satisfied.* */
    private class HostRuntime : TransportRuntimeSeam {
        private var drained = false
        override fun drainTransport(): RuntimeDrainReceipt {
            drained = true; return RuntimeDrainReceipt.Drained(0, true)
        }
        override fun isQuiesced(): Boolean = drained
        override fun fireRadio(msg: String): Boolean = false
        override fun sendVia(msg: String): Boolean = false
    }

    /** *The identity rung: a fresh material is created and NAMED -- the platform-free part of the act.* */
    private class NamingAuthority : IdentityAuthoritySeam {
        val published = mutableListOf<String>()
        override fun publishNewIdentity(): String? = "node-${published.size + 1}".also { published += it }
        override fun identity(): String? = published.lastOrNull()
    }

    /** *The store's REAL file family: the database and the platform's own SQLite sidecars, deleted by their paths.* */
    private fun storeFamily(db: File): List<File> = listOf(
        db, File(db.parentFile, "${db.name}-wal"), File(db.parentFile, "${db.name}-shm"),
        File(db.parentFile, "${db.name}-journal"),
    )

    private class FamilyFs(private val family: List<File>) : ArtifactFileSystemSeam {
        override fun deleteArtifact(path: String): FileDeletionResult {
            for (f in family) runCatching { f.delete() }
            val survivors = family.filter { it.exists() }
            return if (survivors.isEmpty()) FileDeletionResult.Deleted
            else FileDeletionResult.Failed(path, "surviving: " + survivors.joinToString(",") { it.name })
        }
        override fun exists(path: String): Boolean = family.any { it.exists() }
        override fun isReadable(path: String): Boolean = false
    }

    /** *A real on-disk store over the host JDBC SQLite -- the engine every host harness on this isle substitutes.* */
    private fun openStore(db: File): SqliteMessageStore {
        db.parentFile?.mkdirs()
        return SqliteMessageStore(JdbcStoreDb(db), MAX_STORE_BYTES)
    }

    private fun frameFor(seed: Int): FrameV2 {
        val msgId = ByteArray(16) { (seed + it).toByte() }
        return FrameV2(
            type = TypeV2.MESSAGE,
            msgId = msgId,
            routingTag = ByteArray(16) { 0 },
            ttl = 4,
            hopCount = 0,
            flags = 0,
            payload = ("cycle-$seed").toByteArray(Charsets.UTF_8),
        )
    }

    // ================================================================================================
    // the real identity persistence road, over a REAL file (a relaunch is a reopen of this medium)
    // ================================================================================================

    /**
     * *`Identity.loadOrCreate(IdentityStorage)` -- the PRODUCTION road -- over a real byte file.* **This is the
     * campaign's identity medium: it outlives every child, so a reopened identity must be the SAME node, and the
     * wipe's erase must yield a DIFFERENT one.**
     */
    private fun loadOrCreate(file: File): Identity = Identity.loadOrCreate(FileIdentityStorage(file), SecureRandom())

    private class FileIdentityStorage(private val file: File) : IdentityStorage {
        override fun readV1State(): ByteArray? =
            if (file.exists()) runCatching { file.readBytes() }.getOrNull() else null

        override fun readLegacyMaterial(): LegacyIdentityMaterial? = null
        override fun hasPartialLegacy(): Boolean = false

        override fun writeV1State(state: ByteArray): Boolean {
            file.parentFile?.mkdirs()
            return runCatching { file.writeBytes(state); file.exists() && file.readBytes().contentEquals(state) }
                .getOrDefault(false)
        }

        override fun migrateLegacyToV1(state: ByteArray): Boolean = writeV1State(state)

        override fun clear(): Boolean = runCatching { !file.exists() || file.delete() }.getOrDefault(false)
    }

    private fun hex(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it) }

    // ================================================================================================
    // the child process plumbing (the MeshHarness forked pattern's own launch recipe)
    // ================================================================================================

    /**
     * *** A CHILD, ITS TRANSCRIPT DRAINED AND FILED, AND ITS EXIT WATCHED. *** *Bounded everywhere and fully drained
     * on close, so the tail is the WHOLE transcript rather than a race.*
     */
    private class Child(private val process: Process, private val log: File) {
        private val lines = LinkedBlockingQueue<String>()
        @Volatile private var drained = false

        private val reader = Thread {
            runCatching {
                process.inputStream.bufferedReader().useLines { seq ->
                    log.outputStream().bufferedWriter().use { writer ->
                        seq.forEach { line ->
                            // *JUnitCore printeth a progress dot before the first line the child writes -- strip ANY
                            // leading progress decoration so the marker is matched on its CONTENT, not its offset.*
                            val normalized = line.trimStart('.', 'E')
                            lines.put(normalized)
                            writer.write(line); writer.newLine(); writer.flush()
                        }
                    }
                }
            }
            drained = true
        }.also { it.isDaemon = true; it.start() }

        fun isAlive(): Boolean = process.isAlive

        fun exitIfFinished(): String = if (process.isAlive) "running" else "exit=${process.exitValue()}"

        fun await(prefix: String, timeoutMillis: Long): String? {
            val deadline = System.nanoTime() + timeoutMillis * 1_000_000L
            while (System.nanoTime() < deadline) {
                val line = lines.poll(100, TimeUnit.MILLISECONDS)
                if (line != null && line.startsWith(prefix)) return line
                if (!process.isAlive && drained && lines.isEmpty()) return null
            }
            return null
        }

        fun awaitExit(): Int {
            if (!process.waitFor(30_000L, TimeUnit.MILLISECONDS)) {
                process.destroyForcibly()
                throw AssertionError("the child never exited within its bound")
            }
            return process.exitValue()
        }

        fun terminate() { if (process.isAlive) process.destroyForcibly() }

        fun close() { runCatching { process.inputStream.close() }; reader.join(30_000L) }

        fun tail(max: Int = 80): String = log.readLines().takeLast(max).joinToString("\n")
    }

    private fun launchChild(
        java: String,
        classpath: String,
        log: File,
        props: Map<String, String>,
    ): Child {
        val argv = ArrayList<String>()
        argv += java
        argv += inheritedJvmOptions()
        argv += props.map { (key, value) -> "-D$key=$value" }
        argv += "-cp"
        argv += classpath
        argv += JUnitCore::class.java.name
        argv += WipeCampaignWorkerTest::class.java.name
        val builder = ProcessBuilder(argv)
        // *THE CHILD'S WORKING DIRECTORY IS THE PARENT'S, so a relative path any owner resolves landeth the same way.*
        builder.directory(File(System.getProperty("user.dir")!!))
        builder.redirectErrorStream(true)
        return Child(builder.start(), log)
    }

    /** *Whatever the enclosing JVM was given, the child is given too (minus worker-specific properties).* */
    private fun inheritedJvmOptions(): List<String> = runCatching {
        val factory = Class.forName("java.lang.management.ManagementFactory")
        val bean = factory.getMethod("getRuntimeMXBean").invoke(null)
        val raw = bean.javaClass.getMethod("getInputArguments").invoke(bean)
        (raw as? List<*>)?.filterIsInstance<String>() ?: emptyList()
    }.getOrDefault(emptyList()).filter { option ->
        option.startsWith("--add-opens=") || option.startsWith("--add-exports=") ||
            option.startsWith("--add-modules=") || option.startsWith("--enable-")
    }

    /**
     * *** THE CHILD RUNS ON THE SAME TEST RUNTIME CLASSPATH THE PARENT IS RUNNING ON. *** *Two sources, deliberately:
     * the test class loader's own URLs (under Gradle that is the worker's `URLClassLoader`, carrying the whole test
     * runtime classpath), and only when that yieldeth too little, the JVM's own `java.class.path` expanded.*
     */
    private fun childClasspath(): String {
        val entries = LinkedHashSet<String>()
        runCatching {
            var loader: ClassLoader? = javaClass.classLoader
            while (loader != null) {
                if (loader is java.net.URLClassLoader) {
                    loader.urLs.forEach { url ->
                        if (url.protocol == "file") {
                            runCatching { File(url.toURI()).absolutePath }.getOrNull()?.let { entries.add(it) }
                        }
                    }
                }
                loader = loader.parent
            }
        }
        if (entries.size < 5) {
            for (part in (System.getProperty("java.class.path") ?: "").split(File.pathSeparator)) {
                if (part.isNotBlank()) entries.add(part)
            }
        }
        return entries.filter { File(it).exists() }.joinToString(File.pathSeparator)
    }
}
