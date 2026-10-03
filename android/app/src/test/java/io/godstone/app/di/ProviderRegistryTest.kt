package io.godstone.app.di

import androidx.sqlite.SQLiteConnection
import androidx.sqlite.driver.bundled.BundledSQLiteDriver
import io.godstone.core.archive.ArchiveBridge
import io.godstone.core.archive.ArchiveDocument
import io.godstone.core.archive.ArchiveDrivers
import io.godstone.core.archive.ArchivePassage
import io.godstone.core.archive.ArchiveReader
import io.godstone.core.archive.ArchiveRepository
import io.godstone.core.archive.ArchiveSourceMetadata
import io.godstone.core.archive.ArchiveState
import java.io.File
import java.security.MessageDigest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test

/*
 * ============================================================================
 * GS-ARCHIVE-010 (step 10 `provider-dispatch`) -- the provider table court.
 *
 * WHAT THIS COURT PROVES, AND WHAT IT DELIBERATELY DOES NOT.
 *
 * THE CHANGE UNDER TEST: the app's dispatch is a REAL TABLE LOOKUP over the runtime request (the tier and the
 * archive asset), with the app's ORIGINAL construction preserved as the FALLBACK that runs for real when the lookup
 * cannot answer; and the error paths around the resolution validate WHAT THE PROVIDERS ACTUALLY RETURN rather than
 * what their declarations claim.
 *
 * THE INJECTED PROVIDERS ARE REAL `ArchiveRepository` INSTANCES OVER REAL TEMPORARY ARCHIVE FILES -- a fake bridge
 * over the SAME frozen DDL the core courts execute -- driven by THE SAME `BundledSQLiteDriver` THE LIGHT APK
 * INSTALLS OUT OF BAND. **Nothing here is a mock of the reader**: a mocked reader could only prove that the
 * dispatcher calls a lambda, which is the "a provider's body cannot be measured by a court that passes its own
 * lambda" defect this programme already paid for once.
 *
 * THE LIMIT, NAMED HONESTLY: the PRODUCTION rows (`TierAssetArchiveProvider`/`PlatformArchiveProvider`) build a
 * `ArchiveRepository` from an Android `Context`, so their `open` needs the framework -- this court exercises their
 * MATCHING law (which is the routing decision the cutover introduces) and the dispatcher over injected rows, while
 * the production context road is compiled and wired by `AppModule` (its `@Provides` returns the registry's checked
 * concrete repository). No framework logger is touched: `ProviderDiagnostics` writes to `System.err` by default and
 * a sink is installed to read the faults.
 * ============================================================================
 */

private const val LEDGER_ASSET: String = "archive_light.db"
private const val LEDGER_TIER: String = "LIGHT"

private fun ledgerSha256(bytes: ByteArray): String =
    MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { b -> "%02x".format(b.toInt() and 0xFF) }

private fun ledgerRoot(prefix: String): File =
    File("/tmp/" + prefix + "-" + System.nanoTime()).also { it.mkdirs(); it.deleteOnExit() }

private fun SQLiteConnection.speak(sql: String) {
    prepare(sql).use { it.step() }
}

/** Execute a multi-statement SQL script, splitting on semicolons that stand outside literals and comments. */
private fun ledgerSpeakScript(conn: SQLiteConnection, script: String) {
    val buf = StringBuilder()
    var i = 0
    while (i < script.length) {
        val c = script[i]
        when {
            c == '\'' -> {
                buf.append(c); i++
                while (i < script.length) {
                    val d = script[i]; buf.append(d); i++
                    if (d == '\'') {
                        if (i < script.length && script[i] == '\'') { buf.append(script[i]); i++ } else break
                    }
                }
            }
            c == '-' && i + 1 < script.length && script[i + 1] == '-' -> {
                while (i < script.length && script[i] != '\n') { buf.append(script[i]); i++ }
            }
            c == '/' && i + 1 < script.length && script[i + 1] == '*' -> {
                buf.append(c).append(script[i + 1]); i += 2
                while (i + 1 < script.length && !(script[i] == '*' && script[i + 1] == '/')) {
                    buf.append(script[i]); i++
                }
                if (i + 1 < script.length) { buf.append('*').append('/'); i += 2 }
            }
            c == ';' -> {
                val stmt = buf.toString().trim()
                if (stmt.isNotEmpty()) conn.speak(stmt)
                buf.clear(); i++
            }
            else -> { buf.append(c); i++ }
        }
    }
    val tail = buf.toString().trim()
    if (tail.isNotEmpty()) conn.speak(tail)
}

