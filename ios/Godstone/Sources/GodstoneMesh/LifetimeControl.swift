import Foundation

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
 *                    carries only what the platform itself passes to a
 *                    real delegate - the peripheral identity, the value
 *                    that travelled with the event, the octets received -
 *                    and the OS object identities the factory handed out
 *                    when the manager was created. No fixture may invent
 *                    an epoch, a generation, or a name the delegate never
 *                    saw; where the OS passes nil, the trace carries nil.
 *                    The enumerators name only the real entry points of
 *                    the platform's delegate surface.
 *
 *   InvariantLedger  the entries a suite accumulates while its schedules
 *                    run: one record per invariant checked, with the
 *                    verdict it reached. The ledger prints its report to
 *                    the evidence log, so the record shows what was
 *                    verified, not merely that a test passed.
 */

public enum LifetimeControl {
    /// The unclaimed relation: a bare reassembler built without an owner
    /// (a vector test of the codec, say) admits its leases under this
    /// documented placeholder. Production always binds the real relation
    /// key through the connection, so a lease that carries the unclaimed
    /// key never governs a live relation and is never noticed by a fall arm.
    public static let unclaimedRelation = RelationKey(
        direction: .outboundCentral,
        peerId: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
        generation: 0
    )
}

/// The absolute lease of one inbound whole-record assembly.
public struct AssemblyLease: Equatable, Sendable {
    /// The relation that owns the assembly this lease governs.
    public let relationKey: RelationKey
    /// The sequence number whose assembly is under lease.
    public let seq: UInt8
    /// The admission identity: never borne twice by one reassembler.
    public let admissionId: UInt64
    /// The absolute term, on the reassembler's own clock. No arrival moves it.
    public let deadlineMono: TimeInterval

    /// The absolute term, in seconds, of one whole-record assembly. It
    /// mirrors the frozen invariant record's timeout_seconds: the sliding
    /// window's courtesy is bounded by this absolute term.
    public static let leaseSeconds: TimeInterval = 30.0

    public init(relationKey: RelationKey, seq: UInt8, admissionId: UInt64,
                deadlineMono: TimeInterval) {
        self.relationKey = relationKey
        self.seq = seq
        self.admissionId = admissionId
        self.deadlineMono = deadlineMono
    }
}

/// The real delegate entry points of the platform's adapter surface.
/// Every name corresponds to one method the OS itself invokes on the
/// transport's delegate; a fixture that cannot name its source here cannot
/// deliver through that source at all.
public enum AdapterCallbackSource: String, CaseIterable, Sendable {
    case didUpdateState
    case didConnect
    case didFailToConnect
    case didDiscoverServices
    case didDiscoverCharacteristics
    case didDiscoverDescriptors
    case didReadCharacteristics
    case didReadDescriptors
    case didWriteValue
    case didUpdateNotification
    case didReadRSSI
    case didReadRSSIPeripheral
    case didUpdateSUBscribers
    case willRestore
    case peerIsModified
}

/// One trace event: the arguments one delegate received, verbatim, plus
/// the identities the factory injected when the manager was created.
public struct AdapterTraceEvent: Sendable {
    public let source: AdapterCallbackSource
    /// The peripheral identity the callback names, or nil where the
    /// callback carries none.
    public let deviceUUID: UUID?
    /// The value that travelled with the event (state code, mtu, rssi -
    /// as the source names it), or nil where the source carries none.
    public let propertyValue: Int?
    /// The octets the callback received, verbatim, or nil.
    public let payload: Data?
    /// The object identity the factory handed out for the manager that
    /// owns this callback; a trace event from a foreign manager is refused
    /// by the production reducers, which is what the crossed-connect
    /// schedule proves.
    public let managerIdentity: UInt64
    /// The epoch the delivering fixture observed at the moment of
    /// delivery; production revalidates the epoch itself and may discard
    /// the event - the fixture never decides.
    public let epochAtDelivery: UInt64

    public init(source: AdapterCallbackSource, deviceUUID: UUID? = nil,
                propertyValue: Int? = nil, payload: Data? = nil,
                managerIdentity: UInt64, epochAtDelivery: UInt64) {
        self.source = source
        self.deviceUUID = deviceUUID
        self.propertyValue = propertyValue
        self.payload = payload
        self.managerIdentity = managerIdentity
        self.epochAtDelivery = epochAtDelivery
    }
}

/// The ledger one suite accumulates while its identical schedules run on
/// both platforms. Each entry names an invariant checked, the scenario
/// step it was checked at, and the verdict the check reached.
public final class InvariantLedger {
    public enum Verdict: String { case held = "HELD"; case broken = "BROKEN"; case skipped = "SKIPPED" }
    public struct Entry {
        public let invariantId: String
        public let scenario: String
        public let statement: String
        public let verdict: Verdict
    }

    public let owner: String
    private var entries: [Entry] = []

    public init(owner: String) { self.owner = owner }

    /// Record one check, with the verdict it reached; returns the verdict
    /// so a caller may fail its test on the broken ones.
    @discardableResult
    public func check(_ invariantId: String, _ scenario: String, _ statement: String,
                      _ held: Bool) -> Verdict {
        let verdict: Verdict = held ? .held : .broken
        entries.append(Entry(invariantId: invariantId, scenario: scenario,
                             statement: statement, verdict: verdict))
        return verdict
    }

    /// Record a check the platform's own gate makes unavailable.
    public func skip(_ invariantId: String, _ scenario: String, _ statement: String, _ why: String) {
        entries.append(Entry(invariantId: invariantId, scenario: scenario,
                             statement: statement + " (skipped: " + why + ")", verdict: .skipped))
    }

    public func broken() -> [Entry] { entries.filter { $0.verdict == .broken } }
    public func entriesCount() -> Int { entries.count }

    public func report() -> String {
        var out = "invariant ledger [\(owner)]: \(entries.count) checks, "
            + "\(entries.filter { $0.verdict == .held }.count) held, "
            + "\(entries.filter { $0.verdict == .broken }.count) broken, "
            + "\(entries.filter { $0.verdict == .skipped }.count) skipped\n"
        for e in entries {
            out += "  \(e.verdict.rawValue)  \(e.invariantId) @ \(e.scenario) - \(e.statement)\n"
        }
        return out
    }
}
