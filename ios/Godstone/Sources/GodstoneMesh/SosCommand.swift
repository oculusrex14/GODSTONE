import Foundation

// T39 (section 14): the SOS command surface -- Author, Retry, Cancel -- and the
// durable projections the one authority exposes. The card's word: "Commit SOS held
// frame plus NONE-mode delivery row atomically. Expose active SOS from that row.
// Cancel marks terminal and removes scheduled/held work transactionally; it
// cannot retract already relayed copies and UI says so. Retry resumes the same
// authored SOS bytes."
//
// The commands are data, not side effects: executing them belongs to MeshNode
// (handleSosCommand / dispatchSos / retrySos / cancelSos), which routes every
// mutation of BOTH tables -- held frames and delivery rows -- through the single
// durable authority (the store-backed repository, or the SQL store's own
// transaction over the shared handle). No command mutates authoritative state on
// a validation failure; each typed result distinguishes failure from the
// idempotent no-op. Data is byte-equal by value, so duplicate logical records
// are detected, not silently doubled.

/// One command of the distress lifecycle. Identity is by msg_id; the payload
/// is the user's bytes, never interpreted here.
public enum SosCommand: Sendable, Equatable {
    /// Author a fresh distress call: the node composes the frame (the T38
    /// signed-SOS authority when wired, the documented legacy shape otherwise)
    /// and commits held frame + NONE-mode row as ONE durable pair.
    case author(Data)
    /// Resume the SAME authored bytes of a still-live call (never re-derive:
    /// the msg_id is immutable content; a retry that re-authored would betray
    /// it). A terminal row refuses the resume.
    case retry(Data)
    /// Cancel one call durably: guarded terminal CAS on the row plus removal of
    /// the scheduled/held work, transactionally in the one authority. Already
    /// relayed copies cannot be recalled -- the result says so, the UI must say
    /// so too. Duplicate cancellation is idempotent, never an error.
    case cancel(Data)
}

/// The durable Active-SOS projection: read FROM the delivery row (state, mode)
/// joined with the held frame and its receipt stamp -- never from a UI memory.
/// Broadcast shows local queue and offers only; it never claims
/// recipient-delivered or guaranteed rescue.
public struct ActiveSos: Sendable, Equatable {
    public let msgId: Data
    public let state: DeliveryState
    public let frame: FrameV2
    /// When this node committed the pair, when it remembers; nil when the
    /// tables cannot name the instant (honest silence over a fabricated clock).
    public let committedAtMillis: Int64?

    public init(msgId: Data, state: DeliveryState, frame: FrameV2, committedAtMillis: Int64?) {
        self.msgId = msgId
        self.state = state
        self.frame = frame
        self.committedAtMillis = committedAtMillis
    }

    /// True when the row has been handed to at least one relay: the UI must
    /// then say that already relayed copies cannot be recalled.
    public var relayed: Bool { state == .handedToRelay }
}

/// Typed outcome of the Cancel arm (C6.4-A discipline: a failed destructive
/// operation is never indistinguishable from success, and an idempotent no-op
/// is named apart from a fresh cancellation).
public enum SosCancelResult: Sendable, Equatable {
    /// This call cancelled: the row moved to cancelledLocally and the held
    /// frame was removed in the one transaction. `wasRelayed` is the truth of
    /// whether bytes had already gone out at the moment of cancellation --
    /// the UI must say it: "already relayed copies cannot be recalled".
    case cancelled(wasRelayed: Bool)
    /// The call was already cancelled (or its row had reached this terminal
    /// state by another path): idempotent, nothing moved. `wasRelayed` is nil
    /// when the fact can no longer be derived from the row itself -- an honest
    /// silence, not a guess.
    case alreadyCancelled(wasRelayed: Bool?)
    /// The row is terminal in a way cancellation may not overwrite (expired,
    /// acknowledged): refused, nothing moved.
    case rejectedTerminal(DeliveryState)
    /// A singleRecipient obligation is not this broadcast authority's to
    /// cancel: refused, nothing moved (the directed path owns its own retire
    /// machinery).
    case notBroadcast
    /// Nothing was found for this msg_id: failure, not an empty success.
    case unknownMessage
    /// The row (or its pair) is corrupt on read: fail closed, nothing moved.
    case corrupt
    /// A storage failure during the guarded transaction: rolled back whole.
    case storageFailure
    /// The command was not well-formed (widths): refused before any write.
    case invalidArgument
}

/// The unified outcome of `MeshNode.handleSosCommand`: which arm ran and what
/// its durable result was. No arm reports success it did not achieve; the
/// dispatch arm's taxonomy is the established `SosDispatchResult`, the cancel
/// arm's is `SosCancelResult` -- one envelope, two honest payloads.
public enum SosCommandResult: Sendable, Equatable {
    case enqueued(SosDispatchResult)
    case cancelled(SosCancelResult)
}
