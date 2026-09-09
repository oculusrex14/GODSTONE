package io.godstone.mesh.transport

import java.util.ArrayList
import java.util.LinkedHashMap

/**
 * T11: the bounded discovery surface shared by the scan path.
 *
 * A plain map keyed by peer address over-accepts an arbitrary number of
 * advertisers; a flood of distinct advertisements then holds memory without
 * ever releasing it, and an entry of a peer that is currently active may be
 * lost together with the stale ones. This index applies the discovered-peer
 * bound before inserting any record: when the surface is full, the least
 * recently observed entries that do not hold an active relation are evicted
 * first, deterministically, in observation order. Entries of active
 * relations are pinned by the caller-provided predicate and are never
 * evicted; if every entry is pinned, a newcomer is expelled instead
 * (the intruder is the most recent observation, so the pinned history stays
 * authoritative and the bound still holds). Re-observation moves an entry to
 * the end of the order, so recency is the last observation, not the first.
 *
 * The class is deliberately free of synchronisation: it is a plain memory of
 * the transport, and every caller reduces it under its own lock (the
 * transport scan gate, or the orchestration driver lock), which keeps the
 * locking discipline at the platform boundaries intact.
 */
class BoundedDiscoveryIndex<V : Any>(
    val capacity: Int,
    private val isPinned: (String) -> Boolean = { false }
) {

    private val order = LinkedHashMap<String, V>()

    init {
        if (capacity <= 0) {
            throw IllegalArgumentException("the discovered-peer bound must be positive")
        }
    }

    /** Insert or refresh the record of one peer address and restore the bound. */
    fun observe(address: String, value: V) {
        order.remove(address)
        order[address] = value
        enforceBound()
    }

    /** Drop the record of one peer address; returns the released value or null. */
    fun release(address: String): V? = order.remove(address)

    /** Release every record of the surface. */
    fun releaseAll() {
        order.clear()
    }

    fun contains(address: String): Boolean = order.containsKey(address)

    fun valueOf(address: String): V? = order[address]

    val size: Int
        get() = order.size

    /** The current observation order, least recently observed first. */
    fun addresses(): List<String> = order.keys.toList()

    /**
     * Restore the bound after an insertion. Eviction is deterministic: the
     * walk starts at the least recently observed entry and only unpinned
     * entries leave the surface.
     */
    private fun enforceBound() {
        if (order.size <= capacity) {
            return
        }
        val victims = ArrayList<String>()
        for (address in order.keys) {
            if (order.size - victims.size <= capacity) {
                break
            }
            if (!isPinned(address)) {
                victims.add(address)
            }
        }
        for (victim in victims) {
            order.remove(victim)
        }
        while (order.size > capacity) {
            var expelled = false
            for (address in order.keys) {
                if (!isPinned(address)) {
                    order.remove(address)
                    expelled = true
                    break
                }
            }
            if (!expelled) {
                var intruder: String? = null
                for (address in order.keys) {
                    intruder = address
                }
                if (intruder == null) {
                    break
                }
                order.remove(intruder)
            }
        }
    }
}

/** A record of the transport discovery surface: metadata and signal, kept together. */
class BleDiscoveryRecord(
    var metadata: BleLinkInfoV1? = null,
    var rssi: Int? = null
) {
    /** Refresh only the fields present in this observation; absent fields stay as they were. */
    fun absorb(incomingMetadata: BleLinkInfoV1?, incomingRssi: Int?) {
        if (incomingMetadata != null) {
            metadata = incomingMetadata
        }
        if (incomingRssi != null) {
            rssi = incomingRssi
        }
    }
}

/** A record of the orchestration driver discovery caches: hint and signal, kept together. */
class DriverScanRecord(
    var hint: ByteArray? = null,
    var rssi: Int? = null
) {
    fun absorb(incomingHint: ByteArray?, incomingRssi: Int?) {
        if (incomingHint != null) {
            hint = incomingHint
        }
        if (incomingRssi != null) {
            rssi = incomingRssi
        }
    }
}
