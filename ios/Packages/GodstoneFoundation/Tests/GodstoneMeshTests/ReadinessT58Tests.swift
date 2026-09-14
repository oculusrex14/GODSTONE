// T58 readiness court (iOS isle) -- the message and SOS journeys.
//
// The twin of T57's court, with the SAME fixture values and the SAME vocabulary,
// plus the iOS-specific laws: background/foreground, a locked device, a scene
// discard, VoiceOver hold/cancel, and an incoming duplicate.
//
// The model is driven against a DETERMINISTIC authority that projects statuses the
// way the durable repository would: an ATT acceptance is ATTEMPTING, and only an
// authenticated recipient ACK is DELIVERED. That is what letteth the card's named
// semantic negative -- a coordinator UI reset that hideth remaining work -- be
// EXECUTED rather than argued.
//
// No device behaviour is claimed; the physical matrix stays external (T73-T75).
import XCTest
@testable import GodstoneMesh

// -------------------------- the SHARED fixtures (both isles) ----------------
//
// The same values appear in T57's court as well, and W13 asserteth that they still
// do: one set of journey fixtures, two isles.
private enum SharedJourneyFixture {
    static let peerSeed: UInt8 = 0x11
    static let bodyAscii400 = String(repeating: "a", count: 400)
    static let cjkCharacter = "\u{6c34}"
    static let sosBody = "SOS"

    static func nodeId(_ seed: UInt8) -> Data {
        Data((0..<16).map { UInt8((Int($0) + Int(seed)) & 0xFF) })
    }
}

/// The durable authority's SEMANTICS, faithfully mirrored.
private final class AuthorityDouble: MeshAuthorityPort, @unchecked Sendable {
    final class Row {
        let msgId: Data
        let peerLabel: String
        let body: String
        var status: MessageStatus
        let outgoing: Bool
        var retryable: Bool
        var note: String?
        init(msgId: Data, peerLabel: String, body: String, status: MessageStatus,
             outgoing: Bool, retryable: Bool, note: String? = nil) {
            self.msgId = msgId; self.peerLabel = peerLabel; self.body = body
            self.status = status; self.outgoing = outgoing; self.retryable = retryable
            self.note = note
        }
    }

    var rows: [Row] = []
    var link: LinkState = .offline
    var contactList: [RecipientProjection] = []
    var storageFails = false
    var relayCopiesMayBeOut = false
    var activeSosRow: Row?
    var sends = 0
    var calls = 0

    @discardableResult
    func seedRecipient(_ seed: UInt8, _ label: String, _ trust: ContactTrustLabel) -> RecipientProjection {
        let projection = RecipientProjection(nodeId: SharedJourneyFixture.nodeId(seed),
                                             label: label, trust: trust)
        contactList.append(projection)
        return projection
    }

    /// A link acceptance: what an ATT Boolean proveth, and nothing more.
    func transportAccepted(_ msgId: Data) {
        rows.first { $0.msgId == msgId }?.status = .attempting
        rows.first { $0.msgId == msgId }?.note = "a link took the bytes; no recipient answered yet"
    }

    /// The intended recipient's AUTHENTICATED ACK: the only delivery road.
    func recipientAcked(_ msgId: Data) {
        rows.first { $0.msgId == msgId }?.status = .delivered
        rows.first { $0.msgId == msgId }?.retryable = false
        rows.first { $0.msgId == msgId }?.note = nil
    }

    /// An INBOUND duplicate: the same msgId arriving twice is ONE row.
    func inboundDuplicate(_ msgId: Data, label: String, body: String) {
        if rows.contains(where: { $0.msgId == msgId }) { return }
        rows.append(Row(msgId: msgId, peerLabel: label, body: body, status: .delivered,
                        outgoing: false, retryable: false))
    }

    func linkState() -> LinkState { link }

    func recipients() -> [RecipientProjection] { contactList }

