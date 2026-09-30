package io.godstone.mesh.rig

import androidx.test.core.app.ApplicationProvider
import io.godstone.mesh.DirectDispatchResult
import io.godstone.mesh.delivery.AckObligationState
import io.godstone.mesh.delivery.AckVerificationClass
import io.godstone.mesh.delivery.DeliveryState
import io.godstone.mesh.delivery.InboxCommitResult
import io.godstone.mesh.delivery.ObligationLookup
import io.godstone.mesh.delivery.PairList
import io.godstone.mesh.di.MeshModule
import io.godstone.mesh.identity.WipeSensitiveUseGate
import io.godstone.mesh.wire.v2.FrameV2
import java.io.File
import java.io.FileOutputStream
import java.io.OutputStream
import java.net.URLClassLoader
import java.util.UUID
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * *** GS-INTEGRATION-001 `scenarios` (step 6), THE ANDROID HALF: A DURABLE BOUNDARY SURVIVING AN ABRUPT JVM DEATH. ***
 *
 * *The plan's own words: "Mirror the durable-boundary recovery assertions against Android's real host store/runtime
 * path using fresh Robolectric worker JVMs controlled by the same host coordinator. Do not kill a Gradle daemon or
 * unrelated test process; target the registered worker only."* **THIS FILE IS THAT MIRROR. It is the SIBLING — never
 * the replacement — of `RealTransportHostRigWorkerTest.CrashRoles`, which mirrors the same two boundaries on the
 * coordinator's own role names; this one adds its own explicit `board1DurableBoundaryWorker` Gradle task and its own
 * parent-driven kill, so neither court has to be reshaped for the other.**
 *
 * WHAT IS REAL HERE:
 *   * the estate is the REAL on-disk `JdbcStoreDb` built by `RealTransportHostRig` — the production provider
 *     (`MeshModule.provideMeshNode`), the production transport, and the production trust/ACK/dispatch owners, over
 *     real SQLite files that OUTLIVE the process;
 *   * both boundaries are reached through PRODUCTION roads — `MeshNode.dispatchDirect` for the outbound commit, and
 *     `RecipientInboxRepository.acceptVerifiedAndRequireAck` held at the inbox's OWN production `"signing"` fault
 *     seam for the inbound commit. **No production seam is added for either.**
 *   * the recovery runs in a FRESH JVM over the SAME estate and RESUMES through the production owner of that work —
 *     `AckObligationDriver.runPendingOnce` over the module's own providers.
 *   * the death is a REAL abrupt death of a REAL separate JVM, and the parent PROVES it was a kill by observing that
 *     the child was STILL ALIVE (blocked in its hold) at the instant before the fatal signal, and that no graceful
 *     completion line was ever printed.
 *
 * *** THE TWO BOUNDARIES THIS ISLE MIRRORS, AND THE FIVE IT DOES NOT. *** *The plan's step-6 table nameth seven.
 * Two are reachable on this isle's own host store roads without inventing a boundary; PRETENDING TO THE OTHER FIVE
 * WOULD BE A BOUNDARY THAT NEVER FIRED, so they stay with the macOS child-process campaign, which walketh the full
 * table.*
 *
 *   * **`outboundEnqueue`** — held "after the atomic held+delivery enqueue committed, before the FIRST radio byte".
 *     `MeshNode.dispatchDirect` commits the held frame AND the `QUEUED_DURABLY` delivery row in ONE transaction and
 *     ONLY THEN iterateth the route-eligible peers calling `send`; so the hold is taken INSIDE the FIRST `send`,
 *     which is the first statement after the durable commit. *A marker written from inside the store transaction
 *     would be, in the plan's own words, "NOT a durable-commit marker".*
 *   * **`inboundCommit`** — held at the recipient inbox's own `"signing"` fault seam, which
 *     `RecipientInboxRepository.issueOrRestoreAck` invokes AFTER the held+obligation transaction has returned
 *     `Committed` and BEFORE any ACK is constructed. *Production passeth `null` there, so no shipped road ever
 *     holds.*
 *
 * THE THREE ROLES, DECIDED BY SYSTEM PROPERTIES AND NOTHING ELSE:
 *
 *   * **no role** — THE PARENT CAMPAIGN. It asserts the wire laws, then for each boundary spawns a prepare child,
 *     waits for `READY` and then `AT_BOUNDARY <name>`, requires the child to be ALIVE at that instant, kills it,
 *     verifies the abrupt status, and then runs the recovery child over the same estate. **An ordinary invocation is
 *     therefore the campaign rather than an empty or skipped test.**
 *   * **`crash-prepare`** — the child. Build the real estate, emit `READY`, reach the boundary, flush
 *     `AT_BOUNDARY <name>` (to stdout AND as the coordinator's framed record on `godstone.integration.out`), then
 *     **END ABRUPTLY**: held for the parent's kill when `godstone.integration.holdForParentKill=true`, otherwise
 *     `Runtime.halt(137)` — never a graceful return, never a timed sleep that politely finishes.
 *   * **`crash-recover`** — a FRESH JVM over the SAME estate. It asserts the required post-restart result and prints
 *     `COMPLETE <boundary> PASS ...`.
 *
 * THE COORDINATOR'S CONTRACT (`tools/readiness/run_board1_integration.py`, `--mode crash`): the record framing is
 * `u32be header_len | header(utf8 JSON, carrying "kind") | u32be payload_len | payload`, the same one the sibling
 * worker speaks, emitted as `{"kind":"at_boundary",...}` before the death and
 * `{"kind":"complete","durable_row":"present",...}` from the recovery. *The coordinator never decodes a payload and
 * neither doth this file.* Reach it with:
 *
 *     GS_ANDROID_CRASH_TASK=:mesh:board1DurableBoundaryWorker \
 *     GS_ANDROID_CRASH_CLASS=io.godstone.mesh.rig.Board1DurableBoundaryWorkerTest \
 *       python3 tools/readiness/run_board1_integration.py --mode crash --evidence-dir PATH
 *
 * *** STORE-BACKEND SUBSTITUTION, STATED PLAINLY IN EVERY MANIFEST THIS PRODUCES. *** *The host JDBC SQLite engine
 * standeth in for the native SQLCipher link, exactly as every host harness on this isle substitutes it. **NEITHER
 * THIS COURT NOR ITS EVIDENCE CLAIMETH ANDROIDKEYSTORE OR APPROVED-SQLCIPHER-DEVICE PROOF.***
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33])
internal class Board1DurableBoundaryWorkerTest {

    // ============================================================================================
    // MARK: - the wire the coordinator readeth
    // ============================================================================================

    /**
     * *THE PROPERTY KEYS AND THE FRAMING THE COORDINATOR OWNS.* **Blank values are dropped exactly as the sibling
     * worker drops them**, because the committed Gradle task forwardeth an unset key as an EMPTY STRING: a worker
     * that tested only for `null` would take the empty string for a role and refuse an ordinary run — which is the
     * "empty/skipped test" the plan forbids, inverted.
     */
    private object Wire {
        const val ROLE = "godstone.integration.role"
        const val IN = "godstone.integration.in"
        const val OUT = "godstone.integration.out"
        const val ROOT = "godstone.integration.root"
        const val VARIANT = "godstone.integration.variant"
        const val BOUNDARY = "godstone.integration.boundary"
        const val DEADLINE = "godstone.integration.deadlineSeconds"
        const val EXPECTED_MSG_ID = "godstone.integration.expectedMsgId"

        /** *THIS FILE'S OWN KEY: a child HELD for its parent's kill rather than self-halted.* */
        const val HOLD = "godstone.integration.holdForParentKill"

        const val PREPARE = "crash-prepare"
        const val RECOVER = "crash-recover"

        /** *The abrupt status `Runtime.halt` carrieth, matching the sibling role and the plan's own number.* */
        const val HALT_CODE = 137

        fun props(): Map<String, String> = listOf(
            ROLE, IN, OUT, ROOT, VARIANT, BOUNDARY, DEADLINE, EXPECTED_MSG_ID, HOLD,
        ).mapNotNull { key -> System.getProperty(key)?.takeIf { it.isNotBlank() }?.let { key to it } }.toMap()

        private fun putU32(out: ByteArray, at: Int, value: Int) {
            out[at] = (value ushr 24).toByte()
            out[at + 1] = (value ushr 16).toByte()
            out[at + 2] = (value ushr 8).toByte()
            out[at + 3] = value.toByte()
        }

        private fun u32(bytes: ByteArray, at: Int): Int =
            ((bytes[at].toInt() and 0xFF) shl 24) or
                ((bytes[at + 1].toInt() and 0xFF) shl 16) or
                ((bytes[at + 2].toInt() and 0xFF) shl 8) or
                (bytes[at + 3].toInt() and 0xFF)

        /** *The metadata header; a marker carrieth no payload, and no payload is ever interpreted.* */
        fun frame(header: Map<String, Any?>): ByteArray {
            val head = json(header).toByteArray(Charsets.UTF_8)
            val out = ByteArray(4 + head.size + 4)
            putU32(out, 0, head.size)
            head.copyInto(out, 4)
            putU32(out, 4 + head.size, 0)
            return out
        }

