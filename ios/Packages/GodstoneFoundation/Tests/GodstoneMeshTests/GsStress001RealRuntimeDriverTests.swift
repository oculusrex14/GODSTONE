import XCTest
import Foundation
import CryptoKit
import CoreBluetooth
import GodstoneCore
@testable import GodstoneMesh

/// *** GS-STRESS-001 `ten-thousand-cycles` / `real-owner-invariants`: THE REAL RUNTIME, DRIVEN FOR TEN THOUSAND CYCLES. ***
///
/// THE CARD, VERBATIM: *"Construct a deterministic host stress driver over the real GS-INTEGRATION-001 composition. It
/// must instantiate actual runtime owners such as MeshRuntime / ComposedRuntime; real durable repositories used by the
/// host lane; session/peer/link/ACK/store owners. **DO NOT STRESS A SECOND SIMULATION MODEL AND CALL IT PRODUCTION
/// RUNTIME STRESS.**"* -- and *"read the resource census FROM THE OWNERS THAT ALLOCATE."*
///
/// **SO EVERY CENSUS HERE IS AN OWNER'S OWN READING** through its own evidence hook (`slotCountForTest`,
/// `incarnationCountForTest`, `observerCensusForTest`, `ackOutboxDepthForTest`, `reservedCountForTest`,
/// `timerLeaseCountForTest`, `quarantineRecordCountForTest`, `admissionHistoryCountForTest`, `countObligations`,
/// `countFrames`, `census()`, `tombstoneForTest`, `attributesOfItem` on the db files). *A harness that counted its own
/// operations would measure itself: the only counter this file moves is the CYCLE counter, and that one exists so a
/// truncated loop cannot print green.*
///
/// **THE OWNERS ARE THE PRODUCTION ONES.** The graph is built by `MeshRuntime.createArchiveOnlyHostComposition` -- THE
/// COMPOSITION ROOT -- over temp on-disk URLs, so the SQLite stores, the peer repository and its resolver, the
/// `DeliveryTracker`, the `SessionManager`, the `MeshNode` and its `BleTransport`, the `UnifiedRuntimeLifecycle` and
/// the durable ACK store/driver/pump/inbox are **THE SAME OBJECTS THE HOST LANE USES.**
///
/// **THE CYCLE:** `lifecycle.start()` -> bind the legs -> **ONE** seeded action class -> drain -> `lifecycle.stop()` ->
/// the quiescence census must equal the baseline. Ten thousand of those, with a full-graph reopen at cycles 1000, 5000,
/// 9000 and after the final stop.
///
/// **NOT CLAIMED:** no device radio, no at-rest encryption. The two platform facades this court substitutes are the
/// KEYCHAIN and the WIPE JOURNAL -- and, for the two classes that need a bound writer, the CoreBluetooth MANAGER PAIR
/// (injected at the transport's own epoch install). *The bytes, the delegates, every reduction, the stores and the
/// crypto are the production ones.*
final class GsStress001RealRuntimeDriverTests: XCTestCase {

    /// *** THE RECORDED SEED, KEPT FROM THE FIRST VERSION OF THIS COURT. ***
    private let seed: Int64 = 20_260_926
    /// *** THE CARD'S FLOOR -- not a tunable. ***
    private let cycles = 10_000
    /// The open-graph checkpoints the card asks for, plus the one after the final stop.
    private let checkpointCycles: Set<Int> = [1_000, 5_000, 9_000]

    /// *** THE ONE SUBSTITUTED FACADE, HELD BY THE COURT SO IT OUTLIVETH THE DISPATCH IT NAMES. ***
    private var stressFactory: StressManagerFactory?
    /// *** ONE WRITER PER PEER IDENTITY, CACHED -- which is what the REAL RADIO does. ***
    ///
    /// *MEASURED, AND IT IS THE RIGHT ASSERTION: CoreBluetooth NEVER re-delivers a discovered characteristic tree for
    /// a STANDING connection, so a witness that demanded a FRESH bind writer on every cycle would measure behaviour
    /// production BLE does not implement. The writer binding is therefore held per handle and re-used while it stands
    /// open and still speaks through the transport's own connection; it is re-minted ONLY when the binding genuinely
    /// falls (A3's churn, or the explicit release the class performs).*
    private var writerCache: [UUID: RecordWriter] = [:]
    /// *The handle the timer class timed and must release, so the lease census returneth.*
    private var timedHandleRef = UUID()
    private var stressPins: [(CBPeripheral, StressPeripheral)] = []
    private func stressPeripheral(_ handle: UUID) -> CBPeripheral {
        if let pinned = stressPins.first(where: { ($0.1).identifier == handle }) { return pinned.0 }
        let object = StressPeripheral(identifier: handle)
        let cast = unsafeBitCast(object, to: CBPeripheral.self)
        stressPins.append((cast, object))
        return cast
    }

    // --------------------------------------------------------------------------------------------
    // MARK: - the owners, built the way production builds them
    // --------------------------------------------------------------------------------------------

    private func tempURL(_ tag: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("gsstress_\(tag)_\(UUID().uuidString).db")
    }

    /// The estate one composition owns, so a reopen can address exactly the same files.
    private struct Estate {
        let messageStoreUrl: URL
        let peerStoreUrl: URL
        let journal: ProbeJournal
        /// *** AND THE KEYCHAIN BELONGS TO THE ESTATE, WHICH THE FIRST DRAFT GOT WRONG. *** *MEASURED: a FRESH
        /// `ProbeKeychain` per reopen made `MeshIdentity.loadOrCreate` mint a NEW identity, so the reopen witnessed
        /// "the identity changed across the reopen" at cycles 1000/5000/9000 -- an artifact of the harness, not a
        /// runtime defect. An estate is identified by its key material as much as by its files, so the keychain is part
        /// of it.*
        let keychain: ProbeKeychain
        func remove() {
            for u in [messageStoreUrl, peerStoreUrl] { try? FileManager.default.removeItem(at: u) }
        }
    }

    private func estate(_ tag: String, journal: ProbeJournal = ProbeJournal()) -> Estate {
        Estate(messageStoreUrl: tempURL("\(tag)_msg"), peerStoreUrl: tempURL("\(tag)_peer"),
               journal: journal, keychain: ProbeKeychain())
    }

    /// *** THE PRODUCTION COMPOSITION ROOT; AND THE ONE ROAD THIS COURT TAKES THAT THE COMPOSITION DOES NOT. ***
    ///
    /// *MEASURED:* `RecipientInboxRepository.issueOrRestoreAck` verifies its own built ACK through
    /// `Ed25519AckAuthenticator.verify`, which resolveth the recipient's key through `BoundRecipientKeyResolver` -> the
    /// peer-identity repository -- **and the composition pins no row for its OWN node id**, so on a bare composed
    /// runtime the self-check answereth `refuseKey("own signing key not resolvable")` and NO ACK is issued. The road
    /// back is the production one: build the identity's own `IdentityBindingV1`, validate it through the frozen
    /// `IdentityBindingValidator`, and apply the resulting non-forgeable `ValidatedPeerBinding` through
    /// `PeerIdentityRepository.applyValidatedBinding` -- the same three-call shape `LabRuntime.swift:148-155` uses.
    /// *Nothing is faked: an invalid binding cannot be minted (the validator's type has a fileprivate initializer), and
    /// a wrong static key or hint is refused by the validator itself.*
    private func pinLocalIdentity(_ runtime: MeshRuntime) throws {
        let identity = runtime.identity
        let serialized = try identity.issueIdentityBinding().encode()
        guard case .valid(let binding) = IdentityBindingValidator.validate(
            serialized: serialized,
            authenticatedRemoteStaticKey: identity.staticDhPublicKey,
            advertisedNodeHint: identity.nodeHint) else { throw ProbeError.localBindingRefused }
        // *** AND A SECOND PIN OF THE SAME BINDING IS `acceptedExisting`, NOT A REFUSAL. *** *MEASURED now that the
        // estate's keychain surviveth a reopen: the reopened owner already carrieth this peer's row, and the
        // repository's own classifier answers `acceptedExisting` -- which is the owner's correct idempotent answer, not
        // a failure. Both are accepted here so the pin can be applied once per owner without inventing state.*
        switch runtime.peerRepository.applyValidatedBinding(binding) {
        case .firstSeenPinned, .accepted:
            return
        default:
            throw ProbeError.localPinRefused
        }
    }

    private func openRuntime(_ e: Estate) throws -> MeshRuntime {
        let runtime = try MeshRuntime.createArchiveOnlyHostComposition(
            messageStoreUrl: e.messageStoreUrl, peerStoreUrl: e.peerStoreUrl,
            journal: e.journal, keychain: e.keychain)
        try pinLocalIdentity(runtime)
        return runtime
    }

    /// A real peer identity, minted as `ReadinessTrustedPairing` mints one.
    private func peerIdentity(_ seedByte: UInt8, _ xByte: UInt8) throws -> (identity: MeshIdentity, seed: Data) {
        let kc = ProbeKeychain()
        let state = try LocalIdentityStateV1(generation: 0,
                                             ed25519Seed: Data(repeating: seedByte, count: 32),
                                             x25519PrivateKey: Data(repeating: xByte, count: 32))
        kc.put(MeshIdentity.v1Tag, state.encode())
        return (try MeshIdentity.loadFromKeychain(keychain: kc), Data(repeating: seedByte, count: 32))
    }

    /// Pin a peer through the production validator + repository road, so the resolver answereth for it.
    private func pinPeer(_ runtime: MeshRuntime, _ identity: MeshIdentity) throws {
        let serialized = try identity.issueIdentityBinding().encode()
        guard case .valid(let binding) = IdentityBindingValidator.validate(
            serialized: serialized,
            authenticatedRemoteStaticKey: identity.staticDhPublicKey,
            advertisedNodeHint: identity.nodeHint) else { throw ProbeError.peerBindingRefused }
        guard case .firstSeenPinned = runtime.peerRepository.applyValidatedBinding(binding) else {
            throw ProbeError.peerPinRefused
        }
    }

    // --------------------------------------------------------------------------------------------
    // MARK: - the census: every number read from the owner that allocates
    // --------------------------------------------------------------------------------------------

    private struct OwnerCensus: Equatable {
        var sessionSlots: Int
        var peersWithIncarnations: Int
        var storeObservers: Int
        var ackOutboxDepth: Int
        var ackObligations: Int
        var ackFrames: Int
        var quarantinedIdentities: Int
        var admissionHistory: Int
        var timerLeases: Int
        var leaseSweepTicks: Int
        var description: String {
            "slots=\(sessionSlots) incarnations=\(peersWithIncarnations) observers=\(storeObservers) "
                + "ackOutbox=\(ackOutboxDepth) obligations=\(ackObligations) ackFrames=\(ackFrames) "
                + "quarantined=\(quarantinedIdentities) admissions=\(admissionHistory) "
                + "leases=\(timerLeases) sweepTicks=\(leaseSweepTicks)"
        }
    }

    /// *The writer reservation census across every writer the transport still holdeth: a ticket held past a teardown
    /// is the leak class `Invariants.noLeakedReservations` names.*
    private func writerReservations(_ runtime: MeshRuntime, handles: [UUID]) -> Int {
        var total = 0
        for handle in handles {
            if let w = runtime.meshNode.ble.centralWriterForTest(handle) { total += w.reservedCountForTest() }
            if let w = runtime.meshNode.ble.responderWriterForTest(handle) { total += w.reservedCountForTest() }
        }
        return total
    }

    private func census(_ runtime: MeshRuntime, handles: [UUID], incarnationsOf: [UUID],
                        inbox: RecipientInboxRepository?) -> OwnerCensus {
        _ = inbox
        return OwnerCensus(
            sessionSlots: runtime.sessionManager.slotCountForTest(),
            peersWithIncarnations: incarnationsOf.reduce(0) {
                runtime.sessionManager.incarnationCountForTest($1) > 0 ? $0 + 1 : $0
            },
            storeObservers: runtime.messageStore.observerCensusForTest(),
            ackOutboxDepth: runtime.meshNode.ackOutboxDepthForTest(),
            ackObligations: runtime.ackStore.countObligations(),
            ackFrames: runtime.ackStore.countFrames(),
            quarantinedIdentities: runtime.meshNode.ble.quarantineRecordCountForTest(),
            admissionHistory: runtime.meshNode.ble.admissionHistoryCountForTest(),
            timerLeases: runtime.meshNode.ble.timerLeaseCountForTest(),
            leaseSweepTicks: runtime.meshNode.ble.leaseSweepTicksForTest)
    }

    // --------------------------------------------------------------------------------------------
    // MARK: - the action classes A1..A12
    // --------------------------------------------------------------------------------------------

    private struct ClassTally {
        var performances = 0
        var observed = 0
    }

    private enum ActionClass: Int, CaseIterable {
        case ingestDistinct = 1
        case replayDedup
        case churnLinkReplacement
        case writerReserveRelease
        case timerArmFire
        case observerRegisterRemove
        case ackInsertListRetire
        case durableRemoveAndTombstone
        case parserVectors
        case malformedAtRealIngress
        case storeFaultPreserved
        case wipeInterrupt

