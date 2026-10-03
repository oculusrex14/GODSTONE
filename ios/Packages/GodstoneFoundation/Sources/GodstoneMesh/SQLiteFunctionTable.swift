import Foundation
import SQLite3

//  ================================================================================================
//  GS-FINAL-004 (`provider-dispatch`): *** ONE IMMUTABLE SQLITE FUNCTION TABLE PER PROVIDER. ***
//
//  *** THE DEFECT THIS CLOSES, MEASURED BY READING THE TREE RATHER THAN REASONING ABOUT IT. ***
//
//  `SqlCipherDylibEngine` obtaineth its SQLite handles by `dlsym` on a library it loaded itself, so those handles
//  belong to THAT image's allocator, VFS, mutexes and `sqlite3` struct layout. **AND THEN
//  `SqliteMessageStore.init(verifiedConnection:)` AND `SqlitePeerIdentityStore.init(verifiedConnection:)` CALL THE
//  GLOBALLY LINKED `sqlite3_*` FUNCTIONS ON THEM** -- `sqlite3_busy_timeout`, `sqlite3_exec`, `sqlite3_prepare_v2`,
//  `sqlite3_step`, `sqlite3_finalize`, `sqlite3_changes`, the whole bind/column family, and `sqlite3_close_v2`.
//
//  *A POINTER CREATED BY ONE SQLITE IMPLEMENTATION MUST NOT BE PASSED TO ANOTHER.* **Matching pointer identity, or a
//  matching SQLite major version, doth NOT establish provider compatibility: two builds of the same version can carry
//  different compile options (`SQLITE_THREADSAFE`, `SQLITE_ENABLE_*`), different struct layouts and different
//  `sqlite3_int64`/VFS assumptions -- and the failure that followeth is a silent corruption, not a clean refusal.**
//
//  **SO THIS FILE INTRODUCES THE MISSING ABSTRACTION: A TABLE OF FUNCTION POINTERS, BOUND ONCE PER PROVIDER FROM
//  THE IMAGE THE HANDLE CAME FROM.** *A store that adopteth an engine's connection carrieth that engine's table and
//  calls through it; a legacy `url:` store carrieth the table over the statically linked SQLite3 functions. No raw
//  handle ever crosses an implementation boundary through a global symbol again.*
//
//  *** WHY A STRUCT OF FUNCTION POINTERS AND NOT A GLOBAL RAW-POINTER -> PROVIDER MAP. *** *A global map keyed by the
//  handle is mutable shared state reached from every query, and it can be silently wrong (a recycled pointer would
//  answer with the DEAD provider's table). A table carried BY VALUE with the connection cannot be wrong: the store
//  either holds the table or it holds nothing.*
//  ================================================================================================

/// *** THE UNLOADABLE-IMAGE LEASE: THE `dlopen` HANDLE, KEPT ALIVE BY **ARC** AND UNLOADED EXACTLY ONCE. ***
///
/// *SQLITE-REVIEW-1 / SQLITE-LATEST-C2, MEASURED: the image's lifetime was governed by a MANUAL `references` counter,
/// while the function table held the lease by STRONG REFERENCE. Ordinary struct copies therefore did NOT increment the
/// counter, so an escaped `provider`/connection copy could outlive a manually-released reference and dispatch into an
/// UNLOADED image -- and every manual `retain`/`release` pair was a lifetime bug waiting to happen.*
///
/// **SO THE MANUAL COUNTER IS GONE. THE LEASE'S LIFETIME IS ITS ARC LIFETIME:** *every function-table value and every
/// class that means to keep the image (the engine, each `OwnedConnection`, each adopting store) holds this object
/// STRONGLY, so the object lives until the LAST of them falls -- and `deinit` (plus the owner's explicit
/// `unloadIfNeeded`) `dlclose`es it exactly once, only when no user remains.* **A value copy of the table keeps the
/// lease alive exactly as long as the copy does, which is the invariant the counter was trying (and failing) to
/// approximate.***
internal final class SQLiteImageLease: @unchecked Sendable {
    private let handle: UnsafeMutableRawPointer
    /// *** THE PRIVATE SNAPSHOT'S **ROOT DIRECTORY**, REMOVED ON UNLOAD -- AND **NEVER THE ORIGINAL ARTIFACT'S**. ***
    ///
    /// *When the image was bound from an exclusively-created, byte-verified private copy (see `SqlCipherDylibEngine`),
    /// that copy's name is `unlink`ed right after the load and only this root remaineth. Cleanup deleteth ONLY the copy
    /// this lease created; the original image's path is never touched, deleted or mutated. `nil` when the load did not
    /// create a copy (a bundle-resident/signed load).*
    private let snapshotRoot: String?
    private let lock = NSLock()
    private var unloaded = false