        /**
         * *** THE MARKER RECORD THE PARENT SEEKETH, WALKED OUT OF THE CHANNEL'S CONCATENATED FRAMES. ***
         *
         * *THE DEFECT THIS CLOSES WAS MEASURED ON BOTH SIDES OF THE ISLE AND IN THIS FILE'S OWN ASSERTIONS: a
         * prepare child writeth TWO records -- `ready` when the estate is built, and `at_boundary` at the boundary --
         * so `length_of(ready) + length_of(at_boundary) != length_of(file)`. **A reader that framed only the record
         * at offset zero therefore called a whole marker "not parseable" and reported `bytes=391`/`bytes=380` for a
         * channel that held BOTH records intact** (the coordinator's own reader walketh the records; this file's
         * reader did not, and neither did the macOS twin's).*
         *
         * *The walk is the coordinator's own law: `u32be head_len | head | u32be payload_len | payload`, repeated
         * while whole records remain. `at_boundary`/`complete` return the FIRST record of that kind; `ready` keeps
         * its head-of-file meaning, because it IS the first record a prepare child writeth. A TORN OR UNKNOWN RECORD
         * IS STILL REFUSED: the walk stoppeth and only whole, canonical records are ever returned.*
         */
        fun recordOf(bytes: ByteArray, kind: String): Pair<String, Int>? =
            records(bytes).firstOrNull { (header, _) -> header.contains("\"kind\":\"$kind\"") }

        /** *Every WHOLE record in the channel, in order; a torn tail endeth the walk.* */
        fun records(bytes: ByteArray): List<Pair<String, Int>> {
            val out = ArrayList<Pair<String, Int>>()
            var at = 0
            while (at + 8 <= bytes.size) {
                val parsed = recordAt(bytes, at) ?: break
                out.add(parsed.first)
                at += parsed.second
            }
            return out
        }

        /** *One whole record at [at], as (header, total octets); null when it is not whole.* */
        private fun recordAt(bytes: ByteArray, at: Int): Pair<Pair<String, Int>, Int>? {
            val headLen = u32(bytes, at)
            if (headLen <= 0 || bytes.size < at + 4 + headLen + 4) return null
            val payLen = u32(bytes, at + 4 + headLen)
            val total = 4 + headLen + 4 + payLen
            if (bytes.size < at + total) return null
            return (String(bytes, at + 4, headLen, Charsets.UTF_8) to payLen) to total
        }

        private fun json(value: Map<String, Any?>): String =
            value.entries.sortedBy { it.key }.joinToString(prefix = "{", postfix = "}") { (key, v) ->
                "\"${escape(key)}\":" + jsonValue(v)
            }

        private fun jsonValue(value: Any?): String = when (value) {
            null -> "null"
            is String -> "\"${escape(value)}\""
            is Boolean, is Number -> value.toString()
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
    }

    // ============================================================================================
    // MARK: - the named boundaries, the estate labels and the bounds
    // ============================================================================================

    private companion object {
        const val OUTBOUND_ENQUEUE = "outboundEnqueue"
        const val INBOUND_COMMIT = "inboundCommit"

        /** *The boundaries this isle's own host roads reach; the plan's other five belong to the macOS campaign.* */
        val BOUNDARIES = listOf(OUTBOUND_ENQUEUE, INBOUND_COMMIT)

        const val ENDPOINT = "android-boundary"
        const val COUNTERPART = "android-boundary-peer"

        /** *Robolectric's own cold start plus a real handshake. Generous; and a TIMEOUT IS A FAILURE, not a skip.* */
        const val CHILD_BOUND_MILLIS = 180_000L

        /**
         * *** THE COLLECTOR SETTLE, GIVEN EXPLICITLY BY THIS COURT. ***
         *
         * *`RealTransportHostRig.open` waiteth for the peer collector's body to begin and then pauses 50ms "so the
         * two INNER collector jobs attach" -- its own comment recordeth the race: `peers()`/`received()` are COLD
         * `callbackFlow`s over a REPLAY-LESS `MutableSharedFlow`, so an event emitted before the inner collector
         * attaches is DROPPED, and a ladder driven immediately can lose the `Found` that maketh a peer routable.
         * **MEASURED IN A COLD CHILD JVM: the `outboundEnqueue` prepare child timed out with "both registries report
         * the peer ready" while the `inboundCommit` child -- WHICH NEVER LINKS -- succeeded, so the failure is the
         * fixture's handshake race under a cold JVM rather than any durable boundary.*** *This court therefore opens
         * both nodes ITSELF (idempotent) and grants a longer settle BEFORE the ladder fires. No production ordering is
         * touched and no readiness flag is fabricated: the assertion afterwards is still the rig's own exact-handle
         * readiness.*
         */
        const val COLLECTOR_SETTLE_MILLIS = 750L

        /** *The read/write bound on the marker channel, so a child blocked on a pipe is a bounded refusal.* */
        const val MARKER_IO_BOUND_MILLIS = 5_000L
    }

    // ============================================================================================
    // MARK: - the single test method, in three roles
    // ============================================================================================

    @Test
    fun testBoard1DurableBoundaryCampaign() {
        val props = Wire.props()
        when (val role = props[Wire.ROLE]) {
            null -> runParentCampaign()
            Wire.PREPARE -> runPrepareChild(props)
            Wire.RECOVER -> runRecoverChild(props)
            else -> throw AssertionError(
                "*** NO ROLE BY THE NAME '$role' STANDS. A worker that carried on with an unknown role would " +
                    "silently run the campaign and fork-bomb itself. ***",
            )
        }
    }

    // ============================================================================================
    // MARK: - the wire laws (cheap, always exercised, never a skip)
    // ============================================================================================

    /**
     * *** THE CONTRACT THIS FILE SHARES WITH THE COORDINATOR, ASSERTED RATHER THAN ASSUMED. *** *And the launch
     * preconditions, every one of which is a NAMED refusal rather than a silent downgrade to a no-op worker.*
     */
    private fun assertTheWireLaws() {
        val hostile = mapOf<String, Any?>(
            "kind" to "at_boundary", "boundary" to OUTBOUND_ENQUEUE, "msg_id" to "0a0b0c",
        )
        val framed = Wire.frame(hostile)
        val parsed = Wire.recordOf(framed, "at_boundary")
        assertNotNull("*** THE FRAME MUST PARSE. ***", parsed)
        val (header, payloadLen) = parsed!!
        assertEquals("no payload ever travels on a marker", 0, payloadLen)
        for (expected in listOf(
            "\"kind\":\"at_boundary\"", "\"boundary\":\"$OUTBOUND_ENQUEUE\"", "\"msg_id\":\"0a0b0c\"",
        )) {
            assertTrue("the framed header must carry $expected; got $header", header.contains(expected))
        }
        // *** AND A CONCATENATED CHANNEL IS WALKED, NOT MIS-FRAMED. ***
        //
        // *MEASURED: a prepare child writeth `ready` and THEN `at_boundary`, so a reader that parsed only the record
        // at offset zero reported "no parseable framed record" for a channel that held both whole. The walk findeth
        // the marker wherever it standeth, and it findeth NOTHING in a channel that holdeth no such record.*
        val readyRecord = Wire.frame(mapOf("v" to 1, "kind" to "ready", "platform" to "android",
            "boundary" to OUTBOUND_ENQUEUE))
        val two = readyRecord + framed
        assertEquals("the walk readeth BOTH records", 2, Wire.records(two).size)
        assertEquals(
            "and the marker is found though it is not the first record",
            header, Wire.recordOf(two, "at_boundary")?.first,
        )
        assertNull(
            "*** A CHANNEL THAT HOLDETH NO SUCH RECORD YIELDETH NOTHING. ***",
            Wire.recordOf(two, "complete"),
        )
        // AND A TRUNCATED RECORD IS REFUSED RATHER THAN HALF-READ.
        assertTrue(
            "*** A TRUNCATED RECORD MUST NOT PARSE. *** *A reader that accepted it would take a torn marker for a " +
                "whole one.*",
            Wire.records(framed.copyOfRange(0, framed.size - 1)).isEmpty(),
        )

        val complete = mapOf(Wire.ROLE to Wire.PREPARE, Wire.ROOT to "/tmp/e", Wire.OUT to "/tmp/o")
        for ((missing, props) in listOf(
            "the role" to (complete - Wire.ROLE),
            "a blank role" to (complete + (Wire.ROLE to "")),
            "an unknown role" to (complete + (Wire.ROLE to "bystander")),
            "the estate root" to (complete - Wire.ROOT),
            "the boundary" to (complete + (Wire.BOUNDARY to "") + (Wire.VARIANT to "")),
            "an unmapped boundary" to (complete + (Wire.BOUNDARY to "handshake")),
        )) {
            var refused = false
            try {
                validateLaunch(props)
            } catch (_: AssertionError) {
                refused = true
            }
            assertTrue("*** A LAUNCH MISSING $missing MUST BE REFUSED. ***", refused)
        }
    }

