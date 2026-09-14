// T55 readiness court (android isle) -- the identity verification, rotation and
// wipe UX.
//
// The app layer speaketh to the durable trust authority through `TrustPort` and
// nothing else. This court driveth the REAL ViewModel and the REAL QR policy
// against a DETERMINISTIC port that mirrors the durable repository's CAS
// semantics exactly: an approval is refused unless it carrieth the generation AND
// the key the pending row actually holdeth. That is what letteth the card's named
// semantic negative -- "Approve whichever rotation is current instead of the
// displayed candidate" -- be executed rather than argued.
//
// No shipping behaviour is claimed: the port's real binding belongeth to the lab
// composition (T54), the shipping app bindeth `UnavailableTrustPort`, and the
// readiness flags stay false.
package io.godstone.app.readiness

import io.godstone.app.trust.BindingImportOutcome
import io.godstone.app.trust.ContactProjection
import io.godstone.app.trust.ContactTrustLabel
import io.godstone.app.trust.ConfirmOutcome
import io.godstone.app.trust.ContactVerificationCommand
import io.godstone.app.trust.ExactRotationCandidateRef
import io.godstone.app.trust.IdentityTrustViewModel
import io.godstone.app.trust.OwnIdentityProjection
import io.godstone.app.trust.QrPayloadPolicy
import io.godstone.app.trust.RevokeOutcome
import io.godstone.app.trust.RotationApprovalOutcome
import io.godstone.app.trust.TrustCensus
import io.godstone.app.trust.TrustPort
import io.godstone.app.trust.TrustUiState
import io.godstone.app.trust.WipeProgressState
import io.godstone.app.ui.trust.screenshotProtectionWanted
import io.godstone.app.ui.trust.trustLabel
import java.io.File
import org.junit.Assert
import org.junit.Test

private fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }

class ReadinessT55Test {

    // ------------------------------------------------------------ the durable double

    /** One contact row, as the durable authority would carry it. */
    private class Row(
        val nodeId: ByteArray,
        val label: String,
        var trust: ContactTrustLabel,
        var acceptedGeneration: Long,
        var acceptedKeyDigest: String,
        var pending: ExactRotationCandidateRef?,
    )

