package io.godstone.mesh.transport

import io.godstone.mesh.identity.Identity
import io.godstone.mesh.router.BloomDigest
import io.godstone.mesh.store.MessageStore
import kotlinx.coroutines.runBlocking
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

/**
 * Authoritative provider and precomputed cache of local LinkInfo V1 snapshots (ADR-002, Phase C8.4D1-R2.3).
 *
 * Enforces:
 * - Real identity nodeHint derivation (no synthetic dummy values). Fails closed (null) if identity is absent.
 * - Real MessageStore held message ID enumeration and Bloom digest calculation. Fails closed (null) if store is absent.
 * - Canonical empty digest and queue depth 0 when store is real and empty.
 * - Exact held count queue depth, saturating at 255.
 * - Immutable precomputed snapshot caching: ATT callbacks NEVER perform durable store traversal.
 * - Automatic cache refresh on MessageStore mutation events without requiring manual caller invocation.
 *
 * T25 platform layer (subscription-owned, nonblocking reads):
 * - The held-set digest/queue-depth are computed on the store's post-commit notify path (the store
 *   notifies ONLY after `inTransaction` commits, on the committing thread) and published ATOMICALLY as an
 *   immutable [HeldSnapshot] carrying a monotonic generation [storeVersion]; a stale compute never
 *   overwrites a newer one (revalidate-before-publish).
 * - The GATT read path ([currentSnapshot]/[currentBytes]/[currentHeldSnapshot]) is a PURE cached copy:
 *   it NEVER traverses the store, so a blocked/erroring store cannot stall an ATT read.
 * - A storage failure DURING traversal is SURFACED (kept in [lastStorageFailureForTest]) and the PRIOR
 *   committed snapshot is RETAINEd -- a failed store is never fabricated as an empty one.
 * - Exactly one observation lease is owned per runtime ([startObserving]/[stopObserving]); the store's
 *   registry is grow-only, so the lease is a GATE -- a closed lease makes the single registration inert
 *   (no recompute), and re-opening reuses that same one registration (never a second).
 */
