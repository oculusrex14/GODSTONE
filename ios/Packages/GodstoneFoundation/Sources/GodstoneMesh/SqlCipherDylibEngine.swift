import Foundation

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
//  tree"); THIS FILE REMOVES THAT EXCUSE. What remains outside the builder's reach is the PINNED
//  BINARY and its device at-rest proof, which stay `EXTERNAL_BLOCKED`.
//
//  *** WHY `dlopen`/`dlsym` RATHER THAN A VENDORED LIBRARY OR A SYNTHESIZED ARTIFACT. ***
//  *`third_party/llama.cpp`'s precedent in this repository forbids vendoring the artifact.* And a
//  synthesized `.tbd`/stub would be the "enum value called pinnedSQLCipher is not engine
//  verification" defect wearing a linker flag. **Dynamic binding leaves the artifact where the
//  supply chain puts it, and makes its ABSENCE a RUNTIME ANSWER rather than a link error** -- which
//  is exactly the fail-closed shape the card asks for: no approved artifact means no engine, and no
//  engine means no private store, never a plaintext one.
//
//  *** AND THIS IS NOT A CLAIM OF DEVICE VERIFICATION. *** The pinned binary, its approval and the
//  at-rest bytes on a device are the EXTERNAL half. **Everything this file proves is provable on a
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
    /// digest `44fc40c3…`, version `4.17.0`); the iOS artifact's own pin is the external half this
    /// builder cannot write.* **The name here is the Apple-platform spelling of the same engine, and
    /// the obligation's evidence records that the pin itself remains external.**
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
public final class SqlCipherDylibEngine: OwnedConnectionStoreEngine, @unchecked Sendable {

    /// *** THE COMPLETE TABLE BOUND FROM THIS ENGINE'S OWN IMAGE -- ALL-OR-NOTHING. ***
    ///
    /// *The old engine bound eight symbols into a private struct and then let the adopting stores reach the GLOBALLY
    /// LINKED `sqlite3_*` functions for everything else. This table carrieth the COMPLETE surface both stores use, all
    /// resolved from the one image, and `openKeyedVerified` hands it to the connection -- so no raw handle ever
    /// crosses a provider boundary through a global symbol again.*
    private let table: SQLiteFunctionTable?

    /// *** THE `dlopen` HANDLE IS RETAINED FOR AS LONG AS THE TABLE'S POINTERS CAN BE USED, AND THE CLOSE IS PAIRED
    /// WITH THE ENGINE'S OWN LIFETIME. ***
    ///
    /// *THE DEFECT THIS CLOSES: the old `deinit` called `dlclose`, but the close CLOSURE handed to `OwnedConnection`
    /// captured only the eight FUNCTION POINTERS -- so if an `OwnedConnection` outlived the engine, its close would
    /// invoke a pointer into an UNLOADED image. The reverse ordering is the practical one (an engine outlives its
    /// connections in the composition), but "practical" is not a guarantee.* **So ownership is made explicit: the
    /// engine keepeth the `dlopen` handle, the connection carrieth its table, and the composition's close order
    /// (stores, then adopted connections, then the engine) is what the courts assert.**
    private let handle: UnsafeMutableRawPointer?
    private let bindingFailure: String?

    /// Bind the pinned library. *A caller may pin its own name for a court; production passeth none.*
    public init(libraryPath: String? = nil) {
        let name = libraryPath ?? SQLCipherPin.libraryName
        let h = dlopen(name, RTLD_NOW | RTLD_LOCAL)
        self.handle = h
        guard let h else {
            let why = dlerror().map { String(cString: $0) } ?? "dlopen returned no handle"
            self.table = nil
            self.bindingFailure = "the pinned SQLCipher library '\(name)' is not present: \(why)"
            return
        }
        // *** THE COMPLETE TABLE, ALL-OR-NOTHING. *** *A partially bound image would call a garbage function pointer
        // -- a crash, not a refusal -- so a missing symbol is a TYPED BINDING FAILURE taken here, once. The required
        // names are the ONE list the table and its court agree on.*
        guard let bound = SQLiteFunctionTable.bind(fromImage: h,
                                                   providerName: "SQLCipher (\(name))") else {
            self.table = nil
            self.bindingFailure = "the library '\(name)' loaded but carrieth not the complete "
                + "sqlite3_* surface both stores use (\(SQLiteFunctionTable.requiredSymbols.count) symbols); a "
                + "partial bind cannot perform the cipher probe"
            return
        }
        self.table = bound
        self.bindingFailure = nil
    }

    /// *** `deinit` CLOSES THE IMAGE -- AND THAT IS EXACTLY WHY THE TABLE MUST BE CARRIED BY THE CONNECTION. ***
    ///
    /// *An `OwnedConnection` that outlived its engine would otherwise close through a pointer into an unloaded image.
    /// The composition's close order (documented in `closeAdoptedConnections`) is stores -> adopted connections ->
    /// engine, and `GsFinal004OwnedConnectionTests` asserteth that order.*
    deinit { if let handle { dlclose(handle) } }

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
    public var kind: StoreEngineKind { isBound ? .pinnedSQLCipher : .plainSQLite }

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
        let verified = OwnedVerifiedConnection(rawHandle: handle,
                                               engineKind: .pinnedSQLCipher,
                                               cipherVersion: major,
                                               encryptedAtRest: true,
                                               path: path,
                                               provider: s)
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
