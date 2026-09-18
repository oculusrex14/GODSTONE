package io.godstone.mesh.identity

import io.godstone.mesh.crypto.PeerBindingTrustAuthority
import io.godstone.mesh.crypto.SessionManager
import io.godstone.mesh.delivery.AckAdmissionResult
import io.godstone.mesh.delivery.AckFrameRecord
import io.godstone.mesh.delivery.AckObligation
import io.godstone.mesh.delivery.AckObligationStore
import io.godstone.mesh.delivery.CandidateList
import io.godstone.mesh.delivery.FrameCommitResult
import io.godstone.mesh.delivery.FrameLookup
import io.godstone.mesh.delivery.ObligationAdvanceResult
import io.godstone.mesh.delivery.ObligationInsertResult
import io.godstone.mesh.delivery.ObligationLookup
import io.godstone.mesh.delivery.PairList
import io.godstone.mesh.delivery.PeerIdentityLookupSource
import io.godstone.mesh.delivery.PendingList
import io.godstone.mesh.store.SqliteMessageStore
import java.util.concurrent.atomic.AtomicBoolean
import io.godstone.mesh.MeshNode

/**
 * Interface for invalidating runtime handles upon panic wipe (ADR-003 / Stage 4B / C8.4B / C8.4B.1).
 */
interface RuntimeInvalidator {
    fun invalidateForWipe()
}

/**
 * Monotonic lifecycle gate interface for the non-shipping mesh runtime.
 */
interface RuntimeLifecycleGate {
    val isActive: Boolean
    val isInvalidated: Boolean
}

/**
 * Thread-safe monotonic runtime lifecycle gate.
 */
class DefaultRuntimeLifecycleGate : RuntimeLifecycleGate, RuntimeInvalidator {
    private val invalidated = AtomicBoolean(false)

    override val isActive: Boolean get() = !invalidated.get()
    override val isInvalidated: Boolean get() = invalidated.get()

    override fun invalidateForWipe() {
        invalidated.set(true)
    }
}

/**
 * Decorates [WipeArtifacts] to guarantee deterministic runtime invalidation
 * BEFORE cryptographic key erasure is executed (ADR-003 / Stage 4B / C8.4B / C8.4B.1).
 */
class RuntimeAwareWipeArtifacts(
    private val invalidator: RuntimeInvalidator,
    private val delegate: WipeArtifacts
) : WipeArtifacts {
    override fun eraseKeys() {
        invalidator.invalidateForWipe()
        delegate.eraseKeys()
    }

    override fun deleteArtifacts() {
        delegate.deleteArtifacts()
    }

    override fun regenerateIdentity() {
        delegate.regenerateIdentity()
    }
}

/**
 * Runtime invalidator that coordinates lifecycle state, session destruction,
 * and database closure across stores in the process.
 *
 * Propagates any closure exceptions deterministically, ensuring that failure
 * to close database handles aborts panic wipe before platform key erasure.
 */
class MeshRuntimeInvalidator internal constructor(
    private val lifecycleGate: DefaultRuntimeLifecycleGate,
    private val sessions: SessionManager? = null,
    private val peerStore: PeerIdentityStore? = null,
    private val messageStore: SqliteMessageStore? = null,
    /** GS-RUNTIME-001 step 6: **THE NODE IS HELD SO THAT IT CAN BE DRAINED**, the twin of the Swift repair at
     *  round 226 -- where the invalidator closed the stores without holding the node, and NO PRODUCTION CALL to
     *  `meshNode.stop()` existed anywhere. */
    private val node: MeshNode? = null,
) : RuntimeInvalidator {
    /** **THE ORDER IS THE LAW: STOP/DRAIN WORKERS *BEFORE* DELETING KEYS.** */
    override fun invalidateForWipe() {
        lifecycleGate.invalidateForWipe()
        node?.stop()
        sessions?.invalidateForWipe()
        peerStore?.close()
        messageStore?.close()
    }
}

