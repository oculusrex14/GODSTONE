package io.godstone.mesh.rig

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import io.godstone.mesh.MeshNode
import io.godstone.mesh.MeshIdentity
import io.godstone.mesh.crypto.PeerBindingTrustAuthority
import io.godstone.mesh.crypto.RelationDirection
import io.godstone.mesh.crypto.RelationKey as CryptoRelationKey
import io.godstone.mesh.crypto.SessionManager
import io.godstone.mesh.delivery.AckMode
import io.godstone.mesh.delivery.AckSignerSeam
import io.godstone.mesh.delivery.AdmitAllSenders
import io.godstone.mesh.delivery.DeliveryLookup
import io.godstone.mesh.delivery.DeliveryTracker
import io.godstone.mesh.delivery.Ed25519AckAuthenticator
import io.godstone.mesh.delivery.EnqueueResult
import io.godstone.mesh.delivery.InboxCommitResult
import io.godstone.mesh.delivery.RecipientInboxRepository
import io.godstone.mesh.delivery.RecipientKeyResolver
import io.godstone.mesh.delivery.SqliteAckStore
import io.godstone.mesh.delivery.SqliteDeliveryRepository
import io.godstone.mesh.identity.DefaultRuntimeLifecycleGate
import io.godstone.mesh.identity.Identity
import io.godstone.mesh.identity.PeerTrustApplyResult
import io.godstone.mesh.identity.ValidatedPeerBinding
import io.godstone.mesh.identity.WipeSensitiveUseGate
import io.godstone.mesh.di.MeshModule
import io.godstone.mesh.router.Router
import io.godstone.mesh.seal.SealedSender
import io.godstone.mesh.store.InMemoryMessageStore
import io.godstone.mesh.store.JdbcStoreDb
import io.godstone.mesh.store.OutboundEnqueueResult
import io.godstone.mesh.store.PersistResult
import io.godstone.mesh.store.SqliteMessageStore
import io.godstone.mesh.identity.JdbcPeerIdentityStore
import io.godstone.mesh.transport.AdmissionError
import io.godstone.mesh.transport.BleCentralOrchestrationDriver
import io.godstone.mesh.transport.BleConnection
import io.godstone.mesh.transport.BleConnectionState
import io.godstone.mesh.transport.BleDirection
import io.godstone.mesh.transport.BleGattServer
import io.godstone.mesh.transport.BleHandshakeAuthority
import io.godstone.mesh.transport.BleLinkInfoCodec
import io.godstone.mesh.transport.BleLinkInfoV1
import io.godstone.mesh.transport.BleOutletHooks
import io.godstone.mesh.transport.BleRecordFragmenter
import io.godstone.mesh.transport.BleRecordType
import io.godstone.mesh.transport.BleRole
import io.godstone.mesh.transport.BleServerAction
import io.godstone.mesh.transport.BleTransport
import io.godstone.mesh.transport.PeerId
import io.godstone.mesh.transport.RecordWriter
import io.godstone.mesh.transport.RelationKey as TransportRelationKey
import io.godstone.mesh.transport.ReservationAnswer
import io.godstone.mesh.transport.ScanEvent
import io.godstone.mesh.transport.TransportResult
import io.godstone.mesh.transport.WriteCompletion
import io.godstone.mesh.wire.v2.FrameV2
import io.godstone.mesh.wire.v2.LogicalMessageIdentity
import io.godstone.mesh.wire.v2.Priority
import io.godstone.mesh.wire.v2.SenderVerificationResult
import io.godstone.mesh.wire.v2.SignedMessageV1
import io.godstone.mesh.wire.v2.TimeQuality
import io.godstone.mesh.wire.v2.TypeV2
import java.io.File
import java.security.SecureRandom
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * *** GS-STRESS-001 step 4/5 + GS-INTEGRATION-001: THE ANDROID RELEASE-OWNER, DEDUP AND PARSER CONTROLS,
 * DRIVEN AGAINST THE **REAL** PRODUCTION OWNERS. ***
 *
 * THE FINDING'S OWN TWO REMAINING CLAUSES, IN THE CARD'S WORDS:
 *
 *   * *"Add behavioural arms that drive the REAL release owners and assert a real live resource is gone after the
 *     release boundary: session retirement/destruction on `stop()`/invalidation; timer-lease removal on
 *     cancellation/stop; writer-reservation cleanup on shutdown."*
 *   * *"Add inbox/delivery dedup arms against the real durable stores"* and *"parser CRC/magic/length refusal arms
 *     built from ONE valid frame, each mutating exactly one decoder gate, with the valid frame accepted in the same
 *     run as the control."*
 *
 * *** AND THE THREE ARMS WROTE THEMSELVES AS REDS, WHICH IS THE WHOLE POINT OF ASKING AN OWNER INSTEAD OF A
 * COUNTER: EVERY ONE OF THEM FOUND A REAL DEFECT (each is named at its arm, with the repaired line). ***
 *
 * THE STORES ARE ON DISK (`JdbcStoreDb` -- a genuine SQLite engine running the shared `StoreSchema`, the same
 * statements the SQLCipher production engine runs), the inbox/ACK pair is the store's own
 * `commitInboundWithObligationAtWithFault` (ONE engine transaction, both-or-neither), the tracker is
 * `DeliveryTracker(SqliteDeliveryRepository(store.engine))`, and the transport is the production `BleTransport`
 * driven to genuine READY through its own doors (the T17/T18 ladder + trusted handshake), exactly as
 * `ReadinessT17Test`..`ReadinessT23Test` do. **NOTHING HERE SETS A COUNTER THAT THE ARM THEN READS: each census is
 * paired with a BEHAVIOURAL reading** -- a destroyed session refuses to seal, a stopped transport refuses a
 * reservation, a released timer is re-delivered to the scheduler.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33])
class RealOwnerReleaseDedupParserControlsTest {

    private lateinit var root: File

    @Before
    fun mintEstate() {
        root = File.createTempFile("gs_realowner_", "").let {
            it.delete(); it.mkdirs(); it.deleteOnExit(); it
        }
    }

    @After
    fun razeEstate() {
        root.deleteRecursively()
    }

    private fun ctx(): Context = ApplicationProvider.getApplicationContext()

    private fun db(name: String): SqliteMessageStore =
        SqliteMessageStore(JdbcStoreDb(File(root, name)), 1L shl 20, null)

    private fun acceptingAuthority(): PeerBindingTrustAuthority = object : PeerBindingTrustAuthority {
        override fun applyValidatedBinding(binding: ValidatedPeerBinding): PeerTrustApplyResult =
            PeerTrustApplyResult.Accepted
    }

    private fun nullKeys(): RecipientKeyResolver = object : RecipientKeyResolver {
        override fun publicSigningKey(nodeId: ByteArray): ByteArray? = null
    }

    // =================================================================================================================
    // (1) THE SESSION OWNER: RETIREMENT/DESTRUCTION AT THE RELEASE BOUNDARY.
    // =================================================================================================================

