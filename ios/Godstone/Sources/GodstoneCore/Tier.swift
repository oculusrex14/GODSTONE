// SYNTHESIZED gap-closure file -- authored to make the project compile; see docs/AUDIT.md.
import Foundation

/// Device capability tier.
///
/// Three tiers -- light, medium, large -- select the on-device model, the
/// context window, the retrieval depth and the archive database. The tier is
/// read once from the app's Info.plist (`GodstoneTier` = LIGHT|MEDIUM|LARGE)
/// and defaults to `.light`, the safe-everywhere option.
///
/// Mirrors the Android `Tier` enum in the core module. The two must agree on
/// model file names, context token counts and archive database names or the
/// same device class loads a different model on each platform.
public enum Tier: Sendable {

    case light
    case medium
    case large

    /// Active tier, resolved from the main bundle's Info.plist.
    public static var current: Tier {
        if let raw = Bundle.main.object(forInfoDictionaryKey: "GodstoneTier") as? String {
            switch raw.uppercased() {
            case "MEDIUM": return .medium
            case "LARGE":  return .large
            default:       return .light
            }
        }
        return .light
    }

    /// Bundled GGUF file name, e.g. "qwen3-0.6b-q4km.gguf".
    public var modelFile: String {
        switch self {
        case .light:  return "qwen3-0.6b-q4km.gguf"
        case .medium: return "qwen3-1.7b-q4km.gguf"
        case .large:  return "qwen3-4b-q5km.gguf"
        }
    }

    /// Convenience alias for `modelFile` (some call sites name it as a "file
    /// name" rather than a "file"). Kept in sync with `modelFile`.
    public var modelFileName: String { modelFile }

    /// KV-cache context window in tokens.
    public var contextTokens: Int {
        switch self {
        case .light:  return 2048
        case .medium: return 4096
        case .large:  return 8192
        }
    }

    /// Number of fused chunks kept after reciprocal-rank fusion.
    public var topKChunks: Int {
        switch self {
        case .light:  return 4
        case .medium: return 6
        case .large:  return 8
        }
    }

    /// Chunks surfaced to retrieval; equal to `topKChunks` on every tier.
    public var retrievalChunks: Int { topKChunks }

    /// Embedding GGUF the ARCHIVE was built with. Must match
    /// content/ingest/build_archive.py TIERS[*]["embed_model"], or semantic
    /// search compares two unrelated vector spaces.
    public var embedModelFile: String {
        switch self {
        case .light:  return "bge-small-en-v1.5-q8.gguf"
        case .medium: return "bge-small-en-v1.5-q8.gguf"
        case .large:  return "bge-base-en-v1.5-q8.gguf"
        }
    }

    /// Embedding dimension. Cross-checked against archive_meta.embed_dim.
    public var embedDim: Int {
        switch self {
        case .light, .medium: return 384
        case .large:          return 768
        }
    }

    /// Archive SQLite database bundled resource name.
    public var archiveDatabaseName: String {
        switch self {
        case .light:  return "archive_light.db"
        case .medium: return "archive_medium.db"
        case .large:  return "archive_large.db"
        }
    }
}
