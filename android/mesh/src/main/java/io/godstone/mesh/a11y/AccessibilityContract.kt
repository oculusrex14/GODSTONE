package io.godstone.mesh.a11y

// ---------------------------------------------------------------------------
// T60 -- the accessibility contract for this isle.
//
// "Host UI tests do not prove large-text layout, screen-reader operation or
// process-restored truth." So this contract decideth only what a HOST can decide
// from the semantic model -- labels, words, orders, target sizes, mirroring -- and
// sayeth LOUDLY which checks belong to a person (the T74 human audit).
//
// Laws, the same ones the python conductor and the iOS twin own:
//   1. NO COLOUR-ONLY STATE: every state carrieth WORDS as well as a colour token,
//      and no two states share the same words.
//   2. AN ESSENTIAL CONTROL ALWAYS CARRIETH A LABEL at every text scale.
//   3. A STATUS IS NEVER CLIPPED at the largest scale: a truncated status is a
//      false statement about delivery.
//   4. A TOUCH TARGET MEETETH ITS PLATFORM MINIMUM (48dp Android, 44pt iOS), and
//      the essential controls form a CONTIGUOUS reading order a switch can walk.
//   5. RTL MIRRORETH THE LAYOUT, NOT A CONTROL'S MEANING.
//   6. LONG CONTENT FITTETH without clipping an essential label.
// ---------------------------------------------------------------------------

/** Who can decide a check. */
enum class Requirement { AUTOMATED, HUMAN_REQUIRED }

/** The largest scale a host may simulate. */
enum class TextScale {
    DEFAULT, LARGE, LARGEST, LARGEST_ACCESSIBILITY;

    /** The largest scale a host may simulate. */
    val isLargest: Boolean get() = this == LARGEST_ACCESSIBILITY
}

/** The platform, for the numbers that differ. */
enum class A11yPlatform(val touchTargetMinDp: Float, val platformName: String) {
    ANDROID(48f, "android"),
    IOS(44f, "ios"),
}

/** One rendered node, as the contract seeth it: semantics only, no pixels. */
data class UiNode(
    val controlId: String,
    val role: ControlRole,
    val label: String,
    val contentDescription: String,
    val touchWidthDp: Float,
    val touchHeightDp: Float,
    val readingOrder: Int,
    val enabled: Boolean = true,
    val stateWords: String = "",
    val colourToken: String = "",
    val truncated: Boolean = false,
    val mirrored: Boolean = false,
    val mirrorsMeaning: Boolean = false,
    val containerWidthDp: Float = 0f,
    val contentWidthDp: Float = 0f,
)

enum class ControlRole { BUTTON, IMAGE_BUTTON, TEXT_FIELD, TOGGLE, STATIC_TEXT }

/** One check, with the class of requirement that owneth it. */
data class AccessibilityAssertion(
    val assertionId: String,
    val requirement: Requirement,
    val platform: A11yPlatform,
    val textScale: TextScale,
    val rtl: Boolean = false,
    val locale: String = "en",
    val journey: String = "",
)

/** What must survive a process recreation, and who proveth it. */
data class RestorationCheckpoint(
    val checkpointId: String,
    val requirement: Requirement,
    val durableFact: String,
    val survivesAirplaneMode: Boolean,
)

/** A check's verdict: never a bare Boolean, always a reason. */
data class Verdict(val passed: Boolean, val reason: String) {
    companion object {
        fun pass(reason: String) = Verdict(true, reason)
        fun fail(reason: String) = Verdict(false, reason)
    }
}

object AccessibilityContract {
    const val LARGEST_SCALE_NAME: String = "largest_accessibility"

    /** The controls every profile MUST offer, with the label a user readeth. */
    val ESSENTIAL_CONTROLS: Map<String, String> = linkedMapOf(
        "recipient_select" to "Choose a recipient",
        "compose_send" to "Send",
        "sos_arm" to "Distress call",
        "sos_cancel" to "Cancel the distress call",
        "retry" to "Retry",
    )

    /**
     * The WORDS the delivery vocabulary carrieth. They are the SAME words the
     * durable projection speaketh (T43), so a screen can never invent a status --
     * and no two of them read alike, which is what maketh colour a SECOND channel
     * rather than the only one.
     */
    val STATE_WORDS: Map<String, String> = linkedMapOf(
        "QUEUED" to "Queued on this phone",
        "ATTEMPTING" to "On its way; no answer yet",
        "DELIVERED" to "Delivered: the recipient confirmed it",
        "CANCELLED" to "Cancelled",
        "EXPIRED" to "Expired before delivery",
        "FAILED" to "Failed: the phone could not queue it",
    )

    /** A colour token per state; two states MAY share one, never their words. */
    val STATE_COLOUR_TOKEN: Map<String, String> = linkedMapOf(
        "QUEUED" to "outline",
        "ATTEMPTING" to "tertiary",
        "DELIVERED" to "primary",
        "CANCELLED" to "outline",
        "EXPIRED" to "outline",
        "FAILED" to "error",
    )

    /** WCAG AA thresholds. */
    const val CONTRAST_BODY_MIN: Double = 4.5
    const val CONTRAST_LARGE_MIN: Double = 3.0

    /** The spoken words for the hold-to-confirm control (a gesture a reader cannot hold). */
    const val SOS_IDLE_HINT: String = "Hold to place a distress call. It takes two steps."
    const val SOS_ARMED_HINT: String = "Armed. Confirm to place the call, or dismiss to cancel."
    const val SOS_CANCEL_LABEL: String = "Cancel the distress call"
    const val SOS_CONFIRM_LABEL: String = "Confirm and place the distress call"

