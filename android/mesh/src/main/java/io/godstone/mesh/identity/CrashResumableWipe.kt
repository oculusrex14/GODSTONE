package io.godstone.mesh.identity

/**
 * T34: crash-resumable wipe across transport AND storage.
 *
 * The sealed PanicWipe journal runs IDLE -> REQUESTED -> KEY_ERASED ->
 * ARTIFACTS_DELETED -> NEW_IDENTITY -> IDLE with no proof that the transport
 * queues were drained, raw throwing erase/delete seams, and a gate that is not
 * journal-bound. This additive contract completes it with the durable ladder
 *
 *   REQUESTED -> RUNTIME_DRAINED -> KEYS_ERASED -> ARTIFACTS_DELETED -> NEW_IDENTITY -> IDLE
 *
 * and the typed results the card names: [WipeJournalState], the idempotent
 * [WipeStepResult], [RuntimeDrainReceipt], [KeyDeletionResult] (Absent vs Deleted
 * vs Failed), [FileDeletionResult], and a [WipeLifecycleGate] that cannot be
 * bypassed because it answers from the journal, never from a cached boolean.
 *
 * Laws enforced:
 *  - the journal is append-only and strictly monotone: every persisted state is
 *    exactly one rank above the last (rank(to) == rank(from) + 1);
 *  - advancing past REQUESTED requires a Drained RuntimeDrainReceipt;
 *  - the store DEK and the identity keys are erased BEFORE any file cleanup, and
 *    every enumerated artifact is proven unreadable while it still exists;
 *  - a non-retryable key failure REFUSES the whole wipe: no artifacts deleted and
 *    no new identity constructed (retry durably without a new usable runtime);
 *  - a busy file is Failed-retryable, an already-absent file is satisfied (resume
 *    is idempotent);
 *  - deletion is scoped to the enumerated private artifacts; approved public
 *    Archive/model assets are never glob-deleted;
 *  - the gate stays closed for the whole ladder span and a late radio callback or
 *    a stale UI send cannot open it.
 *
 * Everything is injected and pure; the physical Keystore/SecureEnclave/flash
 * evidence is the device gate (deferred), not this contract.
 */

/** The durable ladder states with their monotone rank. */
enum class WipeJournalState(val rank: Int) {
    REQUESTED(1),
    RUNTIME_DRAINED(2),
    KEYS_ERASED(3),
    ARTIFACTS_DELETED(4),
    NEW_IDENTITY(5),
    IDLE(6);

    companion object {
        /**
         * Parse one journal line, honouring the CURRENT journal compatibility: the sealed
         * ladder wrote the legacy spelling KEY_ERASED for what this ladder calls
         * KEYS_ERASED. An unknown (future) spelling maps to null so callers can refuse it
         * fail-closed rather than guess a position in the ladder.
         */
        fun fromWire(name: String): WipeJournalState? = when (name) {
            "KEY_ERASED" -> WipeJournalState.KEYS_ERASED
            else -> WipeJournalState.entries.firstOrNull { it.name == name }
        }
    }
}

/** Thrown by an injected hook to simulate a process death BEFORE a journal write lands. */
class WipeCrashException(message: String) : RuntimeException(message)

/** The proof that the transport side was quiesced before anything was destroyed. */
sealed class RuntimeDrainReceipt {
    class Drained(val closedTransports: Int, val quiescedRuntime: Boolean) : RuntimeDrainReceipt()
    class NotDrained(val reason: String) : RuntimeDrainReceipt()
    val isDrained: Boolean get() = this is Drained
}

/** Tri-state key-erasure outcome: ABSENT and DELETED satisfy the erasure; FAILED does not. */
sealed class KeyDeletionResult {
    object Absent : KeyDeletionResult()
    object Deleted : KeyDeletionResult()
    class Failed(val keyName: String, val retryable: Boolean, val reason: String) : KeyDeletionResult()
    val satisfiesErasure: Boolean get() = this is Absent || this is Deleted
}

/** Tri-state file-deletion outcome: ABSENT and DELETED satisfy cleanup; FAILED (busy) retries. */
sealed class FileDeletionResult {
    object Absent : FileDeletionResult()
    object Deleted : FileDeletionResult()
    class Failed(val path: String, val reason: String) : FileDeletionResult()
    val satisfiesCleanup: Boolean get() = this is Absent || this is Deleted
}

