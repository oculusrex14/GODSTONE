import Foundation
import CryptoKit
import GodstoneCore

// T23 (section 13): the typed vocabulary of the handshake failure, duplicate
// and key-confirmation policy - the Swift twin of the Android BleHandshake.kt.
// The instruments that stand here are each of them a servant of the relation
// that owneth them: the stage projection the connection weareth, the transcript
// that remembereth what hath already been told as a whole frame, the hour-glass
// that telleth the moment a half-spoken exchange must fall, and the sealed
// key-confirmation of a trusted hour.
//
// Nothing here mutateth the authoritative state: the doors consult them, and
// the owners hands alone close a relation. A refusal never corrupteth a
// standing truth - the previous authoritative state is preserved, or the
// relation reacheth its specified terminal state.
//
// The clock domain differs of the Android twin: the connection is given a
// MonotonicClock whose nowUptimeMillis() is UInt64 MILLISECONDS, so the
// ten-second hour and the half-minute confirming hour are 10_000 and 30_000
// millis, and the court advanceeth that selfsame clock to lapse them.

/// The projection of section thirteens progression, worn beside the lifecycle
/// state so the drivers effect may be traced without a second mutable ready
/// flag. The lifecycle state is the authority; this is its shadow, and it
/// stoppeth short of keyConfirmed and applicationLinkReady until the sealed
/// key-confirmation round is proved by its echo.
public enum HandshakeStage: Int, Sendable {
    /// No relation of record.
    case idle = 0
    /// The LinkInfo exchange hath bound the seat; the hour-glass is armed.
    case roleBound = 1
    /// The half hath spoken its opening counsel (the first, or the second).
    case hsOut = 2
    /// The half hath heard its counsel and answered; it awaiteth the last.
    case hsIn = 3
    /// The controller reporteth the slot cryptographically ready.
    case trustedCryptoReady = 4
    /// The sealed key-confirmation echo matched the standing challenge.
    case keyConfirmed = 5
    /// The application LinkReady hath been published, exactly once.
    case applicationLinkReady = 6
}

/// The typed connection dispatch violations that D2 must OBSERVE and CLOSE,
/// raised before the silent stage filter of the reassembler would swallow an
/// out-of-place handshake record. Each is a distinct fall of the law; each is
/// recorded, bounded, and answereth by the exact relation falling through its
/// owners hand.
public enum HandshakeDispatchViolation: Int, Sendable {
    /// A handshake record of any kind seen once the relation is trusted.
    case unsolicitedHSAfterReady = 0
    /// The respondent spake its own second aloud at the responders gate.
    case ownVoiceAtTheGate = 1
    /// The whole of the counsel is out of order at the door.
    case outOfOrderCounsel = 2
    /// A challenge came back that was the very one this side standeth upon.
    case reflectedChallenge = 3
    /// An echo that matched none standing, of this relation or of an elder.
    case forgedOrStaleEcho = 4
    /// The hour-glass of the handshake ran out before the trust was whole.
    case handshakeDeadlineLapsed = 5
    /// The confirming hour ran out unanswered: the challenge went abroad and
    /// no echo ever came home to settle it. A distinct lapse from the
    /// handshake hour above, that an audit may tell the two twain apart.
    case keyConfirmationDeadlineLapsed = 6
}

/// A heard dispatch violation, recorded for the courts sight. A value, of its
/// peer, its site, and its kind alone.
public struct HandshakeDispatchRecord: Hashable, Sendable {
    public let peerId: Data
    public let site: String
    public let kind: HandshakeDispatchViolation

    public init(peerId: Data, site: String, kind: HandshakeDispatchViolation) {
        self.peerId = peerId
        self.site = site
        self.kind = kind
    }

    /// Of the CONTENT of the peer id, the site and the kind - the twin of the
    /// Android contentEquals.
    public static func == (left: HandshakeDispatchRecord, right: HandshakeDispatchRecord) -> Bool {
        return left.peerId == right.peerId && left.site == right.site && left.kind == right.kind
    }

    /// The twin of the Android contentHashCode: the same three fields, the
    /// eldest-of-three fold the hash combiner doth over them.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(peerId)
        hasher.combine(site)
        hasher.combine(kind.rawValue)
    }
}

