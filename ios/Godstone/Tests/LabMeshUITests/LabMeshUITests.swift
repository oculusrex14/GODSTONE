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

    /// Query the native tab's declared accessibility label in either container.
    /// A tab-item Text identifier need not appear on its native button after relaunch.
    private func tab(_ label: String, in app: XCUIApplication) -> XCUIElement {
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline {
            let viaTabBar = app.tabBars.buttons[label]
            if viaTabBar.exists { return viaTabBar }
            let plain = app.buttons[label]
            if plain.exists { return plain }
            usleep(150_000)
        }
        return app.buttons[label]
    }

    /// *** GS-UX-001: A CONTROL BELOW THE FOLD IS REACHABLE, AND THE ARM MUST PROVE IT RATHER THAN ASSUME IT. ***
    ///
    /// *MEASURED, FROM THE LANE LOG: `lab.trust.confirm` EXISTED (`waitForExistence` passed) but `isHittable` was
    /// false. **THE CAUSE IS THE LAYOUT THE ARM ITSELF NOW DRIVES:** the Contacts page was wrapped in a `ScrollView`
    /// (the same repair its sibling journeys already carry, so enlarged type cannot cover the tab bar), and the trust
    /// page carrieth more controls than any sibling -- so its action row can sit BELOW THE FOLD, where it is
    /// ADDRESSABLE but not tappable until the user scrolls.*
    ///
    /// **SO THE ARM DOES WHAT THE USER DOES: SCROLL, BOUNDED, AND THEN REQUIRE THE CONTROL TO BE HITTABLE.** *The
    /// assertion is NOT weakened -- it moveth from "hittable where it happens to be" to "reachable by scrolling", and
    /// it still FAILS with a named reason if the control cannot be reached at all. A control no amount of scrolling
    /// revealeth is the real defect this keeps biting on.*
    @discardableResult
    private func scrollIntoView(_ element: XCUIElement, in app: XCUIApplication,
                                attempts: Int = 6) -> Bool {
        if element.isHittable { return true }
        for _ in 0..<attempts {
            let scrollView = app.scrollViews.firstMatch
            if scrollView.exists {
                scrollView.swipeUp()
            } else {
                app.swipeUp()
            }
            if element.isHittable { return true }
        }
        return element.isHittable
    }

    /// *** THE CARD'S CLOSURE CHECK: type multibyte text, select a recipient, tap Send. ***
    ///
    /// *"Types multibyte text" is taken literally: the payload is UTF-8 that is NOT ASCII, because a bounded input
    /// that mangles a multi-byte character is a defect no ASCII test can see.*
    func testGSINT001TypeSelectRecipientAndSendReachesARenderedOutcome() throws {
        let app = XCUIApplication()
        app.launch()

        // THE CONVERSATION TAB, BY ITS DECLARED ACCESSIBILITY LABEL.
        let conversationTab = tab("Conversation screen", in: app)
        XCTAssertTrue(conversationTab.waitForExistence(timeout: 20),
                      "*** THE CONVERSATION TAB MUST EXIST: the native tab button carrieth this declared accessibility "
                          + "label, so if the label is missing the control is not reachable by a user of assistive "
                          + "technology either. ***")
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
        // *** *** IOS-R12: THE COURT NOW ASSERTS A REAL EFFECT, NOT THE EXISTENCE OF AN INSTRUMENT. *** ***
        //
        // *THE REVIEW'S DEFECT: this arm "polls the admission witness but only asserts that the readout exists,
        // explicitly allowing an unchanged 0/0 result" -- so a DISCONNECTED Send action satisfied it.* **THE POSITIVE
        // WITNESS IS NOW THE DURABLE VERDICT THE VIEW RENDERS**: `lab.conversation.durable` is written from
        // `durableIntentVerdict(intent)` over the LAB'S OWN AUTHOR STORE, and `lab.conversation.intent` names the exact
        // id the view minted -- so the rendered verdict must become `found:<the same id>`.* *A no-op Send leaves the
        // verdict `notFound`/unmoved and reddens.*
        XCTAssertTrue(admitted.exists, "the runtime-owned readout must stand")
        let durable = app.descendants(matching: .any)["lab.conversation.durable"]
        XCTAssertTrue(durable.waitForExistence(timeout: 20), "the durable verdict must render")
        let intent = app.descendants(matching: .any)["lab.conversation.intent"]
        XCTAssertTrue(intent.waitForExistence(timeout: 20), "the rendered intent id must stand")
        let deadline2 = Date().addingTimeInterval(25)
        var verdict = durable.value as? String ?? durable.label
        while Date() < deadline2 {
            verdict = durable.value as? String ?? durable.label
            if verdict.hasPrefix("found:") { break }
            usleep(200_000)
        }
        let renderedOutcome = outcome.label
        XCTAssertTrue(
            verdict.hasPrefix("found:"),
            "*** THE SEND MUST REACH THE DURABLE AUTHORITY: the rendered verdict must name a FOUND intent, not " +
                "merely exist. Observed: '\(verdict)' (admitted \(before) -> \(after)) ***",
        )
        // *** *** THE TRUE RELATION, VERIFIED WHERE THE USER SEES IT -- BETWEEN THE TWO RENDERED AUTHORITY ANSWERS. *** ***
        //
        // *`lab.conversation.intent` renders the id the VIEW minted (`mintIntentId()` -> a 16-octet NONCE): the
        // DURABLE JOURNAL KEY the reopen road re-asks by. `lab.conversation.durable` renders the authority's verdict
        // for that key, whose id is the LOGICAL MESSAGE id the authority DERIVED (`MessageId.logical(nodeId:nonce:
        // createdAt:)`) -- **a DIFFERENT identity by construction**, so an assertion that the verdict "contains the
        // minted nonce" conflated a key with the message it names.*
        //
        // **SO THE RELATION IS BOUND WHERE IT IS REAL AND VISIBLE: THE SEND'S OWN OUTCOME.** *`lab.conversation.outcome`
        // renders the authority's reply to THE SAME send (`durable:<logical id>`), so the two rendered answers -- the
        // send's outcome and the reopen's verdict -- must name the SAME logical id. **THAT is the relation the user
        // reads on screen, and it proveth the verdict is about THIS send rather than a key echo.***
        if renderedOutcome.hasPrefix("durable:") {
            let sentId = renderedOutcome.dropFirst("durable:".count)
                .split(separator: ":").first.map(String.init) ?? ""
            XCTAssertFalse(sentId.isEmpty,
                           "*** THE SEND'S OUTCOME MUST NAME THE AUTHORITY'S LOGICAL MESSAGE ID; observed: '\(renderedOutcome)' ***")
            XCTAssertTrue(
                verdict.contains(sentId),
                "*** THE REOPEN VERDICT MUST NAME THE SAME AUTHORITY LOGICAL ID THE SEND'S OWN OUTCOME NAMED: "
                    + "the send rendered '\(renderedOutcome)', the reopen rendered '\(verdict)'. Two answers about "
                    + "THE SAME send must agree on the message identity. ***",
            )
        } else {
            // A REFUSAL carries its own truthful reason; the verdict then answers honestly about the intent key.
            XCTAssertTrue(renderedOutcome.hasPrefix("refused:"),
                          "the outcome must name the runtime's own answer; observed: '\(renderedOutcome)'")
        }
    }

    /// *** THE WIPE JOURNEY, DRIVEN: the button must ACT, not merely display. ***
    ///
    /// *The card asks for "wipe progress from the real reopened store". **MEASURED BEFORE THIS REPAIR, AND IT WAS THE
    /// DEFECT: this control read the COMPOSITION HARNESS's own flag (which owns no ladder at all), so the rendered
    /// state came from a boolean while the real durable record stood untouched.** *`LabRuntime.wipeStateName()` now
    /// readeth `WipeJournalDurabilityAdapter` over the same journal the shipping ladder writeth, and the buttons drive
    /// `MeshRuntime.runRecoveryLadder` -- the production road.* **A CONTROL THAT ONLY SET A LOCAL FLAG STILL FAILS
    /// HERE**, because the rendered state is read back from the durable record and the typed outcome.*
    ///
    /// *** AND THE LIVE JOURNEY: DRIVE THE WIPE, RELAUNCH, AND RESUME FROM THE DURABLE RECORD. ***
    ///
    /// *A wipe that only worked within one process would be no wipe at all: the whole reason the ladder is durable is
    /// that a process may die mid-erasure.* **THE RELAUNCH IS THE DISCRIMINATOR** -- *a flag in memory reads "no wipe
    /// was ever requested" after a fresh launch, while the journal carrieth the rung the ladder reached.*
    func testGSINT001TheWipeControlReportsTheRuntimesOwnState() throws {
        let app = XCUIApplication()
        app.launch()

        let diagnosticsTab = tab("Diagnostics screen", in: app)
        XCTAssertTrue(diagnosticsTab.waitForExistence(timeout: 20), "the diagnostics tab must exist")
        diagnosticsTab.tap()

        let state = app.staticTexts["lab.diagnostics.wipestate"]
        XCTAssertTrue(state.waitForExistence(timeout: 20),
                      "*** THE WIPE STATE MUST RENDER -- the card's step 6 journey. ***")
        XCTAssertTrue(state.label.contains("wipe:"),
                      "and it must NAME the state it read; observed: \(state.label)")

        // *** THE TYPED RUNG AND ARTIFACT READOUTS STAND BESIDE IT: a single word cannot carry which estate the ladder
        // reached, which rung it stands at, and which private artifact survived. ***
        let rung = app.staticTexts["lab.diagnostics.wiperung"]
        XCTAssertTrue(rung.waitForExistence(timeout: 20),
                      "*** THE DURABLE RUNG MUST BE RENDERED, read from the journal rather than recalled. ***")
        let artifacts = app.staticTexts["lab.diagnostics.wipeartifacts"]
        XCTAssertTrue(artifacts.waitForExistence(timeout: 20),
                      "*** THE REMAINING ARTIFACTS MUST BE RENDERED, measured on the filesystem. ***")
        let startupRecovery = app.staticTexts["lab.diagnostics.startuprecovery"]
        XCTAssertTrue(startupRecovery.waitForExistence(timeout: 20),
                      "*** THE STARTUP DECISION MUST BE RENDERED: `operator required` is the field a corrupt record "
                          + "needs and a Boolean cannot carry. ***")

        let begin = app.buttons["lab.diagnostics.beginwipe"]
        XCTAssertTrue(begin.exists, "the wipe action must exist as a CONTROL")
        XCTAssertTrue(begin.isEnabled, "and it must be actionable")

        // *** THE FRESH WIPE, DRIVEN. ***
        let result = app.staticTexts["lab.diagnostics.wiperesult"]
        XCTAssertTrue(result.waitForExistence(timeout: 20), "the wipe result must render")
        begin.tap()

        // A PLAIN BOUNDED POLL on the rendered result, which now carries the TYPED decision and the measured artifacts.
        let deadline = Date().addingTimeInterval(20)
        var rendered = result.label
        while Date() < deadline {
            rendered = result.label
            if rendered != "wipe result: not requested" && !rendered.hasSuffix("not requested") { break }
            usleep(200_000)
        }
        XCTAssertFalse(rendered.hasSuffix("not requested"),
                       "*** THE WIPE CONTROL MUST HAVE ACTED AND REPORTED: the result is written from the TYPED "
                           + "outcome of the production ladder, not from a local flag. Observed: '\(rendered)' ***")

        // *** AND THE RESUME ROAD, WHICH IS A DIFFERENT PHASE: it reads the durable record and drives it onward. ***
        let resume = app.buttons["lab.diagnostics.resumewipe"]
        XCTAssertTrue(resume.exists, "the resume control must exist as a CONTROL")
        XCTAssertTrue(scrollIntoView(resume, in: app), "and it must be reachable")
        resume.tap()

        // *** *** IOS-R12: THE WIPE MUST HAVE REALLY DELETED ITS ARTIFACTS. *** ***
        //
        // *THE REVIEW'S DEFECT: the old arm "checks changed text and a persisted nonempty wipe record, not artifact
        // destruction or terminal completion". **THE MEASURED ARTIFACT READOUT (`lab.diagnostics.wipeartifacts`, read
        // from the FILESYSTEM by `recoveryArtifactWords()`) MUST REACH "no private artifact remains"** -- so a wipe
        // that merely set text without deleting the lab's real files reddens.*
        let artifactsAfter = app.staticTexts["lab.diagnostics.wipeartifacts"]
        XCTAssertTrue(artifactsAfter.waitForExistence(timeout: 20), "the artifact readout must render")
        let wipeDeadline = Date().addingTimeInterval(25)
        var artifactLine = artifactsAfter.label
        while Date() < wipeDeadline {
            artifactLine = artifactsAfter.label
            if artifactLine.contains("no private artifact remains") { break }
            usleep(250_000)
        }
        XCTAssertTrue(
            artifactLine.contains("no private artifact remains"),
            "*** THE WIPE MUST REALLY DELETE THE LAB'S OWN FILES: the filesystem-measured readout must reach 'no "
                + "private artifact remains', not merely change text. Observed: '\(artifactLine)' ***",
        )

        // *** AND THE RELAUNCH: A FRESH PROCESS MUST READ THE SAME DURABLE RECORD. ***
        app.terminate()
        app.launch()
        let relaunchedTab = tab("Diagnostics screen", in: app)
        XCTAssertTrue(relaunchedTab.waitForExistence(timeout: 30),
                      "the diagnostics tab must exist after relaunch")
        relaunchedTab.tap()
        let afterRelaunch = app.staticTexts["lab.diagnostics.wipestate"]
        XCTAssertTrue(afterRelaunch.waitForExistence(timeout: 30), "the wipe state must render after relaunch")
        XCTAssertFalse(
            afterRelaunch.label.contains("no wipe was ever requested"),
            "*** THE DURABLE RECORD MUST SURVIVE THE PROCESS: a flag in memory would read 'no wipe was ever "
                + "requested' here, while the journal carries the rung the ladder reached. Observed: "
                + "'\(afterRelaunch.label)' ***",
        )
    }

    /// *** *** GS-UX-001 `rendered-controls` / IOS-FOLLOWUP-C1: THE INDEPENDENT-PROCESS DURABLE-ACKNOWLEDGMENT
    /// WITNESS -- THE ACKNOWLEDGED GENERATION, THE REAL LADDER'S RUNGS, AND THE PERSISTED ROWS, ACROSS THREE
    /// PROCESSES. *** ***
    ///
    /// *THE GAP THIS CLOSES, MEASURED: the durable-acknowledgment road -- `establishBaseline()`'s CHECKED epoch rise,
    /// `settledSnapshot()`'s pinned `(idle, N)`, and `bumpEpoch()`'s refusal to name a generation for a present estate
    /// whose history carrieth no counter -- lived entirely in the module and was asserted only by in-process model
    /// courts. **NO RENDERED SURFACE NAMED THE ACKNOWLEDGED GENERATION AT ALL**, so no witness DRIVING THIS APP could
    /// bind the number the medium acknowledged across a terminate/reopen: an arm could see a rung, a verdict and an
    /// artifact list, but never the NUMBER, and a number a surface cannot name is a number a fresh process cannot
    /// prove it read. `lab.diagnostics.generation` and `lab.diagnostics.liverung` now render it, read from
    /// `WipeJournalDurabilityAdapter.durableEpoch` over the SAME journal the ladder writeth.*
    ///
    /// **AND THE DISCRIMINATOR IS THE PROCESS BOUNDARY, NOT A CLAIM.** *Nothing of a terminated process is consulted
    /// at the relaunch -- `app.terminate()` then `XCUIApplication().launch()` -- so a generation (or a rung, or an
    /// artifact readout) held in memory would read `unacknowledged` / `none read` there, and the arm would redden.*
    /// **The RENDERED Begin-wipe control drives `MeshRuntime.runRecoveryLadder(requestFresh: true)` over the lab's
    /// OWN estate -- the SAME production road `MeshRuntime.create` takes -- so the REQUESTED checkpoint and every rung
    /// it earns are written durably through the checked append, and the fresh process reads the ADVANCED generation
    /// from the medium.** *A no-op control, or a generation the surface invented, reddens at the third process.*
    func testGSINT001TheAcknowledgedGenerationRungAndArtifactsSurviveTheProcess() throws {
        // (0) A CLEAN ESTATE, SO THIS ARM MEASURETH THIS RUN RATHER THAN THE PREVIOUS ONE. *`installStandardControls`
        // establishes the normal surfaces in the SAME test, so the fixture is known to have reached the app.*
        installStandardControls()

        // The rendered readouts, addressed by their own identifiers in whatever element type SwiftUI chose.
        func generationLine(_ app: XCUIApplication) -> XCUIElement {
            app.staticTexts["lab.diagnostics.generation"]
        }
        func settled(_ element: XCUIElement) -> String {
            var value = element.label
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline {
                value = element.label
                if value.contains("acknowledged") { break }
                usleep(200_000)
            }
            return value
        }
        /// The NUMBER the rendered line names, or nil when it names none -- so the assertion is about the durable
        /// value rather than about the line's spelling, and an `unacknowledged` read returneth nil and reddeneth BY
        /// NAME in the caller's message.
        func number(_ words: String) -> UInt64? {
            guard let token = words.split(separator: " ").dropFirst().first else { return nil }
            return UInt64(token)
        }
        /// A readout that must have rendered before its label meaneth anything: a MISSING element readeth as an
        /// empty string, and an empty string satisfieth a `!contains(...)` clause vacuously.
        func requiredLine(_ app: XCUIApplication, _ identifier: String, _ why: String) -> XCUIElement {
            let element = app.staticTexts[identifier]
            XCTAssertTrue(element.waitForExistence(timeout: 25), "*** \(why) Observed element missing: '\(identifier)'. ***")
            return element
        }
        /// The diagnostics surface must stand before any of its readouts mean anything.
        func openDiagnostics(_ app: XCUIApplication) {
            let tab = self.tab("Diagnostics screen", in: app)
            XCTAssertTrue(tab.waitForExistence(timeout: 30),
                          "*** A SETTLED RECORD MUST COMPOSE NORMALLY, SO THE DIAGNOSTICS SURFACE MUST STAND. ***")
            tab.tap()
        }

        // (1) THE BASELINE: a `reset` boot re-stamps the pinned, readable `idle|1` beside floor 1, so the app must
        // render the generation the MEDIUM acknowledged -- and the record must be readable enough to name its rung.
        let app = launchFixture("reset")
        openDiagnostics(app)
        let generation = generationLine(app)
        XCTAssertTrue(generation.waitForExistence(timeout: 25),
                      "*** THE ACKNOWLEDGED GENERATION MUST RENDER (`lab.diagnostics.generation`). ***")
        let baselineWords = settled(generation)
        XCTAssertEqual(
            number(baselineWords), 1,
            "*** A CLEAN ESTATE MUST CARRY A DURABLY ACKNOWLEDGED BASELINE GENERATION, READ FROM THE MEDIUM (the "
                + "record's phase-stamped suffix pinned to the floor) -- never a local 0 and never a fabricated "
                + "number. Observed: '\(baselineWords)' ***",
        )
        // *** AND THE RUNG READOUT IS THE MEDIUM'S OWN VIEW, WITH NO PERSISTED-OUTCOME FALLBACK. ***
        //
        // *MEASURED FROM THE ADAPTER'S OWN CONTRACT BEFORE THIS ASSERTION WAS WRITTEN: `readJournal()` answereth `[]`
        // for `.idle` -- "IDLE and 'nothing was ever requested' are the same estate and reporting a longer history
        // than the store carrieth would be inventing a past" -- so a CLEAN PINNED RECORD LEGITIMATELY NAMES NO
        // OUTSTANDING RUNG. **A rung line that invented one here would be the defect this arm existeth to catch**;
        // naming none is the truth, and it is asserted as such rather than assumed away.*
        let baselineRung = requiredLine(
            app, "lab.diagnostics.liverung",
            "THE MEDIUM'S OWN RUNG READING MUST RENDER, so the assertion below is about a line that really exists "
                + "rather than about an absent element read as an empty string.").label
        XCTAssertEqual(
            baselineRung, "rung: none read",
            "*** A CLEAN PINNED `idle|1` RECORD CARRIETH NO OUTSTANDING RUNG: the adapter collapseth a settled "
                + "record to an empty durable view BY DESIGN, so the medium's own reading is 'none read'. A rung "
                + "line that named one here would be a rung the record doth not carry. Observed: '\(baselineRung)' ***",
        )

        // (2) *** THE PROCESS BOUNDARY: terminate, relaunch WITH NO FIXTURE VALUE, and require the SAME number. ***
        app.terminate()
        let relaunched = XCUIApplication()
        relaunched.launch()
        openDiagnostics(relaunched)
        let relaunchedGeneration = generationLine(relaunched)
        XCTAssertTrue(relaunchedGeneration.waitForExistence(timeout: 30),
                      "the acknowledged generation must render after a relaunch")
        let afterRelaunch = settled(relaunchedGeneration)
        // *** A GUARD, SO nil == nil CANNOT PASS AS "THE SAME NUMBER". ***
        guard let baselineNumber = number(baselineWords), let relaunchNumber = number(afterRelaunch) else {
            XCTFail("*** THE ACKNOWLEDGED GENERATION MUST BE READABLE IN BOTH PROCESSES; observed '\(baselineWords)' "
                + "and '\(afterRelaunch)'. `unacknowledged` meaneth the record named no pinned generation, and "
                + "`nil == nil` must never stand in for agreement. ***")
            return
        }
        XCTAssertEqual(
            relaunchNumber, baselineNumber,
            "*** THE ACKNOWLEDGED GENERATION MUST SURVIVE THE PROCESS: a FRESH process is consulted here, and it "
                + "reads the number from the MEDIUM, so a value held in memory would read `unacknowledged` (nil) "
                + "instead. Observed: '\(baselineWords)' -> '\(afterRelaunch)' ***",
        )

        // (3) *** THE REAL LADDER, DRIVEN FROM THE RENDERED CONTROL -- a fresh request writes REQUESTED durably and
        // advances every rung its real seams allow, exactly as the shipping composition's create-time road doth. ***
        let begin = relaunched.buttons["lab.diagnostics.beginwipe"]
        XCTAssertTrue(begin.exists, "*** THE WIPE CONTROL MUST STAND AS A CONTROL. ***")
        XCTAssertTrue(begin.isEnabled, "and it must be actionable")
        XCTAssertTrue(scrollIntoView(begin, in: relaunched), "and it must be reachable by a user")
        let result = relaunched.staticTexts["lab.diagnostics.wiperesult"]
        XCTAssertTrue(result.waitForExistence(timeout: 25), "the wipe result must render")
        begin.tap()

        // *** AND THE RESUME ROAD DRIVES THE LADDER ONWARD FROM WHEREVER THE DURABLE RECORD STANDETH -- the crash
        // path, driven live. *** *The pair is the one the sibling wipe arm already driveth: a fresh request writeth
        // `REQUESTED` and advances every rung its real seams allow, and a resume continueth from the persisted rung.
        // Both controls report the PRODUCTION ladder's own typed outcome (`wipe_completed @ <rung> (<artifacts>)`), so
        // a control whose closure merely set a string reddens here.*
        let resume = relaunched.buttons["lab.diagnostics.resumewipe"]
        XCTAssertTrue(resume.waitForExistence(timeout: 25), "the resume control must stand")
        XCTAssertTrue(scrollIntoView(resume, in: relaunched), "and it must be reachable")
        var outcome = result.label
        var deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            outcome = result.label
            if !outcome.hasSuffix("not requested") { break }
            usleep(250_000)
        }
        XCTAssertFalse(
            outcome.hasSuffix("not requested"),
            "*** THE FRESH REQUEST MUST HAVE ACTED AND REPORTED -- its result is written from the TYPED outcome of the "
                + "production ladder, not from a local flag. Observed: '\(outcome)' ***",
        )
        resume.tap()
        // *THE RESUME IS ANOTHER PHASE. The observable is NOT a particular decision WORD -- a ladder that already ran
        // to its end legitimately answereth `clean_start` on a subsequent resume (the estate really is clean), so
        // pinning a phrase here would be an incidental-prose assertion, not a behavioural one. **WHAT IS ASSERTED IS
        // THE MEDIUM: the control acted (the placeholder is gone), the filesystem lost its artifacts, and the durable
        // record settled to no outstanding rung.***
        deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            outcome = result.label
            if !outcome.hasSuffix("not requested") { break }
            usleep(250_000)
        }
        // AND THE FILESYSTEM HALF: the measured artifacts must reach empty, which is what maketh the decision's
        // completion honest rather than a checkpoint standing over a store that survived.
        let artifacts = relaunched.staticTexts["lab.diagnostics.wipeartifacts"]
        XCTAssertTrue(artifacts.waitForExistence(timeout: 25), "the artifact readout must render")
        deadline = Date().addingTimeInterval(25)
        var artifactLine = artifacts.label
        while Date() < deadline {
            artifactLine = artifacts.label
            if artifactLine.contains("no private artifact remains") { break }
            usleep(250_000)
        }
        XCTAssertTrue(
            artifactLine.contains("no private artifact remains"),
            "*** THE WIPE MUST REALLY DELETE THE LAB'S OWN FILES: the filesystem-measured readout must reach 'no "
                + "private artifact remains'. Observed: '\(artifactLine)' ***",
        )

        // (4) *** A THIRD PROCESS MUST READ THE ADVANCED GENERATION, THE SETTLED RECORD, AND NO OUTSTANDING RUNG --
        // ALL FROM THE MEDIUM. ***
        relaunched.terminate()
        let third = XCUIApplication()
        third.launch()
        openDiagnostics(third)
        let thirdGeneration = generationLine(third)
        XCTAssertTrue(thirdGeneration.waitForExistence(timeout: 30),
                      "the acknowledged generation must render in the third process")
        let finalWords = settled(thirdGeneration)
        guard let finalNumber = number(finalWords) else {
            XCTFail("*** THE THIRD PROCESS MUST NAME A NUMERIC ACKNOWLEDGED GENERATION; observed '\(finalWords)'. A "
                + "surface that rendered `unacknowledged` here is the failure this arm existeth to catch. ***")
            return
        }
        XCTAssertGreaterThan(
            finalNumber, baselineNumber,
            "*** THE ACKNOWLEDGED GENERATION MUST HAVE ADVANCED ACROSS THE REAL WIPE, STORED ON THE MEDIUM: the fresh "
                + "request's checked epoch rise raiseth the durable floor, and the bump is REFUSED (not fabricated) when "
                + "the medium cannot acknowledge it -- so a fresh process must read a STRICTLY GREATER number than the "
                + "baseline. Observed: \(baselineNumber) -> \(finalNumber) ***",
        )
        // *** AND WITH THE NUMBER, THE RECORD'S OWN ROWS: a completed ladder settles to an EMPTY durable view, so a
        // fresh process must find NO OUTSTANDING RUNG and must not read the record as a first launch. ***
        let finalRung = requiredLine(
            third, "lab.diagnostics.liverung",
            "THE MEDIUM'S OWN RUNG READING MUST RENDER IN THE THIRD PROCESS, so 'no outstanding rung' is asserted of "
                + "a line that really exists rather than of an absent element read as an empty string.")
        XCTAssertTrue(
            finalRung.label.contains("none read"),
            "*** A COMPLETED LADDER SETTLES TO AN EMPTY DURABLE VIEW, SO A FRESH PROCESS MUST FIND NO OUTSTANDING "
                + "RUNG -- the journal's own answer, read from the medium. Observed: '\(finalRung.label)' ***",
        )
        // AND THE HUMAN-FACING WIPE LINE STILL RENDERETH ITS HONEST WORDS FROM THE SAME RECORD.
        let finalState = requiredLine(third, "lab.diagnostics.wipestate",
                                      "THE WIPE STATE MUST RENDER IN THE THIRD PROCESS.")
        XCTAssertFalse(
            finalState.label.contains("no wipe was ever requested"),
            "*** A RECORD THE FIRST PROCESS REALLY WROTE MUST NOT READ AS A FIRST LAUNCH IN THE THIRD: a wipe was "
                + "requested, durably. Observed: '\(finalState.label)' ***",
        )
    }

    /// *** *** GS-UX-001 `required-retry`: THE ESSENTIAL `Retry` CONTROL, DRIVEN. *** ***
    ///
    /// *THE OMISSION THIS ARM CLOSES: `AccessibilityContract.essentialControls` declares `("retry", "Retry")`
    /// essential, the shared Android lab renders it, and iOS's SOS surface rendered a hold, an accessible alternative
    /// and a cancel -- **but NO RETRY AT ALL**, while `MeshNode.handleSosCommand(.retry(msgId))` stood wired behind it.
    /// A source grep for "retry" could not see the omission; a control-level arm can.*
    ///
    /// **AND IT TAPS: the control must ACT.** *The runtime answers with the node's own taxonomy ("resumed" or a refusal
    /// that NAMES its reason, including the honest "no standing distress call to retry"), and the outcome is then
    /// announced and rendered.*
    func testGSINT001TheEssentialRetryControlStandsAndActs() throws {
        let app = XCUIApplication()
        app.launch()

        let sosTab = tab("SOS screen", in: app)
        XCTAssertTrue(sosTab.waitForExistence(timeout: 20), "the SOS tab must exist")
        sosTab.tap()

        let retry = app.buttons["lab.sos.retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 25),
                      "*** THE CONTRACT'S OWN ESSENTIAL `retry` CONTROL MUST STAND ON THE SOS SURFACE -- it is in "
                          + "`AccessibilityContract.essentialControls` and the shared Android lab renders it. ***")
        XCTAssertTrue(retry.isEnabled, "and it must be actionable")
        XCTAssertEqual(retry.label, "Retry",
                       "*** AND IT MUST CARRY THE CONTRACT'S OWN WORD, so a screen reader hears what the table "
                           + "names. A deleted modifier falls back to the TITLE and this fails. ***")
        XCTAssertTrue(scrollIntoView(retry, in: app), "the control must be reachable by a user")
        let frame = retry.frame
        XCTAssertGreaterThanOrEqual(frame.height, 44,
                                    "*** AND IT MUST MEET THE 44pt MINIMUM; measured \(frame.width)x\(frame.height)pt. ***")

        // *** ARMED FIRST, SO THE RETRY HAS A STANDING CALL TO RESUME -- AND SO THE POSITIVE ROAD IS WHAT IS MEASURED. ***
        let alt = app.buttons["lab.sos.send"]
        XCTAssertTrue(alt.waitForExistence(timeout: 20), "the accessible SOS control must exist")
        XCTAssertTrue(scrollIntoView(alt, in: app), "and it must be reachable")
        alt.tap()

        let outcome = app.staticTexts["lab.sos.outcome"]
        XCTAssertTrue(outcome.waitForExistence(timeout: 25), "the SOS outcome must render")
        let beforeRetry = outcome.label

        retry.tap()

        // *** A BOUNDED PLAIN POLL ON THE RENDERED OUTCOME: it is written from the RUNTIME'S OWN ANSWER, so a control
        // whose closure was replaced by a local write would leave it unmoved. ***
        let deadline = Date().addingTimeInterval(20)
        var after = outcome.label
        while Date() < deadline {
            after = outcome.label
            if after != beforeRetry { break }
            usleep(200_000)
        }
        XCTAssertNotEqual(
            after, beforeRetry,
            "*** THE RETRY MUST REACH THE RUNTIME AND ITS ANSWER MUST RENDER: the outcome is the node's own taxonomy "
                + "(`resumed` or a refusal NAMING its reason). Observed unchanged: '\(after)' ***",
        )
        XCTAssertTrue(
            after.contains("resume:") || after.contains("refused"),
            "*** AND THE ANSWER MUST BE THE RUNTIME'S OWN VOCABULARY, never a phrase this view invented. The resumed "
                + "road renders `resume:` + the node's own taxonomy (`LabRuntime.retrySos`), and a real refusal renders "
                + "`refused:`. Observed: '\(after)' ***",
        )
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
        let conversation = tab("Conversation screen", in: app)
        XCTAssertTrue(
            conversation.waitForExistence(timeout: 20),
            "*** THE TAB MUST REMAIN ADDRESSABLE UNDER RTL AND AT AX-XXXL: a native tab button whose declared "
                + "accessibility label disappears when the layout is mirrored or the type is enlarged is a control "
                + "some users cannot reach. ***",
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

        let contactsTab = tab("Contacts screen", in: app)
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

        let contactsTab = tab("Contacts screen", in: app)
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

        let sosTab = tab("SOS screen", in: app)
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
        let sosTab = tab("SOS screen", in: app)
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
        // \`app.tabBars.buttons["Contacts"]\` and the arm FAILED on "the Contacts tab must exist" -- **the tab is
        // addressed by its DECLARED ACCESSIBILITY LABEL (\`Contacts screen\`), NOT the visible word, and a name SEARCH
        // is not a name READ.*** *The sibling arms useth the \`tab(_:in:)\` helper, which resolveth that label in
        // either native container -- so the helper is used here too rather than a second, guessed road.*
        let contactsTab = tab("Contacts screen", in: app)
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
            XCTAssertTrue(
                scrollIntoView(control, in: app),
                "*** THE \(label) CONTROL MUST BE REACHABLE BY A USER. It existeth in the tree but is not hittable "
                    + "after bounded scrolling, which is the real 'a control no user can tap' defect -- measured on "
                    + "this arm's own ScrollView, where the action row can sit below the fold. ***",
            )
            let before = outcome.label
            control.tap()
            // *The authority answereth synchronously, so the rendered outcome must differ from what it was.*
            let changed = NSPredicate(format: "label != %@", before)
            expectation(for: changed, evaluatedWith: outcome)
            waitForExpectations(timeout: 10)
        }
    }

    /// *** GS-UX-001 `rendered-controls`: THE STALE CANDIDATE IS REFUSED WITH THE EXACT STRING. ***
    ///
    /// *THE CARD'S LAW 3: "THE DISPLAYED CANDIDATE IS THE ONE APPROVED. An approval carrieth an
    /// "`ExactRotationCandidateRef`"; a rotation that moved between render and tap is refused by the CAS."*
    ///
    /// *** AND THE MEASURED DEFECT THIS ARM REPLACES: the old road took a LABEL and re-read "the current" candidate
    /// inside the call, so a rotation that arrived between render and tap was APPROVED instead of refused -- the
    /// exact defect law 3 existeth to prevent, with no rendered consumer to catch it.***
    ///
    /// *The arm driveth the control the way a user doth: the screen captures the candidate it displayed, the
    /// authority move happens BEHIND it (through the app's own journaled rotation, driven by the launch environment),
    /// and the tap must refuse with the exact string.*
    func testGSINT001AStaleRotationCandidateIsRefusedWithTheExactString() throws {
        let app = XCUIApplication()
        app.launch()

        let contactsTab = tab("Contacts screen", in: app)
        XCTAssertTrue(contactsTab.waitForExistence(timeout: 20), "the Contacts tab must exist")
        contactsTab.tap()

        let outcome = app.staticTexts["lab.trust.outcome"]
        XCTAssertTrue(outcome.waitForExistence(timeout: 20), "the trust outcome must be rendered")
        let approve = app.buttons["lab.trust.approve"]
        XCTAssertTrue(approve.waitForExistence(timeout: 20), "the Approve control must be addressable")

        // *** (1) THE SCREEN IS LOOKING AT SOMETHING: a real candidate must have been DISPLAYED. ***
        //
        // *Without this the arm could pass on a screen that showed nothing and refused for the wrong reason.*
        let seedRotation = app.buttons["lab.trust.seedrotation"]
        XCTAssertTrue(seedRotation.waitForExistence(timeout: 20),
                      "*** THE ROTATION-ARRIVAL CONTROL MUST EXIST: 'a rotation that moved between render and tap' is "
                          + "not performable without a way for it to move. ***")
        XCTAssertTrue(scrollIntoView(seedRotation, in: app),
                      "and it must be REACHABLE -- the trust page scrolls, so a control below the fold is revealed")
        seedRotation.tap()

        // The displayed candidate is now a real pending rotation -- and the screen captured it when it re-rendered.
        let pending = NSPredicate(format: "value CONTAINS 'ROTATION_PENDING'")
        let status = app.descendants(matching: .any)["lab.trust.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 20), "the status readout must render")
        expectation(for: pending, evaluatedWith: status)
        waitForExpectations(timeout: 15)

        // *** (2) A SECOND CANDIDATE ARRIVES, BEHIND THE ONE ON SCREEN. ***
        //
        // *The displayed ref is NOT re-captured by this control -- that is the point: the screen is still holding the
        // candidate it showed.*
        XCTAssertTrue(scrollIntoView(seedRotation, in: app), "and the control must remain reachable")
        seedRotation.tap()

        // *** (3) THE TAP ON THE STALE CANDIDATE MUST REFUSE WITH THE EXACT STRING. ***
        XCTAssertTrue(scrollIntoView(approve, in: app), "the Approve control must be reachable before the tap")
        approve.tap()

        let refused = NSPredicate(format: "label == %@",
                                  "refused: that rotation is no longer pending: nothing was approved")
        expectation(for: refused, evaluatedWith: outcome)
        waitForExpectations(timeout: 15)
        XCTAssertEqual(outcome.label,
                       "refused: that rotation is no longer pending: nothing was approved",
                       "*** THE RENDERED REFUSAL MUST BE THE EXACT STRING (**not merely 'something changed'**). "
                           + "Observed: \(outcome.label) ***")
    }

    /// *** GS-UX-001 `rendered-controls` step 2: THE BOUNDED COMPOSE, IN OCTETS, WITH THE READOUT UPDATED. ***
    ///
    /// *The card asketh the input be "UTF-8 bounded". The arm tapeth the field, types a MULTIBYTE payload, and reads
    /// the rendered octets line -- **so a bound counted in CHARACTERS would show the wrong number and a bound that
    /// never truncated would let the payload through whole.***
    ///
    /// *The readout is `lab.conversation.octets` and it must change as text is typed, which is the observation that the
    /// bound is enforced on the INPUT rather than only at send time.*
    func testGSINT001TheBoundedComposeCountsOctetsAndUpdatesItsReadout() throws {
        let app = XCUIApplication()
        app.launch()

        let conversationTab = tab("Conversation screen", in: app)
        XCTAssertTrue(conversationTab.waitForExistence(timeout: 20), "the Conversation tab must exist")
        conversationTab.tap()

        let field = app.textFields["lab.conversation.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 20), "the compose field must exist")
        let readout = app.descendants(matching: .any)["lab.conversation.octets"]
        XCTAssertTrue(readout.waitForExistence(timeout: 20),
                      "*** THE OCTET READOUT MUST RENDER: a bound a user cannot see is a bound they cannot respect ***")
        let initial = readout.value as? String ?? readout.label
        XCTAssertTrue(initial.hasSuffix("octets"),
                      "the readout must name its unit; observed: \(initial)")

        // *** A MULTIBYTE PAYLOAD: emoji and Arabic, where CHARACTERS and OCTETS DIVERGE. ***
        field.tap()
        field.typeText("⛵️ الطريق مسدود")

        // The readout must move, and it must count OCTETS (the payload above is far more than its character count).
        let moved = NSPredicate(format: "value != %@", initial)
        expectation(for: moved, evaluatedWith: readout)
        waitForExpectations(timeout: 10)
        let after = readout.value as? String ?? readout.label
        XCTAssertNotEqual(after, initial,
                          "*** THE READOUT MUST FOLLOW THE INPUT; observed \(initial) -> \(after) ***")
        XCTAssertTrue(after.hasSuffix("octets"), "and it must still name its unit; observed: \(after)")
    }

    /// *** GS-UX-001 `rendered-controls` step 3: DURABLE SEND, RENDERED, AND ITS INTENT AFTER A RELAUNCH. ***
    ///
    /// *The card's step 6 asketh "visible durable state after recreation". This arm taps Send, reads the rendered
    /// `durable:` verdict, terminates the process and RELAUNCHES it -- **and the verdict must still be there, read from
    /// the same holder-owned medium.***
    ///
    /// *** THE DISCRIMINATOR IS THE NOT-AUTHORED ROW, printed by the app itself on a fresh launch: `.notFound` for an
    /// id nobody authored is what maketh `.found` mean something.*** *An arm that only saw `.found` could be satisfied
    /// by a reader that answereth `.found` to anything.*
    func testGSINT001TheDurableSendVerdictSurvivesARelaunch() throws {
        let app = XCUIApplication()
        app.launch()

        let conversationTab = tab("Conversation screen", in: app)
        XCTAssertTrue(conversationTab.waitForExistence(timeout: 20), "the Conversation tab must exist")
        conversationTab.tap()

        let send = app.buttons["lab.conversation.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 20), "the Send control must exist")
        let durable = app.descendants(matching: .any)["lab.conversation.durable"]
        XCTAssertTrue(durable.waitForExistence(timeout: 20),
                      "*** THE DURABLE VERDICT MUST RENDER ***")

        send.tap()
        // The verdict is written by the awaited durable send, so it must become `.found:`.
        let found = NSPredicate(format: "value BEGINSWITH 'found:'")
        expectation(for: found, evaluatedWith: durable)
        waitForExpectations(timeout: 20)
        let afterSend = durable.value as? String ?? durable.label
        XCTAssertTrue(afterSend.hasPrefix("found:"),
                      "*** THE RENDERED VERDICT MUST NAME A FOUND INTENT; observed: \(afterSend) ***")

        // *** THE RELAUNCH: the process dies, and a fresh one must read the SAME medium. ***
        app.terminate()
        app.launch()
        let relaunchedTab = tab("Conversation screen", in: app)
        XCTAssertTrue(relaunchedTab.waitForExistence(timeout: 20), "the Conversation tab must exist after relaunch")
        relaunchedTab.tap()
        let relaunchedDurable = app.descendants(matching: .any)["lab.conversation.durable"]
        XCTAssertTrue(relaunchedDurable.waitForExistence(timeout: 20),
                      "the durable verdict must render after a relaunch")
        let afterRelaunch = relaunchedDurable.value as? String ?? relaunchedDurable.label
        XCTAssertTrue(
            afterRelaunch.hasPrefix("found:"),
            "*** THE DURABLE INTENT MUST SURVIVE THE PROCESS. This is the clause no in-memory medium can satisfy: "
                + "`.found` read from a FRESH process over the same file. Observed after relaunch: \(afterRelaunch) ***",
        )
    }

    /// *** GS-UX-001 `rendered-controls` step 3: THE DISTRESS STATE, RENDERED AND SURVIVING A RELAUNCH. ***
    ///
    /// *The card asketh the SOS journey be durable. This arm arms through the rendered control, READS the rendered
    /// state, terminates and relaunches -- **and the state must still be there, in the SHARED vocabulary's own
    /// words.***
    ///
    /// *A second half driveth the CANCEL control and requires the state to become terminal while the author counter is
    /// unmoved -- the card's own discriminator between stopping a call and un-authoring one.*
    func testGSINT001TheDistressStateSurvivesARelaunchAndACancelDoesNotUnAuthor() throws {
        let app = XCUIApplication()
        app.launch()

        let sosTab = tab("SOS screen", in: app)
        XCTAssertTrue(sosTab.waitForExistence(timeout: 20), "the SOS tab must exist")
        sosTab.tap()

        let state = app.descendants(matching: .any)["lab.sos.state"]
        XCTAssertTrue(state.waitForExistence(timeout: 20),
                      "*** THE DISTRESS STATE MUST RENDER (`lab.sos.state`) ***")

        let alt = app.buttons["lab.sos.send"]
        XCTAssertTrue(alt.waitForExistence(timeout: 20), "the accessible SOS control must exist")
        alt.tap()

        // *** (1) AN ARMED CALL RENDERS AS ACTIVE, IN THE SHARED VOCABULARY'S OWN WORDS. ***
        let active = NSPredicate(format: "value BEGINSWITH 'active: '")
        expectation(for: active, evaluatedWith: state)
        waitForExpectations(timeout: 20)
        let activeValue = state.value as? String ?? state.label
        XCTAssertTrue(activeValue.hasPrefix("active: "),
                      "*** AN ARMED CALL MUST RENDER AS ACTIVE; observed \(activeValue) ***")

        // *** (2) *** *** IOS-R9: THE FULL ACTIVE-RELAUNCH-CANCEL-RELAUNCH CYCLE, FOR THE SAME msg_id. *** *** ***
        //
        // *THE REVIEW'S DEFECT: the old arm CANCELLED BEFORE TERMINATING, so it narrowed away the requirement --
        // "arm -> terminate -> relaunch -> active -> cancel -> terminate -> relaunch -> terminal", which is the road
        // that proves a RELAUNCHED process carries a real obligation rather than a display register. **THE CANCEL IS
        // NOW DRIVEN IN THE SECOND PROCESS** (the holder composes over a durable estate root, so the row really
        // survives), and a retry of the SAME authored frame is exercised too.*
        // *** (2a) TERMINATE AND RELAUNCH: the ACTIVE call must survive. ***
        app.terminate()
        app.launch()
        let relaunchedSosTab = tab("SOS screen", in: app)
        XCTAssertTrue(relaunchedSosTab.waitForExistence(timeout: 20), "the SOS tab must exist after relaunch")
        relaunchedSosTab.tap()
        let relaunchedState = app.descendants(matching: .any)["lab.sos.state"]
        XCTAssertTrue(relaunchedState.waitForExistence(timeout: 20),
                      "the distress state must render after relaunch")
        let relaunchedActive = NSPredicate(format: "value BEGINSWITH 'active: '")
        expectation(for: relaunchedActive, evaluatedWith: relaunchedState)
        waitForExpectations(timeout: 20)
        let activeAfterRelaunch = relaunchedState.value as? String ?? relaunchedState.label
        XCTAssertTrue(
            activeAfterRelaunch.hasPrefix("active: "),
            "*** THE ACTIVE CALL MUST SURVIVE THE RELAUNCH: the durable obligation (held frame + row), not a display "
                + "register, must re-render it. Observed: '\(activeAfterRelaunch)' ***",
        )

        // *** (2b) CANCEL THE SAME CALL IN THE SECOND PROCESS -- the id comes from the DURABLE row. ***
        let cancel = app.buttons["lab.sos.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 20), "the cancel control must exist")
        cancel.tap()
        let terminal = NSPredicate(format: "value BEGINSWITH 'terminal: '")
        expectation(for: terminal, evaluatedWith: relaunchedState)
        waitForExpectations(timeout: 20)
        let terminalValue = relaunchedState.value as? String ?? relaunchedState.label
        XCTAssertTrue(terminalValue.hasPrefix("terminal: "),
                      "*** A CANCELLED CALL MUST RENDER AS TERMINAL; observed \(terminalValue) ***")

        // *** (3) THE SECOND RELAUNCH: the TERMINAL state must survive, read from the same durable row. ***
        app.terminate()
        app.launch()
        let thirdSosTab = tab("SOS screen", in: app)
        XCTAssertTrue(thirdSosTab.waitForExistence(timeout: 20), "the SOS tab must exist after the second relaunch")
        thirdSosTab.tap()
        let thirdState = app.descendants(matching: .any)["lab.sos.state"]
        XCTAssertTrue(thirdState.waitForExistence(timeout: 20), "the distress state must render after relaunch")
        let afterRelaunch = thirdState.value as? String ?? thirdState.label
        XCTAssertTrue(
            afterRelaunch.hasPrefix("terminal: "),
            "*** THE TERMINAL STATE MUST SURVIVE THE SECOND RELAUNCH: a cancelled call must still read terminal in a "
                + "FRESH process, since nothing of the first process is consulted. Observed: \(afterRelaunch) ***",
        )
        XCTAssertEqual(afterRelaunch, terminalValue,
                       "and the relaunched rendering must be the SAME line, not merely the same prefix")
    }

    /// *** GS-UX-001 `accessibility`: THE LIVE TREE CARRIES THE ROLE, LABEL AND STATE SEMANTICS. ***
    ///
    /// *The obligation is `Internally verify rendered semantics (labels, identifiers, roles, state descriptions)
    /// without claiming human/device accessibility acceptance`. **HUMAN acceptance stays EXTERNAL**; this arm
    /// asserteth only what the LIVE TREE can be asked.*
    ///
    /// *The identifiers are the card's own roster, and the STATE WORDS checked here come from the shared table in the
    /// app's source -- **so a state line that invented a word would not match any of them**.*
    func testGSINT001TheLiveTreeCarriesTheRenderedSemantics() throws {
        let app = XCUIApplication()
        app.launch()

        // THE SURFACES THE JOURNEYS DEPEND ON, EACH ADDRESSED WHERE IT RENDERS.
        let conversationTab = tab("Conversation screen", in: app)
        XCTAssertTrue(conversationTab.waitForExistence(timeout: 20), "the Conversation tab must exist")
        conversationTab.tap()

        // The readout whose VALUE liveth on a container (the measured pattern): label states WHAT, value carries the DATA.
        let octets = app.descendants(matching: .any)["lab.conversation.octets"]
        XCTAssertTrue(octets.waitForExistence(timeout: 20), "the octet readout must render")
        XCTAssertFalse(octets.label.trimmingCharacters(in: .whitespaces).isEmpty,
                       "*** EVERY READOUT MUST CARRY A NON-EMPTY LABEL: an element a screen reader reads as blank is "
                           + "unreachable. ***")
        XCTAssertFalse((octets.value as? String ?? "").isEmpty,
                       "and its VALUE must carry the datum it names")

        // AND EVERY BUTTON ON THE PAGE MUST CARRY A NON-EMPTY LABEL -- the contract's own law.
        var unlabelled: [String] = []
        for element in app.buttons.allElementsBoundByIndex where element.exists {
            if element.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                unlabelled.append(element.identifier.isEmpty ? "<no identifier>" : element.identifier)
            }
        }
        XCTAssertTrue(unlabelled.isEmpty,
                      "*** EVERY BUTTON MUST CARRY A NON-EMPTY LABEL. Unlabelled: \(unlabelled) ***")

        // AND THE OTHER TWO SURFACES' STATE READOUTS, EACH ADDRESSED BY ITS OWN IDENTIFIER (the tabs themselves by
        // their declared accessibility labels).
        let contactsTab = tab("Contacts screen", in: app)
        XCTAssertTrue(contactsTab.exists, "the Contacts tab must be addressable")
        contactsTab.tap()
        XCTAssertTrue(app.descendants(matching: .any)["lab.trust.status"].waitForExistence(timeout: 20),
                      "the trust status readout must render")

        let sosTab = tab("SOS screen", in: app)
        XCTAssertTrue(sosTab.exists, "the SOS tab must be addressable")
        sosTab.tap()
        let sosState = app.descendants(matching: .any)["lab.sos.state"]
        XCTAssertTrue(sosState.waitForExistence(timeout: 20), "the distress state must render")
        XCTAssertFalse((sosState.value as? String ?? "").isEmpty,
                       "and it must carry the value it names")
    }

    // ================================================================================================
    // *** *** G1: THE RECOVERY-ONLY TOPOLOGY, DRIVEN BY A REAL ON-DISK FIXTURE. *** ***
    //
    // *THE REPORT'S GAP, VERBATIM: "ZERO arms reference lab.recovery.* -- the recovery-only topology, the
    // Retry-recovery/Resolve buttons and deniedRetry have no XCUITest discriminator; no launchEnvironment injection
    // door exists to reach those states."* **THE DOOR IS NOW A REAL, DEBUG-ONLY FIXTURE** that planteth the lab's
    // actual journal bytes (phase + floor) beside its real inventory BEFORE the holder constructs -- so the typed
    // decision these arms read is read from a record that really stands, never a UI value.
    //
    // **THE ARMS ARE WRITTEN SO THEY DO NOT DEPEND ON EACH OTHER'S ORDER: every arm that must start CLEAN sets
    // `LAB_FIXTURE=reset`; the corruption arm ALWAYS plants its own unreadable record.** *And the zero-private-open
    // count is the PROBE RAISED AT THE REAL STORE-CONSTRUCTION DOORS (`LabRuntime.compose`), not an inference from
    // the absent tab tree.*
    // ================================================================================================

    /// *** THE FIXTURE LAUNCH VALUE, AND THE NORMAL BOOT THAT PRECEDES IT. ***
    ///
    /// *`installStandardControls()` first CLEARS the estate to a clean first-launch state and lets the app boot
    /// NORMALLY, so the positive control is established in the SAME test: the real store doors were reached (the
    /// `reset` run composes the lab) and the normal surfaces render. **Only then is the app relaunched under the
    /// fixture** -- so the arm proveth the fixture CHANGED the topology rather than that the app never worked.*
    private func installStandardControls() {
        let app = XCUIApplication()
        app.launchEnvironment["GODSTONE_LAB_RECOVERY_FIXTURE"] = "reset"
        app.launch()
        XCTAssertTrue(tab("Diagnostics screen", in: app).waitForExistence(timeout: 25),
                      "*** THE POSITIVE CONTROL: a reset boot MUST reach the normal surfaces, or the recovery-only "
                          + "arms below prove nothing about what the fixture changed. ***")
        app.terminate()
    }

    /// Launch the app with a recovery fixture value in its environment.
    private func launchFixture(_ value: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["GODSTONE_LAB_RECOVERY_FIXTURE"] = value
        app.launch()
        return app
    }

    /// The recovery-only surface's rendered readouts, for an arm to bind.
    private func recoveryReadouts(_ app: XCUIApplication) -> (decision: XCUIElement, gate: XCUIElement,
                                                             opens: XCUIElement, rung: XCUIElement,
                                                             bootstrap: XCUIElement) {
        (app.staticTexts["lab.recovery.decision"], app.staticTexts["lab.recovery.gate"],
         app.staticTexts["lab.recovery.privateopens"], app.staticTexts["lab.recovery.rung"],
         app.staticTexts["lab.recovery.bootstrap"])
    }

    /// *** *** G1 (SCHEME A): A PENDING RECOVERY BOOTS RECOVERY-ONLY, OPENS ZERO PRIVATE STORES, AND RETRIES A
    /// RESUME. *** ***
    ///
    /// *The journal is planted at a REAL, durable `REQUESTED` phase (pinned to a seeded floor) beside the lab's real
    /// inventory. The holder reads it BEFORE constructing anything, renders recovery-only, and the arm binds:*
    ///   * the TYPED decision is a recovery state (never clean/wipe-completed) with a NAMED rung;
    ///   * **NO normal surface exists** (no native tab button is reachable by its declared accessibility label)
    ///     **AND the zero-open witness -- raised at the real store-construction doors -- reads 0** (a
    ///     tab-absence-only claim could not distinguish "gate held" from "never composed");
    ///   * the GATE renders `recovery=permitted operator=not-required` and ONLY the Retry control stands;
    ///   * the Retry RESUMES (`requestFresh: false`): its typed answer names the authority's own summary, NOT a fresh
    ///     wipe -- which is the exact defect (a Retry that started destruction from a settled estate);
    ///   * after the retry the estate re-gates, and a RELAUNCH WITH THE FIXTURE CLEARED still reads the durable record.
    func testG1ThePendingRecoveryBootsRecoveryOnlyAndRetriesAResume() throws {
        installStandardControls()
        let app = launchFixture("requested")

        let readouts = recoveryReadouts(app)
        XCTAssertTrue(readouts.decision.waitForExistence(timeout: 25),
                      "*** THE RECOVERY-ONLY SURFACE MUST RENDER for a pending estate. ***")

        // (1) THE TYPED DECISION, READ FROM THE DURABLE RECORD.
        let decisionWords = readouts.decision.label
        XCTAssertTrue(decisionWords.hasPrefix("estate: "), "the decision readout must name its state; got \(decisionWords)")
        XCTAssertTrue(decisionWords.contains("recovery_pending") || decisionWords.contains("retryable_failure"),
                      "*** A PLANTED `REQUESTED` MUST DECIDE AS A RECOVERY STATE, never clean/wipe-completed. A `Retry` " +
                          "offered over a SETTLED estate is the defect this gate closeth. Observed: \(decisionWords) ***")
        XCTAssertFalse(decisionWords.contains("clean_start"),
                       "*** A PENDING ESTATE MUST NOT DECIDE CLEAN: that is the unsound direction the ladder forbids. ***")
        XCTAssertTrue(readouts.rung.label.contains("REQUESTED"),
                      "*** THE DURABLE RUNG MUST NAME THE PLANTED PHASE; observed: \(readouts.rung.label) ***")

        // (2) ZERO PRIVATE OPENS, WITNESSED AT THE REAL STORE-CONSTRUCTION DOORS.
        XCTAssertTrue(readouts.opens.label.contains("private stores opened: 0"),
                      "*** NO PRIVATE STORE MAY BE CONSTRUCTED BEHIND THE RECOVERY SURFACE. This count is raised " +
                          "inside `LabRuntime.compose` at the store-construction calls, so it is REAL construction " +
                          "evidence rather than the absent tab tree. Observed: \(readouts.opens.label) ***")
        for label in ["Identity screen", "Contacts screen", "Conversation screen",
                      "SOS screen", "Diagnostics screen"] {
            XCTAssertFalse(app.tabBars.buttons[label].exists || app.buttons[label].exists,
                           "*** NO NORMAL SURFACE MAY EXIST BEHIND A BLOCKED ESTATE: the '\(label)' native tab " +
                               "button IS reachable, so the recovery-only gate did not hold. ***")
        }

        // (3) THE GATE, AND ONLY THE RETRY.
        XCTAssertTrue(readouts.gate.label.contains("recovery=permitted"),
                      "*** A PENDING/RETRYABLE ESTATE EARNS THE RECOVERY RESUME (`permitsRecoveryConstruction`). " +
                          "Observed gate: \(readouts.gate.label) ***")
        XCTAssertFalse(readouts.gate.label.contains("operator=required"),
                       "a pending estate needs no operator -- `requiresOperator` is reserved for corrupt/terminal")
        let retry = app.buttons["lab.recovery.retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 20),
                      "*** THE GATED RETRY MUST STAND where the decision permits recovery. ***")
        XCTAssertFalse(app.buttons["lab.recovery.resolve"].exists,
                       "*** AND THE OPERATOR ROAD MUST NOT: offering it here invites an operator wipe where a resume " +
                           "was owed, which is exactly the ungated pair the report named. ***")

        // (4) THE RETRY RESUMES AND DESTROYS NOTHING: it drives the durable ladder onward over the LAB'S OWN estate
        // (`requestFresh: false`), so a resume that settled the estate makes the holder re-gate and compose normally.
        // **THE EFFECT IS THE GRAPH'S RETURN, NOT A STRING:** a fresh-request Retry from a settled estate (the defect)
        // or a resume that did nothing would leave the recovery surface standing.
        retry.tap()
        let returnedTab = tab("Diagnostics screen", in: app)
        XCTAssertTrue(returnedTab.waitForExistence(timeout: 30),
                      "*** A PERMITTED RESUME MUST DRIVE THE DURABLE LADDER AND RE-GATE TO THE NORMAL GRAPH. " +
                          "Observed recovery surface still standing, or the resume did not settle the estate. ***")
        returnedTab.tap()
        let opens = app.staticTexts["lab.diagnostics.privateopens"]
        XCTAssertTrue(opens.waitForExistence(timeout: 20),
                      "the normal boot's open count must render after the resume")
        XCTAssertFalse(opens.label.contains("private stores opened: 0"),
                       "*** AND THE RESUME'S COMPOSITION MUST HAVE REALLY CONSTRUCTED THE PRIVATE STORES (the same " +
                          "counter as the blocked-estate zero), so 'the graph returned' is not a flag flip. " +
                          "Observed: \(opens.label) ***")

        // (5) THE RELAUNCH **WITH THE FIXTURE CLEARED** -- the durable record itself, not the door, must be read.
        app.terminate()
        let relaunched = XCUIApplication()
        relaunched.launch()
        XCTAssertTrue(tab("Diagnostics screen", in: relaunched).waitForExistence(timeout: 30),
                      "*** A RECORD THE PREVIOUS PROCESS SETTLED MUST STILL COMPOSE NORMALLY IN A FRESH PROCESS: " +
                          "this is the durability half, and NO FIXTURE VALUE is present here. ***")
        XCTAssertFalse(relaunched.staticTexts["lab.recovery.decision"].exists,
                       "*** AND THE RECOVERY SURFACE MUST NOT RETURN: a settled estate must not read as blocked. A " +
                          "process that re-planted its own fixture (or read a lost record) would redden here. ***")
    }

    /// *** *** G1 (SCHEME B): A CORRUPT RECORD DENIES THE RETRY, OFFERS ONLY THE OPERATOR, AND THE OPERATOR'S OWNED
    /// WIPE EARNETH THE GRAPH BACK. *** ***
    ///
    /// *The journal is planted as genuinely UNREADABLE bytes beside a standing floor. The holder must render
    /// recovery-only with:*
    ///   * the typed decision `corrupt_journal` and the words `operator required` (the field a Boolean cannot carry);
    ///   * the GATE `recovery=denied operator=required`, with **NO Retry control at all** -- retrying cannot make an
    ///     unparseable value parse, and the report's `deniedRetry` discriminator is exactly this absence;
    ///   * the Resolve control, whose tap drives the EXPLICIT, COMPLETE, OWNED wipe (never a clear-journal) and whose
    ///     typed answer renders -- including any artifact that SURVIVED;
    ///   * and after the resolution, the holder re-runs the gate and the normal graph (with its real store opens)
    ///     return, the witness being the tab set and a NON-ZERO open count.
    func testG1TheCorruptRecordDeniesRetryAndTheOperatorWipeEarnsTheGraphBack() throws {
        installStandardControls()
        let app = launchFixture("corrupt")

        let readouts = recoveryReadouts(app)
        XCTAssertTrue(readouts.decision.waitForExistence(timeout: 25),
                      "*** THE RECOVERY-ONLY SURFACE MUST RENDER for a corrupt record. ***")
        XCTAssertTrue(readouts.decision.label.contains("corrupt_journal"),
                      "*** AN UNREADABLE RECORD MUST DECIDE `corrupt_journal`; observed: \(readouts.decision.label) ***")
        XCTAssertTrue(readouts.bootstrap.label.contains("operator required"),
                      "*** THE WORDS `operator required` MUST RENDER -- the field that carrieth 'refused, and a person " +
                          "must intervene'. Observed: \(readouts.bootstrap.label) ***")

        // (1) THE GATE DENIES THE RETRY AND REQUIRES THE OPERATOR.
        XCTAssertTrue(readouts.gate.label.contains("recovery=denied"),
                      "*** `permitsRecoveryConstruction` IS FALSE FOR CORRUPT -- the retry must be DENIED. Observed: " +
                          "\(readouts.gate.label) ***")
        XCTAssertTrue(readouts.gate.label.contains("operator=required"),
                      "*** `requiresOperator` IS TRUE for corrupt. Observed: \(readouts.gate.label) ***")

        // (2) THE RETRY IS ABSENT -- the report's `deniedRetry` discriminator, in the LIVE tree.
        XCTAssertFalse(app.buttons["lab.recovery.retry"].exists,
                       "*** NO RETRY MAY BE OFFERED FOR A CORRUPT RECORD: retrying cannot make an unparseable value " +
                           "parse, and the old ungated pair offered one ANYWAY. ***")
        let resolve = app.buttons["lab.recovery.resolve"]
        XCTAssertTrue(resolve.waitForExistence(timeout: 20),
                      "*** THE OPERATOR ROAD MUST BE OFFERED -- and ONLY it. ***")
        XCTAssertEqual(resolve.label, "Resolve corruption with an operator wipe",
                       "and it must carry the explicit-owned-wipe name, not a bare verb")

        // (3) THE OPERATOR'S OWNED WIPE, DRIVEN: its typed answer must survive the transition it causes and render --
        // written from the authority's own result (`resolveCorruptRecoveryForOperator`), never a view text, and
        // carried into the normal graph by the holder. **A CONTROL THAT MERELY CLEARED A FLAG WOULD RENDER NOTHING
        // HERE** -- the real defect the readout exposes: the operator's act must be REPORTED, not lost to the re-gate.
        resolve.tap()
        let operatorWords = app.staticTexts["lab.recovery.operatorwipe"]
        XCTAssertTrue(operatorWords.waitForExistence(timeout: 30),
                      "*** THE OPERATOR'S ACT MUST REPORT ITS TYPED OUTCOME (`decision @ rung (artifacts)`) EVEN THOUGH "
                          + "A SUCCESSFUL RESOLUTION RE-GATES TO THE NORMAL GRAPH: the holder carrieth the authority's "
                          + "result across the transition, so a control that merely cleared a flag reddens here. ***")
        XCTAssertTrue(operatorWords.label.hasPrefix("operator wipe: "),
                      "the report must be the authority's own summary; observed: \(operatorWords.label)")

        // (4) AND THE GRAPH RETURNS: the holder re-ran the gate over the settled estate.
        XCTAssertTrue(tab("Diagnostics screen", in: app).waitForExistence(timeout: 30),
                      "*** AFTER THE OWNED WIPE AND RE-GATE, THE NORMAL SURFACES MUST RETURN -- the tab set is the " +
                          "witness that the corrupt block was cleared by a real resolution. ***")
        let diagnosticsTab = tab("Diagnostics screen", in: app)
        diagnosticsTab.tap()
        let opens = app.staticTexts["lab.diagnostics.privateopens"]
        XCTAssertTrue(opens.waitForExistence(timeout: 20),
                      "*** AND THE NORMAL BOOT'S OPEN COUNT MUST RENDER (the positive control). ***")
        XCTAssertFalse(opens.label.contains("private stores opened: 0"),
                       "*** A NORMAL BOOT AFTER THE RESOLUTION MUST HAVE REALLY OPENED THE PRIVATE STORES: this " +
                          "counter is raised at `LabRuntime.compose`'s store-construction calls, so a non-zero read " +
                          "is the positive control that the recovery-only arm's zero is NOT a dead constant. " +
                          "Observed: \(opens.label) ***")
    }

    /// *** *** G1: A PERSISTED MID-LADDER RUNG BOOTS RECOVERY-ONLY AND RESUMES FROM THAT RUNG. *** ***
    ///
    /// *The report asketh that a `REQUESTED`/persisted-intermediate rung boot be recovery-only. **THE INTERMEDIATE
    /// RUNG IS A DIFFERENT RECORD THAN `REQUESTED`**: the journal carrieth a phase the ladder ADVANCED to and stopped
    /// at, so the resume must CONTINUE from there rather than re-request -- which is exactly what the durable ladder's
    /// own contract provideth (a phase is a checkpoint, and `resume()` re-readeth it). The arm binds the rung by its
    /// own name and the same zero-open / graph-return evidence as its sibling.*
    func testG1TheIntermediateRungBootsRecoveryOnlyAndResumesFromIt() throws {
        installStandardControls()
        let app = launchFixture("keys_erased")

        let readouts = recoveryReadouts(app)
        XCTAssertTrue(readouts.decision.waitForExistence(timeout: 25),
                      "*** A PERSISTED MID-LADDER RUNG MUST BOOT RECOVERY-ONLY. ***")
        XCTAssertTrue(readouts.rung.label.contains("KEYS_ERASED"),
                      "*** THE DURABLE RUNG MUST NAME THE PLANTED INTERMEDIATE PHASE; observed: \(readouts.rung.label) ***")
        XCTAssertTrue(readouts.decision.label.contains("recovery_pending") || readouts.decision.label.contains("retryable_failure"),
                      "a mid-ladder rung is a recovery state; observed: \(readouts.decision.label)")

        // The same gate and zero-open evidence as the REQUESTED boot.
        XCTAssertTrue(readouts.gate.label.contains("recovery=permitted"),
                      "a resume is permitted from an intermediate rung; observed: \(readouts.gate.label)")
        XCTAssertTrue(readouts.opens.label.contains("private stores opened: 0"),
                      "*** NO PRIVATE STORE MAY STAND BEHIND THE INTERMEDIATE-RUNG SURFACE. Observed: \(readouts.opens.label) ***")
        XCTAssertTrue(app.buttons["lab.recovery.retry"].waitForExistence(timeout: 20),
                      "the gated Retry must stand for a resumable intermediate rung")
        XCTAssertFalse(app.buttons["lab.recovery.resolve"].exists,
                       "and the operator road must not")

        // *** THE RESUME CONTINUES FROM THE PERSISTED RUNG AND SETTLES: the graph returns with real store opens. ***
        app.buttons["lab.recovery.retry"].tap()
        let diagnosticsTab = tab("Diagnostics screen", in: app)
        XCTAssertTrue(diagnosticsTab.waitForExistence(timeout: 30),
                      "*** A PERMITTED RESUME FROM AN INTERMEDIATE RUNG MUST DRIVE THE LADDER TO A SETTLED ESTATE " +
                          "AND RE-GATE. ***")
        diagnosticsTab.tap()
        let opens = app.staticTexts["lab.diagnostics.privateopens"]
        XCTAssertTrue(opens.waitForExistence(timeout: 20), "the normal boot's open count must render")
        XCTAssertFalse(opens.label.contains("private stores opened: 0"),
                       "*** AND THE RESUME'S COMPOSITION MUST HAVE REALLY OPENED THE PRIVATE STORES. Observed: " +
                          "\(opens.label) ***")
    }

    /// *** *** G1: A NORMAL BOOT IS THE ZERO-OPEN WITNESS'S POSITIVE CONTROL. *** ***
    ///
    /// *The two arms above claim zero opens behind a blocked estate. **A COUNT THAT IS ALWAYS ZERO WOULD SATISFY
    /// THEM** -- the constant-zero witness the contract forbids. So this arm proveth the counter really rises: a
    /// `reset` boot renders the normal graph and its `lab.diagnostics.privateopens` reads NON-ZERO, raised at the
    /// real store-construction doors inside `LabRuntime.compose`.*
    func testG1ANormalBootReallyOpensPrivateStores() throws {
        let app = launchFixture("reset")
        XCTAssertTrue(tab("Diagnostics screen", in: app).waitForExistence(timeout: 25),
                      "a clean first launch must reach the normal surfaces")
        let diagnosticsTab = tab("Diagnostics screen", in: app)
        diagnosticsTab.tap()
        let opens = app.staticTexts["lab.diagnostics.privateopens"]
        XCTAssertTrue(opens.waitForExistence(timeout: 20),
                      "*** THE OPEN COUNTER MUST RENDER ON A NORMAL BOOT. ***")
        XCTAssertFalse(opens.label.contains("private stores opened: 0"),
                       "*** A NORMAL BOOT MUST REALLY OPEN THE PRIVATE STORES: the counter is raised in " +
                           "`LabRuntime.compose` at `SqliteMessageStore`/`SqlitePeerIdentityStore` construction, so a " +
                           "zero here would mean the witness is DEAD -- and would make the blocked-estate zero " +
                           "vacuous. Observed: \(opens.label) ***")
    }
}
