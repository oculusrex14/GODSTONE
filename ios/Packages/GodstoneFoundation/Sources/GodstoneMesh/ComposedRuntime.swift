import Foundation
import CryptoKit
import GodstoneCore

// ---------------------------------------------------------------------------
// T44 -- "Prove crash-safe multihop behavior through composed runtimes".
// The Swift twin of android/mesh/src/main/java/io/godstone/mesh/runtime/
// ComposedRuntime.kt, with the SAME laws and the SAME trace format.
//
// This harness composes the REAL authorities -- the real MeshNode, the real
// Router (with its required store), the real durable store, the real
// DeliveryTracker, the real recipient inbox, the real T84 ACK authority and the
// real T42 sync pump -- and substitutes ONLY the operating system's facades:
//
//   * `HostClock`  -- a deterministic monotonic clock plus the wire calendar's
//                     seconds, seeded from the real clock once at construction
//   * `LinkFacade` -- the radio, serialized: every byte handed to a link is
//                     RECORDED verbatim, so "no relay plaintext" is a fact about
//                     captured bytes rather than a claim
//
// Laws:
//   1. NO SEND WITHOUT THE DURABLE COMMIT.
//   2. CRASH CHECKPOINTS ARE REAL: `crashAfter(boundary)` interrupts the
//      composition at a named seam and leaveth the durable estate as it found it.
//   3. A WIPE DURING A SEND IS EXERCISED; no pre-wipe epoch may send afterwards.
//   4. RESOURCES ARE BOUNDED and the caps are observable.
//   5. THE SEALED INNER PAYLOAD IS THE FROZEN SignedMessageV1 CONTAINER: sealing
//      a bare body is a payload the frozen verifier MUST refuse. (The first form
//      of the android harness did exactly that, and the composed trace caught it.)
//
// Nonshipping: the lab mesh path. Readiness stays false and no device claim is
// made; host tests prove no CoreBluetooth behaviour.
// ---------------------------------------------------------------------------

/// The OS facade the harness substitutes for time.
public protocol HostClock: AnyObject {
    func monoMillis() -> Int64
    func wallSeconds() -> Int64
}

/// A deterministic clock: every case fixes its own instants.
public final class FixedHostClock: HostClock, @unchecked Sendable {
    private var now: Int64
    private let wallBase: Int64

    public init(now: Int64 = 1_000, wallBase: Int64 = Int64(Date().timeIntervalSince1970)) {
        self.now = now
        self.wallBase = wallBase
    }

    public func monoMillis() -> Int64 { now }
    public func wallSeconds() -> Int64 { wallBase + (now - 1_000) / 1_000 }

    @discardableResult
    public func advance(by delta: Int64) -> Int64 { now += delta; return now }
}

/// One captured link delivery: the exact bytes a radio carried.
public struct LinkDelivery: Sendable, Equatable {
    public let fromLabel: String
    public let toLabel: String
    public let bytes: Data
    public let admitted: Bool
    public let atMonoMillis: Int64
}

/// The radio, serialized and recording.
public final class LinkFacade: @unchecked Sendable {
    /// Bound on captured deliveries: telemetry, drop-oldest, counted.
    public static let maxCaptured: Int = 4096

    private let lock = NSLock()
    private let clock: HostClock
    private let bound: Int
    private var captured: [LinkDelivery] = []
    private var admittedCount = 0
    private var refusedCount = 0
    private var dropped: Int64 = 0

    /// Whether the transport accepteth these bytes (a refusal must never become a
    /// durable claim).
    public var admit: (String, String) -> Bool = { _, _ in true }

    public init(clock: HostClock, bound: Int = LinkFacade.maxCaptured) {
        self.clock = clock
        self.bound = bound
    }

    /// Hand `bytes` to the `toLabel` link. Records EVERY attempt, admitted or not.
    @discardableResult
    public func offer(fromLabel: String, toLabel: String, bytes: Data) -> Bool {
        let said = admit(fromLabel, toLabel)
        lock.lock()
        while captured.count >= bound {
            captured.removeFirst()
            dropped += 1
        }
        captured.append(LinkDelivery(fromLabel: fromLabel, toLabel: toLabel, bytes: Data(bytes),
                                     admitted: said, atMonoMillis: clock.monoMillis()))
        if said { admittedCount += 1 } else { refusedCount += 1 }
        lock.unlock()
        return said
    }

    public func deliveries() -> [LinkDelivery] {
        lock.lock(); defer { lock.unlock() }
        return captured
    }

    public func deliveriesTo(_ label: String) -> [LinkDelivery] {
        lock.lock(); defer { lock.unlock() }
        return captured.filter { $0.toLabel == label }
    }

    public func admitted() -> Int { lock.lock(); defer { lock.unlock() }; return admittedCount }
    public func refused() -> Int { lock.lock(); defer { lock.unlock() }; return refusedCount }
    public func droppedCount() -> Int64 { lock.lock(); defer { lock.unlock() }; return dropped }
    func clear() { lock.lock(); captured.removeAll(); lock.unlock() }
}

/// One composed node: every authority below is a PRODUCTION instance.
final class ComposedNode: @unchecked Sendable {
    let label: String
    let identity: MeshIdentity
    let store: InMemoryMessageStore
    let tracker: DeliveryTracker
    let node: MeshNode
    let inbox: RecipientInboxRepository
    let ackStore: InMemoryAckStore
    let keys: MutableKeyTable
    let ackPump: DurableAckPump
    private let signingSeed: Data
    /// The harness this node belongeth to, if any -- so a durable store this node createth is **OWNED** by the composition rather than orphaned.
    internal weak var ownerHarness: ComposedRuntimeHarness?

    var nodeId: Data { identity.nodeId }

