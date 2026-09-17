import Foundation

/// GS-STORE-006: **THE PRODUCTION `TransportRuntimeSeam`** -- the first of the five adapters that finding's card
/// requireth, and the one whose absence the audit measured ("the composition still invokes old PanicWipe through
/// invalidators that own sessions and stores but NO TRANSPORT").
///
/// **IT INVENTETH NOTHING.** The drain is expressed in the transport's OWN terms, read rather than chosen:
///   * `stop()` -- the transport's own teardown verb (BleTransport.swift), to CLOSE ADMISSION;
///   * `barrierOnActiveContext()` -- a barrier on THE ACTIVE CONTEXT'S OWN EXECUTOR, whose `queue.sync { withSerial(...) }`
///     waiteth for every previously-enqueued reduction; **THE RETURN OF THAT CALL IS THE DRAINED POINT**, the same road
///     the transport's own teardown useth (which is what the transport promiseth: "so the authority receiveth a
///     MEASUREMENT rather than the assumption").
///
/// SO THE RECEIPT IS **EARNED RATHER THAN ASSERTED**: this adapter reporteth `.drained` because a barrier on the
/// transport's own queue RETURNED, not because the adapter sayeth so. (The first draft of this file asked the
/// `BleTransport` itself for `serialise` and THE COMPILER REFUSED IT IN ONE LINE -- the barrier belongeth to the
/// EXECUTOR, not to the transport -- which is why the door above existeth and why the object was read rather than
/// inferred from the road it lieth on.)
///
/// THE TWO SEND VERBS: `fireRadio`/`sendVia` are the seam's "can the radio still carry anything" probes, and THIS SEAM
/// NEVER SENDS -- it existeth to DEMONSTRATE an absence after the drain. They therefore answer `false` while the seam
/// standeth quiesced (the only state a wipe consulteth them in), and they answer `true` BEFORE a drain only to say
/// truthfully that the radio is still live.
public final class WipeTransportDrainSeam: TransportRuntimeSeam, @unchecked Sendable {
    private let transport: BleTransport
    private let lock = NSLock()
    /// Whether THIS process lifetime hath drained the transport. A reboot starteth un-quiesced, which is the seam's own
    /// contract ("Whether THIS process lifetime hath drained the transport; a reboot starts un-quiesced").
    private var quiescedThisLifetime = false

    public init(transport: BleTransport) {
        self.transport = transport
    }

    public func drainTransport() -> RuntimeDrainReceipt {
        lock.lock()
        defer { lock.unlock() }
        transport.stop()                      // close admission FIRST, so nothing new is admitted behind the barrier
        _ = transport.barrierOnActiveContext() // THE BARRIER: it cannot return until every queued reduction completed
        quiescedThisLifetime = true
        return .drained(closedTransports: 1, quiescedRuntime: true)
    }

    public func isQuiesced() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return quiescedThisLifetime
    }

    public func fireRadio(_ msg: String) -> Bool {
        _ = msg
        return !isQuiesced()
    }

    public func sendVia(_ msg: String) -> Bool {
        _ = msg
        return !isQuiesced()
    }
}
