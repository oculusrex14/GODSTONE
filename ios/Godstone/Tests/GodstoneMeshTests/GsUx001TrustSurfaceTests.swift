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

        // Step 3: Candidate changes in the repository to generation 8 behind user's back
        let b3 = makeBinding(seed: seedA, generation: 8, staticDhPriv: staticPrivC)
        let res3 = repo.applyValidatedBinding(b3)
        XCTAssertEqual(res3, .keyChangedQuarantined)

        // Step 4: User approves the displayed generation 6 candidate
        // (the facade's model has candidate generation 6 cached from when it was displayed)
        let approveOutcome = facade.approveRotation(for: "Alice")

        // Repository CAS refuses stale candidate
        XCTAssertTrue(approveOutcome.hasPrefix("refused:"), "Stale approval must be refused: \(approveOutcome)")
        XCTAssertTrue(
            approveOutcome.contains("no longer pending"),
            "Expected stale candidate explanation: \(approveOutcome)"
        )

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
}
