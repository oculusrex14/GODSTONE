import XCTest
import Foundation
import CoreBluetooth
import CryptoKit
@testable import GodstoneCore
@testable import GodstoneMesh

// ================================================================================================
// GS-INTEGRATION-001 `scenarios`: THE WRONG-PEER/KEY HAND, THE OS-FACADE ROUTE, AND THE WIPE-WHILE-SUSPENDED.
//
// *** THE CARD'S CLAUSE FOR (A), WHICH THE PRIOR COURT RECORDED AS OWED: *"`testGSINT001AMalformedFrame...` IS NOT
// A WITNESS THAT THE HINT COMPARISON IS WHAT REFUSETH ... the refusal observed above is NOT attributable to the
// hint check"* -- because the transcript refused FIRST. *** *So the three arms below are ORDERED so that each one
// can only be refused at ONE gate:*
//
//   (i)  WRONG TRANSCRIPT -- a divergent hint prologue, so `readMessage2`'s AEAD refuses BEFORE any validator runs.
//   (ii) ADVERTISED HINT   -- an HONEST transcript, whose static key MATCHES, presented with a stranger's hint as
//                             `advertisedRemoteHint`: the hint comparison (step 10) is the ONLY gate left.
//   (iii) WRONG SIGNED STATIC -- an honest transcript (and an honest hint) whose BINDING was issued for a stranger's
//                             key: signature verifies under the stranger's own key, and the static comparison
//                             (step 9) is the ONLY gate left.
//
// *And EVERY one carrieth the HONEST CONTROL on the SAME identities: an arm that refused everything would satisfy
// all three refusals and prove nothing.* **THE PROTOCOL CRYPTO IS UNCHANGED** -- `NoiseSession`,
// `TrustedHandshakeController` and `IdentityBindingValidator` are the production types throughout; all this court
// does is CHOOSE THE INPUT.
// ================================================================================================
final class GsIntegration001ScenarioTests: XCTestCase {

    // ============================================================================================
    // MARK: - (A) the three separately attributable refusals
    // ============================================================================================

    /// *** `testAWrongTranscriptIsRefusedByTheAeadBeforeAnyValidator` -- WITNESS (i). ***
    ///
    /// *The responder builds its HS2 with a DIVERGENT hint prologue: `TrustedHandshakeController.responder` is handed
    /// a `remoteHint` that is not the initiator's, so the Noise prologue (`"GMP2" || initiatorHint || responderHint`,
    /// `NoiseSession.swift:110-124`) differs, the handshake hash differs, and `readMessage2`'s AEAD tag refuseth the
    /// message.* **THE POINT IS THE ORDER: THE REFUSAL HAPPENS INSIDE `readMessage2`, SO NO VALIDATOR -- HINT OR
    /// STATIC -- HAS RUN AT ALL, WHICH IS WHY THIS WITNESS CANNOT BE CONFUSED WITH (ii) OR (iii).**
    func testAWrongTranscriptIsRefusedByTheAeadBeforeAnyValidator() throws {
        let p = try ReadinessTrustedPairing.barePair(seedA: 0x11, privA: 0x22, seedB: 0x33, privB: 0x44)
        defer { ReadinessTrustedPairing.tearDown(p) }
        let bHandle = p.viaBob
        let aHandle = p.viaAlice

        // ---- THE HONEST CONTROL, FIRST, ON THESE VERY IDENTITIES -----------------------------------
        XCTAssertNoThrow(
            try ReadinessTrustedPairing.pairUp(p, viaBob: bHandle, viaAlice: aHandle,
                                               aliceHint: p.aliceIdentity.nodeHint,
                                               bobHint: p.bobIdentity.nodeHint),
            "*** THE HONEST TRANSCRIPT MUST ESTABLISH ON THESE IDENTITIES, or the refusal below proveth nothing. ***")

        // ---- AND NOW THE DIVERGENT ONE, ON A FRESH PAIR OF THE SAME SHAPE ----------------------------
        let q = try ReadinessTrustedPairing.barePair(seedA: 0x51, privA: 0x52, seedB: 0x53, privB: 0x54)
        defer { ReadinessTrustedPairing.tearDown(q) }
        let aAdmission = ReadinessTrustedPairing.firstRelationAdmission(q.viaBob, direction: .outboundCentral)
        let bAdmission = ReadinessTrustedPairing.firstRelationAdmission(q.viaAlice, direction: .inboundPeripheral)
        guard let hs1 = q.aliceManager.beginInitiator(aAdmission, remoteHint: q.bobIdentity.nodeHint) else {
            return XCTFail("the initiator must be able to form its first counsel on an honest hint")
        }
        // *** THE DIVERGENCE: the responder is told a STRANGER's hint, so its prologue and the initiator's disagree.
        // The HS2 that comes back is a well-formed, properly-signed message -- whose AEAD tag is computed over the
        // WRONG transcript. ***
        let strangerHint = Data(repeating: 0xEE, count: 4)
        XCTAssertNotEqual(strangerHint, q.aliceIdentity.nodeHint, "the divergent hint must really differ")
        guard let divergentHs2 = q.bobManager.responderProcessHs1(
            bAdmission, remoteHint: strangerHint, hs1: hs1) else {
            return XCTFail("the responder must still answer the honest HS1 (its refusal is not this witness's subject)")
        }
        XCTAssertEqual(divergentHs2.count, 229, "the answer must be a real second counsel, not a stub")
        XCTAssertNil(
            q.aliceManager.initiatorProcessHs2(aAdmission, hs2: divergentHs2,
                                               advertisedRemoteHint: q.bobIdentity.nodeHint),
            "*** A DIVERGENT TRANSCRIPT MUST BE REFUSED INSIDE `readMessage2`: the prologue differs, so the "
                + "handshake hash differs, so the AEAD tag refuseth BEFORE `IdentityBindingValidator` is ever "
                + "consulted. THIS IS THE WITNESS THAT MAKES (ii) UNAMBIGUOUS -- with it present, a green (ii) "
                + "cannot be misread as 'the transcript refused instead'. ***")
        XCTAssertFalse(q.aliceManager.isReady(aAdmission), "and no session may stand")
        XCTAssertNil(q.aliceManager.slotForTest(q.viaBob), "and the slot must perish with the refusal")
    }

