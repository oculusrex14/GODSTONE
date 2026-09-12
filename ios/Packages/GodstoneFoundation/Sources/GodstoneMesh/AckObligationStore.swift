// T83 (iOS isle) -- the recipient ACK return path, section 14 of the plan.
//
// Add ack_obligations and ack_frames namespaces as section14 specifies: ACKs reuse the
// MESSAGE msgID, so the existing held_frames primary key collides; a crash between the
// inbox commit and the ACK signing would lose a reply without a durable obligation.
//
//   * ack_obligations(msg_id, recipient_node_id, identity_generation,
//     remaining_lifetime_ms, state) keyed by the FIRST TWO fields; inserted in the
//     SAME recipient inbox transaction (the store's commitInboundWithObligation);
//   * after commit the bounded worker signs via the corresponding still-valid local
//     identity (injected AckSignerSeam; the sealed AckFrame builder produces the
//     canonical frame -- the generated wire formula is NOT reimplemented here),
//     stores the exact frame row, then retires the obligation IN ONE TRANSACTION;
//   * process death at any boundary resumes it: the driver is stateless between runs
//     and re-reads the tables afresh; a key/storage failure leaves a retryable
//     obligation and produces NO claimed delivery;
//   * ack_frames(ack_key, msg_id, recipient_node_id, signature, encoded_frame,
//     received_from, remaining_lifetime_ms, verification_class) where
//     ack_key = SHA256(ASCII("GMP2-ACK-CACHE") || msg_id || recipient || signature) is
//     a LOCAL CACHE KEY ONLY -- it introduces no wire field;
//   * a MESSAGE and its ACK coexist (separate namespaces, no collision); different
//     signature candidates for one (msg_id, recipient) pair do not dedup each other;
//     bounded 4 per pair, 4096 total; known-invalid signatures under an available
//     authenticated recipient key are REJECTED (never stored); unknown-key relays
//     carry only bounded OPAQUE candidates, never labelled recipient-verified;
//     exhaustion REFUSES new custody explicitly, does not poison origin verification
//     state and does not erase original messages.
//
// Every read distinguishes ABSENT from STORAGE FAILURE from CORRUPT (section 14: no
// correctness-critical query may fabricate an empty set); every refusal names its
// cause; byte fields are defensively copied at every boundary; descriptions are
// redacted (section 5 privacy: no key material, no full payloads in logs).
//
// Mirrors Android delivery/AckObligationStore.kt (the engine primitives live in
// store/MessageStore.swift, where the SQL statements and the migration regime are
// homed on both isles).
import Foundation
import CryptoKit

let ackMsgLen: Int = 16
let ackRecipLen: Int = 16
let ackSigLen: Int = 64
let ackKeyLen: Int = 32
let ackPayloadLen: Int = 80
let ackHintLen: Int = 4
let ackCandidatesPerPairLimit: Int = 4
let ackCandidatesTotalLimit: Int = 4096

// ------------------------------------------------------------------ persisted records

/// The obligation states of section 14. The raw values are the cross-platform
/// persistence contract, NOT enum ordinals. Unknown codes never decode: the
/// paired-store boundary maps them to `.corrupt` (fail closed, C6.5 doctrine).
enum AckObligationState: Int32 {
    case pending = 0
    case signed = 1

    static func fromPersistedCode(_ code: Int32) -> AckObligationState? {
        switch code {
        case 0: return .pending
        case 1: return .signed
        default: return nil
        }
    }
}

/// The custody classes of the ack_frames namespace. 1 == the local recipient's own
/// signature verified under an available authenticated key; 2 == a bounded relay
/// copy whose key was NOT available (never labelled verified). 0 / unknown codes
/// decode to nil -> .corrupt at the repository boundary.
enum AckVerificationClass: Int32 {
    case verifiedRecipiant = 1
    case opaqueCandidate = 2

    static func fromPersistedCode(_ code: Int32) -> AckVerificationClass? {
        switch code {
        case 1: return .verifiedRecipiant
        case 2: return .opaqueCandidate
        default: return nil
        }
    }
}

func ackBytesEqual(_ left: Data?, _ right: Data?) -> Bool {
    if left == nil && right == nil { return true }
    guard let l = left, let r = right else { return false }
    return l == r
}

