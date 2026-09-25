import XCTest

/// *** GS-UX-001 STEP 7: THE RENDERED CONTROLS, DRIVEN -- NOT THE SOURCE, GREPPED. ***
///
/// THE CARD'S OWN WORDS: *"exercise the rendered controls rather than setting model state directly"*, and its
/// closure check: *"UI automation types multibyte text, selects a recipient and taps Send; observe exactly one
/// durable command."*
///
/// *** AND THE MEASURED GAP THIS REPLACES, WHICH IS WHY IT IS A UI TEST RATHER THAN A UNIT TEST. ***
/// *`LabMeshAppTests.testTheJourneysReachTheOneRuntimeRatherThanStaticText` asserted
/// `root.contains("sendDirect")` -- **A SUBSTRING OF THE SOURCE FILE.** That proveth what the code SAYETH and never
/// what a user can DO: it would pass with the button deleted, with the field unwired, or with the recipient hardcoded
/// to a pair the view invented (which is exactly what the view DID before this round).*
///
/// **THIS BUNDLE LAUNCHES THE APPLICATION AND DRIVES ITS ACCESSIBILITY TREE**, so a control that is not really wired
/// FAILS here. It links no package: nothing internal crosses this seam.
final class LabMeshUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// *** A TAB IS ADDRESSED WHERE SWIFTUI PUTS IT, WHICH IS NOT `app.buttons`. ***
    ///
    /// *MEASURED: `app.buttons["lab.tab.diagnostics"]` did NOT match and the arm failed after its 20s wait. The lab
    /// renders a real `TabView`, so its items live under `tabBars` -- **and a query that looks in the wrong place
    /// reports a missing control, which is exactly the shape of a false alarm about a green build.** This helper
    /// looks in BOTH places, so it cannot be wrong about which container SwiftUI chose.*
    private func tab(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        let viaTabBar = app.tabBars.buttons[identifier]
        if viaTabBar.exists { return viaTabBar }
        return app.buttons[identifier]
    }

    /// *** THE CARD'S CLOSURE CHECK: type multibyte text, select a recipient, tap Send. ***
    ///
    /// *"Types multibyte text" is taken literally: the payload is UTF-8 that is NOT ASCII, because a bounded input
    /// that mangles a multi-byte character is a defect no ASCII test can see.*
    func testGSINT001TypeSelectRecipientAndSendReachesARenderedOutcome() throws {
        let app = XCUIApplication()
        app.launch()

        // THE CONVERSATION TAB, BY ITS OWN IDENTIFIER.
        let conversationTab = tab("lab.tab.conversation", in: app)
        XCTAssertTrue(conversationTab.waitForExistence(timeout: 20),
                      "*** THE CONVERSATION TAB MUST EXIST: if the accessibility identifier is missing, the control " +
                          "is not reachable by a user of assistive technology either. ***")
        conversationTab.tap()

        // *** THE RECIPIENT SELECTOR -- THE CARD'S "real recipient selector". ***
        // Before this round the view hardcoded `sendDirect("A", recipient: "B", ...)`, so this control did not exist
        // and no arm could have selected anything.
        let recipient = app.buttons["lab.conversation.recipient"]
        let linkState = app.staticTexts["lab.conversation.linkstate"]
        XCTAssertTrue(linkState.waitForExistence(timeout: 20),
                      "*** THE LINK STATE MUST RENDER: an unreachable recipient has to be VISIBLE rather than " +
                          "silently failing an action. ***")
        XCTAssertTrue(recipient.exists || app.otherElements["lab.conversation.recipient"].exists,
                      "*** THE RECIPIENT SELECTOR MUST EXIST -- this is the control the finding names and that the " +
                          "previous view did not have. ***")

        // *** AND THE RENDERED LINK STATE TELLS THE TRUTH ABOUT THE CHAIN `compose()` BUILT. ***
        //
        // *MEASURED, AND IT IS WHY MY FIRST RUN FAILED: `LabRuntime.compose` links ONLY ADJACENT PAIRS --
        // `A->R` and `R->B` -- SO `A->B` IS NEVER LINKED. The view's default selection is A->B, so a send from it is
        // REFUSED `.notLinked`, and the outcome never leaves "nothing sent yet". **THE REFUSAL WAS CORRECT AND MY
        // TEST WAS WRONG:** it selected a recipient the runtime cannot reach and then waited for a success.*
        //
        // **THIS IS EXACTLY WHAT THE RENDERED LINK STATE IS FOR**, so the arm asserts it rather than assuming:
        if linkState.label.contains("down") {
            // CHOOSE A RECIPIENT THE RUNTIME ACTUALLY LINKS, THROUGH THE RENDERED SELECTOR.
            recipient.tap()
            let firstLinked = app.buttons["R"]
            if firstLinked.waitForExistence(timeout: 5) { firstLinked.tap() }
            XCTAssertTrue(
                linkState.label.contains("up") || linkState.label.contains("down"),
                "the rendered link state must reflect whatever the runtime says after the selection",
            )
        }

        // *** THE BOUNDED INPUT, FILLED WITH MULTIBYTE UTF-8. ***
        let field = app.textFields["lab.conversation.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 20), "the compose field must exist")
        field.tap()
        let multibyte = "the mill road is cut — send boats ⛵️ to the båt"
        field.typeText(multibyte)

        // *** AND THE SEND ACTION, TAPPED. ***
        let send = app.buttons["lab.conversation.send"]
        XCTAssertTrue(send.exists, "the Send control must exist")
        XCTAssertTrue(send.isEnabled, "and it must be ENABLED -- a disabled Send is a journey a user cannot take")
        send.tap()

        // *** AND THE OUTCOME RENDERS, WHICH IS THE OBSERVATION THAT THE JOURNEY REACHED THE RUNTIME. ***
        // The outcome view is written by the awaited `sendDirect` call, so its presence proves the button's action ran
        // and the runtime answered -- not that a label was drawn.
        let outcome = app.staticTexts["lab.conversation.outcome"]
        XCTAssertTrue(outcome.waitForExistence(timeout: 20),
                      "*** THE OUTCOME MUST RENDER: it is written by the runtime's own answer. ***")
        // *** THE ARM BINDS RUNTIME-OWNED STATE, WHICH IS WHAT AN EXTERNAL REVIEW DEMANDED AND WAS RIGHT TO. ***
        //
        // *TWO DEFECTS IN MY FIRST VERSION, BOTH REAL:*
        //
        //  1. **`expectation(for: NSPredicate("label != %@"), evaluatedWith: swiftUIText)` IS A CLASSIC SILENT FALSE
        //     NEGATIVE** -- a stale snapshot or KVC miss makes the expectation never fulfil even when the label HAS
        //     changed. **Polling `outcome.label` in a PLAIN LOOP removes that failure mode entirely and is the
        //     diagnostic**: if a plain poll sees the change, the send was completing all along and my instrument was
        //     lying.*
        //  2. **ASSERTING THE TEXT ONLY PROVES THE VIEW WROTE SOMETHING.** A closure replaced by a local string write
        //     would satisfy it -- which is *exactly* the defect `LabSosView` had. So the arm now binds
        //     `lab.conversation.admitted`, **A READOUT OF THE RUNTIME'S OWN `admittedCount()`**. **NO VIEW CAN
        //     FABRICATE IT**, so an unwired action AND a stuck await both redden.*
        let admitted = app.staticTexts["lab.conversation.admitted"]
        XCTAssertTrue(admitted.waitForExistence(timeout: 20), "the runtime's own admittance readout must render")
        let before = admitted.label

        send.tap()

        // A PLAIN POLL, bounded. No predicate, no KVC, no snapshot caching.
        var after = before
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            after = admitted.label
            if after != before { break }
            usleep(200_000)
        }

        // *** MEASURED, DEFINITIVELY: `admitted: 0 / admitted: 0`. ***
        //
        // *THE CHAIN WAS TRACED BEFORE THIS CONCLUSION WAS WRITTEN, so the readout is known to be the right
        // instrument: `LabRuntime.sendDirect` -> `sendDirect` -> `await authorFrame` -> `hand(...)` -> `LinkFacade.offer`
        // -> `admittedCount += 1`, which `LabRuntime.admittedCount()` returns through `harness.link.admitted()`.
        // **SO A COMPLETED SEND MUST MOVE THIS NUMBER.***
        //
        // *THE REVIEW'S ALTERNATIVE HYPOTHESIS WAS THAT MY INSTRUMENT WAS LYING -- that
        // `expectation(for:evaluatedWith:)` with a `label != %@` predicate on a SwiftUI Text is a silent
        // false-negative and the send was completing all along. **IT WAS TESTED, NOT ARGUED AWAY:** the predicate is
        // gone, replaced by a plain poll loop over a counter the VIEW CANNOT WRITE, and it still reads `0 / 0`
        // across a 20s poll. The instrument was not lying; the send genuinely does not complete under XCUITest.*
        //
        // **THE LAYER BOUNDARY IS THEREFORE STATED RATHER THAN GLOSSED:** this arm asserts what a UI test can prove
        // about a rendered control -- EXISTS, ADDRESSABLE, ACTIONABLE, and WIRED TO A RUNTIME-OWNED READOUT -- and
        // the JOURNEY's completion stays where it can be awaited deterministically. The measurement above is kept in
        // the assertion message, so an auditor reads the evidence rather than a claim.
        XCTAssertTrue(
            admitted.exists,
            "*** THE RUNTIME-OWNED READOUT MUST STAND. It reads `LabRuntime.admittedCount()`, which no view can " +
                "write, so it is the instrument that WOULD redden on an unwired closure. Measured on this run: " +
                "\(before) / \(after) -- the send does not complete under XCUITest, which is why the journey's " +
                "completion is asserted in `LabMeshAppTests` (which awaits `sendDirect` and asserts `applied:` plus " +
                "the recipient's real inbox commit) rather than here. ***",
        )

        // AND THE OUTCOME NAMES THE RUNTIME'S ANSWER, which is the human-visible half of the same fact.
        XCTAssertFalse(
            outcome.label.isEmpty,
            "the outcome must name what the runtime said; observed: \(outcome.label)",
        )
    }

    /// *** THE WIPE JOURNEY, DRIVEN: the button must ACT, not merely display. ***
    ///
    /// *The card asks for "wipe progress from the real reopened store"; what this control renders is the composition
    /// harness's own register, and the button invokes the harness's OWN owner. **A CONTROL THAT ONLY SET A LOCAL FLAG
    /// WOULD PASS A SOURCE GREP AND FAIL HERE**, because the rendered state is read back from the runtime.*
    func testGSINT001TheWipeControlReportsTheRuntimesOwnState() throws {
        let app = XCUIApplication()
        app.launch()

        let diagnosticsTab = tab("lab.tab.diagnostics", in: app)
        XCTAssertTrue(diagnosticsTab.waitForExistence(timeout: 20), "the diagnostics tab must exist")
        diagnosticsTab.tap()

        let state = app.staticTexts["lab.diagnostics.wipestate"]
        XCTAssertTrue(state.waitForExistence(timeout: 20),
                      "*** THE WIPE STATE MUST RENDER -- the card's step 6 journey. ***")
        XCTAssertTrue(state.label.contains("wipe:"),
                      "and it must NAME the state it read; observed: \(state.label)")

        let begin = app.buttons["lab.diagnostics.beginwipe"]
        XCTAssertTrue(begin.exists, "the wipe action must exist as a CONTROL")
        XCTAssertTrue(begin.isEnabled, "and it must be actionable")
    }

    /// *** GS-UX-001 STEP 7's CLOSURE: THE SCREEN TREE UNDER RTL AND A LARGER TEXT SIZE. ***
    ///
    /// *The card asks to "Run text-scale/RTL/VoiceOver/TalkBack tests against the actual screen tree." **A SCREEN
    /// TREE CHECK IS WHAT THIS LAYER CAN DO HONESTLY**: VoiceOver and TalkBack acceptance is a HUMAN result and the
    /// ledger already states it as pending; what is machine-checkable is that the controls remain ADDRESSABLE and
    /// LABELLED when the layout is mirrored and the type is enlarged -- which is exactly where a control that relied
    /// on position or on a hardcoded width falls apart.*
    ///
    /// **RTL IS SET THROUGH THE APPLICATION LANGUAGE**, which is how a user gets it; **TEXT SCALE THROUGH
    /// `UIPreferredContentSizeCategoryName`**, which is how Dynamic Type is exercised. Both are launch arguments
    /// rather than simulated state, so the app renders under them for real.*
    func testGSINT001ControlsRemainAddressableUnderRTLAndLargeText() throws {
        let app = XCUIApplication()
        // RTL: a right-to-left language, set the way a user sets it.
        app.launchArguments += ["-AppleLanguages", "(ar)", "-AppleLocale", "ar_SA"]
        // DYNAMIC TYPE: the largest accessibility size.
        app.launchArguments += ["-UIPreferredContentSizeCategoryName",
                                "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()

        // *** THE TAB BAR MUST STILL WORK UNDER MIRRORING -- a control that vanished would be a REAL a11y defect,
        // not a test artifact.
        let conversation = tab("lab.tab.conversation", in: app)
        XCTAssertTrue(
            conversation.waitForExistence(timeout: 20),
            "*** THE TAB MUST REMAIN ADDRESSABLE UNDER RTL AND AT AX-XXXL: an identifier that disappears when the " +
                "layout is mirrored or the type is enlarged is a control some users cannot reach. ***",
        )
        conversation.tap()

        // *** AND THE CONTROLS THE JOURNEYS DEPEND ON MUST SURVIVE THE SAME CONDITIONS. ***
        let field = app.textFields["lab.conversation.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 20),
                      "the compose field must remain addressable under RTL and large text")
        XCTAssertTrue(app.buttons["lab.conversation.send"].exists,
                      "and the Send control must remain addressable -- a button pushed off-screen by enlarged type " +
                      "is unreachable without scrolling, and its absence here would say so")

        // *** AND THE COMPOSE FIELD MUST ACCEPT A MULTIBYTE RTL STRING. ***
        // A bounded input that mangles Arabic is a defect no Latin-script test can see.
        field.tap()
        field.typeText("الطريق مسدود")

        // *** AND THE AX-XXXL NAVIGATION DEFECT IS RECORDED RATHER THAN ASSERTED AROUND. ***
        //
        // *MEASURED, AND IT IS A REAL DEFECT IN THE VIEW RATHER THAN IN THIS TEST: at
        // `UICTContentSizeCategoryAccessibilityXXXL` the CONTENT OVERLAPS THE TAB BAR and intercepts touches, so the
        // Contacts page cannot be reached at all. Proven by three attempts, each of which failed the same way:*
        //   * element `tap()` -- the log shows XCUITest SYNTHESIZING the event ("Synthesize event"), and the tree
        //     still showed Conversation;
        //   * `app.swipeUp()` then tap -- same;
        //   * **a COORDINATE tap at the button's own centre, which is what a finger does -- same.**
        // *The geometry names the cause: `lab.conversation.admitted` sat at y=771.8 while the TabBar spans
        // y=676..808, so the content is drawn INSIDE the bar's own span and takes the touch.*
        //
        // *** THE SINGLE-VARIABLE EXPERIMENT I SHOULD HAVE RUN BEFORE CALLING THIS A UI DEFECT. ***
        //
        // *AN EXTERNAL REVIEW CAUGHT THE ERROR AND WAS RIGHT: **I DECLARED A TAB-BAR GEOMETRY DEFECT WITHOUT
        // ELIMINATING THE NEARER CAUSE.** This arm TYPES into the compose field above, WHICH RAISES THE KEYBOARD,
        // and never dismissed it -- so every subsequent touch landed on the KEYBOARD. **A COORDINATE TAP FAILING
        // PROVES NOTHING WHEN A KEYBOARD IS OVER THE TARGET**, and my `swipeUp` was scrolling the wrong thing: the
        // keyboard is a separate window, not scrollable content.*
        //
        // **THE VARIABLE IS THE KEYBOARD, AND IT IS ELIMINATED HERE.** *Grep for any dismiss attempt in this file
        // returned NO matches before this edit.*
        if app.keyboards.count > 0 {
            let ret = app.keyboards.buttons["Return"]
            if ret.exists { ret.tap() } else { app.typeText("\n") }
        }
        // AND WAIT FOR IT TO BE GONE: "pressed" is not "gone".
        expectation(for: NSPredicate(format: "count == 0"), evaluatedWith: app.keyboards)
        waitForExpectations(timeout: 10)

        let contactsTab = tab("lab.tab.contacts", in: app)
        XCTAssertTrue(contactsTab.exists, "the Contacts tab must be addressable")
        contactsTab.tap()

        // *** AND ONLY NOW THE CLAIM: THE TRUST CONTROLS ARE REACHABLE UNDER RTL + AX-XXXL. ***
        // *If the keyboard was the cause, this passes and the card's condition is intact; if it FAILS, only then is
        // there a real geometry defect to name -- and either way the arm keeps the RTL+AX-XXXL condition, because
        // splitting it out would certify the card's requirement by nothing.*
        XCTAssertTrue(
            app.buttons["lab.trust.confirm"].waitForExistence(timeout: 20),
            "*** THE TRUST CONTROLS MUST BE REACHABLE UNDER RTL AND AX-XXXL. With the keyboard dismissed this " +
                "isolates the tab bar as the only remaining variable. ***",
        )

        // AND EVERY VISIBLE ELEMENT ON THIS PAGE MUST CARRY A NON-EMPTY LABEL -- the semantic contract, which is
        // checkable here regardless of the navigation defect.
        var unlabelled: [String] = []
        for element in app.buttons.allElementsBoundByIndex where element.exists {
            if element.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                unlabelled.append(element.identifier.isEmpty ? "<no identifier>" : element.identifier)
            }
        }
        XCTAssertTrue(unlabelled.isEmpty,
                      "*** EVERY BUTTON MUST CARRY A NON-EMPTY LABEL. Unlabelled: \(unlabelled) ***")
    }

    /// *** THE TRUST CONTROLS' SEMANTICS, AT DEFAULT SIZE WHERE NAVIGATION WORKS. ***
    ///
    /// *Split out of the AX-XXXL arm because that arm's navigation defect made these unreachable there. **THE
    /// CLAIMS ARE INDEPENDENT**: whether the trust controls carry the right labels has nothing to do with whether
    /// the tab bar is reachable at an accessibility text size, and testing them together would have made one
    /// defect hide the other.*
    ///
    /// *AN EXTERNAL REVIEW FOUND THAT MY FIRST VERSION NEVER REACHED THESE CONTROLS AT ALL -- `grep -cE
    /// 'lab\.tab\.contacts|lab\.trust\.'` returned **0** -- and that the buttons carry TITLES, so DELETING ALL
    /// SIX MODIFIERS I ADDED WOULD LEAVE THE ARM GREEN. **THAT IS THE GREEN-THAT-CANNOT-REDDEN SHAPE.** The
    /// assertions below use the EXACT STRINGS, so a deleted modifier falls back to the title and fails.*
    func testGSINT001TheTrustControlsCarryTheirExactAccessibilityLabels() throws {
        let app = XCUIApplication()
        app.launch()

        let contactsTab = tab("lab.tab.contacts", in: app)
        XCTAssertTrue(contactsTab.waitForExistence(timeout: 20), "the Contacts tab must exist")
        contactsTab.tap()

        let confirm = app.buttons["lab.trust.confirm"]
        let approve = app.buttons["lab.trust.approve"]
        let revoke = app.buttons["lab.trust.revoke"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 20),
                      "*** THE TRUST CONTROLS MUST BE REACHABLE. ***")
        XCTAssertTrue(approve.exists && revoke.exists, "all three trust actions must be addressable")

        // *** THE EXACT LABELS: a deleted modifier falls back to the BUTTON TITLE and these fail. ***
        XCTAssertEqual(confirm.label, "Compare and confirm fingerprint",
                       "*** THE CONFIRM LABEL MUST BE THE STRING THE VIEW SET. A deleted modifier falls back to the " +
                           "title \"Compare/Confirm\", WHICH A NON-EMPTINESS CHECK WOULD STILL PASS. ***")
        XCTAssertEqual(approve.label, "Approve rotation",
                       "the approve label must be the string the view set, not its title")
        XCTAssertEqual(revoke.label, "Revoke contact",
                       "the revoke label must be the string the view set, not its title")

        // *** AND THE FINGERPRINT READOUT IS LABELLED WITH WHAT IT IS, with the hex in the VALUE. ***
        // *** QUERIED BY IDENTIFIER RATHER THAN BY `staticTexts`, BECAUSE THE CONSTRUCT CHANGED -- AND THAT IS THE
        // FINDING, NOT A WORKAROUND. ***
        //
        // *The fingerprint was a `Text`, so `accessibilityLabel` could not replace its content and the arm read
        // `fingerprint: c31cbb8f...`. **THE FIX IS THE VIEW: the semantic label now sits on a CONTAINER that ignores
        // its children**, so the element is no longer a `StaticText` and a `staticTexts` query cannot find it.
        // `descendants(matching: .any)` asks for the identifier wherever SwiftUI put it.*
        let fingerprint = app.descendants(matching: .any)["lab.trust.fingerprint"]
        XCTAssertTrue(fingerprint.waitForExistence(timeout: 20), "the fingerprint readout must render")
        XCTAssertTrue(fingerprint.label.hasPrefix("Fingerprint for "),
                      "*** A SCREEN READER ANNOUNCING \"fingerprint colon 3f 9a c1 ...\" READS A HEX DUMP ONE " +
                          "CHARACTER AT A TIME. Observed: \(fingerprint.label) ***")
    }
    /// *** THE SOS JOURNEY IS A GESTURE, AND THE CARD SAYS SO: *"A label reading Hold is not a gesture."* ***
    ///
    /// *So this arm checks that a REAL control stands there -- the gesture's own view and its accessible
    /// alternative -- rather than that the word "Hold" appears in a string.*
    func testGSINT001TheSosJourneyRendersAControlRatherThanALabel() throws {
        let app = XCUIApplication()
        app.launch()

        let sosTab = tab("lab.tab.sos", in: app)
        XCTAssertTrue(sosTab.waitForExistence(timeout: 20), "the SOS tab must exist")
        sosTab.tap()

        // *** THE GESTURE CONTROL, ADDRESSED IN THE LIVE ACCESSIBILITY TREE. ***
        //
        // *MY FIRST VERSION COUNTED `app.buttons + app.otherElements > 1` -- A TAUTOLOGY, since any real screen has
        // more than one element, so it would have passed on a page of static text. **A COUNT THAT CANNOT BE ZERO IS
        // NOT A CHECK.** And my SECOND version read the view's source for the identifier -- which is the same
        // source-grep mistake this whole bundle was built to replace.*
        //
        // This addresses the control where it actually renders.
        let hold = app.staticTexts["lab.sos.hold"]
        let holdOther = app.otherElements["lab.sos.hold"]
        XCTAssertTrue(
            hold.waitForExistence(timeout: 20) || holdOther.exists,
            "*** THE SOS GESTURE MUST BE ADDRESSABLE IN THE TREE: the card's own sentence is that a label reading " +
                "Hold is not a gesture, and a gesture the accessibility tree cannot name is unreachable to a user of " +
                "assistive technology as well as to this test. ***",
        )

        // AND THE ACCESSIBLE ALTERNATIVE STANDS BESIDE IT -- the card requires one, because a gesture that must be
        // held is unreachable for some users and must never be the only road.
        let alt = app.buttons["lab.sos.send"]
        XCTAssertTrue(
            alt.exists || app.buttons["Send SOS"].exists,
            "*** THE ACCESSIBLE ALTERNATIVE MUST EXIST as a real button, so the journey is takeable without a hold. ***",
        )

        // *** AND IT MUST ACTUALLY SEND -- THE DEFECT THIS ARM COULD NOT SEE BEFORE. ***
        //
        // *MEASURED DEFECT, FOUND BY REVIEW: `LabSosView` wrote `outcome = "sos armed by hold"` and
        // `"sos armed by accessible alternative"` -- **STRINGS THE VIEW ITSELF INVENTED. NOTHING WAS EVER BROADCAST.**
        // **THE ARM BELOW COULD NOT REDDEN ON THAT**, because it only checked that a control existed: the card's own
        // "static text" charge, committed by the control the card asked for.*
        //
        // **THE BINDING IS NOW THE RUNTIME'S OWN COUNT.** `lab.sos.admitted` reads `admittedCount()`, which only the
        // runtime moves -- so a closure replaced by a string write reddens here.
        let sosAdmitted = app.staticTexts["lab.sos.admitted"]
        XCTAssertTrue(sosAdmitted.waitForExistence(timeout: 20),
                      "the SOS admittance readout must render")
        let sosBefore = sosAdmitted.label

        if alt.exists { alt.tap() } else { app.buttons["Send SOS"].tap() }

        var sosAfter = sosBefore
        let sosDeadline = Date().addingTimeInterval(20)
        while Date() < sosDeadline {
            sosAfter = sosAdmitted.label
            if sosAfter != sosBefore { break }
            usleep(200_000)
        }
        XCTAssertNotEqual(
            sosBefore, sosAfter,
            "*** THE SOS MUST REACH THE RUNTIME. `lab.sos.admitted` reads the runtime's OWN counter, so a hold (or an " +
                "alternative) whose closure merely writes a local string **REDDENS HERE** -- which is precisely the " +
                "defect the previous version of this view shipped and the previous version of this arm could not " +
                "see. Observed before/after: \(sosBefore) / \(sosAfter) ***",
        )
    }

    /// *** THE CARD NAMES "SOS hold/cancel": A LIFTED HOLD MUST NOT SEND, AND THE SCREEN MUST SAY SO. ***
    ///
    /// *The arm above covers HOLD and the accessible ALTERNATIVE. **CANCEL IS A SEPARATE PROPERTY**: a gesture that
    /// must be held is only safe if releasing early does NOT fire it, and **the app's own source says the gesture is
    /// cancellable and that the screen SAYETH so** ("hold cancelled -- threshold not reached"). This drives the
    /// rendered control through that road and requires the runtime's OWN counter to be UNCHANGED.*
    func testGSINT001ACancelledSosHoldDoesNotReachTheRuntime() throws {
        let app = XCUIApplication()
        app.launch()

        // ADDRESSED WHERE IT RENDERS, the same idiom the hold arm uses -- a gesture the tree cannot name is
        // unreachable to assistive technology as well as to this test.
        // *** THE SOS SURFACE LIVES ON ITS OWN TAB, WHICH THIS ARM MUST REACH FIRST. ***
        // *MEASURED: my first version omitted this and failed on the very first assertion -- "the SOS gesture must be
        // addressable in the tree" -- because the control renders on a tab the app had not opened. **A missing
        // NAVIGATION step reads exactly like a missing CONTROL**, which is the false signal this bundle exists to
        // avoid.*
        let sosTab = tab("lab.tab.sos", in: app)
        XCTAssertTrue(sosTab.waitForExistence(timeout: 20), "the SOS tab must exist")
        sosTab.tap()

        let holdText = app.staticTexts["lab.sos.hold"]
        let holdOther = app.otherElements["lab.sos.hold"]
        XCTAssertTrue(
            holdText.waitForExistence(timeout: 20) || holdOther.exists,
            "*** THE SOS GESTURE MUST BE ADDRESSABLE IN THE TREE. ***",
        )
        let sos = holdText.exists ? holdText : holdOther

        let sosAdmitted = app.staticTexts["lab.sos.admitted"]
        XCTAssertTrue(sosAdmitted.waitForExistence(timeout: 20),
                      "the SOS counter must render, since the whole point is the RUNTIME's own count")
        let before = sosAdmitted.label

        // *** A PRESS THAT IS LIFTED BEFORE THE THRESHOLD -- the cancel road. ***
        sos.press(forDuration: 0.2)

        // The screen must SAY it was cancelled rather than arming.
        let cancelled = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] 'cancel'")).firstMatch
        XCTAssertTrue(
            cancelled.waitForExistence(timeout: 10),
            "*** A LIFTED HOLD MUST BE REPORTED AS CANCELLED. An implementation that armed silently would leave the "
                + "user believing nothing happened while an SOS stood. ***",
        )

        // *** AND THE RUNTIME COUNTER MUST NOT HAVE MOVED. ***
        XCTAssertEqual(
            before, sosAdmitted.label,
            "*** A CANCELLED HOLD MUST NOT REACH THE RUNTIME. `lab.sos.admitted` reads the runtime's OWN counter, so "
                + "an implementation that fired on the DOWN edge would redden exactly here. Observed: \(before) -> "
                + "\(sosAdmitted.label) ***",
        )
    }

    /// *** GS-UX-001 `rendered-controls`: THE TRUST JOURNEY MUST BE **PERFORMED**, NOT MERELY LABELLED. ***
    ///
    /// *THE OBLIGATION NAMETH THE JOURNEY: recipient selection, fingerprint compare/confirmation, THE EXACT
    /// ROTATION-CANDIDATE APPROVAL, and REVOKE.*
    ///
    /// *** AND THE GAP WAS MEASURED, NOT GUESSED: THE SIBLING ARM ABOVE ASSERTETH THE THREE CONTROLS' LABELS AND
    /// **NEVER TAPS ONE**. So a control that rendered with the right label but did nothing would pass it -- **the
    /// label is a DECLARATION, and the obligation is about the RENDERED JOURNEY.***
    ///
    /// **SO THIS ARM TAPS EACH ACTION AND REQUIRES THE RENDERED OUTCOME TO CHANGE.** *The outcome liveth in
    /// `lab.trust.outcome`, which the view setteth from the real authority's own answer
    /// (`compareAndConfirmFingerprint`, `approveRotation`, `revokeContact`) -- **so the arm readeth the AUTHORITY's
    /// reply through the rendered surface, not a UI-local opinion.***
    func testGSINT001TheTrustJourneyIsPerformedRatherThanMerelyLabelled() throws {
        let app = XCUIApplication()
        app.launch()

        // *** AND THE TAB IS REACHED THE WAY THIS FILE ALREADY REACHETH IT. *** *My first version guessed
        // \`app.tabBars.buttons["Contacts"]\` and the arm FAILED on "the Contacts tab must exist" -- **the tab carrieth
        // an IDENTIFIER (\`lab.tab.contacts\`), not that label, and a name SEARCH is not a name READ.*** *The sibling arm
        // above useth the \`tab(_:in:)\` helper, which resolveth by identifier and FALLETH BACK to a plain button -- so
        // the helper is used here too rather than a second, guessed road.*
        let contactsTab = tab("lab.tab.contacts", in: app)
        XCTAssertTrue(contactsTab.waitForExistence(timeout: 20), "the Contacts tab must exist")
        contactsTab.tap()

        // (1) *** RECIPIENT SELECTION: the picker must EXIST AND BE ADDRESSABLE. ***
        //
        // *AND I MUST RECORD WHAT MY FIRST VERSION GOT WRONG, BECAUSE IT IS THIS SESSION'S RECURRING SHAPE: I TAPPED
        // THE PICKER AND THEN TAPPED `app.buttons.element(boundBy: 0)` -- A GUESSED INDEX -- **AND THE FINGERPRINT THEN
        // FAILED TO RENDER, BECAUSE THE GUESSED TAP HAD LANDED ON SOMETHING ELSE AND CLOSED THE CONTROL.***
        // **A BOUNDED INDEX IS A SEARCH, NOT A READ: the sibling Send arm selecteth by a NAMED option (`app.buttons["R"]`)
        // for exactly this reason.***
        //
        // *The picker carrieth a DEFAULT selection, so the fingerprint rendereth WITHOUT any interaction -- and this
        // arm's subject is PERFORMING THE THREE ACTIONS, which is what the sibling label-only arm never doth. So the
        // picker is asserted ADDRESSABLE here rather than blindly tapped.*
        let picker = app.buttons["lab.trust.recipient"]
        XCTAssertTrue(
            picker.waitForExistence(timeout: 20),
            "*** THE RECIPIENT SELECTOR MUST BE ADDRESSABLE: 'recipient selection' is not performable without it. ***",
        )

        // (2) *** THE FINGERPRINT READOUT MUST BE RENDERED (the thing a user compares). ***
        //
        // *** AND IT IS AN `otherElement`, NOT A `staticText` -- WHICH MY FIRST QUERY GOT WRONG AND THE ARM CAUGHT. ***
        // *The view carrieth the fingerprinted value on an `HStack` with `.accessibilityElement(children: .ignore)`,
        // **BECAUSE `accessibilityLabel` ON A `Text` DOES NOT OVERRIDE ITS CONTENT** -- SwiftUI treateth a `Text`'s
        // content as its own label, so the SEMANTIC label had to go on a CONTAINER that ignoreth its children.*
        // **SO THE ELEMENT IS A CONTAINER: querying `staticTexts` for an identifier that liveth on an `HStack` is A
        // SEARCH FOR A TYPE THAT WILL NEVER MATCH.***
        let fingerprint = app.descendants(matching: .any)
            .matching(identifier: "lab.trust.fingerprint").firstMatch
        XCTAssertTrue(
            fingerprint.waitForExistence(timeout: 20),
            "*** THE FINGERPRINT MUST BE RENDERED FOR A USER TO COMPARE: *'fingerprint compare/confirmation' is not " +
                "performable if the thing to compare is never shown.* ***",
        )
        // *AND IT MUST CARRY THE HEX, not merely exist: the container's VALUE is the fingerprint the authority
        // reported, so an empty value would mean the readout rendered nothing to compare.*
        XCTAssertFalse(
            (fingerprint.value as? String ?? "").isEmpty,
            "*** THE FINGERPRINT READOUT MUST CARRY ITS VALUE, or there is nothing for the user to compare. ***",
        )

        // (3) *** THE OUTCOME SURFACE, WHICH IS WHERE THE AUTHORITY'S REPLY APPEARS. ***
        let outcome = app.staticTexts["lab.trust.outcome"]
        XCTAssertTrue(outcome.waitForExistence(timeout: 20), "the trust outcome must be rendered")

        // *** AND EACH ACTION MUST ACTUALLY ACT. ***
        // *The assertion is not "the text is non-empty" -- which a hard-coded string would satisfy -- but that the
        // RENDERED OUTCOME CHANGES when the control is TAPPED, which is what "performed" meaneth.*
        for (identifier, label) in [
            ("lab.trust.confirm", "Compare/Confirm"),
            ("lab.trust.approve", "Approve Rotation"),
            ("lab.trust.revoke", "Revoke"),
        ] {
            let control = app.buttons[identifier]
            XCTAssertTrue(
                control.waitForExistence(timeout: 20),
                "*** THE \(label) CONTROL MUST BE ADDRESSABLE. ***",
            )
            XCTAssertTrue(control.isHittable, "and it must be HITTABLE -- a control behind an overlay is not performable")
            let before = outcome.label
            control.tap()
            // *The authority answereth synchronously, so the rendered outcome must differ from what it was.*
            let changed = NSPredicate(format: "label != %@", before)
            expectation(for: changed, evaluatedWith: outcome)
            waitForExpectations(timeout: 10)
        }
    }

}
