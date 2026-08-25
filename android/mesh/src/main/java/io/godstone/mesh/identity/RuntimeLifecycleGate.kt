package io.godstone.mesh.identity

import io.godstone.mesh.crypto.PeerBindingTrustAuthority
import io.godstone.mesh.crypto.SessionManager
import io.godstone.mesh.delivery.PeerIdentityLookupSource
import io.godstone.mesh.store.SqliteMessageStore
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Interface for invalidating runtime handles upon panic wipe (ADR-003 / Stage 4B / C8.4B).
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
 * BEFORE cryptographic key erasure is executed (ADR-003 / Stage 4B / C8.4B).
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
 */
class MeshRuntimeInvalidator internal constructor(
    private val lifecycleGate: DefaultRuntimeLifecycleGate,
    private val sessions: SessionManager? = null,
    private val peerStore: PeerIdentityStore? = null,
    private val messageStore: SqliteMessageStore? = null
) : RuntimeInvalidator {
    override fun invalidateForWipe() {
        lifecycleGate.invalidateForWipe()
        sessions?.invalidateForWipe()
        try {
            peerStore?.close()
        } catch (_: Exception) {}
        try {
            messageStore?.close()
        } catch (_: Exception) {}
    }
}

/**
 * Adapter ensuring [PeerIdentityLookupSource] fails closed (returns StorageFailure)
 * when the runtime lifecycle gate has been invalidated.
 */
internal class RuntimeGatedPeerIdentityLookupSource(
    private val delegate: PeerIdentityLookupSource,
    private val lifecycleGate: RuntimeLifecycleGate
) : PeerIdentityLookupSource {
    override fun lookup(nodeId: ByteArray): PeerIdentityLookup {
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
    private val lifecycleGate: RuntimeLifecycleGate
) : PeerBindingTrustAuthority {
    override fun applyValidatedBinding(binding: ValidatedPeerBinding): PeerTrustApplyResult {
        if (!lifecycleGate.isActive) return PeerTrustApplyResult.StorageFailure()
        return delegate.applyValidatedBinding(binding)
    }
}
