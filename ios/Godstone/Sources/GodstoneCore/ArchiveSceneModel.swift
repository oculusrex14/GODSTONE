import Foundation

/* ============================================================================
 * T50 (s17) -- the reading journey's state owner, iOS side. The isle twin of
 * the sealed android BrowseViewModel (T49): explicit phases (loading, ready,
 * noResults, unavailable with its cause named), the immutable identity of the
 * published search, the generation token deleguated to the main-actor model,
 * back restoration by stash (the road is not ridden again for the back),
 * retry earned only where the road may mend, the journey's place carried
 * through process recreation, the scroll anchor preserved, and the spoken
 * tale sanitised -- the engine's diagnostics never travel to the user's eye.
 * The view rendereth; this model speaketh.
 * ========================================================================== */

/// The three places the browse journey standeth.
public enum ArchiveSceneMode: String, Sendable, Equatable {
    case documents
    case search
    case document
}

/// The explicit phase of the road. An unavailable archive is told as
/// .unavailable with its cause named -- it never masqueradeth as the honest
/// empty .noResults, which meaneth only: the archive is ready and this word
/// matched nobody.
public enum ArchivePhase: Sendable, Equatable {
    case loading
    case ready
    case noResults
    case unavailable(reason: String, recoverable: Bool)

    public var isUnavailable: Bool {
        if case .unavailable = self { return true }
        return false
    }
}

/// The tale the banner telleth, sanitised. The spoken form is a fixed
/// sentence per kind of woe; the engine's own words (prepare failures,
/// step codes, errmsg fragments, SQL fragments) are kept apart for the
/// log, never for the user's eye.
public enum ArchiveUserMessage {
    public static func spoken(for error: ArchiveError) -> String {
        switch error {
        case .missing:            return "the archive is not installed"
        case .corrupt:            return "the archive is corrupt"
        case .incompatible:       return "the archive is not compatible with this build"
        case .wrongTier:          return "the archive belongs to another tier"
        case .schemaVersion:      return "the archive was built for a different schema"
        case .noSuchTable:        return "the archive is missing a required table"
        case .integrity:          return "the archive failed its integrity check"
        case .ftsUnavailable:     return "search is unavailable on this stock"
        case .queryFailed:        return "the search could not be completed"
        case .unreadable:         return "the archive could not be read"
        }
    }

    /// The full tale for the diagnostic log only -- never rendered.
    public static func diagnostic(for error: ArchiveError) -> String {
        switch error {
        case .missing(let why):           return "missing: " + why
        case .corrupt(let why):           return "corrupt: " + why
        case .incompatible(let why):      return "incompatible: " + why
        case .wrongTier:            return "wrongTier"
        case .schemaVersion(let why):     return "schemaVersion: " + why
        case .noSuchTable(let why):       return "noSuchTable: " + why
        case .integrity(let why):         return "integrity: " + why
        case .ftsUnavailable(let why):    return "ftsUnavailable: " + why
        case .queryFailed(let why):       return "queryFailed: " + why
        case .unreadable(let why):        return "unreadable: " + why
        }
    }
}

/// Where the reader stood when the road was left; restored upon return.
public struct ArchiveScrollAnchor: Sendable, Equatable {
    public let documentId: Int64?
    public let passageId: Int64?
    public init(documentId: Int64? = nil, passageId: Int64? = nil) {
        self.documentId = documentId
        self.passageId = passageId
    }
}

private struct Scene {
    let mode: ArchiveSceneMode
    let query: String
    let searchedQuery: String?
    let documents: [ArchiveDocument]
    let passages: [ArchivePassage]
    let openedDocumentId: Int64?
    let openedTitle: String?
    let openedSource: ArchiveSourceMetadata?
}

/// The journey's state owner. @MainActor, as the sealed reader model: the
/// view bindeth to its published fields; every road runneth through the
/// injected ArchiveReading, off the main thread's shoulder.
/// A captured petition: the phrase, the token, and the moment of its
/// taking. Dispatch is synchronous and observeth the epoch as it stands;
/// travel is asynchronous and gateh both ways. A petition born before a
/// supersession cannot travel unobserved (the T50 court's second campaign
/// taught it: a token taken at the body's start observeth nothing that
/// came before the body).
public struct SearchPetition: Sendable {
    public let phrase: String
    public let token: UInt64
}

