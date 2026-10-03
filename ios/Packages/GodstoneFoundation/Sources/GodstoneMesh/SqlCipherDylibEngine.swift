import Foundation
import CryptoKit
//  GS-STORE-002 / GS-FINAL-004 (`native-engine-half`): THE REAL SQLCIPHER ENGINE, DYNAMICALLY BOUND.
//
//  *** THE FINDING'S OWN WORDS, QUOTED: "iOS private stores still use ordinary SQLite without a store
//  DEK" -- AND ITS REMEDIATION STEP NAMES WHAT IS MISSING: "Implement EncryptedStoreEngine using
//  native SQLCipher open, key application before schema reads, and a verified cipher
//  version/configuration." ***
//
//  MEASURED BEFORE THIS FILE: `EncryptedStoreEngine` had NO production implementor in this tree at
//  all -- the only conformers were courts' `FakeEngine`s -- so `EncryptedStoreFactory.reopenOwned`
//  answered `.engineUnavailable` for every real composition, and both private stores fell back to
//  their ordinary-SQLite roads. The ledger recorded that absence as a blocker ("no implementor in
//  tree"); THIS FILE REMOVES THAT EXCUSE. **The pinned image ITSELF is REPOSITORY-OWNED**: the host
//  and simulator images are built from the pinned source recipe
//  (`tools/supplychain/build_sqlcipher_simulator.sh`) and their per-toolchain digests are recorded in
//  the repo-owned register (`docs/supplychain/SQLCIPHER.pins.json`) from which the generated
//  `SQLCipherTrustedExpectation` is emitted. What remains genuinely outside the builder's reach is the
//  DEVICE-signed artifact and the on-device at-rest proof, which stay `EXTERNAL_BLOCKED`.
//
//  *** WHY `dlopen`/`dlsym` RATHER THAN A VENDORED LIBRARY OR A SYNTHESIZED ARTIFACT. ***
//  *`third_party/llama.cpp`'s precedent in this repository forbids vendoring the artifact.* And a
//  synthesized `.tbd`/stub would be the "enum value called pinnedSQLCipher is not engine
//  verification" defect wearing a linker flag. **Dynamic binding leaves the artifact where the
//  supply chain puts it, and makes its ABSENCE a RUNTIME ANSWER rather than a link error** -- which
//  is exactly the fail-closed shape the card asks for: no approved artifact means no engine, and no
//  engine means no private store, never a plaintext one.
//
//  *** AND THIS IS NOT A CLAIM OF DEVICE VERIFICATION. *** Host and simulator images are repo-owned and
//  proven hereby EXECUTION; **the DEVICE-signed artifact and the at-rest bytes on a real device remain the
//  EXTERNAL half** (`gs-store-002.sqlcipher-engine`). **Everything this file proves is provable on a
//  host, and it proves it by EXECUTION:** the symbols really are resolved from a real dynamic
//  library, the key really is applied before any schema read, and the cipher probe really is what
//  decides `encryptedAtRest`.

/// *** THE PINNED ARTIFACT'S NAME, AS THE SUPPLY CHAIN RECORDS IT. ***
///
/// *This is the ONE place the library's identity is stated, so a change to the pin is a change to
/// one constant.* **The name is deliberately NOT a glob and NOT a search path:** *a `dlopen` that
/// tried several names could succeed against a DIFFERENT library than the one the supply chain
/// approved, which is the same class of defect as a build that resolves `sqlcipher` to whatever
/// happens to be on the linker path.*
public enum SQLCipherPin {
    /// The library the approved iOS artifact is expected to provide.
    ///
    /// *`net.zetetic:sqlcipher-android` is pinned for the Android isle (`docs/supplychain/SBOM.json`,
    /// digest `44fc40c3…`, version `4.17.0`).* **The iOS artifact's own pin is repo-owned: the host and
    /// simulator digests are recorded per-toolchain in `docs/supplychain/SQLCIPHER.pins.json` and baked
    /// into the generated `SQLCipherTrustedExpectation`; only the DEVICE-signed artifact remains external.**
    /// **The name here is the Apple-platform spelling of the same engine.**
    public static let libraryName = "libsqlcipher.0.dylib"

    /// The cipher version this build accepts. *A store keyed by a different generation is REFUSED by
    /// name rather than opened and hoped for -- the same rule `unsupportedVersion` carrieth on the
    /// metadata road.*
    public static let supportedCipherVersion = 4
}

/// *** THE SYMBOLS THIS ENGINE NEEDS ARE NOW DECLARED IN ONE PLACE: `SQLiteFunctionTable`. ***
///
/// *THE DEFECT THIS REPLACES: this file carrieth EIGHT private typealiases and bound exactly those eight symbols --
/// which is why the engine could perform its own probe and nothing more, leaving the ADOPTING STORES to reach the
/// globally linked `sqlite3_*` functions for the other twelve entry points they use.* **The complete surface now lives
/// in `SQLiteFunctionTable.requiredSymbols`, bound all-or-nothing from the one image, and handed over with the
/// connection.** *`sqlite3_key`/`sqlite3_rekey` remain deliberately ABSENT there: SQLCipher's `PRAGMA key` is the
/// documented interface and it goeth through the statement road, which keeps the key material inside the engine's own
/// parser rather than in a buffer this file owns.*