    init(label: String, identity: MeshIdentity, signingSeed: Data,
                  store: InMemoryMessageStore, tracker: DeliveryTracker, node: MeshNode,
                  inbox: RecipientInboxRepository, ackStore: InMemoryAckStore,
                  keys: MutableKeyTable, ackPump: DurableAckPump) {
        self.label = label
        self.identity = identity
        self.signingSeed = signingSeed
        self.store = store
        self.tracker = tracker
        self.node = node
        self.inbox = inbox
        self.ackStore = ackStore
        self.keys = keys
        self.ackPump = ackPump
    }

    /// Trust one peer's signing key (the operator's selection, never self-named).
    func trust(nodeId: Data, signingKey: Data) { keys.put(nodeId, signingKey) }

    func signingKeySeed() -> Data { Data(signingSeed) }
}

/// A durable checkpoint: what the estate carrieth at one instant.
public struct DurableCheckpoint: Sendable, Equatable {
    public let atMonoMillis: Int64
    public let heldDigest: String
    public let heldCount: Int
    public let rows: [String: String]
    public let offeredToLinks: Int

    public func json() -> [String: Any] {
        ["at_mono_ms": atMonoMillis, "held_digest": heldDigest, "held_count": heldCount,
         "rows": rows, "offered_to_links": offeredToLinks]
    }
}

/// One typed trace event: what the composition did, in order.
public struct TraceEvent: Sendable, Equatable {
    public let kind: String
    public let atMonoMillis: Int64
    public let fields: [String: String]

    public func json() -> [String: Any] {
        ["kind": kind, "at_mono_ms": atMonoMillis, "fields": fields]
    }
}

/// T44's cross-process / cross-isle trace: schema 1, canonical JSON, replayable by
/// ANOTHER isle's harness (the android twin carrieth the same format).
public final class MeshTrace: @unchecked Sendable {
    public static let schema: Int = 1
    public static let isle: String = "ios"
    public static let maxEvents: Int = 4096

    private let lock = NSLock()
    private let bound: Int
    private var events: [TraceEvent] = []
    private var checkpoints: [DurableCheckpoint] = []
    private var dropped: Int64 = 0

    public init(bound: Int = MeshTrace.maxEvents) { self.bound = bound }

    public func append(_ event: TraceEvent) {
        lock.lock()
        while events.count >= bound {
            events.removeFirst()
            dropped += 1
        }
        events.append(event)
        lock.unlock()
    }

    public func checkpoint(_ cp: DurableCheckpoint) {
        lock.lock(); checkpoints.append(cp); lock.unlock()
    }

    public func eventsSnapshot() -> [TraceEvent] { lock.lock(); defer { lock.unlock() }; return events }
    public func kinds() -> [String] { lock.lock(); defer { lock.unlock() }; return events.map { $0.kind } }
    public func checkpointsSnapshot() -> [DurableCheckpoint] {
        lock.lock(); defer { lock.unlock() }; return checkpoints
    }
    public func droppedCount() -> Int64 { lock.lock(); defer { lock.unlock() }; return dropped }
    public func size() -> Int { lock.lock(); defer { lock.unlock() }; return events.count }

    public func json() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["schema": MeshTrace.schema, "isle": MeshTrace.isle,
                "events": events.map { $0.json() },
                "checkpoints": checkpoints.map { $0.json() }]
    }

    /// Replayable shape check: a foreign trace is accepted only if it carrieth this
    /// schema, an isle name and a well-formed event list. A future schema is
    /// REFUSED rather than auto-detected.
    public static func parse(_ document: [String: Any]) throws -> [TraceEvent] {
        guard let schema = document["schema"] as? Int else {
            throw TraceSchemaError(reason: "the trace carrieth no schema")
        }
        guard schema == MeshTrace.schema else {
            throw TraceSchemaError(reason: "the trace schema \(schema) is refused (only \(MeshTrace.schema) is known)")
        }
        guard let raw = document["events"] as? [[String: Any]] else {
            throw TraceSchemaError(reason: "the trace carrieth no events")
        }
        return try raw.map { entry in
            guard let kind = entry["kind"] as? String else {
                throw TraceSchemaError(reason: "every trace event must carry a kind")
            }
            let at = (entry["at_mono_ms"] as? NSNumber)?.int64Value ?? 0
            let fields = (entry["fields"] as? [String: String]) ?? [:]
            return TraceEvent(kind: kind, atMonoMillis: at, fields: fields)
        }
    }
}

public struct TraceSchemaError: Error, Equatable { public let reason: String }

/// Why a composed step was refused. Named, never a silent no-op.
public enum ComposedRefusal: String, Sendable {
    case noSuchNode = "NO_SUCH_NODE"
    case notLinked = "NOT_LINKED"
    case storeRefused = "STORE_REFUSED"
    case wiped = "WIPED"
    case crashPoint = "CRASH_POINT"
    case traceSchema = "TRACE_SCHEMA"
}

/// The typed outcome of one composed step.
public enum ComposedOutcome: Sendable, Equatable {
    case applied(detail: String)
    case refused(reason: ComposedRefusal, detail: String)

    public var isApplied: Bool { if case .applied = self { return true }; return false }
    public var detail: String {
        switch self {
        case .applied(let d): return d
        case .refused(let r, let d): return "\(r.rawValue):\(d)"
        }
    }
}

/// A crash at a named composition seam: the estate is left exactly as found.
public struct ComposedCrash: Error { public let boundary: String }

