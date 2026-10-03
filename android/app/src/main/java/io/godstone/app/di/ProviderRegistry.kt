package io.godstone.app.di

import android.content.Context
import io.godstone.core.archive.ArchiveReader
import io.godstone.core.archive.ArchiveRepository

// ============================================================================================
// GS-ARCHIVE-010 (step 10 `provider-dispatch`): THE PROVIDER TABLE, IN PLACE OF CONDITIONAL ROUTING.
//
// *** THE DEFECT THIS FILE CLOSES, MEASURED AT SOURCE RATHER THAN REASONED ABOUT. ***
//
// BEFORE THIS FILE, THE APP HAD EXACTLY ONE PROVIDER AND EXACTLY ONE CONSTRUCTION SITE: `AppModule`
// returned `ArchiveRepository(ctx, BuildConfig.ARCHIVE_FILE)` -- the runtime asset name INTERPOLATED as an
// argument, the tier left to a default, and NO table at all. *The composition answered "which provider
// serves this build" by the SHAPE OF THE CALL IT HAPPENED TO MAKE rather than by a lookup: an
// if/else-in-disguise.* That is the same class of defect the iOS isle's `SQLiteFunctionTable` closed for
// function pointers -- a handle resolved by a global symbol instead of by the table that owns it -- and the
// audit's own word for the app-side shape is `provider-dispatch`.
//
// *** SO THE DISPATCH IS NOW A REAL TABLE LOOKUP OVER THE RUNTIME REQUEST. ***
//
// * `ProviderRequest` carrieth THE ACTUAL RUNTIME VALUES the app already holds -- the tier and the archive
//   asset from `BuildConfig` -- and each `ProviderTableEntry` ANSWEReth `matches(request)` itself. No call
//   site decides by an `if (tier == "LIGHT")`-shaped conditional; the row decides, and the table is the
//   one place a new provider is added.
// * The FIRST matching entry that opens `Ready` WINS, and the resolution NAMES the row that answered, so
//   "which provider served this" is an observable fact rather than an inference about the call graph.
//
// *** AND THE FALLBACK IS THE APP'S OWN ROAD, PRESERVED RATHER THAN REPLACED. ***
//
// THE LOOKUP MAY HONESTLY FAIL -- no row matches, every matching row refuses, or a row throws while opening
// the platform's own archive. **The fallback provider is the ORIGINAL construction the app used before this
// table existed** (`ArchiveRepository(context, archiveAsset)`), and it now runs FOR REAL when the direct
// lookup cannot answer -- not as styling, and not only for a type. Its resolution is `Fallback`, carrieth
// the PRIMARY cause, and is DISTINGUISHABLE from a clean `Resolved` by type, so a caller can tell "the
// table chose this" from "the table could not, and the old road answered".
//
// *** THE TYPES, HOWEVER, ARE OFTEN ALREADY WHAT THE RUNTIME IS NOT. ***
//
// THE SECOND HALF OF THE DISPATCH DEFECT: the values that arrive at a provider are DECLARED types -- a tier
// string, an asset name, a resolved `ArchiveReader` -- and a declared type is NOT evidence about what the
// platform will actually return. **So THIS FILE TRUSTS THE RUNTIME VALUES AND VALIDATES WHAT THE PROVIDER
// ACTUALLY RETURNED, rather than assuming the declaration held:**
//   * a request whose tier/asset pair matches NO row is NEVER served by a row that did not match: the lookup
//     failure is LOGGED and funnels to the app's own fallback, so a mis-provisioned build is not bricked;
//   * an entry that THROWS while opening is caught, named and LOGGED, and the next row is tried -- the
//     exception never escapes as a fabricated `Unavailable`;
//   * a TABLE LOOKUP that itself fails (an unreadable/absent role) is caught BEFORE the providers, LOGGED, and
//     falls through to the fallback -- an honest "the table could not be consulted", distinct from "the
//     archive is not there";
//   * the fallback's own throw is caught and answered `Unavailable` CARRYING BOTH THROWS.
//
// AND WHEN A CALLER NEEDS THE CONCRETE PRODUCTION TYPE (`ArchiveRepository`, which a Dagger `@Inject`
// constructor consumes), `resolvedRepository()` RE-CHECKS THE ACTUAL CLASS the provider returned and throws
// a named fault when it is not that -- a runtime check on the real object, never a cast that assumes the
// declaration.
//
// *** KEPT DELIBERATELY SMALL. *** The provider implementations (`ArchiveRepository`, `ArchiveDrivers`,
// `ArchiveInstaller`) are correct and UNTOUCHED: the change is WHAT THE APP CALLS, not how they construct.
// The fallback chain is PRESERVED because that fallback is the app's own working logic -- transforming it
// would break what already answers on a device.
// ============================================================================================

