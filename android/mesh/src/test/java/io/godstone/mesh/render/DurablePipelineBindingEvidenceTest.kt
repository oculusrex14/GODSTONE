package io.godstone.mesh.render

import io.godstone.mesh.MeshIdentity
import io.godstone.mesh.delivery.AckCacheKey
import io.godstone.mesh.delivery.AckFrame
import io.godstone.mesh.delivery.AckFrameRecord
import io.godstone.mesh.delivery.AckMode
import io.godstone.mesh.delivery.AckResult
import io.godstone.mesh.delivery.AckVerificationClass
import io.godstone.mesh.delivery.ACK_INITIAL_TTL
import io.godstone.mesh.delivery.DeliveryLookup
import io.godstone.mesh.delivery.DeliveryState
import io.godstone.mesh.delivery.DeliveryTracker
import io.godstone.mesh.delivery.Ed25519AckAuthenticator
import io.godstone.mesh.delivery.FrameLookup
import io.godstone.mesh.delivery.SqliteAckStore
import io.godstone.mesh.delivery.SqliteDeliveryRepository
import io.godstone.mesh.delivery.TransitionResult
import io.godstone.mesh.runtime.MutableKeyTable
import io.godstone.mesh.store.JdbcStoreDb
import io.godstone.mesh.store.OutboundEnqueueResult
import io.godstone.mesh.store.PersistResult
import io.godstone.mesh.store.SqliteMessageStore
import io.godstone.mesh.wire.v2.FrameV2
import io.godstone.mesh.wire.v2.Priority
import io.godstone.mesh.wire.v2.TypeV2
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * *** RENDER/DURABLE-PIPELINE-BINDING: THE PROOF-052 SHAPE ON THE DURABLE ROAD. ***
 *
 * *Capture the REAL runtime value BEFORE it enters a transformation (a durable persist, a wire encode, a reboot), and
 * prove the captured value SURVIVES the transformation -- then prove the SAME OBJECT reports it on the far side.*
 *
 * Every arm here drives a REAL production type over a REAL on-disk SQLite engine (`JdbcStoreDb`, the same schema and
 * SQL the SQLCipher production engine runs) and never asserts what a fake bookkept. *The two failure classes it
 * catches are the ones that ship: a store that holds a plausible-looking row that is not the authored bytes, and a
 * pipeline that reports success while the durable state is empty.*
 */
class DurablePipelineBindingEvidenceTest {

    private fun freshFile(name: String): File =
        File.createTempFile("gs_pipeline_", "_$name").also { it.delete(); it.deleteOnExit() }

    private fun inboundFrame(msgId: ByteArray, payload: ByteArray): FrameV2 = FrameV2(
        type = TypeV2.MESSAGE,
        msgId = msgId,
        routingTag = msgId.copyOfRange(0, 4),
        ttl = FrameV2.DEFAULT_TTL,
        hopCount = 0,
        flags = FrameV2.SEALED or Priority.toFlags(Priority.DIRECT) or FrameV2.ACK_REQ,
        payload = payload,
    )

    private fun heldFrames(store: SqliteMessageStore): List<FrameV2> =
        runBlocking { store.allHeldOrderedByPriority() }

