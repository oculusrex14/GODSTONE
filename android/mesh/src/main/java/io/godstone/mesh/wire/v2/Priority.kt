// Hand-written runtime helper -- NOT a codegen artifact.
// The wire format carries priority as 3 flag bits (FrameV2.PRIORITY_MASK); this
// enum is the typed runtime view the router and abuse governor use. It is the
// successor to the deleted GMP/1 io.godstone.mesh.wire.Priority, kept as a
// logical class so PeerGovernor's per-priority token buckets survive the
// FrameV2 cutover. ci/check_parity.py Invariant A does not regenerate this
// file; it is outside the codegen contract.
package io.godstone.mesh.wire.v2

/**
 * Runtime message priority derived from a FrameV2 header's 3-bit PRIORITY_MASK
 * field (ADR-001 §3.1).
 *
 * Values match wire/wire_v2.yaml `priority`: SOS 0 / DIRECT 1 / GROUP 2 /
 * BROADCAST 3 / BULK 4, occupying bits 8..10 of the flags word
 * (FrameV2.PRIORITY_MASK = 0x0700).
 */
enum class Priority(val code: Int) {
    SOS(0),
    DIRECT(1),
    GROUP(2),
    BROADCAST(3),
    BULK(4);

    /**
     * GROUP and BROADCAST are wide-distribution traffic the sender must pay PoW
     * for (ADR-001 §3). SOS and DIRECT are exempt because latency there is a
     * safety property; BULK is governed by its own transport (ADR-006).
     */
    val requiresProofOfWork: Boolean get() = this == GROUP || this == BROADCAST

    companion object {
        /** Derive the priority from a FrameV2 flags word. Fail-safe to DIRECT. */
        fun fromFlags(flags: Int): Priority {
            val idx = (flags and FrameV2.PRIORITY_MASK) ushr 8
            return entries.firstOrNull { it.code == idx } ?: DIRECT
        }

        /**
         * Strictly decode priority from FrameV2 flags. Fails closed (null) on unknown codes
         * (codes 5..7 or unmapped). Used in security validation and abuse gating.
         */
        fun fromFlagsStrict(flags: Int): Priority? {
            val idx = (flags and FrameV2.PRIORITY_MASK) ushr 8
            return entries.firstOrNull { it.code == idx }
        }

        /** Place a priority into its flag-bit position (bits 8..10). */
        fun toFlags(priority: Priority): Int = priority.code shl 8

        fun fromCode(code: Int): Priority? = entries.firstOrNull { it.code == code }
    }
}