    /// *** `testAStrangerAdvertisedHintIsRefusedByTheHintComparisonOnAnHonestTranscript` -- WITNESS (ii). ***
    ///
    /// *THE WITNESS THE PRIOR COURT NAMED OWED: "I MUTATED THE HINT COMPARISON ITSELF ... AND THIS ARM STAYED GREEN."
    /// Here the transcript is HONEST (so `readMessage2` succeeds), the static key MATCHES (so step 9 passeth), and
    /// **THE ONLY GATE THAT CAN REFUSE IS THE HINT COMPARISON AT STEP 10** (`expectedHint == advertisedNodeHint`).*
    ///
    /// **A ROD THAT TAUTOLOGISES THAT COMPARISON REDDENS THIS ARM** -- and, because witness (i) proveth the
    /// transcript itself refuses nothing here, there is no earlier gate left for the mutation to hide behind.
    func testAStrangerAdvertisedHintIsRefusedByTheHintComparisonOnAnHonestTranscript() throws {
        let p = try ReadinessTrustedPairing.barePair(seedA: 0x61, privA: 0x62, seedB: 0x63, privB: 0x64)
        defer { ReadinessTrustedPairing.tearDown(p) }
        let aAdmission = ReadinessTrustedPairing.firstRelationAdmission(p.viaBob, direction: .outboundCentral)
        let bAdmission = ReadinessTrustedPairing.firstRelationAdmission(p.viaAlice, direction: .inboundPeripheral)

        // ---- THE HONEST CONTROL: the SAME calls, the HONEST advertised hint -------------------------
        guard let hs1 = p.aliceManager.beginInitiator(aAdmission, remoteHint: p.bobIdentity.nodeHint) else {
            return XCTFail("the initiator must form its first counsel")
        }
        guard let honestHs2 = p.bobManager.responderProcessHs1(
            bAdmission, remoteHint: p.aliceIdentity.nodeHint, hs1: hs1) else {
            return XCTFail("the responder must answer the honest HS1")
        }
        XCTAssertNotNil(
            p.aliceManager.initiatorProcessHs2(aAdmission, hs2: honestHs2,
                                               advertisedRemoteHint: p.bobIdentity.nodeHint),
            "*** THE HONEST CONTROL, ON THIS EXACT TRANSCRIPT: with the responder's OWN advertised hint the very "
                + "same HS2 is ACCEPTED -- so the refusal below cannot be the transcript, the static key, the "
                + "signature, or the crypto primitives. IT IS THE HINT COMPARISON AND NOTHING ELSE. ***")

        // ---- AND NOW THE STRANGER'S HINT, ON A FRESH EXCHANGE OF THE SAME SHAPE ----------------------
        let q = try ReadinessTrustedPairing.barePair(seedA: 0x65, privA: 0x66, seedB: 0x67, privB: 0x68)
        defer { ReadinessTrustedPairing.tearDown(q) }
        let qa = ReadinessTrustedPairing.firstRelationAdmission(q.viaBob, direction: .outboundCentral)
        let qb = ReadinessTrustedPairing.firstRelationAdmission(q.viaAlice, direction: .inboundPeripheral)
        guard let q1 = q.aliceManager.beginInitiator(qa, remoteHint: q.bobIdentity.nodeHint) else {
            return XCTFail("the initiator must form its first counsel")
        }
        guard let q2 = q.bobManager.responderProcessHs1(qb, remoteHint: q.aliceIdentity.nodeHint, hs1: q1) else {
            return XCTFail("the responder must answer the honest HS1")
        }
        // *** THE ONLY DIFFERENCE FROM THE CONTROL ABOVE: THE HINT THE INITIATOR IS TOLD TO EXPECT. ***
        let strangerHint = Data(repeating: 0xAB, count: 4)
        XCTAssertNotEqual(strangerHint, q.bobIdentity.nodeHint, "the 'advertised' hint must really be a stranger's")
        XCTAssertNil(
            q.aliceManager.initiatorProcessHs2(qa, hs2: q2, advertisedRemoteHint: strangerHint),
            "*** AN HONEST TRANSCRIPT PRESENTED WITH A STRANGER'S ADVERTISED HINT MUST BE REFUSED. `readMessage2` "
                + "SUCCEEDED (witness (i) proveth that a bad transcript refuseth there), the static key MATCHED (it "
                + "is the honest binding), and the signature VERIFIED -- so `expectedHint == advertisedNodeHint` at "
                + "step 10 is the ONLY gate left, and IT IS WHAT REFUSETH. ***")
        XCTAssertFalse(q.aliceManager.isReady(qa), "and no session may stand on the refused exchange")
        XCTAssertNil(q.aliceManager.slotForTest(q.viaBob), "and the slot must perish")
    }

