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

/// *** THE COMPLETE SQLITE SURFACE BOTH PRIVATE STORES USE, BOUND FROM ONE IMAGE. ***
///
/// *Every entry point is listed EXPLICITLY, so the surface is auditable at a glance and an unlisted function cannot
/// be reached: the two stores' sources are checked against this set by `ReadinessT30Tests`' provider-dispatch arms.*
/// **The signatures are the C ones, so a call site readeth identically whether it nameth the global symbol or the
/// table entry -- which is what let the cutover be mechanical rather than a rewrite.**
public struct SQLiteFunctionTable: @unchecked Sendable {

    // --- connection ---------------------------------------------------------------------------
    public let openV2: @convention(c) (UnsafePointer<CChar>?, UnsafeMutablePointer<OpaquePointer?>?, Int32,
                                       UnsafePointer<CChar>?) -> Int32
    public let closeV2: @convention(c) (OpaquePointer?) -> Int32
    public let busyTimeout: @convention(c) (OpaquePointer?, Int32) -> Int32
    public let exec: @convention(c) (OpaquePointer?, UnsafePointer<CChar>?,
                                     (@convention(c) (UnsafeMutableRawPointer?, Int32,
                                                      UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
                                                      UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32)?,
                                     UnsafeMutableRawPointer?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32
    public let changes: @convention(c) (OpaquePointer?) -> Int32
    public let errmsg: @convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?

    // --- statements ---------------------------------------------------------------------------
    public let prepareV2: @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, Int32,
                                          UnsafeMutablePointer<OpaquePointer?>?,
                                          UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> Int32
    public let step: @convention(c) (OpaquePointer?) -> Int32
    public let finalize: @convention(c) (OpaquePointer?) -> Int32

    // --- binding ------------------------------------------------------------------------------
    public let bindBlob: @convention(c) (OpaquePointer?, Int32, UnsafeRawPointer?, Int32,
                                         (@convention(c) (UnsafeMutableRawPointer?) -> Void)?) -> Int32
    public let bindInt: @convention(c) (OpaquePointer?, Int32, Int32) -> Int32
    public let bindInt64: @convention(c) (OpaquePointer?, Int32, Int64) -> Int32
    public let bindNull: @convention(c) (OpaquePointer?, Int32) -> Int32
    public let bindText: @convention(c) (OpaquePointer?, Int32, UnsafePointer<CChar>?, Int32,
                                         (@convention(c) (UnsafeMutableRawPointer?) -> Void)?) -> Int32

    // --- columns ------------------------------------------------------------------------------
    public let columnBlob: @convention(c) (OpaquePointer?, Int32) -> UnsafeRawPointer?
    public let columnBytes: @convention(c) (OpaquePointer?, Int32) -> Int32
    public let columnInt: @convention(c) (OpaquePointer?, Int32) -> Int32
    public let columnInt64: @convention(c) (OpaquePointer?, Int32) -> Int64
    public let columnText: @convention(c) (OpaquePointer?, Int32) -> UnsafePointer<UInt8>?
    public let columnType: @convention(c) (OpaquePointer?, Int32) -> Int32

    /// The human-readable name of the image this table was bound from, for an operator or a court.
    public let providerName: String

    /// *** THE TABLE OVER THE **STATICALLY LINKED** SQLITE3 -- the archive-only / legacy provider. ***
    ///
    /// *This is the provider for a store that opened its own connection through the globally linked Apple SQLite:
    /// there the handle and the functions come from the SAME image, so the table is consistent by construction.*
    /// **It is deliberately NAMED as the plain provider rather than left implicit, so a composition that runs it is
    /// visibly the plaintext/archive road rather than the pinned-engine one.**
    public static let linkedPlatform = SQLiteFunctionTable(
        providerName: "platform-sqlite3 (statically linked)",
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
                              providerName: String) -> SQLiteFunctionTable? {
        func sym<T>(_ name: String, _ type: T.Type) -> T? {
            guard let p = dlsym(handle, name) else { return nil }
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
            providerName: providerName, openV2: openV2, closeV2: closeV2, busyTimeout: busyTimeout, exec: exec,
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
