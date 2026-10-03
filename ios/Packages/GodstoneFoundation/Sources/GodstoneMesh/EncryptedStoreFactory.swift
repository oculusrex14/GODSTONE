import Foundation

// ---------------------------------------------------------------------------
// T30 FACTORY - the fail-closed EncryptedStoreFactory.
//
// It opens (or reopens) a private message / peer store ONLY through:
//   * the [PrivateStoreKeyProvider] Keychain seam, to obtain the ThisDeviceOnly
//     StoreDEK -- and it NEVER falls back to a plaintext or empty store when the
//     DEK, the Keychain, or file protection is unavailable; and
//   * an [EncryptedStoreEngine] seam that MUST report kind == .pinnedSQLCipher --
//     a plain SQLite engine is refused outright (the "no fallback plain SQLite"
//     law), so the system SQLite path can never masquerade as the encrypted store.
//
// The decision is TOTAL and FAIL-CLOSED: every thrown fault maps to a typed
// non-available EncryptedStoreOpenResult, and an opened handle that does not
// itself assert encrypted-at-rest on the pinned SQLCipher engine is rejected. A
// reopen of an EXISTING store requires the DEK: a missing DEK yields `.unavailable`,
// never a silently-empty healthy store. The concrete SQLCipher engine (the real
// PRAGMA key / cipher_version / cipher settings) and the Keychain items are the
// device adapter; on the host the injected seams drive the SAME decision laws the
// ReadinessT30Tests court asserts. Physical at-rest bytes are device evidence.
// ---------------------------------------------------------------------------
/// A factory scope is created only from the physical authority's live construction lease.
public enum EncryptedStoreAdmissionFault: Equatable, Sendable {
    case noScope
    case bindingMismatch(reason: String)
    case staleOrSpent
}

public struct EncryptedStoreAdmissionScope: Sendable {
    public let estateId: String
    public let generation: UInt64
    public let storeTag: String
    public let storePath: String
    private let authorityLease: PhysicalEstateAuthority.ConstructionLease

    internal init(authorityLease: PhysicalEstateAuthority.ConstructionLease, storeTag: String, storePath: String) {
        self.authorityLease = authorityLease
        self.estateId = authorityLease.estateId
        self.generation = authorityLease.generation
        self.storeTag = storeTag
        self.storePath = PhysicalEstateAuthority.canonicalPath(URL(fileURLWithPath: storePath))
    }

    public var isCurrent: Bool { authorityLease.isCurrent }
    internal func claim(path: String, tag: String, keyDomain: String) -> Bool {
        guard tag == storeTag, PhysicalEstateAuthority.canonicalPath(URL(fileURLWithPath: path)) == storePath else { return false }
        return authorityLease.claim(path: path, tag: tag, keyDomain: keyDomain)
    }
}

public enum StoreEngineKind: String, Sendable {
    case pinnedSQLCipher
    case plainSQLite
}

/// A successfully opened, encrypted private store handle. It carries the at-rest
/// assertions the factory verifies before ever returning `.available`.
public struct EncryptedStoreHandle: Equatable, @unchecked Sendable {
    public let path: String
    public let kind: StoreEngineKind
    public let encryptedAtRest: Bool
    public let cipherVersion: Int
    public init(path: String, kind: StoreEngineKind, encryptedAtRest: Bool, cipherVersion: Int) {
        self.path = path; self.kind = kind; self.encryptedAtRest = encryptedAtRest; self.cipherVersion = cipherVersion
    }
}

public enum EncryptedStoreOpenResult: Equatable {
    case available(EncryptedStoreHandle)
    case locked            // the DEK is present but the store cannot be decrypted with it
    case corrupt           // malformed header / an unclassified fault fails CLOSED here
    case unavailable       // DEK / Keychain / protection unavailable, or a plain-engine fallback refused
    case unsupportedVersion(found: Int, supported: Int)
    public var isAvailable: Bool { if case .available = self { return true }; return false }
}

/// The fault vocabulary an [EncryptedStoreEngine] throws; the factory classifies it.
public enum StoreOpenFault: Error, Equatable {
    case wrongKey
    case corruptHeader
    case cipherVersionMismatch(found: Int, supported: Int)
    case io(String)
}

