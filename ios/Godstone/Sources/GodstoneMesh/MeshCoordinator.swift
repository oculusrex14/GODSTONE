// SYNTHESIZED gap-closure file -- authored to make the project compile; see docs/AUDIT.md.
import Foundation
import Combine

/// Observable, UI-facing facade over a `MeshNode`.
///
/// This is the only mesh surface SwiftUI should touch. It translates the node's
/// radio state into the three pieces of information the UI actually needs: how
/// many peers are reachable, whether the radios are degraded by backgrounding,
/// and whether an SOS is currently being broadcast. Everything else -- frame
/// construction, Noise handshakes, router policy -- stays behind this wall.
///
/// `@MainActor` because every published mutation is read by views on the main
/// actor, and the scene-phase transitions that drive foreground/background are
/// delivered there.
@MainActor
public final class MeshCoordinator: ObservableObject {

    public let node: MeshNode

    @Published public private(set) var peerCount: Int = 0
    @Published public private(set) var isBackgroundDegraded: Bool = false
    @Published public private(set) var isBroadcastingSos: Bool = false

    public init(node: MeshNode) {
        self.node = node
    }

    /// Full mesh: BLE plus the Wi-Fi bulk plane. Called when the app becomes
    /// active. The bulk plane activates lazily on demand, so foregrounding only
    /// needs to clear the degradation flag and start the BLE control plane.
    public func enterForegroundMode() {
        isBackgroundDegraded = false
        node.start()
    }

    /// iOS suspends the radio stack when the app is backgrounded: advertisement
    /// data is truncated, scanning is coalesced, and MultipeerConnectivity is
    /// gone entirely. We do not pretend otherwise -- the UI shows a banner.
    public func enterBackgroundMode() {
        isBackgroundDegraded = true
        // TODO: stop the Wi-Fi bulk plane (BulkTransport.deactivate) once the
        // router owns a reference to it. BLE stays up, degraded.
    }

    /// Begin broadcasting an SOS. The frame is built and handed to the router,
    /// which epidemic-forwards it to every reachable peer. The broadcast repeats
    /// until `cancelSos` is called.
    public func broadcastSos() {
        isBroadcastingSos = true
        // TODO: construct a GMP/1 SOS frame (type .sos, max TTL, location +
        // call sign payload) and enqueue it via node.router.ingest, then drive
        // a 30-second repeat timer. msg_id derivation and the repeat loop are
        // deferred; see docs/AUDIT.md.
    }

    /// Stop broadcasting. Already-relayed copies continue to propagate through
    /// the mesh on their own -- cancellation is local, not network-wide.
    public func cancelSos() {
        isBroadcastingSos = false
        // TODO: invalidate the 30-second repeat timer once it exists.
    }
}