    internal init(handle: UnsafeMutableRawPointer, snapshotRoot: String? = nil) {
        self.handle = handle
        self.snapshotRoot = snapshotRoot
    }

    /// Unload the image exactly once. *Called by the OWNER's `deinit` (which also holds the lease strongly) and by this
    /// object's own `deinit`; idempotent, so the image is `dlclose`d precisely once and never while a user remains.*
    /// **The same single pass removeth the private root, so no failure path can leak the copy and no cleanup can reach
    /// the original artifact.**
    private func unloadIfNeeded() {
        lock.lock(); defer { lock.unlock() }
        guard !unloaded else { return }
        unloaded = true
        dlclose(handle)
        if let snapshotRoot { try? FileManager.default.removeItem(atPath: snapshotRoot) }
    }

    deinit { unloadIfNeeded() }

    /// For a court: whether the image has been unloaded. *A witness that the last user's fall is what unloads it.*
    internal var isUnloadedForTest: Bool { lock.lock(); defer { lock.unlock() }; return unloaded }
}

/// *** THE SUPPLIED-ARTIFACT DESCRIPTOR: WHAT THE RUNTIME IMAGE MUST BE, BEFORE IT IS LOADED. ***
///
/// *SQLITE-REVIEW-5, MEASURED: the public constructor accepted ANY `libraryPath` or bare filename, complete symbol
/// binding established only AVAILABILITY, and cipher major 4 established only a MAJOR GENERATION -- so an unapproved
/// SQLCipher-4 image could be labelled `.pinnedSQLCipher` and publish owners indistinguishable from the approved
/// supply.*
///
/// **SO THE PIN IS CONSUMED RATHER THAN MERELY NAMED.** *`SqlCipherDylibEngine`'s production initializer resolves one
/// of these beside the library, verifies the loaded image against the digest/platform/architecture/cipher-major/source
/// fields, and only then loads it. A missing or mismatching descriptor is a TYPED UNAVAILABLE, never a silent load of
/// whatever the search path happened to find.* **The arbitrary-path/function-table injection initializers remain
/// INTERNAL so a court can drive the adapter; they are not the production road.**
public struct SQLCipherArtifactDescriptor: Equatable, Sendable, Codable {
    /// The leaf name the loader expects (`libsqlcipher.0.dylib`).
    public let libraryName: String
    /// The source repository the image was built from, and the exact content-addressed commit (the authority).
    public let sourceRepo: String
    public let sourceCommit: String
    public let sourceTag: String
    /// The cipher major the descriptor's source provides. *Checked against `SqlCipherDylibEngine.supportedCipherVersion`.*
    public let cipherVersionMajor: Int
    /// The platform the bytes are FOR ("MACOS"/"IOSSIMULATOR") and the architecture ("arm64"). *A macOS process must
    /// not dlopen an IOSSIMULATOR image and vice versa -- the same separation the build script stages separately.*
    public let platform: String
    public let arch: String
    /// The RECORDED sha256 of the built dylib, the cross-check applied to the bytes actually loaded.
    public let sha256: String
    /// The recorded byte count, a second cheap cross-check.
    public let bytes: Int

