// T43 readiness court (android isle) -- honest delivery labels.
//
// The card's defect: "A Boolean send currently advances HANDED_TO_RELAY even
// though it only proves local ATT admission." A message whose bytes a radio
// accepted was recorded as durably handed to a relay -- a custody claim the node
// could not honour, and one a restart would keep repeating.
//
// One reviewed scenario per witness; every assertion is positive and expected (a
// present side effect is captured, an absent one is CAPTURED as absence through a
// typed refusal or a zero census). The real MeshNode path is used throughout.
package io.godstone.mesh.readiness

import io.godstone.mesh.MeshNode
import io.godstone.mesh.SosCancelResult
import io.godstone.mesh.delivery.AckFrame
import io.godstone.mesh.delivery.AckMode
import io.godstone.mesh.delivery.AckResult
import io.godstone.mesh.delivery.DeliveryLabel
import io.godstone.mesh.delivery.DeliveryLookup
import io.godstone.mesh.delivery.DeliveryProjection
import io.godstone.mesh.delivery.DeliveryState
import io.godstone.mesh.delivery.DeliveryTracker
import io.godstone.mesh.delivery.Ed25519AckAuthenticator
import io.godstone.mesh.delivery.LegacyHandedLabels
import io.godstone.mesh.delivery.LinkOfferLedger
import io.godstone.mesh.delivery.RecipientKeyResolver
import io.godstone.mesh.identity.Identity
import io.godstone.mesh.store.InMemoryMessageStore
import io.godstone.mesh.store.InMemoryMigrationExecutor
import io.godstone.mesh.store.MigrationResult
import io.godstone.mesh.store.SchemaMigrationEngine
import io.godstone.mesh.store.SchemaFingerprint
import io.godstone.mesh.store.TableFingerprint
import io.godstone.core.crypto.Ed25519Keys
import io.godstone.core.crypto.X25519Keys
import io.godstone.mesh.wire.v2.FrameV2
import io.godstone.mesh.wire.v2.Priority
import io.godstone.mesh.wire.v2.TypeV2
import java.security.SecureRandom
import kotlinx.coroutines.test.runTest
import org.junit.Assert
import org.junit.Test

class ReadinessT43Test {
    private val rng = SecureRandom()

    // ------------------------------------------------------------ fixtures

    private class Local(val id: ByteArray, val seed: ByteArray, val pub: ByteArray)

    private fun newLocal(): Local {
        val ed = Ed25519Keys.generate(rng)
        val dh = X25519Keys.generate(rng)
        val identity = Identity.fromKeyMaterial(ed.pub, ed.priv, dh.pub, dh.priv)
        return Local(identity.nodeId, ed.priv, ed.pub)
    }

    private class KeyTable : RecipientKeyResolver {
        private val table = HashMap<List<Byte>, ByteArray>()
        fun put(nodeId: ByteArray, key: ByteArray) { table[nodeId.toList()] = key.copyOf() }
        fun dropAll() { table.clear() }
        override fun publicSigningKey(nodeId: ByteArray): ByteArray? = table[nodeId.toList()]?.copyOf()
    }

    private class CountingAuthenticator(private val inner: Ed25519AckAuthenticator) :
        io.godstone.mesh.delivery.AckAuthenticator {
        var calls = 0
        override fun verify(originalMsgId: ByteArray, expectedRecipientNodeId: ByteArray,
                            ackFrame: FrameV2): Boolean {
            calls++
            return inner.verify(originalMsgId, expectedRecipientNodeId, ackFrame)
        }
    }

    private class Rig(val store: InMemoryMessageStore, val keys: KeyTable,
                      val tracker: DeliveryTracker, val node: MeshNode,
                      val auth: CountingAuthenticator,
                      val identity: Identity, val sessions: io.godstone.mesh.crypto.SessionManager) {
        private var seedCounter = 0
        /** A fresh msg_id seed per authored frame: two authorings are two messages. */
        fun nextSeed(): Int = ++seedCounter * 13 + 5
    }

