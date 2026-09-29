import XCTest
import Foundation
import CoreBluetooth
import CryptoKit
import GodstoneCore
@testable import GodstoneMesh

// ================================================================================================
// GS-INTEGRATION-001 `real-adapters` (step 5.5/5.6): THE iOS CROSS-PLATFORM WORKER.
//
// *** THE CLAUSE THIS FILE ANSWERETH, IN THE PLAN'S OWN WORDS: "launches Swift/macOS and Android/Robolectric
// workers, relays exact characteristic bytes between their OS facades". ***
//
// *A single-process host run can only ever prove a relation between two nodes of ONE platform, because the rig
// substitutes the radio and re-enters the SAME platform's real entry points.* **PROVING THAT AN iOS OS FACADE AND AN
// ANDROID OS FACADE CAN CARRY ONE ANOTHER'S BYTES REQUIRES TWO PROCESSES AND A REAL WIRE BETWEEN THEM.** THIS IS
// THE iOS END OF THAT WIRE.
//
// *** THE WORKER OWNS ITS OWN LADDER AND ITS OWN INGRESS. *** *The coordinator
// (`tools/readiness/run_board1_integration.py`) hands over UNINTERPRETED octet strings and never learns what they
// mean: it frames them with a length prefix, records them verbatim, and passes them on. **This file re-enters them
// at the REAL CoreBluetooth entry points the rig already re-enters its own deliveries through**
// (`processPeripheralReceiveWrite` on the responder leg, `processPeripheralUpdateValue` on the initiator leg) **and
// captures what its own stack is handed at the writer outlets** (`HostPeripheral.onWrite` for the initiator's
// `writeValue`, the responder manager's `onUpdate` for `updateValue`). *That is the whole of the transport: the
// radio is a pipe.*
//
// *** WHAT IS REAL, AND WHAT IS SUBSTITUTED -- NAMED, NOT GLOSSED. ***
//
//   * REAL: the composition root (`MeshRuntime.createArchiveOnlyHostComposition` over on-disk temp URLs), the
//     `MeshNode`, the `BleTransport`, both `SqliteMessageStore`s, the role election, the trusted Noise handshake
//     (`TrustedHandshakeController` through `SessionManager`), the record framer and reassembler, the writer leases,
//     the recipient inbox and its canonical ACK, and the delivery tracker.
//   * SUBSTITUTED, exactly as the rig substitutes them: the `CBCentralManager`/`CBPeripheralManager` pair, the host
//     keychain facade, the wipe journal -- **and the radio itself, which is a pair of FIFOs owned by the
//     coordinator.** *No `PeerEvent.Found` is synthesised, no receiver is called directly, no frame is minted and no
//     store row is written by this file.*
//
// *** THE SENDER IS THE ELECTION'S INITIATOR, AND THAT IS A PRODUCTION FACT RATHER THAN A CONVENIENCE. ***
// *`MeshNode.dispatchDirect` offereth to `currentPeers()` -- the ROUTE-ELIGIBLE view, which only
// `trustedPeerDidConnect` filleth, and production publish eth APPLICATION LinkReady solely inside
// `takeInboundKeyConfirmation`'s RESPONSE branch. **Only the party that ISSUES the challenge receives that echo, and
// that is the election's INITIATOR.*** **SO THE COORDINATOR SEATS THE SENDER AS THE INITIATOR, AND IT CAN DO SO
// HONESTLY: each worker mints its identity from a seed the coordinator names, reports its hint, and -- if the
// production election would make the wrong side the opener -- is asked to re-mint with another seed BEFORE anything
// at all has happened.** *A reseed is a fresh identity over a fresh estate, not a role forced against the
// election.*
//
// *** macOS-HOST-ONLY, AND THE GUARD IS STRUCTURAL RATHER THAN DECLARATIVE. *** *Foundation FIFOs and a raw
// `xctest` launch are unavailable under the iOS Simulator, so the whole file is inside `#if os(macOS)`: the
// simulator lane compiles it to NOTHING and therefore registers no empty case.*
//
// **AN ORDINARY (ROLE-LESS) INVOCATION IS NOT AN EMPTY TEST**: it executes the worker's own boundary contract -- the
// framing round-trip over hostile octets, and the refusal of an incomplete launch -- so the default lane carries a
// real assertion rather than a no-op.
// ================================================================================================
#if os(macOS)

import Darwin

final class GsIntegration001CrossPlatformWorkerTests: XCTestCase {

    // ============================================================================================
    // MARK: - the worker protocol (the ONLY things that cross the process boundary)
    // ============================================================================================

    private enum WireKey {
        static let role = "GS_INTEGRATION_ROLE"
        static let inPath = "GS_INTEGRATION_IN"
        static let outPath = "GS_INTEGRATION_OUT"
        static let root = "GS_INTEGRATION_ROOT"
        static let variant = "GS_INTEGRATION_VARIANT"
        static let deadline = "GS_INTEGRATION_DEADLINE_S"
    }

    /// *** THE FRAMING, IDENTICAL ON BOTH ENDS OF EVERY PIPE. ***
    ///
    ///     u32be header_len | header(utf8 canonical json) | u32be payload_len | payload
    ///
    /// *Length-delimited rather than newline-delimited -- **because a protocol payload may contain any octet,
    /// including newlines and NULs.***
    enum Framing {
        static let maxHeader = 1 << 22
        static let maxPayload = 1 << 24

        struct Record {
            let header: [String: Any]
            let payload: Data
            var kind: String { (header["kind"] as? String) ?? "" }
        }

        static func frame(header: [String: Any], payload: Data) -> Data {
            let head = (try? JSONSerialization.data(withJSONObject: header, options: [.sortedKeys]))
                ?? Data("{}".utf8)
            var out = Data()
            var headLen = UInt32(head.count).bigEndian
            var payLen = UInt32(payload.count).bigEndian
            withUnsafeBytes(of: &headLen) { out.append(contentsOf: $0) }
            out.append(head)
            withUnsafeBytes(of: &payLen) { out.append(contentsOf: $0) }
            out.append(payload)
            return out
        }

        /// The total byte length of the record at the head of `buffer`, or nil when it is not whole yet.
        static func recordLength(_ buffer: Data) -> Int? {
            guard buffer.count >= 4 else { return nil }
            let headLen = Int(readU32(buffer, 0))
            guard headLen <= maxHeader, buffer.count >= 4 + headLen + 4 else { return nil }
            let payLen = Int(readU32(buffer, 4 + headLen))
            guard payLen <= maxPayload else { return nil }
            return 4 + headLen + 4 + payLen
        }

