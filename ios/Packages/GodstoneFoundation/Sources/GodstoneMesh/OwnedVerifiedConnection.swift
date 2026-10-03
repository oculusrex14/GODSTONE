import Foundation

//  GS-FINAL-004: THE OWNED VERIFIED CONNECTION -- WHAT THE ENGINE ACTUALLY HANDS OVER.
//
//  *** THE AUDIT'S CHARGE, QUOTED: ***
//
//      "the connection verified by the approved encrypted-store engine is NOT the connection used
//      by the repository."
//
//  MEASURED, IN THE PRIVATE COMPOSITION, BEFORE THIS FILE:
//
//      switch factory.reopenExisting(path: url.path, tag: tag) {
//      case .available(let handle):
//          guard handle.encryptedAtRest else { throw ... }     // verified...
//      }
//      let messageStore = SqliteMessageStore(url: messageStoreUrl, ...)   // ...then DISCARDED
//
//  `SqliteMessageStore(url:)` calls `sqlite3_open_v2` itself, so the repository ran on a SECOND,
//  INDEPENDENT connection that no engine ever keyed or verified. Everything the factory proved was
//  about a handle that nobody then used.
//
//  AND THE DEFECT IS NOT ABOUT SQLCIPHER'S AVAILABILITY. It holds with the engine absent, because
//  the SHAPE is wrong: descriptive metadata cannot be operated on, so a composition holding only
//  metadata has no choice but to open its own connection. *That is why the internal half of
//  GS-STORE-002 is completable now and the native half is not.*
//
//  SO THE ABSTRACTION CHANGES: the engine yields an OWNED OPERATIONAL CONNECTION, not a
//  description of one.
//
//  *** WHY AN `OpaquePointer` AND NOT A WRAPPER THE STORE COULD IGNORE. *** *The repository's
//  stores already run on `OpaquePointer` -- `SqliteMessageStore` holds one. That makes this an
//  ACTUAL HANDOVER rather than a parallel abstraction the private path could quietly bypass: the
//  store either receives a connection from the engine or opens one itself, and those two roads are
//  now type-distinguishable at the call site.*
//
//  *** WHAT IS DELIBERATELY NOT HERE. *** *No Boolean such as `messageStoreWasBuiltFromVerifiedHandle`.
//  The audit named that specific shape as forbidden, and the reason is general: it ASSERTS the
//  architecture instead of observing it. A store that receives a connection can be asked for the
//  connection it is using, and that answer can be compared BY IDENTITY against what the engine
//  returned -- which is an observation.*

/// *** THE SHARED USE/CLOSE LIFECYCLE: ONE OBJECT PER CONNECTION, HELD BY THE OWNER AND EVERY ADOPTING STORE. ***
///
/// *SQLITE-REVIEW-2, MEASURED: stores retained only `rawHandle` + `provider`, never the owner; their `NSLock`s did not
/// participate in `OwnedConnection.close()`, and no query checked the owner's closed state. A store could dispatch a
/// STALE handle to SQLite after the owner closed it, and a close mid-statement could zombie or free a handle a worker
/// was using.*
///
/// **SO THE CLOSED FLAG, THE ACTIVE-USE COUNT AND THE WAIT SHARE ONE SYNCHRONISATION POINT.** *An operation ADMITTETH
/// itself (refused after close), close MARKS CLOSED (no new admission) then WAITS for the count to drain before it
/// frees the handle, and the wait is exactly-once with the close.* **`NSLock` + `NSCondition` rather than the store's
/// `NSLock` alone, because close must block on other threads' uses, not merely exclude them.**
internal final class ConnectionLifecycle: @unchecked Sendable {
    private let condition = NSCondition()
    private var closed = false
    private var physicallyClosed = false
    private var adoptionRejected = false
    private var activeUsers = 0
    private var threadUses: [ObjectIdentifier: Int] = [:]
    private var pendingClose: (() -> Void)?

    func markAdoptionRejected() {
        condition.lock(); adoptionRejected = true; condition.unlock()
    }

    func beginUse() -> Bool {
        condition.lock(); defer { condition.unlock() }
        guard !closed && !adoptionRejected else { return false }
        activeUsers += 1
        threadUses[ObjectIdentifier(Thread.current), default: 0] += 1
        return true
    }

    func endUse() {
        condition.lock()
        let thread = ObjectIdentifier(Thread.current)
        let remaining = (threadUses[thread] ?? 1) - 1
        if remaining == 0 { threadUses.removeValue(forKey: thread) }
        else { threadUses[thread] = remaining }
        activeUsers -= 1
        let action = activeUsers == 0 ? pendingClose : nil
        if action != nil { pendingClose = nil }
        condition.unlock()
        if let action { finishClose(action) }
    }