private func ackRedactedHex(_ bytes: Data?) -> String {
    guard let bytes else { return "null" }
    let hex = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f"]
    func nibblePair(_ b: UInt8) -> String {
        return hex[Int((Int(b) >> 4) & 0xF)] + hex[Int(Int(b) & 0xF)]
    }
    if bytes.isEmpty { return "-" }
    var out = ""
    let head = min(4, bytes.count)
    for i in 0..<head {
        let idx = bytes.startIndex + bytes.index(bytes.startIndex, offsetBy: i)
        out += nibblePair(bytes[idx])
    }
    if bytes.count > 4 {
        out += ".."
        for i in (bytes.count - 4)..<bytes.count {
            let idx = bytes.startIndex + bytes.index(bytes.startIndex, offsetBy: i)
            out += nibblePair(bytes[idx])
        }
    }
    return out
}

/// One row of ack_obligations. Value semantics; redacted description.
struct AckObligation: Equatable, @unchecked Sendable {
    let msgId: Data
    let recipientNodeId: Data
    let identityGeneration: Int64
    let remainingLifetimeMs: Int64
    let state: AckObligationState

    static func of(msgId: Data, recipientNodeId: Data, identityGeneration: Int64,
                   remainingLifetimeMs: Int64, state: AckObligationState) -> AckObligation? {
        if msgId.count != ackMsgLen { return nil }
        if recipientNodeId.count != ackRecipLen { return nil }
        if identityGeneration < 0 { return nil }
        if remainingLifetimeMs < 0 { return nil }
        return AckObligation(msgId: Data(msgId), recipientNodeId: Data(recipientNodeId),
                             identityGeneration: identityGeneration,
                             remainingLifetimeMs: remainingLifetimeMs, state: state)
    }

    var description: String {
        return "AckObligation(msg=" + ackRedactedHex(msgId) + ",recip=" + ackRedactedHex(recipientNodeId)
            + ",gen=" + String(identityGeneration) + ",remainingMs=" + String(remainingLifetimeMs)
            + ",state=" + String(describing: state) + ")"
    }
}

/// One row of ack_frames. Value semantics; redacted description.
struct AckFrameRecord: Equatable, @unchecked Sendable {
    let ackKey: Data
    let msgId: Data
    let recipientNodeId: Data
    let signature: Data
    let encodedFrame: Data
    let receivedFrom: Data?
    let remainingLifetimeMs: Int64
    let verificationClass: AckVerificationClass

    static func of(ackKey: Data, msgId: Data, recipientNodeId: Data, signature: Data,
                   encodedFrame: Data, receivedFrom: Data?, remainingLifetimeMs: Int64,
                   verificationClass: AckVerificationClass) -> AckFrameRecord? {
        if ackKey.count != ackKeyLen { return nil }
        if msgId.count != ackMsgLen { return nil }
        if recipientNodeId.count != ackRecipLen { return nil }
        if signature.count != ackSigLen { return nil }
        if encodedFrame.isEmpty { return nil }
        if let from = receivedFrom, from.count != ackRecipLen { return nil }
        if remainingLifetimeMs < 0 { return nil }
        return AckFrameRecord(ackKey: Data(ackKey), msgId: Data(msgId), recipientNodeId: Data(recipientNodeId),
                              signature: Data(signature), encodedFrame: Data(encodedFrame),
                              receivedFrom: receivedFrom.map { Data($0) },
                              remainingLifetimeMs: remainingLifetimeMs, verificationClass: verificationClass)
    }

    func toView() -> AckFrameRowView {
        return AckFrameRowView(ackKey: ackKey, msgId: msgId, recipientNodeId: recipientNodeId,
                               signature: signature, encodedFrame: encodedFrame,
                               receivedFrom: receivedFrom, remainingLifetimeMs: remainingLifetimeMs,
                               verificationClassCode: verificationClass.rawValue)
    }

    var description: String {
        return "AckFrameRecord(key=" + ackRedactedHex(ackKey) + ",msg=" + ackRedactedHex(msgId)
            + ",recip=" + ackRedactedHex(recipientNodeId) + ",sig=" + ackRedactedHex(signature)
            + ",frame=" + ackRedactedHex(encodedFrame) + ",from=" + ackRedactedHex(receivedFrom)
            + ",remainingMs=" + String(remainingLifetimeMs) + ",class=" + String(describing: verificationClass) + ")"
    }
}

// ------------------------------------------------------------------ local cache key

/// ack_key = SHA256(ASCII("GMP2-ACK-CACHE") || msg_id || recipient || signature).
/// A LOCAL cache key only -- it never enters the wire. Mirrors the Android
/// AckCacheKey (java.security.MessageDigest "SHA-256" over the same preimage).
enum AckCacheKey {
    static let ackDomainText = "GMP2-ACK-CACHE"