        static func parseOne(_ buffer: Data) -> Record? {
            guard let len = recordLength(buffer), buffer.count >= len else { return nil }
            // *** ABSOLUTE-INDEX SAFE, AND THAT IS A MEASURED REPAIR RATHER THAN A PRECAUTION. ***
            //
            // *`nextRecord` consumeth a whole record with `buffer.removeFirst(len)`, **WHICH MOVETH `startIndex`
            // AND DOES NOT RE-BASE THE REMAINING BYTES** -- so the tail's first octet liveth at `startIndex`, and a
            // helper that indexed from ZERO TRAPPED (`EXC_BREAKPOINT`/SIGTRAP, measured in the coordinator's first
            // live run at `Framing.readU32`).* **Every offset is therefore taken from `startIndex`, and the payload
            // is a slice of the same base.**
            let base = buffer.startIndex
            let headLen = Int(readU32(buffer, 0))
            let head = Data(buffer[(base + 4)..<(base + 4 + headLen)])
            let payload = Data(buffer[(base + 4 + headLen + 4)..<(base + len)])
            guard let header = (try? JSONSerialization.jsonObject(with: head)) as? [String: Any] else { return nil }
            return Record(header: header, payload: payload)
        }

        private static func readU32(_ data: Data, _ at: Int) -> UInt32 {
            // *Offsets are relative to `startIndex`, so a slice readeth the same layout as a fresh `Data`.*
            let base = data.startIndex + at
            return (UInt32(data[base]) << 24) | (UInt32(data[base + 1]) << 16)
                | (UInt32(data[base + 2]) << 8) | UInt32(data[base + 3])
        }
    }

    private enum Variant: String {
        case honest, altered, mismatched, replay, nullsession
    }

    /// The node this worker builds. *Its OWN transport is the endpoint; nothing else is built here, because the
    /// production handshake needs no second station -- the foreign platform IS the peer.*
    private static let endpoint = "ios-endpoint"

    // ============================================================================================
    // MARK: - the entry point, in two roles
    // ============================================================================================

    /// *** ONE TEST METHOD. With `GS_INTEGRATION_ROLE` set it IS the worker; without it, it checks the worker's own
    /// boundary contract. *** *The coordinator selects this method explicitly with `-XCTest`, so the worker is never
    /// a default-suite empty or skipped test; the role-less invocation is a real assertion about the framing and the
    /// launch refusal.*
    func testGSINT001CrossPlatformWorker() throws {
        let env = ProcessInfo.processInfo.environment
        guard let role = env[WireKey.role] else {
            try ContractSelfCheck.run()
            return
        }
        let worker = try CrossPlatformWorker(role: role, env: env)
        defer { worker.close() }
        try worker.runReportingRefusal()
    }

    /// *** THE ROLE-LESS HALF: THE WORKER'S OWN BOUNDARY LAWS, ASSERTED RATHER THAN ASSUMED. ***
    enum ContractSelfCheck {
        static func run() throws {
            // (1) THE FRAMING SURVIVES HOSTILE OCTETS -- which is the entire reason it is length-delimited.
            let hostile = Data([0x00, 0x0A, 0x0D, 0xFF, 0x00, 0x7B, 0x22, 0x0A])
                + Data(repeating: 0x0A, count: 300) + Data([0x00, 0x00, 0x00, 0x01])
            let framed = Framing.frame(header: ["v": 1, "kind": "frame", "platform": "ios", "epoch": 7],
                                       payload: hostile)
            let parsed = Framing.parseOne(framed)
            XCTAssertNotNil(parsed, "the worker's own framing must parse what it framed")
            XCTAssertEqual(parsed?.payload, hostile,
                           "*** THE PAYLOAD MUST SURVIVE THE FRAMING OCTET-FOR-OCTET, NEWLINES AND NULS INCLUDED. ***")
            XCTAssertEqual(parsed?.header["epoch"] as? Int, 7)
            XCTAssertNil(Framing.parseOne(framed.dropLast()),
                         "*** A TRUNCATED FRAME MUST NOT PARSE: a partial record is never a record. ***")

            // (2) AN INCOMPLETE LAUNCH IS REFUSED, never silently downgraded to a no-op worker.
            let complete = [WireKey.role: "sender", WireKey.inPath: "/tmp/gs-in",
                            WireKey.outPath: "/tmp/gs-out", WireKey.root: "/tmp/gs-estate"]
            for (missing, env) in [
                ("the input FIFO", complete.filter { $0.key != WireKey.inPath }),
                ("the output FIFO", complete.filter { $0.key != WireKey.outPath }),
                ("the estate root", complete.filter { $0.key != WireKey.root }),
                ("a known role", complete.merging([WireKey.role: "bystander"]) { _, new in new }),
            ] {
                XCTAssertThrowsError(
                    try CrossPlatformWorker(role: env[WireKey.role] ?? "sender", env: env),
                    "*** A LAUNCH MISSING \(missing) MUST BE REFUSED. *** *A worker that carried on with a missing "
                        + "end of its wire would hang the coordinator on a marker that could never arrive.*")
            }
        }
    }

    // ============================================================================================
    // MARK: - the worker
    // ============================================================================================

    final class CrossPlatformWorker {
        enum Failure: Error, CustomStringConvertible {
            case refused(String)
            var description: String { if case .refused(let r) = self { return r }; return "refused" }
        }

        private let role: String                 // "sender" | "recipient"
        private let variant: Variant
        private let estateRoot: URL
        private let deadline: TimeInterval
        private let inFD: Int32
        private let outFD: Int32

        /// *** THE ROLES THIS WORKER KNOWETH. *** *The two cross-platform seats. **The durable-boundary recovery
        /// roles are NOT here: the macOS isle's crash campaign is the child-process SIGKILL campaign in
        /// `GsIntegration001ProcessTests`, which the coordinator launch eth directly -- so this worker never serves a
        /// crash role, and an unknown role is REFUSED rather than silently becoming a no-op.***
        static let knownRoles: Set<String> = ["sender", "recipient"]

        private var rig: RealTransportHostRig
        private var seedByte: UInt8 = 0xC1
        private let writeLock = NSLock()

        // ---- the remote peer, as the other platform advertised it over the pipe -------------------------
        private var remoteNodeId: Data?
        private var remoteNodeHint: Data?
        private var remoteStaticPub: Data?

        // ---- this endpoint's seat on the relation -------------------------------------------------------
        private var peerHandle: UUID?
        private var isInitiator = false
        private var initiatorPeripheral: RealTransportHostRig.HostPeripheral?
        private var responderSeated = false

        // ---- the message and the evidence ---------------------------------------------------------------
        private var trackedMsgId: Data?
        private var authoredFrame: FrameV2?
        private var ringBaseline = 0
        private var reported = false
        private var buffer = Data()

