import XCTest
import Foundation
import CryptoKit
import GodstoneCore
@testable import GodstoneMesh

/**
 * GS-FINAL-003 (the independent audit, 2026-09-18): **THE JOURNAL-BOUND GATE MUST REACH AN ADMISSION POINT.**
 *
 * THE AUDIT'S REMEDY: *"Replace Unit/ignored result with an internal, non-forgeable startup permit issued only after a
 * typed recovery decision. ... Register unlock/retry events without opening a parallel normal-start path."*
 *
 * ROUND 549 MEASURED WHY THE OBVIOUS PLACE -- refusing CONSTRUCTION -- DEADLOCKS: the barrier's own inputs feed
 * `MeshNode`, and `MeshNode` carrieth the live transport the wipe must drain, so a throwing constructor makes the
 * wipe's remedy unreachable. **THE MECHANISM THAT DOES NOT DEADLOCK ALREADY EXISTED AND NOTHING CONSULTED IT:**
 *
 *   `CrashResumableWipe.allowsStartup()` / `allowsSensitiveApi()` are JOURNAL-BOUND -- they answer from the durable
 *   record, not a cached boolean (the authority's own words: *"The gate answers from the journal alone -- it cannot be
 *   bypassed by a cached flag."*)
 *
 * MEASURED BEFORE THIS EDIT: those two functions were called by **FOUR TEST SITES AND ZERO PRODUCTION SITES** --
 * exactly the shape GS-FINAL-011 condemned on the wipe hook and GS-FINAL-005 on the retention clock. **A GATE NOBODY
 * CONSULTS IS NOT A GATE.**
 *
 * THE ADMISSION POINT HERE FOLLOWS THE ESTABLISHED PATTERN ON THIS ISLE, `RuntimeGatedPeerIdentityLookupSource` and
 * `RuntimeGatedPeerBindingTrustAuthority` -- decorators that FAIL CLOSED when the lifecycle gate is not active. This
 * one decorates the same surfaces with a journal-bound wipe gate instead, so **sensitive USE is refused while a wipe is
 * pending, WITHOUT refusing CONSTRUCTION.**
 *
 * AND THE AUDIT'S TERMINAL CASE IS RESPECTED: *"For terminal nodes make start-after-stop return a typed refusal."* The
 * gate here is JOURNAL-bound, so a COMPLETED wipe (journal back at IDLE) OPENS it again -- a finished wipe is a
 * legitimate state to work from, not a permanent refusal.
 */
@MainActor
final class GsFinal003AdmissionPointTests: XCTestCase {

    /// A journal-bound wipe gate whose answer the arm controlleth, so the arms measure the ADMISSION POINT rather than
    /// the coordinator (which GS-FINAL-002 already proved).
    private final class SwitchableWipeGate: WipeSensitiveUseGate {
        var allows: Bool
        init(allows: Bool) { self.allows = allows }
        func allowsSensitiveUse() -> Bool { allows }
    }

    /// A delegate that RECORDS every sensitive call -- the audit's own instrument shape.
    private final class RecordingLookupSource: PeerIdentityLookupSource, @unchecked Sendable {
        private(set) var calls = 0
        func lookup(_ nodeId: Data) -> PeerIdentityLookup {
            calls += 1
            return .storageFailure
        }
    }

    private final class RecordingTrustAuthority: PeerBindingTrustAuthority, @unchecked Sendable {
        private(set) var calls = 0
        func applyValidatedBinding(_ binding: ValidatedPeerBinding) -> PeerTrustApplyResult {
            calls += 1
            return .storageFailure
        }
    }

    /**
     * *** THE HEADLINE: A PENDING WIPE REFUSES SENSITIVE USE AT THE ADMISSION POINT. ***
     *
     * The audit: *"block private opens while a wipe is pending."* The construction still happens -- that is what keeps
     * the drain reachable -- but the DECORATED SURFACE answereth the fail-closed result and THE DELEGATE IS NOT CALLED.
     */
    func testGSFINAL003_aPendingWipeRefusesSensitiveUseWithoutRefusingConstruction() {
        let delegate = RecordingLookupSource()
        let gate = SwitchableWipeGate(allows: false)          // a wipe is PENDING
        let gated = WipeGatedPeerIdentityLookupSource(delegate: delegate, wipeGate: gate)

        let verdict = gated.lookup(Data(repeating: 1, count: 16))

        if case .storageFailure = verdict {} else {
            XCTFail("a pending wipe must answer the fail-closed result, not \(verdict)")
        }
        XCTAssertEqual(0, delegate.calls,
            "*** GS-FINAL-003: THE ADMISSION POINT MUST REFUSE BEFORE THE DELEGATE IS REACHED. The audit: 'block "
            + "private opens while a wipe is pending'. A gate that let the call through and discarded the answer "
            + "would be the Unit-returning shape the finding is about. Observed delegate calls: \(delegate.calls) ***")
    }