    private fun rig(): Rig {
        val store = InMemoryMessageStore()
        val keys = KeyTable()
        val auth = CountingAuthenticator(Ed25519AckAuthenticator(keys))
        val tracker = DeliveryTracker(InMemoryDeliveryRepositoryForT43(store), auth)
        val ed = Ed25519Keys.generate(rng)
        val dh = X25519Keys.generate(rng)
        val identity = Identity.fromKeyMaterial(ed.pub, ed.priv, dh.pub, dh.priv)
        val node = MeshNode(null, identity, store, tracker)
        node.sosAuthority = SosTestAuthority()   // GS-SOS-001: a court that dispatcheth an SOS must wire an authority
        return Rig(store, keys, tracker, node, auth, identity, node.sessions)
    }

    private fun msgId(seed: Int): ByteArray = ByteArray(16) { ((it + seed) and 0xFF).toByte() }

    private fun directedFrame(seed: Int): FrameV2 = FrameV2(
        type = TypeV2.MESSAGE,
        msgId = msgId(seed),
        routingTag = ByteArray(4) { 3 },
        ttl = FrameV2.DEFAULT_TTL,
        hopCount = 0,
        flags = FrameV2.SEALED or (Priority.DIRECT.code shl 8),
        payload = ByteArray(24) { ((it + seed) and 0xFF).toByte() },
    )

    /** A canonical ACK of [mid] by [signer]. */
    private fun ackOf(mid: ByteArray, signer: Local): FrameV2 =
        AckFrame.build(mid, signer.seed, signer.id, ByteArray(4) { 7 })

    private fun stateOf(tracker: DeliveryTracker, mid: ByteArray): DeliveryState? =
        (tracker.lookup(mid) as? DeliveryLookup.Found)?.record?.state

    /** Author one DIRECT message and hand it to [peers] links (all admitted). */
    private suspend fun authorAndOffer(r: Rig, recipient: Local, peers: Int = 1,
                                       admitted: Boolean = true): ByteArray {
        for (i in 0 until peers) r.node.injectPeerForTest(ByteArray(16) { (0x40 + i).toByte() })
        val frame = directedFrame(r.nextSeed())
        val result = r.node.dispatchDirect(frame, expectedRecipient = recipient.id) { _, _ -> admitted }
        Assert.assertTrue("the dispatch must reach the transport",
            result is io.godstone.mesh.DirectDispatchResult.HandedToRelays ||
                result is io.godstone.mesh.DirectDispatchResult.QueuedLocally)
        return frame.msgId
    }

    // ------------------------------------------------------------ W01

    /** W01 -- the card's named mutation: an ATT success advances NOTHING durable.
     *  The message standeth QUEUED_DURABLY, retryable, and claimeth no custody. */
    @Test
    fun test_w01_att_success_without_remote_storage_leaveth_it_queued() = runTest {
        val r = rig()
        val recipient = newLocal()
        r.keys.put(recipient.id, recipient.pub)
        val mid = authorAndOffer(r, recipient, peers = 2)

        Assert.assertEquals("the DURABLE state did not advance",
            DeliveryState.QUEUED_DURABLY, stateOf(r.tracker, mid))
        val projection = r.node.deliveryProjection(mid)
        Assert.assertEquals("the label saith OFFERED, never handed and never delivered",
            DeliveryLabel.OFFERED, projection.label)
        Assert.assertTrue("an offer NEVER clear retryability", projection.retryable)
        Assert.assertFalse("and it claimeth no delivery", projection.claimsDelivery)
        Assert.assertFalse("nor custody", projection.claimsRelayCustody)
        Assert.assertEquals("both offers are recorded as ephemeral telemetry", 2, projection.linkOffers)
        Assert.assertFalse("and the row is not a legacy label", projection.legacyHandedToRelay)
    }

    // ------------------------------------------------------------ W02