/** The role a provider fills. A single member today, so a second role is a compile-visible addition. */
enum class ProviderRole {
    /** Serves the read face of the on-device Archive. */
    ARCHIVE_READER,
}

/**
 * *** THE RUNTIME REQUEST: THE REAL VALUES THE APP HOLDS, NOT A GUESS ABOUT THEM. ***
 *
 * *[tier] and [archiveAsset] come from `BuildConfig` (`TIER` / `ARCHIVE_FILE`) -- the same two values the
 * pre-table composition interpolated into its one construction. The table is keyed on these FACTS rather
 * than on an `if`.*
 */
data class ProviderRequest(
    val tier: String,
    val archiveAsset: String,
    val role: ProviderRole = ProviderRole.ARCHIVE_READER,
)

/** What a provider answereth when asked to open. A typed value, never a nullable handle. */
sealed class ProviderOpen {
    /** The provider opened and returns a reader. */
    data class Ready(val reader: ArchiveReader) : ProviderOpen()

    /**
     * The provider REFUSED, with its cause named. *This is a legitimate answer -- an archive that is not
     * installed on this device is Unavailable, not a crash -- so the dispatcher records it and moves on.*
     */
    data class Unavailable(val reason: String) : ProviderOpen()
}

/**
 * *** ONE ROW OF THE TABLE. *** *It decides whether it serves a request (`matches`) and, when asked, opens.*
 *
 * A row is an OBJECT rather than a function-pointer pair so that a provider's identity (`name`) travels
 * with its answer, which is what makes "which row served this" observable.
 */
interface ProviderTableEntry {
    val role: ProviderRole

    /** The row's own name, carried into every resolution so the served provider is never anonymous. */
    val name: String

    /** True when this row serves [request]. The ROW decides; the dispatcher does not. */
    fun matches(request: ProviderRequest): Boolean

    /** Open for [request]. May throw; the dispatcher catches, names and logs the throw. */
    fun open(request: ProviderRequest): ProviderOpen
}

/** The typed outcome of one dispatch. */
sealed class ProviderResolution {
    /** A table row answered. [entry] nameth it. */
    data class Resolved(val entry: String, val reader: ArchiveReader) : ProviderResolution()

    /**
     * No table row answered, so THE FALLBACK PROVIDER RAN and returned [reader]. *[cause] carrieth the
     * primary reason the direct lookup failed -- a table fault, an unregistered role, or the rows'
     * refusals/throws -- so a Fallback is never mistaken for a chosen row, and the flow can be traced.*
     */
    data class Fallback(val entry: String, val reader: ArchiveReader, val cause: String) : ProviderResolution()

    /**
     * The direct lookup failed AND the fallback provider could not answer either. [reason] carrieth BOTH
     * causes, so the one honest refusal names everything that was tried.
     */
    data class Unavailable(val reason: String) : ProviderResolution()
}

/**
 * *** WHERE THE REAL ERRORS GO, SO THE FLOW CAN BE TRACED. ***
 *
 * *The brief is explicit: "logs the real errors ... because you might add too many guards or fallbacks,
 * not the right ones". A guard whose fault is swallowed is indistinguishable from a guard that never ran.
 * So every caught fault in the dispatch is emitted HERE, with the role, the row (when one was reached) and
 * the exception's own type and message -- NOT the values, which may quote an archive path.*
 *
 * IT DOES NOT TOUCH `android.util.Log`: this type is reachable from a JVM unit court, where the framework
 * logger is unmocked and THROWS -- so a diagnostics seam that called it would fault the very path it was
 * meant to observe. The default sink is `System.err`, and a court installs its own sink to read the faults.
 */
object ProviderDiagnostics {
    @Volatile
    private var sink: (String) -> Unit = { message -> System.err.println("GODSTONE-PROVIDER: $message") }

    /** Install a court's sink; pass null to restore the default. */
    fun setSinkForTesting(next: ((String) -> Unit)?) {
        sink = next ?: { message -> System.err.println("GODSTONE-PROVIDER: $message") }
    }

    internal fun log(message: String) {
        runCatching { sink(message) }
    }
}

