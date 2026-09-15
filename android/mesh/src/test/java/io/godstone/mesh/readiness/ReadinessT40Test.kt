package io.godstone.mesh.readiness

// T40 readiness court (android isle) -- twin of ReadinessT40Tests.swift.
//
// The anti-entropy control plane (blueprint section 14, ADR-009): versioned
// payloads riding the EXISTING HELLO/DIGEST/WANT/PING codes, struck once by
// the independent reference (wire/anti_entropy_reference.py) from the one
// bloom authority (crypto/gmp21.py) into the one table
// (crypto/anti_entropy_vectors.json). Both isles' codecs are measured against
// THAT table -- cross-platform exact bytes: the isles must agree with the
// table, not merely with each other.
//
// Witnesses: W1 cross-platform exact bytes; W2 truncations and size
// disorders by their named failures; W3 the builders refuse duplicates and
// out-of-range counts; W4 sequence discipline on the received pages; W5 the
// stale digest is ignored and the tracked one stands; W6 the inventory walk
// wraps around the end; W7 the full 512-byte bloom travels the ATT leg at
// MTU 20; W8 a forced bloom collision converges -- through exact
// reconciliation alone; W9 eviction is forgotten by the fresh capture (a
// seen-based digest would remember: the semantic negative's first limb);
// W10 the snapshot authority's discipline (monotonic ids, rate, leases,
// budget, exhaustion, pinned pages); W11 the control campaign census: no
// control frame ever reaches held message storage, the seen window stays
// pure, and the sealed MESSAGE/SOS road remains open.

import io.godstone.core.crypto.Ed25519Keys
import io.godstone.core.crypto.X25519Keys
import io.godstone.mesh.MeshNode
import io.godstone.mesh.delivery.AckAuthenticator
import io.godstone.mesh.delivery.DeliveryTracker
import io.godstone.mesh.delivery.InMemoryStoreDeliveryRepository
import io.godstone.mesh.identity.Identity
import io.godstone.mesh.router.BloomDigest
import io.godstone.mesh.router.ControlPayloadV1
import io.godstone.mesh.router.InventorySnapshotAuthority
import io.godstone.mesh.router.Router
import io.godstone.mesh.router.StableInventorySnapshot
import io.godstone.mesh.router.SyncControlOwner
import io.godstone.mesh.store.InMemoryMessageStore
import io.godstone.mesh.store.MessageStore
import io.godstone.mesh.store.PersistResult
import io.godstone.mesh.transport.BleRecordFragmenter
import io.godstone.mesh.transport.BleRecordReassembler
import io.godstone.mesh.transport.BleRecordType
import io.godstone.mesh.wire.v2.FrameV2
import io.godstone.mesh.wire.v2.TypeV2
import java.security.SecureRandom
import kotlinx.coroutines.test.runTest
import org.junit.Assert
import org.junit.Test

class ReadinessT40Test {

    // ------------------------------------------------------------------
    // the one table, read whole (the court depends on the table)
    // ------------------------------------------------------------------

    @Volatile private var cachedTable: Table? = null

    private fun table(): Table {
        cachedTable?.let { return it }
        synchronized(this) {
            cachedTable?.let { return it }
            var dir = java.io.File(System.getProperty("user.dir"))
            while (!java.io.File(dir, "crypto").isDirectory) {
                dir = dir.parentFile ?: throw AssertionError("no repo root above user.dir")
            }
            val text = java.io.File(dir, "crypto/anti_entropy_vectors.json").readText()
            val t = Table(jObj(JsonReader(text).parseWhole()))
            cachedTable = t
            return t
        }
    }

    private fun armOf(name: String): ControlPayloadV1.ControlArm =
        ControlPayloadV1.ControlArm.fromWireName(name)
            ?: throw AssertionError("table names an unknown arm: $name")

    private fun unhex(s: String): ByteArray {
        val out = ByteArray(s.length / 2)
        for (k in out.indices) out[k] = s.substring(k * 2, k * 2 + 2).toInt(16).toByte()
        return out
    }

    // ------------------------------------------------------------------
    // fixtures
    // ------------------------------------------------------------------

    private fun newIdentity(): Identity {
        val rng = SecureRandom()
        val ed = Ed25519Keys.generate(rng)
        val dh = X25519Keys.generate(rng)
        return Identity.fromKeyMaterial(ed.pub, ed.priv, dh.pub, dh.priv)
    }

    private fun peerOf(seedByte: Int): ByteArray =
        ByteArray(16) { ((seedByte * 31 + it) and 0xFF).toByte() }

    private class NoAuth : AckAuthenticator {
        override fun verify(
            originalMsgId: ByteArray,
            expectedRecipientNodeId: ByteArray,
            ackFrame: FrameV2,
        ): Boolean = false
    }

    private fun messageFrame(msgId: ByteArray, payloadSize: Int = 40): FrameV2 = FrameV2(
        type = TypeV2.MESSAGE,
        msgId = msgId,
        routingTag = ByteArray(4),
        ttl = 4,
        hopCount = 0,
        flags = 3 shl 8,                          // priority BROADCAST in bits 9..8
        payload = ByteArray(payloadSize) { ((it * 7 + 3) and 0xFF).toByte() },
    )

    /** The deterministic evict-campaign id, pre-verified against
     * crypto/gmp21.py: octet 0 = 0xE4, octets 1..15 = the 15-digit
     * zero-padded decimal of k (ASCII). */
    private fun evictId(k: Int): ByteArray {
        val digits = k.toString().padStart(15, '0')
        return ByteArray(16) { if (it == 0) 0xE4.toByte() else digits[it - 1].code.toByte() }
    }

    /** A counting delegate: records every persist and every id ever seen. */
    private class CountingStore(val delegate: InMemoryMessageStore) : MessageStore by delegate {
        var persistCount = 0
            private set
        val seenAll = ArrayList<ByteArray>()
        override suspend fun persist(frame: FrameV2, receivedFrom: ByteArray): PersistResult {
            persistCount++
            seenAll.add(frame.msgId.copyOf())
            return delegate.persist(frame, receivedFrom)
        }
    }

    /** A store whose walk advances an injected clock: the read-budget trap. */
    private class BudgetTrapStore(
        val delegate: InMemoryMessageStore,
        private val advancePerVisit: Long,
        private val sink: (Long) -> Unit,
    ) : MessageStore by delegate {
        override suspend fun forEachHeldMsgId(visit: (ByteArray) -> Boolean) {
            for (id in delegate.allHeldMsgIds()) {
                sink(advancePerVisit)
                if (!visit(id)) return
            }
        }
    }

    private fun <T> List<T>.withIndex(): List<Pair<Int, T>> = mapIndexed { k, v -> Pair(k, v) }

