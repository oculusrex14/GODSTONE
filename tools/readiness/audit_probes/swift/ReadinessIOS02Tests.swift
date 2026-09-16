// IOS-02 -- THE ADAPTER MUST BEGIN THE TRUSTED HANDSHAKE ITSELF: the behavioural arms, PARKED.
//
// WHY THESE ARMS LIVE OUTSIDE THE PACKAGE. They are RED BY DESIGN on this tree, and the iOS lane
// (`swift test --package-path ios/Packages/GodstoneFoundation`) must never be red -- the same rule the
// python probes follow, and the reason the Kotlin probe liveth outside its Gradle source sets. WHEN THE
// REPAIR LANDETH, THESE ARMS MOVE INTO
// `ios/Godstone/Tests/GodstoneMeshTests/ReadinessT22Tests.swift` (the canonical subsystem suite), and
// this file disappears.
//
// WHAT WAS MEASURED IN ROUND 281 (nothing here is inferred):
//
//   * THE CLAIM IS EXACTLY TRUE: `beginTrustedHandshake(` appeareth ONCE in the canonical Sources --
//     its declaration at `GodstoneMesh/BleTransport.swift:2294` -- and `beginKeyConfirmation(` ONCE,
//     at `:2575`. NOTHING IN PRODUCTION CALLETH EITHER. The audit's words hold: "the application never
//     starts D2 or key confirmation".
//   * THE RED WAS TAKEN: with these arms in the canonical suite, the T22 suite ran 15 tests with
//     EXACTLY 2 FAILURES -- these arms -- each with the words "THE ADAPTER NEVER BEGAN THE TRUSTED
//     HANDSHAKE upon the witnessed duplex: no HS1 went out", AND AN EMPTY REJECTION RING, because
//     nothing had even attempted the begin. The other 13 arms passed, so the rig is sound and the
//     RED is not a rig failure.
//   * THE REPAIR WAS WRITTEN AND IT WORKETH: in the physical-duplex reduction
//     (`reductionProcessPeripheralNotificationStateUpdated`, the `.physicalDuplexReady` branch) the
//     transport now readeth the relation's captured remote hint from the driver's election context and
//     calleth `beginTrustedHandshake`, ONCE, and only from `.roleBound` (the card's no-second-slot
//     clause). WITH IT, THE T22 SUITE RAN 16 TESTS, 0 FAILURES -- these arms GREEN, plus a third that
//     witnesseth the card's "do not repeat beginInitiator" law, because the ring nameth it:
//     `hs.begin|begin initiator refused`.
//   * AND ITS BLAST RADIUS WAS MEASURED, NOT GUESSED: the FULL iOS lane ran 1208 tests with 61
//     failures -- ReadinessT23 30, ReadinessT21 26, ReadinessT17 3, ReadinessT19 1, ReadinessT14 1 --
//     every one of them a rig that BEGINNETH THE HANDSHAKE BY HAND after the adapter already had, and
//     is therefore REFUSED (`hs.begin|begin initiator refused`) with its HS1 cleared away by
//     `capturePeer.clearWrites()`. THE PRODUCTION LAW IS NOT BROKEN; THE RIGS ENCODE THE OLD ONE.
//   * THE WHOLE CHANGE IS PRESERVED AS A RE-APPLIABLE PATCH:
//     `.../REMEDIATION/IOS-02/round281-the-repair-and-the-arms.patch`
//     (sha256 4fe85c5e0ad28b0c...), so the next round re-applieth it rather than re-deriving it.
//
// WHAT THE NEXT ROUND MUST DO -- ARM BY ARM, ATOMICALLY, BECAUSE A LANE MAY NOT BE LEFT RED:
//
//   1. APPLY THE PATCH. `ReadinessT22Tests` is already reconciled in it (`driveToReady` and
//      `driveToAnswered` REAP the adapter's HS1 instead of beginning by hand, and `t22Hs1` readeth the
//      counsel's PAYLOAD off the wire, since its callers re-forge it).
//   2. RECONCILE THE OTHER FIVE SUITES' RIGS THE SAME WAY: `beginWith` (T21) and `beginOn` (T23) are
//      each called from ~10 arms; the drive helpers must stop clearing writes and stop beginning.
//   3. **AND THE HARD PART, WHICH IS WHY THIS IS NOT MECHANICAL: T21 AND T23 CARRY *GUARD-LAW* ARMS
//      WHOSE PRECONDITIONS CAN NO LONGER BE ARRANGED AFTER RIG CONSTRUCTION, because the adapter
//      beginneth during construction.** `testTheBeginIsRefusedWhileTheDuplexLiesUnwitnessed` setteth
//      `conn.maxAttValueLength = 10` AFTER `rigT21()` hath already witnessed the duplex and begun the
//      exchange; the arm then expecteth `state == .roleBound` and `slotForTest == nil`, which the
//      adapter's begin hath already made false. The enabling idea, so the next round need not
//      rediscover it: **give the rigs a variant that stoppeth BEFORE the notification reduction** --
//      i.e. `advanceToRoleBound(..., subscribeth: false)` -- so a guard-law arm can arrange its
//      precondition and THEN witness the transport's own entry. Arms that witness a refusal
//      (`testTheBeginIsRefusedWhenTheHintsDescendOrMeet`) additionally need their expected ring count
//      raised by one, because THE ADAPTER'S OWN ATTEMPT NOW RINGETH TOO -- which is a STRONGER
//      witness, not a weaker one.
//   4. RUN THE FULL iOS LANE, and only then move these three arms into the canonical suite.
//
// THE ARMS, EXACTLY AS THEY RAN (they use the helpers of `ReadinessT22Tests`: `rigT22`, `ringOf`,
// `waitWhile`, `beginWith`; and the two helpers added beside them: `records`, `firstRecord`):