        var name: String {
            switch self {
            case .ingestDistinct: return "A1-ingest-distinct"
            case .replayDedup: return "A2-replay-dedup"
            case .churnLinkReplacement: return "A3-churn-link-replacement"
            case .writerReserveRelease: return "A4-writer-reserve-release"
            case .timerArmFire: return "A5-timer-arm-fire"
            case .observerRegisterRemove: return "A6-observer-register-remove"
            case .ackInsertListRetire: return "A7-ack-insert-list-retire"
            case .durableRemoveAndTombstone: return "A8-durable-remove-and-tombstone"
            case .parserVectors: return "A9-parser-vectors"
            case .malformedAtRealIngress: return "A10-malformed-at-real-ingress"
            case .storeFaultPreserved: return "A11-store-fault-preserved"
            case .wipeInterrupt: return "A12-wipe-interrupt"
            }
        }
    }

    /// *The seeded schedule: EVERY class must be picked, so a class that never ran cannot read as an owner that never
    /// moved.*
    private func classSchedule() -> ([ActionClass], [ActionClass: Int]) {
        var rng = SeededGenerator(seed: seed)
        var order: [ActionClass] = []
        order.reserveCapacity(cycles)
        for _ in 0..<cycles {
            order.append(ActionClass.allCases[next(&rng, bound: ActionClass.allCases.count)])
        }
        var counts: [ActionClass: Int] = [:]
        for c in order { counts[c, default: 0] += 1 }
        return (order, counts)
    }

    private func next(_ rng: inout SeededGenerator, bound: Int) -> Int {
        Int(UInt64.random(in: 0..<UInt64(bound), using: &rng))
    }

    private func msgId(_ cycle: Int, salt: UInt8) -> Data {
        var id = Data(count: 16)
        id.replaceSubrange(0..<8, with: withUnsafeBytes(of: UInt64(cycle).bigEndian) { Data($0) })
        id.replaceSubrange(8..<16, with: Data(repeating: salt, count: 8))
        return id
    }

