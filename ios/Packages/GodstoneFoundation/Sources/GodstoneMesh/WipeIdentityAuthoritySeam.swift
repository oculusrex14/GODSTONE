import Foundation

/// GS-STORE-006: **THE PRODUCTION `IdentityAuthoritySeam`** -- the FIFTH AND LAST of the adapters the finding's card
/// requireth, and the one the ladder's last rung becometh: `NEW_IDENTITY`, after which the node rejoins the mesh as a
/// STRANGER, because the keys that made it who it was are gone.
///
/// **IT USETH THE IDENTITY PATH'S OWN VERBS, READ RATHER THAN ASSUMED** (`MeshIdentity.generateAndStore()`,
/// `loadFromKeychain()`, and `nodeHint`): so the identity path and the wipe path cannot disagree about what "a new
/// identity" meaneth -- the same discipline as every other adapter here.
///
/// **AND IT NAMETH ITS OWN FAILURE RATHER THAN INVENTING A SUCCESS.** The seam's signature demandeth a `String`, and
/// `generateAndStore()` throweth; so a failed generation answereth a name that SAYETH SO, and the journal then carrieth
/// the truth. Returning a plausible-looking identifier for an identity that was never created would be the worst kind of
/// lie in this file: THE WIPE WOULD PROCEED TO `IDLE` BELIEVING THE NODE HAD A NEW IDENTITY WHEN IT HAD NONE.
public final class WipeIdentityAuthoritySeam: IdentityAuthoritySeam {
    private let lock = NSLock()
    private var current: String?
    /// GS-FINAL-002: **THE REGENERATION THE OLD PATH PERFORMED, CARRIED ACROSS RATHER THAN DROPPED.**
    ///
    /// `PanicWipe`'s `KeychainWipeArtifacts.regenerateIdentity()` called `MeshIdentity.generateAndStore(keychain:)`
    /// -- with the FIXED default keychain, ignoring whatever keychain the composition had been given. The ladder's
    /// last rung needs the same effect, and the composition now supplies it WITH ITS OWN KEYCHAIN, which is both the
    /// carried-across effect and a correction of the old path's own inconsistency.
    private let regenerateIdentity: () throws -> MeshIdentity

    /// The name recorded when the identity could not be published. It sayeth what happened; it is not an identifier.
    public static let generationFailedName = "identity-generation-failed"

    /// *** THE FIRST DRAFT OF THIS REPAIR SPLIT ONE ACT INTO TWO, AND MEASURED ITS OWN BUG (round 548). ***
    ///
    /// It called the injected `regenerateIdentity()` and then read the result back with `MeshIdentity.loadFromKeychain()`
    /// -- WHICH USES THE *DEFAULT* KEYCHAIN. In production those are the same keychain, so the split was invisible; under
    /// a test composition they are not, and the ladder answered `retryLater(at: .artifactsDeleted, reason: "no identity
    /// could be published")` AFTER the keys had already been erased. A regenerate that does not say WHAT it regenerated
    /// forces its caller to go and guess, and the guess reads a different store.
    ///
    /// ONE VERB, ONE ANSWER: the closure returns the identity it published, and the seam never loads anything.
    public init(regenerateIdentity: @escaping () throws -> MeshIdentity = { try MeshIdentity.generateAndStore() }) {
        self.regenerateIdentity = regenerateIdentity
    }

    public func publishNewIdentity() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let identity = try? regenerateIdentity() else {
            // THE TYPED REFUSAL: `nil`, NOT a name that says what happened -- because the CALLER must be able to tell a
            // refusal from a success, and prose cannot be told apart from an identifier.
            current = nil
            return nil
        }
        current = Self.name(of: identity)
        return current ?? Self.generationFailedName
    }

    public func identity() -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let current { return current }
        guard let loaded = try? MeshIdentity.loadFromKeychain() else { return nil }
        current = Self.name(of: loaded)
        return current
    }

    /// The identity's NAME FOR THE WIPE'S JOURNAL: its node hint, hex-encoded -- the same four bytes this mesh elects
    /// on, so the recorded name is something the runtime itself could recognise rather than an opaque token invented
    /// here.
    private static func name(of identity: MeshIdentity) -> String {
        return identity.nodeHint.map { String(format: "%02x", $0) }.joined()
    }
}