/// *** THE DYNAMICALLY BOUND SQLCIPHER ENGINE. ***
///
/// *A conformer of `OwnedConnectionStoreEngine`, so the factory's OWNED road can ask it for a
/// connection -- which is the road that makes a second, independent open impossible.*
///
/// **FAIL-CLOSED BY CONSTRUCTION, IN THREE PLACES:**
///   1. the pinned library absent -> `kind` reporteth `.plainSQLite`, so the factory refuseth with
///      `.engineUnavailable` BEFORE any file is touched;
///   2. any symbol missing from a library that DOES load -> the same refusal, because a partially
///      bound engine cannot perform the probe that decideth the answer;
///   3. the key, the cipher version or the schema probe failing -> a TYPED fault, and the handle is
///      closed on EVERY failure path before the throw.
public final class SQLCipherRuntimeProof: @unchecked Sendable {
    fileprivate let table: SQLiteFunctionTable
    fileprivate init(table: SQLiteFunctionTable) { self.table = table }
    internal func matches(_ connection: OwnedVerifiedConnection) -> Bool {
        connection.provider.lease === table.lease && table.lease != nil
    }
}

/// *** THE PRE-LOAD DISCRIMINATOR SEAM -- **HOST/SIMULATOR COURTS ONLY**. ***
///
/// *The production road passeth `nil`, so this is a no-op outside a court. A court uses it to model the REAL swap
/// window deterministically: immediately AFTER the approved bytes are read and verified, a DIFFERENT real Mach-O is
/// put at the mutable name the bytes came from. On the OLD road that swap made `dlopen(pathname)` execute the wrong
/// image (constructors included) BEFORE any pointer was admitted; on the NEW road the image is loaded from an unnamed
/// private snapshot of the ALREADY-VERIFIED bytes, so the swap cannot reach the load at all.*
///
/// **IT CANNOT APPROVE AN ARBITRARY IMAGE.** *The hook runs only after the bytes have matched the baked pin
/// (digest + bytes + arch + platform), it cannot change the bytes the engine loads, and it cannot alter the compiled
/// `SQLCipherTrustedExpectation`. It is an `internal` seam of the PRODUCTION initializer, never a factory input, and
/// it can never label an arbitrary library `.pinnedSQLCipher`.*
internal struct ImageByteBindingTestSeam: @unchecked Sendable {
    /// Called after the approved bytes are verified and immediately before the image is loaded. *Receives the private
    /// snapshot path the loader is about to use -- never the original image's pathname.*
    let willLoad: @Sendable (String) -> Void
    /// The host directory the private snapshot is created under (a court's own temp root). *`nil` -> the system
    /// temporary directory.*
    let snapshotDirectory: String?
    /// An ARTIFACT SEARCH DIRECTORY consulted first, exactly as `GODSTONE_SQLCIPHER_ARTIFACT_DIR` is -- a court can
    /// stage a private, mutable copy of the approved image without mutating process-global environment. *The bytes are
    /// still verified against the baked pin, so this cannot admit an unapproved image.*
    let artifactDirectory: String?
    init(willLoad: @escaping @Sendable (String) -> Void,
         snapshotDirectory: String? = nil,
         artifactDirectory: String? = nil) {
        self.willLoad = willLoad
        self.snapshotDirectory = snapshotDirectory
        self.artifactDirectory = artifactDirectory
    }
}

public final class SqlCipherDylibEngine: OwnedConnectionStoreEngine, @unchecked Sendable {
    public private(set) var runtimeEngineProof: SQLCipherRuntimeProof?
    /// *** THE COMPLETE TABLE BOUND FROM THIS ENGINE'S OWN IMAGE -- ALL-OR-NOTHING. ***
    ///
    /// *The old engine bound eight symbols into a private struct and then let the adopting stores reach the GLOBALLY
    /// LINKED `sqlite3_*` functions for everything else. This table carrieth the COMPLETE surface both stores use, all
    /// resolved from the one image, and `openKeyedVerified` hands it to the connection -- so no raw handle ever
    /// crosses a provider boundary through a global symbol again.*
    private let table: SQLiteFunctionTable?
    private let bindingFailure: String?
    private let isArbitraryPath: Bool

    private struct SidecarFormat: Decodable {
        struct SourceInfo: Decodable {
            let commit: String
            let tag: String
            let repo: String
        }
        let library_name: String
        let source: SourceInfo
        let cipher_version_major: Int
        let platform: String
        let arch: String
        let sha256: String
        let bytes: Int
        let mode: String
    }

