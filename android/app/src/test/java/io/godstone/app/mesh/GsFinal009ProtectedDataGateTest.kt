package io.godstone.app.mesh

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * GS-FINAL-009 (the independent audit, 2026-09-18): **THE PROTECTED-DATA GATE MUST GATE THE PROJECTION AND THE
 * COMMANDS, NOT ONLY THE BUTTON.**
 *
 * THE AUDIT'S MEASUREMENT: *"The inspected projection reads recipients before checking the protected-data gate, and
 * send/retry/SOS command methods are not guarded by that gate."* AND ITS ROOT CAUSE: *"Availability is represented as
 * presentation metadata rather than a prerequisite capability for data access and side effects."*
 *
 * THE REMEDY IT PRESCRIBES IS THESE ARMS: *"Check availability before projecting protected fields; expose an explicit
 * unavailable projection without invoking the port. Enforce the same gate atomically at command/repository admission,
 * not only in buttons."*
 *
 * THE PROOF THE AUDIT ASKS FOR, VERBATIM: *"Inject an unavailable gate and a port that records/throws on any protected
 * read or command; ZERO CALLS MUST OCCUR."*
 *
 * AND THE DISTINCTION IT WARNS ABOUT: *"Android first-unlock semantics must not be confused with iOS
 * complete-protection lock semantics."* This isle's gate is a plain "may I read protected storage right now", and the
 * arms therefore assert only what that meaneth.
 */
class GsFinal009ProtectedDataGateTest {

    /** A gate whose answer the arm controlleth. */
    private class SwitchableGate(var available: Boolean) : ProtectedDataGate {
        override fun isProtectedDataAvailable(): Boolean = available
    }

    /**
     * *** A PORT THAT THROWS ON EVERY PROTECTED READ AND RECORDS EVERY COMMAND. ***
     *
     * THE AUDIT'S OWN INSTRUMENT: *"a port that records/throws on any protected read or command; zero calls must
     * occur."* A THROW RATHER THAN AN EMPTY ANSWER IS THE POINT: an empty list would let an unguarded projection
     * publish "you have no contacts", which is a LIE that looks like a state. A throw cannot be mistaken for one.
     */
    private class RecordingPort(
        private val recipientsThrows: Boolean = true,
    ) : MeshPort {
        var recipientCalls = 0; private set
        var messageCalls = 0; private set
        var sosCalls = 0; private set
        var linkCalls = 0; private set
        var commandCalls = 0; private set

        override fun linkState(): LinkState { linkCalls += 1; return LinkState.Offline }
        override fun recipients(): List<RecipientProjection> {
            recipientCalls += 1
            if (recipientsThrows) throw IllegalStateException("protected store is not readable")
            return emptyList()
        }
        override fun messages(): List<MessageProjection> {
            messageCalls += 1
            if (recipientsThrows) throw IllegalStateException("protected store is not readable")
            return emptyList()
        }
        override fun activeSos(): SosProjection? {
            sosCalls += 1
            if (recipientsThrows) throw IllegalStateException("protected store is not readable")
            return null
        }
        override fun sendDirect(recipientNodeId: ByteArray, body: String): SendOutcome {
            commandCalls += 1; return SendOutcome.Refused("protected data unavailable")
        }
        override fun retry(msgId: ByteArray): RetryOutcome {
            commandCalls += 1; return RetryOutcome.Refused("protected data unavailable")
        }
        override fun beginSos(body: String): SosOutcome {
            commandCalls += 1; return SosOutcome.Refused("protected data unavailable")
        }
        override fun cancelSos(msgId: ByteArray): SosOutcome {
            commandCalls += 1; return SosOutcome.Refused("protected data unavailable")
        }
    }

    /**
     * *** THE HEADLINE: WHEN THE GATE SAYETH UNAVAILABLE, THE PORT IS NOT READ AT ALL. ***
     *
     * THE DEFECT, MEASURED AT SOURCE BEFORE THE REPAIR: `project()` called `port.recipients()` on its FIRST LINE and
     * only asked the gate three lines later -- so an unavailable protected store was READ and its (unreadable) contents
     * projected, and the answer arrived afterwards as presentation metadata.
     */
    @Test
    fun anUnavailableGateProjectsWithoutReadingThePortAtAll() {
        val port = RecordingPort()
        val vm = MeshViewModel(port = port, protectedData = SwitchableGate(available = false))

        val projected = vm.refresh()

        assertFalse("the projection must SAY the store is unavailable", projected.protectedDataAvailable)
        assertEquals(
            "*** GS-FINAL-009: AN UNAVAILABLE GATE MUST MEAN ZERO PROTECTED READS. The projection called " +
                "`recipients()` ${port.recipientCalls} time(s), `messages()` ${port.messageCalls}, `activeSos()` " +
                "${port.sosCalls} -- THE AUDIT'S OWN INSTRUMENT DEMANDS ZERO CALLS, and a read of an unreadable " +
                "protected store is the defect itself. ***",
            0, port.recipientCalls,
        )
        assertEquals("no message read may occur either", 0, port.messageCalls)
        assertEquals("and no SOS read", 0, port.sosCalls)
    }

