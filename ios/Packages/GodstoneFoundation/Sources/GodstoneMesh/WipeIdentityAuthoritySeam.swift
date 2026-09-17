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

    /// The name recorded when the identity could not be published. It sayeth what happened; it is not an identifier.
    public static let generationFailedName = "identity-generation-failed"

    public init() {}

    public func publishNewIdentity() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let identity = try? MeshIdentity.generateAndStore() else {
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
