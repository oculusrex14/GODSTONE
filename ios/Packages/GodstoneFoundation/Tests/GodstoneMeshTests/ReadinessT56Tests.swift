// T56 readiness court (iOS isle) -- the identity, rotation and wipe UX.
//
// The twin of T55's court, with the SAME fixture values and the SAME vocabulary,
// so the two isles provably speak one set of trust semantics.
//
// The model is driveth against a DETERMINISTIC authority that mirrors
// `PeerIdentityRepository`'s CAS semantics exactly: an approval is refused unless
// it carrieth the generation AND the key the pending row holdeth, and a
// fingerprint confirmation promoteth nothing unless the digest is the durable one.
// That is what letteth the card's named semantic negative -- "Show USER_VERIFIED
// before durable CAS succeeds" -- be EXECUTED rather than argued.
//
// No device behaviour is claimed: the protected-data gate is a seam the app binds
// to the real platform state, the physical matrix stays external (T73-T75), and
// readiness stays false.
import XCTest
@testable import GodstoneMesh

// -------------------------- the SHARED fixtures (both isles) ----------------
//
// These exact values appear in T55's court as well, and W13 asserteth that they
// still do: one set of contact/rotation fixtures, two isles.
private enum SharedTrustFixture {
    static let verifiedSeed: UInt8 = 0x50
    static let verifiedGeneration: UInt32 = 1
    static let elderGeneration: UInt32 = 2
    static let newerGeneration: UInt32 = 3
    static let tofuSeed: UInt8 = 0x40
    static let pendingKeySeed: UInt8 = 0x60

    static func nodeId(_ seed: UInt8) -> Data {
        Data((0..<16).map { UInt8((Int($0) + Int(seed)) & 0xFF) })
    }

    static func keyDigest(_ seed: UInt8) -> String {
        ExactRotationCandidateRef.digestHex(
            Data((0..<32).map { UInt8((Int($0) + Int(seed)) & 0xFF) }))
    }
}

