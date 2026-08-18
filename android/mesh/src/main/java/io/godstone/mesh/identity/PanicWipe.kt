package io.godstone.mesh.identity

import android.content.Context
import io.godstone.mesh.store.SqliteMessageStore
import java.security.KeyStore

/**
 * Coordinated, resumable, cryptographic-erasure panic wipe (ADR-004 criterion 5,
 * GST-WIPE-001).
 *
 * The wipe destroys long-lived secrets across the store + identity + the key
 * material that encrypts them, then regenerates a fresh identity so prior
 * traffic cannot be linked to the new node. It must be crash-safe: a process
 * kill, power loss or jetsam at any point must leave the device in a state from
 * which a restart finishes the wipe without leaking recoverable data and without
 * skipping a step.
 *
 * The construction is a small persisted state machine. The state is written to a
 * durable [WipeJournal] AFTER each step completes, and every step is idempotent,
 * so a crash-then-resume re-runs at most the one step that was interrupted and
 * then continues forward. The ordering is deliberate:
 *
 *   IDLE -> REQUESTED -> KEY_ERASED -> ARTIFACTS_DELETED -> NEW_IDENTITY -> IDLE
 *
 *   REQUESTED          -- wipe requested, nothing destroyed yet
 *   eraseKeys()        -- destroy the KEK (Android Keystore master key). After
 *                         this the data is cryptographically erased: the
 *                         EncryptedSharedPreferences ciphertexts for the identity
 *                         and the store key are undecryptable even if their
 *                         files still sit on disk. KEY_ERASED is the point of no
 *                         return.
 *   KEY_ERASED         -- KEK gone, ciphertext files still present but unreadable
 *   deleteArtifacts()  -- delete the now-useless ciphertext files (store DB, store
 *                         key prefs, identity prefs). Idempotent.
 *   ARTIFACTS_DELETED  -- no recoverable artifacts remain
 *   regenerateIdentity()-- create a fresh Keystore master key + fresh identity.
 *   NEW_IDENTITY       -- new identity in place
 *   clear()            -- drop the journal; the device is back to IDLE clean.
 *
 * Crypto-erasure-first is the safety property: even a total failure after
 * [WipeArtifacts.eraseKeys] cannot leave prior data recoverable, because the key
 * that decrypted it is gone. The remaining steps are cleanup + re-identity, and
 * the journal guarantees they eventually run.
 *
 * The state machine itself ([PanicWipe]) is pure Kotlin with no Android
 * dependency; the platform glue ([FileWipeJournal], [AndroidWipeArtifacts]) is
 * injected. The host unit tests in `PanicWipeTest` drive the machine with fakes
 * (simulating a crash before each step) and assert resumability + ordering +
 * the no-op-when-idle contract without a device. The production glue is thin
 * (Keystore entry delete + the existing `SqliteMessageStore.panicWipe` /
 * `Identity.panicWipe` / `Identity.loadOrCreate`); the actual Keystore + file
 * deletion is an on-device verification, not host-testable.
 */
class PanicWipe(
    private val journal: WipeJournal,
    private val artifacts: WipeArtifacts,
) {

    /** The persisted phase of an in-progress wipe. Ordered by the run() ladder. */
    enum class WipeState {
        IDLE,
        REQUESTED,
        KEY_ERASED,
        ARTIFACTS_DELETED,
        NEW_IDENTITY,
    }

    /**
     * Begin a wipe from a clean (IDLE) state. Writes REQUESTED, then advances as
     * far as it can. A crash at any point leaves the journal at the last
     * completed step; [resumeIfPending] on the next launch finishes it.
     */
    fun begin() {
        journal.write(WipeState.REQUESTED)
        run()
    }

    /**
     * If a wipe was in progress (journal != IDLE), finish it. Safe to call on
     * every app launch. No-op when no wipe is pending.
     */
    fun resumeIfPending() {
        if (journal.read() != WipeState.IDLE) run()
    }

    /**
     * Advance the machine from its persisted state to completion. Each rung
     * checks the persisted state, performs the step that rung owns, then
     * persists the next state -- so a crash between "perform" and "persist"
     * re-runs that one idempotent step on resume, and a crash after "persist"
     * skips it. The cascade falls through: a single call runs every remaining
     * rung unless a step throws (simulating a crash), in which case the journal
     * already reflects the last completed rung and the next resume continues.
     */
    private fun run() {
        var s = journal.read()
        if (s == WipeState.IDLE) { s = WipeState.REQUESTED; journal.write(s) }
        if (s == WipeState.REQUESTED) {
            artifacts.eraseKeys()
            s = WipeState.KEY_ERASED; journal.write(s)
        }
        if (s == WipeState.KEY_ERASED) {
            artifacts.deleteArtifacts()
            s = WipeState.ARTIFACTS_DELETED; journal.write(s)
        }
        if (s == WipeState.ARTIFACTS_DELETED) {
            artifacts.regenerateIdentity()
            s = WipeState.NEW_IDENTITY; journal.write(s)
        }
        if (s == WipeState.NEW_IDENTITY) {
            journal.clear()
        }
    }

    companion object {
        /** Production entry point: start a full wipe using platform glue. */
        fun begin(ctx: Context) {
            PanicWipe(FileWipeJournal(ctx), AndroidWipeArtifacts(ctx)).begin()
        }

        /** Call on app launch: finishes a wipe that a crash interrupted. */
        fun resumeIfPending(ctx: Context) {
            PanicWipe(FileWipeJournal(ctx), AndroidWipeArtifacts(ctx)).resumeIfPending()
        }
    }
}

