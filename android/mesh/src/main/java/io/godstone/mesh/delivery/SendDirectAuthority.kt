// T36: Expose an atomic authored DIRECT send command.
//
// Hand-written product seam -- NOT a codegen artifact (the MessageId.kt / Priority.kt /
// SignedMessageV1.kt precedent): ci/check_parity.py Invariant A regenerates the wire codecs
// only from wire_v2.yaml; nothing here rewrites them. The authority COMPOSES the sealed
// authorities read-only: SignedMessageV1.author (T35, section 15) for the authorship binding,
// Router.buildSealedMessage for the canonical sealing formula over one pinned
// LogicalMessageIdentity, and MessageStore.enqueueDirectOutbound for the atomic durable
// transaction that pairs held_frames with the SINGLE_RECIPIENT delivery row.
//
// The card law, verbatim: Add SendDirect(recipientTrustRef, utf8Body) returning an immutable
// logical message ID ONLY AFTER durable enqueue. Resolve the current approved recipient
// key/version; generate ONE CSPRNG nonce; sign/seal ONCE; commit held frame + delivery row
// atomically. Retry loads identical persisted bytes; changed recipient/body/priority creates
// a NEW logical send. Enforce the 400-byte UTF-8 DIRECT body profile BEFORE signing.
// Regenerating the message nonce or the expected recipient during retry fails the logical
// identity test (section 14 row 13: "retry: load identical authored FrameV2 and immutable
// recipient policy"; section 14 row 3: a successful transaction yields a typed committed
// result; no correctness-critical query may return a fabricated empty set).

package io.godstone.mesh.delivery

import io.godstone.mesh.identity.Identity
import io.godstone.mesh.identity.PeerIdentityLookup
import io.godstone.mesh.identity.PeerTrustLevel
import io.godstone.mesh.router.Router
import io.godstone.mesh.store.MessageStore
import io.godstone.mesh.store.OutboundEnqueueResult
import io.godstone.mesh.wire.v2.FrameV2
import io.godstone.mesh.wire.v2.LogicalMessageIdentity
import io.godstone.mesh.wire.v2.MessageId
import io.godstone.mesh.wire.v2.Priority
import io.godstone.mesh.wire.v2.SignedMessageV1
import io.godstone.mesh.wire.v2.TimeQuality
import io.godstone.mesh.wire.v2.TypeV2
import kotlin.text.Charsets
import org.bouncycastle.crypto.digests.Blake2sDigest

/**
 * The UI command: an explicit intent token, a recipient trust reference, a UTF-8 body.
 * A double tap is TWO explicit intents (two tokens), never one mutated token; a retry of
 * the SAME token must load identical persisted bytes. Immutable: every field is a
 * defensive copy at construction and through every accessor. The toString is redacted --
 * no key material and no full payload bytes ever leak into a log line (privacy, section 5).
 */
class SendDirectCommand private constructor(
    intentId: ByteArray,
    recipientTrustRef: ByteArray,
    bodyUtf8: ByteArray,
) {
    private val _intentId: ByteArray = intentId.copyOf()
    private val _recipientTrustRef: ByteArray = recipientTrustRef.copyOf()
    private val _bodyUtf8: ByteArray = bodyUtf8.copyOf()

    /** The explicit intent token minted by the UI layer (1..INTENT_MAX bytes). Copy on read. */
    val intentId: ByteArray get() = _intentId.copyOf()

    /** Reference into the peer trust authority -- the recipient node id (16 bytes). Copy on read. */
    val recipientTrustRef: ByteArray get() = _recipientTrustRef.copyOf()

    /** The application body: 1..400 bytes of well-formed UTF-8 (profile-gated at the authority). */
    val bodyUtf8: ByteArray get() = _bodyUtf8.copyOf()

    companion object {
        const val INTENT_MAX: Int = 64

        /**
         * Well-formedness of the COMMAND SHAPE (not of the body profile -- the profile is
         * enforced by the authority BEFORE any signing, so that an oversize or malformed body
         * can never reach an authorship primitive). Returns null on a shape violation; the
         * caller turns null into a typed Rejected; no authoritative state is ever mutated on
         * a validation failure.
         */
        fun of(intentId: ByteArray, recipientTrustRef: ByteArray, bodyUtf8: ByteArray): SendDirectCommand? {
            if (intentId.isEmpty() || intentId.size > INTENT_MAX) return null
            if (recipientTrustRef.size != MessageId.NODE_ID_BYTES) return null
            return SendDirectCommand(intentId, recipientTrustRef, bodyUtf8)
        }
    }

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is SendDirectCommand) return false
        return _intentId.contentEquals(other._intentId) &&
            _recipientTrustRef.contentEquals(other._recipientTrustRef) &&
            _bodyUtf8.contentEquals(other._bodyUtf8)
    }

    override fun hashCode(): Int {
        var result = _intentId.contentHashCode()
        result = 31 * result + _recipientTrustRef.contentHashCode()
        result = 31 * result + _bodyUtf8.contentHashCode()
        return result
    }

    override fun toString(): String =
        "SendDirectCommand(intent=${redactedHex(_intentId)}, recipient=${redactedHex(_recipientTrustRef)}, body=${_bodyUtf8.size}B)"
}

