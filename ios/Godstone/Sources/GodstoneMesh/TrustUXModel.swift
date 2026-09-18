import Foundation

// ---------------------------------------------------------------------------
// T56 -- the iOS identity, rotation and wipe UX model, the twin of T55's
// `io.godstone.app.trust` layer.
//
// The card's path: user intent -> SwiftUI model -> MeshRuntime -> durable/verified
// state -> view. This file liveth INSIDE the nonshipping GodstoneMesh module
// (which the LIGHT app never links and the lab doeth), which is why it can bind
// the REAL `PeerIdentityRepository` and the REAL wipe journal directly instead of
// through a port. The shipping app's trust surface stayeth absent, as it is today.
//
// Laws, one witness each:
//
//   1. NOTHING IS CLAIMED WHILE THE PRIVATE STORE IS LOCKED. The protected-data
//      gate is consulted FIRST; while it is closed the model reporteth
//      `.protectedDataUnavailable` and carrieth NO contact and NO own identity --
//      not a stale cache, not an empty-looking estate. A lock during a
//      verification refuseth the promotion rather than half-applying it.
//
//   2. USER_VERIFIED APPEARETH ONLY AFTER THE DURABLE CAS SUCCEEDETH. Promotion
//      runneth through `PeerIdentityRepository`'s compare-and-set on the
//      fingerprint, never through a local comparison alone -- and never through a
//      biometric success, which is not peer authentication. This is the card's
//      named semantic negative.
//
//   3. THE DISPLAYED CANDIDATE IS THE ONE APPROVED. An approval carrieth an
//      `ExactRotationCandidateRef` (node, generation AND pending-key digest); a
//      rotation that moved between render and tap is refused by the CAS.
//
//   4. MAIN-ACTOR STATE OBSERVES DURABLE OUTCOMES. Every mutation endeth by
//      RE-PROJECTING from the authority, so a scene recreation (a fresh model over
//      the same estate) says exactly what the surviving one said.
// ---------------------------------------------------------------------------

/// Why the trust surface has nothing to show. Failure is never dressed as empty.
public enum TrustUnavailability: Sendable, Equatable {
    /// The private store is readable.
    case available
    /// The device is locked (or the Keychain is otherwise protected): NOTHING is
    /// claimed until the user unlocks.
    case protectedDataUnavailable
    /// The durable trust store is unreadable: a typed corruption, never an empty
    /// contact list.
    case storeUnreadable(String)
}

/// How a contact's trust may be labelled. The case set is SHARED with the Android
/// isle (T55) so the two courts speak one vocabulary.
public enum ContactTrustLabel: String, Sendable, Equatable, CaseIterable {
    case unknown = "UNKNOWN"
    case tofuUnverified = "TOFU_UNVERIFIED"
    case verified = "USER_VERIFIED"
    case rotationPending = "ROTATION_PENDING"
    case revoked = "REVOKED"
    case corrupt = "CORRUPT"
}

/// The exact pending rotation the user was shown. Byte-for-byte the same three
/// fields the Android isle carrieth, and the same three the durable CAS bindeth on.
public struct ExactRotationCandidateRef: Sendable, Equatable {
    public let nodeId: Data
    public let pendingGeneration: UInt32
    /// The pending STATIC DH PUBLIC key the screen displayed. It is public
    /// material, and it is carried BECAUSE the durable CAS bindeth on it: a ref
    /// that carried only a digest could not satisfy the authority's own signature.
    public let pendingStaticDhPublicKey: Data

    /// The digest, DERIVED from the key (display and comparison only).
    public var pendingKeyDigestHex: String {
        ExactRotationCandidateRef.digestHex(pendingStaticDhPublicKey)
    }

    public init(nodeId: Data, pendingGeneration: UInt32, pendingStaticDhPublicKey: Data) {
        precondition(nodeId.count == 16, "a rotation candidate names a 16-octet node id")
        precondition(pendingStaticDhPublicKey.count == 32, "a pending static key is 32 octets")
        self.nodeId = nodeId
        self.pendingGeneration = pendingGeneration
        self.pendingStaticDhPublicKey = pendingStaticDhPublicKey
    }