/*
    private func records(_ r: T22Rig, ofType type: BleRecordType) -> [Data] {
        return r.capturePeer.writes.filter { written in
            guard let frag = BleRecordCodec.decodeFragment(written) else { return false }
            return frag.header.recordType == type
        }
    }

    private func firstRecord(_ r: T22Rig, ofType type: BleRecordType) -> Data? {
        return records(r, ofType: type).first
    }

    func testTheAdapterItselfBeginnethTheTrustedHandshakeOnTheWitnessedDuplex() throws {
        let r = try rigT22()
        guard let hs1 = waitWhile({ self.firstRecord(r, ofType: .hs1) }, nonEmpty: true) else {
            XCTFail("THE ADAPTER NEVER BEGAN THE TRUSTED HANDSHAKE upon the witnessed duplex: no HS1 went out, "
                + "though the relation was ROLE_BOUND, the duplex was witnessed by the real notification "
                + "reduction, and the local hint is ascendant. IOS-02: the application never starts D2 or key "
                + "confirmation. ring: " + ringOf(r.alice))
            return
        }
        XCTAssertFalse(hs1.isEmpty, "the first counsel must carry a body")
        XCTAssertEqual(records(r, ofType: .hs1).count, 1,
                       "the adapter must begin the exchange exactly ONCE: ring: " + ringOf(r.alice))
        XCTAssertEqual(r.alice.connection(for: r.handleB)?.state, .handshakeInProgress,
                       "the relation must be IN the trusted handshake once the adapter began it")
        // AND A THING I ASSERTED FROM READING THE CODE, WHICH THE MEASUREMENT REFUTED: I wrote that the
        // stage must be `.hsOut` (the line that setteth it after the first counsel). MEASURED: it is
        // `.hsIn` -- the relation hath SENT its first and awaiteth the responsive second. The assertion
        // is withdrawn rather than bent: THE LAW THIS ARM WITNESSETH IS THE BEGIN, NOT THE INTERNAL NAME
        // OF THE HOUR.
    }

    func testADuplicateNotificationReductionBeginnethNoSecondHandshake() throws {
        let r = try rigT22()
        guard let first = waitWhile({ self.firstRecord(r, ofType: .hs1) }, nonEmpty: true) else {
            XCTFail("no HS1 stood to be duplicated: the adapter never began the handshake. ring: " + ringOf(r.alice))
            return
        }
        let inboxChar = NotifyingInboxCharacteristic(
            type: BleTransport.inboxCharacteristicUuid,
            properties: [.read, .write, .notify], value: nil, permissions: [.readable, .writeable])
        _ = r.alice.processPeripheralNotificationStateUpdated(nil, delegate: r.aliceDelegate,
                                                             characteristic: inboxChar, error: nil)
        _ = r.alice.processPeripheralNotificationStateUpdated(nil, delegate: r.aliceDelegate,
                                                             characteristic: inboxChar, error: nil)
        XCTAssertEqual(records(r, ofType: .hs1).count, 1,
                       "A DUPLICATE NOTIFICATION REDUCTION BEGAN THE HANDSHAKE AGAIN (the card forbiddeth a "
                       + "second SessionSlot or a repeated beginInitiator). ring: " + ringOf(r.alice))
        XCTAssertEqual(records(r, ofType: .hs1).first, first, "the first counsel must be the one already sent")
    }

    func testASecondBeginUponTheSameRelationIsRefused() throws {
        let r = try rigT22()
        guard waitWhile({ self.firstRecord(r, ofType: .hs1) }, nonEmpty: true) != nil else {
            XCTFail("the adapter never began the handshake, so no second begin can be witnessed. ring: "
                + ringOf(r.alice)); return
        }
        XCTAssertEqual(beginWith(r, r.pair.bobIdentity.nodeHint), .rejected("begin initiator refused"),
                       "a second begin upon a relation ALREADY IN handshake must be refused -- a relation "
                       + "is not re-opened by a repeated call. ring: " + ringOf(r.alice))
        XCTAssertEqual(records(r, ofType: .hs1).count, 1,
                       "and the refused begin must put NO second counsel on the wire")
    }
*/

// THE PRODUCTION REPAIR, as it stood (the patch carrieth it verbatim):
//
//   case .physicalDuplexReady:
//       let relationHint = snapshotCentral?.getElectionContext(peerId)?.remoteNodeHint
//       lockTransport()
//       cancelTimerLocked(matching: delegate.relationKey)
//       let mayBegin = outboundCentralConnections[peerId]?.state == .roleBound
//       unlockTransport()
//       publishRelation(delegate.relationKey)
//       if mayBegin, let relationHint = relationHint {
//           _ = beginTrustedHandshake(peerId: peerId, remoteHint: relationHint)
//       }
//
// NOTICE WHAT IT DOTH NOT DO: it doth not remove `publishRelation`. That call publisheth the PHYSICAL
// relation (`transportPhysicalDuplexReady`) and is a DIFFERENT concern from the authenticated
// readiness of the card's fifth step; removing it would be a repair breaking its neighbour.
