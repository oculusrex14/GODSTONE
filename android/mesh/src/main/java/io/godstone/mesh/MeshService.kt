package io.godstone.mesh

import android.app.Notification
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.BatteryManager
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import dagger.hilt.android.AndroidEntryPoint
import io.godstone.mesh.transport.PowerState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * Foreground service that keeps the mesh alive while the app is backgrounded.
 *
 * V4 (audit P0-02): the node is now INJECTED, not fetched from a holder that
 * built its own. `MeshNodeHolder` is deleted. This service and the UI now
 * observe the same peer set, the same sessions and the same active-SOS flag.
 *
 * V4 also stops this service crashing on first launch. On Android 14+ a
 * foreground service typed `connectedDevice` requires BLUETOOTH_CONNECT to be
 * GRANTED at the moment `startForeground` is called. Nothing in the app requests
 * runtime permissions (P0-14), so V3 would throw SecurityException on a fresh
 * install on any modern device -- before any of the mesh defects could even be
 * reached. The service now refuses to start rather than crash, and reports why.
 *
 * Constraint C4: power state is re-evaluated from the battery every minute.
 */
@AndroidEntryPoint
class MeshService : Service() {

    @Inject lateinit var meshNode: MeshNode

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private var started = false

    override fun onCreate() {
        super.onCreate()
        if (!MeshNode.LINK_LAYER_READY) {
            android.util.Log.w(TAG, "mesh service refused: M1-wire/M2-link not implemented")
            stopSelf()
            return
        }
        if (!hasRequiredPermissions()) {
            // Fail visibly and stop. Starting a connectedDevice FGS without
            // BLUETOOTH_CONNECT is an immediate SecurityException on API 34+.
            android.util.Log.w(TAG, "mesh service refused: BLUETOOTH_CONNECT not granted")
            stopSelf()
            return
        }
        startForeground(NOTIFICATION_ID, buildNotification(peers = 0, queued = 0))
        scope.launch {
            while (true) {
                meshNode.setPowerState(currentPowerState())
                delay(POWER_CHECK_INTERVAL_MS)
            }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (!MeshNode.LINK_LAYER_READY || !hasRequiredPermissions()) {
            stopSelf()
            return START_NOT_STICKY
        }
        // START_STICKY redelivers onStartCommand after a process kill, so this
        // must be idempotent. MeshNode.start() is guarded as well.
        if (!started) {
            started = true
            meshNode.start()
        }
        return START_STICKY
    }

    override fun onDestroy() {
        meshNode.stop()
        started = false
        scope.cancel()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    /**
     * BLUETOOTH_CONNECT is runtime-granted from API 31 and is required for the
     * connectedDevice foreground-service type from API 34.
     */
    private fun hasRequiredPermissions(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        return ContextCompat.checkSelfPermission(
            this, android.Manifest.permission.BLUETOOTH_CONNECT
        ) == PackageManager.PERMISSION_GRANTED
    }

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

    // ADR-005 OPEN: this notification is still built once and never updated, so
    // it reports 0 peers forever. Wiring it needs the single mesh StateFlow that
    // ADR-005 specifies; a second ad-hoc state source is what produced P0-02.
    private fun buildNotification(peers: Int, queued: Int): Notification =
        NotificationCompat.Builder(this, CHANNEL_MESH)
            .setContentTitle("Godstone mesh active")
            .setContentText("$peers nearby, $queued carried")
            .setSmallIcon(R.drawable.ic_mesh)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()

    companion object {
        private const val TAG = "MeshService"
        private const val NOTIFICATION_ID = 1001
        private const val CHANNEL_MESH = "godstone.mesh"
        private const val POWER_CHECK_INTERVAL_MS = 60_000L

        fun start(ctx: Context) {
            ctx.startForegroundService(Intent(ctx, MeshService::class.java))
        }
    }
}
