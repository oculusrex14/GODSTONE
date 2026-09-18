import XCTest
import Foundation
@testable import GodstoneMesh

/**
 * GS-FINAL-010 (the independent audit, 2026-09-18): **THE SHUTDOWN LATCH IS LIFETIME-WIDE, SO A SECOND ACTIVATION
 * CANNOT BE TORN DOWN.**
 *
 * THE AUDIT'S MEASUREMENT: *"MeshNode.stop sets adaptersClosed once. The inspected start/open paths never reset it,
 * while start sets isStarted before invoking the lifecycle owner and does not consume an activation outcome."* AND ITS
 * ROOT CAUSE: *"A lifetime-wide Boolean is used where restartable epoch state appears to be required."*
 *
 * WHAT THAT MEANS CONCRETELY, AND IT IS A RESOURCE LEAK RATHER THAN A NICETY:
 *
 *   `stop()` guardeth the radio close behind `if !adaptersClosed { adaptersClosed = true; ... }`, and NOTHING EVER
 *   SETS IT BACK. So the FIRST stop closes the radio; an activation afterwards opens it AGAIN through the owner; and
 *   the SECOND stop **CLOSES NOTHING** -- the latch is already set, the adverts and the scan keep running, and the
 *   process stands holding platform resources for a runtime it has torn down.
 *
 * THE AUDIT'S OWN INSTRUCTION ON HOW TO PROCEED, WHICH THESE ARMS FOLLOW EXACTLY:
 *
 *   *"First establish the lifecycle contract by inspecting UnifiedRuntimeLifecycle and all callers. ... Do not blindly
 *   reset a flag before proving teardown has drained."*
 *
 * SO THE CONTRACT IS ESTABLISHED FIRST, AND MEASURED RATHER THAN READ: `UnifiedRuntimeLifecycle.stop()` sets
 * `started = false` and releases the lease, and `start()` RE-CREATES the lease and a FRESH context. **THE OWNER IS
 * RESTARTABLE**, so a node whose owner may be started again must be able to close again -- which is precisely what a
 * lifetime-wide latch prevents.
 */
@MainActor
final class GsFinal010ShutdownLatchTests: XCTestCase {

    /// A lifecycle seam that RECORDS every OS call, so "was the radio really closed" is observable rather than
    /// inferred. `UnifiedRuntimeLifecycle` speaks to the platform only through this.
    private final class RecordingSeam: TransportSeam, @unchecked Sendable {
        private let lock = NSLock()
        private var events: [String] = []
        var log: [String] { lock.lock(); defer { lock.unlock() }; return events }
        private func note(_ e: String) { lock.lock(); events.append(e); lock.unlock() }
        func startScan() { note("startScan") }
        func stopScan() { note("stopScan") }
        func startAdvertising() { note("startAdvertising") }
        func stopAdvertising() { note("stopAdvertising") }
        func disconnectAll() -> Int { note("disconnectAll"); return 0 }
        func resetResources() { note("resetResources") }
    }

    private func makeNode() throws -> (MeshNode, RecordingSeam) {
        let keychain = LatchKeychain()
        let identity = try MeshIdentity.generateAndStore(keychain: keychain)
        let store = InMemoryMessageStore()
        let tracker = DeliveryTracker(
            repo: UnexercisedDeliveryRepository(),
            authenticator: Ed25519AckAuthenticator(resolver: UnresolvedRecipientKeyResolver())
        )
        let node = MeshNode(identity: identity, store: store, deliveryTracker: tracker)
        return (node, RecordingSeam())
    }

    /// *** THE ARM: ACTIVATE, STOP, ACTIVATE, STOP -- AND THE SECOND STOP MUST CLOSE AGAIN. ***
    ///
    /// THE AUDIT'S OWN PROPOSED SHAPE, by name: *"StartStopStartStopThroughComposition: observe actual transport
    /// start/stop calls, returned states, callback generations and resource census."* THIS ARM OBSERVES THE FIRST AND
    /// THE LAST OF THOSE: THE ACTUAL PLATFORM CALLS.
    func testGSFINAL010_aSecondActivationIsTornDownByASecondStop() throws {
        let (node, seam) = try makeNode()
        let lifecycle = UnifiedRuntimeLifecycle(seam: seam, nowMillis: { 0 },
                                               adapterPresent: true, permissionGranted: true)
        node.lifecycleOwner = lifecycle

        // (1) FIRST ACTIVATION -- through the node's own roads, so the owner is really invoked.
        node.startInOrder(attach: {}, open: { node.openAdapters() })
        XCTAssertEqual(node.adaptersOpenedThroughTheOwner, 1, "the first activation opens through the one owner")
        XCTAssertTrue(seam.log.contains("startAdvertising"), "and the platform really began advertising: \(seam.log)")

        // (2) FIRST STOP -- the radio closes, once.
        node.stop()
        XCTAssertEqual(node.adaptersClosedThroughTheOwner, 1, "the first stop closes through the one owner")
        XCTAssertTrue(seam.log.contains("stopAdvertising"), "and the platform really stopped: \(seam.log)")

        // (3) SECOND ACTIVATION -- THE OWNER IS RESTARTABLE, which the embedded contract proves below.
        node.startInOrder(attach: {}, open: { node.openAdapters() })
        XCTAssertEqual(node.adaptersOpenedThroughTheOwner, 2, "a second activation opens again through the owner")
        XCTAssertTrue(lifecycle.isStarted(), "and the owner really stands started again")

        // (4) *** SECOND STOP: THE DEFECT IS HERE. ***
        let closesBefore = node.adaptersClosedThroughTheOwner
        let advertsBefore = seam.log.filter { $0 == "startAdvertising" }.count
        node.stop()

        XCTAssertEqual(
            node.adaptersClosedThroughTheOwner, closesBefore + 1,
            "*** GS-FINAL-010: A SECOND ACTIVATION MUST BE TORN DOWN BY A SECOND STOP. The node's `adaptersClosed` "
            + "latch is set ONCE and NEVER RESET, so this stop closed NOTHING: the radio the second activation opened "
            + "is still running, and the process holds platform resources for a runtime it has torn down. "
            + "Observed closes: \(node.adaptersClosedThroughTheOwner) (was \(closesBefore)); "
            + "adverts started: \(advertsBefore). ***",
        )
        XCTAssertFalse(
            lifecycle.isStarted(),
            "and the owner itself must be stopped -- a node that called stop and left its owner running is the "
            + "resource leak the latch produceth",
        )
    }

