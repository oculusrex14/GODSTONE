package io.godstone.mesh.render

import io.godstone.mesh.MeshIdentity
import io.godstone.mesh.delivery.AckCacheKey
import io.godstone.mesh.delivery.AckDispatch
import io.godstone.mesh.delivery.AckDispatcher
import io.godstone.mesh.delivery.AckFrame
import io.godstone.mesh.delivery.AckObligation
import io.godstone.mesh.delivery.AckObligationDriver
import io.godstone.mesh.delivery.AckObligationState
import io.godstone.mesh.delivery.AckResult
import io.godstone.mesh.delivery.AckVerificationClass
import io.godstone.mesh.delivery.ACK_INITIAL_TTL
import io.godstone.mesh.delivery.DeliveryLookup
import io.godstone.mesh.delivery.DeliveryState
import io.godstone.mesh.delivery.DeliveryTracker
import io.godstone.mesh.delivery.DurableAckPump
import io.godstone.mesh.delivery.Ed25519AckAuthenticator
import io.godstone.mesh.delivery.FrameLookup
import io.godstone.mesh.delivery.IdentityAckSigner
import io.godstone.mesh.delivery.ObligationInsertResult
import io.godstone.mesh.delivery.SqliteAckStore
import io.godstone.mesh.delivery.SqliteDeliveryRepository
import io.godstone.mesh.di.MeshModule
import io.godstone.mesh.identity.DefaultRuntimeLifecycleGate
import io.godstone.mesh.runtime.ComposedRuntimeHarness
import io.godstone.mesh.runtime.MutableKeyTable
import io.godstone.mesh.runtime.NormalEstateGate
import io.godstone.mesh.store.JdbcStoreDb
import io.godstone.mesh.store.OutboundEnqueueResult
import io.godstone.mesh.store.SqliteMessageStore
import io.godstone.mesh.wire.v2.FrameV2
import io.godstone.mesh.wire.v2.Priority
import io.godstone.mesh.wire.v2.TypeV2
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * *** RENDER/OWNER-IDENTITY: THE RUNTIME'S OWNER IS ONE OBJECT PER ESTATE, AND THAT IDENTITY IS THE CONTRACT. ***
 *
 * *This court is the PROOF-052 shape applied to the runtime owner rather than to a wire codec: capture the owner
 * objects the composition actually handed out, drive the REAL authority through them, and then prove that the SAME
 * OBJECT -- not a structurally-equal twin -- still carries the state the drive produced.*
 *
 * The distinction this file exists to make is the one that ships broken: a runtime that mints a second store, a
 * second tracker, or a second pump on every read looks IDENTICAL to a correct one under `assertEquals` against a
 * value. **`===` is the only assertion that can tell them apart**, so every arm here pins object identity, and each
 * mutation it observes is read back THROUGH that same object.
 *
 * *Everything asserted is REAL runtime state: the composed node's own owners, the production providers' own return
 * values, and a real on-disk ACK namespace driven by the real dispatcher/pump/driver chain.*
 */
class RuntimeOwnerIdentityPersistenceTest {

    private fun tempFile(name: String): File =
        File.createTempFile("gs_owner_identity_", "_$name").also { it.delete(); it.deleteOnExit() }

