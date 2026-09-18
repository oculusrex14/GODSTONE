import Foundation

// ---------------------------------------------------------------------------
// T58 -- the iOS message and SOS journeys, the twin of T57's
// `io.godstone.app.mesh` layer.
//
// The card's path: user intent -> SwiftUI model -> MeshRuntime -> durable/verified
// state -> view. Like T56, this file liveth INSIDE the nonshipping GodstoneMesh
// module, so it bindeth the durable authority directly and the shipping app's
// messaging surface stayeth absent.
//
// The three laws are T57's, verbatim, because a status is not a platform:
//
//   1. A STATUS COMETH FROM THE DURABLE AUTHORITY. A Boolean `send` proveth only
//      that a radio took some bytes: a link-accepted message is ATTEMPTING at
//      best, and DELIVERED only when the intended recipient's authenticated ACK
//      committed. "Sent" is not a word this surface may use for an ATT acceptance.
//   2. NOTHING IS SECURE BEFORE THE TRUSTED KEY IS CONFIRMED -- a link that is up
//      is not security, and a peer merely pinned is not verified.
//   3. THE SOS ARM IS HELD, NOT TAPPED: arm-then-confirm, restored from the durable
//      row, with the relayed-copy limitation stated in words.
//
// And the iOS-specific laws this task owneth:
//
//   4. A SCENE PHASE CHANGEOVER RE-READETH; IT NEVER RESETTETH. Backgrounding and
//      foregrounding -- and a scene DISCARD -- re-project from the durable row, so
//      remaining work stayeth visible. (The card's named negative: resetting the
//      coordinator's UI only on cancel would hide work that a relaunch must show.)
//   5. A LOCKED PRIVATE STORE CLAIMETH NOTHING, and no gesture is half-applied
//      behind the lock screen.
// ---------------------------------------------------------------------------

/// The DIRECT compose bound: 400 UTF-8 BYTES, the same number as T57's.
public enum DirectComposePolicy {
    public static let maxBodyBytes: Int = 400

    public static func byteCount(_ body: String) -> Int {
        body.utf8.count
    }

    public static func isBlank(_ body: String) -> Bool {
        body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static func fits(_ body: String) -> Bool {
        byteCount(body) <= maxBodyBytes
    }

    /// The longest PREFIX that fits, cut on a CHARACTER boundary so a multi-byte
    /// character is never split into invalid UTF-8.
    public static func truncateToFit(_ body: String) -> String {
        if fits(body) { return body }
        var result = ""
        for character in body {
            let candidate = result + String(character)
            if byteCount(candidate) > maxBodyBytes { break }
            result = candidate
        }
        return result
    }
}

/// A status the screen may show, projected from the durable authority. The case
/// set is SHARED with the Android isle (T57), so the fixtures mean one thing.
public enum MessageStatus: String, Sendable, Equatable, CaseIterable {
    case queued = "QUEUED"
    case attempting = "ATTEMPTING"
    case delivered = "DELIVERED"
    case cancelled = "CANCELLED"
    case expired = "EXPIRED"
    case failed = "FAILED"

    /// True iff the screen may say a recipient received it.
    public var claimsDelivery: Bool { self == .delivered }
}

/// One conversation row, projected for the screen.
public struct MessageProjection: Sendable, Equatable {
    public let msgId: Data
    public let peerLabel: String
    public let body: String
    public let status: MessageStatus
    public let outgoing: Bool
    public let retryable: Bool
    public let authorityNote: String?
}

/// The trust state of the SELECTED recipient (the vocabulary is T56's).
public struct RecipientProjection: Sendable, Equatable {
    public let nodeId: Data
    public let label: String
    public let trust: ContactTrustLabel

    public var isVerified: Bool { trust == .verified }
    public var hasTrustedKey: Bool { trust == .verified || trust == .tofuUnverified }
}

/// The link's state, with the words the screen may use for it.
public enum LinkState: Sendable, Equatable {
    case offline
    case scanning
    /// A radio link is up to somebody -- NOT necessarily a trusted peer.
    case connected(peers: Int)
    case permissionDenied
    case unsupported