    /** *The launch's own preconditions, checked BEFORE any resource is touched.* */
    private fun validateLaunch(props: Map<String, String>) {
        val role = props[Wire.ROLE]
        if (role.isNullOrBlank()) throw AssertionError("no role was given")
        if (role != Wire.PREPARE && role != Wire.RECOVER) throw AssertionError("the role '$role' is unknown")
        if (props[Wire.ROOT].isNullOrBlank()) throw AssertionError("no estate root was given")
        if (role == Wire.PREPARE && props[Wire.OUT].isNullOrBlank()) throw AssertionError("no output channel was named")
        boundaryOf(props)
    }

    /**
     * *The boundary a role walketh.* **`boundary` is this file's own key; `variant` is read as the fallback because
     * the committed coordinator smuggleth it there.** *Blank values are absent values, throughout.*
     */
    private fun boundaryOf(props: Map<String, String>): String {
        val named = props[Wire.BOUNDARY] ?: props[Wire.VARIANT]
        if (named.isNullOrBlank()) throw AssertionError("no boundary was named")
        if (named !in BOUNDARIES) {
            throw AssertionError(
                "*** THIS ISLE MIRRORETH $BOUNDARIES AND NOTHING ELSE: '$named' would be a boundary that never " +
                    "fired. It belongeth to the macOS child-process campaign. ***",
            )
        }
        return named
    }

    // ============================================================================================
    // MARK: - the marker channel (stdout AND the coordinator's framing)
    // ============================================================================================

    /**
     * *THE MARKER WRITER.* **The framed record goeth to `godstone.integration.out` (a FIFO under the coordinator, a
     * regular file under this file's own campaign, which then PARSETH it) and the human line goeth to stdout for the
     * parent to read.** *Both are flushed BEFORE the abrupt end, so the marker arriveth though the JVM die th.*
     */
    private class Marker private constructor(private val output: OutputStream?) : AutoCloseable {
        fun emit(kind: String, line: String, fields: Map<String, Any?>) {
            val header = LinkedHashMap<String, Any?>()
            header["v"] = 1
            header["kind"] = kind
            header["platform"] = "android"
            header.putAll(fields)
            output?.let {
                it.write(Wire.frame(header))
                it.flush()
            }
            println(line)
            System.out.flush()
        }

        override fun close() {
            runCatching { output?.close() }
        }

        companion object {
            /**
             * **A CHANNEL THAT DOES NOT EXIST IS NO CHANNEL, AND THAT IS DELIBERATE**: opening a FIFO for writing
             * with no reader would block for ever, so the existence check is what keepeth an unlaunched worker from
             * hanging on a path nobody opened. *The parent's own campaign createth the file first, so its records are
             * always written.*
             */
            fun open(props: Map<String, String>): Marker {
                val path = props[Wire.OUT]
                return Marker(
                    path?.takeIf { File(it).exists() }
                        ?.let { runCatching { FileOutputStream(it) }.getOrNull() },
                )
            }
        }
    }

    // ============================================================================================
    // MARK: - the fixture's own environment controls (named, printed, never a fabrication)
    // ============================================================================================

    /**
     * *** A THROWAWAY LINK IN A THROWAWAY ESTATE, SO THE MEASURED ESTATE'S LINK IS NOT THE FIRST ONE THIS JVM EVER
     * DREW. ***
     *
     * *A cold JVM pays for coroutine/BouncyCastle/Noise class loading and provider registration on FIRST use, and the
     * fixture's handshake window is a fixed 2-second bound -- so a cold child can lose that race for reasons that have
     * NOTHING to do with any durable boundary.* **The warm-up runs on its OWN temp estate and is torn down, so the
     * measured estate is untouched and its durable material is still the whole of the evidence. A warm-up that fails
     * is PRINTED as an environment refusal rather than swallowed, and the measured arm proceeds to report its own
     * outcome honestly.**
     */
    private fun warmUpTheJvm() {
        // *** THREE ATTEMPTS, AND EVERY FAILING ATTEMPT'S DIAGNOSTIC IS PRINTED. ***
        //
        // *The fixture's handshake window is a fixed 2-second bound, and a cold JVM can lose it on the FIRST rung;
        // a SECOND link in the same JVM is already warm. **MEASURED: a warm-up that skipped the collector settle --
        // the step-5 `deliver` legs now hand the handshake's FIRST records to nobody unless both ends' `peers()` /
        // `received()` inner collectors have attached, and those are COLD replay-less flows -- lost the sealed
        // confirmation round on BOTH rungs and reported only `transportRoster=[]` with a route-eligible view and an
        // empty ring, which is the very "Found is dropped" race `RealTransportHostRig.open`'s own comment recordeth.
        // The measured arm already granteth [COLLECTOR_SETTLE_MILLIS]; the warm-up now granteth the same pause and
        // ALSO requires the rig's exact-handle readiness, so a rung that merely began is never taken for a warm
        // one.** The retry is still not allowed to hide a reason: every failing attempt's readiness detail (both
        // registries, the route-eligible view and the rejection ring) is PRINTED.*
        for (attempt in 1..3) {
            val dir = File(System.getProperty("java.io.tmpdir")!!, "gs-boundary-warmup-${UUID.randomUUID()}")
            assertTrue("the warm-up root must be creatable", dir.mkdirs())
            val rig = RealTransportHostRig(ApplicationProvider.getApplicationContext(), dir)
            try {
                rig.makeNode("warmup-a")
                rig.makeNode("warmup-b")
                rig.open("warmup-a")
                rig.open("warmup-b")
                Thread.sleep(COLLECTOR_SETTLE_MILLIS)
                val link = rig.electLink("warmup-a", "warmup-b")
                try {
                    rig.link("warmup-a", "warmup-b")
                    if (rig.waitUntil(600, pollMillis = 5L) { rig.isLinkReady(link) }) {
                        println("GS-BOUNDARY warm-up attempt=$attempt link ready=true")
                        return
                    }
                    println(
                        "GS-BOUNDARY warm-up attempt=$attempt FAILED: the link never reported ready ;; " +
                            rig.linkReadinessDetail(link),
                    )
                } catch (t: Throwable) {
                    println(
                        "GS-BOUNDARY warm-up attempt=$attempt FAILED: $t ;; " + rig.linkReadinessDetail(link),
                    )
                }
            } finally {
                runCatching { rig.tearDown() }
                runCatching { dir.deleteRecursively() }
            }
        }
        throw AssertionError(
            "*** THE FIXTURE'S OWN HANDSHAKE COULD NOT BE ESTABLISHED IN THREE ATTEMPTS, so no durable-boundary " +
                "claim can be made from this JVM. The diagnostics above name the fixture state. ***",
        )
    }

    /**
     * *ESTABLISH THE MEASURED RELATION, WITH THE SETTLE GRANTED BEFORE THE LADDER FIRES.* **The readiness assertion
     * afterwards is still the rig's OWN exact-handle observation, so nothing here weakens what "ready" meaneth.**
     */
    private fun establishMeasuredLink(rig: RealTransportHostRig): RealTransportHostRig.Link {
        // *`open` is IDEMPOTENT, so calling it here is what buyeth the settle time: `link`'s own `open` calls then
        // return at once and the ladder fires only after this pause.*
        rig.open(ENDPOINT)
        rig.open(COUNTERPART)
        Thread.sleep(COLLECTOR_SETTLE_MILLIS)
        val link = rig.electLink(ENDPOINT, COUNTERPART)
        try {
            rig.link(ENDPOINT, COUNTERPART)
        } catch (t: Throwable) {
            throw AssertionError(
                "*** THE FIXTURE'S HANDSHAKE FOR THE MEASURED ESTATE NEVER COMPLETED: $t ;; " +
                    rig.linkReadinessDetail(link),
            )
        }
        assertTrue(
            "the measured link never became ready: " + rig.linkReadinessDetail(link),
            rig.waitUntil(600, pollMillis = 5L) { rig.isLinkReady(link) },
        )
        return link
    }

    /**
     * *THE AUTHOR IS THE ELECTION'S OPENER, AND THAT IS A MEASURED REQUIREMENT RATHER THAN SCENERY.*
     *
     * *`dispatchDirect` offereth to `knownPeers()` -- the ROUTE-ELIGIBLE view -- and production populateth that view
     * ONLY for the party that published APPLICATION LinkReady, which is the INITIATOR. **An author who is the responder
     * can never offer to anybody, so a hold placed there would NEVER FIRE** -- the exact measured failure the macOS
     * twin recorded.* *The election is deterministic from the two identities' hints, which the estate persisteth, so
     * the recovery process deriveth the SAME author with the same call.*
     */
    private fun electionOpener(rig: RealTransportHostRig): String =
        rig.electLink(ENDPOINT, COUNTERPART).let { if (it.aOpened) it.a else it.b }

    private fun peerOf(author: String): String = if (author == ENDPOINT) COUNTERPART else ENDPOINT

    // ============================================================================================
    // MARK: - PHASE 1: the prepare child (reach the boundary, flush, END ABRUPTLY)
    // ============================================================================================

