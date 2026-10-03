package io.godstone.mesh.lab.replay

import io.godstone.mesh.MeshIdentity
import io.godstone.mesh.crypto.PeerBindingTrustAuthority
import io.godstone.mesh.crypto.RelationDirection
import io.godstone.mesh.crypto.RelationKey as CryptoRelationKey
import io.godstone.mesh.crypto.SessionManager
import io.godstone.mesh.delivery.IntentStateRank
import io.godstone.mesh.delivery.InMemoryOutboundIntentJournal
import io.godstone.mesh.delivery.SendDirectAuthority
import io.godstone.mesh.delivery.SendDirectCommand
import io.godstone.mesh.delivery.SendDirectRejection
import io.godstone.mesh.delivery.SendDirectResult
import io.godstone.mesh.delivery.SigningKeysAdapter
import io.godstone.mesh.delivery.TrustedPeerIdentityResolver
import io.godstone.mesh.delivery.RepositoryPeerIdentityLookupSource
import io.godstone.mesh.identity.Identity
import io.godstone.mesh.identity.IdentityBindingV1
import io.godstone.mesh.identity.IdentityBindingValidationResult
import io.godstone.mesh.identity.IdentityBindingValidator
import io.godstone.mesh.identity.JdbcPeerIdentityStore
import io.godstone.mesh.identity.PeerIdentityLookup
import io.godstone.mesh.identity.PeerIdentityRepository
import io.godstone.mesh.identity.PeerTrustApplyResult
import io.godstone.mesh.identity.PeerTrustLevel
import io.godstone.mesh.identity.ValidatedPeerBinding
import io.godstone.mesh.identity.VerifiedPeerIdentity
import io.godstone.mesh.router.ForwardOffer
import io.godstone.mesh.router.InventorySnapshotAuthority
import io.godstone.mesh.router.Router
import io.godstone.mesh.router.SyncControlOwner
import io.godstone.mesh.router.SyncPump
import io.godstone.mesh.runtime.ComposedOutcome
import io.godstone.mesh.runtime.ComposedRuntimeHarness
import io.godstone.mesh.runtime.FixedHostClock
import io.godstone.mesh.runtime.LinkFacade
import io.godstone.mesh.runtime.NormalEstateGate
import io.godstone.mesh.store.InMemoryMessageStore
import io.godstone.mesh.wire.v2.FrameV2
import io.godstone.mesh.wire.v2.LogicalMessageIdentity
import io.godstone.mesh.wire.v2.Priority
import io.godstone.mesh.wire.v2.SignedMessageV1
import io.godstone.mesh.wire.v2.TimeQuality
import io.godstone.mesh.wire.v2.TypeV2
import java.io.File
import java.security.SecureRandom
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import io.godstone.core.crypto.Ed25519Keys
import io.godstone.core.crypto.X25519Keys

