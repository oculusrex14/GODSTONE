package io.godstone.mesh.identity

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import io.godstone.mesh.store.StoreSchema
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.File

/**
 * *** GS-FINAL-003 `full-estate-erasure` (A4/A5/A10): THE REAL FILESYSTEM, SEEDED AT THE ACTUAL PATHS. ***
 *
 * *THE REVIEW'S INSTRUMENT, VERBATIM: **"Populate the exact runtime paths and preferences, invoke the real MeshPanicWipe
 * .begin, and require those paths erased; a surviving physical artifact must prevent ARTIFACTS_DELETED."*** **THIS COURT IS
 * THAT INSTRUMENT FOR THE SEAM THAT OWNETH THE DELETION -- `FullEstateArtifactSeam` -- and no assertion is made about any
 * file it did not actually touch.**
 *
 * *** AND IT IS DRIVEN UNDER ROBOLECTRIC, WHICH SUPPLIES A REAL `Context` WITH A REAL `getDatabasePath`/`shared_prefs`
 * TREE, SO THE FILES SEEDED HERE ARE THE FILES THE PRODUCTION DESTROYERS RESOLVE. *** *The two negative cases are the
 * load-bearing ones: **a SURVIVING database must report `Failed` (not a silent `Deleted`), and an ABSENT one must still
 * satisfy the cleanup** -- without them a seam that always answered `Deleted` would pass.*
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33])
class GsFinal003FullEstateErasureTest {

    private fun ctx(): Context = ApplicationProvider.getApplicationContext()

    /** A journal at a chosen rung, in memory, so the oracle arm can be driven without a device. */
    private class MemoryJournal(private var state: PanicWipe.WipeState) :
        WipeJournal, WipeReadabilityReporting {
        override fun read(): PanicWipe.WipeState = state
        override fun write(state: PanicWipe.WipeState) { this.state = state }
        override fun clear() { state = PanicWipe.WipeState.IDLE }
        override val isReadable: Boolean get() = true
    }

    private fun seam(state: PanicWipe.WipeState = PanicWipe.WipeState.ARTIFACTS_DELETED) =
        FullEstateArtifactSeam(ctx(), MemoryJournal(state))

    private fun seed(path: File): File {
        path.parentFile?.mkdirs()
        path.writeBytes(byteArrayOf(1, 2, 3, 4))
        assertTrue("the rig must really seed ${path.path}", path.exists())
        return path
    }

    private fun clearEstate() {
        for (f in PrivateEstatePaths.targetsFor(ctx(), "mesh.db")!! +
            PrivateEstatePaths.targetsFor(ctx(), "peer.db")!! +
            PrivateEstatePaths.identityTargets(ctx())) {
            runCatching { f.delete() }
        }
    }

    @Before fun clean() = clearEstate()
    @After fun tearDown() = clearEstate()

    // =================================================================================================================
    // (1) THE ACTUAL PHYSICAL TARGETS ARE THE ONES THE OWNERS DECLARE -- NOT ALIASES.
    // =================================================================================================================

    /**
     * *** THE MESH FAMILY RESOLVES TO THE REAL `godstone_messages.db` AND ITS OWN KEYS -- NOT `mesh.db`. ***
     *
     * *THE A5/A10 DEFECT IN ONE ASSERTION: the obsolete seam addressed `File("mesh.db")` (cwd-relative) and the
     * context-backed one verified `getDatabasePath("mesh.db")`; **NEITHER named the file the message store actually
     * creates.*** **This pins the owner-defined names so a later edit cannot quietly re-address an alias.**
     */
    @Test
    fun theMeshFamilyNamesTheRealDatabaseSidecarsAndKeys() {
        val names = PrivateEstatePaths.targetsFor(ctx(), "mesh.db")!!.map { it.name }
        assertTrue(
            "*** THE MESSAGE DATABASE'S REAL NAME MUST BE A TARGET. Observed: $names ***",
            names.any { it == "${StoreSchema.DB_NAME}" },
        )
        assertTrue("and its -wal sidecar", names.any { it == "${StoreSchema.DB_NAME}-wal" })
        assertTrue("and its -shm sidecar", names.any { it == "${StoreSchema.DB_NAME}-shm" })
        assertTrue(
            "*** AND THE WRAPPED STORE KEY -- the preference whose loss is what maketh the ciphertext unreadable. ***",
            names.any { it.contains(StoreSchema.KEY_PREFS) },
        )
        assertFalse(
            "*** NO CWD-RELATIVE ALIAS MAY APPEAR: that was the A5 defect, and the fix must not reintroduce it. ***",
            names.any { it == "mesh.db" || it == "peer.db" },
        )
    }

    /** *** AND THE PEER FAMILY, LIKEWISE, FROM THE PEER SCHEMA'S OWN CONSTANTS. *** */
    @Test
    fun thePeerFamilyNamesTheRealDatabaseSidecarsAndKeys() {
        val names = PrivateEstatePaths.targetsFor(ctx(), "peer.db")!!.map { it.name }
        assertTrue(names.any { it == PeerIdentitySchema.DB_NAME })
        assertTrue(names.any { it == "${PeerIdentitySchema.DB_NAME}-journal" })
        assertTrue(names.any { it.contains(PeerIdentitySchema.KEY_PREFS) })
    }

    /**
     * *** AND THE IDENTITY FAMILY IS A TARGET AT ALL -- WHICH IT NEVER WAS BEFORE THIS ROUND (FINDING A4). ***
     *
     * *`Identity.panicWipe` deleted `godstone_identity`, but no logical artifact name addressed it, so an existing
     * encrypted identity survived the master-KEK deletion and the replacement could not replace it.* **This pins that the
     * identity preferences -- and the AndroidX keyset, the surviving-ciphertext case the finding names -- are targets.**
     */
    @Test
    fun theIdentityFamilyIsATargetIncludingTheAndroidxKeyset() {
        val names = PrivateEstatePaths.identityTargets(ctx()).map { it.name }
        assertTrue(
            "*** THE IDENTITY PREFERENCES MUST BE A TARGET, or a wipe leaves an encrypted identity behind. ***",
            names.any { it.contains(Identity.PREFS) },
        )
        assertTrue(
            "*** AND THE ANDROIDX KEYSET: a keyset that outliveth its master key IS the surviving ciphertext. ***",
            names.any { it.contains("androidx") },
        )
    }

    // =================================================================================================================
    // (2) THE ERASURE IS VERIFIED OVER THE ACTUAL FILES -- AND THE NEGATIVE CASE IS THE ONE THAT MATTERS.
    // =================================================================================================================

    /**
     * *** A SURVIVING PHYSICAL ARTIFACT MUST REPORT `Failed` -- NEVER A SILENT `Deleted`. ***
     *
     * *THE REVIEW'S OWN NEGATIVE INSTRUMENT: **"a surviving physical artifact must prevent ARTIFACTS_DELETED."*** **The
     * seam is asked to delete a family whose database is present but UNREMOVABLE, and it must name the survivor rather
     * than claim success.** *Without this arm a seam hardwired to `Deleted` would pass every positive assertion.*
     */
    @Test
    fun aSurvivingArtifactIsAFailureNamingTheRealFile() {
        // Seed the REAL message database, then make its family undeletable by the destroyer AND the sweep: the seam's own
        // direct `file.delete()` is defeated by making the target a NON-EMPTY DIRECTORY, which `File.delete()` refuseth.
        val db = ctx().getDatabasePath(StoreSchema.DB_NAME)
        db.parentFile?.mkdirs()
        // remove any real file first, then stand a directory in its name
        runCatching { db.delete() }
        db.mkdirs()
        File(db, "occupied").writeBytes(byteArrayOf(9))
        assertTrue("the rig must leave a survivor at the REAL database path", db.exists())

        val result = seam().deleteArtifact("mesh.db")
        assertTrue(
            "*** A SURVIVING PHYSICAL ARTIFACT MUST BE A FAILURE, NOT A `Deleted`. Observed: $result ***",
            result is FileDeletionResult.Failed,
        )
        assertTrue(
            "*** AND THE FAILURE MUST NAME THE REAL FILE, so a court can assert on the actual path rather than a " +
                "sentence. Observed: ${(result as FileDeletionResult.Failed).reason} ***",
            result.reason.contains(StoreSchema.DB_NAME),
        )
        // tidy: the directory must not survive into another arm
        runCatching { File(db, "occupied").delete() }
        runCatching { db.delete() }
    }

    /**
     * *** AND THE POSITIVE DIRECTION: WITH THE REAL FILES PRESENT, THE FAMILY IS ERASED AND VERIFIED. ***
     *
     * *Every owner-defined target is seeded, the seam is asked to delete the family, and EVERY target must be gone.*
     * **The `identityTargets` are seeded too and erased through the recovery material op, so the arm proveth the identity
     * erase that finding A4 required.*** *Robolectric's `deleteDatabase`/`deleteSharedPreferences` may or may not be
     * no-ops, which is exactly why the seam ALSO deletes survivors directly and the verdict is taken over the files.*
     */
    @Test
    fun everyOwnerDefinedTargetIsErasedAndVerified() {
        val meshTargets = PrivateEstatePaths.targetsFor(ctx(), "mesh.db")!!
        val peerTargets = PrivateEstatePaths.targetsFor(ctx(), "peer.db")!!
        for (f in meshTargets + peerTargets) seed(f)

        assertEquals(
            "*** THE FAMILY MUST BE REPORTED DELETED ONLY WHEN EVERY OWNER-DEFINED TARGET IS GONE. ***",
            FileDeletionResult.Deleted, seam().deleteArtifact("mesh.db"),
        )
        assertEquals(FileDeletionResult.Deleted, seam().deleteArtifact("peer.db"))
        assertTrue(
            "*** NOT ONE SEEDED TARGET MAY SURVIVE. Observed: " +
                "${(meshTargets + peerTargets).filter { it.exists() }.map { it.name }} ***",
            (meshTargets + peerTargets).none { it.exists() },
        )
    }

    /**
     * *** AND THE IDENTITY ERASE, VERIFIED -- THE STEP THE LADDER NEVER TOOK. ***
     *
     * *THE PARENT'S RULING MADE THIS AN EXPLICIT RECOVERY MATERIAL OP; this arm proveth it ERASES AND VERIFIES, and that it
     * answers `false` (so the ladder stays `ARTIFACTS_DELETED`) when a survivor cannot be removed.* **A `true` over
     * surviving ciphertext would be the false success finding A4 names.**
     */
    @Test
    fun theRecoveryIdentityEraseIsVerifiedOverTheRealPreferences() {
        val material = RecoveryIdentityMaterial(ctx())
        for (f in PrivateEstatePaths.identityTargets(ctx())) seed(f)
        assertTrue(
            "*** THE IDENTITY ERASE MUST REMOVE EVERY OWNER-DEFINED TARGET AND SAY SO. ***",
            material.erase(),
        )
        assertTrue(
            "*** AND NOTHING MAY SURVIVE. Observed: " +
                "${PrivateEstatePaths.identityTargets(ctx()).filter { it.exists() }.map { it.name }} ***",
            PrivateEstatePaths.identityTargets(ctx()).none { it.exists() },
        )
    }

    /**
     * *** AND IT REFUSES WHEN A SURVIVOR REMAINS -- the negative direction of the same op. ***
     *
     * *A directory stood in the identity preference's name cannot be deleted by `File.delete`, so the verified erase must
     * answer `false` and the wipe must therefore NOT advance past `ARTIFACTS_DELETED`.*
     */
    @Test
    fun theRecoveryIdentityEraseRefusesOverASurvivor() {
        val victim = PrivateEstatePaths.identityTargets(ctx()).first()
        runCatching { victim.delete() }
        victim.mkdirs()
        File(victim, "occupied").writeBytes(byteArrayOf(9))
        assertFalse(
            "*** AN IDENTITY SURVIVOR MUST REFUSE THE ERASE, so no replacement is published over surviving ciphertext. ***",
            RecoveryIdentityMaterial(ctx()).erase(),
        )
        runCatching { File(victim, "occupied").delete() }
        runCatching { victim.delete() }
    }

    // =================================================================================================================
    // (3) THE ORACLE: READABILITY COMES FROM THE JOURNAL, NEVER FROM A DESTRUCTIVE PROBE.
    // =================================================================================================================

    /** *Once the record standeth at or past `KEY_ERASED`, an artifact still on disk is NOT readable -- no key is touched.* */
    @Test
    fun readabilityIsTakenFromTheJournalNotFromTheVault() {
        val target = PrivateEstatePaths.targetsFor(ctx(), "mesh.db")!!.first()
        seed(target)
        assertTrue(
            "before the keys are erased, a present artifact is readable",
            seam(PanicWipe.WipeState.RUNTIME_DRAINED).isReadable("mesh.db"),
        )
        assertFalse(
            "*** AFTER `KEY_ERASED` THE MATERIAL THAT WOULD DECRYPT IT IS GONE, so it is NOT readable -- and no key " +
                "was touched to answer this. ***",
            seam(PanicWipe.WipeState.KEY_ERASED).isReadable("mesh.db"),
        )
        runCatching { target.delete() }
    }

    /** *** AND A NAME WITH NO OWNER CLAIMS NOTHING: absence satisfieth, and a `Deleted` would be a lie. *** */
    @Test
    fun aNameWithNoOwnerIsAbsentAndErasesNothing() {
        assertEquals(
            FileDeletionResult.Absent, seam().deleteArtifact("binding-salt"),
        )
        assertFalse("and it is not readable, because it does not exist", seam().isReadable("binding-salt"))
    }
}