/** Redaction helper: a 4-byte witness prefix plus the length -- enough to align a column, never enough to leak. */
private fun redactedHex(b: ByteArray): String {
    val n = minOf(4, b.size)
    val sb = StringBuilder(n * 2)
    for (i in 0 until n) sb.append(Character.forDigit((b[i].toInt() shr 4) and 0xF, 16)).append(Character.forDigit(b[i].toInt() and 0xF, 16))
    return sb.append("…(").append(b.size).append('B').toString()
}

/** The monotone journal rank ladder: AUTHORED < COMMITTED. A row may only climb one rung at a time. */
enum class IntentStateRank(val rank: Int) {
    AUTHORED(0),
    COMMITTED(1),
    ;

    companion object {
        fun fromRank(r: Int): IntentStateRank? = values().firstOrNull { it.rank == r }
    }
}

/**
 * The write-ahead intent ledger row: the pinned logical identity and the pinned canonical
 * bytes of one authored send. Self-verifying: the re-derivation of the logical message id over
 * the pinned (createdAt, messageNonce, signedPlaintext) must reproduce logicalMessageId --
 * possession is proved from the row alone, so a replay never needs to re-sign, re-seal,
 * re-resolve or re-create anything (the retry law, section 14 row 13).
 */
class JournalEntry private constructor(
    intentId: ByteArray,
    logicalMessageId: ByteArray,
    signedPlaintextBytes: ByteArray,
    canonicalFrameBytes: ByteArray,
    recipientNodeId: ByteArray,
    recipientStaticDhPub: ByteArray,
    acceptedGeneration: Long,
    bindingDigest: ByteArray,
    createdAtEpochSeconds: Long,
    messageNonce: ByteArray,
    priorityCode: Int,
    stateRank: IntentStateRank,
) {
    private val _intentId: ByteArray = intentId.copyOf()
    private val _logicalMessageId: ByteArray = logicalMessageId.copyOf()
    private val _signedPlaintext: ByteArray = signedPlaintextBytes.copyOf()
    private val _frameBytes: ByteArray = canonicalFrameBytes.copyOf()
    private val _recipientNodeId: ByteArray = recipientNodeId.copyOf()
    private val _recipientStaticDhPub: ByteArray = recipientStaticDhPub.copyOf()
    private val _bindingDigest: ByteArray = bindingDigest.copyOf()
    private val _messageNonce: ByteArray = messageNonce.copyOf()

    val intentId: ByteArray get() = _intentId.copyOf()
    val logicalMessageId: ByteArray get() = _logicalMessageId.copyOf()
    val signedPlaintextBytes: ByteArray get() = _signedPlaintext.copyOf()
    val canonicalFrameBytes: ByteArray get() = _frameBytes.copyOf()
    val recipientNodeId: ByteArray get() = _recipientNodeId.copyOf()
    val recipientStaticDhPub: ByteArray get() = _recipientStaticDhPub.copyOf()
    private val _acceptedGeneration: Long = acceptedGeneration
    private val _createdAt: Long = createdAtEpochSeconds
    private val _priorityCode: Int = priorityCode
    private val _stateRank: IntentStateRank = stateRank
    val acceptedGeneration: Long get() = _acceptedGeneration
    val bindingDigest: ByteArray get() = _bindingDigest.copyOf()
    val createdAtEpochSeconds: Long get() = _createdAt
    val messageNonce: ByteArray get() = _messageNonce.copyOf()
    val priorityCode: Int get() = _priorityCode
    val stateRank: IntentStateRank get() = _stateRank

    companion object {
        fun of(
            intentId: ByteArray,
            logicalMessageId: ByteArray,
            signedPlaintextBytes: ByteArray,
            canonicalFrameBytes: ByteArray,
            recipientNodeId: ByteArray,
            recipientStaticDhPub: ByteArray,
            acceptedGeneration: Long,
            bindingDigest: ByteArray,
            createdAtEpochSeconds: Long,
            messageNonce: ByteArray,
            priorityCode: Int,
            stateRank: IntentStateRank,
        ): JournalEntry? {
            if (intentId.isEmpty() || intentId.size > SendDirectCommand.INTENT_MAX) return null
            if (logicalMessageId.size != MessageId.NODE_ID_BYTES) return null          // msg id is 16 bytes
            if (recipientNodeId.size != MessageId.NODE_ID_BYTES) return null
            if (recipientStaticDhPub.size != 32) return null
            if (bindingDigest.size != 32) return null
            if (messageNonce.size != MessageId.NONCE_BYTES) return null
            if (signedPlaintextBytes.isEmpty() || canonicalFrameBytes.isEmpty()) return null
            return JournalEntry(intentId, logicalMessageId, signedPlaintextBytes, canonicalFrameBytes,
                recipientNodeId, recipientStaticDhPub, acceptedGeneration, bindingDigest,
                createdAtEpochSeconds, messageNonce, priorityCode, stateRank)
        }
    }

    /** Re-derive the logical message id from the pinned bytes: proof of possession from the row alone. */
    fun verifyLogicalIdentity(senderNodeId: ByteArray): Boolean {
        if (senderNodeId.size != MessageId.NODE_ID_BYTES) return false
        val rederived = MessageId.derive(senderNodeId, createdAtEpochSeconds, _messageNonce, _signedPlaintext)
        return rederived.contentEquals(_logicalMessageId)
    }

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is JournalEntry) return false
        return _intentId.contentEquals(other._intentId) && _logicalMessageId.contentEquals(other._logicalMessageId) &&
            _signedPlaintext.contentEquals(other._signedPlaintext) && _frameBytes.contentEquals(other._frameBytes) &&
            _recipientNodeId.contentEquals(other._recipientNodeId) && _recipientStaticDhPub.contentEquals(other._recipientStaticDhPub) &&
            acceptedGeneration == other.acceptedGeneration && _bindingDigest.contentEquals(other._bindingDigest) &&
            createdAtEpochSeconds == other.createdAtEpochSeconds && _messageNonce.contentEquals(other._messageNonce) &&
            priorityCode == other.priorityCode && stateRank == other.stateRank
    }

    override fun hashCode(): Int {
        var result = _intentId.contentHashCode()
        result = 31 * result + _logicalMessageId.contentHashCode()
        result = 31 * result + _bindingDigest.contentHashCode()
        result = 31 * result + acceptedGeneration.hashCode()
        result = 31 * result + stateRank.rank
        return result
    }

    override fun toString(): String =
        "JournalEntry(intent=${redactedHex(_intentId)}, msgId=${redactedHex(_logicalMessageId)}, gen=$acceptedGeneration, rank=${stateRank.name})"
}

