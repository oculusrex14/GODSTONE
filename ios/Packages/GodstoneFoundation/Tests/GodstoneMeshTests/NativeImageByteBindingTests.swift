import XCTest
import Foundation
import SQLite3
@testable import GodstoneMesh

//  ================================================================================================
//  *** THE HASH -> LOAD IMAGE-BINDING LAW, PROVEN BY EXECUTION ON A REAL IMAGE (SQLITE-REVIEW-5,
//  TOCTOU). ***
//
//  *THE DEFECT THIS COURT CONDEMNS, MEASURED IN THE OLD BODY: `SqlCipherDylibEngine` read and hashed the
//  approved image at a MUTABLE pathname and then called `dlopen` on THAT SAME PATHNAME. Between the hash
//  and the load, a replacer could substitute a DIFFERENT Mach-O -- and `dlopen` would execute it, its
//  CONSTRUCTORS included, BEFORE any function pointer was admitted or re-checked. A second hash or a
//  `stat` identity recheck after the load cannot repair an ABA: the wrong image has already run.*
//
//  **THE LAW, AND THE ARM THAT PROVES IT: the bytes whose digest matched the baked pin are written once
//  into an exclusively-created private snapshot and loaded from that private copy -- the mutable original
//  pathname carrieth NO weight in the load. The arms below SWAP the original for a DISTINCT REAL Mach-O
//  (a compiled dylib whose constructor writeth a marker) in the pre-load window, and then observe that the
//  approved bytes still load and the swapped image's constructor NEVER ran.** *No fake symbol, no mock and
//  no self-signed "promise" is involved: the discriminator is real code execution observed by a real file.*
//  ================================================================================================

#if os(macOS)

/// A thread-safe box, so a `@Sendable` pre-load hook can record what it saw.
private final class NIBBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: String?
    var value: String? { lock.lock(); defer { lock.unlock() }; return _value }
    func set(_ v: String?) { lock.lock(); _value = v; lock.unlock() }
}

final class NativeImageByteBindingTests: XCTestCase {

    // ------------------------------------------------------------------ fixtures