    /**
     * *** (1) AN INBOUND FRAME'S CAPTURED BYTES AND PROVENANCE SURVIVE A REAL CLOSE/REOPEN. ***
     *
     * *The pre-persist value (`frame.encode()`) is captured BEFORE the transformation; after the persist, a close and a
     * reopen of the SAME on-disk file, the frame read back through the reopened store must encode to those exact bytes,
     * and the row's `received_from` must be the provenance the receiver recorded -- read from the reopened engine.*
     */
    @Test
    fun anInboundFramesBytesAndProvenanceSurviveACloseReopen() {
        val file = freshFile("held.db")
        val msgId = ByteArray(16) { (it + 1).toByte() }
        val receivedFrom = ByteArray(16) { (it + 90).toByte() }
        val frame = inboundFrame(msgId, ByteArray(250) { (it + 11).toByte() })
        // *** THE PRE-TRANSFORMATION VALUE. ***
        val authoredBytes = frame.encode()

        val first = SqliteMessageStore(JdbcStoreDb(file), 1L shl 20, null)
        try {
            assertEquals(PersistResult.HELD_NEW, runBlocking { first.persist(frame, receivedFrom) })
        } finally {
            first.close()
        }

        val reopened = SqliteMessageStore(JdbcStoreDb(file), 1L shl 20, null)
        try {
            val held = heldFrames(reopened)
            assertEquals("the reopened store must hold exactly the one frame", 1, held.size)
            assertEquals(
                "*** THE FRAME MUST SURVIVE THE REBOOT BYTE-FOR-BYTE -- the authored encoding IS the stored encoding. ***",
                authoredBytes.toList(), held.first().encode().toList(),
            )
            val row = reopened.engine.readHeld(msgId)
            assertTrue("the row must be present after reopen", row != null)
            assertEquals(
                "*** AND ITS PROVENANCE MUST SURVIVE: the recorded `received_from` is the receiver's own value. ***",
                receivedFrom.toList(), row!!.receivedFrom.toList(),
            )
            assertEquals("and the stored msg_id is the authored one", msgId.toList(), row.msgId.toList())
        } finally {
            reopened.close()
        }
    }

    /**
     * *** (2) THE OUTBOUND DIRECT SEND'S CANONICAL FRAME IS THE AUTHORED FRAME, AND THE RECIPIENT BINDING SURVIVES. ***
     *
     * *`enqueueDirectOutbound` re-reads the persisted bytes and returns the canonical frame. This captures the authored
     * frame BEFORE the transformation and requires the returned canonical frame (and, after a reopen, the held frame and
     * the durable SINGLE_RECIPIENT binding) to carry exactly those bytes and that recipient.*
     */
    @Test
    fun theOutboundDirectSendsCanonicalFrameAndRecipientBindingSurvive() {
        val file = freshFile("outbound.db")
        val msgId = ByteArray(16) { (it + 21).toByte() }
        val recipient = ByteArray(16) { (it + 55).toByte() }
        val localNode = ByteArray(16) { (it + 77).toByte() }
        val frame = inboundFrame(msgId, ByteArray(180) { (it + 3).toByte() })
        val authoredBytes = frame.encode()

        val store = SqliteMessageStore(JdbcStoreDb(file), 1L shl 20, null)
        try {
            val result = runBlocking { store.enqueueDirectOutbound(frame, recipient, localNode) }
            assertTrue(
                "*** THE AUTHORED CANONICAL FRAME MUST BE ACCEPTED. *An InvalidArgument here would mean the rig's "
                    + "flags do not satisfy the DIRECT policy.* Observed: $result ***",
                result is OutboundEnqueueResult.Created,
            )
            val canonical = (result as OutboundEnqueueResult.Created).canonicalFrame
            assertEquals(
                "*** THE CANONICAL FRAME READ BACK MUST EQUAL THE AUTHORED FRAME, BYTE FOR BYTE. ***",
                authoredBytes.toList(), canonical.encode().toList(),
            )
        } finally {
            store.close()
        }

        val reopened = SqliteMessageStore(JdbcStoreDb(file), 1L shl 20, null)
        try {
            val held = heldFrames(reopened)
            assertEquals("the outbound frame must survive the reboot", 1, held.size)
            assertEquals(
                "*** AND IT MUST SURVIVE THE REBOOT AS THE SAME AUTHORED BYTES. ***",
                authoredBytes.toList(), held.first().encode().toList(),
            )

            // *** THE DURABLE RECIPIENT BINDING, READ THROUGH A TRACKER OVER THE REOPENED ENGINE. ***
            val tracker = DeliveryTracker(
                SqliteDeliveryRepository(reopened.engine),
                Ed25519AckAuthenticator(MutableKeyTable()),
            )
            val found = tracker.lookup(msgId)
            assertTrue("the delivery row must survive the reboot", found is DeliveryLookup.Found)
            val record = (found as DeliveryLookup.Found).record
            assertEquals(
                "*** THE HISTORICAL SEND INTENT MUST SURVIVE: SINGLE_RECIPIENT with the authored recipient. ***",
                AckMode.SINGLE_RECIPIENT, record.ackMode,
            )
            assertEquals(
                "*** AND THE EXACT RECIPIENT NODE ID MUST SURVIVE -- a durable binding that drifted would let a "
                    + "stranger ACK the message. ***",
                recipient.toList(), record.expectedRecipientNodeId!!.toList(),
            )
            assertEquals(DeliveryState.QUEUED_DURABLY, record.state)
            assertNotEquals("the recipient is not the local origin", recipient.toList(), localNode.toList())
        } finally {
            reopened.close()
        }
    }