    // Close inside any transaction callback must not wait for its own statement.
    // The last admitted use performs deferred cleanup; other threads wait for physical closure.
    func close(_ action: @escaping () -> Void) -> Bool {
        condition.lock()
        let first = !closed
        if first { closed = true; pendingClose = action }
        if threadUses[ObjectIdentifier(Thread.current), default: 0] > 0 {
            condition.unlock()
            return false
        }
        if activeUsers == 0, let pending = pendingClose {
            pendingClose = nil
            condition.unlock()
            finishClose(pending)
            return first
        }
        while !physicallyClosed { condition.wait() }
        condition.unlock()
        return first
    }

    private func finishClose(_ action: () -> Void) {
        action()
        condition.lock(); physicallyClosed = true; condition.broadcast(); condition.unlock()
    }

    var activeUsersForTest: Int { condition.lock(); defer { condition.unlock() }; return activeUsers }
    var isClosed: Bool { condition.lock(); defer { condition.unlock() }; return closed }
    var isPhysicallyClosed: Bool { condition.lock(); defer { condition.unlock() }; return physicallyClosed }
    var isUsable: Bool { condition.lock(); defer { condition.unlock() }; return !closed && !adoptionRejected }
}

/// *** THE VERIFIED, OWNED OPERATIONAL CONNECTION. ***
///
/// Carries the engine's own verdict AND the live database handle, so a consumer cannot possess the
/// proof without also possessing the thing the proof is about.
///
/// CONSTRUCTION IS RESTRICTED TO THE MODULE: the initializer is `internal`, so an engine must be
/// in this module to produce one. *A consumer cannot mint a verified connection by asserting that
/// it has one* -- the same reasoning as `PrivateRuntimePermit` in GS-FINAL-003.
public struct OwnedVerifiedConnection: @unchecked Sendable {
    /// The SQLite handle the ENGINE opened, keyed and verified. This is the connection the
    /// repository must run on; there is no second one.
    public let rawHandle: OpaquePointer

    /// Which engine produced it, so a consumer can refuse an engine it does not accept.
    public let engineKind: StoreEngineKind

    /// The cipher version the engine reported FOR THIS CONNECTION.
    public let cipherVersion: Int

    /// The at-rest verdict the engine reached BEFORE returning this connection.
    public let encryptedAtRest: Bool

    /// The path this connection is bound to, so a mismatch with the requested store is detectable.
    public let path: String

    /// *** THE PROVIDER'S OWN FUNCTION TABLE -- THE IMAGE THIS HANDLE CAME FROM. ***
    ///
    /// *THE DEFECT THIS CLOSES: the handle was created by `SqlCipherDylibEngine`'s `dlsym`-loaded image, and every
    /// adoptING store then called the GLOBALLY LINKED `sqlite3_*` functions on it.* **A pointer created by one SQLite
    /// implementation must not be passed to another -- so the table travelleth WITH the connection, and a store that
    /// adopteth one carrieth the table and calls through it.** *A legacy `url:` store carrieth
    /// `SQLiteFunctionTable.linkedPlatform`, where the handle and the functions come from the same image by
    /// construction.*
    public let provider: SQLiteFunctionTable

    /// *** THE SHARED CLOSE/USE LIFECYCLE -- THE OWNER'S OWN OBJECT, ALSO HELD BY EVERY ADOPTING STORE. ***
    /// *SQLITE-REVIEW-2: a store must be able to admit itself against the SAME closed flag the owner's `close()` sets.*
    internal let lifecycle: ConnectionLifecycle?

    /// *** THE OWNER, WHEN ONE WAS HANDED OVER -- SO A STORE CAN CHECK "CLOSED?" AND TAKE A USE REFERENCE. ***
    /// *Held WEAK: the owner owns the connection; the connection must not keep the owner alive, or a close order that
    /// dropped the owner would never release the handle. `nil` for a connection an engine minted without a wrapper.*
    internal weak var owner: OwnedConnection?

    /// *** INTERNAL ON PURPOSE: AN ENGINE, NOT A CALLER, MINTS ONE OF THESE. ***
    ///
    /// *The IMAGE LEASE is deliberately NOT a field here: an `OwnedVerifiedConnection` is a `struct`, and a `struct`
    /// cannot release an unloadable image when its last copy dieth. **The lease is owned by the CLASS owners instead --
    /// the engine, the `OwnedConnection` wrapper, and each adopting store** -- which is where a `deinit` existeth to
    /// release it.*
    internal init(rawHandle: OpaquePointer, engineKind: StoreEngineKind,
                  cipherVersion: Int, encryptedAtRest: Bool, path: String,
                  provider: SQLiteFunctionTable = .linkedPlatform,
                  lifecycle: ConnectionLifecycle? = nil) {
        self.rawHandle = rawHandle
        self.engineKind = engineKind
        self.cipherVersion = cipherVersion
        self.encryptedAtRest = encryptedAtRest
        self.path = path
        self.provider = provider
        self.lifecycle = lifecycle
    }