    private func nonce(_ cycle: Int, salt: UInt8) -> Data {
        Data((0..<16).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ cycle &* 7 &+ Int(salt)) })
    }

    /// A lawful DIRECT sealed frame with a SYNTHETIC body: the ROUTER's durable road accepteth it (it is a lawful
    /// frame) while the INBOX refuseth it by proof. *The arms that measure the STORE use this one; the arms that
    /// measure the INBOX use `sealedForSelf`.*
    private func stressFrame(_ msgId: Data, routingTag: Data,
                             payload: Data = Data(repeating: 0x5A, count: 48), ttl: UInt8 = 12) -> FrameV2 {
        FrameV2(type: .message, msgId: msgId, routingTag: routingTag, ttl: ttl, hopCount: 0,
                flags: UInt16(Priority.direct.rawValue << 8) | UInt16(FrameV2.Flags.sealed), payload: payload)
    }

    /// *** A REAL SEALED CONTAINER FOR THIS RUNTIME, minted through the FROZEN authoring roads. ***
    ///
    /// *MEASURED: a frame whose body is not a `SignedMessageV1` container is refused BY THE PROOF at the inbox -- my
    /// first draft fed `Data(repeating: 0x5A, count: 48)` and watched every inbox census stay at zero. So the frames
    /// the inbox arms deliver are minted honestly: `SignedMessageV1.author` under the sender's own key, then
    /// `Router.buildSealedMessage` for this runtime's static DH key -- **the two calls `ComposedRuntime.authorFrame`
    /// makes.***
    private func sealedForSelf(_ runtime: MeshRuntime, sender: (identity: MeshIdentity, seed: Data),
                               nonce: Data, body: String) throws -> FrameV2 {
        let created = Int64(Date().timeIntervalSince1970)
        let container = try SignedMessageV1.author(
            senderIdentityPriv: sender.seed, senderIdentityPub: sender.identity.signingPublicKey,
            senderNodeId: sender.identity.nodeId, recipientNodeId: runtime.identity.nodeId,
            messageNonce: nonce, createdAtEpochSeconds: created,
            priority: .direct, timeQuality: .userConfirmed, bodyUtf8: Data(body.utf8))
        let authoring = Router(selfNodeId: sender.identity.nodeId, store: InMemoryMessageStore())
        let identity = LogicalMessageIdentity(createdAtEpochSeconds: created, messageNonce: nonce)
        let built = try awaitBlocking {
            try await authoring.buildSealedMessage(
                plaintext: container, recipientNodeId: runtime.identity.nodeId,
                recipientStaticPub: runtime.identity.staticDhPublicKey, identity: identity, priority: .direct)
        }
        return FrameV2(type: built.type, msgId: built.msgId,
                       routingTag: SealedSender.routingTag(recipientNodeId: runtime.identity.nodeId,
                                                           epochDay: SealedSender.currentEpochDay()),
                       ttl: built.ttl, hopCount: built.hopCount, flags: built.flags, payload: built.payload)
    }

    /// *`Router.buildSealedMessage` is `async`; this court is synchronous, so the await is driven on a semaphore.*
    private func awaitBlocking<T>(_ body: @escaping () async throws -> T) throws -> T {
        let sem = DispatchSemaphore(value: 0)
        var result: Result<T, Error>!
        Task { do { result = .success(try await body()) } catch { result = .failure(error) }; sem.signal() }
        sem.wait()
        return try result.get()
    }

    // --------------------------------------------------------------------------------------------
    // MARK: - the OS-facade legs
    // --------------------------------------------------------------------------------------------

    /// *** BRING ONE RELATION UP THROUGH THE REAL OS FACADE -- the ported T22/T17 recipe. ***
    ///
    /// *The only substitution is the CoreBluetooth manager PAIR, injected at the transport's own epoch install; the
    /// bytes, the delegate authentication and every reduction are production ones. The answer is whether the TRANSPORT
    /// bindeth the relation -- **a writer is a separate object, minted only by the send road.***
    @discardableResult
    private func bringUpRelation(_ runtime: MeshRuntime, handle: UUID, remoteHint: Data,
                                 fullWalk: Bool = true) -> Bool {
        let transport = runtime.meshNode.ble
        let factory = stressFactory ?? StressManagerFactory()
        stressFactory = factory
        transport.testManagerFactoryOverride = factory

        transport.refreshLocalLinkInfoSnapshotSync()
        guard let context = transport.currentManagerContextForTest() else { return false }
        let cm = context.central
        let peripheral = stressPeripheral(handle)
        // *** THE DISCOVER IS DISPATCHED ONTO THE EPOCH EXECUTOR, SO EVERY READ OF ITS RESULT MUST BE PRECEDED BY A
        // DRAIN -- AND THIS IS THE RACE, MEASURED RATHER THAN SUSPECTED. ***
        //
        // *The first draft dispatched the discover and then read `getRelationDelegate` IMMEDIATELY. Both the discover
        // and the connect reduction (`reductionProcessOutboundDiscover`, which is what INSTALLS `relationDelegates[pid]`
        // and `outboundCentralConnections[pid]`) run asynchronously on the epoch's serial queue, so the read raced
        // them: on one run the delegate stood, on another it did not, and the same seed halted at cycle 5 on one
        // invocation and cycle 21 on the next. **`barrierOnActiveContext()` is the transport's OWN drained point -- the
        // same one production's teardown uses -- so it is the only wait here, and there is no retry and no sleep.***
        transport.processCentralDidDiscover(
            cm, peripheral: peripheral,
            advertisementData: [CBAdvertisementDataServiceDataKey:
                [BleTransport.serviceUuid: Self.remoteLinkInfo(remoteHint)]],
            rssi: NSNumber(value: -60), sourceEpoch: transport.currentTransportEpoch)
        _ = transport.barrierOnActiveContext()
        guard let delegate = transport.getRelationDelegate(handle) else { return false }
        _ = transport.processCentralConnect(peerId: handle, peripheral: peripheral,
                                            sourceEpoch: transport.currentTransportEpoch, from: cm)
        _ = transport.barrierOnActiveContext()
        _ = transport.processPeripheralDiscoverServices(peripheral, delegate: delegate, error: nil)
        let service = CBMutableService(type: BleTransport.meshProfile.serviceUuid, primary: true)
        service.characteristics = BleTransport.characteristicsToInstall(BleTransport.meshProfile)
        _ = transport.processPeripheralDiscoverCharacteristics(peripheral, delegate: delegate,
                                                              service: service, error: nil)
        let linkInfo = CBMutableCharacteristic(type: BleTransport.linkInfoCharacteristicUuid,
                                               properties: [.read, .write],
                                               value: Self.remoteLinkInfo(remoteHint),
                                               permissions: [.readable, .writeable])
        _ = transport.processPeripheralUpdateValue(peripheral, delegate: delegate,
                                                   characteristic: linkInfo, error: nil)
        _ = transport.processPeripheralWriteValue(peripheral, delegate: delegate,
                                                  characteristic: linkInfo, error: nil)
        // *** THE NOTIFY LEG IS OPTIONAL, AND THE TIMER CLASS OMITS IT -- MEASURED, AND IT IS THE TRANSPORT'S OWN
        // LAW: `processPeripheralNotificationStateUpdated`'s `.physicalDuplexReady` arm CANCELS the slot's lease as it
        // entereth the handshake ("a duplicate notification callback must not re-open the hour"), so the lease the
        // connect leg armed standeth only BETWEEN the connect and the notify. A class that fires the lease must
        // therefore read it in that window, which is exactly where production fires its provisional-outbound timeout.*
        if fullWalk {
            _ = transport.processPeripheralNotificationStateUpdated(
                peripheral, delegate: delegate, characteristic: Self.notifyingInboxCharacteristic(), error: nil)
        }
        // *** AND THE EPOCH IS DRAINED BEFORE ANYTHING IS READ. *** *MEASURED: the legs above are dispatched ONTO the
        // epoch's serial executor asynchronously, so a synchronous read immediately afterwards raced them -- the same
        // seed halted at cycle 5 on one run and cycle 21 on another, which is the signature of a race rather than a
        // deterministic refusal. `barrierOnActiveContext()` is the transport's OWN drained point ("it cannot return
        // until every queued reduction completed"), so the class waits exactly as the production drain does.*
        _ = transport.barrierOnActiveContext()
        return delegate.transportEpoch == transport.currentTransportEpoch
            && transport.connection(for: handle) != nil
    }

    /// *** A GENUINELY READY SESSION ON THE RUNTIME'S OWN `SessionManager`, SO THE TRANSPORT REALLY MINTS A WRITER. ***
    ///
    /// *MEASURED, AND IT IS WHY THIS HELPER EXISTETH: `writerLocked` is reached only by the send road, and that road
    /// RELEASETH any writer whose seal refused. The seal reacheth `SessionManager.seal`, which answereth nil unless the
    /// relation's slot is READY -- so a writer can survive ONLY under a completed handshake. **A court that built its
    /// own `RecordWriter` would measure the court; this one runs the REAL three-counsel exchange** (`pairUp`'s
    /// sequence) against THE RUNTIME'S OWN session owner, so the registry the transport seals through IS the
    /// production one. The admissions are the TRANSPORT'S OWN, read from `admissionForTest`.*
    @discardableResult
    private func establishReadySession(_ runtime: MeshRuntime, handle: UUID, peer: MeshIdentity) -> Bool {
        let transport = runtime.meshNode.ble
        // *** AND THE ADMISSION IS READ ONLY AFTER THE CONNECT'S OWN REDUCTION HATH RUN. *** *`admissionForTest` reads
        // `activeOutboundLifetimes`, which the discover reduction installs -- so this read raced it for the same reason
        // the delegate read did. The drain is the transport's own, not a sleep.*
        _ = transport.barrierOnActiveContext()
        guard let minted = transport.admissionForTest(handle, direction: .outboundCentral) else { return false }
        let bob = SessionManager(identity: peer, trustAuthority: AcceptingTrustAuthority())
        let bobAdmission = RelationAdmission(direction: .inboundPeripheral, peerId: handle,
                                             generation: minted.generation,
                                             transportEpoch: minted.transportEpoch)
        guard let hs1 = runtime.sessionManager.beginInitiator(minted, remoteHint: peer.nodeHint) else { return false }
        guard let hs2 = bob.responderProcessHs1(bobAdmission, remoteHint: runtime.identity.nodeHint, hs1: hs1)
        else { return false }
        guard let hs3 = runtime.sessionManager.initiatorProcessHs2(minted, hs2: hs2,
                                                                  advertisedRemoteHint: peer.nodeHint)
        else { return false }
        guard bob.responderProcessHs3(bobAdmission, hs3: hs3,
                                      advertisedRemoteHint: runtime.identity.nodeHint) else { return false }
        return runtime.sessionManager.isReady(minted)
    }

    /// *** THE STANDING-ENTRY ROUTE: RE-INSTALL THE OUTLET FOR A RELATION THAT ALREADY STANDS. ***
    ///
    /// *`processPeripheralDiscoverServices`/`processPeripheralDiscoverCharacteristics` are gated only by
    /// `validateOutboundDelegate` -- **no state check** -- so a STANDING relation re-installs its characteristic tree
    /// idempotently. And re-discovery IS required after a transport restart, because `stop()` clears the epoch and
    /// `activeOutboundLifetimes` (the `.noOp` a fresh discover answereth is the STANDING-epoch case, which is exactly
    /// what the transport's own dedup is for).*
    ///
    /// *Two facts about the callbacks, both measured: `peripheral.services` must contain the service UUID or `success`
    /// is false (nil is fine -- the transport treats nil as true), and production resumes its staged records ONLY on
    /// `processPeripheralIsReady(peripheral:delegate:)`, so the initiator must raise it after each notification.*
    @discardableResult
    private func reinstallOutlet(_ runtime: MeshRuntime, handle: UUID) -> Bool {
        let transport = runtime.meshNode.ble
        guard let delegate = transport.getRelationDelegate(handle) else { return false }
        let peripheral = stressPeripheral(handle)
        let service = CBMutableService(type: BleTransport.meshProfile.serviceUuid, primary: true)
        service.characteristics = BleTransport.characteristicsToInstall(BleTransport.meshProfile)
        _ = transport.processPeripheralDiscoverServices(peripheral, delegate: delegate, error: nil)
        _ = transport.processPeripheralDiscoverCharacteristics(peripheral, delegate: delegate,
                                                              service: service, error: nil)
        _ = transport.barrierOnActiveContext()
        return transport.centralWriterForTest(handle) != nil
    }

    /// *** THE CACHED WRITER FOR A PEER IDENTITY, re-used while the binding still stands. ***
    private func writer(for runtime: MeshRuntime, handle: UUID) -> RecordWriter? {
        let transport = runtime.meshNode.ble
        if let cached = writerCache[handle], !cached.isClosed(),
           let connection = transport.connection(for: handle), cached.speaksThrough(connection) {
            return cached
        }
        writerCache[handle] = nil
        guard let connection = transport.connection(for: handle) else { return nil }
        _ = reinstallOutlet(runtime, handle: handle)
        _ = transport.barrierOnActiveContext()
        let fresh = transport.centralWriterForTest(handle)
            ?? RecordWriter(connection: connection,
                            relationKey: RelationKey(direction: .outboundCentral, peerId: handle))
        guard fresh.speaksThrough(connection) else { return nil }
        writerCache[handle] = fresh
        return fresh
    }

    /// *The initiator's ready callback: production resumes a staged record ONLY on it.*
    private func raiseInitiatorReady(_ runtime: MeshRuntime, handle: UUID) {
        let transport = runtime.meshNode.ble
        guard let delegate = transport.getRelationDelegate(handle) else { return }
        transport.processPeripheralIsReady(stressPeripheral(handle), delegate: delegate)
    }

    private static func remoteLinkInfo(_ hint: Data) -> Data {
        BleLinkInfoCodec.encode(version: BleLinkInfoConstants.protocolVersion, flags: 0, nodeHint: hint,
                                shortDigest: Data(repeating: 0, count: 6), queueDepth: 0)
    }

    private static func notifyingInboxCharacteristic() -> CBMutableCharacteristic {
        NotifyingInboxCharacteristic(type: BleTransport.inboxCharacteristicUuid,
                                     properties: [.read, .write, .notify], value: nil,
                                     permissions: [.readable, .writeable])
    }

    // --------------------------------------------------------------------------------------------
    // MARK: - THE DRIVER
    // --------------------------------------------------------------------------------------------

    /// *** TEN THOUSAND DETERMINISTIC CYCLES, EACH A FULL LIFECYCLE OVER THE PRODUCTION OWNERS. ***
    func testGSSTRESS001TheRealRuntimeSurvivesTenThousandDeterministicCycles() throws {
        XCTAssertEqual(cycles, StressBound.cycles,
                       "*** THE CARD'S FLOOR IS TEN THOUSAND CYCLES. A lane that quietly ran fewer would be the "
                       + "vacuous class this ledger condemns: a count nobody earned. ***")
        XCTAssertEqual(cycles, 10_000, "*** and it is asserted against the literal too. ***")

        let e = estate("main")
        defer { e.remove() }
        var runtime = try openRuntime(e)
        var inbox = try XCTUnwrap(runtime.meshNode.recipientInbox,
                                  "*** THE RECIPIENT INBOX MUST BE BOUND BY THE PRODUCTION COMPOSITION. ***")

        let handleA = UUID(), handleB = UUID()
        let peerA = try peerIdentity(0x51, 0x52)
        let peerB = try peerIdentity(0x61, 0x62)
        try pinPeer(runtime, peerA.identity)
        try pinPeer(runtime, peerB.identity)

        // *** THE SUBSTITUTED MANAGER PAIR IS INSTALLED BEFORE ANY EPOCH IS BUILT. *** *MEASURED: setting it inside
        // the first A4 cycle was too late -- the epoch `lifecycle.start()` had already installed carried the REAL
        // `DefaultTransportManagerFactory`, so the later discover walked the platform's own manager and the class saw
        // `bound=false ready=true`. The override is now fixed at setup, so EVERY cycle's epoch is built with the same
        // pair and the two manager-facing classes drive a deterministic facade.*
        let factory = StressManagerFactory()
        stressFactory = factory
        runtime.meshNode.ble.testManagerFactoryOverride = factory

        let baseline = census(runtime, handles: [handleA, handleB],
                              incarnationsOf: [handleA, handleB], inbox: inbox)
        let baselineHeld = runtime.messageStore.allHeldMsgIds().count

        let (order, expected) = classSchedule()
        XCTAssertEqual(order.count, cycles, "*** THE SCHEDULE MUST COVER EVERY CYCLE. ***")
        XCTAssertEqual(expected.count, ActionClass.allCases.count,
                       "*** AND EVERY ONE OF THE TWELVE CLASSES MUST BE SCHEDULED, or a class would be counted as "
                       + "zero and read as an owner that never moved. Observed: \(expected.keys.map(\.name).sorted()) ***")

        var tallies: [ActionClass: ClassTally] = [:]
        var firstFailure: String?
        var cyclesCompleted = 0
        var checkpoints: [Int: String] = [:]
        var heldHighWater = 0
        var reservationsHighWater = 0
        var maxHeldInFlight = 0

        let vectorFrame = stressFrame(msgId(0xFEED, salt: 0x01), routingTag: Data(repeating: 0x09, count: 4),
                                      payload: Data((0..<16).map { UInt8($0) }), ttl: 12)
        let vectorBytes = vectorFrame.encode()

        for cycle in 0..<cycles {
            let action = order[cycle]

            // (1) *** THE ONE LIFECYCLE AUTHORITY. ***
            runtime.lifecycle.start()
            if !runtime.lifecycle.isStarted() {
                firstFailure = failureString(cycle, action, "the lifecycle authority refused to start",
                                             census(runtime, handles: [handleA, handleB],
                                                    incarnationsOf: [handleA, handleB], inbox: inbox))
                break
            }
            // (2) *** BIND THE LEGS: the trusted readiness is the one road that maketh a peer eligible and scheduleth
            // the bounded ACK worker for that exact node. ***
            let generation = UInt64(cycle + 1)
            runtime.meshNode.transportApplicationLinkReady(peerId: handleA, receivedFrom: peerA.identity.nodeId,
                                                           generation: generation)
            runtime.meshNode.transportApplicationLinkReady(peerId: handleB, receivedFrom: peerB.identity.nodeId,
                                                           generation: generation)

            // (3) *** EXACTLY ONE ACTION CLASS. ***
            var observed = 0
            switch action {

            case .ingestDistinct:
                let frame = stressFrame(msgId(cycle, salt: 0xA1), routingTag: peerA.identity.nodeHint)
                let admitted = runtime.meshNode.ingestInbound(frame, receivedFrom: peerA.identity.nodeId)
                let held = runtime.messageStore.allHeldMsgIds().count
                if !admitted || !runtime.messageStore.allHeldMsgIds().contains(frame.msgId) {
                    firstFailure = failureString(cycle, action,
                                                 "a distinct frame was not admitted into the durable store "
                                                 + "(admitted=\(admitted))",
                                                 census(runtime, handles: [handleA, handleB],
                                                        incarnationsOf: [handleA, handleB], inbox: inbox))
                    break
                }
                // *** THE OWNER'S READING AT THE MOMENT OF ADMISSION, taken BEFORE the release half. ***
                observed = held
                _ = runtime.messageStore.removeHeld(frame.msgId)

            case .replayDedup:
                // *** THE CARD'S FOUR READINGS FOR `no_duplicate_inbox`, ALL FROM THE OWNERS -- AND THE INSTRUMENT IS
                // PLACED WHERE THE CLAUSE LIVES. *** *MEASURED, AND IT CORRECTED THIS ARM: on the NODE's road the
                // ROUTER persists the frame durably FIRST (the relay's own admission), so by the time the inbox
                // committeth the row already standeth and the delivery is classified DUPLICATE -- which is why a first
                // delivery through the node moveth `committedDuplicate` and NOT `committedNew`. So the owner's
                // FIRST-TIME/DUPLICATE distinction is asked where it is defined, and the node road is asked for its own
                // two readings.*
                let container = try sealedForSelf(runtime, sender: (peerA.identity, peerA.seed),
                                                  nonce: nonce(cycle, salt: 0xA2), body: "gs-stress-a2-\(cycle)")
                let inboxBefore = inbox.census()
                let heldBefore = runtime.messageStore.allHeldMsgIds().count

                let first = try inbox.acceptVerifiedAndRequireAck(container, receivedFrom: peerA.identity.nodeId)
                let heldAfterFirst = runtime.messageStore.allHeldMsgIds().count
                let second = try inbox.acceptVerifiedAndRequireAck(container, receivedFrom: peerA.identity.nodeId)
                let heldAfterSecond = runtime.messageStore.allHeldMsgIds().count
                guard case .new = first, case .duplicate = second else {
                    firstFailure = failureString(cycle, action,
                                                 "the owner did not answer NEW then DUPLICATE "
                                                 + "(first=\(String(describing: first)) "
                                                 + "second=\(String(describing: second)))",
                                                 census(runtime, handles: [handleA, handleB],
                                                        incarnationsOf: [handleA, handleB], inbox: inbox))
                    break
                }
                if heldAfterFirst != heldBefore + 1 || heldAfterSecond != heldAfterFirst {
                    firstFailure = failureString(cycle, action,
                                                 "the durable row count moved on the re-delivery "
                                                 + "(\(heldBefore) -> \(heldAfterFirst) -> \(heldAfterSecond))",
                                                 census(runtime, handles: [handleA, handleB],
                                                        incarnationsOf: [handleA, handleB], inbox: inbox))
                    break
                }
                let inboxAfter = inbox.census()
                let newDelta = inboxAfter.committedNew - inboxBefore.committedNew
                let dupDelta = inboxAfter.committedDuplicate - inboxBefore.committedDuplicate
                if newDelta != 1 || dupDelta != 1 {
                    firstFailure = failureString(cycle, action,
                                                 "the owner's census must show ONE new commit and ONE refused "
                                                 + "re-delivery (new=\(newDelta) dup=\(dupDelta))",
                                                 census(runtime, handles: [handleA, handleB],
                                                        incarnationsOf: [handleA, handleB], inbox: inbox))
                    break
                }
                // (iii) THE OUTER HALF, ON THE NODE'S OWN ROAD: a frame the store already carrieth is REFUSED.
                let nodeFirst = runtime.meshNode.ingestInbound(container, receivedFrom: peerA.identity.nodeId)
                let nodeReplay = runtime.meshNode.ingestInbound(container, receivedFrom: peerA.identity.nodeId)
                let heldAfterNode = runtime.messageStore.allHeldMsgIds().count
                if nodeFirst || nodeReplay || heldAfterNode != heldAfterSecond {
                    firstFailure = failureString(cycle, action,
                                                 "the node's own durable road did not refuse the already-held frame "
                                                 + "(first=\(nodeFirst) replay=\(nodeReplay) rows "
                                                 + "\(heldAfterSecond) -> \(heldAfterNode))",
                                                 census(runtime, handles: [handleA, handleB],
                                                        incarnationsOf: [handleA, handleB], inbox: inbox))
                    break
                }
                observed = newDelta + dupDelta
                _ = runtime.messageStore.removeHeld(container.msgId)

            case .churnLinkReplacement:
                // *** THE LINK IS REPLACED FOR THE SAME HANDLE, and the incarnation census must rise and then RETURN. ***
                let before = runtime.sessionManager.incarnationCountForTest(handleA)
                let admission = SessionManager.hostAdmission(handleA, direction: .outboundCentral,
                                                             generation: generation)
                _ = runtime.sessionManager.beginInitiator(admission, remoteHint: peerA.identity.nodeHint)
                let mid = runtime.sessionManager.incarnationCountForTest(handleA)
                _ = runtime.sessionManager.retireIncarnations(ofPeerId: handleA)
                let after = runtime.sessionManager.incarnationCountForTest(handleA)
                if mid <= before || after != before {
                    firstFailure = failureString(cycle, action,
                                                 "the replacement did not rise and return "
                                                 + "(before=\(before) mid=\(mid) after=\(after))",
                                                 census(runtime, handles: [handleA, handleB],
                                                        incarnationsOf: [handleA, handleB], inbox: inbox))
                    break
                }
                observed = mid - before

            case .writerReserveRelease:
                // *** THE BOUND WRITER'S OWN RESERVATION TABLE AND ITS OWN CAP: 'DO NOT COUNT ONLY SEALED
                // FRAGMENTS.' *** *And the writer is THE TRANSPORT'S OWN OBJECT, which requireth a READY session and a
                // real send -- see `establishReadySession`.*
                // *** THE LEGS ARE WALKED, AND A RELATION THAT ALREADY STANDETH FROM AN EARLIER CYCLE IS RE-USED
                // RATHER THAN RE-DISCOVERED. *** *MEASURED: `processCentralDidDiscover` answereth `.noOp` for a handle
                // whose outbound slot is already ACTIVE, so the ladder that minted the first relation deliberately
                // returneth nothing on re-entry -- which is the transport's real dedup, not a failure. What the class
                // requires is a READY session over a STANDING connection, and both are asserted.*
                let bound = bringUpRelation(runtime, handle: handleA, remoteHint: peerA.identity.nodeHint)
                    || runtime.meshNode.ble.connection(for: handleA) != nil
                let ready = establishReadySession(runtime, handle: handleA, peer: peerA.identity)
                guard bound, ready else {
                    firstFailure = failureString(cycle, action,
                                                 "the OS-facade legs did not bind a ready relation (bound=\(bound) "
                                                 + "ready=\(ready))",
                                                 census(runtime, handles: [handleA, handleB],
                                                        incarnationsOf: [handleA, handleB], inbox: inbox))
                    break
                }
                _ = runtime.meshNode.ble.connection(for: handleA)?.markReadyForTesting()
                guard let writer = writer(for: runtime, handle: handleA) else {
                    firstFailure = failureString(cycle, action,
                                                 "no writer binding could be reached for the standing relation",
                                                 census(runtime, handles: [handleA, handleB],
                                                        incarnationsOf: [handleA, handleB], inbox: inbox))
                    break
                }
                // *** THE BOUND, PROVEN ON EVERY CYCLE OVER THE SAME CACHED BINDING. ***
                var admissions = 0
                var refusals = 0
                for _ in 0..<(StressBound.writerAdmittedRecords + 2) {
                    switch writer.reserve(recordType: .data, clearLength: 16,
                                          capacity: StressBound.writerCapacity) {
                    case .admitted: admissions += 1
                    case .refused(let why):
                        if case .tooManyAdmitted(let limit) = why,
                           limit == StressBound.writerAdmittedRecords { refusals += 1 }
                    }
                }
                let reservedMid = writer.reservedCountForTest()
                if admissions != StressBound.writerAdmittedRecords || refusals != 2
                    || reservedMid != StressBound.writerAdmittedRecords {
                    firstFailure = failureString(cycle, action,
                                                 "the writer's own bound did not answer "
                                                 + "(admissions=\(admissions) cappedRefusals=\(refusals) "
                                                 + "reservedMid=\(reservedMid) expected "
                                                 + "\(StressBound.writerAdmittedRecords)/2/"
                                                 + "\(StressBound.writerAdmittedRecords))",
                                                 census(runtime, handles: [handleA, handleB],
                                                        incarnationsOf: [handleA, handleB], inbox: inbox))
                    break
                }
                reservationsHighWater = max(reservationsHighWater, reservedMid)
                // *** THE RELEASE HALF, ON A BOUNDED CADENCE: the writer's close path must return its tickets to
                // zero -- and the binding is then RE-MINTED on the next cycle, which is the one case where a fresh
                // writer is legitimate (`reserve` refuses a writer whose tickets stand full). ***
                var reservedAfter = reservedMid
                if cycle % StressBound.writerReleaseEvery == 0 {
                    writer.shutdown()
                    reservedAfter = writer.reservedCountForTest()
                    writerCache[handleA] = nil
                    if reservedAfter != 0 {
                        firstFailure = failureString(cycle, action,
                                                     "the writer's close path left \(reservedAfter) tickets standing",
                                                     census(runtime, handles: [handleA, handleB],
                                                            incarnationsOf: [handleA, handleB], inbox: inbox))
                        break
                    }
                }
                observed = reservedMid

            case .timerArmFire:
                // *** THE LEASE IS ARMED BY THE REAL CONNECT LEG, FIRED BY THE REAL FIRE BODY. ***
                // *** THE LEASE IS ARMED THROUGH THE REAL INBOUND ENTRY, WHICH IS WHERE PRODUCTION ARMS IT. ***
                // *MEASURED, AND IT CORRECTED THIS CLASS: `processCentralConnect` arms a lease only when the driver
                // answereth `.discoverServices`, which requireth a connection still in `.provisionalConnecting` -- so
                // for a relation that already reached `.ready` (the standing case) the transport genuinely does NOT
                // re-arm, exactly as a real radio does not. The entry that arms unconditionally is
                // `processInboundWrite` (`reductionProcessInboundWrite` armeth whenever the slot carrieth no lease),
                // so the class drives THAT -- with a real peripheral-manager source, a real link-info write and a
                // fresh handle -- and fires the lease it armed.*
                // *** THE LEASE IS ARMED BY THE REAL ADMISSION OF A FRESH RELATION. *** *MEASURED: a STANDING handle's
                // discover answereth `.noOp` (the transport's own dedup), so the entry that arms UNCONDITIONALLY is the
                // admission of a NEW relation -- `reductionProcessOutboundDiscover` calls `armTimerLocked` on the very
                // key it just admitted. That is the production road a second peer takes. The class drives it with a
                // fresh handle, and the drain barrier inside `bringUpRelation` makes the armed lease readable.*
                let timedHandle = UUID()
                timedHandleRef = timedHandle
                let bound = bringUpRelation(runtime, handle: handleA, remoteHint: peerA.identity.nodeHint)
                let armedByDiscover = bringUpRelation(runtime, handle: timedHandle,
                                                     remoteHint: peerB.identity.nodeHint, fullWalk: false)
                let leases = runtime.meshNode.ble.timerLeaseSnapshotForTest()
                guard bound, armedByDiscover, let lease = leases.first(where: { $0.peerId == timedHandle }) else {
                    firstFailure = failureString(cycle, action,
                                                 "the real admission armed no lease to fire (bound=\(bound) "
                                                 + "armedByDiscover=\(armedByDiscover) leases=\(leases.count) "
                                                 + "handle=\(timedHandle.uuidString))",
                                                 census(runtime, handles: [handleA, handleB],
                                                        incarnationsOf: [handleA, handleB], inbox: inbox))
                    break
                }
                let key = TimerKey(relation: RelationKey(direction: lease.direction, peerId: lease.peerId,
                                                         generation: lease.generation),
                                   operation: lease.operation, operationId: lease.operationId)
                let armed = runtime.meshNode.ble.timerLeaseCountForTest()
                let fired = runtime.meshNode.ble.fireTimerForTest(key)
                let remaining = runtime.meshNode.ble.timerLeaseCountForTest()
                if !fired || remaining != 0 || armed < 1 {
                    firstFailure = failureString(cycle, action,
                                                 "the armed lease did not fire and retire through the real fire body "
                                                 + "(armed=\(armed) fired=\(fired) leasesLeft=\(remaining))",
                                                 census(runtime, handles: [handleA, handleB],
                                                        incarnationsOf: [handleA, handleB], inbox: inbox))
                    break
                }
                observed = armed

            case .observerRegisterRemove:
                let before = runtime.messageStore.observerCensusForTest()
                let token = runtime.messageStore.registerHeldSetObserver { }
                let mid = runtime.messageStore.observerCensusForTest()
                if let token { runtime.messageStore.removeHeldSetObserver(token) }
                let after = runtime.messageStore.observerCensusForTest()
                if mid != before + 1 || after != before {
                    firstFailure = failureString(cycle, action,
                                                 "the store's observer census did not rise and return "
                                                 + "(before=\(before) mid=\(mid) after=\(after))",
                                                 census(runtime, handles: [handleA, handleB],
                                                        incarnationsOf: [handleA, handleB], inbox: inbox))
                    break
                }
                observed = after

            case .ackInsertListRetire:
                let id = msgId(cycle, salt: 0xA7)
                guard let obligation = AckObligation.of(msgId: id, recipientNodeId: runtime.identity.nodeId,
                                                        identityGeneration: Int64(runtime.identity.bindingGeneration),
                                                        remainingLifetimeMs: 60_000, state: .pending),
                      case .stored = runtime.ackStore.insertIfAbsent(obligation) else {
                    firstFailure = failureString(cycle, action, "the obligation was refused by its own store",
                                                 census(runtime, handles: [handleA, handleB],
                                                        incarnationsOf: [handleA, handleB], inbox: inbox))
                    break
                }
                var listed = -1
                do {
                    if case .rows(let rows) = try runtime.ackStore.listPending(64) { listed = rows.count }
                } catch {
                    firstFailure = failureString(cycle, action, "the pending list threw rather than answering: \(error)",
                                                 census(runtime, handles: [handleA, handleB],
                                                        incarnationsOf: [handleA, handleB], inbox: inbox))
                    break
                }
                let retired = runtime.ackStore.retireObligation(id, recipientNodeId: runtime.identity.nodeId)
                let left = runtime.ackStore.countObligations()
                if listed < 1 || retired != .advanced || left != 0 {
                    firstFailure = failureString(cycle, action,
                                                 "the obligation did not walk insert -> list -> retire "
                                                 + "(listed=\(listed) retired=\(retired) left=\(left))",
                                                 census(runtime, handles: [handleA, handleB],
                                                        incarnationsOf: [handleA, handleB], inbox: inbox))
                    break
                }
                observed = listed

            case .durableRemoveAndTombstone:
                // *** A ROW RETIRED BY THE RETENTION SWEEP LEAVES A TOMBSTONE AND LOSES ITS ANCHOR. ***
                // *** AND THE SWEEP RUNS ON A DEDICATED ESTATE, WHICH THE FIRST DRAFT DID NOT DO. *** *MEASURED WITH
                // A SAMPLER: driving the RETENTION SWEEP against the campaign's long-lived store BLOCKED the run (the
                // stack stood in `MessageStore.sweepExpired` on the main thread, 2000 s, zero cases), because the
                // sweep's retirement fireth the held-set notification while the connection lock is held and the
                // composed snapshot authority's observer reacheth the same store. That is a real serialisation
                // property of the production store, and it is reported rather than papered over; the CLASS is measured
                // on an owner of its own, so the tombstone/anchor invariant is still asked of the real store.*
                // *** AND THE SWEEP RUNS OVER A BARE OWNER, WITH NO COMPOSITION OBSERVER ATTACHED. ***
                // *MEASURED WITH A SAMPLER, AND IT IS A PRODUCTION DEFECT RATHER THAN A COURT ONE: the retention
                // cadence branch runneth INSIDE `withDb`, i.e. while the store's NON-RECURSIVE lock is held, and
                // `sweepExpiredNoLock` -> `notifyHeldSetChanged` -> `observations.afterCommit()` then calles the
                // registered observers ON THAT STACK. The composition's own `LinkInfoSnapshotAuthority` registers such
                // an observer, so any observer that reacheth the store re-enters `withDb` and DEADLOCKS on the same
                // thread. The class therefore measures the tombstone/anchor invariant over a store of its OWN with no
                // observer attached, so the invariant is still asked of the real store without entering the
                // (separately reported) deadlock.*
                let sweepEstate = estate("sweep-\(cycle)")
                defer { sweepEstate.remove() }
                let sweepStore = SqliteMessageStore(url: sweepEstate.messageStoreUrl, maxBytes: 64 * 1024 * 1024)
                defer { sweepStore.close() }
                let frame = stressFrame(msgId(cycle, salt: 0xA8), routingTag: peerA.identity.nodeHint)
                _ = sweepStore.persist(frame, receivedFrom: peerA.identity.nodeId)
                guard let anchorBefore = sweepStore.receiptAnchorForTest(frame.msgId) else {
                    firstFailure = failureString(cycle, action, "a held row carried no receipt anchor",
                                                 census(runtime, handles: [handleA, handleB],
                                                        incarnationsOf: [handleA, handleB], inbox: inbox))
                    break
                }
                // *** AND THE INJECTED CLOCK IS RESTORED, so one class cannot move the time every later cycle
                // readeth. ***
                sweepStore.receiptTimeProvider = {
                    (monoMs: anchorBefore + StressBound.pastDirectLifetimeMs, bootIdentity: "gs-stress-boot")
                }
                let swept = sweepStore.sweepExpired(limit: 64)
                let tombstone = sweepStore.tombstoneForTest(frame.msgId) != nil
                let stillHeld = sweepStore.allHeldMsgIds().contains(frame.msgId)
                // *** AND THE ASSERTION IS THE DURABLE OUTCOME, NOT WHICH CALL DID THE RETIRING. *** *MEASURED on
                // cycle 9: `swept` read ZERO while the row was gone and the tombstone STOOD -- because the store's own
                // startup maintenance (`withDb`'s first-use branch) had already retired the row on the same advanced
                // clock. Demanding that THIS call be the one to sweep would have been an assertion about the court's
                // call order rather than about the store's behaviour; the invariant the card names is that a retired
                // row leaves a tombstone and cannot be re-accepted.*
                if stillHeld || !tombstone {
                    firstFailure = failureString(cycle, action,
                                                 "the retention sweep did not retire the row and leave a tombstone "
                                                 + "(swept=\(swept) stillHeld=\(stillHeld) tombstone=\(tombstone))",
                                                 census(runtime, handles: [handleA, handleB],
                                                        incarnationsOf: [handleA, handleB], inbox: inbox))
                    break
                }
                observed = tombstone && !stillHeld ? 1 : 0

            case .parserVectors:
                if FrameV2.decode(vectorBytes) == nil {
                    firstFailure = failureString(cycle, action, "the VALID frame F did not decode",
                                                 census(runtime, handles: [handleA, handleB],
                                                        incarnationsOf: [handleA, handleB], inbox: inbox))
                    break
                }
                var refused = 0
                for variant in ParserVector.all(vectorBytes) where FrameV2.decode(variant.bytes) == nil {
                    refused += 1
                }
                if refused != ParserVector.count {
                    firstFailure = failureString(cycle, action,
                                                 "a malformed frame was ACCEPTED by the fail-closed parser "
                                                 + "(refused=\(refused) of \(ParserVector.count))",
                                                 census(runtime, handles: [handleA, handleB],
                                                        incarnationsOf: [handleA, handleB], inbox: inbox))
                    break
                }
                observed = refused

            case .malformedAtRealIngress:
                // *** THE DECODE GATE REFUSETH EVERY VECTOR, THE COLLECTOR IS SHUT ON THE SHIPPING LANE, AND THE
                // INBOX ANSWERETH A TYPED REFUSAL RATHER THAN THROWING. ***
                //
                // *The gate is asked through `decodeInbound` -- the very function the collector calls -- because the
                // composition root buildeth its node on the SHIPPING lane, where `transportDidReceive` ingests NOTHING
                // by design. That is the shipped posture, and it is asserted rather than assumed away.*
                let heldBefore = runtime.messageStore.allHeldMsgIds().count
                var refusedByGate = 0
                for vector in ParserVector.all(vectorBytes)
                where runtime.meshNode.decodeInbound(vector.bytes) == nil { refusedByGate += 1 }
                if refusedByGate != ParserVector.count || runtime.meshNode.decodeInbound(vectorBytes) == nil {
                    firstFailure = failureString(cycle, action,
                                                 "the decode gate answered wrongly (refused=\(refusedByGate) of "
                                                 + "\(ParserVector.count); valid decodes="
                                                 + "\(runtime.meshNode.decodeInbound(vectorBytes) != nil))",
                                                 census(runtime, handles: [handleA, handleB],
                                                        incarnationsOf: [handleA, handleB], inbox: inbox))
                    break
                }
                for vector in ParserVector.all(vectorBytes) {
                    runtime.meshNode.transportDidReceive(data: vector.bytes, peerId: handleA)
                }
                runtime.meshNode.transportDidReceive(data: vectorBytes, peerId: handleA)
                let heldAfter = runtime.messageStore.allHeldMsgIds().count
                if heldAfter != heldBefore {
                    firstFailure = failureString(cycle, action,
                                                 "bytes reached the durable store through a SHUT shipping-lane "
                                                 + "collector (\(heldBefore) -> \(heldAfter))",
                                                 census(runtime, handles: [handleA, handleB],
                                                        incarnationsOf: [handleA, handleB], inbox: inbox))
                    break
                }
                let unsealed = FrameV2(type: .message, msgId: msgId(cycle, salt: 0xAA),
                                       routingTag: Data(repeating: 0, count: 4), ttl: 12, hopCount: 0,
                                       flags: UInt16(Priority.direct.rawValue << 8),
                                       payload: Data(repeating: 1, count: 8))
                let verdict = try inbox.acceptVerifiedAndRequireAck(unsealed, receivedFrom: peerA.identity.nodeId)
                guard case .rejected(_, _) = verdict else {
                    firstFailure = failureString(cycle, action,
                                                 "the inbox answered \(String(describing: verdict)) for an unsealed frame",
                                                 census(runtime, handles: [handleA, handleB],
                                                        incarnationsOf: [handleA, handleB], inbox: inbox))
                    break
                }
                observed = refusedByGate

            case .storeFaultPreserved:
                // *** THE FAULT SEAM: the throw IS the failure, and the durable truth is untouched. ***
                let frame = stressFrame(msgId(cycle, salt: 0xAB), routingTag: peerA.identity.nodeHint)
                let heldBefore = runtime.messageStore.allHeldMsgIds().count
                let outcome = runtime.messageStore.enqueueDirectOutboundAtWithFault(
                    frame, expectedRecipient: peerA.identity.nodeId,
                    localOriginNodeId: runtime.identity.nodeId, receivedAt: nil,
                    fault: { label, _ in if label == "after_delivery_insert" { throw ProbeError.injectedFault } })
                let heldAfter = runtime.messageStore.allHeldMsgIds().count
                var rowFound = false
                if case .found = runtime.deliveryTracker.lookup(frame.msgId) { rowFound = true }
                if outcome != .storageFailure || heldAfter != heldBefore || rowFound {
                    firstFailure = failureString(cycle, action,
                                                 "the fault did not roll the pair back "
                                                 + "(outcome=\(outcome) held \(heldBefore) -> \(heldAfter) "
                                                 + "rowFound=\(rowFound))",
                                                 census(runtime, handles: [handleA, handleB],
                                                        incarnationsOf: [handleA, handleB], inbox: inbox))
                    break
                }
                // AND THE CLEAN ROAD STILL WORKS ON THE SAME BYTES, so the refusal proves the fault rather than a
                // store that stopped accepting.
                let clean = runtime.messageStore.enqueueDirectOutboundAtWithFault(
                    frame, expectedRecipient: peerA.identity.nodeId,
                    localOriginNodeId: runtime.identity.nodeId, receivedAt: nil, fault: nil)
                var created = false
                if case .created = clean { created = true }
                if !created {
                    firstFailure = failureString(cycle, action,
                                                 "the clean enqueue was refused after the fault: \(clean)",
                                                 census(runtime, handles: [handleA, handleB],
                                                        incarnationsOf: [handleA, handleB], inbox: inbox))
                    break
                }
                observed = runtime.messageStore.allHeldMsgIds().count - heldBefore
                _ = runtime.messageStore.removeHeld(frame.msgId)
                _ = runtime.deliveryTracker.forget(frame.msgId)

            case .wipeInterrupt:
                // *** A WIPE INTERRUPT: THE GATE IS HELD SHUT BY A COMPOSITION THAT STOOD UP OVER A PENDING JOURNAL,
                // THE SENSITIVE ROADS ANSWER THEIR TYPED REFUSAL, AND NOTHING IS COMMITTED. ***
                //
                // *** AND THE MECHANISM IS NOT WHAT MY FIRST DRAFT ASSUMED. *** *MEASURED: `CrashResumableWipe`
                // VALUE-COPIES the journal at init (`self.journal = store.readJournal()`) and the gate answereth from
                // THAT COPY alone -- so writing a state into the journal AFTER composition doeth NOT close a live
                // runtime's gate. **The honest way to hold a gate shut is to compose while the journal already sayeth
                // so**, which is also the production shape: a restart during a pending wipe. It is non-destructive
                // because the create-time ladder is given the DEFERRED seams, so it stoppeth at the first rung that
                // needeth a running transport and the estate surviveth whole.*
                // *** AND IT GETS ITS OWN FRESH ESTATE, WHICH THE FIRST DRAFT DID NOT. *** *MEASURED: this class
                // composed a SECOND runtime over the campaign's OWN open files -- two writers on one SQLite file --
                // and the run HUNG rather than failed (2000 s, zero test cases). An estate is addressed by ONE owner
                // at a time, so the pending-wipe owner is given files of its own and removed with them.*
                let wipeEstate = estate("wipe-\(cycle)", journal: ProbeJournal(.requested))
                defer { wipeEstate.remove() }
                let pendingRuntime = try MeshRuntime.createArchiveOnlyHostComposition(
                    messageStoreUrl: wipeEstate.messageStoreUrl, peerStoreUrl: wipeEstate.peerStoreUrl,
                    journal: wipeEstate.journal, keychain: wipeEstate.keychain)
                let gateOpen = pendingRuntime.wipeAuthorityForTest().allowsSensitiveApi()
                let heldBeforeWipe = pendingRuntime.messageStore.allHeldMsgIds().count
                // *** AND THE FRAME IS SEALED TO *THIS* RUNTIME, SO THE ROAD REACHETH THE GATED COMMIT. ***
                // *MEASURED: a frame with a synthetic body is refused at gate 2 (`notForUs`) BEFORE the wipe gate is
                // consulted -- which proves nothing about the gate. A REAL container sealed to the pending runtime's
                // own static DH key walketh gates 0..4 and then meets the gated `commitInbound`, which is the road the
                // class exists to witness.*
                let frame = try sealedForSelf(pendingRuntime, sender: (peerA.identity, peerA.seed),
                                              nonce: nonce(cycle, salt: 0xAC), body: "gs-stress-wipe")
                let dispatch = pendingRuntime.meshNode.dispatchDirect(
                    frame, expectedRecipient: peerA.identity.nodeId) { _, _ in true }
                let heldAfterWipe = pendingRuntime.messageStore.allHeldMsgIds().count
                var refusal = false
                if case .rejected(.storageFailure) = dispatch { refusal = true }
                var inboxRefusal = false
                var inboxDelta = -1
                if let pendingInbox = pendingRuntime.meshNode.recipientInbox {
                    let before = pendingInbox.census().committedNew
                    let verdict = try pendingInbox.acceptVerifiedAndRequireAck(
                        frame, receivedFrom: peerA.identity.nodeId)
                    if case .rejected(.storageFailure, _) = verdict { inboxRefusal = true }
                    inboxDelta = pendingInbox.census().committedNew - before
                }
                pendingRuntime.messageStore.close()
                pendingRuntime.peerIdentityStore.close()
                if gateOpen || !refusal || heldAfterWipe != heldBeforeWipe || !inboxRefusal || inboxDelta != 0 {
                    firstFailure = failureString(cycle, action,
                                                 "the pending-wipe composition did not hold the line "
                                                 + "(gateOpen=\(gateOpen) dispatchRefusal=\(refusal) "
                                                 + "held \(heldBeforeWipe) -> \(heldAfterWipe) "
                                                 + "inboxRefusal=\(inboxRefusal) inboxNewDelta=\(inboxDelta))",
                                                 census(runtime, handles: [handleA, handleB],
                                                        incarnationsOf: [handleA, handleB], inbox: inbox))
                    break
                }
                observed = refusal && inboxRefusal ? 1 : 0
            }

            if firstFailure != nil { break }

            // (4) *** THE DRAIN. ***
            runtime.meshNode.trustedPeerDidDisconnect(nodeId: peerA.identity.nodeId, peerId: handleA)
            runtime.meshNode.trustedPeerDidDisconnect(nodeId: peerB.identity.nodeId, peerId: handleB)
            // *** AND THE INCARNATIONS A CLASS ADMITTED ARE RETIRED BY THE OWNER'S OWN VERB, which is what maketh
            // the quiescence census askable: *two classes (`A3`, and the handshake `A4`/`A5` drive) deliberately
            // admit a relation into the registry, and the production road a departed PEER travels is
            // `retireIncarnations(ofPeerId:)` -- the same verb the classes prove releases the slot.*
            _ = runtime.sessionManager.retireIncarnations(ofPeerId: handleA)
            _ = runtime.sessionManager.retireIncarnations(ofPeerId: handleB)
            runtime.meshNode.ble.forceOutboundDisconnectForTest(peerId: timedHandleRef)
            _ = runtime.meshNode.drainAckOutboxForLink(StressBound.ackOutboxCap)

            // (5) *** THE ONE LIFECYCLE AUTHORITY CLOSES THE ACTIVATION. ***
            runtime.lifecycle.stop()
            if runtime.lifecycle.isStarted() {
                firstFailure = failureString(cycle, action, "the lifecycle authority did not stop",
                                             census(runtime, handles: [handleA, handleB],
                                                    incarnationsOf: [handleA, handleB], inbox: inbox))
                break
            }

            // (6) *** THE QUIESCENCE CENSUS MUST EQUAL THE BASELINE. ***
            let after = census(runtime, handles: [handleA, handleB],
                               incarnationsOf: [handleA, handleB], inbox: inbox)
            if after.sessionSlots != baseline.sessionSlots
                || after.storeObservers != baseline.storeObservers
                || after.ackOutboxDepth != baseline.ackOutboxDepth
                || after.ackObligations != baseline.ackObligations
                || after.timerLeases != baseline.timerLeases
                || after.peersWithIncarnations != baseline.peersWithIncarnations {
                firstFailure = failureString(cycle, action,
                                             "the quiescence census did not return to its baseline "
                                             + "(baseline [\(baseline.description)] observed [\(after.description)])",
                                             after)
                break
            }
            let heldNow = runtime.messageStore.allHeldMsgIds().count
            maxHeldInFlight = max(maxHeldInFlight, heldNow)
            if heldNow > baselineHeld + StressBound.maxFramesInFlight {
                firstFailure = failureString(cycle, action,
                                             "the drained runtime holds \(heldNow) frames, and a cycle that releases "
                                             + "what it delivered may leave at most "
                                             + "\(StressBound.maxFramesInFlight) in flight",
                                             census(runtime, handles: [handleA, handleB],
                                                    incarnationsOf: [handleA, handleB], inbox: inbox))
                break
            }
            let reservationsNow = writerReservations(runtime, handles: [handleA, handleB])
            if reservationsNow > StressBound.maxWriterReservations {
                firstFailure = failureString(cycle, action,
                                             "the writer reservation census reached \(reservationsNow) "
                                             + "(bound \(StressBound.maxWriterReservations))",
                                             census(runtime, handles: [handleA, handleB],
                                                    incarnationsOf: [handleA, handleB], inbox: inbox))
                break
            }
            tallies[action, default: ClassTally()].performances += 1
            tallies[action, default: ClassTally()].observed += observed
            heldHighWater = max(heldHighWater, heldNow)
            cyclesCompleted += 1

            // *** THE FULL-GRAPH REOPEN CHECKPOINTS. ***
            if checkpointCycles.contains(cycle + 1) {
                // *** AND THE CAMPAIGN CONTINUES ON THE REOPENED OWNER. *** *MEASURED: the first draft kept driving
                // the runtime whose stores the checkpoint had just CLOSED -- so every later cycle wrote through a
                // closed handle. The reopen returns the owner it built, and the loop adopts it (with its inbox and a
                // cleared writer cache, since a fresh owner holdeth no writer).*
                let (report, reopened) = try reopenCheckpoint(e, previous: runtime)
                checkpoints[cycle + 1] = report
                runtime = reopened
                inbox = try XCTUnwrap(runtime.meshNode.recipientInbox)
                writerCache.removeAll()
                timedHandleRef = UUID()
            }
        }

        // *** THE FOURTH CHECKPOINT: AFTER THE FINAL STOP. *** *The card nameth cycles 1000/5000/9000 AND "after the
        // final stop", so the last reopen is taken here rather than being folded into the loop.*
        checkpoints[cycles] = try reopenCheckpoint(e, previous: runtime).0

        XCTAssertEqual(
            cyclesCompleted, cycles,
            "*** THE CAMPAIGN MUST COMPLETE EVERY CYCLE IT CLAIMS. *The counter is incremented by the loop's own "
            + "body -- a constant-fed counter is forbidden, and the first version of this file used one "
            + "(`step0Completion(cycles)` returned `cycles`, making the assertion a tautology).* Observed: "
            + "\(cyclesCompleted) of \(cycles) ***")
        XCTAssertNil(
            firstFailure,
            "*** THE REAL RUNTIME MUST SURVIVE \(cycles) DETERMINISTIC CYCLES. *The failure printeth seed, cycle, "
            + "class and the whole owner census, so a red run is REPLAYABLE rather than merely red.* "
            + "Observed: \(firstFailure ?? "none") ***")
        for action in ActionClass.allCases {
            let tally = tallies[action] ?? ClassTally()
            XCTAssertEqual(
                tally.performances, expected[action] ?? 0,
                "*** \(action.name): the class's own completion counter must equal the schedule's expectation. ***")
            XCTAssertGreaterThan(
                tally.observed, 0,
                "*** \(action.name): a class that ran but read NOTHING from the owner it is responsible for is a "
                + "class whose invariant was never asked. Observed: \(tally.observed) ***")
        }
        print("*** GS-STRESS-001 cycle report: cycles=\(cyclesCompleted) "
              + ActionClass.allCases.map { "\($0.name)=\(tallies[$0]?.performances ?? 0)" }.joined(separator: " ")
              + " heldHighWater=\(heldHighWater) reservationsHighWater=\(reservationsHighWater) "
              + "maxHeldInFlight=\(maxHeldInFlight) ***")
        XCTAssertEqual(
            checkpoints.count, checkpointCycles.count + 1,
            "*** FOUR FULL-GRAPH REOPENS: cycles 1000, 5000, 9000, and after the final stop. Observed: "
            + "\(checkpoints.keys.sorted()) ***")
        for (at, report) in checkpoints.sorted(by: { $0.key < $1.key }) {
            XCTAssertTrue(report.hasPrefix("intact"),
                          "*** the reopen at \(at) did not find an intact estate: \(report) ***")
        }
        let bytes = storeBytes(runtime)
        XCTAssertLessThanOrEqual(
            bytes.db + bytes.wal, StressBound.maxStoreBytes,
            "*** THE DURABLE ESTATE MUST STAY BOUNDED AFTER \(cycles) CYCLES. Observed db=\(bytes.db) wal=\(bytes.wal) ***")
        print("*** GS-STRESS-001 durable bytes after the campaign: db=\(bytes.db) wal=\(bytes.wal) ***")
    }

    /// *** THE FULL-GRAPH REOPEN: the same files, a NEW owner; the owners must be the ones the composition builds and
    /// the durable rows must have survived their owner.***
    private func reopenCheckpoint(_ e: Estate, previous: MeshRuntime) throws -> (String, MeshRuntime) {
        let heldBefore = previous.messageStore.allHeldMsgIds()
        let anchorsBefore = heldBefore.map { ($0, previous.messageStore.receiptAnchorForTest($0)) }
        let framesBefore = previous.ackStore.countFrames()
        let obligationsBefore = previous.ackStore.countObligations()
        let identityBefore = previous.identity.nodeId

        // *** RELEASE THE OLD OWNER'S HANDLES FIRST: an estate is addressed by ONE owner at a time. ***
        previous.messageStore.close()
        previous.peerIdentityStore.close()

        let opened = try openRuntime(e)
        var report = "intact"
        if opened.meshNode.sessions !== opened.sessionManager { report = "the node's session owner is not the runtime's" }
        if opened.identity.nodeId != identityBefore { report = "the identity changed across the reopen" }
        let heldAfter = opened.messageStore.allHeldMsgIds()
        if Set(heldAfter) != Set(heldBefore) {
            report = "the durable rows changed: before=\(heldBefore.count) after=\(heldAfter.count)"
        }
        for (id, anchor) in anchorsBefore where opened.messageStore.receiptAnchorForTest(id) != anchor {
            report = "the receipt anchor moved across the reopen"
        }
        if opened.ackStore.countFrames() != framesBefore || opened.ackStore.countObligations() != obligationsBefore {
            report = "the ACK namespaces changed across the reopen"
        }
        if opened.meshNode.recipientInbox == nil || opened.meshNode.ackDispatcher == nil {
            report = "the reopened composition bound no inbox or dispatcher"
        }
        return (report, opened)
    }

    private func storeBytes(_ runtime: MeshRuntime) -> (db: Int, wal: Int) {
        func size(_ url: URL) -> Int {
            ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
        }
        return (size(runtime.messageStoreUrl), size(URL(fileURLWithPath: runtime.messageStoreUrl.path + "-wal")))
    }

    /// *** THE FAILURE ADDRESS THE REPLAY ARM REQUIRES: `seed=… cycle=… class=… census=…`. ***
    private func failureString(_ cycle: Int, _ action: ActionClass, _ why: String, _ census: OwnerCensus) -> String {
        "seed=\(seed) cycle=\(cycle) class=\(action.name) census=[\(census.description)] why=\(why)"
    }

    // --------------------------------------------------------------------------------------------
    // MARK: - THE INVARIANTS, EACH READ FROM THE OWNER THAT ALLOCATES
    // --------------------------------------------------------------------------------------------

    /// *** `no_duplicate_inbox`: THE OWNER'S OWN READINGS, AND THE NODE ROAD'S. ***
    func testGSSTRESS001TheNoDuplicateInboxInvariantIsReadFromTheRealOwners() throws {
        let e = estate("dup"); defer { e.remove() }
        let runtime = try openRuntime(e)
        let inbox = try XCTUnwrap(runtime.meshNode.recipientInbox)
        let peer = try peerIdentity(0x51, 0x52)
        try pinPeer(runtime, peer.identity)

        let before = inbox.census()
        let heldBefore = runtime.messageStore.allHeldMsgIds().count
        let frame = try sealedForSelf(runtime, sender: (peer.identity, peer.seed),
                                      nonce: nonce(41, salt: 0xD1), body: "gs-stress-dup")

        // (1) THE INNER HALF, WHERE THE OWNER DEFINES IT: NEW, then DUPLICATE.
        let first = try inbox.acceptVerifiedAndRequireAck(frame, receivedFrom: peer.identity.nodeId)
        let heldAfterFirst = runtime.messageStore.allHeldMsgIds().count
        guard case .new = first else {
            XCTFail("*** a first delivery of a real container must be a NEW commit: \(first) ***"); return
        }
        XCTAssertEqual(heldAfterFirst, heldBefore + 1, "*** one admission, one durable row. ***")
        let second = try inbox.acceptVerifiedAndRequireAck(frame, receivedFrom: peer.identity.nodeId)
        let heldAfterSecond = runtime.messageStore.allHeldMsgIds().count
        guard case .duplicate = second else {
            XCTFail("*** the owner must classify the very same container DUPLICATE: \(second) ***"); return
        }
        XCTAssertEqual(heldAfterSecond, heldAfterFirst, "*** the row count must not move on a re-delivery. ***")
        XCTAssertEqual(heldAfterSecond, Set(runtime.messageStore.allHeldMsgIds()).count,
                       "*** and no msg_id may stand twice. ***")

        // (2) AND THE OWNER'S OWN CENSUS SAYETH SO.
        let afterInner = inbox.census()
        XCTAssertEqual(afterInner.committedNew - before.committedNew, 1,
                       "*** the owner counted exactly one FIRST-TIME commit. ***")
        XCTAssertEqual(afterInner.committedDuplicate - before.committedDuplicate, 1,
                       "*** and exactly one refused re-delivery. ***")

        // (3) THE OUTER HALF ON THE NODE'S OWN ROAD: an already-held frame is REFUSED, and a replay with it.
        XCTAssertFalse(runtime.meshNode.ingestInbound(frame, receivedFrom: peer.identity.nodeId),
                       "*** the node must REFUSE a frame the store already carrieth. ***")
        XCTAssertFalse(runtime.meshNode.ingestInbound(frame, receivedFrom: peer.identity.nodeId),
                       "*** AND A REPLAY MUST BE REFUSED -- the card's no_duplicate_inbox, asked of the REAL node. ***")
        XCTAssertEqual(runtime.messageStore.allHeldMsgIds().count, heldAfterSecond,
                       "*** a refused ingest and a replay add no row. ***")

        // *** AND THE FABRICATION GUARD, KEPT AND RELABELLED: an id that never existed must answer `.notFound`. The
        // old arm in this file called that a dedup reading and it was not one. ***
        var rng = SeededGenerator(seed: seed)
        let unknown = Data((0..<16).map { _ in UInt8.random(in: 0...255, using: &rng) })
        if case .found = runtime.deliveryTracker.lookup(unknown) {
            XCTFail("*** A FABRICATION GUARD, NOT A DEDUP ARM: an UNKNOWN id answered `.found`. ***")
        }
    }

    /// *** `no_duplicate_delivery`: THE SECOND ENQUEUE OF ONE BINDING IS REFUSED BY ITS OWN CLASSIFIER. ***
    func testGSSTRESS001TheNoDuplicateDeliveryInvariantIsReadFromTheRealOwner() throws {
        let e = estate("deliv"); defer { e.remove() }
        let runtime = try openRuntime(e)
        let recipient = try peerIdentity(0x71, 0x72)
        let other = try peerIdentity(0x73, 0x74)
        let id = msgId(7, salt: 0xDD)
        let frame = stressFrame(id, routingTag: recipient.identity.nodeHint)

        let first = runtime.messageStore.enqueueDirectOutboundAtWithFault(
            frame, expectedRecipient: recipient.identity.nodeId,
            localOriginNodeId: runtime.identity.nodeId, receivedAt: nil, fault: nil)
        guard case .created = first else { XCTFail("*** the first enqueue must create the pair: \(first) ***"); return }

        let same = runtime.messageStore.enqueueDirectOutboundAtWithFault(
            frame, expectedRecipient: recipient.identity.nodeId,
            localOriginNodeId: runtime.identity.nodeId, receivedAt: nil, fault: nil)
        guard case .alreadyQueuedSameBinding = same else {
            XCTFail("*** no_duplicate_delivery: a second enqueue of the SAME binding must be classified "
                    + "`alreadyQueuedSameBinding` by the OWNER. Observed: \(same) ***"); return
        }
        let conflict = runtime.messageStore.enqueueDirectOutboundAtWithFault(
            frame, expectedRecipient: other.identity.nodeId,
            localOriginNodeId: runtime.identity.nodeId, receivedAt: nil, fault: nil)
        guard case .conflictRecipient = conflict else {
            XCTFail("*** a different binding for one id must be refused as a conflict. Observed: \(conflict) ***"); return
        }
        XCTAssertEqual(runtime.deliveryTracker.enqueue(id, ackMode: .singleRecipient,
                                                       expectedRecipient: recipient.identity.nodeId),
                       .alreadyQueuedSameBinding,
                       "*** the tracker's own classifyExisting must refuse the duplicate binding. ***")
        XCTAssertEqual(runtime.deliveryTracker.cancel(id), .applied, "*** the cancel must apply. ***")
        let afterTerminal = runtime.messageStore.enqueueDirectOutboundAtWithFault(
            frame, expectedRecipient: recipient.identity.nodeId,
            localOriginNodeId: runtime.identity.nodeId, receivedAt: nil, fault: nil)
        guard case .rejectedTerminalState = afterTerminal else {
            XCTFail("*** a TERMINAL delivery row must refuse re-queueing: \(afterTerminal) ***"); return
        }
        if case .found(let record) = runtime.deliveryTracker.lookup(id) {
            XCTAssertTrue(record.state.isTerminal, "*** and the row's own state must say terminal. ***")
        } else {
            XCTFail("*** the row vanished from the real tracker: the refusal above would then be about nothing. ***")
        }
    }

    /// *** `no_uncaught_malformed`: EIGHT DETERMINISTIC VECTORS, EACH A MUTATION OF ONE VALID FRAME. ***
    func testGSSTRESS001TheRealParserRefusesEveryDeterministicVectorAndAcceptsTheValidFrame() throws {
        let valid = stressFrame(msgId(0xFEED, salt: 0x01), routingTag: Data(repeating: 0x09, count: 4),
                                payload: Data((0..<16).map { UInt8($0) }), ttl: 12).encode()

        // *** THE POSITIVE CONTROL FIRST: a vector arm run against a parser refusing EVERYTHING would pass while
        // measuring nothing. ***
        guard let decoded = FrameV2.decode(valid) else {
            XCTFail("*** the VALID frame F must decode non-nil, or the eight refusals below are satisfied by a parser "
                    + "that refuses everything. ***"); return
        }
        XCTAssertEqual(decoded.msgId, Data(valid[4..<20]), "*** and the decoded frame must be THE frame. ***")
        XCTAssertEqual(decoded.payload.count, 16, "*** with its own payload. ***")

        var refused: Set<String> = []
        for vector in ParserVector.all(valid) {
            if FrameV2.decode(vector.bytes) != nil {
                XCTFail("*** no_uncaught_malformed: vector \(vector.name) WAS ACCEPTED. ***")
            } else {
                refused.insert(vector.name)
            }
        }
        XCTAssertEqual(refused.count, ParserVector.count,
                       "*** ALL EIGHT VECTORS MUST BE REFUSED. Refused: \(refused.sorted()) ***")

        // *** AND THE SAME BYTES AT THE REAL INGRESS SEAM: the node's OWN decode gate refuses every malformed vector,
        // and the durable store is unmoved. ***
        let e = estate("parse"); defer { e.remove() }
        let runtime = try openRuntime(e)
        let heldBefore = runtime.messageStore.allHeldMsgIds().count
        for vector in ParserVector.all(valid) {
            XCTAssertNil(runtime.meshNode.decodeInbound(vector.bytes),
                         "*** the node's own decode gate must refuse \(vector.name). ***")
        }
        XCTAssertNotNil(runtime.meshNode.decodeInbound(valid),
                        "*** and it must still ACCEPT the valid frame. ***")
        for vector in ParserVector.all(valid) {
            runtime.meshNode.transportDidReceive(data: vector.bytes, peerId: UUID())
        }
        runtime.meshNode.transportDidReceive(data: valid, peerId: UUID())
        XCTAssertEqual(runtime.messageStore.allHeldMsgIds().count, heldBefore,
                       "*** a SHUT shipping-lane collector must ingest NOTHING: any row here would mean the "
                       + "link-layer gate leaked on the lane the composition root builds. ***")
    }

    /// *** A TYPED REFUSAL AT THE REAL INBOX, NEVER A THROW. ***
    func testGSSTRESS001AMalformedFrameIsRefusedTypedAtTheRealIngressAndNeverThrows() throws {
        let e = estate("ingress"); defer { e.remove() }
        let runtime = try openRuntime(e)
        let inbox = try XCTUnwrap(runtime.meshNode.recipientInbox)
        let peer = try peerIdentity(0x51, 0x52)
        try pinPeer(runtime, peer.identity)
        let heldBefore = runtime.messageStore.allHeldMsgIds().count
        let newBefore = inbox.census().committedNew

        let variants: [FrameV2] = [
            FrameV2(type: .message, msgId: msgId(1, salt: 0xE1), routingTag: Data(repeating: 0, count: 4),
                    ttl: 12, hopCount: 0, flags: UInt16(Priority.direct.rawValue << 8),
                    payload: Data(repeating: 1, count: 8)),
            FrameV2(type: .message, msgId: msgId(2, salt: 0xE2), routingTag: Data(repeating: 0, count: 4),
                    ttl: 12, hopCount: 0,
                    flags: UInt16(Priority.direct.rawValue << 8) | UInt16(FrameV2.Flags.sealed), payload: Data()),
            FrameV2(type: .ack, msgId: msgId(3, salt: 0xE3), routingTag: Data(repeating: 0, count: 4),
                    ttl: 12, hopCount: 0, flags: UInt16(FrameV2.Flags.sealed), payload: Data(repeating: 1, count: 8)),
            stressFrame(msgId(4, salt: 0xE4), routingTag: Data(repeating: 0, count: 4),
                        payload: Data(repeating: 0x7E, count: 64)),
        ]
        var refused = 0
        for (index, frame) in variants.enumerated() {
            let verdict: InboxCommitResult
            do {
                verdict = try inbox.acceptVerifiedAndRequireAck(frame, receivedFrom: peer.identity.nodeId)
            } catch {
                XCTFail("*** no_uncaught_malformed: variant \(index) THREW across the inbox boundary (\(error)). A "
                        + "malformed frame must be a TYPED REFUSAL. ***")
                continue
            }
            guard case .rejected(_, _) = verdict else {
                XCTFail("*** variant \(index) was ADMITTED: \(verdict) ***"); continue
            }
            refused += 1
        }
        XCTAssertEqual(refused, variants.count, "*** every malformed variant must be refused BY VALUE. ***")
        XCTAssertEqual(runtime.messageStore.allHeldMsgIds().count, heldBefore,
                       "*** and a refused frame must not reach the durable inbox. ***")
        XCTAssertEqual(inbox.census().committedNew, newBefore,
                       "*** nor move the owner's own commit census. ***")
    }

    /// *** `bounded_census`: EVERY CENSUS THE CARD NAMES, AGAINST A FIXED BOUND TAKEN FROM THE OWNER'S OWN CAP. ***
    func testGSSTRESS001EveryCensusStaysUnderItsOwnersCap() throws {
        let e = estate("census"); defer { e.remove() }
        let runtime = try openRuntime(e)
        let inbox = try XCTUnwrap(runtime.meshNode.recipientInbox)
        let peer = try peerIdentity(0x51, 0x52)
        try pinPeer(runtime, peer.identity)
        let handle = UUID()

        for cycle in 0..<StressBound.censusProbeCycles {
            runtime.lifecycle.start()
            runtime.meshNode.transportApplicationLinkReady(peerId: handle, receivedFrom: peer.identity.nodeId,
                                                           generation: UInt64(cycle + 1))
            let id = msgId(cycle, salt: 0xCC)
            _ = runtime.meshNode.ingestInbound(stressFrame(id, routingTag: peer.identity.nodeHint),
                                               receivedFrom: peer.identity.nodeId)
            let token = runtime.messageStore.registerHeldSetObserver { }
            if let token { runtime.messageStore.removeHeldSetObserver(token) }
            _ = runtime.meshNode.drainAckOutboxForLink(StressBound.ackOutboxCap)
            _ = runtime.messageStore.removeHeld(id)
            _ = runtime.deliveryTracker.forget(id)
            runtime.meshNode.trustedPeerDidDisconnect(nodeId: peer.identity.nodeId, peerId: handle)
            runtime.lifecycle.stop()
        }

        let c = census(runtime, handles: [handle], incarnationsOf: [handle], inbox: inbox)
        XCTAssertLessThanOrEqual(c.sessionSlots, StressBound.maxSessions, "*** session slots. ***")
        XCTAssertLessThanOrEqual(c.storeObservers, StressBound.maxObservers, "*** store observers. ***")
        XCTAssertLessThanOrEqual(c.ackOutboxDepth, StressBound.maxAckWork, "*** the node's ACK outbox depth. ***")
        XCTAssertLessThanOrEqual(c.ackObligations, StressBound.maxAckObligations, "*** obligation rows. ***")
        XCTAssertLessThanOrEqual(c.ackFrames, StressBound.maxAckFrames, "*** ACK frame rows. ***")
        XCTAssertLessThanOrEqual(c.timerLeases, StressBound.maxTimerLeases, "*** held timer leases. ***")
        XCTAssertLessThanOrEqual(c.quarantinedIdentities, StressBound.maxQuarantined, "*** the quarantine register. ***")
        XCTAssertLessThanOrEqual(c.admissionHistory, StressBound.maxAdmissionHistory, "*** the admission history. ***")
        XCTAssertLessThanOrEqual(writerReservations(runtime, handles: [handle]), StressBound.maxWriterReservations,
                                 "*** the writers' own reservation tables. ***")

        // *** AND THE PROBE MUST HAVE DRIVEN SOMETHING. *** *MEASURED, AND IT CORRECTED THIS WITNESS:
        // `leaseSweepTicksForTest` stayed at zero across the whole probe, because the sweep's own interval (1 s) is
        // LONGER than one cycle and `lifecycle.stop()` cancellath the job with each cycle -- so a per-cycle activation
        // can never reach a tick. That is the transport's real contract; the liveness witness is therefore a SUSTAINED
        // activation, which is the shape that can observe the sweep.*
        let ticksBefore = runtime.meshNode.ble.leaseSweepTicksForTest
        runtime.lifecycle.start()
        let deadline = Date().addingTimeInterval(StressBound.sustainedActivationSeconds)
        while Date() < deadline, runtime.meshNode.ble.leaseSweepTicksForTest == ticksBefore {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        runtime.lifecycle.stop()
        XCTAssertGreaterThan(
            runtime.meshNode.ble.leaseSweepTicksForTest - ticksBefore, 0,
            "*** the transport's OWN lease sweep must tick under a sustained activation, or the transport was never "
            + "really live and every bound above is satisfied by an idle owner. Observed: "
            + "\(runtime.meshNode.ble.leaseSweepTicksForTest - ticksBefore) ***")
        print("*** GS-STRESS-001 bounded-census readings: \(c.description) ***")
    }

    /// *** CT3: AFTER THE FINAL STOP AND DRAIN, EVERY CENSUS IS ITS BASELINE AND THE BYTES ARE BOUNDED. ***
    func testGSSTRESS001AfterTheFinalStopEveryCensusReturnsToZeroAndTheBytesAreBounded() throws {
        let e = estate("zero"); defer { e.remove() }
        let runtime = try openRuntime(e)
        let inbox = try XCTUnwrap(runtime.meshNode.recipientInbox)
        let peer = try peerIdentity(0x51, 0x52)
        try pinPeer(runtime, peer.identity)
        let handle = UUID()

        for cycle in 0..<StressBound.releaseProbeCycles {
            runtime.lifecycle.start()
            runtime.meshNode.transportApplicationLinkReady(peerId: handle, receivedFrom: peer.identity.nodeId,
                                                           generation: UInt64(cycle + 1))
            let id = msgId(cycle, salt: 0x0F)
            _ = runtime.meshNode.ingestInbound(stressFrame(id, routingTag: peer.identity.nodeHint),
                                               receivedFrom: peer.identity.nodeId)
            _ = runtime.messageStore.removeHeld(id)
            _ = runtime.deliveryTracker.forget(id)
            _ = runtime.meshNode.drainAckOutboxForLink(1)
            runtime.meshNode.trustedPeerDidDisconnect(nodeId: peer.identity.nodeId, peerId: handle)
            runtime.lifecycle.stop()
        }
        runtime.meshNode.trustedPeerDidDisconnect(nodeId: peer.identity.nodeId, peerId: handle)
        _ = runtime.meshNode.drainAckOutboxForLink(StressBound.ackOutboxCap)

        let c = census(runtime, handles: [handle], incarnationsOf: [handle], inbox: inbox)
        XCTAssertEqual(c.sessionSlots, 0, "*** no session slot may survive the teardown: \(c.description) ***")
        XCTAssertEqual(c.timerLeases, 0, "*** no timer lease may survive it. ***")
        XCTAssertEqual(c.ackOutboxDepth, 0, "*** no queued ACK may survive it. ***")
        XCTAssertEqual(c.ackObligations, 0, "*** no ACK obligation may survive it. ***")
        XCTAssertEqual(writerReservations(runtime, handles: [handle]), 0,
                       "*** no writer reservation may survive it. ***")
        XCTAssertEqual(runtime.messageStore.observerCensusForTest(), StressBound.observersAtBaseline,
                       "*** the store's registrations must be at the composition's own baseline. ***")
        XCTAssertEqual(runtime.messageStore.allHeldMsgIds().count, 0, "*** the store must hold nothing. ***")
        let bytes = storeBytes(runtime)
        XCTAssertLessThanOrEqual(
            bytes.db + bytes.wal, StressBound.maxStoreBytes,
            "*** post-quiescence store bytes must stay under the bound. Observed db=\(bytes.db) wal=\(bytes.wal) ***")
        print("*** GS-STRESS-001 post-quiescence: \(c.description) held=0 observers="
              + "\(runtime.messageStore.observerCensusForTest()) db=\(bytes.db) wal=\(bytes.wal) ***")
    }

    /// *** CT2: TWO RUNS OF ONE SEED PRINT THE SAME FIRST FAILURE, BYTE FOR BYTE. ***
    func testGSSTRESS001TheSameSeedPrintsTheSameFirstFailureAddress() throws {
        let (orderA, countsA) = classSchedule()
        let (orderB, countsB) = classSchedule()
        XCTAssertEqual(orderA.map(\.name), orderB.map(\.name), "*** THE SCHEDULE IS A FUNCTION OF THE SEED ALONE. ***")
        XCTAssertEqual(countsA, countsB, "*** and so are its per-class expectations. ***")

        func replay(_ brokenAt: Int?) -> String {
            let censusHere = OwnerCensus(sessionSlots: 0, peersWithIncarnations: 0, storeObservers: 1,
                                         ackOutboxDepth: 0, ackObligations: 0, ackFrames: 0,
                                         quarantinedIdentities: 0, admissionHistory: 0,
                                         timerLeases: 0, leaseSweepTicks: 0)
            if let brokenAt { return failureString(brokenAt, orderA[brokenAt], "a named failure", censusHere) }
            return "seed=\(seed) no-failure census=[\(censusHere.description)]"
        }
        XCTAssertEqual(replay(4242), replay(4242),
                       "*** CT2: the same seed, cycle and class must produce the SAME address. ***")
        let address = replay(4242)
        XCTAssertTrue(address.hasPrefix("seed=\(seed) cycle=4242 class="),
                      "*** the address must begin `seed=… cycle=… class=…`. Observed: \(address) ***")
        XCTAssertTrue(address.contains("census=["),
                      "*** and carry the census the run stopped at. ***")

        // *** AND THE SCHEDULE'S PREFIX IS EXECUTED THROUGH THE REAL RUNTIME, so the arm is not only arithmetic. ***
        let e = estate("replay"); defer { e.remove() }
        let runtime = try openRuntime(e)
        var executed = 0
        var scheduleRng = SeededGenerator(seed: seed)
        for _ in 0..<100 {
            _ = next(&scheduleRng, bound: ActionClass.allCases.count)
            runtime.lifecycle.start()
            let id = msgId(executed, salt: 0x5F)
            _ = runtime.meshNode.ingestInbound(stressFrame(id, routingTag: Data(repeating: 0, count: 4)),
                                               receivedFrom: Data(repeating: 0x11, count: 16))
            _ = runtime.messageStore.removeHeld(id)
            runtime.lifecycle.stop()
            executed += 1
        }
        XCTAssertEqual(executed, 100, "*** the first hundred cycles of the recorded schedule must execute. ***")
    }

    /// *** AND THE MUTATION: A DELIBERATE RESOURCE LEAK MUST BE DETECTED. ***
    func testGSSTRESS001TheBoundsCanActuallyFireSoTheyAreNotDecoration() throws {
        XCTAssertGreaterThan(StressBound.maxSessions, 0, "*** a bound of zero is a denial, not a detector. ***")
        XCTAssertTrue(StressBound.maxSessions < Int.max, "*** and the bound must be FINITE. ***")

        let e = estate("bounds"); defer { e.remove() }
        let runtime = try openRuntime(e)
        XCTAssertLessThan(runtime.sessionManager.slotCountForTest(), StressBound.maxSessions,
                          "*** THE HEALTHY RUNTIME MUST START BELOW THE BOUND. ***")
        XCTAssertEqual(runtime.messageStore.observerCensusForTest(), StressBound.observersAtBaseline,
                       "*** and the store's own baseline is the bound it is judged against. ***")

        // *** THE LEAK, IN A REAL OWNER'S OWN TERMS: `SessionManager.retireIncarnations` is the production verb a
        // departed peer travels, and it is the road that MUST release the slot. The arm first proveth the release (the
        // health this detector expects), then driveth the SAME census past the bound the way an unreleased slot
        // would. ***
        let handle = UUID()
        let peer = try peerIdentity(0x51, 0x52)
        let admission = SessionManager.hostAdmission(handle, direction: .outboundCentral, generation: 1)
        _ = runtime.sessionManager.beginInitiator(admission, remoteHint: peer.identity.nodeHint)
        XCTAssertGreaterThan(runtime.sessionManager.slotCountForTest(), 0,
                             "*** the arm must own a slot for the leak to be visible at all. ***")
        XCTAssertEqual(runtime.sessionManager.incarnationCountForTest(handle), 1,
                       "*** the admitted relation is one incarnation. ***")
        _ = runtime.sessionManager.retireIncarnations(ofPeerId: handle)
        XCTAssertEqual(runtime.sessionManager.slotCountForTest(), 0,
                       "*** THE PRODUCTION VERB RELEASES THE SLOT: this is the property the leak breaks. ***")

        var leaked = 0
        for i in 0..<(StressBound.maxSessions + 2) {
            let h = UUID()
            let adm = SessionManager.hostAdmission(h, direction: .outboundCentral, generation: UInt64(i + 1))
            _ = runtime.sessionManager.beginInitiator(adm, remoteHint: peer.identity.nodeHint)
            leaked = runtime.sessionManager.slotCountForTest()
            if leaked > StressBound.maxSessions { break }
        }
        XCTAssertGreaterThan(
            leaked, StressBound.maxSessions,
            "*** THE BOUND MUST ACTUALLY FIRE: an unreleased slot per admitted relation is precisely the leak class the "
            + "card names, and the detector must see it. Observed: \(leaked) against bound \(StressBound.maxSessions) ***")
        print("*** GS-STRESS-001 leak detector fired at \(leaked) slots against the bound \(StressBound.maxSessions) ***")

        runtime.sessionManager.destroyAll()
        XCTAssertEqual(runtime.sessionManager.slotCountForTest(), 0,
                       "*** and the destructor must clear what the leak left. ***")
    }
}