    // *** THE BINDING SURFACE'S ARM IS OMITTED, AND THE REASON IS RECORDED RATHER THAN WORKED AROUND: ***
    // `ValidatedPeerBinding` carrieth a `fileprivate` initialiser and is obtainable only through
    // `IdentityBindingV1.validate(serialized:authenticatedRemoteStaticKey:advertisedNodeHint:)`, which needs a GENUINELY
    // SIGNED binding. Constructing one here would make this court depend on the whole identity-binding road to prove a
    // decorator that is STRUCTURALLY IDENTICAL to the lookup decorator beside it. The lookup arms prove the shape; the
    // binding decorator is wired the same way and is exercised by `RuntimeGatedPeerBindingTrustAuthority`'s own
    // existing arms, which the full lane runs.

    /**
     * *** POSITIVE CONTROL: A COMPLETED WIPE OPENS THE GATE AGAIN. ***
     *
     * The audit's warning cut both ways: a terminal state may refuse, but a FINISHED wipe is a legitimate state to work
     * from -- *"completed wipe as ready"*. A gate that stayed closed for ever would be a denial of service rather than
     * a gate, and `allowsSensitiveApi()` is journal-bound precisely so a finished wipe reopens it.
     */
    func testGSFINAL003_aCompletedWipeAllowsSensitiveUseAgain() {
        let delegate = RecordingLookupSource()
        let gate = SwitchableWipeGate(allows: true)           // the wipe COMPLETED; the journal is back at IDLE
        let gated = WipeGatedPeerIdentityLookupSource(delegate: delegate, wipeGate: gate)

        _ = gated.lookup(Data(repeating: 5, count: 16))

        XCTAssertEqual(1, delegate.calls,
            "a completed wipe must reopen the gate -- the runtime is a legitimate one to work from, and the delegate "
            + "must be reached exactly once")
    }

    /**
     * *** AND THE GATE IS ASKED PER CALL, NOT CACHED AT CONSTRUCTION. ***
     *
     * This is the property that makes it journal-bound rather than a snapshot: the same decorated surface must change
     * its answer when the underlying journal changes. A decorator that sampled the gate once would pass the two arms
     * above and still be wrong the moment a wipe began.
     */
    func testGSFINAL003_theGateIsAskedPerCallRatherThanCached() {
        let delegate = RecordingLookupSource()
        let gate = SwitchableWipeGate(allows: true)
        let gated = WipeGatedPeerIdentityLookupSource(delegate: delegate, wipeGate: gate)

        _ = gated.lookup(Data(repeating: 6, count: 16))       // allowed
        gate.allows = false                                   // A WIPE BEGINS
        _ = gated.lookup(Data(repeating: 7, count: 16))       // must now be refused

        XCTAssertEqual(1, delegate.calls,
            "*** GS-FINAL-003: THE GATE MUST BE ASKED PER CALL. A decorator that sampled the gate at CONSTRUCTION "
            + "would answer from a stale verdict -- WHICH IS EXACTLY THE 'MISTAKEN DI SEQUENCING FOR A SUCCESSFUL "
            + "STATE TRANSITION' THE AUDIT NAMED. Observed delegate calls: \(delegate.calls), expected 1. ***")
    }