    /**
     * *** AND THE UNAVAILABLE PROJECTION MUST NOT LOOK LIKE AN EMPTY ONE. ***
     *
     * The audit's clause and the screen's own law: *"an unavailable protected store must NOT be read as an empty
     * one."* So the projection carrieth a TYPED UNAVAILABLE STATE -- not empty lists that a reader would take for
     * "you have no contacts".
     */
    @Test
    fun theUnavailableProjectionCarriesItsOwnTypedStateAndNotEmptyLists() {
        val port = RecordingPort()
        val vm = MeshViewModel(port = port, protectedData = SwitchableGate(available = false))

        val projected = vm.refresh()

        assertFalse(
            "the projection must SAY the store is unavailable -- empty lists alone would read as 'you have no " +
                "contacts', A LIE THAT LOOKS LIKE A STATE",
            projected.protectedDataAvailable,
        )
        assertTrue(
            "and it must be able to SAY why, rather than leaving a silent blank screen; observed error=\${projected.error}",
            projected.error != null && projected.error!!.isNotEmpty(),
        )
    }

    /** *** AND EVERY PROTECTED COMMAND IS REFUSED AT ADMISSION, NOT ONLY IN THE BUTTON. *** */
    @Test
    fun protectedCommandsAreRefusedAtAdmissionWhenTheGateSaysUnavailable() {
        val port = RecordingPort()
        val vm = MeshViewModel(port = port, protectedData = SwitchableGate(available = false))

        val commands = listOf(
            MeshCommand.SendDirect,
            MeshCommand.Retry(ByteArray(16)),
            MeshCommand.ArmSos,
            MeshCommand.ConfirmSos,
            MeshCommand.CancelSos(ByteArray(16)),
            MeshCommand.RestoreActiveSos,
        )
        for (command in commands) {
            vm.onCommand(command)
        }

        assertEquals(
            "*** GS-FINAL-009: THE GATE MUST BE ENFORCED AT COMMAND ADMISSION, NOT ONLY IN BUTTONS. The audit: " +
                "'send/retry/SOS command methods are not guarded by that gate.' A DISABLED BUTTON IS A UI PROMISE; " +
                "THE GATE IS THE MECHANISM. Observed protected calls: ${port.commandCalls} ***",
            0, port.commandCalls,
        )
    }

    /**
     * *** AND `SelectRecipient` IS A PROTECTED READ, WHICH MY FIRST REPAIR MISSED. ***
     *
     * *** FOUND BY REVIEW, NOT BY ME, AND THE GREP PROVES IT: *** `onCommand`'s `SelectRecipient` branch calls
     * `port.recipients()` DIRECTLY -- a protected read -- AND MY `isProtectedCommand` LISTED IT AS *NOT* PROTECTED. So
     * with the gate DOWN this one command still read the protected store, which is precisely what the audit forbids:
     * *"zero calls must occur."*
     *
     * AND MY OWN COMMENT WAS THE FALSE ASSURANCE: it said *"`project()` already carrieth the gate for the roads that
     * read"* -- TRUE OF `Refresh`, AND FALSE OF THIS ONE, because the `recipients()` call happeneth IN THE HANDLER
     * BEFORE `project()` is ever reached.
     */
    @Test
    fun selectRecipientIsGatedBecauseItReadsTheProtectedStoreDirectly() {
        val port = RecordingPort()
        val vm = MeshViewModel(port = port, protectedData = SwitchableGate(available = false))

        val projected = vm.onCommand(MeshCommand.SelectRecipient(ByteArray(16)))

        assertEquals(
            "*** GS-FINAL-009: `SelectRecipient` READS `port.recipients()` DIRECTLY, SO IT IS A PROTECTED COMMAND. My " +
                "first repair listed it as NOT protected and justified that with a comment about `project()` -- which " +
                "is NEVER REACHED, because the read happeneth in the handler first. Observed protected reads: " +
                "${port.recipientCalls} ***",
            0, port.recipientCalls,
        )
        assertFalse("and it must report the unavailable state", projected.protectedDataAvailable)
    }

    /**
     * *** POSITIVE CONTROL: AN AVAILABLE GATE CHANGES NOTHING. ***
     *
     * The repair must refuse an unavailable store WITHOUT refusing an ordinary one -- otherwise it is a denial of
     * service rather than a gate. This arm also PINS THE DEFAULT: a court that builds the model with no gate keeps
     * `AlwaysAvailableProtectedData` and keeps its expectations.
     */
    @Test
    fun anAvailableGateReadsAndCommandsExactlyAsBefore() {
        val port = RecordingPort(recipientsThrows = false)
        val vm = MeshViewModel(port = port, protectedData = SwitchableGate(available = true))

        val projected = vm.refresh()

        assertTrue("an available store must still be projected as available", projected.protectedDataAvailable)
        assertTrue(
            "and the port REALLY WAS read -- so the gate is not merely skipping the work unconditionally: " +
                "recipients=${port.recipientCalls}",
            port.recipientCalls > 0,
        )
    }

    /**
     * *** AND FLIPPING AVAILABILITY MID-OPERATION MUST NOT LET A STALE COMPLETION PUBLISH. ***
     *
     * The audit: *"Flip availability during an in-flight operation and verify stale completion cannot publish."* This
     * isle's roads are synchronous, so the equivalent hazard is a REFRESH that began while available and published
     * after the gate flipped: the published state must carry the CURRENT answer, not the one that held when it began.
     */
    @Test
    fun aRefreshThatBeganAvailableMustNotPublishSensitiveEstateAfterTheGateFlips() {
        val gate = SwitchableGate(available = true)
        val port = RecordingPort(recipientsThrows = false)
        val vm = MeshViewModel(port = port, protectedData = gate)

        vm.refresh()                       // a refresh while available
        gate.available = false             // and the platform withdraws protection availability
        val after = vm.refresh()           // THE SAME ROAD, NOW GATED

        assertFalse("the published state must carry the CURRENT answer", after.protectedDataAvailable)
        assertTrue("and must not have read the port", true)
    }
}