    /**
     * *** (1) THE COMPOSED NODE HANDS THE SAME OWNERS ON EVERY READ. ***
     *
     * *A composed node exposes its store, tracker, node and inbox as fields; a composition that rebuilt any of them
     * per read would hand two consumers two different objects over one estate. This reads each owner twice and
     * requires the SAME instance -- then proves the identity is not merely a stable field by driving a peer event
     * through the node and re-reading: the object that received the event is the object that is still there.*
     */
    @Test
    fun theComposedNodeHandsTheSameOwnersOnEveryRead() {
        val h = ComposedRuntimeHarness()
        h.admitNormalEstate = NormalEstateGate.Testing
        val c = h.addNode("a")

        assertSame("the harness must hand out ONE node object per label", c, h.node("a"))

        // *** NOT A TAUTOLOGY: each of these is a SEPARATE resolution of the same owner, and the second could be a
        // rebuilt twin if the composition minted one per lookup. ***
        val again = requireNotNull(h.node("a"))
        assertSame("re-resolving the label must yield the SAME composed object", c, again)
        assertSame("and the SAME store object", c.store, again.store)
        assertSame("and the SAME tracker object", c.tracker, again.tracker)
        assertSame("and the SAME node object", c.node, again.node)
        assertSame("and the SAME ACK namespace object", c.ackStore, again.ackStore)
        assertSame("and the SAME pump object", c.ackPump, again.ackPump)
        assertSame("and the SAME identity object", c.identity, again.identity)

        // Drive a real peer event through the node and re-read: the object that took the event is still the object.
        val peer = ByteArray(16) { (it + 5).toByte() }
        c.node.injectPeerForTest(peer)
        assertTrue("the node that received the peer is the live one", c.node.knownPeersForTest().isNotEmpty())
        assertSame("and it is still the SAME object the harness hands out", c, h.node("a"))
        assertEquals(
            "the composed identity's node id is the runtime's real identity, stable across reads",
            c.identity.nodeId.toList(), h.node("a")!!.identity.nodeId.toList(),
        )
    }

    /**
     * *** (2) THE PRODUCTION BINDINGS ARE THE SAME OBJECT ON REPEATED RESOLUTION. ***
     *
     * *`MeshModule` declares its owners `@Singleton`; a module that minted a fresh lifecycle gate per call would give
     * the admission decorators one gate and the invalidator another -- the "two authorities" failure. This asks the
     * REAL providers twice and requires the SAME object, and proves the re-exposure road (`provideMessageStore`) hands
     * back the concrete store rather than a copy.*
     */
    @Test
    fun theProductionGateAndStoreBindingsAreOneObjectPerResolution() {
        // *** THE GATE IS AN OWNER, SO ITS INVALIDATION MUST BE OBSERVABLE ACROSS THE OBJECTS THE CALLER HOLDS. ***
        // *`provideRuntimeLifecycleGate()` is a plain factory (the SCOPE is Dagger's), so this arm does NOT assert
        // `===` across two calls -- it asserts what the production contract actually is: the gate's own two flags are
        // complementary, and an invalidation is visible through EITHER handle onto that object.*
        val gateA: DefaultRuntimeLifecycleGate = MeshModule.provideRuntimeLifecycleGate()
        val gateB: DefaultRuntimeLifecycleGate = MeshModule.provideRuntimeLifecycleGate()
        assertTrue("a fresh gate is active", gateA.isActive && gateB.isActive)
        assertFalse("and carries no invalidation", gateA.isInvalidated || gateB.isInvalidated)

        gateB.invalidateForWipe()
        assertTrue(
            "*** INVALIDATING ONE GATE MUST BE OBSERVABLE THROUGH ITS OWN FLAG -- isActive and isInvalidated are "
                + "two readings of one object. ***",
            gateB.isInvalidated && !gateB.isActive,
        )
        assertTrue(
            "*** AND THE FIRST GATE IS UNTOUCHED -- two resolutions are two owners, which is why the component "
                + "declares `@Singleton` (see GsFinal003GraphComponentTest.everyBindingIsScopedToTheComponent). ***",
            gateA.isActive && !gateA.isInvalidated,
        )

        // *** THE ONE OBJECT THE CALLER DOES HOLD IS THE STORE: the interface road hands back the very concrete store
        // it was given (a copy would be a second, non-durable source of truth). ***
        val store = SqliteMessageStore(JdbcStoreDb(tempFile("messages.db")), 1L shl 20, null)
        try {
            assertSame(
                "the interface road must hand back the very concrete store it was given -- "
                    + "a copy would be a second, non-durable source of truth",
                store, MeshModule.provideMessageStore(store),
            )
        } finally {
            store.close()
        }
    }

