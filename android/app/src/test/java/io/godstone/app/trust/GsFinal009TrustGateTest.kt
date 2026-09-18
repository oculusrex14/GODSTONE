package io.godstone.app.trust

import io.godstone.app.mesh.ProtectedDataGate
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * *** GS-FINAL-009 (round 715) -- THE SECOND CONSUMER, GATED: `IdentityTrustViewModel`. ***
 *
 * **FOUND BY AN INDEPENDENT SWEEP THAT ENUMERATED EVERY CONSUMER OF `ProtectedDataGate` RATHER THAN TRUSTING THE
 * FINDING'S `affected_files`** (*which named only `MeshContracts.kt` and `MeshViewModel.kt`*). *The audit's own wording
 * is generic to the class, not to one file: "view-model methods are callable ... Enforce the same gate atomically at
 * command/repository admission, not only in buttons."*
 *
 * **MEASURED, THIS VIEW-MODEL READ THE PORT BEFORE ASKING THE GATE:** `port.contacts()`, `port.ownIdentity()` and
 * `port.wipeProgress()` all ran first, and `protectedData.isProtectedDataAvailable()` was consulted only to fill a
 * presentation field -- *the audit's root cause verbatim: "Availability is represented as presentation metadata rather
 * than a prerequisite capability for data access and side effects."*
 *
 * *** AND THIS FILE REUSES THE AUDIT'S OWN INSTRUMENT: "a port that records/throws on any protected read or command;
 * zero calls must occur." *** *A THROW RATHER THAN AN EMPTY ANSWER IS THE POINT: an empty list would let an unguarded
 * projection publish "you have no contacts", which is A LIE THAT LOOKS LIKE A STATE. A throw cannot be mistaken for
 * one.*
 */
class GsFinal009TrustGateTest {

    private class SwitchableGate(private var available: Boolean) : ProtectedDataGate {
        override fun isProtectedDataAvailable(): Boolean = available
    }

    /**
     * THE AUDIT'S INSTRUMENT: every protected read THROWS and every command is counted, so an unguarded road cannot
     * pass by returning something plausible.
     */
    private class RecordingPort : TrustPort {
        var protectedReads = 0; private set
        var commands = 0; private set

        private fun boom(): Nothing = throw IllegalStateException("protected store is not readable")

        override fun ownIdentity(): OwnIdentityProjection? { protectedReads += 1; boom() }
        override fun contacts(): TrustCensus { protectedReads += 1; boom() }
        override fun wipeProgress(): WipeProgressState { protectedReads += 1; boom() }

        override fun importBinding(payload: String): BindingImportOutcome { commands += 1; boom() }
        override fun approveRotation(ref: ExactRotationCandidateRef): RotationApprovalOutcome { commands += 1; boom() }
        override fun confirmVerified(nodeId: ByteArray, fingerprintHex: String): ConfirmOutcome { commands += 1; boom() }
        override fun revoke(nodeId: ByteArray): RevokeOutcome { commands += 1; boom() }
        override fun beginWipe(): WipeProgressState { commands += 1; boom() }
        override fun resumeWipe(): WipeProgressState { commands += 1; boom() }
    }

    private fun nodeId(seed: Int): ByteArray = ByteArray(16) { ((it + seed) and 0xFF).toByte() }

    private fun candidate(seed: Int) = ExactRotationCandidateRef(
        nodeId = nodeId(seed),
        pendingGeneration = 1L,
        pendingStaticDhPublicKey = ByteArray(32) { (it + seed).toByte() },
    )

    private fun everyCommand(): List<ContactVerificationCommand> = listOf(
        ContactVerificationCommand.ShowOwnIdentity,
        ContactVerificationCommand.Refresh,
        ContactVerificationCommand.ClearError,
        ContactVerificationCommand.ImportRecipientBinding("payload"),
        ContactVerificationCommand.CompareAndConfirmFingerprint(nodeId(1), "ab"),
        ContactVerificationCommand.ApproveRotation(candidate(2)),
        ContactVerificationCommand.DismissRotation(candidate(3)),
        ContactVerificationCommand.Revoke(nodeId(4)),
        ContactVerificationCommand.BeginWipe,
        ContactVerificationCommand.ResumeWipe,
    )

