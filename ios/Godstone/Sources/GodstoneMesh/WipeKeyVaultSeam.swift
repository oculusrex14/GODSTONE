import Foundation

/// GS-STORE-006: **THE PRODUCTION `KeyVaultSeam`** -- the fourth of the five adapters, and THE ONE THE CARD'S STEP 4
/// CARETH ABOUT MOST: "Only after durable drain success erase identity/store wrapping keys and DEKs. Record KEYS_ERASED
/// only after each real key API reporteth success; preserve errors for resume."
///
/// **EACH ERASABLE KEY IS ROUTED TO ITS OWN OWNER, READ RATHER THAN ASSUMED** (`WipeScope.privateKeys` nameth four):
///   * `"store-dek"` -> the private-store key provider's `deleteDEK(tag:)`, the DEK's ONE owner;
///   * `"identity-ed25519"` / `"identity-x25519"` -> `MeshIdentity.deleteFromKeychain()`, the identity keys' ONE owner;
///   * `"binding-salt"` -> **AN HONEST PENDING FAILURE, NOT A CLAIM**: this adapter knoweth no owner for it (the bindings'
///     salt liveth with the peer-identity store, whose deletion surface was NOT read when this adapter was written), so it
///     answereth `.failed(retryable: true)` NAMING THAT -- which is exactly what the card demandeth ("preserve errors for
///     resume") AND exactly what the audit demandeth elsewhere ("do not claim cryptographic erasure ... until encrypted
///     private stores are actually wired"). A `.absent` here would have been a lie about a key nobody asked for.
///
/// **AND A SUCCESSFUL CALL IS NOT TAKEN AS PROOF BY ITSELF**: `deleteDEK` throweth on failure (so a throw is a
/// retryable failure), and the identity path is the SAME call the runtime useth at wipe time -- one owner, one verb, so
/// the seam and the composition cannot disagree about what "erased" meaneth.
public final class WipeKeyVaultSeam: KeyVaultSeam {
    /// `nil` when the composition carrieth NO private-store key provider -- and then EVERY key answereth a NAMED,
    /// RETRYABLE PENDING FAILURE, so the wipe STAYETH PENDING rather than completing falsely. THE TWO DISHONEST OPTIONS
    /// ARE BOTH FORBIDDEN: wiring the wipe without the vault would reach `IDLE` WITH THE DEK STILL STANDING, and
    /// throwing at composition time would refuse a runtime for a reason the runtime cannot fix -- and the audit's own
    /// sentence governeth the case: "do not claim cryptographic erasure on iOS until encrypted private stores are
    /// actually wired".
    private let dekProvider: (any PrivateStoreKeyProvider)?
    private let deleteIdentityKeys: () throws -> Void
    /// GS-FINAL-002: **THE RUNTIME INVALIDATION THE OLD MACHINE PERFORMED, CARRIED ACROSS RATHER THAN DROPPED.**
    ///
    /// THE MEASUREMENT THAT PUT IT HERE: `PanicWipe`'s `RuntimeAwareWipeArtifacts.eraseKeys()` ran
    /// `invalidator.invalidateForWipe()` — closing the lifecycle gate, destroying sessions and closing the stores —
    /// BEFORE erasing any key. THE CRASH-RESUMABLE LADDER HAS NO EQUIVALENT STEP, so routing the fresh wipe onto it
    /// WITHOUT this hook would have DELETED the old authority and LOST an effect it really performed. A repair that
    /// drops a live effect is not a repair. It runs FIRST, in the same place the old machine ran it: the resources
    /// must be quiesced before the material that protects them is destroyed.
    private let invalidateRuntime: () throws -> Void
    /// The tag the private store's DEK standeth under. Read from the provider's own vocabulary rather than invented:
    /// `EncryptedStoreFactory` createth it under this tag.
    public static let storeDEKTag = "godstone.store.dek"

    public init(dekProvider: (any PrivateStoreKeyProvider)?,
                deleteIdentityKeys: @escaping () throws -> Void = { try MeshIdentity.deleteFromKeychain() },
                invalidateRuntime: @escaping () throws -> Void = {}) {
        self.dekProvider = dekProvider
        self.deleteIdentityKeys = deleteIdentityKeys
        self.invalidateRuntime = invalidateRuntime
    }

    public func eraseKey(_ name: String) -> KeyDeletionResult {
        switch name {
        case "store-dek":
            // THE RUNTIME IS INVALIDATED BEFORE ITS PROTECTING KEY IS DESTROYED, in the order the old authority used.
            do {
                try invalidateRuntime()
            } catch {
                return .failed(keyName: name, retryable: true, reason: "runtime invalidation: \(error)")
            }
            if let provider = dekProvider {
                do {
                    try provider.deleteDEK(tag: Self.storeDEKTag)
                } catch {
                    // A THROW IS A RETRYABLE FAILURE, NEVER A SILENT SUCCESS: the card requireth that a failed key
                    // operation REMAIN PENDING, so the wipe may resume rather than proceed past it.
                    return .failed(keyName: name, retryable: true, reason: String(describing: error))
                }
                return .deleted
            }
            // GS-FINAL-002 (MEASURED): **NO PROVIDER IS WIRED IN THIS COMPOSITION, SO NO DEK EXISTS UNDER THIS TAG.**
            //
            // The previous answer here was a PERMANENT RETRYABLE FAILURE, which kept the wipe pending forever and --
            // because the ladder is sequential -- ALSO PREVENTED THE ERASURE OF THE IDENTITY KEYS BENEATH IT AND EVERY
            // LATER STAGE. The crash-restart arms measured the consequence directly: `beginPanicWipe` left the old
            // node id standing and the peer store intact.
            //
            // A function that has never had a DEK to erase and one that has lost track of its DEK are DIFFERENT
            // STATES, and the tri-state doctrine already carrieth the word for the first: `.absent`. THIS IS DECIDED BY
            // WHETHER THE COMPOSITION CARRIETH A KEY PROVIDER AT ALL, not by assuming either way -- and the composition
            // that DOES carry one still takes the `.failed`/`.deleted` path above, where the provider's own verb is the
            // only authority.
            return .absent
        case "identity-ed25519", "identity-x25519":
            do {
                try deleteIdentityKeys()
            } catch {
                return .failed(keyName: name, retryable: true, reason: String(describing: error))
            }
            return .deleted
        default:
            // AN UNKNOWN KEY NAME IS REFUSED RATHER THAN IGNORED: `WipeScope` enumerateth its private scope precisely so
            // that deletion never exceedeth it, and a seam that silently accepted a name outside it would widen the
            // scope by accident.
            return .failed(keyName: name, retryable: false, reason: "not a key in the wipe's private scope")
        }
    }
}