    /** W02 -- a refused or unattempted send is NOT an offer: the label stayeth
     *  QUEUED and nothing claimeth the bytes left the device. */
    @Test
    fun test_w02_a_refused_send_leaveth_the_label_queued() = runTest {
        val r = rig()
        val recipient = newLocal()
        r.keys.put(recipient.id, recipient.pub)
        val mid = authorAndOffer(r, recipient, peers = 2, admitted = false)

        Assert.assertEquals(DeliveryState.QUEUED_DURABLY, stateOf(r.tracker, mid))
        val projection = r.node.deliveryProjection(mid)
        Assert.assertEquals("a refused offer is not an offer", DeliveryLabel.QUEUED, projection.label)
        Assert.assertEquals("no ADMITTED offer standeth, so the label stayeth QUEUED",
            0, projection.linkOffers)
        Assert.assertEquals("the two refusals are still visible as telemetry",
            2, projection.refusedOffers)
        Assert.assertFalse("but NOTHING was admitted", r.node.linkOffers.anyAdmitted(mid))
        Assert.assertTrue(projection.retryable)
        Assert.assertFalse(projection.claimsDelivery)
    }

    // ------------------------------------------------------------ W03

    /** W03 -- the ONLY road to DELIVERED: an authenticated ACK from the intended
     *  recipient. */
    @Test
    fun test_w03_the_intended_recipients_ack_produceth_delivered() = runTest {
        val r = rig()
        val recipient = newLocal()
        r.keys.put(recipient.id, recipient.pub)
        val mid = authorAndOffer(r, recipient)
        Assert.assertEquals(DeliveryLabel.OFFERED, r.node.deliveryProjection(mid).label)

        Assert.assertEquals(AckResult.Applied, r.tracker.acknowledge(mid, ackOf(mid, recipient)))
        val projection = r.node.deliveryProjection(mid)
        Assert.assertEquals(DeliveryState.ACKNOWLEDGED_BY_RECIPIENT, projection.state)
        Assert.assertEquals("delivered, and only now", DeliveryLabel.DELIVERED, projection.label)
        Assert.assertTrue(projection.claimsDelivery)
        Assert.assertFalse("a delivered message is not retryable", projection.retryable)
    }

    // ------------------------------------------------------------ W04

    /** W04 -- a WRONG recipient's ACK is rejected and the label never claimeth
     *  delivery. */
    @Test
    fun test_w04_a_wrong_recipients_ack_is_rejected() = runTest {
        val r = rig()
        val recipient = newLocal()
        val stranger = newLocal()
        r.keys.put(recipient.id, recipient.pub)
        r.keys.put(stranger.id, stranger.pub)
        val mid = authorAndOffer(r, recipient)

        val result = r.tracker.acknowledge(mid, ackOf(mid, stranger))
        Assert.assertEquals(AckResult.RejectedAuthentication, result)
        val projection = r.node.deliveryProjection(mid)
        Assert.assertEquals(DeliveryState.QUEUED_DURABLY, projection.state)
        Assert.assertEquals(DeliveryLabel.OFFERED, projection.label)
        Assert.assertFalse(projection.claimsDelivery)
    }

    // ------------------------------------------------------------ W05

    /** W05 -- a duplicate ACK is idempotent AND is not a second verification: the
     *  label stayeth DELIVERED and the authenticator is not consulted again. */
    @Test
    fun test_w05_a_duplicate_ack_is_idempotent() = runTest {
        val r = rig()
        val recipient = newLocal()
        r.keys.put(recipient.id, recipient.pub)
        val mid = authorAndOffer(r, recipient)

        Assert.assertEquals(AckResult.Applied, r.tracker.acknowledge(mid, ackOf(mid, recipient)))
        val callsAfterFirst = r.auth.calls
        val again = r.tracker.acknowledge(mid, ackOf(mid, recipient))
        Assert.assertEquals(AckResult.AlreadyAcknowledged, again)
        Assert.assertEquals("the authenticator is NOT consulted for a terminal row",
            callsAfterFirst, r.auth.calls)
        Assert.assertEquals(DeliveryLabel.DELIVERED, r.node.deliveryProjection(mid).label)
    }

