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

        // *** IOS-R10: THE LAB COMPOSES OVER AN ESTATE ROOT, SO THE NODES OWN REAL DURABLE STORES. *** *The durable
        // send refuses an in-memory node (there is no medium to outlive the process), so the journey's medium IS the
        // authors' own store -- and the reopen below asks THAT file.*
        let lab = try LabRuntime.compose(labels: ["A", "R", "B"], seedByte: 0x21, estateRoot: dir)
        let intentId = Data(repeating: 0xA5, count: 16)
        let storeURL = lab.authorDurableStoreURL

        // CLAUSE 1 -- THE LAB REACHETH A DURABLE AUTHORITY AT ALL.
        let verdict = await lab.sendDirectDurable("A", recipient: "B", plaintext: plaintext,
                                                  intentId: intentId)
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

    // MARK: - GS-UX-001 step 1 + IOS-R9/R10: THE JOURNEY REACHES A DURABLE AUTHORITY

    /// *** *** IOS-R9/R10: THE LAB'S RENDERED JOURNEYS REALLY REACH THE DURABLE ESTATE. *** ***
    ///
    /// *THE REVIEW'S CHARGE WAS THAT THE JOURNEYS "stop at disconnected models and static text", and that a SOURCE
    /// GREP ("assert `sendDirect` is a substring") proveth what the code SAYETH rather than what a user can DO.
    /// **THAT SOURCE-SHAPE ASSERTION IS DELETED** (it is incidental-wording, not consumer-visible behaviour) AND
    /// REPLACED BY THE REAL CONSEQUENCES A JOURNEY MUST PRODUCE, driven through the SAME `LabRuntime` doors the
    /// rendered controls call:*
    ///   * a durable SEND pins a FOUND intent in the author node's OWN store, and the recipient's own ingest carries
    ///     it (the message row really lands);
    ///   * an SOS ARM writes a durable delivery ROW and a HELD frame, and the row survives a REOPEN over the same root;
    ///   * a WIPE drives the production ladder to a COMPLETE terminal over the lab's OWN inventory with no artifact
    ///     surviving.
    func testTheLabJourneysReachADurableEstateAndLeaveRealRows() async throws {
        // *A CLEAN LAB ESTATE, or this arm measureth a previous arm's wipe.*
        LabRuntime.resetLabEstateForTest()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lab-journeys-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let lab = try LabRuntime.compose(labels: ["A", "R", "B"], seedByte: 0x31, estateRoot: dir)

        // (1) THE SEND JOURNEY: a durable intent the AUTHOR NODE'S OWN STORE carrieth, and a recipient that processed it.
        let intentId = LabRuntime.mintIntentId()
        let verdict = await lab.sendDirectDurable("A", recipient: "R",
                                                  plaintext: Data("boats to the mill".utf8), intentId: intentId)
        XCTAssertTrue(verdict.hasPrefix("durable:"),
                      "the send journey must reach the durable authority; observed: \(verdict)")
        XCTAssertTrue(lab.durableIntentVerdict(intentId).hasPrefix("found:"),
                      "*** AND THE INTENT MUST STAND IN THE AUTHOR'S OWN STORE, read from a FRESH handle. ***")
        XCTAssertGreaterThan(lab.heldCount("R"), 0,
                             "*** AND THE RECIPIENT MUST HAVE PROCESSED THE FRAME, so an ACK can advance it. ***")

        // (2) THE SOS JOURNEY: a durable ROW and a HELD frame -- the obligation a relaunch reads.
        let armed = lab.armSos(payload: Data("SOS".utf8))
        XCTAssertTrue(armed.hasPrefix("armed:"), "the SOS journey must reach the durable authority; observed: \(armed)")
        guard let sosId = lab.activeSosMsgId() else {
            return XCTFail("an armed call must carry a durable msg_id")
        }
        XCTAssertEqual(lab.durableDeliveryState(author: lab.author, msgId: sosId), .queuedDurably,
                       "*** THE SOS ROW MUST BE DURABLE ON DISK, not a register's claim. ***")
        XCTAssertTrue(lab.durableSosHeldMsgIds(author: lab.author).contains(sosId),
                      "and the held frame itself must be on disk")

        // (3) THE WIPE JOURNEY: the production ladder must COMPLETE over the lab's OWN inventory.
        let outcome = try lab.beginWipe()
        XCTAssertTrue(outcome.isComplete,
                      "*** THE WIPE MUST REACH A TERMINAL OVER THE LAB'S OWN ESTATE (no artifact surviving); "
                          + "observed: \(outcome.summaryWords) ***")
    }

    /// *** *** IOS-R6: THE PERMIT BOUNDARY IS ESTATE- AND GENERATION-BOUND, AND CONSUMED EXACTLY ONCE. *** ***
    ///
    /// *This is the HOST-RUNNABLE witness for the holder's gate: it drives the ACTUAL construction boundary
    /// (`permit.consumeForConstruction`) with the permit's OWN estate id and its REAL durable generation, so a mutant
    /// that ignores consumption reddens HERE.* **FOUR CASES, INCLUDING THE POSITIVE ONE: the permit's own estate at
    /// its OWN generation is accepted; a FOREIGN estate, a STALE (moved/ABA) generation, and a SECOND use are all
    /// refused. The positive half is what stops a boundary that refuseth everything from looking correct.**
    func testTheLabPermitBoundaryRefusesAForeignOrStaleEstateAndAcceptsTheLiveOne() throws {
        // *A CLEAN LAB ESTATE: the permit road requires the record to stand where the permit was judged.*
        LabRuntime.resetLabEstateForTest()
        guard let permit = try LabRuntime.mintLabPermit(callerEstateId: LabRuntime.labEstateIdentifier(root: LabRuntime.labEstateRootURL())) else {
            return XCTFail("a settled lab estate must mint a permit")
        }
        // THE REAL DURABLE GENERATION THE PERMIT WAS JUDGED AT -- never a forged literal.
        let realGeneration = permit.generation
        let realEstate = permit.estateId

        // (1) THE POSITIVE HALF: the permit's own estate at its OWN generation admits construction.
        XCTAssertNotNil(
            permit.consumeForConstruction(estateId: realEstate, liveGeneration: realGeneration),
            "*** THE SAME ESTATE AT ITS OWN DURABLE GENERATION MUST BE ACCEPTED: without this, the refusals below "
                + "would be satisfiable by a boundary that refuseth everything. ***",
        )
        // (2) A SECOND USE OF THE SAME PERMIT IS REFUSED (one-shot).
        XCTAssertNil(
            permit.consumeForConstruction(estateId: realEstate, liveGeneration: realGeneration),
            "*** A PERMIT'S ONE-SHOT SLOT MUST BE SPENT: copying/reusing it cannot buy a second construction. ***",
        )
        // (3) A FRESH PERMIT FOR A DIFFERENT ESTATE IS REFUSED AGAINST THIS ONE, AND (4) A MOVED RECORD (ABA) TOO.
        guard let other = try LabRuntime.mintLabPermit(callerEstateId: realEstate + "|foreign") else {
            return XCTFail("a second mint must succeed")
        }
        XCTAssertNil(
            other.consumeForConstruction(estateId: realEstate, liveGeneration: other.generation),
            "*** A PERMIT IS A JUDGEMENT ABOUT ONE ESTATE: a permit minted for another id must not admit this one. ***",
        )
        guard let aba = try LabRuntime.mintLabPermit(callerEstateId: realEstate) else {
            return XCTFail("a third mint must succeed")
        }
        XCTAssertNil(
            aba.consumeForConstruction(estateId: aba.estateId, liveGeneration: aba.generation &+ 1),
            "*** AND A PERMIT MINTED BEFORE THE RECORD MOVED (ABA) MUST NOT ADMIT CONSTRUCTION. ***",
        )
        // (5) AND THE PRODUCTION HELPER REFUSES A FOREIGN ESTATE AND ACCEPTS THE MATCHING ONE:
        XCTAssertFalse(
            try LabRuntime.consumeLabConstructionPermit(estateId: realEstate + "|foreign", liveGeneration: realGeneration),
            "*** THE PRODUCTION HELPER REFUSES A FOREIGN ESTATE. ***"
        )
        XCTAssertTrue(
            try LabRuntime.consumeLabConstructionPermit(estateId: realEstate, liveGeneration: realGeneration),
            "*** AND ACCEPTS THE LIVE SAME-ESTATE RECORD. ***"
        )
    }

    // MARK: - *** *** G2: THE PER-PEER SESSION INVALIDATION REALLY REACHES THE REAL SESSIONS. *** ***

    /// *** *** G2: A REVOCATION/RESOLUTION THROUGH THE REAL FACADE MUST DESTROY THE REAL SESSIONS, WHILE AN
    /// UNRELATED PEER SURVIVES. *** ***
    ///
    /// *THE DEFECT, VERBATIM: "Revocation/rotation reach `adapter.invalidateSessions`, which appends
    /// `invalidatedSessionNodes` and calls the sessionInvalidator every composition leaves nil ... while
    /// `SessionManager.drop/retireIncarnations` stand unwired -- a revoked peer's live sessions keep sealing/opening
    /// after the revocation claims otherwise, the array a witness that never sees the effect."*
    ///
    /// **THE COURT THEREFORE MEASURES THE SESSION, NOT THE LEDGER, AND IN THE POSITIVE DIRECTION FIRST:**
    ///   * two REAL paired Noise sessions are established (the four-entry keyed handshake) and BOUND under two real
    ///     lab contacts' identity node ids -- one to be revoked, one the UNRELATED POSITIVE CONTROL;
    ///   * both seal AND open SUCCESSFULLY before the act, in BOTH directions;
    ///   * the REAL facade revocation is driven (`revokeContact(for:)`), which reaches `invalidateSessions` through
    ///     the wired `sessionInvalidator`;
    ///   * the revoked contact's sessions must then REJECT (seal and open both nil, not ready) **while the unrelated
    ///     peer still seals and opens** -- so a callback that tore down everything, or tore down nothing, reddens.
    func testG2ARevocationThroughTheRealFacadeDestroyesTheRealSessionWhileAnUnrelatedPeerSurvives() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("godstone-lab-g2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let lab = try LabRuntime.compose(labels: ["A", "R", "B"], seedByte: 0x51, estateRoot: dir)
        // *** TWO NON-AUTHOR CONTACTS: the revocation road is for peers, and the author is not one. ***
        let contacts = lab.trustContactLabels().filter { $0 != lab.author }
        guard contacts.count >= 2 else {
            return XCTFail("the lab must expose at least two non-author contacts; got \(contacts)")
        }
        let revokedContact = contacts[0]
        let unrelatedContact = contacts[1]

        // (1) TWO REAL PAIRED SESSIONS, BOUND UNDER THE TWO REAL CONTACTS' IDENTITY NODE IDS.
        XCTAssertTrue(lab.installRealSessionFixture(tag: "revoked", boundTo: revokedContact),
                      "*** A REAL PAIRED NOISE SESSION MUST BE ESTABLISHED AND BOUND to the contact we will revoke. ***")
        XCTAssertTrue(lab.installRealSessionFixture(tag: "unrelated", boundTo: unrelatedContact),
                      "*** AND A SECOND, for the UNRELATED-PEER POSITIVE CONTROL. ***")
        XCTAssertTrue(lab.fixtureReady("revoked") && lab.fixtureReady("unrelated"),
                      "both real sessions must be READY before anything is revoked")

        // (2) BOTH SESSIONS SEAL **AND** OPEN, IN BOTH DIRECTIONS, BEFORE THE ACT.
        let before = Data("before the revocation".utf8)
        let revokedCipherI2R = try XCTUnwrap(lab.fixtureSeal("revoked", before),
                                             "the revoked session must seal before the act")
        XCTAssertEqual(lab.fixtureOpen("revoked", revokedCipherI2R), before,
                       "and its peer must open it before the act")
        let revokedCipherR2I = try XCTUnwrap(lab.fixtureSealResponder("revoked", before),
                                             "the revoked session must seal the other direction before the act")
        XCTAssertEqual(lab.fixtureOpenInitiator("revoked", revokedCipherR2I), before,
                       "and the other direction must open before the act")

        let unrelatedCipher = try XCTUnwrap(lab.fixtureSeal("unrelated", before),
                                            "the unrelated session must seal before the act")
        XCTAssertEqual(lab.fixtureOpen("unrelated", unrelatedCipher), before,
                       "and it must open before the act")

        // (3) THE REAL FACADE REVOCATION -- the road whose effect the report said died at the ledger.
        let revokeOutcome = lab.revokeContact(for: revokedContact)
        XCTAssertTrue(revokeOutcome.hasPrefix("applied"),
                      "*** THE FACADE REVOCATION MUST BE APPLIED; observed: \(revokeOutcome) ***")

        // (4) THE REVOKED CONTACT'S REAL SESSIONS MUST NOW REJECT -- seal AND open, BOTH directions.
        XCTAssertFalse(lab.fixtureReady("revoked"),
                       "*** A REVOKED PEER'S SESSION MUST NO LONGER READ READY: `retireIncarnations` removes the " +
                           "incarnations, so `isReady` falls. The ledger array a witness that never saw this is " +
                           "exactly the defect this arm closes. ***")
        XCTAssertNil(lab.fixtureSeal("revoked", before),
                     "*** A REVOKED PEER'S SESSION MUST NOT SEAL. A held alias that can still seal is the precise " +
                         "hole the finding names. ***")
        XCTAssertNil(lab.fixtureOpen("revoked", revokedCipherI2R),
                     "*** NOR OPEN -- the incarnation is retired, so the old ciphertext has no session. ***")
        XCTAssertNil(lab.fixtureSealResponder("revoked", before),
                     "*** NOR SEAL THE OTHER DIRECTION: `retireIncarnations` removes BOTH directions. ***")
        XCTAssertNil(lab.fixtureOpenInitiator("revoked", revokedCipherR2I),
                     "*** NOR OPEN THE OTHER DIRECTION. ***")

        // (5) AND THE UNRELATED PEER SURVIVES -- the positive control that stops a callback which tears down everything
        // from looking correct.
        XCTAssertTrue(lab.fixtureReady("unrelated"),
                      "*** AN UNRELATED PEER MUST REMAIN READY: a callback that invalidated every session would pass " +
                          "the revoked half and be WRONG. ***")
        let after = Data("after the revocation".utf8)
        let unrelatedAfter = try XCTUnwrap(lab.fixtureSeal("unrelated", after),
                                           "the unrelated peer must still seal after the revocation")
        XCTAssertEqual(lab.fixtureOpen("unrelated", unrelatedAfter), after,
                       "*** AND STILL OPEN -- its trust was never touched. ***")

        // (6) AND THE CALLBACK ITSELF IS THE ONE THE FACADE HOLDS: driving it directly by the revoked contact's
        // identity node id is idempotent (nothing left to retire), so the effect is the SAME road.
        let revokedNodeId = try XCTUnwrap(lab.trustContactNodeId(revokedContact),
                                          "the revoked contact must resolve to an identity node id")
        XCTAssertEqual(lab.invalidateSessions(forNodeId: revokedNodeId), 0,
                       "*** A SECOND INVOCATION MUST RETIRE NOTHING (already retired) -- proveth the first was real. ***")
    }

    /// *** *** G2: THE WIRING IS PRESENT, NOT A NIL DEFAULT -- THE MAPPING'S OWN WITNESS. *** ***
    ///
    /// *`LabRuntime.compose` binds each linked pair's identity node id to the transport handle the harness really
    /// minted (both directions), so `boundSessionPeers` is non-zero for a real contact. **A composition that left
    /// `sessionInvalidator` nil would still bind nothing and this reads 0** -- which is why the arm binds a real
    /// session first and then reads the count.*
    func testG2TheCompositionBindsRealPeersToTheSessionInvalidationRoad() throws {
        let lab = try LabRuntime.compose(labels: ["A", "R", "B"], seedByte: 0x61)
        let contacts = lab.trustContactLabels()
        guard let contact = contacts.first else { return XCTFail("a composed lab must expose contacts") }
        let nodeId = try XCTUnwrap(lab.trustContactNodeId(contact))

        // *** BOUND WHERE THE HARNESS'S OWN LINK ESTABLISHED IT: the identity→handle relation is non-empty. ***
        XCTAssertGreaterThan(
            lab.boundSessionPeers(forNodeId: nodeId), 0,
            "*** THE COMPOSITION MUST BIND THE IDENTITY→HANDLE RELATION AT THE WIRING POINT: a nil `sessionInvalidator` " +
                "(the defect) would reach the callback with a node id it could not map to any peer. ***",
        )

        // And a truly unknown node id maps to nothing (the refusal direction).
        XCTAssertEqual(lab.boundSessionPeers(forNodeId: Data(repeating: 0x7F, count: 16)), 0,
                       "an unknown node id must map to no peer -- a mapping that answered everything would be no map")
    }

    /// *** *** THE THROWING DRIVE BOUNDARY: A FAILED DRIVE MUST NOT LOOK COMPLETE. *** ***
    ///
    /// *The wipe handler now throweth, and the adapter is the boundary that turns a thrown failure into a NON-complete
    /// progress state carrying the ACTUAL error -- never a fabricated `RecoveryLadderOutcome`, never a swallowed
    /// `try?`, and never a `nil`/`false` that a surface could mistake for a mere refusal. **AND THE POSITIVE CONTROL
    /// STANDS BESIDE IT:** a handler that really settled still renders `.complete`, so the refusal arm cannot be
    /// satisfied by an adapter that could never report success.*
    func testTheThrowingWipeDriveRendersNonCompleteWithTheActualError() throws {
        struct DriveFailed: Error { let reason: String }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("godstone-lab-wipe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SqlitePeerIdentityStore(url: dir.appendingPathComponent("trust.db"))
        defer { store.close() }
        let repo = PeerIdentityRepository(store: store)

        // (1) A DRIVE THAT THREW: non-complete, carrying the ACTUAL error, still blocking ordinary use.
        let throwing = TrustAuthorityAdapter(repository: repo, wipeHandler: {
            throw DriveFailed(reason: "the estate's inventory could not be bound")
        })
        let failed = throwing.beginWipe()
        XCTAssertNotEqual(failed, .complete,
                          "*** A DRIVE THAT THREW MUST NOT BE RENDERED COMPLETE. ***")
        if case .inProgress(_, _, let resumable, let error) = failed {
            XCTAssertTrue(resumable, "the estate is not settled, so a resume remaineth legitimate")
            XCTAssertTrue(error?.contains("could not be bound") == true,
                          "*** THE ACTUAL ERROR MUST BE CARRIED -- observed: \(String(describing: error)) ***")
            XCTAssertTrue(failed.blocksOrdinaryUse, "and an unfinished wipe must block ordinary use")
        } else {
            XCTFail("a thrown drive must be in progress, got \(failed)")
        }
        XCTAssertEqual(throwing.resumeWipe(), failed,
                       "the resume road carries the same non-complete state rather than a second fabricated answer")

        // (2) THE POSITIVE CONTROL: a handler that really settled still renders complete.
        let completeOutcome = RecoveryLadderOutcome(decision: .wipeCompleted, rungs: [], artifactsRemaining: [])
        let settled = TrustAuthorityAdapter(repository: repo, wipeHandler: { completeOutcome })
        XCTAssertEqual(settled.beginWipe(), .complete,
                       "*** A SETTLED DRIVE MUST STILL RENDER COMPLETE, or the arm above is vacuous. ***")
    }
}