/// The durable authority's SEMANTICS, faithfully mirrored.
fileprivate final class AuthorityDouble: TrustAuthorityPort, @unchecked Sendable {
    fileprivate final class Row {
        let nodeId: Data
        var trust: ContactTrustLabel
        var acceptedGeneration: UInt32
        var acceptedKeyDigest: String
        var pending: ExactRotationCandidateRef?
        /// The pending static KEY itself (the CAS's second operand); the ref's
        /// digest is DERIVED from these bytes, never the other way round.
        var pendingStaticKey: Data?
        let staticDh: Data
        init(nodeId: Data, trust: ContactTrustLabel, acceptedGeneration: UInt32,
             acceptedKeyDigest: String, staticDh: Data, pending: ExactRotationCandidateRef? = nil) {
            self.nodeId = nodeId; self.trust = trust
            self.acceptedGeneration = acceptedGeneration
            self.acceptedKeyDigest = acceptedKeyDigest; self.staticDh = staticDh
            self.pending = pending
        }
    }

    private var rows: [Data: Row] = [:]
    var wipe: WipeProgressState = .idle
    var wipedSessions: [Data] = []
    var confirmRefusals = false
    var storageFails = false

    @discardableResult
    fileprivate func seedVerified(_ seed: UInt8, generation: UInt32 = SharedTrustFixture.verifiedGeneration) -> Row {
        let staticDh = Data((0..<32).map { UInt8((Int($0) + Int(seed)) & 0xFF) })
        let row = Row(nodeId: SharedTrustFixture.nodeId(seed), trust: .verified,
                      acceptedGeneration: generation,
                      acceptedKeyDigest: ExactRotationCandidateRef.digestHex(staticDh),
                      staticDh: staticDh)
        rows[row.nodeId] = row
        return row
    }

    @discardableResult
    fileprivate func seedTofu(_ seed: UInt8) -> Row {
        let staticDh = Data((0..<32).map { UInt8((Int($0) + Int(seed)) & 0xFF) })
        let row = Row(nodeId: SharedTrustFixture.nodeId(seed), trust: .tofuUnverified,
                      acceptedGeneration: 1,
                      acceptedKeyDigest: ExactRotationCandidateRef.digestHex(staticDh),
                      staticDh: staticDh)
        rows[row.nodeId] = row
        return row
    }

    @discardableResult
    fileprivate func offerRotation(_ nodeId: Data, generation: UInt32,
                                   keySeed: UInt8) -> ExactRotationCandidateRef {
        let pendingKey = Data((0..<32).map { UInt8((Int($0) + Int(keySeed)) & 0xFF) })
        let ref = ExactRotationCandidateRef(
            nodeId: nodeId, pendingGeneration: generation,
            pendingStaticDhPublicKey: pendingKey)
        rows[nodeId]?.pending = ref
        rows[nodeId]?.pendingStaticKey = pendingKey
        rows[nodeId]?.trust = .rotationPending
        return ref
    }

    func lookup(_ nodeId: Data) -> PeerIdentityLookup {
        guard let row = rows[nodeId] else { return .notFound }
        if storageFails { return .storageFailure }
        switch row.trust {
        case .revoked: return .revoked
        case .rotationPending:
            return .quarantined(PendingPeerIdentity.testFixture(
                nodeId: row.nodeId, staticDh: row.staticDh,
                acceptedGeneration: row.acceptedGeneration,
                pendingStatic: row.pendingStaticKey ?? Data(),
                pendingGeneration: row.pending!.pendingGeneration))
        default:
            return .verified(VerifiedPeerIdentity.testFixture(
                nodeId: row.nodeId, staticDh: row.staticDh,
                acceptedGeneration: row.acceptedGeneration,
                trustLevel: row.trust == .verified ? .userVerified : .tofuPinned))
        }
    }

    func approvePendingRotation(nodeId: Data, expectedPendingGeneration: UInt32,
                                expectedPendingStaticDhPublicKey: Data) -> RotationApprovalResult {
        guard let row = rows[nodeId] else { return .peerNotFound }
        if row.trust == .revoked { return .rejectedRevoked }
        guard let pending = row.pending else { return .noPendingCandidate }
        // THE CAS: generation AND key, both, or nothing happens
        if pending.pendingGeneration != expectedPendingGeneration {
            return .staleCandidate
        }
        if expectedPendingStaticDhPublicKey != pending.pendingStaticDhPublicKey {
            return .staleCandidate
        }
        row.acceptedGeneration = pending.pendingGeneration
        row.acceptedKeyDigest = pending.pendingKeyDigestHex
        row.trust = .verified
        row.pending = nil
        return .approved(VerifiedPeerIdentity.testFixture(
            nodeId: row.nodeId, staticDh: row.staticDh,
            acceptedGeneration: row.acceptedGeneration, trustLevel: .userVerified))
    }

    func confirmVerified(nodeId: Data, fingerprintHex: String) -> ConfirmOutcome {
        guard let row = rows[nodeId] else { return .peerNotFound }
        if confirmRefusals { return .refused("the durable store refused the confirmation") }
        if row.trust == .verified { return .alreadyVerified }
        if row.trust == .revoked { return .refused("revoked") }
        if row.acceptedKeyDigest.lowercased() != fingerprintHex.lowercased() {
            return .mismatch
        }
        row.trust = .verified
        return .confirmed(nodeId: nodeId, acceptedGeneration: row.acceptedGeneration)
    }

    func revokePeer(_ nodeId: Data) -> RevokeResult {
        guard let row = rows[nodeId] else { return .peerNotFound }
        if row.trust == .revoked { return .alreadyRevoked }
        row.trust = .revoked
        row.pending = nil
        return .revoked
    }

    func applyBinding(nodeId: Data, staticDhPublicKey: Data, signature: Data) -> BindingImportOutcome {
        if rows[nodeId] != nil { return .imported(nodeId: nodeId, label: "contact-rebound") }
        let row = Row(nodeId: nodeId, trust: .tofuUnverified, acceptedGeneration: 1,
                      acceptedKeyDigest: ExactRotationCandidateRef.digestHex(staticDhPublicKey),
                      staticDh: staticDhPublicKey)
        rows[nodeId] = row
        return .imported(nodeId: nodeId, label: "contact-" + ExactRotationCandidateRef.digestHex(nodeId).prefix(4).description)
    }

    func invalidateSessions(for nodeId: Data) { wipedSessions.append(nodeId) }

    func wipeState() -> WipeProgressState { wipe }
    func beginWipe() -> WipeProgressState {
        if case .inProgress = wipe { return wipe }
        wipe = .inProgress(stage: "erase_peer_trust", attempt: 1, resumable: true,
                           lastError: "the Keychain refused the deletion")
        return wipe
    }
    func resumeWipe() -> WipeProgressState {
        if case .inProgress = wipe { wipe = .complete }
        return wipe
    }

    fileprivate func row(_ nodeId: Data) -> Row? { rows[nodeId] }
}