/// The composed runtime harness. Every node it buildeth is the REAL composition.
public final class ComposedRuntimeHarness {
    public let clock: FixedHostClock
    public let link: LinkFacade
    private let trace: MeshTrace
    private var nodes: [String: ComposedNode] = [:]
    private var links: Set<String> = []
    /// The transport handle each label came up on (a UUID is not a node id).
    private var transports: [String: UUID] = [:]
    /// Which LABEL a transport handle reacheth. A UUID is neither a node id nor a
    /// recipient: this map is the harness's own bookkeeping of its own links.
    private var handleLabels: [UUID: String] = [:]
    private var wiped = false
    private var crashAt: String?
    /// *** GS-INTEGRATION-001: THE DURABLE STORES THIS HARNESS HATH HANDED OUT -- AND IT MUST **OWN** THEM, BECAUSE **A WIPE THAT OWNS NOTHING
    /// HATH NOTHING TO REACH** (round 514's measured RED: `beginWipe()` setteth a flag and eraseth no row, so the intent ledger stood after a wipe). ***
    private var durableStoreURLs: Set<URL> = []

    /// The composition seam a crash can be fixed at, before the radio.
    public static let seamBeforeLink: String = "before_link"
    /// Bound on one ACK turn (the T37 outbox is bounded at 64 by its own law).
    public static let maxAcksPerTurn: Int = 64

    public init(clock: FixedHostClock = FixedHostClock(),
                link: LinkFacade? = nil,
                trace: MeshTrace = MeshTrace()) {
        self.clock = clock
        self.link = link ?? LinkFacade(clock: clock)
        self.trace = trace
    }

    /// Compose one node. The recipient key directory is per-node and explicit: a
    /// node resolveth only the keys it was actually trusted with.
    func addNode(_ label: String, seedByte: UInt8? = nil) throws -> ComposedNode {
        let seed = Data((0..<32).map { i -> UInt8 in
            if let s = seedByte { return UInt8((Int(s) + i) & 0xFF) }
            return UInt8(Int.random(in: 0...255))
        })
        let xSeed = Data((0..<32).map { i -> UInt8 in
            if let s = seedByte { return UInt8((Int(s) &+ 0x40 &+ i) & 0xFF) }
            return UInt8(Int.random(in: 0...255))
        })
        let identity = try ComposedRuntimeHarness.makeIdentity(seed: seed, xSeed: xSeed)
        let store = InMemoryMessageStore()
        let ackStore = InMemoryAckStore()
        let keys = MutableKeyTable()
        // a node pinnaleth its OWN authentic signing key first: the inbox
        // self-verifieth every ACK it produceth, so a directory without our own
        // key refuseth to issue one at all (the census saith acksRefusedKey)
        keys.put(identity.nodeId, identity.signingPublicKey)
        let authenticator = Ed25519AckAuthenticator(resolver: keys)
        let repo = ComposedDeliveryRepository(store)
        let tracker = DeliveryTracker(repo: repo, authenticator: authenticator)
        let node = MeshNode(identity: identity, store: store, deliveryTracker: tracker,
                            sessions: SessionManager(identity: identity,
                                                     trustAuthority: ComposedTrustAuthority()))
        // GS-SOS-001 (the iOS twin): the SOS road may no longer fall back to an
        // UNSIGNED structural frame, so a composed node that is meant to send
        // distress MUST carry a signing authority. This harness generateth its
        // own keys for every node (see `seed`/`xSeed` above), so it wireth a
        // SIMULATED authority over THAT generated material -- the same material
        // its own TestAckSigner already useth. It is HARNESS SUPPORT AND NOT A
        // DEVICE RESULT: production carries no authority yet and therefore
        // REFUSES to offer an unauthenticated distress call.
        node.sosAuthority = SimulatedSosAuthority(
            seed: seed,
            dhPublicKey: identity.staticDhPublicKey,
            generation: identity.bindingGeneration,
            // GS-SOS-001, second defect (round 164): the binding is ISSUED BY THE HARNESS'S OWN
            // IDENTITY (`MeshIdentity.issueIdentityBinding()`, an AUTHORITY file) and handed in --
            // this file is not an authority file, so constructing one here would be the very
            // issuance bypass the local-identity control refuseth.
            binding: try identity.issueIdentityBinding(),
            clock: { [clock] in Int64(clock.wallSeconds()) })
        let ackDriver = AckObligationDriver(store: ackStore,
                                            signer: TestAckSigner(nodeId: identity.nodeId, seed: seed),
                                            authenticator: authenticator, resolver: keys)
        let ackPump = DurableAckPump(store: ackStore, admitForeign: { encoded, from in
            ackDriver.admitForeignCandidate(encoded, receivedFrom: from)
        }, clock: { [clock] in Int(clock.wallSeconds() * 1000) })
        node.ackDispatcher = AckDispatcher(
            lookupDeliveryRow: { tracker.lookup($0) },
            verifyOrigin: { tracker.acknowledge($0.msgId, $0) },
            admitCandidate: { encoded, from in ackPump.admit(encoded, receivedFrom: from) })
        let inbox = RecipientInboxRepository(
            router: node.router,
            ourNodeId: identity.nodeId,
            localDhPrivate: { xSeed },
            signer: TestAckSigner(nodeId: identity.nodeId, seed: seed),
            resolver: keys,
            authenticator: Ed25519AckAuthenticator(resolver: keys),
            pairedStore: ackStore,
            commitInbound: { frame, receivedFrom, localRecipient, generation, lifetime, receivedAt, fault in
                try store.commitInboundWithObligationAtWithFault(
                    frame, receivedFrom: receivedFrom, localRecipientNodeId: localRecipient,
                    identityGeneration: generation, obligationLifetimeMs: lifetime,
                    receivedAt: receivedAt, fault: fault)
            },
            clockSeconds: { [clock] in clock.wallSeconds() })
        node.recipientInbox = inbox

        let composed = ComposedNode(label: label, identity: identity, signingSeed: seed,
                                    store: store, tracker: tracker, node: node, inbox: inbox,
                                    ackStore: ackStore, keys: keys, ackPump: ackPump)
        // GS-INTEGRATION-001: THE NODE KNOWETH ITS HARNESS, SO WHAT IT CREATETH IS **OWNED** BY THE COMPOSITION (and a wipe can therefore reach it).
        composed.ownerHarness = self
        nodes[label] = composed
        trace.append(TraceEvent(kind: "node_composed", atMonoMillis: clock.monoMillis(),
                                fields: ["node": label, "node_id": ComposedRuntimeHarness.hex(identity.nodeId)]))
        return composed
    }

