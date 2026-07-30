// SYNTHESIZED gap-closure file -- authored to make the project compile; see docs/AUDIT.md.
import Foundation

/// The mesh node: an identity plus the radios and router that carry it.
///
/// This is the long-lived, non-observable surface. It owns a BLE control plane
/// and the epidemic router; the Wi-Fi bulk plane is brought up on demand by the
/// router. The observable, UI-facing surface is `MeshCoordinator`, which wraps a
/// node and exposes peer count and foreground/background state to SwiftUI.
///
/// `start`/`stop` only drive the BLE transport: BLE is the always-on plane and
/// the one iOS will (grudgingly) keep alive in the background. The bulk plane is
/// activated lazily by the router when a frame exceeds the BLE threshold, and is
/// torn down on idle -- see `BulkTransport`.
public final class MeshNode {

    public let identity: MeshIdentity

    /// Lazy so CoreBluetooth managers are not constructed until the node is
    /// actually started. Constructing them at app launch, before the user has
    /// any reason to be on the mesh, would needlessly burn radio power.
    public private(set) lazy var ble: BleTransport = BleTransport()
    public private(set) lazy var router: Router = Router()

    private var isStarted = false

    public init(identity: MeshIdentity) {
        self.identity = identity
    }

    /// Bring up the BLE control plane and begin advertising/scanning.
    public func start() {
        guard !isStarted else { return }
        isStarted = true
        ble.start()
    }

    /// Tear down the BLE control plane. The bulk plane, if active, is left to
    /// idle out on its own timer; forcibly killing it here would abort in-flight
    /// transfers that the router still counts on.
    public func stop() {
        guard isStarted else { return }
        isStarted = false
        ble.stop()
    }
}