enum class JournalInsertResult { Stored, Duplicate, StorageFailure }
enum class JournalAdvanceResult { Advanced, Stale, NoSuchEntry, StorageFailure }

/**
 * The durable intent ledger seam. The production adapter binds this to the same store
 * engine family as the message store; the JVM harness drives the in-memory reference
 * implementation below. load() returning null MEANS ABSENT -- a storage fault is typed
 * separately (StorageFailure) so an empty ledger is never confused with a failed read
 * (section 14 row 3: no correctness-critical query may return a fabricated empty set).
 */
interface OutboundIntentJournal {
    fun load(intentId: ByteArray): JournalEntry?
    fun insertIfAbsent(entry: JournalEntry): JournalInsertResult
    /**
     * One explicit transition, strictly monotone: rank(to) must equal rank(from)+1 and the
     * stored row must currently stand at [from]; anything else is Stale (the captured token
     * was revalidated on completion). Never a silent overwrite.
     */
    fun advance(intentId: ByteArray, from: IntentStateRank, to: IntentStateRank): JournalAdvanceResult
}

/**
 * In-memory reference implementation: the map IS the durable medium for the JVM harness
 * (the MessageStore corpus keeps its InMemory siblings in the same file as the interface
 * by standing precedent). A harness "restart" builds a NEW authority over the SAME
 * journal and store instances -- exactly how the Sqlite siblings model survival.
 */
class InMemoryOutboundIntentJournal : OutboundIntentJournal {
    private class IntentKey(bytes: ByteArray) {
        private val b = bytes.copyOf()
        override fun equals(other: Any?): Boolean = other is IntentKey && b.contentEquals(other.b)
        override fun hashCode(): Int = b.contentHashCode()
    }
    private val rows = HashMap<IntentKey, JournalEntry>()

    override fun load(intentId: ByteArray): JournalEntry? = rows[IntentKey(intentId)]

    override fun insertIfAbsent(entry: JournalEntry): JournalInsertResult {
        val k = IntentKey(entry.intentId)
        if (rows.containsKey(k)) return JournalInsertResult.Duplicate
        rows[k] = entry
        return JournalInsertResult.Stored
    }