    /// Identity of the CONNECTION ITSELF, for a court that must prove the repository is running on
    /// exactly the object the engine returned. *Comparing the pointer is comparing the connection;
    /// comparing a description of it would prove nothing.*
    public var connectionIdentity: UInt {
        UInt(bitPattern: Int(bitPattern: UnsafeRawPointer(rawHandle)))
    }
}

/// *** WHAT AN ENGINE RETURNS ONCE IT HAS AN OPERATIONAL, VERIFIED CONNECTION. ***
///
/// The faults reuse `StoreOpenFault`'s vocabulary where they overlap, so the factory's existing
/// classification keeps working; `refused` carries the engine's own words for the cases only it
/// can describe.
public enum OwnedConnectionResult {
    /// A live, keyed, verified connection -- AND the closed handle that owns it.
    case opened(OwnedConnection, cipherVersion: Int)
    /// The engine refused: wrong key, missing DEK, corrupt header, unsupported version.
    case refused(StoreOpenFault)
    /// The engine is not available at all (no approved native artifact).
    case engineUnavailable

    public var isOpened: Bool { if case .opened = self { return true }; return false }
}

/// *** THE CLOSE-OWNING WRAPPER: "explicit close ownership" FROM THE AUDIT'S LIST. ***
///
/// *Whoever opened the connection closes it, once, and the type says so.* The handler is invoked
/// exactly once; a second `close()` is a no-op that reports that it was already closed rather than
/// double-closing the handle -- *which is undefined behaviour in SQLite and the reason
/// "double close / ownership violation -> fail" is on the audit's negative list.*
public final class OwnedConnection: @unchecked Sendable {
    /// *** `private(set) var` RATHER THAN `let`: the owner back-reference is written after full initialization (a
    /// `let` field cannot be assigned a value that itself needs `self`), and the public read access is unchanged. ***
    public private(set) var connection: OwnedVerifiedConnection
    private let closeHandler: (OpaquePointer) -> Void
    private let lock = NSLock()
    private var closed = false
    /// *** THE IMAGE LEASE OWNED BY THIS WRAPPER, SO THE IMAGE OUTLIVETH BOTH THE ENGINE AND THIS CONNECTION. ***
    /// *SQLITE-REVIEW-1: `deinit` releases the reference taken on the provider's lease, so the image is unloaded only
    /// after the LAST owner (engine, connection, store) falls.*
    private let imageLease: SQLiteImageLease?
    /// *** THE SHARED LIFECYCLE: THE CLOSED FLAG THE ADOPTING STORES ALSO ADMIT THEMSELVES AGAINST. *** *When an
    /// engine handed this wrapper over, the verified connection carrieth the SAME object (see `connection.lifecycle`),
    /// so `close()` and a store's `beginUse()` observe one another.*
    private let lifecycle: ConnectionLifecycle

    internal init(connection: OwnedVerifiedConnection,
                  close: @escaping (OpaquePointer) -> Void) {
        // *EVERY STORED PROPERTY IS INITIALIZED BEFORE `self` IS USED AS A VALUE -- Swift forbids passing `self` while a
        // field is unset, and writing the owner back-reference NEEDS `self`. So the connection is stored first, and the
        // (value-type) connection's `owner` is written through the stored property afterwards.*
        self.closeHandler = close
        let lc = connection.lifecycle ?? ConnectionLifecycle()
        self.lifecycle = lc
        // *TAKE A REFERENCE ON THE IMAGE so the pointers in `connection.provider` stay valid while this wrapper lives.*
        self.imageLease = connection.provider.lease
                self.connection = connection
        // *The connection is handed its owner WEAKLY here, so a store can ask `isClosed` and take a use reference.
        // Weak, so this link never keeps the owner alive and a forgotten close order cannot leak the handle.*
        self.connection.owner = self
    }