    // ---- the checks ------------------------------------------------------

    fun checkEssentialControlsLabelled(nodes: List<UiNode>): Verdict {
        val byId = nodes.associateBy { it.controlId }
        for ((controlId, _) in ESSENTIAL_CONTROLS) {
            val node = byId[controlId]
                ?: return Verdict.fail("the essential control '$controlId' is absent")
            if (node.label.isBlank()) return Verdict.fail("$controlId: the visible label is empty")
            if (node.contentDescription.isBlank()) {
                return Verdict.fail("$controlId: a screen reader would read nothing")
            }
        }
        return Verdict.pass("every essential control carrieth a visible label and a description")
    }

    fun checkStatusNeverClipped(nodes: List<UiNode>, scale: TextScale): Verdict {
        for (node in nodes) {
            if (node.stateWords.isNotEmpty() && node.truncated) {
                return Verdict.fail(
                    "${node.controlId}: the status '${node.stateWords}' is CLIPPED at " +
                        scale.name.lowercase())
            }
        }
        return Verdict.pass("every status survives the largest text scale whole")
    }

    fun checkNoColourOnlyState(nodes: List<UiNode>): Verdict {
        if (STATE_WORDS.values.toSet().size != STATE_WORDS.size) {
            return Verdict.fail("two states share the SAME words")
        }
        for (node in nodes) {
            if (node.stateWords.isEmpty() && node.colourToken.isEmpty()) continue
            if (node.stateWords.isNotEmpty() && node.colourToken.isEmpty()) {
                return Verdict.fail("${node.controlId}: a state carrieth words but no colour token")
            }
            if (node.colourToken.isNotEmpty() && node.stateWords.isEmpty()) {
                return Verdict.fail("${node.controlId}: a state carrieth a colour but NO words")
            }
        }
        return Verdict.pass("every state carrieth words as well as a colour token")
    }

    fun checkTouchTargets(nodes: List<UiNode>, platform: A11yPlatform): Verdict {
        for (node in nodes) {
            if (node.role == ControlRole.STATIC_TEXT) continue
            if (node.touchWidthDp < platform.touchTargetMinDp ||
                node.touchHeightDp < platform.touchTargetMinDp
            ) {
                return Verdict.fail(
                    "${node.controlId}: ${node.touchWidthDp}x${node.touchHeightDp} is below the " +
                        "${platform.touchTargetMinDp} minimum for ${platform.platformName}")
            }
        }
        return Verdict.pass("every control meeteth the ${platform.touchTargetMinDp} minimum")
    }

    fun checkReadingOrder(nodes: List<UiNode>): Verdict {
        val orders = nodes.filter { ESSENTIAL_CONTROLS.containsKey(it.controlId) }
            .map { it.readingOrder }.sorted()
        if (orders != List(orders.size) { it }) {
            return Verdict.fail("the essential controls' reading order is not contiguous: $orders")
        }
        if (nodes.any { it.contentDescription.isBlank() }) {
            return Verdict.fail("a node in the reading order carrieth no description")
        }
        return Verdict.pass("every essential control is reachable in a contiguous reading order")
    }

    fun checkRtlMeaning(nodes: List<UiNode>, rtl: Boolean): Verdict {
        for (node in nodes) {
            if (node.mirrored && node.mirrorsMeaning) {
                return Verdict.fail(
                    "${node.controlId}: its MEANING mirrored with the layout (rtl=$rtl)")
            }
        }
        return Verdict.pass("the mirror may move the layout, never a control's meaning")
    }

    fun checkLongContent(nodes: List<UiNode>, locale: String): Verdict {
        for (node in nodes) {
            if (node.containerWidthDp > 0f && node.contentWidthDp > node.containerWidthDp &&
                node.truncated
            ) {
                return Verdict.fail(
                    "${node.controlId}: the $locale fixture overfloweth " +
                        "(${node.contentWidthDp} > ${node.containerWidthDp}) and was clipped")
            }
            if (node.truncated && ESSENTIAL_CONTROLS.containsKey(node.controlId)) {
                return Verdict.fail("${node.controlId}: an essential label was clipped")
            }
        }
        return Verdict.pass("the $locale fixture fitteth without clipping a label")
    }

    // ---- contrast (WCAG 2.1) --------------------------------------------

    fun contrastRatio(foregroundHex: String, backgroundHex: String): Double {
        val l1 = relativeLuminance(parseHex(foregroundHex))
        val l2 = relativeLuminance(parseHex(backgroundHex))
        val lighter = maxOf(l1, l2)
        val darker = minOf(l1, l2)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private fun parseHex(value: String): Triple<Double, Double, Double> {
        val text = value.trim().removePrefix("#")
        require(text.length == 6) { "a colour is #rrggbb" }
        return Triple(
            text.substring(0, 2).toInt(16) / 255.0,
            text.substring(2, 4).toInt(16) / 255.0,
            text.substring(4, 6).toInt(16) / 255.0,
        )
    }

    private fun relativeLuminance(rgb: Triple<Double, Double, Double>): Double {
        fun channel(c: Double) = if (c <= 0.03928) c / 12.92 else Math.pow((c + 0.055) / 1.055, 2.4)
        return 0.2126 * channel(rgb.first) + 0.7152 * channel(rgb.second) + 0.0722 * channel(rgb.third)
    }
}
