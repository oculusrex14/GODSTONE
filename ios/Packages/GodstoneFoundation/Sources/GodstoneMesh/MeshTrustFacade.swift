import Foundation
import GodstoneCore

/// Public facade for trust surface operations in GodstoneMesh.
///
/// Owns the internal `TrustAuthorityAdapter` and the `TrustUXModel`.
/// Exposes ONLY plain Swift types (`String`, `[String]`, `Bool`, `Data?`)
/// without exposing `TrustAuthorityPort` or any internal mesh authority ports.
public final class MeshTrustFacade: @unchecked Sendable {
    internal let adapter: TrustAuthorityAdapter
    private let ownNodeId: Data

    private let lock = NSLock()
    private var labelToNodeId: [String: Data] = [:]
    private var nodeIdToLabel: [Data: String] = [:]
    private var _model: TrustUXModel?

    init(
        repository: PeerIdentityRepository,
        ownNodeId: Data,
        contacts: [(label: String, nodeId: Data)] = [],
        wipeHandler: (() -> Void)? = nil,
        sessionInvalidator: ((Data) -> Void)? = nil
    ) {
        self.ownNodeId = ownNodeId
        self.adapter = TrustAuthorityAdapter(
            repository: repository,
            wipeHandler: wipeHandler,
            sessionInvalidator: sessionInvalidator
        )
        for c in contacts {
            self.labelToNodeId[c.label] = c.nodeId
            self.nodeIdToLabel[c.nodeId] = c.label
        }
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                _ = self.ensureModelIsolated()
            }
        }
    }

    @MainActor
    private func ensureModelIsolated() -> TrustUXModel {
        if let existing = _model { return existing }
        let m = TrustUXModel(authority: adapter, ownNodeId: ownNodeId)
        m.knownContactIdsProvider = { [weak self] in
            guard let self = self else { return [] }
            self.lock.lock()
            defer { self.lock.unlock() }
            return Array(self.nodeIdToLabel.keys)
        }
        _ = m.refresh()
        _model = m
        return m
    }

    /// *** THE UNDERLYING MODEL, KEPT INTERNAL -- AND NARROWED DELIBERATELY. ***
    ///
    /// *The agent left this `public`, which WIDENED the module's surface beyond what anything
    /// reads: `grep` over `LabRuntime` and every LabMesh view found NO consumer of
    /// `facade.model`. **`TrustUXModel` is itself a public type, so this is not a leak of an
    /// internal port -- but an unused public accessor is still surface a caller can come to
    /// depend on, and the mission's rule is that the facade is what consumers use.** The
    /// facade's own verbs (`fingerprint`, `compareAndConfirm`, `approveRotation`, `revoke`,
    /// `contactTrust`, ...) are the intended road, and they exist so that no caller needs the
    /// model. If a future consumer genuinely needs it, widen this deliberately and say why.*
    @MainActor
    internal var model: TrustUXModel {
        ensureModelIsolated()
    }

    private func executeOnMain<T>(_ block: @MainActor () -> T) -> T {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { block() }
        } else {
            return DispatchQueue.main.sync {
                MainActor.assumeIsolated { block() }
            }
        }
    }

    /// Register a contact mapping between a human-readable label and a 16-byte nodeId.
    public func registerContact(label: String, nodeId: Data) {
        lock.lock()
        labelToNodeId[label] = nodeId
        nodeIdToLabel[nodeId] = label
        lock.unlock()
        executeOnMain {
            _ = self.ensureModelIsolated().refresh()
        }
    }

    /// The list of known contact labels.
    public func contactLabels() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(labelToNodeId.keys).sorted()
    }

    /// Resolve a label or hex representation to a 16-byte nodeId.
    public func resolveNodeId(_ labelOrHex: String) -> Data? {
        lock.lock()
        if let direct = labelToNodeId[labelOrHex] {
            lock.unlock()
            return direct
        }
        lock.unlock()

        // Try decoding as 32-hex-character (16-byte) string
        if labelOrHex.count == 32, labelOrHex.allSatisfy({ $0.isHexDigit }) {
            var data = Data()
            var index = labelOrHex.startIndex
            while index < labelOrHex.endIndex {
                let nextIndex = labelOrHex.index(index, offsetBy: 2)
                if let byte = UInt8(labelOrHex[index..<nextIndex], radix: 16) {
                    data.append(byte)
                } else {
                    break
                }
                index = nextIndex
            }
            if data.count == 16 { return data }
        }

        // Check if any projected contact has this label
        return executeOnMain {
            for contact in self.ensureModelIsolated().uiState().contacts {
                if contact.label == labelOrHex {
                    return contact.nodeId
                }
            }
            return nil
        }
    }

    /// The rendered hex fingerprint of a contact, or nil if not found.
    public func fingerprint(for label: String) -> String? {
        guard let nodeId = resolveNodeId(label) else { return nil }
        let fromModel: String? = executeOnMain {
            self.ensureModelIsolated().uiState().contact(nodeId)?.fingerprintHex
        }
        if let fromModel = fromModel {
            return fromModel
        }
        // Fall back to direct repository lookup
        switch adapter.lookup(nodeId) {
        case .verified(let identity):
            return ExactRotationCandidateRef.digestHex(identity.acceptedStaticDhPublicKey)
        case .quarantined(let pending):
            return ExactRotationCandidateRef.digestHex(pending.acceptedStaticDhPublicKey)
        default:
            return nil
        }
    }

    /// The human-readable trust status string for a contact.
    public func contactTrust(label: String) -> String {
        guard let nodeId = resolveNodeId(label) else { return "unknown" }
        let fromModel: String? = executeOnMain {
            self.ensureModelIsolated().uiState().contact(nodeId)?.trust.rawValue
        }
        if let fromModel = fromModel {
            return fromModel
        }
        switch adapter.lookup(nodeId) {
        case .verified(let identity):
            return identity.trustLevel == .userVerified ? "USER_VERIFIED" : "TOFU_UNVERIFIED"
        case .quarantined:
            return "ROTATION_PENDING"
        case .revoked:
            return "REVOKED"
        default:
            return "unknown"
        }
    }

    /// Whether the contact is verified.
    public func isVerified(label: String) -> Bool {
        guard let nodeId = resolveNodeId(label) else { return false }
        return executeOnMain {
            self.ensureModelIsolated().uiState().contact(nodeId)?.isVerified ?? false
        }
    }

    /// Whether the contact is revoked.
    public func isRevoked(label: String) -> Bool {
        guard let nodeId = resolveNodeId(label) else { return false }
        let fromModel: Bool? = executeOnMain {
            if let contact = self.ensureModelIsolated().uiState().contact(nodeId) {
                return contact.trust == .revoked
            }
            return nil
        }
        if let fromModel = fromModel { return fromModel }
        if case .revoked = adapter.lookup(nodeId) { return true }
        return false
    }

    /// Whether a rotation is pending for this contact.
    public func isRotationPending(label: String) -> Bool {
        guard let nodeId = resolveNodeId(label) else { return false }
        return executeOnMain {
            self.ensureModelIsolated().uiState().contact(nodeId)?.pendingRotation != nil
        }
    }

    /// Compare and confirm a fingerprint for a contact.
    /// Returns an outcome description string ("applied: ..." or "refused: ...").
    public func compareAndConfirm(label: String, displayedFingerprintHex: String) -> String {
        guard let nodeId = resolveNodeId(label) else {
            return "refused: unknown contact label '\(label)'"
        }
        return executeOnMain {
            let outcomeState = self.ensureModelIsolated().onCommand(
                .compareAndConfirmFingerprint(nodeId: nodeId, displayedFingerprintHex: displayedFingerprintHex)
            )
            if let error = outcomeState.error {
                return "refused: " + error
            }
            if let outcome = outcomeState.lastOutcome {
                return "applied: " + outcome
            }
            return "applied"
        }
    }

    /// *** GS-UX-001 `rendered-controls`: THE CANDIDATE THE SCREEN DISPLAYED, HANDED BACK AS A REF. ***
    ///
    /// *THE DEFECT THIS CLOSES, MEASURED BEFORE THE EDIT: the only road to an approval was
    /// `approveRotation(for label:)`, WHICH TOOK A **LABEL**, RE-READ "the current" pending candidate inside the
    /// call and approved WHATEVER IT FOUND. So the ref the screen displayed was never the thing approved -- a
    /// rotation that MOVED BETWEEN RENDER AND TAP was silently approved by the label road, and the model's own law
    /// 3 ("THE DISPLAYED CANDIDATE IS THE ONE APPROVED", `TrustUXModel.swift:26-30`) had no rendered consumer at
    /// all.* **A CONTROL THAT NAMES A CONTACT INSTEAD OF THE CANDIDATE IT SHOWED IS A CONTROL THAT CANNOT REFUSE A
    /// RACE.***
    ///
    /// **THE PRODUCTION ROAD IS TWO VERBS NOW, AND THE REF TRAVELS BETWEEN THEM:** the view reads the candidate
    /// ONCE (this call, which refresheth so what it returneth is what the authority currently standeth on), holds
    /// it in `@State`, and hands THAT SAME REF to `approveDisplayedRotation(_:)` -- which carries no label, reads
    /// nothing, and re-resolves nothing. *The durable CAS then bindeth on the node, the generation AND the pending
    /// key digest, so a candidate that moved is refused rather than substituted.*
    ///
    /// Returns nil when the contact is unknown or carrieth no pending rotation (the view renders a refusal; it never
    /// invents a candidate).
    public func displayedRotationCandidate(for label: String) -> ExactRotationCandidateRef? {
        guard let nodeId = resolveNodeId(label) else { return nil }
        return executeOnMain {
            let model = self.ensureModelIsolated()
            // ONE refresh, so what is returned IS what the authority standeth on right now.
            _ = model.refresh()
            return model.uiState().contact(nodeId)?.pendingRotation
        }
    }

    /// *** APPROVE THE EXACT CANDIDATE THE SCREEN SHOWED -- NO LABEL, NO RESOLVE, NO REFRESH. ***
    ///
    /// *The ref carrieth node id, pending generation AND the pending static key, and it is forwarded UNCHANGED into
    /// the existing durable CAS (`TrustUXModel.handleApprove` -> `TrustAuthorityAdapter.approvePendingRotation` ->
    /// `PeerIdentityRepository.approvePendingRotation`). **NOTHING HERE RE-READS "the current" candidate**, which is
    /// the whole difference from the deleted label road.*
    ///
    /// `.staleCandidate` maps to the card's own words -- `refused: that rotation is no longer pending: nothing was
    /// approved` -- so a rendered arm can bind the EXACT string rather than "something changed".
    public func approveDisplayedRotation(_ candidate: ExactRotationCandidateRef) -> String {
        executeOnMain {
            // LAW 3: THE DISPLAYED REF TRAVELS; nothing here re-readeth "the current" one.
            let outcomeState = self.ensureModelIsolated().onCommand(.approveRotation(candidate))
            if let error = outcomeState.error {
                return "refused: " + error
            }
            if let outcome = outcomeState.lastOutcome {
                return "applied: " + outcome
            }
            return "applied: rotation approved"
        }
    }

    /// Revoke a contact and invalidate its sessions.
    /// Returns an outcome description string ("applied: ..." or "refused: ...").
    public func revoke(label: String) -> String {
        guard let nodeId = resolveNodeId(label) else {
            return "refused: unknown contact label '\(label)'"
        }
        return executeOnMain {
            let outcomeState = self.ensureModelIsolated().onCommand(.revoke(nodeId))
            if let error = outcomeState.error {
                return "refused: " + error
            }
            if let outcome = outcomeState.lastOutcome {
                return "applied: " + outcome
            }
            return "applied: revoked"
        }
    }

    /// The last outcome reported by the trust model.
    public func lastOutcome() -> String? {
        executeOnMain {
            self.ensureModelIsolated().uiState().lastOutcome
        }
    }

    /// The last error reported by the trust model.
    public func lastError() -> String? {
        executeOnMain {
            self.ensureModelIsolated().uiState().error
        }
    }

    /// Refresh model projection.
    public func refresh() {
        executeOnMain {
            _ = self.ensureModelIsolated().refresh()
        }
    }
}