    /**
     * The durable trust authority's SEMANTICS, faithfully mirrored: a pending
     * rotation is approved only by an [ExactRotationCandidateRef] whose node,
     * generation AND key digest all match the standing row.
     */
    private class DurableTrustDouble(
        private val ownNodeId: ByteArray = ByteArray(16) { (it + 0x20).toByte() },
    ) : TrustPort {
        val rows = LinkedHashMap<String, Row>()
        var corruptReason: String? = null
        var unavailableReason: String? = null
        var wipe: WipeProgressState = WipeProgressState.Idle
        var wipeFailsAt: String? = null
        var wipeCompletesAfterResume = true

        // call counters: a refused command must never reach the authority
        var contactsReads = 0
        var imports = 0
        var approvals = 0
        var revocations = 0
        /** Every ref the ViewModel handed to the authority, in order. */
        val approvedRefs = ArrayList<ExactRotationCandidateRef>()

        fun seedVerified(seed: Byte, label: String, generation: Long = 1L): ExactRotationCandidateRef {
            val nodeId = ByteArray(16) { (it + seed).toByte() }
            val staticKey = ByteArray(32) { (it + seed).toByte() }
            rows[nodeId.toHex()] = Row(nodeId, label, ContactTrustLabel.USER_VERIFIED,
                acceptedGeneration = generation,
                acceptedKeyDigest = ExactRotationCandidateRef.digestHex(staticKey), pending = null)
            return ExactRotationCandidateRef(nodeId, generation, staticKey)
        }

        fun seedTofu(seed: Byte, label: String): ByteArray {
            val nodeId = ByteArray(16) { (it + seed).toByte() }
            val keyDigest = ExactRotationCandidateRef.digestHex(ByteArray(32) { (it + seed).toByte() })
            rows[nodeId.toHex()] = Row(nodeId, label, ContactTrustLabel.TOFU_UNVERIFIED,
                acceptedGeneration = 1L, acceptedKeyDigest = keyDigest, pending = null)
            return nodeId
        }

        fun offerRotation(nodeId: ByteArray, generation: Long, keySeed: Byte): ExactRotationCandidateRef {
            val ref = ExactRotationCandidateRef(
                nodeId, generation, ByteArray(32) { (it + keySeed).toByte() },
            )
            rows.getValue(nodeId.toHex()).pending = ref
            rows.getValue(nodeId.toHex()).trust = ContactTrustLabel.ROTATION_PENDING
            return ref
        }

        override fun ownIdentity(): OwnIdentityProjection? {
            if (unavailableReason != null || corruptReason != null) return null
            val staticKey = ByteArray(32) { (it + 0x11).toByte() }
            val signature = ByteArray(64) { (it + 0x33).toByte() }
            return OwnIdentityProjection(
                nodeId = ownNodeId,
                fingerprintHex = ExactRotationCandidateRef.digestHex(ownNodeId),
                qrPayload = QrPayloadPolicy.render(ownNodeId, staticKey, signature),
            )
        }

        override fun contacts(): TrustCensus {
            contactsReads++
            corruptReason?.let { return TrustCensus.Corrupt(it) }
            unavailableReason?.let { return TrustCensus.Unavailable(it) }
            return TrustCensus.Readable(rows.values.map { row ->
                ContactProjection(
                    nodeId = row.nodeId.copyOf(),
                    label = row.label,
                    trust = row.trust,
                    fingerprintHex = row.acceptedKeyDigest,
                    acceptedGeneration = row.acceptedGeneration,
                    pendingRotation = row.pending,
                )
            })
        }

        override fun importBinding(payload: String): BindingImportOutcome {
            imports++
            val parsed = QrPayloadPolicy.parse(payload)
            if (parsed is io.godstone.app.trust.QrParseResult.Refused) {
                return BindingImportOutcome.Refused(parsed.reason)
            }
            val binding = (parsed as io.godstone.app.trust.QrParseResult.Parsed).binding
            rows[binding.nodeId.toHex()] = Row(
                binding.nodeId, "imported-" + binding.nodeId.toHex().take(4),
                ContactTrustLabel.TOFU_UNVERIFIED, 1L,
                ExactRotationCandidateRef.digestHex(binding.staticDhPublicKey), null,
            )
            return BindingImportOutcome.Imported(binding.nodeId.copyOf(),
                "imported-" + binding.nodeId.toHex().take(4))
        }

        override fun approveRotation(ref: ExactRotationCandidateRef): RotationApprovalOutcome {
            approvals++
            approvedRefs.add(ref)
            val row = rows[ref.nodeIdCopy().toHex()] ?: return RotationApprovalOutcome.PeerNotFound
            if (row.trust == ContactTrustLabel.REVOKED) return RotationApprovalOutcome.RejectedRevoked
            val pending = row.pending ?: return RotationApprovalOutcome.NoPendingCandidate
            // THE CAS: generation AND key digest, both, or nothing happeneth
            if (pending.pendingGeneration != ref.pendingGeneration ||
                pending.pendingKeyDigestHex != ref.pendingKeyDigestHex
            ) {
                return RotationApprovalOutcome.StaleCandidate
            }
            row.acceptedGeneration = ref.pendingGeneration
            row.acceptedKeyDigest = ref.pendingKeyDigestHex
            row.trust = ContactTrustLabel.USER_VERIFIED
            row.pending = null
            return RotationApprovalOutcome.Approved(ref.nodeIdCopy(), ref.pendingGeneration)
        }

        override fun confirmVerified(nodeId: ByteArray, fingerprintHex: String): ConfirmOutcome {
            val row = rows[nodeId.toHex()] ?: return ConfirmOutcome.PeerNotFound
            if (row.trust == ContactTrustLabel.USER_VERIFIED) return ConfirmOutcome.AlreadyVerified
            if (row.trust == ContactTrustLabel.REVOKED) return ConfirmOutcome.Refused("revoked")
            // THE CAS: the digest must be the durable one, or nothing is promoted
            if (!row.acceptedKeyDigest.equals(fingerprintHex, ignoreCase = true)) {
                return ConfirmOutcome.Mismatch
            }
            row.trust = ContactTrustLabel.USER_VERIFIED
            return ConfirmOutcome.Confirmed(nodeId.copyOf(), row.acceptedGeneration)
        }

        override fun revoke(nodeId: ByteArray): RevokeOutcome {
            revocations++
            val row = rows[nodeId.toHex()] ?: return RevokeOutcome.PeerNotFound
            if (row.trust == ContactTrustLabel.REVOKED) return RevokeOutcome.AlreadyRevoked
            row.trust = ContactTrustLabel.REVOKED
            row.pending = null
            return RevokeOutcome.Revoked
        }

        override fun wipeProgress(): WipeProgressState = wipe

        override fun beginWipe(): WipeProgressState {
            wipe = if (wipeFailsAt != null) {
                WipeProgressState.InProgress(wipeFailsAt!!, attempt = 1, resumable = true,
                    lastError = "storage refused the erase")
            } else if (wipeCompletesAfterResume) {
                WipeProgressState.InProgress("erase_estate", attempt = 1, resumable = true)
            } else {
                WipeProgressState.Complete
            }
            return wipe
        }

        override fun resumeWipe(): WipeProgressState {
            val current = wipe
            wipe = if (current is WipeProgressState.InProgress && wipeCompletesAfterResume) {
                WipeProgressState.Complete
            } else {
                current
            }
            return wipe
        }
    }