    public init(libraryName: String, sourceRepo: String, sourceCommit: String, sourceTag: String,
                cipherVersionMajor: Int, platform: String, arch: String, sha256: String, bytes: Int) {
        self.libraryName = libraryName
        self.sourceRepo = sourceRepo
        self.sourceCommit = sourceCommit
        self.sourceTag = sourceTag
        self.cipherVersionMajor = cipherVersionMajor
        self.platform = platform
        self.arch = arch
        self.sha256 = sha256
        self.bytes = bytes
    }

    /// The sidecar filename the builder-emitted descriptor is expected to carry, beside the staged library.
    public static func sidecarName(forLibrary libraryName: String) -> String { libraryName + ".artifact.json" }
}

/// *** THE COMPLETE SQLITE SURFACE BOTH PRIVATE STORES USE, BOUND FROM ONE IMAGE. ***
///
/// *Every entry point is listed EXPLICITLY, so the surface is auditable at a glance and an unlisted function cannot
/// be reached: the two stores' sources are checked against this set by `ReadinessT30Tests`' provider-dispatch arms.*
/// **The signatures are the C ones, so a call site readeth identically whether it nameth the global symbol or the
/// table entry -- which is what let the cutover be mechanical rather than a rewrite.**
public struct SQLiteFunctionTable: @unchecked Sendable {

