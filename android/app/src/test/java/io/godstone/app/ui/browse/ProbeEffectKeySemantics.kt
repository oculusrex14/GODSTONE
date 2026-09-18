package io.godstone.app.ui.browse

import androidx.compose.foundation.clickable
import androidx.compose.material3.Text
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * *** A RE-RUNNABLE PROOF OF A FRAMEWORK SEMANTIC THAT A DESIGN DECISION RESTS ON. ***
 *
 * WHY THIS FILE IS KEPT RATHER THAN A COMMENT: a review warned that `val ids = state.passages.map { it.chunkId }`
 * buildeth a fresh `List` on every recomposition, that `LaunchedEffect` keys "compare Lists by reference", and
 * therefore that the reading list's report effect would RESTART ITSELF through its own `vm.noteScroll` write --
 * resetting `previous`/`placementLanded`, RE-LOCKING THE GATE, and silently dropping the reader's later scrolls. On
 * that premise it prescribed hoisting the derivation (`remember(state.passages) { ... }`) as the fix.
 *
 * **THE PREMISE IS FALSE, AND THIS PROBE IS THE EVIDENCE: `LaunchedEffect` KEYS COMPARE WITH STRUCTURAL EQUALITY,
 * NOT BY REFERENCE.** A comment asserting that would be worth nothing -- this programme has paid repeatedly for
 * comments that claimed behaviour nobody measured. So the probe is KEPT, re-runnable, and it CHECKS ITSELF.
 *
 * *** AND THE PROBE CHECKS ITSELF BECAUSE MY FIRST VERSION DID NOT, WHICH IS THE WHOLE POINT. *** That version
 * observed `starts == 1` and I recorded "the premise is refuted". A review pointed out THE HOLE: if the click had
 * never re-executed the scope that OWNETH the `LaunchedEffect`, `starts` would ALSO have stayed 1 -- **and "the
 * effect never got a chance to re-fire" is a DIFFERENT CLAIM from "a fresh-equal List key does not re-fire".**
 * Both render as `1`. So the first probe could not have gone red even if the premise were true: **A GREEN PROBE THAT
 * WAS NEVER CAPABLE OF GOING RED IS THE SAME FALSE ASSURANCE THIS PROGRAMME KEEPS FINDING, ONE LAYER UP.**
 *
 * HENCE THREE CASES, AND THE FIRST ONE IS THE CONTROL THAT MAKES THE OTHER TWO MEANINGFUL:
 *
 *   1. POSITIVE CONTROL -- keyed on a genuinely CHANGING value: the effect MUST restart.
 *      **IF THIS DOES NOT RESTART, THE SCOPE IS NOT RECOMPOSING, THE PROBE IS INERT, AND CASE 3 PROVES NOTHING.**
 *   2. KEYED ON GENUINELY DIFFERENT CONTENT (a List, fresh instance, different elements): MUST restart.
 *   3. NULL CONTROL -- keyed on a fresh instance with CONTENT-EQUAL elements: must NOT restart. THIS IS THE CLAIM.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33])
class ProbeEffectKeySemantics {

    @get:Rule val compose = createComposeRule()

    /**
     * *** CASE 1: THE POSITIVE CONTROL. WITHOUT THIS THE WHOLE PROBE IS WORTHLESS. ***
     *
     * The effect is keyed on `tick` ITSELF -- a value that changes on every click -- so if the composable scope really
     * re-executes, the effect MUST restart. **A FAILURE HERE MEANS THE RIG IS INERT AND CASE 3 CANNOT BE TRUSTED.**
     */
    @Test
    fun positiveControlAChangingKeyRestartsTheEffect() {
        var starts = 0
        var tick by mutableStateOf(0)

        compose.setContent {
            LaunchedEffect(tick) { starts++ }
            Text("tick $tick", modifier = Modifier.clickable { tick++ })
        }
        compose.waitForIdle()
        val afterFirst = starts

        compose.onNodeWithText("tick 0").performClick()
        compose.waitForIdle()

        assertEquals(
            "*** THE POSITIVE CONTROL MUST REDDEN-PROVE: a key that GENUINELY CHANGES must restart the effect. If " +
                "this stays at its initial value, THE SCOPE IS NOT RECOMPOSING, the probe is inert, and the " +
                "content-equal case below would prove nothing. starts: $afterFirst -> $starts ***",
            afterFirst + 1, starts,
        )
    }

