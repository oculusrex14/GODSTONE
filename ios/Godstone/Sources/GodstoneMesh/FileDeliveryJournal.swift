import Foundation

// Stage 3 Phase H -- a real durable DeliveryJournal backed by a JSON file, the
// Swift twin of android/.../mesh/delivery/FileDeliveryJournal.kt. Used in
// production (Application Support dir) and in the reboot-recovery test (a temp
// file reopened by a fresh tracker), so the persistence path CI exercises is
// the persistence path production uses.

/// File-backed `DeliveryJournal`: key = hex(msgId), value = state name. The map
/// is rewritten on every mutation (the tracked set is bounded by the store's
/// hard cap) and loaded once at construction. Survives a process restart
/// (reboot/jetsam) so a fresh `DeliveryTracker` over the same file recovers
/// state -- the ADR-005 reboot-recovery exit criterion, proven host-side by
/// reopening the file.
public final class FileDeliveryJournal: DeliveryJournal {
    private let url: URL
    private var map: [String: String] = [:]

    public init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            map = obj
        }
    }

    private func key(_ msgId: Data) -> String {
        msgId.map { String(format: "%02x", $0) }.joined()
    }

    public func read(_ msgId: Data) -> DeliveryState {
        guard let name = map[key(msgId)] else { return .unavailable }
        return DeliveryState(rawValue: name) ?? .unavailable
    }

    public func write(_ msgId: Data, _ state: DeliveryState) {
        map[key(msgId)] = state.rawValue
        persist()
    }

    public func clear(_ msgId: Data) {
        map.removeValue(forKey: key(msgId))
        persist()
    }

    private func persist() {
        guard let data = try? JSONSerialization.data(withJSONObject: map) else { return }
        try? data.write(to: url, options: .atomic)
    }
}