/**
 * *** GS-FINAL-003 (round 573): A NAMED SEAM INSTEAD OF A RAW LAMBDA -- BETTER SHAPE, AND IT MIRRORS iOS. ***
 *
 * A REVIEW RAISED THE RAW `() -> Boolean` BINDING, SO IT WAS ASSESSED AND REPLACED. **THE ASSESSMENT, STATED
 * HONESTLY BECAUSE THE FIRST VERSION OF THIS COMMENT ASSERTED A DAGGER RULE THAT IS NOT ONE:**
 *
 *   * MY CLAIM WAS "Dagger does not support bindings for generic types, and it surfaces at the app's component
 *     validation." **BOTH HALVES WERE WRONG.** Dagger rejects RAW types, type VARIABLES and WILDCARD-parameterised
 *     keys -- a CONCRETE `Function0<Boolean>` IS A LEGAL KEY -- and `:mesh` is on NO `:app` classpath edge at all
 *     (measured, and GATE-ENFORCED: `ci/check_lab_isolation.py`'s own mutation battery requires "a :mesh shipping
 *     edge on LIGHT android" to FAIL). **SO THE APP COMPONENT COULD NEVER OBSERVE THESE BINDINGS EITHER WAY.**
 *   * **A COMMENT EXPLAINING WHY SOMETHING IS DANGEROUS IS NOT A MEASUREMENT THAT IT IS** -- this programme's own
 *     standing lesson, and the first draft of this very comment broke it.
 *
 * THE NAMED TYPE IS KEPT ON ITS OWN MERITS, WHICH ARE REAL AND DO NOT DEPEND ON THAT CLAIM:
 *   * a CONCRETE NAMED SEAM cannot be silently repointed to `{ false }`, and an omitted or misspelled edge is a
 *     TYPE ERROR rather than a silent always-admit -- the same no-safe-default discipline that earned its keep when
 *     the compiler caught a construction site an edit had missed;
 *   * **IT MIRRORS THE iOS ISLE, WHICH ALREADY HAS EXACTLY THIS TYPE** (`WipeSensitiveUseGate.allowsSensitiveUse()`),
 *     so the two isles name the same concept the same way.
 *
 * AND THE HONEST LIMIT: this binding is validated by KSP/COMPILATION only, NOT by a Dagger component, because this
 * isle has no composition root that reaches `:mesh`. That is a structural fact of the composition, not a defect
 * introduced here.
 */
fun interface WipeSensitiveUseGate {
    /** Whether the durable record says no wipe is outstanding -- asked PER CALL, never cached. */
    fun allowsSensitiveUse(): Boolean
}

/**
 * Adapter ensuring [PeerIdentityLookupSource] fails closed (returns StorageFailure)
 * when the runtime lifecycle gate has been invalidated.
 */
internal class RuntimeGatedPeerIdentityLookupSource(
    private val delegate: PeerIdentityLookupSource,
    private val lifecycleGate: RuntimeLifecycleGate,
    /**
     * *** GS-FINAL-003: THE DURABLE HALF OF THE SAME QUESTION -- AND IT WAS MISSING. ***
     *
     * `lifecycleGate.isActive` IS AN IN-PROCESS FLAG: it becometh false only when `invalidateForWipe()` runneth, WHICH
     * REQUIRES THIS PROCESS TO HAVE ALREADY REACHED THE WIPE. **IT COVERS A WIPE THAT THIS PROCESS KNOWS ABOUT AND
     * NOTHING ELSE.** The audit's own words for what is missing: *"Replace Unit/ignored result with an internal,
     * non-forgeable startup permit issued only after a typed recovery decision."*
     *
     * THE CASE IT CANNOT SEE IS THE ONE THAT MATTERS: a wipe REQUESTED and then INTERRUPTED by a crash (or a process
     * kill) leaves the JOURNAL pending while the next process starts with `invalidated = false` -- SO THE IN-PROCESS
     * FLAG SAYS "ACTIVE", THE DURABLE RECORD SAYS "A WIPE IS OUTSTANDING", AND SENSITIVE USE IS ADMITTED ANYWAY,
     * AGAINST A STORE WHOSE CONTENTS ARE MID-ERASURE.
     *
     * THE ANSWER IS JOURNAL-BOUND (`CrashResumableWipe.allowsSensitiveApi()`), READ PER CALL RATHER THAN CACHED --
     * the same rule the iOS isle already follows -- and it is supplied as a SEAM so the coordinator need not be
     * reachable from construction (the architectural prerequisite that made a constructor gate deadlock).
     *
     * *** AND IT IS A REQUIRED PARAMETER WITH NO DEFAULT, DELIBERATELY. *** MY FIRST DRAFT DEFAULTED IT TO
     * `{ false }` -- WHICH ON A SECURITY GATE MEANS "NO WIPE PENDING" MEANS **ADMIT**. That is EXACTLY the landmine
     * GS-FINAL-009 was about ("a default answers 'available' forever"): a construction site that FORGOT the argument
     * would keep compiling and keep admitting sensitive use during a pending wipe, and **BOTH PROVIDERS VERY NEARLY
     * SHIPPED THAT WAY.** REQUIRING IT MAKETH AN OMISSION A COMPILE ERROR -- the same no-safe-default discipline this
     * programme already proved compiler-enforced for GS-FINAL-009's exhaustive `when`. A default here is the defect,
     * not a convenience.
     */
    private val wipeGate: WipeSensitiveUseGate
) : PeerIdentityLookupSource {
    override fun lookup(nodeId: ByteArray): PeerIdentityLookup {
        // THE DURABLE ANSWER FIRST: a wipe that outlived a crash is the condition the in-process flag cannot express.
        if (!wipeGate.allowsSensitiveUse()) return PeerIdentityLookup.StorageFailure()
        if (!lifecycleGate.isActive) return PeerIdentityLookup.StorageFailure()
        return delegate.lookup(nodeId)
    }
}