/// The concrete engine seam (the real SQLCipher binding on the device; a deterministic
/// fake in the court). It must report its kind and open the file with the DEK applied.
public protocol EncryptedStoreEngine: AnyObject {
    var kind: StoreEngineKind { get }
    var supportedCipherVersion: Int { get }
    func openForWriting(path: String, dek: StoreDEK) throws -> EncryptedStoreHandle
    func reopenRequiringDEK(path: String, dek: StoreDEK) throws -> EncryptedStoreHandle
}

public final class EncryptedStoreFactory: @unchecked Sendable {
    private let provider: PrivateStoreKeyProvider
    private let engine: EncryptedStoreEngine
    public init(provider: PrivateStoreKeyProvider, engine: EncryptedStoreEngine) {
        self.provider = provider; self.engine = engine
    }

    /// *** THE ENGINE IN THE OWNED ROAD'S VOCABULARY -- THE SUPPLIER OF A VERIFIED CONNECTION. ***
    ///
    /// *The mid-edit that added the admission scopes left `reopenOwnedRequiringDEK`'s body referring to an `owner` that
    /// did not exist and ending with an UNCONDITIONAL `return .engineUnavailable` plus a stray brace, so the file did
    /// not compile. This is that binding, named once: a metadata-only engine (no `OwnedConnectionStoreEngine`
    /// conformance) simply cannot satisfy the owned road, which is the TYPED `.engineUnavailable` the road already
    /// documents -- never a fabricated connection.*
    private var owner: OwnedConnectionStoreEngine? { engine as? OwnedConnectionStoreEngine }

    // ================================================================================================
    // *** THE ADMISSION CHECK: THE LEDGER-ISSUED MINT IS VERIFIED **BEFORE** THE KEY PROVIDER IS TOUCHED. ***
    //
    // *Two parties, one ledger. The ESTATE AUTHORITY mints (and consumes, once its construction succeeds, so a permit is
    // one-shot); the FACTORY verifies the mint against that same ledger -- issuance, exact binding, and not-yet-spent --
    // before it will fetch a DEK or hand over a connection. Neither half alone closes the door: an authority that records
    // but is never consulted, or a factory that checks a shape rather than an issuance, both let a copied struct through.*
    // ================================================================================================
    private func admissionRefusal(path: String, tag: String,
                                  scope: EncryptedStoreAdmissionScope?) -> EncryptedStoreOpenResult? {
        // fail closed: an unadmitted open never reaches the key provider or the engine.
        admissionFault(path: path, tag: tag, scope: scope) == nil ? nil : .unavailable
    }

    private func ownedAdmissionRefusal(path: String, tag: String,
                                       scope: EncryptedStoreAdmissionScope?) -> OwnedConnectionResult? {
        // *THE OWNED ROAD CARRIETH NO `.unavailable`; its refusal vocabulary is `refused`/`engineUnavailable`. An
        // admission failure is `.engineUnavailable` -- "this composition is not admitted to open a private store" -- and
        // it is TYPED rather than a fabricated connection, which is the same law the metadata road obeys above.*
        admissionFault(path: path, tag: tag, scope: scope) == nil ? nil : .engineUnavailable
    }

    /// The ONE admission decision both roads share: `nil` admits **AND ATOMICALLY CLAIMS THE TOKEN**; a fault refuses.
    ///
    /// *** SQLITE-LATEST-C3: THE CLAIM IS TAKEN HERE, IN ONE LOCK SECTION, BEFORE THE KEY PROVIDER IS TOUCHED. *** *So a
    /// scope is ONE-SHOT at the actual factory boundary (a concurrent or sequential replay is refused, and a
    /// failed-attempt retry is refused too), and the authority's later `consume` is idempotent against the spent mint.
    private func admissionFault(path: String, tag: String,
                                scope: EncryptedStoreAdmissionScope?) -> EncryptedStoreAdmissionFault? {
        guard let scope else { return .noScope }
        // *** THE BINDING CHECK RUNS BEFORE THE CLAIM, SO A MISDIRECTED ATTEMPT SPENDETH NOTHING. ***
        // *The claim spendeth the per-tag slot ONLY for the exact tag+path the authority bound; a wrong-path attempt is
        // the `bindingMismatch` class, named here rather than laundered into `staleOrSpent` by the claim itself --
        // and it leaves the legitimately-bound slot still spendable exactly once.*
        guard scope.storeTag == tag,
              PhysicalEstateAuthority.canonicalPath(URL(fileURLWithPath: path)) == scope.storePath
        else {
            return .bindingMismatch(reason: "the lease is bound to tag '\(scope.storeTag)' at '\(scope.storePath)', "
                                   + "not to '\(tag)' at '\(path)'")
        }
        guard scope.claim(path: path, tag: tag, keyDomain: provider.physicalKeyDomain) else { return .staleOrSpent }
        return nil
    }

