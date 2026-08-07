package io.godstone.app.di

import android.content.Context
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import io.godstone.app.BuildConfig
import io.godstone.llm.ModelManager
import io.godstone.llm.archive.ArchiveRepository
import io.godstone.llm.rag.Embedder
import io.godstone.llm.rag.OraclePipeline
import io.godstone.llm.rag.RagPipeline
import io.godstone.llm.rag.Retriever
import javax.inject.Singleton

/** Archive and test-only Oracle wiring. No Mesh store or radio object is injectable. */
@Module
@InstallIn(SingletonComponent::class)
object AppModule {
    @Provides @Singleton
    fun provideArchiveRepository(@ApplicationContext ctx: Context): ArchiveRepository =
        ArchiveRepository(ctx, archiveAsset = BuildConfig.ARCHIVE_FILE)

    @Provides @Singleton
    fun provideModelManager(@ApplicationContext ctx: Context): ModelManager =
        ModelManager(ctx, BuildConfig.MODEL_FILE, BuildConfig.CTX_TOKENS)

    @Provides @Singleton
    fun provideEmbedder(@ApplicationContext ctx: Context): Embedder? =
        BuildConfig.EMBED_MODEL_FILE.takeIf { it.isNotEmpty() }?.let {
            Embedder(ctx, it, BuildConfig.EMBED_DIM)
        }

    @Provides @Singleton
    fun provideRetriever(@ApplicationContext ctx: Context, embedder: Embedder?): Retriever =
        Retriever(ctx, archiveAsset = BuildConfig.ARCHIVE_FILE, embedder = embedder)

    @Provides @Singleton
    fun provideRagPipeline(models: ModelManager, retriever: Retriever): RagPipeline =
        RagPipeline(models, retriever, BuildConfig.TOP_K_CHUNKS)

    // OracleViewModel depends on the OraclePipeline seam, not the concrete
    // RagPipeline, so the state machine is testable with a fake. The production
    // binding is the llama.cpp-backed RagPipeline; tests bypass Hilt entirely.
    @Provides @Singleton
    fun provideOraclePipeline(impl: RagPipeline): OraclePipeline = impl
}
