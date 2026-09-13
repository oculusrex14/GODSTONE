import Foundation

/* ============================================================================
 T48 (s17) -- the typed truth of the Archive read road.

 The committed road called an opened file usable (`isAvailable == handle !=
 nil`) and collapsed every SQL woe into the empty list. S17 forbids both:
 "Return [] for SQL failure: error-state/no-results distinction test fails"
 and "treats an opened SQLite file as usable". These enums are the words the
 road now speaketh, and they are the words the UI, the actor library and the
 court all conspire by.
 ============================================================================ */

/// The verdict of the open-time validation. A repository that is not `.ready`
/// refuseth service and saith why; it never serveth the empty lie.
public enum ArchiveAvailability: Sendable, Equatable {
    /// The archive opened read-only, carried the required tables, answered
    /// the schema covenant, matched its tier, was not contentless, passed
    /// integrity_check, and the FTS5 stock was proved by the canary.
    case ready(origin: String)
    /// No such file could be found where the lookup goeth.
    case missing(String)
    /// The bytes are there but are not a sound database (open refused,
    /// integrity cried, or a contentless husk).
    case corrupt(String)
    /// A database it is, but not one this build can serve: a required table
    /// is absent, the schema_version is not the one understood, the file is
    /// not the tier's own, or the FTS5 stock is not to be had.
    case incompatible(String)
    /// The road itself is wounded (a pragma would not seat, the handle is
    /// not walkable). Distinct from `.incompatible`: the archive may be
    /// sound while the way is blocked.
    case readFailure(String)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    /// The tale the empty state of the Archive view telleth.
    public var reasonForDisplay: String {
        switch self {
        case .ready(let origin): return "the archive serveth from \(origin)"
        case .missing(let why): return "missing archive: \(why)"
        case .corrupt(let why): return "corrupt archive: \(why)"
        case .incompatible(let why): return "incompatible archive: \(why)"
        case .readFailure(let why): return "archive read failure: \(why)"
        }
    }

    /// The error a read raiseth when the road was never ready.
    public func asArchiveError() -> ArchiveError {
        switch self {
        case .ready(let origin):
            return .unreadable("a ready repository refuseth nothing; yet this read failed (origin \(origin))")
        case .missing(let why): return .missing(why)
        case .corrupt(let why): return .corrupt(why)
        case .incompatible(let why): return .incompatible(why)
        case .readFailure(let why): return .unreadable(why)
        }
    }
}

/// The failures of the Archive road, told apart. `Equatable` so the court and
/// the published state can compare them word for word.
public enum ArchiveError: Error, Equatable {
    case missing(String)
    case corrupt(String)
    case incompatible(String)
    /// The file chosen is not the database the tier names.
    case wrongTier
    /// archive_meta schema_version is absent or not the one understood.
    case schemaVersion(String)
    /// One of the required tables is not there.
    case noSuchTable(String)
    /// PRAGMA integrity_check did not answer "ok".
    case integrity(String)
    /// The FTS5 canary would not sing.
    case ftsUnavailable(String)
    /// A prepare, a step or a finalize cried. NOT the same as zero rows:
    /// a genuine no-matches result is a success carrying an empty list.
    case queryFailed(String)
    /// The handle itself is not walkable.
    case unreadable(String)

    public var localizedDescription: String {
        switch self {
        case .missing(let w): return "missing archive: \(w)"
        case .corrupt(let w): return "corrupt archive: \(w)"
        case .incompatible(let w): return "incompatible archive: \(w)"
        case .wrongTier: return "wrong tier: the file chosen is not the database this tier names"
        case .schemaVersion(let w): return "schema version: \(w)"
        case .noSuchTable(let w): return "no such table: \(w)"
        case .integrity(let w): return "integrity: \(w)"
        case .ftsUnavailable(let w): return "fts5 unavailable: \(w)"
        case .queryFailed(let w): return "query failed: \(w)"
        case .unreadable(let w): return "unreadable: \(w)"
        }
    }
}

/// What the browser asketh of the library.
public enum ArchiveRequest: Sendable, Equatable {
    case browse
    case search(String)
    case document(Int64)
}

/// What the library answereth, typed.
public enum ArchivePage: Sendable, Equatable {
    case documents([ArchiveDocument])
    case passages([ArchivePassage])
}

/// The seam the reader model turneth upon -- injectable so the court may
/// pause, wound and resurrect a library without a disk in sight.
public protocol ArchiveReading: Sendable {
    func read(_ request: ArchiveRequest) async throws -> ArchivePage
}

/// The bounds of a search petition, enforced before the database is
/// approached. The twin of the sealed Android SearchQuery: the same
/// 512/32/200 bounds, the same strips, the same quarantined grammar --
/// every term led behind double quotes, the terms joined by " OR ".
public enum ArchiveSearchQuery {
    public static let maxPhraseChars = 512
    public static let maxTerms = 32
    public static let maxResults = 200
    /// The characters the sealed road strips to a space.
    public static let stripped = "\"*():^-"

    public enum Built: Equatable {
        case empty
        case ready(match: String, termCount: Int)
        case refused(reason: String)
    }

    public static func build(_ raw: String?) -> Built {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .empty
        }
        if raw.count > maxPhraseChars {
            return .refused(reason: "the query exceedeth the \(maxPhraseChars)-character phrase bound")
        }
        var seen: [String] = []
        var current = ""
        for ch in raw {
            if ch.isWhitespace || stripped.contains(String(ch)) {
                if !current.isEmpty { seen.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { seen.append(current) }
        var terms: [String] = []
        for term in seen {
            if !terms.contains(term) { terms.append(term) } // first-seen order kept
        }
        if terms.isEmpty { return .empty }
        if terms.count > maxTerms {
            return .refused(reason: "the query exceedeth the \(maxTerms)-term bound")
        }
        let match = terms.map { "\"\($0)\"" }.joined(separator: " OR ")
        return .ready(match: match, termCount: terms.count)
    }

    /// The page ceiling: a petition below one readeth as one, a petition
    /// above the ceiling readeth as the ceiling.
    public static func bound(_ limit: Int) -> Int {
        max(1, min(maxResults, limit))
    }
}
