package io.godstone.mesh.router

import io.godstone.mesh.wire.v2.FrameV2
import io.godstone.mesh.wire.v2.TypeV2

/**
 * T40 (ADR-009, blueprint section 14) -- the anti-entropy control-plane
 * payload table, frozen here once for both isles.
 *
 * Every instance that represents a control payload shall define a method
 * named [encode]; the payload table as a whole defines the method named
 * [decode]. The two name the same function on both isles; the one table
 * crypto/anti_entropy_vectors.json (struck by the INDEPENDENT reference
 * wire/anti_entropy_vectors.py from crypto/gmp21.py alone) is the single
 * source of truth; the readiness courts of both isles read it and the
 * codecs must agree with it byte for byte.
 *
 * The wire table (no new outer codes -- the arms ride the frozen types):
 *
 *   digest             DIGEST 0x12  version u8(1) || snapshotId u64_be || bloom[512]
 *   want               WANT  0x14  version u8(1) || snapshotId u64_be || count u8(1..32) || msgID[count][16]
 *   inventory_request  HELLO 0x11  version || u8(1) || snapshotId u64_be || cursorPresent u8 || cursor[16]
 *   inventory_page     HELLO 0x11  version || u8(2) || snapshotId u64_be || done u8 || count u8 || msgID[count][16]
 *   reset              HELLO 0x11  version || u8(3) || newSnapshotId u64_be
 *   ping               PING  0x28  version u8(1) || reply u8(0..1) || nonce u64_be
 *
 * The envelope law: control frames carry control-only zero values (flags,
 * ttl, hop_count), are local to the authenticated link, are never forwarded,
 * never pass the generic expiration, and never enter held message storage.
 *
 * Decode is strict and fail-closed: every rejection carries one name from
 * [FAILURE_NAMES]; a rejected control mutates nothing.
 */
sealed class ControlPayloadV1 {

    /** Each arm defines its own encoder: the canonical bytes of the struct. */
    abstract fun encode(): ByteArray

    /** digest: version || snapshotId u64_be || bloom[512]. */
    class Digest(val snapshotId: Long, val bloom: ByteArray) : ControlPayloadV1() {
        init {
            if (snapshotId == 0L) throw ControlException(ControlDecodeFailure("zero_snapshot_id"))
            if (bloom.size != ControlPayloadV1.BLOOM_BYTES) throw ControlException(ControlDecodeFailure("wrong_size"))
        }
        override fun encode(): ByteArray {
            if (snapshotId == 0L) throw ControlException(ControlDecodeFailure("zero_snapshot_id"))
            if (bloom.size != ControlPayloadV1.BLOOM_BYTES) throw ControlException(ControlDecodeFailure("wrong_size"))
            val out = ByteArray(1 + 8 + ControlPayloadV1.BLOOM_BYTES)
            out[0] = ControlPayloadV1.VERSION.toByte()
            ControlPayloadV1.putU64Be(out, 1, snapshotId)
            bloom.copyInto(out, 9, 0, ControlPayloadV1.BLOOM_BYTES)
            return out
        }

        override fun equals(other: Any?): Boolean =
            other is Digest && other.snapshotId == snapshotId && other.bloom.contentEquals(bloom)

        override fun hashCode(): Int =
            31 * snapshotId.hashCode() + bloom.contentHashCode()

        override fun toString(): String = "digest(sid=$snapshotId,bloom=${bloom.size}B)"
    }