/** Build one real, probe-passing Archive (documents + chunks + FTS5 + archive_meta) from the frozen DDL. */
private fun ledgerBuildArchive(target: File) {
    var probe: File? = File(System.getProperty("user.dir") ?: ".").absoluteFile
    var repoRoot: File? = null
    while (probe != null) {
        if (File(probe, "content/db/schema.sql").isFile) { repoRoot = probe; break }
        probe = probe.parentFile
    }
    val root = repoRoot ?: error("the court could not find content/db/schema.sql from " +
        (System.getProperty("user.dir") ?: "."))
    val schema = File(root, "content/db/schema.sql").readText()
    val indexes = File(root, "content/db/indexes.sql").readText()
    val conn = BundledSQLiteDriver().open(target.absolutePath)
    try {
        ledgerSpeakScript(conn, schema)
        conn.prepare(
            "INSERT INTO documents(document_id,title,domain,source_id,licence,revision,is_critical) " +
                "VALUES(?,?,?,?,?,?,?)"
        ).use { st ->
            st.bindLong(1, 7L); st.bindText(2, "Archive guide"); st.bindText(3, "reference")
            st.bindText(4, "src-001"); st.bindText(5, "CC0-BY"); st.bindText(6, "r7"); st.bindLong(7, 0L)
            st.step()
        }
        conn.prepare(
            "INSERT INTO chunks(chunk_id,document_id,ordinal,section,text,token_count) VALUES(?,?,?,?,?,?)"
        ).use { st ->
            st.bindLong(1, 11L); st.bindLong(2, 7L); st.bindLong(3, 1L)
            st.bindText(4, "Search"); st.bindText(5, "Read the full guide."); st.bindLong(6, 4L); st.step()
        }
        conn.prepare(
            "INSERT INTO chunks(chunk_id,document_id,ordinal,section,text,token_count) VALUES(?,?,?,?,?,?)"
        ).use { st ->
            st.bindLong(1, 12L); st.bindLong(2, 7L); st.bindLong(3, 2L)
            st.bindText(4, "Search"); st.bindText(5, "Remaining context."); st.bindLong(6, 2L); st.step()
        }
        conn.prepare("INSERT INTO archive_meta(key,value) VALUES(?,?)").use { st ->
            st.bindText(1, "schema_version"); st.bindText(2, "3"); st.step()
        }
        ledgerSpeakScript(conn, indexes)
    } finally {
        conn.close()
    }
}

/** A real `ArchiveBridge` over a real file and a real manifest; the repository is never mocked. */
private class FixtureBridge(
    private val root: File,
    private val asset: String,
    private val tier: String,
    private val bytes: ByteArray?,
) : ArchiveBridge {
    override fun assetBytes(name: String): ByteArray? = when (name) {
        asset -> bytes
        "$asset.manifest" -> bytes?.let { b ->
            ("{\"archive_bytes\":${b.size},\"archive_file\":\"$asset\",\"archive_schema\":3," +
                "\"archive_sha256\":\"${ledgerSha256(b)}\",\"schema\":1,\"tier\":\"$tier\"}")
                .toByteArray()
        }
        else -> null
    }

    override fun cacheRoot(): File = root
}

/** One real repository, with its probe verdict observable. */
private class RealFixture(val reader: ArchiveRepository, val digest: String)

private fun realFixture(prefix: String, asset: String = LEDGER_ASSET, tier: String = LEDGER_TIER): RealFixture {
    val root = ledgerRoot(prefix)
    val db = File(root, "source.db")
    ledgerBuildArchive(db)
    val bytes = db.readBytes()
    val repo = ArchiveRepository(
        FixtureBridge(ledgerRoot("$prefix-cache"), asset, tier, bytes),
        archiveAsset = asset, expectedAsset = asset, expectedTier = tier,
    )
    return RealFixture(repo, ledgerSha256(bytes))
}

/**
 * A table row over a REAL repository. *The lambdas are named explicitly at every call site rather than trailing,
 * so "which lambda is the predicate" is never decided by position.*
 */
