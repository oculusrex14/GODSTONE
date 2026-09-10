//
// RecordWriter.swift - the whole-record writer of the outbound path
//
// T19: the same contract the Android twin keeps, spoken here in the iOS
// voice. The law, stated once:
//
//   reserve(kind, clearLength, capacity) - every check that can refuse a
//       whole record refuses it here, by value, consuming nothing: no
//       nonce is burnt, no sequence number taken, no byte staged. The
//       capacity is the direction's own: the write leg speaks through the
//       peripheral's maximumWriteValueLength(for: .withoutResponse), the
//       update leg through the central manager's maximumUpdateValueLength,
//       so the same record may be fragmented differently at the two ends,
//       each fragmentation lawful for its direction.
//   sealAndQueue / stageSealed  - the one seal (for the data plane) and
//       the one fragmentation, after admission and only once. The already
//       sealed handshake records of the control plane enter through
//       stageSealed, sealed by the controller's own sealer, and share the
//       one window and the one in-flight of their direction.
//   nextOut / completed / rewindInFlight / failed - the pump: at most one
//       value in flight per direction, advanced only by real completions.
//       A write without response has no completion beyond the platform's
//       readiness: the pump treats the stack's acceptance as the signal
//       that the value left, and claims nothing of the remote. A refusal
//       to take the value (canSendWriteWithoutResponse false, updateValue
//       false) re-hands the very same ciphertext fragment when the leg is
//       ready again - never a re-encryption, never an alteration. A
//       partial write failure closes the relation and releases the
//       staging; the durable application data is not the writer's to
//       touch.
//
// The bounds are the card's and the codec's own: a sealed record may not
// exceed min(MAX_RECORD, MAX_FRAGMENTS * (capacity - HEADER_BYTES)); a
// relation holds at most four admitted records; a direction stages at most
// sixteen values and keeps one in flight. Every answer is a value; no
// refusal throws across the platform boundary.
//

import Foundation

/// The typed completion of one staged value as the leg reports it.
public enum WriteCompletion {
    /// The value travelled (or, for a write without response, the stack
    /// took it): the pump may retire it and advance.
    case accepted
    /// The leg's own buffer refused the value: the very same fragment is
    /// re-handed when the leg is ready again. Nothing is lost, nothing is
    /// resealed.
    case queueFull
    /// The leg failed while the value stood in flight: the relation cannot
    /// stand.
    case failed
}

/// The token that identifies one fragment on the wire, carried with the
/// relation it belongs to: a completion is honoured only when it names
/// the operation standing in flight, so a stale or duplicate completion
/// moves nothing.
public struct WriteOperation: Equatable, Sendable {
    public let relationKey: RelationKey
    public let operationId: UInt64
    public let fragmentIndex: Int

    public init(relationKey: RelationKey, operationId: UInt64, fragmentIndex: Int) {
        self.relationKey = relationKey
        self.operationId = operationId
        self.fragmentIndex = fragmentIndex
    }
}

/// The bounded refusals of `RecordWriter.reserve`.
public enum AdmissionError: Equatable {
    /// The sealed record would outgrow the record ceiling or the fragment
    /// ceiling: the 65th fragment is told here, before the seal.
    case notEnoughCapacity(sealedLength: Int, ceiling: Int, fragmentCount: Int)
    /// More than `limit` admitted records stand on the relation.
    case tooManyAdmitted(limit: Int)
    /// The station cannot receive records now.
    case inactive
}

/// The answer of `RecordWriter.reserve`.
public enum ReservationAnswer {
    case admitted(Reservation)
    case refused(AdmissionError)
}

/// The answer of `Reservation.sealAndQueue` and of `RecordWriter.stageSealed`.
public enum SealAnswer: Equatable {
    /// Sealed once, fragmented once, staged; the pump may take it.
    case queued
    /// The seal refused, or the envelope lied about its length: nothing
    /// was consumed - the sequence number stands where it stood.
    case refused(String)
}

/// One reserved whole record. The reservation checked the length, the
/// ceilings and the budgets; `sealAndQueue` now seals the clear text
/// exactly once with the session's sealer, fragments the sealed record
/// exactly once, takes the connection's next sequence number - consumed
/// here and only here - and stages the fragments.
public final class Reservation {
    fileprivate weak var writer: RecordWriter?
    fileprivate let operationId: UInt64
    fileprivate let recordType: BleRecordType
    fileprivate let clearLength: Int
    fileprivate let capacity: Int