    static func compute(msgId: Data, recipientNodeId: Data, signature: Data) -> Data? {
        if msgId.count != ackMsgLen { return nil }
        if recipientNodeId.count != ackRecipLen { return nil }
        if signature.count != ackSigLen { return nil }
        var hasher = SHA256()
        hasher.update(data: Data(ackDomainText.utf8))
        hasher.update(data: msgId)
        hasher.update(data: recipientNodeId)
        hasher.update(data: signature)
        let digest = hasher.finalize()
        return Data(digest)
    }
}

// ------------------------------------------------------------------ typed outcomes

enum InboundCommitResult: Equatable {
    case committed(heldNew: Bool, obligationStored: Bool, duplicate: Bool)
    case rejectedCapacity
    case storageFailure
    case invalidArgument
}

enum ObligationInsertResult: Equatable {
    case stored
    case duplicate
    case storageFailure
}

enum ObligationLookup: Equatable {
    case found(AckObligation)
    case absent
    case corrupt(String)
    case storageFailure
}

enum ObligationAdvanceResult: Equatable {
    case advanced
    case absent
    case stateDrift(AckObligationState)
    case storageFailure
}

enum AckAdmissionResult: Equatable {
    case stored(ackKey: Data)
    case duplicate
    case refusedQuotaPair
    case refusedQuotaGlobal
    case refusedBadFrame
    case refusedKnownInvalid
    case storageFailure
}

enum FrameCommitResult: Equatable {
    case committed
    case idempotent
    case refusedQuotaPair
    case refusedQuotaGlobal
    case storageFailure
}

enum PendingList: Equatable {
    case rows([AckObligation])
    case corrupt(String)
    case storageFailure
}

enum PairList: Equatable {
    case records([AckFrameRecord])
    case corrupt(String)
    case storageFailure
}

enum FrameLookup: Equatable {
    case found(AckFrameRecord)
    case absent
    case corrupt(String)
    case storageFailure
}

// ------------------------------------------------------------------ the paired store

/// The still-valid local signing identity behind the worker's pen. A nil nodeId or
/// a seed the signer refuses to release leaves the obligation PENDING (retryable)
/// and claims nothing. Throws only for fault injection from the courts.
protocol AckSignerSeam: AnyObject {
    var nodeId: Data? { get }
    func generation() -> Int64
    func signingSeed(msgId: Data, recipientNodeId: Data) throws -> Data?
}

/// The two namespaces as ONE paired store: the frame insert and the obligation
/// retirement commit together or not at all (section 14: "in a transaction").
protocol AckObligationStore: AnyObject {
    func insertIfAbsent(_ obligation: AckObligation) -> ObligationInsertResult
    func lookupObligation(_ msgId: Data, recipientNodeId: Data) -> ObligationLookup
    func listPending(_ bound: Int32) throws -> PendingList
    func markSigned(_ msgId: Data, recipientNodeId: Data) -> ObligationAdvanceResult
    func retireObligation(_ msgId: Data, recipientNodeId: Data) -> ObligationAdvanceResult
    func countObligations() -> Int

    func storeCandidate(_ record: AckFrameRecord) -> AckAdmissionResult
    func lookupByAckKey(_ ackKey: Data) -> FrameLookup
    func candidatesForPair(_ msgId: Data, recipientNodeId: Data, bound: Int32) throws -> PairList
    func countForPair(_ msgId: Data, recipientNodeId: Data) -> Int
    func countFrames() -> Int
    func deleteAllFrames() -> Int

    /// The atomic pair step: insert the frame row AND retire the obligation.
    func commitFrameAndRetireObligation(_ record: AckFrameRecord, msgId: Data,
                                         recipientNodeId: Data) -> FrameCommitResult
}

// ------------------------------------------------------------------ in-memory engine

final class InMemoryAckStore: AckObligationStore, @unchecked Sendable {
    private let lock = NSLock()
    private var obligations: [Data: AckObligation] = [:]
    private var frames: [Data: AckFrameRecord] = [:]

    func clearAll() {
        lock.lock()
        obligations.removeAll()
        frames.removeAll()
        lock.unlock()
    }

    func insertIfAbsent(_ obligation: AckObligation) -> ObligationInsertResult {
        lock.lock(); defer { lock.unlock() }
        let k = obKey(obligation.msgId, obligation.recipientNodeId)
        if obligations[k] != nil { return .duplicate }
        obligations[k] = obligation
        return .stored
    }

