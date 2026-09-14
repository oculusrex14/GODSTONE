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
}