    /// GS-STORE-006: **THE KEY PROVIDER, HANDED OUT FOR THE WIPE'S OWN VAULT SEAM.**
    ///
    /// The card's step 2 forbiddeth a composition in which "a default-nil dependency permit[s] a production wipe to omit
    /// a required resource" -- and THE DEK's ONE OWNER IS THIS PROVIDER (its `deleteDEK(tag:)` is the only verb that
    /// eraseth the wrapping key). The field is `private`, so rather than reaching into it from the composition, THE
    /// FACTORY NAMETH THE RESPONSIBILITY HERE, and the wipe's `WipeKeyVaultSeam` taketh it as its `any
    /// PrivateStoreKeyProvider`. A wipe wired without it would reach `IDLE` WITHOUT HAVING ERASED THE DEK.
    internal var keyProviderForWipe: PrivateStoreKeyProvider { provider }


    /// *** GS-STORE-002 STEP 5 (round 544): *'Apply complete file protection to created **DB/WAL/SHM AND
    /// DIRECTORIES** as required.'* ***
    ///
    /// MEASURED BEFORE THIS EDIT, AND IT IS THE CARD'S OWN CLAUSE UNSATISFIED: BOTH call sites passed
    /// `paths: [path]` -- **THE MAIN DATABASE FILE ALONE.** In WAL mode the `-wal` and `-shm` SIDECARS hold the very
    /// rows the main file lacketh, and **AN UNPROTECTED SIDECAR IS AN UNPROTECTED STORE** whatever protection the
    /// main file carrieth; the containing DIRECTORY governeth what may be created beside it.
    ///
    /// THE PATH SET IS **DERIVED FROM THE STORE'S OWN LOCATION** rather than from a list a caller must remember --
    /// a caller who must remember the sidecars is a caller who will forget them, which is how this clause came to be
    /// unmet while the protection call looked correct. **A PATH THAT IS NEVER NAMED IS NEVER PROTECTED.**
    ///
    /// IT IS A SEAM (`protectionPaths`) SO THE LAW IS TESTABLE WITHOUT A DEVICE: the host cannot apply a real
    /// Data-Protection class (measured: the provider answereth `.success` unconditionally off-iOS), **but the SET OF
    /// PATHS THE FACTORY ASKS FOR is host-observable, and that set is what this repair fixeth.**
    internal func protectionPaths(forStoreAt path: String) -> [String] {
        [path, path + "-wal", path + "-shm",
         (path as NSString).deletingLastPathComponent]
    }

    /// *** SQLITE-LATEST-I3: PROTECT ONLY WHAT **EXISTS**, AND PROTECT THE DIRECTORY **BEFORE** CREATION. ***
    ///
    /// *MEASURED DEFECT: the owned first-install road applied `setAttributes` to `[DB, DB-wal, DB-shm, parent]` BEFORE
    /// the engine created the database -- and the REAL iOS adapter treateth a missing path as a FAILURE, so a
    /// fresh/post-wipe composition (the DB is absent by definition) and a clean reopen (sidecars legitimately absent)
    /// were refused with `.engineUnavailable` before SQLCipher could create anything.* **SO: the PARENT (which the
    /// composition creates first) is protected BEFORE the open, and after the open the artifacts THAT EXIST (the DB and
    /// whichever sidecars the engine created) are protected -- no missing-file error, and no weakening of the class.**
    internal func existingProtectionPaths(forStoreAt path: String) -> [String] {
        var out = [(path as NSString).deletingLastPathComponent]
        for p in [path, path + "-wal", path + "-shm"] where FileManager.default.fileExists(atPath: p) { out.append(p) }
        return out
    }

