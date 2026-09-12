package io.godstone.mesh.delivery

import io.godstone.mesh.router.OpenMessageResult
import io.godstone.mesh.router.Router
import io.godstone.mesh.seal.SealedSender
import io.godstone.mesh.wire.v2.FrameV2
import io.godstone.mesh.wire.v2.Priority
import io.godstone.mesh.wire.v2.SenderVerificationResult
import io.godstone.mesh.wire.v2.SignedMessageV1
import io.godstone.mesh.wire.v2.TypeV2

// ------------------------------------------------------------------ T37 constants
// Section 14 verbatim: the production generator's initial ACK TTL is explicitly
// 12 -- passed at THIS call site; the frozen builder's default parameter (4)
// stands untouched. Unexpired ACKs and dedup tombstones stand 8 days from
// first local receipt, on the same non-replenishing clock policy as T83.
const val ACK_INITIAL_TTL: Int = 12
const val ACK_RETENTION_MS: Long = 8L * 24L * 60L * 60L * 1000L

// The public rotating tag may legitimately lag or lead this node's calendar by
// a bounded window when peers' clocks differ; the hint census scans that
// window only -- it is never an identity decision.
const val HINT_WINDOW_DAYS: Long = 1L
const val PAIR_CENSUS_BOUND: Int = ACK_CANDIDATES_PER_PAIR_LIMIT

/** Typed rejection taxonomy of the recipient inbox process. Input refusals
 *  keep every table byte-for-byte; none of these arms writes anything. */
enum class RejectionReason {
    WIDTHS,
    ENVELOPE,
    NOT_DIRECT,
    NOT_FOR_US,
    MALFORMED,
    POLICY_MISMATCH,
    MESSAGE_ID_MISMATCH,
    PROOF_UNBOUND,
    VERIFICATION_FAILED,
    SENDER_REVOKED,
    CAPACITY,
    STORAGE_FAILURE,
    KEY_UNAVAILABLE,
    SELF_VERIFICATION_FAILED,
    STORED_FRAME_CORRUPT,
    CACHE_KEY_UNSOUND,
    ADMISSION_QUOTA,
}

/** The card's taxonomy of one accept-and-require-ACK transaction. New and
 *  Duplicate carry the canonical recipient ACK; Rejected carries none -- a
 *  rejected delivery emits no ACK and claims no local acceptance. */
sealed class InboxCommitResult {
    /** The frame was newly held; the canonical ACK stands filed beside it. */
    data class New(val ack: FrameV2) : InboxCommitResult() {
        override fun toString(): String = "New(ack=" + redactedAckFrame(ack) + ")"
    }

    /** The frame was already held durably; the STORED row's very bytes were
     *  returned -- never a re-signature (the host Ed25519 layer may sign
     *  randomized; the durable row is the truth). No duplicate inbox content
     *  was written. */
    data class Duplicate(val ack: FrameV2) : InboxCommitResult() {
        override fun toString(): String = "Duplicate(ack=" + redactedAckFrame(ack) + ")"
    }

    /** Nothing was written and no ACK was issued: the prior state stands. */
    data class Rejected(val reason: RejectionReason, val detail: String? = null) : InboxCommitResult()
}

/** Sender admission policy, made BESIDE and never in place of the
 *  cryptographic proof (section 14: trust is policy; proof is proof). The lab
 *  composition (T54) wires the durable peer-identity authority behind it. */
internal interface RecipientSenderTrustPolicy {
    /** False only when the sender's durable identity stands revoked. */
    fun admits(senderNodeId: ByteArray): Boolean
}

/** The fail-open default: an absent policy must not masquerade as a revoked
 *  one; proof of the signature IS the identity. Width sanity still applies. */
internal object AdmitAllSenders : RecipientSenderTrustPolicy {
    override fun admits(senderNodeId: ByteArray): Boolean = senderNodeId.size == 16
}

/** Runtime telemetry of one repository instance -- observable, admissible
 *  never as proof; the durable store remains the sole authority. */
data class InboxCensus(
    val hintHits: Int,
    val hintMissesUnsealed: Int,
    val unsealedAccepted: Int,
    val verificationRejections: Int,
    val policyRejections: Int,
    val committedNew: Int,
    val committedDuplicate: Int,
    val acksIssued: Int,
    val acksRefusedQuota: Int,
    val acksRefusedKey: Int,
    val acksRefusedSelfVerify: Int,
    val storageFailures: Int,
)

