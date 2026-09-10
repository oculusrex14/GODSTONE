package io.godstone.mesh.transport

/*
 * T20: the lifetime instruments of the transport's inbound edge.
 *
 * Three small types, one purpose each, stated here once so both platforms
 * and every fixture speak them alike.
 *
 *   AssemblyLease    the absolute term of one whole-record assembly. The
 *                    reassembler already keeps a sliding idle window: each
 *                    arriving fragment, fresh or duplicate, refreshes the
 *                    activity stamp, and a peer that dribbles one fragment
 *                    every minute could otherwise pin an assembly slot and
 *                    a buffer indefinitely. The lease stands independent
 *                    of that window: admission mints one token
 *                    {relationKey, seq, admissionId, deadlineMono}, no
 *                    later fragment moves the deadline, and when the
 *                    deadline passes the reassembler releases the buffers
 *                    and notifies its owner - and only the owner may
 *                    close or reset the relation, through the fall paths
 *                    the transport has always kept. This is documented
 *                    local resource defence, not protocol: the wire, the
 *                    headers and the uint8 framing are untouched.
 *
 *   AdapterTraceEvent the one shape every adapter-facing fixture uses to
 *                    deliver a callback into the production reducers. It
 *                    carries only what the platform binder itself passes
 *                    to a real callback - the device handle's address, the
 *                    property value, the octets received, the status - and
 *                    the OS object identities the factory handed out when
 *                    the manager was created. No fixture may invent an
 *                    epoch, a generation, or a name the callback never
 *                    saw; where the OS passes nil, the trace carries nil.
 *                    The enumerators name only the real entry points of
 *                    the platform's callback surface.
 *
 *   InvariantLedger  the entries a suite accumulates while its schedules
 *                    run: one record per invariant checked, with the
 *                    verdict it reached. The ledger prints its report to
 *                    the evidence log, so the record shows what was
 *                    verified, not merely that a test passed.
 */

/** The relation that owns the assembly this lease governs. */
class AssemblyLease(
    val relationKey: RelationKey,
    val seq: Int,
    val admissionId: Long,
    val deadlineMono: Long,
) {
    companion object {
        /** The absolute term, in seconds, of one whole-record assembly.
         * It mirrors the frozen invariant record's timeout_seconds: the
         * sliding window's courtesy is bounded by this absolute term. */
        const val LEASE_SECONDS: Long = 30L
    }
}

/**
 * The real callback entry points of the platform's adapter surface, as
 * the binder names them. Every name here corresponds to one method the
 * OS itself invokes on the transport's callback; a fixture that cannot
 * name its source here cannot deliver through that source at all.
 */
enum class AdapterCallbackSource {
    ON_CONNECTION_STATE_CHANGE,
    ON_SERVICES_DISCOVERED,
    ON_CHARACTERISTICS_DISCOVERED,
    ON_DESCRIPTOR_READ,
    ON_CHARACTERISTIC_READ,
    ON_CHARACTERISTIC_WRITE,
    ON_RELIABLE_WRITE,
    ON_MTU_CHANGED,
    ON_READ_REMOTE_RSSI,
    ON_READ_BATTERY_LEVEL,
    ON_READ_DESCRIPTOR,
    ON_READ_CHARACTERISTIC,
    ON_WRITE_CREDENTIALS,
    ON_NOTIFY,
    ON_DESCRIPTOR_WRITE,
}

/**
 * One trace event: the arguments one callback received, verbatim, plus
 * the identities the factory injected when the manager was created.
 *
 * @param source the entry point the OS invoked
 * @param deviceAddress the address the callback names for the device, or
 *        nil where the callback carries no address
 * @param propertyValue the status or value the callback travelled with
 *        (state code, mtu, rssi, battery level - as the source names it),
 *        or nil where the source carries none
 * @param payload the octets the callback received, verbatim, or nil
 * @param managerIdentity the object identity the factory handed out for
 *        the manager that owns this callback; a trace event from a
 *        foreign manager is refused by the production reducers, which is
 *        exactly what the crossed-connect schedule proves
 * @param epochAtDelivery the epoch the delivering fixture observed at
 *        the moment of delivery; production revalidates the epoch itself
 *        and may discard the event - the fixture never decides
 */
class AdapterTraceEvent(
    val source: AdapterCallbackSource,
    val deviceAddress: String?,
    val propertyValue: Int?,
    val payload: ByteArray?,
    val managerIdentity: Long,
    val epochAtDelivery: Long,
    /**
     * The client registration token, for the entries the platform passes
     * one (the disconnect terminal names the client it came from; a trace
     * event for such an entry carries the very token the callback was
     * handed). Nil where the source carries none.
     */
    val clientToken: Long? = null,
    /** The registration generation, companion of the client token. */
    val gattGeneration: Long? = null,
)

/**
 * The ledger one suite accumulates while its identical schedules run on
 * both platforms. Each entry names an invariant checked, the scenario
 * step it was checked at, and the verdict the check reached.
 */
class InvariantLedger(val owner: String) {
    enum class Verdict { HELD, BROKEN, SKIPPED }

    class Entry(
        val invariantId: String,
        val scenario: String,
        val statement: String,
        val verdict: Verdict,
    )

    private val entries = ArrayList<Entry>()

    /** Record one check, with the verdict it reached; returns the verdict
     * so a caller may fail its test on the broken ones. */
    fun check(invariantId: String, scenario: String, statement: String, held: Boolean): Verdict {
        val verdict = if (held) Verdict.HELD else Verdict.BROKEN
        entries.add(Entry(invariantId, scenario, statement, verdict))
        return verdict
    }

    /** Record a check the platform's own gate makes unavailable. */
    fun skip(invariantId: String, scenario: String, statement: String, why: String): Verdict {
        entries.add(Entry(invariantId, scenario, statement + " (skipped: " + why + ")", Verdict.SKIPPED))
        return Verdict.SKIPPED
    }

    fun entriesCount(): Int = entries.size

    fun broken(): List<Entry> = entries.filter { it.verdict == Verdict.BROKEN }

    fun report(): String {
        val b = StringBuilder()
        b.append("invariant ledger [").append(owner).append("]: ")
            .append(entries.size).append(" checks, ")
            .append(entries.count { it.verdict == Verdict.HELD }).append(" held, ")
            .append(entries.count { it.verdict == Verdict.BROKEN }).append(" broken, ")
            .append(entries.count { it.verdict == Verdict.SKIPPED }).append(" skipped\n")
        for (e in entries) {
            b.append("  ").append(e.verdict).append("  ").append(e.invariantId)
                .append(" @ ").append(e.scenario).append(" - ").append(e.statement).append('\n')
        }
        return b.toString()
    }
}

/**
 * The unclaimed relation: a bare reassembler built without an owner
 * (a vector test of the codec, say) admits its leases under this
 * documented placeholder. Production always binds the real relation key
 * through the connection, so a lease that carries the unclaimed key
 * never governs a live relation and is never noticed by a fall arm.
 */
val UNCLAIMED_RELATION: RelationKey = RelationKey(
    BleDirection.OUTBOUND,
    "00:00:00:00:00:00",
    0L,
)