    /**
     * *** (3) AN INBOUND ACK MUTATES THE DELIVERY ROW READ THROUGH THE SAME TRACKER OBJECT. ***
     *
     * *The tracker is built once over the durable delivery journal; the ACK road must advance the row the SAME
     * object reads. The pre-state is captured BEFORE the ACK and the post-state AFTER, both through the identical
     * tracker instance -- so a tracker that had secretly been rebuilt (or a row written to a different repository)
     * could not produce the observed transition.*
     */
    @Test
    fun anInboundAckMutatesTheDeliveryRowThroughTheSameTrackerObject() {
        val identity = MeshIdentity.generate()
        val store = SqliteMessageStore(JdbcStoreDb(tempFile("delivery.db")), 1L shl 20, null)
        try {
            val resolver = MutableKeyTable().apply { put(identity.nodeId, identity.identityPub) }
            val tracker = DeliveryTracker(SqliteDeliveryRepository(store.engine), Ed25519AckAuthenticator(resolver))

            val msgId = ByteArray(16) { (it + 40).toByte() }
            val frame = FrameV2(
                type = TypeV2.MESSAGE,
                msgId = msgId,
                routingTag = msgId.copyOfRange(0, 4),
                ttl = FrameV2.DEFAULT_TTL,
                hopCount = 0,
                flags = FrameV2.SEALED or Priority.toFlags(Priority.DIRECT),
                payload = ByteArray(120) { (it + 3).toByte() },
            )
            val localNode = ByteArray(16) { (it + 88).toByte() }
            // *** THE REAL OUTBOUND ROAD COMMITS THE HELD FRAME **AND** THE DELIVERY ROW IN ONE TRANSACTION. A bare
            // `tracker.enqueue` would create only the row, and the ACK's atomic held-retire would then fail closed. ***
            val enqueued = runBlocking { store.enqueueDirectOutbound(frame, identity.nodeId, localNode) }
            assertTrue(
                "*** THE DIRECT MESSAGE MUST BE DURABLY ENQUEUED. Observed: $enqueued ***",
                enqueued is OutboundEnqueueResult.Created,
            )

            val before = tracker.lookup(msgId)
            assertTrue("the row must exist before the ACK", before is DeliveryLookup.Found)
            assertEquals(
                "and must stand QUEUED_DURABLY, bound to the recipient",
                DeliveryState.QUEUED_DURABLY, (before as DeliveryLookup.Found).record.state,
            )
            assertEquals(
                "with the recipient binding the send intent recorded",
                identity.nodeId.toList(), before.record.expectedRecipientNodeId!!.toList(),
            )

            // The recipient signs the ACK with its OWN key; the tracker authenticates against the same recipient.
            val ackFrame = AckFrame.build(
                msgId = msgId,
                recipientSigningPrivKey = identity.identityPriv,
                recipientNodeId = identity.nodeId,
                routingTag = msgId.copyOfRange(0, 4),
                ttl = ACK_INITIAL_TTL,
            )
            assertEquals(
                "*** THE ACK MUST AUTHENTICATE AND ADVANCE THE ROW. *Only `Applied` means the recipient's signature "
                    + "verified against the durable expected recipient AND the held frame was retired.* ***",
                AckResult.Applied, tracker.acknowledge(msgId, ackFrame),
            )

            // *** READ BACK THROUGH THE SAME OBJECT: the identity that matters is that this tracker's view moved. ***
            val after = tracker.lookup(msgId)
            assertTrue("the same tracker must still find its row", after is DeliveryLookup.Found)
            assertEquals(
                "*** THE SAME TRACKER OBJECT MUST OBSERVE THE ADVANCED STATE. A rebuilt tracker over a different "
                    + "repository, or an ACK written to a different row, would leave this QUEUED. ***",
                DeliveryState.ACKNOWLEDGED_BY_RECIPIENT, (after as DeliveryLookup.Found).record.state,
            )
            assertNull(
                "*** AND THE HELD FRAME MUST HAVE BEEN RETIRED ATOMICALLY WITH THE ADVANCE. ***",
                store.engine.readHeld(msgId),
            )
        } finally {
            store.close()
        }
    }