/** Crash-safe marker for the wipe state machine. Implementations must persist. */
interface WipeJournal {
    fun read(): PanicWipe.WipeState
    fun write(state: PanicWipe.WipeState)
    fun clear()
}

/** The three idempotent destroy/rebuild steps, injectable for host tests. */
interface WipeArtifacts {
    /** Destroy the KEK. After this, encrypted artifacts are unrecoverable. */
    fun eraseKeys()
    /** Delete the ciphertext/DB/prefs files. Idempotent. */
    fun deleteArtifacts()
    /** Generate + store a fresh identity (and the KEK that protects it). */
    fun regenerateIdentity()
}

/**
 * Journal backed by a dedicated SharedPreferences file, committed synchronously
 * so the marker survives a crash. The journal file itself is not sensitive (it
 * holds only a state enum) and is left in place by the wipe -- a leftover IDLE
 * marker is harmless. A non-IDLE marker after a reboot is exactly the signal
 * [PanicWipe.resumeIfPending] acts on.
 */
internal class FileWipeJournal(ctx: Context) : WipeJournal {
    private val prefs = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    override fun read(): PanicWipe.WipeState {
        val ord = prefs.getInt(KEY, -1)
        return if (ord < 0 || ord >= PanicWipe.WipeState.entries.size) PanicWipe.WipeState.IDLE
        else PanicWipe.WipeState.entries[ord]
    }

    override fun write(state: PanicWipe.WipeState) {
        prefs.edit().putInt(KEY, state.ordinal).commit()
    }

    override fun clear() {
        prefs.edit().clear().commit()
    }

    private companion object {
        const val PREFS = "godstone_wipe_journal"
        const val KEY = "state"
    }
}

/**
 * Production [WipeArtifacts] for Android.
 *
 * `eraseKeys` deletes the AndroidX Security AndroidKeystore master key (the KEK
 * that [Identity] and the store key prefs are encrypted under). Deleting it is
 * the cryptographic-erasure step: every EncryptedSharedPreferences ciphertext
 * becomes undecryptable regardless of whether its file is later deleted.
 * `deleteArtifacts` reuses the existing, tested store + identity panic-wipe
 * methods (DB + store-key prefs + identity prefs). `regenerateIdentity` builds a
 * fresh master key + identity via [Identity.loadOrCreate], which creates new
 * EncryptedSharedPreferences since the old ones were deleted.
 *
 * Each step is idempotent: a Keystore `deleteEntry` on an absent alias is a
 * no-op, `deleteSharedPreferences`/`deleteDatabase` on absent files are no-ops,
 * and `loadOrCreate` creates when nothing exists.
 */
internal class AndroidWipeArtifacts(private val ctx: Context) : WipeArtifacts {

    override fun eraseKeys() {
        // Crypto erasure: destroy the KEK. All EncryptedSharedPreferences
        // ciphertexts (identity, store key) become permanently undecryptable.
        val ks = KeyStore.getInstance("AndroidKeyStore")
        ks.load(null)
        if (ks.containsAlias(MASTER_KEY_ALIAS)) {
            ks.deleteEntry(MASTER_KEY_ALIAS)
        }
        // A failure to delete the master key is a genuine wipe failure; the
        // machine will re-attempt eraseKeys on resume because KEY_ERASED was
        // not persisted (run() persists only after the call returns).
    }

    override fun deleteArtifacts() {
        // Reuse the existing, tested store + identity panic-wipe methods.
        SqliteMessageStore.panicWipe(ctx)   // store DB + store key prefs
        Identity.panicWipe(ctx)             // identity prefs
    }

    override fun regenerateIdentity() {
        // Fresh master key + fresh EncryptedSharedPreferences + fresh keys.
        // The returned identity is the new node identity; nothing to do with it
        // here -- the caller (app init) will loadOrCreate again when it needs it.
        Identity.loadOrCreate(ctx)
    }

    private companion object {
        // AndroidX Security MasterKey default alias. Deleting this entry
        // invalidates every EncryptedSharedPreferences file it encrypted.
        const val MASTER_KEY_ALIAS = "_androidx_security_master_key_"
    }
}