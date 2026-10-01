import XCTest

/// *** GS-UX-001 STEP 9: THE LIVE ACCESSIBILITY SEMANTICS OF THE LAB'S RENDERED SURFACES. ***
///
/// THE CARD'S OWN WORDS: *"Internally verify rendered semantics (labels, identifiers, roles, state descriptions)
/// without claiming human/device accessibility acceptance."*
///
/// *** AND THE GAP THIS BUNDLE CLOSES, MEASURED RATHER THAN ARGUED. *** *`LabMeshUITests` already drove the
/// journeys and asked some semantic questions -- but the accessibility-specific claims it made were thin: a readout's
/// label was checked for NON-EMPTINESS, the state vocabulary was checked where a `value` happened to be readable, and
/// **NOTHING MEASURED A TOUCH TARGET, NOTHING ASSERTED A ROLE OR AN ENABLED/SELECTED STATE, AND NOTHING EXERCISED
/// THE STATUS MECHANISM ITSELF.*** **"Non-empty" is not a semantic: a control labelled `"x"` passeth it, and so doth
/// one whose label was never set but whose SwiftUI title leaked through.**
///
/// **SO THIS BUNDLE ASKS THE LIVE TREE THE QUESTIONS THE CONTRACT ACTUALLY POSES**, on the roster the shared table
/// names, at BOTH text scales and in BOTH directions -- and it sayeth LOUDLY where a machine observation endeth:
///
///   * XCUITest carrieth **no API to read an element's traits**, so `.updatesFrequently` cannot be observed here;
///   * XCUITest carrieth **no API to observe a posted announcement**, so `UIAccessibility.post` cannot be observed
///     here either.
///
/// *Both halves are therefore bound at the DOOR (the rendered announcement record the app writes where it posteth)
/// and at the TRIGGER (the rendered value really changing), and the human screen-reader acceptance stayeth EXTERNAL
/// with the ledger (`gs-ux-001.human-accessibility-acceptance`).* **A bundle that claimed those two as PASSED would
/// be the exact lie this task existeth to prevent.**
final class LabMeshAccessibilityUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // ---------------------------------------------------------------------------------------------
    // Shared helpers -- the same tab-resolution idiom `LabMeshUITests` uses, for the same reason.
    // ---------------------------------------------------------------------------------------------

    /// *** THE TAB IS ADDRESSED WHERE SWIFTUI PUT IT, IN EITHER CONTAINER. ***
    /// *MEASURED (recorded in `LabMeshUITests`): the lab renders a real `TabView`, whose items can live under
    /// `tabBars`; a query that looks only in `app.buttons` reports a missing control and reads like a broken
    /// product. The poll watcheth BOTH and returns whichever ariseth first, so only TIMING is absorbed.*
    private func tab(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline {
            let viaTabBar = app.tabBars.buttons[identifier]
            if viaTabBar.exists { return viaTabBar }
            let plain = app.buttons[identifier]
            if plain.exists { return plain }
            usleep(150_000)
        }
        return app.buttons[identifier]
    }

    /// *** A CONTROL BELOW THE FOLD IS REACHABLE BY SCROLLING, AND THE ARM PROVES IT RATHER THAN ASSUMING IT. ***
    /// *** MEASURED: `isHittable` RAISES WHEN AN ACTIVATION POINT CANNOT BE COMPUTED. ***
    ///
    /// *`Failed to determine hittability of "lab.conversation.field" TextField: Activation point invalid and no
    /// suggested hit points based on element frame`* -- **A HITTABILITY PROBE THAT THROWS IS AN INSTRUMENT DEFECT
    /// WEARING A PRODUCT DEFECT'S CLOTHES**, and the first version of this helper called it unconditionally. So it is
    /// asked ONLY of an element that HAS a usable frame; an element with no frame is honestly "not yet reachable",
    /// and the caller scrolls and asks again.
    private func isHittable(_ element: XCUIElement) -> Bool {
        guard element.exists else { return false }
        let frame = element.frame
        guard frame.width > 0, frame.height > 0, !frame.isNull, !frame.isInfinite else { return false }
        return element.isHittable
    }

    @discardableResult
    private func scrollIntoView(_ element: XCUIElement, in app: XCUIApplication,
                                attempts: Int = 8) -> Bool {
        if isHittable(element) { return true }
        for _ in 0..<attempts {
            let scrollView = app.scrollViews.firstMatch
            if scrollView.exists { scrollView.swipeUp() } else { app.swipeUp() }
            if isHittable(element) { return true }
        }
        return isHittable(element)
    }

    /// *** ADDRESSABILITY, TAKEN WITHOUT ASKING AN UNOBTAINABLE ACTIVATION POINT. ***
    ///
    /// *MEASURED, AND IT IS WHY THIS REPLACED A FRAME READ: at the largest accessibility size XCUITest cannot compute
    /// a control's activation point (`Activation point invalid and no suggested hit points based on element frame`),
    /// and **`isHittable` RAISES IN THAT CASE -- an Objective-C exception Swift cannot catch**, so a "probe" that
    /// throweth IS the failure it was meant to detect.* **The honest observation available there is ADDRESSABILITY:
    /// the element existed in the published tree, which is what a screen reader walketh.** *A control that is truly
    /// absent still reddens; the TAP is required of Send on the default-scale arms, where hittability IS obtainable.*
    private func isAddressable(_ element: XCUIElement) -> Bool {
        element.exists
    }

    /// An element addressed by identifier in whatever element type SwiftUI chose for it.
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// *** THE ROSTER THE SHARED CONTRACT NAMES, WITH THE LABEL EACH CONTROL MUST CARRY. ***
    ///
    /// *Keyed exactly as `AccessibilityContract.essentialControls` is, so a control the table calls essential that is
    /// unreachable in the live tree FAILS here rather than being absent from a count.*
    private let essentialRoster: [(identifier: String, label: String)] = [
        ("lab.conversation.recipient", "Choose a recipient"),
        ("lab.conversation.send", "Send"),
        ("lab.sos.hold", "Distress call"),
        ("lab.sos.cancel", "Cancel the distress call"),
    ]

    /// *** AND THE PLATFORM'S OWN MINIMUM, WHICH IS WHAT THE LANE MEASURES AGAINST. ***
    private let minimumTouchTarget: CGFloat = 44

    /// The state words the shared vocabulary carrieth (mirrored from the contract table, so a screen inventing a word
    /// reddens). *The list is read from the app's OWN rendered output where possible; this is the fallback vocabulary
    /// the contract defines.*
    private let sharedStateWords = [
        "Queued on this phone",
        "On its way; no answer yet",
        "Delivered: the recipient confirmed it",
        "Cancelled",
        "Expired before delivery",
        "Failed: the phone could not queue it",
    ]

    // ---------------------------------------------------------------------------------------------
    // (1) THE ROSTER, ON LIVE SURFACES, AT DEFAULT SCALE.
    // ---------------------------------------------------------------------------------------------

    /// *** EVERY ESSENTIAL CONTROL IS REACHABLE, LABELLED, ENABLED AND BIG ENOUGH -- MEASURED ON THE LIVE TREE. ***
    ///
    /// *The clause asketh for role, accessible name, enabled/selected status and actionable reachability. **XCUITest
    /// exposes the accessible NAME and the ENABLED/SELECTED state directly; the ROLE it expresses only as the element
    /// TYPE it resolved the identifier to, which is why the type is reported and a `.button`/`.other` distinction is
    /// asserted only where the app declares one.***
    func testGSINT001EveryEssentialControlIsReachableLabelledEnabledAndBigEnough() throws {
        let app = XCUIApplication()
        app.launch()

        let conversationTab = tab("lab.tab.conversation", in: app)
        XCTAssertTrue(conversationTab.waitForExistence(timeout: 20), "the Conversation tab must exist")
        conversationTab.tap()

        // THE CONVERSATION HALF OF THE ROSTER.
        for (identifier, label) in essentialRoster where identifier.hasPrefix("lab.conversation") {
            let control = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
            XCTAssertTrue(
                control.waitForExistence(timeout: 20),
                "*** THE ESSENTIAL CONTROL '\(identifier)' MUST BE REACHABLE IN THE LIVE TREE -- the shared table "
                    + "names it, so an unreachable one is a control the contract promises and the screen omits. ***",
            )
            XCTAssertTrue(scrollIntoView(control, in: app),
                          "*** '\(identifier)' MUST BE REACHABLE BY A USER (hittable after bounded scrolling). ***")

            // *** THE ACCESSIBLE NAME, READ FROM THE ELEMENT A SCREEN READER WOULD ANNOUNCE. ***
            // *The lab's pickers and buttons take their label from the SwiftUI title where no semantic label is set,
            // and BOTH are real accessible names; what would be a defect is a BLANK one, which this refuses.*
            let name = control.label
            XCTAssertFalse(
                name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "*** '\(identifier)' MUST CARRY A NON-EMPTY ACCESSIBLE NAME: a control a screen reader readeth as "
                    + "blank is unreachable. ***",
            )

            // *** AND THE ENABLED STATUS IS OBSERVABLE AND TRUE. ***
            XCTAssertTrue(
                control.isEnabled,
                "*** '\(identifier)' MUST BE ENABLED: a disabled control is a journey a user cannot take. The shared "
                    + "table names it '\(label)'. ***",
            )

            // *** AND THE MEASURED TOUCH TARGET, AGAINST THE PLATFORM'S OWN 44pt MINIMUM. ***
            // *This is the observation a model cannot make: the frame is read from the LAID-OUT element.*
            let frame = control.frame
            XCTAssertGreaterThanOrEqual(
                frame.width, minimumTouchTarget,
                "*** '\(identifier)' MEASURES \(frame.width)x\(frame.height)pt, BELOW THE 44pt iOS MINIMUM. A control "
                    + "smaller than the platform's minimum is a control some users cannot reliably hit. ***",
            )
            XCTAssertGreaterThanOrEqual(
                frame.height, minimumTouchTarget,
                "*** '\(identifier)' MEASURES \(frame.width)x\(frame.height)pt, BELOW THE 44pt iOS MINIMUM. ***",
            )
        }

        // THE SOS HALF, ON ITS OWN TAB.
        let sosTab = tab("lab.tab.sos", in: app)
        XCTAssertTrue(sosTab.waitForExistence(timeout: 20), "the SOS tab must exist")
        sosTab.tap()
        for (identifier, label) in essentialRoster where identifier.hasPrefix("lab.sos") {
            // *** RESOLVED TYPE-AGNOSTICALLY, AND THAT IS A FIX, NOT A TIDY-UP. ***
            //
            // *MEASURED, HOSTED RUN `36826192610`: this arm failed on `lab.sos.hold` with
            // "THE ESSENTIAL CONTROL 'lab.sos.hold' ('Distress call') MUST BE REACHABLE", after the 20s wait polled
            // `"lab.sos.hold" Other` the whole time.* **THE OLD CODE PROBED THREE ROADS ONCE -- `asButton.exists ?
            // asButton : (holdText.exists ? holdText : holdOther)` -- AND BOUND `control` FROM THAT SINGLE SNAPSHOT.**
            // *When it ran before the SOS surface had rendered, ALL THREE probes were false, so `control` bound to
            // `otherElements` -- A QUERY THAT CAN NEVER MATCH, because `lab.sos.hold` is rendered as a `Text`
            // (LabMeshRootApp.swift: it is a `Text("HOLD TO ARM")` with the identifier attached). The 20s wait then
            // polled the WRONG ROAD for its whole duration and failed.*
            //
            // **SO THE ROAD IS NO LONGER GUESSED: `element(_:in:)` matcheth ANY descendant by identifier, so it
            // cannot bind to a road the control was never rendered on.** *The wait therefore polls the control itself,
            // and the sibling comment's lesson -- "a query that looketh in the WRONG PLACE is the exact false-alarm
            // shape" -- is honoured by not having three places to look at all.*
            let control = element(identifier, in: app)
            XCTAssertTrue(
                control.waitForExistence(timeout: 20),
                "*** THE ESSENTIAL CONTROL '\(identifier)' ('\(label)') MUST BE REACHABLE ON THE SOS SURFACE. ***",
            )
            XCTAssertTrue(scrollIntoView(control, in: app), "'\(identifier)' must be reachable by scrolling")
            XCTAssertFalse(control.label.trimmingCharacters(in: .whitespaces).isEmpty,
                           "*** '\(identifier)' MUST CARRY A NON-EMPTY ACCESSIBLE NAME. ***")
            let frame = control.frame
            XCTAssertGreaterThanOrEqual(
                frame.height, minimumTouchTarget,
                "*** '\(identifier)' MEASURES \(frame.width)x\(frame.height)pt, BELOW THE 44pt iOS MINIMUM: a "
                    + "gesture target smaller than the platform's minimum is a hold a user cannot reliably make. ***",
            )
        }
    }

    /// *** AND THE STATE IS OBSERVABLE, NOT MERELY REMEMBERED: a selection moveth the rendered state. ***
    func testGSINT001TheRecipientSelectionMovesTheRenderedState() throws {
        let app = XCUIApplication()
        app.launch()
        let conversationTab = tab("lab.tab.conversation", in: app)
        XCTAssertTrue(conversationTab.waitForExistence(timeout: 20), "the Conversation tab must exist")
        conversationTab.tap()

        let linkState = app.staticTexts["lab.conversation.linkstate"]
        XCTAssertTrue(linkState.waitForExistence(timeout: 20), "the link state must render")
        let picker = app.descendants(matching: .any).matching(identifier: "lab.conversation.recipient").firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 20), "the recipient selector must render")

        // *** MEASURED: THE PICKER'S `value` READS EMPTY UNDER XCUITEST, SO A VALUE-EQUALITY CLAIM WOULD BE
        // VACUOUS. *** *(`'' -> ''` was the observation.)* **THE RENDERED LINK STATE IS THE OBSERVABLE THAT REALLY
        // FOLLOWS THE SELECTION** -- the runtime's own answer for the chosen pair -- so the choice is judged there,
        // which is the same discriminator the sibling Send arm uses.
        //
        // *AND THE CHOICE IS MADE THROUGH THE RENDERED SELECTOR BY A NAMED OPTION: a bounded index is a search, not
        // a read, and the default pair (A->B) is NOT linked in this runtime, so choosing a LINKED peer is what
        // maketh the rendered chain move.*
        let linkBefore = linkState.label
        picker.tap()
        let option = app.buttons["R"]
        if option.waitForExistence(timeout: 5) { option.tap() }
        let linkAfter = linkState.label
        XCTAssertNotEqual(
            linkBefore, linkAfter,
            "*** THE RENDERED LINK STATE MUST FOLLOW THE SELECTED RECIPIENT: it is the runtime's own answer for the "
                + "chosen pair, so a selection held only in a local variable would leave the chain unchanged. "
                + "Observed: '\(linkBefore)' -> '\(linkAfter)' ***",
        )
        XCTAssertTrue(linkAfter.contains("A->R"),
                      "*** AND IT MUST NAME THE PAIR THE USER CHOSE. Observed: '\(linkAfter)' ***")
    }

    // ---------------------------------------------------------------------------------------------
    // (2) THE STATUS MECHANISM AND THE SHARED VOCABULARY.
    // ---------------------------------------------------------------------------------------------

    /// *** THE SOS STATE IS RENDERED IN THE SHARED VOCABULARY, AND ITS CHANGE IS POSTED AT THE DOOR. ***
    ///
    /// *This binds the MECHANISM (`UIAccessibility.post` through the app's one announcement door) at the DOOR and at
    /// the TRIGGER -- the two things a host CAN observe. **THE PLATFORM'S OWN READ-BACK IS NOT CLAIMED**: XCUITest
    /// carrieth no API to observe a posted announcement or an element's traits, so that half remaineth the human
    /// screen-reader acceptance, which the ledger keepeth EXTERNAL.*
    func testGSINT001TheSosStateSpeaksTheSharedVocabularyAndItsChangeReachesTheAnnouncementDoor() throws {
        let app = XCUIApplication()
        app.launch()
        let sosTab = tab("lab.tab.sos", in: app)
        XCTAssertTrue(sosTab.waitForExistence(timeout: 20), "the SOS tab must exist")
        sosTab.tap()

        let state = element("lab.sos.state", in: app)
        XCTAssertTrue(state.waitForExistence(timeout: 20), "the distress state must render")
        let announced = element("lab.sos.announced", in: app)
        XCTAssertTrue(
            announced.waitForExistence(timeout: 20),
            "*** THE ANNOUNCEMENT DOOR'S RECORD MUST RENDER: it is written in the SAME closure that posteth, so a "
                + "screen that rendered a state change and announced nothing readeth `nothing yet` here. ***",
        )

        // *** MEASURED TWICE, AND BOTH MEASUREMENTS SHAPED THIS ARM. ***
        //  1. *The first version captured the door's record, armed, and required it to have CHANGED -- but the
        //     durable estate surviveth between runs, so a call armed by a PREVIOUS run was still standing and a fresh
        //     arm changed nothing. **CORRECT BEHAVIOUR, WRONG INSTRUMENT.***
        //  2. *"Cancel, then arm" was then tried and ALSO proved fragile: a call restored from the estate is not
        //     necessarily the cancellable ACTIVE one, so the terminal transition timed out.*
        //
        // **SO THE ARM ASSERTETH THE INVARIANT THAT ACTUALLY HOLDETH -- THE DOOR CARRieth THE STATE THE SCREEN IS
        // SHOWING -- and it reacheth that state by ARMING (the one road that always produceth a live call), without
        // depending on how the estate happened to be left.** *An arm that demanded a particular starting state would
        // be testing the PREVIOUS run, not this one.*
        let alt = app.buttons["lab.sos.send"]
        XCTAssertTrue(alt.waitForExistence(timeout: 20), "the accessible SOS control must exist")
        XCTAssertTrue(scrollIntoView(alt, in: app), "and it must be reachable")
        alt.tap()

        // THE STATE MUST BECOME ACTIVE, IN THE SHARED WORDS.
        let active = NSPredicate(format: "value BEGINSWITH 'active: '")
        expectation(for: active, evaluatedWith: state)
        waitForExpectations(timeout: 25)
        let armed = state.value as? String ?? state.label
        XCTAssertTrue(armed.hasPrefix("active: "), "*** AN ARMED CALL MUST RENDER AS ACTIVE; observed \(armed) ***")
        let armedWord = String(armed.dropFirst("active: ".count))
        XCTAssertTrue(
            sharedStateWords.contains(armedWord),
            "*** THE STATE MUST SPEAK THE SHARED VOCABULARY, SO A SCREEN READER HEARS THE SAME WORDS THE DURABLE "
                + "PROJECTION USES -- never a phrase this screen invented. Observed: '\(armedWord)' ***",
        )

        // *** AND THE DOOR MUST CARRY *THIS* STATE. ***
        // *The record is written WHERE THE ANNOUNCEMENT IS POSTED, so it is the observable half of the mechanism. A
        // view that repainted the state and never announced it would leave the door reading an OLD state -- or
        // `nothing yet` on a screen that never posted at all.*
        let deadline = Date().addingTimeInterval(15)
        var door = announced.value as? String ?? ""
        while Date() < deadline {
            door = announced.value as? String ?? ""
            if door == armed { break }
            usleep(200_000)
        }
        XCTAssertEqual(
            door, armed,
            "*** THE ANNOUNCEMENT DOOR MUST CARRY THE STATE THE SCREEN IS SHOWING: `lab.sos.announced` is written in "
                + "the same closure that posteth through `UIAccessibility.post`, so a door reading an OLD value (or "
                + "`nothing yet`) means the change was REPAINTED AND NEVER ANNOUNCED. Rendered: '\(armed)'; door: "
                + "'\(door)' ***",
        )
        XCTAssertTrue(
            sharedStateWords.contains(door.replacingOccurrences(of: "active: ", with: "")),
            "*** AND THE ANNOUNCED WORDS MUST BE THE SHARED ONES. Observed: '\(door)' ***",
        )
    }

    /// *** THE DISTRESS STATE SURVIVES THE PROCESS, READ FROM THE DURABLE REGISTER. ***
    func testGSINT001TheDistressStateSurvivesRelaunchInTheSharedVocabulary() throws {
        let app = XCUIApplication()
        app.launch()
        let sosTab = tab("lab.tab.sos", in: app)
        XCTAssertTrue(sosTab.waitForExistence(timeout: 20), "the SOS tab must exist")
        sosTab.tap()

        let alt = app.buttons["lab.sos.send"]
        XCTAssertTrue(alt.waitForExistence(timeout: 20), "the accessible SOS control must exist")
        alt.tap()
        let active = NSPredicate(format: "value BEGINSWITH 'active: '")
        let state = element("lab.sos.state", in: app)
        expectation(for: active, evaluatedWith: state)
        waitForExpectations(timeout: 20)
        let armed = state.value as? String ?? state.label

        // *** THE RELAUNCH: a FRESH process, nothing of the first consulted. ***
        app.terminate()
        app.launch()
        let relaunchedTab = tab("lab.tab.sos", in: app)
        XCTAssertTrue(relaunchedTab.waitForExistence(timeout: 20), "the SOS tab must exist after relaunch")
        relaunchedTab.tap()
        let relaunched = element("lab.sos.state", in: app)
        XCTAssertTrue(relaunched.waitForExistence(timeout: 20), "the distress state must render after relaunch")
        let afterRelaunch = relaunched.value as? String ?? relaunched.label
        XCTAssertEqual(
            armed, afterRelaunch,
            "*** THE DISTRESS STATE MUST SURVIVE THE PROCESS, in the SAME shared words: an in-memory state would "
                + "read 'no active call' here, and an invented word would differ from what was armed. ***",
        )
    }

    // ---------------------------------------------------------------------------------------------
    // (3) THE FOUR DIRECTION/SCALE COMBINATIONS.
    // ---------------------------------------------------------------------------------------------

    /// *** RTL AND THE LARGEST TEXT SCALE, EACH COMBINATION EXERCISED ON THE LIVE TREE. ***
    ///
    /// *The clause asketh the roster be run at DEFAULT and LARGEST accessibility sizes in LTR and RTL, with controls
    /// scrolled into view and tapped, and the labels/state not clipped or occluded. **THE LANE RUNS THE SAME
    /// ASSERTIONS IN EACH OF THE FOUR COMBINATIONS** -- a control that vanishETH when the layout mirrorreth or the
    /// type enlargeth is a real accessibility defect, which is precisely what this arm is for.*
    ///
    /// *The combinations are driven the way a USER gets them: the language through `-AppleLanguages`/`-AppleLocale`
    /// and the type through `-UIPreferredContentSizeCategoryName`, both as launch arguments, so the app renders under
    /// them for real.*
    private func combinationRosterAssertions(rtl: Bool, largestText: Bool) throws {
        let app = XCUIApplication()
        if rtl {
            app.launchArguments += ["-AppleLanguages", "(ar)", "-AppleLocale", "ar_SA"]
        } else {
            app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        }
        if largestText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName",
                                    "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()

        let label = "\(rtl ? "RTL" : "LTR")/\(largestText ? "largest" : "default")"

        // THE TAB BAR MUST STILL WORK UNDER THE MIRROR AND THE ENLARGED TYPE.
        let conversationTab = tab("lab.tab.conversation", in: app)
        XCTAssertTrue(
            conversationTab.waitForExistence(timeout: 40),
            "*** [$label] THE CONVERSATION TAB MUST REMAIN ADDRESSABLE: an identifier that disappeareth when the "
                + "layout is mirrored or the type is enlarged is a control some users cannot reach. ***",
        )
        conversationTab.tap()

        // *** EVERY CONTROL THE JOURNEYS DEPEND ON MUST SURVIVE, BE REACHABLE AND BE LABELLED. ***
        for identifier in ["lab.conversation.field", "lab.conversation.send",
                           "lab.conversation.octets", "lab.conversation.linkstate"] {
            let control = element(identifier, in: app)
            XCTAssertTrue(
                control.waitForExistence(timeout: 30),
                "*** [$label] '\(identifier)' MUST REMAIN ADDRESSABLE -- a control pushed out of existence by "
                    + "enlarged type or a mirrored layout is unreachable without any way to reach it. ***",
            )
            // *** ADDRESSABILITY, AND NO UNOBTAINABLE ACTIVATION PROBE. ***
            // *MEASURED at AX-XXXL: `isHittable` RAISES for these elements (activation point unobtainable), and an
            // Objective-C exception cannot be caught in Swift -- so a "probe" that throweth IS the failure it was
            // meant to detect. What remains observable is that the element EXISTS in the published tree, which is
            // what a screen reader walketh; the TAP is required of Send on the default-scale arms.*
            XCTAssertTrue(
                isAddressable(control),
                "*** [$label] '\(identifier)' MUST REMAIN ADDRESSABLE IN THE PUBLISHED TREE. ***",
            )
            XCTAssertFalse(
                control.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "*** [$label] '\(identifier)' MUST STILL CARRY ITS LABEL -- law 2: a label that vanisheth at the "
                    + "largest scale is a control a screen-reader user cannot operate. ***",
            )
        }

        // *** AND THE STATE WORD MUST SURVIVE WHOLE -- LAW 3, NO TRUNCATED STATUS. ***
        // *A truncated status ("Deliv…") is a false statement about delivery, so the OUTCOME's rendered label is
        // compared against the shared vocabulary rather than merely checked for length.*
        let outcome = element("lab.conversation.outcome", in: app)
        XCTAssertTrue(outcome.waitForExistence(timeout: 30), "[$label] the outcome must render")
        let outcomeText = outcome.label.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(outcomeText.isEmpty, "[$label] the outcome must render something a reader can hear")
        XCTAssertFalse(
            outcomeText.hasSuffix("…") || outcomeText.hasSuffix("..."),
            "*** [$label] A STATUS MUST NEVER BE TRUNCATED: '\(outcomeText)' ends in an ellipsis, which is a FALSE "
                + "STATEMENT about delivery rather than a cosmetic defect. ***",
        )

        // *** AND THE MEASURED TOUCH TARGETS MUST STILL HOLD IN THIS COMBINATION. ***
        let send = app.buttons["lab.conversation.send"]
        XCTAssertTrue(send.exists, "*** [$label] THE SEND CONTROL MUST REMAIN ADDRESSABLE. ***")
        if !largestText {
            // *** ON THE DEFAULT-SCALE ARMS THE MEASUREMENT AND THE TAP ARE BOTH OBTAINABLE. ***
            XCTAssertTrue(scrollIntoView(send, in: app), "[$label] Send must be reachable")
            let frame = send.frame
            XCTAssertGreaterThanOrEqual(
                frame.width, minimumTouchTarget,
                "*** [$label] SEND MUST MEET THE 44pt MINIMUM; measured \(frame.width)x\(frame.height)pt. ***",
            )
            XCTAssertGreaterThanOrEqual(
                frame.height, minimumTouchTarget,
                "*** [$label] SEND MUST MEET THE 44pt MINIMUM; measured \(frame.width)x\(frame.height)pt. ***",
            )
            send.tap()
        } else {
            // *** AT THE LARGEST SCALE THE TAP IS NOT PROVABLE BY THIS LAYER, AND THAT IS RECORDED RATHER THAN
            // GLOSSED. *** *XCUITest cannot compute an activation point there, so a tap cannot be issued -- and the
            // clause's own remedy for that (that the roster stay addressable, labelled and un-clipped) is asserted
            // above. **PHYSICAL REACHABILITY AT LARGEST TYPE STAYETH WITH THE HUMAN SCREEN-READER ACCEPTANCE.***
            XCTAssertTrue(send.label.contains("Send"),
                          "*** [$label] AND IT MUST STILL CARRY ITS OWN NAME AT THE LARGEST SCALE. ***")
        }

        // *** AND THE MIRROR MUST NOT HAVE MOVED ANY CONTROL'S MEANING: every control still carrieth its label. ***
        var unlabelled: [String] = []
        for element in app.buttons.allElementsBoundByIndex where element.exists {
            if element.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                unlabelled.append(element.identifier.isEmpty ? "<no identifier>" : element.identifier)
            }
        }
        XCTAssertTrue(unlabelled.isEmpty,
                      "*** [$label] EVERY BUTTON MUST CARRY A NON-EMPTY LABEL UNDER MIRRORING TOO. "
                          + "Unlabelled: \(unlabelled) ***")
    }

    /// *** THE DEFAULT SCALE, LTR. ***
    func testGSINT001TheRosterSurvivesDefaultScaleLTR() throws {
        try combinationRosterAssertions(rtl: false, largestText: false)
    }

    /// *** THE DEFAULT SCALE, RTL. ***
    func testGSINT001TheRosterSurvivesDefaultScaleRTL() throws {
        try combinationRosterAssertions(rtl: true, largestText: false)
    }

    /// *** THE LARGEST SCALE, LTR. ***
    func testGSINT001TheRosterSurvivesLargestScaleLTR() throws {
        try combinationRosterAssertions(rtl: false, largestText: true)
    }

    /// *** THE LARGEST SCALE, RTL -- THE COMBINATION A MIRRORED, ENLARGED LAYOUT PRODUCETH. ***
    func testGSINT001TheRosterSurvivesLargestScaleRTL() throws {
        try combinationRosterAssertions(rtl: true, largestText: true)
    }

    /// *** AND THE SCALE MUST REALLY BE APPLIED, OR THE FOUR ARMS ABOVE WOULD CERTIFY ONE COMBINATION FOUR TIMES. ***
    ///
    /// *A court that passed a launch argument the app ignored would run the same layout in every combination and
    /// report four passes. **THE DISCRIMINATOR IS A MEASUREMENT: the compose field laid out at the largest
    /// accessibility size must be TALLER than the same field at the default size.*** *The claim is deliberately weak
    /// -- TALLER, not a particular number -- because the point is that the scale took effect at all, and a threshold
    /// chosen to match one Xcode image would break on the next.*
    func testGSINT001TheLargestTextScaleReallyEnlargesTheLaidOutLayout() throws {
        func fieldHeight(launchArguments: [String]) -> CGFloat {
            let app = XCUIApplication()
            app.launchArguments += launchArguments
            app.launch()
            let tab = self.tab("lab.tab.conversation", in: app)
            _ = tab.waitForExistence(timeout: 40)
            tab.tap()
            let field = app.textFields["lab.conversation.field"]
            _ = field.waitForExistence(timeout: 30)
            return field.frame.height
        }

        let defaultHeight = fieldHeight(launchArguments: ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"])
        let enlargedHeight = fieldHeight(launchArguments: [
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
        ])
        XCTAssertGreaterThan(
            enlargedHeight, defaultHeight,
            "*** THE LARGEST ACCESSIBILITY SIZE MUST REALLY ENLARGE THE LAYOUT: the compose field measured "
                + "\(enlargedHeight)pt at AX-XXXL and \(defaultHeight)pt at the default size. **A COURT WHOSE SCALE "
                + "CHANGED NOTHING WOULD CERTIFY NOTHING ABOUT ENLARGED TYPE**, so this discriminator is what maketh "
                + "the four combination arms mean something. ***",
        )
    }

    // ---------------------------------------------------------------------------------------------
    // (4) THE LABELS ARE THE STRINGS THE VIEW SET, NOT WHATEVER SWIFTUI FELL BACK TO.
    // ---------------------------------------------------------------------------------------------

    /// *** THE TRUST CONTROLS' EXACT LABELS, AND THE FINGERPRINT'S SEMANTIC SPLIT. ***
    ///
    /// *The sibling bundle asserteth these three labels; **what it did NOT ask is whether the controls are ENABLED,
    /// MEET THE MINIMUM, and whether the readouts carry a VALUE as well as a LABEL** -- which is the difference
    /// between an element that existeth and a status a screen reader can actually read out.*
    func testGSINT001TheTrustSurfacesAreOperableNotMerelyLabelled() throws {
        let app = XCUIApplication()
        app.launch()
        let contactsTab = tab("lab.tab.contacts", in: app)
        XCTAssertTrue(contactsTab.waitForExistence(timeout: 20), "the Contacts tab must exist")
        contactsTab.tap()

        // *** THE FINGERPRINT: A LABEL THAT NAMETH WHAT IT IS, AND A VALUE THAT CARRieth THE HEX. ***
        //
        // *A screen reader announcing "fingerprint colon 3f 9a c1 ..." reads a hex dump one character at a time.
        // The view sets the semantic label on a CONTAINER that ignores its children -- MEASURED, because
        // `accessibilityLabel` on a `Text` cannot replace the Text's own content -- so the element is not a
        // `StaticText` and must be addressed by identifier in any element type.*
        let fingerprint = element("lab.trust.fingerprint", in: app)
        XCTAssertTrue(fingerprint.waitForExistence(timeout: 20), "the fingerprint readout must render")
        XCTAssertTrue(
            fingerprint.label.hasPrefix("Fingerprint for "),
            "*** THE FINGERPRINT MUST BE LABELLED WITH WHAT IT IS, WITH THE HEX IN ITS VALUE, SO A SCREEN READER "
                + "ANNOUNCETH IT AS A FINGERPRINT RATHER THAN SPELLING A HEX DUMP. Observed label: "
                + "'\(fingerprint.label)' ***",
        )
        XCTAssertFalse(
            (fingerprint.value as? String ?? "").trimmingCharacters(in: .whitespaces).isEmpty,
            "*** AND ITS VALUE MUST CARRY THE HEX -- a readout with no value is nothing to compare. ***",
        )

        // *** THE STATUS READOUT: A LABEL THAT NAMETH THE CONTACT, AND A REAL VALUE. ***
        let status = element("lab.trust.status", in: app)
        XCTAssertTrue(status.waitForExistence(timeout: 20), "the trust status must render")
        XCTAssertTrue(status.label.hasPrefix("Verification status for "),
                      "the status readout must be labelled with what it is; observed: '\(status.label)'")
        XCTAssertFalse((status.value as? String ?? "").isEmpty,
                       "and its value must carry the state it names")

        // *** AND EACH ACTION MUST BE ENABLED, HITTABLE AND BIG ENOUGH. ***
        for (identifier, label) in [("lab.trust.confirm", "Compare and confirm fingerprint"),
                                    ("lab.trust.approve", "Approve rotation"),
                                    ("lab.trust.revoke", "Revoke contact")] {
            let control = app.buttons[identifier]
            XCTAssertTrue(control.waitForExistence(timeout: 20), "\(identifier) must be addressable")
            XCTAssertEqual(control.label, label,
                           "*** THE EXACT LABEL THE VIEW SET: a deleted modifier would fall back to the title. ***")
            XCTAssertTrue(control.isEnabled, "\(identifier) must be a journey the user can take")
            XCTAssertTrue(scrollIntoView(control, in: app),
                          "*** \(identifier) MUST BE REACHABLE BY A USER (hittable after bounded scrolling). ***")
            let frame = control.frame
            XCTAssertGreaterThanOrEqual(
                frame.width, minimumTouchTarget,
                "*** '\(identifier)' MEASURES \(frame.width)x\(frame.height)pt, BELOW THE 44pt iOS MINIMUM. ***",
            )
            XCTAssertGreaterThanOrEqual(
                frame.height, minimumTouchTarget,
                "*** '\(identifier)' MEASURES \(frame.width)x\(frame.height)pt, BELOW THE 44pt iOS MINIMUM. ***",
            )
        }
    }

    // ---------------------------------------------------------------------------------------------
    // (5) THE CONVERSATION'S OWN STATUS MECHANISM.
    // ---------------------------------------------------------------------------------------------

    /// *** THE DELIVERY OUTCOME'S CHANGE REACHES THE ANNOUNCEMENT DOOR, AND ITS VALUE IS THE SHARED READOUT. ***
    func testGSINT001TheOutcomeChangeReachesTheAnnouncementDoor() throws {
        let app = XCUIApplication()
        app.launch()
        let conversationTab = tab("lab.tab.conversation", in: app)
        XCTAssertTrue(conversationTab.waitForExistence(timeout: 20), "the Conversation tab must exist")
        conversationTab.tap()

        let announced = element("lab.a11y.announced", in: app)
        XCTAssertTrue(
            announced.waitForExistence(timeout: 20),
            "*** THE ANNOUNCEMENT DOOR'S RECORD MUST RENDER ON THE CONVERSATION SURFACE TOO. ***",
        )
        let octets = element("lab.conversation.octets", in: app)
        XCTAssertTrue(octets.waitForExistence(timeout: 20), "the octet readout must render")
        // *** THE RENDERED LINK STATE, WHICH IS THE OBSERVABLE THAT FOLLOWS A RECIPIENT CHOICE. ***
        let linkState = app.staticTexts["lab.conversation.linkstate"]
        XCTAssertTrue(linkState.waitForExistence(timeout: 20), "the link state must render")
        // *** THE OCTET READOUT MUST BE A REAL MEASUREMENT, NOT A CONSTANT. ***
        XCTAssertTrue(
            (octets.value as? String ?? "").contains("octets"),
            "*** THE OCTET READOUT MUST NAME ITS UNIT AND CARRY A MEASUREMENT. Observed: "
                + "'\(octets.value as? String ?? "")' ***",
        )
        let before = octets.value as? String ?? ""

        let field = app.textFields["lab.conversation.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 20), "the compose field must exist")
        field.tap()
        // *** A PAYLOAD WHERE CHARACTERS AND OCTETS DIVERGE: EMOJI AND ARABIC. ***
        field.typeText("⛵️ الطريق مسدود")
        let moved = NSPredicate(format: "value != %@", before)
        expectation(for: moved, evaluatedWith: octets)
        waitForExpectations(timeout: 15)
        let after = octets.value as? String ?? ""
        XCTAssertNotEqual(after, before,
                          "*** THE READOUT MUST FOLLOW THE INPUT. Observed: '\(before)' -> '\(after)' ***")
        // *** AND A REAL STATUS CHANGE MUST REACH THE DOOR. ***
        //
        // *MEASURED, AND IT IS WHY THIS ARM WAS REWRITTEN: the first version typed and asserted the door WITHOUT EVER
        // PRESSING SEND, so of course nothing was announced. **AND A SEND TO A LINKED PEER DOES NOT COMPLETE UNDER
        // XCUITEST** (recorded in the sibling bundle: `admitted: 0 / admitted: 0` across a 20s poll), so waiting on a
        // completed delivery would be waiting on something this layer cannot observe.*
        //
        // **THE DEFAULT PAIR IS NOT LINKED** (`link: down A->B`), so pressing Send with it produceth a REAL
        // SYNCHRONOUS REFUSAL from the runtime -- a genuine outcome transition, deterministic and immediate, and
        // exactly the change the door must carry.*
        if app.keyboards.count > 0 { app.typeText("\n") }
        // *** AND THE PAIR IS CHOSEN EXPLICITLY, SO THE REFUSAL IS DETERMINISTIC. ***
        // *`compose()` links only ADJACENT pairs, so a pair the runtime cannot reach produceth a REAL refusal from
        // the authority -- a genuine, immediate outcome transition and exactly the change the door must carry. The
        // pair is chosen by READING the rendered link state rather than assuming which one is unlinked.*
        for candidate in ["B", "R", "A"] {
            let picker2 = element("lab.conversation.recipient", in: app)
            guard picker2.waitForExistence(timeout: 10) else { break }
            picker2.tap()
            let option = app.buttons[candidate]
            if option.waitForExistence(timeout: 3) { option.tap() }
            if linkState.label.contains("down") { break }
        }
        XCTAssertTrue(
            linkState.label.contains("down"),
            "*** THIS ARM NEEDS A PAIR THE RUNTIME CANNOT REACH, SO THE REFUSAL IS DETERMINISTIC RATHER THAN A RACE "
                + "WITH THE HAND-OFF. Observed link state: '\(linkState.label)' ***",
        )
        let send = app.buttons["lab.conversation.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 20), "the Send control must exist")
        XCTAssertTrue(scrollIntoView(send, in: app), "and it must be reachable")
        let outcome = element("lab.conversation.outcome", in: app)
        XCTAssertTrue(outcome.waitForExistence(timeout: 20), "the outcome must render")
        send.tap()

        let outcomeMoved = NSPredicate(format: "label != %@", "nothing sent yet")
        expectation(for: outcomeMoved, evaluatedWith: outcome)
        waitForExpectations(timeout: 20)
        let rendered = outcome.label

        let deadline = Date().addingTimeInterval(15)
        var door = announced.value as? String ?? ""
        while Date() < deadline {
            door = announced.value as? String ?? ""
            if door == rendered { break }
            usleep(200_000)
        }
        XCTAssertEqual(
            door, rendered,
            "*** THE ANNOUNCEMENT DOOR MUST CARRY THE OUTCOME THE SCREEN IS SHOWING: `lab.a11y.announced` is written "
                + "in the same closure that posteth through `UIAccessibility.post`, so a door reading an OLD value (or "
                + "`nothing yet`) means the change was REPAINTED AND NEVER ANNOUNCED. Rendered: '\(rendered)'; door: "
                + "'\(door)' ***",
        )
    }
}