    // ------------------------------------------------------------ W06

    /** W06 -- ACK versus cancel and expiry: a terminal committed state WINS. */
    @Test
    fun test_w06_cancellation_and_expiry_win_over_a_late_ack() = runTest {
        val r = rig()
        val recipient = newLocal()
        r.keys.put(recipient.id, recipient.pub)

        val cancelled = authorAndOffer(r, recipient)
        Assert.assertTrue(r.tracker.cancel(cancelled) is io.godstone.mesh.delivery.TransitionResult.Applied)
        Assert.assertEquals(AckResult.RejectedState, r.tracker.acknowledge(cancelled, ackOf(cancelled, recipient)))
        val cancelledProjection = r.node.deliveryProjection(cancelled)
        Assert.assertEquals(DeliveryLabel.CANCELLED, cancelledProjection.label)
        Assert.assertFalse(cancelledProjection.claimsDelivery)
        Assert.assertFalse(cancelledProjection.retryable)

        val expired = authorAndOffer(r, recipient)
        Assert.assertTrue(r.tracker.expire(expired) is io.godstone.mesh.delivery.TransitionResult.Applied)
        Assert.assertEquals(AckResult.RejectedState, r.tracker.acknowledge(expired, ackOf(expired, recipient)))
        Assert.assertEquals(DeliveryLabel.EXPIRED, r.node.deliveryProjection(expired).label)
    }

    // ------------------------------------------------------------ W07

    /** W07 -- RESTART preserves honest status: the durable label surviveth, the
     *  EPHEMERAL offers do not. */
    @Test
    fun test_w07_a_restart_preserveth_the_honest_status() = runTest {
        val r = rig()
        val recipient = newLocal()
        r.keys.put(recipient.id, recipient.pub)
        val mid = authorAndOffer(r, recipient, peers = 2)
        Assert.assertEquals(DeliveryLabel.OFFERED, r.node.deliveryProjection(mid).label)

        // a cold node over the SAME durable store
        val coldEd = Ed25519Keys.generate(rng)
        val coldDh = X25519Keys.generate(rng)
        val cold = MeshNode(
            null,
            Identity.fromKeyMaterial(coldEd.pub, coldEd.priv, coldDh.pub, coldDh.priv),
            r.store,
            DeliveryTracker(InMemoryDeliveryRepositoryForT43(r.store), Ed25519AckAuthenticator(r.keys)),
        )
        cold.sosAuthority = SosTestAuthority()
        val projection = cold.deliveryProjection(mid)
        Assert.assertEquals("the durable state surviveth", DeliveryState.QUEUED_DURABLY, projection.state)
        Assert.assertEquals("but the offer is GONE: the label falleth back to QUEUED",
            DeliveryLabel.QUEUED, projection.label)
        Assert.assertEquals("and no offer surviveth the process", 0, projection.linkOffers)
        Assert.assertTrue(projection.retryable)
    }

    // ------------------------------------------------------------ W08

    /** W08 -- a LEGACY handed row is READ as queued, before any migration runneth. */
    @Test
    fun test_w08_a_legacy_handed_row_is_read_as_queued() {
        val mid = msgId(80)
        Assert.assertTrue(LegacyHandedLabels.isLegacy(LegacyHandedLabels.LEGACY_CODE))
        val projection = LegacyHandedLabels.projectionForLegacyRow(mid, LegacyHandedLabels.LEGACY_CODE)
        Assert.assertEquals("the legacy label is read as the queued estate it always was",
            DeliveryLabel.QUEUED, projection.label)
        Assert.assertEquals(DeliveryState.QUEUED_DURABLY, projection.state)
        Assert.assertTrue(projection.retryable)
        Assert.assertFalse(projection.claimsRelayCustody)
        Assert.assertFalse(projection.claimsDelivery)
        Assert.assertTrue("and the fact of the legacy label is PRESERVED", projection.legacyHandedToRelay)
        // a row that carrieth a genuinely terminal code is read as such
        Assert.assertEquals(DeliveryLabel.DELIVERED,
            LegacyHandedLabels.projectionForLegacyRow(mid, 3).label)
    }