@MainActor
public final class ArchiveSceneModel: ObservableObject {

    @Published public private(set) var query: String = ""
    /// The identity of the search actually published -- editing the field
    /// never relabelleth submitted results.
    @Published public private(set) var searchedQuery: String?
    @Published public private(set) var mode: ArchiveSceneMode = .documents
    @Published public private(set) var phase: ArchivePhase = .loading
    @Published public private(set) var documents: [ArchiveDocument] = []
    @Published public private(set) var passages: [ArchivePassage] = []
    @Published public private(set) var openedDocumentId: Int64?
    @Published public private(set) var openedTitle: String?
    @Published public private(set) var openedSource: ArchiveSourceMetadata?
    @Published public private(set) var error: String?
    @Published public private(set) var canRetry: Bool = false
    @Published public private(set) var scrollAnchor: ArchiveScrollAnchor?

    private let reading: any ArchiveReading
    private let model: ArchiveReaderModel
    /* The scene's own token, beside the model's: every request captureth it
     * before delivery and revalidateth it after the road, that no stale
     * completion -- good or failing -- publisheth over the present one. */
    private var epoch: UInt64 = 0
    private var returnScene: Scene?
    private var lastRequest: (() async -> Void)?

    public init(reading: any ArchiveReading, model: ArchiveReaderModel) {
        self.reading = reading
        self.model = model
    }

    /// The field gate: the bound the engine itself commandeth.
    public func onQueryChanged(_ value: String) {
        query = String(value.prefix(ArchiveSearchQuery.maxPhraseChars))
    }