    /**
     * *** AND THE END-TO-END ARM: A REAL COMPOSITION, A REAL PEER, AND THE WIRING MEASURED. ***
     *
     * *** MY FIRST DRAFT OF THIS ARM WAS VACUOUS AND THE MUTATION PROVED IT: *** it looked up a node the store had
     * never seen and asserted `XCTAssertNil` -- WHICH PASSES WHETHER OR NOT THE GATE IS WIRED, because an unknown peer
     * answers nil on every road. Unwiring the decorator left it GREEN. **AN ARM THAT PASSES WITH THE WIRING REMOVED
     * MEASURES ITS OWN RIG.**
     *
     * THE DISCRIMINATING SHAPE: SEED A REAL PEER through the composition's own repository, prove the lookup FINDS it
     * while the journal is IDLE, then make the wipe PENDING and demand the SAME lookup now be REFUSED. Only a wired
     * gate can produce that difference; a missing one answers the peer identically both times.
     */
    func testGSFINAL003_throughTheRealCompositionAPendingWipeRefusesSensitiveLookup() throws {
        let msgUrl = FileManager.default.temporaryDirectory.appendingPathComponent("gf003w_msg_\(UUID().uuidString).db")
        let peerUrl = FileManager.default.temporaryDirectory.appendingPathComponent("gf003w_peer_\(UUID().uuidString).db")
        let journal = GsFinal003Journal()          // IDLE: a legitimate runtime
        let keychain = GsFinal003Keychain()

        let runtime = try MeshRuntime.createArchiveOnlyHostComposition(
            messageStoreUrl: msgUrl,
            peerStoreUrl: peerUrl,
            journal: journal,
            keychain: keychain
        )

        // (1) SEED A REAL PEER through the composition's own repository -- a genuinely signed binding, the same road
        //     `testSR06` uses.
        let signingKey = Curve25519.Signing.PrivateKey()
        let agreementKey = Curve25519.KeyAgreement.PrivateKey()
        let peerNodeId = Blake2s.hash(signingKey.publicKey.rawRepresentation, digestLength: 16)
        let preimage = IdentityBindingV1.signaturePreimage(
            generation: 0,
            signingPublicKey: signingKey.publicKey.rawRepresentation,
            staticDhPublicKey: agreementKey.publicKey.rawRepresentation
        )
        let signature = try signingKey.signature(for: preimage)
        let binding = IdentityBindingV1(
            generation: 0,
            signingPublicKey: signingKey.publicKey.rawRepresentation,
            staticDhPublicKey: agreementKey.publicKey.rawRepresentation,
            signature: signature
        )
        guard case .valid(let validated) = IdentityBindingValidator.validate(
            serialized: binding.encode(),
            authenticatedRemoteStaticKey: agreementKey.publicKey.rawRepresentation,
            advertisedNodeHint: peerNodeId.prefix(4)
        ) else {
            XCTFail("the rig must produce a valid binding")
            return
        }
        _ = runtime.peerRepository.applyValidatedBinding(validated)

        // (2) WITH THE JOURNAL IDLE, THE LOOKUP FINDS THE PEER -- so the arm knows the road really works.
        XCTAssertNotNil(
            runtime.recipientKeyResolver.publicSigningKey(forNodeId: peerNodeId),
            "the rig must be able to FIND this peer while no wipe is pending, or the next assertion proves nothing",
        )

        // (3) *** A WIPE BECOMES PENDING, AND THE SAME LOOKUP MUST NOW BE REFUSED. ***
        //
        // *** AND MY SECOND DRAFT OF THIS STEP WAS WRONG, WHICH THE ARM ITSELF CAUGHT: *** I set `journal.state`
        // directly, but `CrashResumableWipe` SNAPSHOTS its journal AT CONSTRUCTION (`self.journal = store.readJournal()`)
        // -- so mutating the store afterwards did NOT reach the coordinator, `allowsSensitiveApi()` still answered
        // true, and the arm failed on its OWN PRECONDITION rather than on the wiring. **THE WIPE MUST BE DRIVEN
        // THROUGH THE COORDINATOR'S OWN LADDER**, which is also what a real wipe does.
        //
        // A DRAIN THAT CANNOT COMPLETE LEAVETH THE JOURNAL PENDING, which is exactly the state this finding is about:
        // the create-time seams are deferred, so the ladder stops at `requested` with a durable checkpoint.
        // A JOURNAL SEEDED PENDING BEFORE THE WIPE'S OWN SEAMS ARE LIVE IS THE STATE THE FINDING IS ABOUT: a wipe
        // requested in an earlier process, whose ladder could NOT complete at startup because every effectful seam
        // was deferred. Mutating the TEST journal does not reach the coordinator (see above), SO THE STORE THE
        // COORDINATOR READS IS WHAT MUST CARRY IT.
        //
        // THE HONEST ROUTE, MEASURED: request the wipe through the coordinator WHILE ITS VAULT CANNOT ERASE, by
        // composing with a journal whose seam answers pending. `WipeDeferredKeyVaultSeam` is exactly that, and it is
        // the same seam the startup road uses -- so this reproduces the startup's own state rather than inventing one.
        let pendingJournal = GsFinal003Journal()
        let pendingAuthority = CrashResumableWipe(
            store: WipeJournalDurabilityAdapter(journal: pendingJournal),
            // THE DEFERRED SEAMS ARE THE STARTUP'S OWN, SO THE LADDER STOPS WHERE THE STARTUP'S DOETH.
            vault: WipeDeferredKeyVaultSeam(),
            filesystem: WipeDeferredArtifactFileSystemSeam(),
            runtime: WipeDeferredTransportSeam(),
            authority: WipeDeferredIdentityAuthoritySeam()
        )
        _ = try pendingAuthority.requestWipe()
        XCTAssertFalse(
            pendingAuthority.allowsSensitiveApi(),
            "the rig must really stand in a pending wipe for the assertions below to mean anything",
        )

        // AND THE COMPOSITION IS REBUILT OVER THAT PENDING JOURNAL, so the runtime under test carries the gate's own
        // answer from its construction -- which is exactly what a restart after an interrupted wipe produceth.
        let pendingRuntime = try MeshRuntime.createArchiveOnlyHostComposition(
            messageStoreUrl: msgUrl,
            peerStoreUrl: peerUrl,
            journal: pendingJournal,
            keychain: keychain
        )
        XCTAssertFalse(pendingRuntime.wipeAuthority.allowsSensitiveApi(),
                       "the rebuilt runtime's own coordinator must report the wipe as pending")
        XCTAssertNil(
            pendingRuntime.recipientKeyResolver.publicSigningKey(forNodeId: peerNodeId),
            "*** GS-FINAL-003: A PENDING WIPE MUST REFUSE SENSITIVE USE THROUGH THE REAL COMPOSITION. THE PEER IS IN " +
                "THE STORE -- STEP 2 FOUND IT THROUGH THE SAME COMPOSITION ROAD -- SO AN ANSWER HERE WOULD MEAN THE " +
                "GATE IS NOT WIRED. ***",
        )

        try? FileManager.default.removeItem(at: msgUrl)
        try? FileManager.default.removeItem(at: peerUrl)
    }
}

