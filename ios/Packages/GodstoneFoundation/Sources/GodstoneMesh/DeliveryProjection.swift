import Foundation

// ---------------------------------------------------------------------------
// T43 -- "Align delivery labels with durable evidence". The Swift twin of
// android/mesh/src/main/java/io/godstone/mesh/delivery/DeliveryProjection.kt
//
// The card's defect: "A Boolean send currently advances HANDED_TO_RELAY even
// though it only proves local ATT admission." A message whose bytes a local radio
// accepted was recorded as durably handed to a relay -- a custody claim the node
// could not honour, and one a restart would keep repeating. The laws:
//
//   1. THE DURABLE STATE IS THE ONLY LABEL. QUEUED_DURABLY standeth until an
//      authenticated ACK from the INTENDED recipient produceth
//      ACKNOWLEDGED_BY_RECIPIENT. Nothing local moveth it.
//   2. A LINK OFFER IS EPHEMERAL TELEMETRY: never persisted, never surviveth a
//      restart, and never calleth itself custody or delivery.
//   3. THE PROJECTION CLAIMETH NO MORE THAN THE DURABLE STATE SUPPORTETH. An
//      offer distinguisheth QUEUED from OFFERED; BOTH remain retryable;
//      DELIVERED requireth the ACK.
//   4. LEGACY ROWS ARE MIGRATED CONSERVATIVELY: a persisted handedToRelay row is
//      rewritten to queuedDurably (retryable) with its history preserved, and even
//      BEFORE the migration the projection of such a row is QUEUED.
//   5. NO RELAY RECEIPTS in this release profile.
//
// Nonshipping: the lab mesh path; readiness stays false and no device claim is
// made. Host tests prove no CoreBluetooth behaviour.
// ---------------------------------------------------------------------------

/// One LOCAL link admission: the radio accepted these bytes onto a link. It
/// proveth nothing about the recipient and is deliberately NOT durable.
public struct LinkOffer: Sendable, Equatable {
    public let msgId: Data
    /// The LINK's own identity bytes -- on this isle the transport's UUID bytes,
    /// because a transport handle is neither a node id nor a recipient (T42's
    /// law). It nameth where the bytes were offered, nothing more.
    public let linkId: Data
    public let admitted: Bool
    public let atMonoMillis: Int64
}

/// The honest label a consumer may display.
public enum DeliveryLabel: String, Sendable {
    case unavailable = "UNAVAILABLE"
    /// Durably queued and retryable: the label of a message nothing acknowledged.
    case queued = "QUEUED"
    /// Durably queued AND a local link accepted bytes at least once. STILL retryable.
    case offered = "OFFERED"
    /// The INTENDED recipient's authenticated ACK committed. The only delivery claim.
    case delivered = "DELIVERED"
    case expired = "EXPIRED"
    case cancelled = "CANCELLED"
}

/// The label a consumer readeth, with everything it is derived from.
public struct DeliveryProjection: Sendable, Equatable {
    public let msgId: Data
    public let state: DeliveryState
    public let label: DeliveryLabel
    /// True exactly while the durable state is queuedDurably: an offer NEVER
    /// clear it, because an offer is not progress toward delivery.
    public let retryable: Bool
    /// ADMITTED local offers only: the ones that make the label OFFERED.
    public let linkOffers: Int
    /// Offered-but-refused local attempts: telemetry, and they raise no label.
    public let refusedOffers: Int
    public let lastOfferMonoMillis: Int64?
    public let legacyHandedToRelay: Bool

    public var claimsDelivery: Bool { label == .delivered }
    /// True only when the durable state (not an offer) sayeth a relay holdeth it.
    public var claimsRelayCustody: Bool { state == .handedToRelay }

    /// Derive the honest label. A legacy `handedToRelay` row is treated as the
    /// queued estate it always was (law 4).
    public static func of(_ msgId: Data, state: DeliveryState, linkOffers: Int = 0,
                          refusedOffers: Int = 0,
                          lastOfferMonoMillis: Int64? = nil) -> DeliveryProjection {
        let legacy = state == .handedToRelay
        let effective: DeliveryState = legacy ? .queuedDurably : state
        let label: DeliveryLabel
        switch effective {
        case .unavailable: label = .unavailable
        case .queuedDurably: label = linkOffers > 0 ? .offered : .queued
        case .acknowledgedByRecipient: label = .delivered
        case .expired: label = .expired
        case .cancelledLocally: label = .cancelled
        case .handedToRelay: label = .queued   // unreachable: mapped above
        }
        return DeliveryProjection(msgId: Data(msgId), state: effective, label: label,
                                  retryable: effective == .queuedDurably,
                                  linkOffers: linkOffers, refusedOffers: refusedOffers,
                                  lastOfferMonoMillis: lastOfferMonoMillis,
                                  legacyHandedToRelay: legacy)
    }

    /// A refused read: a corrupt or absent row is never labelled queued.
    public static func unavailable(_ msgId: Data) -> DeliveryProjection {
        DeliveryProjection(msgId: Data(msgId), state: .unavailable, label: .unavailable,
                           retryable: false, linkOffers: 0, refusedOffers: 0,
                           lastOfferMonoMillis: nil, legacyHandedToRelay: false)
    }
}