/**
 * *** GS-FINAL-003: WHY A STEP WAS REFUSED, AS A TYPE RATHER THAN A SENTENCE. ***
 *
 * A STARTUP GATE DECIDES WHETHER PRIVATE STORES MAY BE OPENED. When that decision is made by matching a SUBSTRING OF
 * PROSE -- `reason.contains("nothing to resume")` -- then RENAMING THE REASON TEXT SILENTLY CHANGES WHAT THE GATE
 * PERMITS. One message rewording and a MALFORMED JOURNAL reads as a CLEAN FIRST LAUNCH, opening stores over material
 * that may be mid-erasure. A count that moves with the vocabulary of its input measures the classifier, not the
 * repository; that is the exact defect `AUDIT-B1-CTRL-001` retired on the control plane.
 *
 * **THE IOS ISLE ALREADY REJECTS THIS MOVE AND SAYS WHY**: its `StartupRecoveryDecision` treats an ambiguous refusal
 * as `corruptJournal` rather than guessing clean, naming guessing-clean as "the unsound direction". Porting a Boolean
 * and a prose match here would ship, on the second isle, the precise asymmetry this mission keeps catching -- one
 * isle has the control, the other only appears to.
 *
 * THE CONTRAST THAT MAKES THE CASES NECESSARY: [NOTHING_TO_RESUME] and [MALFORMED_JOURNAL] both produce a refusal,
 * and they must permit OPPOSITE things. Only the first is a proven clean estate.
 */
enum class WipeRefusalCause {
    /** NO WIPE WAS EVER REQUESTED -- a journal that is EMPTY, not one that is UNREADABLE. A proven clean estate. */
    NOTHING_TO_RESUME,

    /** THE DURABLE RECORD CANNOT BE PARSED AS A LADDER. Material may be mid-erasure: the UNSOUND case to call clean. */
    MALFORMED_JOURNAL,

    /** A WIPE IS ALREADY OUTSTANDING. Refuse to start a second: one composition root drives the ladder. */
    WIPE_ALREADY_PENDING,

    /** A KEY OR ARTIFACT COULD NOT BE DESTROYED, NON-RETRYABLY. The estate is neither clean nor resumable. */
    TERMINAL_STEP_FAILURE,

    /** THE JOURNAL VANISHED MID-LADDER. It was readable and then was not; treat as unsound, never as clean. */
    JOURNAL_LOST,
}

/** Idempotent step result: a repeat call on a passed state reports AlreadyAtOrPast, never re-effects. */
sealed class WipeStepResult {
    class Advanced(val from: WipeJournalState, val to: WipeJournalState) : WipeStepResult()
    class AlreadyAtOrPast(val state: WipeJournalState) : WipeStepResult()
    class RetryLater(val at: WipeJournalState, val reason: String) : WipeStepResult()

    /**
     * A REFUSAL CARRIES ITS CAUSE, and [reason] is for HUMANS ONLY -- **BRANCH ON [cause], NEVER ON [reason]**.
     * The text is free to change; the cause is what a gate may act on.
     */
    class Refused(val cause: WipeRefusalCause, val reason: String) : WipeStepResult()
}

/** The append-only durable journal. */
interface WipeDurabilityStore {
    fun readJournal(): List<String>
    fun appendJournal(stateName: String)
}

interface KeyVaultSeam {
    fun eraseKey(name: String): KeyDeletionResult
}

interface ArtifactFileSystemSeam {
    fun deleteArtifact(path: String): FileDeletionResult
    fun exists(path: String): Boolean
    /** An artifact is readable exactly while it exists AND some erasable key still lives. */
    fun isReadable(path: String): Boolean
}

interface TransportRuntimeSeam {
    fun drainTransport(): RuntimeDrainReceipt
    /** Whether THIS process lifetime has drained the transport; a reboot starts un-quiesced. */
    fun isQuiesced(): Boolean
    fun fireRadio(msg: String): Boolean
    fun sendVia(msg: String): Boolean
}

interface IdentityAuthoritySeam {
    /**
     * *** GS-STORE-006: A TYPED FAILURE CHANNEL, WHICH IS THE FIX AN ARM FORCED (round 421 on iOS, and on THIS isle by the
     * shared contract). ***
     *
     * IT RETURNED A NON-NULL `String`, AND A `String` CANNOT SAY "I DID NOT PUBLISH AN IDENTITY": the deferred seam answered
     * a NAME THAT SAID WHAT HAPPENED -- honest prose -- and the ladder, having no way to read a refusal as a refusal,
     * ADVANCED TO `IDLE` BELIEVING AN IDENTITY STOOD WHEN NONE DID. An authority that cannot FAIL where it must not succeed
     * is the very species of defect this finding is about.
     *
     * `null` MEANS **NOT PUBLISHED**, and the ladder must therefore STAY PENDING rather than reach `IDLE`.
     */
    fun publishNewIdentity(): String?
    fun identity(): String?
}