    /// Two refs name the same candidate only if node, generation AND key agree.
    public func sameCandidate(as other: ExactRotationCandidateRef) -> Bool {
        nodeId == other.nodeId && pendingGeneration == other.pendingGeneration
            && pendingStaticDhPublicKey == other.pendingStaticDhPublicKey
    }

    /// SHA-256 hex of public material.
    public static func digestHex(_ bytes: Data) -> String {
        InsecureDigest.sha256Hex(bytes)
    }

    /// A short, human-comparable rendering.
    public static func fingerprint(_ bytes: Data) -> String {
        stride(from: 0, to: 16, by: 4).map { offset in
            digestHex(bytes.prefix(offset + 4)).prefix(8).description
        }.joined(separator: " ")
    }
}

/// The resumable wipe state the view shows, shared with the Android vocabulary.
public enum WipeProgressState: Sendable, Equatable {
    case idle
    case inProgress(stage: String, attempt: Int, resumable: Bool, lastError: String?)
    case complete

    public var isResumable: Bool {
        if case .inProgress(_, _, let resumable, _) = self { return resumable }
        return false
    }

    /// A finished wipe is exactly when ordinary use MAY resume; only an
    /// unfinished one standeth in the way.
    public var blocksOrdinaryUse: Bool {
        if case .inProgress = self { return true }
        return false
    }
}

/// One contact, projected for the view.
public struct ContactProjection: Sendable, Equatable {
    public let nodeId: Data
    public let label: String
    public let trust: ContactTrustLabel
    public let fingerprintHex: String
    public let acceptedGeneration: UInt32
    public let pendingRotation: ExactRotationCandidateRef?

    public var isVerified: Bool { trust == .verified }
    public var isTofu: Bool { trust == .tofuUnverified }
}

/// The own-identity projection (public material only).
public struct OwnIdentityProjection: Sendable, Equatable {
    public let nodeId: Data
    public let fingerprintHex: String
    public let qrPayload: String
}

/// Everything the user can ask for. The SAME seven intents the Android isle
/// carrieth, so the shared fixtures mean the same thing on both.
public enum TrustCommand: Sendable, Equatable {
    case showOwnIdentity
    case importRecipientBinding(String)
    case compareAndConfirmFingerprint(nodeId: Data, displayedFingerprintHex: String)
    case refresh
    case approveRotation(ExactRotationCandidateRef)
    case dismissRotation(ExactRotationCandidateRef)
    case revoke(Data)
    case beginWipe
    case resumeWipe
    case clearError
}

/// The immutable projection the SwiftUI layer rendereth.
public struct TrustUIState: Sendable, Equatable {
    public let availability: TrustUnavailability
    public let own: OwnIdentityProjection?
    public let contacts: [ContactProjection]
    public let wipe: WipeProgressState
    public let error: String?
    public let lastOutcome: String?
    public let revision: UInt64

    public static let unavailable = TrustUIState(
        availability: .protectedDataUnavailable, own: nil, contacts: [],
        wipe: .idle, error: nil, lastOutcome: nil, revision: 0)

    public var isAvailable: Bool { availability == .available }
    public var verified: [ContactProjection] { contacts.filter { $0.isVerified } }
    public var tofu: [ContactProjection] { contacts.filter { $0.isTofu } }
    public var pendingRotations: [ExactRotationCandidateRef] { contacts.compactMap { $0.pendingRotation } }

    public func contact(_ nodeId: Data) -> ContactProjection? {
        contacts.first { $0.nodeId == nodeId }
    }

    /// The spoken form of the state (voice accessibility): a screen-reader user
    /// must be able to tell a verified contact from a first-use one.
    public func voiceSummary() -> String {
        switch availability {
        case .protectedDataUnavailable:
            return "Contacts are unavailable while the device is locked. Unlock to review them."
        case .storeUnreadable(let reason):
            return "Your trust store cannot be read: \(reason). No contact is claimed."
        case .available: break
        }
        if case .inProgress(let stage, let attempt, _, _) = wipe {
            return "A wipe is in progress at \(stage), attempt \(attempt). It will resume after a relaunch."
        }
        if contacts.isEmpty { return "No contacts yet." }
        let verifiedCount = verified.count
        let tofuCount = tofu.count
        var spoken = "\(contacts.count) contacts. \(verifiedCount) verified, \(tofuCount) on first-use trust."
        if !pendingRotations.isEmpty {
            spoken += " \(pendingRotations.count) awaiting your review of a new key."
        }
        return spoken
    }
}