    func lookupObligation(_ msgId: Data, recipientNodeId: Data) -> ObligationLookup {
        lock.lock(); defer { lock.unlock() }
        guard let row = obligations[obKey(msgId, recipientNodeId)] else { return .absent }
        return .found(row)
    }

    func listPending(_ bound: Int32) throws -> PendingList {
        lock.lock(); defer { lock.unlock() }
        if bound <= 0 { return .rows([]) }
        var taken: [AckObligation] = []
        for (_, row) in obligations {
            if taken.count >= Int(bound) { break }
            if row.state == .pending || row.state == .signed { taken.append(row) }
        }
        return .rows(taken)
    }

    func markSigned(_ msgId: Data, recipientNodeId: Data) -> ObligationAdvanceResult {
        lock.lock(); defer { lock.unlock() }
        let k = obKey(msgId, recipientNodeId)
        guard let cur = obligations[k] else { return .absent }
        guard cur.state == .pending else { return .stateDrift(cur.state) }
        guard let moved = AckObligation.of(msgId: cur.msgId, recipientNodeId: cur.recipientNodeId,
                                           identityGeneration: cur.identityGeneration,
                                           remainingLifetimeMs: cur.remainingLifetimeMs, state: .signed)
        else { return .storageFailure }
        obligations[k] = moved
        return .advanced
    }

    func retireObligation(_ msgId: Data, recipientNodeId: Data) -> ObligationAdvanceResult {
        lock.lock(); defer { lock.unlock() }
        let k = obKey(msgId, recipientNodeId)
        guard obligations[k] != nil else { return .absent }
        obligations[k] = nil
        return .advanced
    }

    func countObligations() -> Int {
        lock.lock(); defer { lock.unlock() }
        return obligations.count
    }

    func storeCandidate(_ record: AckFrameRecord) -> AckAdmissionResult {
        lock.lock(); defer { lock.unlock() }
        if frames[record.ackKey] != nil { return .duplicate }
        if countForPairLocked(record.msgId, record.recipientNodeId) >= ackCandidatesPerPairLimit {
            return .refusedQuotaPair
        }
        if frames.count >= ackCandidatesTotalLimit { return .refusedQuotaGlobal }
        frames[record.ackKey] = record
        return .stored(ackKey: record.ackKey)
    }

    func lookupByAckKey(_ ackKey: Data) -> FrameLookup {
        lock.lock(); defer { lock.unlock() }
        guard let row = frames[ackKey] else { return .absent }
        return .found(row)
    }

    func candidatesForPair(_ msgId: Data, recipientNodeId: Data, bound: Int32) throws -> PairList {
        lock.lock(); defer { lock.unlock() }
        if bound <= 0 { return .records([]) }
        var out: [AckFrameRecord] = []
        for (_, row) in frames {
            if row.msgId == msgId && row.recipientNodeId == recipientNodeId {
                out.append(row)
                if out.count >= Int(bound) { break }
            }
        }
        return .records(out)
    }

    func countForPair(_ msgId: Data, recipientNodeId: Data) -> Int {
        lock.lock(); defer { lock.unlock() }
        return countForPairLocked(msgId, recipientNodeId)
    }

    private func countForPairLocked(_ msgId: Data, _ recipientNodeId: Data) -> Int {
        var n = 0
        for (_, row) in frames {
            if row.msgId == msgId && row.recipientNodeId == recipientNodeId { n += 1 }
        }
        return n
    }

    func countFrames() -> Int {
        lock.lock(); defer { lock.unlock() }
        return frames.count
    }

    func deleteAllFrames() -> Int {
        lock.lock(); defer { lock.unlock() }
        let n = frames.count
        frames.removeAll()
        return n
    }

    func commitFrameAndRetireObligation(_ record: AckFrameRecord, msgId: Data,
                                        recipientNodeId: Data) -> FrameCommitResult {
        lock.lock(); defer { lock.unlock() }
        let framePresent = frames[record.ackKey] != nil
        let obPresent = obligations[obKey(msgId, recipientNodeId)] != nil
        if !framePresent {
            if countForPairLocked(record.msgId, record.recipientNodeId) >= ackCandidatesPerPairLimit {
                return .refusedQuotaPair
            }
            if frames.count >= ackCandidatesTotalLimit { return .refusedQuotaGlobal }
            frames[record.ackKey] = record
            if obPresent { obligations[obKey(msgId, recipientNodeId)] = nil }
            return .committed
        }
        if obPresent { obligations[obKey(msgId, recipientNodeId)] = nil }
        return .idempotent
    }