    override fun advance(intentId: ByteArray, from: IntentStateRank, to: IntentStateRank): JournalAdvanceResult {
        val k = IntentKey(intentId)
        val cur = rows[k] ?: return JournalAdvanceResult.NoSuchEntry
        if (to.rank != from.rank + 1) return JournalAdvanceResult.Stale          // strictly monotone, one rung
        if (cur.stateRank != from) return JournalAdvanceResult.Stale              // token revalidation on completion
        rows[k] = withRank(cur, to)
        return JournalAdvanceResult.Advanced
    }

    /** Total row count -- an observable counter for the harness (never a production query path). */
    fun size(): Int = rows.size

    private fun withRank(e: JournalEntry, to: IntentStateRank): JournalEntry =
        JournalEntry.of(e.intentId, e.logicalMessageId, e.signedPlaintextBytes, e.canonicalFrameBytes,
            e.recipientNodeId, e.recipientStaticDhPub, e.acceptedGeneration, e.bindingDigest,
            e.createdAtEpochSeconds, e.messageNonce, e.priorityCode, to)!!
}

/** The typed verdict of resolving a recipient trust reference -- failures are DISTINGUISHED, never a flattened null. */
sealed class ResolvedRecipient {
    class Approved(
        val recipientNodeId: ByteArray,
        val recipientSigningPub: ByteArray,
        val recipientStaticDhPub: ByteArray,
        val acceptedGeneration: Long,
    ) : ResolvedRecipient() {
        override fun equals(other: Any?): Boolean {
            if (this === other) return true
            if (other !is Approved) return false
            return recipientNodeId.contentEquals(other.recipientNodeId) &&
                recipientSigningPub.contentEquals(other.recipientSigningPub) &&
                recipientStaticDhPub.contentEquals(other.recipientStaticDhPub) &&
                acceptedGeneration == other.acceptedGeneration
        }
        override fun hashCode(): Int {
            var r = recipientNodeId.contentHashCode()
            r = 31 * r + recipientSigningPub.contentHashCode()
            r = 31 * r + recipientStaticDhPub.contentHashCode()
            r = 31 * r + acceptedGeneration.hashCode()
            return r
        }
        override fun toString(): String =
            "Approved(recipient=${redactedHex(recipientNodeId)}, gen=$acceptedGeneration)"
    }
    object Absent : ResolvedRecipient() { override fun toString(): String = "Absent" }
    class NotApproved(val reason: String) : ResolvedRecipient() { override fun toString(): String = "NotApproved($reason)" }
    object Revoked : ResolvedRecipient() { override fun toString(): String = "Revoked" }
    class Corrupt(val reason: String) : ResolvedRecipient() { override fun toString(): String = "Corrupt($reason)" }
    object StorageFailure : ResolvedRecipient() { override fun toString(): String = "StorageFailure" }
    object InvalidArgument : ResolvedRecipient() { override fun toString(): String = "InvalidArgument" }
}

/** The trust-resolution seam. The production adapter reads the peer trust DB; the harness injects a deterministic fake. */
interface RecipientTrustResolver {
    fun resolve(recipientTrustRef: ByteArray): ResolvedRecipient
}

/**
 * Default adapter over the sealed read-only PeerIdentityLookupSource, mirroring the trust
 * gate of BoundRecipientKeyResolver VERBATIM in policy (only TOFU_PINNED and USER_VERIFIED
 * are accepted; REVOKED, quarantine, absence and every fault are refused) -- but typed and
 * DISTINGUISHED, so the send authority can report which gate refused without a null
 * collapsing the difference (the card's negative law: distinguish failure from empty success).
 */
internal class TrustedPeerIdentityResolver(private val source: PeerIdentityLookupSource) : RecipientTrustResolver {
    override fun resolve(recipientTrustRef: ByteArray): ResolvedRecipient {
        if (recipientTrustRef.size != MessageId.NODE_ID_BYTES) return ResolvedRecipient.InvalidArgument
        val lookup = try {
            source.lookup(recipientTrustRef)
        } catch (_e: Throwable) {
            return ResolvedRecipient.StorageFailure
        }
        return when (lookup) {
            is PeerIdentityLookup.Verified -> when (lookup.identity.trustLevel) {
                PeerTrustLevel.TOFU_PINNED, PeerTrustLevel.USER_VERIFIED -> ResolvedRecipient.Approved(
                    lookup.identity.nodeId, lookup.identity.signingPublicKey,
                    lookup.identity.acceptedStaticDhPublicKey, lookup.identity.acceptedGeneration)
                PeerTrustLevel.REVOKED -> ResolvedRecipient.Revoked
            }
            is PeerIdentityLookup.NotFound -> ResolvedRecipient.Absent
            is PeerIdentityLookup.Quarantined -> ResolvedRecipient.NotApproved("quarantined")
            is PeerIdentityLookup.Revoked -> ResolvedRecipient.Revoked
            is PeerIdentityLookup.Corrupt -> ResolvedRecipient.Corrupt(lookup.reason.toString())
            is PeerIdentityLookup.StorageFailure -> ResolvedRecipient.StorageFailure
            is PeerIdentityLookup.InvalidArgument -> ResolvedRecipient.InvalidArgument
        }
    }
}

