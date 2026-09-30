import XCTest
import Foundation
import GodstoneCore
@testable import GodstoneMesh

// ================================================================================================
// GS-INTEGRATION-001 `scenarios` (step 6): THE CHILD-PROCESS CRASH HARNESS.
//
// *** THE CLAUSE THIS FILE ANSWERETH, IN THE CARD'S OWN WORDS: "close the lane gate mid-write" is NOT met by a
// graceful close and is NOT met by a timed sleep. *** *The plan's own diagnosis of the earlier arms -- which this
// file replaces in role, not in place -- is exact: `testGSINT001ACrashAfterOutboundEnqueueLeavesTheRowQueued`
// rebuilds a `MeshNode` over the same LIVE store within ONE process, and "A `MeshNode` rebuild releases no
// `sqlite3` handle, reloads no keychain and exits no process, so what they measure is a QUEUE TRANSITION, which is
// real and worth keeping -- and is NOT crash survival."* **AN OBJECT REBIRTH IS NOT A PROCESS DEATH.**
//
// SO THIS FILE KILLS A PROCESS. The discipline, named rather than glossed:
//
//   * **THE PARENT LAUNCHES THE ALREADY-BUILT macOS XCTEST BUNDLE DIRECTLY** with the Xcode `xctest` executable,
//     selecting THIS test plus a child-role environment variable -- never a recursive `swift test` build. *The
//     parent runs the campaign; the SAME selector with the role variable set runs the child. There is no skipped
//     or empty test: an ordinary invocation IS the campaign.*
//   * **BOUNDED PIPES CARRY THE PROTOCOL**: `READY`, `AT_BOUNDARY <name>`, `COMPLETE <name> <PASS|reason>`. *At the
//     named boundary the child flushes its marker and then WAITS; the parent SIGKILLs ITS OWN CHILD, WAITS FOR
//     SIGNAL TERMINATION, and only then launches the recovery child.*
//   * **A MISSING MARKER, A WRONG TERMINATION, A TIMEOUT OR AN EARLY EXIT IS A FAILED SCENARIO** -- never a skip.
//     *The termination is checked with `terminationReason == .uncaughtSignal` and `terminationStatus == SIGKILL`,
//     so a child that exited politely (status 0) or died of anything else FAILS the scenario.*
//   * **ONLY A TEMPORARY ESTATE PATH, SCENARIO IDENTIFIERS AND NON-SECRET EXPECTED IDs CROSS THE BOUNDARY.** *No
//     store, no dictionary, no session and no repository is ever passed; the recovery child REACHES ITS OWN by
//     reopening the estate through the production composition root.*
//   * **THE ESTATE IS THE MECHANISM.** `RealTransportHostRig(fixtureRoot:)` makes the wipe journal, the host
//     keychain facade and both stores file-backed under that root, so a NEW PROCESS reacheth the SAME committed
//     rows, the SAME (possibly deleted) identity keys and the SAME (possibly mid-ladder) wipe journal. *In
//     particular the seed is only written when the estate holds no identity, so a wipe-produced key deletion or a
//     regenerated identity is PRESERVED rather than overwritten by the original seed.*
//
// *** macOS-HOST-ONLY, AND THE GUARD IS STRUCTURAL RATHER THAN DECLARATIVE. *** *Foundation process spawning is
// unavailable under the iOS Simulator, so the whole file is inside `#if os(macOS)`: the simulator lane compiles it
// to NOTHING and therefore cannot launch a child. The cooperative `closeAndReopen` durability arms stay in
// `GsIntegration001ScenarioTests` for the simulator; THIS is where abrupt SIGKILL recovery is proven.*
// ================================================================================================
#if os(macOS)

import Darwin

final class GsIntegration001ProcessTests: XCTestCase {

    // ============================================================================================
    // MARK: - the child protocol (the ONLY things that cross the process boundary)
    // ============================================================================================

    private enum ChildProtocol {
        static let roleKey = "GS_INT_PROC_ROLE"
        static let roleValue = "child"
        static let boundaryKey = "GS_INT_PROC_BOUNDARY"
        static let detailKey = "GS_INT_PROC_DETAIL"
        static let phaseKey = "GS_INT_PROC_PHASE"
        static let estateKey = "GS_INT_PROC_ESTATE"
        static let xctestKey = "GS_INT_PROC_XCTEST"

        static let prepare = "prepare"
        static let recover = "recover"

        static let ready = "READY"
        static let atBoundary = "AT_BOUNDARY"
        static let complete = "COMPLETE"
        static let pass = "PASS"

        /// The selector the parent passes; it is THIS test, which is why an ordinary suite run is the campaign.
        static let selector = "GodstoneMeshTests.GsIntegration001ProcessTests/testGSINT001ProcessCrashCampaign"
    }

    /// One scenario: a durable boundary (and, for `handshake`, which of its two emissions).
    private struct Scenario {
        let boundary: String
        let detail: String?
        var name: String { detail.map { "\(boundary)@\($0)" } ?? boundary }
    }

    private let scenarios: [Scenario] = [
        Scenario(boundary: MeshCheckpointNames.outboundEnqueue, detail: nil),
        Scenario(boundary: MeshCheckpointNames.inboundCommit, detail: nil),
        Scenario(boundary: MeshCheckpointNames.ackCreate, detail: nil),
        Scenario(boundary: MeshCheckpointNames.ackCommit, detail: nil),
        Scenario(boundary: MeshCheckpointNames.senderAckRetire, detail: nil),
        Scenario(boundary: MeshCheckpointNames.preSend, detail: nil),
        Scenario(boundary: MeshCheckpointNames.handshake, detail: MeshCheckpointNames.handshakeDetailPreReady),
        Scenario(boundary: MeshCheckpointNames.handshake, detail: MeshCheckpointNames.handshakeDetailAuthenticated),
    ]

    // ============================================================================================
    // MARK: - the campaign (the parent), and the child dispatch
    // ============================================================================================

    /// *** THE ONE TEST METHOD, IN TWO ROLES, DECIDED BY THE ENVIRONMENT AND NOTHING ELSE. ***
    ///
    /// *Normal invocation (no role variable) IS THE CAMPAIGN. With the role variable set, the SAME selector
    /// performs the child's prepare or recover work -- so the parent never needs a second test, and the file never
    /// registers a skipped or empty case.* **A CHILD THAT FINDS NO BOUNDARY/PHASE FAILS IMMEDIATELY RATHER THAN
    /// FALLING THROUGH INTO THE CAMPAIGN: a misconfigured launch must not fork bomb.**
    func testGSINT001ProcessCrashCampaign() throws {
        let env = ProcessInfo.processInfo.environment
        if env[ChildProtocol.roleKey] == ChildProtocol.roleValue {
            try runChildRole(env: env)
            return
        }
        try runCampaign()
    }

