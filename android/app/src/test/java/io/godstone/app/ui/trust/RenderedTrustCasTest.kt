package io.godstone.app.ui.trust

import androidx.compose.runtime.getValue
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.assertIsDisplayed
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.godstone.app.trust.BindingImportOutcome
import io.godstone.app.trust.ContactProjection
import io.godstone.app.trust.ContactTrustLabel
import io.godstone.app.trust.ContactVerificationCommand
import io.godstone.app.trust.ConfirmOutcome
import io.godstone.app.trust.ExactRotationCandidateRef
import io.godstone.app.trust.FingerprintDisplay
import io.godstone.app.trust.IdentityTrustViewModel
import io.godstone.app.trust.OwnIdentityProjection
import io.godstone.app.trust.RevokeOutcome
import io.godstone.app.trust.RotationApprovalOutcome
import io.godstone.app.trust.TrustCensus
import io.godstone.app.trust.TrustPort
import io.godstone.app.trust.WipeProgressState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * *** GS-UX-001 STEP 8 (TrustUiCasBuilder): THE FINGERPRINT-CONFIRM CAS, DRIVEN THROUGH THE REAL RENDERED CONTROL. ***
 * THE PROBLEM THIS COURT IS BUILT AROUND, STATED AS THE OWNER'S OWN WORDS PUT IT: *"the initial fingerprint reads are
 * correct -- the flow AFTER is what is wrong ... because that is where trust decisions are ACTUALLY made."* So this is
 * **not** another arm that reads the first projection and asserts the digest looks right. It clicks the PRODUCTION
 * control, and the discriminator is **what the durable authority ACTUALLY RECEIVED and what its row ACTUALLY BECAME**
 * -- never what the screen (or this court's prose) says happened.
 *
 * THE THREE THINGS IT PINS:
 *
 *   1. **THE CONTROL DISPATCHES THE DISPLAYED MATERIAL, EXACTLY.** The port records the [FingerprintDisplay] the
 *      rendered button handed over: the node, the digest THE SCREEN PRINTED and the accepted generation THE SCREEN
 *      PRINTED (`"Accepted generation 1"` is really in the tree). A control that re-read the row at tap time would
 *      record the FRESH operands instead, and that is the mutation this arm kills.
 *   2. **THE CAS REFUSES A ROW THAT MOVED BENEATH THE READER.** The authority's accepted generation advances *between
 *      render and tap*. The control still carrieth the DISPLAYED (stale) operands, and the durable row must NOT be
 *      promoted -- asserted from the port's own row, not from a returned sentence.
 *   3. **A REFRESHED, EXPLICITLY DISPLAYED CANDIDATE CONFIRMS.** The refusal above is paired with a success, so an arm
 *      that merely refused everything could not pass.
 *
 * *** WHY "THE PORT RECORDED IT" IS THE STRONGEST AVAILABLE WITNESS. *** *The `TrustPort` IS the transport between this
 * UI and the durable authority: what it receives is a REAL value at the real boundary, whereas the screen's
 * `lastOutcome` is a sentence the app wrote about itself. The arms below therefore read the PORT's recorded request and
 * the PORT's row, and only glance at the rendered text to prove the operand was actually displayed.*
 */
private fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33])
class RenderedTrustCasTest {
    @get:Rule val compose = createComposeRule()

    /** One durable contact row, as the authority holdeth it. */
    private class Row(
        val nodeId: ByteArray,
        val label: String,
        var trust: ContactTrustLabel,
        var acceptedGeneration: Long,
        var acceptedKeyDigest: String,
    )

    /**
     * The durable trust authority's CAS, faithfully mirrored from the real repository's semantics: a confirmation is
     * promoted ONLY when the request carrieth the digest AND the accepted generation the row actually holdeth.
     *
     * **AND IT RECORDETH WHAT IT WAS HANDED**, which is the observable this court judges: the recorded request is the
     * value the UI really sent, not the value the UI said it sent.
     */
    private class CasTrustPort : TrustPort {
        val rows = LinkedHashMap<String, Row>()
        /** Every confirmation request the port received, in order. */
        val confirmRequests = ArrayList<FingerprintDisplay>()
        var confirmCalls = 0