    // ------------------------------------------------------------------
    // W1 -- cross-platform exact bytes
    // ------------------------------------------------------------------
    @Test
    fun testEncodeDecodeCrossPlatformExactBytes() {
        val t = table()
        Assert.assertEquals("version macro", 1, jLong(t.constants.req("version")).toInt())
        Assert.assertEquals("BLOOM_BYTES", 512, jLong(t.constants.req("bloom_bytes")).toInt())
        Assert.assertEquals("ID_BYTES", 16, jLong(t.constants.req("id_size_bytes")).toInt())
        Assert.assertEquals("MAX_IDS", 32, jLong(t.constants.req("max_ids_per_arm")).toInt())
        val sub = jObj(t.constants.req("subtype"))
        Assert.assertEquals("SUBTYPE request", 1, jLong(sub.req("inventory_request")).toInt())
        Assert.assertEquals("SUBTYPE page", 2, jLong(sub.req("inventory_page")).toInt())
        Assert.assertEquals("SUBTYPE reset", 3, jLong(sub.req("reset")).toInt())

        var encoded = 0
        var decoded = 0
        for (v in t.payloadVectors) {
            val name = jStr(v.req("name"))
            val arm = armOf(jStr(v.req("arm")))
            val input = jObj(v.req("input"))
            val struct = jObj(v.req("struct"))
            val want = unhex(jStr(v.req("payload_hex")))

            val built = when (arm) {
                ControlPayloadV1.ControlArm.DIGEST ->
                    ControlPayloadV1.digest(jLong(input.req("snapshot_id")), unhex(jStr(input.req("bloom"))))
                ControlPayloadV1.ControlArm.WANT ->
                    ControlPayloadV1.want(jLong(input.req("snapshot_id")), jArr(input.req("ids")).map { unhex(jStr(it)) })
                ControlPayloadV1.ControlArm.INVENTORY_REQUEST ->
                    ControlPayloadV1.inventoryRequest(
                        jLong(input.req("snapshot_id")),
                        jLong(input.req("cursor_present")).toInt(),
                        unhex(jStr(input.req("cursor"))),
                    )
                ControlPayloadV1.ControlArm.INVENTORY_PAGE ->
                    ControlPayloadV1.inventoryPage(
                        jLong(input.req("snapshot_id")),
                        jLong(input.req("done")).toInt(),
                        jArr(input.req("ids")).map { unhex(jStr(it)) },
                    )
                ControlPayloadV1.ControlArm.RESET ->
                    ControlPayloadV1.reset(jLong(input.req("new_snapshot_id")))
                ControlPayloadV1.ControlArm.PING ->
                    ControlPayloadV1.ping(jLong(input.req("reply")).toInt(), jLong(input.req("nonce")))
            }
            val bytes = built.encode()
            Assert.assertArrayEquals("$name: encode must equal the table octets", want, bytes)

            val r = ControlPayloadV1.decode(arm, bytes)
            Assert.assertTrue("$name: decode rejected a canonical payload", r is ControlPayloadV1.ControlDecodeResult.Ok)
            val got = (r as ControlPayloadV1.ControlDecodeResult.Ok).payload
            when (arm) {
                ControlPayloadV1.ControlArm.DIGEST -> {
                    val g = got as ControlPayloadV1.Digest
                    Assert.assertEquals("$name: sid", jLong(struct.req("snapshot_id")), g.snapshotId)
                    Assert.assertArrayEquals("$name: bloom", unhex(jStr(struct.req("bloom"))), g.bloom)
                }
                ControlPayloadV1.ControlArm.WANT -> {
                    val g = got as ControlPayloadV1.Want
                    Assert.assertEquals("$name: sid", jLong(struct.req("snapshot_id")), g.snapshotId)
                    Assert.assertEquals("$name: count", jLong(struct.req("count")).toInt(), g.ids.size)
                    val ids = jArr(struct.req("ids"))
                    for (k in ids.indices) {
                        Assert.assertArrayEquals("$name: ids[$k] order preserved", unhex(jStr(ids[k])), g.ids[k])
                    }
                }
                ControlPayloadV1.ControlArm.INVENTORY_REQUEST -> {
                    val g = got as ControlPayloadV1.InventoryRequest
                    Assert.assertEquals("$name: sid", jLong(struct.req("snapshot_id")), g.snapshotId)
                    Assert.assertEquals("$name: cursorPresent", jLong(struct.req("cursor_present")).toInt(), g.cursorPresent)
                    Assert.assertArrayEquals("$name: cursor", unhex(jStr(struct.req("cursor"))), g.cursor)
                }
                ControlPayloadV1.ControlArm.INVENTORY_PAGE -> {
                    val g = got as ControlPayloadV1.InventoryPage
                    Assert.assertEquals("$name: sid", jLong(struct.req("snapshot_id")), g.snapshotId)
                    Assert.assertEquals("$name: done", jLong(struct.req("done")).toInt(), g.done)
                    Assert.assertEquals("$name: count", jLong(struct.req("count")).toInt(), g.ids.size)
                    val ids = jArr(struct.req("ids"))
                    for (k in ids.indices) Assert.assertArrayEquals("$name: ids[$k]", unhex(jStr(ids[k])), g.ids[k])
                }
                ControlPayloadV1.ControlArm.RESET -> Assert.assertEquals(
                    "$name: new sid", jLong(struct.req("new_snapshot_id")), (got as ControlPayloadV1.Reset).newSnapshotId,
                )
                ControlPayloadV1.ControlArm.PING -> {
                    val g = got as ControlPayloadV1.Ping
                    Assert.assertEquals("$name: reply", jLong(struct.req("reply")).toInt(), g.reply)
                    Assert.assertEquals("$name: nonce", jLong(struct.req("nonce")), g.nonce)
                }
            }
            Assert.assertArrayEquals("$name: re-encode reproduces the very octets", want, got.encode())
            encoded++; decoded++
        }
        Assert.assertEquals("payload vectors encoded", 18, encoded)
        Assert.assertEquals("payload vectors decoded back", 18, decoded)

        var framed = 0
        for (f in t.frameVectors) {
            val name = jStr(f.req("name"))
            val arm = armOf(jStr(f.req("arm")))
            val wire = ControlPayloadV1.frameFor(
                arm,
                unhex(jStr(f.req("msg_id"))),
                unhex(jStr(f.req("routing_tag"))),
                unhex(jStr(f.req("payload_hex"))),
            )
            Assert.assertArrayEquals("$name: frame octets", unhex(jStr(f.req("frame_hex"))), wire.encode())
            Assert.assertEquals("$name: ttl keeps the control-only zero", 0, wire.ttl)
            Assert.assertEquals("$name: hop keeps the control-only zero", 0, wire.hopCount)
            Assert.assertEquals("$name: flags keep the control-only zero", 0, wire.flags)
            val back = FrameV2.decode(wire.encode())
            Assert.assertNotNull("$name: the frozen decoder refuses its own frame", back)
            back!!
            Assert.assertSame("$name: outer code", arm.outerCode, back.type)
            Assert.assertArrayEquals("$name: msg_id", wire.msgId, back.msgId)
            Assert.assertArrayEquals("$name: routing_tag", wire.routingTag, back.routingTag)
            Assert.assertArrayEquals("$name: payload", wire.payload, back.payload)
            framed++
        }
        Assert.assertEquals("frame vectors sealed and unsealed", 18, framed)
        Assert.assertSame("DIGEST rides 0x12", TypeV2.DIGEST, armOf("digest").outerCode)
        Assert.assertSame("WANT rides 0x14", TypeV2.WANT, armOf("want").outerCode)
        Assert.assertSame("PING rides 0x28", TypeV2.PING, armOf("ping").outerCode)
        for (n in listOf("inventory_request", "inventory_page", "reset")) {
            Assert.assertSame("$n rides HELLO", TypeV2.HELLO, armOf(n).outerCode)
        }
    }

    // ------------------------------------------------------------------
    // W2 -- every malformed payload refused by its named failure
    // ------------------------------------------------------------------
    @Test
    fun testDecodeRejectsEveryMalformedPayloadByItsName() {
        val t = table()
        var refusedCount = 0
        val namesSeen = LinkedHashSet<String>()
        for (m in t.malformedVectors) {
            val name = jStr(m.req("name"))
            val arm = armOf(jStr(m.req("arm")))
            val expected = jStr(m.req("expect_failure"))
            val raw = unhex(jStr(m.req("payload_hex")))
            val r = ControlPayloadV1.decode(arm, raw)
            Assert.assertTrue("$name: must refuse $expected, got $r", r is ControlPayloadV1.ControlDecodeResult.Err)
            val got = (r as ControlPayloadV1.ControlDecodeResult.Err).failure.name
            Assert.assertEquals("$name: failure name", expected, got)
            Assert.assertTrue("$name: name must be in the alphabet", ControlPayloadV1.FAILURE_NAMES.contains(got))
            val again = ControlPayloadV1.decode(arm, raw)
            Assert.assertTrue("$name: refusal is not stable", again is ControlPayloadV1.ControlDecodeResult.Err)
            Assert.assertEquals(
                "$name: refusal stable", got,
                (again as ControlPayloadV1.ControlDecodeResult.Err).failure.name,
            )
            namesSeen.add(got)
            refusedCount++
        }
        Assert.assertEquals("malformed vectors refused", 40, refusedCount)
        // the decoder's own alphabet is the ten wire laws; sequence_break is the
        // owner's law of the received stream, proven by W4 over the corrupted walks
        val decodeLaw = (ControlPayloadV1.FAILURE_NAMES.toSet() - "sequence_break")
        Assert.assertEquals(
            "every decoder-law name exercised (missing " + (decodeLaw - namesSeen) + ")",
            decodeLaw,
            namesSeen.toSet(),
        )
        Assert.assertEquals("the alphabet has eleven names", 11, ControlPayloadV1.FAILURE_NAMES.size)
        Assert.assertTrue("sequence_break stands reserved for the owner", namesSeen.none { it == "sequence_break" })
    }

