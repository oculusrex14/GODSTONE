import Foundation

// ---------------------------------------------------------------------------
// T28 platform-integration (iOS): the Swift twin of
// android/.../transport/LifecycleTransportAdapter.kt. It binds the fine-grained
// TransportSeam calls the UnifiedRuntimeLifecycle authority issues onto the
// coarse, transport-agnostic Transport contract, idempotently, so the lifecycle
// laws hold AT the transport boundary on BOTH isles. The concrete iOS transports
// (BleTransport / MeshNode) conform to this Transport contract in the runtime
// composition; the authority never reaches Transport.start except through a live,
// admissible activation, so a stopped/terminal runtime cannot resurrect the radio.
// ---------------------------------------------------------------------------

/// The transport-agnostic lifecycle contract the authority governs: the coarse
/// start/stop surface (plus descriptive flags) every concrete iOS transport offers.
public protocol Transport: AnyObject {
    var name: String { get }
    var isBulkCapable: Bool { get }
    func start()
    func stop()
}

/// Binds the authority's [TransportSeam] primitives onto a [Transport], mapping
/// the scanner/advertiser/disconnect primitives to the transport's coarse
/// start/stop EXACTLY once per activation/drain:
///  - the FIRST of {startScan, startAdvertising} in an activation issues one [Transport.start];
///  - the FIRST of {stopScan, stopAdvertising, disconnectAll} in a drain issues one [Transport.stop];
/// so a power-off / permission-removal / wipe uniformly stops the transport once, and
/// a stopped or terminal authority has no path to re-start it. Pure glue, no radio logic.
/// **IOS-06 step 2: A TRANSPORT THAT CAN REPORT WHAT ITS TEARDOWN ACTUALLY SEVERED.** The coarse `Transport`
/// protocol owneth only start/stop, so an adapter over a plain transport CANNOT know the count -- and that is
/// precisely why the adapter must not invent one.
public protocol DisconnectingTransport: Transport {
    /// How many live links this teardown severed. A REAL number, or none is claimed.
    func disconnectAll() -> Int
}

public final class LifecycleTransportAdapter: TransportSeam, @unchecked Sendable {
    private let transport: any Transport
    private let lock = NSLock()
    private var transportStarted: Bool = false

    public init(transport: any Transport) {
        self.transport = transport
    }

    public func startScan() { beginOnce() }
    public func startAdvertising() { beginOnce() }
    public func stopScan() { endOnce() }
    public func stopAdvertising() { endOnce() }

    public func disconnectAll() -> Int {
        endOnce()
        // **IOS-06 step 2: A REAL TEARDOWN RESULT, NOT A HARD-CODED ONE.** The audit's words, and the measurement
        // that made them exact: THIS METHOD RETURNED A LITERAL `1` with a comment calling it "one logical
        // disconnect sweep" -- **and `BleTransport` owneth NO disconnect method at all, so the number could not
        // have been measured by anybody.** A transport that CAN report answereth for itself; one that cannot
        // getteth ZERO, because a zero that meaneth "not measured" is honest, while a one that meaneth "one
        // logical sweep" masquerades as a measurement. **WHAT REMAINETH: teaching the concrete transports to
        // report (this isle's `BleTransport` carrieth no such method yet), which is named rather than implied.**
        if let reporting = transport as? DisconnectingTransport { return reporting.disconnectAll() }
        return 0
    }

    public func resetResources() {
        // Duty-cycle tables and caches are reset by the concrete transport inside its
        // own stop(); the adapter carries no separate resource to release here.
    }

    private func beginOnce() {
        lock.lock(); defer { lock.unlock() }
        if !transportStarted {
            transport.start()
            transportStarted = true
        }
    }

    private func endOnce() {
        lock.lock(); defer { lock.unlock() }
        if transportStarted {
            transport.stop()
            transportStarted = false
        }
    }
}
