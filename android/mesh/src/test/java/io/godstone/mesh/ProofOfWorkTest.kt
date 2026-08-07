package io.godstone.mesh

import io.godstone.mesh.router.ProofOfWork
import io.godstone.mesh.wire.v2.TypeV2
import kotlinx.coroutines.runBlocking
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Recipient-side GMP/2.1 proof-of-work (ADR-001 §3). The nonce lives inside the
 * sealed payload; the recipient verifies it after SealedSender.open. This test
 * exercises the mine/verify round-trip directly -- the router no longer gates
 * on PoW at the relay (see RouterTest).
 *
 * mine()/verify() take a targetBits parameter whose production default is 20
 * (ADR-pinned, ~1M BLAKE2s average). Tests pass an 8-bit target so the mine/verify
 * code path runs in milliseconds; production never calls with a non-default
 * target. mine() is CPU-bound on Dispatchers.Default, so the test uses runBlocking
 * (NOT runTest, whose virtual-time TestScheduler cannot track a real dispatcher
 * loop and reports UncompletedCoroutinesError).
 */
class ProofOfWorkTest {

    private val sender = ByteArray(16) { 0x0A }
    private val createdAt = byteArrayOf(0, 0, 0, 1)   // big-endian uint32 = epoch second 1
    private val plaintext = "hello".toByteArray()
    private val easyTarget = 8   // ~256 hashes average; exercises the path without a real search

    @Test
    fun `mined nonce is 8 bytes and verifies at the production target shape`() = runBlocking {
        // Cold-start mine at the easy target returns an 8-byte nonce that verifies.
        val nonce = ProofOfWork.mine(sender, createdAt, TypeV2.MESSAGE.code, plaintext, targetBits = easyTarget)
        assertEquals(ProofOfWork.NONCE_BYTES, nonce.size)
        assertTrue(ProofOfWork.verify(nonce, sender, createdAt, TypeV2.MESSAGE.code, plaintext, targetBits = easyTarget))
    }

    @Test
    fun `a zero nonce does not verify for fresh content`() {
        val zero = ByteArray(ProofOfWork.NONCE_BYTES)
        assertFalse(ProofOfWork.verify(zero, sender, createdAt, TypeV2.MESSAGE.code, plaintext, targetBits = easyTarget))
    }

    @Test
    fun `mined nonce bound to one plaintext does not verify a different one`() = runBlocking {
        val nonce = ProofOfWork.mine(sender, createdAt, TypeV2.MESSAGE.code, plaintext, targetBits = easyTarget)
        assertFalse(ProofOfWork.verify(nonce, sender, createdAt, TypeV2.MESSAGE.code, "world".toByteArray(), targetBits = easyTarget))
    }

    @Test
    fun `mined nonce bound to one type code does not verify a different type`() = runBlocking {
        val nonce = ProofOfWork.mine(sender, createdAt, TypeV2.MESSAGE.code, plaintext, targetBits = easyTarget)
        assertFalse(ProofOfWork.verify(nonce, sender, createdAt, TypeV2.SOS.code, plaintext, targetBits = easyTarget))
    }

    @Test
    fun `production 20-bit target rejects an 8-bit nonce`() = runBlocking {
        // An 8-bit-mined nonce has only its top 8 bits zero; the 20-bit production
        // target demands 20, so the same nonce must fail at the harder target.
        val nonce = ProofOfWork.mine(sender, createdAt, TypeV2.MESSAGE.code, plaintext, targetBits = easyTarget)
        assertFalse(ProofOfWork.verify(nonce, sender, createdAt, TypeV2.MESSAGE.code, plaintext, targetBits = ProofOfWork.TARGET_BITS))
    }
}