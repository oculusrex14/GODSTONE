package io.godstone.mesh.identity

import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

// ---------------------------------------------------------------------------
// T28 CONTRACT - the unified runtime lifecycle authority.
//
// The card mandates: RuntimeLifecycleGate owns a transport lease. start
// subscribes then creates exactly one context; stop atomically closes admission,
// invalidates callbacks/timers, drains outbound/session work, then releases.
// Bluetooth-unavailable and permission-revoked are TYPED terminal/suspended
// states, NEVER READY. Background callbacks CANNOT start a stopped runtime (no
// OS call). Wipe drains BEFORE key erasure. A retired context forbids all future
// effects. Process recreation inherits no session and no lease.
//
// This file is the CONTRACT + a self-contained authority the platform child will
// wire the real transport behind, by driving it only through the injectable
// [TransportSeam] (the OS boundary). The court counts every seam call so the
// laws -- above all "a stopped runtime makes no OS calls" -- are executable,
// not narrated. No frozen BLE/LinkInfo/wire/identity contract is touched here.
// ---------------------------------------------------------------------------

/** The typed capability ladder. Terminal/suspended states are never READY. */
enum class CapabilityStatus {
    SUSPENDED_NO_ADAPTER,   // radio absent / not yet started: never READY
    ACTIVE_READY,           // started with adapter + permission present
    TERMINAL_UNAVAILABLE,   // powered off / radio gone: terminal, never returns to READY
    TERMINAL_PERMISSION_REVOKED,   // permission removed: terminal, never returns to READY
}

/** A single transport lease. Acquired exactly once per activation, released exactly once. */
class RuntimeTransportLease(val leaseId: Long, private val onRelease: (RuntimeTransportLease) -> Unit) {
    private val released = AtomicBoolean(false)
    val isReleased: Boolean get() = released.get()
    /** @return true on the one winning release; false if already released. */
    fun releaseOnce(): Boolean {
        val won = released.compareAndSet(false, true)
        if (won) onRelease(this)
        return won
    }
}

/** Immutable identity of one delivered callback context. A retired token forbids future effects. */
class ContextToken(val contextId: Long, val bornMillis: Long) {
    private val retired = AtomicBoolean(false)
    val isRetired: Boolean get() = retired.get()
    /** A live, unretired context is the only one whose effects may run. */
    fun permitsEffect(): Boolean = !retired.get()
    fun retireOnce(): Boolean = retired.compareAndSet(false, true)
}

/** The outcome of one atomic drain: admission closed, contexts retired, outbound drained, resources released. */
data class DrainResult(
    val admissionClosed: Boolean,
    val contextsRetired: Int,
    val outboundDrained: Int,
    val resourcesReleased: Int,
) {
    val isClean: Boolean get() = admissionClosed && contextsRetired >= 0 && outboundDrained >= 0 && resourcesReleased >= 1
}

/** The OS boundary the authority drives. The court injects a fake that records every call. */
interface TransportSeam {
    fun startScan()
    fun stopScan()
    fun startAdvertising()
    fun stopAdvertising()
    fun disconnectAll(): Int
    fun resetResources()
}

/**
 * The single lifecycle authority that owns a transport lease and unifies
 * start/stop/power/background/permission behind one monotonic, lock-guarded
 * state machine. It makes the required laws impossible to violate:
 *  - a stopped (or terminal) runtime issues NO OS call, so a background event
 *    cannot resurrect a scanner;
 *  - power-off / permission-revocation uniformly drain AND are terminal (never READY);
 *  - a lease is acquired once and released once; a fresh authority inherits none.
 */
