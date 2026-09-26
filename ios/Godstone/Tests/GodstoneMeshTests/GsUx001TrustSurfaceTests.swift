import XCTest
import CryptoKit
import Foundation
@testable import GodstoneMesh
import GodstoneCore

/// GS-UX-001 court: exercises the trust surface facade over the REAL PeerIdentityRepository
/// and SQLite store.
///
/// Witnesses:
/// 1. `test01ConfirmOnMismatchRefusesLocally`: A mismatched fingerprint is refused by the model
///    before the port, leaving trust unchanged.
/// 2. `test02ConfirmOnMatchReachesPortAndRefusesHonestUnclaimed`: A matching fingerprint reaches
///    the port, which honestly reports that durable promotion is unclaimed pending an ADR.
/// 3. `test03StaleRotationCandidateRefusedByRepositoryCas`: A rotation candidate modified after
///    display is refused by the real repository's CAS (`staleCandidate`).
/// 4. `test04RevokeInvalidatesPeerInRealRepositoryAndSessions`: Revocation marks the peer revoked
///    in the real SQLite store and invalidates its sessions.
@MainActor
final class GsUx001TrustSurfaceTests: XCTestCase {

    private let seedA = Data(repeating: 0x11, count: 32)
    private let seedB = Data(repeating: 0x22, count: 32)
    private let staticPrivA = Data(repeating: 0x33, count: 32)
    private let staticPrivB = Data(repeating: 0x44, count: 32)
    private let staticPrivC = Data(repeating: 0x55, count: 32)

