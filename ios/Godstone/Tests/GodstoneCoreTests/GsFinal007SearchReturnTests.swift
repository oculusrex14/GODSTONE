import XCTest
import Foundation
@testable import GodstoneCore

/**
 * GS-FINAL-007 (the independent audit, 2026-09-18): **A RESTORED RETURN-TO-SEARCH MUST RE-EXECUTE, NOT RENDER AS
 * "NO RESULTS".**
 *
 * THE AUDIT'S MEASUREMENT, VERBATIM: *"restore creates a search returnScene with empty passages. back publishes that
 * empty scene as NoResults and only triggers reload for an empty documents-mode scene, not the restored search."*
 *
 * ITS ROOT CAUSE: *"Persisting only identities was correct, but the restore/back path treats intentionally absent
 * payload as a completed empty payload."*
 *
 * THE USER-VISIBLE CONSEQUENCE, WHICH IS WHY IT IS A REAL DEFECT AND NOT A MODELLING NICETY: open a document from
 * search results, let the process be recreated (or the scene restored), then press Back -- **AND THE READER IS TOLD
 * THERE ARE NO RESULTS FOR A QUERY THEY NEVER SEE RE-RUN**, on an archive that would have returned the hits.
 *
 * THE REMEDIATION THE AUDIT PRESCRIBES IS THE ARM'S OWN SUBJECT: *"Represent restored return routes as unloaded
 * identities, not fully loaded Scene values with empty arrays. In back, detect unloaded search, publish Loading and
 * rerun the saved searchedQuery under a fresh generation before rendering results."*
 */
private final class HitReader: ArchiveReading, @unchecked Sendable {
    private let lock = NSLock()
    let document = ArchiveDocument(id: 7, title: "Archive guide", domain: "reference",
                                   isCritical: false, sourceId: "src-001", revision: "r7")
    let hitA = ArchivePassage(id: 11, documentId: 7, documentTitle: "Archive guide",
                              domain: "reference", section: "Search", text: "Read the full guide.")
    let hitB = ArchivePassage(id: 12, documentId: 7, documentTitle: "Archive guide",
                              domain: "reference", section: "Search", text: "Remaining context.")
    var availability: ArchiveAvailability = .ready(origin: "fake://installed.bin")
    /// WHAT EACH SUCCESSIVE SEARCH RETURNS, IN ORDER. The rig needs TWO DIFFERENT ANSWERS: two hits for the initial
    /// search (so the reader reaches Search mode with a hit to open), and whatever the re-run returns. A single fixed
    /// answer could not distinguish "the re-run found nothing" from "the re-run never happened" -- WHICH IS THE ARM'S
    /// WHOLE SUBJECT.
    var searchAnswers: [[ArchivePassage]] = []
    var hitsForSearch: [ArchivePassage] = []
    private(set) var searched: [String] = []

    func read(_ request: ArchiveRequest) async throws -> ArchivePage {
        switch request {
        case .browse:
            return .documents([document])
        case .search(let phrase):
            lock.lock()
            searched.append(phrase)
            let answer = searchAnswers.isEmpty ? hitsForSearch : searchAnswers.removeFirst()
            lock.unlock()
            return .passages(answer)
        case .document:
            return .passages([hitA, hitB])
        }
    }

    func sourceMetadata(documentId: Int64) -> ArchiveSourceMetadata? { nil }
}

@MainActor
final class GsFinal007SearchReturnTests: XCTestCase {

    private func settled() async {
        for _ in 0..<40 { await Task.yield() }
    }

    /// A scene restored into the DOCUMENT mode with a SEARCH return-destination -- the state the user is in after
    /// opening a hit and having the process recreated.
    private func restoredFromSearch(_ reader: HitReader) async -> ArchiveSceneModel {
        let model = ArchiveReaderModel(library: reader)
        let scene = ArchiveSceneModel(reading: reader, model: model)

        // (1) the reader searches and gets TWO hits.
        reader.hitsForSearch = [reader.hitA, reader.hitB]
        scene.onQueryChanged("guide")
        await scene.search()
        await settled()
        XCTAssertEqual(scene.passages.count, 2, "the rig must have produced the two hits before the snapshot")

        // (2) the reader opens a hit -- which stashes the SEARCH scene as the return-destination.
        await scene.open(document: reader.document)
        await settled()

        // (3) the process is recreated: snapshot, then a FRESH scene restored from that handle.
        var handle: [String: Any] = [:]
        scene.snapshot(into: &handle)
        let freshModel = ArchiveReaderModel(library: reader)
        let fresh = ArchiveSceneModel(reading: reader, model: freshModel)
        await fresh.restore(from: handle)
        await settled()
        return fresh
    }