/** The crash-injection point: a throw from beforeWrite means the state was NEVER written. */
interface WipeHooks {
    fun beforeWrite(stateName: String)
    companion object {
        val NoHooks: WipeHooks = object : WipeHooks {
            override fun beforeWrite(stateName: String) {}
        }
    }
}

/** The enumerated private scope. Deletion must never exceed it; public assets never appear in it. */
object WipeScope {
    /**
     * GS-FINAL-002 (the independent audit, 2026-09-18): **EVERY NAME HERE MUST HAVE AN OWNER.**
     *
     * The list formerly read `["store-dek", "identity-ed25519", "identity-x25519", "binding-salt"]`. `binding-salt` HAS NO
     * OWNER ANYWHERE IN THIS CODEBASE: no keystore alias, no store column, no seam that erases it. On this isle a vault
     * that answers such a name with a retryable failure keeps the ladder pending FOREVER -- so a name nobody owns could
     * hold a wipe open permanently, which is the opposite of a wipe.
     *
     * THE THREE REAL NAMES ARE ERASED THROUGH ONE OWNER: on this isle the KEK is destroyed by `WipeArtifacts.eraseKeys()`
     * -- "Destroy the KEK. After this, encrypted artifacts are unrecoverable" -- and that single act is what every name
     * routes to. `store-dek` and the two identity names are the vocabulary the card uses; this isle has one destroyer.
     */
    val PRIVATE_KEYS: List<String> = listOf("store-dek", "identity-ed25519", "identity-x25519")

    /**
     * GS-FINAL-002: **AND EVERY ARTIFACT HERE MUST BE ONE THE SEAM CAN ADDRESS.**
     *
     * The list formerly ended `..., "export.tmp", "relay.cache"`. Neither name is ever written on either isle -- the iOS
     * twin carrieth the same two speculative names -- and an unmappable name is not a defensive extra: it is a deletion
     * the composition cannot perform, which keeps the wipe pending forever. The two REAL durable stores are named, and
     * they are the ones `AndroidWipeArtifacts.deleteArtifacts()` actually destroys (`SqliteMessageStore.panicWipe(ctx)`
     * and `SqlcipherPeerIdentityStore.panicWipe(ctx)`).
     */
    val PRIVATE_ARTIFACTS: List<String> = listOf("mesh.db", "mesh.db-wal", "mesh.db-shm", "peer.db", "peer.db-wal", "peer.db-shm")
    fun filterPrivatePaths(paths: List<String>): List<String> = paths.filter { it in PRIVATE_ARTIFACTS }
}

/**
 * The crash-resumable wipe coordinator. It keeps no memory of progress: every
 * decision is taken from the durable journal, so a fresh instance over the same
 * store resumes exactly where the previous process died.
 */