        init(role: String, env: [String: String]) throws {
            guard CrossPlatformWorker.knownRoles.contains(role) else {
                throw Failure.refused("the role '\(role)' is not one this worker knoweth")
            }
            guard let root = env[WireKey.root] else { throw Failure.refused("no estate root was given") }
            guard let inPath = env[WireKey.inPath], FileManager.default.fileExists(atPath: inPath) else {
                throw Failure.refused("the input FIFO is absent or was not named")
            }
            guard let outPath = env[WireKey.outPath], FileManager.default.fileExists(atPath: outPath) else {
                throw Failure.refused("the output FIFO is absent or was not named")
            }
            self.role = role
            self.variant = Variant(rawValue: env[WireKey.variant] ?? "honest") ?? .honest
            self.estateRoot = URL(fileURLWithPath: root)
            self.deadline = Double(env[WireKey.deadline] ?? "300") ?? 300
            // *** BOTH ENDS OPENED RDWR, SO NEITHER SIDE BLOCKS ON THE OTHER'S OPEN AND EVERY READ IS BOUNDED. ***
            // *`open(path, O_RDONLY)` would block until a writer appeared, and a worker that blocked there could not
            // bound its own wait; opened RDWR the pipe always has both ends, so `read` is the only thing that waits.*
            self.inFD = open(inPath, O_RDWR)
            self.outFD = open(outPath, O_RDWR)
            guard inFD >= 0 else { throw Failure.refused("the input FIFO could not be opened") }
            guard outFD >= 0 else { throw Failure.refused("the output FIFO could not be opened") }
            try FileManager.default.createDirectory(at: estateRoot, withIntermediateDirectories: true)
            self.rig = RealTransportHostRig(fixtureRoot: CrossPlatformWorker.rootFor(URL(fileURLWithPath: root), seedByte: 0xC1))
        }

        func close() {
            rig.tearDown()
            Darwin.close(inFD)
            Darwin.close(outFD)
        }

        /// *Static, because `init` must not touch `self` before every stored property is set.*
        private static func rootFor(_ root: URL, seedByte: UInt8) -> URL {
            root.appendingPathComponent(String(format: "seed-%02x", seedByte), isDirectory: true)
        }

        private func rootFor(seedByte: UInt8) -> URL {
            Self.rootFor(estateRoot, seedByte: seedByte)
        }

        // ---------------------------------------------------------------------------------------------
        // the pipe
        // ---------------------------------------------------------------------------------------------

        func emit(_ kind: String, payload: Data = Data(), header: [String: Any] = [:]) {
            var head: [String: Any] = ["v": 1, "kind": kind, "platform": "ios", "role": role,
                                       "variant": variant.rawValue]
            for (k, v) in header { head[k] = v }
            let bytes = Framing.frame(header: head, payload: payload)
            writeLock.lock()
            defer { writeLock.unlock() }
            bytes.withUnsafeBytes { raw in
                var off = 0
                while off < bytes.count {
                    let n = write(outFD, raw.baseAddress!.advanced(by: off), bytes.count - off)
                    if n <= 0 { break }
                    off += n
                }
            }
        }

        /// *** BOUNDED. A missing record is a NAMED REFUSAL, never a hang. ***
        func nextRecord(timeout: TimeInterval) throws -> Framing.Record {
            let deadlineAt = Date().addingTimeInterval(timeout)
            while Date() < deadlineAt {
                if let len = Framing.recordLength(buffer), let rec = Framing.parseOne(buffer) {
                    buffer.removeFirst(len)
                    return rec
                }
                var chunk = [UInt8](repeating: 0, count: 1 << 16)
                let n = read(inFD, &chunk, chunk.count)
                if n > 0 {
                    buffer.append(contentsOf: chunk[0..<n])
                } else {
                    usleep(2_000)
                }
            }
            throw Failure.refused("no record arrived within \(Int(timeout))s")
        }

        func expect(_ kind: String, timeout: TimeInterval) throws -> Framing.Record {
            let rec = try nextRecord(timeout: timeout)
            guard rec.kind == kind else {
                throw Failure.refused("expected `\(kind)`, got `\(rec.kind)`")
            }
            return rec
        }

        // ---------------------------------------------------------------------------------------------
        // the run
        // ---------------------------------------------------------------------------------------------

        /// *** *** A REFUSAL IS REPORTED, NEVER THROWN: THE WORKER NAMES ITS OWN OUTCOME AND RETURNS. *** ***
        ///
        /// *THE DEFECT THIS CLOSES, MEASURED IN THE LIVE COORDINATOR RUN (android->ios `mismatched`): a throw raised
        /// anywhere in this worker's exchange path -- the seat, the ingress, the dispatch -- KILLED the process, and
        /// the coordinator's wait for the `ready` marker then found it EXITED (`THE swift-mismatched WORKER EXITED
        /// (status=1) BEFORE its ready marker`).* **So a REFUSAL and a BROKEN HARNESS looked exactly alike, which is
        /// the one confusion this worker's refusal vocabulary existeth to prevent -- and the control could never
        /// reach the verdict it was built to produce.**
        ///
        /// **THE REPORT CLAIMETH NOTHING IT DOES NOT KNOW: the transport's own rejection ring carrieth whatever the
        /// production doors refused, and an EMPTY ring is reported as empty. The coordinator's refusal tests require
        /// a NON-EMPTY `refusal` string, so this can make a genuine refusal OBSERVABLE but can never MANUFACTURE
        /// one.** *The typed reason still travels on the record, so a harness fault is legible rather than silent.*
        func runReportingRefusal() throws {
            do {
                try run()
            } catch {
                emit("refuse", header: refusalHeader(["reason": "the worker's exchange ended in a refusal: \(error)"]))
            }
        }

        func run() throws {
            try buildEndpoint(seed: seedByte)
            emit("hello", header: identityHeader())

            // *** THE COORDINATOR MAY ASK FOR A RE-MINT, AND IT MAY DO SO HONESTLY. ***
            //
            // *THE FACT THAT MAKETH IT NECESSARY IS PRODUCTION'S, AND IT IS NAMED RATHER THAN WORKED AROUND: a node
            // is reachable in the ROUTE-ELIGIBLE view only through `trustedPeerDidConnect`, which production
            // reacheth only from `publishApplicationLinkReadyOnce`, which is reached only from
            // `takeInboundKeyConfirmation`'s RESPONSE branch -- **and only the party that ISSUES the challenge
            // receives that echo, which is the election's INITIATOR.** So a SENDER seated as the responder would
            // dispatch to nobody.*
            //
            // **NOTHING HAS HAPPENED YET when a re-mint is asked for** -- no link, no session, no store row -- *so a
            // fresh identity over a fresh estate is a DIFFERENT HONEST ELECTION rather than a role forced against
            // the election.*
            var attempts = 0
            while true {
                let directive = try nextRecord(timeout: deadline)
                switch directive.kind {
                case "mint":
                    attempts += 1
                    guard attempts <= 16 else {
                        throw Failure.refused("the coordinator asked for more than 16 re-mints; refusing rather "
                                              + "than grinding")
                    }
                    try reseed(UInt8((directive.header["seed"] as? Int) ?? Int(seedByte)))
                    emit("hello", header: identityHeader())
                case "peer":
                    try acceptPeer(directive)
                    return try continueAfterPeer()
                case "bye":
                    return
                default:
                    throw Failure.refused("unexpected `\(directive.kind)` before a peer was named")
                }
            }
        }

