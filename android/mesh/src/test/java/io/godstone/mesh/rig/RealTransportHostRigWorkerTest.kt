package io.godstone.mesh.rig

import androidx.test.core.app.ApplicationProvider
import io.godstone.mesh.delivery.DeliveryState
import io.godstone.mesh.store.DeliveryRow
import io.godstone.mesh.transport.PeerId
import io.godstone.mesh.transport.TransportResult
import io.godstone.mesh.wire.v2.LogicalMessageIdentity
import io.godstone.mesh.wire.v2.Priority
import io.godstone.mesh.wire.v2.SignedMessageV1
import io.godstone.mesh.wire.v2.TimeQuality
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.security.SecureRandom
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * *** GS-INTEGRATION-001 `real-adapters` (step 5.5/5.6): THE ANDROID CROSS-PLATFORM WORKER. ***
 *
 * *The foreign end of the coordinator's wire. `tools/readiness/run_board1_integration.py` launch eth this class
 * through the committed `:mesh:board1IntegrationWorker` Gradle task, naming a ROLE and a pair of FIFOs; the
 * coordinator relays the **EXACT characteristic bytes** this worker's OS facade handed its stack to the iOS
 * worker's OS facade, and vice versa.* **The coordinator never decodes a payload; neither doth this worker read one
 * it did not author.**
 *
 * *** THE WORKER'S LADDER IS THE RIG'S OWN ONE-SIDED SEAT. *** *`RealTransportHostRig.seatInitiator` /
 * `seatResponder` drive the PRODUCTION drivers to the point where the sealed handshake may cross the pipe; the
 * trusted handshake then proceeds AUTOMATICALLY through the node's own consumers as the foreign platform's records
 * arrive at this node's REAL ingress doors (`handleServerInboundWrite` / `handleCentralInboundNotification`).*
 * **Nothing here synthesises a `PeerEvent.Found`, calls `MeshNode.ingestInbound`, pre-trusts a remote key by hand,
 * or fabricates a session.** *The remote's binding is pinned by the SEALED HANDSHAKE ITSELF, through the node's own
 * `RepositoryPeerBindingTrustAuthority` -- the production road, not a court's shortcut.*
 *
 * **THE SENDER IS SEATED AS THE ELECTION'S INITIATOR.** *That is a production fact rather than a convenience: a
 * node is reachable in the route-eligible view only through the sealed key-confirmation round, and only the party
 * that ISSUES the challenge receives the echo. **The coordinator re-mints an identity over a fresh estate until the
 * production election seats the sender as the initiator** -- nothing has happened yet at that point, so it is a
 * different honest election rather than a role forced against the election.*
 *
 * THE FRAMING (identical on both ends of every pipe):
 *
 *     u32be header_len | header(utf8 canonical json) | u32be payload_len | payload
 *
 * *Length-delimited rather than newline-delimited, **because a protocol payload may contain any octet.***
 *
 * *** AN ORDINARY (ROLE-LESS) INVOCATION IS NOT AN EMPTY TEST. *** *With no `godstone.integration.role` property the
 * test executes the worker's own boundary contract -- the framing round-trip over hostile octets, and the refusal
 * of an incomplete launch -- so the default `:mesh:testDebugUnitTest` run carries a real assertion rather than a
 * no-op.*
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33])
internal class RealTransportHostRigWorkerTest {

    // =============================================================================================================
    // the boundary contract (the role-less invocation)
    // =============================================================================================================

    /**
     * *** THE ROLE-LESS HALF: THE WORKER'S OWN BOUNDARY LAWS, ASSERTED RATHER THAN ASSUMED. ***
     *
     * *Two laws are checkable with no coordinator: the framing round-trips opaque octets (including newlines and
     * NULs -- which is WHY it is length-delimited), and an incomplete launch is REFUSED rather than becoming a
     * silent no-op worker. **Both are the boundary this file shares with the Python coordinator, so a change on
     * either side that broke them is caught by the default lane.***
     */
    @Test
    fun testTheWorkerFramingSurvivesHostileOctetsAndAnIncompleteLaunchIsRefused() {
        val hostile = byteArrayOf(0, 0x0A, 0x0D, 0xFF.toByte(), 0, 0x7B, 0x22, 0x0A) +
            ByteArray(300) { 0x0A } + byteArrayOf(0, 0, 0, 1)
        val framed = WorkerFraming.frame(
            header = mapOf("v" to 1, "kind" to "frame", "platform" to "android", "epoch" to 7),
            payload = hostile,
        )
        val parsed = WorkerFraming.parseOne(framed)
        assertTrue("*** THE WORKER'S OWN FRAMING MUST PARSE WHAT IT FRAMED. ***", parsed != null)
        assertTrue(
            "*** THE PAYLOAD MUST SURVIVE THE FRAMING OCTET-FOR-OCTET, NEWLINES AND NULS INCLUDED. *** " +
                "*That is the entire reason the stream is length-delimited.* Observed=${parsed!!.payload.size} " +
                "octets against ${hostile.size}",
            parsed.payload.contentEquals(hostile),
        )
        assertTrue("and the header's epoch must survive", parsed.header["epoch"] == 7)
        assertTrue(
            "*** A TRUNCATED FRAME MUST NOT PARSE: a partial record is never a record. ***",
            WorkerFraming.parseOne(framed.copyOf(framed.size - 1)) == null,
        )

        // *** AND AN INCOMPLETE LAUNCH IS REFUSED, NOT SILENTLY DOWNGRADED TO A NO-OP WORKER. ***
        val complete = mapOf(
            WorkerFraming.ROLE to "sender", WorkerFraming.IN to "/tmp/gs-in",
            WorkerFraming.OUT to "/tmp/gs-out", WorkerFraming.ROOT to "/tmp/gs-estate",
        )
        for ((missing, props) in listOf(
            "the role" to (complete - WorkerFraming.ROLE),
            "a blank role" to (complete + (WorkerFraming.ROLE to "")),
            "a known role" to (complete + (WorkerFraming.ROLE to "bystander")),
            "the input FIFO" to (complete - WorkerFraming.IN),
            "the output FIFO" to (complete - WorkerFraming.OUT),
            "the estate root" to (complete - WorkerFraming.ROOT),
        )) {
            var refused = false
            try {
                WorkerFraming.validateLaunch(props)
            } catch (expected: WorkerFraming.Refused) {
                refused = true
            }
            assertTrue(
                "*** A LAUNCH MISSING $missing MUST BE REFUSED. *** *A worker that carried on with a missing end " +
                    "of its wire would hang the coordinator on a marker that could never arrive.*",
                refused,
            )
        }
    }