    // ------------------------------------------------------------------
    // W3 -- the builders validate and name their rejects
    // ------------------------------------------------------------------
    @Test
    fun testBuilderValidationNamesTheRejects() {
        var checked = 0
        fun expectRaise(what: String, name: String, block: () -> Unit) {
            try {
                block()
                throw AssertionError("$what: must have raised $name")
            } catch (e: ControlPayloadV1.ControlException) {
                Assert.assertEquals("$what: failure name", name, e.failure.name)
            }
            checked++
        }
        val a = ByteArray(16) { (it and 0xFF).toByte() }
        val b = ByteArray(16) { ((it + 1) and 0xFF).toByte() }

        expectRaise("want 33 ids", "count_out_of_range") {
            ControlPayloadV1.want(7L, (0..32).map { n -> ByteArray(16) { (it + n + 1).toByte() } })
        }
        expectRaise("want empty", "count_out_of_range") { ControlPayloadV1.want(7L, emptyList()) }
        expectRaise("want duplicates", "duplicate_ids") { ControlPayloadV1.want(7L, listOf(a, b, a)) }
        expectRaise("want a 15-octet id", "wrong_size") { ControlPayloadV1.want(7L, listOf(ByteArray(15))) }
        expectRaise("want zero sid", "zero_snapshot_id") { ControlPayloadV1.want(0L, listOf(a)) }
        expectRaise("page done=0 empty", "bad_done") { ControlPayloadV1.inventoryPage(7L, 0, emptyList()) }
        expectRaise("page done=2", "bad_done") { ControlPayloadV1.inventoryPage(7L, 2, listOf(a)) }
        expectRaise("page 33 ids", "count_out_of_range") {
            ControlPayloadV1.inventoryPage(7L, 1, (0..32).map { n -> ByteArray(16) { (it + n + 1).toByte() } })
        }
        expectRaise("page duplicates", "duplicate_ids") { ControlPayloadV1.inventoryPage(7L, 0, listOf(a, a)) }
        expectRaise("request cp=2", "bad_cursor") { ControlPayloadV1.inventoryRequest(7L, 2, ByteArray(16)) }
        expectRaise("request cp=0 with a non-zero filler", "bad_cursor") {
            ControlPayloadV1.inventoryRequest(7L, 0, ByteArray(16) { if (it == 15) 1 else 0 })
        }
        expectRaise("request a 15-octet cursor", "bad_cursor") { ControlPayloadV1.inventoryRequest(7L, 1, ByteArray(15)) }
        expectRaise("request zero sid", "zero_snapshot_id") { ControlPayloadV1.inventoryRequest(0L, 0, ByteArray(16)) }
        expectRaise("digest short bloom", "wrong_size") { ControlPayloadV1.digest(1L, ByteArray(511)) }
        expectRaise("digest zero sid", "zero_snapshot_id") { ControlPayloadV1.digest(0L, ByteArray(512)) }
        expectRaise("reset zero sid", "zero_snapshot_id") { ControlPayloadV1.reset(0L) }
        expectRaise("ping reply=2", "bad_reply") { ControlPayloadV1.ping(2, 9L) }
        expectRaise("frame with a 15-octet msg_id", "wrong_size") {
            ControlPayloadV1.frameFor(ControlPayloadV1.ControlArm.PING, ByteArray(15), ByteArray(4), ByteArray(10))
        }
        expectRaise("frame with a 3-octet tag", "wrong_size") {
            ControlPayloadV1.frameFor(ControlPayloadV1.ControlArm.PING, ByteArray(16), ByteArray(3), ByteArray(10))
        }
        expectRaise("wantSplit maxPerWant=0", "count_out_of_range") { ControlPayloadV1.wantSplit(7L, listOf(a), 0) }
        expectRaise("wantSplit maxPerWant=33", "count_out_of_range") { ControlPayloadV1.wantSplit(7L, listOf(a), 33) }
        expectRaise("wantSplit over the arm bound", "count_out_of_range") {
            ControlPayloadV1.wantSplit(7L, (0 until 40).map { n -> ByteArray(16) { (it + n + 1).toByte() } }, 16)
        }
        val ids = (0 until 30).map { n -> ByteArray(16) { (it + n + 1).toByte() } }
        val parts = ControlPayloadV1.wantSplit(7L, ids, 16)
        Assert.assertEquals("the split keeps its measures", listOf(16, 14), parts.map { it.ids.size })
        Assert.assertArrayEquals("order preserved at the head", ids[0], parts[0].ids[0])
        Assert.assertArrayEquals("order preserved at the tail", ids[29], parts[1].ids[13])
        Assert.assertTrue("builder validations counted ($checked)", checked >= 22)
    }

    // ------------------------------------------------------------------
    // W4 -- sequence discipline on the received pages
    // ------------------------------------------------------------------
    @Test
    fun testSequenceDisciplineOnReceivedPages() {
        val t = table()
        val store = InMemoryMessageStore()
        var tnow = 1_000L
        val authority = InventorySnapshotAuthority(store, { tnow })
        val owner = SyncControlOwner(store, authority, { tnow }, peerOf(9))
        val peer = peerOf(7)
        val bloom = ByteArray(512)                      // the walk is about the sequence
        val rel = owner.relationFor(peer)

        runTest {
            val digest = ControlPayloadV1.digest(42L, bloom)
            val df = ControlPayloadV1.frameFor(
                ControlPayloadV1.ControlArm.DIGEST, ByteArray(16) { (it + 3).toByte() }, ByteArray(4), digest.encode(),
            )
            Assert.assertTrue("digest adopted", owner.handleControlFrame(df, peer) is SyncControlOwner.OwnerDecision.Accepted)
            Assert.assertTrue("the run opens", owner.startInventoryRun(peer))
            val first = owner.pumpNextInventoryFrames(peer)
            Assert.assertEquals("one request frame on the opening turn", 1, first.size)
            val d0 = ControlPayloadV1.decodeFor(first[0].type, first[0].payload)
            Assert.assertTrue("the request is canonical", d0 is ControlPayloadV1.ControlDecodeResult.Ok)
            val req0 = (d0 as ControlPayloadV1.ControlDecodeResult.Ok).payload as ControlPayloadV1.InventoryRequest
            Assert.assertEquals("the walk starts at the beginning", 0, req0.cursorPresent)
            Assert.assertArrayEquals("with the all-zero filler", ByteArray(16), req0.cursor)

            val clean = t.walkVectors.first { jStr(it.req("name")) == "walk_100_by_32" }
            val pages = jArr(clean.req("pages")).map { jObj(it) }
            val pumpedWants = ArrayList<FrameV2>()
            var fed = 0
            for ((k, pageObj) in pages.withIndex()) {
                val p = ControlPayloadV1.inventoryPage(
                    pageSid(pageObj, clean),
                    jLong(pageObj.req("done")).toInt(),
                    jArr(pageObj.req("ids")).map { unhex(jStr(it)) },
                )
                val pf = ControlPayloadV1.frameFor(
                    ControlPayloadV1.ControlArm.INVENTORY_PAGE,
                    ByteArray(16) { (it + 11 + k).toByte() }, ByteArray(4), p.encode(),
                )
                val dec = owner.handleControlFrame(pf, peer)
                Assert.assertTrue("page ${k + 1} accepted, got $dec", dec is SyncControlOwner.OwnerDecision.Accepted)
                fed++
                if (k == 1) {
                    val more = owner.pumpNextInventoryFrames(peer)
                    pumpedWants.addAll(more.filter { it.type == TypeV2.WANT })
                    val rq = more.firstOrNull { it.type == TypeV2.HELLO }
                    Assert.assertNotNull("the walk continues with a request", rq)
                    val rd = ControlPayloadV1.decodeFor(rq!!.type, rq.payload)
                    val r2 = (rd as ControlPayloadV1.ControlDecodeResult.Ok).payload as ControlPayloadV1.InventoryRequest
                    val cont = t.payloadVectors.first { jStr(it.req("name")) == "request_continuation" }
                    Assert.assertArrayEquals(
                        "the resumable cursor names the very next request the table strikes",
                        unhex(jStr(cont.req("payload_hex"))), r2.encode(),
                    )
                    val lastOfSecond = jArr(pages[1].req("ids")).let { it[it.size - 1] }
                    Assert.assertArrayEquals("after page 2 the run waits on the right page", unhex(jStr(lastOfSecond)), r2.cursor)
                }
            }
            Assert.assertEquals("pages fed", rel.pagesReceived, fed)
            Assert.assertEquals("the run closed by the final done", true, rel.runDone)
            Assert.assertNull("the coherent stream certifies", owner.checkSequence(rel))

            // the advertisement of this node speaks only of its captured vector:
            // the store holds nothing, so the filter must be empty -- though
            // thirty-six received ids wait unclaimed in the queue (a digest
            // built from the seen-but-unheld union would paint bits here and
            // be taken)
            val advert = owner.buildDigestFrame()
            Assert.assertNotNull("the node cannot advertise its store", advert)
            Assert.assertArrayEquals("the advertisement is the empty vector's own bloom",
                ByteArray(512), advert!!.second.bloom)
            Assert.assertEquals("thirty-six received ids wait unclaimed", 36, rel.wantQueue.size)

            val wants = owner.pumpNextInventoryFrames(peer)          // the wants drain after the close
            pumpedWants.addAll(wants.filter { it.type == TypeV2.WANT })
            Assert.assertEquals("the missing ids are requested in four want frames", 4, pumpedWants.size)
            var requested = 0
            for (f in pumpedWants) {
                val wd = ControlPayloadV1.decodeFor(f.type, f.payload)
                val w = (wd as ControlPayloadV1.ControlDecodeResult.Ok).payload as ControlPayloadV1.Want
                Assert.assertTrue("a want never exceeds the arm bound", w.ids.size <= 32)
                requested += w.ids.size
            }
            Assert.assertEquals("every received-but-unheld id was requested", 100, requested)

            for ((idx, cv) in t.walkVectors.filter { it.optStr("expect_failure") != null }.withIndex()) {
                val cpeer = peerOf(20 + idx)                          // a fresh relation per stream
                val crel = owner.relationFor(cpeer)
                val dd = ControlPayloadV1.digest(jLong(cv.req("snapshot_id")), bloom)
                val df2 = ControlPayloadV1.frameFor(
                    ControlPayloadV1.ControlArm.DIGEST, ByteArray(16) { (it + 3).toByte() }, ByteArray(4), dd.encode(),
                )
                owner.handleControlFrame(df2, cpeer)
                Assert.assertTrue("stream ${jStr(cv.req("name"))} opens", owner.startInventoryRun(cpeer))
                owner.pumpNextInventoryFrames(cpeer)                  // the opening request
                var verdict: SyncControlOwner.OwnerDecision = SyncControlOwner.OwnerDecision.Accepted
                for (pageObj in jArr(cv.req("pages")).map { jObj(it) }) {
                    val p = ControlPayloadV1.inventoryPage(
                        pageSid(pageObj, cv),
                        jLong(pageObj.req("done")).toInt(),
                        jArr(pageObj.req("ids")).map { unhex(jStr(it)) },
                    )
                    val pf = ControlPayloadV1.frameFor(
                        ControlPayloadV1.ControlArm.INVENTORY_PAGE, ByteArray(16) { (it + 5).toByte() }, ByteArray(4), p.encode(),
                    )
                    val dec = owner.handleControlFrame(pf, cpeer)
                    if (dec !is SyncControlOwner.OwnerDecision.Accepted) { verdict = dec; break }
                }
                val expected = jStr(cv.req("expect_failure"))
                val cert = owner.checkSequence(crel)
                val named = when {
                    verdict is SyncControlOwner.OwnerDecision.Refused -> (verdict as SyncControlOwner.OwnerDecision.Refused).reason
                    cert != null -> cert
                    else -> "no failure detected"
                }
                Assert.assertEquals(
                    "corrupted stream ${jStr(cv.req("name"))} must be named $expected (verdict=$verdict cert=$cert)",
                    expected, named,
                )
            }
        }
    }

