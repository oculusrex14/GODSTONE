// SYNTHESIZED gap-closure file -- authored to make the project compile; see docs/AUDIT.md.
import Foundation

/// One retrieved Archive chunk, fused from lexical and semantic search.
///
/// Mirrors the Android `Chunk` data class (`chunkId`, `documentId`,
/// `documentTitle`, `domain`, `text`, `score`) plus the `section` field used by
/// the iOS citation UI. `score` is mutable because `RagPipeline.fuse` overwrites
/// it with the normalised reciprocal-rank-fusion score before the prompt is
/// built and the citation list is emitted.
public struct RetrievedChunk: Sendable {

    public let chunkId: Int64
    public let documentId: Int64
    public let documentTitle: String
    public let section: String
    public let domain: String
    public let text: String
    public var score: Double

    public init(chunkId: Int64,
                documentId: Int64,
                documentTitle: String,
                section: String,
                domain: String,
                text: String,
                score: Double) {
        self.chunkId = chunkId
        self.documentId = documentId
        self.documentTitle = documentTitle
        self.section = section
        self.domain = domain
        self.text = text
        self.score = score
    }
}
