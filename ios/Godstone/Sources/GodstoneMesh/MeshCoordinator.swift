import Foundation
import Combine

@MainActor
public final class MeshCoordinator: ObservableObject {
    public enum SosState: Equatable {
        case idle
        case unavailable(String)
        case queuedDurably
        case handedToRelays(Int)
        case notPersisted
        case failed(String)
    }

    public let node: MeshNode
    @Published public private(set) var peerCount = 0
    @Published public private(set) var isBackgroundDegraded = false
    @Published public private(set) var sosState: SosState = .idle

    public var transportAvailable: Bool { MeshNode.linkLayerReady }
    public var transportDetail: String {
        transportAvailable ? "Encrypted mesh control plane active" : MeshNode.linkLayerOpenReason
    }
    public var isBroadcastingSos: Bool {
        if case .handedToRelays = sosState { return true }
        if case .queuedDurably = sosState { return true }
        return false
    }

    public init(node: MeshNode) {
        self.node = node
        node.onPeerCountChanged = { [weak self] count in
            Task { @MainActor in self?.peerCount = count }
        }
    }

    public func enterForegroundMode() {
        isBackgroundDegraded = false
        if transportAvailable { _ = node.start() }
    }

    public func enterBackgroundMode() {
        isBackgroundDegraded = transportAvailable
    }

    public func broadcastSos() {
        let result = node.broadcastSos(payload: Data("SOS".utf8))
        switch result {
        case .unavailable(let reason): sosState = .unavailable(reason)
        case .queuedDurably: sosState = .queuedDurably
        case .handedToRelays(let count): sosState = .handedToRelays(count)
        case .notPersisted: sosState = .notPersisted
        case .failed(let reason): sosState = .failed(reason)
        }
    }

    public func cancelSos() {
        // Cancellation is local. Already-relayed copies cannot be recalled.
        sosState = .idle
    }
}
