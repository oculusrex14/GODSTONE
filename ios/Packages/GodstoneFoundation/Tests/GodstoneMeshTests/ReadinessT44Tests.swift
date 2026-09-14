// T44 readiness court (iOS isle) -- crash-safe multihop through COMPOSED runtimes.
// The twin of ReadinessT44Test.kt (android), with the SAME witness name set.
//
// Every witness drives the COMPOSITION (real MeshNode, real Router with its
// required store, real durable store, real DeliveryTracker, real recipient inbox,
// real T84 ACK authority, real T42 sync pump) and substitutes only the OS facades:
// a fixed clock and a recording radio.
//
// Host tests prove no CoreBluetooth and no Data Protection behaviour; readiness
// stays false and no gate is closed.
import XCTest
import CryptoKit
@testable import GodstoneMesh
import GodstoneCore

final class ReadinessT44Tests: XCTestCase {
    // a realistic payload: the sealed-sender layout carrieth the sender's static
    // public key and a signature beside the message, so a short plaintext is
    // refused by the codec as "shorter than the fixed layout"
    private let plaintext = Data(("the river riseth at dawn and the bridge at Harrow is under two "
        + "feet of water; the mill road is cut at both ends and the surgery hath no power. Send "
        + "boats and a medic to the church hall.").utf8)

    private func harness(_ now: Int64 = 5_000) -> ComposedRuntimeHarness {
        let clock = FixedHostClock(now: now)
        return ComposedRuntimeHarness(clock: clock, link: LinkFacade(clock: clock))
    }

    /// A and B linked; for the relay cases R sitteth between them.
    private func pair() throws -> ComposedRuntimeHarness {
        let h = harness()
        _ = try h.addNode("A", seedByte: 0x11)
        _ = try h.addNode("B", seedByte: 0x31)
        XCTAssertTrue(h.link("A", "B").isApplied)
        return h
    }

    private func relayWorld() throws -> ComposedRuntimeHarness {
        let h = harness()
        _ = try h.addNode("A", seedByte: 0x11)
        _ = try h.addNode("R", seedByte: 0x21)
        _ = try h.addNode("B", seedByte: 0x31)
        XCTAssertTrue(h.link("A", "R").isApplied)
        XCTAssertTrue(h.link("R", "B").isApplied)
        return h
    }

    private func stateOf(_ node: ComposedNode, _ mid: Data) -> DeliveryState? {
        if case .found(let rec) = node.tracker.lookup(mid) { return rec.state }
        return nil
    }

    // ------------------------------------------------------------ W01

    /// W01 -- DIRECTED DELIVERY through the composition: author -> durable enqueue
    /// -> link -> recipient inbox -> signed ACK -> DELIVERED at the author.
    func testW01DirectedDeliveryReachethDeliveredThroughTheComposition() async throws {
        let h = try pair()
        let out = try await h.sendDirect("A", recipient: "B", plaintext: plaintext)
        XCTAssertTrue(out.isApplied, out.detail)
        let a = h.node("A")!; let b = h.node("B")!
        let mid = try XCTUnwrap(a.store.allHeldMsgIds().first)
        XCTAssertEqual(stateOf(a, mid), .queuedDurably, "the author durably queued it")
        XCTAssertTrue(b.store.allHeldMsgIds().contains(mid), "the recipient holds it")
        h.turnAcks("B", "A")
        XCTAssertEqual(stateOf(a, mid), .acknowledgedByRecipient,
                       "only the intended recipient's ACK produced DELIVERED")
        XCTAssertEqual(a.node.deliveryProjection(mid).label, .delivered)
        XCTAssertTrue(h.traceSnapshot().kinds().contains("turn_acks"))
    }

    // ------------------------------------------------------------ W02

