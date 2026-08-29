package io.godstone.mesh.transport

import java.util.concurrent.atomic.AtomicLong

enum class BleDirection {
    OUTBOUND,
    INBOUND
}

data class RelationKey(
    val direction: BleDirection,
    val peerAddress: String,
    val generation: Long
)

data class CapacityLease(
    val direction: BleDirection,
    val peerAddress: String,
    val generation: Long,
    val leaseId: Long
)

class BleGlobalCapacityAuthority(
    val maxTotalPeers: Int = 7
) {
    private val lock = Any()
    private val leaseIdCounter = AtomicLong(1L)
    private val outboundLeases = mutableMapOf<String, CapacityLease>()
    private val inboundLeases = mutableMapOf<String, CapacityLease>()

    val outboundCount: Int
        get() = synchronized(lock) { outboundLeases.size }

    val inboundCount: Int
        get() = synchronized(lock) { inboundLeases.size }

    val totalCount: Int
        get() = synchronized(lock) { outboundLeases.size + inboundLeases.size }

    fun tryAdmitOutbound(peerAddress: String, generation: Long = 0L): CapacityLease? = synchronized(lock) {
        val existing = outboundLeases[peerAddress]
        if (existing != null) {
            val updated = CapacityLease(BleDirection.OUTBOUND, peerAddress, generation, leaseIdCounter.getAndIncrement())
            outboundLeases[peerAddress] = updated
            return updated
        }
        if (totalCount < maxTotalPeers) {
            val lease = CapacityLease(BleDirection.OUTBOUND, peerAddress, generation, leaseIdCounter.getAndIncrement())
            outboundLeases[peerAddress] = lease
            return lease
        }
        return null
    }

    fun tryAdmitInbound(peerAddress: String, generation: Long = 0L): CapacityLease? = synchronized(lock) {
        val existing = inboundLeases[peerAddress]
        if (existing != null) {
            val updated = CapacityLease(BleDirection.INBOUND, peerAddress, generation, leaseIdCounter.getAndIncrement())
            inboundLeases[peerAddress] = updated
            return updated
        }
        if (totalCount < maxTotalPeers) {
            val lease = CapacityLease(BleDirection.INBOUND, peerAddress, generation, leaseIdCounter.getAndIncrement())
            inboundLeases[peerAddress] = lease
            return lease
        }
        return null
    }

    fun releaseLease(lease: CapacityLease?): Boolean = synchronized(lock) {
        if (lease == null) return false
        return when (lease.direction) {
            BleDirection.OUTBOUND -> {
                val current = outboundLeases[lease.peerAddress]
                if (current != null && current.leaseId == lease.leaseId && current.generation == lease.generation) {
                    outboundLeases.remove(lease.peerAddress)
                    true
                } else {
                    false
                }
            }
            BleDirection.INBOUND -> {
                val current = inboundLeases[lease.peerAddress]
                if (current != null && current.leaseId == lease.leaseId && current.generation == lease.generation) {
                    inboundLeases.remove(lease.peerAddress)
                    true
                } else {
                    false
                }
            }
        }
    }

    fun isLeaseActive(lease: CapacityLease?): Boolean = synchronized(lock) {
        if (lease == null) return false
        val current = when (lease.direction) {
            BleDirection.OUTBOUND -> outboundLeases[lease.peerAddress]
            BleDirection.INBOUND -> inboundLeases[lease.peerAddress]
        }
        return current != null && current.leaseId == lease.leaseId && current.generation == lease.generation
    }

    fun releaseOutbound(peerAddress: String): Boolean = synchronized(lock) {
        return outboundLeases.remove(peerAddress) != null
    }

    fun releaseInbound(peerAddress: String): Boolean = synchronized(lock) {
        return inboundLeases.remove(peerAddress) != null
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