    fileprivate init(writer: RecordWriter, operationId: UInt64,
                     recordType: BleRecordType, clearLength: Int, capacity: Int) {
        self.writer = writer
        self.operationId = operationId
        self.recordType = recordType
        self.clearLength = clearLength
        self.capacity = capacity
    }

    /// Seal `payload` with `sealer` (which answers nil when the session
    /// refuses), fragment once, and stage. The payload must be the very
    /// clear text whose length stood reserved; any drift refuses the
    /// seal before anything is consumed.
    public func sealAndQueue(_ payload: Data, sealer: (Data) -> Data?) -> SealAnswer {
        guard let writer = writer else { return .refused("the writer retired") }
        return writer.sealAndQueueOf(self, payload: payload, sealer: sealer)
    }
}

/// The writer of one direction of one relation. It is pure bookkeeping:
/// it owns no thread and speaks to no peripheral; the transport drives
/// the pump loop, because only the transport can ask the leg whether it
/// is ready and hand it the value.
public final class RecordWriter {
    public static let defaultMaxAdmittedRecords = 4
    public static let defaultMaxStagedValues = 16
    public static let defaultMaxInFlight = 1

    /// The envelope the session's seal adds: the nonce the seal carries
    /// and the authentication tag, as the transport ciphertext format
    /// lays them out.
    public static let sealNonceBytes = 8
    public static let sealTagBytes = 16
    public static let sealOverheadBytes =
        RecordWriter.sealNonceBytes + RecordWriter.sealTagBytes

    private let connection: BleConnection
    internal let relationKey: RelationKey
    private let maxAdmittedRecords: Int
    private let maxStagedValues: Int
    private let maxInFlight: Int

    private final class AdmittedRecord {
        let operationId: UInt64
        var fragments: [Data]
        var nextFragment = 0
        var stagedUpTo = 0
        var held: Int { stagedUpTo - nextFragment }
        init(operationId: UInt64, fragments: [Data]) {
            self.operationId = operationId
            self.fragments = fragments
        }
    }

    private var admitted: [AdmittedRecord] = []
    private var inFlight: WriteOperation?
    private var closed = false
    private var nextOperationId: UInt64 = 1
    private var operationsIssued: UInt64 = 0
    private var staleCompletions: UInt64 = 0

    public init(connection: BleConnection, relationKey: RelationKey,
                maxAdmittedRecords: Int = RecordWriter.defaultMaxAdmittedRecords,
                maxStagedValues: Int = RecordWriter.defaultMaxStagedValues,
                maxInFlight: Int = RecordWriter.defaultMaxInFlight) {
        self.connection = connection
        self.relationKey = relationKey
        self.maxAdmittedRecords = maxAdmittedRecords
        self.maxStagedValues = maxStagedValues
        self.maxInFlight = maxInFlight
    }

    /// Everything that can refuse a whole record refuses here, by value,
    /// consuming nothing. `capacity` is the direction's own maximum, as
    /// the adapter reports it for the leg this writer serves.
    public func reserve(recordType: BleRecordType, clearLength: Int,
                        capacity: Int) -> ReservationAnswer {
        if closed || !connection.isActive { return .refused(.inactive) }
        let sealedLength = clearLength + RecordWriter.sealOverheadBytes
        let space = capacity - BleRecordConstants.headerBytes
        if space < 1 || clearLength < 0 {
            return .refused(.notEnoughCapacity(sealedLength: sealedLength, ceiling: 0,
                                               fragmentCount: 0))
        }
        let ceiling = min(BleRecordConstants.maxRecord,
                          BleRecordConstants.maxFragments * space)
        let fragmentCount = sealedLength == 0 ? 1 : (sealedLength + space - 1) / space
        if sealedLength > ceiling || fragmentCount > BleRecordConstants.maxFragments {
            return .refused(.notEnoughCapacity(sealedLength: sealedLength, ceiling: ceiling,
                                               fragmentCount: fragmentCount))
        }
        if admitted.count >= maxAdmittedRecords {
            return .refused(.tooManyAdmitted(limit: maxAdmittedRecords))
        }
        let operationId = nextOperationId
        nextOperationId += 1
        operationsIssued += 1
        return .admitted(Reservation(writer: self, operationId: operationId,
                                    recordType: recordType, clearLength: clearLength,
                                    capacity: capacity))
    }

