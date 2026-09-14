import XCTest
import Foundation
import GodstoneCore

/*
 T61 readiness court, iOS isle -- the twin of ReadinessT61Test.kt upon the
 Android isle and of the tested Python authority scripts/model_provenance.py.
 Every required case of the card is witnessed upon the production classes of
 GodstoneCore: the strict register's refusals (wrong or missing hash,
 mutable revision, licence absent, path traversal, duplicate identifiers,
 unsupported architecture), the content-addressed law (a truncated GGUF is
 refused though the name and the length agree; the file name and the length
 alone are NOT trusted), the bounded temporary with atomic promotion
 (repeated restore is determinist; an interruption preserveth the prior
 authoritative state), and the cancellation token standing independent of
 every worker queue. Cross-isle parity witnesses read the very bytes of the
 Python authority, of the two shell gates, of the build files, and of the
 shipped register itself, so the triad answereth with one voice.
*/

private let t61Commit40 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
private let t61ShaA = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

private func t61Q(_ s: String) -> String { return "\"" + s + "\"" }

private func t61Has(_ hay: String, _ needle: String) -> Bool {
    let h = Array(hay)
    let n = Array(needle)
    if n.isEmpty { return true }
    if h.count < n.count { return false }
    var i = 0
    while i + n.count <= h.count {
        var j = 0
        while j < n.count { if h[i + j] != n[j] { break }; j += 1 }
        if j == n.count { return true }
        i += 1
    }
    return false
}

