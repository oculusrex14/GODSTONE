import Foundation
import CryptoKit

/// ADR-002 Canonical BLE Record Layer Types & Constants (Phase C8.4C).
public enum BleRecordType: UInt8, Sendable, CaseIterable, Equatable {
    case hs1 = 0x11
    case hs2 = 0x12
    case hs3 = 0x14
    case data = 0x18
    case close = 0x21
}

public enum BleRecordConstants {
    public static let magic: UInt8 = 0x47
    public static let headerBytes: Int = 8
    public static let maxRecord: Int = 16384
    public static let maxFragments: Int = 64
    public static let maxConcurrent: Int = 4
    public static let reassemblyTimeoutSeconds: TimeInterval = 30.0
}

public struct BleRecordHeader: Equatable, Sendable {
    public let magic: UInt8
    public let recordType: BleRecordType
    public let recordSeq: UInt8
    public let fragIndex: UInt8
    public let fragCount: UInt8
    public let totalLen: UInt16
    public let headerCheck: UInt8

    public init(
        magic: UInt8 = BleRecordConstants.magic,
        recordType: BleRecordType,
        recordSeq: UInt8,
        fragIndex: UInt8,
        fragCount: UInt8,
        totalLen: UInt16,
        headerCheck: UInt8
    ) {
        self.magic = magic
        self.recordType = recordType
        self.recordSeq = recordSeq
        self.fragIndex = fragIndex
        self.fragCount = fragCount
        self.totalLen = totalLen
        self.headerCheck = headerCheck
    }
}

public struct BleRecordFragment: Equatable, Sendable {
    public let header: BleRecordHeader
    public let payload: Data

    public init(header: BleRecordHeader, payload: Data) {
        self.header = header
        self.payload = Data(payload)
    }
}

public struct BleReassembledRecord: Equatable, Sendable {
    public let recordType: BleRecordType
    public let recordSeq: UInt8
    public let payload: Data

    public init(recordType: BleRecordType, recordSeq: UInt8, payload: Data) {
        self.recordType = recordType
        self.recordSeq = recordSeq
        self.payload = Data(payload)
    }
}

public enum BleRecordCodec {

    public static func computeHeaderCheck(
        _ b0: UInt8,
        _ b1: UInt8,
        _ b2: UInt8,
        _ b3: UInt8,
        _ b4: UInt8,
        _ b5: UInt8,
        _ b6: UInt8
    ) -> UInt8 {
        b0 ^ b1 ^ b2 ^ b3 ^ b4 ^ b5 ^ b6
    }

