import Foundation

/// GS-STORE-006: **THE PRODUCTION `IdentityAuthoritySeam`** -- the last of the five adapters, and the one the ladder's
/// last rung becometh: `NEW_IDENTITY`, after which the node rejoins the mesh as a STRANGER.
///
/// *** IOS-R8 + IOS-FOLLOWUP-C7: PUBLICATION IS IDEMPOTENT, FULLY VERIFIED, AND BOUND TO THE WIPE GENERATION. ***
///
/// *THE TWO FINDINGS THIS CLOSES:*
///   * IOS-R8 -- "A crash after identity publication but before NEW_IDENTITY permanently bricks recovery" (the old
///     code called `generateAndStore` again, which REFUSED the present identity);
///   * IOS-FOLLOWUP-C7 -- "Identity adoption accepts an unknown or mismatching standing key ... only 4-byte hint, not
///     full key ... publication writes are Void and use `try? keychain.add` ... cannot distinguish the exact
///     interrupted replacement from an unrelated surviving/reintroduced key."
///
/// **THE CONTRACT, IN FOUR PARTS:**
///   1. an identity is associated with the wipe generation by its FULL public keys (signing + static DH), not a
///      4-byte hint;
///   2. a SAME-GENERATION record whose standing identity does NOT reproduce those exact keys **REFUSES** -- it never
///      falls through to adopt a mismatch;
///   3. a FRESH publish first durably records an **intent** for this generation, so the crash between `add` and the
///      full record is RECOGNIZED (adopt) rather than confused with an arbitrary standing key;
///   4. the publication write is CHECKED (`Bool`) and a failure is NOT swallowed -- adopt/checkpoint do not advance on
///      a record that did not reach the medium.
public final class WipeIdentityAuthoritySeam: IdentityAuthoritySeam {
    private let lock = NSLock()
    private var current: String?
    /// The regeneration the composition supplies (with ITS OWN keychain).
    private let regenerateIdentity: () throws -> MeshIdentity
    /// The standing identity read from the SAME keychain the regeneration wrote to (ONE VERB, ONE ANSWER).
    private let loadStandingIdentity: () throws -> MeshIdentity
    /// *** THE DURABLE ASSOCIATION (IOS-FOLLOWUP-C7): the full publication for a wipe generation. ***
    private let readPublication: () -> WipeIdentityPublication?
    /// *** CHECKED (IOS-FOLLOWUP-C7): false when the record did not reach the medium. ***
    private let writePublication: (WipeIdentityPublication) -> Bool
    /// *** THE PRE-PUBLICATION INTENT (IOS-FOLLOWUP-C7): a generation-only marker. ***
    /// *CURRENT-04: the AUTHORITY of an adoption is now the STAGED FULL PAIR written through `writePublication`,
    /// never this marker -- a generation number alone confers no provenance. It is retained as the protocol's own
    /// pre-publication witness (and the seam's documented shape) and is read by no adoption decision.*
    private let readPublicationIntent: () -> UInt64?
    private let writePublicationIntent: (UInt64) -> Bool

    /// The name recorded when the identity could not be published. It sayeth what happened; it is not an identifier.
    public static let generationFailedName = "identity-generation-failed"

    /// *** THE KEYCHAIN THE STAGED-PAIR PROMOTION REACHETH (IOS-FOLLOWUP-CURRENT-04). *** *The staged replacement is
    /// promoted through ONE verb on the same keychain the identity liveth in, so "is this pair the one that stands" is
    /// a keychain comparison rather than a generation marker.*
    private let keychain: any LocalIdentityKeychain

    /// *** INTERNAL, BECAUSE IT CARRIETH THE INTERNAL `LocalIdentityKeychain` (the composition and the courts are
    /// both in this module). *** *A public initializer cannot take an internal type, and the staged-pair promotion
    /// needs exactly that keychain -- the same reason `MeshRuntime`'s keychain-taking overload is internal.*
    internal init(
        regenerateIdentity: @escaping () throws -> MeshIdentity = { try MeshIdentity.generateAndStore() },
        loadStandingIdentity: @escaping () throws -> MeshIdentity = { try MeshIdentity.loadFromKeychain() },
        readPublication: @escaping () -> WipeIdentityPublication? = { nil },
        writePublication: @escaping (WipeIdentityPublication) -> Bool = { _ in false },
        readPublicationIntent: @escaping () -> UInt64? = { nil },
        writePublicationIntent: @escaping (UInt64) -> Bool = { _ in false },
        keychain: any LocalIdentityKeychain = DefaultLocalIdentityKeychain()
    ) {
        self.regenerateIdentity = regenerateIdentity
        self.loadStandingIdentity = loadStandingIdentity
        self.readPublication = readPublication
        self.writePublication = writePublication
        self.readPublicationIntent = readPublicationIntent
        self.writePublicationIntent = writePublicationIntent
        self.keychain = keychain
    }

