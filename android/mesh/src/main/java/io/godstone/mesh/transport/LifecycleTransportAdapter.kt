package io.godstone.mesh.transport

import io.godstone.mesh.identity.TransportSeam

/**
 * T28 platform-integration adapter: binds the fine-grained [TransportSeam] calls
 * the [io.godstone.mesh.identity.UnifiedRuntimeLifecycle] authority issues onto the
 * real [Transport] contract. The authority speaks in scanner/advertiser/disconnect
 * primitives; a [Transport] exposes a coarse start/stop. The adapter maps them
 * faithfully and idempotently so the lifecycle invariants the authority enforces
 * hold at the ACTUAL transport boundary:
 *
 *  - the FIRST of {startScan, startAdvertising} in an activation issues exactly one
 *    [Transport.start]; the rest of that activation are no-ops (a repeated start can
 *    never double-start the radio);
 *  - the FIRST of {stopScan, stopAdvertising, disconnectAll} in a drain issues exactly
 *    one [Transport.stop]; a power-off / permission-removal / wipe therefore uniformly
 *    stops the transport once;
 *  - because a stopped (or terminal) authority never reaches the seam begin calls, a
 *    background event cannot resurrect the transport -- there is no path from
 *    [TransportSeam] to [Transport.start] while the runtime is stopped.
 *
 * This adapter is pure glue (no radio logic of its own) and is the seam the runtime
 * composition binds to the concrete transports (BleTransport / WifiAwareTransport).
 */
class LifecycleTransportAdapter(private val transport: Transport) : TransportSeam {

    private var transportStarted: Boolean = false

    override fun startScan() = beginOnce()

    override fun startAdvertising() = beginOnce()

    override fun stopScan() = endOnce()

    override fun stopAdvertising() = endOnce()

    override fun disconnectAll(): Int {
        endOnce()
        // A coarse Transport.stop() severs every live session; the authority counts the
        // drain, so report one logical disconnect sweep.
        return 1
    }

    override fun resetResources() {
        // Duty-cycle tables and caches are reset by the concrete transport inside its
        // own stop(); the adapter carries no separate resource to release here.
    }

    private fun beginOnce() {
        if (!transportStarted) {
            transport.start()
            transportStarted = true
        }
    }

    private fun endOnce() {
        if (transportStarted) {
            transport.stop()
            transportStarted = false
        }
    }
}