    /**
     * *** THE ZERO-CALL ARM: WITH THE GATE CLOSED, NEITHER A PROJECTION NOR *ANY* COMMAND MAY REACH THE PORT. ***
     *
     * *This asserts ZERO, not "a refusal": a port that THROWS on every protected call makes "was it reached?" a question
     * the run itself answereth -- the arm would ERROR rather than merely fail if a port call escaped.*
     */
    @Test
    fun testGF009AUnavailableGateProvokethZeroProtectedReadsAndZeroCommands() {
        val gate = SwitchableGate(available = false)
        val port = RecordingPort()
        val vm = IdentityTrustViewModel(port = port, protectedData = gate)

        // (1) THE CONSTRUCTION ITSELF, and every projection road, must not read the port.
        assertEquals("*** CONSTRUCTION must not read the protected port ***", 0, port.protectedReads)
        vm.refresh()
        assertEquals(
            "*** `refresh()` must reach the gate FIRST and return WITHOUT reading the port ***",
            0, port.protectedReads,
        )

        // (2) AND EVERY COMMAND -- including the three that only re-project, which are covered by project()'s own gate.
        for (command in everyCommand()) {
            vm.onCommand(command)
        }
        assertEquals(
            "*** GS-FINAL-009: WITH THE GATE CLOSED NO COMMAND MAY REACH THE PORT. The audit: 'Inject an unavailable " +
                "gate and a port that records/throws on any protected read or command; zero calls must occur.' ***",
            0, port.commands,
        )
        assertEquals("*** AND NO PROTECTED READ MAY OCCUR EITHER ***", 0, port.protectedReads)
    }

    /**
     * *** AND THE POSITIVE CONTROL, WHICH IS WHAT MAKETH THE ARM ABOVE MEANINGFUL: WITH THE GATE OPEN THE SAME PORT IS
     * REACHED. *** *Without this, a view-model hardwired to refuse everything would satisfy the zero-call arm.*
     */
    @Test
    fun testGF009AnOpenGateReallyReachethThePort() {
        val port = RecordingPort()
        val vm = IdentityTrustViewModel(port = port, protectedData = SwitchableGate(available = true))

        // the port throws on read, so reaching it is observable as an exception rather than as a count.
        var reached = false
        try {
            vm.refresh()
        } catch (expected: IllegalStateException) {
            reached = true
        }
        assertTrue(
            "*** THE OPEN GATE MUST REALLY REACH THE PORT -- otherwise the zero-call arm above proves only that a " +
                "view-model can refuse everything. ***",
            reached,
        )
    }

    /**
     * *** AND THE FLAG IS NOT A LIE: WHEN THE GATE IS CLOSED THE PROJECTION SAYETH SO, AND CLAIMETH NOTHING IT DID NOT
     * READ. *** *The audit: "expose an explicit unavailable projection without invoking the port."*
     */
    @Test
    fun testGF009TheUnavailableProjectionIsExplicitAndClaimethNothing() {
        val port = RecordingPort()
        val vm = IdentityTrustViewModel(port = port, protectedData = SwitchableGate(available = false))
        // THE PROJECTION RUNS FIRST, deliberately: `uiState()` returneth `TrustUiState.EMPTY` until something projecteth
        // (*the state owner's own initial value*), so reading it cold would assert about `EMPTY` rather than about the
        // gate's answer. *This is the audit's road: "expose an explicit unavailable projection without invoking the
        // port" -- `refresh()` IS that projection.*
        val state = vm.refresh()
        assertEquals("and the projection itself read nothing", 0, port.protectedReads)

        assertFalse("the flag must tell the UI WHY the screen is bare", state.protectedDataAvailable)
        assertTrue("and it must claim no contacts it never read", state.contacts.isEmpty())
        assertTrue(
            "AND THE CENSUS MUST NAME THE REASON rather than resemble an empty authority",
            state.census is TrustCensus.Unavailable,
        )
    }
}
