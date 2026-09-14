// T60 readiness court (iOS isle) -- the automated accessibility and restoration
// checks. The twin of the python conductor and the Android court, with the SAME
// laws and the SAME words, and this platform's own numbers (44pt, AX5).
//
// The card's law: "Remove an essential control label or clip status at large text:
// UI/accessibility check fails."
import XCTest
@testable import GodstoneMesh

final class ReadinessT60Tests: XCTestCase {
    private let minimum = A11yPlatform.ios.touchTargetMinDp

    private func words(_ state: String) -> String {
        AccessibilityContract.stateWords.first { $0.0 == state }!.1
    }

    private func token(_ state: String) -> String {
        AccessibilityContract.stateColourToken.first { $0.0 == state }!.1
    }

    /// A screen that passeth every automated check.
    private func healthy() -> [UiNode] {
        [
            UiNode(controlId: "recipient_select", role: .button, label: "Choose a recipient",
                   contentDescription: "Choose a recipient", touchWidthDp: minimum,
                   touchHeightDp: minimum, readingOrder: 0),
            UiNode(controlId: "compose_send", role: .button, label: "Send",
                   contentDescription: "Send the message", touchWidthDp: minimum,
                   touchHeightDp: minimum, readingOrder: 1),
            UiNode(controlId: "sos_arm", role: .button, label: "Distress call",
                   contentDescription: AccessibilityContract.sosIdleHint,
                   touchWidthDp: minimum + 8, touchHeightDp: minimum + 8, readingOrder: 2),
            UiNode(controlId: "sos_cancel", role: .button,
                   label: AccessibilityContract.sosCancelLabel,
                   contentDescription: AccessibilityContract.sosCancelLabel,
                   touchWidthDp: minimum + 8, touchHeightDp: minimum + 8, readingOrder: 3),
            UiNode(controlId: "retry", role: .button, label: "Retry",
                   contentDescription: "Retry the message", touchWidthDp: minimum,
                   touchHeightDp: minimum, readingOrder: 4),
            UiNode(controlId: "status_row", role: .staticText, label: words("ATTEMPTING"),
                   contentDescription: words("ATTEMPTING"), touchWidthDp: 0, touchHeightDp: 0,
                   readingOrder: 5, stateWords: words("ATTEMPTING"),
                   colourToken: token("ATTEMPTING")),
        ]
    }

    // ------------------------------------------------------------ W01

    func testW01TheContractCarriethRequirementClasses() {
        let assertion = AccessibilityAssertion(
            assertionId: "essential_control_labelled", requirement: .automated,
            platform: .ios, textScale: .largestAccessibility, journey: "cold_launch_airplane")
        XCTAssertEqual(assertion.requirement, .automated)
        XCTAssertTrue(TextScale.largestAccessibility.isLargest)
        XCTAssertFalse(TextScale.defaultSize.isLargest)
        XCTAssertEqual(TextScale.uICTContentSizeCategory, "UICTContentSizeCategoryAccessibilityXXXL")
        let pass = AccessibilityContract.checkEssentialControlsLabelled(healthy())
        XCTAssertTrue(pass.passed, pass.reason)
        XCTAssertEqual(AccessibilityContract.stateWords.count, 6)
        XCTAssertEqual(AccessibilityContract.stateColourToken.count, 6)
    }

    // ------------------------------------------------------------ W02

    func testW02ContrastIsComputedForReal() throws {
        XCTAssertEqual(try AccessibilityContract.contrastRatio("#ffffff", "#000000"), 21.0,
                       accuracy: 0.1)
        let weak = try AccessibilityContract.contrastRatio("#777777", "#888888")
        XCTAssertLessThan(weak, AccessibilityContract.contrastBodyMin)
        let large = try AccessibilityContract.contrastRatio("#949494", "#ffffff")
        XCTAssertGreaterThanOrEqual(large, AccessibilityContract.contrastLargeMin)
        XCTAssertLessThan(large, AccessibilityContract.contrastBodyMin)
        XCTAssertGreaterThanOrEqual(try AccessibilityContract.contrastRatio("#b3261e", "#ffffff"),
                                    AccessibilityContract.contrastBodyMin)
        XCTAssertThrowsError(try AccessibilityContract.contrastRatio("#zzz", "#fff"))
    }