    /** *** CASE 2: A FRESH LIST WITH GENUINELY DIFFERENT CONTENT MUST RESTART THE EFFECT. *** */
    @Test
    fun aListKeyWithDifferentContentRestartsTheEffect() {
        var starts = 0
        var tick by mutableStateOf(0)

        compose.setContent {
            // A FRESH INSTANCE EVERY COMPOSITION, AND ITS CONTENT CHANGES WITH `tick`.
            val ids = listOf(1L, 2L, tick.toLong() + 3L)
            LaunchedEffect(ids) { starts++ }
            Text("tick $tick", modifier = Modifier.clickable { tick++ })
        }
        compose.waitForIdle()
        val afterFirst = starts

        compose.onNodeWithText("tick 0").performClick()
        compose.waitForIdle()

        assertEquals(
            "a key whose CONTENT really changed must restart the effect -- the other half of the control",
            afterFirst + 1, starts,
        )
    }

    /**
     * *** CASE 3: THE CLAIM. A FRESH INSTANCE WITH CONTENT-EQUAL ELEMENTS MUST **NOT** RESTART THE EFFECT. ***
     *
     * `val ids = listOf(1L, 2L, 3L)` IS REBUILT ON EVERY COMPOSITION AND IS **NEVER** REFERENTIALLY EQUAL TO THE
     * LAST ONE. If `LaunchedEffect` compared keys by reference this would restart; it does not, because keys compare
     * with **STRUCTURAL EQUALITY**. **THIS IS WHY `val ids = state.passages.map { it.chunkId }` IS LEFT UN-MEMOIZED
     * AND WHY NO `remember(state.passages) { ... }` HOIST WAS ADDED: MEASUREMENT SHOWS THERE IS NO BUG TO FIX.**
     *
     * AND THE PROBE IS VALID ONLY BECAUSE CASE 1 PASSED -- it proveth the scope really re-executes, so `starts`
     * staying put here is structural equality doing its work rather than a rig that never ran.
     */
    @Test
    fun aFreshListKeyWithEqualContentDoesNotRestartTheEffect() {
        var starts = 0
        var tick by mutableStateOf(0)
        var recompositions = 0

        compose.setContent {
            recompositions++
            val ids = listOf(1L, 2L, 3L)          // A FRESH INSTANCE, CONTENT-IDENTICAL, EVERY TIME
            LaunchedEffect(ids) { starts++ }
            Text("tick $tick", modifier = Modifier.clickable { tick++ })
        }
        compose.waitForIdle()
        val afterFirst = starts
        val recompositionsAfterFirst = recompositions

        compose.onNodeWithText("tick 0").performClick()
        compose.waitForIdle()

        // THE RIG'S OWN WITNESS THAT THE SCOPE REALLY RE-EXECUTED -- so the assertion below cannot pass vacuously.
        assertTrue(
            "*** THE SCOPE MUST REALLY HAVE RE-EXECUTED (recompositions: $recompositionsAfterFirst -> " +
                "$recompositions). WITHOUT THIS, `starts` STAYING PUT WOULD MEAN 'NOTHING RAN', NOT 'STRUCTURAL " +
                "EQUALITY HELD' -- THE EXACT CONFOUND A REVIEW CAUGHT IN MY FIRST PROBE. ***",
            recompositions > recompositionsAfterFirst,
        )

        assertEquals(
            "*** A FRESH, CONTENT-EQUAL `List` KEY MUST NOT RESTART THE EFFECT -- `LaunchedEffect` KEYS COMPARE WITH " +
                "STRUCTURAL EQUALITY, NOT BY REFERENCE. This is the measurement that refuted the self-restart " +
                "premise and that justifies leaving `val ids = state.passages.map { it.chunkId }` un-memoized. " +
                "starts: $afterFirst -> $starts, recompositions: $recompositionsAfterFirst -> $recompositions ***",
            afterFirst, starts,
        )
    }
}