private class RealRow(
    override val name: String,
    private val reader: () -> ArchiveReader,
    private val serves: (ProviderRequest) -> Boolean,
) : ProviderTableEntry {
    override val role: ProviderRole = ProviderRole.ARCHIVE_READER
    var openCalls: Int = 0
        private set

    override fun matches(request: ProviderRequest): Boolean = serves(request)

    override fun open(request: ProviderRequest): ProviderOpen {
        openCalls++
        return ProviderOpen.Ready(reader())
    }
}

/** A row that always matches and always refuses honestly. */
private class RefusingRow(override val name: String) : ProviderTableEntry {
    override val role: ProviderRole = ProviderRole.ARCHIVE_READER
    var openCalls: Int = 0
        private set

    override fun matches(request: ProviderRequest): Boolean = true

    override fun open(request: ProviderRequest): ProviderOpen {
        openCalls++
        return ProviderOpen.Unavailable("no archive is installed for ${request.tier}")
    }
}

private fun request(
    tier: String = LEDGER_TIER,
    asset: String = LEDGER_ASSET,
    role: ProviderRole = ProviderRole.ARCHIVE_READER,
) = ProviderRequest(tier = tier, archiveAsset = asset, role = role)

class ProviderRegistryTest {

    private val faults = mutableListOf<String>()

    @Before
    fun installSink() {
        faults.clear()
        ProviderDiagnostics.setSinkForTesting { faults.add(it) }
    }

    @After
    fun restoreSink() {
        ProviderDiagnostics.setSinkForTesting(null)
    }

    private companion object {
        init {
            // The very driver class the LIGHT APK installs out of band.
            ArchiveDrivers.install { BundledSQLiteDriver() }
        }
    }

    // (1) THE TABLE REPLACES THE CONDITIONAL ROUTING -- AND THE ROW THAT ANSWERED IS NAMED.
    @Test
    fun testTheTableLookupReplacesTheConditionalRoutingAndNamesTheServingRow() {
        val fixture = realFixture("table-names")
        val row = RealRow("injected-archive", reader = { fixture.reader }, serves = { true })
        val registry = ProviderRegistry(
            table = mapOf(ProviderRole.ARCHIVE_READER to listOf(row)),
            fallbackProvider = { error("the fallback must NOT run when a row answers") },
        )
        val resolution = registry.resolve(request())
        assertTrue("a matching row must resolve", resolution is ProviderResolution.Resolved)
        val resolved = resolution as ProviderResolution.Resolved
        assertEquals("the serving row must be named", "injected-archive", resolved.entry)
        assertSame("the row's OWN reader must be the one returned", fixture.reader, resolved.reader)
        assertEquals("the row was asked exactly once", 1, row.openCalls)
        assertTrue("no fault may be logged on the clean road", faults.isEmpty())
    }

    // (2) THE ROW DECIDES, NOT THE CALL SITE: two disjoint rows route two requests to their own provider.
    @Test
    fun testTheRowDecidesWhichProviderServesRatherThanTheCallSite() {
        val light = realFixture("route-light")
        val medium = realFixture("route-medium", asset = "archive_medium.db", tier = "MEDIUM")
        val lightRow = RealRow("light-row", reader = { light.reader }, serves = { it.tier == "LIGHT" })
        val mediumRow = RealRow("medium-row", reader = { medium.reader }, serves = { it.tier == "MEDIUM" })
        val registry = ProviderRegistry(
            table = mapOf(ProviderRole.ARCHIVE_READER to listOf(lightRow, mediumRow)),
            fallbackProvider = { error("a matching row must answer; the fallback must not run") },
        )
        val a = registry.resolve(request("LIGHT", LEDGER_ASSET)) as ProviderResolution.Resolved
        val b = registry.resolve(request("MEDIUM", "archive_medium.db")) as ProviderResolution.Resolved
        assertEquals("the LIGHT request must be served by its own row", "light-row", a.entry)
        assertEquals("the MEDIUM request must be served by its own row", "medium-row", b.entry)
        assertSame("each request must carry its own provider", light.reader, a.reader)
        assertSame("each request must carry its own provider", medium.reader, b.reader)
        assertEquals("the LIGHT row was asked exactly once", 1, lightRow.openCalls)
        assertEquals("the MEDIUM row was asked exactly once", 1, mediumRow.openCalls)
    }