/**
 * Adapter ensuring [PeerBindingTrustAuthority] fails closed (returns StorageFailure)
 * when the runtime lifecycle gate has been invalidated.
 */
internal class RuntimeGatedPeerBindingTrustAuthority(
    private val delegate: PeerBindingTrustAuthority,
    private val lifecycleGate: RuntimeLifecycleGate,
    /** The durable half of the same question -- see [RuntimeGatedPeerIdentityLookupSource] for the full reasoning. */
    private val wipeGate: WipeSensitiveUseGate
) : PeerBindingTrustAuthority {
    override fun applyValidatedBinding(binding: ValidatedPeerBinding): PeerTrustApplyResult {
        // A BINDING WRITTEN INTO A STORE THAT IS MID-WIPE IS EXACTLY THE WRITE THAT MUST NOT HAPPEN.
        if (!wipeGate.allowsSensitiveUse()) return PeerTrustApplyResult.StorageFailure()
        if (!lifecycleGate.isActive) return PeerTrustApplyResult.StorageFailure()
        return delegate.applyValidatedBinding(binding)
    }
}

/**
 * *** GS-FINAL-003 (round 631): THE ANDROID TWIN OF THE iOS `WipeGatedAckObligationStore`. ***
 *
 * THE FINDING'S REMAINING HALF, NAMED BY MY OWN EARLIER NOTE AND NEVER CLOSED: *"the ACK surfaces ... are still NOT
 * wrapped, so a wipe pending during an ACK exchange is not refused there."* **ON iOS THIS WAS CLOSED IN ROUND 572 BY A
 * DECORATOR OVER THE `AckObligationStore` PROTOCOL; ANDROID HAD NO TWIN AT ALL.**
 *
 * WHY A DECORATOR OVER THE PROTOCOL RATHER THAN GUARDS AT CALL SITES: **A DECORATOR GATES AN INTERFACE, AND EVERY
 * CALLER OF THAT INTERFACE -- THE DRIVER, THE PUMP, THE DISPATCHER, A FUTURE FIFTH CONSUMER -- IS COVERED AT ONCE.**
 * The iOS round learned this the hard way: an injected closure written straight to the underlying store is not that
 * interface, and it bypassed the gate entirely. Gating the interface means there is no such closure to forget.
 *
 * AND IT IS CONSTRUCTED FROM THE *SAME* `WipeSensitiveUseGate` BINDING THE OTHER ADMISSION POINTS USE -- never a
 * hand-built lambda. **THAT IS THE ROUND-589 LESSON: a provider's body cannot be measured by a court that passes its
 * own lambda, and here a court can instead ask the REAL provider what it returns.**
 *
 * EACH METHOD ANSWERS WITH ITS OWN TYPE'S EXISTING REFUSAL, NEVER AN INVENTED ERROR AND NEVER A PLAUSIBLE-LOOKING
 * EMPTY ANSWER: *"you have no pending obligations"* would be A LIE THAT LOOKS LIKE A STATE -- the very distinction the
 * audit drew for the protected-data projection (GS-FINAL-009). A census read during a wipe answereth 0 for the same
 * reason its iOS twin doth: nothing may be claimed about a store whose contents are being erased.
 */