    /// Open (creating if first install) the encrypted store at `path`, keyed by `tag`.
    ///
    /// *** THE ADMITTED SCOPE IS DEMANDED BEFORE THE KEY PROVIDER IS TOUCHED. *** *An unadmitted call is a refusal,
    /// not a key fetch -- which is the whole point of a capability at this boundary: the previous shape let any caller
    /// that could name a path and a tag ask the Keychain for that estate's DEK.*
    public func openStore(path: String, tag: String,
                          scope: EncryptedStoreAdmissionScope?) -> EncryptedStoreOpenResult {
        if let refusal = admissionRefusal(path: path, tag: tag, scope: scope) { return refusal }
        guard engine.kind == .pinnedSQLCipher else { return .unavailable }   // no plaintext fallback, ever
        let dek: StoreDEK
        do {
            dek = try provider.fetchDEK(tag: tag)
        } catch let e {
            if case StoreKeyError.dekNotFound = e {
                do { dek = try provider.createDEK(tag: tag) }                  // first install: mint the DEK
                catch let e2 { return mapProviderError(e2) }
            } else { return mapProviderError(e) }
        }
        // *** SQLITE-LATEST-I3: THE PARENT FIRST, THEN THE ARTIFACTS THAT ACTUALLY EXIST. ***
        // *This is the FIRST-INSTALL road: the DB does not exist yet, so the composition's directory is protected
        // first, the keyed database is created inside it, and the DB plus whichever sidecars the engine really
        // created are protected after the open. The REAL iOS adapter treateth a MISSING path as a failure, so the
        // pre-open ask for [DB, DB-wal, DB-shm] refused every fresh estate before SQLCipher could run.*
        let parent = (path as NSString).deletingLastPathComponent
        guard provider.applyFileProtection(paths: [parent], protection: .complete).isSuccess else { return .unavailable }
        let opened = finalize { try self.engine.openForWriting(path: path, dek: dek) }
        guard opened.isAvailable else { return opened }
        guard provider.applyFileProtection(paths: existingProtectionPaths(forStoreAt: path),
                                            protection: .complete).isSuccess
        else { return .unavailable }   // protection unproven on created artifacts: nothing is published
        return opened
    }

    /// Reopen an EXISTING encrypted store at `path`. Requires the DEK; a missing DEK is
    /// `.unavailable`, never an empty healthy store (this is the reopen-without-DEK law).
    public func reopenExisting(path: String, tag: String,
                               scope: EncryptedStoreAdmissionScope?) -> EncryptedStoreOpenResult {
        if let refusal = admissionRefusal(path: path, tag: tag, scope: scope) { return refusal }
        guard engine.kind == .pinnedSQLCipher else { return .unavailable }
        let dek: StoreDEK
        do {
            dek = try provider.fetchDEK(tag: tag)                              // MUST exist; no create-on-reopen
        } catch let e {
            return mapProviderError(e)                                         // dekNotFound -> .unavailable (fail-closed)
        }
        // *** SQLITE-LATEST-I3: ON A REOPEN THE SIDECARS CAN LEGITIMATELY BE ABSENT -- protect what EXISTS. ***
        // *`protectionPaths` remains the full derived set (its own court pins the SET); on the road, a missing
        // sidecar is not a failure -- and an unproven apply on an artifact that DOES exist still fails closed.*
        guard provider.applyFileProtection(paths: existingProtectionPaths(forStoreAt: path),
                                            protection: .complete).isSuccess else { return .unavailable }
        return finalize { try self.engine.reopenRequiringDEK(path: path, dek: dek) }
    }