    func messages() -> [MessageProjection] {
        rows.map {
            MessageProjection(msgId: $0.msgId, peerLabel: $0.peerLabel, body: $0.body,
                              status: $0.status, outgoing: $0.outgoing,
                              retryable: $0.retryable, authorityNote: $0.note)
        }
    }

    func activeSos() -> SosProjection? {
        activeSosRow.map { SosProjection(msgId: $0.msgId, status: $0.status,
                                        relayCopiesMayBeOut: relayCopiesMayBeOut) }
    }

    func sendDirect(recipientNodeId: Data, body: String) -> SendOutcome {
        sends += 1
        if storageFails { return .refused("the store refused the row") }
        let msgId = Data((0..<16).map { UInt8((Int($0) + sends + 0x10) & 0xFF) })
        let label = contactList.first { $0.nodeId == recipientNodeId }?.label ?? "unknown"
        rows.append(Row(msgId: msgId, peerLabel: label, body: body, status: .queued,
                        outgoing: true, retryable: true))
        return .queued(msgId)
    }

    func retry(msgId: Data) -> RetryOutcome {
        guard let row = rows.first(where: { $0.msgId == msgId }) else {
            return .refused("no such row")
        }
        if storageFails { return .refused("the store refused the retry") }
        if !row.retryable { return .refused("terminal state") }
        return .accepted(msgId)
    }

    func beginSos(body: String) -> SosOutcome {
        calls += 1
        if storageFails { return .refused("the store refused the call") }
        if activeSosRow != nil { return .refused("a call is already active") }
        let msgId = Data((0..<16).map { UInt8((Int($0) + calls + 0x40) & 0xFF) })
        let row = Row(msgId: msgId, peerLabel: "broadcast", body: body, status: .queued,
                      outgoing: true, retryable: true, note: "queued on this phone")
        rows.append(row)
        activeSosRow = row
        return .enqueued(msgId)
    }

    func cancelSos(msgId: Data) -> SosOutcome {
        guard let row = activeSosRow else { return .refused("no active call") }
        if row.msgId != msgId { return .refused("no such active call") }
        if row.status == .cancelled { return .alreadyCancelled(relayCopiesMayBeOut: relayCopiesMayBeOut) }
        row.status = .cancelled
        row.retryable = false
        activeSosRow = nil
        return .cancelled(relayCopiesMayBeOut: relayCopiesMayBeOut)
    }
}

// ------------------------------- the court ---------------------------------

@MainActor
final class ReadinessT58Tests: XCTestCase {
    private func model(_ authority: AuthorityDouble,
                       protected: ProtectedDataGate = AlwaysAvailableProtectedData(),
                       recipients: [Data]) -> MeshUXModel {
        let built = MeshUXModel(authority: authority, protectedData: protected)
        built.knownRecipientIdsProvider = { recipients }
        _ = built.refresh()
        return built
    }

    private func selectAndDraft(_ model: MeshUXModel, _ recipient: RecipientProjection,
                                _ body: String) {
        _ = model.onCommand(.selectRecipient(recipient.nodeId))
        _ = model.onCommand(.draft(body))
    }

    // ------------------------------------------------------------ W01