    /// The synchronous prologue of the search road: the phrase and the token
    /// are taken NOW, the pre-arm publisheth under the current epoch, and the
    /// petition is born. nil answereth when the field is blank -- the caller
    /// returneth to the root instead (the blank-petition law).
    @discardableResult
    public func dispatchSearch() -> SearchPetition? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        epoch &+= 1
        let petition = SearchPetition(phrase: trimmed, token: epoch)
        lastRequest = { [weak self] in
            guard let self else { return }
            if let fresh = self.dispatchSearch() { await self.travel(fresh) }
            else { self.backToDocuments() }
        }
        phase = .loading
        error = nil
        canRetry = false
        return petition
    }

    /// The asynchronous way of the search road: gateh before the engine,
    /// travelleth, gateh again after it -- a petition whose epoch hath been
    /// supanted over publisheth nothing at all.
    public func travel(_ petition: SearchPetition) async {
        if epoch != petition.token { return }   // stale before the road
        await model.load(.search(petition.phrase))
        if epoch != petition.token { return }   // stale after the road
        if case .failed(let archiveError) = model.state {
            publishFailure(archiveError)
            return
        }
        // the verdict of the stock is consulted first, that an absent
        // archive be not mistaken for an empty one.
        let hits = passagesOf(model.state)
        switch reading.availability {
        case .ready:
            searchedQuery = petition.phrase
            query = petition.phrase   // the trim publish: the field telleth what stands published
            documents = []
            passages = hits ?? []
            openedDocumentId = nil
            openedTitle = nil
            openedSource = nil
            if let hits, !hits.isEmpty {
                phase = .ready; mode = .search; error = nil; canRetry = false
            } else {
                phase = .noResults; mode = .search; error = nil; canRetry = false
            }
        case .missing, .corrupt, .incompatible, .readFailure:
            publishAbsent()
        }
    }

    /// The single-call form for callers that cannot split: dispatch and
    /// travel in one breath.
    public func search() async {
        if let petition = dispatchSearch() {
            await travel(petition)
        } else {
            backToDocuments()
        }
    }

    /// A search hit openeth the WHOLE document, not only the matched passage.
    public func open(document: ArchiveDocument) async {
        stashScene()
        await openDocumentInternal(id: document.id, title: document.title)
    }

    public func openPassage(_ passage: ArchivePassage) async {
        stashScene()
        await openDocumentInternal(id: passage.documentId, title: passage.documentTitle)
    }

    private func openDocumentInternal(id: Int64, title: String) async {
        epoch &+= 1
        let mine = epoch
        lastRequest = { [weak self] in await self?.openDocumentInternal(id: id, title: title) }
        phase = .loading
        error = nil
        canRetry = false
        await model.load(.document(id))
        if epoch != mine { return }   // stale after the road (the model's token gate is the second belt)
        if case .failed(let archiveError) = model.state {
            publishFailure(archiveError)
            return
        }
        let found = passagesOf(model.state)
        switch reading.availability {
        case .ready:
            let source = reading.sourceMetadata(documentId: id)
            mode = .document
            documents = []
            passages = found ?? []
            openedDocumentId = id
            openedTitle = title
            openedSource = source
            phase = .ready
        case .missing, .corrupt, .incompatible, .readFailure:
            publishAbsent()
        }
    }

    /// Back restoration: from the document, the scene from which it was
    /// opened returneth untouched -- the query, its published identity and
    /// the results stand again, the road not ridden again.
    public func back() {
        switch mode {
        case .document:
            guard let scene = returnScene else { backToDocuments(); return }
            generationBump()
            returnScene = nil
            mode = scene.mode
            query = scene.query
            searchedQuery = scene.searchedQuery
            documents = scene.documents
            passages = scene.passages
            openedDocumentId = scene.openedDocumentId
            openedTitle = scene.openedTitle
            openedSource = scene.openedSource
            phase = (scene.mode == .search && (scene.searchedQuery != nil) && scene.passages.isEmpty)
                ? .noResults : .ready
            error = nil
            canRetry = false
            if scene.mode == .documents && scene.documents.isEmpty {
                Task { await self.loadDocuments() }
            }
        case .search:
            backToDocuments()
        case .documents:
            break   // already at the root: the journey resteth
        }
    }

    public func backToDocuments() {
        generationBump()
        returnScene = nil
        query = ""
        searchedQuery = nil
        mode = .documents
        openedDocumentId = nil
        openedTitle = nil
        openedSource = nil
        error = nil
        canRetry = false
        Task { await self.loadDocuments() }
    }

    /// Retry only where the road may mend: a failed request is replayable;
    /// an absent archive is the installer's to mend, not the reader's.
    public func retry() async {
        guard canRetry else { return }
        await lastRequest?()
    }

    /// The dismissal seam: a view going away striketh out the in-flight
    /// petition; late arrivals publish nothing.
    public func dismiss() {
        epoch &+= 1
        model.cancelInFlight()
    }

    /// Where the reader stood; remembered for the return.
    public func noteScroll(documentId: Int64? = nil, passageId: Int64? = nil) {
        scrollAnchor = ArchiveScrollAnchor(documentId: documentId, passageId: passageId)
    }

    /// Process recreation: the journey's place, the query and the opened
    /// identity travel through a property-list handle and stand again.
    public func snapshot(into handle: inout [String: Any]) {
        handle["query"] = query
        if let searchedQuery { handle["searchedQuery"] = searchedQuery }
        handle["mode"] = mode.rawValue
        if let openedDocumentId { handle["openedDocumentId"] = openedDocumentId }
        if let openedTitle { handle["openedTitle"] = openedTitle }
        if let scrollAnchor {
            if let d = scrollAnchor.documentId { handle["anchorDocument"] = d }
            if let p = scrollAnchor.passageId { handle["anchorPassage"] = p }
        }
    }

    public func restore(from handle: [String: Any]) async {
        generationBump()
        let modeName = handle["mode"] as? String
        mode = ArchiveSceneMode(rawValue: modeName ?? "documents") ?? .documents
        query = handle["query"] as? String ?? ""
        searchedQuery = handle["searchedQuery"] as? String
        let anchorDocument = handle["anchorDocument"] as? Int64
        let anchorPassage = handle["anchorPassage"] as? Int64
        scrollAnchor = ArchiveScrollAnchor(documentId: anchorDocument, passageId: anchorPassage)
        returnScene = Scene(mode: .documents, query: "", searchedQuery: nil,
                             documents: [], passages: [],
                             openedDocumentId: nil, openedTitle: nil, openedSource: nil)
        phase = .loading
        error = nil
        canRetry = false
        switch mode {
        case .document:
            if let id = handle["openedDocumentId"] as? Int64 {
                await openDocumentInternal(id: id, title: handle["openedTitle"] as? String ?? "")
            } else {
                await loadDocuments()
            }
        case .search:
            if let s = searchedQuery, !s.isEmpty {
                query = s
                await search()
            } else {
                await loadDocuments()
            }
        case .documents:
            await loadDocuments()
        }
    }

    /// The root of the journey: the documents list. Public for the first
    /// browse (the view's .task) and the mended return.
    public func loadDocuments() async {
        phase = .loading
        error = nil
        canRetry = false
        mode = .documents
        openedDocumentId = nil
        openedTitle = nil
        openedSource = nil
        epoch &+= 1
        let mine = epoch
        lastRequest = { [weak self] in await self?.loadDocuments() }
        if epoch != mine { return }                       // stale before the road
        await model.load(.browse)
        if epoch != mine { return }                       // stale after the road
        if case .failed(let archiveError) = model.state {
            publishFailure(archiveError)
            return
        }
        let found = documentsOf(model.state)
        switch reading.availability {
        case .ready:
            documents = found ?? []
            passages = []
            phase = (found?.isEmpty == false) ? .ready : .noResults
        case .missing, .corrupt, .incompatible, .readFailure:
            publishAbsent()
        }
    }

    // -- the machinery beneath ---------------------------------------------------

    /// Strike out every stale petition: the scene's token rotateth and the
    /// model's with it; no in-flight road shall publish over the newer.
    private func generationBump() {
        epoch &+= 1
        model.cancelInFlight()
    }

    private func publishAbsent() {
        let why = reasonOf(reading.availability)
        documents = []
        passages = []
        openedDocumentId = nil
        openedTitle = nil
        openedSource = nil
        error = nil
        canRetry = false
        phase = .unavailable(reason: why, recoverable: false)
    }

    private func reasonOf(_ availability: ArchiveAvailability) -> String {
        switch availability {
        case .ready:                      return "the reader reporteth not"
        case .missing(let why), .corrupt(let why),
             .incompatible(let why), .readFailure(let why): return why
        }
    }

    private func passagesOf(_ state: ArchiveReaderModel.State) -> [ArchivePassage]? {
        if case .loaded(let page) = state, case .passages(let hits) = page { return hits }
        return nil
    }

    private func documentsOf(_ state: ArchiveReaderModel.State) -> [ArchiveDocument]? {
        if case .loaded(let page) = state, case .documents(let rows) = page { return rows }
        return nil
    }

    private func stashScene() {
        if mode != .document {
            returnScene = Scene(mode: mode, query: query, searchedQuery: searchedQuery,
                                documents: documents, passages: passages,
                                openedDocumentId: nil, openedTitle: nil, openedSource: nil)
        }
    }

    /// The failure road: the shown tale is sanitised; only the kind of the
    /// woe is named to the eye. The model carrieth the error in its state.
    internal func publishFailure(_ archiveError: ArchiveError) {
        documents = []
        passages = []
        openedDocumentId = nil
        openedTitle = nil
        openedSource = nil
        error = ArchiveUserMessage.spoken(for: archiveError)
        // the kind of the woe decideth whether the road may mend: a momentary
        // query or read failure is retriable; a missing, corrupt or
        // incompatible installation is the installer's to mend, not the reader's
        let mendable: Bool
        switch archiveError {
        case .queryFailed, .unreadable:
            mendable = true
        case .missing, .corrupt, .incompatible, .wrongTier, .schemaVersion,
             .noSuchTable, .integrity, .ftsUnavailable:
            mendable = false
        }
        phase = .unavailable(
            reason: ArchiveUserMessage.spoken(for: archiveError) + " (" + kindOf(archiveError) + ")",
            recoverable: mendable)
        canRetry = mendable
    }

    private func kindOf(_ archiveError: ArchiveError) -> String {
        switch archiveError {
        case .missing:      return "missing"
        case .corrupt:      return "corrupt"
        case .incompatible: return "incompatible"
        case .wrongTier:    return "wrong-tier"
        case .schemaVersion: return "schema-version"
        case .noSuchTable:  return "no-such-table"
        case .integrity:    return "integrity"
        case .ftsUnavailable: return "fts-unavailable"
        case .queryFailed:  return "query-failed"
        case .unreadable:   return "unreadable"
        }
    }
}
