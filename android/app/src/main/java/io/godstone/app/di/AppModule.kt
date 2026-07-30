package io.godstone.app.di

import android.content.Context
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import io.godstone.app.BuildConfig
import io.godstone.llm.ModelManager
import io.godstone.llm.rag.RagPipeline
import io.godstone.llm.rag.Retriever
import io.godstone.mesh.MeshNode
import io.godstone.mesh.store.MessageStore
import io.godstone.mesh.store.SqliteMessageStore
import javax.inject.Singleton

@Module
@InstallIn(SingletonComponent::class)
object AppModule {

    @Provides
    @Singleton
    fun provideMessageStore(@ApplicationContext ctx: Context): MessageStore =
        SqliteMessageStore(ctx, maxBytes = 200L * 1024 * 1024)

    @Provides
    @Singleton
    fun provideMeshNode(
        @ApplicationContext ctx: Context,
        store: MessageStore
    ): MeshNode = MeshNode(ctx, store)

    @Provides
    @Singleton
    fun provideModelManager(@ApplicationContext ctx: Context): ModelManager =
        ModelManager(
            context = ctx,
            modelAsset = BuildConfig.MODEL_FILE,
            contextTokens = BuildConfig.CTX_TOKENS
        )

    @Provides
    @Singleton
    fun provideRetriever(@ApplicationContext ctx: Context): Retriever =
        Retriever(ctx, archiveAsset = BuildConfig.ARCHIVE_FILE)

    @Provides
    @Singleton
    fun provideRagPipeline(
        models: ModelManager,
        retriever: Retriever
    ): RagPipeline = RagPipeline(
        models = models,
        retriever = retriever,
        topK = BuildConfig.TOP_K_CHUNKS
    )
}