        private func continueAfterPeer() throws {
            // ---- (3) THE SEAT ------------------------------------------------------------------------
            let setup = try expect("setup", timeout: deadline)
            isInitiator = (setup.header["seat"] as? String) == "initiator"
            // *** BOTH SEATS ARE DRIVEN EAGERLY, AND THAT IS A MEASURED REQUIREMENT RATHER THAN A CONVENIENCE. ***
            //
            // *THE RESPONDER'S SEAT CANNOT BE LAZY HERE: in a one-sided cross-process ladder the initiator's
            // link-info write-back is answered LOCALLY (nothing crosses the wire for it), so the responder's first
            // inbound byte is the initiator's HS1 -- an INBOX write. **A responder that waited for a linkInfo write
            // before seating would drop that HS1 and never negotiate.*** *So the responder seateth from the
            // ADVERTISED hint the coordinator carried, exactly as the Android twin doth.*
            // *** THE RING BASELINE IS TAKEN *BEFORE* THE SEAT, SO A REFUSAL TAKEN AT THE SEAT IS VISIBLE. ***
            //
            // *MEASURED IN THE LIVE COORDINATOR RUN (android->ios `mismatched`): the FOREIGN INITIATOR advertiseth a
            // hint that its own sealed binding will not prove, and the responder's link-info door runneth
            // `BleRoleElection` on that record BEFORE any session existeth -- so the door can refuse AT THE SEAT.*
            // **A baseline taken after the seat would discard exactly the ring entry that recordeth the control's
            // refusal, and the loop's `refreshReports` would then observe nothing.**
            ringBaseline = ringCount()
            if isInitiator {
                try seatEndpoint()
            } else {
                // *** *** A SEAT THAT CANNOT BE TAKEN IS THE CONTROL'S OWN REFUSAL, NOT A WORKER CRASH. *** ***
                //
                // *THE DEFECT THIS CLOSES, MEASURED: `seatResponder` THREW when its inbound link-info write door
                // refused, and a throw from `continueAfterPeer` KILLED the worker -- the coordinator's wait for the
                // `ready` marker then found the process EXITED (`THE swift-mismatched WORKER EXITED (status=1)
                // BEFORE its ready marker`), so the `mismatched` control could never reach its verdict in this
                // direction.* **The expected outcome of that control IS a refusal at the sealed-binding boundary
                // (the sender's advertised hint does not match its authenticated static key), and a refusal is
                // REPORTED rather than fatal: the transport's own rejection ring carrieth it, `refreshReports`
                // emitteth it as the worker's `observe`, and the control is judged on its own verdict.** *A worker
                // that died instead would make a REFUSED control indistinguishable from a broken harness, which is
                // exactly the confusion this worker's refusal vocabulary existeth to prevent.*
                do {
                    try seatResponder()
                } catch {
                    // *The seat's own words are kept -- a refusal that named no reason would be worse than the crash
                    // it replaced -- and the loop below still runs, so the ring is polled and the refusal observed.*
                    emit("refuse", header: refusalHeader([
                        "reason": "the responder's seat was refused by the foreign initiator's own record: \(error)"]))
                }
            }
            emit("ready", header: ["seat": isInitiator ? "initiator" : "responder",
                                   "handle": peerHandle.map { $0.uuidString } ?? "",
                                   "remote_hint": remoteNodeHint.map(hex) ?? "",
                                   "advertised_hint": hex(advertisedHint())])

            // ---- (4) THE EXCHANGE --------------------------------------------------------------------
            // *** AUTHORING AND DISPATCH ARE SPLIT BY THE `authored` MARKER, AND THAT SPLIT IS WHAT MAKETH THE
            // ALTERED-RECORD CONTROL PRECISE. ***
            //
            // *THE COORDINATOR CANNOT DECODE A PAYLOAD (a coordinator that could parse a frame could manufacture
            // one), so it cannot tell a handshake record from a DATA record by inspection. **WHAT IT CAN SEE IS
            // ORDER**: every byte this endpoint put on the wire BEFORE it announced `authored` belongeth to the
            // handshake, and every byte AFTER it is the sealed DATA record the control is about.* **So the marker is
            // emitted once the frame IS AUTHORED and before it is dispatched, the coordinator marks that instant,
            // and it tamper eth only the records that cross after it.** *That is a metadata-level discriminator, and
            // it is the only one a non-decoding coordinator may use.*
            var authored = false
            var dispatched = false
            // *** THE RELEASE IS STICKY, AND THAT IS A CORRECTNESS REQUIREMENT RATHER THAN A NICETY. ***
            //
            // *THE COORDINATOR MAY SEND `go` BEFORE THE HANDSHAKE HATH COMPLETED (in the honest and mismatched
            // controls it send eth `go` at once, when it has nothing to hold back) -- and the producer is not yet
            // AUTHORED at that instant, because authoring waiteth for `isReady()`. **A release that were consumed
            // once and dropped would never be seen again, and the DATA record would never leave.*** *So the release
            // is RECORDED and the dispatch happen eth when BOTH `authored` AND `released` stand.*
            var released = false
            var lastReport = ""
            let started = Date()
            while Date().timeIntervalSince(started) < deadline {
                if role == "sender", !authored, isReady() {
                    try author()
                    emit("authored", header: ["msg_id": trackedMsgId.map(hex) ?? ""])
                    authored = true
                }
                if role == "sender", authored, released, !dispatched {
                    try dispatch()
                    dispatched = true
                }
                let rec: Framing.Record
                do {
                    rec = try nextRecord(timeout: 2.0)
                } catch {
                    lastReport = refreshReports(ifChangedFrom: lastReport)
                    continue
                }
                switch rec.kind {
                case "inject":
                    try inject(rec)
                    if role == "recipient" { try carryAckIfDurable() }
                case "go":
                    // *** THE COORDINATOR'S PERMISSION TO PUT THE DATA RECORD ON THE WIRE -- REMEMBERED, SO A
                    // RELEASE THAT ARRIVETH BEFORE THE AUTHORING IS NOT LOST. ***
                    released = true
                case "reconnect":
                    try reconnect()
                    emit("ready", header: ["seat": isInitiator ? "initiator" : "responder",
                                           "reconnected": true,
                                           "handle": peerHandle.map { $0.uuidString } ?? ""])
                case "bye":
                    refreshReports(ifChangedFrom: "")
                    return
                default:
                    break
                }
                lastReport = refreshReports(ifChangedFrom: lastReport)
            }
            refreshReports(ifChangedFrom: "")
        }

        // ---------------------------------------------------------------------------------------------
        // construction, and the re-mint
        // ---------------------------------------------------------------------------------------------