    private func obKey(_ msgId: Data, _ recipientNodeId: Data) -> Data {
        var k = msgId
        k.append(recipientNodeId)
        return k
    }
}

// ------------------------------------------------------------------ engine protocol

/// The durable SQLite transaction engine behind the paired store: the thirteen
/// single-statement primitives plus the one-transaction pair step. A storage
/// failure THROWS and the repository boundary maps it to the typed
/// .storageFailure; absence is a nil / 0 sentinels, never folded into failure
/// (C6.4-A doctrine). Implemented by SqliteMessageStore (see
/// store/MessageStore.swift, beside the delivery_state primitives).
protocol AckObligationEngine: AnyObject {
    func insertObligation(_ msgId: Data, recipientNodeId: Data, identityGeneration: Int64,
                          remainingLifetimeMs: Int64, stateCode: Int32) throws -> Bool
    func readObligation(_ msgId: Data, recipientNodeId: Data) throws -> ObligationEntryRow?
    func listPendingObligations(_ bound: Int32) throws -> [ObligationEntryRow]
    func countObligationRows() throws -> Int
    func casMarkObligationSigned(_ msgId: Data, recipientNodeId: Data) throws -> Int
    func deleteObligation(_ msgId: Data, recipientNodeId: Data) throws -> Int
    func insertAckFrameRow(_ row: AckFrameRowView) throws -> Bool
    func readAckFrameRowByAckKey(_ ackKey: Data) throws -> AckFrameRowView?
    func listAckFrameRowsForPair(_ msgId: Data, recipientNodeId: Data, bound: Int32) throws -> [AckFrameRowView]
    func countAckFrameRowsForPair(_ msgId: Data, recipientNodeId: Data) throws -> Int
    func countAckFrameRowsTotal() throws -> Int
    func deleteAllAckFrameRows() throws -> Int
    func commitAckPair(_ row: AckFrameRowView, msgId: Data, recipientNodeId: Data) throws -> FrameCommitOutcome
}

struct ObligationEntryRow: Equatable {
    let msgId: Data
    let recipientNodeId: Data
    let identityGeneration: Int64
    let remainingLifetimeMs: Int64
    let stateCode: Int32
}

struct AckFrameRowView: Equatable {
    let ackKey: Data
    let msgId: Data
    let recipientNodeId: Data
    let signature: Data
    let encodedFrame: Data
    let receivedFrom: Data?
    let remainingLifetimeMs: Int64
    let verificationClassCode: Int32
}

/// The outcome of the ONE-transaction pair step (frame insert + retirement). The
/// quota censuses run INSIDE the transaction so the census and the write share one
/// snapshot; refusals leave the obligation pending (retry later), never touching any
/// other namespace.
enum FrameCommitOutcome: Equatable {
    case committed
    case idempotent
    case refusedQuotaPair
    case refusedQuotaGlobal
}

// ------------------------------------------------------------------ sqlite repository

/// The paired store over the durable SQLite transaction engine: the frame insert and
/// the obligation retirement commit inside ONE engine transaction (both-or-neither;
/// the non-recursive connection lock is held once per call). Mirrors Android
/// SqliteAckStore.
final class SqliteAckStore: AckObligationStore, @unchecked Sendable {
    private let engine: AckObligationEngine

    init(engine: AckObligationEngine) {
        self.engine = engine
    }

    func insertIfAbsent(_ obligation: AckObligation) -> ObligationInsertResult {
        do {
            let fresh = try engine.insertObligation(
                obligation.msgId, recipientNodeId: obligation.recipientNodeId,
                identityGeneration: obligation.identityGeneration,
                remainingLifetimeMs: obligation.remainingLifetimeMs,
                stateCode: obligation.state.rawValue
            )
            return fresh ? .stored : .duplicate
        } catch {
            return .storageFailure
        }
    }

    func lookupObligation(_ msgId: Data, recipientNodeId: Data) -> ObligationLookup {
        let row: ObligationEntryRow?
        do {
            row = try engine.readObligation(msgId, recipientNodeId: recipientNodeId)
        } catch {
            return .storageFailure
        }
        guard let row else { return .absent }
        guard let state = AckObligationState.fromPersistedCode(row.stateCode) else {
            return .corrupt("persisted state code \(row.stateCode)")
        }
        guard let ob = AckObligation.of(msgId: row.msgId, recipientNodeId: row.recipientNodeId,
                                        identityGeneration: row.identityGeneration,
                                        remainingLifetimeMs: row.remainingLifetimeMs, state: state)
        else { return .corrupt("persisted widths violate the relation") }
        return .found(ob)
    }