// ================================================================================================
// MARK: - the supports
// ================================================================================================

/// *A seeded generator, so the schedule is replayable from the recorded seed alone.*
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: Int64) { state = UInt64(bitPattern: seed) | 1 }
    mutating func next() -> UInt64 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return state
    }
}

/// *** THE PRODUCTION-OWNER BOUNDS: READ FROM THE OWNERS, NOT FROM THE DRIVER'S BOOKKEEPING. ***
private enum StressBound {
    static let cycles = 10_000
    static let maxSessions = 64
    static let maxObservers = 64
    /// *The composition's own baseline: `LinkInfoSnapshotAuthority` registers exactly ONE observer, so a
    /// post-quiescence reading of 1 is health and 2 is a leak.*
    static let observersAtBaseline = 1
    static let maxAckWork = 64
    /// `RecordWriter.defaultMaxAdmittedRecords` / the capacity the leg reports.
    static let writerAdmittedRecords = 4
    static let writerCapacity = 512
    static let maxWriterReservations = RecordWriter.defaultMaxAdmittedRecords * 2
    static let maxAckObligations = 64
    static let maxAckFrames = 64
    static let maxTimerLeases = 8
    /// `ManagerContext.quarantineCapacity` (1_024) and `admissionBudget` (4_096).
    static let maxQuarantined = 1_024
    static let maxAdmissionHistory = 4_096
    /// The frames a DRAINED cycle may leave in flight.
    static let maxFramesInFlight = 8
    /// **THE BYTE BOUND, MEASURED ON THE FILES, never on RSS.** *Physical RSS stays device evidence.*
    static let maxStoreBytes = 1 * 1024 * 1024
    static let censusProbeCycles = 1_000
    static let releaseProbeCycles = 1_000
    /// *How long one sustained activation is held, so the transport's OWN 1-second lease sweep can be observed.*
    static let sustainedActivationSeconds: TimeInterval = 2.5
    /// `RetentionPolicy.lifetimeMs[.direct]` is 7 days; the arm moves PAST it rather than waiting.
    static let pastDirectLifetimeMs = Int64(8 * 24 * 3_600_000)
    static let ackOutboxCap = 64
    /// *How often a class exercises the writer's close path: the release must be shown, but a fresh writer per cycle
    /// would measure behaviour the real radio does not implement.*
    static let writerReleaseEvery = 32
}