    /** want: version || snapshotId u64_be || count u8(1..32) || msgID[count][16], distinct. */
    class Want(val snapshotId: Long, val ids: List<ByteArray>) : ControlPayloadV1() {
        init {
            if (snapshotId == 0L) throw ControlException(ControlDecodeFailure("zero_snapshot_id"))
            if (ids.size < 1 || ids.size > ControlPayloadV1.MAX_IDS_PER_ARM) {
                throw ControlException(ControlDecodeFailure("count_out_of_range"))
            }
            if (!ControlPayloadV1.idsDistinct(ids)) throw ControlException(ControlDecodeFailure("duplicate_ids"))
            if (ids.any { it.size != ControlPayloadV1.ID_BYTES }) throw ControlException(ControlDecodeFailure("wrong_size"))
        }
        override fun encode(): ByteArray {
            if (snapshotId == 0L) throw ControlException(ControlDecodeFailure("zero_snapshot_id"))
            if (ids.isEmpty() || ids.size > ControlPayloadV1.MAX_IDS_PER_ARM) {
                throw ControlException(ControlDecodeFailure("count_out_of_range"))
            }
            if (!ControlPayloadV1.idsDistinct(ids)) throw ControlException(ControlDecodeFailure("duplicate_ids"))
            if (ids.any { it.size != ControlPayloadV1.ID_BYTES }) throw ControlException(ControlDecodeFailure("wrong_size"))
            val out = ByteArray(1 + 8 + 1 + 16 * ids.size)
            out[0] = ControlPayloadV1.VERSION.toByte()
            ControlPayloadV1.putU64Be(out, 1, snapshotId)
            out[9] = ids.size.toByte()
            var off = 10
            for (id in ids) { id.copyInto(out, off, 0, ControlPayloadV1.ID_BYTES); off += ControlPayloadV1.ID_BYTES }
            return out
        }

        override fun equals(other: Any?): Boolean =
            other is Want && other.snapshotId == snapshotId && ControlPayloadV1.idsEqual(other.ids, ids)

        override fun hashCode(): Int {
            var h = 31 * snapshotId.hashCode()
            for (id in ids) h = 31 * h + id.contentHashCode()
            return h
        }

        override fun toString(): String = "want(sid=$snapshotId,count=${ids.size})"
    }

    /**
     * HELLO subtype 1 -- inventory request. [cursorPresent] is explicit:
     * 0 denotes the start and REQUIRES the all-zero filler; 1 admits every
     * 16-byte cursor, including all-zero. Cursors are exclusive
     * lexicographic last-seen msgIDs, never SQL offsets.
     */
    class InventoryRequest(val snapshotId: Long, val cursorPresent: Int, val cursor: ByteArray) : ControlPayloadV1() {
        init {
            if (snapshotId == 0L) throw ControlException(ControlDecodeFailure("zero_snapshot_id"))
            if (cursorPresent != 0 && cursorPresent != 1) throw ControlException(ControlDecodeFailure("bad_cursor"))
            if (cursor.size != ControlPayloadV1.ID_BYTES) throw ControlException(ControlDecodeFailure("bad_cursor"))
            if (cursorPresent == 0 && !ControlPayloadV1.isZeroCursor(cursor)) {
                throw ControlException(ControlDecodeFailure("bad_cursor"))
            }
        }
        override fun encode(): ByteArray {
            if (snapshotId == 0L) throw ControlException(ControlDecodeFailure("zero_snapshot_id"))
            if (cursorPresent != 0 && cursorPresent != 1) throw ControlException(ControlDecodeFailure("bad_cursor"))
            if (cursor.size != ControlPayloadV1.ID_BYTES) throw ControlException(ControlDecodeFailure("bad_cursor"))
            if (cursorPresent == 0 && !ControlPayloadV1.isZeroCursor(cursor)) {
                throw ControlException(ControlDecodeFailure("bad_cursor"))
            }
            val out = ByteArray(2 + 8 + 1 + ControlPayloadV1.ID_BYTES)
            out[0] = ControlPayloadV1.VERSION.toByte()
            out[1] = ControlPayloadV1.SUBTYPE_INVENTORY_REQUEST.toByte()
            ControlPayloadV1.putU64Be(out, 2, snapshotId)
            out[10] = cursorPresent.toByte()
            cursor.copyInto(out, 11, 0, ControlPayloadV1.ID_BYTES)
            return out
        }

        override fun equals(other: Any?): Boolean =
            other is InventoryRequest && other.snapshotId == snapshotId &&
                other.cursorPresent == cursorPresent && other.cursor.contentEquals(cursor)

        override fun hashCode(): Int =
            31 * (31 * (31 * snapshotId.hashCode() + cursorPresent) + cursor.contentHashCode())

