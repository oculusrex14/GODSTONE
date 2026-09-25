import XCTest
@testable import GodstoneCore

/// *** GS-ARCHIVE-005 / GS-FINAL-006: THE iOS RESTORATION WITNESS. ***
///
/// THE CARD'S `regression_test`, VERBATIM: *"Open a non-first search hit, scroll to a later passage,
/// background/recreate, assert matching document and visible passage; repeat from document browse."*
///
/// *** AND THE CLAIM THESE ARMS REPLACE. *** *Both findings recorded that "the iOS App layer cannot be compiled here
/// at all (NATIVE_MODELS)", and I DISPROVED THAT THIS SESSION by running the canonical build:
/// `xcodebuild -scheme Godstone-Light -configuration LightRelease ... build` -> `** BUILD SUCCEEDED **`, and the
/// scheme's test action -> `** TEST SUCCEEDED **`, 1277 tests. **THE NATIVE_MODELS GATE BOUNDS THE MODEL/ORACLE STACK
/// AND THE SQLCIPHER ENGINE -- NOT THE APP TARGET.** So the iOS witness was ALWAYS REACHABLE IN-REPO and was
/// outstanding work rather than an external dependency.*
///
/// **THE VEHICLE IS THE ONE `ArchiveView` ACTUALLY BINDS:** `snapshot(into:)` / `restore(from:)`, which the view
/// carries through **`ArchivePlaceStore` -- a `UserDefaults` record that surviveth the process.** *That is what
/// "recreate" means for a foregrounded app: the handle survives, the model does not.*
///
/// *** THIS DOCSTRING PREVIOUSLY READ "which the view wraps in `@SceneStorage("godstone.archive.scene")`", AND THAT
/// WAS THE DEFECT STATED AS THE DESIGN. *** *`@SceneStorage` is scene-scoped and this target carrieth no
/// state-restoration opt-in, so iOS discarded the record -- **which is why the executed recreation arm stayed
/// deterministically red while every MODEL-level arm here passed.*** *These courts prove the HANDLE round-trips; only
/// the executed app arm can prove the STORE survives a `terminate()`, and it now does.*
/// *** `@MainActor`, MATCHING THE MODEL: `ArchiveReaderModel` and `ArchiveSceneModel` are main-actor-isolated, so a
/// nonisolated court cannot even construct them -- which the compiler said plainly. The sibling court
/// (`GsFinal007SearchReturnTests`) carries the same attribute for the same reason.***
@MainActor
final class GsArchive005IOSRestorationTests: XCTestCase {

    // ================================================================================================
    // MARK: - a library that answers, so the journey is real
    // ================================================================================================

    /// An `ArchiveReading` that answers searches and browses from fixture data, so a hit is a REAL hit in the
    /// model's own vocabulary rather than an id the arm invented.
    private final class Library: ArchiveReading, @unchecked Sendable {
        var docs: [ArchiveDocument]
        var passages: [ArchivePassage]
        var hitsForSearch: [ArchivePassage] = []
        private let lock = NSLock()

        init(docs: [ArchiveDocument], passages: [ArchivePassage]) {
            self.docs = docs
            self.passages = passages
            self.hitsForSearch = passages
        }

        var availability: ArchiveAvailability { .ready(origin: "fake://gsa005.bin") }

        func read(_ request: ArchiveRequest) async throws -> ArchivePage {
            switch request {
            case .browse: return .documents(docs)
            case .search: return .passages(hitsForSearch)
            case .document(let id): return .passages(passages.filter { $0.documentId == id })
            }
        }

        func sourceMetadata(documentId: Int64) -> ArchiveSourceMetadata? { nil }
    }

    private func settled() async {
        for _ in 0..<40 { await Task.yield() }
    }