    private fun viewModel(port: TrustPort) = IdentityTrustViewModel(port = port)

    // ------------------------------------------------------------ W01

    /** W01 -- one contact verified: TOFU first, VERIFIED only after the compare. */
    @Test
    fun test_w01_one_contact_is_verified_only_after_the_compare() {
        val port = DurableTrustDouble()
        val nodeId = port.seedTofu(0x40, "Aunt")
        val model = viewModel(port)

        val before = model.refresh()
        val tofu = before.contact(nodeId)!!
        Assert.assertEquals(ContactTrustLabel.TOFU_UNVERIFIED, tofu.trust)
        Assert.assertTrue("TOFU must never look verified", tofu.isTofu && !tofu.isVerified)
        Assert.assertNotEquals("TOFU and VERIFIED must read differently",
            trustLabel(ContactTrustLabel.TOFU_UNVERIFIED), trustLabel(ContactTrustLabel.USER_VERIFIED))

        val confirmed = model.onCommand(
            ContactVerificationCommand.CompareAndConfirmFingerprint(nodeId, tofu.fingerprintHex))
        val after = confirmed.contact(nodeId)!!
        Assert.assertEquals("a matching compare promotes to VERIFIED",
            ContactTrustLabel.USER_VERIFIED, after.trust)
        Assert.assertTrue(after.isVerified)
        Assert.assertNull(confirmed.error)
    }

    // ------------------------------------------------------------ W02

    /**
     * W02 -- THE NAMED NEGATIVE: competing rotation candidates. The screen holdeth
     * the ELDER candidate; the authority's pending row is the NEWER one. Approving
     * the DISPLAYED (elder) ref must be REFUSED by the CAS -- and the ref the
     * ViewModel hands over must be the displayed one, not a re-read current one.
     */
    @Test
    fun test_w02_the_displayed_candidate_is_the_one_approved() {
        val port = DurableTrustDouble()
        val ref = port.seedVerified(0x50, "Brother")
        val nodeId = ref.nodeIdCopy()
        val model = viewModel(port)

        // the screen renders the elder candidate ...
        val displayed = port.offerRotation(nodeId, generation = 2L, keySeed = 0x60)
        val rendered = model.refresh()
        Assert.assertEquals("the screen carrieth the exact ref it displayed",
            displayed, rendered.contact(nodeId)!!.pendingRotation)

        // ... and the authority's pending row moves on while the user readeth it
        val newer = port.offerRotation(nodeId, generation = 3L, keySeed = 0x70)
        Assert.assertFalse("the two candidates are different",
            newer.sameCandidateAs(displayed))

        // approving what the user SAW is refused: the CAS bindeth to the candidate
        val refused = model.onCommand(ContactVerificationCommand.ApproveRotation(displayed))
        Assert.assertEquals("the DISPLAYED ref is what travelled",
            displayed, port.approvedRefs.single())
        Assert.assertNotNull("a stale approval is refused with a visible reason", refused.error)
        Assert.assertTrue(refused.error!!.contains("no longer pending"))
        val after = refused.contact(nodeId)!!
        Assert.assertEquals("the old trust standeth untouched",
            ContactTrustLabel.ROTATION_PENDING, after.trust)
        Assert.assertEquals("and the newer candidate is STILL pending",
            newer, after.pendingRotation)
        Assert.assertNotEquals("nothing was accepted at the new generation",
            3L, after.acceptedGeneration)

        // ... and a DISMISSAL is not an approval: the pending candidate standeth,
        // the old trust keepeth working, and nothing is accepted (the card: "a
        // canceled rotation leaves old trust unchanged")
        val dismissed = model.onCommand(ContactVerificationCommand.DismissRotation(newer))
        val stillPending = dismissed.contact(nodeId)!!
        Assert.assertEquals("a dismissal approveth nothing",
            ContactTrustLabel.ROTATION_PENDING, stillPending.trust)
        Assert.assertEquals("the candidate standeth for a later decision",
            newer, stillPending.pendingRotation)
        Assert.assertEquals("and the accepted generation did not move",
            1L, stillPending.acceptedGeneration)

        // approving the ref the screen NOW carrieth succeedeth
        val approved = model.onCommand(ContactVerificationCommand.ApproveRotation(newer))
        val settled = approved.contact(nodeId)!!
        Assert.assertEquals(ContactTrustLabel.USER_VERIFIED, settled.trust)
        Assert.assertEquals(3L, settled.acceptedGeneration)
        Assert.assertNull(settled.pendingRotation)
    }