        override fun toString(): String = "inventory_request(sid=$snapshotId,cp=$cursorPresent)"
    }

    /**
     * HELLO subtype 2 -- inventory page. At most 32 ids; the empty page is
     * legal only with [done] set: "count 0 is allowed only with done=1".
     */
    class InventoryPage(val snapshotId: Long, val done: Int, val ids: List<ByteArray>) : ControlPayloadV1() {
        init {
            if (snapshotId == 0L) throw ControlException(ControlDecodeFailure("zero_snapshot_id"))
            if (done != 0 && done != 1) throw ControlException(ControlDecodeFailure("bad_done"))
            if (ids.size > ControlPayloadV1.MAX_IDS_PER_ARM) throw ControlException(ControlDecodeFailure("count_out_of_range"))
            if (done == 0 && ids.isEmpty()) throw ControlException(ControlDecodeFailure("bad_done"))
            if (!ControlPayloadV1.idsDistinct(ids)) throw ControlException(ControlDecodeFailure("duplicate_ids"))
            if (ids.any { it.size != ControlPayloadV1.ID_BYTES }) throw ControlException(ControlDecodeFailure("wrong_size"))
        }
        override fun encode(): ByteArray {
            if (snapshotId == 0L) throw ControlException(ControlDecodeFailure("zero_snapshot_id"))
            if (done != 0 && done != 1) throw ControlException(ControlDecodeFailure("bad_done"))
            if (ids.size > ControlPayloadV1.MAX_IDS_PER_ARM) throw ControlException(ControlDecodeFailure("count_out_of_range"))
            if (done == 0 && ids.isEmpty()) throw ControlException(ControlDecodeFailure("bad_done"))
            if (!ControlPayloadV1.idsDistinct(ids)) throw ControlException(ControlDecodeFailure("duplicate_ids"))
            if (ids.any { it.size != ControlPayloadV1.ID_BYTES }) throw ControlException(ControlDecodeFailure("wrong_size"))
            val out = ByteArray(2 + 8 + 2 + 16 * ids.size)
            out[0] = ControlPayloadV1.VERSION.toByte()
            out[1] = ControlPayloadV1.SUBTYPE_INVENTORY_PAGE.toByte()
            ControlPayloadV1.putU64Be(out, 2, snapshotId)
            out[10] = done.toByte()
            out[11] = ids.size.toByte()
            var off = 12
            for (id in ids) { id.copyInto(out, off, 0, ControlPayloadV1.ID_BYTES); off += ControlPayloadV1.ID_BYTES }
            return out
        }

        override fun equals(other: Any?): Boolean =
            other is InventoryPage && other.snapshotId == snapshotId && other.done == done &&
                ControlPayloadV1.idsEqual(other.ids, ids)

        override fun hashCode(): Int {
            var h = 31 * (31 * snapshotId.hashCode() + done)
            for (id in ids) h = 31 * h + id.contentHashCode()
            return h
        }

        override fun toString(): String = "inventory_page(sid=$snapshotId,done=$done,count=${ids.size})"
    }

    /** HELLO subtype 3 -- reset: the producer names the new snapshot. */
    class Reset(val newSnapshotId: Long) : ControlPayloadV1() {
        init {
            if (newSnapshotId == 0L) throw ControlException(ControlDecodeFailure("zero_snapshot_id"))
        }
        override fun encode(): ByteArray {
            if (newSnapshotId == 0L) throw ControlException(ControlDecodeFailure("zero_snapshot_id"))
            val out = ByteArray(2 + 8)
            out[0] = ControlPayloadV1.VERSION.toByte()
            out[1] = ControlPayloadV1.SUBTYPE_RESET.toByte()
            ControlPayloadV1.putU64Be(out, 2, newSnapshotId)
            return out
        }

        override fun equals(other: Any?): Boolean = other is Reset && other.newSnapshotId == newSnapshotId
        override fun hashCode(): Int = 31 * newSnapshotId.hashCode() + 7
        override fun toString(): String = "reset(newSid=$newSnapshotId)"
    }