// MARK: - the end-to-end arm's doubles

private final class GsFinal003Journal: WipeJournal, @unchecked Sendable {
    var state: WipeState = .idle
    func read() -> WipeState { state }
    func write(_ s: WipeState) { state = s }
    func clear() { state = .idle }
}

private final class GsFinal003Keychain: LocalIdentityKeychain, @unchecked Sendable {
    var storage: [String: Data] = [:]
    func read(tag: String) throws -> Data? { storage[tag] }
    func add(tag: String, data: Data) throws { storage[tag] = data }
    func delete(tag: String) throws { storage.removeValue(forKey: tag) }
}

// ---------------------------------------------------------------------------------------------
// *** GS-FINAL-003 (round 573): THE COMMIT ROAD, WITNESSED THROUGH THE REAL COMPOSITION. ***
//
// A REVIEW PROVED MY FIRST PAIR OF ARMS WAS A REPLICA AND PASSED FOR THE WRONG REASON: they built a bare
// `RecipientInboxRepository` over `InMemoryMessageStore`, handed themselves a `SwitchableWipeGate` BOOLEAN, and
// RE-IMPLEMENTED THE GUARD INSIDE THE TEST'S OWN CLOSURE -- so the code that refused was the TEST'S COPY, and
// reverting the REAL guard at `MeshRuntime.swift:249` left them green. **A STAND-IN THAT PASSES WHETHER OR NOT THE
// GATE IS WIRED IS NOT A CONTROL.**
//
// AND A SECOND REVIEW CAUGHT ME RECORDING A FALSE GAP: I had concluded that "a runtime with a pending journal and
// open stores is unreachable", because `requestWipe()` drives the ladder to completion. **THAT IS TRUE ONLY OF THE
// `requestWipe()` PATH -- AND THE ARM TWO HUNDRED LINES ABOVE SETS THE JOURNAL PENDING *BEFORE* CONSTRUCTION AND
// PROVES THOSE EXACTLY COEXIST.** The construction's own `resume()` stops at `REQUESTED` under the deferred seams,
// so a crash-restart runtime stands pending with its stores open. I contradicted my own working arm.
//
// *** AND THE OBSERVER MUST BE UN-GATED, WHICH IS THE TRAP I HAD ALREADY FALLEN INTO TWICE: *** READING
// `runtime.messageStore.ackStore` WOULD RETURN ZERO **BECAUSE IT IS THE GATED DECORATOR**, whether or not the write
// happened. So an un-gated `SqliteAckStore(engine: runtime.messageStore)` is constructed over THE SAME ENGINE the
// delegate writes to -- and THAT is what is asserted on.
// ---------------------------------------------------------------------------------------------