    private fun runPrepareChild(props: Map<String, String>) {
        validateLaunch(props)
        val boundary = boundaryOf(props)
        val marker = Marker.open(props)
        val root = File(props.getValue(Wire.ROOT)).also { it.mkdirs() }
        val rig = RealTransportHostRig(ApplicationProvider.getApplicationContext(), File(root, "estate"))
        rig.makeNode(ENDPOINT)
        rig.makeNode(COUNTERPART)
        val endpoint = rig.nodeOf(ENDPOINT)
        val counterpart = rig.nodeOf(COUNTERPART)

        // *** `READY` IS ANNOUNCED *BEFORE* THE OPERATION, AND THE ORDER IS LOAD-BEARING. *** *The boundary HOLD
        // blocketh INSIDE the production call, so a `READY` printed afterwards could never be printed at all — the
        // parent would time out waiting for a line the child was never going to reach. **So `READY` meaneth "the
        // estate is really built and the production road is being driven", and `AT_BOUNDARY` meaneth "the durable
        // boundary was genuinely reached". Their separation is what maketh "missing marker" a distinguishable
        // failure rather than a mystery.***
        marker.emit("ready", "READY boundary=$boundary", mapOf("boundary" to boundary))

        when (boundary) {
            // *** AFTER THE ATOMIC held+delivery ENQUEUE COMMITTED, BEFORE THE FIRST RADIO BYTE. ***
            OUTBOUND_ENQUEUE -> {
                // *The measured estate's link must not be this JVM's FIRST -- see [warmUpTheJvm].*
                warmUpTheJvm()
                establishMeasuredLink(rig)
                val author = electionOpener(rig)
                val authorNode = rig.nodeOf(author)
                val recipient = peerOf(author)
                assertTrue(
                    "*** THE AUTHOR MUST SEE A ROUTE-ELIGIBLE PEER, or production never offereth and the boundary " +
                        "would never fire. author=$author knownPeers=${authorNode.node.knownPeersForTest()} ***",
                    authorNode.node.knownPeersForTest().isNotEmpty(),
                )
                val frame = rig.authorDirectFrame(
                    author, recipient, "boundary-$boundary".toByteArray(Charsets.US_ASCII),
                )
                val msgIdHex = hex(frame.msgId)
                val fired = AtomicBoolean(false)
                val outcome = runBlocking {
                    authorNode.node.dispatchDirect(frame, rig.nodeOf(recipient).identity.nodeId) { _, _ ->
                        if (fired.compareAndSet(false, true)) {
                            marker.emit(
                                "at_boundary",
                                "AT_BOUNDARY $boundary author=$author msg_id=$msgIdHex",
                                mapOf(
                                    "boundary" to boundary, "msg_id" to msgIdHex, "author" to author,
                                    "detail" to "the atomic held+delivery enqueue returned success; halting inside " +
                                        "the first radio offer, before any byte reacheth the transport",
                                ),
                            )
                            endAbruptly(props)
                        }
                        false
                    }
                }
                throw AssertionError(
                    "*** THE CHILD RETURNED FROM `dispatchDirect` WITH $outcome WITHOUT REACHING $boundary. " +
                        "A boundary that never fires is a FAILED SCENARIO. ***",
                )
            }

            // *** AFTER THE held+obligation TRANSACTION RETURNED, BEFORE SIGNING. ***
            INBOUND_COMMIT -> {
                val frame = rig.authorDirectFrame(
                    COUNTERPART, ENDPOINT, "boundary-$boundary".toByteArray(Charsets.US_ASCII),
                )
                val msgIdHex = hex(frame.msgId)
                val fired = AtomicBoolean(false)
                val result = runBlocking {
                    endpoint.node.recipientInbox!!.acceptVerifiedAndRequireAck(
                        frame, counterpart.identity.nodeId,
                    ) { seam ->
                        if (seam == "signing" && fired.compareAndSet(false, true)) {
                            marker.emit(
                                "at_boundary",
                                "AT_BOUNDARY $boundary holder=$ENDPOINT msg_id=$msgIdHex",
                                mapOf(
                                    "boundary" to boundary, "msg_id" to msgIdHex, "holder" to ENDPOINT,
                                    "detail" to "the held+ACK-obligation transaction returned success; halting at " +
                                        "the production 'signing' seam, before any ACK is constructed",
                                ),
                            )
                            endAbruptly(props)
                        }
                    }
                }
                throw AssertionError(
                    "*** THE INBOX ANSWERED $result WITHOUT REACHING THE 'signing' SEAM, so $boundary never fired. ***",
                )
            }

            else -> throw AssertionError("no prepare road for boundary '$boundary'")
        }
    }

    /**
     * *** THE ABRUPT END. AND THE WORD "ABRUPT" IS THE WHOLE CLAIM. ***
     *
     * *Held for the parent's kill when this file's own campaign launched the child (`holdForParentKill=true`), so the
     * parent can PROVE the child was alive at the fatal instant; otherwise `Runtime.halt(137)`, which terminateth the
     * JVM AT ONCE — no `finally` blocks, no shutdown hooks, no flushed-then-closed stores.* **Never a graceful
     * return, and never a timed sleep that politely finishes: the plan's own words are that a graceful close is not
     * crash proof.**
     */
    private fun endAbruptly(props: Map<String, String>): Nothing {
        if (props[Wire.HOLD] == "true") hold()
        System.out.flush()
        System.err.flush()
        Runtime.getRuntime().halt(Wire.HALT_CODE)
        throw AssertionError("unreachable: Runtime.halt returned")
    }

    /** *The hold: a bounded sleep loop, never a single infinite sleep, so the process stayeth inspectable.* */
    private fun hold(): Nothing {
        while (true) {
            try {
                Thread.sleep(30_000L)
            } catch (_: InterruptedException) {
                // *The hold is ended by the parent's signal and nothing else, so an interrupt is ignored.*
            }
        }
    }

    // ============================================================================================
    // MARK: - PHASE 2: the recovery child (a FRESH JVM over the SAME estate)
    // ============================================================================================

    /**
     * *THE REQUIRED POST-RESTART RESULT, PER BOUNDARY.* **Every assertion below read eth a REAL OWNER — the durable
     * store, the obligation store, production's own authenticator — and never a court counter.**
     */
    private fun runRecoverChild(props: Map<String, String>) {
        validateLaunch(props)
        val boundary = boundaryOf(props)
        val expected = props[Wire.EXPECTED_MSG_ID]
        val marker = Marker.open(props)
        val root = File(props.getValue(Wire.ROOT)).also { it.mkdirs() }
        val rig = RealTransportHostRig(ApplicationProvider.getApplicationContext(), File(root, "estate"))
        try {
            rig.makeNode(ENDPOINT)
            rig.makeNode(COUNTERPART)
            val endpoint = rig.nodeOf(ENDPOINT)
            val counterpart = rig.nodeOf(COUNTERPART)

            // *** NO READY RELATION AND NO ROUTE-ELIGIBLE PEER MAY BE INHERITED ACROSS A KILL. *** *The
            // predecessor's transport epoch died with it; a fresh transport that already held a relation would mean
            // the estate carried readiness, which no set of FILES should ever be able to.*
            assertTrue(
                "*** NO READY RELATION MAY BE INHERITED FROM THE ESTATE. ***",
                endpoint.transport.linkReadyPeersForTest().isEmpty(),
            )
            assertTrue(
                "*** AND NO ROUTE-ELIGIBLE PEER EITHER. ***",
                endpoint.node.knownPeersForTest().isEmpty(),
            )

            val detail = when (boundary) {
                OUTBOUND_ENQUEUE -> {
                    // *The measured estate's link must not be this JVM's FIRST, so the environment is warmed on a
                    // throwaway estate first — see [warmUpTheJvm].*
                    warmUpTheJvm()
                    recoverOutbound(rig, expected)
                }
                INBOUND_COMMIT -> recoverInbound(rig, endpoint, counterpart, expected)
                else -> throw AssertionError("no recovery road for boundary '$boundary'")
            }
            marker.emit(
                "complete",
                "COMPLETE $boundary PASS durable_row=present detail=$detail",
                mapOf(
                    "boundary" to boundary, "durable_row" to "present", "msg_id" to (lastMsgIdHex ?: ""),
                    "delivery" to detail,
                    "detail" to "a FRESH JVM over the SAME estate read the owners' own durable answers",
                ),
            )
        } finally {
            runCatching { rig.tearDown() }
            marker.close()
        }
    }

    /** *The msgId the recovery actually observed, so the completion record carrieth the REAL receipt.* */
    private var lastMsgIdHex: String? = null

