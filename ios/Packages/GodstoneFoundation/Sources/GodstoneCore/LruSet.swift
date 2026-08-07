import Foundation

/// A bounded least-recently-used set.
///
/// V4: O(1) membership and insertion.
///
/// V3 backed this with a single Array and documented the cost as acceptable
/// because the set is "scanned once per encounter". It is not -- `Router.ingest`
/// calls `contains` on EVERY FRAME, and `insert` then called `firstIndex(of:)`
/// and `removeFirst()`, both O(n) on an Array. At the 16,384 capacity the router
/// actually uses, that is three linear scans with Data equality per frame, on
/// the exact path a flood saturates. Another comment asserting a property the
/// code contradicted.
public struct LruSet<Element: Hashable> {
    private var order: [Element] = []
    private var index: Set<Element> = []
    private var head = 0                    // amortises removeFirst to O(1)
    private let capacity: Int

    public init(capacity: Int) {
        precondition(capacity >= 0)
        self.capacity = capacity
        order.reserveCapacity(min(capacity, 1024))
    }

    public func contains(_ element: Element) -> Bool {
        index.contains(element)
    }

    public mutating func insert(_ element: Element) {
        // Re-seeing an id is a no-op: promoting it would reorder the digest and
        // make peers re-offer frames we already hold.
        guard !index.contains(element) else { return }
        index.insert(element)
        order.append(element)

        while index.count > capacity {
            let oldest = order[head]
            head += 1
            index.remove(oldest)
        }
        // Compact once the dead prefix dominates, so `order` cannot grow without
        // bound on a long-lived node.
        if head > 4096 && head * 2 > order.count {
            order.removeFirst(head)
            head = 0
        }
    }

    /// Insertion order, oldest first.
    public var elements: [Element] { Array(order[head...]) }

    public var count: Int { index.count }
}