    // ------------------------------------------------------------ W03

    /** W03 -- a stale or foreign ref is refused and the estate is UNCHANGED. */
    @Test
    fun test_w03_a_stale_ref_leaveth_the_estate_unchanged() {
        val port = DurableTrustDouble()
        val ref = port.seedVerified(0x51, "Cousin")
        val nodeId = ref.nodeIdCopy()
        val pending = port.offerRotation(nodeId, generation = 5L, keySeed = 0x61)
        val model = viewModel(port)
        val before = model.refresh()

        val foreign = ExactRotationCandidateRef(nodeId, 5L, ByteArray(32) { 0 })
        val refused = model.onCommand(ContactVerificationCommand.ApproveRotation(foreign))
        Assert.assertNotNull(refused.error)
        val after = refused.contact(nodeId)!!
        Assert.assertEquals("the pending candidate standeth", pending, after.pendingRotation)
        Assert.assertEquals("the accepted generation moved for nothing",
            before.contact(nodeId)!!.acceptedGeneration, after.acceptedGeneration)
        Assert.assertEquals("and the trust label is untouched",
            before.contact(nodeId)!!.trust, after.trust)
    }

    // ------------------------------------------------------------ W04

    /** W04 -- revoke during an ACTIVE session: trust dropped, rotation dismissed. */
    @Test
    fun test_w04_revocation_during_an_active_session() {
        val port = DurableTrustDouble()
        val ref = port.seedVerified(0x52, "Neighbour")
        val nodeId = ref.nodeIdCopy()
        val pending = port.offerRotation(nodeId, generation = 9L, keySeed = 0x62)
        val model = viewModel(port)
        model.refresh()
        Assert.assertEquals(1, model.uiState().pendingRotations.size)

        val revoked = model.onCommand(ContactVerificationCommand.Revoke(nodeId))
        Assert.assertEquals(ContactTrustLabel.REVOKED, revoked.contact(nodeId)!!.trust)
        Assert.assertNull("a revoked contact carrieth no pending rotation",
            revoked.contact(nodeId)!!.pendingRotation)
        Assert.assertTrue(revoked.pendingRotations.isEmpty())
        Assert.assertEquals("the sessions are invalidated by the authority's revoke",
            1, port.revocations)

        // a late approval of the old candidate cannot resurrect the contact
        val late = model.onCommand(ContactVerificationCommand.ApproveRotation(pending))
        Assert.assertNotNull(late.error)
        Assert.assertTrue(late.error!!.contains("revoked"))
        Assert.assertEquals(ContactTrustLabel.REVOKED, late.contact(nodeId)!!.trust)

        // and a duplicate revocation is idempotent, never an error
        val again = model.onCommand(ContactVerificationCommand.Revoke(nodeId))
        Assert.assertNull(again.error)
        Assert.assertTrue(again.lastOutcome!!.contains("already revoked"))
    }

    // ------------------------------------------------------------ W05