    /**
     * *`outboundEnqueue`: "Same accepted msgId and queued delivery row survive; no DELIVERED; resumption transmits it
     * without a second authoring intent."*
     */
    private fun recoverOutbound(
        rig: RealTransportHostRig,
        expected: String?,
    ): String {
        // *** THE AUTHOR IS DERIVED, NOT ASSUMED. *** *The production election is deterministic from the two
        // identities' hints, which the estate persistent, so this process nameth the same author the dying process
        // drove — and a hard-coded label would report "no delivery row stands" for a row that was perfectly present
        // on its true owner, which is exactly the failure the macOS twin recorded.*
        val author = electionOpener(rig)
        val recipient = peerOf(author)
        val recipientId = rig.nodeOf(recipient).identity.nodeId

        val msgId = onlyHeldMsgId(rig, author)
        lastMsgIdHex = hex(msgId)
        if (!expected.isNullOrBlank()) {
            assertEquals(
                "*** THE SURVIVING RECEIPT MUST BE THE VERY msgId THE DYING PROCESS ACCEPTED — resumption must " +
                    "not author a second one. ***",
                expected, hex(msgId),
            )
        }
        assertNotNull("*** THE QUEUED DELIVERY ROW MUST SURVIVE THE KILL. ***", rig.deliveryRow(author, msgId))
        assertEquals(
            "*** THE PRE-RADIO COMMIT MUST NOT CLAIM DELIVERY: the row must stand QUEUED_DURABLY. ***",
            DeliveryState.QUEUED_DURABLY, rig.deliveryState(author, msgId),
        )
        assertFalse(
            "*** AND IT MUST NOT READ DELIVERED — nothing local may advance it. ***",
            rig.deliveryState(author, msgId) == DeliveryState.ACKNOWLEDGED_BY_RECIPIENT,
        )

        // *** THE RESUMED PROCESS OFFERS THE SAME CANONICAL FRAME, WITH NO SECOND AUTHORING INTENT. ***
        //
        // *`dispatchDirect` offereth to `knownPeers()` — the ROUTE-ELIGIBLE view — so on a freshly reopened estate
        // the offer count is legitimately ZERO until a relation is negotiated. The fresh callbacks therefore
        // negotiate their own relation, and the offer is then measured against a peer that really stands.* **MEASURED
        // on the macOS twin: an arm that skipped this step demanded a peer that was never connected.**
        val link = establishMeasuredLink(rig)
        assertTrue(
            "the fresh callbacks must negotiate their own relation: " + rig.linkReadinessDetail(link),
            rig.isLinkReady(link),
        )
        val held = runBlocking { rig.nodeOf(author).messageStore.allHeldOrderedByPriority() }
        assertEquals("exactly one durable frame must survive", 1, held.size)
        val durableFrame = held.first()
        assertEquals("the durable frame must BE the accepted receipt", hex(msgId), hex(durableFrame.msgId))

        var offered = 0
        var offeredMsgIdHex: String? = null
        val outcome = runBlocking {
            rig.nodeOf(author).node.dispatchDirect(durableFrame, recipientId) { _, _ ->
                offered++
                offeredMsgIdHex = hex(durableFrame.msgId)
                false
            }
        }
        assertEquals(
            "*** THE RESUMPTION MUST RE-OFFER THE DURABLE FRAME EXACTLY ONCE. *** got=$offered " +
                "ring=${rig.ring(author)}",
            1, offered,
        )
        assertEquals(
            "*** AND IT MUST BE THE SAME CANONICAL msgId, NOT A RE-AUTHORED ONE. ***",
            hex(msgId), offeredMsgIdHex,
        )
        assertEquals(
            "*** THE RESUMED HAND-OFF MUST STILL CLAIM NOTHING: every offer was refused, so the outcome is " +
                "QueuedLocally. ***",
            DirectDispatchResult.QueuedLocally, outcome,
        )
        assertEquals(
            "*** THE RESUMPTION MUST NOT AUTHOR A SECOND ROW. ***",
            1, rig.heldMsgIds(author).size,
        )
        assertEquals(
            "*** AND THE ROAD THAT RE-OFFERED IT MUST NOT HAVE ADVANCED THE DURABLE STATE. ***",
            DeliveryState.QUEUED_DURABLY, rig.deliveryState(author, msgId),
        )
        return "author=$author state=${DeliveryState.QUEUED_DURABLY.name} offered=$offered"
    }

    /**
     * *`inboundCommit`: "One inbox row and pending obligation survive; recovery produces one canonical ACK; replay
     * adds no second inbox entry."*
     */
    private fun recoverInbound(
        rig: RealTransportHostRig,
        endpoint: RealTransportHostRig.Node,
        counterpart: RealTransportHostRig.Node,
        expected: String?,
    ): String {
        val ourNodeId = endpoint.identity.nodeId
        val msgId = onlyHeldMsgId(rig, ENDPOINT)
        lastMsgIdHex = hex(msgId)
        if (!expected.isNullOrBlank()) {
            assertEquals(
                "*** THE SURVIVING INBOX ROW MUST BE THE VERY msgId THE DYING PROCESS ACCEPTED. ***",
                expected, hex(msgId),
            )
        }

        // (1) THE PENDING OBLIGATION SURVIVED, AND NO ACK ROW WAS FILED BEFORE THE KILL.
        when (val obligation = endpoint.ackStore.lookupObligation(msgId, ourNodeId)) {
            is ObligationLookup.Found -> assertEquals(
                "*** THE OBLIGATION MUST STAND PENDING (retryable) AFTER THE KILL. ***",
                AckObligationState.PENDING, obligation.obligation.state,
            )
            ObligationLookup.Absent -> throw AssertionError("*** THE PENDING ACK OBLIGATION MUST SURVIVE. ***")
            is ObligationLookup.Corrupt -> throw AssertionError("the obligation row is corrupt: ${obligation.reason}")
            ObligationLookup.StorageFailure -> throw AssertionError("the obligation lookup refused (storage)")
        }
        assertEquals(
            "*** NO ACK ROW MAY HAVE BEEN FILED BEFORE THE CRASH. ***",
            0, endpoint.ackStore.countForPair(msgId, ourNodeId),
        )

        // (2) *** RECOVERY RESUMES THROUGH THE PRODUCTION OWNER OF THAT WORK. ***
        //
        // *`AckObligationDriver` IS section 14's bounded worker: it is stateless between runs, RE-READETH the pending
        // set from the durable store, signs through the production `IdentityAckSigner` (which NEVER releases the
        // seed — the immediate road's seed seam is deliberately refused by production), verifies its own frame under
        // the pinned key, and files the frame row TOGETHER with the obligation retirement in ONE transaction.*
        // **Nothing here mints an ACK: the bytes production produced are the bytes asserted on.***
        val ackStore = MeshModule.provideAckStore(endpoint.messageStore)
        val wipeGate = WipeSensitiveUseGate { endpoint.gate.isActive }
        val gatedStore = MeshModule.provideWipeGatedAckStore(ackStore, wipeGate)
        val resolver = MeshModule.provideBoundRecipientKeyResolver(endpoint.peerRepository, endpoint.gate, wipeGate)
        val authenticator = MeshModule.provideEd25519AckAuthenticator(resolver)
        val driver = MeshModule.provideAckDriver(gatedStore, endpoint.identity, authenticator, resolver)
        val report = driver.runPendingOnce(8)
        val census =
            "scanned=${report.scanned} signed=${report.signed} retired=${report.retired} " +
                "keyUnavailable=${report.keyUnavailable} idempotent=${report.idempotent} " +
                "refusedQuota=${report.refusedQuota} storageFailures=${report.storageFailures}"
        assertEquals("*** THE RESUMPTION MUST SCAN THE SURVIVING OBLIGATION. *** $census", 1, report.scanned)
        assertEquals("*** RECOVERY MUST PRODUCE EXACTLY ONE CANONICAL ACK. *** $census", 1, report.signed)
        assertEquals("*** AND THE OBLIGATION MUST RETIRE WITH IT. *** $census", 1, report.retired)
        assertEquals("*** AND NOTHING MAY BE REFUSED FOR A MISSING KEY. *** $census", 0, report.keyUnavailable)
        assertEquals("*** NOR MAY ANY PAIR STEP FAIL. *** $census", 0, report.storageFailures)

        // (3) THE SURVIVING BYTES ARE PRODUCTION'S, AND THEY PASS PRODUCTION'S OWN PINNED-KEY VERIFIER.
        val storedAck = storedAck(endpoint, msgId, ourNodeId)
        assertEquals("the regenerated ACK must name the surviving receipt", hex(msgId), hex(storedAck.msgId))
        assertTrue(
            "*** THE REGENERATED ACK MUST PASS PRODUCTION'S OWN AUTHENTICATOR, OR IT IS NOT AN ACK AT ALL. ***",
            authenticator.verify(
                originalMsgId = storedAck.msgId, expectedRecipientNodeId = ourNodeId, ackFrame = storedAck,
            ),
        )
        assertEquals("exactly one ACK row after recovery", 1, endpoint.ackStore.countForPair(msgId, ourNodeId))
        when (val after = endpoint.ackStore.lookupObligation(msgId, ourNodeId)) {
            ObligationLookup.Absent -> Unit
            is ObligationLookup.Found -> throw AssertionError(
                "*** THE OBLIGATION MUST HAVE RETIRED WITH ITS FRAME ROW, got ${after.obligation.state} ***",
            )
            is ObligationLookup.Corrupt -> throw AssertionError("the obligation row is corrupt: ${after.reason}")
            ObligationLookup.StorageFailure -> throw AssertionError("the obligation lookup refused (storage)")
        }

        // (4) *** AND A REPLAY OF THE SAME FRAME ADDS NO SECOND INBOX ENTRY. ***
        //
        // *The stored VERIFIED_RECIPIENT row answereth a duplicate with the VERY bytes first filed — regenerating by
        // re-signing is forbidden, because the durable row is the truth. So the replay's answer must BE those bytes.*
        val replayFrame = runBlocking { endpoint.messageStore.allHeldOrderedByPriority() }.first()
        val replay = runBlocking {
            endpoint.node.recipientInbox!!.acceptVerifiedAndRequireAck(replayFrame, counterpart.identity.nodeId)
        }
        val replayed = when (replay) {
            is InboxCommitResult.Duplicate -> replay.ack
            is InboxCommitResult.New -> throw AssertionError(
                "*** A REPLAY MUST NOT BE A NEW ADMISSION — the frame was already committed. ***",
            )
            is InboxCommitResult.Rejected -> throw AssertionError(
                "*** THE REPLAY WAS REFUSED FOR THE WRONG REASON: ${replay.reason} ${replay.detail ?: ""} ***",
            )
            else -> throw AssertionError("the inbox answered an unknown class: $replay")
        }
        assertTrue(
            "*** THE REPLAY MUST BE ANSWERED BY THE VERY BYTES FIRST FILED, NOT A RE-SIGNED FRAME. ***",
            replayed.encode().contentEquals(storedAck.encode()),
        )
        assertEquals(
            "*** A REPLAY MUST NOT ADD A SECOND INBOX ENTRY. ***",
            1, rig.heldMsgIds(ENDPOINT).size,
        )
        assertEquals(
            "*** AND IT MUST NOT FILE A SECOND ACK ROW EITHER. ***",
            1, endpoint.ackStore.countForPair(msgId, ourNodeId),
        )
        return "holder=$ENDPOINT acks=${report.signed} retired=${report.retired} inboxRows=1"
    }