    /**
     * *** MEASURED RED BEFORE THE REPAIR: `MeshNode.stop()` RETURNED AT ITS `!isStarted` GUARD *BEFORE*
     * `sessions.destroyAll()`. ***
     *
     * *THE SAME EARLY-RETURN CLASS THE TWO COMMENTS ABOVE THE GUARD ALREADY NAME TWICE (the workers, the adapters,
     * the peer view) -- reached a third time from the SESSION direction.* **AND THIS SHIPPING TREE MAKES THE GUARD
     * ALWAYS FALSE: `start()` returneth false while `LINK_LAYER_READY` is frozen off, so `isStarted` is false BY
     * CONSTRUCTION and a production `stop()` NEVER retired a session: the slots, the live Noise ciphers and the
     * armed age timers of every established relation survived the stop.**
     */
    @Test
    fun theSessionOwnerIsRetiredByStopEvenOnANodeThatWasNeverStarted() {
        val identity = MeshIdentity.generate()
        val sm = SessionManager(identity, acceptingAuthority())
        val store = db("release_sessions.db")
        try {
            val node = MeshNode(
                ctx = ctx(),
                identity = identity,
                store = store,
                deliveryTracker = DeliveryTracker(SqliteDeliveryRepository(store.engine), Ed25519AckAuthenticator(nullKeys())),
                wipeGate = WipeSensitiveUseGate { true },
                sessions = sm,
            )
            // THE PRODUCTION SHAPE, ASSERTED RATHER THAN ASSUMED: this node can never be started on this tree.
            assertFalse(
                "*** THE GUARD'S PREMISE: `start()` must refuse while the link layer is frozen off, or this arm " +
                    "would be measuring a started node and not the production shape. ***",
                node.start(),
            )
            assertFalse(
                "*** AND `isStarted` IS THEREFORE FALSE BY CONSTRUCTION -- which is what made the guard below " +
                    "`stop()`'s session release an ALWAYS-TAKEN early return. Read from the node's own published " +
                    "status, not a test-only flag. ***",
                node.statusFlow.value.started,
            )

            // A REAL ESTABLISHED RELATION on the node's own registry, through the manager's keyed surface.
            val admission = CryptoRelationKey(RelationDirection.OUTBOUND_CENTRAL, "release-peer", 5L, 9L)
            establishPair(sm, admission, identity)
            assertEquals(
                "*** THE CONTROL: THE RELATION MUST FIRST BE LIVE, or 'the release released it' would be satisfied " +
                    "by nothing having been held. ***",
                1, sm.slotCountForTest(),
            )
            assertTrue("and the relation must publish ready", sm.isReady(admission))
            assertNotNull("and it must really seal", sm.seal(admission, byteArrayOf(1, 2, 3)))

            // *** THE RELEASE BOUNDARY: the runtime's own verb, on the production shape. ***
            node.stop()

            // THE BEHAVIOURAL READING, NOT THE CENSUS: a destroyed registry refuses to seal.
            assertNull(
                "*** AFTER `stop()`, THE SESSION OWNER MUST NOT SEAL -- a live cipher after the runtime stopped is " +
                    "the leak this arm existeth for (GS-RUNTIME-001 step 6's session half). ***",
                sm.seal(admission, byteArrayOf(1, 2, 3)),
            )
            assertFalse("and it must not publish ready", sm.isReady(admission))
            // AND THE CENSUS, READ FROM THE OWNER'S OWN HOOK.
            assertEquals(
                "*** AND THE EXACT SLOT MUST BE GONE -- `MeshNode.stop()`'s release must stand ABOVE the " +
                    "`!isStarted` guard, as the adapters close and the peer drain already do. ***",
                0, sm.slotCountForTest(),
            )
            assertTrue(
                "*** AND ITS TIMER LEASE WITH IT (see the timer arm for the separate defect in the arm's own " +
                    "release). Observed: ${sm.armedAgeDeadlinesForTest()} ***",
                sm.armedAgeDeadlinesForTest().isEmpty(),
            )
        } finally {
            store.close()
        }
    }

    /** The invalidator is the wipe's release boundary, and it must reach the session owner too. */
    @Test
    fun theInvalidatorRetiresTheSessionOwnerAtTheWipeBoundary() {
        val identity = MeshIdentity.generate()
        val sm = SessionManager(identity, acceptingAuthority())
        val store = db("release_wipe.db")
        val peerStore = JdbcPeerIdentityStore(File(root, "release_wipe_peers.db"))
        try {
            val node = MeshNode(
                ctx = ctx(),
                identity = identity,
                store = store,
                deliveryTracker = DeliveryTracker(SqliteDeliveryRepository(store.engine), Ed25519AckAuthenticator(nullKeys())),
                wipeGate = WipeSensitiveUseGate { true },
                sessions = sm,
            )
            val admission = CryptoRelationKey(RelationDirection.OUTBOUND_CENTRAL, "wipe-peer", 6L, 9L)
            establishPair(sm, admission, identity)
            assertEquals("the relation must first be live", 1, sm.slotCountForTest())

            val gate = DefaultRuntimeLifecycleGate()
            val invalidator = MeshModule.provideMeshRuntimeInvalidator(
                gate = gate, sessions = sm, peerStore = peerStore, messageStore = store, node = node,
            )
            invalidator.invalidateForWipe()

            assertFalse("the gate must be inactive after the wipe", gate.isActive)
            assertFalse("and the owner must be inactive with it", sm.isActive)
            assertNull("and a wiped owner must refuse to seal", sm.seal(admission, byteArrayOf(4, 5, 6)))
            assertEquals("and hold no slot", 0, sm.slotCountForTest())
            assertTrue(
                "*** AND HOLD NO TIMER LEASE EITHER -- `invalidateForWipe()` cleared the registry and left every " +
                    "armed deadline standing. Observed: ${sm.armedAgeDeadlinesForTest()} ***",
                sm.armedAgeDeadlinesForTest().isEmpty(),
            )
        } finally {
            store.close()
            peerStore.close()
        }
    }

    // =================================================================================================================
    // (2) THE TIMER OWNER: LEASE REMOVAL ON CANCELLATION, AND RE-ARMING AFTER IT.
    // =================================================================================================================

    /**
     * *** MEASURED RED BEFORE THE REPAIR, AND IT IS A BEHAVIOURAL DEFECT RATHER THAN A CENSUS ONE: NOTHING ANYWHERE
     * IN THE MANAGER REMOVED AN ENTRY FROM `armedAgeDeadlines`. ***
     *
     * *`drop()`, `retireIncarnations()`, `destroyAll()`, `invalidateForWipe()` and `getOrCreateSlot()`'s
     * supersession ALL removed slots and left the deadline map untouched.* **AND THE CONSEQUENCE IS NOT A LEAK
     * ALONE: `armAgeTimer` returneth early on `armedAgeDeadlines.containsKey(admission)` -- the IMMUTABILITY law
     * that a deadline shall never be EXTENDED -- so a relation that was DROPPED AND RE-ESTABLISHED on the same
     * admission (the ordinary reconnect) kept the OLD incarnation's deadline, and THE FRESH SESSION'S DEADLINE WAS
     * NEVER ARMED AND NEVER DELIVERED TO THE SCHEDULER. An idle-aged session after a reconnect therefore never
     * retired through its own timer.**
     *
     * THE ARMS BELOW PIN BOTH HALVES: the lease is RELEASED on cancellation, and it is RE-ARMED (and really
     * delivered) for the successor.
     */
    @Test
    fun theAgeTimerLeaseIsReleasedOnCancellationAndReArmedForTheSuccessor() {
        val identity = MeshIdentity.generate()
        val sm = SessionManager(identity, acceptingAuthority())
        val deliveries = ArrayList<Long>()
        sm.scheduleAgeDeadline = { _, deadline, _ -> deliveries.add(deadline) }

        val admission = CryptoRelationKey(RelationDirection.INBOUND_PERIPHERAL, "timer-peer", 2L, 4L)
        establishPair(sm, admission, identity, responder = true)

        assertEquals(
            "*** THE CONTROL: EXACTLY ONE LEASE, ARMED AT TRUSTED ESTABLISHMENT, AND DELIVERED TO THE SCHEDULER. ***",
            1, sm.armedAgeDeadlinesForTest().size,
        )
        assertEquals("and the scheduler really received it", 1, deliveries.size)

        // *** THE CANCELLATION BOUNDARY: the relation is lost / the link is cancelled. ***
        sm.drop(admission)
        assertEquals("the cancellation must retire the slot", 0, sm.slotCountForTest())
        assertTrue(
            "*** AND IT MUST RELEASE THE RELATION'S TIMER LEASE. A deadline that surviveth its relation is a " +
                "callback into a relation that no longer standeth -- and (below) it is what SILENCES the successor. " +
                "Observed: ${sm.armedAgeDeadlinesForTest()} ***",
            sm.armedAgeDeadlinesForTest().isEmpty(),
        )

        // *** AND THE SUCCESSOR ON THE SAME ADMISSION IS ARMED AFRESH AND DELIVERED. ***
        var fired: (() -> Unit)? = null
        sm.scheduleAgeDeadline = { _, deadline, f -> deliveries.add(deadline); fired = f }
        establishPair(sm, admission, identity, responder = true)
        assertEquals(
            "*** A FRESH RELATION ON THE SAME ADMISSION MUST BE ARMED -- pre-repair the stale deadline short-" +
                "circuited `armAgeTimer` and the successor's timer was NEVER ARMED AT ALL. ***",
            1, sm.armedAgeDeadlinesForTest().size,
        )
        assertEquals("and the scheduler must have been handed the successor's deadline", 2, deliveries.size)
        assertNotNull("and the successor's own callback must stand", fired)

        // THE BEHAVIOURAL READING: firing the DELIVERED callback retires the live successor.
        fired!!.invoke()
        assertEquals("the delivered deadline must retire the successor", 0, sm.slotCountForTest())
        assertFalse("and the successor must stop publishing ready", sm.isReady(admission))
    }

