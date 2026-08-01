// SYNTHESIZED gap-closure file -- authored to make the project compile; see docs/AUDIT.md.
package io.godstone.mesh.transport

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothProfile
import android.content.Context
import java.util.UUID
import kotlin.coroutines.resume
import kotlinx.coroutines.suspendCancellableCoroutine

/**
 * Central-side GATT client. Connects to a peer, locates the write characteristic,
 * and writes one frame. The peer [peerId] is the peer's MAC address as raw bytes.
 */
@SuppressLint("MissingPermission")
internal object GattClient {

    /**
     * Write [bytes] to [charUuid] on the peer identified by [peerId] MAC bytes.
     * Returns true only when the write is acknowledged by the peripheral.
     */
    suspend fun write(
        context: Context,
        peerId: ByteArray,
        charUuid: UUID,
        bytes: ByteArray
    ): Boolean = suspendCancellableCoroutine { cont ->
        val manager = context.getSystemService(android.bluetooth.BluetoothManager::class.java)
        val adapter = manager?.adapter
        if (adapter == null) {
            cont.resume(false); return@suspendCancellableCoroutine
        }

        val mac = PeerId.toAddress(peerId) ?: run {
            cont.resume(false); return@suspendCancellableCoroutine
        }
        val device: BluetoothDevice = try {
            adapter.getRemoteDevice(mac)
        } catch (e: IllegalArgumentException) {
            cont.resume(false); return@suspendCancellableCoroutine
        }

        var gatt: BluetoothGatt? = null
        val callback = object : BluetoothGattCallback() {
            override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
                if (newState == BluetoothProfile.STATE_CONNECTED) {
                    g.discoverServices()
                } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                    if (cont.isActive) cont.resume(false)
                    g.close()
                }
            }

            override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
                val service = g.services.firstOrNull { it.uuid == BleTransport.SERVICE_UUID }
                val characteristic = service?.getCharacteristic(charUuid)
                if (characteristic == null) {
                    if (cont.isActive) cont.resume(false)
                    g.disconnect(); return
                }
                characteristic.value = bytes
                characteristic.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
                if (!g.writeCharacteristic(characteristic)) {
                    if (cont.isActive) cont.resume(false)
                    g.disconnect()
                }
            }

            override fun onCharacteristicWrite(
                g: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
                status: Int
            ) {
                if (cont.isActive) cont.resume(status == BluetoothGatt.GATT_SUCCESS)
                g.disconnect()
            }
        }

        gatt = device.connectGatt(context, false, callback, BluetoothDevice.TRANSPORT_LE)
        if (gatt == null && cont.isActive) cont.resume(false)

        cont.invokeOnCancellation { gatt?.close() }
    }

}