/// The bounded transcript of whole frames this relation hath already SPOKEN
/// AND HEARD complete - keyed not by the kind alone but by the FULL frame
/// identity (kind, sequence, bytes). This is the very letter of section
/// thirteen: "exact duplicate bytes ... are ignored; conflicting duplicates or
/// out-of-order stages close." An exact re-delivery of the selfsame frame is
/// an idle re-telling and is hearkened not, and the controller is never run
/// for it a second time; a re-telling under an other sequence, or with other
/// bytes, is a CONFLICT and falleth to the doors stage law as ever.
///
/// It supplieth a need the reassembler cannot: the reassembler collapseth
/// repeated FRAGMENTS within one sequence; the transcript here is the whole
/// record as it is presented at the door, so that a re-presented whole record
/// - though it be a fresh assembly - never runneth the Noise controller the
/// second time. It is bounded: the eldest memory giveth way, that no
/// adversary may swell it.
public final class TranscriptCache: @unchecked Sendable {
    private let lock = NSLock()
    private var heard: [Int: [UInt32]] = [:]
    private var overflow: Int = 0
    private let capacity: Int

    public static let FRAME_CAPACITY: Int = 16

    public init(capacity: Int = TranscriptCache.FRAME_CAPACITY) {
        precondition(capacity > 0, "the transcript must keep at least one counsel of a kind")
        self.capacity = capacity
    }

    /// The mark of a whole frame, of its kind, its sequence and its bytes
    /// alone - never of any address, clock or station. The sequence is part
    /// of the identity so that a re-telling of the selfsame tale under an
    /// OTHER sequence is NO exact duplicate. The arithmetic is the 32-bit
    /// FNV-1a of the Android twin, done in UInt32 that wrappeth as Kotlin Int
    /// doth, so the two isles mark a frame alike.
    private func fingerprint(kind: Int, sequence: Int, payload: Data) -> UInt32 {
        var h: UInt32 = 0x811C9DC4
        h = (h ^ UInt32(truncatingIfNeeded: kind)) &* 0x01000193
        h = (h ^ UInt32(truncatingIfNeeded: sequence)) &* 0x01000193
        for b in payload {
            h = (h ^ UInt32(b)) &* 0x01000193
        }
        return h
    }

    /// Whether this very frame was already spoken and heard whole: the doors
    /// aske it at the mouth of each arm, and a known frame is hearkened not
    /// (the controller is never run again for it), it standeth.
    public func knows(kind: Int, sequence: Int, payload: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let kept = heard[kind] else { return false }
        return kept.contains(fingerprint(kind: kind, sequence: sequence, payload: payload))
    }

    /// The doors, at the health of a counsel through the controller, record it
    /// here that a selfsame frame re-presented be known. Idempotent: a frame
    /// twice remembred is kept but once.
    public func remember(kind: Int, sequence: Int, payload: Data) {
        lock.lock(); defer { lock.unlock() }
        let mark = fingerprint(kind: kind, sequence: sequence, payload: payload)
        if heard[kind] == nil {
            heard[kind] = [mark]
            return
        }
        var kept = heard[kind]!
        if kept.contains(mark) { return }
        if kept.count >= capacity {
            kept.removeFirst()
            overflow += 1
        }
        kept.append(mark)
        heard[kind] = kept
    }

    /// The number of tales remembered of one kind, that a court may count.
    internal func heardCountForTest(_ kind: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        return heard[kind]?.count ?? 0
    }

    /// The number of eldest tales that gave way to make room.
    internal func overflowCountForTest() -> Int {
        lock.lock(); defer { lock.unlock() }
        return overflow
    }

    /// Whether the transcript keepeth nothing at all.
    internal func isEmptyForTest() -> Bool {
        lock.lock(); defer { lock.unlock() }
        for (_, kept) in heard where !kept.isEmpty { return false }
        return true
    }

    /// The relations hand, at its fall or fresh course, forgetteth all.
    internal func forgetAll() {
        lock.lock(); defer { lock.unlock() }
        heard.removeAll()
        overflow = 0
    }
}