        fun seedTofu(seed: Byte, label: String, generation: Long = 1L): ByteArray {
            val nodeId = ByteArray(16) { (it + seed).toByte() }
            rows[nodeId.toHex()] = Row(
                nodeId, label, ContactTrustLabel.TOFU_UNVERIFIED, generation,
                ExactRotationCandidateRef.digestHex(ByteArray(32) { (it + seed).toByte() }),
            )
            return nodeId
        }

        /**
         * The authority's row MOVES beneath the reader, as a rotation approval from another device would move it: a
         * NEW accepted generation and a NEW digest. The reader's screen still carrieth the old pair.
         */
        fun advanceRowBehindTheReader(nodeId: ByteArray, newGeneration: Long, newKeySeed: Byte): String {
            val row = rows.getValue(nodeId.toHex())
            row.acceptedGeneration = newGeneration
            row.acceptedKeyDigest = ExactRotationCandidateRef.digestHex(ByteArray(32) { (it + newKeySeed).toByte() })
            return row.acceptedKeyDigest
        }

        override fun ownIdentity(): OwnIdentityProjection? = null

        override fun contacts(): TrustCensus = TrustCensus.Readable(rows.values.map { row ->
            ContactProjection(
                nodeId = row.nodeId.copyOf(),
                label = row.label,
                trust = row.trust,
                fingerprintHex = row.acceptedKeyDigest,
                acceptedGeneration = row.acceptedGeneration,
                pendingRotation = null,
            )
        })

        override fun importBinding(payload: String): BindingImportOutcome =
            BindingImportOutcome.Refused("not exercised by this court")

        override fun approveRotation(ref: ExactRotationCandidateRef): RotationApprovalOutcome =
            RotationApprovalOutcome.Refused("not exercised by this court")

        override fun confirmVerified(request: FingerprintDisplay): ConfirmOutcome {
            confirmCalls += 1
            confirmRequests.add(request)
            val row = rows[request.nodeIdCopy().toHex()] ?: return ConfirmOutcome.PeerNotFound
            if (row.trust == ContactTrustLabel.USER_VERIFIED) return ConfirmOutcome.AlreadyVerified
            // *** THE CAS, ON BOTH OPERANDS: the generation the reader compared AND the digest. *** A digest that
            // matcheth a row whose accepted generation moved beneath the reader promoteth NOTHING.
            if (row.acceptedGeneration != request.acceptedGeneration) return ConfirmOutcome.Mismatch
            if (!row.acceptedKeyDigest.equals(request.fingerprintHex, ignoreCase = true)) {
                return ConfirmOutcome.Mismatch
            }
            row.trust = ContactTrustLabel.USER_VERIFIED
            return ConfirmOutcome.Confirmed(request.nodeIdCopy(), row.acceptedGeneration)
        }

        override fun revoke(nodeId: ByteArray): RevokeOutcome = RevokeOutcome.Refused("not exercised")

        override fun wipeProgress(): WipeProgressState = WipeProgressState.Idle
        override fun beginWipe(): WipeProgressState = WipeProgressState.Idle
        override fun resumeWipe(): WipeProgressState = WipeProgressState.Idle

        /** The durable trust the row ACTUALLY holdeth now -- the value that matters, not the screen's sentence. */
        fun trustOf(nodeId: ByteArray): ContactTrustLabel = rows.getValue(nodeId.toHex()).trust
    }

    /** Render the REAL screen (the production composable) over the REAL ViewModel and the CAS port. */
    private fun render(model: IdentityTrustViewModel) {
        compose.setContent { TrustScreen(model) }
        compose.waitForIdle()
    }