    /**
     * *** (3) ONE TRACKER OBJECT REPORTS THE ROW ACROSS ITS WHOLE LIFECYCLE. ***
     *
     * *Where the contract is "the SAME object observes each mutation", this arm walks QUEUED -> HANDED -> ACKNOWLEDGED
     * through one tracker instance and reads after every step -- so a tracker that had been rebuilt between steps
     * cannot pass.*
     */
    @Test
    fun oneTrackerObjectReportsTheRowAcrossItsWholeLifecycle() {
        val identity = MeshIdentity.generate()
        val store = SqliteMessageStore(JdbcStoreDb(freshFile("lifecycle.db")), 1L shl 20, null)
        try {
            val resolver = MutableKeyTable().apply { put(identity.nodeId, identity.identityPub) }
            val tracker = DeliveryTracker(SqliteDeliveryRepository(store.engine), Ed25519AckAuthenticator(resolver))
            val msgId = ByteArray(16) { (it + 33).toByte() }
            val frame = FrameV2(
                type = TypeV2.MESSAGE,
                msgId = msgId,
                routingTag = msgId.copyOfRange(0, 4),
                ttl = FrameV2.DEFAULT_TTL,
                hopCount = 0,
                flags = FrameV2.SEALED or Priority.toFlags(Priority.DIRECT),
                payload = ByteArray(120) { (it + 9).toByte() },
            )
            // *** THE REAL OUTBOUND ROAD: the held frame AND the delivery row commit atomically. A bare enqueue would
            // create only the row, and the ACK's atomic held-retire would then fail closed (Corrupt). ***
            assertTrue(
                "the direct message must be durably enqueued",
                runBlocking { store.enqueueDirectOutbound(frame, identity.nodeId, ByteArray(16) { 0x5A }) }
                    is OutboundEnqueueResult.Created,
            )
            assertEquals(
                "queued state, read through the same tracker",
                DeliveryState.QUEUED_DURABLY, (tracker.lookup(msgId) as DeliveryLookup.Found).record.state,
            )

            assertEquals(
                "*** THE SAME OBJECT MUST OBSERVE THE HAND-OFF. ***",
                TransitionResult.Applied, tracker.markHanded(msgId),
            )
            assertEquals(
                "*** AND ITS OWN NEXT READ MUST SHOW THE ADVANCE -- proof the object, not a copy, walked the row. ***",
                DeliveryState.HANDED_TO_RELAY, (tracker.lookup(msgId) as DeliveryLookup.Found).record.state,
            )

            val ack = AckFrame.build(
                msgId = msgId,
                recipientSigningPrivKey = identity.identityPriv,
                recipientNodeId = identity.nodeId,
                routingTag = msgId.copyOfRange(0, 4),
                ttl = ACK_INITIAL_TTL,
            )
            assertEquals(
                "*** THE AUTHENTICATED ACK MUST ADVANCE THE SAME ROW. ***",
                AckResult.Applied, tracker.acknowledge(msgId, ack),
            )
            assertEquals(
                "*** AND THE TERMINAL STATE MUST BE VISIBLE THROUGH THE IDENTICAL TRACKER OBJECT. ***",
                DeliveryState.ACKNOWLEDGED_BY_RECIPIENT, (tracker.lookup(msgId) as DeliveryLookup.Found).record.state,
            )
            // A replayed ACK is idempotent on the SAME object -- never a second verification.
            assertEquals(AckResult.AlreadyAcknowledged, tracker.acknowledge(msgId, ack))
        } finally {
            store.close()
        }
    }