    // ------------------------------------------------------------ W03

    func testW03AnEssentialControlWithoutALabelIsRefused() {
        var blank = healthy()
        blank[1] = UiNode(controlId: "compose_send", role: .button, label: "",
                          contentDescription: "Send the message", touchWidthDp: minimum,
                          touchHeightDp: minimum, readingOrder: 1)
        let verdict = AccessibilityContract.checkEssentialControlsLabelled(blank)
        XCTAssertFalse(verdict.passed)
        XCTAssertTrue(verdict.reason.contains("compose_send"), verdict.reason)
        XCTAssertTrue(verdict.reason.contains("label is empty"))

        var undescribed = healthy()
        undescribed[4] = UiNode(controlId: "retry", role: .button, label: "Retry",
                                contentDescription: "", touchWidthDp: minimum,
                                touchHeightDp: minimum, readingOrder: 4)
        let verdict2 = AccessibilityContract.checkEssentialControlsLabelled(undescribed)
        XCTAssertFalse(verdict2.passed)
        XCTAssertTrue(verdict2.reason.contains("read nothing"))

        let absent = healthy().filter { $0.controlId != "sos_cancel" }
        let verdict3 = AccessibilityContract.checkEssentialControlsLabelled(absent)
        XCTAssertFalse(verdict3.passed)
        XCTAssertTrue(verdict3.reason.contains("sos_cancel"))
        XCTAssertTrue(verdict3.reason.contains("absent"))
    }

    // ------------------------------------------------------------ W04

    func testW04AClippedStatusIsRefusedAtLargeText() {
        var clipped = healthy()
        clipped[5] = UiNode(controlId: "status_row", role: .staticText, label: "On its way; no ans",
                            contentDescription: words("ATTEMPTING"), touchWidthDp: 0,
                            touchHeightDp: 0, readingOrder: 5, stateWords: words("ATTEMPTING"),
                            colourToken: token("ATTEMPTING"), truncated: true)
        let verdict = AccessibilityContract.checkStatusNeverClipped(clipped, .largestAccessibility)
        XCTAssertFalse(verdict.passed)
        XCTAssertTrue(verdict.reason.contains("CLIPPED"), verdict.reason)
        XCTAssertTrue(verdict.reason.contains("largest_accessibility"))
        XCTAssertFalse(AccessibilityContract.checkStatusNeverClipped(clipped, .defaultSize).passed)
    }

    // ------------------------------------------------------------ W05

    func testW05NoColourOnlyState() {
        XCTAssertEqual(Set(AccessibilityContract.stateWords.map { $0.1 }).count,
                       AccessibilityContract.stateWords.count,
                       "two states must not share words")
        XCTAssertEqual(token("QUEUED"), token("CANCELLED"), "two states MAY share a colour")
        XCTAssertNotEqual(words("QUEUED"), words("CANCELLED"))

        var noColour = healthy()
        noColour[5] = UiNode(controlId: "status_row", role: .staticText, label: "On its way",
                             contentDescription: "On its way", touchWidthDp: 0, touchHeightDp: 0,
                             readingOrder: 5, stateWords: words("ATTEMPTING"), colourToken: "")
        let verdict = AccessibilityContract.checkNoColourOnlyState(noColour)
        XCTAssertFalse(verdict.passed)
        XCTAssertTrue(verdict.reason.contains("no colour token"), verdict.reason)

        var noWords = healthy()
        noWords[5] = UiNode(controlId: "status_row", role: .staticText, label: "",
                            contentDescription: "", touchWidthDp: 0, touchHeightDp: 0,
                            readingOrder: 5, stateWords: "", colourToken: "error")
        let verdict2 = AccessibilityContract.checkNoColourOnlyState(noWords)
        XCTAssertFalse(verdict2.passed)
        XCTAssertTrue(verdict2.reason.contains("NO words"), verdict2.reason)
    }