    /// The honest one-line explanation, or nil when nothing needeth saying.
    public var explanation: String? {
        switch self {
        case .offline:
            return "No radio link. Your message stays queued and is retried."
        case .scanning:
            return "Looking for peers nearby."
        case .connected:
            return nil
        case .permissionDenied:
            return "Godstone cannot reach the radio: the nearby-devices permission was denied. "
                + "Messages stay queued until it is granted in Settings."
        case .unsupported:
            return "This device's Bluetooth is off or unsupported, so messages cannot leave it. "
                + "They stay queued on this phone."
        }
    }
}

/// The active-SOS projection: restored from the durable row, never from memory.
public struct SosProjection: Sendable, Equatable {
    public let msgId: Data
    public let status: MessageStatus
    public let relayCopiesMayBeOut: Bool

    /// The honest words for cancelling a call whose copies may already be out.
    public var cancelExplanation: String {
        relayCopiesMayBeOut
            ? "Cancelling stops this phone retrying. Copies already handed to relays cannot be recalled."
            : "Cancelling stops this phone retrying. No copy has left this device yet."
    }
}

/// Everything the user can ask for. The SAME intents the Android isle carrieth.
public enum MeshCommand: Sendable, Equatable {
    case refresh
    case selectRecipient(Data)
    case draft(String)
    case sendDirect
    case retry(Data)
    case armSos
    case confirmSos
    case disarmSos
    case cancelSos(Data)
    case restoreActiveSos
    case clearError
}

/// The scene phase, as the model seeth it (no UIKit import, so the model stayeth
/// host-testable; the app mapeth its own scenePhase onto this).
public enum MeshScenePhase: Sendable, Equatable {
    case active
    case inactive
    case background
}

/// The immutable projection the SwiftUI layer rendereth.
public struct MeshUIState: Sendable, Equatable {
    public let availability: TrustUnavailability
    public let link: LinkState
    public let scenePhase: MeshScenePhase
    public let recipients: [RecipientProjection]
    public let selectedRecipient: RecipientProjection?
    public let draft: String
    public let draftBytes: Int
    public let messages: [MessageProjection]
    public let sos: SosProjection?
    public let sosArmed: Bool
    public let error: String?
    public let lastOutcome: String?
    public let revision: UInt64

    public static let unavailable = MeshUIState(
        availability: .protectedDataUnavailable, link: .offline, scenePhase: .active,
        recipients: [], selectedRecipient: nil, draft: "", draftBytes: 0, messages: [],
        sos: nil, sosArmed: false, error: nil, lastOutcome: nil, revision: 0)

    public var isAvailable: Bool { availability == .available }

    /// True iff the compose control may send.
    public var canSend: Bool {
        selectedRecipient != nil && !DirectComposePolicy.isBlank(draft)
            && DirectComposePolicy.fits(draft)
    }

    /// True iff the screen may call this conversation secure: the key must have
    /// been CONFIRMED by the user. A link that is up is not enough.
    public var isSecure: Bool { selectedRecipient?.isVerified == true }

    public var securitySummary: String {
        guard let recipient = selectedRecipient else { return "No recipient selected." }
        switch recipient.trust {
        case .verified: return "Secure: you verified this contact's key yourself."
        case .tofuUnverified:
            return "Not verified: this contact's key was pinned on first use. "
                + "Comparing fingerprints is what maketh it secure."
        case .revoked: return "Blocked: this contact was revoked."
        default: return "No trusted key for this contact yet."
        }
    }

    public var bytesRemaining: Int { DirectComposePolicy.maxBodyBytes - draftBytes }