    /**
     * *** (4) A MID-TRANSACTION FAULT LEAVES THE PRE-STATE EXACTLY AS IT STOOD -- AND THE ROLLBACK IS DURABLE. ***
     *
     * *The pre-persist durable view is captured BEFORE the faulting persist; after `FAILED_STORAGE` the view must be
     * UNCHANGED, and it must still be unchanged after a close/reopen -- so a half-written row cannot survive a crash.*
     */
    @Test
    fun aMidTransactionFaultLeavesThePreStateAndTheRollbackIsDurable() {
        val file = freshFile("fault.db")
        val survivorId = ByteArray(16) { 0x01 }
        val faultedId = ByteArray(16) { 0x02 }
        val survivor = inboundFrame(survivorId, ByteArray(60) { 0x11 })
        val faulted = inboundFrame(faultedId, ByteArray(60) { 0x22 })

        val store = SqliteMessageStore(JdbcStoreDb(file), 1L shl 20, null)
        try {
            assertEquals(PersistResult.HELD_NEW, runBlocking { store.persist(survivor, ByteArray(16)) })
            // *** THE PRE-STATE: the durable view before the transformation that will fail. ***
            val preState = heldFrames(store).map { it.msgId.toList() }
            assertEquals("the rig must hold exactly the survivor", 1, preState.size)

            val faultedResult = runBlocking {
                store.persistAtWithFault(faulted, ByteArray(16), 1234L) { phase ->
                    if (phase == "after_insert") throw RuntimeException("injected fault after insert")
                }
            }
            assertEquals(
                "*** A THROWN FAULT MUST ROLL BACK AND REPORT FAILED_STORAGE, NEVER THROW. ***",
                PersistResult.FAILED_STORAGE, faultedResult,
            )
            assertEquals(
                "*** THE PRE-STATE MUST BE UNCHANGED: no half-inserted row may survive the rollback. ***",
                preState, heldFrames(store).map { it.msgId.toList() },
            )
            assertNull("and the faulted row must not be present", store.engine.readHeld(faultedId))
        } finally {
            store.close()
        }

        val reopened = SqliteMessageStore(JdbcStoreDb(file), 1L shl 20, null)
        try {
            assertEquals(
                "*** AND THE ROLLBACK MUST BE DURABLE: the faulted row is still absent after a reboot. ***",
                listOf(survivorId.toList()), heldFrames(reopened).map { it.msgId.toList() },
            )
        } finally {
            reopened.close()
        }
    }

    /**
     * *** (5) EVERY WIRE FIELD'S REAL VALUE SURVIVES THE ENCODE/DECODE TRANSFORMATION. ***
     *
     * *The pre-representation values are captured BEFORE encoding; after decoding the captured frame, each field must
     * equal its captured value -- and a mutated payload must produce a DIFFERENT decoded value, so the round-trip is
     * not trivially satisfied by a constant.*
     */
    @Test
    fun everyWireFieldsRealValueSurvivesTheEncodeDecodeTransformation() {
        val msgId = ByteArray(16) { (it + 7).toByte() }
        val routingTag = ByteArray(4) { (it + 100).toByte() }
        val payload = ByteArray(333) { (it + 2).toByte() }
        val original = FrameV2(
            type = TypeV2.MESSAGE, msgId = msgId, routingTag = routingTag,
            ttl = 12, hopCount = 3, flags = FrameV2.SEALED or Priority.toFlags(Priority.DIRECT), payload = payload,
        )
        // *** CAPTURE EVERY REAL FIELD VALUE BEFORE THE TRANSFORMATION. ***
        val capturedType = original.type
        val capturedMsgId = original.msgId
        val capturedTag = original.routingTag
        val capturedTtl = original.ttl
        val capturedHop = original.hopCount
        val capturedFlags = original.flags
        val capturedPayload = original.payload

        val decoded = FrameV2.decode(original.encode())
        assertTrue("a well-formed frame must decode", decoded != null)
        val d = decoded!!
        assertEquals("type survives the transformation", capturedType, d.type)
        assertEquals("msg_id survives", capturedMsgId.toList(), d.msgId.toList())
        assertEquals("routing_tag survives", capturedTag.toList(), d.routingTag.toList())
        assertEquals("ttl survives", capturedTtl, d.ttl)
        assertEquals("hop_count survives", capturedHop, d.hopCount)
        assertEquals("flags survive", capturedFlags, d.flags)
        assertEquals("payload survives byte-for-byte", capturedPayload.toList(), d.payload.toList())
        assertEquals("and the decoded priority is the captured one", Priority.DIRECT, Priority.fromFlags(d.flags))

        // A mutation must produce a DIFFERENT transformation result -- the round-trip cannot be a constant.
        val mutated = original.copy(payload = ByteArray(333) { 0x7F })
        val mutatedDecoded = FrameV2.decode(mutated.encode())!!
        assertNotEquals(
            "*** A MUTATED PAYLOAD MUST SURVIVE AS THE MUTATION -- proof the round-trip carries the value, not a "
                + "constant. ***",
            d.payload.toList(), mutatedDecoded.payload.toList(),
        )
        // Corrupted bytes must FAIL CLOSED -- never half-parse into a different message.
        val corrupted = original.encode().also { it[10] = (it[10] + 1).toByte() }
        assertEquals(
            "*** A CORRUPTED HEADER MUST FAIL CLOSED. *A frame that decoded despite a mutated magic/version/CRC "
                + "would be a desync hazard.* ***",
            null, FrameV2.decode(corrupted),
        )
    }

