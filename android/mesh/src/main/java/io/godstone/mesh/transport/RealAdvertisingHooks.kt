package io.godstone.mesh.transport

import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.os.ParcelUuid

/**
 * T09: the production [AdvertisingHooks]. This file is the only place in the
 * advertising path that touches android.bluetooth.le classes: it executes
 * the canonical instruction stream against the real AdvertiseData.Builder
 * one call per instruction and submits the result through
 * [BluetoothLeAdvertiser]. Because the canonical adapter performs the budget
 * audit and the readiness gate before dispatch, a submission that reaches
 * this class is always the canonical UUID-only payload.
 */
class RealAdvertisingHooks(
    private val advertiser: BluetoothLeAdvertiser?
) : AdvertisingHooks {

    private var registeredCallback: AdvertiseCallback? = null

    override val isAvailable: Boolean
        get() = advertiser != null

    override fun dispatchStart(
        settings: BleAdvertiseSettings,
        instructions: List<AdvertiseInstruction>,
        callback: (AdvertisingResult) -> Unit
    ): Boolean {
        val adv = advertiser ?: return false

        val settingsBuilder = AdvertiseSettings.Builder()
            .setAdvertiseMode(settings.mode)
            .setTxPowerLevel(settings.txPowerLevel)
            .setConnectable(settings.connectable)

        val dataBuilder = AdvertiseData.Builder()
        for (instruction in instructions) {
            when (instruction) {
                is AdvertiseInstruction.AddServiceUuid ->
                    dataBuilder.addServiceUuid(ParcelUuid(instruction.uuid))
                is AdvertiseInstruction.AddServiceData ->
                    dataBuilder.addServiceData(ParcelUuid(instruction.uuid), instruction.data.copyOf())
                is AdvertiseInstruction.AddManufacturerData ->
                    dataBuilder.addManufacturerData(instruction.companyId, instruction.data.copyOf())
                is AdvertiseInstruction.IncludeDeviceName ->
                    dataBuilder.setIncludeDeviceName(instruction.include)
                is AdvertiseInstruction.IncludeTxPowerLevel ->
                    dataBuilder.setIncludeTxPowerLevel(instruction.include)
            }
        }

        val advertiseCallback = object : AdvertiseCallback() {
            override fun onStartSuccess(advertiseSettings: AdvertiseSettings?) {
                callback(AdvertisingResult.Success)
            }

            override fun onStartFailure(errorCode: Int) {
                callback(
                    AdvertisingResult.Failure(
                        failureFor(errorCode),
                        errorCode
                    )
                )
            }
        }
        registeredCallback = advertiseCallback
        adv.startAdvertising(settingsBuilder.build(), dataBuilder.build(), advertiseCallback)
        return true
    }

    override fun dispatchStop(): Boolean {
        val adv = advertiser ?: return false
        val current = registeredCallback ?: return false
        adv.stopAdvertising(current)
        registeredCallback = null
        return true
    }

    companion object {

        /** Map the platform callback error codes onto the typed failure set. */
        fun failureFor(errorCode: Int): AdvertisingFailure = when (errorCode) {
            AdvertiseCallback.ADVERTISE_FAILED_DATA_TOO_LARGE -> AdvertisingFailure.DATA_TOO_LARGE
            AdvertiseCallback.ADVERTISE_FAILED_TOO_MANY_ADVERTISERS -> AdvertisingFailure.TOO_MANY_ADVERTISERS
            AdvertiseCallback.ADVERTISE_FAILED_ALREADY_STARTED -> AdvertisingFailure.ALREADY_STARTED
            AdvertiseCallback.ADVERTISE_FAILED_INTERNAL_ERROR -> AdvertisingFailure.INTERNAL_ERROR
            AdvertiseCallback.ADVERTISE_FAILED_FEATURE_UNSUPPORTED -> AdvertisingFailure.FEATURE_UNSUPPORTED
            else -> AdvertisingFailure.UNKNOWN
        }
    }
}