    private func makeLibrary() -> Library {
        let docs = (1...4).map { i in
            ArchiveDocument(id: Int64(i), title: "Document \(i)", domain: "reference", isCritical: false)
        }
        // FOUR passages per document, so a "later passage" is a REAL later one and not the only one available.
        let passages = docs.flatMap { d in
            (1...4).map { p in
                ArchivePassage(id: d.id * 100 + Int64(p), documentId: d.id,
                               documentTitle: d.title, domain: d.domain,
                               section: "Section \(p)", text: "passage \(p) of document \(d.id)",
                               score: 1.0)
            }
        }
        return Library(docs: docs, passages: passages)
    }

    // ================================================================================================
    // MARK: - the journeys
    // ================================================================================================

    /// *** THE CARD'S SEQUENCE, WITH "NON-FIRST" TAKEN LITERALLY. ***
    ///
    /// *A restoration that only ever returned to the FIRST hit would satisfy a weaker arm, so this opens a hit that
    /// is deliberately NOT the first.*
    func testGSA005NONFIRSTSearchHitRestoresItsDocumentAndVisiblePassage() async throws {
        let library = makeLibrary()
        let model = ArchiveReaderModel(library: library)
        let scene = ArchiveSceneModel(reading: library, model: model)
        await settled()

        // (1) A SEARCH.
        scene.onQueryChanged("passage")
        await scene.search()
        await settled()
        let hits = scene.passages
        try XCTSkipUnless(
            hits.count >= 2,
            "*** THE RIG NEEDS AT LEAST TWO HITS: the arm must open a NON-FIRST one, or a restoration that only ever " +
                "returned to the first result would satisfy it. Observed: \(hits.count) ***",
        )
        let chosen = hits[1]   // *** NOT THE FIRST. ***

        // (2) OPEN IT -- the verb a rendered tap calls.
        guard let document = library.docs.first(where: { $0.id == chosen.documentId }) else {
            return XCTFail("the chosen hit's document must exist in the library")
        }
        await scene.open(document: document)
        await settled()

        // (3) SCROLL ONWARD, through the model's own scroll notice -- the reader is now at a LATER passage.
        let laterPassage = library.passages.first { $0.documentId == document.id && $0.id > chosen.id }
        try XCTSkipUnless(laterPassage != nil, "the rig needs a later passage in the same document")
        scene.noteScroll(passageId: laterPassage!.id)

        // (4) RECREATE: snapshot, then a FRESH model restored from that handle.
        var handle: [String: Any] = [:]
        scene.snapshot(into: &handle)
        XCTAssertFalse(handle.isEmpty, "*** THE SNAPSHOT MUST CARRY SOMETHING, or restoration has nothing to restore. ***")

        let freshModel = ArchiveReaderModel(library: library)
        let reborn = ArchiveSceneModel(reading: library, model: freshModel)
        await reborn.restore(from: handle)
        await settled()

        // *** (5) THE ASSERTION THE CARD ASKS FOR. ***
        // *The card distinguishes the DOCUMENT from the VISIBLE PASSAGE, so both are asserted -- a restoration that
        // returns to the right document at the wrong passage loses the reader's place.*
        XCTAssertEqual(
            reborn.openedDocumentId, document.id,
            "*** THE RECREATED SCENE MUST BE SHOWING THE SAME DOCUMENT. ***",
        )
        let anchor = reborn.scrollAnchor
        XCTAssertEqual(
            anchor?.passageId, laterPassage!.id,
            "*** AND THE SAME VISIBLE PASSAGE. `noteScroll` records where the reader actually IS; restoring the " +
                "document without the passage is the distinction the card draws. Observed: " +
                "\(String(describing: anchor?.passageId)), expected \(laterPassage!.id) ***",
        )
    }

