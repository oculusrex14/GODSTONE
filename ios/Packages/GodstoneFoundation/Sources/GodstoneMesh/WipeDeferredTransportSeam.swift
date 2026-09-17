import Foundation

/// GS-STORE-006: **THE TRANSPORT SEAM FOR A RUNTIME THAT DOES NOT YET STAND** -- and it existeth because READING the
/// composition showed that the startup resume CANNOT have a transport: `MeshRuntime.create` performeth the resume root
/// BEFORE the runtime object existeth at all, so the node (and every transport) is built later, inside `init`.
///
/// **SO THIS SEAM SAYETH SO, RATHER THAN PRETENDING.** It NEVER answers `.drained`: it answereth `.notDrained(reason:)`
/// with the truth, WHICH STOPS THE LADDER AT `REQUESTED` -- exactly as the card's step 6 requireth ("on restart, resume
/// from the durable compatible journal BEFORE opening keys, databases, discovery or a new identity") and exactly as a
/// crash-resumable ladder is supposed to behave: **`RUNTIME_DRAINED` IS THE FIRST STAGE THAT REQUIRES A RUNNING
/// RUNTIME**, so a process that hath no runtime yet MUST NOT ADVANCE PAST IT. A seam that answered `.drained()` here
/// would let a restart erase keys while queued radio work stood -- the very charge this finding carrieth.
///
/// THE RUNTIME THAT LATER STANDS RESUMETH WITH THE LIVE SEAM (`WipeTransportDrainSeam` over `meshNode.ble`), and BECAUSE
/// THE JOURNAL NOW CARRIETH `RUNTIME_DRAINED` AS ITS OWN CHECKPOINT, the second attempt cannot mistake "we had not yet
/// drained" for "we had".
public final class WipeDeferredTransportSeam: TransportRuntimeSeam {
    /// Why no drain was performed, in the seam's own vocabulary, so a reader of a stuck wipe is TOLD rather than left
    /// guessing. It nameth the actual condition.
    public static let reason = "the runtime does not yet stand: the startup resume performeth no drain"

    public init() {}

    public func drainTransport() -> RuntimeDrainReceipt {
        return .notDrained(reason: Self.reason)
    }

    public func isQuiesced() -> Bool {
        // THIS PROCESS LIFETIME HATH DRAINED NOTHING -- and a reboot starts un-quiesced by the seam's own contract.
        return false
    }

    public func fireRadio(_ msg: String) -> Bool {
        _ = msg
        // NO RADIO STANDS YET, so nothing can be fired through this seam; a truthful `false` rather than a hopeful
        // `true`.
        return false
    }

    public func sendVia(_ msg: String) -> Bool {
        _ = msg
        return false
    }
}