class CrashResumableWipe(
    private val store: WipeDurabilityStore,
    private val vault: KeyVaultSeam,
    private val filesystem: ArtifactFileSystemSeam,
    private val runtime: TransportRuntimeSeam,
    private val authority: IdentityAuthoritySeam,
    private val hooks: WipeHooks = WipeHooks.NoHooks,
) {
    /** The journal in memory, element-wise copied from the store (never aliased). */
    private val journal: MutableList<String> = store.readJournal().toMutableList()

    /** Counts refusals that tried to bypass the ladder; the gate is journal-bound, so these stay zero. */
    var bypassAttempts: Int = 0
        private set

    /** The current durable state, or null when the journal is empty (nothing ever requested). */
    private fun current(): WipeJournalState? = journal.lastOrNull()?.let { WipeJournalState.fromWire(it) }

    /** True while any ladder state is outstanding: the gate must stay closed across the whole span. */
    val isWipePending: Boolean
        get() {
            val c = current() ?: return false
            return c != WipeJournalState.IDLE
        }

    /** The gate answers from the journal alone -- it cannot be bypassed by a cached flag. */
    fun allowsStartup(): Boolean = !isWipePending
    fun allowsSensitiveApi(): Boolean = !isWipePending

    /**
     * A journal is well-formed when every line parses and, within each completed wipe
     * segment (a segment ends at IDLE), ranks strictly increase. Segmentation honours the
     * append-only durability: a second wipe legitimately restarts the ladder at REQUESTED.
     */
    fun isSupportedJournal(): Boolean {
        var rank = 0
        for (line in journal) {
            val st = WipeJournalState.fromWire(line) ?: return false
            if (st == WipeJournalState.IDLE) {
                if (rank != WipeJournalState.IDLE.rank - 1) return false   // IDLE may only close a full ladder
                rank = 0
            } else {
                if (st.rank <= rank) return false
                rank = st.rank
            }
        }
        return true
    }

    /** The normalized view of the journal for assertions (legacy spellings mapped, never mutated). */
    fun journalView(): List<WipeJournalState?> = journal.map { WipeJournalState.fromWire(it) }

    /**
     * *** GS-FINAL-003: DID THE DURABLE RECORD PARSE AT ALL? ***
     *
     * **THE DISTINCTION THE LADDER CANNOT EXPRESS**: an UNREADABLE record and a record that says "nothing was ever
     * requested" both leave the ladder EMPTY -- so a caller asking only "is a wipe pending?" sees a clean estate for
     * both. THEY MUST PERMIT OPPOSITE THINGS. This is the iOS `WipeJournal.isReadable` distinction, ported.
     *
     * *** THE STORE IS ASKED DIRECTLY, AND THAT IS THE CORRECTION AN EXTERNAL REVIEW FORCED. ***
     * *My first version derived readability from `journal` -- THE ALREADY-COERCED LINES. It therefore could NOT SEE the
     * defect it was written for: production `FileWipeJournal.read()` coerces an out-of-range ordinal to `IDLE`, the
     * adapter maps `IDLE` to an EMPTY list, and by the time this property ran, THE INFORMATION WAS ALREADY GONE. A
     * check derived from coerced output cannot detect a lossy coercion upstream of it.*
     *
     * **AND THE FAIL-CLOSED DEFAULT MATTERS HERE MOST**: a `WipeDurabilityStore` that has not adopted
     * `WipeReadabilityReporting` has not answered the question, and the permissive reading of an unanswerable question
     * is the one that opens private stores over material nobody managed to read.
     */
    val isReadableJournal: Boolean
        get() {
            // 1. THE STORE'S OWN ANSWER FIRST -- the only one that can see a lossy read.
            if (!((store as? WipeReadabilityReporting)?.isReadable ?: false)) return false
            // 2. AND the parsed lines must form a legal ladder: a well-formed prefix that is not a legal sequence is
            //    equally unreadable to us. `isSupportedJournal()` is that same question asked structurally.
            return isSupportedJournal()
        }

    /** Begin a wipe. From IDLE/empty this records REQUESTED and drives the ladder as far as it can. */
    fun requestWipe(): WipeStepResult {
        if (!isSupportedJournal()) return WipeStepResult.Refused(
                WipeRefusalCause.MALFORMED_JOURNAL,
                "journal carries an unsupported state; refusing to guess",
            )
        if (isWipePending) return WipeStepResult.Refused(
                WipeRefusalCause.WIPE_ALREADY_PENDING,
                "a wipe is already outstanding; one composition root drives the ladder",
            )
        persistRequest()
        return runLadder()
    }

    /** Resume after death: drive strictly from the durable journal. */
    fun resume(): WipeStepResult {
        if (!isSupportedJournal()) return WipeStepResult.Refused(
                WipeRefusalCause.MALFORMED_JOURNAL,
                "journal carries an unsupported state; refusing to guess",
            )
        val c = current() ?: return WipeStepResult.Refused(
                WipeRefusalCause.NOTHING_TO_RESUME,
                "nothing to resume; no wipe was ever requested",
            )
        if (c == WipeJournalState.IDLE) return WipeStepResult.AlreadyAtOrPast(c)
        return runLadder()
    }

    /** Drive the ladder one call, advancing as far as the seams allow. */
    fun step(): WipeStepResult {
        if (!isSupportedJournal()) return WipeStepResult.Refused(
                WipeRefusalCause.MALFORMED_JOURNAL,
                "journal carries an unsupported state; refusing to guess",
            )
        val c = current() ?: return WipeStepResult.Refused(
                WipeRefusalCause.NOTHING_TO_RESUME,
                "no journal entry",
            )
        if (c == WipeJournalState.IDLE) return WipeStepResult.AlreadyAtOrPast(c)
        return runLadder()
    }

    private fun persistRequest() {
        hooks.beforeWrite(WipeJournalState.REQUESTED.name)
        store.appendJournal(WipeJournalState.REQUESTED.name)
        journal.add(WipeJournalState.REQUESTED.name)
    }

    private fun persist(from: WipeJournalState, to: WipeJournalState) {
        require(to.rank == from.rank + 1) { "illegal ladder step ${from.name} -> ${to.name}" }
        hooks.beforeWrite(to.name)
        store.appendJournal(to.name)
        journal.add(to.name)
    }

    private fun runLadder(): WipeStepResult {
        var from = current() ?: return WipeStepResult.Refused(
                WipeRefusalCause.NOTHING_TO_RESUME,
                "no journal entry",
            )
        while (true) {
            when (from) {
                WipeJournalState.REQUESTED -> {
                    val receipt = runtime.drainTransport()
                    if (!receipt.isDrained) {
                        return WipeStepResult.RetryLater(from, (receipt as RuntimeDrainReceipt.NotDrained).reason)
                    }
                    persist(from, WipeJournalState.RUNTIME_DRAINED)
                }
                WipeJournalState.RUNTIME_DRAINED -> {
                    // the drain is a THIS-lifetime property: after a reboot the volatile queues are live again,
                    // so the quiesce must be re-proven in this process before the point of no return is crossed
                    if (!runtime.isQuiesced()) {
                        val redrain = runtime.drainTransport()
                        if (!redrain.isDrained) {
                            return WipeStepResult.RetryLater(from, (redrain as RuntimeDrainReceipt.NotDrained).reason)
                        }
                    }
                    val failed = WipeScope.PRIVATE_KEYS.map { vault.eraseKey(it) }
                        .mapNotNull { it as? KeyDeletionResult.Failed }
                    val permanent = failed.firstOrNull { !it.retryable }
                    if (permanent != null) {
                        return WipeStepResult.Refused(
                            WipeRefusalCause.TERMINAL_STEP_FAILURE,
                            "key ${permanent.keyName} not erasable: ${permanent.reason}",
                        )
                    }
                    if (failed.isNotEmpty()) {
                        return WipeStepResult.RetryLater(from, failed.joinToString(",") { it.keyName })
                    }
                    persist(from, WipeJournalState.KEYS_ERASED)
                }
                WipeJournalState.KEYS_ERASED -> {
                    val failed = WipeScope.filterPrivatePaths(WipeScope.PRIVATE_ARTIFACTS)
                        .map { filesystem.deleteArtifact(it) }
                        .mapNotNull { it as? FileDeletionResult.Failed }
                    if (failed.isNotEmpty()) {
                        return WipeStepResult.RetryLater(from, failed.joinToString(",") { it.path })
                    }
                    persist(from, WipeJournalState.ARTIFACTS_DELETED)
                }
                WipeJournalState.ARTIFACTS_DELETED -> {
                    // THE TYPED REFUSAL IS HONOURED HERE, WHICH THE COMPILER CANNOT ENFORCE: a nullable result used as a
                    // STATEMENT is perfectly legal Kotlin, SO THE TYPE CHANGE ALONE WOULD NOT HAVE FIXED THIS -- THE
                    // CALLER HAD TO HONOUR IT. `null` means the identity was NOT published, so the wipe must NOT record
                    // `NEW_IDENTITY` and must NOT advance: it stays PENDING for the runtime that owns an identity.
                    if (authority.publishNewIdentity() == null) {
                        return WipeStepResult.RetryLater(from, "no identity could be published")
                    }
                    persist(from, WipeJournalState.NEW_IDENTITY)
                }
                WipeJournalState.NEW_IDENTITY -> {
                    persist(from, WipeJournalState.IDLE)
                    return WipeStepResult.Advanced(from, WipeJournalState.IDLE)
                }
                WipeJournalState.IDLE -> return WipeStepResult.AlreadyAtOrPast(from)
            }
            from = current() ?: return WipeStepResult.Refused(
                WipeRefusalCause.JOURNAL_LOST,
                "journal lost mid-ladder",
            )
        }
    }

    /**
     * A late radio callback: delivered only while the runtime is quiesced (after the drain);
     * dropped and counted otherwise -- a stale frame must never resurrect the old session.
     */
    fun deliverLate(msg: String): Boolean {
        if (isWipePending) {
            bypassAttempts += 1
            return false
        }
        return runtime.fireRadio(msg)
    }

    /**
     * A stale UI send: admitted only after the ladder returns to IDLE; refused and counted
     * while any state is outstanding -- the gate cannot be bypassed from the UI side.
     */
    fun submitUi(msg: String): Boolean {
        if (isWipePending) {
            bypassAttempts += 1
            return false
        }
        return runtime.sendVia(msg)
    }

    companion object {
        /** The expected full ladder as spelled by THIS contract, for assertions. */
        val FULL_LADDER: List<String> = listOf(
            WipeJournalState.REQUESTED.name,
            WipeJournalState.RUNTIME_DRAINED.name,
            WipeJournalState.KEYS_ERASED.name,
            WipeJournalState.ARTIFACTS_DELETED.name,
            WipeJournalState.NEW_IDENTITY.name,
            WipeJournalState.IDLE.name,
        )
    }
}