    /// *** `testABindingForAStrangerStaticKeyIsRefusedAtTheStaticComparison` -- WITNESS (iii). ***
    ///
    /// *The initiator is built over a `LocalBindingIssuer` that issueth the STRANGER's binding -- the seam named at
    /// `TrustedHandshakeController.swift:346-348`.* **So the third counsel carrieth a binding that is internally
    /// VALID (it verifieth under the stranger's own signing key, and its derived hint is the stranger's), while the
    /// noise static is the initiator's real one: STEP 9 (the static comparison) IS THE ONLY GATE LEFT.**
    func testABindingForAStrangerStaticKeyIsRefusedAtTheStaticComparison() throws {
        // ---- THE HONEST CONTROL with the production responder on the same shapes ---------------------
        let p = try ReadinessTrustedPairing.barePair(seedA: 0x71, privA: 0x72, seedB: 0x73, privB: 0x74)
        defer { ReadinessTrustedPairing.tearDown(p) }
        XCTAssertNoThrow(
            try ReadinessTrustedPairing.pairUp(p, viaBob: p.viaBob, viaAlice: p.viaAlice,
                                               aliceHint: p.aliceIdentity.nodeHint,
                                               bobHint: p.bobIdentity.nodeHint),
            "*** THE HONEST EXCHANGE MUST ESTABLISH, so that the refusal below is attributable to the STRANGER "
                + "BINDING and not to the responder's own gates. ***")

        // ---- AND NOW: an initiator whose BINDING ISSUER NAMES A STRANGER ------------------------------
        let q = try ReadinessTrustedPairing.barePair(seedA: 0x75, privA: 0x76, seedB: 0x77, privB: 0x78)
        defer { ReadinessTrustedPairing.tearDown(q) }
        let stranger = try ReadinessTrustedPairing.makeIdentity(seedByte: 0x79, staticPrivByte: 0x7A)
        let strangerIssuer = StrangerBindingIssuer(stranger: stranger)
        let controller = TrustedHandshakeController.initiator(
            identity: q.aliceIdentity,
            remoteHint: q.bobIdentity.nodeHint,
            trustAuthority: RepositoryPeerBindingTrustAuthority(repository: try repository(for: q.aliceIdentity)),
            localBindingIssuer: strangerIssuer)
        // The responder is the PRODUCTION controller over the REAL registry -- nothing about it is substituted.
        let responder = TrustedHandshakeController.responder(
            identity: q.bobIdentity,
            remoteHint: q.aliceIdentity.nodeHint,
            trustAuthority: RepositoryPeerBindingTrustAuthority(repository: try repository(for: q.bobIdentity)))

        guard let hs1 = try? controller.initiatorWriteMessage1() else {
            return XCTFail("the stranger-bound initiator must still form its first counsel")
        }
        guard let hs2 = try? responder.responderProcessMessage1AndWriteMessage2(hs1: hs1) else {
            return XCTFail("the production responder must answer the honest HS1 -- its gates are not the subject here")
        }
        guard let hs3 = controller.initiatorProcessMessage2(hs2: hs2,
                                                           advertisedRemoteHint: q.bobIdentity.nodeHint) else {
            return XCTFail("*** THE INITIATOR MUST REACH THE THIRD COUNSEL: the transcript is honest, so `readMessage2` "
                + "succeedeth and the binding it issueth is VALID UNDER THE STRANGER'S OWN KEY. Only the responder's "
                + "static comparison can refuse this, and it must refuse it at THAT gate. ***")
        }
        XCTAssertEqual(hs3.count, 197, "the third counsel must be a real one")
        XCTAssertFalse(
            responder.responderProcessMessage3(hs3: hs3, advertisedRemoteHint: q.aliceIdentity.nodeHint),
            "*** A BINDING ISSUED FOR A STRANGER'S STATIC KEY MUST BE REFUSED AT STEP 9: the binding is internally "
                + "valid (its signature verifieth under the stranger's own key) and its hint is the stranger's, so "
                + "the NOISE STATIC COMPARISON -- `staticDhPublicKey == authenticatedRemoteStaticKey` -- is what "
                + "refuseth. ***")
        XCTAssertFalse(responder.isReady, "and the responder must hold no session")
        // *** AND THE INITIATOR'S OWN STATE IS DELIBERATELY **NOT** ASSERTED HERE: an initiator that has emitted its
        // third counsel is `.ready` BY DESIGN (it cannot see the responder's verdict -- that is what the key
        // confirmation round is for), so asserting "not ready" would pin a falsehood about the protocol. THE WITNESS
        // IS THE RESPONDER'S REFUSAL ABOVE, which is where `staticDhPublicKey == authenticatedRemoteStaticKey` biteth.
        //
        // (The standalone controllers above are driven directly -- the rig's own `barePair` registries are not used
        // for this exchange -- so a session-manager slot assertion here would be a tautology. The controller-level
        // refusal IS the measurement.)
        XCTAssertNil(
            responder.authenticatedNodeId,
            "*** AND NO IDENTITY MAY HAVE BEEN RETAINED BY THE REFUSED EXCHANGE: the responder must not have "
                + "adopted the third counsel's claimed node id, or a refusal would leave trust behind. ***")
    }

