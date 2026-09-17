// T54 -- the LabMesh target's own test capability (iOS twin).
//
// The card requireth that the lab's "explicit test capability runs real adapters
// and trusted handshake; it cannot manufacture crypto READY". These cases drive
// the REAL composition through `LabRuntime`.
import XCTest
@testable import GodstoneMesh
@testable import GodstoneCore

final class LabMeshAppTests: XCTestCase {
    private let plaintext = Data(("the river riseth at dawn and the bridge at Harrow is under two "
        + "feet of water; the mill road is cut at both ends. Send boats and a medic.").utf8)

    func testTheLabCarriethItsOwnIdentityAndCannotManufactureReadiness() {
        XCTAssertEqual(LabProfile.labBundleId, "io.godstone.labmesh")
        XCTAssertNotEqual(LabProfile.shippingBundleId, LabProfile.labBundleId,
                          "the lab never carrieth the shipping identity")
        XCTAssertEqual(LabProfile.name, "LABMESH")
        XCTAssertTrue(LabProfile.experimental)
        XCTAssertFalse(LabProfile.manufacturesReadiness,
                       "the lab cannot manufacture crypto readiness")
        let readiness = LabRuntime.readinessStatement()
        XCTAssertFalse(readiness.androidLinkLayerReady)
        XCTAssertFalse(readiness.iosLinkLayerReady)
        XCTAssertEqual(readiness.profile, "LABMESH")
    }

    func testTheLabDrivethARealHandshake() async throws {
        let lab = try LabRuntime.compose(labels: ["A", "R", "B"], seedByte: 0x11)
        XCTAssertEqual(lab.labels, ["A", "R", "B"])
        let sent = await lab.sendDirect("A", recipient: "B", plaintext: plaintext)
        XCTAssertTrue(sent.hasPrefix("applied:"), sent)
        lab.turn("A", "R")
        lab.turn("R", "B")
        XCTAssertEqual(lab.heldCount("B"), 1, "the recipient's real inbox committed it")
        lab.turnAcks("B", "R")
        lab.turnAcks("R", "A")
        XCTAssertFalse(lab.capturedBytes().isEmpty, "the lab composed a real radio")
        XCTAssertNil(lab.durableStateName("A", Data(repeating: 9, count: 16)),
                     "an unknown msg_id carrieth no state")
    }

    func testTheLabRefusethAnImpossibleComposition() {
        XCTAssertThrowsError(try LabRuntime.compose(labels: ["A"]))
        XCTAssertThrowsError(try LabRuntime.compose(labels: ["A", "A"]))
    }

    // MARK: - GS-UX-001: THE JOURNEY REACHETH A DURABLE AUTHORITY AND SURVIVETH IT

    /// *** GS-UX-001 (steps 6 and 2). The card chargeth that 'passing a model test with a fake port does not show
    /// a user action reaches a durable authority'. This arm therefore driveth THE LAB -- the onely surface a user's
    /// journey can travel -- and asketh the durable consequence of that journey from a FRESH HANDLE UPON THE SAME
    /// MEDIUM, which is the onely thing an in-memory medium can never answer.
    ///
    /// HONESTY ABOUT THE RED, MEASURED AND RECORDED RATHER THAN GLOSSED: a PRE-REPAIR BEHAVIOURAL RED WAS NOT
    /// CONSTRUCTIBLE for these clauses, and the reason is a COMPILE-TIME fact on this isle, not a difficulty:
    /// `LabRuntime.compose()` nameth no medium and `ComposedNode.store` is a CONCRETE `InMemoryMessageStore`, so
    /// before the door below existed there was no expression in the language that could ask this question -- an arm
    /// asserting it would have failed the whole test target to COMPILE, and a target that cannot compile presenteth
    /// itself as 'no failures' (this programme's round-471 law). So the door landed first, and the arm's judging
    /// power is proven by a SEPARATE NEGATIVE CASE (the durable wiring replaced by the in-memory road) which
    /// faileth on clause 1's own name.
    ///
    /// CLAUSE 3 IS THE ARM'S OWN DISCRIMINATOR and is not decoration: the same reopened handle is asked for an
    /// intent THAT WAS NEVER AUTHORED, and must answer `.notFound` -- otherwise clause 2's `.found` would be
    /// evidence that the reader returneth `.found` for anything.
    func testTheLabJourneyReachethADurableAuthorityAndSurvivethAReopen() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("godstone-lab-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("lab-durable.sqlite")

        let lab = try LabRuntime.compose(labels: ["A", "R", "B"], seedByte: 0x21)
        let intentId = Data(repeating: 0xA5, count: 16)

        // CLAUSE 1 -- THE LAB REACHETH A DURABLE AUTHORITY AT ALL.
        let verdict = await lab.sendDirectDurable("A", recipient: "B", plaintext: plaintext,
                                                  intentId: intentId, storeURL: storeURL)
        XCTAssertTrue(verdict.hasPrefix("durable:"), verdict)

        // CLAUSE 2 -- AND THE JOURNEY'S CONSEQUENCE SURVIVETH THE RUNTIME THAT AUTHORED IT: a FRESH STORE HANDLE
        // over the caller-named medium still findeth EXACTLY THIS intent. Nothing of the authoring runtime is
        // consulted -- the medium alone answereth.
        let reopened = try SqliteMessageStore(url: storeURL, maxBytes: 64 * 1024 * 1024)
        let journal = SqliteOutboundIntentJournal(store: reopened)
        guard case .found = journal.load(intentId) else {
            return XCTFail("the reopened store must carry the intent the lab's journey pinned")
        }

        // CLAUSE 3 -- THE DISCRIMINATOR: an intent that was NEVER authored is ABSENT from the very same handle,
        // so clause 2's `.found` meaneth what it saith and is not a reader that answereth `.found` to anything.
        guard case .notFound = journal.load(Data(repeating: 0x00, count: 16)) else {
            return XCTFail("an intent that was never authored must be ABSENT, not found")
        }
    }
}