private val ACK_HEX_DIGITS = "0123456789abcdef"

private fun ackHex2(sb: StringBuilder, v: Int) {
    sb.append(ACK_HEX_DIGITS[(v shr 4) and 0xF])
    sb.append(ACK_HEX_DIGITS[v and 0xF])
}

private fun redactedAckBytes(bytes: ByteArray?): String {
    if (bytes == null) return "null"
    if (bytes.isEmpty()) return "-"
    val sb = StringBuilder()
    for (i in 0 until 4) ackHex2(sb, bytes[i].toInt() and 0xFF)
    sb.append("..")
    for (i in (bytes.size - 4) until bytes.size) ackHex2(sb, bytes[i].toInt() and 0xFF)
    return sb.toString()
}

private fun redactedAckFrame(frame: FrameV2): String {
    val sb = StringBuilder("FrameV2[type=")
    sb.append(frame.type.name)
    sb.append(",msg=")
    sb.append(redactedAckBytes(frame.msgId))
    sb.append(",tag=")
    sb.append(redactedAckBytes(frame.routingTag))
    sb.append(",ttl=")
    sb.append(frame.ttl.toString())
    sb.append(",hop=")
    sb.append(frame.hopCount.toString())
    sb.append(",payload=")
    sb.append(frame.payload.size.toString())
    sb.append("B]")
    return sb.toString()
}

/**
 * T37 (section 14): the recipient inbox transaction -- from the authenticated
 * link's bounded frame to the canonical recipient ACK, in the order the plan
 * prescribes and never out of it.
 *
 * ```text
 * authenticated link -> bounded decode -> local destination attempt
 *   -> unseal -> canonical inner policy -> verify signed author/recipient/msgID
 *   -> transaction: unique inbox + dedup + receipt-relative retention
 *   -> after commit: sign canonical recipient ACK and schedule it
 * duplicate valid message: no duplicate inbox; regenerate the ACK
 * storage/verification failure: no ACK and no claimed local acceptance
 * ```
 *
 * Identity doctrine (the task's objective): the immediate-hop TrustedPeer is
 * NOT necessarily the end-to-end sender; neither the transport id
 * [receivedFrom] nor the 4-byte routing tag may stand in for either identity.
 * The sender is proven ONLY cryptographically -- the sealed layer
 * authenticates the senderNodeId claim under our DH key
 * ([Router.openSealedMessage], the frozen policy core) and the container's
 * Ed25519 signature plus the BLAKE2s128 id/key binding
 * ([SignedMessageV1.verify], the frozen binding laws) authenticate the author
 * and bind the intended local recipient. The tag is an optimization hint: a
 * mismatch never rejects (clock skew must not be mistaken for an
 * authentication failure of an identity) and a match never admits (it is not
 * proof); both directions are only counted into the observable census.
 *
 * The inbox transaction itself is the caller-bound [commitInbound] pair of the
 * T83 store method `commitInboundWithObligationAtWithFault`: held insert,
 * capacity enforcement and the pending ACK obligation INSERT in ONE engine
 * transaction, both-or-neither. The canonical ACK is produced ONLY after that
 * commit returns, by the frozen builder [AckFrame.build] with the section-14
 * production TTL, verified through the pinned-key authenticator BEFORE
 * filing, and filed together with the obligation retirement in the paired
 * store's atomic step. A storage or verification failure emits no ACK and
 * claims no acceptance; the obligation (if any) stays pending for the bounded
 * T83 worker.
 *
 * The repository keeps NO authoritative state: the durable store is the sole
 * authority; [census] is runtime telemetry only.
 */