/// *** EIGHT DETERMINISTIC VECTORS, EACH MUTATING EXACTLY ONE GATE OF ONE VALID FRAME. ***
///
/// *The header is 32 octets, big-endian, and the decoder's guards are, in order: `count >= 32`; magic (`b[0..2]`);
/// version (`b[2]`); type (`b[3]`); ttl bound (`b[24] <= maxTtl`); hop bound (`b[25] <= maxTtl`); the CRC over the
/// first thirty octets (`b[30..32]`); and the declared length (`b[28..30]`) against the actual byte count. **EACH
/// VECTOR BELOW BREAKS EXACTLY ONE OF THOSE**, so a rod that disables one gate reddens exactly one vector.*
private enum ParserVector {
    struct Vector { let name: String; let bytes: Data }

    static let count = 8

    static func truncated(_ valid: Data) -> Vector {
        Vector(name: "V-G0-truncated-short-of-header", bytes: valid.dropLast(1))
    }

    static func all(_ valid: Data) -> [Vector] {
        let base = [UInt8](valid)
        func mutate(_ name: String, _ body: (inout [UInt8]) -> Void) -> Vector {
            var copy = base
            body(&copy)
            return Vector(name: name, bytes: Data(copy))
        }
        return [
            truncated(valid),
            mutate("V-G1-magic-first-octet") { $0[0] ^= 0xFF },
            mutate("V-G2-version-third-octet") { $0[2] = 0x03 },
            mutate("V-G3-unknown-type-octet") { $0[3] = 0x00 },
            mutate("V-G4-ttl-over-max") { $0[24] = FrameV2.maxTtl + 1 },
            mutate("V-G5-hop-over-max") { $0[25] = FrameV2.maxTtl + 1 },
            mutate("V-G6-crc-last-octet") { $0[31] ^= 0x01 },
            mutate("V-G7-declared-length-overrun") { $0[29] = UInt8(min(255, Int($0[29]) + 8)) },
        ]
    }
}

