import Foundation
import GodstoneCore

// ---------------------------------------------------------------------------
// T54 -- the LabMesh runtime seam, living INSIDE the nonshipping GodstoneMesh
// module. The Swift twin of android/mesh/src/main/java/io/godstone/mesh/lab/
// LabRuntime.kt, with the SAME laws.
//
// It liveth here rather than in the lab application target for one honest
// reason: the composed runtime is built from authorities that are internal to
// GodstoneMesh, and publishing them all would widen a nonshipping-but-delicate
// surface for the convenience of a lab. So the lab ENTRY is a small PUBLIC
// handle with a deliberately narrow surface -- labels, an honest readiness
// statement, a durable state name -- and everything else (the store, the
// tracker, the inbox, the ACK authority) stayeth inside.
//
// Law 1: THE LAB COMPOSETH REAL COMPONENTS -- the production MeshNode over the
// real router, the real durable store, the real DeliveryTracker, the real
// recipient inbox and the real T84 ACK authority, through T44's harness.
// Law 2: THE LAB CANNOT MANUFACTURE READINESS -- no setter, no override, no flag
// writer; MANUFACTURES_READINESS is a compile-time false and the readiness
// statement carrieth no parameter.
// Law 3: THE LAB IS VISIBLY EXPERIMENTAL AND NONSHIPPING.
// ---------------------------------------------------------------------------

/// What the lab reporteth about itself, in one place.
public enum LabProfile {
    public static let name: String = "LABMESH"
    public static let experimental: Bool = true

    /// True iff this build can manufacture crypto readiness. It CANNOT, and the
    /// constant is `false` so a reader -- and the profile gate -- seeth the claim
    /// rather than inferring it from the absence of a setter.
    public static let manufacturesReadiness: Bool = false

    /// The shipping bundle identity the lab may never masquerade as.
    public static let shippingBundleId: String = "io.godstone.app"

    /// The lab's own bundle identity, distinct from the shipping one.
    public static let labBundleId: String = "io.godstone.labmesh"
}

/// The honest readiness statement: every platform field is FALSE.
public struct LabReadiness: Sendable, Equatable {
    public let androidLinkLayerReady: Bool
    public let iosLinkLayerReady: Bool
    public let profile: String
    public let experimental: Bool
}

/// The lab runtime handle.
public final class LabRuntime: @unchecked Sendable {
    private let harness: ComposedRuntimeHarness
    public let labels: [String]

    private init(harness: ComposedRuntimeHarness, labels: [String]) {
        self.harness = harness
        self.labels = labels
    }

    /// The honest readiness statement. It carrieth no parameter, so no caller can
    /// argue it into saying true.
    public static func readinessStatement() -> LabReadiness {
        LabReadiness(androidLinkLayerReady: false, iosLinkLayerReady: false,
                     profile: LabProfile.name, experimental: LabProfile.experimental)
    }

    /// Compose `labels.count` real peers and link them in a chain, so a message
    /// from the first to the last travelleth through a real relay.
    public static func compose(labels: [String] = ["A", "R", "B"],
                               seedByte: UInt8? = nil) throws -> LabRuntime {
        guard labels.count >= 2 else {
            throw LabRuntimeError(reason: "a lab runtime needs at least two peers")
        }
        guard Set(labels).count == labels.count else {
            throw LabRuntimeError(reason: "lab labels must be distinct")
        }
        let clock = FixedHostClock()
        let harness = ComposedRuntimeHarness(clock: clock, link: LinkFacade(clock: clock))
        var next = seedByte ?? 0x11
        for label in labels {
            _ = try harness.addNode(label, seedByte: next)
            next = next &+ 0x10
        }
        for i in 0..<(labels.count - 1) {
            _ = harness.link(labels[i], labels[i + 1])
        }
        return LabRuntime(harness: harness, labels: labels)
    }

    /// The durable state of one message, by NAME (a String, so no internal type
    /// crosses this seam).
    public func durableStateName(_ nodeLabel: String, _ msgId: Data) -> String? {
        guard let node = harness.node(nodeLabel) else { return nil }
        if case .found(let rec) = node.tracker.lookup(msgId) { return "\(rec.state)" }
        return nil
    }

    /// How many messages the named node durably holdeth.
    public func heldCount(_ nodeLabel: String) -> Int {
        harness.node(nodeLabel)?.store.allHeldMsgIds().count ?? 0
    }

    /// Author one DIRECT message at `from` FOR `recipient`.
    public func sendDirect(_ from: String, recipient: String, plaintext: Data) async -> String {
        do {
            return describe(try await harness.sendDirect(from, recipient: recipient, plaintext: plaintext))
        } catch {
            return "refused:\(error)"
        }
    }

    /// Author one SOS broadcast at `from`.
    public func sendSos(_ from: String, plaintext: Data) async -> String {
        describe(await harness.sendSos(from, plaintext: plaintext))
    }

    /// One bounded sync turn from `from` to `to`.
    @discardableResult public func turn(_ from: String, _ to: String) -> Int { harness.turn(from, to) }

    /// Carry `from`'s queued ACK traffic to `to`.
    @discardableResult public func turnAcks(_ from: String, _ to: String) -> Int { harness.turnAcks(from, to) }

    /// A trusted relation comes up (both layers).
    @discardableResult public func link(_ from: String, _ to: String) -> String { describe(harness.link(from, to)) }

    /// A trusted relation goes down.
    @discardableResult public func unlink(_ from: String, _ to: String) -> String { describe(harness.unlink(from, to)) }

    /// The exact bytes a link carried.
    public func capturedBytes() -> [Data] { harness.capturedBytes() }

    /// How many link hand-offs were admitted.
    public func admittedCount() -> Int { harness.link.admitted() }

    private func describe(_ outcome: ComposedOutcome) -> String {
        switch outcome {
        case .applied(let detail): return "applied:" + detail
        case .refused(let reason, _): return "refused:" + reason.rawValue
        }
    }
}

public struct LabRuntimeError: Error, Equatable { public let reason: String }