private func t61Scratch(_ name: String) throws -> URL {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("t61-" + name + "-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
}

private func t61RepoRoot() throws -> URL {
    // ascend, not by number, but until the marker be found: the authority
    // scripts/model_provenance.py is the root's own witness, so the walk
    // endureth alike from the canonical and the mirrored dwelling
    var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    var hops = 0
    while hops < 12 {
        let mark = dir.appendingPathComponent("scripts").appendingPathComponent("model_provenance.py")
        if FileManager.default.fileExists(atPath: mark.path) { return dir }
        let parent = dir.deletingLastPathComponent()
        if parent.path == dir.path { break }
        dir = parent
        hops += 1
    }
    throw ProvenanceError("the repository root is not to be fond from the court's own file")
}

private func t61ReadRepo(_ relative: String) throws -> String {
    return try String(contentsOfFile: t61RepoRoot().path + "/" + relative, encoding: .utf8)
}

private func t61Refuses(_ label: String, _ needle: String? = nil,
                         _ thunk: () throws -> Any?) -> Bool {
    do { _ = try thunk() }
    catch let mischief as ProvenanceError {
        if let n = needle, !t61Has(mischief.message, n) { return false }
        return true
    }
    catch {
        return false
    }
    return false
}

private func t61Bytes(_ s: String) -> [UInt8] { return Array(s.utf8) }

private func t61ChopTail(_ s: String) -> String {
    let a = Array(s)
    var out = ""
    var i = 0
    while i < a.count - 1 { out.append(a[i]); i += 1 }
    return out
}

private func t61PutLe(_ out: inout [UInt8], _ v: Int, _ width: Int) {
    var i = 0
    while i < width { out.append(UInt8((v >> (8 * i)) & 0xFF)); i += 1 }
}

private func t61PutField(_ out: inout [UInt8], _ word: String) {
    let w = t61Bytes(word)
    t61PutLe(&out, w.count, 4)
    out += w
}

/* The synthetic vessel: a GGUF container the header walk must finish wholly. */
private func t61Gguf(_ version: Int, _ nTensors: Int, _ nKv: Int, _ tail: Bool) -> [UInt8] {
    var out: [UInt8] = []
    out += t61Bytes("GGUF")
    t61PutLe(&out, version, 4)
    t61PutLe(&out, nTensors, 8)
    t61PutLe(&out, nKv, 8)
    if nKv >= 1 {
        t61PutField(&out, "general.name")
        out.append(8)
        out.append(4)
        t61PutLe(&out, 2, 4)
        t61PutLe(&out, 7, 4)
        t61PutLe(&out, 11, 4)
    }
    if nKv >= 2 {
        t61PutField(&out, "tokenizer.ggml.add_bos")
        out.append(7)
        out.append(1)
    }
    var t = 0
    while t < nTensors {
        t61PutField(&out, "blk." + "\(t)" + ".weight")
        t61PutLe(&out, 2, 4)
        t61PutLe(&out, 64, 8)
        t61PutLe(&out, 32, 8)
        out.append(10)
        t61PutLe(&out, 4096 * t, 8)
        t += 1
    }
    if tail { out.append(0); out.append(0) }
    return out
}

private func t61Artifact(_ sha: String, _ size: Int, _ abi: String) -> ContentAddressedArtifact {
    return try! ContentAddressedArtifact(id: "generation-court", kind: "generation",
        tiers: ["LIGHT", "MEDIUM", "LARGE"], repo: "court-synthesists/fake-models",
        sourceCommit: t61Commit40, sourceFile: "Court.gguf", outputFile: "court.gguf",
        sha256: sha, sizeBytes: size, licenseName: "apache-2.0", tokenizer: "gpt2",
        contextTokens: 2048, fingerprint: nil, nativeAbi: abi)
}

private func t61Embedding(_ pooling: String, _ normalization: String, _ dimension: Int)
    -> EmbeddingFingerprint {
    return try! EmbeddingFingerprint(pooling: pooling, normalization: normalization,
        dimension: dimension)
}

private func t61ArtifactJson(_ idF: String, _ kindF: String, _ tiersF: String, _ repoF: String,
    _ commitF: String, _ sourceF: String, _ outputF: String, _ shaF: String, _ sizeF: String,
    _ licenceF: String, _ tokenizerF: String, _ contextF: String, _ embeddingF: String,
    _ abiF: String) -> String {
    return "{" +
        "\"id\": " + idF + ", " +
        "\"kind\": " + kindF + ", " +
        "\"tiers\": " + tiersF + ", " +
        "\"repo\": " + repoF + ", " +
        "\"source_commit\": " + commitF + ", " +
        "\"source_file\": " + sourceF + ", " +
        "\"output_file\": " + outputF + ", " +
        "\"sha256\": " + shaF + ", " +
        "\"size_bytes\": " + sizeF + ", " +
        "\"license\": " + licenceF + ", " +
        "\"tokenizer\": " + tokenizerF + ", " +
        "\"context_tokens\": " + contextF + ", " +
        "\"embedding\": " + embeddingF + ", " +
        "\"native_abi\": " + abiF +
    "}"
}

private func t61GoodArtifactJson() -> String {
    return t61ArtifactJson(t61Q("generation-court"), t61Q("generation"),
        "[\"LIGHT\", \"MEDIUM\", \"LARGE\"]", t61Q("court-synthesists/fake-models"),
        t61Q(t61Commit40), t61Q("Court.gguf"), t61Q("court.gguf"), t61Q(t61ShaA), "7",
        t61Q("apache-2.0"), t61Q("gpt2"), "2048", "null", t61Q("arm64-v8a"))
}

private func t61NativeTale() -> String {
    return "{ \"llama_revision\": null, " +
        "\"source_repo\": \"ggml-org/llama.cpp\", " +
        "\"build_flags\": [\"-O3\", \"-ffast-math\", \"-funroll-loops\", " +
        "\"-fno-exceptions\", \"-fno-rtti\"], " +
        "\"toolchains\": [{\"name\": \"ndk\", \"version\": \"27.0.12077973\"}, " +
        "{\"name\": \"cmake\", \"version\": \"3.22.1\"}], " +
        "\"abis\": [\"arm64-v8a\"] }"
}

private func t61LockJson(_ schemaF: String, _ statusF: String, _ verifiedOnF: String,
    _ verifiedByF: String, _ nativeF: String, _ bodies: String, _ extraTop: String) -> String {
    return "{" +
        "\"schema\": " + schemaF + ", " +
        "\"status\": " + statusF + ", " +
        "\"verified_on\": " + verifiedOnF + ", " +
        "\"verified_by\": " + verifiedByF + ", " +
        "\"notes\": null, " +
        "\"native\": " + nativeF + ", " +
        "\"artifacts\": [" + bodies + "]" + extraTop +
    "}"
}

private func t61GoodLockJson() -> String {
    return t61LockJson("2", t61Q("PINNED"), t61Q("2026-09-13"), t61Q("the court's own eye"),
        t61NativeTale(), t61GoodArtifactJson(), "")
}

private func t61AnyCry(_ cries: [String], _ needle: String) -> Bool {
    var i = 0
    while i < cries.count { if t61Has(cries[i], needle) { return true }; i += 1 }
    return false
}

private func t61Chunked(_ bytes: [UInt8], _ measure: Int, _ burst: Int) -> ModelStaging.T61Chunker {
    var given = bytes
    var at = 0
    var words = 0
    return { _, _ in
        if burst >= 0 && words >= burst {
            throw ProvenanceError("the well runneth dry mid-transfer")
        }
        if at >= given.count { return nil }
        let hi = min(at + measure, given.count)
        let chunk = Array(given[at..<hi])
        at = hi
        words += 1
        return chunk
    }
}

private func t61WriteFoul(_ url: URL, _ bytes: [UInt8]) throws {
    try Data(bytes).write(to: url)
}

final class ReadinessT61Tests: XCTestCase {

    // W01 -- the named falsification: trust in the file name alone is death.
    func testW01WrongDigestIsRefusedAndNothingStandethPromoted() throws {
        let good = t61Gguf(3, 2, 2, false)
        var foul = good
        foul[foul.count - 1] = UInt8((Int(foul[foul.count - 1]) + 7) & 0xFF)
        let art = t61Artifact(t61ShaHex(good), good.count, "arm64-v8a")
        let dir = try t61Scratch("w01")
        XCTAssertTrue(t61Refuses("wrong digest") { try ModelStaging().restore(art, foul, into: dir) },
            "W01 the tampered bytes were accepted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(art.outputFile).path),
            "W01 a refused artifact stoodeth promoted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(art.outputFile + ".part").path),
            "W01 a temporary outlived the refusal")
    }

    // W02 -- a register that will not swear the hash is refused at the door.
    func testW02MissingHashFieldIsRefusedAtTheRegisterDoor() throws {
        let body = t61ArtifactJson(t61Q("generation-court"), t61Q("generation"),
            "[\"LIGHT\"]", t61Q("court-synthesists/fake-models"), t61Q(t61Commit40),
            t61Q("Court.gguf"), t61Q("court.gguf"), "null", "7", t61Q("apache-2.0"),
            t61Q("gpt2"), "2048", "null", t61Q("arm64-v8a"))
        XCTAssertTrue(t61Refuses("missing hash", "sha256") {
            try self.t61LockPin(body)
        }, "W02 an unsworn digest was accepted")
    }

    func testW22MalformedDigestLengthIsRefusedAtTheRegisterDoor() throws {
        let body = t61ArtifactJson(t61Q("generation-court"), t61Q("generation"),
            "[\"LIGHT\"]", t61Q("court-synthesists/fake-models"), t61Q(t61Commit40),
            t61Q("Court.gguf"), t61Q("court.gguf"), t61Q(t61ShaA + "0"), "7", t61Q("apache-2.0"),
            t61Q("gpt2"), "2048", "null", t61Q("arm64-v8a"))
        XCTAssertTrue(t61Refuses("malformed digest length", "64-character") {
            try self.t61LockPin(body)
        }, "W02 an unsworn digest was accepted")
    }

    private func t61LockPin(_ body: String) throws -> ModelLockV1 {
        return try ModelLockV1.fromText(t61LockJson("2", t61Q("PINNED"),
            t61Q("2026-09-13"), t61Q("the court's own eye"), t61NativeTale(), body, ""))
    }

    // W03 -- a mutable branch head where an immutable revision should stand.
    func testW03MutableBranchHeadCoordinateIsRefused() throws {
        let body = t61ArtifactJson(t61Q("generation-court"), t61Q("generation"),
            "[\"LIGHT\"]", t61Q("court-synthesists/fake-models"), t61Q("main"),
            t61Q("Court.gguf"), t61Q("court.gguf"), t61Q(t61ShaA), "7", t61Q("apache-2.0"),
            t61Q("gpt2"), "2048", "null", t61Q("arm64-v8a"))
        XCTAssertTrue(t61Refuses("branch head", "source_commit") { try self.t61LockPin(body) },
            "W03 a branch head was admitted as a coordinate")
        let art = t61Artifact(t61ShaHex(t61Gguf(3, 2, 2, false)), 214, "arm64-v8a")
        XCTAssertTrue(t61Has(art.url(), "/resolve/" + t61Commit40 + "/"),
            "W03 the immutable url drifteth: " + art.url())
        XCTAssertFalse(t61Has(art.url(), "/main/"), "W03 the url carrieth a branch head")
    }

    // W04 -- the licence oath is no decoration.
    func testW04AbsentLicenceOathIsRefused() throws {
        let body = t61ArtifactJson(t61Q("generation-court"), t61Q("generation"),
            "[\"LIGHT\"]", t61Q("court-synthesists/fake-models"), t61Q(t61Commit40),
            t61Q("Court.gguf"), t61Q("court.gguf"), t61Q(t61ShaA), "7", "null",
            t61Q("gpt2"), "2048", "null", t61Q("arm64-v8a"))
        XCTAssertTrue(t61Refuses("no licence", "license") { try self.t61LockPin(body) },
            "W04 an unlicensed artifact was sworn")
    }

    // W05 -- path traversal at either door.
    func testW05PathTraversalIsRefusedAtBothDoors() throws {
        let outTrivial = t61ArtifactJson(t61Q("generation-court"), t61Q("generation"),
            "[\"LIGHT\"]", t61Q("court-synthesists/fake-models"), t61Q(t61Commit40),
            t61Q("Court.gguf"), t61Q("../evil.gguf"), t61Q(t61ShaA), "7", t61Q("apache-2.0"),
            t61Q("gpt2"), "2048", "null", t61Q("arm64-v8a"))
        XCTAssertTrue(t61Refuses("traversal out", "output_file") { try self.t61LockPin(outTrivial) },
            "W05 a traversal output_file walked in")
        let sourceDoor = t61ArtifactJson(t61Q("generation-court"), t61Q("generation"),
            "[\"LIGHT\"]", t61Q("court-synthesists/fake-models"), t61Q(t61Commit40),
            t61Q("../../etc/passwd.gguf"), t61Q("court.gguf"), t61Q(t61ShaA), "7",
            t61Q("apache-2.0"), t61Q("gpt2"), "2048", "null", t61Q("arm64-v8a"))
        XCTAssertTrue(t61Refuses("traversal source", "source_file") { try self.t61LockPin(sourceDoor) },
            "W05 a traversal source_file walked in")
    }

    // W06 -- a truncated container is refused though name and length agree.
    func testW06TruncatedGgufIsRefusedThoughNameAndLengthAgree() throws {
        let good = t61Gguf(3, 2, 2, false)
        let trunc = Array(good[0..<(good.count - 20)])
        let art = t61Artifact(t61ShaHex(trunc), trunc.count, "arm64-v8a")
        XCTAssertTrue(t61Refuses("truncated walk", "truncated") { try ggufWalk(trunc) },
            "W06 the walk enduréd a truncated container")
        let cries = verifyContentAddressed(art, trunc)
        XCTAssertTrue(cries.count > 0 && t61AnyCry(cries, "truncated"),
            "W06 the header cry was silent: " + cries.joined(separator: " | "))
        let dir = try t61Scratch("w06")
        XCTAssertTrue(t61Refuses("truncated restore") { try ModelStaging().restore(art, trunc, into: dir) },
            "W06 a truncated artifact was promoted")
    }

    // W07 -- no two identifiers, no two destinations.
    func testW07DuplicateIdentifiersAreRefused() throws {
        let body = t61GoodArtifactJson()
        XCTAssertTrue(t61Refuses("twin ids", "duplicate") {
            try self.t61LockPin(body + ", " + body)
        }, "W07 two artifacts bore one id")
        let twin = t61ArtifactJson(t61Q("generation-court-twin"), t61Q("generation"),
            "[\"LIGHT\"]", t61Q("court-synthesists/fake-models"), t61Q(t61Commit40),
            t61Q("Court.gguf"), t61Q("court.gguf"), t61Q(t61ShaA), "7", t61Q("apache-2.0"),
            t61Q("gpt2"), "2048", "null", t61Q("arm64-v8a"))
        XCTAssertTrue(t61Refuses("twin outputs", "duplicate") {
            try self.t61LockPin(body + ", " + twin)
        }, "W07 two artifacts claimed one destination")
    }

    // W08 -- the architecture must be one this house speaketh.
    func testW08UnsupportedArchitectureIsRefused() throws {
        let offList = t61ArtifactJson(t61Q("generation-court"), t61Q("generation"),
            "[\"LIGHT\"]", t61Q("court-synthesists/fake-models"), t61Q(t61Commit40),
            t61Q("Court.gguf"), t61Q("court.gguf"), t61Q(t61ShaA), "7", t61Q("apache-2.0"),
            t61Q("gpt2"), "2048", "null", t61Q("riscv-9"))
        XCTAssertTrue(t61Refuses("strange abi", "native_abi") { try self.t61LockPin(offList) },
            "W08 an unknown ABI was admitted")
        let unlisted = t61ArtifactJson(t61Q("generation-court"), t61Q("generation"),
            "[\"LIGHT\"]", t61Q("court-synthesists/fake-models"), t61Q(t61Commit40),
            t61Q("Court.gguf"), t61Q("court.gguf"), t61Q(t61ShaA), "7", t61Q("apache-2.0"),
            t61Q("gpt2"), "2048", "null", t61Q("x86-64"))
        XCTAssertTrue(t61Refuses("abi off the native tale", "not compatible") {
            try self.t61LockPin(unlisted)
        }, "W08 the native tale listeth no such ABI")
    }

    // W09 -- the second restore is the first remembered.
    func testW09RepeatedRestoreIsDeterministAndLeavethNoTemporary() throws {
        let good = t61Gguf(3, 2, 2, false)
        let art = t61Artifact(t61ShaHex(good), good.count, "arm64-v8a")
        let dir = try t61Scratch("w09")
        let first = try ModelStaging().restore(art, good, into: dir)
        let second = try ModelStaging().restore(art, good, into: dir)
        XCTAssertEqual(first.path, second.path, "W09 the two restores disagree")
        XCTAssertEqual(t61ShaHex(good), t61ShaHex(try Data(contentsOf: first).map { $0 }),
            "W09 the standing bytes answer to a different digest")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(art.outputFile + ".part").path),
            "W09 a temporary outlived the promotion")
    }

    // W10 -- one cry, the digest; name and length are trusted and found lying.
    func testW10FileNameAndLengthAloneAreNotTrusted() throws {
        let good = t61Gguf(3, 2, 2, false)
        var foul = good
        foul[34] = UInt8((Int(foul[34]) + 9) & 0xFF)
        XCTAssertEqual(good.count, foul.count, "W10 the fixture must preserve the length")
        let art = t61Artifact(t61ShaHex(good), good.count, "arm64-v8a")
        let cries = verifyContentAddressed(art, foul)
        XCTAssertEqual(cries.count, 1, "W10 expected exactly the digest to cry: " + cries.joined(separator: " | "))
        XCTAssertTrue(t61AnyCry(cries, "digest"), "W10 the cry came not from the digest")
        let dir = try t61Scratch("w10")
        XCTAssertTrue(t61Refuses("same name, same length, wrong content") {
            try ModelStaging().restore(art, foul, into: dir)
        }, "W10 a lookalike vessel was promoted")
    }

    // W11 -- the standing corrupt file is preserved, not overwritten.
    func testW11CorruptStandingFileIsNotOverwrittenByTheSwornGate() throws {
        let good = t61Gguf(3, 2, 2, false)
        var foul = good
        foul[foul.count - 1] = UInt8((Int(foul[foul.count - 1]) + 7) & 0xFF)
        let art = t61Artifact(t61ShaHex(good), good.count, "arm64-v8a")
        let dir = try t61Scratch("w11")
        let standing = dir.appendingPathComponent(art.outputFile)
        try t61WriteFoul(standing, foul)
        XCTAssertTrue(t61Refuses("corrupt standing") { try ModelStaging().restore(art, good, into: dir) },
            "W11 the gate opened upon a corrupt standing file")
        let stillThere = try Data(contentsOf: standing).map { $0 }
        XCTAssertEqual(t61ShaHex(foul), t61ShaHex(stillThere),
            "W11 the prior authoritative state was disturbed")
        XCTAssertTrue(t61Refuses("in-place verification of the corrupt file") {
            try ModelStaging().verifyInPlace(atPath: standing.path, verifiedBy: art)
        }, "W11 verifyInPlace trusted the corrupt file")
    }

    // W12 -- interruption mid-transfer preserveth the prior state wholly.
    func testW12InterruptionMidStagingLeavethNoAuthoritativeTrace() throws {
        let good = t61Gguf(3, 2, 2, false)
        let art = t61Artifact(t61ShaHex(good), good.count, "arm64-v8a")
        let dir = try t61Scratch("w12")
        let doomed = dir.appendingPathComponent(art.outputFile)
        XCTAssertTrue(t61Refuses("burst after one chunk") {
            try ModelStaging().stage(t61Chunked(good, 24, 1), to: doomed, verifiedBy: art)
        }, "W12 a broken transfer was suffered to stand")
        XCTAssertFalse(FileManager.default.fileExists(atPath: doomed.path),
            "W12 the destination stood though the transfer burst")
        XCTAssertFalse(FileManager.default.fileExists(atPath: doomed.path + ".part"),
            "W12 a temporary outlived the burst")
        let gentle = try ModelStaging().stage(t61Chunked(good, 24, -1), to: doomed, verifiedBy: art)
        XCTAssertTrue(FileManager.default.fileExists(atPath: gentle.path),
            "W12 the lawful transfer left no artifact")
        XCTAssertEqual(t61ShaHex(good), t61ShaHex(try Data(contentsOf: gentle).map { $0 }),
            "W12 the promoted bytes answer to a different digest")
    }

    // W13 -- the embedding fingerprint must be sworn in full or not at all.
    func testW13EmbeddingFingerprintLawsAreEnforced() throws {
        XCTAssertTrue(t61Refuses("strange pooling", "pooling") {
            try EmbeddingFingerprint(pooling: "meanq", normalization: "l2", dimension: 384)
        }, "W13 an unknown pooling was sworn")
        XCTAssertTrue(t61Refuses("strange normalization", "normalization") {
            try EmbeddingFingerprint(pooling: "mean", normalization: "l1", dimension: 384)
        }, "W13 an unknown normalization was sworn")
        XCTAssertTrue(t61Refuses("zero dimension", "dimension") {
            try EmbeddingFingerprint(pooling: "mean", normalization: "l2", dimension: 0)
        }, "W13 a zero dimension was sworn")
        let sworn = t61Embedding("mean", "l2", 384)
        XCTAssertEqual(sworn.dimension, 384, "W13 the dimension drifteth")
        let good = t61Gguf(3, 2, 2, false)
        let sha = t61ShaHex(good)
        XCTAssertTrue(t61Refuses("generation with fingerprint", "fingerprint") {
            try ContentAddressedArtifact(id: "generation-court", kind: "generation",
                tiers: ["LIGHT"], repo: "court-synthesists/fake-models", sourceCommit: t61Commit40,
                sourceFile: "Court.gguf", outputFile: "court.gguf", sha256: sha, sizeBytes: good.count,
                licenseName: "apache-2.0", tokenizer: "gpt2", contextTokens: 2048,
                fingerprint: sworn, nativeAbi: "arm64-v8a")
        }, "W13 a generation model swore an embedding fingerprint")
        XCTAssertTrue(t61Refuses("embedding without fingerprint", "fingerprint") {
            try ContentAddressedArtifact(id: "embedding-court", kind: "embedding",
                tiers: ["LIGHT"], repo: "court-synthesists/fake-models", sourceCommit: t61Commit40,
                sourceFile: "Court.gguf", outputFile: "court.gguf", sha256: sha, sizeBytes: good.count,
                licenseName: "apache-2.0", tokenizer: "gpt2", contextTokens: 2048,
                fingerprint: nil, nativeAbi: "arm64-v8a")
        }, "W13 an embedding model kept its fingerprint unsworn")
    }

    // W14 -- the token is independent of every worker queue.
    func testW14TheTokenCeasethForwardingAndTheGateKeepethRecord() throws {
        let token = T61CancellationToken()
        let gate = T61StreamGate(token)
        XCTAssertTrue(gate.forward("the "), "W14 the gate refused a willing piece")
        XCTAssertTrue(gate.forward("quick "), "W14 the gate refused a willing piece")
        XCTAssertEqual(gate.forwardedCount, 2, "W14 the record is false")
        XCTAssertTrue(token.cancel(), "W14 the first strike should have struck")
        XCTAssertFalse(token.cancel(), "W14 the second strike struck again")
        XCTAssertFalse(gate.forward("brown "), "W14 the gate forwarded after the strike")
        XCTAssertEqual(gate.forwardedCount, 2, "W14 the record grew after the strike")
        let other = T61StreamGate(token)
        XCTAssertFalse(other.forward("fox"), "W14 a fresh gate forgot the standing strike")
        let free = T61StreamGate(T61CancellationToken())
        XCTAssertTrue(free.forward("jumps"), "W14 an unstruck token held the gate shut")
        XCTAssertEqual(free.forwardedCount, 1, "W14 the free record is false")
    }

    // W15 -- the native tale is told from the build files, not from fancy.
    func testW15TheNativeTaleIsToldFromTheBuildFiles() throws {
        let lock = try ModelLockV1.fromText(t61GoodLockJson())
        XCTAssertEqual(lock.schema, 2, "W15 the strict estate must read schema 2")
        XCTAssertEqual(lock.status, "PINNED", "W15 the good lock must read PINNED")
        let tale = lock.nativeLock
        XCTAssertTrue(tale.llamaRevision == nil, "W15 the revision must stand unsworn")
        XCTAssertEqual(tale.sourceRepo, "ggml-org/llama.cpp", "W15 the source repo drifteth")
        XCTAssertEqual(tale.abis, ["arm64-v8a"], "W15 the ABI list drifteth")
        XCTAssertEqual(tale.buildFlags.count, 5, "W15 the flag tale lost a flag")
        XCTAssertTrue(tale.buildFlags.contains(where: { $0 == "-O3" }), "W15 -O3 is missing")
        XCTAssertTrue(tale.buildFlags.contains(where: { $0 == "-fno-exceptions" }), "W15 -fno-exceptions is missing")
        XCTAssertTrue(tale.buildFlags.contains(where: { $0 == "-fno-rtti" }), "W15 -fno-rtti is missing")
        XCTAssertTrue(tale.buildFlags.contains(where: { $0 == "-ffast-math" }), "W15 -ffast-math is missing")
        XCTAssertTrue(tale.buildFlags.contains(where: { $0 == "-funroll-loops" }), "W15 -funroll-loops is missing")
        XCTAssertEqual(tale.toolchains.count, 2, "W15 two toolchains must be told")
        XCTAssertEqual(tale.toolchains[0].name, "ndk", "W15 the first toolchain is not ndk")
        XCTAssertEqual(tale.toolchains[0].version, "27.0.12077973", "W15 the ndk version drifteth")
        XCTAssertEqual(tale.toolchains[1].name, "cmake", "W15 the second toolchain is not cmake")
        XCTAssertEqual(tale.toolchains[1].version, "3.22.1", "W15 the cmake version drifteth")
        let gradle = try t61ReadRepo("android/llm/build.gradle.kts")
        XCTAssertTrue(t61Has(gradle, "27.0.12077973"), "W15 the ndk numerals are not in build.gradle.kts")
        XCTAssertTrue(t61Has(gradle, "3.22.1"), "W15 the cmake numerals are not in build.gradle.kts")
        XCTAssertTrue(t61Has(gradle, "arm64-v8a"), "W15 the ABI is not in build.gradle.kts")
        XCTAssertTrue(t61Has(gradle, "fno-exceptions"), "W15 -fno-exceptions is not in build.gradle.kts")
        XCTAssertTrue(t61Has(gradle, "fno-rtti"), "W15 -fno-rtti is not in build.gradle.kts")
        let cmake = try t61ReadRepo("android/llm/src/main/cpp/CMakeLists.txt")
        XCTAssertTrue(t61Has(cmake, "ffast-math"), "W15 -ffast-math is not in CMakeLists.txt")
        XCTAssertTrue(t61Has(cmake, "funroll-loops"), "W15 -funroll-loops is not in CMakeLists.txt")
        XCTAssertTrue(t61Has(cmake, "O3"), "W15 -O3 is not in CMakeLists.txt")
    }

    // W16 -- the bridge keepeth one worker; the gate speaketh at the seam.
    func testW16TheBridgeKeepethOneWorkerAndTheGateWordethAtTheSeam() throws {
        let bridge = try t61ReadRepo("android/llm/src/main/java/io/godstone/llm/LlamaBridge.kt")
        XCTAssertTrue(t61Has(bridge, "var handle: Long = 0"), "W16 one worker handle vanished")
        XCTAssertTrue(t61Has(bridge, "if (isLoaded) return true"), "W16 the loaded guard vanished")
        XCTAssertTrue(t61Has(bridge, "val gate = StreamGate(token)"), "W16 the gate is not at the seam")
        XCTAssertTrue(t61Has(bridge, "if (gate.forward(piece)) trySend(piece)"),
            "W16 the gate does not ward the forwarding")
        let runner = try t61ReadRepo("ios/Godstone/Sources/GodstoneLLM/LlamaRunner.swift")
        XCTAssertTrue(t61Has(runner, "verifiedBy artifact"), "W16 the load seam lost its sworn gate")
        XCTAssertTrue(t61Has(runner, "if !gate.forward(piece) { return false }"),
            "W16 the iOS seam lost its gate")
    }

    // W17 -- the Python authority keepeth its face clean.
    func testW17ThePythonAuthorityKeepethItsFaceClean() throws {
        let py = try t61ReadRepo("scripts/model_provenance.py")
        XCTAssertTrue(t61Has(py, "def gguf_verify"), "W17 the walker is gone from the authority")
        XCTAssertTrue(t61Has(py, "def restore"), "W17 restore is gone from the authority")
        XCTAssertTrue(t61Has(py, "os.replace"), "W17 the atomic promotion is gone")
        XCTAssertTrue(t61Has(py, "/resolve/"), "W17 the immutable url form is gone")
        XCTAssertTrue(t61Has(py, "UNPINNED"), "W17 the UNPINNED estate is gone")
        XCTAssertTrue(t61Has(py, "_load_strict"), "W17 the strict reader is gone")
        XCTAssertTrue(t61Has(py, "object_pairs_hook"), "W17 the duplicate-key watch is gone")
        XCTAssertFalse(t61Has(py, "mapfile"), "W17 mapfile crept back into the authority")
        let sh = try t61ReadRepo("scripts/fetch_models.sh")
        XCTAssertFalse(t61Has(sh, "mapfile"), "W17 mapfile crept back into the fetch gate")
        XCTAssertFalse(t61Has(sh, "MODELS=("), "W17 a bash-4 array crept into the fetch gate")
        XCTAssertTrue(t61Has(sh, "model_provenance.py"), "W17 the fetch gate lost the authority")
        XCTAssertTrue(t61Has(sh, "lock.get(\"status\")"), "W17 the K-gate literal drifteth")
        XCTAssertTrue(t61Has(sh, "!= \"PINNED\""), "W17 the K-gate comparison drifteth")
        let q = try t61ReadRepo("scripts/quantise.sh")
        XCTAssertTrue(t61Has(q, "model_provenance.py"), "W17 the quantise gate lost the authority")
    }

    // W18 -- the shipped register is UNPINNED and wholly unsworn.
    func testW18TheShippedRegisterIsUnpinnedAndWhollyUnsworn() throws {
        let text = try t61ReadRepo("docs/packaging/MODELS.lock.json")
        let lock = try ModelLockV1.fromText(text)
        XCTAssertEqual(lock.schema, 2, "W18 the shipped register must be schema 2")
        XCTAssertEqual(lock.status, "UNPINNED", "W18 the shipped register is not UNPINNED")
        XCTAssertEqual(lock.blobs.count, 5, "W18 the shipped register lost a blob")
        XCTAssertTrue(lock.artifacts.isEmpty, "W18 an UNPINNED register nameth sworn artifacts")
        var i = 0
        while i < lock.blobs.count {
            let b = lock.blobs[i]
            for key in ["source_commit", "sha256", "size_bytes", "license",
                        "tokenizer", "context_tokens", "embedding", "native_abi"] {
                XCTAssertTrue(b[key] == nil || b[key] is T61Null,
                    "W18 blob " + "\(i)" + " carrieth a sworn " + key)
            }
            i += 1
        }
        var ids: [String] = []
        var j = 0
        while j < lock.blobs.count {
            ids.append((lock.blobs[j]["id"] as? String) ?? "?")
            j += 1
        }
        XCTAssertEqual(ids, ["generation-light", "generation-medium", "generation-large",
            "embedding-small", "embedding-base"], "W18 the register's ids drift")
        XCTAssertTrue(lock.nativeLock.llamaRevision == nil, "W18 the native revision is sworn")
        XCTAssertEqual(lock.nativeLock.abis, ["arm64-v8a"], "W18 the shipped ABI tale drifteth")
        XCTAssertEqual(lock.nativeLock.toolchains.map { $0.name }, ["ndk", "cmake"],
            "W18 the shipped toolchain tale drifteth")
        XCTAssertTrue(t61Refuses("the UNPINNED estate may not fetch") {
            try lock.selectForTier("ALL")
        }, "W18 an UNPINNED register answered a selection")
    }

    // W19 -- unknown fields and future schemas are refused, not waved through.
    func testW19UnknownFieldsAndFutureSchemasAreRefused() throws {
        XCTAssertTrue(t61Refuses("future schema", "unsupported model-lock schema") {
            try ModelLockV1.fromText(t61LockJson("3", t61Q("PINNED"), t61Q("2026-09-13"),
                t61Q("the court's own eye"), t61NativeTale(), self.t61GoodBody(), ""))
        }, "W19 a future schema was admitted")
        XCTAssertTrue(t61Refuses("unknown top field", "unknown top-level field") {
            try ModelLockV1.fromText(t61LockJson("2", t61Q("PINNED"), t61Q("2026-09-13"),
                t61Q("the court's own eye"), t61NativeTale(), self.t61GoodBody(),
                ", \"future_field\": true"))
        }, "W19 an unknown top-level field was admitted")
        let surcharged = t61ChopTail(t61GoodArtifactJson()) + ", \"surcharge\": true}"
        XCTAssertTrue(t61Refuses("unknown artifact field", "unknown field") {
            try self.t61LockPin(surcharged)
        }, "W19 an unknown artifact field was admitted")
    }

    private func t61GoodBody() -> String { return t61GoodArtifactJson() }

    // W20 -- the legacy estate is read-only and tell-tale.
    func testW20LegacySchemaOneIsTheReadonlyEstate() throws {
        let lock = try ModelLockV1.fromText(t61LegacyDoc(""))
        XCTAssertEqual(lock.schema, 1, "W20 the legacy estate must read schema 1")
        XCTAssertEqual(lock.status, "UNPINNED", "W20 the legacy estate must stand UNPINNED")
        XCTAssertTrue(lock.artifacts.isEmpty, "W20 the read-only estate nameth sworn artifacts")
        XCTAssertTrue(t61Refuses("legacy selection", "schema 1") { try lock.selectForTier("ALL") },
            "W20 the read-only estate answered a selection")
        XCTAssertEqual(try ModelLockV1.fromText(t61LegacyDoc("{}")).schema, 1,
            "W20 an archived empty native block was refused")
        XCTAssertTrue(t61Refuses("legacy native tale", "legacy estate") {
            try ModelLockV1.fromText(t61LegacyDoc("{\"abis\": [\"arm64-v8a\"]}"))
        }, "W20 a native tale under the read-only estate was admitted")
        XCTAssertTrue(t61Refuses("strict silent native", "wanteth field 'native'") {
            try ModelLockV1.fromText(t61LockJson("2", t61Q("PINNED"), t61Q("2026-09-13"),
                t61Q("the court's own eye"), "null", t61GoodArtifactJson(), ""))
        }, "W20 the strict estate kept its native tale silent")
        XCTAssertTrue(t61Refuses("strict non-object native", "wanteth field 'native'") {
            try ModelLockV1.fromText(t61LockJson("2", t61Q("PINNED"), t61Q("2026-09-13"),
                t61Q("the court's own eye"), "\"llama.cpp\"", t61GoodArtifactJson(), ""))
        }, "W20 a non-object native block was admitted")
    }

    private func t61LegacyDoc(_ nativeFragment: String) -> String {
        let nativePart = nativeFragment.isEmpty ? "" : "\"native\": " + nativeFragment + ", "
        return "{\"schema\": 1, \"status\": \"UNPINNED\", \"verified_on\": null, " +
            "\"verified_by\": null, " + nativePart + "\"notes\": null, \"artifacts\": [{" +
            "\"id\": \"generation-light\", \"tiers\": [\"LIGHT\"], " +
            "\"repo\": \"Qwen/Qwen3-0.6B-GGUF\", " +
            "\"source_file\": \"Qwen3-0.6B-Q4_K_M.gguf\", " +
            "\"output_file\": \"qwen3-0.6b-q4km.gguf\", \"sha256\": null}]}"
    }

    // W21 -- the strict reader itself refuseth the old JSON vices.
    func testW21TheStrictReaderRefusethDuplicateKeysAndTrailingMatter() throws {
        XCTAssertTrue(t61Refuses("duplicate keys", "duplicate key") {
            try t61ParseJson("{\"a\": 1, \"a\": 2}")
        }, "W21 the reader folded duplicate keys")
        XCTAssertTrue(t61Refuses("trailing matter", "trailing matter") {
            try t61ParseJson("{\"a\": 1} }")
        }, "W21 the reader suffered trailing matter")
        XCTAssertTrue(t61Refuses("fraction", "fractional") {
            try t61ParseJson("{\"a\": 1.5}")
        }, "W21 a fractional number entered the register")
        XCTAssertTrue(t61Refuses("unterminated string", "unterminated") {
            try t61ParseJson("{\"a\": \"truth")
        }, "W21 an unterminated string was read")
        let v = try t61ParseJson("{\"a\": [1, 2, null, true], \"b\": {\"c\": \"x\"}}")
        let top = v as? [String: Any]
        XCTAssertTrue(top != nil, "W21 the lawful document was refused")
        XCTAssertTrue((top?["a"] as? [Any])?.count == 4, "W21 the array lost an element")
        XCTAssertTrue(top?["b"] is [String: Any], "W21 the nested object was misread")
    }
}