internal class RecipientInboxRepository(
    private val router: Router,
    private val ourNodeId: ByteArray,
    /** The current local DH private key (32 bytes) or null while none stands ready. */
    private val localDhPrivate: () -> ByteArray?,
    /** The T83 signer seam: nodeId binding, generation pin and Ed25519 seed. */
    private val signer: AckSignerSeam,
    /** Pins the authentic public signing keys; consulted for OUR own key. */
    private val resolver: RecipientKeyResolver,
    /** The frozen authenticator: every self-produced ACK passes it pre-filing. */
    private val authenticator: Ed25519AckAuthenticator,
    /** The two T83 namespaces under the both-or-neither pair law. */
    private val pairedStore: AckObligationStore,
    /** The bound inbox commit: the T83 store method of the composing store. */
    private val commitInbound: suspend (
        frame: FrameV2,
        receivedFrom: ByteArray,
        localRecipientNodeId: ByteArray,
        identityGeneration: Long,
        obligationLifetimeMs: Long,
        receivedAt: Long,
        fault: ((String) -> Unit)?,
    ) -> InboundCommitResult,
    /** Sender admission policy beside, never in place of, the proof. */
    private val trustPolicy: RecipientSenderTrustPolicy = AdmitAllSenders,
    /** Wall clock in whole seconds; the composition root injects the platform truth. */
    private val clockSeconds: () -> Long = { System.currentTimeMillis() / 1000L },
    /** The rotating-tag epoch day; defaults to the sealed layer's own calendar. */
    private val epochDay: () -> Long = { SealedSender.currentEpochDay() },
    /** The generation an accepted delivery pins into the obligation row. */
    private val identityGeneration: () -> Long = { 0L },
) {

    private val countersLock = Any()

    private class Counters {
        var hintHits: Int = 0
        var hintMissesUnsealed: Int = 0
        var unsealedAccepted: Int = 0
        var verificationRejections: Int = 0
        var policyRejections: Int = 0
        var committedNew: Int = 0
        var committedDuplicate: Int = 0
        var acksIssued: Int = 0
        var acksRefusedQuota: Int = 0
        var acksRefusedKey: Int = 0
        var acksRefusedSelfVerify: Int = 0
        var storageFailures: Int = 0
    }

    private val counters = Counters()

    /** The current census of this receiving process (telemetry, not authority). */
    fun census(): InboxCensus = synchronized(countersLock) {
        InboxCensus(
            hintHits = counters.hintHits,
            hintMissesUnsealed = counters.hintMissesUnsealed,
            unsealedAccepted = counters.unsealedAccepted,
            verificationRejections = counters.verificationRejections,
            policyRejections = counters.policyRejections,
            committedNew = counters.committedNew,
            committedDuplicate = counters.committedDuplicate,
            acksIssued = counters.acksIssued,
            acksRefusedQuota = counters.acksRefusedQuota,
            acksRefusedKey = counters.acksRefusedKey,
            acksRefusedSelfVerify = counters.acksRefusedSelfVerify,
            storageFailures = counters.storageFailures,
        )
    }

    // ------------------------------------------------------------------ the entry

    /**
     * The whole inbound-recipient transaction of section 14 for one already
     * decoded frame off the authenticated link. [receivedFrom] is the
     * immediate-hop token (the trusted peer's 16-byte node id): it is filed
     * as receipt metadata and NEVER consulted for the end-to-end sender
     * identity. [fault] is the court-only fail-point seam, strings "signing"
     * and "frame_insert", mirroring the T83 discipline; production passes
     * null.
     */
    suspend fun acceptVerifiedAndRequireAck(
        frame: FrameV2,
        receivedFrom: ByteArray,
        fault: ((String) -> Unit)? = null,
    ): InboxCommitResult {
        // -- gate 0: widths and the envelope, fail-closed before any work ----
        if (ourNodeId.size != ACK_RECIPIENT_LEN || receivedFrom.size != ACK_RECIPIENT_LEN ||
            frame.msgId.size != ACK_MSG_LEN || frame.routingTag.size != ACK_HINT_LEN ||
            frame.payload.isEmpty() || frame.payload.size > FrameV2.MAX_PAYLOAD
        ) {
            return InboxCommitResult.Rejected(RejectionReason.WIDTHS)
        }
        if (frame.type != TypeV2.MESSAGE) {
            return InboxCommitResult.Rejected(RejectionReason.ENVELOPE)
        }
        if ((frame.flags and FrameV2.SEALED) == 0) {
            return InboxCommitResult.Rejected(RejectionReason.ENVELOPE)
        }
        if ((frame.flags and FrameV2.HAS_POW) != 0) {
            // the frozen DIRECT profile carries no stamp (the core binds this too)
            return InboxCommitResult.Rejected(RejectionReason.ENVELOPE)
        }
        val headerPriority = Priority.fromFlagsStrict(frame.flags)
            ?: return InboxCommitResult.Rejected(RejectionReason.ENVELOPE)
        if (headerPriority != Priority.DIRECT) {
            // only a directed message has the one recipient who could sign an ACK
            return InboxCommitResult.Rejected(RejectionReason.NOT_DIRECT)
        }

        // -- gate 1: the rotating-tag census -- a hint, never a decision ------
        val today = epochDay()
        var hintHit = false
        var day = today - HINT_WINDOW_DAYS
        while (day <= today + HINT_WINDOW_DAYS) {
            if (SealedSender.routingTag(ourNodeId, day).contentEquals(frame.routingTag)) {
                hintHit = true
            }
            day += 1L
        }
        synchronized(countersLock) {
            if (hintHit) {
                counters.hintHits += 1
            } else {
                counters.hintMissesUnsealed += 1
            }
        }
        // the tag NEVER gates: a miss is charged to the bounded decryption
        // budget (this very attempt) and the frame is still opened, because
        // "incorrect clocks must not be mistaken for authentication failure of
        // an identity".

        // -- gate 2: unseal under the local key through the frozen core -------
        val ourDh = localDhPrivate()
            ?: return refuseKey("no local dh key material")
        val opened = when (val oc = router.openSealedMessage(frame, ourDh)) {
            is OpenMessageResult.Accepted -> {
                synchronized(countersLock) { counters.unsealedAccepted += 1 }
                oc.message
            }
            OpenMessageResult.NotForUs -> return InboxCommitResult.Rejected(RejectionReason.NOT_FOR_US)
            OpenMessageResult.Malformed -> return InboxCommitResult.Rejected(RejectionReason.MALFORMED)
            OpenMessageResult.WrongFrameType -> return InboxCommitResult.Rejected(RejectionReason.ENVELOPE)
            OpenMessageResult.MissingSealedFlag -> return InboxCommitResult.Rejected(RejectionReason.ENVELOPE)
            OpenMessageResult.PolicyMismatch -> return InboxCommitResult.Rejected(RejectionReason.POLICY_MISMATCH)
            OpenMessageResult.MessageIdMismatch -> return InboxCommitResult.Rejected(RejectionReason.MESSAGE_ID_MISMATCH)
            OpenMessageResult.InvalidProofOfWork -> return InboxCommitResult.Rejected(RejectionReason.PROOF_UNBOUND)
        }

        // -- gate 3: verify the signed author/recipient/msgID before admission -
        val sv = SignedMessageV1.verify(
            signedPlaintext = opened.plaintext,
            senderNodeId = opened.senderNodeId,
            recipientLocalNodeId = ourNodeId,
            messageNonce = opened.messageNonce,
            createdAtEpochSeconds = opened.createdAtEpochSeconds,
            priorityCode = opened.priority.code,
        )
        if (sv !is SenderVerificationResult.Verified) {
            val detail = if (sv is SenderVerificationResult.Invalid) sv.reason else "verification did not yield"
            synchronized(countersLock) { counters.verificationRejections += 1 }
            return InboxCommitResult.Rejected(RejectionReason.VERIFICATION_FAILED, detail)
        }
        val vm = sv.message
        // defense in depth: the frozen derivation must agree with the envelope
        if (!vm.msgId.contentEquals(frame.msgId)) {
            synchronized(countersLock) { counters.verificationRejections += 1 }
            return InboxCommitResult.Rejected(RejectionReason.MESSAGE_ID_MISMATCH, "derived vs framed")
        }
        if (!vm.recipientNodeId.contentEquals(ourNodeId)) {
            // the verifier already bound this; a divergence here is unsound input
            synchronized(countersLock) { counters.verificationRejections += 1 }
            return InboxCommitResult.Rejected(RejectionReason.VERIFICATION_FAILED, "recipient binding")
        }

        // -- gate 4: sender admission policy, beside (never instead of) proof --
        if (!trustPolicy.admits(vm.senderNodeId)) {
            synchronized(countersLock) { counters.policyRejections += 1 }
            return InboxCommitResult.Rejected(RejectionReason.SENDER_REVOKED)
        }

        // -- gate 5: the durable inbox transaction: unique + dedup + retention -
        val commitOutcome = commitInbound(
            frame, receivedFrom, ourNodeId, identityGeneration(),
            ACK_RETENTION_MS, clockSeconds(), fault,
        )
        when (commitOutcome) {
            is InboundCommitResult.Committed -> {}
            InboundCommitResult.RejectedCapacity ->
                return InboxCommitResult.Rejected(RejectionReason.CAPACITY)
            InboundCommitResult.StorageFailure ->
                return refuseStorage("inbox commit")
            InboundCommitResult.InvalidArgument ->
                return InboxCommitResult.Rejected(RejectionReason.WIDTHS, "commit args")
        }
        if (commitOutcome !is InboundCommitResult.Committed) {
            // unreachable while the taxonomy is closed; defensive, never silent
            return InboxCommitResult.Rejected(RejectionReason.STORAGE_FAILURE, "commit outcome vanished")
        }

        // -- step 6: AFTER the commit, the canonical recipient ACK, once ------
        return issueOrRestoreAck(frame, receivedFrom, commitOutcome, fault)
    }

    // ------------------------------------------------------------------ internals

    /** Read the stored row for this (msg, us) pair; else sign, verify, file. */
    private fun issueOrRestoreAck(
        frame: FrameV2,
        receivedFrom: ByteArray,
        committed: InboundCommitResult.Committed,
        fault: ((String) -> Unit)?,
    ): InboxCommitResult {
        val heldNew = committed.heldNew
        // (a) the stored verified row answers a duplicate with the VERY bytes
        //     first filed -- regenerating by re-signing is forbidden: the host
        //     Ed25519 layer may sign randomized, the durable row is the truth.
        when (val pl = pairedStore.candidatesForPair(frame.msgId, ourNodeId, PAIR_CENSUS_BOUND)) {
            is PairList.Records -> {
                for (rec in pl.records) {
                    if (!rec.recipientNodeId.contentEquals(ourNodeId)) continue
                    if (rec.verificationClass != AckVerificationClass.VERIFIED_RECIPIENT) continue
                    val stored = FrameV2.decode(rec.encodedFrame)
                        ?: return refuseCorrupt("stored ack row does not decode")
                    if (committed.obligationStored) {
                        // The sealed T83 commit inserts its obligation beside EVERY
                        // inbox entry, duplicates included; this accept answered
                        // from the already-filed row and skipped the pair step, so
                        // the fresh PENDING row is a resurrection of a settled
                        // pair. Retire it here -- the census stays honest and the
                        // bounded worker is never re-armed for an answered pair.
                        when (pairedStore.retireObligation(frame.msgId, ourNodeId)) {
                            is ObligationAdvanceResult.StorageFailure -> {
                                synchronized(countersLock) { counters.storageFailures += 1 }
                            }
                            else -> {}
                        }
                    }
                    return admitArm(heldNew, stored)
                }
            }
            is PairList.Corrupt -> return refuseCorrupt(pl.reason)
            is PairList.StorageFailure -> return refuseStorage("pair census")
        }
        // (b) no filed row yet: the obligation stands (or an external wipe
        //     removed the pair's frames and this is the reissuance under the
        //     frozen formula). Sign now -- this is still AFTER the durable
        //     commit, which returned above.
        fault?.invoke("signing")
        val theirNode = signer.nodeId
        if (theirNode == null || !theirNode.contentEquals(ourNodeId)) {
            return refuseKey("signer does not name the obligated recipient")
        }
        val seed = signer.signingSeed(frame.msgId, ourNodeId)
            ?: return refuseKey("signing seed unavailable")
        when (val ol = pairedStore.lookupObligation(frame.msgId, ourNodeId)) {
            is ObligationLookup.Found -> {
                if (signer.generation() < ol.obligation.identityGeneration) {
                    // the key stands behind the obligation's pinned generation
                    return refuseKey("signer generation behind obligation pin")
                }
            }
            ObligationLookup.Absent -> Unit // reissuance; the pair step tolerates an absent obligation
            is ObligationLookup.Corrupt -> return refuseCorrupt("obligation row: " + ol.reason)
            ObligationLookup.StorageFailure -> return refuseStorage("obligation lookup")
        }
        val built = AckFrame.build(
            msgId = frame.msgId,
            recipientSigningPrivKey = seed,
            recipientNodeId = ourNodeId,
            routingTag = ourNodeId.copyOfRange(0, ACK_HINT_LEN),
            ttl = ACK_INITIAL_TTL,
        )
        // verification-first, even for our own freshly built answer: an ACK
        // that fails its own pinned-key check is never filed and never handed
        // out -- the obligation stays pending for the bounded worker.
        val ourPublic = resolver.publicSigningKey(ourNodeId)
        if (ourPublic == null || ourPublic.size != 32) {
            return refuseKey("own signing key not resolvable")
        }
        if (!authenticator.verify(
                originalMsgId = frame.msgId,
                expectedRecipientNodeId = ourNodeId,
                ackFrame = built,
            )
        ) {
            synchronized(countersLock) { counters.acksRefusedSelfVerify += 1 }
            return InboxCommitResult.Rejected(RejectionReason.SELF_VERIFICATION_FAILED)
        }
        if (built.payload.size != ACK_PAYLOAD_LEN ||
            !built.payload.copyOfRange(ACK_SIG_LEN, ACK_PAYLOAD_LEN).contentEquals(ourNodeId)
        ) {
            synchronized(countersLock) { counters.acksRefusedSelfVerify += 1 }
            return InboxCommitResult.Rejected(RejectionReason.SELF_VERIFICATION_FAILED, "canonical shape")
        }
        val signature = built.payload.copyOfRange(0, ACK_SIG_LEN)
        val ackKey = AckCacheKey.compute(
            msgId = frame.msgId,
            recipientNodeId = ourNodeId,
            signature = signature,
        ) ?: return InboxCommitResult.Rejected(RejectionReason.CACHE_KEY_UNSOUND)
        val record = AckFrameRecord.of(
            ackKey = ackKey,
            msgId = frame.msgId,
            recipientNodeId = ourNodeId,
            signature = signature,
            encodedFrame = built.encode(),
            receivedFrom = receivedFrom.copyOf(),
            remainingLifetimeMs = ACK_RETENTION_MS,
            verificationClass = AckVerificationClass.VERIFIED_RECIPIENT,
        ) ?: return InboxCommitResult.Rejected(RejectionReason.CACHE_KEY_UNSOUND, "record")
        fault?.invoke("frame_insert")
        when (pairedStore.commitFrameAndRetireObligation(record, frame.msgId, ourNodeId)) {
            FrameCommitResult.Committed, FrameCommitResult.Idempotent -> {
                synchronized(countersLock) { counters.acksIssued += 1 }
                return admitArm(heldNew, built)
            }
            FrameCommitResult.RefusedQuotaPair, FrameCommitResult.RefusedQuotaGlobal -> {
                synchronized(countersLock) { counters.acksRefusedQuota += 1 }
                // saturation posture: nothing is claimed; the obligation stays
                // pending for the bounded T83 worker to retire later
                return InboxCommitResult.Rejected(RejectionReason.ADMISSION_QUOTA)
            }
            FrameCommitResult.StorageFailure -> return refuseStorage("pair commit")
        }
    }

    private fun admitArm(heldNew: Boolean, ack: FrameV2): InboxCommitResult {
        if (heldNew) {
            synchronized(countersLock) { counters.committedNew += 1 }
            return InboxCommitResult.New(ack)
        }
        synchronized(countersLock) { counters.committedDuplicate += 1 }
        return InboxCommitResult.Duplicate(ack)
    }

    private fun refuseKey(detail: String): InboxCommitResult {
        synchronized(countersLock) { counters.acksRefusedKey += 1 }
        return InboxCommitResult.Rejected(RejectionReason.KEY_UNAVAILABLE, detail)
    }

    private fun refuseStorage(where: String): InboxCommitResult {
        synchronized(countersLock) { counters.storageFailures += 1 }
        return InboxCommitResult.Rejected(RejectionReason.STORAGE_FAILURE, where)
    }

    private fun refuseCorrupt(detail: String): InboxCommitResult =
        InboxCommitResult.Rejected(RejectionReason.STORED_FRAME_CORRUPT, detail)
}