    /**
     * *** ONE TEST METHOD. With `godstone.integration.role` set it IS the worker; without it, the boundary contract
     * above is the only arm. *** *The role-less run therefore never blocks on a FIFO, and the coordinator's own
     * `-Dgodstone.integration.role=...` is what maketh this the worker.*
     */
    @Test
    fun testGSINT001CrossPlatformWorker() {
        val props = WorkerFraming.propertiesFromSystem()
        when (props[WorkerFraming.ROLE]) {
            // *** THE ROLE-LESS ARM IS THE CONTRACT TEST ABOVE; THIS METHOD IS THE COORDINATOR'S LAUNCH. ***
            null -> return
            "crash-prepare" -> CrashRoles.prepare(props)
            "crash-recover" -> CrashRoles.recover(props)
            else -> WorkerLauncher.worker(props).use { it.run() }
        }
    }

    // =============================================================================================================
    // the durable-commit crash roles (`--mode crash`, the Android mirror of the macOS SIGKILL campaign)
    // =============================================================================================================

    /**
     * *** THE DURABLE-BOUNDARY RECOVERY ROLES, OVER THE REAL ON-DISK OWNERS. ***
     *
     * *The macOS isle's authoritative abrupt-death proof is the child-process SIGKILL campaign; **this is its
     * Android mirror on the real host store.*** The `prepare` JVM driveth a REAL durable owner to a successful
     * commit and then **HALTETH IMMEDIATELY** (`Runtime.halt`, which is not a graceful return -- a cooperative exit
     * is not crash proof). The `recover` JVM openeth the SAME estate and read eth what survived.
     *
     * *** THE BOUNDARY STANDS ON THE STATEMENT AFTER THE OWNER'S OWN RETURN. *** *The plan's table demand eth an
     * "after commit" marker "only after the transaction has returned success", and nameth an in-transaction marker
     * as NOT a durable-commit marker. `SqliteMessageStore.enqueueDirectOutbound` insert eth the held frame AND the
     * `QUEUED_DURABLY` delivery row in ONE atomic transaction, so **its return IS the commit** and the halt stand eth
     * on the next statement. **No production ordering is changed and no production seam is added: the worker
     * STOPPETH ITSELF at a point it owns.***
     */
    internal object CrashRoles {
        private const val ENDPOINT = "android-crash"
        private const val COUNTERPART = "android-crash-peer"
        private const val HALT_CODE = 137

        /** The boundaries this isle mirrors (the plan's step-6 table, restricted to the host store's own roads). */
        val BOUNDARIES = listOf("outboundEnqueue", "inboundCommit")

        /**
         * *The `prepare` JVM: drive ONE real durable owner to a successful commit, emit the marker, and HALT.*
         * **The halt is not a graceful return -- `Runtime.halt` terminateth the JVM at once, with the status the
         * coordinator requireth -- so a clean exit here is itself a failure of the scenario.**
         */
        fun prepare(props: Map<String, String>) {
            val marker = Marker.output(props)
            val root = File(props.getValue(WorkerFraming.ROOT)).also { it.mkdirs() }
            val rig = RealTransportHostRig(
                ctx = ApplicationProvider.getApplicationContext(),
                fixtureRoot = File(root, "estate"),
            )
            try {
                // *** TWO REAL NODES: the endpoint whose owner is driven, and the counterpart it author eth FOR.
                // Neither is opened -- the crash roles measure the STORE's own durable answers, so no radio is
                // needed and none is started.***
                rig.makeNode(ENDPOINT)
                rig.makeNode(COUNTERPART)
                val node = rig.nodeOf(ENDPOINT)
                val counterpart = rig.nodeOf(COUNTERPART).identity
                val boundary = props[WorkerFraming.VARIANT] ?: BOUNDARIES.first()
                when (boundary) {
                    // *** AFTER THE ATOMIC HELD+DELIVERY ENQUEUE RETURNS: the same accepted msgId and its
                    // `QUEUED_DURABLY` row must survive, with NO DELIVERED claim. ***
                    "outboundEnqueue" -> {
                        val frame = rig.authorDirectFrame(
                            ENDPOINT, COUNTERPART, "crash-$boundary".toByteArray(Charsets.US_ASCII),
                        )
                        val result = runBlocking {
                            node.messageStore.enqueueDirectOutbound(
                                frame, counterpart.nodeId, node.identity.nodeId,
                            )
                        }
                        marker.emit(
                            "at_boundary",
                            mapOf(
                                "boundary" to boundary, "msg_id" to hex(frame.msgId),
                                "enqueue" to result::class.simpleName,
                                "detail" to "the atomic held+delivery enqueue returned success; halting before any " +
                                    "radio work",
                            ),
                        )
                        Runtime.getRuntime().halt(HALT_CODE)
                    }
                    // *** AFTER THE ATOMIC held+ACK-OBLIGATION PAIR RETURNS: one inbox row and a PENDING
                    // obligation must survive, before any signing. ***
                    "inboundCommit" -> {
                        val inbound = rig.authorDirectFrame(
                            COUNTERPART, ENDPOINT, "crash-$boundary".toByteArray(Charsets.US_ASCII),
                        )
                        val result = runBlocking {
                            node.messageStore.commitInboundWithObligationAtWithFault(
                                frame = inbound,
                                receivedFrom = counterpart.nodeId,
                                localRecipientNodeId = node.identity.nodeId,
                                identityGeneration = 0L,
                                obligationLifetimeMs = 300_000L,
                                receivedAt = System.currentTimeMillis(),
                                fault = null,
                            )
                        }
                        marker.emit(
                            "at_boundary",
                            mapOf(
                                "boundary" to boundary, "msg_id" to hex(inbound.msgId),
                                "commit" to result::class.simpleName,
                                "detail" to "the atomic held+obligation pair returned success; halting before signing",
                            ),
                        )
                        Runtime.getRuntime().halt(HALT_CODE)
                    }
                    else -> throw WorkerFraming.Refused("no prepare road for boundary '$boundary'")
                }
            } finally {
                runCatching { rig.tearDown() }
                marker.close()
            }
        }