/// The ten-second monotonic hour-glass of the handshake, turn'd upon the role
/// binding and stopt at the trusted hour. It answereth by predicate, never by
/// wall; a stale lookup of the present hour can not lengthen it, and a
/// re-delivered event can not shorten it. It is measured in the seconds
/// domain of the connection's own timeProvider - the selfsame clock the
/// assembly lease and the courts both turn - so a relation may be aged as a
/// whole and asunder never.
public final class HandshakeDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private let now: () -> UInt64
    private let windowMillis: UInt64
    private var armedMono: Int64 = HandshakeDeadline.UNARMED
    private var fired: Bool = false

    /// The ten-second hour of section thirteen, in the uptime-millis domain.
    public static let handshakeWindowMillis: UInt64 = 10_000
    /// The elder name of the hour, kept for the two isles shared reading.
    public static let HAND_SECONDS: UInt64 = handshakeWindowMillis
    /// The glass was never turn'd.
    public static let UNARMED: Int64 = -1
    /// The glass was stopt by the trusted hour, and may never fell a relation.
    public static let STOPPED: Int64 = -2

    public init(now: @escaping () -> UInt64,
                 windowMillis: UInt64 = HandshakeDeadline.handshakeWindowMillis) {
        self.now = now
        self.windowMillis = windowMillis
    }

    /// Turn'd upon the very MonotonicClock the connection weareth.
    public convenience init(clock: MonotonicClock,
                windowMillis: UInt64 = HandshakeDeadline.handshakeWindowMillis) {
        self.init(now: { clock.nowUptimeMillis() }, windowMillis: windowMillis)
    }

    /// The seat is bound; the glass is turn'd. It is armed but once; a
    /// redundant binding findeth it already turn'd and spareth the first hour.
    public func arm() {
        lock.lock(); defer { lock.unlock() }
        if armedMono == HandshakeDeadline.UNARMED {
            armedMono = Int64(truncatingIfNeeded: now())
                &+ Int64(truncatingIfNeeded: windowMillis)
        }
    }

    /// The trusted hour is come; the glass is stopt and may never fell a
    /// relation that is already trusted.
    public func stop() {
        lock.lock(); defer { lock.unlock() }
        armedMono = HandshakeDeadline.STOPPED
    }

    /// The relation is torn down; the glass is wound again to unturn'd, that a
    /// fresh binding of the selfsame station may turn it afresh.
    public func reset() {
        lock.lock(); defer { lock.unlock() }
        armedMono = HandshakeDeadline.UNARMED
        fired = false
    }

    /// Is the glass spent, with the hour yet to come? A stopt or unturn'd
    /// glass answereth false.
    public func expired() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if armedMono == HandshakeDeadline.UNARMED || armedMono == HandshakeDeadline.STOPPED {
            return false
        }
        return Int64(truncatingIfNeeded: now()) >= armedMono
    }

    /// The hour the glass was set to, for the courts inspection: -1 unturn'd,
    /// -2 stopt.
    internal func armedMillisForTest() -> Int {
        lock.lock(); defer { lock.unlock() }
        return Int(armedMono)
    }

    /// The selfsame witness, in the domain of the glass.
    internal func armedMonoForTest() -> Int64 {
        lock.lock(); defer { lock.unlock() }
        return armedMono
    }

    /// Whether the glass was ever spent.
    internal func hasFiredForTest() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return fired
    }

    /// The owners hand, at the fall, marketh the glass spent, that the trace
    /// may name it once.
    internal func markFired() {
        lock.lock(); defer { lock.unlock() }
        fired = true
    }
}

public final class KeyConfirmation: @unchecked Sendable {
    private let lock = NSLock()
    private let now: () -> UInt64
    private let windowMillis: UInt64
    private var ourChallenge: Data? = nil
    private var issuedMono: Int64 = KeyConfirmation.UNISSUED
    private var confirmed: Bool = false

    /// The length of a key-confirmation challenge, of section thirteen.
    public static let CHALLENGE_BYTES: Int = 16
    /// The half-minute confirming hour, in the uptime-millis domain.
    public static let echoWindowMillis: UInt64 = 30_000
    /// The elder name of the hour, kept for the two isles shared reading.
    public static let ECHO_SECONDS: UInt64 = echoWindowMillis
    /// The version octet of the key-confirmation payload.
    public static let KEY_CONFIRMATION_VERSION: UInt8 = 0x01
    /// The mode of a challenge, and of its echo.
    public static let MODE_CHALLENGE: UInt8 = 0x00
    public static let MODE_RESPONSE: UInt8 = 0x01
    /// No challenge is abroad.
    public static let UNISSUED: Int64 = -1