    func listPending(_ bound: Int32) throws -> PendingList {
        if bound <= 0 { return .rows([]) }
        let rows: [ObligationEntryRow]
        do {
            rows = try engine.listPendingObligations(bound)
        } catch {
            return .storageFailure
        }
        var out: [AckObligation] = []
        for row in rows {
            guard let state = AckObligationState.fromPersistedCode(row.stateCode) else {
                return .corrupt("pending scan: state code \(row.stateCode)")
            }
            guard let ob = AckObligation.of(msgId: row.msgId, recipientNodeId: row.recipientNodeId,
                                           identityGeneration: row.identityGeneration,
                                           remainingLifetimeMs: row.remainingLifetimeMs, state: state)
            else { return .corrupt("pending scan: widths violate the relation") }
            out.append(ob)
        }
        return .rows(out)
    }

    func markSigned(_ msgId: Data, recipientNodeId: Data) -> ObligationAdvanceResult {
        let advanced: Int
        do {
            advanced = try engine.casMarkObligationSigned(msgId, recipientNodeId: recipientNodeId)
        } catch {
            return .storageFailure
        }
        if advanced == 1 { return .advanced }
        return classifyZeroCas(msgId, recipientNodeId: recipientNodeId, expect: .pending)
    }

    func retireObligation(_ msgId: Data, recipientNodeId: Data) -> ObligationAdvanceResult {
        let retired: Int
        do {
            retired = try engine.deleteObligation(msgId, recipientNodeId: recipientNodeId)
        } catch {
            return .storageFailure
        }
        if retired > 0 { return .advanced }
        return classifyZeroCas(msgId, recipientNodeId: recipientNodeId, expect: nil)
    }

    /// A 0-row guarded statement is re-read ONCE and classified -- absent vs state
    /// drift are distinct observations; never folded into the storage failure.
    private func classifyZeroCas(_ msgId: Data, recipientNodeId: Data,
                                 expect: AckObligationState?) -> ObligationAdvanceResult {
        let row: ObligationEntryRow?
        do {
            row = try engine.readObligation(msgId, recipientNodeId: recipientNodeId)
        } catch {
            return .storageFailure
        }
        guard let row else { return .absent }
        guard let state = AckObligationState.fromPersistedCode(row.stateCode) else {
            return .storageFailure
        }
        if let expect, state == expect { return .storageFailure }
        return .stateDrift(state)
    }

    func countObligations() -> Int {
        do { return try engine.countObligationRows() } catch { return -1 }
    }

    func storeCandidate(_ record: AckFrameRecord) -> AckAdmissionResult {
        let inserted: Bool
        do {
            inserted = try engine.insertAckFrameRow(record.toView())
        } catch {
            return .storageFailure
        }
        if inserted { return .stored(ackKey: record.ackKey) }
        // a duplicate key: re-read ONCE to distinguish the true duplicate from a
        // raced removal; never report a refusal that did not happen
        do {
            let again = try engine.readAckFrameRowByAckKey(record.ackKey)
            return again == nil ? .storageFailure : .duplicate
        } catch {
            return .storageFailure
        }
    }

    /// The quota gates run BEFORE any write: the pair census and the total census,
    /// each refused explicitly, none of them poisoning any other namespace
    /// (section 14: exhaustion refuses, it does not corrupt).
    func admitUnderQuota(_ record: AckFrameRecord) -> AckAdmissionResult {
        let pairCount: Int
        do {
            pairCount = try engine.countAckFrameRowsForPair(record.msgId, recipientNodeId: record.recipientNodeId)
        } catch {
            return .storageFailure
        }
        if pairCount >= ackCandidatesPerPairLimit { return .refusedQuotaPair }
        let total: Int
        do {
            total = try engine.countAckFrameRowsTotal()
        } catch {
            return .storageFailure
        }
        if total >= ackCandidatesTotalLimit { return .refusedQuotaGlobal }
        return storeCandidate(record)
    }

    func lookupByAckKey(_ ackKey: Data) -> FrameLookup {
        let row: AckFrameRowView?
        do {
            row = try engine.readAckFrameRowByAckKey(ackKey)
        } catch {
            return .storageFailure
        }
        guard let row else { return .absent }
        guard let rec = fromView(row) else { return .corrupt("stored frame violates the relation") }
        return .found(rec)
    }

