package io.godstone.mesh.transport

import java.security.MessageDigest

/**
 * ADR-002 Canonical BLE Record Layer Types & Constants (Phase C8.4C).
 */
enum class BleRecordType(val typeCode: Byte) {
    HS1(0x11.toByte()),
    HS2(0x12.toByte()),
    HS3(0x14.toByte()),
    DATA(0x18.toByte()),
    CLOSE(0x21.toByte());

    companion object {
        fun fromByte(b: Byte): BleRecordType? = entries.firstOrNull { it.typeCode == b }
    }
}

object BleRecordConstants {
    const val MAGIC: Byte = 0x47.toByte()
    const val HEADER_BYTES: Int = 8
    const val MAX_RECORD: Int = 16384
    const val MAX_FRAGMENTS: Int = 64
    const val MAX_CONCURRENT: Int = 4
    const val REASSEMBLY_TIMEOUT_SECONDS: Long = 30L
}

data class BleRecordHeader(
    val magic: Byte,
    val recordType: BleRecordType,
    val recordSeq: Int,
    val fragIndex: Int,
    val fragCount: Int,
    val totalLen: Int,
    val headerCheck: Byte,
)

class BleRecordFragment(
    val header: BleRecordHeader,
    payload: ByteArray,
) {
    val payload: ByteArray = payload.copyOf()

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is BleRecordFragment) return false
        return header == other.header && payload.contentEquals(other.payload)
    }

    override fun hashCode(): Int = 31 * header.hashCode() + payload.contentHashCode()
}

class BleReassembledRecord(
    val recordType: BleRecordType,
    val recordSeq: Int,
    payload: ByteArray,
) {
    val payload: ByteArray = payload.copyOf()

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is BleReassembledRecord) return false
        return recordType == other.recordType && recordSeq == other.recordSeq && payload.contentEquals(other.payload)
    }

    override fun hashCode(): Int {
        var result = recordType.hashCode()
        result = 31 * result + recordSeq
        result = 31 * result + payload.contentHashCode()
        return result
    }
}

object BleRecordCodec {

    fun computeHeaderCheck(
        b0: Byte,
        b1: Byte,
        b2: Byte,
        b3: Byte,
        b4: Byte,
        b5: Byte,
        b6: Byte,
    ): Byte {
        return (b0.toInt() xor b1.toInt() xor b2.toInt() xor b3.toInt() xor b4.toInt() xor b5.toInt() xor b6.toInt()).toByte()
    }

    fun computeHeaderCheck(bytes7: ByteArray): Byte {
        require(bytes7.size == 7) { "computeHeaderCheck requires exactly 7 bytes, got ${bytes7.size}" }
        return computeHeaderCheck(
            bytes7[0],
            bytes7[1],
            bytes7[2],
            bytes7[3],
            bytes7[4],
            bytes7[5],
            bytes7[6],
        )
    }

    fun canonicalFragmentBounds(totalLen: Int, fragCount: Int, fragIndex: Int): Pair<Int, Int> {
        if (totalLen == 0) {
            require(fragCount == 1 && fragIndex == 0) {
                "totalLen=0 requires fragCount=1, fragIndex=0; got count=$fragCount, index=$fragIndex"
            }
            return Pair(0, 0)
        }
        require(fragCount in 1..BleRecordConstants.MAX_FRAGMENTS) {
            "fragCount $fragCount outside 1..${BleRecordConstants.MAX_FRAGMENTS}"
        }
        require(fragIndex in 0 until fragCount) {
            "fragIndex $fragIndex outside 0 until $fragCount"
        }
        val stride = (totalLen + fragCount - 1) / fragCount
        val start = fragIndex * stride
        require(start < totalLen) {
            "canonical start $start >= totalLen $totalLen"
        }
        val end = minOf(start + stride, totalLen)
        return Pair(start, end)
    }