    /// VoiceOver: the spoken form of the whole surface.
    public func voiceSummary() -> String {
        var spoken: [String] = []
        if let explanation = link.explanation { spoken.append(explanation) }
        spoken.append(securitySummary)
        if let call = sos {
            spoken.append("An active call standeth: \(voiceLabel(for: call.status)). "
                          + call.cancelExplanation)
        } else if sosArmed {
            spoken.append("The distress control is held. Release to place the call.")
        }
        if messages.isEmpty {
            spoken.append("No messages yet.")
        } else {
            let undelivered = messages.filter { !$0.status.claimsDelivery }.count
            spoken.append("\(messages.count) messages, \(undelivered) not yet delivered.")
        }
        return spoken.joined(separator: " ")
    }
}

/// The spoken form of one status (VoiceOver, per row). "Sent" is deliberately
/// absent: an ATT acceptance is not a send.
public func voiceLabel(for status: MessageStatus) -> String {
    switch status {
    case .queued: return "queued on this phone; it will be retried"
    case .attempting: return "on its way; no answer yet"
    case .delivered: return "delivered: the recipient confirmed it"
    case .cancelled: return "cancelled"
    case .expired: return "expired before it could be delivered"
    case .failed: return "failed: the phone could not queue it"
    }
}

/// The spoken form of the SOS hold gesture (VoiceOver for a hold-to-confirm
/// control, which a screen reader cannot express as a gesture).
public enum SosAccessibility {
    public static let idleHint = "Hold to place a distress call. It takes two steps."
    public static let armedHint = "Armed. Confirm to place the call, or dismiss to cancel."
    public static let activeHint = "A call is active. Cancel stops this phone retrying only."
    public static let cancelLabel = "Cancel the distress call"
    public static let confirmLabel = "Confirm and place the distress call"
}

/// The outcome of asking the authority to send or retry.
public enum SendOutcome: Sendable, Equatable {
    /// Durably queued. NOT a delivery, and not even an attempt yet.
    case queued(Data)
    case refused(String)
}

public enum RetryOutcome: Sendable, Equatable {
    case accepted(Data)
    case refused(String)
}

public enum SosOutcome: Sendable, Equatable {
    case enqueued(Data)
    case cancelled(relayCopiesMayBeOut: Bool)
    case alreadyCancelled(relayCopiesMayBeOut: Bool?)
    case refused(String)
}

/// The mesh as the model seeth it. It is `internal` because it carrieth the mesh
/// module's own types; the PUBLIC surface is `MeshUXModel`.
protocol MeshAuthorityPort: AnyObject {
    func linkState() -> LinkState
    func recipients() -> [RecipientProjection]
    func messages() -> [MessageProjection]
    func activeSos() -> SosProjection?
    func sendDirect(recipientNodeId: Data, body: String) -> SendOutcome
    func retry(msgId: Data) -> RetryOutcome
    func beginSos(body: String) -> SosOutcome
    func cancelSos(msgId: Data) -> SosOutcome
}

// ---------------------------------------------------------------------------
// The MainActor model.
// ---------------------------------------------------------------------------

@MainActor
public final class MeshUXModel: ObservableObject {
    private let authority: MeshAuthorityPort
    private let protectedData: ProtectedDataGate

    // --------------------------------------------------------------------------------------
    // *** GS-UX-001 STEP 3 (round 540): **MAINACTOR OBSERVABLE STATE, CONSUMED BY SWIFTUI.** ***
    //
    // THE CARD'S OWN WORDS: *'Expose observable state: ... and MainActor observable state consumed by SwiftUI.
    // Refresh after durable events and lifecycle restoration, and unsubscribe when the owner ends.'*
    //
    // MEASURED BEFORE THIS EDIT: this class was `@MainActor` (so the card's FIRST half already stood) **AND
    // `ObservableObject` IT WAS NOT** -- it carried a private `state` and a SNAPSHOT accessor `uiState()`, and
    // NOTHING IN THE MODULE PUBLISHED A CHANGE TO SWIFTUI. **THE PRECEDENT ALREADY STOOD ON THIS ISLE:
    // `ArchiveSceneModel: ObservableObject` (`:111`) carrieth `@Published` state and IS the shipping Archive's
    // model. A CAPABILITY THE ISLE'S OWN ARCHIVE MODEL HATH IS ONE THIS MODEL NEVER WIRED.** ***
    //
    // THE SEAM IS VALUE-PRESERVING BY CONSTRUCTION: `state` becometh a COMPUTED PROPERTY OVER THE PUBLISHED ONE,
    // so every existing write (`state = ...`) still compileth, still carrieth the value, AND NOW PUBLISHETH --
    // **A MIGRATION THAT REWRITETH TWELVE CALL SITES IS ONE THAT CAN SILENTLY DROP ONE.** ***
    // --------------------------------------------------------------------------------------
    @Published public private(set) var observableState: MeshUIState

    private var state: MeshUIState {
        get { observableState }
        set { observableState = newValue }
    }

    init(authority: MeshAuthorityPort,
         protectedData: ProtectedDataGate = AlwaysAvailableProtectedData()) {
        self.authority = authority
        self.protectedData = protectedData
        self.observableState = .unavailable
        self.state = .unavailable
        self.state = project(lastOutcome: nil, error: nil)
    }

    public func uiState() -> MeshUIState { state }

    /// The recipient ids the surface may offer. The app injecteth the operator's
    /// selection; a court injecteth its fixture.
    public var knownRecipientIdsProvider: () -> [Data] = { [] }

    public func refresh() -> MeshUIState { project(lastOutcome: nil, error: nil) }