    /**
     * *** THE HEADLINE: BACK FROM A RESTORED DOCUMENT MUST RE-EXECUTE THE SAVED SEARCH. ***
     *
     * The archive returns TWO hits for the saved query. After Back the reader must SEE them -- or, if the road is
     * still in flight, a Loading phase. **WHAT THEY MUST NOT SEE IS `NoResults`**, which is an assertion about the
     * archive that this reader disproves.
     */
    func testGSFINAL007_backFromRestoredDocumentDoesNotRenderNoResults() async throws {
        let reader = HitReader()
        reader.hitsForSearch = [reader.hitA, reader.hitB]
        let fresh = await restoredFromSearch(reader)

        let before = reader.searched.count
        fresh.back()
        await settled()

        XCTAssertNotEqual(
            fresh.phase, .noResults,
            "*** GS-FINAL-007: BACK FROM A RESTORED DOCUMENT MUST NOT RENDER `NoResults`. The saved query returns "
            + "TWO hits; the restored return-destination carried an EMPTY passages array, and `back()` read that "
            + "intentionally-absent payload as a COMPLETED empty payload. The reader is told there is nothing to find "
            + "for a query that was never re-run. Observed phase: \(fresh.phase), passages: \(fresh.passages.count) ***",
        )
        XCTAssertGreaterThan(
            reader.searched.count, before,
            "*** AND THE SAVED QUERY MUST ACTUALLY BE RE-EXECUTED -- the audit's own remedy: 'publish Loading and "
            + "rerun the saved searchedQuery under a fresh generation before rendering results'. Searches before "
            + "back(): \(before); after: \(reader.searched.count) ***",
        )
    }

    /**
     * *** AND THE RESULT THE ARCHIVE ACTUALLY RETURNS MUST BE WHAT STANDS: TWO HITS, NOT ZERO. ***
     */
    func testGSFINAL007_theRestoredSearchShowsTheHitsTheArchiveReturns() async throws {
        let reader = HitReader()
        reader.hitsForSearch = [reader.hitA, reader.hitB]
        let fresh = await restoredFromSearch(reader)

        fresh.back()
        await settled()

        XCTAssertEqual(
            fresh.mode, .search,
            "Back from a document opened out of SEARCH must return to SEARCH, not to the document list",
        )
        XCTAssertEqual(
            fresh.passages.count, 2,
            "*** THE TWO HITS THE ARCHIVE RETURNS MUST STAND after the restored Back. Observed "
            + "\(fresh.passages.count) passage(s) in phase \(fresh.phase) ***",
        )
        XCTAssertEqual(
            fresh.searchedQuery, "guide",
            "and the published search identity must be the saved query, so the reader knows what was run",
        )
    }

    /**
     * *** POSITIVE CONTROL: A GENUINELY EMPTY SEARCH STILL REPORTS `NoResults`. ***
     *
     * The repair must distinguish "the payload was never loaded" from "the query ran and found nothing" -- WITHOUT
     * breaking the second. An archive that truly has no hits must still say so, or the repair has traded one lie for
     * another.
     */
    func testGSFINAL007_aGenuinelyEmptySearchStillReportsNoResults() async throws {
        let reader = HitReader()
        // THE FIRST SEARCH FINDS TWO (so a hit can be opened); THE RE-RUN FINDS NOTHING -- and THAT is the honest
        // `NoResults` the repair must preserve.
        reader.searchAnswers = [[reader.hitA, reader.hitB], []]
        let fresh = await restoredFromSearch(reader)

        fresh.back()
        await settled()

        XCTAssertEqual(
            fresh.phase, .noResults,
            "an archive that truly returns zero hits must still report `NoResults` -- the repair must distinguish "
            + "an UNLOADED payload from a COMPLETED EMPTY one, not suppress the honest empty state",
        )
        XCTAssertEqual(fresh.passages.count, 0)
    }

    /**
     * *** AND THE NAVIGATION IS NOT A LOOP: the return-to-search road must not re-open the document. ***
     */
    func testGSFINAL007_theRestoredBackReturnsToSearchAndNotToTheDocument() async throws {
        let reader = HitReader()
        reader.hitsForSearch = [reader.hitA, reader.hitB]
        let fresh = await restoredFromSearch(reader)

        fresh.back()
        await settled()
        fresh.back()          // a SECOND back, from search, reaches the list
        await settled()

        XCTAssertEqual(
            fresh.mode, .documents,
            "a second Back from the restored SEARCH must reach the document list -- the journey must terminate",
        )
    }
}