    public static func computeHeaderCheck(_ data7: Data) -> UInt8 {
        let bytes = [UInt8](data7)
        precondition(bytes.count == 7, "computeHeaderCheck requires exactly 7 bytes")
        return computeHeaderCheck(
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6]
        )
    }

    public static func canonicalFragmentBounds(
        totalLen: Int,
        fragCount: Int,
        fragIndex: Int
    ) throws -> (start: Int, end: Int) {
        if totalLen == 0 {
            guard fragCount == 1, fragIndex == 0 else {
                throw NSError(domain: "BleRecordCodec", code: 1, userInfo: [NSLocalizedDescriptionKey: "totalLen=0 requires fragCount=1, fragIndex=0"])
            }
            return (0, 0)
        }

        guard fragCount >= 1, fragCount <= BleRecordConstants.maxFragments else {
            throw NSError(domain: "BleRecordCodec", code: 2, userInfo: [NSLocalizedDescriptionKey: "fragCount outside 1..\(BleRecordConstants.maxFragments)"])
        }
        guard fragIndex >= 0, fragIndex < fragCount else {
            throw NSError(domain: "BleRecordCodec", code: 3, userInfo: [NSLocalizedDescriptionKey: "fragIndex outside 0..<\(fragCount)"])
        }

        let stride = (totalLen + fragCount - 1) / fragCount
        let start = fragIndex * stride
        guard start < totalLen else {
            throw NSError(domain: "BleRecordCodec", code: 4, userInfo: [NSLocalizedDescriptionKey: "start >= totalLen"])
        }
        let end = min(start + stride, totalLen)
        return (start, end)
    }

    public static func encodeHeader(
        recordType: BleRecordType,
        recordSeq: UInt8,
        fragIndex: UInt8,
        fragCount: UInt8,
        totalLen: UInt16,
        magic: UInt8 = BleRecordConstants.magic
    ) throws -> Data {
        guard fragCount >= 1, fragCount <= BleRecordConstants.maxFragments else {
            throw NSError(domain: "BleRecordCodec", code: 10, userInfo: [NSLocalizedDescriptionKey: "fragCount out of bounds"])
        }
        guard fragIndex < fragCount else {
            throw NSError(domain: "BleRecordCodec", code: 11, userInfo: [NSLocalizedDescriptionKey: "fragIndex >= fragCount"])
        }
        guard totalLen <= BleRecordConstants.maxRecord else {
            throw NSError(domain: "BleRecordCodec", code: 12, userInfo: [NSLocalizedDescriptionKey: "totalLen > maxRecord"])
        }

        let b0 = magic
        let b1 = recordType.rawValue
        let b2 = recordSeq
        let b3 = fragIndex
        let b4 = fragCount
        let b5 = UInt8((totalLen >> 8) & 0xFF)
        let b6 = UInt8(totalLen & 0xFF)
        let b7 = computeHeaderCheck(b0, b1, b2, b3, b4, b5, b6)

        return Data([b0, b1, b2, b3, b4, b5, b6, b7])
    }

    public static func decodeHeader(_ data: Data) -> BleRecordHeader? {
        guard data.count >= BleRecordConstants.headerBytes else { return nil }

        let bytes = [UInt8](data.prefix(BleRecordConstants.headerBytes))
        let b0 = bytes[0]
        guard b0 == BleRecordConstants.magic else { return nil }

        guard let recordType = BleRecordType(rawValue: bytes[1]) else { return nil }

        let b2 = bytes[2]
        let b3 = bytes[3]
        let b4 = bytes[4]
        let totalLen = (UInt16(bytes[5]) << 8) | UInt16(bytes[6])
        let b7 = bytes[7]

        let expectedChk = computeHeaderCheck(b0, bytes[1], b2, b3, b4, bytes[5], bytes[6])
        guard b7 == expectedChk else { return nil }

        guard b4 >= 1, b4 <= BleRecordConstants.maxFragments else { return nil }
        guard b3 < b4 else { return nil }
        guard totalLen <= BleRecordConstants.maxRecord else { return nil }

        return BleRecordHeader(
            magic: b0,
            recordType: recordType,
            recordSeq: b2,
            fragIndex: b3,
            fragCount: b4,
            totalLen: totalLen,
            headerCheck: b7
        )
    }

    public static func decodeFragment(_ data: Data) -> BleRecordFragment? {
        guard data.count >= BleRecordConstants.headerBytes else { return nil }

        guard let header = decodeHeader(data) else { return nil }

        guard let (start, end) = try? canonicalFragmentBounds(
            totalLen: Int(header.totalLen),
            fragCount: Int(header.fragCount),
            fragIndex: Int(header.fragIndex)
        ) else {
            return nil
        }

        let expectedPayloadLen = end - start
        let actualPayloadLen = data.count - BleRecordConstants.headerBytes
        guard actualPayloadLen == expectedPayloadLen else { return nil }

        let payload = Data(data.dropFirst(BleRecordConstants.headerBytes))
        return BleRecordFragment(header: header, payload: payload)
    }
}

public enum BleRecordFragmenter {

