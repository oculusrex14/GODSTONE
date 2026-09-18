package io.godstone.app.ui.browse

import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * *** GS-FINAL-006 (round 731): THE DOCUMENT KEY'S PRESENCE, GUARDED BECAUSE ITS BEHAVIOUR CANNOT BE WITNESSED. ***
 *
 * **MEASURED, AND THE MEASUREMENT KILLED MY OWN BEHAVIOURAL ARM:** *I wrote
 * `theDocumentKeyIsObservableOnASameDocumentScroll` to force an observable window for
 * `key(state.openedDocumentId)`, then removed the key -- AND MY NEW ARM STAYED GREEN.* **A review had said it could not
 * exist; the mutation confirmed it.**
 *   * the key's effect is to RECREATE the list state, observable ONLY when `openedDocumentId` CHANGES;
 *   * on a cross-document open the target resolves to THE FIRST PASSAGE (0) and the consume-effect's `scrollToItem(0)`
 *     then forces the top REGARDLESS of what was inherited -- *** so the outcome is identical with or without the key ***;
 *   * and the one road where the target can be NON-zero is a SAME-DOCUMENT re-entry, **where `openedDocumentId` did not
 *     change, so the key never fires anyway.**
 *
 * *** THE KEY IS BEHAVIOURALLY UNEXERCISABLE BY CONSTRUCTION. THE ABSENCE OF AN OBSERVABLE WINDOW *IS* THE PROPERTY. ***
 * **"An arm is missing but findable" would be the weaker and FALSE statement** -- *an arm that stays green under the
 * mutation it names is a test of nothing.*
 *
 * **SO THIS COURT GUARDETH THE ONLY THING THAT CAN BE GUARDED: THAT THE KEY IS STILL THERE.** *It is the same remedy
 * this programme uses for a dominated control -- **assert the thing exists, and say plainly that its effect is not
 * observable today.*** *The assertion is COMMENT-STRIPPED, so the long rationale above (which NAMES the key repeatedly)
 * cannot satisfy it.*
 */
class GsFinal006DocumentKeyPresenceTest {

    private val screen = File("src/main/java/io/godstone/app/ui/browse/BrowseScreen.kt")

    /** Strip comments, so a doc block that merely NAMES the key cannot satisfy a check about the CODE. */
    private fun withoutComments(text: String): String =
        text.replace(Regex("""/\*.*?\*/""", RegexOption.DOT_MATCHES_ALL), "")
            .replace(Regex("""//.*"""), "")

    @Test
    fun theDocumentKeyIsPresentEvenThoughItsEffectIsNotObservable() {
        assertTrue("the browse screen must exist at ${screen.absolutePath}", screen.isFile)
        val code = withoutComments(screen.readText())
        assertTrue(
            "*** GS-FINAL-006: `key(state.openedDocumentId)` MUST STAND. It is DOMINATED TODAY -- *a cross-document open " +
                "resolves its target to the first passage and the consume-effect then forces the top, so removing the " +
                "key changes nothing an arm can see* -- **WHICH IS EXACTLY WHY IT NEEDS A STRUCTURAL GUARD: an unobservable " +
                "guarantee is the one a refactor deletes without noticing.** *The key becometh LOAD-BEARING the moment any " +
                "future change resolves a cross-document target to a NON-zero index, and this court is what keepeth it " +
                "alive until that day.* ***",
            code.contains("key(state.openedDocumentId)"),
        )
        // *** AND IT MUST KEY THE LIST STATE SPECIFICALLY -- keying something else would satisfy the string above while
        // protecting nothing.***
        assertTrue(
            "*** AND THE KEY MUST WRAP `rememberLazyListState()` -- the LIST STATE is what must be recreated per " +
                "document. A key around something else would pass the assertion above while protecting nothing. ***",
            Regex("""key\(state\.openedDocumentId\)\s*\{\s*rememberLazyListState\(\)\s*\}""")
                .containsMatchIn(code),
        )
    }
}