    /**
     * *** ARM 1: THE RENDERED CONTROL DISPATCHES EXACTLY THE MATERIAL THE SCREEN SHOWED. ***
     *
     * *The generation operand is not an internal detail: it is PRINTED (`"Accepted generation 1"`) and then asserted
     * present in the tree, because a CAS bound on an operand the reader never saw would be the very substitution the
     * card forbids, one field over.* **AND THE PORT'S RECORD IS THE WITNESS: the request's digest and generation are the
     * displayed pair, which is what a re-resolving control would get wrong.**
     */
    @Test
    fun theRenderedConfirmDispatchesTheDisplayedDigestAndGenerationAndTheAuthorityPromotesTheRow() {
        val port = CasTrustPort()
        val nodeId = port.seedTofu(0x40, "Aunt")
        val model = IdentityTrustViewModel(port = port)
        model.refresh()
        val displayed = model.uiState().contact(nodeId)!!

        render(model)

        // (a) THE OPERANDS REALLY WERE DISPLAYED -- the generation the CAS will bind on is ON SCREEN.
        compose.onNodeWithText("Accepted generation ${displayed.acceptedGeneration}").assertIsDisplayed()

        // (b) THE PRODUCTION CONTROL'S OWN CLICK -- not a hand-built command.
        compose.onNodeWithTag(CONFIRM_FINGERPRINT_TAG + "." + displayed.label).performClick()
        compose.waitForIdle()

        // (c) *** WHAT THE AUTHORITY ACTUALLY RECEIVED: the displayed digest AND the displayed generation. ***
        assertEquals("exactly one confirmation reached the authority", 1, port.confirmCalls)
        val received = port.confirmRequests.single()
        assertTrue("the authority must have received the DISPLAYED node",
            received.nodeIdCopy().contentEquals(nodeId))
        assertEquals("*** THE AUTHORITY MUST HAVE RECEIVED THE DISPLAYED DIGEST ***",
            displayed.fingerprintHex, received.fingerprintHex)
        assertEquals("*** AND THE DISPLAYED ACCEPTED GENERATION -- the second CAS operand ***",
            displayed.acceptedGeneration, received.acceptedGeneration)

        // (d) *** AND THE DURABLE ROW REALLY MOVED: VERIFIED, read from the port's own row. ***
        assertEquals("*** THE AUTHORITY'S ROW MUST ACTUALLY BE VERIFIED NOW ***",
            ContactTrustLabel.USER_VERIFIED, port.trustOf(nodeId))
    }