        private func identityHeader() -> [String: Any] {
            guard let node = rig.node(GsIntegration001CrossPlatformWorkerTests.endpoint) else { return ["node_id": "", "node_hint": ""] }
            let binding = (try? node.identity.issueIdentityBinding().encode()) ?? Data()
            return ["node_id": hex(node.identity.nodeId),
                    // *** `node_hint` IS THE ADVERTISED HINT (the `mismatched` control lies here); `real_hint` is
                    // the identity's own. *** *The coordinator electeth on the REAL hints and checketh that the
                    // advertised pair elects the same way, so the mismatch control cannot accidentally move the
                    // role election and produce a refusal for the wrong reason.*
                    "node_hint": hex(advertisedHint()),
                    "real_hint": hex(node.identity.nodeHint),
                    "static_dh_pub": hex(node.identity.staticDhPublicKey),
                    "binding": hex(binding),
                    "seed": Int(seedByte)]
        }

        private func buildEndpoint(seed: UInt8) throws {
            seedByte = seed
            try rig.makeNode(label: GsIntegration001CrossPlatformWorkerTests.endpoint, seedByte: seed, staticPrivByte: seed &+ 1)
            try rig.open(GsIntegration001CrossPlatformWorkerTests.endpoint)
        }

        /// *** A FRESH IDENTITY OVER A FRESH ESTATE -- NOT A ROLE FORCED AGAINST THE ELECTION. ***
        private func reseed(_ next: UInt8) throws {
            rig.tearDown()
            try? FileManager.default.removeItem(at: rootFor(seedByte: seedByte))
            seedByte = next
            try FileManager.default.createDirectory(at: rootFor(seedByte: next),
                                                    withIntermediateDirectories: true)
            rig = RealTransportHostRig(fixtureRoot: rootFor(seedByte: next))
            peerHandle = nil
            initiatorPeripheral = nil
            responderSeated = false
            ringBaseline = 0
            remoteNodeId = nil
            remoteNodeHint = nil
            remoteStaticPub = nil
            try buildEndpoint(seed: next)
        }

        /// *** PIN THE REMOTE BINDING THROUGH THE FROZEN VALIDATOR -- THE SAME THREE CALLS `LabRuntime` MAKETH. ***
        /// *The ACK road verifyeth its own fresh signature through the resolver, and the inbox verifyeth the signed
        /// author through the same repository, so a peer whose binding is not pinned would be refused for a reason
        /// that had nothing to do with the cross-platform wire.*
        private func acceptPeer(_ message: Framing.Record) throws {
            guard let node = rig.node(GsIntegration001CrossPlatformWorkerTests.endpoint),
                  let idHex = message.header["node_id"] as? String,
                  let hintHex = message.header["node_hint"] as? String,
                  let staticHex = message.header["static_dh_pub"] as? String,
                  let bindHex = message.header["binding"] as? String,
                  let id = Data(gsHex: idHex), let hint = Data(gsHex: hintHex),
                  let staticPub = Data(gsHex: staticHex), let binding = Data(gsHex: bindHex) else {
                throw Failure.refused("the `peer` message did not carry a well-formed identity")
            }
            let realHex = (message.header["real_hint"] as? String) ?? hintHex
            guard let realHint = Data(gsHex: realHex), realHint.count == 4 else {
                throw Failure.refused("the peer's real hint was not a four-octet value")
            }
            remoteNodeId = id
            // *** THE ADVERTISED HINT IS WHAT THE SEAT BINDETH (so the `mismatched` control can lie); THE REAL HINT
            // IS WHAT PINNETH THE BINDING. ***
            //
            // *THE FROZEN VALIDATOR REFUSETH A BINDING WHOSE DERIVED HINT IS NOT THE ONE GIVEN -- **so pinning with
            // the advertised hint would refuse the mismatched control AT THE PIN, before any session existed, which is
            // NOT the boundary the control is about.*** **The binding is therefore pinned against the identity's OWN
            // hint (the TOFU step a real discovery would make), and the MISMATCH IS LEFT FOR THE SEALED HANDSHAKE to
            // refuse -- which is exactly the handshake boundary the plan nameth.**
            remoteNodeHint = hint
            remoteStaticPub = staticPub
            guard case .valid(let validated) = IdentityBindingValidator.validate(
                serialized: binding, authenticatedRemoteStaticKey: staticPub,
                advertisedNodeHint: realHint) else {
                throw Failure.refused("the frozen validator refused the remote binding at its own hint")
            }
            switch node.runtime.peerRepository.applyValidatedBinding(validated) {
            case .firstSeenPinned, .accepted:
                return
            default:
                throw Failure.refused("the repository refused the pinned remote binding")
            }
        }

        // ---------------------------------------------------------------------------------------------
        // the seat
        // ---------------------------------------------------------------------------------------------

        /// *** THE ENDPOINT'S OWN LADDER, DRIVEN TO THE POINT WHERE THE HANDSHAKE MAY CROSS THE WIRE. ***
        ///
        /// *THE INITIATOR'S GROUND: discovery, the connect leg, the service and characteristic walks, the link-info
        /// read answered from the hint the `peer` message carried, the write-back, and then the notification-state
        /// reduction -- **which is where production issueth HS1 by itself** (`processPeripheralNotificationStateUpdated`
        /// -> `.physicalDuplexReady` -> `beginTrustedHandshake`).*
        ///
        /// *THE RESPONDER'S GROUND IS ITS OWN INBOUND INGRESS AND NOTHING ELSE: it holds no outbound relation at all,
        /// so its seat is completed by `seatResponder()` -- the responder-side inbound write and subscribe doors --
        /// **driving the initiator's ladder on the responder would be a fabricated relation, and the responder would
        /// then hold two.**
        private func seatEndpoint() throws {
            guard let node = rig.node(GsIntegration001CrossPlatformWorkerTests.endpoint) else { throw Failure.refused("no endpoint node") }
            guard isInitiator else { return }   // the responder's seat is `seatResponder()`'s
            guard let hint = remoteNodeHint else { throw Failure.refused("no remote hint to seat against") }
            let handle = UUID()
            peerHandle = handle
            node.ble.refreshLocalLinkInfoSnapshotSync()
            let central = node.ble.requireContextCentralForTest()
            let peripheral = RealTransportHostRig.HostPeripheral(identifier: handle)
            initiatorPeripheral = peripheral
            let bridged = unsafeBitCast(peripheral, to: CBPeripheral.self)
            // *** THE INITIATOR'S EGRESS: every byte the stack handeth `writeValue` crosseth the pipe, verbatim. ***
            peripheral.onWrite = { [weak self] bytes, uuid in
                self?.emit("frame", payload: bytes, header: [
                    "characteristic": uuid == BleTransport.linkInfoCharacteristicUuid
                        ? "linkInfo" : "inbox",
                    "epoch": node.ble.currentTransportEpoch])
            }
            let advertised = self.advertisedHint()
            node.ble.processCentralDidDiscover(
                central, peripheral: bridged,
                advertisementData: [CBAdvertisementDataServiceDataKey: [BleTransport.serviceUuid:
                    RealTransportHostRig.linkInfo(hint)]],
                rssi: NSNumber(value: -60), sourceEpoch: node.ble.currentTransportEpoch)
            guard let delegate = node.ble.getRelationDelegate(handle) else {
                throw Failure.refused("the discovery door admitted no relation for the endpoint")
            }
            _ = node.ble.processCentralConnect(peerId: handle, peripheral: bridged,
                                               sourceEpoch: node.ble.currentTransportEpoch, from: central)
            _ = node.ble.processPeripheralDiscoverServices(bridged, delegate: delegate, error: nil)
            _ = node.ble.processPeripheralDiscoverCharacteristics(
                bridged, delegate: delegate, service: RealTransportHostRig.provisionedService(), error: nil)
            _ = node.ble.processPeripheralUpdateValue(
                bridged, delegate: delegate,
                characteristic: CBMutableCharacteristic(
                    type: BleTransport.linkInfoCharacteristicUuid, properties: [.read, .write],
                    value: RealTransportHostRig.linkInfo(hint), permissions: [.readable, .writeable]), error: nil)
            _ = node.ble.processPeripheralWriteValue(
                bridged, delegate: delegate,
                characteristic: CBMutableCharacteristic(
                    type: BleTransport.linkInfoCharacteristicUuid, properties: [.read, .write],
                    value: advertised, permissions: [.readable, .writeable]), error: nil)
            _ = node.ble.processPeripheralNotificationStateUpdated(
                bridged, delegate: delegate,
                characteristic: RealTransportHostRig.NotifyingInboxCharacteristic(
                    type: BleTransport.inboxCharacteristicUuid, properties: [.read, .write, .notify],
                    value: nil, permissions: [.readable, .writeable]), error: nil)
        }