    /// W01 -- the whole journey: offline -> a peer appears -> an ACK delivers.
    func testW01OfflineThenAPeerThenTheAck() {
        let authority = AuthorityDouble()
        let peer = authority.seedRecipient(SharedJourneyFixture.peerSeed, "Aunt", .verified)
        let built = model(authority, recipients: [peer.nodeId])

        // 1. OFFLINE: queued, and the screen sayeth so in words
        let offline = built.refresh()
        XCTAssertEqual(offline.link, .offline)
        XCTAssertTrue((offline.link.explanation ?? "").contains("queued"))
        selectAndDraft(built, peer, "the bridge is out")
        XCTAssertTrue(built.uiState().canSend)
        let sent = built.onCommand(.sendDirect)
        XCTAssertEqual(sent.messages.first?.status, .queued)
        guard let sentRow = sent.messages.first else {
            return XCTFail("the send must have queued a row")
        }
        XCTAssertFalse(sentRow.status.claimsDelivery)
        // THE WORDS are the interface: queued is never "sent"
        XCTAssertTrue(voiceLabel(for: .queued).contains("queued"))
        XCTAssertFalse(voiceLabel(for: .queued).contains("sent"))
        XCTAssertNotEqual(voiceLabel(for: .attempting), voiceLabel(for: .delivered))
        XCTAssertTrue((sent.lastOutcome ?? "").contains("queued"))
        XCTAssertFalse((sent.lastOutcome ?? "").contains("sent"))

        // 2. A PEER APPEARS: the link is up and NOTHING is delivered
        authority.link = .connected(peers: 1)
        let connected = built.refresh()
        XCTAssertEqual(connected.link, .connected(peers: 1))
        XCTAssertNil(connected.link.explanation, "an up link needeth no explanation")
        XCTAssertEqual(connected.messages.first?.status, .queued)

        // 3. the radio takes the bytes: ATTEMPTING, no delivery claim
        authority.transportAccepted(sentRow.msgId)
        let attempting = built.refresh()
        XCTAssertEqual(attempting.messages.first?.status, .attempting)
        guard let attemptingRow = attempting.messages.first else {
            return XCTFail("the row must stand")
        }
        XCTAssertFalse(attemptingRow.status.claimsDelivery)

        // 4. the recipient's ACK commits: NOW, and only now
        authority.recipientAcked(sentRow.msgId)
        let delivered = built.refresh()
        XCTAssertEqual(delivered.messages.first?.status, .delivered)
        guard let deliveredRow = delivered.messages.first else {
            return XCTFail("the row must stand")
        }
        XCTAssertTrue(deliveredRow.status.claimsDelivery)
        XCTAssertTrue(voiceLabel(for: .delivered).contains("delivered"))
    }

    // ------------------------------------------------------------ W02

    /// W02 -- THE NAMED NEGATIVE: only resetting the coordinator UI on cancel
    /// hideth remaining work. A scene changeover and a relaunch must both show it.
    func testW02RemainingWorkSurvivethASceneChangeoverAndARelaunch() {
        let authority = AuthorityDouble()
        let peer = authority.seedRecipient(0x12, "Brother", .verified)
        let built = model(authority, recipients: [peer.nodeId])
        selectAndDraft(built, peer, "meet me at the hall")
        let sent = built.onCommand(.sendDirect)
        guard let sentMessage = sent.messages.first else {
            return XCTFail("the send must have queued a row")
        }
        let msgId = sentMessage.msgId
        authority.transportAccepted(msgId)
        XCTAssertEqual(built.refresh().messages.count, 1, "the work standeth")

        // a BACKGROUND/FOREGROUND cycle must not reset it
        _ = built.scenePhaseChanged(.background)
        let backgrounded = built.uiState()
        XCTAssertEqual(backgrounded.scenePhase, .background)
        XCTAssertEqual(backgrounded.messages.count, 1,
                       "remaining work must stay visible in the background")
        _ = built.scenePhaseChanged(.active)
        let foregrounded = built.uiState()
        XCTAssertEqual(foregrounded.scenePhase, .active)
        XCTAssertEqual(1, foregrounded.messages.count, "and after returning")
        XCTAssertEqual(.attempting, foregrounded.messages.first?.status)

        // A SCENE DISCARD: a fresh model over the same authority
        let discarded = model(authority, recipients: [peer.nodeId])
        XCTAssertEqual(discarded.uiState().messages.count, 1,
                       "a discarded scene must re-expose the remaining work")
        XCTAssertEqual(.attempting, discarded.uiState().messages.first?.status)
        // and the words sayeth it is NOT delivered
        XCTAssertFalse(discarded.uiState().messages.first?.status.claimsDelivery ?? false,
                       "and the words sayeth it is NOT delivered")
    }