    // ------------------------------------------------------------ W06

    func testW06TheTouchTargetMinimumsDifferByPlatform() {
        XCTAssertEqual(A11yPlatform.android.touchTargetMinDp, 48)
        XCTAssertEqual(A11yPlatform.ios.touchTargetMinDp, 44)
        var small = healthy()
        small[1] = UiNode(controlId: "compose_send", role: .button, label: "Send",
                          contentDescription: "Send", touchWidthDp: 44, touchHeightDp: 44,
                          readingOrder: 1)
        XCTAssertTrue(AccessibilityContract.checkTouchTargets(small, .ios).passed)
        let androidVerdict = AccessibilityContract.checkTouchTargets(small, .android)
        XCTAssertFalse(androidVerdict.passed)
        XCTAssertTrue(androidVerdict.reason.contains("48.0"), androidVerdict.reason)

        let withCaption = healthy() + [UiNode(controlId: "caption", role: .staticText,
                                              label: "note", contentDescription: "note",
                                              touchWidthDp: 0, touchHeightDp: 0, readingOrder: 6)]
        XCTAssertTrue(AccessibilityContract.checkTouchTargets(withCaption, .ios).passed)
    }

    // ------------------------------------------------------------ W07

    func testW07TheReadingOrderIsContiguousAndComplete() {
        XCTAssertTrue(AccessibilityContract.checkReadingOrder(healthy()).passed)
        var gapped = healthy()
        gapped[3] = UiNode(controlId: "sos_cancel", role: .button,
                           label: AccessibilityContract.sosCancelLabel,
                           contentDescription: AccessibilityContract.sosCancelLabel,
                           touchWidthDp: minimum + 8, touchHeightDp: minimum + 8, readingOrder: 9)
        let verdict = AccessibilityContract.checkReadingOrder(gapped)
        XCTAssertFalse(verdict.passed)
        XCTAssertTrue(verdict.reason.contains("not contiguous"), verdict.reason)

        let undeclared = healthy() + [UiNode(controlId: "decorative", role: .imageButton,
                                             label: "", contentDescription: "",
                                             touchWidthDp: minimum, touchHeightDp: minimum,
                                             readingOrder: 6)]
        let verdict2 = AccessibilityContract.checkReadingOrder(undeclared)
        XCTAssertFalse(verdict2.passed)
        XCTAssertTrue(verdict2.reason.contains("no description"), verdict2.reason)
    }

    // ------------------------------------------------------------ W08

    func testW08RtlMirrorMayNotMoveAMeaning() {
        let mirrored = healthy().map { node -> UiNode in
            var copy = node; copy.mirrored = true; copy.mirrorsMeaning = false; return copy
        }
        XCTAssertTrue(AccessibilityContract.checkRtlMeaning(mirrored, rtl: true).passed,
                      "a mirrored LAYOUT is fine")
        var flipped = healthy()
        flipped[1].mirrored = true
        flipped[1].mirrorsMeaning = true
        let verdict = AccessibilityContract.checkRtlMeaning(flipped, rtl: true)
        XCTAssertFalse(verdict.passed)
        XCTAssertTrue(verdict.reason.contains("mirrored with the layout"), verdict.reason)
    }

    // ------------------------------------------------------------ W09