    // =================================================================================================================
    // (3) THE WRITER OWNER: RESERVATION CLEANUP AT THE TRANSPORT'S SHUTDOWN.
    // =================================================================================================================

    /**
     * *** MEASURED RED BEFORE THE REPAIR: `BleTransport.stop()` NEVER TOUCHED `centralWriters`/`serverWriters`. ***
     *
     * *The iOS twin (`BleTransport.swift`) had shut both maps down since round 244 -- "for writer in
     * centralWriters.values { writer.shutdown() }" -- while this isle's `stop()` cleared the connections, the
     * drivers, the capacity authority and the published relations and **LEFT EVERY WRITER, ITS RESERVATIONS, ITS
     * ADMITTED RECORDS AND ITS CONNECTION REFERENCE STANDING IN THE MAP.** `failed()` and `shutdown()` disagreeing
     * about what a closed writer holdeth was already found by round 534's arm; THE OWNER'S OWN STOP WAS A THIRD
     * PATH THAT RELEASED NOTHING AT ALL.*
     */
    @Test
    fun theTransportReleasesItsWriterAndTheWritersReservationsAtStop() {
        val rig = linkRig()
        try {
            rig.completeTrust()
            val verdict = runBlocking { rig.alice.send(rig.peerIdTowardsBob(), ByteArray(24) { (it + 3).toByte() }) }
            assertEquals(
                "*** THE CONTROL: A RECORD MUST REALLY TRAVEL, or the writer this arm accuseth would not exist. " +
                    "ring: " + rig.ringDump(rig.alice) + " ***",
                TransportResult.Admitted, verdict,
            )
            val writer = rig.alice.centralWriterForTest(rig.bobAddress)
            assertNotNull("the relation's writer must stand after a real send", writer)

            // A LIVE ALLOCATION ON THAT WRITER: one reservation taken and never sealed.
            assertTrue(
                "the live reservation must stand",
                writer!!.reserve(BleRecordType.DATA, 16) is ReservationAnswer.Admitted,
            )
            assertEquals("one live reservation the owner now holdeth", 1, writer.reservedCountForTest())

            // *** THE RELEASE BOUNDARY: the transport's own shutdown. ***
            rig.alice.stop()

            assertNull(
                "*** AFTER `stop()`, THE TRANSPORT MUST HOLD NO WRITER FOR THAT RELATION -- the iOS twin shutteth " +
                    "both maps down at this very boundary and this isle released NONE of them. ***",
                rig.alice.centralWriterForTest(rig.bobAddress),
            )
            assertEquals(
                "*** AND THE WRITER IT HANDED OUT MUST HOLD NOTHING: the live reservation perisheth with the " +
                    "relation. Observed: ${writer.reservedCountForTest()} ***",
                0, writer.reservedCountForTest(),
            )
            // THE BEHAVIOURAL READING, NOT THE CENSUS: a released writer accepts nothing further.
            val refused = writer.reserve(BleRecordType.DATA, 16)
            assertTrue(
                "*** A RELEASED WRITER MUST REFUSE A NEW RECORD -- observed: $refused ***",
                refused is ReservationAnswer.Refused &&
                    (refused as ReservationAnswer.Refused).error is AdmissionError.Inactive,
            )
        } finally {
            rig.stopQuietly()
        }
    }

    // =================================================================================================================
    // (4) THE INBOX AND DELIVERY DEDUP ARMS, OVER THE REAL DURABLE STORES.
    // =================================================================================================================

    /**
     * *** A REPLAYED `msgId` MUST ADD NO SECOND HELD ROW AND NO SECOND ACK ROW -- measured at the durable owner
     * (the SQLite tables), with the OPPOSITE control (a genuinely new message) in the same run. ***
     *
     * *The pair step is the store's own `commitInboundWithObligationAtWithFault` (ONE engine transaction), and the
     * canonical ACK is restored from the filed row rather than re-signed -- so the replay answers with the VERY
     * BYTES FIRST FILED, which is what maketh the dedup observable from the outside.*
     */
    @Test
    fun theInboxDedupAnswersTheFiledAckAndAddsNoSecondDurableRow() {
        val recipient = MeshIdentity.generate()
        val sender = MeshIdentity.generate()
        val store = db("dedup_inbox.db")
        val ackStore = SqliteAckStore(store.engine)
        try {
            val keys = object : RecipientKeyResolver {
                private val table = HashMap<String, ByteArray>()
                fun put(nodeId: ByteArray, key: ByteArray) { table[nodeId.joinToString("") { "%02x".format(it) }] = key }
                override fun publicSigningKey(nodeId: ByteArray): ByteArray? =
                    table[nodeId.joinToString("") { "%02x".format(it) }]?.copyOf()
            }
            keys.put(recipient.nodeId, recipient.identityPub)
            val signer = object : AckSignerSeam {
                override val nodeId: ByteArray get() = recipient.nodeId
                override fun generation(): Long = 0L
                override fun signingSeed(msgId: ByteArray, recipientNodeId: ByteArray): ByteArray =
                    recipient.identityPriv
            }
            val repo = RecipientInboxRepository(
                router = Router(store, recipient.nodeId, wipeGate = WipeSensitiveUseGate { true }),
                ourNodeId = recipient.nodeId,
                localDhPrivate = { recipient.staticDhPriv },
                signer = signer,
                resolver = keys,
                authenticator = Ed25519AckAuthenticator(keys),
                pairedStore = ackStore,
                commitInbound = { f, rf, lr, g, l, t, fault ->
                    store.commitInboundWithObligationAtWithFault(f, rf, lr, g, l, t, fault)
                },
                trustPolicy = AdmitAllSenders,
                clockSeconds = { 1_700_000_201L },
                epochDay = { FIXED_DAY },
                identityGeneration = { 0L },
            )
            val hop = ByteArray(16) { (it + 0x40).toByte() }
            val frame = sealedDirectFrom(sender, recipient, store, nonceSeed = 11)
            val other = sealedDirectFrom(sender, recipient, store, nonceSeed = 12)

            // (1) THE FIRST ADMISSION: a real pair commit.
            val first = runBlocking { repo.acceptVerifiedAndRequireAck(frame, hop) }
            assertTrue("*** the control: a valid sealed DIRECT message is admitted, not $first ***", first is InboxCommitResult.New)
            val ack = (first as InboxCommitResult.New).ack
            assertEquals("one durable inbox row", 1, runBlocking { store.allHeldMsgIds() }.size)
            assertEquals("one durable ACK frame row", 1, ackStore.countFrames())
            assertEquals("and the obligation was retired by the pair step", 0, ackStore.countObligations())

            // (2) *** THE REPLAY OF THE EXACT SAME msgId. ***
            val replay = runBlocking { repo.acceptVerifiedAndRequireAck(frame, hop) }
            assertTrue(
                "*** A REPLAY MUST BE CLASSIFIED AS A DUPLICATE ADMISSION, not a second one: $replay ***",
                replay is InboxCommitResult.Duplicate,
            )
            assertTrue(
                "*** AND THE DUPLICATE MUST ANSWER WITH THE BYTES FIRST FILED -- never a re-signed frame, which " +
                    "the host Ed25519 layer could randomize. ***",
                (replay as InboxCommitResult.Duplicate).ack.encode().contentEquals(ack.encode()),
            )
            assertEquals(
                "*** AND THE DURABLE ESTATE MUST BE UNCHANGED: one inbox row, not two. ***",
                1, runBlocking { store.allHeldMsgIds() }.size,
            )
            assertEquals("*** and one ACK frame row, not two ***", 1, ackStore.countFrames())
            assertEquals("and no resurrected obligation", 0, ackStore.countObligations())
            val census = repo.census()
            assertEquals("one admission counted new", 1, census.committedNew)
            assertEquals("and one counted duplicate", 1, census.committedDuplicate)
            assertEquals("and exactly one ACK issued across both accepts", 1, census.acksIssued)

            // (3) THE OPPOSITE CONTROL: a genuinely different message is admitted, so the above is dedup and not refusal.
            val second = runBlocking { repo.acceptVerifiedAndRequireAck(other, hop) }
            assertTrue("a different msgId must be admitted", second is InboxCommitResult.New)
            assertEquals("and it adds its own row", 2, runBlocking { store.allHeldMsgIds() }.size)
            assertEquals("and its own ACK row", 2, ackStore.countFrames())
        } finally {
            store.close()
        }
    }