    // ------------------------------------------------------------------
    // W5 -- the stale digest is ignored; the tracked one stands
    // ------------------------------------------------------------------
    @Test
    fun testStaleDigestIsIgnoredTheTrackedOneStands() {
        val t = table()
        val store = InMemoryMessageStore()
        val authority = InventorySnapshotAuthority(store, { 1_000L })
        val owner = SyncControlOwner(store, authority, { 1_000L }, peerOf(9))
        val peer = peerOf(7)
        val basic = t.payloadVectors.first { jStr(it.req("name")) == "digest_basic" }
        val good = ControlPayloadV1.digest(42L, unhex(jStr(jObj(basic.req("input")).req("bloom"))))

        fun feed(d: ControlPayloadV1.Digest): SyncControlOwner.OwnerDecision {
            val f = ControlPayloadV1.frameFor(
                ControlPayloadV1.ControlArm.DIGEST,
                ByteArray(16) { (it + 3).toByte() }, ByteArray(4) { (it + 1).toByte() }, d.encode(),
            )
            var out: SyncControlOwner.OwnerDecision = SyncControlOwner.OwnerDecision.Accepted
            runTest { out = owner.handleControlFrame(f, peer) }
            return out
        }

        val rel = owner.relationFor(peer)
        Assert.assertTrue("the first digest is adopted", feed(good) is SyncControlOwner.OwnerDecision.Accepted)
        Assert.assertEquals("the tracked sid", 42L, rel.trackedSid)
        val held = rel.trackedBloom!!
        Assert.assertArrayEquals("the tracked bloom is the table's own", good.bloom, held)

        val stale = ControlPayloadV1.digest(41L, ByteArray(512) { 0xEE.toByte() })
        val sres = feed(stale)
        Assert.assertTrue("the stale digest must be ignored, got $sres", sres is SyncControlOwner.OwnerDecision.Ignored)
        Assert.assertEquals("stale reason", "stale digest", (sres as SyncControlOwner.OwnerDecision.Ignored).reason)
        Assert.assertEquals("the tracked sid stands", 42L, rel.trackedSid)
        Assert.assertArrayEquals("the tracked bloom stands", held, rel.trackedBloom!!)

        // the very same sid reaffirms: the bloom copy is refreshed, the sid does not move
        val sameSidOtherBloom = ControlPayloadV1.digest(42L, ByteArray(512))
        Assert.assertTrue("reaffirmation is accepted", feed(sameSidOtherBloom) is SyncControlOwner.OwnerDecision.Accepted)
        Assert.assertEquals("the sid does not move", 42L, rel.trackedSid)
        Assert.assertArrayEquals("the bloom copy is refreshed", sameSidOtherBloom.bloom, rel.trackedBloom!!)

        // a newer sid is adopted; an open run over the elder is discarded
        Assert.assertTrue("the run opens for the walk", owner.startInventoryRun(peer))
        Assert.assertEquals("the run rides the tracked sid", 42L, rel.runSid)
        val newer = ControlPayloadV1.digest(43L, held)
        Assert.assertTrue("the newer digest is adopted", feed(newer) is SyncControlOwner.OwnerDecision.Accepted)
        Assert.assertEquals("the newer sid is tracked", 43L, rel.trackedSid)
        Assert.assertEquals("the elder run is discarded", 0L, rel.runSid)
        Assert.assertEquals("and nothing was counted on it", 0, rel.pagesReceived)
    }

    // ------------------------------------------------------------------
    // W6 -- the inventory walk wraps around the end
    // ------------------------------------------------------------------
    @Test
    fun testInventoryWalksWrapAroundTheEnd() {
        val t = table()
        val store = InMemoryMessageStore()
        var tnow = 1_000L
        val authority = InventorySnapshotAuthority(store, { tnow })
        runTest {
            for ((k, hx) in t.storeIds.withIndex()) {
                store.persist(messageFrame(unhex(hx), 8), peerOf(k and 0x7F))
            }
            val snap = authority.forceSnapshot()
            Assert.assertNotNull("the capture must not be deferred", snap)
            snap!!
            Assert.assertEquals("the captured vector holds the store's ids", 100, snap.ids.size)
            for (k in 1 until snap.ids.size) {
                Assert.assertTrue(
                    "the vector is lexicographically sorted at $k",
                    ControlPayloadV1.lexicographicCompare(snap.ids[k - 1], snap.ids[k]) < 0,
                )
            }
            val clean = t.walkVectors.first { jStr(it.req("name")) == "walk_100_by_32" }
            val pages = jArr(clean.req("pages")).map { jObj(it) }
            Assert.assertEquals("the walk needs four pages", 4, pages.size)
            var cursor: ByteArray? = null
            var walked = 0
            for ((k, p) in pages.withIndex()) {
                val page = snap.pageAfter(cursor, 32)
                Assert.assertEquals("page ${k + 1} done", jLong(p.req("done")).toInt(), page.done)
                Assert.assertEquals("page ${k + 1} count", jLong(p.req("count")).toInt(), page.ids.size)
                val ids = jArr(p.req("ids"))
                for (m in ids.indices) Assert.assertArrayEquals("page ${k + 1} id $m", unhex(jStr(ids[m])), page.ids[m])
                if (page.ids.isNotEmpty()) cursor = page.ids[page.ids.size - 1]
                walked++
            }
            Assert.assertEquals("pages walked", 4, walked)
            val after = snap.pageAfter(cursor, 32)
            val ae = jObj(clean.req("after_end_empty"))
            Assert.assertEquals("the page past the end is done", jLong(ae.req("done")).toInt(), after.done)
            Assert.assertEquals("and empty", jLong(ae.req("count")).toInt(), after.ids.size)
            val restart = snap.pageAfter(null, 32)
            val rz = jObj(clean.req("restart_from_zero"))
            Assert.assertEquals("restart count", jLong(rz.req("count")).toInt(), restart.ids.size)
            Assert.assertEquals("restart done", jLong(rz.req("done")).toInt(), restart.done)
            val rzids = jArr(rz.req("ids"))
            for (m in rzids.indices) Assert.assertArrayEquals("restart id $m", unhex(jStr(rzids[m])), restart.ids[m])

            // the pages are pinned to the captured vector: new holds do not disturb a running walk
            store.persist(messageFrame(evictId(900_001), 8), peerOf(1))
            store.persist(messageFrame(evictId(900_002), 8), peerOf(2))
            val pinned = snap.pageAfter(null, 32)
            Assert.assertArrayEquals("the first page is pinned to the capture", restart.ids[0], pinned.ids[0])
            Assert.assertEquals("the vector keeps its count", 100, snap.ids.size)
            Assert.assertEquals("while the store grew by two", 102, store.allHeldMsgIds().size)

            var raised = 0
            try { snap.pageAfter(cursor, 33) } catch (e: ControlPayloadV1.ControlException) {
                Assert.assertEquals("the page size over the arm bound", "count_out_of_range", e.failure.name); raised++
            }
            try { snap.pageAfter(cursor, 0) } catch (e: ControlPayloadV1.ControlException) {
                Assert.assertEquals("the page size under the arm bound", "count_out_of_range", e.failure.name); raised++
            }
            try { snap.pageAfter(ByteArray(15), 32) } catch (e: ControlPayloadV1.ControlException) {
                Assert.assertEquals("a 15-octet cursor is no cursor", "bad_cursor", e.failure.name); raised++
            }
            Assert.assertEquals("walker bounds exercised", 3, raised)

            // ordinary new holds do not restart the active immutable snapshot
            tnow += 1_000
            val again = authority.currentSnapshot()
            Assert.assertSame("the active snapshot stands", snap, again)
        }
    }