    /** W05 -- a CORRUPT trust store claimeth nothing, and fabricateth no contact. */
    @Test
    fun test_w05_a_corrupt_trust_store_claimeth_nothing() {
        val port = DurableTrustDouble()
        port.seedVerified(0x53, "Doctor")
        port.corruptReason = "the peer identity table faileth its frozen DDL fingerprint"
        val model = viewModel(port)

        val state = model.refresh()
        Assert.assertTrue(state.census is TrustCensus.Corrupt)
        Assert.assertTrue("no contact may be fabricated for a corrupt store",
            state.contacts.isEmpty())
        Assert.assertNull("and no own identity is claimed either", state.own)
        Assert.assertTrue(state.verified.isEmpty() && state.tofu.isEmpty())

        // every command against a corrupt store is refused with a reason
        val revoked = model.onCommand(ContactVerificationCommand.Revoke(ByteArray(16) { 1 }))
        Assert.assertNotNull(revoked.error)
    }

    // ------------------------------------------------------------ W06

    /** W06 -- a failed wipe stayeth resumable, and a RELAUNCH reacheth it. */
    @Test
    fun test_w06_a_failed_wipe_surviveth_a_relaunch() {
        val port = DurableTrustDouble()
        port.seedVerified(0x54, "Sister")
        port.wipeFailsAt = "erase_peer_trust"
        val model = viewModel(port)

        val begun = model.onCommand(ContactVerificationCommand.BeginWipe)
        val state = begun.wipe as WipeProgressState.InProgress
        Assert.assertEquals("erase_peer_trust", state.stage)
        Assert.assertEquals(1, state.attempt)
        Assert.assertTrue("a failed wipe MUST be resumable", state.resumable)
        Assert.assertTrue(state.blocksOrdinaryUse)
        Assert.assertNotNull(state.lastError)

        // a RELAUNCH: a fresh ViewModel over the same durable journal
        val relaunched = viewModel(port)
        val reprojected = relaunched.refresh()
        Assert.assertTrue("a relaunch must never report Idle while the wipe standeth",
            reprojected.wipe is WipeProgressState.InProgress)
        Assert.assertTrue(reprojected.wipe.isResumable)

        val resumed = relaunched.onCommand(ContactVerificationCommand.ResumeWipe)
        Assert.assertTrue("the resumed wipe reacheth its terminal state",
            resumed.wipe is WipeProgressState.Complete)
        Assert.assertFalse(resumed.wipe.blocksOrdinaryUse)
    }

    // ------------------------------------------------------------ W07

    /** W07 -- a malformed QR is refused by name, and the authority is not consulted. */
    @Test
    fun test_w07_a_malformed_payload_is_refused() {
        val port = DurableTrustDouble()
        port.seedVerified(0x55, "Chemist")
        val model = viewModel(port)
        model.refresh()
        val readsBefore = port.contactsReads
        val importsBefore = port.imports

        val cases = listOf(
            "" to "empty",
            "https://example.com" to "prefix",
            QrPayloadPolicy.PREFIX to "no body",
            QrPayloadPolicy.PREFIX + "not*base64!" to "charset",
            QrPayloadPolicy.PREFIX + "AAAA" to "length",
            QrPayloadPolicy.PREFIX + "A".repeat(200) to "length",
        )
        for ((payload, what) in cases) {
            val state = model.onCommand(ContactVerificationCommand.ImportRecipientBinding(payload))
            Assert.assertNotNull("a $what payload must be refused visibly", state.error)
            Assert.assertTrue("a $what payload must never be a silent success",
                state.error!!.startsWith("that code cannot be used"))
        }
        Assert.assertEquals("the authority's IMPORT road was never entered",
            importsBefore, port.imports)
        Assert.assertEquals("and a locally-refused command re-projected nothing at all",
            readsBefore, port.contactsReads)
    }

    // ------------------------------------------------------------ W08

    /** W08 -- an OVERSIZED payload is refused before it is decoded. */
    @Test
    fun test_w08_an_oversized_payload_is_refused_before_decoding() {
        val port = DurableTrustDouble()
        val model = viewModel(port)
        val huge = QrPayloadPolicy.PREFIX + "A".repeat(QrPayloadPolicy.MAX_PAYLOAD_CHARS * 40)
        Assert.assertTrue("the fixture must exceed the bound",
            huge.length > QrPayloadPolicy.MAX_PAYLOAD_CHARS)
        Assert.assertFalse("and the policy must say so without parsing it",
            QrPayloadPolicy.isWellFormed(huge))

        val state = model.onCommand(ContactVerificationCommand.ImportRecipientBinding(huge))
        Assert.assertNotNull(state.error)
        Assert.assertTrue(state.error!!.contains("over the"))
        Assert.assertEquals("nothing was imported", 0, port.imports)
        Assert.assertTrue(state.contacts.isEmpty())
    }

