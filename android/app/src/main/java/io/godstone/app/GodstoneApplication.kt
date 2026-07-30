package io.godstone.app

import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager
import dagger.hilt.android.HiltAndroidApp
import javax.inject.Inject
import io.godstone.llm.ModelManager
import io.godstone.mesh.MeshNode

@HiltAndroidApp
class GodstoneApplication : Application() {

    @Inject lateinit var meshNode: MeshNode
    @Inject lateinit var modelManager: ModelManager

    override fun onCreate() {
        super.onCreate()
        createNotificationChannels()

        // Identity must exist before any radio starts. Cheap if already present.
        meshNode.ensureIdentity()

        // The model is NOT loaded here. It is loaded lazily when the Oracle is
        // opened and released when it is backgrounded, per constraint C4.
        modelManager.prepareWithoutLoading()
    }

    private fun createNotificationChannels() {
        val nm = getSystemService(NotificationManager::class.java)

        nm.createNotificationChannel(
            NotificationChannel(
                CHANNEL_MESH,
                getString(R.string.channel_mesh),
                NotificationManager.IMPORTANCE_LOW
            ).apply { description = getString(R.string.channel_mesh_desc) }
        )

        nm.createNotificationChannel(
            NotificationChannel(
                CHANNEL_SOS,
                getString(R.string.channel_sos),
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = getString(R.string.channel_sos_desc)
                enableVibration(true)
                setBypassDnd(true)
            }
        )
    }

    companion object {
        const val CHANNEL_MESH = "godstone.mesh"
        const val CHANNEL_SOS = "godstone.sos"
    }
}