class LinkInfoSnapshotAuthority(
    private val identityProvider: () -> Identity? = { null },
    private val storeProvider: () -> MessageStore? = { null },
    private val powerStateProvider: () -> PowerState = { PowerState.NORMAL },
    private val sosPresentProvider: () -> Boolean = { false },
    private val clockUntrustedProvider: () -> Boolean = { false }
) {
    private val cachedSnapshot = AtomicReference<BleLinkInfoV1?>(null)
    private val cachedBytes = AtomicReference<ByteArray?>(null)
    private val published = AtomicReference<HeldSnapshot?>(null)

    // Post-commit generation token; a compute captures it and may publish only while unchanged.
    private val generation = AtomicLong(0L)
    // Bounded reentrancy guard: a nested notify during an in-flight compute marks a re-run, never a nest.
    private val computing = AtomicBoolean(false)
    private val rerun = AtomicBoolean(false)
    // The single owned observation lease (born active) + the grow-only store registration it gates.
    private val observing = AtomicReference<SnapshotObservationLease>(SnapshotObservationLease())
    private val registeredStoreRef = AtomicReference<MessageStore?>(null)
    private val registrations = AtomicInteger(0)
    // A traversal failure is surfaced, never fabricated as an empty store.
    private val lastFailure = AtomicReference<Throwable?>(null)

    init {
        attachStoreObserver()
        refresh()
    }

    private fun attachStoreObserver() {
        val store = storeProvider() ?: return
        val current = registeredStoreRef.get()
        if (current === store) return
        if (registeredStoreRef.compareAndSet(current, store)) {
            registrations.incrementAndGet()
            store.registerHeldSetObserver { onHeldSetChanged() }
        }
    }

    // The store fires this on the COMMITTING thread, after `inTransaction` committed. Gated by the lease.
    private fun onHeldSetChanged() {
        if (!observing.get().isActive) return
        generation.incrementAndGet()
        requestCompute()
    }

    /** Open the single owned observation lease (idempotent); ensure the one registration exists. */
    fun startObserving() {
        if (!observing.get().isActive) observing.set(SnapshotObservationLease())
        attachStoreObserver()
    }

    /** Close the owned lease: the single registration becomes inert (no recompute) until re-opened. */
    fun stopObserving() {
        observing.get().close()
    }

    fun isObserving(): Boolean = observing.get().isActive

    internal fun isObservingForTest(): Boolean = observing.get().isActive
    internal fun registrationsForTest(): Int = registrations.get()
    internal fun lastStorageFailureForTest(): Throwable? = lastFailure.get()

    /**
     * Compute and atomically update the immutable cached snapshot.
     * Fails closed (returns null) if identity or store authority is missing.
     * Must be called outside ATT callbacks (e.g. on store mutation boundaries or transport start).
     * The explicit command path always recomputes (it is a command, not the gated observation).
     */
    fun refresh(): BleLinkInfoV1? {
        attachStoreObserver()
        generation.incrementAndGet()
        requestCompute()
        return currentSnapshot()
    }

    private fun requestCompute() {
        if (!computing.compareAndSet(false, true)) {
            rerun.set(true)   // reentrant notify observed; the in-flight loop will re-run once (bounded)
            return
        }
        try {
            var guard = 0
            do {
                rerun.set(false)
                doCompute()
            } while (rerun.get() && ++guard < 8)
        } finally {
            computing.set(false)
        }
    }

    private fun doCompute() {
        // Capture the token BEFORE the traversal, so a commit that supervenes during the
        // traversal (a reentrant notify) advances `generation` and this compute's result is
        // recognised as stale and DROPPED at the revalidate gate -- the latest then wins.
        val token = generation.get()
        val identity = identityProvider()
        val store = storeProvider()

        if (identity == null || identity.nodeHint.size != BleLinkInfoConstants.NODE_HINT_BYTES || store == null) {
            cachedSnapshot.set(null)
            cachedBytes.set(null)
            published.set(null)
            lastFailure.set(null)
            return
        }

        val nodeHint = identity.nodeHint
        var count = 0
        val bloom = BloomDigest()
        try {
            runBlocking(kotlinx.coroutines.Dispatchers.IO) {
                store.forEachHeldMsgId { msgId ->
                    count++
                    bloom.add(msgId)
                    true
                }
            }
        } catch (t: Throwable) {
            // SURFACE the failure; RETAIN the prior committed snapshot -- never fabricate an empty store.
            lastFailure.set(t)
            return
        }
        lastFailure.set(null)

        val queueDepth = minOf(count, 255)
        val shortDigest = bloom.toBytes().copyOf(BleLinkInfoConstants.SHORT_DIGEST_BYTES)

        var flags = 0
        if (sosPresentProvider() || powerStateProvider() == PowerState.SOS_ACTIVE) {
            flags = flags or BleLinkInfoConstants.FLAG_SOS_PRESENT
        }
        if (clockUntrustedProvider()) {
            flags = flags or BleLinkInfoConstants.FLAG_CLOCK_UNTRUSTED
        }
        if (powerStateProvider() == PowerState.CRITICAL) {
            flags = flags or BleLinkInfoConstants.FLAG_POWER_CONSTRAINED
        }

        val info = BleLinkInfoV1(
            version = BleLinkInfoConstants.PROTOCOL_VERSION,
            flags = flags.toByte(),
            nodeHint = nodeHint,
            shortDigest = shortDigest,
            queueDepth = queueDepth
        )
        val bytes = BleLinkInfoCodec.encode(
            version = info.version,
            flags = info.flags,
            nodeHint = info.nodeHint,
            shortDigest = info.shortDigest,
            queueDepth = info.queueDepth
        )
        val snapshot = HeldSnapshot(
            storeVersion = token,
            hint4 = nodeHint,
            digest6 = shortDigest,
            queueDepth = queueDepth,
        )
        // revalidate-before-publish: publish only if no newer committed event supervened the token.
        if (generation.get() == token) {
            published.set(snapshot)
            cachedSnapshot.set(info)
            cachedBytes.set(bytes)
        }
    }

    /**
     * Pure cached read. Returns null (fail-closed) if snapshot has not been precomputed.
     * ATT read callbacks MUST use this — never triggers durable store traversal.
     */
    fun currentSnapshot(): BleLinkInfoV1? {
        return cachedSnapshot.get()
    }

    /**
     * Pure cached read. Returns null (fail-closed) if bytes have not been precomputed.
     * ATT read callbacks MUST use this — never triggers durable store traversal.
     */
    fun currentBytes(): ByteArray? {
        return cachedBytes.get()
    }

    /** Pure cached read of the last committed immutable [HeldSnapshot]; never traverses the store. */
    fun currentHeldSnapshot(): HeldSnapshot? {
        return published.get()
    }
}