    func candidatesForPair(_ msgId: Data, recipientNodeId: Data, bound: Int32) throws -> PairList {
        if bound <= 0 { return .records([]) }
        let rows: [AckFrameRowView]
        do {
            rows = try engine.listAckFrameRowsForPair(msgId, recipientNodeId: recipientNodeId, bound: bound)
        } catch {
            return .storageFailure
        }
        var out: [AckFrameRecord] = []
        for row in rows {
            guard let rec = fromView(row) else {
                return .corrupt("pair scan: row violates the relation")
            }
            out.append(rec)
        }
        return .records(out)
    }

    func countForPair(_ msgId: Data, recipientNodeId: Data) -> Int {
        do { return try engine.countAckFrameRowsForPair(msgId, recipientNodeId: recipientNodeId) } catch { return -1 }
    }

    func countFrames() -> Int {
        do { return try engine.countAckFrameRowsTotal() } catch { return -1 }
    }

    func deleteAllFrames() -> Int {
        do { return try engine.deleteAllAckFrameRows() } catch { return -1 }
    }

    func commitFrameAndRetireObligation(_ record: AckFrameRecord, msgId: Data,
                                        recipientNodeId: Data) -> FrameCommitResult {
        let outcome: FrameCommitOutcome
        do {
            outcome = try engine.commitAckPair(record.toView(), msgId: msgId, recipientNodeId: recipientNodeId)
        } catch {
            return .storageFailure
        }
        switch outcome {
        case .committed: return .committed
        case .idempotent: return .idempotent
        case .refusedQuotaPair: return .refusedQuotaPair
        case .refusedQuotaGlobal: return .refusedQuotaGlobal
        }
    }

    private func fromView(_ row: AckFrameRowView) -> AckFrameRecord? {
        guard let klass = AckVerificationClass.fromPersistedCode(row.verificationClassCode) else { return nil }
        return AckFrameRecord.of(ackKey: row.ackKey, msgId: row.msgId, recipientNodeId: row.recipientNodeId,
                                 signature: row.signature, encodedFrame: row.encodedFrame,
                                 receivedFrom: row.receivedFrom, remainingLifetimeMs: row.remainingLifetimeMs,
                                 verificationClass: klass)
    }
}

// ------------------------------------------------------------------ the bounded worker

/// The bounded worker of section 14: signs via the still-valid local identity AFTER
/// the inbox commit, stores the exact frame row, retires the obligation -- one
/// transaction per pair. Stateless between runs; a restart resumes by re-reading.
final class AckObligationDriver: @unchecked Sendable {
    private let store: AckObligationStore
    private let signer: AckSignerSeam
    private let authenticator: Ed25519AckAuthenticator
    private let resolver: RecipientKeyResolver

    init(store: AckObligationStore, signer: AckSignerSeam,
         authenticator: Ed25519AckAuthenticator, resolver: RecipientKeyResolver) {
        self.store = store
        self.signer = signer
        self.authenticator = authenticator
        self.resolver = resolver
    }

    struct DriverReport: Equatable {
        let scanned: Int
        let signed: Int
        let retired: Int
        let keyUnavailable: Int
        let idempotent: Int
        let refusedQuota: Int
        let storageFailures: Int
    }