/**
 * *** THE DISPATCHER: A TABLE KEYED BY ROLE, AND THE APP'S OWN FALLBACK BENEATH IT. ***
 *
 * @param table the provider table -- a real `Map`, so a table that cannot be read is a fault the dispatcher
 *   must survive rather than a compile-time certainty.
 * @param fallbackProvider the ORIGINAL construction road, invoked only when the direct lookup cannot answer.
 *   It receives the SAME [ProviderRequest] the table was given, so the fallback runs on the real runtime
 *   values rather than on a re-derived guess.
 */
class ProviderRegistry(
    private val table: Map<ProviderRole, List<ProviderTableEntry>>,
    private val fallbackProvider: (ProviderRequest) -> ArchiveReader,
) {

    /**
     * Resolve [request] to a reader.
     *
     * THE LOOKUP, AND EVERY FAILURE OF IT FUNNELS TO THE FALLBACK -- WHICH IS THE WHOLE POINT OF KEEPING THE
     * APP'S OWN ROAD BENEATH THE TABLE ("a fallback for when the registry lookup itself fails ... for a smooth
     * transition without breaking existing integrations"). *A build whose runtime pair no row matches must NOT
     * be bricked at DI just because the table is newer than the device's provisioning; the failure is LOGGED so
     * it is not mistaken for a clean answer, and the original provider runs.*
     *
     *   1. consult the table for the role -- a throw here is recorded and the flow falls through to the fallback;
     *   2. no rows registered, or no row that MATCHES the runtime request, is recorded and falls through;
     *   3. each matching row in order: a `Ready` WINS; an `Unavailable` is recorded; a row that THROWS is caught,
     *      LOGGED and recorded, and the next row is tried;
     *   4. when no row answered -- for ANY of the reasons above -- the FALLBACK PROVIDER RUNS on the same real
     *      request. Its reader is a `Fallback` carrying the primary cause; if it also throws, the resolution is
     *      `Unavailable` carrying BOTH throws.
     *
     * *** THE CLOSED PROPERTY THE TABLE STILL OWNS: no mismatching row is EVER opened. *** *"Fall through to the
     * fallback" is not "open the first row anyway": [PlatformArchiveProvider]/[TierAssetArchiveProvider] each
     * decide their own match, and a row that says no is never asked to open.*
     */
    fun resolve(request: ProviderRequest): ProviderResolution {
        // *** THE PRE-LOOKUP ERRORS RUN FIRST, BECAUSE THAT IS WHERE VALIDATION BELONGS. ***
        // *A malformed request -- a blank tier, a blank asset, or an asset that names a path rather than a
        // shipped file name -- is caught BEFORE the table is consulted, LOGGED with its exact fault, and answered
        // through the same fallback funnel. Validating here rather than letting a malformed value reach a row
        // means the row never has to defend against a shape the wiring should have refused.*
        val invalid = validationFault(request)
        if (invalid != null) {
            ProviderDiagnostics.log("$invalid; falling through to the fallback")
            return fallback(request, invalid)
        }

        var cause: String
        val rows = try {
            table[request.role]
        } catch (fault: Throwable) {
            cause = "the provider table could not be consulted for ${request.role}: ${describe(fault)}"
            ProviderDiagnostics.log("table lookup faulted; falling through to the fallback: $cause")
            return fallback(request, cause)
        }
        if (rows == null) {
            cause = "no provider is registered for role ${request.role}"
            ProviderDiagnostics.log("$cause; falling through to the fallback")
            return fallback(request, cause)
        }
        if (rows.isEmpty()) {
            cause = "an empty provider list is registered for role ${request.role}"
            ProviderDiagnostics.log("$cause; falling through to the fallback")
            return fallback(request, cause)
        }
        val candidates = try {
            rows.filter { it.matches(request) }
        } catch (fault: Throwable) {
            cause = "a provider row faulted while matching ${request.role}: ${describe(fault)}"
            ProviderDiagnostics.log("$cause; falling through to the fallback")
            return fallback(request, cause)
        }
        if (candidates.isEmpty()) {
            // *** AN UNKNOWN PAIR IS NEVER SILENTLY SERVED BY A ROW THAT DID NOT MATCH -- IT FALLS TO THE
            // APP'S OWN ROAD, AND THE FAILURE IS LOGGED SO IT IS TRACED RATHER THAN SILENT. ***
            cause = "no registered ${request.role} provider matches the runtime request " +
                "(tier ${request.tier}, asset ${request.archiveAsset})"
            ProviderDiagnostics.log("$cause; falling through to the fallback")
            return fallback(request, cause)
        }

        cause = "every matching provider refused or faulted"
        for (row in candidates) {
            val opened = try {
                row.open(request)
            } catch (fault: Throwable) {
                // *** THE UNTYPED PROBLEMS COME AFTER THE DISPATCH, SO THEY ARE TRACED HERE. ***
                ProviderDiagnostics.log(
                    "provider '${row.name}' threw while opening (role ${request.role}): " +
                        describe(fault))
                cause = "'${row.name}' threw ${fault::class.java.simpleName}: ${messageOf(fault)}"
                continue
            }
            when (opened) {
                is ProviderOpen.Ready -> return ProviderResolution.Resolved(row.name, opened.reader)
                is ProviderOpen.Unavailable -> {
                    ProviderDiagnostics.log("provider '${row.name}' refused: ${opened.reason}")
                    cause = "'${row.name}': ${opened.reason}"
                }
            }
        }

        return fallback(request, cause)
    }

    /**
     * *** THE PRE-LOOKUP VALIDATION: WHAT MUST BE TRUE BEFORE ANY ROW IS ASKED. ***
     *
     * *Returns the fault's name, or null when the request is well formed. THE RULES ARE THE ARCHIVE CONTRACT'S
     * OWN: a tier names a real tier; an asset names a plain file (no path separator) ending in `.db`, because
     * the installer and the repository both refuse an absolute/directory path and a blank name.*
     */
    private fun validationFault(request: ProviderRequest): String? {
        if (request.tier.isBlank()) return "the runtime tier is blank"
        if (request.archiveAsset.isBlank()) return "the runtime archive asset is blank"
        if (request.archiveAsset.contains('/') || request.archiveAsset.contains('\\')) {
            return "the runtime archive asset names a path rather than a shipped file: " +
                request.archiveAsset
        }
        if (!request.archiveAsset.endsWith(".db")) {
            return "the runtime archive asset is not a database file: ${request.archiveAsset}"
        }
        return null
    }

    /**
     * *** THE APP'S OWN ROAD, RUN FOR REAL WHEN THE LOOKUP FAILED -- ON THE REAL RUNTIME REQUEST. ***
     *
     * *[cause] is logged with the fallback's own success OR throw, so a Fallback resolution is never a silent
     * substitution: an operator reading the trace sees WHICH lookup failure sent the app to its fallback.*
     */
    private fun fallback(request: ProviderRequest, cause: String): ProviderResolution {
        val reader = try {
            fallbackProvider(request)
        } catch (fault: Throwable) {
            ProviderDiagnostics.log(
                "the FALLBACK provider threw (role ${request.role}): ${describe(fault)}; " +
                    "primary cause: $cause")
            return ProviderResolution.Unavailable(
                "the direct lookup failed ($cause) and the fallback provider threw " +
                    "${fault::class.java.simpleName}: ${messageOf(fault)}")
        }
        ProviderDiagnostics.log(
            "the FALLBACK provider answered after a lookup failure: $cause")
        return ProviderResolution.Fallback(FALLBACK_ENTRY_NAME, reader, cause)
    }

    /**
     * *** THE RUNTIME CHECK ON THE ACTUAL OBJECT, FOR THE CONCRETE PRODUCTION TYPE. ***
     *
     * *A Dagger `@Inject` constructor consumes the concrete `ArchiveRepository`, so the graph must hand it
     * one. The reader the provider returned is CHECKED -- `is ArchiveRepository` on the live object -- rather
     * than assumed from the declaration, because a provider that returns some other conformer would
     * otherwise fail later as a `ClassCastException` at an unrelated call site. A resolution that carries no
     * reader throws with the resolution's own reason.*
     */
    fun resolvedRepository(request: ProviderRequest): ArchiveRepository {
        val reader = when (val resolution = resolve(request)) {
            is ProviderResolution.Resolved -> resolution.reader
            is ProviderResolution.Fallback -> resolution.reader
            is ProviderResolution.Unavailable -> throw IllegalStateException(
                "no Archive provider could be resolved: ${resolution.reason}")
        }
        return reader as? ArchiveRepository ?: throw IllegalStateException(
            "the resolved Archive provider returned a ${reader::class.java.name}, which is not the " +
                "repository-backed reader the production graph consumes")
    }

    companion object {
        /** The name every fallback resolution carrieth, so it is never anonymous. */
        const val FALLBACK_ENTRY_NAME: String = "fallback"

        /**
         * *** THE PRODUCTION TABLE, AND THE PRODUCTION FALLBACK -- THE SAME OBJECT `AppModule` BUILT BEFORE. ***
         *
         * *Both rows construct the REAL `ArchiveRepository` over the app's context; neither mocks, and the
         * fallback is byte-identical in behaviour to the pre-table `provideArchiveRepository` body. The
         * table exists so the app LOOKS UP which provider serves the runtime request instead of interpolating
         * the first provider it happens to know.*
         */
        fun production(context: Context): ProviderRegistry = ProviderRegistry(
            table = archiveProviderTable { context.applicationContext },
            fallbackProvider = { request ->
                ArchiveRepository(context, request.archiveAsset, expectedTier = request.tier)
            },
        )
    }
}