/// The spoken form of ONE contact's trust (voice accessibility, per row).
public func voiceLabel(for trust: ContactTrustLabel) -> String {
    switch trust {
    case .verified: return "verified: you compared this fingerprint yourself"
    case .tofuUnverified: return "not verified: trusted on first use only"
    case .rotationPending: return "a new key is offered; the old one still works"
    case .revoked: return "revoked: this contact is blocked"
    case .corrupt: return "unreadable: nothing is claimed about this contact"
    case .unknown: return "unknown contact"
    }
}

/// The protected-data gate: whether the private store may be read right now.
public protocol ProtectedDataGate: AnyObject {
    func isProtectedDataAvailable() -> Bool
}

/// The platform gate, expressed without importing UIKit (the model stayeth
/// host-testable; the app injecteth a gate that readeth the real
/// `UIApplication` state).
public final class AlwaysAvailableProtectedData: ProtectedDataGate {
    public init() {}
    public func isProtectedDataAvailable() -> Bool { true }
}

/// A gate a test (or the app) can open and close.
public final class SwitchableProtectedData: ProtectedDataGate, @unchecked Sendable {
    private let lock = NSLock()
    private var available: Bool
    public init(available: Bool = true) { self.available = available }
    public func isProtectedDataAvailable() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return available
    }
    public func setAvailable(_ value: Bool) {
        lock.lock(); available = value; lock.unlock()
    }
}

/// The bounded binding-payload policy, the twin of T55's `QrPayloadPolicy`: the
/// SAME prefix, the SAME character ceiling and the SAME decoded width, so a code
/// minted on one isle is read on the other.
public enum BindingPayloadPolicy {
    public static let prefix = "godstone-binding:v1:"
    public static let maxPayloadChars = 512
    public static let expectedBytes = 112

    public enum Outcome: Sendable, Equatable {
        case parsed(nodeId: Data, staticDhPublicKey: Data, signature: Data)
        case refused(String)
    }

    public static func isWellFormed(_ payload: String) -> Bool {
        payload.count <= maxPayloadChars && payload.hasPrefix(prefix)
    }

    public static func parse(_ payload: String) -> Outcome {
        if payload.isEmpty { return .refused("the payload is empty") }
        if payload.count > maxPayloadChars {
            return .refused("the payload is \(payload.count) characters, over the \(maxPayloadChars) bound")
        }
        guard payload.hasPrefix(prefix) else {
            return .refused("the payload carrieth no \(prefix) prefix")
        }
        let body = String(payload.dropFirst(prefix.count))
        if body.isEmpty { return .refused("the payload carrieth no body after the prefix") }
        guard body.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
            return .refused("the payload body is not base64url: wrong type or charset")
        }
        guard let decoded = base64UrlDecode(body) else {
            return .refused("the payload body is not decodable base64url")
        }
        guard decoded.count == expectedBytes else {
            return .refused("the payload decodeth to \(decoded.count) octets, not the required \(expectedBytes)")
        }
        let nodeId = decoded.prefix(16)
        let staticDh = decoded.dropFirst(16).prefix(32)
        let signature = decoded.dropFirst(48).prefix(64)
        if nodeId.allSatisfy({ $0 == 0 }) { return .refused("the payload carrieth an all-zero node id") }
        if staticDh.allSatisfy({ $0 == 0 }) { return .refused("the payload carrieth an all-zero static key") }
        return .parsed(nodeId: Data(nodeId), staticDhPublicKey: Data(staticDh), signature: Data(signature))
    }

    public static func render(nodeId: Data, staticDhPublicKey: Data, signature: Data) -> String {
        prefix + base64UrlEncode(nodeId + staticDhPublicKey + signature)
    }

    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

    private static func base64UrlEncode(_ bytes: Data) -> String {
        var out = String()
        let array = [UInt8](bytes)
        var i = 0
        while i < array.count {
            let b0 = Int(array[i])
            let b1 = i + 1 < array.count ? Int(array[i + 1]) : -1
            let b2 = i + 2 < array.count ? Int(array[i + 2]) : -1
            out.append(alphabet[b0 >> 2])
            out.append(alphabet[((b0 & 0x03) << 4) | (b1 >= 0 ? b1 >> 4 : 0)])
            if b1 >= 0 { out.append(alphabet[((b1 & 0x0F) << 2) | (b2 >= 0 ? b2 >> 6 : 0)]) }
            if b2 >= 0 { out.append(alphabet[b2 & 0x3F]) }
            i += 3
        }
        return out
    }

    private static func base64UrlDecode(_ text: String) -> Data? {
        var out = [UInt8]()
        var buffer = 0
        var bits = 0
        for character in text {
            guard let value = alphabet.firstIndex(of: character) else { return nil }
            buffer = (buffer << 6) | value
            bits += 6
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((buffer >> bits) & 0xFF))
            }
        }
        return Data(out)
    }
}