    // =================================================================================================================
    // (4b) THE PAYLOAD ROUND-TRIP: WHAT THE USER ACTUALLY SENT, READ BACK FROM THE RECIPIENT'S OWN DOORS.
    // =================================================================================================================

    /**
     * *** ONE REAL USER MESSAGE, CARRIED BY THE REAL PRODUCTION ROAD, AND ITS EXACT BYTES READ BACK AT THE
     * RECIPIENT -- THE PAYLOAD THE RECIPIENT'S OWN DOORS REACH, NOT A VALUE THIS COURT WROTE BESIDE IT. ***
     *
     * *THE DEFECT THIS CLOSETH, AND IT IS THE CLASS THE TASK NAMED: a court may assert only that a decoder's output
     * equath its OWN re-encoding (`decode(encode(x)) == x`), **which is satisfied by a transform that rewrote the
     * value and then reported the rewrite back to itself** -- the payload that truly reaches the recipient is never
     * compared to what the USER sent.* **THIS ARM THEREFORE PINS THE TWO ENDS: the body `SignedMessageV1.author`
     * signed is the body the frozen verifier reproduces at the RECIPIENT, and the frame the recipient's durable
     * store holds is the frame the recipient's OWN `Router.openSealedMessage` opens.***
     *
     * *** NOTHING HERE IS A COURT HELPER'S ASSERTION ABOUT ITSELF. *** *Every value is read back through a production
     * door -- [`Router.openSealedMessage`] (the recipient's own decryption and policy core), [`SignedMessageV1.verify`]
     * (the frozen authorship verifier), the [`RecipientInboxRepository`]'s durable commit, and the
     * [`io.godstone.mesh.store.SqliteMessageStore`]'s own held rows -- and the SAME call re-run with a MUTATED body
     * must reproduce THE MUTATION, so the round-trip cannot be a constant that agreeth with itself.*
     *
     * *THE BODY IS DELIBERATELY AWKWARD: multibyte UTF-8 (BMP, astral and a combining mark) with newlines and NULs,
     * so a transform that silently re-encoded, truncated or normaliseth the text would DIVERGE rather than pass.*
     */
    @Test
    fun theUserPayloadSurvivesTheRealRoadAndIsReadBackAtTheRecipient() {
        val sender = MeshIdentity.generate()
        val recipient = MeshIdentity.generate()
        val store = db("payload_roundtrip.db")
        val ackStore = SqliteAckStore(store.engine)
        try {
            // *** THE REAL USER'S MESSAGE -- multibyte, newline and NUL bearing, so a rewrite cannot coincide.***
            val userBody = (
                "evacuation notice\n" +
                    "the bridge at Harrow is under two feet of water -- " +
                    "mill road cut at both ends\n" +
                    "send boats + medic to the church hall \u2014 " +
                    "\u00e9\u00e8\u00ea\u00eb \u0416\u0438\u0432\u0435\u0439 \u6cb3\u5ddd \uD83D\uDEA4\uD83C\uDFE5\n" +
                    "combining: e\u0301\u0302  zero\u0000nul  tab\there"
                ).toByteArray(Charsets.UTF_8)
            // THE OTHER DIRECTION: a MUTATED body under the same road, so the round-trip is proved to carry the VALUE.
            val mutatedBody = userBody.copyOf().also { it[0] = 0x45 /* 'E' for 'e' */ }
            assertFalse("the mutation must really differ from the user's own bytes", mutatedBody.contentEquals(userBody))

            val keys = object : RecipientKeyResolver {
                private val table = HashMap<String, ByteArray>()
                fun put(nodeId: ByteArray, key: ByteArray) { table[hex(nodeId)] = key }
                override fun publicSigningKey(nodeId: ByteArray): ByteArray? = table[hex(nodeId)]?.copyOf()
            }
            keys.put(recipient.nodeId, recipient.identityPub)
            val repo = RecipientInboxRepository(
                router = Router(store, recipient.nodeId, wipeGate = WipeSensitiveUseGate { true }),
                ourNodeId = recipient.nodeId,
                localDhPrivate = { recipient.staticDhPriv },
                signer = object : AckSignerSeam {
                    override val nodeId: ByteArray get() = recipient.nodeId
                    override fun generation(): Long = 0L
                    override fun signingSeed(msgId: ByteArray, recipientNodeId: ByteArray): ByteArray =
                        recipient.identityPriv
                },
                resolver = keys,
                authenticator = Ed25519AckAuthenticator(keys),
                pairedStore = ackStore,
                commitInbound = { f, rf, lr, g, l, t, fault ->
                    store.commitInboundWithObligationAtWithFault(f, rf, lr, g, l, t, fault)
                },
                trustPolicy = AdmitAllSenders,
                clockSeconds = { 1_700_000_200L },
                epochDay = { FIXED_DAY },
                identityGeneration = { 0L },
            )
            val hop = ByteArray(16) { (it + 0x50).toByte() }

            // *** (1) THE SENDER AUTHORS THE USER'S EXACT BYTES THROUGH THE FROZEN PRODUCTION ROAD. ***
            val frame = sealedDirectFromBody(sender, recipient, store, userBody)
            // The author's own plaintext (the signed container) is what the sender really sent inside the seal.
            val authoredContainer = SignedMessageV1.author(
                senderIdentityPriv = sender.identityPriv,
                senderIdentityPub = sender.identityPub,
                senderNodeId = sender.nodeId,
                recipientNodeId = recipient.nodeId,
                messageNonce = AUTHORED_NONCE,
                createdAtEpochSeconds = AUTHORED_CREATED_AT,
                priority = Priority.DIRECT,
                timeQuality = TimeQuality.USER_CONFIRMED,
                bodyUtf8 = userBody,
            )

            // *** (2) THE RECIPIENT'S OWN DOORS OPEN THE FRAME THE RADIO CARRIED. ***
            val recipientRouter = Router(store, recipient.nodeId, wipeGate = WipeSensitiveUseGate { true })
            val opened = recipientRouter.openSealedMessage(frame, recipient.staticDhPriv)
            assertTrue(
                "*** THE RECIPIENT'S OWN OPEN ROAD MUST ACCEPT THE AUTHOR'S FRAME, not $opened -- a payload that " +
                    "cannot be opened at the recipient never 'arrives intact'. ***",
                opened is io.godstone.mesh.router.OpenMessageResult.Accepted,
            )
            val message = (opened as io.godstone.mesh.router.OpenMessageResult.Accepted).message

            // *** AND THE FROZEN VERIFIER REPRODUCES THE USER'S EXACT BODY FROM THE OPENED PLAINTEXT. ***
            val verified = SignedMessageV1.verify(
                signedPlaintext = message.plaintext,
                senderNodeId = message.senderNodeId,
                recipientLocalNodeId = recipient.nodeId,
                messageNonce = message.messageNonce,
                createdAtEpochSeconds = message.createdAtEpochSeconds,
                priorityCode = message.priority.code,
            )
            assertTrue(
                "*** THE FROZEN AUTHORSHIP VERIFIER MUST ACCEPT THE AUTHORED CONTAINER, not $verified. ***",
                verified is SenderVerificationResult.Verified,
            )
            val vm = (verified as SenderVerificationResult.Verified).message
            assertEquals(
                "*** THE BODY THE RECIPIENT READS BACK MUST BE THE USER'S OWN BYTES -- OCTET FOR OCTET, multibyte " +
                    "UTF-8, newlines, tabs and NULs included. Observed ${vm.bodyUtf8.size} octets against the " +
                    "user's ${userBody.size}. ***",
                userBody.toList(), vm.bodyUtf8.toList(),
            )

            // *** (3) THE DURABLE ROAD: THE RECIPIENT COMMITS IT, AND ITS OWN HELD ROW RE-OPENS TO THE USER'S BYTES. ***
            val accepted = runBlocking { repo.acceptVerifiedAndRequireAck(frame, hop) }
            assertTrue("*** the recipient must durably admit the user's message, not $accepted ***",
                accepted is InboxCommitResult.New)
            val held = runBlocking { store.allHeldMsgIds() }
            assertEquals("exactly the one authored msgId is durably held at the recipient", 1, held.size)
            assertEquals("and it is the author's own id", frame.msgId.toList(), held.single().toList())

            // *THE STORED FRAME IS READ BACK FROM THE STORE AND RE-OPENED -- the recipient's truth, not this arm's copy.*
            val stored = runBlocking { store.allHeldOrderedByPriority() }.single()
            assertEquals("*** the store's held row must BE the frame the radio carried ***",
                frame.encode().toList(), stored.encode().toList())
            val reopened = recipientRouter.openSealedMessage(stored, recipient.staticDhPriv)
            assertTrue("the DURABLE row must reopen at the recipient", reopened is io.godstone.mesh.router.OpenMessageResult.Accepted)
            val storedVerified = SignedMessageV1.verify(
                signedPlaintext = (reopened as io.godstone.mesh.router.OpenMessageResult.Accepted).message.plaintext,
                senderNodeId = sender.nodeId,
                recipientLocalNodeId = recipient.nodeId,
                messageNonce = AUTHORED_NONCE,
                createdAtEpochSeconds = AUTHORED_CREATED_AT,
                priorityCode = Priority.DIRECT.code,
            )
            val storedBody = (storedVerified as? SenderVerificationResult.Verified)?.message?.bodyUtf8
            assertEquals(
                "*** THE PAYLOAD THE RECIPIENT ACTUALLY HOLDS MUST BE THE USER'S OWN MESSAGE -- read back through " +
                    "the recipient's durable row and its own open road, not from this arm's authoring. ***",
                userBody.toList(), storedBody?.toList(),
            )
            assertEquals(
                "and the recipient's durable row must re-prove the author's identity, not a rewritten one",
                authoredContainer.toList(), message.plaintext.toList(),
            )

            // *** (4) THE NEGATIVE CONTROL: THE MUTATED BODY MUST REPRODUCE AS THE MUTATION. ***
            val mutatedFrame = sealedDirectFromBody(sender, recipient, store, mutatedBody)
            val mutatedOpened = recipientRouter.openSealedMessage(mutatedFrame, recipient.staticDhPriv)
            assertTrue("the mutated body's own frame must still open",
                mutatedOpened is io.godstone.mesh.router.OpenMessageResult.Accepted)
            val mutatedVerified = SignedMessageV1.verify(
                signedPlaintext = (mutatedOpened as io.godstone.mesh.router.OpenMessageResult.Accepted).message.plaintext,
                senderNodeId = sender.nodeId,
                recipientLocalNodeId = recipient.nodeId,
                messageNonce = AUTHORED_NONCE,
                createdAtEpochSeconds = AUTHORED_CREATED_AT,
                priorityCode = Priority.DIRECT.code,
            )
            val mutatedReadBack = (mutatedVerified as SenderVerificationResult.Verified).message.bodyUtf8
            assertEquals("*** A MUTATED PAYLOAD MUST SURVIVE AS THE MUTATION -- proof the round-trip carrieth the " +
                "VALUE rather than a constant that equalth itself. ***", mutatedBody.toList(), mutatedReadBack.toList())
            assertFalse(
                "*** AND THE MUTATION MUST DIFFER FROM THE USER'S OWN BODY, or the control above proveth nothing. ***",
                mutatedReadBack.contentEquals(userBody),
            )
        } finally {
            store.close()
        }
    }