    // ------------------------------------------------------------ W03

    /// W03 -- a LOCKED device claimeth nothing, and no gesture is half-applied.
    func testW03ALockedDeviceClaimethNothing() {
        let authority = AuthorityDouble()
        let peer = authority.seedRecipient(0x13, "Chemist", .verified)
        let gate = SwitchableProtectedData(available: true)
        let built = model(authority, protected: gate, recipients: [peer.nodeId])
        selectAndDraft(built, peer, "do you have insulin")
        _ = built.onCommand(.sendDirect)
        XCTAssertEqual(1, built.uiState().messages.count)

        gate.setAvailable(false)
        let locked = built.refresh()
        assertEqualsLocked(locked)

        // a mutating command while locked is refused BY THE LOCK
        let refused = built.onCommand(.sendDirect)
        XCTAssertTrue((refused.error ?? "").contains("locked"),
                      "a locked send is refused by the lock: \(refused.error ?? "")")
        XCTAssertEqual(1, authority.rows.count, "and no second row was created")

        // a DRAFT may still be typed while locked (it is not a secret claim)
        _ = built.onCommand(.draft("still here"))
        XCTAssertEqual(built.uiState().draft, "still here")

        // after unlock the real estate reappeareth
        gate.setAvailable(true)
        let unlocked = built.refresh()
        XCTAssertTrue(unlocked.isAvailable)
        XCTAssertEqual(1, unlocked.messages.count)
        XCTAssertNotNil(unlocked.selectedRecipient)
    }

    private func assertEqualsLocked(_ state: MeshUIState) {
        XCTAssertEqual(state.availability, .protectedDataUnavailable)
        XCTAssertTrue(state.messages.isEmpty, "not even a cached message is claimed")
        XCTAssertTrue(state.recipients.isEmpty, "nor a cached recipient")
        // the user's CHOICE surviveth (they may keep typing), but its TRUST claim
        // does not: no secure chip may stand behind a lock screen
        if let selection = state.selectedRecipient {
            XCTAssertEqual(selection.trust, .unknown,
                           "a locked store carrieth no trust verdict")
            XCTAssertFalse(state.isSecure, "nothing is secure while the store is unreadable")
        }
        XCTAssertNil(state.sos)
    }

    // ------------------------------------------------------------ W04

    /// W04 -- an INCOMING DUPLICATE is one row, and it is delivered (the peer's
    /// own copy arrived), never queued and never counted twice.
    func testW04AnIncomingDuplicateIsOneRow() {
        let authority = AuthorityDouble()
        let peer = authority.seedRecipient(0x14, "Warden", .verified)
        let built = model(authority, recipients: [peer.nodeId])
        let inbound = Data((0..<16).map { UInt8(($0 + 0x77) & 0xFF) })
        authority.inboundDuplicate(inbound, label: "Warden", body: "are you safe")
        authority.inboundDuplicate(inbound, label: "Warden", body: "are you safe")
        let state = built.refresh()
        XCTAssertEqual(1, state.messages.count, "a duplicate arrival is ONE row")
        XCTAssertEqual(.delivered, state.messages.first?.status)
        XCTAssertEqual(state.messages.first?.outgoing, false, "and it is inbound")
        XCTAssertEqual(state.messages.count, 1,
                       "and the VoiceOver summary counteth it once")
        XCTAssertTrue(state.voiceSummary().contains("1 messages"))
    }

    // ------------------------------------------------------------ W05