    /// W02 -- SOS BROADCAST: mode none, no recipient bound, no delivery claim.
    func testW02SosBroadcastClaimethNoRecipientAndNoDelivery() async throws {
        let h = try pair()
        let out = await h.sendSos("A", plaintext: Data("distress".utf8))
        XCTAssertTrue(out.isApplied, out.detail)
        let a = h.node("A")!
        let mid = try XCTUnwrap(a.store.allHeldMsgIds().first)
        guard case .found(let rec) = a.tracker.lookup(mid) else { return XCTFail("the row must stand") }
        XCTAssertEqual(rec.ackMode, .none)
        XCTAssertNil(rec.expectedRecipientNodeId, "a broadcast bindeth no recipient")
        XCTAssertEqual(rec.state, .queuedDurably)
        let projection = a.node.deliveryProjection(mid)
        XCTAssertEqual(projection.label, .offered, "offered to the links, never delivered")
        XCTAssertFalse(projection.claimsDelivery)
    }

    // ------------------------------------------------------------ W03

    /// W03 -- NO RELAY PLAINTEXT: every byte the radio carried is searched.
    func testW03NoRelayPlaintextIsEverCaptured() async throws {
        let h = try pair()
        _ = try await h.sendDirect("A", recipient: "B", plaintext: plaintext)
        h.turnAcks("B", "A")
        let captured = h.capturedBytes()
        XCTAssertFalse(captured.isEmpty, "the radio carried something")
        for (i, bytes) in captured.enumerated() {
            XCTAssertFalse(bytes.range(of: plaintext) != nil, "capture #\(i) carrieth the plaintext")
        }
        if let sealedFrame = captured.compactMap({ FrameV2.decode($0) }).first(where: { $0.type == .message }) {
            XCTAssertNotEqual(sealedFrame.flags & FrameV2.Flags.sealed, 0, "the frame is SEALED")
            XCTAssertNil(sealedFrame.payload.range(of: plaintext),
                         "the plaintext is not in the wire payload")
        } else {
            XCTFail("a sealed MESSAGE must have been captured")
        }
    }

    // ------------------------------------------------------------ W04

    /// W04 -- INTENDED-RECIPIENT-ONLY ACK: a stranger's ACK cannot deliver.
    func testW04OnlyTheIntendedRecipientsAckDelivereth() async throws {
        let h = try pair()
        _ = try h.addNode("C", seedByte: 0x41)
        XCTAssertTrue(h.link("A", "C").isApplied)
        _ = try await h.sendDirect("A", recipient: "B", plaintext: plaintext)
        let a = h.node("A")!; let c = h.node("C")!
        let mid = try XCTUnwrap(a.store.allHeldMsgIds().first)
        let forged = ackFrame(mid: mid, signer: c)
        _ = a.node.ingestInbound(forged, receivedFrom: c.nodeId)
        XCTAssertEqual(stateOf(a, mid), .queuedDurably, "a stranger's ACK may not deliver")
        XCTAssertFalse(a.node.deliveryProjection(mid).claimsDelivery)
    }

    // ------------------------------------------------------------ W05

    /// W05 -- CRASH BEFORE THE RADIO: the estate holds the frame, nothing left.
    func testW05ACrashBeforeTheLinkSendethNothing() async throws {
        let h = try pair()
        h.crashAfter(ComposedRuntimeHarness.seamBeforeLink)
        _ = try? await h.sendDirect("A", recipient: "B", plaintext: plaintext)
        XCTAssertEqual(h.link.deliveriesTo("B").count, 0, "the radio carried NOTHING on that link")
        XCTAssertEqual(h.link.admitted(), 0, "and nothing was ADMITTED")
        let a = h.node("A")!
        XCTAssertEqual(a.store.allHeldMsgIds().count, 1, "but the durable enqueue stood")
        let cp = try h.checkpoint("A")
        XCTAssertEqual(cp.heldCount, 1)
        XCTAssertEqual(cp.rows.values.first, "queuedDurably")
    }

    // ------------------------------------------------------------ W06

    /// W06 -- CRASH AFTER THE INBOUND COMMIT: the author claimeth NOTHING yet.
    func testW06ACrashAfterTheInboundCommitClaimethNoDelivery() async throws {
        let h = try pair()
        _ = try await h.sendDirect("A", recipient: "B", plaintext: plaintext)
        let a = h.node("A")!; let b = h.node("B")!
        let mid = try XCTUnwrap(a.store.allHeldMsgIds().first)
        XCTAssertTrue(b.store.allHeldMsgIds().contains(mid), "the recipient's inbox committed it")
        let census = b.inbox.census()
        XCTAssertEqual(census.acksIssued, 1, "the recipient issued its canonical ACK")
        XCTAssertEqual(census.acksRefusedKey, 0, "and self-verified it")
        XCTAssertEqual(census.verificationRejections, 0)
        XCTAssertEqual(stateOf(a, mid), .queuedDurably, "the author claimeth NO delivery yet")
        h.turnAcks("B", "A")
        XCTAssertEqual(stateOf(a, mid), .acknowledgedByRecipient)
    }