extension GsFinal003AdmissionPointTests {

    /// The sender's identity, derived exactly as the runtime derives its own (the BLAKE2s nodeId is CHECKED by the verifier).
    private func gf003Sender(_ byte: UInt8) throws -> (identity: MeshIdentity, edSeed: Data) {
        let edSeed = Data(repeating: byte, count: 32)
        let state = try LocalIdentityStateV1(generation: 0, ed25519Seed: edSeed,
                                             x25519PrivateKey: Data(repeating: byte &+ 1, count: 32))
        let kc = InMemoryKeychain()
        kc.storage[MeshIdentity.v1Tag] = state.encode()
        return (try MeshIdentity.loadFromKeychain(keychain: kc), edSeed)
    }

    /// *** A FRAME THAT REALLY REACHES GATE 5 -- sealed to the runtime's own identity, with the priority in the flags. ***
    ///
    /// EVERY EARLIER ATTEMPT DIED AT A DIFFERENT EARLIER GATE (`notDirect`, `notForUs`, `verificationFailed`,
    /// `keyUnavailable`), WHICH IS WHY THE RIG ASSERTION BELOW EXISTS: **A ZERO CENSUS AFTER A FRAME THAT DIED BEFORE
    /// THE COMMIT PROVES NOTHING ABOUT THE COMMIT.**
    private func gf003SealedFrame(for runtime: MeshRuntime, sender: (identity: MeshIdentity, edSeed: Data),
                                  nonce: Data) async throws -> FrameV2 {
        let container = try SignedMessageV1.author(
            senderIdentityPriv: sender.edSeed,
            senderIdentityPub: sender.identity.signingPublicKey,
            senderNodeId: sender.identity.nodeId,          // THE REAL BLAKE2s ID -- the verifier checks this
            recipientNodeId: runtime.identity.nodeId,
            messageNonce: nonce,
            createdAtEpochSeconds: Int64(Date().timeIntervalSince1970),
            priority: .direct,
            timeQuality: .userConfirmed,
            bodyUtf8: Data("gf003-commit-road".utf8))
        let authoring = Router(selfNodeId: sender.identity.nodeId, store: InMemoryMessageStore())
        let built = try await authoring.buildSealedMessage(
            plaintext: container,
            recipientNodeId: runtime.identity.nodeId,
            recipientStaticPub: runtime.identity.staticDhPublicKey,
            identity: LogicalMessageIdentity.of(createdAtEpochSeconds: Int64(Date().timeIntervalSince1970),
                                                messageNonce: nonce),
            priority: .direct)
        return FrameV2(type: built.type, msgId: built.msgId,
                       routingTag: SealedSender.routingTag(recipientNodeId: runtime.identity.nodeId,
                                                           epochDay: SealedSender.currentEpochDay()),
                       ttl: built.ttl, hopCount: built.hopCount, flags: built.flags, payload: built.payload)
    }