    /// The one seal, the one fragmentation, the one consumption of the
    /// sequence number. Reached through `Reservation.sealAndQueue` only.
    fileprivate func sealAndQueueOf(_ reservation: Reservation, payload: Data,
                                    sealer: (Data) -> Data?) -> SealAnswer {
        if closed || !connection.isActive {
            return .refused("the relation fell before the seal")
        }
        if payload.count != reservation.clearLength {
            return .refused("the payload drifted from the reservation")
        }
        guard let sealed = sealer(payload) else {
            return .refused("the seal refused")
        }
        if sealed.count != reservation.clearLength + RecordWriter.sealOverheadBytes {
            return .refused("the seal lied about the envelope")
        }
        switch stageRecord(type: reservation.recordType, sealed: sealed,
                           capacity: reservation.capacity,
                           expectedOperation: reservation.operationId) {
        case .queued: return .queued
        case .refused(let why): return .refused(why)
        }
    }

    /// The control plane's admission: the handshake records are already
    /// sealed by the controller's sealer; their fragments enter the same
    /// window of the direction, under the same sequence discipline. The
    /// station's phase is consulted by the connection's own fragmenter,
    /// which gates the record type and consumes the sequence number once.
    public func stageSealed(recordType: BleRecordType, sealed: Data,
                            capacity: Int) -> SealAnswer {
        if closed || !connection.isActive { return .refused("the relation has fallen") }
        if admitted.count >= maxAdmittedRecords {
            return .refused("too many admitted records on the relation")
        }
        let space = capacity - BleRecordConstants.headerBytes
        let ceiling = min(BleRecordConstants.maxRecord,
                          BleRecordConstants.maxFragments * max(0, space))
        let fragmentCount = sealed.count == 0 ? 1 : (sealed.count + space - 1) / space
        if space < 1 || sealed.count > ceiling || fragmentCount > BleRecordConstants.maxFragments {
            return .refused("the sealed record outgrew the ceiling")
        }
        let operationId = nextOperationId
        nextOperationId += 1
        operationsIssued += 1
        // The connection's own entry gates the phase, takes the sequence
        // number exactly once, and fragments once; it answers empty when
        // the station may not carry this record type.
        let fragments = connection.fragmentOutbound(recordType: recordType,
                                                   payload: sealed,
                                                   capacity: capacity)
        guard !fragments.isEmpty else {
            return .refused("the fragmenter refused the record")
        }
        let record = AdmittedRecord(operationId: operationId, fragments: fragments)
        record.stagedUpTo = min(fragments.count, max(0, maxStagedValues - stagedLocked()))
        admitted.append(record)
        return .queued
    }

    /// Measure, then take the sequence number, then fragment - the
    /// fragmenter is reached only when the arithmetic has already
    /// promised it cannot refuse. A refusal after the take would burn a
    /// number without carrying a record: lawful on the wire (the
    /// reassembler knows no contiguity), and it is told as an event.
    private func stageRecord(type: BleRecordType, sealed: Data, capacity: Int,
                             expectedOperation: UInt64) -> SealAnswer {
        let space = capacity - BleRecordConstants.headerBytes
        let ceiling = min(BleRecordConstants.maxRecord,
                          BleRecordConstants.maxFragments * max(0, space))
        let fragmentCount = sealed.count == 0 ? 1 : (sealed.count + space - 1) / space
        if space < 1 || sealed.count > ceiling || fragmentCount > BleRecordConstants.maxFragments {
            return .refused("the sealed record outgrew the ceiling")
        }
        if admitted.count >= maxAdmittedRecords {
            return .refused("the staging filled before the seal")
        }
        guard let seq = connection.takeOutboundSequenceIfReady(type) else {
            return .refused("the station may not carry this record")
        }
        let fragments = try? BleRecordFragmenter.fragment(
            recordType: type, recordSeq: seq, payload: sealed,
            maxAttValueLength: capacity)
        guard let fragments = fragments, !fragments.isEmpty else {
            return .refused("the fragmenter refused the record")
        }
        let record = AdmittedRecord(operationId: expectedOperation, fragments: fragments)
        record.stagedUpTo = min(fragments.count, max(0, maxStagedValues - stagedLocked()))
        admitted.append(record)
        return .queued
    }

