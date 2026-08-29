package io.godstone.mesh.transport

class BleGlobalCapacityAuthority {
    private var outboundCount: Int = 0
    private var inboundCount: Int = 0
    val maxTotalPeers: Int = 7

    val totalCount: Int
        get() = outboundCount + inboundCount

    fun tryAdmitOutbound(): Boolean {
        if (totalCount < maxTotalPeers) {
            outboundCount++
            return true
        }
        return false
    }

    fun tryAdmitInbound(): Boolean {
        if (totalCount < maxTotalPeers) {
            inboundCount++
            return true
        }
        return false
    }

    fun releaseOutbound() {
        if (outboundCount > 0) outboundCount--
    }

    fun releaseInbound() {
        if (inboundCount > 0) inboundCount--
    }
}