    // ------------------------------------------------------------ W07

    /// W07 -- WIPE DURING A SEND: no pre-wipe epoch may send.
    func testW07AWipeDuringASendStopsEveryEpoch() async throws {
        let h = try pair()
        _ = try await h.sendDirect("A", recipient: "B", plaintext: plaintext)
        let before = h.link.admitted()
        h.beginWipe()
        XCTAssertTrue(h.isWiped())
        _ = try await h.sendDirect("A", recipient: "B", plaintext: Data("another".utf8))
        XCTAssertEqual(h.link.admitted(), before,
                       "the link admitted nothing while the wipe was in progress")
        XCTAssertTrue(h.traceSnapshot().kinds().contains("send_refused"))
    }

    // ------------------------------------------------------------ W08

    /// W08 -- REPLAY AFTER RECONNECT is a DUPLICATE.
    func testW08AReplayAfterReconnectIsADuplicate() async throws {
        let h = try pair()
        _ = try await h.sendDirect("A", recipient: "B", plaintext: plaintext)
        let a = h.node("A")!; let b = h.node("B")!
        let held = b.store.allHeldMsgIds().count
        let mid = try XCTUnwrap(a.store.allHeldMsgIds().first)
        let captured = try XCTUnwrap(h.link.deliveriesTo("B").first).bytes
        h.turnAcks("B", "A")
        XCTAssertEqual(stateOf(a, mid), .acknowledgedByRecipient)

        XCTAssertTrue(h.unlink("A", "B").isApplied)
        XCTAssertFalse(h.isLinked("A", "B"))
        XCTAssertTrue(h.link("A", "B").isApplied)
        XCTAssertTrue(h.isLinked("A", "B"))
        // the REPLAY carrieth the very bytes the radio carried the first time, and
        // RE-ENTERETH the receiving statute (the marker proveth it)
        _ = h.replay("A", to: "B", bytes: captured)
        XCTAssertTrue(h.traceSnapshot().kinds().contains("replay_ingested"),
                      "the replay RE-ENTERED the receiving statute")
        XCTAssertEqual(b.store.allHeldMsgIds().count, held,
                       "the replay did not duplicate the recipient's estate")
        XCTAssertEqual(stateOf(a, mid), .acknowledgedByRecipient,
                       "and the terminal delivery claim standeth")
    }

    // ------------------------------------------------------------ W09

    /// W09 -- FINITE RESOURCE GROWTH: the caps are observable.
    func testW09ResourceGrowthIsFinite() async throws {
        let h = try pair()
        for i in 0..<(LinkFacade.maxCaptured / 16 + 64) {
            _ = try await h.sendDirect("A", recipient: "B",
                                       plaintext: Data("burst-\(i)".utf8) + plaintext)
        }
        XCTAssertLessThanOrEqual(h.link.deliveries().count, LinkFacade.maxCaptured,
                                 "the capture ledger stoppeth at its bound")
        XCTAssertGreaterThanOrEqual(h.link.droppedCount(), 0)
        XCTAssertLessThanOrEqual(h.traceSnapshot().size(), MeshTrace.maxEvents,
                                 "the trace stoppeth at its bound")
        // the bound itself, proved on a small trace
        let small = MeshTrace(bound: 8)
        for i in 0..<20 {
            small.append(TraceEvent(kind: "burst", atMonoMillis: Int64(i), fields: ["i": "\(i)"]))
        }
        XCTAssertEqual(small.size(), 8, "the trace stoppeth at ITS OWN bound")
        XCTAssertEqual(small.droppedCount(), 12, "and the supersessions are counted")
        let cp = try h.checkpoint("A")
        XCTAssertGreaterThan(cp.heldCount, 0)
        XCTAssertEqual(cp.heldDigest, try h.checkpoint("A").heldDigest,
                       "the digest is stable for the same estate")
    }