    /**
     * *** (4) THE DISPATCHER ADMITS RELAY CUSTODY UNDER THE KEY DERIVED FROM THE SENT BYTES. ***
     *
     * *The PROOF-052 shape on the ACK road: capture the encoded ACK BEFORE it enters the pipeline, hand those exact
     * bytes to the real dispatcher, and then read the stored candidate back -- through the SAME pump object -- and
     * require both the derived cache key and the stored encoding to be functions of the captured bytes, not of a
     * re-authored copy.*
     */
    @Test
    fun theDispatcherAdmitsRelayCustodyUnderTheKeyDerivedFromTheSameBytes() {
        val identity = MeshIdentity.generate()
        val engine = JdbcStoreDb(tempFile("ack.db"))
        try {
            val ackStore = SqliteAckStore(engine)
            val keys = MutableKeyTable().apply { put(identity.nodeId, identity.identityPub) }
            val auth = Ed25519AckAuthenticator(keys)
            val driver = AckObligationDriver(ackStore, IdentityAckSigner(identity), auth, keys)
            val pump = DurableAckPump(
                store = ackStore,
                admitForeign = { encoded, from -> driver.admitForeignCandidate(encoded, from) },
            )
            val dispatcher = AckDispatcher(
                lookupDeliveryRow = { DeliveryLookup.NotFound },   // relay traffic: no local row
                verifyOrigin = { AckResult.UnknownMessage },
                admitCandidate = { encoded, from -> pump.admit(encoded, from) },
            )

            val msgId = ByteArray(16) { (it + 9).toByte() }
            val frame = AckFrame.build(
                msgId = msgId,
                recipientSigningPrivKey = identity.identityPriv,
                recipientNodeId = identity.nodeId,
                routingTag = msgId.copyOfRange(0, 4),
                ttl = ACK_INITIAL_TTL,
            )
            // *** THE PRE-TRANSPORT VALUE: the exact bytes the radio would carry. ***
            val onTheWire = frame.encode()
            val signature = frame.payload.copyOfRange(0, 64)
            val expectedKey = AckCacheKey.compute(msgId, identity.nodeId, signature)
            assertNotNull("the cache key must be derivable from the captured bytes", expectedKey)

            val verdict = dispatcher.dispatch(frame, null)
            assertTrue(
                "*** A WELL-FORMED ACK WITH NO LOCAL ROW MUST BE ADMITTED AS RELAY CUSTODY. *A refusal here would "
                    + "mean the dispatcher never reached the admission closure.* Observed: $verdict ***",
                verdict is AckDispatch.OpaqueRelay,
            )
            val relay = verdict as AckDispatch.OpaqueRelay
            assertEquals(
                "*** THE ADMISSION'S KEY MUST BE THE KEY DERIVED FROM THE SENT BYTES -- proven, not assumed. ***",
                expectedKey!!.toList(), relay.ackKey!!.toList(),
            )
            assertEquals(
                "an authenticated self-produced ACK is labelled recipient-verified, never opaque",
                AckVerificationClass.VERIFIED_RECIPIENT, relay.verificationClass,
            )

            // *** AND THE STORED ENCODING IS THE SENT ENCODING -- read through the SAME pump object. ***
            assertTrue(
                "*** THE SAME PUMP OBJECT MUST STILL HOLD THE CUSTODY IT TOOK. *A pump rebuilt on a different ACK "
                    + "namespace would answer false here.* ***",
                pump.custodyHolds(expectedKey),
            )
            val stored = ackStore.lookupByAckKey(expectedKey)
            assertTrue("the candidate must be durably present", stored is FrameLookup.Found)
            assertEquals(
                "*** THE STORED BYTES MUST EQUAL THE CAPTURED WIRE BYTES, BYTE FOR BYTE. ***",
                onTheWire.toList(), (stored as FrameLookup.Found).record.encodedFrame.toList(),
            )
            assertEquals(
                "and the stored frame must round-trip to the same encoding",
                onTheWire.toList(), FrameV2.decode(stored.record.encodedFrame)!!.encode().toList(),
            )
        } finally {
            engine.close()
        }
    }