    // ------------------------------------------------------------------
    // W7 -- the full 512-byte bloom travels the ATT leg at MTU 20
    // ------------------------------------------------------------------
    @Test
    fun testFullBloomTravelsTheAtTwentyByteLink() {
        val t = table()
        val att = t.att
        val frameHex = jStr(att.req("reassembled_frame_hex"))
        val frags = jArr(att.req("fragments_hex")).map { unhex(jStr(it)) }
        val maxAtt = jLong(att.req("max_att_value_length")).toInt()
        val seq = jLong(att.req("record_seq")).toInt()
        val rtype = recordTypeOf(jLong(att.req("record_type")).toInt())
        Assert.assertEquals("the MTU of the smallest legal leg", 20, maxAtt)
        Assert.assertSame("control DATA rides the DATA record", BleRecordType.DATA, rtype)

        val mine = BleRecordFragmenter.fragment(rtype, seq, unhex(frameHex), maxAtt)
        Assert.assertEquals("the fragment count agrees with the table", frags.size, mine.size)
        Assert.assertEquals("the count is 47", 47, mine.size)
        for (k in mine.indices) Assert.assertArrayEquals("fragment $k agrees with the table", frags[k], mine[k])
        for ((k, f) in mine.withIndex()) Assert.assertTrue("fragment $k fits one ATT value", f.size <= maxAtt)

        val reas = BleRecordReassembler(clock = { 0L })
        var rec: io.godstone.mesh.transport.BleReassembledRecord? = null
        for ((k, f) in mine.withIndex()) {
            rec = reas.receiveFragmentBytes(f)
            if (k < mine.size - 1) Assert.assertNull("no early reassembly at $k", rec)
        }
        Assert.assertNotNull("the last fragment completes the record", rec)
        rec!!
        Assert.assertArrayEquals("the reassembled frame is the frame that was sent", unhex(frameHex), rec.payload)
        Assert.assertSame("of the DATA type", rtype, rec.recordType)
        Assert.assertEquals("with the sequence kept", seq, rec.recordSeq)

        val wire = FrameV2.decode(rec.payload)
        Assert.assertNotNull("the frozen envelope decodes", wire)
        wire!!
        Assert.assertSame("DIGEST", TypeV2.DIGEST, wire.type)
        Assert.assertEquals("flags stay zero", 0, wire.flags)
        Assert.assertEquals("ttl stays zero", 0, wire.ttl)
        Assert.assertEquals("hop stays zero", 0, wire.hopCount)
        val r = ControlPayloadV1.decode(ControlPayloadV1.ControlArm.DIGEST, wire.payload)
        Assert.assertTrue("the digest payload decodes", r is ControlPayloadV1.ControlDecodeResult.Ok)
        val dg = (r as ControlPayloadV1.ControlDecodeResult.Ok).payload as ControlPayloadV1.Digest
        Assert.assertEquals("the full bloom travels unabridged", 512, dg.bloom.size)
        val basic = t.payloadVectors.first { jStr(it.req("name")) == "digest_basic" }
        Assert.assertArrayEquals(
            "octet for octet with the gmp21-struck bloom",
            unhex(jStr(jObj(basic.req("struct")).req("bloom"))), dg.bloom,
        )
        val bd = BloomDigest()
        for (hx in t.storeIds) bd.add(unhex(hx))
        Assert.assertArrayEquals("the production bloom agrees with the authority", dg.bloom, bd.toBytes())
        var bits = 0
        for (b in dg.bloom) bits += Integer.bitCount(b.toInt() and 0xFF)
        Assert.assertTrue("the filter is neither empty nor saturated: bits=$bits", bits in 250..650)
        Assert.assertArrayEquals("the short digest is the head of the filter", dg.bloom.copyOfRange(0, 20), bd.shortDigest())
    }

    private fun recordTypeOf(code: Int): BleRecordType =
        BleRecordType.values().first { (it.typeCode.toInt() and 0xFF) == code }

    // ------------------------------------------------------------------
    // W8 -- a forced bloom collision converges by exact reconciliation
    // ------------------------------------------------------------------
    @Test
    fun testForcedBloomCollisionConvergesByExactReconciliation() {
        val t = table()
        val coll = t.collision
        val realIds = jArr(coll.req("store")).map { jStr(it) }
        val foreign = unhex(jStr(coll.req("foreign")))
        val indices = jArr(coll.req("indices")).map { jLong(it).toInt() }
        Assert.assertEquals("one foreign id pressed against the filter", 16, foreign.size)
        Assert.assertEquals("four rounds probe it", 4, indices.size)

        val storeA = InMemoryMessageStore()
        val storeB = InMemoryMessageStore()
        var tA = 1_000L
        val authA = InventorySnapshotAuthority(storeA, { tA })
        val authB = InventorySnapshotAuthority(storeB, { tA })
        val ownerA = SyncControlOwner(storeA, authA, { tA }, peerOf(1))
        val ownerB = SyncControlOwner(storeB, authB, { tA }, peerOf(2))
        val peerA = peerOf(1)
        val peerB = peerOf(2)

        runTest {
            val digestA = BloomDigest()
            for ((k, hx) in realIds.withIndex()) {
                storeA.persist(messageFrame(unhex(hx), 16), peerB)
                digestA.add(unhex(hx))
            }
            Assert.assertTrue(
                "the table's own digest and ours are one", digestA.toBytes().contentEquals(unhex(jStr(coll.req("digest_hex")))),
            )
            Assert.assertTrue(
                "the foreign id is truly absent from A", storeA.allHeldMsgIds().none { it.contentEquals(foreign) },
            )
            Assert.assertTrue("the filter swears the foreign id may be there", digestA.mightContain(foreign))
            for ((k, idx) in indices.withIndex()) {
                val byte = idx / 8
                val bit = 1 shl (idx % 8)
                Assert.assertTrue("round $k index $idx is set in A's filter", digestA.toBytes()[byte].toInt() and bit != 0)
            }

            // B holds the colliding id alone and would offer it; A's filter,
            // a false positive, suppresses the offering -- the digest-only
            // exchange would conceal the frame forever.
            storeB.persist(messageFrame(foreign, 24), peerA)
            val routerB = Router(storeB, peerOf(2))
            val suppressed = routerB.framesPeerLacks(digestA, 32)
            Assert.assertEquals("the digest-only exchange suppresses the colliding id", 0, suppressed.size)

            // exact reconciliation: A walks B's captured inventory
            val dresB = ownerB.buildDigestFrame()
            Assert.assertNotNull("B can build its digest", dresB)
            dresB!!
            Assert.assertEquals("B's bloom is full width", 512, dresB.second.bloom.size)
            val relA = ownerA.relationFor(peerB)
            Assert.assertTrue(
                "A adopts B's digest",
                ownerA.handleControlFrame(dresB.first, peerB) is SyncControlOwner.OwnerDecision.Accepted,
            )
            Assert.assertEquals("A tracks B's snapshot", dresB.second.snapshotId, relA.trackedSid)
            Assert.assertTrue("A opens the run", ownerA.startInventoryRun(peerB))
            val request = ownerA.pumpNextInventoryFrames(peerB).first { it.type == TypeV2.HELLO }

            // B answers with the page that lists the exact id
            val bVerdict = ownerB.handleControlFrame(request, peerA)
            Assert.assertTrue("B delivers a page, got $bVerdict", bVerdict is SyncControlOwner.OwnerDecision.Delivered)
            val answerPages = (bVerdict as SyncControlOwner.OwnerDecision.Delivered).frames
            Assert.assertEquals("one page frame", 1, answerPages.size)
            val pdec = ControlPayloadV1.decodeFor(answerPages[0].type, answerPages[0].payload)
            val page = (pdec as ControlPayloadV1.ControlDecodeResult.Ok).payload as ControlPayloadV1.InventoryPage
            Assert.assertEquals("the page lists exactly the id B holds", 1, page.ids.size)
            Assert.assertArrayEquals("the exact id, bytewise", foreign, page.ids[0])

            // A receives the page: absent locally, the id waits in the want queue
            val aVerdict = ownerA.handleControlFrame(answerPages[0], peerB)
            Assert.assertTrue("A accepts the page, got $aVerdict", aVerdict is SyncControlOwner.OwnerDecision.Accepted)
            Assert.assertEquals("one page received", 1, relA.pagesReceived)
            Assert.assertTrue("the run is closed by the done", relA.runDone)
            Assert.assertNull("the stream certifies", ownerA.checkSequence(relA))
            Assert.assertEquals("the want queue holds the one missing id", 1, relA.wantQueue.size)
            Assert.assertArrayEquals("waiting for the exact id", foreign, relA.wantQueue[0])

            // A must not advertise what it does not hold: the digest the owner
            // builds now speaks over A's own captured vector only -- were it
            // built from the seen-but-unheld union (the queue below holds the
            // very foreign id), the filter bits would differ from the vector's
            // own bloom and the card's first negative stands condemned
            val aAdvert = ownerA.buildDigestFrame()
            Assert.assertNotNull("A can advertise its own store", aAdvert)
            val aVector = authA.currentSnapshotOrNull()
            Assert.assertNotNull("the vector stands captured", aVector)
            val honest = BloomDigest()
            for (vid in aVector!!.ids) honest.add(vid)
            Assert.assertArrayEquals("the advertisement is the captured vector's own bloom", honest.toBytes(), aAdvert!!.second.bloom)
            Assert.assertEquals("one id waits in the queue", 1, relA.wantQueue.size)

            // A pumps the want (the drain runs even when the page walk is done); B answers from the store
            val wantFrames = ownerA.pumpNextInventoryFrames(peerB).filter { it.type == TypeV2.WANT }
            Assert.assertEquals("one want frame", 1, wantFrames.size)
            val wdec = ControlPayloadV1.decode(ControlPayloadV1.ControlArm.WANT, wantFrames[0].payload)
            val want = (wdec as ControlPayloadV1.ControlDecodeResult.Ok).payload as ControlPayloadV1.Want
            Assert.assertEquals("asking for one id", 1, want.ids.size)
            val bAnswer = ownerB.handleControlFrame(wantFrames[0], peerA)
            Assert.assertTrue("B answers", bAnswer is SyncControlOwner.OwnerDecision.Delivered)
            val answers = (bAnswer as SyncControlOwner.OwnerDecision.Delivered).frames
            Assert.assertEquals("the held frame is delivered", 1, answers.size)
            Assert.assertArrayEquals("with the very msg_id that collides", foreign, answers[0].msgId)
            Assert.assertEquals("bytes as stored, verbatim", 24, answers[0].payload.size)

            // A converges: the once-suppressed id is now durably A's own
            tA += 30_001
            val before = storeA.allHeldMsgIds().size
            storeA.persist(answers[0], peerB)
            val after = storeA.allHeldMsgIds().size
            Assert.assertEquals("A gained exactly one frame", 1, after - before)
            Assert.assertTrue("the converged id is held by A now", storeA.allHeldMsgIds().any { it.contentEquals(foreign) })
            val snapA = authA.forceSnapshot()
            Assert.assertNotNull("A can capture its grown store", snapA)
            Assert.assertTrue("the captured vector includes the convergee", snapA!!.contains(foreign))
            Assert.assertEquals("and all that B ever listed", 121, snapA.ids.size)
        }
    }

