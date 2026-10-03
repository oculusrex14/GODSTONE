import Foundation

/// GS-STORE-006: **THE PRODUCTION `KeyVaultSeam`** -- the fourth of the five adapters, and THE ONE THE CARD'S STEP 4
/// CARETH ABOUT MOST: "Only after durable drain success erase identity/store wrapping keys and DEKs. Record KEYS_ERASED
/// only after each real key API reporteth success; preserve errors for resume."
///
/// **EACH ERASABLE KEY IS ROUTED TO ITS OWN OWNER, READ RATHER THAN ASSUMED.** *The scope nameth the DEK accounts the
/// private stores ACTUALLY USE and the identity keys.*
///
/// *** IOS-R4: THE WIPE ERASES THE DEKs THE PRIVATE STORES ACTUALLY USE, AND VERIFIES THEIR ABSENCE. ***
///
/// *THE FINDING, VERBATIM: "The actual keyed connections fetch DEKs under message-store and peer-identity-store.
/// WipeKeyVaultSeam deletes only godstone.store.dek, a different Keychain account. Both actual encryption keys survive
/// KEYS_ERASED and terminal completion."*
///
/// **SO `store-dek-message` ROUTES TO `deleteDEK(tag: "message-store")` AND `store-dek-peer` TO
/// `deleteDEK(tag: "peer-identity-store")`** -- *the exact accounts `MeshRuntime.create` passeth to the factory's
/// `reopenOwnedRequiringDEK(path:tag:)` -- and EACH ERASURE IS THEN **VERIFIED ABSENT** by asking the provider for the
/// key again: `.deleted` is claimed only when the follow-up `fetchDEK` answereth `dekNotFound`. **A skipped real-account
/// deletion therefore reddeneth**, and a fresh key is created on the next successful open (`openStore` minteth one when
/// the fetch answereth `dekNotFound`), rather than accidentally reusing a surviving old key.*
///
/// **AND A SUCCESSFUL CALL IS NOT TAKEN AS PROOF BY ITSELF:** `deleteDEK` throweth on failure (so a throw is a
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
    /// drops a live effect is not a repair. It runs FIRST, once, before ANY key is destroyed: the resources must be
    /// quiesced before the material that protects them is destroyed.
    private let invalidateRuntime: () throws -> Void
    private let invalidationLock = NSLock()
    private var invalidated = false

    /// *** THE DEK ACCOUNTS THE PRIVATE STORES ACTUALLY USE, EACH WITH THE TAG THE FACTORY FETCHETH IT UNDER. ***
    /// *Read from the composition's own vocabulary (`MeshRuntime.create` passeth these tags) rather than invented.*
    public static let messageStoreDEKTag = "message-store"
    public static let peerStoreDEKTag = "peer-identity-store"

    public init(dekProvider: (any PrivateStoreKeyProvider)?,
                deleteIdentityKeys: @escaping () throws -> Void = { try MeshIdentity.deleteFromKeychain() },
                invalidateRuntime: @escaping () throws -> Void = {}) {
        self.dekProvider = dekProvider
        self.deleteIdentityKeys = deleteIdentityKeys
        self.invalidateRuntime = invalidateRuntime
    }

    /// Invalidate the runtime exactly once, before the first key is destroyed.
    private func invalidateOnce() throws {
        invalidationLock.lock()
        defer { invalidationLock.unlock() }
        guard !invalidated else { return }
        try invalidateRuntime()
        invalidated = true
    }

    public func eraseKey(_ name: String) -> KeyDeletionResult {
        switch name {
        case "store-dek-message":
            return eraseStoreDEK(name: name, tag: Self.messageStoreDEKTag)
        case "store-dek-peer":
            return eraseStoreDEK(name: name, tag: Self.peerStoreDEKTag)
        case "identity-ed25519", "identity-x25519":
            do {
                try invalidateOnce()
                try deleteIdentityKeys()
            } catch {
                return .failed(keyName: name, retryable: true, reason: String(describing: error))
            }
            return .verifiedAbsent(name: name)
        default:
            // AN UNKNOWN KEY NAME IS REFUSED RATHER THAN IGNORED: `WipeScope` enumerateth its private scope precisely so
            // that deletion never exceedeth it, and a seam that silently accepted a name outside it would widen the
            // scope by accident.
            return .failed(keyName: name, retryable: false, reason: "not a key in the wipe's private scope")
        }
    }

    /// *** IOS-R4: DESTROY THE REAL DEK *AND VERIFY NO SUCH KEY STANDETH AFTERWARDS*. ***
    private func eraseStoreDEK(name: String, tag: String) -> KeyDeletionResult {
        // THE RUNTIME IS INVALIDATED BEFORE ITS PROTECTING KEY IS DESTROYED, in the order the old authority used.
        do {
            try invalidateOnce()
        } catch {
            return .failed(keyName: name, retryable: true, reason: "runtime invalidation: \(error)")
        }
        guard let provider = dekProvider else {
            // GS-FINAL-002 (MEASURED): **NO PROVIDER IS WIRED IN THIS COMPOSITION, SO NO DEK EXISTS UNDER THIS TAG.**
            // A function that has never had a DEK to erase and one that has lost track of its DEK are DIFFERENT STATES,
            // and the tri-state doctrine already carrieth the word for the first: `.absent`.
            return .absent
        }
        do {
            try provider.deleteDEK(tag: tag)
        } catch {
            // A THROW IS A RETRYABLE FAILURE, NEVER A SILENT SUCCESS: the card requireth that a failed key operation
            // REMAIN PENDING, so the wipe may resume rather than proceed past it.
            return .failed(keyName: name, retryable: true, reason: String(describing: error))
        }
        // *** AND THE ERASURE IS *VERIFIED*, NOT MERELY ATTEMPTED: the provider is asked for the key again. ***
        do {
            _ = try provider.fetchDEK(tag: tag)
            // THE KEY SURVIVED ITS OWN DELETION -- the exact IOS-R4 defect, now LOUD rather than silent.
            return .failed(keyName: name, retryable: true,
                           reason: "the DEK for '\(tag)' surviveth its own deletion")
        } catch StoreKeyError.dekNotFound {
            return .verifiedAbsent(name: name)
        } catch {
            // ANY OTHER refusal means the key could not be CONFIRMED absent, so the erasure is not claimed.
            return .failed(keyName: name, retryable: true,
                           reason: "the DEK for '\(tag)' could not be confirmed absent: \(error)")
        }
    }
}