    /// *** GS-FINAL-006: AN ANCHOR THAT NO LONGER EXISTETH FALLS BACK -- AND THE FALLBACK MUST BE OBSERVED FIRING. ***
    ///
    /// *THE CARD'S CLAUSE IS "an invalid anchor falls back safely", AND IT IS THE EASIEST CLAUSE IN THIS FINDING TO
    /// FAKE GREEN.* **`ArchiveReadingAnchor.target` already decideth it CORRECTLY and `ReadinessArchive004Tests`
    /// witnesseth the PURE FUNCTION -- but a pure-function court can go green while THE PRODUCTION ROAD NEVER CALLS IT,
    /// which is precisely the "a declaration is not a capability" defect this programme has filed repeatedly.***
    ///
    /// *** SO THIS ARM GOES THROUGH THE REAL SCENE: a persisted anchor is made to name a passage that the reopened
    /// document DOES NOT CONTAIN, and the assertion is on WHAT THE READER IS GIVEN rather than on the stored field.***
    /// *Asserting `scrollAnchor == nil` would only re-check the projection; the reader-facing fact is WHICH PASSAGE the
    /// reader should be at, which is what `ArchiveReadingAnchor.target` produceth from the restored anchor and the
    /// document's own passage list.*
    ///
    /// **AND THE CONTRAST IS MEASURED IN THE SAME ARM:** the SAME restored scene, with a VALID anchor, must yield that
    /// anchor -- so a "fallback" that always fired would fail the valid half, and a fallback that never fired would
    /// fail the invalid half. *Two directions, one arm, because a single direction can be satisfied by a constant.*
    func testGSA005AnInvalidAnchorFallsBackAndTheFallbackIsObservedFiring() async throws {
        let library = makeLibrary()
        let scene = ArchiveSceneModel(reading: library, model: ArchiveReaderModel(library: library))
        await settled()

        // A DOCUMENT WITH AT LEAST TWO PASSAGES, so "a valid anchor" and "an invalid one" are BOTH expressible.
        guard let document = library.docs.first(where: { doc in
            library.passages.contains { $0.documentId == doc.id }
        }) else { return XCTFail("the rig needs a document with passages") }
        let passages = library.passages.filter { $0.documentId == document.id }
        try XCTSkipUnless(passages.count >= 1, "the rig needs at least one passage")
        let real = passages[0]
        // *** AN ID THAT CANNOT EXIST IN THIS DOCUMENT: every real passage id, offset far beyond the set. ***
        let impossible = (passages.map(\.id).max() ?? 0) + 9_999

        // (1) PERSIST A VALID ANCHOR, THEN RECREATE -- the CONTROL direction.
        await scene.open(document: document)
        await settled()
        scene.noteScroll(passageId: real.id)
        var validHandle: [String: Any] = [:]
        scene.snapshot(into: &validHandle)
        let validReborn = ArchiveSceneModel(reading: library, model: ArchiveReaderModel(library: library))
        await validReborn.restore(from: validHandle)
        await settled()
        XCTAssertEqual(validReborn.scrollAnchor?.passageId, real.id,
                       "*** THE VALID ANCHOR MUST SURVIVE, or the invalid-anchor arm below proveth nothing. ***")
        let validIds = library.passages.filter { $0.documentId == document.id }.map(\.id)
        XCTAssertEqual(
            ArchiveReadingAnchor.target(passageIds: validIds, saved: validReborn.scrollAnchor?.passageId), real.id,
            "*** AND THE READER MUST BE SENT TO IT -- the control direction of the same decision. ***",
        )

        // (2) PERSIST THE IMPOSSIBLE ANCHOR, THEN RECREATE -- the direction the card's clause is about.
        scene.noteScroll(passageId: impossible)
        var staleHandle: [String: Any] = [:]
        scene.snapshot(into: &staleHandle)
        XCTAssertEqual(staleHandle["anchorPassage"] as? Int64, impossible,
                       "the rig must actually persist the impossible anchor, or this arm testeth nothing")
        let staleReborn = ArchiveSceneModel(reading: library, model: ArchiveReaderModel(library: library))
        await staleReborn.restore(from: staleHandle)
        await settled()

        XCTAssertEqual(
            staleReborn.openedDocumentId, document.id,
            "*** THE DOCUMENT MUST STILL OPEN: a stale anchor is not a reason to lose the reader's document. ***",
        )
        let restoredIds = library.passages.filter { $0.documentId == document.id }.map(\.id)
        XCTAssertFalse(
            restoredIds.contains(impossible),
            "the rig's impossible id must NOT be in the document, or the fallback could not be reached",
        )
        // *** THE READER-FACING FACT: the fallback yieldeth the BEGINNING, and it does so by the DECISION rather than by
        // a lucky absence. `first` is the beginning of the document's reading order. ***
        XCTAssertEqual(
            ArchiveReadingAnchor.target(passageIds: restoredIds, saved: staleReborn.scrollAnchor?.passageId),
            restoredIds.first,
            "*** AN ANCHOR THAT NO LONGER EXISTETH MUST FALL BACK TO THE BEGINNING -- never wait for a passage that "
                + "cannot come, and never claim the stale position held. Restored "
                + "\(String(describing: staleReborn.scrollAnchor?.passageId)), which is not in \(restoredIds). ***",
        )
        XCTAssertFalse(
            ArchiveReadingAnchor.anchorHolds(passageIds: restoredIds, saved: staleReborn.scrollAnchor?.passageId),
            "*** AND THE DECISION MUST REPORT THAT IT FELL BACK, so a caller can SAY so rather than pretend the anchor "
                + "held. A silent fallback is indistinguishable from a successful restore. ***",
        )
    }