    func testW09LongContentLocaleFixturesFit() {
        let long = "Zugestellt: Die Empfangerin hat den Empfang bestatigt"
        var overflowing = healthy()
        overflowing[0] = UiNode(controlId: "recipient_select", role: .button, label: long,
                                contentDescription: long, touchWidthDp: minimum,
                                touchHeightDp: minimum, readingOrder: 0,
                                containerWidthDp: 200, contentWidthDp: 260)
        XCTAssertTrue(AccessibilityContract.checkLongContent(overflowing, locale: "de").passed,
                      "an overflowing container is fine while the label standeth whole")

        var clipped = healthy()
        clipped[0] = UiNode(controlId: "recipient_select", role: .button,
                            label: String(long.prefix(20)), contentDescription: long,
                            touchWidthDp: minimum, touchHeightDp: minimum, readingOrder: 0,
                            truncated: true, containerWidthDp: 200, contentWidthDp: 260)
        let verdict = AccessibilityContract.checkLongContent(clipped, locale: "de")
        XCTAssertFalse(verdict.passed)
        XCTAssertTrue(verdict.reason.contains("recipient_select"), verdict.reason)
        XCTAssertTrue(verdict.reason.contains("clipped"))

        let arabic = "\u{062a}\u{0645} \u{0627}\u{0644}\u{062a}\u{0633}\u{0644}\u{064a}\u{0645}"
        var rtl = healthy()
        rtl[5] = UiNode(controlId: "status_row", role: .staticText, label: arabic,
                        contentDescription: arabic, touchWidthDp: 0, touchHeightDp: 0,
                        readingOrder: 5, stateWords: arabic, colourToken: token("DELIVERED"))
        XCTAssertTrue(AccessibilityContract.checkLongContent(rtl, locale: "ar").passed)
        XCTAssertTrue(AccessibilityContract.checkStatusNeverClipped(rtl, .largestAccessibility).passed)
    }

    // ------------------------------------------------------------ W10

    func testW10TheRestorationCheckpointsDistinguishHumanChecks() {
        let durable = RestorationCheckpoint(checkpointId: "cold_launch_airplane.durable_estate",
                                            requirement: .automated,
                                            durableFact: "the held rows and their authority status",
                                            survivesAirplaneMode: true)
        let human = RestorationCheckpoint(checkpointId: "cold_launch_airplane.human_screenreader",
                                          requirement: .humanRequired,
                                          durableFact: "none: this is a human observation, not durable state",
                                          survivesAirplaneMode: true)
        XCTAssertEqual(durable.requirement, .automated)
        XCTAssertEqual(human.requirement, .humanRequired)
        XCTAssertTrue(durable.survivesAirplaneMode)
        XCTAssertTrue(human.durableFact.contains("human observation"))
        XCTAssertNotEqual(durable.requirement, human.requirement)
    }

    // ------------------------------------------------------------ W11

    func testW11TheHoldGestureIsSpoken() {
        XCTAssertNotEqual(AccessibilityContract.sosIdleHint, AccessibilityContract.sosArmedHint)
        XCTAssertTrue(AccessibilityContract.sosIdleHint.contains("Hold"))
        XCTAssertTrue(AccessibilityContract.sosArmedHint.contains("Confirm"))
        XCTAssertTrue(AccessibilityContract.sosCancelLabel.contains("Cancel"))
        XCTAssertTrue(AccessibilityContract.sosConfirmLabel.contains("Confirm"))
        for hint in [AccessibilityContract.sosIdleHint, AccessibilityContract.sosArmedHint,
                     AccessibilityContract.sosCancelLabel, AccessibilityContract.sosConfirmLabel] {
            XCTAssertGreaterThan(hint.count, 8, "a hint carrieth words: \(hint)")
        }
    }

    // ------------------------------------------------------------ W12

    func testW12TheWordsAreTheDurableVocabulary() {
        for state in ["QUEUED", "ATTEMPTING", "DELIVERED", "CANCELLED", "EXPIRED", "FAILED"] {
            XCTAssertTrue(AccessibilityContract.stateWords.contains { $0.0 == state }, state)
            XCTAssertTrue(AccessibilityContract.stateColourToken.contains { $0.0 == state }, state)
        }
        XCTAssertTrue(words("DELIVERED").contains("confirmed"))
        XCTAssertTrue(words("ATTEMPTING").contains("no answer"))
        XCTAssertNotEqual(words("DELIVERED"), words("ATTEMPTING"))
        for (state, word) in AccessibilityContract.stateWords {
            XCTAssertFalse(word.isEmpty, state)
            XCTAssertFalse(["red", "green", "amber"].contains(word.lowercased()),
                           "\(state) is not a colour name")
        }
    }

    // ------------------------------------------------------------ W13

