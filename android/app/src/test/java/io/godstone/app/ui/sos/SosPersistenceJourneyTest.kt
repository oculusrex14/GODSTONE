package io.godstone.app.ui.sos

import io.godstone.app.mesh.LinkState
import io.godstone.app.mesh.MeshCommand
import io.godstone.app.mesh.MeshPort
import io.godstone.app.mesh.MeshViewModel
import io.godstone.app.mesh.MessageProjection
import io.godstone.app.mesh.MessageStatus
import io.godstone.app.mesh.RecipientProjection
import io.godstone.app.mesh.RetryOutcome
import io.godstone.app.mesh.SendOutcome
import io.godstone.app.mesh.SosOutcome
import io.godstone.app.mesh.SosProjection
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * *** GS-UX-001 `rendered-controls` / GS-FINAL-009 (Android isle, app layer): THE SOS JOURNEY'S DURABLE AUTHORITY, AND
 * THE DISTINCTION BETWEEN THE AUTHORITY'S ROWS AND THE VIEWMODEL'S OWN MEMORY. ***
 *
 * *THE PLAN'S OWN CHARGE (step 8, item 4): **"reload the active msgId/delivery state from that authority"**, proving
 * arm -> terminate -> relaunch -> active -> cancel -> terminate -> relaunch -> terminal "for the SAME message" -- and
 * asserting "durable rows as the opposite-half discriminator".*
 *
 * *** THIS COURT DIES THE VIEWMODEL AND RAISES A NEW ONE, AND THE AUTHORITY SURVIVES. *** *`MeshViewModel` is the app's
 * SOS state machine; its memory is NOT the authority. The `Authority` below stands in for the durable store behind
 * `MeshPort` and OUTLIVES every ViewModel built here.* **So an arm on the first ViewModel, then a NEW ViewModel whose
 * only road to the standing call is `RestoreActiveSos`, proves the id on the second surface was READ FROM THE
 * AUTHORITY rather than remembered by the first.**
 *
 * *** AND THE DISCRIMINATOR AGAINST LOCAL STATE IS NAMED. *** *A cancel must be REFUSED when the id names a call the
 * ViewModel has not read -- the app's own law ("there is no such active call") -- so a surface that invented or
 * remembered an id cannot durably retire anything.* **And every rendered status word is asserted against the
 * AUTHORITY'S OWN ROW (`authority.statusOf`), never against a value the ViewModel produced.**
 *
 * SCOPE, NAMED RATHER THAN IMPLIED: the ACTUAL on-disk table rows (the real `held_frames`/`delivery_state` in each
 * label's `godstone_messages.db`) are proven by the labmesh courts (`:labmesh`, which links the real `:mesh`). This
 * court proves the APP layer's state machine uses the authority it is handed and never its own memory -- the two are
 * complementary halves of step 8, and this one makes no claim about a real file or a device radio.
 */
class SosPersistenceJourneyTest {

    /**
     * *** THE DURABLE AUTHORITY BEHIND THE PORT -- IT OUTLIVES THE VIEWMODEL. ***
     *
     * *Rows are keyed by msg_id and mutated ONLY by the port's own verbs, so the "authority" is the store's role: the
     * ViewModel cannot reach it except through `MeshPort`.*
     */
    private class Authority {
        private val rows = LinkedHashMap<String, Row>()
        var nextIdByte: Int = 0x40

        /** One active SOS row: the durable pair of the message id and its delivery state. */
        private data class Row(val msgId: ByteArray, var status: MessageStatus, val relayMayBeOut: Boolean)

        fun mintSos(): ByteArray {
            val id = ByteArray(16).also { it[0] = nextIdByte++.toByte() }
            rows[hex(id)] = Row(id, MessageStatus.QUEUED, relayMayBeOut = false)
            return id
        }

        fun statusOf(msgId: ByteArray): MessageStatus? = rows[hex(msgId)]?.status

        fun activeSos(): SosProjection? {
            val row = rows.values.firstOrNull { it.status == MessageStatus.QUEUED || it.status == MessageStatus.ATTEMPTING }
                ?: return null
            return SosProjection(row.msgId.copyOf(), row.status, row.relayMayBeOut)
        }

        /** Cancel the row named by [msgId], or report the honest typed no-op. */
        fun cancel(msgId: ByteArray): SosOutcome {
            val row = rows[hex(msgId)] ?: return SosOutcome.Refused("no such call")
            return when (row.status) {
                MessageStatus.CANCELLED -> SosOutcome.AlreadyCancelled(row.relayMayBeOut)
                MessageStatus.QUEUED, MessageStatus.ATTEMPTING -> {
                    row.status = MessageStatus.CANCELLED
                    SosOutcome.Cancelled(row.relayMayBeOut)
                }
                else -> SosOutcome.Refused("already terminal (${row.status})")
            }
        }

        private fun hex(b: ByteArray): String = b.joinToString("") { "%02x".format(it) }
    }

    /** The port the ViewModel binds: every verb readeth or writeth the SURVIVING authority. */
    private class AuthorityPort(private val authority: Authority) : MeshPort {
        override fun linkState(): LinkState = LinkState.Connected(peers = 1)
        override fun recipients(): List<RecipientProjection> = emptyList()
        override fun messages(): List<MessageProjection> = emptyList()
        override fun activeSos(): SosProjection? = authority.activeSos()
        override fun sendDirect(recipientNodeId: ByteArray, body: String): SendOutcome =
            SendOutcome.Refused("this court drives the SOS arm only")
        override fun retry(msgId: ByteArray): RetryOutcome = RetryOutcome.Refused("this court drives the SOS arm only")
        override fun beginSos(body: String): SosOutcome {
            authority.mintSos()
            return SosOutcome.Enqueued(authority.activeSos()!!.msgIdCopy())
        }
        override fun cancelSos(msgId: ByteArray): SosOutcome = authority.cancel(msgId)
    }

    /**
     * *** ARM -> "TERMINATE" -> RELAUNCH: THE SAME CALL IS RESTORED FROM THE AUTHORITY, BY THE SAME ID. ***
     */
    @Test
    fun theSosCallIsRestoredFromTheAuthorityAcrossARelaunch() {
        val authority = Authority()

        // ---- (1) ARM on the first surface (the held-control pair: arm, then confirm).
        val first = MeshViewModel(port = AuthorityPort(authority))
        first.onCommand(MeshCommand.ArmSos)
        first.onCommand(MeshCommand.ConfirmSos)
        val armed = authority.activeSos()
        assertNotNull("*** CONFIRMING THE ARM MUST DURABLY ENQUEUE AN SOS CALL IN THE AUTHORITY. ***", armed)
        assertEquals(
            "*** AND THE AUTHORITY'S OWN ROW MUST BE THE DURABLE QUEUED ROW. ***",
            MessageStatus.QUEUED, authority.statusOf(armed!!.msgIdCopy()),
        )

        // ---- (2) "TERMINATE" THE VIEWMODEL: raise a FRESH one, whose memory starteth empty.
        val relaunched = MeshViewModel(port = AuthorityPort(authority))
        assertNull(
            "*** A FRESH VIEWMODEL MUST NOT KNOW THE CALL BEFORE IT IS RESTORED -- otherwise the restore below " +
                "would be measuring memory, not the authority. ***",
            relaunched.uiState().sos,
        )

        // ---- (3) RESTORE from the authority: the SAME msg_id, read through the port.
        relaunched.onCommand(MeshCommand.RestoreActiveSos)
        val restored = relaunched.uiState().sos
        assertNotNull("*** THE RESTORE MUST PROJECT THE STANDING CALL FROM THE AUTHORITY. ***", restored)
        assertEquals(
            "*** AND IT MUST BE THE SAME msg_id THE AUTHORITY CARRIES -- a remembered or newly minted id would " +
                "differ. Authority: ${hex(armed.msgIdCopy())}, restored: ${hex(restored!!.msgIdCopy())} ***",
            hex(armed.msgIdCopy()), hex(restored.msgIdCopy()),
        )
    }

    /**
     * *** CANCEL -> "TERMINATE" -> RELAUNCH: THE AUTHORITY'S ROW IS TERMINAL, AND NO SURFACE RESURRECTS IT. ***
     */
    @Test
    fun theSosCancelMovesTheAuthorityTerminalAcrossARelaunch() {
        val authority = Authority()
        val first = MeshViewModel(port = AuthorityPort(authority))
        first.onCommand(MeshCommand.ArmSos)
        first.onCommand(MeshCommand.ConfirmSos)
        first.onCommand(MeshCommand.RestoreActiveSos)
        val standing = first.uiState().sos!!
        val id = standing.msgIdCopy()

        // ---- CANCEL through the rendered control, naming the AUTHORITY's id.
        first.onCommand(MeshCommand.CancelSos(id))
        assertEquals(
            "*** THE CANCEL MUST MOVE THE AUTHORITY'S OWN ROW TERMINAL. ***",
            MessageStatus.CANCELLED, authority.statusOf(id),
        )

        // ---- RELAUNCH: a fresh surface must see NO active call, because the authority carries none.
        val relaunched = MeshViewModel(port = AuthorityPort(authority))
        relaunched.onCommand(MeshCommand.RestoreActiveSos)
        assertNull(
            "*** A RELAUNCH AFTER A CANCELLATION MUST SEE NO STANDING CALL -- the terminal row is the record, and no " +
                "surface may resurrect it. ***",
            relaunched.uiState().sos,
        )
        assertEquals(
            "*** AND THE AUTHORITY MUST AGREE, so the two readings of one fact cannot drift. ***",
            MessageStatus.CANCELLED, authority.statusOf(id),
        )
    }

    /**
     * *** THE LOCAL-STATE DISCRIMINATOR: A CANCEL NAMING A CALL THE SURFACE NEVER READ IS REFUSED, AND THE AUTHORITY
     * IS UNTOUCHED. ***
     */
    @Test
    fun aCancelThatNamesAnUnreadCallIsRefusedAndMovesNothing() {
        val authority = Authority()
        val surface = MeshViewModel(port = AuthorityPort(authority))
        surface.onCommand(MeshCommand.ArmSos)
        surface.onCommand(MeshCommand.ConfirmSos)
        val real = authority.activeSos()!!.msgIdCopy()

        // *** A SURFACE THAT INVENTED AN ID: its memory names a call the authority never carried. ***
        val invented = ByteArray(16) { 0x7E }
        assertTrue("the invented id must differ from the real one or the arm is vacuous", !invented.contentEquals(real))
        surface.onCommand(MeshCommand.CancelSos(invented))

        assertEquals(
            "*** THE INVENTED ID MUST MOVE NOTHING IN THE AUTHORITY: the real call stayeth standing. ***",
            MessageStatus.QUEUED, authority.statusOf(real),
        )
        assertNotNull(
            "*** AND THE AUTHORITY MUST STILL REPORT A STANDING CALL -- a refused cancel retireth nothing. ***",
            authority.activeSos(),
        )
    }

    /**
     * *** A CANCEL FROM A SURFACE THAT NEVER READ THE AUTHORITY IS REFUSED LOCALLY, AND THE AUTHORITY'S CALL STANDS. ***
     *
     * *The surface's own projection must name the call before a cancel may reach the authority; a surface that never
     * restored carries no call in memory.* **So a fresh surface cancelling the REAL id is refused -- proving the cancel
     * road is gated by what the surface READ, not by what it remembered -- and the authority's live row is untouched.**
     */
    @Test
    fun aCancelFromASurfaceThatNeverReadTheAuthorityIsRefusedLocally() {
        val authority = Authority()
        // A first surface arms and confirms, so the AUTHORITY carries a real standing call.
        val armer = MeshViewModel(port = AuthorityPort(authority))
        armer.onCommand(MeshCommand.ArmSos)
        armer.onCommand(MeshCommand.ConfirmSos)
        val real = authority.activeSos()!!.msgIdCopy()

        // A SECOND surface that never restored: its memory carrieth no call at all.
        val unread = MeshViewModel(port = AuthorityPort(authority))
        assertNull("the second surface must not have read the call", unread.uiState().sos)
        unread.onCommand(MeshCommand.CancelSos(real))

        assertEquals(
            "*** THE AUTHORITY'S LIVE ROW MUST STAY STANDING: a surface that never read the call cannot durably " +
                "retire it. ***",
            MessageStatus.QUEUED, authority.statusOf(real),
        )
        assertNotNull("and the local refusal must be user-visible rather than silent", unread.uiState().error)
        assertNotNull("*** AND THE AUTHORITY STILL CARRIES A STANDING CALL. ***", authority.activeSos())
    }

    private fun hex(b: ByteArray): String = b.joinToString("") { "%02x".format(it) }
}
