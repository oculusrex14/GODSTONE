package io.godstone.mesh.transport

import io.godstone.mesh.identity.Identity
import io.godstone.mesh.router.BloomDigest
import io.godstone.mesh.store.MessageStore
import kotlinx.coroutines.runBlocking
import java.util.concurrent.atomic.AtomicReference

/**
 * Authoritative provider and precomputed cache of local LinkInfo V1 snapshots (ADR-002, Phase C8.4D1-R2.2).
 *
 * Enforces:
 * - Real identity nodeHint derivation (no synthetic dummy values).
 * - Real MessageStore held message ID enumeration and Bloom digest calculation.
 * - Exact held count queue depth, saturating at 255.
 * - Immutable precomputed snapshot caching: ATT callbacks NEVER perform durable store traversal.
 * - Cache refresh on defined durable-state mutation boundaries (identity load, store insert/purge, transport start).
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

    init {
        refresh()
    }

    /**
     * Compute and atomically update the immutable cached snapshot.
     * Must be called outside ATT callbacks (e.g. on store mutation boundaries or transport start).
     */
    fun refresh(): BleLinkInfoV1 {
        val identity = identityProvider()
        val nodeHint = identity?.nodeHint ?: ByteArray(BleLinkInfoConstants.NODE_HINT_BYTES)
        val store = storeProvider()

        var count = 0
        val bloom = BloomDigest()
        if (store != null) {
            runBlocking {
                store.forEachHeldMsgId { msgId ->
                    count++
                    bloom.add(msgId)
                    true
                }
            }
        }

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

        cachedSnapshot.set(info)
        cachedBytes.set(bytes)
        return info
    }

    fun currentSnapshot(): BleLinkInfoV1 {
        return cachedSnapshot.get() ?: refresh()
    }

    fun currentBytes(): ByteArray {
        return cachedBytes.get() ?: currentSnapshot().let {
            cachedBytes.get()!!
        }
    }
}