    public init(now: @escaping () -> UInt64,
                 windowMillis: UInt64 = KeyConfirmation.echoWindowMillis) {
        self.now = now
        self.windowMillis = windowMillis
    }

    /// Bound to the very MonotonicClock the connection holdeth, that the court
    /// which advancech it may lapse the confirming hour also.
    public convenience init(clock: MonotonicClock,
                 windowMillis: UInt64 = KeyConfirmation.echoWindowMillis) {
        self.init(now: { clock.nowUptimeMillis() }, windowMillis: windowMillis)
    }

    /// Whether the sealed round of this half is whole: an echo matched the
    /// standing challenge. The truth of keyConfirmed dwelleth here, in the
    /// projection, and nowher as a parallel ready flag upon the station.
    public var isConfirmed: Bool {
        lock.lock(); defer { lock.unlock() }
        return confirmed
    }

    /// The owners hand, at the proving of an authenticated echo that matched
    /// the standing challenge, recordeth the sealed round as whole. It is the
    /// authors sole path to confirmation; the challenge is spent at the
    /// selfsame breath, that no echo may win a selfsame publication twice.
    internal func confirmExternally() {
        lock.lock(); defer { lock.unlock() }
        ourChallenge = nil
        confirmed = true
    }

    /// A new challenge is taken upon the old; the elder is forgotten whole.
    public func issue(_ challenge: Data) {
        precondition(challenge.count == KeyConfirmation.CHALLENGE_BYTES,
                     "the key-confirmation challenge must be sixteen octets")
        lock.lock(); defer { lock.unlock() }
        ourChallenge = Data(challenge)
        issuedMono = Int64(truncatingIfNeeded: now())
    }

    /// The challenge the half standeth upon, or nil when none is abroad.
    public func outstanding() -> Data? {
        lock.lock(); defer { lock.unlock() }
        return ourChallenge.map { Data($0) }
    }

    /// Whether the echo matcheth the standing challenge, and is not yet spent.
    /// A match consumeth the standing, that no second echo may win a selfsame
    /// publication. The compare is constant-time over the sixteen octets.
    public func matchesAndConsume(_ candidate: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let standing = ourChallenge else { return false }
        if candidate.count != KeyConfirmation.CHALLENGE_BYTES
            || standing.count != KeyConfirmation.CHALLENGE_BYTES {
            return false
        }
        let echo = [UInt8](candidate)
        let stand = [UInt8](standing)
        var diff: UInt8 = 0
        for i in 0..<KeyConfirmation.CHALLENGE_BYTES {
            diff = diff | (echo[i] ^ stand[i])
        }
        if diff != 0 { return false }
        ourChallenge = nil
        confirmed = true
        return true
    }

    /// The echo is past its hour.
    public func echoLapsed() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard ourChallenge != nil else { return false }
        if issuedMono == KeyConfirmation.UNISSUED { return false }
        return Int64(truncatingIfNeeded: now())
            >= issuedMono &+ Int64(truncatingIfNeeded: windowMillis)
    }

    /// A challenge goeth abroad and no echo hath yet matched it: the half doth
    /// AWAIT the peers echo. It is the witness that the round is a-comming, and
    /// the trigger of the key-confirmation timeout of section thirteen.
    public func isAwaitingEcho() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return ourChallenge != nil && !confirmed
    }

    /// The half hath spoken no challenge; the trace may rest.
    public func clear() {
        lock.lock(); defer { lock.unlock() }
        ourChallenge = nil
        issuedMono = KeyConfirmation.UNISSUED
        confirmed = false
    }

    /// Whether no challenge is standing at all.
    public var isIdle: Bool {
        lock.lock(); defer { lock.unlock() }
        return ourChallenge == nil
    }
}

/// A parsed key-confirmation control frame: its mode and its sixteen-octet
/// challenge. A value, of its mode and its challenge alone.
public struct KeyConfirmationFrame: Hashable, Sendable {
    public let mode: Int
    public let challenge: Data

    public init(mode: Int, challenge: Data) {
        self.mode = mode
        self.challenge = Data(challenge)
    }

