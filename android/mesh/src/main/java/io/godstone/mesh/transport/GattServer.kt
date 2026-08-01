// SYNTHESIZED gap-closure file -- authored to make the project compile; see docs/AUDIT.md.
package io.godstone.mesh.transport

import android.annotation.SuppressLint
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.content.Context
import java.util.UUID
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow

/**
 * Peripheral-side GATT server. Exposes the write characteristic and emits every
 * frame a central writes, paired with that central's MAC bytes as the peer id.
 */
@SuppressLint("MissingPermission")
internal object GattServer {

    /**
     * Stream of (peerId, frame) pairs written by connected centrals. [peerId] is
     * the central's MAC address as raw bytes.
     */
    fun incoming(
        context: Context,
        serviceUuid: UUID,
        writeCharUuid: UUID
    ): Flow<Pair<ByteArray, ByteArray>> = callbackFlow {
        val manager = context.getSystemService(BluetoothManager::class.java)
        val adapter = manager?.adapter
        if (manager == null || adapter == null) {
            close(); return@callbackFlow
        }

        lateinit var server: BluetoothGattServer
        server = manager.openGattServer(context, object : BluetoothGattServerCallback() {
            override fun onCharacteristicWriteRequest(
                device: android.bluetooth.BluetoothDevice,
                requestId: Int,
                characteristic: BluetoothGattCharacteristic,
                preparedWrite: Boolean,
                responseNeeded: Boolean,
                offset: Int,
                value: ByteArray
            ) {
                if (characteristic.uuid == writeCharUuid) {
                    PeerId.fromAddress(device.address)?.let { trySend(it to value) }
                }
                if (responseNeeded) {
                    server.sendResponse(device, requestId, 0 /* GATT_SUCCESS */, offset, value)
                }
            }
        }) ?: run { close(); return@callbackFlow }

        val characteristic = BluetoothGattCharacteristic(
            writeCharUuid,
            BluetoothGattCharacteristic.PROPERTY_WRITE,
            BluetoothGattCharacteristic.PERMISSION_WRITE
        )
        val service = BluetoothGattService(
            serviceUuid,
            BluetoothGattService.SERVICE_TYPE_PRIMARY
        ).apply { addCharacteristic(characteristic) }

        server.addService(service)

        awaitClose {
            server.clearServices()
            server.close()
        }
    }
}