    // --- connection ---------------------------------------------------------------------------
    internal let openV2: @convention(c) (UnsafePointer<CChar>?, UnsafeMutablePointer<OpaquePointer?>?, Int32, UnsafePointer<CChar>?) -> Int32
    internal let closeV2: @convention(c) (OpaquePointer?) -> Int32
    internal let busyTimeout: @convention(c) (OpaquePointer?, Int32) -> Int32
    internal let exec: @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, (@convention(c) (UnsafeMutableRawPointer?, Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32)?, UnsafeMutableRawPointer?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32
    internal let changes: @convention(c) (OpaquePointer?) -> Int32
    internal let errmsg: @convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?
    internal let prepareV2: @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, Int32, UnsafeMutablePointer<OpaquePointer?>?, UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> Int32
    internal let step: @convention(c) (OpaquePointer?) -> Int32
    internal let finalize: @convention(c) (OpaquePointer?) -> Int32
    internal let bindBlob: @convention(c) (OpaquePointer?, Int32, UnsafeRawPointer?, Int32, (@convention(c) (UnsafeMutableRawPointer?) -> Void)?) -> Int32
    internal let bindInt: @convention(c) (OpaquePointer?, Int32, Int32) -> Int32
    internal let bindInt64: @convention(c) (OpaquePointer?, Int32, Int64) -> Int32
    internal let bindNull: @convention(c) (OpaquePointer?, Int32) -> Int32
    internal let bindText: @convention(c) (OpaquePointer?, Int32, UnsafePointer<CChar>?, Int32, (@convention(c) (UnsafeMutableRawPointer?) -> Void)?) -> Int32
    internal let columnBlob: @convention(c) (OpaquePointer?, Int32) -> UnsafeRawPointer?
    internal let columnBytes: @convention(c) (OpaquePointer?, Int32) -> Int32
    internal let columnInt: @convention(c) (OpaquePointer?, Int32) -> Int32
    internal let columnInt64: @convention(c) (OpaquePointer?, Int32) -> Int64
    internal let columnText: @convention(c) (OpaquePointer?, Int32) -> UnsafePointer<UInt8>?
    internal let columnType: @convention(c) (OpaquePointer?, Int32) -> Int32

    /// The human-readable name of the image this table was bound from, for an operator or a court.
    public let providerName: String

    /// *** THE IMAGE LEASE THIS TABLE'S POINTERS ARE ONLY VALID INSIDE -- `nil` FOR THE STATICALLY LINKED TABLE. ***
    ///
    /// *A `struct` cannot release an unloadable image when its last copy dieth, so the lease is released by the CLASS
    /// owners that hold it: the engine, the owned connection, and each adopting store. `linkedPlatform` carrieth
    /// `nil`: its functions ARE the process image and cannot be unloaded.*
    internal let lease: SQLiteImageLease?

    /// *** THE TABLE OVER THE **STATICALLY LINKED** SQLITE3 -- the archive-only / legacy provider. ***
    ///
    /// *This is the provider for a store that opened its own connection through the globally linked Apple SQLite:
    /// there the handle and the functions come from the SAME image, so the table is consistent by construction.*
    /// **It is deliberately NAMED as the plain provider rather than left implicit, so a composition that runs it is
    /// visibly the plaintext/archive road rather than the pinned-engine one.**
    public static let linkedPlatform = SQLiteFunctionTable(
        providerName: "platform-sqlite3 (statically linked)",
        lease: nil,
        openV2: sqlite3_open_v2,
        closeV2: sqlite3_close_v2,
        busyTimeout: sqlite3_busy_timeout,
        exec: sqlite3_exec,
        changes: sqlite3_changes,
        errmsg: sqlite3_errmsg,
        prepareV2: sqlite3_prepare_v2,
        step: sqlite3_step,
        finalize: sqlite3_finalize,
        bindBlob: sqlite3_bind_blob,
        bindInt: sqlite3_bind_int,
        bindInt64: sqlite3_bind_int64,
        bindNull: sqlite3_bind_null,
        bindText: sqlite3_bind_text,
        columnBlob: sqlite3_column_blob,
        columnBytes: sqlite3_column_bytes,
        columnInt: sqlite3_column_int,
        columnInt64: sqlite3_column_int64,
        columnText: sqlite3_column_text,
        columnType: sqlite3_column_type)

    /// *** AND THE COMPLETE REQUIRED SYMBOL SET, AS NAMES, SO A LOADED IMAGE CAN BE BOUND IN FULL OR REFUSED IN FULL. ***
    ///
    /// *A partially bound table would call a garbage function pointer -- a crash, not a refusal.* **So the binding
    /// below is ALL-OR-NOTHING, and these names are the single list both the table and its court agree on.**
    public static let requiredSymbols: [String] = [
        "sqlite3_open_v2", "sqlite3_close_v2", "sqlite3_busy_timeout", "sqlite3_exec", "sqlite3_changes",
        "sqlite3_errmsg", "sqlite3_prepare_v2", "sqlite3_step", "sqlite3_finalize",
        "sqlite3_bind_blob", "sqlite3_bind_int", "sqlite3_bind_int64", "sqlite3_bind_null", "sqlite3_bind_text",
        "sqlite3_column_blob", "sqlite3_column_bytes", "sqlite3_column_int", "sqlite3_column_int64",
        "sqlite3_column_text", "sqlite3_column_type",
    ]

    internal init(providerName: String,
                 lease: SQLiteImageLease? = nil,
                 openV2: @escaping @convention(c) (UnsafePointer<CChar>?, UnsafeMutablePointer<OpaquePointer?>?,
                                                  Int32, UnsafePointer<CChar>?) -> Int32,
                 closeV2: @escaping @convention(c) (OpaquePointer?) -> Int32,
                 busyTimeout: @escaping @convention(c) (OpaquePointer?, Int32) -> Int32,
                 exec: @escaping @convention(c) (OpaquePointer?, UnsafePointer<CChar>?,
                                                 (@convention(c) (UnsafeMutableRawPointer?, Int32,
                                                                  UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
                                                                  UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32)?,
                                                 UnsafeMutableRawPointer?,
                                                 UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32,
                 changes: @escaping @convention(c) (OpaquePointer?) -> Int32,
                 errmsg: @escaping @convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?,
                 prepareV2: @escaping @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, Int32,
                                                      UnsafeMutablePointer<OpaquePointer?>?,
                                                      UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> Int32,
                 step: @escaping @convention(c) (OpaquePointer?) -> Int32,
                 finalize: @escaping @convention(c) (OpaquePointer?) -> Int32,
                 bindBlob: @escaping @convention(c) (OpaquePointer?, Int32, UnsafeRawPointer?, Int32,
                                                     (@convention(c) (UnsafeMutableRawPointer?) -> Void)?) -> Int32,
                 bindInt: @escaping @convention(c) (OpaquePointer?, Int32, Int32) -> Int32,
                 bindInt64: @escaping @convention(c) (OpaquePointer?, Int32, Int64) -> Int32,
                 bindNull: @escaping @convention(c) (OpaquePointer?, Int32) -> Int32,
                 bindText: @escaping @convention(c) (OpaquePointer?, Int32, UnsafePointer<CChar>?, Int32,
                                                     (@convention(c) (UnsafeMutableRawPointer?) -> Void)?) -> Int32,
                 columnBlob: @escaping @convention(c) (OpaquePointer?, Int32) -> UnsafeRawPointer?,
                 columnBytes: @escaping @convention(c) (OpaquePointer?, Int32) -> Int32,
                 columnInt: @escaping @convention(c) (OpaquePointer?, Int32) -> Int32,
                 columnInt64: @escaping @convention(c) (OpaquePointer?, Int32) -> Int64,
                 columnText: @escaping @convention(c) (OpaquePointer?, Int32) -> UnsafePointer<UInt8>?,
                 columnType: @escaping @convention(c) (OpaquePointer?, Int32) -> Int32) {
        self.providerName = providerName
        self.lease = lease
        self.openV2 = openV2
        self.closeV2 = closeV2
        self.busyTimeout = busyTimeout
        self.exec = exec
        self.changes = changes
        self.errmsg = errmsg
        self.prepareV2 = prepareV2
        self.step = step
        self.finalize = finalize
        self.bindBlob = bindBlob
        self.bindInt = bindInt
        self.bindInt64 = bindInt64
        self.bindNull = bindNull
        self.bindText = bindText
        self.columnBlob = columnBlob
        self.columnBytes = columnBytes
        self.columnInt = columnInt
        self.columnInt64 = columnInt64
        self.columnText = columnText
        self.columnType = columnType
    }

    /// *** BIND THE COMPLETE TABLE FROM ONE LOADED IMAGE, OR FAIL AS A WHOLE. ***
    ///
    /// *`dlsym` per symbol, and if ANY required name is absent the binding is REFUSED -- returning `nil` so the caller
    /// can report a typed refusal rather than carry a table with holes in it.* **The caller keeps the `dlopen` handle
    /// alive for as long as the table is used (see `SqlCipherDylibEngine`), because these pointers are only valid while
    /// the image remaineth loaded.**
    internal static func bind(fromImage handle: UnsafeMutableRawPointer,
                              providerName: String,
                              lease: SQLiteImageLease? = nil,
                              imagePath: String? = nil) -> SQLiteFunctionTable? {
        let expectedPath = imagePath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path }
        var imageBase: UnsafeMutableRawPointer?
        func sym<T>(_ name: String, _ type: T.Type) -> T? {
            guard let p = dlsym(handle, name) else { return nil }
            var origin = Dl_info()
            guard dladdr(p, &origin) != 0, let filename = origin.dli_fname, let base = origin.dli_fbase else { return nil }
            if let expectedPath {
                let actualPath = URL(fileURLWithPath: String(cString: filename)).resolvingSymlinksInPath().standardizedFileURL.path
                guard actualPath == expectedPath else { return nil }
            }
            if let imageBase { guard base == imageBase else { return nil } }
            else { imageBase = base }
            return unsafeBitCast(p, to: T.self)
        }
        guard let openV2 = sym("sqlite3_open_v2", OpenV2Fn.self),
              let closeV2 = sym("sqlite3_close_v2", CloseV2Fn.self),
              let busyTimeout = sym("sqlite3_busy_timeout", BusyTimeoutFn.self),
              let exec = sym("sqlite3_exec", ExecFn.self),
              let changes = sym("sqlite3_changes", ChangesFn.self),
              let errmsg = sym("sqlite3_errmsg", ErrmsgFn.self),
              let prepareV2 = sym("sqlite3_prepare_v2", PrepareV2Fn.self),
              let step = sym("sqlite3_step", StepFn.self),
              let finalize = sym("sqlite3_finalize", FinalizeFn.self),
              let bindBlob = sym("sqlite3_bind_blob", BindBlobFn.self),
              let bindInt = sym("sqlite3_bind_int", BindIntFn.self),
              let bindInt64 = sym("sqlite3_bind_int64", BindInt64Fn.self),
              let bindNull = sym("sqlite3_bind_null", BindNullFn.self),
              let bindText = sym("sqlite3_bind_text", BindTextFn.self),
              let columnBlob = sym("sqlite3_column_blob", ColumnBlobFn.self),
              let columnBytes = sym("sqlite3_column_bytes", ColumnBytesFn.self),
              let columnInt = sym("sqlite3_column_int", ColumnIntFn.self),
              let columnInt64 = sym("sqlite3_column_int64", ColumnInt64Fn.self),
              let columnText = sym("sqlite3_column_text", ColumnTextFn.self),
              let columnType = sym("sqlite3_column_type", ColumnTypeFn.self)
        else { return nil }
        return SQLiteFunctionTable(
            providerName: providerName, lease: lease,
            openV2: openV2, closeV2: closeV2, busyTimeout: busyTimeout, exec: exec,
            changes: changes, errmsg: errmsg, prepareV2: prepareV2, step: step, finalize: finalize,
            bindBlob: bindBlob, bindInt: bindInt, bindInt64: bindInt64, bindNull: bindNull, bindText: bindText,
            columnBlob: columnBlob, columnBytes: columnBytes, columnInt: columnInt, columnInt64: columnInt64,
            columnText: columnText, columnType: columnType)
    }
}

//: The named function types, so `bind(fromImage:)` can `unsafeBitCast` each symbol to the right shape without
//: restating twenty `@convention(c)` signatures at the call site.
internal typealias OpenV2Fn = @convention(c) (UnsafePointer<CChar>?, UnsafeMutablePointer<OpaquePointer?>?,
                                              Int32, UnsafePointer<CChar>?) -> Int32
internal typealias CloseV2Fn = @convention(c) (OpaquePointer?) -> Int32
internal typealias BusyTimeoutFn = @convention(c) (OpaquePointer?, Int32) -> Int32
internal typealias ExecFn = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?,
                                            (@convention(c) (UnsafeMutableRawPointer?, Int32,
                                                             UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
                                                             UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32)?,
                                            UnsafeMutableRawPointer?,
                                            UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32
internal typealias ChangesFn = @convention(c) (OpaquePointer?) -> Int32
internal typealias ErrmsgFn = @convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?
internal typealias PrepareV2Fn = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, Int32,
                                                 UnsafeMutablePointer<OpaquePointer?>?,
                                                 UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> Int32
internal typealias StepFn = @convention(c) (OpaquePointer?) -> Int32
internal typealias FinalizeFn = @convention(c) (OpaquePointer?) -> Int32
internal typealias BindBlobFn = @convention(c) (OpaquePointer?, Int32, UnsafeRawPointer?, Int32,
                                                (@convention(c) (UnsafeMutableRawPointer?) -> Void)?) -> Int32
internal typealias BindIntFn = @convention(c) (OpaquePointer?, Int32, Int32) -> Int32
internal typealias BindInt64Fn = @convention(c) (OpaquePointer?, Int32, Int64) -> Int32
internal typealias BindNullFn = @convention(c) (OpaquePointer?, Int32) -> Int32
internal typealias BindTextFn = @convention(c) (OpaquePointer?, Int32, UnsafePointer<CChar>?, Int32,
                                                (@convention(c) (UnsafeMutableRawPointer?) -> Void)?) -> Int32
internal typealias ColumnBlobFn = @convention(c) (OpaquePointer?, Int32) -> UnsafeRawPointer?
internal typealias ColumnBytesFn = @convention(c) (OpaquePointer?, Int32) -> Int32
internal typealias ColumnIntFn = @convention(c) (OpaquePointer?, Int32) -> Int32
internal typealias ColumnInt64Fn = @convention(c) (OpaquePointer?, Int32) -> Int64
internal typealias ColumnTextFn = @convention(c) (OpaquePointer?, Int32) -> UnsafePointer<UInt8>?
internal typealias ColumnTypeFn = @convention(c) (OpaquePointer?, Int32) -> Int32