    // ============================================================================================
    // MARK: - (A-R-B) establishment over OS facades + the egress gate + the recipient ACK
    // ============================================================================================

    /// *** `testARBEstablishesOverOSFacadesOnlyThenDeliversADirectFrameAndTheRecipientAck`. ***
    ///
    /// *THE CARD'S CLAUSE, VERBATIM: "establish Alice--Relay--Bob using ONLY OS-facade callbacks
    /// (discovery/connect/subscribe/write notifications through the fake managers), then deliver a DIRECT frame and
    /// the recipient ACK; the arm never calls `drainSyncFrames`, `turnAcks`, synthetic `PeerFound`, or any readiness
    /// setter." AND: "every admitted send must show >=1 recorded `writeValue` byte for that msg_id."*
    ///
    /// **WHAT THIS ARM DRIVES**: `rig.link` twice -- each through `processCentralDidDiscover`,
    /// `processCentralConnect`, the service and characteristic walks, the link-info read and write-back, the
    /// notification-state reduction (where production issues HS1 itself), `processInboundWrite`,
    /// `processInboundSubscribe` and the two write entries -- and then ONE direct frame over the established
    /// relay--bob link, whose bytes cross the fabric into Bob's own transport entry, with production's own
    /// canonical ACK taken from Bob's outbox and carried out over the real writer.
    ///
    /// **THE EGRESS GATE IS THE MEASUREMENT**: the A->B `writeValue` byte count for the send window must be non-zero,
    /// **and** Bob's durable inbox must hold exactly the frame's `msg_id` -- unsatisfiable by a silent no-op.
    func testARBEstablishesOverOSFacadesOnlyThenDeliversADirectFrameAndTheRecipientAck() throws {
        let r = RealTransportHostRig()
        defer { r.tearDown() }
        try r.makeNode(label: "alice", seedByte: 0x11, staticPrivByte: 0x12)
        try r.makeNode(label: "relay", seedByte: 0x21, staticPrivByte: 0x22)
        try r.makeNode(label: "bob", seedByte: 0x31, staticPrivByte: 0x32)

        let ar = try r.link("alice", "relay")
        let rb = try r.link("relay", "bob")
        XCTAssertNotEqual(ar.aHandle, ar.bHandle,
                          "the two sides name one relation by DIFFERENT handles, exactly as a real radio must")
        XCTAssertNotEqual(rb.aHandle, rb.bHandle, "and so for the second hop")

        // *** BOTH HOPS MUST REACH THE TRUSTED HOUR BY PRODUCTION'S OWN EVENT. ***
        XCTAssertTrue(
            r.waitUntil { r.trustedHandles("alice").contains(ar.aHandle)
                          && r.trustedHandles("relay").contains(ar.bHandle)
                          && r.trustedHandles("bob").contains(rb.bHandle) },
            "*** A--R AND R--B MUST BOTH REACH THE TRUSTED HOUR THROUGH THE PRODUCTION PATH (the sealed handshake, "
                + "whose HS1 the transport issueth itself at the notification-state reduction). Alice ring: "
                + r.ring("alice") + " | Relay ring: " + r.ring("relay") + " | Bob ring: " + r.ring("bob") + " ***")

        // ---- THE DIRECT FRAME OVER THE R--B LINK, WITH THE EGRESS WINDOW -----------------------------
        //
        // *** THE DIRECTION IS THE PRODUCTION HINT ELECTION'S, NOT THIS COURT'S: `beginTrustedHandshake` refuseth
        // unless the local hint is strictly ASCENDANT, so only ONE of the two may open the exchange -- and only the
        // OPENER carrieth the outbound relation, which is the only road `ble.send` can travel. The rig DERIVES it, so
        // the arm asks rather than assumes. ***
        // *** THE HONEST DIRECTION: THE RESPONDER SENDS TO THE INITIATOR, BECAUSE THE INITIATOR IS THE SIDE THAT
        // CAN DELIVER LOCALLY. *** *Only the initiator issues the key-confirmation challenge, so only the initiator
        // receives the echo and populates `capturedPeers`; the responder-side delivery would take the handle-only
        // overload whose `receivedFrom: Data()` the inbox refuseth at gate 0 -- BEFORE its first counter bump, which
        // is the all-zero census this arm first measured.*
        let dir = try XCTUnwrap(r.deliverableDirection("relay", "bob"),
                                "the rig must name a direction that can deliver locally")
        let sender = dir.sender
        let receiver = dir.receiver
        let body = Data("the a-r-b arm's own body".utf8)
        let sent = try awaitRig { try await r.sendDirect(from: sender, to: receiver, plaintext: body) }
        XCTAssertGreaterThan(
            sent.egressBytes, 0,
            "*** THE EGRESS GATE: EVERY ADMITTED SEND MUST SHOW >=1 RECORDED `writeValue` BYTE IN THE FABRIC FOR "
                + "THIS SEND WINDOW. A silent no-op would show 0 and FAIL here. Observed: \(sent.egressBytes) bytes "
                + "***")

        XCTAssertTrue(
            r.waitUntil { r.messageStore(receiver).allHeldMsgIds().contains(sent.frame.msgId) },
            "*** AND IT MUST REACH THE RECIPIENT'S DURABLE INBOX THROUGH THE FABRIC AND ITS OWN TRANSPORT ENTRY: the egress "
                + "bytes prove bytes left, THIS proveth they were this frame and that the recipient's sealed open, "
                + "signed-author verification and inbox commit all ran. ***")

        // ---- THE RECIPIENT'S CANONICAL ACK: ISSUED BY PRODUCTION, CARRIED OVER THE REAL WRITER ---------
        XCTAssertEqual(r.inboxCensus(receiver)?.committedNew, 1,
                       "the recipient's OWN census must show exactly one new commit; got "
                       + "\(String(describing: r.inboxCensus(receiver)))")
        XCTAssertEqual(r.inboxCensus(receiver)?.acksIssued, 1,
                       "*** AND PRODUCTION MUST HAVE ISSUED THE CANONICAL RECIPIENT ACK BESIDE IT. ***")
        XCTAssertEqual(r.ackOutboxDepth(receiver), 1,
                       "*** THE ISSUED ACK MUST STAND IN THE NODE'S BOUNDED OUTBOX, drainable for the link. ***")
        guard let ack = r.drainOneAck(receiver) else {
            return XCTFail("the recipient's canonical ACK must have been issued by production")
        }
        let verdict = r.carryToWire(ack, from: receiver, to: sender)
        XCTAssertTrue(String(describing: verdict).hasPrefix("admitted"),
                      "*** THE RECIPIENT ACK MUST CROSS THE REAL LINK WRITER: this rig carrieth the BYTE production "
                          + "issued, it doth not mint one. Observed: \(verdict) ***")
        XCTAssertGreaterThan(r.recordedEgressBytes(label: receiver, msgId: ack.msgId), 0,
                             "*** AND THE ACK'S OWN BYTES MUST BE RECORDED BY THE FABRIC -- the same egress law on "
                                 + "the returning road. ***")

        // ---- ALICE'S HALF: HER TRUSTED RELATION STANDS, AND SHE WAS NEVER THE RECIPIENT ---------------
        XCTAssertTrue(r.trustedHandles("alice").contains(ar.aHandle),
                      "Alice's relation to the relay must still stand -- the mesh was established, not replaced")
        XCTAssertFalse(r.messageStore(receiver).allHeldMsgIds().isEmpty,
                       "and the recipient's estate must not be empty")

        XCTAssertGreaterThan(
            r.fabric.recordCount(), 0,
            "*** THE FABRIC RECORDED SOMETHING AT ALL: the whole arm is about bytes that really crossed. ***")
    }

