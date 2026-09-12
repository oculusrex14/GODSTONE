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
    /// T39: the UI's truthful record of the last cancellation. The card's law:
    /// cancellation "cannot retract already relayed copies and UI says so" --
    /// when bytes had gone out, the note says so; when they had not, the note
    /// says merely the cancellation. nil: no cancellation has been recorded
    /// since the last authoring.
    @Published public private(set) var sosCancelNote: String? = nil

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
        // T39: a fresh authoring clears the last cancellation's note; the mirror
        // states below are the dispatch result, and after the durable pair stood
        // the node's own projection re-read the tables to confirm them.
        sosCancelNote = nil
        switch result {
        case .unavailable(let reason): sosState = .unavailable(reason)
        case .queuedDurably: sosState = .queuedDurably
        case .handedToRelays(let count): sosState = .handedToRelays(count)
        case .notPersisted: sosState = .notPersisted
        case .failed(let reason): sosState = .failed(reason)
        }
    }

    public func cancelSos() {
        // T39: cancellation is local and the durable cancel runs FIRST -- the row
        // moves terminal and the held/scheduled work retires with it in the one
        // authority (it cannot retract already relayed copies, and the note
        // says so from the truth the result carries). The published state is
        // then re-derived FROM the durable projection: the mirror goes idle only
        // when the tables say nothing live; while a row still stands (a refused
        // or non-broadcast case), the UI keeps telling the row's truth instead
        // of overwriting it with wish.
        if let seen = node.activeSosSnapshot() {
            let outcome = node.cancelSos(seen.msgId)
            if case .cancelled(let wasRelayed) = outcome, wasRelayed {
                sosCancelNote = "cancellation recorded; already relayed copies cannot be recalled"
            } else {
                sosCancelNote = "cancellation recorded"
            }
        }
        if node.refreshSosStatusAfterScan() == nil {
            sosState = .idle
        }
    }
}