    func node(_ label: String) -> ComposedNode? { nodes[label] }

    /// A trusted relation comes up between two nodes (both sides).
    @discardableResult
    public func link(_ from: String, _ to: String) -> ComposedOutcome {
        guard let a = nodes[from] else { return .refused(reason: .noSuchNode, detail: from) }
        guard let b = nodes[to] else { return .refused(reason: .noSuchNode, detail: to) }
        // the TRANSPORT first: a node can only hand bytes to a peer its radio
        // carrieth a handle for (the iOS peer view is a set of UUIDs)
        let aHandle = transports[from] ?? UUID()
        let bHandle = transports[to] ?? UUID()
        transports[from] = aHandle
        transports[to] = bHandle
        a.node.transportDidConnect(peerId: bHandle)
        b.node.transportDidConnect(peerId: aHandle)
        handleLabels[bHandle] = to
        handleLabels[aHandle] = from
        // then the TRUSTED relation the sync pump schedulleth against
        a.node.trustedPeerDidConnect(nodeId: b.nodeId, peerId: bHandle)
        b.node.trustedPeerDidConnect(nodeId: a.nodeId, peerId: aHandle)
        links.insert("\(from)->\(to)"); links.insert("\(to)->\(from)")
        trace.append(TraceEvent(kind: "link_up", atMonoMillis: clock.monoMillis(),
                                fields: ["from": from, "to": to]))
        return .applied(detail: "linked \(from) <-> \(to)")
    }

    @discardableResult
    public func unlink(_ from: String, _ to: String) -> ComposedOutcome {
        guard let a = nodes[from] else { return .refused(reason: .noSuchNode, detail: from) }
        guard let b = nodes[to] else { return .refused(reason: .noSuchNode, detail: to) }
        a.node.transportDidDisconnect(peerId: transports[to] ?? UUID())
        b.node.transportDidDisconnect(peerId: transports[from] ?? UUID())
        a.node.trustedPeerDidDisconnect(nodeId: b.nodeId, peerId: transports[to] ?? UUID())
        b.node.trustedPeerDidDisconnect(nodeId: a.nodeId, peerId: transports[from] ?? UUID())
        links.remove("\(from)->\(to)"); links.remove("\(to)->\(from)")
        trace.append(TraceEvent(kind: "link_down", atMonoMillis: clock.monoMillis(),
                                fields: ["from": from, "to": to]))
        return .applied(detail: "unlinked \(from) <-> \(to)")
    }

    public func isLinked(_ from: String, _ to: String) -> Bool { links.contains("\(from)->\(to)") }

    /// The labels of the peers `from` currently carrieth a link to.
    public func linkedPeerLabels(_ from: String) -> [String] {
        nodes.values.filter { $0.label != from && links.contains("\(from)->\($0.label)") }
            .map { $0.label }
    }

    /// Fix a crash at a named composition seam (nil cleareth it).
    /// *** CRYPTO-005: **THE COMPOSITION'S EXPOSED DURABLE COMMAND** -- the harness's own door to `ComposedNode.sendDirectDurable`, because the
    /// harness's `nodes` map is PRIVATE and the audit's closure test invoketh a command ON THE RUNTIME, not on a node it cannot reach. ***
    ///
    /// THE CARD'S OWN WORDS: "Composition test invokes the **EXPOSED RUNTIME COMMAND** and observes exactly one ...". IT IS THE ONLY METHOD IN
    /// PRODUCTION THAT REACHETH A SEND PATH WHOSE JOURNAL IS THE DURABLE ONE, AND IT RETURNETH THE AUTHORITY'S OWN `SendDirectResult` LOSSLESSLY.
    public func sendDirectDurable(_ from: String, recipient recipientLabel: String, plaintext: Data,
                                  intentId: Data, storeURL: URL) async throws -> SendDirectResult {
        guard let a = nodes[from] else { return .rejected(reason: .enqueueInvalidArgument) }
        guard let b = nodes[recipientLabel] else { return .rejected(reason: .enqueueInvalidArgument) }
        return try await a.sendDirectDurable(intentId, recipient: b, plaintext: plaintext, storeURL: storeURL)
    }

    public func crashAfter(_ boundary: String?) { crashAt = boundary }

    /// A wipe is in progress: no epoch may send or publish afterwards.
    /// GS-INTEGRATION-001: the composition TAKETH OWNERSHIP of a durable store it created.
    internal func registerDurableStore(_ url: URL) { durableStoreURLs.insert(url) }

    /// GS-INTEGRATION-001: **THE WIPE NOW REACHETH THE REAL OWNER.** Round 514's RED measured that `beginWipe()` set a flag and erased NO row, so a
    /// durable intent stood after a wipe. IT NOW ERASETH THE DURABLE ARTIFACTS IT OWNS -- which is the artifact-filesystem erasure GS-STORE-006 built,
    /// applied to the stores this composition handed out -- AND THE FLAG REMAINS THE SECOND LINE OF DEFENCE RATHER THAN THE ONLY ONE.
    public func beginWipe() {
        for url in durableStoreURLs { try? FileManager.default.removeItem(at: url) }
        durableStoreURLs.removeAll()
        wiped = true
        trace.append(TraceEvent(kind: "wipe_begin", atMonoMillis: clock.monoMillis(), fields: [:]))
    }

    public func isWiped() -> Bool { wiped }