    /// The lane-staged, repo-built, pinned image (the same one `ReadinessT30Tests` requires).
    private func stagedPinnedImage() -> URL? {
        guard let dir = ProcessInfo.processInfo.environment["GODSTONE_SQLCIPHER_ARTIFACT_DIR"], !dir.isEmpty else {
            return nil
        }
        let url = URL(fileURLWithPath: dir).appendingPathComponent(SQLCipherPin.libraryName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func requireStagedImage(_ lane: String) -> Data? {
        guard let url = stagedPinnedImage(), let data = try? Data(contentsOf: url) else {
            XCTFail("*** MANDATORY NATIVE LANE '\(lane)': the pinned image '\(SQLCipherPin.libraryName)' is not "
                + "staged. It is repository-built: run tools/supplychain/build_sqlcipher_simulator.sh --mode macos "
                + "--out <dir> and export GODSTONE_SQLCIPHER_ARTIFACT_DIR=<dir>. ***")
            return nil
        }
        return data
    }

    /// Compile a DISTINCT REAL Mach-O whose CONSTRUCTOR writes `marker`. *This is the "different image" a
    /// replacer would substitute: not a stub and not a mock -- it really executes when loaded.*
    private func buildSwapImage(in dir: URL, marker: URL) throws -> URL {
        let source = dir.appendingPathComponent("nib_swap.c")
        let output = dir.appendingPathComponent("nib_swap.dylib")
        let cSource = """
        #include <fcntl.h>
        #include <unistd.h>
        __attribute__((constructor)) static void nib_swap_ctor(void) {
            int fd = open("\(marker.path)", O_WRONLY | O_CREAT | O_TRUNC, 0644);
            if (fd >= 0) { (void)write(fd, "SWAPPED-IMAGE-RAN", 17); close(fd); }
        }
        int nib_swap_probe(void) { return 42; }
        """
        try cSource.write(to: source, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
        process.arguments = ["-dynamiclib", "-o", output.path, source.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: output.path) else {
            throw NSError(domain: "NativeImageByteBindingTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "could not compile the swap fixture"])
        }
        return output
    }

    /// A fresh private root for one arm.
    private func makeRoot(_ name: String) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nib-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Stage a MUTABLE copy of the approved bytes at a private "original" path.
    private func stageMutableOriginal(_ data: Data, root: URL) throws -> URL {
        let stage = root.appendingPathComponent("stage", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        let url = stage.appendingPathComponent(SQLCipherPin.libraryName)
        try data.write(to: url)
        return url
    }

    private func snapshotEntries(_ dir: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    }

    // ------------------------------------------------------------------ (1) the hash->load law

    /// *** THE NAMED SEMANTIC NEGATIVE: THE BYTES READ AND VERIFIED ARE THE BYTES LOADED, EVEN IF THE
    /// ORIGINAL PATHNAME IS REPLACED BY A DIFFERENT REAL MACH-O IN THE PRE-LOAD WINDOW. ***
    ///
    /// *The hook fires only AFTER the digest matched the baked pin, so the approved bytes are already in hand;
    /// it then swaps the mutable original for a compiled dylib whose constructor writes a marker. The engine must
    /// still bind the approved bytes -- and the swapped image's constructor must NEVER run.*
    func testTheApprovedBytesLoadWhenTheOriginalPathnameIsSwappedForADifferentRealMachOBeforeTheLoad() throws {
        guard let approved = requireStagedImage("byte-binding hash->load") else { return }
        let root = try makeRoot("swap")
        let original = try stageMutableOriginal(approved, root: root)
        let marker = root.appendingPathComponent("swap-ran.marker")
        let swapImage = try buildSwapImage(in: root, marker: marker)
        let snapshotRoot = root.appendingPathComponent("snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshotRoot, withIntermediateDirectories: true)

        let sawLoad = NIBBox()
        let seam = ImageByteBindingTestSeam(
            willLoad: { loadPath in
                sawLoad.set(loadPath)
                // *THE PRE-LOAD WINDOW: replace the ORIGINAL pathname with a DIFFERENT real Mach-O. A loader that
                //  named this pathname would here be about to execute `swapImage`.*
                try? FileManager.default.removeItem(at: original)
                try? FileManager.default.copyItem(at: swapImage, to: original)
            },
            snapshotDirectory: snapshotRoot.path,
            artifactDirectory: original.deletingLastPathComponent().path)

        let engine = SqlCipherDylibEngine(testSeam: seam)

        XCTAssertEqual(
            engine.kind, .pinnedSQLCipher,
            "*** THE APPROVED BYTES MUST STILL BIND AFTER A PRE-LOAD SWAP OF THE ORIGINAL PATHNAME. "
                + "Reason: \(engine.bindingFailureReason ?? "unknown") ***")
        XCTAssertTrue(engine.isBound, "*** the engine must be really bound, not merely kind-tagged ***")
        guard let loadPath = sawLoad.value else {
            return XCTFail("*** the pre-load hook must have run (the load road must exist) ***")
        }
        XCTAssertNotEqual(
            loadPath, original.path,
            "*** THE LOAD MUST NOT NAME THE MUTABLE ORIGINAL PATHNAME. *A load by that name is exactly the "
                + "hash->load window this law closes. Observed load path: \(loadPath) ***")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: marker.path),
            "*** THE SWAPPED IMAGE'S CONSTRUCTOR MUST NEVER RUN. *Its marker file exists, so a DIFFERENT Mach-O "
                + "was executed before any pointer was admitted -- the exact TOCTOU defect. Observed: \(marker.path) ***")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: original.path),
            "*** THE ORIGINAL ARTIFACT'S NAME MUST STILL EXIST (the engine may not delete the user's image) ***")
    }

    /// *** THE SAME PRE-LOAD SWAP, BUT NOW PROVING THE APPROVED IMAGE REALLY *WORKED*: A REAL KEYED STORE. ***
    ///
    /// *Binds after the swap, opens a store through the pinned engine, and requires that the real SQLCipher actually
    /// encrypteth -- the on-disk header is not the plaintext SQLite header.*
    func testThePostSwapBindingRunsTheRealApprovedCipherOnARealStore() throws {
        guard let approved = requireStagedImage("byte-binding post-swap positive") else { return }
        let root = try makeRoot("positive")
        let original = try stageMutableOriginal(approved, root: root)
        let marker = root.appendingPathComponent("swap-ran.marker")
        let swapImage = try buildSwapImage(in: root, marker: marker)
        let snapshotRoot = root.appendingPathComponent("snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshotRoot, withIntermediateDirectories: true)

        let seam = ImageByteBindingTestSeam(
            willLoad: { _ in
                try? FileManager.default.removeItem(at: original)
                try? FileManager.default.copyItem(at: swapImage, to: original)
            },
            snapshotDirectory: snapshotRoot.path,
            artifactDirectory: original.deletingLastPathComponent().path)
        let engine = SqlCipherDylibEngine(testSeam: seam)
        XCTAssertTrue(engine.isBound, "the approved bytes must bind: \(engine.bindingFailureReason ?? "unknown")")

        let storePath = root.appendingPathComponent("mesh.db").path
        let handle = try engine.openForWriting(path: storePath, dek: StoreDEK(bytes: Data(repeating: 0x5C, count: 32)))
        XCTAssertTrue(handle.encryptedAtRest, "*** the bound approved engine must claim at-rest through a real open ***")
        XCTAssertEqual(handle.kind, .pinnedSQLCipher)
        XCTAssertEqual(handle.cipherVersion, SQLCipherPin.supportedCipherVersion)

        let header = try Data(contentsOf: URL(fileURLWithPath: storePath)).prefix(16)
        XCTAssertNotEqual(
            Data(header), Data("SQLite format 3\0".utf8),
            "*** THE REAL PINNED CIPHER MUST HAVE ENCRYPTED THE FILE (no plaintext SQLite header). *A swap that "
                + "silently degraded to plaintext would leave this header intact.* ***")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path),
                       "*** the swapped image must still never have run ***")
    }

    // ------------------------------------------------------------------ (2) the pin gate is unchanged

    /// *** A DIFFERENT REAL IMAGE AT THE ORIGINAL PATH IS STILL REFUSED BY THE BAKED PIN -- THE COPY ROAD DID
    /// NOT LOOSEN AUTHORISATION. ***
    func testAnUnapprovedRealMachOAtTheStageIsRefusedByTheBakedExpectation() throws {
        let root = try makeRoot("unapproved")
        let marker = root.appendingPathComponent("swap-ran.marker")
        let swapImage = try buildSwapImage(in: root, marker: marker)
        let stage = root.appendingPathComponent("stage", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        let unapproved = stage.appendingPathComponent(SQLCipherPin.libraryName)
        try FileManager.default.copyItem(at: swapImage, to: unapproved)

        let engine = SqlCipherDylibEngine(testSeam: ImageByteBindingTestSeam(
            willLoad: { _ in XCTFail("the load hook must never fire for an image that fails the pin") },
            snapshotDirectory: root.appendingPathComponent("snapshots").path,
            artifactDirectory: stage.path))

        XCTAssertFalse(
            engine.isBound,
            "*** AN IMAGE THAT IS NOT THE BAKED BYTES MUST BE REFUSED -- the copy road carrieth no self-authority. ***")
        XCTAssertEqual(engine.kind, .plainSQLite, "an unapproved image must never claim `.pinnedSQLCipher`")
        XCTAssertNotNil(engine.bindingFailureReason, "the refusal must be NAMED")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path),
                       "*** THE REFUSED IMAGE MUST NOT BE LOADED EITHER (its constructor must not run) ***")
    }

