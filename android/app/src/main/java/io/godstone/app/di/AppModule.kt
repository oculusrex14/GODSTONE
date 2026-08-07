package io.godstone.app.di

import android.content.Context
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
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
    @Provides @Singleton
    fun provideArchiveRepository(@ApplicationContext ctx: Context): ArchiveRepository =
        ArchiveRepository(ctx, archiveAsset = BuildConfig.ARCHIVE_FILE)
}