        /**
         * *The `recover` JVM: a FRESH JVM over the SAME estate, reading the owners' own durable answers.*
         * **`tearDown` leaveth a caller-owned estate in place, which is exactly the durable material this role
         * existeth to read.**
         */
        fun recover(props: Map<String, String>) {
            val marker = Marker.output(props)
            val root = File(props.getValue(WorkerFraming.ROOT)).also { it.mkdirs() }
            val rig = RealTransportHostRig(
                ctx = ApplicationProvider.getApplicationContext(),
                fixtureRoot = File(root, "estate"),
            )
            try {
                rig.makeNode(ENDPOINT)
                rig.makeNode(COUNTERPART)
                val boundary = props[WorkerFraming.VARIANT] ?: BOUNDARIES.first()
                val held = rig.heldMsgIds(ENDPOINT)
                val msgId = held.firstOrNull()
                val row = msgId?.let { rig.deliveryRow(ENDPOINT, it) }
                marker.emit(
                    "complete",
                    mapOf(
                        "boundary" to boundary,
                        "durable_row" to (if (msgId != null) "present" else "absent"),
                        "msg_id" to (msgId?.let { hex(it) } ?: ""),
                        "delivery" to (row?.let { DeliveryState.fromCode(it.state)?.name } ?: "none"),
                        "detail" to "a FRESH JVM over the SAME estate read the owners' own durable answers",
                    ),
                )
            } finally {
                runCatching { rig.tearDown() }
                marker.close()
            }
        }

        private fun hex(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it) }

        /**
         * *THE CRASH ROLES\' OWN MARKER WRITER -- OVER THE SAME FRAMING THE CROSS-PLATFORM WORKER USETH.* **The
         * coordinator therefore read eth one protocol for every role, and the marker is written and flushed BEFORE
         * the halt so it arriveth even though the JVM die th immediately after.**
         */
        internal class Marker private constructor(private val output: FileOutputStream?) : AutoCloseable {
            fun emit(kind: String, fields: Map<String, Any?>) {
                val header = LinkedHashMap<String, Any?>()
                header["v"] = 1
                header["kind"] = kind
                header["platform"] = "android"
                header.putAll(fields)
                output?.let {
                    it.write(WorkerFraming.frame(header, ByteArray(0)))
                    it.flush()
                }
                println("GS-INTEGRATION-MARKER $kind $fields")
            }

            override fun close() { runCatching { output?.close() } }