    /** *The exact bytes of the stored ACK row, decoded from the durable record — never re-signed.* */
    private fun storedAck(
        endpoint: RealTransportHostRig.Node,
        msgId: ByteArray,
        ourNodeId: ByteArray,
    ): FrameV2 {
        val rows = when (val census = endpoint.ackStore.candidatesForPair(msgId, ourNodeId, 4)) {
            is PairList.Records -> census.records
            is PairList.Corrupt -> throw AssertionError("the ACK pair census is corrupt: ${census.reason}")
            PairList.StorageFailure -> throw AssertionError("the ACK pair census refused (storage)")
            else -> throw AssertionError("the ACK pair census answered nothing")
        }
        val verified = rows.firstOrNull { it.verificationClass == AckVerificationClass.VERIFIED_RECIPIENT }
            ?: throw AssertionError("*** NO VERIFIED RECIPIENT ACK ROW STANDS FOR THE RECEIPT. ***")
        return FrameV2.decode(verified.encodedFrame)
            ?: throw AssertionError("the stored ACK row does not decode")
    }

    private fun onlyHeldMsgId(rig: RealTransportHostRig, label: String): ByteArray {
        val ids = rig.heldMsgIds(label)
        assertEquals("*** EXPECTED EXACTLY ONE SURVIVING HELD ROW ON $label. ***", 1, ids.size)
        return ids.first()
    }

    private fun hex(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it) }

    // ============================================================================================
    // MARK: - the parent campaign: spawn, mark, KILL, verify, recover
    // ============================================================================================

    /**
     * *** THE PARENT RUNS THE CAMPAIGN; THE SAME CLASS RUNS THE CHILD. *** *The parent launch eth the child as a REAL
     * separate JVM through `JUnitCore` on the test runtime classpath, so what it kill eth is a genuine process rather
     * than a coroutine that stopped.*
     */
    private fun runParentCampaign() {
        assertTheWireLaws()

        val java = File(System.getProperty("java.home")!!, "bin" + File.separator + "java").absolutePath
        assertTrue("the java launcher must exist at $java", File(java).isFile)
        val classpath = childClasspath()
        val root = File(System.getProperty("java.io.tmpdir")!!, "gs-board1-boundary-${UUID.randomUUID()}")
        assertTrue("the campaign root must be creatable", root.mkdirs())

        println("GS-BOUNDARY platform=android java=$java")
        println(
            "GS-BOUNDARY store-backend=host-JDBC-SQLite (the SQLCipher substitution every host harness makes; " +
                "NO AndroidKeyStore and NO approved-device-SQLCipher claim)",
        )
        println("GS-BOUNDARY classpath-entries=${classpath.split(File.pathSeparator).size} root=$root")

        val failures = ArrayList<String>()
        for (boundary in BOUNDARIES) {
            try {
                val estate = File(root, "gs-boundary-$boundary")
                assertTrue("the estate must be creatable", estate.mkdirs())
                val prepared = prepareScenario(java, classpath, boundary, estate)
                val recovered = recoverScenario(java, classpath, boundary, estate, prepared)
                println(
                    "GS-BOUNDARY $boundary: prepare-pid=${prepared.pid} " +
                        "warmup=${prepared.warmUpLine} ready=${prepared.readySeen} " +
                        "alive-at-marker=${prepared.aliveAtMarker} " +
                        "termination=abrupt child-exit=${prepared.exit} " +
                        "no-graceful-completion=${prepared.noCompletion} " +
                        "record=${prepared.recordHeader} ;; " +
                        "recover-exit=${recovered.exit} complete=${recovered.line}",
                )
            } catch (t: Throwable) {
                failures += "$boundary: ${t.message}"
                println("GS-BOUNDARY $boundary: FAIL -- ${t.message}")
            }
        }
        assertTrue(
            "*** EVERY NAMED BOUNDARY MUST SURVIVE A REAL ABRUPT JVM DEATH AND A REAL REOPEN. *** *A missing marker, " +
                "a cooperative exit, a timeout and an early exit are all FAILED scenarios rather than skips.* " +
                "Observed failures: $failures ***",
            failures.isEmpty(),
        )
    }

    private class Prepared(
        val pid: Long,
        val warmUpLine: String,
        val readySeen: Boolean,
        val aliveAtMarker: Boolean,
        val exit: Int,
        val noCompletion: Boolean,
        val recordHeader: String,
        val msgIdHex: String,
    )

    private class Recovered(val exit: Int, val line: String)