        /// The hint this endpoint advertiseth. **Honest: its own. Mismatched: a FOREIGN but well-formed four-octet
        /// hint -- the exact class the election bindeth and the frozen validator then refuseth against the
        /// authenticated static key.**
        ///
        /// *** *** THE LIE IS CHOSEN TO PRESERVE THE ELECTION, WHICH IS WHAT MAKETH THE CONTROL MEASURE THE BINDING. *** ***
        ///
        /// *MEASURED IN THE LIVE COORDINATOR RUN: the former lie was `own ^ 0xFF`, which for this pair's real hints
        /// moved the UNSIGNED-LEXICOGRAPHIC election the WRONG WAY (`real elect(0bb99473, bfeb4baf) = initiator`, but
        /// `advertised elect(f4466b8c, bfeb4baf) = responder`) -- so the coordinator's own seat law refused with `THE
        /// ADVERTISED HINTS ELECT AGAINST THE REAL ONES` BEFORE any session existed.* **A control refused at the
        /// election measureth the ELECTION, not the sealed binding it existeth to test.**
        ///
        /// **AND THE REQUIREMENT IS SATISFIABLE WITHOUT EVEN KNOWING THE PEER'S HINT, WHICH MATTERS BECAUSE THIS VALUE
        /// IS EMITTED IN `hello` BEFORE THE PEER IS NAMED.** *The sender is seated as the production election's
        /// INITIATOR, which by the production law meaneth `real(self) < real(peer)` unsigned-lexicographically; the
        /// peer advertiseth its REAL hint (only the SENDER carrieth the `mismatched` variant), so `real(peer)` standeth
        /// fixed.* **THEREFORE EVERY HINT STRICTLY BELOW `real(self)` IS ALSO STRICTLY BELOW `real(peer)` -- the
        /// ordering is transitive.** *So the lie is the lexicographic predecessor: the first non-zero octet is
        /// decremented (which alone maketh the value strictly smaller) and every later octet is maximised, so the
        /// result is as large as a strictly-smaller value can be -- and, differing in that octet, is never the
        /// identity's own hint.*
        ///
        /// *(The Android twin carrieth the same repair at `RealTransportHostRigWorkerTest.kt`'s `advertisedHint()`.)*
        private func advertisedHint() -> Data {
            guard let node = rig.node(GsIntegration001CrossPlatformWorkerTests.endpoint) else { return Data() }
            guard variant == .mismatched else { return node.identity.nodeHint }
            var lie = node.identity.nodeHint
            guard let at = lie.firstIndex(where: { $0 != 0 }) else {
                // *UNREACHABLE WHILE WE ARE THE ELECTED INITIATOR: an all-zero hint could only be the smaller of the
                // pair if the peer's hint were negative, which no four-octet value is. A named refusal rather than a
                // silent return that would move the election.*
                return Data()
            }
            lie[at] -= 1
            for later in lie.indices where later > at { lie[later] = 0xFF }
            return lie
        }

        /// *** THE RESPONDER'S SEAT, COMPLETED BY THE FOREIGN PLATFORM'S OWN LINK-INFO WRITE. ***
        /// *The inbound write seats the relation and the following subscribe seats the subscription (which is what
        /// retaineth the destination central this leg's writer pumpeth towards -- `pumpLocked(isInitiator:false)`
        /// refuseth without it, so the recipient's ACK could not otherwise leave).* **Both are the REAL entry
        /// points; nothing is fabricated.**
        private func seatResponder() throws {
            guard let node = rig.node(GsIntegration001CrossPlatformWorkerTests.endpoint), !responderSeated else { return }
            guard let hint = remoteNodeHint else { throw Failure.refused("no remote hint to seat against") }
            let handle = UUID()
            peerHandle = handle
            let manager = node.ble.currentManagerContextForTest()?.peripheral
                ?? node.ble.requireContextPeripheralForTest()
            node.ble.setMutableInboxCharacteristicForTesting(CBMutableCharacteristic(
                type: BleTransport.inboxCharacteristicUuid, properties: [.read, .write, .notify],
                value: nil, permissions: [.readable, .writeable]))
            // *** THE RESPONDER'S EGRESS: the manager's own outlet is where `updateValue` crosseth the pipe. ***
            for m in node.factory.peripheralManagers {
                m.onUpdate = { [weak self] out, _, uuid in
                    self?.emit("frame", payload: out, header: [
                        "characteristic": uuid == BleTransport.linkInfoCharacteristicUuid
                            ? "linkInfo" : "inbox",
                        "epoch": node.ble.currentTransportEpoch])
                }
            }
            // *** THE INBOUND WRITE IS THE FOREIGN INITIATOR'S OWN LINK-INFO, SO ITS PAYLOAD IS THE REMOTE'S
            // ADVERTISED HINT -- NOT OURS. *** *The driver runneth `BleRoleElection.elect(localHint, remoteHint)` on
            // this record; passing our own hint makes it compare the local hint with itself, which the Android twin
            // measured as `.tie` -> `RejectWrite("Tie or invalid role election")`.*
            let write = node.ble.processInboundWrite(
                centralId: handle, rawData: RealTransportHostRig.linkInfo(hint),
                sourceEpoch: node.ble.currentTransportEpoch, from: manager)
            guard String(describing: write).hasPrefix("accept") else {
                throw Failure.refused("the responder's inbound write door refused: \(write)")
            }
            let subscribe = node.ble.processInboundSubscribe(
                centralId: handle, central: rig.centralPresent(handle),
                sourceEpoch: node.ble.currentTransportEpoch, from: manager)
            guard String(describing: subscribe).hasPrefix("accept") else {
                throw Failure.refused("the responder's subscribe door refused: \(subscribe)")
            }
            responderSeated = true
        }