    // ------------------------------------------------------------ W09

    /** W09 -- the MIGRATION rewriteth every legacy row through the T31 engine's
     *  own transaction, deleting nothing. */
    @Test
    fun test_w09_the_legacy_migration_rewriteth_through_the_engine() {
        val tables = listOf(TableFingerprint(
            name = "delivery_state",
            columns = listOf("msg_id", "state", "ack_mode", "expected_recipient"),
            immutableColumns = setOf("msg_id", "expected_recipient"),
        ))
        val history = ArrayList<Int>()
        // the accepted fingerprint IS the executor's own observation, so the
        // engine's post-migration drift check is a real check and not a fixture
        // artefact
        val executor = InMemoryMigrationExecutor(
            startRevision = 1,
            initialTables = tables,
            initialImmutable = mapOf("delivery_state" to listOf("msg-1", "recipient-1")),
        ).withImmutableDomains(mapOf("delivery_state" to setOf("msg_id", "expected_recipient")))
        val engine = SchemaMigrationEngine(
            steps = listOf(LegacyHandedLabels.step(history = history)),
            supportedMax = LegacyHandedLabels.TO_REVISION,
            fingerprint = executor.observeFingerprint(),
        )
        val immutableBefore = executor.immutableDigest()
        val result = engine.migrate(1, executor.observeFingerprint(), executor)
        Assert.assertEquals("the engine must advance the revision",
            MigrationResult.Upgraded(1, LegacyHandedLabels.TO_REVISION), result)
        Assert.assertTrue("the rewrite ran through the engine's own executor",
            executor.executed.any { it.contains("UPDATE delivery_state SET state = 1 WHERE state = 2") })
        Assert.assertEquals("and the history list recordeth the legacy code once",
            listOf(LegacyHandedLabels.LEGACY_CODE), history)
        Assert.assertEquals("NOTHING immutable moved", immutableBefore, executor.immutableDigest())
        Assert.assertTrue("no violation was recorded", executor.violations.isEmpty())

        // the statements themselves: one guarded rewrite, and no deletion
        val sql = LegacyHandedLabels.statements()
        Assert.assertEquals(1, sql.size)
        Assert.assertTrue("it rewriteth 2 -> 1 and nothing else", sql[0].contains("= 1 WHERE state = 2"))
        Assert.assertFalse("it never deleteth a row", sql[0].uppercase().contains("DELETE"))
        Assert.assertFalse("nor truncateth", sql[0].uppercase().contains("DROP"))
    }

    // ------------------------------------------------------------ W10

    /** W10 -- NO RELAY RECEIPTS in this profile: nothing a relay observeth can
     *  raise a label above OFFERED, and custody is never claimed. */
    @Test
    fun test_w10_no_relay_receipt_is_ever_claimed() = runTest {
        val r = rig()
        val recipient = newLocal()
        r.keys.put(recipient.id, recipient.pub)
        // the origin offers to TWO links; neither can answer for the recipient
        val mid = authorAndOffer(r, recipient, peers = 2)
        val projection = r.node.deliveryProjection(mid)
        Assert.assertFalse("a local admission is not custody", projection.claimsRelayCustody)
        Assert.assertFalse("and it is not delivery", projection.claimsDelivery)
        Assert.assertEquals(DeliveryLabel.OFFERED, projection.label)
        // only the intended recipient's ACK moveth it
        Assert.assertEquals(AckResult.Applied, r.tracker.acknowledge(mid, ackOf(mid, recipient)))
        Assert.assertEquals(DeliveryLabel.DELIVERED, r.node.deliveryProjection(mid).label)
    }