    /// W05 -- VoiceOver hold/cancel: the control's hints and labels say what it is.
    func testW05VoiceOverHoldAndCancelAreSpoken() {
        XCTAssertTrue(SosAccessibility.idleHint.contains("Hold"))
        XCTAssertTrue(SosAccessibility.armedHint.contains("Confirm"))
        XCTAssertTrue(SosAccessibility.activeHint.contains("Cancel"))
        XCTAssertNotEqual(SosAccessibility.idleHint, SosAccessibility.armedHint)
        XCTAssertTrue(SosAccessibility.cancelLabel.contains("Cancel"))
        XCTAssertTrue(SosAccessibility.confirmLabel.contains("Confirm"))

        let authority = AuthorityDouble()
        let built = model(authority, recipients: [])
        let idle = built.uiState().voiceSummary()
        XCTAssertFalse(idle.contains("active call"))

        _ = built.onCommand(.armSos)
        XCTAssertTrue(built.uiState().voiceSummary().contains("held"),
                      "an armed control is spoken: \(built.uiState().voiceSummary())")
        _ = built.onCommand(.confirmSos)
        let active = built.uiState().voiceSummary()
        XCTAssertTrue(active.contains("active call"), active)

        // every status speaketh a distinct form
        let spoken = MessageStatus.allCases.map { voiceLabel(for: $0) }
        XCTAssertEqual(Set(spoken).count, MessageStatus.allCases.count)
    }

    // ------------------------------------------------------------ W06

    /// W06 -- the compose bound is 400 UTF-8 BYTES on this isle too.
    func testW06TheComposeBoundIsBytesNotCharacters() {
        XCTAssertEqual(400, DirectComposePolicy.maxBodyBytes)
        XCTAssertTrue(DirectComposePolicy.fits(SharedJourneyFixture.bodyAscii400))
        XCTAssertFalse(DirectComposePolicy.fits(String(repeating: "a", count: 401)))
        let cjk = String(repeating: SharedJourneyFixture.cjkCharacter, count: 200)
        XCTAssertEqual(200, cjk.count)
        XCTAssertEqual(600, DirectComposePolicy.byteCount(cjk))
        XCTAssertFalse(DirectComposePolicy.fits(cjk), "the bound is BYTES")

        let authority = AuthorityDouble()
        let peer = authority.seedRecipient(0x15, "Sister", .verified)
        let built = model(authority, recipients: [peer.nodeId])
        selectAndDraft(built, peer, cjk)
        XCTAssertTrue((built.uiState().error ?? "").contains("600 bytes"),
                      built.uiState().error ?? "")
        XCTAssertFalse(built.uiState().canSend)

        let truncated = DirectComposePolicy.truncateToFit(cjk)
        XCTAssertTrue(DirectComposePolicy.fits(truncated))
        XCTAssertEqual(133, truncated.count, "whole characters only")
        XCTAssertEqual(truncated, String(truncated), "the cut is on a CHARACTER boundary")
    }

    // ------------------------------------------------------------ W07

    /// W07 -- the SOS control is HELD, and a bare confirm placeth nothing.
    func testW07TheSosControlRequirethAnArm() {
        let authority = AuthorityDouble()
        let built = model(authority, recipients: [])

        let bare = built.onCommand(.confirmSos)
        XCTAssertNotNil(bare.error)
        XCTAssertTrue((bare.error ?? "").contains("hold"))
        XCTAssertEqual(0, authority.calls, "NO call was placed")
        XCTAssertNil(bare.sos)

        _ = built.onCommand(.armSos)
        XCTAssertTrue(built.uiState().sosArmed)
        let placed = built.onCommand(.confirmSos)
        XCTAssertEqual(1, authority.calls)
        XCTAssertNotNil(placed.sos)
        XCTAssertEqual(.queued, placed.sos?.status)

        _ = built.onCommand(.disarmSos)
        XCTAssertFalse(built.uiState().sosArmed)
        XCTAssertEqual(1, authority.calls)
    }

    // ------------------------------------------------------------ W08

