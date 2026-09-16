"""GS-RUNTIME-001's ANDROID half -- THE WIRING IS WITNESSED AT SOURCE LEVEL, AND THE ARM SAITH SO.

WHY SOURCE LEVEL, MEASURED: the pure-JVM courts on that isle build their OWN `Node` fixture (a test-local class
holding the store, driver, pump and dispatcher), NOT a `MeshNode` -- and a `MeshNode` buildeth its transport
`by lazy { BleTransport(context = ctx!!, ...) }`, so a plain unit court cannot drive the node's transport path at
all. THE BEHAVIOURAL (instrumentation / fake-outlet) WITNESS IS THEREFORE STILL OWED, and this arm is what can be
run TODAY: it checketh that the wiring the round-231..233 repairs LANDED is actually in the tree.

MEASURED BEFORE THOSE REPAIRS: `MeshModule.provideMeshNode` returned a bare node with NO ACK store, pump,
dispatcher or inbox, and **NO CODE ANYWHERE IN THE ANDROID TREE COLLECTED `applicationLinkReady()`** (round 209:
the declaration and not one collector).

IT READETH PRODUCTION SOURCE TEXT. It is NOT a device result, and no gate is closed by it.
"""
from __future__ import annotations

import unittest
from pathlib import Path


def _repo_root() -> Path:
    here = Path(__file__).resolve()
    for candidate in [here.parent, *here.parents]:
        if (candidate / "ci" / "check_repository.py").exists():
            return candidate
    raise SystemExit("the repository root could not be located from " + str(here))


REPO = _repo_root()
MESH = REPO / "android/mesh/src/main/java/io/godstone/mesh"
NODE = MESH / "MeshNode.kt"
MODULE = MESH / "di/MeshModule.kt"
TRANSPORT = MESH / "transport/BleTransport.kt"
PUMP = MESH / "delivery/AckDispatcher.kt"