    /// *** THE PLAIN PUBLISH ROAD (kept for the protocol's own contract). *** *The ladder useth `publishOrAdopt`. *
    public func publishNewIdentity() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let identity = try? regenerateIdentity() else { current = nil; return nil }
        current = Self.hint(of: identity)
        return current
    }

    /// *** IOS-R8/C7: PUBLISH *OR ADOPT*, IDEMPOTENT, FULLY VERIFIED, GENERATION-BOUND. ***
    public func publishOrAdoptIdentity(wipeGeneration: UInt64) -> String? {
        lock.lock(); defer { lock.unlock() }

        // (1) *** A SAME-GENERATION RECORD: ADOPT ONLY IF THE STANDING IDENTITY REPRODUCES ITS FULL KEYS. ***
        if let record = readPublication(), record.generation == wipeGeneration {
            if let standing = try? loadStandingIdentity(), record.matches(standing) {
                current = record.hint
                return record.hint
            }
            // *** A MISMATCH IS A REFUSAL -- NOT A FALL-THROUGH. *** *The old code fell through and then adopted the
            // mismatching key via the `identityAlreadyExists` catch; the record exists precisely to prevent that.*
            current = nil
            return nil
        }

        // (2) *** A FRESH PUBLISH: STAGE THE FULL REPLACEMENT PAIR FIRST, THEN PUBLISH *THAT PAIR*. ***
        //
        // *CURRENT-04: the intent carrieth MORE than a generation. It recordeth the STAGED pair's full public keys
        // (and only their public halves reach the durable record), so an adoption can be authorized by the pair this
        // wipe actually staged -- never by "an intent for this generation exists". An attempt that crashETH between
        // the staging record and the standing write is therefore recognizable by FULL KEYS, and a NEW generation
        // number can no longer confer provenance on an identity that already stood.*
        let staged = MeshIdentity.generateStaged()
        let staging = WipeIdentityPublication(identity: staged.identity, generation: wipeGeneration)
        guard writePublication(staging) else {          // the durable staging record (checked)
            current = nil
            return nil
        }
        do {
            let standing = try MeshIdentity.promoteStaged(state: staged.state, keychain: keychain)
            // The promoted identity MUST reproduce the staged pair: anything else is a refusal.
            guard staging.matches(standing) else {
                current = nil
                return nil
            }
            // *** CURRENT-04: A CRASH BETWEEN THE FLOOR RAISE AND THE PHASE WRITE IS REPAIRED HERE. *** *When the
            // staging record's generation no longer equals what stands (a previous attempt raised the floor and died
            // before the phase landed), the SAME staged pair is re-written under this generation, so phase and floor
            // agree again -- which is what the settled/admission roads require.*
            if let existing = readPublication(), existing.generation != wipeGeneration,
               existing.matches(standing) {
                _ = writePublication(staging)
            }
            current = staging.hint
            return staging.hint
        } catch MeshError.identityAlreadyExists {
            // *** A FOREIGN STANDING KEY IS REFUSED. *** *Only a standing identity that IS the staged pair (the
            // interrupted publication of THIS replacement) may be adopted -- which `promoteStaged` already enforces,
            // so this branch is the refusal road rather than an adoption.*
            current = nil
            return nil
        } catch {
            current = nil
            return nil
        }
    }

    public func identity() -> String? {
        lock.lock(); defer { lock.unlock() }
        if let current { return current }
        guard let loaded = try? loadStandingIdentity() else { return nil }
        current = Self.hint(of: loaded)
        return current
    }

    /// The identity's NAME FOR THE WIPE'S JOURNAL: its node hint, hex-encoded.
    static func hint(of identity: MeshIdentity) -> String? {
        let hint = identity.nodeHint
        guard !hint.isEmpty else { return nil }
        return hex(hint)
    }

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
}