    // ------------------------------------------------------------ W11

    /** W11 -- the ledger is BOUNDED, drop-oldest, and refuseth a malformed key. */
    @Test
    fun test_w11_the_offer_ledger_is_bounded_and_fail_closed() {
        val ledger = LinkOfferLedger(bound = 4)
        for (i in 1..6) {
            ledger.record(msgId(i), ByteArray(16) { 9 }, admitted = true, atMonoMillis = i.toLong())
        }
        Assert.assertEquals("the ledger stoppeth at its bound", 4, ledger.total())
        Assert.assertEquals("and the supersessions are counted", 2L, ledger.droppedCount())
        Assert.assertEquals("the eldest two are gone, the freshest four stand", 0, ledger.countFor(msgId(1)))
        Assert.assertEquals(1, ledger.countFor(msgId(6)))
        val before = ledger.total()
        var refused = false
        try {
            ledger.record(ByteArray(4), ByteArray(16) { 1 }, admitted = true, atMonoMillis = 9L)
        } catch (_e: IllegalArgumentException) {
            refused = true
        }
        Assert.assertTrue("a wrong-size msg_id is refused, not silently accepted", refused)
        Assert.assertEquals("and nothing was written", before, ledger.total())
        ledger.clear()
        Assert.assertEquals(0, ledger.total())
    }

    // ------------------------------------------------------------ W12

    /** W12 -- an UNREADABLE row is never labelled queued: the projection falleth
     *  closed to UNAVAILABLE. */
    @Test
    fun test_w12_an_unreadable_row_is_never_labelled_queued() = runTest {
        val r = rig()
        val stranger = msgId(99)
        val projection = r.node.deliveryProjection(stranger)
        Assert.assertEquals("an absent row is UNAVAILABLE, never QUEUED",
            DeliveryLabel.UNAVAILABLE, projection.label)
        Assert.assertFalse(projection.retryable)
        Assert.assertFalse(projection.claimsDelivery)
        Assert.assertFalse(projection.claimsRelayCustody)
        Assert.assertEquals(0, projection.linkOffers)
        // the SOS cancel surface reporteth the ephemeral truth, and a refusal is
        // typed rather than an empty success
        val recipient = newLocal()
        r.keys.put(recipient.id, recipient.pub)
        val mid = authorAndOffer(r, recipient)
        Assert.assertTrue("the offer ledger is the only source of 'copies may be out'",
            r.node.linkOffers.anyAdmitted(mid))
        Assert.assertEquals("a NONE-mode call's cancel never overwriteth a terminal state",
            SosCancelResult.NotBroadcast, r.node.cancelSos(mid))
        Assert.assertEquals("an unknown msg_id is a typed refusal, not a silent success",
            SosCancelResult.UnknownMessage, r.node.cancelSos(stranger))
    }

    // ------------------------------------------------------------ W13

    /**
     * W13 -- the SOS arm carrieth the same law: a broadcast whose bytes a radio
     * admitted standeth QUEUED_DURABLY (mode NONE, no recipient), and the send is
     * an EPHEMERAL offer. The first campaign proved this witness necessary:
     * without it the SOS send site could re-acquire the custody advance
     * unobserved (the roster's T43-RC2 escaped before this witness existed).
     */
    @Test
    fun test_w13_a_broadcast_send_leaveth_the_sos_label_queued() = runTest {
        val r = rig()
        r.node.injectPeerForTest(ByteArray(16) { 0x51 })
        r.node.injectPeerForTest(ByteArray(16) { 0x52 })

        val result = r.node.dispatchSos("medic".toByteArray()) { _, _ -> true }
        Assert.assertTrue("two links took the bytes: " + result,
            result is io.godstone.mesh.SosDispatchResult.HandedToRelays)
        val mid = r.store.allHeldMsgIds().single()
        Assert.assertEquals("the DURABLE state did not advance",
            DeliveryState.QUEUED_DURABLY, stateOf(r.tracker, mid))
        val projection = r.node.deliveryProjection(mid)
        Assert.assertEquals(DeliveryLabel.OFFERED, projection.label)
        Assert.assertEquals("both admissions are ephemeral telemetry", 2, projection.linkOffers)
        Assert.assertTrue(projection.retryable)
        Assert.assertFalse(projection.claimsDelivery)
        Assert.assertFalse(projection.claimsRelayCustody)
        Assert.assertEquals("and the row standeth NONE-mode, binding no recipient",
            AckMode.NONE, (r.tracker.lookup(mid) as DeliveryLookup.Found).record.ackMode)
    }