// ------------------------------- the court ---------------------------------

@MainActor
final class ReadinessT56Tests: XCTestCase {
    private let plaintextPayload = Data("the river riseth at dawn and the bridge is under water".utf8)

    private func model(_ authority: AuthorityDouble,
                       protected: ProtectedDataGate = AlwaysAvailableProtectedData(),
                       contacts: [Data]) -> TrustUXModel {
        let built = TrustUXModel(authority: authority,
                                 ownNodeId: SharedTrustFixture.nodeId(0x20),
                                 protectedData: protected)
        built.knownContactIdsProvider = { contacts }
        _ = built.refresh()
        return built
    }

    // ------------------------------------------------------------ W01

    /// W01 -- one contact verified, and ONLY through the durable CAS. This is the
    /// card's named semantic negative: the UI may not read USER_VERIFIED before
    /// the authority saith so.
    func testW01UserVerifiedAppearethOnlyAfterTheDurableCas() {
        let authority = AuthorityDouble()
        let row = authority.seedTofu(SharedTrustFixture.tofuSeed)
        let built = model(authority, contacts: [row.nodeId])

        let before = built.uiState()
        XCTAssertEqual(before.contact(row.nodeId)?.trust, .tofuUnverified)
        XCTAssertTrue(before.verified.isEmpty, "nothing is verified before the CAS")
        XCTAssertEqual(before.tofu.count, 1)

        let after = built.onCommand(.compareAndConfirmFingerprint(
            nodeId: row.nodeId, displayedFingerprintHex: row.acceptedKeyDigest))
        XCTAssertEqual(after.contact(row.nodeId)?.trust, .verified)
        XCTAssertEqual(authority.row(row.nodeId)?.trust, .verified,
                       "the DURABLE row is what moved")
        XCTAssertNil(after.error)
        // the two labels never read alike, in words or in voice
        XCTAssertNotEqual(voiceLabel(for: .tofuUnverified), voiceLabel(for: .verified))
    }

    // ------------------------------------------------------------ W02

    /// W02 -- the named negative, executed directly: when the authority REFUSES
    /// the confirmation, the UI must NOT claim USER_VERIFIED.
    func testW02ARefusedCasNeverShowethUserVerified() {
        let authority = AuthorityDouble()
        let row = authority.seedTofu(SharedTrustFixture.tofuSeed)
        authority.confirmRefusals = true
        let built = model(authority, contacts: [row.nodeId])

        let refused = built.onCommand(.compareAndConfirmFingerprint(
            nodeId: row.nodeId, displayedFingerprintHex: row.acceptedKeyDigest))
        XCTAssertEqual(refused.contact(row.nodeId)?.trust, .tofuUnverified,
                       "the UI may not outrun the durable CAS")
        XCTAssertTrue(refused.verified.isEmpty)
        XCTAssertNotNil(refused.error)
        XCTAssertEqual(authority.row(row.nodeId)?.trust, .tofuUnverified,
                       "and the durable row did not move either")
    }

    // ------------------------------------------------------------ W03