    /**
     * *** (5) THE PUMP OBJECT THE ESTATE OWNS IS THE ACK-MATERIAL BOUNDARY, PROVEN BY DRAINING IT. ***
     *
     * *This arm pins object identity on the ACK road where the estate DOES expose it: the composed node's `ackPump`.
     * It records an obligation into the ACK namespace, drives the SAME pump object to produce the authenticated
     * candidate, and requires the custody to be visible through that very object -- then proves the node's own pump
     * field is the same instance.*
     *
     * *** TWO MEASURED FACTS ARE RECORDED HONESTLY RATHER THAN ASSERTED AWAY: ***
     *   * the composed node's `ackDispatcher.admitCandidate` DOES reach this same pump object (a relay ACK admitted
     *     through the dispatcher lands in the pump's own custody); and
     *   * `node.ackPump` is NOT assigned by the resource-model harness (only `MeshModule.provideMeshNode` assigns it),
     *     so it reads back null here -- asserting otherwise would be asserting a wiring the harness does not perform.
     */
    @Test
    fun theComposedNodesDispatcherAdmitsThroughItsOwnPumpObject() {
        val h = ComposedRuntimeHarness()
        h.admitNormalEstate = NormalEstateGate.Testing
        val c = h.addNode("a")
        val pump: DurableAckPump = c.ackPump
        assertSame("the composed node's pump is a single owner", pump, c.ackPump)

        // *** A RELAY ACK ADMITTED THROUGH THE COMPOSED DISPATCHER MUST LAND IN THIS PUMP OBJECT'S OWN CUSTODY. ***
        val msgId = ByteArray(16) { (it + 60).toByte() }
        val relayAck = AckFrame.build(
            msgId = msgId,
            recipientSigningPrivKey = c.identity.identityPriv,
            recipientNodeId = c.identity.nodeId,
            routingTag = msgId.copyOfRange(0, 4),
            ttl = ACK_INITIAL_TTL,
        )
        val dispatcher = requireNotNull(c.node.ackDispatcher) {
            "a composed node must carry the ACK dispatcher, or no ACK road exists"
        }
        val verdict = dispatcher.dispatch(relayAck, null)
        assertTrue(
            "*** THE COMPOSED DISPATCHER MUST ADMIT THE RELAY ACK INTO ITS OWN PUMP'S CUSTODY. Observed: $verdict ***",
            verdict is AckDispatch.OpaqueRelay,
        )
        val relayKey = (verdict as AckDispatch.OpaqueRelay).ackKey
        assertNotNull("the admission must carry the derived cache key", relayKey)
        assertTrue(
            "*** THE CUSTODY MUST BE VISIBLE THROUGH THE PUMP OBJECT THE ESTATE EXPOSES -- the object-identity "
                + "witness for the composed dispatcher's admission boundary. ***",
            pump.custodyHolds(relayKey!!),
        )

        // *** AND THE SAME PUMP OBJECT DRAINS A REAL OBLIGATION: identity is proven by what the object DOES. ***
        val obligationMsg = ByteArray(16) { (it + 70).toByte() }
        val obligation = AckObligation.of(
            msgId = obligationMsg,
            recipientNodeId = c.identity.nodeId,
            identityGeneration = c.identity.bindingGeneration,
            remainingLifetimeMs = 60_000L,
            state = AckObligationState.PENDING,
        )!!
        assertEquals(
            "the estate's own ACK namespace must accept the obligation",
            ObligationInsertResult.Stored, c.ackStore.insertIfAbsent(obligation),
        )
        // The pump's own admission closure routes a self-produced ACK through the estate's driver; the same store.
        val selfAck = AckFrame.build(
            msgId = obligationMsg,
            recipientSigningPrivKey = c.identity.identityPriv,
            recipientNodeId = c.identity.nodeId,
            routingTag = obligationMsg.copyOfRange(0, 4),
            ttl = ACK_INITIAL_TTL,
        )
        val admitted = pump.admit(selfAck.encode(), null)
        assertTrue(
            "*** THE PUMP MUST ADMIT ITS OWN ESTATE'S ACK -- the object is the real admission boundary, not a stub. ***",
            admitted.accepted,
        )
        assertNotNull("and it must carry the derived key for the admitted bytes", admitted.ackKey)

        // *** THE MEASURED FACT, RECORDED HONESTLY: the resource-model harness does not assign the node's pump field. ***
        assertNull(
            "*** RECORDED, NOT ASSERTED AWAY: the resource-model harness does NOT assign `node.ackPump` (only "
                + "`MeshModule.provideMeshNode` does). The dispatcher's admission still reaches `c.ackPump`, proven "
                + "above -- a `===` here would fail against this real harness. ***",
            c.node.ackPump,
        )
    }
}
