package io.godstone.mesh.transport

/** Stable six-byte representation of an Android Bluetooth device address. */
internal object PeerId {
    fun fromAddress(address: String): ByteArray? {
        val parts = address.split(':')
        if (parts.size != 6) return null
        return runCatching {
            ByteArray(6) { index -> parts[index].toInt(16).toByte() }
        }.getOrNull()
    }

    fun toAddress(bytes: ByteArray): String? {
        if (bytes.size != 6) return null
        return bytes.joinToString(":") { "%02X".format(it.toInt() and 0xFF) }
    }
}
