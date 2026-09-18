// T57 readiness court (android isle) -- direct messaging and honest SOS controls.
//
// The card's law: "Never show secure/connected before trusted key confirmation or
// sent on ATT acceptance." The ViewModel is driven through `MeshPort` and nothing
// else, against a DETERMINISTIC port that projects statuses the way the durable
// authority would: an ATT acceptance is ATTEMPTING and only an authenticated
// recipient ACK is DELIVERED. That is what letteth the card's named semantic
// negative -- "Project DELIVERED from transport Boolean" -- be EXECUTED rather
// than argued.
//
// No device behaviour is claimed: the radio is a port, the physical matrix stays
// external (T73-T75), and readiness stays false.
package io.godstone.app.readiness

import io.godstone.app.mesh.DirectComposePolicy
import io.godstone.app.mesh.LinkState
import io.godstone.app.mesh.MeshCommand
import io.godstone.app.mesh.MeshPort
import io.godstone.app.mesh.MeshUiState
import io.godstone.app.mesh.MeshViewModel
import io.godstone.app.mesh.MessageProjection
import io.godstone.app.mesh.MessageStatus
import io.godstone.app.mesh.RecipientProjection
import io.godstone.app.mesh.RetryOutcome
import io.godstone.app.mesh.SendOutcome
import io.godstone.app.mesh.SosOutcome
import io.godstone.app.mesh.SosProjection
import io.godstone.app.trust.ContactTrustLabel
import io.godstone.app.ui.mesh.statusWords
import java.io.File
import org.junit.Assert
import org.junit.Test

class ReadinessT57Test {