    func testW13TheIslesShareTheirVocabularyAndEveryCheckRefusethByName() {
        // the SAME laws and words as the python conductor and the Android court
        var repo = URL(fileURLWithPath: #filePath)
        var hops = 0
        while repo.path != "/" && hops < 12 {
            if FileManager.default.fileExists(atPath: repo.appendingPathComponent("android").path) { break }
            repo.deleteLastPathComponent(); hops += 1
        }
        let conductor = try? String(contentsOf: repo.appendingPathComponent(
            "tools/readiness/accessibility.py"), encoding: .utf8)
        let kotlin = try? String(contentsOf: repo.appendingPathComponent(
            "android/mesh/src/main/java/io/godstone/mesh/a11y/AccessibilityContract.kt"),
            encoding: .utf8)
        XCTAssertNotNil(conductor, "the python conductor must be discoverable")
        XCTAssertNotNil(kotlin, "the Android contract must be discoverable")
        for source in [conductor ?? "", kotlin ?? ""] {
            for word in ["Queued on this phone", "On its way; no answer yet",
                         "Delivered: the recipient confirmed it"] {
                XCTAssertTrue(source.contains(word), "both isles carrieth '\(word)'")
            }
        }

        // every automated check refuseth BY NAME
        var blank = healthy(); blank[1].mirrored = false
        blank[1] = UiNode(controlId: "compose_send", role: .button, label: "",
                          contentDescription: "Send", touchWidthDp: minimum,
                          touchHeightDp: minimum, readingOrder: 1)
        XCTAssertFalse(AccessibilityContract.checkEssentialControlsLabelled(blank).passed)

        var clipped = healthy()
        clipped[5].truncated = true
        XCTAssertFalse(AccessibilityContract.checkStatusNeverClipped(clipped, .largestAccessibility).passed)

        var noColour = healthy()
        noColour[5].colourToken = ""
        XCTAssertFalse(AccessibilityContract.checkNoColourOnlyState(noColour).passed)

        var tiny = healthy()
        tiny[1] = UiNode(controlId: "compose_send", role: .button, label: "Send",
                         contentDescription: "Send", touchWidthDp: 20, touchHeightDp: 20,
                         readingOrder: 1)
        XCTAssertFalse(AccessibilityContract.checkTouchTargets(tiny, .ios).passed)

        // a GAP in the order: replace one node rather than mutate a `let`
        var gapped = healthy()
        gapped[0] = UiNode(controlId: "recipient_select", role: .button,
                           label: "Choose a recipient", contentDescription: "Choose a recipient",
                           touchWidthDp: minimum, touchHeightDp: minimum, readingOrder: 42)
        XCTAssertFalse(AccessibilityContract.checkReadingOrder(gapped).passed)

        let flipped = healthy().map { node -> UiNode in
            var copy = node; copy.mirrored = true; copy.mirrorsMeaning = true; return copy
        }
        XCTAssertFalse(AccessibilityContract.checkRtlMeaning(flipped, rtl: true).passed)

        var overflow = healthy()
        overflow[0].truncated = true
        overflow[0].containerWidthDp = 10
        overflow[0].contentWidthDp = 99
        XCTAssertFalse(AccessibilityContract.checkLongContent(overflow, locale: "fi").passed)

        // ... and the healthy screen passeth every one of them
        XCTAssertTrue(AccessibilityContract.checkEssentialControlsLabelled(healthy()).passed)
        XCTAssertTrue(AccessibilityContract.checkStatusNeverClipped(healthy(), .largestAccessibility).passed)
        XCTAssertTrue(AccessibilityContract.checkNoColourOnlyState(healthy()).passed)
        XCTAssertTrue(AccessibilityContract.checkTouchTargets(healthy(), .ios).passed)
        XCTAssertTrue(AccessibilityContract.checkReadingOrder(healthy()).passed)
        XCTAssertTrue(AccessibilityContract.checkRtlMeaning(healthy(), rtl: false).passed)
        XCTAssertTrue(AccessibilityContract.checkLongContent(healthy(), locale: "en").passed)
    }
}