    // (3) AN UNKNOWN TIER/ASSET PAIR IS NEVER SILENTLY SERVED BY A NON-MATCHING ROW -- IT FALLS TO THE APP'S ROAD.
    @Test
    fun testAnUnknownRuntimePairFallsToTheRealFallbackAndOpensNoMismatchedRow() {
        val fixture = realFixture("unknown-pair")
        val row = RealRow("only-row", reader = { error("must not open") }, serves = { false })
        val registry = ProviderRegistry(
            table = mapOf(ProviderRole.ARCHIVE_READER to listOf(row)),
            fallbackProvider = { fixture.reader },   // the app's OWN road -- must run for real
        )
        val resolution = registry.resolve(request("MEDIUM", "archive_light.db"))
        assertTrue("an unmatched runtime pair must fall to the fallback",
            resolution is ProviderResolution.Fallback)
        val fallback = resolution as ProviderResolution.Fallback
        assertSame("the fallback's OWN real reader must be returned", fixture.reader, fallback.reader)
        assertTrue("the primary cause must NAME the runtime pair, got: ${fallback.cause}",
            fallback.cause.contains("MEDIUM") && fallback.cause.contains("archive_light.db"))
        assertEquals("a non-matching row must NEVER be opened", 0, row.openCalls)
        assertTrue("the lookup failure must be logged", faults.any { it.contains("no registered") })
        assertTrue("the served fallback must be logged too",
            faults.any { it.contains("FALLBACK provider answered") })
    }

    // (4) THE FALLBACK PROVIDER RUNS FOR REAL WHEN THE LOOKUP FAILS -- ON THE REAL RUNTIME VALUES.
    @Test
    fun testTheFallbackProviderRunsForRealWhenEveryRowRefuses() {
        val fixture = realFixture("fallback-runs")
        var sawRequest: ProviderRequest? = null
        val refusing = RefusingRow("refusing-row")
        val resolution = ProviderRegistry(
            table = mapOf(ProviderRole.ARCHIVE_READER to listOf(refusing)),
            fallbackProvider = { req -> sawRequest = req; fixture.reader },
        ).resolve(request())
        assertTrue("a running fallback must be told apart from a chosen row",
            resolution is ProviderResolution.Fallback)
        val fallback = resolution as ProviderResolution.Fallback
        assertEquals("the fallback must be named", ProviderRegistry.FALLBACK_ENTRY_NAME, fallback.entry)
        assertSame("the fallback's OWN reader must be returned", fixture.reader, fallback.reader)
        assertTrue("the primary cause must travel with the fallback", fallback.cause.contains("refusing-row"))
        assertTrue("the fallback reader must be the REAL one, and its ACTUAL verdict must be Ready",
            fallback.reader.status() is ArchiveState.Ready)
        assertEquals("the fallback must receive the SAME runtime request (asset)",
            LEDGER_ASSET, sawRequest?.archiveAsset)
        assertEquals("the fallback must receive the SAME runtime request (tier)",
            LEDGER_TIER, sawRequest?.tier)
        assertEquals("the refused row was asked exactly once", 1, refusing.openCalls)
        assertTrue("the refused row must be logged: $faults",
            faults.any { it.contains("refusing-row") && it.contains("refused") })
    }

    // (5) A THROWING PROVIDER IS CAUGHT, LOGGED, AND THE NEXT ROW RUNS.
    @Test
    fun testAProviderThatThrowsIsCaughtLoggedAndTheNextRowRuns() {
        val fixture = realFixture("throw-next")
        val thrower = object : ProviderTableEntry {
            override val role: ProviderRole = ProviderRole.ARCHIVE_READER
            override val name: String = "exploding-row"
            override fun matches(request: ProviderRequest) = true
            override fun open(request: ProviderRequest): ProviderOpen =
                throw IllegalStateException("the platform refused to open the store")
        }
        val good = RealRow("good-row", reader = { fixture.reader }, serves = { true })
        val registry = ProviderRegistry(
            table = mapOf(ProviderRole.ARCHIVE_READER to listOf(thrower, good)),
            fallbackProvider = { error("the second row must answer; no fallback") },
        )
        val resolution = registry.resolve(request())
        assertTrue(resolution is ProviderResolution.Resolved)
        assertEquals("the surviving row must be the one named", "good-row",
            (resolution as ProviderResolution.Resolved).entry)
        assertSame(fixture.reader, resolution.reader)
        assertEquals("the good row ran exactly once", 1, good.openCalls)
        assertTrue("the caught throw must be LOGGED with its row and type: $faults",
            faults.any { f -> f.contains("exploding-row") && f.contains("IllegalStateException") &&
                f.contains("the platform refused to open the store") })
    }

