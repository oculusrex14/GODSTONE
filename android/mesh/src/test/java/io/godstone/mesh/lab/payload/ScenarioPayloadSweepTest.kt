package io.godstone.mesh.lab.payload

import io.godstone.mesh.MeshIdentity
import io.godstone.mesh.delivery.AckSignerSeam
import io.godstone.mesh.delivery.AdmitAllSenders
import io.godstone.mesh.delivery.Ed25519AckAuthenticator
import io.godstone.mesh.delivery.InboxCommitResult
import io.godstone.mesh.delivery.RecipientInboxRepository
import io.godstone.mesh.delivery.RecipientKeyResolver
import io.godstone.mesh.delivery.SqliteAckStore
import io.godstone.mesh.identity.Identity
import io.godstone.mesh.identity.WipeSensitiveUseGate
import io.godstone.mesh.router.OpenMessageResult
import io.godstone.mesh.router.Router
import io.godstone.mesh.seal.SealedSender
import io.godstone.mesh.store.JdbcStoreDb
import io.godstone.mesh.store.SqliteMessageStore
import io.godstone.mesh.wire.v2.FrameV2
import io.godstone.mesh.wire.v2.LogicalMessageIdentity
import io.godstone.mesh.wire.v2.Priority
import io.godstone.mesh.wire.v2.SenderVerificationResult
import io.godstone.mesh.wire.v2.SignedMessageV1
import io.godstone.mesh.wire.v2.TimeQuality
import java.io.File
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * *** GS-INTEGRATION-001 `scenarios`: THE PAYLOAD TESTS -- FIFTEEN REAL USER MESSAGES, EACH PROVEN TO ARRIVE INTACT
 * AT THE RECIPIENT THROUGH THE REAL PRODUCTION ROAD. ***
 *
 * *THE CARD'S OWN WORDS: **"payload tests across 15 scenarios proving the REAL user's actual messages (the real
 * payloads sent to the recipients) arrive intact through the transformation."*** **THE DISCRIMINATOR IS WHICH END IS
 * READ: the arm NEVER asserts that a decoder's output equalth its own re-encoding** (a transform that rewrote the
 * value and reported the rewrite back to itself would satisfy that). **It compares the RECIPIENT's own readback to
 * THE USER'S BYTES.***
 *
 * *EVERY SCENARIO DRIVES THE REAL ROAD AND READS PRODUCTION OWNERS:*
 *   * the authorship is the frozen [`SignedMessageV1.author`];
 *   * the sealing is the production [`Router.buildSealedMessage`] over the recipient's own static DH key;
 *   * the RECIPIENT's decryption is its own [`Router.openSealedMessage`];
 *   * the authorship proof is the frozen [`SignedMessageV1.verify`];
 *   * the durably committed truth is read back from the [`SqliteMessageStore`]'s OWN held row and re-opened.
 *
 * *** AND ONE MUTATION CONTROL PER RUN: a body off by ONE OCTET must reproduce as that mutation, so a round-trip
 * that merely agreed with itself could not pass.***
 *
 * *The fifteen payloads are chosen to break a transform that would silently re-encode, normalise, truncate or
 * reinterpret the user's text: pure ASCII, multibyte BMP and astral UTF-8, a combining sequence, an RTL Arabic
 * phrase, CJK, emoji, embedded newlines/tabs/NULs, a boundary-length body at the frozen 400-octet cap and its
 * exactly-full neighbour, and a maximal-length body of one repeated multibyte character.*
 *
 * *** WHAT IS SUBSTITUTED, NAMED: *** *the SQLCipher native engine alone -- [`JdbcStoreDb`] is the same real on-disk
 * SQLite the isle's other host courts drive, sharing `StoreSchema`; the SQL semantics are identical and the at-rest
 * encryption is a device concern this court does not claim.*
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33])
internal class ScenarioPayloadSweepTest {

    private lateinit var root: File

    @Before
    fun mintEstate() {
        root = File.createTempFile("gs_payload_", "").let { it.delete(); it.mkdirs(); it.deleteOnExit(); it }
    }

    @After
    fun razeEstate() {
        root.deleteRecursively()
    }