    // ------------------------------------------------------------------
    // W9 -- eviction is forgotten by the fresh capture
    // ------------------------------------------------------------------
    @Test
    fun testEvictionIsForgottenByTheFreshCapture() {
        val total = 200
        val payloadSize = 256                        // bytesOf = payload + 64; three fit under 1000
        val store = InMemoryMessageStore(maxBytes = 1_000)
        val ever = ArrayList<ByteArray>()
        var tnow = 1_000L
        val authority = InventorySnapshotAuthority(store, { tnow })
        runTest {
            for (k in 0 until total) {
                val id = evictId(k)
                store.persist(messageFrame(id, payloadSize), peerOf(k and 0x7F))
                ever.add(id)                          // what the node has ever seen, held or not
            }
            val survivors = store.allHeldMsgIds()
            Assert.assertTrue("the hard cap evicted: survivors=${survivors.size}", survivors.size in 1..6)
            val kept = survivors.toSet()
            val evicted = ever.filter { e -> kept.none { it.contentEquals(e) } }
            Assert.assertTrue("the head of the campaign was evicted (${evicted.size} of them)", evicted.size >= total - 6)

            val snap = authority.forceSnapshot()
            Assert.assertNotNull("the fresh capture succeeds", snap)
            snap!!
            Assert.assertEquals("the vector holds what the store holds", survivors.size, snap.ids.size)
            for (s in survivors) Assert.assertTrue("a survivor is present", snap.contains(s))
            for (e in evicted) Assert.assertFalse("the evicted are forgotten by the capture", snap.contains(e))

            val fresh = BloomDigest()
            for (id in snap.ids) fresh.add(id)
            var forgotten = 0
            for (e in evicted) if (!fresh.mightContain(e)) forgotten++
            Assert.assertEquals("every evicted id is forgotten by the fresh digest", evicted.size, forgotten)
            for (s in survivors) Assert.assertTrue("every held id is remembered", fresh.mightContain(s))

            // the semantic negative: a digest built from the SEEN list -- every
            // id that ever passed through, held or not -- would remember what
            // the store forgot; had the implementation taken that source, the
            // assertions above could not all hold
            val seen = BloomDigest()
            for (id in ever) seen.add(id)
            for (e in evicted) Assert.assertTrue("the seen-based construction would remember the evicted", seen.mightContain(e))
            Assert.assertFalse("the two sources tell different truths", fresh.toBytes().contentEquals(seen.toBytes()))

            val pinned = authority.currentSnapshot()
            Assert.assertSame("the active snapshot stays pinned until expiry or rebuild", snap, pinned)
            Assert.assertEquals("and still tells of the survivors only", survivors.size, pinned!!.ids.size)
            Assert.assertEquals("seen-all counted", total, ever.size)
            Assert.assertEquals("survivors counted", survivors.size, kept.size)
        }
    }

