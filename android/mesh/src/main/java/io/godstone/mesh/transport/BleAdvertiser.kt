package io.godstone.mesh.transport

/**
 * T09: the canonical advertising adapter of the mesh.
 *
 * The BleAdvertiser is the single decision point that turns a
 * [BleAdvertisingPayload] into one platform submission. It performs the
 * legacy payload accounting before anything is handed to the radio, keeps
 * the last typed result observable, and reaches the outside world only
 * through [AdvertisingHooks], so tests can inspect the exact instruction
 * stream that would be executed against the platform builder.
 *
 * This file is deliberately free of android.* imports: everything here is
 * JVM-inspectable domain code. The platform substitution lives in
 * [RealAdvertisingHooks].
 */

/** Typed outcome of one advertising start attempt, surfaced from the platform. */
sealed class AdvertisingResult {

    /** The platform accepted the submission and the advertiser started. */
    object Success : AdvertisingResult() {
        override fun toString(): String = "AdvertisingResult.Success"
    }

    /**
     * A typed platform failure. [reason] classifies it; [errorCode] carries
     * the raw platform code when the failure came from the callback.
     */
    class Failure(
        val reason: AdvertisingFailure,
        val errorCode: Int? = null
    ) : AdvertisingResult() {
        override fun toString(): String = "AdvertisingResult.Failure($reason, code=$errorCode)"
    }
}

/** Classification of advertising failures the adapter can surface. */
enum class AdvertisingFailure {
    /** No BluetoothLeAdvertiser is reachable (adapter absent or disabled path). */
    ADAPTER_UNAVAILABLE,

    /** The GATT service is not registered yet; advertising without it is meaningless. */
    SERVICE_NOT_READY,

    /** The stack refused the BLUETOOTH_ADVERTISE permission grant. */
    PERMISSION_DENIED,

    /** Legacy payload accounting exceeded the 31-octet budget; refused before dispatch. */
    DATA_TOO_LARGE,

    /** Platform code 3: an advertiser is already active. */
    ALREADY_STARTED,

    /** Platform code 2: the controller rejects another advertiser instance. */
    TOO_MANY_ADVERTISERS,

    /** Platform code 5: LE advertising not supported on this controller. */
    FEATURE_UNSUPPORTED,

    /** Platform code 4: unspecified stack failure. */
    INTERNAL_ERROR,

    /** Anything the adapter cannot classify. */
    UNKNOWN
}

/** Values mirror of the platform AdvertiseSettings the mesh submits. */
class BleAdvertiseSettings(
    val mode: Int,
    val txPowerLevel: Int,
    val connectable: Boolean
) {
    override fun equals(other: Any?): Boolean =
        other is BleAdvertiseSettings && other.mode == mode &&
            other.txPowerLevel == txPowerLevel && other.connectable == connectable

    override fun hashCode(): Int = 31 * (31 * mode + txPowerLevel) + connectable.hashCode()

    override fun toString(): String =
        "BleAdvertiseSettings(mode=$mode, tx=$txPowerLevel, connectable=$connectable)"
}

/**
 * The substitution point between the canonical adapter and the radio stack.
 *
 * Production uses [RealAdvertisingHooks], which executes the instruction
 * stream against android.bluetooth.le.AdvertiseData.Builder and submits it
 * through BluetoothLeAdvertiser. Tests substitute a recording double that
 * captures the exact settings and instruction stream handed to the platform.
 */
interface AdvertisingHooks {

    /** Whether a BluetoothLeAdvertiser is reachable at all. */
    val isAvailable: Boolean

    /**
     * Execute the instruction stream against the platform builder and submit
     * the advertisement. The typed outcome is delivered to [callback]; it
     * may arrive synchronously (recording doubles) or asynchronously (real
     * stack). The return value reports whether the submission was accepted.
     */
    fun dispatchStart(
        settings: BleAdvertiseSettings,
        instructions: List<AdvertiseInstruction>,
        callback: (AdvertisingResult) -> Unit
    ): Boolean

    /** Withdraw the advertiser most recently submitted through these hooks. */
    fun dispatchStop(): Boolean
}

/**
 * The canonical advertising adapter. One instance per transport; it owns the
 * decision logic (availability, readiness, budget, permission handling),
 * while the hooks own the platform mechanics.
 */
class BleAdvertiser(private val hooks: AdvertisingHooks) {

    private var lastResultValue: AdvertisingResult? = null
    private var advertisingActive: Boolean = false

    /** The last typed result recorded, or null when nothing was ever submitted. */
    val lastResult: AdvertisingResult?
        get() = lastResultValue

    /** Whether an advertiser submission is currently outstanding. */
    val isActive: Boolean
        get() = advertisingActive

    /**
     * Submit the canonical [payload]. [ready] reflects the GATT service
     * registration the advertisement depends on. Returns true only when the
     * platform accepted the submission and no failure was delivered
     * synchronously. The typed outcome is observable via [lastResult].
     */
    fun start(
        settings: BleAdvertiseSettings,
        payload: BleAdvertisingPayload,
        ready: Boolean = true
    ): Boolean {
        if (!hooks.isAvailable) {
            record(AdvertisingResult.Failure(AdvertisingFailure.ADAPTER_UNAVAILABLE))
            return false
        }
        if (!ready) {
            record(AdvertisingResult.Failure(AdvertisingFailure.SERVICE_NOT_READY))
            return false
        }
        if (!payload.fitsLegacyBudget()) {
            record(
                AdvertisingResult.Failure(
                    AdvertisingFailure.DATA_TOO_LARGE,
                    ADVERTISE_FAILED_DATA_TOO_LARGE
                )
            )
            return false
        }
        var delivered: AdvertisingResult? = null
        val accepted = try {
            hooks.dispatchStart(settings, payload.toInstructions()) { result ->
                delivered = result
                record(result)
            }
        } catch (denied: SecurityException) {
            record(AdvertisingResult.Failure(AdvertisingFailure.PERMISSION_DENIED))
            return false
        }
        if (delivered == null) {
            if (!accepted) {
                record(AdvertisingResult.Failure(AdvertisingFailure.UNKNOWN))
            } else if (lastResult !is AdvertisingResult.Success) {
                // Submission accepted; the asynchronous outcome has not arrived
                // yet. Optimistically mark the advertiser outstanding without
                // overwriting a previous typed failure that is still true.
                record(AdvertisingResult.Success)
            }
        }
        return accepted && delivered !is AdvertisingResult.Failure
    }

    /**
     * Withdraw the advertisement. A stop without a prior outstanding
     * submission is a no-op, not a failure: nothing is recorded and true is
     * returned.
     */
    fun stop(): Boolean {
        if (!advertisingActive) {
            return true
        }
        val stopped = hooks.dispatchStop()
        if (stopped) {
            advertisingActive = false
        }
        return stopped
    }

    private fun record(result: AdvertisingResult) {
        lastResultValue = result
        advertisingActive = result is AdvertisingResult.Success
    }

    companion object {
        /**
         * Values mirror of android.bluetooth.le.AdvertiseCallback
         * .ADVERTISE_FAILED_DATA_TOO_LARGE. Mirrored as a plain constant so
         * this file stays free of platform imports; the real mapping table
         * lives in [RealAdvertisingHooks].
         */
        const val ADVERTISE_FAILED_DATA_TOO_LARGE: Int = 1
    }
}