    /**
     * *** (6) AN ACK CANDIDATE'S SIGNED BYTES SURVIVE A REAL CLOSE/REOPEN OF THE ACK NAMESPACE. ***
     *
     * *The captured signature and encoded frame are the pre-transformation values; stored through the REAL
     * `SqliteAckStore` and read back after a reopen, every field must equal its captured value and the cache key must
     * re-derive from them.*
     */
    @Test
    fun anAckCandidatesSignedBytesSurviveACloseReopen() {
        val file = freshFile("ack-ns.db")
        val identity = MeshIdentity.generate()
        val msgId = ByteArray(16) { (it + 44).toByte() }
        val frame = AckFrame.build(
            msgId = msgId,
            recipientSigningPrivKey = identity.identityPriv,
            recipientNodeId = identity.nodeId,
            routingTag = msgId.copyOfRange(0, 4),
            ttl = ACK_INITIAL_TTL,
        )
        // *** THE PRE-TRANSFORMATION VALUES: the exact signed bytes and the derived cache key. ***
        val encoded = frame.encode()
        val signature = frame.payload.copyOfRange(0, 64)
        val ackKey = AckCacheKey.compute(msgId, identity.nodeId, signature)!!

        val record = AckFrameRecord.of(
            ackKey = ackKey,
            msgId = msgId,
            recipientNodeId = identity.nodeId,
            signature = signature,
            encodedFrame = encoded,
            receivedFrom = null,
            remainingLifetimeMs = 60_000L,
            verificationClass = AckVerificationClass.VERIFIED_RECIPIENT,
        )!!
        val engine = JdbcStoreDb(file)
        try {
            assertEquals(
                "the candidate must be stored (not a duplicate)",
                io.godstone.mesh.delivery.AckAdmissionResult.Stored::class.java,
                SqliteAckStore(engine).storeCandidate(record).javaClass,
            )
        } finally {
            engine.close()
        }

        val reopenedEngine = JdbcStoreDb(file)
        try {
            val lookup = SqliteAckStore(reopenedEngine).lookupByAckKey(ackKey)
            assertTrue("the candidate must survive the reopen", lookup is FrameLookup.Found)
            val stored = (lookup as FrameLookup.Found).record
            assertEquals("*** the signature survives ***", signature.toList(), stored.signature.toList())
            assertEquals("*** the encoded frame survives byte-for-byte ***", encoded.toList(), stored.encodedFrame.toList())
            assertEquals("*** the recipient binding survives ***", identity.nodeId.toList(), stored.recipientNodeId.toList())
            assertEquals("*** the msg_id survives ***", msgId.toList(), stored.msgId.toList())
            assertEquals("the verification class survives", AckVerificationClass.VERIFIED_RECIPIENT, stored.verificationClass)
            assertEquals("and the cache key re-derives from the stored signature",
                ackKey.toList(), AckCacheKey.compute(stored.msgId, stored.recipientNodeId, stored.signature)!!.toList())
        } finally {
            reopenedEngine.close()
        }
    }
}