    /**
     * *ONE PREPARE CHILD: launch, wait for `READY` and then the boundary marker, PROVE IT IS STILL ALIVE, KILL IT,
     * VERIFY THE ABRUPT STATUS, and read the framed record it left.*
     */
    private fun prepareScenario(
        java: String,
        classpath: String,
        boundary: String,
        estate: File,
    ): Prepared {
        val records = File(estate, "prepare.records").also { assertTrue("the record file must be creatable", it.createNewFile()) }
        val log = File(estate, "prepare.log")
        val child = launchChild(
            java, classpath, log,
            mapOf(
                Wire.ROLE to Wire.PREPARE,
                Wire.BOUNDARY to boundary,
                Wire.ROOT to estate.absolutePath,
                Wire.OUT to records.absolutePath,
                Wire.HOLD to "true",
            ),
        )
        // *** `READY` FIRST, SO A SETUP FAILURE IS DISTINGUISHABLE FROM A BOUNDARY FAILURE. ***
        val readyLine = child.await("READY", CHILD_BOUND_MILLIS)
        val readySeen = readyLine != null
        if (!readySeen) {
            child.terminate()
            val warmUpLine = child.linesForDiagnostic().firstOrNull { it.startsWith("GS-BOUNDARY warm-up") }
            throw AssertionError(
                "*** THE PREPARE CHILD NEVER REACHED `READY` WITHIN ${CHILD_BOUND_MILLIS / 1000}s, so the estate " +
                    "was never built and NO boundary claim can be made. *** child-exit=${child.exitIfFinished()} " +
                    "warm-up=${warmUpLine ?: "(none printed)"} transcript-tail=\n${child.tail()}",
            )
        }
        val marker = child.await("AT_BOUNDARY $boundary", CHILD_BOUND_MILLIS)
        if (marker == null) {
            child.terminate()
            throw AssertionError(
                "*** A CHILD MARKER NEVER ARRIVED WITHIN ${CHILD_BOUND_MILLIS / 1000}s. A missing marker, a wrong " +
                    "termination, a timeout and an early exit are all FAILED SCENARIOS, never skips. *** " +
                    "child-exit=${child.exitIfFinished()} transcript-tail=\n${child.tail()}",
            )
        }

        // *** THE KILL, AND THE PROOF THAT IT WAS A KILL. ***
        //
        // *The child is BLOCKED IN THE HOLD at this instant — it emitted its marker and never returned — so a child
        // that is ALREADY DEAD here exited COOPERATIVELY, which is exactly what the plan forbideth. That observation
        // is the discriminator the status code alone cannot give: `Runtime.halt(137)` and a SIGKILL both report 137
        // to a Java parent, but only a LIVE child can be killed.*
        val aliveAtMarker = child.isAlive()
        assertTrue(
            "*** THE CHILD MUST STILL BE ALIVE AT THE BOUNDARY — a child that already exited cooperatively is not " +
                "crash evidence. *** child-exit=${child.exitIfFinished()} transcript-tail=\n${child.tail()}",
            aliveAtMarker,
        )
        child.killAbruptly()
        val exit = child.awaitExit()

        // *READ THE TRANSCRIPT BEFORE CLOSING, so the completion check is on the WHOLE record.*
        val tail = child.tail()
        child.close()
        assertEquals(
            "*** THE CHILD MUST DIE BY ABRUPT TERMINATION. *** *On POSIX a Java parent observeth `128 + signal`, so a " +
                "SIGKILL reacheth here as 137 — the same status `Runtime.halt` carrieth, which is why the LIVENESS " +
                "observation above is the load-bearing one.* transcript-tail=\n$tail",
            137, exit,
        )
        val noCompletion = !tail.contains("COMPLETE $boundary")
        assertTrue(
            "*** A CHILD THAT COMPLETED GRACEFULLY AFTER ITS MARKER WAS NOT KILLED AT THE BOUNDARY. *** " +
                "transcript-tail=\n$tail",
            noCompletion,
        )

        // AND THE FRAMED RECORD IS THE COORDINATOR'S OWN PROTOCOL, VERIFIED RATHER THAN TRUSTED.
        val bytes = records.readBytes()
        val parsedRecord = Wire.recordOf(bytes, "at_boundary")
        assertNotNull(
            "*** THE PREPARE CHILD LEFT NO PARSEABLE `at_boundary` RECORD. *** *The channel carrieth the `ready` " +
                "record the child writeth when its estate is built AND the `at_boundary` marker; the walk readeth " +
                "every whole record, and the marker is the one sought.* bytes=${bytes.size} " +
                "records=${Wire.records(bytes).map { it.first }}",
            parsedRecord,
        )
        val (header, payloadLen) = parsedRecord!!
        assertEquals("a marker carrieth no payload", 0, payloadLen)
        assertTrue("the record must be an at_boundary marker: $header", header.contains("\"kind\":\"at_boundary\""))
        assertTrue("the record must name the boundary: $header", header.contains("\"boundary\":\"$boundary\""))
        val msgIdHex = Regex("msg_id=([0-9a-f]{32})").find(marker)?.groupValues?.get(1)
        assertNotNull("the marker line must name the accepted msgId: $marker", msgIdHex)
        assertTrue("the record must carry the same msgId: $header", header.contains("\"msg_id\":\"$msgIdHex\""))

        return Prepared(
            child.pid, child.linesForDiagnostic().firstOrNull { it.startsWith("GS-BOUNDARY warm-up") }
                ?: "(warm-up did not run: inboundCommit never links)",
            readySeen, aliveAtMarker, exit, noCompletion, header, msgIdHex!!,
        )
    }

    /** *ONE RECOVERY CHILD over the SAME estate: a fresh JVM, the owners' own answers, one completion line.* */
    private fun recoverScenario(
        java: String,
        classpath: String,
        boundary: String,
        estate: File,
        prepared: Prepared,
    ): Recovered {
        val records = File(estate, "recover.records").also { assertTrue("the record file must be creatable", it.createNewFile()) }
        val log = File(estate, "recover.log")
        val child = launchChild(
            java, classpath, log,
            mapOf(
                Wire.ROLE to Wire.RECOVER,
                Wire.BOUNDARY to boundary,
                Wire.ROOT to estate.absolutePath,
                Wire.OUT to records.absolutePath,
                Wire.EXPECTED_MSG_ID to prepared.msgIdHex,
            ),
        )
        val line = child.await("COMPLETE $boundary", CHILD_BOUND_MILLIS)
        if (line == null) {
            child.terminate()
            throw AssertionError(
                "*** THE RECOVERY CHILD NEVER COMPLETED WITHIN ${CHILD_BOUND_MILLIS / 1000}s. *** " +
                    "exit=${child.exitIfFinished()} transcript-tail=\n${child.tail()}",
            )
        }
        val exit = child.awaitExit()
        val tail = child.tail()
        child.close()
        assertEquals(
            "*** THE RECOVERY JVM MUST EXIT CLEANLY AFTER ITS ASSERTIONS. *** *Its completion line is read first, so " +
                "a non-zero status is a real failure, never a truncation.* line=$line transcript-tail=\n$tail",
            0, exit,
        )
        assertTrue(
            "*** THE RECOVERY VERDICT MUST BE PASS, VERBATIM: $line ***",
            line.startsWith("COMPLETE $boundary PASS durable_row=present"),
        )
        val bytes = records.readBytes()
        val parsedRecord = Wire.recordOf(bytes, "complete")
        assertNotNull(
            "*** THE RECOVERY CHILD LEFT NO PARSEABLE `complete` RECORD. *** bytes=${bytes.size} " +
                "records=${Wire.records(bytes).map { it.first }}",
            parsedRecord,
        )
        val (header, payloadLen) = parsedRecord!!
        assertEquals("a completion carrieth no payload", 0, payloadLen)
        assertTrue("the record must be a completion: $header", header.contains("\"kind\":\"complete\""))
        assertTrue(
            "*** THE RECOVERY MUST REPORT A SURVIVING ROW — the coordinator refuseth anything else. *** $header",
            header.contains("\"durable_row\":\"present\""),
        )
        assertTrue(
            "the completion must name the same receipt: $header",
            header.contains("\"msg_id\":\"${prepared.msgIdHex}\""),
        )
        return Recovered(exit, line)
    }

    // ============================================================================================
    // MARK: - the child process plumbing
    // ============================================================================================

    /**
     * *** A CHILD, ITS MERGED TRANSCRIPT DRAINED AND FILED, AND ITS EXIT WATCHED. *** *Bounded everywhere and fully
     * drained on close, so the tail is the WHOLE transcript rather than a race.*
     *
     * *** AND THE MATCH IS ON THE LINE'S CONTENT, NOT ITS OFFSET -- A MEASURED REQUIREMENT. *** *The child is
     * launched through `org.junit.runner.JUnitCore`, which printeth a `.` PROGRESS DOT WITH NO NEWLINE before the
     * first line the child itself writes -- so the `READY` line arriveth as `.READY boundary=...`, and a
     * `startsWith("READY")` test NEVER MATCHED IT. **MEASURED: the boundary marker itself arriveth unprefixed (the dot
     * had already been flushed by then) and the framed record parsed, while the parent reported "never reached READY"
     * for a child that had plainly reached its boundary and was holding.*** *The comparison therefore strips any
     * leading JUnit progress characters first -- no marker is weakened, and a line that merely CONTAINETH the word in
     * a payload cannot match a marker whose shape is `KIND <boundary> ...`.*
     */
    private class Child(private val process: Process, private val log: File) {
        private val lines = LinkedBlockingQueue<String>()

        /**
         * *** EVERY NORMALIZED LINE THE CHILD EVER WROTE, KEPT BESIDE THE MATCHING QUEUE. ***
         *
         * *`await` POLLS AND DISCARDS the lines it is not looking for -- a matcher cannot put a line back -- so a
         * diagnostic read from `lines` alone would report `(none printed)` for a warm-up line the child plainly
         * printed before the marker it was awaited for. **MEASURED: the parent's own summary reported "warm-up did
         * not run" for a child whose log held `GS-BOUNDARY warm-up attempt=1 link ready=true`.*** *The transcript is
         * therefore RETAINED here as well, and `linesForDiagnostic` readeth THIS -- the class's own rule is that an
         * environment refusal is PRINTED rather than swallowed.*
         */
        private val seenLock = Any()
        private val seen = ArrayList<String>()

        /** *SET BY THE DRAIN THREAD AT EOF, so "the pipe is closed" is distinguishable from "the line is late".* */
        @Volatile
        private var drained = false

        private val reader = Thread {
            runCatching {
                process.inputStream.bufferedReader().useLines { seq ->
                    log.outputStream().bufferedWriter().use { writer ->
                        seq.forEach { line ->
                            // *THE RAW LINE GOES TO THE LOG -- that file IS the child's transcript evidence. The
                            // QUEUE carrieth the NORMALIZED line, with JUnitCore's leading progress characters
                            // stripped, because those characters are the harness's own decoration and would otherwise
                            // hide the child's first protocol line from the parent. See the class docstring.*
                            val normalized = line.trimStart('.', 'E')
                            synchronized(seenLock) { seen.add(normalized) }
                            lines.put(normalized)
                            writer.write(line); writer.newLine(); writer.flush()
                        }
                    }
                }
            }
            drained = true
        }.also { it.isDaemon = true; it.start() }

        /**
         * *** THE PID, READ REFLECTIVELY. *** *`Process.pid()` arriveth only at API 33 in the Android platform jar
         * this module compiles against, so a direct call is a COMPILE error here even though the host JVM running
         * this court carrieth it. A refusal of `-1` is reported as such rather than guessed at: the pid is DIAGNOSTIC
         * evidence, and the load-bearing proof of a kill is the liveness observation beside it.*
         */
        val pid: Long
            get() = runCatching {
                (Process::class.java.getMethod("pid").invoke(process) as Long)
            }.getOrElse { -1L }