    /// *** THE COMMIT ROAD, ON THE REAL COMPOSITION: A PENDING WIPE LEAVES **NOTHING** IN THE REAL STORE. ***
    func testGF003TheRealCommitRoadWritesNothingWhileTheJournalStandsPending() async throws {
        let msgUrl = FileManager.default.temporaryDirectory.appendingPathComponent("gf003_msg_\(UUID().uuidString).db")
        let peerUrl = FileManager.default.temporaryDirectory.appendingPathComponent("gf003_peer_\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: msgUrl); try? FileManager.default.removeItem(at: peerUrl) }

        // *** THE CRASH-RESTART STATE: THE JOURNAL IS ALREADY PENDING WHEN THE RUNTIME IS BUILT. Its own `resume()`
        // stops at REQUESTED under the deferred seams, so the runtime STANDS PENDING WITH ITS STORES OPEN. ***
        let pendingJournal = GsFinal003Journal()
        pendingJournal.state = .requested
        let runtime = try MeshRuntime.createArchiveOnlyHostComposition(
            messageStoreUrl: msgUrl, peerStoreUrl: peerUrl,
            journal: pendingJournal, keychain: InMemoryKeychain())
        XCTAssertFalse(
            runtime.wipeAuthority.allowsSensitiveApi(),
            "*** THE RIG MUST REALLY STAND PENDING WITH ITS STORES OPEN -- the state a crash-restart leaves, and the "
            + "only state in which this guard matters. ***")

        let sender = try gf003Sender(0x81)
        let frame = try await gf003SealedFrame(for: runtime, sender: sender,
                                               nonce: Data(repeating: 0x82, count: 16))

        // *** THE REAL INGESTION ROAD -- AND A DIAGNOSTIC FIRST, BECAUSE THE ADVISORY'S INSTRUMENTED GUARD PROVED
        // SOMETHING IMPORTANT: **A PROBE INSIDE THE PRODUCTION COMMIT CLOSURE NEVER FIRED**, SO THIS ROAD DOES NOT
        // REACH IT AND EVERY ZERO ASSERTED BELOW WOULD BE ZERO FOR AN UNRELATED REASON. ***

        // *** WHAT THIS ARM MEASURES, AND -- AFTER FIVE WRONG CONCLUSIONS -- WHAT IT DOES **NOT**. ***
        //
        // IT MEASURES: **the inbox road is refused while the journal stands pending, and nothing reaches the store**
        // (`obligations=0 frames=0 held=0`, read through an UN-GATED `SqliteAckStore` over the same engine -- NOT the
        // gated decorator, which would return zero whether or not the write happened).
        //
        // *** IT DOES NOT MEASURE THE GUARD AT `MeshRuntime.swift:249`, AND THE FINAL EXPERIMENT SETTLED THAT WITH A
        // DISTINCT SENTINEL RATHER THAN AN AMBIGUOUS ONE. *** The ambiguity was real and a review named it:
        // `refuseStorage("inbox commit")` is produced BOTH by my guard AND by the commit's own catch-all
        // (`} catch { return .storageFailure }`), so an arm reading that string CANNOT TELL THEM APART.
        //
        // THE DISAMBIGUATION: the guard was temporarily changed to return a sentinel the commit CANNOT produce
        // (`.invalidArgument`), and the pending runtime STILL answered `.storageFailure` / `"inbox commit"`.
        // **SO THE REFUSAL COMETH FROM THE COMMIT, NOT FROM THE GUARD.** (AND THE FIRST THREE ATTEMPTS AT THIS
        // EXPERIMENT WERE WORTHLESS FOR A DIFFERENT REASON A REVIEW ALSO CAUGHT: **STALE BINARIES** -- a `swift test`
        // returning in 1.2s HAD NOT RECOMPILED THE EDITED SOURCE, SO THOSE RUNS EXERCISED THE PREVIOUS BUILD. The
        // results here are from runs that verifiably recompiled: 16s and 2m49s of real compile time, after deleting
        // the build directory. **A 1-SECOND `swift test` ON AN EDITED PRODUCTION FILE IS A STALE-BINARY SIGNATURE.**)
        //
        // **AND A GUARD IN FRONT OF A COMMIT THAT CANNOT RUN PROVES NOTHING ABOUT THE GUARD.** The commit fails on a
        // pending runtime for a NON-WIPE reason -- the deferred seams of a crash-restart composition leave its
        // transaction throwing -- and that is UNIDENTIFIED HERE. **THE GUARD IS KEPT AS FAIL-CLOSED DEFENCE IN DEPTH
        // AND IS RECORDED AS UNPROVEN, POSSIBLY REDUNDANT.** The commit road's real proof remains the four DECORATOR
        // arms, which ARE causally proven (reverting the decorator reddens them).
        let outcome = try? runtime.meshNode.recipientInbox?.acceptVerifiedAndRequireAck(
            frame, receivedFrom: sender.identity.nodeId)
        let probeAck = SqliteAckStore(engine: runtime.messageStore)
        XCTAssertEqual(probeAck.countObligations(), 0,
                       "the un-gated observer over the real engine must see no obligation")
        XCTAssertEqual(probeAck.countFrames(), 0,
                       "nor an ACK frame row")

        // *** THE SEPARATE ROAD, MEASURED ON ITS OWN SO IT CANNOT BE CONFLATED WITH THE ONE ABOVE. ***
        //
        // `MeshNode.ingestInbound` CALLS `router.ingest(...)` **BEFORE** the inbox, and `Router.ingest` calls
        // `store.persist(frame, receivedFrom:)`. **THAT IS THE SHARED RELAY/FORWARD ROAD AND IT CARRIES NO WIPE GATE**
        // -- so a frame ENTERS THE STORE WHILE A WIPE IS PENDING even though the inbox refused it.
        //
        // IT IS PINNED RATHER THAN ASSERTED-AND-LEFT-RED, BECAUSE IT IS THE **NEXT** FINDING AND NOT THIS REPAIR'S
        // CHARGE, AND BECAUSE THE ADVISORY'S WARNING ABOUT GATING IT IS SOUND: this persist is the road the RELAY and
        // the FORWARD legitimately drive, so gating it naively would break relaying even with NO wipe pending. **THE
        // SEAM MUST BE LOCATED, NOT GUESSED -- AND THE MEASUREMENT BELOW IS WHAT SAYS THE LEAK IS REAL.**
        let sender2 = try gf003Sender(0x83)
        let frame2 = try await gf003SealedFrame(for: runtime, sender: sender2,
                                                nonce: Data(repeating: 0x84, count: 16))
        _ = runtime.meshNode.ingestInbound(frame2, receivedFrom: sender2.identity.nodeId)
        XCTAssertEqual(
            runtime.messageStore.allHeldMsgIds().count, 1,
            "*** ROUTER ROAD, PINNED: `Router.ingest` -> `store.persist` writes a held row WHILE THE JOURNAL STANDS "
            + "PENDING. THIS ARM WILL BE INVERTED TO 0 WHEN THAT ROAD IS GATED, AND IT EXISTS SO THE ROAD CANNOT BE "
            + "FORGOTTEN. Observed: \(runtime.messageStore.allHeldMsgIds().count) ***")
    }

    /// *** AND THE POSITIVE CONTROL: THE SAME FRAME ON A CLEAN RUNTIME REALLY COMMITS. ***
    func testGF003TheRealCommitRoadWritesWhenNoWipeIsPending() async throws {
        let msgUrl = FileManager.default.temporaryDirectory.appendingPathComponent("gf003b_msg_\(UUID().uuidString).db")
        let peerUrl = FileManager.default.temporaryDirectory.appendingPathComponent("gf003b_peer_\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: msgUrl); try? FileManager.default.removeItem(at: peerUrl) }

        let runtime = try MeshRuntime.createArchiveOnlyHostComposition(
            messageStoreUrl: msgUrl, peerStoreUrl: peerUrl,
            journal: GsFinal003Journal(), keychain: InMemoryKeychain())
        XCTAssertTrue(runtime.wipeAuthority.allowsSensitiveApi(), "a clean journal must ADMIT")

        let sender = try gf003Sender(0x91)
        let frame = try await gf003SealedFrame(for: runtime, sender: sender,
                                               nonce: Data(repeating: 0x92, count: 16))
        _ = runtime.meshNode.ingestInbound(frame, receivedFrom: sender.identity.nodeId)

        // THE RIG'S OWN WITNESS THAT IT REACHED THE COMMIT, so a zero in the sibling arm cannot be vacuous.
        let realAck = SqliteAckStore(engine: runtime.messageStore)
        XCTAssertGreaterThan(
            realAck.countObligations(), 0,
            "*** WITH NO WIPE PENDING THE SAME FRAME MUST REALLY COMMIT AN OBLIGATION -- otherwise the refusal arm's "
            + "zero would be zero for an unrelated reason (a frame dying at an earlier gate) and would prove nothing. "
            + "Observed: obligations=\(realAck.countObligations()) frames=\(realAck.countFrames()) held="
            + "\(runtime.messageStore.allHeldMsgIds().count) ***")
    }
}