    func runPendingOnce(_ bound: Int, fault: ((String) throws -> Void)? = nil) throws -> DriverReport {
        var scanned = 0, signed = 0, retired = 0, keyUnavailable = 0
        var idempotent = 0, refusedQuota = 0, failures = 0
        var pending: PendingList = .storageFailure
        do {
            pending = try store.listPending(Int32(bound))
        } catch {
            pending = .storageFailure
        }
        var rows: [AckObligation] = []
        if case .rows(let rs) = pending { rows = rs }
        if case .corrupt = pending { failures += 1 }
        if case .storageFailure = pending { failures += 1 }
        for ob in rows {
            scanned += 1
            // refuse to sign with a key that does not name the obligated recipient
            guard let signerNode = signer.nodeId, signerNode == ob.recipientNodeId else {
                keyUnavailable += 1; continue
            }
            guard signer.generation() >= ob.identityGeneration else {
                // the presented identity is older than the pin: NOT the still-valid
                // local identity; the obligation remains pending and nothing is claimed
                keyUnavailable += 1; continue
            }
            var seed: Data? = nil
            do {
                seed = try signer.signingSeed(msgId: ob.msgId, recipientNodeId: ob.recipientNodeId)
            } catch {
                seed = nil
            }
            guard let seed else { keyUnavailable += 1; continue }
            try fault?("signing")
            var frame: FrameV2
            do {
                frame = try AckFrame.build(
                    msgId: ob.msgId, recipientSigningPrivKey: seed,
                    recipientNodeId: ob.recipientNodeId,
                    routingTag: Data(ob.recipientNodeId.prefix(4))
                )
            } catch {
                failures += 1; continue
            }
            guard frame.payload.count == ackPayloadLen else { failures += 1; continue }
            let encoded = frame.encode()
            guard !encoded.isEmpty else { failures += 1; continue }
            let signature = Data(frame.payload.prefix(64))
            let claimed = Data(frame.payload.suffix(16))
            // verification-first even for self-produced frames: a mis-signed reply
            // must never be stored and the obligation must survive it
            if resolver.publicSigningKey(forNodeId: claimed) != nil {
                guard authenticator.verify(originalMsgId: ob.msgId, expectedRecipientNodeId: claimed,
                                           ackFrame: frame) else {
                    failures += 1; continue
                }
            }
            guard let ackKey = AckCacheKey.compute(msgId: ob.msgId, recipientNodeId: ob.recipientNodeId,
                                                   signature: signature) else {
                failures += 1; continue
            }
            guard let record = AckFrameRecord.of(ackKey: ackKey, msgId: ob.msgId,
                                                 recipientNodeId: ob.recipientNodeId, signature: signature,
                                                 encodedFrame: encoded, receivedFrom: nil,
                                                 remainingLifetimeMs: ob.remainingLifetimeMs,
                                                 verificationClass: .verifiedRecipiant) else {
                failures += 1; continue
            }
            try fault?("frame_insert")
            let outcome = store.commitFrameAndRetireObligation(record, msgId: ob.msgId,
                                                               recipientNodeId: ob.recipientNodeId)
            switch outcome {
            case .committed: signed += 1; retired += 1
            case .idempotent: idempotent += 1
            case .refusedQuotaPair, .refusedQuotaGlobal: refusedQuota += 1
            case .storageFailure: failures += 1
            }
        }
        return DriverReport(scanned: scanned, signed: signed, retired: retired,
                            keyUnavailable: keyUnavailable, idempotent: idempotent,
                            refusedQuota: refusedQuota, storageFailures: failures)
    }

    /// Admission of a foreign candidate (a received ACK frame): the classifier runs
    /// BEFORE any write. Known-invalid under an available authenticated key is
    /// REJECTED; without an available key the candidate is admitted only as a
    /// bounded OPAQUE row, never labelled recipient-verified. Quota gates live in
    /// the store.
    func admitForeignCandidate(_ encoded: Data, receivedFrom: Data?) -> AckAdmissionResult {
        guard let frame = FrameV2.decode(encoded) else { return .refusedBadFrame }
        guard frame.type == .ack else { return .refusedBadFrame }
        guard frame.payload.count == ackPayloadLen else { return .refusedBadFrame }
        guard frame.msgId.count == ackMsgLen else { return .refusedBadFrame }
        if let from = receivedFrom, from.count != ackRecipLen { return .refusedBadFrame }
        let signature = Data(frame.payload.prefix(64))
        let claimed = Data(frame.payload.suffix(16))
        let key = resolver.publicSigningKey(forNodeId: claimed)
        let klass: AckVerificationClass
        if key != nil {
            guard authenticator.verify(originalMsgId: frame.msgId, expectedRecipientNodeId: claimed,
                                       ackFrame: frame) else {
                return .refusedKnownInvalid
            }
            klass = .verifiedRecipiant
        } else {
            klass = .opaqueCandidate
        }
        guard let ackKey = AckCacheKey.compute(msgId: frame.msgId, recipientNodeId: claimed,
                                               signature: signature) else {
            return .refusedBadFrame
        }
        guard let record = AckFrameRecord.of(ackKey: ackKey, msgId: frame.msgId, recipientNodeId: claimed,
                                             signature: signature, encodedFrame: encoded,
                                             receivedFrom: receivedFrom,
                                             remainingLifetimeMs: AckObligationDriver.ackCandidateLifetimeMs,
                                             verificationClass: klass) else {
            return .refusedBadFrame
        }
        if let sqlite = store as? SqliteAckStore { return sqlite.admitUnderQuota(record) }
        return store.storeCandidate(record)
    }

    /// Candidates admitted without a verified origin enter the bounded relay
    /// window under the 8-day ACK-retention policy of section 14 (the clock
    /// policy proper belongs to the retention sweep, T84).
    static let ackCandidateLifetimeMs: Int64 = 8 * 24 * 60 * 60 * 1000
}