    /**
     * *** ARM 2: THE CAS REFUSES A ROW THAT MOVED BENEATH THE READER -- AND THE MUTATION THE ARM KILLS IS NAMED. ***
     *
     * *The authority's accepted generation (and key digest) advance AFTER the screen rendered and BEFORE the tap --
     * exactly what an approval from another device would do. The control carrieth the DISPLAYED pair, so the
     * confirmation must be refused: the durable row must NOT be promoted.*
     *
     * *** THE OBSERVED REFUSAL POINT, MEASURED RATHER THAN ASSUMED. *** *The ViewModel's first run of this arm FAILED
     * (`NoSuchElementException` on the port's recorded requests) because NO request reached the authority at all: the
     * local half of the CAS saw that the displayed material no longer matched the row and refused BEFORE the port was
     * troubled -- the SAME two-layer shape the rotation path useth.* **So the arm asserteth what really happeneth: the
     * moved row never even reacheth the authority, and the authority's trust is unchanged.** *(A direct port-level arm
     * below proves the authority's OWN CAS refuses a stale pair too, so neither layer is taken on trust.)*
     *
     * *** THE KILL: a control that re-resolved the row at tap time would send the FRESH pair; the local check would
     * pass, the authority WOULD be called, and BOTH `confirmCalls == 0` and `trustOf == TOFU` would fail. This arm is
     * therefore sensitive to precisely the defect class the card names. ***
     */
    @Test
    fun aRowThatMovedBeneathTheReaderIsRefusedAndTheAuthoritysTrustIsUnchanged() {
        val port = CasTrustPort()
        val nodeId = port.seedTofu(0x50, "Brother", generation = 1L)
        val model = IdentityTrustViewModel(port = port)
        model.refresh()
        val displayed = model.uiState().contact(nodeId)!!
        render(model)

        // THE AUTHORITY MOVES BEHIND THE VIEW: a new accepted generation AND a new key digest.
        val freshDigest = port.advanceRowBehindTheReader(nodeId, newGeneration = 2L, newKeySeed = 0x77)
        assertFalse("this arm tests nothing unless the durable digest really changed",
            freshDigest.equals(displayed.fingerprintHex, ignoreCase = true))

        compose.onNodeWithTag(CONFIRM_FINGERPRINT_TAG + "." + displayed.label).performClick()
        compose.waitForIdle()

        // (a) *** THE STALE CONFIRMATION NEVER REACHED THE AUTHORITY AT ALL. ***
        assertEquals("*** A ROW THAT MOVED BENEATH THE READER MUST NOT REACH THE AUTHORITY, let alone be " +
            "promoted: the displayed material no longer names this row ***", 0, port.confirmCalls)

        // (b) *** AND THE DURABLE TRUST IS EXACTLY WHERE IT WAS. ***
        assertEquals("*** THE AUTHORITY'S TRUST MUST BE UNCHANGED ***",
            ContactTrustLabel.TOFU_UNVERIFIED, port.trustOf(nodeId))

        // (c) AND THE VIEW RE-PROJECTED THE AUTHORITY (the comparison began by reading it): what the screen now
        // carrieth is the FRESH, durable pair -- so a reader who compares again is comparing the CURRENT material.
        assertEquals("the projection must carry the authority's CURRENT digest, not the stale one",
            freshDigest, model.uiState().contact(nodeId)!!.fingerprintHex)
        assertNotNull("and the reader must be told the comparison no longer holds",
            model.uiState().error)
    }

    /**
     * *** ARM 2b: THE AUTHORITY'S OWN CAS REFUSES A STALE PAIR -- AT THE PORT, INDEPENDENT OF THE VIEW. ***
     *
     * *The arms above prove the VIEW refuses; this one proves the AUTHORITY does, so the ViewModel's local check is a
     * fast path rather than the only guard. A request carrying a generation the row no longer holdeth must be answered
     * `Mismatch` and must leave the row exactly as it stood.*
     */
    @Test
    fun theAuthorityItselfRefusesAStaleGenerationAndItsTrustIsUnchanged() {
        val port = CasTrustPort()
        val nodeId = port.seedTofu(0x51, "Neighbour", generation = 3L)
        val digestShownByTheReader = "ab".repeat(32)
        port.rows.getValue(nodeId.toHex()).acceptedKeyDigest = digestShownByTheReader
        port.advanceRowBehindTheReader(nodeId, newGeneration = 4L, newKeySeed = 0x79)

        // The reader's material: the OLD digest and the OLD generation -- a pair the row no longer holdeth.
        val stale = FingerprintDisplay(
            nodeId = nodeId.copyOf(),
            fingerprintHex = digestShownByTheReader,
            acceptedGeneration = 3L,
        )
        val outcome = port.confirmVerified(stale)

        assertTrue("*** THE AUTHORITY'S OWN CAS MUST REFUSE A GENERATION THE ROW NO LONGER HOLDS ***",
            outcome is ConfirmOutcome.Mismatch)
        assertEquals("and the durable trust is exactly where it was",
            ContactTrustLabel.TOFU_UNVERIFIED, port.trustOf(nodeId))
    }