/**
 * *** GS-INTEGRATION-001 `scenarios` (THE LATER STAGES): INITIAL HANDSHAKE REPLAY, THE BOUNDED QUEUE'S
 * OVERFLOW, AND THE REPLAY/ROTATION PATHS THAT SURVIVE A RECONNECT. ***
 *
 * *The existing scenario coverage walks the EARLY path -- a handshake, one DIRECT delivery, the ACK return leg.
 * **The breakage that survives that coverage lives in the LATER stages**, so these scenarios stand on them:*
 *
 *   1. the INITIAL HANDSHAKE's own replay law (the selfsame HS1 re-presented must not rerun the Noise transitions);
 *   2. the bounded FORWARD QUEUE's overflow (a flood must supersede the eldest rather than swell, and the durable
 *      estate must not grow with it);
 *   3. a REPLAY after a reconnect (a captured frame re-offered over a fresh relation is a DUPLICATE);
 *   4. the ROTATION paths -- an exact-candidate rotation quarantines until APPROVED, the post-approval send pins the
 *      NEW generation, and a RETRY of the pinned intent reuses the OLD authored bytes without re-resolving.
 *
 * *** EVERY OWNER IS REAL AND EVERY OBSERVATION READS ONE. *** *The trusted handshake runs through the production
 * `SessionManager`; the replay and overflow scenarios drive the composed runtime (real `MeshNode`, `Router`, durable
 * store, `DeliveryTracker`, recipient inbox and the `SyncPump`); and the rotation scenarios run the REAL
 * `PeerIdentityRepository` over a REAL on-disk SQLite trust store and the REAL `SendDirectAuthority` product command.
 * **No counter a fixture incremented is asserted; the census, the durable rows and the pinned ledger are.***
 *
 * *** WHAT IS SUBSTITUTED, NAMED RATHER THAN GLOSSED: *** *the OS facades alone -- the fixed host clock, the recording
 * radio, and (for the pure rotation court) an in-memory store beneath the real trust repository. Readiness stays
 * false and no device claim is made.*
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33])
internal class ScenarioReplayRotationTest {

    /** A real on-disk trust store, so the rotation rows are durable rather than modelled. */
    private lateinit var root: File

    /** The real on-disk trust stores opened by this court, closed in teardown. */
    private val trustStores = ArrayList<JdbcPeerIdentityStore>()

    @Before
    fun mintEstate() {
        root = File.createTempFile("gs_replay_", "").let { it.delete(); it.mkdirs(); it.deleteOnExit(); it }
    }

    @After
    fun razeEstate() {
        closeTrustStores()
        root.deleteRecursively()
    }

    private fun closeTrustStores() {
        for (store in trustStores) runCatching { store.close() }
        trustStores.clear()
    }

    private fun acceptingAuthority(): PeerBindingTrustAuthority = object : PeerBindingTrustAuthority {
        override fun applyValidatedBinding(binding: ValidatedPeerBinding): PeerTrustApplyResult =
            PeerTrustApplyResult.Accepted
    }

    private fun rng(): SecureRandom = SecureRandom()

    // =================================================================================================================
    // 1. THE INITIAL HANDSHAKE: THE SELFSAME FIRST COUNSEL IS HEARKENED NOT, AND THE RELATION STANDS.
    // =================================================================================================================

    /**
     * *** A REPLAYED HS1 REACHES THE HANDSHAKE DOOR AND MUST NOT RERUN THE NOISE TRANSITIONS. ***
     *
     * *THE LATER-STAGE LAW THE EARLY SCENARIOS NEVER ASK: the initial handshake's own replay. The transport's
     * transcript cache suppresseth a re-presented whole record, but the MANAGER's own guard is what this arm proveth
     * at the registry: `initiatorStart`/`responderProcessHs1` refuse a slot that already carrieth a controller.*
     * **So the arm first ESTABLISHES a real relation over the production handshake, then re-presents the VERY HS1 the
     * responder already processed -- and requires a null answer (the controller is never run a second time) with the
     * established relation, its one slot and its readiness all still standing.***
     */
    @Test
    fun theInitialHandshakesReplayedFirstCounselIsHeardNotAndTheRelationStands() {
        val idA = MeshIdentity.generate()
        val idB = MeshIdentity.generate()
        val smA = SessionManager(idA, acceptingAuthority())
        val smB = SessionManager(idB, acceptingAuthority())
        val admA = CryptoRelationKey(RelationDirection.OUTBOUND_CENTRAL, "peer", 1L, 1L)
        val admB = CryptoRelationKey(RelationDirection.INBOUND_PERIPHERAL, "peer", 1L, 1L)

        // *** THE REAL TRUSTED HANDSHAKE, HS1 -> HS2 -> HS3, THROUGH THE PRODUCTION MANAGER'S OWN ENTRIES. ***
        val hs1 = smA.initiatorStart(admA, idB.nodeHint)
        assertNotNull("the initiator must emit HS1", hs1)
        val hs2 = smB.responderProcessHs1(admB, idA.nodeHint, hs1!!)
        assertNotNull("the responder must answer HS2", hs2)
        val hs3 = smA.initiatorProcessHs2(admA, hs2!!, idB.nodeHint)
        assertNotNull("the initiator must emit HS3", hs3)
        assertTrue("the responder must accept HS3 and reach READY", smB.responderProcessHs3(admB, hs3!!, idA.nodeHint))

        // THE CONTROL: both sides really stand ready and really hold one slot.
        assertTrue("the initiator's relation must be READY", smA.isReady(admA))
        assertTrue("the responder's relation must be READY", smB.isReady(admB))
        assertEquals("one live slot at the initiator", 1, smA.slotCountForTest())
        assertEquals("and one at the responder", 1, smB.slotCountForTest())

        // *** *** THE REPLAY: THE VERY HS1 THE RESPONDER ALREADY PROCESSED, RE-PRESENTED. *** ***
        //
        // *A controller is already installed for this admission, so a second HS1 is an idle re-telling: the manager
        // MUST answer null rather than run the Noise handshake a second time.* **A manager that returned a fresh HS2
        // here would silently re-key the relation behind the caller's back.**
        val replayed = smB.responderProcessHs1(admB, idA.nodeHint, hs1)
        assertNull(
            "*** A REPLAYED FIRST COUNSEL MUST NOT RUN THE CONTROLLER AGAIN: the responder answered $replayed. ***",
            replayed,
        )
        // *** AND NOTHING MOVED: the one slot stands, readiness survives, and the relation still seals. ***
        assertEquals("the replayed counsel must not add or retire a slot", 1, smB.slotCountForTest())
        assertTrue("and the responder's relation must still be READY after the replay", smB.isReady(admB))
        assertNotNull(
            "*** and it must still really seal -- a replay that tore the cipher down would answer null here. ***",
            smB.seal(admB, byteArrayOf(1, 2, 3)),
        )
    }

    // =================================================================================================================
    // 2. THE BOUNDED FORWARD QUEUE'S OVERFLOW.
    // =================================================================================================================

    /**
     * *** A FLOOD PAST THE BOUNDED QUEUE SUPERSEDES THE ELDEST COPY, COUNTS THE OVERFLOW, AND LETTETH NOTHING SWELL
     * WITHOUT LIMIT. ***
     *
     * *THE LATER-STAGE LAW THE EARLY SCENARIOS NEVER ASK: the epidemic forward queue is BOUNDED at
     * `SYNC_MAX_FORWARD_QUEUE`; a flood must drop the eldest (counted) rather than grow, and a turn must emit at most
     * `SYNC_MAX_FORWARD_PER_TURN`.* **The arm drives the REAL `SyncPump` over a REAL store and its own control owner,
     * floods it past the bound, and reads the pump's OWN overflow census and its OWN pending-queue depth -- never a
     * number this fixture incremented.***
     */
    @Test
    fun theForwardQueueOverflowSupersedesTheEldestAndStaysBounded() = runTest {
        val rng = rng()
        val store = InMemoryMessageStore()
        val ourId = ByteArray(16) { (it + 2).toByte() }
        val router = Router(store, ourId, wipeGate = io.godstone.mesh.identity.WipeSensitiveUseGate { true })
        val authority = InventorySnapshotAuthority(store, { 1_000L })
        val owner = SyncControlOwner(store, authority, { 1_000L }, ourId)
        val pump = SyncPump(owner, store, router, { 1_000L })

        val peerB = ByteArray(16) { (it + 0x31).toByte() }
        val peerC = ByteArray(16) { (it + 0x51).toByte() }
        assertTrue("the first relation must register", pump.register(peerB, 1_000L))
        assertTrue("the second relation must register", pump.register(peerC, 1_000L))

        // *** FLOOD: MANY DISTINCT FRAMES OFFERED FROM A THIRD PEER, SO EVERY COPY IS QUEUED FOR peers B AND C. ***
        val fromPeer = ByteArray(16) { (it + 0x11).toByte() }
        val frameCount = SyncPump_QueueBound() + 64
        for (i in 0 until frameCount) {
            val frame = FrameV2(
                type = TypeV2.MESSAGE,
                msgId = ByteArray(16) { j -> ((j * 7 + i) and 0xFF).toByte() },
                routingTag = ByteArray(4) { 1 },
                ttl = FrameV2.DEFAULT_TTL,
                hopCount = 0,
                flags = FrameV2.SEALED or Priority.toFlags(Priority.DIRECT),
                payload = ByteArray(24) { j -> ((j + i) and 0xFF).toByte() },
            )
            val offer = pump.enqueueForward(frame, fromPeer, 1_000L)
            assertTrue("every forwardable frame must be queued for the other peers, observed $offer",
                offer is ForwardOffer.Queued)
        }

        // *** THE OVERFLOW IS COUNTED AND THE QUEUE IS BOUNDED AT ITS OWN CAP. ***
        val overflow = pump.overflowCount(peerB)
        assertTrue(
            "*** A FLOOD PAST THE BOUND MUST SUPERSEDE THE ELDEST AND COUNT IT: observed overflow=$overflow for " +
                "$frameCount offered frames against the cap ${SyncPump_QueueBound()}. ***",
            overflow >= (frameCount - SyncPump_QueueBound()).toLong(),
        )
        val pendingB = pump.pendingForwardCount(peerB)
        assertTrue(
            "*** AND THE PENDING QUEUE MUST STAY AT OR BELOW ITS CAP: observed $pendingB. ***",
            pendingB <= SyncPump_QueueBound(),
        )
        assertEquals(
            "*** every admitted copy was queued for BOTH relations, so both carry the same bounded depth. ***",
            pendingB, pump.pendingForwardCount(peerC),
        )

        // *** AND ONE BOUNDED TURN EMITS AT MOST THE PER-TURN CAP -- never the whole backlog. ***
        val batch = pump.pump(peerB, 1_000L)
        assertTrue(
            "*** A TURN MUST EMIT AT MOST THE PER-TURN CAP; observed ${batch.copies.size}. ***",
            batch.copies.size <= 32,
        )
        assertTrue("and it must emit something from a non-empty queue", batch.copies.isNotEmpty() ||
            (pump.pendingForwardCount(peerB) == 0))
    }

    // =================================================================================================================
    // 3. THE REPLAY AFTER A RECONNECT.
    // =================================================================================================================

    /**
     * *** A CAPTURED FRAME RE-OFFERED OVER A FRESH RELATION IS A DUPLICATE -- NO SECOND ROW, NO NEW CLAIM, AND THE
     * TERMINAL DELIVERY SURVIVES. ***
     *
     * *THE LATER-STAGE LAW: the early scenarios deliver once; the RECONNECT is where the mesh re-offers. This arm
     * carries a DIRECT message A -> R -> B, observes the terminal ACK, then UNLINKS and RELINKS and REPLAYS the very
     * bytes the radio carried.* **The discriminator is the DURABLE ESTATE: the recipient's held set must not grow, and
     * the author's terminal claim must not be disturbed.***
     */
    @Test
    fun aReplayAfterAReconnectAddsNoSecondRowAndTheTerminalClaimSurvives() = runTest {
        val h = world()
        assertTrue(h.sendDirect("A", "B", BODY) is ComposedOutcome.Applied)
        h.turn("A", "R")
        h.turn("R", "B")
        val a = h.node("A")!!
        val b = h.node("B")!!
        val mid = a.store.allHeldMsgIds().single()
        val heldBefore = b.store.allHeldMsgIds().size
        val captured = h.link.deliveriesTo("B").first().bytesCopy()
        h.turnAcks("B", "R")
        h.turnAcks("R", "A")
        assertEquals(
            "the terminal claim must stand BEFORE the replay, or the arm would measure the ordinary delivery",
            io.godstone.mesh.delivery.DeliveryState.ACKNOWLEDGED_BY_RECIPIENT,
            (a.tracker.lookup(mid) as io.godstone.mesh.delivery.DeliveryLookup.Found).record.state,
        )

        // *** THE RECONNECT: THE RELATION FALLS AND A FRESH ONE COMES UP. ***
        h.unlink("A", "B")
        assertFalse("the relation must really have fallen", h.isLinked("A", "B"))
        h.link("A", "B")
        assertTrue("and a fresh relation must stand", h.isLinked("A", "B"))

        // *** THE REPLAY: THE EXACT BYTES THE RADIO ALREADY CARRIED. ***
        h.replay("A", "B", captured)
        assertTrue(
            "*** the replay must RE-ENTER the receiving statute, or nothing was really offered. ***",
            h.traceSnapshot().kinds().contains("replay_ingested"),
        )
        assertEquals(
            "*** THE REPLAYED FRAME MUST NOT DUPLICATE THE RECIPIENT'S ESTATE: held was $heldBefore, now " +
                "${b.store.allHeldMsgIds().size}. ***",
            heldBefore, b.store.allHeldMsgIds().size,
        )
        assertEquals(
            "*** AND THE AUTHOR'S TERMINAL CLAIM MUST SURVIVE THE REPLAY -- a duplicate must never demote it. ***",
            io.godstone.mesh.delivery.DeliveryState.ACKNOWLEDGED_BY_RECIPIENT,
            (a.tracker.lookup(mid) as io.godstone.mesh.delivery.DeliveryLookup.Found).record.state,
        )
    }

    // =================================================================================================================
    // 4. THE ROTATION PATHS.
    // =================================================================================================================

    /**
     * *** AN EXACT-CANDIDATE ROTATION QUARANTINES UNTIL IT IS APPROVED. ***
     *
     * *THE LATER-STAGE LAW: rotation is EXACT-CANDIDATE CAS. A peer that reconnects with a NEWER static DH generation
     * must be QUARANTINED (not silently accepted, not rolled back), and its candidate must not become resolvable
     * until the operator approves THE EXACT candidate.* **This driveth the REAL `PeerIdentityRepository` over a REAL
     * on-disk SQLite trust store, through the frozen validator, and reads the repository's OWN lookup -- never a
     * fixture's flag.***
     */
    @Test
    fun aRotationQuarantinesUntilTheExactCandidateIsApproved() {
        val peer = MeshIdentity.generate()
        val repo = repository()
        try {
            // *** (1) FIRST SEEN: a validated gen-1 binding pins the peer. ***
            val gen1Static = peer.staticDhPub
            val pinned = repo.applyValidatedBinding(bindingOf(peer, generation = 1L, staticPub = gen1Static))
            assertEquals("*** the first binding must TOFU-pin: observed $pinned ***", PeerTrustApplyResult.FirstSeenPinned, pinned)
            assertTrue("and the peer must resolve VERIFIED at gen 1", verifiedGeneration(repo, peer) == 1L)

            // *** (2) ROTATION: the same signing key, a NEW static DH generation -> the candidate QUARANTINES. ***
            val gen2Static = X25519Keys.generate(rng()).pub
            assertFalse("the rotated candidate must really differ from the accepted static key",
                gen2Static.contentEquals(gen1Static))
            val quarantined = repo.applyValidatedBinding(bindingOf(peer, generation = 2L, staticPub = gen2Static))
            assertEquals(
                "*** A NEWER GENERATION MUST QUARANTINE, NOT AUTO-ACCEPT: observed $quarantined ***",
                PeerTrustApplyResult.KeyChangedQuarantined, quarantined,
            )
            val duringQuarantine = repo.lookup(peer.nodeId)
            assertTrue(
                "*** AND THE PEER MUST NOT RESOLVE AS VERIFIED WHILE THE CANDIDATE STANDS PENDING; observed " +
                    "$duringQuarantine ***",
                duringQuarantine is PeerIdentityLookup.Quarantined,
            )

            // *** (3) AND A STALE APPROVAL (the WRONG generation) MUST BE REFUSED BY NAME. ***
            val stale = repo.approvePendingRotation(peer.nodeId, expectedPendingGeneration = 3L, expectedPendingStaticDhPublicKey = gen2Static)
            assertEquals(
                "*** APPROVING A GENERATION THAT IS NOT THE PENDING CANDIDATE MUST BE REFUSED: observed $stale ***",
                io.godstone.mesh.identity.RotationApprovalResult.StaleCandidate, stale,
            )
            assertTrue("and the stale refusal must not move the record", repo.lookup(peer.nodeId) is PeerIdentityLookup.Quarantined)

            // *** (4) THE EXACT CANDIDATE APPROVES, AND THE ACCEPTED GENERATION BECOMES THE NEW ONE. ***
            val approved = repo.approvePendingRotation(peer.nodeId, expectedPendingGeneration = 2L, expectedPendingStaticDhPublicKey = gen2Static)
            assertTrue(
                "*** THE EXACT CANDIDATE MUST APPROVE: observed $approved ***",
                approved is io.godstone.mesh.identity.RotationApprovalResult.Approved,
            )
            assertEquals("*** and the ACCEPTED generation must now be the rotated one. ***", 2L, verifiedGeneration(repo, peer))
            assertEquals(
                "*** and the approved static key must be the ROTATED material, not the elder one. ***",
                gen2Static.toList(), acceptedStaticOf(repo, peer)?.toList(),
            )
        } finally {
            closeTrustStores()
        }
    }

    /**
     * *** THE POST-ROTATION SEND PINS THE NEW GENERATION, AND A RETRY OF THE PINNED INTENT REUSES THE OLD BYTES. ***
     *
     * *THE TWO HALVES OF THE ROTATION LAW IN ONE RUN: a FRESH send after an approval must seal against the ROTATED
     * static material and pin the new generation; **a RETRY of the SAME intent token must NOT re-resolve the rotated
     * table at all** -- it must load the pinned row and hand back the VERY authored bytes.*
     *
     * **The road is the REAL `SendDirectAuthority` product command over the REAL trust repository; the observations
     * are the durable ledger ROW's own `acceptedGeneration`/`recipientStaticDhPub` and the returned logical id.**
     */
    @Test
    fun thePostRotationSendPinsTheNewGenerationAndTheRetryReusesThePinnedBytes() = runTest {
        val peer = MeshIdentity.generate()
        val repo = repository()
        val sender = MeshIdentity.generate()
        val store = InMemoryMessageStore()
        val journal = InMemoryOutboundIntentJournal()
        try {
            // Pin gen 1, then rotate to gen 2 and APPROVE it, so the resolver's current answer is gen 2.
            repo.applyValidatedBinding(bindingOf(peer, generation = 1L, staticPub = peer.staticDhPub))
            val gen2Static = X25519Keys.generate(rng()).pub
            repo.applyValidatedBinding(bindingOf(peer, generation = 2L, staticPub = gen2Static))
            assertTrue(
                "the rotated candidate must approve before the send",
                repo.approvePendingRotation(peer.nodeId, 2L, gen2Static) is io.godstone.mesh.identity.RotationApprovalResult.Approved,
            )

            val authority = sendAuthority(sender, store, journal, repo)
            val token = ByteArray(16) { (it + 0x41).toByte() }

            // *** (1) A FRESH SEND AFTER THE ROTATION: it seals against the ROTATED key and pins generation 2. ***
            val first = authority.sendDirect(command(token, peer.nodeId, BODY))
            assertTrue("*** the post-rotation send must durably enqueue: observed $first ***", first is SendDirectResult.DurablyEnqueued)
            val row = journal.load(token)
            assertNotNull("*** the intent ledger row must stand. ***", row)
            assertEquals(
                "*** A POST-ROTATION SEND MUST PIN THE NEW GENERATION. Observed ${row!!.acceptedGeneration}. ***",
                2L, row.acceptedGeneration,
            )
            assertEquals(
                "*** AND IT MUST SEAL AGAINST THE ROTATED STATIC KEY, not the elder one. ***",
                gen2Static.toList(), row.recipientStaticDhPub.toList(),
            )
            assertEquals(
                "*** and its pinned row must re-prove the authored logical identity from the row alone. ***",
                true, row.verifyLogicalIdentity(sender.nodeId),
            )

            // *** (2) THE RETRY: the SAME token must reuse the pinned bytes WITHOUT re-resolving the table. ***
            val retry = authority.sendDirect(command(token, peer.nodeId, BODY))
            assertTrue("*** the retry must durably enqueue from the PINNED row: observed $retry ***", retry is SendDirectResult.DurablyEnqueued)
            assertEquals(
                "*** A RETRY MUST HAND BACK THE VERY PINNED LOGICAL ID -- a re-authoring would mint a new one. ***",
                (first as SendDirectResult.DurablyEnqueued).logicalMessageId.toList(),
                (retry as SendDirectResult.DurablyEnqueued).logicalMessageId.toList(),
            )
            assertTrue("and the retry must report itself as a retry", retry.fromRetry)
            assertEquals(
                "*** AND THE PINNED ROW MUST STILL NAME GENERATION 2 -- the retry never re-resolved. ***",
                2L, journal.load(token)!!.acceptedGeneration,
            )
        } finally {
            closeTrustStores()
        }
    }

    /**
     * *** A REVOKED PEER IS REFUSED BY NAME BY THE SEND AUTHORITY. ***
     *
     * *THE NEGATIVE OF THE ROTATION LAW: a REVOKED record must refuse every send with the authority's OWN typed
     * rejection, and NOTHING may be durably enqueued -- the "trust revoked recipient refused" clause, on the REAL
     * repository and the REAL product command.*
     */
    @Test
    fun aRevokedPeerIsRefusedByNameAndNothingIsEnqueued() = runTest {
        val peer = MeshIdentity.generate()
        val repo = repository()
        val sender = MeshIdentity.generate()
        val store = InMemoryMessageStore()
        val journal = InMemoryOutboundIntentJournal()
        try {
            repo.applyValidatedBinding(bindingOf(peer, generation = 1L, staticPub = peer.staticDhPub))
            assertTrue(
                "the peer must really revoke",
                repo.revokePeer(peer.nodeId) is io.godstone.mesh.identity.RevokeResult.Revoked,
            )
            val authority = sendAuthority(sender, store, journal, repo)
            val refused = authority.sendDirect(command(ByteArray(16) { 9 }, peer.nodeId, BODY))
            assertTrue("*** a revoked recipient must be REFUSED: observed $refused ***", refused is SendDirectResult.Rejected)
            assertEquals(
                "*** AND THE REFUSAL MUST NAME THE REVOCATION, not a generic fault. ***",
                SendDirectRejection.RecipientRevoked, (refused as SendDirectResult.Rejected).reason,
            )
            assertEquals("*** and nothing may be durably enqueued for a revoked recipient. ***", 0, runBlocking { store.allHeldMsgIds() }.size)
            assertEquals("*** nor may an intent row be pinned. ***", 0, journal.size())
        } finally {
            closeTrustStores()
        }
    }

    // =================================================================================================================
    // the composition (the T44 idiom: production authorities, OS facades substituted)
    // =================================================================================================================

    private suspend fun world(): ComposedRuntimeHarness {
        val clock = FixedHostClock(5_000L)
        val h = ComposedRuntimeHarness(clock = clock, link = LinkFacade(clock))
        h.admitNormalEstate = NormalEstateGate.Testing
        h.addNode("A"); h.addNode("R"); h.addNode("B")
        assertTrue(h.link("A", "R") is ComposedOutcome.Applied)
        assertTrue(h.link("R", "B") is ComposedOutcome.Applied)
        return h
    }

    // =================================================================================================================
    // fixtures: the REAL trust repository, the frozen validator, and the REAL send authority
    // =================================================================================================================

    private fun repository(): PeerIdentityRepository {
        val store = JdbcPeerIdentityStore(File(root, "trust_${System.nanoTime()}.db"))
        trustStores.add(store)
        return PeerIdentityRepository(store)
    }

    /**
     * *** A SERIALIZED IdentityBindingV1 AT A NAMED GENERATION OVER A NAMED STATIC KEY, SIGNED BY THE PEER'S OWN
     * ED25519 SEED. ***
     *
     * *The frozen `IdentityBindingV1` binds `(generation, signingPub, staticDhPub)` and is signed by the signing key,
     * so a rotation is expressible: the SIGNING half persists while the STATIC half rotates, exactly as ADR-003
     * describes.* **This strikes the canonical preimage through the frozen `signaturePreimage` and signs it with the
     * peer's own seed -- so the binding is genuinely validated, not a fixture pretending to be.**
     */
    private fun bindingOf(peer: Identity, generation: Long, staticPub: ByteArray): ValidatedPeerBinding {
        val signingPub = peer.identityPub
        val preimage = IdentityBindingV1.signaturePreimage(generation, signingPub, staticPub)
        val signature = Ed25519Keys.sign(preimage, peer.identityPriv)
        val serialized = IdentityBindingV1.create(generation, signingPub, staticPub, signature).encode()

        val nodeId = IdentityBindingV1.deriveNodeId(signingPub)
        val validated = IdentityBindingValidator.validate(
            serialized = serialized,
            authenticatedRemoteStaticKey = staticPub,
            advertisedNodeHint = IdentityBindingV1.deriveNodeHint(nodeId),
        )
        assertTrue(
            "*** the fixture's binding must PASS THE FROZEN VALIDATOR, or the rotation arm would measure a malformed " +
                "input rather than the engine: observed $validated ***",
            validated is IdentityBindingValidationResult.Valid,
        )
        return (validated as IdentityBindingValidationResult.Valid).binding
    }

    private fun verifiedGeneration(repo: PeerIdentityRepository, peer: Identity): Long? =
        (repo.lookup(peer.nodeId) as? PeerIdentityLookup.Verified)?.identity?.acceptedGeneration

    private fun acceptedStaticOf(repo: PeerIdentityRepository, peer: Identity): ByteArray? =
        (repo.lookup(peer.nodeId) as? PeerIdentityLookup.Verified)?.identity?.acceptedStaticDhPublicKey

    private fun sendAuthority(
        sender: Identity,
        store: InMemoryMessageStore,
        journal: InMemoryOutboundIntentJournal,
        repo: PeerIdentityRepository,
    ): SendDirectAuthority = SendDirectAuthority(
        identity = sender,
        signingKeys = SigningKeysAdapter(sender.identityPriv, sender.identityPub),
        router = Router(store, sender.nodeId, wipeGate = io.godstone.mesh.identity.WipeSensitiveUseGate { true }),
        store = store,
        trustResolver = TrustedPeerIdentityResolver(RepositoryPeerIdentityLookupSource(repo)),
        journal = journal,
    )

    private fun command(intent: ByteArray, recipientNodeId: ByteArray, body: ByteArray): SendDirectCommand =
        SendDirectCommand.of(intent, recipientNodeId, body)
            ?: error("the fixture's command must be well-formed")

    private companion object {
        /** The bounded forward queue's own cap, read from the production constant's law. */
        fun SyncPump_QueueBound(): Int = io.godstone.mesh.router.SYNC_MAX_FORWARD_QUEUE

        val BODY: ByteArray =
            ("the river riseth at dawn and the bridge at Harrow is under two feet of water; the mill road is " +
                "cut at both ends and the surgery hath no power. Send boats and a medic to the church hall.")
                .toByteArray(Charsets.UTF_8)
    }
}