    // ============================================================================================
    // MARK: - (D) the OS-facade route
    // ============================================================================================

    /// *** `testDTheOSFacadeRouteCarriesASealedFrameIntoTheStoreThroughProductionCode`. ***
    ///
    /// *THE CARD'S CLAUSE: "with `compositionLane: .labHost`, drive `transportDidReceive(data:peerId:receivedFrom:)`
    /// from the fake manager's notification callback and assert the frame reacheth the router/store through
    /// production code; assert the default-lane node ingesteth nothing."*
    ///
    /// **THE DRIVE IS THE FABRIC'S, NOT THE COURT'S**: bytes are handed to the receiving transport's REAL
    /// `processPeripheralReceiveWrite` (the responder's notification callback road), which reassembles, opens and
    /// dispatches -- and the store row that follows is written by `Router.accept` inside the node's own
    /// `transportDidReceive`. *The court only readeth the store afterwards.*
    func testDTheOSFacadeRouteCarriesASealedFrameIntoTheStoreThroughProductionCode() throws {
        let r = RealTransportHostRig()
        defer { r.tearDown() }
        try r.makeNode(label: "alice", seedByte: 0x21, staticPrivByte: 0x22)
        try r.makeNode(label: "bob", seedByte: 0x31, staticPrivByte: 0x32)
        let link = try r.link("alice", "bob")

        let initiator = try XCTUnwrap(r.opener(of: "alice", "bob"), "the initiator of the alice--bob exchange")
        XCTAssertTrue(
            r.waitUntil { r.trustedHandles(initiator).contains(r.linkHandle(initiator,
                                                                             r.peer(of: "alice", "bob")!)) },
            "*** THE INITIATOR'S OWN APPLICATION-LINKREADY ROSTER MUST CONTAIN THE RELATION, because that roster is
                what maketh the peer route-eligible for `dispatchDirect`. Ring: " + r.ring(initiator) + " ***")

        let dir = try XCTUnwrap(r.deliverableDirection("alice", "bob"),
                                "the rig must name a direction that can deliver locally")
        let sender = dir.sender
        let receiver = dir.receiver
        let sent = try awaitRig { try await r.sendDirect(from: sender, to: receiver,
                                                         plaintext: Data("d-route".utf8)) }
        XCTAssertTrue(
            r.waitUntil { r.messageStore(receiver).allHeldMsgIds().contains(sent.frame.msgId) },
            "*** THE SEALED FRAME MUST REACH BOB'S DURABLE STORE THROUGH THE PRODUCTION INGEST ROAD (the fabric "
                + "entereth `processPeripheralReceiveWrite`, the receiver reassembles and opens, the node's own "
                + "`transportDidReceive` dispatches, and `Router.accept` persisteth). ring: " + r.ring("bob") + " ***")
        XCTAssertGreaterThan(r.recordedEgressBytes(label: sender, msgId: sent.frame.msgId), 0,
                             "and the SAME send's egress window must be non-zero (the card's egress gate)")

        // ---- AND THE DEFAULT-LANE TWIN: NOTHING INGESTS ----------------------------------------------
        let shipping = try r.makeShippingNode(label: "shipping", seedByte: 0x41, staticPrivByte: 0x42)
        shipping.runtime.meshNode.transportDidReceive(
            data: sent.frame.encode(), peerId: UUID(), receivedFrom: Data(repeating: 0xAA, count: 16))
        XCTAssertEqual(
            0, shipping.messageStore.allHeldMsgIds().count,
            "*** THE DEFAULT-LANE NODE INGESTS NOTHING FROM THE SAME BYTES: the refusal is `linkLayerAdmissible`, "
                + "and the labHost node above ingesteth the selfsame encoding. ***")
    }

    // ============================================================================================
    // MARK: - (E) wipe during a suspended write
    // ============================================================================================

    /// *** `testEWipeDuringASuspendedWriteRefusesStorageFailureThenReopens`. ***
    ///
    /// *The card's clause: "close the lane gate mid-write, assert lookups answer `.storageFailure`, `committedNew`
    /// delta 0, then reopen and continue (RuntimeLifecycleGate gated lookups)."*
    ///
    /// **HOW THIS RIG MODELS EACH HALF, NAMED RATHER THAN GLOSSED:**
    ///   * **THE CLOSED GATE IS THE WIPE AUTHORITY'S OWN**: `runtime.wipeAuthorityForTest().requestWipe()` writeth the
    ///     durable journal, and `wipeGateBox.authority` is THE SAME OBJECT the composition's inbox-commit closure and
    ///     the resolver decorators consult -- so the refusal is production's own typed `.storageFailure`.
    ///   * **THE TYPED LOOKUP** is read through the gated peer-identity road the runtime handeth out
    ///     (`recipientKeyResolver.publicSigningKey`), whose `WipeGatedPeerIdentityLookupSource` answereth
    ///     `.storageFailure` and therefore `nil` -- fail-closed.
    ///   * **THE "REOPEN"** is a FRESH runtime over the SAME ON-DISK URLs whose journal is idle: `CrashResumableWipe`
    ///     has no un-invalidate (a wipe is not undone), so "the lane reopens on a settled estate" is the honest
    ///     reading -- and the arm proveth the estate was NOT corrupted by asserting the frames that committed before
    ///     the gate closed are STILL THERE, and that new work commits afterwards.
    func testEWipeDuringASuspendedWriteRefusesStorageFailureThenReopens() throws {
        let r = RealTransportHostRig()
        defer { r.tearDown() }
        let alice = try r.makeNode(label: "alice", seedByte: 0x51, staticPrivByte: 0x52)
        let bob = try r.makeNode(label: "bob", seedByte: 0x61, staticPrivByte: 0x62)
        _ = try r.link("alice", "bob")
        let initiator = try XCTUnwrap(r.opener(of: "alice", "bob"), "the initiator of the alice--bob exchange")
        XCTAssertTrue(
            r.waitUntil { r.trustedHandles(initiator).contains(r.linkHandle(initiator,
                                                                             r.peer(of: "alice", "bob")!)) },
            "*** THE INITIATOR'S OWN APPLICATION-LINKREADY ROSTER MUST CONTAIN THE RELATION. Ring: "
                + r.ring(initiator) + " ***")

        // ---- (1) A FIRST FRAME COMMITS, SO THE ESTATE HAS SOMETHING TO PROVE AFTERWARDS ----------------
        let dir = try XCTUnwrap(r.deliverableDirection("alice", "bob"),
                                "the rig must name a direction that can deliver locally")
        let sender = dir.sender
        let receiver = dir.receiver
        let first = try awaitRig { try await r.sendDirect(from: sender, to: receiver,
                                                          plaintext: Data("before the gate".utf8)) }
        XCTAssertTrue(r.waitUntil { r.messageStore(receiver).allHeldMsgIds().contains(first.frame.msgId) },
                      "the first frame must commit before the gate closeth; ring: " + r.ring(receiver))
        let censusBefore = r.inboxCensus(receiver)
        XCTAssertEqual(censusBefore?.committedNew, 1, "exactly one new commit so far")

        // ---- (2) THE LOOKUP HALF: A GATED READ ANSWERETH `.storageFailure` (nil, fail-closed) ---------
        XCTAssertNotNil(
            r.node(receiver)!.runtime.recipientKeyResolver.publicSigningKey(forNodeId: r.node(sender)!.identity.nodeId),
            "*** BEFORE THE WIPE THE GATED LOOKUP MUST RESOLVE -- a resolver that always answered nil would satisfy "
                + "the refusal below while proving nothing. ***")

        // ---- (3) CLOSE THE GATE MID-WRITE: a real wipe is REQUESTED, so the durable journal says so ----
        _ = try r.node(receiver)!.runtime.wipeAuthorityForTest().requestWipe()
        XCTAssertNil(
            r.node(receiver)!.runtime.recipientKeyResolver.publicSigningKey(forNodeId: r.node(sender)!.identity.nodeId),
            "*** WITH THE WIPE PENDING, THE GATED PEER-IDENTITY LOOKUP MUST ANSWER `.storageFailure`, WHICH THE "
                + "RESOLVER PUBLISHES AS `nil` -- fail-closed. A resolver that still answered would be reading "
                + "stores the wipe is erasing. ***")

        // ---- (4) AND THE INBOX COMMIT REFUSETH, TYPED: `.storageFailure`, `committedNew` UNMOVED ---------
        let second = try awaitRig { try await r.authorDirectFrame(from: sender, to: receiver,
                                                                 plaintext: Data("during the wipe".utf8)) }
        let verdict = r.offerToInbox(receiver, frame: second, from: r.node(sender)!.identity.nodeId)
        XCTAssertEqual(
            String(describing: verdict).contains("storageFailure"), true,
            "*** A COMMIT WHILE THE WIPE STANDS PENDING MUST BE REFUSED WITH THE TYPE'S OWN VOCABULARY, "
                + "`.storageFailure` -- never a plausible-looking success. Observed: \(verdict) ***")
        let censusAfter = r.inboxCensus(receiver)
        XCTAssertEqual(
            censusAfter?.committedNew, censusBefore?.committedNew,
            "*** `committedNew` MUST NOT MOVE: the refusal left the durable estate exactly as it found it. ***")
        XCTAssertFalse(
            r.messageStore(receiver).allHeldMsgIds().contains(second.msgId),
            "and the refused frame must leave NO held row")

        // ---- (5) REOPEN ON A SETTLED ESTATE: THE FIRST FRAME SURVIVED AND NEW WORK COMMITS --------------
        let reopened = try r.closeAndReopen(receiver, as: receiver + "_reopened")
        XCTAssertTrue(
            reopened.messageStore.allHeldMsgIds().contains(first.frame.msgId),
            "*** THE ESTATE MUST SURVIVE THE GATE'S CLOSE: the frame that committed before the wipe is still held, "
                + "on-disk, in a FRESH runtime over the SAME URLs (the handles were closed and the process's view of "
                + "the file released) -- so the refusal above suspended WRITES without corrupting what was already "
                + "durable. ***")
        let third = try awaitRig { try await r.authorDirectFrame(from: sender, to: receiver + "_reopened",
                                                                plaintext: Data("after the gate".utf8)) }
        let reopenedVerdict = r.offerToInbox(receiver + "_reopened", frame: third,
                                            from: r.node(sender)!.identity.nodeId)
        XCTAssertEqual(
            String(describing: reopenedVerdict).contains("new(") || String(describing: reopenedVerdict).contains("duplicate("),
            true,
            "*** AND WORK MUST RESUME on an idle journal: a fresh runtime's gate standeth open, so the third frame "
                + "is ADMITTED. Observed: \(reopenedVerdict) ***")
        XCTAssertTrue(reopened.messageStore.allHeldMsgIds().contains(third.msgId),
                      "and it must be durably held")
    }

    // ============================================================================================
    // MARK: - helpers
    // ============================================================================================

    /// *A `LocalBindingIssuer` that issueth the STRANGER's binding -- the seam at
    /// `TrustedHandshakeController.swift:346-348`. The binding is genuine and internally valid; it simply names a key
    /// that is not the noise static the exchange authenticated.*
    private struct StrangerBindingIssuer: LocalBindingIssuer {
        let stranger: MeshIdentity
        func issueEncodedBinding() throws -> Data {
            return try stranger.issueIdentityBinding().encode()
        }
    }

    private func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

    private func repository(for identity: MeshIdentity) throws -> PeerIdentityRepository {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("scenario_repo_\(UUID().uuidString).db")
        let store = try SqlitePeerIdentityStore(url: url)
        return PeerIdentityRepository(store: store)
    }

    private func awaitRig<T>(_ body: @escaping () async throws -> T,
                             file: StaticString = #filePath, line: UInt = #line) throws -> T {
        let sem = DispatchSemaphore(value: 0)
        var result: Result<T, Error>?
        Task {
            do { result = .success(try await body()) } catch { result = .failure(error) }
            sem.signal()
        }
        guard sem.wait(timeout: .now() + 30) == .success else {
            XCTFail("the async body never finished", file: file, line: line)
            throw RealTransportHostRig.RigError.notEstablished("async body timed out")
        }
        switch result {
        case .success(let v): return v
        case .failure(let e): throw e
        case nil:
            XCTFail("the async body produced nothing", file: file, line: line)
            throw RealTransportHostRig.RigError.notEstablished("async body produced nothing")
        }
    }
}