    public static func fragment(
        recordType: BleRecordType,
        recordSeq: UInt8,
        payload: Data,
        maxAttValueLength: Int
    ) throws -> [Data] {
        let capacity = maxAttValueLength - BleRecordConstants.headerBytes
        guard capacity >= 1 else {
            throw NSError(domain: "BleRecordFragmenter", code: 1, userInfo: [NSLocalizedDescriptionKey: "capacity < 1"])
        }

        let totalLen = payload.count
        guard totalLen <= BleRecordConstants.maxRecord else {
            throw NSError(domain: "BleRecordFragmenter", code: 2, userInfo: [NSLocalizedDescriptionKey: "payload size > maxRecord"])
        }

        if totalLen == 0 {
            let hdr = try BleRecordCodec.encodeHeader(
                recordType: recordType,
                recordSeq: recordSeq,
                fragIndex: 0,
                fragCount: 1,
                totalLen: 0
            )
            return [hdr]
        }

        let fragCount = (totalLen + capacity - 1) / capacity
        guard fragCount <= BleRecordConstants.maxFragments else {
            throw NSError(domain: "BleRecordFragmenter", code: 3, userInfo: [NSLocalizedDescriptionKey: "fragCount > maxFragments"])
        }

        let stride = (totalLen + fragCount - 1) / fragCount
        var fragments: [Data] = []
        fragments.reserveCapacity(fragCount)

        let payloadBytes = [UInt8](payload)
        for i in 0..<fragCount {
            let start = i * stride
            let end = min(start + stride, totalLen)
            let fragPayload = Data(payloadBytes[start..<end])
            let hdr = try BleRecordCodec.encodeHeader(
                recordType: recordType,
                recordSeq: recordSeq,
                fragIndex: UInt8(i),
                fragCount: UInt8(fragCount),
                totalLen: UInt16(totalLen)
            )
            var fullFrag = hdr
            fullFrag.append(fragPayload)
            fragments.append(fullFrag)
        }

        return fragments
    }
}

public final class BleRecordReassembler: @unchecked Sendable {

    private final class InFlightAssembly {
        let recordType: BleRecordType
        let totalLen: Int
        let fragCount: Int
        let stride: Int
        var receivedIndices: Set<Int>
        var buffer: [UInt8]
        let createdTime: TimeInterval
        var lastActivityTime: TimeInterval
        let lease: AssemblyLease

        init(
            recordType: BleRecordType,
            totalLen: Int,
            fragCount: Int,
            stride: Int,
            lease: AssemblyLease,
            createdTime: TimeInterval
        ) {
            self.recordType = recordType
            self.totalLen = totalLen
            self.fragCount = fragCount
            self.stride = stride
            self.receivedIndices = []
            self.buffer = [UInt8](repeating: 0, count: totalLen)
            self.createdTime = createdTime
            self.lastActivityTime = createdTime
            self.lease = lease
        }
    }

    private let timeProvider: () -> TimeInterval
    /// T20: the owner's seat for expiry notices, bound late by the
    /// connection once its own identity is fully standing. Unbound, the
    /// reassembler still releases buffers at the term; only the notice is
    /// withheld, and the absolute term itself never depends on the seat.
    internal var onLeaseExpiry: ((AssemblyLease) -> Void)?
    /// T20: the owner's seat for the relation key the leases name; the
    /// unclaimed placeholder stands until the connection binds its own.
    internal var relationKeyOf: () -> RelationKey = { LifetimeControl.unclaimedRelation }
    private var nextAdmissionId: UInt64 = 1
    private var inFlight: [UInt8: InFlightAssembly] = [:]
    private var completedFingerprints: [UInt8: String] = [:]
    private let lock = NSLock()

