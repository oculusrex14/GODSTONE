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
import io.godstone.mesh.di.MeshGraphComponent
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
 * V4 (audit P0-02): the node is no longer fetched from a holder that built
 * its own. `MeshNodeHolder` is deleted. This service and the UI now observe the
 * same peer set, the same sessions and the same active-SOS flag.
 *
 * GS-FINAL-003 `android-provider-court` (round 2026-10-04): the node is resolved
 * from `MeshGraphComponent.production(...)` -- THE COMPONENT THE COURTS CONSTRUCT
 * -- rather than by Hilt injection over a parallel `MeshModule` assembly. See the
 * field docstring below for why, and for the refusal-before-construction half.
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
class MeshService : Service() {

    /**
     * *** GS-FINAL-003 `android-provider-court`: THE NODE COMES FROM THE COMPONENT THE COURTS TEST, NOT FROM A
     * PARALLEL HILT GRAPH. ***
     *
     * *THE DEFECT THIS REPLACES, IN THE LEDGER'S OWN WORDS: **"the component exists and the miswiring mutation ran,
     * but the SHIPPING composition (AppModule -> MeshModule) is never checked by it."*** *Before this edit the node was
     * `@Inject lateinit var meshNode: MeshNode`, resolved by Hilt over `MeshModule` -- a SECOND assembly of the same
     * `@Provides` set, entered by `@AndroidEntryPoint`, never the `@Component` the courts construct.*
     *
     * *** SO THE PRODUCTION USE SITE IS `MeshGraphComponent.production(this).meshNode()`: THE TESTED COMPONENT IS THE
     * PRODUCTION COMPONENT. *** *`MeshGraphComponent`'s `MeshGraphMeshModule` delegates every provider to the SAME
     * `MeshModule`, so there is no second graph and no second implementation -- only one road, which a court can
     * construct and a miswiring mutation can redden.*
     *
     * *** AND THE RESOLUTION IS DELAYED UNTIL AFTER THE REFUSAL GATES. *** *The former `@Inject` field was populated by
     * Hilt on `onCreate`, BEFORE `LINK_LAYER_READY`/permission checks -- so a refused service still walked the whole
     * private composition (identity, message store, peer store, transport). **A refused service must open NOTHING**: the
     * component is built only on the road that really starts the radio, and `node` stays null on every refusing road.*
     */
    private var node: MeshNode? = null

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
            // Fail visibly and stop. A refusing road therefore constructs no private state at all.
            android.util.Log.w(TAG, "mesh service refused: BLUETOOTH_CONNECT not granted")
            stopSelf()
            return
        }
        // *** THE TESTED PRODUCTION COMPOSITION, AT ITS ONE NON-TEST USE SITE. ***
        val node = MeshGraphComponent.production(applicationContext).meshNode()
        this.node = node
        startForeground(NOTIFICATION_ID, buildNotification(peers = 0, queued = 0))
        scope.launch {
            while (true) {
                node.setPowerState(currentPowerState())
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
            node?.start()
        }
        return START_STICKY
    }

    override fun onDestroy() {
        node?.stop()
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
        if (node?.hasActiveSos() == true) return PowerState.SOS_ACTIVE
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