    // ------------------------------------------------------------ W09

    /** W09 -- no private-key export and no leak: only public material crosseth. */
    @Test
    fun test_w09_no_private_material_is_exported_or_leaked() {
        val port = DurableTrustDouble()
        val ref = port.seedVerified(0x56, "Ferryman")
        val pending = port.offerRotation(ref.nodeIdCopy(), generation = 4L, keySeed = 0x66)
        val model = viewModel(port)
        val state = model.refresh()

        val own = state.own!!
        Assert.assertTrue("the QR payload is the public binding form",
            own.qrPayload.startsWith(QrPayloadPolicy.PREFIX))
        val parsed = QrPayloadPolicy.parse(own.qrPayload)
        Assert.assertTrue(parsed is io.godstone.app.trust.QrParseResult.Parsed)
        val binding = (parsed as io.godstone.app.trust.QrParseResult.Parsed).binding
        Assert.assertEquals("the payload carrieth the node id, a static PUBLIC key and a signature",
            QrPayloadPolicy.EXPECTED_BYTES,
            binding.nodeId.size + binding.staticDhPublicKey.size + binding.signature.size)

        // the approval carrieth a PUBLIC digest of the pending key -- never key bytes
        model.onCommand(ContactVerificationCommand.ApproveRotation(pending))
        val handed = port.approvedRefs.single()
        Assert.assertEquals("the ref carrieth a digest, not material",
            64, handed.pendingKeyDigestHex.length)
        Assert.assertFalse("a digest is not a key", handed.toString().contains("PRIVATE"))

        // and nothing the screen carrieth rendereth key material
        val rendered = state.toString() +
            state.contacts.joinToString { it.toString() + it.fingerprintHex } +
            (state.error ?: "") + (state.lastOutcome ?: "")
        Assert.assertFalse("no projection or message carrieth private material",
            rendered.contains("PRIVATE") || rendered.contains("privateKey"))
    }

    // ------------------------------------------------------------ W10

    /** W10 -- the screenshot policy followeth the secret-bearing material. */
    @Test
    fun test_w10_the_screenshot_policy_followeth_the_material() {
        val port = DurableTrustDouble()
        port.seedVerified(0x57, "Boatman")
        val model = viewModel(port)

        val shown = model.onCommand(ContactVerificationCommand.ShowOwnIdentity)
        Assert.assertNotNull("the identity screen carrieth the QR", shown.own)
        Assert.assertTrue("so a screenshot must be blocked while it standeth",
            screenshotProtectionWanted(shown))
        Assert.assertTrue(shown.redacted)

        // a corrupt store claimeth no identity, so nothing needeth protection
        port.corruptReason = "unreadable"
        val hidden = model.refresh()
        Assert.assertNull(hidden.own)
        Assert.assertFalse("with no identity shown there is nothing to protect",
            screenshotProtectionWanted(hidden))
    }

    // ------------------------------------------------------------ W11

    /** W11 -- a fingerprint MISMATCH never promotes trust. */
    @Test
    fun test_w11_a_mismatching_fingerprint_is_refused() {
        val port = DurableTrustDouble()
        val nodeId = port.seedTofu(0x58, "Warden")
        val model = viewModel(port)
        val before = model.refresh().contact(nodeId)!!

        val wrong = "f".repeat(64)
        Assert.assertNotEquals(before.fingerprintHex, wrong)
        val refused = model.onCommand(
            ContactVerificationCommand.CompareAndConfirmFingerprint(nodeId, wrong))
        Assert.assertNotNull(refused.error)
        Assert.assertTrue(refused.error!!.contains("NOT verified"))
        Assert.assertEquals("trust is unchanged by a mismatch",
            ContactTrustLabel.TOFU_UNVERIFIED, refused.contact(nodeId)!!.trust)

        // a malformed digest is refused before anything is compared
        val malformed = model.onCommand(
            ContactVerificationCommand.CompareAndConfirmFingerprint(nodeId, "zzzz"))
        Assert.assertNotNull(malformed.error)
        Assert.assertTrue(malformed.error!!.contains("64-character hex"))
        Assert.assertEquals(ContactTrustLabel.TOFU_UNVERIFIED,
            malformed.contact(nodeId)!!.trust)
    }

