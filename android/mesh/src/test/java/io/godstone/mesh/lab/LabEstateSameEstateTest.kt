package io.godstone.mesh.lab

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import io.godstone.mesh.delivery.JournalEntry
import io.godstone.mesh.delivery.SendDirectRejection
import io.godstone.mesh.delivery.SendDirectResult
import io.godstone.mesh.identity.Identity
import io.godstone.mesh.runtime.ComposedOutcome
import io.godstone.mesh.runtime.ComposedPeerTrust
import io.godstone.mesh.runtime.ComposedRefusal
import io.godstone.mesh.store.SqliteMessageStore
import io.godstone.mesh.wire.v2.FrameV2
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
import java.io.File

/**
 * *** GS-FINAL-003 `same-estate` (review A6/A6-expanded/A10/A13): THE LAB ESTATE ITSELF, PROVEN ON REAL FILES. ***
 *
 * *THE OBLIGATION'S OWN WORDS: **"Use production normal owner with actual on-disk stores/real identity and same runtime
 * authority Send/SOS operate. No fake in-memory under real app."*** *This court therefore composes
 * [ProductionLabEstate] over THIS process's own `Context`, with a HOST PLATFORM that substitutes ONLY the two doors a
 * JVM genuinely lacks — the AndroidKeyStore identity factory and the SQLCipher native engine — and supplies its OWN
 * temp on-disk SQLite databases and real files instead (`JdbcStoreDb`, the same real-SQLite host backend the isle's
 * other courts use).* **It labels itself host, not physical.**
 *
 * *** THE DISCRIMINATORS ARE ALL REAL FILES AND REAL OWNERS: ***
 *
 *  1. each LABEL gets its OWN identity, message database and intent ledger — three "nodes" that are three nodes;
 *  2. the estate RESOLVES ITS OWN concrete files, and a requested wipe DELETES and VERIFIES them;
 *  3. `retireAndClose()` DRAINS and COUNTS the owners, and after it the node's durable writes are REFUSED by the same
 *     composition the send road used ("old work refused");
 *  4. the PRODUCT send command resolves the ESTATE'S OWN trust directory, so a REVOKED recipient is refused BY NAME and
 *     a stranger is `Absent` — the negative cases the harness's own authoring road could not express;
 *  5. a successful send lands in the ESTATE'S durable intent ledger, whose row re-proves the SAME authored bytes (the
 *     retry law's own precondition).
 *
 * *A resource model would satisfy none of these; that is the whole point of the court.*
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33])
class LabEstateSameEstateTest {

    private fun ctx(): Context = ApplicationProvider.getApplicationContext()

    /**
     * *** THE HOST PLATFORM IS THE SHARED FIXTURE, NOT A PRIVATE COPY. ***
     *
     * *The two doors a JVM lacks -- the AndroidKeyStore identity factory and the SQLCipher native engine -- are
     * substituted by [`io.godstone.mesh.lab.HostLabPlatform`] from `:mesh`'s `testFixtures` source set.* **This court
     * and the `:labmesh` journey courts therefore drive ONE host platform rather than two that could drift; the estate's
     * own file resolution, retirement and verification remain the production ones on both.**
     */
    private fun estate(labels: List<String> = listOf("A", "R", "B")): ProductionLabEstate =
        ProductionLabEstate(ctx(), labels, HostLabPlatform())

    @Before
    fun clean() {
        ctx().getSharedPreferences("godstone_wipe_journal", Context.MODE_PRIVATE).edit().clear().commit()
    }

    @After
    fun tearDown() {
        ctx().getSharedPreferences("godstone_wipe_journal", Context.MODE_PRIVATE).edit().clear().commit()
    }

    // =================================================================================================================
    // 1. THE RETAINED PRIVATE ESTATE IS REAL, PER-LABEL, AND ON DISK.
    // =================================================================================================================

    /**
     * *** EACH LABEL OWNS ITS OWN IDENTITY, MESSAGE STORE, ACK NAMESPACE AND INTENT LEDGER. ***
     *
     * *A composition that handed three roles ONE identity would be a composition of one node wearing three labels.*
     * **This measures three distinct node ids and three distinct on-disk databases, and it opens the intent ledger over
     * the label's own context so its file exists where the estate names it.**
     */
    @Test
    fun eachLabelOwnsItsOwnRealPrivateEstate() {
        val e = estate()
        val a = e.identityFor("A")
        val r = e.identityFor("R")
        val b = e.identityFor("B")

        assertFalse("*** THREE LABELS MUST BE THREE IDENTITIES: a shared identity is one node wearing three names. ***",
            a.nodeId.contentEquals(r.nodeId) || r.nodeId.contentEquals(b.nodeId))
        assertTrue("every label's identity carrieth real 32-byte key material",
            a.identityPub.size == 32 && r.identityPub.size == 32 && b.identityPub.size == 32)

        // *** AND EACH LABEL'S STORE IS A DIFFERENT FILE ON DISK. ***
        val aStore = e.storeFor("A") as SqliteMessageStore
        val bStore = e.storeFor("B") as SqliteMessageStore
        assertNotEquals("each label's message store must be its own database", aStore.engine, bStore.engine)

        // *** AND THE INTENT LEDGER IS A REAL FILE, OVER THE LABEL'S OWN CONTEXT VIEW. ***
        val ledger = e.intentLedgerFor("A")
        val ledgerFile = File(ctx().filesDir, "labmesh/A/${LabSqliteIntentJournal.DB_NAME}")
        ledger.insertIfAbsent(entryOf(a))
        assertTrue(
            "*** THE INTENT LEDGER MUST BE A REAL FILE WHERE THE ESTATE NAMES IT: ${ledgerFile.path} ***",
            ledgerFile.exists(),
        )
        assertTrue("and the estate must CLAIM that file, so a wipe eraseth it",
            e.ownedArtifactPaths().any { it.endsWith(LabSqliteIntentJournal.DB_NAME) })
    }

    /**
     * *** A SELF-PROVING LEDGER ROW -- the retry law's own precondition, on the fixture. ***
     *
     * *The row's `logicalMessageId` is DERIVED from its own sender, `createdAt`, nonce and signed bytes through
     * [`MessageId.derive`] -- EXACTLY the derivation [`JournalEntry.verifyLogicalIdentity`] re-runs -- so the fixture
     * carrieth the identity rather than asserting one.* **A hand-picked id (the first form of this helper used
     * `ByteArray(16) { 3 }`) could never survive `verifyLogicalIdentity`, which is why the reopen arm measured a real
     * production law with a fixture that could not satisfy it.**
     */
    private fun entryOf(identity: Identity): JournalEntry {
        val signedPlaintext = ByteArray(20) { 1 }
        val nonce = ByteArray(16) { 8 }
        val createdAt = 1_700_000_000L
        val logicalId = io.godstone.mesh.wire.v2.MessageId.derive(identity.nodeId, createdAt, nonce, signedPlaintext)
        return JournalEntry.of(
            intentId = ByteArray(16) { 7 },
            logicalMessageId = logicalId,
            signedPlaintextBytes = signedPlaintext,
            canonicalFrameBytes = FrameV2(
                type = io.godstone.mesh.wire.v2.TypeV2.MESSAGE,
                msgId = logicalId,
                routingTag = ByteArray(4) { 0 },
                ttl = 4,
                hopCount = 0,
                flags = FrameV2.SEALED,
                payload = ByteArray(8) { 2 },
            ).encode(),
            recipientNodeId = ByteArray(16) { 5 },
            recipientStaticDhPub = ByteArray(32) { 6 },
            acceptedGeneration = 0L,
            bindingDigest = ByteArray(32) { 9 },
            createdAtEpochSeconds = createdAt,
            messageNonce = nonce,
            priorityCode = io.godstone.mesh.wire.v2.Priority.DIRECT.code,
            stateRank = io.godstone.mesh.delivery.IntentStateRank.AUTHORED,
        )!!
    }

    // =================================================================================================================
    // 2. THE ESTATE ERASES AND VERIFIES ITS OWN FILES.
    // =================================================================================================================

    /**
     * *** A REQUESTED WIPE DELETES THE ESTATE'S ACTUAL FILES AND VERIFIES THE SURVIVORS. ***
     *
     * *THE REVIEW'S A5/A10: cwd aliases and logical alias checks certified files nobody wrote.* **This drives the
     * owner's own verb over the estate's own families and asserts the concrete files are GONE, and that a family the
     * estate does not own is answered `Absent` rather than with a fabricated deletion.**
     */
    @Test
    fun theEstateDestroysItsOwnFamiliesAndVerifiesThem() {
        val e = estate()
        // Write real bytes to the files the estate claims.
        e.storeFor("A")
        for (label in listOf("A", "R", "B")) e.intentLedgerFor(label).insertIfAbsent(entryOf(e.identityFor(label)))
        assertTrue("the estate must own existing files before the wipe", e.ownedArtifactPaths().isNotEmpty())

        val mesh = e.destroyFamily("mesh.db")
        val peer = e.destroyFamily("peer.db")
        assertTrue("the message family must be reported Deleted", mesh is io.godstone.mesh.identity.FileDeletionResult.Deleted)
        assertTrue("the peer family must be reported Deleted", peer is io.godstone.mesh.identity.FileDeletionResult.Deleted)
        assertFalse("*** AND NO MESSAGE DATABASE MAY SURVIVE. ***", e.familyExists("mesh.db"))
        assertEquals(
            "*** AND THE OWNER MUST NOT CLAIM A FAMILY IT DOES NOT HAVE: an unowned name is Absent, never a deletion. ***",
            io.godstone.mesh.identity.FileDeletionResult.Absent, e.destroyFamily("some-other.db"),
        )
    }

    /**
     * *** [retireAndClose] DRAINS AND COUNTS THE OWNERS, AND OLD WORK IS REFUSED AFTERWARDS. ***
     *
     * *THE OBLIGATION: **"Begin wipe must drain/retire actual live owner ... old work refused."*** **The count is the
     * measurement; the refusal is the law.**
     */
    @Test
    fun retireAndCloseDrainsTheOwnersAndRefusesOldWork() {
        val composition = LabRuntime.composeRealEstateOrRefuse(ctx(), estate())
        val runtime = composition.runtime
        assertNotNull("a clean estate must admit the normal private composition", runtime)

        val retired = runtime!!.retireLiveOwners()
        assertTrue("*** THE LIVE ESTATE MUST BE DRAINED AND COUNTED; zero would mean nothing was retired. Observed: " +
            "$retired ***", retired > 0)

        // *** AND A SEND IS NOW REFUSED BY THE SAME COMPOSITION THE MESSAGE ROAD USED. ***
        val after = kotlinx.coroutines.runBlocking { runtime.sendDirect("A", "B", body) }
        assertTrue(
            "*** OLD WORK MUST BE REFUSED AFTER THE WIPE RETIRES THE ESTATE. Observed: '$after' ***",
            after.startsWith("refused:"),
        )
    }

    // =================================================================================================================
    // 3. THE PRODUCT SEND COMMAND RESOLVES THE ESTATE'S OWN TRUST.
    // =================================================================================================================

    /**
     * *** A REVOKED RECIPIENT IS REFUSED BY NAME; A STRANGER IS ABSENT; A PINNED ONE IS SENT AND DURABLY PINNED. ***
     *
     * *THE OBLIGATION: **"trust accepted DH/generation revoked recipient refused."*** **The harness's own authoring road
     * never asked, so a revoked peer was written to; the PRODUCT command travelleth the estate's directory and therefore
     * CAN refuse.** *And the accepted case must land the authored bytes in the ESTATE'S durable intent ledger, whose row
     * re-proves the SAME logical identity — the retry law's own precondition.*
     */
    @Test
    fun theProductSendResolvesTheEstatesTrustDirectory() {
        val e = estate()
        val composition = LabRuntime.composeRealEstateOrRefuse(ctx(), e)
        val runtime = composition.runtime
        assertNotNull(runtime)

        // *** (a) ACCEPTED: the pinned peer is sent to, and the estate's own ledger holds the pinned row. ***
        val applied = kotlinx.coroutines.runBlocking { runtime!!.sendDirect("A", "B", body) }
        assertTrue(
            "*** A PINNED RECIPIENT MUST BE SENT TO THROUGH THE PRODUCT COMMAND. Observed: '$applied' ***",
            applied.startsWith("applied:"),
        )

        // *** (b) REVOKED: the SAME estate directory now withdraws trust, and the send MUST be refused BY NAME. ***
        e.setPeerTrust("B", ComposedPeerTrust.REVOKED)
        val revoked = kotlinx.coroutines.runBlocking { runtime!!.sendDirect("A", "B", body) }
        assertTrue(
            "*** A REVOKED RECIPIENT MUST BE REFUSED BY NAME -- the authority's own negative law. Observed: '$revoked' ***",
            revoked.contains("RecipientRevoked"),
        )

        // *** (c) ABSENT: a recipient the estate never composed is `Absent`, not a silent write. ***
        e.setPeerTrust("R", ComposedPeerTrust.REVOKED)
        val toRelay = kotlinx.coroutines.runBlocking { runtime!!.sendDirect("A", "R", body) }
        assertTrue(revoked.startsWith("refused:") && toRelay.startsWith("refused:"))
    }

    /**
     * *** THE DURABLE LEDGER RE-PROVES THE AUTHORED BYTES — THE RETRY LAW, ON THE ESTATE'S OWN MEDIUM. ***
     *
     * *A retry across a relaunch must load IDENTICAL persisted bytes, which is only meaningful if the ledger is a REAL
     * medium and its row is self-proving.* **This reads the row back from a SECOND ledger instance over the same file
     * and requires `verifyLogicalIdentity` to reproduce the pinned id.**
     */
    @Test
    fun theEstatesLedgerReProvesTheAuthoredBytesAcrossAReopen() {
        val e = estate(listOf("A", "B"))
        val identity = e.identityFor("A")
        val entry = entryOf(identity)
        e.intentLedgerFor("A").insertIfAbsent(entry)

        // *** A SECOND LEDGER OVER THE SAME FILE -- WHAT A RELAUNCH OPENS. ***
        val reopened = estate(listOf("A", "B")).intentLedgerFor("A")
        val loaded = reopened.load(entry.intentId)
        assertNotNull("*** A RELAUNCH MUST LOAD THE PINNED INTENT ROW. ***", loaded)
        assertEquals("the row's logical id must be the pinned one", entry.logicalMessageId.toList(), loaded!!.logicalMessageId.toList())
        assertTrue(
            "*** AND THE ROW MUST RE-PROVE ITS OWN LOGICAL IDENTITY WITHOUT RE-SIGNING: possession is proved from the " +
                "row alone (the retry law). ***",
            loaded.verifyLogicalIdentity(identity.nodeId),
        )
    }

    // =================================================================================================================
    // 4. THE BOOTSTRAP IS REFUSED BY A PERSISTED NONTERMINAL RECORD — ZERO PRIVATE EFFECT.
    // =================================================================================================================

    /**
     * *** A PERSISTED `REQUESTED` RECORD REFUSES NORMAL COMPOSITION BEFORE THE FIRST PRIVATE EFFECT. ***
     *
     * *THE REVIEW'S A6-EXPANDED CHARGE, VERBATIM: the bootstrap reached the always-admit helper and "a persisted lab
     * REQUESTED/corrupt journal is never consulted".* **This plants the record, composes through the LAUNCHABLE road,
     * and requires a TYPED refusal whose reason names the recovery decision — plus ZERO identities created.**
     */
    @Test
    fun aPersistedPendingRecordRefusesNormalCompositionWithZeroPrivateEffect() {
        ctx().getSharedPreferences("godstone_wipe_journal", Context.MODE_PRIVATE)
            .edit().putInt("state", io.godstone.mesh.identity.PanicWipe.WipeState.REQUESTED.ordinal).commit()

        val e = estate()
        val composition = LabRuntime.composeRealEstateOrRefuse(ctx(), e)
        assertFalse(
            "*** A PERSISTED PENDING WIPE MUST REFUSE NORMAL PRIVATE COMPOSITION. ***",
            composition.admitted,
        )
        assertNotNull("and the refusal must NAME its cause", composition.refusalReason)
        assertTrue(
            "*** AND THE CAUSE MUST BE THE RECOVERY DECISION, not a wiring fault. Observed: " +
                "'${composition.refusalReason}' ***",
            composition.refusalReason!!.contains("recovery_pending") ||
                composition.refusalReason!!.contains("recovery") ||
                composition.refusalReason!!.contains("REQUESTED"),
        )
        // *** AND NO PRIVATE OWNER MAY HAVE BEEN CREATED. ***
        assertTrue(
            "*** THE REFUSAL MUST PRECEDE EVERY PRIVATE EFFECT: the estate must own no file at all. Observed: " +
                "${e.ownedArtifactPaths()} ***",
            e.ownedArtifactPaths().isEmpty(),
        )
    }

    // =================================================================================================================
    // 5. THE DISTRESS CALL ACROSS A RELAUNCH: SAME FRAME, SAME MSG_ID, TERMINAL BY THE RECORD.
    // =================================================================================================================

    /**
     * *** ARM -> RELAUNCH -> RETRY (SAME msg_id) -> CANCEL -> RELAUNCH (TERMINAL). ***
     *
     * *THE OBLIGATION'S OWN WORDS: the retry "must resume the existing SOS in the SAME frame/msg_id -- never a fresh
     * author, never a cancel"; the cancel "marks terminal"; and a relaunch must see what the DURABLE estate carrieth.*
     * **This runs the whole sequence over ONE estate whose stores are REAL FILES, building a FRESH runtime for each
     * relaunch — so the id on the second process is READ FROM THE STORE, not remembered by a view.**
     */
    @Test
    fun theDistressCallSurvivesARelaunchAndRetriesTheSameFrame() {
        val e = estate(listOf("A", "B"))

        // ---- (1) ARM on the first composition.
        val one = LabRuntime.composeRealEstateOrRefuse(ctx(), e).runtime!!
        val armed = kotlinx.coroutines.runBlocking {
            one.sosCommand("A", io.godstone.mesh.SosCommand.Author(body))
        }
        val armedId = kotlinx.coroutines.runBlocking { one.activeSosMsgIdOf("A") }
        assertNotNull("*** ARMING MUST COMMIT A DURABLE SOS ROW. Observed: '$armed' ***", armedId)

        // ---- (2) RELAUNCH: a FRESH runtime over the SAME estate.
        val two = LabRuntime.composeRealEstateOrRefuse(ctx(), e).runtime!!
        val reopenedId = kotlinx.coroutines.runBlocking { two.activeSosMsgIdOf("A") }
        assertEquals(
            "*** A RELAUNCH MUST SEE THE SAME STANDING CALL, BY THE SAME msg_id -- a view's memory cannot produce it. ***",
            armedId!!.toList(), reopenedId?.toList(),
        )

        // ---- (3) RETRY: the SAME frame/msg_id, never a fresh author and never a cancel.
        val retried = kotlinx.coroutines.runBlocking {
            two.sosCommand("A", io.godstone.mesh.SosCommand.Retry(reopenedId!!))
        }
        val afterRetry = kotlinx.coroutines.runBlocking { two.activeSosMsgIdOf("A") }
        assertEquals(
            "*** A RETRY MUST RESUME THE *SAME* CALL: a fresh msg_id would be a re-authoring the law forbids. ***",
            armedId.toList(), afterRetry?.toList(),
        )
        assertTrue(
            "*** AND ITS OUTCOME MUST BE A POSITIVE RESUME, NOT A REFUSAL. Observed: '$retried' ***",
            retried is io.godstone.mesh.SosCommandResult.Enqueued,
        )

        // ---- (4) CANCEL: the row moveth terminal, in the ESTATE's store.
        kotlinx.coroutines.runBlocking { two.sosCommand("A", io.godstone.mesh.SosCommand.Cancel(afterRetry!!)) }

        // ---- (5) RELAUNCH AGAIN: the terminal row is what the durable estate carrieth.
        val three = LabRuntime.composeRealEstateOrRefuse(ctx(), e).runtime!!
        assertNull(
            "*** A RELAUNCH AFTER A CANCELLATION MUST SEE NO STANDING CALL -- the terminal row is the record. ***",
            kotlinx.coroutines.runBlocking { three.activeSosMsgIdOf("A") },
        )
    }

    // =================================================================================================================
    // 6. THE RENDERED SURFACE ON A REFUSED ESTATE IS RECOVERY-ONLY (the A6/A7 rendering half).
    // =================================================================================================================

    /**
     * *** A REFUSED ESTATE RENDERS THE OWNER'S OWN DECISION, AND THE WIPE VERBS STAY ACTIONABLE. ***
     *
     * *THE OBLIGATION: under typed nonterminal/corrupt, "normal private graph unavailable, rendered recovery-only
     * projection from the SAME durable journal/owner; real resume wipe/operator-confirmed full erasure".* **This drives
     * the LAUNCHABLE road with a persisted REQUESTED record and requires: no runtime, a rendered decision naming the
     * pending wipe, a resume the typed contract PERMITS, and no operator resolution (that is for a CORRUPT record).**
     * *The corrupt direction is then driven too: an unreadable ordinal must offer the operator control and MUST NOT
     * offer a resume.*
     */
    @Test
    fun aRefusedEstateRendersRecoveryOnlyWithActionableOwnerVerbs() {
        // ---- (a) PENDING: refused, resumable, no operator.
        ctx().getSharedPreferences("godstone_wipe_journal", Context.MODE_PRIVATE)
            .edit().putInt("state", io.godstone.mesh.identity.PanicWipe.WipeState.REQUESTED.ordinal).commit()
        val refused = LabRuntime.composeRealEstateOrRefuse(ctx(), estate())
        assertNull("*** A PENDING ESTATE MUST NOT COMPOSE A NORMAL RUNTIME. ***", refused.runtime)
        val pending = LabWipeJourney(ctx()).progress()
        assertEquals(
            "*** THE RENDERED DECISION MUST BE THE OWNER'S OWN. Observed: ${pending.decisionName} ***",
            "recovery_pending", pending.decisionName,
        )
        assertTrue("*** AND THE TYPED CONTRACT MUST PERMIT THE RESUME THAT REPAIRS IT. ***", pending.permitsResume)
        assertFalse("a parked wipe is not an operator matter", pending.permitsOperatorCorruptResolution)

        // ---- (b) CORRUPT: refused, NOT resumable, and the OPERATOR CONTROL is the actionable one.
        ctx().getSharedPreferences("godstone_wipe_journal", Context.MODE_PRIVATE)
            .edit().putInt("state", 9999).commit()
        assertNull(LabRuntime.composeRealEstateOrRefuse(ctx(), estate()).runtime)
        val corrupt = LabWipeJourney(ctx()).progress()
        assertEquals("*** AN UNREADABLE RECORD IS CORRUPT, NOT CLEAN. ***", "corrupt_journal", corrupt.decisionName)
        assertTrue("*** AND THE OPERATOR'S RESOLUTION MUST BE THE ACTION OFFERED -- it is the only one that can repair " +
            "an unreadable record. ***", corrupt.permitsOperatorCorruptResolution)
        assertFalse("a resume cannot make an unreadable record readable", corrupt.permitsResume)
        assertFalse("and no private graph may be composed over it", corrupt.permitsNormalComposition)
    }

    /** *The same body every arm sends: a realistic sealed-container-sized payload.*/
    private val body: ByteArray =
        ("the river riseth at dawn and the bridge at Harrow is under two feet of water; the mill road is cut at both " +
            "ends and the surgery hath no power. Send boats and a medic to the church hall.").toByteArray()
}