    public var isChallenge: Bool { mode == KeyConfirmationControl.MODE_CHALLENGE }
    public var isResponse: Bool { mode == KeyConfirmationControl.MODE_RESPONSE }

    /// Of the mode and the CONTENT of the challenge - the twin of the Android
    /// contentEquals.
    public static func == (left: KeyConfirmationFrame, right: KeyConfirmationFrame) -> Bool {
        return left.mode == right.mode && left.challenge == right.challenge
    }

    /// The twin of the Android contentHashCode.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(mode)
        hasher.combine(challenge)
    }
}

/// T23 (section 13): the sealed key-confirmation round, carried INSIDE the
/// existing PING frame of the wire - never a fourth Noise message, never
/// persisted, never forwarded by the router. A control frame is the very
/// plaintext of an ordinary trusted DATA record: it is sealed by the selfsame
/// session the third counsel established, fragmented and pump'd by the
/// selfsame whole-record writer, and opened again by the selfsame collector.
/// D2 onely RECOGNISETH it by its shape and answereth it.
///
/// The shape, of section thirteens own words: a PING frame whose payload is
/// [version = 1, mode, challenge(16)], where mode 0 is a challenge and 1 its
/// echo; TTL 0, hop 0, no priority, no ACK-REQUEST, no SEALED flag - a control
/// frame claimeth none of the application planes.
public enum KeyConfirmationControl {
    public static let PROTOCOL_VERSION: Int = 0x01
    public static let MODE_CHALLENGE: Int = 0x00
    public static let MODE_RESPONSE: Int = 0x01
    public static let CHALLENGE_BYTES: Int = 16
    private static let PAYLOAD_BYTES: Int = 2 + CHALLENGE_BYTES
    private static let MSG_ID_BYTES: Int = 16

    /// One fresh CSPRNG challenge: sixteen unpredictable octets, the selfsame
    /// SecRandom-backed nonce the send path taketh for a message id.
    public static func newChallenge() -> Data { MessageId.generateNonce() }

    /// One fresh control message identifier: sixteen octets, distinct ever.
    private static func newMessageId() -> Data { MessageId.generateNonce() }

    public static func encodeChallenge(_ challenge: Data) -> Data {
        encode(MODE_CHALLENGE, challenge)
    }

    public static func encodeResponse(_ challenge: Data) -> Data {
        encode(MODE_RESPONSE, challenge)
    }

    private static func encode(_ mode: Int, _ challenge: Data) -> Data {
        precondition(challenge.count == CHALLENGE_BYTES,
                     "the key-confirmation challenge must be sixteen octets")
        precondition(mode == MODE_CHALLENGE || mode == MODE_RESPONSE,
                     "the key-confirmation mode is none of challenge or response")
        var payload = Data(count: PAYLOAD_BYTES)
        payload[0] = UInt8(PROTOCOL_VERSION)
        payload[1] = UInt8(mode)
        for i in 0..<CHALLENGE_BYTES {
            payload[2 + i] = challenge[challenge.startIndex.advanced(by: i)]
        }
        return FrameV2(
            type: .ping,
            msgId: newMessageId(),
            routingTag: Data(count: 4),
            ttl: 0,
            hopCount: 0,
            flags: 0,
            payload: payload
        ).encode()
    }

    /// The strict shape of section thirteen. It returneth the parsed challenge
    /// and its mode, or nil when the opened plaintext is not a key-confirmation
    /// control - every ordinary application frame, and every corrupted one,
    /// answereth nil and travelleth on to the application undisturb'd.
    public static func parse(_ opened: Data) -> KeyConfirmationFrame? {
        guard let frame = FrameV2.decode(opened) else { return nil }
        if frame.type != .ping { return nil }
        if frame.ttl != 0 || frame.hopCount != 0 { return nil }
        if frame.flags != 0 { return nil }
        let payload = [UInt8](frame.payload)
        if payload.count != PAYLOAD_BYTES { return nil }
        if Int(payload[0]) != PROTOCOL_VERSION { return nil }
        let mode = Int(payload[1])
        if mode != MODE_CHALLENGE && mode != MODE_RESPONSE { return nil }
        return KeyConfirmationFrame(mode: mode,
                                    challenge: Data(payload[2..<PAYLOAD_BYTES]))
    }
}