    /// *** SQLITE-LATEST-I2: THE FINAL OWNER CLOSES ITS LIVE DATABASE IN `deinit`, NOT ONLY ITS IMAGE REFERENCE. ***
    ///
    /// *MEASURED DEFECT: `deinit` released the image lease but never closed the SQLite handle, and both adopted stores
    /// deliberately do not close what they do not own -- so an owner dropped WITHOUT an explicit `close()` (a leaked
    /// runtime, a dropped factory result, a failed direct adoption) LEAKED its connection, and the image could unload
    /// while a leaked native handle remained live.* **`close()` is idempotent and exactly-once, so calling it here is
    /// safe: an owner that was explicitly closed already has `closed == true` and this is a no-op; a dropped owner gets
    /// its one close on the way out.** *The image reference is released after, so the last owner's exit unloads the
    /// image only after the connection is freed.*
    deinit {
        _ = close()             // exactly-once by the same lifecycle guard; a no-op if already explicitly closed
        // (the `imageLease` strong reference is released by ARC when this owner deallocates; if it was the last user,
        // the lease's deinit unloads the image)
    }

    /// Close the connection, exactly once. Returns whether this call was the one that closed it,
    /// so a court can observe that ownership was honoured.
    ///
    /// *** AND IT WAITS FOR ACTIVE USE, WHICH IS SQLITE-REVIEW-2'S OWN LAW. *** *The previous body marked closed and
    /// freed immediately; a worker between `prepare`/`step`/`finalize` then dispatched through a freed or zombied
    /// handle. Now the close marks closed (no NEW use may enter), DRAINS the active users, and only then frees --
    /// so a real statement or transaction in flight is never freed out from under.*
    @discardableResult
    public func close() -> Bool {
        let handle = connection.rawHandle
        let handler = closeHandler
        let lease = imageLease
        return lifecycle.close {
            // *** THE IMAGE STAYETH LOADED THROUGH THE CLOSE DISPATCH: the closure capture itself holdeth a
            // strong reference on the lease, so the lease's `deinit` `dlclose` cannot run before `closeHandler`
            // hath returned -- the `withExtendedLifetime` helper this line referenced never existed in the tree. ***
            handler(handle)
            _ = lease
        }
    }

    public var isClosed: Bool { lifecycle.isClosed }
    public var isPhysicallyClosed: Bool { lifecycle.isPhysicallyClosed }
    /// *** ADOPT A USE OF THIS CONNECTION FOR THE DURATION OF `body`, OR REFUSE WITH THE NAMED REASON. ***
    ///
    /// *The one admission every store operation and every transaction goeth through: it checketh the owner's CLOSED
    /// state before any raw handle is dispatched, so a post-owner-close call becometh a TYPED REFUSAL rather than a
    /// stale-handle dispatch. It holdeth a use reference for the whole body, so a concurrent `close()` WAITS rather
    /// than frees mid-operation.* **`body` is called WITHOUT the lifecycle's lock held**, so the store may take its own
    /// lock inside (documented lock order: lifecycle -> store lock) without a cycle.
    internal func usingConnection<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        guard lifecycle.beginUse() else { throw StoreConnectionError.ownerClosed }
        defer { lifecycle.endUse() }
        return try body(connection.rawHandle)
    }

    /// *** THE NON-THROWING ADMISSION FOR THE LEGACY NIL-ON-FAILURE SURFACE. *** *A closed connection answereth nil
    /// here, which the `withDb` readers already treat as "unusable" -- never a fabricated value.*
    internal func usingConnectionIfOpen<T>(_ body: (OpaquePointer) -> T) -> T? {
        guard lifecycle.beginUse() else { return nil }
        defer { lifecycle.endUse() }
        return body(connection.rawHandle)
    }

    /// The uses in flight, for a court that must observe that a close waited rather than raced.
    internal var activeUsesForTest: Int { lifecycle.activeUsersForTest }
}

/// *** THE TYPED REFUSAL A STORE RAISETH WHEN THE OWNER ALREADY CLOSED THE CONNECTION. *** *Distinct from the store's
/// own `handleMissing` so a caller (and a court) can tell "the owner closed it" from "this store never had a handle".*
internal enum StoreConnectionError: Error, Equatable { case ownerClosed }

/// *** THE ENGINE CONTRACT, EXTENDED TO HAND OVER THE CONNECTION. ***
///
/// *A conformer that can only describe a connection cannot supply one, which is exactly how the
/// repository ended up opening its own.* This is the requirement that makes the handover
/// unavoidable rather than optional.
public protocol OwnedConnectionStoreEngine: EncryptedStoreEngine {
    /// Open (or create) the store and return the OWNED, VERIFIED, OPERATIONAL connection.
    ///
    /// The engine MUST have performed its keying and its at-rest verification BEFORE returning:
    /// the connection is the proof, so returning one that is not keyed would defeat the contract.
    func openOwnedForWriting(path: String, dek: StoreDEK) throws -> OwnedConnection

    /// Reopen an existing store, requiring the DEK -- never creating. The same ownership rules.
    func reopenOwnedRequiringDEK(path: String, dek: StoreDEK) throws -> OwnedConnection
}
