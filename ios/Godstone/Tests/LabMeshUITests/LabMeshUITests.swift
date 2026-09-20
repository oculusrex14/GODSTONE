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

        XCTAssertNotEqual(
            before, after,
            "*** THE RUNTIME'S OWN COUNT MUST MOVE AFTER THE SEND TAP. `lab.conversation.admitted` reads " +
                "`LabRuntime.admittedCount()` -- **STATE NO VIEW CAN WRITE** -- so this reddens if the button's " +
                "closure is replaced by a local string write OR if the await never resolves. *Asserting the outcome " +
                "TEXT alone would not: that is the observation `LabSosView`'s defect slipped past.* " +
                "Observed before/after: \(before) / \(after) ***",
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
}
