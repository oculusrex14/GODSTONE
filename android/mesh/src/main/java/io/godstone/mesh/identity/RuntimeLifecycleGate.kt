package io.godstone.mesh.identity

import io.godstone.mesh.crypto.PeerBindingTrustAuthority
import io.godstone.mesh.crypto.SessionManager
import io.godstone.mesh.delivery.PeerIdentityLookupSource
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
    private val wipeIsPending: () -> Boolean
) : PeerIdentityLookupSource {
    override fun lookup(nodeId: ByteArray): PeerIdentityLookup {
        // THE DURABLE ANSWER FIRST: a wipe that outlived a crash is the condition the in-process flag cannot express.
        if (wipeIsPending()) return PeerIdentityLookup.StorageFailure()
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
    private val wipeIsPending: () -> Boolean
) : PeerBindingTrustAuthority {
    override fun applyValidatedBinding(binding: ValidatedPeerBinding): PeerTrustApplyResult {
        // A BINDING WRITTEN INTO A STORE THAT IS MID-WIPE IS EXACTLY THE WRITE THAT MUST NOT HAPPEN.
        if (wipeIsPending()) return PeerTrustApplyResult.StorageFailure()
        if (!lifecycleGate.isActive) return PeerTrustApplyResult.StorageFailure()
        return delegate.applyValidatedBinding(binding)
    }
}