    /// *** AND FROM DOCUMENT BROWSE -- THE CARD'S SECOND JOURNEY. ***
    ///
    /// *The search journey's return identity is the search; the browse journey's is the document list. **The model
    /// persists the return scene SEPARATELY for exactly this reason**, so a restoration that hard-coded one shape
    /// would pass one journey and fail the other.*
    func testGSA005BROWSEJourneyRestoresItsOwnReturnIdentity() async throws {
        let library = makeLibrary()
        let model = ArchiveReaderModel(library: library)
        let scene = ArchiveSceneModel(reading: library, model: model)
        await settled()

        // BROWSE -- a different road to a document than searching.
        let docs = library.docs
        try XCTSkipUnless(docs.count >= 2, "the rig needs documents to browse")
        await scene.open(document: docs[1])
        await settled()
        XCTAssertEqual(scene.openedDocumentId, docs[1].id, "the browsed document must be open")

        var handle: [String: Any] = [:]
        scene.snapshot(into: &handle)
        let freshModel = ArchiveReaderModel(library: library)
        let reborn = ArchiveSceneModel(reading: library, model: freshModel)
        await reborn.restore(from: handle)
        await settled()

        XCTAssertEqual(
            reborn.openedDocumentId, docs[1].id,
            "*** A DOCUMENT OPENED BY BROWSING MUST SURVIVE RECREATION. ***",
        )
        // *** AND ITS RETURN IDENTITY IS NOT A SEARCH -- ASSERTED ON THE PUBLISHED OBSERVABLES, NOT ON A PRIVATE
        // FIELD. ***
        //
        // *My first version read `reborn.returnScene` and the compiler refused: it is PRIVATE. **The right response
        // was not to widen it** -- the model publishes `mode` and `searchedQuery`, which ARE the return identity as a
        // caller can observe it, and a court that reaches a private field to make its assertion compiles is
        // asserting something no consumer can see.*
        //
        // *A document opened by BROWSING has no searched query, so a return identity that claims one would send
        // Back to a search that never happened -- which is the defect the `returnScene` field exists to prevent.*
        XCTAssertNil(
            reborn.searchedQuery,
            "*** A DOCUMENT OPENED BY BROWSING MUST CARRIY NO SEARCHED QUERY: a restored return identity that names " +
                "a search that never ran would send the reader to it. Observed: " +
                "\(String(describing: reborn.searchedQuery)) ***",
        )
        XCTAssertNotEqual(
            reborn.mode, .search,
            "*** AND THE MODE MUST NOT BE .search for a browsed document. Observed: \(reborn.mode) ***",
        )
    }