    // (6) A FALLING TABLE LOOKUP IS CAUGHT *BEFORE* THE PROVIDERS AND FALLS THROUGH TO THE FALLBACK.
    @Test
    fun testAFallingTableLookupIsCaughtBeforeAnyProviderAndFallsToTheFallback() {
        val fixture = realFixture("lookup-fault")
        val explodingTable = object : Map<ProviderRole, List<ProviderTableEntry>> {
            override val entries get() = throw IllegalStateException("the table cannot be read")
            override val keys get() = throw IllegalStateException("the table cannot be read")
            override val size get() = throw IllegalStateException("the table cannot be read")
            override val values get() = throw IllegalStateException("the table cannot be read")
            override fun containsKey(key: ProviderRole) = false
            override fun containsValue(value: List<ProviderTableEntry>) = false
            override fun isEmpty() = false
            override fun get(key: ProviderRole): List<ProviderTableEntry> =
                throw IllegalStateException("the role cannot be read from the table")
        }
        var fallbackRan = false
        val registry = ProviderRegistry(explodingTable) { fallbackRan = true; fixture.reader }
        val resolution = registry.resolve(request())
        assertTrue("a falling lookup must fall to the fallback, not fabricate a refusal",
            resolution is ProviderResolution.Fallback)
        val fallback = resolution as ProviderResolution.Fallback
        assertTrue("the lookup fault must be named, got: ${fallback.cause}",
            fallback.cause.contains("the role cannot be read from the table"))
        assertSame("the fallback must answer on the real request", fixture.reader, fallback.reader)
        assertTrue("the fallback must have run for real", fallbackRan)
        assertTrue("the lookup fault must be logged",
            faults.any { it.contains("table lookup faulted") })
    }

    // (7) A FALLBACK THAT ITSELF THROWS IS UNAVAILABLE, CARRYING BOTH THROWS.
    @Test
    fun testAFallbackThrowIsUnavailableCarryingBothThrows() {
        val registry = ProviderRegistry(
            table = mapOf(ProviderRole.ARCHIVE_READER to listOf(RefusingRow("refusing-row"))),
            fallbackProvider = { throw IllegalStateException("the original road is also broken") },
        )
        val resolution = registry.resolve(request())
        assertTrue(resolution is ProviderResolution.Unavailable)
        val reason = (resolution as ProviderResolution.Unavailable).reason
        assertTrue("the fallback throw must be named, got: $reason",
            reason.contains("the original road is also broken"))
        assertTrue("the primary row cause must travel too, got: $reason", reason.contains("refusing-row"))
        assertTrue("the double failure must be logged", faults.any { it.contains("the FALLBACK provider threw") })
    }

    // (8) THE DIRECT LOOKUP IS *NOT* TRUSTED FOR ITS TYPE -- THE ACTUAL VERDICT OF THE RUNNING READER IS WHAT COUNTS.
    @Test
    fun testTheResolutionCarriesTheReadersActualVerdictNotItsClaimedType() {
        // a real repository whose archive is genuinely NOT installed (no manifest), so status() is Unavailable
        // even though the row answered `ProviderOpen.Ready`.
        val repo = ArchiveRepository(
            FixtureBridge(ledgerRoot("not-installed"), LEDGER_ASSET, LEDGER_TIER, bytes = null),
            archiveAsset = LEDGER_ASSET, expectedAsset = LEDGER_ASSET, expectedTier = LEDGER_TIER,
        )
        val registry = ProviderRegistry(
            table = mapOf(ProviderRole.ARCHIVE_READER to listOf(
                RealRow("empty-row", reader = { repo }, serves = { true }))),
            fallbackProvider = { error("no fallback") },
        )
        val resolved = registry.resolve(request()) as ProviderResolution.Resolved
        assertSame(repo, resolved.reader)
        assertFalse("the dispatcher must carry the ACTUAL verdict, never fabricate availability",
            resolved.reader.status() is ArchiveState.Ready)
        val verdict = resolved.reader.status()
        assertTrue("the actual verdict names the manifest, got: $verdict",
            verdict is ArchiveState.Unavailable && verdict.reason.contains("manifest"))
    }