    private static func verifyMachO(data: Data, expectedArch: String) -> Bool {
        guard data.count >= 8 else { return false }
        let magic = data.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
        let cputype = data.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }
        let is64 = (magic == 0xfeedfacf || magic == 0xcffaedfe)
        guard is64 else { return false }
        let isLittleEndian = (magic == 0xfeedfacf)
        let actualCpu = isLittleEndian ? cputype : cputype.byteSwapped
        if expectedArch == "arm64" {
            return actualCpu == 0x0100000C
        } else if expectedArch == "x86_64" {
            return actualCpu == 0x01000007
        }
        return true
    }

    private static func sha256Hex(data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// *** THE PRIVATE, EXCLUSIVELY-CREATED SNAPSHOT: THE VERIFIED BYTES ARE LOADED FROM A PRIVATE COPY, NEVER FROM
    /// THE MUTABLE ORIGINAL PATHNAME. ***
    ///
    /// *THE DEFECT THIS CLOSES, MEASURED IN THE PREVIOUS BODY: the loader read and hashed the approved image at
    /// `libPath`, and then called `dlopen(libPath, …)`. Between the hash and the load, `libPath` is an ordinary
    /// MUTABLE pathname: a replacer could substitute a DIFFERENT Mach-O there, and `dlopen` would execute it --
    /// constructors included -- **before any function pointer was admitted or re-checked**. Re-hashing or re-`stat`ing
    /// after the load cannot repair this: it is an ABA window, and the wrong image has already run.*
    ///
    /// **THE REPAIR: an exclusively created (`O_EXCL`, mode `0600`) private copy of the ALREADY-VERIFIED `fileData`
    /// -- no second read of the original is performed -- inside a fresh `0700` root this call owns, loaded at that
    /// private root's own unique pathname.** *The bytes the loader maps are therefore the exact bytes this method wrote
    /// and verified; the replacer's target (the original pathname) is never consulted for the load, and the copy liveth
    /// only beneath this call's own `0700` root -- removed by the lease when the last user falls, and on EVERY failure
    /// path. The ORIGINAL artifact is never touched, deleted or mutated.*
    ///
    /// **Why a private PATHNAME and not `/dev/fd`:** *`dlopen` on Darwin resolves `/dev/fd/<n>` through the code-signing
    /// policy, which nondeterministically rejecteth a process-created copy ("library load disallowed by system
    /// policy" -- measured on this host). A unique private pathname inside this call's own `0700` root loads
    /// deterministically and is reported by `dladdr`, so the bind-time image cross-check still holds.*
    ///
    /// **Platform scope, stated as law, not hope:** *this copy road is the macOS/SIMULATOR road, where the image is a
    /// plain Mach-O that the platform loader will map. On a real DEVICE the process image must satisfy the kernel's
    /// code-signing policy (AMFI), and Apple's primary guidance is that `dlopen` may load only libraries BUILT IN TO
    /// THE OS or EMBEDDED WITHIN THE APP (Apple Developer Forums 773210), while any attempt to MODIFY a bundle at
    /// runtime is enforced against (Apple's bundle documentation: "A bundle is a read-only structure. All Apple
    /// platforms except the Mac enforce this requirement at runtime"). **So on a device the loader does NOT take this
    /// road: `loadSignedBundleImage` binds the **sealed, signed, bundle-resident** pathname, whose integrity the code
    /// signature -- not a byte copy -- enforces.***
    private static func loadVerifiedSnapshot(fileData: Data,
                                             snapshotDirectory: String?,
                                             seal: ImageByteBindingTestSeam?) throws
        -> (handle: UnsafeMutableRawPointer, imagePath: String, snapshotRoot: String) {
        let base = snapshotDirectory ?? NSTemporaryDirectory()
        let rootPath = (base as NSString).appendingPathComponent("godstone-sqlcipher-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(atPath: rootPath, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw StoreOpenFault.io("could not create a private image snapshot root")
        }
        func cleanup() { try? FileManager.default.removeItem(atPath: rootPath) }
        let snapshotPath = (rootPath as NSString).appendingPathComponent("image.dylib")
        let fd = snapshotPath.withCString { open($0, O_WRONLY | O_CREAT | O_EXCL, 0o600) }
        guard fd >= 0 else {
            cleanup()
            throw StoreOpenFault.io("could not exclusively create a private image snapshot")
        }
        let wrote: Bool = fileData.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return fileData.isEmpty }
            var off = 0
            while off < raw.count {
                let n = write(fd, base.advanced(by: off), raw.count - off)
                if n <= 0 { return false }
                off += n
            }
            return true
        }
        guard wrote else {
            close(fd)
            cleanup()
            throw StoreOpenFault.io("could not write the private image snapshot")
        }
        _ = fsync(fd)
        close(fd)
        // *The court's pre-load hook fires HERE: after verification, before the load. It receives the private
        //  snapshot path the loader is about to use -- NOT the original image's pathname.*
        seal?.willLoad(snapshotPath)
        let h = dlopen(snapshotPath, RTLD_NOW | RTLD_LOCAL)
        guard let h else {
            let why = dlerror().map { String(cString: $0) } ?? "dlopen returned no handle"
            cleanup()
            throw StoreOpenFault.io("dlopen of the verified private snapshot failed: \(why)")
        }
        // *** THE COPY STAYETH ONLY UNDER THIS CALL'S OWN `0700` ROOT, AND THE LEASE REMOVETH IT WHEN THE LAST USER
        //  FALLS. *** *No other user can traverse the root, so there is no attacker-controlled pathname for the load;
        //  the copy's own unique name is the one `dlopen` and `dlsym`/`dladdr` are resolved against. The original
        //  artifact's pathname is never used by this road at all.*
        return (h, snapshotPath, rootPath)
    }

    /// *** BIND FROM THE **SEALED BUNDLE-RESIDENT SIGNED IMAGE** -- THE DEVICE ROAD. ***
    ///
    /// *On a real device the platform will not map a process-created copy; the image must be a signed, embedded bundle
    /// item, and the bundle is the one container Apple enforceth as read-only at runtime. The load therefore happeneth
    /// at the image's own installed pathname, and the digest/arch/platform/bytes checks above are the pre-load
    /// cross-check of the SAME signed bytes the kernel will admit.*
    ///
    /// **HONEST LIMIT, AS LAW:** *this road has the same class of pathname window as any bundle load, but on-device the
    /// window is closed by AMFI/code-signing (a swapped byte sequence no longer matchs the signature the kernel
    /// verified) rather than by this file. This repo cannot execute a device load, so this is the platform-correct
    /// shape with its evidence cited, NOT a claim of on-device proof -- which remains the external device gate. The
    /// signed image's own bytes are still digested above; `SQLCipherTrustedExpectation` is the DEVICE artifact's
    /// recorded (still-external) digest, and this road refuseth a signed image whose bytes do not match it.*
    private static func loadSignedBundleImage(originalPath: String) throws
        -> (handle: UnsafeMutableRawPointer, imagePath: String) {
        let h = dlopen(originalPath, RTLD_NOW | RTLD_LOCAL)
        guard let h else {
            let why = dlerror().map { String(cString: $0) } ?? "dlopen returned no handle"
            throw StoreOpenFault.io("dlopen of the signed bundle image '\(originalPath)' failed: \(why)")
        }
        return (h, originalPath)
    }

    /// *** THE MACH-O PLATFORM CHECK (SQLITE-LATEST-C4/REVIEW-5): ARCHITECTURE ALONE IS NOT ENOUGH. ***
    ///
    /// *A macOS and an iOS-simulator image can share `arm64` and still be mutually unloadable; the platform liveth in the
    /// LC_BUILD_VERSION (`0x32`) / LC_VERSION_MIN_* load command, not in the cputype. So the loader now reads the
    /// platform field of that command and requires it to match the expectation.* **`PLATFORM_MACOS = 1`,
    /// `PLATFORM_IOSSIMULATOR = 7`, `PLATFORM_IOS = 2`.** *An unreadable/absent command fails closed.*
    private static func verifyMachOPlatform(data: Data, expectedPlatform: String) -> Bool {
        // Parse the Mach-O load commands; find LC_BUILD_VERSION (0x32) and read its `platform` field.
        let lcBuildVersion: UInt32 = 0x32
        guard data.count >= 32 else { return false }
        let magic = data.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
        let little = (magic == 0xfeedfacf)
        guard magic == 0xfeedfacf || magic == 0xcffaedfe else { return false }
        func u32(_ off: Int) -> UInt32 {
            let v = data.withUnsafeBytes { $0.load(fromByteOffset: off, as: UInt32.self) }
            return little ? v : v.byteSwapped
        }
        let ncmds = Int(u32(16))
        var off = 32
        for _ in 0..<ncmds {
            guard off + 8 <= data.count else { return false }
            let cmd = u32(off)
            let cmdsize = Int(u32(off + 4))
            if cmdsize < 8 || off + cmdsize > data.count { return false }
            if cmd == lcBuildVersion, cmdsize >= 24 {
                // struct build_version_command { cmd, cmdsize, platform, minos, sdk, ntools }
                let platform = u32(off + 8)
                let map: [String: UInt32] = ["MACOS": 1, "IOS": 2, "IOSSIMULATOR": 7]
                guard let want = map[expectedPlatform] else { return false }
                return platform == want
            }
            off += cmdsize
        }
        return false   // no LC_BUILD_VERSION: fail closed rather than admit an unverifiable platform
    }

    /// *** THE PRODUCTION CONSTRUCTOR: RESOLVE, VERIFY THE BAKED EXPECTATION, AND ONLY THEN `dlopen`. ***
    ///
    /// *SQLITE-REVIEW-5: arbitrary path loading is forbidden in production; the runtime must verify the actual
    /// supplied artifact descriptor (digest, platform, architecture, cipher major, source commit) BEFORE `dlopen`.*
    /// *The production constructor; the court-only hook liveth on `init(testSeam:)`.*
    public convenience init() { self.init(testSeam: nil) }

    /// *** THE PRODUCTION ROAD, WITH AN OPTIONAL COURT HOOK (`ImageByteBindingTestSeam`). ***
    ///
    /// *`testSeam` is `nil` in every production composition, so the hook is inert there; a host court passeth one to
    /// model the real hash->load window deterministically.* **A seam can only OBSERVE the load; it cannot change the
    /// verified bytes the engine chooses, and it cannot alter the baked expected pin.**
    internal init(testSeam: ImageByteBindingTestSeam?) {
        self.isArbitraryPath = false
        var searchDirs: [String] = []
        if let seamDir = testSeam?.artifactDirectory, !seamDir.isEmpty {
            searchDirs.append(seamDir)
        }
        if let envDir = ProcessInfo.processInfo.environment["GODSTONE_SQLCIPHER_ARTIFACT_DIR"], !envDir.isEmpty {
            searchDirs.append(envDir)
        }
        if let frameworks = Bundle(for: SqlCipherDylibEngine.self).privateFrameworksPath {
            searchDirs.append(frameworks)
        }
        if let mainFrameworks = Bundle.main.privateFrameworksPath {
            searchDirs.append(mainFrameworks)
        }
        #if targetEnvironment(simulator)
        searchDirs.append("/tmp/sqlcipher-sim")
        #else
        searchDirs.append("/tmp/sqlcipher-macos")
        #endif

        var resolvedLibPath: String?
        for dir in searchDirs {
            let candidate = (dir as NSString).appendingPathComponent(SQLCipherPin.libraryName)
            if FileManager.default.fileExists(atPath: candidate) {
                resolvedLibPath = candidate
                break
            }
        }

        guard let libPath = resolvedLibPath else {
            self.table = nil
            self.bindingFailure = "the pinned SQLCipher library '\(SQLCipherPin.libraryName)' was not found in any search path"
            return
        }

        // *** THE BAKED EXPECTATION MUST MATCH THIS RUNTIME (SQLITE-LATEST-C4). *** *If the generated constant is for a
        // DIFFERENT mode/platform/arch than the process, the loader refuses rather than guessing.*
        #if os(macOS)
        let runtimePlatform = "MACOS"
        #elseif targetEnvironment(simulator)
        let runtimePlatform = "IOSSIMULATOR"
        #else
        let runtimePlatform = "IOS"
        #endif
        guard SQLCipherTrustedExpectation.platform == runtimePlatform else {
            self.table = nil
            self.bindingFailure = "the baked SQLCipher trust expectation is for platform \(SQLCipherTrustedExpectation.platform), but this runtime is \(runtimePlatform); re-emit it for this mode"
            return
        }
        #if arch(arm64)
        let runtimeArch = "arm64"
        #elseif arch(x86_64)
        let runtimeArch = "x86_64"
        #else
        let runtimeArch = "unknown"
        #endif
        guard SQLCipherTrustedExpectation.arch == runtimeArch else {
            self.table = nil
            self.bindingFailure = "the baked SQLCipher trust expectation is for arch \(SQLCipherTrustedExpectation.arch), but this runtime is \(runtimeArch)"
            return
        }
        guard SQLCipherTrustedExpectation.libraryName == SQLCipherPin.libraryName else {
            self.table = nil
            self.bindingFailure = "the baked expectation names '\(SQLCipherTrustedExpectation.libraryName)', not the pinned '\(SQLCipherPin.libraryName)'"
            return
        }

        // *** THE SIDECAR IS A **RECORD**, NEVER THE AUTHORITY (SQLITE-LATEST-C4). *** *If one is present BESIDE the
        // image, it must AGREE with the baked expectation -- a disagreement is a refusal (a swapped image/sidecar pair
        // cannot both authorise themselves). Its absence is fine: the expectation is compiled in.*
        let sidecarPath = (libPath as NSString).deletingLastPathComponent
            .appending("/\(SQLCipherArtifactDescriptor.sidecarName(forLibrary: SQLCipherPin.libraryName))")
        if FileManager.default.fileExists(atPath: sidecarPath),
           let sidecarData = try? Data(contentsOf: URL(fileURLWithPath: sidecarPath)),
           let sidecar = try? JSONDecoder().decode(SidecarFormat.self, from: sidecarData) {
            guard sidecar.source.commit == SQLCipherTrustedExpectation.commit,
                  sidecar.source.tag == SQLCipherTrustedExpectation.tag,
                  sidecar.source.repo == SQLCipherTrustedExpectation.repo,
                  sidecar.library_name == SQLCipherTrustedExpectation.libraryName,
                  sidecar.mode == SQLCipherTrustedExpectation.mode,
                  sidecar.platform == SQLCipherTrustedExpectation.platform,
                  sidecar.arch == SQLCipherTrustedExpectation.arch,
                  sidecar.cipher_version_major == SQLCipherTrustedExpectation.cipherVersionMajor else {
                self.table = nil
                self.bindingFailure = "the artifact sidecar DISAGREES with the baked trust expectation at '\(sidecarPath)'"
                return
            }
        }
        guard SQLCipherTrustedExpectation.cipherVersionMajor == SQLCipherPin.supportedCipherVersion else {
            self.table = nil
            self.bindingFailure = "the baked expectation's cipher major \(SQLCipherTrustedExpectation.cipherVersionMajor) disagrees with the engine's \(SQLCipherPin.supportedCipherVersion)"
            return
        }

        guard let fileData = try? Data(contentsOf: URL(fileURLWithPath: libPath)) else {
            self.table = nil
            self.bindingFailure = "could not read artifact file at '\(libPath)'"
            return
        }
        guard fileData.count == SQLCipherTrustedExpectation.bytes else {
            self.table = nil
            self.bindingFailure = "artifact byte count mismatch: expected \(SQLCipherTrustedExpectation.bytes), got \(fileData.count)"
            return
        }
        guard Self.verifyMachO(data: fileData, expectedArch: SQLCipherTrustedExpectation.arch) else {
            self.table = nil
            self.bindingFailure = "artifact Mach-O architecture check failed for '\(libPath)'"
            return
        }
        // *** AND THE PLATFORM, NOT MERELY THE ARCH (a macOS and a simulator image both carry arm64). ***
        guard Self.verifyMachOPlatform(data: fileData, expectedPlatform: SQLCipherTrustedExpectation.platform) else {
            self.table = nil
            self.bindingFailure = "artifact Mach-O PLATFORM check failed for '\(libPath)' (expected \(SQLCipherTrustedExpectation.platform))"
            return
        }
        let actualDigest = Self.sha256Hex(data: fileData)
        guard actualDigest.lowercased() == SQLCipherTrustedExpectation.sha256.lowercased() else {
            self.table = nil
            self.bindingFailure = "artifact digest mismatch: expected \(SQLCipherTrustedExpectation.sha256), got \(actualDigest)"
            return
        }

        // *** THE LOAD ROAD IS CHOSEN BY PLATFORM -- AND ONLY THE DEVICE ROAD MAY NAME THE ORIGINAL PATHNAME. ***
        //
        // *Host/simulator: the verified bytes are written once into an exclusively-created `0600` private snapshot,
        // and loaded from a unique path inside a fresh `0700` root -- so the mutable original pathname carrieth NO
        // weight in the load and cannot be ABA-swapped into executing a different image. Device: the process image must
        // be the sealed, signed, bundle-resident one, so the device bindeth that container path and the code signature
        // -- not a copy -- is what the kernel enforceth.*
        #if targetEnvironment(simulator) || os(macOS)
        let boundTable: SQLiteFunctionTable?
        do {
            let loaded = try Self.loadVerifiedSnapshot(fileData: fileData,
                                                       snapshotDirectory: testSeam?.snapshotDirectory,
                                                       seal: testSeam)
            let lease = SQLiteImageLease(handle: loaded.handle, snapshotRoot: loaded.snapshotRoot)
            boundTable = SQLiteFunctionTable.bind(fromImage: loaded.handle,
                                                  providerName: "SQLCipher (\(SQLCipherPin.libraryName))",
                                                  lease: lease, imagePath: loaded.imagePath)
        } catch {
            self.table = nil
            self.bindingFailure = "could not bind the verified bytes from a private snapshot: \(error)"
            return
        }
        #else
        // *** THE DEVICE ROAD VERIFIETH THE CONTAINER, RATHER THAN TRUSTING A STRING. ***
        //
        // *A device may `dlopen` only an image EMBEDDED WITHIN THE APP (Apple DTS, Forums 773210) -- so the resolved
        // path MUST lie inside the app's own bundle container, the one structure the platform enforceth as read-only
        // and covers with the code signature. A path outside it (a user directory, a temp file, an absolute string) is
        // REFUSED here, before any load: the digest check above is not a substitute for the container check, because a
        // mutable path can be swapped between the two.*
        let bundleRoot = Bundle.main.bundleURL.standardizedFileURL.path
        let canonicalLib = URL(fileURLWithPath: libPath).standardizedFileURL.path
        guard canonicalLib.hasPrefix(bundleRoot + "/") else {
            self.table = nil
            self.bindingFailure = "the resolved image '\(canonicalLib)' is NOT inside the signed app container "
                + "'\(bundleRoot)'; a device may bind only a bundle-embedded, signed image"
            return
        }
        let boundTable: SQLiteFunctionTable?
        do {
            let loaded = try Self.loadSignedBundleImage(originalPath: canonicalLib)
            let lease = SQLiteImageLease(handle: loaded.handle)
            boundTable = SQLiteFunctionTable.bind(fromImage: loaded.handle,
                                                  providerName: "SQLCipher (\(SQLCipherPin.libraryName))",
                                                  lease: lease, imagePath: loaded.imagePath)
        } catch {
            self.table = nil
            self.bindingFailure = "could not bind the signed bundle image: \(error)"
            return
        }
        #endif
        guard let bound = boundTable else {
            // *No table is published; the lease's own fall unloads the image and removes the private copy, so a failed
            //  bind leaks neither an image nor a snapshot -- and never touches the original artifact.*
            self.table = nil
            self.bindingFailure = "the verified image loaded but failed symbol binding"
            return
        }
        self.table = bound
        self.runtimeEngineProof = SQLCipherRuntimeProof(table: bound)
        self.bindingFailure = nil
    }

    /// Internal initializer for adapter tests driving missing/unapproved library paths.
    internal init(libraryPath: String, claimPinned: Bool = false) {
        self.isArbitraryPath = !claimPinned
        let h = dlopen(libraryPath, RTLD_NOW | RTLD_LOCAL)
        guard let h else {
            let why = dlerror().map { String(cString: $0) } ?? "dlopen returned no handle"
            self.table = nil
            self.bindingFailure = "the pinned SQLCipher library '\(libraryPath)' is not present: \(why)"
            return
        }
        let lease = SQLiteImageLease(handle: h)
        guard let bound = SQLiteFunctionTable.bind(fromImage: h,
                                                   providerName: "SQLCipher (\(libraryPath))",
                                                   lease: lease, imagePath: libraryPath) else {
            self.table = nil
            self.bindingFailure = "the library '\(libraryPath)' loaded but carrieth not the complete sqlite3 surface"
            return
        }
        self.table = bound
        self.bindingFailure = nil
    }

    /// Internal test injection seam: runs the production open/probe road over an injected table.
    internal init(testTable: SQLiteFunctionTable, bindingFailure: String? = nil, claimPinned: Bool = true) {
        self.isArbitraryPath = !claimPinned
        self.table = testTable
        self.bindingFailure = bindingFailure
    }

    /// *** WHETHER THE ENGINE IS ACTUALLY THE PINNED ONE -- ASKED OF THE BIND, NOT OF A CONSTANT. ***
    ///
    /// *This is the property the factory guardeth on, and it is TRUE ONLY WHEN THE LIBRARY LOADED AND EVERY SYMBOL
    /// RESOLVED.* **A `kind` that returned `.pinnedSQLCipher` unconditionally would make every fail-closed arm pass
    /// vacuously -- the factory would proceed to open with no engine and the arms would measure the absence of a file
    /// rather than the presence of a gate.**
    public var isBound: Bool { table != nil }

    /// The binding failure, for an operator or a court that must NAME why the engine is absent.
    public var bindingFailureReason: String? { bindingFailure }

    /// The provider name this engine bound, for a court that must prove a store ran on THIS image's table.
    public var providerName: String? { table?.providerName }

    // ---------------------------------------------------------------- EncryptedStoreEngine

    /// *`.pinnedSQLCipher` ONLY WHEN THE PINNED LIBRARY IS REALLY BOUND, else `.plainSQLite`.*
    /// **The factory refuseth a `.plainSQLite` engine outright ("no plaintext fallback, ever"), so
    /// this single property IS the first fail-closed gate.**
    public var kind: StoreEngineKind { (isBound && !isArbitraryPath) ? .pinnedSQLCipher : .plainSQLite }

    public var supportedCipherVersion: Int { SQLCipherPin.supportedCipherVersion }

    /// *The metadata road: opened, keyed and probed, then CLOSED -- a handle this verb returns is a
    /// description, and a description that owned a live connection would leak it. The OWNED road
    /// below is the one that hands the connection over.*
    public func openForWriting(path: String, dek: StoreDEK) throws -> EncryptedStoreHandle {
        let c = try openKeyedVerified(path: path, dek: dek, create: true)
        _ = c.close()
        return EncryptedStoreHandle(path: path, kind: .pinnedSQLCipher,
                                    encryptedAtRest: true,
                                    cipherVersion: SQLCipherPin.supportedCipherVersion)
    }

    public func reopenRequiringDEK(path: String, dek: StoreDEK) throws -> EncryptedStoreHandle {
        let c = try openKeyedVerified(path: path, dek: dek, create: false)
        _ = c.close()
        return EncryptedStoreHandle(path: path, kind: .pinnedSQLCipher,
                                    encryptedAtRest: true,
                                    cipherVersion: SQLCipherPin.supportedCipherVersion)
    }

    // ---------------------------------------------------------------- OwnedConnectionStoreEngine

    public func openOwnedForWriting(path: String, dek: StoreDEK) throws -> OwnedConnection {
        try openKeyedVerified(path: path, dek: dek, create: true)
    }

    public func reopenOwnedRequiringDEK(path: String, dek: StoreDEK) throws -> OwnedConnection {
        try openKeyedVerified(path: path, dek: dek, create: false)
    }

    // ---------------------------------------------------------------- the one open road

    /// *** OPEN, KEY **BEFORE ANY SCHEMA READ**, PROBE, AND ONLY THEN CLAIM AT-REST. ***
    ///
    /// *THE ORDER IS THE CARD'S OWN STEP: "key application before schema reads".* **A probe issued
    /// before the key would read an UNKEYED header, which for a plain SQLite file succeedeth and for
    /// a keyed one giveth `SQLITE_NOTADB` -- so an engine that probed first would refuse every
    /// genuinely encrypted store and accept every plaintext one. The order is not a style choice.**
    private func openKeyedVerified(path: String, dek: StoreDEK, create: Bool) throws -> OwnedConnection {
        guard let s = table else {
            // *No engine, no store. This throw is the second gate; the factory's `kind` guard is the
            // first, and both exist because either alone could be bypassed by a future caller.*
            throw StoreOpenFault.io(bindingFailure ?? "the SQLCipher engine is not bound")
        }
        if dek.isEmpty { throw StoreOpenFault.wrongKey }   // a store keyed by nothing is not keyed

        var db: OpaquePointer?
        // SQLITE_OPEN_READWRITE = 2, SQLITE_OPEN_CREATE = 4
        let flags: Int32 = create ? (2 | 4) : 2
        let rcOpen = path.withCString { s.openV2($0, &db, flags, nil) }
        // *** AND A **PARTIAL** HANDLE FROM A FAILED OPEN IS CLOSED BEFORE THE THROW. ***
        //
        // *THE DEFECT THIS CLOSES, MEASURED BY READING THE OLD BODY: `sqlite3_open_v2` may return a NONNULL handle
        // even on failure (`SQLITE_CANTOPEN`/`SQLITE_NOTADB`), and the old guard threw on `rcOpen != 0` WITHOUT closing
        // it -- so every failed open leaked a connection. The cleanup below began only AFTER the success guard and
        // therefore could never see this case.* **The partial handle is closed HERE, before the throw, exactly as the
        // card's "close handles on every failure path" requirith.**
        guard rcOpen == 0, let handle = db else {
            if let partial = db { _ = s.closeV2(partial) }
            throw StoreOpenFault.io("sqlite3_open_v2 refused \(path) (rc=\(rcOpen))")
        }
        // *** A HANDLE THAT WAS OPENED IS CLOSED ON EVERY PATH BELOW. *** *"Close handles on every
        // failure path" is on the card's remediation list, and the `defer`-shaped version of it is
        // the only one that cannot be forgotten when a branch is added.*
        var handedOver = false
        defer { if !handedOver { _ = s.closeV2(handle) } }

        // (1) THE KEY, BEFORE ANY SCHEMA READ. *Hex-literal form, so the DEK never enters a string
        // that could be logged or reused: `PRAGMA key = "x'…'"`.*
        try applyKey(s, handle, dek: dek)

        // (2) THE CIPHER PROBE: this must be SQLCipher, not stock SQLite. *Stock SQLite silently
        // ignoreth an unknown `PRAGMA key` and reporteth no cipher version at all -- which is exactly
        // how a plaintext store could otherwise be mistaken for a protected one.*
        guard let version = try scalarText(s, handle, "PRAGMA cipher_version;", label: "cipher_version probe"),
              !version.isEmpty else {
            throw StoreOpenFault.io("PRAGMA cipher_version returned nothing: this library is NOT SQLCipher, "
                + "and a store it opened would be plaintext")
        }
        let major = Int(version.split(separator: ".").first.map(String.init) ?? "") ?? -1
        guard major == SQLCipherPin.supportedCipherVersion else {
            throw StoreOpenFault.cipherVersionMismatch(found: major,
                                                       supported: SQLCipherPin.supportedCipherVersion)
        }

        // (3) THE KEY-ACTUALLY-WORKED PROBE: a schema read that a WRONG key cannot survive.
        // *The probe NORMALISES `SQLITE_NOTADB` to `.wrongKey` in BOTH `prepare` and `step` -- see the helpers.*
        let count = try scalarInt(s, handle, "SELECT count(*) FROM sqlite_master;")

        // (4) ONLY NOW IS AT-REST CLAIMED -- and the claim is made of the connection itself, not of a
        // boolean a caller passed in.
        let lc = ConnectionLifecycle()
        let verified = OwnedVerifiedConnection(rawHandle: handle,
                                               engineKind: .pinnedSQLCipher,
                                               cipherVersion: major,
                                               encryptedAtRest: true,
                                               path: path,
                                               provider: s,
                                               lifecycle: lc)
        _ = count
        handedOver = true
        // *The close handler is `sqlite3_close_v2`, so ownership is explicit and a double close is
        // refused by `OwnedConnection` before it can reach SQLite's undefined behaviour.*
        return OwnedConnection(connection: verified) { h in _ = s.closeV2(h) }
    }

    // ---------------------------------------------------------------- statement helpers

    /// *** THE KEY IS APPLIED WITHOUT EVER ECHOING IT -- AND WITHOUT AN INTERPOLATED SQL STRING IN ANY FAULT. ***
    ///
    /// *THE DEFECT THIS CLOSES, MEASURED: `exec` interpolated the SQL IT WAS GIVEN into its fault message, and for the
    /// key statement that SQL IS `PRAGMA key = "x'<hex DEK>'"` -- so a wrong-key refusal wrote the DATABASE KEY into an
    /// error string (and, on this isle, into whatever logs it).* **The repair takes a NON-SECRET OPERATION LABEL plus
    /// the NUMERIC result code, and never the SQL or the engine text; the DEK is never placed in a value this file
    /// formats.** *No retry and no plaintext fallback is introduced -- the refusal stays a refusal.*
    private func applyKey(_ s: SQLiteFunctionTable, _ db: OpaquePointer, dek: StoreDEK) throws {
        let sql = "PRAGMA key = \"x'\(hex(dek.bytes))'\";"
        var stmt: OpaquePointer?
        let rc = sql.withCString { s.prepareV2(db, $0, -1, &stmt, nil) }
        defer { if let stmt { _ = s.finalize(stmt) } }
        guard rc == 0, let stmt else {
            // *The label is non-secret and the code is numeric: neither can carry the DEK.*
            throw StoreOpenFault.io("apply-key prepare failed (rc=\(rc))")
        }
        let stepRC = s.step(stmt)
        guard stepRC == 101 || stepRC == 100 else {
            throw StoreOpenFault.io("apply-key step failed (rc=\(stepRC))")
        }
    }

    /// A NON-KEY statement, executed. *Its SQL is a fixed literal owned by this file (BEGIN/COMMIT/PRAGMA
    /// user_version), so naming it is not a key-leak risk -- but the shape below still passeth a LABEL rather than
    /// interpolating freely, so a future caller cannot route the key road through it.*
    private func exec(_ s: SQLiteFunctionTable, _ db: OpaquePointer, _ sql: String) throws {
        var stmt: OpaquePointer?
        let rc = sql.withCString { s.prepareV2(db, $0, -1, &stmt, nil) }
        defer { if let stmt { _ = s.finalize(stmt) } }
        guard rc == 0, let stmt else {
            throw StoreOpenFault.io("could not prepare a fixed statement (rc=\(rc))")
        }
        let stepRC = s.step(stmt)
        // *** SQLITE_DONE(101)/SQLITE_ROW(100) ARE SUCCESS; **0 IS *NOT*.** ***
        // *The old comment said "SQLITE_DONE / SQLITE_ROW" while accepting `0` -- and `SQLITE_OK(0)` is never a
        // successful `step` result, so accepting it would have silently passed a statement that never ran.*
        guard stepRC == 101 || stepRC == 100 else {
            throw StoreOpenFault.io("could not execute a fixed statement (rc=\(stepRC))")
        }
    }

    private func scalarText(_ s: SQLiteFunctionTable, _ db: OpaquePointer, _ sql: String,
                            label: String = "scalar read") throws -> String? {
        var stmt: OpaquePointer?
        let rc = sql.withCString { s.prepareV2(db, $0, -1, &stmt, nil) }
        defer { if let stmt { _ = s.finalize(stmt) } }
        guard rc == 0, let stmt else {
            // *** `SQLITE_NOTADB` AT **PREPARE** IS NORMALISED TOO -- a wrong key on a keyed file can refuse here
            // as well as at `step`, and the old road reported a generic IO fault for it. ***
            if rc == 26 { throw StoreOpenFault.wrongKey }
            throw StoreOpenFault.io("\(label): prepare failed (rc=\(rc))")
        }
        let stepRC = s.step(stmt)
        guard stepRC == 100 else {                            // SQLITE_ROW
            if stepRC == 26 { throw StoreOpenFault.wrongKey } // SQLITE_NOTADB
            // *** THE LABEL NAMES THE PROBE, SO A LIBRARY THAT ANSWERETH `DONE` WITH NO ROWS IS DIAGNOSABLE. ***
            // *Stock SQLite silently ignoreth an unknown `PRAGMA key` and answereth `PRAGMA cipher_version` with DONE
            // and zero rows -- which is EXACTLY the plaintext-library case -- so the fault must say WHICH probe it was
            // rather than printing a bare result code.*
            throw StoreOpenFault.io("\(label) answered rc=\(stepRC) with no row: this library is NOT SQLCipher")
        }
        guard let text = s.columnText(stmt, 0) else { return nil }
        return String(cString: text)
    }

    private func scalarInt(_ s: SQLiteFunctionTable, _ db: OpaquePointer, _ sql: String) throws -> Int32 {
        var stmt: OpaquePointer?
        let rc = sql.withCString { s.prepareV2(db, $0, -1, &stmt, nil) }
        defer { if let stmt { _ = s.finalize(stmt) } }
        guard rc == 0, let stmt else {
            if rc == 26 { throw StoreOpenFault.wrongKey }     // SQLITE_NOTADB at prepare
            throw StoreOpenFault.io("prepare failed (rc=\(rc))")
        }
        let stepRC = s.step(stmt)
        guard stepRC == 100 else {
            if stepRC == 26 { throw StoreOpenFault.wrongKey } // SQLITE_NOTADB: the key did not decrypt
            throw StoreOpenFault.io("statement answered rc=\(stepRC)")
        }
        return s.columnInt(stmt, 0)
    }

    /// **REDACTED, AND DELIBERATELY SO.** *The engine's own message is NOT returned, because SQLCipher's messages can
    /// quote the offending SQL -- and for the key road that SQL is the DEK. Kept for the call sites that only need a
    /// non-key diagnostic; the key road above does not use it.*
    private func err(_ s: SQLiteFunctionTable, _ db: OpaquePointer) -> String {
        _ = s.errmsg(db)
        return "engine error (message redacted: it may quote the key-bearing statement)"
    }

    private func hex(_ data: Data) -> String {
        var out = String(); out.reserveCapacity(data.count * 2)
        for b in data { out += String(format: "%02x", b) }
        return out
    }
}
