package io.godstone.app.di

import android.content.Context
import androidx.sqlite.driver.bundled.BundledSQLiteDriver
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import android.os.UserManager
import dagger.hilt.components.SingletonComponent
import io.godstone.app.mesh.PlatformProtectedDataGate
import io.godstone.app.mesh.ProtectedDataGate
import io.godstone.app.BuildConfig
import io.godstone.core.archive.ArchiveRepository
import javax.inject.Singleton

/**
 * Archive-only shipping wiring. The LIGHT release links ONLY `:core`, so the
 * single injectable here is the Archive repository -- the survival-knowledge
 * path that works with no model and no radio. The on-device model / Oracle /
 * RAG graph (`ModelManager`, `Retriever`, `RagPipeline`, `OraclePipeline`) lives
 * in the NON-SHIPPING `:llm` module (Stage 3 Phase I); its ViewModel
 * (`OracleViewModel`) is compiled only in the test source set for the
 * state-machine safety tests, and the Oracle UI screen is dormant debt (see
 * `src/main/dormant/java/.../ui/oracle/`, excluded by the oracle UI exclude
 * glob in build.gradle.kts). No Mesh store or radio object is injectable.
 */
@Module
@InstallIn(SingletonComponent::class)
object AppModule {
    init {
        // T47 (s17): the Archive read path runseth on the PINNED AndroidX
        // bundled driver -- installed as a thunk so the native library loads
        // at first use, never at class-init of the wiring. There is no
        // silent fallback to the platform engine by design.
        io.godstone.core.archive.ArchiveDrivers.install {
            BundledSQLiteDriver()
        }
    }

    @Provides @Singleton
    fun provideArchiveRepository(@ApplicationContext ctx: Context): ArchiveRepository =
        ArchiveRepository(ctx, archiveAsset = BuildConfig.ARCHIVE_FILE)

    /**
     * *** GS-FINAL-009 (round 564): THE PRODUCTION ANSWER TO "MAY I READ PROTECTED DATA RIGHT NOW". ***
     *
     * BEFORE THIS PROVIDER THE ANSWER WAS A CONSTANT: every construction site was a TEST, so
     * `AlwaysAvailableProtectedData` (which returneth `true` unconditionally) was the only gate the shipping app
     * could ever see, and the platform was NEVER ASKED.
     *
     * THE PLATFORM FACT: this app's protected data live in credential-encrypted storage, WHICH IS READABLE ONLY AFTER
     * THE USER UNLOCKETH THE DEVICE FOR THE FIRST TIME. `UserManager.isUserUnlocked` is exactly that question. Before
     * first unlock -- Direct Boot, after a restart -- the answer is FALSE, and every protected read is refused at
     * admission rather than failing at the storage layer.
     */
    @Provides @Singleton
    fun provideProtectedDataGate(@ApplicationContext ctx: Context): ProtectedDataGate =
        PlatformProtectedDataGate {
            (ctx.getSystemService(Context.USER_SERVICE) as? UserManager)?.isUserUnlocked ?: false
        }
}