    // (9) THE RESOLVED PROVIDER RUNS THE REAL READ ROAD OVER REAL BYTES.
    @Test
    fun testTheResolvedProviderRunsTheRealReadRoadOverRealBytes() {
        val fixture = realFixture("real-road")
        val row = RealRow("real-row", reader = { fixture.reader }, serves = { true })
        val registry = ProviderRegistry(
            table = mapOf(ProviderRole.ARCHIVE_READER to listOf(row)),
            fallbackProvider = { error("no fallback") },
        )
        val reader = registry.resolvedRepository(request())
        assertSame("the checked concrete repository must be the row's own object", fixture.reader, reader)
        val state = reader.status()
        assertTrue("the real repository must be Ready", state is ArchiveState.Ready)
        assertEquals("the Ready verdict must carry the digest of the REAL bytes",
            fixture.digest, (state as ArchiveState.Ready).sha256)
        val docs: List<ArchiveDocument> = reader.listDocuments()
        assertEquals("the real read road must return the seeded document", 1, docs.size)
        assertEquals("the seeded title must travel", "Archive guide", docs[0].title)
        assertTrue("the real FTS5 search must answer", reader.search("guide").isNotEmpty())
        val passages: List<ArchivePassage> = reader.passages(7L)
        assertEquals("the real passage road must answer both chunks", 2, passages.size)
        val provenance: ArchiveSourceMetadata? = reader.sourceMetadata(7L)
        assertEquals("the real provenance road must answer the citation", "src-001", provenance?.sourceId)
    }

    // (10) THE CONCRETE-TYPE CHECK RUNS AGAINST THE LIVE OBJECT, NOT THE DECLARATION.
    @Test
    fun testTheConcreteRepositoryCheckRefusesARepositoryShapedNonRepository() {
        val impostor = object : ArchiveReader {
            override fun listDocuments(domain: String?): List<ArchiveDocument> = emptyList()
            override fun listDomains(): List<String> = emptyList()
            override fun passages(documentId: Long): List<ArchivePassage> = emptyList()
            override fun search(query: String, limit: Int): List<ArchivePassage> = emptyList()
            override fun sourceMetadata(documentId: Long): ArchiveSourceMetadata? = null
        }
        val registry = ProviderRegistry(
            table = mapOf(ProviderRole.ARCHIVE_READER to listOf(object : ProviderTableEntry {
                override val role: ProviderRole = ProviderRole.ARCHIVE_READER
                override val name: String = "impostor-row"
                override fun matches(request: ProviderRequest) = true
                override fun open(request: ProviderRequest) = ProviderOpen.Ready(impostor)
            })),
            fallbackProvider = { error("no fallback") },
        )
        try {
            registry.resolvedRepository(request())
            fail("a non-repository reader must not be handed to the concrete production graph")
        } catch (expected: IllegalStateException) {
            assertTrue("the refusal must name the ACTUAL class returned, got: ${expected.message}",
                expected.message!!.contains("not the") && expected.message!!.contains("Archive"))
        }
    }

    // (11) A LOOKUP THAT FALLS THROUGH AND A THROWING FALLBACK IS UNAVAILABLE AT THE CONCRETE ROAD, NAMING BOTH.
    @Test
    fun testTheConcreteRoadIsUnavailableWhenTheLookupFallsThroughAndTheFallbackThrows() {
        val registry = ProviderRegistry(
            table = mapOf(ProviderRole.ARCHIVE_READER to listOf(
                RealRow("row", reader = { error("must not open") }, serves = { false }))),
            fallbackProvider = { throw IllegalStateException("the app's own road is broken") },
        )
        try {
            registry.resolvedRepository(request())
            fail("a lookup that falls through to a throwing fallback must not yield a repository")
        } catch (expected: IllegalStateException) {
            val message = expected.message ?: ""
            assertTrue("the refusal must name the fallback throw, got: $message",
                message.contains("the app's own road is broken"))
            assertTrue("the refusal must also name the primary lookup cause, got: $message",
                message.contains("no registered"))
        }
    }

