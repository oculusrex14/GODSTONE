package io.godstone.mesh.transport

/**
 * T11: the scan source context.
 *
 * A scan registration is created complete - epoch, callback identity and
 * lease - before the scanner is told to call anybody back. Every callback
 * delivery is first captured as a ScanEvent that names its source context;
 * the reducer consults the context and takes no action at all unless the
 * exact same context is still the active registration of a started
 * transport. A late delivery of a retired or replaced registration can
 * therefore never mutate the state a newer registration owns: it is dropped
 * where it stands, and the previous authoritative state survives untouched.
 *
 * The identity is never inferred from a current-state lookup after the
 * fact; the event carries the token captured at the callback boundary.
 */
class ScanLease internal constructor() {

    @Volatile
    private var active: Boolean = true

    /** Whether the reducer may still accept events of this lease. */
    fun isActivity(): Boolean = active

    /** End the lease; idempotent, and only the owning operation calls it. */
    internal fun release() {
        active = false
    }

    override fun toString(): String = "ScanLease(active=" + active + ")"
}

/** The immutable source token of one scanner registration. */
class ScanContext(
    val epoch: Long,
    val callbackIdentity: Long,
    val lease: ScanLease
) {

    /** Whether this context still carries the currently open epoch. */
    fun isCurrent(currentEpoch: Long): Boolean = epoch == currentEpoch

    /** Whether the lease of this context has not been terminated. */
    fun isActive(): Boolean = lease.isActivity()

    override fun toString(): String = "ScanContext(epoch=" + epoch + ", identity=" + callbackIdentity + ", lease=" + lease + ")"
}

/**
 * A scan result captured at the callback boundary: the source context is
 * taken before any delivery, the payload fields are read once, and the
 * reducer decides - under the named owner - whether this event is real.
 */
class ScanEvent(
    val context: ScanContext,
    val callbackType: Int,
    val address: String?,
    val rssi: Int?,
    val metadata: BleLinkInfoV1?
) {
    override fun toString(): String =
        "ScanEvent(context=" + context + ", type=" + callbackType + ", address=" + address + ", rssi=" + rssi + ")"
}

/** A scan failure captured at the callback boundary; it terminates only its own context. */
class ScanFailureEvent(
    val context: ScanContext,
    val errorCode: Int
) {
    override fun toString(): String = "ScanFailureEvent(context=" + context + ", code=" + errorCode + ")"
}