/** The identity-creation seam: exactly one CSPRNG nonce per fresh logical send, injected at the real dependency boundary. */
interface LogicalIdentityFactory {
    fun create(nowEpochSeconds: Long): LogicalMessageIdentity
}

object DefaultLogicalIdentityFactory : LogicalIdentityFactory {
    override fun create(nowEpochSeconds: Long): LogicalMessageIdentity =
        LogicalMessageIdentity.createNew(nowEpochSeconds)
}

/** The (createdAt, quality) pair the clock stamps; the T35 binding law (0 iff UNKNOWN) is enforced at the authority. */
/**
 * The keystore seam handing the authority its 32-byte Ed25519 seed and public half. The
 * frozen Identity class keeps its private seed genuinely private (identity contract); the
 * composition root already holds the local state from which both halves are readable, and
 * the harness injects deterministic fake material. The authority proves coherence itself:
 * the public half must equal the identity's, the seed must be 32 bytes.
 */
interface SenderSigningKeys {
    val identityPrivSeed: ByteArray
    val identityPub32: ByteArray
}

class SigningKeysAdapter(
    private val seed: ByteArray,
    private val pub: ByteArray,
) : SenderSigningKeys {
    init {
        require(seed.size == 32 && pub.size == 32) { "Ed25519 key material must be 32 bytes per half" }
    }
    override val identityPrivSeed: ByteArray get() = seed.copyOf()
    override val identityPub32: ByteArray get() = pub.copyOf()
    override fun toString(): String = "SigningKeysAdapter(pub=" + redactedHex(pub) + ")"
}

class SenderTime(val createdAtEpochSeconds: Long, val timeQuality: TimeQuality)
interface SenderClock { fun now(): SenderTime }

/**
 * Production adapter: a wall clock in user hands is the evidence the operator confirmed it
 * (USER_CONFIRMED); a clock that has not been proven to a positive epoch cannot claim a time
 * and stands at the UNKNOWN rung with createdAt 0 -- the two fields stand and fall together
 * (section 15 binding law, re-enforced by SignedMessageV1.author itself).
 */
object SystemSenderClock : SenderClock {
    override fun now(): SenderTime {
        val s = System.currentTimeMillis() / 1000
        return if (s > 0L) SenderTime(s, TimeQuality.USER_CONFIRMED) else SenderTime(0L, TimeQuality.UNKNOWN)
    }
}

/** The typed rejection taxonomy of the command. Every variant is DISTINGUISHED; no id is ever carried by a rejection. */
enum class SendDirectRejection {
    BodyEmpty, BodyTooLarge, BodyNotUtf8,
    IntentIdMalformed, TrustRefMalformed,
    RecipientAbsent, RecipientNotApproved, RecipientRevoked, RecipientCorrupt, RecipientStorageFailure,
    ClockUnbound, IdentityCreationFailed, SenderIdentityUnbound,
    JournalStorageFailure,
    EnqueueCanonicMismatch, EnqueueCapacity, EnqueueConflictRecipient, EnqueueTerminalState,
    EnqueueInconsistent, EnqueueStorageFailure, EnqueueInvalidArgument,
}

/** The result surface. A logical id is handed out ONLY after the durable commit proved itself. */
sealed class SendDirectResult {
    class DurablyEnqueued(val logicalMessageId: ByteArray, val fromRetry: Boolean) : SendDirectResult() {
        override fun equals(other: Any?): Boolean {
            if (this === other) return true
            if (other !is DurablyEnqueued) return false
            return logicalMessageId.contentEquals(other.logicalMessageId) && fromRetry == other.fromRetry
        }
        override fun hashCode(): Int = 31 * logicalMessageId.contentHashCode() + fromRetry.hashCode()
        override fun toString(): String = "DurablyEnqueued(msgId=${redactedHex(logicalMessageId)}, fromRetry=$fromRetry)"
    }
    class Rejected(val reason: SendDirectRejection) : SendDirectResult() {
        override fun equals(other: Any?): Boolean = other is Rejected && reason == other.reason
        override fun hashCode(): Int = reason.hashCode()
        override fun toString(): String = "Rejected(${reason.name})"
    }
}

