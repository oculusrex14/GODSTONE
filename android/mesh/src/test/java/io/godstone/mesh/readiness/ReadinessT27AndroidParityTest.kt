package io.godstone.mesh.readiness

// ---------------------------------------------------------------------------
// T27 - cross-platform parity court, ANDROID side (the authority). The iOS twin
// court ReadinessT27Tests.swift replays the SAME shared vector
// (wire/traffic_governor_vectors.txt) through the new iOS PeerGovernor. The
// sealed android governor (abuse/PeerGovernor.kt, frozen as the T26 authority)
// is replayed here against the shared expect column: if BOTH isles reproduce
// one shared file, the two governors decide identically -- that is the T27
// "same adversarial trace yields identical admit/drop on both platforms"
// evidence. This court does NOT modify the sealed governor; it only drives it.
// ---------------------------------------------------------------------------

import io.godstone.mesh.abuse.PeerGovernor
import io.godstone.mesh.wire.v2.Priority
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ReadinessT27AndroidParityTest {

    private val frozenClock: Long = 1_700_000_000_000L

    private fun hexToBytes(hex: String): ByteArray {
        val clean = if (hex.length % 2 == 0) hex else "0" + hex
        val out = ByteArray(clean.length / 2)
        var i = 0
        while (i < clean.length) {
            out[i / 2] = clean.substring(i, i + 2).toInt(16).toByte()
            i += 2
        }
        return out
    }

    private fun vectorFile(): File {
        val rel = "wire/traffic_governor_vectors.txt"
        var dir: File? = File(".").absoluteFile
        var hops = 0
        while (dir != null && hops < 14) {
            val cand = File(dir, rel)
            if (cand.isFile) return cand
            dir = dir.parentFile
            hops += 1
        }
        throw AssertionError("wire/traffic_governor_vectors.txt not found from cwd " + File(".").absolutePath)
    }

    // Replays every scenario through a FRESH real android governor and asserts the
    // live decisions equal the shared expect column, then checks the bounded
    // identity-governor gauge on the Sybil scenario.
    @Test
    fun testAndroidGovernorReproducesTheSharedBudgetVectors() {
        val lines = vectorFile().readLines()
        val header = lines.firstOrNull { it.startsWith("#godstone-tgv") } ?: "#godstone-tgv-1"
        assertTrue("recognise the vector format header", header.startsWith("#godstone-tgv-"))

        var gov: PeerGovernor? = null
        var scenario = "<none>"
        var step = 0
        var events = 0
        var distinctSeen = 0
        val seen = LinkedHashSet<String>()
        var maxPeers = 0
        for (raw in lines) {
            val l = raw.trim()
            if (l.isEmpty() || l.startsWith("#")) continue
            if (l.startsWith("S ")) {
                val parts = l.split(" ")
                scenario = parts[1]
                maxPeers = parts[2].substringAfter("max=").toInt()
                gov = PeerGovernor(nowMillis = { frozenClock }, maxTrackedPeers = maxPeers)
                step = 0
                seen.clear()
                distinctSeen = 0
                continue
            }
            if (l.startsWith("E ")) {
                val g = gov ?: throw AssertionError("E line outside a scenario in " + scenario)
                val parts = l.split(" ")
                val idHex = parts[1]
                val prio = Priority.values()[parts[3].toInt()]
                val expect = parts[4] == "1"
                step += 1
                events += 1
                if (idHex !in seen) { seen.add(idHex); distinctSeen += 1 }
                val actual = g.allowInbound(hexToBytes(idHex), prio)
                assertTrue(
                    "parity divergence in scenario '%s' step %d id=%s prio=%d: expected %b got %b".format(
                        scenario, step, idHex, parts[3].toInt(), expect, actual),
                    actual == expect)
            }
        }
        assertTrue("the vector carried a meaningful number of events", events > 200)
    }

    // The bounded identity governor: under a Sybil churn above the cap the tracked
    // set equals the cap (never unbounded), and a KNOWN identity is still served.
    @Test
    fun testSybilChurnKeepsTheTrackedSetBoundedAndServesKnownPeers() {
        val g = PeerGovernor(nowMillis = { frozenClock }, maxTrackedPeers = 8)
        var served = 0
        for (k in 0 until 12) {
            if (g.allowInbound(hexToBytes(String.format("%032x", 0xD0 + k)), Priority.DIRECT)) served += 1
        }
        assertEquals("the eight within the bound are served", 8, served)
        assertEquals("the registry is capped at maxTrackedPeers", 8, g.trackedPeerCount())
        // a fresh id beyond the cap is refused and does not grow the registry
        assertTrue("a fresh over-cap identity is refused", !g.allowInbound(hexToBytes(String.format("%032x", 0xEE)), Priority.DIRECT))
        assertEquals("the registry stays bounded", 8, g.trackedPeerCount())
        // a known identity is still served despite the cap being reached
        assertTrue("a tracked identity is still served at the cap", g.allowInbound(hexToBytes(String.format("%032x", 0xD0)), Priority.DIRECT))
    }

    // A denial flood on one identity leaves OTHER trusted identities' decisions
    // intact (per-identity isolation), mirroring the shared vector's fifth scenario.
    @Test
    fun testDenialOnOneIdentityLeavesOtherTrustedPeersIntact() {
        val g = PeerGovernor(nowMillis = { frozenClock }, maxTrackedPeers = 64)
        val attacker = hexToBytes(String.format("%032x", 0xE3))
        val bystander = hexToBytes(String.format("%032x", 0xE1))
        var by = 0
        for (i in 0 until 10) { if (g.allowInbound(bystander, Priority.DIRECT)) by += 1 }
        var drop = 0
        for (i in 0 until 18) { if (g.allowInbound(attacker, Priority.BULK)) drop += 1 }
        var after = 0
        for (i in 0 until 2) { if (g.allowInbound(bystander, Priority.DIRECT)) after += 1 }
        assertEquals("the bystander keeps its own full budget before the flood", 10, by)
        assertEquals("the attacker is bounded to its 10-token BULK bucket", 10, drop)
        assertEquals("the bystander is undisturbed by the attacker's denials", 2, after)
    }
}