    /**
     * ping (ADR-009 section 3: there is no PONG code and none is invented;
     * PING is its own answer). [reply] 0 = request, 1 = reply; a reply
     * echoes the [nonce] unchanged and is never answered.
     */
    class Ping(val reply: Int, val nonce: Long) : ControlPayloadV1() {
        init {
            if (reply != 0 && reply != 1) throw ControlException(ControlDecodeFailure("bad_reply"))
        }
        override fun encode(): ByteArray {
            if (reply != 0 && reply != 1) throw ControlException(ControlDecodeFailure("bad_reply"))
            val out = ByteArray(2 + 8)
            out[0] = ControlPayloadV1.VERSION.toByte()
            out[1] = reply.toByte()
            ControlPayloadV1.putU64Be(out, 2, nonce)
            return out
        }

        override fun equals(other: Any?): Boolean = other is Ping && other.reply == reply && other.nonce == nonce
        override fun hashCode(): Int = 31 * reply + nonce.hashCode()
        override fun toString(): String = "ping(reply=$reply,nonce=$nonce)"
    }

    /**
     * The typed failures of the decode path. One name, one cause; the two
     * isles name them identically (the alphabet travels with the vector
     * table's expect_failure strings).
     */
    class ControlDecodeFailure(val name: String) : Comparable<ControlDecodeFailure> {
        override fun compareTo(other: ControlDecodeFailure): Int = name.compareTo(other.name)
        override fun equals(other: Any?): Boolean = other is ControlDecodeFailure && other.name == name
        override fun hashCode(): Int = name.hashCode()
        override fun toString(): String = name
    }

    /** The builders validate their arguments and raise the named failures. */
    class ControlException(val failure: ControlDecodeFailure) : Exception(failure.name)

    /** decode returns a result, never a partial: Ok of the struct, Err of the name. */
    sealed class ControlDecodeResult {
        class Ok(val payload: ControlPayloadV1) : ControlDecodeResult()
        class Err(val failure: ControlDecodeFailure, val hint: String = "") : ControlDecodeResult()
    }

    /** The six arms; wireName is the table's spelling, outerCode the frozen frame type. */
    enum class ControlArm(val wireName: String, val outerCode: TypeV2) {
        DIGEST("digest", TypeV2.DIGEST),
        WANT("want", TypeV2.WANT),
        INVENTORY_REQUEST("inventory_request", TypeV2.HELLO),
        INVENTORY_PAGE("inventory_page", TypeV2.HELLO),
        RESET("reset", TypeV2.HELLO),
        PING("ping", TypeV2.PING),
        ;

        companion object {
            fun fromWireName(name: String): ControlArm? {
                for (arm in values()) if (arm.wireName == name) return arm
                return null
            }
        }
    }

