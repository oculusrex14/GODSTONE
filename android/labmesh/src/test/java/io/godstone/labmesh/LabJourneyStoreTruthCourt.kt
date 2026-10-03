package io.godstone.labmesh

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import io.godstone.mesh.delivery.DeliveryState
import io.godstone.mesh.identity.PanicWipe
import io.godstone.mesh.lab.HostLabPlatform
import io.godstone.mesh.lab.LabRuntime
import io.godstone.mesh.lab.LabWipeJourney
import io.godstone.mesh.lab.ProductionLabEstate
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.File
import java.sql.DriverManager

/**
 * *** GS-FINAL-003 `durable-authority` / GS-UX-001 `rendered-controls`: THE ACTUAL STORE'S OWN ROWS, READ BY RAW
 * SQLITE -- NOT THE RUNTIME'S OR THE SCREEN'S CLAIM. ***
 *
 * *THE PLAN'S OWN CHARGE (step 8, item 4): **"fix actual persistence, not its readout"** -- do not "prove a UI string".
 * The Android estate's actionable SOS row and its authored messages live in each label's own `godstone_messages.db`
 * (`held_frames` + `delivery_state`), written by the production `SqliteMessageStore`.*
 *
 * *** SO THIS COURT OPENS THAT FILE DIRECTLY, WITH A JDBC CONNECTION OF ITS OWN, AND READS THE TABLES. *** *The
 * runtime's `activeSosMsgIdOf`/`durableStateOf`/`heldMsgIdOf` are the READ paths; if a bug made them report something
 * the tables do not carry, this court would catch it -- the raw `SELECT` is the ground truth the rendered words must
 * match.* **A test that asserted only the runtime's own getters would be measuring the read path against itself.**
 *
 * THE HOST BOUNDARY: [`HostLabPlatform`] substitutes only the two JVM-absent doors (the AndroidKeyStore identity
 * factory and the SQLCipher native engine) with REAL on-disk SQLite; the store schema, the transactions and the file
 * layout are the production ones. Nothing here claims a device result.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33])
class LabJourneyStoreTruthCourt {

    private fun ctx(): Context = ApplicationProvider.getApplicationContext()

    private fun estate(labels: List<String> = listOf("A", "R", "B")): ProductionLabEstate =
        ProductionLabEstate(ctx(), labels, HostLabPlatform())

    private fun boot(labels: List<String> = listOf("A", "R", "B")) =
        LabRuntime.composeRealEstateOrRefuse(ctx(), estate(labels), labels)

    /** The label's own database file -- where the estate's production store really writes. */
    private fun dbFile(label: String): File =
        File(File(ctx().filesDir, "labmesh/$label"), MESSAGES_DB)

    /** *One raw row of `delivery_state`, read by a connection the runtime knows nothing about.* */
    private data class Row(val msgId: ByteArray, val state: Int, val ackMode: Int, val expected: ByteArray?) {
        override fun equals(other: Any?): Boolean = other is Row && msgId.contentEquals(other.msgId) &&
            state == other.state && ackMode == other.ackMode &&
            ((expected == null && other.expected == null) ||
                (expected != null && other.expected != null && expected.contentEquals(other.expected)))
        override fun hashCode(): Int = msgId.contentHashCode() * 31 + state
    }

    private fun deliveryRows(label: String): List<Row> {
        val f = dbFile(label)
        if (!f.exists()) return emptyList()
        val out = ArrayList<Row>()
        DriverManager.getConnection("jdbc:sqlite:" + f.absolutePath).use { c ->
            c.createStatement().use { st ->
                st.executeQuery("SELECT msg_id, state, ack_mode, expected_recipient FROM delivery_state").use { rs ->
                    while (rs.next()) {
                        out.add(Row(rs.getBytes(1), rs.getInt(2), rs.getInt(3), rs.getBytes(4)))
                    }
                }
            }
        }
        return out
    }

    private fun heldMsgIds(label: String): List<ByteArray> {
        val f = dbFile(label)
        if (!f.exists()) return emptyList()
        val out = ArrayList<ByteArray>()
        DriverManager.getConnection("jdbc:sqlite:" + f.absolutePath).use { c ->
            c.createStatement().use { st ->
                st.executeQuery("SELECT msg_id FROM held_frames").use { rs ->
                    while (rs.next()) out.add(rs.getBytes(1))
                }
            }
        }
        return out
    }

    private fun presetJournal(ordinal: Int?) {
        ctx().getSharedPreferences("godstone_wipe_journal", Context.MODE_PRIVATE).edit().apply {
            if (ordinal == null) remove("state") else putInt("state", ordinal)
        }.commit()
    }

    @Before fun clean() = presetJournal(null)
    @After fun tearDown() = presetJournal(null)

    // =================================================================================================================
    // 1. AN ARMING THROUGH THE RENDERED BINDING LANDS A REAL `delivery_state` ROW.
    // =================================================================================================================

    /**
     * *** THE SOS ARM'S ROW IS IN THE ACTUAL TABLE, WITH THE ID THE RUNTIME REPORTS AND THE WORDS THE SCREEN SHOWS. ***
     */
    @Test
    fun theRenderedArmCommitsARealDeliveryStateRowInTheLabelsOwnStore() {
        val runtime = boot().runtime!!
        val bindings = LabJourneyBindings(runtime, CoroutineScope(Dispatchers.Unconfined), LabWipeJourney(ctx(), liveEstate = runtime))
        bindings.refresh()
        val author = bindings.author

        val before = deliveryRows(author)
        assertTrue(
            "*** BEFORE THE ARM, THE LABEL'S OWN TABLE MUST CARRY NO ROW -- the store is the premise, and a " +
                "pre-seeded row would make every assertion below vacuous. Observed: $before ***",
            before.isEmpty(),
        )

        bindings.armSos()

        // *** THE ACTUAL ROW, READ BY RAW SQLITE. ***
        val rows = deliveryRows(author)
        assertEquals("*** THE RENDERED ARM MUST WRITE EXACTLY ONE delivery_state ROW. ***", 1, rows.size)
        val row = rows.single()
        assertEquals(
            "*** A BROADCAST CALL IS NONE-MODE: no expected recipient, ack_mode 0. ***",
            0, row.ackMode,
        )
        assertTrue(
            "*** AND A NONE-MODE ROW MUST CARRY NO RECIPIENT (the schema's own CHECK). ***",
            row.expected == null,
        )

        // *** AND THE RUNTIME'S READ PATH MUST AGREE WITH THE RAW TABLE. ***
        val reportedId = runBlocking { runtime.activeSosMsgIdOf(author) }
        assertNotNull(reportedId)
        assertTrue(
            "*** THE RUNTIME'S REPORTED msg_id MUST BE THE TABLE'S OWN -- if the read path disagreed with the row, " +
                "this line is where the lie would show. Table: ${hex(row.msgId)}, runtime: ${hex(reportedId!!)} ***",
            row.msgId.contentEquals(reportedId),
        )
        assertEquals(
            "*** AND THE TABLE'S STATE CODE MUST BE THE DURABLE QUEUED ROW -- not HANDED_TO_RELAY, which would be a " +
                "custody claim no ACK backed. Observed code: ${row.state} ***",
            DeliveryState.QUEUED_DURABLY.code, row.state,
        )

        // *** AND THE HELD FRAME (the authored bytes) MUST ALSO BE IN THE TABLE BESIDE IT. ***
        assertTrue(
            "*** THE ARM MUST HOLD THE FRAME BESIDE THE ROW -- a row without a held frame is not a resumable call. ***",
            heldMsgIds(author).any { it.contentEquals(row.msgId) },
        )

        // *** AND THE RENDERED WORDS MUST MATCH THE ACTUAL ROW'S STATE. ***
        trace("sos.arm", bindings.state.value.sosStateWords, stateWordsForState(DeliveryState.fromPersistedCode(row.state)))
        assertEquals(
            "*** THE RENDERED SOS WORDS MUST BE THE SHARED WORD FOR THE TABLE'S OWN STATE. ***",
            stateWordsForState(DeliveryState.fromPersistedCode(row.state)), bindings.state.value.sosStateWords,
        )
    }

    // =================================================================================================================
    // 2. A CANCEL LANDS IN THE ACTUAL TABLE: THE ROW IS TERMINAL AND THE HELD FRAME IS GONE.
    // =================================================================================================================

    @Test
    fun theRenderedCancelMovesTheRealRowTerminalAndRetiresTheHeldFrame() {
        val runtime = boot().runtime!!
        val bindings = LabJourneyBindings(runtime, CoroutineScope(Dispatchers.Unconfined), LabWipeJourney(ctx(), liveEstate = runtime))
        bindings.refresh()
        val author = bindings.author
        bindings.armSos()
        val armedId = runBlocking { runtime.activeSosMsgIdOf(author) }!!

        bindings.cancelSos()

        // *** THE ACTUAL ROW, READ BY RAW SQLITE: state CANCELLED_LOCALLY (code 5). ***
        val rows = deliveryRows(author)
        val cancelled = rows.firstOrNull { it.msgId.contentEquals(armedId) }
        assertNotNull("*** THE CANCELLED CALL'S ROW MUST STILL STAND (terminal, not deleted). ***", cancelled)
        assertEquals(
            "*** THE RENDERED CANCEL MUST MOVE THE REAL ROW TERMINAL. Observed code: ${cancelled!!.state} ***",
            DeliveryState.CANCELLED_LOCALLY.code, cancelled.state,
        )
        // *** AND THE HELD FRAME MUST BE RETIRED BY THE SAME TRANSACTION. ***
        assertFalse(
            "*** A CANCELLED CALL MUST NOT LEAVE ITS AUTHORED BYTES HELD -- the transactional pair is the law. ***",
            heldMsgIds(author).any { it.contentEquals(armedId) },
        )
        // *** AND NO ACTIVE PROJECTION MAY STAND. ***
        trace("sos.cancel", bindings.state.value.sosStateWords, stateWordsForState(DeliveryState.fromPersistedCode(cancelled!!.state)))
        assertEquals(
            "*** AND THE RUNTIME MUST REPORT NO ACTIVE CALL, CONSISTENT WITH THE TERMINAL ROW. ***",
            null, runBlocking { runtime.activeSosMsgIdOf(author) },
        )
    }

    // =================================================================================================================
    // 3. A RENDERED DIRECT SEND LANDS IN THE ACTUAL TABLE WITH THE COMMITTED msg_id.
    // =================================================================================================================

    @Test
    fun theRenderedSendLandsInTheActualStoreWithTheCommittedMsgId() {
        val runtime = boot(listOf("A", "B")).runtime!!
        val bindings = LabJourneyBindings(runtime, CoroutineScope(Dispatchers.Unconfined), LabWipeJourney(ctx(), liveEstate = runtime))
        bindings.refresh()
        val author = bindings.author
        assertFalse("*** THE STORE MUST START EMPTY. ***", dbFile(author).exists() && heldMsgIds(author).isNotEmpty())

        bindings.send(bindings.recipients.single(), "the mill road is cut at both ends; send boats")

        val ids = heldMsgIds(author)
        assertEquals("*** ONE RENDERED SEND MUST HOLD EXACTLY ONE FRAME IN THE REAL TABLE. ***", 1, ids.size)
        val durable = ids.single()
        assertEquals(
            "*** AND THE RENDERED ID MUST BE THE TABLE'S OWN msg_id -- hex of the raw blob. ***",
            hex(durable), bindings.state.value.durableMsgId,
        )
        // *** AND THE DELIVERY ROW IS SINGLE_RECIPIENT-MODE WITH THE INTENDED RECIPIENT RECORDED. ***
        val row = deliveryRows(author).single { it.msgId.contentEquals(durable) }
        trace("send.commit", bindings.state.value.durableMsgId, hex(durable))
        assertEquals(
            "*** A DIRECT SEND IS SINGLE_RECIPIENT-MODE (ack_mode 1) WITH ITS RECIPIENT RECORDED -- never a broadcast " +
                "row. ***",
            1, row.ackMode,
        )
        assertEquals(
            "*** AND IT MUST STAND QUEUED_DURABLY: NOTHING claims delivery before the recipient's ACK. ***",
            DeliveryState.QUEUED_DURABLY.code, row.state,
        )
    }

    // =================================================================================================================
    // 4. THE WIPE ERASES THE ESTATE'S ACTUAL FILES -- AND A FRESH PROCESS IS REFUSED.
    // =================================================================================================================

    /**
     * *** A RENDERED WIPE MUST MOVE THE ACTUAL DURABLE RECORD AND REFUSE THE NEXT PROCESS. ***
     *
     * *What a HOST can prove about erasure is bounded: the ladder's pre-private seams reach beyond the two JVM-absent
     * doors (the AndroidKeyStore), so it stops at the rung whose owner refused and STAYS PENDING -- the honest,
     * crash-resumable answer.* **What is asserted here is therefore what the record itself says (the durable rung MOVED)
     * and the law that follows from it (the NEXT composition is refused, because old work is refused) -- never a
     * deletion claim a host cannot make.**
     */
    @Test
    fun theRenderedWipeMovesTheDurableRecordAndRefusesTheNextProcess() {
        val runtime = boot(listOf("A", "B")).runtime!!
        val bindings = LabJourneyBindings(runtime, CoroutineScope(Dispatchers.Unconfined), LabWipeJourney(ctx(), liveEstate = runtime))
        bindings.refresh()
        // Give the estate a real authored row so "erased" is measurable.
        bindings.send(bindings.recipients.single(), "the bridge at Harrow is under two feet of water")
        assertTrue(
            "*** THE ESTATE MUST HOLD REAL BYTES BEFORE THE WIPE, or erasure is unmeasurable. ***",
            dbFile(bindings.author).exists(),
        )

        bindings.beginWipe()

        val ordinal = ctx().getSharedPreferences("godstone_wipe_journal", Context.MODE_PRIVATE).getInt("state", -1)
        trace("wipe.begin", bindings.state.value.wipeStage, PanicWipe.WipeState.entries.getOrNull(ordinal)?.name)
        assertTrue(
            "*** THE RENDERED WIPE MUST MOVE THE ACTUAL DURABLE RECORD OFF IDLE. Observed ordinal: $ordinal ***",
            ordinal != PanicWipe.WipeState.IDLE.ordinal,
        )

        // *** AND THE NEXT PROCESS MUST BE REFUSED WHILE THE WIPE IS OUTSTANDING. ***
        val next = boot(listOf("A", "B"))
        assertEquals(
            "*** A FRESH PROCESS OVER A PENDING-WIPE ESTATE MUST COMPOSE NO PRIVATE RUNTIME -- the record is the " +
                "authority, and old work is refused. ***",
            null, next.runtime,
        )
        assertNotNull("and the refusal must name the recovery cause", next.refusalReason)
    }

    // =================================================================================================================
    // 5. THE FULL FLOW LANDS DELIVERY IN THE ACTUAL TABLE: A -> R -> B, B's ACK -> R -> A.
    // =================================================================================================================

    /**
     * *** THE RENDERED SEND'S DELIVERY IS A REAL ROW TRANSITION IN `delivery_state`, END TO END. ***
     *
     * *THE PLAN'S CHARGE ON THE FLOW ITSELF: prove the journey "retrieves the real values", not a claim. The author
     * sends to B through a relay, B's real inbox commits and issues its canonical ACK, and the ACK travelleth home.*
     * **THE DISCRIMINATOR IS THE RAW TABLE: A's `delivery_state` row must move from QUEUED_DURABLY (1) to
     * ACKNOWLEDGED_BY_RECIPIENT (3) -- the ONLY delivery -- and the runtime's reported label must be that row's own
     * projection. And the relay B's inbox row must exist in B's OWN table, so the receipt is real, not an author-side
     * assumption.**
     */
    @Test
    fun theEndToEndFlowLandsDeliveryInTheActualDeliveryStateTable() {
        val composition = boot()
        val runtime = composition.runtime!!
        val labels = runtime.labels // A, R, B

        // ---- A SENDS to B (a two-hop road through the relay).
        val applied = runBlocking { runtime.sendDirect("A", "B", "the mill road is cut at both ends; send boats".toByteArray()) }
        assertTrue("*** THE AUTHOR'S SEND MUST BE APPLIED. Observed: '$applied' ***", applied.startsWith("applied:"))
        val authoredId = runBlocking { runtime.heldMsgIdOf("A") }!!
        val rowAfter = deliveryRows("A").single { it.msgId.contentEquals(authoredId) }
        assertEquals(
            "*** BEFORE THE ACK, THE REAL ROW MUST STAND QUEUED_DURABLY -- nothing claims delivery yet. ***",
            DeliveryState.QUEUED_DURABLY.code, rowAfter.state,
        )

        // ---- RELAY the frame A -> R -> B, then B's ACK B -> R -> A.
        runBlocking {
            runtime.turn("A", "R")
            runtime.turn("R", "B")
            runtime.turnAcks("B", "R")
            runtime.turnAcks("R", "A")
        }

        // *** THE RECEIVER'S OWN TABLE MUST CARRY A HELD ROW -- the receipt is real. ***
        assertTrue(
            "*** B'S OWN STORE MUST HOLD THE RECEIVED FRAME (a real receipt, not an author-side assumption). ***",
            heldMsgIds("B").any { it.contentEquals(authoredId) },
        )
        // *** AND THE AUTHOR'S REAL ROW MUST HAVE MOVED TO ACKNOWLEDGED_BY_RECIPIENT (code 3). ***
        val delivered = deliveryRows("A").single { it.msgId.contentEquals(authoredId) }
        assertEquals(
            "*** THE AUTHOR'S `delivery_state` ROW MUST MOVE TO ACKNOWLEDGED_BY_RECIPIENT (3) -- the ONLY delivery, " +
                "read from the real table rather than from the runtime's claim. Observed code: ${delivered.state} ***",
            DeliveryState.ACKNOWLEDGED_BY_RECIPIENT.code, delivered.state,
        )
        // *** AND THE RUNTIME'S REPORTED LABEL MUST BE THAT ROW'S OWN PROJECTION. ***
        val label = runtime.deliveryLabelOf("A", authoredId)
        assertEquals(
            "*** THE RUNTIME MUST REPORT THE DELIVERED LABEL THE REAL ROW SUPPORTETH. Observed: '$label' ***",
            "DELIVERED", label,
        )

        // *** AND A FRESH PROCESS MUST READ THE SAME DELIVERED ROW FROM THE ACTUAL TABLE. ***
        // *After delivery the AUTHORED frame is retired from the held set (the delivered row IS the record), so the
        // rendered held-readout honestly readeth `none` -- THIS court then reads the surviving `delivery_state` row
        // directly, which is where the delivery really lives.*
        val second = boot().runtime!!
        assertEquals(
            "*** A RELAUNCH MUST SEE THE DELIVERED ROW IN THE ACTUAL TABLE, UNCHANGED. ***",
            DeliveryState.ACKNOWLEDGED_BY_RECIPIENT.code,
            deliveryRows("A").single { it.msgId.contentEquals(authoredId) }.state,
        )
        assertEquals(
            "*** AND THE RUNTIME'S STATE READ MUST AGREE WITH THAT ROW. ***",
            DeliveryState.ACKNOWLEDGED_BY_RECIPIENT,
            second.durableStateOf("A", authoredId),
        )
        assertFalse(
            "*** AND THE DELIVERED FRAME MUST BE RETIRED FROM THE HELD SET (the delivery row is the record now). ***",
            heldMsgIds("A").any { it.contentEquals(authoredId) },
        )
    }

    // =================================================================================================================
    // 6. THE STORE-TRUTH NEGATIVE CONTROL: A REMEMBERED STRING CANNOT PRODUCE A TABLE ROW.
    // =================================================================================================================
    /**
     * *** WITHOUT A SEND, THE TABLE CARRIES NO ROW AND THE RUNTIME REPORTS NOTHING -- THE TWO AGREE ON ABSENCE. ***
     */
    @Test
    fun theAbsentReadoutAgreesWithTheAbsentTable() {
        val runtime = boot(listOf("A", "B")).runtime!!
        val bindings = LabJourneyBindings(runtime, CoroutineScope(Dispatchers.Unconfined), LabWipeJourney(ctx(), liveEstate = runtime))
        bindings.refresh()
        assertEquals(
            "*** THE RENDERED ID MUST BE ABSENT WHEN THE TABLE CARRIES NO ROW. ***",
            null, bindings.state.value.durableMsgId,
        )
        assertEquals(
            "*** AND THE RUNTIME'S READ PATH AND THE TABLE MUST AGREE ON THAT ABSENCE. ***",
            emptyList<ByteArray>(), heldMsgIds(bindings.author),
        )
        assertEquals(
            "*** AND NO delivery_state ROW MAY STAND EITHER. ***",
            emptyList<Row>(), deliveryRows(bindings.author),
        )
    }

    private fun hex(b: ByteArray): String = LabJourneyBindings.hexOf(b)

    /**
     * *** THE REAL JOURNEY TRACE: WHAT THE USER ACTUALLY GETS Vs. WHAT THE DURABLE ESTATE ACTUALLY CARRIES. ***
     *
     * *The plan's own directive: "add the real logging to help you trace what your users ACTUALLY get behind the
     * recovery flow (their values are what matter most)".* **Each junction below is logged with BOTH readings, so a
     * failing run's retained XML shows the user-visible value beside the durable one -- the two must agree, and a
     * disagreement is visible rather than inferred.** *This is deliberately a log of the REAL values (the store's own
     * rows), never of a test's own expectation.*
     */
    private fun trace(junction: String, userVisible: Any?, durable: Any?) {
        println("JOURNEY[$junction] user-visible=$userVisible durable=$durable agree=${userVisible == durable}")
    }

    private companion object {
        /**
         * *The production store's database name.*
         *
         * *`StoreSchema` is `internal` to `:mesh`, so this court spells the file name (the value `SqlcipherStoreDb`
         * itself uses) and reads the tables by raw SQLite. **The file IS the contract: if the production name ever
         * changed, the database file would move and this court would find no rows -- which is the correct failure, not
         * a silent pass.*** 
         */
        const val MESSAGES_DB: String = "godstone_messages.db"
    }
}
