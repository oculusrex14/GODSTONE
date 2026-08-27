package io.godstone.mesh.transport

import java.nio.ByteBuffer

/**
 * Elected role for a BLE link between two peers (ADR-002, Phase C8.4D1).
 */
enum class BleRole {
    INITIATOR,
    RESPONDER
}

/**
 * Result of deterministic role election based on unsigned-byte lexicographic comparison of 4-byte node hints.
 */
sealed interface BleRoleElectionResult {
    data class Elected(val role: BleRole) : BleRoleElectionResult
    data object Tie : BleRoleElectionResult
    data class Invalid(val reason: String) : BleRoleElectionResult
}

/**
 * Pure, platform-independent helper for deterministic BLE role election (ADR-002 §3, Phase C8.4D1-A1).
 *
 * For unequal 4-byte node hints:
 *   initiator = peer with lexicographically smaller node_hint (unsigned byte comparison).
 *
 * For equal 4-byte hints:
 *   Returns [BleRoleElectionResult.Tie] (fails closed, no silent tie-breaker fallback).
 */
object BleRoleElection {

    const val NODE_HINT_BYTES = 4

    fun elect(localHint: ByteArray, remoteHint: ByteArray): BleRoleElectionResult {
        if (localHint.size != NODE_HINT_BYTES) {
            return BleRoleElectionResult.Invalid("localHint size ${localHint.size} != $NODE_HINT_BYTES")
        }
        if (remoteHint.size != NODE_HINT_BYTES) {
            return BleRoleElectionResult.Invalid("remoteHint size ${remoteHint.size} != $NODE_HINT_BYTES")
        }

        for (i in 0 until NODE_HINT_BYTES) {
            val l = localHint[i].toInt() and 0xFF
            val r = remoteHint[i].toInt() and 0xFF
            if (l < r) {
                return BleRoleElectionResult.Elected(BleRole.INITIATOR)
            } else if (l > r) {
                return BleRoleElectionResult.Elected(BleRole.RESPONDER)
            }
        }

        // Equal hints: fail closed
        return BleRoleElectionResult.Tie
    }
}

/**
 * Canonical 13-byte LinkInfo structure exchanged over the link_info GATT characteristic (ADR-002 §2, Phase C8.4D1-A1).
 * Also used for optional Android scan-response discovery metadata.
 */
data class BleLinkInfoV1(
    val version: Byte,
    val flags: Byte,
    val nodeHint: ByteArray,
    val shortDigest: ByteArray,
    val queueDepth: Int
) {
    val isSosPresent: Boolean get() = (flags.toInt() and BleLinkInfoConstants.FLAG_SOS) != 0
    val isBulkCapable: Boolean get() = (flags.toInt() and BleLinkInfoConstants.FLAG_BULK_CAPABLE) != 0
    val isPowerConstrained: Boolean get() = (flags.toInt() and BleLinkInfoConstants.FLAG_POWER_CONSTRAINED) != 0
    val isVerifiedOnly: Boolean get() = (flags.toInt() and BleLinkInfoConstants.FLAG_VERIFIED_ONLY) != 0
    val isClockUntrusted: Boolean get() = (flags.toInt() and BleLinkInfoConstants.FLAG_CLOCK_UNTRUSTED) != 0

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (javaClass != other?.javaClass) return false
        other as BleLinkInfoV1
        if (version != other.version) return false
        if (flags != other.flags) return false
        if (!nodeHint.contentEquals(other.nodeHint)) return false
        if (!shortDigest.contentEquals(other.shortDigest)) return false
        if (queueDepth != other.queueDepth) return false
        return true
    }

    override fun hashCode(): Int {
        var result = version.toInt()
        result = 31 * result + flags.toInt()
        result = 31 * result + nodeHint.contentHashCode()
        result = 31 * result + shortDigest.contentHashCode()
        result = 31 * result + queueDepth
        return result
    }
}

typealias BleDiscoveryMetadata = BleLinkInfoV1

object BleLinkInfoConstants {
    const val LINK_INFO_BYTES = 13
    const val DISCOVERY_PAYLOAD_BYTES = 13
    const val PROTOCOL_VERSION: Byte = 0x02
    const val NODE_HINT_BYTES = 4
    const val SHORT_DIGEST_BYTES = 6

    const val FLAG_SOS = 0x01
    const val FLAG_BULK_CAPABLE = 0x02
    const val FLAG_POWER_CONSTRAINED = 0x04
    const val FLAG_VERIFIED_ONLY = 0x08
    const val FLAG_CLOCK_UNTRUSTED = 0x10
}

object BleDiscoveryConstants {
    const val DISCOVERY_PAYLOAD_BYTES = 13
    const val PROTOCOL_VERSION: Byte = 0x02
    const val NODE_HINT_BYTES = 4
    const val SHORT_DIGEST_BYTES = 6

    const val FLAG_SOS = 0x01
    const val FLAG_BULK_CAPABLE = 0x02
    const val FLAG_POWER_CONSTRAINED = 0x04
    const val FLAG_VERIFIED_ONLY = 0x08
    const val FLAG_CLOCK_UNTRUSTED = 0x10
}

object BleLinkInfoCodec {

    fun encode(
        version: Byte = BleLinkInfoConstants.PROTOCOL_VERSION,
        flags: Byte,
        nodeHint: ByteArray,
        shortDigest: ByteArray,
        queueDepth: Int
    ): ByteArray {
        require(nodeHint.size == BleLinkInfoConstants.NODE_HINT_BYTES) {
            "nodeHint must be exactly ${BleLinkInfoConstants.NODE_HINT_BYTES} bytes"
        }
        require(shortDigest.size == BleLinkInfoConstants.SHORT_DIGEST_BYTES) {
            "shortDigest must be exactly ${BleLinkInfoConstants.SHORT_DIGEST_BYTES} bytes"
        }

        val clampedQueueDepth = queueDepth.coerceIn(0, 255)
        val buf = ByteBuffer.allocate(BleLinkInfoConstants.LINK_INFO_BYTES)
        buf.put(version)
        buf.put(flags)
        buf.put(nodeHint)
        buf.put(shortDigest)
        buf.put(clampedQueueDepth.toByte())
        return buf.array()
    }

    fun decode(bytes: ByteArray): BleLinkInfoV1? {
        if (bytes.size < BleLinkInfoConstants.LINK_INFO_BYTES) return null

        val buf = ByteBuffer.wrap(bytes)
        val version = buf.get()
        if (version != BleLinkInfoConstants.PROTOCOL_VERSION) return null

        val flags = buf.get()
        val nodeHint = ByteArray(BleLinkInfoConstants.NODE_HINT_BYTES).also { buf.get(it) }
        val shortDigest = ByteArray(BleLinkInfoConstants.SHORT_DIGEST_BYTES).also { buf.get(it) }
        val queueDepth = buf.get().toInt() and 0xFF

        return BleLinkInfoV1(
            version = version,
            flags = flags,
            nodeHint = nodeHint,
            shortDigest = shortDigest,
            queueDepth = queueDepth
        )
    }
}

object BleDiscoveryCodec {
    fun encode(
        version: Byte = BleDiscoveryConstants.PROTOCOL_VERSION,
        flags: Byte,
        nodeHint: ByteArray,
        shortDigest: ByteArray,
        queueDepth: Int
    ): ByteArray = BleLinkInfoCodec.encode(version, flags, nodeHint, shortDigest, queueDepth)

    fun decode(bytes: ByteArray): BleDiscoveryMetadata? = BleLinkInfoCodec.decode(bytes)
}