    /// W03 -- competing rotation candidates: the DISPLAYED ref is what travels, and
    /// a rotation that moved is refused as stale.
    func testW03TheDisplayedCandidateIsTheOneApproved() {
        let authority = AuthorityDouble()
        let row = authority.seedVerified(SharedTrustFixture.verifiedSeed)
        let built = model(authority, contacts: [row.nodeId])

        let displayed = authority.offerRotation(row.nodeId,
                                                generation: SharedTrustFixture.elderGeneration,
                                                keySeed: SharedTrustFixture.pendingKeySeed)
        let rendered = built.refresh()
        XCTAssertEqual(rendered.contact(row.nodeId)?.pendingRotation, displayed,
                       "the view carrieth the exact ref it displayed")

        let newer = authority.offerRotation(row.nodeId,
                                            generation: SharedTrustFixture.newerGeneration,
                                            keySeed: 0x70)
        XCTAssertFalse(newer.sameCandidate(as: displayed))

        let refused = built.onCommand(.approveRotation(displayed))
        XCTAssertNotNil(refused.error)
        XCTAssertTrue((refused.error ?? "<no error was reported>").contains("no longer pending"))
        XCTAssertEqual(refused.contact(row.nodeId)?.pendingRotation, newer,
                       "the newer candidate standeth")
        XCTAssertEqual(authority.row(row.nodeId)?.acceptedGeneration,
                       SharedTrustFixture.verifiedGeneration,
                       "the old trust is untouched")

        // ... and a DISMISSAL approveth nothing
        let dismissed = built.onCommand(.dismissRotation(newer))
        XCTAssertEqual(dismissed.contact(row.nodeId)?.trust, .rotationPending)
        XCTAssertEqual(dismissed.contact(row.nodeId)?.pendingRotation, newer)

        // approving the ref the view NOW carrieth succeeds
        let approved = built.onCommand(.approveRotation(newer))
        XCTAssertEqual(approved.contact(row.nodeId)?.trust, .verified)
        XCTAssertEqual(authority.row(row.nodeId)?.acceptedGeneration,
                       SharedTrustFixture.newerGeneration)
        XCTAssertNil(approved.contact(row.nodeId)?.pendingRotation)
    }

    // ------------------------------------------------------------ W04

    /// W04 -- the LOCKED private store: nothing is claimed until unlock.
    func testW04ALockedPrivateStoreClaimethNothing() {
        let authority = AuthorityDouble()
        let row = authority.seedVerified(SharedTrustFixture.verifiedSeed)
        let gate = SwitchableProtectedData(available: false)
        let built = model(authority, protected: gate, contacts: [row.nodeId])

        let locked = built.uiState()
        XCTAssertEqual(locked.availability, .protectedDataUnavailable)
        XCTAssertTrue(locked.contacts.isEmpty, "not even a cached contact is claimed")
        XCTAssertNil(locked.own, "nor the own identity")
        XCTAssertTrue(locked.voiceSummary().contains("locked"))
        XCTAssertFalse(locked.isAvailable)

        // a mutating command while locked is refused, and the estate standeth
        let refused = built.onCommand(.revoke(row.nodeId))
        XCTAssertNotNil(refused.error)
        XCTAssertTrue((refused.error ?? "<no error was reported>").contains("locked"))
        XCTAssertEqual(authority.row(row.nodeId)?.trust, .verified)

        // after unlock the REAL estate appeareth
        gate.setAvailable(true)
        let unlocked = built.refresh()
        XCTAssertTrue(unlocked.isAvailable)
        XCTAssertEqual(unlocked.contacts.count, 1)
        XCTAssertNotNil(unlocked.own)

        // ... and locking AGAIN claimeth nothing, even though the previous
        // projection carrieth a contact and an identity: a stale cache is not an
        // estate, and this arm is what condemneth one being rendered as if it were
        gate.setAvailable(false)
        let relocked = built.refresh()
        XCTAssertEqual(relocked.availability, .protectedDataUnavailable)
        XCTAssertTrue(relocked.contacts.isEmpty, "the previous projection is NOT rendered")
        XCTAssertNil(relocked.own, "nor the previously shown identity")
    }