    public init(timeProvider: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 }) {
        self.timeProvider = timeProvider
    }

    /// The lease register's probes, for the lifetime suites and the owner.
    internal func activeLeaseOf(_ seq: UInt8) -> AssemblyLease? {
        lock.lock()
        defer { lock.unlock() }
        return inFlight[seq]?.lease
    }

    internal func leaseCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return inFlight.count
    }

    /// The sweep every ingress runs, at the clock's current instant.
    internal func sweepAtNow() {
        lock.lock()
        defer { lock.unlock() }
        evictExpired(now: timeProvider())
    }

    /// The sweep every ingress runs, exposed for the timer-race schedules.
    internal func sweepExpiredAt(_ now: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        evictExpired(now: now)
    }

    private func evictExpired(now: TimeInterval) {
        var expired: [UInt8] = []
        for (seq, asm) in inFlight {
            if (now - asm.lastActivityTime) > BleRecordConstants.reassemblyTimeoutSeconds {
                expired.append(seq)
            }
        }
        for seq in expired {
            inFlight.removeValue(forKey: seq)
        }

        // T20: the absolute term of the assembly lease. Whatever the sliding
        // window above has been made to forget by late arrivals - fresh or
        // duplicate, each of which refreshes the activity stamp - the
        // deadline the admission minted stands fast: no refresh moves it.
        // When it passes, the buffers are released here and the owner is
        // told below, so a dribbling peer cannot pin the slots and buffers
        // indefinitely through the window courtesy.
        var lapsed: [AssemblyLease] = []
        for (_, asm) in inFlight {
            if now >= asm.lease.deadlineMono {
                lapsed.append(asm.lease)
            }
        }
        for lease in lapsed {
            inFlight.removeValue(forKey: lease.seq)
        }
        for lease in lapsed {
            onLeaseExpiry?(lease)
        }
    }

    private func computeFingerprint(recordType: BleRecordType, seq: UInt8, payload: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: Data([recordType.rawValue, seq]))
        hasher.update(data: payload)
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public func receiveFragmentBytes(_ data: Data) -> BleReassembledRecord? {
        guard let frag = BleRecordCodec.decodeFragment(data) else { return nil }
        return receiveFragment(frag)
    }

    public func receiveFragment(_ frag: BleRecordFragment) -> BleReassembledRecord? {
        lock.lock()
        defer { lock.unlock() }

        let now = timeProvider()
        evictExpired(now: now)

        let hdr = frag.header
        let seq = hdr.recordSeq

        let totalLen = Int(hdr.totalLen)
        let fragCount = Int(hdr.fragCount)
        let fragIndex = Int(hdr.fragIndex)

        let asm: InFlightAssembly
        if let existing = inFlight[seq] {
            asm = existing
        } else {
            // Check capacity
            guard inFlight.count < BleRecordConstants.maxConcurrent else {
                return nil // Reject 5th concurrent assembly
            }

            let stride = totalLen > 0 ? (totalLen + fragCount - 1) / fragCount : 0
            // T20: the admission mints the absolute lease once. The token
            // names the relation, the sequence, an admission identity that
            // never repeats for this reassembler, and the deadline; nothing
            // later received moves any of it.
            let minted = AssemblyLease(relationKey: relationKeyOf(), seq: seq,
                                      admissionId: nextAdmissionId,
                                      deadlineMono: now + AssemblyLease.leaseSeconds)
            nextAdmissionId += 1
            let newAsm = InFlightAssembly(
                recordType: hdr.recordType,
                totalLen: totalLen,
                fragCount: fragCount,
                stride: stride,
                lease: minted,
                createdTime: now
            )
            inFlight[seq] = newAsm
            asm = newAsm
        }

        // Validate metadata consistency
        guard asm.recordType == hdr.recordType,
              asm.totalLen == totalLen,
              asm.fragCount == fragCount else {
            inFlight.removeValue(forKey: seq)
            return nil
        }

        asm.lastActivityTime = now

        guard let (start, end) = try? BleRecordCodec.canonicalFragmentBounds(
            totalLen: totalLen,
            fragCount: fragCount,
            fragIndex: fragIndex
        ) else {
            inFlight.removeValue(forKey: seq)
            return nil
        }

        let fragBytes = [UInt8](frag.payload)

        // Check duplicate fragment index
        if asm.receivedIndices.contains(fragIndex) {
            let existingPayload = Array(asm.buffer[start..<end])
            if existingPayload == fragBytes {
                // Idempotent duplicate
                return nil
            } else {
                // Conflicting duplicate: invalidate and fail closed
                inFlight.removeValue(forKey: seq)
                return nil
            }
        }

        // Store fragment payload
        for (offset, byte) in fragBytes.enumerated() {
            asm.buffer[start + offset] = byte
        }
        asm.receivedIndices.insert(fragIndex)

        // Check if complete
        if asm.receivedIndices.count == asm.fragCount {
            let completePayload = Data(asm.buffer)
            inFlight.removeValue(forKey: seq)

            let fp = computeFingerprint(recordType: hdr.recordType, seq: seq, payload: completePayload)
            if completedFingerprints[seq] == fp {
                // Duplicate completion
                return nil
            }

            completedFingerprints[seq] = fp
            return BleReassembledRecord(
                recordType: hdr.recordType,
                recordSeq: seq,
                payload: completePayload
            )
        }

        return nil
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        inFlight.removeAll()
        completedFingerprints.removeAll()
    }
}