    /// Hand the next fragment, if the direction is idle and a record
    /// stands with values in the window. At most one value is ever in
    /// flight.
    public func nextOut() -> (operation: WriteOperation, bytes: Data)? {
        if closed { return nil }
        if inFlight != nil { return nil }
        topUpLocked()
        guard let record = admitted.first(where: { $0.nextFragment < $0.stagedUpTo }) else {
            return nil
        }
        let index = record.nextFragment
        let operation = WriteOperation(relationKey: relationKey,
                                      operationId: record.operationId,
                                      fragmentIndex: index)
        inFlight = operation
        return (operation, record.fragments[index])
    }

    /// A real completion of `operation`. A completion that does not name
    /// the standing in-flight operation is stale or duplicate: it is
    /// counted and changes nothing.
    public func completed(_ operation: WriteOperation) -> Bool {
        guard let standing = inFlight, standing == operation else {
            staleCompletions += 1
            return false
        }
        guard let record = admitted.first(where: { $0.operationId == operation.operationId }),
              record.nextFragment == operation.fragmentIndex else {
            staleCompletions += 1
            return false
        }
        record.nextFragment += 1
        if record.nextFragment >= record.fragments.count,
           record.stagedUpTo >= record.fragments.count {
            admitted.removeAll { $0.operationId == record.operationId }
        }
        inFlight = nil
        topUpLocked()
        return true
    }

    /// The leg refused the value: the in-flight operation stands down so
    /// the very same fragment can be re-handed when the leg is ready
    /// again. Nothing is resealed, nothing is re-fragmented.
    public func rewindInFlight(_ operation: WriteOperation) -> Bool {
        guard let standing = inFlight, standing == operation else {
            staleCompletions += 1
            return false
        }
        inFlight = nil
        return true
    }

    /// The leg failed while the value stood in flight: the relation
    /// cannot stand. The admitted records and every staged value are
    /// released - the durable application data is not the writer's to
    /// touch - and the writer accepts nothing further.
    public func failed(_ operation: WriteOperation) -> Bool {
        guard let standing = inFlight, standing == operation else {
            staleCompletions += 1
            return false
        }
        closed = true
        admitted.removeAll { _ in true }
        inFlight = nil
        return true
    }

    /// The relation fell by other means: release what was staged, accept
    /// nothing further.
    public func shutdown() {
        closed = true
        admitted.removeAll { _ in true }
        inFlight = nil
    }

    private func stagedLocked() -> Int {
        var total = 0
        for record in admitted { total += record.held }
        return total
    }

    /// Fill the head records' windows as far as the bound allows; records
    /// are staged in the order they were admitted.
    private func topUpLocked() {
        var free = maxStagedValues - stagedLocked()
        if free <= 0 { return }
        for record in admitted {
            if record.stagedUpTo >= record.fragments.count { continue }
            let take = min(record.fragments.count - record.stagedUpTo, free)
            record.stagedUpTo += take
            free -= take
            if free <= 0 { return }
        }
    }

    /// The window stands full while some admitted record still waits to
    /// stage and no value can be added: the truth the transport tells to
    /// the ring when it sees it.
    internal func stagingSaturated() -> Bool {
        if stagedLocked() < maxStagedValues { return false }
        for record in admitted {
            if record.stagedUpTo < record.fragments.count { return true }
        }
        return false
    }

    // The witnesses the suite reads: module-internal, as the island's
    // law on test factories commands, invisible to the shipping eye.
    internal func admittedCount() -> Int { admitted.count }
    internal func stagedValues() -> Int { stagedLocked() }
    internal func inFlightOperation() -> WriteOperation? { inFlight }
    internal func staleCompletionsCount() -> UInt64 { staleCompletions }
    internal func operationsIssuedCount() -> UInt64 { operationsIssued }
    internal func isClosed() -> Bool { closed }
    internal func heldRelation() -> RelationKey { relationKey }
    internal func speaksThrough(_ candidate: BleConnection) -> Bool {
        candidate === connection
    }
}