    /**
     * *** THE CONTRACT, MEASURED: THE OWNER IS RESTARTABLE, SO A LIFETIME LATCH IS THE WRONG SHAPE. ***
     *
     * The audit bade me establish this BEFORE touching the flag: *"Do not blindly reset a flag before proving teardown
     * has drained."* This arm proves the premise the repair rests on -- `stop()` drains and releases, and `start()`
     * genuinely re-activates with a FRESH context and a NEW lease -- so re-arming the node's latch after a drained
     * teardown is sound rather than blind.
     */
    func testGSFINAL010_theOwnerContractIsRestartable() throws {
        let seam = RecordingSeam()
        let lifecycle = UnifiedRuntimeLifecycle(seam: seam, nowMillis: { 0 },
                                               adapterPresent: true, permissionGranted: true)

        lifecycle.start()
        XCTAssertTrue(lifecycle.isStarted())
        let firstLease = lifecycle.activeLease()
        let firstContexts = lifecycle.snapshotContexts()
        XCTAssertNotNil(firstLease, "a start carrieth a live lease")

        lifecycle.stop()
        XCTAssertFalse(lifecycle.isStarted(), "a stop ends the activation")
        XCTAssertTrue(firstLease?.isReleased == true, "AND IT RELEASETH THE LEASE -- so teardown really drained")
        XCTAssertEqual(lifecycle.liveContextCount(), 0, "and no context permits an effect afterwards")

        lifecycle.start()
        XCTAssertTrue(lifecycle.isStarted(), "*** THE OWNER IS RESTARTABLE: start() after a drained stop re-activates ***")
        XCTAssertNotEqual(
            lifecycle.activeLease()?.leaseId, firstLease?.leaseId,
            "with a FRESH lease rather than the released one -- which is what 'restartable' meaneth",
        )
        XCTAssertNotEqual(
            lifecycle.snapshotContexts().map(\.contextId), firstContexts.map(\.contextId),
            "and a FRESH context, so the elder's tokens cannot deliver an effect into the new activation",
        )
    }

    /**
     * *** AND A TERMINAL OWNER IS STILL TERMINAL: THE REPAIR MUST NOT RESURRECT ONE. ***
     *
     * The audit's warning cut both ways -- *"For terminal nodes make start-after-stop return a typed refusal"*. A power
     * loss is terminal by the owner's own contract (`onPowerLoss` sets `.terminalUnavailable` and NOTHING restarts it),
     * so the node's stop must NOT claim a close it did not perform, and a later activation must not open.
     */
    func testGSFINAL010_aTerminalOwnerIsNotResurrected() throws {
        let (node, seam) = try makeNode()
        let lifecycle = UnifiedRuntimeLifecycle(seam: seam, nowMillis: { 0 },
                                               adapterPresent: true, permissionGranted: true)
        node.lifecycleOwner = lifecycle

        node.startInOrder(attach: {}, open: { node.openAdapters() })
        lifecycle.onPowerLoss()                    // TERMINAL, by the owner's own contract
        XCTAssertFalse(lifecycle.isStarted(), "a power loss ends the activation")

        node.stop()
        // AND A LATER ACTIVATION MUST NOT OPEN THE RADIO: the owner is terminal, so `start()` returns early.
        node.startInOrder(attach: {}, open: { node.openAdapters() })
        XCTAssertFalse(
            lifecycle.isStarted(),
            "a terminal owner must NOT be resurrected by a later activation -- `start()` refuseth on its own contract",
        )
    }
}

// MARK: - this court's own doubles (the ones elsewhere are private to their files)

private final class LatchKeychain: LocalIdentityKeychain, @unchecked Sendable {
    var storage: [String: Data] = [:]
    func read(tag: String) throws -> Data? { storage[tag] }
    func add(tag: String, data: Data) throws { storage[tag] = data }
    func delete(tag: String) throws { storage.removeValue(forKey: tag) }
}

/// The audit's own note applies: these arms never exercise delivery, so the repository records that rather than
/// pretending to answer. `fatalError` is honest here -- an arm that reached it would be an arm that strayed into a
/// subject it does not own, and it would fail loudly rather than pass on a fabricated result.
private final class UnexercisedDeliveryRepository: DeliveryRepository {
    func get(_ msgId: Data) -> DeliveryLookup { fatalError("unused by these witnesses") }
    func enqueue(_ msgId: Data, ackMode: AckMode, expectedRecipient: Data?) -> EnqueueResult { fatalError("unused by these witnesses") }
    func transition(_ msgId: Data, _ transition: DeliveryTransition) -> TransitionResult { fatalError("unused by these witnesses") }
    func acknowledgeBoundAndRetire(_ msgId: Data, expectedRecipient: Data) -> AckResult { fatalError("unused by these witnesses") }
    func clear(_ msgId: Data) -> ClearResult { fatalError("unused by these witnesses") }
}
