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

    /**
     * **THE REAL TEARDOWN RESULT, NOT A LITERAL -- AND THIS FILE ALREADY CARRIETH THE PATTERN, ONE METHOD BELOW.**
     * The literal `1` that stood here called itself "one logical disconnect sweep", and **NO TRANSPORT ON THIS ISLE
     * COULD HAVE PRODUCED IT** -- while `awaitInFlight`, a few lines down, saith the right thing in the same breath:
     * "A transport that offereth the capability is ASKED, and its MEASURED count is returned; a coarse transport
     * answereth 0 exactly as before, **so nothing that could not answer is pretended to have been drained**."
     * THE SAME LAW NOW STANDETH HERE: a reporting transport is believed, and one that cannot report CLAIMETH NOTHING.
     * (The SWIFT twin was repaired the same way at rounds 239-241, where the same literal stood.)
     */
    override fun disconnectAll(): Int {
        val severed = (transport as? DisconnectingTransport)?.disconnectAll() ?: 0
        endOnce()
        return severed
    }

    /**
     * ANDROID-05 (step 3): THE BOUNDED IN-FLIGHT DRAIN, at the REAL boundary. The seam's default
     * answereth 0 for a seam that owneth no such work, and its own KDoc sayeth "the REAL adapter must
     * override it" -- this is that override. A transport that offereth the capability is ASKED, and
     * its MEASURED count is returned; a coarse transport answereth 0 exactly as before, so nothing
     * that could not answer is pretended to have been drained.
     */
    override fun awaitInFlight(boundMillis: Long): Int {
        val aware = transport as? InFlightAwareTransport ?: return 0
        return aware.awaitInFlight(boundMillis)
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