    // ================================================================================================
    // *** GS-FINAL-004 CLAUSE (a): THE FACTORY HANDS OVER AN OWNED, OPERATIONAL CONNECTION. ***
    //
    // THE AUDIT'S CHARGE, VERBATIM: *"The factory yields descriptive metadata rather than an owned
    // operational connection/capability, and composition performs a second independent open."* AND ITS
    // REMEDIATION: *"Change EncryptedStoreFactory to return an owned verified connection with restricted
    // construction and explicit close ownership."*
    //
    // **THIS IS THE VERB THAT MAKES THE SECOND OPEN IMPOSSIBLE RATHER THAN MERELY ABSENT.** *`reopenExisting`
    // answers with `EncryptedStoreHandle` -- path, kind, `encryptedAtRest`, `cipherVersion` AND NO CONNECTION
    // -- so a caller could only ever CHECK it and then open a store by URL, which is what the composition
    // did. A handle that CARRIES the connection leaves the caller nothing to reopen with.*
    //
    // **TWO VERBS FOR TWO QUESTIONS**, rather than one verb whose answer depends on which fields the caller
    // happens to read: the metadata road answers the at-rest verdict BEFORE a private store existeth; this
    // road is for a caller that means to USE the connection.
    //
    // **IT IS GUARDED ON `OwnedConnectionStoreEngine`, SO AN ENGINE THAT CANNOT HAND ONE OVER IS NOT ASKED
    // TO.** *The ledger's blocker is re-verified here: no PRODUCTION `EncryptedStoreEngine` exists in this
    // tree -- the real SQLCipher binding IS the injected seam the NATIVE_MODELS gate owns, and the only
    // implementors are courts' `FakeEngine`s. So `engineUnavailable` is the TRUTHFUL answer for a
    // metadata-only engine, and it is TYPED rather than a fabricated connection. Nothing here claims an
    // at-rest result: the handover is what is proven, and the engine that supplies it is the seam's.*
    public func reopenOwnedRequiringDEK(path: String, tag: String,
                                        scope: EncryptedStoreAdmissionScope?) -> OwnedConnectionResult {
        if let refusal = ownedAdmissionRefusal(path: path, tag: tag, scope: scope) { return refusal }
        guard engine.kind == .pinnedSQLCipher else { return .engineUnavailable }   // no plaintext fallback, ever
        guard let owner else {
            // THE ENGINE CANNOT SUPPLY A CONNECTION, so refusing is the honest answer: a caller that asked for
            // an owned connection must not receive a nominal one, which is the "nominal store with a nil
            // handle" the same card clause forbids. *`owner` is the engine viewed as `OwnedConnectionStoreEngine`;
            // a metadata-only engine cannot satisfy the owned road.*
            return .engineUnavailable
        }
        let dek: StoreDEK
        do { dek = try provider.fetchDEK(tag: tag) }              // MUST exist; no create-on-reopen
        catch let e { return mapOwnedProviderError(e) }

        // STEP 5, AS ON THE METADATA ROAD: an unprotected `-wal`/`-shm` is an unprotected store.
        let protection = provider.applyFileProtection(paths: existingProtectionPaths(forStoreAt: path),
                                                      protection: .complete)
        guard protection.isSuccess else { return .engineUnavailable }
        do {
            let connection = try owner.reopenOwnedRequiringDEK(path: path, dek: dek)
            // THE VERIFIED CONNECTION KNOWS ITS OWN CIPHER VERSION; the DEK's LENGTH does not. My first version
            // reported the key width (32) under a parameter named `cipherVersion`, which is a different quantity
            // wearing the same word -- the comparison `found == supported` would then never hold.
            return .opened(connection, cipherVersion: connection.connection.cipherVersion)
        }
        catch let f { return ownedRefusal(classifyEngineFault(f)) }
    }

