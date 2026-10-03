// GS-ARCHIVE-004: restored anchors must select a live passage or the beginning.
// Scrolling and restored placement are exercised by the actual Archive UI journeys.
import XCTest
@testable import GodstoneCore   // the anchor decision liveth in GodstoneCore (the scene's isle)

final class ReadinessArchive004Tests: XCTestCase {

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

}
