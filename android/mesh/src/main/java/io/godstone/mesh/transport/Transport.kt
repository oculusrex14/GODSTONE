package io.godstone.mesh.transport

import kotlinx.coroutines.flow.Flow

/**
 * Common surface for both planes. The router is transport agnostic, which is
 * what allows the entire routing layer to be exercised in the simulator with no
 * radio present at all (see tab 12_TESTS_CI).
 */
interface Transport {

    val name: String

    /** True when this transport can carry payloads above BULK_THRESHOLD. */
    val isBulkCapable: Boolean

    fun start()
    fun stop()

    /** Peers currently reachable on this transport. */
    fun peers(): Flow<PeerEvent>

    suspend fun send(peerId: ByteArray, bytes: ByteArray): Boolean

    fun received(): Flow<Pair<ByteArray, ByteArray>>

    companion object {
        /** Above this size, negotiate the Wi-Fi bulk plane. */
        const val BULK_THRESHOLD = 512
    }
}

sealed class PeerEvent {
    data class Found(
        val peerId: ByteArray,
        val nodeHint: ByteArray,
        val rssi: Int?,
        val sosFlag: Boolean,
        val bulkCapable: Boolean,
        val shortDigest: ByteArray,
        val queueDepth: Int
    ) : PeerEvent()

    data class Lost(val peerId: ByteArray) : PeerEvent()
}

/** Duty cycle by power state. Battery is life (constraint C4). */
enum class PowerState(
    val advertiseIntervalMs: Int,
    val scanWindowMs: Int,
    val scanIntervalMs: Int
) {
    NORMAL(1000, 300, 2000),
    POWER_SAVE(3000, 300, 8000),
    CRITICAL(10000, 300, 30000),
    SOS_ACTIVE(200, 300, 300)
}