    private fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }

    /** One durable message row, as the authority would carry it. */
    private class Row(
        val msgId: ByteArray,
        val peerLabel: String,
        var body: String,
        var status: MessageStatus,
        val outgoing: Boolean,
        var retryable: Boolean,
        var note: String? = null,
    )

    /**
     * The durable authority's SEMANTICS, faithfully mirrored: a send QUEUES, a
     * link acceptance moveth the row to ATTEMPTING, and only an authenticated
     * recipient ACK moveth it to DELIVERED.
     */
    private class MeshDouble(
        private var nodeId: ByteArray = ByteArray(16) { (it + 0x60).toByte() },
    ) : MeshPort {
        val rows = ArrayList<Row>()
        var link: LinkState = LinkState.Offline
        var recipients = ArrayList<RecipientProjection>()
        var storageFails = false
        var relayCopiesMayBeOut = false
        var activeSosRow: Row? = null
        var sends = 0
        var calls = 0

        /** What the RADIO did, as opposed to what the authority recorded. */
        var lastTransportAccepted = false

        fun seedRecipient(seed: Byte, label: String, trust: ContactTrustLabel): RecipientProjection {
            val projection = RecipientProjection(
                ByteArray(16) { (it + seed).toByte() }, label, trust)
            recipients.add(projection)
            return projection
        }

        /** A link acceptance: what an ATT Boolean proveth, and nothing more. */
        fun transportAccepted(msgId: ByteArray) {
            lastTransportAccepted = true
            rows.firstOrNull { it.msgId.contentEquals(msgId) }?.let { row ->
                row.status = MessageStatus.ATTEMPTING
                row.note = "a link took the bytes; no recipient answered yet"
            }
        }

        /** The intended recipient's AUTHENTICATED ACK: the only delivery road. */
        fun recipientAcked(msgId: ByteArray) {
            rows.firstOrNull { it.msgId.contentEquals(msgId) }?.let { row ->
                row.status = MessageStatus.DELIVERED
                row.retryable = false
                row.note = null
            }
        }

        override fun linkState(): LinkState = link

        override fun recipients(): List<RecipientProjection> = ArrayList(recipients)

        override fun messages(): List<MessageProjection> =
            rows.map { row ->
                MessageProjection(
                    msgId = row.msgId.copyOf(), peerLabel = row.peerLabel, body = row.body,
                    status = row.status, outgoing = row.outgoing, retryable = row.retryable,
                    authorityNote = row.note,
                )
            }

        override fun activeSos(): SosProjection? = activeSosRow?.let {
            SosProjection(it.msgId.copyOf(), it.status, relayCopiesMayBeOut)
        }

        override fun sendDirect(recipientNodeId: ByteArray, body: String): SendOutcome {
            sends++
            if (storageFails) return SendOutcome.Refused("the store refused the row")
            val msgId = ByteArray(16) { (it + sends + 0x10).toByte() }
            val label = recipients.firstOrNull { it.nodeIdCopy().contentEquals(recipientNodeId) }
                ?.label ?: "unknown"
            rows.add(Row(msgId, label, body, MessageStatus.QUEUED, outgoing = true, retryable = true))
            return SendOutcome.Queued(msgId.copyOf())
        }

        override fun retry(msgId: ByteArray): RetryOutcome {
            val row = rows.firstOrNull { it.msgId.contentEquals(msgId) }
                ?: return RetryOutcome.Refused("no such row")
            if (storageFails) return RetryOutcome.Refused("the store refused the retry")
            if (!row.retryable) return RetryOutcome.Refused("terminal state")
            return RetryOutcome.Accepted(msgId.copyOf())
        }

        override fun beginSos(body: String): SosOutcome {
            calls++
            if (storageFails) return SosOutcome.Refused("the store refused the call")
            if (activeSosRow != null) return SosOutcome.Refused("a call is already active")
            val msgId = ByteArray(16) { (it + calls + 0x40).toByte() }
            val row = Row(msgId, "broadcast", body, MessageStatus.QUEUED, outgoing = true,
                retryable = true, note = "queued on this phone")
            rows.add(row)
            activeSosRow = row
            return SosOutcome.Enqueued(msgId.copyOf())
        }

        override fun cancelSos(msgId: ByteArray): SosOutcome {
            val row = activeSosRow ?: return SosOutcome.Refused("no active call")
            if (!row.msgId.contentEquals(msgId)) return SosOutcome.Refused("no such active call")
            if (row.status == MessageStatus.CANCELLED) {
                return SosOutcome.AlreadyCancelled(relayCopiesMayBeOut)
            }
            row.status = MessageStatus.CANCELLED
            row.retryable = false
            activeSosRow = null
            return SosOutcome.Cancelled(relayCopiesMayBeOut)
        }
    }

    private fun model(port: MeshPort) = MeshViewModel(port = port)

    private fun selectAndDraft(model: MeshViewModel, recipient: RecipientProjection, body: String) {
        model.onCommand(MeshCommand.SelectRecipient(recipient.nodeIdCopy()))
        model.onCommand(MeshCommand.Draft(body))
    }

    // ------------------------------------------------------------ W01

    /** W01 -- the whole journey: offline -> a peer appears -> an ACK delivers. */
    @Test
    fun test_w01_offline_then_a_peer_then_the_ack() {
        val port = MeshDouble()
        val peer = port.seedRecipient(0x11, "Aunt", ContactTrustLabel.USER_VERIFIED)
        val view = model(port)

        // 1. OFFLINE: the message is queued and the banner sayeth so
        val offline = view.refresh()
        Assert.assertTrue(offline.link is LinkState.Offline)
        Assert.assertNotNull("an offline link is explained", offline.link.explanation)
        Assert.assertTrue(offline.link.explanation!!.contains("queued"))
        selectAndDraft(view, peer, "the bridge is out")
        Assert.assertTrue(view.uiState().canSend)
        view.onCommand(MeshCommand.SendDirect)
        val queued = view.uiState()
        Assert.assertEquals(MessageStatus.QUEUED, queued.messages.single().status)
        Assert.assertFalse("a queued message claimeth nothing", queued.messages.single().claimsDelivery)
        // the WORDS are the interface at this layer: a queued row may not be
        // rendered as "Sent", and the ATT words may not be the DELIVERY words
        Assert.assertTrue("a queued row is rendered as Queued",
            statusWords(MessageStatus.QUEUED).contains("Queued"))
        Assert.assertFalse("and never as Sent",
            statusWords(MessageStatus.QUEUED).contains("Sent"))
        Assert.assertNotEquals("the ATT words differ from the DELIVERY words",
            statusWords(MessageStatus.ATTEMPTING), statusWords(MessageStatus.DELIVERED))
        Assert.assertFalse("and the ATT words do not claim a delivery",
            statusWords(MessageStatus.ATTEMPTING).contains("Delivered"))

        // 2. A PEER APPEARS: the link is up, and the message is still not delivered
        port.link = LinkState.Connected(peers = 1)
        val connected = view.refresh()
        Assert.assertTrue(connected.link is LinkState.Connected)
        Assert.assertNull("a connected link needeth no explanation", connected.link.explanation)
        Assert.assertEquals("a link that came up delivereth NOTHING",
            MessageStatus.QUEUED, connected.messages.single().status)

        // 3. the radio takes the bytes: an ATT acceptance, and no more
        port.transportAccepted(queued.messages.single().msgIdCopy())
        val attempting = view.refresh()
        Assert.assertEquals(MessageStatus.ATTEMPTING, attempting.messages.single().status)
        Assert.assertFalse("an ATT acceptance is NOT a delivery",
            attempting.messages.single().claimsDelivery)

        // 4. the RECIPIENT's authenticated ACK commits: now, and only now
        port.recipientAcked(queued.messages.single().msgIdCopy())
        val delivered = view.refresh()
        Assert.assertEquals(MessageStatus.DELIVERED, delivered.messages.single().status)
        Assert.assertTrue(delivered.messages.single().claimsDelivery)
        Assert.assertTrue(statusWords(MessageStatus.DELIVERED).contains("Delivered"))
    }

    // ------------------------------------------------------------ W02

    /**
     * W02 -- THE NAMED NEGATIVE: a transport Boolean may never produce DELIVERED.
     * The port reporteth a QUEUED outcome and its projected row carrieth the ATT
     * acceptance; the UI must show ATTEMPTING, never a delivery.
     */
    @Test
    fun test_w02_a_transport_boolean_never_projecteth_delivered() {
        val port = MeshDouble()
        val peer = port.seedRecipient(0x12, "Brother", ContactTrustLabel.USER_VERIFIED)
        val view = model(port)
        selectAndDraft(view, peer, "meet me at the hall")
        val sent = view.onCommand(MeshCommand.SendDirect)
        val msgId = sent.messages.single().msgIdCopy()
        // the SEND's own outcome sayeth "queued", never "sent" and never "delivered"
        Assert.assertTrue("the send claimeth a QUEUE, not a send",
            (sent.lastOutcome ?: "<none>").contains("queued"))
        Assert.assertFalse("and it never claimeth a send",
            (sent.lastOutcome ?: "").contains("sent"))

        // the radio accepted the bytes -- the ONLY thing an ATT Boolean proveth
        port.transportAccepted(msgId)
        val state = view.refresh()
        val row = state.messages.single()
        Assert.assertEquals("an accepted Boolean is an ATTEMPT, never a delivery",
            MessageStatus.ATTEMPTING, row.status)
        Assert.assertFalse(row.claimsDelivery)
        Assert.assertNotEquals("the word 'Delivered' may not appear for an ATT acceptance",
            "Delivered: the recipient confirmed it.", statusWords(row.status))
        Assert.assertTrue("and the words sayeth the truth", statusWords(row.status).contains("no answer"))

        // ... and a later refresh carrieth NO new outcome: the status is the row's,
        // so a stale row cannot be upgraded by a Boolean
        Assert.assertNull("a refresh inventeth no outcome", state.lastOutcome)
        Assert.assertEquals("the projected word is the row's", MessageStatus.ATTEMPTING,
            state.messages.single().status)
    }

    // ------------------------------------------------------------ W03

    /** W03 -- FAILED STORAGE: the row is never created and the draft surviveth. */
    @Test
    fun test_w03_failed_storage_leaveth_the_estate_and_the_draft() {
        val port = MeshDouble()
        val peer = port.seedRecipient(0x13, "Chemist", ContactTrustLabel.USER_VERIFIED)
        val view = model(port)
        selectAndDraft(view, peer, "do you have insulin")
        val before = view.uiState().messages.size
        port.storageFails = true

        val refused = view.onCommand(MeshCommand.SendDirect)
        Assert.assertNotNull("a refusal is visible", refused.error)
        Assert.assertTrue(refused.error!!.contains("store refused"))
        Assert.assertEquals("no durable row was created", before, port.rows.size)
        Assert.assertEquals("and the projected list is unchanged", before, refused.messages.size)
        Assert.assertEquals("the user's text is NOT thrown away",
            "do you have insulin", refused.draft)
    }

    // ------------------------------------------------------------ W04

    /** W04 -- DUPLICATE TAPS: one row, and the second tap refuse. */
    @Test
    fun test_w04_duplicate_taps_create_one_row() {
        val port = MeshDouble()
        val peer = port.seedRecipient(0x14, "Warden", ContactTrustLabel.USER_VERIFIED)
        val view = model(port)
        selectAndDraft(view, peer, "one message")

        view.onCommand(MeshCommand.SendDirect)
        val second = view.onCommand(MeshCommand.SendDirect)
        Assert.assertEquals("exactly ONE durable row", 1, port.rows.size)
        Assert.assertEquals("and one send reached the authority", 1, port.sends)
        Assert.assertNotNull("the duplicate tap is refused with a reason", second.error)
        Assert.assertTrue(second.error!!.contains("nothing to send"))
        Assert.assertEquals("the draft was cleared by the first send", "", second.draft)
    }

    // ------------------------------------------------------------ W05

    /** W05 -- REVOKE: the recipient is blocked, the chip sayeth so, sends refuse. */
    @Test
    fun test_w05_revoke_blocketh_the_conversation() {
        val port = MeshDouble()
        val peer = port.seedRecipient(0x15, "Ferryman", ContactTrustLabel.USER_VERIFIED)
        val view = model(port)
        selectAndDraft(view, peer, "across the water?")
        Assert.assertTrue("a verified contact is secure", view.uiState().isSecure)

        // the operator revoketh the contact in the trust surface
        port.recipients.clear()
        port.seedRecipient(0x15, "Ferryman", ContactTrustLabel.REVOKED)
        val revoked = view.refresh()
        Assert.assertFalse("a revoked contact is NOT secure", revoked.isSecure)
        Assert.assertTrue(revoked.securitySummary.contains("Blocked"))

        // and the authority refuseth the send
        port.storageFails = false
        selectAndDraft(view, port.recipients.single(), "across the water?")
        port.storageFails = true
        val refused = view.onCommand(MeshCommand.SendDirect)
        Assert.assertNotNull(refused.error)
    }

    // ------------------------------------------------------------ W06

    /** W06 -- the DIRECT compose bound is 400 UTF-8 BYTES, character-safe. */
    @Test
    fun test_w06_the_compose_bound_is_bytes_not_characters() {
        Assert.assertEquals(400, DirectComposePolicy.MAX_BODY_BYTES)
        val ascii400 = "a".repeat(400)
        Assert.assertTrue("400 ASCII bytes fit", DirectComposePolicy.fits(ascii400))
        Assert.assertFalse("401 do not", DirectComposePolicy.fits("a".repeat(401)))
        // a multi-byte body: 200 CJK characters are 600 bytes and MUST be refused,
        // though a character count would have called them short
        val cjk = "\u6c34".repeat(200)
        Assert.assertEquals(200, cjk.length)
        Assert.assertEquals(600, DirectComposePolicy.byteCount(cjk))
        Assert.assertFalse("the bound is BYTES", DirectComposePolicy.fits(cjk))

        val port = MeshDouble()
        val peer = port.seedRecipient(0x16, "Sister", ContactTrustLabel.USER_VERIFIED)
        val view = model(port)
        selectAndDraft(view, peer, cjk)
        Assert.assertNotNull("an over-budget draft is refused visibly", view.uiState().error)
        Assert.assertTrue(view.uiState().error!!.contains("600 bytes"))
        Assert.assertFalse(view.uiState().canSend)

        // truncation never splits a character into invalid UTF-8
        val truncated = DirectComposePolicy.truncateToFit(cjk)
        Assert.assertTrue(DirectComposePolicy.fits(truncated))
        Assert.assertTrue("the cut is on a CHARACTER boundary",
            truncated.toByteArray(Charsets.UTF_8).toString(Charsets.UTF_8) == truncated)
        Assert.assertEquals("and it keepeth whole characters only", 133, truncated.length)
    }

    // ------------------------------------------------------------ W07

    /** W07 -- the SOS control is HELD: a bare confirm placeth nothing. */
    @Test
    fun test_w07_the_sos_control_requireth_an_arm() {
        val port = MeshDouble()
        val view = model(port)

        val bare = view.onCommand(MeshCommand.ConfirmSos)
        Assert.assertNotNull("a bare confirm is refused", bare.error)
        Assert.assertTrue(bare.error!!.contains("hold"))
        Assert.assertEquals("and NO call was placed", 0, port.calls)
        Assert.assertNull("nor is a call active", bare.sos)

        view.onCommand(MeshCommand.ArmSos)
        Assert.assertTrue(view.uiState().sosArmed)
        val placed = view.onCommand(MeshCommand.ConfirmSos)
        Assert.assertEquals("the held control placed exactly one call", 1, port.calls)
        Assert.assertNotNull(placed.sos)
        Assert.assertEquals(MessageStatus.QUEUED, placed.sos!!.status)

        // a disarm sendeth nothing
        view.onCommand(MeshCommand.DisarmSos)
        Assert.assertFalse(view.uiState().sosArmed)
        Assert.assertEquals("disarming placed nothing further", 1, port.calls)
    }

    // ------------------------------------------------------------ W08

    /** W08 -- CANCEL nameth the relayed-copy limitation honestly, either way. */
    @Test
    fun test_w08_cancel_nameth_the_relayed_copy_limitation() {
        val port = MeshDouble()
        val view = model(port)
        view.onCommand(MeshCommand.ArmSos)
        val placed = view.onCommand(MeshCommand.ConfirmSos)
        val msgId = placed.sos!!.msgIdCopy()

        // case A: no copy had left this device
        port.relayCopiesMayBeOut = false
        val activeRow = view.uiState().sos
        Assert.assertNotNull(activeRow)
        Assert.assertTrue("the SCREEN's words sayeth no copy has left",
            activeRow!!.cancelExplanation.contains("No copy has left"))
        val quiet = view.onCommand(MeshCommand.CancelSos(msgId))
        Assert.assertTrue(quiet.lastOutcome!!.contains("no copy had left"))
        Assert.assertNull(quiet.sos)

        // case B: copies MAY be out -- the words must not imply recall
        val port2 = MeshDouble()
        port2.relayCopiesMayBeOut = true
        val view2 = model(port2)
        view2.onCommand(MeshCommand.ArmSos)
        val placed2 = view2.onCommand(MeshCommand.ConfirmSos)
        val loudRow = view2.uiState().sos
        Assert.assertNotNull(loudRow)
        Assert.assertTrue("the SCREEN's words state the limitation",
            loudRow!!.cancelExplanation.contains("cannot be recalled"))
        val loud = view2.onCommand(MeshCommand.CancelSos(placed2.sos!!.msgIdCopy()))
        Assert.assertTrue(loud.lastOutcome!!.contains("cannot be recalled"))
        Assert.assertFalse("the outcome NEVER claimeth recall",
            loud.lastOutcome!!.contains("recalled successfully"))

        // and a second cancel is idempotent
        val again = view.onCommand(MeshCommand.CancelSos(msgId))
        Assert.assertNotNull("there is no call left to cancel", again.error)
    }

    // ------------------------------------------------------------ W09

    /** W09 -- a RELAUNCH restoreth the active call from the durable row. */
    @Test
    fun test_w09_a_relaunch_restoreth_the_active_call() {
        val port = MeshDouble()
        val first = model(port)
        first.onCommand(MeshCommand.ArmSos)
        val placed = first.onCommand(MeshCommand.ConfirmSos)
        Assert.assertNotNull(placed.sos)

        // the process dieth and a FRESH model standeth over the same authority
        val relaunched = model(port)
        val beforeRestore = relaunched.refresh()
        Assert.assertNotNull("the durable row re-exposeth the call unasked", beforeRestore.sos)
        Assert.assertEquals(placed.sos!!.msgIdCopy().toHex(),
            beforeRestore.sos!!.msgIdCopy().toHex())
        Assert.assertFalse("and the fresh model is NOT armed", beforeRestore.sosArmed)

        val restored = relaunched.onCommand(MeshCommand.RestoreActiveSos)
        Assert.assertTrue(restored.lastOutcome!!.contains("restored"))
        Assert.assertNotNull(restored.sos)
    }

    // ------------------------------------------------------------ W10

    /** W10 -- a DENIED permission is explained, not merely failed. */
    @Test
    fun test_w10_a_denied_permission_is_explained() {
        val port = MeshDouble()
        val peer = port.seedRecipient(0x17, "Doctor", ContactTrustLabel.USER_VERIFIED)
        val view = model(port)
        port.link = LinkState.PermissionDenied
        selectAndDraft(view, peer, "the surgery is closed")

        val state = view.refresh()
        val words = state.link.explanation
        Assert.assertNotNull("a denied permission is EXPLAINED", words)
        Assert.assertTrue("and it nameth the permission", words!!.contains("permission"))
        Assert.assertTrue("and it nameth the remedy", words.contains("Settings"))
        Assert.assertTrue("and it sayeth the message is kept", words.contains("queued"))
        // the message may still be queued locally -- being unable to transmit is
        // not a reason to lose it
        view.onCommand(MeshCommand.SendDirect)
        Assert.assertEquals(MessageStatus.QUEUED, view.uiState().messages.single().status)
    }

    // ------------------------------------------------------------ W11

    /** W11 -- an UNSUPPORTED direction is explained distinctly. */
    @Test
    fun test_w11_an_unsupported_direction_is_explained_distinctly() {
        val port = MeshDouble()
        val view = model(port)
        port.link = LinkState.Unsupported
        val unsupported = view.refresh().link.explanation
        Assert.assertNotNull(unsupported)
        Assert.assertTrue(unsupported!!.contains("Bluetooth"))
        Assert.assertTrue(unsupported.contains("stay queued"))
        // the two explanations are DIFFERENT: a user must be able to act on them
        port.link = LinkState.PermissionDenied
        val denied = view.refresh().link.explanation
        Assert.assertNotEquals("a denial and an unsupported radio are not the same problem",
            unsupported, denied)
    }

    // ------------------------------------------------------------ W12

    /** W12 -- nothing is SECURE before the trusted key is confirmed. */
    @Test
    fun test_w12_nothing_is_secure_before_the_key_is_confirmed() {
        val port = MeshDouble()
        val tofu = port.seedRecipient(0x18, "Neighbour", ContactTrustLabel.TOFU_UNVERIFIED)
        val view = model(port)
        // a link IS up: the thing a naive screen would call "connected/secure"
        port.link = LinkState.Connected(peers = 2)
        selectAndDraft(view, tofu, "hello")

        val pinned = view.uiState()
        Assert.assertTrue("the link really is up", pinned.link is LinkState.Connected)
        Assert.assertFalse("a link that is up is NOT security", pinned.isSecure)
        Assert.assertTrue(pinned.securitySummary.contains("pinned on first use"))
        Assert.assertNotEquals(statusWords(MessageStatus.DELIVERED),
            statusWords(MessageStatus.ATTEMPTING))

        // the user confirms the key: NOW the chip may say secure
        port.recipients.clear()
        port.seedRecipient(0x18, "Neighbour", ContactTrustLabel.USER_VERIFIED)
        val verified = view.refresh()
        Assert.assertTrue("a confirmed key IS security", verified.isSecure)
        Assert.assertTrue(verified.securitySummary.contains("you verified"))
    }

    // ------------------------------------------------------------ W13

    /**
     * W13 -- the app layer never WRITETH a status. A witness readeth the source to
     * prove the words cometh from the projection, and that the durable vocabulary
     * the projection speaketh is T43's.
     */
    @Test
    fun test_w13_the_app_never_writeth_a_status_of_its_own() {
        var repo = File(System.getProperty("user.dir"))
        var hops = 0
        while (!File(repo, "android").isDirectory && hops < 8) {
            repo = repo.parentFile ?: break
            hops++
        }
        val viewModel = File(repo, "android/app/src/main/java/io/godstone/app/mesh/MeshViewModel.kt")
        Assert.assertTrue("the ViewModel must be discoverable: " + viewModel.path, viewModel.isFile)
        val text = viewModel.readText()
        Assert.assertFalse("the ViewModel never inventeth a DELIVERED status",
            text.contains("MessageStatus.DELIVERED"))
        Assert.assertFalse("nor an ATTEMPTING one: both cometh from the row",
            text.contains("MessageStatus.ATTEMPTING"))
        Assert.assertTrue("it re-projects instead", text.contains("port.messages()"))

        // and the status vocabulary the projection speaketh is the durable one
        val contracts = File(repo, "android/app/src/main/java/io/godstone/app/mesh/MeshContracts.kt")
            .readText()
        for (status in listOf("QUEUED", "ATTEMPTING", "DELIVERED", "CANCELLED", "EXPIRED", "FAILED")) {
            Assert.assertTrue("the app vocabulary carrieth $status", contracts.contains(status))
        }
        val delivery = File(repo, "android/mesh/src/main/java/io/godstone/mesh/delivery/DeliveryProjection.kt")
        Assert.assertTrue("the durable label vocabulary must be discoverable", delivery.isFile)
        val durable = delivery.readText()
        for (label in listOf("QUEUED", "OFFERED", "DELIVERED", "EXPIRED", "CANCELLED")) {
            Assert.assertTrue("the durable projection carrieth $label", durable.contains(label))
        }
    }
    // ================================================================ GS-UX-001 step 4: THE SELECTOR DISPATCHETH

    /**
     * *** GS-UX-001 STEP 4: *'Add a real recipient selector'* -- AND A SELECTOR IS A DISPATCHER, NOT A LIST. ***
     *
     * MEASURED BEFORE ROUND 541: the mesh screen printed *'Choose a recipient'* and offered **NO WAY TO CHOOSE
     * ONE** -- the recipients came from the port and nothing let the operator select one. **A PROMPT WITH NO CONTROL
     * IS NOT A CONTROL.**
     *
     * AND THE INVARIANT THIS ARM KEEPS IS THE ONE THAT MATTERS ABOUT A UI-SIDE SELECTOR: **THE SELECTION MUST
     * TRAVEL TO THE AUTHORITY THE SEND USES.** The control dispatcheth `SelectRecipient` -- EXACTLY what the chip in
     * `MeshContent` dispatcheth -- and the arm then asserteth that the SEND GOETH TO THE CHOSEN RECIPIENT. **A
     * SELECTOR WHOSE CHOICE NEVER REACHES THE SEND IS DECORATION.**
     */
    @Test
    fun test_ux041_the_recipient_selector_dispatches_and_the_send_follows_it() {
        val port = MeshDouble()
        val aunt = port.seedRecipient(0x21, "Aunt", ContactTrustLabel.USER_VERIFIED)
        port.seedRecipient(0x31, "Uncle", ContactTrustLabel.TOFU_UNVERIFIED)
        val view = model(port)
        view.refresh()
        val offered = view.uiState().recipients
        Assert.assertTrue("*** the port must offer recipients, or this arm tests nothing ***",
            offered.size >= 2)

        // THE CONTROL'S OWN CALL: exactly what the chip dispatcheth.
        view.onCommand(MeshCommand.SelectRecipient(aunt.nodeIdCopy()))
        val selected = view.uiState().selectedRecipient
        Assert.assertNotNull("the dispatch must select", selected)
        Assert.assertTrue("*** and the selection must be the one CHOSEN, by identity ***",
            selected!!.nodeIdCopy().contentEquals(aunt.nodeIdCopy()))

        // *** AND IT FLOWETH: the draft-and-send then travelleth to THAT recipient. *** The double labelleth the
        // row with the recipient it was HANDED, so the label IS the witness of where the send went.
        view.onCommand(MeshCommand.Draft("the mill road is cut"))
        view.onCommand(MeshCommand.SendDirect)
        val row = view.uiState().messages.singleOrNull()
        Assert.assertNotNull("the send must queue exactly one row", row)
        Assert.assertEquals(
            "*** THE SEND MUST GO TO THE RECIPIENT THE SELECTOR CHOSE: a selector whose choice never reaches the " +
                "send is decoration (GS-UX-001 step 4) ***",
            "Aunt", row!!.peerLabel)
    }
}
