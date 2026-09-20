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

    /// *** INTERNAL ON PURPOSE: AN ENGINE, NOT A CALLER, MINTS ONE OF THESE. ***
    internal init(rawHandle: OpaquePointer, engineKind: StoreEngineKind,
                  cipherVersion: Int, encryptedAtRest: Bool, path: String) {
        self.rawHandle = rawHandle
        self.engineKind = engineKind
        self.cipherVersion = cipherVersion
        self.encryptedAtRest = encryptedAtRest
        self.path = path
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
    public let connection: OwnedVerifiedConnection
    private let closeHandler: (OpaquePointer) -> Void
    private let lock = NSLock()
    private var closed = false

    internal init(connection: OwnedVerifiedConnection,
                  close: @escaping (OpaquePointer) -> Void) {
        self.connection = connection
        self.closeHandler = close
    }

    /// Close the connection, exactly once. Returns whether this call was the one that closed it,
    /// so a court can observe that ownership was honoured.
    @discardableResult
    public func close() -> Bool {
        lock.lock()
        if closed { lock.unlock(); return false }
        closed = true
        let handle = connection.rawHandle
        lock.unlock()
        closeHandler(handle)
        return true
    }

    public var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }
}

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