    /// W08 -- cancel nameth the relayed-copy limitation, in the SCREEN's words.
    func testW08CancelNamethTheRelayedCopyLimitation() {
        let quiet = AuthorityDouble()
        let first = model(quiet, recipients: [])
        _ = first.onCommand(.armSos)
        let placed = first.onCommand(.confirmSos)
        XCTAssertTrue((first.uiState().sos?.cancelExplanation ?? "").contains("No copy has left"))
        guard let placedCall = placed.sos else { return XCTFail("a call must stand") }
        let cancelled = first.onCommand(.cancelSos(placedCall.msgId))
        XCTAssertTrue((cancelled.lastOutcome ?? "").contains("no copy had left"))
        XCTAssertNil(cancelled.sos)

        let loud = AuthorityDouble()
        loud.relayCopiesMayBeOut = true
        let second = model(loud, recipients: [])
        _ = second.onCommand(.armSos)
        let placed2 = second.onCommand(.confirmSos)
        XCTAssertTrue((second.uiState().sos?.cancelExplanation ?? "").contains("cannot be recalled"),
                      second.uiState().sos?.cancelExplanation ?? "")
        guard let placedCall2 = placed2.sos else { return XCTFail("a call must stand") }
        let cancelled2 = second.onCommand(.cancelSos(placedCall2.msgId))
        XCTAssertTrue((cancelled2.lastOutcome ?? "").contains("cannot be recalled"))
        XCTAssertFalse((cancelled2.lastOutcome ?? "").contains("recalled successfully"))
    }

    // ------------------------------------------------------------ W09

    /// W09 -- a relaunch restoreth the active call and is NOT armed.
    func testW09ARelaunchRestorethTheActiveCall() {
        let authority = AuthorityDouble()
        let first = model(authority, recipients: [])
        _ = first.onCommand(.armSos)
        let placed = first.onCommand(.confirmSos)
        XCTAssertNotNil(placed.sos)

        let relaunched = model(authority, recipients: [])
        let beforeRestore = relaunched.refresh()
        XCTAssertNotNil(beforeRestore.sos, "the durable row re-exposeth the call unasked")
        XCTAssertEqual(placed.sos?.msgId, beforeRestore.sos?.msgId)
        XCTAssertFalse(beforeRestore.sosArmed, "and the fresh model is NOT armed")

        let restored = relaunched.onCommand(.restoreActiveSos)
        XCTAssertTrue((restored.lastOutcome ?? "").contains("restored"))
        XCTAssertNotNil(restored.sos)
    }

    // ------------------------------------------------------------ W10

    /// W10 -- a denied permission is EXPLAINED, and the message is still kept.
    func testW10ADeniedPermissionIsExplained() {
        let authority = AuthorityDouble()
        let peer = authority.seedRecipient(0x16, "Doctor", .verified)
        let built = model(authority, recipients: [peer.nodeId])
        authority.link = .permissionDenied
        selectAndDraft(built, peer, "the surgery is closed")

        let state = built.refresh()
        let words = state.link.explanation
        XCTAssertNotNil(words, "a denied permission is EXPLAINED")
        XCTAssertTrue((words ?? "").contains("permission"))
        XCTAssertTrue((words ?? "").contains("Settings"))
        XCTAssertTrue((words ?? "").contains("queued"))
        _ = built.onCommand(.sendDirect)
        XCTAssertEqual(built.uiState().messages.first?.status, .queued,
                       "the message is still queued locally")
    }

    // ------------------------------------------------------------ W11

