import Foundation
import Combine

/* ============================================================================
 T48 (s17) -- port of the WIP ArchiveReaderModel.swift (original checkout,
 never yet walked by this ladder), strengthened where the sealed Android twin
 (T47) taught what the road must say.

 The WIP's ArchiveLibrary re-opened the file on every read when
 `repository.isAvailable == false` -- an existence-shaped probe loop that,
 over a corrupt archive, cryeth "available or not" anew on every keystroke
 and never tells WHY. The port openeth ONCE, keepeth the typed verdict, and
 refuseth service naming its cause.

 The WIP's generation-token discipline in the reader model was sound and is
 kept verbatim: capture the token BEFORE dispatch, verify it under the main
 actor BEFORE any publish, and a cancelled or superseded completion moveth
 nothing.
 ============================================================================ */

/// Owns the repository and all SQLite work on an actor executor, away from
/// the main actor. Opening and validating a large archive thus never blocks
/// a UI turn.
public actor ArchiveLibrary: ArchiveReading {
    private let databaseName: String
    private let tier: Tier
    // T50 (s17): the repository binding, exposed nonisolated -- an immutable
    // let of a Sendable type, published once in init; the synchronous
    // witnesses below may read it without hopping the actor's executor.
    nonisolated private let repository: ArchiveRepository

    public init(databaseName: String, tier: Tier) {
        self.databaseName = databaseName
        self.tier = tier
        // One honest open, with the validation pipeline running behind it.
        // Not re-opened per read: the archive is immutable; a second open of
        // a corrupt husk calleth the same woe anew and achieveth nothing.
        self.repository = ArchiveRepository(databaseName: databaseName, expectedTier: tier)
    }

    /// The typed verdict, for the view that wisheth to tell the user why nothing
    /// answers. Never a bare boolean.
    nonisolated public var availability: ArchiveAvailability { repository.availability }

    /// T50 (s17): the provenance probe, forwarded nonisolated to the
    /// repository's own locked roads -- thread-safe by the repository's lock.
    nonisolated public func sourceMetadata(documentId: Int64) -> ArchiveSourceMetadata? {
        repository.sourceMetadata(documentId: documentId)
    }

    /// Release the native handle now rather than trust the timing of ARC --
    /// the stop half of the stop/start lifecycle the boundary must exercise.
    public func close() { repository.close() }

    public func read(_ request: ArchiveRequest) async throws -> ArchivePage {
        try Task.checkCancellation()
        // Serve nothing that was not proved ready at open.
        guard repository.availability.isReady else {
            throw repository.availability.asArchiveError()
        }
        let page: ArchivePage
        switch request {
        case .browse:
            page = .documents(try repository.listDocumentsChecked(domain: nil))
        case .search(let query):
            page = .passages(try repository.searchChecked(query, limit: 40))
        case .document(let id):
            page = .passages(try repository.passagesChecked(documentId: id))
        }
        try Task.checkCancellation()
        return page
    }
}

/// The main-actor face of the browser. Publisheth loading / loaded / failed
/// and keeps stale completions from ever overwriting the present results.
@MainActor
public final class ArchiveReaderModel: ObservableObject {
    public enum State: Equatable {
        case idle
        case loading
        case loaded(ArchivePage)
        case failed(ArchiveError)
    }

    @Published public private(set) var state: State = .idle

    private let library: any ArchiveReading
    /// The generation token. Every load captureth a new one; only a completion
    /// whose token is still the present one may publish.
    private var activeRequest = UUID()

    public init(library: any ArchiveReading) { self.library = library }

    public func load(_ request: ArchiveRequest) async {
        let requestID = UUID()
        activeRequest = requestID
        state = .loading
        do {
            let page = try await library.read(request)
            try Task.checkCancellation()
            guard activeRequest == requestID else { return } // stale: verbatim from the WIP
            state = .loaded(page)
        } catch is CancellationError {
            // A dismissed view or a superseded search must never publish a
            // result -- nor an error -- verbatim from the WIP.
            return
        } catch {
            guard !Task.isCancelled, activeRequest == requestID else { return }
            state = .failed(error as? ArchiveError ?? .queryFailed(String(describing: error)))
        }
    }

    /// Dismiss the in-flight petition: its completion, good or evil, findeth
    /// the token rotated and publisheth nothing.
    public func cancelInFlight() {
        activeRequest = UUID()
        state = .idle
    }
}