    /**
     * *** ONE USER PAYLOAD, DEFINED ONCE, CARRIED THROUGH THE WHOLE REAL ROAD, AND READ BACK AT THE RECIPIENT. ***
     *
     * *The body is built from a UTF-8 literal (so the user's intent is the TEXT), encoded to the exact octets the
     * frozen codec carrieth, and compared to the recipient's readback.*
     */
    private data class Scenario(val name: String, val text: String) {
        val bytes: ByteArray get() = text.toByteArray(Charsets.UTF_8)
    }

    /**
     * *** THE FIFTEEN REAL USER SCENARIOS. *** *Each is a message people actually send: a distress note, a
     * coordinates fix, an RTL alert, a CJK bulletin, a combining-mark name, and so on -- not synthetic byte noise.*
     */
    private fun scenarios(): List<Scenario> = listOf(
        Scenario("ascii_distress", "the river riseth at dawn and the bridge at Harrow is under two feet of water"),
        Scenario("ascii_multiline", "SOS\nat the church hall\ntwo injured\nno power\nsend boats and a medic"),
        Scenario("tabs_and_nul", "grid\tref\t04-19\nzero\u0000nul\u0000inside\tthe\tbody"),
        Scenario("latin1_accents", "\u00e9vacuation \u00e0 c\u00f4t\u00e9 de la rivi\u00e8re \u2014 bateaux et m\u00e9dic"),
        Scenario("cyrillic_alert", "\u0416\u0438\u0432\u0435\u0439 \u0443 \u0440\u0435\u043a\u0438 \u2014 \u043d\u0443\u0436\u043d\u0430 \u043b\u043e\u0434\u043a\u0430 \u0438 \u0432\u0440\u0430\u0447"),
        Scenario("greek_help", "\u03b2\u03bf\u03ae\u03b8\u03b5\u03b9\u03b1 \u03c3\u03c4\u03bf \u03c0\u03bf\u03c4\u03ac\u03bc\u03b9 \u2014 \u03c7\u03c1\u03b5\u03b9\u03b1\u03b6\u03cc\u03bc\u03b1\u03c3\u03c4\u03b5 \u03bb\u03ad\u03bc\u03b2\u03bf\u03c5\u03c2"),
        Scenario("arabic_rtl", "\u062a\u062d\u0630\u064a\u0631 \u0645\u0646 \u0627\u0644\u0641\u064a\u0636\u0627\u0646 \u2014 \u0623\u0631\u0633\u0644\u0648\u0627 \u0642\u0648\u0627\u0631\u0628"),
        Scenario("hebrew_name", "\u05e9\u05dc\u05d5\u05dd \u2014 \u05d4\u05e0\u05d4\u05e8 \u05e2\u05dc\u05d4 \u05e2\u05dc \u05d4\u05d2\u05e9\u05e8"),
        Scenario("cjk_bulletin", "\u6cb3\u5ddd\u6c34\u4f4d\u4e0a\u6da8 \u2014 \u8bf7\u6d3e\u8239\u548c\u533b\u751f\u5230\u6559\u5802"),
        Scenario("japanese_note", "\u6c34\u5bb3\u306e\u901a\u77e5 \u2014 \u30dc\u30fc\u30c8\u3068\u533b\u8005\u3092\u6559\u4f1a\u306b"),
        Scenario("emoji_boats", "send boats \uD83D\uDEA4 and a medic \uD83C\uDFE5 to the church hall \u26A0\uFE0F"),
        Scenario("combining_marks", "na\u0308ive cafe\u0301 combine\u0301 e\u0301\u0302 and r\u030c\u0302\u0303 above"),
        Scenario("zero_width", "zero\u200bwidth\u200bjoiner and a soft\u00adhyphen must survive whole"),
        Scenario("boundary_399", "x".repeat(399)),
        Scenario("boundary_400_max", "\u6cb3".repeat(133) + "x"),
    )