        fun isAlive(): Boolean = process.isAlive

        fun exitIfFinished(): String = if (process.isAlive) "running" else "exit=${process.exitValue()}"

        /**
         * *BOUNDED, AND IT RETURNS AT ONCE WHEN THE CHILD HAS EXITED WITH ITS PIPE DRAINED.*
         *
         * *** AN EARLY EXIT IS A FAILED SCENARIO AND MUST BE REPORTED AS ONE -- PROMPTLY. *** *A waiter that only
         * polled for a line would burn its whole bound on a child that died in its first second, and the plan's own
         * rule is that an early exit is a NAMED FAILURE rather than a timeout; the caller raiseth the refusal with
         * the child's exit status and transcript either way.*
         */
        fun await(prefix: String, timeoutMillis: Long): String? {
            val deadline = System.nanoTime() + timeoutMillis * 1_000_000L
            while (System.nanoTime() < deadline) {
                val line = lines.poll(100, TimeUnit.MILLISECONDS)
                if (line != null && line.startsWith(prefix)) return line
                if (!process.isAlive && drained && lines.isEmpty()) return null
            }
            return null
        }

        /** *ABRUPT: `destroyForcibly` is the SIGKILL-equivalent of the process API. Never a cooperative close.* */
        fun killAbruptly() {
            if (process.isAlive) process.destroyForcibly()
        }

        fun terminate() {
            if (process.isAlive) process.destroyForcibly()
        }

        fun awaitExit(): Int {
            if (!process.waitFor(CHILD_BOUND_MILLIS, TimeUnit.MILLISECONDS)) {
                process.destroyForcibly()
                throw AssertionError("the child never exited within its bound")
            }
            return process.exitValue()
        }

        /**
         * *WAIT FOR THE DRAIN THREAD, SO THE TAIL IS THE WHOLE TRANSCRIPT RATHER THAN A RACE.* **Bounded, because a
         * child's pipe is closed by its exit — an unbounded join would be the only place in this file that could
         * hang.**
         */
        fun close() {
            runCatching { process.inputStream.close() }
            reader.join(30_000L)
        }

        fun tail(max: Int = 80): String = log.readLines().takeLast(max).joinToString("\n")

        /** *EVERY NORMALIZED LINE SEEN SO FAR, for a parent that must report an environment refusal.* */
        fun linesForDiagnostic(): List<String> = synchronized(seenLock) { seen.toList() }
    }

    private fun launchChild(
        java: String,
        classpath: String,
        log: File,
        props: Map<String, String>,
    ): Child {
        val argv = ArrayList<String>()
        argv += java
        // *THE `--add-opens` SET ROBOLECTRIC'S HOST RUNTIME NEEDS, plus whatever the enclosing JVM was given.*
        argv += inheritedJvmOptions()
        argv += "--add-opens=java.base/java.lang=ALL-UNNAMED"
        argv += "--add-opens=java.base/java.lang.invoke=ALL-UNNAMED"
        argv += "--add-opens=java.base/java.util=ALL-UNNAMED"
        argv += "--add-opens=java.base/java.util.concurrent=ALL-UNNAMED"
        argv += "--add-opens=java.base/java.io=ALL-UNNAMED"
        argv += "--add-opens=java.base/java.net=ALL-UNNAMED"
        argv += "--add-opens=java.base/java.security=ALL-UNNAMED"
        argv += "--add-opens=java.base/java.text=ALL-UNNAMED"
        argv += "--add-opens=java.base/java.nio=ALL-UNNAMED"
        argv += "--add-opens=java.base/sun.nio.ch=ALL-UNNAMED"
        argv += "--add-opens=java.base/jdk.internal.misc=ALL-UNNAMED"
        argv += "--add-opens=java.base/java.lang.reflect=ALL-UNNAMED"
        argv += props.map { (key, value) -> "-D$key=$value" }
        // *** WHATEVER ROBOLECTRIC/THE TOOLCHAIN TOLD THE ENCLOSING JVM, THE CHILD IS TOLD TOO. *** *The Android
        // Gradle plugin and Robolectric both pass their configuration as system properties (the dependency dir, the
        // offline flag, the SDK pin), and a child JVM launched without them would re-resolve or refuse the very
        // runtime its parent is already executing on — a failure with NOTHING to do with the crash boundary this
        // court existeth to measure.*
        argv += System.getProperties().stringPropertyNames()
            .filter {
                it.startsWith("robolectric.") || it.startsWith("android.") || it.startsWith("com.android.")
            }
            .map { "-D$it=${System.getProperty(it)}" }
        argv += "-cp"
        argv += classpath
        argv += "org.junit.runner.JUnitCore"
        argv += Board1DurableBoundaryWorkerTest::class.java.name

        val builder = ProcessBuilder(argv)
        // *** THE CHILD'S WORKING DIRECTORY IS THE PARENT'S, AND THAT IS LOAD-BEARING RATHER THAN TIDY. ***
        // *Robolectric readeth `com/android/tools/test_config.properties` from the CLASSPATH and resolveth the
        // `android_merged_assets` / `android_resource_apk` paths inside it RELATIVE TO THE WORKING DIRECTORY — which
        // AGP set to the module directory. A child started anywhere else would look for the merged assets beside the
        // wrong directory and fail during setup.*
        builder.directory(File(System.getProperty("user.dir")!!))
        builder.redirectErrorStream(true)
        return Child(builder.start(), log)
    }

    /**
     * *WHATEVER THE ENCLOSING JVM WAS GIVEN, the child is given too — minus anything worker-specific.*
     *
     * *** READ REFLECTIVELY, BECAUSE `java.lang.management` IS NOT ON THE ANDROID PLATFORM JAR. *** *The host JVM that
     * runneth this court carrieth it; the Android `compileSdk` classpath does NOT, so a direct reference is a COMPILE
     * error and a reflective one is both. **An unavailable bean yieldeth an empty list rather than a failure: this is
     * a best-effort inheritance, and the explicit `--add-opens` set below is what Robolectric actually needeth.***
     */
    private fun inheritedJvmOptions(): List<String> = runCatching {
        val factory = Class.forName("java.lang.management.ManagementFactory")
        val bean = factory.getMethod("getRuntimeMXBean").invoke(null)
        val raw = bean.javaClass.getMethod("getInputArguments").invoke(bean)
        val arguments: List<String> = (raw as? List<*>)?.filterIsInstance<String>() ?: emptyList()
        arguments
            .filter { option ->
                option.startsWith("--add-opens=") || option.startsWith("--add-exports=") ||
                    option.startsWith("--add-modules=") || option.startsWith("--enable-")
            }
            // *THE WORKER'S OWN PROPERTIES ARE DELIBERATELY NOT INHERITED: the child's role/boundary/root come from
            // the launch map, and copying the parent's would give the child the PARENT's identity.*
            .filterNot { option -> option.startsWith("-Dgodstone.integration.") }
    }.getOrDefault(emptyList())

    /**
     * *** THE CHILD RUNS ON THE SAME TEST RUNTIME CLASSPATH THE PARENT IS RUNNING ON. *** *TWO SOURCES, DELIBERATELY:
     * first the test class loader's OWN URLs — under Gradle that is the worker's `URLClassLoader`, carrying the whole
     * test runtime classpath INCLUDING Robolectric's generated `test_config.properties` directory — and, only when
     * that yieldeth too little to be a classpath at all, the JVM's own `java.class.path` with any jar-manifest
     * `Class-Path` entries EXPANDED.*
     */
    private fun childClasspath(): String {
        val entries = LinkedHashSet<String>()
        runCatching {
            var loader: ClassLoader? = javaClass.classLoader
            while (loader != null) {
                if (loader is URLClassLoader) {
                    loader.urLs.forEach { url ->
                        if (url.protocol == "file") {
                            runCatching { File(url.toURI()).absolutePath }.getOrNull()?.let { entries.add(it) }
                        }
                    }
                }
                loader = loader.parent
            }
        }
        if (entries.size < 5) {
            for (part in (System.getProperty("java.class.path") ?: "").split(File.pathSeparator)) {
                if (part.isBlank()) continue
                entries.add(part)
                if (part.endsWith(".jar")) expandManifestClassPath(File(part), entries)
            }
        }
        return entries.filter { File(it).exists() }.joinToString(File.pathSeparator)
    }

    private fun expandManifestClassPath(jar: File, into: MutableSet<String>) {
        runCatching {
            java.util.jar.JarFile(jar).use { archive ->
                val cp = archive.manifest?.mainAttributes?.getValue("Class-Path") ?: return@use
                for (rel in cp.split(' ')) {
                    if (rel.isBlank()) continue
                    val resolved = runCatching { File(java.net.URI(rel)) }.getOrElse { File(jar.parentFile, rel) }
                    into.add(resolved.absolutePath)
                }
            }
        }
    }
}