    /// The seam every send passeth through: the durable commit, then the link.
    @discardableResult
    private func hand(_ node: ComposedNode, toLabel: String, bytes: Data) -> Bool {
        if wiped {
            trace.append(TraceEvent(kind: "send_refused", atMonoMillis: clock.monoMillis(),
                                    fields: ["node": node.label, "reason": "wipe_in_progress"]))
            return false
        }
        if crashAt == ComposedRuntimeHarness.seamBeforeLink {
            crashAt = nil
            trace.append(TraceEvent(kind: "crash", atMonoMillis: clock.monoMillis(),
                                    fields: ["boundary": ComposedRuntimeHarness.seamBeforeLink]))
            return false
        }
        let admitted = link.offer(fromLabel: node.label, toLabel: toLabel, bytes: bytes)
        trace.append(TraceEvent(kind: "link_offer", atMonoMillis: clock.monoMillis(),
                                fields: ["node": node.label, "to": toLabel,
                                         "admitted": admitted ? "true" : "false",
                                         "bytes": String(bytes.count)]))
        if admitted, let receiving = nodes[toLabel], let frame = FrameV2.decode(bytes) {
            // the radio DELIVERETH: the recorded bytes are handed to the receiving
            // node's own dispatch statute, which is the only way anything enters
            // its durable estate
            _ = receiving.node.ingestInbound(frame, receivedFrom: node.nodeId)
        }
        return admitted
    }

    /// Author one DIRECT message at `from` FOR `recipientLabel`, handing it to every
    /// peer `from` is linked to. The recipient need not be a neighbour.
    @discardableResult
    public func sendDirect(_ from: String, recipient recipientLabel: String, plaintext: Data,
                           crash: Bool = false) async throws -> ComposedOutcome {
        guard let a = nodes[from] else { return .refused(reason: .noSuchNode, detail: from) }
        guard let b = nodes[recipientLabel] else {
            return .refused(reason: .noSuchNode, detail: recipientLabel)
        }
        let peers = linkedPeerLabels(from)
        if peers.isEmpty { return .refused(reason: .notLinked, detail: "no linked peer of \(from)") }
        a.trust(nodeId: b.nodeId, signingKey: b.identity.signingPublicKey)

        if crash && crashAt == ComposedRuntimeHarness.seamBeforeLink {
            // the durable enqueue happeneth FIRST; the crash falleth at the radio
            let prepared = try await authorFrame(a, recipient: b, plaintext: plaintext)
            _ = a.node.dispatchDirect(prepared, expectedRecipient: b.nodeId) { f, peerUUID in
                self.hand(a, toLabel: self.transportLabel(peerUUID), bytes: f.encode())
            }
            return .applied(detail: "crashed:\(ComposedRuntimeHarness.seamBeforeLink)")
        }

        let frame = try await authorFrame(a, recipient: b, plaintext: plaintext)
        // the iOS transport handeth a TRANSPORT UUID: the offer still nameth the
        // DESTINATION LABEL, because a UUID is neither a node id nor a recipient
        let result = a.node.dispatchDirect(frame, expectedRecipient: b.nodeId) { f, peerUUID in
            // a transport UUID is neither a node id nor a recipient (T42's law), so
            // the offer nameth the LINK the bytes were handed to
            self.hand(a, toLabel: self.transportLabel(peerUUID), bytes: f.encode())
        }
        trace.append(TraceEvent(kind: "send_direct", atMonoMillis: clock.monoMillis(),
                                fields: ["from": from, "recipient": recipientLabel,
                                         "msg_id": ComposedRuntimeHarness.hex(frame.msgId),
                                         "result": "\(result)"]))
        return .applied(detail: "\(result)")
    }

    private func authorFrame(_ a: ComposedNode, recipient b: ComposedNode,
                             plaintext: Data) async throws -> FrameV2 {
        var nonce = Data(count: 16)
        _ = nonce.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        let createdAt = clock.wallSeconds()
        // The sealed inner payload IS the frozen SignedMessageV1 container: the
        // recipient's inbox verifieth the author, the recipient and the msgId over
        // exactly those bytes. Sealing a bare body is a payload the frozen verifier
        // MUST refuse.
        let container = try SignedMessageV1.author(
            senderIdentityPriv: a.signingKeySeed(),
            senderIdentityPub: a.identity.signingPublicKey,
            senderNodeId: a.nodeId,
            recipientNodeId: b.nodeId,
            messageNonce: nonce,
            createdAtEpochSeconds: createdAt,
            priority: .direct,
            timeQuality: .userConfirmed,
            bodyUtf8: plaintext)
        return try await a.node.router.buildSealedMessage(
            plaintext: container,
            recipientNodeId: b.nodeId,
            recipientStaticPub: b.identity.staticDhPublicKey,
            identity: LogicalMessageIdentity(createdAtEpochSeconds: createdAt, messageNonce: nonce),
            priority: .direct)
    }

    /// Author and dispatch one SOS broadcast from `from` to every linked peer.
    @discardableResult
    public func sendSos(_ from: String, plaintext: Data) async -> ComposedOutcome {
        guard let a = nodes[from] else { return .refused(reason: .noSuchNode, detail: from) }
        let result = a.node.dispatchSos(payload: plaintext) { f, peerUUID in
            self.hand(a, toLabel: self.transportLabel(peerUUID), bytes: f.encode())
        }
        trace.append(TraceEvent(kind: "send_sos", atMonoMillis: clock.monoMillis(),
                                fields: ["from": from, "result": "\(result)"]))
        return .applied(detail: "\(result)")
    }