/// *** IOS-FOLLOWUP-C7: THE FULL PUBLICATION ASSOCIATION -- GENERATION + THE COMPLETE PUBLIC KEYS. ***
///
/// *A 4-byte hint cannot distinguish the exact replacement from a re-introduced key; this carrieth BOTH public keys
/// (signing + static DH), and `matches` compareth them in full.*
public struct WipeIdentityPublication: Equatable, Sendable {
    public let generation: UInt64
    public let hint: String
    public let signingPublicKeyHex: String
    public let staticDhPublicKeyHex: String

    public init(generation: UInt64, hint: String, signingPublicKeyHex: String, staticDhPublicKeyHex: String) {
        self.generation = generation
        self.hint = hint
        self.signingPublicKeyHex = signingPublicKeyHex
        self.staticDhPublicKeyHex = staticDhPublicKeyHex
    }

    public init(identity: MeshIdentity, generation: UInt64) {
        self.generation = generation
        self.hint = WipeIdentityAuthoritySeam.hint(of: identity) ?? ""
        self.signingPublicKeyHex = WipeIdentityAuthoritySeam.hex(identity.signingPublicKey)
        self.staticDhPublicKeyHex = WipeIdentityAuthoritySeam.hex(identity.staticDhPublicKey)
    }

    /// *** FULL VERIFICATION: the standing identity must reproduce BOTH public keys exactly. ***
    public func matches(_ identity: MeshIdentity) -> Bool {
        signingPublicKeyHex == WipeIdentityAuthoritySeam.hex(identity.signingPublicKey)
            && staticDhPublicKeyHex == WipeIdentityAuthoritySeam.hex(identity.staticDhPublicKey)
    }
}

/// *** THE DURABLE PUBLICATION RECORD, KEYCHAIN-BACKED, WITH A CHECKED WRITE AND AN INTENT MARKER. ***
///
/// *Encoding: `gen|hint|signingHex|staticHex` for the publication, and `intent:gen` for the pre-publication intent.
/// Both live in the SAME keychain the identity liveth in, so they surviveth a crash exactly as the identity does.*
internal final class KeychainWipePublicationRecord {
    internal static let tag = "io.godstone.mesh.identity.wipe-publication"
    internal static let intentTag = "io.godstone.mesh.identity.wipe-publication-intent"
    private let keychain: any LocalIdentityKeychain

    internal init(keychain: any LocalIdentityKeychain) { self.keychain = keychain }

    internal func read() -> WipeIdentityPublication? {
        guard let data = try? keychain.read(tag: Self.tag),
              let raw = String(data: data, encoding: .utf8) else { return nil }
        let parts = raw.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 4, let generation = UInt64(parts[0]), !parts[1].isEmpty else { return nil }
        return WipeIdentityPublication(generation: generation, hint: String(parts[1]),
                                       signingPublicKeyHex: String(parts[2]),
                                       staticDhPublicKeyHex: String(parts[3]))
    }

    /// *** IOS-FOLLOWUP-C7: THE CHECKED DUPLICATE/UPDATE LIFECYCLE. *** *A SecItemAdd-only road made the SECOND
    /// wipe's publication fail as a duplicate (the first wipe's record survives identity deletion), so the write
    /// either went stale or was swallowed. Upsert IS the update lifecycle -- and `true` answereth only when the
    /// written bytes READ BACK EQUAL the intended record: a keychain that stored something else is a refusal.*
    @discardableResult
    internal func write(_ publication: WipeIdentityPublication) -> Bool {
        let raw = "\(publication.generation)|\(publication.hint)|\(publication.signingPublicKeyHex)|\(publication.staticDhPublicKeyHex)"
        let expected = Data(raw.utf8)
        do {
            try keychain.upsert(tag: Self.tag, data: expected)
            return try keychain.read(tag: Self.tag) == expected
        } catch {
            return false
        }
    }

    internal func readIntent() -> UInt64? {
        guard let data = try? keychain.read(tag: Self.intentTag),
              let raw = String(data: data, encoding: .utf8),
              raw.hasPrefix("intent:") else { return nil }
        return UInt64(raw.dropFirst("intent:".count))
    }

    /// *** CHECKED UPSERT + READ-BACK (IOS-FOLLOWUP-C7), same law as the publication itself. ***
    @discardableResult
    internal func writeIntent(_ generation: UInt64) -> Bool {
        let expected = Data("intent:\(generation)".utf8)
        do {
            try keychain.upsert(tag: Self.intentTag, data: expected)
            return try keychain.read(tag: Self.intentTag) == expected
        } catch {
            return false
        }
    }
}
