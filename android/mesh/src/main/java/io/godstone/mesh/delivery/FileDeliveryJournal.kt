package io.godstone.mesh.delivery

import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.util.Properties

// Stage 3 Phase H -- a real durable DeliveryJournal backed by a Properties file.
// Used in production (Application Support dir) and in the reboot-recovery test
// (a temp file reopened by a fresh tracker), so the persistence path that CI
// exercises is the persistence path production uses.

/**
 * File-backed [DeliveryJournal]: key = hex(msgId), value = state name. The whole
 * map is rewritten on every mutation (the tracked set is bounded by the store's
 * hard cap), and read fresh on every [read] from the in-memory cache that is
 * loaded once at construction and kept in sync. Survives a process restart
 * (reboot/jetsam) so a fresh [DeliveryTracker] over the same file recovers
 * state -- the ADR-005 reboot-recovery exit criterion, proven host-side by
 * reopening the file.
 */
class FileDeliveryJournal(private val file: File) : DeliveryJournal {
    private val props = Properties()
    private val states = DeliveryState.entries.associateBy { it.name }

    init {
        if (file.exists()) {
            FileInputStream(file).use { props.load(it) }
        }
    }

    private fun key(msgId: ByteArray): String = msgId.toHex()

    override fun read(msgId: ByteArray): DeliveryState {
        val name = props.getProperty(key(msgId)) ?: return DeliveryState.UNAVAILABLE
        return states[name] ?: DeliveryState.UNAVAILABLE
    }

    override fun write(msgId: ByteArray, state: DeliveryState) {
        props.setProperty(key(msgId), state.name)
        persist()
    }

    override fun clear(msgId: ByteArray) {
        props.remove(key(msgId))
        persist()
    }

    private fun persist() {
        FileOutputStream(file).use { props.store(it, "godstone delivery state") }
    }

    private fun ByteArray.toHex(): String =
        joinToString("") { "%02x".format(it) }
}