    /**
     * *** AUTHOR ONE SEALED DIRECT FRAME OVER A CALLER-SUPPLIED BODY, UNDER THE FIXED AUTHORED IDENTITY. ***
     *
     * *The nonce and `createdAt` are FIXED constants rather than fresh randomness, so this arm can RE-DERIVE the
     * author's own container ([`SignedMessageV1.author`]) and compare the recipient's opened plaintext to it -- a
     * comparison a randomised authoring could not make.* **The sealing road is the production `Router.buildSealedMessage`
     * over the recipient's own static DH key, and the rotating tag is the same `SealedSender.routingTag` the frozen
     * composer useth, so the frame is byte-for-byte a production frame.**
     */
    private fun sealedDirectFromBody(
        sender: Identity,
        recipient: Identity,
        store: SqliteMessageStore,
        body: ByteArray,
    ): FrameV2 {
        val container = SignedMessageV1.author(
            senderIdentityPriv = sender.identityPriv,
            senderIdentityPub = sender.identityPub,
            senderNodeId = sender.nodeId,
            recipientNodeId = recipient.nodeId,
            messageNonce = AUTHORED_NONCE,
            createdAtEpochSeconds = AUTHORED_CREATED_AT,
            priority = Priority.DIRECT,
            timeQuality = TimeQuality.USER_CONFIRMED,
            bodyUtf8 = body,
        )
        val author = Router(store, sender.nodeId, wipeGate = WipeSensitiveUseGate { true })
        val built = runBlocking {
            author.buildSealedMessage(
                plaintext = container,
                recipientNodeId = recipient.nodeId,
                recipientStaticPub = recipient.staticDhPub,
                identity = LogicalMessageIdentity.of(AUTHORED_CREATED_AT, AUTHORED_NONCE),
                priority = Priority.DIRECT,
            )
        }
        return built.copy(routingTag = SealedSender.routingTag(recipient.nodeId, FIXED_DAY))
    }

