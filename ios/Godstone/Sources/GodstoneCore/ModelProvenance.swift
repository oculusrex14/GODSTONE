import Foundation
import CryptoKit

/*
 T61 model-provenance law, iOS isle -- the twin of the tested Python authority
 scripts/model_provenance.py and of the Android io.godstone.llm.provenance
 package. The strict register (schema 2) refuseth: future or unknown schemas;
 a mutable branch head where an immutable 40-hex source commit is demanded;
 missing or malformed digests; absent licence oaths; path traversal at either
 door; duplicate identifiers and duplicate destinations; truncated GGUF
 containers; unsupported architectures; unknown fields of every estate; and
 embedding models that will not swear their pooling, normalization and
 dimension. An UNPINNED register must be wholly unsworn: any half-pinned
 mixture is the very mutable-trusting disease this gate keepeth out. Bounded
 temporary files are promoted atomically; a failed verification never toucheth
 the authoritative destination. Nothing here speaketh on the shipping runtime
 path over the wire: the network fetch liveth in the developer authority
 (scripts/model_provenance.py) alone. The JSON reader is hand-rolled and
 STRICTER than its Python kin: duplicate keys are refused, not silently
    folded; only printable-ASCII \u escapes are admitted, while the C0 escapes \b and \f be refused -- a tightening,
 never a loosening, of the same law.
*/

public let T61MaxChunk = 1048576            // one mebibyte, the bounded read
public let T61MaxArrayBytes = 1073741824    // two tebibytes, the array ceiling

public let T61Tiers: [String] = ["LIGHT", "MEDIUM", "LARGE"]
public let T61Poolings: [String] = ["none", "mean", "cls", "last"]
public let T61Normalizations: [String] = ["none", "l2"]
public let T61Kinds: [String] = ["generation", "embedding"]
public let T61Abis: [String] = ["arm64-v8a", "x86-64"]
public let T61Statutes: [String] = ["UNPINNED", "PINNED"]
public let T61ArtifactKeys: [String] = ["id", "kind", "tiers", "repo", "source_commit",
    "source_file", "output_file", "sha256", "size_bytes", "license",
    "tokenizer", "context_tokens", "embedding", "native_abi"]
public let T61ProvenanceKeys: [String] = ["source_commit", "sha256", "size_bytes", "license",
    "tokenizer", "context_tokens", "embedding", "native_abi"]
public let T61TopKeys: Set<String> = ["schema", "status", "verified_on", "verified_by",
    "notes", "native", "artifacts"]
public let T61NativeKeys: Set<String> = ["llama_revision", "source_repo", "build_flags",
    "toolchains", "abis"]
public let T61EmbeddingKeys: Set<String> = ["pooling", "normalization", "dimension"]
public let T61LegacyKeys: Set<String> = ["id", "tiers", "repo", "source_file", "output_file",
    "sha256"]

public struct ProvenanceError: Error, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

private func t61Swear(_ condition: Bool, _ cry: () -> String) throws {
    if !condition { throw ProvenanceError(cry()) }
}

// ---------------------------------------------------------------------------
// The character classes of the register, hand-rolled (no regexes cross this
// isle). Every set below is the very class the Python authority compilith.
// ---------------------------------------------------------------------------

private let t61LowerSet = Array("abcdefghijklmnopqrstuvwxyz")
private let t61UpperSet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
private let t61DigitSet = Array("0123456789")
private let t61HexSet = Array("0123456789abcdef")
private let t61IdTailSet = Array("abcdefghijklmnopqrstuvwxyz0123456789_-")
private let t61NameSet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
private let t61FlagSet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+=,/._%-")
private let t61ToolSet = Array("0123456789.")

private func t61Quoted(_ xs: [String]) -> String {
    return "[" + xs.map { "\"" + $0 + "\"" }.joined(separator: ", ") + "]"
}

private func t61Num(_ v: Int) -> String { return "\(v)" }

private func t61In(_ c: Character, _ set: [Character]) -> Bool {
    var i = 0
    while i < set.count { if set[i] == c { return true }; i += 1 }
    return false
}

private func t61AllIn(_ s: String, _ set: [Character]) -> Bool {
    for c in s { if !t61In(c, set) { return false } }
    return s.count > 0
}

private func t61IsHex(_ s: String, _ width: Int) -> Bool {
    var n = 0
    for c in s { if !t61In(c, t61HexSet) { return false }; n += 1 }
    return n == width
}

private func t61IsId(_ s: String) -> Bool {
    var n = 0
    for c in s {
        if n == 0 { if !t61In(c, t61LowerSet) && !t61In(c, t61DigitSet) { return false } }
        else { if !t61In(c, t61IdTailSet) { return false } }
        n += 1
    }
    return n > 0
}

private func t61IsRepo(_ s: String) -> Bool {
    var n = 0
    var slashes = 0
    for c in s {
        if c == "/" { slashes += 1 }
        else if !t61In(c, t61NameSet) { return false }
        n += 1
    }
    return slashes == 1 && n > 2
}

/* The basename law: a plain .gguf name, no separators, no traversal. */
private func t61IsBasename(_ s: String) -> Bool {
    if s.count < 6 { return false }
    if !t61AllIn(s, t61NameSet) { return false }
    let a = Array(s)
    let want = Array(".gguf")
    var i = 0
    while i < 5 { if a[a.count - 5 + i] != want[i] { return false }; i += 1 }
    return true
}

/* The legacy estate knoweth plain basenames only: no separators, no dots-twice. */
private func t61IsPlainName(_ s: String) -> Bool {
    if s.isEmpty { return false }
    if s == "." || s == ".." { return false }
    for c in s { if c == "/" { return false } }
    return true
}