/// The dependency seam the model driveth. It is `internal` because it carrieth
/// the mesh module's own result taxonomies; the PUBLIC surface is `TrustUXModel`,
/// which speaketh only in public types. A court inside the module injecteth its
/// double directly.
protocol TrustAuthorityPort: AnyObject {
    func lookup(_ nodeId: Data) -> PeerIdentityLookup
    func approvePendingRotation(nodeId: Data, expectedPendingGeneration: UInt32,
                                expectedPendingStaticDhPublicKey: Data) -> RotationApprovalResult
    func revokePeer(_ nodeId: Data) -> RevokeResult
    func wipeState() -> WipeProgressState
    func beginWipe() -> WipeProgressState
    func resumeWipe() -> WipeProgressState
    /// Drop the sessions of one peer (revocation and rotation both reach here).
    func invalidateSessions(for nodeId: Data)
    /// The durable fingerprint-confirmation CAS.
    func confirmVerified(nodeId: Data, fingerprintHex: String) -> ConfirmOutcome
    func applyBinding(nodeId: Data, staticDhPublicKey: Data, signature: Data) -> BindingImportOutcome
}

enum ConfirmOutcome: Sendable, Equatable {
    case confirmed(nodeId: Data, acceptedGeneration: UInt32)
    case mismatch
    case peerNotFound
    case alreadyVerified
    case refused(String)
}

enum BindingImportOutcome: Sendable, Equatable {
    case imported(nodeId: Data, label: String)
    case refused(String)
}

enum RotationOutcome: Sendable, Equatable {
    case approved(nodeId: Data, acceptedGeneration: UInt32)
    case staleCandidate
    case noPendingCandidate
    case peerNotFound
    case rejectedRevoked
    case refused(String)
}

enum RevocationOutcome: Sendable, Equatable {
    case revoked
    case alreadyRevoked
    case peerNotFound
    case refused(String)
}

/// SHA-256 without a platform dependency, so the model stayeth host-testable.
enum InsecureDigest {
    static func sha256Hex(_ data: Data) -> String {
        // A compact FIPS-180-4 implementation over UInt32 words; deterministic and
        // dependency-free, which is all a public fingerprint digest requireth.
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                           0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        let k: [UInt32] = [
            0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
            0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
            0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
            0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
            0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
            0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
            0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
            0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2]
        var message = [UInt8](data)
        let bitLength = UInt64(message.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            message.append(UInt8((bitLength >> UInt64(shift)) & 0xFF))
        }
        for chunk in stride(from: 0, to: message.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 64)
            for i in 0..<16 {
                let base = chunk + i * 4
                w[i] = (UInt32(message[base]) << 24) | (UInt32(message[base + 1]) << 16)
                    | (UInt32(message[base + 2]) << 8) | UInt32(message[base + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var (a, b, c, d, e, f, g, hh) = (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7])
            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let temp1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ maj
                hh = g; g = f; f = e; e = d &+ temp1
                d = c; c = b; b = a; a = temp1 &+ temp2
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
        }
        return h.map { String(format: "%08x", $0) }.joined()
    }

    private static func rotr(_ value: UInt32, _ amount: UInt32) -> UInt32 {
        (value >> amount) | (value << (32 - amount))
    }
}

// ---------------------------------------------------------------------------
// The MainActor model itself.
// ---------------------------------------------------------------------------

/// The SwiftUI-facing model. `@MainActor` because every published value is
/// observed by the view; the durable authorities it driveth are ordinary
/// references, so no blocking work happeneth under a platform reducer lock.
@MainActor
public final class TrustUXModel: ObservableObject {
    private let authority: TrustAuthorityPort
    private let ownNodeId: Data
    private let protectedData: ProtectedDataGate
    private let ownSigningKey: Data
    private let ownStaticDhKey: Data