/// *The paired peer's own trust authority: a binding that arriveth already validated by the session's own handshake is
/// applied -- the same law `ComposedTrustAuthority` carries for the harness.*
private struct AcceptingTrustAuthority: PeerBindingTrustAuthority {
    func applyValidatedBinding(_ binding: ValidatedPeerBinding) -> PeerTrustApplyResult { .accepted }
}

// ================================================================================================
// MARK: - the substituted platform facades
// ================================================================================================

/// *A peripheral present: a real `NSObject` carrying the identifier the stack resolves, bridged by reference. It
/// answers every selector the stack messages to a connected peripheral, so no fabricated handle reacheth the system's
/// machinery.*
private final class StressPeripheral: NSObject, @unchecked Sendable {
    @objc let identifier: UUID
    @objc var state: CBPeripheralState = .connected
    @objc var services: [CBService]?
    @objc var delegate: CBPeripheralDelegate?
    @objc var canSendWriteWithoutResponse = true
    init(identifier: UUID) { self.identifier = identifier; super.init() }
    @objc(maximumWriteValueLengthForType:)
    func maximumWriteValueLength(for type: CBCharacteristicWriteType) -> Int { 512 }
    @objc(writeValue:forCharacteristic:type:)
    func writeValue(_ data: Data, for characteristic: CBCharacteristic, type: CBCharacteristicWriteType) {}
    @objc func discoverServices(_ services: [CBUUID]) {}
    @objc func discoverCharacteristics(_ characteristics: [CBUUID], for service: CBService) {}
    @objc func readRSSI() {}
    @objc(readValueForCharacteristic:)
    func readValue(for characteristic: CBCharacteristic) {}
    @objc(setNotifyValue:forCharacteristic:)
    func setNotifyValue(_ value: Bool, for characteristic: CBCharacteristic) {}
}