    /**
     * A SCENE PHASE CHANGEOVER. Law 4: this RE-READETH the durable authority and
     * never resetteth the surface. Remaining work stayeth visible through a
     * background/foreground cycle AND through a scene discard, which is exactly
     * what a coordinator that reseteth its UI on cancel would hide.
     */
    @discardableResult
    public func scenePhaseChanged(_ phase: MeshScenePhase) -> MeshUIState {
        state = MeshUIState(
            availability: state.availability, link: state.link, scenePhase: phase,
            recipients: state.recipients, selectedRecipient: state.selectedRecipient,
            draft: state.draft, draftBytes: state.draftBytes, messages: state.messages,
            sos: state.sos, sosArmed: state.sosArmed, error: state.error,
            lastOutcome: state.lastOutcome, revision: state.revision + 1)
        return project(lastOutcome: state.lastOutcome, error: state.error)
    }

    @discardableResult
    public func onCommand(_ command: MeshCommand) -> MeshUIState {
        // law 5: a locked private store claimeth nothing, and no gesture is
        // half-applied behind the lock screen
        if !protectedData.isProtectedDataAvailable() {
            switch command {
            // the model's OWN state may still be edited while locked: a draft is
            // not a claim about a durable fact, and losing a sentence the user
            // typed because the screen locked would be its own defect
            case .draft(let body):
                return handleDraft(body)
            case .refresh, .clearError, .armSos, .disarmSos:
                return project(lastOutcome: nil, error: nil)
            default:
                return project(lastOutcome: nil,
                               error: "the device is locked; unlock to review or send")
            }
        }

        switch command {
        case .refresh, .clearError:
            return project(lastOutcome: nil, error: nil)
        case .selectRecipient(let nodeId):
            return handleSelect(nodeId)
        case .draft(let body):
            return handleDraft(body)
        case .sendDirect:
            return handleSend()
        case .retry(let msgId):
            return handleRetry(msgId)
        case .armSos:
            state = stateCopy(sosArmed: true, error: nil)
            return state
        case .disarmSos:
            state = stateCopy(sosArmed: false, error: nil)
            return state
        case .confirmSos:
            return handleConfirmSos()
        case .cancelSos(let msgId):
            return handleCancelSos(msgId)
        case .restoreActiveSos:
            return handleRestore()
        }
    }

    // ---------------------------------------------------------------- handlers

    private func handleSelect(_ nodeId: Data) -> MeshUIState {
        guard let recipient = port().recipients().first(where: { $0.nodeId == nodeId }) else {
            return withError("that contact is not a selectable recipient")
        }
        // the SELECTION is the model's own state: the authority carrieth
        // recipients, not a choice of them
        state = stateCopy(selectedRecipient: recipient, error: nil)
        return project(lastOutcome: "recipient: " + recipient.label, error: nil)
    }

    private func handleDraft(_ body: String) -> MeshUIState {
        let bytes = DirectComposePolicy.byteCount(body)
        if bytes > DirectComposePolicy.maxBodyBytes {
            return withError("that message is \(bytes) bytes; the limit is "
                             + "\(DirectComposePolicy.maxBodyBytes) bytes of UTF-8")
        }
        state = stateCopy(draft: body, draftBytes: bytes, error: nil)
        return state
    }

    private func handleSend() -> MeshUIState {
        guard let recipient = state.selectedRecipient else {
            return withError("choose a recipient first")
        }
        if DirectComposePolicy.isBlank(state.draft) {
            return withError("there is nothing to send")
        }
        if !DirectComposePolicy.fits(state.draft) {
            return withError("that message is over the \(DirectComposePolicy.maxBodyBytes)-byte limit")
        }
        switch port().sendDirect(recipientNodeId: recipient.nodeId, body: state.draft) {
        case .refused(let reason):
            return withAuthorityError("send refused: " + reason)
        case .queued:
            // law 1: the outcome is "queued", NOT "sent" and NOT "delivered"
            state = stateCopy(draft: "", draftBytes: 0)
            return project(lastOutcome: "queued for " + recipient.label, error: nil)
        }
    }

    private func handleRetry(_ msgId: Data) -> MeshUIState {
        guard msgId.count == 16 else { return withError("that message is not addressable") }
        guard let known = state.messages.first(where: { $0.msgId == msgId }) else {
            return withError("no such message")
        }
        guard known.retryable else {
            return withError("that message cannot be retried from its current state")
        }
        switch port().retry(msgId: msgId) {
        case .refused(let reason):
            return withAuthorityError("retry refused: " + reason)
        case .accepted:
            return project(lastOutcome: "retrying", error: nil)
        }
    }