    // ------------------------------------------------------------------
    // W10 -- the snapshot authority's discipline
    // ------------------------------------------------------------------
    @Test
    fun testSnapshotAuthorityKeepsTheLaw() {
        val store = InMemoryMessageStore()
        runTest {
            store.persist(messageFrame(evictId(1), 8), peerOf(1))
            store.persist(messageFrame(evictId(2), 8), peerOf(2))
            var tnow = 1_000L
            val authority = InventorySnapshotAuthority(store, { tnow })

            var previous = 0L
            for (k in 1..5) {
                val sid = authority.nextSnapshotId()
                Assert.assertNotNull("allocation $k", sid)
                Assert.assertTrue("the id is nonzero", sid != 0L)
                Assert.assertTrue("the ids are strictly monotonic over $previous", sid!! > previous)
                previous = sid
            }

            val doomed = InventorySnapshotAuthority(store, { tnow }, firstId = Long.MAX_VALUE - 1L)
            val last = doomed.nextSnapshotId()
            Assert.assertEquals("the last lawful id", Long.MAX_VALUE, last)
            Assert.assertNull("one past the end refuses", doomed.nextSnapshotId())
            Assert.assertTrue("the context is retired", doomed.isRetired())
            Assert.assertNull("retired: no capture", doomed.forceSnapshot())
            Assert.assertEquals("and it says why", 1, doomed.refusedByExhaustion())

            val t0 = InventorySnapshotAuthority(store, { tnow })
            val s1 = t0.forceSnapshot()
            Assert.assertNotNull("the first force captures", s1)
            tnow += 1
            Assert.assertNull("within the build gap the force is spent", t0.forceSnapshot())
            Assert.assertEquals("the deferral was counted", 1, t0.deferredByRate())
            tnow += 300_000
            Assert.assertNotNull("after the gap a fresh capture succeeds", t0.forceSnapshot())

            // the leases: at most two outstanding; an expired snapshot is never served
            val leased = InventorySnapshotAuthority(store, { tnow })
            val l1 = leased.forceSnapshot()
            Assert.assertNotNull("first capture", l1)
            Assert.assertTrue("lease the current", leased.acquire(l1!!.snapshotId))
            tnow += 30_001
            val l2 = leased.forceSnapshot()
            Assert.assertNotNull("the successor builds while one lease stands open", l2)
            Assert.assertTrue("the elder is kept as the referenced predecessor", leased.acquire(l2!!.snapshotId))
            Assert.assertEquals("the successor rides above the elder", true, l2.snapshotId > l1.snapshotId)
            tnow += 300_001                                     // the current expired; both leased: no build
            Assert.assertNull("the expired one is never served, the rebuild defers", leased.currentSnapshot())
            Assert.assertEquals("deferred by leases", 1, leased.deferredByLeases())
            Assert.assertTrue("release the elder", leased.release(l1.snapshotId))
            Assert.assertTrue("release the current", leased.release(l2.snapshotId))
            Assert.assertEquals("no leases remain", 0, leased.leasedOf(l2.snapshotId))
            tnow += 30_001
            val l3 = leased.currentSnapshot()
            Assert.assertNotNull("once leases free, the rebuild proceeds", l3)
            Assert.assertTrue("with a fresh monotonic id", l3!!.snapshotId > l2.snapshotId)

            // the read budget: a walk that outlasts its two seconds aborts safely
            val trap = BudgetTrapStore(store, 1_001L) { dt -> tnow += dt }
            val budgeted = InventorySnapshotAuthority(trap, { tnow })
            tnow += 40_000
            Assert.assertNull("the capture aborts when the walk overruns", budgeted.forceSnapshot())
            Assert.assertEquals("the abort was counted", 1, budgeted.abortedByBudget())
            Assert.assertNull("and nothing was installed", budgeted.currentSnapshotOrNull())

            var raised = 0
            try {
                StableInventorySnapshot.of(5L, (0..100_000).map { evictId(it) }, 0L)
            } catch (e: ControlPayloadV1.ControlException) {
                Assert.assertEquals("rows over the bound", "count_out_of_range", e.failure.name); raised++
            }
            try {
                StableInventorySnapshot.of(5L, listOf(ByteArray(15)), 0L)
            } catch (e: ControlPayloadV1.ControlException) {
                Assert.assertEquals("an id of the wrong width", "wrong_size", e.failure.name); raised++
            }
            try {
                StableInventorySnapshot.of(5L, listOf(evictId(1), evictId(1)), 0L)
            } catch (e: ControlPayloadV1.ControlException) {
                Assert.assertEquals("a vector is of distinct ids", "duplicate_ids", e.failure.name); raised++
            }
            try {
                StableInventorySnapshot.of(0L, listOf(evictId(1)), 0L)
            } catch (e: ControlPayloadV1.ControlException) {
                Assert.assertEquals("the id is nonzero", "zero_snapshot_id", e.failure.name); raised++
            }
            Assert.assertEquals("the gate refused four", 4, raised)

            // an ordinary new hold does not restart the active snapshot; the
            // consumer's pages stay pinned to the vector it walked
            val steady = InventorySnapshotAuthority(store, { tnow })
            tnow += 40_000
            val before = steady.forceSnapshot()
            Assert.assertNotNull(before)
            store.persist(messageFrame(evictId(4242), 8), peerOf(3))
            tnow += 5
            val after = steady.currentSnapshot()
            Assert.assertSame("the active snapshot stands unrestarted", before, after)
            val page = after!!.pageAfter(null, 32)
            Assert.assertEquals("the pinned page tells only what its capture saw", 2, page.ids.size)
            Assert.assertFalse("the later hold is no part of the pinned vector", page.ids.any { it.contentEquals(evictId(4242)) })
            Assert.assertEquals("leases open at zero", 0, steady.leasedOf(after.snapshotId))
        }
    }

    // ------------------------------------------------------------------
    // W11 -- control frames never enter held message storage
    // ------------------------------------------------------------------
    @Test
    fun testControlCampaignNeverTouchesTheDurableStore() {
        val t = table()
        val counting = CountingStore(InMemoryMessageStore())
        val peer = peerOf(7)
        val rigStore = InMemoryMessageStore()
        val tracker = DeliveryTracker(InMemoryStoreDeliveryRepository(rigStore), NoAuth())
        val node = MeshNode(
            ctx = null,
            identity = newIdentity(),
            store = counting,
            deliveryTracker = tracker,
        )
        val byName = t.payloadVectors.associateBy { jStr(it.req("name")) }
        val CONTROL_ID = unhex("0A0B0C0D0E0F1011121314151617 1819".replace(" ", ""))

        fun controlFrame(arm: ControlPayloadV1.ControlArm, payload: ByteArray): FrameV2 = FrameV2(
            type = arm.outerCode,
            msgId = CONTROL_ID,
            routingTag = ByteArray(4),
            ttl = 0,
            hopCount = 0,
            flags = 0,
            payload = payload,
        )

        fun payloadOf(name: String): ByteArray = unhex(jStr(byName.getValue(name).req("payload_hex")))

        // (frame, must the ingress accept it?) -- the page is unsolicited (no
        // run was ever opened through the node) and the bulk pair and GOODBYE
        // are refused in this profile
        val campaign = listOf(
            Triple("ping", controlFrame(ControlPayloadV1.ControlArm.PING, payloadOf("ping_request")), true),
            Triple("digest", controlFrame(ControlPayloadV1.ControlArm.DIGEST, payloadOf("digest_basic")), true),
            Triple("want", controlFrame(ControlPayloadV1.ControlArm.WANT, payloadOf("want_mid")), true),
            Triple("request", controlFrame(ControlPayloadV1.ControlArm.INVENTORY_REQUEST, payloadOf("request_start")), true),
            Triple("page", controlFrame(ControlPayloadV1.ControlArm.INVENTORY_PAGE, payloadOf("page_mid")), false),
            Triple("reset", controlFrame(ControlPayloadV1.ControlArm.RESET, payloadOf("reset_min")), true),
            Triple("bulk offer", refusedFrame(TypeV2.BULK_OFFER), false),
            Triple("bulk chunk", refusedFrame(TypeV2.BULK_CHUNK), false),
            Triple("goodbye", refusedFrame(TypeV2.GOODBYE), false),
        )

        var accepted = 0
        var refused = 0
        val decisions = LinkedHashMap<String, SyncControlOwner.OwnerDecision>()
        runTest {
            for ((k, triple) in campaign.withIndex()) {
                val (label, frame, expectAccept) = triple
                val verdict = node.ingestInbound(frame, peer)
                Assert.assertEquals("control campaign leg $k ($label)", expectAccept, verdict)
                decisions[label] = node.lastControlDecision
                if (expectAccept) accepted++ else refused++
            }
            Assert.assertEquals(
                "the unsolicited page was ignored, not held",
                "unsolicited page",
                decisionReason(decisions.getValue("page")),
            )
            Assert.assertEquals("nothing entered held storage from the campaign", 0, counting.persistCount)
            Assert.assertEquals("and the seen list stands empty", 0, counting.seenAll.size)
            Assert.assertEquals("controls accepted", 5, accepted)
            Assert.assertEquals("profiles refused", 4, refused)

            // the answers that the owner produced rode back out: the ping
            // reply echoes the very nonce; the stale request was answered
            // with the reset naming the fresh sid plus the current digest
            val out = node.drainControlOutbox()
            val replies = out.filter { it.type == TypeV2.PING }
            Assert.assertEquals("the ping was answered once", 1, replies.size)
            val pr = ControlPayloadV1.decode(ControlPayloadV1.ControlArm.PING, replies[0].payload)
            Assert.assertTrue("the reply is canonical", pr is ControlPayloadV1.ControlDecodeResult.Ok)
            val pingBack = (pr as ControlPayloadV1.ControlDecodeResult.Ok).payload as ControlPayloadV1.Ping
            Assert.assertEquals("replying, not requesting", 1, pingBack.reply)
            Assert.assertEquals(
                "echoing the very nonce",
                jLong(jObj(byName.getValue("ping_request").req("struct")).req("nonce")),
                pingBack.nonce,
            )
            Assert.assertTrue("the stale request drew the reset pair (${out.size} out)", out.any { it.type == TypeV2.HELLO })
            Assert.assertTrue("and the current digest", out.any { it.type == TypeV2.DIGEST })
            Assert.assertEquals("three frames rode the outbox", 3, out.size)

            // the sealed road remains open: MESSAGE and SOS pass as ever they did
            val msg = messageFrame(evictId(777), 32)
            Assert.assertTrue("a MESSAGE is still accepted", node.ingestInbound(msg, peer))
            Assert.assertEquals("and reached the durable store", 1, counting.persistCount)
            Assert.assertArrayEquals("the very id the node saw", msg.msgId, counting.seenAll[0])
            val sos = FrameV2(
                type = TypeV2.SOS,
                msgId = evictId(778),
                routingTag = ByteArray(4),
                ttl = 4,
                hopCount = 0,
                flags = FrameV2.SEALED or FrameV2.ACK_REQ or FrameV2.RELAY_OK,
                payload = ByteArray(16),
            )
            Assert.assertTrue("an SOS is still accepted", node.ingestInbound(sos, peer))
            Assert.assertEquals("both arrived", 2, counting.persistCount)

            // the purity of the seen window: a control frame's msg_id, reused
            // by a MESSAGE, is held for the first time -- the window never saw
            // the control that carried it
            val asMessage = messageFrame(CONTROL_ID, 20)
            Assert.assertTrue("the re-used id is novel to the store", node.ingestInbound(asMessage, peer))
            Assert.assertEquals("persisted, not suppressed by any control", 3, counting.persistCount)
            Assert.assertTrue("the store holds it", counting.delegate.allHeldMsgIds().any { it.contentEquals(CONTROL_ID) })
        }
    }