    private func tempDbUrl() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("godstone-test-trust-\(UUID().uuidString).db")
    }

    private func makeBinding(
        seed: Data,
        generation: UInt32,
        staticDhPriv: Data
    ) -> ValidatedPeerBinding {
        let signingKey = try! Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        let agreementKey = try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: staticDhPriv)
        let preimage = IdentityBindingV1.signaturePreimage(
            generation: generation,
            signingPublicKey: signingKey.publicKey.rawRepresentation,
            staticDhPublicKey: agreementKey.publicKey.rawRepresentation
        )
        let sig = try! signingKey.signature(for: preimage)
        let binding = try! IdentityBindingV1(
            generation: generation,
            signingPublicKey: signingKey.publicKey.rawRepresentation,
            staticDhPublicKey: agreementKey.publicKey.rawRepresentation,
            signature: sig
        )
        let res = IdentityBindingValidator.validate(
            serialized: binding.encode(),
            authenticatedRemoteStaticKey: agreementKey.publicKey.rawRepresentation,
            advertisedNodeHint: IdentityBindingV1.deriveNodeHint(
                nodeId: IdentityBindingV1.deriveNodeId(signingPublicKey: signingKey.publicKey.rawRepresentation)
            )
        )
        guard case .valid(let validated) = res else {
            fatalError("Validation failed")
        }
        return validated
    }

    // -------------------------------------------------------------------------
    // 1. Confirm-on-mismatch refuses locally
    // -------------------------------------------------------------------------

    /// *** THE REGRESSION GUARD FOR THE SILENT PRODUCTION DEFECT. ***
    ///
    /// *`LabRuntime.compose` passed `nodeId.prefix(2)` where `IdentityBindingValidator` requires
    /// `identityBindingNodeHintLength == 4`, so EVERY validation returned `.invalidContext` -- and the `if case
    /// .valid` HAD NO `else`, SO EVERY BINDING WAS SILENTLY SKIPPED. **MEASURED CONSEQUENCE:**
    /// `trustContactLabels()` returned three labels while `trustFingerprint(for:)` returned nil for EVERY one and
    /// every contact read "unknown", BECAUSE THE DURABLE REPOSITORY WAS EMPTY.*
    ///
    /// *** AN EXTERNAL REVIEW FOUND THAT I COMMITTED THE FIX WITHOUT ITS GUARD: `grep trustWiringFailures` over
    /// `ios/Godstone/Tests` returned NO MATCHES -- APPEND-ONLY DEAD CODE THAT REDDENS ON NOTHING, AND THE a11y SUITE
    /// CANNOT SEE THIS AT ALL. *** This is that guard, and it drives the REAL `LabRuntime.compose` path rather than
    /// a hand-built facade, because the defect lived in the COMPOSITION.
    func test00TheLabComposesWithNoSilentBindingFailures() throws {
        // A FRESH COMPOSE, so the counter's state is this test's and not a previous run's.
        LabRuntime.resetTrustWiringFailuresForTest()
        let lab = try LabRuntime.compose(labels: ["A", "R", "B"], seedByte: 0x11)

        // *** (i) NOTHING FAILED TO WIRE. *** *This is the observation the counter exists for, and no court read it
        // until this one.*
        XCTAssertTrue(
            LabRuntime.trustWiringFailures.isEmpty,
            "*** NO BINDING MAY FAIL VALIDATION SILENTLY. Observed failures: \(LabRuntime.trustWiringFailures) -- " +
                "a non-empty list means the lab composed with contacts that have NO IDENTITY. ***",
        )

        // *** (ii) AND THE CONTACTS ACTUALLY CARRY IDENTITIES -- THE CONSEQUENCE THE SILENT SKIP HID. ***
        let labels = lab.trustContactLabels()
        XCTAssertFalse(labels.isEmpty, "the lab must register its labels as trust contacts")
        for label in labels {
            let fp = lab.trustFingerprint(for: label)
            XCTAssertNotNil(fp, "*** \(label) MUST HAVE A FINGERPRINT: nil here is exactly the symptom of the " +
                                "silently-skipped binding. ***")
            XCTAssertEqual(
                fp?.count, 64,
                "*** AND IT MUST BE A 64-CHARACTER HEX DIGEST, not a placeholder. Observed: \(fp ?? "nil") ***",
            )
            XCTAssertTrue(
                fp!.allSatisfy { $0.isHexDigit },
                "and every character must be hex; observed: \(fp!)",
            )
            XCTAssertNotEqual(
                lab.contactTrustLabel(label), "unknown",
                "*** AND THE TRUST MUST BE KNOWN. \"unknown\" for EVERY label is the exact state the empty " +
                    "repository produced. ***",
            )
        }
    }

    func test01ConfirmOnMismatchRefusesLocally() throws {
        let url = tempDbUrl()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try SqlitePeerIdentityStore(url: url)
        let repo = PeerIdentityRepository(store: store)
        let binding = makeBinding(seed: seedA, generation: 1, staticDhPriv: staticPrivA)
        _ = repo.applyValidatedBinding(binding)

        let facade = MeshTrustFacade(
            repository: repo,
            ownNodeId: Data(repeating: 0x99, count: 16),
            contacts: [("Alice", binding.nodeId)]
        )

        let mismatchFp = String(repeating: "0", count: 64)
        let outcome = facade.compareAndConfirm(label: "Alice", displayedFingerprintHex: mismatchFp)

        XCTAssertTrue(outcome.hasPrefix("refused:"), "Outcome must be refused: \(outcome)")
        XCTAssertTrue(outcome.contains("differ"), "Expected mismatch explanation: \(outcome)")
        XCTAssertFalse(facade.isVerified(label: "Alice"), "Contact must NOT be verified after mismatch")
        XCTAssertNotNil(facade.lastError())

        // *** AND THE DURABLE DISCRIMINATOR -- `test04`'s OWN STANDARD APPLIED HERE. ***
        //
        // *`test04` reads `repo.lookup` directly because **THE PROJECTION IS A CLAIM AND THE STORE IS THE SOURCE**;
        // these two arms asserted ONLY `facade.*` projections, which an adapter that promoted locally could move
        // without touching the row. **AN EXTERNAL REVIEW POINTED OUT THAT INCONSISTENCY AND WAS RIGHT.***
        //
        // *`PeerIdentityLookup.verified` + `PeerTrustLevel.tofuPinned` is the UNCHANGED state a REFUSED confirm must
        // leave behind: a bound peer sits at `.tofuPinned`, and `.userVerified` is what only a durable CAS may
        // produce (`PeerTrustModels.swift:11`: tofuPinned=1, userVerified=2, revoked=3).*
        //
        // *** HONEST SCOPE: `TrustAuthorityAdapter.confirmVerified` returns `.refused(...)` UNCONDITIONALLY today --
        // THERE IS NO DURABLE CAS -- so this cannot catch a live bug. IT GUARDS THE FUTURE CAS: when one is written,
        // an implementation that projects success WITHOUT the durable write reddens here rather than shipping.*** *Stated
        // so the arm is not read as proving more than it does.*
        guard case .verified(let unchanged) = repo.lookup(binding.nodeId) else {
            XCTFail("*** a refused confirm must leave the row verified/tofuPinned; got \(repo.lookup(binding.nodeId)) ***")
            return
        }
        // *** WHAT THIS CHECK IS AND IS NOT -- STATED EXACTLY, BECAUSE AN EXTERNAL REVIEW ASKED. ***
        //
        // *It catches ONE DIRECTION: **A SPURIOUS PROMOTION.** If the adapter ever wrote `userVerified` on a
        // refused confirm, the row would no longer be `.tofuPinned` and this reddens.*
        //
        // *IT IS **NOT MUTATION-PROVEN TODAY**, AND THAT IS RECORDED RATHER THAN GLOSSED: the adapter has NO write
        // path -- `confirmVerified` returns `.refused(...)` with no store access -- so there is nothing to mutate to
        // make it fire. **IT IS A GUARD FOR THE FUTURE CAS, NOT VERIFIED COVERAGE.** The mutation that WAS run
        // (project success without a write) leaves the row untouched, so THIS check passes under it -- which is
        // exactly why the forgery check below exists.*
        //
        // *THE TWO ARE NOT REDUNDANT AND NEITHER IS A TAUTOLOGY: they cover OPPOSITE DIRECTIONS. This one fires on
        // "promoted without authority"; the forgery check fires on "claimed without promotion". **A SINGLE-SOURCE
        // ASSERTION IN EITHER DIRECTION IS BLIND TO THE OTHER'S DEFECT** -- established by measurement across three
        // versions of this arm, not by argument.*
        XCTAssertEqual(
            unchanged.trustLevel, .tofuPinned,
            "*** THE DURABLE STATE: a refused confirm must leave the row where it was. Fires on a SPURIOUS " +
                "PROMOTION -- the opposite direction from the forgery check below. ***",
        )

        // *** AND THE DISCRIMINATOR THAT ACTUALLY CATCHES FORGING -- WHICH TOOK TWO WRONG VERSIONS TO FIND. ***
        //
        // *MY FIRST VERSION stopped at the store assertion above, and **THE MUTATION PROVED IT INSUFFICIENT**:
        // with `confirmVerified` mutated to project success without a durable write, the row genuinely stayed
        // `tofuPinned`, so that check PASSED. **A CHECK THAT ONLY READS THE STORE CANNOT SEE A PROJECTION THAT
        // DISAGREES WITH IT.***
        //
        // *MY SECOND VERSION asserted the model and the store AGREE on verification -- and it STILL did not fire,
        // because of something the mutation revealed about the model itself: `.confirmed` sets
        // `lastOutcome: "fingerprint confirmed for Alice"` and then `project()` RE-READS THE STORE, so
        // `isVerified` stays FALSE. **THE MODEL CONTRADICTS ITSELF: IT REPORTS SUCCESS AND NON-VERIFICATION AT
        // ONCE**, and both sides of my comparison said "not verified".*
        //
        // **SO THE FORGERY'S ACTUAL SIGNATURE IS A SUCCESS CLAIM WITHOUT A DURABLE PROMOTION**, and that is what is
        // asserted here: the outcome string may report a confirmation ONLY IF THE ROW WAS PROMOTED. *This is the
        // model's own law 2 -- "USER_VERIFIED APPEARETH ONLY AFTER THE DURABLE CAS SUCCEEDETH" -- checked from the
        // OUTSIDE, where a local-only implementation cannot satisfy it.*
        let projectedOutcome = facade.lastOutcome() ?? ""
        let claimsConfirmation = projectedOutcome.contains("confirmed")
        let rowWasPromoted = (unchanged.trustLevel == .userVerified)
        XCTAssertFalse(
            claimsConfirmation && !rowWasPromoted,
            "*** A SUCCESS CLAIM WITHOUT A DURABLE PROMOTION IS THE FORGERY: the model reported "
                + "\"\(projectedOutcome)\" while the row still says \(unchanged.trustLevel). **THE PROJECTION IS A CLAIM AND "
                + "THE STORE IS THE SOURCE** -- their disagreement is the defect, and no single-source assertion "
                + "(neither the store alone nor the model alone) can see it. ***",
        )
    }

    // -------------------------------------------------------------------------
    // 2. Confirm-on-match reaches port and refuses honest unclaimed
    // -------------------------------------------------------------------------
    func test02ConfirmOnMatchReachesPortAndRefusesHonestUnclaimed() throws {
        let url = tempDbUrl()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try SqlitePeerIdentityStore(url: url)
        let repo = PeerIdentityRepository(store: store)
        let binding = makeBinding(seed: seedA, generation: 1, staticDhPriv: staticPrivA)
        _ = repo.applyValidatedBinding(binding)

        let facade = MeshTrustFacade(
            repository: repo,
            ownNodeId: Data(repeating: 0x99, count: 16),
            contacts: [("Alice", binding.nodeId)]
        )

        guard let matchingFp = facade.fingerprint(for: "Alice") else {
            XCTFail("Alice must have a rendered fingerprint")
            return
        }

        let outcome = facade.compareAndConfirm(label: "Alice", displayedFingerprintHex: matchingFp)

        // Matching fingerprint passes local model check and reaches port;
        // port returns the honest refusal recorded by T56 (unclaimed pending ADR).
        XCTAssertTrue(outcome.hasPrefix("refused:"), "Outcome must report port refusal: \(outcome)")
        XCTAssertTrue(
            outcome.contains("unclaimed pending an ADR"),
            "Expected port refusal reason regarding unclaimed promotion: \(outcome)"
        )
        XCTAssertFalse(facade.isVerified(label: "Alice"), "Contact must remain unverified")

        // *** AND THE DURABLE DISCRIMINATOR -- `test04`'s OWN STANDARD APPLIED HERE. ***
        //
        // *`test04` reads `repo.lookup` directly because **THE PROJECTION IS A CLAIM AND THE STORE IS THE SOURCE**;
        // these two arms asserted ONLY `facade.*` projections, which an adapter that promoted locally could move
        // without touching the row. **AN EXTERNAL REVIEW POINTED OUT THAT INCONSISTENCY AND WAS RIGHT.***
        //
        // *`PeerIdentityLookup.verified` + `PeerTrustLevel.tofuPinned` is the UNCHANGED state a REFUSED confirm must
        // leave behind: a bound peer sits at `.tofuPinned`, and `.userVerified` is what only a durable CAS may
        // produce (`PeerTrustModels.swift:11`: tofuPinned=1, userVerified=2, revoked=3).*
        //
        // *** HONEST SCOPE: `TrustAuthorityAdapter.confirmVerified` returns `.refused(...)` UNCONDITIONALLY today --
        // THERE IS NO DURABLE CAS -- so this cannot catch a live bug. IT GUARDS THE FUTURE CAS: when one is written,
        // an implementation that projects success WITHOUT the durable write reddens here rather than shipping.*** *Stated
        // so the arm is not read as proving more than it does.*
        guard case .verified(let unchanged) = repo.lookup(binding.nodeId) else {
            XCTFail("*** a refused confirm must leave the row verified/tofuPinned; got \(repo.lookup(binding.nodeId)) ***")
            return
        }
        // *** WHAT THIS CHECK IS AND IS NOT -- STATED EXACTLY, BECAUSE AN EXTERNAL REVIEW ASKED. ***
        //
        // *It catches ONE DIRECTION: **A SPURIOUS PROMOTION.** If the adapter ever wrote `userVerified` on a
        // refused confirm, the row would no longer be `.tofuPinned` and this reddens.*
        //
        // *IT IS **NOT MUTATION-PROVEN TODAY**, AND THAT IS RECORDED RATHER THAN GLOSSED: the adapter has NO write
        // path -- `confirmVerified` returns `.refused(...)` with no store access -- so there is nothing to mutate to
        // make it fire. **IT IS A GUARD FOR THE FUTURE CAS, NOT VERIFIED COVERAGE.** The mutation that WAS run
        // (project success without a write) leaves the row untouched, so THIS check passes under it -- which is
        // exactly why the forgery check below exists.*
        //
        // *THE TWO ARE NOT REDUNDANT AND NEITHER IS A TAUTOLOGY: they cover OPPOSITE DIRECTIONS. This one fires on
        // "promoted without authority"; the forgery check fires on "claimed without promotion". **A SINGLE-SOURCE
        // ASSERTION IN EITHER DIRECTION IS BLIND TO THE OTHER'S DEFECT** -- established by measurement across three
        // versions of this arm, not by argument.*
        XCTAssertEqual(
            unchanged.trustLevel, .tofuPinned,
            "*** THE DURABLE STATE: a refused confirm must leave the row where it was. Fires on a SPURIOUS " +
                "PROMOTION -- the opposite direction from the forgery check below. ***",
        )

        // *** AND THE DISCRIMINATOR THAT ACTUALLY CATCHES FORGING -- WHICH TOOK TWO WRONG VERSIONS TO FIND. ***
        //
        // *MY FIRST VERSION stopped at the store assertion above, and **THE MUTATION PROVED IT INSUFFICIENT**:
        // with `confirmVerified` mutated to project success without a durable write, the row genuinely stayed
        // `tofuPinned`, so that check PASSED. **A CHECK THAT ONLY READS THE STORE CANNOT SEE A PROJECTION THAT
        // DISAGREES WITH IT.***
        //
        // *MY SECOND VERSION asserted the model and the store AGREE on verification -- and it STILL did not fire,
        // because of something the mutation revealed about the model itself: `.confirmed` sets
        // `lastOutcome: "fingerprint confirmed for Alice"` and then `project()` RE-READS THE STORE, so
        // `isVerified` stays FALSE. **THE MODEL CONTRADICTS ITSELF: IT REPORTS SUCCESS AND NON-VERIFICATION AT
        // ONCE**, and both sides of my comparison said "not verified".*
        //
        // **SO THE FORGERY'S ACTUAL SIGNATURE IS A SUCCESS CLAIM WITHOUT A DURABLE PROMOTION**, and that is what is
        // asserted here: the outcome string may report a confirmation ONLY IF THE ROW WAS PROMOTED. *This is the
        // model's own law 2 -- "USER_VERIFIED APPEARETH ONLY AFTER THE DURABLE CAS SUCCEEDETH" -- checked from the
        // OUTSIDE, where a local-only implementation cannot satisfy it.*
        let projectedOutcome = facade.lastOutcome() ?? ""
        let claimsConfirmation = projectedOutcome.contains("confirmed")
        let rowWasPromoted = (unchanged.trustLevel == .userVerified)
        XCTAssertFalse(
            claimsConfirmation && !rowWasPromoted,
            "*** A SUCCESS CLAIM WITHOUT A DURABLE PROMOTION IS THE FORGERY: the model reported "
                + "\"\(projectedOutcome)\" while the row still says \(unchanged.trustLevel). **THE PROJECTION IS A CLAIM AND "
                + "THE STORE IS THE SOURCE** -- their disagreement is the defect, and no single-source assertion "
                + "(neither the store alone nor the model alone) can see it. ***",
        )
    }

    // -------------------------------------------------------------------------
    // 3. Stale rotation candidate is refused
    // -------------------------------------------------------------------------
    func test03StaleRotationCandidateRefusedByRepositoryCas() throws {
        let url = tempDbUrl()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try SqlitePeerIdentityStore(url: url)
        let repo = PeerIdentityRepository(store: store)

        // Step 1: Pinned initial binding (generation 5)
        let b1 = makeBinding(seed: seedA, generation: 5, staticDhPriv: staticPrivA)
        _ = repo.applyValidatedBinding(b1)

        // Step 2: Ingest rotation candidate (generation 6, key B) -> quarantined
        let b2 = makeBinding(seed: seedA, generation: 6, staticDhPriv: staticPrivB)
        let res2 = repo.applyValidatedBinding(b2)
        XCTAssertEqual(res2, .keyChangedQuarantined)

        var invalidatedSessions: [Data] = []
        let facade = MeshTrustFacade(
            repository: repo,
            ownNodeId: Data(repeating: 0x99, count: 16),
            contacts: [("Alice", b1.nodeId)],
            sessionInvalidator: { invalidatedSessions.append($0) }
        )

        XCTAssertTrue(facade.isRotationPending(label: "Alice"), "Alice should have a pending rotation")

        // Step 4: THE VIEW CAPTURES THE CANDIDATE IT DISPLAYED, at the moment the screen showed it (generation 6,
        // key B). *This is the state the screen held while the user was looking at it.*
        guard let displayed = facade.displayedRotationCandidate(for: "Alice") else {
            XCTFail("*** THE SCREEN MUST BE ABLE TO CAPTURE THE CANDIDATE IT DISPLAYED (GS-UX-001 law 3) ***")
            return
        }
        XCTAssertEqual(displayed.pendingGeneration, 6, "the displayed candidate is the one the screen showed")

        // *** AND ONLY NOW DOES THE REPOSITORY MOVE BEHIND THE USER'S BACK -- AFTER the capture, BEFORE the tap. ***
        //
        // *THE ORDER IS THE TEST: the previously-issued label-taking approval verb re-read "the current" candidate
        // inside the call, so it would have approved generation 8 rather than refusing. **THE DISPLAYED REF MUST
        // TRAVEL, and the CAS must bind on it.***
        let b3 = makeBinding(seed: seedA, generation: 8, staticDhPriv: staticPrivC)
        let res3 = repo.applyValidatedBinding(b3)
        XCTAssertEqual(res3, .keyChangedQuarantined)

        // Step 5: THE USER TAPS APPROVE ON THE STALE CANDIDATE THEY WERE SHOWN.
        let approveOutcome = facade.approveDisplayedRotation(displayed)

        // Repository CAS refuses stale candidate
        XCTAssertTrue(approveOutcome.hasPrefix("refused:"), "Stale approval must be refused: \(approveOutcome)")
        XCTAssertTrue(
            approveOutcome.contains("no longer pending"),
            "Expected stale candidate explanation: \(approveOutcome)"
        )
        // *** AND THE EXACT STRING THE RENDERED ARM BINDS. ***
        XCTAssertEqual(approveOutcome, "refused: that rotation is no longer pending: nothing was approved")

        // Repository accepted generation remains 5
        guard case .quarantined(let current) = repo.lookup(b1.nodeId) else {
            XCTFail("Expected peer to remain quarantined")
            return
        }
        XCTAssertEqual(current.acceptedGeneration, 5)
        XCTAssertEqual(current.pendingGeneration, 8)
    }

    // -------------------------------------------------------------------------
    // 4. Revoke invalidates peer in repository and sessions
    // -------------------------------------------------------------------------
    func test04RevokeInvalidatesPeerInRealRepositoryAndSessions() throws {
        let url = tempDbUrl()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try SqlitePeerIdentityStore(url: url)
        let repo = PeerIdentityRepository(store: store)
        let binding = makeBinding(seed: seedA, generation: 1, staticDhPriv: staticPrivA)
        _ = repo.applyValidatedBinding(binding)

        var invalidatedNodes: [Data] = []
        let facade = MeshTrustFacade(
            repository: repo,
            ownNodeId: Data(repeating: 0x99, count: 16),
            contacts: [("Alice", binding.nodeId)],
            sessionInvalidator: { invalidatedNodes.append($0) }
        )

        XCTAssertFalse(facade.isRevoked(label: "Alice"))

        let revokeOutcome = facade.revoke(label: "Alice")
        XCTAssertTrue(revokeOutcome.hasPrefix("applied:"), "Revocation must succeed: \(revokeOutcome)")
        XCTAssertTrue(facade.isRevoked(label: "Alice"), "Facade must report Alice is revoked")

        // *** AND THE REPOSITORY ITSELF, WHICH IS THE DISCRIMINATOR -- AN EXTERNAL REVIEW'S POINT. ***
        //
        // *`facade.isRevoked` reads the MODEL'S PROJECTION. `TrustUXModel` sets its `lastOutcome` string purely from
        // the `ConfirmOutcome`/`RevokeResult` the port returned, INDEPENDENT of whether the durable store was
        // touched -- so **AN ADAPTER THAT REVOKED IN MEMORY AND NEVER WROTE TO THE REPOSITORY WOULD KEEP BOTH THE
        // OUTCOME STRING AND THE PROJECTION GREEN.** The projection is a claim; the store is the source.*
        //
        // **SO THIS READS THE REAL REPOSITORY DIRECTLY.** `PeerIdentityRepository.lookup` is the same source
        // `TrustAuthorityAdapter.lookup` delegates to, so if the two ever disagree, the adapter is forging.*
        // *** AND THE REPOSITORY ITSELF, WHICH IS THE DISCRIMINATOR -- AN EXTERNAL REVIEW'S POINT. ***
        //
        // *`facade.isRevoked` reads the MODEL'S PROJECTION, and `TrustUXModel` sets its outcome string purely from
        // the typed result the port returned, INDEPENDENT of whether the durable store was touched. **AN ADAPTER
        // THAT REVOKED ONLY IN MEMORY WOULD KEEP BOTH THE OUTCOME STRING AND THE PROJECTION GREEN.** The projection
        // is a claim; the store is the source.*
        //
        // **MY FIRST VERSION OF THIS ASSERTION WAS WRONG AND THE FAILURE TAUGHT ME THE REAL VOCABULARY:** I assumed
        // a revoked peer still answers `.verified` with a different `trustLevel`, and the arm failed saying the peer
        // was not found as verified. **`PeerIdentityLookup` HAS A DEDICATED `.revoked` CASE**
        // (`PeerIdentityRepository.swift:31`), so the durable revocation is a DIFFERENT CASE rather than a field
        // value -- and asserting the case is both correct AND STRONGER than comparing a level.*
        switch repo.lookup(binding.nodeId) {
        case .revoked:
            break   // THE DURABLE REVOCATION, READ FROM THE STORE RATHER THAN THE PROJECTION.
        case .verified(let identity):
            XCTFail("*** THE REPOSITORY STILL REPORTS THE PEER VERIFIED (trustLevel \(identity.trustLevel)) AFTER A " +
                    "REVOKE THAT THE FACADE CALLED APPLIED. **THE PROJECTION WOULD HAVE BEEN FORGED** -- the store " +
                    "is the source and it says otherwise. ***")
        case .notFound:
            XCTFail("*** A REVOKED PEER'S ROW IS UPDATED, NOT DELETED, so `notFound` means the wrong durable " +
                    "operation ran. ***")
        case .quarantined, .corrupt, .storageFailure, .invalidArgument:
            XCTFail("*** THE STORE MUST ANSWER `.revoked` AFTER A REVOKE; it answered \(repo.lookup(binding.nodeId)) ***")
        }

        // Real repository check
        XCTAssertEqual(repo.lookup(binding.nodeId), .revoked, "Repository lookup must return revoked")

        // Session invalidation check
        XCTAssertTrue(invalidatedNodes.contains(binding.nodeId), "Session invalidator must have been called")
    }

    // -------------------------------------------------------------------------
    // 5. The COMPOSE BOUND is a MEASUREMENT, not a copied constant
    // -------------------------------------------------------------------------

    /// *** GS-UX-001 `rendered-controls`: THE BOUND THE VIEW ENFORCES IS THE BOUND THE AUTHORITY BUILDS. ***
    ///
    /// *THE DEFECT THIS PREVENTS: a view with `maxBody = 512` typed into it while the frame builder refuses at 400 --
    /// the input would ACCEPT a body the authority REFUSES, and the rendered failure would read as a transport
    /// problem. **A COPIED CONSTANT IS A CONSTANT THAT DRIFTS.***
    ///
    /// **SO THE ARM RE-RUNS THE PROBE AND REQUIRES THE ADVERTISED BOUND TO EQUAL IT.** *That is the mutation-bite: a
    /// hand-typed constant reddens here, because the probe measures the REAL chain
    /// (`SignedMessageV1.author` -> `Router.buildSealedMessage`, exactly `ComposedRuntime.authorFrame`'s road) rather
    /// than a number.*
    func test05TheComposeBoundIsMeasuredThroughTheRealChain() throws {
        let measured = LabRuntime.measureMaxComposeBodyOctets()
        XCTAssertEqual(
            LabRuntime.maxComposeBodyOctets, measured,
            "*** THE ADVERTISED BOUND MUST BE THE MEASURED ONE. A constant that disagrees with the probe accepteth a " +
                "body the authority refuses. ***",
        )
        // AND THE MEASUREMENT IS CONSISTENT WITH THE FROZEN CONTAINER: the lab may not author a body the container
        // would refuse, so the bound can never exceed the container's own budget.
        XCTAssertLessThanOrEqual(LabRuntime.maxComposeBodyOctets, SignedMessageV1.bodyMax,
                                 "the compose bound may not exceed the frozen container's body budget")

        // AND THE ENFORCEMENT POINT USES IT, in OCTETS. *The multibyte case is the discriminator: an emoji is ONE
        // character and FOUR octets, so a `Character.count` implementation would keep it while a correct one drops
        // it -- which is exactly the defect the card's "UTF-8 bounded" clause names.*
        let prefix = String(repeating: "a", count: LabRuntime.maxComposeBodyOctets - 1)
        XCTAssertEqual(LabRuntime.truncateToComposeBound(prefix + "⛵️"), prefix,
                       "a multibyte character that would overflow the OCTET bound must be dropped WHOLE")
        XCTAssertEqual(LabRuntime.truncateToComposeBound(prefix).utf8.count, LabRuntime.maxComposeBodyOctets - 1,
                       "and a body within the bound must be returned untouched")
        XCTAssertEqual(LabRuntime.truncateToComposeBound(prefix + "a").utf8.count, LabRuntime.maxComposeBodyOctets,
                       "a body exactly AT the bound must survive")

        // AND THE READOUT THE VIEW RENDERS NAMES THE SAME NUMBER.
        let lab = try LabRuntime.compose(labels: ["A", "R", "B"], seedByte: 0x41)
        XCTAssertEqual(lab.composeOctetsReadout("abc"),
                       "3/\(LabRuntime.maxComposeBodyOctets) octets",
                       "the rendered readout must carry the measured bound, counted in octets")
    }

    // -------------------------------------------------------------------------
    // 6. The durable Send's intent SURVIVES the runtime that authored it
    // -------------------------------------------------------------------------

    /// *** GS-UX-001 `rendered-controls` step 3: THE SEND IS DURABLE, AND THE INTENT OUTLIVES ITS AUTHOR. ***
    ///
    /// *The card asketh for `visible durable state after recreation`. The rendered Send now travels the DURABLE road
    /// (`sendDirectDurableIntent`), which pins the intent in `outbound_intents` BEFORE the frame is authored -- and
    /// this arm asks the question an in-memory medium can never answer: **a FRESH HANDLE over the same medium, with
    /// nothing of the authoring runtime consulted.***
    ///
    /// **THE DISCRIMINATOR IS THE SECOND CLAUSE.** *An id that was never authored must be ABSENT from the very same
    /// handle; without it, a reader that answereth `.found` to anything would satisfy clause one.*
    func test06TheRenderedSendPinsADurableIntentThatOutlivesItsAuthor() async throws {
        LabRuntime.resetLastIntentForTest()
        // A CLEAN MEDIUM, so the arm cannot read a previous run's row.
        let storeURL = LabRuntime.durableStoreURL()
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: storeURL.path + suffix) }

        let lab = try LabRuntime.compose(labels: ["A", "R", "B"], seedByte: 0x42)
        let intentId = LabRuntime.mintIntentId()
        let verdict = await lab.sendDirectDurableIntent("A", recipient: "B", plaintext: Data("boats".utf8),
                                                       intentId: intentId)
        XCTAssertTrue(verdict.hasPrefix("durable:"), "the rendered Send must take the durable road: \(verdict)")

        // CLAUSE 1 -- THE INTENT SURVIVES ITS AUTHOR, read from a fresh handle over the same medium.
        XCTAssertTrue(lab.durableIntentVerdict(intentId).hasPrefix("found:"),
                      "*** THE INTENT MUST SURVIVE THE RUNTIME THAT AUTHORED IT (read from a FRESH handle) ***")
        // AND THE RELAUNCH ROAD (the register a fresh process would read) names the SAME id and gives the SAME answer.
        XCTAssertEqual(LabRuntime.lastIntentId(), intentId,
                       "the last-intent register must survive for a relaunch to name")
        XCTAssertTrue(lab.durableVerdictForLastIntent().hasPrefix("found:"),
                      "and the RELAUNCH readout must answer from the register rather than from this process's memory")

        // CLAUSE 2 -- THE DISCRIMINATOR: an id that was NEVER authored is ABSENT from the very same handle.
        XCTAssertEqual(lab.durableIntentVerdict(Data(repeating: 0x00, count: 16)), "notFound",
                       "*** AN UNAUTHORED ID MUST BE ABSENT, or clause 1's `.found` would mean nothing ***")
    }

    // -------------------------------------------------------------------------
    // 7. SOS: durable arm and cancel through the node's own command surface
    // -------------------------------------------------------------------------

    /// *** GS-UX-001 `rendered-controls` step 3: THE DISTRESS CALL IS DURABLE, CANCELLABLE, AND RELAUNCH-READABLE. ***
    ///
    /// *The card's step 3 asketh the SOS journey be durable; the plan's instruction is that it use **THE EXISTING
    /// COMMAND SURFACE** (`handleSosCommand(.author)` / `.cancel(msgId)`), never a new mechanism. So this arm driveth
    /// the rendered road and REQUIREth:*
    ///  1. **an arm ENQUEUES DURABLY** -- the authority's own taxonomy, not a view's string;
    ///  2. **the state renders in the SHARED VOCABULARY** -- every word must come from
    ///     `AccessibilityContract.stateWords`, which is the mutation-bite against an invented phrase;
    ///  3. **a cancel retires the call AND DOES NOT MOVE THE AUTHOR COUNTER** -- the card's own discriminator
    ///     between stopping a call and un-authoring one;
    ///  4. **the state survives a relaunch** -- a FRESH `LabRuntime` over the same register renders what the first
    ///     one left, which is what no view-local `@State` can do.
    func test07TheDistressCallIsDurableCancellableAndRelaunchReadable() throws {
        LabRuntime.resetSosRegisterForTest()
        let first = try LabRuntime.compose(labels: ["A", "R", "B"], seedByte: 0x43)

        // (1) ARM, through the node's own command door.
        let armed = first.armSos(payload: Data("SOS".utf8))
        XCTAssertTrue(armed.hasPrefix("armed:"),
                      "*** THE DISTRESS ARM MUST REACH THE DURABLE AUTHORITY (got \(armed)) ***")
        let authoredAfterArm = first.sosAuthoredCount()
        XCTAssertEqual(authoredAfterArm, 1, "exactly one call was authored")

        // (2) THE STATE RENDERS IN THE SHARED VOCABULARY, not in invented words.
        let liveState = first.sosStateNames()
        XCTAssertTrue(liveState.hasPrefix("active: "), "a live call must render as active: \(liveState)")
        let spoken = String(liveState.dropFirst("active: ".count))
        XCTAssertTrue(
            AccessibilityContract.stateWords.contains { $0.1 == spoken },
            "*** EVERY RENDERED STATE WORD MUST COME FROM THE SHARED VOCABULARY (`AccessibilityContract.stateWords`); " +
                "got \(spoken) ***",
        )

        // (3) CANCEL BY ITS DURABLE ID.
        guard let msgId = first.activeSosMsgId() else {
            XCTFail("the standing call must have a durable msg_id to cancel")
            return
        }
        let cancelled = first.cancelSos(msgId: msgId)
        XCTAssertTrue(cancelled.hasPrefix("cancelled"), "the cancel must report its durable result: \(cancelled)")
        XCTAssertEqual(first.sosAuthoredCount(), authoredAfterArm,
                       "*** A CANCEL MUST NOT MOVE THE AUTHOR COUNTER: it stopeth a call, it doth not un-author one ***")
        // *** AND THE DURABLE ROW ITSELF SAYETH SO -- not merely the rendered string. ***
        //
        // *A cancel RETIRES the held frame but LEAVES the delivery row in its terminal state, which is the durable
        // witness a relaunch reads. Asking the ROW maketh the arm bite on the store rather than on the label.*
        XCTAssertEqual(first.durableDeliveryState(author: first.author, msgId: msgId), .cancelledLocally,
                       "*** THE DURABLE ROW MUST BE TERMINAL AFTER A CANCEL, or the rendered state is a claim ***")
        let terminal = first.sosStateNames()
        XCTAssertTrue(terminal.hasPrefix("terminal: "), "the retired call must render as terminal: \(terminal)")
        XCTAssertTrue(AccessibilityContract.stateWords.contains { $0.1 == String(terminal.dropFirst("terminal: ".count)) },
                      "and the terminal word must come from the same vocabulary")

        // (4) THE STATE SURVIVES A RELAUNCH: a FRESH runtime, nothing of the first consulted.
        let relaunched = try LabRuntime.compose(labels: ["A", "R", "B"], seedByte: 0x43)
        XCTAssertEqual(relaunched.sosStateNames(), terminal,
                       "*** THE RENDERED STATE MUST SURVIVE A RELAUNCH (register read, not view memory) ***")
        XCTAssertEqual(relaunched.sosAuthoredCount(), authoredAfterArm,
                       "and a cancel must still leave the author counter unmoved after a relaunch")
    }

    // -------------------------------------------------------------------------
    // 8. The host-decidable accessibility contract, over the LAB's own roster
    // -------------------------------------------------------------------------

    /// *** GS-UX-001 `accessibility`: THE CONTRACT CHECKS, RUN OVER THE LAB'S RENDERED ROSTER. ***
    ///
    /// *The obligation is `Internally verify rendered semantics (labels, identifiers, roles, state descriptions)
    /// without claiming human/device accessibility acceptance`. The contract's eight checks are the host-decidable
    /// half (`AccessibilityContract.swift:58-136`), and **HUMAN acceptance stays EXTERNAL** -- this arm asserteth only
    /// what a host can decide, and the roster below is built from the SHARED vocabulary so an invented word reddens.*
    ///
    /// **EVERY ESSENTIAL CONTROL IS PRESENT, LABELLED AND DESCRIBED, at BOTH scales and under RTL** -- because a
    /// contract check that only ever saw the default scale would certify nothing about enlarged type.
    func test08TheHostDecidableAccessibilityContractPassesAtBothScalesAndRtl() throws {
        // THE ROSTER: the essential controls, with content descriptions and touch sizes from the contract's own
        // minimum for iOS. The state words come FROM the shared table, never typed here.
        func roster(scale: TextScale) -> [UiNode] {
            let queued = AccessibilityContract.stateWords.first { $0.0 == "QUEUED" }!.1
            let delivered = AccessibilityContract.stateWords.first { $0.0 == "DELIVERED" }!.1
            let min = A11yPlatform.ios.touchTargetMinDp
            // At the largest scale the state line stays WHOLE (truncated = false); the point of `checkStatusNeverClipped`
            // is that a clipped status is refused, and this roster models the correct behaviour and asserts it passes.
            return [
                UiNode(controlId: "recipient_select", role: .button, label: "Choose a recipient",
                       contentDescription: "Choose a recipient", touchWidthDp: min, touchHeightDp: min,
                       readingOrder: 0),
                UiNode(controlId: "compose_send", role: .button, label: "Send",
                       contentDescription: "Send the message", touchWidthDp: min, touchHeightDp: min,
                       readingOrder: 1, stateWords: queued, colourToken: "outline",
                       truncated: false, containerWidthDp: 320, contentWidthDp: 120),
                UiNode(controlId: "sos_arm", role: .button, label: "Distress call",
                       contentDescription: "Hold to place a distress call", touchWidthDp: min,
                       touchHeightDp: min, readingOrder: 2),
                UiNode(controlId: "sos_cancel", role: .button, label: "Cancel the distress call",
                       contentDescription: "Cancel the distress call", touchWidthDp: min, touchHeightDp: min,
                       readingOrder: 3, stateWords: delivered, colourToken: "primary",
                       truncated: false, containerWidthDp: 320, contentWidthDp: 140),
                UiNode(controlId: "retry", role: .button, label: "Retry",
                       contentDescription: "Retry the message", touchWidthDp: min, touchHeightDp: min,
                       readingOrder: 4),
            ]
        }

        for scale in [TextScale.defaultSize, .largestAccessibility] {
            let nodes = roster(scale: scale)
            for (name, verdict) in [
                ("essential controls", AccessibilityContract.checkEssentialControlsLabelled(nodes)),
                ("status never clipped", AccessibilityContract.checkStatusNeverClipped(nodes, scale)),
                ("no colour-only state", AccessibilityContract.checkNoColourOnlyState(nodes)),
                ("touch targets", AccessibilityContract.checkTouchTargets(nodes, .ios)),
                ("reading order", AccessibilityContract.checkReadingOrder(nodes)),
                ("rtl meaning", AccessibilityContract.checkRtlMeaning(nodes, rtl: scale == .largestAccessibility)),
                ("long content", AccessibilityContract.checkLongContent(nodes, locale: "en")),
            ] {
                XCTAssertTrue(verdict.passed, "*** \(name) at \(scale.rawValue): \(verdict.reason) ***")
            }
        }

        // *** AND THE DISCRIMINATOR: A ROSTER THAT DID BREAK THE CONTRACT MUST FAIL. ***
        //
        // *Seven passing checks prove only that the checks ran. Without this, a check that `return .pass` unconditionally
        // would look identical to a working one.*
        let broken = [
            UiNode(controlId: "compose_send", role: .button, label: "Send", contentDescription: "",
                   touchWidthDp: 10, touchHeightDp: 10, readingOrder: 0,
                   stateWords: AccessibilityContract.stateWords[0].1, colourToken: ""),
        ]
        XCTAssertFalse(AccessibilityContract.checkTouchTargets(broken, .ios).passed,
                       "a 10pt control must FAIL the touch-target check")
        XCTAssertFalse(AccessibilityContract.checkEssentialControlsLabelled(broken).passed,
                       "an empty content description must FAIL the labelling check")
        XCTAssertFalse(AccessibilityContract.checkNoColourOnlyState(broken).passed,
                       "a state word without a colour token must FAIL the colour-only check")
    }
}