    // --------------------------------------------------------------------------------------
    // *** GS-UX-001 STEP 3 (round 540): **MAINACTOR OBSERVABLE STATE, CONSUMED BY SWIFTUI** -- THE TWIN OF
    // `MeshUXModel`'s, BECAUSE THE CONTRACT IS SHARED AND BOTH MODELS FEED ONE UI. ***
    //
    // MEASURED BEFORE THIS EDIT: `@MainActor` stood (the card's first half) and `ObservableObject` did NOT -- a
    // private `state` behind a SNAPSHOT accessor, so NOTHING PUBLISHED A CHANGE. The precedent on this isle is
    // `ArchiveSceneModel: ObservableObject` (`:111`).
    // *** AND THE SEAM IS VALUE-PRESERVING: `state` becometh a COMPUTED PROPERTY OVER THE PUBLISHED ONE, so every
    // existing write still compileth, still carrieth the value, AND NOW PUBLISHETH. ***
    // --------------------------------------------------------------------------------------
    @Published public private(set) var observableState: TrustUIState

    private var state: TrustUIState {
        get { observableState }
        set { observableState = newValue }
    }

    init(authority: TrustAuthorityPort,
         ownNodeId: Data,
         ownSigningKey: Data = Data(repeating: 0x21, count: 32),
         ownStaticDhKey: Data = Data(repeating: 0x11, count: 32),
         protectedData: ProtectedDataGate = AlwaysAvailableProtectedData()) {
        self.authority = authority
        self.ownNodeId = ownNodeId
        self.ownSigningKey = ownSigningKey
        self.ownStaticDhKey = ownStaticDhKey
        self.protectedData = protectedData
        self.observableState = TrustUIState.unavailable
        self.state = TrustUIState.unavailable
        self.state = project(lastOutcome: nil, error: nil)
    }

    /// The current projection.
    public func uiState() -> TrustUIState { state }

    /// The contacts the durable authority carrieth, as node ids (a census for callers).
    public func contactNodeIds() -> [Data] { state.contacts.map { $0.nodeId } }

    public func refresh() -> TrustUIState { project(lastOutcome: nil, error: nil) }

    @discardableResult
    public func onCommand(_ command: TrustCommand) -> TrustUIState {
        // LAW 1: while the private store is locked NOTHING is claimed, and no
        // command that would mutate trust is even attempted
        if !protectedData.isProtectedDataAvailable() {
            switch command {
            case .refresh, .clearError, .showOwnIdentity:
                return project(lastOutcome: nil, error: nil)
            default:
                return project(lastOutcome: nil,
                               error: "the device is locked; unlock to review or change your contacts")
            }
        }

        switch command {
        case .showOwnIdentity:
            return project(lastOutcome: "own identity shown", error: nil)
        case .refresh:
            return project(lastOutcome: nil, error: nil)
        case .clearError:
            return project(lastOutcome: nil, error: nil)
        case .importRecipientBinding(let payload):
            return handleImport(payload)
        case .compareAndConfirmFingerprint(let nodeId, let displayed):
            return handleCompare(nodeId: nodeId, displayedHex: displayed)
        case .approveRotation(let candidate):
            return handleApprove(candidate)
        case .dismissRotation(let candidate):
            return handleDismiss(candidate)
        case .revoke(let nodeId):
            return handleRevoke(nodeId)
        case .beginWipe:
            _ = authority.beginWipe()
            return project(lastOutcome: "wipe begun", error: nil)
        case .resumeWipe:
            _ = authority.resumeWipe()
            return project(lastOutcome: "wipe resumed", error: nil)
        }
    }

    // ---------------------------------------------------------------- handlers

