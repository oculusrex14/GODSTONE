// SYNTHESIZED gap-closure file -- authored to make the project compile; see docs/AUDIT.md.
package io.godstone.mesh

import android.content.Context
import io.godstone.mesh.store.SqliteMessageStore

/**
 * Process-wide holder for the singleton [MeshNode].
 *
 * The foreground service is created and destroyed by the system independently of
 * the Hilt-provided instance used by the app, so both reach the same node through
 * this holder rather than through separate constructions.
 */
object MeshNodeHolder {
    @Volatile
    private var instance: MeshNode? = null

    fun get(ctx: Context): MeshNode =
        instance ?: synchronized(this) {
            instance ?: MeshNode(
                ctx,
                SqliteMessageStore(ctx, 200L * 1024 * 1024)
            ).also { instance = it }
        }
}