import Foundation

// ---------------------------------------------------------------------------
// GS-ARCHIVE-004: the decision of WHICH passage a reader scrolleth to.
//
// The audit found the full-document reader with NO scrolling container at all
// (`ScrollViewReader { _ in LazyVStack { ... } }` -- the proxy was discarded), so a
// document longer than a screen could not be read. The container is a view concern; the
// DECISION is not, and it liveth here so that it can be TESTED rather than asserted:
//
//   * the saved anchor wineth when the selected archive still carrieth it;
//   * otherwise the reader FALLETH BACK TO THE BEGINNING -- never waiteth for an anchor
//     that no longer existeth;
//   * a document with no passages hath no target at all.
// ---------------------------------------------------------------------------

public enum ArchiveReadingAnchor {
    /// The passage identity a reader should scroll to, or nil when there is none.
    ///
    /// - Parameters:
    ///   - passageIds: the passages of the CURRENTLY selected document, in reading order.
    ///   - saved: the anchor restored from the scene (persisted navigation identity).
    public static func target(passageIds: [Int64], saved: Int64?) -> Int64? {
        guard let first = passageIds.first else { return nil }
        guard let saved else { return first }
        return passageIds.contains(saved) ? saved : first
    }

    /// True when the saved anchor still existeth in this document -- so a caller can
    /// report that it fell back rather than pretending the anchor held.
    public static func anchorHolds(passageIds: [Int64], saved: Int64?) -> Bool {
        guard let saved else { return false }
        return passageIds.contains(saved)
    }
}
