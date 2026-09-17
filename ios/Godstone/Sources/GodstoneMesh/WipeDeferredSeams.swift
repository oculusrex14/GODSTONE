import Foundation

/// GS-STORE-006: **THE EFFECTFUL SEAMS FOR A RUNTIME THAT DOES NOT YET STAND.** `MeshRuntime.create` performeth the
/// startup resume BEFORE the runtime object existeth -- so at that moment IT OWNETH NO PLATFORM RESOURCE: not the
/// transport, not the keychain, not the database handles. THE CREATE-TIME RESUME MUST THEREFORE DEFER **EVERY** EFFECTFUL
/// SEAM, not only the transport's, AND THESE TWO ARE THE ONES THAT REMAINED:
///
///   * THE IDENTITY AUTHORITY: the live one calls `MeshIdentity.generateAndStore()` -- and a measured run showed the
///     ladder hanging when a composition that CARRIED A PENDING WIPE was created, the Keychain being precisely the kind of
///     API that BLOCKS rather than fails on the host. THE DEFERRED ONE NEVER TOUCHES IT.
///   * THE KEY VAULT: the live one erases DEKs and identity keys. THE DEFERRED ONE ERASES NOTHING.
///
/// BOTH ANSWER **NAMED, RETRYABLE PENDING** RESULTS, WHICH STOP THE LADDER BEFORE `KEYS_ERASED` -- EXACTLY WHERE A PROCESS
/// THAT HATH NOT YET OPENED ITS STORES MUST STOP, AND EXACTLY WHAT THE CARD'S STEP 6 SAYETH: "on restart, resume from the
/// durable compatible journal BEFORE opening keys, databases, discovery or a new identity." THE RUNTIME THAT LATER STANDS
/// RESUMETH WITH THE LIVE SEAMS, AND BECAUSE THE JOURNAL CARRIETH EACH STAGE, THE SECOND ATTEMPT CANNOT MISTAKE WORK NOT
/// DONE FOR WORK ALREADY DONE.

/// The identity authority of a runtime that does not yet stand. It PUBLISHETH NOTHING.
public final class WipeDeferredIdentityAuthoritySeam: IdentityAuthoritySeam {
    public static let reason = "the runtime does not yet stand: no identity may be published at the startup resume"

    public init() {}

    /// IT NAMETH ITS OWN ABSENCE RATHER THAN INVENTING A NAME: the ladder records `NEW_IDENTITY` only when this is
    /// called, and the caller's journal then carrieth a state that SAYS the identity was not published.
    public func publishNewIdentity() -> String { Self.reason }

    /// NO IDENTITY STANDS AT THIS MOMENT -- and `nil` is exactly the seam's own vocabulary for that.
    public func identity() -> String? { nil }
}

/// The key vault of a runtime that does not yet stand. It ERASETH NOTHING.
public final class WipeDeferredKeyVaultSeam: KeyVaultSeam {
    public static let reason = "the runtime does not yet stand: no key may be erased at the startup resume"

    public init() {}

    /// A NAMED, RETRYABLE PENDING FAILURE FOR EVERY KEY -- never `.deleted` (a claim about an act nobody performed) and
    /// never `.absent` (a lie about a key nobody asked for). THE WIPE STAYETH PENDING, which is what the card requireth of
    /// a failed key operation, and `KEYS_ERASED` stayeth unreachable until the runtime that stands owns the vault.
    public func eraseKey(_ name: String) -> KeyDeletionResult {
        return .failed(keyName: name, retryable: true, reason: Self.reason)
    }
}