    // ------------------------------------------------------------ W05

    /// W05 -- a lock DURING a verification: no half-applied promotion.
    func testW05ALockDuringVerificationPromotethNothing() {
        let authority = AuthorityDouble()
        let row = authority.seedTofu(SharedTrustFixture.tofuSeed)
        let gate = SwitchableProtectedData(available: true)
        let built = model(authority, protected: gate, contacts: [row.nodeId])
        let fingerprint = row.acceptedKeyDigest

        gate.setAvailable(false)
        let whileLocked = built.onCommand(.compareAndConfirmFingerprint(
            nodeId: row.nodeId, displayedFingerprintHex: fingerprint))
        XCTAssertNotNil(whileLocked.error)
        // the refusal must be the LOCK'S refusal, not some incidental error: with
        // the lock check removed the command proceedeth and reports "no such
        // contact" instead, which this arm condemneth (its rod escaped until the
        // witness demanded the reason)
        XCTAssertTrue((whileLocked.error ?? "").contains("locked"),
                      "a locked attempt is refused BY THE LOCK: \(whileLocked.error ?? "")")
        XCTAssertEqual(authority.row(row.nodeId)?.trust, .tofuUnverified,
                       "the durable row is untouched by a locked attempt")

        gate.setAvailable(true)
        let afterUnlock = built.onCommand(.compareAndConfirmFingerprint(
            nodeId: row.nodeId, displayedFingerprintHex: fingerprint))
        XCTAssertEqual(afterUnlock.contact(row.nodeId)?.trust, .verified)
        XCTAssertNil(afterUnlock.error)
    }

    // ------------------------------------------------------------ W06

    /// W06 -- a SCENE RECREATION: a fresh model over the same estate says the same.
    func testW06ASceneRecreationReprojectsTheSameState() {
        let authority = AuthorityDouble()
        let row = authority.seedVerified(SharedTrustFixture.verifiedSeed)
        let pending = authority.offerRotation(row.nodeId, generation: 5, keySeed: 0x62)
        let first = model(authority, contacts: [row.nodeId])
        let firstState = first.uiState()

        let recreated = model(authority, contacts: [row.nodeId])
        let secondState = recreated.uiState()
        XCTAssertEqual(firstState.contacts.map { $0.trust }, secondState.contacts.map { $0.trust })
        XCTAssertEqual(firstState.contacts.map { $0.pendingRotation }, secondState.contacts.map { $0.pendingRotation })
        XCTAssertEqual(secondState.contact(row.nodeId)?.pendingRotation, pending)
        XCTAssertEqual(firstState.voiceSummary(), secondState.voiceSummary())
    }

    // ------------------------------------------------------------ W07

    /// W07 -- VOICE ACCESSIBILITY: every trust label speaketh a distinct form, and
    /// a verified contact is audibly distinguishable from a first-use one.
    func testW07VoiceLabelsDistinguishEveryTrustLevel() {
        let spoken = ContactTrustLabel.allCases.map { voiceLabel(for: $0) }
        XCTAssertEqual(Set(spoken).count, ContactTrustLabel.allCases.count,
                       "no two trust levels may sound alike")
        XCTAssertTrue(voiceLabel(for: .verified).contains("verified"))
        XCTAssertTrue(voiceLabel(for: .tofuUnverified).contains("not verified"))
        XCTAssertTrue(voiceLabel(for: .rotationPending).contains("new key"))
        XCTAssertTrue(voiceLabel(for: .revoked).contains("blocked"))

        let authority = AuthorityDouble()
        let verified = authority.seedVerified(SharedTrustFixture.verifiedSeed)
        let tofu = authority.seedTofu(SharedTrustFixture.tofuSeed)
        let built = model(authority, contacts: [verified.nodeId, tofu.nodeId])
        let summary = built.uiState().voiceSummary()
        XCTAssertTrue(summary.contains("1 verified"))
        XCTAssertTrue(summary.contains("first-use"))
    }