    fun encodeHeader(
        recordType: BleRecordType,
        recordSeq: Int,
        fragIndex: Int,
        fragCount: Int,
        totalLen: Int,
        magic: Byte = BleRecordConstants.MAGIC,
    ): ByteArray {
        require(recordSeq in 0..255) { "recordSeq $recordSeq outside 0..255" }
        require(fragCount in 1..BleRecordConstants.MAX_FRAGMENTS) {
            "fragCount $fragCount outside 1..${BleRecordConstants.MAX_FRAGMENTS}"
        }
        require(fragIndex in 0 until fragCount) {
            "fragIndex $fragIndex outside 0 until $fragCount"
        }
        require(totalLen in 0..BleRecordConstants.MAX_RECORD) {
            "totalLen $totalLen outside 0..${BleRecordConstants.MAX_RECORD}"
        }

        val b0 = magic
        val b1 = recordType.typeCode
        val b2 = recordSeq.toByte()
        val b3 = fragIndex.toByte()
        val b4 = fragCount.toByte()
        val b5 = ((totalLen ushr 8) and 0xFF).toByte()
        val b6 = (totalLen and 0xFF).toByte()
        val b7 = computeHeaderCheck(b0, b1, b2, b3, b4, b5, b6)

        return byteArrayOf(b0, b1, b2, b3, b4, b5, b6, b7)
    }

    fun decodeHeader(bytes: ByteArray): BleRecordHeader? {
        if (bytes.size < BleRecordConstants.HEADER_BYTES) return null

        val magic = bytes[0]
        if (magic != BleRecordConstants.MAGIC) return null

        val recordType = BleRecordType.fromByte(bytes[1]) ?: return null
        val recordSeq = bytes[2].toInt() and 0xFF
        val fragIndex = bytes[3].toInt() and 0xFF
        val fragCount = bytes[4].toInt() and 0xFF
        val totalLen = ((bytes[5].toInt() and 0xFF) shl 8) or (bytes[6].toInt() and 0xFF)
        val chk = bytes[7]

        val expectedChk = computeHeaderCheck(
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6]
        )
        if (chk != expectedChk) return null

        if (fragCount !in 1..BleRecordConstants.MAX_FRAGMENTS) return null
        if (fragIndex !in 0 until fragCount) return null
        if (totalLen !in 0..BleRecordConstants.MAX_RECORD) return null

        return BleRecordHeader(
            magic = magic,
            recordType = recordType,
            recordSeq = recordSeq,
            fragIndex = fragIndex,
            fragCount = fragCount,
            totalLen = totalLen,
            headerCheck = chk,
        )
    }

    fun decodeFragment(bytes: ByteArray): BleRecordFragment? {
        if (bytes.size < BleRecordConstants.HEADER_BYTES) return null

        val header = decodeHeader(bytes) ?: return null

        val (start, end) = try {
            canonicalFragmentBounds(header.totalLen, header.fragCount, header.fragIndex)
        } catch (_: Exception) {
            return null
        }

        val expectedPayloadLen = end - start
        val actualPayloadLen = bytes.size - BleRecordConstants.HEADER_BYTES
        if (actualPayloadLen != expectedPayloadLen) return null

        val payload = bytes.copyOfRange(BleRecordConstants.HEADER_BYTES, bytes.size)
        return BleRecordFragment(header = header, payload = payload)
    }
}

object BleRecordFragmenter {

    fun fragment(
        recordType: BleRecordType,
        recordSeq: Int,
        payload: ByteArray,
        maxAttValueLength: Int,
    ): List<ByteArray> {
        val capacity = maxAttValueLength - BleRecordConstants.HEADER_BYTES
        require(capacity >= 1) {
            "maxAttValueLength $maxAttValueLength must be >= ${BleRecordConstants.HEADER_BYTES + 1}"
        }

        val totalLen = payload.size
        require(totalLen <= BleRecordConstants.MAX_RECORD) {
            "payload size $totalLen exceeds MAX_RECORD ${BleRecordConstants.MAX_RECORD}"
        }

        if (totalLen == 0) {
            val hdr = BleRecordCodec.encodeHeader(recordType, recordSeq, 0, 1, 0)
            return listOf(hdr)
        }

        val fragCount = (totalLen + capacity - 1) / capacity
        require(fragCount <= BleRecordConstants.MAX_FRAGMENTS) {
            "fragCount $fragCount exceeds MAX_FRAGMENTS ${BleRecordConstants.MAX_FRAGMENTS}"
        }

        val stride = (totalLen + fragCount - 1) / fragCount
        val fragments = ArrayList<ByteArray>(fragCount)

        for (i in 0 until fragCount) {
            val start = i * stride
            val end = minOf(start + stride, totalLen)
            val fragPayload = payload.copyOfRange(start, end)
            val hdr = BleRecordCodec.encodeHeader(recordType, recordSeq, i, fragCount, totalLen)
            val fullFrag = ByteArray(BleRecordConstants.HEADER_BYTES + fragPayload.size)
            System.arraycopy(hdr, 0, fullFrag, 0, BleRecordConstants.HEADER_BYTES)
            System.arraycopy(fragPayload, 0, fullFrag, BleRecordConstants.HEADER_BYTES, fragPayload.size)
            fragments.add(fullFrag)
        }

        return fragments
    }
}

