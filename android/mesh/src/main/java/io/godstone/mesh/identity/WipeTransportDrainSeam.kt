package io.godstone.mesh.identity

import io.godstone.mesh.transport.BleTransport

/**
 * GS-STORE-006: **THE PRODUCTION `TransportRuntimeSeam` FOR THIS ISLE** -- and, unlike the iOS side, IT NEEDS NO NEW
 * MECHANISM: the isle already owneth the verb this seam requires.
 *
 * [drainTransport] closeth admission with the transport's own `stop()` and then asketh the transport's own
 * `awaitInFlight(boundMillis)`, WHICH RETURNETH **ZERO** WHEN THE WORK IS GONE AND **THE OUTSTANDING COUNT** WHEN THE BOUND
 * PASSES. SO THE RECEIPT IS **EARNED BY THE ISLE'S OWN MEASUREMENT RATHER THAN ASSERTED BY THIS ADAPTER**: `.Drained` is
 * returned only when that count is zero, and `.NotDrained` NAMETH the count otherwise.
 *
 * THE ISLE'S OWN DOCTRINE, WHICH THIS ADAPTER OBEYS RATHER THAN RESTATES (from `BleTransport.awaitInFlight`): "still
 * running when the bound passeth -- so a drain that leaveth work behind **cannot** be reported as clean, which is precisely
 * what the seam's do-nothing default made invisible." THAT IS THE LAW OF THIS WHOLE FINDING: A SEAM'S SILENT DEFAULT IS THE
 * DEFECT, AND LEAVING WORK BEHIND MUST BE **REPRESENTABLE**.
 *
 * (AND THE CONTRAST WITH iOS IS DELIBERATE AND RECORDED: iOS's adapter used a BARRIER ON ITS SERIAL EXECUTOR, because that
 * is what iOS hath; this isle hath a COUNT, so this isle useth the count. READ THE ISLE'S OWN VOCABULARY; DO NOT TRANSPLANT
 * THE OTHER ISLE'S.)
 */
class WipeTransportDrainSeam(
    private val transport: BleTransport,
    private val drainBoundMillis: Long = DEFAULT_DRAIN_BOUND_MILLIS,
) : TransportRuntimeSeam {

    /** Whether THIS process lifetime hath drained the transport; a reboot starteth un-quiesced, as the seam's contract saith. */
    private var quiescedThisLifetime: Boolean = false
    private val lock = Any()

    override fun drainTransport(): RuntimeDrainReceipt {
        synchronized(lock) {
            // CLOSE ADMISSION FIRST, so that nothing new is admitted behind the drain we are about to prove.
            transport.stop()
            val outstanding = transport.awaitInFlight(drainBoundMillis)
            if (outstanding != 0) {
                // NOT DRAINED, AND THE COUNT IS NAMED: a wipe that carried work behind must not proceed to key erasure,
                // and the reason it did not is a number rather than an opinion.
                return RuntimeDrainReceipt.NotDrained(
                    "the transport still carrieth $outstanding item(s) at the $drainBoundMillis ms bound"
                )
            }
            quiescedThisLifetime = true
            return RuntimeDrainReceipt.Drained(closedTransports = 1, quiescedRuntime = true)
        }
    }

    override fun isQuiesced(): Boolean = synchronized(lock) { quiescedThisLifetime }

    /** Before a drain the radio is live and this seam saith so; after it the transport carrieth nothing. */
    override fun fireRadio(msg: String): Boolean = !isQuiesced()

    override fun sendVia(msg: String): Boolean = !isQuiesced()

    companion object {
        /** The bound within which the transport must quiesce. Short enough for a boot path, long enough for a write in flight. */
        const val DEFAULT_DRAIN_BOUND_MILLIS: Long = 2_000L
    }
}