    private func handleImport(_ payload: String) -> TrustUIState {
        switch BindingPayloadPolicy.parse(payload) {
        case .refused(let reason):
            return withError("that code cannot be used: " + reason)
        case .parsed(let nodeId, let staticDh, let signature):
            switch authority.applyBinding(nodeId: nodeId, staticDhPublicKey: staticDh,
                                          signature: signature) {
            case .refused(let reason):
                return withAuthorityError("import refused: " + reason)
            case .imported(_, let label):
                return project(lastOutcome: "imported " + label, error: nil)
            }
        }
    }

    private func handleCompare(nodeId: Data, displayedHex: String) -> TrustUIState {
        guard nodeId.count == 16 else { return withError("that contact is not addressable") }
        guard displayedHex.count == 64,
              displayedHex.allSatisfy({ $0.isHexDigit || ("a"..."f").contains($0) }) else {
            return withError("the fingerprint you entered is not a 64-character hex digest")
        }
        let current = project(lastOutcome: nil, error: nil)
        guard let contact = current.contact(nodeId) else { return withError("no such contact") }
        guard contact.fingerprintHex.lowercased() == displayedHex.lowercased() else {
            return withError("those fingerprints differ; the contact was NOT verified and trust is unchanged")
        }
        // LAW 2: the promotion is DURABLE. A local match is never enough, and no
        // biometric success may stand in for the authority's own CAS.
        switch authority.confirmVerified(nodeId: nodeId, fingerprintHex: contact.fingerprintHex) {
        case .confirmed(_, _):
            return project(lastOutcome: "fingerprint confirmed for " + contact.label, error: nil)
        case .mismatch:
            return withAuthorityError("the durable fingerprint is not the one you compared: trust is unchanged")
        case .peerNotFound:
            return withAuthorityError("no such contact")
        case .alreadyVerified:
            return project(lastOutcome: "that contact was already verified", error: nil)
        case .refused(let reason):
            return withAuthorityError("confirmation refused: " + reason)
        }
    }

    private func handleApprove(_ candidate: ExactRotationCandidateRef) -> TrustUIState {
        // LAW 3: the DISPLAYED ref travels; nothing re-readeth "the current" one
        let outcome = authority.approvePendingRotation(
            nodeId: candidate.nodeId,
            expectedPendingGeneration: candidate.pendingGeneration,
            expectedPendingStaticDhPublicKey: candidate.pendingStaticDhPublicKey)
        switch outcome {
        case .approved(let identity):
            // a rotation invalidates the sessions the old key protected
            authority.invalidateSessions(for: candidate.nodeId)
            return project(lastOutcome: "rotation approved at generation \(identity.acceptedGeneration)",
                           error: nil)
        case .staleCandidate:
            return withAuthorityError("that rotation is no longer pending: nothing was approved")
        case .noPendingCandidate:
            return withAuthorityError("there is no pending rotation to approve")
        case .peerNotFound:
            return withAuthorityError("no such contact")
        case .rejectedRevoked:
            return withAuthorityError("that contact is revoked: its rotation cannot be approved")
        case .invalidArgument(let message):
            return withAuthorityError("approval refused: " + message)
        case .corrupt(let reason):
            return withAuthorityError("the trust store is unreadable: \(reason)")
        case .storageFailure:
            return withAuthorityError("the durable store refused the approval")
        }
    }

    private func handleDismiss(_ candidate: ExactRotationCandidateRef) -> TrustUIState {
        let current = project(lastOutcome: nil, error: nil)
        guard let contact = current.contact(candidate.nodeId) else {
            return withError("no such contact")
        }
        guard contact.pendingRotation != nil else {
            return withError("there is no pending rotation to dismiss")
        }
        // a dismissal is a UI decision, not an authority mutation: the pending row
        // standeth and the old trust keepeth working
        return project(lastOutcome: "rotation review dismissed; trust unchanged", error: nil)
    }

    private func handleRevoke(_ nodeId: Data) -> TrustUIState {
        guard nodeId.count == 16 else { return withError("that contact is not addressable") }
        switch authority.revokePeer(nodeId) {
        case .revoked:
            // revocation invalidates the affected sessions
            authority.invalidateSessions(for: nodeId)
            return project(lastOutcome: "contact revoked; its sessions are invalidated", error: nil)
        case .alreadyRevoked:
            return project(lastOutcome: "the contact was already revoked", error: nil)
        case .peerNotFound:
            return withAuthorityError("no such contact")
        case .invalidArgument(let message):
            return withAuthorityError("revocation refused: " + message)
        case .corrupt(let reason):
            return withAuthorityError("the trust store is unreadable: \(reason)")
        case .storageFailure:
            return withAuthorityError("the durable store refused the revocation")
        }
    }

