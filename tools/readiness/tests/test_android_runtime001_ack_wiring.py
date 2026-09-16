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

    def test_the_signer_refuseth_the_seed_road_by_construction(self):
        signer = (MESH / "delivery/IdentityAckSigner.kt").read_text(encoding="utf-8")
        self.assertIn("override fun signingSeed(msgId: ByteArray, recipientNodeId: ByteArray): ByteArray? = null",
                      signer,
                      "GS-RUNTIME-001 step 2: the PRODUCTION signer must refuse the harness seed road")
        self.assertIn("identity.identityPriv", signer,
                      "and sign with the pinned identity's own material, which never leaveth the module")


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