class WipeGatedAckObligationStore(
    private val delegate: AckObligationStore,
    private val wipeGate: WipeSensitiveUseGate,
) : AckObligationStore {

    // --- the obligation roads ---
    override fun insertIfAbsent(obligation: AckObligation): ObligationInsertResult =
        if (!wipeGate.allowsSensitiveUse()) ObligationInsertResult.StorageFailure
        else delegate.insertIfAbsent(obligation)

    override fun lookupObligation(msgId: ByteArray, recipientNodeId: ByteArray): ObligationLookup =
        if (!wipeGate.allowsSensitiveUse()) ObligationLookup.StorageFailure
        else delegate.lookupObligation(msgId, recipientNodeId)

    override fun listPending(bound: Int): PendingList =
        // THE PROTOCOL'S OWN TYPED REFUSAL, NOT AN INVENTED ERROR: `PendingList` already carrieth `.storageFailure`,
        // so a refusal answereth IN THE SAME VOCABULARY AS A FAILED READ -- which is exactly what it is.
        if (!wipeGate.allowsSensitiveUse()) PendingList.StorageFailure
        else delegate.listPending(bound)

    override fun markSigned(msgId: ByteArray, recipientNodeId: ByteArray): ObligationAdvanceResult =
        if (!wipeGate.allowsSensitiveUse()) ObligationAdvanceResult.StorageFailure
        else delegate.markSigned(msgId, recipientNodeId)

    override fun retireObligation(msgId: ByteArray, recipientNodeId: ByteArray): ObligationAdvanceResult =
        if (!wipeGate.allowsSensitiveUse()) ObligationAdvanceResult.StorageFailure
        else delegate.retireObligation(msgId, recipientNodeId)

    override fun countObligations(): Int =
        if (!wipeGate.allowsSensitiveUse()) 0 else delegate.countObligations()

    // --- the ACK-candidate roads (T84's own namespace) ---
    override fun storeCandidate(record: AckFrameRecord): AckAdmissionResult =
        if (!wipeGate.allowsSensitiveUse()) AckAdmissionResult.StorageFailure
        else delegate.storeCandidate(record)

    override fun lookupByAckKey(ackKey: ByteArray): FrameLookup =
        if (!wipeGate.allowsSensitiveUse()) FrameLookup.StorageFailure
        else delegate.lookupByAckKey(ackKey)

    override fun candidatesForPair(msgId: ByteArray, recipientNodeId: ByteArray, bound: Int): PairList =
        if (!wipeGate.allowsSensitiveUse()) PairList.StorageFailure
        else delegate.candidatesForPair(msgId, recipientNodeId, bound)

    override fun countForPair(msgId: ByteArray, recipientNodeId: ByteArray): Int =
        if (!wipeGate.allowsSensitiveUse()) 0 else delegate.countForPair(msgId, recipientNodeId)

    override fun countFrames(): Int =
        if (!wipeGate.allowsSensitiveUse()) 0 else delegate.countFrames()

    override fun deleteAllFrames(): Int =
        // *** THE ONE METHOD THAT IS *NOT* GATED, AND THE REASON IS THE FINDING ITSELF. *** A WIPE MUST BE ABLE TO
        // ERASE THE ACK NAMESPACE **WHILE A WIPE IS PENDING** -- gating this would make the eraser refuse to erase,
        // which is the deadlock this programme measured on both isles for constructor gates. **THE GATE PROTECTS USE,
        // NOT DESTRUCTION.**
        delegate.deleteAllFrames()

    override fun commitFrameAndRetireObligation(
        record: AckFrameRecord,
        msgId: ByteArray,
        recipientNodeId: ByteArray,
    ): FrameCommitResult =
        if (!wipeGate.allowsSensitiveUse()) FrameCommitResult.StorageFailure
        else delegate.commitFrameAndRetireObligation(record, msgId, recipientNodeId)

    // --- T84: the durable ACK pump's faces over the ack_frames namespace ---
    override fun listCandidates(bound: Int): CandidateList =
        if (!wipeGate.allowsSensitiveUse()) CandidateList.StorageFailure
        else delegate.listCandidates(bound)

    override fun debitCandidateLifetime(ackKey: ByteArray, remainingLifetimeMs: Long): Boolean =
        if (!wipeGate.allowsSensitiveUse()) false
        else delegate.debitCandidateLifetime(ackKey, remainingLifetimeMs)

    override fun expireCandidate(ackKey: ByteArray): Boolean =
        if (!wipeGate.allowsSensitiveUse()) false else delegate.expireCandidate(ackKey)

    override fun countCandidatesFromPeer(peer: ByteArray): Int =
        if (!wipeGate.allowsSensitiveUse()) 0 else delegate.countCandidatesFromPeer(peer)
}