        // ---------------------------------------------------------------------------------------------
        // authoring (sender) and the ingress (recipient)
        // ---------------------------------------------------------------------------------------------

        /// *** AUTHOR THE FRAME ONLY -- no dispatch and no wire. *** *The `authored` marker is emitted after this
        /// returneth, so everything the endpoint wrote before it belongeth to the handshake.*
        private func author() throws {
            guard let node = rig.node(GsIntegration001CrossPlatformWorkerTests.endpoint) else { throw Failure.refused("no endpoint node") }
            guard let recipientId = remoteNodeId, let recipientPub = remoteStaticPub else {
                throw Failure.refused("no remote identity to author for")
            }
            guard role == "sender" else { return }
            var nonce = Data(count: 16)
            _ = nonce.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
            let createdAt = Int64(Date().timeIntervalSince1970)
            let body = Data("cross-platform \(variant.rawValue)".utf8)
            let container = try SignedMessageV1.author(
                senderIdentityPriv: node.signingSeed,
                senderIdentityPub: node.identity.signingPublicKey,
                senderNodeId: node.identity.nodeId,
                recipientNodeId: recipientId,
                messageNonce: nonce,
                createdAtEpochSeconds: createdAt,
                priority: .direct, timeQuality: .userConfirmed,
                bodyUtf8: body)
            let frame = try gsAwaitBlocking {
                try await node.node.router.buildSealedMessage(
                    plaintext: container, recipientNodeId: recipientId, recipientStaticPub: recipientPub,
                    identity: LogicalMessageIdentity(createdAtEpochSeconds: createdAt, messageNonce: nonce),
                    priority: .direct)
            }
            authoredFrame = frame
            trackedMsgId = frame.msgId
        }

        /// *** THE DISPATCH IS THE NODE'S OWN PRODUCTION ROAD: `enqueueDirectOutbound` commits the held frame and
        /// the queued delivery row in ONE transaction, and the `send` closure is the transport's OWN `ble.send`. ***
        private func dispatch() throws {
            guard let node = rig.node(GsIntegration001CrossPlatformWorkerTests.endpoint) else { throw Failure.refused("no endpoint node") }
            guard let frame = authoredFrame, let recipientId = remoteNodeId else {
                throw Failure.refused("nothing was authored to dispatch")
            }
            guard let handle = peerHandle else { throw Failure.refused("no handle to dispatch over") }
            _ = node.node.dispatchDirect(frame, expectedRecipient: recipientId) { f, peer in
                guard peer == handle else { return false }
                return node.ble.send(f, to: peer) == .admitted
            }
        }

        /// *** RE-ENTER THE FOREIGN PLATFORM'S EXACT BYTES AT THIS PLATFORM'S REAL OS INGRESS. ***
        private func inject(_ rec: Framing.Record) throws {
            guard let node = rig.node(GsIntegration001CrossPlatformWorkerTests.endpoint) else { throw Failure.refused("no endpoint node") }
            let characteristic = (rec.header["characteristic"] as? String) ?? "inbox"
            let isLinkInfo = characteristic == "linkInfo"
            let uuid = isLinkInfo ? BleTransport.linkInfoCharacteristicUuid : BleTransport.inboxCharacteristicUuid
            if !isInitiator {
                // *** THE RESPONDER'S DOOR: the manager's real `processPeripheralReceiveWrite`. ***
                guard responderSeated, let handle = peerHandle,
                      let manager = node.ble.currentManagerContextForTest()?.peripheral else {
                    emit("refuse", header: refusalHeader(["reason": "the responder holds no seated relation to "
                                                                    + "receive a foreign record"]))
                    return
                }
                let request = RealTransportHostRig.HostRequest(
                    pinnedCentral: rig.centralPresent(handle), uuid: uuid, value: rec.payload)
                _ = node.ble.processPeripheralReceiveWrite(
                    manager, requests: [unsafeBitCast(request, to: CBATTRequest.self)],
                    sourceEpoch: node.ble.currentTransportEpoch)
                if !isLinkInfo {
                    node.ble.processPeripheralIsReadyToUpdateSubscribers(
                        manager, sourceEpoch: node.ble.currentTransportEpoch)
                }
            } else {
                // *** THE INITIATOR'S DOOR: the peripheral's real `processPeripheralUpdateValue`. ***
                guard let handle = peerHandle, let delegate = node.ble.getRelationDelegate(handle) else {
                    emit("refuse", header: refusalHeader(["reason": "the initiator holds no relation delegate for "
                                                                    + "the foreign record; no session stands"]))
                    return
                }
                let peripheral = initiatorPeripheral ?? RealTransportHostRig.HostPeripheral(
                    identifier: handle)
                initiatorPeripheral = peripheral
                let bridged = unsafeBitCast(peripheral, to: CBPeripheral.self)
                _ = node.ble.processPeripheralUpdateValue(
                    bridged, delegate: delegate,
                    characteristic: CBMutableCharacteristic(
                        type: uuid, properties: [.read, .write, .notify], value: rec.payload,
                        permissions: [.readable, .writeable]), error: nil)
                node.ble.processPeripheralIsReady(bridged, delegate: delegate)
            }
        }

        /// *** THE RECIPIENT'S CANONICAL ACK, DRAINED FROM PRODUCTION'S OWN OUTBOX -- NEVER MINTED. ***
        private func carryAckIfDurable() throws {
            guard let node = rig.node(GsIntegration001CrossPlatformWorkerTests.endpoint), let handle = peerHandle else { return }
            guard let msgId = durableMsgId() else { return }
            guard let ack = node.node.drainAckOutboxForLink(1).first else { return }
            _ = node.ble.send(ack, to: handle)
            emit("ack", header: ["msg_id": hex(ack.msgId), "for": hex(msgId),
                                 "epoch": node.ble.currentTransportEpoch])
        }

        /// *** A FRESH SESSION: the transport restarteth into a new epoch and the seat is re-driven. ***
        /// *Ciphertext from an unrelated Noise session is not an interchangeable fixture, so the replay control must
        /// face a session the captured bytes were never sealed under -- **and the fresh session is what proves
        /// it.***
        private func reconnect() throws {
            guard let node = rig.node(GsIntegration001CrossPlatformWorkerTests.endpoint) else { throw Failure.refused("no endpoint node") }
            _ = rig.restartTransport(label: GsIntegration001CrossPlatformWorkerTests.endpoint)
            peerHandle = nil
            initiatorPeripheral = nil
            responderSeated = false
            buffer.removeAll()
            if isInitiator { try seatEndpoint() } else { try seatResponder() }
            ringBaseline = ringCount()
            _ = node
        }