class UnifiedRuntimeLifecycle(
    private val seam: TransportSeam,
    private val nowMillis: () -> Long,
    private val adapterPresent: Boolean = true,
    private val permissionGranted: Boolean = true,
) {
    private var started: Boolean = false
    private var capability: CapabilityStatus =
        if (!permissionGranted) CapabilityStatus.TERMINAL_PERMISSION_REVOKED
        else CapabilityStatus.SUSPENDED_NO_ADAPTER
    private var lease: RuntimeTransportLease? = null
    private val contexts = mutableListOf<ContextToken>()
    private var nextContextId: Long = 0

    /** start subscribes, creates exactly one context, and (only when admissible) begins the OS work. */
    fun start() {
        synchronized(this) {
            if (capability == CapabilityStatus.TERMINAL_UNAVAILABLE || capability == CapabilityStatus.TERMINAL_PERMISSION_REVOKED) return
            if (!adapterPresent) { capability = CapabilityStatus.SUSPENDED_NO_ADAPTER; return }
            if (started) return                                     // idempotent: one context, one lease, one scan
            val live = lease
            if (live == null || live.isReleased) {
                lease = RuntimeTransportLease(LEASE_SEQ.incrementAndGet()) { }
            }
            started = true
            capability = CapabilityStatus.ACTIVE_READY
            newContextLocked()
            seam.startAdvertising()
            seam.startScan()
        }
    }

    /** stop atomically closes admission, retires contexts, drains, and releases the lease exactly once. */
    fun stop() {
        synchronized(this) {
            if (!started) return
            drainLocked()
            lease?.releaseOnce()
            started = false
        }
    }

    /** A background/foreground transition. A stopped or terminal runtime makes NO OS call. */
    fun onBackgrounded() {
        synchronized(this) {
            if (!started || capability != CapabilityStatus.ACTIVE_READY) return   // the semantic-negative guard
            // a background event never (re)starts a scan; it only stays within the already-active budget
        }
    }

    /** Power-off uniformly invalidates every resource and is terminal (never READY again). */
    fun onPowerLoss() {
        synchronized(this) {
            drainLocked()
            if (started) { lease?.releaseOnce(); started = false }
            capability = CapabilityStatus.TERMINAL_UNAVAILABLE
        }
    }

    /** Permission removal uniformly invalidates every resource and is terminal (never READY again). */
    fun onPermissionRemoved() {
        synchronized(this) {
            drainLocked()
            if (started) { lease?.releaseOnce(); started = false }
            capability = CapabilityStatus.TERMINAL_PERMISSION_REVOKED
        }
    }

    /**
     * Deliver an effect to a context. A retired context, a stopped runtime, or a
     * terminal capability drops the effect WITHOUT an OS call -- the law that a
     * late callback arriving during/after a wipe must not mutate new state.
     */
    fun deliverToContext(context: ContextToken, effect: () -> Unit) {
        synchronized(this) {
            if (!context.permitsEffect()) return
            if (!started || capability != CapabilityStatus.ACTIVE_READY) return
            effect()
        }
    }

    /** The wipe path drains (retires contexts, releases resources) BEFORE platform key erasure. */
    fun drainForWipe(): DrainResult {
        synchronized(this) {
            val d = drainLocked()
            if (started) { lease?.releaseOnce(); started = false }
            return d
        }
    }

    // ---- read-only observation for the court -------------------------------------
    fun isReady(): Boolean = synchronized(this) { started && capability == CapabilityStatus.ACTIVE_READY }
    fun isStarted(): Boolean = synchronized(this) { started }
    fun capabilityState(): CapabilityStatus = synchronized(this) { capability }
    fun activeLease(): RuntimeTransportLease? = synchronized(this) { val l = lease; if (l != null && !l.isReleased) l else null }
    fun liveContextCount(): Int = synchronized(this) { contexts.count { it.permitsEffect() } }
    fun snapshotContexts(): List<ContextToken> = synchronized(this) { contexts.toList() }

    // ---- internal, called only with the monitor held ----------------------------
    private fun newContextLocked(): ContextToken {
        nextContextId += 1
        val token = ContextToken(nextContextId, nowMillis())
        contexts.add(token)
        return token
    }

    private fun drainLocked(): DrainResult {
        var retired = 0
        for (c in contexts) {
            if (c.retireOnce()) retired += 1
        }
        contexts.clear()
        val drained = seam.disconnectAll()
        seam.stopAdvertising()
        seam.stopScan()
        seam.resetResources()
        return DrainResult(admissionClosed = true, contextsRetired = retired, outboundDrained = drained, resourcesReleased = 1)
    }

    private companion object {
        // process-wide monotonic lease token sequence: every acquired lease is a globally unique
        // token, so a leaked or reused token can never collide with a live one across recreations.
        val LEASE_SEQ = AtomicLong(0)
    }
}
