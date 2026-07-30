// SYNTHESIZED gap-closure file -- authored to make the project compile; see docs/AUDIT.md.
import Foundation

/// A bounded least-recently-used set.
///
/// Used by `Router` to deduplicate message ids. Insertion order is preserved so
/// `BloomDigest.build(from:)` sees the most recently seen ids first; when the
/// capacity is exceeded the oldest entry is evicted. `contains` is O(n) but the
/// capacity is fixed (16k), and the alternative -- a separate index dict -- buys
/// little on a 16k String/Data set that is scanned once per encounter.
public struct LruSet<Element: Hashable> {

    private var order: [Element] = []
    private let capacity: Int

    public init(capacity: Int) {
        precondition(capacity >= 0)
        self.capacity = capacity
    }

    public func contains(_ element: Element) -> Bool {
        order.contains(element)
    }

    public mutating func insert(_ element: Element) {
        // Dedup: a re-seen id is promoted to the tail (most-recently-used).
        if let existing = order.firstIndex(of: element) {
            order.remove(at: existing)
        }
        order.append(element)
        while order.count > capacity {
            order.removeFirst()
        }
    }

    /// Insertion order, oldest first.
    public var elements: [Element] { order }
}