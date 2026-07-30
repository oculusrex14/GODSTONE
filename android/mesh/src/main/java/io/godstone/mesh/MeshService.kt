package io.godstone.mesh

import android.app.Notification
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.BatteryManager
import android.os.IBinder
import androidx.core.app.NotificationCompat
import io.godstone.mesh.transport.PowerState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Foreground service that keeps the mesh alive while the app is backgrounded.
 *
 * Constraint C4, battery is life: the service re-evaluates power state from the
 * battery level every minute and lowers the duty cycle accordingly. It never
 * pins the CPU and holds no wake lock outside an active SOS.
 */
class MeshService : Service() {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private lateinit var meshNode: MeshNode

    override fun onCreate() {
        super.onCreate()
        meshNode = MeshNodeHolder.get(applicationContext)
        startForeground(NOTIFICATION_ID, buildNotification(peers = 0, queued = 0))

        scope.launch {
            while (true) {
                meshNode.setPowerState(currentPowerState())
                delay(POWER_CHECK_INTERVAL_MS)
            }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        meshNode.start()
        return START_STICKY
    }

    override fun onDestroy() {
        meshNode.stop()
        scope.cancel()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun currentPowerState(): PowerState {
        if (meshNode.hasActiveSos()) return PowerState.SOS_ACTIVE

        val bm = getSystemService(BatteryManager::class.java)
        val level = bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)

        return when {
            level <= 15 -> PowerState.CRITICAL
            level <= 40 -> PowerState.POWER_SAVE
            else -> PowerState.NORMAL
        }
    }

    private fun buildNotification(peers: Int, queued: Int): Notification =
        NotificationCompat.Builder(this, CHANNEL_MESH)
            .setContentTitle("Godstone mesh active")
            .setContentText(peers.toString() + " nearby, " + queued + " carried")
            .setSmallIcon(R.drawable.ic_mesh)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()

    companion object {
        private const val NOTIFICATION_ID = 1001
        private const val CHANNEL_MESH = "godstone.mesh"
        private const val POWER_CHECK_INTERVAL_MS = 60_000L

        fun start(ctx: Context) {
            ctx.startForegroundService(Intent(ctx, MeshService::class.java))
        }
    }
}