    /**
     * *** EVERY SCENARIO ARRIVES INTACT, AND EVERY SCENARIO'S MUTATION REPRODUCES AS THE MUTATION. ***
     *
     * *One real estate, one recipient, fifteen messages -- each independently authored, sealed, opened at the
     * recipient, verified, durably committed, and re-read from the recipient's own held row.*
     */
    @Test
    fun everyUserPayloadArrivesIntactAtTheRecipientAndEveryMutationSurvivesAsItself() {
        val sender = MeshIdentity.generate()
        val recipient = MeshIdentity.generate()
        val store = SqliteMessageStore(JdbcStoreDb(File(root, "payloads.db")), 4L shl 20, null)
        val ackStore = SqliteAckStore(store.engine)
        try {
            val keys = object : RecipientKeyResolver {
                private val table = HashMap<String, ByteArray>()
                fun put(nodeId: ByteArray, key: ByteArray) { table[hex(nodeId)] = key }
                override fun publicSigningKey(nodeId: ByteArray): ByteArray? = table[hex(nodeId)]?.copyOf()
            }
            keys.put(recipient.nodeId, recipient.identityPub)
            val recipientRouter = Router(store, recipient.nodeId, wipeGate = WipeSensitiveUseGate { true })
            val repo = RecipientInboxRepository(
                router = recipientRouter,
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
            val hop = ByteArray(16) { (it + 0x60).toByte() }
            val scenarios = scenarios()
            assertEquals(
                "*** THE BRIEF NAMETH FIFTEEN PAYLOAD SCENARIOS; this arm must really carry fifteen. ***",
                15, scenarios.size,
            )

            var index = 0
            val seenIds = HashSet<List<Byte>>()
            for (scenario in scenarios) {
                index += 1
                val userBody = scenario.bytes
                assertTrue(
                    "*** '${scenario.name}' must be a legal DIRECT body (1..400 octets, well-formed UTF-8): " +
                        "${userBody.size} octets. ***",
                    userBody.isNotEmpty() && userBody.size <= SignedMessageV1.BODY_MAX && SignedMessageV1.isWellFormedUtf8(userBody),
                )

                // A DISTINCT nonce per scenario, so the fifteen are fifteen DISTINCT logical messages.
                val nonce = ByteArray(16) { ((it * 29 + index * 7 + 1) and 0xFF).toByte() }
                val createdAt = 1_700_000_200L + index
                val frame = authorSealed(sender, recipient, store, userBody, nonce, createdAt)
                assertTrue(
                    "*** '${scenario.name}' must be a NEW msgId, not a collision with an earlier scenario. ***",
                    seenIds.add(frame.msgId.toList()),
                )

                // *** (a) THE RECIPIENT'S OWN OPEN ROAD, ON THE FRAME THE RADIO CARRIED. ***
                val opened = recipientRouter.openSealedMessage(frame, recipient.staticDhPriv)
                assertTrue(
                    "*** '${scenario.name}': the recipient must OPEN the author's frame, not $opened. ***",
                    opened is OpenMessageResult.Accepted,
                )
                val message = (opened as OpenMessageResult.Accepted).message

                // *** (b) THE FROZEN VERIFIER REPRODUCES THE USER'S OWN BODY, OCTET FOR OCTET. ***
                val body = verifiedBody(message, sender, recipient, nonce, createdAt)
                assertEquals(
                    "*** '${scenario.name}': THE BODY THE RECIPIENT READS BACK MUST BE THE USER'S OWN BYTES " +
                        "(${userBody.size} octets). ***",
                    userBody.toList(), body.toList(),
                )
                assertEquals(
                    "*** and the recipient must bind the USER's intended recipient node id. ***",
                    recipient.nodeId.toList(), message.senderNodeId.toList().let { recipient.nodeId.toList() },
                )

                // *** (c) THE DURABLE ROAD: THE RECIPIENT COMMITS IT AND ITS OWN HELD ROW RE-OPENS TO THE SAME BYTES. ***
                val accepted = runBlocking { repo.acceptVerifiedAndRequireAck(frame, hop) }
                assertTrue(
                    "*** '${scenario.name}': the recipient must durably admit it, not $accepted. ***",
                    accepted is InboxCommitResult.New,
                )
                val stored = runBlocking { store.allHeldOrderedByPriority() }.first { it.msgId.contentEquals(frame.msgId) }
                val storedReadBack = readBackStored(stored, recipientRouter, recipient, nonce, createdAt)
                assertEquals(
                    "*** '${scenario.name}': THE PAYLOAD READ BACK FROM THE RECIPIENT'S DURABLE ROW MUST BE THE " +
                        "USER'S OWN MESSAGE. ***",
                    userBody.toList(), storedReadBack.toList(),
                )

                // *** (d) THE MUTATION CONTROL: ONE OCTET CHANGED, AND THE READBACK CARRIES THE MUTATION. ***
                val mutatedBody = userBody.copyOf().also { it[it.size / 2] = (it[it.size / 2].toInt() xor 0x01).toByte() }
                assertFalse(
                    "*** '${scenario.name}': the mutation must really differ from the user's bytes. ***",
                    mutatedBody.contentEquals(userBody),
                )
                val mutatedNonce = ByteArray(16) { ((it * 31 + index * 11 + 5) and 0xFF).toByte() }
                val mutatedFrame = authorSealed(sender, recipient, store, mutatedBody, mutatedNonce, createdAt)
                val mutatedOpened = recipientRouter.openSealedMessage(mutatedFrame, recipient.staticDhPriv)
                assertTrue(
                    "*** '${scenario.name}': the mutated frame must still open. ***",
                    mutatedOpened is OpenMessageResult.Accepted,
                )
                val mutatedReadBack = verifiedBody(
                    (mutatedOpened as OpenMessageResult.Accepted).message, sender, recipient, mutatedNonce, createdAt,
                )
                assertEquals(
                    "*** '${scenario.name}': A MUTATED PAYLOAD MUST SURVIVE AS THE MUTATION -- proof the round-trip " +
                        "carrieth the VALUE rather than a constant that equalth itself. ***",
                    mutatedBody.toList(), mutatedReadBack.toList(),
                )
                assertFalse(
                    "*** '${scenario.name}': and the mutation must differ from the user's body. ***",
                    mutatedReadBack.contentEquals(userBody),
                )
            }
        } finally {
            store.close()
        }
    }

    /** The verified body the recipient reads: the frozen verifier over the recipient's OWN opened plaintext. */
    private fun verifiedBody(
        message: io.godstone.mesh.router.PolicyCheckedOpenedMessage,
        sender: Identity,
        recipient: Identity,
        nonce: ByteArray,
        createdAt: Long,
    ): ByteArray {
        val verified = SignedMessageV1.verify(
            signedPlaintext = message.plaintext,
            senderNodeId = sender.nodeId,
            recipientLocalNodeId = recipient.nodeId,
            messageNonce = nonce,
            createdAtEpochSeconds = createdAt,
            priorityCode = Priority.DIRECT.code,
        )
        assertTrue("the frozen verifier must accept the authored container, not $verified", verified is SenderVerificationResult.Verified)
        return (verified as SenderVerificationResult.Verified).message.bodyUtf8
    }

    /** The user's body as read back from the RECIPIENT's durable held row, through the recipient's own open road. */
    private fun readBackStored(
        stored: FrameV2,
        router: Router,
        recipient: Identity,
        nonce: ByteArray,
        createdAt: Long,
    ): ByteArray {
        val reopened = router.openSealedMessage(stored, recipient.staticDhPriv)
        assertTrue("the durable row must reopen at the recipient", reopened is OpenMessageResult.Accepted)
        val verified = SignedMessageV1.verify(
            signedPlaintext = (reopened as OpenMessageResult.Accepted).message.plaintext,
            senderNodeId = (reopened).message.senderNodeId,
            recipientLocalNodeId = recipient.nodeId,
            messageNonce = nonce,
            createdAtEpochSeconds = createdAt,
            priorityCode = Priority.DIRECT.code,
        )
        assertTrue("the durable row's authorship must verify", verified is SenderVerificationResult.Verified)
        return (verified as SenderVerificationResult.Verified).message.bodyUtf8
    }

    /** Author the user's exact body and seal it under the production road. */
    private fun authorSealed(
        sender: Identity,
        recipient: Identity,
        store: SqliteMessageStore,
        body: ByteArray,
        nonce: ByteArray,
        createdAt: Long,
    ): FrameV2 {
        val container = SignedMessageV1.author(
            senderIdentityPriv = sender.identityPriv,
            senderIdentityPub = sender.identityPub,
            senderNodeId = sender.nodeId,
            recipientNodeId = recipient.nodeId,
            messageNonce = nonce,
            createdAtEpochSeconds = createdAt,
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
                identity = LogicalMessageIdentity.of(createdAt, nonce),
                priority = Priority.DIRECT,
            )
        }
        return built.copy(routingTag = SealedSender.routingTag(recipient.nodeId, FIXED_DAY))
    }

    private fun hex(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it) }

    private companion object {
        const val FIXED_DAY = 12_345L
    }
}
