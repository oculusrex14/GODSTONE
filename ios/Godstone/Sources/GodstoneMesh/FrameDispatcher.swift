import Foundation

// ---------------------------------------------------------------------------
// T42 -- the typed frame dispatcher (section 14's dispatch statute), the Swift
// twin of android/mesh/src/main/java/io/godstone/mesh/router/FrameDispatcher.kt.
//
// "Control dispatch order is explicit: decoded PING/HELLO/DIGEST/WANT go to the
// per-relation sync/control owner before generic Router TTL/dedup/storage; ACK
// goes to the ACK dispatcher described below; only supported MESSAGE/SOS enter
// durable message routing. Unknown/BULK control types are rejected in this
// profile."
//
// On this isle the order lived inline in MeshNode.ingestInbound. It is now a
// TYPE: [DispatchVerdict.dispatchClass] sayeth which authority owneth the frame,
// a refusal is by NAME rather than a fall-through into persistence, and the
// ACK road is the T84 dispatcher -- or, when no ack_frames namespace is bound,
// the historical point-to-point face expressed as the VERY SAME verdict type.
//
// The dispatcher ROUTES; it persisteth nothing. A `message`/`sos` verdict meaneth
// "the generic durable road is this frame's duty", and the composition runneth it.
// ---------------------------------------------------------------------------

/// Which authority owneth one inbound frame.
enum DispatchClass: String, Sendable {
    case control = "CONTROL"
    case ack = "ACK"
    case message = "MESSAGE"
    case sos = "SOS"
    case refused = "REFUSED"
}

/// Why a frame was refused at the door. Named, never a silent drop.
enum DispatchRefusal: String, Sendable {
    /// The bulk pair, GOODBYE, an unknown type: not a frame of this profile.
    case unsupportedType = "UNSUPPORTED_TYPE"
}

/// The typed verdict of one dispatch.
enum DispatchVerdict {
    /// A link control: the per-relation owner decided; any answer rides back out.
    case control(decision: SyncControlOwner.OwnerDecision, accepted: Bool)
    /// An ACK: the delivery authority, never the message road.
    case ack(AckDispatch)
    /// A supported MESSAGE: the generic durable road is its duty.
    case message
    /// A supported SOS: the generic durable road is its duty.
    case sos
    /// Refused by name: nothing is stored, nothing relayed, no trust moves.
    case refused(DispatchRefusal, String)

    var dispatchClass: DispatchClass {
        switch self {
        case .control: return .control
        case .ack: return .ack
        case .message: return .message
        case .sos: return .sos
        case .refused: return .refused
        }
    }

    var accepted: Bool {
        switch self {
        case .control(_, let accepted): return accepted
        case .ack(let dispatch): return dispatch.accepted
        case .message, .sos: return true
        case .refused: return false
        }
    }
}

/// The dispatch statute, in one place and in one order.
final class FrameDispatcher: @unchecked Sendable {
    private let owner: SyncControlOwner
    private let ackAuthority: () -> AckDispatcher?
    private let acknowledgeHistorically: (FrameV2) -> AckResult

    init(owner: SyncControlOwner,
                ackAuthority: @escaping () -> AckDispatcher?,
                acknowledgeHistorically: @escaping (FrameV2) -> AckResult) {
        self.owner = owner
        self.ackAuthority = ackAuthority
        self.acknowledgeHistorically = acknowledgeHistorically
    }

    /// One inbound frame: control, then ACK, then the generic road.
    func dispatch(_ frame: FrameV2, from peer: Data) -> DispatchVerdict {
        switch frame.type {
        case .ping, .hello, .digest, .want:
            // the per-relation owner, BEFORE policy, the seen window, the TTL
            // gate and persistence: a control frame is never content
            let decision = owner.handleControlFrame(frame, from: peer)
            return .control(decision: decision, accepted: Self.accepted(decision))
        case .ack:
            guard let authority = ackAuthority() else {
                // the historical point-to-point face, expressed as the same verdict
                return .ack(.originVerification(acknowledgeHistorically(frame)))
            }
            return .ack(authority.dispatch(frame, receivedFrom: peer))
        case .message:
            return .message
        case .sos:
            return .sos
        default:
            return .refused(.unsupportedType,
                            "the bulk pair, GOODBYE and anything unknown are refused in this " +
                            "profile (section 14 dispatch statute); nothing is stored, nothing " +
                            "is relayed, no trust is moved: \(frame.type)")
        }
    }

    /// The frames an owner decision answereth with (empty when it answereth not).
    func replies(_ decision: SyncControlOwner.OwnerDecision) -> [FrameV2] {
        switch decision {
        case .answered(let frame): return [frame]
        case .delivered(let frames): return frames
        default: return []
        }
    }

    private static func accepted(_ decision: SyncControlOwner.OwnerDecision) -> Bool {
        switch decision {
        case .accepted, .answered, .delivered: return true
        default: return false
        }
    }
}