    /// W11 -- an unsupported radio is explained DISTINCTLY, and nothing is secure.
    func testW11AnUnsupportedRadioIsExplainedDistinctly() {
        let authority = AuthorityDouble()
        let tofu = authority.seedRecipient(0x17, "Neighbour", .tofuUnverified)
        let built = model(authority, recipients: [tofu.nodeId])
        authority.link = .unsupported
        let unsupported = built.refresh().link.explanation
        XCTAssertNotNil(unsupported)
        XCTAssertTrue((unsupported ?? "").contains("Bluetooth"))
        XCTAssertTrue((unsupported ?? "").contains("stay queued"))

        authority.link = .permissionDenied
        let denied = built.refresh().link.explanation
        XCTAssertNotEqual(unsupported, denied,
                          "a denial and an unsupported radio are not the same problem")

        // and a link that is UP is still not security for a merely pinned peer
        authority.link = .connected(peers: 2)
        selectAndDraft(built, tofu, "hello")
        let pinned = built.uiState()
        XCTAssertFalse(pinned.isSecure, "a link that is up is NOT security")
        XCTAssertTrue(pinned.securitySummary.contains("pinned on first use"))

        authority.contactList = [RecipientProjection(nodeId: tofu.nodeId, label: "Neighbour",
                                                   trust: .verified)]
        XCTAssertTrue(built.refresh().isSecure, "a confirmed key IS security")
    }

    // ------------------------------------------------------------ W12

    /// W12 -- failed storage leaveth the estate AND the user's text intact.
    func testW12FailedStorageLeavethTheEstateAndTheDraft() {
        let authority = AuthorityDouble()
        let peer = authority.seedRecipient(0x18, "Ferryman", .verified)
        let built = model(authority, recipients: [peer.nodeId])
        selectAndDraft(built, peer, "across the water?")
        let before = built.uiState().messages.count
        authority.storageFails = true

        let refused = built.onCommand(.sendDirect)
        XCTAssertTrue((refused.error ?? "").contains("store refused"), refused.error ?? "")
        XCTAssertEqual(before, authority.rows.count, "no durable row was created")
        XCTAssertEqual(before, refused.messages.count, "and the projected list is unchanged")
        XCTAssertEqual("across the water?", refused.draft, "the user's text is NOT thrown away")
    }

    // ------------------------------------------------------------ W13

    /// W13 -- SHARED fixtures and the durable vocabulary: the two isles speak ONE
    /// set of journey semantics, asserted from the Android court's own source.
    func testW13TheIslesShareTheirJourneyFixtures() throws {
        var repo = URL(fileURLWithPath: #filePath)
        var hops = 0
        while repo.path != "/" && hops < 12 {
            if FileManager.default.fileExists(atPath: repo.appendingPathComponent("android").path) { break }
            repo.deleteLastPathComponent(); hops += 1
        }
        let androidCourt = try String(contentsOf: repo.appendingPathComponent(
            "android/app/src/test/java/io/godstone/app/readiness/ReadinessT57Test.kt"),
            encoding: .utf8)
        for fixture in ["400", "0x11", "600"] {
            XCTAssertTrue(androidCourt.contains(fixture), "the Android fixtures carrieth \(fixture)")
        }
        // the ONE vocabulary, both isles
        for status in ["QUEUED", "ATTEMPTING", "DELIVERED", "CANCELLED", "EXPIRED", "FAILED"] {
            XCTAssertTrue(MessageStatus.allCases.contains { $0.rawValue == status },
                          "this isle must speak \(status)")
            XCTAssertTrue(androidCourt.contains(status), "and so must the Android fixtures")
        }
        // and the words this isle renders carrieth no "Sent" for an ATT acceptance
        let source = try String(contentsOf: repo.appendingPathComponent(
            "ios/Godstone/Sources/GodstoneMesh/MeshUXModel.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("no answer yet"), "the ATT words say there is no answer")
        // the WORDS the surface renders are asserted, not the source text: a scan
        // cannot tell a comment from a rendering, and this is the law that mattereth
        let rendered = MessageStatus.allCases.map { voiceLabel(for: $0) }.joined(separator: " | ")
        XCTAssertFalse(rendered.contains("Sent"), "the word Sent is never rendered: \(rendered)")
        XCTAssertFalse(rendered.contains("Delivered") && rendered.contains("no answer yet")
                        && voiceLabel(for: .attempting).contains("Delivered"),
                       "the ATT words never claim a delivery")
    }
}