    // ------------------------------------------------------------ W08

    /// W08 -- a FAILED Keychain deletion stayeth resumable across a relaunch.
    func testW08AFailedWipeSurvivethARelaunch() {
        let authority = AuthorityDouble()
        authority.seedVerified(SharedTrustFixture.verifiedSeed)
        let built = model(authority, contacts: [])
        let begun = built.onCommand(.beginWipe)
        guard case .inProgress(let stage, let attempt, let resumable, let lastError) = begun.wipe else {
            return XCTFail("a wipe must be in progress, got \(begun.wipe)")
        }
        XCTAssertEqual(stage, "erase_peer_trust")
        XCTAssertEqual(attempt, 1)
        XCTAssertTrue(resumable, "a failed Keychain deletion MUST be resumable")
        XCTAssertNotNil(lastError)
        XCTAssertTrue(begun.wipe.blocksOrdinaryUse)

        // a RELAUNCH: a fresh model over the same journal
        let relaunched = model(authority, contacts: [])
        guard case .inProgress = relaunched.uiState().wipe else {
            return XCTFail("a relaunch must never report idle while the wipe standeth")
        }
        XCTAssertTrue(relaunched.uiState().wipe.isResumable)
        let resumed = relaunched.onCommand(.resumeWipe)
        XCTAssertEqual(resumed.wipe, .complete)
        XCTAssertFalse(resumed.wipe.blocksOrdinaryUse,
                       "a finished wipe is exactly when ordinary use may resume")
    }

    // ------------------------------------------------------------ W09

    /// W09 -- a STALE CONFIRMATION: confirming with an old fingerprint after a
    /// rotation promoteth nothing.
    func testW09AStaleConfirmationPromotethNothing() {
        // ARM 1 -- the DURABLE key rotated behind the user's back: the model's own
        // compare (against the projection) still matches, and the AUTHORITY's CAS
        // is what refuseth the stale confirmation
        let authority = AuthorityDouble()
        let row = authority.seedTofu(SharedTrustFixture.tofuSeed)
        let displayed = ExactRotationCandidateRef.digestHex(row.staticDh)
        row.acceptedKeyDigest = ExactRotationCandidateRef.digestHex(Data(repeating: 0x99, count: 32))
        let built = model(authority, contacts: [row.nodeId])
        let refusedByAuthority = built.onCommand(.compareAndConfirmFingerprint(
            nodeId: row.nodeId, displayedFingerprintHex: displayed))
        XCTAssertNotNil(refusedByAuthority.error)
        XCTAssertTrue((refusedByAuthority.error ?? "<no error was reported>").contains("not the one you compared"),
                      "the DURABLE CAS refuseth a stale confirmation: \((refusedByAuthority.error ?? "<no error was reported>"))")
        XCTAssertEqual(authority.row(row.nodeId)?.trust, .tofuUnverified)

        // ARM 2 -- the user reads out an OLD fingerprint: the model refuseth it
        // locally, before the authority is troubled at all
        let stale = model(authority, contacts: [row.nodeId])
        let refusedLocally = stale.onCommand(.compareAndConfirmFingerprint(
            nodeId: row.nodeId, displayedFingerprintHex: String(repeating: "0", count: 64)))
        XCTAssertNotNil(refusedLocally.error)
        XCTAssertTrue((refusedLocally.error ?? "<no error was reported>").contains("differ"))
        XCTAssertEqual(authority.row(row.nodeId)?.trust, .tofuUnverified)

        // a malformed digest is refused before anything is compared
        let malformed = built.onCommand(.compareAndConfirmFingerprint(
            nodeId: row.nodeId, displayedFingerprintHex: "zzzz"))
        XCTAssertNotNil(malformed.error)
        XCTAssertEqual(authority.row(row.nodeId)?.trust, .tofuUnverified)
    }

    // ------------------------------------------------------------ W10