    /**
     * *** A SECOND ENQUEUE OF THE SAME BINDING MUST ANSWER `AlreadyQueuedSameBinding` AT THE REAL TRACKER, AND THE
     * STORE'S OWN ATOMIC PAIR MUST SAY THE SAME -- with a DIFFERENT binding refused as a conflict. ***
     */
    @Test
    fun theDeliveryDedupAnswersAlreadyQueuedSameBindingAtTheRealTracker() {
        val origin = MeshIdentity.generate()
        val recipient = MeshIdentity.generate()
        val otherRecipient = MeshIdentity.generate()
        val store = db("dedup_delivery.db")
        try {
            val tracker = DeliveryTracker(
                SqliteDeliveryRepository(store.engine),
                Ed25519AckAuthenticator(nullKeys()),
            )
            val msgId = ByteArray(16) { (it + 7).toByte() }

            assertEquals(
                "*** the control: a fresh binding is CREATED. ***",
                EnqueueResult.Created,
                tracker.enqueue(msgId, AckMode.SINGLE_RECIPIENT, recipient.nodeId),
            )
            assertEquals(
                "*** A SECOND ENQUEUE OF THE SAME BINDING MUST BE THE IDEMPOTENT ANSWER -- no second row, no " +
                    "mutation of the historical intent. ***",
                EnqueueResult.AlreadyQueuedSameBinding,
                tracker.enqueue(msgId, AckMode.SINGLE_RECIPIENT, recipient.nodeId),
            )
            assertEquals(
                "*** AND A DIFFERENT BINDING MUST BE REFUSED AS A CONFLICT, which is what telleth the idempotent " +
                    "answer above apart from a blanket refusal. ***",
                EnqueueResult.ConflictRecipient,
                tracker.enqueue(msgId, AckMode.SINGLE_RECIPIENT, otherRecipient.nodeId),
            )
            val row = tracker.lookup(msgId)
            assertTrue(
                "*** AND THE DURABLE INTENT MUST STILL NAME THE ORIGINAL RECIPIENT -- the conflicting enqueue " +
                    "never overwrote it. Observed: $row ***",
                row is DeliveryLookup.Found &&
                    (row as DeliveryLookup.Found).record.expectedRecipientNodeId!!.contentEquals(recipient.nodeId),
            )

            // *** AND THE STORE'S OWN ATOMIC PAIR, over the SAME on-disk engine. ***
            val frame = sealedDirectFrom(origin, recipient, store, nonceSeed = 21)
            val firstPair = runBlocking {
                store.enqueueDirectOutbound(frame, recipient.nodeId, origin.nodeId)
            }
            assertTrue(
                "*** the control: the store's own pair commits, observed $firstPair ***",
                firstPair is OutboundEnqueueResult.Created,
            )
            val replayPair = runBlocking {
                store.enqueueDirectOutbound(frame, recipient.nodeId, origin.nodeId)
            }
            assertTrue(
                "*** AND ITS REPLAY MUST ANSWER AlreadyQueuedSameBinding -- the store's pair law mirrored at the " +
                    "aggregate that owneth it. Observed: $replayPair ***",
                replayPair is OutboundEnqueueResult.AlreadyQueuedSameBinding,
            )
            assertEquals(
                "*** AND THE HELD TABLE MUST CARRY THAT ONE ROW -- not a second from the replay's pair step, which " +
                    "INSERT-OR-IGNOREs and answereth the classification only. Observed: " +
                    "${runBlocking { store.allHeldMsgIds().size }} ***",
                1, runBlocking { store.allHeldMsgIds() }.size,
            )
        } finally {
            store.close()
        }
    }

    // =================================================================================================================
    // (5) THE PARSER GATES: ONE VALID FRAME, ONE GATE MUTATED PER ARM, THE VALID FRAME ACCEPTED IN THE SAME RUN.
    // =================================================================================================================

    /**
     * *** EVERY MUTATION BELOW CHANGES EXACTLY ONE DECODER GATE, AND THE CRC IS *RECOMPUTED* AFTER THE MUTATION SO
     * THAT THE GATE UNDER TEST IS THE ONE THAT REFUSES. ***
     *
     * *The header is `magic(2) version(1) type(1) msg_id(16) routing_tag(4) ttl(1) hop(1) flags(2) declared_len(2)
     * crc(2)` over `HEADER_SIZE` 32, and the CRC covereth the first thirty octets -- so a naive byte flip is
     * refused by the CRC gate and would prove NOTHING about magic, version, type, TTL or length.* **THAT IS WHY THE
     * CRC IS REFIXED: the mutation, and not the CRC, must be the reason.**
     */
    @Test
    fun theParserRefusesEachMutatedGateAndAcceptsTheValidFrameInTheSameRun() {
        val recipient = MeshIdentity.generate()
        val store = db("parser_gates.db")
        try {
            val node = MeshNode(
                ctx = ctx(),
                identity = recipient,
                store = store,
                deliveryTracker = DeliveryTracker(SqliteDeliveryRepository(store.engine), Ed25519AckAuthenticator(nullKeys())),
                wipeGate = WipeSensitiveUseGate { true },
                sessions = SessionManager(recipient, acceptingAuthority()),
            )
            val hop = ByteArray(16) { (it + 0x20).toByte() }
            val valid = FrameV2(
                type = TypeV2.MESSAGE,
                msgId = ByteArray(16) { (it + 1).toByte() },
                routingTag = ByteArray(4) { (it + 2).toByte() },
                ttl = 12, hopCount = 0,
                flags = Priority.toFlags(Priority.DIRECT) or FrameV2.SEALED,
                payload = ByteArray(48) { (it + 3).toByte() },
            )
            val raw = valid.encode()

            // *** THE CONTROL, ASSERTED BEFORE AND AFTER EVERY MUTATION: THE VALID FRAME IS ACCEPTED. ***
            assertValidFrame(raw, valid, "the control frame")

            val mutations: List<Pair<String, ByteArray>> = listOf(
                "magic" to withCrc(mutate(raw, 0, (raw[0].toInt() xor 0x01).toByte())),
                "version" to withCrc(mutate(raw, 2, 0x03.toByte())),
                "unknown type octet" to withCrc(mutate(raw, 3, 0x7F.toByte())),
                "ttl beyond the ceiling" to withCrc(mutate(raw, 24, 17.toByte())),
                "hop count beyond the ceiling" to withCrc(mutate(raw, 25, 17.toByte())),
                "declared length past the payload" to withCrc(mutateShort(raw, 28, raw.size - FrameV2.HEADER_SIZE + 1)),
                "declared length beyond MAX_PAYLOAD" to withCrc(mutateShort(raw, 28, 0xFFFF)),
                "crc that does not cover the header" to mutate(raw, 30, (raw[30].toInt() xor 0xFF).toByte()),
                "header shorter than the frame layout" to raw.copyOf(FrameV2.HEADER_SIZE - 1),
                "trailing octet after the declared payload" to withCrc(raw + byteArrayOf(0x00)),
            )

            for ((name, mutated) in mutations) {
                assertNull(
                    "*** THE PARSER MUST REFUSE A FRAME WHOSE $name GATE IS BROKEN. Observed: " +
                        "${FrameV2.decode(mutated)} ***",
                    FrameV2.decode(mutated),
                )
                assertNull(
                    "and the node's own ingress decoder must refuse it too",
                    node.decodeInbound(mutated),
                )
                assertFalse(
                    "*** AND THE REAL INGRESS ROAD MUST REFUSE IT -- a refusal that only the decoder knoweth is " +
                        "not a refusal on the road that carrieth records. ($name) ***",
                    runBlocking { node.handleInboundFrame(hop, mutated) },
                )
            }
            assertTrue(
                "*** AND NOTHING MAY HAVE LANDED IN THE DURABLE STORE FROM ANY REFUSED RECORD. Observed: " +
                    "${runBlocking { store.allHeldMsgIds() }} ***",
                runBlocking { store.allHeldMsgIds() }.isEmpty(),
            )

            // *** AND THE VALID FRAME STILL TRAVELS -- ACCEPTED BY THE VERY ROAD THAT REFUSED EVERY MUTATION. ***
            assertValidFrame(raw, valid, "the control frame after the mutation battery")
            assertTrue(
                "*** AND THE VALID FRAME MUST BE ACCEPTED BY THE REAL INGRESS ROAD, in the same run as the " +
                    "refusals above. ***",
                runBlocking { node.handleInboundFrame(hop, raw) },
            )
            assertEquals(
                "and it must really be durably held",
                1, runBlocking { store.allHeldMsgIds() }.size,
            )
        } finally {
            store.close()
        }
    }

    private fun assertValidFrame(raw: ByteArray, expected: FrameV2, what: String) {
        val decoded = FrameV2.decode(raw)
        assertNotNull("*** $what MUST DECODE -- the control the mutations are measured against ***", decoded)
        assertEquals("and the type must survive", expected.type, decoded!!.type)
        assertEquals("and the msg_id", expected.msgId.toList(), decoded.msgId.toList())
        assertEquals("and the routing tag", expected.routingTag.toList(), decoded.routingTag.toList())
        assertEquals("and the ttl", expected.ttl, decoded.ttl)
        assertEquals("and the hop count", expected.hopCount, decoded.hopCount)
        assertEquals("and the flags", expected.flags, decoded.flags)
        assertEquals("and the payload", expected.payload.toList(), decoded.payload.toList())
    }