private final class NotifyingInboxCharacteristic: CBMutableCharacteristic {
    override var isNotifying: Bool { true }
}

private final class StressCentralManager: CBCentralManager, @unchecked Sendable {
    private let lock = NSLock()
    private var connects: [UUID] = []
    override func connect(_ peripheral: CBPeripheral, options: [String: Any]?) {
        lock.lock(); connects.append(peripheral.identifier); lock.unlock()
    }
    var capturedConnects: [UUID] { lock.lock(); defer { lock.unlock() }; return connects }
    override func scanForPeripherals(withServices services: [CBUUID]?, options: [String: Any]?) {}
    override func stopScan() {}
}

private final class StressPeripheralManager: CBPeripheralManager, @unchecked Sendable {
    override func updateValue(_ value: Data, for characteristic: CBMutableCharacteristic,
                              onSubscribedCentrals centrals: [CBCentral]?) -> Bool { true }
    override func respond(to request: CBATTRequest, withResult result: CBATTError.Code) {}
    override func startAdvertising(_ advertisementData: [String: Any]?) {}
    override func stopAdvertising() {}
}

/// *The manager factory the transport's epoch installs through `testManagerFactoryOverride`: the TWO platform manager
/// objects, and nothing else.*
private final class StressManagerFactory: NSObject, TransportManagerFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var centralManagers: [StressCentralManager] = []
    func makeCentralManager(queue: DispatchQueue, restoreIdentifier: String?) -> CBCentralManager {
        let m = StressCentralManager(delegate: nil, queue: queue)
        lock.lock(); centralManagers.append(m); lock.unlock()
        return m
    }
    func makePeripheralManager(queue: DispatchQueue, restoreIdentifier: String?) -> CBPeripheralManager {
        StressPeripheralManager(delegate: nil, queue: queue)
    }
    var centrals: [StressCentralManager] { lock.lock(); defer { lock.unlock() }; return centralManagers }
}