    // ------------------------------------------------------------ GS-FINAL-003 (round 699): THE DELIVERY READ ROAD

    /**
     * *** GS-FINAL-003 (round 699) -- THE DELIVERY READ ROAD IS GATED, AND THIS ARM IS ITS RED. ***
     *
     * **THE DEFECT: `deliveryProjection` READ A DELIVERY ROW WITHOUT CONSULTING THE ADMISSION SEAM.** *Measured by
     * sweeping every function that toucheth `store`/`deliveryTracker`: `retrySos` and `activeSosSnapshot` were gated
     * in round 633, this one was NOT -- and it readeth the same store.*
     *
     * **AND THIS ARM IS A BEHAVIOURAL RED, NOT A COMPILE ERROR:** against the pre-fix revision the projector
     * RETURNETH THE ROW'S REAL STATE (`OFFERED`), because the guard did not exist. *A compile error would have proved
     * only that I can type; this proves the ROAD.*
     *
     * The positive control below is the SAME rig with a PERMITTING gate: it must still report the real label, so the
     * arm cannot pass by refusing everything.
     */
    @Test
    fun test_gf003_the_delivery_read_road_is_gated_on_a_pending_wipe() = runTest {
        val r = rig()
        val recipient = newLocal()
        r.keys.put(recipient.id, recipient.pub)
        val mid = authorAndOffer(r, recipient, peers = 2)

        // the row IS durable and the PERMITTING rig seeth it -- the positive control, stated first
        Assert.assertEquals(DeliveryState.QUEUED_DURABLY, stateOf(r.tracker, mid))
        Assert.assertEquals("the PERMITTING rig reads the real label -- so this road works when allowed",
            DeliveryLabel.OFFERED, r.node.deliveryProjection(mid).label)

        // NOW THE SAME NODE, WITH THE SEAM REFUSING: the read must not report a live state from a store under erasure
        val refusing = refusingNodeFor(r)
        val projection = refusing.deliveryProjection(mid)
        Assert.assertEquals("*** a wipe in flight must NOT yield a live delivery state ***",
            DeliveryState.UNAVAILABLE, projection.state)
        Assert.assertFalse("and it must not claim the bytes left the device", projection.claimsDelivery)
        Assert.assertFalse("nor claim relay custody", projection.claimsRelayCustody)
    }

    /** The SAME rig with ONLY the seam refusing -- *so the arm differeth from its control by the gate alone.* */
    private fun refusingNodeFor(r: Rig): MeshNode =
        MeshNode(null, r.identity, r.store, r.tracker,
            io.godstone.mesh.identity.WipeSensitiveUseGate { false }, r.sessions)
            .also { it.sosAuthority = SosTestAuthority() }
}

/** The minimal in-memory delivery repository the T43 court requireth (the
 *  durable CAS itself is T37's and is exercised by its own courts). */