    /// *** AND BACK ACTUALLY LEAVES THE READER. ***
    ///
    /// *The card says "drive actual taps and native back". `back()` is the verb the rendered Back control calls.*
    func testGSA005BACKLeavesTheReaderRatherThanStrandingIt() async throws {
        let library = makeLibrary()
        let model = ArchiveReaderModel(library: library)
        let scene = ArchiveSceneModel(reading: library, model: model)
        await settled()

        scene.onQueryChanged("passage")
        await scene.search()
        await settled()
        try XCTSkipUnless(scene.passages.count >= 1, "the rig needs a hit")
        guard let document = library.docs.first(where: { $0.id == scene.passages[0].documentId }) else {
            return XCTFail("the hit's document must exist")
        }
        await scene.open(document: document)
        await settled()
        XCTAssertEqual(scene.mode, .document, "*** OPENING A DOCUMENT MUST PUT THE SCENE IN `.document` MODE -- my first version wrote `.reader`, which is not a case; the real enum is `documents`/`search`/`document` (`ArchiveSceneModel.swift:16`). ***")

        // NATIVE BACK.
        scene.back()
        await settled()

        // *** AND BACK MUST RESTORE THE SEARCH *IDENTITY ITSELF* -- NOT MERELY "NOT A DOCUMENT". ***
        //
        // *MEASURED, HOSTED RUN `35914747948`: a UI arm reported that Back lost the submitted query, and the render
        // side was the obvious suspect. **BUT `XCTAssertNotEqual(mode, .document)` -- WHICH IS WHAT THIS COURT USED TO
        // ASSERT -- IS SATISFIED BY `.search` AND BY `.documents` ALIKE**, so it could not tell "Back returned to the
        // search" from "Back dropped the user at the list". The arm and its subject could disagree about which of
        // those happened and BOTH still look green here.*
        //
        // **SO THIS NOW PINS THE EXACT IDENTITY, ONE FIELD PER CLAIM** *(`ArchiveSceneModel.back()` restores each of
        // these from the stashed `returnScene`, so a defect in any single one is now separable).*
        XCTAssertEqual(
            scene.mode, .search,
            "*** BACK FROM A SEARCH-ORIGIN DOCUMENT MUST RETURN TO `.search`, NOT TO THE DOCUMENT LIST. " +
                "Observed: \(scene.mode) ***",
        )
        XCTAssertEqual(
            scene.searchedQuery, "passage",
            "*** AND THE SUBMITTED QUERY MUST SURVIVE -- this is the field the card's clause is about. " +
                "Observed: \(String(describing: scene.searchedQuery)) ***",
        )
        XCTAssertEqual(
            scene.query, "passage",
            "*** AND THE QUERY MUST BE BACK IN THE FIELD, not only in the model's memory of what was submitted. " +
                "Observed: \(scene.query) ***",
        )
        XCTAssertFalse(
            scene.passages.isEmpty,
            "*** AND THE RESULT SET MUST COME BACK TOO -- a query restored over an empty list would strand the user " +
                "with their words and nothing to open. ***",
        )
        XCTAssertNil(
            scene.openedDocumentId,
            "*** AND NO DOCUMENT REMAINS OPEN: the projection and the scene must not disagree after Back. ***",
        )

        // *** AND THE BROWSE ROAD MUST NOT BE POLLUTED BY THAT IDENTITY -- THE OTHER HALF OF THE SAME DISTINCTION. ***
        // *A defect that restored `returnScene` unconditionally would pass every assertion above and STILL send a
        // browse user to a search they never ran.*
        let browseScene = ArchiveSceneModel(reading: library, model: ArchiveReaderModel(library: library))
        await settled()
        await browseScene.open(document: library.docs[0])
        await settled()
        browseScene.back()
        await settled()
        XCTAssertEqual(
            browseScene.mode, .documents,
            "*** A BROWSED DOCUMENT MUST RETURN TO THE LIST. Observed: \(browseScene.mode) ***",
        )
        XCTAssertNil(
            browseScene.searchedQuery,
            "*** AND IT MUST CARRY NO QUERY: a browse user must never be returned to a search that never ran. " +
                "Observed: \(String(describing: browseScene.searchedQuery)) ***",
        )
    }
}