    /// *** IOS-R4: THE OWNED ROAD'S FIRST-INSTALL VERB -- `fetchDEK` THEN `createDEK` ON ABSENCE. ***
    ///
    /// *The obligation: "Model the two stores' key lifecycle explicitly, including FRESH KEY CREATION after successful
    /// destruction rather than accidental reuse of surviving old keys." After a completed wipe the two real DEK accounts
    /// AND the store files are GONE, so the next private composition is effectively a FIRST INSTALL and MUST CREATE a
    /// key -- but the composition called `reopenOwnedRequiringDEK` unconditionally, which fetchETH (never createth) and
    /// therefore FAILS post-wipe. This verb is the owned twin of `openStore` vs. `reopenExisting`, so the composition can
    /// CHOOSE by file existence.* **Everything else is identical to `reopenOwnedRequiringDEK`: the same scope admission
    /// check, the same `.pinnedSQLCipher` guard, the same file-protection set, and the same `openOwnedForWriting`
    /// handover.** *And it still NEVER falls back to plaintext: a failed create, a non-pinned engine, or a metadata-only
    /// engine all answer typed refusals.*
    public func openOwnedForWriting(path: String, tag: String,
                                    scope: EncryptedStoreAdmissionScope?) -> OwnedConnectionResult {
        if let refusal = ownedAdmissionRefusal(path: path, tag: tag, scope: scope) { return refusal }
        guard engine.kind == .pinnedSQLCipher else { return .engineUnavailable }   // no plaintext fallback, ever
        guard let owner else { return .engineUnavailable }
        let dek: StoreDEK
        do { dek = try provider.fetchDEK(tag: tag) }
        catch let e {
            if case StoreKeyError.dekNotFound = e {
                // FIRST INSTALL: the DEK does not exist (a fresh estate, or one whose key a wipe DESTROYED), so mint one.
                do { dek = try provider.createDEK(tag: tag) } catch let e2 { return mapOwnedProviderError(e2) }
            } else { return mapOwnedProviderError(e) }
        }
        // *** SQLITE-LATEST-I3: PROTECT THE PARENT **BEFORE** CREATION (the DB does not exist yet). ***
        let parent = (path as NSString).deletingLastPathComponent
        guard provider.applyFileProtection(paths: [parent], protection: .complete).isSuccess else { return .engineUnavailable }
        do {
            let connection = try owner.openOwnedForWriting(path: path, dek: dek)
            // *** NOW PROTECT THE ARTIFACTS THE ENGINE ACTUALLY CREATED (the DB and whichever sidecars exist). ***
            guard provider.applyFileProtection(paths: existingProtectionPaths(forStoreAt: path),
                                               protection: .complete).isSuccess else {
                _ = connection.close()
                return .engineUnavailable
            }
            return .opened(connection, cipherVersion: connection.connection.cipherVersion)
        }
        catch let f { return ownedRefusal(classifyEngineFault(f)) }
    }

    /// The provider's classification, expressed in the OWNED road's own vocabulary.
    private func mapOwnedProviderError(_ e: Error) -> OwnedConnectionResult {
        if let k = e as? StoreKeyError, case .decodingFailure = k { return .refused(.corruptHeader) }
        return .engineUnavailable
    }

    /// Translate the factory's existing typed classification into the owned road's refusal vocabulary.
    private func ownedRefusal(_ r: EncryptedStoreOpenResult) -> OwnedConnectionResult {
        switch r {
        case .available: return .engineUnavailable          // unreachable: the owned road never returns a handle
        case .locked: return .refused(.wrongKey)
        case .corrupt: return .refused(.corruptHeader)
        case .unavailable: return .engineUnavailable
        case .unsupportedVersion(let found, let supported):
            return .refused(.cipherVersionMismatch(found: found, supported: supported))
        }
    }

    /// Classify a provider (Keychain / DEK / protection) error to a typed result -- fail-closed.
    private func mapProviderError(_ e: Error) -> EncryptedStoreOpenResult {
        if let k = e as? StoreKeyError {
            switch k {
            case .dekNotFound, .keychainUnavailable, .deviceLocked, .dekWrongLength, .protectionFailure: return .unavailable
            case .decodingFailure: return .corrupt
            }
        }
        return .unavailable                                                    // an unknown Keychain fault fails CLOSED
    }

    /// Run an engine open, classify a thrown fault, and enforce the encrypted-at-rest pin.
    private func finalize(_ open: () throws -> EncryptedStoreHandle) -> EncryptedStoreOpenResult {
        let handle: EncryptedStoreHandle
        do { handle = try open() }
        catch let f { return classifyEngineFault(f) }
        guard handle.kind == .pinnedSQLCipher, handle.encryptedAtRest else { return .locked }  // reject a non-encrypted handle
        return .available(handle)
    }

    private func classifyEngineFault(_ f: Error) -> EncryptedStoreOpenResult {
        if let sf = f as? StoreOpenFault {
            switch sf {
            case .wrongKey: return .locked
            case .corruptHeader: return .corrupt
            case .cipherVersionMismatch(let found, let supported): return .unsupportedVersion(found: found, supported: supported)
            case .io: return .corrupt                                            // an io fault fails CLOSED, not empty-healthy
            }
        }
        return .corrupt                                                          // any unclassified open fault fails CLOSED
    }
}