    private func handleConfirmSos() -> MeshUIState {
        // law 3: the confirm is refused unless the control was armed first
        guard state.sosArmed else {
            return withError("hold the SOS control to place a call")
        }
        switch port().beginSos(body: Self.sosBody) {
        case .refused(let reason):
            return withAuthorityError("the call could not be placed: " + reason)
        case .enqueued:
            return project(lastOutcome: "distress call queued on this phone", error: nil)
        case .cancelled, .alreadyCancelled:
            return withAuthorityError("the call could not be placed")
        }
    }

    private func handleCancelSos(_ msgId: Data) -> MeshUIState {
        guard msgId.count == 16 else { return withError("that call is not addressable") }
        guard let active = state.sos, active.msgId == msgId else {
            return withError("there is no such active call")
        }
        switch port().cancelSos(msgId: msgId) {
        case .refused(let reason):
            return withAuthorityError("cancel refused: " + reason)
        case .cancelled(let mayBeOut):
            return project(
                lastOutcome: mayBeOut
                    ? "call cancelled; copies already handed to relays cannot be recalled"
                    : "call cancelled; no copy had left this device",
                error: nil)
        case .alreadyCancelled:
            return project(lastOutcome: "that call was already cancelled", error: nil)
        case .enqueued:
            return project(lastOutcome: "call stands", error: nil)
        }
    }

    private func handleRestore() -> MeshUIState {
        if port().activeSos() == nil {
            return project(lastOutcome: "no active call", error: nil)
        }
        return project(lastOutcome: "active call restored from this phone's record", error: nil)
    }

    // ---------------------------------------------------------------- projection

    private func port() -> MeshAuthorityPort { authority }

    /// Law 5 first, then law 1: the ONE read of the authority.
    private func project(lastOutcome: String?, error: String?) -> MeshUIState {
        guard protectedData.isProtectedDataAvailable() else {
            // NOTHING about the durable estate is claimed -- no recipient list, no
            // message, no call -- but the model's own draft and SELECTION survive:
            // they are the user's working state, not a claim about a store
            // the user's CHOICE surviveth the lock, but its TRUST claim does not:
            // while the trust store is unreadable the selection carrieth no verdict,
            // so the security chip can never say Secure behind the lock screen
            let lockedSelection = state.selectedRecipient.map {
                RecipientProjection(nodeId: $0.nodeId, label: $0.label, trust: .unknown)
            }
            let locked = MeshUIState(
                availability: .protectedDataUnavailable, link: state.link,
                scenePhase: state.scenePhase, recipients: [],
                selectedRecipient: lockedSelection,
                draft: state.draft, draftBytes: state.draftBytes, messages: [], sos: nil,
                sosArmed: state.sosArmed, error: error, lastOutcome: lastOutcome,
                revision: state.revision + 1)
            state = locked
            return locked
        }

        let recipients = port().recipients()
        let selected = state.selectedRecipient.flatMap { previous in
            recipients.first { $0.nodeId == previous.nodeId }
        }
        let next = MeshUIState(
            availability: .available, link: port().linkState(), scenePhase: state.scenePhase,
            recipients: recipients, selectedRecipient: selected, draft: state.draft,
            draftBytes: state.draftBytes, messages: port().messages(),
            sos: port().activeSos(), sosArmed: state.sosArmed, error: error,
            lastOutcome: lastOutcome, revision: state.revision + 1)
        state = next
        return next
    }

    /// A copy with the model's OWN fields changed; the authority is not consulted.
    private func stateCopy(selectedRecipient: RecipientProjection? = nil,
                           draft: String? = nil, draftBytes: Int? = nil,
                           sosArmed: Bool? = nil, error: String? = nil) -> MeshUIState {
        MeshUIState(
            availability: state.availability, link: state.link, scenePhase: state.scenePhase,
            recipients: state.recipients,
            selectedRecipient: selectedRecipient ?? state.selectedRecipient,
            draft: draft ?? state.draft, draftBytes: draftBytes ?? state.draftBytes,
            messages: state.messages, sos: state.sos,
            sosArmed: sosArmed ?? state.sosArmed, error: error, lastOutcome: nil,
            revision: state.revision + 1)
    }

    private func withError(_ message: String) -> MeshUIState {
        state = stateCopy(error: message)
        return state
    }

    private func withAuthorityError(_ message: String) -> MeshUIState {
        project(lastOutcome: nil, error: message)
    }

    /// The broadcast body: no free text, no private detail.
    public static let sosBody: String = "SOS"
}