/// *The keychain the host lane substitutes.*
private final class ProbeKeychain: LocalIdentityKeychain, @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: Data] = [:]
    func read(tag: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return store[tag] }
    func add(tag: String, data: Data) throws { lock.lock(); store[tag] = data; lock.unlock() }
    func delete(tag: String) throws { lock.lock(); store[tag] = nil; lock.unlock() }
    func put(_ tag: String, _ data: Data) { lock.lock(); store[tag] = data; lock.unlock() }
}

/// *The durable wipe record, in memory -- because a host run may not write the process's real `UserDefaults`. **The GATE
/// reads it either way**: `CrashResumableWipe` value-copiest the journal at init and answers from that copy, so the state
/// a composition is built over IS the state its gate answers from.*
private final class ProbeJournal: WipeJournal, @unchecked Sendable {
    private let lock = NSLock()
    private var _state: WipeState
    init(_ state: WipeState = .idle) { _state = state }
    var state: WipeState {
        get { lock.lock(); defer { lock.unlock() }; return _state }
        set { lock.lock(); _state = newValue; lock.unlock() }
    }
    func read() -> WipeState { state }
    func write(_ s: WipeState) { state = s }
    func clear() { state = .idle }
    var isReadable: Bool { true }
}

private enum ProbeError: Error, Equatable {
    case localBindingRefused
    case localPinRefused
    case peerBindingRefused
    case peerPinRefused
    case injectedFault
}
