package io.godstone.mesh.identity

/**
 * GS-STORE-006: **THE PRODUCTION `KeyVaultSeam` FOR THIS ISLE** -- the card's step 4, which reads: "Only after durable drain
 * success erase identity/store wrapping keys and DEKs. Record KEYS_ERASED only after each real key API reporteth success;
 * preserve errors for resume."
 *
 * **IT ROUTES TO THE ISLE'S OWN OWNER RATHER THAN INVENTING ONE.** On this isle the material has ONE destroyer --
 * `WipeArtifacts.eraseKeys()`, documented as "**Destroy the KEK. After this, encrypted artifacts are unrecoverable**" -- and
 * the KEK it destroys is the one that protects everything, the identity included (the isle's own words, from
 * `regenerateIdentity`: "a fresh identity (**and the KEK that protects it**)"). So this seam does NOT carry iOS's per-key
 * routing, WHICH WOULD HAVE BEEN A TRANSPLANT OF THE OTHER ISLE'S STRUCTURE: here every name the coordinator asks for is
 * answered by the ONE step that genuinely owns the erasure.
 *
 * **AND IT IS NAME-AGNOSTIC ON PURPOSE**: the coordinator owneth the key vocabulary, and this adapter does not second-guess
 * it -- it neither rejects a name it does not recognise NOR pretends a name was erased when no step ran. A THROW FROM THE
 * OWNER BECOMES A RETRYABLE FAILURE NAMING THE KEY, so the wipe stays PENDING and may resume, exactly as the card requires
 * ("preserve errors for resume").
 */
class WipeKeyVaultSeam(private val artifacts: WipeArtifacts) : KeyVaultSeam {

    override fun eraseKey(name: String): KeyDeletionResult {
        return try {
            artifacts.eraseKeys()
            // THE OWNER'S OWN VERDICT IS THE VERDICT: no exception means the KEK is gone, and the caller's journal may
            // therefore record KEYS_ERASED.
            KeyDeletionResult.Deleted
        } catch (e: Throwable) {
            // A FAILURE IS PRESERVED FOR RESUME AND NAMETH THE KEY: never a silent success, and never a non-retryable
            // refusal invented by an adapter that cannot know whether the material is recoverable.
            KeyDeletionResult.Failed(keyName = name, retryable = true, reason = e.toString())
        }
    }
}