private func t61IsFlag(_ s: String) -> Bool {
    var n = 0
    for c in s {
        if n == 0 { if c != "-" { return false } }
        else { if !t61In(c, t61FlagSet) { return false } }
        n += 1
    }
    return n > 1
}

private func t61IsToolVersion(_ s: String) -> Bool {
    var n = 0
    for c in s {
        if n == 0 { if !t61In(c, t61DigitSet) { return false } }
        else { if !t61In(c, t61ToolSet) { return false } }
        n += 1
    }
    return n > 0
}

public func t61ShaHex(_ bytes: [UInt8]) -> String {
    var hasher = SHA256()
    hasher.update(data: Data(bytes))
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

// ---------------------------------------------------------------------------
// The strict JSON reader. Duplicate keys, trailing matter, fractions and
// deep nesting be all refused. Integers arrive as Int; null as T61Null.
// ---------------------------------------------------------------------------

public struct T61Null: Sendable, Equatable {
    public init() {}
}

private let t61Printables = Array(" !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~")

private let t61MaxDepth = 24

private struct T61JsonReader {
    private let chars: [Character]
    private var at = 0
    private let limit = t61MaxDepth

    init(_ text: String) { chars = Array(text) }

    private func fail(_ cry: String) throws -> Never {
        throw ProvenanceError("model lock JSON: " + cry + " (offset " + t61Num(at) + ")")
    }

    private func peek() throws -> Character {
        if at >= chars.count { try fail("document endeth unexpectidly") }
        return chars[at]
    }

    private mutating func bump() throws -> Character {
        let c = try peek()
        at += 1
        return c
    }

    private mutating func expect(_ c: Character, _ what: String) throws {
        let got = try bump()
        if got != c { try fail("expected " + what) }
    }

    private mutating func skipBlanks() {
        while at < chars.count {
            let c = chars[at]
            if c == " " || c == "\n" || c == "\t" || c == "\r" { at += 1 }
            else { break }
        }
    }

    private mutating func literal(_ word: String, _ what: String) throws {
        let wcs = Array(word)
        if at + wcs.count > chars.count { try fail("expected " + what) }
        var k = 0
        while k < wcs.count {
            if chars[at + k] != wcs[k] { try fail("expected " + what) }
            k += 1
        }
        at += wcs.count
    }

    private mutating func string() throws -> String {
        try expect("\"", "a quotation")
        var out = ""
        while true {
            if at >= chars.count { try fail("unterminated string") }
            let c = chars[at]
            at += 1
            if c == "\"" { return out }
            if c != "\\" { out.append(c); continue }
            let e = try bump()
            if e == "\"" { out.append("\"") }
            else if e == "\\" { out.append("\\") }
            else if e == "/" { out.append("/") }
            else if e == "b" { try fail("unprintable escape b in the strict register") }
            else if e == "f" { try fail("unprintable escape f in the strict register") }
            else if e == "n" { out.append("\n") }
            else if e == "r" { out.append("\r") }
            else if e == "t" { out.append("\t") }
            else if e == "u" {
                var value = 0
                var k = 0
                while k < 4 {
                    let d = try bump()
                    var dig = -1
                    var h = 0
                    while h < t61HexSet.count { if t61HexSet[h] == d { dig = h % 16 }; h += 1 }
                    if dig < 0 { try fail("bad hex digit in \\u escape") }
                    value = value * 16 + dig
                    k += 1
                }
                if value < 32 || value > 126 {
                    try fail("\\u escape outside the printable ASCII tale")
                }
                out.append(t61Printables[value - 32])
            }
            else { try fail("unknown escape") }
        }
    }

    private mutating func number() throws -> Int {
        var negative = false
        if chars[at] == "-" { negative = true; at += 1 }
        var value = 0
        var digits = 0
        while at < chars.count {
            let c = chars[at]
            var dig = -1
            var d = 0
            while d < t61DigitSet.count { if t61DigitSet[d] == c { dig = d }; d += 1 }
            if dig < 0 { break }
            value = value * 10 + dig
            digits += 1
            at += 1
        }
        if digits == 0 { try fail("malformed number") }
        if at < chars.count, chars[at] == "." || chars[at] == "e" || chars[at] == "E" {
            try fail("fractional and exponent numbers have no place in a strict register")
        }
        return negative ? -value : value
    }

    private mutating func value(_ depth: Int) throws -> Any {
        if depth > limit { try fail("nesting deeper than " + t61Num(limit)) }
        skipBlanks()
        let c = try peek()
        if c == "{" { return try object(depth + 1) }
        if c == "[" { return try array(depth + 1) }
        if c == "\"" { return try string() }
        if c == "n" { try literal("null", "null"); return T61Null() }
        if c == "t" { try literal("true", "true"); return true }
        if c == "f" { try literal("false", "false"); return false }
        return try number()
    }

    private mutating func object(_ depth: Int) throws -> [String: Any] {
        try expect("{", "an open brace")
        var out: [String: Any] = [:]
        skipBlanks()
        if try peek() == "}" { at += 1; return out }
        while true {
            skipBlanks()
            let key = try string()
            if out[key] != nil { try fail("duplicate key '" + key + "' in one object") }
            skipBlanks()
            try expect(":", "a colon")
            let v = try value(depth)
            out[key] = v
            skipBlanks()
            let sep = try bump()
            if sep == "," { continue }
            if sep == "}" { return out }
            try fail("expected ',' or '}'")
        }
    }

    private mutating func array(_ depth: Int) throws -> [Any] {
        try expect("[", "an open bracket")
        var out: [Any] = []
        skipBlanks()
        if try peek() == "]" { at += 1; return out }
        while true {
            out.append(try value(depth))
            skipBlanks()
            let sep = try bump()
            if sep == "," { continue }
            if sep == "]" { return out }
            try fail("expected ',' or ']'")
        }
    }

    mutating func read() throws -> Any {
        let v = try value(0)
        skipBlanks()
        if at != chars.count { try fail("trailing matter after the model lock document") }
        return v
    }
}

public func t61ParseJson(_ text: String) throws -> Any {
    var reader = T61JsonReader(text)
    return try reader.read()
}

// ---------------------------------------------------------------------------
// The GGUF header walk. A container that will not walk wholly is no container.
// ---------------------------------------------------------------------------

public struct GgufHeader: Sendable, Equatable {
    public let version: Int
    public let nTensors: Int
    public let nKv: Int
}

private func t61ValueSize(_ type: Int) -> Int {
    switch type {
    case 0, 1, 7: return 1
    case 2, 3: return 2
    case 4, 5, 6: return 4
    default: return -1
    }
}

public func ggufWalk(_ data: [UInt8]) throws -> GgufHeader {
    let n = data.count
    var at = 0
    func take(_ count: Int, _ what: String) throws -> [UInt8] {
        if n - at < count {
            throw ProvenanceError("gguf header truncated: wanteth " + t61Num(count) +
                " byte(s) for " + what + ", the container holdeth but " + t61Num(n - at))
        }
        var out: [UInt8] = []
        var i = 0
        while i < count { out.append(data[at + i]); i += 1 }
        at += count
        return out
    }
    func u32(_ what: String) throws -> Int {
        let b = try take(4, what)
        var v = 0
        var i = 0
        while i < 4 { v = v | (Int(b[i]) << (8 * i)); i += 1 }
        return v
    }
    func u64(_ what: String) throws -> Int {
        let b = try take(8, what)
        var v = 0
        var i = 0
        while i < 8 { v = v | (Int(b[i]) << (8 * i)); i += 1 }
        return v
    }
    func skipString(_ what: String) throws {
        let len = try u32(what + " length")
        if len < 0 || len > T61MaxChunk { throw ProvenanceError(what + " length out of bounds") }
        _ = try take(len, what)
    }
    if !(n >= 24 && data[0] == 71 && data[1] == 71 && data[2] == 85 && data[3] == 70) {
        throw ProvenanceError("not a GGUF container: magic mismatch")
    }
    _ = try take(4, "magic")
    let version = try u32("version")
    if version < 1 || version > 3 {
        throw ProvenanceError("unsupported GGUF version " + t61Num(version) +
            "; this walk understandeth 1..3")
    }
    let nTensors = try u64("n_tensors")
    let nKv = try u64("n_kv")
    if nTensors < 0 || nTensors > 65536 || nKv < 0 || nKv > 4096 {
        throw ProvenanceError("implausible header counts (n_tensors=" + t61Num(nTensors) +
            ", n_kv=" + t61Num(nKv) + ")")
    }
    var k = 0
    while k < nKv {
        try skipString("metadata key")
        let vtype = Int(try take(1, "metadata value type")[0])
        if vtype & 0xF8 == 0 {
            if t61ValueSize(vtype) < 0 { throw ProvenanceError("unknown GGUF metadata value type " + t61Num(vtype)) }
            _ = try take(t61ValueSize(vtype), "metadata value")
        } else if vtype == 8 {
            let elem = Int(try take(1, "array element type")[0])
            if t61ValueSize(elem) < 0 { throw ProvenanceError("unknown GGUF array element type " + t61Num(elem)) }
            let count = try u32("array count")
            if count < 0 || count * t61ValueSize(elem) > T61MaxArrayBytes {
                throw ProvenanceError("array byte count out of bounds")
            }
            _ = try take(count * t61ValueSize(elem), "array bytes")
        } else {
            throw ProvenanceError("unknown GGUF metadata value type " + t61Num(vtype))
        }
        k += 1
    }
    var seen = 0
    while seen < nTensors {
        try skipString("tensor name")
        let nDims = try u32("tensor n_dims")
        if nDims < 0 || nDims > 16 { throw ProvenanceError("implausible tensor rank " + t61Num(nDims)) }
        _ = try take(8 * nDims, "tensor dimensions")
        _ = try take(1, "tensor type")
        _ = try take(8, "tensor offset")
        seen += 1
    }
    if seen != nTensors {
        throw ProvenanceError("GGUF tensor count mismatch: header promised " + t61Num(nTensors) +
            ", the walk fond " + t61Num(seen))
    }
    return GgufHeader(version: version, nTensors: nTensors, nKv: nKv)
}

// ---------------------------------------------------------------------------
// The sworn artifacts and their several parts.
// ---------------------------------------------------------------------------

public struct EmbeddingFingerprint: Sendable, Equatable {
    public let pooling: String
    public let normalization: String
    public let dimension: Int

    public init(pooling: String, normalization: String, dimension: Int) throws {
        try t61Swear(T61Poolings.contains(where: { $0 == pooling })) {
            "unknown pooling '" + pooling + "': must be one of " + t61Quoted(T61Poolings)
        }
        try t61Swear(T61Normalizations.contains(where: { $0 == normalization })) {
            "unknown normalization '" + normalization + "': must be one of " + t61Quoted(T61Normalizations)
        }
        try t61Swear(dimension > 0) {
            "embedding dimension must be a positive integer, got " + t61Num(dimension)
        }
        self.pooling = pooling
        self.normalization = normalization
        self.dimension = dimension
    }
}

public struct ContentAddressedArtifact: Sendable {
    public let id: String
    public let kind: String
    public let tiers: [String]
    public let repo: String
    public let sourceCommit: String
    public let sourceFile: String
    public let outputFile: String
    public let sha256: String
    public let sizeBytes: Int
    public let licenseName: String
    public let tokenizer: String
    public let contextTokens: Int
    public let fingerprint: EmbeddingFingerprint?
    public let nativeAbi: String

    public init(id: String, kind: String, tiers: [String], repo: String,
                sourceCommit: String, sourceFile: String, outputFile: String,
                sha256: String, sizeBytes: Int, licenseName: String, tokenizer: String,
                contextTokens: Int, fingerprint: EmbeddingFingerprint?, nativeAbi: String) throws {
        try t61Swear(t61IsId(id)) { "artifact id must match [a-z0-9][a-z0-9_-]*: '" + id + "'" }
        try t61Swear(T61Kinds.contains(where: { $0 == kind })) {
            "'" + id + "': kind must be one of " + t61Quoted(T61Kinds) + ", got '" + kind + "'"
        }
        try t61Swear(!tiers.isEmpty && tiers.allSatisfy { tier in T61Tiers.contains(where: { $0 == tier }) }) {
            "'" + id + "': tiers must be drawn from " + t61Quoted(T61Tiers)
        }
        try t61Swear(t61IsRepo(repo)) { "'" + id + "': repo must be 'owner/name': '" + repo + "'" }
        try t61Swear(t61IsBasename(sourceFile)) {
            "'" + id + "'.source_file must be a plain .gguf basename: '" + sourceFile + "'"
        }
        try t61Swear(t61IsBasename(outputFile)) {
            "'" + id + "'.output_file must be a plain .gguf basename without separators or traversal: '" + outputFile + "'"
        }
        try t61Swear(t61IsHex(sourceCommit, 40)) {
            "'" + id + "'.source_commit must be a full 40-character lower-case hexadecimal revision, never a mutable branch head such as '" + sourceCommit + "'"
        }
        try t61Swear(t61IsHex(sha256, 64)) {
            "'" + id + "'.sha256 must be a full 64-character lower-case hexadecimal digest"
        }
        try t61Swear(sizeBytes > 0) { "'" + id + "'.size_bytes must be a positive integer" }
        try t61Swear(!licenseName.isEmpty) { "'" + id + "'.license must be a non-empty string" }
        try t61Swear(!tokenizer.isEmpty) { "'" + id + "'.tokenizer must be a non-empty string" }
        try t61Swear(contextTokens > 0) { "'" + id + "'.context_tokens must be a positive integer" }
        try t61Swear(T61Abis.contains(where: { $0 == nativeAbi })) {
            "'" + id + "': native_abi '" + nativeAbi + "' is not a compatible ABI of this repository (known: " + t61Quoted(T61Abis) + ")"
        }
        if kind == "embedding" {
            try t61Swear(fingerprint != nil) {
                "'" + id + "': an embedding model must swear its full fingerprint (pooling, normalization, dimension)"
            }
        } else {
            try t61Swear(fingerprint == nil) {
                "'" + id + "': a generation model hath no embedding fingerprint to swear"
            }
        }
        self.id = id
        self.kind = kind
        self.tiers = tiers
        self.repo = repo
        self.sourceCommit = sourceCommit
        self.sourceFile = sourceFile
        self.outputFile = outputFile
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
        self.licenseName = licenseName
        self.tokenizer = tokenizer
        self.contextTokens = contextTokens
        self.fingerprint = fingerprint
        self.nativeAbi = nativeAbi
    }

    /* The immutable coordinate: a pinned commit, never a branch head. */
    public func url() -> String {
        return "https://huggingface.co/" + repo + "/resolve/" + sourceCommit + "/" + sourceFile
    }
}

public struct T61Toolchain: Sendable, Equatable {
    public let name: String
    public let version: String
    public init(name: String, version: String) throws {
        try t61Swear(!name.isEmpty) { "toolchain name must be a non-empty string" }
        try t61Swear(t61IsToolVersion(version)) {
            "toolchain version must be dotted digits: '" + version + "'"
        }
        self.name = name
        self.version = version
    }
}

public struct NativeLockV1: Sendable {
    public let llamaRevision: String?
    public let sourceRepo: String
    public let buildFlags: [String]
    public let toolchains: [T61Toolchain]
    public let abis: [String]

    public init(llamaRevision: String?, sourceRepo: String, buildFlags: [String],
                toolchains: [T61Toolchain], abis: [String]) throws {
        if let rev = llamaRevision {
            try t61Swear(t61IsHex(rev, 40)) {
                "native.llama_revision must be null or a full 40-hex revision, never a mutable branch head: '" + rev + "'"
            }
        }
        try t61Swear(t61IsRepo(sourceRepo)) {
            "native.source_repo must be 'owner/name': '" + sourceRepo + "'"
        }
        try t61Swear(!buildFlags.isEmpty && buildFlags.allSatisfy { t61IsFlag($0) }) {
            "native.build_flags must be non-empty -D/-f/-W tokens without separators or traversal"
        }
        try t61Swear(!toolchains.isEmpty) { "native.toolchains must be a non-empty list" }
        try t61Swear(!abis.isEmpty && abis.allSatisfy { abi in T61Abis.contains(where: { $0 == abi }) }) {
            "native.abis must be drawn from " + t61Quoted(T61Abis)
        }
        self.llamaRevision = llamaRevision
        self.sourceRepo = sourceRepo
        self.buildFlags = buildFlags
        self.toolchains = toolchains
        self.abis = abis
    }
}

/* The bootstrap tale the authority telleth for the legacy estate. */
internal func t61BootstrapNative() -> NativeLockV1 {
    return try! NativeLockV1(llamaRevision: nil, sourceRepo: "ggml-org/llama.cpp",
        buildFlags: ["-O0"],
        toolchains: [T61Toolchain(name: "bootstrap", version: "0")],
        abis: ["arm64-v8a"])
}

// ---------------------------------------------------------------------------
// The content-addressed law: digest, length AND header -- never the name.
// ---------------------------------------------------------------------------

public func verifyContentAddressed(_ artifact: ContentAddressedArtifact,
                                    _ data: [UInt8]) -> [String] {
    var cries: [String] = []
    let digest = t61ShaHex(data)
    if digest != artifact.sha256 {
        cries.append(artifact.outputFile + ": content digest mismatch -- the lock sweareth " +
            artifact.sha256 + ", the bytes answer to " + digest +
            " (a file of the same name and length is NOT the sworn content)")
    }
    if data.count != artifact.sizeBytes {
        cries.append(artifact.outputFile + ": length mismatch -- the lock sweareth " +
            t61Num(artifact.sizeBytes) + " byte(s), the bytes count " + t61Num(data.count))
    }
    do {
        _ = try ggufWalk(data)
    } catch let mischief as ProvenanceError {
        cries.append(artifact.outputFile + ": " + mischief.message)
    } catch {
        cries.append(artifact.outputFile + ": header walk perished unexpectidly")
    }
    return cries
}

public final class T61CancellationToken: @unchecked Sendable {
    private let door = NSLock()
    private var struck = false

    public init() {}

    public var isCancelled: Bool {
        door.lock()
        defer { door.unlock() }
        return struck
    }

    @discardableResult
    public func cancel() -> Bool {
        door.lock()
        defer { door.unlock() }
        if struck { return false }
        struck = true
        return true
    }
}

/* The gate the streaming callback passeth through: once the token is struck,
 no more pieces be forwarded. It owneth no queue and disturbeth no handle. */
public final class T61StreamGate: @unchecked Sendable {
    private let token: T61CancellationToken?
    private let book = NSLock()
    private var forwarded: [String] = []

    public init(_ token: T61CancellationToken?) { self.token = token }

    public var forwardedCount: Int {
        book.lock()
        defer { book.unlock() }
        return forwarded.count
    }

    public func forward(_ piece: String) -> Bool {
        if let t = token, t.isCancelled { return false }
        book.lock()
        defer { book.unlock() }
        forwarded.append(piece)
        return true
    }
}

public final class ModelStaging: @unchecked Sendable {
    private let promotionLock = NSLock()

    public init() {}

    private func readBytes(_ url: URL) throws -> [UInt8] {
        return [UInt8](try Data(contentsOf: url))
    }

    private func writePart(_ bytes: [UInt8], to url: URL) throws {
        try Data(bytes).write(to: url)
    }

    /* Restore fully-sworn bytes into destinationDir under the content-addressed law. */
    @discardableResult
    public func restore(_ artifact: ContentAddressedArtifact, _ data: [UInt8],
                         into destinationDir: URL) throws -> URL {
        promotionLock.lock()
        defer { promotionLock.unlock() }
        let firstCries = verifyContentAddressed(artifact, data)
        if !firstCries.isEmpty {
            throw ProvenanceError(firstCries.joined(separator: "; "))
        }
        try FileManager.default.createDirectory(at: destinationDir,
            withIntermediateDirectories: true)
        let final = destinationDir.appendingPathComponent(artifact.outputFile)
        if FileManager.default.fileExists(atPath: final.path) {
            let standing = try readBytes(final)
            let cries = verifyContentAddressed(artifact, standing)
            if !cries.isEmpty {
                throw ProvenanceError(artifact.outputFile +
                    " standeth corrupt and refuseth the restore: " + cries.joined(separator: "; "))
            }
            return final
        }
        let part = URL(fileURLWithPath: final.path + ".part")
        try? FileManager.default.removeItem(at: part)
        do {
            try writePart(data, to: part)
        } catch {
            try? FileManager.default.removeItem(at: part)
            throw ProvenanceError("staging failed for " + artifact.outputFile)
        }
        let staged: [UInt8]
        do {
            staged = try readBytes(part)
        } catch {
            try? FileManager.default.removeItem(at: part)
            throw ProvenanceError("re-reading the staged bytes perished for " + artifact.outputFile)
        }
        let reread = verifyContentAddressed(artifact, staged)
        if !reread.isEmpty {
            try? FileManager.default.removeItem(at: part)
            throw ProvenanceError("staged bytes failed the final verification: " +
                reread.joined(separator: "; "))
        }
        do {
            try Data(staged).write(to: final, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: part)
            throw ProvenanceError("atomic promotion failed for " + artifact.outputFile)
        }
        try? FileManager.default.removeItem(at: part)
        return final
    }

    /* Stage the packaged asset at destination under the same law. The opener
     is a pull-chunker: it answereth the next want bytes, or nil at the end. */
    public typealias T61Chunker = (_ name: String, _ want: Int) throws -> [UInt8]?

    @discardableResult
    public func stage(_ opener: T61Chunker, to destination: URL,
                       verifiedBy artifact: ContentAddressedArtifact?) throws -> URL {
        promotionLock.lock()
        defer { promotionLock.unlock() }
        if FileManager.default.fileExists(atPath: destination.path) {
            if let artifact = artifact {
                let cries = verifyContentAddressed(artifact, try readBytes(destination))
                if !cries.isEmpty {
                    throw ProvenanceError(destination.lastPathComponent +
                        " standeth corrupt and refuseth the restore: " + cries.joined(separator: "; "))
                }
            }
            return destination
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let name = destination.lastPathComponent
        let part = URL(fileURLWithPath: destination.path + ".part")
        try? FileManager.default.removeItem(at: part)
        let ceiling = artifact?.sizeBytes ?? 1099511627776
        var bytes: [UInt8] = []
        do {
            while true {
                guard let chunk = try opener(name, T61MaxChunk) else { break }
                bytes += chunk
                if bytes.count > ceiling {
                    try? FileManager.default.removeItem(at: part)
                    throw ProvenanceError(name + ": stream exceeded the declared size " +
                        t61Num(ceiling) + " (the transfer is perishèd)")
                }
            }
        } catch let oath as ProvenanceError {
            try? FileManager.default.removeItem(at: part)
            throw oath
        } catch {
            try? FileManager.default.removeItem(at: part)
            throw ProvenanceError(name + ": the well runneth dry mid-transfer")
        }
        do {
            try writePart(bytes, to: part)
        } catch {
            try? FileManager.default.removeItem(at: part)
            throw ProvenanceError("staging failed for " + name)
        }
        do {
            let staged = try readBytes(part)
            if let artifact = artifact {
                let cries = verifyContentAddressed(artifact, staged)
                if !cries.isEmpty {
                    try? FileManager.default.removeItem(at: part)
                    throw ProvenanceError("staged bytes failed the final verification: " +
                        cries.joined(separator: "; "))
                }
            }
            try Data(bytes).write(to: destination, options: .atomic)
        } catch let oath as ProvenanceError {
            try? FileManager.default.removeItem(at: part)
            throw oath
        } catch {
            try? FileManager.default.removeItem(at: part)
            throw ProvenanceError("atomic promotion failed for " + name)
        }
        try? FileManager.default.removeItem(at: part)
        return destination
    }

    /* Verify a file that standeth where it lieth, in place, before trust. */
    public func verifyInPlace(atPath path: String, verifiedBy artifact: ContentAddressedArtifact) throws {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ProvenanceError(url.lastPathComponent + " is not to be found for verification")
        }
        let cries = verifyContentAddressed(artifact, try readBytes(url))
        if !cries.isEmpty { throw ProvenanceError(cries.joined(separator: "; ")) }
    }
}

public final class ModelLockV1: @unchecked Sendable {
    public let schema: Int
    public let status: String
    public let verifiedOn: String?
    public let verifiedBy: String?
    public let notes: String?
    public let nativeLock: NativeLockV1
    public let blobs: [[String: Any]]
    public let artifacts: [ContentAddressedArtifact]

    private init(schema: Int, status: String, verifiedOn: String?, verifiedBy: String?,
                 notes: String?, nativeLock: NativeLockV1, blobs: [[String: Any]],
                 artifacts: [ContentAddressedArtifact]) {
        self.schema = schema
        self.status = status
        self.verifiedOn = verifiedOn
        self.verifiedBy = verifiedBy
        self.notes = notes
        self.nativeLock = nativeLock
        self.blobs = blobs
        self.artifacts = artifacts
    }

    /* The strict estate's fourteen keys, every one demanded of every blob. */
    private static func t61ArtifactFrom(_ blob: [String: Any]) throws -> ContentAddressedArtifact {
        let id = try t61Str(blob, "id")
        for key in blob.keys {
            try t61Swear(T61ArtifactKeys.contains(key)) {
                "artifact '" + id + "': unknown field '" + key + "'"
            }
        }
        for key in T61ArtifactKeys {
            try t61Swear(blob[key] != nil) {
                "artifact '" + id + "': wanteth field '" + key + "'"
            }
        }
        let kind = try t61Str(blob, "kind")
        let tiers = try t61StrList(blob, "tiers", id)
        let repo = try t61Str(blob, "repo")
        let commit = try t61Str(blob, "source_commit")
        let sourceFile = try t61Str(blob, "source_file")
        let outputFile = try t61Str(blob, "output_file")
        let sha = try t61Str(blob, "sha256")
        let size = try t61Int(blob, "size_bytes", id)
        let license = try t61Str(blob, "license")
        let tokenizer = try t61Str(blob, "tokenizer")
        let context = try t61Int(blob, "context_tokens", id)
        let abi = try t61Str(blob, "native_abi")
        var fp: EmbeddingFingerprint? = nil
        let emb = blob["embedding"]
        if !(emb is T61Null), emb != nil {
            guard let e = emb as? [String: Any] else {
                throw ProvenanceError("'" + id + "': embedding fingerprint must be an object")
            }
            for key in e.keys {
                try t61Swear(T61EmbeddingKeys.contains(key)) {
                    "'" + id + "': unknown embedding fingerprint field '" + key + "'"
                }
            }
            for key in T61EmbeddingKeys {
                try t61Swear(e[key] != nil) {
                    "'" + id + "': embedding fingerprint wanteth field '" + key + "'"
                }
            }
            fp = try EmbeddingFingerprint(pooling: t61Str(e, "pooling"),
                normalization: t61Str(e, "normalization"),
                dimension: t61Int(e, "dimension", id))
        }
        return try ContentAddressedArtifact(id: id, kind: kind, tiers: tiers, repo: repo,
            sourceCommit: commit, sourceFile: sourceFile, outputFile: outputFile, sha256: sha,
            sizeBytes: size, licenseName: license, tokenizer: tokenizer, contextTokens: context,
            fingerprint: fp, nativeAbi: abi)
    }

    private static func t61Str(_ blob: [String: Any], _ key: String) throws -> String {
        guard let v = blob[key] as? String else {
            throw ProvenanceError("field '" + key + "' must be a string")
        }
        return v
    }

    private static func t61Int(_ blob: [String: Any], _ key: String, _ id: String) throws -> Int {
        guard let v = blob[key] as? Int else {
            throw ProvenanceError("'" + id + "': field '" + key + "' must be an integer")
        }
        return v
    }

    private static func t61StrList(_ blob: [String: Any], _ key: String, _ id: String) throws -> [String] {
        guard let v = blob[key] as? [String] else {
            throw ProvenanceError("'" + id + "': field '" + key + "' must be an array of strings")
        }
        return v
    }

    private static func t61NativeFrom(_ block: [String: Any]) throws -> NativeLockV1 {
        for key in block.keys {
            try t61Swear(T61NativeKeys.contains(key)) {
                "native block: unknown field '" + key + "'"
            }
        }
        for key in T61NativeKeys {
            try t61Swear(block[key] != nil) {
                "native block wanteth field '" + key + "'"
            }
        }
        let sourceRepo = try t61Str(block, "source_repo")
        guard let flags = block["build_flags"] as? [String] else {
            throw ProvenanceError("native block: build_flags must be an array of strings")
        }
        guard let abis = block["abis"] as? [String] else {
            throw ProvenanceError("native block: abis must be an array of strings")
        }
        guard let tools = block["toolchains"] as? [[String: Any]] else {
            throw ProvenanceError("native block: toolchains must be an array of objects")
        }
        var tcs: [T61Toolchain] = []
        for tc in tools {
            for k in tc.keys {
                try t61Swear(k == "name" || k == "version") {
                    "toolchain entry: unknown field '" + k + "'"
                }
            }
            tcs.append(try T61Toolchain(name: t61Str(tc, "name"), version: t61Str(tc, "version")))
        }
        let rev = block["llama_revision"]
        return try NativeLockV1(llamaRevision: (rev is T61Null) ? nil : (rev as? String),
            sourceRepo: sourceRepo, buildFlags: flags, toolchains: tcs, abis: abis)
    }

    /* Parse the strict register; every malformed or future face is refused. */
    public static func fromText(_ text: String) throws -> ModelLockV1 {
        guard let top = try t61ParseJson(text) as? [String: Any] else {
            throw ProvenanceError("model lock must be an object")
        }
        for key in top.keys {
            try t61Swear(T61TopKeys.contains(key)) {
                "model lock: unknown top-level field '" + key + "'"
            }
        }
        for key in ["schema", "status", "artifacts"] {
            try t61Swear(top[key] != nil) { "model lock wanteth field '" + key + "'" }
        }
        guard let schema = top["schema"] as? Int else {
            throw ProvenanceError("model lock schema must be an integer")
        }
        try t61Swear(schema == 1 || schema == 2) {
            "unsupported model-lock schema " + t61Num(schema) +
            "; this tool understandeth 1 (legacy, read-only) and 2 (strict)"
        }
        guard let status = top["status"] as? String else {
            throw ProvenanceError("model lock status must be a string")
        }
        try t61Swear(T61Statutes.contains(where: { $0 == status })) {
            "model lock status '" + status + "' is not one of " + t61Quoted(T61Statutes)
        }
        let verifiedOn = (top["verified_on"] as? String)
        let verifiedBy = (top["verified_by"] as? String)
        let notes = (top["notes"] as? String)
        let block = top["native"]
        var native: NativeLockV1
        if schema == 1 {
            // The legacy estate never saw the native block; an archived register
            // that writhe "native": {} verbatim is tolerated; a native tale under
            // the read-only estate is the very drift refused.
            if block != nil && !(block is T61Null) {
                let empty = (block as? [String: Any])?.isEmpty ?? false
                try t61Swear(empty) {
                    "schema 1 is the legacy estate; it knoweth no native block"
                }
            }
            native = t61BootstrapNative()
        } else {
            // The strict estate: the oath first, then the tale (the order the
            // Python authority observeth).
            if status == "PINNED" {
                try t61Swear((verifiedOn?.isEmpty == false)) {
                    "verified_on must be a non-empty string under the strict PINNED estate"
                }
                try t61Swear((verifiedBy?.isEmpty == false)) {
                    "verified_by must be a non-empty string under the strict PINNED estate"
                }
            } else {
                try t61Swear(verifiedOn == nil && verifiedBy == nil) {
                    "an UNPINNED lock must not name a verifier or a date: the oath belongeth to the PINNED estate only"
                }
            }
            guard let dict = block as? [String: Any] else {
                throw ProvenanceError("model lock wanteth field 'native'")
            }
            native = try t61NativeFrom(dict)
        }
        guard let list = top["artifacts"] as? [[String: Any]], !list.isEmpty else {
            throw ProvenanceError("model lock containeth no artifacts")
        }
        var seenIds: Set<String> = []
        var seenOutputs: Set<String> = []
        var sworn: [ContentAddressedArtifact] = []
        for blob in list {
            let idRepr = (blob["id"] as? String) ?? "?"
            if schema == 2 {
                for key in blob.keys {
                    try t61Swear(T61ArtifactKeys.contains(key)) {
                        "artifact '" + idRepr + "': unknown field '" + key + "'"
                    }
                }
                for key in T61ArtifactKeys {
                    try t61Swear(blob[key] != nil) {
                        "artifact '" + idRepr + "': wanteth field '" + key + "'"
                    }
                }
            } else {
                for key in blob.keys {
                    try t61Swear(T61LegacyKeys.contains(key)) {
                        "artifact '" + idRepr + "': legacy estate knoweth not field '" + key + "'"
                    }
                }
                for key in ["id", "tiers", "repo", "source_file", "output_file"] {
                    try t61Swear(blob[key] != nil) {
                        "artifact '" + idRepr + "': legacy estate wanteth field '" + key + "'"
                    }
                }
            }
            let label = (blob["id"] as? String) ?? ""
            try t61Swear(!seenIds.contains(label)) { "duplicate artifact id '" + label + "'" }
            _ = seenIds.insert(label)
            let output = (blob["output_file"] as? String) ?? "?"
            try t61Swear(!seenOutputs.contains(output)) {
                "duplicate output_file '" + output + "' (two ids, one destination is a collision)"
            }
            _ = seenOutputs.insert(output)
            if schema == 2 {
                if status == "PINNED" {
                    let art = try t61ArtifactFrom(blob)
                    try t61Swear(native.abis.contains(where: { $0 == art.nativeAbi })) {
                        art.id + ": native_abi '" + art.nativeAbi + "' is not compatible: the native lock listeth " + t61Quoted(native.abis)
                    }
                    sworn.append(art)
                } else {
                    // An UNPINNED register must be wholly unsworn: every provenance
                    // field standeth null, the coordinates alone being tellingly sane.
                    var swornAlready: [String] = []
                    for key in T61ProvenanceKeys {
                        if let v = blob[key], !(v is T61Null) { swornAlready.append(key) }
                    }
                    try t61Swear(swornAlready.isEmpty) {
                        label + ": the register is UNPINNED yet these provenance fields are sworn: " +
                        t61Quoted(swornAlready) + " -- verify them all or none"
                    }
                    try t61Swear(t61IsId(label)) {
                        "artifact id must match [a-z0-9][a-z0-9_-]*: '" + label + "'"
                    }
                    let kindv = (blob["kind"] as? String) ?? ""
                    try t61Swear(T61Kinds.contains(where: { $0 == kindv })) {
                        label + ": kind must be one of " + t61Quoted(T61Kinds) + ", got '" + kindv + "'"
                    }
                    let tiers = try t61StrList(blob, "tiers", label)
                    try t61Swear(!tiers.isEmpty && tiers.allSatisfy { tier in T61Tiers.contains(where: { $0 == tier }) }) {
                        label + ": tiers must be drawn from " + t61Quoted(T61Tiers)
                    }
                    let repo = (blob["repo"] as? String) ?? ""
                    try t61Swear(t61IsRepo(repo)) { label + ": repo must be 'owner/name': '" + repo + "'" }
                    let source = (blob["source_file"] as? String) ?? ""
                    try t61Swear(t61IsBasename(source)) {
                        label + ".source_file must be a plain .gguf basename: '" + source + "'"
                    }
                    try t61Swear(t61IsBasename(output)) {
                        label + ".output_file must be a plain .gguf basename: '" + output + "'"
                    }
                }
            } else {
                let sha = blob["sha256"]
                if status == "PINNED" {
                    try t61Swear((verifiedOn?.isEmpty == false) && (verifiedBy?.isEmpty == false)) {
                        "PINNED legacy lock lacketh verifier metadata"
                    }
                    try t61Swear(t61IsHex((sha as? String) ?? "", 64)) {
                        "artifact '" + label + "': PINNED legacy artifact lacketh a valid sha256"
                    }
                } else {
                    try t61Swear(sha == nil || sha is T61Null) {
                        "'" + label + "': UNPINNED legacy artifact must keep sha256 null"
                    }
                }
                try t61Swear(t61IsId(label)) {
                    "artifact id must match [a-z0-9][a-z0-9_-]*: '" + label + "'"
                }
                let tiers = try t61StrList(blob, "tiers", label)
                try t61Swear(!tiers.isEmpty && tiers.allSatisfy { tier in T61Tiers.contains(where: { $0 == tier }) }) {
                    "'" + label + "': tiers must be drawn from " + t61Quoted(T61Tiers)
                }
                let repo = (blob["repo"] as? String) ?? ""
                try t61Swear(t61IsRepo(repo)) { "'" + label + "': repo must be 'owner/name': '" + repo + "'" }
                let source = (blob["source_file"] as? String) ?? ""
                try t61Swear(t61IsPlainName(source)) {
                    "'" + label + "'.source_file must be a plain basename without separators or traversal: '" + source + "'"
                }
                try t61Swear(t61IsPlainName(output)) {
                    "'" + label + "'.output_file must be a plain basename without separators or traversal: '" + output + "'"
                }
            }
        }
        if status == "PINNED" && schema == 2 {
            // the oaths were sworne above, ere the native tale was read
        }
        return ModelLockV1(schema: schema, status: status, verifiedOn: verifiedOn,
            verifiedBy: verifiedBy, notes: notes, nativeLock: native, blobs: list,
            artifacts: sworn)
    }

    /* The sworn artifacts whose tiers name the asked tier (PINNED estate only). */
    public func selectForTier(_ tier: String) throws -> [ContentAddressedArtifact] {
        try t61Swear(schema == 2) {
            "schema 1 is the legacy proposed-coordinates estate: validate only; reforge the register to schema 2 before fetch or verify"
        }
        try t61Swear(status == "PINNED") {
            "the model lock is UNPINNED; independently verify every upstream artifact and its SHA-256 before use (status must read PINNED with verified_on/verified_by sworn)"
        }
        try t61Swear(tier == "ALL" || T61Tiers.contains(where: { $0 == tier })) {
            "tier must be ALL, LIGHT, MEDIUM or LARGE, got '" + tier + "'"
        }
        var chosen: [ContentAddressedArtifact] = []
        for a in artifacts {
            if tier == "ALL" || a.tiers.contains(where: { $0 == tier }) { chosen.append(a) }
        }
        try t61Swear(!chosen.isEmpty) { "no locked artifacts selected for tier '" + tier + "'" }
        return chosen
    }
}