private fun messageOf(fault: Throwable): String = fault.message ?: "(no message)"

private fun describe(fault: Throwable): String =
    fault::class.java.name + ": " + messageOf(fault)

// ============================================================================================
// THE ARCHIVE PROVIDER TABLE -- THE FUNCTION TABLE THAT REPLACES THE CONDITIONAL ROUTING.
// ============================================================================================

/**
 * *** THE TIER -> ASSET TABLE, THE ONE CANONICAL SOURCE OF "WHICH FILE IS THIS BUILD'S ARCHIVE". ***
 *
 * *The values are the SAME three the repository already carrieth (`config/tiers.json` names
 * `archive_light.db` / `archive_medium.db` / `archive_large.db`; the Android flavour declares `LIGHT` and
 * `archive_light.db` in its `buildConfigField`s). The app now LOOKS UP the pair instead of interpolating
 * one of them at the construction site.*
 */
object ArchiveProviderTable {
    val TIER_ARCHIVE_ASSETS: Map<String, String> = mapOf(
        "LIGHT" to "archive_light.db",
        "MEDIUM" to "archive_medium.db",
        "LARGE" to "archive_large.db",
    )
}

/**
 * Build the table keyed by role. *[contextFactory] is a thunk so the table can be built before the app
 * context stands (and so a court can build a table over its own bridge instead).*
 *
 * THE ROWS, AND WHY THERE ARE TWO:
 *   * `tier-asset-archive` matches a request whose tier and asset AGREE with the canonical pair -- the
 *     shipped road, named so a resolution says which row it took;
 *   * `platform-archive` matches any registered tier requesting a plain archive asset -- the road a future
 *     tier or a lab composition takes, so the table is not a single hard-coded row pretending to be a
 *     lookup.
 */