        // ---------------------------------------------------------------------------------------------
        // observations (every one readeth an OWNER, never a worker counter)
        // ---------------------------------------------------------------------------------------------

        private func isReady() -> Bool {
            guard let node = rig.node(GsIntegration001CrossPlatformWorkerTests.endpoint), let handle = peerHandle else { return false }
            return node.ble.linkReadyPeersForTest().contains(handle)
                && node.node.knownPeersForTest().contains(handle)
        }

        private func ringCount() -> Int {
            rig.node(GsIntegration001CrossPlatformWorkerTests.endpoint)?.ble.rejectionRecordsForTest().count ?? 0
        }

        /// The receiver's durable row: **the exact `msgId` the FOREIGN platform authored, as this store holds it.**
        private func durableMsgId() -> Data? {
            guard let node = rig.node(GsIntegration001CrossPlatformWorkerTests.endpoint) else { return nil }
            let held = node.messageStore.allHeldMsgIds()
            if let tracked = trackedMsgId, held.contains(tracked) { return tracked }
            return held.first
        }

        private func isDelivered() -> Bool {
            guard let msgId = trackedMsgId,
                  let row = rig.deliveryRow(GsIntegration001CrossPlatformWorkerTests.endpoint, msgId: msgId) else { return false }
            return row.state == .acknowledgedByRecipient
        }

        /// *** THE REFUSAL EVIDENCE IS READ FROM THE RECEIVER'S OWN REJECTION RING, BY NAME -- NEVER BY DECODING A
        /// PAYLOAD. *** *Only entries NEW since the seat are reported, so a refusal recorded during the honest phase
        /// cannot be mistaken for the control's own refusal.*
        private func newRingEntries() -> [String] {
            guard let node = rig.node(GsIntegration001CrossPlatformWorkerTests.endpoint) else { return [] }
            let ring = node.ble.rejectionRecordsForTest()
            return ring.dropFirst(ringBaseline).map { $0.site + "|" + $0.reason }
        }

        private func refusalHeader(_ extra: [String: Any] = [:]) -> [String: Any] {
            var head: [String: Any] = ["ring": newRingEntries().joined(separator: ", "),
                                       "ring_size": newRingEntries().count,
                                       "ready": isReady(),
                                       "held_rows": rig.node(GsIntegration001CrossPlatformWorkerTests.endpoint)?.messageStore
                                           .allHeldMsgIds().count ?? 0]
            for (k, v) in extra { head[k] = v }
            return head
        }

        /// *** EMIT ONLY ON A CHANGE OF THE OWNER'S OWN STATE. ***
        ///
        /// *The exchange loop polls, so an unconditional report would fill the pipe with identical lines and the
        /// coordinator's transcript with noise. **The token is the owner's OWN answer** -- the durable row's id, the
        /// delivery state, or the newest refusal's text -- so a report is emitted exactly when something production
        /// did changed the answer.*
        @discardableResult
        private func refreshReports(ifChangedFrom previous: String) -> String {
            guard let node = rig.node(GsIntegration001CrossPlatformWorkerTests.endpoint) else { return previous }
            let held = node.messageStore.allHeldMsgIds()
            if role == "recipient" {
                if let msgId = durableMsgId() {
                    let token = "row:" + hex(msgId)
                    if token != previous {
                        reported = true
                        emit("observe", header: ["durable_row": "present", "msg_id": hex(msgId),
                                                 "held_rows": held.count])
                    }
                    return token
                }
                let refusals = newRingEntries()
                if !refusals.isEmpty {
                    let token = "refused:" + refusals.joined(separator: "|")
                    if token != previous {
                        reported = true
                        emit("observe", header: ["durable_row": "absent", "held_rows": held.count,
                                                 "refusal": refusals.joined(separator: ", "),
                                                 "ring_size": refusals.count, "ready": isReady()])
                    }
                    return token
                }
                return previous
            }
            // *** A SENDER CAN BE REFUSED TOO, AND THAT MUST BE REPORTED: the `mismatched` control's refusal may
            // land on the SENDER's own handshake (which is where production refuseth a binding the sealed round
            // cannot authenticate), so a sender that only ever reported delivery states would make the control
            // unobservable. ***
            let refusals = newRingEntries()
            if let msgId = trackedMsgId, let row = rig.deliveryRow(GsIntegration001CrossPlatformWorkerTests.endpoint, msgId: msgId) {
                let state = row.state == .acknowledgedByRecipient ? "DELIVERED" : "QUEUED"
                let token = "delivery:\(state):\(refusals.count)"
                if token != previous {
                    emit("observe", header: ["delivery": state, "msg_id": hex(msgId),
                                             "durable_row": held.contains(msgId) ? "present" : "retired",
                                             "refusal": refusals.joined(separator: ", "),
                                             "ring_size": refusals.count])
                }
                return token
            }
            if !refusals.isEmpty {
                let token = "refused:" + refusals.joined(separator: "|")
                if token != previous {
                    emit("observe", header: ["durable_row": "absent", "refusal":
                        refusals.joined(separator: ", "), "ring_size": refusals.count])
                }
                return token
            }
            return previous
        }

        private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
    }
}

/// *** ONE AUTHORING AWAIT, AT FILE SCOPE. ***
///
/// *`SignedMessageV1.author` and `Router.buildSealedMessage` are `async`; this worker is a synchronous test body.
/// The bridge is a file-scope function rather than a method of the test class, **because the nested worker type
/// cannot reach the test class's own members** -- and a bounded one, so an authoring road that never returned would
/// fail the worker instead of hanging the coordinator's wait.*
private func gsAwaitBlocking<T>(_ body: @escaping () async throws -> T) throws -> T {
    let sem = DispatchSemaphore(value: 0)
    var outcome: Result<T, Error>?
    Task {
        do { outcome = .success(try await body()) } catch { outcome = .failure(error) }
        sem.signal()
    }
    guard sem.wait(timeout: .now() + 60) == .success else {
        throw GsIntegration001CrossPlatformWorkerTests.CrossPlatformWorker.Failure.refused(
            "the authoring road never returned within 60s")
    }
    switch outcome {
    case .success(let value): return value
    case .failure(let error): throw error
    case nil: throw GsIntegration001CrossPlatformWorkerTests.CrossPlatformWorker.Failure.refused(
        "the authoring road produced no outcome")
    }
}

private extension Data {
    init?(gsHex: String) {
        let chars = Array(gsHex)
        guard chars.count % 2 == 0 else { return nil }
        var out = Data(capacity: chars.count / 2)
        var index = 0
        while index < chars.count {
            guard let byte = UInt8(String(chars[index...index + 1]), radix: 16) else { return nil }
            out.append(byte)
            index += 2
        }
        self = out
    }
}

#endif
