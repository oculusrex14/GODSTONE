import Foundation
import MultipeerConnectivity

/// Wi-Fi bulk plane, used only for payloads above 512 bytes: photos, voice
/// notes, and content chunks. Brought up on demand and torn down within five
/// seconds of going idle, because peer-to-peer Wi-Fi is the single largest
/// battery draw in the whole application.
///
/// MultipeerConnectivity uses peer-to-peer Wi-Fi with an automatic Bluetooth
/// fallback and negotiates AWDL itself. It has NO background mode whatsoever:
/// when the app is suspended, this plane is simply gone. BLE carries on alone.
public final class BulkTransport: NSObject {

    private static let serviceType = "godstone-mesh"

    private let peerId: MCPeerID
    private let session: MCSession
    private let advertiser: MCNearbyServiceAdvertiser
    private let browser: MCNearbyServiceBrowser

    private var idleTimer: Timer?
    public weak var delegate: TransportDelegate?

    public private(set) var isActive = false

    public init(displayName: String) {
        // Display name is the 4-byte node hint in hex, never anything personal.
        self.peerId = MCPeerID(displayName: displayName)

        self.session = MCSession(
            peer: peerId,
            securityIdentity: nil,
            // Required, not optional. Even though every payload is already
            // Noise-encrypted, defence in depth costs nothing here.
            encryptionPreference: .required)

        self.advertiser = MCNearbyServiceAdvertiser(
            peer: peerId, discoveryInfo: nil,
            serviceType: BulkTransport.serviceType)

        self.browser = MCNearbyServiceBrowser(
            peer: peerId, serviceType: BulkTransport.serviceType)

        super.init()
        session.delegate = self
        advertiser.delegate = self
        browser.delegate = self
    }

    /// Called by the router when a large frame needs to move.
    public func activate() {
        guard !isActive else { resetIdleTimer(); return }
        isActive = true
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
        resetIdleTimer()
    }

    public func deactivate() {
        guard isActive else { return }
        isActive = false
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        session.disconnect()
        idleTimer?.invalidate()
    }

    private func resetIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) {
            [weak self] _ in self?.deactivate()
        }
    }

    public func send(_ frame: Frame) {
        guard isActive, !session.connectedPeers.isEmpty else { return }
        resetIdleTimer()
        // Unreliable for bulk: a dropped photo chunk is retried by the DTN layer
        // above, and head-of-line blocking on a flaky radio is far worse.
        try? session.send(frame.encode(), toPeers: session.connectedPeers,
                          with: .unreliable)
    }
}

extension BulkTransport: MCSessionDelegate, MCNearbyServiceAdvertiserDelegate,
                         MCNearbyServiceBrowserDelegate {

    public func session(_ s: MCSession, peer: MCPeerID,
                        didChange state: MCSessionState) {
        switch state {
        case .connected:    delegate?.transportReady(peerId: UUID())
        case .notConnected: delegate?.transportDidDisconnect(peerId: UUID())
        default: break
        }
    }

    public func session(_ s: MCSession, didReceive data: Data, fromPeer peer: MCPeerID) {
        resetIdleTimer()
        delegate?.transportDidReceive(data: data, peerId: UUID())
    }

    public func advertiser(_ a: MCNearbyServiceAdvertiser,
                           didReceiveInvitationFromPeer peer: MCPeerID,
                           withContext context: Data?,
                           invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        // Accept everyone. Authentication happens in the Noise handshake, not
        // here; refusing at this layer would only weaken the mesh.
        invitationHandler(true, session)
    }

    public func browser(_ b: MCNearbyServiceBrowser, foundPeer peer: MCPeerID,
                        withDiscoveryInfo info: [String: String]?) {
        b.invitePeer(peer, to: session, withContext: nil, timeout: 15)
    }

    public func browser(_ b: MCNearbyServiceBrowser, lostPeer peer: MCPeerID) { }

    public func session(_ s: MCSession, didReceive stream: InputStream,
                        withName name: String, fromPeer peer: MCPeerID) { }
    public func session(_ s: MCSession, didStartReceivingResourceWithName name: String,
                        fromPeer peer: MCPeerID, with progress: Progress) { }
    public func session(_ s: MCSession, didFinishReceivingResourceWithName name: String,
                        fromPeer peer: MCPeerID, at url: URL?, withError error: Error?) { }
}