    // (13) PRE-LOOKUP VALIDATION: A MALFORMED REQUEST IS CAUGHT BEFORE ANY ROW, LOGGED, AND FUNNELS TO FALLBACK.
    @Test
    fun testAMalformedRequestIsRefusedBeforeAnyProviderIsAsked() {
        val fixture = realFixture("malformed")
        val row = RealRow("never-asked", reader = { error("must not open") }, serves = { true })
        fun registry() = ProviderRegistry(
            table = mapOf(ProviderRole.ARCHIVE_READER to listOf(row)),
            fallbackProvider = { fixture.reader },
        )

        val blankTier = registry().resolve(request(tier = "  "))
        assertTrue("a blank tier must fall to the fallback before any row is asked",
            blankTier is ProviderResolution.Fallback)
        assertTrue("the blank tier must be named, got: ${(blankTier as ProviderResolution.Fallback).cause}",
            blankTier.cause.contains("tier is blank"))

        val blankAsset = registry().resolve(request(asset = ""))
        assertTrue(blankAsset is ProviderResolution.Fallback)
        assertTrue("the blank asset must be named, got: ${(blankAsset as ProviderResolution.Fallback).cause}",
            blankAsset.cause.contains("asset is blank"))

        val pathAsset = registry().resolve(request(asset = "/etc/archive.db"))
        assertTrue(pathAsset is ProviderResolution.Fallback)
        assertTrue("a path-shaped asset must be named, got: ${(pathAsset as ProviderResolution.Fallback).cause}",
            pathAsset.cause.contains("names a path"))

        val nonDb = registry().resolve(request(asset = "archive.txt"))
        assertTrue(nonDb is ProviderResolution.Fallback)
        assertTrue("a non-.db asset must be named, got: ${(nonDb as ProviderResolution.Fallback).cause}",
            nonDb.cause.contains("not a database file"))

        assertEquals("NO row may be asked to open for a malformed request", 0, row.openCalls)
        assertTrue("each malformed request must be logged", faults.count { it.contains("falling through") } >= 4)
    }

    // (12) THE TABLE'S OWN ROUTING LAW, EXERCISED WITHOUT A CONTEXT (the production rows' matching decision).
    @Test
    fun testTheProductionTableRoutesByRuntimePairWithoutTouchingTheFramework() {
        val table = archiveProviderTable { error("the context must NOT be built to decide a match") }
        val rows = table[ProviderRole.ARCHIVE_READER]!!
        assertEquals("the role must carry the tier/asset row and the platform row", 2, rows.size)
        val tierRow = rows.first { it.name == "tier-asset-archive" }
        val platformRow = rows.first { it.name == "platform-archive" }

        assertTrue("the canonical pair must be served", tierRow.matches(request("LIGHT", LEDGER_ASSET)))
        assertTrue("every registered tier's CANONICAL pair must be served by the canonical row",
            tierRow.matches(request("MEDIUM", "archive_medium.db")))
        assertFalse("a MISMATCHED pair must NOT be served by the canonical row",
            tierRow.matches(request("LIGHT", "archive_medium.db")))

        assertTrue("a registered tier with a plain .db asset must be served by the platform row",
            platformRow.matches(request("MEDIUM", "archive_medium.db")))
        assertFalse("a non-.db asset must NOT be served", platformRow.matches(request("LIGHT", "notes.txt")))
        assertFalse("an unregistered tier must NOT be served",
            platformRow.matches(request("TINY", "archive_tiny.db")))
        assertFalse("a traversal-shaped asset must NOT be served",
            platformRow.matches(request("LIGHT", "../archive_light.db")))

        assertEquals("the canonical LIGHT asset must be the one config/tiers.json names",
            "archive_light.db", ArchiveProviderTable.TIER_ARCHIVE_ASSETS["LIGHT"])
        assertEquals("the canonical MEDIUM asset must be the one config/tiers.json names",
            "archive_medium.db", ArchiveProviderTable.TIER_ARCHIVE_ASSETS["MEDIUM"])
        assertEquals("the canonical LARGE asset must be the one config/tiers.json names",
            "archive_large.db", ArchiveProviderTable.TIER_ARCHIVE_ASSETS["LARGE"])
    }
}