    // ------------------------------------------------------------ W10

    /// W10 -- the CROSS-PROCESS TRACE round-trippeth and refuseth a future schema.
    func testW10TheTraceRoundTrippethAndRefusethAFutureSchema() async throws {
        let h = try pair()
        _ = try await h.sendDirect("A", recipient: "B", plaintext: plaintext)
        let document = h.traceSnapshot().json()
        XCTAssertFalse("\(document)".contains(String(decoding: plaintext, as: UTF8.self)),
                       "the trace carrieth no plaintext")
        let replayed = try h.replay(document)
        XCTAssertEqual(replayed.count, h.traceSnapshot().size())
        XCTAssertEqual(replayed.map { $0.kind }, h.traceSnapshot().kinds())
        var future = document
        future["schema"] = 2
        XCTAssertThrowsError(try MeshTrace.parse(future),
                             "a future trace schema is refused, never auto-detected")
    }

    // ------------------------------------------------------------ W11

    /// W11 -- a REFUSED link leaves the durable estate standing.
    func testW11ARefusedLinkLeavethTheDurableEstateStanding() async throws {
        let h = try pair()
        h.link.admit = { _, _ in false }
        _ = try await h.sendDirect("A", recipient: "B", plaintext: plaintext)
        let a = h.node("A")!
        XCTAssertEqual(h.link.admitted(), 0, "nothing was admitted")
        XCTAssertGreaterThanOrEqual(h.link.refused(), 1, "and the attempts are recorded REFUSED")
        let mid = try XCTUnwrap(a.store.allHeldMsgIds().first)
        XCTAssertEqual(stateOf(a, mid), .queuedDurably, "the durable row standeth queued")
        let projection = a.node.deliveryProjection(mid)
        XCTAssertEqual(projection.label, .queued, "the label saith QUEUED, never OFFERED")
        XCTAssertTrue(projection.retryable)
        h.link.admit = { _, _ in true }
    }

    // ------------------------------------------------------------ W12

    /// W12 -- the COMPOSED-TRACE law: every CONTENT byte the radio carried belongeth
    /// to a frame the sender durably holdeth.
    func testW12EveryRelayedByteBelongethToADurablyHeldFrame() async throws {
        let h = try relayWorld()
        _ = try await h.sendDirect("A", recipient: "B", plaintext: plaintext)
        h.turn("A", "R")
        h.turn("R", "B")
        var contentChecked = 0
        for delivery in h.link.deliveries() {
            guard let frame = FrameV2.decode(delivery.bytes) else { continue }
            if frame.type != .message && frame.type != .sos { continue }
            guard let sender = h.node(delivery.fromLabel) else { continue }
            XCTAssertTrue(sender.store.allHeldMsgIds().contains(frame.msgId),
                          "a \(frame.type) byte left \(delivery.fromLabel) without its durable frame")
            // AND the receiving node's own estate carrieth it: the durable inbound
            // commit is what this law is about
            if let receiver = h.node(delivery.toLabel) {
                XCTAssertTrue(receiver.store.allHeldMsgIds().contains(frame.msgId),
                              "a \(frame.type) byte arrived at \(delivery.toLabel) without entering its estate")
            }
            contentChecked += 1
        }
        XCTAssertGreaterThanOrEqual(contentChecked, 1, "at least one content frame was checked")
        let kinds = h.traceSnapshot().kinds()
        XCTAssertTrue(kinds.contains("send_direct"))
        XCTAssertTrue(kinds.contains("link_offer"))
        XCTAssertTrue(kinds.contains("turn"))
    }

    // ------------------------------------------------------------ helpers

    private func ackFrame(mid: Data, signer: ComposedNode) -> FrameV2 {
        let preimage = Data("GMP2-ACK".utf8) + mid + signer.nodeId
        let key = try! Curve25519.Signing.PrivateKey(rawRepresentation: signer.signingKeySeed())
        let signature = try! key.signature(for: preimage)
        return FrameV2(type: .ack, msgId: mid, routingTag: Data(repeating: 7, count: 4),
                       ttl: 12, hopCount: 0, flags: 0,
                       payload: signature + signer.nodeId)
    }
}
