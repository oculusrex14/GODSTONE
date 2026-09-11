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
        // A coarse Transport.stop() severs every live session; the authority counts the
        // drain, so report one logical disconnect sweep.
        return 1
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
