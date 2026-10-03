package io.godstone.mesh.a11y

// ---------------------------------------------------------------------------
// T60 / GS-UX-001 step 9 -- THE LIVE ACCESSIBILITY ROSTER, IN EVERY MODE.
//
// "Host UI tests do not prove large-text layout, screen-reader operation or
// process-restored truth." So this roster decideth NOTHING ITSELF: it is handed
// the [UiNode]s READ FROM A RENDERED TREE -- the live state behind the
// components, after the runtime has already transformed them -- and applies the
// SAME [AccessibilityContract] laws the python conductor and the iOS twin own,
// once per RUNTIME MODE.
//
// ITS OWN MODES ARE THE CONTRACT'S: [TextScale.entries] carries exactly the
// four modes the readiness conductor names (default / large / largest /
// largest_accessibility). This class DECLARES NO MODE OF ITS OWN -- a second
// enum here would be a second declaration, which is the drift the contract
// existeth to prevent.
//
// *** AND IT IS APPLIED AFTER THE RUNTIME, NOT BEFORE IT. *** *The component's
// INITIAL render is not what a user meets: the state machinery and the layout
// run after it, and THAT is where a status clip, a lost label or a folded
// reading order really appear. So [decide] readeth the POST-transform node
// values (the words the state published, the box the layout really gave it, the
// enablement the typed estate really set) rather than any pre-render claim.*
//
// `received` IS THE REAL LOGGING: one line per node NAMING WHAT THE USER ACTUALLY
// GETS -- the published description, the state words, whether the control is
// reachable, and the laid-out size measured after the transform -- so a trace of
// a failing mode readeth like the screen the user saw rather than like the model
// it was supposed to be.
// ---------------------------------------------------------------------------

/**
 * The live accessibility roster, decided once per runtime mode.
 *
 * A caller hands [decide] the nodes a REAL rendered tree published in ONE mode,
 * and the [ModeRecord] it returneth carrieth a verdict WITH ITS REASON for every
 * law, plus the human-readable lines of what the user receives.
 */
class LiveAccessibilityRoster {

    /**
     * One mode's decision: every law's verdict, and the lines of what the user received.
     *
     * [passed] is true iff EVERY law passed -- a mode is never "mostly" accessible.
     */
    data class ModeRecord(
        val mode: TextScale,
        val rtl: Boolean,
        val verdicts: Map<String, Verdict>,
        val received: List<String>,
    ) {
        val passed: Boolean get() = verdicts.values.all { it.passed }

        /** The first refusal, by name, or null when the mode passed. */
        fun refusal(): Pair<String, String>? =
            verdicts.entries.firstOrNull { !it.value.passed }?.let { it.key to it.value.reason }
    }

    /** The four runtime modes, taken from the SHARED contract -- never re-declared here. */
    val modes: List<TextScale> get() = TextScale.entries.toList()

    /**
     * Decide one mode's roster from the POST-transform nodes.
     *
     * Every law a HOST can decide is decided here, from the same semantic model
     * all three isles share. A refusal nameth the law, the control and the mode,
     * so a trace of a failing mode is actionable rather than a bare false.
     */
    fun decide(
        mode: TextScale,
        nodes: List<UiNode>,
        rtl: Boolean = false,
        locale: String = "en",
    ): ModeRecord {
        val verdicts = linkedMapOf(
            "essential_control_labelled" to AccessibilityContract.checkEssentialControlsLabelled(nodes),
            "status_never_clipped" to AccessibilityContract.checkStatusNeverClipped(nodes, mode),
            "no_colour_only_state" to AccessibilityContract.checkNoColourOnlyState(nodes),
            "touch_target_minimum" to AccessibilityContract.checkTouchTargets(nodes, A11yPlatform.ANDROID),
            "reading_order_reachable" to AccessibilityContract.checkReadingOrder(nodes),
            "rtl_meaning_preserved" to AccessibilityContract.checkRtlMeaning(nodes, rtl),
            "long_content_fits" to AccessibilityContract.checkLongContent(nodes, locale),
        )
        return ModeRecord(mode = mode, rtl = rtl, verdicts = verdicts, received = received(nodes, mode))
    }

    /**
     * Decide the roster across [modes] in BOTH directions, reading the tree through [rendered].
     *
     * [rendered] is the CALLER'S read of a REAL rendered tree at one (mode, rtl): the caller
     * owneth the composition (this roster owneth the laws), which is why a court here can drive
     * a real Compose tree and a unit court can drive a modeled one -- and both decide the SAME laws.
     */
    fun roster(
        rendered: (TextScale, Boolean) -> List<UiNode>,
        modes: List<TextScale> = this.modes,
        locale: String = "en",
    ): List<ModeRecord> = modes.flatMap { mode ->
        listOf(false, true).map { rtl -> decide(mode, rendered(mode, rtl), rtl, locale) }
    }

    /**
     * *** THE REAL LOGGING: WHAT THE USER ACTUALLY RECEIVES, PER NODE, AFTER THE TRANSFORM. ***
     *
     * *Not the component's initial state and not its intent -- the published description, the words
     * the STATE machinery wrote, whether the control is REACHABLE at this mode, and the size the
     * LAYOUT really gave it. This is the trace a reader useth to see WHY a mode failed, and it is
     * built from the same nodes the laws were decided upon, so a log can never disagree with the verdict.*
     */
    fun received(nodes: List<UiNode>, mode: TextScale): List<String> = nodes.map { node ->
        val reachable = if (node.enabled) "reachable" else "DISABLED"
        val size = "%.1fx%.1f".format(node.touchWidthDp, node.touchHeightDp)
        val clip = if (node.truncated) " CLIPPED" else ""
        val words = if (node.stateWords.isNotEmpty()) " state=\"${node.stateWords}\"" else ""
        val described = if (node.contentDescription.isBlank()) " <NO DESCRIPTION>" else ""
        "${node.controlId} [${mode.name.lowercase()}] $reachable $size$words$clip$described"
    }

    /**
     * A human-readable trace of a whole roster run: each mode, its verdict, and what the user got.
     *
     * A failing mode is printed with the FIRST refusal's reason, so the trace is the whole evidence.
     */
    fun trace(records: List<ModeRecord>): String {
        val lines = mutableListOf<String>()
        for (record in records) {
            val direction = if (record.rtl) "RTL" else "LTR"
            val verdict = if (record.passed) "PASS" else "FAIL"
            lines += "mode=${record.mode.name.lowercase()} $direction $verdict"
            record.refusal()?.let { (law, reason) -> lines += "  refused by $law: $reason" }
            record.received.forEach { lines += "    $it" }
        }
        return lines.joinToString("\n")
    }

    companion object {
        /**
         * The mode that every host MUST be able to simulate, per the contract's own law 3.
         *
         * *The contract already declarest it ([TextScale.LARGEST_ACCESSIBILITY] / [AccessibilityContract.LARGEST_SCALE_NAME]);
         * this alias existeth so a caller nameth it without re-deriving which of the four it is.* **No scale NUMBER is
         * declared here**: the contract nameth the MODES, and the host's own font scale is the host's to choose -- a
         * number invented in this file would be a second declaration, which is the drift the contract preventeth.**
         */
        val LARGEST: TextScale get() = TextScale.LARGEST_ACCESSIBILITY
    }
}