    companion object {
        const val VERSION: Int = 1
        const val BLOOM_BYTES: Int = 512
        const val ID_BYTES: Int = 16
        const val MAX_IDS_PER_ARM: Int = 32
        const val SUBTYPE_INVENTORY_REQUEST: Int = 1
        const val SUBTYPE_INVENTORY_PAGE: Int = 2
        const val SUBTYPE_RESET: Int = 3

        /** The failure alphabet; every name must be exercised by a vector. */
        val FAILURE_NAMES: List<String> = listOf(
            "truncated", "wrong_size", "unsupported_version", "count_out_of_range",
            "duplicate_ids", "bad_cursor", "bad_done", "bad_reply",
            "zero_snapshot_id", "unknown_subtype", "sequence_break",
        )

        // ------------------------------------------------------------------
        // decode -- strict, fail-closed; mirrors the reference branch for branch
        // ------------------------------------------------------------------
        fun decode(arm: ControlArm, buf: ByteArray): ControlDecodeResult {
            when (arm) {
                ControlArm.DIGEST -> {
                    val need = 1 + 8 + BLOOM_BYTES
                    if (buf.size < need) return ControlDecodeResult.Err(ControlDecodeFailure("truncated"), "digest")
                    if (buf.size > need) return ControlDecodeResult.Err(ControlDecodeFailure("wrong_size"), "digest")
                    if (buf[0].toInt() and 0xFF != VERSION) return ControlDecodeResult.Err(ControlDecodeFailure("unsupported_version"), "digest")
                    val sid = u64Be(buf, 1)
                    if (sid == 0L) return ControlDecodeResult.Err(ControlDecodeFailure("zero_snapshot_id"), "digest")
                    return ControlDecodeResult.Ok(Digest(sid, buf.copyOfRange(9, 9 + BLOOM_BYTES)))
                }
                ControlArm.WANT -> {
                    if (buf.size < 10) return ControlDecodeResult.Err(ControlDecodeFailure("truncated"), "want")
                    if (buf[0].toInt() and 0xFF != VERSION) return ControlDecodeResult.Err(ControlDecodeFailure("unsupported_version"), "want")
                    val sid = u64Be(buf, 1)
                    if (sid == 0L) return ControlDecodeResult.Err(ControlDecodeFailure("zero_snapshot_id"), "want")
                    val count = buf[9].toInt() and 0xFF
                    if (count < 1 || count > MAX_IDS_PER_ARM) return ControlDecodeResult.Err(ControlDecodeFailure("count_out_of_range"), "want")
                    val need = 10 + 16 * count
                    if (buf.size < need) return ControlDecodeResult.Err(ControlDecodeFailure("truncated"), "want")
                    if (buf.size > need) return ControlDecodeResult.Err(ControlDecodeFailure("wrong_size"), "want")
                    val ids = ArrayList<ByteArray>(count)
                    for (k in 0 until count) ids.add(buf.copyOfRange(10 + 16 * k, 10 + 16 * (k + 1)))
                    if (!idsDistinct(ids)) return ControlDecodeResult.Err(ControlDecodeFailure("duplicate_ids"), "want")
                    return ControlDecodeResult.Ok(Want(sid, ids))
                }
                ControlArm.INVENTORY_REQUEST, ControlArm.INVENTORY_PAGE, ControlArm.RESET -> {
                    if (buf.size < 2) return ControlDecodeResult.Err(ControlDecodeFailure("truncated"), "hello")
                    if (buf[0].toInt() and 0xFF != VERSION) return ControlDecodeResult.Err(ControlDecodeFailure("unsupported_version"), "hello")
                    val subtype = buf[1].toInt() and 0xFF
                    when (subtype) {
                        SUBTYPE_INVENTORY_REQUEST -> {
                            if (arm != ControlArm.INVENTORY_REQUEST) return ControlDecodeResult.Err(ControlDecodeFailure("unknown_subtype"), "hello")
                            val need = 2 + 8 + 1 + 16
                            if (buf.size < need) return ControlDecodeResult.Err(ControlDecodeFailure("truncated"), "inventory_request")
                            if (buf.size > need) return ControlDecodeResult.Err(ControlDecodeFailure("wrong_size"), "inventory_request")
                            val sid = u64Be(buf, 2)
                            if (sid == 0L) return ControlDecodeResult.Err(ControlDecodeFailure("zero_snapshot_id"), "inventory_request")
                            val cp = buf[10].toInt() and 0xFF
                            if (cp != 0 && cp != 1) return ControlDecodeResult.Err(ControlDecodeFailure("bad_cursor"), "inventory_request")
                            val cursor = buf.copyOfRange(11, 27)
                            if (cp == 0 && !isZeroCursor(cursor)) return ControlDecodeResult.Err(ControlDecodeFailure("bad_cursor"), "inventory_request")
                            return ControlDecodeResult.Ok(InventoryRequest(sid, cp, cursor))
                        }
                        SUBTYPE_INVENTORY_PAGE -> {
                            if (arm != ControlArm.INVENTORY_PAGE) return ControlDecodeResult.Err(ControlDecodeFailure("unknown_subtype"), "hello")
                            if (buf.size < 4) return ControlDecodeResult.Err(ControlDecodeFailure("truncated"), "inventory_page")
                            val sid = u64Be(buf, 2)
                            if (sid == 0L) return ControlDecodeResult.Err(ControlDecodeFailure("zero_snapshot_id"), "inventory_page")
                            val done = buf[10].toInt() and 0xFF
                            val count = buf[11].toInt() and 0xFF
                            if (done != 0 && done != 1) return ControlDecodeResult.Err(ControlDecodeFailure("bad_done"), "inventory_page")
                            if (count > MAX_IDS_PER_ARM) return ControlDecodeResult.Err(ControlDecodeFailure("count_out_of_range"), "inventory_page")
                            if (done == 0 && count == 0) return ControlDecodeResult.Err(ControlDecodeFailure("bad_done"), "inventory_page")
                            val need = 12 + 16 * count
                            if (buf.size < need) return ControlDecodeResult.Err(ControlDecodeFailure("truncated"), "inventory_page")
                            if (buf.size > need) return ControlDecodeResult.Err(ControlDecodeFailure("wrong_size"), "inventory_page")
                            val ids = ArrayList<ByteArray>(count)
                            for (k in 0 until count) ids.add(buf.copyOfRange(12 + 16 * k, 12 + 16 * (k + 1)))
                            if (!idsDistinct(ids)) return ControlDecodeResult.Err(ControlDecodeFailure("duplicate_ids"), "inventory_page")
                            return ControlDecodeResult.Ok(InventoryPage(sid, done, ids))
                        }
                        SUBTYPE_RESET -> {
                            if (arm != ControlArm.RESET) return ControlDecodeResult.Err(ControlDecodeFailure("unknown_subtype"), "hello")
                            val need = 2 + 8
                            if (buf.size < need) return ControlDecodeResult.Err(ControlDecodeFailure("truncated"), "reset")
                            if (buf.size > need) return ControlDecodeResult.Err(ControlDecodeFailure("wrong_size"), "reset")
                            val sid = u64Be(buf, 2)
                            if (sid == 0L) return ControlDecodeResult.Err(ControlDecodeFailure("zero_snapshot_id"), "reset")
                            return ControlDecodeResult.Ok(Reset(sid))
                        }
                        else -> return ControlDecodeResult.Err(ControlDecodeFailure("unknown_subtype"), "hello")
                    }
                }
                ControlArm.PING -> {
                    val need = 2 + 8
                    if (buf.size < need) return ControlDecodeResult.Err(ControlDecodeFailure("truncated"), "ping")
                    if (buf.size > need) return ControlDecodeResult.Err(ControlDecodeFailure("wrong_size"), "ping")
                    if (buf[0].toInt() and 0xFF != VERSION) return ControlDecodeResult.Err(ControlDecodeFailure("unsupported_version"), "ping")
                    val reply = buf[1].toInt() and 0xFF
                    if (reply != 0 && reply != 1) return ControlDecodeResult.Err(ControlDecodeFailure("bad_reply"), "ping")
                    return ControlDecodeResult.Ok(Ping(reply, u64Be(buf, 2)))
                }
            }
        }

        /** Decode by the frame's outer code alone (the demultiplex path). */
        fun decodeFor(type: TypeV2, buf: ByteArray): ControlDecodeResult {
            val arm = when (type) {
                TypeV2.DIGEST -> ControlArm.DIGEST
                TypeV2.WANT -> ControlArm.WANT
                TypeV2.PING -> ControlArm.PING
                TypeV2.HELLO -> {
                    // HELLO carries three subtypes plus the bare hello; the
                    // second octet discriminates. A non-control hello is not
                    // this profile's creature: reject by name, mutate nothing.
                    if (buf.isEmpty() || buf[0].toInt() and 0xFF != VERSION) {
                        return ControlDecodeResult.Err(ControlDecodeFailure("unsupported_version"), "hello")
                    }
                    when (buf[1].toInt() and 0xFF) {
                        SUBTYPE_INVENTORY_REQUEST -> ControlArm.INVENTORY_REQUEST
                        SUBTYPE_INVENTORY_PAGE -> ControlArm.INVENTORY_PAGE
                        SUBTYPE_RESET -> ControlArm.RESET
                        else -> return ControlDecodeResult.Err(ControlDecodeFailure("unknown_subtype"), "hello")
                    }
                }
                else -> return ControlDecodeResult.Err(ControlDecodeFailure("unknown_subtype"), type.name)
            }
            return decode(arm, buf)
        }

        // ------------------------------------------------------------------
        // the encode helpers: builders that validate and name their failures
        // ------------------------------------------------------------------
        fun digest(snapshotId: Long, bloom: ByteArray): Digest = Digest(snapshotId, bloom.copyOf())
        fun want(snapshotId: Long, ids: List<ByteArray>): Want = Want(snapshotId, ids.map { it.copyOf() })
        fun inventoryRequest(snapshotId: Long, cursorPresent: Int, cursor: ByteArray): InventoryRequest =
            InventoryRequest(snapshotId, cursorPresent, cursor.copyOf())
        fun inventoryPage(snapshotId: Long, done: Int, ids: List<ByteArray>): InventoryPage =
            InventoryPage(snapshotId, done, ids.map { it.copyOf() })
        fun reset(newSnapshotId: Long): Reset = Reset(newSnapshotId)
        fun ping(reply: Int, nonce: Long): Ping = Ping(reply, nonce)

        /** Split the wanted ids into want payloads as the writer capacity requires. */
        fun wantSplit(snapshotId: Long, ids: List<ByteArray>, maxPerWant: Int): List<Want> {
            if (maxPerWant < 1 || maxPerWant > MAX_IDS_PER_ARM) {
                throw ControlException(ControlDecodeFailure("count_out_of_range"))
            }
            if (ids.isEmpty() || ids.size > MAX_IDS_PER_ARM) {
                throw ControlException(ControlDecodeFailure("count_out_of_range"))
            }
            if (!idsDistinct(ids)) throw ControlException(ControlDecodeFailure("duplicate_ids"))
            val out = ArrayList<Want>()
            var i = 0
            while (i < ids.size) {
                val to = minOf(i + maxPerWant, ids.size)
                out.add(Want(snapshotId, ids.subList(i, to).map { it.copyOf() }))
                i = to
            }
            return out
        }

        /** The frame as sent: frozen outer code, control-only zero envelope values. */
        fun frameFor(arm: ControlArm, msgId: ByteArray, routingTag: ByteArray, payload: ByteArray): FrameV2 {
            if (msgId.size != 16) throw ControlException(ControlDecodeFailure("wrong_size"))
            if (routingTag.size != 4) throw ControlException(ControlDecodeFailure("wrong_size"))
            return FrameV2(
                type = arm.outerCode,
                msgId = msgId.copyOf(),
                routingTag = routingTag.copyOf(),
                ttl = 0,
                hopCount = 0,
                flags = 0,
                payload = payload.copyOf(),
            )
        }

        // ------------------------------------------------------------------
        // the comparison helpers shared by both isles
        // ------------------------------------------------------------------
        /** Unsigned lexicographic order over equal-length octet vectors (u8 compare). */
        fun lexicographicCompare(a: ByteArray, b: ByteArray): Int {
            val n = minOf(a.size, b.size)
            for (k in 0 until n) {
                val x = a[k].toInt() and 0xFF
                val y = b[k].toInt() and 0xFF
                if (x != y) return if (x < y) -1 else 1
            }
            return a.size.compareTo(b.size)
        }

        fun idsEqual(x: List<ByteArray>, y: List<ByteArray>): Boolean {
            if (x.size != y.size) return false
            for (k in x.indices) if (!x[k].contentEquals(y[k])) return false
            return true
        }

        fun idsDistinct(ids: List<ByteArray>): Boolean {
            for (i in ids.indices) for (j in i + 1 until ids.size) {
                if (ids[i].contentEquals(ids[j])) return false
            }
            return true
        }

        fun isZeroCursor(cursor: ByteArray): Boolean {
            for (b in cursor) if (b.toInt() != 0) return false
            return true
        }

        fun u64Be(buf: ByteArray, off: Int): Long {
            var v = 0L
            for (k in 0 until 8) v = (v shl 8) or (buf[off + k].toLong() and 0xFFL)
            return v
        }

        fun putU64Be(dst: ByteArray, off: Int, v: Long) {
            for (k in 0 until 8) dst[off + k] = (v ushr (56 - 8 * k) and 0xFFL).toByte()
        }
    }
}