    // =================================================================================================================
    // fixtures
    // =================================================================================================================

    /** Fix the header CRC after a mutation, so the DECODER GATE under test is the one that refuses. */
    private fun withCrc(bytes: ByteArray): ByteArray {
        val crc = FrameV2.crc16(bytes, 0, FrameV2.HEADER_SIZE - 2)
        bytes[FrameV2.HEADER_SIZE - 2] = ((crc ushr 8) and 0xFF).toByte()
        bytes[FrameV2.HEADER_SIZE - 1] = (crc and 0xFF).toByte()
        return bytes
    }

    private fun mutate(bytes: ByteArray, offset: Int, value: Byte): ByteArray =
        bytes.copyOf().also { it[offset] = value }

    private fun mutateShort(bytes: ByteArray, offset: Int, value: Int): ByteArray =
        bytes.copyOf().also {
            it[offset] = ((value ushr 8) and 0xFF).toByte()
            it[offset + 1] = (value and 0xFF).toByte()
        }

    /**
     * A REAL sealed DIRECT frame authored for [recipient] by [sender], through the frozen authorities
     * (`SignedMessageV1.author` + `Router.buildSealedMessage` + the rotating tag), exactly as `ReadinessT37Test`
     * buildeth its inbound frames.
     */
    private fun sealedDirectFrom(
        sender: Identity,
        recipient: Identity,
        store: SqliteMessageStore,
        nonceSeed: Int,
    ): FrameV2 {
        val nonce = ByteArray(16) { ((it * 31 + nonceSeed * 5 + 3) and 0xFF).toByte() }
        val createdAt = 1_700_000_200L
        val container = SignedMessageV1.author(
            senderIdentityPriv = sender.identityPriv,
            senderIdentityPub = sender.identityPub,
            senderNodeId = sender.nodeId,
            recipientNodeId = recipient.nodeId,
            messageNonce = nonce,
            createdAtEpochSeconds = createdAt,
            priority = Priority.DIRECT,
            timeQuality = TimeQuality.USER_CONFIRMED,
            bodyUtf8 = "real-owner-arm-$nonceSeed".toByteArray(Charsets.US_ASCII),
        )
        val author = Router(store, sender.nodeId, wipeGate = WipeSensitiveUseGate { true })
        val built = runBlocking {
            author.buildSealedMessage(
                plaintext = container,
                recipientNodeId = recipient.nodeId,
                recipientStaticPub = recipient.staticDhPub,
                identity = LogicalMessageIdentity.of(createdAt, nonce),
                priority = Priority.DIRECT,
            )
        }
        return built.copy(routingTag = SealedSender.routingTag(recipient.nodeId, FIXED_DAY))
    }

    /**
     * A REAL established relation on [sm]'s keyed surface, through the frozen trusted handshake. One manager only
     * is needed for the release arms: the handshake runs against a second manager and only the FIRST is the
     * subject, so the peer's registry is a throwaway (its readiness is not what these arms measure).
     */
    private fun establishPair(
        sm: SessionManager,
        admission: CryptoRelationKey,
        localIdentity: Identity,
        responder: Boolean = false,
    ) {
        val remote = MeshIdentity.generate()
        val peer = SessionManager(remote, acceptingAuthority())
        if (responder) {
            // The subject is the RESPONDER of the exchange.
            val hs1 = peer.initiatorStart(
                CryptoRelationKey(RelationDirection.OUTBOUND_CENTRAL, "subject", 1L, 1L),
                localIdentity.nodeHint,
            )!!
            val hs2 = sm.responderProcessHs1(admission, remote.nodeHint, hs1)!!
            val hs3 = peer.initiatorProcessHs2(
                CryptoRelationKey(RelationDirection.OUTBOUND_CENTRAL, "subject", 1L, 1L),
                hs2, localIdentity.nodeHint,
            )!!
            assertTrue(
                "the trusted handshake must complete at the subject",
                sm.responderProcessHs3(admission, hs3, remote.nodeHint),
            )
        } else {
            val hs1 = sm.initiatorStart(admission, remote.nodeHint)!!
            val hs2 = peer.responderProcessHs1(
                CryptoRelationKey(RelationDirection.INBOUND_PERIPHERAL, "subject", 1L, 1L),
                localIdentity.nodeHint, hs1,
            )!!
            val hs3 = sm.initiatorProcessHs2(admission, hs2, remote.nodeHint)!!
            assertTrue(
                "the trusted handshake must complete at the subject",
                peer.responderProcessHs3(
                    CryptoRelationKey(RelationDirection.INBOUND_PERIPHERAL, "subject", 1L, 1L),
                    hs3, localIdentity.nodeHint,
                ),
            )
        }
    }

    // ---------------------------------------------------------------- the transport rig (the T17/T18 idiom)

    /** The recording outlet: the writes of both directions, captured, and both legs answering Accepted. */
    private class RecordingOutlet : BleOutletHooks {
        var subscribed: String? = null
        var clientConnected: String? = null
        val written = java.util.concurrent.CopyOnWriteArrayList<Pair<String, ByteArray>>()
        val notified = java.util.concurrent.CopyOnWriteArrayList<Pair<String, ByteArray>>()
        override fun isPeerSubscribed(address: String): Boolean = subscribed == address
        override fun isClientConnected(address: String): Boolean = clientConnected == address
        override suspend fun notifyPeer(address: String, value: ByteArray): Boolean {
            notified.add(address to value.copyOf()); return true
        }
        override suspend fun writePeer(address: String, value: ByteArray): Boolean {
            written.add(address to value.copyOf()); return true
        }
        override suspend fun notifyPeerTyped(address: String, value: ByteArray): WriteCompletion {
            notified.add(address to value.copyOf()); return WriteCompletion.Accepted
        }
        override suspend fun writePeerTyped(address: String, value: ByteArray): WriteCompletion {
            written.add(address to value.copyOf()); return WriteCompletion.Accepted
        }
        fun writesTo(address: String): List<ByteArray> = written.filter { it.first == address }.map { it.second }
        fun notificationsTo(address: String): List<ByteArray> = notified.filter { it.first == address }.map { it.second }
        fun clear() { written.clear(); notified.clear() }
    }