    /// W10 -- rotation and revocation INVALIDATE the affected sessions.
    func testW10RotationAndRevocationInvalidateSessions() {
        let authority = AuthorityDouble()
        let row = authority.seedVerified(SharedTrustFixture.verifiedSeed)
        let built = model(authority, contacts: [row.nodeId])
        let candidate = authority.offerRotation(row.nodeId, generation: 7, keySeed: 0x71)
        _ = built.refresh()

        _ = built.onCommand(.approveRotation(candidate))
        XCTAssertEqual(authority.wipedSessions, [row.nodeId],
                       "an approved rotation invalidates the sessions the old key protected")

        let revoked = built.onCommand(.revoke(row.nodeId))
        XCTAssertEqual(revoked.contact(row.nodeId)?.trust, .revoked)
        XCTAssertEqual(authority.wipedSessions.count, 2, "revocation invalidates too")
        XCTAssertNil(revoked.contact(row.nodeId)?.pendingRotation)

        // an already-revoked contact is idempotent, and a late approval is refused
        let again = built.onCommand(.revoke(row.nodeId))
        XCTAssertTrue(again.lastOutcome!.contains("already revoked"))
        let late = built.onCommand(.approveRotation(candidate))
        XCTAssertNotNil(late.error)
    }

    // ------------------------------------------------------------ W11