    // ---------------------------------------------------------------- projection

    /// LAW 4: the ONE read of the durable authorities, and the only writer of state.
    private func project(lastOutcome: String?, error: String?) -> TrustUIState {
        // LAW 1 first: a locked private store is checked BEFORE any read
        guard protectedData.isProtectedDataAvailable() else {
            let locked = TrustUIState(
                availability: .protectedDataUnavailable,
                own: nil,
                contacts: [],
                wipe: authority.wipeState(),
                error: error,
                lastOutcome: lastOutcome,
                revision: state.revision + 1)
            state = locked
            return locked
        }

        var contacts: [ContactProjection] = []
        var availability: TrustUnavailability = .available
        for nodeId in knownContactIds() {
            switch authority.lookup(nodeId) {
            case .verified(let identity):
                contacts.append(ContactProjection(
                    nodeId: identity.nodeId, label: shortLabel(identity.nodeId),
                    trust: identity.trustLevel == .userVerified ? .verified : .tofuUnverified,
                    fingerprintHex: ExactRotationCandidateRef.digestHex(identity.acceptedStaticDhPublicKey),
                    acceptedGeneration: identity.acceptedGeneration, pendingRotation: nil))
            case .quarantined(let pending):
                contacts.append(ContactProjection(
                    nodeId: pending.nodeId, label: shortLabel(pending.nodeId),
                    trust: .rotationPending,
                    fingerprintHex: ExactRotationCandidateRef.digestHex(pending.acceptedStaticDhPublicKey),
                    acceptedGeneration: pending.acceptedGeneration,
                    pendingRotation: ExactRotationCandidateRef(
                        nodeId: pending.nodeId,
                        pendingGeneration: pending.pendingGeneration,
                        pendingStaticDhPublicKey: pending.pendingStaticDhPublicKey)))
            case .revoked:
                contacts.append(ContactProjection(
                    nodeId: nodeId, label: shortLabel(nodeId), trust: .revoked,
                    fingerprintHex: ExactRotationCandidateRef.digestHex(nodeId),
                    acceptedGeneration: 0, pendingRotation: nil))
            case .corrupt(let reason):
                availability = .storeUnreadable("\(reason)")
            case .storageFailure:
                availability = .storeUnreadable("the durable store refused the read")
            case .notFound, .invalidArgument:
                continue
            }
        }

        let own: OwnIdentityProjection?
        if availability == .available {
            own = OwnIdentityProjection(
                nodeId: ownNodeId,
                fingerprintHex: ExactRotationCandidateRef.digestHex(ownNodeId),
                qrPayload: BindingPayloadPolicy.render(
                    nodeId: ownNodeId, staticDhPublicKey: ownStaticDhKey,
                    signature: Data(repeating: 0x33, count: 64)))
        } else {
            own = nil
        }

        let next = TrustUIState(
            availability: availability, own: own, contacts: contacts,
            wipe: authority.wipeState(), error: error, lastOutcome: lastOutcome,
            revision: state.revision + 1)
        state = next
        return next
    }

    /// The contact ids the surface may show. The app injecteth the operator's
    /// selection; a court injecteth its fixture.
    public var knownContactIdsProvider: () -> [Data] = { [] }

    private func knownContactIds() -> [Data] { knownContactIdsProvider() }

    private func shortLabel(_ nodeId: Data) -> String {
        "contact-" + ExactRotationCandidateRef.digestHex(nodeId).prefix(4)
    }

    private func withError(_ message: String) -> TrustUIState {
        state = TrustUIState(availability: state.availability, own: state.own,
                             contacts: state.contacts, wipe: state.wipe, error: message,
                             lastOutcome: nil, revision: state.revision + 1)
        return state
    }

    private func withAuthorityError(_ message: String) -> TrustUIState {
        project(lastOutcome: nil, error: message)
    }
}