    private func runCampaign() throws {
        let xctest = try resolveXCTestExecutable()
        let bundle = try resolveTestBundlePath()
        // *** THE EXACT INVOCATION IS RECORDED, EXCLUDING SECRETS: the executable, the bundle, the selector and the
        // environment KEYS (never a value that could carry material). ***
        print("GS-INT-PROC harness: executable=\(xctest) bundle=\(bundle) selector=\(ChildProtocol.selector)")
        print("GS-INT-PROC harness: child env keys=[\(ChildProtocol.roleKey), \(ChildProtocol.boundaryKey), "
              + "\(ChildProtocol.detailKey), \(ChildProtocol.phaseKey), \(ChildProtocol.estateKey)] "
              + "(values: a boundary name, a non-secret detail, a phase, and a temporary estate path)")

        var failures: [String] = []
        for scenario in scenarios {
            let estate = FileManager.default.temporaryDirectory
                .appendingPathComponent("gs_proc_\(scenario.name.replacingOccurrences(of: "@", with: "_"))_"
                                        + UUID().uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(at: estate, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: estate) }

            do {
                try runOneScenario(scenario, xctest: xctest, bundle: bundle, estate: estate)
                print("GS-INT-PROC scenario \(scenario.name): PASS")
            } catch {
                let reason = "\(error)"
                failures.append("\(scenario.name): \(reason)")
                print("GS-INT-PROC scenario \(scenario.name): FAIL -- \(reason)")
            }
        }
        XCTAssertTrue(
            failures.isEmpty,
            "*** EVERY NAMED BOUNDARY MUST SURVIVE A REAL SIGKILL AND A REAL REOPEN. *** *A missing marker, a wrong "
                + "termination, a timeout and an early exit are all FAILED scenarios rather than skips.* Observed "
                + "failures: \(failures) ***")
    }

    /// One scenario: prepare child -> marker -> SIGKILL -> verified signal death -> recovery child -> outcome.
    private func runOneScenario(_ scenario: Scenario, xctest: String, bundle: String, estate: URL) throws {
        // ---- (1) THE PREPARE CHILD: it reaches the boundary, flushes its marker, and waits to be killed -----
        let prepare = try launchChild(scenario: scenario, phase: ChildProtocol.prepare,
                                      xctest: xctest, bundle: bundle, estate: estate)
        defer { prepare.terminateIfRunning() }
        try prepare.awaitLine { line in line == ChildProtocol.ready || line.hasPrefix(ChildProtocol.ready + " ") }
        let marker = "\(ChildProtocol.atBoundary) \(scenario.boundary)"
        try prepare.awaitLine { $0 == marker }

        // ---- (2) THE KILL, AND THE PROOF THAT IT WAS A KILL ---------------------------------------------
        let pid = prepare.process.processIdentifier
        guard pid > 0 else { throw ChildError.malformed("the child carried no pid") }
        XCTAssertEqual(
            Darwin.kill(pid, SIGKILL), 0,
            "*** THE PARENT MUST BE ABLE TO SIGKILL THE CHILD IT SPAWNED -- this process, and no other. ***")
        prepare.process.waitUntilExit()
        guard prepare.process.terminationReason == .uncaughtSignal,
              prepare.process.terminationStatus == SIGKILL else {
            throw ChildError.malformed(
                "*** THE CHILD WAS NOT KILLED BY SIGKILL: reason=\(prepare.process.terminationReason) "
                + "status=\(prepare.process.terminationStatus). A graceful exit (status 0) or any other signal is a "
                + "FAILED CRASH SCENARIO, because a cooperative close is not crash proof. ***")
        }
        XCTAssertEqual(prepare.process.terminationStatus, SIGKILL,
                       "the child must die BY SIGNAL, not by a return from main")

        // ---- (3) THE RECOVERY CHILD: a NEW PROCESS over the SAME estate ---------------------------------
        let recover = try launchChild(scenario: scenario, phase: ChildProtocol.recover,
                                      xctest: xctest, bundle: bundle, estate: estate)
        defer { recover.terminateIfRunning() }
        var outcome: String?
        try recover.awaitLine { line in
            guard line.hasPrefix(ChildProtocol.complete + " ") else { return false }
            outcome = line
            return true
        }
        recover.process.waitUntilExit()
        let line = outcome ?? ""
        let expectedPrefix = "\(ChildProtocol.complete) \(scenario.boundary) "
        guard line.hasPrefix(expectedPrefix) else {
            throw ChildError.malformed("the recovery child's completion line did not name the boundary: \(line)")
        }
        let verdict = String(line.dropFirst(expectedPrefix.count))
        XCTAssertEqual(
            recover.process.terminationStatus, 0,
            "*** THE RECOVERY CHILD MUST EXIT CLEANLY AFTER ITS ASSERTIONS. *Its completion line is read first, so a "
                + "non-zero status is a real failure, never a truncation.* Line: \(line) ***")
        guard verdict == ChildProtocol.pass else {
            throw ChildError.malformed("*** THE NEW-PROCESS RESULT FAILED: \(verdict) ***")
        }
        XCTAssertEqual(verdict, ChildProtocol.pass, "and the verdict must be PASS, verbatim")
    }

    // ============================================================================================
    // MARK: - the child process plumbing
    // ============================================================================================

    private enum ChildError: Error, CustomStringConvertible {
        case unavailable(String)
        case malformed(String)
        case assertion(String)

        var description: String {
            switch self {
            case .unavailable(let d): return "the child harness is unavailable: \(d)"
            case .malformed(let d): return d
            case .assertion(let d): return d
            }
        }
    }

    /// A launched child, its bounded stdout pipe drained on a background thread, and its exit watched.
    private final class LaunchedChild {
        let process: Process
        private let handle: FileHandle
        private let lock = NSLock()
        private var lines: [String] = []
        private var eof = false

        init(process: Process, handle: FileHandle) {
            self.process = process
            self.handle = handle
        }

        func startDraining() {
            let queue = DispatchQueue(label: "gs.int.proc.child.stdout")
            queue.async { [self] in
                var buffer = Data()
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    buffer.append(chunk)
                    while let nl = buffer.firstIndex(of: 0x0A) {
                        let lineData = buffer[buffer.startIndex..<nl]
                        buffer.removeSubrange(buffer.startIndex...nl)
                        let line = String(data: Data(lineData), encoding: .utf8) ?? ""
                        lock.lock(); lines.append(line); lock.unlock()
                    }
                }
                lock.lock(); eof = true; lock.unlock()
            }
        }

        private func snapshot() -> (lines: [String], eof: Bool, exited: Bool) {
            lock.lock()
            let snapshot = (lines: lines, eof: eof, exited: !process.isRunning)
            lock.unlock()
            return snapshot
        }