    private inner class TransportRig(
        val aliceId: Identity,
        val bobId: Identity,
        val bobAddress: String,
        val aliceOutlet: RecordingOutlet,
        val bobOutlet: RecordingOutlet,
        val alice: BleTransport,
        val bob: BleTransport,
        val smA: SessionManager,
        val smB: SessionManager,
    ) {
        fun peerIdTowardsBob(): ByteArray = PeerId.fromAddress(bobAddress) ?: error("no B id")
        fun initiatorConnection(): BleConnection =
            alice.centralDriver.getActiveConnection(bobAddress) ?: error("the initiator has no connection")
        fun responderConnection(): BleConnection =
            bob.serverDriver.getInboundConnection(aliceAddress()) ?: error("the responder has no connection")
        fun aliceAddress(): String = aliceAddressValue

        var aliceAddressValue: String = ""

        fun bringUpInitiatorLadder() {
            val ctx = alice.openScanContextForTest()
            assertTrue(
                "the scan admission is accepted",
                alice.handleScanEvent(
                    ScanEvent(ctx, 1, bobAddress, -55, BleLinkInfoV1(nodeHint = bobId.nodeHint, shortDigest = ByteArray(6))),
                ),
            )
            val driver = alice.centralDriver
            driver.onGattConnected(bobAddress, 1L, 1L)
            driver.onServicesDiscovered(bobAddress, true, 1L, 1L)
            driver.onLinkInfoReadResult(bobAddress, linkInfoOf(bobId), 1L, 1L)
            driver.onLinkInfoWriteAcknowledged(bobAddress, true, bobId.nodeHint, 1L, 1L)
            driver.onCccdWriteAcknowledged(bobAddress, true, 1L, 1L)
            driver.onMtuChanged(bobAddress, MTU)
            aliceOutlet.clientConnected = bobAddress
            val conn = initiatorConnection()
            assertTrue(
                "the initiator stands role bound (or has legitimately advanced into the handshake, which only " +
                    "the role-bound state can reach), was " + conn.state,
                conn.state == BleConnectionState.ROLE_BOUND ||
                    conn.state == BleConnectionState.HANDSHAKE_IN_PROGRESS,
            )
            assertEquals("the election made the initiator", BleRole.INITIATOR, conn.localRole)
            assertTrue("the duplex is up", conn.isHandshakeTransportReady)
        }

        fun bringUpResponderLadder() {
            val srv = bob.serverDriver
            assertTrue(
                "the client connection is admitted",
                srv.onClientConnected(aliceAddressValue, 1L) is BleServerAction.AdmitConnection,
            )
            bob.handleInboundClientAdmitted(aliceAddressValue, 1L)
            val descriptor = srv.onDescriptorWriteRequest(aliceAddressValue, true)
            assertTrue(
                "the subscription is accepted",
                descriptor is BleServerAction.AcceptDescriptorWrite ||
                    descriptor is BleServerAction.AcceptDescriptorWriteAndPublishFound,
            )
            val linkInfo = srv.onLinkInfoWriteRequest(aliceAddressValue, linkInfoOf(aliceId))
            assertTrue(
                "the link-info record is accepted",
                linkInfo is BleServerAction.AcceptWrite ||
                    linkInfo is BleServerAction.AcceptWriteAndPublishFound,
            )
            bobOutlet.subscribed = aliceAddressValue
            val conn = responderConnection()
            assertEquals("the responder stands role bound", BleConnectionState.ROLE_BOUND, conn.state)
            assertEquals("the election made the responder", BleRole.RESPONDER, conn.localRole)
            conn.maxAttValueLength = MTU
            assertTrue("the duplex is up", conn.isHandshakeTransportReady)
        }

        fun completeHandshake() {
            val begin = runBlocking { alice.beginTrustedHandshake(peerIdTowardsBob(), bobId.nodeHint) }
            assertEquals("the begin must stand; ring: " + ringDump(alice), TransportResult.Admitted, begin)
            val hs1 = lastOf("hs1 at the initiator outlet; ring: " + ringDump(alice)) { aliceOutlet.writesTo(bobAddress) }
            aliceOutlet.clear()
            pushToResponder(hs1)
            val hs2 = lastOf("hs2 at the responder outlet; ring: " + ringDump(bob)) { bobOutlet.notificationsTo(aliceAddressValue) }
            bobOutlet.clear()
            pushToInitiator(hs2)
            val hs3 = lastOf("hs3 stall; ring: " + ringDump(alice)) { aliceOutlet.writesTo(bobAddress) }
            aliceOutlet.clear()
            pushToResponder(hs3)
            awaitUntil("both registries report the peer ready") {
                smA.isReady(initiatorConnection().peerId) && smB.isReady(responderConnection().peerId)
            }
            awaitUntil("both connections stand READY") {
                initiatorConnection().state == BleConnectionState.READY &&
                    responderConnection().state == BleConnectionState.READY
            }
        }

        fun completeTrust() {
            bringUpInitiatorLadder()
            bringUpResponderLadder()
            completeHandshake()
        }

        private fun pushToResponder(fragments: List<ByteArray>) {
            for (f in fragments) bob.handleServerInboundWrite(aliceAddressValue, f)
        }

        private fun pushToInitiator(fragments: List<ByteArray>) {
            for (f in fragments) alice.handleCentralInboundNotification(bobAddress, f)
        }

        fun stopQuietly() {
            runCatching { alice.stop() }
            runCatching { bob.stop() }
        }
    }

    private fun linkRig(): TransportRig {
        val rng = SecureRandom()
        val first = MeshIdentity.generate()
        val second = MeshIdentity.generate()
        // THE ORDER IS CHOSEN, NEVER FISHED FOR (the T18 lane-integrity lesson): the ascendant hint is the initiator.
        val alice = if (hintAscending(first.nodeHint, second.nodeHint)) first else second
        val bob = if (alice === first) second else first
        val aliceAddress = addressOf(alice.nodeId, 0x10)
        val bobAddress = addressOf(bob.nodeId, 0x90)
        assertTrue("the peers hold distinct addresses", aliceAddress != bobAddress)
        val aliceOutlet = RecordingOutlet()
        val bobOutlet = RecordingOutlet()
        val smA = SessionManager(alice, acceptingAuthority())
        val smB = SessionManager(bob, acceptingAuthority())
        val aliceStore = InMemoryMessageStore()
        val bobStore = InMemoryMessageStore()
        val aliceTransport = BleTransport(
            serverStartAttempt = { true }, identity = alice, store = aliceStore, sessions = smA,
            outletHooks = aliceOutlet,
        )
        // This court DRIVES the trusted hour by hand and then does arithmetic upon the relation's writer, so it
        // issues the key confirmation ITSELF and says so (the T18 precedent; the seam is DEFAULT-ON in production).
        aliceTransport.applicationIssuesKeyConfirmationForTest = false
        val bobTransport = BleTransport(
            serverStartAttempt = { true }, identity = bob, store = bobStore, sessions = smB,
            outletHooks = bobOutlet,
        )
        runBlocking { aliceTransport.start() }
        runBlocking { bobTransport.start() }
        return TransportRig(
            aliceId = alice, bobId = bob, bobAddress = bobAddress,
            aliceOutlet = aliceOutlet, bobOutlet = bobOutlet,
            alice = aliceTransport, bob = bobTransport, smA = smA, smB = smB,
        ).also { it.aliceAddressValue = aliceAddress }
    }

    private fun TransportRig.ringDump(transport: BleTransport): String =
        transport.rejectionRecordsForTest().joinToString(separator = "; ") { it.site + "|" + it.reason }

    private fun <T> lastOf(what: String, observe: () -> List<T>): List<T> {
        for (attempt in 0 until 200) {
            val seen = observe()
            if (seen.isNotEmpty()) return seen
            Thread.sleep(10)
        }
        return error(what)
    }

    private fun awaitUntil(what: String, predicate: () -> Boolean) {
        for (attempt in 0 until 200) {
            if (predicate()) return
            Thread.sleep(10)
        }
        throw AssertionError(what)
    }

    private fun addressOf(nodeId: ByteArray, salt: Int): String {
        val six = ByteArray(6) { i -> if (i < 4) nodeId[i] else (salt + i).toByte() }
        return PeerId.toAddress(six) ?: error("the address could not be formed")
    }

    private fun linkInfoOf(peer: Identity): ByteArray =
        BleLinkInfoCodec.encode(
            flags = 0.toByte(),
            nodeHint = peer.nodeHint,
            shortDigest = ByteArray(6) { (it % 251).toByte() },
            queueDepth = 0,
        )

    private fun hintAscending(x: ByteArray, y: ByteArray): Boolean {
        for (i in 0 until 4) {
            val a = x[i].toInt() and 0xFF
            val b = y[i].toInt() and 0xFF
            if (a != b) return a < b
        }
        throw AssertionError("the two drawn identities carry the SAME node hint")
    }

    /** *The lowercase hex this court's key directory and its payload arms name node ids by.* */
    private fun hex(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it) }

    private companion object {
        const val FIXED_DAY = 12_345L
        const val MTU = 247

        /**
         * *THE FIXED AUTHORED IDENTITY THE PAYLOAD ROUND-TRIP PINS: one nonce and one `createdAt`, so the arm can
         * RE-DERIVE the author's own container and compare the recipient's opened plaintext to it. A randomised
         * authoring could not make that comparison, which is why these are constants and not draws.*
         */
        val AUTHORED_NONCE: ByteArray = ByteArray(16) { ((it * 13 + 7) and 0xFF).toByte() }
        const val AUTHORED_CREATED_AT = 1_700_000_200L
    }
}