            companion object {
                fun output(props: Map<String, String>): Marker {
                    val path = props[WorkerFraming.OUT]
                    return Marker(
                        path?.takeIf { File(it).exists() }
                            ?.let { runCatching { FileOutputStream(it) }.getOrNull() },
                    )
                }
            }
        }
    }

    // =============================================================================================================
    // the framing (shared by the contract arm and the worker)
    // =============================================================================================================

    internal object WorkerFraming {
        const val ROLE = "godstone.integration.role"
        const val IN = "godstone.integration.in"
        const val OUT = "godstone.integration.out"
        const val ROOT = "godstone.integration.root"
        const val VARIANT = "godstone.integration.variant"
        const val DEADLINE = "godstone.integration.deadlineSeconds"
        const val MAX_HEADER = 1 shl 22
        const val MAX_PAYLOAD = 1 shl 24

        class Refused(message: String) : RuntimeException(message)

        class Record(val header: Map<String, Any?>, val payload: ByteArray) {
            val kind: String get() = header["kind"] as? String ?: ""
        }

        /** *** THE LAUNCH'S OWN PRECONDITIONS, CHECKED BEFORE ANY RESOURCE IS TOUCHED. *** */
        fun validateLaunch(props: Map<String, String>) {
            val role = props[ROLE] ?: throw Refused("no role was given")
            if (role.isBlank()) throw Refused("the role was blank: no role was given")
            if (role != "sender" && role != "recipient" &&
                role != "crash-prepare" && role != "crash-recover") {
                throw Refused("the role '$role' is not one this worker knoweth")
            }
            props[IN] ?: throw Refused("the input FIFO was not named")
            props[OUT] ?: throw Refused("the output FIFO was not named")
            props[ROOT] ?: throw Refused("no estate root was given")
        }

        fun frame(header: Map<String, Any?>, payload: ByteArray): ByteArray {
            val head = canonicalJson(header).toByteArray(Charsets.UTF_8)
            val out = ByteArray(4 + head.size + 4 + payload.size)
            var at = 0
            fun putInt(value: Int) {
                out[at++] = (value ushr 24).toByte(); out[at++] = (value ushr 16).toByte()
                out[at++] = (value ushr 8).toByte(); out[at++] = value.toByte()
            }
            putInt(head.size); head.copyInto(out, at); at += head.size
            putInt(payload.size); payload.copyInto(out, at)
            return out
        }

        /**
         * *A MINIMAL, DETERMINISTIC JSON WRITER FOR THE METADATA HEADER ONLY.* **The payload is never touched: it
         * travells beside the header as opaque octets, so no encoder ever see th it.**
         */
        private fun canonicalJson(value: Map<String, Any?>): String =
            value.entries.sortedBy { it.key }.joinToString(prefix = "{", postfix = "}") { (key, v) ->
                "\"${escape(key)}\":" + jsonValue(v)
            }

        private fun jsonValue(value: Any?): String = when (value) {
            null -> "null"
            is String -> "\"${escape(value)}\""
            is Boolean -> value.toString()
            is Number -> value.toString()
            is Map<*, *> -> canonicalJson(value.entries.associate { it.key.toString() to it.value })
            is List<*> -> value.joinToString(prefix = "[", postfix = "]") { jsonValue(it) }
            else -> "\"${escape(value.toString())}\""
        }

        private fun escape(s: String): String = buildString {
            for (c in s) when (c) {
                '"' -> append("\\\"")
                '\\' -> append("\\\\")
                '\n' -> append("\\n")
                '\r' -> append("\\r")
                '\t' -> append("\\t")
                else -> if (c.code < 0x20) append("\\u%04x".format(c.code)) else append(c)
            }
        }

        private fun readU32(bytes: ByteArray, at: Int): Int =
            ((bytes[at].toInt() and 0xFF) shl 24) or
                ((bytes[at + 1].toInt() and 0xFF) shl 16) or
                ((bytes[at + 2].toInt() and 0xFF) shl 8) or
                (bytes[at + 3].toInt() and 0xFF)

        /** The total byte length of the record at the head of [buffer], or null when it is not whole yet. */
        fun recordLength(buffer: ByteArray): Int? {
            if (buffer.size < 4) return null
            val headLen = readU32(buffer, 0)
            if (headLen > MAX_HEADER || buffer.size < 4 + headLen + 4) return null
            val payLen = readU32(buffer, 4 + headLen)
            if (payLen > MAX_PAYLOAD) return null
            return 4 + headLen + 4 + payLen
        }

        fun parseOne(buffer: ByteArray): Record? {
            val len = recordLength(buffer) ?: return null
            if (buffer.size < len) return null
            val headLen = readU32(buffer, 0)
            val head = String(buffer, 4, headLen, Charsets.UTF_8)
            val payload = buffer.copyOfRange(4 + headLen + 4, len)
            return Record(MiniJson.parseObject(head), payload)
        }

        /**
         * *** A BLANK PROPERTY ISAN ABSENT ONE. ***
         *
         * *THE COMMITTED GRADLE TASK FORWARDETH EVERY KEY WITH `getOrElse("")`, so an unset parameter arriveth here as
         * an EMPTY STRING rather than as a missing property.* **A worker that tested only for `null` would therefore
         * take the empty string as a role and REFUSE the launch in the ordinary default-suite run -- which is exactly
         * the "empty/skipped test" the plan forbids, inverted.** *So blank values are dropped here, and "not launched"
         * and "launched with an empty value" become ONE case.*
         */
        fun propertiesFromSystem(): Map<String, String> = listOf(ROLE, IN, OUT, ROOT, VARIANT, DEADLINE)
            .mapNotNull { key -> System.getProperty(key)?.takeIf { it.isNotBlank() }?.let { key to it } }
            .toMap()
    }

    /**
     * *A MINIMAL JSON READER FOR THE METADATA HEADER ONLY.* **The header carrieth flat scalars and string maps; no
     * payload is ever parsed, so this is the whole of the coordinator's JSON surface on this side.**
     */
    internal object MiniJson {
        fun parseObject(text: String): Map<String, Any?> {
            val cursor = Cursor(text)
            cursor.skipWs()
            if (!cursor.take('{')) throw WorkerFraming.Refused("a metadata header must be a JSON object")
            val out = LinkedHashMap<String, Any?>()
            cursor.skipWs()
            if (cursor.take('}')) return out
            while (true) {
                cursor.skipWs()
                val key = cursor.string()
                cursor.skipWs()
                if (!cursor.take(':')) throw WorkerFraming.Refused("a metadata key must be followed by ':'")
                cursor.skipWs()
                out[key] = value(cursor)
                cursor.skipWs()
                when {
                    cursor.take(',') -> continue
                    cursor.take('}') -> return out
                    else -> throw WorkerFraming.Refused("a metadata object must continue with ',' or '}'")
                }
            }
        }

        private fun value(c: Cursor): Any? {
            c.skipWs()
            return when {
                c.take('"') -> c.restOfString()
                c.take('{') -> {
                    val out = LinkedHashMap<String, Any?>()
                    c.skipWs()
                    if (c.take('}')) return out
                    while (true) {
                        c.skipWs()
                        val key = c.string()
                        c.skipWs()
                        if (!c.take(':')) throw WorkerFraming.Refused("bad nested key")
                        c.skipWs()
                        out[key] = value(c)
                        c.skipWs()
                        when {
                            c.take(',') -> continue
                            c.take('}') -> return out
                            else -> throw WorkerFraming.Refused("bad nested object")
                        }
                    }
                }
                c.take('[') -> {
                    val out = ArrayList<Any?>()
                    c.skipWs()
                    if (c.take(']')) return out
                    while (true) {
                        out.add(value(c))
                        c.skipWs()
                        when {
                            c.take(',') -> continue
                            c.take(']') -> return out
                            else -> throw WorkerFraming.Refused("bad array")
                        }
                    }
                }
                c.match("true") -> true
                c.match("false") -> false
                c.match("null") -> null
                else -> {
                    val number = c.number()
                    number.toIntOrNull() ?: number.toLongOrNull() ?: number.toDouble()
                }
            }
        }

        private class Cursor(val text: String) {
            var index = 0
            fun skipWs() { while (index < text.length && text[index].isWhitespace()) index++ }
            fun take(ch: Char): Boolean {
                if (index < text.length && text[index] == ch) { index++; return true }
                return false
            }
            fun match(word: String): Boolean {
                if (text.startsWith(word, index)) { index += word.length; return true }
                return false
            }
            fun string(): String {
                if (!take('"')) throw WorkerFraming.Refused("expected a JSON string")
                return restOfString()
            }
            fun restOfString(): String {
                val out = StringBuilder()
                while (index < text.length) {
                    val ch = text[index++]
                    when {
                        ch == '"' -> return out.toString()
                        ch == '\\' -> {
                            val esc = text[index++]
                            when (esc) {
                                '"' -> out.append('"')
                                '\\' -> out.append('\\')
                                '/' -> out.append('/')
                                'b' -> out.append('\b')
                                'f' -> out.append('\u000C')
                                'n' -> out.append('\n')
                                'r' -> out.append('\r')
                                't' -> out.append('\t')
                                'u' -> {
                                    out.append(text.substring(index, index + 4).toInt(16).toChar())
                                    index += 4
                                }
                                else -> throw WorkerFraming.Refused("unknown escape \\$esc")
                            }
                        }
                        else -> out.append(ch)
                    }
                }
                throw WorkerFraming.Refused("an unterminated JSON string")
            }
            fun number(): String {
                val start = index
                while (index < text.length && (text[index].isDigit() || text[index] in "-+.eE")) index++
                return text.substring(start, index)
            }
        }
    }

    // =============================================================================================================
    // the launch (the FIFOs are real pipes on this host JVM)
    // =============================================================================================================

    /**
     * *** THE HOST'S OWN WIRE. ***
     *
     * *The coordinator createth a named pipe (`os.mkfifo`) and openeth BOTH ends RDWR **before** it launch eth this
     * worker -- so a plain `FileInputStream(path)` here cannot block on the open, and a `FileOutputStream` always
     * has a reader. **That is the same discipline the Swift worker keepeth with `O_RDWR`.***
     *
     * **EVERY READ IS BOUNDED BY A DEADLINE.** *A plain blocking `read` would hang for ever if the coordinator died,
     * so the input is drained by one background thread into a queue and every caller poll th the queue with its own
     * timeout -- a timeout being a NAMED REFUSAL rather than a hang.*
     */
    internal object WorkerLauncher {
        fun worker(props: Map<String, String>): CrossPlatformWorker {
            WorkerFraming.validateLaunch(props)
            val root = File(props.getValue(WorkerFraming.ROOT))
            root.mkdirs()
            if (!root.isDirectory) {
                throw WorkerFraming.Refused("the estate root '${root.path}' could not be made a directory")
            }
            // The FIFOs must EXIST: a coordinator that launched a worker without its wire is the failure this
            // check nameth, rather than a hang on a path that was never created.
            for (key in listOf(WorkerFraming.IN, WorkerFraming.OUT)) {
                val path = props.getValue(key)
                if (!File(path).exists()) {
                    throw WorkerFraming.Refused("the FIFO '$path' is absent")
                }
            }
            val input = try {
                FileInputStream(props.getValue(WorkerFraming.IN))
            } catch (io: IOException) {
                throw WorkerFraming.Refused("the input FIFO could not be opened: ${io.message}")
            }
            val output = try {
                FileOutputStream(props.getValue(WorkerFraming.OUT))
            } catch (io: IOException) {
                throw WorkerFraming.Refused("the output FIFO could not be opened: ${io.message}")
            }
            return CrossPlatformWorker(props, input, output)
        }
    }

    // =============================================================================================================
    // the worker
    // =============================================================================================================

    /**
     * *** ONE ANDROID ENDPOINT, DRIVEN ENTIRELY BY THE PIPE. ***
     *
     * *`use {}` close th the streams and teareth the rig down; a coordinator-given estate root is LEFT IN PLACE, so
     * a later run reacheth the same durable rows (the Android twin of the macOS fixture root).*
     */
    internal class CrossPlatformWorker(
        private val props: Map<String, String>,
        private val input: FileInputStream,
        private val output: FileOutputStream,
    ) : AutoCloseable {

        private companion object {
            const val ENDPOINT = "android-endpoint"
            const val SEED_BASE = 0
            /** *A salt that cannot collide with the rig's own derived ordinal salt (`nodes.size*0x41+0x10`).* */
            const val REMOTE_SALT = 0x51
        }

        private val role: String = props.getValue(WorkerFraming.ROLE)
        private val variant: String = props[WorkerFraming.VARIANT] ?: "honest"
        private val deadline: Long = (props[WorkerFraming.DEADLINE]?.toDoubleOrNull() ?: 300.0).toLong()
        private val rng = SecureRandom()
        private val inbound = LinkedBlockingQueue<ByteArray>()
        private val inbox = ByteArrayQueue()

        private val writeLock = Any()
        private val stopReader = java.util.concurrent.atomic.AtomicBoolean(false)

        private var rig: RealTransportHostRig = RealTransportHostRig(
            ctx = ApplicationProvider.getApplicationContext(),
            fixtureRoot = rootFor(SEED_BASE),
        )
        private var seed = SEED_BASE
        private val reader = Thread({ drainInput() }, "gs-int-worker-input").also { it.isDaemon = true }

        private var remoteNodeId: ByteArray? = null
        private var remoteAddress: String? = null
        private var remoteHint: ByteArray? = null
        private var remoteStaticPub: ByteArray? = null
        private var isInitiator = false
        private var ringBaseline = 0
        private var trackedMsgId: ByteArray? = null
        private var authoredFrame: io.godstone.mesh.wire.v2.FrameV2? = null
        private var dispatched = false

        init { reader.start() }

        override fun close() {
            stopReader.set(true)
            runCatching { rig.tearDown() }
            runCatching { input.close() }
            runCatching { output.close() }
            runCatching { reader.interrupt() }
        }

        // ---------------------------------------------------------------------------------------------------------
        // the pipe
        // ---------------------------------------------------------------------------------------------------------

        private fun drainInput() {
            val chunk = ByteArray(1 shl 16)
            while (!stopReader.get()) {
                val n = try {
                    input.read(chunk)
                } catch (io: IOException) {
                    return
                }
                if (n < 0) return
                if (n > 0) inbound.put(chunk.copyOf(n))
            }
        }

        private fun emit(kind: String, payload: ByteArray = ByteArray(0), header: Map<String, Any?> = emptyMap()) {
            val head = LinkedHashMap<String, Any?>()
            head["v"] = 1
            head["kind"] = kind
            head["platform"] = "android"
            head["role"] = role
            head["variant"] = variant
            head.putAll(header)
            val bytes = WorkerFraming.frame(head, payload)
            synchronized(writeLock) {
                try {
                    output.write(bytes)
                    output.flush()
                } catch (io: IOException) {
                    throw WorkerFraming.Refused("the wire refused a record: ${io.message}")
                }
            }
        }

        /** *** BOUNDED. A missing record is a NAMED REFUSAL, never a hang. *** */
        private fun nextRecord(timeoutSeconds: Long): WorkerFraming.Record {
            val deadlineAt = System.nanoTime() + timeoutSeconds.coerceAtLeast(1) * 1_000_000_000L
            while (true) {
                // *A whole record at the head of the queue is consumed first, so a burst of records read in one
                // chunk is never dropped.*
                val head = inbox.snapshot()
                val len = WorkerFraming.recordLength(head)
                if (len != null && head.size >= len) {
                    val whole = inbox.takeExact(len)
                    return WorkerFraming.parseOne(whole)
                        ?: throw WorkerFraming.Refused("a framed record could not be parsed")
                }
                val remainingMillis = (deadlineAt - System.nanoTime()) / 1_000_000
                if (remainingMillis <= 0) {
                    throw WorkerFraming.Refused("no record arrived within ${timeoutSeconds}s")
                }
                val chunk = inbound.poll(remainingMillis.coerceAtMost(200), TimeUnit.MILLISECONDS) ?: continue
                inbox.append(chunk)
            }
        }

        private fun expect(kind: String, timeoutSeconds: Long): WorkerFraming.Record {
            val rec = nextRecord(timeoutSeconds)
            if (rec.kind != kind) throw WorkerFraming.Refused("expected `$kind`, got `${rec.kind}`")
            return rec
        }

        // ---------------------------------------------------------------------------------------------------------
        // the run
        // ---------------------------------------------------------------------------------------------------------

        fun run() {
            buildEndpoint(seed)
            emit("hello", header = identityHeader())
            var mintAttempts = 0
            while (true) {
                val directive = nextRecord(deadline)
                when (directive.kind) {
                    "mint" -> {
                        mintAttempts++
                        if (mintAttempts > 16) {
                            throw WorkerFraming.Refused(
                                "the coordinator asked for more than 16 re-mints; refusing rather than grinding",
                            )
                        }
                        reseed(((directive.header["seed"] as? Number)?.toInt() ?: seed))
                        emit("hello", header = identityHeader())
                    }
                    "peer" -> { acceptPeer(directive); continueAfterPeer(); return }
                    "bye" -> return
                    else -> throw WorkerFraming.Refused("unexpected `${directive.kind}` before a peer was named")
                }
            }
        }

        private fun identityHeader(): Map<String, Any?> {
            val identity = rig.nodeOf(ENDPOINT).identity
            return mapOf(
                "node_id" to hex(identity.nodeId),
                // *** `node_hint` IS THE ADVERTISED HINT (the `mismatched` control lies here); `real_hint` is the
                // identity's own. *** *The coordinator electeth on the REAL hints and checketh that the advertised
                // pair elects the same way, so the mismatch control cannot accidentally move the role election and
                // produce a refusal for the wrong reason.*
                "node_hint" to hex(advertisedHint()),
                "real_hint" to hex(identity.nodeHint),
                "static_dh_pub" to hex(identity.staticDhPub),
                "binding" to hex(identity.issueIdentityBinding().encode()),
                "seed" to seed,
            )
        }

        private fun buildEndpoint(seedValue: Int) {
            seed = seedValue
            rig.makeNode(ENDPOINT)
            rig.open(ENDPOINT)
        }

        /**
         * *** A FRESH IDENTITY OVER A FRESH ESTATE -- NOT A ROLE FORCED AGAINST THE ELECTION. ***
         *
         * *The rig mint eth from the estate file when one standeth, so a re-mint removeth that file and starteth a
         * new estate. **Nothing has happened yet** -- no link, no session, no store row -- so this is a different
         * honest election rather than a role forced against the production election.*
         */
        private fun reseed(next: Int) {
            runCatching { rig.tearDown() }
            runCatching { identityFile(seed).delete() }
            seed = next
            rootFor(next).mkdirs()
            rig = RealTransportHostRig(ctx = ApplicationProvider.getApplicationContext(), fixtureRoot = rootFor(next))
            remoteNodeId = null; remoteAddress = null; remoteHint = null; remoteStaticPub = null
            isInitiator = false; ringBaseline = 0; trackedMsgId = null; authoredFrame = null
            dispatched = false
            inbox.clear()
            buildEndpoint(next)
        }

        private fun identityFile(seedValue: Int): File = File(rootFor(seedValue), "${ENDPOINT}_identity.bin")

        private fun rootFor(seedValue: Int): File =
            File(File(props.getValue(WorkerFraming.ROOT)), "seed-%02x".format(seedValue))

        /**
         * *** RECORD THE REMOTE'S PUBLIC IDENTITY. ***
         *
         * *NO PRE-TRUST IS WRITTEN HERE, AND THAT IS DELIBERATE: the remote's binding is pinned by the SEALED
         * HANDSHAKE ITSELF through the node's own `RepositoryPeerBindingTrustAuthority` (`TrustedHandshakeController`
         * -> `applyValidatedBinding`), which is the production road. **A court that pinned the binding by hand would
         * be pre-trusting a remote key, which the assignment forbids.*** The fields recorded here are what the
         * worker AUTHORETH against and what it names when it seateth the relation.
         */
        private fun acceptPeer(message: WorkerFraming.Record) {
            remoteNodeId = fromHex(
                message.header["node_id"] as? String ?: throw WorkerFraming.Refused("the peer named no node_id"),
            )
            remoteHint = fromHex(
                message.header["node_hint"] as? String ?: throw WorkerFraming.Refused("the peer named no node_hint"),
            )
            remoteStaticPub = fromHex(
                message.header["static_dh_pub"] as? String
                    ?: throw WorkerFraming.Refused("the peer named no static_dh_pub"),
            )
            remoteNodeId!!.let { id ->
                if (id.size != 16) throw WorkerFraming.Refused("the peer's node_id is not sixteen octets")
            }
            remoteHint!!.let { hint ->
                if (hint.size != 4) throw WorkerFraming.Refused("the peer's node hint is not four octets")
            }
        }

        private fun continueAfterPeer() {
            val setup = expect("setup", deadline)
            isInitiator = (setup.header["seat"] as? String) == "initiator"
            val address = rig.addressOf(remoteNodeId!!, REMOTE_SALT)
            remoteAddress = address
            // *** THE LADDER TAKES THE REMOTE'S ADVERTISED HINT, NOT OURS -- AND THE RUN MEASURED WHY. ***
            //
            // *`seatResponder` feedeth the hint to `BleServerOrchestrationDriver.onLinkInfoWriteRequest`, which
            // runneth `BleRoleElection.elect(localHint, remoteHint)`. **Passing OUR OWN hint made the election
            // compare the local hint with itself -> `.tie` -> `RejectWrite("Tie or invalid role election")`** --
            // measured in the coordinator's live run. The parameter is what the FOREIGN INITIATOR wrote on the
            // link, which is its own advertised hint. Same for `seatInitiator`.*
            val peerAdvertised = remoteHint ?: ByteArray(0)
            if (isInitiator) rig.seatInitiator(ENDPOINT, address, peerAdvertised)
            else rig.seatResponder(ENDPOINT, address, peerAdvertised)
            ringBaseline = ringCount()
            emit("ready", header = mapOf("seat" to if (isInitiator) "initiator" else "responder",
                                         "handle" to address,
                                         "remote_hint" to hex(remoteHint ?: ByteArray(0)),
                                         "advertised_hint" to hex(advertisedHint())))

            // *** AUTHORING AND DISPATCH ARE SPLIT BY THE `authored` MARKER, AND THAT SPLIT IS WHAT MAKETH THE
            // ALTERED-RECORD CONTROL PRECISE. ***
            //
            // *THE COORDINATOR CANNOT DECODE A PAYLOAD (a coordinator that could parse a frame could manufacture one),
            // so it cannot tell a handshake record from a DATA record by inspection. **WHAT IT CAN SEE IS ORDER**:
            // every byte this endpoint put on the wire BEFORE it announced `authored` belongeth to the handshake, and
            // every byte AFTER it is the sealed DATA record the control is about.* **So the marker is emitted once the
            // frame IS AUTHORED and before it is dispatched, the coordinator marks that instant, and it tamper eth
            // only the records that cross after it.** *That is a metadata-level discriminator, and it is the only one
            // a non-decoding coordinator may use.*
            var authored = false
            // *** THE RELEASE IS STICKY, AND THAT IS A CORRECTNESS REQUIREMENT RATHER THAN A NICETY. ***
            //
            // *THE COORDINATOR MAY SEND `go` BEFORE THE HANDSHAKE HATH COMPLETED (in the honest and mismatched
            // controls it send eth `go` at once, when it has nothing to hold back) -- and the producer is not yet
            // AUTHORED at that instant, because authoring wait eth for `isReady()`. **A release that were consumed
            // once and dropped would never be seen again, and the DATA record would never leave.*** *So the release
            // is RECORDED and the dispatch happen eth when BOTH `authored` AND `released` stand.*
            var released = false
            var lastReport = ""
            var lastAck = ""
            val startedAt = System.nanoTime()
            while (System.nanoTime() - startedAt < deadline * 1_000_000_000L) {
                if (role == "sender" && !authored && isReady()) {
                    author()
                    emit("authored", header = mapOf("msg_id" to (trackedMsgId?.let { hex(it) } ?: "")))
                    authored = true
                }
                if (role == "sender" && authored && released && !dispatched) {
                    dispatch()
                    dispatched = true
                }
                val rec = try {
                    nextRecord(2)
                } catch (timeout: WorkerFraming.Refused) {
                    lastReport = refreshReports(lastReport)
                    lastAck = maybeCarryAck(lastAck)
                    continue
                }
                when (rec.kind) {
                    "inject" -> {
                        inject(rec)
                        lastAck = maybeCarryAck(lastAck)
                    }
                    // *** THE COORDINATOR'S PERMISSION TO PUT THE DATA RECORD ON THE WIRE -- REMEMBERED, SO A
                    // RELEASE THAT ARRIVETH BEFORE THE AUTHORING IS NOT LOST. ***
                    "go" -> released = true
                    "reconnect" -> {
                        reconnect()
                        emit("ready", header = mapOf("seat" to if (isInitiator) "initiator" else "responder",
                                                     "reconnected" to true, "handle" to address))
                    }
                    "bye" -> { refreshReports(""); return }
                }
                lastReport = refreshReports(lastReport)
                lastAck = maybeCarryAck(lastAck)
            }
            refreshReports("")
        }

        /**
         * The hint this endpoint advertiseth. **Honest: its own. Mismatched: a FOREIGN but well-formed four-octet
         * hint -- the exact class the election bindeth and the frozen validator then refuseth against the
         * authenticated static key.**
         */
        private fun advertisedHint(): ByteArray {
            val own = rig.nodeOf(ENDPOINT).identity.nodeHint
            return if (variant == "mismatched") ByteArray(own.size) { (own[it].toInt() xor 0xFF).toByte() } else own
        }

        // ---------------------------------------------------------------------------------------------------------
        // authoring (sender) and the ingress (recipient)
        // ---------------------------------------------------------------------------------------------------------

        /// *** AUTHOR THE FRAME ONLY -- no dispatch and no wire. *** *The `authored` marker is emitted after this
        /// return eth, so everything the endpoint wrote before it belongeth to the handshake.*
        private fun author() {
            val node = rig.nodeOf(ENDPOINT)
            val recipientId = remoteNodeId!!
            val recipientPub = remoteStaticPub!!
            val nonce = ByteArray(16).also { rng.nextBytes(it) }
            val createdAt = System.currentTimeMillis() / 1000L
            val container = SignedMessageV1.author(
                senderIdentityPriv = node.identity.identityPriv,
                senderIdentityPub = node.identity.identityPub,
                senderNodeId = node.identity.nodeId,
                recipientNodeId = recipientId,
                messageNonce = nonce,
                createdAtEpochSeconds = createdAt,
                priority = Priority.DIRECT,
                timeQuality = TimeQuality.USER_CONFIRMED,
                bodyUtf8 = "cross-platform $variant".toByteArray(Charsets.US_ASCII),
            )
            val frame = runBlocking {
                node.node.router.buildSealedMessage(
                    plaintext = container,
                    recipientNodeId = recipientId,
                    recipientStaticPub = recipientPub,
                    identity = LogicalMessageIdentity.of(createdAt, nonce),
                    priority = Priority.DIRECT,
                )
            }
            trackedMsgId = frame.msgId
            authoredFrame = frame
        }

        /// *** THE DISPATCH IS THE NODE'S OWN PRODUCTION ROAD: `enqueueDirectOutbound` commit eth the held frame and
        /// the queued delivery row in ONE transaction, and the `send` closure is the transport's own `send`. ***
        private fun dispatch() {
            val node = rig.nodeOf(ENDPOINT)
            val frame = authoredFrame ?: throw WorkerFraming.Refused("nothing was authored to dispatch")
            val recipientId = remoteNodeId!!
            val address = remoteAddress!!
            runBlocking {
                node.node.dispatchDirect(frame, expectedRecipient = recipientId) { peer, bytes ->
                    val asAddress = PeerId.toAddress(peer) ?: peer.decodeToString()
                    if (asAddress != address) return@dispatchDirect false
                    node.transport.send(peer, bytes) is TransportResult.Admitted
                }
            }
        }

        /** *** RE-ENTER THE FOREIGN PLATFORM'S EXACT BYTES AT THIS PLATFORM'S REAL OS INGRESS. *** */
        private fun inject(rec: WorkerFraming.Record) {
            val node = rig.nodeOf(ENDPOINT)
            val address = remoteAddress
            if (address == null) {
                emit("refuse", header = refusalHeader(mapOf("reason" to "the endpoint holds no seat")))
                return
            }
            // THE SEAT DECIDES THE DOOR: production's responder readeth a WRITE, the initiator a NOTIFICATION.
            if (isInitiator) node.transport.handleCentralInboundNotification(address, rec.payload)
            else node.transport.handleServerInboundWrite(address, rec.payload)
        }

        /**
         * *** THE RECIPIENT'S CANONICAL ACK, DRAINED FROM PRODUCTION'S OWN OUTBOX -- NEVER MINTED. ***
         *
         * *The drain is idempotent per `msgId` (the token the caller carrieth), so a poll loop that found nothing
         * once cannot send the same ACK twice.*
         */
        private fun maybeCarryAck(previous: String): String {
            val node = rig.nodeOf(ENDPOINT)
            val address = remoteAddress ?: return previous
            val held = durableMsgId() ?: return previous
            val token = hex(held)
            if (previous == token) return previous
            val ack = rig.drainOneAck(ENDPOINT) ?: return previous
            runBlocking { node.transport.send(PeerId.fromAddress(address) ?: address.toByteArray(), ack.encode()) }
            emit("ack", header = mapOf("msg_id" to hex(ack.msgId), "for" to token))
            return token
        }

        /**
         * *** A FRESH SESSION: the transport stop th and the seat is re-driven. ***
         * *Ciphertext from an unrelated Noise session is not an interchangeable fixture, so the replay control must
         * face a session the captured bytes were never sealed under -- **and the fresh session is what proveth
         * it.***
         */
        private fun reconnect() {
            val node = rig.nodeOf(ENDPOINT)
            val address = remoteAddress!!
            runCatching { node.transport.stop() }
            runCatching { node.node.stop() }
            inbox.clear()
            rig.open(ENDPOINT)
            // *** THE LADDER TAKES THE REMOTE'S ADVERTISED HINT, NOT OURS -- AND THE RUN MEASURED WHY. ***
            //
            // *`seatResponder` feedeth the hint to `BleServerOrchestrationDriver.onLinkInfoWriteRequest`, which
            // runneth `BleRoleElection.elect(localHint, remoteHint)`. **Passing OUR OWN hint made the election
            // compare the local hint with itself -> `.tie` -> `RejectWrite("Tie or invalid role election")`** --
            // measured in the coordinator's live run. The parameter is what the FOREIGN INITIATOR wrote on the
            // link, which is its own advertised hint. Same for `seatInitiator`.*
            val peerAdvertised = remoteHint ?: ByteArray(0)
            if (isInitiator) rig.seatInitiator(ENDPOINT, address, peerAdvertised)
            else rig.seatResponder(ENDPOINT, address, peerAdvertised)
            ringBaseline = ringCount()
        }

        // ---------------------------------------------------------------------------------------------------------
        // observations (every one readeth an OWNER, never a worker counter)
        // ---------------------------------------------------------------------------------------------------------

        private fun isReady(): Boolean {
            val node = rig.nodeOf(ENDPOINT)
            val address = remoteAddress ?: return false
            val addressHex = hex(address.toByteArray())
            val mac = PeerId.fromAddress(address)
            val rosterHit = node.transport.linkReadyPeersForTest().any {
                hex(it) == addressHex || (mac != null && it.contentEquals(mac))
            }
            val viewHit = node.node.knownPeersForTest().let {
                it.contains(addressHex) || (mac != null && it.contains(hex(mac)))
            }
            return rosterHit && viewHit
        }

        private fun ringCount(): Int = rig.nodeOf(ENDPOINT).transport.rejectionRecordsForTest().size

        /** The receiver's durable row: **the exact `msgId` the FOREIGN platform authored, as this store holds it.** */
        private fun durableMsgId(): ByteArray? {
            val held = rig.heldMsgIds(ENDPOINT)
            val tracked = trackedMsgId
            if (tracked != null && held.any { it.contentEquals(tracked) }) return tracked
            return held.firstOrNull()
        }

        private fun isDelivered(): Boolean {
            val msgId = trackedMsgId ?: return false
            val row: DeliveryRow = rig.deliveryRow(ENDPOINT, msgId) ?: return false
            return DeliveryState.fromCode(row.state) == DeliveryState.ACKNOWLEDGED_BY_RECIPIENT
        }

        /** *** THE REFUSAL EVIDENCE IS READ FROM THE RECEIVER'S OWN REJECTION RING, BY NAME. *** */
        private fun newRingEntries(): List<String> {
            val ring = rig.nodeOf(ENDPOINT).transport.rejectionRecordsForTest()
            return ring.drop(ringBaseline).map { "${it.site}|${it.reason}" }
        }

        private fun refusalHeader(extra: Map<String, Any?> = emptyMap()): Map<String, Any?> {
            val refusals = newRingEntries()
            val head = LinkedHashMap<String, Any?>()
            head["ring"] = refusals.joinToString(", ")
            head["ring_size"] = refusals.size
            head["ready"] = isReady()
            head["held_rows"] = rig.heldMsgIds(ENDPOINT).size
            head.putAll(extra)
            return head
        }

        /** *** EMIT ONLY ON A CHANGE OF THE OWNER'S OWN STATE; the token is the owner's own answer. *** */
        private fun refreshReports(previous: String): String {
            val held = rig.heldMsgIds(ENDPOINT)
            if (role == "recipient") {
                val msgId = durableMsgId()
                if (msgId != null) {
                    val token = "row:" + hex(msgId)
                    if (token != previous) {
                        emit("observe", header = mapOf("durable_row" to "present", "msg_id" to hex(msgId),
                                                       "held_rows" to held.size))
                    }
                    return token
                }
                val refusals = newRingEntries()
                if (refusals.isNotEmpty()) {
                    val token = "refused:" + refusals.joinToString("|")
                    if (token != previous) {
                        emit("observe", header = mapOf("durable_row" to "absent", "held_rows" to held.size,
                                                       "refusal" to refusals.joinToString(", "),
                                                       "ring_size" to refusals.size, "ready" to isReady()))
                    }
                    return token
                }
                return previous
            }
            // *** A SENDER CAN BE REFUSED TOO, AND THAT MUST BE REPORTED: the `mismatched` control's refusal may
            // land on the SENDER's own handshake, so a sender that only ever reported delivery states would make the
            // control unobservable. ***
            val refusals = newRingEntries()
            val msgId = trackedMsgId
            val row = msgId?.let { rig.deliveryRow(ENDPOINT, it) }
            if (msgId != null && row != null) {
                val state = if (DeliveryState.fromCode(row.state) == DeliveryState.ACKNOWLEDGED_BY_RECIPIENT) {
                    "DELIVERED"
                } else {
                    "QUEUED"
                }
                val token = "delivery:$state:${refusals.size}"
                if (token != previous) {
                    emit("observe", header = mapOf("delivery" to state, "msg_id" to hex(msgId),
                                                   "durable_row" to if (held.any { it.contentEquals(msgId) }) {
                                                       "present"
                                                   } else {
                                                       "retired"
                                                   },
                                                   "refusal" to refusals.joinToString(", "),
                                                   "ring_size" to refusals.size))
                }
                return token
            }
            if (refusals.isNotEmpty()) {
                val token = "refused:" + refusals.joinToString("|")
                if (token != previous) {
                    emit("observe", header = mapOf("durable_row" to "absent",
                                                   "refusal" to refusals.joinToString(", "),
                                                   "ring_size" to refusals.size))
                }
                return token
            }
            return previous
        }

        private fun hex(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it) }

        private fun fromHex(text: String): ByteArray {
            if (text.length % 2 != 0) throw WorkerFraming.Refused("a hex string of odd length cannot be octets")
            return ByteArray(text.length / 2) { text.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
        }
    }

    /**
     * *A tiny byte queue: the framing is a STREAM, so a partial record must be carried across reads.* **A growable
     * primitive buffer rather than a boxing collection -- the worker carrieth ciphertext, and a boxed byte per octet
     * would be an avoidable allocation on every read.**
     */
    internal class ByteArrayQueue {
        private var bytes = ByteArray(1 shl 12)
        private var size = 0

        @Synchronized
        fun append(chunk: ByteArray) {
            if (size + chunk.size > bytes.size) {
                var grown = bytes.size * 2
                while (grown < size + chunk.size) grown *= 2
                bytes = bytes.copyOf(grown)
            }
            chunk.copyInto(bytes, size)
            size += chunk.size
        }

        @Synchronized fun size(): Int = size

        @Synchronized fun snapshot(): ByteArray = bytes.copyOf(size)

        @Synchronized fun clear() { size = 0 }

        @Synchronized fun takeExact(count: Int): ByteArray {
            val out = bytes.copyOf(count)
            bytes.copyInto(bytes, 0, count, size)
            size -= count
            return out
        }
    }
}