        /// *** BOUNDED. *** *A child that never prints the marker is a FAILED scenario, so this returneth an error
        /// rather than waiting for ever -- and the whole transcript is carried in the reason.*
        func awaitLine(timeout: TimeInterval = 120, _ match: (String) -> Bool) throws {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                let snap = snapshot()
                if let found = snap.lines.first(where: match) { _ = found; return }
                if snap.eof || (snap.exited && !snap.eof) {
                    // The pipe may still be draining; give it a moment to deliver the tail.
                    if snap.eof { break }
                }
                if snap.exited && snap.eof { break }
                Thread.sleep(forTimeInterval: 0.02)
            }
            let snap = snapshot()
            throw ChildError.malformed(
                "*** A CHILD MARKER NEVER ARRIVED WITHIN \(Int(timeout))s. Missing marker, wrong termination, timeout "
                + "or early exit is a FAILED SCENARIO, never a skip. *** transcript=\(snap.lines) "
                + "eof=\(snap.eof) exited=\(snap.exited) status=\(process.isRunning ? "running" : "\(process.terminationStatus)")")
        }

        func terminateIfRunning() {
            if process.isRunning { process.terminate() }
        }
    }

    private func launchChild(scenario: Scenario, phase: String,
                             xctest: String, bundle: String, estate: URL) throws -> LaunchedChild {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: xctest)
        process.arguments = ["-XCTest", ChildProtocol.selector, bundle]
        var env = ProcessInfo.processInfo.environment
        env[ChildProtocol.roleKey] = ChildProtocol.roleValue
        env[ChildProtocol.boundaryKey] = scenario.boundary
        env[ChildProtocol.phaseKey] = phase
        env[ChildProtocol.estateKey] = estate.path
        if let detail = scenario.detail { env[ChildProtocol.detailKey] = detail } else { env.removeValue(forKey: ChildProtocol.detailKey) }
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let child = LaunchedChild(process: process, handle: pipe.fileHandleForReading)
        child.startDraining()
        return child
    }

    /// `xcrun --find xctest` when available; else the Xcode-relative path. *Never a guess about a secret.*
    private func resolveXCTestExecutable() throws -> String {
        if let override = ProcessInfo.processInfo.environment[ChildProtocol.xctestKey],
           FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        if let xcrun = try? runAndCapture("/usr/bin/xcrun", ["--find", "xctest"]) {
            let path = xcrun.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        let candidates = [
            "/Applications/Xcode.app/Contents/Developer/usr/bin/xctest",
            "/usr/bin/xctest",
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        throw ChildError.unavailable(
            "no `xctest` executable was found; set \(ChildProtocol.xctestKey) to the Xcode `xctest` binary")
    }

    private func runAndCapture(_ launchPath: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// *** THE ALREADY-BUILT BUNDLE, RESOLVED FROM THE LOADED TEST BUNDLE RATHER THAN HARD-CODED. *** *Under
    /// `swift test` the case is executed through a synthesized runner, so `Bundle(for:)` is consulted FIRST and the
    /// loaded-bundle roster is the fallback -- a path literal would break the moment the build directory moved.*
    static func resolveBundlePath(
        from direct: String,
        env: [String: String] = [:],
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) throws -> String {
        if direct.hasSuffix(".xctest"), fileExists(direct) {
            return direct
        }
        var tried: [String] = [direct]
        let parentDir = URL(fileURLWithPath: direct).deletingLastPathComponent().path
        let knownCandidates = [
            (parentDir as NSString).appendingPathComponent("GodstoneMeshTests.xctest"),
            (parentDir as NSString).appendingPathComponent("GodstoneFoundationPackageTests.xctest"),
        ]
        for candidate in knownCandidates {
            tried.append(candidate)
            if fileExists(candidate) { return candidate }
        }
        if let envBundle = env["XCTestBundlePath"] {
            tried.append(envBundle)
            if fileExists(envBundle) { return envBundle }
        }
        throw ChildError.unavailable(
            "the built test bundle could not be located; tried candidates: \(tried)")
    }

    private func resolveTestBundlePath() throws -> String {
        try Self.resolveBundlePath(
            from: Bundle(for: GsIntegration001ProcessTests.self).bundlePath,
            env: ProcessInfo.processInfo.environment
        )
    }

    func testGSINT001ProcessBundleResolution() throws {
        // 1. Direct resolution against live runtime bundle
        let bundle = try resolveTestBundlePath()
        XCTAssertTrue(bundle.hasSuffix(".xctest"), "resolved bundle must be an xctest: \(bundle)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle), "resolved bundle must exist: \(bundle)")

        // 2. Direct per-target bundle candidate
        let directTarget = "/build/debug/GodstoneMeshTests.xctest"
        let resolvedTarget = try Self.resolveBundlePath(from: directTarget, fileExists: { $0 == directTarget })
        XCTAssertEqual(resolvedTarget, directTarget)

        // 3. Merged package bundle candidate (Xcode 16 shape)
        let directPkg = "/build/debug/GodstoneFoundationPackageTests.xctest"
        let resolvedPkg = try Self.resolveBundlePath(from: directPkg, fileExists: { $0 == directPkg })
        XCTAssertEqual(resolvedPkg, directPkg)

        // 4. Fallback from a synthetic non-existing direct path to package bundle
        let directMissing = "/build/debug/Runner.app"
        let resolvedFallback = try Self.resolveBundlePath(
            from: directMissing,
            fileExists: { $0 == "/build/debug/GodstoneFoundationPackageTests.xctest" }
        )
        XCTAssertEqual(resolvedFallback, "/build/debug/GodstoneFoundationPackageTests.xctest")

        // 5. Environment variable fallback
        let envResolved = try Self.resolveBundlePath(
            from: directMissing,
            env: ["XCTestBundlePath": "/custom/path/MyTests.xctest"],
            fileExists: { $0 == "/custom/path/MyTests.xctest" }
        )
        XCTAssertEqual(envResolved, "/custom/path/MyTests.xctest")

        // 6. Refusal when none exist
        XCTAssertThrowsError(try Self.resolveBundlePath(from: directMissing, fileExists: { _ in false })) { error in
            guard case ChildError.unavailable(let msg) = error else {
                XCTFail("expected ChildError.unavailable, got \(error)")
                return
            }
            XCTAssertTrue(msg.contains("tried candidates:"), "message must list tried candidates: \(msg)")
        }
    }

    // ============================================================================================
    // MARK: - the child role
    // ============================================================================================

    private func runChildRole(env: [String: String]) throws {
        guard let boundary = env[ChildProtocol.boundaryKey],
              let phase = env[ChildProtocol.phaseKey],
              let estatePath = env[ChildProtocol.estateKey] else {
            throw ChildError.malformed(
                "*** A CHILD LAUNCH MUST CARRY boundary, phase and estate. Refusing rather than falling through "
                + "into the campaign, which would spawn children without bound. ***")
        }
        let scenario = Scenario(boundary: boundary, detail: env[ChildProtocol.detailKey])
        let estate = URL(fileURLWithPath: estatePath)
        switch phase {
        case ChildProtocol.prepare:
            try childPrepare(scenario: scenario, estate: estate)
        case ChildProtocol.recover:
            try childRecover(scenario: scenario, estate: estate)
        default:
            throw ChildError.malformed("unknown child phase \(phase)")
        }
    }

    /// Write one protocol line and FLUSH it. *The flush is load-bearing: the parent must see the marker BEFORE the
    /// kill, and a buffered line would be lost with the process.*
    private func emitProtocol(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
        fflush(stdout)
    }

    /// *** THE BOUNDARY HOLD: flush the marker, then WAIT TO BE KILLED. *** *Never a sleep that returns -- the
    /// parent's SIGKILL is the only thing that ends this.*
    private final class BoundaryHold: MeshCheckpointObserver, @unchecked Sendable {
        private let lock = NSLock()
        private var firedFlag = false
        private let name: String
        private let detail: String?
        private let announce: (String) -> Void

        init(name: String, detail: String?, announce: @escaping (String) -> Void) {
            self.name = name
            self.detail = detail
            self.announce = announce
        }

        var fired: Bool {
            lock.lock(); defer { lock.unlock() }
            return firedFlag
        }

        func checkpoint(_ event: MeshCheckpointEvent) {
            lock.lock()
            if firedFlag { lock.unlock(); return }
            guard event.name == name else { lock.unlock(); return }
            if let detail, event.detail != detail { lock.unlock(); return }
            firedFlag = true
            lock.unlock()
            announce("\(ChildProtocol.atBoundary) \(name)")
            // *** THE HOLD. *** *A bounded `Thread.sleep` loop rather than one infinite sleep, so the process
            // remains inspectable in a debugger attach; it never returns on its own.*
            while true { Thread.sleep(forTimeInterval: 30) }
        }
    }

    // ---------------------------------------------------------------- the durable estate helpers

    /// The label set every scenario's estate carrieth.
    private static let alice = "alice"
    private static let bob = "bob"
    private static let aliceSeed: UInt8 = 0x11
    private static let bobSeed: UInt8 = 0x31

    private func nodes(_ rig: RealTransportHostRig) throws {
        try rig.makeNode(label: Self.alice, seedByte: Self.aliceSeed, staticPrivByte: 0x12)
        try rig.makeNode(label: Self.bob, seedByte: Self.bobSeed, staticPrivByte: 0x32)
    }

    private func aliceId(_ rig: RealTransportHostRig) throws -> Data {
        try XCTUnwrap(rig.node(Self.alice)?.identity.nodeId, "alice's identity")
    }

    private func bobId(_ rig: RealTransportHostRig) throws -> Data {
        try XCTUnwrap(rig.node(Self.bob)?.identity.nodeId, "bob's identity")
    }

    /// *The rig's async authoring road needs an event loop; the scenario suite's `awaitRig` idiom is reused so the
    /// body runs on a detached task and reports its own answer.*
    private func awaitRig<T>(_ body: @escaping () async throws -> T) throws -> T {
        let sem = DispatchSemaphore(value: 0)
        var result: Result<T, Error>?
        Task.detached {
            do { result = .success(try await body()) } catch { result = .failure(error) }
            sem.signal()
        }
        guard sem.wait(timeout: .now() + 30) == .success else {
            throw ChildError.assertion("the async rig body never finished")
        }
        switch result {
        case .success(let v): return v
        case .failure(let e): throw e
        case nil: throw ChildError.assertion("the async rig body produced nothing")
        }
    }

    // ============================================================================================
    // MARK: - PHASE 1: prepare (reach the boundary, flush, wait)
    // ============================================================================================

    private func childPrepare(scenario: Scenario, estate: URL) throws {
        let rig = RealTransportHostRig(fixtureRoot: estate)
        try nodes(rig)

        // *** THE OBSERVER IS INSTALLED *BEFORE* THE OPERATION AND IS REMOVED BY NOBODY: this process is about to
        // be killed. It is installed HERE and NOWHERE ELSE, so no shipped graph and no existing arm ever sees one.*
        let hold = BoundaryHold(name: scenario.boundary, detail: scenario.detail, announce: emitProtocol)
        MeshCheckpoint.install(hold)

        // *** `READY` IS ANNOUNCED *BEFORE* THE OPERATION, AND THE ORDER IS LOAD-BEARING. *** *The boundary hold
        // BLOCKS INSIDE the production call, so a `READY` printed afterwards could never be printed at all -- the
        // parent would time out waiting for a line the child was never going to reach. `READY` therefore means "the
        // estate is built and the radio path is being driven", and `AT_BOUNDARY` means "the durable boundary was
        // genuinely reached".* **Their separation is what makes "missing marker" a distinguishable failure.**
        emitProtocol(ChildProtocol.ready)

        switch scenario.boundary {
        case MeshCheckpointNames.outboundEnqueue:
            // *** THE AUTHOR IS THE ELECTION'S OPENER. *** *MEASURED, AND IT IS WHY THIS ROAD EXISTS: `dispatchDirect`
            // offereth to the ROUTE-ELIGIBLE view, and production populate th that view ONLY for the party that
            // published APPLICATION LinkReady -- which is the INITIATOR. **An author who is the responder can never
            // offer to anybody, so a resumption arm written with a fixed label would measure the election rather than
            // the resumption.*** *The same `opens` election the rig's own authoring roads use is asked, so the author
            // is whoever production would make it.*
            let author = try XCTUnwrap(rig.opener(of: Self.alice, Self.bob), "the election's opener")
            let recipient = try XCTUnwrap(rig.peer(of: Self.alice, Self.bob), "its peer")
            let frame = try awaitRig { try await rig.authorDirectFrame(
                from: author, to: recipient, plaintext: Data("prepare-outbound".utf8)) }
            _ = rig.node(author)!.node.dispatchDirect(
                frame, expectedRecipient: try XCTUnwrap(rig.node(recipient)?.identity.nodeId, "the recipient"),
                send: { _, _ in false })

        case MeshCheckpointNames.inboundCommit, MeshCheckpointNames.ackCreate, MeshCheckpointNames.ackCommit:
            let frame = try awaitRig { try await rig.authorDirectFrame(
                from: Self.alice, to: Self.bob, plaintext: Data("prepare-inbound".utf8)) }
            _ = rig.node(Self.bob)!.node.ingestInbound(frame, receivedFrom: try aliceId(rig))

        case MeshCheckpointNames.senderAckRetire:
            let frame = try awaitRig { try await rig.authorDirectFrame(
                from: Self.alice, to: Self.bob, plaintext: Data("prepare-retire".utf8)) }
            // The sender's own durable commit, so a delivery row stands to be retired.
            _ = rig.node(Self.alice)!.node.dispatchDirect(
                frame, expectedRecipient: try bobId(rig), send: { _, _ in false })
            // AND THE RECIPIENT'S OWN CANONICAL ACK, from production's own outbox -- never minted here.
            guard case .new(let ack)? = rig.offerToInbox(Self.bob, frame: frame, from: try aliceId(rig)) else {
                throw ChildError.assertion("the recipient must have committed the frame and issued its ACK")
            }
            // *** THE SENDER'S AUTHENTICATOR MUST BE ABLE TO RESOLVE THE ACK'S AUTHOR, AND THAT REQUIRES THE PEER'S
            // BINDING TO BE PINNED IN THE SENDER'S OWN REPOSITORY. ***
            //
            // *MEASURED, AND IT IS WHY THIS ROAD EXISTS: `buildNode` pins each node's OWN binding (the ACK road
            // verifyeth its own fresh signature), and the rig's `pin` is only otherwise exercised by `link(...)` --
            // which this linkless scenario never runs. So `Ed25519AckAuthenticator` could not resolve bob's signing
            // key and `DeliveryTracker.acknowledge` answered `.rejectedAuthentication` WITHOUT EVER REACHING THE
            // RETIREMENT, so the boundary fired nowhere and the prepare child exited with "returned without reaching".*
            // **THE PIN TRAVELS THE PRODUCTION VALIDATOR ROAD (`IdentityBindingValidator` + `applyValidatedBinding`),
            // the same three calls `LabRuntime` makes -- so no bypass is introduced.**
            try rig.pin(try XCTUnwrap(rig.node(Self.bob)?.identity, "bob's identity"), into: try XCTUnwrap(rig.node(Self.alice)))
            // AND THE ACK IS INGESTED: the sender's tracker authenticates it against the pinned recipient and the
            // guarded CAS commits DELIVERED beside the exact held-row deletion -- which is the boundary under test.
            _ = rig.node(Self.alice)!.node.ingestInbound(ack, receivedFrom: try bobId(rig))

        case MeshCheckpointNames.preSend:
            // *** THE HOLD IS ARMED *AFTER* THE LINK, AND THAT ORDERING IS A MEASURED REQUIREMENT RATHER THAN A
            // CONVENIENCE. *** *The handshake itself stages records through the bound writer, so an observer armed
            // before `link(...)` would hold at the HS1 write -- a `preSend` with NO DURABLE WORK BEHIND IT, which is
            // not the boundary the plan names ("after durable acceptance").* **So the link is established first and
            // the hold is re-armed for the DATA dispatch alone.**
            MeshCheckpoint.install(nil)
            let link = try rig.link(Self.alice, Self.bob)
            guard rig.waitUntil(400, { rig.isLinkReady(link) }) else {
                throw ChildError.assertion("the link never became ready: " + rig.linkReadinessDetail(link))
            }
            MeshCheckpoint.install(hold)
            let sender = try XCTUnwrap(rig.opener(of: Self.alice, Self.bob), "the opener")
            let receiver = try XCTUnwrap(rig.peer(of: Self.alice, Self.bob), "its peer")
            _ = try awaitRig { try await rig.sendDirect(
                from: sender, to: receiver, plaintext: Data("prepare-presend".utf8)) }

        case MeshCheckpointNames.handshake:
            // *** THE LINK'S CROSSINGS ARE ASYNCHRONOUS, SO THE CHILD STAYS ALIVE AFTER `link(...)` RETURNS: the
            // hold fires from the transport's own delivery thread and never comes back. ***
            _ = try rig.link(Self.alice, Self.bob)

        default:
            throw ChildError.malformed("no prepare road for boundary \(scenario.boundary)")
        }

        // *** A CHILD THAT RETURNED HERE FROM A *SYNCHRONOUS* OPERATION DID NOT REACH ITS BOUNDARY AT ALL. *** *The
        // four store/sender boundaries emit inline, so their absence is a real defect and is reported with the
        // boundary's own name rather than waiting for the parent to time out.*
        //
        // **THE TWO ASYNCHRONOUS BOUNDARIES (`preSend`, `handshake`) ARE DIFFERENT: their crossings run on the
        // transport's own delivery queue, so the main thread legitimately returns first.** *There the child WAITS for
        // the hold to fire -- and the hold itself never returns, so this loop is what keeps the process alive until
        // the parent's SIGKILL. A boundary that never fires within the bound is a FAILED SCENARIO, named here.*
        switch scenario.boundary {
        case MeshCheckpointNames.preSend, MeshCheckpointNames.handshake:
            let deadline = Date().addingTimeInterval(120)
            while Date() < deadline {
                if hold.fired { break }
                Thread.sleep(forTimeInterval: 0.02)
            }
            if !hold.fired {
                throw ChildError.assertion(
                    "*** THE ASYNCHRONOUS BOUNDARY \(scenario.name) NEVER FIRED WITHIN THE BOUND. ***")
            }
            // The hold's own thread is blocked in `checkpoint`; the main thread joins it here for ever.
            while true { Thread.sleep(forTimeInterval: 30) }
        default:
            throw ChildError.assertion(
                "*** THE CHILD RETURNED FROM THE OPERATION WITHOUT REACHING \(scenario.name). A boundary that "
                    + "never fires is a FAILED SCENARIO. ***")
        }
    }

    // ============================================================================================
    // MARK: - PHASE 2: recover (a NEW PROCESS over the SAME estate)
    // ============================================================================================

    private func childRecover(scenario: Scenario, estate: URL) throws {
        do {
            try recoverBoundary(scenario: scenario, estate: estate)
            emitProtocol("\(ChildProtocol.complete) \(scenario.boundary) \(ChildProtocol.pass)")
        } catch {
            emitProtocol("\(ChildProtocol.complete) \(scenario.boundary) \(error)")
            exit(1)
        }
        exit(0)
    }

    private func recoverBoundary(scenario: Scenario, estate: URL) throws {
        let rig = RealTransportHostRig(fixtureRoot: estate)
        defer { rig.tearDown() }
        try nodes(rig)

        switch scenario.boundary {
        case MeshCheckpointNames.outboundEnqueue:
            // REQUIRED: "Same accepted msgId and queued delivery row survive; no DELIVERED; resumption transmits
            // it without a second authoring intent."
            let author = try XCTUnwrap(rig.opener(of: Self.alice, Self.bob), "the election's opener")
            let recipient = try XCTUnwrap(rig.peer(of: Self.alice, Self.bob), "its peer")
            let recipientId = try XCTUnwrap(rig.node(recipient)?.identity.nodeId, "the recipient's identity")
            let msgId = try onlyHeldMsgId(rig, label: author)
            let row = try XCTUnwrap(rig.deliveryRow(author, msgId: msgId), "the queued delivery row")
            try requireNotDelivered(row, "the pre-radio commit must not claim delivery")
            try require(row.state == .queuedDurably, "the row must still stand QUEUED_DURABLY, got \(row.state)")
            // AND THE RESUMED PROCESS OFFERS THE SAME CANONICAL FRAME, WITH NO SECOND AUTHORING INTENT.
            //
            // *** THE RELATION IS ESTABLISHED FIRST, AND THAT IS A MEASURED REQUIREMENT RATHER THAN SCENERY. ***
            // *`dispatchDirect` offereth to `currentPeers()` -- the ROUTE-ELIGIBLE view -- so on a freshly reopened
            // estate, where NO link hath been negotiated yet, the offer count is legitimately ZERO and an arm
            // demanding one would be demanding a peer that was never connected.* **MEASURED: that is exactly how the
            // first version of this recovery failed ("exactly one offer, got 0").** *So the fresh callbacks negotiate
            // their own relation, and the offer is then measured against a peer that really stands.*
            let link = try rig.link(Self.alice, Self.bob)
            try require(rig.waitUntil(400, { rig.isLinkReady(link) }),
                        "the fresh callbacks must negotiate their own relation: " + rig.linkReadinessDetail(link))
            let held = try XCTUnwrap(rig.messageStore(author).allHeldOrderedByPriority().first,
                                     "the durable frame")
            var offered = 0
            var offeredFrame: FrameV2?
            let outcome = rig.node(author)!.node.dispatchDirect(
                held, expectedRecipient: recipientId,
                send: { frame, _ in offered += 1; offeredFrame = frame; return false })
            try require(outcome == .queuedLocally,
                        "the resumption must re-offer the durable frame, got \(outcome)")
            try require(offered == 1, "exactly one offer, got \(offered)")
            try require(offeredFrame?.msgId == msgId,
                        "the offered frame must be the SAME canonical msgId, not a re-authored one")
            try require(rig.messageStore(author).allHeldMsgIds().count == 1,
                        "the resumption must not author a second row")

        case MeshCheckpointNames.inboundCommit:
            // REQUIRED: "One inbox row and pending obligation survive; recovery produces one canonical ACK; replay
            // adds no second inbox entry."
            let msgId = try onlyHeldMsgId(rig, label: Self.bob)
            let obligation = try obligationState(rig, msgId: msgId, holder: Self.bob)
            try require(obligation.found, "the pending ACK obligation must survive the kill")
            try require(obligation.state == "PENDING",
                        "the obligation must stand PENDING (retryable), got \(obligation.state)")
            try require(obligation.frames == 0, "no ACK row may have been filed before the crash")
            // AND RECOVERY PRODUCES THE ONE CANONICAL ACK, VERIFIED BY PRODUCTION'S OWN AUTHENTICATOR.
            let frame = try XCTUnwrap(rig.messageStore(Self.bob).allHeldOrderedByPriority().first, "the held frame")
            let ack = try canonicalAck(rig, frame: frame)
            try require(ack.msgId == msgId, "the regenerated ACK must name the surviving receipt")
            try require(try obligationState(rig, msgId: msgId, holder: Self.bob).frames == 1,
                        "exactly one ACK row after recovery")
            // AND A REPLAY OF THE SAME FRAME ADDS NO SECOND INBOX ENTRY.
            _ = rig.offerToInbox(Self.bob, frame: frame, from: try aliceId(rig))
            try require(rig.messageStore(Self.bob).allHeldMsgIds().count == 1,
                        "*** A REPLAY MUST NOT ADD A SECOND INBOX ENTRY. ***")

        case MeshCheckpointNames.ackCreate:
            // REQUIRED: "Pending obligation survives; restart regenerates/verifies the canonical ACK; no ACK or
            // delivery is falsely claimed from lost memory."
            let msgId = try onlyHeldMsgId(rig, label: Self.bob)
            let before = try obligationState(rig, msgId: msgId, holder: Self.bob)
            try require(before.found && before.state == "PENDING", "the obligation must survive PENDING")
            try require(before.frames == 0, "*** NO ACK MAY BE CLAIMED FROM MEMORY THE DYING PROCESS LOST. ***")
            let frame = try XCTUnwrap(rig.messageStore(Self.bob).allHeldOrderedByPriority().first, "the held frame")
            let ack = try canonicalAck(rig, frame: frame)
            try require(ack.msgId == msgId, "the regenerated ACK must name the surviving receipt")
            try require(try obligationState(rig, msgId: msgId, holder: Self.bob).frames == 1,
                        "one ACK row after regeneration")

        case MeshCheckpointNames.ackCommit:
            // REQUIRED: "Stored ACK survives and obligation is retired; recovery sends that ACK without duplicate
            // inbox admission."
            let msgId = try onlyHeldMsgId(rig, label: Self.bob)
            let after = try obligationState(rig, msgId: msgId, holder: Self.bob)
            try require(after.frames == 1,
                        "*** THE PAIR STEP COMMITTED BEFORE THE KILL, so the stored ACK must survive. Observed "
                            + "frames=\(after.frames). ***")
            try require(!after.found, "and the obligation must have retired WITH it, got \(after.state)")
            // AND THE SURVIVING BYTES ARE SENDABLE WITHOUT A SECOND ADMISSION.
            let stored = try storedAck(rig, msgId: msgId, holder: Self.bob)
            try require(rig.node(Self.bob)!.node.offerAckForLink(stored),
                        "the stored ACK must be offerable for the link")
            let drained = try XCTUnwrap(rig.drainOneAck(Self.bob), "the stored ACK must be drainable")
            try require(drained.msgId == msgId, "and it must name the surviving receipt")
            let frame = try XCTUnwrap(rig.messageStore(Self.bob).allHeldOrderedByPriority().first, "the held frame")
            _ = rig.offerToInbox(Self.bob, frame: frame, from: try aliceId(rig))
            try require(rig.messageStore(Self.bob).allHeldMsgIds().count == 1,
                        "*** RECOVERY MUST NOT ADMIT A SECOND INBOX ENTRY FOR THE SAME FRAME. ***")

        case MeshCheckpointNames.senderAckRetire:
            // REQUIRED: "DELIVERED and held-row retirement agree after restart; replay ACK is idempotent."
            let msgId = try senderRowMsgId(rig, label: Self.alice)
            let row = try XCTUnwrap(rig.deliveryRow(Self.alice, msgId: msgId), "the sender's delivery row")
            try require(row.state == .acknowledgedByRecipient,
                        "*** THE SENDER'S ROW MUST READ DELIVERED -- the CAS committed before the kill. Observed "
                            + "\(row.state). ***")
            try require(!rig.messageStore(Self.alice).allHeldMsgIds().contains(msgId),
                        "*** AND THE HELD FRAME MUST BE RETIRED WITH IT: DELIVERED and retirement must AGREE. ***")
            // AND THE REPLAY IS IDEMPOTENT: the surviving ACK re-dispatched must not resurrect the row.
            let ack = try storedAck(rig, msgId: msgId, holder: Self.bob)
            _ = rig.node(Self.alice)!.node.ingestInbound(ack, receivedFrom: try bobId(rig))
            let afterReplay = try XCTUnwrap(rig.deliveryRow(Self.alice, msgId: msgId), "the row after replay")
            try require(afterReplay.state == .acknowledgedByRecipient,
                        "the replayed ACK must be idempotent, got \(afterReplay.state)")
            try require(!rig.messageStore(Self.alice).allHeldMsgIds().contains(msgId),
                        "and the replay must not resurrect the retired held row")

        case MeshCheckpointNames.preSend:
            // REQUIRED: "Accepted work remains queued; a new epoch resumes it; an old connection/record cannot claim
            // delivery."
            //
            // *** THE SENDER IS THE ELECTION'S OPENER, NOT A LABEL THE COURT ASSUMED. *** *MEASURED: the first
            // version hard-coded `alice`, and the delivery row stood on whichever side the production hint election
            // made the initiator -- so the arm reported "no delivery row stands on alice" for a row that was
            // perfectly present on its true owner.* **The election is asked, exactly as the rig's own authoring roads
            // do.**
            let opener = try XCTUnwrap(rig.opener(of: Self.alice, Self.bob), "the production election's opener")
            let msgId = try senderRowMsgId(rig, label: opener)
            let row = try XCTUnwrap(rig.deliveryRow(opener, msgId: msgId), "the accepted delivery row")
            try requireNotDelivered(row, "*** the bytes never left: NOTHING may claim delivery. ***")
            try require(rig.messageStore(opener).allHeldMsgIds().contains(msgId),
                        "the accepted work must remain durably held")
            // *** AND THE OLD CONNECTION CANNOT CLAIM IT. *** *The predecessor process's transport epoch, relation
            // and session registry died with it; the fresh transport has no ready relation and no handle at all.*
            try require(rig.node(opener)!.ble.linkReadyPeersForTest().isEmpty,
                        "*** NO READY RELATION MAY BE INHERITED FROM THE ESTATE. ***")
            try require(rig.node(opener)!.node.knownPeersForTest().isEmpty,
                        "*** AND NO ROUTE-ELIGIBLE PEER EITHER. ***")
            // A NEW EPOCH RESUMES IT: the same durable frame is re-offered over a freshly negotiated link.
            let link = try rig.link(Self.alice, Self.bob)
            try require(rig.waitUntil(400, { rig.isLinkReady(link) }),
                        "the fresh callbacks must negotiate again: " + rig.linkReadinessDetail(link))
            try require(rig.deliveryRow(opener, msgId: msgId)?.state != .acknowledgedByRecipient,
                        "the resumed hand-off still may not claim delivery")

        case MeshCheckpointNames.handshake:
            // REQUIRED: "No session/ready state inherited; fresh callbacks negotiate again, and captured
            // old-session records are refused."
            try require(rig.node(Self.alice)!.ble.linkReadyPeersForTest().isEmpty,
                        "*** NO READY ROSTER MAY BE INHERITED ACROSS THE KILL. ***")
            try require(rig.node(Self.alice)!.node.knownPeersForTest().isEmpty,
                        "*** AND NO ROUTE-ELIGIBLE PEER. ***")
            try require(rig.node(Self.bob)!.ble.linkReadyPeersForTest().isEmpty,
                        "*** ON EITHER SIDE. ***")

            // ---- (1) NEGOTIATE A LIVE SESSION AND CAPTURE WHAT IT REALLY WROTE --------------------------
            let liveLink = try rig.link(Self.alice, Self.bob)
            try require(rig.waitUntil(400, { rig.isLinkReady(liveLink) }),
                        "*** THE FRESH CALLBACKS MUST NEGOTIATE AGAIN: an inherited session would block this. *** "
                            + rig.linkReadinessDetail(liveLink))
            let opener = try XCTUnwrap(rig.opener(of: Self.alice, Self.bob), "the opener")
            let peer = try XCTUnwrap(rig.peer(of: Self.alice, Self.bob), "its peer")
            let liveHandle = liveLink.aOpened ? liveLink.aHandle : liveLink.bHandle
            let initiatorSent = try XCTUnwrap(rig.opens(opener, peer), "the production hint election")
            let mark = rig.fabric.mark()
            _ = try awaitRig { try await rig.sendDirect(from: opener, to: peer,
                                                        plaintext: Data("live-session".utf8)) }
            // *** THE RECEIVER'S INGEST IS ASYNCHRONOUS ON THE RIG'S OWN DELIVERY QUEUE, SO THE DURABLE EFFECT MUST
            // BE WAITED FOR BEFORE ANY PRE-SNAPSHOT IS TAKEN. ***
            //
            // *MEASURED, AND IT IS HOW THE FIRST VERSION OF THIS CONTROL FAILED: `sendDirect` returneth once the
            // OPENER's writes are recorded, but delivering them into the receiver runneth on `deliveryQueue`. So the
            // receiver's held-row count was still zero when the pre-snapshot was read, and the re-entered record then
            // legitimately committed the FIRST row -- which the arm misread as "the retired record committed".*
            // **The wait is on the receiver's own durable row, which is the effect the control is about.**
            try require(rig.waitUntil(400, {
                rig.messageStore(peer).allHeldMsgIds().count == 1
            }), "*** THE LIVE DELIVERY MUST REACH THE RECEIVER'S DURABLE ROAD BEFORE ANY SNAPSHOT. *** "
                + "ring=" + rig.ring(peer))
            // AND THE CAPTURED RECORD IS THE OPENER'S OWN INBOX WRITE -- a DATA record, never a handshake counsel:
            // *re-entering a counsel would measure the handshake state machine rather than the DATA ingress the row
            // names.*
            let liveWrites = rig.fabric.writes(since: mark)
                .filter { $0.characteristic == "inbox" && $0.from == opener }
            let captured = try XCTUnwrap(liveWrites.first,
                                         "*** THE LIVE SESSION MUST HAVE WRITTEN AN INBOX RECORD TO CAPTURE. ***")

            // *** THE HONEST CONTROL, ON THESE VERY BYTES: the same re-entry into the LIVE epoch must not revive
            // readiness, seat a new connection or commit a new row -- so the refusal below cannot mean "the door
            // refuses everything". ***
            let liveVerdict = rig.replayCapturedWrite(captured, into: peer,
                                                      underHandle: liveHandle, initiatorSent: initiatorSent)
            try require(liveVerdict.hasPrefix("refused"),
                        "*** THE CONTROL: a re-entered record on the LIVE epoch must be harmless. Observed: "
                            + "\(liveVerdict) ***")

            // ---- (2) RETIRE THE EPOCH, RE-NEGOTIATE, AND REPLAY THE CAPTURED OLD-SESSION RECORD ---------
            try require(rig.restartTransport(label: peer),
                        "the receiver's transport must restart through its own node")
            try require(rig.node(peer)!.ble.linkReadyPeersForTest().isEmpty,
                        "*** AND THE RESTARTED TRANSPORT MUST HOLD NO READY RELATION. ***")
            let replacement = try rig.link(Self.alice, Self.bob)
            try require(rig.waitUntil(400, { rig.isLinkReady(replacement) }),
                        "the replacement epoch must negotiate its own relation: "
                            + rig.linkReadinessDetail(replacement))
            // *** THE HANDLE COMES FROM THE REPLACEMENT `Link` VALUE ITSELF, NOT FROM A LOOKUP. ***
            // *MEASURED: `linkHandle(opener, peer)` returneth the FIRST matching link -- which is still the LIVE one,
            // so a comparison against it reported "the same handle" for a genuinely fresh relation and the arm failed
            // on its own instrument rather than on production.* **`link(...)` hands back the relation it just made,
            // so its own handle is the only honest reading.**
            let replacementHandle = replacement.aOpened ? replacement.aHandle : replacement.bHandle
            try require(replacementHandle != liveHandle,
                        "*** THE REPLACEMENT RELATION MUST BEAR A DIFFERENT HANDLE, or the replay below could "
                            + "address the LIVE connection and prove nothing. ***")
            let staleVerdict = rig.replayCapturedWrite(captured, into: peer,
                                                       underHandle: liveHandle, initiatorSent: initiatorSent)
            try require(staleVerdict.hasPrefix("refused"),
                        "*** A RECORD CAPTURED FROM THE RETIRED SESSION MUST BE REFUSED UNDER ITS OWN RETIRED "
                            + "HANDLE -- no revived readiness, no seated connection and no newly committed row. "
                            + "Observed: \(staleVerdict) ***")

        default:
            throw ChildError.malformed("no recovery road for boundary \(scenario.boundary)")
        }
    }

    private func onlyHeldMsgId(_ rig: RealTransportHostRig, label: String) throws -> Data {
        let ids = rig.messageStore(label).allHeldMsgIds()
        try require(ids.count == 1, "expected exactly one held row on \(label), got \(ids.count)")
        return ids[0]
    }

    /// The sender's row, which may be DELIVERED even though its held frame was retired -- so the held rows cannot
    /// name it. *Read from the store's own delivery namespace through the rig's tracker.*
    private func senderRowMsgId(_ rig: RealTransportHostRig, label: String) throws -> Data {
        guard let id = rig.anyDeliveryMsgId(label) else {
            throw ChildError.assertion("no delivery row stands on \(label)")
        }
        return id
    }

    private struct ObligationView { let found: Bool; let state: String; let frames: Int }

    private func obligationState(_ rig: RealTransportHostRig, msgId: Data,
                                 holder: String) throws -> ObligationView {
        let runtime = try XCTUnwrap(rig.node(holder)?.runtime, "the holder's runtime")
        let recipient = try XCTUnwrap(rig.node(holder)?.identity.nodeId, "the holder's identity")
        switch runtime.ackStore.lookupObligation(msgId, recipientNodeId: recipient) {
        case .found(let ob):
            return ObligationView(found: true, state: String(describing: ob.state).uppercased(),
                                  frames: runtime.ackStore.countForPair(msgId, recipientNodeId: recipient))
        case .absent:
            return ObligationView(found: false, state: "ABSENT",
                                  frames: runtime.ackStore.countForPair(msgId, recipientNodeId: recipient))
        case .corrupt(let why):
            throw ChildError.assertion("the obligation row is corrupt: \(why)")
        case .storageFailure:
            throw ChildError.assertion("the obligation lookup refused with a storage failure")
        }
    }

    /// *** PRODUCTION'S OWN CANONICAL ACK FOR A SURVIVING RECEIPT, AND PRODUCTION'S OWN VERIFICATION OF IT. ***
    private func canonicalAck(_ rig: RealTransportHostRig, frame: FrameV2) throws -> FrameV2 {
        guard let inbox = rig.node(Self.bob)?.node.recipientInbox else {
            throw ChildError.assertion("no recipient inbox on the reopened node")
        }
        let result: InboxCommitResult
        do { result = try inbox.acceptVerifiedAndRequireAck(frame, receivedFrom: try aliceId(rig), fault: nil) }
        catch { throw ChildError.assertion("the inbox threw rather than answering: \(error)") }
        let ack: FrameV2
        switch result {
        case .new(let a): ack = a
        case .duplicate(let a): ack = a
        case .rejected(let reason, let detail):
            throw ChildError.assertion("the recovery accept was REFUSED: \(reason) \(detail ?? "")")
        }
        let runtime = try XCTUnwrap(rig.node(Self.bob)?.runtime, "bob's runtime")
        try require(runtime.ackAuthenticator.verify(originalMsgId: frame.msgId,
                                                   expectedRecipientNodeId: try bobId(rig),
                                                   ackFrame: ack),
                    "*** THE REGENERATED ACK MUST PASS PRODUCTION'S OWN PINNED-KEY VERIFIER. ***")
        return ack
    }

    /// The exact bytes of a stored ACK row, decoded from the durable record -- never re-signed.
    private func storedAck(_ rig: RealTransportHostRig, msgId: Data,
                           holder: String) throws -> FrameV2 {
        let runtime = try XCTUnwrap(rig.node(holder)?.runtime, "the runtime holding the ACK")
        let recipientId = try XCTUnwrap(rig.node(holder)?.identity.nodeId, "the holder's identity")
        guard case .records(let rows) = try runtime.ackStore.candidatesForPair(
            msgId, recipientNodeId: recipientId, bound: 4) else {
            throw ChildError.assertion("the ACK pair census refused")
        }
        guard let record = rows.first, let frame = FrameV2.decode(record.encodedFrame) else {
            throw ChildError.assertion("no decodable stored ACK row stands for the receipt")
        }
        return frame
    }

    private func requireNotDelivered(_ row: DeliveryRecord, _ why: String) throws {
        try require(row.state != .acknowledgedByRecipient,
                    "\(why) -- observed state \(row.state)")
    }

    private func require(_ condition: Bool, _ why: String) throws {
        guard condition else { throw ChildError.assertion(why) }
    }
}

#endif