fun archiveProviderTable(contextFactory: () -> Context): Map<ProviderRole, List<ProviderTableEntry>> = mapOf(
    ProviderRole.ARCHIVE_READER to listOf(
        TierAssetArchiveProvider(contextFactory),
        PlatformArchiveProvider(contextFactory),
    ),
)

/** The canonical pair for the request's tier: the shipped road. */
class TierAssetArchiveProvider(private val contextFactory: () -> Context) : ProviderTableEntry {
    override val role: ProviderRole = ProviderRole.ARCHIVE_READER
    override val name: String = "tier-asset-archive"

    override fun matches(request: ProviderRequest): Boolean =
        ArchiveProviderTable.TIER_ARCHIVE_ASSETS[request.tier] == request.archiveAsset

    override fun open(request: ProviderRequest): ProviderOpen =
        ProviderOpen.Ready(
            ArchiveRepository(contextFactory(), request.archiveAsset, expectedTier = request.tier))
}

/** Any registered tier requesting a plain (non-traversal) archive asset. */
class PlatformArchiveProvider(private val contextFactory: () -> Context) : ProviderTableEntry {
    override val role: ProviderRole = ProviderRole.ARCHIVE_READER
    override val name: String = "platform-archive"

    override fun matches(request: ProviderRequest): Boolean =
        request.tier in ArchiveProviderTable.TIER_ARCHIVE_ASSETS &&
            request.archiveAsset.isNotEmpty() &&
            !request.archiveAsset.contains('/') &&
            request.archiveAsset.endsWith(".db")

    override fun open(request: ProviderRequest): ProviderOpen =
        ProviderOpen.Ready(
            ArchiveRepository(contextFactory(), request.archiveAsset, expectedTier = request.tier))
}
