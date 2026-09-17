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
    private let dekProvider: any PrivateStoreKeyProvider
    private let deleteIdentityKeys: () throws -> Void
    /// The tag the private store's DEK standeth under. Read from the provider's own vocabulary rather than invented:
    /// `EncryptedStoreFactory` createth it under this tag.
    public static let storeDEKTag = "godstone.store.dek"

    public init(dekProvider: any PrivateStoreKeyProvider,
                deleteIdentityKeys: @escaping () throws -> Void = { try MeshIdentity.deleteFromKeychain() }) {
        self.dekProvider = dekProvider
        self.deleteIdentityKeys = deleteIdentityKeys
    }

    public func eraseKey(_ name: String) -> KeyDeletionResult {
        switch name {
        case "store-dek":
            do {
                try dekProvider.deleteDEK(tag: Self.storeDEKTag)
            } catch {
                // A THROW IS A RETRYABLE FAILURE, NEVER A SILENT SUCCESS: the card requireth that a failed key
                // operation REMAIN PENDING, so the wipe may resume rather than proceed past it.
                return .failed(keyName: name, retryable: true, reason: String(describing: error))
            }
            return .deleted
        case "identity-ed25519", "identity-x25519":
            do {
                try deleteIdentityKeys()
            } catch {
                return .failed(keyName: name, retryable: true, reason: String(describing: error))
            }
            return .deleted
        case "binding-salt":
            // THE HONEST ANSWER FOR A KEY THIS ADAPTER CANNOT REACH: pending, named, retryable -- NEVER `.absent`
            // (which would claim the material is gone) and never `.deleted` (which would claim an act nobody performed).
            return .failed(keyName: name, retryable: true,
                           reason: "the bindings' salt liveth with the peer-identity store, whose deletion surface this adapter was not given")
        default:
            // AN UNKNOWN KEY NAME IS REFUSED RATHER THAN IGNORED: `WipeScope` enumerateth its private scope precisely so
            // that deletion never exceedeth it, and a seam that silently accepted a name outside it would widen the
            // scope by accident.
            return .failed(keyName: name, retryable: false, reason: "not a key in the wipe's private scope")
        }
    }
}