class BleRecordReassembler(
    private val clock: () -> Long = { System.currentTimeMillis() / 1000L },
) {
    private class InFlightAssembly(
        val recordType: BleRecordType,
        val totalLen: Int,
        val fragCount: Int,
        val stride: Int,
        val receivedIndices: MutableSet<Int>,
        val buffer: ByteArray,
        val createdTimeSec: Long,
        var lastActivityTimeSec: Long,
    )

    private val inFlight = HashMap<Int, InFlightAssembly>()
    private val completedFingerprints = HashMap<Int, String>()

    private fun evictExpired(nowSec: Long) {
        val expiredSeqs = inFlight.filter { (_, asm) ->
            (nowSec - asm.lastActivityTimeSec) > BleRecordConstants.REASSEMBLY_TIMEOUT_SECONDS
        }.keys.toList()

        for (seq in expiredSeqs) {
            inFlight.remove(seq)
        }
    }

    private fun computeFingerprint(recordType: BleRecordType, seq: Int, payload: ByteArray): String {
        val md = MessageDigest.getInstance("SHA-256")
        md.update(recordType.typeCode)
        md.update(seq.toByte())
        md.update(payload)
        return md.digest().joinToString("") { "%02x".format(it) }
    }

    fun receiveFragmentBytes(rawBytes: ByteArray): BleReassembledRecord? {
        val frag = BleRecordCodec.decodeFragment(rawBytes) ?: return null
        return receiveFragment(frag)
    }

    fun receiveFragment(frag: BleRecordFragment): BleReassembledRecord? {
        val nowSec = clock()
        evictExpired(nowSec)

        val hdr = frag.header
        val seq = hdr.recordSeq

        var asm = inFlight[seq]
        if (asm == null) {
            // Check capacity
            if (inFlight.size >= BleRecordConstants.MAX_CONCURRENT) {
                return null // Reject 5th concurrent assembly
            }

            val stride = if (hdr.totalLen > 0) (hdr.totalLen + hdr.fragCount - 1) / hdr.fragCount else 0
            asm = InFlightAssembly(
                recordType = hdr.recordType,
                totalLen = hdr.totalLen,
                fragCount = hdr.fragCount,
                stride = stride,
                receivedIndices = HashSet(),
                buffer = ByteArray(hdr.totalLen),
                createdTimeSec = nowSec,
                lastActivityTimeSec = nowSec,
            )
            inFlight[seq] = asm
        }

        // Validate metadata consistency
        if (asm.recordType != hdr.recordType || asm.totalLen != hdr.totalLen || asm.fragCount != hdr.fragCount) {
            // Conflicting metadata: invalidate and fail closed
            inFlight.remove(seq)
            return null
        }

        asm.lastActivityTimeSec = nowSec

        val (start, end) = try {
            BleRecordCodec.canonicalFragmentBounds(hdr.totalLen, hdr.fragCount, hdr.fragIndex)
        } catch (_: Exception) {
            inFlight.remove(seq)
            return null
        }

        // Check duplicate fragment index
        if (hdr.fragIndex in asm.receivedIndices) {
            val existingPayload = asm.buffer.copyOfRange(start, end)
            return if (existingPayload.contentEquals(frag.payload)) {
                // Idempotent duplicate: ignore
                null
            } else {
                // Conflicting duplicate: invalidate and fail closed
                inFlight.remove(seq)
                null
            }
        }

        // Store fragment payload
        System.arraycopy(frag.payload, 0, asm.buffer, start, end - start)
        asm.receivedIndices.add(hdr.fragIndex)

        // Check if complete
        if (asm.receivedIndices.size == asm.fragCount) {
            val completePayload = asm.buffer.copyOf()
            inFlight.remove(seq)

            val fp = computeFingerprint(hdr.recordType, seq, completePayload)
            if (completedFingerprints[seq] == fp) {
                // Duplicate retransmission of already completed record
                return null
            }

            completedFingerprints[seq] = fp
            return BleReassembledRecord(
                recordType = hdr.recordType,
                recordSeq = seq,
                payload = completePayload,
            )
        }

        return null
    }

    fun reset() {
        inFlight.clear()
        completedFingerprints.clear()
    }
}