    /// Deliver everything `from` holdeth for a peer: one bounded sync turn over the
    /// REAL pump, then the peer ingesteth each frame through the REAL statute.
    @discardableResult
    public func turn(_ from: String, _ to: String) -> Int {
        guard let a = nodes[from], let b = nodes[to] else { return 0 }
        if !isLinked(from, to) { return 0 }
        let batch = a.node.drainSyncFrames(for: b.nodeId)
        var delivered = 0
        for f in batch {
            if hand(a, toLabel: to, bytes: f.encode()) { delivered += 1 }
        }
        trace.append(TraceEvent(kind: "turn", atMonoMillis: clock.monoMillis(),
                                fields: ["from": from, "to": to,
                                         "frames": String(batch.count),
                                         "delivered": String(delivered)]))
        return batch.count
    }

    /// Carry `from`'s queued ACK traffic to `to` over a DIRECT link: the node's own
    /// recipient ACKs (the T37 outbox) AND the bounded relay custody its T84 pump
    /// holdeth.
    @discardableResult
    public func turnAcks(_ from: String, _ to: String) -> Int {
        guard let a = nodes[from], let b = nodes[to] else { return 0 }
        if !isLinked(from, to) { return 0 }
        let own = a.node.drainAckOutboxForLink(ComposedRuntimeHarness.maxAcksPerTurn)
        a.ackPump.onLinkReady(b.nodeId, now: Int(clock.wallSeconds() * 1000))
        let relay = a.ackPump.nextBatch(b.nodeId, now: Int(clock.wallSeconds() * 1000)).copies
        var delivered = 0
        for ack in own {
            if hand(a, toLabel: to, bytes: ack.encode()) { delivered += 1 }
        }
        for copy in relay {
            if hand(a, toLabel: to, bytes: copy.encodedFrame) { delivered += 1 }
            a.ackPump.onForwardOutcome(copy, peer: b.nodeId, accepted: true,
                                       now: Int(clock.wallSeconds() * 1000))
        }
        trace.append(TraceEvent(kind: "turn_acks", atMonoMillis: clock.monoMillis(),
                                fields: ["from": from, "to": to, "own": String(own.count),
                                         "relay": String(relay.count), "delivered": String(delivered)]))
        return own.count + relay.count
    }

    /// REPLAY exact captured bytes over a link: the honest "replay after
    /// reconnect" -- the same frame the radio carried once, offered again.
    @discardableResult
    func replay(_ from: String, to: String, bytes: Data) -> Bool {
        guard let a = nodes[from], let b = nodes[to] else { return false }
        if !isLinked(from, to) { return false }
        trace.append(TraceEvent(kind: "replay", atMonoMillis: clock.monoMillis(),
                                fields: ["from": from, "to": to, "bytes": String(bytes.count)]))
        guard link.offer(fromLabel: a.label, toLabel: to, bytes: bytes) else { return false }
        guard let frame = FrameV2.decode(bytes) else { return false }
        // the replay RE-ENTERETH the receiving node's own statute
        trace.append(TraceEvent(kind: "replay_ingested", atMonoMillis: clock.monoMillis(),
                                fields: ["from": from, "to": to,
                                         "msg_id": ComposedRuntimeHarness.hex(frame.msgId)]))
        return b.node.ingestInbound(frame, receivedFrom: a.nodeId)
    }

    /// The durable checkpoint of one node's estate.
    public func checkpoint(_ label: String) throws -> DurableCheckpoint {
        guard let n = nodes[label] else { throw TraceSchemaError(reason: "no node \(label)") }
        let ids = n.store.allHeldMsgIds()
        var rows: [String: String] = [:]
        for id in ids {
            if case .found(let rec) = n.tracker.lookup(id) {
                rows[ComposedRuntimeHarness.hex(id)] = "\(rec.state)"
            } else {
                rows[ComposedRuntimeHarness.hex(id)] = "ABSENT"
            }
        }
        let cp = DurableCheckpoint(atMonoMillis: clock.monoMillis(),
                                   heldDigest: ComposedRuntimeHarness.digest(ids),
                                   heldCount: ids.count, rows: rows,
                                   offeredToLinks: n.node.linkOffers.total())
        trace.checkpoint(cp)
        return cp
    }

    public func traceSnapshot() -> MeshTrace { trace }

    public func capturedBytes() -> [Data] { link.deliveries().map { $0.bytes } }

    /// Replay a FOREIGN isle's trace document against THIS isle's trace reader.
    public func replay(_ document: [String: Any]) throws -> [TraceEvent] {
        try MeshTrace.parse(document)
    }

    private func label(of nodeId: Data) -> String? {
        nodes.values.first { $0.nodeId == nodeId }?.label
    }

    /// Compose a real `MeshIdentity` through the production keychain road (the OS
    /// keystore is the facade this harness substitutes).
    /// A transport handle's LABEL: the peer it reacheth, or the handle itself when
    /// the harness carrieth no link for it. It nameth the LINK, never a recipient.
    func transportLabel(_ peer: UUID) -> String {
        handleLabels[peer] ?? "link:\(peer.uuidString)"
    }

    static func makeIdentity(seed: Data, xSeed: Data) throws -> MeshIdentity {
        let kc = HarnessIdentityKeychain()
        let state = try LocalIdentityStateV1(generation: 0, ed25519Seed: seed, x25519PrivateKey: xSeed)
        kc.storage[MeshIdentity.v1Tag] = state.encode()
        return try MeshIdentity.loadFromKeychain(keychain: kc)
    }

    public static func hex(_ bytes: Data) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    public static func digest(_ parts: [Data]) -> String {
        var hasher = SHA256()
        for p in parts.sorted(by: { hex($0) < hex($1) }) { hasher.update(data: p) }
        return hex(Data(hasher.finalize()))
    }
}

// ---------------------------------------------------------------- seams