    // ------------------------------------------------------------------ (3) lifetime + cleanup

    /// *** THE PRIVATE COPY LIVETH EXACTLY AS LONG AS A NATIVE USER -- AND ITS CLEANUP NEVER TOUCHES THE
    /// ORIGINAL ARTIFACT. ***
    ///
    /// *A retained owned connection outlives the engine and keepeth the image (and its private copy) alive; only
    /// when the LAST user falls is the copy removed. At no point is the original stage file deleted.*
    func testThePrivateCopyOutlivesTheEngineAndIsRemovedOnlyWhenTheLastUserFalls() throws {
        guard let approved = requireStagedImage("byte-binding lifetime") else { return }
        let root = try makeRoot("lifetime")
        let original = try stageMutableOriginal(approved, root: root)
        let snapshotRoot = root.appendingPathComponent("snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshotRoot, withIntermediateDirectories: true)

        var engine: SqlCipherDylibEngine? = SqlCipherDylibEngine(testSeam: ImageByteBindingTestSeam(
            willLoad: { _ in },
            snapshotDirectory: snapshotRoot.path,
            artifactDirectory: original.deletingLastPathComponent().path))
        XCTAssertTrue(engine?.isBound ?? false, "the approved image must bind: \(engine?.bindingFailureReason ?? "unknown")")
        XCTAssertFalse(snapshotEntries(snapshotRoot).isEmpty,
                       "*** a private snapshot must exist while the engine is bound ***")

        let storePath = root.appendingPathComponent("held.db").path
        var owned: OwnedConnection? = try engine!.openOwnedForWriting(
            path: storePath, dek: StoreDEK(bytes: Data(repeating: 0x33, count: 32)))

        engine = nil
        XCTAssertFalse(
            snapshotEntries(snapshotRoot).isEmpty,
            "*** THE PRIVATE COPY MUST OUTLIVE THE ENGINE WHILE A NATIVE USER (the owned connection) REMAINS. "
                + "*If the copy vanished here, the connection's function pointers would dispatch into an unmapped image.* ***")

        owned?.close()
        owned = nil   // the last native user falls: its lease reference is the last, so the copy is removed here
        XCTAssertTrue(
            snapshotEntries(snapshotRoot).isEmpty,
            "*** AFTER THE LAST NATIVE USER FALLS THE PRIVATE COPY MUST BE REMOVED (no leak) ***")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: original.path),
            "*** CLEANUP MUST NEVER DELETE THE ORIGINAL ARTIFACT -- only the private copy. ***")
    }
}

#endif