internal class InMemoryDeliveryRepositoryForT43(
    private val store: InMemoryMessageStore,
) : io.godstone.mesh.delivery.DeliveryRepository {
    private val records = LinkedHashMap<List<Byte>, io.godstone.mesh.delivery.DeliveryRecord>()

    override fun get(msgId: ByteArray): DeliveryLookup {
        if (msgId.size != 16) return DeliveryLookup.InvalidArgument
        records[msgId.toList()]?.let { return DeliveryLookup.Found(it) }
        val row = store.readDeliveryRow(msgId) ?: return DeliveryLookup.NotFound
        val state = DeliveryState.fromPersistedCode(row.state) ?: return DeliveryLookup.Corrupt
        val mode = AckMode.fromCode(row.ackMode) ?: return DeliveryLookup.Corrupt
        val rec = io.godstone.mesh.delivery.DeliveryRecord(msgId, state, mode, row.expectedRecipient)
        records[msgId.toList()] = rec
        return DeliveryLookup.Found(rec)
    }

    override fun enqueue(msgId: ByteArray, ackMode: AckMode,
                         expectedRecipient: ByteArray?): io.godstone.mesh.delivery.EnqueueResult {
        if (msgId.size != 16) return io.godstone.mesh.delivery.EnqueueResult.InvalidArgument
        return when (val l = get(msgId)) {
            DeliveryLookup.NotFound -> {
                records[msgId.toList()] = io.godstone.mesh.delivery.DeliveryRecord(
                    msgId, DeliveryState.QUEUED_DURABLY, ackMode, expectedRecipient)
                io.godstone.mesh.delivery.EnqueueResult.Created
            }
            is DeliveryLookup.Found -> io.godstone.mesh.delivery.EnqueueResult.AlreadyQueuedSameBinding
            else -> io.godstone.mesh.delivery.EnqueueResult.StorageFailure
        }
    }

    override fun transition(msgId: ByteArray, transition: io.godstone.mesh.delivery.DeliveryTransition)
        : io.godstone.mesh.delivery.TransitionResult {
        // the durable row may have been written by the STORE (the outbound
        // enqueue pair), so the read path is consulted, never the local map alone
        val rec = (get(msgId) as? DeliveryLookup.Found)?.record
            ?: return io.godstone.mesh.delivery.TransitionResult.UnknownMessage
        val target = when (transition) {
            io.godstone.mesh.delivery.DeliveryTransition.EXPIRE -> DeliveryState.EXPIRED
            io.godstone.mesh.delivery.DeliveryTransition.CANCEL -> DeliveryState.CANCELLED_LOCALLY
            io.godstone.mesh.delivery.DeliveryTransition.MARK_HANDED -> DeliveryState.HANDED_TO_RELAY
        }
        if (rec.state == target) return io.godstone.mesh.delivery.TransitionResult.AlreadyInTarget
        if (rec.state.isTerminal) return io.godstone.mesh.delivery.TransitionResult.RejectedState
        records[msgId.toList()] = rec.copy(state = target)
        return io.godstone.mesh.delivery.TransitionResult.Applied
    }

    override fun acknowledgeBoundAndRetire(msgId: ByteArray, expectedRecipient: ByteArray): AckResult {
        if (msgId.size != 16 || expectedRecipient.size != 16) return AckResult.InvalidArgument
        val rec = (get(msgId) as? DeliveryLookup.Found)?.record ?: return AckResult.UnknownMessage
        if (rec.state == DeliveryState.ACKNOWLEDGED_BY_RECIPIENT) return AckResult.DuplicateAuthenticatedAck
        if (rec.state.isTerminal) return AckResult.RejectedState
        if (rec.ackMode != AckMode.SINGLE_RECIPIENT) return AckResult.NotAckEligible
        val bound = rec.expectedRecipientNodeId ?: return AckResult.Corrupt
        if (!bound.contentEquals(expectedRecipient)) return AckResult.RejectedState
        records[msgId.toList()] = rec.copy(state = DeliveryState.ACKNOWLEDGED_BY_RECIPIENT)
        return AckResult.Applied
    }

    override fun clear(msgId: ByteArray) = io.godstone.mesh.delivery.ClearResult.AlreadyAbsent
}