/// GS-SOS-001 (the iOS isle): the SOS signing authority for the COMPOSED and
/// COURT roads. It is **test and harness support that liveth in main only
/// because the composed harness is itself main-side**, mirroring the Android
/// isle's `SimulatedSosAuthority` (`runtime/ComposedRuntime.kt`).
///
/// WHAT IT IS NOT: it is NOT a device, radio or production result. The
/// `fixed()` material is public by construction and is used only by courts that
/// assert delivery/queueing outcomes and never authenticate the frame under a
/// node's own binding; the harness instead passeth the seed IT generated for the
/// node, so the composed arms sign with the same material the harness already
/// trusts for ACKs. Production wireth no authority at all, and therefore
/// REFUSES to offer an unauthenticated distress call (the card's own law).
final class SimulatedSosAuthority: SosSigningAuthority, @unchecked Sendable {
    private let seed: Data
    private let dhPublicKey: Data
    private let generation: UInt32
    private let issuedBinding: IdentityBindingV1
    private let clock: () -> Int64
    private let nonce: () -> Data

    init(seed: Data, dhPublicKey: Data, generation: UInt32,
         binding: IdentityBindingV1,
         clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970) },
         nonce: @escaping () -> Data = { MessageId.generateNonce() }) {
        self.seed = seed
        self.dhPublicKey = dhPublicKey
        self.generation = generation
        self.issuedBinding = binding
        self.clock = clock
        self.nonce = nonce
    }

    func currentNonce() -> Data { nonce() }
    func currentSigningSeed() -> Data? { seed }
    func currentStaticDhPublicKey() -> Data? { dhPublicKey }
    func currentGeneration() -> UInt32 { generation }
    /// GS-SOS-001, second defect: the authority ISSUETH; the sender never strikes its own.
    func currentIdentityBinding() -> IdentityBindingV1? { issuedBinding }
    func currentTimeEpochSeconds() -> Int64 { clock() }
}

/// A per-node key directory: a node resolveth only the keys it was trusted with.
final class MutableKeyTable: RecipientKeyResolver, @unchecked Sendable {
    private let lock = NSLock()
    private var table: [Data: Data] = [:]
    public init() {}
    func put(_ nodeId: Data, _ key: Data) {
        lock.lock(); table[nodeId] = Data(key); lock.unlock()
    }
    func publicSigningKey(forNodeId nodeId: Data) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return table[nodeId].map { Data($0) }
    }
}

/// The OS keystore facade the harness substitutes for the platform keychain.
final class HarnessIdentityKeychain: LocalIdentityKeychain, @unchecked Sendable {
    var storage: [String: Data] = [:]
    func read(tag: String) throws -> Data? { storage[tag] }
    func add(tag: String, data: Data) throws { storage[tag] = data }
    func delete(tag: String) throws { storage[tag] = nil }
}

/// The local signing identity as the inbox's seam seeth it.
final class TestAckSigner: AckSignerSeam, @unchecked Sendable {
    private let idBytes: Data
    private let seed: Data
    init(nodeId: Data, seed: Data) { self.idBytes = Data(nodeId); self.seed = Data(seed) }
    var nodeId: Data? { Data(idBytes) }
    func generation() -> Int64 { 1 }
    func signingSeed(msgId: Data, recipientNodeId: Data) throws -> Data? { Data(seed) }
}

/// The lab trust authority: a binding arrives already validated by the session's
/// own handshake, so applying it is a no-op that stores nothing.
final class ComposedTrustAuthority: PeerBindingTrustAuthority, @unchecked Sendable {
    init() {}
    func applyValidatedBinding(_ binding: ValidatedPeerBinding) -> PeerTrustApplyResult {
        .accepted
    }
}

/// The composed delivery repository over the composed store.
final class ComposedDeliveryRepository: DeliveryRepository, @unchecked Sendable {
    private let store: InMemoryMessageStore
    private var records: [Data: DeliveryRecord] = [:]
    private let lock = NSLock()

    init(_ store: InMemoryMessageStore) { self.store = store }

    func get(_ msgId: Data) -> DeliveryLookup {
        if msgId.count != 16 { return .invalidArgument }
        lock.lock()
        if let rec = records[msgId] { lock.unlock(); return .found(rec) }
        lock.unlock()
        guard let row = store.readDeliveryRow(msgId) else { return .notFound }
        guard let state = DeliveryState.fromPersistedCode(row.state) else { return .corrupt }
        guard let mode = AckMode.fromCode(row.ackMode) else { return .corrupt }
        let rec = DeliveryRecord(msgId: msgId, state: state, ackMode: mode,
                                 expectedRecipientNodeId: row.expectedRecipient)
        lock.lock(); records[msgId] = rec; lock.unlock()
        return .found(rec)
    }

    func enqueue(_ msgId: Data, ackMode: AckMode, expectedRecipient: Data?) -> EnqueueResult {
        if msgId.count != 16 { return .invalidArgument }
        switch get(msgId) {
        case .notFound:
            let rec = DeliveryRecord(msgId: msgId, state: .queuedDurably, ackMode: ackMode,
                                     expectedRecipientNodeId: expectedRecipient)
            lock.lock(); records[msgId] = rec; lock.unlock()
            return .created
        case .found(let rec):
            if rec.state.isTerminal { return .rejectedTerminalState }
            if rec.ackMode != ackMode { return .conflictRecipient }
            return .alreadyQueuedSameBinding
        default:
            return .storageFailure
        }
    }

    func transition(_ msgId: Data, _ transition: DeliveryTransition) -> TransitionResult {
        guard case .found(let rec) = get(msgId) else { return .unknownMessage }
        let target: DeliveryState
        switch transition {
        case .expire: target = .expired
        case .cancel: target = .cancelledLocally
        case .markHanded: target = .handedToRelay
        }
        if rec.state == target { return .alreadyInTarget }
        if rec.state.isTerminal { return .rejectedState }
        let updated = DeliveryRecord(msgId: rec.msgId, state: target, ackMode: rec.ackMode,
                                     expectedRecipientNodeId: rec.expectedRecipientNodeId)
        lock.lock(); records[msgId] = updated; lock.unlock()
        return .applied
    }

