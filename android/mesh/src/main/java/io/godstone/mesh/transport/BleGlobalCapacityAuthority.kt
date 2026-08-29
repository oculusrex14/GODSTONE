package io.godstone.mesh.transport

enum class BleDirection {
    OUTBOUND,
    INBOUND
}

data class CapacityLease(
    val direction: BleDirection,
    val peerId: String,
    val generation: Long
)

class BleGlobalCapacityAuthority(
    val maxTotalPeers: Int = 7
) {
    private val lock = Any()
    private val outboundLeases = mutableMapOf<String, CapacityLease>()
    private val inboundLeases = mutableMapOf<String, CapacityLease>()

    val outboundCount: Int
        get() = synchronized(lock) { outboundLeases.size }

    val inboundCount: Int
        get() = synchronized(lock) { inboundLeases.size }

    val totalCount: Int
        get() = synchronized(lock) { outboundLeases.size + inboundLeases.size }

    fun tryAdmitOutbound(peerId: String, generation: Long = 0L): CapacityLease? = synchronized(lock) {
        val existing = outboundLeases[peerId]
        if (existing != null) {
            val updated = CapacityLease(BleDirection.OUTBOUND, peerId, generation)
            outboundLeases[peerId] = updated
            return updated
        }
        if (totalCount < maxTotalPeers) {
            val lease = CapacityLease(BleDirection.OUTBOUND, peerId, generation)
            outboundLeases[peerId] = lease
            return lease
        }
        return null
    }

    fun tryAdmitInbound(peerId: String, generation: Long = 0L): CapacityLease? = synchronized(lock) {
        val existing = inboundLeases[peerId]
        if (existing != null) {
            val updated = CapacityLease(BleDirection.INBOUND, peerId, generation)
            inboundLeases[peerId] = updated
            return updated
        }
        if (totalCount < maxTotalPeers) {
            val lease = CapacityLease(BleDirection.INBOUND, peerId, generation)
            inboundLeases[peerId] = lease
            return lease
        }
        return null
    }

    fun releaseLease(lease: CapacityLease?): Boolean = synchronized(lock) {
        if (lease == null) return false
        return when (lease.direction) {
            BleDirection.OUTBOUND -> {
                val current = outboundLeases[lease.peerId]
                if (current == lease || (current != null && current.generation == lease.generation)) {
                    outboundLeases.remove(lease.peerId)
                    true
                } else {
                    false
                }
            }
            BleDirection.INBOUND -> {
                val current = inboundLeases[lease.peerId]
                if (current == lease || (current != null && current.generation == lease.generation)) {
                    inboundLeases.remove(lease.peerId)
                    true
                } else {
                    false
                }
            }
        }
    }

    fun releaseOutbound(peerId: String): Boolean = synchronized(lock) {
        return outboundLeases.remove(peerId) != null
    }

    fun releaseInbound(peerId: String): Boolean = synchronized(lock) {
        return inboundLeases.remove(peerId) != null
    }

    fun releaseAllInbound() = synchronized(lock) {
        inboundLeases.clear()
    }

    fun releaseAllOutbound() = synchronized(lock) {
        outboundLeases.clear()
    }

    fun reset() = synchronized(lock) {
        outboundLeases.clear()
        inboundLeases.clear()
    }
}
