// GS-ARCHIVE-004 -- the full-document reader scrolls, and the anchor decision is TESTED.
//
// The audit confirmed by source that `readingView` was ScrollViewReader + LazyVStack with
// NO scrolling container and a DISCARDED proxy. The container is a view concern and is
// asserted here as source; the ANCHOR DECISION is behavioural and is exercised directly.
import XCTest
import Foundation
@testable import GodstoneMesh
@testable import GodstoneCore   // the anchor decision liveth in GodstoneCore (the scene's isle)

final class ReadinessArchive004Tests: XCTestCase {
    // ------------------------------------------------------------ W01
    func testW01TheReaderHasAScrollingContainer() throws {
        let source = try archiveViewSource()
        // the container WRAPPETH the passage stack
        XCTAssertTrue(source.contains("ScrollViewReader { proxy in"),
                      "the proxy must be CAPTURED, not discarded: the old form was `{ _ in }`")
        XCTAssertTrue(source.contains("ScrollView(.vertical)"),
                      "the full-document reader must carry a vertical scrolling container")
        XCTAssertFalse(source.contains("ScrollViewReader { _ in"),
                       "the discarded-proxy form is the audited defect and must be gone")
        // the container wraps the stack, not the other way round
        let reader = source.range(of: "ScrollViewReader { proxy in")
        let scroll = source.range(of: "ScrollView(.vertical)")
        let stack = source.range(of: "LazyVStack(alignment: .leading, spacing: 24)")
        XCTAssertNotNil(reader); XCTAssertNotNil(scroll); XCTAssertNotNil(stack)
        if let reader, let scroll, let stack {
            XCTAssertLessThan(reader.lowerBound, scroll.lowerBound)
            XCTAssertLessThan(scroll.lowerBound, stack.lowerBound)
        }
    }

    // ------------------------------------------------------------ W02
    func testW02TheProxyIsUsedForTheRestoredAnchor() throws {
        let source = try archiveViewSource()
        XCTAssertTrue(source.contains("proxy.scrollTo("),
                      "the captured proxy must actually place the reader")
        XCTAssertTrue(source.contains("ArchiveReadingAnchor.target("),
                      "the anchor decision must come from the tested helper")
        XCTAssertTrue(source.contains(".id(passage.id)"),
                      "each passage needeth a STABLE identity for the proxy to address")
    }

    // ------------------------------------------------------------ W03
    func testW03ASavedAnchorThatStillExistsWins() {
        XCTAssertEqual(ArchiveReadingAnchor.target(passageIds: [3, 7, 9], saved: 7), 7)
        XCTAssertTrue(ArchiveReadingAnchor.anchorHolds(passageIds: [3, 7, 9], saved: 7))
    }

    // ------------------------------------------------------------ W04
    func testW04AnAnchorThatNoLongerExistsFallsBackToTheBeginning() {
        XCTAssertEqual(ArchiveReadingAnchor.target(passageIds: [3, 7, 9], saved: 42), 3,
                       "an absent anchor must FALL BACK, never wait")
        XCTAssertFalse(ArchiveReadingAnchor.anchorHolds(passageIds: [3, 7, 9], saved: 42))
        let noTarget: Int64? = ArchiveReadingAnchor.target(passageIds: [], saved: 42)
        XCTAssertNil(noTarget, "a document with no passages hath no target")
        let noTargetAtAll: Int64? = ArchiveReadingAnchor.target(passageIds: [], saved: nil)
        XCTAssertNil(noTargetAtAll)
    }

    // ------------------------------------------------------------ W05
    func testW05NoAnchorMeansTheBeginning() {
        XCTAssertEqual(ArchiveReadingAnchor.target(passageIds: [11, 12], saved: nil), 11)
        XCTAssertFalse(ArchiveReadingAnchor.anchorHolds(passageIds: [11, 12], saved: nil))
    }

    private func archiveViewSource() throws -> String {
        var repo = URL(fileURLWithPath: #filePath)
        var hops = 0
        while repo.path != "/" && hops < 12 {
            if FileManager.default.fileExists(atPath: repo.appendingPathComponent("android").path) { break }
            repo.deleteLastPathComponent(); hops += 1
        }
        return try String(contentsOf: repo.appendingPathComponent(
            "ios/Godstone/Sources/App/ArchiveView.swift"), encoding: .utf8)
    }
}
