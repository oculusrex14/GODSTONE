package io.godstone.app.ui.trust

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Card
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import io.godstone.app.trust.ContactProjection
import io.godstone.app.trust.ContactTrustLabel
import io.godstone.app.trust.IdentityTrustViewModel
import io.godstone.app.trust.TrustCensus
import io.godstone.app.trust.TrustUiState
import io.godstone.app.trust.WipeProgressState

// ---------------------------------------------------------------------------
// T55 -- the Compose projections.
//
// Every screen is a pure function of [TrustUiState]: nothing here reacheth a
// repository, a port or a store. That is what maketh the ViewModel's projection
// the single source of what the user seeth, and what letteth the court judge the
// same state object the screen would render.
//
// THE SECRET-BEARING SCREEN: [OwnIdentityCard] showeth the QR payload, which is
// public binding material but is also a durable impersonation aid if captured.
// The screen therefore declarest [TrustUiState.redacted] as its screenshot policy
// through [screenshotProtectionWanted], and the Activity applieth FLAG_SECURE from
// that answer -- the policy liveth with the state, not with the Activity's mood.
//
// No screen rendereth key material: a fingerprint is a public digest and the QR
// payload is the public binding string; neither carrieth a private key.
// ---------------------------------------------------------------------------

/** True iff the screen showing [state] wanteth FLAG_SECURE (no screenshots). */
fun screenshotProtectionWanted(state: TrustUiState): Boolean =
    state.redacted || state.own != null

/** A stable tag a UI test can find the trust list by. */
const val TRUST_LIST_TAG = "trust-list"
const val OWN_IDENTITY_TAG = "own-identity"
const val WIPE_STATE_TAG = "wipe-state"

@Composable
fun TrustScreen(viewModel: IdentityTrustViewModel, modifier: Modifier = Modifier) {
    // *** GS-UX-001 STEP 3 (round 540): COLLECTED **WITH LIFECYCLE**, WHICH IS THE CARD'S OWN CLAUSE. ***
    // MEASURED BEFORE THIS EDIT: the screen read `uiState()` ONCE -- a SNAPSHOT -- so a durable event
    // could not reach it. The idiom is this app's own (`BrowseScreen.kt:37`).
    val state by viewModel.flow.collectAsStateWithLifecycle()
    TrustContent(state, modifier)
}

/** The stateless projection: the court can render or inspect the SAME state. */
@Composable
fun TrustContent(state: TrustUiState, modifier: Modifier = Modifier) {
    Column(modifier = modifier.padding(16.dp)) {
        OwnIdentityCard(state)
        state.error?.let { message ->
            Card(Modifier.fillMaxWidth().padding(vertical = 8.dp)) {
                Text("Problem: $message", color = MaterialTheme.colorScheme.error,
                    modifier = Modifier.padding(12.dp))
            }
        }
        WipeBanner(state.wipe)
        when (val census = state.census) {
            is TrustCensus.Corrupt -> Text(
                "The trust store cannot be read: ${census.reason}. No contact is claimed.",
                color = MaterialTheme.colorScheme.error,
            )
            is TrustCensus.Unavailable -> Text("Trust is unavailable: ${census.reason}")
            is TrustCensus.Readable -> ContactList(census.contacts)
        }
    }
}

@Composable
private fun OwnIdentityCard(state: TrustUiState) {
    val own = state.own ?: return
    Card(Modifier.fillMaxWidth().testTag(OWN_IDENTITY_TAG)) {
        Column(Modifier.padding(12.dp)) {
            Text("Your fingerprint", style = MaterialTheme.typography.titleMedium)
            Text(own.fingerprintHex.chunked(4).joinToString(" "))
            Text("Show this code to a contact so they can bind you exactly.")
        }
    }
}

@Composable
private fun ContactList(contacts: List<ContactProjection>) {
    Column(Modifier.fillMaxWidth().testTag(TRUST_LIST_TAG)) {
        for (contact in contacts) {
            Card(Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
                Column(Modifier.padding(12.dp)) {
                    Text(contact.label, style = MaterialTheme.typography.titleSmall)
                    Text(trustLabel(contact.trust))
                    Text(contact.fingerprintHex.chunked(4).joinToString(" "))
                    contact.pendingRotation?.let { ref ->
                        Text(
                            "A new key is offered (generation ${ref.pendingGeneration}). " +
                                "Compare it before approving.",
                            color = MaterialTheme.colorScheme.tertiary,
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun WipeBanner(wipe: WipeProgressState) {
    when (wipe) {
        is WipeProgressState.Idle -> Unit
        is WipeProgressState.Complete -> Text(
            "Wipe complete. No local estate remains.",
            modifier = Modifier.testTag(WIPE_STATE_TAG),
        )
        is WipeProgressState.InProgress -> Column(Modifier.testTag(WIPE_STATE_TAG)) {
            LinearProgressIndicator(Modifier.fillMaxWidth())
            Text("Wiping: ${wipe.stage} (attempt ${wipe.attempt})")
            if (wipe.resumable) {
                Text("This wipe did not finish. It will resume on the next launch.")
            }
            wipe.lastError?.let { Text("Last error: $it", color = MaterialTheme.colorScheme.error) }
        }
    }
}

/** The user-facing words for a trust label. Verified and TOFU must never look alike. */
fun trustLabel(trust: ContactTrustLabel): String = when (trust) {
    ContactTrustLabel.USER_VERIFIED -> "Verified: you compared this fingerprint."
    ContactTrustLabel.TOFU_UNVERIFIED -> "Not verified: trusted on first use only."
    ContactTrustLabel.ROTATION_PENDING -> "A new key is offered; the old one still stands."
    ContactTrustLabel.REVOKED -> "Revoked: this contact is blocked."
    ContactTrustLabel.CORRUPT -> "Unreadable: nothing is claimed about this contact."
    ContactTrustLabel.UNKNOWN -> "Unknown contact."
}