class AndroidAckWiringTest(unittest.TestCase):
    """W00 -- the positive control: the signal and the node's attachment points still stand to be wired."""

    def test_w00_the_signal_and_the_attachment_points_still_stand(self):
        t = TRANSPORT.read_text(encoding="utf-8")
        self.assertIn("fun applicationLinkReady(): Flow<ByteArray>", t,
                      "the readiness flow must still exist for a collector to reach")
        n = NODE.read_text(encoding="utf-8")
        self.assertIn("internal var recipientInbox: RecipientInboxRepository?", n)
        self.assertIn("internal var ackDispatcher: AckDispatcher?", n)

    def test_the_node_collecteth_the_readiness_and_schedulleth_the_worker(self):
        n = NODE.read_text(encoding="utf-8")
        self.assertIn("internal var ackPump: DurableAckPump?", n,
                      "GS-RUNTIME-001 step 3: the node must HOLD the pump, or the readiness cannot reach it")
        self.assertIn("ble.applicationLinkReady().collect", n,
                      "GS-RUNTIME-001 step 3: THE COLLECTOR -- measured absent from the whole tree before this work")
        self.assertIn("ackPump?.onLinkReady(nodeId)", n,
                      "and it must SCHEDULE the worker for THAT EXACT relation")
        self.assertIn("drainAckWorkOnce(nodeId)", n,
                      "and take the relation's first inventory at once")

    def test_the_bounded_turn_handeth_the_canonical_bytes_through_the_transport(self):
        n = NODE.read_text(encoding="utf-8")
        self.assertIn("internal suspend fun drainAckWorkOnce(nodeId: ByteArray): Int?", n)
        self.assertIn("ble.send(nodeId, copy.encodedFrame)", n,
                      "the relay copy travelleth AS THE CANONICAL BYTES it already is (this isle's transport is "
                      "keyed by node id and taketh bytes, so no mapping and no decode are needed)")
        self.assertIn("pump.onForwardOutcome(copy, nodeId, accepted)", n,
                      "and the outcome returneth to the pump, so its retry interval is honoured")

    def test_the_composition_provideth_the_owners_and_bindeth_them_to_the_node(self):
        m = MODULE.read_text(encoding="utf-8")
        for needle, why in [
            ("fun provideAckStore(store: SqliteMessageStore): SqliteAckStore = SqliteAckStore(store.engine)",
             "the durable ACK store must stand over THE SAME ENGINE the held-frames store useth"),
            ("AckObligationDriver(ackStore, IdentityAckSigner(identity), authenticator, resolver)",
             "the driver must be built over the PRODUCTION signer"),
            ("fun provideAckPump(", "the pump must be provided"),
            ("node.ackDispatcher = AckDispatcher(", "and the dispatcher BOUND to the node"),
            ("node.recipientInbox = RecipientInboxRepository(", "and the recipient inbox BOUND to the node"),
            ("commitInboundWithObligationAtWithFault(", "whose commit road is the composing store's own method"),
        ]:
            self.assertIn(needle, m, "GS-RUNTIME-001 step 2: " + why)

    def test_the_drain_precedeth_the_store_closures(self):
        """GS-RUNTIME-001 step 6 on this isle: **STOP/DRAIN WORKERS BEFORE DELETING KEYS** -- the Swift twin's law."""
        g = (MESH / "identity/RuntimeLifecycleGate.kt").read_text(encoding="utf-8")
        self.assertIn("private val node: MeshNode?", g,
                      "the invalidator must HOLD THE NODE, or it cannot drain what the keys are about to strand")
        # **THE FIRST `override fun invalidateForWipe()` IN THIS FILE IS NOT THE ONE I MEANT**: the
        # `DefaultRuntimeLifecycleGate` carrieth its own above the invalidator, and my first draft judged THAT one
        # (its slice read `invalidated.set(true)`, which is how the mistake announced itself). The arm therefore
        # beginneth at the INVALIDATOR'S class and taketh the override THAT followeth it -- the fourth species of
        # this session's control family, met again in the instrument rather than in the code.
        start = g.index("class MeshRuntimeInvalidator")
        invalidate = g[g.index("override fun invalidateForWipe() {", start):]
        invalidate = invalidate[:invalidate.index("\n    }")]
        order = [invalidate.index(s) for s in ("node?.stop()", "peerStore?.close()", "messageStore?.close()")
                 if s in invalidate]
        self.assertEqual(3, len(order),
                         "the drain AND both closures must stand in this method: " + " ".join(invalidate.split()))
        self.assertEqual(sorted(order), order,
                         "GS-RUNTIME-001 step 6: `node?.stop()` MUST PRECEDE the store closures -- a worker firing "
                         "for keys already gone is what the Swift witness caught (census 1 -> 6)")
        m = MODULE.read_text(encoding="utf-8")
        self.assertIn("node = node", m, "and the runtime must PASS its node into the invalidator")

    def test_the_nodes_stop_cancelleth_its_workers_before_the_early_return(self):
        """The Swift twin's own leak (round 220), twinned here: an early return that skippeth the cancel leaveth
        workers alive for ever when the node was never started (which is the shipping case on both isles)."""
        n = NODE.read_text(encoding="utf-8")
        stop = n[n.index("fun stop() {"):]
        stop = stop[:stop.index("\n    }")]
        cancel_at = stop.index("scope.coroutineContext.cancelChildren()")
        guard_at = stop.index("if (!isStarted) return")
        self.assertLess(cancel_at, guard_at,
                        "GS-RUNTIME-001 step 6: THE CANCEL MUST PRECEDE THE `isStarted` GUARD -- the Swift witness "
                        "watched the turn census climb 2 -> 7 AFTER stop() because its guard returned early")

    def test_the_signer_refuseth_the_seed_road_by_construction(self):
        signer = (MESH / "delivery/IdentityAckSigner.kt").read_text(encoding="utf-8")
        self.assertIn("override fun signingSeed(msgId: ByteArray, recipientNodeId: ByteArray): ByteArray? = null",
                      signer,
                      "GS-RUNTIME-001 step 2: the PRODUCTION signer must refuse the harness seed road")
        self.assertIn("identity.identityPriv", signer,
                      "and sign with the pinned identity's own material, which never leaveth the module")


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