/// The bounded, ephemeral ledger of local link admissions. Memory only by
/// construction -- no persist, no load, no store dependency -- so no offer can
/// ever become a durable claim.
public final class LinkOfferLedger: @unchecked Sendable {
    /// The bound: telemetry only, so drop-oldest is honest and sufficient.
    public static let maxOffers: Int = 512

    private let lock = NSLock()
    private let bound: Int
    private var offers: [LinkOffer] = []
    private var dropped: Int64 = 0

    public init(bound: Int = LinkOfferLedger.maxOffers) {
        precondition(bound > 0, "the ledger bound must be positive")
        self.bound = bound
    }

    @discardableResult
    public func record(_ msgId: Data, linkId: Data, admitted: Bool, atMonoMillis: Int64) -> LinkOffer {
        precondition(msgId.count == 16, "a link offer names a 16-octet msg_id")
        precondition(!linkId.isEmpty, "a link offer names the link it was offered on")
        let offer = LinkOffer(msgId: Data(msgId), linkId: Data(linkId),
                              admitted: admitted, atMonoMillis: atMonoMillis)
        lock.lock(); defer { lock.unlock() }
        while offers.count >= bound {
            offers.removeFirst()
            dropped += 1
        }
        offers.append(offer)
        return offer
    }

    public func offersFor(_ msgId: Data) -> [LinkOffer] {
        lock.lock(); defer { lock.unlock() }
        return offers.filter { $0.msgId == msgId }
    }

    public func countFor(_ msgId: Data) -> Int {
        lock.lock(); defer { lock.unlock() }
        return offers.filter { $0.msgId == msgId }.count
    }

    /// ADMITTED attempts only: these are what raise the label to OFFERED.
    public func admittedCountFor(_ msgId: Data) -> Int {
        lock.lock(); defer { lock.unlock() }
        return offers.filter { $0.msgId == msgId && $0.admitted }.count
    }

    /// Refused attempts: telemetry that raiseth NO label.
    public func refusedCountFor(_ msgId: Data) -> Int {
        lock.lock(); defer { lock.unlock() }
        return offers.filter { $0.msgId == msgId && !$0.admitted }.count
    }

    /// True iff a radio ADMITTED these bytes at least once: "copies may be out".
    public func anyAdmitted(_ msgId: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return offers.contains { $0.msgId == msgId && $0.admitted }
    }

    public func lastOfferMonoFor(_ msgId: Data) -> Int64? {
        lock.lock(); defer { lock.unlock() }
        return offers.last { $0.msgId == msgId }?.atMonoMillis
    }

    public func total() -> Int {
        lock.lock(); defer { lock.unlock() }
        return offers.count
    }

    public func droppedCount() -> Int64 {
        lock.lock(); defer { lock.unlock() }
        return dropped
    }

    /// Everything this ledger knoweth vanisheth with the process.
    public func clear() {
        lock.lock(); defer { lock.unlock() }
        offers.removeAll()
        dropped = 0
    }
}

/// T43 law 4 -- the LEGACY label migration, the Swift twin of the Android object.
/// Before T43 a Boolean send advanced the durable row to `handedToRelay`, which
/// only ever proved a local ATT admission. Those rows are migrated
/// CONSERVATIVELY back to `queuedDurably` (retryable), and the fact of the legacy
/// label is preserved rather than erased. The rewrite is a data step the T31
/// migration engine runneth inside its own transaction.
public enum LegacyHandedLabels {
    /// The persisted code of the legacy label (`DeliveryState.handedToRelay`).
    public static let legacyCode: Int32 = 2
    /// The persisted code every legacy row migrateth TO (`queuedDurably`).
    public static let migratedCode: Int32 = 1
    /// The revision this migration belongeth to (the T31 engine's `to`).
    public static let toRevision: Int = 2

    /// The statements the engine executeth: one guarded rewrite, nothing deleted.
    public static func statements(table: String = "delivery_state",
                                  column: String = "state") -> [String] {
        ["UPDATE \(table) SET \(column) = \(migratedCode) WHERE \(column) = \(legacyCode)"]
    }

    /// The T31 step itself: the apply rewriteth every legacy row THROUGH the
    /// injected executor, so the whole step stayeth transactional and a crash
    /// leaveth the store at the prior revision.
    public static func step(table: String = "delivery_state",
                            column: String = "state",
                            history: NSMutableArray? = nil) -> MigrationStep {
        let sql = statements(table: table, column: column)
        let declared = MigrationStep(from: 1, to: toRevision, statements: sql, apply: nil)
        return MigrationStep(from: 1, to: toRevision, statements: sql, apply: { executor in
            // MigrationApply is non-throwing by contract: a faulting executor is
            // the engine's own concern (it rolls the whole step back), and a
            // throw here would be a harness defect, not a migration outcome.
            do {
                try executor.execute(step: declared, statements: sql)
                history?.add(legacyCode)
            } catch {
                history?.add(-1)
            }
        })
    }

    /// How a row that still carrieth the legacy code must be READ, before any
    /// migration: as a queued, retryable estate. Never as custody.
    public static func projectionForLegacyRow(_ msgId: Data, code: Int32) -> DeliveryProjection {
        guard let state = DeliveryState.fromPersistedCode(code) else {
            return DeliveryProjection.unavailable(msgId)
        }
        return DeliveryProjection.of(msgId, state: state)
    }

    /// True iff this persisted code is the legacy label the migration rewriteth.
    public static func isLegacy(_ code: Int32) -> Bool { code == legacyCode }
}