    private fun refusedFrame(type: TypeV2): FrameV2 = FrameV2(
        type = type,
        msgId = unhex("0F0E0D0C0B0A090807060504030201 00".replace(" ", "")),
        routingTag = ByteArray(4),
        ttl = 4,
        hopCount = 0,
        flags = 3 shl 8,
        payload = ByteArray(8),
    )

    private fun decisionReason(d: SyncControlOwner.OwnerDecision): String = when (d) {
        is SyncControlOwner.OwnerDecision.Ignored -> d.reason
        is SyncControlOwner.OwnerDecision.Refused -> d.reason
        else -> "accepted"
    }

    /**
     * GS-SYNC-001 (the audit's charge): "Inventory receiver accepts more than its bounded run page
     * budget." The receiver retains every verified page and advances `pagesReceived` without
     * consulting MAX_PAGES_PER_RUN -- which boundeth the PRODUCER (:271) and the PUMP (:385/:400)
     * only. The bound must be imposed AT THIS BOUNDARY, before any mutation.
     */
    @Test
    fun testTheReceiverRefusethTheFirstPageBeyondItsRunBudget() = runTest {
        val out = StringBuilder()
        val store = InMemoryMessageStore()
        val authority = InventorySnapshotAuthority(store, { 1_000L })
        val owner = SyncControlOwner(store, authority, { 1_000L }, ByteArray(16) { (it + 9).toByte() })
        val peer = ByteArray(16) { (it + 7).toByte() }
        // the court's OWN digest vector: the bloom must be the payload-bound size
        val t = table()
        val basic = t.payloadVectors.first { jStr(it.req("name")) == "digest_basic" }
        val bloom = unhex(jStr(jObj(basic.req("input")).req("bloom")))
        val digestFrame = ControlPayloadV1.frameFor(
            ControlPayloadV1.ControlArm.DIGEST,
            ByteArray(16) { (it + 3).toByte() }, ByteArray(4) { (it + 1).toByte() },
            ControlPayloadV1.digest(42L, bloom).encode(),
        )
        val adopted = owner.handleControlFrame(digestFrame, peer)
        val opened = owner.startInventoryRun(peer)
        val rel = owner.relationFor(peer)
        out.appendLine("adopted=$adopted opened=$opened runSid=${rel.runSid}")
        for (k in 0 until SyncControlOwner.MAX_PAGES_PER_RUN + 3) {
            val id = ByteArray(16).also { b -> b[0] = ((k + 1) ushr 8).toByte(); b[1] = ((k + 1) and 0xFF).toByte() }
            val payload = ControlPayloadV1.inventoryPage(rel.runSid, 0, listOf(id)).encode()
            val frame = ControlPayloadV1.frameFor(
                ControlPayloadV1.ControlArm.INVENTORY_PAGE,
                ByteArray(16) { (it + 21 + k).toByte() }, ByteArray(4) { (it + 2).toByte() }, payload,
            )
            val verdict = owner.handleControlFrame(frame, peer)
            if (k >= SyncControlOwner.MAX_PAGES_PER_RUN - 4) {
                out.appendLine("page=${k + 1} verdict=$verdict delivered=${rel.delivered.size} recv=${rel.pagesReceived} runDone=${rel.runDone}")
            }
            // GS-SYNC-001: the RECEIVER's own bound. The FIRST page beyond MAX_PAGES_PER_RUN must be
            // REFUSED at this boundary, BEFORE any mutation -- the receiver may not retain more page
            // descriptors than the run's budget, and MAX_PAGES_PER_RUN already boundeth only the
            // PRODUCER (`producerPagesSent`) and the PUMP (`pagesRequested`), never `pagesReceived`.
            if (k == SyncControlOwner.MAX_PAGES_PER_RUN) {
                Assert.assertFalse(
                    "the page beyond the run budget must be REFUSED, not accepted (delivered=${rel.delivered.size}, recv=${rel.pagesReceived})",
                    verdict is SyncControlOwner.OwnerDecision.Accepted,
                )
            }
        }
        out.appendLine("final delivered=${rel.delivered.size} recv=${rel.pagesReceived}")
        java.io.File("/tmp/gs-sync-001-diag.txt").writeText(out.toString())
        Assert.assertEquals("nothing beyond the budget may be RETAINED",
                            SyncControlOwner.MAX_PAGES_PER_RUN, rel.delivered.size)
        Assert.assertEquals("nor may the run's received-page counter pass it",
                            SyncControlOwner.MAX_PAGES_PER_RUN, rel.pagesReceived)
    }
}

// ----------------------------------------------------------------------
// file-scope JSON apparatus for the one table (the court reads it whole)
// ----------------------------------------------------------------------

private sealed class Json {
    class Obj(val members: LinkedHashMap<String, Json> = LinkedHashMap()) : Json()
    class Arr(val elements: ArrayList<Json> = ArrayList()) : Json()
    class Str(val value: String) : Json()
    class Num(val raw: String) : Json()
}

private class JsonReader(private val src: String) {
    private var i = 0
    fun parseWhole(): Json { val v = readValue(); return v }
    private fun readValue(): Json {
        ws()
        if (i >= src.length) throw IllegalStateException("json: end of input")
        return when (val c = src[i]) {
            '{' -> readObj()
            '[' -> readArr()
            '"' -> Json.Str(readStr())
            else -> if (c == '-' || c in '0'..'9') readNum()
            else throw IllegalStateException("json: unexpected '$c' at $i")
        }
    }
    private fun readObj(): Json.Obj {
        val o = Json.Obj(); expect('{'); ws()
        if (peek() == '}') { i++; return o }
        while (true) {
            ws(); val k = readStr(); ws(); expect(':'); o.members[k] = readValue(); ws()
            when (src[i++]) { ',' -> continue; '}' -> return o; else -> throw IllegalStateException("json obj at $i") }
        }
    }
    private fun readArr(): Json.Arr {
        val a = Json.Arr(); expect('['); ws()
        if (peek() == ']') { i++; return a }
        while (true) {
            a.elements.add(readValue()); ws()
            when (src[i++]) { ',' -> continue; ']' -> return a; else -> throw IllegalStateException("json arr at $i") }
        }
    }
    private fun readStr(): String {
        ws(); expect('"'); val sb = StringBuilder()
        while (true) {
            val c = src[i++]
            if (c == '"') return sb.toString()
            if (c == '\\') {
                sb.append(when (val e = src[i++]) {
                    'n' -> '\n'; 't' -> '\t'; 'r' -> '\r'; '"' -> '"'; '\\' -> '\\'; '/' -> '/'
                    else -> throw IllegalStateException("json escape $e")
                })
            } else sb.append(c)
        }
    }
    private fun readNum(): Json.Num {
        val start = i
        if (src[i] == '-') i++
        while (i < src.length && (src[i] in '0'..'9' || src[i] == '.' || src[i] == 'e' || src[i] == 'E' || src[i] == '+' || src[i] == '-')) i++
        return Json.Num(src.substring(start, i))
    }
    private fun ws() { while (i < src.length && src[i] in " \t\r\n") i++ }
    private fun peek(): Char = src[i]
    private fun expect(c: Char) { if (src[i++] != c) throw IllegalStateException("json: expected $c at ${i - 1}") }
}

private fun jStr(j: Json): String = (j as Json.Str).value
private fun jLong(j: Json): Long = java.lang.Long.parseUnsignedLong((j as Json.Num).raw)
private fun jObj(j: Json): Json.Obj = j as Json.Obj
private fun jArr(j: Json): List<Json> = (j as Json.Arr).elements
private fun Json.Obj.req(key: String): Json = members[key] ?: throw IllegalStateException("table lacks $key")
private fun Json.Obj.optStr(key: String): String? = (members[key] as? Json.Str)?.value

private class Table(val root: Json.Obj) {
    val constants: Json.Obj = jObj(root.req("constants"))
    val payloadVectors: List<Json.Obj> = jArr(root.req("payloads")).map { jObj(it) }
    val malformedVectors: List<Json.Obj> = jArr(root.req("malformed")).map { jObj(it) }
    val frameVectors: List<Json.Obj> = jArr(root.req("frames")).map { jObj(it) }
    val walkVectors: List<Json.Obj> = jArr(root.req("walk")).map { jObj(it) }
    val collision: Json.Obj = jObj(root.req("collision"))
    val att: Json.Obj = jObj(root.req("att"))
    val storeIds: List<String> = jArr(root.req("store")).map { jStr(it) }
}


/** A page speaks with its own snapshot id when it carries one; the lawful
 * page_after output omits it and the stream's stands. */
private fun pageSid(pageObj: Json.Obj, stream: Json.Obj): Long =
    if (pageObj.members.containsKey("snapshot_id")) jLong(pageObj.req("snapshot_id")) else jLong(stream.req("snapshot_id"))