    public func clear(_ msgId: Data) -> ClearResult { .alreadyAbsent }

    func acknowledgeBoundAndRetire(_ msgId: Data, expectedRecipient: Data) -> AckResult {
        if msgId.count != 16 || expectedRecipient.count != 16 { return .invalidArgument }
        guard case .found(let rec) = get(msgId) else { return .unknownMessage }
        if rec.state == .acknowledgedByRecipient { return .duplicateAuthenticatedAck }
        if rec.state.isTerminal { return .rejectedState }
        if rec.ackMode != .singleRecipient { return .notAckEligible }
        guard let bound = rec.expectedRecipientNodeId else { return .corrupt }
        if bound != expectedRecipient { return .rejectedState }
        let updated = DeliveryRecord(msgId: rec.msgId, state: .acknowledgedByRecipient,
                                     ackMode: rec.ackMode,
                                     expectedRecipientNodeId: rec.expectedRecipientNodeId)
        lock.lock(); records[msgId] = updated; lock.unlock()
        return .applied
    }
}

// MARK: - CRYPTO-005: THE DURABLE SEND PATH (the composition's exposed command)

extension ComposedNode {
    /// *** CRYPTO-005: **THE COMPOSITION'S DURABLE SEND** -- the send path that PINS THE INTENT BEFORE THE FRAME REACHETH THE RADIO, which is what
    /// this lab's own comment above its in-memory path already claimeth ("the durable enqueue happeneth FIRST") and what `SendDirectAuthority` --
    /// with an `OutboundIntentJournal` -- is FOR. ***
    ///
    /// IT IS **ADDITIVE**: the existing `sendDirect` path is untouched, so nothing that stood before this finding changes behaviour; this method is
    /// the one that carrieth the durable property, and it is the one the audit's closure test invoketh.
    ///
    /// AND IT USES **ONLY WHAT THE NODE ALREADY HOLDETH** -- `identity`, `signingKeySeed()`, `node.router`, `keys` -- BESIDE A DURABLE STORE BESIDE
    /// THE COMPOSITION, WHICH IS THE ONE SUBSTITUTION THIS FINDING MUST MAKE (an in-memory store cannot carry an intent across a process).
    func sendDirectDurable(_ intentId: Data, recipient b: ComposedNode, plaintext: Data,
                           storeURL: URL) async throws -> SendDirectResult {
        // *** THE TRUST PIN -- AND IT IS THE LINE ROUND 509's COURT NAMED: the lab's OWN in-memory path maketh this explicit
        // (`a.trust(nodeId: b.nodeId, signingKey: b.identity.signingPublicKey)` at :486) WHILE THE DURABLE PATH ASSUMED IT, SO THE AUTHORITY'S
        // RESOLVER ANSWERED `.absent` AND THE SEND REFUSED WITH `recipientAbsent` -- THE VERY SYMPTOM THAT OPENED THIS FINDING AT ROUND 430.
        // THE PIN BELONGETH HERE, IN THE COMPOSITION, RATHER THAN IN A COURT: A SEND PATH THAT DEPENDETH ON A CALLER HAVING TRUSTED THE
        // RECIPIENT IS A PATH THAT CAN BE CALLED UNTRUSTED. ***
        trust(nodeId: b.nodeId, signingKey: b.identity.signingPublicKey)

        // WIRING 1: THE DURABLE STORE -- the same `SqliteMessageStore` the runtime uses, over a caller-named path (so a court can REOPEN it).
        let durableStore = try SqliteMessageStore(url: storeURL, maxBytes: 64 * 1024 * 1024)
        // AND THE COMPOSITION TAKETH **OWNERSHIP** OF WHAT IT CREATED, so that ITS OWN WIPE can reach it (GS-INTEGRATION-001: a wipe that owns nothing
        // has nothing to reach -- which is exactly the measured RED of round 514).
        ownerHarness?.registerDurableStore(storeURL)
        // WIRING 2: THE AUTHORITY ON THE NODE'S OWN MATERIAL, over both adapters and THE DURABLE JOURNAL.
        let authority = SendDirectAuthority(
            identity: identity,
            signingKeys: SigningKeysAdapter(seed: signingKeySeed(), pub: identity.signingPublicKey),
            router: node.router,
            store: durableStore,
            trustResolver: KeyTableTrustResolver(
                signingKeyForNodeId: { [keys] nodeId in keys.publicSigningKey(forNodeId: nodeId) },
                // THE LAB'S TRUST TABLE CARRIETH A SIGNING KEY PER NODE ID AND NOTHING ELSE, so the static-DH half cometh from the NODE'S OWN
                // BINDING MATERIAL -- the same accessor the lab's in-memory path already useth for a recipient's static half.
                staticDhForNodeId: { _ in self.identity.staticDhPublicKey },
                // AND A TABLE THAT CARRIETH NO GENERATION CANNOT INVENT ONE: the lab trusteth a node id and a signing key with no version of
                // that binding, so the FIRST generation is named here AS A DECISION rather than smuggled in as a fact.
                generationForNodeId: { _ in 1 }),
            // THE DURABLE JOURNAL: the property the audit found absent from BOTH the runtime and this composition.
            journal: SqliteOutboundIntentJournal(store: durableStore))
        // WIRING 3: THE SEND THROUGH THE AUTHORITY -- the intent is pinned in `outbound_intents` before the frame is authored.
        guard let command = SendDirectCommand.of(intentId: intentId, recipientTrustRef: b.nodeId, bodyUtf8: [UInt8](plaintext)) else {
            return .rejected(reason: .enqueueInvalidArgument)
        }
        return await authority.sendDirect(command)
    }
}