    /// W11 -- NO BIOMETRIC SUBSTITUTION: the model carrieth no biometric road, and
    /// the only promotion path is the explicit fingerprint comparison.
    func testW11NoBiometricSuccessSubstitutesForPeerAuthentication() throws {
        var repo = URL(fileURLWithPath: #filePath)
        var hops = 0
        while repo.path != "/" && hops < 12 {
            if FileManager.default.fileExists(atPath: repo.appendingPathComponent("android").path) { break }
            repo.deleteLastPathComponent(); hops += 1
        }
        let source = repo.appendingPathComponent("ios/Godstone/Sources/GodstoneMesh/TrustUXModel.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        for forbidden in ["LAContext", "evaluatePolicy", "biometryType", "LocalAuthentication"] {
            XCTAssertFalse(text.contains(forbidden),
                           "no biometric road may stand in for peer authentication (\(forbidden))")
        }
        XCTAssertTrue(text.contains("compareAndConfirmFingerprint"),
                      "the explicit fingerprint comparison IS the promotion road")
        XCTAssertTrue(text.contains("confirmVerified"),
                      "and it runneth through the durable CAS")
    }

    // ------------------------------------------------------------ W12

    /// W12 -- the binding payload is bounded, exactly as on the Android isle.
    func testW12TheBindingPayloadIsBounded() {
        let authority = AuthorityDouble()
        let built = model(authority, contacts: [])
        let oversized = BindingPayloadPolicy.prefix
            + String(repeating: "A", count: BindingPayloadPolicy.maxPayloadChars * 40)
        XCTAssertGreaterThan(oversized.count, BindingPayloadPolicy.maxPayloadChars)

        for payload in ["", BindingPayloadPolicy.prefix,
                        BindingPayloadPolicy.prefix + "not*base64!",
                        BindingPayloadPolicy.prefix + "AAAA"] {
            let refused = built.onCommand(.importRecipientBinding(payload))
            XCTAssertNotNil(refused.error, "payload \(payload.prefix(12)) must be refused visibly")
        }
        // the OVERSIZED case must be refused BY THE SIZE BOUND, before any decoding:
        // without that reason the payload would be walked character by character
        let oversizedRefusal = built.onCommand(.importRecipientBinding(oversized))
        XCTAssertNotNil(oversizedRefusal.error)
        XCTAssertTrue((oversizedRefusal.error ?? "").contains("over the"),
                      "an oversized payload is refused by the BOUND: \(oversizedRefusal.error ?? "")")

        // a WELL-FORMED payload imports and lands on first-use trust
        let nodeId = SharedTrustFixture.nodeId(0x77)
        let rendered = BindingPayloadPolicy.render(
            nodeId: nodeId,
            staticDhPublicKey: Data(repeating: 0x44, count: 32),
            signature: Data(repeating: 0x55, count: 64))
        let imported = built.onCommand(.importRecipientBinding(rendered))
        XCTAssertNil(imported.error)
        XCTAssertEqual(imported.lastOutcome ?? "",
                       "imported contact-\(ExactRotationCandidateRef.digestHex(nodeId).prefix(4))")
    }

    // ------------------------------------------------------------ W13

    /// W13 -- SHARED FIXTURES and the durable contract. The two isles speak ONE set
    /// of trust semantics: this witness readeth T55's court and the durable
    /// authority's own source to prove it.
    func testW13TheIslesShareTheirFixturesAndTheCasContract() throws {
        var repo = URL(fileURLWithPath: #filePath)
        var hops = 0
        while repo.path != "/" && hops < 12 {
            if FileManager.default.fileExists(atPath: repo.appendingPathComponent("android").path) { break }
            repo.deleteLastPathComponent(); hops += 1
        }
        // the Android court's own fixture set
        let android = try String(contentsOf: repo.appendingPathComponent(
            "android/app/src/test/java/io/godstone/app/readiness/ReadinessT55Test.kt"), encoding: .utf8)
        for fixture in ["0x50", "0x40", "0x60", "2L", "3L"] {
            XCTAssertTrue(android.contains(fixture), "the Android fixtures carrieth \(fixture)")
        }
        // the same vocabulary on both isles
        let androidContracts = try String(contentsOf: repo.appendingPathComponent(
            "android/app/src/main/java/io/godstone/app/trust/TrustContracts.kt"), encoding: .utf8)
        for label in ["TOFU_UNVERIFIED", "USER_VERIFIED", "ROTATION_PENDING", "REVOKED", "CORRUPT"] {
            XCTAssertTrue(androidContracts.contains(label), "the Android labels carrieth \(label)")
            XCTAssertTrue(ContactTrustLabel.allCases.contains { $0.rawValue == label },
                          "and this isle must speak \(label) too")
        }
        // the durable authority's CAS is bound to node, generation AND key
        let repository = try String(contentsOf: repo.appendingPathComponent(
            "ios/Godstone/Sources/GodstoneMesh/PeerIdentityRepository.swift"), encoding: .utf8)
        XCTAssertTrue(repository.contains("func approvePendingRotation("))
        XCTAssertTrue(repository.contains("expectedPendingGeneration"))
        XCTAssertTrue(repository.contains("expectedPendingStaticDhPublicKey"))
        XCTAssertTrue(repository.contains("case staleCandidate"))
        // OPEN ITEM, asserted so it cannot be forgotten: this isle exposes no
        // durable road that promoteth a contact to userVerified. The model's
        // confirmation CAS is therefore exercised against the PORT's contract, and
        // the real promotion road remaineth unclaimed until an ADR defines it.
        XCTAssertFalse(repository.contains("func confirmUserVerified"),
                       "if this ever starteth passing, the iOS isle gained a durable "
                       + "confirmation road and T56's boundary must be revisited")
    }
}

// ------------------------- internal test fixtures ---------------------------

extension VerifiedPeerIdentity {
    static func testFixture(nodeId: Data, staticDh: Data, acceptedGeneration: UInt32,
                            trustLevel: PeerTrustLevel) -> VerifiedPeerIdentity {
        // the mesh module's own internal initializer: this court liveth inside the
        // module's test target, so it may build the durable projection directly
        VerifiedPeerIdentity.makeForTesting(nodeId: nodeId, staticDh: staticDh,
                                            acceptedGeneration: acceptedGeneration,
                                            trustLevel: trustLevel)
    }
}

extension PendingPeerIdentity {
    static func testFixture(nodeId: Data, staticDh: Data, acceptedGeneration: UInt32,
                            pendingStatic: Data, pendingGeneration: UInt32) -> PendingPeerIdentity {
        PendingPeerIdentity.makeForTesting(nodeId: nodeId, staticDh: staticDh,
                                           acceptedGeneration: acceptedGeneration,
                                           pendingStatic: pendingStatic,
                                           pendingGeneration: pendingGeneration)
    }
}