    /**
     * *** ARM 3: THE PAIRED SUCCESS. ***
     *
     * *The refusal above must not be a control that refuses everything.* Here the reader REFRESHES (so the screen
     * carrieth the authority's CURRENT pair) and confirms it: the authority must promote the row, and the recorded
     * request must be the FRESH pair -- proving the operand really travelleth from what the screen held.
     */
    @Test
    fun anExplicitlyRefreshedCandidateConfirmsAndTheRecordedRequestFollowsTheRefresh() {
        val port = CasTrustPort()
        val nodeId = port.seedTofu(0x60, "Cousin", generation = 1L)
        val model = IdentityTrustViewModel(port = port)
        model.refresh()
        render(model)
        port.advanceRowBehindTheReader(nodeId, newGeneration = 2L, newKeySeed = 0x78)

        // THE READER REFRESHES: the projection now carrieth the authority's CURRENT pair.
        model.refresh()
        compose.waitForIdle()
        val fresh = model.uiState().contact(nodeId)!!

        compose.onNodeWithTag(CONFIRM_FINGERPRINT_TAG + "." + fresh.label).performClick()
        compose.waitForIdle()

        val received = port.confirmRequests.single()
        assertEquals("*** THE REQUEST MUST FOLLOW THE REFRESHED, DISPLAYED GENERATION ***",
            2L, received.acceptedGeneration)
        assertEquals("and the refreshed digest", fresh.fingerprintHex, received.fingerprintHex)
        assertEquals("*** THE AUTHORITY MUST ACTUALLY PROMOTE THE REFRESHED ROW ***",
            ContactTrustLabel.USER_VERIFIED, port.trustOf(nodeId))
    }

    /**
     * *** ARM 4: A MISMATCHED TYPED CODE NEVER REACHES THE AUTHORITY. ***
     *
     * *A local mismatch is refused BEFORE the port is consulted, so a wrong comparison cannot even be attempted
     * against the durable store -- and the row stays exactly as it was.* The discriminator is the port's own call
     * counter: a control (or ViewModel) that forwarded every comparison would show calls == 1 here.
     */
    @Test
    fun aLocalMismatchNeverReachesTheAuthority() {
        val port = CasTrustPort()
        val nodeId = port.seedTofu(0x70, "Warden")
        val model = IdentityTrustViewModel(port = port)
        model.refresh()
        val displayed = model.uiState().contact(nodeId)!!

        val wrong = displayed.fingerprintHex.reversed()
        model.onCommand(
            ContactVerificationCommand.CompareAndConfirmFingerprint(
                nodeId, wrong, displayedAcceptedGeneration = displayed.acceptedGeneration),
        )

        assertEquals("*** A LOCAL MISMATCH MUST NOT TROUBLE THE DURABLE AUTHORITY ***", 0, port.confirmCalls)
        assertEquals("and the trust must be exactly where it was",
            ContactTrustLabel.TOFU_UNVERIFIED, port.trustOf(nodeId))
    }

    /**
     * *** ARM 5: THE DISPLAYED GENERATION IS PART OF THE LOCAL COMPARISON, NOT MERELY FORWARDED. ***
     *
     * *A caller that presenteth a STALE generation with a matching digest is refused BEFORE the port is consulted --
     * so "the row moved and nobody refreshed" cannot even be attempted against the authority by a future caller that
     * bypassed the rendered control.* **The port's call count is the witness: the refusal is LOCAL.**
     */
    @Test
    fun aStaleDisplayedGenerationIsRefusedLocallyAndNeverReachesTheAuthority() {
        val port = CasTrustPort()
        val nodeId = port.seedTofu(0x68, "Farmer", generation = 5L)
        val model = IdentityTrustViewModel(port = port)
        model.refresh()
        val displayed = model.uiState().contact(nodeId)!!

        val state = model.onCommand(
            ContactVerificationCommand.CompareAndConfirmFingerprint(
                nodeId, displayed.fingerprintHex, displayedAcceptedGeneration = 4L),
        )

        assertEquals("*** A STALE DISPLAYED GENERATION MUST BE REFUSED BEFORE THE AUTHORITY IS CALLED ***",
            0, port.confirmCalls)
        assertNotNull("and the reader is told why", state.error)
        assertEquals("the durable row is untouched",
            ContactTrustLabel.TOFU_UNVERIFIED, port.trustOf(nodeId))
    }
}
