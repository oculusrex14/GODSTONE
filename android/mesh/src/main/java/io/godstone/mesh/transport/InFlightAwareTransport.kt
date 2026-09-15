package io.godstone.mesh.transport

/**
 * ANDROID-05 (the card's step 3) -- THE OPTIONAL BOUNDED IN-FLIGHT DRAIN.
 *
 * `Transport` exposeth a coarse `start()`/`stop()`: it sayeth nothing about the writer and session
 * tasks a transport owneth, so `TransportSeam.awaitInFlight(boundMillis)` had a do-nothing default
 * and the lifecycle authority's drain could never SEE in-flight work at the real boundary -- a drain
 * that left writers running was indistinguishable from one that left nothing behind, and the courts
 * that asserted the drain's law were asserting it against FAKES.
 *
 * A transport that CAN answer implementeth this capability: it waiteth up to [awaitInFlight]'s bound
 * for its own in-flight work to terminate and reporteth HOW MANY tasks are still running when the
 * bound passeth -- a MEASURED count, never a constant. A transport that cannot answer is unchanged:
 * the adapter answereth 0 for it, exactly as the seam's default did.
 *
 * WHAT THIS IS NOT: not a device, radio or emulator result, and not a claim that a real stack
 * draineth. It is the SHAPE by which the production seam can be told the truth about its own work.
 */
interface InFlightAwareTransport {
    /**
     * Wait up to [boundMillis] for in-flight writer/session work to terminate; return how many
     * tasks are STILL RUNNING at the bound. 0 meaneth "nothing outstanding".
     */
    fun awaitInFlight(boundMillis: Long): Int
}