/**
 * The send authority. It rewrites no sealed formula: the authorship binding is delegated to
 * SignedMessageV1.author (T35), the sealing to Router.buildSealedMessage over ONE pinned
 * LogicalMessageIdentity, the atomic durable pair (held frame + SINGLE_RECIPIENT delivery row)
 * to MessageStore.enqueueDirectOutbound, and the trust gate to the read-only resolver.
 * The journal is the command's own write-ahead ledger so that the logical identity survives
 * every fault and restart between the authoring and the commit.
 */
internal class SendDirectAuthority(
    private val identity: Identity,
    private val signingKeys: SenderSigningKeys,
    private val router: Router,
    private val store: MessageStore,
    private val trustResolver: RecipientTrustResolver,
    private val journal: OutboundIntentJournal,
    private val identityFactory: LogicalIdentityFactory = DefaultLogicalIdentityFactory,
    private val clock: SenderClock = SystemSenderClock,
) {
    init {
        require(identity.nodeId.contentEquals(SignedMessageV1.nodeIdOf(identity.identityPub))) {
            "the send authority must own its key: senderNodeId is not BLAKE2s128(identityPub)"
        }
        require(signingKeys.identityPub32.contentEquals(identity.identityPub)) {
            "the keystore public half must cohere with the identity's"
        }
        require(signingKeys.identityPrivSeed.size == 32) { "the Ed25519 seed must be 32 bytes" }
    }

    /** The product command surface: the DIRECT lab profile. */
    suspend fun sendDirect(command: SendDirectCommand): SendDirectResult = sendDirect(command, Priority.DIRECT)

    /**
     * Internal door for the harness to exercise the priority variant of the binding digest
     * (the card: "changed recipient/body/priority creates a new logical send"). The public
     * surface admits DIRECT only; the lab profile forbids shipping other priorities here.
     */
    internal suspend fun sendDirect(command: SendDirectCommand, priority: Priority): SendDirectResult {
        // ---- input validation FIRST; nothing authoritative is mutated on any failure (the card's negative law)
        val body = command.bodyUtf8
        if (body.isEmpty()) return SendDirectResult.Rejected(SendDirectRejection.BodyEmpty)
        if (body.size > SignedMessageV1.BODY_MAX) return SendDirectResult.Rejected(SendDirectRejection.BodyTooLarge)
        if (!SignedMessageV1.isWellFormedUtf8(body)) return SendDirectResult.Rejected(SendDirectRejection.BodyNotUtf8)
        if (priority != Priority.DIRECT) return SendDirectResult.Rejected(SendDirectRejection.EnqueueInvalidArgument)

        val digest = bindingDigest(command.recipientTrustRef, body, priority.code)

        // ---- RETRY PATH first: the ledger answers; the retry creates NOTHING and resolves NOTHING
        val pinned = try {
            journal.load(command.intentId)
        } catch (_e: Throwable) {
            return SendDirectResult.Rejected(SendDirectRejection.JournalStorageFailure)
        }
        if (pinned != null && pinned.bindingDigest.contentEquals(digest)) {
            if (!pinned.verifyLogicalIdentity(identity.nodeId)) {
                return SendDirectResult.Rejected(SendDirectRejection.EnqueueCanonicMismatch)   // row is not self-proving: refuse
            }
            val frame = FrameV2.decode(pinned.canonicalFrameBytes)
                ?: return SendDirectResult.Rejected(SendDirectRejection.EnqueueCanonicMismatch)
            if (frame.type != TypeV2.MESSAGE || frame.flags and FrameV2.SEALED == 0 ||
                !frame.msgId.contentEquals(pinned.logicalMessageId)) {
                return SendDirectResult.Rejected(SendDirectRejection.EnqueueCanonicMismatch)
            }
            val replay = try {
                store.enqueueDirectOutbound(frame, pinned.recipientNodeId, identity.nodeId)
            } catch (_e: Throwable) {
                return SendDirectResult.Rejected(SendDirectRejection.EnqueueStorageFailure)
            }
            return when (replay) {
                is OutboundEnqueueResult.Created ->
                    replayed(replay.canonicalFrame, pinned.intentId, pinned.stateRank, fromRetry = true)
                is OutboundEnqueueResult.AlreadyQueuedSameBinding ->
                    replayed(replay.canonicalFrame, pinned.intentId, pinned.stateRank, fromRetry = true)
                else -> mapEnqueueRejection(replay)
            }
        }
        // pinned == null with a matching digest is impossible; a DIGEST MISMATCH falls through:
        // changed recipient/body/priority under one token is a NEW logical send (L8), the old
        // row stays where it is (the store retains history; the ledger keeps the latest accept).

        // ---- FRESH ACCEPT: resolve the CURRENT approved key material exactly once
        val resolved = try {
            trustResolver.resolve(command.recipientTrustRef)
        } catch (_e: Throwable) {
            ResolvedRecipient.StorageFailure
        }
        val approved = when (resolved) {
            is ResolvedRecipient.Approved -> resolved
            ResolvedRecipient.Absent -> return SendDirectResult.Rejected(SendDirectRejection.RecipientAbsent)
            is ResolvedRecipient.NotApproved -> return SendDirectResult.Rejected(SendDirectRejection.RecipientNotApproved)
            ResolvedRecipient.Revoked -> return SendDirectResult.Rejected(SendDirectRejection.RecipientRevoked)
            is ResolvedRecipient.Corrupt -> return SendDirectResult.Rejected(SendDirectRejection.RecipientCorrupt)
            ResolvedRecipient.StorageFailure -> return SendDirectResult.Rejected(SendDirectRejection.RecipientStorageFailure)
            ResolvedRecipient.InvalidArgument -> return SendDirectResult.Rejected(SendDirectRejection.TrustRefMalformed)
        }
        if (approved.recipientNodeId.size != MessageId.NODE_ID_BYTES ||
            approved.recipientSigningPub.size != 32 || approved.recipientStaticDhPub.size != 32) {
            return SendDirectResult.Rejected(SendDirectRejection.RecipientCorrupt)             // fail closed on malformed material
        }

        // ---- create the logical identity EXACTLY once: one CSPRNG nonce, one createdAt; the same
        // identity object then feeds the signature preimage and the sealed prefix -- one source of truth
        val t = try { clock.now() } catch (_e: Throwable) { return SendDirectResult.Rejected(SendDirectRejection.ClockUnbound) }
        if ((t.createdAtEpochSeconds == 0L) != (t.timeQuality == TimeQuality.UNKNOWN)) {
            return SendDirectResult.Rejected(SendDirectRejection.ClockUnbound)                 // the binding law stands and falls together
        }
        val msgIdentity = try {
            identityFactory.create(t.createdAtEpochSeconds)
        } catch (_e: Throwable) {
            return SendDirectResult.Rejected(SendDirectRejection.IdentityCreationFailed)
        }

        // ---- sign ONCE through the T35 authority (profile re-enforced there), then seal ONCE through
        // the canonical formula -- every violation is a typed refusal, no state was touched
        val signedPlaintext = try {
            SignedMessageV1.author(
                signingKeys.identityPrivSeed, identity.identityPub, identity.nodeId,
                approved.recipientNodeId, msgIdentity.messageNonce, msgIdentity.createdAtEpochSeconds,
                priority, t.timeQuality, body)
        } catch (_e: Throwable) {
            return SendDirectResult.Rejected(SendDirectRejection.EnqueueInvalidArgument)
        }
        val frame = try {
            router.buildSealedMessage(signedPlaintext, approved.recipientNodeId, approved.recipientStaticDhPub, msgIdentity, priority)
        } catch (_e: Throwable) {
            return SendDirectResult.Rejected(SendDirectRejection.EnqueueInvalidArgument)
        }
        val expectId = MessageId.derive(identity.nodeId, msgIdentity.createdAtEpochSeconds, msgIdentity.messageNonce, signedPlaintext)
        if (!frame.msgId.contentEquals(expectId) ||
            !expectId.contentEquals(MessageId.derive(identity.nodeId, msgIdentity, signedPlaintext))) {
            return SendDirectResult.Rejected(SendDirectRejection.EnqueueCanonicMismatch)       // the two derivations must agree before anything is written
        }

        // ---- WRITE-AHEAD the ledger BEFORE the store transaction, so the pinned identity survives
        // every fault and restart between authoring and commit (L6)
        val entry = JournalEntry.of(
            command.intentId, frame.msgId, signedPlaintext, frame.encode(),
            approved.recipientNodeId, approved.recipientStaticDhPub, approved.acceptedGeneration,
            digest, msgIdentity.createdAtEpochSeconds, msgIdentity.messageNonce,
            priority.code, IntentStateRank.AUTHORED)
            ?: return SendDirectResult.Rejected(SendDirectRejection.IntentIdMalformed)
        when (try { journal.insertIfAbsent(entry) } catch (_e: Throwable) { JournalInsertResult.StorageFailure }) {
            JournalInsertResult.Stored, JournalInsertResult.Duplicate -> {}                   // raced acceptor: the idempotent store transaction below governs
            JournalInsertResult.StorageFailure -> return SendDirectResult.Rejected(SendDirectRejection.JournalStorageFailure)
        }

        // ---- the atomic durable commit: held frame + SINGLE_RECIPIENT delivery row in ONE transaction
        val res = try {
            store.enqueueDirectOutbound(frame, approved.recipientNodeId, identity.nodeId)
        } catch (_e: Throwable) {
            return SendDirectResult.Rejected(SendDirectRejection.EnqueueStorageFailure)
        }
        return when (res) {
            is OutboundEnqueueResult.Created -> committed(res.canonicalFrame, command.intentId, fromRetry = false)
            is OutboundEnqueueResult.AlreadyQueuedSameBinding -> committed(res.canonicalFrame, command.intentId, fromRetry = true)
            else -> mapEnqueueRejection(res)                                                    // the row stays AUTHORED: replayable, identity survives
        }
    }

    private fun replayed(frame: FrameV2, intentId: ByteArray, from: IntentStateRank, fromRetry: Boolean): SendDirectResult {
        advanceQuietly(intentId, from, IntentStateRank.COMMITTED)
        return SendDirectResult.DurablyEnqueued(frame.msgId.copyOf(), fromRetry)
    }

    private fun committed(frame: FrameV2, intentId: ByteArray, fromRetry: Boolean): SendDirectResult {
        // the climb AUTHORED -> COMMITTED is one rung; a stale rank means a concurrent acceptor got there
        // first (the idempotent store already proved the same binding) -- bookkeeping never revokes a durable commit
        advanceQuietly(intentId, IntentStateRank.AUTHORED, IntentStateRank.COMMITTED)
        return SendDirectResult.DurablyEnqueued(frame.msgId.copyOf(), fromRetry)
    }

    private fun advanceQuietly(intentId: ByteArray, from: IntentStateRank, to: IntentStateRank) {
        try { journal.advance(intentId, from, to) } catch (_e: Throwable) { /* the store is the durable truth; a replay repairs the rank */ }
    }

    private fun mapEnqueueRejection(res: OutboundEnqueueResult): SendDirectResult.Rejected = when (res) {
        OutboundEnqueueResult.InvalidArgument -> SendDirectResult.Rejected(SendDirectRejection.EnqueueInvalidArgument)
        OutboundEnqueueResult.CanonicalFrameMismatch -> SendDirectResult.Rejected(SendDirectRejection.EnqueueCanonicMismatch)
        OutboundEnqueueResult.RejectedCapacity -> SendDirectResult.Rejected(SendDirectRejection.EnqueueCapacity)
        OutboundEnqueueResult.ConflictRecipient -> SendDirectResult.Rejected(SendDirectRejection.EnqueueConflictRecipient)
        OutboundEnqueueResult.RejectedTerminalState -> SendDirectResult.Rejected(SendDirectRejection.EnqueueTerminalState)
        OutboundEnqueueResult.InconsistentState -> SendDirectResult.Rejected(SendDirectRejection.EnqueueInconsistent)
        OutboundEnqueueResult.StorageFailure -> SendDirectResult.Rejected(SendDirectRejection.EnqueueStorageFailure)
        else -> SendDirectResult.Rejected(SendDirectRejection.EnqueueStorageFailure)
    }

    companion object {
        /** Domain separation for the binding digest, ASCII-clean like every other domain here. */
        const val BINDING_DOMAIN_TEXT: String = "GMP2-SEND-DIRECT-BIND-V1"

        /**
         * The binding digest: BLAKE2s-256 over domain || trustRef || priorityCode || body.
         * It covers the COMMAND-level facts only (never the live resolved key), so a rotation
         * behind a pinned intent cannot masquerade as changed content and a changed content can
         * never replay the pinned bytes -- both laws are proved at the counters of the harness.
         */
        fun bindingDigest(recipientTrustRef: ByteArray, bodyUtf8: ByteArray, priorityCode: Int): ByteArray {
            val dom = BINDING_DOMAIN_TEXT.toByteArray(Charsets.US_ASCII)
            val input = ByteArray(dom.size + recipientTrustRef.size + 1 + bodyUtf8.size)
            var off = 0
            dom.copyInto(input, off); off += dom.size
            recipientTrustRef.copyInto(input, off); off += recipientTrustRef.size
            input[off] = priorityCode.toByte(); off += 1
            bodyUtf8.copyInto(input, off)
            val d = Blake2sDigest(null, 32, null, null)
            d.update(input, 0, input.size)
            val out = ByteArray(32)
            d.doFinal(out, 0)
            return out
        }
    }
}