    // ------------------------------------------------------------ W12

    /** W12 -- a refused command never mutates the authoritative estate. */
    @Test
    fun test_w12_a_refused_command_never_mutates_the_estate() {
        val port = DurableTrustDouble()
        port.seedVerified(0x59, "Keeper")
        val model = viewModel(port)
        val before = model.refresh()

        val readsBefore = port.contactsReads
        // a stranger's candidate, a node id of the wrong width, an unknown contact:
        // each is refused, and the ESTATE is what must be unchanged -- an authority
        // may be consulted and refuse without a single row moving
        model.onCommand(ContactVerificationCommand.ApproveRotation(
            ExactRotationCandidateRef(ByteArray(16) { 9 }, 1L, ByteArray(32) { 0x0a })))
        model.onCommand(ContactVerificationCommand.Revoke(ByteArray(5)))
        model.onCommand(ContactVerificationCommand.CompareAndConfirmFingerprint(
            ByteArray(16) { 9 }, "b".repeat(64)))
        val after = model.refresh()

        Assert.assertEquals("the contact census is unchanged",
            before.contacts.map { it.label to it.trust }, after.contacts.map { it.label to it.trust })
        Assert.assertEquals("nor did any generation move",
            before.contacts.map { it.acceptedGeneration },
            after.contacts.map { it.acceptedGeneration })
        Assert.assertNull("and no pending rotation was created or consumed",
            after.contacts.map { it.pendingRotation }.firstOrNull { it != null })
        Assert.assertTrue("the wrong-width node id never reached the authority's revoke road",
            port.revocations == 0)
        Assert.assertTrue("while the estate was still read (a refusal is news about it)",
            port.contactsReads > readsBefore)
    }

    // ------------------------------------------------------------ W13

    /**
     * W13 -- the app-side ref carrieth EXACTLY what the durable CAS bindeth on.
     *
     * The port's real binding liveth in :mesh (the lab composition); this witness
     * readeth that authority's own source and asserteth the three fields the app
     * handeth over are the three its CAS requireth, so the contract cannot drift
     * apart from it silently.
     */
    @Test
    fun test_w13_the_ref_matcheth_the_durable_cas_signature() {
        var repo = File(System.getProperty("user.dir"))
        var hops = 0
        while (!File(repo, "android").isDirectory && hops < 8) {
            repo = repo.parentFile ?: break
            hops++
        }
        val source = File(repo, "android/mesh/src/main/java/io/godstone/mesh/identity/PeerIdentityRepository.kt")
        Assert.assertTrue("the durable authority must be discoverable: " + source.path, source.isFile)
        val text = source.readText()
        Assert.assertTrue("the CAS is bound to the node, the generation AND the pending key",
            text.contains("fun approvePendingRotation(") &&
                text.contains("expectedPendingGeneration") &&
                text.contains("expectedPendingStaticDhPublicKey"))
        Assert.assertTrue("and a stale candidate is refused by name",
            text.contains("object StaleCandidate"))

        val ref = ExactRotationCandidateRef(ByteArray(16) { 1 }, 7L, ByteArray(32) { 0x0c })
        Assert.assertEquals("the ref carrieth the node id", 16, ref.nodeIdCopy().size)
        Assert.assertEquals("the ref carrieth the generation", 7L, ref.pendingGeneration)
        Assert.assertEquals("the ref carrieth the pending KEY itself, which the CAS bindeth on",
            32, ref.pendingKeyCopy().size)
        Assert.assertEquals("and the digest is derived from it", 64, ref.pendingKeyDigestHex.length)
        Assert.assertFalse("two refs differing in generation are different candidates",
            ref.sameCandidateAs(ref.copy(pendingGeneration = 8L)))
        Assert.assertFalse("two refs differing in key are different candidates",
            ref.sameCandidateAs(ref.copy(pendingStaticDhPublicKey = ByteArray(32) { 0x0d })))
        Assert.assertTrue("and the same three operands are the SAME candidate",
            ref.sameCandidateAs(ref.copy()))
    }
}
